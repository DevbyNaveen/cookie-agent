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
    io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader},
    sync::{oneshot, Mutex as AsyncMutex},
};

use crate::error::{Error, Result};

const PROTOCOL_VERSION: &str = "2025-06-18";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);

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
        loop {
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
                Some(next) if !next.is_empty() => cursor = Some(next.to_string()),
                _ => return Ok(tools),
            }
        }
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

/// Routes responses to their callers; answers `ping`; refuses any other
/// server request (sampling, elicitation, roots), which this client doesn't offer.
async fn read_loop(reader: impl AsyncRead + Send + Unpin, writer: Writer, pending: Pending) {
    let mut lines = BufReader::new(reader).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
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
}
