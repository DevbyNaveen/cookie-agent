//! A minimal MCP client: JSON-RPC 2.0 over a spawned server's stdio (or any
//! byte stream), or over Streamable HTTP to a remote server.

use std::{
    collections::HashMap,
    process::Stdio,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

use serde_json::{json, Value};
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader},
    sync::{oneshot, Mutex as AsyncMutex},
};

use async_trait::async_trait;
use sha2::{Digest, Sha256};

use crate::{
    error::{Error, Result},
    tool::{valid_tool_name, Effect, Tool, ToolSpec},
};

const PROTOCOL_VERSION: &str = "2025-06-18";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
/// The longest message accepted from a server; a longer line means the
/// server is broken or hostile, and the connection is dropped.
const MAX_LINE: usize = if cfg!(test) { 64 * 1024 } else { 16 * 1024 * 1024 };
/// Pages of `tools/list` before the server is considered to be looping.
const MAX_PAGES: usize = 100;

type Writer = Arc<AsyncMutex<Box<dyn AsyncWrite + Send + Unpin>>>;
type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<std::result::Result<Value, String>>>>>;

/// One tool as the server describes it. The description and schema are the
/// server's words: untrusted.
#[derive(Debug, Clone, PartialEq)]
pub struct McpToolInfo {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
    pub annotations: Value,
}

pub struct McpClient {
    transport: Transport,
    next_id: AtomicU64,
}

enum Transport {
    Stream {
        writer: Writer,
        pending: Pending,
        reader: tokio::task::JoinHandle<()>,
        _child: Option<tokio::process::Child>,
    },
    Http(Http),
}

/// Streamable HTTP (MCP 2025-03-26 and later): one POST per message; the
/// server names the session in `Mcp-Session-Id` and answers with JSON or SSE.
struct Http {
    client: reqwest::Client,
    url: String,
    /// Sent on every request, e.g. `Authorization`. Never printed.
    headers: Vec<(String, String)>,
    session: Mutex<Option<String>>,
}

impl Drop for McpClient {
    fn drop(&mut self) {
        if let Transport::Stream { reader, .. } = &self.transport {
            reader.abort();
        }
    }
}

async fn send(writer: &Writer, message: &Value) -> Result<()> {
    let mut line = serde_json::to_vec(message)?;
    line.push(b'\n');
    let mut writer = writer.lock().await;
    writer.write_all(&line).await.map_err(|e| Error::Mcp(format!("write: {e}")))?;
    writer.flush().await.map_err(|e| Error::Mcp(format!("write: {e}")))
}

impl McpClient {
    /// Start a server process and talk to it over its stdin/stdout. It is
    /// killed when the client is dropped. Its stderr is discarded.
    pub async fn spawn(command: &str, args: &[&str]) -> Result<Self> {
        let mut child = tokio::process::Command::new(command)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| Error::Mcp(format!("could not start `{command}`: {e}")))?;
        let stdin = child.stdin.take().ok_or_else(|| Error::Mcp("no stdin".into()))?;
        let stdout = child.stdout.take().ok_or_else(|| Error::Mcp("no stdout".into()))?;
        Self::stream(stdout, stdin, Some(child)).await
    }

    /// Talk to a remote server over Streamable HTTP, then run the MCP
    /// handshake. `headers` go on every request (e.g. `Authorization`).
    pub async fn http(url: &str, headers: &[(&str, &str)]) -> Result<Self> {
        let client = Self {
            transport: Transport::Http(Http {
                // No redirects: an MCP endpoint has no reason to move, and a redirect
                // could carry the headers somewhere else.
                client: reqwest::Client::builder()
                    .timeout(REQUEST_TIMEOUT)
                    .redirect(reqwest::redirect::Policy::none())
                    .build().map_err(|e| Error::Mcp(e.to_string()))?,
                url: url.to_string(),
                headers: headers.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
                session: Mutex::new(None),
            }),
            next_id: AtomicU64::new(1),
        };
        client.handshake().await?;
        Ok(client)
    }

    /// Talk to a server over any pair of streams, then run the MCP handshake.
    pub async fn over(
        reader: impl AsyncRead + Send + Unpin + 'static,
        writer: impl AsyncWrite + Send + Unpin + 'static,
    ) -> Result<Self> {
        Self::stream(reader, writer, None).await
    }

    async fn stream(
        reader: impl AsyncRead + Send + Unpin + 'static,
        writer: impl AsyncWrite + Send + Unpin + 'static,
        child: Option<tokio::process::Child>,
    ) -> Result<Self> {
        let writer: Writer = Arc::new(AsyncMutex::new(Box::new(writer)));
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let reader = tokio::spawn(read_loop(reader, writer.clone(), pending.clone()));
        let client = Self { transport: Transport::Stream { writer, pending, reader, _child: child }, next_id: AtomicU64::new(1) };
        client.handshake().await?;
        Ok(client)
    }

    async fn handshake(&self) -> Result<()> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let message = initialize(id);
        self.request("initialize", message["params"].clone()).await?;
        let initialized = initialized();
        match &self.transport {
            Transport::Stream { writer, .. } => send(writer, &initialized).await,
            Transport::Http(http) => http.post(&initialized).await.map(drop),
        }
    }

    async fn request(&self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let message = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        let (writer, pending) = match &self.transport {
            Transport::Stream { writer, pending, .. } => (writer, pending),
            Transport::Http(http) => {
                let reply = match http.post(&message).await {
                    // The server dropped the session: open a new one, then retry once.
                    Err(Error::Mcp(m)) if m == SESSION_GONE => {
                        *http.session.lock().unwrap() = None;
                        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
                        http.post(&initialize(id)).await.map_err(|e| Error::Mcp(format!("{method}: re-initialize: {e}")))?;
                        http.post(&initialized()).await.map_err(|e| Error::Mcp(format!("{method}: re-initialize: {e}")))?;
                        http.post(&message).await
                    }
                    other => other,
                }
                .map_err(|e| Error::Mcp(format!("{method}: {e}")))?;
                return match reply {
                    Some(reply) if reply.get("error").is_some() => Err(Error::Mcp(format!("{method}: {}", reply["error"]))),
                    Some(reply) => Ok(reply["result"].clone()),
                    None => Err(Error::Mcp(format!("{method}: the server sent no answer"))),
                };
            }
        };
        let (tx, rx) = oneshot::channel();
        pending.lock().unwrap().insert(id, tx);
        send(writer, &message).await?;
        match tokio::time::timeout(REQUEST_TIMEOUT, rx).await {
            Ok(Ok(Ok(result))) => Ok(result),
            Ok(Ok(Err(error))) => Err(Error::Mcp(format!("{method}: {error}"))),
            Ok(Err(_)) => Err(Error::Mcp(format!("{method}: the server closed the connection"))),
            Err(_) => {
                pending.lock().unwrap().remove(&id);
                Err(Error::Mcp(format!("{method}: no answer in {}s", REQUEST_TIMEOUT.as_secs())))
            }
        }
    }

    /// Every tool the server offers, following pagination.
    pub async fn list_tools(&self) -> Result<Vec<McpToolInfo>> {
        let mut tools = Vec::new();
        let mut cursor: Option<String> = None;
        let mut seen = std::collections::HashSet::new();
        for _ in 0..MAX_PAGES {
            let params = match &cursor {
                Some(cursor) => json!({"cursor": cursor}),
                None => json!({}),
            };
            let page = self.request("tools/list", params).await?;
            for tool in page["tools"].as_array().into_iter().flatten() {
                let Some(name) = tool["name"].as_str() else {
                    return Err(Error::Mcp(format!("tool without a name: {tool}")));
                };
                tools.push(McpToolInfo {
                    name: name.to_string(),
                    description: tool["description"].as_str().unwrap_or_default().to_string(),
                    input_schema: tool.get("inputSchema").cloned().unwrap_or_else(|| json!({"type": "object"})),
                    annotations: tool.get("annotations").cloned().unwrap_or(Value::Null),
                });
            }
            match page["nextCursor"].as_str() {
                Some(next) if !next.is_empty() => {
                    if !seen.insert(next.to_string()) {
                        return Err(Error::Mcp(format!("tools/list repeated the cursor `{next}`")));
                    }
                    cursor = Some(next.to_string());
                }
                _ => return Ok(tools),
            }
        }
        Err(Error::Mcp(format!("tools/list went past {MAX_PAGES} pages")))
    }

    /// Call a tool. Returns its text output and whether the server marked it an error.
    pub async fn call_tool(&self, name: &str, arguments: Value) -> Result<(String, bool)> {
        let result = self.request("tools/call", json!({"name": name, "arguments": arguments})).await?;
        let text = result["content"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|part| match part["type"].as_str() {
                Some("text") => part["text"].as_str().unwrap_or_default().to_string(),
                Some(other) => format!("[{other}]"),
                None => String::new(),
            })
            .filter(|t| !t.is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        Ok((text, result["isError"].as_bool().unwrap_or(false)))
    }
}

const SESSION_GONE: &str = "the server ended this session";

fn initialize(id: u64) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "cookie-harness", "version": env!("CARGO_PKG_VERSION")},
        },
    })
}

fn initialized() -> Value {
    json!({"jsonrpc": "2.0", "method": "notifications/initialized"})
}

/// Complete SSE events in `text` (CRLF or LF), each event's `data:` lines joined.
fn sse_events(text: &str) -> Vec<Value> {
    let text = text.replace("\r\n", "\n");
    let mut events: Vec<&str> = text.split("\n\n").collect();
    events.pop(); // the part after the last blank line is not complete yet
    events
        .into_iter()
        .filter_map(|event| {
            let data: Vec<&str> = event.lines().filter_map(|l| l.strip_prefix("data:")).map(str::trim_start).collect();
            serde_json::from_str(&data.join("\n")).ok()
        })
        .collect()
}

impl Http {
    /// POST one message. Returns the JSON-RPC response to it, or `None` for a
    /// notification (no body).
    async fn post(&self, message: &Value) -> Result<Option<Value>> {
        use futures::StreamExt;
        let mut request = self
            .client
            .post(&self.url)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/event-stream")
            .header("MCP-Protocol-Version", PROTOCOL_VERSION);
        for (name, value) in &self.headers {
            request = request.header(name, value);
        }
        if let Some(session) = self.session.lock().unwrap().clone() {
            request = request.header("Mcp-Session-Id", session);
        }
        // Errors are built from the status and reqwest's message, never the headers.
        let response = request.body(serde_json::to_vec(message)?).send().await.map_err(|e| Error::Mcp(e.without_url().to_string()))?;
        let status = response.status();
        if status == reqwest::StatusCode::NOT_FOUND && self.session.lock().unwrap().is_some() {
            return Err(Error::Mcp(SESSION_GONE.into()));
        }
        if !status.is_success() {
            return Err(Error::Mcp(format!("HTTP {status}")));
        }
        if let Some(session) = response.headers().get("mcp-session-id").and_then(|v| v.to_str().ok()) {
            *self.session.lock().unwrap() = Some(session.to_string());
        }
        let sse = response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.starts_with("text/event-stream"));
        let ours = |r: &Value| r.get("id") == message.get("id") && (r.get("result").is_some() || r.get("error").is_some());
        let mut body = Vec::new();
        let mut chunks = response.bytes_stream();
        while let Some(chunk) = chunks.next().await {
            body.extend_from_slice(&chunk.map_err(|e| Error::Mcp(e.without_url().to_string()))?);
            if body.len() > MAX_LINE {
                return Err(Error::Mcp(format!("the reply is too large (over {MAX_LINE} bytes)")));
            }
            // A server may keep the stream open after answering: stop at our answer.
            if sse {
                if let Some(reply) = sse_events(&String::from_utf8_lossy(&body)).into_iter().find(ours) {
                    return Ok(Some(reply));
                }
            }
        }
        let text = String::from_utf8_lossy(&body);
        if text.trim().is_empty() {
            return Ok(None);
        }
        if sse {
            return Ok(sse_events(&format!("{text}\n\n")).into_iter().find(ours));
        }
        let reply: Value = serde_json::from_str(&text)?;
        Ok(ours(&reply).then_some(reply))
    }
}

/// One MCP server and how its tools may be used. Every tool asks a person
/// (`Outbound`) unless the developer lowers it with `effect`; a server's own
/// annotations are untrusted and can only make a tool stricter.
pub struct McpServer {
    /// The command to start, or the URL for `http`.
    command: String,
    args: Vec<String>,
    http: bool,
    /// Sent on every HTTP request. Never printed.
    headers: Vec<(String, String)>,
    pin: Option<String>,
    effects: HashMap<String, Effect>,
    guards: Vec<(String, String)>,
    prefix: Option<String>,
}

/// The server's tools, ready for `Agent::tools`, and the hash of its tool
/// list to pass to `pin` next time.
pub struct McpTools {
    pub hash: String,
    pub tools: Vec<Arc<dyn Tool>>,
}

/// SHA-256 over the tool list in name order, as canonical JSON.
pub fn tool_list_hash(tools: &[McpToolInfo]) -> String {
    let mut sorted: Vec<&McpToolInfo> = tools.iter().collect();
    sorted.sort_by(|a, b| a.name.cmp(&b.name));
    let canonical: Vec<Value> = sorted
        .iter()
        .map(|t| json!({"name": t.name, "description": t.description, "inputSchema": t.input_schema, "annotations": t.annotations}))
        .collect();
    let digest = Sha256::digest(serde_json::to_vec(&canonical).unwrap_or_default());
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

impl McpServer {
    pub fn stdio(command: &str, args: &[&str]) -> Self {
        Self {
            command: command.to_string(),
            http: false,
            headers: Vec::new(),
            args: args.iter().map(|a| a.to_string()).collect(),
            pin: None,
            effects: HashMap::new(),
            guards: Vec::new(),
            prefix: None,
        }
    }

    /// Refuse the server if its tool list no longer hashes to this.
    /// A remote server over Streamable HTTP.
    pub fn http(url: &str) -> Self {
        Self { http: true, ..Self::stdio(url, &[]) }
    }

    /// A header for every HTTP request, e.g. `Authorization`.
    pub fn header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.to_string(), value.to_string()));
        self
    }

    pub fn pin(mut self, hash: &str) -> Self {
        self.pin = Some(hash.to_string());
        self
    }

    /// Set a tool's effect (e.g. lower a search tool to `Read`).
    pub fn effect(mut self, tool: &str, effect: Effect) -> Self {
        self.effects.insert(tool.to_string(), effect);
        self
    }

    /// Guard an argument of a tool (see `ToolSpec::guarded_args`).
    pub fn guard(mut self, tool: &str, arg: &str) -> Self {
        self.guards.push((tool.to_string(), arg.to_string()));
        self
    }

    /// Name the tools `<prefix>__<name>`, to keep servers apart.
    pub fn prefix(mut self, prefix: &str) -> Self {
        self.prefix = Some(prefix.to_string());
        self
    }

    pub async fn connect(self) -> Result<McpTools> {
        let client = if self.http {
            let headers: Vec<(&str, &str)> = self.headers.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
            McpClient::http(&self.command, &headers).await?
        } else {
            let args: Vec<&str> = self.args.iter().map(String::as_str).collect();
            McpClient::spawn(&self.command, &args).await?
        };
        self.tools_from(client).await
    }

    /// Build the tools from an already connected client.
    pub async fn tools_from(self, client: McpClient) -> Result<McpTools> {
        let listed = client.list_tools().await?;
        let hash = tool_list_hash(&listed);
        if let Some(pin) = &self.pin {
            if pin != &hash {
                return Err(Error::Mcp(format!(
                    "`{}`: the tool list changed since it was pinned (pinned {pin}, now {hash}); review it before trusting it again",
                    self.command
                )));
            }
        }
        let known = |name: &str| listed.iter().any(|t| t.name == name);
        for name in self.effects.keys().chain(self.guards.iter().map(|(tool, _)| tool)) {
            if !known(name) {
                return Err(Error::Mcp(format!("`{}` has no tool called `{name}`", self.command)));
            }
        }
        let name_of = |name: &str| match &self.prefix {
            Some(prefix) => format!("{prefix}__{name}"),
            None => name.to_string(),
        };
        if let Some(bad) = listed.iter().map(|t| name_of(&t.name)).find(|n| !valid_tool_name(n)) {
            return Err(Error::Mcp(format!(
                "`{}` offers a tool named `{bad}`, which providers reject (letters, digits, _ and -, at most 64)",
                self.command
            )));
        }
        let client = Arc::new(client);
        let tools = listed
            .into_iter()
            .map(|info| {
                let mut effect = self.effects.get(&info.name).copied().unwrap_or(Effect::Outbound);
                if info.annotations["destructiveHint"] == true {
                    effect = Effect::Destroy;
                }
                let spec = ToolSpec {
                    name: name_of(&info.name),
                    description: info.description,
                    schema: info.input_schema,
                    effect,
                    guarded_args: self.guards.iter().filter(|(tool, _)| *tool == info.name).map(|(_, arg)| arg.clone()).collect(),
                    parallel_safe: false,
                    delegates: false,
                };
                Arc::new(McpTool { client: client.clone(), remote_name: info.name, spec }) as Arc<dyn Tool>
            })
            .collect();
        Ok(McpTools { hash, tools })
    }
}

struct McpTool {
    client: Arc<McpClient>,
    remote_name: String,
    spec: ToolSpec,
}

#[async_trait]
impl Tool for McpTool {
    fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    async fn call(&self, args: Value) -> std::result::Result<String, String> {
        match self.client.call_tool(&self.remote_name, args).await {
            Ok((output, false)) => Ok(output),
            Ok((output, true)) => Err(output),
            Err(error) => Err(error.to_string()),
        }
    }
}

/// Routes responses to their callers; answers `ping`; refuses any other
/// server request (sampling, elicitation, roots), which this client doesn't offer.
async fn read_loop(reader: impl AsyncRead + Send + Unpin, writer: Writer, pending: Pending) {
    let mut reader = BufReader::new(reader);
    let mut line = Vec::new();
    loop {
        line.clear();
        // Bounded: never buffer more than MAX_LINE bytes of one message.
        match (&mut reader).take(MAX_LINE as u64 + 1).read_until(b'\n', &mut line).await {
            Ok(0) | Err(_) => break,
            Ok(_) if line.len() > MAX_LINE => break,
            Ok(_) => {}
        }
        let Ok(message) = serde_json::from_slice::<Value>(&line) else { continue };
        match (message.get("id"), message["method"].as_str()) {
            (Some(id), Some(method)) => {
                let reply = if method == "ping" {
                    json!({"jsonrpc": "2.0", "id": id, "result": {}})
                } else {
                    json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": format!("{method} is not supported")}})
                };
                if send(&writer, &reply).await.is_err() {
                    break;
                }
            }
            (Some(id), None) => {
                let Some(id) = id.as_u64() else { continue };
                let Some(caller) = pending.lock().unwrap().remove(&id) else { continue };
                let outcome = match message.get("error") {
                    Some(error) => Err(error["message"].as_str().unwrap_or("error").to_string()),
                    None => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
                };
                let _ = caller.send(outcome);
            }
            _ => {} // notifications
        }
    }
    // The server is gone: every waiting caller gets an error, none hangs.
    pending.lock().unwrap().clear();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tool::Effect;
    use serde_json::json;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    /// A scripted server: answers each request with `respond(method, params)`.
    async fn serve(
        io: tokio::io::DuplexStream,
        respond: impl Fn(&str, &Value) -> Option<Value> + Send + 'static,
    ) {
        let (read, mut write) = tokio::io::split(io);
        let mut lines = BufReader::new(read).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let msg: Value = serde_json::from_str(&line).unwrap();
            let (Some(id), Some(method)) = (msg.get("id"), msg["method"].as_str()) else { continue };
            if let Some(result) = respond(method, &msg["params"]) {
                let reply = json!({"jsonrpc": "2.0", "id": id, "result": result});
                write.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
            }
        }
    }

    fn tool(name: &str) -> Value {
        json!({"name": name, "description": format!("{name} tool"), "inputSchema": {"type": "object"}})
    }

    #[tokio::test]
    async fn initializes_lists_every_page_and_calls_a_tool() {
        let (client_io, server_io) = tokio::io::duplex(64 * 1024);
        tokio::spawn(serve(server_io, |method, params| match method {
            "initialize" => Some(json!({"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake"}})),
            "tools/list" if params.get("cursor").is_none() => Some(json!({"tools": [tool("a"), tool("b")], "nextCursor": "p2"})),
            "tools/list" => Some(json!({"tools": [tool("c")]})),
            "tools/call" => {
                assert_eq!(params["name"], "a");
                assert_eq!(params["arguments"], json!({"x": 1}));
                Some(json!({"content": [{"type": "text", "text": "done"}, {"type": "image", "data": "", "mimeType": "image/png"}], "isError": false}))
            }
            _ => None,
        }));
        let (read, write) = tokio::io::split(client_io);
        let client = McpClient::over(read, write).await.unwrap();
        let tools = client.list_tools().await.unwrap();
        assert_eq!(tools.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), vec!["a", "b", "c"]);
        assert_eq!(tools[0].description, "a tool");
        assert_eq!(client.call_tool("a", json!({"x": 1})).await.unwrap(), ("done\n[image]".to_string(), false));
    }

    #[tokio::test]
    async fn answers_ping_and_refuses_what_it_does_not_offer() {
        let (client_io, server_io) = tokio::io::duplex(64 * 1024);
        let (read, mut write) = tokio::io::split(server_io);
        let server = tokio::spawn(async move {
            let mut lines = BufReader::new(read).lines();
            let init: Value = serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            write.write_all(format!("{}\n", json!({"jsonrpc": "2.0", "id": init["id"], "result": {"protocolVersion": "2025-06-18", "capabilities": {}}})).as_bytes()).await.unwrap();
            let _initialized = lines.next_line().await.unwrap().unwrap();
            write.write_all(b"{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"ping\"}\n").await.unwrap();
            write.write_all(b"{\"jsonrpc\":\"2.0\",\"id\":\"s2\",\"method\":\"sampling/createMessage\",\"params\":{}}\n").await.unwrap();
            let pong: Value = serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            let refusal: Value = serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            (pong, refusal)
        });
        let (r, w) = tokio::io::split(client_io);
        let _client = McpClient::over(r, w).await.unwrap();
        let (pong, refusal) = server.await.unwrap();
        assert_eq!(pong, json!({"jsonrpc": "2.0", "id": "s1", "result": {}}));
        assert_eq!(refusal["id"], "s2");
        assert_eq!(refusal["error"]["code"], -32601);
    }

    #[tokio::test]
    async fn a_server_that_goes_away_fails_the_call_instead_of_hanging() {
        let (client_io, server_io) = tokio::io::duplex(64 * 1024);
        tokio::spawn(async move {
            let (read, mut write) = tokio::io::split(server_io);
            let mut lines = BufReader::new(read).lines();
            let init: Value = serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            write.write_all(format!("{}\n", json!({"jsonrpc": "2.0", "id": init["id"], "result": {"protocolVersion": "2025-06-18", "capabilities": {}}})).as_bytes()).await.unwrap();
            let _initialized = lines.next_line().await.unwrap();
            // then hang up after the handshake
        });
        let (r, w) = tokio::io::split(client_io);
        let client = McpClient::over(r, w).await.unwrap();
        let out = tokio::time::timeout(std::time::Duration::from_secs(2), client.list_tools()).await;
        assert!(matches!(out, Ok(Err(Error::Mcp(_)))), "{out:?}");
    }

    #[tokio::test]
    async fn an_error_result_is_reported_as_an_error() {
        let (client_io, server_io) = tokio::io::duplex(64 * 1024);
        tokio::spawn(serve(server_io, |method, _| match method {
            "initialize" => Some(json!({"protocolVersion": "2025-06-18", "capabilities": {}})),
            "tools/call" => Some(json!({"content": [{"type": "text", "text": "no such repo"}], "isError": true})),
            _ => None,
        }));
        let (r, w) = tokio::io::split(client_io);
        let client = McpClient::over(r, w).await.unwrap();
        assert_eq!(client.call_tool("x", json!({})).await.unwrap(), ("no such repo".to_string(), true));
    }

    fn annotated(name: &str, annotations: Value) -> Value {
        json!({"name": name, "description": format!("{name} tool"), "inputSchema": {"type": "object"}, "annotations": annotations})
    }

    async fn server_with(tools: Vec<Value>) -> McpClient {
        let (client_io, server_io) = tokio::io::duplex(64 * 1024);
        tokio::spawn(serve(server_io, move |method, params| match method {
            "initialize" => Some(json!({"protocolVersion": "2025-06-18", "capabilities": {}})),
            "tools/list" => Some(json!({"tools": tools})),
            "tools/call" if params["name"] == "fail" => Some(json!({"content": [{"type": "text", "text": "boom"}], "isError": true})),
            "tools/call" => Some(json!({"content": [{"type": "text", "text": format!("ran {}", params["name"])}]})),
            _ => None,
        }));
        let (r, w) = tokio::io::split(client_io);
        McpClient::over(r, w).await.unwrap()
    }

    fn effect_of(tools: &McpTools, name: &str) -> Effect {
        tools.tools.iter().find(|t| t.spec().name == name).unwrap().spec().effect
    }

    #[tokio::test]
    async fn every_mcp_tool_asks_a_person_unless_the_developer_lowers_it() {
        let client = server_with(vec![
            annotated("search", json!({"readOnlyHint": true})),
            annotated("post", json!({})),
            annotated("wipe", json!({"destructiveHint": true})),
        ]).await;
        let tools = McpServer::stdio("unused", &[]).effect("search", Effect::Read).effect("wipe", Effect::Read).tools_from(client).await.unwrap();
        assert_eq!(effect_of(&tools, "search"), Effect::Read, "lowered by the developer");
        assert_eq!(effect_of(&tools, "post"), Effect::Outbound, "the server's own hints never lower it");
        assert_eq!(effect_of(&tools, "wipe"), Effect::Destroy, "a destructive hint only ever raises it");
    }

    #[tokio::test]
    async fn a_pinned_server_whose_tools_changed_is_refused() {
        let pinned = McpServer::stdio("unused", &[]).tools_from(server_with(vec![annotated("a", json!({}))]).await).await.unwrap().hash;
        let same = McpServer::stdio("unused", &[]).pin(&pinned).tools_from(server_with(vec![annotated("a", json!({}))]).await).await;
        assert!(same.is_ok());
        let changed = McpServer::stdio("unused", &[])
            .pin(&pinned)
            .tools_from(server_with(vec![json!({"name": "a", "description": "now also emails your files", "inputSchema": {"type": "object"}})]).await)
            .await;
        assert!(matches!(changed, Err(Error::Mcp(m)) if m.contains("changed")));
    }

    #[tokio::test]
    async fn the_hash_does_not_depend_on_tool_order() {
        let one = McpServer::stdio("x", &[]).tools_from(server_with(vec![annotated("a", json!({})), annotated("b", json!({}))]).await).await.unwrap().hash;
        let two = McpServer::stdio("x", &[]).tools_from(server_with(vec![annotated("b", json!({})), annotated("a", json!({}))]).await).await.unwrap().hash;
        assert_eq!(one, two);
        assert_eq!(one.len(), 64, "sha-256 hex");
    }

    #[tokio::test]
    async fn prefixes_names_guards_arguments_and_calls_by_the_server_name() {
        let client = server_with(vec![annotated("send", json!({})), annotated("fail", json!({}))]).await;
        let tools = McpServer::stdio("x", &[]).prefix("mail").guard("send", "to").tools_from(client).await.unwrap();
        let send = tools.tools.iter().find(|t| t.spec().name == "mail__send").unwrap();
        assert_eq!(send.spec().guarded_args, vec!["to".to_string()]);
        assert_eq!(send.call(json!({"to": "anna@x.com"})).await.unwrap(), "ran \"send\"");
        let fail = tools.tools.iter().find(|t| t.spec().name == "mail__fail").unwrap();
        assert_eq!(fail.call(json!({})).await.unwrap_err(), "boom");
    }

    #[tokio::test]
    async fn settings_for_a_tool_the_server_does_not_have_are_refused() {
        let client = server_with(vec![annotated("send", json!({}))]).await;
        let out = McpServer::stdio("x", &[]).guard("sned", "to").tools_from(client).await;
        assert!(matches!(out, Err(Error::Mcp(m)) if m.contains("sned")));
    }

    #[tokio::test]
    async fn a_server_that_repeats_its_cursor_is_refused_instead_of_looping() {
        let (client_io, server_io) = tokio::io::duplex(64 * 1024);
        tokio::spawn(serve(server_io, |method, _| match method {
            "initialize" => Some(json!({"protocolVersion": "2025-06-18", "capabilities": {}})),
            "tools/list" => Some(json!({"tools": [tool("a")], "nextCursor": "same"})),
            _ => None,
        }));
        let (r, w) = tokio::io::split(client_io);
        let client = McpClient::over(r, w).await.unwrap();
        let out = tokio::time::timeout(std::time::Duration::from_secs(2), client.list_tools()).await;
        assert!(matches!(&out, Ok(Err(Error::Mcp(m))) if m.contains("cursor")), "{out:?}");
    }

    #[tokio::test]
    async fn an_endless_line_is_cut_off_instead_of_filling_memory() {
        let (client_io, server_io) = tokio::io::duplex(64 * 1024);
        tokio::spawn(async move {
            let (read, mut write) = tokio::io::split(server_io);
            let mut lines = BufReader::new(read).lines();
            let init: Value = serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            write.write_all(format!("{}\n", json!({"jsonrpc": "2.0", "id": init["id"], "result": {"protocolVersion": "2025-06-18", "capabilities": {}}})).as_bytes()).await.unwrap();
            let _initialized = lines.next_line().await.unwrap();
            let _ = lines.next_line().await;
            let chunk = vec![b'x'; 8 * 1024];
            for _ in 0..(MAX_LINE / chunk.len() + 2) {
                if write.write_all(&chunk).await.is_err() {
                    break;
                }
            }
        });
        let (r, w) = tokio::io::split(client_io);
        let client = McpClient::over(r, w).await.unwrap();
        let out = tokio::time::timeout(std::time::Duration::from_secs(5), client.list_tools()).await;
        assert!(matches!(out, Ok(Err(Error::Mcp(_)))), "{out:?}");
    }

    #[tokio::test]
    async fn a_tool_name_providers_would_reject_is_refused_at_connect() {
        let client = server_with(vec![annotated("repo.search", json!({}))]).await;
        let out = McpServer::stdio("x", &[]).tools_from(client).await;
        assert!(matches!(out, Err(Error::Mcp(m)) if m.contains("repo.search")));
    }

    #[tokio::test]
    async fn speaks_streamable_http_with_a_session_and_sse_or_json_replies() {
        let server = fake_http::start(fake_http::Mode::Normal).await;
        let client = McpClient::http(&server.url, &[("Authorization", "Bearer k")]).await.unwrap();
        let tools = client.list_tools().await.unwrap();
        assert_eq!(tools.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), ["recall", "remember", "forget"]);
        let (text, is_error) = client.call_tool("recall", json!({"query": "x"})).await.unwrap();
        assert_eq!((text.as_str(), is_error), ("recall: {\"query\":\"x\"}", false), "an SSE-framed reply");
        let seen = server.seen.lock().unwrap().clone();
        assert_eq!(seen[0].method, "initialize");
        assert_eq!(seen[0].session, None);
        assert!(seen[1..].iter().all(|r| r.session.as_deref() == Some("s-1")), "every later request carries the session");
        assert!(seen.iter().all(|r| r.auth.as_deref() == Some("Bearer k")));
    }

    #[tokio::test]
    async fn an_oversized_http_reply_is_refused() {
        let server = fake_http::start(fake_http::Mode::Huge).await;
        let client = McpClient::http(&server.url, &[]).await.unwrap();
        assert!(matches!(client.list_tools().await, Err(Error::Mcp(m)) if m.contains("too large")));
    }

    #[tokio::test]
    async fn an_expired_session_is_opened_again_once() {
        let server = fake_http::start(fake_http::Mode::ExpireOnce).await;
        let client = McpClient::http(&server.url, &[]).await.unwrap();
        let (text, _) = client.call_tool("recall", json!({})).await.unwrap();
        assert!(text.starts_with("recall"));
        let seen = server.seen.lock().unwrap().clone();
        assert_eq!(seen.last().unwrap().session.as_deref(), Some("s-2"));
    }

    #[tokio::test]
    async fn an_sse_reply_left_open_returns_as_soon_as_the_answer_arrives() {
        let server = fake_http::start(fake_http::Mode::KeepOpen).await;
        let client = McpClient::http(&server.url, &[]).await.unwrap();
        let out = tokio::time::timeout(std::time::Duration::from_secs(3), client.call_tool("recall", json!({}))).await;
        assert!(matches!(&out, Ok(Ok((t, false))) if t == "open"), "{out:?}");
    }

    #[tokio::test]
    async fn crlf_sse_with_a_notification_first_is_read() {
        let server = fake_http::start(fake_http::Mode::Crlf).await;
        let client = McpClient::http(&server.url, &[]).await.unwrap();
        assert!(client.call_tool("recall", json!({})).await.unwrap().0.starts_with("recall"));
    }
}

/// A tiny Streamable HTTP MCP server for tests: one session `s-1`, three
/// tools, `tools/call` answered as SSE. `huge` makes `tools/list` too big.
#[cfg(test)]
pub(crate) mod fake_http {
    use std::sync::{Arc, Mutex};

    use serde_json::{json, Value};
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };

    #[derive(Debug, Clone)]
    pub struct Seen {
        pub method: String,
        pub session: Option<String>,
        pub auth: Option<String>,
    }

    pub struct Server {
        pub url: String,
        pub seen: Arc<Mutex<Vec<Seen>>>,
    }

    #[derive(Debug, Clone, Copy, PartialEq)]
    pub enum Mode {
        Normal,
        /// `tools/list` is too big.
        Huge,
        /// The first `tools/call` gets 404 (session gone); initialize again mints `s-2`.
        ExpireOnce,
        /// `tools/call` answers on an SSE stream that stays open.
        KeepOpen,
        /// `tools/call` answers in CRLF SSE, after a notification event.
        Crlf,
        /// Never answers anything.
        Hang,
    }

    pub async fn start(mode: Mode) -> Server {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/mcp", listener.local_addr().unwrap());
        let seen: Arc<Mutex<Vec<Seen>>> = Arc::default();
        let log = seen.clone();
        let inits = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else { return };
                let log = log.clone();
                let inits = inits.clone();
                tokio::spawn(async move {
                    if mode == Mode::Hang {
                        tokio::time::sleep(std::time::Duration::from_secs(60)).await;
                        return;
                    }
                    let mut buf = Vec::new();
                    let mut chunk = [0u8; 4096];
                    let (head_end, length) = loop {
                        let n = socket.read(&mut chunk).await.unwrap_or(0);
                        if n == 0 {
                            return;
                        }
                        buf.extend_from_slice(&chunk[..n]);
                        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                            let head = String::from_utf8_lossy(&buf[..end]).to_lowercase();
                            let length = head
                                .lines()
                                .find_map(|l| l.strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap()))
                                .unwrap_or(0);
                            break (end + 4, length);
                        }
                    };
                    while buf.len() < head_end + length {
                        let n = socket.read(&mut chunk).await.unwrap_or(0);
                        if n == 0 {
                            return;
                        }
                        buf.extend_from_slice(&chunk[..n]);
                    }
                    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
                    let header = |name: &str| {
                        head.lines().find_map(|l| {
                            let (k, v) = l.split_once(':')?;
                            k.eq_ignore_ascii_case(name).then(|| v.trim().to_string())
                        })
                    };
                    let body: Value = serde_json::from_slice(&buf[head_end..head_end + length]).unwrap_or(Value::Null);
                    let method = body["method"].as_str().unwrap_or_default().to_string();
                    log.lock().unwrap().push(Seen { method: method.clone(), session: header("mcp-session-id"), auth: header("authorization") });
                    let id = body["id"].clone();
                    let reply = |result: Value| json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string();
                    let session = header("mcp-session-id");
                    if mode == Mode::ExpireOnce && method == "tools/call" && session.as_deref() == Some("s-1") {
                        let _ = socket.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
                        return;
                    }
                    if mode == Mode::KeepOpen && method == "tools/call" {
                        let event = format!("event: message\ndata: {}\n\n", reply(json!({"content": [{"type": "text", "text": "open"}]})));
                        let _ = socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n{event}").as_bytes()).await;
                        tokio::time::sleep(std::time::Duration::from_secs(60)).await;
                        return;
                    }
                    let (status, extra, content_type, payload) = match method.as_str() {
                        "initialize" => {
                            let n = inits.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                            ("200 OK", if n == 1 { "Mcp-Session-Id: s-1\r\n" } else { "Mcp-Session-Id: s-2\r\n" }, "application/json", reply(json!({"protocolVersion": "2025-06-18", "capabilities": {}})))
                        }
                        "tools/list" if mode == Mode::Huge => ("200 OK", "", "application/json", "x".repeat(super::MAX_LINE + 10)),
                        "tools/list" => ("200 OK", "", "application/json", reply(json!({"tools": [
                            {"name": "recall", "description": "Search memory", "inputSchema": {"type": "object"}, "annotations": {"readOnlyHint": true}},
                            {"name": "remember", "description": "Store", "inputSchema": {"type": "object"}},
                            {"name": "forget", "description": "Forget", "inputSchema": {"type": "object"}, "annotations": {"destructiveHint": true}},
                        ]}))),
                        "tools/call" => {
                            let text = format!("{}: {}", body["params"]["name"].as_str().unwrap_or_default(), body["params"]["arguments"]);
                            let answer = reply(json!({"content": [{"type": "text", "text": text}]}));
                            let body = if mode == Mode::Crlf {
                                format!("event: message\r\ndata: {}\r\n\r\nevent: message\r\ndata: {answer}\r\n\r\n", json!({"jsonrpc": "2.0", "method": "notifications/progress", "params": {}}))
                            } else {
                                format!("event: message\ndata: {answer}\n\n")
                            };
                            ("200 OK", "", "text/event-stream", body)
                        }
                        _ => ("202 Accepted", "", "application/json", String::new()),
                    };
                    let response = format!(
                        "HTTP/1.1 {status}\r\n{extra}Content-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
                        payload.len()
                    );
                    let _ = socket.write_all(response.as_bytes()).await;
                });
            }
        });
        Server { url, seen }
    }
}
