//! Hard limits. A cap that only warns is not a cap.

use serde_json::Value;

use crate::{
    error::{Error, Result},
    provider::Usage,
};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Budget {
    /// Model calls per run.
    pub max_steps: usize,
    /// Input, output and cache-written tokens per run. Cache reads are left
    /// out: they re-read what a call already counted, and at a tenth of the
    /// price they are the dollar cap's to weigh. Counting them made a run
    /// with a growing, cached history stop after a few calls.
    pub max_tokens: u64,
    /// Dollars per run, priced with `Agent::prices`. A cap with no prices is
    /// refused rather than ignored.
    pub max_dollars: Option<f64>,
}

impl Budget {
    /// The stricter of two budgets, limit by limit.
    pub fn min(&self, other: &Budget) -> Budget {
        Budget {
            max_steps: self.max_steps.min(other.max_steps),
            max_tokens: self.max_tokens.min(other.max_tokens),
            max_dollars: match (self.max_dollars, other.max_dollars) {
                (Some(a), Some(b)) => Some(a.min(b)),
                (a, b) => a.or(b),
            },
        }
    }
}

/// One budget a run draws from live: what has been spent against it, and its cap.
pub(crate) type Pool = (std::sync::Arc<std::sync::Mutex<crate::tool::Spend>>, Budget);

impl Default for Budget {
    fn default() -> Self {
        Self { max_steps: 25, max_tokens: 200_000, max_dollars: None }
    }
}

/// What a model costs, in dollars per million tokens. You supply it: the
/// harness ships no price table, because prices change and a stale one lies.
#[derive(Debug, Clone, Copy, PartialEq, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Price {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_write: f64,
}

impl Price {
    /// Every price a finite number, zero or more: a bad price would make every
    /// call cost nothing and the cap never trip.
    pub(crate) fn check(&self) -> Result<()> {
        let all = [self.input, self.output, self.cache_read, self.cache_write];
        if all.iter().all(|p| p.is_finite() && *p >= 0.0) {
            Ok(())
        } else {
            Err(Error::Budget(format!("prices must be numbers of zero or more: {self:?}")))
        }
    }

    /// Millionths of a dollar for this usage, rounded up.
    pub fn microdollars(&self, usage: &Usage) -> u64 {
        let micro = usage.input_tokens as f64 * self.input
            + usage.output_tokens as f64 * self.output
            + usage.cache_read_tokens as f64 * self.cache_read
            + usage.cache_write_tokens as f64 * self.cache_write;
        micro.ceil() as u64
    }
}

fn cap_microdollars(dollars: f64) -> u64 {
    (dollars * 1_000_000.0).floor() as u64
}

#[derive(Debug, Default)]
pub(crate) struct Meter {
    steps: usize,
    tokens: u64,
    microdollars: u64,
    /// A sub-agent's: the pools of every batch above it, nearest last. Each
    /// of its model calls is charged to all of them at once and checked
    /// against all of them, so siblings — and their children — share what is
    /// left at every level instead of each taking all of it.
    pools: Vec<Pool>,
}

impl Meter {
    pub(crate) fn pooled(pools: Vec<Pool>) -> Self {
        Self { pools, ..Self::default() }
    }

    /// The pools above this meter, for a batch of tool calls to extend.
    pub(crate) fn pools(&self) -> Vec<Pool> {
        self.pools.clone()
    }

    /// Check every limit and take one model call from this meter and every
    /// pool above it in one step, so two siblings can't both take the last
    /// call. Call it right before the model call it pays for.
    /// ponytail: tokens and dollars are only known after the call, so calls
    /// already in flight can overshoot those two caps; steps never overshoot.
    pub(crate) fn begin_call(&mut self, budget: &Budget) -> Result<()> {
        self.check(budget)?;
        // Locked top-down, the same order everywhere, so no two meters deadlock.
        let mut pools: Vec<_> = self.pools.iter().map(|(pool, cap)| (pool.lock().expect("pool lock"), cap)).collect();
        if let Some((pool, cap)) = pools.iter().find(|(pool, cap)| pool.steps >= cap.max_steps) {
            return Err(Error::Budget(format!("the parent's budget is spent ({} model calls, limit {})", pool.steps, cap.max_steps)));
        }
        for (pool, _) in pools.iter_mut() {
            pool.steps += 1;
        }
        self.steps += 1;
        Ok(())
    }

    /// The one model call past a limit that turns what a run found into its
    /// answer (`Agent::close_with_answer`): counted, never refused. It may
    /// spend past the dollar cap by that one call.
    pub(crate) fn begin_closing(&mut self) {
        for (pool, _) in &self.pools {
            pool.lock().expect("pool lock").steps += 1;
        }
        self.steps += 1;
    }

    /// The tokens and dollars of a call `begin_call` already counted.
    pub(crate) fn charge(&mut self, usage: &Usage, price: Option<&Price>) {
        let tokens = usage.input_tokens + usage.output_tokens + usage.cache_write_tokens;
        let microdollars = price.map_or(0, |p| p.microdollars(usage));
        let spend = crate::tool::Spend { steps: 0, tokens, microdollars };
        self.count(spend);
        for (pool, _) in &self.pools {
            let mut pool = pool.lock().expect("pool lock");
            pool.steps += spend.steps;
            pool.tokens += spend.tokens;
            pool.microdollars += spend.microdollars;
        }
    }

    fn count(&mut self, spend: crate::tool::Spend) {
        self.steps += spend.steps;
        self.tokens += spend.tokens;
        self.microdollars += spend.microdollars;
    }

    /// What is left of `budget` after what this meter has counted.
    pub(crate) fn remaining(&self, budget: &Budget) -> Budget {
        Budget {
            max_steps: budget.max_steps.saturating_sub(self.steps),
            max_tokens: budget.max_tokens.saturating_sub(self.tokens),
            max_dollars: budget.max_dollars.map(|d| (d - self.microdollars as f64 / 1_000_000.0).max(0.0)),
        }
    }

    /// Count what a sub-agent spent on this run's behalf. It already reached
    /// every pool above this meter live, so only this meter counts it now.
    pub(crate) fn absorb(&mut self, spend: crate::tool::Spend) {
        self.count(spend);
    }

    pub(crate) fn spent(&self) -> crate::tool::Spend {
        crate::tool::Spend { steps: self.steps, tokens: self.tokens, microdollars: self.microdollars }
    }

    pub(crate) fn check(&self, budget: &Budget) -> Result<()> {
        for (pool, cap) in &self.pools {
            let pool = pool.lock().expect("pool lock");
            let over_dollars = cap.max_dollars.is_some_and(|d| pool.microdollars >= cap_microdollars(d));
            if pool.steps >= cap.max_steps || pool.tokens >= cap.max_tokens || over_dollars {
                return Err(Error::Budget(format!("the parent's budget is spent ({} model calls, {} tokens)", pool.steps, pool.tokens)));
            }
        }
        if self.steps >= budget.max_steps {
            return Err(Error::Budget(format!("{} model calls (limit {})", self.steps, budget.max_steps)));
        }
        if self.tokens >= budget.max_tokens {
            return Err(Error::Budget(format!("{} tokens (limit {})", self.tokens, budget.max_tokens)));
        }
        if let Some(dollars) = budget.max_dollars {
            if self.microdollars >= cap_microdollars(dollars) {
                return Err(Error::Budget(format!(
                    "${:.6} spent (limit ${dollars:.6})",
                    self.microdollars as f64 / 1_000_000.0
                )));
            }
        }
        Ok(())
    }
}

#[derive(Debug, Default)]
pub(crate) struct LoopGuard {
    /// The most recent calls, newest last.
    recent: std::collections::VecDeque<String>,
    /// Changes that already worked this run, by call: the same change is
    /// answered from here and never sent twice.
    done: std::collections::HashMap<String, String>,
    /// Requests the person said no to, in a row.
    declined: usize,
    /// A tool that must be checked afterwards (`Agent::check_after`) worked,
    /// and nothing has read anything since.
    unchecked: Vec<crate::verification::Pending>,
    /// Calls already warned about repeating: the next repeat stops the run.
    warned: std::collections::HashSet<String>,
}

/// What a repeated call comes to.
#[derive(Debug, PartialEq)]
pub(crate) enum Seen {
    Fine,
    /// Not run: the model is told it is going round in circles, once.
    Warned(String),
}

/// Three noes in a row: the person does not want what this run is doing.
const DECLINED_IN_A_ROW: usize = 3;

/// The same call three times in a row is a loop; so is one call coming back
/// a fourth time among the last twelve (a cycle such as a, b, a, b, …).
const IN_A_ROW: usize = 3;
const WINDOW: usize = 12;
const IN_WINDOW: usize = 4;

impl LoopGuard {
    /// A call about to run. The first time it repeats past the limit it is
    /// not run and the model is told so (it may be one step from an answer);
    /// repeating it after that stops the run.
    pub(crate) fn see(&mut self, name: &str, args: &Value) -> Result<Seen> {
        let key = format!("{name}{args}");
        if self.recent.len() == WINDOW {
            self.recent.pop_front();
        }
        self.recent.push_back(key.clone());
        let in_a_row = self.recent.iter().rev().take_while(|k| **k == key).count();
        let in_window = self.recent.iter().filter(|k| **k == key).count();
        if in_a_row >= IN_A_ROW || in_window >= IN_WINDOW {
            if !self.warned.insert(key) {
                return Err(Error::Loop(name.to_string()));
            }
            return Ok(Seen::Warned(format!(
                "Not run: `{name}` was already called with these same arguments {} times and gave the same. Try another \
                 way, or answer with what you have. Calling it again like this stops the job.",
                in_window.max(in_a_row) - 1
            )));
        }
        Ok(Seen::Fine)
    }

    /// What this exact change returned, if it already worked this run.
    pub(crate) fn already_done(&self, name: &str, args: &Value) -> Option<&str> {
        self.done.get(&format!("{name}{args}")).map(String::as_str)
    }

    /// A change worked: remember what it returned.
    pub(crate) fn did(&mut self, name: &str, args: &Value, output: &str) {
        let kept: String = output.chars().take(400).collect();
        self.done.insert(format!("{name}{args}"), kept);
    }

    /// The person answered a request. `true` once they have said no three
    /// times in a row.
    pub(crate) fn answered(&mut self, yes: bool) -> bool {
        self.declined = if yes { 0 } else { self.declined + 1 };
        self.declined >= DECLINED_IN_A_ROW
    }

    pub(crate) fn pending_check(&mut self, tool: String, args: Value) {
        self.unchecked.push(crate::verification::Pending { tool, args });
    }

    pub(crate) fn observe_read(&mut self, name: &str, output: &str, rules: &[crate::verification::VerificationRule]) {
        let Ok(value) = serde_json::from_str::<Value>(output) else { return };
        self.unchecked.retain(|p| !rules.iter().any(|r| r.write_tool == p.tool && r.proves(&p.args, name, &value)));
    }

    /// All unresolved changes get one reminder; this is not a verified receipt.
    pub(crate) fn take_unchecked(&mut self) -> Option<String> {
        if self.unchecked.is_empty() { return None }
        Some(std::mem::take(&mut self.unchecked).into_iter().map(|p| p.tool).collect::<Vec<_>>().join(", "))
    }

}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cache_writes_count_against_the_budget_and_reads_do_not() {
        let cap = Budget { max_steps: 10, max_tokens: 1_000, max_dollars: None };
        let mut meter = Meter::default();
        meter.charge(&Usage { input_tokens: 1, output_tokens: 1, cache_read_tokens: 50_000, cache_write_tokens: 0 }, None);
        assert!(meter.check(&cap).is_ok(), "re-reading a cached history is not new tokens");
        meter.charge(&Usage { input_tokens: 1, output_tokens: 1, cache_read_tokens: 0, cache_write_tokens: 1_000 }, None);
        assert!(matches!(meter.check(&cap), Err(Error::Budget(_))));
        meter.begin_closing();
        assert_eq!(meter.steps, 1, "the closing call is counted, never refused");
    }

    #[test]
    fn a_change_is_remembered_and_three_noes_in_a_row_stop_but_a_yes_resets() {
        use serde_json::json;
        let mut guard = LoopGuard::default();
        let args = json!({"deal": 7, "stage": "won"});
        assert_eq!(guard.already_done("update_deal", &args), None);
        guard.did("update_deal", &args, "Deal 7 moved to won.");
        assert_eq!(guard.already_done("update_deal", &args), Some("Deal 7 moved to won."));
        assert_eq!(guard.already_done("update_deal", &json!({"deal": 7, "stage": "lost"})), None);
        assert!(!guard.answered(false));
        assert!(!guard.answered(false));
        assert!(!guard.answered(true), "a yes resets the count");
        assert!(!guard.answered(false));
        assert!(!guard.answered(false));
        assert!(guard.answered(false), "three in a row");
    }

    #[test]
    fn a_cycle_between_calls_is_a_loop_but_occasional_repeats_are_not() {
        use serde_json::json;
        let (a, b) = (json!({"x": 1}), json!({"x": 2}));
        let mut guard = LoopGuard::default();
        let mut warned = false;
        for (name, args) in [("a", &a), ("b", &b), ("a", &a), ("b", &b), ("a", &a), ("b", &b), ("a", &a)] {
            warned |= matches!(guard.see(name, args), Ok(Seen::Warned(_)));
        }
        assert!(warned, "a,b,a,b,a,b,a is a loop: warned first");
        assert!(guard.see("a", &a).is_err(), "and the next repeat stops it");
        let mut guard = LoopGuard::default();
        for (i, name) in ["a", "c", "a", "d", "a", "e", "f"].iter().enumerate() {
            assert_eq!(guard.see(name, &json!({"x": if *name == "a" { 0 } else { i }})).unwrap(), Seen::Fine, "three a's spread out are fine");
        }
        let mut guard = LoopGuard::default();
        assert_eq!(guard.see("x", &a).unwrap(), Seen::Fine);
        assert_eq!(guard.see("x", &a).unwrap(), Seen::Fine);
        assert!(matches!(guard.see("x", &a), Ok(Seen::Warned(w)) if w.contains("2 times")));
        assert!(guard.see("x", &a).is_err());
    }
}
