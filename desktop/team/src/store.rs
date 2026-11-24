//! What the team keeps on disk, and where.
//!
//! ```text
//! <dir>/agents.json                 the roster
//! <dir>/settings.json               prices, checker, channels, runner (never secrets)
//! <dir>/agents/<id>/session.jsonl   its one conversation
//! <dir>/agents/<id>/work/           its own folder: the only place it may write
//! <dir>/agents/<id>/NOTES.md        its memory when there is no Enkeon
//! <dir>/agents/<id>/jobs.jsonl      every job it ran: the record its scorecard reads
//! <dir>/agents/<id>/tests.json      its test cases; tests/<run>.json their results
//! <dir>/agents/<id>/trust.json      tools it earned the right to run without asking
//! <dir>/agents/<id>/trace.jsonl     every action, hashed, chained and signed
//! <dir>/routines.json               standing jobs on a schedule
//! <dir>/handovers/                  notes a fired agent left its successor
//! ```

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// What an agent may use. Off means the tool is not even offered to the model.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Grants {
    /// Read, search and write files in its own folder.
    pub files: bool,
    /// Search the web (with a search key) and read pages.
    pub web: bool,
    /// Run commands, sandboxed to its own folder with no network.
    pub shell: bool,
    /// Keep notes (or use Enkeon when signed in).
    pub memory: bool,
    /// Set up routines of its own (each one asks you first).
    pub routines: bool,
    /// Ask another of your agents for help.
    pub team: bool,
    /// Other people's agents it may talk to (their card addresses).
    pub peers: Vec<String>,
    /// The Mac's own apps: Reminders, Notes, Calendar, Contacts, Messages.
    pub mac: bool,
    /// A browser of its own, with the sign-ins you gave it (`browser`). Clicks and typing ask you.
    pub browser: bool,
    /// Parallax worlds of its own: copies to try things in, undo, race, rewind (`computer`).
    /// Left out of the JSON when off, so packs signed before it still verify.
    #[serde(skip_serializing_if = "is_false")]
    pub worlds: bool,
    /// Apps connected through Enkeon (Composio): each call is billed per call.
    #[serde(skip_serializing_if = "is_true")]
    pub apps: bool,
}

fn is_false(b: &bool) -> bool {
    !*b
}

fn is_true(b: &bool) -> bool {
    *b
}

impl Default for Grants {
    fn default() -> Self {
        Self { files: true, web: true, shell: false, memory: true, routines: true, team: true, peers: Vec::new(), mac: false, browser: false, worlds: false, apps: true }
    }
}

impl Grants {
    /// Nothing at all: what an imported agent starts with.
    pub fn none() -> Self {
        Self { files: false, web: false, shell: false, memory: false, routines: false, team: false, peers: Vec::new(), mac: false, browser: false, worlds: false, apps: false }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Limits {
    /// Model calls per job.
    pub steps: usize,
    /// Tokens per job.
    pub tokens: u64,
    /// Dollars per job (needs prices for its model in settings).
    pub job_dollars: Option<f64>,
    /// Dollars per calendar month; past it, jobs wait until you raise it.
    pub month_dollars: Option<f64>,
}

impl Default for Limits {
    fn default() -> Self {
        Self { steps: 24, tokens: 400_000, job_dollars: None, month_dollars: None }
    }
}

/// Where an imported agent came from, as its pack said and its signature proved.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Origin {
    pub publisher_key: String,
    pub pack_hash: String,
    pub imported_at: u64,
}

/// One hire.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AgentRecord {
    pub id: String,
    pub name: String,
    /// `provider:model`, named by the person. The harness has no default.
    pub model: String,
    /// The one job this agent does, in the person's words.
    pub job: String,
    pub created_at: u64,
    #[serde(default)]
    pub grants: Grants,
    #[serde(default)]
    pub limits: Limits,
    /// Until then it works in shadow: every change it would make is recorded, none is made.
    #[serde(default)]
    pub probation_until: Option<u64>,
    /// The agent this one was forked from.
    #[serde(default)]
    pub parent: Option<String>,
    /// Shadowing that agent: it gets a copy of each of its chat jobs, answers
    /// privately, and is compared, never shown in the chat.
    #[serde(default)]
    pub shadow_of: Option<String>,
    /// A predecessor's handover note it starts with.
    #[serde(default)]
    pub handover: Option<String>,
    #[serde(default)]
    pub origin: Option<Origin>,
    /// Bumped on every change to its setup; tests record which version they ran.
    #[serde(default)]
    pub version: u32,
}

impl AgentRecord {
    pub fn on_probation(&self, now: u64) -> bool {
        self.probation_until.is_some_and(|t| t > now)
    }
}

/// Price of a model, in dollars per million tokens (= millionths of a dollar per token).
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Default)]
pub struct PriceCfg {
    pub input: f64,
    pub output: f64,
    #[serde(default)]
    pub cache_read: f64,
    #[serde(default)]
    pub cache_write: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct Telegram {
    pub enabled: bool,
    /// Chats linked with a one-time code: chat id → the agent it talks to by default.
    pub chats: BTreeMap<String, Option<String>>,
    /// The code waiting to be sent from a chat to link it.
    pub pending_code: Option<String>,
    /// The last update read, so a restart doesn't replay old messages.
    pub offset: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Server {
    /// Serve the team over HTTP (for a phone, another computer, other people's agents).
    pub enabled: bool,
    pub bind: String,
    pub port: u16,
    /// The public address other agents use to reach yours (for invites).
    pub public_url: Option<String>,
}

impl Default for Server {
    fn default() -> Self {
        Self { enabled: false, bind: "127.0.0.1".into(), port: 4519, public_url: None }
    }
}

/// An invitation another person's agent uses to talk to one of yours.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Invite {
    pub id: String,
    pub agent: String,
    pub label: String,
    /// Kept as a SHA-256 digest; the token itself is shown once.
    pub token_sha256: String,
    pub created_at: u64,
    #[serde(default)]
    pub revoked: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Settings {
    /// `provider:model` → price. None ship with Cookie: prices change and a stale table lies.
    pub prices: BTreeMap<String, PriceCfg>,
    /// A second model, from another provider, that reads every send before you see it.
    pub checker_model: Option<String>,
    /// Interruptions per day across all agents (approvals always get through).
    pub daily_notices: i64,
    pub telegram: Telegram,
    pub server: Server,
    pub invites: Vec<Invite>,
    /// Where to browse agents others published (a JSON index).
    pub market_url: Option<String>,
    /// Remote runner this desktop drives instead of running agents itself.
    pub runner_url: Option<String>,
    /// The model the public "try to trick my Cookie" challenge runs on (off when None).
    pub challenge_model: Option<String>,
    /// Scout proposals the person waved away.
    pub scout_dismissed: Vec<String>,
    /// Wake agents when their memory changes (`wake`). On by default.
    pub wake: bool,
    /// The cloud: which agents run there while this Mac is off, and the one store (`cloud`).
    pub cloud: CloudCfg,
    /// The nightly exam loop (`evolve`). Off until you turn it on.
    pub evolve: crate::evolve::EvolveCfg,
}

/// What Cookie does with Enkeon's cloud (`cloud`). Both off until you say.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct CloudCfg {
    /// Keep waiting approvals, notices and answers in Enkeon's store, for your phone.
    pub store: bool,
    /// Agents that run in the cloud while this Mac is off (Cookie credits).
    pub run_when_off: Vec<String>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            prices: BTreeMap::new(),
            checker_model: None,
            daily_notices: cookie_harness::attention::DAILY_CAP,
            telegram: Telegram::default(),
            server: Server::default(),
            invites: Vec::new(),
            market_url: None,
            runner_url: None,
            challenge_model: None,
            scout_dismissed: Vec::new(),
            wake: true,
            cloud: CloudCfg::default(),
            evolve: crate::evolve::EvolveCfg::default(),
        }
    }
}

/// What started a job.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Trigger {
    #[default]
    Chat,
    Routine { routine: String },
    /// Another of your agents asked; `chain` is who asked whom, to stop loops.
    Handoff { from: String, chain: Vec<String> },
    Telegram { chat: String },
    /// Another person's agent, through an invite.
    Peer { invite: String, label: String },
    Test { case: String },
    Shadow { of_job: String },
    Handover,
    Inbox,
    /// A contact or a guest on the Cookie Network; `level` is `talk` or `work`.
    Contact { contact: String, label: String, level: String },
    /// A room on the Cookie Network where this agent was named.
    Room { room: String, label: String },
    /// A learning pass: the agent updating its skills and notes after a conversation.
    Review,
    /// The person wrote from Slack, Discord, iMessage or Signal.
    Channel { channel: String, chat: String },
    /// Its memory changed enough to be worth its attention (`wake`).
    Memory { subject: String },
    /// Getting ready, while idle, for a routine due soon (`prep`): changes recorded, not made.
    Prep { routine: String },
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobStatus {
    #[default]
    Running,
    Done,
    Stopped,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ApprovalRecord {
    pub tool: String,
    pub effect: String,
    pub preview: String,
    /// `yes`, `no`, or `would` (probation or shadow: recorded, not done).
    pub outcome: String,
    #[serde(default)]
    pub checker: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PromiseRecord {
    pub text: String,
    pub due: String,
    /// `open`, `kept`, `missed`, set by the person.
    pub state: String,
}

/// One job, as its agent's record keeps it.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Job {
    pub id: String,
    pub agent: String,
    pub trigger: Trigger,
    pub input: String,
    pub started_at: u64,
    pub finished_at: Option<u64>,
    pub status: JobStatus,
    #[serde(default)]
    pub answer: String,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub tools: Vec<String>,
    #[serde(default)]
    pub approvals: Vec<ApprovalRecord>,
    #[serde(default)]
    pub promises: Vec<PromiseRecord>,
    #[serde(default)]
    pub tokens: u64,
    /// Millionths of a dollar (only when the model has a price).
    #[serde(default)]
    pub microdollars: u64,
    /// The person's grade: 1 good, -1 not good.
    #[serde(default)]
    pub grade: Option<i8>,
    /// The setup version that ran it.
    #[serde(default)]
    pub version: u32,
    /// Every tool call, in order, and how it ended (`outcome`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<crate::outcome::Step>,
    /// Times the person added words while it worked (a correction mid-job).
    #[serde(default, skip_serializing_if = "is_zero")]
    pub steered: u32,
    /// It stopped at a limit and wrote its answer from what it had.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cut_off: bool,
    /// Lessons that matched it, and whether each was given (`experience`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub lessons: Vec<cookie_harness::lessons::Picked>,
    /// A routine's saved recipe rode in it (`procedures`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub recipe: bool,
    /// Where it ran when not on this Mac: `cloud` (Enkeon, while the Mac was off).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub place: Option<String>,
    /// Input tokens sent fresh, read from the prompt cache, and written to it.
    #[serde(default, skip_serializing_if = "is_zero64")]
    pub input_tokens: u64,
    #[serde(default, skip_serializing_if = "is_zero64")]
    pub cache_read_tokens: u64,
    #[serde(default, skip_serializing_if = "is_zero64")]
    pub cache_write_tokens: u64,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

fn is_zero64(n: &u64) -> bool {
    *n == 0
}

/// When a routine runs, in this computer's local time.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "every", rename_all = "snake_case")]
pub enum Schedule {
    Day { at: String },
    Weekday { at: String },
    Week { day: String, at: String },
    Minutes { n: u32 },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Routine {
    pub id: String,
    pub agent: String,
    /// What to do each time, in the person's words.
    pub task: String,
    pub schedule: Schedule,
    pub enabled: bool,
    pub created_at: u64,
    #[serde(default)]
    pub last_run: Option<u64>,
    #[serde(default)]
    pub next_run: Option<u64>,
}

/// A saved test: an input and what a good answer must do.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TestCase {
    pub id: String,
    pub input: String,
    /// What a good answer does, in the person's words (the judge's yardstick).
    pub expect: String,
    /// The answer that was graded good when the test was saved.
    #[serde(default)]
    pub reference: Option<String>,
    #[serde(default)]
    pub from_job: Option<String>,
    pub created_at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TestResult {
    pub case: String,
    pub pass: bool,
    pub reason: String,
    pub answer: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TestRun {
    pub id: String,
    pub agent: String,
    pub model: String,
    pub version: u32,
    pub started_at: u64,
    pub finished_at: Option<u64>,
    pub results: Vec<TestResult>,
}

/// Paths for one data folder.
#[derive(Debug, Clone)]
pub struct Paths {
    pub root: PathBuf,
}

impl Paths {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }
    pub fn roster(&self) -> PathBuf {
        self.root.join("agents.json")
    }
    pub fn settings(&self) -> PathBuf {
        self.root.join("settings.json")
    }
    pub fn routines(&self) -> PathBuf {
        self.root.join("routines.json")
    }
    pub fn handovers(&self) -> PathBuf {
        self.root.join("handovers")
    }
    pub fn team_key(&self) -> PathBuf {
        self.root.join("team.key")
    }
    pub fn agents_dir(&self) -> PathBuf {
        self.root.join("agents")
    }
    pub fn agent(&self, id: &str) -> PathBuf {
        self.agents_dir().join(id)
    }
    pub fn work(&self, id: &str) -> PathBuf {
        self.agent(id).join("work")
    }
    pub fn session(&self, id: &str) -> PathBuf {
        self.agent(id).join("session.jsonl")
    }
    pub fn notes(&self, id: &str) -> PathBuf {
        self.agent(id).join("NOTES.md")
    }
    pub fn jobs(&self, id: &str) -> PathBuf {
        self.agent(id).join("jobs.jsonl")
    }
    pub fn tests(&self, id: &str) -> PathBuf {
        self.agent(id).join("tests.json")
    }
    pub fn test_runs(&self, id: &str) -> PathBuf {
        self.agent(id).join("tests")
    }
    pub fn trust(&self, id: &str) -> PathBuf {
        self.agent(id).join("trust.json")
    }
    pub fn trace(&self, id: &str) -> PathBuf {
        self.agent(id).join("trace.jsonl")
    }
    pub fn actions(&self, id: &str) -> PathBuf {
        self.agent(id).join("actions")
    }
    /// Only folders of this team's own, never anything else on disk.
    pub fn owns(&self, path: &Path) -> bool {
        path.starts_with(&self.root)
    }
}
