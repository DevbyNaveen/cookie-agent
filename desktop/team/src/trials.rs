//! Every change an agent keeps to itself goes live on trial.
//!
//! A skill edit that won its exam is still only a guess about real work: the
//! exam is a handful of cases. So it goes live with a review date, and the
//! jobs that used it are read against the jobs that used the skill before it
//! changed, by how they ended as the world judged them (`outcome::end_state`:
//! shown right, or corrected or failed; unknown counts for nothing). If the
//! change does clearly worse, it is put back by itself and the person is told
//! why; at the review date it is kept, and that is said too. Without enough
//! judged jobs either side, nothing is concluded: it stays on trial until the
//! review date, then it is kept as the exam decided.

use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::outcome::{end_state, wilson};
use crate::store::Job;
use crate::{util, Team};

/// How long a change is on trial.
pub const TRIAL_DAYS: u64 = 14;
/// Judged jobs each side needs before a change can be put back.
const ENOUGH: usize = 5;
const TICK: Duration = Duration::from_secs(3600);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Trial {
    pub id: String,
    pub agent: String,
    pub skill: String,
    /// The version to put back.
    pub before: String,
    pub what: String,
    pub started_at: u64,
    pub review_at: u64,
    /// `on_trial`, `kept`, `reverted`.
    pub state: String,
    #[serde(default)]
    pub note: String,
}

/// (right, judged) among `jobs` that used `skill`, within [from, to).
fn record(jobs: &[Job], skill: &str, from: u64, to: u64) -> (usize, usize) {
    let used: Vec<&Job> = jobs.iter().filter(|j| j.started_at >= from && j.started_at < to && j.skills.iter().any(|s| s == skill)).collect();
    let judged: Vec<bool> = used.iter().filter_map(|j| end_state(j).learned()).collect();
    (judged.iter().filter(|w| **w).count(), judged.len())
}

/// Clearly worse: the after side's best case is below the before side's worst case.
pub fn clearly_worse(before: (usize, usize), after: (usize, usize)) -> bool {
    if before.1 < ENOUGH || after.1 < ENOUGH {
        return false;
    }
    let (b_low, _) = wilson(before.0 as i64, before.1 as i64);
    let (_, a_high) = wilson(after.0 as i64, after.1 as i64);
    a_high < b_low
}

impl Team {
    fn trials_path(&self) -> std::path::PathBuf {
        self.paths.root.join("trials.json")
    }

    pub fn trials(&self) -> Vec<Trial> {
        util::read_json(&self.trials_path())
    }

    fn save_trials(&self, all: &[Trial]) {
        let _ = util::write_json(&self.trials_path(), &all);
    }

    /// A kept change goes live on trial.
    pub(crate) fn start_trial(&self, agent: &str, skill: &str, before: &str, what: &str) {
        let mut all = self.trials();
        let now = util::now();
        all.push(Trial { id: util::new_id("trial"), agent: agent.into(), skill: skill.into(), before: before.into(), what: util::clip(what, 300), started_at: now, review_at: now + TRIAL_DAYS * 86_400, state: "on_trial".into(), note: String::new() });
        self.save_trials(&all);
    }

    /// Reads every trial against its record; puts back what did clearly worse, keeps what reached its date.
    pub(crate) fn review_trials(&self) {
        let now = util::now();
        let mut all = self.trials();
        let mut changed = false;
        for t in all.iter_mut().filter(|t| t.state == "on_trial") {
            let jobs: Vec<Job> = util::read_jsonl(&self.paths.jobs(&t.agent));
            let window = t.started_at.saturating_sub(30 * 86_400);
            let before = record(&jobs, &t.skill, window, t.started_at);
            let after = record(&jobs, &t.skill, t.started_at, now + 1);
            if clearly_worse(before, after) {
                match self.undo_skill_change(&t.agent, &t.skill, &t.before) {
                    Ok(()) => {
                        t.state = "reverted".into();
                        t.note = format!("Put back: {} of {} right after the change, {} of {} before.", after.0, after.1, before.0, before.1);
                        self.notice(&t.agent, &format!("A change to {} was put back", t.skill), &format!("{} {}", t.what, t.note), None, false);
                    }
                    Err(e) => t.note = format!("It should be put back but couldn't be: {e}"),
                }
                changed = true;
            } else if now >= t.review_at {
                t.state = "kept".into();
                t.note = format!("Kept after its trial: {} of {} right after the change, {} of {} before.", after.0, after.1, before.0, before.1);
                changed = true;
            }
        }
        if changed {
            self.save_trials(&all);
        }
    }
}

pub(crate) fn spawn(team: Arc<Team>) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(TICK);
        loop {
            tick.tick().await;
            team.review_trials();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::JobStatus;

    #[test]
    fn only_a_clear_drop_puts_a_change_back() {
        assert!(!clearly_worse((9, 10), (3, 4)), "too few after: no conclusion");
        assert!(clearly_worse((18, 20), (1, 10)), "18 of 20 right before, 1 of 10 after");
        assert!(!clearly_worse((7, 10), (6, 10)), "a little lower is noise");
    }

    #[test]
    fn a_change_that_does_clearly_worse_is_found_and_one_at_its_date_is_kept() {
        let dir = tempfile::tempdir().unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let team = rt.block_on(async { Team::open(dir.path()).unwrap() });
        let now = util::now();
        let job = |i: u64, at: u64, right: bool| Job {
            id: format!("j{i}"), agent: "a".into(), started_at: at, finished_at: Some(at + 1), status: JobStatus::Done, answer: "x".into(),
            skills: vec!["reports".into()], grade: Some(if right { 1 } else { -1 }), ..Default::default()
        };
        let mut jobs: Vec<Job> = (0..20).map(|i| job(i, now - 10 * 86_400 + i, true)).collect();
        jobs.extend((20..30).map(|i| job(i, now - 86_400 + i, false)));
        assert_eq!(record(&jobs, "reports", now - 30 * 86_400, now - 2 * 86_400), (20, 20));
        assert!(clearly_worse(record(&jobs, "reports", now - 30 * 86_400, now - 2 * 86_400), record(&jobs, "reports", now - 2 * 86_400, now)));
        // A trial past its date with nothing against it is kept.
        team.save_trials(&[Trial { id: "t".into(), agent: "a".into(), skill: "reports".into(), before: "v1".into(), started_at: now - 20 * 86_400, review_at: now - 1, state: "on_trial".into(), ..Default::default() }]);
        team.review_trials();
        assert_eq!(team.trials()[0].state, "kept");
    }
}
