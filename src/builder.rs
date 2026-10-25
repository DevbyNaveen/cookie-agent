//! Building an `Agent`: plain data, set field by field. The loop that runs
//! it is in `agent.rs`.

use std::sync::Arc;

use crate::{
    agent::Agent,
    approval::Approver,
    budget::{Budget, Price},
    compaction::Compaction,
    enkeon::Enkeon,
    error::Result,
    model_id::ModelId,
    policy::Policy,
    provider::{Effort, Provider},
    providers, telemetry,
    tool::{Effect, Tool},
    tool_search::ToolSearch,
    trust::EarnedTrust,
};

impl Agent {
    /// `provider:model`, e.g. "anthropic:claude-sonnet-4-6". There is no default.
    pub fn new(model_id: &str) -> Result<Self> {
        let id = ModelId::parse(model_id)?;
        let provider = providers::resolve(&id)?;
        let mut agent = Self::with_provider(provider, id.model);
        agent.provider_name = Some(telemetry::provider_name(&id.provider));
        Ok(agent)
    }

    pub fn with_provider(provider: Arc<dyn Provider>, model: impl Into<String>) -> Self {
        Self {
            model: model.into(),
            provider,
            instructions: String::new(),
            tools: Vec::new(),
            policy: Policy::default(),
            approver: None,
            budget: Budget::default(),
            price: None,
            trust: None,
            tool_search: None,
            compaction: None,
            // On by default when ENKEON_API_KEY is set; never in this crate's own tests.
            enkeon: if cfg!(test) { None } else { Enkeon::from_env().map(Arc::new) },
            provider_name: None,
            reasoning: None,
            output_schema: None,
            check_after: Vec::new(),
            verification: Vec::new(),
            action_ledger: None,
            close_with_answer: false,
            finish_check: false,
            trace: None,
        }
    }

    /// Models to ask, in order, when the one before is out of reach
    /// (throttled, overloaded, broken on its side, silent) and none of its
    /// reply has arrived yet; each `provider:model`. Every fallback is an
    /// `Event::FellBack`.
    pub fn fallback_models<S: AsRef<str>>(self, ids: impl IntoIterator<Item = S>) -> Result<Self> {
        let then = ids
            .into_iter()
            .map(|id| {
                let id = ModelId::parse(id.as_ref())?;
                Ok((id.model.clone(), providers::resolve(&id)?))
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(self.fallbacks(then))
    }

    /// The same with providers already made: `(model, provider)`.
    pub fn fallbacks(mut self, then: Vec<(String, Arc<dyn Provider>)>) -> Self {
        if !then.is_empty() {
            self.provider = Arc::new(providers::fallback::Fallback::new(self.provider, then));
        }
        self
    }

    /// Keep a tamper-evident log of this run's actions (`trace::TraceLog`).
    pub fn trace(mut self, tracer: crate::trace::Tracer) -> Self {
        self.trace = Some(tracer);
        self
    }

    pub fn instructions(mut self, text: impl Into<String>) -> Self {
        self.instructions = text.into();
        self
    }

    /// Persist admission of non-read tool calls across process restarts.
    /// Existing policy and approvals still apply before every admission.
    pub fn action_ledger(mut self, ledger: crate::durable::ActionLedger) -> Self {
        self.action_ledger = Some(ledger);
        self
    }

    pub fn tool(self, tool: impl Tool + 'static) -> Self {
        self.tools([Arc::new(tool) as Arc<dyn Tool>])
    }

    /// Add shared tools, e.g. `McpTools::tools` from an MCP server.
    pub fn tools(mut self, tools: impl IntoIterator<Item = Arc<dyn Tool>>) -> Self {
        for tool in tools {
            let spec = tool.spec();
            if matches!(spec.effect, Effect::Outbound | Effect::Destroy) && spec.guarded_args.is_empty() && !spec.delegates {
                tracing::warn!(tool = %spec.name, "a tool that sends or deletes has no guarded argument: who or what it acts on is not checked");
            }
            self.tools.push(tool);
        }
        self
    }

    pub fn policy(mut self, policy: Policy) -> Self {
        self.policy = policy;
        self
    }

    pub fn approver(mut self, approver: impl Approver + 'static) -> Self {
        self.approver = Some(Arc::new(approver));
        self
    }

    pub fn budget(mut self, budget: Budget) -> Self {
        self.budget = budget;
        self
    }

    /// Let a person's repeated approvals of a `write` tool stand: after the
    /// streak, it runs without asking (and `Event::RanOnEarnedTrust` says so).
    /// Tools that send, delete or pay always ask.
    pub fn earned_trust(mut self, trust: EarnedTrust) -> Self {
        self.trust = Some(trust);
        self
    }

    /// Past `after` tools, send a `search_tools` tool instead of them all.
    pub fn tool_search(mut self, search: ToolSearch) -> Self {
        self.tool_search = Some(search);
        self
    }

    /// What this agent's model costs, so `Budget::max_dollars` can be enforced.
    pub fn prices(mut self, price: Price) -> Self {
        self.price = Some(price);
        self
    }

    /// Use this Enkeon account instead of `ENKEON_API_KEY`.
    pub fn enkeon(mut self, enkeon: Enkeon) -> Self {
        self.enkeon = Some(Arc::new(enkeon));
        self
    }

    /// No Enkeon, even with a key set.
    pub fn without_enkeon(mut self) -> Self {
        self.enkeon = None;
        self
    }

    /// Cookie's own notes at `path` (`notes.rs`), for an agent with no Enkeon
    /// account: the notes ride in the instructions, and `note` / `forget_note`
    /// keep them. With Enkeon, nothing changes: context has one place to go.
    /// Call it after `instructions`, which replaces them.
    pub fn notes(mut self, path: std::path::PathBuf) -> Self {
        if self.enkeon.is_some() {
            return self;
        }
        let mut more = vec![crate::notes::NOTES_INSTRUCTIONS.to_string()];
        more.extend(crate::notes::block(&crate::notes::load(&path)));
        for text in more {
            if !self.instructions.is_empty() {
                self.instructions.push_str("\n\n");
            }
            self.instructions.push_str(&text);
        }
        self.tools.extend(crate::notes::tools(path));
        self
    }

    /// How hard the model thinks; its reasoning is kept for the provider
    /// that wrote it and never shown as the answer.
    pub fn reasoning(mut self, effort: Effort) -> Self {
        self.reasoning = Some(effort);
        self
    }

    /// The final answer must be JSON following this schema; one that isn't
    /// is an error, not an answer.
    pub fn output_schema(mut self, schema: serde_json::Value) -> Self {
        self.output_schema = Some(schema);
        self
    }

    /// Keep long sessions within reach. Off unless set.
    pub fn compaction(mut self, compaction: Compaction) -> Self {
        self.compaction = Some(compaction);
        self
    }

    /// Tools whose working is not proof of the result — an update in someone
    /// else's app. A run that used one and read nothing after is asked, once,
    /// to check before it finishes.
    pub fn verify_with(mut self, rules: Vec<crate::verification::VerificationRule>) -> Result<Self> {
        if rules.iter().any(|r| !r.validate()) {
            return Err(crate::Error::Tool("verification needs a valid read tool, identity and expected fields".into()));
        }
        for rule in &rules {
            if !self.check_after.contains(&rule.write_tool) { self.check_after.push(rule.write_tool.clone()); }
        }
        self.verification = rules;
        Ok(self)
    }

    pub fn check_after(mut self, tools: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.check_after = tools.into_iter().map(Into::into).collect();
        self
    }

    /// End with an answer instead of an error: a run that reaches its budget,
    /// or is asked to finish its turn, makes one more model call that writes
    /// the answer from what it found and says what it did not get to.
    pub fn close_with_answer(mut self) -> Self {
        self.close_with_answer = true;
        self
    }

    /// Send a top-level answer back once when it ends by offering work it
    /// could have done ("want me to draft them?") or by handing the job back
    /// to the person, with a note to do that work now.
    pub fn finish_check(mut self) -> Self {
        self.finish_check = true;
        self
    }
}
