//! Web: read a page as text — with Scrapling when it is installed, else
//! plainly over HTTPS. The answer says which (`by`).
//!
//! Scrapling (a Python library) runs caged in the world with network on, so
//! what it fetches can only land in the world. Without it, Parallax fetches
//! the page itself (https only, 4 MB at most, 30 seconds) and takes the text
//! out of the HTML. Either way it is a read: nothing is sent but the request.

use async_trait::async_trait;
use serde_json::{json, Value};

use crate::engine::{s, ActionSpec, Ctx, Effect, Engine};

pub struct Web;

const MAX_BYTES: usize = 4 * 1024 * 1024;

/// Is Scrapling importable by the system Python?
pub async fn scrapling() -> bool {
    tokio::process::Command::new("/usr/bin/env").args(["python3", "-c", "import scrapling"]).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status().await.is_ok_and(|s| s.success())
}

const SCRAPLING_PY: &str = r#"
import json, sys
from scrapling.fetchers import Fetcher
page = Fetcher.get(sys.argv[1])
text = None
for name in ("get_all_text", "text"):
    v = getattr(page, name, None)
    try:
        text = v() if callable(v) else v
    except TypeError:
        text = None
    if text:
        break
title = None
try:
    title = page.css_first("title::text") if hasattr(page, "css_first") else None
except Exception:
    title = None
print(json.dumps({"status": getattr(page, "status", None), "title": str(title) if title else None, "text": str(text or "")[:200000]}))
"#;

/// Text of an HTML page: no scripts or styles, tags out, entities read, spaces tidied.
pub fn html_text(html: &str) -> (Option<String>, String) {
    let lower = html.to_lowercase();
    let title = lower.find("<title").and_then(|a| lower[a..].find('>').map(|b| a + b + 1)).and_then(|st| lower[st..].find("</title>").map(|e| html[st..st + e].trim().to_string()));
    let mut out = String::with_capacity(html.len() / 3);
    let (mut i, bytes) = (0, html.as_bytes());
    while i < bytes.len() {
        if bytes[i] == b'<' {
            let rest = &lower[i..];
            for skip in ["script", "style", "noscript", "svg"] {
                if rest.starts_with(&format!("<{skip}")) {
                    if let Some(end) = rest.find(&format!("</{skip}>")) {
                        i += end + skip.len() + 3;
                        break;
                    }
                }
            }
            if i < bytes.len() && bytes[i] == b'<' {
                let block = ["<p", "<br", "<div", "<li", "<h1", "<h2", "<h3", "<h4", "<tr", "</p", "</div", "</li"].iter().any(|t| lower[i..].starts_with(t));
                match lower[i..].find('>') {
                    Some(e) => i += e + 1,
                    None => break,
                }
                if block {
                    out.push('\n');
                }
            }
        } else {
            let ch_len = html[i..].chars().next().map(|c| c.len_utf8()).unwrap_or(1);
            out.push_str(&html[i..i + ch_len]);
            i += ch_len;
        }
    }
    let out = out.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'");
    let tidy: Vec<String> = out.lines().map(|l| l.split_whitespace().collect::<Vec<_>>().join(" ")).filter(|l| !l.is_empty()).collect();
    (title, tidy.join("\n"))
}

async fn fetch(url: &str) -> Result<Value, String> {
    if !url.starts_with("https://") {
        return Err("The web engine reads https pages.".into());
    }
    let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(30)).user_agent("Parallax/0.1 (+https://github.com/DevbyNaveen/cookie-agent)").build().map_err(|e| e.to_string())?;
    let resp = client.get(url).send().await.map_err(|e| format!("Couldn't reach {url}: {e}"))?;
    let status = resp.status().as_u16();
    let mut body = Vec::new();
    let mut stream = resp.bytes_stream();
    use futures::StreamExt;
    while let Some(chunk) = stream.next().await {
        body.extend_from_slice(&chunk.map_err(|e| e.to_string())?);
        if body.len() > MAX_BYTES {
            break;
        }
    }
    let (title, text) = html_text(&String::from_utf8_lossy(&body));
    Ok(json!({"status": status, "title": title, "text": crate::util::clip(&text, 200_000), "by": "https"}))
}

#[async_trait]
impl Engine for Web {
    fn name(&self) -> &'static str {
        "web"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let p = json!({"type": "string"});
        vec![
            ActionSpec::new("web", "read", "Read a web page as text (Scrapling when installed, else plain HTTPS).", json!({"type": "object", "properties": {"url": p}, "required": ["url"]}), Effect::Read),
            ActionSpec::new("web", "save", "Read a page and save its text into the world.", json!({"type": "object", "properties": {"url": p, "to": p}, "required": ["url", "to"]}), Effect::Local),
        ]
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        let url = s(args, "url")?.trim();
        if !url.starts_with("https://") {
            return Err("The web engine reads https pages.".into());
        }
        let page = if scrapling().await {
            let script = ctx.state.join("scrapling_read.py");
            std::fs::create_dir_all(&ctx.state).map_err(|e| e.to_string())?;
            std::fs::write(&script, SCRAPLING_PY).map_err(|e| e.to_string())?;
            let quoted = url.replace('\'', "'\\''");
            let (code, out) = crate::sizes::world_run(&ctx.files, &format!("python3 .parallax/scrapling_read.py '{quoted}'"), true, 60).await?;
            match (code, out.lines().rev().find_map(|l| serde_json::from_str::<Value>(l).ok())) {
                (0, Some(mut v)) => {
                    v["by"] = json!("scrapling");
                    v
                }
                _ => fetch(url).await?,
            }
        } else {
            fetch(url).await?
        };
        if action == "save" {
            let to = s(args, "to")?;
            std::fs::write(ctx.path(to)?, page["text"].as_str().unwrap_or("")).map_err(|e| e.to_string())?;
            return Ok(json!({"written": to, "by": page["by"]}));
        }
        Ok(page)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn text_out_of_html() {
        let (t, x) = super::html_text("<html><head><title>Hi</title><style>p{}</style></head><body><p>One &amp; two</p><script>alert(1)</script><div>three</div></body></html>");
        assert_eq!(t.as_deref(), Some("Hi"));
        assert_eq!(x, "Hi\nOne & two\nthree");
    }
}
