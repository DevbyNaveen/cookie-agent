//! Earned trust: after a person has approved the same `write` tool enough
//! times in a row, it stops asking. One "no" resets it. Tools that send,
//! delete or pay are never earned, whatever the streak.

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

use serde::{Deserialize, Serialize};

use crate::{
    error::{Error, Result},
    tool::Effect,
};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
struct Rung {
    /// Approvals in a row since the last "no".
    streak: usize,
    earned: bool,
}

/// Shared by every agent it is given to; cheap to clone.
#[derive(Debug, Clone)]
pub struct EarnedTrust {
    after: usize,
    path: Option<PathBuf>,
    rungs: Arc<Mutex<BTreeMap<String, Rung>>>,
}

impl EarnedTrust {
    /// Forgotten when the process ends. `after` approvals in a row earn a tool.
    pub fn in_memory(after: usize) -> Self {
        Self { after: after.max(1), path: None, rungs: Arc::default() }
    }

    /// Kept in a JSON file (written on every change, readable, deletable).
    pub fn open(path: impl AsRef<Path>, after: usize) -> Result<Self> {
        let path = path.as_ref().to_path_buf();
        let rungs = match std::fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str(&text).map_err(|e| Error::Session(format!("{}: {e}", path.display())))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
            Err(e) => return Err(e.into()),
        };
        Ok(Self { after: after.max(1), path: Some(path), rungs: Arc::new(Mutex::new(rungs)) })
    }

    pub fn earned(&self, tool: &str) -> bool {
        self.rungs.lock().unwrap().get(tool).is_some_and(|r| r.earned)
    }

    /// Every tool that runs without asking.
    pub fn earned_tools(&self) -> Vec<String> {
        self.rungs.lock().unwrap().iter().filter(|(_, r)| r.earned).map(|(name, _)| name.clone()).collect()
    }

    /// Ask again from now on.
    pub fn revoke(&self, tool: &str) -> Result<()> {
        self.update(tool, |rung| *rung = Rung::default())
    }

    /// A person's answer for `tool`. Only `write` climbs; a "no" resets.
    pub(crate) fn record(&self, tool: &str, effect: Effect, approved: bool) -> Result<()> {
        if effect != Effect::Write {
            return Ok(());
        }
        let after = self.after;
        self.update(tool, |rung| {
            if approved {
                rung.streak += 1;
                rung.earned |= rung.streak >= after;
            } else {
                *rung = Rung::default();
            }
        })
    }

    /// Whether a `write` call may run without asking.
    pub(crate) fn allows(&self, tool: &str, effect: Effect) -> bool {
        effect == Effect::Write && self.earned(tool)
    }

    fn update(&self, tool: &str, change: impl FnOnce(&mut Rung)) -> Result<()> {
        let mut rungs = self.rungs.lock().unwrap();
        change(rungs.entry(tool.to_string()).or_default());
        if let Some(path) = &self.path {
            let tmp = path.with_extension("tmp");
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
        approval::{ApprovalRequest, FnApprover},
        providers::scripted::Scripted,
        tool::{tool, Effect},
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
        let agent = Agent::with_provider(p, "m").tool(page()).tool(note(effect)).earned_trust(trust.clone()).approver(FnApprover(
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
}
