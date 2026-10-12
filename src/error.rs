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
    #[error("cancelled")]
    Cancelled,
    #[error("stopped a loop: `{0}` was called with the same arguments three times in a row")]
    Loop(String),
    #[error("session: {0}")]
    Session(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

pub type Result<T> = std::result::Result<T, Error>;
