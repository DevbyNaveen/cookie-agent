//! Browser: Chrome without a window, one per world.
//!
//! Each world has its own browser profile (`.parallax/browser` inside the
//! world), so forking a world forks its cookies and sign-ins too. Opening and
//! reading a page are reads. The web itself can't be forked, so a click or
//! typed text — which may submit, buy or send — is an outside action: it stops
//! at the wall for a person's yes. A page is read with its links, buttons and
//! fields numbered; clicks are real mouse events at the element.

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::sync::Mutex;
use tokio_tungstenite::tungstenite::Message as Ws;

use crate::engine::{s, ActionSpec, Ctx, Effect, Engine};

const CHROMES: &[&str] = &[
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
];

pub fn chrome() -> Option<&'static str> {
    CHROMES.iter().copied().find(|p| Path::new(p).exists())
}

type Sock = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

struct Session {
    child: tokio::process::Child,
    ws: Sock,
    next: AtomicU64,
}

impl Session {
    async fn call(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        self.ws.send(Ws::Text(json!({"id": id, "method": method, "params": params}).to_string().into())).await.map_err(|e| format!("The browser closed: {e}"))?;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
        loop {
            let m = tokio::time::timeout_at(deadline, self.ws.next()).await.map_err(|_| format!("The browser didn't answer {method}."))?.ok_or("The browser closed.")?.map_err(|e| e.to_string())?;
            let Ws::Text(t) = m else { continue };
            let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
            if v["id"].as_u64() != Some(id) {
                continue;
            }
            if let Some(e) = v.get("error") {
                return Err(e["message"].as_str().unwrap_or("refused").to_string());
            }
            return Ok(v["result"].clone());
        }
    }

    async fn eval(&mut self, expr: &str) -> Result<Value, String> {
        let r = self.call("Runtime.evaluate", json!({"expression": expr, "returnByValue": true, "awaitPromise": true})).await?;
        if let Some(ex) = r.get("exceptionDetails") {
            return Err(ex.pointer("/exception/description").and_then(Value::as_str).unwrap_or("the page's script failed").to_string());
        }
        Ok(r.pointer("/result/value").cloned().unwrap_or(Value::Null))
    }

    async fn settle(&mut self) {
        let end = Instant::now() + Duration::from_secs(20);
        while Instant::now() < end {
            if self.eval("document.readyState").await.ok().as_ref().and_then(Value::as_str) == Some("complete") {
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }

    async fn read(&mut self) -> Result<Value, String> {
        self.settle().await;
        self.eval(READ_JS).await
    }
}

const READ_JS: &str = r#"(() => {
  const sel = 'a[href], button, input:not([type=hidden]), select, textarea, [role=button], [role=link], [contenteditable=true]';
  const els = [...document.querySelectorAll(sel)].filter(e => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; });
  document.querySelectorAll('[data-px-ref]').forEach(e => e.removeAttribute('data-px-ref'));
  const items = els.slice(0, 150).map((e, i) => {
    e.setAttribute('data-px-ref', String(i + 1));
    const t = e.tagName.toLowerCase();
    const kind = t === 'a' ? 'link' : t === 'input' ? 'field:' + (e.type || 'text') : t === 'select' ? 'choice' : t === 'textarea' ? 'field:text' : 'button';
    const label = (e.getAttribute('aria-label') || e.innerText || e.value || e.placeholder || e.name || '').trim().replace(/\s+/g, ' ').slice(0, 80);
    return {ref: i + 1, kind, label, href: t === 'a' ? (e.href || '').slice(0, 200) : undefined};
  });
  return {title: document.title, url: location.href, items, text: (document.body ? document.body.innerText : '').slice(0, 20000)};
})()"#;

#[derive(Default)]
pub struct Browser {
    sessions: Mutex<HashMap<String, Arc<Mutex<Session>>>>,
}

async fn launch(profile: &Path) -> Result<Session, String> {
    let bin = chrome().ok_or("The browser engine needs Chrome, Chromium, Brave or Edge.")?;
    std::fs::create_dir_all(profile).map_err(|e| e.to_string())?;
    let port_file = profile.join("DevToolsActivePort");
    let _ = std::fs::remove_file(&port_file);
    let child = tokio::process::Command::new(bin)
        .args(["--headless=new", "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1", "--no-first-run", "--no-default-browser-check", "--disable-sync", "--window-size=1280,900"])
        .arg(format!("--user-data-dir={}", profile.display()))
        .arg("about:blank")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| e.to_string())?;
    let end = Instant::now() + Duration::from_secs(15);
    let port = loop {
        if let Some(p) = std::fs::read_to_string(&port_file).ok().and_then(|s| s.lines().next().and_then(|l| l.trim().parse::<u16>().ok())) {
            break p;
        }
        if Instant::now() > end {
            return Err("The browser didn't start in 15 seconds.".into());
        }
        tokio::time::sleep(Duration::from_millis(150)).await;
    };
    let list: Value = reqwest::Client::new().get(format!("http://127.0.0.1:{port}/json/list")).timeout(Duration::from_secs(5)).send().await.map_err(|e| e.to_string())?.json().await.map_err(|e| e.to_string())?;
    let url = list.as_array().into_iter().flatten().find(|t| t["type"] == "page").and_then(|t| t["webSocketDebuggerUrl"].as_str()).ok_or("The browser has no page.")?.to_string();
    if !url.starts_with("ws://127.0.0.1:") {
        return Err("The browser's control socket isn't local.".into());
    }
    let (ws, _) = tokio_tungstenite::connect_async(&url).await.map_err(|e| e.to_string())?;
    let mut s = Session { child, ws, next: AtomicU64::new(1) };
    s.call("Page.enable", json!({})).await?;
    s.call("Runtime.enable", json!({})).await?;
    Ok(s)
}

impl Browser {
    async fn session(&self, ctx: &Ctx) -> Result<Arc<Mutex<Session>>, String> {
        let mut all = self.sessions.lock().await;
        if let Some(s) = all.get(&ctx.world) {
            if s.lock().await.child.try_wait().ok().flatten().is_none() {
                return Ok(s.clone());
            }
            all.remove(&ctx.world);
        }
        let s = Arc::new(Mutex::new(launch(&ctx.state.join("browser")).await?));
        all.insert(ctx.world.clone(), s.clone());
        Ok(s)
    }
}

async fn locate(s: &mut Session, r: u64) -> Result<(f64, f64), String> {
    let v = s.eval(&format!("(() => {{ const e = document.querySelector('[data-px-ref=\"{r}\"]'); if (!e) return null; e.scrollIntoView({{block: 'center'}}); const b = e.getBoundingClientRect(); return {{x: b.left + b.width / 2, y: b.top + b.height / 2}}; }})()")).await?;
    if v.is_null() {
        return Err(format!("There is no [{r}] on the page now; read it again for fresh numbers."));
    }
    Ok((v["x"].as_f64().unwrap_or(0.0), v["y"].as_f64().unwrap_or(0.0)))
}

async fn click(s: &mut Session, x: f64, y: f64) -> Result<(), String> {
    for t in ["mouseMoved", "mousePressed", "mouseReleased"] {
        s.call("Input.dispatchMouseEvent", json!({"type": t, "x": x, "y": y, "button": "left", "clickCount": 1})).await?;
    }
    Ok(())
}

fn web_address(u: &str) -> Result<String, String> {
    let u = u.trim();
    if u.starts_with("https://") || u.starts_with("http://") {
        Ok(u.into())
    } else if !u.contains("://") && u.contains('.') && !u.contains(' ') {
        Ok(format!("https://{u}"))
    } else {
        Err("Open a web address (https://…).".into())
    }
}

#[async_trait]
impl Engine for Browser {
    fn name(&self) -> &'static str {
        "browser"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let p = json!({"type": "string"});
        let n = json!({"type": "integer"});
        vec![
            ActionSpec::new("browser", "open", "Open a page in this world's browser and read it (text, and links, buttons and fields by number).", json!({"type": "object", "properties": {"url": p}, "required": ["url"]}), Effect::Read),
            ActionSpec::new("browser", "read", "Read the page the browser is on now, with fresh numbers.", json!({"type": "object", "properties": {}}), Effect::Read),
            ActionSpec::new("browser", "click", "Click an element by its number.", json!({"type": "object", "properties": {"ref": n, "what": p}, "required": ["ref", "what"]}), Effect::Outside),
            ActionSpec::new("browser", "type", "Type into a field by its number; `submit` presses Enter.", json!({"type": "object", "properties": {"ref": n, "text": p, "submit": {"type": "boolean"}}, "required": ["ref", "text"]}), Effect::Outside),
            ActionSpec::new("browser", "screenshot", "Save a screenshot of the page into the world.", json!({"type": "object", "properties": {"to": p}, "required": ["to"]}), Effect::Local),
        ]
    }

    fn preview(&self, action: &str, args: &Value) -> String {
        match action {
            "click" => format!("Click [{}] in the browser: {}", args["ref"], args["what"].as_str().unwrap_or("")),
            "type" => format!("Type into [{}]{}: {}", args["ref"], if args["submit"].as_bool().unwrap_or(false) { " and press Enter" } else { "" }, crate::util::clip(args["text"].as_str().unwrap_or(""), 400)),
            _ => format!("browser {action}"),
        }
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        let sess = self.session(ctx).await?;
        let mut s = sess.lock().await;
        match action {
            "open" => {
                s.call("Page.navigate", json!({"url": web_address(crate::engine::s(args, "url")?)?})).await?;
                s.read().await
            }
            "read" => s.read().await,
            "click" => {
                let r = args["ref"].as_u64().ok_or("Which number?")?;
                let (x, y) = locate(&mut s, r).await?;
                click(&mut s, x, y).await?;
                s.read().await
            }
            "type" => {
                let r = args["ref"].as_u64().ok_or("Which field?")?;
                let (x, y) = locate(&mut s, r).await?;
                click(&mut s, x, y).await?;
                s.eval(&format!("(() => {{ const e = document.querySelector('[data-px-ref=\"{r}\"]'); if (e && 'value' in e) {{ e.value = ''; e.dispatchEvent(new Event('input', {{bubbles: true}})); }} }})()")).await?;
                s.call("Input.insertText", json!({"text": s_text(args)?})).await?;
                if args["submit"].as_bool().unwrap_or(false) {
                    for t in ["keyDown", "keyUp"] {
                        s.call("Input.dispatchKeyEvent", json!({"type": t, "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "text": if t == "keyDown" { "\r" } else { "" }})).await?;
                    }
                }
                s.read().await
            }
            "screenshot" => {
                use base64::Engine as _;
                let r = s.call("Page.captureScreenshot", json!({"format": "png"})).await?;
                let png = base64::engine::general_purpose::STANDARD.decode(r["data"].as_str().unwrap_or("")).map_err(|e| e.to_string())?;
                let to = s_to(args)?;
                std::fs::write(ctx.path(to)?, png).map_err(|e| e.to_string())?;
                Ok(json!({"written": to}))
            }
            other => Err(format!("The browser engine has no action {other}.")),
        }
    }

    async fn sleep(&self, world: &str) {
        if let Some(s) = self.sessions.lock().await.remove(world) {
            let mut s = s.lock().await;
            let _ = s.call("Browser.close", json!({})).await;
            let _ = s.child.kill().await;
        }
    }
}

fn s_text(args: &Value) -> Result<&str, String> {
    s(args, "text")
}

fn s_to(args: &Value) -> Result<&str, String> {
    s(args, "to")
}

#[cfg(test)]
mod tests {
    #[test]
    fn only_web_addresses() {
        assert_eq!(super::web_address("example.com").unwrap(), "https://example.com");
        assert!(super::web_address("file:///etc/passwd").is_err());
        assert!(super::web_address("javascript:alert(1)").is_err());
    }
}
