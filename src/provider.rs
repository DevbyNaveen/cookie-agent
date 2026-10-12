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
    fn the_answer_must_be_json_with_the_required_keys() {
        let schema = json!({"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]});
        assert!(check_output(&schema, r#"{"city": "Riga", "extra": 1}"#).is_ok());
        for (answer, reason) in [("Sure! Riga.", "not JSON"), (r#"{"town": "Riga"}"#, "city"), (r#"["Riga"]"#, "object")] {
            assert!(matches!(check_output(&schema, answer), Err(crate::Error::Provider(m)) if m.contains(reason)), "{answer}");
        }
        assert!(check_output(&json!({"type": "array"}), "[1, 2]").is_ok());
    }
}
