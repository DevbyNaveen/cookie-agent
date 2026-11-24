//! What an agent can use, built per job from its grants. Off means the tool
//! is not offered at all: a model cannot misuse what it was never shown.
//!
//! - files: `search_files`, `read_file` (harness `local` tools, scoped to its
//!   own folder) and `write_file` (only inside that folder).
//! - web: `web_search` (with a search key) and `read_url`.
//! - shell: `run_command`, sandboxed: its folder only, no network, no keys.
//! - routines: `set_routine`, `list_routines`, `stop_routine`.
//! - team: `ask_agent` hands a task to another of your agents and waits for
//!   its answer; both records keep the receipt.
//! - peers: `message_agent` talks to another person's agent it was allowed
//!   to, over A2A. Always asks you first (it sends).

use std::path::PathBuf;
use std::sync::{Arc, Weak};

use cookie_harness::tool::{tool, Effect, Tool};
use serde_json::{json, Value};

use crate::store::{AgentRecord, Schedule, Trigger};
use crate::{util, Team};

/// How deep a chain of agents asking agents may go.
pub const MAX_CHAIN: usize = 3;

pub(crate) fn for_agent(team: &Arc<Team>, rec: &AgentRecord, trigger: &Trigger, job: &str) -> Vec<Arc<dyn Tool>> {
    let g = &rec.grants;
    let work = team.paths.work(&rec.id);
    let _ = std::fs::create_dir_all(&work);
    let mut out: Vec<Arc<dyn Tool>> = Vec::new();

    if g.files || g.web {
        let search = if g.web { cookie_harness::local::Search::from_env() } else { None };
        for t in cookie_harness::local::tools(g.files.then(|| work.clone()), search, true) {
            let name = t.spec().name.clone();
            let keep = match name.as_str() {
                "search_files" | "read_file" => g.files,
                "web_search" | "read_url" => g.web,
                _ => false,
            };
            if keep {
                out.push(t);
            }
        }
    }
    if g.files {
        out.push(Arc::new(write_file(work.clone())));
    }
    if g.shell {
        if let Some(sandbox) = cookie_harness::sandbox::detect() {
            if let Ok(cmd) = cookie_harness::sandbox::command_tool("run_command", sandbox, &work) {
                out.push(Arc::new(cmd.timeout(std::time::Duration::from_secs(120))));
            }
        }
    }
    if g.routines {
        out.extend(routine_tools(Arc::downgrade(team), rec.id.clone()));
    }
    // Talking to anyone, by address: teammates, contacts, invited agents.
    if let Some(t) = crate::talk::message_tool(team, rec, trigger) {
        out.push(t);
    }
    // Contacts the person accepted for this agent. Not offered to people
    // reaching it from outside, so a contact can't relay through it.
    if !matches!(trigger, Trigger::Contact { .. } | Trigger::Room { .. } | Trigger::Peer { .. }) {
        out.extend(crate::network::contact_tools(team, rec));
    }
    // Its own skills (it reads them; writing one asks you), what it knows
    // about you, and its own past.
    let outside = matches!(trigger, Trigger::Contact { .. } | Trigger::Room { .. } | Trigger::Peer { .. });
    if rec.grants.memory {
        let viewed = std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashSet::new()));
        let skills = crate::learning::skill_tools(team, &rec.id, viewed, "written");
        if outside {
            out.extend(skills.into_iter().filter(|t| t.spec().name != "skill_manage"));
        } else {
            out.extend(skills);
            out.extend(crate::learning::about_tools(team));
            out.push(crate::learning::search_tool(team, &rec.id));
        }
    }
    out.extend(crate::workbench::tools(team, &rec.id, &rec.name, trigger));
    // The person's own files beyond its folder (Settings → Your files), never for
    // someone reaching it from outside: a contact can't read your Documents through it.
    if g.files && !outside {
        out.extend(crate::access::tools(team, &rec.id, job));
    }
    // Cookie sees the whole team (who's working, what waits on the person).
    if rec.id == crate::front::COOKIE_ID && !outside {
        out.push(crate::front::overview_tool(Arc::downgrade(team)));
    }
    // The Mac's own apps, never for someone reaching it from outside.
    if g.mac && !outside {
        out.extend(crate::mac::tools());
    }
    // Code that calls its read-only tools (only with "Run commands" on, never for outsiders).
    if g.shell && !outside {
        if let Some(t) = crate::code::run_code_tool(&work, &out) {
            out.push(t);
        }
    }
    // Talking to outsiders at talk level, or in a room: reading only. Tools
    // that would change something aren't shown, so the agent never offers.
    let read_only = matches!(trigger, Trigger::Room { .. }) || matches!(trigger, Trigger::Contact { level, .. } if level == "talk");
    if read_only {
        out.retain(|t| t.spec().effect == Effect::Read);
    }
    out
}

fn write_file(root: PathBuf) -> impl Tool {
    tool(
        "write_file",
        "Write a text file in your own folder (creates folders as needed, replaces the file if it exists). \
         `path` is relative to your folder. Use it for drafts, notes and results the person can open.",
        json!({"type": "object", "properties": {
            "path": {"type": "string", "description": "relative path, e.g. drafts/reply-to-anna.md"},
            "content": {"type": "string"}
        }, "required": ["path", "content"]}),
        Effect::Write,
        move |args: Value| {
            let root = root.clone();
            async move {
                let rel = args["path"].as_str().unwrap_or_default();
                let content = args["content"].as_str().unwrap_or_default();
                if content.len() > 2_000_000 {
                    return Err("That file is over 2 MB; split it.".into());
                }
                let path = util::inside(&root, rel).ok_or_else(|| format!("`{rel}` is outside your folder."))?;
                if let Some(dir) = path.parent() {
                    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
                }
                std::fs::write(&path, content).map_err(|e| e.to_string())?;
                Ok(format!("Wrote {rel} ({} bytes).", content.len()))
            }
        },
    )
    .with_preview(|args| format!("Write {}:\n{}", args["path"].as_str().unwrap_or("?"), util::clip(args["content"].as_str().unwrap_or(""), 1500)))
}

fn schedule_of(args: &Value) -> Result<Schedule, String> {
    let at = || args["at"].as_str().map(str::to_string).ok_or_else(|| "Say the time, as HH:MM.".to_string());
    let s = match args["every"].as_str().unwrap_or_default() {
        "day" => Schedule::Day { at: at()? },
        "weekday" => Schedule::Weekday { at: at()? },
        "week" => Schedule::Week { day: args["day"].as_str().unwrap_or("mon").to_string(), at: at()? },
        "minutes" => Schedule::Minutes { n: args["minutes"].as_u64().unwrap_or(60) as u32 },
        other => return Err(format!("`every` must be day, weekday, week or minutes, not `{other}`.")),
    };
    crate::routines::validate(&s)?;
    Ok(s)
}

fn routine_tools(team: Weak<Team>, agent: String) -> Vec<Arc<dyn Tool>> {
    let t1 = team.clone();
    let a1 = agent.clone();
    let set = tool(
        "set_routine",
        "Set up a standing job you will do on a schedule, in this computer's local time. Asks the person first.",
        json!({"type": "object", "properties": {
            "task": {"type": "string", "description": "what to do each time, as an instruction to yourself"},
            "every": {"type": "string", "enum": ["day", "weekday", "week", "minutes"]},
            "at": {"type": "string", "description": "HH:MM, 24-hour (for day, weekday, week)"},
            "day": {"type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]},
            "minutes": {"type": "integer", "minimum": 15, "description": "for every=minutes"}
        }, "required": ["task", "every"]}),
        Effect::Write,
        move |args: Value| {
            let (team, agent) = (t1.clone(), a1.clone());
            async move {
                let team = team.upgrade().ok_or("Cookie is closing.")?;
                let schedule = schedule_of(&args)?;
                let task = args["task"].as_str().unwrap_or_default().trim().to_string();
                if task.is_empty() {
                    return Err("Say what the routine does.".into());
                }
                let r = team.add_routine(&agent, &task, schedule).await?;
                Ok(format!("Routine set: {} ({}). Next run: {}.", r.task, crate::routines::describe(&r.schedule), r.next_run.map(crate::routines::local_time).unwrap_or_default()))
            }
        },
    )
    .with_preview(|args| format!("Every {} {} {}: {}", args["every"].as_str().unwrap_or("?"), args["day"].as_str().unwrap_or(""), args["at"].as_str().unwrap_or(""), args["task"].as_str().unwrap_or("")));
    let t2 = team.clone();
    let a2 = agent.clone();
    let list = tool(
        "list_routines",
        "Your routines: what each does, when, and when it runs next.",
        json!({"type": "object", "properties": {}}),
        Effect::Read,
        move |_args: Value| {
            let (team, agent) = (t2.clone(), a2.clone());
            async move {
                let team = team.upgrade().ok_or("Cookie is closing.")?;
                let rs = team.routines_of(&agent).await;
                if rs.is_empty() {
                    return Ok("No routines.".into());
                }
                Ok(rs.iter().map(|r| format!("{} | {} | {} | {}", r.id, crate::routines::describe(&r.schedule), if r.enabled { "on" } else { "off" }, r.task)).collect::<Vec<_>>().join("\n"))
            }
        },
    );
    let t3 = team;
    let a3 = agent;
    let stop = tool(
        "stop_routine",
        "Turn one of your routines off, by its id from list_routines.",
        json!({"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]}),
        Effect::Write,
        move |args: Value| {
            let (team, agent) = (t3.clone(), a3.clone());
            async move {
                let team = team.upgrade().ok_or("Cookie is closing.")?;
                let id = args["id"].as_str().unwrap_or_default();
                if !team.routines_of(&agent).await.iter().any(|r| r.id == id) {
                    return Err("That isn't one of your routines.".into());
                }
                team.set_routine_enabled(id, false).await?;
                Ok("Stopped.".into())
            }
        },
    );
    vec![Arc::new(set), Arc::new(list), Arc::new(stop)]
}

#[allow(dead_code)]
fn ask_agent(team: Weak<Team>, me: AgentRecord, chain: Vec<String>) -> impl Tool {
    tool(
        "ask_agent",
        "Hand a task to another of the person's agents (by name) and wait for its answer. \
         Use it when the work belongs to that agent's job. It works with its own tools and rules.",
        json!({"type": "object", "properties": {
            "agent": {"type": "string", "description": "the other agent's name"},
            "task": {"type": "string", "description": "what you need, with everything it needs to know"}
        }, "required": ["agent", "task"]}),
        Effect::Write,
        move |args: Value| {
            let (team, me, chain) = (team.clone(), me.clone(), chain.clone());
            async move {
                let team = team.upgrade().ok_or("Cookie is closing.")?;
                let name = args["agent"].as_str().unwrap_or_default();
                let task = args["task"].as_str().unwrap_or_default().trim().to_string();
                let other = team.agent_named(name).await.ok_or_else(|| format!("There is no agent called {name}."))?;
                if other.id == me.id {
                    return Err("That's you.".into());
                }
                if chain.contains(&other.id) {
                    return Err(format!("{} is already part of this chain; ask the person instead.", other.name));
                }
                let mut chain = chain;
                chain.push(me.id.clone());
                let job = team
                    .run_and_wait(&other.id, task.clone(), Vec::new(), Trigger::Handoff { from: me.id.clone(), chain })
                    .await?;
                match job.status {
                    crate::JobStatus::Done => Ok(format!("{} answered:\n{}", other.name, job.answer)),
                    _ => Err(format!("{} couldn't finish: {}", other.name, job.error.unwrap_or_else(|| "stopped".into()))),
                }
            }
        },
    )
    .with_preview(|args| format!("Ask {}: {}", args["agent"].as_str().unwrap_or("?"), util::clip(args["task"].as_str().unwrap_or(""), 600)))
}
