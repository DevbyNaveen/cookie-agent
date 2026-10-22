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
    /// The person said no three times in a row.
    Declined,
}

const NOT_RUN_CANCELLED: &str = "Not run: the run was cancelled first.";
const INTERRUPTED: &str = "Interrupted: this may or may not have run. Check before trying again.";
const ALREADY_DONE: &str = "Already done earlier in this run, so it was not sent again. It returned: ";

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

        // Actions that need a person, put to them together once every call is decided.
        let mut asks: Vec<(usize, Arc<dyn Tool>, ApprovalRequest)> = Vec::new();
        for (index, (_, name, args)) in calls.iter().enumerate() {
            // Arguments that were not JSON: answered with what was wrong, never run.
            if let Some(wrong) = args.get(crate::provider::MALFORMED_ARGS).and_then(|v| v.as_str()) {
                outcomes[index] = Some((format!("The arguments for `{name}` were not valid JSON ({wrong}). Send the call again with valid JSON."), true));
                continue;
            }
            match loop_guard.see(name, args) {
                Err(Error::Loop(looping)) => {
                    // Nothing in this batch runs, and every call is still answered.
                    for outcome in outcomes.iter_mut().filter(|o| o.is_none()) {
                        *outcome = Some(("Not run: the agent kept repeating the same calls, so the run stopped.".into(), true));
                    }
                    approved.clear();
                    stop = Stop::Loop(looping);
                    break;
                }
                Ok(crate::budget::Seen::Warned(note)) => {
                    outcomes[index] = Some((note, true));
                    continue;
                }
                _ => {}
            }
            let Some(tool) = tools.iter().find(|t| t.spec().name == *name).cloned() else {
                outcomes[index] = Some((format!("There is no tool called `{name}`."), true));
                continue;
            };
            // The same change twice is one change: the second is answered
            // with what the first returned, never sent again.
            if tool.spec().effect != Effect::Read {
                if let Some(earlier) = loop_guard.already_done(name, args) {
                    outcomes[index] = Some((format!("{ALREADY_DONE}{earlier}"), false));
                    continue;
                }
            }
            match policy.decide(tool.spec(), args, provenance, tool.preview(args)) {
                Decision::Allow => approved.push((index, tool)),
                // A cancelled run asks no one; a wait for a person stops on cancel.
                Decision::Ask { .. } if cancel.is_cancelled() => outcomes[index] = Some((NOT_RUN_CANCELLED.into(), true)),
                // Earned trust answers only for values the person wrote; data is always put to them.
                Decision::Ask { ref from_data, .. } if from_data.is_empty() && self.trust.as_ref().is_some_and(|t| t.allows(tool.spec())) => {
                    on_event(Event::RanOnEarnedTrust { tool: name.clone() });
                    approved.push((index, tool));
                }
                Decision::Ask { preview, reason, from_data } => {
                    on_event(Event::AskedPerson { tool: name.clone(), preview: preview.clone() });
                    let request = ApprovalRequest { tool: name.clone(), effect: tool.spec().effect, preview, reason, from_data };
                    asks.push((index, tool, request));
                }
                Decision::Deny(reason) => outcomes[index] = Some((reason, true)),
            }
        }
        // A loop stop already answered every call ("Not run"): nobody is asked.
        if !asks.is_empty() && matches!(stop, Stop::No) {
            let requests: Vec<ApprovalRequest> = asks.iter().map(|(_, _, request)| request.clone()).collect();
            let answers = tokio::select! {
                answers = async {
                    if requests.len() == 1 { vec![approver.approve(&requests[0]).await] } else { approver.approve_batch(&requests).await }
                } => answers,
                _ = cancel.cancelled() => vec![false; requests.len()],
            };
            for (position, (index, tool, _)) in asks.into_iter().enumerate() {
                // A short or missing answer is a no.
                let yes = answers.get(position).copied().unwrap_or(false);
                // Only a person's answer counts, and a cancelled wait is no answer.
                if let (Some(trust), true, false) = (&self.trust, approver.is_person(), cancel.is_cancelled()) {
                    if let Err(error) = trust.record(tool.spec(), yes) {
                        tracing::warn!(%error, "could not record the approval for earned trust");
                    }
                }
                // Only the person's own noes count toward stopping.
                let stop_now = approver.is_person() && !cancel.is_cancelled() && loop_guard.answered(yes);
                if yes {
                    approved.push((index, tool));
                } else {
                    outcomes[index] = Some(("The person declined this action.".into(), true));
                }
                if stop_now && matches!(stop, Stop::No) {
                    stop = Stop::Declined;
                }
            }
            approved.sort_by_key(|(index, _)| *index);
        }
        // What ran and what it was, for what is remembered afterwards.
        let ran: Vec<(usize, Effect, String)> =
            approved.iter().map(|(index, tool)| (*index, tool.spec().effect, tool.spec().name.clone())).collect();

        let run_one = |index: usize, tool: Arc<dyn Tool>| {
            let (id, name, args) = calls[index].clone();
            let span = telemetry::tool_span(&name, &id);
            let recorder = span.clone();
            async move {
                let attempt = if tool.spec().effect != Effect::Read {
                    match self.action_ledger.as_ref().map(|ledger|ledger.begin(&name,&args)).transpose() {
                        Ok(key) => key,
                        Err(e) => return (index, Err(e.to_string())),
                    }
                } else { None };
                let output = tool.call_in(args, context).await;
                if output.is_ok() {
                    if let (Some(ledger),Some(key))=(&self.action_ledger,attempt) {
                        if ledger.acknowledged(&key).is_err() {
                            return (index,Err("The tool ran but its receipt could not be saved. Outcome unknown; do not retry.".into()));
                        }
                    }
                }
                if output.is_err() {
                    recorder.record("error.type", "_OTHER");
                }
                (index, output)
            }
            .instrument(span)
        };
        // In order, in segments: calls that are safe side by side run
        // together; one that is not runs alone, after what came before it
        // and before what comes after. One `remember` no longer makes a batch
        // of lookups wait for each other.
        for segment in segments(approved) {
            if cancel.is_cancelled() {
                for (index, _) in segment {
                    outcomes[index] = Some((NOT_RUN_CANCELLED.into(), true));
                }
                continue;
            }
            let running: Vec<usize> = segment.iter().map(|(index, _)| *index).collect();
            let all = futures::future::join_all(segment.into_iter().map(|(i, t)| run_one(i, t)));
            tokio::select! {
                done = all => record(&mut outcomes, done),
                _ = cancel.cancelled() => {
                    for index in running {
                        outcomes[index] = Some((INTERRUPTED.into(), true));
                    }
                }
            }
        }
        if cancel.is_cancelled() && matches!(stop, Stop::No) {
            stop = Stop::Cancelled;
        }
        // Changes that worked are remembered; a check-after tool that worked
        // waits for an adapter-defined read proving its identity and changed fields.
        for (index, effect, name) in ran {
            let Some((output, false)) = &outcomes[index] else { continue };
            if effect == Effect::Read {
                loop_guard.observe_read(&name, output, &self.verification);
            } else {
                loop_guard.did(&calls[index].1, &calls[index].2, output);
                if self.check_after.contains(&name) {
                    loop_guard.pending_check(name, calls[index].2.clone());
                }
            }
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

/// Consecutive parallel-safe calls make one segment; any other call is a
/// segment of its own. Order is kept.
fn segments(approved: Vec<(usize, Arc<dyn Tool>)>) -> Vec<Vec<(usize, Arc<dyn Tool>)>> {
    let mut out: Vec<Vec<(usize, Arc<dyn Tool>)>> = Vec::new();
    for (index, tool) in approved {
        let safe = tool.spec().parallel_safe;
        match out.last_mut() {
            Some(last) if safe && last.iter().all(|(_, t)| t.spec().parallel_safe) => last.push((index, tool)),
            _ => out.push(vec![(index, tool)]),
        }
    }
    out
}

fn record(outcomes: &mut [Option<(String, bool)>], finished: Vec<(usize, std::result::Result<String, String>)>) {
    for (index, result) in finished {
        outcomes[index] = Some(match result {
            Ok(output) => (output, false),
            Err(error) => (error, true),
        });
    }
}
