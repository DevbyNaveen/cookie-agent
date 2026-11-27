//! Mandates: one yes for a pattern the person keeps saying yes to.
//!
//! Approving every send one by one ends in rubber-stamping (people approve
//! 93–97% of such prompts, and catch few of the bad ones). Plans are where a
//! person's judgement works. So when an agent keeps asking for the same kind
//! of send to the same people, it may propose a mandate: this tool, to these
//! recipients only, at most this many times, until this date. The person sees
//! the whole scope once and says yes or no; within it, sends go out without a
//! card, each with a receipt that names the mandate.
//!
//! What a mandate can never cover: a payment, an order or a trade, a delete,
//! a recipient that isn't on its list, or any value that came from content
//! the person didn't write (the policy's "not from you" marks). Those ask
//! every time. A mandate ends at its date or its count, and the person can end
//! it at any moment.

use std::sync::Arc;

use cookie_harness::tool::{tool, Effect, Tool};
use cookie_harness::ApprovalRequest;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{util, Team};

pub const PROPOSE_TOOL: &str = "propose_mandate";
/// The longest a mandate may last.
const MOST_DAYS: u64 = 90;
const MOST_USES: u32 = 500;
const MOST_TARGETS: usize = 50;

/// Words in a tool's name that make it money or something that can't be taken back: never under a mandate.
const NEVER: [&str; 16] = ["pay", "charge", "transfer", "order", "buy", "purchase", "trade", "checkout", "wire", "refund", "delete", "remove", "cancel", "invoice_send", "service_act", "phone_call"];

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Mandate {
    pub id: String,
    pub agent: String,
    pub tool: String,
    /// Who or where it may reach, lowercased: every address in a send must be one of these.
    pub targets: Vec<String>,
    pub why: String,
    pub max_uses: u32,
    pub used: u32,
    pub expires_at: u64,
    pub created_at: u64,
    pub ended: bool,
}

impl Mandate {
    fn live(&self, now: u64) -> bool {
        !self.ended && self.used < self.max_uses && now < self.expires_at
    }
}

fn never_mandated(tool: &str) -> bool {
    let t = tool.to_lowercase();
    NEVER.iter().any(|w| t.contains(w))
}

/// Email addresses and phone-like numbers in a preview, lowercased.
fn addresses(text: &str) -> Vec<String> {
    text.split(|c: char| c.is_whitespace() || matches!(c, '<' | '>' | '(' | ')' | '"' | '\'' | ',' | ';' | ':'))
        .map(|w| w.trim_matches(|c: char| matches!(c, '.' | '[' | ']')).to_lowercase())
        .filter(|w| w.contains('@') && w.split('@').nth(1).is_some_and(|d| d.contains('.')))
        .collect()
}

/// Does `m` cover this request? Only an outward action of its tool, by its agent, whose every
/// address is on its list, with at least one of its targets named, and nothing chosen by data.
pub(crate) fn covers(m: &Mandate, agent: &str, req: &ApprovalRequest, now: u64) -> bool {
    if !m.live(now) || m.agent != agent || m.tool != req.tool || req.effect != Effect::Outbound || never_mandated(&req.tool) || !req.from_data.is_empty() {
        return false;
    }
    let preview = req.preview.to_lowercase();
    let named = m.targets.iter().any(|t| preview.contains(t.as_str()));
    let all_listed = addresses(&preview).iter().all(|a| m.targets.contains(a));
    named && all_listed
}

impl Team {
    fn mandates_path(&self) -> std::path::PathBuf {
        self.paths.root.join("mandates.json")
    }

    pub fn mandates(&self) -> Vec<Mandate> {
        util::read_json(&self.mandates_path())
    }

    fn edit_mandates<T>(&self, f: impl FnOnce(&mut Vec<Mandate>) -> T) -> Result<T, String> {
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _g = LOCK.lock().unwrap();
        let mut all = self.mandates();
        let out = f(&mut all);
        util::write_json(&self.mandates_path(), &all)?;
        Ok(out)
    }

    pub fn end_mandate(&self, id: &str) -> Result<(), String> {
        self.edit_mandates(|all| {
            let m = all.iter_mut().find(|m| m.id == id).ok_or("No such mandate.")?;
            m.ended = true;
            Ok::<_, String>(())
        })?
    }

    /// The mandate that covers this request, used once; none when it must be put to the person.
    pub(crate) fn use_mandate(&self, agent: &str, req: &ApprovalRequest) -> Option<Mandate> {
        let now = util::now();
        self.edit_mandates(|all| {
            let m = all.iter_mut().find(|m| covers(m, agent, req, now))?;
            m.used += 1;
            Some(m.clone())
        })
        .ok()
        .flatten()
    }
}

/// `propose_mandate`, for an agent that may send.
pub(crate) fn tool_for(team: &Arc<Team>, agent: &str) -> Arc<dyn Tool> {
    let (w, a) = (Arc::downgrade(team), agent.to_string());
    Arc::new(
        tool(
            PROPOSE_TOOL,
            "Ask the person for a standing yes, when you keep asking them for the same kind of send to the same people: one tool, these \
             recipients only (their exact addresses), at most so many times, for so many days. Within it, those sends go out without a \
             card. It never covers a payment, an order, a trade, a delete, anyone not on the list, or anything chosen by content they \
             didn't write. Propose it only for a pattern they have already said yes to.",
            json!({"type": "object", "properties": {
                "tool": {"type": "string", "description": "the tool it covers, e.g. send_email"},
                "targets": {"type": "array", "items": {"type": "string"}, "maxItems": MOST_TARGETS, "description": "exact addresses it may reach"},
                "max_uses": {"type": "integer", "minimum": 1, "maximum": MOST_USES},
                "days": {"type": "integer", "minimum": 1, "maximum": MOST_DAYS},
                "why": {"type": "string", "description": "the pattern, in one line: 'weekly reminders for unpaid invoices'"}
            }, "required": ["tool", "targets", "max_uses", "days", "why"]}),
            Effect::Write,
            move |args: Value| {
                let (w, a) = (w.clone(), a.clone());
                async move {
                    let team = w.upgrade().ok_or("Cookie is closing.")?;
                    let t = args["tool"].as_str().unwrap_or_default().trim().to_string();
                    if t.is_empty() || never_mandated(&t) {
                        return Err("That tool can't be under a mandate: money, orders, trades and deletes ask every time.".into());
                    }
                    let targets: Vec<String> = args["targets"].as_array().into_iter().flatten().filter_map(|x| x.as_str()).map(|x| x.trim().to_lowercase()).filter(|x| !x.is_empty()).take(MOST_TARGETS).collect();
                    if targets.is_empty() {
                        return Err("Name exactly who it may reach.".into());
                    }
                    let days = args["days"].as_u64().unwrap_or(7).clamp(1, MOST_DAYS);
                    let m = Mandate {
                        id: util::new_id("mandate"),
                        agent: a.clone(),
                        tool: t,
                        targets,
                        why: util::clip(args["why"].as_str().unwrap_or(""), 300),
                        max_uses: (args["max_uses"].as_u64().unwrap_or(10) as u32).clamp(1, MOST_USES),
                        used: 0,
                        expires_at: util::now() + days * 86_400,
                        created_at: util::now(),
                        ended: false,
                    };
                    team.edit_mandates(|all| all.push(m.clone()))?;
                    Ok(format!("Mandate {} is in force: {} to {} recipients, up to {} times, for {days} days.", m.id, m.tool, m.targets.len(), m.max_uses))
                }
            },
        )
        .with_preview(|args| {
            let targets: Vec<&str> = args["targets"].as_array().into_iter().flatten().filter_map(|x| x.as_str()).collect();
            format!(
                "A standing yes: {} — {}\nTo exactly: {}\nAt most {} times, for {} days. Money, orders, deletes and anyone else still ask every time.",
                args["tool"].as_str().unwrap_or("?"),
                args["why"].as_str().unwrap_or(""),
                targets.join(", "),
                args["max_uses"].as_u64().unwrap_or(0),
                args["days"].as_u64().unwrap_or(0)
            )
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m() -> Mandate {
        Mandate { id: "m".into(), agent: "a".into(), tool: "send_email".into(), targets: vec!["anna@acme.com".into()], max_uses: 2, expires_at: 2_000_000_000, ..Default::default() }
    }

    fn req(tool: &str, effect: Effect, preview: &str, from_data: Vec<String>) -> ApprovalRequest {
        ApprovalRequest { tool: tool.into(), effect, preview: preview.into(), reason: String::new(), from_data }
    }

    #[test]
    fn a_mandate_covers_only_its_own_send_to_its_own_people() {
        let now = 1_900_000_000;
        assert!(covers(&m(), "a", &req("send_email", Effect::Outbound, "To: Anna@acme.com\nYour invoice is due", vec![]), now));
        assert!(!covers(&m(), "a", &req("send_email", Effect::Outbound, "To: anna@acme.com, cc: boss@evil.example", vec![]), now), "anyone not on the list");
        assert!(!covers(&m(), "a", &req("send_email", Effect::Outbound, "To: anna@acme.com", vec!["to = x".into()]), now), "a value chosen by data");
        assert!(!covers(&m(), "b", &req("send_email", Effect::Outbound, "To: anna@acme.com", vec![]), now), "another agent");
        assert!(!covers(&m(), "a", &req("send_slack", Effect::Outbound, "To: anna@acme.com", vec![]), now), "another tool");
        assert!(!covers(&m(), "a", &req("send_email", Effect::Destroy, "To: anna@acme.com", vec![]), now), "a delete");
        assert!(!covers(&Mandate { used: 2, ..m() }, "a", &req("send_email", Effect::Outbound, "To: anna@acme.com", vec![]), now), "its count is spent");
        assert!(!covers(&Mandate { expires_at: now, ..m() }, "a", &req("send_email", Effect::Outbound, "To: anna@acme.com", vec![]), now), "its date has passed");
        assert!(!covers(&Mandate { tool: "pay_invoice".into(), ..m() }, "a", &req("pay_invoice", Effect::Outbound, "To: anna@acme.com", vec![]), now), "money never");
    }

    #[test]
    fn using_a_mandate_counts_down() {
        let dir = tempfile::tempdir().unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let team = rt.block_on(async { Team::open(dir.path()).unwrap() });
        team.edit_mandates(|all| all.push(m())).unwrap();
        let r = req("send_email", Effect::Outbound, "To: anna@acme.com", vec![]);
        assert!(team.use_mandate("a", &r).is_some());
        assert!(team.use_mandate("a", &r).is_some());
        assert!(team.use_mandate("a", &r).is_none(), "two uses, then it asks again");
    }
}
