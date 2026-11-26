//! Settings an agent can read and change for the person: `settings_search`
//! (what there is, what each is set to now, the values it takes) and
//! `settings_set` (a change, put to the person on an approval card first).
//!
//! One table, `KEYS`, is the whole surface: each setting's name, where it
//! lives in the app, what it takes, and how it is read and written through the
//! same calls the app's own screens use. Secrets (keys, tokens) are never
//! here: an agent can say a provider is connected, never read its key.

use std::sync::{Arc, Weak};

use cookie_harness::tool::{tool, Effect, Tool};
use serde_json::{json, Value};

use crate::front::COOKIE_ID;
use crate::{util, Patch, Team};

/// What a setting takes.
#[derive(Clone, Copy)]
pub(crate) enum Kind {
    Bool,
    Int(i64, i64),
    /// A number; `off` (or empty) clears it when `optional`.
    Num(f64, f64, bool),
    Text,
    /// `provider:model`, or `off` when optional.
    Model(bool),
    Choice(&'static [&'static str]),
}

/// One setting. `agent`: it belongs to one agent (the caller, or another named one).
pub(crate) struct Key {
    pub id: &'static str,
    pub title: &'static str,
    pub where_: &'static str,
    pub kind: Kind,
    pub agent: bool,
    pub help: &'static str,
}

pub(crate) const KEYS: &[Key] = &[
    // Team-wide
    Key { id: "daily_notices", title: "Interruptions a day", where_: "Settings → General", kind: Kind::Int(0, 50), agent: false, help: "How many notices all agents together may send the person a day. Approvals always get through." },
    Key { id: "wake", title: "Wake agents when their memory changes", where_: "Settings → General", kind: Kind::Bool, agent: false, help: "With Enkeon: when something worth an agent's attention lands in its memory, it starts a job on it, a few times a day at most." },
    Key { id: "checker_model", title: "Checker model", where_: "Settings → Models", kind: Kind::Model(true), agent: false, help: "A second model, from another provider, that reads every send before the person sees it. `off` for none." },
    Key { id: "evolve.nightly", title: "Tune agents at night", where_: "Settings → Evolution", kind: Kind::Bool, agent: false, help: "Each night one change per agent is tried on a copy against the person's own jobs and kept only if it does as well or better. Uses real model calls." },
    Key { id: "evolve.hour", title: "Hour the night tuning runs", where_: "Settings → Evolution", kind: Kind::Int(0, 23), agent: false, help: "0 to 23, on this Mac's clock." },
    Key { id: "evolve.cases", title: "Exam cases per night", where_: "Settings → Evolution", kind: Kind::Int(3, 20), agent: false, help: "How many of the person's own jobs each night's exam replays." },
    Key { id: "evolve.max_dollars", title: "Night tuning budget ($)", where_: "Settings → Evolution", kind: Kind::Num(0.0, 100.0, false), agent: false, help: "The most a night of tuning may spend." },
    Key { id: "evolve.max_exams", title: "Exams per night", where_: "Settings → Evolution", kind: Kind::Int(1, 50), agent: false, help: "The most exams one night runs." },
    Key { id: "auto_skills.tests", title: "Test skills before using them", where_: "Settings → Skills", kind: Kind::Bool, agent: false, help: "A new skill is tried against each agent's practice tasks before it becomes part of how it works." },
    Key { id: "auto_skills.month_dollars", title: "Skills testing budget a month ($)", where_: "Settings → Skills", kind: Kind::Num(0.0, 500.0, false), agent: false, help: "What picking and testing skills may spend in a month." },
    Key { id: "cloud_store", title: "Keep approvals, notices and answers in Enkeon", where_: "Settings → Privacy", kind: Kind::Bool, agent: false, help: "So the person's phone and the Console see them and can answer. Only the words, never files." },
    Key { id: "sharing.server", title: "Serve this team over HTTP", where_: "Settings → Sharing", kind: Kind::Bool, agent: false, help: "Lets the person's phone, another computer or other people's agents reach the team." },
    Key { id: "sharing.port", title: "Sharing port", where_: "Settings → Sharing", kind: Kind::Int(1024, 65535), agent: false, help: "The port the team is served on." },
    Key { id: "market_url", title: "Market address", where_: "Settings → Market", kind: Kind::Text, agent: false, help: "Where to browse agents others published (a JSON index). `off` to clear." },
    Key { id: "files.level", title: "How far agents see files", where_: "The folder chip under the composer", kind: Kind::Choice(&["own", "folders", "home"]), agent: false, help: "own: each agent only its own folder; folders: plus the folders the person chose; home: the person's home folder (never secret places)." },
    // One agent's
    Key { id: "agent.name", title: "Name", where_: "Its profile", kind: Kind::Text, agent: true, help: "The agent's name." },
    Key { id: "agent.job", title: "Job", where_: "Its profile", kind: Kind::Text, agent: true, help: "Its one job, in the person's words." },
    Key { id: "agent.model", title: "Model", where_: "The model chip under the composer, or its profile", kind: Kind::Model(false), agent: true, help: "provider:model, e.g. anthropic:claude-sonnet-5-5. A new model re-tests its skills." },
    Key { id: "agent.backup_model", title: "Backup model", where_: "The model chip under the composer, or its profile", kind: Kind::Model(true), agent: true, help: "Answers when its model is out of reach (an outage, overload). `off` lets Cookie pick from the routes this Mac has: the same model another way first." },
    Key { id: "agent.look.shape", title: "Face shape", where_: "Its profile → look", kind: Kind::Choice(&crate::made::SHAPES), agent: true, help: "Its face's shape." },
    Key { id: "agent.look.color", title: "Face colour", where_: "Its profile → look", kind: Kind::Choice(&crate::made::COLORS), agent: true, help: "Its face's colour; its chat bubbles and send button follow it." },
    Key { id: "agent.grants.files", title: "Files", where_: "The permission chip under the composer", kind: Kind::Bool, agent: true, help: "Read, search and write files in its own folder." },
    Key { id: "agent.grants.web", title: "Web", where_: "The permission chip under the composer", kind: Kind::Bool, agent: true, help: "Search the web and read pages." },
    Key { id: "agent.grants.shell", title: "Commands", where_: "The permission chip under the composer", kind: Kind::Bool, agent: true, help: "Run commands, sandboxed to its own folder with no network." },
    Key { id: "agent.grants.memory", title: "Memory", where_: "The permission chip under the composer", kind: Kind::Bool, agent: true, help: "Keep notes, or use Enkeon when signed in." },
    Key { id: "agent.grants.routines", title: "Routines", where_: "The permission chip under the composer", kind: Kind::Bool, agent: true, help: "Set up routines of its own (each one asks first)." },
    Key { id: "agent.grants.team", title: "Team", where_: "The permission chip under the composer", kind: Kind::Bool, agent: true, help: "Message the person's other agents." },
    Key { id: "agent.grants.mac", title: "Mac apps", where_: "The permission chip under the composer", kind: Kind::Bool, agent: true, help: "Reminders, Notes, Calendar, Contacts, Messages on this Mac." },
    Key { id: "agent.grants.browser", title: "Browser", where_: "The permission chip under the composer", kind: Kind::Bool, agent: true, help: "A browser of its own with the sign-ins the person gave it; clicks and typing ask first." },
    Key { id: "agent.grants.worlds", title: "Parallax worlds", where_: "The permission chip under the composer", kind: Kind::Bool, agent: true, help: "Copies to try things in, undo, race and rewind." },
    Key { id: "agent.grants.apps", title: "Connected apps", where_: "The permission chip under the composer", kind: Kind::Bool, agent: true, help: "Apps connected through Enkeon (Gmail, Calendar, Slack…), billed per call." },
    Key { id: "agent.grants.helpers", title: "Helpers", where_: "The permission chip under the composer", kind: Kind::Bool, agent: true, help: "Send short-lived read-only helpers to research side by side." },
    Key { id: "agent.grants.contractors", title: "Contractors", where_: "The permission chip under the composer", kind: Kind::Bool, agent: true, help: "Bring in a temporary specialist for one piece of a job." },
    Key { id: "agent.limits.steps", title: "Model calls per job", where_: "Its profile → limits", kind: Kind::Int(1, 500), agent: true, help: "The most model calls one job may make." },
    Key { id: "agent.limits.tokens", title: "Tokens per job", where_: "Its profile → limits", kind: Kind::Int(1_000, 10_000_000), agent: true, help: "The most tokens one job may use." },
    Key { id: "agent.limits.job_dollars", title: "Dollars per job", where_: "Its profile → limits", kind: Kind::Num(0.0, 1_000.0, true), agent: true, help: "The most one job may spend (needs prices for its model). `off` for no limit." },
    Key { id: "agent.limits.month_dollars", title: "Dollars a month", where_: "Its profile → limits", kind: Kind::Num(0.0, 10_000.0, true), agent: true, help: "Past it, its jobs wait until the person raises it. `off` for no limit." },
];

pub(crate) fn key(id: &str) -> Option<&'static Key> {
    KEYS.iter().find(|k| k.id == id)
}

fn takes(k: &Key) -> String {
    match k.kind {
        Kind::Bool => "true or false".into(),
        Kind::Int(a, b) => format!("a whole number {a}–{b}"),
        Kind::Num(a, b, off) => format!("a number {a}–{b}{}", if off { ", or off" } else { "" }),
        Kind::Text => "text".into(),
        Kind::Model(off) => format!("provider:model{}", if off { ", or off" } else { "" }),
        Kind::Choice(c) => format!("one of: {}", c.join(", ")),
    }
}

/// A value as given (string or JSON), checked against what the setting takes.
pub(crate) fn parse(k: &Key, v: &Value) -> Result<Value, String> {
    let s = match v {
        Value::String(s) => s.trim().to_string(),
        other => other.to_string(),
    };
    let off = matches!(s.to_lowercase().as_str(), "off" | "none" | "" | "null");
    let bad = || format!("{} takes {}.", k.title, takes(k));
    Ok(match k.kind {
        Kind::Bool => match s.to_lowercase().as_str() {
            "true" | "on" | "yes" => json!(true),
            "false" | "off" | "no" => json!(false),
            _ => return Err(bad()),
        },
        Kind::Int(a, b) => {
            let n: i64 = s.parse().map_err(|_| bad())?;
            if n < a || n > b {
                return Err(bad());
            }
            json!(n)
        }
        Kind::Num(_, _, true) if off => Value::Null,
        Kind::Num(a, b, _) => {
            let n: f64 = s.trim_start_matches('$').parse().map_err(|_| bad())?;
            if !(a..=b).contains(&n) {
                return Err(bad());
            }
            json!(n)
        }
        Kind::Model(true) if off => Value::Null,
        Kind::Model(_) => {
            cookie_harness::Agent::new(&s).map_err(|e| format!("{s}: {e}"))?;
            json!(s)
        }
        Kind::Text if off && k.id == "market_url" => Value::Null,
        Kind::Text => {
            if s.is_empty() || s.len() > 2_000 {
                return Err(bad());
            }
            json!(s)
        }
        Kind::Choice(c) => {
            let l = s.to_lowercase();
            if !c.contains(&l.as_str()) {
                return Err(bad());
            }
            json!(l)
        }
    })
}

impl Team {
    /// Which agent a setting is about: the caller's own, or (Cookie only) another, by name, @address or id.
    async fn settings_target(&self, caller: &str, named: Option<&str>) -> Result<crate::AgentRecord, String> {
        let Some(n) = named.map(str::trim).filter(|n| !n.is_empty()) else { return self.agent(caller).await };
        let want = n.trim_start_matches('@').to_lowercase();
        let agents = self.agents().await;
        let a = agents
            .iter()
            .find(|a| a.id == want || a.name.to_lowercase() == want || self.slug_of(a).to_lowercase() == want)
            .cloned()
            .ok_or_else(|| format!("There is no agent called {n}."))?;
        if a.id != caller && caller != COOKIE_ID {
            return Err("You can change your own settings and the team's; another agent's, only Cookie or the person.".into());
        }
        Ok(a)
    }

    /// A setting's value now.
    pub(crate) async fn setting_value(&self, k: &Key, agent: Option<&crate::AgentRecord>) -> Value {
        let s = self.settings().await;
        if let Some(a) = agent {
            let look = util::read_json::<Value>(&self.paths.agent(&a.id).join("look.json"));
            let grants = serde_json::to_value(&a.grants).unwrap_or_default();
            let limits = serde_json::to_value(&a.limits).unwrap_or_default();
            return match k.id {
                "agent.name" => json!(a.name),
                "agent.job" => json!(a.job),
                "agent.model" => json!(a.model),
                "agent.backup_model" => s.backup_models.get(&a.id).map(|m| json!(m)).unwrap_or(json!("off")),
                "agent.look.shape" => look["shape"].clone(),
                "agent.look.color" => look["color"].clone(),
                id => match id.strip_prefix("agent.grants.") {
                    // Fields left out of the JSON when on (worlds, helpers, contractors) are on.
                    Some(g) => grants.get(g).cloned().unwrap_or(json!(true)),
                    None => id.strip_prefix("agent.limits.").map(|l| limits[l].clone()).unwrap_or(Value::Null),
                },
            };
        }
        match k.id {
            "daily_notices" => json!(s.daily_notices),
            "wake" => json!(s.wake),
            "checker_model" => json!(s.checker_model),
            "evolve.nightly" => json!(s.evolve.nightly),
            "evolve.hour" => json!(s.evolve.hour),
            "evolve.cases" => json!(s.evolve.cases),
            "evolve.max_dollars" => json!(s.evolve.max_dollars),
            "evolve.max_exams" => json!(s.evolve.max_exams),
            "auto_skills.tests" => json!(self.auto_cfg().tests),
            "auto_skills.month_dollars" => json!(self.auto_cfg().month_dollars),
            "cloud_store" => json!(s.cloud.store),
            "sharing.server" => json!(s.server.enabled),
            "sharing.port" => json!(s.server.port),
            "market_url" => json!(s.market_url),
            "files.level" => json!(self.access().level),
            _ => Value::Null,
        }
    }

    /// Change one setting through the same calls the app's screens use.
    pub(crate) async fn apply_setting(self: &Arc<Self>, k: &Key, agent: Option<&crate::AgentRecord>, v: Value) -> Result<(), String> {
        if let Some(a) = agent {
            let mut p = Patch::default();
            match k.id {
                "agent.name" => p.name = v.as_str().map(str::to_string),
                "agent.job" => p.job = v.as_str().map(str::to_string),
                "agent.model" => p.model = v.as_str().map(str::to_string),
                "agent.backup_model" => {
                    let m = v.as_str().map(str::trim).filter(|m| !m.is_empty() && *m != "off").map(str::to_string);
                    let id = a.id.clone();
                    self.update_settings(move |s| match m {
                        Some(m) => {
                            s.backup_models.insert(id, m);
                        }
                        None => {
                            s.backup_models.remove(&id);
                        }
                    })
                    .await?;
                    return Ok(());
                }
                "agent.look.shape" | "agent.look.color" => {
                    let look = util::read_json::<Value>(&self.paths.agent(&a.id).join("look.json"));
                    let (mut shape, mut color) = (look["shape"].as_str().map(str::to_string), look["color"].as_str().map(str::to_string));
                    if k.id.ends_with("shape") { shape = v.as_str().map(str::to_string) } else { color = v.as_str().map(str::to_string) }
                    self.set_agent_look(&a.id, shape, color).await?;
                    return Ok(());
                }
                id if id.starts_with("agent.grants.") => {
                    let mut g = serde_json::to_value(&a.grants).map_err(|e| e.to_string())?;
                    g[id.trim_start_matches("agent.grants.")] = v;
                    p.grants = Some(serde_json::from_value(g).map_err(|e| e.to_string())?);
                }
                id if id.starts_with("agent.limits.") => {
                    let mut l = serde_json::to_value(&a.limits).map_err(|e| e.to_string())?;
                    l[id.trim_start_matches("agent.limits.")] = v;
                    p.limits = Some(serde_json::from_value(l).map_err(|e| e.to_string())?);
                }
                _ => return Err("That setting can't be changed here.".into()),
            }
            let model_changed = p.model.as_ref().is_some_and(|m| *m != a.model);
            self.update(&a.id, p).await?;
            if model_changed {
                let (t, id) = (self.clone(), a.id.clone());
                tokio::spawn(async move { t.recheck_skills(&id).await });
            }
            return Ok(());
        }
        match k.id {
            "auto_skills.tests" => self.set_auto_cfg(v.as_bool(), None).map(|_| ()),
            "auto_skills.month_dollars" => self.set_auto_cfg(None, v.as_f64()).map(|_| ()),
            "files.level" => {
                let folders = self.access().folders;
                self.set_access(v.as_str().unwrap_or("own"), folders).map(|_| ())
            }
            id => {
                // The same patch the Settings screen sends.
                let patch = match id {
                    "checker_model" | "market_url" => json!({ id: v.as_str().unwrap_or("") }),
                    "sharing.server" => json!({"server": {"enabled": v}}),
                    "sharing.port" => json!({"server": {"port": v}}),
                    id if id.starts_with("evolve.") => json!({"evolve": { id.trim_start_matches("evolve."): v }}),
                    id => json!({ id: v }),
                };
                self.update_settings(|s| crate::api::apply_settings(s, &patch)).await?;
                if patch.get("server").is_some() {
                    crate::server::spawn_if_enabled(self.clone());
                }
                Ok(())
            }
        }
    }
}

/// `settings_search` and `settings_set` for one agent.
pub(crate) fn tools(team: Weak<Team>, me: String) -> Vec<Arc<dyn Tool>> {
    let (t1, me1) = (team.clone(), me.clone());
    let search = tool(
        "settings_search",
        "Find the app's settings you can read and change for the person: each one's key, where it is in the app, what it is set to now, and \
         what it takes. Empty query lists them all. `agent`: another agent's own settings (by name), else yours and the team's.",
        json!({"type": "object", "properties": {
            "query": {"type": "string", "description": "words, e.g. 'model', 'budget', 'web', 'notifications'"},
            "agent": {"type": "string"}
        }}),
        Effect::Read,
        move |a: Value| {
            let (team, me) = (t1.clone(), me1.clone());
            async move {
                let team = team.upgrade().ok_or("Cookie is closing.")?;
                let target = team.settings_target(&me, a["agent"].as_str()).await?;
                let q: Vec<String> = crate::shelf::terms(a["query"].as_str().unwrap_or(""));
                let mut out = Vec::new();
                for k in KEYS {
                    let hay = crate::shelf::terms(&format!("{} {} {} {}", k.id.replace(['.', '_'], " "), k.title, k.where_, k.help));
                    if !q.is_empty() && !q.iter().any(|w| hay.contains(w)) {
                        continue;
                    }
                    let now = team.setting_value(k, k.agent.then_some(&target)).await;
                    out.push(json!({"key": k.id, "title": k.title, "where": k.where_, "now": now, "takes": takes(k), "about": k.help, "for": if k.agent { target.name.as_str() } else { "the whole team" }}));
                }
                if out.is_empty() {
                    return Ok("No setting matches; try fewer words, or app_help for how the app works.".into());
                }
                Ok(serde_json::to_string_pretty(&out).unwrap_or_default())
            }
        },
    );
    let set = tool(
        "settings_set",
        "Change one of the app's settings for the person (keys from settings_search). The person sees what will change and approves it first. \
         `agent`: another agent's own setting, Cookie only; else yours or the team's.",
        json!({"type": "object", "properties": {
            "key": {"type": "string", "enum": KEYS.iter().map(|k| k.id).collect::<Vec<_>>()},
            "value": {"type": "string", "description": "the new value, as settings_search says it takes"},
            "agent": {"type": "string"}
        }, "required": ["key", "value"]}),
        Effect::Write,
        move |a: Value| {
            let (team, me) = (team.clone(), me.clone());
            async move {
                let team = team.upgrade().ok_or("Cookie is closing.")?;
                let k = key(a["key"].as_str().unwrap_or("")).ok_or("No such setting; find it with settings_search.")?;
                let v = parse(k, &a["value"])?;
                let target = if k.agent { Some(team.settings_target(&me, a["agent"].as_str()).await?) } else { None };
                let before = team.setting_value(k, target.as_ref()).await;
                team.apply_setting(k, target.as_ref(), v.clone()).await?;
                let after = team.setting_value(k, target.as_ref()).await;
                let whose = target.map(|t| format!("{}'s ", t.name)).unwrap_or_default();
                Ok(format!("{whose}{} changed: {} → {}.", k.title, before, after))
            }
        },
    )
    .with_preview(|a| {
        let k = key(a["key"].as_str().unwrap_or(""));
        let title = k.map(|k| k.title).unwrap_or("A setting");
        let whose = a["agent"].as_str().filter(|s| !s.trim().is_empty()).map(|s| format!(" ({s})")).unwrap_or_default();
        let place = k.map(|k| format!("\n{}", k.where_)).unwrap_or_default();
        format!("Change {title}{whose} to: {}{place}", util::clip(&a["value"].to_string().trim_matches('"').to_string(), 200))
    });
    vec![Arc::new(search), Arc::new(set)]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_key_is_unique_and_values_are_checked() {
        let mut ids: Vec<&str> = KEYS.iter().map(|k| k.id).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), KEYS.len());
        // Drift guard: every on/off permission an agent has is a setting (fields left out when on are switched off to show).
        let mut g = serde_json::to_value(crate::store::Grants::default()).unwrap();
        for f in ["worlds", "helpers", "contractors"] {
            g[f] = json!(false);
        }
        for (name, v) in g.as_object().unwrap() {
            if v.is_boolean() {
                assert!(key(&format!("agent.grants.{name}")).is_some(), "the permission `{name}` has no setting");
            }
        }
        // And every limit.
        for (name, _) in serde_json::to_value(crate::store::Limits::default()).unwrap().as_object().unwrap() {
            assert!(key(&format!("agent.limits.{name}")).is_some(), "the limit `{name}` has no setting");
        }
        let n = key("daily_notices").unwrap();
        assert_eq!(parse(n, &json!("12")).unwrap(), json!(12));
        assert!(parse(n, &json!("99")).is_err());
        assert_eq!(parse(key("wake").unwrap(), &json!("off")).unwrap(), json!(false));
        assert_eq!(parse(key("agent.limits.job_dollars").unwrap(), &json!("off")).unwrap(), Value::Null);
        assert!(parse(key("agent.look.color").unwrap(), &json!("neon")).is_err());
        assert_eq!(parse(key("checker_model").unwrap(), &json!("off")).unwrap(), Value::Null);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_setting_is_read_and_changed_through_the_app_s_own_calls() {
        let dir = std::env::temp_dir().join(format!("cookie-appset-{}", util::random_hex(4)));
        let team = Team::open(&dir).unwrap();
        let k = key("daily_notices").unwrap();
        team.apply_setting(k, None, json!(7)).await.unwrap();
        assert_eq!(team.setting_value(k, None).await, json!(7));
        let e = key("evolve.hour").unwrap();
        team.apply_setting(e, None, json!(4)).await.unwrap();
        assert_eq!(team.setting_value(e, None).await, json!(4));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
