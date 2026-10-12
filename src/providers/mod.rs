//! `provider:model` → a provider. No defaults: an unknown name is an error.

use std::sync::Arc;

use crate::{error::{Error, Result}, model_id::ModelId, provider::Provider};

pub mod anthropic;
mod fence;
pub mod openai;
pub mod scripted;

pub fn resolve(id: &ModelId) -> Result<Arc<dyn Provider>> {
    match id.provider.as_str() {
        "anthropic" => Ok(Arc::new(anthropic::AnthropicProvider::from_env()?)),
        "openai" => Ok(Arc::new(openai::OpenAiProvider::openai_from_env()?)),
        "ollama" => Ok(Arc::new(openai::OpenAiProvider::ollama_from_env())),
        other => Err(Error::UnknownProvider(other.to_string())),
    }
}

/// An HTTP failure, keeping the status even when the body isn't JSON.
pub fn http_error(status: u16, body: &str) -> Error {
    let detail: String = body.chars().take(500).collect();
    Error::Provider(format!("HTTP {status}: {detail}"))
}
