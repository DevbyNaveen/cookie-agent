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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Notice {
    pub subject: String,
    pub title: String,
    pub branch: String,
    pub hard: bool,
    pub utility: f64,
    pub level: f64,
    pub cues: Vec<Signal>,
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
        format!("{}…", s.chars().take(n - 1).collect::<String>().trim_end())
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
    let notice = Notice {
        subject: subject.key.clone(),
        title: subject.title.clone(),
        branch: subject.branch.clone(),
        hard,
        utility: score,
        level,
        cues: std::mem::take(&mut subject.cues),
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

// ── Over `cookie serve` ───────────────────────────────────────────────────

fn verdict_json(v: &Verdict) -> Value {
    match v {
        Verdict::Wait => json!({"kind": "wait"}),
        Verdict::Drop => json!({"kind": "drop"}),
        Verdict::Fade => json!({"kind": "fade"}),
        Verdict::Notice(n) => json!({"kind": "notice", "notice": n}),
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
///
/// Replies `{subject, signal?, verdict?}`; the client stores `subject`.
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
}
