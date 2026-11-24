//! Race several attempts; the agent's own tests pick the winner.
//!
//! Each attempt runs in its own fork of the world, all at once. Then the
//! test (a shell command, run inside each fork's cage: `make test`,
//! `pytest -q`, a script) decides: an attempt passes when its test exits 0.
//! The winner is the passing attempt that changed the fewest files, then the
//! fastest; it is kept (its files become the world's, after a checkpoint, so
//! keeping is undoable) and the other forks are thrown away. When none
//! passes, nothing is kept and every attempt's test output is returned.

use std::sync::Arc;
use std::time::Instant;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::verbs::Step;
use crate::world::{changed, digests, Event};
use crate::{util, Parallax};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Attempt {
    pub label: String,
    /// Engine steps, in order.
    pub steps: Vec<Step>,
    /// Or a script (`runtime`), run after the steps.
    pub script: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Run {
    pub label: String,
    pub world: String,
    pub passed: bool,
    pub error: Option<String>,
    pub test_output: String,
    pub files_changed: usize,
    pub ms: u64,
}

impl Parallax {
    pub async fn race(self: &Arc<Self>, world: &str, attempts: Vec<Attempt>, test: &str) -> Result<Value, String> {
        if attempts.len() < 2 || attempts.len() > 8 {
            return Err("A race has 2 to 8 attempts.".into());
        }
        if test.trim().is_empty() {
            return Err("A race needs a test: the command that says which attempt works.".into());
        }
        self.worlds.touch(world)?;
        let base = digests(&self.worlds.files(world)?);
        let mut tasks = Vec::new();
        for (i, a) in attempts.into_iter().enumerate() {
            let label = if a.label.trim().is_empty() { format!("attempt {}", i + 1) } else { a.label.clone() };
            let fork = self.worlds.fork(world, Some(&format!("race: {label}")))?;
            let (me, test, base) = (self.clone(), test.to_string(), base.clone());
            tasks.push(tokio::spawn(async move {
                let began = Instant::now();
                let mut run = Run { label, world: fork.id.clone(), ..Run::default() };
                for s in &a.steps {
                    if let Err(e) = me.act(&fork.id, s, None).await {
                        run.error = Some(e);
                        break;
                    }
                }
                if run.error.is_none() {
                    if let Some(code) = a.script.as_deref() {
                        if let Err(e) = me.script(&fork.id, code).await {
                            run.error = Some(e);
                        }
                    }
                }
                if run.error.is_none() {
                    match crate::sizes::world_run(&me.worlds.files(&fork.id).unwrap_or_default(), test.as_str(), false, 300).await {
                        Ok((code, out)) => {
                            run.passed = code == 0;
                            run.test_output = util::clip(&out, 4_000);
                        }
                        Err(e) => run.error = Some(e),
                    }
                }
                run.files_changed = me.worlds.files(&fork.id).map(|f| changed(&base, &digests(&f)).len()).unwrap_or(0);
                run.ms = began.elapsed().as_millis() as u64;
                run
            }));
        }
        let mut runs = Vec::new();
        for t in tasks {
            runs.push(t.await.map_err(|e| e.to_string())?);
        }
        let winner = runs.iter().filter(|r| r.passed).min_by_key(|r| (r.files_changed, r.ms)).cloned();
        if let Some(w) = &winner {
            let n = self.worlds.checkpoint(world, "Before keeping the race's winner")?;
            let (src, dst) = (self.worlds.files(&w.world)?, self.worlds.files(world)?);
            let staged = dst.with_file_name(".winner");
            let _ = std::fs::remove_dir_all(&staged);
            crate::world::clone_tree(&src, &staged)?;
            let old = dst.with_file_name(".before-winner");
            let _ = std::fs::remove_dir_all(&old);
            std::fs::rename(&dst, &old).map_err(|e| e.to_string())?;
            if let Err(e) = std::fs::rename(&staged, &dst) {
                let _ = std::fs::rename(&old, &dst);
                return Err(e.to_string());
            }
            let _ = std::fs::remove_dir_all(&old);
            let after = digests(&dst);
            let change = format!("{world}:{n}");
            self.worlds.log(world, &Event { at: util::now(), kind: "do".into(), checkpoint: Some(n), change: Some(change), engine: Some("race".into()), action: Some("keep".into()), what: format!("Kept “{}” from a race of {}", w.label, runs.len()), files: changed(&base, &after), ..Event::default() })?;
        }
        for r in &runs {
            let _ = self.worlds.discard(&r.world);
        }
        Ok(json!({"winner": winner.as_ref().map(|w| &w.label), "change": winner.as_ref().map(|_| format!("{world}:{}", self.worlds.get(world).map(|w| w.next_checkpoint.saturating_sub(1)).unwrap_or(0))), "runs": runs}))
    }
}
