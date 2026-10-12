//! Cookie Agent Harness: a tiny agent loop where text the model read can
//! never, on its own, decide who gets sent what.

pub mod agent;
pub mod approval;
pub mod budget;
pub mod chat;
mod calls;
pub mod compaction;
pub mod enkeon;
pub mod error;
pub mod label;
pub mod mcp;
pub mod message;
pub mod model_id;
pub mod policy;
pub mod provider;
pub mod providers;
pub mod replay;
pub mod serve;
pub mod session;
pub mod skills;
pub mod subagent;
pub mod telemetry;
pub mod tool;

pub use agent::{Agent, Event, RunControl};
pub use approval::{ApprovalRequest, Approver, DenyAll, FnApprover};
pub use budget::Budget;
pub use compaction::{Compaction, SUMMARY_PROMPT};
pub use error::{Error, Result};
pub use label::{Origin, Source};
pub use message::{Content, Message, Role};
pub use model_id::ModelId;
pub use policy::{Decision, Policy, Provenance};
pub use provider::{ModelRequest, ModelResponse, Provider, ProviderEvent, StopReason, Usage};
pub use session::Session;
pub use tool::{tool, Effect, FnTool, Tool, ToolSpec};
pub use tokio_util::sync::CancellationToken;
pub use mcp::{McpClient, McpServer, McpTools};
pub use skills::{read_agents_md, Skills};
pub use subagent::SubAgent;
pub use replay::{Replay, ReplayProvider};
pub use enkeon::{Enkeon, ENKEON_INSTRUCTIONS};
