//! Where a piece of text came from. Set by the runtime, never by the model.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "detail", rename_all = "snake_case")]
pub enum Source {
    Tool(String),
    Web,
    File,
    Screen,
    Agent(String),
    /// The model's output after it had read untrusted content.
    Context,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "origin", content = "source", rename_all = "snake_case")]
pub enum Origin {
    /// The person's own words.
    User,
    /// The developer's instructions.
    System,
    /// Written by the model with nothing untrusted in its context.
    Model,
    /// Anything the person didn't write: tool output, web, files, screens, other agents.
    Untrusted(Source),
}

impl Origin {
    pub fn is_untrusted(&self) -> bool {
        matches!(self, Origin::Untrusted(_))
    }
}
