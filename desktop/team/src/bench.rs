//! The Cookie bench: 30 to 50 of your own real jobs, and the exam every change
//! to an agent must pass.
//!
//! **The bench** is chosen from what your agents actually did: jobs that
//! finished cleanly (an answer, nothing failed, not cut off, not graded "not
//! good"), asked in your own words (chat, routines, channels), long enough to
//! stand on their own. Jobs you graded good come first; near-duplicates are
//! dropped; every agent gets its share. Each case keeps the accepted answer
//! as its reference, and the yardstick from the agent's own test when there is
//! one. You can drop any case; it never comes back. Fewer than 30 good jobs
//! means a smaller bench, said as it is — never padded with made-up tasks.
//!
//! **An exam** runs some cases on a copy of an agent with one thing changed
//! (its model, its tuning) and on the agent as it is, side by side, and a
//! judge grades each answer against the case's yardstick and reference. A copy
//! is a probe: its own scratch folder, reads of the agent's memory but no
//! saves, every change it would make recorded and refused.
//!
//! **Racing copies share one cache.** The copies of one agent in an exam send
//! the same instructions and tools byte for byte (no copy's id or folder in
//! them), so the provider's prompt cache holds one prefix for all of them: the
//! first case runs alone and writes it, the rest run three at a time and read
//! it.

use std::sync::Arc;

use futures::StreamExt;
use serde::{Deserialize, Serialize};

use crate::store::{Job, JobStatus, Trigger};
use crate::tuning::Tuning;
use crate::{util, Team};

pub const TARGET: usize = 50;
pub const ENOUGH: usize = 30;
/// Copies of one agent working at once in an exam.
const RACE: usize = 3;
const SAME_JOB: f64 = 0.8;

/// A probe is a throwaway copy of an agent: `<agent>--test` (its tests) or
/// `<agent>--exam-<n>` (an exam). It never counts as a teammate.
pub fn is_probe(id: &str) -> bool {
    id.ends_with("--test") || id.contains("--exam-")
}

/// The agent a probe copies.
pub fn original(id: &str) -> &str {
    id.strip_suffix("--test").or_else(|| id.split_once("--exam-").map(|(a, _)| a)).unwrap_or(id)
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct BenchCase {
    pub id: String,
    pub agent: String,
    pub input: String,
    /// The answer the agent gave and you accepted.
    pub reference: String,
    /// What a good answer must do.
    pub expect: String,
    pub from_job: String,
    /// You graded the job good.
    pub graded_good: bool,
    pub added_at: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
struct BenchFile {
    cases: Vec<BenchCase>,
    /// Jobs you took off the bench: never chosen again.
    removed: Vec<String>,
    built_at: u64,
}

/// What an exam changes in the copy.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Variant {
    pub model: Option<String>,
    pub tuning: Option<Tuning>,
    /// Its skills changed (`autoskills`): some taken away, some added, some edited.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skills: Option<crate::autoskills::SkillDelta>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct CaseResult {
    pub case: String,
    pub pass: bool,
    pub reason: String,
    pub microdollars: u64,
    pub tokens: u64,
    pub cache_read_tokens: u64,
    pub ms: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Side {
    pub passed: usize,
    pub total: usize,
    pub microdollars: u64,
    pub tokens: u64,
    pub results: Vec<CaseResult>,
}

impl Side {
    fn add(&mut self, r: CaseResult) {
        self.passed += usize::from(r.pass);
        self.total += 1;
        self.microdollars += r.microdollars;
        self.tokens += r.tokens;
        self.results.push(r);
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Exam {
    pub id: String,
    pub agent: String,
    pub what: String,
    pub variant: Variant,
    /// What the "before" side ran with, when not the agent as it is.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub baseline: Option<Variant>,
    pub before: Side,
    pub after: Side,
    pub started_at: u64,
    pub finished_at: u64,
}

/// What the exam says about the change.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    /// As good or better, and no dearer (or clearly better for a little more).
    Keep,
    /// As good, for clearly less: worth offering when it is a model change.
    Cheaper,
    Drop,
}

/// Paired on the same cases: a change is kept only when it passes at least
/// as many, and costs no more than 5% extra unless it passes more. When no
/// price is known, cost is read in tokens.
pub fn verdict(before: &Side, after: &Side) -> Verdict {
    if after.total == 0 || before.total == 0 || after.total != before.total {
        return Verdict::Drop;
    }
    let (b, a) = if before.microdollars > 0 && after.microdollars > 0 { (before.microdollars as f64, after.microdollars as f64) } else { (before.tokens as f64, after.tokens as f64) };
    if after.passed < before.passed {
        return Verdict::Drop;
    }
    if after.passed == before.passed && a <= b * 0.7 {
        return Verdict::Cheaper;
    }
    if after.passed > before.passed && a <= b * 1.25 {
        return Verdict::Keep;
    }
    if a <= b * 1.05 {
        return Verdict::Keep;
    }
    Verdict::Drop
}

/// The jobs fit for the bench, best first.
pub fn candidates(agent: &str, jobs: &[Job], removed: &[String]) -> Vec<BenchCase> {
    let mut out: Vec<BenchCase> = Vec::new();
    let mut picked: Vec<&Job> = jobs
        .iter()
        .filter(|j| matches!(j.trigger, Trigger::Chat | Trigger::Routine { .. } | Trigger::Channel { .. } | Trigger::Telegram { .. }))
        .filter(|j| j.status == JobStatus::Done && crate::outcome::clean(j) && !j.cut_off && j.steered == 0)
        .filter(|j| {
            let words = j.input.split_whitespace().count();
            words >= 4 && j.input.chars().count() <= 4_000 && !j.answer.trim().is_empty()
        })
        .filter(|j| !removed.contains(&j.id))
        .collect();
    // Graded good first, then the newest.
    picked.sort_by(|a, b| (b.grade == Some(1)).cmp(&(a.grade == Some(1))).then(b.started_at.cmp(&a.started_at)));
    for j in picked {
        if out.iter().any(|c| cookie_harness::lessons::similarity(&c.input, &j.input) >= SAME_JOB) {
            continue;
        }
        out.push(BenchCase {
            id: format!("bench-{}", j.id),
            agent: agent.into(),
            input: j.input.clone(),
            reference: util::clip(&j.answer, 6_000),
            expect: String::new(),
            from_job: j.id.clone(),
            graded_good: j.grade == Some(1),
            added_at: util::now(),
        });
    }
    out
}

/// Every agent its share of `target`, then the rest to whoever has more.
pub fn share(mut per_agent: Vec<Vec<BenchCase>>, target: usize) -> Vec<BenchCase> {
    let n = per_agent.iter().filter(|c| !c.is_empty()).count().max(1);
    let fair = (target / n).max(1);
    let mut out = Vec::new();
    for list in per_agent.iter_mut() {
        let take = fair.min(list.len());
        out.extend(list.drain(..take));
    }
    let mut more = true;
    while out.len() < target && more {
        more = false;
        for list in per_agent.iter_mut() {
            if out.len() >= target {
                break;
            }
            if !list.is_empty() {
                out.push(list.remove(0));
                more = true;
            }
        }
    }
    out
}

const DEFAULT_EXPECT: &str = "Does what was asked as fully and correctly as the reference answer (which the person accepted), with nothing invented; it may be worded differently.";

impl Team {
    fn bench_path(&self) -> std::path::PathBuf {
        self.paths.root.join("bench.json")
    }

    fn exams_dir(&self, agent: &str) -> std::path::PathBuf {
        self.paths.agent(agent).join("exams")
    }

    pub fn bench(&self) -> Vec<BenchCase> {
        util::read_json::<BenchFile>(&self.bench_path()).cases
    }

    pub fn bench_for(&self, agent: &str) -> Vec<BenchCase> {
        self.bench().into_iter().filter(|c| c.agent == agent).collect()
    }

    /// Choose the bench again from the record (kept cases stay first).
    pub async fn build_bench(&self) -> Result<serde_json::Value, String> {
        let mut file: BenchFile = util::read_json(&self.bench_path());
        let agents: Vec<_> = self.agents().await.into_iter().filter(|a| a.shadow_of.is_none() && !is_probe(&a.id)).collect();
        let mut per: Vec<Vec<BenchCase>> = Vec::new();
        for a in &agents {
            let jobs: Vec<Job> = util::read_jsonl(&self.paths.jobs(&a.id));
            // The yardsticks the agent's own tests already wrote, by job.
            let tests = self.tests(&a.id);
            let mut list: Vec<BenchCase> = file.cases.iter().filter(|c| c.agent == a.id && jobs.iter().any(|j| j.id == c.from_job)).cloned().collect();
            for c in candidates(&a.id, &jobs, &file.removed) {
                if list.iter().any(|k| k.from_job == c.from_job || cookie_harness::lessons::similarity(&k.input, &c.input) >= SAME_JOB) {
                    continue;
                }
                list.push(c);
            }
            for c in list.iter_mut() {
                c.expect = tests.iter().find(|t| t.from_job.as_deref() == Some(c.from_job.as_str())).map(|t| t.expect.clone()).unwrap_or_else(|| DEFAULT_EXPECT.into());
            }
            per.push(list);
        }
        file.cases = share(per, TARGET);
        file.built_at = util::now();
        util::write_json(&self.bench_path(), &file)?;
        Ok(self.bench_view())
    }

    pub fn bench_view(&self) -> serde_json::Value {
        let file: BenchFile = util::read_json(&self.bench_path());
        serde_json::json!({
            "cases": file.cases,
            "count": file.cases.len(),
            "enough": file.cases.len() >= ENOUGH,
            "target": TARGET,
            "built_at": (file.built_at > 0).then_some(file.built_at),
        })
    }

    /// Take a case off the bench for good.
    pub fn drop_bench_case(&self, id: &str) -> Result<(), String> {
        let mut file: BenchFile = util::read_json(&self.bench_path());
        let Some(c) = file.cases.iter().find(|c| c.id == id).cloned() else { return Err("No such case.".into()) };
        file.cases.retain(|x| x.id != id);
        file.removed.push(c.from_job);
        util::write_json(&self.bench_path(), &file)
    }

    pub fn exams(&self, agent: &str) -> Vec<Exam> {
        let mut v: Vec<Exam> = std::fs::read_dir(self.exams_dir(agent))
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| serde_json::from_slice(&std::fs::read(e.path()).ok()?).ok())
            .collect();
        v.sort_by_key(|e: &Exam| std::cmp::Reverse(e.started_at));
        v
    }

    /// Run `cases` on the agent as it is and on a copy with `variant`, paired.
    pub async fn exam(self: &Arc<Self>, agent: &str, what: &str, cases: Vec<BenchCase>, variant: Variant) -> Result<Exam, String> {
        self.exam_between(agent, what, cases, Variant::default(), variant).await
    }

    /// Run `cases` on two copies of the agent, `baseline` and `variant`, paired.
    pub async fn exam_between(self: &Arc<Self>, agent: &str, what: &str, cases: Vec<BenchCase>, baseline: Variant, variant: Variant) -> Result<Exam, String> {
        let rec = self.agent(agent).await?;
        if cases.is_empty() {
            return Err("No bench cases for this agent yet.".into());
        }
        if let Some(m) = &variant.model {
            cookie_harness::Agent::new(m).map_err(|e| e.to_string())?;
        }
        // One judge for both sides: the checker model, else the agent's own (never the candidate's).
        let judge = self.settings().await.checker_model.unwrap_or_else(|| rec.model.clone());
        let mut exam = Exam {
            id: util::new_id("exam"),
            agent: agent.into(),
            what: what.into(),
            variant: variant.clone(),
            baseline: (baseline != Variant::default()).then(|| baseline.clone()),
            started_at: util::now(),
            ..Exam::default()
        };
        for (side, v) in [(0usize, baseline), (1, variant)] {
            let results = self.race(&rec, &cases, &v, &judge, side).await;
            for r in results {
                if side == 0 { exam.before.add(r) } else { exam.after.add(r) }
            }
        }
        exam.finished_at = util::now();
        let _ = util::write_json(&self.exams_dir(agent).join(format!("{}.json", exam.id)), &exam);
        Ok(exam)
    }

    /// The copies race: the first case alone (it writes the cache), the rest three at a time.
    async fn race(self: &Arc<Self>, rec: &crate::store::AgentRecord, cases: &[BenchCase], v: &Variant, judge: &str, side: usize) -> Vec<CaseResult> {
        let mut out = Vec::new();
        let slot = |i: usize| format!("{}--exam-{}", rec.id, side * RACE + i % RACE);
        if let Some(first) = cases.first() {
            out.push(self.exam_case(rec, first, v, judge, &slot(0)).await);
        }
        let rest: Vec<(usize, BenchCase)> = cases.iter().skip(1).cloned().enumerate().collect();
        let mut stream = futures::stream::iter(rest.into_iter().map(|(i, c)| {
            let (team, rec, v, judge, id) = (self.clone(), rec.clone(), v.clone(), judge.to_string(), slot(i));
            async move { team.exam_case(&rec, &c, &v, &judge, &id).await }
        }))
        .buffer_unordered(RACE);
        while let Some(r) = stream.next().await {
            out.push(r);
        }
        out
    }

    async fn exam_case(self: &Arc<Self>, rec: &crate::store::AgentRecord, case: &BenchCase, v: &Variant, judge: &str, probe_id: &str) -> CaseResult {
        let mut probe = rec.clone();
        probe.id = probe_id.to_string();
        if let Some(m) = &v.model {
            probe.model = m.clone();
        }
        let tuning = v.tuning.clone().unwrap_or_else(|| self.tuning(&rec.id));
        let began = std::time::Instant::now();
        let job = match self.run_probe_job_with(&probe, &case.input, Trigger::Test { case: case.id.clone() }, Some(tuning), v.skills.as_ref()).await {
            Ok(j) => j,
            Err(e) => return CaseResult { case: case.id.clone(), pass: false, reason: format!("It didn't finish: {e}"), ms: began.elapsed().as_millis() as u64, ..CaseResult::default() },
        };
        let ms = began.elapsed().as_millis() as u64;
        let (pass, reason) = if job.status == JobStatus::Done {
            self.judge_answer(judge, &case.input, &case.expect, Some(&case.reference), &job.answer).await
        } else {
            (false, format!("It didn't finish: {}", job.error.clone().unwrap_or_else(|| "stopped".into())))
        };
        CaseResult { case: case.id.clone(), pass, reason, microdollars: job.microdollars, tokens: job.tokens, cache_read_tokens: job.cache_read_tokens, ms }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job(id: &str, input: &str, grade: Option<i8>, at: u64) -> Job {
        Job { id: id.into(), agent: "a".into(), trigger: Trigger::Chat, input: input.into(), started_at: at, finished_at: Some(at + 5), status: JobStatus::Done, answer: "Here it is.".into(), grade, ..Job::default() }
    }

    #[test]
    fn only_clean_standalone_jobs_and_graded_good_first() {
        let mut failed = job("f", "Summarise the March invoices for Acme", None, 5);
        failed.status = JobStatus::Failed;
        let mut bad = job("b", "Write the weekly update for the team", Some(-1), 6);
        bad.grade = Some(-1);
        let jobs = vec![job("1", "Summarise the March invoices for Acme please", None, 10), job("2", "yes do it", None, 11), job("3", "Draft a reply to Mara about pricing", Some(1), 1), failed, bad, job("4", "Summarise the March invoices for Acme please", None, 12)];
        let c = candidates("a", &jobs, &[]);
        let ids: Vec<&str> = c.iter().map(|c| c.from_job.as_str()).collect();
        assert_eq!(ids, vec!["3", "4"], "graded good first; a reply too short to stand alone, failures, a not-good and a duplicate left out");
        assert!(candidates("a", &jobs, &["3".into()]).iter().all(|c| c.from_job != "3"), "a dropped case never comes back");
    }

    #[test]
    fn every_agent_gets_its_share() {
        let mk = |a: &str, n: usize| (0..n).map(|i| BenchCase { id: format!("{a}{i}"), agent: a.into(), ..BenchCase::default() }).collect::<Vec<_>>();
        let out = share(vec![mk("a", 40), mk("b", 3), mk("c", 0)], 10);
        assert_eq!(out.len(), 10);
        assert_eq!(out.iter().filter(|c| c.agent == "b").count(), 3);
        assert_eq!(share(vec![mk("a", 2)], 50).len(), 2, "never padded");
    }

    #[test]
    fn a_change_must_pass_at_least_as_much() {
        let s = |passed, total, cost| Side { passed, total, microdollars: cost, tokens: 0, results: vec![] };
        assert_eq!(verdict(&s(8, 10, 1000), &s(7, 10, 100)), Verdict::Drop, "cheaper but worse");
        assert_eq!(verdict(&s(8, 10, 1000), &s(8, 10, 600)), Verdict::Cheaper);
        assert_eq!(verdict(&s(8, 10, 1000), &s(9, 10, 1200)), Verdict::Keep);
        assert_eq!(verdict(&s(8, 10, 1000), &s(8, 10, 1300)), Verdict::Drop, "same, dearer");
        assert_eq!(verdict(&s(8, 10, 1000), &s(8, 9, 900)), Verdict::Drop, "not the same cases");
    }

    #[test]
    fn probes_name_their_agent() {
        assert!(is_probe("sorter--exam-2") && is_probe("sorter--test") && !is_probe("sorter"));
        assert_eq!(original("sorter--exam-2"), "sorter");
        assert_eq!(original("sorter--test"), "sorter");
        assert_eq!(original("sorter"), "sorter");
    }
}
