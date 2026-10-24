//! The one thing a model backend has to do.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::{error::Result, message::{Content, Message}, tool::ToolSpec};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    /// Input tokens served from the provider's prompt cache.
    #[serde(default)]
    pub cache_read_tokens: u64,
    /// Input tokens written to the provider's prompt cache.
    #[serde(default)]
    pub cache_write_tokens: u64,
}

/// The arguments of a tool call that were not valid JSON, carried to the
/// call itself so it can be answered with what was wrong and the model can
/// send it again (`calls::run_calls`).
pub const MALFORMED_ARGS: &str = "__malformed_arguments__";

pub(crate) fn malformed_args(raw: &str, error: &serde_json::Error) -> serde_json::Value {
    let raw: String = raw.chars().take(300).collect();
    serde_json::json!({ MALFORMED_ARGS: format!("{error} in: {raw}") })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    EndTurn,
    ToolUse,
    MaxTokens,
    /// The provider paused a long turn: send the conversation again as it
    /// is, and the model carries on.
    PauseTurn,
}

/// How hard the model should think before answering. Each provider maps it
/// to its own setting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Effort {
    Low,
    Medium,
    High,
}

impl Effort {
    pub fn as_str(self) -> &'static str {
        match self {
            Effort::Low => "low",
            Effort::Medium => "medium",
            Effort::High => "high",
        }
    }
}

/// Where the turn in progress begins: the last instruction (the person's
/// words, a task, a note), not counting tool results. Reasoning is sent back
/// only from here on — the API needs it there, ignores it before, and older
/// turns may have been edited (cleared output, summaries), which would make
/// it invalid.
pub(crate) fn current_turn_start(messages: &[crate::message::Message]) -> usize {
    use crate::message::{Content, Role};
    messages
        .iter()
        .rposition(|m| m.role() == Role::User && !m.content().iter().any(|c| matches!(c, Content::ToolResult { .. })))
        .unwrap_or(0)
}

#[derive(Default)]
pub struct ModelRequest<'a> {
    pub model: &'a str,
    pub system: &'a str,
    pub messages: &'a [Message],
    pub tools: Vec<&'a ToolSpec>,
    /// Reasoning effort; the provider's own default when `None`.
    pub reasoning: Option<Effort>,
    /// A JSON Schema the final answer must follow.
    pub output_schema: Option<&'a serde_json::Value>,
}

/// Is `answer` JSON, and does it have the schema's top-level shape (an
/// object when the schema says so, with every `required` key)?
pub fn check_output(schema: &serde_json::Value, answer: &str) -> Result<()> {
    let value: serde_json::Value = serde_json::from_str(answer.trim())
        .map_err(|e| crate::Error::Provider(format!("the answer is not JSON ({e}), but an output schema was set")))?;
    if schema["type"] == "object" {
        let Some(object) = value.as_object() else {
            return Err(crate::Error::Provider("the answer is not a JSON object, as the output schema requires".into()));
        };
        for key in schema["required"].as_array().into_iter().flatten().filter_map(|k| k.as_str()) {
            if !object.contains_key(key) {
                return Err(crate::Error::Provider(format!("the answer has no `{key}`, which the output schema requires")));
            }
        }
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq)]
pub struct ModelResponse {
    pub content: Vec<Content>,
    pub stop: StopReason,
    pub usage: Usage,
}

/// What a provider reports while a reply is still arriving.
#[derive(Debug, Clone, PartialEq)]
pub enum ProviderEvent {
    TextDelta(String),
    ToolCallStarted { id: String, name: String },
}

/// Prompt-cache lifetime for the stable prefix (tools and system), from
/// `COOKIE_PROMPT_CACHE_TTL`: `1h` keeps it an hour between runs instead of
/// the default five minutes — for a person who asks something now and again,
/// which a 5-minute cache never serves. Only Claude models from 4.5 on take
/// it (Bedrock refuses `ttl` on 3.x with a ValidationException); anything
/// else, or the variable unset, keeps the default and sends no `ttl`.
/// The conversation's own breakpoint stays at five minutes: a longer entry
/// must come before a shorter one, and tools and system come first.
pub fn prefix_cache_ttl(model: &str) -> Option<&'static str> {
    let wanted = std::env::var("COOKIE_PROMPT_CACHE_TTL").ok()?;
    (wanted.trim() == "1h" && hour_cache_supported(model)).then_some("1h")
}

/// Claude 4.5 and later, by id: `claude-sonnet-4-6`, `eu.anthropic.claude-opus-5-5`, …
/// (the families Bedrock's prompt-caching table lists with a 1-hour TTL).
pub fn hour_cache_supported(model: &str) -> bool {
    let Some(at) = model.find("claude-") else { return false };
    // `<tier>-<major>[-<minor>][-<date>…]`, or the 3.x naming `3-7-sonnet-…`;
    // a date is eight digits, never a minor.
    let mut parts = model[at + "claude-".len()..].split(['-', '@', ':', '.']).peekable();
    let number = |part: Option<&str>| part.filter(|p| (1..=2).contains(&p.len())).and_then(|p| p.parse::<u32>().ok());
    if number(parts.peek().copied()).is_none() {
        parts.next();
    }
    let Some(major) = number(parts.next()) else { return false };
    let minor = number(parts.next()).unwrap_or(0);
    (major, minor) >= (4, 5)
}

#[async_trait]
pub trait Provider: Send + Sync {
    async fn complete(&self, request: ModelRequest<'_>) -> Result<ModelResponse>;

    /// Like `complete`, reporting progress as it arrives. The default waits
    /// for the whole reply and reports it at once.
    async fn stream(
        &self,
        request: ModelRequest<'_>,
        on: &mut (dyn FnMut(ProviderEvent) + Send),
    ) -> Result<ModelResponse> {
        let response = self.complete(request).await?;
        for content in &response.content {
            match content {
                Content::Text { text } if !text.is_empty() => on(ProviderEvent::TextDelta(text.clone())),
                Content::ToolCall { id, name, .. } => {
                    on(ProviderEvent::ToolCallStarted { id: id.clone(), name: name.clone() })
                }
                _ => {}
            }
        }
        Ok(response)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_claude_after_three_keeps_a_cache_for_an_hour() {
        for yes in ["claude-sonnet-4-6", "eu.anthropic.claude-sonnet-4-6", "anthropic.claude-haiku-4-5-20251001-v1:0", "claude-opus-5-5", "claude-opus-5", "eu.anthropic.claude-fable-5-1"] {
            assert!(hour_cache_supported(yes), "{yes}");
        }
        for no in ["anthropic.claude-3-7-sonnet-20250219-v1:0", "claude-3-5-haiku-latest", "claude-sonnet-4-20250514", "claude-opus-4-1-20250805",
                   "amazon.nova-pro-v1:0", "gpt-6"] {
            assert!(!hour_cache_supported(no), "{no}");
        }
    }

    #[test]
    fn the_answer_must_be_json_with_the_required_keys() {
        let schema = json!({"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]});
        assert!(check_output(&schema, r#"{"city": "Riga", "extra": 1}"#).is_ok());
        for (answer, reason) in [("Sure! Riga.", "not JSON"), (r#"{"town": "Riga"}"#, "city"), (r#"["Riga"]"#, "object")] {
            assert!(matches!(check_output(&schema, answer), Err(crate::Error::Provider(m)) if m.contains(reason)), "{answer}");
        }
        assert!(check_output(&json!({"type": "array"}), "[1, 2]").is_ok());
    }
}
