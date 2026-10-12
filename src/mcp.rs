//! A minimal MCP client: newline-delimited JSON-RPC 2.0 over any byte
//! stream — a spawned server's stdio, or an in-memory pipe in tests.

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
    writer: Writer,
    pending: Pending,
    next_id: AtomicU64,
    reader: tokio::task::JoinHandle<()>,
    _child: Option<tokio::process::Child>,
}

impl Drop for McpClient {
    fn drop(&mut self) {
        self.reader.abort();
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
        let mut client = Self::over(stdout, stdin).await?;
        client._child = Some(child);
        Ok(client)
    }

    /// Talk to a server over any pair of streams, then run the MCP handshake.
    pub async fn over(
        reader: impl AsyncRead + Send + Unpin + 'static,
        writer: impl AsyncWrite + Send + Unpin + 'static,
    ) -> Result<Self> {
        let writer: Writer = Arc::new(AsyncMutex::new(Box::new(writer)));
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let reader = tokio::spawn(read_loop(reader, writer.clone(), pending.clone()));
        let client = Self { writer, pending, next_id: AtomicU64::new(1), reader, _child: None };
        client
            .request(
                "initialize",
                json!({
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "cookie-harness", "version": env!("CARGO_PKG_VERSION")},
                }),
            )
            .await?;
        send(&client.writer, &json!({"jsonrpc": "2.0", "method": "notifications/initialized"})).await?;
        Ok(client)
    }

    async fn request(&self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        send(&self.writer, &json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})).await?;
        match tokio::time::timeout(REQUEST_TIMEOUT, rx).await {
            Ok(Ok(Ok(result))) => Ok(result),
            Ok(Ok(Err(error))) => Err(Error::Mcp(format!("{method}: {error}"))),
            Ok(Err(_)) => Err(Error::Mcp(format!("{method}: the server closed the connection"))),
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
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

/// One MCP server and how its tools may be used. Every tool asks a person
/// (`Outbound`) unless the developer lowers it with `effect`; a server's own
/// annotations are untrusted and can only make a tool stricter.
pub struct McpServer {
    command: String,
    args: Vec<String>,
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
            args: args.iter().map(|a| a.to_string()).collect(),
            pin: None,
            effects: HashMap::new(),
            guards: Vec::new(),
            prefix: None,
        }
    }

    /// Refuse the server if its tool list no longer hashes to this.
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
        let args: Vec<&str> = self.args.iter().map(String::as_str).collect();
        let client = McpClient::spawn(&self.command, &args).await?;
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
}
