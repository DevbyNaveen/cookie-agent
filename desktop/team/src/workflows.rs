//! Living workflows: an agent's repeated work, written down as steps.
//!
//! Open work stays on the agent loop: it decides each step as it goes. Work
//! that repeats (the weekly report, chasing overdue invoices, a client brief
//! before each call) is better as a workflow (`cookie_harness::flow`): known
//! steps, each with its own model, run the same way each time, saved after
//! every step, picked up where it stopped after a restart.
//!
//! - **Made by the agent, approved by the person.** An agent that notices a job
//!   it does again and again proposes it as a workflow (`save_workflow`). The
//!   person sees every step in words and says yes: only then is it kept, so
//!   its prompts carry the person's authority. What earlier steps said stays
//!   data, never an instruction (`flow::split`).
//! - **Every step is a job's turn.** An agent step runs with the agent's own
//!   tools, rules and approvals, its receipts keyed to the run and the step, so
//!   a step picked up again never repeats an action it began. Questions and
//!   yes-or-no steps reach the person like any other.
//! - **Versions with Undo.** Every change keeps the version before it.
//! - **One record.** A run becomes one job in the agent's record (its cost,
//!   receipts and answer), so usage, receipts and scores count it.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use cookie_harness::approval::{ApprovalRequest, Approver};
use cookie_harness::flow::{self, Flow, FlowRun, RunState, StepCtx};
use cookie_harness::label::Source;
use cookie_harness::tool::{tool, Effect, Tool};
use cookie_harness::{Event, Message, RunControl, Session};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::approvals::{Broker, Mode};
use crate::events::TeamEvent;
use crate::runtime::Built;
use crate::store::{AgentRecord, Job, JobStatus, Trigger};
use crate::{util, Team};

/// How long a workflow's question waits for the person.
const ASK_WAIT: Duration = Duration::from_secs(1800);

/// A version kept for Undo.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Version {
    at: u64,
    by: String,
    flow: Flow,
}

impl Team {
    fn flows_dir(&self, agent: &str) -> std::path::PathBuf {
        self.paths.agent(agent).join("workflows")
    }

    fn flow_store(&self, agent: &str) -> flow::Store {
        flow::Store::new(self.flows_dir(agent).join("runs"))
    }

    /// The agent's workflows.
    pub fn workflows(&self, agent: &str) -> Vec<Flow> {
        let mut v: Vec<Flow> = std::fs::read_dir(self.flows_dir(agent).join("flows"))
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| serde_json::from_slice(&std::fs::read(e.path()).ok()?).ok())
            .collect();
        v.sort_by(|a, b| a.name.cmp(&b.name));
        v
    }

    pub fn workflow(&self, agent: &str, id: &str) -> Result<Flow, String> {
        self.workflows(agent).into_iter().find(|f| f.id == id).ok_or_else(|| "No such workflow.".to_string())
    }

    fn versions_path(&self, agent: &str, id: &str) -> std::path::PathBuf {
        self.flows_dir(agent).join("versions").join(format!("{}.jsonl", safe(id)))
    }

    /// Keep `f` as the agent's workflow (new, or the next version), checked first.
    pub fn save_workflow(&self, agent: &str, mut f: Flow, by: &str) -> Result<Flow, String> {
        f.id = if f.id.trim().is_empty() { slug(&f.name) } else { safe(&f.id) };
        if f.name.trim().is_empty() {
            return Err("Give the workflow a name.".into());
        }
        f.check()?;
        let old = self.workflow(agent, &f.id).ok();
        f.version = old.as_ref().map_or(1, |o| o.version + 1);
        if let Some(o) = old {
            util::append_jsonl(&self.versions_path(agent, &f.id), &Version { at: util::now(), by: by.into(), flow: o })?;
        }
        util::write_json(&self.flows_dir(agent).join("flows").join(format!("{}.json", f.id)), &f)?;
        self.emit(TeamEvent::Workflow { agent: agent.into(), flow: f.id.clone(), run: None, state: "saved".into() });
        Ok(f)
    }

    /// Back to the version before the last change.
    pub fn undo_workflow(&self, agent: &str, id: &str) -> Result<Flow, String> {
        let path = self.versions_path(agent, id);
        let mut versions: Vec<Version> = util::read_jsonl(&path);
        let last = versions.pop().ok_or("There is no earlier version.")?;
        let current = self.workflow(agent, id)?;
        let mut back = last.flow;
        back.version = current.version + 1;
        util::write_json(&self.flows_dir(agent).join("flows").join(format!("{}.json", safe(id))), &back)?;
        // The version list without the one restored.
        let _ = std::fs::remove_file(&path);
        for v in versions {
            util::append_jsonl(&path, &v)?;
        }
        self.emit(TeamEvent::Workflow { agent: agent.into(), flow: id.into(), run: None, state: "saved".into() });
        Ok(back)
    }

    pub fn delete_workflow(&self, agent: &str, id: &str) -> Result<(), String> {
        std::fs::remove_file(self.flows_dir(agent).join("flows").join(format!("{}.json", safe(id)))).map_err(|_| "No such workflow.".to_string())?;
        self.emit(TeamEvent::Workflow { agent: agent.into(), flow: id.into(), run: None, state: "deleted".into() });
        Ok(())
    }

    /// One step's model, set by the person (`None`: the agent's own).
    pub fn set_workflow_model(&self, agent: &str, id: &str, step: &str, model: Option<String>) -> Result<Flow, String> {
        let mut f = self.workflow(agent, id)?;
        if let Some(m) = &model {
            cookie_harness::Agent::new(m).map_err(|e| e.to_string())?;
        }
        let s = f.steps.iter_mut().find(|s| s.id == step).ok_or("No such step.")?;
        s.model = model.filter(|m| !m.trim().is_empty());
        self.save_workflow(agent, f, "you")
    }

    /// An agent's workflow runs, newest first.
    pub fn workflow_runs(&self, agent: &str) -> Vec<FlowRun> {
        self.flow_store(agent).all()
    }

    /// Run a workflow on `input`, in the background; its run id. `from_person`: the
    /// person gave the input themselves (from an agent, it stays data).
    pub async fn start_workflow(self: &Arc<Self>, agent: &str, id: &str, input: String, from_person: bool) -> Result<String, String> {
        let rec = self.agent(agent).await?;
        let f = self.workflow(agent, id)?;
        let mut run = FlowRun::new(&util::new_id("flowrun"), &f, util::clip(input.trim(), 4000).as_str());
        run.input_from_person = from_person;
        self.go_workflow(rec, f, run).await
    }

    async fn go_workflow(self: &Arc<Self>, rec: AgentRecord, f: Flow, run: FlowRun) -> Result<String, String> {
        let control = RunControl::default();
        let job_id = util::new_id("job");
        {
            let mut runs = self.runs.lock().unwrap();
            if runs.contains_key(&rec.id) {
                return Err(format!("{} is already working. Run the workflow when it's free.", rec.name));
            }
            runs.insert(rec.id.clone(), crate::runtime::Run { job: job_id.clone(), control: control.clone() });
        }
        let run_id = run.id.clone();
        let trigger = Trigger::Workflow { flow: f.id.clone(), run: run.id.clone() };
        self.emit(TeamEvent::JobStarted { job: job_id.clone(), agent: rec.id.clone(), trigger: trigger.clone(), input: util::clip(&run.input, 2000), resumed: run.resumed > 0 || !run.history.is_empty() });
        let team = self.clone();
        tokio::spawn(async move {
            let started_at = util::now();
            let exec = FlowExec { team: team.clone(), rec: rec.clone(), job: job_id.clone(), flow: f.name.clone(), log: Default::default(), usage: Default::default(), receipts: Default::default() };
            let store = team.flow_store(&rec.id);
            let (t, aid, fid) = (team.clone(), rec.id.clone(), f.id.clone());
            let mut on = move |r: &FlowRun| {
                t.emit(TeamEvent::Workflow { agent: aid.clone(), flow: fid.clone(), run: Some(r.id.clone()), state: r.current.clone().unwrap_or_else(|| "end".into()) });
            };
            let done = flow::run(&f, run, &exec, &store, &control.cancel, &mut on).await;
            team.runs.lock().unwrap().remove(&rec.id);
            let status = match done.state {
                RunState::Done => JobStatus::Done,
                RunState::Stopped => JobStatus::Stopped,
                _ => JobStatus::Failed,
            };
            let (tokens, microdollars) = *exec.usage.lock().unwrap();
            let job = Job {
                id: job_id.clone(),
                agent: rec.id.clone(),
                trigger,
                input: util::clip(&done.input, 4000),
                started_at,
                finished_at: Some(util::now()),
                status,
                answer: util::clip(&done.answer, 20_000),
                error: done.error.clone(),
                tools: done.history.iter().map(|h| format!("workflow:{}", h.step)).collect(),
                approvals: exec.log.lock().unwrap().clone(),
                tokens,
                microdollars,
                version: rec.version,
                receipts: exec.receipts.lock().unwrap().take(),
                ..Job::default()
            };
            let _ = util::append_jsonl(&team.paths.jobs(&rec.id), &job);
            team.emit(TeamEvent::JobFinished { job: job_id, agent: rec.id.clone(), status, answer: job.answer.clone(), error: job.error.clone(), microdollars, made: Vec::new() });
        });
        Ok(run_id)
    }

    /// Runs Cookie closed in the middle of: picked up at their step (receipts keep it from repeating an action).
    pub(crate) async fn resume_workflows(self: &Arc<Self>) {
        for rec in self.agents().await {
            for run in self.workflow_runs(&rec.id).into_iter().filter(|r| r.state == RunState::Running) {
                let Ok(f) = self.workflow(&rec.id, &run.flow) else { continue };
                // A workflow changed since: never resumed on steps it didn't start with.
                if f.version != run.version {
                    let mut r = run;
                    r.state = RunState::Failed;
                    r.error = Some("The workflow changed while this run was cut off; start it again.".into());
                    let _ = self.flow_store(&rec.id).save(&r);
                    continue;
                }
                if let Err(e) = self.go_workflow(rec.clone(), f, run).await {
                    tracing::warn!(%e, "a workflow run couldn't be picked up");
                }
            }
        }
    }
}

/// Carries a workflow's steps out with the agent's own tools, rules and approvals.
struct FlowExec {
    team: Arc<Team>,
    rec: AgentRecord,
    job: String,
    flow: String,
    log: Arc<Mutex<Vec<crate::store::ApprovalRecord>>>,
    usage: Arc<Mutex<(u64, u64)>>,
    receipts: Arc<Mutex<crate::receipts::Collector>>,
}

#[async_trait]
impl flow::Executor for FlowExec {
    async fn agent(&self, ctx: &StepCtx<'_>, template: &str) -> Result<String, String> {
        let mut rec = self.rec.clone();
        if let Some(m) = &ctx.step.model {
            rec.model = m.clone();
        }
        let trigger = Trigger::Workflow { flow: self.flow.clone(), run: ctx.run.to_string() };
        // Receipts keyed to the run, the step and its visit: a step picked up again never repeats an action.
        let mut built = Built { ledger_scope: Some(ctx.scope()), ..Built::default() };
        let (instruction, data) = flow::split(template, ctx.input, ctx.input_from_person, ctx.outputs);
        let agent = self.team.build_agent(&rec, &trigger, Mode::Ask, &self.job, &instruction, self.log.clone(), &mut built).await?;
        let mut input: Vec<Message> = built.note.take().map(Message::harness_note).into_iter().collect();
        input.push(Message::harness_note(format!(
            "You are running step \"{}\" of the workflow \"{}\" the person approved. Do this step only, then answer with its result: the next step reads it.",
            if ctx.step.title.is_empty() { &ctx.step.id } else { &ctx.step.title },
            self.flow
        )));
        if !data.is_empty() {
            input.push(Message::untrusted(data, Source::Agent("workflow".into())));
        }
        input.push(Message::user(instruction));
        let (us, rc, team, aid, jid) = (self.usage.clone(), self.receipts.clone(), self.team.clone(), rec.id.clone(), self.job.clone());
        let mut forward = move |e: Event| match e {
            Event::Usage(u) => {
                let mut g = us.lock().unwrap();
                g.0 += u.input_tokens + u.output_tokens + u.cache_write_tokens;
                g.1 += team.price_of(&aid, &u);
            }
            Event::ToolCallReady { id, name, args } => {
                let (doing, did, with) = crate::steps::words(&team, &name, &args);
                let (kind, detail) = crate::steps::brief(&name, &args);
                rc.lock().unwrap().words(&id, &did);
                team.emit(TeamEvent::Step { job: jid.clone(), agent: aid.clone(), id, name, doing, did, with, thread: None, sort: kind.into(), detail });
            }
            Event::ToolFinished { id, is_error } => team.emit(TeamEvent::StepDone { job: jid.clone(), agent: aid.clone(), id, ok: !is_error }),
            Event::Receipt(r) => {
                let receipt = rc.lock().unwrap().add(r);
                team.emit(TeamEvent::Receipt { job: jid.clone(), agent: aid.clone(), receipt });
            }
            _ => {}
        };
        let control = RunControl::default();
        agent.run_streaming_all(&mut Session::in_memory(), input, &control, &mut forward).await.map_err(|e| e.to_string())
    }

    async fn parallel(&self, ctx: &StepCtx<'_>, prompts: &[String]) -> Result<Vec<String>, String> {
        // Side by side, each its own turn under its own scope.
        let runs = prompts.iter().enumerate().map(|(i, p)| async move {
            let step = flow::Step { id: format!("{}-{}", ctx.step.id, i + 1), ..ctx.step.clone() };
            let c = StepCtx { run: ctx.run, step: &step, visit: ctx.visit, input: ctx.input, input_from_person: ctx.input_from_person, outputs: ctx.outputs };
            self.agent(&c, p).await
        });
        futures::future::join_all(runs).await.into_iter().collect()
    }

    async fn ask(&self, _: &StepCtx<'_>, question: &str) -> Result<String, String> {
        let q = crate::workbench::Question { id: util::new_id("q"), agent: self.rec.id.clone(), agent_name: self.rec.name.clone(), question: util::clip(question, 1000), choices: Vec::new(), asked_at: util::now() };
        let (tx, rx) = tokio::sync::oneshot::channel();
        self.team.questions.lock().unwrap().insert(q.id.clone(), crate::workbench::PendingQuestion { question: q.clone(), answer: tx });
        self.team.emit(TeamEvent::Question { question: q.clone() });
        self.team.notice(&self.rec.id, &format!("{} has a question", self.rec.name), &util::clip(&q.question, 200), None, true);
        match tokio::time::timeout(ASK_WAIT, rx).await {
            Ok(Ok(answer)) => Ok(answer),
            _ => {
                self.team.questions.lock().unwrap().remove(&q.id);
                Err("You didn't answer within 30 minutes.".into())
            }
        }
    }

    async fn approve(&self, _: &StepCtx<'_>, text: &str) -> Result<bool, String> {
        let broker = Broker { team: Arc::downgrade(&self.team), agent: self.rec.id.clone(), agent_name: self.rec.name.clone(), job: self.job.clone(), mode: Mode::Ask, log: self.log.clone() };
        Ok(broker.approve(&ApprovalRequest { tool: "workflow".into(), effect: Effect::Write, preview: format!("{}: {}", self.flow, util::clip(text, 1500)), reason: "The workflow asks you before it goes on.".into(), from_data: Vec::new() }).await)
    }
}

fn safe(id: &str) -> String {
    id.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').take(64).collect()
}

fn slug(name: &str) -> String {
    let s: String = name.to_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    let s = s.split('-').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("-");
    if s.is_empty() { util::new_id("flow") } else { s.chars().take(48).collect() }
}

/// The steps in words, for the person to read before saying yes.
pub fn describe(f: &Flow) -> String {
    let mut out = format!("Workflow: {}\n", f.name);
    for (i, s) in f.steps.iter().enumerate() {
        let what = match &s.kind {
            flow::StepKind::Agent { prompt } => format!("do: {}", util::clip(prompt, 300)),
            flow::StepKind::Parallel { prompts } => format!("side by side: {}", prompts.iter().map(|p| util::clip(p, 120)).collect::<Vec<_>>().join(" | ")),
            flow::StepKind::Check { then, otherwise, .. } => format!("check, then {then}, otherwise {otherwise}"),
            flow::StepKind::Ask { question } => format!("ask you: {}", util::clip(question, 200)),
            flow::StepKind::Approve { text, .. } => format!("ask your yes: {}", util::clip(text, 200)),
            flow::StepKind::Repeat { step, max, .. } => format!("repeat {step} up to {max} times"),
            flow::StepKind::End { answer } => format!("end: {}", util::clip(answer, 200)),
        };
        let model = s.model.as_deref().map(|m| format!(" [{}]", crate::failover::short(m))).unwrap_or_default();
        out.push_str(&format!("{}. {}{}: {what}\n", i + 1, if s.title.is_empty() { &s.id } else { &s.title }, model));
    }
    out
}

/// An agent's tools for its workflows: propose one (the person approves it), and run one.
pub(crate) fn tools(team: &Arc<Team>, agent: &str) -> Vec<Arc<dyn Tool>> {
    let w = Arc::downgrade(team);
    let aid = agent.to_string();
    let save = tool(
        SAVE_TOOL,
        "Propose a workflow: work you do again and again, written as steps, so it runs the same way each time, each step saved as it goes. \
         The person sees every step and says yes before it is kept. Steps (each: id, title, type, and `next` to the following step's id): \
         {\"type\":\"agent\",\"prompt\":...} one turn of yours; {\"type\":\"parallel\",\"prompts\":[...]} turns side by side; \
         {\"type\":\"check\",\"when\":{\"if\":\"contains\",\"step\":id,\"text\":...} or {\"if\":\"empty\",\"step\":id} or {\"if\":\"yes\",\"step\":id},\"then\":id,\"otherwise\":id}; \
         {\"type\":\"ask\",\"question\":...} asks the person; {\"type\":\"approve\",\"text\":...,\"then\":id} waits for their yes; \
         {\"type\":\"repeat\",\"step\":id,\"until\":cond,\"max\":n}; {\"type\":\"end\",\"answer\":...}. In prompts, {{input}} is what the run was started \
         with and {{steps.<id>}} what that step answered. A step may set `model` to run on a cheaper or stronger model. Only for work that really repeats.",
        json!({"type": "object", "properties": {
            "name": {"type": "string"},
            "start": {"type": "string", "description": "the first step's id"},
            "steps": {"type": "array", "items": {"type": "object"}}
        }, "required": ["name", "start", "steps"]}),
        Effect::Write,
        move |args: Value| {
            let (w, aid) = (w.clone(), aid.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                let f: Flow = serde_json::from_value(json!({"id": "", "name": args["name"], "start": args["start"], "steps": args["steps"]})).map_err(|e| format!("That isn't a workflow: {e}"))?;
                let f = team.save_workflow(&aid, f, "you")?;
                Ok(format!("Kept the workflow \"{}\" (version {}, {} steps). The person can run it from your profile, or ask you to.", f.name, f.version, f.steps.len()))
            }
        },
    )
    .with_preview(|args| {
        let f: Result<Flow, _> = serde_json::from_value(json!({"id": "", "name": args["name"], "start": args["start"], "steps": args["steps"]}));
        match f {
            Ok(f) => describe(&f),
            Err(e) => format!("A workflow that can't be read ({e})"),
        }
    });
    let w = Arc::downgrade(team);
    let aid = agent.to_string();
    let run = tool(
        "run_workflow",
        "Start one of your saved workflows (by its name or id) on an input. It runs in the background, step by step; you'll be free again when it finishes.",
        json!({"type": "object", "properties": {"workflow": {"type": "string"}, "input": {"type": "string"}}, "required": ["workflow"]}),
        Effect::Read,
        move |args: Value| {
            let (w, aid) = (w.clone(), aid.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                let want = args["workflow"].as_str().unwrap_or_default().trim().to_lowercase();
                let f = team.workflows(&aid).into_iter().find(|f| f.id == want || f.name.to_lowercase() == want).ok_or("No workflow by that name.")?;
                // It starts once this job ends: the agent can't run two things at once.
                let (team2, aid2, fid, input) = (team.clone(), aid.clone(), f.id.clone(), args["input"].as_str().unwrap_or_default().to_string());
                tokio::spawn(async move {
                    for _ in 0..600 {
                        if !team2.runs.lock().unwrap().contains_key(&aid2) {
                            // An agent's input is data for the workflow's steps, never an instruction.
                            let _ = team2.start_workflow(&aid2, &fid, input, false).await;
                            return;
                        }
                        tokio::time::sleep(Duration::from_secs(1)).await;
                    }
                });
                Ok(format!("\"{}\" starts as soon as this job ends.", f.name))
            }
        },
    );
    vec![Arc::new(save), Arc::new(run)]
}

/// The tool that keeps a workflow: put to the person every time.
pub const SAVE_TOOL: &str = "save_workflow";

#[cfg(test)]
mod tests {
    use super::*;

    fn team() -> (Arc<Team>, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!("cookie-flows-{}", util::random_hex(4)));
        (Team::open(&dir).unwrap(), dir)
    }

    fn weekly() -> Flow {
        serde_json::from_value(json!({
            "id": "", "name": "Weekly report", "start": "gather",
            "steps": [
                {"id": "gather", "title": "Collect the numbers", "type": "agent", "prompt": "Collect this week's numbers for {{input}}", "next": "write", "model": "anthropic:claude-haiku-5-5"},
                {"id": "write", "title": "Write it", "type": "agent", "prompt": "Write the report from {{steps.gather}}", "next": "end"},
                {"id": "end", "type": "end", "answer": "{{steps.write}}"}
            ]
        }))
        .unwrap()
    }

    #[test]
    fn a_workflow_is_kept_in_versions_and_undone() {
        let (team, dir) = team();
        let f = team.save_workflow("a", weekly(), "you").unwrap();
        assert_eq!((f.id.as_str(), f.version), ("weekly-report", 1));
        let mut g = f.clone();
        g.steps[1].title = "Write it short".into();
        assert_eq!(team.save_workflow("a", g, "you").unwrap().version, 2);
        let back = team.undo_workflow("a", "weekly-report").unwrap();
        assert_eq!(back.steps[1].title, "Write it", "the version before the change");
        assert!(team.undo_workflow("a", "weekly-report").is_err(), "nothing older");
        let text = describe(&back);
        assert!(text.contains("1. Collect the numbers [Haiku 5.5]: do: Collect"), "{text}");
        let mut bad = weekly();
        bad.steps[0].next = Some("ghost".into());
        assert!(team.save_workflow("a", bad, "you").is_err(), "checked before it is kept");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
