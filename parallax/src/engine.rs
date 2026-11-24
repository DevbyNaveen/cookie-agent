//! Engines, and the small runtime that loads them.
//!
//! An engine is an application's brain without its screen: a spreadsheet's
//! calculation, a browser's page, a PDF tool. It is called directly with
//! JSON and answers with JSON. Each action says what kind it is:
//!
//! - `Read`: looks, changes nothing.
//! - `Local`: changes the world's own files; it can be undone.
//! - `Outside`: reaches the world outside (sends, pays, publishes); it stops
//!   at the wall (`ledger`) until a person says yes.
//!
//! The runtime is small on purpose: engines are registered as constructors
//! and built on their first call, so a world that only edits a sheet never
//! starts a browser.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Effect {
    Read,
    Local,
    Outside,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionSpec {
    pub engine: String,
    pub name: String,
    pub description: String,
    /// JSON Schema of its arguments.
    pub args: Value,
    pub effect: Effect,
}

impl ActionSpec {
    pub fn new(engine: &str, name: &str, description: &str, args: Value, effect: Effect) -> Self {
        Self { engine: engine.into(), name: name.into(), description: description.into(), args, effect }
    }
}

/// What an engine call sees: the world it works in.
#[derive(Debug, Clone)]
pub struct Ctx {
    pub world: String,
    /// The world's files: the only place an engine reads and writes.
    pub files: PathBuf,
    /// Parallax's own corner of the world (`files/.parallax`): an engine's state
    /// that forks with the world (a browser's cookies), hidden from the agent.
    pub state: PathBuf,
    /// Parallax's home, for what lives beside the worlds (hosting's releases).
    pub home: PathBuf,
}

impl Ctx {
    /// A path inside the world from the agent's relative one.
    pub fn path(&self, rel: &str) -> Result<PathBuf, String> {
        crate::util::inside(&self.files, rel)
    }
}

#[async_trait]
pub trait Engine: Send + Sync {
    fn name(&self) -> &'static str;
    fn actions(&self) -> Vec<ActionSpec>;
    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String>;
    /// What an outside action will do, in words, for the person at the wall.
    fn preview(&self, action: &str, args: &Value) -> String {
        format!("{} {} {}", self.name(), action, crate::util::clip(&args.to_string(), 600))
    }
    /// The world went to sleep: close what runs for it (a browser).
    async fn sleep(&self, _world: &str) {}
}

type Make = Box<dyn Fn() -> Arc<dyn Engine> + Send + Sync>;

/// Engines by name, built on first use.
pub struct Registry {
    makers: BTreeMap<&'static str, Make>,
    built: Mutex<BTreeMap<&'static str, Arc<dyn Engine>>>,
}

impl Default for Registry {
    fn default() -> Self {
        Self::new()
    }
}

impl Registry {
    pub fn new() -> Self {
        Self { makers: BTreeMap::new(), built: Mutex::new(BTreeMap::new()) }
    }

    pub fn register(&mut self, name: &'static str, make: impl Fn() -> Arc<dyn Engine> + Send + Sync + 'static) {
        self.makers.insert(name, Box::new(make));
    }

    pub fn names(&self) -> Vec<&'static str> {
        self.makers.keys().copied().collect()
    }

    /// The engine, built now if this is its first call.
    pub fn get(&self, name: &str) -> Result<Arc<dyn Engine>, String> {
        let (key, make) = self.makers.get_key_value(name).ok_or_else(|| format!("There is no engine called {name}. Engines: {}.", self.names().join(", ")))?;
        let mut built = self.built.lock().unwrap();
        Ok(built.entry(*key).or_insert_with(|| make()).clone())
    }

    /// Engines that are running now (built).
    pub fn loaded(&self) -> Vec<&'static str> {
        self.built.lock().unwrap().keys().copied().collect()
    }

    /// Every action of every engine (building each once to ask).
    pub fn actions(&self) -> Vec<ActionSpec> {
        self.names().into_iter().filter_map(|n| self.get(n).ok()).flat_map(|e| e.actions()).collect()
    }

    pub fn spec(&self, engine: &str, action: &str) -> Result<ActionSpec, String> {
        self.get(engine)?.actions().into_iter().find(|a| a.name == action).ok_or_else(|| format!("The {engine} engine has no action {action}."))
    }

    /// Tell every running engine a world is asleep.
    pub async fn sleep(&self, world: &str) {
        let running: Vec<Arc<dyn Engine>> = self.built.lock().unwrap().values().cloned().collect();
        for e in running {
            e.sleep(world).await;
        }
    }
}

/// An argument as text, or an error naming it.
pub fn s<'a>(args: &'a Value, k: &str) -> Result<&'a str, String> {
    args.get(k).and_then(Value::as_str).ok_or_else(|| format!("Needs `{k}`."))
}
