//! Rehearsal: a job tried first, for real, with nothing done.
//!
//! The agent works as it would (its instructions, its tools, its rules, the
//! conversation it was asked in), reading what it needs, but every change it
//! would make (a send, a draft, a payment, a calendar event, a file) is
//! recorded instead of made, and it carries on to the end of its plan
//! (`cookie_harness::approval::Approver::rehearses`). The person sees, in the
//! chat, each action it would take with its receipt (why it was allowed,
//! which values came from content they didn't write) and says go or not.
//! Go runs the same request for real, where each action still asks as usual.

use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::events::TeamEvent;
use crate::store::{JobStatus, Trigger};
use crate::{util, Team};

/// One change a rehearsal would have made.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Would {
    pub did: String,
    pub tool: String,
    pub effect: String,
    pub because: String,
    pub from_data: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Rehearsal {
    pub id: String,
    pub agent: String,
    pub job: String,
    pub request: String,
    pub at: u64,
    /// Where it sits in the agent's chat.
    pub after_message: usize,
    /// `running`, `done` or `failed`.
    pub state: String,
    pub would: Vec<Would>,
    /// What it said it would do.
    pub answer: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// The job it became when the person said go.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ran_as: Option<String>,
}

impl Team {
    fn rehearsals_path(&self, agent: &str) -> std::path::PathBuf {
        self.paths.agent(agent).join("rehearsals.jsonl")
    }

    /// Every rehearsal of an agent, latest version of each, oldest first.
    pub fn rehearsals(&self, agent: &str) -> Vec<Rehearsal> {
        let mut by: Vec<Rehearsal> = Vec::new();
        for r in util::read_jsonl::<Rehearsal>(&self.rehearsals_path(agent)) {
            match by.iter_mut().find(|x| x.id == r.id) {
                Some(x) => *x = r,
                None => by.push(r),
            }
        }
        by
    }

    fn save_rehearsal(&self, r: &Rehearsal) {
        let _ = util::append_jsonl(&self.rehearsals_path(&r.agent), r);
        self.emit(TeamEvent::Rehearsal { agent: r.agent.clone(), id: r.id.clone(), state: r.state.clone() });
    }

    /// Rehearse `text` on `agent`: returns the rehearsal's id at once; it runs in the background.
    pub async fn rehearse(self: &Arc<Self>, agent: &str, text: String) -> Result<String, String> {
        let rec = self.agent(agent).await?;
        let text = text.trim().to_string();
        if text.is_empty() {
            return Err("Say what to rehearse.".into());
        }
        if self.busy().iter().any(|(a, _)| a == &rec.id) {
            return Err(format!("{} is working. Rehearse when it's free.", rec.name));
        }
        let r = Rehearsal {
            id: util::new_id("rehearsal"),
            agent: rec.id.clone(),
            request: util::clip(&text, 4000),
            at: util::now(),
            after_message: self.session_len(&rec.id).await,
            state: "running".into(),
            ..Rehearsal::default()
        };
        self.save_rehearsal(&r);
        let (team, id) = (self.clone(), r.id.clone());
        tokio::spawn(async move {
            let mut r = r;
            match team.run_and_wait(&r.agent.clone(), text, Vec::new(), Trigger::Rehearse).await {
                Ok(job) => {
                    r.job = job.id.clone();
                    r.answer = util::clip(&job.answer, 6000);
                    r.state = if job.status == JobStatus::Done { "done".into() } else { "failed".into() };
                    r.error = job.error.clone();
                    r.would = job
                        .receipts
                        .iter()
                        .filter(|x| x.receipt.outcome == "rehearsed")
                        .map(|x| Would {
                            did: x.did.clone(),
                            tool: x.receipt.tool.clone(),
                            effect: serde_json::to_value(x.receipt.effect).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default(),
                            because: x.because_line(),
                            from_data: x.receipt.from_data.clone(),
                        })
                        .collect();
                }
                Err(e) => {
                    r.state = "failed".into();
                    r.error = Some(e);
                }
            }
            team.save_rehearsal(&r);
        });
        Ok(id)
    }

    /// The person said go: the same request, for real (each action still asks as usual).
    pub async fn rehearsal_go(self: &Arc<Self>, agent: &str, id: &str) -> Result<String, String> {
        let mut r = self.rehearsals(agent).into_iter().find(|r| r.id == id).ok_or("No such rehearsal.")?;
        if r.state != "done" {
            return Err("That rehearsal didn't finish.".into());
        }
        if let Some(j) = &r.ran_as {
            return Err(format!("It already ran for real (job {j})."));
        }
        let job = self.start_job(agent, r.request.clone(), Vec::new(), Trigger::Chat).await?;
        r.ran_as = Some(job.clone());
        self.save_rehearsal(&r);
        Ok(job)
    }
}
