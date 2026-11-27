//! Goals an agent owns for days or weeks, and promises that come due.
//!
//! A job is one sitting. A goal is the work across many: "no invoice over 14
//! days unpaid", "ship the booking site", "20 qualified leads a week". It
//! holds what done looks like, a progress note the agent keeps (so each
//! sitting starts where the last one stopped, not from a blank page), a budget
//! in dollars, and when to look again. Between sittings nothing runs and
//! nothing is spent: the goal sleeps until its time comes, a watcher it set
//! fires (`watchers`), or the person writes.
//!
//! - **Setting a goal asks the person once**, with its plan and budget: that
//!   one yes covers every sitting after it (the gates on sending, deleting
//!   and paying stay as they are, every time).
//! - **It wakes itself.** Each sitting ends by saying when to look next; with
//!   nothing said, a goal looks again in a day.
//! - **Done is checked, not claimed.** A goal finishes when the agent shows
//!   what meets its "done when"; that sitting's record is marked verified,
//!   so learning counts it (`outcome::end_state`).
//! - **Silent work has its own budget.** Goal sittings never count against
//!   the person's interruptions (attention's daily cap): they are bounded by
//!   the goal's dollars and a guard on sittings a day.
//! - **Promises fire.** "I'll check Friday whether Acme paid" was kept on the
//!   job's record; on Friday morning its agent is woken to keep it.

use std::sync::Arc;
use std::time::Duration;

use cookie_harness::tool::{tool, Effect, Tool};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::store::{Job, Trigger};
use crate::{util, Team};

pub const SET_TOOL: &str = "set_goal";
/// How often goals and promises are looked at.
const TICK: Duration = Duration::from_secs(30);
/// A goal whose sitting said nothing about when to look again: a day.
const DEFAULT_NEXT: u64 = 86_400;
/// Sittings one goal may have in a day: a guard against a goal that wakes itself in a loop.
const SITTINGS_A_DAY: u32 = 48;
/// The soonest a goal may ask to be looked at again.
const SOONEST: u64 = 60;
/// Promises fire at this hour (UTC) of the day they are due.
const PROMISE_HOUR_UTC: u64 = 8;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Goal {
    pub id: String,
    pub agent: String,
    pub objective: String,
    /// What shows it is met, checkable by someone other than the agent.
    pub done_when: String,
    /// The plan the person said yes to.
    #[serde(default)]
    pub plan: String,
    /// Where the work stands, in the agent's words: read at the start of every sitting.
    #[serde(default)]
    pub progress: String,
    /// `active`, `done`, `stopped`, `out_of_budget`.
    pub status: String,
    pub budget_dollars: Option<f64>,
    #[serde(default)]
    pub spent_microdollars: u64,
    pub created_at: u64,
    /// When it looks next (seconds since the epoch); none while a watcher or the person is awaited.
    pub next_at: Option<u64>,
    /// Why it looks then, as the agent said it.
    #[serde(default)]
    pub next_why: String,
    #[serde(default)]
    pub sittings: Vec<String>,
    /// Sittings today, and the day (days since the epoch) they were counted on.
    #[serde(default)]
    pub today: (u64, u32),
    #[serde(default)]
    pub finished_at: Option<u64>,
    /// What showed it met, when done.
    #[serde(default)]
    pub evidence: String,
}

impl Goal {
    pub fn active(&self) -> bool {
        self.status == "active"
    }

    fn over_budget(&self) -> bool {
        self.budget_dollars.is_some_and(|b| self.spent_microdollars as f64 / 1e6 >= b)
    }
}

impl Team {
    fn goals_path(&self) -> std::path::PathBuf {
        self.paths.root.join("goals.json")
    }

    pub fn goals(&self) -> Vec<Goal> {
        util::read_json(&self.goals_path())
    }

    pub fn goals_of(&self, agent: &str) -> Vec<Goal> {
        self.goals().into_iter().filter(|g| g.agent == agent).collect()
    }

    fn edit_goals<T>(&self, f: impl FnOnce(&mut Vec<Goal>) -> T) -> Result<T, String> {
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _g = LOCK.lock().unwrap();
        let mut all = self.goals();
        let out = f(&mut all);
        util::write_json(&self.goals_path(), &all)?;
        Ok(out)
    }

    pub fn add_goal(&self, agent: &str, objective: &str, done_when: &str, plan: &str, budget: Option<f64>, first_at: Option<u64>) -> Result<Goal, String> {
        let (objective, done_when) = (objective.trim(), done_when.trim());
        if objective.is_empty() || done_when.is_empty() {
            return Err("A goal needs what it is for and what shows it is done.".into());
        }
        let g = Goal {
            id: util::new_id("goal"),
            agent: agent.into(),
            objective: util::clip(objective, 600),
            done_when: util::clip(done_when, 600),
            plan: util::clip(plan, 4000),
            status: "active".into(),
            budget_dollars: budget.filter(|b| b.is_finite() && *b > 0.0),
            created_at: util::now(),
            next_at: Some(first_at.unwrap_or_else(util::now)),
            next_why: "its first sitting".into(),
            ..Goal::default()
        };
        self.edit_goals(|all| all.push(g.clone()))?;
        Ok(g)
    }

    /// The person stops a goal, or starts it again.
    pub fn set_goal_status(&self, id: &str, status: &str) -> Result<(), String> {
        if !matches!(status, "active" | "stopped") {
            return Err("A goal is active or stopped.".into());
        }
        self.edit_goals(|all| {
            let g = all.iter_mut().find(|g| g.id == id).ok_or("No such goal.")?;
            g.status = status.into();
            if status == "active" && g.next_at.is_none() {
                g.next_at = Some(util::now());
            }
            Ok::<_, String>(())
        })?
    }

    /// A watcher of this goal's agent fired: the goal looks now.
    pub(crate) fn wake_goal_now(&self, id: &str, why: &str) {
        let _ = self.edit_goals(|all| {
            if let Some(g) = all.iter_mut().find(|g| g.id == id && g.active()) {
                g.next_at = Some(util::now());
                g.next_why = util::clip(why, 300);
            }
        });
    }

    /// What a goal's sitting is told: the goal, its plan, where it stands, why now.
    fn sitting_text(g: &Goal) -> String {
        let budget = match g.budget_dollars {
            Some(b) => format!("${:.2} of ${b:.2} spent", g.spent_microdollars as f64 / 1e6),
            None => format!("${:.2} spent", g.spent_microdollars as f64 / 1e6),
        };
        format!(
            "A goal you own, sitting {n}. Work on it now, as far as you can get in this sitting.\n\n\
             Goal: {obj}\nDone when: {done}\n{plan}Where it stands (your own note from last time): {progress}\nWhy now: {why}\nBudget: {budget}\n\n\
             Before you finish this sitting, call goal_progress with an updated note (what you did, what's next, what you're waiting for) \
             and when to look next; or goal_done with what shows it is met. Anything that would send, delete or pay still asks the person.",
            n = g.sittings.len() + 1,
            obj = g.objective,
            done = g.done_when,
            plan = if g.plan.is_empty() { String::new() } else { format!("Plan the person agreed: {}\n", g.plan) },
            progress = if g.progress.is_empty() { "(first sitting: nothing yet)".to_string() } else { g.progress.clone() },
            why = g.next_why,
        )
    }

    /// Goals and promises that are due, started. Called every `TICK`.
    pub(crate) async fn tick_goals(self: &Arc<Self>) {
        let now = util::now();
        let today = now / 86_400;
        let due: Vec<Goal> = self.goals().into_iter().filter(|g| g.active() && g.next_at.is_some_and(|t| t <= now)).collect();
        for g in due {
            if self.is_asleep(&g.agent) {
                continue;
            }
            if g.over_budget() {
                let _ = self.edit_goals(|all| {
                    if let Some(x) = all.iter_mut().find(|x| x.id == g.id) {
                        x.status = "out_of_budget".into();
                    }
                });
                self.notice(&g.agent, "A goal reached its budget", &format!("“{}” stopped at its budget. Raise it to go on.", util::clip(&g.objective, 120)), None, true);
                continue;
            }
            let sittings_today = if g.today.0 == today { g.today.1 } else { 0 };
            if sittings_today >= SITTINGS_A_DAY {
                let _ = self.edit_goals(|all| {
                    if let Some(x) = all.iter_mut().find(|x| x.id == g.id) {
                        x.next_at = Some((today + 1) * 86_400);
                        x.next_why = "it had as many sittings as a day allows".into();
                    }
                });
                continue;
            }
            // Claimed before it starts, so the next tick doesn't start it twice; the sitting sets the next time.
            let _ = self.edit_goals(|all| {
                if let Some(x) = all.iter_mut().find(|x| x.id == g.id) {
                    x.next_at = Some(now + DEFAULT_NEXT);
                    x.next_why = "a day passed since the last sitting".into();
                    x.today = (today, sittings_today + 1);
                }
            });
            match self.give_work(&g.agent, Self::sitting_text(&g), Trigger::Goal { goal: g.id.clone() }).await {
                Ok(_) => {}
                Err(e) => tracing::warn!("goal {} couldn't start: {e}", g.id),
            }
        }
        self.fire_promises(now).await;
    }

    /// Promises whose day has come: their agent is woken to keep them, once.
    async fn fire_promises(self: &Arc<Self>, now: u64) {
        for rec in self.agents().await {
            let jobs: Vec<Job> = util::read_jsonl(&self.paths.jobs(&rec.id));
            for job in jobs.iter().filter(|j| j.promises.iter().any(|p| p.state == "open" && !p.fired)) {
                for (i, p) in job.promises.iter().enumerate().filter(|(_, p)| p.state == "open" && !p.fired) {
                    let Some(at) = due_at(&p.due) else { continue };
                    if at > now {
                        continue;
                    }
                    let marked = self.edit_job(&rec.id, &job.id, |j| {
                        if let Some(x) = j.promises.get_mut(i) {
                            x.fired = true;
                        }
                    });
                    if marked.is_err() {
                        continue;
                    }
                    let text = format!(
                        "You promised the person, on {}: “{}” It is due today ({}). Keep it now: do it, or tell them plainly why you can't. \
                         The work it was about: {}",
                        crate::routines::local_time(job.started_at),
                        p.text,
                        p.due,
                        util::clip(&job.input, 400)
                    );
                    let _ = self.give_work(&rec.id, text, Trigger::Promise { job: job.id.clone(), index: i }).await;
                }
            }
        }
    }

    /// After a goal's sitting: what it cost, and its record.
    pub(crate) fn after_goal_sitting(&self, goal: &str, job: &Job) {
        let _ = self.edit_goals(|all| {
            if let Some(g) = all.iter_mut().find(|g| g.id == goal) {
                g.spent_microdollars += job.microdollars;
                g.sittings.push(job.id.clone());
                if g.sittings.len() > 500 {
                    g.sittings.remove(0);
                }
            }
        });
    }
}

/// Jobs shown right while they were still running (a goal met), waiting for their record.
fn verified() -> &'static std::sync::Mutex<std::collections::HashMap<String, String>> {
    static V: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, String>>> = std::sync::OnceLock::new();
    V.get_or_init(Default::default)
}

pub(crate) fn mark_verified(job: &str, by: &str) {
    verified().lock().unwrap().insert(job.to_string(), by.to_string());
}

/// What showed `job` right, for its record, once.
pub(crate) fn take_verified(job: &str) -> Option<String> {
    verified().lock().unwrap().remove(job)
}

/// When a promise due on `day` (YYYY-MM-DD, UTC) fires.
fn due_at(day: &str) -> Option<u64> {
    let d = chrono::NaiveDate::parse_from_str(day.trim(), "%Y-%m-%d").ok()?;
    let midnight = d.and_hms_opt(0, 0, 0)?.and_utc().timestamp();
    (midnight >= 0).then(|| midnight as u64 + PROMISE_HOUR_UTC * 3600)
}

/// Looks at goals and promises every `TICK`, for as long as the team runs.
pub(crate) fn spawn(team: Arc<Team>) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(TICK);
        loop {
            tick.tick().await;
            team.tick_goals().await;
        }
    });
}

/// When to look next, from what a sitting said: `in_minutes`, `at` (YYYY-MM-DD HH:MM, local), or nothing (a day).
fn next_of(args: &Value, now: u64) -> Result<Option<u64>, String> {
    if args["wait_for_watcher"].as_bool().unwrap_or(false) {
        return Ok(None);
    }
    if let Some(m) = args["in_minutes"].as_u64() {
        return Ok(Some(now + (m * 60).max(SOONEST)));
    }
    if let Some(at) = args["at"].as_str().filter(|s| !s.trim().is_empty()) {
        let t = chrono::NaiveDateTime::parse_from_str(at.trim(), "%Y-%m-%d %H:%M").map_err(|_| "Say `at` as YYYY-MM-DD HH:MM.".to_string())?;
        let local = t.and_local_timezone(chrono::Local).earliest().ok_or("That time doesn't exist here.")?;
        return Ok(Some((local.timestamp().max(0) as u64).max(now + SOONEST)));
    }
    Ok(Some(now + DEFAULT_NEXT))
}

/// The goal tools for one job: setting one (asks the person), and, in a goal's sitting, keeping its note and finishing it.
pub(crate) fn tools(team: &Arc<Team>, agent: &str, trigger: &Trigger, job: &str) -> Vec<Arc<dyn Tool>> {
    let mut out: Vec<Arc<dyn Tool>> = Vec::new();
    let (w, a) = (Arc::downgrade(team), agent.to_string());
    out.push(Arc::new(
        tool(
            SET_TOOL,
            "Take on a goal you will own for days or weeks: something to keep true or get done, not one task. You work on it in \
             sittings that wake themselves; between them nothing runs. Asks the person once, with your plan and budget; that yes \
             covers the sittings (sending, deleting and paying still ask every time). Use it when the person hands you an outcome \
             (\"keep my invoices paid\", \"get the site live\"), not for something you can finish now.",
            json!({"type": "object", "properties": {
                "objective": {"type": "string"},
                "done_when": {"type": "string", "description": "what shows it is met, checkable by someone else: 'every invoice older than 14 days is paid or has a reminder sent'"},
                "plan": {"type": "string", "description": "how you'll go about it, in a few lines"},
                "budget_dollars": {"type": "number", "description": "the most all its sittings together may spend"},
                "start_in_minutes": {"type": "integer", "minimum": 0}
            }, "required": ["objective", "done_when", "plan"]}),
            Effect::Write,
            move |args: Value| {
                let (w, a) = (w.clone(), a.clone());
                async move {
                    let team = w.upgrade().ok_or("Cookie is closing.")?;
                    let first = args["start_in_minutes"].as_u64().map(|m| util::now() + m * 60);
                    let g = team.add_goal(&a, args["objective"].as_str().unwrap_or(""), args["done_when"].as_str().unwrap_or(""), args["plan"].as_str().unwrap_or(""), args["budget_dollars"].as_f64(), first)?;
                    Ok(format!("Goal set ({}). Its first sitting starts {}.", g.id, if first.is_some() { "when you said" } else { "after this job" }))
                }
            },
        )
        .with_preview(|args| {
            format!(
                "Own a goal: {}\nDone when: {}\nPlan:\n{}\nBudget: {}",
                args["objective"].as_str().unwrap_or(""),
                args["done_when"].as_str().unwrap_or(""),
                args["plan"].as_str().unwrap_or(""),
                args["budget_dollars"].as_f64().map(|b| format!("${b:.2}")).unwrap_or_else(|| "its per-job limits".into())
            )
        }),
    ));
    let Trigger::Goal { goal } = trigger else { return out };
    let (w, g, j) = (Arc::downgrade(team), goal.clone(), job.to_string());
    out.push(Arc::new(tool(
        "goal_progress",
        "End this sitting of your goal: your updated note (what you did, what's next, what you're waiting for, any numbers that matter) and when \
         to look again: in_minutes, at (YYYY-MM-DD HH:MM), or wait_for_watcher when one of your watchers will wake you.",
        json!({"type": "object", "properties": {
            "note": {"type": "string"},
            "in_minutes": {"type": "integer", "minimum": 1},
            "at": {"type": "string"},
            "wait_for_watcher": {"type": "boolean"},
            "why": {"type": "string", "description": "why then, in a few words"}
        }, "required": ["note"]}),
        Effect::Write,
        move |args: Value| {
            let (w, g) = (w.clone(), g.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                let next = next_of(&args, util::now())?;
                let note = args["note"].as_str().unwrap_or("").trim().to_string();
                if note.is_empty() {
                    return Err("Write where it stands.".into());
                }
                team.edit_goals(|all| {
                    let x = all.iter_mut().find(|x| x.id == g).ok_or("No such goal.")?;
                    x.progress = util::clip(&note, 6000);
                    x.next_at = next;
                    x.next_why = util::clip(args["why"].as_str().unwrap_or(if next.is_none() { "a watcher fired" } else { "the time it set" }), 300);
                    Ok::<_, String>(())
                })??;
                Ok(match next {
                    Some(t) => format!("Noted. It looks again {}.", crate::routines::local_time(t)),
                    None => "Noted. It waits for a watcher.".into(),
                })
            }
        },
    )));
    let (w, g) = (Arc::downgrade(team), goal.clone());
    out.push(Arc::new(tool(
        "goal_done",
        "Finish your goal: what shows it meets its 'done when' (the evidence, with where it is), checked the way it says.",
        json!({"type": "object", "properties": {"evidence": {"type": "string"}}, "required": ["evidence"]}),
        Effect::Write,
        move |args: Value| {
            let (w, g, j) = (w.clone(), g.clone(), j.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                let evidence = args["evidence"].as_str().unwrap_or("").trim().to_string();
                if evidence.len() < 20 {
                    return Err("Show what meets it: the evidence and where it is.".into());
                }
                // A goal code can check is checked by code: the agent's word doesn't finish it.
                let owner = team.goals().into_iter().find(|x| x.id == g).map(|x| x.agent).unwrap_or_default();
                let evidence = match crate::specialists::invoices_goal_met(&team, &owner) {
                    Some(false) => return Err("Your ledger still shows invoices breaking the goal (invoices_check). It isn't done.".into()),
                    Some(true) => format!("Checked against the ledger: none breaks it. {evidence}"),
                    None => evidence,
                };
                let agent = team.edit_goals(|all| {
                    let x = all.iter_mut().find(|x| x.id == g).ok_or("No such goal.")?;
                    x.status = "done".into();
                    x.finished_at = Some(util::now());
                    x.next_at = None;
                    x.evidence = util::clip(&evidence, 3000);
                    Ok::<_, String>(x.agent.clone())
                })??;
                mark_verified(&j, &format!("goal met: {}", util::clip(&evidence, 160)));
                team.notice(&agent, "A goal is done", &util::clip(&evidence, 300), None, false);
                Ok("Done. The person will see the evidence.".into())
            }
        },
    )));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sitting_says_when_to_look_next() {
        let now = 1_800_000_000;
        assert_eq!(next_of(&json!({}), now).unwrap(), Some(now + DEFAULT_NEXT));
        assert_eq!(next_of(&json!({"in_minutes": 30}), now).unwrap(), Some(now + 1800));
        assert_eq!(next_of(&json!({"in_minutes": 0}), now).unwrap(), Some(now + SOONEST), "never sooner than a minute");
        assert_eq!(next_of(&json!({"wait_for_watcher": true}), now).unwrap(), None);
        assert!(next_of(&json!({"at": "friday"}), now).is_err());
    }

    #[test]
    fn a_promise_fires_on_its_morning() {
        assert_eq!(due_at("2026-11-27"), Some(1_795_737_600 + 8 * 3600));
        assert_eq!(due_at("someday"), None);
    }

    #[tokio::test]
    async fn a_due_goal_starts_once_and_a_spent_one_stops() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        let g = team.add_goal("nobody", "keep invoices paid", "none older than 14 days unpaid", "check weekly", Some(1.0), None).unwrap();
        team.tick_goals().await;
        let after = team.goals().into_iter().find(|x| x.id == g.id).unwrap();
        assert!(after.next_at.unwrap() > util::now() + 3600, "claimed: not started again on the next tick");
        assert_eq!(after.today.1, 1);
        team.edit_goals(|all| {
            all[0].spent_microdollars = 2_000_000;
            all[0].next_at = Some(0);
        })
        .unwrap();
        team.tick_goals().await;
        assert_eq!(team.goals()[0].status, "out_of_budget");
    }
}
