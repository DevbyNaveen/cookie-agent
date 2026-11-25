//! Reading web pages through Enkeon's Scrapling, for agents with "The web" on.
//!
//! - **Fast first.** `scrapling::get` (a real browser's fingerprint, no browser)
//!   reads most pages in a second or two.
//! - **Stealth when a site blocks.** A 403/429/503, or a "checking you're
//!   human" page, goes again through `scrapling::stealthy_fetch` with a few
//!   seconds' wait: the fetcher made for protected sites (Cloudflare and kin).
//! - **Never stuck.** When Enkeon can't be reached, the Mac's own reader answers.
//!
//! Scrapling runs on Enkeon's server, so it reads with the Mac closed, and
//! nothing is installed here.

use std::sync::Arc;
use std::time::Duration;

use cookie_harness::tool::{tool, Effect, Tool};
use serde_json::{json, Value};

/// Words a page shows while it checks for bots, not the page itself.
const CHALLENGE: &[&str] = &[
    "performing security verification",
    "checking your browser",
    "verify you are human",
    "just a moment...",
    "enable javascript and cookies",
    "attention required! | cloudflare",
    "access denied",
    "are you a robot",
    "captcha",
];

/// The page text Scrapling returned, and whether it's the real page.
fn page_of(answer: &str) -> (u64, String) {
    let v: Value = serde_json::from_str(answer).unwrap_or(Value::Null);
    let status = v["status"].as_u64().unwrap_or(0);
    let text = match &v["content"] {
        Value::Array(parts) => parts.iter().filter_map(Value::as_str).collect::<Vec<_>>().join("\n").trim().to_string(),
        Value::String(s) => s.trim().to_string(),
        _ => String::new(),
    };
    (status, text)
}

fn blocked(status: u64, text: &str) -> bool {
    let lower = text.to_lowercase();
    matches!(status, 401 | 403 | 429 | 503) || text.len() < 200 && status != 200 || (text.len() < 3_000 && CHALLENGE.iter().any(|c| lower.contains(c)))
}

async fn scrapling(tool_name: &str, args: Value) -> Result<(u64, String), String> {
    let e = crate::pair::enkeon().ok_or("Enkeon isn't connected.")?;
    let client = e.client().await.map_err(|e| e.to_string())?;
    let (text, is_error) = tokio::time::timeout(Duration::from_secs(90), client.call_tool("tool_invoke", json!({"name": tool_name, "arguments": args})))
        .await
        .map_err(|_| "Enkeon's reader took too long.".to_string())?
        .map_err(|e| e.to_string())?;
    if is_error {
        return Err(text);
    }
    // tool_invoke wraps the tool's own reply: {content: [{text}]} or the text itself.
    let inner = serde_json::from_str::<Value>(&text).ok().and_then(|v| v["content"][0]["text"].as_str().map(str::to_string)).unwrap_or(text);
    Ok(page_of(&inner))
}

/// `read_url`, through Enkeon's Scrapling, with the Mac's own reader behind it.
pub(crate) fn read_url_tool(local: Arc<dyn Tool>) -> Arc<dyn Tool> {
    let t = tool(
        "read_url",
        "Read a web page (https) as text, through Enkeon's Scrapling: fast for most pages, and a stealth browser for sites \
         that block bots (Cloudflare and the like). Long pages come back in parts: pass `offset` for the next part.",
        json!({"type": "object", "properties": {
            "url": {"type": "string"},
            "offset": {"type": "integer", "description": "characters to skip, for the next part of a long page"}
        }, "required": ["url"]}),
        Effect::Read,
        move |a: Value| {
            let local = local.clone();
            async move {
                let url = a["url"].as_str().unwrap_or("").trim().to_string();
                if !url.starts_with("https://") && !url.starts_with("http://") {
                    return Err("Give a web address (https://…).".into());
                }
                let base = json!({"url": url, "extraction_type": "markdown", "main_content_only": true});
                let mut got = scrapling("scrapling::get", base.clone()).await;
                let mut how = "Scrapling";
                if got.as_ref().is_ok_and(|(s, t)| blocked(*s, t)) || got.is_err() && crate::pair::enkeon().is_some() {
                    let mut stealth = base.clone();
                    stealth["wait"] = json!(6000);
                    stealth["google_search"] = json!(true);
                    if let Ok(r) = scrapling("scrapling::stealthy_fetch", stealth).await {
                        got = Ok(r);
                        how = "Scrapling, stealth";
                    }
                }
                let (status, text) = match got {
                    Ok((s, t)) if !t.is_empty() && !blocked(s, &t) => (s, t),
                    Ok((s, _)) if crate::pair::enkeon().is_some() => {
                        // Scrapling reached the site but it refused even the stealth browser: the Mac tries.
                        return local.call(json!({"url": url})).await.map_err(|e| format!("The site refused ({s}), and reading it here failed too: {e}"));
                    }
                    _ => return local.call(json!({"url": url})).await,
                };
                let offset = a["offset"].as_u64().unwrap_or(0) as usize;
                let chars: Vec<char> = text.chars().collect();
                let part: String = chars.iter().skip(offset).take(30_000).collect();
                let more = if offset + 30_000 < chars.len() { format!("\n\n… {} more characters: read_url with offset {}.", chars.len() - offset - 30_000, offset + 30_000) } else { String::new() };
                Ok(format!("{url} (status {status}, via {how})\n\n{part}{more}"))
            }
        },
    )
    .parallel_safe();
    Arc::new(t.guard("url"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bot_check_is_not_the_page() {
        let wall = r#"{"status": 403, "content": ["www.example.com\n\nPerforming security verification\n\nThis website uses a security service"], "url": "x"}"#;
        let (s, t) = page_of(wall);
        assert!(blocked(s, &t));
        let fine = format!(r#"{{"status": 200, "content": ["{}"], "url": "x"}}"#, "A real article about leg presses. ".repeat(20));
        let (s, t) = page_of(&fine);
        assert!(!blocked(s, &t) && t.starts_with("A real article"));
        let long_with_word = format!(r#"{{"status": 200, "content": ["{} captcha"], "url": "x"}}"#, "text ".repeat(1000));
        let (s, t) = page_of(&long_with_word);
        assert!(!blocked(s, &t), "a long real page that merely mentions a captcha is the page");
    }
}
