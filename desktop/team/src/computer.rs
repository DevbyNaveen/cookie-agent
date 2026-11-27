//! Parallax in Cookie: worlds for agents, each agent's own software, and the
//! watch window.
//!
//! **Worlds.** An agent with "Worlds" on gets Parallax's tools (open a world,
//! preview, do, undo, branch, script, race, rewind, keep), scoped to its own
//! worlds: it never sees another agent's. It may open a world from its own
//! folder or a folder you gave it, and keeping writes back there (asking you,
//! as any change to your files does). Outside actions stop at Parallax's wall
//! and show up here, for you, with yes and no.
//!
//! **Its own software.** Every agent has a workspace: a Parallax world that
//! holds its software, made of tested blocks (tracker, board, calendar,
//! chart, form, sheet, document, pdf). The workspace button beside its name
//! opens it beside the chat. You and the agent both work in it, every change
//! through Do, so each can be undone; the agent changes its own software by
//! reshaping blocks ("add a protein column"), never by writing new code.
//! Published with the agent (`pack`), the software goes too: its blocks and
//! their shape, never your data.

use std::sync::Arc;

use cookie_harness::tool::{tool, Effect, Tool};
use parallax::{Parallax, Step};
use serde_json::{json, Value};

use crate::events::TeamEvent;
use crate::{util, Team};

/// Tools that only look; the rest change something (in a world, or your folder on keep).
const LOOKS: &[&str] = &["parallax_actions", "parallax_worlds", "parallax_preview", "parallax_timeline", "parallax_diff", "parallax_waiting"];

impl Team {
    /// Parallax, opened on first use in Cookie's own folder.
    pub fn parallax(&self) -> Result<Arc<Parallax>, String> {
        if let Some(p) = self.px.get() {
            return Ok(p.clone());
        }
        let p = Parallax::open(self.paths.root.join("parallax"))?;
        Ok(self.px.get_or_init(|| p).clone())
    }

    /// The agent's workspace world, made the first time.
    pub fn workspace_world(&self, agent: &str) -> Result<String, String> {
        let px = self.parallax()?;
        if let Some(w) = px.worlds.list().into_iter().find(|w| w.owner == agent && w.name == "workspace") {
            return Ok(w.id);
        }
        Ok(px.worlds.create("workspace", None, agent)?.id)
    }

    /// The workspace as the panel draws it: the layout and each block's contents.
    pub async fn workspace(&self, agent: &str) -> Result<Value, String> {
        let px = self.parallax()?;
        let w = self.workspace_world(agent)?;
        let layout = px.act(&w, &Step { engine: "blocks".into(), action: "layout".into(), args: json!({}) }, None).await?.result;
        let mut blocks = Vec::new();
        for b in layout["blocks"].as_array().into_iter().flatten() {
            let name = b["name"].as_str().unwrap_or("");
            let kind = b["kind"].as_str().unwrap_or("");
            let content = match kind {
                "sheet" => px.act(&w, &Step { engine: "sheet".into(), action: "get".into(), args: json!({"path": b["path"]}) }, None).await.map(|o| o.result),
                "document" => px.act(&w, &Step { engine: "files".into(), action: "read".into(), args: json!({"path": b["path"]}) }, None).await.map(|o| o.result),
                "pdf" => px.act(&w, &Step { engine: "pdf".into(), action: "info".into(), args: json!({"path": b["path"]}) }, None).await.map(|o| o.result),
                _ => px.act(&w, &Step { engine: "blocks".into(), action: "get".into(), args: json!({"name": name}) }, None).await.map(|o| o.result),
            };
            blocks.push(json!({"name": name, "kind": kind, "title": b["title"], "path": b["path"], "content": content.unwrap_or_else(|e| json!({"error": e}))}));
        }
        let history: Vec<Value> = px.worlds.timeline(&w).into_iter().rev().filter(|e| e.kind == "do").take(20).map(|e| json!({"change": e.change, "what": e.what, "at": e.at, "args": e.args})).collect();
        Ok(json!({"world": w, "title": layout["title"], "blocks": blocks, "history": history}))
    }

    /// The person's own change in an agent's workspace (through Do, so undoable).
    pub async fn workspace_do(&self, agent: &str, engine: &str, action: &str, args: Value) -> Result<Value, String> {
        if !matches!(engine, "blocks" | "sheet" | "document" | "pdf") {
            return Err("A workspace changes through its blocks.".into());
        }
        let px = self.parallax()?;
        let w = self.workspace_world(agent)?;
        let out = px.act(&w, &Step { engine: engine.into(), action: action.into(), args }, None).await?;
        self.emit(TeamEvent::Workspace { agent: agent.into() });
        Ok(json!(out))
    }

    pub async fn workspace_undo(&self, agent: &str, change: &str) -> Result<Value, String> {
        let px = self.parallax()?;
        let w = self.workspace_world(agent)?;
        if !change.starts_with(&format!("{w}:")) {
            return Err("That change isn't in this workspace.".into());
        }
        let r = px.undo(change)?;
        self.emit(TeamEvent::Workspace { agent: agent.into() });
        Ok(r)
    }

    /// Set up a workspace from a ready template (the Gym Trainer's).
    pub async fn workspace_template(&self, agent: &str, template: &str) -> Result<Value, String> {
        let steps: Vec<(&str, Value)> = match template {
            "gym-trainer" => vec![
                ("add_block", json!({"name": "plan", "kind": "calendar", "title": "This week's plan"})),
                ("add_block", json!({"name": "log", "kind": "tracker", "title": "Workout log", "setup": {"columns": [
                    {"name": "date", "type": "date"}, {"name": "exercise", "type": "text"}, {"name": "sets", "type": "number"},
                    {"name": "reps", "type": "number"}, {"name": "weight", "type": "number"}, {"name": "done", "type": "yes/no"}]}})),
                ("add_block", json!({"name": "body", "kind": "tracker", "title": "Body", "setup": {"columns": [
                    {"name": "date", "type": "date"}, {"name": "weight", "type": "number"}, {"name": "energy", "type": "choice", "options": ["low", "ok", "high"]}]}})),
                ("add_block", json!({"name": "progress", "kind": "chart", "title": "Lifting progress", "setup": {"source": "log", "x": "date", "y": ["weight"], "kind": "line"}})),
                ("add_block", json!({"name": "checkin", "kind": "form", "title": "Weekly check-in", "setup": {"fields": [
                    {"name": "body_weight", "type": "number", "required": true}, {"name": "sleep_hours", "type": "number"}, {"name": "how_it_went", "type": "text"}]}})),
            ],
            other => return Err(format!("No template called {other}.")),
        };
        for (action, args) in steps {
            self.workspace_do(agent, "blocks", action, args).await?;
        }
        self.workspace(agent).await
    }

    /// The software to publish with an agent: its blocks and their shape, not the person's data.
    pub async fn software_of(&self, agent: &str) -> Option<Value> {
        let ws = self.workspace(agent).await.ok()?;
        let blocks: Vec<Value> = ws["blocks"].as_array()?.iter().map(|b| {
            let c = &b["content"];
            let setup = match b["kind"].as_str().unwrap_or("") {
                "tracker" => json!({"columns": c["data"]["columns"]}),
                "board" => json!({"stages": c["data"]["stages"]}),
                "chart" => json!({"source": c["source"], "x": c["x"], "y": c["y"], "kind": c["chart"]}),
                "form" => json!({"fields": c["data"]["fields"]}),
                _ => json!({}),
            };
            json!({"name": b["name"], "kind": b["kind"], "title": b["title"], "setup": setup})
        }).filter(|b| !matches!(b["kind"].as_str(), Some("sheet" | "document" | "pdf"))).collect();
        (!blocks.is_empty()).then(|| json!({"blocks": blocks}))
    }

    /// Recreate published software in a new agent's workspace (charts after their trackers).
    pub async fn install_software(&self, agent: &str, software: &Value) -> Result<(), String> {
        let mut blocks: Vec<Value> = software["blocks"].as_array().cloned().unwrap_or_default();
        blocks.sort_by_key(|b| b["kind"] == "chart");
        for b in blocks {
            self.workspace_do(agent, "blocks", "add_block", json!({"name": b["name"], "kind": b["kind"], "title": b["title"], "setup": b["setup"]})).await?;
        }
        Ok(())
    }

    /// The watch window: every world, what waits at the wall, the machine.
    pub fn watch(&self) -> Result<Value, String> {
        let px = self.parallax()?;
        Ok(json!({"status": px.status(), "worlds": px.worlds.list(), "waiting": px.ledger.waiting()}))
    }

    pub async fn decide_wall(&self, entry: &str, yes: bool) -> Result<Value, String> {
        let r = self.parallax()?.decide(entry, yes, "you").await;
        self.emit(TeamEvent::Worlds);
        r
    }

    /// One world's timeline and, for a change, what it changed (the Rewind viewer).
    pub fn world_timeline(&self, world: &str) -> Result<Value, String> {
        let px = self.parallax()?;
        let w = px.worlds.get(world)?;
        Ok(json!({"world": w, "timeline": px.worlds.timeline(world)}))
    }

    pub async fn world_call(&self, tool: &str, args: Value) -> Result<Value, String> {
        if !matches!(tool, "parallax_diff" | "parallax_rewind" | "parallax_keep" | "parallax_discard" | "parallax_undo" | "parallax_timeline") {
            return Err("The watch window only looks, rewinds, keeps, discards and undoes.".into());
        }
        let r = parallax::mcp::call(&self.parallax()?, tool, &args, "*").await;
        if tool != "parallax_diff" && tool != "parallax_timeline" {
            self.emit(TeamEvent::Worlds);
        }
        r
    }

    /// Count one connected-app call (Composio bills per call), per agent and day.
    pub(crate) fn count_app_call(&self, agent: &str) {
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = self.paths.agent(agent).join("app-calls.json");
        let mut days: std::collections::BTreeMap<u64, u64> = util::read_json(&path);
        *days.entry(util::now() / 86_400).or_default() += 1;
        while days.len() > 90 {
            let first = *days.keys().next().unwrap_or(&0);
            days.remove(&first);
        }
        let _ = util::write_json(&path, &days);
    }

    /// Connected-app calls by day (UTC day number → count), and today's and the month's totals.
    pub fn app_calls(&self, agent: &str) -> Value {
        let days: std::collections::BTreeMap<u64, u64> = util::read_json(&self.paths.agent(agent).join("app-calls.json"));
        let today = util::now() / 86_400;
        let last30: u64 = days.range(today.saturating_sub(29)..=today).map(|(_, n)| n).sum();
        let by_day: Vec<Value> = days.iter().map(|(d, n)| json!({"day": d * 86_400, "calls": n})).collect();
        json!({"today": days.get(&today).copied().unwrap_or(0), "last_30_days": last30, "by_day": by_day})
    }
}

/// Is `path` inside the agent's own folder or a folder the person gave agents?
fn allowed_folder(team: &Team, agent: &str, path: &str) -> Result<std::path::PathBuf, String> {
    let p = std::fs::canonicalize(path).map_err(|_| format!("No folder at {path}."))?;
    let own = std::fs::canonicalize(team.paths.work(agent)).unwrap_or_default();
    if p.starts_with(&own) {
        return Ok(p);
    }
    let access = team.access();
    if access.roots().iter().any(|r| std::fs::canonicalize(r).is_ok_and(|r| p.starts_with(r))) {
        return Ok(p);
    }
    Err("A world can be opened from your own folder, or a folder the person gave you.".into())
}

/// Parallax's tools for one agent, scoped to its own worlds.
pub(crate) fn tools(team: &Arc<Team>, agent: &str) -> Vec<Arc<dyn Tool>> {
    let mut out: Vec<Arc<dyn Tool>> = Vec::new();
    for spec in parallax::mcp::tools() {
        let name = spec["name"].as_str().unwrap_or_default().to_string();
        // Vaults need Linux with KVM. A team that runs on such a host (the cloud runner, beside its
        // worlds) runs them itself; otherwise they run on the person's cloud computer, if set up.
        if name.starts_with("parallax_vault") {
            if parallax::sizes::vault_available().is_ok() {
                out.push(local_vault_tool(team, agent, &spec));
            } else if team.computer().is_some() {
                out.push(vault_tool(team, agent, &spec));
            }
            continue;
        }
        let effect = if LOOKS.contains(&name.as_str()) { Effect::Read } else { Effect::Write };
        let (t, a, n) = (Arc::downgrade(team), agent.to_string(), name.clone());
        out.push(Arc::new(tool(&name, spec["description"].as_str().unwrap_or(""), spec["inputSchema"].clone(), effect, move |args: Value| {
            let (t, a, n) = (t.clone(), a.clone(), n.clone());
            async move {
                let team = t.upgrade().ok_or("Cookie is closing.")?;
                let px = team.parallax()?;
                let r = if n == "parallax_open" && args["from"].is_string() {
                    let from = allowed_folder(&team, &a, args["from"].as_str().unwrap_or(""))?;
                    json!(px.worlds.create(args["name"].as_str().unwrap_or("world"), Some(&from), &a)?)
                } else {
                    parallax::mcp::call(&px, &n, &args, &a).await?
                };
                if n == "parallax_do" && r["waiting"].is_string() {
                    team.notice(&a, "Waiting at the wall", "An agent's action reaches outside its world and waits for your yes (Worlds).", None, true);
                }
                Ok(util::clip(&serde_json::to_string_pretty(&r).unwrap_or_default(), 30_000))
            }
        })));
    }
    out
}

/// A vault tool run right here, on the host the team itself runs on: the agent's own Linux
/// machine, with root, any software it installs, and the internet when it was made with it.
fn local_vault_tool(team: &Arc<Team>, agent: &str, spec: &Value) -> Arc<dyn Tool> {
    let name = spec["name"].as_str().unwrap_or_default().to_string();
    let effect = if matches!(name.as_str(), "parallax_vaults" | "parallax_vault_look") { Effect::Read } else { Effect::Write };
    let (t, a, n) = (Arc::downgrade(team), agent.to_string(), name.clone());
    let about = format!(
        "{} This is your own computer, on the same host as you: you are root in it, can install anything (apt, pip, npm), \
         and it keeps its disk between jobs. Use it for any work a person would do at a Linux computer.",
        spec["description"].as_str().unwrap_or("")
    );
    Arc::new(tool(&name, &about, spec["inputSchema"].clone(), effect, move |args: Value| {
        let (t, a, n) = (t.clone(), a.clone(), n.clone());
        async move {
            let team = t.upgrade().ok_or("Cookie is closing.")?;
            let px = team.parallax()?;
            let r = parallax::mcp::call(&px, &n, &args, &a).await?;
            Ok(util::clip(&match r {
                Value::String(s) => s,
                v if v["output"].is_string() => format!("exit {}\n{}", v["code"], v["output"].as_str().unwrap_or("")),
                v => serde_json::to_string_pretty(&v).unwrap_or_default(),
            }, 30_000))
        }
    }))
}

/// A vault tool, run on the cloud computer as this agent (`as`): its own Linux machine with a desktop.
fn vault_tool(team: &Arc<Team>, agent: &str, spec: &Value) -> Arc<dyn Tool> {
    let name = spec["name"].as_str().unwrap_or_default().to_string();
    let effect = if matches!(name.as_str(), "parallax_vaults" | "parallax_vault_look") { Effect::Read } else { Effect::Write };
    let (t, a, n) = (Arc::downgrade(team), agent.to_string(), name.clone());
    let about = format!("{} It runs on your cloud computer, which wakes for it (about a minute when it's asleep).", spec["description"].as_str().unwrap_or(""));
    Arc::new(tool(&name, &about, spec["inputSchema"].clone(), effect, move |mut args: Value| {
        let (t, a, n) = (t.clone(), a.clone(), n.clone());
        async move {
            let team = t.upgrade().ok_or("Cookie is closing.")?;
            args["as"] = json!(a);
            let r = team.computer_px(&n, &args).await?;
            Ok(util::clip(&match r {
                Value::String(s) => s,
                v if v["output"].is_string() => format!("exit {}\n{}", v["code"], v["output"].as_str().unwrap_or("")),
                v => serde_json::to_string_pretty(&v).unwrap_or_default(),
            }, 30_000))
        }
    }))
}

/// The agent's own software: look at it, change it (through Do), undo.
pub(crate) fn workspace_tools(team: &Arc<Team>, agent: &str) -> Vec<Arc<dyn Tool>> {
    let (t1, a1) = (Arc::downgrade(team), agent.to_string());
    let (t2, a2) = (Arc::downgrade(team), agent.to_string());
    let (t3, a3) = (Arc::downgrade(team), agent.to_string());
    vec![
        Arc::new(tool("workspace_look", "Your own software (the workspace beside your chat): its blocks and what is in them.", json!({"type": "object", "properties": {}}), Effect::Read, move |_a: Value| {
            let (t, a) = (t1.clone(), a1.clone());
            async move { Ok(util::clip(&serde_json::to_string_pretty(&t.upgrade().ok_or("Cookie is closing.")?.workspace(&a).await?).unwrap_or_default(), 30_000)) }
        })),
        Arc::new(tool(
            "workspace_change",
            "Change your own software or what is in it, through its blocks: engine `blocks` (add_block, remove_block, add_row, update_row, delete_row, add_column, remove_column, add_card, move_card, add_event, remove_event, submit), or `sheet`/`document` on a block's file. Every change can be undone. Change the software only when the person asks or it clearly helps them.",
            json!({"type": "object", "properties": {"engine": {"type": "string", "enum": ["blocks", "sheet", "document"]}, "action": {"type": "string"}, "args": {"type": "object"}}, "required": ["engine", "action", "args"]}),
            Effect::Write,
            move |args: Value| {
                let (t, a) = (t2.clone(), a2.clone());
                async move {
                    let team = t.upgrade().ok_or("Cookie is closing.")?;
                    let r = team.workspace_do(&a, args["engine"].as_str().unwrap_or(""), args["action"].as_str().unwrap_or(""), args["args"].clone()).await?;
                    Ok(serde_json::to_string(&r).unwrap_or_default())
                }
            },
        )),
        Arc::new(tool("workspace_undo", "Undo a change in your software (by the change id workspace_change gave).", json!({"type": "object", "properties": {"change": {"type": "string"}}, "required": ["change"]}), Effect::Write, move |args: Value| {
            let (t, a) = (t3.clone(), a3.clone());
            async move { Ok(t.upgrade().ok_or("Cookie is closing.")?.workspace_undo(&a, args["change"].as_str().unwrap_or("")).await?.to_string()) }
        })),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn the_gym_trainer_comes_with_its_software_and_publishes_its_shape_not_data() {
        let dir = tempfile::tempdir().unwrap();
        let t = Team::open(dir.path()).unwrap();
        let ws = t.workspace_template("gym", "gym-trainer").await.unwrap();
        assert_eq!(ws["blocks"].as_array().unwrap().len(), 5);
        t.workspace_do("gym", "blocks", "add_row", json!({"name": "log", "values": {"date": "2026-11-24", "exercise": "squat", "weight": 80}})).await.unwrap();
        // The agent adds a column to its own software, and it can be undone.
        let out = t.workspace_do("gym", "blocks", "add_column", json!({"name": "log", "column": "protein", "type": "number"})).await.unwrap();
        let ws = t.workspace("gym").await.unwrap();
        let log = ws["blocks"].as_array().unwrap().iter().find(|b| b["name"] == "log").unwrap();
        assert!(log["content"]["data"]["columns"].as_array().unwrap().iter().any(|c| c["name"] == "protein"));
        t.workspace_undo("gym", out["change"].as_str().unwrap()).await.unwrap();
        let ws = t.workspace("gym").await.unwrap();
        let log = ws["blocks"].as_array().unwrap().iter().find(|b| b["name"] == "log").unwrap();
        assert!(!log["content"]["data"]["columns"].as_array().unwrap().iter().any(|c| c["name"] == "protein"));
        // Published: the shape, never the person's rows.
        let sw = t.software_of("gym").await.unwrap();
        assert!(!sw.to_string().contains("squat"));
        t.install_software("copy", &sw).await.unwrap();
        assert_eq!(t.workspace("copy").await.unwrap()["blocks"].as_array().unwrap().len(), 5);
        // Another agent's workspace is its own world.
        assert_ne!(t.workspace_world("gym").unwrap(), t.workspace_world("copy").unwrap());
    }
}
