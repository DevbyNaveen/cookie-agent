//! Agents tested like employees.
//!
//! - Tests: a real job, graded good, becomes a test case (its input and what
//!   a good answer must do). Before a model or setup change, the agent's
//!   tests run on the candidate setup and a judge model grades each answer
//!   against the yardstick. Nothing a test does is real: every change is
//!   recorded and refused.
//! - Forks: a copy of an agent with one thing changed, working in shadow. It
//!   gets each of its parent's chat jobs, answers privately, and the person
//!   compares the pairs and promotes the better setup.

use std::sync::Arc;

use cookie_harness::{Agent, Message, Session};
use serde::Serialize;

use crate::events::TeamEvent;
use crate::store::{AgentRecord, Job, TestCase, TestResult, TestRun, Trigger};
use crate::{util, Team};

const JUDGE: &str = "You grade one answer an AI agent gave, against what a good answer must do. \
Be strict about the yardstick and lenient about wording. Reply with JSON only: \
{\"pass\": true|false, \"reason\": \"one plain sentence\"}.";

fn parse_verdict(raw: &str) -> Option<(bool, String)> {
    let v: serde_json::Value = serde_json::from_str(&raw[raw.find('{')?..=raw.rfind('}')?]).ok()?;
    Some((v["pass"].as_bool()?, v["reason"].as_str().unwrap_or("").trim().to_string()))
}

#[derive(Debug, Clone, Serialize)]
pub struct ShadowPair {
    pub input: String,
    pub parent_job: String,
    pub parent_answer: String,
    pub fork_answer: String,
    pub fork_would: usize,
    pub at: u64,
}

impl Team {
    pub fn tests(&self, agent: &str) -> Vec<TestCase> {
        util::read_json(&self.paths.tests(agent))
    }

    fn save_tests(&self, agent: &str, t: &[TestCase]) -> Result<(), String> {
        util::write_json(&self.paths.tests(agent), t)
    }

    /// Turn a real job into a test. `expect` is what a good answer must do.
    pub fn save_test(&self, agent: &str, input: &str, expect: &str, from_job: Option<&str>) -> Result<TestCase, String> {
        if input.trim().is_empty() || expect.trim().is_empty() {
            return Err("A test needs an input and what a good answer does.".into());
        }
        let reference = from_job.and_then(|id| util::read_jsonl::<Job>(&self.paths.jobs(agent)).into_iter().find(|j| j.id == id)).map(|j| j.answer);
        let case = TestCase {
            id: util::new_id("test"),
            input: input.trim().to_string(),
            expect: expect.trim().to_string(),
            reference,
            from_job: from_job.map(str::to_string),
            created_at: util::now(),
        };
        let mut all = self.tests(agent);
        all.push(case.clone());
        self.save_tests(agent, &all)?;
        Ok(case)
    }

    pub fn delete_test(&self, agent: &str, id: &str) -> Result<(), String> {
        let mut all = self.tests(agent);
        all.retain(|t| t.id != id);
        self.save_tests(agent, &all)
    }

    pub fn test_runs(&self, agent: &str) -> Vec<TestRun> {
        let mut runs: Vec<TestRun> = std::fs::read_dir(self.paths.test_runs(agent))
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| std::fs::read(e.path()).ok().and_then(|b| serde_json::from_slice(&b).ok()))
            .collect();
        runs.sort_by_key(|r: &TestRun| std::cmp::Reverse(r.started_at));
        runs
    }

    /// Run the agent's tests on `model` (or its own). Progress comes as events.
    pub async fn run_tests(self: &Arc<Self>, agent: &str, model: Option<String>) -> Result<String, String> {
        let mut rec = self.agent(agent).await?;
        let cases = self.tests(agent);
        if cases.is_empty() {
            return Err("This agent has no tests yet. Grade a good answer and save it as a test.".into());
        }
        if let Some(m) = model.filter(|m| !m.trim().is_empty()) {
            Agent::new(m.trim()).map_err(|e| e.to_string())?;
            rec.model = m.trim().to_string();
        }
        let judge_model = self.settings().await.checker_model.unwrap_or_else(|| rec.model.clone());
        let run_id = util::new_id("run");
        let mut run = TestRun { id: run_id.clone(), agent: agent.to_string(), model: rec.model.clone(), version: rec.version, started_at: util::now(), finished_at: None, results: Vec::new() };
        let team = self.clone();
        let total = cases.len();
        let rid = run_id.clone();
        tokio::spawn(async move {
            for (i, case) in cases.iter().enumerate() {
                let result = team.run_case(&rec, case, &judge_model).await;
                run.results.push(result);
                team.emit(TeamEvent::TestProgress { run: rid.clone(), agent: rec.id.clone(), done: i + 1, total });
            }
            run.finished_at = Some(util::now());
            let passed = run.results.iter().filter(|r| r.pass).count();
            let _ = util::write_json(&team.paths.test_runs(&rec.id).join(format!("{rid}.json")), &run);
            team.emit(TeamEvent::TestFinished { run: rid, agent: rec.id.clone(), passed, total });
        });
        Ok(run_id)
    }

    async fn run_case(self: &Arc<Self>, rec: &AgentRecord, case: &TestCase, judge_model: &str) -> TestResult {
        // The candidate runs as a throwaway copy: same tools and walls, nothing real.
        let mut probe = rec.clone();
        probe.id = format!("{}--test", rec.id);
        let job = match self.run_probe_job(&probe, &case.input, Trigger::Test { case: case.id.clone() }, None).await {
            Ok(j) if j.status == crate::JobStatus::Done => j,
            Ok(j) => return TestResult { case: case.id.clone(), pass: false, reason: format!("It didn't finish: {}", j.error.unwrap_or_else(|| "stopped".into())), answer: String::new() },
            Err(e) => return TestResult { case: case.id.clone(), pass: false, reason: format!("It didn't finish: {e}"), answer: String::new() },
        };
        let (pass, reason) = self.judge_answer(judge_model, &case.input, &case.expect, case.reference.as_deref(), &job.answer).await;
        TestResult { case: case.id.clone(), pass, reason, answer: util::clip(&job.answer, 8000) }
    }

    /// A judge's grade of one answer against what a good one must do (and a reference, if any).
    pub(crate) async fn judge_answer(&self, judge_model: &str, input: &str, expect: &str, reference: Option<&str>, answer: &str) -> (bool, String) {
        let judge = match Agent::new(judge_model) {
            Ok(a) => a.instructions(JUDGE).without_enkeon(),
            Err(e) => return (false, format!("The judge couldn't start: {e}")),
        };
        let mut s = Session::in_memory();
        let prompt = format!(
            "The task:\n{}\n\nWhat a good answer must do:\n{}\n\n{}The answer to grade:\n{}",
            input,
            expect,
            reference.map(|r| format!("An answer graded good before (for reference, not to copy):\n{}\n\n", util::clip(r, 4000))).unwrap_or_default(),
            util::clip(answer, 8000)
        );
        match judge.run_in(&mut s, Message::user(prompt), &cookie_harness::CancellationToken::new()).await.map_err(|e| e.to_string()).and_then(|raw| parse_verdict(&raw).ok_or_else(|| "the judge's answer couldn't be read".to_string())) {
            Ok(v) => v,
            Err(e) => (false, format!("Not graded: {e}")),
        }
    }

    /// One run of a temporary copy (a probe): a scratch copy of its folder,
    /// skills and notes; every change it would make recorded and refused;
    /// `tuning` when the copy runs with other settings.
    pub(crate) async fn run_probe_job(self: &Arc<Self>, probe: &AgentRecord, input: &str, trigger: Trigger, tuning: Option<crate::tuning::Tuning>) -> Result<crate::store::Job, String> {
        let original = crate::bench::original(&probe.id).to_string();
        let home = self.paths.agent(&probe.id);
        let _ = std::fs::remove_dir_all(&home);
        copy_dir(&self.paths.work(&original), &self.paths.work(&probe.id)).map_err(|e| e.to_string())?;
        for part in ["skills", "NOTES.md"] {
            let src = self.paths.agent(&original).join(part);
            if src.exists() {
                let _ = crate::sleep::clone_path(&src, &home.join(part));
            }
        }
        if let Some(t) = &tuning {
            util::write_json(&home.join("tuning.json"), t)?;
        }
        let mut agents = self.agents.write().await;
        agents.retain(|a| a.id != probe.id);
        agents.push(probe.clone());
        drop(agents);
        let job = self.run_and_wait(&probe.id, input.to_string(), Vec::new(), trigger).await;
        self.agents.write().await.retain(|a| a.id != probe.id);
        let _ = std::fs::remove_dir_all(&home);
        self.traces.lock().unwrap().remove(&probe.id);
        job
    }

    /* ---------- forks ---------- */

    /// Copy an agent with a new model (or job wording) and run it in shadow.
    pub async fn fork(&self, agent: &str, model: Option<String>, job: Option<String>) -> Result<AgentRecord, String> {
        let parent = self.agent(agent).await?;
        if let Some(m) = &model {
            Agent::new(m.trim()).map_err(|e| e.to_string())?;
        }
        let mut f = parent.clone();
        f.id = util::new_id(&format!("{} fork", parent.name));
        f.name = format!("{} (fork)", parent.name);
        f.model = model.map(|m| m.trim().to_string()).unwrap_or(parent.model.clone());
        if let Some(j) = job.filter(|j| !j.trim().is_empty()) {
            f.job = j.trim().to_string();
        }
        f.parent = Some(parent.id.clone());
        f.shadow_of = Some(parent.id.clone());
        f.created_at = util::now();
        f.version = 1;
        let f = self.add_agent(f).await?;
        let _ = copy_dir(&self.paths.work(&parent.id), &self.paths.work(&f.id));
        Ok(f)
    }

    pub async fn forks_of(&self, agent: &str) -> Vec<AgentRecord> {
        self.agents().await.into_iter().filter(|a| a.shadow_of.as_deref() == Some(agent)).collect()
    }

    /// Each parent job beside the fork's shadow answer to it, newest first.
    pub fn compare(&self, parent: &str, fork: &str) -> Vec<ShadowPair> {
        let parents: Vec<Job> = util::read_jsonl(&self.paths.jobs(parent));
        let mut out: Vec<ShadowPair> = util::read_jsonl::<Job>(&self.paths.jobs(fork))
            .into_iter()
            .filter_map(|fj| {
                let Trigger::Shadow { of_job } = &fj.trigger else { return None };
                let pj = parents.iter().find(|p| &p.id == of_job)?;
                Some(ShadowPair {
                    input: pj.input.clone(),
                    parent_job: pj.id.clone(),
                    parent_answer: pj.answer.clone(),
                    fork_answer: if fj.answer.is_empty() { fj.error.clone().unwrap_or_default() } else { fj.answer.clone() },
                    fork_would: fj.approvals.len(),
                    at: fj.finished_at.unwrap_or(fj.started_at),
                })
            })
            .collect();
        out.reverse();
        out
    }

    /// The fork won: its model and job become the parent's, and the fork goes.
    pub async fn promote(self: &Arc<Self>, fork: &str) -> Result<AgentRecord, String> {
        let f = self.agent(fork).await?;
        let parent = f.shadow_of.clone().ok_or("That agent isn't a fork.")?;
        let updated = self.update(&parent, crate::Patch { model: Some(f.model.clone()), job: Some(f.job.clone()), ..Default::default() }).await?;
        self.fire(fork, false).await?;
        Ok(updated)
    }
}

fn copy_dir(from: &std::path::Path, to: &std::path::Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    if !from.exists() {
        return Ok(());
    }
    for e in std::fs::read_dir(from)? {
        let e = e?;
        let t = e.file_type()?;
        if t.is_dir() {
            copy_dir(&e.path(), &to.join(e.file_name()))?;
        } else if t.is_file() {
            std::fs::copy(e.path(), to.join(e.file_name()))?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::parse_verdict;

    #[test]
    fn verdicts_parse_or_refuse() {
        assert_eq!(parse_verdict("ok {\"pass\": true, \"reason\": \"Covers it.\"}"), Some((true, "Covers it.".into())));
        assert_eq!(parse_verdict("{\"reason\": \"x\"}"), None);
        assert_eq!(parse_verdict("nope"), None);
    }
}
