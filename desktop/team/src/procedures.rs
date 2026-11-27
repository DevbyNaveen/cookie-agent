//! A routine that did its job keeps the recipe.
//!
//! A routine runs the same task on a schedule, so "the same job" is true by
//! construction: the routine is the key. When a routine's job ends clean, the
//! calls that worked (in order, with the arguments that worked) are kept as
//! its recipe, with any rejected arguments for the same tool as "don't call
//! it like this". The next run carries the recipe: it executes instead of
//! working it all out again, adjusting only dates and periods.
//!
//! - Kept only from a job that ended clean; a mistake the job fixed itself
//!   is forgiven (and remembered as what to avoid).
//! - Every clean run keeps the newest recipe, so a change in an app heals
//!   on the first success.
//! - Two runs in a row that fail while following it turn it off; the routine
//!   works it out from scratch again, and learns again. Never deleted; the
//!   person can turn it back on or off.
//! - When the agent's tools change, the recipe sits out one run so the
//!   agent finds its way with what it has now.
//!
//! Ported from the super console (gateway `chat/procedures.rs`).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::outcome::{self, Step};
use crate::store::{Job, Trigger};
use crate::{util, Team};

/// Failed runs in a row before a recipe turns itself off.
pub const MAX_FAILURES: u32 = 2;
/// A run with more calls than this was exploring, not following a method.
const MAX_STEPS: usize = 200;
/// Arguments longer than this are not kept in a recipe (the content of a
/// file or a message is the day's, not the method's).
const ARG_CHARS: usize = 600;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Procedure {
    pub routine: String,
    pub task: String,
    /// `[{tool, input, avoid?}]`.
    pub steps: Value,
    pub learned_from: String,
    pub toolkit: String,
    pub successes: u32,
    pub failures: u32,
    pub enabled: bool,
    pub updated_at: u64,
}

/// A short fingerprint of the tools an agent has.
pub fn toolkit(names: &[String]) -> String {
    let mut n: Vec<&str> = names.iter().map(String::as_str).collect();
    n.sort_unstable();
    n.dedup();
    let d = Sha256::digest(n.join(",").as_bytes());
    d.iter().take(4).map(|b| format!("{b:02x}")).collect()
}

fn shrink(v: &Value) -> Value {
    match v {
        Value::String(s) if s.chars().count() > ARG_CHARS => Value::String(format!("(today's text, {} characters)", s.chars().count())),
        Value::Object(m) => Value::Object(m.iter().map(|(k, v)| (k.clone(), shrink(v))).collect()),
        Value::Array(a) => Value::Array(a.iter().map(shrink).collect()),
        other => other.clone(),
    }
}

/// The recipe a clean run leaves: the calls that worked, with what to avoid.
pub fn distill(calls: &[(Step, Value)]) -> Option<Value> {
    let steps: Vec<Step> = calls.iter().map(|(s, _)| s.clone()).collect();
    if calls.is_empty() || calls.len() > MAX_STEPS || outcome::ended_failed(&steps) {
        return None;
    }
    let kept: Vec<(usize, &(Step, Value))> = calls.iter().enumerate().filter(|(_, (s, _))| !s.failed).collect();
    if kept.is_empty() {
        return None;
    }
    Some(Value::Array(
        kept.iter()
            .map(|(i, (s, input))| {
                let avoid: Vec<Value> = calls[..*i].iter().filter(|(e, _)| e.failed && e.tool == s.tool).map(|(_, a)| shrink(a)).collect();
                let mut step = json!({"tool": s.tool, "input": shrink(input)});
                if !avoid.is_empty() {
                    step["avoid"] = json!(avoid);
                }
                step
            })
            .collect(),
    ))
}

/// The recipe in the routine's instructions.
pub fn block(p: &Procedure) -> String {
    let mut s = String::from("This routine has worked before. These are the tool calls that did it, in order, with the arguments that worked:\n");
    for (i, step) in p.steps.as_array().map(Vec::as_slice).unwrap_or_default().iter().enumerate() {
        s.push_str(&format!("{}. {}", i + 1, step["tool"].as_str().unwrap_or("(tool)")));
        if !step["input"].is_null() {
            s.push_str(&format!("\n   arguments: {}", step["input"]));
        }
        for bad in step["avoid"].as_array().map(Vec::as_slice).unwrap_or_default() {
            s.push_str(&format!("\n   don't call it like this, it was rejected: {bad}"));
        }
        s.push('\n');
    }
    s.push_str(
        "Follow these calls as written; don't work out the tools again. Change only values that are a date, time or period to today's. \
         If one of them fails, stop following this recipe, say plainly that the saved recipe failed at that step, and do the job by working it out.",
    );
    s
}

impl Team {
    fn procedures_path(&self, agent: &str) -> std::path::PathBuf {
        self.paths.agent(agent).join("procedures.json")
    }

    pub fn procedures(&self, agent: &str) -> BTreeMap<String, Procedure> {
        util::read_json(&self.procedures_path(agent))
    }

    /// The recipe a routine's job carries, when it has one it may use.
    pub(crate) fn recipe_for(&self, agent: &str, trigger: &Trigger, tools: &[String]) -> Option<String> {
        let Trigger::Routine { routine } = trigger else { return None };
        let p = self.procedures(agent).remove(routine)?;
        (p.enabled && p.toolkit == toolkit(tools)).then(|| block(&p))
    }

    /// After a routine's job: keep the new recipe, or strike the old one.
    pub(crate) fn after_routine(&self, agent: &str, job: &Job, calls: &[(Step, Value)], tools: &[String]) {
        let Trigger::Routine { routine } = &job.trigger else { return };
        let mut all = self.procedures(agent);
        let clean = outcome::clean(job);
        let mut notice = None;
        match (clean, distill(calls)) {
            (true, Some(steps)) => {
                let task = job.input.clone();
                let p = all.entry(routine.clone()).or_insert_with(|| Procedure {
                    routine: routine.clone(),
                    task: task.clone(),
                    steps: Value::Null,
                    learned_from: String::new(),
                    toolkit: String::new(),
                    successes: 0,
                    failures: 0,
                    enabled: true,
                    updated_at: 0,
                });
                // Turned off by the person: it stays off, but keeps learning.
                let off_by_person = !p.enabled && p.failures < MAX_FAILURES;
                p.steps = steps;
                p.task = task;
                p.learned_from = job.id.clone();
                p.toolkit = toolkit(tools);
                p.successes += 1;
                p.failures = 0;
                p.enabled = !off_by_person;
                p.updated_at = util::now();
            }
            (false, _) if job.recipe => {
                if let Some(p) = all.get_mut(routine) {
                    p.failures += 1;
                    if p.failures >= MAX_FAILURES && p.enabled {
                        p.enabled = false;
                        notice = Some(p.task.clone());
                    }
                }
            }
            _ => return,
        }
        let _ = util::write_json(&self.procedures_path(agent), &all);
        if let Some(task) = notice {
            self.notice(agent, "A saved routine recipe turned itself off", &format!("It failed twice in a row on \"{}\". The routine will work it out again and learn a new one.", util::clip(&task, 120)), Some(&job.id), false);
        }
    }

    /// The person turns a routine's recipe on or off.
    pub fn set_procedure(&self, agent: &str, routine: &str, on: bool) -> Result<(), String> {
        let mut all = self.procedures(agent);
        let p = all.get_mut(routine).ok_or("That routine has no recipe yet.")?;
        p.enabled = on;
        if on {
            p.failures = 0;
        }
        util::write_json(&self.procedures_path(agent), &all)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(tool: &str, failed: bool, input: Value) -> (Step, Value) {
        (Step { tool: tool.into(), failed, kind: failed.then(|| "bad_arguments".into()) }, input)
    }

    #[test]
    fn a_recipe_keeps_what_worked_and_what_to_avoid() {
        let calls = vec![
            call("mac_files_list", false, json!({"path": "~/Reports"})),
            call("mac_files_write", true, json!({"path": "Reports/x.md"})),
            call("mac_files_write", false, json!({"path": "~/Reports/x.md", "content": "a".repeat(2000)})),
        ];
        let r = distill(&calls).unwrap();
        let steps = r.as_array().unwrap();
        assert_eq!(steps.len(), 2);
        assert_eq!(steps[1]["avoid"][0]["path"], "Reports/x.md");
        assert!(steps[1]["input"]["content"].as_str().unwrap().starts_with("(today's text"), "content is the day's, not the method's");
        assert!(distill(&[call("x", true, json!({}))]).is_none(), "a failed run teaches no recipe");
        let p = Procedure { routine: "r".into(), task: "t".into(), steps: r, learned_from: "j".into(), toolkit: "k".into(), successes: 1, failures: 0, enabled: true, updated_at: 0 };
        let b = block(&p);
        assert!(b.contains("1. mac_files_list") && b.contains("don't call it like this"));
    }

    #[test]
    fn two_failures_in_a_row_turn_it_off_and_a_clean_run_turns_it_back_on() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        std::fs::create_dir_all(team.paths.agent("a")).unwrap();
        let tools = vec!["mac_files_list".to_string()];
        let trig = Trigger::Routine { routine: "r1".into() };
        let ok = Job { id: "j1".into(), trigger: trig.clone(), status: crate::store::JobStatus::Done, answer: "done".into(), input: "weekly report".into(), ..Default::default() };
        let calls = vec![call("mac_files_list", false, json!({"path": "~"}))];
        team.after_routine("a", &ok, &calls, &tools);
        assert!(team.recipe_for("a", &trig, &tools).is_some());
        assert!(team.recipe_for("a", &trig, &["other".to_string()]).is_none(), "new tools: it sits out a run");
        let bad = Job { recipe: true, status: crate::store::JobStatus::Failed, answer: String::new(), ..ok.clone() };
        team.after_routine("a", &bad, &[], &tools);
        assert!(team.procedures("a")["r1"].enabled);
        team.after_routine("a", &bad, &[], &tools);
        assert!(!team.procedures("a")["r1"].enabled, "two in a row turn it off");
        team.after_routine("a", &ok, &calls, &tools);
        assert!(team.procedures("a")["r1"].enabled, "a clean run learns it again");
    }
}
