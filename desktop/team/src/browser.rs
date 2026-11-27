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
//! - **Every request is checked** ([`Gate`]), by Cookie and not by the model:
//!   nothing but web addresses, nothing on this computer or its private network
//!   unless that is where the person sent it, and no page may carry the browser
//!   onto a site the person signed it in to. Those sign-ins are used only when
//!   the agent was sent to that site, or the person approved the click.
//! - **A browser of its own when the computer has none**: Cookie downloads one
//!   pinned, checked build the first time it is needed (`browser_fetch`).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, OnceLock, Weak};
use std::time::{Duration, Instant};

use cookie_harness::tool::{tool, Effect, Tool};
use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::sync::Mutex;
use tokio_tungstenite::tungstenite::Message as WsMessage;

use crate::{Team, TeamEvent};

const IDLE: Duration = Duration::from_secs(600);
const CALL_TIMEOUT: Duration = Duration::from_secs(30);
const LOAD_TIMEOUT: Duration = Duration::from_secs(20);
const TEXT_CAP: usize = 20_000;
/// How much of a page's text the agent is handed at once; the rest is in a file it can search.
const TEXT_SHOWN: usize = 4_000;
/// The most a saved page holds, and how many saved pages an agent keeps.
const PAGE_FILE_CAP: usize = 400_000;
const PAGES_KEPT: usize = 20;

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

/// Where Cookie keeps the browser it downloads (`<data>/browser-runtime`).
static RUNTIME: OnceLock<PathBuf> = OnceLock::new();

/// Tell the browser where Cookie's data folder is, once, at start.
pub fn init(root: &Path) {
    let _ = RUNTIME.set(root.join("browser-runtime"));
}

fn installed() -> Option<PathBuf> {
    BROWSERS.iter().map(Path::new).find(|p| p.exists()).map(Path::to_path_buf)
}

/// The browser agents use now: one the person installed, else the one Cookie downloaded.
pub fn chrome() -> Option<PathBuf> {
    installed().or_else(|| RUNTIME.get().and_then(|r| crate::browser_fetch::fetched(r)))
}

/// With no browser yet, Cookie can download one for this computer.
fn can_fetch() -> bool {
    RUNTIME.get().is_some() && crate::browser_fetch::platform().is_some()
}

/// Agents can have a browser here, now or after one download.
pub fn available() -> bool {
    chrome().is_some() || can_fetch()
}

/// The browser to run, downloading Cookie's own when the computer has none.
async fn ensure(team: &Team, agent: &str) -> Result<PathBuf, String> {
    if let Some(p) = chrome() {
        return Ok(p);
    }
    let root = RUNTIME.get().filter(|_| can_fetch()).ok_or("No Chrome, Chromium, Brave or Edge on this computer, and Cookie has none to download for it. Install one to give agents a browser.")?;
    if crate::browser_fetch::progress().is_none() {
        team.emit(TeamEvent::Notice {
            agent: agent.to_string(),
            title: "Getting a browser".into(),
            body: "This computer has no Chrome, so Cookie is downloading one for its agents (about 200 MB, once).".into(),
            job: None,
        });
    }
    crate::browser_fetch::fetch(root).await
}

type Ws = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;
type Sink = futures::stream::SplitSink<Ws, WsMessage>;
type Pending = Arc<std::sync::Mutex<HashMap<u64, tokio::sync::oneshot::Sender<Value>>>>;

/// Hosts where anyone can publish a page: each name under them is its own site.
const SHARED_HOSTS: &[&str] = &[
    "github.io", "pages.dev", "vercel.app", "netlify.app", "web.app", "firebaseapp.com", "herokuapp.com", "cloudfront.net", "amazonaws.com",
    "azurewebsites.net", "blogspot.com", "workers.dev", "appspot.com", "googleusercontent.com", "onrender.com", "fly.dev", "glitch.me", "repl.co",
];

/// The site a host belongs to (`mail.google.com` → `google.com`): what a sign-in is good for.
/// A short rule, not the full public-suffix list: when unsure it keeps more of the name,
/// which makes two hosts different sites, the careful side.
fn site_of(host: &str) -> String {
    let h = host.trim_matches(|c| c == '[' || c == ']' || c == '.').to_ascii_lowercase();
    if h.parse::<std::net::IpAddr>().is_ok() || !h.contains('.') {
        return h;
    }
    let labels: Vec<&str> = h.split('.').collect();
    let n = labels.len();
    let keep = if let Some(s) = SHARED_HOSTS.iter().find(|s| h.ends_with(&format!(".{s}"))) {
        s.split('.').count() + 1
    } else if labels[n - 1].len() == 2 && ["co", "com", "org", "net", "gov", "ac", "edu", "or", "ne", "go"].contains(&labels[n - 2]) {
        3
    } else {
        2
    };
    labels[n.saturating_sub(keep)..].join(".")
}

/// This computer, or the private network it sits on: where a web page has no business.
fn is_local(host: &str) -> bool {
    let h = host.trim_matches(|c| c == '[' || c == ']' || c == '.').to_ascii_lowercase();
    if h == "localhost" || h.ends_with(".localhost") || h.ends_with(".local") || h.ends_with(".internal") {
        return true;
    }
    match h.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V4(a)) => a.is_loopback() || a.is_private() || a.is_link_local() || a.is_unspecified() || a.is_broadcast() || (a.octets()[0] == 100 && (a.octets()[1] & 0xc0) == 64),
        Ok(std::net::IpAddr::V6(a)) => a.is_loopback() || a.is_unspecified() || (a.segments()[0] & 0xfe00) == 0xfc00 || (a.segments()[0] & 0xffc0) == 0xfe80,
        Err(_) => false,
    }
}

fn host_of(url: &str) -> Option<String> {
    reqwest::Url::parse(url).ok().and_then(|u| u.host_str().map(str::to_string))
}

/// What Cookie checks on every request the agent's browser makes. The model
/// has no say in it: the rules read only the request and what the person did.
#[derive(Default)]
struct Gate {
    /// The page's own frame; a navigation of it changes where the browser is.
    main_frame: String,
    /// The site the agent was sent to, or the page a person-approved click landed on.
    site: Option<String>,
    /// A click, a typed Enter or "back" the person allowed may take the page anywhere, once.
    free: bool,
    /// Sites the person signed this browser in to.
    signed_in: HashSet<String>,
    /// What was stopped since the page was last read, for the agent and the receipt.
    blocked: Vec<String>,
}

impl Gate {
    fn stop(&mut self, why: String) -> bool {
        if self.blocked.len() < 6 && !self.blocked.contains(&why) {
            self.blocked.push(why);
        }
        false
    }

    /// May this request leave? `kind` is Chrome's resource type, `frame` the frame asking.
    fn allows(&mut self, url: &str, kind: &str, frame: &str) -> bool {
        let Ok(u) = reqwest::Url::parse(url) else { return self.stop("A request with no readable address.".into()) };
        match u.scheme() {
            "http" | "https" | "ws" | "wss" => {}
            // Made inside the page, from what it already has: nothing leaves.
            "data" | "blob" | "about" => return true,
            other => return self.stop(format!("A request to a `{other}:` address, which is not the web.")),
        }
        let Some(host) = u.host_str() else { return self.stop("A request with no host.".into()) };
        let site = site_of(host);
        if is_local(host) && self.site.as_deref() != Some(site.as_str()) {
            return self.stop(format!("The page tried to reach {host}, on this computer or its private network."));
        }
        if kind != "Document" || frame != self.main_frame {
            return true;
        }
        // The page itself is going somewhere.
        match self.site.clone() {
            None => self.site = Some(site),
            Some(_) if self.free => self.site = Some(site),
            Some(cur) if cur == site => {}
            // From a site the person signed in to, to another: their single sign-on.
            Some(cur) if self.signed_in.contains(&site) && !self.signed_in.contains(&cur) => {
                return self.stop(format!("{cur} tried to send the browser to {site}, where the person signed it in. A page can't use that sign-in; only the person sending you there, or approving a click, can."));
            }
            Some(_) => self.site = Some(site),
        }
        true
    }
}

/// One running headless browser for one agent.
struct Session {
    child: tokio::process::Child,
    sink: Arc<Mutex<Sink>>,
    pending: Pending,
    next: Arc<AtomicU64>,
    used: Instant,
    gate: Arc<std::sync::Mutex<Gate>>,
    reader: tokio::task::JoinHandle<()>,
}

impl Drop for Session {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

impl Session {
    async fn call(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        self.used = Instant::now();
        let (tx, rx) = tokio::sync::oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        if let Err(e) = self.sink.lock().await.send(WsMessage::Text(json!({"id": id, "method": method, "params": params}).to_string().into())).await {
            self.pending.lock().unwrap().remove(&id);
            return Err(format!("The browser closed: {e}"));
        }
        let v = match tokio::time::timeout(CALL_TIMEOUT, rx).await {
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                return Err(format!("The browser didn't answer {method} in time."));
            }
            Ok(Err(_)) => return Err("The browser closed.".into()),
            Ok(Ok(v)) => v,
        };
        if let Some(e) = v.get("error") {
            return Err(e["message"].as_str().unwrap_or("The browser refused.").to_string());
        }
        Ok(v["result"].clone())
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

/// Answers go to whoever asked; every request the browser wants to make is put to the gate.
fn spawn_reader(mut stream: futures::stream::SplitStream<Ws>, sink: Arc<Mutex<Sink>>, pending: Pending, next: Arc<AtomicU64>, gate: Arc<std::sync::Mutex<Gate>>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(Ok(msg)) = stream.next().await {
            let WsMessage::Text(t) = msg else { continue };
            let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
            if let Some(id) = v["id"].as_u64() {
                if let Some(tx) = pending.lock().unwrap().remove(&id) {
                    let _ = tx.send(v);
                }
                continue;
            }
            if v["method"] != "Fetch.requestPaused" {
                continue;
            }
            let p = &v["params"];
            let ok = gate.lock().unwrap().allows(p.pointer("/request/url").and_then(Value::as_str).unwrap_or(""), p["resourceType"].as_str().unwrap_or(""), p["frameId"].as_str().unwrap_or(""));
            let id = next.fetch_add(1, Ordering::Relaxed);
            let verdict = if ok {
                json!({"id": id, "method": "Fetch.continueRequest", "params": {"requestId": p["requestId"]}})
            } else {
                json!({"id": id, "method": "Fetch.failRequest", "params": {"requestId": p["requestId"], "errorReason": "BlockedByClient"}})
            };
            if sink.lock().await.send(WsMessage::Text(verdict.to_string().into())).await.is_err() {
                break;
            }
        }
        // The browser is gone: whoever is waiting hears so.
        pending.lock().unwrap().clear();
    })
}

/// Running sessions, and agents whose browser the person has open to sign in.
static SESSIONS: LazyLock<Mutex<HashMap<String, Arc<Mutex<Session>>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
static SIGNING_IN: LazyLock<std::sync::Mutex<HashMap<String, u32>>> = LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));
/// What each agent's browser last showed it, by number: what an approval names is what Cookie saw, not what the agent says.
static LAST_READ: LazyLock<std::sync::Mutex<HashMap<String, Vec<String>>>> = LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));

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

/// The sites the person signed this agent's browser in to, kept beside its profile.
fn sites_file(team: &Team, agent: &str) -> PathBuf {
    team.paths.agent(agent).join("browser-sites.json")
}

fn load_sites(file: &Path) -> HashSet<String> {
    std::fs::read_to_string(file).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
}

/// The port and the browser's own socket path Chrome wrote into the profile once it was up.
async fn devtools(profile: &Path, wait: Duration) -> Option<(u16, String)> {
    let file = profile.join("DevToolsActivePort");
    let deadline = Instant::now() + wait;
    loop {
        if let Ok(s) = std::fs::read_to_string(&file) {
            let mut lines = s.lines();
            if let Some(port) = lines.next().and_then(|l| l.trim().parse::<u16>().ok()) {
                return Some((port, lines.next().unwrap_or("").trim().to_string()));
            }
        }
        if Instant::now() > deadline {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(150)).await;
    }
}

/// Start a headless browser on the agent's profile and attach to its page.
async fn launch(bin: &Path, profile: &Path, signed_in: HashSet<String>) -> Result<Session, String> {
    std::fs::create_dir_all(profile).map_err(|e| e.to_string())?;
    let _ = std::fs::remove_file(profile.join("DevToolsActivePort"));
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
    let (port, _) = devtools(profile, Duration::from_secs(15)).await.ok_or("The browser didn't start in 15 seconds. If this agent's browser window is open, close it first.")?;
    let list: Value = reqwest::Client::new().get(format!("http://127.0.0.1:{port}/json/list")).timeout(Duration::from_secs(5)).send().await.map_err(|e| e.to_string())?.json().await.map_err(|e| e.to_string())?;
    let ws_url = list.as_array().into_iter().flatten().find(|t| t["type"] == "page").and_then(|t| t["webSocketDebuggerUrl"].as_str()).ok_or("The browser has no page.")?.to_string();
    if !ws_url.starts_with("ws://127.0.0.1:") {
        return Err("The browser's control socket isn't local.".into());
    }
    let (ws, _) = tokio_tungstenite::connect_async(&ws_url).await.map_err(|e| format!("Couldn't attach to the browser: {e}"))?;
    let (sink, stream) = ws.split();
    let sink = Arc::new(Mutex::new(sink));
    let pending: Pending = Arc::default();
    let next = Arc::new(AtomicU64::new(1));
    let gate = Arc::new(std::sync::Mutex::new(Gate { signed_in, ..Gate::default() }));
    let reader = spawn_reader(stream, sink.clone(), pending.clone(), next.clone(), gate.clone());
    let mut s = Session { child, sink, pending, next, used: Instant::now(), gate, reader };
    s.call("Page.enable", json!({})).await?;
    s.call("Runtime.enable", json!({})).await?;
    let frame = s.call("Page.getFrameTree", json!({})).await?.pointer("/frameTree/frame/id").and_then(Value::as_str).unwrap_or("").to_string();
    s.gate.lock().unwrap().main_frame = frame;
    // From here on, nothing leaves this browser without passing the gate.
    s.call("Fetch.enable", json!({"patterns": [{"urlPattern": "*"}]})).await?;
    Ok(s)
}

async fn session(team: &Team, agent: &str) -> Result<Arc<Mutex<Session>>, String> {
    if SIGNING_IN.lock().unwrap().contains_key(agent) {
        return Err("The person has this agent's browser open to sign in. Try again after they close it.".into());
    }
    let bin = ensure(team, agent).await?;
    let mut all = SESSIONS.lock().await;
    if let Some(s) = all.get(agent) {
        // Still alive?
        if s.lock().await.child.try_wait().ok().flatten().is_none() {
            return Ok(s.clone());
        }
        all.remove(agent);
    }
    let s = Arc::new(Mutex::new(launch(&bin, &profile_dir(team, agent), load_sites(&sites_file(team, agent))).await?));
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

/// Read the page the browser is on. From here the browser stays on this site
/// until the agent is sent elsewhere or the person approves a click.
async fn read_page(agent: &str, s: &mut Session, work: Option<&Path>) -> Result<String, String> {
    let mut v = s.eval(READ_JS).await?;
    LAST_READ.lock().unwrap().insert(agent.to_string(), v["items"].as_array().into_iter().flatten().filter_map(|i| i.as_str().map(str::to_string)).collect());
    let stopped = {
        let mut g = s.gate.lock().unwrap();
        g.free = false;
        if let Some(h) = v["url"].as_str().and_then(host_of) {
            g.site = Some(site_of(&h));
        }
        std::mem::take(&mut g.blocked)
    };
    // A long page goes to a file in the agent's folder: it gets the start and searches the rest,
    // which costs a fraction of reading every page whole.
    let full = v["text"].as_str().unwrap_or("").to_string();
    let mut saved = String::new();
    if let Some(work) = work.filter(|_| full.chars().count() > TEXT_SHOWN) {
        if let Some(name) = save_page(work, v["title"].as_str().unwrap_or(""), v["url"].as_str().unwrap_or(""), &full) {
            let shown: String = full.chars().take(TEXT_SHOWN).collect();
            saved = format!("\n\n[This is the first {TEXT_SHOWN} of {} characters. The whole page is in browser-pages/{name} in your folder: search that file for what you need instead of reading it all.]", full.chars().count());
            v["text"] = Value::String(shown);
        }
    }
    let text = format!("{}{saved}", page_text(&v));
    Ok(if stopped.is_empty() { text } else { format!("Cookie stopped these (they did not happen):\n- {}\n\n{text}", stopped.join("\n- ")) })
}

/// Keep a page's whole text in the agent's folder (`browser-pages/`), the newest few only. Its file name.
fn save_page(work: &Path, title: &str, url: &str, text: &str) -> Option<String> {
    let dir = work.join("browser-pages");
    std::fs::create_dir_all(&dir).ok()?;
    let name = format!("page-{}-{}.txt", crate::util::now(), crate::util::random_hex(2));
    let body: String = text.chars().take(PAGE_FILE_CAP).collect();
    std::fs::write(dir.join(&name), format!("{title}\n{url}\n\n{body}")).ok()?;
    let mut old: Vec<PathBuf> = std::fs::read_dir(&dir).into_iter().flatten().flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "txt")).collect();
    old.sort();
    for p in old.iter().rev().skip(PAGES_KEPT) {
        let _ = std::fs::remove_file(p);
    }
    Some(name)
}

/// What number `r` was on the page the agent last read, in the page's own words.
fn seen(agent: &str, r: &Value) -> String {
    r.as_u64()
        .filter(|n| *n > 0)
        .and_then(|n| LAST_READ.lock().unwrap().get(agent).and_then(|v| v.get(n as usize - 1).cloned()))
        .unwrap_or_else(|| format!("[{r}], which was not on the page it last read"))
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
    if !available() {
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
    let (p3, p4) = (agent.to_string(), agent.to_string());
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
                        // Sent here by the person's words or a search: this site, and no other, is where it may go.
                        {
                            let mut g = s.gate.lock().unwrap();
                            g.site = host_of(&url).map(|h| site_of(&h));
                            g.free = false;
                        }
                        s.call("Page.navigate", json!({"url": url})).await?;
                        s.settle().await;
                        // A new run starts here (`browser_runs`).
                        crate::browser_runs::record(&a, crate::browser_runs::RunStep::Open { url: url.clone() }, true);
                        read_page(&a, &mut s, Some(&team.paths.work(&a))).await
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
                    read_page(&a, &mut s, Some(&team.paths.work(&a))).await
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
                        // The person said yes to this click: it may take the page where it leads.
                        s.gate.lock().unwrap().free = true;
                        click_at(&mut s, x, y).await?;
                        s.settle().await;
                        crate::browser_runs::record(&a, crate::browser_runs::RunStep::Click { label: label.clone() }, false);
                        Ok(format!("Clicked [{r}] \"{label}\".\n\n{}", read_page(&a, &mut s, Some(&team.paths.work(&a))).await?))
                    }
                },
            )
            .with_preview(move |args| format!("Click in its browser: {}\nIts reason: {}", seen(&p3, &args["ref"]), args["what"].as_str().unwrap_or("(none given)"))),
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
                            s.gate.lock().unwrap().free = true;
                            for kind in ["keyDown", "keyUp"] {
                                s.call("Input.dispatchKeyEvent", json!({"type": kind, "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "text": if kind == "keyDown" { "\r" } else { "" }})).await?;
                            }
                        }
                        s.settle().await;
                        crate::browser_runs::record(&a, crate::browser_runs::RunStep::Type { label: label.clone(), text: text.to_string(), submit: args["submit"].as_bool().unwrap_or(false), fill: None }, false);
                        Ok(format!("Typed into [{r}] \"{label}\".\n\n{}", read_page(&a, &mut s, Some(&team.paths.work(&a))).await?))
                    }
                },
            )
            .with_preview(move |args| {
                let text = args["text"].as_str().unwrap_or("");
                format!("Type into {} in its browser{}:\n{}", seen(&p4, &args["ref"]), if args["submit"].as_bool().unwrap_or(false) { ", then press Enter" } else { "" }, crate::util::clip(text, 500))
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
                    // Back to a page it was already on.
                    s.gate.lock().unwrap().free = true;
                    s.eval("history.back()").await?;
                    s.settle().await;
                    crate::browser_runs::record(&a, crate::browser_runs::RunStep::Back, false);
                    read_page(&a, &mut s, Some(&team.paths.work(&a))).await
                }
            },
        )),
    ]
}

impl Team {
    /// Open the agent's own browser in a window, for the person to sign in to sites.
    pub async fn browser_login(&self, agent: &str, url: Option<String>) -> Result<(), String> {
        let rec = self.agent(agent).await?;
        let bin = ensure(self, agent).await?;
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
        let _ = std::fs::remove_file(profile.join("DevToolsActivePort"));
        let mut child = tokio::process::Command::new(bin)
            .args(["--no-first-run", "--no-default-browser-check", "--disable-sync", "--new-window", "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1"])
            .arg(format!("--user-data-dir={}", profile.display()))
            .arg(&url)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|e| format!("Couldn't open the browser: {e}"))?;
        SIGNING_IN.lock().unwrap().insert(agent.to_string(), child.id().unwrap_or(0));
        let a = agent.to_string();
        let file = sites_file(self, agent);
        tokio::spawn(async move {
            // The sites the person goes to in this window are the ones they signed it in to.
            let visited = tokio::select! {
                v = watch_sites(&profile) => v,
                _ = child.wait() => HashSet::new(),
            };
            let _ = child.wait().await;
            if !visited.is_empty() {
                let mut all = load_sites(&file);
                all.extend(visited);
                let mut list: Vec<&String> = all.iter().collect();
                list.sort();
                let _ = std::fs::write(&file, serde_json::to_string_pretty(&list).unwrap_or_default());
            }
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
        let _ = std::fs::remove_file(sites_file(self, agent));
        LAST_READ.lock().unwrap().remove(agent);
        Ok(())
    }

    /// Download Cookie's own browser now, not at an agent's first use.
    pub async fn browser_install(&self) -> Result<(), String> {
        ensure(self, "cookie").await.map(|_| ())
    }

    pub async fn browser_view(&self, agent: &str) -> Value {
        let p = profile_dir(self, agent);
        let running = SESSIONS.lock().await.contains_key(agent);
        // Sites it has cookies for: Chrome keeps them in an SQLite file we don't
        // open while it runs; the person sees whether a profile exists and how big.
        let bin = chrome();
        let mut sites: Vec<String> = load_sites(&sites_file(self, agent)).into_iter().collect();
        sites.sort();
        json!({
            "available": available(),
            "browser": bin.as_ref().and_then(|b| b.file_name()).map(|n| n.to_string_lossy().to_string()),
            // No browser on this computer yet: Cookie downloads its own on first use.
            "to_download": bin.is_none() && can_fetch(),
            "downloading": crate::browser_fetch::progress().map(|(done, total)| json!({"done": done, "total": total})),
            "sites": sites,
            "has_profile": p.exists(),
            "bytes": dir_size(&p),
            "running": running,
            "signing_in": SIGNING_IN.lock().unwrap().contains_key(agent),
        })
    }
}

/// While the person's sign-in window is open: the sites its pages are on.
/// Ends when the window closes (the socket drops).
async fn watch_sites(profile: &Path) -> HashSet<String> {
    let mut sites = HashSet::new();
    let Some((port, path)) = devtools(profile, Duration::from_secs(20)).await else { return sites };
    let Ok((mut ws, _)) = tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}{path}")).await else { return sites };
    if ws.send(WsMessage::Text(json!({"id": 1, "method": "Target.setDiscoverTargets", "params": {"discover": true}}).to_string().into())).await.is_err() {
        return sites;
    }
    while let Some(Ok(msg)) = ws.next().await {
        let WsMessage::Text(t) = msg else { continue };
        let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
        let info = &v["params"]["targetInfo"];
        if info["type"] != "page" {
            continue;
        }
        let url = info["url"].as_str().unwrap_or("");
        if url.starts_with("https://") || url.starts_with("http://") {
            if let Some(h) = host_of(url) {
                sites.insert(site_of(&h));
            }
        }
    }
    sites
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

    #[test]
    fn a_long_page_is_kept_whole_in_a_file_and_only_the_newest_stay() {
        let dir = tempfile::tempdir().unwrap();
        let name = save_page(dir.path(), "T", "https://example.com/a", &"word ".repeat(5000)).unwrap();
        let kept = std::fs::read_to_string(dir.path().join("browser-pages").join(&name)).unwrap();
        assert!(kept.starts_with("T\nhttps://example.com/a\n\nword word"));
        for _ in 0..PAGES_KEPT + 5 {
            save_page(dir.path(), "T", "u", "x").unwrap();
        }
        assert!(std::fs::read_dir(dir.path().join("browser-pages")).unwrap().count() <= PAGES_KEPT);
    }

    #[test]
    fn a_site_is_what_a_sign_in_is_good_for() {
        assert_eq!(site_of("mail.google.com"), "google.com");
        assert_eq!(site_of("www.bbc.co.uk"), "bbc.co.uk");
        assert_eq!(site_of("evil.github.io"), "evil.github.io");
        assert_ne!(site_of("evil.github.io"), site_of("bank.github.io"));
        assert_eq!(site_of("127.0.0.1"), "127.0.0.1");
        assert_eq!(site_of("[::1]"), "::1");
    }

    #[test]
    fn this_computer_and_its_network_are_local() {
        for h in ["localhost", "app.localhost", "127.0.0.1", "10.1.2.3", "192.168.1.1", "169.254.169.254", "[::1]", "printer.local", "100.64.0.1", "0.0.0.0"] {
            assert!(is_local(h), "{h}");
        }
        for h in ["example.com", "8.8.8.8", "100.128.0.1", "2606:4700::1111"] {
            assert!(!is_local(h), "{h}");
        }
    }

    fn gate(site: &str, signed_in: &[&str]) -> Gate {
        Gate { main_frame: "M".into(), site: Some(site.into()), signed_in: signed_in.iter().map(|s| s.to_string()).collect(), ..Gate::default() }
    }

    #[test]
    fn a_page_cannot_carry_the_browser_onto_a_signed_in_site() {
        let mut g = gate("evil.com", &["bank.com"]);
        assert!(!g.allows("https://www.bank.com/transfer?to=evil", "Document", "M"));
        assert_eq!(g.site.as_deref(), Some("evil.com"), "the browser stays where it was");
        assert!(g.blocked[0].contains("bank.com"), "{:?}", g.blocked);
        // A frame or an image on that site is the web's own business (its cookies have their own rules).
        assert!(g.allows("https://www.bank.com/logo.png", "Image", "M"));
        assert!(g.allows("https://www.bank.com/embed", "Document", "child"));
        // Elsewhere is fine, and is where the browser now is.
        assert!(g.allows("https://news.example.org/a", "Document", "M"));
        assert_eq!(g.site.as_deref(), Some("example.org"));
    }

    #[test]
    fn the_person_sending_it_or_approving_a_click_uses_the_sign_in() {
        // Sent there: the site is the one it was sent to.
        let mut g = gate("bank.com", &["bank.com"]);
        assert!(g.allows("https://bank.com/accounts", "Document", "M"));
        // An approved click on another site leads there.
        let mut g = gate("evil.com", &["bank.com"]);
        g.free = true;
        assert!(g.allows("https://bank.com/", "Document", "M"));
        assert_eq!(g.site.as_deref(), Some("bank.com"));
        // One signed-in site handing over to another is the person's single sign-on.
        let mut g = gate("app.com", &["app.com", "google.com"]);
        assert!(g.allows("https://accounts.google.com/o/oauth2", "Document", "M"));
    }

    #[test]
    fn nothing_but_the_web_and_nothing_on_this_computer() {
        let mut g = gate("example.com", &[]);
        assert!(!g.allows("file:///etc/passwd", "Document", "M"));
        assert!(!g.allows("http://127.0.0.1:8080/admin", "XHR", "M"));
        assert!(!g.allows("http://169.254.169.254/latest/meta-data/", "Fetch", "M"));
        assert!(!g.allows("http://router.local/", "Image", "M"));
        assert!(g.allows("data:text/plain,hi", "Other", "M"));
        assert!(g.allows("https://cdn.example.net/x.js", "Script", "M"));
        // The person sent it to their own machine: that address, and only that one.
        let mut g = gate("localhost", &[]);
        assert!(g.allows("http://localhost:3000/", "Document", "M"));
        assert!(!g.allows("http://192.168.1.1/", "XHR", "M"));
    }

    /// A real browser: a page that reaches for this computer is stopped before anything connects.
    #[tokio::test]
    async fn a_real_page_cannot_reach_this_computer() {
        if chrome().is_none() || std::env::var("COOKIE_BROWSER_TESTS").is_err() {
            return;
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let hits = Arc::new(AtomicU64::new(0));
        let h = hits.clone();
        tokio::spawn(async move {
            while listener.accept().await.is_ok() {
                h.fetch_add(1, Ordering::Relaxed);
            }
        });
        let dir = tempfile::tempdir().unwrap();
        let mut s = launch(&chrome().unwrap(), &dir.path().join("profile"), HashSet::new()).await.unwrap();
        s.gate.lock().unwrap().site = Some("example.com".into());
        let page = format!("data:text/html,<title>T</title><img src=\"http://127.0.0.1:{port}/steal\"><script>fetch('http://localhost:{port}/x').catch(()=>{{}})</script><p>hi</p>");
        s.call("Page.navigate", json!({"url": page})).await.unwrap();
        s.settle().await;
        let text = read_page("t2", &mut s, None).await.unwrap();
        assert!(text.starts_with("Cookie stopped these"), "{text}");
        assert!(text.contains("127.0.0.1") && text.contains("localhost"), "{text}");
        assert_eq!(hits.load(Ordering::Relaxed), 0, "nothing reached the local server");
        let _ = s.child.kill().await;
    }

    /// A real headless Chrome on this machine: open a local page, read it, click by number.
    #[tokio::test]
    async fn the_browser_reads_and_clicks() {
        if chrome().is_none() || std::env::var("COOKIE_BROWSER_TESTS").is_err() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let mut s = launch(&chrome().unwrap(), &dir.path().join("profile"), HashSet::new()).await.unwrap();
        let page = "data:text/html,<title>T</title><button onclick=\"document.title='clicked'\">Go</button><p>hello there</p>";
        s.call("Page.navigate", json!({"url": page})).await.unwrap();
        s.settle().await;
        let text = read_page("t", &mut s, None).await.unwrap();
        assert!(text.contains("[1] button \"Go\"") && text.contains("hello there"), "{text}");
        assert_eq!(seen("t", &json!(1)), "[1] button \"Go\"");
        let (x, y, _) = locate(&mut s, 1).await.unwrap();
        click_at(&mut s, x, y).await.unwrap();
        assert_eq!(s.eval("document.title").await.unwrap(), json!("clicked"));
        let _ = s.child.kill().await;
    }
}

/* ---------- replaying a saved run, with no model (`browser_runs`) ---------- */

/// The number the page gives the element labelled `label` now (after a read numbered them).
async fn ref_by_label(s: &mut Session, label: &str) -> Result<u64, String> {
    let want = serde_json::to_string(label.trim()).unwrap_or_default();
    let v = s
        .eval(&format!(
            "(() => {{ const want = {want}; for (const e of document.querySelectorAll('[data-cookie-ref]')) {{ const l = (e.getAttribute('aria-label') || e.innerText || e.value || e.placeholder || e.name || '').trim().slice(0, 80); if (l === want) return Number(e.getAttribute('data-cookie-ref')); }} return null; }})()"
        ))
        .await?;
    v.as_u64().ok_or_else(|| format!("“{label}” isn't on the page any more: the site has changed since this run was saved."))
}

/// Runs `steps` in the agent's browser, one after another, with no model between them. Stops at
/// the first step the page no longer matches, and says which.
pub(crate) async fn replay(team: &Team, agent: &str, steps: &[crate::browser_runs::RunStep], values: &std::collections::BTreeMap<String, String>) -> Result<String, String> {
    use crate::browser_runs::RunStep;
    let session = session(team, agent).await?;
    let mut s = session.lock().await;
    let work = team.paths.work(agent);
    let mut done = Vec::new();
    for (i, step) in steps.iter().enumerate() {
        let n = i + 1;
        match step {
            RunStep::Open { url } => {
                let url = https_or_http(url)?;
                {
                    let mut g = s.gate.lock().unwrap();
                    g.site = host_of(&url).map(|h| site_of(&h));
                    g.free = false;
                }
                s.call("Page.navigate", json!({"url": url})).await?;
                s.settle().await;
                done.push(format!("{n}. opened {url}"));
            }
            RunStep::Click { label } => {
                read_page(agent, &mut s, None).await?;
                let r = ref_by_label(&mut s, label).await.map_err(|e| format!("Step {n}: {e}"))?;
                let (x, y, _) = locate(&mut s, r).await?;
                // The person approved the whole run: its clicks may go where they lead.
                s.gate.lock().unwrap().free = true;
                click_at(&mut s, x, y).await?;
                s.settle().await;
                done.push(format!("{n}. clicked “{label}”"));
            }
            RunStep::Type { label, text, submit, fill } => {
                read_page(agent, &mut s, None).await?;
                let r = ref_by_label(&mut s, label).await.map_err(|e| format!("Step {n}: {e}"))?;
                let (x, y, _) = locate(&mut s, r).await?;
                click_at(&mut s, x, y).await?;
                let value = match fill {
                    Some(name) => values.get(name).cloned().ok_or_else(|| format!("Step {n} needs a value for “{name}”."))?,
                    None => text.clone(),
                };
                s.eval(&format!("(() => {{ const e = document.querySelector('[data-cookie-ref=\"{r}\"]'); if (e && 'value' in e) {{ e.value = ''; e.dispatchEvent(new Event('input', {{bubbles: true}})); }} }})()")).await?;
                s.call("Input.insertText", json!({"text": value})).await?;
                if *submit {
                    s.gate.lock().unwrap().free = true;
                    for kind in ["keyDown", "keyUp"] {
                        s.call("Input.dispatchKeyEvent", json!({"type": kind, "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "text": if kind == "keyDown" { "\r" } else { "" }})).await?;
                    }
                }
                s.settle().await;
                done.push(format!("{n}. typed into “{label}”{}", if *submit { " and sent it" } else { "" }));
            }
            RunStep::Back => {
                s.gate.lock().unwrap().free = true;
                s.eval("history.back()").await?;
                s.settle().await;
                done.push(format!("{n}. went back"));
            }
        }
    }
    let page = read_page(agent, &mut s, Some(&work)).await?;
    Ok(format!("Replayed {} steps:\n{}\n\nWhere it ended:\n{page}", done.len(), done.join("\n")))
}
