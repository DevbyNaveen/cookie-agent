//! Parallax over MCP: any AI uses worlds and engines with the four verbs.
//!
//! Claude Code, Claude Desktop and Codex start `parallax mcp` (stdio);
//! ChatGPT and other remote clients use `parallax serve` (`POST /mcp`, a
//! bearer token). The tools are the worlds (open, fork, timeline, rewind,
//! diff, keep, discard), the four verbs (preview, do, undo, branch), scripts
//! and races. Saying yes at the wall is not a tool: an outside action waits
//! for the person, in Cookie or with `parallax approve`, never for a model.
//! The four verbs are announced as `experimental.parallax.verbs`.

use std::sync::Arc;

use serde_json::{json, Value};

use crate::verbs::Step;
use crate::Parallax;

pub const PROTOCOL: &str = "2025-03-26";

fn tool(name: &str, description: &str, props: Value, required: &[&str]) -> Value {
    json!({"name": name, "description": description, "inputSchema": {"type": "object", "properties": props, "required": required}})
}

pub fn tools() -> Vec<Value> {
    let w = json!({"type": "string", "description": "the world's id"});
    let st = json!({"type": "string"});
    let step = json!({"engine": st, "action": st, "args": {"type": "object"}});
    let with = |mut base: Value, extra: Value| {
        if let (Some(a), Some(b)) = (base.as_object_mut(), extra.as_object()) {
            a.extend(b.clone());
        }
        base
    };
    vec![
        tool("parallax_actions", "Every engine and its actions, with what kind each is: read (changes nothing), local (changes the world, undoable), outside (waits for a person's yes).", json!({}), &[]),
        tool("parallax_worlds", "The worlds there are.", json!({}), &[]),
        tool("parallax_open", "Open a new world: empty, or an instant copy of a folder (`from`). Work there; `parallax_keep` writes it back.", json!({"name": st, "from": st}), &[]),
        tool("parallax_fork", "Copy a world as it is now, instantly.", json!({"world": w, "name": st}), &["world"]),
        tool("parallax_preview", "What an action would change, without changing anything.", with(json!({"world": w}), step.clone()), &["world", "engine", "action"]),
        tool("parallax_do", "Do an action in a world. Its answer says what changed and the change id to undo it. `then` names the step you expect next, so it can be done ahead.", with(json!({"world": w, "then": {"type": "object"}}), step.clone()), &["world", "engine", "action"]),
        tool("parallax_undo", "Undo a change (by the id parallax_do gave).", json!({"change": st}), &["change"]),
        tool("parallax_branch", "Fork the world and do the action in the fork; the world itself stays as it was.", with(json!({"world": w, "name": st}), step), &["world", "engine", "action"]),
        tool("parallax_script", "Run a Python script in the world that calls engines as functions (`from parallax import *`; e.g. sheet_set(path=…, cells={…})). Prints come back; the whole run is one undoable change.", json!({"world": w, "code": st}), &["world", "code"]),
        tool("parallax_race", "Race 2–8 attempts in forks; `test` (a shell command run in each fork) picks the winner, which is kept. Each attempt: {label, steps:[{engine,action,args}], script}.", json!({"world": w, "attempts": {"type": "array", "items": {"type": "object"}}, "test": st}), &["world", "attempts", "test"]),
        tool("parallax_timeline", "A world's story: every change, checkpoint, undo and rewind.", json!({"world": w}), &["world"]),
        tool("parallax_rewind", "Put a world back as a checkpoint had it (the present is kept as a checkpoint first).", json!({"world": w, "checkpoint": {"type": "integer"}}), &["world", "checkpoint"]),
        tool("parallax_diff", "What differs between two worlds, or between a world and one of its checkpoints.", json!({"world": w, "other": st, "checkpoint": {"type": "integer"}}), &["world"]),
        tool("parallax_keep", "Write a world made from a folder back to that folder (never over a file changed there since).", json!({"world": w}), &["world"]),
        tool("parallax_discard", "Throw a world away.", json!({"world": w}), &["world"]),
        tool("parallax_vaults", "Your vaults: whole Linux computers of your own, each with a hidden desktop. Awake, asleep (on disk, free) or off.", json!({}), &[]),
        tool("parallax_vault_open", "Open a vault by name: a new one boots in seconds with its own disk; an asleep one wakes exactly where it was. `network: true` when making one gives it the internet (and nothing else: not this host, not the private network); without it, it has no network. Chosen once, when it's made.", json!({"name": st, "network": {"type": "boolean"}}), &["name"]),
        tool("parallax_vault_run", "Run a shell command in a vault (its desktop is DISPLAY=:0). Returns the exit code and output.", json!({"name": st, "command": st, "timeout": {"type": "integer", "description": "seconds, default 60"}}), &["name", "command"]),
        tool("parallax_vault_launch", "Start an app on a vault's desktop and return at once: firefox (with network), libreoffice --calc / --writer, mousepad, zenity, or any command.", json!({"name": st, "app": st}), &["name", "app"]),
        tool("parallax_vault_look", "Read an app's window in a vault: its buttons, fields and text, each with a ref.", json!({"name": st, "app": st}), &["name"]),
        tool("parallax_vault_act", "Use an app in a vault: steps by ref or role and name (press, set, focus, menu, type, keys…), checked between steps; answers with what changed.", json!({"name": st, "app": st, "steps": {"type": "array", "items": {"type": "object"}}}), &["name", "steps"]),
        tool("parallax_vault_sleep", "Put a vault to sleep: it stops at once and its memory goes to disk in the background; it wakes exactly where it was.", json!({"name": st}), &["name"]),
        tool("parallax_vault_discard", "Throw a vault away for good: its disk, memory and state.", json!({"name": st}), &["name"]),
        tool("parallax_waiting", "Actions waiting at the wall for a person's yes.", json!({}), &[]),
    ]
}

fn step_of(a: &Value) -> Step {
    Step { engine: a["engine"].as_str().unwrap_or_default().into(), action: a["action"].as_str().unwrap_or_default().into(), args: a.get("args").cloned().filter(|v| v.is_object()).unwrap_or(json!({})) }
}

fn w(a: &Value) -> Result<&str, String> {
    a["world"].as_str().ok_or_else(|| "Needs `world`.".into())
}

/// Over HTTP each account sees only its own worlds; `*` (this machine's own
/// person, on stdio or with the host's own token) sees all.
fn mine(px: &Parallax, world: &str, owner: &str) -> Result<(), String> {
    if owner == "*" {
        return Ok(());
    }
    match px.worlds.get(world) {
        Ok(w) if w.owner == owner => Ok(()),
        _ => Err("No such world.".into()),
    }
}

/// One tool call, as text for the model.
pub async fn call(px: &Arc<Parallax>, name: &str, a: &Value, owner: &str) -> Result<Value, String> {
    if let Some(world) = a["world"].as_str() {
        mine(px, world, owner)?;
    }
    if let Some(other) = a["other"].as_str() {
        mine(px, other, owner)?;
    }
    if let Some(change) = a["change"].as_str() {
        mine(px, change.rsplit_once(':').map(|(w, _)| w).unwrap_or(""), owner)?;
    }
    let made_by = if owner == "*" { "local" } else { owner };
    match name {
        "parallax_actions" => Ok(json!(px.engines.actions())),
        "parallax_worlds" => Ok(json!(px.worlds.list().into_iter().filter(|w| owner == "*" || w.owner == owner).collect::<Vec<_>>())),
        "parallax_open" => {
            // A hosted account opens empty worlds (or linked ones): the host's own folders are not theirs.
            let from = a["from"].as_str().filter(|_| owner == "*").map(std::path::PathBuf::from);
            if a["from"].is_string() && owner != "*" {
                return Err("On a host, bring a folder with `parallax link`; `from` opens folders on this machine only.".into());
            }
            Ok(json!(px.worlds.create(a["name"].as_str().unwrap_or("world"), from.as_deref(), made_by)?))
        }
        "parallax_fork" => Ok(json!(px.worlds.fork(w(a)?, a["name"].as_str())?)),
        "parallax_preview" => px.preview(w(a)?, &step_of(a)).await,
        "parallax_do" => {
            let then = a.get("then").filter(|t| t.is_object()).map(step_of);
            Ok(json!(px.act(w(a)?, &step_of(a), then).await?))
        }
        "parallax_undo" => px.undo(a["change"].as_str().ok_or("Needs `change`.")?),
        "parallax_branch" => Ok(json!(px.branch(w(a)?, &step_of(a), a["name"].as_str()).await?)),
        "parallax_script" => Ok(json!({"output": px.script(w(a)?, a["code"].as_str().ok_or("Needs `code`.")?).await?})),
        "parallax_race" => {
            let attempts: Vec<crate::race::Attempt> = serde_json::from_value(a["attempts"].clone()).map_err(|e| format!("attempts: {e}"))?;
            px.race(w(a)?, attempts, a["test"].as_str().ok_or("Needs `test`.")?).await
        }
        "parallax_timeline" => Ok(json!(px.worlds.timeline(w(a)?))),
        "parallax_rewind" => Ok(json!({"present_kept_as_checkpoint": px.worlds.rewind(w(a)?, a["checkpoint"].as_u64().ok_or("Needs `checkpoint`.")?)?})),
        "parallax_diff" => {
            let mine = px.worlds.files(w(a)?)?;
            let other = match (a["other"].as_str(), a["checkpoint"].as_u64()) {
                (Some(o), _) => px.worlds.files(o)?,
                (None, Some(n)) => px.worlds.checkpoint_files(w(a)?, n)?,
                _ => return Err("Diff against `other` (a world) or a `checkpoint`.".into()),
            };
            Ok(crate::world::diff_dirs(&other, &mine))
        }
        "parallax_keep" => px.worlds.keep(w(a)?),
        "parallax_discard" => {
            px.worlds.discard(w(a)?)?;
            Ok(json!({"discarded": w(a)?}))
        }
        // Vaults: the host's own token may act for an agent (`as`); anyone else is themselves.
        v if v.starts_with("parallax_vault") => {
            let who = if owner == "*" { a["as"].as_str().filter(|s| !s.is_empty()).unwrap_or("local") } else { owner };
            let name = a["name"].as_str().unwrap_or_default();
            let home = &px.home;
            match v {
                "parallax_vaults" => Ok(crate::vaults::list(home, who).await),
                "parallax_vault_open" => crate::vaults::open(home, who, name, a["network"].as_bool()).await,
                "parallax_vault_run" => crate::vaults::run(home, who, name, a["command"].as_str().ok_or("Needs `command`.")?, a["timeout"].as_u64().unwrap_or(60)).await,
                "parallax_vault_launch" => crate::vaults::launch(home, who, name, a["app"].as_str().ok_or("Needs `app`.")?).await,
                "parallax_vault_look" => crate::vaults::look(home, who, name, a["app"].as_str()).await,
                "parallax_vault_act" => crate::vaults::act(home, who, name, a["app"].as_str(), &a["steps"]).await,
                "parallax_vault_sleep" => crate::vaults::sleep(home, who, name).await,
                "parallax_vault_discard" => crate::vaults::discard(home, who, name).await,
                "parallax_vaults_sleep_all" if owner == "*" => Ok(json!({"slept": crate::vaults::sleep_all(home).await})),
                "parallax_vaults_awake" if owner == "*" => Ok(json!({"awake": crate::vaults::awake_count().await})),
                _ => Err(format!("No tool `{v}`.")),
            }
        }
        "parallax_waiting" => Ok(json!(px.ledger.waiting().into_iter().filter(|e| owner == "*" || px.worlds.get(&e.world).is_ok_and(|w| w.owner == owner)).collect::<Vec<_>>())),
        other => Err(format!("No tool {other}.")),
    }
}

/// One JSON-RPC message in, its answer out (`None` for a notification).
pub async fn handle(px: &Arc<Parallax>, msg: &Value, owner: &str) -> Option<Value> {
    let id = msg.get("id").cloned();
    let method = msg["method"].as_str().unwrap_or("");
    let result = match method {
        "initialize" => Ok(json!({
            "protocolVersion": PROTOCOL,
            "capabilities": {"tools": {"listChanged": false}, "experimental": {"parallax.verbs": {"version": 1, "verbs": ["preview", "do", "undo", "branch"]}}},
            "serverInfo": {"name": "parallax", "version": env!("CARGO_PKG_VERSION")},
            "instructions": "Parallax is a computer built for agents. Open a world (an instant copy of a folder, or empty), act in it through engines with parallax_do, preview before big changes, undo what went wrong, branch to try alternatives, race attempts against a test. Outside actions (sending, paying, publishing) wait for the person.",
        })),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": tools()})),
        "tools/call" => {
            let name = msg.pointer("/params/name").and_then(Value::as_str).unwrap_or("");
            let args = msg.pointer("/params/arguments").cloned().unwrap_or(json!({}));
            Ok(match call(px, name, &args, owner).await {
                Ok(v) => json!({"content": [{"type": "text", "text": serde_json::to_string_pretty(&v).unwrap_or_default()}], "isError": false}),
                Err(e) => json!({"content": [{"type": "text", "text": e}], "isError": true}),
            })
        }
        m if m.starts_with("notifications/") => return None,
        _ => Err(json!({"code": -32601, "message": format!("No method {method}")})),
    };
    id.map(|id| match result {
        Ok(r) => json!({"jsonrpc": "2.0", "id": id, "result": r}),
        Err(e) => json!({"jsonrpc": "2.0", "id": id, "error": e}),
    })
}

/// Serve MCP on stdin/stdout, one JSON message per line.
pub async fn stdio(px: Arc<Parallax>) -> Result<(), String> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let mut out = tokio::io::stdout();
    while let Some(line) = lines.next_line().await.map_err(|e| e.to_string())? {
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        if let Some(answer) = handle(&px, &msg, "*").await {
            out.write_all(format!("{answer}\n").as_bytes()).await.map_err(|e| e.to_string())?;
            out.flush().await.map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// How to add Parallax to each AI, for the person to paste.
pub fn setup(binary: &str) -> Value {
    json!({
        "claude_code": format!("claude mcp add parallax -- {binary} mcp"),
        "codex": format!("[mcp_servers.parallax]\ncommand = \"{binary}\"\nargs = [\"mcp\"]"),
        "claude_desktop": {"mcpServers": {"parallax": {"command": binary, "args": ["mcp"]}}},
        "chatgpt": "Run `parallax serve` on a host with an https address, then add a connector in ChatGPT with the URL https://<host>/mcp and the token from `parallax token`.",
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn an_ai_opens_a_world_does_previews_undoes_and_cannot_approve() {
        let d = tempfile::tempdir().unwrap();
        let px = Parallax::open(d.path()).unwrap();
        let init = handle(&px, &json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}), "t").await.unwrap();
        assert_eq!(init["result"]["capabilities"]["experimental"]["parallax.verbs"]["version"], 1);
        let list = handle(&px, &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}), "t").await.unwrap();
        let names: Vec<&str> = list["result"]["tools"].as_array().unwrap().iter().filter_map(|t| t["name"].as_str()).collect();
        assert!(names.contains(&"parallax_do") && !names.iter().any(|n| n.contains("approve")), "no tool says yes for the person");
        let world = call(&px, "parallax_open", &json!({"name": "t"}), "t").await.unwrap();
        let wid = world["id"].as_str().unwrap().to_string();
        let pv = call(&px, "parallax_preview", &json!({"world": wid, "engine": "files", "action": "write", "args": {"path": "a.txt", "text": "hi"}}), "t").await.unwrap();
        assert_eq!(pv["changes"]["files"][0]["path"], "a.txt");
        assert!(!px.worlds.files(&wid).unwrap().join("a.txt").exists(), "a preview changes nothing");
        let done = call(&px, "parallax_do", &json!({"world": wid, "engine": "files", "action": "write", "args": {"path": "a.txt", "text": "hi"}}), "t").await.unwrap();
        assert!(px.worlds.files(&wid).unwrap().join("a.txt").exists());
        call(&px, "parallax_undo", &json!({"change": done["change"]}), "t").await.unwrap();
        assert!(!px.worlds.files(&wid).unwrap().join("a.txt").exists(), "undone");
        // An outside action waits at the wall.
        let click = call(&px, "parallax_do", &json!({"world": wid, "engine": "browser", "action": "click", "args": {"ref": 1, "what": "Buy"}}), "t").await.unwrap();
        assert!(click["waiting"].is_string());
        assert_eq!(px.ledger.waiting().len(), 1);
        assert!(handle(&px, &json!({"jsonrpc": "2.0", "method": "notifications/initialized"}), "t").await.is_none());
    }
}
