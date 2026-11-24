//! The four verbs every action takes: Preview, Do, Undo, Branch.
//!
//! - **Preview**: the action is done in a throwaway copy of the world and
//!   what it would change is returned (files added, changed, removed, with the
//!   lines); the world itself is untouched. An outside action is previewed as
//!   words only: the outside can't be copied.
//! - **Do**: a checkpoint first, then the action; the answer says what
//!   changed and whether it can be undone. An outside action stops at the wall
//!   (`ledger`) and runs only on a person's yes.
//! - **Undo**: the world goes back to the checkpoint taken before that change.
//!   An outside action can't be undone, and Undo says so.
//! - **Branch**: the world is forked and the action is done in the fork.
//!
//! **Thinking ahead**: a Do may name the step the agent expects next
//! (`then`). While the agent reads the answer, Parallax does that step in a
//! spare copy. If the next Do is exactly that step and the world hasn't
//! changed since, the spare's result is used at once (its files swapped in, a
//! checkpoint taken first, so it is undoable like any Do). Otherwise the spare
//! is thrown away. Only reads and local actions are done ahead: never an
//! outside one.

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::engine::{Ctx, Effect};
use crate::world::{changed, digests, Event};
use crate::{util, Parallax};

/// One action: which engine, which action, with what.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Step {
    pub engine: String,
    pub action: String,
    pub args: Value,
}

impl Step {
    pub fn key(&self) -> String {
        format!("{}.{}:{}", self.engine, self.action, canonical(&self.args))
    }
}

fn canonical(v: &Value) -> String {
    fn sort(v: &Value) -> Value {
        match v {
            Value::Object(m) => {
                let mut keys: Vec<&String> = m.keys().collect();
                keys.sort();
                Value::Object(keys.into_iter().map(|k| (k.clone(), sort(&m[k]))).collect())
            }
            Value::Array(a) => Value::Array(a.iter().map(sort).collect()),
            v => v.clone(),
        }
    }
    sort(v).to_string()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Outcome {
    pub world: String,
    /// Its id for Undo (`None` for a read, or one waiting at the wall).
    pub change: Option<String>,
    pub undoable: bool,
    pub result: Value,
    /// Files it changed: path → added · changed · removed.
    pub files: std::collections::BTreeMap<String, String>,
    /// Waiting at the wall for a person's yes: the ledger entry's id.
    pub waiting: Option<String>,
    /// Done ahead while the agent was reading.
    pub from_ahead: bool,
}

/// A step done ahead in a spare world.
pub(crate) struct Ahead {
    key: String,
    base: std::collections::BTreeMap<String, String>,
    spare: String,
    task: tokio::task::JoinHandle<Result<Value, String>>,
}

impl Parallax {
    pub(crate) fn ctx(&self, world: &str) -> Result<Ctx, String> {
        let files = self.worlds.files(world)?;
        Ok(Ctx { world: world.into(), state: files.join(".parallax"), files, home: self.home.clone() })
    }

    /// Run one engine action in a world, holding a share of the machine.
    pub(crate) async fn run(&self, world: &str, step: &Step) -> Result<Value, String> {
        let engine = self.engines.get(&step.engine)?;
        let ctx = self.ctx(world)?;
        let _turn = self.cpu.acquire().await.map_err(|e| e.to_string())?;
        engine.call(&ctx, &step.action, &step.args).await
    }

    /// Preview: what the action would change, from a throwaway copy.
    pub async fn preview(&self, world: &str, step: &Step) -> Result<Value, String> {
        let spec = self.engines.spec(&step.engine, &step.action)?;
        self.worlds.touch(world)?;
        match spec.effect {
            Effect::Outside => Ok(json!({"effect": "outside", "undoable": false, "would": self.engines.get(&step.engine)?.preview(&step.action, &step.args), "note": "This reaches outside the world: it would wait for a person's yes, and can't be undone."})),
            Effect::Read => Ok(json!({"effect": "read", "undoable": true, "would": "Nothing changes: it only reads.", "result": self.run(world, step).await?})),
            Effect::Local => {
                let copy = self.worlds.fork(world, Some("preview"))?;
                let result = self.run(&copy.id, step).await;
                let diff = crate::world::diff_dirs(&self.worlds.files(world)?, &self.worlds.files(&copy.id)?);
                let _ = self.worlds.discard(&copy.id);
                Ok(json!({"effect": "local", "undoable": true, "changes": diff, "result": result?}))
            }
        }
    }

    /// Do: the action, with a checkpoint first (or held at the wall).
    pub async fn act(self: &Arc<Self>, world: &str, step: &Step, then: Option<Step>) -> Result<Outcome, String> {
        let spec = self.engines.spec(&step.engine, &step.action)?;
        self.worlds.touch(world)?;
        let out = match spec.effect {
            Effect::Outside => {
                let preview = self.engines.get(&step.engine)?.preview(&step.action, &step.args);
                let e = self.ledger.hold(world, &step.engine, &step.action, &step.args, &preview)?;
                self.worlds.log(world, &Event { at: util::now(), kind: "wall".into(), engine: Some(step.engine.clone()), action: Some(step.action.clone()), args: Some(step.args.clone()), what: format!("Waiting for a yes: {preview}"), ..Event::default() })?;
                Outcome { world: world.into(), undoable: false, waiting: Some(e.id), result: json!({"waiting": true, "note": "This reaches outside the world, so it waits for a person's yes."}), ..Outcome::default() }
            }
            Effect::Read => {
                let (result, from_ahead) = match self.take_ahead(world, step).await {
                    Some(r) => (r?, true),
                    None => (self.run(world, step).await?, false),
                };
                Outcome { world: world.into(), undoable: true, result, from_ahead, ..Outcome::default() }
            }
            Effect::Local => {
                let n = self.worlds.checkpoint(world, &format!("Before {}.{}", step.engine, step.action))?;
                let before = digests(&self.worlds.files(world)?);
                let ahead = self.take_ahead_local(world, step, &before).await;
                let (result, from_ahead) = match ahead {
                    Some(r) => (r, true),
                    None => (self.run(world, step).await, false),
                };
                let after = digests(&self.worlds.files(world)?);
                let files = changed(&before, &after);
                let result = match result {
                    Ok(r) => r,
                    Err(e) => {
                        // A failed action leaves nothing half done.
                        let _ = self.worlds.rewind(world, n);
                        return Err(e);
                    }
                };
                let change = format!("{world}:{n}");
                self.worlds.log(world, &Event { at: util::now(), kind: "do".into(), checkpoint: Some(n), change: Some(change.clone()), engine: Some(step.engine.clone()), action: Some(step.action.clone()), args: Some(step.args.clone()), what: format!("{}.{}", step.engine, step.action), files: files.clone() })?;
                Outcome { world: world.into(), change: Some(change), undoable: true, result, files, from_ahead, ..Outcome::default() }
            }
        };
        if let Some(next) = then {
            self.think_ahead(world, next);
        }
        Ok(out)
    }

    /// Undo: back to before that change.
    pub fn undo(&self, change: &str) -> Result<Value, String> {
        let (world, n) = change.rsplit_once(':').ok_or("That isn't a change id.")?;
        let n: u64 = n.parse().map_err(|_| "That isn't a change id.")?;
        if !self.worlds.timeline(world).iter().any(|e| e.kind == "do" && e.change.as_deref() == Some(change)) {
            return Err("No such change in that world.".into());
        }
        let saved = self.worlds.rewind(world, n)?;
        self.worlds.log(world, &Event { at: util::now(), kind: "undo".into(), change: Some(change.into()), checkpoint: Some(saved), what: format!("Undid {change}"), ..Event::default() })?;
        Ok(json!({"undone": change, "redo_from_checkpoint": saved}))
    }

    /// Branch: a fork, and the action done there.
    pub async fn branch(self: &Arc<Self>, world: &str, step: &Step, name: Option<&str>) -> Result<Outcome, String> {
        let fork = self.worlds.fork(world, name)?;
        self.act(&fork.id, step, None).await
    }

    /// A person's answer at the wall; on yes the action runs now, once.
    pub async fn decide(&self, entry: &str, yes: bool, by: &str) -> Result<Value, String> {
        let e = self.ledger.decide(entry, yes, by)?;
        if !yes {
            return Ok(json!({"state": "refused"}));
        }
        let step = Step { engine: e.engine.clone(), action: e.action.clone(), args: e.args.clone() };
        let r = self.run(&e.world, &step).await;
        let done = self.ledger.finish(entry, r.is_ok(), &r.as_ref().map(|v| v.to_string()).unwrap_or_else(|e| e.clone()))?;
        Ok(json!({"state": done.state, "result": r.unwrap_or_else(Value::String)}))
    }

    /// Start the expected next step in a spare world.
    fn think_ahead(self: &Arc<Self>, world: &str, next: Step) {
        let Ok(spec) = self.engines.spec(&next.engine, &next.action) else { return };
        if spec.effect == Effect::Outside {
            return;
        }
        let Ok(files) = self.worlds.files(world) else { return };
        let base = digests(&files);
        let (spare, run_in) = if spec.effect == Effect::Local {
            match self.worlds.fork(world, Some("ahead")) {
                Ok(f) => (f.id.clone(), f.id),
                Err(_) => return,
            }
        } else {
            (String::new(), world.to_string())
        };
        let me = self.clone();
        let step = next.clone();
        let task = tokio::spawn(async move { me.run(&run_in, &step).await });
        let old = self.ahead.lock().unwrap().insert(world.to_string(), Ahead { key: next.key(), base, spare, task });
        if let Some(o) = old {
            o.task.abort();
            if !o.spare.is_empty() {
                let _ = self.worlds.discard(&o.spare);
            }
        }
    }

    async fn take_ahead(&self, world: &str, step: &Step) -> Option<Result<Value, String>> {
        let a = self.ahead.lock().unwrap().remove(world)?;
        let still = digests(&self.worlds.files(world).ok()?) == a.base;
        if a.key != step.key() || !still || !a.spare.is_empty() {
            a.task.abort();
            if !a.spare.is_empty() {
                let _ = self.worlds.discard(&a.spare);
            }
            return None;
        }
        a.task.await.ok()
    }

    /// A local step done ahead: its spare's files become the world's.
    async fn take_ahead_local(&self, world: &str, step: &Step, before: &std::collections::BTreeMap<String, String>) -> Option<Result<Value, String>> {
        let a = self.ahead.lock().unwrap().remove(world)?;
        if a.key != step.key() || &a.base != before || a.spare.is_empty() {
            a.task.abort();
            if !a.spare.is_empty() {
                let _ = self.worlds.discard(&a.spare);
            }
            return None;
        }
        let r = a.task.await.ok()?;
        if r.is_ok() {
            let (src, dst) = (self.worlds.files(&a.spare).ok()?, self.worlds.files(world).ok()?);
            let old = dst.with_file_name(".before-ahead");
            let _ = std::fs::remove_dir_all(&old);
            if std::fs::rename(&dst, &old).is_err() || std::fs::rename(&src, &dst).is_err() {
                let _ = std::fs::rename(&old, &dst);
                let _ = self.worlds.discard(&a.spare);
                return None;
            }
            let _ = std::fs::remove_dir_all(&old);
        }
        let _ = self.worlds.discard(&a.spare);
        Some(r)
    }
}
