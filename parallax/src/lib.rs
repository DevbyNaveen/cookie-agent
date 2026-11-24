//! Parallax: a computer built for agents.
//!
//! Software without faces. Every app is a brain and a screen made for people;
//! Parallax keeps the brain and drops the screen. An agent works in **worlds**
//! (copies of everything it touches, made instantly, rewound at will), calls
//! **engines** (browser, spreadsheet, files, documents, PDF, images, video,
//! data) directly with no window, combines them in short **scripts**, and
//! every action takes **four verbs**: Preview, Do, Undo, Branch. What reaches
//! the world outside stops at **the wall** until a person says yes, and is
//! written to a **ledger** kept outside the worlds. Several attempts can
//! **race** and the agent's own tests pick the winner. Any AI connects over
//! MCP (`mcp`): Claude, ChatGPT, Codex, or a Cookie agent.
//!
//! Runs on a Mac with nothing else; the cloud parts (`cloud`, `link`,
//! `preview`) are for when a world should live on a host.

pub mod cloud;
pub mod engine;
pub mod engines;
pub mod ledger;
pub mod link;
pub mod mcp;
pub mod preview;
pub mod race;
pub mod runtime;
pub mod sizes;
pub mod util;
pub mod verbs;
pub mod world;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

pub use engine::{ActionSpec, Ctx, Effect, Engine, Registry};
pub use ledger::Ledger;
pub use verbs::{Outcome, Step};
pub use world::{World, Worlds};

/// A world unused this long goes to sleep.
pub const IDLE_SECS: u64 = 15 * 60;

pub struct Parallax {
    pub home: PathBuf,
    pub worlds: Worlds,
    pub ledger: Ledger,
    pub engines: Registry,
    /// The machine's share of work at once: engines and scripts queue for a
    /// turn rather than each holding a fixed slice (agents mostly wait).
    pub(crate) cpu: tokio::sync::Semaphore,
    pub(crate) ahead: Mutex<HashMap<String, verbs::Ahead>>,
}

/// Where Parallax keeps its worlds: `PARALLAX_HOME`, else the user's application data.
pub fn default_home() -> PathBuf {
    if let Ok(h) = std::env::var("PARALLAX_HOME") {
        if !h.trim().is_empty() {
            return PathBuf::from(h);
        }
    }
    let home = std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."));
    if cfg!(target_os = "macos") {
        home.join("Library/Application Support/Parallax")
    } else {
        home.join(".local/share/parallax")
    }
}

impl Parallax {
    /// Open (or make) a Parallax home with every engine registered.
    pub fn open(home: impl Into<PathBuf>) -> Result<Arc<Self>, String> {
        let home = home.into();
        std::fs::create_dir_all(home.join("worlds")).map_err(|e| e.to_string())?;
        let mut engines = Registry::new();
        engines::register_all(&mut engines);
        let cpus = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
        Ok(Arc::new(Self {
            worlds: Worlds::new(home.join("worlds")),
            ledger: Ledger::new(home.join("ledger.jsonl")),
            engines,
            cpu: tokio::sync::Semaphore::new(cpus * 2),
            ahead: Mutex::new(HashMap::new()),
            home,
        }))
    }

    /// Put idle worlds to sleep and close what runs for them. Call it on a timer.
    pub async fn sleep_idle(&self) -> Vec<String> {
        let slept = self.worlds.put_idle_to_sleep(IDLE_SECS);
        for w in &slept {
            self.engines.sleep(w).await;
        }
        slept
    }

    /// What this Parallax holds now.
    pub fn status(&self) -> serde_json::Value {
        let worlds = self.worlds.list();
        serde_json::json!({
            "home": self.home,
            "worlds": worlds.len(),
            "awake": worlds.iter().filter(|w| w.state == "awake").count(),
            "asleep": worlds.iter().filter(|w| w.state == "asleep").count(),
            "engines": self.engines.names(),
            "engines_running": self.engines.loaded(),
            "waiting_at_wall": self.ledger.waiting().len(),
            "turns_free": self.cpu.available_permits(),
        })
    }
}
