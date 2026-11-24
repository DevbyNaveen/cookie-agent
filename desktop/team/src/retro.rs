//! The morning card: what the team did since yesterday, from the record.
//!
//! Every line is a count of things that happened, never a summary a model
//! wrote, and when nothing worth reading happened there is no card. A daily
//! "all good" trains the person to ignore the one morning it says something
//! real. Jobs done are context on a card that earned its place, never the
//! reason for one: a card needs a lesson learned, a failure, a promise past
//! its day, a correction pattern, or a gap worth a hire.
//!
//! - **Worth a look** (outcome learning): an agent whose replies the person
//!   graded not good at least a third of the time (five graded at least), or
//!   whose saved routine recipe turned itself off. Counts and which jobs,
//!   never the replies' text, and never an edit: the person keeps the pen.
//! - **A hire to consider** (`hire_gap`): requests Cookie did itself that
//!   keep falling in a lane no teammate covers.
//!
//! Posted once a day from 8:00 local, as Cookie's notice and at the end of Cookie's chat.
//!
//! Ported from the super console (gateway `chat/retro.rs`, `chat/learning.rs`).

use chrono::Timelike;
use serde::{Deserialize, Serialize};

use crate::experience::real;
use crate::front::COOKIE_ID;
use crate::store::{Job, JobStatus};
use crate::{util, Team};

/// The hour the card is posted, local.
pub const HOUR: u32 = 8;
/// When this process started: the card waits a minute after it, so a job
/// cut off when Cookie last closed is on the record before the day is read.
pub(crate) static STARTED: std::sync::LazyLock<u64> = std::sync::LazyLock::new(util::now);
const SETTLE_SECS: u64 = 60;
/// Graded replies before a ratio says anything.
const MIN_JUDGED: usize = 5;
const REJECT_SHARE: f32 = 0.34;
/// The window corrections and hire gaps are read over.
const WEEK: u64 = 7 * 86_400;
/// A hire lane or an agent raised is not raised again for this long.
const QUIET_FOR: u64 = 14 * 86_400;

/// One agent's quality signals over the week.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Signals {
    pub agent: String,
    pub good: usize,
    pub bad: usize,
    /// Jobs the person corrected while they ran.
    pub steered: usize,
    pub recipes_off: usize,
    /// The jobs graded not good, so the person can open them.
    pub bad_jobs: Vec<String>,
}

impl Signals {
    pub fn judged(&self) -> usize {
        self.good + self.bad
    }

    pub fn worth_raising(&self) -> bool {
        self.recipes_off > 0 || (self.judged() >= MIN_JUDGED && self.bad as f32 / self.judged() as f32 >= REJECT_SHARE)
    }
}

/// What the last day contained. Counts only.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Facts {
    pub done: usize,
    pub failed: Vec<(String, String)>,
    pub lessons: usize,
    pub promises_due: Vec<(String, String)>,
    pub waiting: usize,
    pub raised: Vec<Signals>,
    pub hire: Option<crate::hire_gap::HireProposal>,
}

impl Facts {
    pub fn nothing_worth_reading(&self) -> bool {
        self.failed.is_empty() && self.lessons == 0 && self.promises_due.is_empty() && self.raised.is_empty() && self.hire.is_none()
    }
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

/// The card, or nothing.
pub fn compose(f: &Facts, hour: u32) -> Option<String> {
    if f.nothing_worth_reading() {
        return None;
    }
    let mut lines = Vec::new();
    if f.done > 0 {
        lines.push(format!("- {} done", plural(f.done, "job", "jobs")));
    }
    if !f.failed.is_empty() {
        lines.push(format!("- {} hit a problem:", plural(f.failed.len(), "job", "jobs")));
        for (who, what) in f.failed.iter().take(3) {
            lines.push(format!("  · {who}: {}", util::clip(what, 90)));
        }
    }
    if f.lessons > 0 {
        lines.push(format!("- {} learned from what went wrong", plural(f.lessons, "lesson", "lessons")));
    }
    if !f.promises_due.is_empty() {
        lines.push(format!("- {} past its day:", plural(f.promises_due.len(), "promise", "promises")));
        for (who, what) in f.promises_due.iter().take(3) {
            lines.push(format!("  · {who}: {}", util::clip(what, 90)));
        }
    }
    if f.waiting > 0 {
        lines.push(format!("- {} waiting for your yes", plural(f.waiting, "request", "requests")));
    }
    for a in &f.raised {
        if a.judged() >= MIN_JUDGED {
            let pct = (100.0 * a.bad as f32 / a.judged() as f32).round() as u32;
            let mut l = format!("- Worth a look: {} had {} of {} graded replies marked not good this week ({pct}%)", a.agent, a.bad, a.judged());
            if a.steered > 0 {
                l.push_str(&format!(", and you corrected {} while they ran", plural(a.steered, "job", "jobs")));
            }
            l.push_str(". Read them before changing anything; this card never edits an agent for you.");
            lines.push(l);
        }
        if a.recipes_off > 0 {
            lines.push(format!("- {}: {} turned itself off after failing twice; the routine is learning it again.", a.agent, plural(a.recipes_off, "saved routine recipe", "saved routine recipes")));
        }
    }
    if let Some(h) = &f.hire {
        lines.push(format!("- A hire to consider: a {}. I did these myself because nobody on the team does them:", h.title));
        for e in &h.evidence {
            lines.push(format!("  · {}", util::clip(e, 90)));
        }
    }
    let head = if hour < 12 { "Overnight" } else { "The last 24 hours" };
    Some(format!("{head}\n{}", lines.join("\n")))
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Card {
    pub day: String,
    pub text: String,
    pub at: u64,
    /// Lanes and agents raised, with when, so they rest for two weeks.
    #[serde(default)]
    pub raised: Vec<(String, u64)>,
}

impl Team {
    fn retro_path(&self) -> std::path::PathBuf {
        self.paths.root.join("retro.json")
    }

    /// The latest card, if there was one.
    pub fn retro(&self) -> Option<Card> {
        let c: Card = util::read_json(&self.retro_path());
        (!c.text.is_empty()).then_some(c)
    }

    async fn retro_facts(&self, now: u64, rested: &[String]) -> Facts {
        let day_ago = now.saturating_sub(86_400);
        let week_ago = now.saturating_sub(WEEK);
        let today = chrono::Local::now().format("%Y-%m-%d").to_string();
        let mut f = Facts { waiting: self.pending_approvals().len(), ..Default::default() };
        let agents = self.agents().await;
        let mut cookie_did = Vec::new();
        for a in agents.iter().filter(|a| a.shadow_of.is_none()) {
            let jobs: Vec<Job> = util::read_jsonl(&self.paths.jobs(&a.id));
            let mut s = Signals { agent: a.name.clone(), ..Default::default() };
            for j in jobs.iter().filter(|j| real(j)) {
                if j.finished_at.unwrap_or(j.started_at) >= day_ago {
                    match j.status {
                        JobStatus::Done => f.done += 1,
                        JobStatus::Failed => f.failed.push((a.name.clone(), j.error.clone().unwrap_or_default())),
                        _ => {}
                    }
                }
                for p in j.promises.iter().filter(|p| p.state == "open" && p.due.as_str() < today.as_str()) {
                    f.promises_due.push((a.name.clone(), p.text.clone()));
                }
                if j.started_at >= week_ago {
                    match j.grade {
                        Some(g) if g > 0 => s.good += 1,
                        Some(_) => {
                            s.bad += 1;
                            s.bad_jobs.push(j.id.clone());
                        }
                        None => {}
                    }
                    if j.steered > 0 {
                        s.steered += 1;
                    }
                    if a.id == COOKIE_ID && j.status == JobStatus::Done && !j.tools.iter().any(|t| t == "message" || t == "ask_agent") {
                        cookie_did.push(j.input.clone());
                    }
                }
            }
            f.lessons += self.lessons(&a.id).iter().filter(|l| l.created_at as u64 >= day_ago).count();
            s.recipes_off = self.procedures(&a.id).values().filter(|p| !p.enabled && p.failures >= crate::procedures::MAX_FAILURES && p.updated_at >= day_ago.saturating_sub(WEEK)).count();
            if s.worth_raising() && !rested.contains(&format!("agent:{}", a.id)) {
                f.raised.push(s);
            }
        }
        let team: Vec<(String, String)> = agents.iter().filter(|a| a.id != COOKIE_ID && a.shadow_of.is_none()).map(|a| (a.name.clone(), a.job.clone())).collect();
        let recent: Vec<String> = rested.iter().filter_map(|r| r.strip_prefix("lane:").map(str::to_string)).collect();
        f.hire = crate::hire_gap::propose(&cookie_did, &team, &recent);
        f
    }

    /// Once a minute from the scheduler: post today's card when it is due.
    pub(crate) async fn maybe_post_retro(&self) {
        let now_local = chrono::Local::now();
        if now_local.hour() < HOUR || util::now() < *STARTED + SETTLE_SECS {
            return;
        }
        let day = now_local.format("%Y-%m-%d").to_string();
        let mut card: Card = util::read_json(&self.retro_path());
        if card.day == day {
            return;
        }
        let now = util::now();
        // Once a day too: lessons nobody used go quiet, then to the archive.
        for a in self.agents().await {
            self.curate_lessons(&a.id);
        }
        card.raised.retain(|(_, at)| now.saturating_sub(*at) < QUIET_FOR);
        let rested: Vec<String> = card.raised.iter().map(|(k, _)| k.clone()).collect();
        let facts = self.retro_facts(now, &rested).await;
        card.day = day;
        match compose(&facts, now_local.hour()) {
            Some(text) => {
                let ids: std::collections::HashMap<String, String> = self.agents().await.into_iter().map(|a| (a.name, a.id)).collect();
                for s in &facts.raised {
                    if let Some(id) = ids.get(&s.agent) {
                        card.raised.push((format!("agent:{id}"), now));
                    }
                }
                if let Some(h) = &facts.hire {
                    card.raised.push((format!("lane:{}", h.lane), now));
                }
                card.text = text.clone();
                card.at = now;
                let _ = util::write_json(&self.retro_path(), &card);
                let first = text.lines().nth(1).unwrap_or("").trim_start_matches("- ").to_string();
                self.notice(COOKIE_ID, "Your morning card", &first, None, false);
                self.emit(crate::events::TeamEvent::Retro);
            }
            // Nothing worth reading: no card today (yesterday's stays readable).
            None => {
                let _ = util::write_json(&self.retro_path(), &card);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_card_when_only_ordinary_work_happened() {
        assert!(compose(&Facts { done: 12, ..Default::default() }, 8).is_none(), "a day of jobs is not news");
        let f = Facts { done: 3, lessons: 1, ..Default::default() };
        let c = compose(&f, 8).unwrap();
        assert!(c.starts_with("Overnight") && c.contains("3 jobs done") && c.contains("1 lesson learned"));
        assert!(compose(&f, 15).unwrap().starts_with("The last 24 hours"), "an afternoon card doesn't say overnight");
    }

    #[test]
    fn worth_a_look_needs_enough_grades_and_never_quotes_a_reply() {
        let few = Signals { agent: "Ana".into(), bad: 2, good: 1, ..Default::default() };
        assert!(!few.worth_raising(), "three grades are not a trend");
        let many = Signals { agent: "Ana".into(), bad: 3, good: 3, steered: 2, bad_jobs: vec!["job-1".into()], ..Default::default() };
        assert!(many.worth_raising());
        let c = compose(&Facts { raised: vec![many], ..Default::default() }, 9).unwrap();
        assert!(c.contains("3 of 6") && c.contains("corrected 2 jobs") && c.contains("never edits"));
    }
}
