//! `cookie serve`: the harness over stdio, one JSON object per line, so any
//! language can drive it. Tools and approvals the client provides go through
//! the same gates as in Rust: a call that needs a person waits for the
//! client's `approve`, and no answer means no action.

use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
};

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::{
    io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt},
    sync::{mpsc, oneshot},
};
use tokio_util::sync::CancellationToken;

use crate::{
    agent::{Agent, RunControl},
    approval::{ApprovalRequest, Approver},
    error::Result,
    message::Message,
    policy::Policy,
    session::Session,
    tool::{Effect, Tool, ToolSpec},
};

/// A `run` message.
#[derive(Debug, Clone, Deserialize)]
pub struct RunRequest {
    pub id: String,
    pub model: String,
    pub input: String,
    #[serde(default)]
    pub instructions: Option<String>,
    /// A session file to resume and append to; in memory if absent.
    #[serde(default)]
    pub session: Option<PathBuf>,
    #[serde(default)]
    pub tools: Vec<ToolDecl>,
    /// Values the person approved in advance (recipients, hosts).
    #[serde(default)]
    pub allow: Vec<String>,
    /// `false` turns Enkeon off for this run.
    #[serde(default)]
    pub enkeon: Option<bool>,
}

/// A tool the client runs itself.
#[derive(Debug, Clone, Deserialize)]
pub struct ToolDecl {
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub schema: Value,
    pub effect: String,
    #[serde(default)]
    pub guard: Vec<String>,
    #[serde(default)]
    pub parallel_safe: bool,
}

type Out = mpsc::UnboundedSender<Value>;
/// Calls waiting for the client's answer, by the id sent with them.
type Waiting = Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>;

struct Wire {
    out: Out,
    waiting: Waiting,
    /// One counter for the whole server: an id is never reused, so a late
    /// answer from an earlier run can't be taken for a later run's.
    next: Arc<AtomicU64>,
    run: String,
    cancel: CancellationToken,
}

/// Takes an id off the waiting list however its wait ends.
struct Unwait<'a>(&'a Waiting, String);

impl Drop for Unwait<'_> {
    fn drop(&mut self) {
        self.0.lock().unwrap().remove(&self.1);
    }
}

impl Wire {
    /// Send `message` with a fresh id and wait for the client's reply to it.
    /// `None` if the run is cancelled or the client goes away first.
    async fn ask(&self, prefix: &str, mut message: Value) -> Option<Value> {
        if self.cancel.is_cancelled() {
            return None;
        }
        let id = format!("{prefix}{}", self.next.fetch_add(1, Ordering::Relaxed));
        let (tx, rx) = oneshot::channel();
        self.waiting.lock().unwrap().insert(id.clone(), tx);
        let _unwait = Unwait(&self.waiting, id.clone());
        message["id"] = json!(id);
        message["run"] = json!(self.run);
        let _ = self.out.send(message);
        tokio::select! {
            reply = rx => reply.ok(),
            _ = self.cancel.cancelled() => None,
        }
    }
}

struct WireTool {
    spec: ToolSpec,
    wire: Arc<Wire>,
}

#[async_trait]
impl Tool for WireTool {
    fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    async fn call(&self, args: Value) -> std::result::Result<String, String> {
        let reply = self
            .wire
            .ask("t", json!({"type": "tool_call", "name": self.spec.name, "args": args}))
            .await
            .ok_or_else(|| "The client did not answer.".to_string())?;
        let output = reply["output"].as_str().unwrap_or_default().to_string();
        if reply["is_error"].as_bool().unwrap_or(false) {
            Err(output)
        } else {
            Ok(output)
        }
    }
}

struct WireApprover(Arc<Wire>);

#[async_trait]
impl Approver for WireApprover {
    async fn approve(&self, request: &ApprovalRequest) -> bool {
        let message = json!({
            "type": "approval",
            "tool": request.tool,
            "effect": request.effect,
            "preview": request.preview,
            "reason": request.reason,
        });
        // No answer is a no.
        self.0.ask("a", message).await.is_some_and(|reply| reply["allow"] == true)
    }
}

fn effect(name: &str) -> std::result::Result<Effect, String> {
    serde_json::from_value(json!(name)).map_err(|_| format!("unknown effect `{name}` (read, write, outbound, destroy)"))
}

fn build(base: Agent, request: &RunRequest, wire: &Arc<Wire>) -> std::result::Result<Agent, String> {
    let mut agent = base.approver(WireApprover(wire.clone()));
    if let Some(instructions) = &request.instructions {
        agent = agent.instructions(instructions.clone());
    }
    if request.enkeon == Some(false) {
        agent = agent.without_enkeon();
    }
    let policy = request.allow.iter().fold(Policy::default(), |policy, value| policy.allow(value));
    agent = agent.policy(policy);
    for decl in &request.tools {
        let spec = ToolSpec {
            name: decl.name.clone(),
            description: decl.description.clone(),
            schema: if decl.schema.is_null() { json!({"type": "object"}) } else { decl.schema.clone() },
            effect: effect(&decl.effect)?,
            guarded_args: decl.guard.clone(),
            parallel_safe: decl.parallel_safe,
            delegates: false,
        };
        agent = agent.tool(WireTool { spec, wire: wire.clone() });
    }
    Ok(agent)
}

/// Serve runs over a line-delimited JSON stream until the input ends.
/// `make_agent` turns a `run` into an agent (the binary uses `Agent::new`);
/// the client's tools, approvals, instructions and allow-list are added here.
pub async fn serve<F>(
    input: impl AsyncBufRead + Unpin,
    mut output: impl AsyncWrite + Unpin + Send + 'static,
    make_agent: F,
) -> Result<()>
where
    F: Fn(&RunRequest) -> Result<Agent>,
{
    let (out, mut lines_out) = mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        while let Some(message) = lines_out.recv().await {
            let mut line = message.to_string();
            line.push('\n');
            if output.write_all(line.as_bytes()).await.is_err() || output.flush().await.is_err() {
                break;
            }
        }
    });
    let waiting: Waiting = Arc::default();
    let next = Arc::new(AtomicU64::new(1));
    let mut current: Option<(RunControl, tokio::task::JoinHandle<()>)> = None;
    let mut lines = input.lines();

    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let message: Value = match serde_json::from_str(&line) {
            Ok(message) => message,
            Err(e) => {
                let _ = out.send(json!({"type": "error", "message": format!("not a JSON line: {e}")}));
                continue;
            }
        };
        let running = current.as_ref().is_some_and(|(_, task)| !task.is_finished());
        match message["type"].as_str().unwrap_or_default() {
            "run" => {
                if running {
                    let _ = out.send(json!({"type": "error", "message": "a run is already going; cancel it or wait for `done`"}));
                    continue;
                }
                let request: RunRequest = match serde_json::from_value(message) {
                    Ok(request) => request,
                    Err(e) => {
                        let _ = out.send(json!({"type": "error", "message": format!("bad run: {e}")}));
                        continue;
                    }
                };
                let control = RunControl::default();
                let wire = Arc::new(Wire {
                    out: out.clone(),
                    waiting: waiting.clone(),
                    next: next.clone(),
                    run: request.id.clone(),
                    cancel: control.cancel.clone(),
                });
                let agent = match make_agent(&request).map_err(|e| e.to_string()).and_then(|base| build(base, &request, &wire)) {
                    Ok(agent) => agent,
                    Err(message) => {
                        let _ = out.send(json!({"type": "error", "run": request.id, "message": message}));
                        continue;
                    }
                };
                let task = tokio::spawn(run_one(agent, request, control.clone(), out.clone()));
                current = Some((control, task));
            }
            "approve" | "tool_result" => {
                let id = message["id"].as_str().unwrap_or_default().to_string();
                match waiting.lock().unwrap().remove(&id) {
                    Some(reply) => {
                        let _ = reply.send(message);
                    }
                    None => {
                        let _ = out.send(json!({"type": "error", "message": format!("nothing is waiting for `{id}`")}));
                    }
                }
            }
            "cancel" => {
                if let Some((control, _)) = &current {
                    control.cancel.cancel();
                }
            }
            "finish_turn" => {
                if let Some((control, _)) = &current {
                    control.finish_turn.cancel();
                }
            }
            other => {
                let _ = out.send(json!({"type": "error", "message": format!("unknown message type `{other}`")}));
            }
        }
    }
    // Input closed: stop the run; anything still waiting is answered "no".
    if let Some((control, task)) = current {
        control.cancel.cancel();
        waiting.lock().unwrap().clear();
        let _ = task.await;
    }
    drop(out);
    let _ = writer.await;
    Ok(())
}

async fn run_one(agent: Agent, request: RunRequest, control: RunControl, out: Out) {
    let mut session = match &request.session {
        Some(path) => match Session::open(path).await {
            Ok(session) => session,
            Err(e) => {
                let _ = out.send(json!({"type": "error", "run": request.id, "message": e.to_string()}));
                return;
            }
        },
        None => Session::in_memory(),
    };
    let events = out.clone();
    let run = request.id.clone();
    let result = agent
        .run_streaming(&mut session, Message::user(&request.input), &control, &mut |event| {
            let _ = events.send(json!({"type": "event", "run": run, "event": event}));
        })
        .await;
    let _ = out.send(match result {
        Ok(answer) => json!({"type": "done", "run": request.id, "answer": answer}),
        Err(e) => json!({"type": "error", "run": request.id, "message": e.to_string()}),
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{agent::Agent, providers::scripted::Scripted};
    use serde_json::{json, Value};
    use std::sync::Arc;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    struct Client {
        tx: tokio::io::WriteHalf<tokio::io::DuplexStream>,
        rx: tokio::io::Lines<BufReader<tokio::io::ReadHalf<tokio::io::DuplexStream>>>,
    }

    impl Client {
        async fn send(&mut self, message: Value) {
            self.tx.write_all(format!("{message}\n").as_bytes()).await.unwrap();
        }
        /// The next line that is not a streamed event.
        async fn next(&mut self) -> Value {
            loop {
                let line = tokio::time::timeout(std::time::Duration::from_secs(3), self.rx.next_line()).await.expect("a line").unwrap().unwrap();
                let message: Value = serde_json::from_str(&line).unwrap();
                if message["type"] != "event" {
                    return message;
                }
            }
        }
    }

    fn start(provider: Arc<dyn crate::provider::Provider>) -> Client {
        start_with_handle(provider).0
    }

    fn start_with_handle(provider: Arc<dyn crate::provider::Provider>) -> (Client, tokio::task::JoinHandle<crate::Result<()>>) {
        let (client, server) = tokio::io::duplex(64 * 1024);
        let (server_read, server_write) = tokio::io::split(server);
        let handle = tokio::spawn(serve(BufReader::new(server_read), server_write, move |_: &RunRequest| Ok(Agent::with_provider(provider.clone(), "m"))));
        let (read, write) = tokio::io::split(client);
        (Client { tx: write, rx: BufReader::new(read).lines() }, handle)
    }

    fn email_tools() -> Value {
        json!([{"name": "send_email", "description": "Send", "schema": {"type": "object"}, "effect": "outbound", "guard": ["to"]}])
    }

    #[tokio::test]
    async fn closing_the_input_while_approvals_wait_ends_serve_and_runs_nothing() {
        let p = Arc::new(Scripted::new(vec![
            Scripted::call_many(&[("e1", "send_email", json!({"to": "anna@x.com"})), ("e2", "send_email", json!({"to": "ben@x.com"}))]),
            Scripted::text("ok"),
        ]));
        let (mut c, handle) = start_with_handle(p);
        c.send(run("email anna@x.com and ben@x.com", email_tools())).await;
        assert_eq!(c.next().await["type"], "approval");
        c.tx.shutdown().await.unwrap(); // end of input
        let ended = tokio::time::timeout(std::time::Duration::from_secs(3), handle).await;
        assert!(ended.is_ok(), "serve hung after the input closed");
        let mut rest = Vec::new();
        while let Ok(Some(line)) = c.rx.next_line().await {
            rest.push(serde_json::from_str::<Value>(&line).unwrap());
        }
        assert!(rest.iter().all(|m| m["type"] != "tool_call"), "nothing ran: {rest:?}");
    }

    #[tokio::test]
    async fn cancel_stops_a_run_waiting_for_the_client_and_the_next_run_starts() {
        let p = Arc::new(Scripted::new(vec![Scripted::call("e1", "send_email", json!({"to": "anna@x.com"})), Scripted::text("second")]));
        let mut c = start(p);
        c.send(run("email anna@x.com", email_tools())).await;
        assert_eq!(c.next().await["type"], "approval");
        c.send(json!({"type": "cancel"})).await;
        let end = c.next().await;
        assert_eq!((end["type"].as_str(), end["run"].as_str()), (Some("error"), Some("r1")));
        c.send(json!({"type": "run", "id": "r2", "model": "x:m", "input": "hi"})).await;
        assert_eq!(c.next().await["answer"], "second");
    }

    #[tokio::test]
    async fn a_late_answer_from_a_cancelled_run_never_reaches_the_next_one() {
        let tools = json!([{"name": "lookup", "description": "", "schema": {"type": "object"}, "effect": "read", "parallel_safe": true}]);
        let p = Arc::new(Scripted::new(vec![Scripted::call("c1", "lookup", json!({})), Scripted::call("c2", "lookup", json!({})), Scripted::text("done")]));
        let mut c = start(p);
        c.send(run("look", tools.clone())).await;
        let first = c.next().await;
        c.send(json!({"type": "cancel"})).await;
        assert_eq!(c.next().await["type"], "error");
        c.send(json!({"type": "run", "id": "r2", "model": "x:m", "input": "look", "tools": tools})).await;
        let second = c.next().await;
        assert_eq!(second["type"], "tool_call");
        assert_ne!(first["id"], second["id"], "ids are never reused");
        c.send(json!({"type": "tool_result", "id": first["id"], "output": "stale"})).await;
        assert!(c.next().await["message"].as_str().unwrap().contains("nothing is waiting"));
        c.send(json!({"type": "tool_result", "id": second["id"], "output": "fresh"})).await;
        assert_eq!(c.next().await["answer"], "done");
    }

    fn run(input: &str, tools: Value) -> Value {
        json!({"type": "run", "id": "r1", "model": "x:m", "input": input, "tools": tools})
    }

    #[tokio::test]
    async fn a_run_streams_events_and_ends_with_the_answer() {
        let (client_io, server) = tokio::io::duplex(64 * 1024);
        let (r, w) = tokio::io::split(server);
        let p = Arc::new(Scripted::new(vec![Scripted::text("hello")]));
        tokio::spawn(serve(BufReader::new(r), w, move |_: &RunRequest| Ok(Agent::with_provider(p.clone(), "m"))));
        let (read, mut write) = tokio::io::split(client_io);
        write.write_all(format!("{}\n", run("hi", json!([]))).as_bytes()).await.unwrap();
        let mut lines = BufReader::new(read).lines();
        let first: Value = serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
        assert_eq!(first, json!({"type": "event", "run": "r1", "event": {"type": "text_delta", "data": "hello"}}));
        loop {
            let m: Value = serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            if m["type"] != "event" {
                assert_eq!(m, json!({"type": "done", "run": "r1", "answer": "hello"}));
                break;
            }
        }
    }

    #[tokio::test]
    async fn a_client_tool_is_called_over_the_wire_and_its_result_is_untrusted() {
        let p = Arc::new(Scripted::new(vec![Scripted::call("c1", "lookup", json!({"q": "x"})), Scripted::text("done")]));
        let mut c = start(p.clone());
        c.send(run("look up x", json!([{"name": "lookup", "description": "Look up", "schema": {"type": "object"}, "effect": "read"}]))).await;
        let call = c.next().await;
        assert_eq!((call["type"].as_str(), call["name"].as_str(), &call["args"]), (Some("tool_call"), Some("lookup"), &json!({"q": "x"})));
        c.send(json!({"type": "tool_result", "id": call["id"], "output": "42"})).await;
        assert_eq!(c.next().await["answer"], "done");
        assert!(p.seen()[1].last().unwrap().origin().is_untrusted());
    }

    #[tokio::test]
    async fn an_action_that_needs_a_person_waits_for_the_client_and_a_no_stops_it() {
        let tools = json!([{"name": "send_email", "description": "Send", "schema": {"type": "object"}, "effect": "outbound", "guard": ["to"]}]);
        for allow in [true, false] {
            let p = Arc::new(Scripted::new(vec![Scripted::call("e1", "send_email", json!({"to": "anna@x.com"})), Scripted::text("ok")]));
            let mut c = start(p);
            c.send(run("email anna@x.com", tools.clone())).await;
            let ask = c.next().await;
            assert_eq!((ask["type"].as_str(), ask["tool"].as_str(), ask["effect"].as_str()), (Some("approval"), Some("send_email"), Some("outbound")));
            c.send(json!({"type": "approve", "id": ask["id"], "allow": allow})).await;
            let next = c.next().await;
            if allow {
                assert_eq!(next["type"], "tool_call");
                c.send(json!({"type": "tool_result", "id": next["id"], "output": "sent"})).await;
                assert_eq!(c.next().await["type"], "done");
            } else {
                assert_eq!(next["type"], "done", "declined: no tool_call was sent");
            }
        }
    }

    struct Hangs;

    #[async_trait::async_trait]
    impl crate::provider::Provider for Hangs {
        async fn complete(&self, _: crate::provider::ModelRequest<'_>) -> crate::Result<crate::provider::ModelResponse> {
            std::future::pending().await
        }
    }

    #[tokio::test]
    async fn the_client_can_cancel_a_run() {
        let mut c = start(Arc::new(Hangs));
        c.send(run("think", json!([]))).await;
        c.send(json!({"type": "cancel"})).await;
        let end = c.next().await;
        assert_eq!((end["type"].as_str(), end["run"].as_str()), (Some("error"), Some("r1")));
        assert!(end["message"].as_str().unwrap().contains("cancel"));
    }

    #[tokio::test]
    async fn a_bad_line_is_answered_and_the_server_keeps_going() {
        let p = Arc::new(Scripted::new(vec![Scripted::text("still here")]));
        let mut c = start(p);
        c.tx.write_all(b"not json\n").await.unwrap();
        assert_eq!(c.next().await["type"], "error");
        c.send(run("hi", json!([{"name": "x", "description": "", "schema": {}, "effect": "teleport"}]))).await;
        assert!(c.next().await["message"].as_str().unwrap().contains("teleport"));
        c.send(run("hi", json!([]))).await;
        assert_eq!(c.next().await["answer"], "still here");
    }
}
