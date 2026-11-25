//! Shared memory for local models on the Mac.
//!
//! Agents on a local model (`ollama:<model>`) all talk to one Ollama server,
//! which keeps each model loaded once and serves every agent from the same
//! weights in memory. Cookie makes the most of that:
//!
//! - **One copy, kept warm.** While any agent on a local model has worked in
//!   the last half hour (or has a routine due within it), Cookie asks Ollama to
//!   keep that model loaded (`POST /api/generate` with no prompt and a
//!   `keep_alive`), at most every 20 minutes. Idle, Ollama unloads it as usual
//!   and the memory is free again.
//! - **What is in memory, and who shares it.** `GET /api/ps` says which models
//!   are loaded and how much memory each takes; Cookie shows that with the
//!   agents on each.
//! - **Two copies where one would do.** Agents on different tags of the same
//!   model (`qwen3:8b` and `qwen3:8b-q8_0`) make Ollama load two copies; Cookie
//!   says so, so you can put them on one.
//!
//! Prompt prefixes are byte-identical between jobs (the job's own notes ride
//! in its message, `runtime`), so Ollama can reuse the cached prompt of a
//! loaded model too.

use std::collections::{BTreeMap, HashMap};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::{util, Team};

const KEEP: &str = "30m";
const WARM_EVERY: Duration = Duration::from_secs(20 * 60);
const ACTIVE_SECS: u64 = 30 * 60;

static WARMED: LazyLock<Mutex<HashMap<String, Instant>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// The Ollama server's root (not its `/v1`), as the harness finds it.
pub fn ollama_root() -> String {
    cookie_harness::providers::openai::ollama_base(std::env::var("OLLAMA_HOST").ok()).trim_end_matches("/v1").to_string()
}

/// `ollama:qwen3:8b` → `qwen3:8b`.
pub fn local_model(model: &str) -> Option<&str> {
    model.strip_prefix("ollama:").filter(|m| !m.is_empty())
}

/// The base of a model tag: `qwen3:8b-q8_0` → `qwen3:8b`, `llama3.2:latest` → `llama3.2`.
pub fn base_of(model: &str) -> String {
    let (name, tag) = model.split_once(':').unwrap_or((model, "latest"));
    let size = tag.split('-').next().unwrap_or(tag);
    if size == "latest" { name.to_string() } else { format!("{name}:{size}") }
}

fn http() -> &'static reqwest::Client {
    static C: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    C.get_or_init(|| reqwest::Client::builder().timeout(Duration::from_secs(10)).build().unwrap_or_default())
}

impl Team {
    /// Agents on each local model.
    async fn local_agents(&self) -> BTreeMap<String, Vec<(String, String)>> {
        let mut m: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
        for a in self.agents().await.into_iter().filter(|a| a.shadow_of.is_none() && !crate::bench::is_probe(&a.id)) {
            if let Some(model) = local_model(&a.model) {
                m.entry(model.to_string()).or_default().push((a.id, a.name));
            }
        }
        m
    }

    /// On the minute tick: keep warm the local models agents are using now.
    pub(crate) async fn keep_local_models_warm(&self) {
        let models = self.local_agents().await;
        if models.is_empty() {
            return;
        }
        let now = util::now();
        let routines = self.routines.read().await.clone();
        for (model, agents) in models {
            let active = agents.iter().any(|(id, _)| {
                let worked = std::fs::metadata(self.paths.session(id)).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).is_some_and(|d| now.saturating_sub(d.as_secs()) < ACTIVE_SECS);
                let due = routines.iter().any(|r| &r.agent == id && r.enabled && r.next_run.is_some_and(|t| t >= now && t - now < ACTIVE_SECS));
                (worked || due || self.runs.lock().unwrap().contains_key(id)) && !self.is_asleep(id)
            });
            if !active {
                continue;
            }
            let due = WARMED.lock().unwrap().get(&model).is_none_or(|t| t.elapsed() >= WARM_EVERY);
            if !due {
                continue;
            }
            let r = http().post(format!("{}/api/generate", ollama_root())).json(&json!({"model": model, "keep_alive": KEEP})).send().await;
            match r {
                Ok(resp) if resp.status().is_success() => {
                    WARMED.lock().unwrap().insert(model, Instant::now());
                }
                Ok(resp) => tracing::info!(model, status = %resp.status(), "local model: Ollama wouldn't load it"),
                Err(e) => tracing::info!(model, error = %e, "local model: Ollama isn't reachable"),
            }
        }
    }

    /// What is loaded, who shares it, and copies that could be one.
    pub async fn local_models_status(&self) -> Value {
        let used = self.local_agents().await;
        let ps: Option<Value> = match http().get(format!("{}/api/ps", ollama_root())).send().await {
            Ok(r) if r.status().is_success() => r.json().await.ok(),
            _ => None,
        };
        let loaded: Vec<Value> = ps
            .as_ref()
            .and_then(|p| p["models"].as_array())
            .into_iter()
            .flatten()
            .map(|m| {
                let name = m["name"].as_str().or(m["model"].as_str()).unwrap_or_default().to_string();
                let agents: Vec<&String> = used.get(&name).map(|v| v.iter().map(|(_, n)| n).collect()).unwrap_or_default();
                json!({"model": name, "bytes": m["size"], "gpu_bytes": m["size_vram"], "until": m["expires_at"], "agents": agents})
            })
            .collect();
        let mut by_base: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for model in used.keys() {
            by_base.entry(base_of(model)).or_default().push(model.clone());
        }
        let doubles: Vec<Value> = by_base.into_iter().filter(|(_, v)| v.len() > 1).map(|(b, v)| json!({"base": b, "tags": v})).collect();
        // Every model pulled into Ollama: what an agent can be hired on, free and offline.
        let installed: Vec<String> = match http().get(format!("{}/api/tags", ollama_root())).send().await {
            Ok(r) if r.status().is_success() => r.json::<Value>().await.ok().and_then(|v| v["models"].as_array().cloned()).unwrap_or_default().iter().filter_map(|m| m["name"].as_str().or(m["model"].as_str()).map(str::to_string)).collect(),
            _ => Vec::new(),
        };
        json!({
            "server": ollama_root(),
            "reachable": ps.is_some(),
            "installed": installed,
            "loaded": loaded,
            "used": used.iter().map(|(m, a)| json!({"model": m, "agents": a.iter().map(|(_, n)| n).collect::<Vec<_>>()})).collect::<Vec<_>>(),
            "doubles": doubles,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_of_one_model_share_a_base() {
        assert_eq!(base_of("qwen3:8b-q8_0"), "qwen3:8b");
        assert_eq!(base_of("qwen3:8b"), "qwen3:8b");
        assert_eq!(base_of("llama3.2:latest"), "llama3.2");
        assert_eq!(base_of("llama3.2"), "llama3.2");
        assert_eq!(local_model("ollama:qwen3:8b"), Some("qwen3:8b"));
        assert_eq!(local_model("anthropic:claude-haiku-4-5"), None);
    }
}
