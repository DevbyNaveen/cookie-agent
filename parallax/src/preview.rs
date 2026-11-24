//! A preview address per world, and hosting.
//!
//! **Preview.** A world that runs a web app (`app.start` with its command and
//! port) gets an address: `http://<world>.localhost:<port>` on a Mac (browsers
//! send every `*.localhost` name to this machine), `https://<world>.<domain>`
//! on a host (`PARALLAX_DOMAIN`, behind a TLS front door). `parallax serve`
//! routes each request by its Host name to that world's app. The app runs in
//! the world's cage: it reads and writes only the world, and may only listen
//! and answer on this machine.
//!
//! **Hosting.** Going live is an outside action, so it stops at the wall.
//! On a yes, the world's files are copied into an immutable release, the
//! release is started, and only once it answers does the live address switch
//! to it (the old release stops after). Rolling back switches to the release
//! before, the same way. The release folders stay, so any one can be forked
//! back into a world. Hosting is a duty: uptime, security, abuse — and a live
//! database can't be branched; an app's data should live outside its files.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::engine::{s, ActionSpec, Ctx, Effect, Engine};
use crate::util;

/// Apps running now: route name (a world id, or `live:<app>`) → (port, process).
static RUNNING: LazyLock<Mutex<HashMap<String, (u16, tokio::process::Child)>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

pub fn domain() -> Option<String> {
    std::env::var("PARALLAX_DOMAIN").ok().map(|d| d.trim().trim_matches('.').to_string()).filter(|d| !d.is_empty())
}

/// The address a world (or a live app) answers on.
pub fn address(route: &str, serve_port: u16) -> String {
    match domain() {
        Some(d) => format!("https://{}.{d}", route.replace(':', "-")),
        None => format!("http://{}.localhost:{serve_port}", route.replace(':', "-")),
    }
}

/// Which route a Host header asks for: `<route>.localhost[:port]` or `<route>.<domain>`.
pub fn route_of(host: &str) -> Option<String> {
    let host = host.split(':').next()?.to_ascii_lowercase();
    let label = match domain() {
        Some(d) => host.strip_suffix(&format!(".{}", d.to_ascii_lowercase()))?.to_string(),
        None => host.strip_suffix(".localhost")?.to_string(),
    };
    if label.is_empty() || label.contains('.') {
        return None;
    }
    Some(match label.strip_prefix("live-") {
        Some(app) => format!("live:{app}"),
        None => label,
    })
}

/// The port a route's app answers on.
pub fn port_of(route: &str) -> Option<u16> {
    RUNNING.lock().unwrap().get(route).map(|(p, _)| *p)
}

/// Start `command` caged in `dir`, listening on `port`; wait until it answers.
async fn start(route: &str, dir: &Path, command: &str, port: u16) -> Result<(), String> {
    stop(route).await;
    let (prog, argv) = crate::sizes::world_command(dir, &format!("export PORT={port}; {command}"), true)?;
    let log = std::fs::File::create(dir.join(".parallax/app.log")).map_err(|e| e.to_string())?;
    let child = tokio::process::Command::new(prog).args(argv).current_dir(dir).stdin(std::process::Stdio::null()).stdout(log.try_clone().map_err(|e| e.to_string())?).stderr(log).kill_on_drop(true).spawn().map_err(|e| e.to_string())?;
    RUNNING.lock().unwrap().insert(route.to_string(), (port, child));
    for _ in 0..60 {
        if tokio::net::TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
            return Ok(());
        }
        let exited = RUNNING.lock().unwrap().get_mut(route).map(|(_, c)| c.try_wait().ok().flatten().is_some()).unwrap_or(true);
        if exited {
            let tail = std::fs::read_to_string(dir.join(".parallax/app.log")).unwrap_or_default();
            RUNNING.lock().unwrap().remove(route);
            return Err(format!("The app stopped before it answered:\n{}", util::clip(&tail, 1_500)));
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    stop(route).await;
    Err(format!("Nothing answered on port {port} within 30 seconds."))
}

async fn stop(route: &str) {
    let c = RUNNING.lock().unwrap().remove(route);
    if let Some((_, mut c)) = c {
        let _ = c.kill().await;
    }
}

fn free_port() -> Result<u16, String> {
    let l = std::net::TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    Ok(l.local_addr().map_err(|e| e.to_string())?.port())
}

/// A world's web app and its preview address.
pub struct App;

#[async_trait]
impl Engine for App {
    fn name(&self) -> &'static str {
        "app"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let st = json!({"type": "string"});
        vec![
            ActionSpec::new("app", "start", "Start this world's web app (`command`, which must listen on $PORT) and give it a preview address.", json!({"type": "object", "properties": {"command": st}, "required": ["command"]}), Effect::Local),
            ActionSpec::new("app", "stop", "Stop this world's app.", json!({"type": "object", "properties": {}}), Effect::Local),
            ActionSpec::new("app", "address", "This world's preview address, if its app is running.", json!({"type": "object", "properties": {}}), Effect::Read),
        ]
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        let serve_port: u16 = std::env::var("PARALLAX_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(4610);
        match action {
            "start" => {
                let port = free_port()?;
                start(&ctx.world, &ctx.files, s(args, "command")?, port).await?;
                Ok(json!({"address": address(&ctx.world, serve_port), "port": port}))
            }
            "stop" => {
                stop(&ctx.world).await;
                Ok(json!({"stopped": true}))
            }
            "address" => Ok(json!({"address": port_of(&ctx.world).map(|_| address(&ctx.world, serve_port))})),
            other => Err(format!("The app engine has no action {other}.")),
        }
    }

    async fn sleep(&self, world: &str) {
        stop(world).await;
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Release {
    pub n: u64,
    pub at: u64,
    pub world: String,
    pub command: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Hosted {
    pub app: String,
    pub releases: Vec<Release>,
    pub live: Option<u64>,
}

fn hosting_dir(home: &Path, app: &str) -> Result<PathBuf, String> {
    if app.is_empty() || app.len() > 40 || !app.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-') {
        return Err("An app's name is lowercase letters, digits and -.".into());
    }
    Ok(home.join("hosting").join(app))
}

async fn go_live(home: &Path, app: &str, n: u64, command: &str) -> Result<(), String> {
    let dir = hosting_dir(home, app)?.join("releases").join(n.to_string());
    let route = format!("live:{app}");
    let port = free_port()?;
    // Started beside the running release; the route moves only once it answers.
    let trial = format!("trial:{app}");
    start(&trial, &dir, command, port).await?;
    let moved = RUNNING.lock().unwrap().remove(&trial);
    let old = moved.map(|m| RUNNING.lock().unwrap().insert(route, m)).flatten();
    if let Some((_, mut c)) = old {
        let _ = c.kill().await;
    }
    Ok(())
}

/// Going live and rolling back: outside actions, at the wall.
pub struct Hosting;

#[async_trait]
impl Engine for Hosting {
    fn name(&self) -> &'static str {
        "hosting"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let st = json!({"type": "string"});
        vec![
            ActionSpec::new("hosting", "go_live", "Make this world the live version of an app: an immutable release, started, then switched to. Waits for a person's yes.", json!({"type": "object", "properties": {"app": st, "command": st}, "required": ["app", "command"]}), Effect::Outside),
            ActionSpec::new("hosting", "rollback", "Switch an app back to its release before. Waits for a person's yes.", json!({"type": "object", "properties": {"app": st}, "required": ["app"]}), Effect::Outside),
            ActionSpec::new("hosting", "releases", "An app's releases and which is live.", json!({"type": "object", "properties": {"app": st}, "required": ["app"]}), Effect::Read),
        ]
    }

    fn preview(&self, action: &str, args: &Value) -> String {
        let app = args["app"].as_str().unwrap_or("?");
        match action {
            "go_live" => format!("Put this world live as “{app}” at {}.", address(&format!("live:{app}"), 4610)),
            "rollback" => format!("Switch “{app}” back to its release before."),
            _ => format!("hosting {action} {app}"),
        }
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        let app = s(args, "app")?;
        let dir = hosting_dir(&ctx.home, app)?;
        let mut h: Hosted = util::read_json(&dir.join("app.json"));
        h.app = app.into();
        match action {
            "releases" => Ok(serde_json::to_value(&h).unwrap_or_default()),
            "go_live" => {
                let n = h.releases.last().map(|r| r.n + 1).unwrap_or(1);
                let rel = dir.join("releases").join(n.to_string());
                crate::world::clone_tree(&ctx.files, &rel)?;
                let command = s(args, "command")?.to_string();
                go_live(&ctx.home, app, n, &command).await?;
                h.releases.push(Release { n, at: util::now(), world: ctx.world.clone(), command });
                h.live = Some(n);
                util::write_json(&dir.join("app.json"), &h)?;
                Ok(json!({"live": n, "address": address(&format!("live:{app}"), 4610)}))
            }
            "rollback" => {
                let live = h.live.ok_or("Nothing is live.")?;
                let prev = h.releases.iter().rev().find(|r| r.n < live).cloned().ok_or("There is no release before this one.")?;
                go_live(&ctx.home, app, prev.n, &prev.command).await?;
                h.live = Some(prev.n);
                util::write_json(&dir.join("app.json"), &h)?;
                Ok(json!({"live": prev.n}))
            }
            other => Err(format!("The hosting engine has no action {other}.")),
        }
    }
}

/// Forward one request to a route's app (the preview and live addresses).
pub async fn forward(route: &str, method: &str, path_and_query: &str, headers: &[(String, String)], body: Vec<u8>) -> Result<(u16, Vec<(String, String)>, Vec<u8>), String> {
    let port = port_of(route).ok_or("No app is running there.")?;
    let client = reqwest::Client::builder().redirect(reqwest::redirect::Policy::none()).timeout(Duration::from_secs(60)).build().map_err(|e| e.to_string())?;
    let m = reqwest::Method::from_bytes(method.as_bytes()).map_err(|e| e.to_string())?;
    let mut req = client.request(m, format!("http://127.0.0.1:{port}{path_and_query}")).body(body);
    for (k, v) in headers {
        if !matches!(k.to_ascii_lowercase().as_str(), "host" | "connection" | "content-length" | "transfer-encoding" | "authorization") {
            req = req.header(k, v);
        }
    }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let hs: Vec<(String, String)> = resp.headers().iter().filter(|(k, _)| !matches!(k.as_str(), "connection" | "transfer-encoding" | "content-length")).map(|(k, v)| (k.to_string(), v.to_str().unwrap_or("").to_string())).collect();
    let bytes = resp.bytes().await.map_err(|e| e.to_string())?.to_vec();
    Ok((status, hs, bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_host_name_says_which_world() {
        if domain().is_some() {
            return;
        }
        assert_eq!(route_of("w-18f2ab.localhost:4610").as_deref(), Some("w-18f2ab"));
        assert_eq!(route_of("live-shop.localhost").as_deref(), Some("live:shop"));
        assert_eq!(route_of("example.com"), None);
        assert_eq!(route_of("a.b.localhost"), None);
        assert_eq!(address("live:shop", 4610), "http://live-shop.localhost:4610");
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn a_world_app_gets_an_address_and_answers() {
        let d = tempfile::tempdir().unwrap();
        let w = std::fs::canonicalize(d.path()).unwrap();
        std::fs::create_dir_all(w.join(".parallax")).unwrap();
        std::fs::write(w.join("index.html"), "hello from the world").unwrap();
        let ctx = Ctx { world: "w-test".into(), files: w.clone(), state: w.join(".parallax"), home: w.join(".parallax/home") };
        let r = App.call(&ctx, "start", &json!({"command": "exec python3 -m http.server $PORT --bind 127.0.0.1"})).await.unwrap();
        let port = r["port"].as_u64().unwrap() as u16;
        let (status, _, body) = forward("w-test", "GET", "/index.html", &[], vec![]).await.unwrap();
        assert_eq!((status, String::from_utf8_lossy(&body).to_string()), (200, "hello from the world".to_string()));
        assert_eq!(port_of("w-test"), Some(port));
        App.call(&ctx, "stop", &json!({})).await.unwrap();
        assert_eq!(port_of("w-test"), None);
    }
}
