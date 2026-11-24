//! A browser per agent, with its own logins.
//!
//! Each agent with the browser permission has a Chrome profile of its own
//! (`agents/<id>/browser`): its cookies, its sign-ins, its history, kept
//! between jobs and shared with no other agent and not with your own Chrome.
//! The agent drives it headless over the Chrome DevTools Protocol; nothing
//! appears on screen.
//!
//! - **Signing it in.** You open the agent's browser in a window
//!   ([`Team::browser_login`]) and sign in to whatever it should use, yourself.
//!   Close the window and the agent uses those sign-ins from then on. Cookie
//!   never sees or stores the password; the site's cookies live in the profile.
//! - **What it may do alone.** Open a page, read it, take a screenshot: these
//!   are reads (a page address the agent found in something it read still asks
//!   you, as for `read_url`). **Clicking and typing ask you every time**, with
//!   what it will click or type: on a signed-in site a click can buy, send or
//!   delete.
//! - **Reading a page** gives its title, address and text, and numbers its
//!   links, buttons and fields (`[3] button "Sign in"`); the agent clicks or
//!   types by number. Clicks are real mouse events at the element.
//! - **Closed when idle** after ten minutes; started again on the next use.
//! - **Walls.** The profile is outside the agent's cage folder, so a command
//!   the agent runs cannot read its browser's cookies.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Weak};
use std::time::{Duration, Instant};

use cookie_harness::tool::{tool, Effect, Tool};
use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::sync::Mutex;
use tokio_tungstenite::tungstenite::Message as WsMessage;

use crate::Team;

const IDLE: Duration = Duration::from_secs(600);
const CALL_TIMEOUT: Duration = Duration::from_secs(30);
const LOAD_TIMEOUT: Duration = Duration::from_secs(20);
const TEXT_CAP: usize = 20_000;

/// Chrome-family browsers, in order of preference.
const BROWSERS: &[&str] = &[
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
];

pub fn chrome() -> Option<&'static str> {
    BROWSERS.iter().copied().find(|p| Path::new(p).exists())
}

type Ws = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// One running headless browser for one agent.
struct Session {
    child: tokio::process::Child,
    ws: Ws,
    next: AtomicU64,
    used: Instant,
}

impl Session {
    async fn call(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        self.used = Instant::now();
        self.ws.send(WsMessage::Text(json!({"id": id, "method": method, "params": params}).to_string().into())).await.map_err(|e| format!("The browser closed: {e}"))?;
        let deadline = tokio::time::Instant::now() + CALL_TIMEOUT;
        loop {
            let msg = tokio::time::timeout_at(deadline, self.ws.next()).await.map_err(|_| format!("The browser didn't answer {method} in time."))?;
            let Some(msg) = msg else { return Err("The browser closed.".into()) };
            let msg = msg.map_err(|e| format!("The browser closed: {e}"))?;
            let WsMessage::Text(t) = msg else { continue };
            let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
            if v["id"].as_u64() != Some(id) {
                continue; // an event, or another call's answer
            }
            if let Some(e) = v.get("error") {
                return Err(e["message"].as_str().unwrap_or("The browser refused.").to_string());
            }
            return Ok(v["result"].clone());
        }
    }

    /// Run JavaScript in the page; its value (by value, so objects come back as JSON).
    async fn eval(&mut self, expr: &str) -> Result<Value, String> {
        let r = self.call("Runtime.evaluate", json!({"expression": expr, "returnByValue": true, "awaitPromise": true})).await?;
        if let Some(ex) = r.get("exceptionDetails") {
            return Err(ex.pointer("/exception/description").or(ex.get("text")).and_then(Value::as_str).unwrap_or("The page's script failed.").to_string());
        }
        Ok(r.pointer("/result/value").cloned().unwrap_or(Value::Null))
    }

    async fn settle(&mut self) {
        let deadline = Instant::now() + LOAD_TIMEOUT;
        while Instant::now() < deadline {
            if self.eval("document.readyState").await.ok().as_ref().and_then(Value::as_str) == Some("complete") {
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        tokio::time::sleep(Duration::from_millis(400)).await;
    }
}

/// Running sessions, and agents whose browser the person has open to sign in.
static SESSIONS: LazyLock<Mutex<HashMap<String, Arc<Mutex<Session>>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
static SIGNING_IN: LazyLock<std::sync::Mutex<HashMap<String, u32>>> = LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));

/// What reading a page returns: numbered elements to act on, then the text.
const READ_JS: &str = r#"(() => {
  const sel = 'a[href], button, input:not([type=hidden]), select, textarea, [role=button], [role=link], [contenteditable=true]';
  const els = [...document.querySelectorAll(sel)].filter(e => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; });
  document.querySelectorAll('[data-cookie-ref]').forEach(e => e.removeAttribute('data-cookie-ref'));
  const items = els.slice(0, 150).map((e, i) => {
    e.setAttribute('data-cookie-ref', String(i + 1));
    const tag = e.tagName.toLowerCase();
    const kind = tag === 'a' ? 'link' : tag === 'input' ? 'field:' + (e.type || 'text') : tag === 'select' ? 'choice' : tag === 'textarea' ? 'field:text' : 'button';
    const label = (e.getAttribute('aria-label') || e.innerText || e.value || e.placeholder || e.name || e.title || '').trim().replace(/\s+/g, ' ').slice(0, 80);
    const extra = tag === 'a' ? ' → ' + (e.href || '').slice(0, 120) : '';
    return '[' + (i + 1) + '] ' + kind + ' "' + label + '"' + extra;
  });
  const text = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n');
  return { title: document.title, url: location.href, items, text };
})()"#;

fn profile_dir(team: &Team, agent: &str) -> PathBuf {
    team.paths.agent(agent).join("browser")
}

/// Start a headless browser on the agent's profile and attach to its page.
async fn launch(profile: &Path) -> Result<Session, String> {
    let bin = chrome().ok_or("No Chrome, Chromium, Brave or Edge on this computer. Install one to give agents a browser.")?;
    std::fs::create_dir_all(profile).map_err(|e| e.to_string())?;
    let port_file = profile.join("DevToolsActivePort");
    let _ = std::fs::remove_file(&port_file);
    let child = tokio::process::Command::new(bin)
        .args(["--headless=new", "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1", "--no-first-run", "--no-default-browser-check", "--disable-sync", "--window-size=1280,900", "--lang=en-US"])
        .arg(format!("--user-data-dir={}", profile.display()))
        .arg("about:blank")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("Couldn't start the browser: {e}"))?;
    // Chrome writes the port it chose (and the browser's socket path) to the profile.
    let deadline = Instant::now() + Duration::from_secs(15);
    let port = loop {
        if let Some(p) = std::fs::read_to_string(&port_file).ok().and_then(|s| s.lines().next().and_then(|l| l.trim().parse::<u16>().ok())) {
            break p;
        }
        if Instant::now() > deadline {
            return Err("The browser didn't start in 15 seconds. If this agent's browser window is open, close it first.".into());
        }
        tokio::time::sleep(Duration::from_millis(150)).await;
    };
    let list: Value = reqwest::Client::new().get(format!("http://127.0.0.1:{port}/json/list")).timeout(Duration::from_secs(5)).send().await.map_err(|e| e.to_string())?.json().await.map_err(|e| e.to_string())?;
    let ws_url = list.as_array().into_iter().flatten().find(|t| t["type"] == "page").and_then(|t| t["webSocketDebuggerUrl"].as_str()).ok_or("The browser has no page.")?.to_string();
    if !ws_url.starts_with("ws://127.0.0.1:") {
        return Err("The browser's control socket isn't local.".into());
    }
    let (ws, _) = tokio_tungstenite::connect_async(&ws_url).await.map_err(|e| format!("Couldn't attach to the browser: {e}"))?;
    let mut s = Session { child, ws, next: AtomicU64::new(1), used: Instant::now() };
    s.call("Page.enable", json!({})).await?;
    s.call("Runtime.enable", json!({})).await?;
    Ok(s)
}

async fn session(team: &Team, agent: &str) -> Result<Arc<Mutex<Session>>, String> {
    if SIGNING_IN.lock().unwrap().contains_key(agent) {
        return Err("The person has this agent's browser open to sign in. Try again after they close it.".into());
    }
    let mut all = SESSIONS.lock().await;
    if let Some(s) = all.get(agent) {
        // Still alive?
        if s.lock().await.child.try_wait().ok().flatten().is_none() {
            return Ok(s.clone());
        }
        all.remove(agent);
    }
    let s = Arc::new(Mutex::new(launch(&profile_dir(team, agent)).await?));
    all.insert(agent.to_string(), s.clone());
    Ok(s)
}

async fn close(agent: &str) {
    if let Some(s) = SESSIONS.lock().await.remove(agent) {
        let mut s = s.lock().await;
        let _ = s.call("Browser.close", json!({})).await;
        let _ = s.child.kill().await;
    }
}

/// Close browsers left idle.
pub fn spawn_reaper() {
    tokio::spawn(async {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            let idle: Vec<String> = {
                let all = SESSIONS.lock().await;
                let mut out = Vec::new();
                for (a, s) in all.iter() {
                    if let Ok(s) = s.try_lock() {
                        if s.used.elapsed() > IDLE {
                            out.push(a.clone());
                        }
                    }
                }
                out
            };
            for a in idle {
                close(&a).await;
            }
        }
    });
}

fn page_text(v: &Value) -> String {
    let items: Vec<&str> = v["items"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    let text: String = v["text"].as_str().unwrap_or("").chars().take(TEXT_CAP).collect();
    format!("{}\n{}\n\nOn the page (act on them by number):\n{}\n\nText:\n{}", v["title"].as_str().unwrap_or(""), v["url"].as_str().unwrap_or(""), if items.is_empty() { "(nothing to click)".to_string() } else { items.join("\n") }, text)
}

fn https_or_http(url: &str) -> Result<String, String> {
    let u = url.trim();
    if u.starts_with("https://") || u.starts_with("http://") {
        Ok(u.to_string())
    } else if !u.contains("://") && u.contains('.') {
        Ok(format!("https://{u}"))
    } else {
        Err("Open a web address (https://…).".into())
    }
}

/// The element a number names, scrolled into view: its centre on the page.
async fn locate(s: &mut Session, r: u64) -> Result<(f64, f64, String), String> {
    let v = s
        .eval(&format!(
            "(() => {{ const e = document.querySelector('[data-cookie-ref=\"{r}\"]'); if (!e) return null; e.scrollIntoView({{block: 'center', inline: 'center'}}); const b = e.getBoundingClientRect(); return {{x: b.left + b.width / 2, y: b.top + b.height / 2, label: (e.getAttribute('aria-label') || e.innerText || e.value || e.placeholder || e.name || '').trim().slice(0, 80)}}; }})()"
        ))
        .await?;
    if v.is_null() {
        return Err(format!("There is no [{r}] on the page now. Read the page again to get fresh numbers."));
    }
    Ok((v["x"].as_f64().unwrap_or(0.0), v["y"].as_f64().unwrap_or(0.0), v["label"].as_str().unwrap_or("").to_string()))
}

async fn click_at(s: &mut Session, x: f64, y: f64) -> Result<(), String> {
    for kind in ["mouseMoved", "mousePressed", "mouseReleased"] {
        s.call("Input.dispatchMouseEvent", json!({"type": kind, "x": x, "y": y, "button": "left", "clickCount": 1})).await?;
    }
    Ok(())
}

/// The browser tools for one agent's job.
pub(crate) fn tools(team: &Arc<Team>, agent: &str) -> Vec<Arc<dyn Tool>> {
    if chrome().is_none() {
        return Vec::new();
    }
    let t = Arc::downgrade(team);
    let mk = |t: &Weak<Team>| (t.clone(), agent.to_string());
    let (t1, a1) = mk(&t);
    let (t2, a2) = mk(&t);
    let (t3, a3) = mk(&t);
    let (t4, a4) = mk(&t);
    let (t5, a5) = mk(&t);
    let (t6, a6) = mk(&t);
    vec![
        Arc::new(
            tool(
                "browser_open",
                "Open a web page in your own browser (signed in to whatever the person signed it in to) and read it: its text, and its links, buttons and fields by number.",
                json!({"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}),
                Effect::Read,
                move |args: Value| {
                    let (t, a) = (t1.clone(), a1.clone());
                    async move {
                        let team = t.upgrade().ok_or("Cookie is closing.")?;
                        let url = https_or_http(args["url"].as_str().unwrap_or(""))?;
                        let s = session(&team, &a).await?;
                        let mut s = s.lock().await;
                        s.call("Page.navigate", json!({"url": url})).await?;
                        s.settle().await;
                        Ok(page_text(&s.eval(READ_JS).await?))
                    }
                },
            )
            .guard("url"),
        ),
        Arc::new(tool(
            "browser_read",
            "Read the page your browser is on now (after a click or a wait), with fresh numbers for its links, buttons and fields.",
            json!({"type": "object", "properties": {}}),
            Effect::Read,
            move |_args: Value| {
                let (t, a) = (t2.clone(), a2.clone());
                async move {
                    let team = t.upgrade().ok_or("Cookie is closing.")?;
                    let s = session(&team, &a).await?;
                    let mut s = s.lock().await;
                    s.settle().await;
                    Ok(page_text(&s.eval(READ_JS).await?))
                }
            },
        )),
        Arc::new(
            tool(
                "browser_click",
                "Click a link or button on the page, by its number from browser_open or browser_read. The person approves each click.",
                json!({"type": "object", "properties": {"ref": {"type": "integer", "description": "the element's number"}, "what": {"type": "string", "description": "what this click does, in a few words, for the person"}}, "required": ["ref", "what"]}),
                Effect::Outbound,
                move |args: Value| {
                    let (t, a) = (t3.clone(), a3.clone());
                    async move {
                        let team = t.upgrade().ok_or("Cookie is closing.")?;
                        let r = args["ref"].as_u64().ok_or("Say which number to click.")?;
                        let s = session(&team, &a).await?;
                        let mut s = s.lock().await;
                        let (x, y, label) = locate(&mut s, r).await?;
                        click_at(&mut s, x, y).await?;
                        s.settle().await;
                        Ok(format!("Clicked [{r}] \"{label}\".\n\n{}", page_text(&s.eval(READ_JS).await?)))
                    }
                },
            )
            .with_preview(|args| format!("Click [{}] in its browser: {}", args["ref"], args["what"].as_str().unwrap_or("(no reason given)"))),
        ),
        Arc::new(
            tool(
                "browser_type",
                "Type into a field on the page, by its number; `submit` presses Enter after. The person approves each one.",
                json!({"type": "object", "properties": {"ref": {"type": "integer"}, "text": {"type": "string"}, "submit": {"type": "boolean"}}, "required": ["ref", "text"]}),
                Effect::Outbound,
                move |args: Value| {
                    let (t, a) = (t4.clone(), a4.clone());
                    async move {
                        let team = t.upgrade().ok_or("Cookie is closing.")?;
                        let r = args["ref"].as_u64().ok_or("Say which field.")?;
                        let text = args["text"].as_str().unwrap_or("");
                        let s = session(&team, &a).await?;
                        let mut s = s.lock().await;
                        let (x, y, label) = locate(&mut s, r).await?;
                        click_at(&mut s, x, y).await?;
                        // Clear what is there, then type as a person would.
                        s.eval(&format!("(() => {{ const e = document.querySelector('[data-cookie-ref=\"{r}\"]'); if (e && 'value' in e) {{ e.value = ''; e.dispatchEvent(new Event('input', {{bubbles: true}})); }} }})()")).await?;
                        s.call("Input.insertText", json!({"text": text})).await?;
                        if args["submit"].as_bool().unwrap_or(false) {
                            for kind in ["keyDown", "keyUp"] {
                                s.call("Input.dispatchKeyEvent", json!({"type": kind, "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "text": if kind == "keyDown" { "\r" } else { "" }})).await?;
                            }
                        }
                        s.settle().await;
                        Ok(format!("Typed into [{r}] \"{label}\".\n\n{}", page_text(&s.eval(READ_JS).await?)))
                    }
                },
            )
            .with_preview(|args| {
                let text = args["text"].as_str().unwrap_or("");
                format!("Type into [{}] in its browser{}:\n{}", args["ref"], if args["submit"].as_bool().unwrap_or(false) { ", then press Enter" } else { "" }, crate::util::clip(text, 500))
            }),
        ),
        Arc::new(tool(
            "browser_screenshot",
            "Save a screenshot of the page your browser is on into your folder (browser-shots/), and say where.",
            json!({"type": "object", "properties": {}}),
            Effect::Read,
            move |_args: Value| {
                let (t, a) = (t5.clone(), a5.clone());
                async move {
                    let team = t.upgrade().ok_or("Cookie is closing.")?;
                    let s = session(&team, &a).await?;
                    let mut s = s.lock().await;
                    let r = s.call("Page.captureScreenshot", json!({"format": "png"})).await?;
                    use base64::Engine as _;
                    let png = base64::engine::general_purpose::STANDARD.decode(r["data"].as_str().unwrap_or("")).map_err(|e| e.to_string())?;
                    let dir = team.paths.work(&a).join("browser-shots");
                    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
                    let name = format!("{}.png", crate::util::now());
                    std::fs::write(dir.join(&name), png).map_err(|e| e.to_string())?;
                    Ok(format!("Saved browser-shots/{name} in your folder."))
                }
            },
        )),
        Arc::new(tool(
            "browser_back",
            "Go back one page in your browser, and read it.",
            json!({"type": "object", "properties": {}}),
            Effect::Read,
            move |_args: Value| {
                let (t, a) = (t6.clone(), a6.clone());
                async move {
                    let team = t.upgrade().ok_or("Cookie is closing.")?;
                    let s = session(&team, &a).await?;
                    let mut s = s.lock().await;
                    s.eval("history.back()").await?;
                    s.settle().await;
                    Ok(page_text(&s.eval(READ_JS).await?))
                }
            },
        )),
    ]
}

impl Team {
    /// Open the agent's own browser in a window, for the person to sign in to sites.
    pub async fn browser_login(&self, agent: &str, url: Option<String>) -> Result<(), String> {
        let rec = self.agent(agent).await?;
        let bin = chrome().ok_or("No Chrome, Chromium, Brave or Edge on this computer.")?;
        if SIGNING_IN.lock().unwrap().contains_key(agent) {
            return Err(format!("{}'s browser is already open.", rec.name));
        }
        // One Chrome per profile: the headless one gives way.
        close(agent).await;
        let profile = profile_dir(self, agent);
        std::fs::create_dir_all(&profile).map_err(|e| e.to_string())?;
        let url = match url {
            Some(u) => https_or_http(&u)?,
            None => "about:blank".into(),
        };
        let mut child = tokio::process::Command::new(bin)
            .args(["--no-first-run", "--no-default-browser-check", "--disable-sync", "--new-window"])
            .arg(format!("--user-data-dir={}", profile.display()))
            .arg(&url)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|e| format!("Couldn't open the browser: {e}"))?;
        SIGNING_IN.lock().unwrap().insert(agent.to_string(), child.id().unwrap_or(0));
        let a = agent.to_string();
        tokio::spawn(async move {
            let _ = child.wait().await;
            SIGNING_IN.lock().unwrap().remove(&a);
        });
        Ok(())
    }

    /// Sign the agent's browser out of everything: its profile is deleted.
    pub async fn browser_forget(&self, agent: &str) -> Result<(), String> {
        self.agent(agent).await?;
        if SIGNING_IN.lock().unwrap().contains_key(agent) {
            return Err("Close its browser window first.".into());
        }
        close(agent).await;
        let p = profile_dir(self, agent);
        if p.exists() {
            std::fs::remove_dir_all(&p).map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    pub async fn browser_view(&self, agent: &str) -> Value {
        let p = profile_dir(self, agent);
        let running = SESSIONS.lock().await.contains_key(agent);
        // Sites it has cookies for: Chrome keeps them in an SQLite file we don't
        // open while it runs; the person sees whether a profile exists and how big.
        json!({
            "available": chrome().is_some(),
            "browser": chrome().map(|b| b.rsplit('/').next().unwrap_or(b).to_string()),
            "has_profile": p.exists(),
            "bytes": dir_size(&p),
            "running": running,
            "signing_in": SIGNING_IN.lock().unwrap().contains_key(agent),
        })
    }
}

fn dir_size(p: &Path) -> u64 {
    let Ok(m) = std::fs::symlink_metadata(p) else { return 0 };
    if m.is_dir() {
        std::fs::read_dir(p).into_iter().flatten().flatten().map(|e| dir_size(&e.path())).sum()
    } else {
        m.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_web_addresses_open() {
        assert_eq!(https_or_http("example.com").unwrap(), "https://example.com");
        assert!(https_or_http("file:///etc/passwd").is_err());
        assert!(https_or_http("javascript:alert(1)").is_err());
    }

    /// A real headless Chrome on this machine: open a local page, read it, click by number.
    #[tokio::test]
    async fn the_browser_reads_and_clicks() {
        if chrome().is_none() || std::env::var("COOKIE_BROWSER_TESTS").is_err() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let mut s = launch(&dir.path().join("profile")).await.unwrap();
        let page = "data:text/html,<title>T</title><button onclick=\"document.title='clicked'\">Go</button><p>hello there</p>";
        s.call("Page.navigate", json!({"url": page})).await.unwrap();
        s.settle().await;
        let v = s.eval(READ_JS).await.unwrap();
        let text = page_text(&v);
        assert!(text.contains("[1] button \"Go\"") && text.contains("hello there"), "{text}");
        let (x, y, _) = locate(&mut s, 1).await.unwrap();
        click_at(&mut s, x, y).await.unwrap();
        assert_eq!(s.eval("document.title").await.unwrap(), json!("clicked"));
        let _ = s.child.kill().await;
    }
}
