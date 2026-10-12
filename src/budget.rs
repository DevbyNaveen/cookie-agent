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
}

impl Meter {
    pub(crate) fn charge(&mut self, usage: &Usage) {
        self.steps += 1;
        self.tokens += usage.input_tokens + usage.output_tokens + usage.cache_read_tokens + usage.cache_write_tokens;
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
        self.steps += spend.steps;
        self.tokens += spend.tokens;
    }

    pub(crate) fn spent(&self) -> crate::tool::Spend {
        crate::tool::Spend { steps: self.steps, tokens: self.tokens }
    }

    pub(crate) fn check(&self, budget: &Budget) -> Result<()> {
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
    last: Option<String>,
    repeats: usize,
}

impl LoopGuard {
    pub(crate) fn see(&mut self, name: &str, args: &Value) -> Result<()> {
        let key = format!("{name}{args}");
        if self.last.as_deref() == Some(key.as_str()) {
            self.repeats += 1;
        } else {
            self.last = Some(key);
            self.repeats = 1;
        }
        if self.repeats >= 3 {
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
}
