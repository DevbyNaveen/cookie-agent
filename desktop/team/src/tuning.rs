//! How one agent is tuned, and every change to it, with Undo.
//!
//! An agent's tuning (`agents/<id>/tuning.json`) is what the harness runs it
//! with beyond its name, job and model: how long its prompt cache lives, when
//! its conversation is compacted, how hard it reasons, and the habits it has
//! proven (standing instructions the nightly exam kept). Habits sit in its
//! instructions, which change only when a habit is kept or undone, so they
//! stay in the prompt cache between jobs.
//!
//! Every change — from the nightly loop (`evolve`), from right-sizing, from a
//! teammate's teaching, or from you — is written to `evolution.jsonl` with the
//! tuning (and model) before and after, and why. Undo puts back what was
//! there before that change. Nothing in an agent changes silently.

use serde::{Deserialize, Serialize};

use crate::{util, Team};

/// Habits an agent keeps at most: each one costs prompt on every call.
pub const MAX_HABITS: usize = 8;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Tuning {
    /// `auto` (chosen from when its jobs come, `cache_ttl_for`), `5m` or `1h`.
    pub cache: String,
    pub clear_tool_results_after: usize,
    pub summarize_above_tokens: u64,
    pub keep_recent_turns: usize,
    /// `low` · `medium` · `high`; `None` is the model's own default.
    pub effort: Option<String>,
    /// Standing instructions the exam proved help this agent.
    pub habits: Vec<String>,
    /// Prepare for its routines while idle (`prep`). Off by default: each prep is a job.
    pub prepare: bool,
}

impl Default for Tuning {
    fn default() -> Self {
        Self { cache: "auto".into(), clear_tool_results_after: 8, summarize_above_tokens: 120_000, keep_recent_turns: 4, effort: None, habits: Vec::new(), prepare: false }
    }
}

impl Tuning {
    /// Within the ranges the harness handles well.
    pub fn clamp(mut self) -> Self {
        if !matches!(self.cache.as_str(), "auto" | "5m" | "1h") {
            self.cache = "auto".into();
        }
        self.clear_tool_results_after = self.clear_tool_results_after.clamp(2, 40);
        self.summarize_above_tokens = self.summarize_above_tokens.clamp(20_000, 400_000);
        self.keep_recent_turns = self.keep_recent_turns.clamp(1, 20);
        if !matches!(self.effort.as_deref(), None | Some("low") | Some("medium") | Some("high")) {
            self.effort = None;
        }
        self.habits.retain(|h| !h.trim().is_empty());
        self.habits.truncate(MAX_HABITS);
        self
    }

    /// The habits as a block of the instructions, or none.
    pub fn habits_block(&self) -> Option<String> {
        (!self.habits.is_empty()).then(|| format!("Habits that proved to help you in your own work (keep them):\n{}", self.habits.iter().map(|h| format!("- {h}")).collect::<Vec<_>>().join("\n")))
    }

    pub fn effort(&self) -> Option<cookie_harness::provider::Effort> {
        use cookie_harness::provider::Effort;
        match self.effort.as_deref() {
            Some("low") => Some(Effort::Low),
            Some("medium") => Some(Effort::Medium),
            Some("high") => Some(Effort::High),
            _ => None,
        }
    }
}

/// Which prompt-cache lifetime costs less for an agent whose jobs start
/// `gaps` seconds apart. A job's first call reads the cache when the previous
/// job's calls are still within the lifetime, else writes it again: at 5
/// minutes a write costs 1.25× the prefix and a read 0.1×; at an hour a write
/// costs 2×. Calls inside one job are seconds apart and cost the same either
/// way, so only the gaps between jobs decide. Fewer than 5 gaps: the default.
pub fn cache_ttl_for(gaps: &[u64]) -> &'static str {
    if gaps.len() < 5 {
        return "5m";
    }
    let cost = |ttl: u64, write: f64| gaps.iter().map(|g| if *g <= ttl { 0.1 } else { write }).sum::<f64>();
    let five = cost(300, 1.25);
    let hour = cost(3_600, 2.0);
    // The hour only when it is clearly cheaper (a tenth), so a near tie keeps the default.
    if hour < five * 0.9 { "1h" } else { "5m" }
}

/// One change to an agent, as kept in `evolution.jsonl`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Change {
    pub id: String,
    pub agent: String,
    pub at: u64,
    /// `knob` (harness setting) · `habit` · `model` · `cache` · `taught` · `you`
    pub kind: String,
    /// In words, for the person.
    pub what: String,
    /// Who made it: `nightly`, `right-size`, a teammate's name, `you`.
    pub by: String,
    pub before: Option<Tuning>,
    pub after: Option<Tuning>,
    pub model_before: Option<String>,
    pub model_after: Option<String>,
    /// The exam it passed: pass rate and cost per case, before and after.
    pub exam: Option<serde_json::Value>,
    /// A lesson it added (a teammate's teaching): Undo takes it out again.
    pub lesson: Option<String>,
    /// `kept` · `undone` · `dropped` (tried, the exam said no) · `proposed`
    /// (offered, yours to accept) · `accepted` · `declined`
    pub state: String,
}

impl Team {
    fn tuning_path(&self, agent: &str) -> std::path::PathBuf {
        self.paths.agent(agent).join("tuning.json")
    }

    fn evolution_path(&self, agent: &str) -> std::path::PathBuf {
        self.paths.agent(agent).join("evolution.jsonl")
    }

    pub fn tuning(&self, agent: &str) -> Tuning {
        util::read_json::<Tuning>(&self.tuning_path(agent)).clamp()
    }

    /// The prompt-cache lifetime this agent runs with now.
    pub fn cache_ttl(&self, agent: &str) -> &'static str {
        match self.tuning(agent).cache.as_str() {
            "1h" => "1h",
            "5m" => "5m",
            _ => {
                let mut starts: Vec<u64> = util::read_jsonl::<crate::store::Job>(&self.paths.jobs(agent)).iter().rev().take(40).map(|j| j.started_at).collect();
                starts.sort_unstable();
                let gaps: Vec<u64> = starts.windows(2).map(|w| w[1].saturating_sub(w[0])).collect();
                cache_ttl_for(&gaps)
            }
        }
    }

    /// The prompt cache and the read cache over the last 30 days: hit rate and
    /// what they saved, from the jobs' own token counts and the model's price.
    pub async fn cache_view(&self, agent: &str) -> serde_json::Value {
        let since = util::now().saturating_sub(30 * 86_400);
        let jobs: Vec<crate::store::Job> = util::read_jsonl(&self.paths.jobs(agent));
        let (mut fresh, mut read, mut write, mut counted) = (0u64, 0u64, 0u64, 0usize);
        for j in jobs.iter().filter(|j| j.started_at >= since && (j.input_tokens + j.cache_read_tokens + j.cache_write_tokens) > 0) {
            fresh += j.input_tokens;
            read += j.cache_read_tokens;
            write += j.cache_write_tokens;
            counted += 1;
        }
        let total_in = fresh + read + write;
        let model = self.agent(agent).await.map(|a| a.model).unwrap_or_default();
        let price = self.settings().await.prices.get(&model).copied();
        // Saved: cached reads at the read price instead of the input price, less what writing cost over plain input.
        let saved = price.map(|p| (read as f64 * (p.input - p.cache_read) - write as f64 * (p.cache_write - p.input)).round() as i64);
        let (hits, fetched) = self.read_cache_counts(agent, 30);
        let ttl = self.cache_ttl(agent);
        serde_json::json!({
            "jobs": counted,
            "input_tokens": fresh, "cache_read_tokens": read, "cache_write_tokens": write,
            "hit_rate": (total_in > 0).then(|| read as f64 / total_in as f64),
            "saved_microdollars": saved,
            "ttl": ttl,
            "ttl_setting": self.tuning(agent).cache,
            "reads_from_cache": hits,
            "reads_fetched": fetched,
        })
    }

    /// Its career stage and what it has earned, from the record.
    pub async fn career(&self, agent: &str) -> Result<serde_json::Value, String> {
        let rec = self.agent(agent).await?;
        let (rank, facts) = self.rank(&rec);
        let jobs: Vec<crate::store::Job> = util::read_jsonl(&self.paths.jobs(agent));
        let real = jobs.iter().filter(|j| crate::experience::real(j)).count();
        let (stage, means) = crate::evolve::stage(rank, rec.on_probation(util::now()), real);
        Ok(serde_json::json!({"stage": stage, "means": means, "rank": rank.label(), "jobs": real, "tenure_days": facts.tenure_days}))
    }

    pub fn evolution(&self, agent: &str) -> Vec<Change> {
        let mut v: Vec<Change> = util::read_jsonl(&self.evolution_path(agent));
        v.reverse();
        v
    }

    /// Change an agent's tuning (and maybe its model), and keep the change.
    pub(crate) async fn apply_change(&self, agent: &str, kind: &str, what: &str, by: &str, tuning: Option<Tuning>, model: Option<String>, exam: Option<serde_json::Value>) -> Result<Change, String> {
        let rec = self.agent(agent).await?;
        let before = self.tuning(agent);
        let after = tuning.map(Tuning::clamp);
        if let Some(t) = &after {
            util::write_json(&self.tuning_path(agent), t)?;
        }
        let model_before = model.as_ref().map(|_| rec.model.clone());
        if let Some(m) = &model {
            cookie_harness::Agent::new(m).map_err(|e| e.to_string())?;
            self.set_model(agent, m).await?;
        }
        let c = Change {
            id: util::new_id("chg"),
            agent: agent.into(),
            at: util::now(),
            kind: kind.into(),
            what: what.into(),
            by: by.into(),
            before: after.as_ref().map(|_| before),
            after,
            model_before,
            model_after: model,
            exam,
            lesson: None,
            state: "kept".into(),
        };
        util::append_jsonl(&self.evolution_path(agent), &c)?;
        self.emit(crate::events::TeamEvent::Evolved { agent: agent.into(), what: what.into() });
        Ok(c)
    }

    /// Put back what was there before one change.
    pub async fn undo_change(&self, agent: &str, id: &str) -> Result<Change, String> {
        let mut all: Vec<Change> = util::read_jsonl(&self.evolution_path(agent));
        let c = all.iter_mut().find(|c| c.id == id).ok_or("No such change.")?;
        if c.state != "kept" {
            return Err("Only a kept change can be undone.".into());
        }
        if let Some(lesson) = &c.lesson {
            let left: Vec<_> = self.lessons(agent).into_iter().filter(|l| &l.id != lesson).collect();
            self.save_lessons(agent, &left)?;
        }
        if let Some(t) = &c.before {
            util::write_json(&self.tuning_path(agent), t)?;
        }
        if let Some(m) = &c.model_before {
            self.set_model(agent, m).await?;
        }
        c.state = "undone".into();
        let done = c.clone();
        util::write_jsonl(&self.evolution_path(agent), &all)?;
        self.emit(crate::events::TeamEvent::Evolved { agent: agent.into(), what: format!("Undid: {}", done.what) });
        Ok(done)
    }

    /// The person's own tuning, kept as a change like any other.
    pub async fn set_tuning(&self, agent: &str, patch: &serde_json::Value) -> Result<Change, String> {
        let mut t = self.tuning(agent);
        if let Some(v) = patch.get("cache").and_then(|v| v.as_str()) {
            t.cache = v.into();
        }
        if let Some(v) = patch.get("effort") {
            t.effort = v.as_str().map(str::to_string);
        }
        if let Some(v) = patch.get("clear_tool_results_after").and_then(|v| v.as_u64()) {
            t.clear_tool_results_after = v as usize;
        }
        if let Some(v) = patch.get("summarize_above_tokens").and_then(|v| v.as_u64()) {
            t.summarize_above_tokens = v;
        }
        if let Some(v) = patch.get("keep_recent_turns").and_then(|v| v.as_u64()) {
            t.keep_recent_turns = v as usize;
        }
        if let Some(v) = patch.get("prepare").and_then(|v| v.as_bool()) {
            t.prepare = v;
        }
        if let Some(h) = patch.get("remove_habit").and_then(|v| v.as_str()) {
            t.habits.retain(|x| x != h);
        }
        self.apply_change(agent, "you", "You changed its tuning", "you", Some(t), None, None).await
    }

    /// The model, changed on the record (as the profile's model field does).
    async fn set_model(&self, agent: &str, model: &str) -> Result<(), String> {
        let mut agents = self.agents.write().await;
        let a = agents.iter_mut().find(|a| a.id == agent).ok_or("No such agent.")?;
        a.model = model.to_string();
        a.version += 1;
        let snapshot = agents.clone();
        drop(agents);
        util::write_json(&self.paths.roster(), &snapshot)?;
        self.emit(crate::events::TeamEvent::RosterChanged);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hour_pays_only_when_jobs_come_five_to_sixty_minutes_apart() {
        assert_eq!(cache_ttl_for(&[600, 900, 1200, 1800, 2400, 600]), "1h", "every gap misses five minutes, hits an hour");
        assert_eq!(cache_ttl_for(&[60, 120, 90, 30, 200]), "5m", "back to back: five minutes already hits");
        assert_eq!(cache_ttl_for(&[86_400, 90_000, 80_000, 100_000, 86_000]), "5m", "days apart: neither hits, the cheaper write wins");
        assert_eq!(cache_ttl_for(&[600, 600]), "5m", "too few to judge");
    }

    #[test]
    fn tuning_stays_in_range_and_habits_become_one_block() {
        let t = Tuning { cache: "2h".into(), clear_tool_results_after: 0, effort: Some("max".into()), habits: vec!["Check the date first.".into(), " ".into()], ..Tuning::default() }.clamp();
        assert_eq!((t.cache.as_str(), t.clear_tool_results_after, t.effort.as_deref()), ("auto", 2, None));
        assert_eq!(t.habits_block().unwrap(), "Habits that proved to help you in your own work (keep them):\n- Check the date first.");
    }

    #[tokio::test]
    async fn a_change_is_kept_and_undone() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("agents.json"), r#"[{"id":"a1","name":"A","model":"anthropic:claude-haiku-4-5","job":"j","created_at":1}]"#).unwrap();
        let t = Team::open(dir.path()).unwrap();
        let c = t.apply_change("a1", "habit", "Learned to check the date", "nightly", Some(Tuning { habits: vec!["Check the date.".into()], ..Tuning::default() }), None, None).await.unwrap();
        assert_eq!(t.tuning("a1").habits.len(), 1);
        t.undo_change("a1", &c.id).await.unwrap();
        assert!(t.tuning("a1").habits.is_empty());
        assert!(t.undo_change("a1", &c.id).await.is_err(), "only once");
        assert_eq!(t.evolution("a1")[0].state, "undone");
    }
}
