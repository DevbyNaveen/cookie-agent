//! Each agent learns from its own work, and every lesson has to keep
//! earning its place.
//!
//! - **Lessons from what went wrong, with no model call.** A finished job
//!   already says what happened: which call failed and why (`outcome`), or
//!   that it hit its limit after many calls. A lesson is composed from those
//!   facts only, so every word of it traces to the record. Most jobs leave
//!   none: a clean job is the expected case, and "it worked" is not
//!   knowledge. When a lesson did not help (the same call failed the same
//!   way again), it is replaced by one that says to stop trying that call.
//! - **Offered only while it helps.** A later job that looks alike may carry
//!   it. Whether it does is a Thompson draw between the lesson's record and
//!   the agent's own jobs that carried no lesson (the harness's `lessons`
//!   bandit). The job's outcome scores each lesson it carried; a job the
//!   person grades not good turns that win into a loss. A losing lesson is
//!   offered less and less often, never removed by the bandit.
//! - **Curated, never deleted.** Unused 14 days, a lesson goes quiet; 30,
//!   archived. The person can archive or restore any lesson.
//!
//! Ported from the super console (gateway `chat/experience.rs`,
//! `chat/selection.rs`) onto the harness's `lessons`.

use std::sync::Arc;

use cookie_harness::lessons::{self, Arm, Lesson, SplitMix64};
use serde_json::{json, Value};

use crate::outcome::{self, FailureKind};
use crate::store::{Job, JobStatus, Trigger};
use crate::{util, Team};

/// How much of the job a lesson quotes back, so it can be recognised.
const TASK_CLIP: usize = 120;
/// The window the agent's own baseline is read over.
const BASELINE_DAYS: u64 = 30;
/// A job cut off after at least this many calls teaches "batch the work".
const CUT_OFF_CALLS: usize = 8;

/// The jobs that count as the agent's own work (not tests, shadows or reviews).
pub(crate) fn real(j: &Job) -> bool {
    !matches!(j.trigger, Trigger::Test { .. } | Trigger::Shadow { .. } | Trigger::Review) && j.status != JobStatus::Running
}

fn clip(s: &str, n: usize) -> String {
    let s = s.trim();
    let mut out: String = s.chars().take(n).collect();
    if s.chars().count() > n {
        out.push('…');
    }
    out
}

/// What a failure teaches, or nothing. `None` for a no from the person, a
/// stopped run, the rules holding, or a passing outage: none of those would
/// make the next job go differently.
fn failure_lesson(kind: FailureKind, tool: &str) -> Option<String> {
    match kind {
        FailureKind::UnknownTool => Some(format!("`{tool}` isn't one of your tools; check the tools you have before calling one")),
        FailureKind::BadArguments => Some(format!("`{tool}` rejected the arguments it was sent; read what it needs and match it exactly")),
        FailureKind::Refused => Some(format!("`{tool}` needs a permission you don't have; tell the person which one instead of trying again")),
        FailureKind::Declined | FailureKind::Blocked | FailureKind::NotRun | FailureKind::Upstream => None,
    }
}

/// Compose the one lesson a finished job leaves, or nothing. `prior_same`:
/// earlier jobs that failed on the same call the same way.
pub fn compose(task: &str, job: &Job, prior_same: u32) -> Option<(String, String)> {
    let task = clip(task, TASK_CLIP);
    if task.is_empty() {
        return None;
    }
    if let Some((kind, tool)) = outcome::failing(&job.steps) {
        let what = failure_lesson(kind, &tool)?;
        if prior_same >= 1 {
            let times = prior_same + 1;
            return Some((
                format!(
                    "On \"{task}\": `{tool}` has now failed the same way ({}) {times} times, despite the earlier lesson. \
                     Don't call it again for this; say plainly which call fails and who must act, then do the part of the job that doesn't need it.",
                    kind.as_str()
                ),
                task,
            ));
        }
        return Some((format!("On \"{task}\": {what}."), task));
    }
    if job.cut_off && job.steps.len() >= CUT_OFF_CALLS {
        return Some((
            format!(
                "On \"{task}\": stopped at its limit after {} tool calls without finishing; this kind of job needs fewer, larger steps (batch the work) instead of one call per item.",
                job.steps.len()
            ),
            task,
        ));
    }
    None
}

impl Team {
    fn lessons_path(&self, agent: &str) -> std::path::PathBuf {
        self.paths.agent(agent).join("lessons.json")
    }

    pub fn lessons(&self, agent: &str) -> Vec<Lesson> {
        util::read_json(&self.lessons_path(agent))
    }

    pub(crate) fn save_lessons(&self, agent: &str, l: &[Lesson]) -> Result<(), String> {
        util::write_json(&self.lessons_path(agent), &l)
    }

    /// The agent's own jobs that carried no lesson, last 30 days: its baseline.
    pub(crate) fn baseline(&self, agent: &str, text: &str) -> Arm {
        let since = util::now().saturating_sub(BASELINE_DAYS * 86_400);
        let jobs: Vec<Job> = util::read_jsonl(&self.paths.jobs(agent));
        let history: Vec<(String, bool)> = jobs
            .iter()
            .filter(|j| real(j) && j.started_at >= since && !j.lessons.iter().any(|p| p.offered))
            // Only endings something outside the agent judged: unknown is neither a win nor a loss.
            .filter_map(|j| outcome::end_state(j).learned().map(|won| (j.input.clone(), won)))
            .collect();
        let wins = history.iter().filter(|(_, c)| *c).count() as i64;
        let pooled = Arm { wins, losses: history.len() as i64 - wins };
        lessons::baseline_for(text, &history, pooled)
    }

    /// The lessons a job gets, and the block for its instructions.
    pub(crate) fn pick_lessons(&self, agent: &str, text: &str) -> (Vec<lessons::Picked>, Option<String>) {
        let mut held = self.lessons(agent);
        if held.is_empty() {
            return (Vec::new(), None);
        }
        let (picked, block) = lessons::pick(text, &held, self.baseline(agent, text), false, &mut SplitMix64::from_time());
        let now = util::now() as f64;
        for p in &picked {
            if let Some(l) = held.iter_mut().find(|l| l.id == p.id) {
                if p.offered {
                    l.last_used_at = Some(now);
                } else {
                    l.withheld += 1;
                }
            }
        }
        let _ = self.save_lessons(agent, &held);
        let block = block.map(|_| {
            let given: Vec<String> = picked.iter().filter(|p| p.offered).filter_map(|p| held.iter().find(|l| l.id == p.id)).map(|l| format!("- {}", l.text)).collect();
            format!(
                "What you learned on jobs like this one (from your own past jobs: things that went wrong, not guesses; where two disagree, the newer holds):\n{}\nUse one only if it fits this job.",
                given.join("\n")
            )
        });
        (picked, block)
    }

    /// After a job: score the lessons it carried, and keep the one it taught.
    pub(crate) fn learn_from(&self, agent: &str, job: &Job) -> Option<Lesson> {
        if !real(job) || job.status == JobStatus::Stopped {
            return None;
        }
        let mut held = self.lessons(agent);
        // A lesson is scored only on an ending the world or the person judged.
        if let Some(won) = outcome::end_state(job).learned() {
            for p in job.lessons.iter().filter(|p| p.offered) {
                if let Some(l) = held.iter_mut().find(|l| l.id == p.id) {
                    lessons::score(l, won);
                }
            }
        }
        // Earlier jobs that failed on this same call, this same way.
        let failing = outcome::failing(&job.steps);
        let prior_same = failing.as_ref().map_or(0, |(kind, tool)| {
            util::read_jsonl::<Job>(&self.paths.jobs(agent))
                .iter()
                .filter(|j| j.id != job.id && real(j))
                .filter(|j| outcome::failing(&j.steps).is_some_and(|(k, t)| k == *kind && t == *tool))
                .count() as u32
        });
        let mut added = None;
        if let Some((text, cue)) = compose(&job.input, job, prior_same) {
            if lessons::screen(&text).is_none() {
                let live: Vec<&str> = held.iter().filter(|l| l.state != "archived").map(|l| l.text.as_str()).collect();
                match lessons::duplicate_of(&text, &live) {
                    // The same lesson again: it is still true; it stays as it is.
                    Some(_) if prior_same == 0 => {}
                    // A lesson that didn't help: the newer one replaces it.
                    dup => {
                        if let Some(i) = dup {
                            let old = live[i].to_string();
                            if let Some(l) = held.iter_mut().find(|l| l.text == old) {
                                l.state = "archived".into();
                            }
                        }
                        let l = Lesson {
                            id: util::new_id("lesson"),
                            text,
                            cue,
                            state: "active".into(),
                            wins: 0,
                            losses: 0,
                            withheld: 0,
                            last_used_at: None,
                            created_at: util::now() as f64,
                            outside: !matches!(job.trigger, Trigger::Chat | Trigger::Welcome | Trigger::Routine { .. } | Trigger::Telegram { .. } | Trigger::Channel { .. } | Trigger::Inbox | Trigger::Memory { .. } | Trigger::Goal { .. } | Trigger::Promise { .. } | Trigger::Watch { .. }),
                            kind: "lesson".into(),
                        };
                        held.push(l.clone());
                        added = Some(l);
                    }
                }
            }
        }
        let _ = self.save_lessons(agent, &held);
        added
    }

    /// The person graded a job not good: its lessons' wins become losses.
    pub(crate) fn rescore_lessons(&self, agent: &str, job: &Job) {
        if outcome::end_state(&Job { grade: None, ..job.clone() }).learned() != Some(true) {
            return; // it was already scored a loss, or never scored
        }
        let mut held = self.lessons(agent);
        for p in job.lessons.iter().filter(|p| p.offered) {
            if let Some(l) = held.iter_mut().find(|l| l.id == p.id) {
                lessons::rescore_as_loss(l);
            }
        }
        let _ = self.save_lessons(agent, &held);
    }

    /// Daily: quiet and archive what isn't used.
    pub(crate) fn curate_lessons(&self, agent: &str) {
        let mut held = self.lessons(agent);
        let now = util::now() as f64;
        if held.iter_mut().fold(false, |any, l| lessons::curate(l, now) | any) {
            let _ = self.save_lessons(agent, &held);
        }
    }

    /// The person archives or restores a lesson.
    pub fn set_lesson(&self, agent: &str, id: &str, state: &str) -> Result<(), String> {
        if !matches!(state, "active" | "archived") {
            return Err("A lesson is active or archived.".into());
        }
        let mut held = self.lessons(agent);
        let l = held.iter_mut().find(|l| l.id == id).ok_or("No such lesson.")?;
        l.state = state.into();
        if state == "active" {
            l.last_used_at = Some(util::now() as f64);
        }
        self.save_lessons(agent, &held)
    }

    /// Lessons as surfaces show them: record, and whether it beats the baseline.
    pub fn lessons_view(&self, agent: &str) -> Vec<Value> {
        let base = self.baseline(agent, "");
        let mut v: Vec<Value> = self
            .lessons(agent)
            .into_iter()
            .map(|l| {
                let proven = lessons::proven(l.arm(), base);
                json!({"id": l.id, "text": l.text, "state": l.state, "wins": l.wins, "losses": l.losses, "withheld": l.withheld, "created_at": l.created_at, "last_used_at": l.last_used_at, "proven": proven})
            })
            .collect();
        v.sort_by(|a, b| b["created_at"].as_f64().unwrap_or(0.0).total_cmp(&a["created_at"].as_f64().unwrap_or(0.0)));
        v
    }
}

/// The block of tools that have been working and failing, from the record.
pub(crate) fn tool_block(team: &Arc<Team>, agent: &str) -> Option<String> {
    let since = util::now().saturating_sub(outcome::RECORD_DAYS * 86_400);
    let jobs: Vec<Job> = util::read_jsonl(&team.paths.jobs(agent));
    let b = outcome::tool_record_block(&outcome::tool_records(&jobs, since));
    (!b.is_empty()).then_some(b)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::outcome::Step;

    fn job(input: &str, steps: Vec<Step>, cut_off: bool) -> Job {
        Job { input: input.into(), steps, cut_off, status: JobStatus::Done, answer: "done".into(), ..Default::default() }
    }

    fn bad(tool: &str, kind: &str) -> Step {
        Step { tool: tool.into(), failed: true, kind: Some(kind.into()) }
    }

    #[test]
    fn a_lesson_comes_only_from_a_fact_that_would_change_the_next_job() {
        assert!(compose("weekly report", &job("weekly report", vec![], false), 0).is_none(), "a clean job teaches nothing");
        assert!(compose("x", &job("x", vec![bad("send_email", "declined")], false), 0).is_none(), "a no is not a lesson");
        assert!(compose("x", &job("x", vec![bad("read_url", "upstream")], false), 0).is_none(), "weather is not a lesson");
        let (l, cue) = compose("file the receipts", &job("file the receipts", vec![bad("mac_files_write", "bad_arguments")], false), 0).unwrap();
        assert!(l.contains("`mac_files_write` rejected the arguments") && cue == "file the receipts");
        let (again, _) = compose("file the receipts", &job("", vec![bad("mac_files_write", "bad_arguments")], false), 1).unwrap();
        assert!(again.contains("2 times") && again.contains("Don't call it again"));
        let many: Vec<Step> = (0..9).map(|_| Step { tool: "read_url".into(), failed: false, kind: None }).collect();
        assert!(compose("read every page", &job("", many, true), 0).unwrap().0.contains("batch the work"));
    }

    #[test]
    fn lessons_are_scored_by_the_jobs_that_carried_them() {
        let dir = tempfile::tempdir().unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let team = rt.block_on(async { Team::open(dir.path()).unwrap() });
        std::fs::create_dir_all(team.paths.agent("a")).unwrap();
        let failed = Job { id: "j1".into(), agent: "a".into(), ..job("file the receipts into the folder", vec![bad("mac_files_write", "bad_arguments")], false) };
        let l = team.learn_from("a", &failed).expect("a lesson");
        assert_eq!(team.lessons("a").len(), 1);
        // A later job carries it and only finishes: nothing said it was right, so nothing is scored.
        let carried = lessons::Picked { id: l.id.clone(), offered: true };
        let finished = Job { id: "j2".into(), agent: "a".into(), lessons: vec![carried.clone()], ..job("file the receipts", vec![], false) };
        team.learn_from("a", &finished);
        assert_eq!((team.lessons("a")[0].wins, team.lessons("a")[0].losses), (0, 0), "finishing is not a win");
        // One the world showed right: a win.
        let clean = Job { id: "j3".into(), verified_by: Some("the file is in the folder".into()), ..finished };
        team.learn_from("a", &clean);
        assert_eq!(team.lessons("a")[0].wins, 1);
        // The person says it wasn't good: the win becomes a loss.
        team.rescore_lessons("a", &clean);
        let after = &team.lessons("a")[0];
        assert_eq!((after.wins, after.losses), (0, 1));
        team.set_lesson("a", &l.id, "archived").unwrap();
        assert_eq!(team.lessons("a")[0].state, "archived");
    }
}
