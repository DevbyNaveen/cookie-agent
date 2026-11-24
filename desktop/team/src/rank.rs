//! Rank: an agent's seniority, worked out from its own record, never written
//! into its instructions by anyone.
//!
//! Arithmetic over the last 90 days of what it did: jobs that ended clean
//! (`outcome::clean`) against all its jobs, by the Wilson lower bound (so 3
//! of 3 is not "100%"), the actions the person lets it run unasked (earned
//! trust), the person's noes, and how long it has been on the team. A
//! window, not a lifetime: a bad quarter demotes. Worked out again after
//! every job; a change is news for the person.
//!
//! What rank never changes is consent: what asks the person still asks, at
//! any rank. On the desktop today rank is a record the agent and the person
//! read; it doesn't change limits (the person's own limits stand).
//!
//! Ported from the super console (gateway `chat/rank.rs`).

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::experience::real;
use crate::outcome::{self, wilson_lower};
use crate::store::{AgentRecord, Job, JobStatus};
use crate::{util, Team};

pub const WINDOW_DAYS: u64 = 90;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Rank {
    #[default]
    Associate,
    Senior,
    Lead,
    Executive,
}

impl Rank {
    pub fn label(self) -> &'static str {
        match self {
            Rank::Associate => "Associate",
            Rank::Senior => "Senior",
            Rank::Lead => "Lead",
            Rank::Executive => "Executive",
        }
    }

    pub fn next(self) -> Option<Rank> {
        match self {
            Rank::Associate => Some(Rank::Senior),
            Rank::Senior => Some(Rank::Lead),
            Rank::Lead => Some(Rank::Executive),
            Rank::Executive => None,
        }
    }
}

/// What a rank is worked out from; every number a record that can be shown.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Facts {
    /// Jobs that finished or failed in the window (a stopped job is the person's call).
    pub jobs: i64,
    pub clean: i64,
    /// The person's noes to its actions in the window.
    pub noes: i64,
    /// Actions it may run without asking.
    pub earned: i64,
    pub tenure_days: i64,
}

struct Bar {
    rank: Rank,
    jobs: i64,
    wilson: f64,
    earned: i64,
    tenure: i64,
    max_noes: i64,
}

/// Top rung first. Most agents start and stay Associate; that is the point.
const BARS: [Bar; 3] = [
    Bar { rank: Rank::Executive, jobs: 150, wilson: 0.70, earned: 3, tenure: 30, max_noes: 0 },
    Bar { rank: Rank::Lead, jobs: 60, wilson: 0.60, earned: 1, tenure: 14, max_noes: 1 },
    Bar { rank: Rank::Senior, jobs: 20, wilson: 0.50, earned: 0, tenure: 7, max_noes: i64::MAX },
];

fn meets(f: &Facts, b: &Bar) -> bool {
    f.jobs >= b.jobs && wilson_lower(f.clean, f.jobs) >= b.wilson && f.earned >= b.earned && f.tenure_days >= b.tenure && f.noes <= b.max_noes
}

pub fn derive(f: &Facts) -> Rank {
    BARS.iter().find(|b| meets(f, b)).map(|b| b.rank).unwrap_or_default()
}

/// What separates this record from `to`, in words the agent can act on.
pub fn gaps(f: &Facts, to: Rank) -> Vec<String> {
    let Some(b) = BARS.iter().find(|b| b.rank == to) else { return Vec::new() };
    let mut out = Vec::new();
    if f.jobs < b.jobs {
        out.push(format!("{} more jobs in the last {WINDOW_DAYS} days", b.jobs - f.jobs));
    }
    if wilson_lower(f.clean, f.jobs) < b.wilson {
        out.push(format!("a clean rate that holds above {:.0}% (now {} clean of {})", b.wilson * 100.0, f.clean, f.jobs));
    }
    if f.earned < b.earned {
        let n = b.earned - f.earned;
        out.push(format!("{n} earned action{} (the person approving the same change five times in a row)", if n == 1 { "" } else { "s" }));
    }
    if f.tenure_days < b.tenure {
        out.push(format!("{} more days on the team", b.tenure - f.tenure_days));
    }
    if f.noes > b.max_noes {
        out.push(format!("a window with {} (it has {})", if b.max_noes == 0 { "no noes".to_string() } else { format!("at most {} no", b.max_noes) }, f.noes));
    }
    out
}

fn basis(f: &Facts, you: bool) -> String {
    let mut s = format!("{} clean of {} jobs in the last {WINDOW_DAYS} days", f.clean, f.jobs);
    if f.earned > 0 {
        s.push_str(&format!(", {} action{} {} runs without asking", f.earned, if f.earned == 1 { "" } else { "s" }, if you { "the person lets you" } else { "it" }));
    }
    if f.noes > 0 {
        s.push_str(&format!(", {} no{}", f.noes, if f.noes == 1 { "" } else { "es" }));
    }
    s
}

/// The block in its instructions: its rank, why, and what the next rung needs.
pub fn block(rank: Rank, f: &Facts) -> String {
    let mut s = format!("Your rank on this team: {}, from your own record ({}), worked out again after every job.\n", rank.label(), basis(f, true));
    if let Some(next) = rank.next() {
        let g = gaps(f, next);
        if !g.is_empty() {
            s.push_str(&format!("To reach {}: {}.\n", next.label(), g.join("; ")));
        }
    }
    s.push_str("Rank never changes what needs the person's yes: every send, delete, payment and change to their things still asks.");
    s
}

pub fn facts(jobs: &[Job], rec: &AgentRecord, earned: usize, now: u64) -> Facts {
    let since = now.saturating_sub(WINDOW_DAYS * 86_400);
    let window: Vec<&Job> = jobs.iter().filter(|j| real(j) && j.started_at >= since && matches!(j.status, JobStatus::Done | JobStatus::Failed)).collect();
    let first = jobs.iter().filter(|j| real(j)).map(|j| j.started_at).min().unwrap_or(rec.created_at).min(rec.created_at);
    Facts {
        jobs: window.len() as i64,
        clean: window.iter().filter(|j| outcome::clean(j)).count() as i64,
        noes: window.iter().flat_map(|j| &j.approvals).filter(|a| a.outcome == "no").count() as i64,
        earned: earned as i64,
        tenure_days: (now.saturating_sub(first) / 86_400) as i64,
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Held {
    rank: Rank,
    since: u64,
}

impl Team {
    fn earned_count(&self, agent: &str) -> usize {
        cookie_harness::trust::EarnedTrust::open(self.paths.trust(agent), 5).map(|t| t.earned_tools().len()).unwrap_or(0)
    }

    /// Its rank and the facts behind it.
    pub fn rank(&self, rec: &AgentRecord) -> (Rank, Facts) {
        let jobs: Vec<Job> = util::read_jsonl(&self.paths.jobs(&rec.id));
        let f = facts(&jobs, rec, self.earned_count(&rec.id), util::now());
        (derive(&f), f)
    }

    pub fn rank_view(&self, rec: &AgentRecord) -> Value {
        let (rank, f) = self.rank(rec);
        let held: Held = util::read_json(&self.paths.agent(&rec.id).join("rank.json"));
        let next = rank.next().map(|n| json!({"rank": n.label(), "needs": gaps(&f, n)}));
        json!({"rank": rank.label(), "since": (held.rank == rank && held.since > 0).then_some(held.since), "facts": f, "basis": basis(&f, false), "next": next})
    }

    /// After a job: a promotion or a step down is news.
    pub(crate) fn update_rank(&self, rec: &AgentRecord) {
        if rec.id == crate::front::COOKIE_ID || rec.shadow_of.is_some() {
            return;
        }
        let path = self.paths.agent(&rec.id).join("rank.json");
        let held: Held = util::read_json(&path);
        let (rank, f) = self.rank(rec);
        if rank == held.rank && held.since > 0 {
            return;
        }
        let _ = util::write_json(&path, &Held { rank, since: util::now() });
        if held.since == 0 && rank == Rank::Associate {
            return; // the first reading of a new agent is not news
        }
        let title = if rank > held.rank { format!("{} was promoted to {}", rec.name, rank.label()) } else { format!("{} is now {} (was {})", rec.name, rank.label(), held.rank.label()) };
        self.notice(&rec.id, &title, &basis(&f, false), None, false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rank_is_arithmetic_and_a_small_record_stays_associate() {
        let f = Facts { jobs: 3, clean: 3, noes: 0, earned: 0, tenure_days: 30 };
        assert_eq!(derive(&f), Rank::Associate, "3 of 3 is not a record");
        let senior = Facts { jobs: 20, clean: 16, noes: 4, earned: 0, tenure_days: 7 };
        assert_eq!(derive(&senior), Rank::Senior);
        let lead_but_noes = Facts { jobs: 70, clean: 60, noes: 2, earned: 1, tenure_days: 20 };
        assert_eq!(derive(&lead_but_noes), Rank::Senior, "two noes keep it from Lead");
        assert!(gaps(&lead_but_noes, Rank::Lead).iter().any(|g| g.contains("at most 1 no")));
        let b = block(Rank::Senior, &senior);
        assert!(b.contains("Senior") && b.contains("To reach Lead") && b.contains("still asks"));
    }
}
