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
        // A standing yes the person gave for exactly this kind of send (`mandates`): no card, a receipt.
        if self.mode == Mode::Ask {
            if let Some(m) = team.use_mandate(&self.agent, req) {
                self.log.lock().unwrap().push(ApprovalRecord {
                    tool: req.tool.clone(),
                    effect: effect_name(req.effect).into(),
                    preview: util::clip(&format!("Under mandate {} ({}; {} of {} used): {}", m.id, m.why, m.used, m.max_uses, req.preview), 2000),
                    outcome: "yes".into(),
                    checker: None,
                });
                return true;
            }
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
        // Nobody there: after the wait the person chose, the request counts as a no and the
        // job moves on, so one unanswered card can't hold an agent (and its routines) for days.
        // The harness counts it as the person's no, which is the careful side: it earns no trust.
        let wait = team.settings.read().await.approval_wait_minutes;
        let mut unanswered = false;
        let yes = if wait > 0 {
            match tokio::time::timeout(std::time::Duration::from_secs(wait as u64 * 60), rx).await {
                Ok(answer) => answer.unwrap_or(false),
                Err(_) => {
                    unanswered = true;
                    false
                }
            }
        } else {
            rx.await.unwrap_or(false)
        };
        if unanswered {
            if team.pending.lock().unwrap().remove(&id).is_some() {
                team.emit(TeamEvent::Answered { id: id.clone(), agent: self.agent.clone(), yes: false, by: "timeout".into() });
            }
            team.notice(
                &self.agent,
                &format!("{} went on without your yes", self.agent_name),
                &format!("Nobody answered in {wait} minutes, so this did not happen: {}", util::clip(&req.preview, 160)),
                Some(&self.job),
                true,
            );
        }
        std::mem::forget(guard); // answered or timed out: nothing to clean up
        self.log.lock().unwrap().push(ApprovalRecord {
            tool: req.tool.clone(),
            effect: effect_name(req.effect).into(),
            preview: util::clip(&req.preview, 2000),
            outcome: if yes { "yes" } else if unanswered { "unanswered" } else { "no" }.into(),
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

/// News another agent wanted to tell the person, waiting for Cookie's next digest.
struct Held {
    agent: String,
    title: String,
    body: String,
    job: Option<String>,
}

/// Held news, per team (by its folder).
fn digest() -> &'static Mutex<std::collections::HashMap<std::path::PathBuf, Vec<Held>>> {
    static D: std::sync::OnceLock<Mutex<std::collections::HashMap<std::path::PathBuf, Vec<Held>>>> = std::sync::OnceLock::new();
    D.get_or_init(Default::default)
}

/// Held news this many items deep goes out at once; otherwise every `DIGEST_EVERY`.
const DIGEST_FULL: usize = 6;
pub(crate) const DIGEST_EVERY: std::time::Duration = std::time::Duration::from_secs(30 * 60);

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
            if book.dismissed.get(agent).copied().unwrap_or(0) >= 3 {
                return;
            }
            // Only Cookie speaks to the person unprompted: another agent's news is held and Cookie
            // brings it as one digest (`flush_digest`). A request for a yes comes straight from the
            // agent, because a job is waiting on it.
            if agent != crate::front::COOKIE_ID {
                drop(book);
                let mut all = digest().lock().unwrap();
                let held = all.entry(self.paths.root.clone()).or_default();
                held.push(Held { agent: agent.to_string(), title: title.to_string(), body: body.to_string(), job: job.map(str::to_string) });
                let full = held.len() >= DIGEST_FULL;
                drop(all);
                if full {
                    self.flush_digest();
                }
                return;
            }
            if book.shown >= cap {
                return;
            }
            book.shown += 1;
        }
        drop(book);
        self.emit(TeamEvent::Notice { agent: agent.to_string(), title: title.to_string(), body: body.to_string(), job: job.map(str::to_string) });
    }

    /// Cookie brings the team's held news as one notice, within the day's budget.
    pub(crate) fn flush_digest(&self) {
        let held: Vec<Held> = digest().lock().unwrap().remove(&self.paths.root).unwrap_or_default();
        if held.is_empty() {
            return;
        }
        let names: std::collections::HashMap<String, String> = self.agents.try_read().map(|a| a.iter().map(|r| (r.id.clone(), r.name.clone())).collect()).unwrap_or_default();
        let name = |id: &str| names.get(id).cloned().unwrap_or_else(|| id.to_string());
        let (title, body, job) = if held.len() == 1 {
            let h = &held[0];
            (format!("{}: {}", name(&h.agent), h.title), h.body.clone(), h.job.clone())
        } else {
            let lines: Vec<String> = held.iter().take(8).map(|h| format!("{}: {}", name(&h.agent), h.title)).collect();
            let more = if held.len() > 8 { format!("\n…and {} more", held.len() - 8) } else { String::new() };
            (format!("News from your team ({})", held.len()), lines.join("\n") + &more, None)
        };
        let cap = self.settings.try_read().map(|s| s.daily_notices).unwrap_or(cookie_harness::attention::DAILY_CAP);
        let mut book = self.notices.lock().unwrap();
        let today = chrono::Local::now().format("%Y-%m-%d").to_string();
        if book.day != today {
            book.day = today;
            book.shown = 0;
        }
        if book.shown >= cap {
            return;
        }
        book.shown += 1;
        drop(book);
        self.emit(TeamEvent::Notice { agent: crate::front::COOKIE_ID.into(), title, body, job });
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

#[cfg(test)]
mod digest_tests {
    use super::*;

    #[tokio::test]
    async fn only_cookie_interrupts_the_rest_arrives_as_one_digest() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        let mut rx = team.subscribe();
        team.notice("invoice-chaser", "Acme paid", "Invoice 12 is paid.", None, false);
        team.notice("leads", "3 new leads", "From the form.", None, false);
        assert!(rx.try_recv().is_err(), "held: no other agent interrupts");
        team.notice("leads", "needs your yes", "Send it?", Some("job-1"), true);
        assert!(matches!(rx.try_recv(), Ok(TeamEvent::Notice { agent, .. }) if agent == "leads"), "a yes comes straight from the agent");
        team.flush_digest();
        match rx.try_recv() {
            Ok(TeamEvent::Notice { agent, title, body, .. }) => {
                assert_eq!(agent, crate::front::COOKIE_ID);
                assert!(title.contains("News from your team (2)"), "{title}");
                assert!(body.contains("Acme paid") && body.contains("3 new leads"), "{body}");
            }
            other => panic!("{other:?}"),
        }
        team.flush_digest();
        assert!(rx.try_recv().is_err(), "nothing held: nothing said");
    }
}
