//! A helper's or a contractor's own work, as a thread: every step it takes
//! shows the moment it happens (`TeamEvent::HelperStep`), and the whole thread
//! (its title, task, steps, sites, report and time) is kept in the agent's
//! `threads.jsonl`, so a reopened chat shows the same thread it showed live.
//!
//! The steps come from the harness itself (`ToolContext::watched`): what the
//! helper really called, never what its report says it did.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};
use std::time::Instant;

use cookie_harness::agent::Event;
use cookie_harness::tool::Watch;
use serde::{Deserialize, Serialize};

use crate::events::TeamEvent;
use crate::{util, Team};

/// One step of a thread, as kept.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct ThreadStep {
    pub did: String,
    #[serde(default)]
    pub ms: u64,
    #[serde(default = "yes")]
    pub ok: bool,
    /// The site it read or searched, for its icon.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    /// `search`, `page` or `other`.
    #[serde(default)]
    pub kind: String,
}

fn yes() -> bool {
    true
}

/// A whole thread, as kept and as the chat shows it after a reload.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct ThreadRecord {
    pub at: u64,
    pub job: String,
    pub n: usize,
    /// The step's own key: the task as the step carries it (`TeamEvent::Step::thread`).
    pub task: String,
    pub title: String,
    /// `done`, `failed` or `stopped`.
    pub state: String,
    #[serde(default)]
    pub report: String,
    #[serde(default)]
    pub steps: Vec<ThreadStep>,
    #[serde(default)]
    pub ms: u64,
    /// Where helpers of its batch disagreed (filled when a chat is opened).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub conflicts: Vec<Conflict>,
}

/// Helpers of one batch that came back saying different things.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Conflict {
    pub job: String,
    pub between: Vec<usize>,
    pub about: String,
    pub detail: String,
}

/// Keep a disagreement, so the reopened chat shows it where it was found.
pub(crate) fn save_conflict(team: &Team, agent: &str, c: &Conflict) {
    let _ = util::append_jsonl(&team.paths.agent(agent).join("conflicts.jsonl"), c);
}

impl ThreadRecord {
    /// Pages it read and searches it ran: the counts the chat shows.
    pub fn counts(&self) -> (usize, usize) {
        let pages = self.steps.iter().filter(|s| s.kind == "page" && s.ok).count();
        let searches = self.steps.iter().filter(|s| s.kind == "search").count();
        (pages, searches)
    }
}

/// A thread while it runs.
pub(crate) struct Thread {
    team: Weak<Team>,
    agent: String,
    job: String,
    n: usize,
    task: String,
    title: String,
    began: Instant,
    steps: Mutex<Vec<ThreadStep>>,
    /// Calls in flight: their place in `steps` and when they began.
    open: Mutex<HashMap<String, (usize, Instant)>>,
}

impl Thread {
    pub(crate) fn new(team: Weak<Team>, agent: &str, job: &str, n: usize, task: &str, title: &str) -> Arc<Self> {
        Arc::new(Self {
            team,
            agent: agent.into(),
            job: job.into(),
            n,
            task: task.into(),
            title: title.into(),
            began: Instant::now(),
            steps: Mutex::new(Vec::new()),
            open: Mutex::new(HashMap::new()),
        })
    }

    /// What the harness calls with each of the sub-agent's events, live.
    pub(crate) fn watch(self: &Arc<Self>) -> Watch {
        let me = Arc::downgrade(self);
        Arc::new(move |event: &Event| {
            if let Some(me) = me.upgrade() {
                me.on(event);
            }
        })
    }

    fn on(&self, event: &Event) {
        let Some(team) = self.team.upgrade() else { return };
        match event {
            Event::ToolCallStarted { id, name } => {
                let (doing, did, _) = crate::steps::words(&team, name, &serde_json::Value::Null);
                let at = {
                    let mut steps = self.steps.lock().unwrap();
                    steps.push(ThreadStep { did: did.clone(), ms: 0, ok: true, host: None, kind: kind(name).into() });
                    steps.len() - 1
                };
                self.open.lock().unwrap().insert(id.clone(), (at, Instant::now()));
                self.emit(&team, id, name, doing, did, "running", None);
            }
            Event::ToolCallReady { id, name, args } => {
                let (doing, did, _) = crate::steps::words(&team, name, args);
                let host = host_of(args);
                if let Some((at, _)) = self.open.lock().unwrap().get(id).copied() {
                    if let Some(s) = self.steps.lock().unwrap().get_mut(at) {
                        s.did = did.clone();
                        s.host = host.clone();
                    }
                }
                self.emit(&team, id, name, doing, did, "running", host);
            }
            Event::ToolFinished { id, is_error } => {
                let Some((at, began)) = self.open.lock().unwrap().remove(id) else { return };
                let step = {
                    let mut steps = self.steps.lock().unwrap();
                    let Some(s) = steps.get_mut(at) else { return };
                    s.ms = began.elapsed().as_millis() as u64;
                    s.ok = !is_error;
                    s.clone()
                };
                let name = match step.kind.as_str() {
                    "search" => "web_search",
                    "page" => "read_url",
                    _ => "",
                };
                self.emit(&team, id, name, step.did.clone(), step.did, if *is_error { "failed" } else { "done" }, step.host);
            }
            _ => {}
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn emit(&self, team: &Team, id: &str, name: &str, doing: String, did: String, state: &str, host: Option<String>) {
        team.emit(TeamEvent::HelperStep {
            job: self.job.clone(),
            agent: self.agent.clone(),
            n: self.n,
            id: id.into(),
            name: name.into(),
            doing,
            did,
            state: state.into(),
            host,
        });
    }

    /// The finished thread, kept for the chat.
    pub(crate) fn save(&self, state: &str, report: &str) {
        let Some(team) = self.team.upgrade() else { return };
        let record = ThreadRecord {
            at: util::now(),
            job: self.job.clone(),
            n: self.n,
            task: self.task.clone(),
            title: self.title.clone(),
            state: state.into(),
            report: util::clip(report, 20_000),
            steps: self.steps.lock().unwrap().clone(),
            ms: self.began.elapsed().as_millis() as u64,
            conflicts: Vec::new(),
        };
        let _ = util::append_jsonl(&path(&team, &self.agent), &record);
    }
}

fn path(team: &Team, agent: &str) -> std::path::PathBuf {
    team.paths.agent(agent).join("threads.jsonl")
}

/// Every kept thread of an agent, by its task (the latest when one task ran twice).
pub(crate) fn load(team: &Team, agent: &str) -> HashMap<String, ThreadRecord> {
    let conflicts = util::read_jsonl::<Conflict>(&team.paths.agent(agent).join("conflicts.jsonl"));
    util::read_jsonl::<ThreadRecord>(&path(team, agent))
        .into_iter()
        .map(|mut t| {
            t.conflicts = conflicts.iter().filter(|c| c.job == t.job).cloned().collect();
            (t.task.clone(), t)
        })
        .collect()
}

fn kind(name: &str) -> &'static str {
    match name {
        "web_search" | "find_images" => "search",
        "read_url" | "read_page" | "browser_open" | "browser_read" => "page",
        _ => "other",
    }
}

/// The site a call reads, from its `url`.
fn host_of(args: &serde_json::Value) -> Option<String> {
    let url = args["url"].as_str()?.trim();
    let rest = url.split("//").nth(1)?;
    let host = rest.split(['/', '?', '#']).next()?.trim_start_matches("www.");
    (!host.is_empty() && host.contains('.')).then(|| host.to_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_thread_reports_each_step_live_and_keeps_them() {
        let dir = std::env::temp_dir().join(format!("threads-{}", std::process::id()));
        let team = Arc::new(Team::open(&dir).unwrap());
        let mut rx = team.subscribe();
        let t = Thread::new(Arc::downgrade(&team), "a", "j1", 1, "Find X", "X");
        let w = t.watch();
        w(&Event::ToolCallStarted { id: "c1".into(), name: "read_url".into() });
        w(&Event::ToolCallReady { id: "c1".into(), name: "read_url".into(), args: json!({"url": "https://www.example.com/p"}) });
        w(&Event::ToolFinished { id: "c1".into(), is_error: false });
        let mut states = Vec::new();
        while let Ok(e) = rx.try_recv() {
            if let TeamEvent::HelperStep { state, host, n, .. } = e {
                assert_eq!(n, 1);
                states.push((state, host));
            }
        }
        assert_eq!(states.first().map(|s| s.0.as_str()), Some("running"));
        assert_eq!(states.last(), Some(&("done".to_string(), Some("example.com".to_string()))));
        t.save("done", "found it");
        let kept = load(&team, "a");
        let r = &kept["Find X"];
        assert_eq!(r.steps.len(), 1);
        assert_eq!(r.steps[0].did, "Read a page on example.com");
        assert_eq!(r.counts(), (1, 0));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
