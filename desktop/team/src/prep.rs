//! Agents that prepare while idle.
//!
//! With "Prepare ahead" on (its Evolution tab; off by default, as each prep is
//! a job), an agent with nothing to do and a routine due in the next half hour
//! prepares for it: it looks up what the routine will need — its memory, the
//! pages and files it used before — and writes a short brief. The prep runs in
//! record mode: anything it would send, post, change or delete is recorded
//! and refused, never done. When the routine starts, the brief rides in its
//! job note, so the routine begins from what was found instead of from
//! nothing. One prep per routine turn; a brief older than two hours is not used.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::store::Trigger;
use crate::{util, Team};

/// How far ahead of a routine an idle agent prepares.
pub const AHEAD: u64 = 30 * 60;
/// A brief older than this is stale.
pub const FRESH: u64 = 2 * 3600;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Brief {
    /// The routine turn it prepared for (epoch s).
    pub due: u64,
    pub text: String,
    pub at: u64,
    pub job: String,
}

pub fn prep_text(task: &str, minutes: u64) -> String {
    format!(
        "In about {minutes} minutes you will do this routine:\n\"{task}\"\n\n\
         Prepare for it now, while you are free: look up what it will need (what you know, the pages and files it used before, \
         anything that changed since), and write a short brief: what you found, and what to check or decide when the routine runs. \
         Do not send, post, change or delete anything now; that waits for the routine itself."
    )
}

impl Team {
    fn briefs_path(&self, agent: &str) -> std::path::PathBuf {
        self.paths.agent(agent).join("prep.json")
    }

    fn briefs(&self, agent: &str) -> BTreeMap<String, Brief> {
        util::read_json(&self.briefs_path(agent))
    }

    /// The brief for a routine turn starting now, if one was prepared and is fresh.
    pub(crate) fn brief_for(&self, agent: &str, routine: &str) -> Option<String> {
        let b = self.briefs(agent).remove(routine)?;
        (util::now().saturating_sub(b.at) < FRESH && !b.text.trim().is_empty()).then(|| format!("You prepared for this routine earlier, while idle. Your brief (check it is still true):\n{}", util::clip(&b.text, 4_000)))
    }

    /// On the minute tick: idle agents with "Prepare ahead" get ready for routines due soon.
    pub(crate) async fn maybe_prepare(self: &Arc<Self>) {
        let now = util::now();
        let routines = self.routines.read().await.clone();
        let busy: Vec<String> = self.busy().into_iter().map(|(a, _)| a).collect();
        for r in routines.iter().filter(|r| r.enabled) {
            let Some(due) = r.next_run.filter(|t| *t > now && *t - now <= AHEAD) else { continue };
            if busy.contains(&r.agent) || self.is_asleep(&r.agent) || !self.tuning(&r.agent).prepare {
                continue;
            }
            if self.briefs(&r.agent).get(&r.id).is_some_and(|b| b.due == due) {
                continue; // already prepared for this turn
            }
            // Claimed before it starts, so the next tick doesn't start it again.
            let mut all = self.briefs(&r.agent);
            all.insert(r.id.clone(), Brief { due, at: now, ..Brief::default() });
            let _ = util::write_json(&self.briefs_path(&r.agent), &all);
            let (team, agent, routine, task) = (self.clone(), r.agent.clone(), r.id.clone(), r.task.clone());
            let minutes = (due - now).div_ceil(60);
            tokio::spawn(async move {
                let job = team.run_and_wait(&agent, prep_text(&task, minutes), Vec::new(), Trigger::Prep { routine: routine.clone() }).await;
                let mut all = team.briefs(&agent);
                if let Ok(j) = job {
                    all.insert(routine, Brief { due, text: j.answer, at: util::now(), job: j.id });
                    let _ = util::write_json(&team.briefs_path(&agent), &all);
                }
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fresh_brief_rides_with_its_routine_and_a_stale_one_does_not() {
        let dir = tempfile::tempdir().unwrap();
        let t = Team::open(dir.path()).unwrap();
        let mut all = BTreeMap::new();
        all.insert("r1".to_string(), Brief { due: 1, text: "Three new invoices.".into(), at: util::now(), job: "j".into() });
        all.insert("r2".to_string(), Brief { due: 1, text: "old".into(), at: util::now() - FRESH - 10, job: "j".into() });
        util::write_json(&t.briefs_path("a"), &all).unwrap();
        assert!(t.brief_for("a", "r1").unwrap().contains("Three new invoices."));
        assert!(t.brief_for("a", "r2").is_none());
        assert!(prep_text("Clean my inbox", 20).contains("Do not send"));
    }
}
