//! Cookie Agent Harness: a tiny agent loop where text the model read can
//! never, on its own, decide who gets sent what.

pub mod error;
pub mod model_id;

pub use error::{Error, Result};
pub use model_id::ModelId;
