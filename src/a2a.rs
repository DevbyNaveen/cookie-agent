//! A2A (Agent2Agent) protocol 1.0 client: another party's agent as a tool.
//!
//! Shapes follow `a2aproject/A2A` 1.0.1 (`specification/a2a.proto`,
//! `docs/specification.md`): JSON-RPC 2.0 over HTTP with PascalCase methods,
//! ProtoJSON (camelCase, `TASK_STATE_*` / `ROLE_*` enums), the card at
//! `/.well-known/agent-card.json`, and `A2A-Version: 1.0` on every request.
//! Only the JSON-RPC binding is spoken; streaming and push are not used.

use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio_util::sync::CancellationToken;

use crate::{
    error::{Error, Result},
    tool::{Effect, Tool, ToolContext, ToolSpec},
};

pub const PROTOCOL_VERSION: &str = "1.0";
pub const CARD_PATH: &str = "/.well-known/agent-card.json";

/// Largest card or reply read.
const MAX_BODY: usize = if cfg!(test) { 64 * 1024 } else { 4 * 1024 * 1024 };
const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);
const POLL_EVERY: Duration = if cfg!(test) { Duration::from_millis(20) } else { Duration::from_secs(1) };
/// How long a whole task may take (`A2aAgent::timeout`).
const TASK_TIMEOUT: Duration = Duration::from_secs(300);

/// What an agent publishes about itself (`AgentCard`). Fields a ProtoJSON
/// writer may leave out when empty default to empty here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentCard {
    pub name: String,
    #[serde(default)]
    pub description: String,
    /// In order of preference.
    pub supported_interfaces: Vec<AgentInterface>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<AgentProvider>,
    #[serde(default)]
    pub version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub documentation_url: Option<String>,
    #[serde(default)]
    pub capabilities: AgentCapabilities,
    /// Name → one of `apiKeySecurityScheme`, `httpAuthSecurityScheme`,
    /// `oauth2SecurityScheme`, `openIdConnectSecurityScheme`, `mtlsSecurityScheme`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub security_schemes: BTreeMap<String, Value>,
    /// `[{"schemes": {"name": {"list": ["scope"]}}}]`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub security_requirements: Vec<Value>,
    #[serde(default)]
    pub default_input_modes: Vec<String>,
    #[serde(default)]
    pub default_output_modes: Vec<String>,
    #[serde(default)]
    pub skills: Vec<AgentSkill>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub signatures: Vec<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentInterface {
    pub url: String,
    /// `JSONRPC`, `GRPC` or `HTTP+JSON`.
    pub protocol_binding: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub tenant: String,
    pub protocol_version: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentProvider {
    pub url: String,
    pub organization: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentCapabilities {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub streaming: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub push_notifications: Option<bool>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub extensions: Vec<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extended_agent_card: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSkill {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub examples: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub input_modes: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub output_modes: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub security_requirements: Vec<Value>,
}

impl AgentCard {
    /// A card for an agent that takes and gives plain text.
    pub fn new(name: &str, description: &str, version: &str) -> Self {
        Self {
            name: name.to_string(),
            description: description.to_string(),
            supported_interfaces: Vec::new(),
            provider: None,
            version: version.to_string(),
            documentation_url: None,
            capabilities: AgentCapabilities::default(),
            security_schemes: BTreeMap::new(),
            security_requirements: Vec::new(),
            default_input_modes: vec!["text/plain".into()],
            default_output_modes: vec!["text/plain".into()],
            skills: Vec::new(),
            signatures: Vec::new(),
            icon_url: None,
        }
    }

    /// Where it answers JSON-RPC, A2A 1.0.
    pub fn jsonrpc(mut self, url: &str) -> Self {
        self.supported_interfaces.push(AgentInterface {
            url: url.to_string(),
            protocol_binding: "JSONRPC".into(),
            tenant: String::new(),
            protocol_version: PROTOCOL_VERSION.into(),
        });
        self
    }

    pub fn provider(mut self, organization: &str, url: &str) -> Self {
        self.provider = Some(AgentProvider { url: url.to_string(), organization: organization.to_string() });
        self
    }

    pub fn skill(mut self, id: &str, name: &str, description: &str, tags: &[&str]) -> Self {
        self.skills.push(AgentSkill {
            id: id.to_string(),
            name: name.to_string(),
            description: description.to_string(),
            tags: tags.iter().map(|t| t.to_string()).collect(),
            examples: Vec::new(),
            input_modes: Vec::new(),
            output_modes: Vec::new(),
            security_requirements: Vec::new(),
        });
        self
    }
}

/// `scheme://host:port` of a URL, the part a credential is bound to.
fn origin(url: &str) -> Option<String> {
    let url = reqwest::Url::parse(url).ok()?;
    Some(format!("{}://{}:{}", url.scheme(), url.host_str()?, url.port_or_known_default()?))
}

fn a2a(message: impl std::fmt::Display) -> Error {
    Error::A2a(message.to_string())
}

/// A remote agent found by its card.
#[derive(Clone)]
pub struct A2aAgent {
    card: AgentCard,
    endpoint: String,
    /// The endpoint is on the site you discovered, or you confirmed it.
    endpoint_confirmed: bool,
    tenant: String,
    /// Header name and value, only when the developer gave a credential.
    auth: Option<(String, String)>,
    client: reqwest::Client,
    timeout: Duration,
    next_id: Arc<AtomicU64>,
}

impl std::fmt::Debug for A2aAgent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("A2aAgent").field("name", &self.card.name).field("auth", &self.auth.as_ref().map(|_| "[hidden]")).finish_non_exhaustive()
    }
}

/// Reads at most `MAX_BODY` bytes.
async fn read_capped(response: reqwest::Response) -> Result<Vec<u8>> {
    use futures::StreamExt;
    let mut body = Vec::new();
    let mut chunks = response.bytes_stream();
    while let Some(chunk) = chunks.next().await {
        body.extend_from_slice(&chunk.map_err(|e| a2a(e.without_url()))?);
        if body.len() > MAX_BODY {
            return Err(a2a(format!("the reply is too large (over {MAX_BODY} bytes)")));
        }
    }
    Ok(body)
}

impl A2aAgent {
    /// Fetches `{origin}/.well-known/agent-card.json` and picks the first
    /// JSON-RPC 1.x interface. https only (plain http only to this machine),
    /// for the card and the interface; no redirects; the card is size-capped.
    pub async fn discover(base_url: &str) -> Result<Self> {
        if !crate::enkeon::safe_for_a_key(base_url) {
            return Err(a2a("an agent's URL must be https (or this machine)"));
        }
        let card_url = reqwest::Url::parse(base_url).and_then(|u| u.join(CARD_PATH)).map_err(a2a)?;
        let client = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(a2a)?;
        let response = client.get(card_url).header("Accept", "application/json").send().await.map_err(|e| a2a(e.without_url()))?;
        if !response.status().is_success() {
            return Err(a2a(format!("the agent card answered HTTP {}", response.status())));
        }
        let card: AgentCard = serde_json::from_slice(&read_capped(response).await?)
            .map_err(|e| a2a(format!("not an agent card: {e}")))?;
        Self::from_card(card, client, base_url)
    }

    fn from_card(card: AgentCard, client: reqwest::Client, base_url: &str) -> Result<Self> {
        if card.name.trim().is_empty() {
            return Err(a2a("the agent card has no name"));
        }
        let Some(interface) = card
            .supported_interfaces
            .iter()
            .find(|i| i.protocol_binding == "JSONRPC" && i.protocol_version.split('.').next() == Some("1"))
        else {
            let offered: Vec<String> = card.supported_interfaces.iter().map(|i| format!("{} {}", i.protocol_binding, i.protocol_version)).collect();
            return Err(a2a(format!("`{}` offers no JSON-RPC A2A 1.x interface (it offers: {})", card.name, offered.join(", "))));
        };
        if !crate::enkeon::safe_for_a_key(&interface.url) {
            return Err(a2a(format!("`{}` answers at a URL that is not https", card.name)));
        }
        // A card on one site may name an endpoint on another; a credential
        // goes there only once the developer confirms that endpoint.
        let endpoint_confirmed = origin(&interface.url).is_some() && origin(&interface.url) == origin(base_url);
        Ok(Self {
            endpoint_confirmed,
            endpoint: interface.url.clone(),
            tenant: interface.tenant.clone(),
            card,
            auth: None,
            client,
            timeout: TASK_TIMEOUT,
            next_id: Arc::new(AtomicU64::new(1)),
        })
    }

    pub fn card(&self) -> &AgentCard {
        &self.card
    }

    /// Sends `secret` the way the card's scheme `scheme` says, on every
    /// request: `httpAuthSecurityScheme` as `Authorization: <scheme> <secret>`,
    /// `apiKeySecurityScheme` in its header, `oauth2`/`openIdConnect` as a
    /// bearer token you obtained. Keys in queries or cookies, and mutual TLS,
    /// are refused.
    pub fn credential(mut self, scheme: &str, secret: &str) -> Result<Self> {
        if !self.endpoint_confirmed {
            return Err(a2a(format!(
                "`{}` sends requests to {}, not the site you discovered; confirm it with allow_endpoint(..) before giving it a credential",
                self.card.name,
                origin(&self.endpoint).unwrap_or_default()
            )));
        }
        let Some(declared) = self.card.security_schemes.get(scheme) else {
            let names: Vec<&String> = self.card.security_schemes.keys().collect();
            return Err(a2a(format!("`{}` declares no scheme `{scheme}` (it declares: {names:?})", self.card.name)));
        };
        let auth = if let Some(http) = declared.get("httpAuthSecurityScheme") {
            let kind = http["scheme"].as_str().filter(|s| !s.is_empty()).ok_or_else(|| a2a("httpAuthSecurityScheme without a scheme"))?;
            ("Authorization".to_string(), format!("{kind} {secret}"))
        } else if let Some(key) = declared.get("apiKeySecurityScheme") {
            match (key["location"].as_str(), key["name"].as_str()) {
                (Some("header"), Some(name)) if !name.is_empty() => (name.to_string(), secret.to_string()),
                (location, _) => return Err(a2a(format!("an API key in `{}` is not supported; only in a header", location.unwrap_or("?")))),
            }
        } else if declared.get("oauth2SecurityScheme").is_some() || declared.get("openIdConnectSecurityScheme").is_some() {
            ("Authorization".to_string(), format!("Bearer {secret}"))
        } else {
            return Err(a2a(format!("scheme `{scheme}` is not supported (mutual TLS or unknown)")));
        };
        reqwest::header::HeaderValue::from_str(&auth.1).map_err(|_| a2a("the credential is not a valid header value"))?;
        self.auth = Some(auth);
        Ok(self)
    }

    /// Confirm the endpoint the card names when it is on another site than
    /// the one you discovered; `endpoint` must match it exactly.
    pub fn allow_endpoint(mut self, endpoint: &str) -> Result<Self> {
        if endpoint != self.endpoint {
            return Err(a2a(format!("the card's endpoint is {}, not {endpoint}", self.endpoint)));
        }
        self.endpoint_confirmed = true;
        Ok(self)
    }

    /// How long one task may take before it is cancelled (default 300 s).
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// This agent as a tool. `Effect::Outbound`: sending a task to another
    /// party always asks a person first. Its answer is untrusted output.
    pub fn tool(&self, name: &str) -> A2aTool {
        let host = reqwest::Url::parse(&self.endpoint).ok().and_then(|u| u.host_str().map(str::to_string)).unwrap_or_default();
        A2aTool {
            spec: ToolSpec {
                name: name.to_string(),
                description: crate::mcp::foreign_description(&format!(
                    "Send a task to the remote agent \"{}\" at {host}. Its card says: {}",
                    self.card.name, self.card.description
                )),
                schema: json!({
                    "type": "object",
                    "properties": {"message": {"type": "string", "description": "The whole task: the agent sees nothing else."}},
                    "required": ["message"],
                }),
                effect: Effect::Outbound,
                guarded_args: Vec::new(),
                parallel_safe: false,
                delegates: false,
                foreign: true,
            },
            host,
            agent: self.clone(),
        }
    }

    async fn rpc(&self, method: &str, mut params: Value) -> Result<Value> {
        if !self.tenant.is_empty() {
            params["tenant"] = json!(self.tenant);
        }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let mut request = self
            .client
            .post(&self.endpoint)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .header("A2A-Version", PROTOCOL_VERSION);
        if let Some((name, value)) = &self.auth {
            request = request.header(name, value);
        }
        let body = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        // Errors carry the status and reqwest's message, never headers or the URL.
        let response = request.body(body.to_string()).send().await.map_err(|e| a2a(e.without_url()))?;
        let status = response.status();
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            let declared: Vec<&String> = self.card.security_schemes.keys().collect();
            return Err(a2a(format!("HTTP {status}: `{}` refused the credential (its card declares {declared:?})", self.card.name)));
        }
        if !status.is_success() {
            return Err(a2a(format!("HTTP {status}")));
        }
        let reply: Value = serde_json::from_slice(&read_capped(response).await?).map_err(|e| a2a(format!("not JSON-RPC: {e}")))?;
        if let Some(error) = reply.get("error") {
            return Err(a2a(format!("{} ({})", error["message"].as_str().unwrap_or("error"), error["code"])));
        }
        if reply["id"] != json!(id) {
            return Err(a2a("a reply to another request"));
        }
        reply.get("result").cloned().ok_or_else(|| a2a("a reply without a result"))
    }

    /// Sends `text`, then polls the task until it ends, `timeout` passes, or
    /// `cancel` fires; the last two cancel the task at the agent.
    pub async fn send(&self, text: &str, cancel: &CancellationToken) -> Result<String> {
        let task_id: Mutex<Option<String>> = Mutex::new(None);
        let work = async {
            let message = json!({"messageId": message_id(), "role": "ROLE_USER", "parts": [{"text": text}]});
            let sent = self.rpc("SendMessage", json!({"message": message, "configuration": {"returnImmediately": true}})).await?;
            if let Some(reply) = sent.get("message") {
                return Ok(parts_text(&reply["parts"]));
            }
            let mut task = sent.get("task").cloned().ok_or_else(|| a2a("SendMessage returned neither a task nor a message"))?;
            let id = task["id"].as_str().filter(|id| !id.is_empty()).ok_or_else(|| a2a("a task without an id"))?.to_string();
            *task_id.lock().unwrap() = Some(id.clone());
            loop {
                if let Some(done) = finished(&task) {
                    return done;
                }
                tokio::time::sleep(POLL_EVERY).await;
                task = self.rpc("GetTask", json!({"id": id})).await?;
            }
        };
        let ended = tokio::select! {
            ended = tokio::time::timeout(self.timeout, work) => ended,
            _ = cancel.cancelled() => {
                self.cancel_task(&task_id).await;
                return Err(Error::Cancelled);
            }
        };
        match ended {
            Ok(result) => result,
            Err(_) => {
                self.cancel_task(&task_id).await;
                Err(a2a(format!("`{}` did not finish in {} s; the task was cancelled", self.card.name, self.timeout.as_secs_f32())))
            }
        }
    }

    /// Best effort, bounded: the caller has already given up.
    async fn cancel_task(&self, task_id: &Mutex<Option<String>>) {
        let id = task_id.lock().unwrap().clone();
        if let Some(id) = id {
            let _ = tokio::time::timeout(Duration::from_secs(5), self.rpc("CancelTask", json!({"id": id}))).await;
        }
    }
}

fn message_id() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    format!("cookie-{nanos:x}-{:x}-{:x}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

/// Text of a list of parts; other kinds are named, not inlined.
fn parts_text(parts: &Value) -> String {
    let parts = parts.as_array().map(Vec::as_slice).unwrap_or_default();
    parts
        .iter()
        .map(|part| {
            if let Some(text) = part["text"].as_str() {
                text.to_string()
            } else if let Some(data) = part.get("data") {
                data.to_string()
            } else if let Some(url) = part["url"].as_str() {
                format!("[file: {url}]")
            } else if let Some(raw) = part["raw"].as_str() {
                format!("[{} bytes of {} not shown]", raw.len() * 3 / 4, part["mediaType"].as_str().unwrap_or("data"))
            } else {
                "[an empty part]".to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// `Some` once the task is over: its artifacts (or final message), or why not.
fn finished(task: &Value) -> Option<Result<String>> {
    let state = task["status"]["state"].as_str().unwrap_or("TASK_STATE_UNSPECIFIED");
    let said = parts_text(&task["status"]["message"]["parts"]);
    match state {
        "TASK_STATE_COMPLETED" => {
            let artifacts: Vec<String> = task["artifacts"].as_array().map(Vec::as_slice).unwrap_or_default().iter().map(|a| parts_text(&a["parts"])).collect();
            let output = if artifacts.is_empty() { said } else { artifacts.join("\n") };
            Some(Ok(if output.is_empty() { "(no output)".into() } else { output }))
        }
        "TASK_STATE_FAILED" | "TASK_STATE_CANCELED" | "TASK_STATE_REJECTED" => Some(Err(a2a(format!("the task ended {state}: {said}")))),
        // Interrupted: a single tool call can't answer, so it ends here.
        "TASK_STATE_INPUT_REQUIRED" | "TASK_STATE_AUTH_REQUIRED" => Some(Err(a2a(format!("the agent stopped with {state}: {said}")))),
        _ => None,
    }
}

/// A remote A2A agent as a tool (`A2aAgent::tool`).
pub struct A2aTool {
    spec: ToolSpec,
    host: String,
    agent: A2aAgent,
}

impl A2aTool {
    async fn run(&self, args: &Value, cancel: &CancellationToken) -> std::result::Result<String, String> {
        let Some(text) = args["message"].as_str().filter(|t| !t.trim().is_empty()) else {
            return Err("needs a `message`".into());
        };
        // Who answered, in the output: the label only names the tool.
        let from = format!("From the remote agent \"{}\" at {}", self.agent.card.name, self.host);
        match self.agent.send(text, cancel).await {
            Ok(answer) => Ok(format!("{from}:\n{answer}")),
            Err(Error::Cancelled) => Err("cancelled".into()),
            Err(error) => Err(format!("{from}: {error}")),
        }
    }
}

#[async_trait]
impl Tool for A2aTool {
    fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    async fn call(&self, args: Value) -> std::result::Result<String, String> {
        self.run(&args, &CancellationToken::new()).await
    }

    async fn call_in(&self, args: Value, context: &ToolContext) -> std::result::Result<String, String> {
        self.run(&args, &context.cancel).await
    }

    fn preview(&self, args: &Value) -> String {
        format!(
            "Send to the remote agent \"{}\" at {}: {}",
            self.agent.card.name,
            self.host,
            args["message"].as_str().unwrap_or("(no message)")
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mcp::fake_http::{header, read_request};
    use tokio::{io::AsyncWriteExt, net::TcpListener};

    #[derive(Clone, Copy, PartialEq)]
    enum Mode {
        /// Submitted, working once, then completed with an artifact.
        Normal,
        /// Answers SendMessage with a message, no task.
        Message,
        /// Never leaves working.
        Hang,
        Fail,
        /// The card is a redirect.
        Redirect,
        /// The card is too large.
        Huge,
        /// Only JSON-RPC 0.3 and gRPC.
        OldOnly,
        /// 401 unless `Authorization: Bearer tok`.
        Auth,
    }

    #[derive(Debug, Clone)]
    struct Seen {
        method: String,
        params: Value,
        version: Option<String>,
        auth: Option<String>,
        api_key: Option<String>,
    }

    struct Server {
        base: String,
        seen: Arc<Mutex<Vec<Seen>>>,
    }

    fn card_json(rpc: &str, mode: Mode) -> Value {
        let interfaces = if mode == Mode::OldOnly {
            json!([{"url": rpc, "protocolBinding": "JSONRPC", "protocolVersion": "0.3"}, {"url": rpc, "protocolBinding": "GRPC", "protocolVersion": "1.0"}])
        } else {
            json!([{"url": rpc, "protocolBinding": "GRPC", "protocolVersion": "1.0"}, {"url": rpc, "protocolBinding": "JSONRPC", "protocolVersion": "1.0", "tenant": "t1"}])
        };
        json!({
            "name": "Route Planner",
            "description": "Plans routes.",
            "supportedInterfaces": interfaces,
            "version": "1.2.0",
            "capabilities": {"streaming": true},
            "securitySchemes": {
                "bearer": {"httpAuthSecurityScheme": {"scheme": "Bearer"}},
                "key": {"apiKeySecurityScheme": {"location": "header", "name": "X-API-Key"}},
                "q": {"apiKeySecurityScheme": {"location": "query", "name": "k"}},
                "google": {"openIdConnectSecurityScheme": {"openIdConnectUrl": "https://accounts.google.com/.well-known/openid-configuration"}},
                "tls": {"mtlsSecurityScheme": {}}
            },
            "securityRequirements": [{"schemes": {"bearer": {"list": []}}}],
            "defaultInputModes": ["text/plain"],
            "defaultOutputModes": ["text/plain"],
            "skills": [{"id": "route", "name": "Route", "description": "Plans a route", "tags": ["maps"]}]
        })
    }

    async fn start(mode: Mode) -> Server {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let rpc = format!("{base}/rpc");
        let seen: Arc<Mutex<Vec<Seen>>> = Arc::default();
        let log = seen.clone();
        let polls = Arc::new(AtomicU64::new(0));
        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else { return };
                let (log, polls, rpc) = (log.clone(), polls.clone(), rpc.clone());
                tokio::spawn(async move {
                    let Some((head, body)) = read_request(&mut socket).await else { return };
                    let path = head.split_whitespace().nth(1).unwrap_or_default().to_string();
                    let (status, extra, payload) = if path == CARD_PATH {
                        match mode {
                            Mode::Redirect => ("302 Found", format!("Location: {}/elsewhere\r\n", base_of(&rpc)), String::new()),
                            Mode::Huge => ("200 OK", String::new(), format!("{{\"name\": \"{}\"}}", "x".repeat(MAX_BODY))),
                            _ => ("200 OK", String::new(), card_json(&rpc, mode).to_string()),
                        }
                    } else {
                        let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
                        let method = body["method"].as_str().unwrap_or_default().to_string();
                        let auth = header(&head, "authorization");
                        log.lock().unwrap().push(Seen {
                            method: method.clone(),
                            params: body["params"].clone(),
                            version: header(&head, "a2a-version"),
                            auth: auth.clone(),
                            api_key: header(&head, "x-api-key"),
                        });
                        if mode == Mode::Auth && auth.as_deref() != Some("Bearer tok") {
                            ("401 Unauthorized", String::new(), String::new())
                        } else {
                            let task = |state: &str, artifacts: Value| json!({"id": "task-1", "contextId": "c-1", "status": {"state": state}, "artifacts": artifacts});
                            let result = match (method.as_str(), mode) {
                                ("SendMessage", Mode::Message) => json!({"message": {"messageId": "m-2", "role": "ROLE_AGENT", "parts": [{"text": "direct answer"}]}}),
                                ("SendMessage", _) => json!({"task": task("TASK_STATE_SUBMITTED", json!([]))}),
                                ("GetTask", Mode::Hang) => task("TASK_STATE_WORKING", json!([])),
                                ("GetTask", Mode::Fail) => json!({"id": "task-1", "status": {"state": "TASK_STATE_FAILED", "message": {"messageId": "m-3", "role": "ROLE_AGENT", "parts": [{"text": "no road"}]}}}),
                                ("GetTask", _) if polls.fetch_add(1, Ordering::SeqCst) == 0 => task("TASK_STATE_WORKING", json!([])),
                                ("GetTask", _) => task("TASK_STATE_COMPLETED", json!([{"artifactId": "a-1", "parts": [{"text": "Take the A2."}, {"data": {"km": 12}}]}])),
                                ("CancelTask", _) => task("TASK_STATE_CANCELED", json!([])),
                                _ => Value::Null,
                            };
                            let reply = if result.is_null() {
                                json!({"jsonrpc": "2.0", "id": body["id"], "error": {"code": -32601, "message": "Method not found"}})
                            } else {
                                json!({"jsonrpc": "2.0", "id": body["id"], "result": result})
                            };
                            ("200 OK", String::new(), reply.to_string())
                        }
                    };
                    let response = format!(
                        "HTTP/1.1 {status}\r\n{extra}Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
                        payload.len()
                    );
                    let _ = socket.write_all(response.as_bytes()).await;
                });
            }
        });
        Server { base, seen }
    }

    fn base_of(rpc: &str) -> &str {
        rpc.trim_end_matches("/rpc")
    }

    fn methods(server: &Server) -> Vec<String> {
        server.seen.lock().unwrap().iter().map(|s| s.method.clone()).collect()
    }

    #[tokio::test]
    async fn discovers_the_card_sends_a_task_and_polls_until_it_completes() {
        let server = start(Mode::Normal).await;
        let agent = A2aAgent::discover(&server.base).await.unwrap();
        assert_eq!(agent.card().name, "Route Planner");
        let t = agent.tool("route_planner");
        assert_eq!(t.spec().effect, Effect::Outbound);
        assert!(t.spec().description.contains("\"Route Planner\" at 127.0.0.1"));
        assert!(t.preview(&json!({"message": "Riga to Jurmala"})).ends_with("at 127.0.0.1: Riga to Jurmala"));

        let out = t.call(json!({"message": "Riga to Jurmala"})).await.unwrap();
        assert_eq!(out, "From the remote agent \"Route Planner\" at 127.0.0.1:\nTake the A2.\n{\"km\":12}");
        assert_eq!(methods(&server), ["SendMessage", "GetTask", "GetTask"]);
        let seen = server.seen.lock().unwrap().clone();
        let sent = &seen[0].params;
        assert_eq!(sent["message"]["role"], "ROLE_USER");
        assert_eq!(sent["message"]["parts"], json!([{"text": "Riga to Jurmala"}]));
        assert!(sent["message"]["messageId"].as_str().is_some_and(|id| !id.is_empty()));
        assert_eq!(sent["configuration"]["returnImmediately"], true);
        assert_eq!(sent["tenant"], "t1", "the tenant of the chosen interface goes on every request");
        assert_eq!(seen[1].params, json!({"id": "task-1", "tenant": "t1"}));
        assert!(seen.iter().all(|s| s.version.as_deref() == Some("1.0") && s.auth.is_none()), "no credential was given, none is sent");
    }

    #[tokio::test]
    async fn a_direct_message_reply_is_the_answer() {
        let server = start(Mode::Message).await;
        let out = A2aAgent::discover(&server.base).await.unwrap().tool("r").call(json!({"message": "hi"})).await.unwrap();
        assert!(out.ends_with(":\ndirect answer"), "{out}");
        assert_eq!(methods(&server), ["SendMessage"]);
    }

    #[tokio::test]
    async fn a_failed_task_is_an_error_with_what_the_agent_said() {
        let server = start(Mode::Fail).await;
        let out = A2aAgent::discover(&server.base).await.unwrap().tool("r").call(json!({"message": "hi"})).await.unwrap_err();
        assert!(out.contains("TASK_STATE_FAILED: no road") && out.starts_with("From the remote agent"), "{out}");
    }

    #[tokio::test]
    async fn a_task_that_runs_too_long_is_cancelled_at_the_agent() {
        let server = start(Mode::Hang).await;
        let agent = A2aAgent::discover(&server.base).await.unwrap().timeout(Duration::from_millis(150));
        let out = agent.tool("r").call(json!({"message": "hi"})).await.unwrap_err();
        assert!(out.contains("did not finish in 0.15 s"), "{out}");
        let seen = server.seen.lock().unwrap().clone();
        let last = seen.last().unwrap();
        assert_eq!((last.method.as_str(), &last.params), ("CancelTask", &json!({"id": "task-1", "tenant": "t1"})));
    }

    #[tokio::test]
    async fn cancelling_the_run_cancels_the_task() {
        let server = start(Mode::Hang).await;
        let t = A2aAgent::discover(&server.base).await.unwrap().tool("r");
        let context = ToolContext::default();
        let cancel = context.cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            cancel.cancel();
        });
        let out = tokio::time::timeout(Duration::from_secs(2), t.call_in(json!({"message": "hi"}), &context)).await.unwrap();
        assert_eq!(out.unwrap_err(), "cancelled");
        assert_eq!(methods(&server).last().unwrap(), "CancelTask");
    }

    #[tokio::test]
    async fn a_credential_is_sent_only_as_the_card_declares_and_only_when_given() {
        let server = start(Mode::Auth).await;
        let agent = A2aAgent::discover(&server.base).await.unwrap();
        let refused = agent.tool("r").call(json!({"message": "hi"})).await.unwrap_err();
        assert!(refused.contains("401") && refused.contains("bearer"), "{refused}");

        let out = agent.clone().credential("bearer", "tok").unwrap().tool("r").call(json!({"message": "hi"})).await.unwrap();
        assert!(out.ends_with("Take the A2.\n{\"km\":12}"), "{out}");

        let keyed = agent.clone().credential("key", "k-1").unwrap();
        let _ = keyed.tool("r").call(json!({"message": "hi"})).await;
        assert_eq!(server.seen.lock().unwrap().last().unwrap().api_key.as_deref(), Some("k-1"));
        assert!(format!("{keyed:?}").contains("[hidden]") && !format!("{keyed:?}").contains("k-1"));

        let oidc = agent.clone().credential("google", "id-tok").unwrap();
        assert_eq!(oidc.auth.unwrap().1, "Bearer id-tok");
        for (scheme, why) in [("q", "query"), ("tls", "not supported"), ("nope", "declares no scheme")] {
            let error = agent.clone().credential(scheme, "s").unwrap_err().to_string();
            assert!(error.contains(why), "{scheme}: {error}");
        }
    }

    #[tokio::test]
    async fn a_card_that_redirects_is_too_large_or_offers_no_jsonrpc_1_is_refused() {
        for (mode, why) in [(Mode::Redirect, "HTTP 302"), (Mode::Huge, "too large"), (Mode::OldOnly, "no JSON-RPC A2A 1.x")] {
            let server = start(mode).await;
            let error = A2aAgent::discover(&server.base).await.unwrap_err().to_string();
            assert!(error.contains(why), "{error}");
        }
    }

    #[tokio::test]
    async fn plain_http_to_another_machine_is_refused() {
        let error = A2aAgent::discover("http://agent.example.com").await.unwrap_err().to_string();
        assert!(error.contains("https"), "{error}");
        let card = AgentCard::new("x", "y", "1").jsonrpc("http://agent.example.com/rpc");
        let error = A2aAgent::from_card(card, reqwest::Client::new(), "https://agent.example.com").unwrap_err().to_string();
        assert!(error.contains("not https"), "{error}");
    }

    #[test]
    fn a_card_built_here_has_the_spec_json_shape() {
        let card = AgentCard::new("Cookie", "Answers questions", "0.1.0")
            .jsonrpc("https://cookie.example.com/a2a")
            .provider("Example", "https://example.com")
            .skill("ask", "Ask", "Answers a question", &["qa"]);
        assert_eq!(
            serde_json::to_value(&card).unwrap(),
            json!({
                "name": "Cookie",
                "description": "Answers questions",
                "supportedInterfaces": [{"url": "https://cookie.example.com/a2a", "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}],
                "provider": {"url": "https://example.com", "organization": "Example"},
                "version": "0.1.0",
                "capabilities": {},
                "defaultInputModes": ["text/plain"],
                "defaultOutputModes": ["text/plain"],
                "skills": [{"id": "ask", "name": "Ask", "description": "Answers a question", "tags": ["qa"]}]
            })
        );
    }

    /// The sample card from the spec (section 8.5), parsed and written back unchanged.
    #[test]
    fn the_spec_sample_card_round_trips() {
        let sample = json!({
            "name": "GeoSpatial Route Planner Agent",
            "description": "Provides advanced route planning.",
            "supportedInterfaces": [
                {"url": "https://georoute-agent.example.com/a2a/v1", "protocolBinding": "JSONRPC", "protocolVersion": "1.0"},
                {"url": "https://georoute-agent.example.com/a2a/grpc", "protocolBinding": "GRPC", "protocolVersion": "1.0"}
            ],
            "provider": {"organization": "Example Geo Services Inc.", "url": "https://www.examplegeoservices.com"},
            "iconUrl": "https://georoute-agent.example.com/icon.png",
            "version": "1.2.0",
            "documentationUrl": "https://docs.examplegeoservices.com/georoute-agent/api",
            "capabilities": {"streaming": true, "pushNotifications": true, "extendedAgentCard": true},
            "securitySchemes": {"google": {"openIdConnectSecurityScheme": {"openIdConnectUrl": "https://accounts.google.com/.well-known/openid-configuration"}}},
            "securityRequirements": [{"schemes": {"google": {"list": ["openid", "profile", "email"]}}}],
            "defaultInputModes": ["application/json", "text/plain"],
            "defaultOutputModes": ["application/json", "image/png"],
            "skills": [{"id": "route-optimizer-traffic", "name": "Traffic-Aware Route Optimizer", "description": "Calculates routes.", "tags": ["maps"], "examples": ["Plan a route"], "inputModes": ["text/plain"], "outputModes": ["application/json"]}],
            "signatures": [{"protected": "eyJhbGciOiJFUzI1NiJ9", "signature": "QFdk"}]
        });
        let card: AgentCard = serde_json::from_value(sample.clone()).unwrap();
        assert_eq!(serde_json::to_value(&card).unwrap(), sample);
    }

    #[test]
    fn a_credential_goes_to_another_site_only_once_confirmed() {
        let mut card = AgentCard::new("partner", "x", "1").jsonrpc("https://elsewhere.example.net/a2a");
        card.security_schemes.insert("bearer".into(), json!({"httpAuthSecurityScheme": {"scheme": "Bearer"}}));
        let agent = A2aAgent::from_card(card.clone(), reqwest::Client::new(), "https://partner.example.com").unwrap();
        assert!(matches!(agent.credential("bearer", "s3cret"), Err(Error::A2a(m)) if m.contains("allow_endpoint")));
        let agent = A2aAgent::from_card(card, reqwest::Client::new(), "https://partner.example.com").unwrap();
        assert!(agent.allow_endpoint("https://elsewhere.example.net/a2a").unwrap().credential("bearer", "s3cret").is_ok());
    }
}
