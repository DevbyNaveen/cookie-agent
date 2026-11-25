//! Cookie's team: separate, focused agents, each behind its own walls.
//!
//! One `Team` holds the roster and runs every agent's jobs. The desktop app,
//! a headless home runner and a cloud runner all drive the same `Team`; every
//! surface listens to one stream of [`TeamEvent`]s.

pub mod access;
pub mod api;
pub mod cage;
pub mod approvals;
pub mod apps;
pub mod bench;
pub mod boards;
pub mod browser;
pub mod challenge;
pub mod channels;
pub mod chatfiles;
pub mod checker;
pub mod cloud;
pub mod code;
pub mod computer;
pub mod evals;
pub mod events;
pub mod evolve;
pub mod experience;
pub mod front;
pub mod helpers;
pub mod hire_gap;
pub mod inbox;
pub mod inherit;
pub mod journal;
pub mod keys;
pub mod lease;
pub mod localmodels;
pub mod links;
pub mod learning;
pub mod mail;
pub mod mac;
pub mod memory;
pub mod mcp_server;
pub mod mcps;
pub mod mention;
pub mod network;
pub mod outcome;
pub mod pair;
pub mod passport;
pub mod pack;
pub mod peers;
pub mod prep;
pub mod privacy;
pub mod procedures;
pub mod rank;
pub mod readcache;
pub mod retro;
pub mod routines;
pub mod runtime;
pub mod scorecard;
pub mod scout;
pub mod sleep;
pub mod slack_agents;
pub mod server;
pub mod store;
pub mod talk;
pub mod toolsearch;
pub mod teamfile;
pub mod telegram;
pub mod tools;
pub mod triggers;
pub mod tuning;
pub mod util;
pub mod voice;
pub mod wake;
pub mod webhooks;
pub mod workbench;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, RwLock};

pub use events::{Approval, TeamEvent};
pub use store::{AgentRecord, Grants, Job, JobStatus, Limits, Routine, Schedule, Settings, Trigger};

use store::Paths;

/// What hiring needs.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct Hire {
    pub name: String,
    pub job: String,
    pub model: String,
    #[serde(default)]
    pub grants: Option<Grants>,
    /// Days to work in shadow before its changes are real (0 = none).
    #[serde(default)]
    pub probation_days: u32,
    /// A predecessor's handover note to start from (its file name).
    #[serde(default)]
    pub handover: Option<String>,
    /// The id it was shown with before hiring (its face is drawn from its id), so
    /// the face picked is the face hired. Used when free and well formed; else a new one.
    #[serde(default)]
    pub id: Option<String>,
    /// A retired agent's archive to start from (`inherit`): its lessons, skills, tests, habits and handover.
    #[serde(default)]
    pub inherit: Option<String>,
    /// A ready workspace to start with (`computer`): "gym-trainer".
    #[serde(default)]
    pub template: Option<String>,
}

/// A change to an agent's setup. Fields left out stay as they are.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct Patch {
    pub name: Option<String>,
    pub job: Option<String>,
    pub model: Option<String>,
    pub grants: Option<Grants>,
    pub limits: Option<Limits>,
    /// Some(0) ends probation now.
    pub probation_days: Option<u32>,
}

/// A roster row: the hire and what its sidebar line shows.
#[derive(Debug, Clone, Serialize)]
pub struct Row {
    #[serde(flatten)]
    pub agent: AgentRecord,
    pub last: Option<String>,
    pub last_at: Option<u64>,
    pub busy: bool,
    pub waiting: usize,
    /// Answers that arrived since the person last opened this agent.
    pub unread: usize,
    pub pinned: bool,
    pub hidden: bool,
    pub section: Option<String>,
}

/// How the person arranged the sidebar: pins, sections, hidden agents and
/// agents they marked unread. Kept by the team so every device sees the same list.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Sidebar {
    #[serde(default)]
    pub pinned: Vec<String>,
    #[serde(default)]
    pub hidden: Vec<String>,
    #[serde(default)]
    pub sections: std::collections::BTreeMap<String, String>,
    #[serde(default)]
    pub marked_unread: Vec<String>,
}

/// One change to an agent's place in the sidebar; absent fields stay as they are.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct SidebarPatch {
    pub pinned: Option<bool>,
    pub hidden: Option<bool>,
    /// `""` takes the agent out of its section.
    pub section: Option<String>,
    pub unread: Option<bool>,
}

pub struct Team {
    pub paths: Paths,
    pub keys: keys::Keys,
    pub(crate) agents: RwLock<Vec<AgentRecord>>,
    /// Parallax, opened on first use (`computer`).
    pub(crate) px: std::sync::OnceLock<Arc<parallax::Parallax>>,
    pub(crate) settings: RwLock<Settings>,
    pub(crate) routines: RwLock<Vec<Routine>>,
    pub(crate) runs: std::sync::Mutex<HashMap<String, runtime::Run>>,
    pub(crate) pending: std::sync::Mutex<HashMap<String, approvals::Pending>>,
    pub(crate) traces: std::sync::Mutex<HashMap<String, Arc<std::sync::Mutex<cookie_harness::trace::TraceLog>>>>,
    pub(crate) notices: std::sync::Mutex<approvals::NoticeBook>,
    pub(crate) net: network::Net,
    pub(crate) chans: channels::Channels,
    /// Questions agents asked the person, waiting for an answer.
    pub(crate) questions: std::sync::Mutex<HashMap<String, workbench::PendingQuestion>>,
    /// Each agent's live plan for its current job.
    pub(crate) todo_lists: std::sync::Mutex<HashMap<String, Vec<workbench::Todo>>>,
    /// The team itself, for background work started from `&self`.
    pub(crate) me: std::sync::Mutex<std::sync::Weak<Team>>,
    events: broadcast::Sender<TeamEvent>,
}

impl Team {
    /// Open (or start) a team in `dir`. Saved keys go into this process's environment.
    pub fn open(dir: impl Into<PathBuf>) -> Result<Arc<Self>, String> {
        let paths = Paths::new(dir);
        std::fs::create_dir_all(paths.agents_dir()).map_err(|e| e.to_string())?;
        std::fs::create_dir_all(paths.handovers()).map_err(|e| e.to_string())?;
        let keys = keys::Keys::new(&paths.root);
        keys.load_into_env();
        let agents: Vec<AgentRecord> = util::read_json(&paths.roster());
        let settings: Settings = std::fs::read(paths.settings())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let routines: Vec<Routine> = util::read_json(&paths.routines());
        let (events, _) = broadcast::channel(2048);
        Ok(Arc::new(Self {
            paths,
            keys,
            agents: RwLock::new(agents),
            px: std::sync::OnceLock::new(),
            settings: RwLock::new(settings),
            routines: RwLock::new(routines),
            runs: Default::default(),
            pending: Default::default(),
            traces: Default::default(),
            notices: Default::default(),
            net: Default::default(),
            chans: Default::default(),
            questions: Default::default(),
            todo_lists: Default::default(),
            me: Default::default(),
            events,
        }))
    }

    /// Start the background work: routines, Telegram, and the HTTP server when enabled.
    pub fn start(self: &Arc<Self>) {
        std::sync::LazyLock::force(&retro::STARTED);
        // Crash reports, if you turned them on (off by default).
        self.install_crash_reports();
        // Enkeon's key, if this computer was paired (before anything reads memory).
        self.load_pairing();
        routines::spawn_scheduler(self.clone());
        telegram::spawn(self.clone());
        server::spawn_if_enabled(self.clone());
        self.spawn_net();
        self.spawn_channels();
        // Agents with their own Slack account.
        self.spawn_agent_slacks();
        // Agents wake when their memory changes (with Enkeon connected).
        wake::spawn(self.clone());
        // Agents' browsers close when idle.
        browser::spawn_reaper();
        // With this Mac paired: the cloud runs its agents while it's off, and one store.
        cloud::spawn(self.clone());
        // Cookie, the agent everyone starts with, once there is a model for it.
        let me = self.clone();
        tokio::spawn(async move { me.ensure_cookie().await });
        // Jobs that were running when Cookie last stopped get an honest record.
        let me = self.clone();
        tokio::spawn(async move { me.recover_interrupted().await });
        // Memories of fired agents that Enkeon couldn't erase at the time.
        let me = self.clone();
        tokio::spawn(async move { me.retry_erasures().await });
        // Cards follow the roster: a hire, a rename or a firing republishes them.
        let team = Arc::downgrade(self);
        let mut rx = self.subscribe();
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(TeamEvent::RosterChanged) => {
                        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                        while rx.try_recv().is_ok() {}
                        match team.upgrade() {
                            Some(t) => t.publish_quietly().await,
                            None => return,
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => return,
                    _ => {}
                }
            }
        });
    }

    pub fn subscribe(&self) -> broadcast::Receiver<TeamEvent> {
        self.events.subscribe()
    }

    pub(crate) fn emit(&self, event: TeamEvent) {
        let _ = self.events.send(event);
    }

    /* ---------- roster ---------- */

    pub async fn agents(&self) -> Vec<AgentRecord> {
        self.agents.read().await.clone()
    }

    pub async fn agent(&self, id: &str) -> Result<AgentRecord, String> {
        self.agents.read().await.iter().find(|a| a.id == id).cloned().ok_or_else(|| "No such agent.".to_string())
    }

    pub async fn agent_named(&self, name: &str) -> Option<AgentRecord> {
        let n = name.trim().trim_start_matches('@').to_lowercase();
        self.agents.read().await.iter().find(|a| a.name.to_lowercase() == n || a.id == n).cloned()
    }

    async fn save_roster(&self, agents: &[AgentRecord]) -> Result<(), String> {
        util::write_json(&self.paths.roster(), agents)
    }

    /// Sidebar rows, most recent first.
    pub async fn rows(&self) -> Vec<Row> {
        let agents = self.agents().await;
        let busy: Vec<String> = self.runs.lock().unwrap().keys().cloned().collect();
        let waiting = self.pending_approvals();
        let read: std::collections::BTreeMap<String, u64> = util::read_json(&self.paths.root.join("read.json"));
        let side = self.sidebar();
        let mut rows: Vec<Row> = agents
            .into_iter()
            .filter(|a| a.shadow_of.is_none())
            .map(|agent| {
                let jobs: Vec<Job> = util::read_jsonl(&self.paths.jobs(&agent.id));
                let visible = |j: &&Job| matches!(j.trigger, Trigger::Chat | Trigger::Routine { .. } | Trigger::Telegram { .. } | Trigger::Channel { .. } | Trigger::Peer { .. } | Trigger::Handoff { .. } | Trigger::Inbox | Trigger::Memory { .. });
                let last_job = jobs.iter().rev().find(visible);
                let mut last = last_job.map(|j| if j.answer.is_empty() { j.error.clone().unwrap_or_default() } else { j.answer.clone() });
                let mut last_at = last_job.map(|j| j.finished_at.unwrap_or(j.started_at));
                // A conversation from before the job record existed still shows its last line and time.
                let session = self.paths.session(&agent.id);
                let session_at = std::fs::metadata(&session).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs());
                if last.is_none() || session_at > last_at {
                    if let Some(text) = last_session_line(&session) {
                        last = Some(text);
                        last_at = session_at.max(last_at);
                    }
                }
                let seen = read.get(&agent.id).copied().unwrap_or(0);
                let mut unread = jobs.iter().filter(visible).filter(|j| j.status != JobStatus::Running && j.finished_at.unwrap_or(0) > seen).count();
                if side.marked_unread.contains(&agent.id) { unread = unread.max(1); }
                Row {
                    busy: busy.contains(&agent.id),
                    waiting: waiting.iter().filter(|w| w.agent == agent.id).count(),
                    last: last.map(|s| util::clip(&s, 160)),
                    last_at,
                    unread,
                    pinned: side.pinned.contains(&agent.id),
                    hidden: side.hidden.contains(&agent.id),
                    section: side.sections.get(&agent.id).cloned(),
                    agent,
                }
            })
            .collect();
        rows.sort_by_key(|r| std::cmp::Reverse(r.last_at.unwrap_or(r.agent.created_at)));
        rows
    }

    /// The person opened this agent: everything so far is read.
    pub fn mark_read(&self, id: &str) -> Result<(), String> {
        let path = self.paths.root.join("read.json");
        let mut read: std::collections::BTreeMap<String, u64> = util::read_json(&path);
        read.insert(id.to_string(), util::now());
        util::write_json(&path, &read)?;
        let mut side = self.sidebar();
        if side.marked_unread.iter().any(|a| a == id) {
            side.marked_unread.retain(|a| a != id);
            util::write_json(&self.paths.root.join("sidebar.json"), &side)?;
        }
        Ok(())
    }

    pub fn sidebar(&self) -> Sidebar {
        util::read_json(&self.paths.root.join("sidebar.json"))
    }

    /// Pin, hide, file under a section, or mark unread one agent.
    pub async fn arrange(&self, id: &str, p: SidebarPatch) -> Result<(), String> {
        if !self.agents.read().await.iter().any(|a| a.id == id) {
            return Err("No such agent.".into());
        }
        let mut side = self.sidebar();
        let set = |list: &mut Vec<String>, on: bool| {
            list.retain(|a| a != id);
            if on { list.push(id.to_string()); }
        };
        if let Some(on) = p.pinned { set(&mut side.pinned, on); }
        if let Some(on) = p.hidden { set(&mut side.hidden, on); }
        if let Some(on) = p.unread { set(&mut side.marked_unread, on); }
        if let Some(name) = p.section {
            let name = name.trim().chars().take(40).collect::<String>();
            if name.is_empty() { side.sections.remove(id); } else { side.sections.insert(id.to_string(), name); }
        }
        util::write_json(&self.paths.root.join("sidebar.json"), &side)?;
        self.emit(TeamEvent::RosterChanged);
        Ok(())
    }

    pub async fn hire(&self, h: Hire) -> Result<AgentRecord, String> {
        let (name, job, model) = (h.name.trim().to_string(), h.job.trim().to_string(), h.model.trim().to_string());
        if name.is_empty() || job.is_empty() {
            return Err("A hire needs a name and a job.".into());
        }
        if self.agent_named(&name).await.is_some() {
            return Err(format!("You already have an agent called {name}."));
        }
        // Fails here, at hiring, when the model id is malformed or its key is missing.
        cookie_harness::Agent::new(&model).map_err(|e| e.to_string())?;
        // Starting from a retired agent: its handover note comes with the rest.
        let inherited_note = match h.inherit.as_deref() {
            Some(a) if !a.contains('/') && !a.contains("..") => util::read_json::<crate::inherit::Archive>(&self.paths.handovers().join("archive").join(a).join("archive.json")).handover,
            _ => None,
        };
        let handover = match h.handover.or(inherited_note) {
            Some(file) => Some(std::fs::read_to_string(self.paths.handovers().join(util::inside(&self.paths.handovers(), &file).map(|_| file.clone()).ok_or("No such handover note.")?)).map_err(|e| e.to_string())?),
            None => None,
        };
        let now = util::now();
        let wanted = h.id.as_deref().map(str::trim).filter(|i| {
            i.len() >= 3 && i.len() <= 64 && i.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') && *i != front::COOKIE_ID
        });
        let id = match wanted {
            Some(i) if self.agent(i).await.is_err() && !self.paths.agent(i).exists() => i.to_string(),
            _ => util::new_id(&name),
        };
        let record = AgentRecord {
            id,
            name,
            model,
            job,
            created_at: now,
            grants: h.grants.unwrap_or_default(),
            limits: Limits::default(),
            probation_until: (h.probation_days > 0).then(|| now + h.probation_days as u64 * 86_400),
            parent: None,
            shadow_of: None,
            handover,
            origin: None,
            version: 1,
        };
        let hired = self.add_agent(record).await?;
        if let Some(a) = h.inherit.as_deref() {
            self.inherit_into(a, &hired.id)?;
        }
        if let Some(t) = h.template.as_deref() {
            self.workspace_template(&hired.id, t).await?;
        }
        // The first hire's model can run Cookie too.
        self.ensure_cookie().await;
        Ok(hired)
    }

    pub(crate) async fn add_agent(&self, record: AgentRecord) -> Result<AgentRecord, String> {
        std::fs::create_dir_all(self.paths.work(&record.id)).map_err(|e| e.to_string())?;
        let mut agents = self.agents.write().await;
        agents.push(record.clone());
        self.save_roster(&agents).await?;
        drop(agents);
        self.emit(TeamEvent::RosterChanged);
        Ok(record)
    }

    pub async fn update(&self, id: &str, p: Patch) -> Result<AgentRecord, String> {
        if let Some(m) = &p.model {
            cookie_harness::Agent::new(m.trim()).map_err(|e| e.to_string())?;
        }
        let mut agents = self.agents.write().await;
        if let Some(n) = &p.name {
            let n = n.trim().to_lowercase();
            if n.is_empty() {
                return Err("An agent needs a name.".into());
            }
            if agents.iter().any(|a| a.id != id && a.name.to_lowercase() == n) {
                return Err("Another agent already has that name.".into());
            }
        }
        let a = agents.iter_mut().find(|a| a.id == id).ok_or("No such agent.")?;
        if let Some(v) = p.name { a.name = v.trim().to_string(); }
        if let Some(v) = p.job {
            if v.trim().is_empty() { return Err("An agent needs a job.".into()); }
            a.job = v.trim().to_string();
        }
        if let Some(v) = p.model { a.model = v.trim().to_string(); }
        if let Some(v) = p.grants { a.grants = v; }
        if let Some(v) = p.limits { a.limits = v; }
        if let Some(d) = p.probation_days {
            a.probation_until = (d > 0).then(|| util::now() + d as u64 * 86_400);
        }
        a.version += 1;
        let out = a.clone();
        self.save_roster(&agents).await?;
        drop(agents);
        self.emit(TeamEvent::RosterChanged);
        Ok(out)
    }

    /// Fire an agent: optionally it writes a handover note first, then its
    /// folder, conversation, record, routines and forks are all deleted.
    pub async fn fire(self: &Arc<Self>, id: &str, handover: bool) -> Result<Option<String>, String> {
        if id == front::COOKIE_ID {
            return Err("Cookie stays: it's your front door. Change its model or rules, or hide it, instead.".into());
        }
        let agent = self.agent(id).await?;
        self.stop(id);
        let note = if handover && self.paths.session(id).exists() { self.write_handover(&agent).await.ok() } else { None };
        let mut agents = self.agents.write().await;
        let gone: Vec<String> = agents.iter().filter(|a| a.id == id || a.shadow_of.as_deref() == Some(id)).map(|a| a.id.clone()).collect();
        agents.retain(|a| !gone.contains(&a.id));
        self.save_roster(&agents).await?;
        drop(agents);
        // Its memories go with it: erased from Enkeon (from its ledger, inside the folder
        // about to be deleted), and retried at the next start if Enkeon can't be reached.
        for g in &gone {
            let (erased, waiting) = self.erase_memory_of(g).await;
            if erased + waiting > 0 {
                tracing::info!(agent = %g, erased, waiting, "erased a fired agent's memories");
            }
        }
        for g in &gone {
            let dir = self.paths.agent(g);
            if dir.starts_with(self.paths.agents_dir()) && dir.exists() {
                std::fs::remove_dir_all(dir).map_err(|e| e.to_string())?;
            }
            self.traces.lock().unwrap().remove(g);
        }
        let mut routines = self.routines.write().await;
        routines.retain(|r| !gone.contains(&r.agent));
        util::write_json(&self.paths.routines(), &*routines)?;
        drop(routines);
        let mut settings = self.settings.write().await;
        settings.invites.retain(|i| !gone.contains(&i.agent));
        for v in settings.telegram.chats.values_mut() {
            if v.as_deref().is_some_and(|a| gone.iter().any(|g| g == a)) {
                *v = None;
            }
        }
        util::write_json(&self.paths.settings(), &*settings)?;
        drop(settings);
        self.emit(TeamEvent::RosterChanged);
        self.emit(TeamEvent::RoutinesChanged);
        Ok(note)
    }

    /// Ask the agent to write what its successor needs, and keep it.
    async fn write_handover(self: &Arc<Self>, agent: &AgentRecord) -> Result<String, String> {
        let prompt = "You are leaving this job. Write a handover note for whoever takes it next: what you were doing, what is still open (with dates you promised), what to watch out for, and where your files are. Plain words, short, no greeting.";
        let job = self.run_and_wait(&agent.id, prompt.to_string(), Vec::new(), Trigger::Handover).await?;
        let file = format!("{}-{}.md", util::new_id(&agent.name), chrono::Local::now().format("%Y-%m-%d"));
        let text = format!("# Handover from {}\n\nJob: {}\n\n{}\n", agent.name, agent.job, job.answer);
        std::fs::write(self.paths.handovers().join(&file), text).map_err(|e| e.to_string())?;
        Ok(file)
    }

    pub fn handovers(&self) -> Vec<(String, String)> {
        let mut out: Vec<(String, String, std::time::SystemTime)> = std::fs::read_dir(self.paths.handovers())
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| {
                let name = e.file_name().to_string_lossy().into_owned();
                let text = std::fs::read_to_string(e.path()).ok()?;
                let title = text.lines().next().unwrap_or(&name).trim_start_matches("# ").to_string();
                Some((name, title, e.metadata().ok()?.modified().ok()?))
            })
            .collect();
        out.sort_by(|a, b| b.2.cmp(&a.2));
        out.into_iter().map(|(n, t, _)| (n, t)).collect()
    }

    /* ---------- settings ---------- */

    pub async fn settings(&self) -> Settings {
        self.settings.read().await.clone()
    }

    pub async fn update_settings(&self, f: impl FnOnce(&mut Settings)) -> Result<Settings, String> {
        let mut s = self.settings.write().await;
        f(&mut s);
        util::write_json(&self.paths.settings(), &*s)?;
        Ok(s.clone())
    }
}

/// The last line of a conversation file, without loading the whole session.
fn last_session_line(path: &std::path::Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    text.lines().rev().find_map(|l| {
        let v: serde_json::Value = serde_json::from_str(l).ok()?;
        let parts = v["content"].as_array()?;
        let t: String = parts.iter().filter(|p| p["type"] == "text").filter_map(|p| p["text"].as_str()).collect::<Vec<_>>().join(" ");
        (!t.trim().is_empty()).then_some(t)
    })
}
