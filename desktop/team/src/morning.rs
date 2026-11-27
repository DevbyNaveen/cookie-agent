//! The morning table: one screen for the whole team, shown first in Cookie's chat.
//!
//! What was done while the person was away (and whether anything outside the
//! agent showed it right), what is waiting for their yes, what is due today,
//! and what the team is carrying on its own: goals, watchers, work queued,
//! work waiting for the Mac. Everything here is read from records; nothing
//! is written by a model to look good.

use serde_json::{json, Value};

use crate::outcome::{end_state, EndState};
use crate::store::{Job, JobStatus, Trigger};
use crate::{util, Team};

impl Team {
    /// The table, for the last `hours` (24 by default).
    pub async fn morning(&self, hours: u64) -> Value {
        let now = util::now();
        let since = now.saturating_sub(hours.max(1) * 3600);
        let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
        let mut done = Vec::new();
        let (mut verified, mut corrected, mut failed, mut unknown, mut dollars) = (0, 0, 0, 0, 0u64);
        let mut due_today = Vec::new();
        let mut queued = 0usize;
        for rec in self.agents().await.into_iter().filter(|a| a.shadow_of.is_none() && !crate::bench::is_probe(&a.id)) {
            let jobs: Vec<Job> = util::read_jsonl(&self.paths.jobs(&rec.id));
            for j in jobs.iter().filter(|j| j.finished_at.unwrap_or(0) >= since && !matches!(j.trigger, Trigger::Test { .. } | Trigger::Shadow { .. } | Trigger::Review | Trigger::Rehearse | Trigger::Prep { .. })) {
                dollars += j.microdollars;
                let state = end_state(j);
                match state {
                    EndState::Verified => verified += 1,
                    EndState::Corrected => corrected += 1,
                    EndState::Failed => failed += 1,
                    EndState::Unknown => unknown += 1,
                }
                // What it did on its own, or anything that didn't end well: the person's own chats they saw.
                let own = !matches!(j.trigger, Trigger::Chat | Trigger::Welcome);
                if own || matches!(state, EndState::Failed) || j.status == JobStatus::NeedsYou {
                    done.push(json!({
                        "agent": rec.id, "name": rec.name, "job": j.id, "end": state.as_str(),
                        "status": j.status, "what": util::clip(&j.input, 160), "said": util::clip(if j.answer.is_empty() { j.error.as_deref().unwrap_or("") } else { &j.answer }, 280),
                        "at": j.finished_at,
                    }));
                }
            }
            for j in &jobs {
                for (i, p) in j.promises.iter().enumerate().filter(|(_, p)| p.state == "open" && p.due <= today) {
                    due_today.push(json!({"agent": rec.id, "name": rec.name, "job": j.id, "index": i, "text": p.text, "due": p.due}));
                }
            }
            queued += self.queued(&rec.id).len();
        }
        done.sort_by_key(|d| std::cmp::Reverse(d["at"].as_u64().unwrap_or(0)));
        let goals: Vec<Value> = self
            .goals()
            .into_iter()
            .filter(|g| g.active() || g.finished_at.unwrap_or(0) >= since || g.status == "out_of_budget")
            .map(|g| json!({"agent": g.agent, "id": g.id, "objective": g.objective, "status": g.status, "progress": util::clip(&g.progress, 240), "next_at": g.next_at, "spent": g.spent_microdollars as f64 / 1e6, "budget": g.budget_dollars}))
            .collect();
        let watchers = self.watchers().into_iter().filter(|w| w.active).count();
        let hits: u32 = self.watchers().iter().filter(|w| w.today.0 == now / 86_400).map(|w| w.today.1).sum();
        json!({
            "hours": hours,
            "done": done.into_iter().take(30).collect::<Vec<_>>(),
            "counts": {"verified": verified, "corrected": corrected, "failed": failed, "unknown": unknown},
            "dollars": dollars as f64 / 1e6,
            "waiting_for_you": self.pending_approvals().len(),
            "due": due_today,
            "goals": goals,
            "watching": watchers,
            "watcher_hits_today": hits,
            "queued": queued,
            "waiting_for_mac": self.parked_calls().len(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn the_table_reads_the_records_as_they_are() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        let m = team.morning(24).await;
        assert_eq!(m["done"].as_array().unwrap().len(), 0);
        assert_eq!(m["counts"]["verified"], 0);
        team.add_goal("a", "keep invoices paid", "none over 14 days", "weekly", Some(5.0), None).unwrap();
        assert_eq!(team.morning(24).await["goals"].as_array().unwrap().len(), 1);
    }
}
