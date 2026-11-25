//! Usage: what this month cost, from the record. Never an estimate shown as a fact.
//!
//! - **Models**: each finished job's tokens and cost (its model's price, or the
//!   list price in `store::known_price`), this month, by agent and by day.
//!   Jobs from before prices were known show their tokens with "not priced".
//! - **Enkeon credits**: the allowance and what's used this month, from
//!   Enkeon itself, when the person's sign-in is fresh.
//! - **Computer**: the cloud Parallax machine's hours this month and what they
//!   cost at its own hourly rate (`cloud_computer`), and the worlds on this Mac (free).

use std::collections::BTreeMap;

use serde_json::{json, Value};

use crate::store::{Job, JobStatus};
use crate::{util, Team};

fn month_of(secs: u64) -> String {
    chrono::DateTime::from_timestamp(secs as i64, 0).map(|t| t.with_timezone(&chrono::Local).format("%Y-%m").to_string()).unwrap_or_default()
}

fn day_of(secs: u64) -> String {
    chrono::DateTime::from_timestamp(secs as i64, 0).map(|t| t.with_timezone(&chrono::Local).format("%Y-%m-%d").to_string()).unwrap_or_default()
}

/// A month's jobs for one agent, summed.
#[derive(Default)]
struct Sum {
    jobs: u64,
    failed: u64,
    tokens: u64,
    microdollars: u64,
    unpriced_tokens: u64,
}

fn add(s: &mut Sum, j: &Job, free: bool) {
    s.jobs += 1;
    if matches!(j.status, JobStatus::Failed) {
        s.failed += 1;
    }
    s.tokens += j.tokens;
    s.microdollars += j.microdollars;
    if j.microdollars == 0 && j.tokens > 0 && !free {
        s.unpriced_tokens += j.tokens;
    }
}

impl Team {
    pub async fn usage(&self) -> Value {
        let month = chrono::Local::now().format("%Y-%m").to_string();
        let settings = self.settings().await;
        let agents = self.agents().await;
        let mut total = Sum::default();
        let mut by_day: BTreeMap<String, (u64, u64)> = BTreeMap::new();
        let mut rows = Vec::new();
        for a in agents.iter().filter(|a| a.shadow_of.is_none() && !crate::bench::is_probe(&a.id)) {
            let free = settings.price_of(&a.model).is_some_and(|p| p.input == 0.0 && p.output == 0.0);
            let mut s = Sum::default();
            for j in util::read_jsonl::<Job>(&self.paths.jobs(&a.id)).iter().filter(|j| month_of(j.started_at) == month) {
                add(&mut s, j, free);
                add(&mut total, j, free);
                let d = by_day.entry(day_of(j.started_at)).or_default();
                d.0 += j.microdollars;
                d.1 += 1;
            }
            if s.jobs > 0 {
                rows.push(json!({
                    "id": a.id, "name": a.name, "model": a.model, "priced": settings.price_of(&a.model).is_some(),
                    "jobs": s.jobs, "failed": s.failed, "tokens": s.tokens, "dollars": s.microdollars as f64 / 1e6, "unpriced_tokens": s.unpriced_tokens,
                }));
            }
        }
        rows.sort_by(|a, b| b["dollars"].as_f64().partial_cmp(&a["dollars"].as_f64()).unwrap_or(std::cmp::Ordering::Equal).then(b["tokens"].as_u64().cmp(&a["tokens"].as_u64())));
        json!({
            "month": month,
            "models": {
                "dollars": total.microdollars as f64 / 1e6,
                "jobs": total.jobs,
                "failed": total.failed,
                "tokens": total.tokens,
                "unpriced_tokens": total.unpriced_tokens,
                "agents": rows,
                "days": by_day.into_iter().map(|(d, (m, n))| json!({"day": d, "dollars": m as f64 / 1e6, "jobs": n})).collect::<Vec<_>>(),
            },
            "credits": self.enkeon_credits().await,
            "computer": self.cloud_computer_usage(&month),
            "worlds_here": self.local_worlds_count(),
        })
    }

    /// Worlds on this Mac: free, counted for the page.
    fn local_worlds_count(&self) -> usize {
        std::fs::read_dir(self.paths.root.join("parallax").join("worlds")).map(|d| d.count()).unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::Trigger;

    fn job(started_at: u64, tokens: u64, microdollars: u64, status: JobStatus) -> Job {
        Job { id: util::random_hex(4), agent: "a".into(), trigger: Trigger::Chat, input: "x".into(), started_at, finished_at: Some(started_at + 1), status, tokens, microdollars, ..Default::default() }
    }

    #[test]
    fn sums_count_failures_and_name_unpriced_tokens() {
        let mut s = Sum::default();
        add(&mut s, &job(1, 1000, 4200, JobStatus::Done), false);
        add(&mut s, &job(2, 500, 0, JobStatus::Failed), false);
        add(&mut s, &job(3, 700, 0, JobStatus::Done), true);
        assert_eq!((s.jobs, s.failed, s.tokens, s.microdollars), (3, 1, 2200, 4200));
        assert_eq!(s.unpriced_tokens, 500, "a free model's tokens aren't 'unpriced'");
    }

    #[tokio::test]
    async fn the_page_reads_this_months_jobs_only() {
        let dir = std::env::temp_dir().join(format!("cookie-usage-{}", util::random_hex(4)));
        let team = Team::open(&dir).unwrap();
        let rec = team
            .add_agent(crate::AgentRecord {
                id: "writer".into(), name: "Writer".into(), model: "anthropic:claude-sonnet-4-6".into(), job: "Writes.".into(), created_at: 0,
                grants: Default::default(), limits: Default::default(), probation_until: None, parent: None, shadow_of: None,
                handover: None, origin: None, version: 1,
            })
            .await
            .unwrap();
        let now = util::now();
        for j in [job(now, 2000, 9000, JobStatus::Done), job(now - 86_400 * 70, 9999, 99_999, JobStatus::Done)] {
            util::append_jsonl(&team.paths.jobs(&rec.id), &Job { agent: rec.id.clone(), ..j }).unwrap();
        }
        let u = team.usage().await;
        assert_eq!(u["models"]["jobs"], 1, "last month's job isn't this month's");
        assert_eq!(u["models"]["dollars"], 0.009);
        assert_eq!(u["models"]["agents"][0]["name"], "Writer");
        assert_eq!(u["models"]["agents"][0]["priced"], true, "Sonnet 4.6 has a list price");
        assert_eq!(u["credits"]["signed_in"], false, "no Enkeon here: said, not guessed");
        assert_eq!(u["computer"]["set_up"], false);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
