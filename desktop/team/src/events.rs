//! What the team says while it works. Every surface (the window, Telegram, a
//! remote desktop over HTTP) listens to the same stream.

use serde::Serialize;

use crate::store::{JobStatus, Trigger};

/// A request for the person's yes, as every surface shows it.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Approval {
    pub id: String,
    pub agent: String,
    pub agent_name: String,
    pub job: String,
    pub tool: String,
    pub effect: String,
    /// What will actually happen: recipient, content, diff, amount.
    pub preview: String,
    pub reason: String,
    /// Values in the action the person didn't write. Check these.
    pub from_data: Vec<String>,
    /// The checker model's view, when one is set.
    pub checker: Option<Checker>,
    pub asked_at: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Checker {
    pub model: String,
    /// `ok`, `concern`, or `block`.
    pub verdict: String,
    pub note: String,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TeamEvent {
    JobStarted { job: String, agent: String, trigger: Trigger, input: String },
    Text { job: String, agent: String, text: String },
    Tool { job: String, agent: String, name: String },
    /// A board changed (`boards`): open views redraw.
    Board { id: String },
    /// Something new was written into this agent's chat from outside a job of its own (an answer from an agent brought in with @).
    ChatChanged { agent: String },
    /// A helper the job sent: its number in the job, its task, `waiting`, `working`, `done` or `failed`, and its report or error.
    Helper { job: String, agent: String, n: usize, task: String, state: String, note: String },
    Steered { job: String, agent: String, text: String },
    Asked { approval: Approval },
    Answered { id: String, agent: String, yes: bool, by: String },
    /// Probation or shadow: the action was recorded, not made.
    Would { job: String, agent: String, tool: String, preview: String },
    Handoff { job: String, from: String, to: String, task: String },
    JobFinished {
        job: String,
        agent: String,
        status: JobStatus,
        answer: String,
        error: Option<String>,
        microdollars: u64,
        /// Documents it made in its folder (Markdown, web pages, PDFs), shown as pages under the answer.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        made: Vec<String>,
    },
    /// Something worth the person's attention, within the day's cap.
    Notice { agent: String, title: String, body: String, job: Option<String> },
    RosterChanged,
    RoutinesChanged,
    /// The morning card was posted.
    Retro,
    /// This computer was paired with Enkeon, or unpaired.
    EnkeonChanged,
    /// An agent's tuning or model changed (kept, or undone), in words.
    Evolved { agent: String, what: String },
    TestProgress { run: String, agent: String, done: usize, total: usize },
    TestFinished { run: String, agent: String, passed: usize, total: usize },
    Channel { name: String, status: String },
    /// The network changed: `status`, `contacts`, `deals`, `rooms`, `thread:<id>`, `room:<id>`.
    Network { what: String },
    /// An agent's learning pass changed its skills or notes (or the curator archived some).
    Learned { agent: String, changes: Vec<String> },
    /// An agent asked the person something and waits for the answer.
    Question { question: crate::workbench::Question },
    /// An agent's plan for its current job.
    Todos { agent: String, items: Vec<crate::workbench::Todo> },
    /// An agent's workspace (its own software) changed.
    Workspace { agent: String },
    /// Parallax changed: a world, or something waiting at the wall.
    Worlds,
}

impl TeamEvent {
    pub fn agent(&self) -> Option<&str> {
        match self {
            TeamEvent::JobStarted { agent, .. }
            | TeamEvent::Text { agent, .. }
            | TeamEvent::Tool { agent, .. }
            | TeamEvent::Steered { agent, .. }
            | TeamEvent::Answered { agent, .. }
            | TeamEvent::Would { agent, .. }
            | TeamEvent::JobFinished { agent, .. }
            | TeamEvent::Notice { agent, .. }
            | TeamEvent::TestProgress { agent, .. }
            | TeamEvent::TestFinished { agent, .. }
            | TeamEvent::Workspace { agent, .. } => Some(agent),
            TeamEvent::Asked { approval } => Some(&approval.agent),
            TeamEvent::Handoff { from, .. } => Some(from),
            _ => None,
        }
    }
}
