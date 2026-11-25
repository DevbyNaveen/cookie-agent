//! A whole team as one Markdown file (`TEAM.md`), on top of signed packs.
//!
//! The file is a playbook people and other AIs can read, with the team's
//! shape in TOML front matter (`+++`): each agent's name, job, model, the
//! access it asks for, and its routines. Cookie reads the front matter to add
//! the team in one step; Claude, ChatGPT or a person can follow the Markdown.
//!
//! ```text
//! +++
//! format = "cookie-team/1"
//! name = "Launch team"
//! about = "Writes the launch note and finds who to send it to."
//!
//! [[agents]]
//! name = "Writing Desk"
//! job = "Turns rough notes into posts and emails."
//! model = "anthropic:claude-sonnet-4-6"
//! asks_for = ["files", "web"]
//!
//! [[agents.routines]]
//! task = "Draft the weekly update from my notes"
//! schedule = { every = "weekday", at = "08:30" }
//!
//! [signature]
//! by = "<the team's Ed25519 key, hex>"
//! value = "<signature over everything above it and the playbook, hex>"
//! +++
//!
//! # Launch team
//! …the playbook…
//! ```
//!
//! Trust is the same as a pack's: a signed file is checked with the team's
//! Ed25519 key over the front matter and the playbook together, and a broken
//! signature is refused; an unsigned file (hand-written) is allowed and said
//! so. Either way every agent starts with no access at all and on probation:
//! what it asks for is listed for the person to grant, and its routines arrive
//! paused. A file never carries keys, conversations, memory or files, and a
//! routine started by a web address (it has a secret) is never written out.

use ring::signature::{KeyPair, UnparsedPublicKey, ED25519};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::pack::{hex, key_pair, sorted, unhex};
use crate::store::{AgentRecord, Grants, Limits, Origin, Schedule};
use crate::{util, Team};

pub const FORMAT: &str = "cookie-team/1";
/// The most agents one file may add, and the largest file read.
pub const MAX_AGENTS: usize = 20;
pub const MAX_BYTES: usize = 512 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TeamRoutine {
    pub task: String,
    pub schedule: Schedule,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TeamAgent {
    pub name: String,
    pub job: String,
    #[serde(default)]
    pub model: String,
    /// What it asks to use: files, web, shell, memory, routines, team, mac, browser, worlds, apps, helpers.
    #[serde(default)]
    pub asks_for: Vec<String>,
    #[serde(default)]
    pub routines: Vec<TeamRoutine>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Signature {
    pub by: String,
    pub value: String,
}

/// The front matter as written.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct Front {
    format: String,
    name: String,
    #[serde(default)]
    about: String,
    agents: Vec<TeamAgent>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    signature: Option<Signature>,
}

/// A team file, read.
#[derive(Debug, Clone, PartialEq)]
pub struct TeamFile {
    pub name: String,
    pub about: String,
    pub agents: Vec<TeamAgent>,
    pub playbook: String,
    pub signature: Option<Signature>,
}

/// How far a file can be trusted.
#[derive(Debug, Clone, PartialEq)]
pub enum Trust {
    /// Signed, and the signature matches: by this key.
    Signed { by: String, hash: String },
    /// No signature: anyone could have written it.
    Unsigned,
}

const GRANT_NAMES: [&str; 11] = ["files", "web", "shell", "memory", "routines", "team", "mac", "browser", "worlds", "apps", "helpers"];

fn grant_names(g: &Grants) -> Vec<String> {
    let on = [g.files, g.web, g.shell, g.memory, g.routines, g.team, g.mac, g.browser, g.worlds, g.apps, g.helpers];
    GRANT_NAMES.iter().zip(on).filter(|(_, on)| *on).map(|(n, _)| n.to_string()).collect()
}

/// What the signature covers: the front matter without the signature, and the playbook, as sorted compact JSON.
fn canonical(t: &TeamFile) -> Vec<u8> {
    let v = json!({"format": FORMAT, "name": t.name, "about": t.about, "agents": t.agents, "playbook": t.playbook.trim()});
    sorted(&v).to_string().into_bytes()
}

/// Read a team file. Errors say what's wrong, in words.
pub fn parse(text: &str) -> Result<TeamFile, String> {
    if text.len() > MAX_BYTES {
        return Err("That file is over 512 KB: a team file is a few pages.".into());
    }
    let text = text.trim_start_matches('\u{feff}').replace("\r\n", "\n");
    let rest = text.trim_start().strip_prefix("+++\n").ok_or("A team file starts with +++ and its front matter.")?;
    let end = rest.find("\n+++").ok_or("The front matter never ends: close it with a line of +++.")?;
    let (front, after) = (&rest[..end], &rest[end + 4..]);
    let f: Front = toml::from_str(front).map_err(|e| format!("The front matter isn't right: {}", e.message()))?;
    if f.format != FORMAT {
        return Err(format!("This file is {}, not {FORMAT}.", f.format));
    }
    if f.name.trim().is_empty() || f.agents.is_empty() {
        return Err("A team needs a name and at least one agent.".into());
    }
    if f.agents.len() > MAX_AGENTS {
        return Err(format!("{} agents is more than one file adds ({MAX_AGENTS}).", f.agents.len()));
    }
    for a in &f.agents {
        if a.name.trim().is_empty() || a.job.trim().is_empty() {
            return Err("Every agent needs a name and a job.".into());
        }
        if let Some(bad) = a.asks_for.iter().find(|g| !GRANT_NAMES.contains(&g.as_str())) {
            return Err(format!("{} asks for `{bad}`, which Cookie doesn't have.", a.name));
        }
        for r in &a.routines {
            if matches!(r.schedule, Schedule::Webhook { .. }) {
                return Err("A team file can't carry a web-address routine: it would need its secret.".into());
            }
            crate::routines::validate(&r.schedule).map_err(|e| format!("{}'s routine “{}”: {e}", a.name, r.task))?;
        }
    }
    Ok(TeamFile { name: f.name.trim().into(), about: f.about.trim().into(), agents: f.agents, playbook: after.trim_start_matches('\n').to_string(), signature: f.signature })
}

/// Check a file's signature. A signature that doesn't match is an error; none is `Unsigned`.
pub fn verify(t: &TeamFile) -> Result<Trust, String> {
    let Some(sig) = &t.signature else { return Ok(Trust::Unsigned) };
    let key = unhex(&sig.by).ok_or("The signer's key isn't hex.")?;
    let value = unhex(&sig.value).ok_or("The signature isn't hex.")?;
    let bytes = canonical(t);
    UnparsedPublicKey::new(&ED25519, key)
        .verify(&bytes, &value)
        .map_err(|_| "The signature doesn't match: this file was changed after it was signed.".to_string())?;
    Ok(Trust::Signed { by: sig.by.clone(), hash: crate::peers::sha256_hex(&String::from_utf8_lossy(&bytes)) })
}

/// Write a team file: front matter, signature, then the playbook.
pub fn render(t: &TeamFile) -> String {
    let front = Front { format: FORMAT.into(), name: t.name.clone(), about: t.about.clone(), agents: t.agents.clone(), signature: t.signature.clone() };
    let toml = toml::to_string(&front).unwrap_or_default();
    format!("+++\n{}+++\n\n{}\n", toml, t.playbook.trim())
}

/// The playbook a team file carries when its maker wrote none: who's who, in words.
fn playbook_of(name: &str, about: &str, agents: &[TeamAgent]) -> String {
    let mut s = format!("# {name}\n\n");
    if !about.is_empty() {
        s.push_str(&format!("{about}\n\n"));
    }
    for a in agents {
        s.push_str(&format!("## {}\n\n{}\n", a.name, a.job));
        if !a.asks_for.is_empty() {
            s.push_str(&format!("\nIt asks to use: {}.\n", a.asks_for.join(", ")));
        }
        for r in &a.routines {
            s.push_str(&format!("\n- {}: {}\n", crate::routines::describe(&r.schedule), r.task));
        }
        s.push('\n');
    }
    s.push_str("---\nMade with Cookie. Add this team in Cookie (Settings → Market → Add a team), or follow it by hand.\n");
    s
}

/// Keep a team file in the person's Downloads folder, never over another file. Returns where.
pub fn save_to_downloads(name: &str, text: &str) -> Result<String, String> {
    let home = std::env::var_os("HOME").ok_or("No home folder.")?;
    let dir = std::path::PathBuf::from(home).join("Downloads");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let base: String = name.chars().map(|c| if c.is_alphanumeric() || c == '-' { c } else { '-' }).collect::<String>().trim_matches('-').to_lowercase();
    let base = if base.is_empty() { "team".to_string() } else { base };
    let mut path = dir.join(format!("{base}.TEAM.md"));
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("{base} ({n}).TEAM.md"));
        n += 1;
    }
    std::fs::write(&path, text).map_err(|e| e.to_string())?;
    Ok(path.to_string_lossy().into_owned())
}

impl Team {
    /// Your team (or the agents named) as one signed Markdown file.
    pub async fn export_team(&self, name: &str, about: &str, ids: Option<Vec<String>>) -> Result<String, String> {
        let all = self.agents().await;
        let chosen: Vec<&AgentRecord> = all
            .iter()
            .filter(|a| a.shadow_of.is_none() && !crate::bench::is_probe(&a.id) && a.id != crate::front::COOKIE_ID)
            .filter(|a| ids.as_ref().is_none_or(|ids| ids.contains(&a.id)))
            .take(MAX_AGENTS)
            .collect();
        if chosen.is_empty() {
            return Err("Choose at least one agent to share (Cookie itself comes with every team).".into());
        }
        let routines = self.routines().await;
        let agents: Vec<TeamAgent> = chosen
            .iter()
            .map(|a| TeamAgent {
                name: a.name.clone(),
                job: a.job.clone(),
                model: a.model.clone(),
                asks_for: grant_names(&a.grants),
                routines: routines
                    .iter()
                    .filter(|r| r.agent == a.id && !matches!(r.schedule, Schedule::Webhook { .. }))
                    .map(|r| TeamRoutine { task: r.task.clone(), schedule: r.schedule.clone() })
                    .collect(),
            })
            .collect();
        let name = if name.trim().is_empty() { "My team".to_string() } else { name.trim().to_string() };
        let mut t = TeamFile { playbook: playbook_of(&name, about.trim(), &agents), name, about: about.trim().into(), agents, signature: None };
        let kp = key_pair(self)?;
        let sig = kp.sign(&canonical(&t));
        t.signature = Some(Signature { by: hex(kp.public_key().as_ref()), value: hex(sig.as_ref()) });
        Ok(render(&t))
    }

    /// What adding a file would do, for the person to review first.
    pub async fn preview_team(&self, text: &str) -> Result<Value, String> {
        let t = parse(text)?;
        let trust = verify(&t)?;
        let mine = self.publisher_key().ok();
        let mut agents = Vec::new();
        for a in &t.agents {
            let model_ok = !a.model.trim().is_empty() && cookie_harness::Agent::new(&a.model).is_ok();
            agents.push(json!({
                "name": a.name, "job": a.job, "model": a.model, "model_ok": model_ok,
                "asks_for": a.asks_for, "taken": self.agent_named(&a.name).await.is_some(),
                "routines": a.routines.iter().map(|r| json!({"task": r.task, "when": crate::routines::describe(&r.schedule)})).collect::<Vec<_>>(),
            }));
        }
        let (signed, by) = match &trust {
            Trust::Signed { by, .. } => (true, Some(by.clone())),
            Trust::Unsigned => (false, None),
        };
        Ok(json!({"name": t.name, "about": t.about, "agents": agents, "playbook": t.playbook, "signed": signed, "by": by, "yours": by.is_some() && by == mine}))
    }

    /// Add a team from a file: each agent with no access, on probation, its routines paused.
    /// `model`: for agents whose own model has no key here.
    pub async fn install_team(&self, text: &str, model: Option<String>) -> Result<Vec<AgentRecord>, String> {
        let t = parse(text)?;
        let trust = verify(&t)?;
        let fallback = model.filter(|m| !m.trim().is_empty());
        // Every agent's model is settled before any is added: a team arrives whole or not at all.
        let mut plan = Vec::new();
        for a in &t.agents {
            let m = if !a.model.trim().is_empty() && cookie_harness::Agent::new(&a.model).is_ok() {
                a.model.clone()
            } else {
                let m = fallback.clone().ok_or_else(|| format!("{} uses {}, which has no key here: choose a model for it.", a.name, if a.model.is_empty() { "no model" } else { &a.model }))?;
                cookie_harness::Agent::new(&m).map_err(|e| format!("{e} (choose a model you have a key for)"))?;
                m
            };
            plan.push((a, m));
        }
        let origin = match &trust {
            Trust::Signed { by, hash } => Some(Origin { publisher_key: by.clone(), pack_hash: hash.clone(), imported_at: util::now() }),
            Trust::Unsigned => None,
        };
        let mut hired = Vec::new();
        for (a, model) in plan {
            let mut name = a.name.trim().to_string();
            let mut n = 2;
            while self.agent_named(&name).await.is_some() {
                name = format!("{} {n}", a.name.trim());
                n += 1;
            }
            let rec = AgentRecord {
                id: util::new_id(&name),
                name,
                model,
                job: a.job.trim().to_string(),
                created_at: util::now(),
                grants: Grants::none(),
                limits: Limits::default(),
                probation_until: Some(util::now() + 7 * 86_400),
                parent: None,
                shadow_of: None,
                handover: None,
                origin: origin.clone(),
                version: 1,
            };
            let rec = self.add_agent(rec).await?;
            for r in &a.routines {
                if let Ok(made) = self.add_routine(&rec.id, &r.task, r.schedule.clone()).await {
                    let _ = self.set_routine_enabled(&made.id, false).await; // arrives paused
                }
            }
            hired.push(rec);
        }
        Ok(hired)
    }

    /// A team file from an https address (a GitHub page is read raw).
    pub async fn fetch_team(&self, url: &str) -> Result<String, String> {
        let url = url.trim();
        if !url.starts_with("https://") {
            return Err("A team's address must be https.".into());
        }
        // A GitHub file page → its raw text.
        let url = match url.strip_prefix("https://github.com/") {
            Some(rest) if rest.contains("/blob/") => format!("https://raw.githubusercontent.com/{}", rest.replacen("/blob/", "/", 1)),
            _ => url.to_string(),
        };
        let r = reqwest::Client::new().get(&url).timeout(std::time::Duration::from_secs(20)).send().await.map_err(|e| e.without_url().to_string())?;
        if !r.status().is_success() {
            return Err(format!("That address answered {}.", r.status()));
        }
        if r.content_length().is_some_and(|n| n as usize > MAX_BYTES) {
            return Err("That file is over 512 KB: a team file is a few pages.".into());
        }
        let bytes = r.bytes().await.map_err(|e| e.without_url().to_string())?;
        if bytes.len() > MAX_BYTES {
            return Err("That file is over 512 KB: a team file is a few pages.".into());
        }
        String::from_utf8(bytes.to_vec()).map_err(|_| "That isn't a text file.".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HAND: &str = r#"+++
format = "cookie-team/1"
name = "Launch team"
about = "Writes the launch note."

[[agents]]
name = "Writing Desk"
job = "Turns rough notes into posts."
model = "anthropic:claude-sonnet-4-6"
asks_for = ["files", "web"]

[[agents.routines]]
task = "Draft the weekly update"
schedule = { every = "weekday", at = "08:30" }

[[agents]]
name = "Lead Watch"
job = "Watches for new leads."

[[agents.routines]]
task = "Note each new lead"
schedule = { every = "app", app = "gmail", contains = ["demo request"] }
+++

# Launch team

Writing Desk drafts; Lead Watch finds who to send it to.
"#;

    #[test]
    fn a_hand_written_file_reads_and_is_unsigned() {
        let t = parse(HAND).unwrap();
        assert_eq!((t.name.as_str(), t.agents.len()), ("Launch team", 2));
        assert_eq!(t.agents[0].routines[0].schedule, Schedule::Weekday { at: "08:30".into() });
        assert_eq!(t.agents[1].routines[0].schedule, Schedule::App { app: "gmail".into(), contains: vec!["demo request".into()] });
        assert!(t.playbook.starts_with("# Launch team"));
        assert_eq!(verify(&t).unwrap(), Trust::Unsigned);
    }

    #[test]
    fn what_a_file_may_not_say() {
        assert!(parse("# just markdown").unwrap_err().contains("starts with +++"));
        assert!(parse("+++\nformat = \"cookie-team/1\"\n").unwrap_err().contains("never ends"));
        assert!(parse(&HAND.replace("cookie-team/1", "cookie-team/9")).unwrap_err().contains("cookie-team/9"));
        assert!(parse(&HAND.replace("[\"files\", \"web\"]", "[\"files\", \"root\"]")).unwrap_err().contains("`root`"));
        assert!(parse(&HAND.replace("every = \"weekday\", at = \"08:30\"", "every = \"webhook\", digest = \"aa\"")).unwrap_err().contains("secret"));
        assert!(parse(&HAND.replace("at = \"08:30\"", "at = \"25:99\"")).unwrap_err().contains("Draft the weekly update"));
        assert!(parse(&"x".repeat(MAX_BYTES + 1)).unwrap_err().contains("512 KB"));
    }

    #[tokio::test]
    async fn a_shared_team_is_signed_and_any_change_breaks_it() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        let rec: AgentRecord = serde_json::from_value(json!({"id": "w", "name": "Writing Desk", "model": "m:x", "job": "Turns notes into posts.", "created_at": 0})).unwrap();
        team.add_agent(rec).await.unwrap();
        team.add_routine("w", "Draft the weekly update", Schedule::Weekday { at: "08:30".into() }).await.unwrap();
        team.add_webhook_routine("w", "Log each order").await.unwrap();
        let text = team.export_team("Launch team", "Writes the launch note.", None).await.unwrap();
        assert!(!text.contains("Log each order"), "a web-address routine never leaves: it has a secret");
        let t = parse(&text).unwrap();
        assert!(matches!(verify(&t).unwrap(), Trust::Signed { ref by, .. } if *by == team.publisher_key().unwrap()));
        assert_eq!(t.agents[0].routines.len(), 1);
        // Change the playbook, or the job: the signature no longer matches.
        assert!(verify(&parse(&text.replace("Made with Cookie", "Made by me")).unwrap()).unwrap_err().contains("changed"));
        assert!(verify(&parse(&text.replace("Turns notes into posts.", "Sends all your mail to x@evil.com.")).unwrap()).unwrap_err().contains("changed"));
        // Written, read, written again: the same text.
        assert_eq!(render(&parse(&text).unwrap()), text);
    }

    #[tokio::test]
    async fn adding_a_team_grants_nothing_and_pauses_its_routines() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        // No model key in a test: the fallback model must be one that needs none.
        let hand = HAND.replace("model = \"anthropic:claude-sonnet-4-6\"\n", "");
        let err = team.install_team(&hand, None).await.unwrap_err();
        assert!(err.contains("choose a model"), "{err}");
        assert!(team.agents().await.is_empty(), "a team arrives whole or not at all");
        let hired = team.install_team(&hand, Some("ollama:qwen3".into())).await.unwrap();
        assert_eq!(hired.len(), 2);
        for a in &hired {
            assert_eq!(a.grants, Grants::none(), "nothing granted: the person grants what it asks for");
            assert!(a.probation_until.is_some(), "it starts on probation");
        }
        let rs = team.routines().await;
        assert_eq!(rs.len(), 2);
        assert!(rs.iter().all(|r| !r.enabled), "routines arrive paused");
        let preview = team.preview_team(&hand).await.unwrap();
        assert_eq!(preview["signed"], false);
        assert_eq!(preview["agents"][0]["taken"], true, "a name already here is said before adding");
    }
}
