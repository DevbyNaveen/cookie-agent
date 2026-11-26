//! One place to say yes. Every agent's actions that need a person land here,
//! whatever started the job (chat, a routine, Telegram, another person's
//! agent); every surface shows the same request and any of them can answer.
//!
//! Probation and shadow runs never ask: what they would have done is
//! recorded and refused, so a new hire proves itself before it changes
//! anything. A second model (the checker, from another provider) reads every
//! send before you see it; its note rides on the card, your yes decides.

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use cookie_harness::approval::{ApprovalRequest, Approver};
use cookie_harness::tool::Effect;
use tokio::sync::oneshot;

use crate::events::{Approval, TeamEvent};
use crate::store::ApprovalRecord;
use crate::{util, Team};

pub(crate) struct Pending {
    pub(crate) approval: Approval,
    answer: oneshot::Sender<bool>,
}

/// How a job's approver behaves.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Mode {
    /// Ask the person (approvals inbox, Telegram, the chat card).
    Ask,
    /// Record what it would do, refuse it (probation, shadow, tests).
    Record,
    /// A rehearsal: every change it would make is recorded and shown, none is
    /// made, and it carries on to the end of its plan (`twin::rehearsal`).
    Rehearse,
}

/// The approver a job's agent asks.
pub(crate) struct Broker {
    pub(crate) team: std::sync::Weak<Team>,
    pub(crate) agent: String,
    pub(crate) agent_name: String,
    pub(crate) job: String,
    pub(crate) mode: Mode,
    /// What this job asked, for its record.
    pub(crate) log: Arc<Mutex<Vec<ApprovalRecord>>>,
}

fn effect_name(e: Effect) -> &'static str {
    match e {
        Effect::Read => "read",
        Effect::Write => "write",
        Effect::Outbound => "outbound",
        Effect::Destroy => "destroy",
    }
}

/// Takes a pending request out of the book if its job is dropped (stopped,
/// failed) before anyone answered, so no card is left waiting on nothing.
struct Forget<'a> {
    team: &'a Team,
    id: String,
}

impl Drop for Forget<'_> {
    fn drop(&mut self) {
        if self.team.pending.lock().unwrap().remove(&self.id).is_some() {
            self.team.emit(TeamEvent::Answered { id: self.id.clone(), agent: String::new(), yes: false, by: "stopped".into() });
        }
    }
}

#[async_trait]
impl Approver for Broker {
    fn rehearses(&self) -> bool {
        self.mode == Mode::Rehearse
    }

    async fn rehearse(&self, req: &ApprovalRequest) {
        let Some(team) = self.team.upgrade() else { return };
        self.log.lock().unwrap().push(ApprovalRecord {
            tool: req.tool.clone(),
            effect: effect_name(req.effect).into(),
            preview: util::clip(&req.preview, 2000),
            outcome: "rehearsed".into(),
            checker: None,
        });
        team.emit(TeamEvent::Would { job: self.job.clone(), agent: self.agent.clone(), tool: req.tool.clone(), preview: util::clip(&req.preview, 600) });
    }

    async fn approve(&self, req: &ApprovalRequest) -> bool {
        let Some(team) = self.team.upgrade() else { return false };
        // Your agents write to each other freely; what each one then does still asks you.
        if self.mode == Mode::Ask && req.tool == "message" && req.preview.starts_with(crate::talk::TO_TEAMMATE) {
            return true;
        }
        if self.mode == Mode::Record {
            self.log.lock().unwrap().push(ApprovalRecord {
                tool: req.tool.clone(),
                effect: effect_name(req.effect).into(),
                preview: util::clip(&req.preview, 2000),
                outcome: "would".into(),
                checker: None,
            });
            team.emit(TeamEvent::Would { job: self.job.clone(), agent: self.agent.clone(), tool: req.tool.clone(), preview: util::clip(&req.preview, 600) });
            return false;
        }
        let checker = if matches!(req.effect, Effect::Outbound | Effect::Destroy) {
            crate::checker::check(&team, &self.agent_name, req).await
        } else {
            None
        };
        let id = util::new_id("ask");
        let approval = Approval {
            id: id.clone(),
            agent: self.agent.clone(),
            agent_name: self.agent_name.clone(),
            job: self.job.clone(),
            tool: req.tool.clone(),
            effect: effect_name(req.effect).into(),
            preview: util::clip(&req.preview, 4000),
            reason: req.reason.clone(),
            from_data: req.from_data.clone(),
            checker: checker.clone(),
            asked_at: util::now(),
        };
        let (tx, rx) = oneshot::channel();
        team.pending.lock().unwrap().insert(id.clone(), Pending { approval: approval.clone(), answer: tx });
        let guard = Forget { team: &team, id: id.clone() };
        team.emit(TeamEvent::Asked { approval: approval.clone() });
        team.notice(&self.agent, &format!("{} needs your yes", self.agent_name), &util::clip(&req.preview, 200), Some(&self.job), true);
        let yes = rx.await.unwrap_or(false);
        std::mem::forget(guard); // answered: nothing to clean up
        self.log.lock().unwrap().push(ApprovalRecord {
            tool: req.tool.clone(),
            effect: effect_name(req.effect).into(),
            preview: util::clip(&req.preview, 2000),
            outcome: if yes { "yes" } else { "no" }.into(),
            checker: checker.map(|c| format!("{}: {}", c.verdict, c.note)),
        });
        yes
    }

    fn is_person(&self) -> bool {
        self.mode == Mode::Ask
    }
}

impl Team {
    /// Everything waiting for a yes, oldest first.
    pub fn pending_approvals(&self) -> Vec<Approval> {
        let mut v: Vec<Approval> = self.pending.lock().unwrap().values().map(|p| p.approval.clone()).collect();
        v.sort_by_key(|a| a.asked_at);
        v
    }

    /// Answer a request. `by` names the surface (window, telegram, runner).
    pub fn answer(&self, id: &str, yes: bool, by: &str) -> Result<(), String> {
        let p = self.pending.lock().unwrap().remove(id).ok_or("That request was already answered or its job ended.")?;
        let agent = p.approval.agent.clone();
        let _ = p.answer.send(yes);
        self.emit(TeamEvent::Answered { id: id.to_string(), agent, yes, by: by.to_string() });
        Ok(())
    }
}

/* ---------- attention: interruptions within a daily budget ---------- */

/// What was shown today, and which agents the person keeps dismissing.
#[derive(Default)]
pub(crate) struct NoticeBook {
    day: String,
    shown: i64,
    /// Agent → dismissals in a row; three and its routine news waits for you to open it.
    dismissed: std::collections::HashMap<String, u32>,
}

impl Team {
    /// Tell the person something, within the day's budget. Requests for a yes
    /// (`urgent`) always get through: a job is waiting on them.
    pub(crate) fn notice(&self, agent: &str, title: &str, body: &str, job: Option<&str>, urgent: bool) {
        let cap = self.settings.try_read().map(|s| s.daily_notices).unwrap_or(cookie_harness::attention::DAILY_CAP);
        let mut book = self.notices.lock().unwrap();
        let today = chrono::Local::now().format("%Y-%m-%d").to_string();
        if book.day != today {
            book.day = today;
            book.shown = 0;
        }
        if !urgent {
            if book.shown >= cap || book.dismissed.get(agent).copied().unwrap_or(0) >= 3 {
                return;
            }
            book.shown += 1;
        }
        drop(book);
        self.emit(TeamEvent::Notice { agent: agent.to_string(), title: title.to_string(), body: body.to_string(), job: job.map(str::to_string) });
    }

    /// The person waved a notice away (or opened it: that resets the count).
    pub fn notice_feedback(&self, agent: &str, dismissed: bool) {
        let mut book = self.notices.lock().unwrap();
        if dismissed {
            *book.dismissed.entry(agent.to_string()).or_default() += 1;
        } else {
            book.dismissed.remove(agent);
        }
    }
}
