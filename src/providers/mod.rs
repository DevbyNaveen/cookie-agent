//! `provider:model` → a provider. No defaults: an unknown name is an error.

use std::sync::Arc;

use crate::{error::{Error, Result}, model_id::ModelId, provider::Provider};

pub mod anthropic;
#[cfg(feature = "bedrock")]
pub mod bedrock;
mod fence;
pub mod gemini;
pub mod openai;
pub mod scripted;
mod sse;

pub fn resolve(id: &ModelId) -> Result<Arc<dyn Provider>> {
    match id.provider.as_str() {
        "anthropic" => Ok(Arc::new(anthropic::AnthropicProvider::from_env()?)),
        "openai" => Ok(Arc::new(openai::OpenAiProvider::openai_from_env()?)),
        "gemini" => Ok(Arc::new(gemini::GeminiProvider::from_env()?)),
        "ollama" => Ok(Arc::new(openai::OpenAiProvider::ollama_from_env())),
        #[cfg(feature = "bedrock")]
        "bedrock" => Ok(Arc::new(bedrock::BedrockProvider::from_env()?)),
        #[cfg(not(feature = "bedrock"))]
        "bedrock" => Err(Error::UnknownProvider("bedrock (enable the `bedrock` cargo feature)".into())),
        other => Err(Error::UnknownProvider(other.to_string())),
    }
}

/// The HTTP client every provider uses. A server that connects but goes
/// quiet fails after the read timeout instead of hanging the run; requests
/// never follow a redirect, so a key header can't be carried elsewhere.
pub(crate) fn http_client() -> reqwest::Client {
    let read = if cfg!(test) { std::time::Duration::from_secs(1) } else { std::time::Duration::from_secs(120) };
    reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(10))
        .read_timeout(read)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("a TLS backend is compiled in")
}

/// An HTTP failure, keeping the status even when the body isn't JSON.
pub fn http_error(status: u16, body: &str) -> Error {
    let detail: String = body.chars().take(500).collect();
    Error::Provider(format!("HTTP {status}: {detail}"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn gemini_is_a_known_provider_that_needs_its_key() {
        let id = crate::model_id::ModelId::parse("gemini:gemini-3.8-flash").unwrap();
        match super::resolve(&id) {
            Ok(_) => assert!(std::env::var("GEMINI_API_KEY").is_ok()),
            Err(crate::Error::Provider(m)) => assert!(m.contains("GEMINI_API_KEY"), "{m}"),
            Err(other) => panic!("{other}"),
        }
    }

    #[cfg(not(feature = "bedrock"))]
    #[test]
    fn bedrock_without_the_feature_says_which_feature_to_enable() {
        let id = crate::model_id::ModelId::parse("bedrock:eu.anthropic.claude-sonnet-4-6").unwrap();
        assert!(matches!(super::resolve(&id), Err(crate::Error::UnknownProvider(m)) if m.contains("`bedrock` cargo feature")));
    }
}
