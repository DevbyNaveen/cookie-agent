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
