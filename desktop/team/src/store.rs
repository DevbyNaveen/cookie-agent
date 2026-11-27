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
    /// On by default: agents work in Parallax first. Left out of the JSON when on,
    /// so packs signed before it still verify; written out only when switched off.
    #[serde(skip_serializing_if = "is_true")]
    pub worlds: bool,
    /// Apps connected through Enkeon (Composio): each call is billed per call.
    #[serde(skip_serializing_if = "is_true")]
    pub apps: bool,
    /// Send short-lived read-only helpers to research side by side (`helpers`). Left out of the JSON
    /// when on, so packs signed before it still verify.
    #[serde(skip_serializing_if = "is_true")]
    pub helpers: bool,
    /// Bring in a temporary specialist for one piece of a job (`contractors`). Left out of the JSON
    /// when on, so packs signed before it still verify.
    #[serde(skip_serializing_if = "is_true")]
    pub contractors: bool,
}

fn is_true(b: &bool) -> bool {
    *b
}

impl Default for Grants {
    fn default() -> Self {
        Self { files: true, web: true, shell: false, memory: true, routines: true, team: true, peers: Vec::new(), mac: false, browser: false, worlds: true, apps: true, helpers: true, contractors: true }
    }
}

impl Grants {
    /// Nothing at all: what an imported agent starts with.
    pub fn none() -> Self {
        Self { files: false, web: false, shell: false, memory: false, routines: false, team: false, peers: Vec::new(), mac: false, browser: false, worlds: false, apps: false, helpers: false, contractors: false }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Limits {
    /// Model calls per job: a guard against a run going round in circles, not a
    /// measure of work. Work is bounded by dollars and minutes.
    pub steps: usize,
    /// Tokens per job (input, output and cache writes): the same kind of guard.
    pub tokens: u64,
    /// Dollars per job (needs prices for its model in settings).
    pub job_dollars: Option<f64>,
    /// Dollars per calendar month; past it, jobs wait until you raise it.
    pub month_dollars: Option<f64>,
    /// Minutes of work per job, wall clock.
    pub job_minutes: Option<u64>,
}

/// The limits every agent had before work was budgeted in dollars and minutes:
/// an agent still holding exactly these is moved to the new ones.
const OLD_DEFAULT: (usize, u64) = (24, 400_000);

impl Default for Limits {
    fn default() -> Self {
        Self { steps: 1_000, tokens: 40_000_000, job_dollars: Some(20.0), month_dollars: None, job_minutes: Some(240) }
    }
}

impl Limits {
    /// The limits a job runs under: an agent left on the old step-count defaults
    /// gets today's, and one the person set keeps what they set.
    pub fn effective(&self) -> Limits {
        // A record from before `job_minutes` existed reads it as today's default, so the step and
        // token pair is what tells an untouched agent apart.
        if (self.steps, self.tokens) == OLD_DEFAULT {
            return Limits { job_dollars: self.job_dollars.or(Limits::default().job_dollars), month_dollars: self.month_dollars, job_minutes: self.job_minutes, ..Limits::default() };
        }
        self.clone()
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

/// List prices, in dollars per million tokens, for models with no price of their
/// own (Anthropic's pricing page, platform.claude.com/docs/en/about-claude/pricing,
/// read 2026-11-25; 5-minute cache writes). Models on your own Mac cost nothing.
/// A price set in Settings always wins.
pub fn known_price(model: &str) -> Option<PriceCfg> {
    let m = model.to_lowercase();
    let p = |input, output, cache_read, cache_write| Some(PriceCfg { input, output, cache_read, cache_write });
    if m.starts_with("ollama:") {
        return p(0.0, 0.0, 0.0, 0.0);
    }
    if m.contains("opus-4-6") || m.contains("opus-4-5") {
        return p(5.0, 25.0, 0.5, 6.25);
    }
    if m.contains("sonnet-4-6") || m.contains("sonnet-4-5") {
        return p(3.0, 15.0, 0.3, 3.75);
    }
    if m.contains("haiku-4-5") {
        return p(1.0, 5.0, 0.1, 1.25);
    }
    None
}

impl Settings {
    /// What a model costs: the person's price, else the list price.
    pub fn price_of(&self, model: &str) -> Option<PriceCfg> {
        self.prices.get(model).cloned().or_else(|| known_price(model))
    }
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
    /// Minutes a request for your yes waits before it counts as a no and the job moves on (0: as long as it takes).
    pub approval_wait_minutes: i64,
    /// While plugged in, this Mac doesn't go to sleep on its own (`power`).
    pub keep_awake: bool,
    /// A login item starts Cookie at login and again after a crash (`power`).
    pub start_at_login: bool,
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
    /// The twin's scores (`twin`): a nightly run on Cookie, with its cap.
    #[serde(default = "crate::twin::TwinCfg::normal")]
    pub twin: crate::twin::TwinCfg,
    /// Each agent's backup model, when the person chose one (`failover`); else Cookie picks.
    pub backup_models: BTreeMap<String, String>,
    /// Each agent's model for routine steps, when the person chose one; `off` for none; else
    /// the tier below its own on the same route (`failover::cheaper`).
    pub routine_models: BTreeMap<String, String>,
    /// The model the person chose to run Cookie on without an Enkeon account (their own key, or
    /// a local model): checked with one real call when chosen.
    pub own_model: Option<String>,
    /// A teammate standing in as the front desk while Cookie's results are poor (`council`).
    pub stand_in: Option<crate::council::StandIn>,
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
            approval_wait_minutes: 60,
            keep_awake: false,
            start_at_login: false,
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
            backup_models: BTreeMap::new(),
            routine_models: BTreeMap::new(),
            own_model: None,
            stand_in: None,
            twin: crate::twin::TwinCfg::normal(),
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
    /// An AI tool the person uses (Claude Desktop, Cursor…) asked over MCP (`mcp_server`).
    Mcp { client: String },
    /// The person named it with @ in another agent's chat (`chat`): it answers there (`mention`).
    Mention { chat: String },
    /// Its memory changed enough to be worth its attention (`wake`).
    Memory { subject: String },
    /// Getting ready, while idle, for a routine due soon (`prep`): changes recorded, not made.
    Prep { routine: String },
    /// A rehearsal of a job before it runs for real (`twin::rehearsal`): reads are real,
    /// every change is recorded and shown, none is made.
    Rehearse,
    /// A step of a saved workflow (`workflows`).
    Workflow { flow: String, run: String },
    /// The person opened Cookie for the first time and has said nothing yet: Cookie speaks first (`front`).
    Welcome,
    /// A goal it owns came due: its next step, from where its progress note left off (`goals`).
    Goal { goal: String },
    /// Something it promised came due ("I'll check Friday") (`goals`).
    Promise { job: String, index: usize },
    /// A watcher it wrote saw what it was watching for (`watchers`).
    Watch { watcher: String },
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobStatus {
    #[default]
    Running,
    Done,
    Stopped,
    Failed,
    /// It stopped where only the person can say what happens next: it was in
    /// the middle of an action that changes something (a send, a write) when
    /// Cookie closed, and whether that went through is unknown.
    NeedsYou,
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
    /// It came due and its agent was woken to keep it (`goals::fire_promises`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub fired: bool,
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
    /// The skills loaded in it (`autoskills`): by themselves or with load_skill.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skills: Vec<String>,
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
    /// For a job another agent started (a handoff, a peer, a contact): how many
    /// messages this agent's own conversation held when it ended, so its chat
    /// shows the exchange where it happened.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after_message: Option<usize>,
    /// Input tokens sent fresh, read from the prompt cache, and written to it.
    #[serde(default, skip_serializing_if = "is_zero64")]
    pub input_tokens: u64,
    #[serde(default, skip_serializing_if = "is_zero64")]
    pub cache_read_tokens: u64,
    #[serde(default, skip_serializing_if = "is_zero64")]
    pub cache_write_tokens: u64,
    /// Its model was out of reach and a backup answered: "Sonnet 5.5 → Opus 5.5: overloaded".
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub switched: Vec<String>,
    /// It is the same job picked up again after Cookie closed mid-way (that job's id).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resumed_from: Option<String>,
    /// It was cut off by Cookie closing and picked up again as this job.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resumed_as: Option<String>,
    /// Every action it took: why it was allowed and what it came to (`receipts`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub receipts: Vec<crate::receipts::ActionReceipt>,
    /// What showed the work was right, from outside the agent: a goal's check that
    /// passed, the person's thumbs-up (`outcome::end_state`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verified_by: Option<String>,
    /// What showed it was wrong: the person's next words correcting it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub corrected_by: Option<String>,
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
    /// When something new arrives in a connected app (`triggers`), mentioning every word in `contains`.
    App { app: String, #[serde(default)] contains: Vec<String> },
    /// When its web address is called with its secret, kept only as its SHA-256 (`triggers`).
    Webhook { digest: String },
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
    /// Run this saved workflow instead (`workflows`), with `task` as its input.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow: Option<String>,
    /// Its last run failed and is being tried once more (`Team::retry_routine`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub retrying: bool,
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

#[cfg(test)]
mod grant_tests {
    #[test]
    fn worlds_are_on_by_default_and_off_stays_off() {
        let on = super::Grants::default();
        assert!(on.worlds, "agents work in Parallax first");
        let json = serde_json::to_value(&on).unwrap();
        assert!(json.get("worlds").is_none(), "on is left out, so signed packs keep their bytes");
        let mut off = on.clone();
        off.worlds = false;
        let back: super::Grants = serde_json::from_value(serde_json::to_value(&off).unwrap()).unwrap();
        assert!(!back.worlds, "switched off survives a save and a load");
    }
}

#[cfg(test)]
mod limits_tests {
    use super::*;

    #[test]
    fn an_agent_left_on_the_old_step_count_works_by_dollars_and_minutes() {
        let old: Limits = serde_json::from_str(r#"{"steps": 24, "tokens": 400000, "job_dollars": null, "month_dollars": 30.0}"#).unwrap();
        let now = old.effective();
        assert_eq!(now.steps, Limits::default().steps, "the step count is only a runaway guard now");
        assert_eq!((now.job_dollars, now.job_minutes, now.month_dollars), (Some(20.0), Some(240), Some(30.0)), "the person's monthly cap stays");
        let set = Limits { steps: 60, ..Limits::default() };
        assert_eq!(set.effective(), set, "what the person set is kept");
    }
}
