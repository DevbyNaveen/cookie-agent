//! `provider:model` → a provider. No defaults: an unknown name is an error.

use std::sync::Arc;

use crate::{error::{Error, Result}, model_id::ModelId, provider::Provider};

pub mod anthropic;
mod fence;
pub mod scripted;

pub fn resolve(id: &ModelId) -> Result<Arc<dyn Provider>> {
    match id.provider.as_str() {
        "anthropic" => Ok(Arc::new(anthropic::AnthropicProvider::from_env()?)),
        other => Err(Error::UnknownProvider(other.to_string())),
    }
}
