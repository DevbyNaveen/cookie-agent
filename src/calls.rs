//! One batch of tool calls: decide each in order, deterministically, then
//! run the approved ones. Every call gets a result, whatever stops the batch.

use std::{collections::HashSet, sync::Arc};

use serde_json::Value;
use tracing::Instrument;

use crate::{
    agent::{Agent, Event},
    approval::{ApprovalRequest, Approver},
    budget::LoopGuard,
    error::{Error, Result},
    message::Content,
    policy::{Decision, Policy, Provenance},
    telemetry,
    tool::{valid_tool_name, Effect, Tool, ToolContext},
};

pub(crate) type Call = (String, String, Value);

/// Why the run stops after this batch, once its results are recorded.
pub(crate) enum Stop {
    No,
    Cancelled,
    Loop(String),
}

const NOT_RUN_CANCELLED: &str = "Not run: the run was cancelled first.";
const INTERRUPTED: &str = "Interrupted: this may or may not have run. Check before trying again.";

/// The tools one run offers, with what comes with them.
pub(crate) struct Toolset {
    pub(crate) tools: Vec<Arc<dyn Tool>>,
    pub(crate) searcher: Option<crate::tool_search::Searcher>,
    pub(crate) artifacts: crate::artifacts::Artifacts,
    /// Some description was written by someone else (see `ToolSpec::foreign`).
    pub(crate) foreign: bool,
}

impl Agent {
    /// This agent's tools plus `extra` (Enkeon's), the artifact reader when
    /// there are sub-agents, and the search tool when there are many; checked.
    pub(crate) fn toolset(&self, extra: Vec<Arc<dyn Tool>>) -> Result<Toolset> {
        let mut tools: Vec<Arc<dyn Tool>> = self.tools.iter().cloned().chain(extra).collect();
        // Sub-agents' long answers come back by reference, read on demand.
        let artifacts = crate::artifacts::Artifacts::default();
        if tools.iter().any(|t| t.spec().delegates) {
            tools.push(artifacts.tool());
        }
        let searcher = self.tool_search.and_then(|config| crate::tool_search::Searcher::new(&tools, config));
        tools.extend(searcher.as_ref().map(|s| s.tool.clone()));
        self.check_tools(&tools)?;
        let foreign = tools.iter().any(|t| t.spec().foreign);
        Ok(Toolset { tools, searcher, artifacts, foreign })
    }

    /// Returns every call's result (in order) and whether the run must stop.
    /// A call that finished keeps its real result either way.
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn run_calls(
        &self,
        tools: &[Arc<dyn Tool>],
        calls: &[Call],
        provenance: &Provenance,
        policy: &Policy,
        approver: &dyn Approver,
        loop_guard: &mut LoopGuard,
        context: &ToolContext,
        on_event: &mut (dyn FnMut(Event) + Send),
    ) -> (Vec<Content>, Stop) {
        let cancel = &context.cancel;
        let mut outcomes: Vec<Option<(String, bool)>> = vec![None; calls.len()];
        let mut approved: Vec<(usize, Arc<dyn Tool>)> = Vec::new();
        let mut stop = Stop::No;

        for (index, (_, name, args)) in calls.iter().enumerate() {
            if let Err(Error::Loop(looping)) = loop_guard.see(name, args) {
                // Nothing in this batch runs, and every call is still answered.
                for outcome in outcomes.iter_mut().filter(|o| o.is_none()) {
                    *outcome = Some(("Not run: the agent kept repeating the same calls, so the run stopped.".into(), true));
                }
                approved.clear();
                stop = Stop::Loop(looping);
                break;
            }
            let Some(tool) = tools.iter().find(|t| t.spec().name == *name).cloned() else {
                outcomes[index] = Some((format!("There is no tool called `{name}`."), true));
                continue;
            };
            match policy.decide(tool.spec(), args, provenance, tool.preview(args)) {
                Decision::Allow => approved.push((index, tool)),
                // A cancelled run asks no one; a wait for a person stops on cancel.
                Decision::Ask { .. } if cancel.is_cancelled() => outcomes[index] = Some((NOT_RUN_CANCELLED.into(), true)),
                Decision::Ask { .. } if self.trust.as_ref().is_some_and(|t| t.allows(tool.spec())) => {
                    on_event(Event::RanOnEarnedTrust { tool: name.clone() });
                    approved.push((index, tool));
                }
                Decision::Ask { preview, reason } => {
                    on_event(Event::AskedPerson { tool: name.clone(), preview: preview.clone() });
                    let request = ApprovalRequest { tool: name.clone(), effect: tool.spec().effect, preview, reason };
                    let yes = tokio::select! {
                        yes = approver.approve(&request) => yes,
                        _ = cancel.cancelled() => false,
                    };
                    // Only a person's answer counts, and a cancelled wait is no answer.
                    if let (Some(trust), true, false) = (&self.trust, approver.is_person(), cancel.is_cancelled()) {
                        if let Err(error) = trust.record(tool.spec(), yes) {
                            tracing::warn!(%error, "could not record the approval for earned trust");
                        }
                    }
                    if yes {
                        approved.push((index, tool));
                    } else {
                        outcomes[index] = Some(("The person declined this action.".into(), true));
                    }
                }
                Decision::Deny(reason) => outcomes[index] = Some((reason, true)),
            }
        }

        let run_one = |index: usize, tool: Arc<dyn Tool>| {
            let (id, name, args) = calls[index].clone();
            let span = telemetry::tool_span(&name, &id);
            let recorder = span.clone();
            async move {
                let output = tool.call_in(args, context).await;
                if output.is_err() {
                    recorder.record("error.type", "_OTHER");
                }
                (index, output)
            }
            .instrument(span)
        };
        let parallel = approved.iter().all(|(_, tool)| tool.spec().parallel_safe);
        if parallel {
            let running: Vec<usize> = approved.iter().map(|(index, _)| *index).collect();
            let all = futures::future::join_all(approved.into_iter().map(|(i, t)| run_one(i, t)));
            tokio::select! {
                done = all => record(&mut outcomes, done),
                _ = cancel.cancelled() => {
                    for index in running {
                        outcomes[index] = Some((INTERRUPTED.into(), true));
                    }
                }
            }
        } else {
            for (index, tool) in approved {
                if cancel.is_cancelled() {
                    outcomes[index] = Some((NOT_RUN_CANCELLED.into(), true));
                    continue;
                }
                tokio::select! {
                    done = run_one(index, tool) => record(&mut outcomes, vec![done]),
                    _ = cancel.cancelled() => outcomes[index] = Some((INTERRUPTED.into(), true)),
                }
            }
        }
        if cancel.is_cancelled() && matches!(stop, Stop::No) {
            stop = Stop::Cancelled;
        }

        let results = calls
            .iter()
            .zip(outcomes)
            .map(|((id, _, _), outcome)| {
                let (output, is_error) = outcome.expect("every call has an outcome");
                Content::ToolResult { id: id.clone(), output, is_error }
            })
            .collect();
        (results, stop)
    }

    /// Tool names must be unique (otherwise providers refuse the request, or
    /// the wrong tool runs) and acceptable to every provider.
    pub(crate) fn check_tools(&self, tools: &[Arc<dyn Tool>]) -> Result<()> {
        let mut seen = HashSet::new();
        for tool in tools {
            let name = &tool.spec().name;
            if !valid_tool_name(name) {
                return Err(Error::Tool(format!("`{name}` is not a valid tool name (letters, digits, _ and -, at most 64)")));
            }
            if !seen.insert(name.as_str()) {
                return Err(Error::Tool(format!("two tools are called `{name}`; give one a prefix")));
            }
        }
        // One writer per tree: this agent (if any of its own tools change
        // things) and every writer sub-agent count; more than one is refused.
        let own = self.tools.iter().any(|t| !t.spec().delegates && t.spec().effect != Effect::Read);
        let writers: Vec<&str> = self
            .tools
            .iter()
            .filter(|t| t.spec().delegates && t.spec().effect != Effect::Read)
            .map(|t| t.spec().name.as_str())
            .collect();
        if usize::from(own) + writers.len() > 1 {
            return Err(Error::Tool(format!(
                "only one agent in a tree may change things; writers here: {}{}",
                if own { "this agent, " } else { "" },
                writers.join(", ")
            )));
        }
        Ok(())
    }
}

fn record(outcomes: &mut [Option<(String, bool)>], finished: Vec<(usize, std::result::Result<String, String>)>) {
    for (index, result) in finished {
        outcomes[index] = Some(match result {
            Ok(output) => (output, false),
            Err(error) => (error, true),
        });
    }
}
