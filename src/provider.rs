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
}

pub struct ModelRequest<'a> {
    pub model: &'a str,
    pub system: &'a str,
    pub messages: &'a [Message],
    pub tools: Vec<&'a ToolSpec>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ModelResponse {
    pub content: Vec<Content>,
    pub stop: StopReason,
    pub usage: Usage,
}

#[async_trait]
pub trait Provider: Send + Sync {
    async fn complete(&self, request: ModelRequest<'_>) -> Result<ModelResponse>;
}
