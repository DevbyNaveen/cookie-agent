//! What an agent made, the one thing pinned beside its name, and the app's
//! settings as an agent may see them.
//!
//! - **Made.** The files in the agent's own folder (what it wrote, built or was
//!   given), newest first, and its space (the workspace blocks) when it has one.
//! - **Pinned.** One item per agent, a file or its space, shown as a button beside
//!   the agent's name. Kept in the agent's folder (`pin.json`).
//! - **Settings, read-only.** `app_settings` tells an agent how Cookie is set up:
//!   its own permissions, the team, which models and channels are connected, what
//!   files agents see, voice, the cloud computer. Names and on/off only: never a
//!   key, token or code.

use std::sync::{Arc, Weak};

use cookie_harness::tool::{tool, Effect, Tool};
use serde_json::{json, Value};

use crate::{util, Team};

/// How many files the list shows, and how deep it looks.
const MAX_FILES: usize = 300;
const MAX_DEPTH: usize = 5;
/// Pinning the space instead of a file.
pub const SPACE: &str = "@space";
/// The faces an agent can wear and the colours it can come in (`ui/face.js` draws them).
pub const SHAPES: [&str; 12] = ["gumdrop", "bun", "macaron", "mochi", "biscuit", "orb", "crystal", "wisp", "bot", "cloud", "star", "ghost"];
pub const COLORS: [&str; 11] = ["amber", "berry", "blueberry", "matcha", "plum", "mint", "caramel", "rose", "lemon", "lagoon", "chocolate"];

impl Team {
    /// The files in an agent's folder, newest first: path (in its folder), name, kind, size, when.
    pub async fn agent_files(&self, agent: &str) -> Result<Value, String> {
        self.agent(agent).await?;
        let work = self.paths.work(agent);
        let mut files: Vec<(u64, Value)> = Vec::new();
        let mut stack = vec![(work.clone(), 0usize)];
        while let Some((dir, depth)) = stack.pop() {
            let Ok(rd) = std::fs::read_dir(&dir) else { continue };
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().to_string();
                if name.starts_with('.') || name == "node_modules" || name == "target" || name == "__pycache__" {
                    continue;
                }
                let Ok(ft) = e.file_type() else { continue };
                if ft.is_dir() {
                    if depth < MAX_DEPTH {
                        stack.push((e.path(), depth + 1));
                    }
                    continue;
                }
                if !ft.is_file() {
                    continue;
                }
                let Ok(meta) = e.metadata() else { continue };
                let when = meta.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
                let rel = e.path().strip_prefix(&work).map(|p| p.to_string_lossy().to_string()).unwrap_or(name.clone());
                let (kind, _) = crate::chatfiles::kind_of(&e.path());
                files.push((when, json!({"path": rel, "name": name, "kind": kind, "size": meta.len(), "modified": when, "given": rel.starts_with("attachments/")})));
            }
        }
        files.sort_by(|a, b| b.0.cmp(&a.0));
        let total = files.len();
        let blocks = self.workspace(agent).await.ok().and_then(|w| w["blocks"].as_array().map(|b| b.len())).unwrap_or(0);
        Ok(json!({
            "files": files.into_iter().take(MAX_FILES).map(|(_, v)| v).collect::<Vec<_>>(),
            "more": total.saturating_sub(MAX_FILES),
            "space": (blocks > 0).then(|| json!({"blocks": blocks})),
            "pin": self.agent_pin(agent),
        }))
    }

    fn pin_file(&self, agent: &str) -> std::path::PathBuf {
        self.paths.agent(agent).join("pin.json")
    }

    /// The item pinned beside this agent's name: a path in its folder, or `@space`.
    pub fn agent_pin(&self, agent: &str) -> Option<String> {
        util::read_json::<Value>(&self.pin_file(agent))["path"].as_str().map(str::to_string)
    }

    /// Pin one item (replacing any other), or unpin with `None`.
    pub async fn set_agent_pin(&self, agent: &str, path: Option<String>) -> Result<Option<String>, String> {
        self.agent(agent).await?;
        match path.as_deref().map(str::trim).filter(|p| !p.is_empty()) {
            None => {
                let _ = std::fs::remove_file(self.pin_file(agent));
                Ok(None)
            }
            Some(SPACE) => {
                util::write_json(&self.pin_file(agent), &json!({"path": SPACE}))?;
                Ok(Some(SPACE.into()))
            }
            Some(p) => {
                // Only something that is in its folder now.
                let work = self.paths.work(agent);
                let real = util::inside(&work, p).filter(|r| r.is_file()).ok_or("That file isn't in its folder.")?;
                let rel = real.strip_prefix(&work).map(|r| r.to_string_lossy().to_string()).map_err(|_| "That file isn't in its folder.".to_string())?;
                util::write_json(&self.pin_file(agent), &json!({"path": rel}))?;
                Ok(Some(rel))
            }
        }
    }

    fn look_file(&self, agent: &str) -> std::path::PathBuf {
        self.paths.agent(agent).join("look.json")
    }

    /// The shape and colour the person chose for every agent that has one: `{id: {shape, color}}`.
    pub async fn agent_looks(&self) -> Value {
        let ids: Vec<String> = self.agents.read().await.iter().map(|r| r.id.clone()).collect();
        let mut out = serde_json::Map::new();
        for id in ids {
            let v = util::read_json::<Value>(&self.look_file(&id));
            if v.is_object() && (v["shape"].is_string() || v["color"].is_string()) {
                out.insert(id, v);
            }
        }
        Value::Object(out)
    }

    /// Choose an agent's shape and colour (either may be left as drawn); both `None` goes back to its own.
    pub async fn set_agent_look(&self, agent: &str, shape: Option<String>, color: Option<String>) -> Result<Value, String> {
        self.agent(agent).await?;
        let shape = shape.map(|x| x.trim().to_ascii_lowercase()).filter(|x| !x.is_empty());
        let color = color.map(|x| x.trim().to_ascii_lowercase()).filter(|x| !x.is_empty());
        if let Some(x) = &shape {
            if !SHAPES.contains(&x.as_str()) {
                return Err(format!("`{x}` isn't a shape: {}.", SHAPES.join(", ")));
            }
        }
        if let Some(x) = &color {
            if !COLORS.contains(&x.as_str()) {
                return Err(format!("`{x}` isn't a colour: {}.", COLORS.join(", ")));
            }
        }
        if shape.is_none() && color.is_none() {
            let _ = std::fs::remove_file(self.look_file(agent));
            return Ok(Value::Null);
        }
        let v = json!({"shape": shape, "color": color});
        util::write_json(&self.look_file(agent), &v)?;
        Ok(v)
    }

    /// How Cookie is set up, as an agent may read it: names and on/off, never a secret.
    pub async fn app_settings_for(&self, agent: &str) -> Result<Value, String> {
        let me = self.agent(agent).await?;
        let s = self.settings().await;
        let team: Vec<Value> = self
            .agents
            .read()
            .await
            .iter()
            .map(|r| json!({"name": r.name, "job": r.job.chars().take(160).collect::<String>(), "model": r.model, "you": r.id == agent}))
            .collect();
        let models: Vec<&str> = crate::keys::PROVIDERS.iter().filter(|(n, _, _)| self.keys.get(n).is_some()).map(|(_, label, _)| *label).collect();
        let access = self.access();
        let channels: Vec<Value> = self
            .channel_states()
            .into_iter()
            .map(|(k, c)| json!({"channel": k, "connected": c.enabled, "chats": c.chats.len()}))
            .chain(std::iter::once(json!({"channel": "telegram", "connected": s.telegram.enabled, "chats": s.telegram.chats.len()})))
            .collect();
        let voice = self.voice_status();
        let computer = self.computer().map(|c| json!({"region": c.region, "kind": c.kind, "market": c.market}));
        Ok(json!({
            "you": {
                "name": me.name, "model": me.model, "job": me.job,
                "permissions": me.grants, "limits": me.limits,
                "on_probation": me.probation_until.is_some_and(|t| t > util::now()),
            },
            "team": team,
            "model_providers_with_keys": models,
            "enkeon": {"connected": crate::pair::enkeon().is_some()},
            "files_agents_see": {"level": access.level, "folders": access.folders},
            "channels": channels,
            "voice": {"elevenlabs": voice.eleven, "voice": voice.voice_name, "transcription_on_this_mac": voice.local},
            "cloud_computer": computer,
            "onepassword_vaults_allowed": self.onepassword().vaults.len(),
            "sharing_over_http": {"on": s.server.enabled, "port": s.server.port},
            "wake_for_routines": s.wake,
            "where_to_change_things": "Settings in Cookie's window (⌘,): General, About you, Models, Usage, Channels, Evolution, Skills, Spaces, Sharing, Market, Privacy, About. Many can be changed for the person with settings_set (they approve each change); the rest they change there.",
        }))
    }
}

/// `app_settings`: how Cookie is set up, read-only.
pub(crate) fn settings_tool(team: Weak<Team>, agent: String) -> Arc<dyn Tool> {
    Arc::new(tool(
        "app_settings",
        "How Cookie is set up right now, read-only: your own permissions and limits, the team, which model providers and channels \
         are connected, which files agents may see, voice, the cloud computer and 1Password. Use it to answer the person's questions \
         about the app. To change a setting for them, use settings_search and settings_set (they approve it); for how the app works, app_help.",
        json!({"type": "object", "properties": {}}),
        Effect::Read,
        move |_a: Value| {
            let team = team.clone();
            let agent = agent.clone();
            async move {
                let t = team.upgrade().ok_or("Cookie is closing.")?;
                let v = t.app_settings_for(&agent).await?;
                Ok(serde_json::to_string_pretty(&v).unwrap_or_default())
            }
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(flavor = "multi_thread")]
    async fn what_an_agent_made_is_listed_newest_first_and_one_item_is_pinned() {
        let dir = std::env::temp_dir().join(format!("cookie-made-{}", util::random_hex(4)));
        let team = Team::open(&dir).unwrap();
        let rec = team
            .add_agent(crate::AgentRecord {
                id: "a".into(), name: "A".into(), model: "anthropic:x".into(), job: "j".into(), created_at: 0,
                grants: Default::default(), limits: Default::default(), probation_until: None, parent: None, shadow_of: None, handover: None, origin: None, version: 1,
            })
            .await
            .unwrap();
        let work = team.paths.work(&rec.id);
        std::fs::create_dir_all(work.join("plans")).unwrap();
        std::fs::write(work.join("plans/week-1.md"), "# Week 1").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        std::fs::write(work.join("report.pdf"), "%PDF-1.4").unwrap();
        std::fs::write(work.join(".hidden"), "x").unwrap();
        let v = team.agent_files(&rec.id).await.unwrap();
        let names: Vec<&str> = v["files"].as_array().unwrap().iter().map(|f| f["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["report.pdf", "week-1.md"], "newest first, hidden left out");
        assert_eq!(v["files"][0]["kind"], "pdf");

        assert_eq!(team.set_agent_pin(&rec.id, Some("plans/week-1.md".into())).await.unwrap().as_deref(), Some("plans/week-1.md"));
        assert_eq!(team.set_agent_pin(&rec.id, Some("report.pdf".into())).await.unwrap().as_deref(), Some("report.pdf"), "one pin: the new one replaces it");
        assert_eq!(team.agent_pin(&rec.id).as_deref(), Some("report.pdf"));
        assert!(team.set_agent_pin(&rec.id, Some("../../agents.json".into())).await.is_err(), "never outside its folder");
        assert!(team.set_agent_pin(&rec.id, None).await.unwrap().is_none());
        assert!(team.agent_pin(&rec.id).is_none());

        assert_eq!(team.set_agent_look(&rec.id, Some("Star".into()), Some("mint".into())).await.unwrap(), json!({"shape": "star", "color": "mint"}));
        assert_eq!(team.agent_looks().await[&rec.id]["shape"], "star");
        assert!(team.set_agent_look(&rec.id, Some("dragon".into()), None).await.is_err(), "only shapes it can draw");
        assert!(team.set_agent_look(&rec.id, None, Some("#ff0000".into())).await.is_err(), "only its colours");
        assert!(team.set_agent_look(&rec.id, None, None).await.unwrap().is_null());
        assert!(team.agent_looks().await.get(&rec.id).is_none(), "back to the face its id gives it");

        let s = team.app_settings_for(&rec.id).await.unwrap();
        let text = s.to_string();
        assert_eq!(s["you"]["name"], "A");
        assert!(s["team"].as_array().unwrap().iter().any(|m| m["you"] == true));
        for secret in ["token", "pending_code", "invites", "secret"] {
            assert!(!text.contains(&format!("\"{secret}\"")), "no {secret} field reaches an agent");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
