//! Earned trust: after a person has approved the same `write` tool enough
//! times in a row, it stops asking. One "no" resets it. Tools that send,
//! delete or pay are never earned, whatever the streak.

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

use serde::{Deserialize, Serialize};

use sha2::{Digest, Sha256};

use crate::{
    error::{Error, Result},
    tool::{Effect, ToolSpec},
};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
struct Rung {
    /// Approvals in a row since the last "no".
    streak: usize,
    earned: bool,
}

/// Shared by every agent it is given to; cheap to clone. Trust belongs to
/// one tool definition (name, description and schema), so another tool that
/// happens to share a name — say from an MCP server — earns nothing from it.
#[derive(Debug, Clone)]
pub struct EarnedTrust {
    after: usize,
    path: Option<PathBuf>,
    rungs: Arc<Mutex<BTreeMap<String, Rung>>>,
}

/// `name#` and the first 12 hex characters of SHA-256 over the description
/// and schema.
fn key(spec: &ToolSpec) -> String {
    let digest = Sha256::digest(format!("{}\n{}", spec.description, spec.schema).as_bytes());
    let short: String = digest.iter().take(6).map(|b| format!("{b:02x}")).collect();
    format!("{}#{short}", spec.name)
}

fn name_of(key: &str) -> &str {
    key.split('#').next().unwrap_or(key)
}

impl EarnedTrust {
    /// Forgotten when the process ends. `after` approvals in a row earn a tool.
    pub fn in_memory(after: usize) -> Self {
        Self { after: after.max(1), path: None, rungs: Arc::default() }
    }

    /// Kept in a JSON file, re-read on every check so a revoke from another
    /// process stands, and written under a lock so writers don't lose each other.
    pub fn open(path: impl AsRef<Path>, after: usize) -> Result<Self> {
        let trust = Self { after: after.max(1), path: Some(path.as_ref().to_path_buf()), rungs: Arc::default() };
        trust.with_file(false, |_| ())?;
        Ok(trust)
    }

    /// Whether any tool called `tool` has been earned.
    pub fn earned(&self, tool: &str) -> bool {
        self.snapshot().iter().any(|(key, rung)| name_of(key) == tool && rung.earned)
    }

    /// The names of every tool that runs without asking.
    pub fn earned_tools(&self) -> Vec<String> {
        let mut names: Vec<String> = self.snapshot().iter().filter(|(_, r)| r.earned).map(|(k, _)| name_of(k).to_string()).collect();
        names.dedup();
        names
    }

    /// Ask again from now on, for every tool called `tool`.
    pub fn revoke(&self, tool: &str) -> Result<()> {
        self.with_file(true, |rungs| rungs.retain(|key, _| name_of(key) != tool))
    }

    /// A person's answer for this tool. Only `write` climbs; a "no" resets.
    pub(crate) fn record(&self, spec: &ToolSpec, approved: bool) -> Result<()> {
        if spec.effect != Effect::Write {
            return Ok(());
        }
        let (after, key) = (self.after, key(spec));
        self.with_file(true, |rungs| {
            let rung = rungs.entry(key).or_default();
            if approved {
                rung.streak += 1;
                rung.earned |= rung.streak >= after;
            } else {
                *rung = Rung::default();
            }
        })
    }

    /// Whether this `write` call may run without asking.
    pub(crate) fn allows(&self, spec: &ToolSpec) -> bool {
        spec.effect == Effect::Write && self.snapshot().get(&key(spec)).is_some_and(|r| r.earned)
    }

    fn snapshot(&self) -> BTreeMap<String, Rung> {
        match self.with_file(false, |_| ()) {
            Ok(()) => self.rungs.lock().unwrap().clone(),
            // An unreadable file earns nothing.
            Err(_) => BTreeMap::new(),
        }
    }

    /// Run `change` on the latest state: from the file (under its lock) when
    /// there is one; written back when `write`.
    fn with_file(&self, write: bool, change: impl FnOnce(&mut BTreeMap<String, Rung>)) -> Result<()> {
        let mut rungs = self.rungs.lock().unwrap();
        let Some(path) = &self.path else {
            change(&mut rungs);
            return Ok(());
        };
        let lock = std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(path.with_extension("lock"))?;
        if write { lock.lock()? } else { lock.lock_shared()? }
        *rungs = match std::fs::read_to_string(path) {
            Ok(text) if text.trim().is_empty() => BTreeMap::new(),
            Ok(text) => serde_json::from_str(&text).map_err(|e| Error::Session(format!("{}: {e}", path.display())))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
            Err(e) => return Err(e.into()),
        };
        change(&mut rungs);
        if write {
            let tmp = path.with_extension(format!("tmp-{}-{:?}", std::process::id(), std::thread::current().id()));
            std::fs::write(&tmp, serde_json::to_vec_pretty(&*rungs)?)?;
            std::fs::rename(&tmp, path)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        agent::{Agent, Event},
        approval::{ApprovalRequest, FnApprover, PersonApprover},
        providers::scripted::Scripted,
        tool::{tool, Effect, Tool},
        Message, RunControl, Session,
    };
    use serde_json::json;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

    fn page() -> impl crate::tool::Tool {
        tool("read_page", "r", json!({"type": "object"}), Effect::Read, |_| async move { Ok("text".to_string()) })
    }

    fn note(effect: Effect) -> impl crate::tool::Tool {
        tool("save_note", "s", json!({"type": "object"}), effect, |_| async move { Ok("saved".to_string()) })
    }

    /// One run: read a page (untrusted), then save a note — which asks.
    async fn one_run(trust: &EarnedTrust, effect: Effect, answer: bool, asked: Arc<AtomicUsize>) -> Vec<Event> {
        let p = Arc::new(Scripted::new(vec![
            Scripted::call("p", "read_page", json!({})),
            Scripted::call("n", "save_note", json!({"text": "x"})),
            Scripted::text("ok"),
        ]));
        let agent = Agent::with_provider(p, "m").tool(page()).tool(note(effect)).earned_trust(trust.clone()).approver(PersonApprover(
            move |_: &ApprovalRequest| {
                asked.fetch_add(1, Ordering::SeqCst);
                answer
            },
        ));
        let mut events = Vec::new();
        agent.run_streaming(&mut Session::in_memory(), Message::user("go"), &RunControl::default(), &mut |e| events.push(e)).await.unwrap();
        events
    }

    #[tokio::test]
    async fn five_yeses_in_a_row_earn_a_write_tool_and_one_no_resets_it() {
        let trust = EarnedTrust::in_memory(5);
        let asked = Arc::new(AtomicUsize::new(0));
        for answer in [true, true, false, true, true, true, true] {
            one_run(&trust, Effect::Write, answer, asked.clone()).await;
        }
        assert!(!trust.earned("save_note"), "the no reset the streak: only 4 in a row since");
        one_run(&trust, Effect::Write, true, asked.clone()).await;
        assert!(trust.earned("save_note"));
        let before = asked.load(Ordering::SeqCst);
        let events = one_run(&trust, Effect::Write, false, asked.clone()).await;
        assert_eq!(asked.load(Ordering::SeqCst), before, "earned: not asked");
        assert!(events.iter().any(|e| matches!(e, Event::RanOnEarnedTrust { tool } if tool == "save_note")), "and the caller is told");
    }

    #[tokio::test]
    async fn sending_is_never_earned() {
        let trust = EarnedTrust::in_memory(5);
        let asked = Arc::new(AtomicUsize::new(0));
        for _ in 0..8 {
            one_run(&trust, Effect::Outbound, true, asked.clone()).await;
        }
        assert!(!trust.earned("save_note"));
        assert_eq!(asked.load(Ordering::SeqCst), 8, "asked every time");
    }

    #[tokio::test]
    async fn earned_trust_survives_a_restart_and_can_be_revoked() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("trust.json");
        let trust = EarnedTrust::open(&path, 2).unwrap();
        let asked = Arc::new(AtomicUsize::new(0));
        one_run(&trust, Effect::Write, true, asked.clone()).await;
        one_run(&trust, Effect::Write, true, asked.clone()).await;
        let reopened = EarnedTrust::open(&path, 2).unwrap();
        assert!(reopened.earned("save_note"));
        reopened.revoke("save_note").unwrap();
        assert!(!EarnedTrust::open(&path, 2).unwrap().earned("save_note"));
    }

    #[tokio::test]
    async fn a_rule_or_script_never_earns_trust() {
        let trust = EarnedTrust::in_memory(2);
        for _ in 0..4 {
            let p = Arc::new(Scripted::new(vec![
                Scripted::call("p", "read_page", json!({})),
                Scripted::call("n", "save_note", json!({})),
                Scripted::text("ok"),
            ]));
            let agent = Agent::with_provider(p, "m").tool(page()).tool(note(Effect::Write)).earned_trust(trust.clone()).approver(FnApprover(|_: &ApprovalRequest| true));
            agent.run("go").await.unwrap();
        }
        assert!(!trust.earned("save_note"), "only a person's approvals count");
    }

    #[test]
    fn trust_belongs_to_one_tool_definition_not_its_name() {
        let trust = EarnedTrust::in_memory(1);
        let mine = note(Effect::Write);
        let theirs = tool("save_note", "a CRM tool from an MCP server", json!({"type": "object"}), Effect::Write, |_| async move { Ok(String::new()) });
        trust.record(mine.spec(), true).unwrap();
        assert!(trust.allows(mine.spec()));
        assert!(!trust.allows(theirs.spec()), "same name, different tool");
    }

    #[test]
    fn a_revoke_from_another_process_stands_and_writers_do_not_lose_each_other() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("trust.json");
        let a = EarnedTrust::open(&path, 1).unwrap();
        let b = EarnedTrust::open(&path, 1).unwrap();
        let spec = note(Effect::Write).spec().clone();
        a.record(&spec, true).unwrap();
        b.revoke("save_note").unwrap();
        assert!(!a.allows(&spec), "a re-reads the file: b's revoke stands");
        let handles: Vec<_> = (0..8)
            .map(|i| {
                let t = EarnedTrust::open(&path, 1).unwrap();
                let mut s = spec.clone();
                s.name = format!("t{i}");
                std::thread::spawn(move || t.record(&s, true).unwrap())
            })
            .collect();
        handles.into_iter().for_each(|h| h.join().unwrap());
        let all = EarnedTrust::open(&path, 1).unwrap().earned_tools();
        assert_eq!(all.len(), 8, "{all:?}");
    }
}
