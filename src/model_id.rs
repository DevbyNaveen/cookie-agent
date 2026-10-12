//! `provider:model` — the only way to choose a model. There is no default.

use crate::error::{Error, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelId {
    pub provider: String,
    pub model: String,
}

impl ModelId {
    pub fn parse(text: &str) -> Result<Self> {
        match text.split_once(':') {
            Some((provider, model)) if !provider.is_empty() && !model.is_empty() => Ok(Self {
                provider: provider.to_ascii_lowercase(),
                model: model.to_string(),
            }),
            _ => Err(Error::ModelId(text.to_string())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_provider_and_model() {
        let id = ModelId::parse("Anthropic:claude-sonnet-4-6").unwrap();
        assert_eq!(id.provider, "anthropic");
        assert_eq!(id.model, "claude-sonnet-4-6");
    }

    #[test]
    fn keeps_colons_inside_the_model_name() {
        let id = ModelId::parse("bedrock:eu.anthropic.claude-sonnet-4-6-v1:0").unwrap();
        assert_eq!(id.provider, "bedrock");
        assert_eq!(id.model, "eu.anthropic.claude-sonnet-4-6-v1:0");
    }

    #[test]
    fn refuses_anything_without_a_provider_and_a_model() {
        for bad in ["claude-sonnet-4-6", ":x", "anthropic:", ""] {
            assert!(matches!(ModelId::parse(bad), Err(Error::ModelId(_))), "{bad}");
        }
    }
}
