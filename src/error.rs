#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("model must be named as `provider:model`, got `{0}`")]
    ModelId(String),
    #[error("unknown provider `{0}`")]
    UnknownProvider(String),
    #[error("provider: {0}")]
    Provider(String),
    #[error("budget reached: {0}")]
    Budget(String),
    #[error("the model ran out of output tokens before finishing")]
    MaxTokens,
    #[error("the conversation no longer fits the model's context window")]
    ContextFull,
    #[error("cancelled")]
    Cancelled,
    #[error("stopped after the turn finished, as asked")]
    Stopped,
    #[error("stopped a loop: `{0}` was called with the same arguments three times in a row")]
    Loop(String),
    #[error("stopped: the person said no three times in a row")]
    Declined,
    #[error("tool: {0}")]
    Tool(String),
    #[error("mcp: {0}")]
    Mcp(String),
    #[error("a2a: {0}")]
    A2a(String),
    #[error("skill: {0}")]
    Skill(String),
    #[error("session: {0}")]
    Session(String),
    #[error("replay {0}")]
    Replay(String),
    #[error("image: {0}")]
    Image(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

impl Error {
    /// What kind of failure this is, as one stable word a client can count
    /// and group by: never parse the message.
    pub fn kind(&self) -> &'static str {
        match self {
            Error::ModelId(_) | Error::UnknownProvider(_) => "setup",
            Error::Provider(_) => "provider",
            Error::Budget(_) => "budget",
            Error::MaxTokens => "max_tokens",
            Error::ContextFull => "context_full",
            Error::Cancelled => "cancelled",
            Error::Stopped => "stopped",
            Error::Loop(_) => "loop",
            Error::Declined => "declined",
            Error::Tool(_) => "tool",
            Error::Mcp(_) => "mcp",
            Error::A2a(_) => "a2a",
            Error::Skill(_) => "skill",
            Error::Session(_) | Error::Io(_) => "session",
            Error::Replay(_) => "replay",
            Error::Image(_) => "image",
            Error::Json(_) => "json",
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;
