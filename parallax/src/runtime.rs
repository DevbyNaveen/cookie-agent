//! Scripts: an agent combines engines in one short script.
//!
//! The script is Python, run caged in the world (`sizes::world_run`: it sees
//! the world's files and nothing else, no network). `from parallax import *`
//! gives one function per engine action — `sheet_set(path=..., cell="B2",
//! value=...)`, `pdf_text(path=...)` — and each call goes through Do
//! (`verbs`): local changes are checkpointed and undoable, outside actions
//! stop at the wall and the script is told they are waiting. The script asks
//! by writing a request file in `.parallax/rpc`; Parallax, outside the cage,
//! answers it. Many steps become one call, and the in-between results never
//! reach the agent: only what the script prints.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};

use crate::verbs::Step;
use crate::Parallax;

const LIMIT: Duration = Duration::from_secs(240);
const MAX_CALLS: usize = 500;

fn helper(actions: &[crate::ActionSpec]) -> String {
    let mut s = String::from(
        r#""""Parallax engines, as functions. Each returns the engine's answer (parsed JSON)."""
import json, os, time, uuid
_DIR = os.path.dirname(os.path.abspath(__file__))

def call(engine, action, **args):
    rid = uuid.uuid4().hex[:12]
    tmp = os.path.join(_DIR, ".req-" + rid + ".tmp")
    with open(tmp, "w") as f:
        json.dump({"id": rid, "engine": engine, "action": action, "args": args}, f)
    os.rename(tmp, os.path.join(_DIR, "req-" + rid + ".json"))
    res = os.path.join(_DIR, "res-" + rid + ".json")
    start = time.time()
    while not os.path.exists(res):
        if time.time() - start > 200:
            raise TimeoutError(engine + "." + action + " took too long")
        time.sleep(0.01)
    with open(res) as f:
        r = json.load(f)
    os.remove(res)
    if not r.get("ok"):
        raise RuntimeError(engine + "." + action + ": " + str(r.get("error")))
    return r["result"]
"#,
    );
    for a in actions {
        let doc = a.description.replace('"', "'").replace('\\', "/");
        let wall = if a.effect == crate::Effect::Outside { " (reaches outside: waits for a person's yes)" } else { "" };
        s.push_str(&format!("\ndef {}_{}(**args):\n    \"\"\"{doc}{wall}\"\"\"\n    return call({:?}, {:?}, **args)\n", a.engine, a.name, a.engine, a.name));
    }
    s
}

impl Parallax {
    /// Run a script in a world. What it prints comes back.
    pub async fn script(self: &Arc<Self>, world: &str, code: &str) -> Result<String, String> {
        if code.trim().is_empty() {
            return Err("Write the script.".into());
        }
        self.worlds.touch(world)?;
        let files = self.worlds.files(world)?;
        let rpc = files.join(".parallax/rpc");
        let _ = std::fs::remove_dir_all(&rpc);
        std::fs::create_dir_all(&rpc).map_err(|e| e.to_string())?;
        std::fs::write(rpc.join("parallax.py"), helper(&self.engines.actions())).map_err(|e| e.to_string())?;
        std::fs::write(rpc.join("script.py"), code).map_err(|e| e.to_string())?;
        // The script may also write files itself: the whole run is one undoable change.
        let n = self.worlds.checkpoint(world, "Before a script")?;
        let before = crate::world::digests(&files);
        let command = "PYTHONPATH=.parallax/rpc PYTHONDONTWRITEBYTECODE=1 /usr/bin/env python3 -u .parallax/rpc/script.py";
        let run = crate::sizes::world_run(&files, command, false, LIMIT.as_secs());
        tokio::pin!(run);
        let mut calls = 0usize;
        let mut waiting: Vec<String> = Vec::new();
        let outcome = loop {
            tokio::select! {
                out = &mut run => break out,
                _ = tokio::time::sleep(Duration::from_millis(15)) => {
                    let reqs: Vec<_> = std::fs::read_dir(&rpc).into_iter().flatten().flatten().filter(|e| { let n = e.file_name().to_string_lossy().to_string(); n.starts_with("req-") && n.ends_with(".json") }).collect();
                    let mut by_id: HashMap<String, Value> = HashMap::new();
                    for e in reqs {
                        let req: Value = std::fs::read(e.path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
                        let _ = std::fs::remove_file(e.path());
                        let id: String = req["id"].as_str().unwrap_or_default().chars().filter(|c| c.is_ascii_alphanumeric()).collect();
                        if !id.is_empty() {
                            by_id.insert(id, req);
                        }
                    }
                    for (id, req) in by_id {
                        calls += 1;
                        let answer = if calls > MAX_CALLS {
                            json!({"ok": false, "error": format!("more than {MAX_CALLS} engine calls in one script")})
                        } else {
                            let step = Step { engine: req["engine"].as_str().unwrap_or_default().into(), action: req["action"].as_str().unwrap_or_default().into(), args: req["args"].clone() };
                            match self.act(world, &step, None).await {
                                Ok(o) => {
                                    if let Some(w) = &o.waiting {
                                        waiting.push(w.clone());
                                    }
                                    json!({"ok": true, "result": o.result})
                                }
                                Err(e) => json!({"ok": false, "error": e}),
                            }
                        };
                        let tmp = rpc.join(format!(".res-{id}.tmp"));
                        if std::fs::write(&tmp, answer.to_string()).is_ok() {
                            let _ = std::fs::rename(&tmp, rpc.join(format!("res-{id}.json")));
                        }
                    }
                }
            }
        };
        let _ = std::fs::remove_dir_all(&rpc);
        let changed = crate::world::changed(&before, &crate::world::digests(&files));
        let change = format!("{world}:{n}");
        let _ = self.worlds.log(world, &crate::world::Event { at: crate::util::now(), kind: "do".into(), checkpoint: Some(n), change: Some(change.clone()), engine: Some("script".into()), action: Some("run".into()), what: format!("A script ({calls} engine calls)"), files: changed, ..Default::default() });
        let (code, out) = outcome?;
        let mut text = crate::util::clip(&out, 20_000);
        if code != 0 {
            text = format!("The script exited with {code}.\n{text}");
        }
        if calls > 0 {
            text.push_str(&format!("\n({calls} engine call{})", if calls == 1 { "" } else { "s" }));
        }
        text.push_str(&format!("\n(undo it all with change {change})"));
        if !waiting.is_empty() {
            text.push_str(&format!("\n({} action{} waiting at the wall for a person's yes: {})", waiting.len(), if waiting.len() == 1 { "" } else { "s" }, waiting.join(", ")));
        }
        Ok(text)
    }
}
