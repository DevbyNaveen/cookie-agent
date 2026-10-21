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
            close_with_answer: false,
        }
    }

    pub fn instructions(mut self, text: impl Into<String>) -> Self {
        self.instructions = text.into();
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
}
