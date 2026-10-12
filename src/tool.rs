//! A tool is a plain function with a JSON schema and an effect class.

use std::{
    future::Future,
    marker::PhantomData,
    sync::{Arc, Mutex},
};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio_util::sync::CancellationToken;

use crate::{budget::Budget, policy::Provenance};

/// What running the tool does to the world.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Effect {
    /// Looks something up.
    Read,
    /// Changes something the person owns.
    Write,
    /// Sends, posts or publishes to someone else.
    Outbound,
    /// Deletes, pays or buys.
    Destroy,
}

impl Effect {
    /// Outbound and destroy always ask a person. Nothing earns them.
    pub fn needs_person(self) -> bool {
        matches!(self, Effect::Outbound | Effect::Destroy)
    }
}

/// What every provider accepts as a tool name: 1–64 of letters, digits, `_`, `-`.
pub fn valid_tool_name(name: &str) -> bool {
    (1..=64).contains(&name.len()) && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

#[derive(Debug, Clone)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    pub schema: Value,
    pub effect: Effect,
    /// Arguments that pick who, where or how much (recipient, url, amount).
    /// Their values must come from the person, never from content they didn't write.
    /// Guard them on every effect class, `Read` included: a fetch URL can carry
    /// data out. A name is a top-level argument; `/a/b` is a JSON pointer.
    pub guarded_args: Vec<String>,
    /// Safe to run at the same time as other calls in one turn.
    pub parallel_safe: bool,
}

/// Model calls and tokens a tool spent on the run's behalf (a sub-agent's).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Spend {
    pub steps: usize,
    pub tokens: u64,
}

/// What a tool call knows about the run it belongs to. Ordinary tools
/// ignore it; a sub-agent uses it to inherit trust, budget and cancellation.
#[derive(Debug, Clone, Default)]
pub struct ToolContext {
    pub(crate) cancel: CancellationToken,
    pub(crate) provenance: Provenance,
    /// What is left of the run's budget.
    pub(crate) budget: Budget,
    /// How many delegations deep this call is.
    pub(crate) depth: usize,
    pub(crate) spend: Arc<Mutex<Spend>>,
}

#[async_trait]
pub trait Tool: Send + Sync {
    fn spec(&self) -> &ToolSpec;

    async fn call(&self, args: Value) -> std::result::Result<String, String>;

    /// Called by the loop. The default ignores the context.
    async fn call_in(&self, args: Value, _context: &ToolContext) -> std::result::Result<String, String> {
        self.call(args).await
    }

    /// True for a sub-agent: used to keep one writer per tree.
    fn is_subagent(&self) -> bool {
        false
    }

    /// What will actually happen, shown to a person before outbound or destroy.
    fn preview(&self, args: &Value) -> String {
        format!("{} {}", self.spec().name, args)
    }
}

type PreviewFn = Box<dyn Fn(&Value) -> String + Send + Sync>;

pub struct FnTool<F, Fut> {
    spec: ToolSpec,
    f: F,
    preview: Option<PreviewFn>,
    _fut: PhantomData<fn() -> Fut>,
}

/// Turn an async function into a tool.
pub fn tool<F, Fut>(name: &str, description: &str, schema: Value, effect: Effect, f: F) -> FnTool<F, Fut>
where
    F: Fn(Value) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = std::result::Result<String, String>> + Send + 'static,
{
    FnTool {
        spec: ToolSpec {
            name: name.to_string(),
            description: description.to_string(),
            schema,
            effect,
            guarded_args: Vec::new(),
            parallel_safe: false,
        },
        f,
        preview: None,
        _fut: PhantomData,
    }
}

impl<F, Fut> FnTool<F, Fut> {
    pub fn guard(mut self, arg: &str) -> Self {
        self.spec.guarded_args.push(arg.to_string());
        self
    }

    pub fn parallel_safe(mut self) -> Self {
        self.spec.parallel_safe = true;
        self
    }

    pub fn with_preview(mut self, preview: impl Fn(&Value) -> String + Send + Sync + 'static) -> Self {
        self.preview = Some(Box::new(preview));
        self
    }
}

#[async_trait]
impl<F, Fut> Tool for FnTool<F, Fut>
where
    F: Fn(Value) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = std::result::Result<String, String>> + Send + 'static,
{
    fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    async fn call(&self, args: Value) -> std::result::Result<String, String> {
        (self.f)(args).await
    }

    fn preview(&self, args: &Value) -> String {
        match &self.preview {
            Some(preview) => preview(args),
            None => format!("{} {}", self.spec.name, args),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn send_email() -> impl Tool {
        tool("send_email", "Send an email", json!({"type": "object"}), Effect::Outbound, |args| async move {
            Ok(format!("sent to {}", args["to"]))
        })
        .guard("to")
        .with_preview(|args| format!("Send an email to {} saying {}", args["to"], args["body"]))
    }

    #[test]
    fn effect_classes_that_need_a_person() {
        assert!(!Effect::Read.needs_person());
        assert!(!Effect::Write.needs_person());
        assert!(Effect::Outbound.needs_person());
        assert!(Effect::Destroy.needs_person());
    }

    #[tokio::test]
    async fn a_function_becomes_a_tool() {
        let t = send_email();
        assert_eq!(t.spec().name, "send_email");
        assert_eq!(t.spec().guarded_args, vec!["to".to_string()]);
        assert!(!t.spec().parallel_safe);
        assert_eq!(t.call(json!({"to": "anna@x.com"})).await.unwrap(), "sent to \"anna@x.com\"");
        assert_eq!(t.preview(&json!({"to": "anna@x.com", "body": "hi"})), "Send an email to \"anna@x.com\" saying \"hi\"");
    }
}
