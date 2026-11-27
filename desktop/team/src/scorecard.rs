//! An agent's track record, read from what it actually did. No number here is
//! estimated: with no jobs there is no score, only "no record yet".

use serde::Serialize;

use crate::store::{Job, JobStatus, Trigger};
use crate::{util, Team};

#[derive(Debug, Clone, Serialize, Default)]
pub struct Scorecard {
    pub jobs: usize,
    pub done: usize,
    pub failed: usize,
    pub stopped: usize,
    /// Jobs the person graded good / not good.
    pub graded_good: usize,
    pub graded_bad: usize,
    /// Approvals asked, said yes to, said no to.
    pub asked: usize,
    pub yes: usize,
    pub no: usize,
    /// On probation or in shadow: changes recorded instead of made.
    pub would: usize,
    pub promises_open: usize,
    pub promises_kept: usize,
    pub promises_missed: usize,
    /// Promises past their day that nobody marked yet.
    pub promises_due: usize,
    pub tokens: u64,
    /// Millionths of a dollar, all time and this month (only with prices set).
    pub microdollars: u64,
    pub month_microdollars: u64,
    pub handoffs_in: usize,
    pub handoffs_out: usize,
    pub last_job_at: Option<u64>,
}

pub fn score(jobs: &[Job], month_microdollars: u64, today: &str) -> Scorecard {
    let mut s = Scorecard { month_microdollars, ..Default::default() };
    for j in jobs.iter().filter(|j| !matches!(j.trigger, Trigger::Test { .. } | Trigger::Review)) {
        s.jobs += 1;
        match j.status {
            JobStatus::Done => s.done += 1,
            JobStatus::Failed => s.failed += 1,
            JobStatus::Stopped => s.stopped += 1,
            // Waiting on the person is neither done nor failed yet.
            JobStatus::Running | JobStatus::NeedsYou => {}
        }
        match j.grade {
            Some(g) if g > 0 => s.graded_good += 1,
            Some(_) => s.graded_bad += 1,
            None => {}
        }
        for a in &j.approvals {
            match a.outcome.as_str() {
                "yes" => { s.asked += 1; s.yes += 1 }
                "no" => { s.asked += 1; s.no += 1 }
                _ => s.would += 1,
            }
        }
        for p in &j.promises {
            match p.state.as_str() {
                "kept" => s.promises_kept += 1,
                "missed" => s.promises_missed += 1,
                _ if p.due.as_str() < today => s.promises_due += 1,
                _ => s.promises_open += 1,
            }
        }
        if matches!(j.trigger, Trigger::Handoff { .. }) {
            s.handoffs_in += 1;
        }
        s.handoffs_out += j.tools.iter().filter(|t| *t == "ask_agent").count();
        s.tokens += j.tokens;
        s.microdollars += j.microdollars;
        s.last_job_at = s.last_job_at.max(j.finished_at);
    }
    s
}

impl Team {
    pub fn scorecard(&self, agent: &str) -> Scorecard {
        let jobs: Vec<Job> = util::read_jsonl(&self.paths.jobs(agent));
        score(&jobs, self.month_spend(agent), &chrono::Local::now().format("%Y-%m-%d").to_string())
    }

    /// Promises not yet marked, across the team, soonest first (the "promised" board).
    pub async fn open_promises(&self) -> Vec<serde_json::Value> {
        let mut out = Vec::new();
        for a in self.agents().await {
            for j in util::read_jsonl::<Job>(&self.paths.jobs(&a.id)) {
                for (i, p) in j.promises.iter().enumerate().filter(|(_, p)| p.state == "open") {
                    out.push(serde_json::json!({"agent": a.id, "agent_name": a.name, "job": j.id, "index": i, "text": p.text, "due": p.due}));
                }
            }
        }
        out.sort_by(|a, b| a["due"].as_str().cmp(&b["due"].as_str()));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{ApprovalRecord, PromiseRecord};

    fn job(status: JobStatus, grade: Option<i8>, approvals: &[&str], promise: Option<(&str, &str)>) -> Job {
        Job {
            id: util::new_id("j"), agent: "a".into(), trigger: Trigger::Chat, input: "x".into(), started_at: 1, finished_at: Some(2),
            status, answer: String::new(), error: None, tools: vec![],
            approvals: approvals.iter().map(|o| ApprovalRecord { tool: "t".into(), effect: "outbound".into(), preview: String::new(), outcome: o.to_string(), checker: None }).collect(),
            promises: promise.map(|(due, state)| vec![PromiseRecord { text: "p".into(), due: due.into(), state: state.into(), fired: false }]).unwrap_or_default(),
            tokens: 10, microdollars: 5, grade, version: 1, ..Default::default()
        }
    }

    #[test]
    fn counts_only_what_happened() {
        assert_eq!(score(&[], 0, "2026-11-23").jobs, 0);
        let s = score(
            &[
                job(JobStatus::Done, Some(1), &["yes", "no"], Some(("2026-11-20", "open"))),
                job(JobStatus::Failed, Some(-1), &["would"], Some(("2026-12-01", "open"))),
                job(JobStatus::Done, None, &[], Some(("2026-11-01", "kept"))),
            ],
            15,
            "2026-11-23",
        );
        assert_eq!((s.jobs, s.done, s.failed), (3, 2, 1));
        assert_eq!((s.graded_good, s.graded_bad), (1, 1));
        assert_eq!((s.asked, s.yes, s.no, s.would), (2, 1, 1, 1));
        assert_eq!((s.promises_due, s.promises_open, s.promises_kept), (1, 1, 1));
        assert_eq!(s.microdollars, 15);
    }
}
