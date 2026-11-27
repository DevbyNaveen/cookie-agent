//! Tools an agent makes for itself, when none it has fits.
//!
//! The agent writes a small Python program (its arguments arrive as JSON on
//! stdin, its answer is what it prints), with one example call and what its
//! answer must contain. Cookie runs that example in the agent's own cage; only
//! a program whose example passes can be kept, and keeping one asks the person
//! once, with its code in front of them (research on self-written skills found
//! that unchecked ones help about as often as they hurt; checked and reviewed
//! ones help). From the next job on it is a tool like any other, `own_<name>`,
//! run in the same cage: offline unless it was made to fetch from the web, and
//! never with the person's private data either way (it is given only its
//! arguments and the agent's own folder).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use cookie_harness::tool::{tool, Effect, Tool};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{util, Team};

pub const SAVE_TOOL: &str = "make_tool";
/// Tools one agent may keep.
const MOST_KEPT: usize = 100;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct OwnTool {
    pub name: String,
    pub description: String,
    /// The JSON schema of its arguments.
    pub schema: Value,
    pub online: bool,
    pub made_at: u64,
    /// Calls and failures since it was kept: a tool that keeps failing is shown so.
    #[serde(default)]
    pub calls: u32,
    #[serde(default)]
    pub failures: u32,
    /// `on_trial` until its replay exam and its use say otherwise; `kept` or `retired` after.
    #[serde(default = "on_trial")]
    pub state: String,
    /// What its replay exam and its use came to.
    #[serde(default)]
    pub verdict: String,
}

fn on_trial() -> String {
    "on_trial".into()
}

/// Calls on trial before its record of use counts; a failure share above this retires it.
const TRIAL_CALLS: u32 = 8;
const MOST_FAILING: f64 = 0.4;

fn dir(team: &Team, agent: &str) -> PathBuf {
    team.paths.agent(agent).join("own-tools")
}

fn valid_name(n: &str) -> bool {
    !n.is_empty() && n.len() <= 40 && n.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_') && n.chars().next().is_some_and(|c| c.is_ascii_lowercase())
}

impl Team {
    pub fn own_tools(&self, agent: &str) -> Vec<OwnTool> {
        util::read_json(&dir(self, agent).join("index.json"))
    }

    fn save_own_tools(&self, agent: &str, all: &[OwnTool]) -> Result<(), String> {
        util::write_json(&dir(self, agent).join("index.json"), &all)
    }
}

/// Runs `code` with `args` in the agent's cage, in a scratch folder inside its own one.
pub(crate) async fn run_program(team: &Arc<Team>, agent: &str, code: &str, args: &Value, online: bool) -> Result<String, String> {
    let cage = team.cage(agent).ok_or("This computer has no sandbox to run it in.")?;
    let cage: Arc<dyn cookie_harness::sandbox::Sandbox> = Arc::new(crate::cage::Cage { cfg: crate::cage::CageCfg { network: online, ..cage.cfg.clone() }, ..(*cage).clone() });
    let work = team.paths.work(agent);
    let scratch = work.join(".own-tool-run").join(util::new_id("run"));
    std::fs::create_dir_all(&scratch).map_err(|e| e.to_string())?;
    std::fs::write(scratch.join("tool.py"), code).map_err(|e| e.to_string())?;
    std::fs::write(scratch.join("args.json"), args.to_string()).map_err(|e| e.to_string())?;
    let rel = scratch.strip_prefix(&work).unwrap_or(Path::new(".")).to_string_lossy().to_string();
    let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"].into_iter().find(|p| Path::new(p).exists()).ok_or("No Python 3 on this computer.")?;
    let cmd = cookie_harness::sandbox::command_tool("own", cage, &work).map_err(|e| e.to_string())?;
    let out = cmd.call(json!({"command": format!("PYTHONDONTWRITEBYTECODE=1 {python} -I {rel}/tool.py < {rel}/args.json")})).await;
    let _ = std::fs::remove_dir_all(&scratch);
    let out = out?;
    // The sandbox reports "exit code: N" first; a program that failed is an error, not an answer.
    if let Some(code) = out.lines().next().and_then(|l| l.strip_prefix("exit code: ")).and_then(|c| c.trim().parse::<i32>().ok()) {
        if code != 0 {
            return Err(util::clip(&out, 4000));
        }
    }
    Ok(util::clip(&out, 20_000))
}

/// `make_tool`, and each tool the agent kept, for one job.
pub(crate) fn tools(team: &Arc<Team>, agent: &str) -> Vec<Arc<dyn Tool>> {
    let mut out: Vec<Arc<dyn Tool>> = Vec::new();
    if team.cage(agent).is_none() {
        return out;
    }
    let (w, a) = (Arc::downgrade(team), agent.to_string());
    out.push(Arc::new(
        tool(
            SAVE_TOOL,
            "Make yourself a new tool when none you have fits and you'll need it again: a Python 3 program that reads its arguments as \
             JSON from stdin and prints its answer. Give one example call (`example_args`) and words its answer must contain \
             (`expect`): it is run once in your sandbox and kept only if that passes, and the person sees its code before it is kept. \
             From your next job it is the tool `own_<name>`. Set online=true only if it must fetch from the web; it never gets the \
             person's private data, only its arguments.",
            json!({"type": "object", "properties": {
                "name": {"type": "string", "description": "lowercase_with_underscores"},
                "description": {"type": "string", "description": "what it does and when to use it"},
                "args_schema": {"type": "object", "description": "JSON schema of its arguments"},
                "code": {"type": "string"},
                "example_args": {"type": "object"},
                "expect": {"type": "string", "description": "text its answer to the example must contain"},
                "online": {"type": "boolean"}
            }, "required": ["name", "description", "code", "example_args", "expect"]}),
            Effect::Write,
            move |args: Value| {
                let (w, a) = (w.clone(), a.clone());
                async move {
                    let team = w.upgrade().ok_or("Cookie is closing.")?;
                    let name = args["name"].as_str().unwrap_or_default().trim().to_string();
                    if !valid_name(&name) {
                        return Err("Name it in lowercase_with_underscores, starting with a letter, up to 40 characters.".into());
                    }
                    let code = args["code"].as_str().unwrap_or_default();
                    let expect = args["expect"].as_str().unwrap_or_default().trim();
                    if code.trim().is_empty() || expect.is_empty() {
                        return Err("Give its code and what its example answer must contain.".into());
                    }
                    let online = args["online"].as_bool().unwrap_or(false);
                    let answer = run_program(&team, &a, code, &args["example_args"], online).await.map_err(|e| format!("Its example failed, so it wasn't kept:\n{e}"))?;
                    if !answer.contains(expect) {
                        return Err(format!("Its example ran but its answer doesn't contain “{expect}”, so it wasn't kept. It said:\n{}", util::clip(&answer, 2000)));
                    }
                    let mut all = team.own_tools(&a);
                    all.retain(|t| t.name != name);
                    if all.len() >= MOST_KEPT {
                        return Err(format!("You keep {MOST_KEPT} tools already; retire one first."));
                    }
                    let d = dir(&team, &a);
                    std::fs::create_dir_all(&d).map_err(|e| e.to_string())?;
                    std::fs::write(d.join(format!("{name}.py")), code).map_err(|e| e.to_string())?;
                    let schema = if args["args_schema"].is_object() { args["args_schema"].clone() } else { json!({"type": "object"}) };
                    all.push(OwnTool { name: name.clone(), description: args["description"].as_str().unwrap_or_default().to_string(), schema, online, made_at: util::now(), calls: 0, failures: 0, state: on_trial(), verdict: String::new() });
                    team.save_own_tools(&a, &all)?;
                    // Replayed against its past work, with the tool and without: one that makes its
                    // work worse is retired, whatever its example said.
                    let (t2, a2, n2) = (team.clone(), a.clone(), name.clone());
                    tokio::spawn(async move { t2.replay_own_tool(&a2, &n2).await });
                    Ok(format!("Kept on trial: own_{name}. Its example passed; it is being replayed against your past work, and it stays only if it doesn't make that work worse and keeps working when you use it."))
                }
            },
        )
        .with_preview(|args| {
            format!(
                "Keep a tool it made, `own_{}`{}: {}\n\nIts code:\n{}",
                args["name"].as_str().unwrap_or("?"),
                if args["online"].as_bool().unwrap_or(false) { " (reaches the web)" } else { "" },
                args["description"].as_str().unwrap_or(""),
                util::clip(args["code"].as_str().unwrap_or(""), 4000)
            )
        }),
    ));
    for t in team.own_tools(agent).into_iter().filter(|t| t.state != "retired") {
        let (w, a, name, online) = (Arc::downgrade(team), agent.to_string(), t.name.clone(), t.online);
        out.push(Arc::new(tool(&format!("own_{}", t.name), &format!("{} (a tool you made)", t.description), t.schema.clone(), Effect::Write, move |args: Value| {
            let (w, a, name) = (w.clone(), a.clone(), name.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                let code = std::fs::read_to_string(dir(&team, &a).join(format!("{name}.py"))).map_err(|_| "Its code is gone.".to_string())?;
                let r = run_program(&team, &a, &code, &args, online).await;
                let mut all = team.own_tools(&a);
                if let Some(x) = all.iter_mut().find(|x| x.name == name) {
                    x.calls += 1;
                    x.failures += r.is_err() as u32;
                    // Its record of use: one that keeps failing is retired.
                    if x.calls >= TRIAL_CALLS && x.failures as f64 / x.calls as f64 > MOST_FAILING {
                        x.state = "retired".into();
                        x.verdict = format!("Retired: {} of its {} calls failed.", x.failures, x.calls);
                    }
                }
                let _ = team.save_own_tools(&a, &all);
                r
            }
        })));
    }
    out
}

impl Team {
    /// The replay exam of a tool it made: its past work with the tool and without it, judged the
    /// same way. Fewer passed with it: retired. Otherwise it stays (most past work didn't need it,
    /// so a tie is what a useful new tool scores on history it never saw), and its use decides.
    pub(crate) async fn replay_own_tool(self: &Arc<Self>, agent: &str, name: &str) {
        let Ok(rec) = self.agent(agent).await else { return };
        let verdict = if !self.may_spend() {
            Err("not replayed: skill tests reached this month's limit".to_string())
        } else {
            let with = crate::bench::Variant { own_tools: true, ..Default::default() };
            let without = crate::bench::Variant::default();
            self.skill_exam(&rec, &format!("Tool it made: own_{name}"), with, without).await.map(|(t, _)| t)
        };
        let mut all = self.own_tools(agent);
        let Some(x) = all.iter_mut().find(|x| x.name == name) else { return };
        match verdict {
            Ok(t) if t.with < t.without => {
                x.state = "retired".into();
                x.verdict = format!("Retired: replayed on {} of its past jobs, {} passed with it and {} without.", t.total, t.with, t.without);
                self.notice(agent, &format!("A tool it made was retired: own_{name}"), &x.verdict, None, false);
            }
            Ok(t) => x.verdict = format!("Replayed on {} of its past jobs: {} passed with it, {} without. On trial in use.", t.total, t.with, t.without),
            Err(e) => x.verdict = e,
        }
        let _ = self.save_own_tools(agent, &all);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tool_name_is_plain() {
        assert!(valid_name("price_watch") && valid_name("csv2json"));
        assert!(!valid_name("Price") && !valid_name("../x") && !valid_name("1st") && !valid_name(""));
    }

    #[tokio::test]
    #[cfg(target_os = "macos")]
    async fn a_tool_is_kept_only_when_its_example_passes_and_then_it_is_offered() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        let _ = std::fs::create_dir_all(team.paths.work("a"));
        let tools = tools(&team, "a");
        let Some(make) = tools.iter().find(|t| t.spec().name == SAVE_TOOL) else { return }; // no sandbox here
        let code = "import json,sys\na=json.load(sys.stdin)\nprint(a['x']*2)\n";
        let bad = make.call(json!({"name": "double", "description": "doubles", "code": code, "example_args": {"x": 2}, "expect": "5"})).await;
        assert!(bad.unwrap_err().contains("wasn't kept"));
        let crash = make.call(json!({"name": "crash", "description": "x", "code": "import sys\nprint('4')\nsys.exit(3)\n", "example_args": {}, "expect": "4"})).await;
        assert!(crash.unwrap_err().contains("example failed"), "a program that exits non-zero is never kept, whatever it printed");
        let ok = make.call(json!({"name": "double", "description": "doubles", "code": code, "example_args": {"x": 2}, "expect": "4"})).await.unwrap();
        assert!(ok.contains("own_double") && ok.contains("on trial"), "{ok}");
        let again = super::tools(&team, "a");
        let own = again.iter().find(|t| t.spec().name == "own_double").expect("offered next time");
        assert!(own.call(json!({"x": 21})).await.unwrap().contains("42"));
    }
}
