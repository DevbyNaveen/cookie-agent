//! Hard limits. A cap that only warns is not a cap.

use serde_json::Value;

use crate::{
    error::{Error, Result},
    provider::Usage,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Budget {
    /// Model calls per run.
    pub max_steps: usize,
    /// Input, output and cached tokens per run.
    pub max_tokens: u64,
}

impl Default for Budget {
    fn default() -> Self {
        Self { max_steps: 25, max_tokens: 200_000 }
    }
}

#[derive(Debug, Default)]
pub(crate) struct Meter {
    steps: usize,
    tokens: u64,
    /// A sub-agent's: the pool its parent's batch draws from, and that
    /// pool's cap. Every charge lands there at once, so siblings running
    /// side by side share what is left instead of each taking all of it.
    pool: Option<(std::sync::Arc<std::sync::Mutex<crate::tool::Spend>>, Budget)>,
}

impl Meter {
    pub(crate) fn pooled(pool: std::sync::Arc<std::sync::Mutex<crate::tool::Spend>>, cap: Budget) -> Self {
        Self { pool: Some((pool, cap)), ..Self::default() }
    }

    pub(crate) fn charge(&mut self, usage: &Usage) {
        let tokens = usage.input_tokens + usage.output_tokens + usage.cache_read_tokens + usage.cache_write_tokens;
        self.add(crate::tool::Spend { steps: 1, tokens });
    }

    fn add(&mut self, spend: crate::tool::Spend) {
        self.steps += spend.steps;
        self.tokens += spend.tokens;
        if let Some((pool, _)) = &self.pool {
            let mut pool = pool.lock().expect("pool lock");
            pool.steps += spend.steps;
            pool.tokens += spend.tokens;
        }
    }

    /// What is left of `budget` after what this meter has counted.
    pub(crate) fn remaining(&self, budget: &Budget) -> Budget {
        Budget {
            max_steps: budget.max_steps.saturating_sub(self.steps),
            max_tokens: budget.max_tokens.saturating_sub(self.tokens),
        }
    }

    /// Count what a sub-agent spent on this run's behalf.
    pub(crate) fn absorb(&mut self, spend: crate::tool::Spend) {
        self.add(spend);
    }

    pub(crate) fn spent(&self) -> crate::tool::Spend {
        crate::tool::Spend { steps: self.steps, tokens: self.tokens }
    }

    pub(crate) fn check(&self, budget: &Budget) -> Result<()> {
        if let Some((pool, cap)) = &self.pool {
            let pool = pool.lock().expect("pool lock");
            if pool.steps >= cap.max_steps || pool.tokens >= cap.max_tokens {
                return Err(Error::Budget(format!("the parent's budget is spent ({} model calls, {} tokens)", pool.steps, pool.tokens)));
            }
        }
        if self.steps >= budget.max_steps {
            return Err(Error::Budget(format!("{} model calls (limit {})", self.steps, budget.max_steps)));
        }
        if self.tokens >= budget.max_tokens {
            return Err(Error::Budget(format!("{} tokens (limit {})", self.tokens, budget.max_tokens)));
        }
        Ok(())
    }
}

#[derive(Debug, Default)]
pub(crate) struct LoopGuard {
    /// The most recent calls, newest last.
    recent: std::collections::VecDeque<String>,
}

/// The same call three times in a row is a loop; so is one call coming back
/// a fourth time among the last twelve (a cycle such as a, b, a, b, …).
const IN_A_ROW: usize = 3;
const WINDOW: usize = 12;
const IN_WINDOW: usize = 4;

impl LoopGuard {
    pub(crate) fn see(&mut self, name: &str, args: &Value) -> Result<()> {
        let key = format!("{name}{args}");
        if self.recent.len() == WINDOW {
            self.recent.pop_front();
        }
        self.recent.push_back(key.clone());
        let in_a_row = self.recent.iter().rev().take_while(|k| **k == key).count();
        let in_window = self.recent.iter().filter(|k| **k == key).count();
        if in_a_row >= IN_A_ROW || in_window >= IN_WINDOW {
            return Err(Error::Loop(name.to_string()));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cached_tokens_count_against_the_budget() {
        let mut meter = Meter::default();
        meter.charge(&Usage { input_tokens: 1, output_tokens: 1, cache_read_tokens: 500, cache_write_tokens: 500 });
        assert!(matches!(meter.check(&Budget { max_steps: 10, max_tokens: 1_000 }), Err(Error::Budget(_))));
    }

    #[test]
    fn a_cycle_between_calls_is_a_loop_but_occasional_repeats_are_not() {
        use serde_json::json;
        let (a, b) = (json!({"x": 1}), json!({"x": 2}));
        let mut guard = LoopGuard::default();
        let mut out = Ok(());
        for (name, args) in [("a", &a), ("b", &b), ("a", &a), ("b", &b), ("a", &a), ("b", &b), ("a", &a)] {
            out = guard.see(name, args);
            if out.is_err() {
                break;
            }
        }
        assert!(out.is_err(), "a,b,a,b,a,b,a is a loop");
        let mut guard = LoopGuard::default();
        for (i, name) in ["a", "c", "a", "d", "a", "e", "f"].iter().enumerate() {
            assert!(guard.see(name, &json!({"x": if *name == "a" { 0 } else { i }})).is_ok(), "three a's spread out are fine");
        }
    }
}
