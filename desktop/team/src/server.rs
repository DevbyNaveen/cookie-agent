//! The team over HTTP: what makes a home runner, a cloud runner, Cookie on
//! your phone, and Cookie-to-Cookie possible.
//!
//! - `/` the same app as the desktop window, in a browser (open the link with
//!   its token once; the page keeps it).
//! - `/api/:cmd` every command (`api::call`), with `Authorization: Bearer <token>`.
//! - `/events?token=` the live stream of team events (server-sent events).
//! - `/a2a/:agent` and its card: other people's agents, with an invite token.
//! - `/challenge`: the public "try to trick my Cookie" game, when switched on.
//!
//! Binds to 127.0.0.1 unless you choose otherwise. Put it behind HTTPS (Caddy,
//! a tunnel) before sharing its address: tokens travel in its requests.

use std::collections::HashMap;
use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, OnceLock};

use axum::extract::{ConnectInfo, Path, Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::sse::{Event as SseEvent, KeepAlive, Sse};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{json, Value};
use tokio_stream::StreamExt;

use crate::events::TeamEvent;
use crate::store::{Job, JobStatus, Trigger};
use crate::{util, Team};

static RUNNING: OnceLock<Mutex<Option<(String, tokio::task::JoinHandle<()>)>>> = OnceLock::new();

/// The runner's access token (created on first use, kept in the Keychain).
pub fn token(team: &Team, rotate: bool) -> Result<String, String> {
    if !rotate {
        if let Some(t) = team.keys.get("runner-token") {
            return Ok(t);
        }
    }
    let t = util::random_hex(24);
    team.keys.set("runner-token", &t)?;
    Ok(t)
}

pub async fn status(team: &Team) -> Value {
    let s = team.settings().await.server;
    let running = RUNNING.get().and_then(|m| m.lock().unwrap().as_ref().map(|(addr, _)| addr.clone()));
    json!({"enabled": s.enabled, "bind": s.bind, "port": s.port, "public_url": s.public_url, "listening": running})
}

/// Start (or restart, or stop) the server to match settings. A change that
/// doesn't touch the address (like the public URL) leaves it running.
pub fn spawn_if_enabled(team: Arc<Team>) {
    tokio::spawn(async move {
        let s = team.settings().await.server;
        let slot = RUNNING.get_or_init(|| Mutex::new(None));
        let want = s.enabled.then(|| format!("{}:{}", s.bind, s.port));
        let running = slot.lock().unwrap().as_ref().map(|(addr, _)| addr.clone());
        if want == running {
            return;
        }
        // Let the request that changed it get its answer before the old server goes.
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        if let Some((_, h)) = slot.lock().unwrap().take() {
            h.abort();
        }
        let Some(addr) = want else {
            team.emit(TeamEvent::Channel { name: "server".into(), status: "off".into() });
            return;
        };
        // The old socket closes a moment after its task is aborted: try for two seconds.
        let mut last_err = String::new();
        for _ in 0..10 {
            match tokio::net::TcpListener::bind(&addr).await {
                Ok(listener) => {
                    let app = router(team.clone());
                    let h = tokio::spawn(async move {
                        let _ = axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await;
                    });
                    *slot.lock().unwrap() = Some((addr.clone(), h));
                    team.emit(TeamEvent::Channel { name: "server".into(), status: format!("listening on {addr}") });
                    return;
                }
                Err(e) => {
                    last_err = e.to_string();
                    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                }
            }
        }
        team.emit(TeamEvent::Channel { name: "server".into(), status: format!("couldn't listen on {addr}: {last_err}") });
    });
}

#[derive(Clone)]
struct AppState {
    team: Arc<Team>,
    /// A2A task id (a job id) → its agent and record once finished.
    tasks: Arc<Mutex<HashMap<String, (String, Option<Job>)>>>,
    /// Challenge attempts per client address this hour.
    tries: Arc<Mutex<HashMap<String, (u64, u32)>>>,
}

pub fn router(team: Arc<Team>) -> Router {
    let state = AppState { team, tasks: Default::default(), tries: Default::default() };
    Router::new()
        .route("/", get(|| async { Html(UI_INDEX) }))
        .route("/app.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_APP) }))
        .route("/face.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_FACE) }))
        .route("/md.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_MD) }))
        .route("/blocks.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_BLOCKS) }))
        .route("/style.css", get(|| async { ([(header::CONTENT_TYPE, "text/css")], UI_CSS) }))
        .route("/api.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_API) }))
        .route("/profile.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_PROFILE) }))
        .route("/today.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_TODAY) }))
        .route("/network.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_NETWORK) }))
        .route("/learn.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_LEARN) }))
        .route("/access.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_ACCESS) }))
        .route("/memory.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_MEMORY) }))
        .route("/dropdown.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_DROPDOWN) }))
        .route("/voice.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_VOICE) }))
        .route("/channels.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_CHANNELS) }))
        .route("/settings.js", get(|| async { ([(header::CONTENT_TYPE, "text/javascript")], UI_SETTINGS) }))
        .route("/api/{cmd}", post(api))
        .layer(axum::extract::DefaultBodyLimit::max(40 * 1024 * 1024)) // voice recordings
        .route("/events", get(events))
        .route("/a2a/{agent}/.well-known/agent-card.json", get(card))
        .route("/a2a/{agent}", post(a2a))
        .route("/challenge", get(challenge_page).post(challenge_try))
        .route("/challenge/board", get(challenge_board))
        .route("/healthz", get(|| async { "ok" }))
        // A job link from a message Cookie sent: the app opens it and asks for the PIN.
        .route("/j/{token}", get(|path: Path<String>| async move { axum::response::Redirect::to(&format!("/#link={}", path.0)) }))
        .route("/link/open", post(link_open))
        // Channels that call Cookie (dark until connected; need a public address).
        .route("/hooks/whatsapp", get(whatsapp_verify).post(whatsapp_hook))
        .route("/hooks/teams", post(teams_hook))
        .route("/hooks/mail", post(mail_hook))
        // A routine started by a call to its own address (secret as a bearer token).
        .route("/hooks/routine/{id}", post(routine_hook))
        // The team over MCP, for Claude Desktop, Cursor and other AI tools (`mcp_server`).
        .route("/mcp", post(mcp))
        .with_state(state)
}

const UI_INDEX: &str = include_str!("../../ui/index.html");
const UI_APP: &str = include_str!("../../ui/app.js");
const UI_FACE: &str = include_str!("../../ui/face.js");
const UI_MD: &str = include_str!("../../ui/md.js");
const UI_BLOCKS: &str = include_str!("../../ui/blocks.js");
const UI_CSS: &str = include_str!("../../ui/style.css");
const UI_API: &str = include_str!("../../ui/api.js");
const UI_PROFILE: &str = include_str!("../../ui/profile.js");
const UI_TODAY: &str = include_str!("../../ui/today.js");
const UI_NETWORK: &str = include_str!("../../ui/network.js");
const UI_LEARN: &str = include_str!("../../ui/learn.js");
const UI_ACCESS: &str = include_str!("../../ui/access.js");
const UI_MEMORY: &str = include_str!("../../ui/memory.js");
const UI_DROPDOWN: &str = include_str!("../../ui/dropdown.js");
const UI_VOICE: &str = include_str!("../../ui/voice.js");
const UI_CHANNELS: &str = include_str!("../../ui/channels.js");
const UI_SETTINGS: &str = include_str!("../../ui/settings.js");

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers.get(header::AUTHORIZATION)?.to_str().ok()?.strip_prefix("Bearer ").map(str::trim)
}

/// Constant-time comparison, so a wrong token takes as long as a right one.
fn same(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn authorised(team: &Team, presented: Option<&str>) -> bool {
    match (team.keys.get("runner-token"), presented) {
        (Some(t), Some(p)) if same(&t, p) => true,
        // A session opened with a job link and the PIN (`links`).
        (_, Some(p)) if !p.is_empty() => team.session_ok(p),
        _ => false,
    }
}

/* ---------- job links ---------- */

async fn link_open(State(st): State<AppState>, Json(args): Json<Value>) -> Response {
    let (token, pin) = (args["link"].as_str().unwrap_or_default(), args["pin"].as_str().unwrap_or_default());
    match st.team.open_link(token, pin) {
        Ok((session, link)) => Json(json!({"ok": {"session": session, "agent": link.agent, "job": link.job}})).into_response(),
        Err(e) => (StatusCode::UNAUTHORIZED, Json(json!({"error": e}))).into_response(),
    }
}

/* ---------- WhatsApp, Teams, mail ---------- */

async fn whatsapp_verify(State(st): State<AppState>, Query(q): Query<HashMap<String, String>>) -> Response {
    let want = st.team.keys.get("channel:whatsapp:verify").unwrap_or_default();
    let ok = !want.is_empty()
        && st.team.channel_states().get("whatsapp").is_some_and(|s| s.enabled)
        && q.get("hub.mode").map(String::as_str) == Some("subscribe")
        && q.get("hub.verify_token").is_some_and(|t| crate::webhooks::same(t.as_bytes(), want.as_bytes()));
    match (ok, q.get("hub.challenge")) {
        (true, Some(c)) => c.clone().into_response(),
        _ => StatusCode::FORBIDDEN.into_response(),
    }
}

async fn whatsapp_hook(State(st): State<AppState>, headers: HeaderMap, body: axum::body::Bytes) -> Response {
    let team = st.team.clone();
    if !team.channel_states().get("whatsapp").is_some_and(|s| s.enabled) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let secret = team.keys.get("channel:whatsapp:app_secret").unwrap_or_default();
    let sig = headers.get("x-hub-signature-256").and_then(|v| v.to_str().ok()).unwrap_or("");
    if secret.is_empty() || !crate::webhooks::whatsapp_verified(&secret, sig, &body) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Ok(v) = serde_json::from_slice::<Value>(&body) else { return StatusCode::OK.into_response() };
    for (phone, text) in crate::webhooks::whatsapp_messages(&v) {
        let team = team.clone();
        tokio::spawn(async move {
            if let Some(reply) = team.channel_inbound("whatsapp", &phone, &text).await {
                team.channel_say("whatsapp", &phone, &reply).await;
            }
        });
    }
    StatusCode::OK.into_response()
}

async fn teams_hook(State(st): State<AppState>, headers: HeaderMap, body: axum::body::Bytes) -> Response {
    let team = st.team.clone();
    if !team.channel_states().get("teams").is_some_and(|s| s.enabled) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let Ok(activity) = serde_json::from_slice::<Value>(&body) else { return StatusCode::BAD_REQUEST.into_response() };
    let service = activity["serviceUrl"].as_str().unwrap_or_default();
    if let Err(e) = team.teams_verified(bearer(&headers).unwrap_or_default(), service).await {
        tracing::info!("teams: refused an activity: {e}");
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Some((conversation, service, text)) = crate::webhooks::teams_message(&activity) else { return StatusCode::OK.into_response() };
    team.teams_route(&conversation, &service);
    tokio::spawn(async move {
        if let Some(reply) = team.channel_inbound("teams", &conversation, &text).await {
            team.channel_say("teams", &conversation, &reply).await;
        }
    });
    StatusCode::OK.into_response()
}

/// Raw mail from the forwarder, with the secret Cookie showed once and,
/// when it has them, the envelope recipients (`X-Cookie-Rcpt`, comma separated).
async fn mail_hook(State(st): State<AppState>, headers: HeaderMap, body: axum::body::Bytes) -> Response {
    let want = st.team.keys.get("channel:mail:inbound").unwrap_or_default();
    let given = headers.get("x-cookie-mail-secret").and_then(|v| v.to_str().ok()).unwrap_or("");
    if want.is_empty() || !crate::webhooks::same(given.as_bytes(), want.as_bytes()) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let rcpt: Vec<String> = headers.get("x-cookie-rcpt").and_then(|v| v.to_str().ok()).unwrap_or("").split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
    match st.team.mail_inbound(&body, &rcpt).await {
        Ok(what) => Json(json!({"ok": what})).into_response(),
        Err(e) => (StatusCode::UNPROCESSABLE_ENTITY, Json(json!({"error": e}))).into_response(),
    }
}

async fn mcp(State(st): State<AppState>, headers: HeaderMap, Json(msg): Json<Value>) -> Response {
    if !authorised(&st.team, bearer(&headers)) {
        return (StatusCode::UNAUTHORIZED, Json(json!({"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32001, "message": "Cookie's token is missing or wrong."}}))).into_response();
    }
    let client = headers.get("x-cookie-client").and_then(|v| v.to_str().ok()).unwrap_or("").chars().take(60).collect::<String>();
    match crate::mcp_server::handle(&st.team, &msg, &client).await {
        Some(answer) => Json(answer).into_response(),
        None => StatusCode::ACCEPTED.into_response(),
    }
}

async fn routine_hook(State(st): State<AppState>, Path(id): Path<String>, headers: HeaderMap, body: axum::body::Bytes) -> Response {
    let secret = bearer(&headers).unwrap_or("");
    match st.team.webhook_call(&id, secret, &body).await {
        Ok(what) => (StatusCode::ACCEPTED, Json(json!({"ok": what}))).into_response(),
        Err((code, why)) => (StatusCode::from_u16(code).unwrap_or(StatusCode::BAD_REQUEST), Json(json!({"error": why}))).into_response(),
    }
}

async fn api(State(st): State<AppState>, Path(cmd): Path<String>, headers: HeaderMap, Json(args): Json<Value>) -> Response {
    if !authorised(&st.team, bearer(&headers)) {
        return (StatusCode::UNAUTHORIZED, Json(json!({"error": "Sign in with the runner's link."}))).into_response();
    }
    // Opening Finder on the runner's machine makes no sense from afar.
    if cmd == "reveal" {
        return (StatusCode::BAD_REQUEST, Json(json!({"error": "Folders open only on the runner's own computer."}))).into_response();
    }
    match crate::api::call(&st.team, &cmd, args).await {
        Ok(v) => Json(json!({"ok": v})).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, Json(json!({"error": e}))).into_response(),
    }
}

async fn events(State(st): State<AppState>, Query(q): Query<HashMap<String, String>>) -> Response {
    if !authorised(&st.team, q.get("token").map(String::as_str)) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let stream = tokio_stream::wrappers::BroadcastStream::new(st.team.subscribe())
        .filter_map(|ev| ev.ok())
        .map(|ev| Ok::<_, Infallible>(SseEvent::default().json_data(ev).unwrap_or_default()));
    Sse::new(stream).keep_alive(KeepAlive::default()).into_response()
}

/* ---------- A2A: other people's agents ---------- */

async fn base_url(team: &Team) -> String {
    let s = team.settings().await.server;
    s.public_url.unwrap_or_else(|| format!("http://{}:{}", s.bind, s.port))
}

async fn card(State(st): State<AppState>, Path(agent): Path<String>) -> Response {
    let invited = st.team.settings().await.invites.iter().any(|i| i.agent == agent && !i.revoked);
    match st.team.agent(&agent).await {
        // Only agents someone was invited to have a public card.
        Ok(a) if invited => Json(crate::peers::card_for(&base_url(&st.team).await, &a)).into_response(),
        _ => StatusCode::NOT_FOUND.into_response(),
    }
}

fn rpc_error(id: &Value, code: i64, message: &str) -> Response {
    Json(json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})).into_response()
}

fn task_json(id: &str, job: Option<&Job>) -> Value {
    let (state, text) = match job {
        None => ("TASK_STATE_WORKING", String::new()),
        Some(j) => match j.status {
            JobStatus::Done => ("TASK_STATE_COMPLETED", j.answer.clone()),
            JobStatus::Stopped => ("TASK_STATE_CANCELED", "Stopped.".into()),
            _ => ("TASK_STATE_FAILED", j.error.clone().unwrap_or_default()),
        },
    };
    let mut t = json!({"id": id, "contextId": id, "status": {"state": state}});
    if state == "TASK_STATE_COMPLETED" {
        t["artifacts"] = json!([{"artifactId": format!("{id}-answer"), "parts": [{"text": text}]}]);
    } else if !text.is_empty() {
        t["status"]["message"] = json!({"messageId": format!("{id}-status"), "role": "ROLE_AGENT", "parts": [{"text": text}]});
    }
    t
}

async fn a2a(State(st): State<AppState>, Path(agent): Path<String>, headers: HeaderMap, Json(req): Json<Value>) -> Response {
    let id = req["id"].clone();
    let Some(token) = bearer(&headers) else { return (StatusCode::UNAUTHORIZED, "invite token needed").into_response() };
    let Some(invite) = st.team.invite_for(&agent, token).await else { return (StatusCode::FORBIDDEN, "not invited").into_response() };
    match req["method"].as_str().unwrap_or_default() {
        "SendMessage" => {
            let text: String = req["params"]["message"]["parts"].as_array().map(Vec::as_slice).unwrap_or_default().iter().filter_map(|p| p["text"].as_str()).collect::<Vec<_>>().join("\n");
            if text.trim().is_empty() {
                return rpc_error(&id, -32602, "The message has no text.");
            }
            let job_id = util::new_id("task");
            st.tasks.lock().unwrap().insert(job_id.clone(), (agent.clone(), None));
            let (team, tasks, jid) = (st.team.clone(), st.tasks.clone(), job_id.clone());
            tokio::spawn(async move {
                let done = team.run_and_wait(&agent, util::clip(&text, 20_000), Vec::new(), Trigger::Peer { invite: invite.id.clone(), label: invite.label.clone() }).await;
                let job = done.unwrap_or_else(|e| Job {
                    id: jid.clone(), agent: agent.clone(), trigger: Trigger::Peer { invite: invite.id, label: invite.label }, input: String::new(),
                    started_at: util::now(), finished_at: Some(util::now()), status: JobStatus::Failed, answer: String::new(), error: Some(e),
                    tools: vec![], approvals: vec![], promises: vec![], tokens: 0, microdollars: 0, grade: None, version: 0, ..Default::default()
                });
                tasks.lock().unwrap().insert(jid, (agent, Some(job)));
            });
            Json(json!({"jsonrpc": "2.0", "id": id, "result": {"task": task_json(&job_id, None)}})).into_response()
        }
        "GetTask" => {
            let tid = req["params"]["id"].as_str().unwrap_or_default().to_string();
            let found = st.tasks.lock().unwrap().get(&tid).cloned();
            match found {
                Some((a, job)) if a == agent => Json(json!({"jsonrpc": "2.0", "id": id, "result": task_json(&tid, job.as_ref())})).into_response(),
                _ => rpc_error(&id, -32001, "No such task."),
            }
        }
        "CancelTask" => {
            let tid = req["params"]["id"].as_str().unwrap_or_default().to_string();
            let found = st.tasks.lock().unwrap().get(&tid).cloned();
            match found {
                Some((a, _)) if a == agent => {
                    st.team.stop(&agent);
                    Json(json!({"jsonrpc": "2.0", "id": id, "result": task_json(&tid, None)})).into_response()
                }
                _ => rpc_error(&id, -32001, "No such task."),
            }
        }
        other => rpc_error(&id, -32601, &format!("`{other}` isn't supported here.")),
    }
}

/* ---------- the public challenge ---------- */

async fn challenge_page(State(st): State<AppState>) -> Response {
    if st.team.settings().await.challenge_model.is_none() {
        return StatusCode::NOT_FOUND.into_response();
    }
    Html(crate::challenge::PAGE).into_response()
}

async fn challenge_try(State(st): State<AppState>, ConnectInfo(addr): ConnectInfo<SocketAddr>, Json(body): Json<Value>) -> Response {
    let Some(model) = st.team.settings().await.challenge_model else { return StatusCode::NOT_FOUND.into_response() };
    let who = addr.ip().to_string();
    {
        let mut tries = st.tries.lock().unwrap();
        let hour = util::now() / 3600;
        let e = tries.entry(who.clone()).or_insert((hour, 0));
        if e.0 != hour {
            *e = (hour, 0);
        }
        if e.1 >= 10 {
            return (StatusCode::TOO_MANY_REQUESTS, Json(json!({"error": "Ten tries an hour. Come back soon."}))).into_response();
        }
        e.1 += 1;
    }
    let message = body["message"].as_str().unwrap_or_default().to_string();
    match crate::challenge::attempt(&st.team, &model, &message).await {
        Ok(r) => Json(r).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, Json(json!({"error": e}))).into_response(),
    }
}

async fn challenge_board(State(st): State<AppState>) -> Response {
    Json(crate::challenge::board(&st.team)).into_response()
}
