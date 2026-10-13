//! `cookie serve`: the harness over stdio, one JSON object per line, so any
//! language can drive it. Tools and approvals the client provides go through
//! the same gates as in Rust: a call that needs a person waits for the
//! client's `approve`, and no answer means no action.

use std::{
    collections::{BTreeMap, HashMap},
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
    budget::Budget,
    error::Result,
    mcp::McpServer,
    message::Message,
    policy::Policy,
    session::Session,
    tool::{Effect, Tool, ToolSpec},
};

/// A `run` message. Unknown fields are refused: a misspelled `allow` must
/// not silently become no allow-list.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RunRequest {
    #[serde(rename = "type")]
    #[allow(dead_code)]
    kind: String,
    pub id: String,
    pub model: String,
    pub input: String,
    #[serde(default)]
    pub instructions: Option<String>,
    /// A session file to resume and append to; in memory if absent.
    #[serde(default)]
    pub session: Option<PathBuf>,
    /// Earlier turns, oldest first, for a client that keeps the conversation
    /// itself (no `session`). Each keeps who wrote it, so a reply that quoted
    /// a screenshot never becomes the person's words on the next run.
    #[serde(default)]
    pub history: Vec<HistoryTurn>,
    #[serde(default)]
    pub tools: Vec<ToolDecl>,
    /// Values the person approved in advance (recipients, hosts).
    #[serde(default)]
    pub allow: Vec<String>,
    /// `false` turns Enkeon off for this run.
    #[serde(default)]
    pub enkeon: Option<bool>,
    /// Dollars per million tokens for this run's model: {input, output, cache_read, cache_write}.
    #[serde(default)]
    pub prices: Option<crate::budget::Price>,
    /// Limits for this run; a limit left out keeps its default.
    #[serde(default)]
    pub budget: Option<BudgetDecl>,
    /// MCP servers connected for this run only.
    #[serde(default)]
    pub mcp: Vec<McpDecl>,
    /// Images sent with the input (a screenshot): one untrusted message
    /// right after it.
    #[serde(default)]
    pub images: Vec<ImageDecl>,
}

/// One earlier turn: `user` is the person's own words, `assistant` the
/// model's reply. `untrusted` marks a turn built from something the person
/// didn't write (a screenshot, a file): it counts as untrusted context.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HistoryTurn {
    pub role: String,
    pub text: String,
    #[serde(default)]
    pub untrusted: bool,
}

fn history_message(turn: &HistoryTurn) -> std::result::Result<Message, String> {
    match turn.role.as_str() {
        "user" | "assistant" => Ok(Message::earlier(turn.role == "user", &turn.text, turn.untrusted)),
        other => Err(format!("history role `{other}`: use user or assistant")),
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImageDecl {
    pub media_type: String,
    /// Base64.
    pub data: String,
    /// `screen` (the default), `web` or `file`.
    #[serde(default)]
    pub source: Option<String>,
    /// Text sent just before the image; untrusted like the image.
    #[serde(default)]
    pub caption: Option<String>,
}

/// The run's images as one untrusted message; `None` without images.
fn images_message(images: &[ImageDecl]) -> std::result::Result<Option<Message>, String> {
    use crate::{label::Source, message::Content};
    let mut source = None;
    let mut parts = Vec::new();
    for image in images {
        let this = match image.source.as_deref().unwrap_or("screen") {
            "screen" => Source::Screen,
            "web" => Source::Web,
            "file" => Source::File,
            other => return Err(format!("image source `{other}`: use screen, web or file")),
        };
        if source.get_or_insert(this.clone()) != &this {
            return Err("the images of one run come from one source".into());
        }
        if let Some(caption) = image.caption.as_ref().filter(|c| !c.trim().is_empty()) {
            parts.push(Content::Text { text: caption.clone() });
        }
        parts.push(Content::Image { media_type: image.media_type.clone(), data: image.data.clone() });
    }
    match source {
        Some(source) => Message::untrusted_images(parts, source).map(Some).map_err(|e| e.to_string()),
        None => Ok(None),
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BudgetDecl {
    #[serde(default)]
    pub max_steps: Option<usize>,
    #[serde(default)]
    pub max_tokens: Option<u64>,
    /// Needs `prices` on the run.
    #[serde(default)]
    pub max_dollars: Option<f64>,
}

/// An MCP server: a `command` to start (with `args`) or a `url` (with
/// `headers`). Every tool asks a person unless `effects` lowers it.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct McpDecl {
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub url: Option<String>,
    /// Sent on every request; never echoed back.
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    /// Tool name to effect (read, write, outbound, destroy).
    #[serde(default)]
    pub effects: BTreeMap<String, String>,
    /// Tool name to the arguments to guard.
    #[serde(default)]
    pub guards: BTreeMap<String, Vec<String>>,
    /// Refuse the server if its tool list no longer hashes to this.
    #[serde(default)]
    pub pin: Option<String>,
    /// Name its tools `<prefix>__<name>`, to keep servers apart.
    #[serde(default)]
    pub prefix: Option<String>,
}

impl McpDecl {
    fn server(&self) -> std::result::Result<McpServer, String> {
        let mut server = match (&self.command, &self.url) {
            (Some(command), None) => {
                if !self.headers.is_empty() {
                    return Err(format!("mcp `{command}`: headers are for a url"));
                }
                McpServer::stdio(command, &self.args.iter().map(String::as_str).collect::<Vec<_>>())
            }
            (None, Some(url)) => {
                if !self.args.is_empty() {
                    return Err("mcp: args are for a command".into());
                }
                self.headers.iter().fold(McpServer::http(url), |server, (name, value)| server.header(name, value))
            }
            _ => return Err("mcp: each server is a command or a url".into()),
        };
        for (tool, name) in &self.effects {
            server = server.effect(tool, effect(name)?);
        }
        for (tool, args) in &self.guards {
            server = args.iter().fold(server, |server, arg| server.guard(tool, arg));
        }
        if let Some(pin) = &self.pin {
            server = server.pin(pin);
        }
        if let Some(prefix) = &self.prefix {
            server = server.prefix(prefix);
        }
        Ok(server)
    }
}

/// A tool the client runs itself.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
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
/// Calls waiting for the client's answer, by the id sent with them, with the
/// run they belong to.
type Waiting = Arc<Mutex<HashMap<String, (String, oneshot::Sender<Value>)>>>;
/// The longest line read from the client.
const MAX_LINE: usize = 16 * 1024 * 1024;

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
        self.waiting.lock().unwrap().insert(id.clone(), (self.run.clone(), tx));
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

/// An error to send back, cut so a huge field (an image) is never echoed.
fn short(text: &str) -> String {
    if text.chars().count() <= 300 {
        return text.to_string();
    }
    format!("{}…", text.chars().take(300).collect::<String>())
}

fn effect(name: &str) -> std::result::Result<Effect, String> {
    serde_json::from_value(json!(name)).map_err(|_| format!("unknown effect `{name}` (read, write, outbound, destroy)"))
}

fn build(base: Agent, request: &RunRequest, wire: &Arc<Wire>) -> std::result::Result<(Agent, Vec<McpServer>), String> {
    let mut agent = base.approver(WireApprover(wire.clone()));
    if let Some(limits) = &request.budget {
        let default = Budget::default();
        agent = agent.budget(Budget {
            max_steps: limits.max_steps.unwrap_or(default.max_steps),
            max_tokens: limits.max_tokens.unwrap_or(default.max_tokens),
            max_dollars: limits.max_dollars,
        });
    }
    if let Some(price) = request.prices {
        agent = agent.prices(price);
    }
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
            foreign: false,
        };
        agent = agent.tool(WireTool { spec, wire: wire.clone() });
    }
    // Checked here, so a bad entry is refused before the run starts.
    let servers = request.mcp.iter().map(McpDecl::server).collect::<std::result::Result<_, _>>()?;
    Ok((agent, servers))
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
    // Cleared by the run itself just before it sends `done` or `error`, so a
    // client that starts the next run on reading `done` is never refused.
    let busy = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mut current: Option<(RunControl, tokio::task::JoinHandle<()>)> = None;
    let mut input = input;
    let mut raw = Vec::new();

    loop {
        raw.clear();
        // Bounded: one line may not exceed MAX_LINE bytes.
        let read = tokio::io::AsyncReadExt::take(&mut input, MAX_LINE as u64 + 1).read_until(b'\n', &mut raw).await?;
        if read == 0 {
            break;
        }
        if raw.len() > MAX_LINE {
            let _ = out.send(json!({"type": "error", "message": format!("a line over {MAX_LINE} bytes was refused")}));
            // Skip the rest of that line.
            while !raw.ends_with(b"\n") {
                raw.clear();
                if tokio::io::AsyncReadExt::take(&mut input, MAX_LINE as u64).read_until(b'\n', &mut raw).await? == 0 {
                    break;
                }
            }
            continue;
        }
        let line = String::from_utf8_lossy(&raw).to_string();
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
        let running = busy.load(Ordering::SeqCst);
        let named = message["id"].clone();
        match message["type"].as_str().unwrap_or_default() {
            "run" => {
                if running {
                    let _ = out.send(json!({"type": "error", "run": named, "message": "a run is already going; cancel it or wait for `done`"}));
                    continue;
                }
                let request: RunRequest = match serde_json::from_value(message) {
                    Ok(request) => request,
                    Err(e) => {
                        let _ = out.send(json!({"type": "error", "run": named, "message": format!("bad run: {}", short(&e.to_string()))}));
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
                let (agent, servers) = match make_agent(&request).map_err(|e| e.to_string()).and_then(|base| build(base, &request, &wire)) {
                    Ok(built) => built,
                    Err(message) => {
                        let _ = out.send(json!({"type": "error", "run": request.id, "message": message}));
                        continue;
                    }
                };
                busy.store(true, Ordering::SeqCst);
                let task = tokio::spawn(run_one(agent, servers, request, control.clone(), out.clone(), busy.clone()));
                current = Some((control, task));
            }
            kind @ ("approve" | "tool_result") => {
                let id = message["id"].as_str().unwrap_or_default().to_string();
                // `a…` ids wait for an `approve`, `t…` ids for a `tool_result`.
                let expected = if kind == "approve" { 'a' } else { 't' };
                let mut waiting_now = waiting.lock().unwrap();
                match waiting_now.get(&id).map(|(run, _)| run.clone()) {
                    Some(run) if id.starts_with(expected) => {
                        if let Some((_, reply)) = waiting_now.remove(&id) {
                            let _ = reply.send(message);
                        }
                    }
                    Some(run) => {
                        let _ = out.send(json!({"type": "error", "run": run, "message": format!("`{id}` is not waiting for a `{kind}`")}));
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
                let _ = out.send(json!({"type": "error", "run": named, "message": format!("unknown message type `{other}`")}));
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

async fn run_one(agent: Agent, servers: Vec<McpServer>, request: RunRequest, control: RunControl, out: Out, busy: Arc<std::sync::atomic::AtomicBool>) {
    use futures::FutureExt;
    let id = request.id.clone();
    // A panic inside the run still ends it with an `error` line.
    let ended = std::panic::AssertUnwindSafe(run_inner(agent, servers, request, control, out.clone())).catch_unwind().await;
    let last = match ended {
        Ok(last) => last,
        Err(panic) => {
            let why = panic.downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| panic.downcast_ref::<String>().cloned()).unwrap_or_default();
            json!({"type": "error", "run": id, "message": format!("the run crashed: {why}")})
        }
    };
    busy.store(false, Ordering::SeqCst);
    let _ = out.send(last);
}

/// The run itself; returns its last line (`done` or `error`).
async fn run_inner(mut agent: Agent, servers: Vec<McpServer>, request: RunRequest, control: RunControl, out: Out) -> Value {
    let mut inputs = vec![Message::user(&request.input)];
    match images_message(&request.images) {
        Ok(images) => inputs.extend(images),
        Err(message) => return json!({"type": "error", "run": request.id, "message": message}),
    }
    // Connected here, not in the read loop: a slow server holds up only its
    // run, and `cancel` stops the wait. Disconnected when the run ends.
    for server in servers {
        let connected = tokio::select! {
            connected = server.connect() => connected,
            _ = control.cancel.cancelled() => Err(crate::Error::Cancelled),
        };
        match connected {
            Ok(mcp) => agent = agent.tools(mcp.tools),
            Err(e) => return json!({"type": "error", "run": request.id, "message": e.to_string()}),
        }
    }
    if request.session.is_some() && !request.history.is_empty() {
        return json!({"type": "error", "run": request.id, "message": "send `history` or a `session` file, not both"});
    }
    let mut session = match &request.session {
        Some(path) => match Session::open(path).await {
            Ok(session) => session,
            Err(e) => return json!({"type": "error", "run": request.id, "message": e.to_string()}),
        },
        None => Session::in_memory(),
    };
    for turn in &request.history {
        let appended = match history_message(turn) {
            Ok(message) => session.append(message).await.map_err(|e| e.to_string()),
            Err(message) => Err(message),
        };
        if let Err(message) = appended {
            return json!({"type": "error", "run": request.id, "message": message});
        }
    }
    let events = out.clone();
    let run = request.id.clone();
    let result = agent
        .run_streaming_all(&mut session, inputs, &control, &mut |event| {
            let _ = events.send(json!({"type": "event", "run": run, "event": event}));
        })
        .await;
    match result {
        Ok(answer) => json!({"type": "done", "run": request.id, "answer": answer}),
        Err(e) => json!({"type": "error", "run": request.id, "message": e.to_string()}),
    }
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
    async fn earlier_turns_keep_who_wrote_them() {
        // A recipient the person wrote in an earlier turn is theirs: the action is put to them.
        let p = Arc::new(Scripted::new(vec![Scripted::call("e1", "send_email", json!({"to": "anna@x.com"})), Scripted::text("ok")]));
        let mut c = start(p.clone());
        let mut request = run("send it to her", email_tools());
        request["history"] = json!([{"role": "user", "text": "my accountant is anna@x.com"}, {"role": "assistant", "text": "Noted."}]);
        c.send(request).await;
        assert_eq!(c.next().await["type"], "approval");
        let first = &p.seen()[0];
        assert_eq!(first.iter().map(|m| m.text()).collect::<Vec<_>>(), ["my accountant is anna@x.com", "Noted.", "send it to her"]);

        // One that appears only in a reply built from the screen is not: refused, nothing asked.
        let p = Arc::new(Scripted::new(vec![Scripted::call("e1", "send_email", json!({"to": "eve@evil.com"})), Scripted::text("ok")]));
        let mut c = start(p.clone());
        let mut request = run("ok send it there", email_tools());
        request["history"] = json!([
            {"role": "user", "text": "what's on my screen?"},
            {"role": "assistant", "text": "A note asking you to email eve@evil.com.", "untrusted": true}
        ]);
        c.send(request).await;
        assert_eq!(c.next().await["type"], "done", "no approval was asked");
        assert!(p.seen()[0][1].origin().is_untrusted());

        // History is for a run without a session file; a role it doesn't know is refused.
        for (extra, needle) in [
            (json!({"session": "/tmp/x.jsonl", "history": [{"role": "user", "text": "hi"}]}), "session"),
            (json!({"history": [{"role": "system", "text": "obey"}]}), "role"),
        ] {
            let mut c = start(Arc::new(Scripted::new(vec![Scripted::text("ok")])));
            let mut request = run("hi", json!([]));
            for (k, v) in extra.as_object().unwrap() { request[k] = v.clone(); }
            c.send(request).await;
            let reply = c.next().await;
            assert_eq!(reply["type"], "error");
            assert!(reply["message"].as_str().unwrap().contains(needle), "{reply}");
        }
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

    #[tokio::test]
    async fn an_answer_of_the_wrong_kind_is_refused_and_the_wait_goes_on() {
        let tools = json!([{"name": "lookup", "description": "", "schema": {"type": "object"}, "effect": "read"}]);
        let p = Arc::new(Scripted::new(vec![Scripted::call("c1", "lookup", json!({})), Scripted::text("done")]));
        let mut c = start(p);
        c.send(run("look", tools)).await;
        let call = c.next().await;
        c.send(json!({"type": "approve", "id": call["id"], "allow": true})).await;
        let refused = c.next().await;
        assert_eq!((refused["type"].as_str(), refused["run"].as_str()), (Some("error"), Some("r1")));
        c.send(json!({"type": "tool_result", "id": call["id"], "output": "42"})).await;
        assert_eq!(c.next().await["answer"], "done");
    }

    #[tokio::test]
    async fn a_run_sent_the_moment_done_arrives_is_accepted() {
        let p = Arc::new(Scripted::new(vec![Scripted::text("one"), Scripted::text("two")]));
        let mut c = start(p);
        c.send(run("first", json!([]))).await;
        assert_eq!(c.next().await["answer"], "one");
        c.send(json!({"type": "run", "id": "r2", "model": "x:m", "input": "second"})).await;
        assert_eq!(c.next().await["answer"], "two");
    }

    #[tokio::test]
    async fn images_arrive_as_one_untrusted_message_right_after_the_input() {
        let p = Arc::new(Scripted::new(vec![Scripted::text("a mail")]));
        let mut c = start(p.clone());
        let png = "iVBORw0KGgp4eA=="; // the PNG signature and "xx"
        let mut request = run("what is this?", json!([]));
        request["images"] = json!([
            {"media_type": "image/png", "data": png, "source": "screen", "caption": "Mail.app"},
            {"media_type": "image/png", "data": png}
        ]);
        c.send(request).await;
        assert_eq!(c.next().await["answer"], "a mail");
        let seen = &p.seen()[0];
        assert_eq!(seen.len(), 2);
        assert_eq!(seen[0], Message::user("what is this?"));
        assert_eq!(seen[1].origin(), &crate::Origin::Untrusted(crate::Source::Screen));
        let image = || crate::Content::Image { media_type: "image/png".into(), data: png.into() };
        assert_eq!(seen[1].content(), &[crate::Content::Text { text: "Mail.app".into() }, image(), image()]);
    }

    #[tokio::test]
    async fn a_bad_image_or_field_ends_the_run_before_the_model_is_called() {
        let p = Arc::new(Scripted::new(vec![Scripted::text("never")]));
        let mut c = start(p.clone());
        let png = |source: &str| json!({"media_type": "image/png", "data": "iVBORw0KGgp4eA==", "source": source});
        for (id, images, expected) in [
            ("r1", json!([{"media_type": "image/svg+xml", "data": "PHN2Zy8+"}]), "image/png, image/jpeg"),
            ("r2", json!([png("tool")]), "screen, web or file"),
            ("r3", json!([{"media_type": "image/png", "data": "iVBORw0KGgp4eA==", "alt": "x"}]), "alt"),
            ("r4", json!([png("screen"), png("web")]), "one source"),
        ] {
            let mut request = run("hi", json!([]));
            request["id"] = json!(id);
            request["images"] = images;
            c.send(request).await;
            let refused = c.next().await;
            assert_eq!((refused["type"].as_str(), refused["run"].as_str()), (Some("error"), Some(id)));
            assert!(refused["message"].as_str().unwrap().contains(expected), "{refused}");
        }
        assert!(p.seen().is_empty());
    }

    #[tokio::test]
    async fn a_misspelled_field_is_refused_and_errors_name_their_run() {
        let p = Arc::new(Scripted::new(vec![Scripted::text("never")]));
        let mut c = start(p);
        c.send(json!({"type": "run", "id": "r9", "model": "x:m", "input": "hi", "allows": ["a@x.com"]})).await;
        let refused = c.next().await;
        assert_eq!(refused["run"], "r9");
        assert!(refused["message"].as_str().unwrap().contains("allows"));
    }

    struct Panics;

    #[async_trait::async_trait]
    impl crate::provider::Provider for Panics {
        async fn complete(&self, _: crate::provider::ModelRequest<'_>) -> crate::Result<crate::provider::ModelResponse> {
            panic!("provider bug")
        }
    }

    #[tokio::test]
    async fn a_run_that_panics_still_ends_with_an_error_line() {
        let mut c = start(Arc::new(Panics));
        c.send(run("hi", json!([]))).await;
        let end = c.next().await;
        assert_eq!((end["type"].as_str(), end["run"].as_str()), (Some("error"), Some("r1")));
        assert!(end["message"].as_str().unwrap().contains("provider bug"));
    }

    #[tokio::test]
    async fn a_run_can_carry_its_own_budget() {
        let tools = json!([{"name": "lookup", "description": "", "schema": {"type": "object"}, "effect": "read"}]);
        let p = Arc::new(Scripted::new(vec![Scripted::call("c1", "lookup", json!({})), Scripted::text("never")]));
        let mut c = start(p);
        let mut message = run("look", tools);
        message["budget"] = json!({"max_steps": 1});
        c.send(message).await;
        let call = c.next().await;
        c.send(json!({"type": "tool_result", "id": call["id"], "output": "42"})).await;
        let end = c.next().await;
        assert_eq!((end["type"].as_str(), end["run"].as_str()), (Some("error"), Some("r1")));
        assert!(end["message"].as_str().unwrap().contains("1 model calls (limit 1)"), "{end}");
        c.send(json!({"type": "run", "id": "r2", "model": "x:m", "input": "hi", "budget": {"max_step": 3}})).await;
        assert!(c.next().await["message"].as_str().unwrap().contains("max_step"), "a misspelled limit is refused");
    }

    fn with_mcp(id: &str, mcp: Value) -> Value {
        json!({"type": "run", "id": id, "model": "x:m", "input": "use memory", "mcp": mcp})
    }

    #[tokio::test]
    async fn mcp_servers_connect_for_the_run_and_ask_a_person_unless_lowered() {
        let server = crate::mcp::fake_http::start(crate::mcp::fake_http::Mode::Normal).await;
        let p = Arc::new(Scripted::new(vec![
            Scripted::call("m1", "recall", json!({"q": "riga"})),
            Scripted::call("m2", "remember", json!({"text": "x"})),
            Scripted::text("done"),
        ]));
        let mut c = start(p.clone());
        c.send(with_mcp("r1", json!([{"url": server.url, "headers": {"Authorization": "Bearer k"}, "effects": {"recall": "read"}}]))).await;
        let ask = c.next().await;
        assert_eq!((ask["type"].as_str(), ask["tool"].as_str()), (Some("approval"), Some("remember")), "recall ran without asking; remember asks");
        c.send(json!({"type": "approve", "id": ask["id"], "allow": false})).await;
        assert_eq!(c.next().await["answer"], "done");
        let asked = p.seen();
        let recalled = &asked[1].last().unwrap().content()[0];
        assert!(matches!(recalled, crate::message::Content::ToolResult { output, is_error: false, .. } if output.contains("recall")), "{recalled:?}");
        let seen = server.seen.lock().unwrap().clone();
        assert!(seen.iter().any(|r| r.method == "tools/call" && r.auth.as_deref() == Some("Bearer k")));
        assert_eq!(seen.iter().filter(|r| r.method == "tools/call").count(), 1, "the declined remember never reached the server");
    }

    #[tokio::test]
    async fn a_server_that_fails_to_connect_or_its_pin_ends_only_that_run() {
        let server = crate::mcp::fake_http::start(crate::mcp::fake_http::Mode::Normal).await;
        let p = Arc::new(Scripted::new(vec![Scripted::text("fine")]));
        let mut c = start(p);
        c.send(with_mcp("r1", json!([{"url": server.url, "pin": "0000"}]))).await;
        let end = c.next().await;
        assert_eq!((end["type"].as_str(), end["run"].as_str()), (Some("error"), Some("r1")));
        assert!(end["message"].as_str().unwrap().contains("pinned"), "{end}");
        c.send(with_mcp("r2", json!([{"command": "/nonexistent/cookie-mcp", "args": ["x"]}]))).await;
        let end = c.next().await;
        assert_eq!((end["type"].as_str(), end["run"].as_str()), (Some("error"), Some("r2")));
        c.send(json!({"type": "run", "id": "r3", "model": "x:m", "input": "hi"})).await;
        assert_eq!(c.next().await["answer"], "fine");
    }

    #[tokio::test]
    async fn an_mcp_entry_must_be_a_command_or_a_url_with_known_effects() {
        let p = Arc::new(Scripted::new(vec![]));
        let mut c = start(p);
        for (bad, says) in [
            (json!([{"command": "x", "url": "https://a"}]), "command or a url"),
            (json!([{"args": ["x"]}]), "command or a url"),
            (json!([{"url": "https://a", "args": ["x"]}]), "args"),
            (json!([{"command": "x", "headers": {"a": "b"}}]), "headers"),
            (json!([{"command": "x", "effects": {"t": "teleport"}}]), "teleport"),
            (json!([{"command": "x", "efects": {}}]), "efects"),
        ] {
            c.send(with_mcp("r1", bad)).await;
            let refused = c.next().await;
            assert_eq!((refused["type"].as_str(), refused["run"].as_str()), (Some("error"), Some("r1")));
            assert!(refused["message"].as_str().unwrap().contains(says), "{refused}");
        }
    }

    #[tokio::test]
    async fn a_bad_run_error_never_echoes_a_huge_payload() {
        let p = Arc::new(Scripted::new(vec![Scripted::text("never")]));
        let mut c = start(p);
        c.send(json!({"type": "run", "id": "r1", "model": "x:m", "input": "hi", "images": "A".repeat(100_000)})).await;
        let error = c.next().await;
        assert!(error["message"].as_str().unwrap().len() < 1_000);
    }
}
