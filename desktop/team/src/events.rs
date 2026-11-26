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
    /// `resumed`: the same job picked up again after Cookie closed mid-way.
    JobStarted { job: String, agent: String, trigger: Trigger, input: String, resumed: bool },
    Text { job: String, agent: String, text: String },
    Tool { job: String, agent: String, name: String },
    /// One step of a job, once its arguments are known: what it is doing and,
    /// when done, what it did, in plain words; `with`, the teammate it is talking to.
    /// Sent first with the tool's name alone (the moment the model starts the call), then again with the
    /// full wording once its arguments are in. `thread`: the task of a helper or contractor this step sends,
    /// which ties the step to that helper's own events.
    /// `sort` (`search`, `page`, `memory`, `file` or `other`) and `detail` (its query, site or file) fold steps into short lines.
    Step { job: String, agent: String, id: String, name: String, doing: String, did: String, with: Option<String>, thread: Option<String>, sort: String, detail: Option<String> },
    /// The step finished.
    StepDone { job: String, agent: String, id: String, ok: bool },
    /// What an action came to, and why it was allowed (`receipts`).
    Receipt { job: String, agent: String, receipt: crate::receipts::ActionReceipt },
    /// One step a helper or contractor took, live: `n` is its number in the job, `state` is
    /// `running`, `done` or `failed`; `host`, the site it read or searched, when there is one.
    HelperStep { job: String, agent: String, n: usize, id: String, name: String, doing: String, did: String, state: String, host: Option<String> },
    /// Helpers sent together came back saying different things: what, between which, in words.
    HelperConflict { job: String, agent: String, between: Vec<usize>, about: String, detail: String },
    /// A council proposal moved on (`council`): voted, tested, applied, or waiting on the person.
    Council { id: String, state: String },
    /// A twin run moved on (`twin`): `running` with how many attempts are done, or `done`.
    Twin { run: String, state: String, done: usize, total: usize },
    /// A rehearsal started, finished or ran for real (`twin::rehearsal`).
    Rehearsal { agent: String, id: String, state: String },
    /// A workflow was saved or deleted (`run: None`), or a run moved to a step (`state`: its id, or `end`).
    Workflow { agent: String, flow: String, run: Option<String>, state: String },
    /// A board changed (`boards`): open views redraw.
    Board { id: String },
    /// Something new was written into this agent's chat from outside a job of its own (an answer from an agent brought in with @).
    ChatChanged { agent: String },
    /// A helper the job sent: its number in the job, its task, `waiting`, `working`, `done` or `failed`, and its report or error.
    Helper { job: String, agent: String, n: usize, task: String, state: String, note: String, title: String },
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
            | TeamEvent::Step { agent, .. }
            | TeamEvent::StepDone { agent, .. }
            | TeamEvent::Receipt { agent, .. }
            | TeamEvent::Rehearsal { agent, .. }
            | TeamEvent::Workflow { agent, .. }
            | TeamEvent::Helper { agent, .. }
            | TeamEvent::HelperStep { agent, .. }
            | TeamEvent::HelperConflict { agent, .. }
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
