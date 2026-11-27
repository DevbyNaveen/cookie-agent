//! Workers that make things, side by side, each in a copy of the world.
//!
//! Helpers only read. A worker writes: the agent splits a piece of work into
//! parts, each part gets an instant fork of one of its Parallax worlds and a
//! fresh agent that works only there, with Parallax's verbs and nothing that
//! reaches outside. They run at the same time; when they finish, their copies
//! are merged back file by file (`Worlds::merge`): what one worker changed is
//! taken, what two changed differently is named as a conflict for the agent
//! to settle, and the merge can be rewound as one step. Many writers, no
//! shared state, one join: the shape where a team of agents actually beats one.

use std::sync::{Arc, Weak};

use async_trait::async_trait;
use cookie_harness::tool::{tool, Effect, Tool, ToolContext, ToolSpec};
use cookie_harness::{Agent, Budget, Message, Price};
use serde_json::{json, Value};
use tokio::sync::Semaphore;

use crate::store::AgentRecord;
use crate::{util, Team};

pub const NAME: &str = "workers";
/// Workers running at once in one call.
const AT_ONCE: usize = 8;
/// Parts one call may split into.
const MOST_PARTS: usize = 24;
/// Model calls one worker may make: a guard; its real limit is the job's budget, shared.
const WORKER_STEPS: usize = 200;

/// The verbs a worker has, each bound to its own copy.
const WORKER_VERBS: [&str; 7] = ["parallax_actions", "parallax_preview", "parallax_do", "parallax_undo", "parallax_script", "parallax_diff", "parallax_timeline"];

const PROMPT: &str = "You are a worker: one part of a bigger piece of work, handed to you by an agent that works for a person. \
You work in your own copy of a Parallax world (your tools already point at it). Do the whole part there: make the files, \
run the scripts, check the result. Change only what your part needs, so your copy merges cleanly with the other workers'. \
Nothing you do leaves the world. End with a short report: what you made (file paths), how you checked it, what is left.";

/// One worker's copy, bound into each of Parallax's tools for it.
fn bound_tools(team: &Weak<Team>, agent: &str, fork: &str) -> Vec<Arc<dyn Tool>> {
    let mut out: Vec<Arc<dyn Tool>> = Vec::new();
    for spec in parallax::mcp::tools() {
        let name = spec["name"].as_str().unwrap_or_default().to_string();
        if !WORKER_VERBS.contains(&name.as_str()) {
            continue;
        }
        let mut schema = spec["inputSchema"].clone();
        if let Some(p) = schema["properties"].as_object_mut() {
            p.remove("world");
        }
        if let Some(r) = schema["required"].as_array_mut() {
            r.retain(|x| x != "world");
        }
        let effect = if matches!(name.as_str(), "parallax_actions" | "parallax_preview" | "parallax_diff" | "parallax_timeline") { Effect::Read } else { Effect::Write };
        let (t, a, f, n) = (team.clone(), agent.to_string(), fork.to_string(), name.clone());
        out.push(Arc::new(tool(&name, spec["description"].as_str().unwrap_or(""), schema, effect, move |mut args: Value| {
            let (t, a, f, n) = (t.clone(), a.clone(), f.clone(), n.clone());
            async move {
                let team = t.upgrade().ok_or("Cookie is closing.")?;
                args["world"] = json!(f);
                let r = parallax::mcp::call(&team.parallax()?, &n, &args, &a).await?;
                Ok(util::clip(&serde_json::to_string_pretty(&r).unwrap_or_default(), 30_000))
            }
        })));
    }
    out
}

pub struct Workers {
    spec: ToolSpec,
    team: Weak<Team>,
    agent: String,
    model: String,
    price: Option<Price>,
}

/// The `workers` tool for an agent with worlds.
pub(crate) fn tool_for(team: &Arc<Team>, rec: &AgentRecord, price: Option<Price>) -> Arc<dyn Tool> {
    let spec = ToolSpec {
        name: NAME.into(),
        description: format!(
            "Split work into parts done at the same time by workers, each in its own instant copy of one of your Parallax worlds, \
             then merged back into it. For work with separate pieces that each make or change things (chapters, pages, modules, \
             one sheet per region). Up to {MOST_PARTS} parts, {AT_ONCE} at a time. You get each worker's report and what merged; a file \
             two workers changed differently is left as it was and named, for you to settle. The merge can be rewound."
        ),
        schema: json!({"type": "object", "properties": {
            "world": {"type": "string", "description": "the world to split the work over (its id)"},
            "parts": {"type": "array", "maxItems": MOST_PARTS, "items": {"type": "object", "properties": {
                "title": {"type": "string", "description": "3 to 6 words"},
                "task": {"type": "string", "description": "the whole part, with what done looks like and which files are its own"}
            }, "required": ["title", "task"]}}
        }, "required": ["world", "parts"]}),
        effect: Effect::Write,
        guarded_args: Vec::new(),
        parallel_safe: false,
        delegates: true,
        foreign: false,
    };
    Arc::new(Workers { spec, team: Arc::downgrade(team), agent: rec.id.clone(), model: rec.model.clone(), price })
}

#[async_trait]
impl Tool for Workers {
    fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    async fn call(&self, args: Value) -> Result<String, String> {
        self.call_in(args, &ToolContext::default()).await
    }

    async fn call_in(&self, args: Value, context: &ToolContext) -> Result<String, String> {
        let team = self.team.upgrade().ok_or("Cookie is closing.")?;
        let px = team.parallax()?;
        let base = args["world"].as_str().ok_or("Name the `world`.")?.to_string();
        let world = px.worlds.get(&base)?;
        if world.owner != self.agent {
            return Err("That world isn't yours.".into());
        }
        let parts: Vec<(String, String)> = args["parts"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|p| Some((p["title"].as_str()?.trim().to_string(), p["task"].as_str()?.trim().to_string())))
            .filter(|(_, t)| !t.is_empty())
            .take(MOST_PARTS)
            .collect();
        if parts.len() < 2 {
            return Err("Give at least two parts; one part is just your own work.".into());
        }
        let before = parallax::world::digests(&px.worlds.files(&base)?);
        let mut forks = Vec::new();
        for (title, _) in &parts {
            forks.push(px.worlds.fork(&base, Some(&format!("{} · {title}", world.name)))?.id);
        }
        let gate = Arc::new(Semaphore::new(AT_ONCE));
        let runs = parts.iter().zip(&forks).enumerate().map(|(i, ((title, task), fork))| {
            let gate = gate.clone();
            let tools = bound_tools(&self.team, &self.agent, fork);
            async move {
                let _slot = gate.acquire().await;
                let mut agent = match Agent::new(&self.model) {
                    Ok(a) => a,
                    Err(e) => return (i, title.clone(), Err(e.to_string())),
                };
                agent = agent
                    .instructions(PROMPT)
                    .tools(tools)
                    .without_enkeon()
                    // Its copy is its own and can be rewound: nothing in it needs anyone.
                    .policy(WORKER_VERBS.iter().fold(cookie_harness::policy::Policy::default(), |p, t| p.contained(t)))
                    .approver(cookie_harness::DenyAll)
                    // A guard against circling; its real limit is the job's own budget, shared with it.
                    .budget(Budget { max_steps: WORKER_STEPS, max_tokens: u64::MAX, max_dollars: None, max_seconds: None })
                    .close_with_answer();
                if let Some(p) = self.price {
                    agent = agent.prices(p);
                }
                let (reply, _spent, _events) = agent.run_delegated(&format!("worker {}", i + 1), Message::user(task.clone()), context).await;
                (i, title.clone(), reply.map_err(|e| e.to_string()))
            }
        });
        let mut reports = futures::future::join_all(runs).await;
        reports.sort_by_key(|(i, _, _)| *i);
        let merged = px.worlds.merge(&base, &before, &forks);
        for f in &forks {
            let _ = px.worlds.discard(f);
        }
        let merged = merged?;
        let mut out = String::new();
        for (i, title, r) in &reports {
            out.push_str(&format!("## Worker {} · {title}\n{}\n\n", i + 1, match r {
                Ok(a) => util::clip(a, 3000),
                Err(e) => format!("(didn't finish: {e})"),
            }));
        }
        out.push_str(&format!(
            "## Merged into {}\n{} files merged. {}Undo the whole merge with parallax_rewind to checkpoint {}.",
            world.name,
            merged["applied"].as_array().map_or(0, Vec::len),
            match merged["conflicts"].as_array().filter(|c| !c.is_empty()) {
                Some(c) => format!("Conflicts, left as they were for you to settle: {}. ", c.iter().map(|x| format!("{} ({})", x["path"].as_str().unwrap_or("?"), x["why"].as_str().unwrap_or(""))).collect::<Vec<_>>().join("; ")),
                None => String::new(),
            },
            merged["undo_checkpoint"]
        ));
        Ok(out)
    }

    fn preview(&self, args: &Value) -> String {
        let titles: Vec<String> = args["parts"].as_array().into_iter().flatten().filter_map(|p| p["title"].as_str().map(str::to_string)).collect();
        format!("{} workers, each in a copy of world {}: {}", titles.len(), args["world"].as_str().unwrap_or("?"), titles.join(", "))
    }
}

/* ---------- racing approaches, judged by another model ---------- */

pub const RACE: &str = "race";
const RACE_MOST: usize = 6;

const JUDGE: &str = "You judge a race between attempts at the same piece of work, for a person. Each attempt was made in its own copy \
of a world; you see what each changed and what its maker reported. Pick the one that best meets the criteria. Judge only by \
the criteria and the evidence in front of you; an attempt's own claims about itself count for nothing without the changes to \
show them. Reply with JSON only: {\"winner\": <attempt number>, \"why\": \"one or two sentences\"}, or {\"winner\": 0, \"why\": \"…\"} \
when none meets the criteria.";

pub struct Race {
    spec: ToolSpec,
    team: Weak<Team>,
    agent: String,
    model: String,
    price: Option<Price>,
}

/// The `race` tool: several approaches tried at once, each by a worker in its own copy, judged by another model.
pub(crate) fn race_tool(team: &Arc<Team>, rec: &AgentRecord, price: Option<Price>) -> Arc<dyn Tool> {
    let spec = ToolSpec {
        name: RACE.into(),
        description: format!(
            "Try 2 to {RACE_MOST} different approaches to the same piece of work at once, each by a worker in its own copy of one of your worlds; \
             a separate model (never you, never the workers) judges them against your criteria and only the winner is merged back. \
             For work with no test to run: a design, a page, a plan, a piece of writing. When a shell command can tell (tests), use parallax_race."
        ),
        schema: json!({"type": "object", "properties": {
            "world": {"type": "string"},
            "task": {"type": "string", "description": "the work, the same for every attempt"},
            "approaches": {"type": "array", "minItems": 2, "maxItems": RACE_MOST, "items": {"type": "string"}, "description": "how each attempt goes about it"},
            "criteria": {"type": "string", "description": "what the judge picks by"}
        }, "required": ["world", "task", "approaches", "criteria"]}),
        effect: Effect::Write,
        guarded_args: Vec::new(),
        parallel_safe: false,
        delegates: true,
        foreign: false,
    };
    Arc::new(Race { spec, team: Arc::downgrade(team), agent: rec.id.clone(), model: rec.model.clone(), price })
}

/// The judge's pick: an attempt number (1-based, 0 for none) and why.
fn pick_of(reply: &str) -> Option<(usize, String)> {
    let t = reply.trim();
    let t = t.strip_prefix("```json").or_else(|| t.strip_prefix("```")).map_or(t, |x| x.trim_end_matches("```").trim());
    let start = t.find('{')?;
    let v: Value = serde_json::from_str(&t[start..=t.rfind('}')?]).ok()?;
    Some((v["winner"].as_u64()? as usize, v["why"].as_str().unwrap_or("").to_string()))
}

#[async_trait]
impl Tool for Race {
    fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    async fn call(&self, args: Value) -> Result<String, String> {
        self.call_in(args, &ToolContext::default()).await
    }

    async fn call_in(&self, args: Value, context: &ToolContext) -> Result<String, String> {
        let team = self.team.upgrade().ok_or("Cookie is closing.")?;
        let px = team.parallax()?;
        let base = args["world"].as_str().ok_or("Name the `world`.")?.to_string();
        let world = px.worlds.get(&base)?;
        if world.owner != self.agent {
            return Err("That world isn't yours.".into());
        }
        let task = args["task"].as_str().unwrap_or("").trim().to_string();
        let criteria = args["criteria"].as_str().unwrap_or("").trim().to_string();
        let approaches: Vec<String> = args["approaches"].as_array().into_iter().flatten().filter_map(|a| a.as_str()).map(|a| a.trim().to_string()).filter(|a| !a.is_empty()).take(RACE_MOST).collect();
        if approaches.len() < 2 || task.is_empty() || criteria.is_empty() {
            return Err("A race needs the task, its criteria and at least two approaches.".into());
        }
        let before = parallax::world::digests(&px.worlds.files(&base)?);
        let mut forks = Vec::new();
        for (i, _) in approaches.iter().enumerate() {
            forks.push(px.worlds.fork(&base, Some(&format!("{} · race {}", world.name, i + 1)))?.id);
        }
        let runs = approaches.iter().zip(&forks).enumerate().map(|(i, (how, fork))| {
            let tools = bound_tools(&self.team, &self.agent, fork);
            let input = format!("{task}\n\nYour approach: {how}");
            async move {
                let mut agent = match Agent::new(&self.model) {
                    Ok(a) => a,
                    Err(e) => return (i, Err(e.to_string())),
                };
                agent = agent
                    .instructions(PROMPT)
                    .tools(tools)
                    .without_enkeon()
                    .policy(WORKER_VERBS.iter().fold(cookie_harness::policy::Policy::default(), |p, t| p.contained(t)))
                    .approver(cookie_harness::DenyAll)
                    .budget(Budget { max_steps: WORKER_STEPS, max_tokens: u64::MAX, max_dollars: None, max_seconds: None })
                    .close_with_answer();
                if let Some(p) = self.price {
                    agent = agent.prices(p);
                }
                let (reply, _, _) = agent.run_delegated(&format!("race attempt {}", i + 1), Message::user(input), context).await;
                (i, reply.map_err(|e| e.to_string()))
            }
        });
        let mut reports = futures::future::join_all(runs).await;
        reports.sort_by_key(|(i, _)| *i);
        // What each attempt changed, for the judge: the evidence, not the claims.
        let base_files = px.worlds.files(&base)?;
        let mut evidence = format!("Task: {task}\nCriteria: {criteria}\n\n");
        for ((i, r), fork) in reports.iter().zip(&forks) {
            let diff = px.worlds.files(fork).map(|f| parallax::world::diff_dirs(&base_files, &f)).unwrap_or(Value::Null);
            evidence.push_str(&format!(
                "<attempt n=\"{}\" approach=\"{}\">\nWhat it changed:\n{}\nIts report:\n{}\n</attempt>\n\n",
                i + 1,
                approaches[*i].replace('"', "'"),
                util::clip(&diff.to_string(), 8000),
                match r { Ok(a) => util::clip(a, 2000), Err(e) => format!("(didn't finish: {e})") }
            ));
        }
        let judge_model = team.judge_model(&self.model).await;
        let judge = Agent::new(&judge_model).map_err(|e| format!("No judge: {e}"))?.instructions(JUDGE).without_enkeon().close_with_answer();
        let (verdict, _, _) = judge.run_delegated("race judge", Message::untrusted(evidence, cookie_harness::label::Source::File), context).await;
        let (winner, why) = verdict.ok().and_then(|v| pick_of(&v)).unwrap_or((0, "The judge gave no clear pick.".into()));
        let mut out = String::new();
        for (i, r) in &reports {
            out.push_str(&format!("## Attempt {} · {}\n{}\n\n", i + 1, approaches[*i], match r { Ok(a) => util::clip(a, 1500), Err(e) => format!("(didn't finish: {e})") }));
        }
        let kept = if (1..=forks.len()).contains(&winner) && reports[winner - 1].1.is_ok() {
            let m = px.worlds.merge(&base, &before, &[forks[winner - 1].clone()])?;
            format!("Winner: attempt {winner}, judged by {} — {why}\nMerged into {}: {} files. Undo with parallax_rewind to checkpoint {}.", crate::failover::short(&judge_model), world.name, m["applied"].as_array().map_or(0, Vec::len), m["undo_checkpoint"])
        } else {
            format!("No attempt was kept: {why} The world is as it was.")
        };
        for f in &forks {
            let _ = px.worlds.discard(f);
        }
        out.push_str(&kept);
        Ok(out)
    }

    fn preview(&self, args: &Value) -> String {
        format!("Race {} approaches in copies of world {}: {}", args["approaches"].as_array().map_or(0, Vec::len), args["world"].as_str().unwrap_or("?"), args["task"].as_str().unwrap_or(""))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Live: a real model builds two parts at once in copies of a world and they merge back.
    /// `COOKIE_LIVE_MODEL=anthropic:claude-haiku-5-5 ANTHROPIC_API_KEY=… cargo test -p cookie-team live_ -- --ignored`
    #[tokio::test]
    #[ignore]
    async fn live_workers_build_two_parts_in_copies_and_they_merge() {
        let model = std::env::var("COOKIE_LIVE_MODEL").unwrap_or_else(|_| "anthropic:claude-haiku-5-5".into());
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        let rec = team
            .add_agent(crate::AgentRecord {
                id: "w".into(), name: "Builder".into(), model: model.clone(), job: "builds things".into(), created_at: 0,
                grants: crate::store::Grants::none(), limits: Default::default(), probation_until: None, parent: None, shadow_of: None, handover: None, origin: None, version: 1,
            })
            .await
            .unwrap();
        let world = team.parallax().unwrap().worlds.create("site", None, "w").unwrap();
        let tool = tool_for(&team, &rec, None);
        let out = tool
            .call(json!({"world": world.id, "parts": [
                {"title": "About page", "task": "Create the file about.html: a short HTML page that says 'About us'. Use parallax_actions to see how to write a file, then do it."},
                {"title": "Contact page", "task": "Create the file contact.html: a short HTML page that says 'Contact us'. Use parallax_actions to see how to write a file, then do it."}
            ]}))
            .await
            .unwrap();
        println!("{out}");
        let files = team.parallax().unwrap().worlds.files(&world.id).unwrap();
        assert!(files.join("about.html").exists() && files.join("contact.html").exists(), "both parts merged back:\n{out}");
        assert!(std::fs::read_to_string(files.join("about.html")).unwrap().contains("About"));
    }

    /// Live: two approaches raced, a separate model picks one, only it is merged.
    #[tokio::test]
    #[ignore]
    async fn live_race_keeps_only_the_judged_winner() {
        let model = std::env::var("COOKIE_LIVE_MODEL").unwrap_or_else(|_| "anthropic:claude-haiku-5-5".into());
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        let rec = team
            .add_agent(crate::AgentRecord {
                id: "w".into(), name: "Writer".into(), model, job: "writes".into(), created_at: 0,
                grants: crate::store::Grants::none(), limits: Default::default(), probation_until: None, parent: None, shadow_of: None, handover: None, origin: None, version: 1,
            })
            .await
            .unwrap();
        let world = team.parallax().unwrap().worlds.create("copy", None, "w").unwrap();
        let out = race_tool(&team, &rec, None)
            .call(json!({"world": world.id, "task": "Write a one-line tagline for a bakery into tagline.txt (use parallax_actions to see how to write a file).",
                         "approaches": ["warm and homely", "short and witty"], "criteria": "the shorter, clearer line wins"}))
            .await
            .unwrap();
        println!("{out}");
        let files = team.parallax().unwrap().worlds.files(&world.id).unwrap();
        assert!(out.contains("Winner") == files.join("tagline.txt").exists(), "merged exactly when there is a winner:\n{out}");
    }

    #[test]
    fn the_judges_pick_is_read_from_its_reply() {
        assert_eq!(pick_of("{\"winner\": 2, \"why\": \"clearer\"}"), Some((2, "clearer".into())));
        assert_eq!(pick_of("```json\n{\"winner\": 0, \"why\": \"none fits\"}\n```").map(|p| p.0), Some(0));
        assert_eq!(pick_of("I like the second one"), None);
    }
}
