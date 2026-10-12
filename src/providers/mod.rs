//! `provider:model` → a provider. No defaults: an unknown name is an error.

use std::sync::Arc;

use crate::{error::{Error, Result}, model_id::ModelId, provider::Provider};

pub mod anthropic;
#[cfg(feature = "bedrock")]
pub mod bedrock;
mod fence;
pub mod openai;
pub mod scripted;

pub fn resolve(id: &ModelId) -> Result<Arc<dyn Provider>> {
    match id.provider.as_str() {
        "anthropic" => Ok(Arc::new(anthropic::AnthropicProvider::from_env()?)),
        "openai" => Ok(Arc::new(openai::OpenAiProvider::openai_from_env()?)),
        "ollama" => Ok(Arc::new(openai::OpenAiProvider::ollama_from_env())),
        #[cfg(feature = "bedrock")]
        "bedrock" => Ok(Arc::new(bedrock::BedrockProvider::from_env()?)),
        #[cfg(not(feature = "bedrock"))]
        "bedrock" => Err(Error::UnknownProvider("bedrock (enable the `bedrock` cargo feature)".into())),
        other => Err(Error::UnknownProvider(other.to_string())),
    }
}

/// An HTTP failure, keeping the status even when the body isn't JSON.
pub fn http_error(status: u16, body: &str) -> Error {
    let detail: String = body.chars().take(500).collect();
    Error::Provider(format!("HTTP {status}: {detail}"))
}

#[cfg(test)]
mod tests {
    #[cfg(not(feature = "bedrock"))]
    #[test]
    fn bedrock_without_the_feature_says_which_feature_to_enable() {
        let id = crate::model_id::ModelId::parse("bedrock:eu.anthropic.claude-sonnet-4-6").unwrap();
        assert!(matches!(super::resolve(&id), Err(crate::Error::UnknownProvider(m)) if m.contains("`bedrock` cargo feature")));
    }
}
