//! Real specialists: an agent earns its place with its own data, its own
//! tools and an outcome that can be counted, not with a narrower job text.
//!
//! **Invoice chaser** is the first. It keeps a ledger of the person's invoices
//! (its own data: who, how much, due when, where it stands). Each invoice
//! email that arrives starts it (a routine on the person's mail), and it
//! records what it read. It owns one standing goal, "no invoice more than 14
//! days overdue without a reminder", and that goal's done is checked by code
//! against the ledger, never by the agent's word. Reminders are drafts or
//! sends that ask the person as always (or go under a mandate the person
//! gave for exactly those people). Making an agent the specialist is the
//! person's act, from its desk.

use std::sync::Arc;

use cookie_harness::tool::{tool, Effect, Tool};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::store::Schedule;
use crate::{util, Team};

pub const INVOICES: &str = "invoices";
/// Days past due before an invoice must have been chased.
pub const OVERDUE_DAYS: i64 = 14;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Invoice {
    pub id: String,
    /// Who owes it (or who is owed, for a bill to pay).
    pub who: String,
    #[serde(default)]
    pub email: String,
    pub amount: f64,
    #[serde(default)]
    pub currency: String,
    /// YYYY-MM-DD.
    pub due: String,
    /// `open`, `reminded`, `paid`, `disputed`, `written_off`.
    pub status: String,
    #[serde(default)]
    pub reminded_at: Option<u64>,
    #[serde(default)]
    pub notes: String,
    pub updated_at: u64,
}

fn ledger_path(team: &Team, agent: &str) -> std::path::PathBuf {
    team.paths.agent(agent).join("invoices.json")
}

/// The specialists each agent is, by id.
fn roster_path(team: &Team) -> std::path::PathBuf {
    team.paths.root.join("specialists.json")
}

/// Days an invoice is past its due date at `today` (negative: not due yet).
fn days_over(due: &str, today: chrono::NaiveDate) -> Option<i64> {
    let d = chrono::NaiveDate::parse_from_str(due.trim(), "%Y-%m-%d").ok()?;
    Some((today - d).num_days())
}

/// The invoices that break the goal: open, and more than `OVERDUE_DAYS` past due with no reminder since they fell due.
pub fn breaking(ledger: &[Invoice], today: chrono::NaiveDate) -> Vec<&Invoice> {
    ledger
        .iter()
        .filter(|i| i.status == "open" || i.status == "reminded")
        .filter(|i| days_over(&i.due, today).is_some_and(|d| d > OVERDUE_DAYS))
        .filter(|i| {
            let due_at = chrono::NaiveDate::parse_from_str(&i.due, "%Y-%m-%d").ok().and_then(|d| d.and_hms_opt(0, 0, 0)).map(|t| t.and_utc().timestamp().max(0) as u64);
            !(i.status == "reminded" && i.reminded_at.zip(due_at).is_some_and(|(r, d)| r >= d))
        })
        .collect()
}

impl Team {
    pub fn invoices(&self, agent: &str) -> Vec<Invoice> {
        util::read_json(&ledger_path(self, agent))
    }

    fn save_invoices(&self, agent: &str, all: &[Invoice]) -> Result<(), String> {
        util::write_json(&ledger_path(self, agent), &all)
    }

    pub fn specialty(&self, agent: &str) -> Option<String> {
        let m: std::collections::BTreeMap<String, String> = util::read_json(&roster_path(self));
        m.get(agent).cloned()
    }

    /// The person makes an agent the invoice chaser: its ledger, its routine on their mail, its goal.
    pub async fn make_invoice_chaser(&self, agent: &str, budget_dollars: Option<f64>) -> Result<Value, String> {
        let rec = self.agent(agent).await?;
        let mut grants = rec.grants.clone();
        grants.apps = true;
        grants.memory = true;
        grants.routines = true;
        self.update(agent, crate::Patch { grants: Some(grants), ..Default::default() }).await?;
        let mut m: std::collections::BTreeMap<String, String> = util::read_json(&roster_path(self));
        m.insert(agent.to_string(), INVOICES.into());
        util::write_json(&roster_path(self), &m)?;
        if !ledger_path(self, agent).exists() {
            self.save_invoices(agent, &[])?;
        }
        let have = self.routines_of(agent).await;
        let routine = match have.iter().find(|r| matches!(&r.schedule, Schedule::App { contains, .. } if contains.iter().any(|c| c == "invoice"))) {
            Some(r) => r.id.clone(),
            None => {
                self.add_routine(
                    agent,
                    "An email that mentions an invoice arrived. Read it (invoices_record takes what it says: who, how much, due when, and whether it is paid) and record it in your ledger. Don't reply to anyone.",
                    Schedule::App { app: "gmail".into(), contains: vec!["invoice".into()] },
                )
                .await?
                .id
            }
        };
        let goal = match self.goals_of(agent).into_iter().find(|g| g.active() && g.objective.contains("overdue")) {
            Some(g) => g.id,
            None => {
                self.add_goal(
                    agent,
                    &format!("No invoice more than {OVERDUE_DAYS} days overdue without a reminder"),
                    &format!("invoices_check finds no open invoice more than {OVERDUE_DAYS} days past due that hasn't been reminded since it fell due"),
                    "Each sitting: invoices_check; for each one it names, draft a short, polite reminder to the email on record and put it to the person (or send under their mandate); mark it reminded; for one paid, mark it paid. Then look again in a week, or sooner when one is close.",
                    budget_dollars.or(Some(10.0)),
                    None,
                )?
                .id
            }
        };
        Ok(json!({"agent": agent, "specialty": INVOICES, "routine": routine, "goal": goal}))
    }
}

/// The ledger tools for an agent that is the invoice chaser.
pub(crate) fn tools(team: &Arc<Team>, agent: &str) -> Vec<Arc<dyn Tool>> {
    if team.specialty(agent).as_deref() != Some(INVOICES) {
        return Vec::new();
    }
    let (w1, a1) = (Arc::downgrade(team), agent.to_string());
    let check = tool(
        "invoices_check",
        &format!("Your invoice ledger: every invoice, and which ones break your goal (open, more than {OVERDUE_DAYS} days past due, not reminded since)."),
        json!({"type": "object", "properties": {}}),
        Effect::Read,
        move |_a: Value| {
            let (w, a) = (w1.clone(), a1.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                let all = team.invoices(&a);
                let today = chrono::Utc::now().date_naive();
                let bad: Vec<&Invoice> = breaking(&all, today);
                Ok(json!({"invoices": all, "breaking_the_goal": bad, "goal_met": bad.is_empty()}).to_string())
            }
        },
    );
    let (w2, a2) = (Arc::downgrade(team), agent.to_string());
    let record = tool(
        "invoices_record",
        "Add an invoice to your ledger, or change one (by its id): who, email, amount, currency, due (YYYY-MM-DD), status (open, reminded, paid, disputed, written_off), notes. Marking it reminded records when.",
        json!({"type": "object", "properties": {
            "id": {"type": "string", "description": "to change one; leave out to add"},
            "who": {"type": "string"}, "email": {"type": "string"}, "amount": {"type": "number"}, "currency": {"type": "string"},
            "due": {"type": "string"}, "status": {"type": "string", "enum": ["open", "reminded", "paid", "disputed", "written_off"]}, "notes": {"type": "string"}
        }}),
        Effect::Write,
        move |args: Value| {
            let (w, a) = (w2.clone(), a2.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                let mut all = team.invoices(&a);
                if let Some(due) = args["due"].as_str() {
                    chrono::NaiveDate::parse_from_str(due.trim(), "%Y-%m-%d").map_err(|_| "Give `due` as YYYY-MM-DD.".to_string())?;
                }
                let now = util::now();
                let id = match args["id"].as_str().filter(|s| !s.is_empty()) {
                    Some(id) => {
                        let i = all.iter_mut().find(|i| i.id == id).ok_or("No invoice with that id.")?;
                        for (k, f) in [("who", &mut i.who), ("email", &mut i.email), ("currency", &mut i.currency), ("due", &mut i.due), ("notes", &mut i.notes)] {
                            if let Some(v) = args[k].as_str() {
                                *f = util::clip(v.trim(), 400);
                            }
                        }
                        if let Some(v) = args["amount"].as_f64() {
                            i.amount = v;
                        }
                        if let Some(s) = args["status"].as_str() {
                            if s == "reminded" {
                                i.reminded_at = Some(now);
                            }
                            i.status = s.into();
                        }
                        i.updated_at = now;
                        id.to_string()
                    }
                    None => {
                        let (who, due) = (args["who"].as_str().unwrap_or("").trim(), args["due"].as_str().unwrap_or("").trim());
                        if who.is_empty() || due.is_empty() {
                            return Err("A new invoice needs who and due.".into());
                        }
                        let status = args["status"].as_str().unwrap_or("open").to_string();
                        let inv = Invoice {
                            id: util::new_id("inv"),
                            who: util::clip(who, 200),
                            email: args["email"].as_str().unwrap_or("").trim().to_string(),
                            amount: args["amount"].as_f64().unwrap_or(0.0),
                            currency: args["currency"].as_str().unwrap_or("").to_string(),
                            due: due.to_string(),
                            reminded_at: (status == "reminded").then_some(now),
                            status,
                            notes: util::clip(args["notes"].as_str().unwrap_or(""), 400),
                            updated_at: now,
                        };
                        let id = inv.id.clone();
                        all.push(inv);
                        id
                    }
                };
                team.save_invoices(&a, &all)?;
                Ok(format!("Recorded ({id})."))
            }
        },
    );
    vec![Arc::new(check), Arc::new(record)]
}

/// For the invoice chaser's goal: whether the ledger shows it met, checked by code (`goals`).
pub(crate) fn invoices_goal_met(team: &Team, agent: &str) -> Option<bool> {
    (team.specialty(agent).as_deref() == Some(INVOICES)).then(|| breaking(&team.invoices(agent), chrono::Utc::now().date_naive()).is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inv(due: &str, status: &str, reminded_at: Option<u64>) -> Invoice {
        Invoice { id: due.into(), who: "Acme".into(), due: due.into(), status: status.into(), reminded_at, amount: 100.0, ..Default::default() }
    }

    #[test]
    fn the_goal_is_counted_from_the_ledger() {
        let today = chrono::NaiveDate::from_ymd_opt(2026, 11, 28).unwrap();
        let after_due = chrono::NaiveDate::from_ymd_opt(2026, 11, 2).unwrap().and_hms_opt(9, 0, 0).unwrap().and_utc().timestamp() as u64;
        let ledger = vec![
            inv("2026-11-01", "open", None),               // 27 days over, never chased: breaks it
            inv("2026-11-01", "reminded", Some(after_due)), // chased after it fell due: fine
            inv("2026-11-20", "open", None),               // 8 days over: not yet
            inv("2026-10-01", "paid", None),               // paid: fine
        ];
        let bad = breaking(&ledger, today);
        assert_eq!(bad.len(), 1);
        assert_eq!(bad[0].status, "open");
    }

    #[tokio::test]
    async fn making_an_agent_the_chaser_gives_it_data_a_routine_a_goal_and_its_tools() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        team.add_agent(crate::AgentRecord {
            id: "ic".into(), name: "Invoice Chaser".into(), model: "anthropic:x".into(), job: "chase invoices".into(), created_at: 0,
            grants: crate::store::Grants::none(), limits: Default::default(), probation_until: None, parent: None, shadow_of: None, handover: None, origin: None, version: 1,
        })
        .await
        .unwrap();
        assert!(tools(&team, "ic").is_empty(), "not a specialist yet");
        let made = team.make_invoice_chaser("ic", Some(5.0)).await.unwrap();
        assert_eq!(made["specialty"], INVOICES);
        assert!(team.agent("ic").await.unwrap().grants.routines);
        assert_eq!(team.routines_of("ic").await.len(), 1);
        assert_eq!(team.goals_of("ic").len(), 1);
        let again = team.make_invoice_chaser("ic", None).await.unwrap();
        assert_eq!((team.routines_of("ic").await.len(), team.goals_of("ic").len()), (1, 1), "made twice: nothing doubled");
        assert_eq!(again["goal"], made["goal"]);
        let ts = tools(&team, "ic");
        let record = ts.iter().find(|t| t.spec().name == "invoices_record").unwrap();
        record.call(json!({"who": "Acme", "email": "ap@acme.example", "amount": 1200, "currency": "EUR", "due": "2020-01-01"})).await.unwrap();
        assert_eq!(invoices_goal_met(&team, "ic"), Some(false), "an old open invoice breaks it");
        let id = team.invoices("ic")[0].id.clone();
        record.call(json!({"id": id, "status": "paid"})).await.unwrap();
        assert_eq!(invoices_goal_met(&team, "ic"), Some(true));
    }
}
