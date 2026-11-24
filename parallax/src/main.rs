//! `parallax`: the computer built for agents, from the command line.
//!
//!   parallax mcp                       MCP on stdio (Claude Code, Codex, Claude Desktop)
//!   parallax serve [--port 4610]       the host: MCP over HTTP, links, preview and live addresses
//!   parallax link <folder> <host> [--name n]   keep a folder linked to a host's world
//!   parallax waiting                   what waits at the wall
//!   parallax approve <id> | refuse <id>
//!   parallax worlds | status | setup | token
//!   parallax guest                     the agent inside a vault (Linux)

use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use parallax::cloud::billing::Billing;
use parallax::link::{Host, Manifest};
use parallax::Parallax;
use serde_json::{json, Value};

#[derive(Clone)]
struct App {
    px: Arc<Parallax>,
    host: Arc<Host>,
    billing: Arc<Billing>,
    token: String,
}

/// This machine's own token (made once, kept in the home, 0600): whoever holds it is the person.
fn own_token(px: &Parallax) -> Result<String, String> {
    let p = px.home.join("token");
    if let Ok(t) = std::fs::read_to_string(&p) {
        if t.trim().len() >= 32 {
            return Ok(t.trim().to_string());
        }
    }
    let t = format!("pxl_{}", parallax::util::random_hex(24));
    std::fs::write(&p, &t).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600));
    }
    Ok(t)
}

fn same(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Who is asking: `*` for this machine's person, an account id, or nobody.
fn who(app: &App, headers: &HeaderMap) -> Option<String> {
    let t = headers.get("authorization")?.to_str().ok()?.strip_prefix("Bearer ")?.trim();
    if same(t, &app.token) {
        return Some("*".into());
    }
    app.billing.account_for(t).map(|a| a.id)
}

fn denied() -> Response {
    (StatusCode::UNAUTHORIZED, Json(json!({"error": "Send the bearer token (`parallax token`, or your account's)."}))).into_response()
}

fn link_name(owner: &str, name: &str) -> String {
    if owner == "*" { name.to_string() } else { format!("{owner}-{name}") }
}

async fn mcp(State(app): State<App>, headers: HeaderMap, Json(msg): Json<Value>) -> Response {
    let Some(owner) = who(&app, &headers) else { return denied() };
    if owner != "*" && msg.pointer("/params/name").and_then(Value::as_str) == Some("parallax_open") {
        if let Some(acct) = headers.get("authorization").and_then(|h| h.to_str().ok()).and_then(|h| h.strip_prefix("Bearer ")).and_then(|t| app.billing.account_for(t)) {
            if let Err(e) = app.billing.may_run(&acct) {
                return (StatusCode::PAYMENT_REQUIRED, Json(json!({"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32000, "message": e}}))).into_response();
            }
        }
    }
    match parallax::mcp::handle(&app.px, &msg, &owner).await {
        Some(a) => Json(a).into_response(),
        None => StatusCode::ACCEPTED.into_response(),
    }
}

async fn link_push(State(app): State<App>, headers: HeaderMap, Path(name): Path<String>, Json(body): Json<Value>) -> Response {
    let Some(owner) = who(&app, &headers) else { return denied() };
    let m: Manifest = serde_json::from_value(body["manifest"].clone()).unwrap_or_default();
    answer(app.host.push(&app.px, &link_name(&owner, &name), &m).map(|v| {
        // The link's world belongs to whoever linked it.
        if let Some(w) = v["world"].as_str() {
            if let Ok(mut world) = app.px.worlds.get(w) {
                if world.owner == "link" {
                    world.owner = if owner == "*" { "local".into() } else { owner.clone() };
                    let _ = app.px.worlds.save(&world);
                }
            }
        }
        v
    }))
}

async fn link_put_block(State(app): State<App>, headers: HeaderMap, Path((name, sha)): Path<(String, String)>, body: Bytes) -> Response {
    let Some(owner) = who(&app, &headers) else { return denied() };
    answer(app.host.put_block(&app.px, &link_name(&owner, &name), &sha, &body))
}

async fn link_get_block(State(app): State<App>, headers: HeaderMap, Path((_name, sha)): Path<(String, String)>) -> Response {
    if who(&app, &headers).is_none() {
        return denied();
    }
    match app.host.get_block(&sha) {
        Ok(b) => b.into_response(),
        Err(e) => (StatusCode::NOT_FOUND, e).into_response(),
    }
}

async fn link_changes(State(app): State<App>, headers: HeaderMap, Path(name): Path<String>) -> Response {
    let Some(owner) = who(&app, &headers) else { return denied() };
    answer(app.host.changes(&app.px, &link_name(&owner, &name)))
}

async fn link_agreed(State(app): State<App>, headers: HeaderMap, Path(name): Path<String>, Json(body): Json<Value>) -> Response {
    let Some(owner) = who(&app, &headers) else { return denied() };
    let files: Manifest = serde_json::from_value(body["files"].clone()).unwrap_or_default();
    let removed: Vec<String> = serde_json::from_value(body["removed"].clone()).unwrap_or_default();
    answer(app.host.agreed(&link_name(&owner, &name), &files, &removed).map(|_| json!({"ok": true})))
}

async fn status(State(app): State<App>, headers: HeaderMap) -> Response {
    if who(&app, &headers).as_deref() != Some("*") {
        return denied();
    }
    Json(app.px.status()).into_response()
}

fn answer(r: Result<Value, String>) -> Response {
    match r {
        Ok(v) => Json(v).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, Json(json!({"error": e}))).into_response(),
    }
}

/// Anything else: a preview or live address, routed by its Host name.
async fn by_host(req: axum::extract::Request) -> Response {
    let host = req.headers().get("host").and_then(|h| h.to_str().ok()).unwrap_or("").to_string();
    let Some(route) = parallax::preview::route_of(&host) else { return (StatusCode::NOT_FOUND, "Parallax").into_response() };
    let method = req.method().to_string();
    let pq = req.uri().path_and_query().map(|p| p.as_str().to_string()).unwrap_or_else(|| "/".into());
    let headers: Vec<(String, String)> = req.headers().iter().map(|(k, v)| (k.to_string(), v.to_str().unwrap_or("").to_string())).collect();
    let body = axum::body::to_bytes(req.into_body(), 32 * 1024 * 1024).await.map(|b| b.to_vec()).unwrap_or_default();
    match parallax::preview::forward(&route, &method, &pq, &headers, body).await {
        Ok((status, hs, bytes)) => {
            let mut r = Response::builder().status(status);
            for (k, v) in hs {
                r = r.header(k, v);
            }
            r.body(axum::body::Body::from(bytes)).unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response())
        }
        Err(e) => (StatusCode::BAD_GATEWAY, e).into_response(),
    }
}

async fn serve(px: Arc<Parallax>, port: u16) -> Result<(), String> {
    let app = App { host: Arc::new(Host::new(&px.home)), billing: Arc::new(Billing::new(&px.home)), token: own_token(&px)?, px: px.clone() };
    // Every minute: idle worlds sleep; awake hosted worlds are metered.
    let (p2, b2) = (px.clone(), app.billing.clone());
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(60)).await;
            p2.sleep_idle().await;
            for w in p2.worlds.list().into_iter().filter(|w| w.state == "awake" && !matches!(w.owner.as_str(), "local" | "link" | "mcp" | "")) {
                let _ = b2.add(&w.owner, &w.id, 60);
            }
        }
    });
    let router = Router::new()
        .route("/mcp", post(mcp))
        .route("/link/{name}/push", post(link_push))
        .route("/link/{name}/block/{sha}", get(link_get_block).put(link_put_block))
        .route("/link/{name}/changes", get(link_changes))
        .route("/link/{name}/agreed", post(link_agreed))
        .route("/status", get(status))
        .fallback(by_host)
        .layer(axum::extract::DefaultBodyLimit::max(32 * 1024 * 1024))
        .with_state(app);
    let bind = std::env::var("PARALLAX_BIND").unwrap_or_else(|_| "127.0.0.1".into());
    let listener = tokio::net::TcpListener::bind((bind.as_str(), port)).await.map_err(|e| e.to_string())?;
    eprintln!("parallax: serving on http://{bind}:{port} (MCP at /mcp; previews at http://<world>.localhost:{port})");
    std::env::set_var("PARALLAX_PORT", port.to_string());
    axum::serve(listener, router).await.map_err(|e| e.to_string())
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("help");
    if cmd == "guest" {
        if let Err(e) = parallax::sizes::guest_agent() {
            eprintln!("parallax guest: {e}");
            std::process::exit(1);
        }
        return;
    }
    let px = match Parallax::open(parallax::default_home()) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("parallax: {e}");
            std::process::exit(1);
        }
    };
    let out: Result<Value, String> = match cmd {
        "mcp" => parallax::mcp::stdio(px).await.map(|_| Value::Null),
        "serve" => serve(px, flag(&args, "--port").and_then(|p| p.parse().ok()).unwrap_or(4610)).await.map(|_| Value::Null),
        "link" => match (args.get(1), args.get(2)) {
            (Some(folder), Some(host)) => {
                let token = std::env::var("PARALLAX_TOKEN").unwrap_or_default();
                let name = flag(&args, "--name").unwrap_or_else(|| std::path::Path::new(folder).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "folder".into()));
                let name: String = name.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' }).collect();
                parallax::link::run(std::path::Path::new(folder), host, &token, &name).await.map(|_| Value::Null)
            }
            _ => Err("parallax link <folder> <host> [--name n]   (PARALLAX_TOKEN holds the token)".into()),
        },
        "waiting" => Ok(json!(px.ledger.waiting())),
        "approve" | "refuse" => match args.get(1) {
            Some(id) => px.decide(id, cmd == "approve", "command line").await,
            None => Err(format!("parallax {cmd} <id>")),
        },
        "worlds" => Ok(json!(px.worlds.list())),
        "status" => Ok(px.status()),
        "setup" => Ok(parallax::mcp::setup(&std::env::current_exe().map(|p| p.to_string_lossy().to_string()).unwrap_or_else(|_| "parallax".into()))),
        "token" => own_token(&px).map(|t| json!({"token": t})),
        _ => {
            eprintln!("parallax mcp | serve [--port 4610] | link <folder> <host> [--name n] | waiting | approve <id> | refuse <id> | worlds | status | setup | token | guest");
            return;
        }
    };
    match out {
        Ok(Value::Null) => {}
        Ok(v) => println!("{}", serde_json::to_string_pretty(&v).unwrap_or_default()),
        Err(e) => {
            eprintln!("parallax: {e}");
            std::process::exit(1);
        }
    }
}
