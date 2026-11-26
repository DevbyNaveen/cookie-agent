//! What each agent knows, and where it lives.
//!
//! With Enkeon (signed in with the Enkeon CLI, or `ENKEON_API_KEY`), every
//! agent has its own space, `cookie-agent-<id>`. The harness holds it there:
//! the model is never offered a space to choose, so text it reads can't steer
//! it into another agent's memory. Its recall reads its own space plus `main`
//! (the person's general material, shared by every agent); never another
//! agent's. Each memory it saves is written to a ledger in its folder, so the
//! person can see, correct and erase exactly what this agent kept, and firing
//! it erases them from Enkeon too (retried later if Enkeon can't be reached).
//!
//! Without Enkeon, the agent keeps one-line notes in its own `NOTES.md`.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;

use cookie_harness::enkeon::{Enkeon, SavedMemory};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{util, Team};

/// The agent's own Enkeon space. `cookie-agent-` keeps clear of the person's own
/// spaces (they may already have `cookie`, `cookie-harness`…); the id is unique.
pub fn space_of(agent: &str) -> String {
    let clean: String = agent.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c.to_ascii_lowercase() } else { '-' }).collect();
    format!("cookie-agent-{clean}")
}

/// One memory the agent saved, as written in its ledger.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Kept {
    pub id: String,
    pub text: String,
    #[serde(default)]
    pub kind: Option<String>,
    /// The memory this one replaced (a newer version of it).
    #[serde(default)]
    pub updates: Option<String>,
    pub at: u64,
    /// `agent` (in a job), `review` (its learning pass) or `you`.
    pub by: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct MemoryView {
    /// `enkeon`, `local` or `off` (the agent has no memory permission).
    pub mode: String,
    /// The Enkeon space, or the notes file.
    pub place: String,
    pub items: Vec<MemoryItem>,
    /// Erasures still waiting for Enkeon to answer.
    pub pending_erase: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct MemoryItem {
    /// What forget and edit take: the Enkeon memory id, or the note itself.
    pub id: String,
    pub text: String,
    pub kind: Option<String>,
    pub at: Option<u64>,
    pub by: Option<String>,
    /// How many earlier versions it replaced.
    pub versions: usize,
}

/// A recall result for "what does it know about…": its own memories and the shared ones.
#[derive(Debug, Clone, Serialize)]
pub struct Recalled {
    pub text: String,
    pub kind: Option<String>,
    /// Saved by this agent (its space), or the person's shared material (`main` or above).
    pub mine: bool,
    /// The memory id when it is this agent's (so it can be edited or forgotten).
    pub id: Option<String>,
    /// Enkeon's check that it still matches its source.
    pub proof: Option<String>,
    pub added_at: Option<String>,
}

fn ledger(team: &Team, agent: &str) -> PathBuf {
    team.paths.agent(agent).join("memories.jsonl")
}

fn pending_file(team: &Team) -> PathBuf {
    team.paths.root.join("erase-pending.json")
}

fn enkeon() -> Option<Enkeon> {
    crate::pair::enkeon()
}

/// The same, for examples and live tests.
pub async fn enkeon_call_pub(tool: &str, args: Value) -> Result<String, String> {
    call(tool, args).await
}

/// An Enkeon tool, called by the host (not by a model): `brain` primes and records with it.
pub(crate) async fn enkeon_call(tool: &str, args: Value) -> Result<String, String> {
    call(tool, args).await
}

/// One open connection to Enkeon for the host's own calls, kept across calls (a new one per call
/// costs a handshake and the session brief), and dropped when the pairing changes or it fails.
static CLIENT: std::sync::LazyLock<tokio::sync::Mutex<Option<(String, Arc<cookie_harness::mcp::McpClient>)>>> = std::sync::LazyLock::new(|| tokio::sync::Mutex::new(None));

async fn client() -> Result<Arc<cookie_harness::mcp::McpClient>, String> {
    let who = crate::pair::gateway_and_key().map(|(g, k)| format!("{g}|{}", &k[..k.len().min(12)])).unwrap_or_default();
    let mut g = CLIENT.lock().await;
    if let Some((w, c)) = g.as_ref() {
        if *w == who {
            return Ok(c.clone());
        }
    }
    let e = enkeon().ok_or("Enkeon isn't connected on this computer.")?;
    let c = Arc::new(e.client().await.map_err(|e| format!("Couldn't reach Enkeon: {e}"))?);
    *g = Some((who, c.clone()));
    Ok(c)
}

/// The text of an Enkeon tool reply, or why it failed. A brain busy with a background pass is retried a few times.
async fn call(tool: &str, args: Value) -> Result<String, String> {
    let mut last = String::new();
    for attempt in 0..4u64 {
        let c = client().await?;
        match tokio::time::timeout(std::time::Duration::from_secs(20), c.call_tool(tool, args.clone())).await {
            Err(_) => return Err("Enkeon didn't answer in 20 seconds.".into()),
            Ok(Ok((text, false))) => return Ok(text),
            Ok(Ok((text, true))) => return Err(text),
            Ok(Err(e)) => {
                last = e.to_string();
                if last.contains("busy") {
                    tokio::time::sleep(std::time::Duration::from_millis(300 * (attempt + 1))).await;
                    continue;
                }
                // A dropped connection: a fresh one next time.
                *CLIENT.lock().await = None;
                if attempt == 0 {
                    continue;
                }
                return Err(last);
            }
        }
    }
    Err(last)
}

impl Team {
    /// Enkeon for this agent: its own space, and every save written to its ledger.
    /// `own_web`: the agent has Cookie's own web search, so Enkeon's isn't offered too.
    pub(crate) fn enkeon_for(&self, agent: &str, by: &'static str, own_web: bool) -> Option<Enkeon> {
        let file = ledger(self, agent);
        let on_saved = Arc::new(move |m: SavedMemory| {
            let _ = util::append_jsonl(&file, &Kept { id: m.id, text: m.text, kind: m.kind, updates: m.updates, at: util::now(), by: by.into() });
        });
        // The spaces it follows: its recall may read one by name (`brain`); it still files only into its own.
        let follows = self.followed(agent);
        enkeon().map(|e| {
            let e = e.space(&space_of(agent)).also_read(follows).on_saved(on_saved);
            if own_web { e.without("web_search") } else { e }
        })
    }

    /// A memory the harness saved for this agent: in its ledger, so the person sees it and erasing the agent erases it.
    pub(crate) fn note_kept(&self, agent: &str, id: &str, text: &str, kind: Option<&str>, by: &str) {
        let _ = util::append_jsonl(&ledger(self, agent), &Kept { id: id.into(), text: text.into(), kind: kind.map(str::to_string), updates: None, at: util::now(), by: by.into() });
    }

    fn kept(&self, agent: &str) -> Vec<Kept> {
        util::read_jsonl(&ledger(self, agent))
    }

    /// What this agent knows, newest first; a corrected memory shows once, as its latest version.
    pub async fn memory(&self, agent: &str) -> Result<MemoryView, String> {
        let rec = self.agent(agent).await?;
        let pending_erase = util::read_json::<Vec<String>>(&pending_file(self)).len();
        if !rec.grants.memory {
            return Ok(MemoryView { mode: "off".into(), place: String::new(), items: vec![], pending_erase });
        }
        if enkeon().is_none() {
            let path = self.paths.notes(agent);
            let items = cookie_harness::notes::load(&path)
                .into_iter()
                .rev()
                .map(|n| MemoryItem { id: n.clone(), text: n, kind: None, at: None, by: None, versions: 0 })
                .collect();
            return Ok(MemoryView { mode: "local".into(), place: path.to_string_lossy().into(), items, pending_erase });
        }
        let kept = self.kept(agent);
        let replaced: HashSet<&str> = kept.iter().filter_map(|k| k.updates.as_deref()).collect();
        let versions = |k: &Kept| {
            let mut n = 0;
            let mut at = k.updates.clone();
            while let Some(prev) = at {
                n += 1;
                at = kept.iter().find(|p| p.id == prev).and_then(|p| p.updates.clone());
                if n > 50 { break; }
            }
            n
        };
        let mut items: Vec<MemoryItem> = kept
            .iter()
            .filter(|k| !replaced.contains(k.id.as_str()))
            .map(|k| MemoryItem { id: k.id.clone(), text: k.text.clone(), kind: k.kind.clone(), at: Some(k.at), by: Some(k.by.clone()), versions: versions(k) })
            .collect();
        items.reverse();
        Ok(MemoryView { mode: "enkeon".into(), place: space_of(agent), items, pending_erase })
    }

    /// What the agent would recall about `query`: its own memories and the person's shared ones.
    pub async fn memory_search(&self, agent: &str, query: &str) -> Result<Vec<Recalled>, String> {
        let rec = self.agent(agent).await?;
        let query = query.trim();
        if query.is_empty() {
            return Ok(vec![]);
        }
        if !rec.grants.memory {
            return Err("This agent has no memory.".into());
        }
        if enkeon().is_none() {
            let words: Vec<String> = query.to_lowercase().split_whitespace().map(str::to_string).collect();
            return Ok(cookie_harness::notes::load(&self.paths.notes(agent))
                .into_iter()
                .filter(|n| { let l = n.to_lowercase(); words.iter().any(|w| l.contains(w.as_str())) })
                .map(|n| Recalled { id: Some(n.clone()), text: n, kind: None, mine: true, proof: None, added_at: None })
                .collect());
        }
        let space = space_of(agent);
        let reply = call(
            "recall",
            json!({"query": query, "branch": space, "top_k": 12, "budget_tokens": 0, "proof": true,
                   "since": null, "until": null, "type": null, "state": null, "workspace": null, "as_of": null, "check": null, "folder": null}),
        )
        .await?;
        // The JSON comes first; Enkeon may add a note after it (who else is working, say).
        let start = reply.find('{').ok_or("Enkeon's answer wasn't readable.")?;
        let body: Value = serde_json::Deserializer::from_str(&reply[start..])
            .into_iter::<Value>()
            .next()
            .and_then(Result::ok)
            .ok_or("Enkeon's answer wasn't readable.")?;
        let marker = format!("/branch/{space}/");
        Ok(body["hits"]
            .as_array()
            .map(|hits| {
                hits.iter()
                    .map(|h| {
                        let uri = h["source_uri"].as_str().unwrap_or_default();
                        let mine = uri.contains(&marker);
                        Recalled {
                            text: h["statement"].as_str().unwrap_or_default().to_string(),
                            kind: h["claim_type"].as_str().map(|k| k.to_lowercase()),
                            mine,
                            id: mine.then(|| uri.rsplit('/').next().unwrap_or_default().to_string()).filter(|i| !i.is_empty()),
                            proof: h["proof"]["state"].as_str().map(str::to_string),
                            added_at: h["added_at"].as_str().map(str::to_string),
                        }
                    })
                    .collect()
            })
            .unwrap_or_default())
    }

    /// Teach the agent something directly.
    pub async fn memory_add(&self, agent: &str, text: &str) -> Result<MemoryView, String> {
        let rec = self.agent(agent).await?;
        let text = text.trim();
        if text.is_empty() {
            return Err("Say what it should know.".into());
        }
        if !rec.grants.memory {
            return Err("Turn on its memory first (its profile, About).".into());
        }
        if enkeon().is_none() {
            cookie_harness::notes::add(&self.paths.notes(agent), text, None)?;
        } else {
            let reply = call("remember", remember_args(agent, text, None, None, "The person told this agent directly, in Cookie.")).await?;
            let id = cookie_harness::enkeon::saved_id(&reply).ok_or_else(|| format!("Enkeon didn't keep it: {reply}"))?;
            util::append_jsonl(&ledger(self, agent), &Kept { id, text: text.into(), kind: None, updates: None, at: util::now(), by: "you".into() })?;
        }
        self.memory(agent).await
    }

    /// Correct a memory: Enkeon keeps the old words as history, the agent recalls the new ones.
    pub async fn memory_edit(&self, agent: &str, id: &str, text: &str) -> Result<MemoryView, String> {
        let text = text.trim();
        if text.is_empty() {
            return self.memory_forget(agent, id).await;
        }
        if enkeon().is_none() {
            cookie_harness::notes::add(&self.paths.notes(agent), text, Some(id))?;
            return self.memory(agent).await;
        }
        let kept = self.kept(agent);
        let old = kept.iter().find(|k| k.id == id).ok_or("That isn't one of this agent's memories.")?;
        let reply = call("remember", remember_args(agent, text, old.kind.as_deref(), Some(id), "The person corrected what this agent knew, in Cookie.")).await?;
        let new = cookie_harness::enkeon::saved_id(&reply).ok_or_else(|| format!("Enkeon didn't keep it: {reply}"))?;
        util::append_jsonl(&ledger(self, agent), &Kept { id: new, text: text.into(), kind: old.kind.clone(), updates: Some(id.into()), at: util::now(), by: "you".into() })?;
        self.memory(agent).await
    }

    /// Erase a memory for good (with its earlier versions).
    pub async fn memory_forget(&self, agent: &str, id: &str) -> Result<MemoryView, String> {
        if enkeon().is_none() {
            cookie_harness::notes::remove(&self.paths.notes(agent), id)?;
            return self.memory(agent).await;
        }
        let kept = self.kept(agent);
        if !kept.iter().any(|k| k.id == id) {
            return Err("That isn't one of this agent's memories.".into());
        }
        // The memory and every version it replaced.
        let mut chain = vec![id.to_string()];
        let mut at = kept.iter().find(|k| k.id == id).and_then(|k| k.updates.clone());
        while let Some(prev) = at {
            if chain.contains(&prev) { break; }
            chain.push(prev.clone());
            at = kept.iter().find(|k| k.id == prev).and_then(|k| k.updates.clone());
        }
        for m in &chain {
            call("forget", json!({"id": m, "workspace": null})).await?;
        }
        let rest: Vec<&Kept> = kept.iter().filter(|k| !chain.contains(&k.id)).collect();
        rewrite(&ledger(self, agent), &rest)?;
        self.memory(agent).await
    }

    /// When an agent is fired: erase everything it kept in Enkeon, and its space.
    /// What can't be erased now waits in a list and is retried at the next start.
    pub(crate) async fn erase_memory_of(&self, agent: &str) -> (usize, usize) {
        // Retired: its space stays for a successor (`brain::succeed`).
        if crate::brain::keeps_space(agent) {
            return (0, 0);
        }
        let ids: Vec<String> = self.kept(agent).into_iter().map(|k| k.id).collect();
        if enkeon().is_none() {
            return (0, ids.len());
        }
        let (mut done, mut left) = (0, Vec::new());
        for id in ids {
            match call("forget", json!({"id": id, "workspace": null})).await {
                Ok(_) => done += 1,
                Err(_) => left.push(id),
            }
        }
        // Whatever else is filed only in its space (written by another tool, or missing from the ledger):
        // forgotten too, because deleting a space moves what is only there back to `main`.
        let (swept, unswept) = self.forget_space(&space_of(agent)).await;
        done += swept;
        left.extend(unswept);
        if left.is_empty() {
            let _ = call("delete_branch", json!({"branch": space_of(agent), "workspace": null})).await;
        }
        let n = left.len();
        if n > 0 {
            let mut pending: Vec<String> = util::read_json(&pending_file(self));
            pending.extend(left);
            let _ = util::write_json(&pending_file(self), &pending);
        }
        (done, n)
    }

    /// Retry erasures that couldn't reach Enkeon when an agent was fired.
    pub(crate) async fn retry_erasures(&self) {
        let pending: Vec<String> = util::read_json(&pending_file(self));
        if pending.is_empty() || enkeon().is_none() {
            return;
        }
        let mut left = Vec::new();
        for id in pending {
            if call("forget", json!({"id": id, "workspace": null})).await.is_err() {
                left.push(id);
            }
        }
        let _ = if left.is_empty() { std::fs::remove_file(pending_file(self)).map_err(|e| e.to_string()) } else { util::write_json(&pending_file(self), &left) };
    }
}

fn remember_args(agent: &str, text: &str, kind: Option<&str>, updates: Option<&str>, purpose: &str) -> Value {
    json!({
        "text": text, "purpose": purpose, "kind": kind, "weight": null, "feeling": null, "about": null, "name": null,
        "updates": updates, "branch": space_of(agent), "due": null, "to": null, "owner": null, "resources": null,
        "depends_on": null, "acceptance": null
    })
}

fn rewrite(path: &std::path::Path, rows: &[&Kept]) -> Result<(), String> {
    let mut out = String::new();
    for r in rows {
        out.push_str(&serde_json::to_string(r).map_err(|e| e.to_string())?);
        out.push('\n');
    }
    let tmp = path.with_extension("jsonl.tmp");
    std::fs::write(&tmp, out).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_agent_gets_its_own_space_clear_of_the_persons() {
        assert_eq!(space_of("writing-desk-a1b2"), "cookie-agent-writing-desk-a1b2");
        assert_ne!(space_of("harness"), "cookie-harness", "never one of the person's own spaces");
        assert_eq!(space_of("Pip/../x"), "cookie-agent-pip----x");
    }
}
