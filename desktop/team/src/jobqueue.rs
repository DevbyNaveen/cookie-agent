//! Work for an agent that is busy waits its turn instead of being refused.
//!
//! An agent runs one job at a time (its folder checkpoint, its plan and its
//! stop button belong to that job). Work that arrives meanwhile — a result
//! from the person's Mac, a goal coming due, a promise firing, a teammate's
//! handoff — goes into the agent's own queue, kept on disk so a restart loses
//! none of it, and starts the moment the running job ends. What the person
//! types in the chat is never queued: it steers the running job, as before.

use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::store::Trigger;
use crate::{util, Team};

/// Most jobs one agent may have waiting; past it the oldest is dropped (and said so).
const MOST_WAITING: usize = 200;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Queued {
    pub text: String,
    pub trigger: Trigger,
    pub at: u64,
}

impl Team {
    fn queue_path(&self, agent: &str) -> std::path::PathBuf {
        self.paths.agent(agent).join("queue.jsonl")
    }

    pub fn queued(&self, agent: &str) -> Vec<Queued> {
        util::read_jsonl(&self.queue_path(agent))
    }

    fn save_queue(&self, agent: &str, q: &[Queued]) {
        let body: String = q.iter().filter_map(|x| serde_json::to_string(x).ok()).map(|l| l + "\n").collect();
        let _ = std::fs::create_dir_all(self.paths.agent(agent));
        let _ = std::fs::write(self.queue_path(agent), body);
    }

    fn queue_work(&self, agent: &str, text: String, trigger: Trigger, front: bool) {
        let mut q = self.queued(agent);
        let item = Queued { text, trigger, at: util::now() };
        if front {
            q.insert(0, item);
        } else {
            q.push(item);
        }
        if q.len() > MOST_WAITING {
            let dropped = q.remove(0);
            tracing::warn!("{agent}'s queue is full; dropped work from {}", dropped.at);
        }
        self.save_queue(agent, &q);
    }

    /// Start this work now, or queue it behind the agent's running job.
    /// Returns the job id, or `queued`.
    pub async fn give_work(self: &Arc<Self>, agent: &str, text: String, trigger: Trigger) -> Result<String, String> {
        // Busy with work that can't run beside its own: straight to the queue.
        if self.runs.lock().unwrap().contains_key(agent) && !crate::runtime::runs_beside(&trigger) {
            self.queue_work(agent, text, trigger, false);
            return Ok("queued".into());
        }
        // Free, or work that runs beside the main job while there is room for it.
        match self.start_job(agent, text.clone(), Vec::new(), trigger.clone()).await {
            // Taken between the check and the start: it waits its turn.
            Err(_) if self.runs.lock().unwrap().contains_key(agent) => {
                self.queue_work(agent, text, trigger, false);
                Ok("queued".into())
            }
            other => other,
        }
    }

    /// After a job ends: start the next one waiting, if any.
    pub(crate) fn start_next_queued(self: &Arc<Self>, agent: &str) {
        let mut q = self.queued(agent);
        if q.is_empty() {
            return;
        }
        let next = q.remove(0);
        self.save_queue(agent, &q);
        let (team, agent) = (self.clone(), agent.to_string());
        tokio::spawn(async move {
            match team.start_job(&agent, next.text.clone(), Vec::new(), next.trigger.clone()).await {
                Ok(_) => {}
                // Something else started first: back to the front of the line.
                Err(_) if team.runs.lock().unwrap().contains_key(&agent) => team.queue_work(&agent, next.text, next.trigger, true),
                Err(e) => tracing::warn!("queued work for {agent} couldn't start: {e}"),
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn waiting_work_keeps_its_order_and_survives_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let team = rt.block_on(async { Team::open(dir.path()).unwrap() });
        team.queue_work("a", "first".into(), Trigger::Inbox, false);
        team.queue_work("a", "second".into(), Trigger::Inbox, false);
        team.queue_work("a", "urgent".into(), Trigger::Inbox, true);
        drop(team);
        let again = rt.block_on(async { Team::open(dir.path()).unwrap() });
        let texts: Vec<String> = again.queued("a").into_iter().map(|q| q.text).collect();
        assert_eq!(texts, ["urgent", "first", "second"]);
    }
}
