//! Attention: Cookie wakes by attention, not by a schedule. Pure arithmetic
//! over a subject's state; the client stores that state, feeds it each write,
//! and calls [`consider`] on a write or a tick. Nothing here calls a model.
//!
//! Every write passes four stages, cheapest first.
//!
//! 1. **Who may cause a notice.** Cookie's own saves never do ([`by_cookie`]:
//!    a run must not wake on what it wrote). Mail and synced items are marked
//!    `outside` ([`from_outside`]): they add to a subject, and the notice says so.
//! 2. **Salience per subject.** A subject is a branch and the thing a write is
//!    about ([`subject_of`]). Each write scores 1–10 from what the brain
//!    stamped on it ([`salience`]), damped by how much the team still wants
//!    that kind on that subject ([`habituation`]). Levels decay by 0.995 an
//!    hour (Generative Agents' recency factor). **Hard cues** skip the
//!    build-up: a decision contradicted and left standing (`conflict`), a plan
//!    past its day (`past_due`), a write about someone a held plan is owed to
//!    (`plan_cue`, from [`signal_of`]). A client calls [`consider`] right after
//!    adding a hard cue.
//! 3. **The gate.** A subject over its threshold, once its writes have gone
//!    quiet for 15 minutes (or after an hour of steady trickle), is scored
//!    0.6·importance + 0.4·relevance − interference − displacement
//!    (ProMemAssist's shape, [`utility`]). Above 0.75 it is noticed; at or
//!    below 0 the build-up is dropped; between, it waits.
//! 4. **Labels.** A notice is for the team to label (useful / not useful /
//!    wrong). A "not useful" halves that kind of signal on that subject
//!    ([`label`]; it recovers over a week); the team-wide threshold rises when
//!    notices stop being useful ([`gain`]).

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// The level a subject's soft signals must reach: about three notable
/// decisions on one subject. To be tuned on labels.
pub const THRESHOLD: f64 = 18.0;
/// Generative Agents' recency decay per hour (half-life ≈ 5.8 days).
pub const DECAY_PER_HOUR: f64 = 0.995;
/// A subject fires once its writes go quiet this long (seconds)…
pub const QUIET: f64 = 15.0 * 60.0;
/// …or after this much steady trickle, whichever comes first.
pub const MAX_WAIT: f64 = 60.0 * 60.0;
/// A build-up that never crossed in a day has faded.
pub const FADE: f64 = 24.0 * 3600.0;
/// ProMemAssist's deliver band.
pub const NOTICE_AT: f64 = 0.75;
/// Notices per team per day, at most (labels are a person's time).
pub const DAILY_CAP: i64 = 8;
/// Signals a subject keeps.
pub const MAX_CUES: usize = 20;
/// A held plan due within this long is coming due: Cookie notices before the
/// day, not only after it.
pub const DUE_SOON: f64 = 24.0 * 3600.0;
/// A plan past its day longer than this is history, not news.
pub const PAST_DUE_WINDOW: f64 = 72.0 * 3600.0;
/// A notice waits for the team's writes to go quiet this long — a natural
/// break — before it is put in front of anyone. Help offered at a break is
/// taken up far more than help offered mid-task (arXiv 2601.10253: 52%
/// engaged after a commit, 62% dismissed mid-task).
pub const BREAK_AFTER: f64 = 10.0 * 60.0;
/// The longest a notice waits for a break: a hard cue (a contradiction, a
/// day passed), then anything else.
pub const HOLD_HARD: f64 = 30.0 * 60.0;
pub const HOLD_MAX: f64 = 4.0 * 3600.0;
/// Notices one person is sent in a day, at most.
pub const PER_PERSON_DAILY: i64 = 3;

/// One write, as attention sees it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Signal {
    /// The memory (or conflict) it came from.
    pub id: String,
    /// decision · plan · requirement · fact · … · conflict · past_due · plan_cue
    pub kind: String,
    /// One line a person can read.
    pub why: String,
    pub salience: f64,
    /// Epoch seconds.
    pub at: f64,
    /// It came from mail or a synced app, not from someone on the team.
    pub outside: bool,
    /// A person on the team wrote it (through an AI tool or the Console).
    pub by_person: bool,
    pub hard: bool,
    /// What it is about, by name — the decision, the plan, the page's host —
    /// for the notice's question ([`question`]). Empty: not known.
    pub what: String,
    /// A plan's day (epoch seconds); 0 = none.
    pub due: f64,
    /// Who or which tool made the change, as the client names them ("Mara",
    /// "Claude Code"). Empty: not known, and the notice says only "someone".
    pub by: String,
    /// When the change was written (epoch seconds); 0 = not known.
    pub changed_at: f64,
    /// A contradicted decision's maker and day, when the client knows them.
    pub decided_by: String,
    pub decided_at: f64,
}

/// How much the team wanted one kind of signal, and when that was set.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Habit {
    pub w: f64,
    pub at: f64,
}

/// One subject's attention. The client keeps it, keyed by `key`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Subject {
    pub key: String,
    pub title: String,
    pub branch: String,
    pub level: f64,
    /// Epoch seconds, as are the other times here.
    pub updated_at: f64,
    pub pending_since: Option<f64>,
    pub last_signal_at: Option<f64>,
    pub cues: Vec<Signal>,
    /// Signal kind → how much the team still wants it.
    pub habituation: BTreeMap<String, Habit>,
    pub last_noticed_at: Option<f64>,
}

impl Subject {
    /// A fresh subject for a write on `branch` about `about`.
    pub fn new(branch: &str, about: &[String], now: f64) -> Subject {
        let (key, title) = subject_of(branch, about);
        let branch = if branch.trim().is_empty() { "main" } else { branch.trim() };
        Subject { key, title, branch: branch.to_string(), updated_at: now, ..Subject::default() }
    }

    /// How much the team still wants `kind` on this subject, now.
    fn wanted(&self, kind: &str, now: f64) -> f64 {
        match self.habituation.get(kind) {
            Some(h) => habituation(h.w, (now - h.at) / 86_400.0),
            None => 1.0,
        }
    }
}

/// A subject the team should hear about.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Notice {
    pub subject: String,
    pub title: String,
    pub branch: String,
    pub hard: bool,
    pub utility: f64,
    pub level: f64,
    pub cues: Vec<Signal>,
    /// The one question the notice ends with, asked of the person
    /// ([`question`]). `None`: none could be put from its cues, and the
    /// notice is held, never sent with a generic line.
    #[serde(default)]
    pub question: Option<String>,
}

/// One memory write, as the client describes it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Write {
    pub id: String,
    pub kind: String,
    pub weight: Option<String>,
    pub feeling: Option<String>,
    /// It revises an earlier memory.
    pub revises: bool,
    pub name: String,
    pub about: Vec<String>,
    pub branch: String,
    pub outside: bool,
    pub by_person: bool,
    /// Who or which tool wrote it ([`Signal::by`]).
    pub by: String,
}

/// What the client counts for the team.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Team {
    /// Labels over the last 50 notices, and how many said useful.
    pub labelled: i64,
    pub useful: i64,
    /// Notices still waiting for a label (last week).
    pub open: usize,
    pub noticed_today: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Verdict {
    /// Not yet: below the threshold, still busy, between bands, or the day's cap is spent.
    Wait,
    /// Scored at or below zero: the build-up is cleared.
    Drop,
    /// Never crossed in a day: the build-up is cleared.
    Fade,
    Notice(Notice),
}

/// How much one write matters, 1–10, from what the brain stamped on it.
pub fn salience(kind: &str, weight: Option<&str>, feeling: Option<&str>, revises: bool) -> f64 {
    let base: f64 = match kind {
        "decision" | "correction" => 6.0,
        "requirement" | "plan" => 5.0,
        "insight" | "opinion" => 4.0,
        "fact" | "metric" | "preference" | "definition" | "document" => 3.0,
        // A tool's own bookkeeping: its checkpoint, an exchange kept for continuity.
        "checkpoint" | "episode" => 1.0,
        _ => 2.0,
    };
    let weight = match weight {
        Some("critical") => 3.0,
        Some("notable") => 1.0,
        _ => 0.0,
    };
    let feeling = match feeling {
        Some("surprising") => 2.0,
        Some("bad") => 1.0,
        _ => 0.0,
    };
    let revises = if revises { 1.0 } else { 0.0 };
    (base + weight + feeling + revises).clamp(1.0, 10.0)
}

/// A level carried forward `hours`.
pub fn decayed(level: f64, hours: f64) -> f64 {
    level * DECAY_PER_HOUR.powf(hours.max(0.0))
}

/// How much the team still wants this kind of signal on a subject: halved by
/// each "not useful", coming back to whole with a week's half-life.
pub fn habituation(w: f64, days_since: f64) -> f64 {
    let w = w.clamp(0.0, 1.0);
    1.0 - (1.0 - w) * 0.5f64.powf(days_since.max(0.0) / 7.0)
}

/// The subject a write belongs to: its branch and the first thing it is about
/// that is not the branch itself. `(key, title)`.
pub fn subject_of(branch: &str, about: &[String]) -> (String, String) {
    let branch = if branch.trim().is_empty() { "main" } else { branch.trim() };
    let entity = about.iter().map(|a| a.trim()).find(|a| !a.is_empty() && !a.eq_ignore_ascii_case(branch));
    match entity {
        Some(e) => (format!("{}|{}", branch.to_lowercase(), e.to_lowercase()), format!("{e} · {branch}")),
        None => (format!("{}|*", branch.to_lowercase()), branch.to_string()),
    }
}

/// The gate. `level` against `threshold`; `by_person`: someone on the team
/// wrote on it; `hours_since_last`: since this subject was last noticed;
/// `open`: notices still waiting for a label.
pub fn utility(level: f64, threshold: f64, by_person: bool, hours_since_last: Option<f64>, open: usize) -> f64 {
    let importance = (level / threshold.max(1.0)).min(1.0);
    // Nobody on the team wrote on it (synced mail alone): it can build up, but
    // it cannot reach a notice without a person's write beside it.
    let relevance = if by_person { 1.0 } else { 0.25 };
    let interference = match hours_since_last {
        Some(h) if h < 24.0 => 0.5 * (1.0 - h / 24.0),
        _ => 0.0,
    };
    let displacement = (open as f64 / 10.0).min(0.5);
    0.6 * importance + 0.4 * relevance - interference - displacement
}

/// The team-wide gain on the threshold: up when notices stop being useful,
/// down when they are (LC-NE adaptive gain). Neutral until ten labels exist.
pub fn gain(labelled: i64, useful: i64) -> f64 {
    if labelled < 10 {
        return 1.0;
    }
    let acceptance = (useful as f64 / labelled as f64).max(0.01);
    (0.5 / acceptance).clamp(0.5, 2.0)
}

/// The branch in a memory's `source_uri` (`…/branch/<name>/…`), else main.
pub fn branch_in(source_uri: &str) -> String {
    source_uri
        .split("/branch/")
        .nth(1)
        .and_then(|r| r.split('/').next())
        .filter(|b| !b.is_empty())
        .unwrap_or("main")
        .to_string()
}

/// A write Cookie itself made never wakes Cookie. `event`: one entry of the
/// engine's activity stream.
pub fn by_cookie(event: &Value) -> bool {
    let low = |k: &str| event.get(k).and_then(Value::as_str).unwrap_or("").to_ascii_lowercase();
    low("member").starts_with("cookie:") || low("via").contains("cookie") || low("principal").contains("cookie")
}

/// A write that came from mail or a synced app rather than from a person.
pub fn from_outside(event: &Value) -> bool {
    let via = event.get("via").and_then(Value::as_str).unwrap_or("").to_ascii_lowercase();
    let verb = event.get("verb").and_then(Value::as_str).unwrap_or("");
    verb == "ingest" && !via.is_empty() && !via.contains("claude") && !via.contains("codex") && !via.contains("cursor") && via != "console"
}

fn clip(s: &str, n: usize) -> String {
    let s = s.trim();
    if s.chars().count() <= n {
        s.to_string()
    } else {
        // Room for the "…": `n - 1` characters (none for a cap of 0 or 1).
        format!("{}…", s.chars().take(n.saturating_sub(1)).collect::<String>().trim_end())
    }
}

/// The signal one write makes. `owed`: the held plans, as
/// `(who it is owed to, lowercase; plan id; plan name)`. A write about someone
/// a plan is owed to is that plan's hard cue; anything else is scored.
pub fn signal_of(write: &Write, owed: &[(String, String, String)], now: f64) -> Signal {
    let plan = write.about.iter().find_map(|a| {
        let a_low = a.to_lowercase();
        owed.iter().find(|(to, _, _)| *to == a_low).map(|(_, id, name)| (a, id, name))
    });
    match plan {
        Some((who, plan_id, plan_name)) if *plan_id != write.id => Signal {
            id: format!("{}:cue:{plan_id}", write.id),
            kind: "plan_cue".into(),
            why: clip(&format!("New about {who}, who is owed “{plan_name}”: {}", write.name), 160),
            salience: 10.0,
            at: now,
            outside: write.outside,
            by_person: write.by_person,
            hard: true,
            what: plan_name.clone(),
            due: 0.0,
            by: write.by.clone(),
            changed_at: now,
            ..Signal::default()
        },
        _ => Signal {
            id: write.id.clone(),
            kind: write.kind.clone(),
            why: clip(&write.name, 140),
            salience: salience(&write.kind, write.weight.as_deref(), write.feeling.as_deref(), write.revises),
            at: now,
            outside: write.outside,
            by_person: write.by_person,
            hard: false,
            what: write.name.clone(),
            due: 0.0,
            by: write.by.clone(),
            changed_at: now,
            ..Signal::default()
        },
    }
}

/// Add one signal to its subject. A hard cue adds no level; the client
/// calls [`consider`] at once after it.
pub fn add(subject: &mut Subject, signal: Signal, now: f64) {
    if subject.cues.iter().any(|c| c.id == signal.id) {
        return;
    }
    let added = if signal.hard { 0.0 } else { signal.salience * subject.wanted(&signal.kind, now) };
    subject.level = decayed(subject.level, (now - subject.updated_at) / 3600.0) + added;
    subject.updated_at = now;
    subject.pending_since.get_or_insert(now);
    subject.last_signal_at = Some(now);
    subject.cues.push(signal);
    if subject.cues.len() > MAX_CUES {
        let extra = subject.cues.len() - MAX_CUES;
        subject.cues.drain(..extra);
    }
}

/// Score a subject: notice it, drop it, let it fade, or let it wait.
pub fn consider(subject: &mut Subject, team: &Team, now: f64) -> Verdict {
    let Some(pending) = subject.pending_since else { return Verdict::Wait };
    let level = decayed(subject.level, (now - subject.updated_at) / 3600.0);
    let hard = subject.cues.iter().any(|c| c.hard);
    let threshold = THRESHOLD * gain(team.labelled, team.useful);
    let quiet = subject.last_signal_at.is_none_or(|t| now - t >= QUIET) || now - pending >= MAX_WAIT;
    if !hard && (level < threshold || !quiet) {
        if now - pending >= FADE {
            subject.pending_since = None;
            subject.cues.clear();
            return Verdict::Fade;
        }
        return Verdict::Wait;
    }
    if team.noticed_today >= DAILY_CAP {
        return Verdict::Wait;
    }
    let by_person = subject.cues.iter().any(|c| c.by_person);
    let since = subject.last_noticed_at.map(|t| (now - t) / 3600.0);
    let score = utility(if hard { threshold } else { level }, threshold, by_person, since, team.open);
    if score <= 0.0 {
        subject.pending_since = None;
        subject.cues.clear();
        return Verdict::Drop;
    }
    if score < NOTICE_AT {
        return Verdict::Wait;
    }
    // Only what supports this notice: the hard cues that fired it, else the
    // writes that built it up without a tool's own bookkeeping. A checkpoint
    // listed under a contradicted decision only confused the person reading.
    let mut cues = std::mem::take(&mut subject.cues);
    if hard {
        cues.retain(|c| c.hard);
    } else {
        cues.retain(|c| !matches!(c.kind.as_str(), "checkpoint" | "episode"));
    }
    let notice = Notice {
        subject: subject.key.clone(),
        title: title(subject, &cues),
        branch: subject.branch.clone(),
        hard,
        utility: score,
        level,
        question: question(&cues),
        cues,
    };
    subject.level = 0.0;
    subject.updated_at = now;
    subject.pending_since = None;
    subject.last_noticed_at = Some(now);
    Verdict::Notice(notice)
}

/// A label on a notice about this subject. "useful" restores each of its cue
/// kinds; anything else ("not_useful", "wrong") halves them.
pub fn label(subject: &mut Subject, cue_kinds: &[String], label: &str, now: f64) {
    let kinds: BTreeSet<&String> = cue_kinds.iter().collect();
    for k in kinds {
        let w = if label == "useful" { 1.0 } else { subject.wanted(k, now) * 0.5 };
        subject.habituation.insert(k.clone(), Habit { w, at: now });
    }
}

/// A held plan, as the client reads it from the brain.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Plan {
    pub id: String,
    pub name: String,
    /// Epoch seconds; 0 = no day.
    pub due: f64,
    pub branch: String,
    pub about: Vec<String>,
    pub to: Option<String>,
}

/// The hard cues held plans give right now: one coming due within
/// [`DUE_SOON`] (`<id>:soon`), one past its day within [`PAST_DUE_WINDOW`]
/// (`<id>:due`). Each id fires once; the client remembers which did.
pub fn due_cues(plans: &[Plan], now: f64) -> Vec<(Plan, Signal)> {
    let mut out = Vec::new();
    for p in plans.iter().filter(|p| p.due > 0.0) {
        let left = p.due - now;
        let owed = p.to.as_deref().map(|t| format!(" (owed to {t})")).unwrap_or_default();
        let (suffix, kind, why, salience) = if left > 0.0 && left <= DUE_SOON {
            let hours = (left / 3600.0).ceil() as i64;
            let when = if hours <= 1 { "within the hour".to_string() } else { format!("in {hours} hours") };
            (":soon", "due_soon", format!("Due {when}: {}{owed}", p.name), 8.0)
        } else if left <= 0.0 && -left < PAST_DUE_WINDOW {
            (":due", "past_due", format!("Past its day: {}{owed}", p.name), 10.0)
        } else {
            continue;
        };
        let signal = Signal {
            id: format!("{}{suffix}", p.id),
            kind: kind.into(),
            why,
            salience,
            at: now,
            outside: false,
            by_person: true,
            hard: true,
            what: p.name.clone(),
            due: p.due,
            ..Signal::default()
        };
        out.push((p.clone(), signal));
    }
    out
}

/// When a notice is put in front of the team.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Moment {
    /// When the notice was made (epoch seconds).
    pub since: f64,
    /// The team's last write to the brain, and Cookie jobs at work for it.
    pub last_write_at: Option<f64>,
    pub jobs_running: i64,
    pub hard: bool,
}

/// Release a held notice now, and why now — or keep holding it. It goes out
/// at a natural break (the team's writes quiet for [`BREAK_AFTER`], no Cookie
/// job at work), or once it has waited as long as it may.
pub fn deliver(m: &Moment, now: f64) -> Option<&'static str> {
    let quiet = m.last_write_at.is_none_or(|t| now - t >= BREAK_AFTER) && m.jobs_running == 0;
    let longest = if m.hard { HOLD_HARD } else { HOLD_MAX };
    if quiet {
        Some("the team's work went quiet")
    } else if now - m.since >= longest {
        Some("it could not wait for a quieter moment")
    } else {
        None
    }
}

/// One person, now: their local time and quiet hours, and what they were
/// sent today.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Person {
    /// Minutes past midnight in their own time.
    pub local_minutes: i64,
    /// Quiet from this hour to that hour, local (20 → 8 spans midnight). Equal = never quiet.
    pub quiet_from: i64,
    pub quiet_to: i64,
    pub sent_today: i64,
    /// They turned notices off.
    pub off: bool,
}

/// Send a released notice to this person now? `Err(why not)` — it stays
/// waiting while they are in quiet hours, and is not sent at all once they
/// had their day's share or turned notices off.
pub fn send_to(p: &Person) -> Result<(), &'static str> {
    if p.off {
        return Err("off");
    }
    if p.sent_today >= PER_PERSON_DAILY {
        return Err("enough today");
    }
    let hour = (p.local_minutes.rem_euclid(1440)) / 60;
    let quiet = match (p.quiet_from, p.quiet_to) {
        (f, t) if f == t => false,
        (f, t) if f < t => hour >= f && hour < t,
        (f, t) => hour >= f || hour < t,
    };
    if quiet {
        return Err("quiet hours");
    }
    Ok(())
}

/// What a notice is about, by name, for its subject line: the thing its
/// writes are about, else what the cue it asks about names. Never a bare
/// branch: "Cookie noticed: main" told the person nothing (2026-10-30).
pub fn title(subject: &Subject, cues: &[Signal]) -> String {
    let thing = (!subject.key.ends_with("|*"))
        .then(|| subject.title.strip_suffix(&format!(" · {}", subject.branch)))
        .flatten()
        .map(str::to_string)
        .or_else(|| asked(cues).map(|(c, _)| c.what.clone()))
        .or_else(|| cues.iter().rev().map(|c| c.what.trim()).find(|w| !w.is_empty()).map(str::to_string));
    match thing {
        Some(t) => clip(&t, 80),
        None if is_main(&subject.branch) => "new notes from the team".to_string(),
        None => format!("new notes on the {} branch", subject.branch),
    }
}

fn is_main(branch: &str) -> bool {
    branch.trim().is_empty() || branch.trim().eq_ignore_ascii_case("main")
}

/// Why this notice, read first: what changed, where, who did it and when, as
/// far as the cues say. A contradicted decision is named, with its maker and
/// day when known; a plan's day speaks for itself; a build-up says who wrote
/// how much about what. Nothing a cue does not carry is said.
pub fn why_now(n: &Notice) -> String {
    let place = if is_main(&n.branch) { String::new() } else { format!(" on the {} branch", n.branch.trim()) };
    let who = |c: &Signal| match c.by.trim() {
        "" if c.outside => "Mail or a synced app".to_string(),
        "" => "Someone on the team".to_string(),
        by => by.to_string(),
    };
    let on = |at: f64| if at > 0.0 { format!("On {}, ", crate::cookie::mail::day_name(at as i64)) } else { String::new() };
    if let Some(c) = n.cues.iter().find(|c| c.hard && c.kind == "conflict") {
        let decision = match c.what.trim() {
            "" => "a decision the team made".to_string(),
            what => format!("the decision “{}”", clip(what, 80)),
        };
        let mut made = Vec::new();
        if !c.decided_by.trim().is_empty() {
            made.push(format!("by {}", c.decided_by.trim()));
        }
        if c.decided_at > 0.0 {
            made.push(format!("on {}", crate::cookie::mail::day_name(c.decided_at as i64)));
        }
        let made = if made.is_empty() { String::new() } else { format!(", made {}", made.join(" ")) };
        let when = on(c.changed_at);
        let actor = if when.is_empty() { who(c) } else { first_lower(&who(c)) };
        return format!("{when}{actor} wrote something{place} that goes against {decision}{made}.");
    }
    if let Some(c) = n.cues.iter().find(|c| c.hard && !c.why.is_empty()) {
        return c.why.clone();
    }
    let notes = if n.cues.len() == 1 { "a note".to_string() } else { format!("{} notes", n.cues.len()) };
    let mut people: Vec<String> = Vec::new();
    for by in n.cues.iter().map(|c| c.by.trim()).filter(|b| !b.is_empty()) {
        if !people.iter().any(|p| p == by) {
            people.push(by.to_string());
        }
    }
    let days: Vec<f64> = n.cues.iter().map(|c| c.changed_at).filter(|t| *t > 0.0).collect();
    let since = match (days.iter().copied().reduce(f64::min), days.iter().copied().reduce(f64::max)) {
        (Some(a), Some(b)) if crate::cookie::mail::day_name(a as i64) == crate::cookie::mail::day_name(b as i64) => {
            format!(" on {}", crate::cookie::mail::day_name(a as i64))
        }
        (Some(a), Some(_)) => format!(" since {}", crate::cookie::mail::day_name(a as i64)),
        _ => String::new(),
    };
    let writers = match people.as_slice() {
        [] if n.cues.iter().any(|c| c.by_person) => "Your team".to_string(),
        [] => return format!("{} about {}{place} came in from mail or synced apps{since}.", first_upper(&notes), n.title),
        [one] => one.clone(),
        [a, b] => format!("{a} and {b}"),
        [a, b, rest @ ..] => format!("{a}, {b} and {}", if rest.len() == 1 { rest[0].clone() } else { format!("{} more", rest.len()) }),
    };
    format!("{writers} wrote {notes} about {}{place}{since}.", n.title)
}

fn first_upper(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().chain(c).collect()).unwrap_or_default()
}

/// "Someone on the team" mid-sentence; a name stays as written.
fn first_lower(s: &str) -> String {
    match s {
        "Someone on the team" | "Mail or a synced app" => {
            let mut c = s.chars();
            c.next().map(|f| f.to_lowercase().chain(c).collect()).unwrap_or_default()
        }
        name => name.to_string(),
    }
}

/// The one question a notice asks, put from the cue that fired it (a hard
/// cue first, else the latest that names something a person can answer
/// for): a contradicted decision — "Is “X” still the plan?"; a plan coming
/// due — "Is “X” still on for Friday?"; one past its day — "Was “X” done,
/// or does it need a new day?"; news about someone a plan is owed to —
/// "Does this change “X”?"; a watched page — "Does the change on example.com
/// matter for what you are working on?"; a build-up of decisions, plans or
/// requirements — about the latest. `None` when no cue names its thing.
pub fn question(cues: &[Signal]) -> Option<String> {
    asked(cues).map(|(_, q)| q)
}

/// The cue a notice asks about, and the question.
fn asked<'a>(cues: &'a [Signal]) -> Option<(&'a Signal, String)> {
    let ask = |c: &Signal| -> Option<String> {
        let what = clip(&c.what, 80);
        if what.is_empty() {
            return None;
        }
        Some(match c.kind.as_str() {
            "conflict" => format!("Is “{what}” still the plan?"),
            "due_soon" if c.due > 0.0 => format!("Is “{what}” still on for {}?", weekday_name(c.due)),
            "past_due" => format!("Was “{what}” done, or does it need a new day?"),
            "plan_cue" => format!("Does this change “{what}”?"),
            "page_change" => format!("Does the change on {what} matter for what you are working on?"),
            "decision" => format!("Is “{what}” settled?"),
            "plan" if c.due > 0.0 => format!("Is “{what}” still on for {}?", weekday_name(c.due)),
            "plan" => format!("Is “{what}” still on?"),
            "requirement" => format!("Does “{what}” still hold?"),
            _ => return None,
        })
    };
    let pair = |c: &'a Signal| ask(c).map(|q| (c, q));
    let found = cues.iter().filter(|c| c.hard).find_map(pair);
    found.or_else(|| cues.iter().rev().filter(|c| !c.hard).find_map(pair))
}

/// The weekday of an epoch time, in UTC.
fn weekday_name(at: f64) -> &'static str {
    const DAYS: [&str; 7] = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
    // The epoch was a Thursday.
    DAYS[((at / 86_400.0).floor() as i64 + 3).rem_euclid(7) as usize]
}

// ── Over `cookie serve` ───────────────────────────────────────────────────

fn verdict_json(v: &Verdict) -> Value {
    match v {
        Verdict::Wait => json!({"kind": "wait"}),
        Verdict::Drop => json!({"kind": "drop"}),
        Verdict::Fade => json!({"kind": "fade"}),
        Verdict::Notice(n) => {
            let mut notice = json!(n);
            notice["why_now"] = json!(why_now(n));
            json!({"kind": "notice", "notice": notice})
        }
    }
}

fn field<T: serde::de::DeserializeOwned>(m: &Value, k: &str) -> Result<T, String> {
    serde_json::from_value(m.get(k).cloned().unwrap_or(Value::Null)).map_err(|e| format!("`{k}`: {e}"))
}

/// One `attention` line from a client that keeps the state: `op` is
///
/// * `add` — `{subject?, write, owed?, team?, now}`: the write's signal joins
///   its subject (a new one when `subject` is absent); a hard cue is scored
///   at once with `team`.
/// * `signal` — `{subject?, branch?, about?, signal, team?, now}`: a signal the
///   client made (a contradicted decision, a plan past its day); a new
///   subject is made from `branch` and `about` when `subject` is absent.
/// * `classify` — `{event}`: one write event from the brain → `{skip, outside,
///   by_person}` (`skip`: Cookie wrote it, so it never wakes Cookie).
/// * `consider` — `{subject, team, now}`: score a waiting subject.
/// * `label` — `{subject, kinds, label, now}`: the team's label on a notice.
/// * `due` — `{plans, now}`: the hard cues held plans give now (coming due,
///   past their day) → `{cues: [{branch, about, signal}]}`; the client signals
///   each one it has not signalled before.
/// * `deliver` — `{moment, now}`: put a held notice in front of the team now?
///   → `{release, because?}`.
/// * `send` — `{person}`: send a released notice to this person now? →
///   `{send, why?, later?}` (`later`: quiet hours; try again after).
///
/// Replies `{subject, signal?, verdict?}`; the client stores `subject`. A
/// notice in a verdict carries `why_now`, the sentence it opens with, and
/// `question`, the one it ends with (`null`: hold it, ask nothing).
pub fn rpc(m: &Value) -> Result<Value, String> {
    let now = m.get("now").and_then(Value::as_f64).unwrap_or(0.0);
    let op = m.get("op").and_then(Value::as_str).unwrap_or_default();
    let team = || -> Result<Team, String> { Ok(m.get("team").map(|_| field(m, "team")).transpose()?.unwrap_or_default()) };
    match op {
        "add" | "signal" => {
            let (mut subject, signal) = if op == "add" {
                let write: Write = field(m, "write")?;
                let owed: Vec<(String, String, String)> = m.get("owed").map(|_| field(m, "owed")).transpose()?.unwrap_or_default();
                let subject = match m.get("subject").filter(|s| !s.is_null()) {
                    Some(_) => field(m, "subject")?,
                    None => Subject::new(&write.branch, &write.about, now),
                };
                (subject, signal_of(&write, &owed, now))
            } else {
                let subject = match m.get("subject").filter(|s| !s.is_null()) {
                    Some(_) => field(m, "subject")?,
                    None => {
                        let branch: String = m.get("branch").map(|_| field(m, "branch")).transpose()?.unwrap_or_default();
                        let about: Vec<String> = m.get("about").map(|_| field(m, "about")).transpose()?.unwrap_or_default();
                        Subject::new(&branch, &about, now)
                    }
                };
                (subject, field::<Signal>(m, "signal")?)
            };
            let hard = signal.hard;
            add(&mut subject, signal.clone(), now);
            let verdict = if hard { Some(consider(&mut subject, &team()?, now)) } else { None };
            Ok(json!({"subject": subject, "signal": signal, "verdict": verdict.as_ref().map(verdict_json)}))
        }
        "consider" => {
            let mut subject: Subject = field(m, "subject")?;
            let verdict = consider(&mut subject, &team()?, now);
            Ok(json!({"subject": subject, "verdict": verdict_json(&verdict)}))
        }
        "label" => {
            let mut subject: Subject = field(m, "subject")?;
            let kinds: Vec<String> = field(m, "kinds")?;
            let said: String = field(m, "label")?;
            label(&mut subject, &kinds, &said, now);
            Ok(json!({"subject": subject}))
        }
        "due" => {
            let plans: Vec<Plan> = field(m, "plans")?;
            let cues: Vec<Value> = due_cues(&plans, now)
                .into_iter()
                .map(|(p, signal)| json!({"branch": p.branch, "about": p.about, "signal": signal}))
                .collect();
            Ok(json!({"cues": cues}))
        }
        "deliver" => {
            let moment: Moment = field(m, "moment")?;
            Ok(match deliver(&moment, now) {
                Some(why) => json!({"release": true, "because": why}),
                None => json!({"release": false}),
            })
        }
        "send" => {
            let person: Person = field(m, "person")?;
            Ok(match send_to(&person) {
                Ok(()) => json!({"send": true}),
                Err(why) => json!({"send": false, "why": why, "later": why == "quiet hours"}),
            })
        }
        "classify" => {
            let event = m.get("event").cloned().unwrap_or(Value::Null);
            let outside = from_outside(&event);
            let named = |k: &str| event.get(k).and_then(Value::as_str).is_some_and(|v| !v.trim().is_empty());
            Ok(json!({"skip": by_cookie(&event), "outside": outside, "by_person": !outside && (named("member") || named("via"))}))
        }
        other => Err(format!("unknown attention op `{other}`")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_title_clipped_to_nothing_is_an_ellipsis_never_a_panic() {
        // Same shape as the gateway's clip_line underflow the fuzz test found on 2026-10-22.
        assert_eq!(clip("Tööäpäev", 0), "…");
        assert_eq!(clip("Tööäpäev", 1), "…");
        assert_eq!(clip("Tööäpäev kõne", 9), "Tööäpäev…");
        crate::fuzz::each(12, 5_000, |t| {
            for n in [0usize, 1, 3, 40] {
                assert!(clip(t, n).chars().count() <= n.max(1));
            }
        });
    }
    use serde_json::json;

    #[test]
    fn a_decision_outweighs_a_checkpoint_and_nothing_leaves_one_to_ten() {
        assert!(salience("decision", Some("critical"), None, false) > salience("checkpoint", Some("critical"), None, true));
        assert_eq!(salience("decision", Some("critical"), Some("surprising"), true), 10.0, "clamped");
        assert_eq!(salience("checkpoint", None, None, false), 1.0);
        assert_eq!(salience("something-new", None, None, false), 2.0);
    }

    #[test]
    fn a_level_halves_in_about_six_days() {
        let half = decayed(10.0, 24.0 * 5.8);
        assert!((half - 5.0).abs() < 0.2, "{half}");
        assert_eq!(decayed(10.0, -3.0), 10.0, "no growth backwards");
    }

    #[test]
    fn not_useful_fades_and_comes_back_over_weeks() {
        assert_eq!(habituation(0.5, 0.0), 0.5);
        assert!((habituation(0.5, 7.0) - 0.75).abs() < 1e-9);
        assert!(habituation(0.25, 60.0) > 0.99);
        assert_eq!(habituation(1.0, 0.0), 1.0);
    }

    #[test]
    fn a_subject_is_a_branch_and_what_a_write_is_about() {
        assert_eq!(subject_of("acme", &["Acme".into(), "Renewal".into()]), ("acme|renewal".into(), "Renewal · acme".into()));
        assert_eq!(subject_of("", &[]), ("main|*".into(), "main".into()));
        assert_eq!(subject_of("main", &[" ".into(), "Pricing".into()]).0, "main|pricing");
    }

    #[test]
    fn the_gate_wants_a_person_a_full_level_and_a_rest() {
        // Over the threshold, written by the team, never noticed: notice.
        assert!(utility(20.0, 18.0, true, None, 0) >= NOTICE_AT);
        // Synced mail alone, nobody on the team wrote: waits.
        assert!(utility(20.0, 18.0, false, None, 0) < NOTICE_AT);
        // Noticed an hour ago: waits.
        assert!(utility(20.0, 18.0, true, Some(1.0), 0) < NOTICE_AT);
        // Half full: waits.
        assert!(utility(9.0, 18.0, true, None, 0) < NOTICE_AT);
        // A pile of unlabelled notices pushes everything down.
        assert!(utility(18.0, 18.0, true, None, 10) < utility(18.0, 18.0, true, None, 0));
    }

    #[test]
    fn the_threshold_rises_when_notices_stop_helping() {
        assert_eq!(gain(3, 0), 1.0, "too few labels to judge");
        assert_eq!(gain(20, 10), 1.0);
        assert_eq!(gain(20, 2), 2.0, "clamped");
        assert_eq!(gain(20, 20), 0.5);
    }

    #[test]
    fn cookie_never_wakes_on_its_own_writes() {
        assert!(by_cookie(&json!({"member": "cookie:usr_1", "via": "api key: runtime"})));
        assert!(by_cookie(&json!({"via": "Cookie"})));
        assert!(!by_cookie(&json!({"member": "usr_1", "via": "Claude Code"})));
    }

    #[test]
    fn synced_mail_is_outside_and_a_tool_is_not() {
        assert!(from_outside(&json!({"verb": "ingest", "via": "gmail"})));
        assert!(!from_outside(&json!({"verb": "ingest", "via": "Claude Code"})));
        assert!(!from_outside(&json!({"verb": "remember", "via": "gmail"})));
    }

    #[test]
    fn the_branch_is_read_from_where_a_memory_lives() {
        assert_eq!(branch_in("mcp://agent/s/branch/cookie-enkeon/01M5"), "cookie-enkeon");
        assert_eq!(branch_in("mcp://agent/s/01M5"), "main");
        assert_eq!(branch_in(""), "main");
    }

    fn decision(id: &str) -> Write {
        Write {
            id: id.into(),
            kind: "decision".into(),
            weight: Some("critical".into()),
            name: format!("Decision {id}"),
            about: vec!["Renewal".into()],
            branch: "acme".into(),
            by_person: true,
            ..Write::default()
        }
    }

    fn acme(now: f64) -> Subject {
        Subject::new("acme", &["Renewal".into()], now)
    }

    #[test]
    fn a_build_up_notices_only_once_it_goes_quiet() {
        let team = Team::default();
        let mut s = acme(0.0);
        for (i, at) in [0.0, 60.0, 120.0].into_iter().enumerate() {
            add(&mut s, signal_of(&decision(&format!("m{i}")), &[], at), at);
        }
        assert!(s.level >= THRESHOLD, "{}", s.level);
        assert_eq!(consider(&mut s, &team, 180.0), Verdict::Wait, "still being written");
        let Verdict::Notice(n) = consider(&mut s, &team, 120.0 + QUIET) else { panic!("noticed once quiet") };
        assert!(!n.hard);
        assert_eq!(n.subject, "acme|renewal");
        assert_eq!(n.cues.len(), 3);
        assert!(n.utility >= NOTICE_AT);
        assert_eq!(s.level, 0.0);
        assert!(s.pending_since.is_none() && s.cues.is_empty());
        assert_eq!(s.last_noticed_at, Some(120.0 + QUIET));
    }

    #[test]
    fn the_same_write_counts_once() {
        let mut s = acme(0.0);
        add(&mut s, signal_of(&decision("m1"), &[], 0.0), 0.0);
        let level = s.level;
        add(&mut s, signal_of(&decision("m1"), &[], 10.0), 10.0);
        assert_eq!(s.level, level);
        assert_eq!(s.cues.len(), 1);
    }

    #[test]
    fn a_write_about_someone_owed_a_plan_notices_at_once() {
        let owed = vec![("renewal".to_string(), "p1".to_string(), "Send the renewal quote".to_string())];
        let cue = signal_of(&decision("m1"), &owed, 0.0);
        assert!(cue.hard);
        assert_eq!(cue.kind, "plan_cue");
        assert_eq!(cue.id, "m1:cue:p1");
        // The plan itself is not its own cue.
        assert!(!signal_of(&decision("p1"), &owed, 0.0).hard);

        let mut s = acme(0.0);
        add(&mut s, cue, 0.0);
        assert_eq!(s.level, 0.0, "a hard cue adds no level");
        let Verdict::Notice(n) = consider(&mut s, &Team::default(), 0.0) else { panic!("noticed at once") };
        assert!(n.hard);
    }

    #[test]
    fn a_spent_day_waits() {
        let mut s = acme(0.0);
        add(&mut s, Signal { id: "c1".into(), kind: "conflict".into(), salience: 10.0, by_person: true, hard: true, ..Signal::default() }, 0.0);
        let team = Team { noticed_today: DAILY_CAP, ..Team::default() };
        assert_eq!(consider(&mut s, &team, 0.0), Verdict::Wait);
        assert!(s.pending_since.is_some() && !s.cues.is_empty(), "kept for tomorrow");
    }

    #[test]
    fn a_crowded_recent_notice_drops_the_build_up() {
        let mut s = acme(0.0);
        s.last_noticed_at = Some(0.0);
        add(&mut s, Signal { id: "c1".into(), kind: "conflict".into(), salience: 10.0, by_person: true, hard: true, ..Signal::default() }, 0.0);
        let team = Team { open: 10, ..Team::default() };
        assert_eq!(consider(&mut s, &team, 0.0), Verdict::Drop);
        assert!(s.pending_since.is_none() && s.cues.is_empty());
    }

    #[test]
    fn a_build_up_that_never_crossed_fades_in_a_day() {
        let mut s = acme(0.0);
        let mut w = decision("m1");
        w.kind = "fact".into();
        w.weight = None;
        add(&mut s, signal_of(&w, &[], 0.0), 0.0);
        assert_eq!(consider(&mut s, &Team::default(), FADE - 1.0), Verdict::Wait);
        assert_eq!(consider(&mut s, &Team::default(), FADE), Verdict::Fade);
        assert!(s.pending_since.is_none() && s.cues.is_empty());
    }

    #[test]
    fn not_useful_halves_a_kind_and_useful_restores_it() {
        let mut s = acme(0.0);
        let kinds = vec!["decision".to_string(), "decision".to_string()];
        label(&mut s, &kinds, "not_useful", 0.0);
        assert_eq!(s.habituation["decision"].w, 0.5);
        label(&mut s, &kinds, "wrong", 0.0);
        assert_eq!(s.habituation["decision"].w, 0.25);
        add(&mut s, signal_of(&decision("m1"), &[], 0.0), 0.0);
        assert!((s.level - 9.0 * 0.25).abs() < 1e-9, "{}", s.level);
        label(&mut s, &kinds, "useful", 0.0);
        assert_eq!(s.habituation["decision"].w, 1.0);
    }

    #[test]
    fn plans_are_noticed_before_their_day_and_after_it_once_each() {
        let now = 1_000_000.0;
        let plan = |id: &str, due: f64| Plan { id: id.into(), name: format!("Quote for {id}"), due, branch: "acme".into(), to: Some("Anna".into()), ..Plan::default() };
        let cues = due_cues(&[plan("p1", now + 5.0 * 3600.0), plan("p2", now - 3600.0), plan("p3", now + 3.0 * 86_400.0), plan("p4", now - 5.0 * 86_400.0), plan("p5", 0.0)], now);
        let got: Vec<(&str, &str)> = cues.iter().map(|(_, s)| (s.id.as_str(), s.kind.as_str())).collect();
        assert_eq!(got, vec![("p1:soon", "due_soon"), ("p2:due", "past_due")]);
        assert_eq!(cues[0].1.why, "Due in 5 hours: Quote for p1 (owed to Anna)");
        assert!(cues.iter().all(|(_, s)| s.hard));
        let r = rpc(&json!({"op": "due", "now": now, "plans": [{"id": "p1", "name": "x", "due": now + 60.0}]})).unwrap();
        assert_eq!(r["cues"][0]["signal"]["why"], "Due within the hour: x");
    }

    #[test]
    fn a_notice_waits_for_a_break_but_not_forever() {
        let busy = Moment { since: 0.0, last_write_at: Some(100.0), jobs_running: 0, hard: false };
        assert_eq!(deliver(&busy, 200.0), None, "the team is mid-task");
        assert_eq!(deliver(&busy, 100.0 + BREAK_AFTER), Some("the team's work went quiet"));
        let working = Moment { last_write_at: None, jobs_running: 1, ..busy.clone() };
        assert_eq!(deliver(&working, 500.0), None, "Cookie is working for them");
        assert!(deliver(&Moment { hard: true, last_write_at: Some(HOLD_HARD - 1.0), ..busy.clone() }, HOLD_HARD).is_some(), "a hard cue waits half an hour at most");
        assert!(deliver(&Moment { last_write_at: Some(HOLD_MAX - 1.0), ..busy.clone() }, HOLD_MAX).is_some());
        assert_eq!(rpc(&json!({"op": "deliver", "now": 50.0, "moment": {"since": 0.0, "last_write_at": 40.0}})).unwrap()["release"], false);
    }

    #[test]
    fn a_notice_says_why_now() {
        let cue = |kind: &str, why: &str, hard: bool| Signal { kind: kind.into(), why: why.into(), hard, by_person: true, ..Signal::default() };
        let mut n = Notice { title: "Acme".into(), branch: "main".into(), cues: vec![cue("fact", "", false), cue("decision", "", false)], ..Notice::default() };
        assert_eq!(why_now(&n), "Your team wrote 2 notes about Acme.");
        // Who and when, only as far as the cues say.
        let thu = 1_793_275_200.0;
        n.cues[0].by = "Mara".into();
        n.cues[1].by = "Claude Code".into();
        n.cues[0].changed_at = thu;
        n.cues[1].changed_at = thu + 86_400.0;
        n.branch = "pricing".into();
        assert_eq!(why_now(&n), "Mara and Claude Code wrote 2 notes about Acme on the pricing branch since 29 October.");
        let synced = Notice { cues: vec![Signal { by_person: false, outside: true, ..cue("fact", "", false) }], ..n.clone() };
        assert_eq!(why_now(&synced), "A note about Acme on the pricing branch came in from mail or synced apps.");
        n.cues.push(cue("past_due", "Past its day: Quote", true));
        assert_eq!(why_now(&n), "Past its day: Quote");
    }

    /// The notice that confused the founder (2026-10-30): titled "main", a
    /// contradiction that never named who or where, and checkpoints listed
    /// as evidence. Now it names the decision, says who wrote what where and
    /// when, lists only the cue that fired, and ends on one question.
    #[test]
    fn a_contradiction_names_the_decision_who_where_and_when_and_lists_only_what_supports_it() {
        let now = 1_793_361_600.0;
        let mut s = Subject::new("main", &[], now);
        for i in 0..3 {
            let w = Write { id: format!("k{i}"), kind: "checkpoint".into(), name: format!("Checkpoint {i}: notch polish"), branch: "main".into(), by_person: true, ..Write::default() };
            add(&mut s, signal_of(&w, &[], now), now);
        }
        let conflict = Signal {
            id: "c1".into(), kind: "conflict".into(), hard: true, by_person: true, salience: 10.0,
            why: "The work makes the Home state floating and expanded".into(), what: "Idle Home stays a capsule".into(),
            by: "Claude Code".into(), changed_at: now, decided_by: "Mara".into(), decided_at: now - 18.0 * 86_400.0, ..Signal::default()
        };
        add(&mut s, conflict, now);
        let Verdict::Notice(n) = consider(&mut s, &Team::default(), now) else { panic!("a contradiction is noticed at once") };
        assert_eq!(n.title, "Idle Home stays a capsule", "named for what it is about, never the bare branch");
        assert_eq!(n.cues.len(), 1, "only the cue that fired it: {:?}", n.cues);
        assert_eq!(why_now(&n), "On 30 October, Claude Code wrote something that goes against the decision “Idle Home stays a capsule”, made by Mara on 12 October.");
        assert_eq!(n.question.as_deref(), Some("Is “Idle Home stays a capsule” still the plan?"));
        // What the client does not say is not said.
        let bare = Notice { branch: "home-redesign".into(), cues: vec![Signal { kind: "conflict".into(), hard: true, what: "Idle Home stays a capsule".into(), ..Signal::default() }], ..n.clone() };
        assert_eq!(why_now(&bare), "Someone on the team wrote something on the home-redesign branch that goes against the decision “Idle Home stays a capsule”.");
    }

    #[test]
    fn a_title_names_the_thing_never_a_bare_branch() {
        let named = |what: &str, kind: &str| Signal { kind: kind.into(), what: what.into(), ..Signal::default() };
        assert_eq!(title(&Subject::new("acme", &["Renewal".into()], 0.0), &[named("x", "decision")]), "Renewal");
        assert_eq!(title(&Subject::new("main", &[], 0.0), &[named("Move to Postgres", "decision")]), "Move to Postgres");
        assert_eq!(title(&Subject::new("main", &[], 0.0), &[named("", "fact")]), "new notes from the team");
        assert_eq!(title(&Subject::new("ops", &[], 0.0), &[]), "new notes on the ops branch");
        // Who wrote a write rides from the client's write to its cue.
        let r = rpc(&json!({"op": "add", "now": 5.0, "write": {"id": "m1", "kind": "decision", "name": "Price stays", "branch": "acme", "by": "Mara", "by_person": true}})).unwrap();
        assert_eq!((r["signal"]["by"].as_str(), r["signal"]["changed_at"].as_f64()), (Some("Mara"), Some(5.0)));
    }

    /// Every sentence a notice is built from, through the voice check.
    #[test]
    fn every_notice_template_reads_like_a_person_wrote_it() {
        let c = |kind: &str, hard: bool| Signal { kind: kind.into(), hard, what: "Send Anna the quote".into(), why: "w".into(), by_person: true, due: 1_793_361_600.0, ..Signal::default() };
        let mut texts = Vec::new();
        for kind in ["conflict", "due_soon", "past_due", "plan_cue", "page_change", "decision", "plan", "requirement"] {
            let hard = !matches!(kind, "decision" | "plan" | "requirement");
            texts.extend(question(&[c(kind, hard)]));
            let n = Notice { title: "Acme".into(), branch: "acme".into(), cues: vec![Signal { by: "Mara".into(), changed_at: 1.0, decided_by: "Ines".into(), decided_at: 2.0, ..c(kind, hard) }], ..Notice::default() };
            texts.push(why_now(&n));
        }
        texts.extend(due_cues(&[Plan { id: "p".into(), name: "Quote".into(), due: 100.0, to: Some("Anna".into()), ..Plan::default() }, Plan { id: "q".into(), name: "Quote".into(), due: 7_200.0, ..Plan::default() }], 3_600.0).into_iter().map(|(_, s)| s.why));
        texts.push(signal_of(&decision("m1"), &[("renewal".into(), "p1".into(), "Quote".into())], 0.0).why);
        texts.extend([title(&Subject::new("main", &[], 0.0), &[]), title(&Subject::new("ops", &[], 0.0), &[])]);
        texts.extend(["the team's work went quiet", "it could not wait for a quieter moment"].map(String::from));
        for t in texts {
            assert!(crate::cookie::voice::check(&t).is_empty(), "{t}: {:?}", crate::cookie::voice::check(&t));
        }
    }

    #[test]
    fn every_notice_asks_one_question_from_the_cue_that_fired_it() {
        let cue = |kind: &str, what: &str, hard: bool| Signal { kind: kind.into(), what: what.into(), hard, by_person: true, ..Signal::default() };
        // Friday 2026-10-30, noon UTC.
        let friday = 1_793_361_600.0;
        let q = |cues: Vec<Signal>| question(&cues);
        assert_eq!(q(vec![cue("conflict", "Price stays at €79", true)]).as_deref(), Some("Is “Price stays at €79” still the plan?"));
        assert_eq!(q(vec![Signal { due: friday, ..cue("due_soon", "Send Anna the quote", true) }]).as_deref(), Some("Is “Send Anna the quote” still on for Friday?"));
        assert_eq!(q(vec![cue("past_due", "Send Anna the quote", true)]).as_deref(), Some("Was “Send Anna the quote” done, or does it need a new day?"));
        assert_eq!(q(vec![cue("plan_cue", "Quote for Anna", true)]).as_deref(), Some("Does this change “Quote for Anna”?"));
        assert_eq!(q(vec![cue("page_change", "example.com", true)]).as_deref(), Some("Does the change on example.com matter for what you are working on?"));
        assert_eq!(q(vec![cue("decision", "Move to Postgres", false)]).as_deref(), Some("Is “Move to Postgres” settled?"));
        assert_eq!(q(vec![cue("plan", "Launch the beta", false)]).as_deref(), Some("Is “Launch the beta” still on?"));
        assert_eq!(q(vec![cue("requirement", "EU data stays in the EU", false)]).as_deref(), Some("Does “EU data stays in the EU” still hold?"));
        // The hard cue asks before any build-up; within a build-up, the latest that can be asked about.
        assert_eq!(q(vec![cue("decision", "A", false), cue("conflict", "B", true)]).as_deref(), Some("Is “B” still the plan?"));
        assert_eq!(q(vec![cue("decision", "A", false), cue("plan", "B", false), cue("fact", "C", false)]).as_deref(), Some("Is “B” still on?"));
        // Nothing to ask about: no question, and the notice is held.
        assert_eq!(q(vec![cue("fact", "Acme has 40 staff", false), cue("metric", "MRR", false)]), None);
        assert_eq!(q(vec![cue("conflict", "", true)]), None, "a cue that names nothing asks nothing");
        assert_eq!(q(vec![cue("due_soon", "x", true)]), None, "no day to ask about");
        assert_eq!(q(vec![]), None);
        let long = q(vec![cue("decision", &"word ".repeat(40), false)]).unwrap();
        assert!(long.chars().count() < 100 && long.ends_with("…” settled?"), "{long}");
    }

    #[test]
    fn a_noticed_subject_carries_its_question_and_its_cues_their_names() {
        let mut s = acme(0.0);
        let plans = [Plan { id: "p1".into(), name: "Quote for Anna".into(), due: 1_793_361_600.0, ..Plan::default() }];
        let (_, soon) = due_cues(&plans, 1_793_361_600.0 - 3600.0).remove(0);
        assert_eq!((soon.what.as_str(), soon.due), ("Quote for Anna", 1_793_361_600.0));
        add(&mut s, soon, 0.0);
        let Verdict::Notice(n) = consider(&mut s, &Team::default(), 0.0) else { panic!("a hard cue is noticed") };
        assert_eq!(n.question.as_deref(), Some("Is “Quote for Anna” still on for Friday?"));
        assert_eq!(signal_of(&decision("m1"), &[], 0.0).what, "Decision m1");
        let owed = [("renewal".to_string(), "p9".to_string(), "Renewal terms".to_string())];
        assert_eq!(signal_of(&decision("m1"), &owed, 0.0).what, "Renewal terms");
        // Over the wire, and a stored subject from before `what` still reads.
        let r = rpc(&json!({"op": "signal", "branch": "acme", "about": ["Renewal"], "now": 0.0,
            "signal": {"id": "c1", "kind": "conflict", "why": "w", "what": "Renewal at €79", "salience": 10.0, "hard": true, "by_person": true}})).unwrap();
        assert_eq!(r["verdict"]["notice"]["question"], "Is “Renewal at €79” still the plan?");
        let old: Subject = serde_json::from_value(json!({"key": "acme|renewal", "cues": [{"id": "x", "kind": "decision"}]})).unwrap();
        assert_eq!(old.cues[0].what, "");
    }

    #[test]
    fn a_person_is_sent_a_notice_outside_quiet_hours_and_three_a_day_at_most() {
        let at = |h: i64| Person { local_minutes: h * 60, quiet_from: 20, quiet_to: 8, ..Person::default() };
        assert_eq!(send_to(&at(10)), Ok(()));
        assert_eq!(send_to(&at(22)), Err("quiet hours"), "quiet spans midnight");
        assert_eq!(send_to(&at(3)), Err("quiet hours"));
        assert_eq!(send_to(&at(8)), Ok(()), "the window ends at eight");
        assert_eq!(send_to(&Person { sent_today: PER_PERSON_DAILY, ..at(10) }), Err("enough today"));
        assert_eq!(send_to(&Person { off: true, ..at(10) }), Err("off"));
        assert_eq!(send_to(&Person { local_minutes: 23 * 60, quiet_from: 0, quiet_to: 0, ..Person::default() }), Ok(()), "never quiet");
        assert_eq!(send_to(&Person { local_minutes: 13 * 60, quiet_from: 12, quiet_to: 14, ..Person::default() }), Err("quiet hours"));
        let r = rpc(&json!({"op": "send", "person": {"local_minutes": 1380, "quiet_from": 20, "quiet_to": 8}})).unwrap();
        assert_eq!((r["send"].as_bool(), r["later"].as_bool()), (Some(false), Some(true)));
    }

}
