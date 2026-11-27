//! Browser runs saved as recipes, replayed with no model.
//!
//! While an agent works in its browser, each step it takes (open a page, click,
//! type, go back) is noted. When a run worked, the agent may save it under a
//! name (`browser_save_run`); saving asks the person, with every step in front
//! of them, and typed text that changes each time is marked as a value to fill
//! in. A saved run is then replayed in one go (`browser_replay`, or by the
//! person from the app): Cookie finds each button and field again by its label
//! (numbers change between visits), with no model between the steps, which
//! makes it fast, cheap and the same every time. Replaying asks once, for the
//! whole run, with its steps shown. If the site has changed, the replay stops
//! at the first step it can't match and says which: nothing is guessed.
//!
//! In a script (`run_code`), every browser tool is callable too, and each click
//! or keystroke asks as it would outside one.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, LazyLock, Mutex};

use cookie_harness::tool::{tool, Effect, Tool};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{util, Team};

pub const SAVE_TOOL: &str = "browser_save_run";
const MOST_STEPS: usize = 60;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "do", rename_all = "snake_case")]
pub enum RunStep {
    Open { url: String },
    Click { label: String },
    /// `fill`: the name of a value given at each replay, instead of `text`.
    Type { label: String, text: String, submit: bool, fill: Option<String> },
    Back,
}

impl RunStep {
    fn said(&self) -> String {
        match self {
            RunStep::Open { url } => format!("open {url}"),
            RunStep::Click { label } => format!("click “{label}”"),
            RunStep::Type { label, text, submit, fill } => format!(
                "type {} into “{label}”{}",
                fill.as_ref().map(|f| format!("{{{f}}}")).unwrap_or_else(|| format!("“{}”", util::clip(text, 60))),
                if *submit { ", then Enter" } else { "" }
            ),
            RunStep::Back => "go back".into(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SavedRun {
    pub name: String,
    pub about: String,
    pub steps: Vec<RunStep>,
    pub saved_at: u64,
    #[serde(default)]
    pub replays: u32,
    #[serde(default)]
    pub failures: u32,
}

/// Each agent's current run, as its steps happen.
static LOGS: LazyLock<Mutex<HashMap<String, Vec<RunStep>>>> = LazyLock::new(Default::default);

/// Note a step of the agent's run; `fresh` starts a new run (a page opened by address).
pub(crate) fn record(agent: &str, step: RunStep, fresh: bool) {
    let mut logs = LOGS.lock().unwrap();
    let log = logs.entry(agent.to_string()).or_default();
    if fresh {
        log.clear();
    }
    if log.len() < MOST_STEPS {
        log.push(step);
    }
}

fn current(agent: &str) -> Vec<RunStep> {
    LOGS.lock().unwrap().get(agent).cloned().unwrap_or_default()
}

/// The run with the named typed steps turned into values to fill in.
fn with_fills(mut steps: Vec<RunStep>, fills: &BTreeMap<usize, String>) -> Result<Vec<RunStep>, String> {
    for (n, name) in fills {
        match steps.get_mut(n.wrapping_sub(1)) {
            Some(RunStep::Type { fill, .. }) => *fill = Some(name.clone()),
            _ => return Err(format!("Step {n} isn't one that types.")),
        }
    }
    Ok(steps)
}

fn dir(team: &Team, agent: &str) -> std::path::PathBuf {
    team.paths.agent(agent).join("browser-runs")
}

fn valid_name(n: &str) -> bool {
    !n.is_empty() && n.len() <= 40 && n.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
}

impl Team {
    pub fn browser_runs(&self, agent: &str) -> Vec<SavedRun> {
        let mut out: Vec<SavedRun> = std::fs::read_dir(dir(self, agent)).into_iter().flatten().flatten().filter_map(|e| util::read_json_opt(&e.path())).collect();
        out.sort_by(|a, b| a.name.cmp(&b.name));
        out
    }

    fn saved_run(&self, agent: &str, name: &str) -> Option<SavedRun> {
        util::read_json_opt(&dir(self, agent).join(format!("{name}.json")))
    }

    /// Replay a saved run (the person from the app, or the agent once they said yes).
    pub async fn replay_browser_run(&self, agent: &str, name: &str, values: &BTreeMap<String, String>) -> Result<String, String> {
        let mut run = self.saved_run(agent, name).ok_or_else(|| format!("No saved run called “{name}”."))?;
        let r = crate::browser::replay(self, agent, &run.steps, values).await;
        run.replays += 1;
        run.failures += r.is_err() as u32;
        let _ = util::write_json(&dir(self, agent).join(format!("{name}.json")), &run);
        r
    }
}

pub(crate) fn tools(team: &Arc<Team>, agent: &str) -> Vec<Arc<dyn Tool>> {
    let (w, a, pa) = (Arc::downgrade(team), agent.to_string(), agent.to_string());
    let save = tool(
        SAVE_TOOL,
        "Save the browser run you just did (from the last page you opened by address) as a recipe, to replay later in one go with \
         no model: name it, say what it does, and mark typed text that changes each time as a value (`fills`: step number → value name). \
         The person sees every step and says yes.",
        json!({"type": "object", "properties": {
            "name": {"type": "string", "description": "lowercase-with-dashes"},
            "about": {"type": "string"},
            "fills": {"type": "object", "description": "step number → value name, for typed steps whose text changes each time", "additionalProperties": {"type": "string"}}
        }, "required": ["name", "about"]}),
        Effect::Write,
        move |args: Value| {
            let (w, a) = (w.clone(), a.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                let name = args["name"].as_str().unwrap_or("").trim().to_string();
                if !valid_name(&name) {
                    return Err("Name it in lowercase-with-dashes, up to 40 characters.".into());
                }
                let steps = current(&a);
                if steps.is_empty() || !matches!(steps[0], RunStep::Open { .. }) {
                    return Err("There is no run to save: open a page by its address first, then do the steps.".into());
                }
                let fills: BTreeMap<usize, String> = args["fills"].as_object().into_iter().flatten().filter_map(|(k, v)| Some((k.parse().ok()?, v.as_str()?.to_string()))).collect();
                let steps = with_fills(steps, &fills)?;
                let run = SavedRun { name: name.clone(), about: util::clip(args["about"].as_str().unwrap_or(""), 300), steps, saved_at: util::now(), replays: 0, failures: 0 };
                std::fs::create_dir_all(dir(&team, &a)).map_err(|e| e.to_string())?;
                util::write_json(&dir(&team, &a).join(format!("{name}.json")), &run)?;
                Ok(format!("Saved “{name}” ({} steps). Replay it with browser_replay.", run.steps.len()))
            }
        },
    )
    .with_preview(move |args| {
        let fills: BTreeMap<usize, String> = args["fills"].as_object().into_iter().flatten().filter_map(|(k, v)| Some((k.parse().ok()?, v.as_str()?.to_string()))).collect();
        let steps = with_fills(current(&pa), &fills).unwrap_or_default();
        format!("Save a browser run “{}”: {}\n{}", args["name"].as_str().unwrap_or("?"), args["about"].as_str().unwrap_or(""), steps.iter().enumerate().map(|(i, s)| format!("{}. {}", i + 1, s.said())).collect::<Vec<_>>().join("\n"))
    });
    let saved = team.browser_runs(agent);
    if saved.is_empty() {
        return vec![Arc::new(save)];
    }
    let names: Vec<Value> = saved.iter().map(|r| json!(r.name)).collect();
    let listing = saved.iter().map(|r| format!("{} ({})", r.name, r.about)).collect::<Vec<_>>().join("; ");
    let (w, a) = (Arc::downgrade(team), agent.to_string());
    let runs = saved.clone();
    let replay = tool(
        "browser_replay",
        &format!("Replay a saved browser run in one go, with no model between its steps (fast, and the same each time). Give `values` for its fill-ins. The person approves the whole run once. Saved: {listing}"),
        json!({"type": "object", "properties": {"name": {"type": "string", "enum": names}, "values": {"type": "object", "additionalProperties": {"type": "string"}}}, "required": ["name"]}),
        Effect::Outbound,
        move |args: Value| {
            let (w, a) = (w.clone(), a.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                let values: BTreeMap<String, String> = args["values"].as_object().into_iter().flatten().filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string()))).collect();
                team.replay_browser_run(&a, args["name"].as_str().unwrap_or(""), &values).await
            }
        },
    )
    .with_preview(move |args| {
        let name = args["name"].as_str().unwrap_or("?");
        match runs.iter().find(|r| r.name == name) {
            Some(r) => format!(
                "Replay “{name}” in its browser ({}), all at once:\n{}{}",
                r.about,
                r.steps.iter().enumerate().map(|(i, s)| format!("{}. {}", i + 1, s.said())).collect::<Vec<_>>().join("\n"),
                args["values"].as_object().filter(|v| !v.is_empty()).map(|v| format!("\nWith: {}", v.iter().map(|(k, x)| format!("{k} = {}", x.as_str().unwrap_or(""))).collect::<Vec<_>>().join(", "))).unwrap_or_default()
            ),
            None => format!("Replay “{name}”"),
        }
    });
    vec![Arc::new(save), Arc::new(replay)]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_run_is_noted_from_the_page_opened_and_its_changing_text_becomes_a_value() {
        record("t-agent", RunStep::Click { label: "old".into() }, false);
        record("t-agent", RunStep::Open { url: "https://shop.example/".into() }, true);
        record("t-agent", RunStep::Type { label: "Search".into(), text: "running shoes".into(), submit: true, fill: None }, false);
        record("t-agent", RunStep::Click { label: "Add to basket".into() }, false);
        let steps = current("t-agent");
        assert_eq!(steps.len(), 3, "a fresh page starts a fresh run");
        let filled = with_fills(steps, &BTreeMap::from([(2, "item".to_string())])).unwrap();
        assert_eq!(filled[1].said(), "type {item} into “Search”, then Enter");
        assert!(with_fills(filled.clone(), &BTreeMap::from([(3, "x".to_string())])).is_err(), "only a typing step takes a value");
    }

    /// Live: a real headless Chrome replays a saved run against a page on this computer.
    /// `cargo test -p cookie-team live_browser -- --ignored` (needs Chrome).
    #[tokio::test]
    #[ignore]
    async fn live_browser_replay_finds_the_field_by_its_label_and_fills_the_value() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let seen: Arc<Mutex<Vec<String>>> = Default::default();
        let s2 = seen.clone();
        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else { return };
                let mut buf = vec![0u8; 8192];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                let line = String::from_utf8_lossy(&buf[..n]).lines().next().unwrap_or("").to_string();
                s2.lock().unwrap().push(line.clone());
                let body = if line.contains("/done") { "<html><title>Done</title><body>Thanks</body></html>".to_string() } else {
                    "<html><title>Form</title><body><form action=\"/done\"><input name=\"who\" aria-label=\"Your name\"><button>Send</button></form></body></html>".to_string()
                };
                let _ = sock.write_all(format!("HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len()).as_bytes()).await;
            }
        });
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        crate::browser::init(dir.path());
        std::fs::create_dir_all(team.paths.work("b")).unwrap();
        let steps = vec![
            RunStep::Open { url: format!("{base}/") },
            RunStep::Type { label: "Your name".into(), text: "placeholder".into(), submit: true, fill: Some("name".into()) },
        ];
        let out = crate::browser::replay(&team, "b", &steps, &BTreeMap::from([("name".to_string(), "Ada".to_string())])).await.unwrap();
        println!("{out}");
        assert!(seen.lock().unwrap().iter().any(|l| l.contains("/done?who=Ada")), "the page got the value: {:?}", seen.lock().unwrap());
        let missing = vec![RunStep::Open { url: format!("{base}/") }, RunStep::Click { label: "A button that isn't there".into() }];
        let e = crate::browser::replay(&team, "b", &missing, &BTreeMap::new()).await.unwrap_err();
        assert!(e.contains("Step 2") && e.contains("isn't on the page"), "it stops and says where: {e}");
    }

    #[test]
    fn a_saved_run_reads_back_as_it_was_written() {
        let run = SavedRun { name: "reorder".into(), about: "reorder coffee".into(), steps: vec![RunStep::Open { url: "https://shop.example/".into() }, RunStep::Back], saved_at: 1, replays: 0, failures: 0 };
        let back: SavedRun = serde_json::from_value(serde_json::to_value(&run).unwrap()).unwrap();
        assert_eq!(back, run);
    }
}
