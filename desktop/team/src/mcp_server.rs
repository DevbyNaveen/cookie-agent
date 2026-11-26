//! Your team over MCP: Claude Desktop, Cursor, Claude Code or any MCP client
//! can hand your agents work and read what they did.
//!
//! One endpoint, `POST /mcp` on the team's own server (Streamable HTTP,
//! answering with JSON), behind the team's token and, by default, only on this
//! computer (127.0.0.1). For clients that start a command instead, the bridge
//! ([`stdio_bridge`]: `Cookie --mcp`, or `cookie-team mcp`) reads JSON-RPC on
//! stdin and passes it to that endpoint of the running team: there is only
//! ever one team process, so no routine runs twice.
//!
//! A deliberately small control plane: see the agents, ask one and wait for
//! its answer (or come back for it), read a job and recent messages, see what
//! waits for the person, stop a job. Never approving, deciding a question,
//! settings, deleting, keys or files: those stay the person's, in Cookie.
//!
//! What a client writes reaches the agent the way another agent's words do
//! (`Trigger::Mcp`): the model behind the client may have read anything, so a
//! recipient or an amount in it is checked like one read on a page, and
//! anything that sends, changes or pays asks the person in Cookie.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};

use crate::store::{Job, JobStatus, Trigger};
use crate::{util, Team};

pub const PROTOCOL: &str = "2025-06-18";
/// How long `ask_agent` waits for an answer before handing back the job to come back for.
const WAIT_DEFAULT: u64 = 120;
const WAIT_MAX: u64 = 600;

fn tools() -> Value {
    json!([
        {"name": "list_agents", "description": "The person's Cookie agents: each one's name, address, job, and whether it is working or waiting on the person.",
         "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": true}},
        {"name": "ask_agent", "description": "Give one of the person's Cookie agents a task and wait for its answer. It works with its own tools; anything it would send, change or pay asks the person in Cookie first. If it isn't done in `wait_seconds`, you get a job id to read later with get_job.",
         "inputSchema": {"type": "object", "properties": {
             "agent": {"type": "string", "description": "the agent's name or @address"},
             "task": {"type": "string", "description": "the whole task: the agent sees only this"},
             "wait_seconds": {"type": "integer", "minimum": 0, "maximum": WAIT_MAX, "description": "how long to wait for the answer (default 120)"}
         }, "required": ["agent", "task"]}},
        {"name": "get_job", "description": "A job you started with ask_agent: whether it is still running, and its answer when done.",
         "inputSchema": {"type": "object", "properties": {"agent": {"type": "string"}, "job": {"type": "string"}}, "required": ["agent", "job"]},
         "annotations": {"readOnlyHint": true}},
        {"name": "recent_messages", "description": "The last messages in one agent's chat with the person (what was asked and answered).",
         "inputSchema": {"type": "object", "properties": {"agent": {"type": "string"}, "limit": {"type": "integer", "minimum": 1, "maximum": 30}}, "required": ["agent"]},
         "annotations": {"readOnlyHint": true}},
        {"name": "waiting_on_person", "description": "What the agents are waiting on the person for: approvals and questions. Read only: the person answers them in Cookie.",
         "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": true}},
        {"name": "stop_agent", "description": "Stop what one agent is doing now.",
         "inputSchema": {"type": "object", "properties": {"agent": {"type": "string"}}, "required": ["agent"]},
         "annotations": {"destructiveHint": false, "idempotentHint": true}}
    ])
}

fn text_result(text: impl Into<String>) -> Value {
    json!({"content": [{"type": "text", "text": text.into()}], "isError": false})
}

fn error_result(text: impl Into<String>) -> Value {
    json!({"content": [{"type": "text", "text": text.into()}], "isError": true})
}

/// One JSON-RPC message from a client. None for a notification (nothing to answer).
pub async fn handle(team: &Arc<Team>, msg: &Value, client: &str) -> Option<Value> {
    let id = msg.get("id").cloned();
    let method = msg["method"].as_str().unwrap_or("");
    let id = id?; // notifications (initialized, cancelled) need no answer
    let result = match method {
        "initialize" => Ok(json!({
            "protocolVersion": PROTOCOL,
            "capabilities": {"tools": {"listChanged": false}},
            "serverInfo": {"name": "cookie", "title": "Cookie", "version": env!("CARGO_PKG_VERSION")},
            "instructions": "The person's Cookie agents. Ask one with ask_agent; read what waits on the person with waiting_on_person. You can't approve anything: the person does, in Cookie."
        })),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": tools()})),
        "tools/call" => Ok(call(team, msg["params"]["name"].as_str().unwrap_or(""), &msg["params"]["arguments"], client).await),
        other => Err(json!({"code": -32601, "message": format!("Cookie doesn't offer `{other}`.")})),
    };
    Some(match result {
        Ok(r) => json!({"jsonrpc": "2.0", "id": id, "result": r}),
        Err(e) => json!({"jsonrpc": "2.0", "id": id, "error": e}),
    })
}

/// An agent named by name or `@address`.
async fn find_agent(team: &Team, who: &str) -> Option<crate::store::AgentRecord> {
    let w = who.trim().trim_start_matches('@').to_lowercase();
    let agents = team.agents().await;
    agents.iter().filter(|a| a.shadow_of.is_none() && !crate::bench::is_probe(&a.id)).find(|a| a.name.to_lowercase() == w || a.id == w || team.slug_of(a) == w).cloned()
}

async fn call(team: &Arc<Team>, name: &str, args: &Value, client: &str) -> Value {
    let s = |k: &str| args[k].as_str().unwrap_or("").trim().to_string();
    match name {
        "list_agents" => {
            let busy: Vec<String> = team.busy().into_iter().map(|(a, _)| a).collect();
            let approvals = team.pending_approvals();
            let questions = team.questions();
            let out: Vec<Value> = team
                .agents()
                .await
                .iter()
                .filter(|a| a.shadow_of.is_none() && !crate::bench::is_probe(&a.id))
                .map(|a| {
                    let waiting = approvals.iter().filter(|x| x.agent == a.id).count() + questions.iter().filter(|q| q.agent == a.id).count();
                    json!({"name": a.name, "address": format!("@{}", team.slug_of(a)), "job": a.job, "working": busy.contains(&a.id), "waiting_on_person": waiting})
                })
                .collect();
            text_result(serde_json::to_string_pretty(&out).unwrap_or_default())
        }
        "ask_agent" => {
            let (who, task) = (s("agent"), s("task"));
            if task.is_empty() {
                return error_result("Give the task.");
            }
            let Some(a) = find_agent(team, &who).await else { return error_result(format!("There is no agent called {who}. list_agents names them.")) };
            let wait = args["wait_seconds"].as_u64().unwrap_or(WAIT_DEFAULT).min(WAIT_MAX);
            let (tx, rx) = tokio::sync::oneshot::channel();
            let job = match team.spawn_job(&a.id, task, Vec::new(), Trigger::Mcp { client: client.to_string() }, Some(tx)).await {
                Ok(j) => j,
                Err(e) => return error_result(e),
            };
            match tokio::time::timeout(Duration::from_secs(wait), rx).await {
                Ok(Ok(done)) => job_result(&a.name, &done),
                _ => text_result(format!("{} is still working. Read it later with get_job (agent: {}, job: {job}).", a.name, a.name)),
            }
        }
        "get_job" => {
            let Some(a) = find_agent(team, &s("agent")).await else { return error_result("No such agent.") };
            let id = s("job");
            match team.jobs(&a.id).into_iter().find(|j| j.id == id) {
                Some(j) => job_result(&a.name, &j),
                None if team.busy().iter().any(|(ag, j)| ag == &a.id && j == &id) => text_result(format!("{} is still working on it.", a.name)),
                None => error_result("No such job."),
            }
        }
        "recent_messages" => {
            let Some(a) = find_agent(team, &s("agent")).await else { return error_result("No such agent.") };
            let limit = args["limit"].as_u64().unwrap_or(10).clamp(1, 30) as usize;
            let lines = team.history(&a.id).await.unwrap_or_default();
            let text: Vec<String> = lines
                .iter()
                .filter(|l| matches!(l.from, "you" | "agent" | "guest") && !l.text.trim().is_empty())
                .map(|l| format!("{}: {}", if l.from == "you" { "Person" } else { a.name.as_str() }, util::clip(&l.text, 1500)))
                .collect();
            let start = text.len().saturating_sub(limit);
            text_result(if text.is_empty() { "No messages yet.".to_string() } else { text[start..].join("\n\n") })
        }
        "waiting_on_person" => {
            let mut out: Vec<String> = team.pending_approvals().iter().map(|x| format!("{} needs a yes to {} ({}).", x.agent_name, x.tool, x.effect)).collect();
            out.extend(team.questions().iter().map(|q| format!("{} asks: {}", q.agent_name, q.question)));
            text_result(if out.is_empty() { "Nothing is waiting on the person.".to_string() } else { format!("{}\n\nThe person answers these in Cookie.", out.join("\n")) })
        }
        "stop_agent" => {
            let Some(a) = find_agent(team, &s("agent")).await else { return error_result("No such agent.") };
            text_result(if team.stop(&a.id) { format!("Stopped {}.", a.name) } else { format!("{} wasn't working.", a.name) })
        }
        other => error_result(format!("Cookie has no tool called `{other}`.")),
    }
}

fn job_result(name: &str, j: &Job) -> Value {
    match j.status {
        JobStatus::Done => text_result(if j.answer.trim().is_empty() { format!("{name} finished with nothing to say.") } else { j.answer.clone() }),
        JobStatus::Running => text_result(format!("{name} is still working on it.")),
        JobStatus::Stopped => error_result(format!("{name} was stopped before it finished.")),
        JobStatus::Failed => error_result(format!("{name} couldn't finish: {}", j.error.as_deref().unwrap_or("it hit a problem"))),
        JobStatus::NeedsYou => error_result(format!("{name} is waiting on the person: {}", j.error.as_deref().unwrap_or("they decide what happens next"))),
    }
}

/// Where the desktop app keeps its team on this computer.
pub fn desktop_dir() -> Option<std::path::PathBuf> {
    let home = std::path::PathBuf::from(std::env::var_os("HOME")?);
    let id = "com.enkeon.cookie.desktop";
    #[cfg(target_os = "macos")]
    let d = home.join("Library/Application Support").join(id);
    #[cfg(not(target_os = "macos"))]
    let d = std::env::var_os("XDG_DATA_HOME").map(std::path::PathBuf::from).unwrap_or_else(|| home.join(".local/share")).join(id);
    Some(d)
}

/// The stdio bridge: JSON-RPC lines on stdin to the running team's `/mcp`, answers on stdout.
/// Never starts a team of its own. `dir` is the team's folder (for its address and token).
pub async fn stdio_bridge(dir: &std::path::Path) -> Result<(), String> {
    let team = Team::open(dir)?;
    let server = team.settings().await.server;
    let token = team.keys.get("runner-token");
    let host = if server.bind == "0.0.0.0" { "127.0.0.1".to_string() } else { server.bind.clone() };
    let url = format!("http://{host}:{}/mcp", server.port);
    let reach = match (token, server.enabled) {
        (Some(token), true) => Some((url, token)),
        _ => None,
    };
    bridge(tokio::io::BufReader::new(tokio::io::stdin()), tokio::io::stdout(), reach).await
}

/// Lines in, answers out, through `reach` (the endpoint and its token), or a plain refusal when there is none.
pub async fn bridge<R, W>(input: R, mut out: W, reach: Option<(String, String)>) -> Result<(), String>
where
    R: tokio::io::AsyncBufRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let http = reqwest::Client::builder().timeout(Duration::from_secs(WAIT_MAX + 30)).build().map_err(|e| e.to_string())?;
    let mut client = String::new();
    let mut lines = input.lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        if msg["method"] == "initialize" {
            client = msg["params"]["clientInfo"]["name"].as_str().unwrap_or("").to_string();
        }
        let answer = match &reach {
            Some((url, token)) => match http.post(url).bearer_auth(token).header("x-cookie-client", &client).json(&msg).send().await {
                Ok(r) if r.status().as_u16() == 202 => None,
                Ok(r) if r.status().is_success() => r.json::<Value>().await.ok(),
                Ok(r) => msg.get("id").map(|id| rpc_error(id, &format!("Cookie answered {}.", r.status()))),
                Err(_) => msg.get("id").map(|id| rpc_error(id, "Cookie isn't running. Open the Cookie app, then try again.")),
            },
            None => msg.get("id").map(|id| rpc_error(id, "Cookie isn't open to AI tools on this computer: in Cookie, Settings → Sharing → AI tools, turn it on.")),
        };
        if let Some(a) = answer {
            let mut s = serde_json::to_string(&a).unwrap_or_default();
            s.push('\n');
            if out.write_all(s.as_bytes()).await.is_err() || out.flush().await.is_err() {
                break;
            }
        }
    }
    Ok(())
}

fn rpc_error(id: &Value, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": message}})
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn team() -> (Arc<Team>, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!("cookie-mcp-{}", util::random_hex(4)));
        let team = Team::open(&dir).unwrap();
        let rec: crate::store::AgentRecord = serde_json::from_value(json!({"id": "w", "name": "Writing Desk", "model": "m:x", "job": "Turns notes into posts", "created_at": 0})).unwrap();
        team.add_agent(rec).await.unwrap();
        (team, dir)
    }

    #[tokio::test]
    async fn the_handshake_and_the_tool_list() {
        let (team, dir) = team().await;
        let init = handle(&team, &json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"clientInfo": {"name": "claude-ai"}}}), "claude-ai").await.unwrap();
        assert_eq!(init["result"]["protocolVersion"], PROTOCOL);
        assert!(handle(&team, &json!({"jsonrpc": "2.0", "method": "notifications/initialized"}), "x").await.is_none(), "a notification gets no answer");
        let list = handle(&team, &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}), "x").await.unwrap();
        let names: Vec<&str> = list["result"]["tools"].as_array().unwrap().iter().filter_map(|t| t["name"].as_str()).collect();
        assert_eq!(names, ["list_agents", "ask_agent", "get_job", "recent_messages", "waiting_on_person", "stop_agent"]);
        for never in ["approve", "answer", "delete", "settings", "key"] {
            assert!(names.iter().all(|n| !n.contains(never)), "no tool to {never}: those stay the person's");
        }
        let unknown = handle(&team, &json!({"jsonrpc": "2.0", "id": 3, "method": "resources/list"}), "x").await.unwrap();
        assert_eq!(unknown["error"]["code"], -32601);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn tools_answer_from_the_team() {
        let (team, dir) = team().await;
        let call = |name: &str, args: Value| json!({"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": name, "arguments": args}});
        let agents = handle(&team, &call("list_agents", json!({})), "x").await.unwrap();
        let text = agents["result"]["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("Writing Desk") && text.contains("@writing-desk"));
        let nobody = handle(&team, &call("ask_agent", json!({"agent": "@nobody", "task": "hi"})), "x").await.unwrap();
        assert_eq!(nobody["result"]["isError"], true);
        let idle = handle(&team, &call("stop_agent", json!({"agent": "Writing Desk"})), "x").await.unwrap();
        assert!(idle["result"]["content"][0]["text"].as_str().unwrap().contains("wasn't working"));
        let waiting = handle(&team, &call("waiting_on_person", json!({})), "x").await.unwrap();
        assert!(waiting["result"]["content"][0]["text"].as_str().unwrap().contains("Nothing is waiting"));
        let _ = std::fs::remove_dir_all(&dir);
    }
    /// The whole path an MCP client takes: lines on its stdin, through the bridge, over HTTP to `/mcp`, and back.
    #[tokio::test]
    async fn a_client_talks_to_the_team_through_the_bridge() {
        let (team, dir) = team().await;
        let t = team.clone();
        let app = axum::Router::new().route(
            "/mcp",
            axum::routing::post(move |headers: axum::http::HeaderMap, axum::Json(msg): axum::Json<Value>| {
                let team = t.clone();
                async move {
                    use axum::response::IntoResponse;
                    if headers.get("authorization").and_then(|v| v.to_str().ok()) != Some("Bearer test-token") {
                        return axum::http::StatusCode::UNAUTHORIZED.into_response();
                    }
                    let client = headers.get("x-cookie-client").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
                    match handle(&team, &msg, &client).await {
                        Some(a) => axum::Json(a).into_response(),
                        None => axum::http::StatusCode::ACCEPTED.into_response(),
                    }
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let url = format!("http://{addr}/mcp");
        let input = concat!(
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-ai"}}}"#, "\n",
            r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, "\n",
            "not json\n",
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_agents","arguments":{}}}"#, "\n",
        );
        let mut out = Vec::new();
        bridge(tokio::io::BufReader::new(input.as_bytes()), &mut out, Some((url.clone(), "test-token".into()))).await.unwrap();
        let answers: Vec<Value> = String::from_utf8(out).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(answers.len(), 2, "the notification and the garbage line get no answer");
        assert_eq!(answers[0]["result"]["serverInfo"]["name"], "cookie");
        assert!(answers[1]["result"]["content"][0]["text"].as_str().unwrap().contains("@writing-desk"));
        // A wrong token, Cookie closed, or AI tools off: each is said, never a hang.
        let mut out = Vec::new();
        bridge(tokio::io::BufReader::new(&br#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#[..]), &mut out, Some((url, "wrong".into()))).await.unwrap();
        assert!(String::from_utf8(out).unwrap().contains("401"));
        let mut out = Vec::new();
        bridge(tokio::io::BufReader::new(&br#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#[..]), &mut out, Some(("http://127.0.0.1:9/mcp".into(), "t".into()))).await.unwrap();
        assert!(String::from_utf8(out).unwrap().contains("isn't running"));
        let mut out = Vec::new();
        bridge(tokio::io::BufReader::new(&br#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#[..]), &mut out, None).await.unwrap();
        assert!(String::from_utf8(out).unwrap().contains("AI tools"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
