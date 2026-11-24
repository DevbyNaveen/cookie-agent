//! An exact-match cache for reads.
//!
//! The same web page or the same search, asked again by the same agent within
//! ten minutes, is answered from what it read the first time: no second fetch,
//! and the model is told it is the earlier read. Only reads whose answer
//! depends on nothing but their arguments are cached (`read_url`,
//! `web_search`): never the person's files (a job may have just changed them),
//! never memory (Enkeon's own answers move), never anything that sends or
//! changes. An error is never cached. Each agent has its own cache: one
//! agent's reads never answer another's.
//!
//! Hits are counted per agent and day (`readcache.json`), for its record.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use cookie_harness::tool::{Tool, ToolContext, ToolSpec};
use serde_json::Value;

use crate::{util, Team};

pub const CACHED_TOOLS: &[&str] = &["read_url", "web_search"];
const TTL: Duration = Duration::from_secs(600);
const MAX_ENTRIES: usize = 200;
const MAX_BYTES: usize = 200_000;

type Key = (String, String, String);
static CACHE: LazyLock<Mutex<HashMap<Key, (Instant, String)>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// The arguments in one canonical form: the same call with keys in another order is the same read.
pub fn canonical(v: &Value) -> String {
    fn sort(v: &Value) -> Value {
        match v {
            Value::Object(m) => Value::Object(m.iter().map(|(k, v)| (k.clone(), sort(v))).collect::<BTreeMap<_, _>>().into_iter().collect()),
            Value::Array(a) => Value::Array(a.iter().map(sort).collect()),
            v => v.clone(),
        }
    }
    sort(v).to_string()
}

struct Cached {
    inner: Arc<dyn Tool>,
    agent: String,
    counts: std::path::PathBuf,
}

impl Cached {
    fn key(&self, args: &Value) -> Key {
        (self.agent.clone(), self.inner.spec().name.clone(), canonical(args))
    }

    fn hit(&self, args: &Value) -> Option<String> {
        let mut c = CACHE.lock().unwrap();
        let k = self.key(args);
        match c.get(&k) {
            Some((at, out)) if at.elapsed() < TTL => {
                let mins = at.elapsed().as_secs() / 60;
                let note = if mins == 0 { "under a minute ago".to_string() } else { format!("{mins} min ago") };
                Some(format!("(The same read as {note}; answered from it.)\n{out}"))
            }
            Some(_) => {
                c.remove(&k);
                None
            }
            None => None,
        }
    }

    fn keep(&self, args: &Value, out: &str) {
        if out.len() > MAX_BYTES {
            return;
        }
        let mut c = CACHE.lock().unwrap();
        if c.len() >= MAX_ENTRIES {
            c.retain(|_, (at, _)| at.elapsed() < TTL);
            if c.len() >= MAX_ENTRIES {
                // Still full: the oldest goes.
                if let Some(oldest) = c.iter().min_by_key(|(_, (at, _))| *at).map(|(k, _)| k.clone()) {
                    c.remove(&oldest);
                }
            }
        }
        c.insert(self.key(args), (Instant::now(), out.to_string()));
    }

    fn count(&self, hit: bool) {
        let day = (util::now() / 86_400).to_string();
        let mut m: BTreeMap<String, (u64, u64)> = util::read_json(&self.counts);
        let e = m.entry(day).or_default();
        if hit { e.0 += 1 } else { e.1 += 1 }
        // Thirty days kept.
        while m.len() > 30 {
            let first = m.keys().next().cloned().unwrap_or_default();
            m.remove(&first);
        }
        let _ = util::write_json(&self.counts, &m);
    }

    async fn run(&self, args: Value, ctx: Option<&ToolContext>) -> Result<String, String> {
        if let Some(out) = self.hit(&args) {
            self.count(true);
            return Ok(out);
        }
        let out = match ctx {
            Some(c) => self.inner.call_in(args.clone(), c).await,
            None => self.inner.call(args.clone()).await,
        }?;
        self.keep(&args, &out);
        self.count(false);
        Ok(out)
    }
}

#[async_trait]
impl Tool for Cached {
    fn spec(&self) -> &ToolSpec {
        self.inner.spec()
    }
    async fn call(&self, args: Value) -> Result<String, String> {
        self.run(args, None).await
    }
    async fn call_in(&self, args: Value, context: &ToolContext) -> Result<String, String> {
        self.run(args, Some(context)).await
    }
    fn send_back(&self, args: &Value) -> Option<String> {
        self.inner.send_back(args)
    }
    fn preview(&self, args: &Value) -> String {
        self.inner.preview(args)
    }
}

/// The agent's tools, with its cacheable reads wrapped.
pub(crate) fn wrap(team: &Team, agent: &str, tools: Vec<Arc<dyn Tool>>) -> Vec<Arc<dyn Tool>> {
    let counts = team.paths.agent(agent).join("readcache.json");
    tools
        .into_iter()
        .map(|t| -> Arc<dyn Tool> {
            if CACHED_TOOLS.contains(&t.spec().name.as_str()) && t.spec().effect == cookie_harness::tool::Effect::Read {
                Arc::new(Cached { inner: t, agent: agent.to_string(), counts: counts.clone() })
            } else {
                t
            }
        })
        .collect()
}

impl Team {
    /// Reads answered from the cache, and reads made, over the last `days`.
    pub fn read_cache_counts(&self, agent: &str, days: u64) -> (u64, u64) {
        let m: BTreeMap<String, (u64, u64)> = util::read_json(&self.paths.agent(agent).join("readcache.json"));
        let since = (util::now() / 86_400).saturating_sub(days);
        m.iter().filter(|(d, _)| d.parse::<u64>().is_ok_and(|d| d >= since)).fold((0, 0), |(h, f), (_, (a, b))| (h + a, f + b))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cookie_harness::tool::{tool, Effect};
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn the_same_read_with_keys_in_another_order_is_the_same() {
        assert_eq!(canonical(&serde_json::json!({"b": 1, "a": {"y": 2, "x": 1}})), canonical(&serde_json::json!({"a": {"x": 1, "y": 2}, "b": 1})));
    }

    #[tokio::test]
    async fn a_second_identical_read_is_answered_from_the_first_and_errors_never_are() {
        let dir = tempfile::tempdir().unwrap();
        let t = Team::open(dir.path()).unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let c2 = calls.clone();
        let read: Arc<dyn Tool> = Arc::new(tool("read_url", "r", serde_json::json!({}), Effect::Read, move |a: Value| {
            let c = c2.clone();
            async move {
                c.fetch_add(1, Ordering::SeqCst);
                if a["url"] == "bad" { Err("404".to_string()) } else { Ok(format!("page {}", a["url"])) }
            }
        }));
        let other: Arc<dyn Tool> = Arc::new(tool("write_file", "w", serde_json::json!({}), Effect::Write, |_a: Value| async { Ok("ok".to_string()) }));
        let tools = wrap(&t, "cache-test-agent", vec![read, other]);
        let first = tools[0].call(serde_json::json!({"url": "u1"})).await.unwrap();
        let second = tools[0].call(serde_json::json!({"url": "u1"})).await.unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 1, "fetched once");
        assert!(second.ends_with(&first) && second.starts_with("(The same read"));
        assert!(tools[0].call(serde_json::json!({"url": "bad"})).await.is_err());
        assert!(tools[0].call(serde_json::json!({"url": "bad"})).await.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 3, "an error is asked again");
        assert_eq!(t.read_cache_counts("cache-test-agent", 1), (1, 1));
        assert_eq!(tools[1].spec().name, "write_file");
    }
}
