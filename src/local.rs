//! `cookie local`: Cookie on your own machine. Your model key, a folder of
//! yours as context (read only), the web through your search key if you have
//! one, and pages read straight from the web. Nothing it can do sends, writes
//! or deletes. A page address that came from a page, a file or a search
//! result asks you first (`ask`, the default); `full` reads it without asking.

use std::{
    collections::HashMap,
    path::{Component, Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

use serde_json::{json, Value};

use crate::tool::{tool, Effect, Tool};

/// What `cookie local` tells the model, before anything the person adds.
pub const LOCAL_INSTRUCTIONS: &str = "You are Cookie, working on the person's own computer. You can look through the folder \
they opened you in (read only), search the web when a search key is set, and read web pages. You cannot send, delete \
or change anything of theirs, and you never claim you did. Look things up before you answer; ask every lookup you already \
know you need in the same turn. Lead with the answer, as long as the question needs. Say where each fact came from: a \
file path with its line, or a page address. When you could not find something, say so plainly.";

/// The model `cookie local` uses when none is named: Anthropic when its key
/// is set. Every other provider needs `--model`, so nothing is guessed.
pub fn default_model() -> Result<String, String> {
    if let Ok(model) = std::env::var("COOKIE_MODEL") {
        if !model.trim().is_empty() {
            return Ok(model.trim().to_string());
        }
    }
    if std::env::var("ANTHROPIC_API_KEY").is_ok_and(|k| !k.trim().is_empty()) {
        return Ok("anthropic:claude-sonnet-4-6".into());
    }
    Err(MISSING_MODEL.into())
}

pub const MISSING_MODEL: &str = "cookie local needs a model. The quickest way:
  export ANTHROPIC_API_KEY=sk-ant-...      # then run `cookie local` again
Or name one with --model (or COOKIE_MODEL):
  --model openai:<model>                    with OPENAI_API_KEY (OPENAI_BASE_URL for compatible servers)
  --model gemini:gemini-3.8-flash           with GEMINI_API_KEY
  --model ollama:qwen3                      with Ollama running (OLLAMA_HOST, default localhost:11434)
  --model bedrock:<model id>                with AWS credentials, in a build with --features bedrock";

/// A web search backend, from the first key set: Exa, then TinyFish, then
/// Brave. With Exa and TinyFish both set, TinyFish answers when Exa fails.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Search {
    pub exa: Option<String>,
    pub tinyfish: Option<String>,
    pub brave: Option<String>,
}

impl Search {
    pub fn from_env() -> Option<Self> {
        let key = |name: &str| std::env::var(name).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
        let search = Self { exa: key("EXA_API_KEY"), tinyfish: key("TINYFISH_API_KEY"), brave: key("BRAVE_SEARCH_API_KEY") };
        (search.exa.is_some() || search.tinyfish.is_some() || search.brave.is_some()).then_some(search)
    }

    /// The engine that answers first, for the banner.
    pub fn name(&self) -> &'static str {
        if self.exa.is_some() {
            "Exa"
        } else if self.tinyfish.is_some() {
            "TinyFish"
        } else {
            "Brave"
        }
    }

    async fn search(&self, http: &reqwest::Client, query: &str) -> Result<String, String> {
        if let Some(key) = &self.exa {
            match exa(http, key, query).await {
                Ok(text) => return Ok(text),
                Err(e) if self.tinyfish.is_none() && self.brave.is_none() => return Err(e),
                Err(_) => {}
            }
        }
        if let Some(key) = &self.tinyfish {
            match tinyfish(http, key, query).await {
                Ok(text) => return Ok(text),
                Err(e) if self.brave.is_none() => return Err(e),
                Err(_) => {}
            }
        }
        match &self.brave {
            Some(key) => brave(http, key, query).await,
            None => Err("web search failed".into()),
        }
    }
}

const RESULTS: usize = 8;

async fn get_json(request: reqwest::RequestBuilder) -> Result<Value, String> {
    let resp = request.timeout(Duration::from_secs(20)).send().await.map_err(|e| format!("web search unreachable: {e}"))?;
    let status = resp.status();
    if !status.is_success() {
        let why = match status.as_u16() {
            402 | 429 => ": the search allowance is used up for now",
            401 | 403 => ": the search key was refused",
            _ => "",
        };
        return Err(format!("web search failed ({status}){why}"));
    }
    resp.json().await.map_err(|e| format!("web search response: {e}"))
}

async fn exa(http: &reqwest::Client, key: &str, query: &str) -> Result<String, String> {
    let body = json!({"query": query, "type": "auto", "numResults": RESULTS, "contents": {"highlights": true}});
    let v = get_json(http.post("https://api.exa.ai/search").header("x-api-key", key).json(&body)).await?;
    Ok(results(query, v["results"].as_array(), |r| {
        let passages: Vec<String> = r["highlights"].as_array().into_iter().flatten().filter_map(Value::as_str).map(one_line).collect();
        (str_of(r, "title"), str_of(r, "url"), passages.join(" … "))
    }))
}

async fn tinyfish(http: &reqwest::Client, key: &str, query: &str) -> Result<String, String> {
    let v = get_json(http.get("https://api.search.tinyfish.ai").query(&[("query", query)]).header("X-API-Key", key)).await?;
    Ok(results(query, v["results"].as_array(), |r| (str_of(r, "title"), str_of(r, "url"), one_line(&str_of(r, "snippet")))))
}

async fn brave(http: &reqwest::Client, key: &str, query: &str) -> Result<String, String> {
    let request = http
        .get("https://api.search.brave.com/res/v1/web/search")
        .query(&[("q", query), ("count", &RESULTS.to_string())])
        .header("X-Subscription-Token", key)
        .header("Accept", "application/json");
    let v = get_json(request).await?;
    Ok(results(query, v.pointer("/web/results").and_then(Value::as_array), |r| {
        (str_of(r, "title"), str_of(r, "url"), one_line(&str_of(r, "description")))
    }))
}

fn str_of(v: &Value, key: &str) -> String {
    v[key].as_str().unwrap_or_default().trim().to_string()
}

fn one_line(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Every engine's results in one shape: `1. Title\n   url\n   text`.
fn results(query: &str, list: Option<&Vec<Value>>, row: impl Fn(&Value) -> (String, String, String)) -> String {
    let list = list.map(Vec::as_slice).unwrap_or_default();
    if list.is_empty() {
        return format!("No web results for \"{query}\".");
    }
    let mut out = format!("Web results for \"{query}\":\n");
    for (i, r) in list.iter().take(RESULTS).enumerate() {
        let (title, url, text) = row(r);
        let title = if title.is_empty() { "(untitled)".to_string() } else { title };
        out.push_str(&format!("\n{}. {title}\n   {url}\n", i + 1));
        if !text.is_empty() {
            out.push_str(&format!("   {}\n", clip(&text, 700)));
        }
    }
    out.push_str("\nRead a page with `read_url` before relying on it.\n");
    out
}

fn clip(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        s.to_string()
    } else {
        format!("{}…", s.chars().take(n).collect::<String>())
    }
}

/// The tools `cookie local` offers: the folder's (when there is one), web
/// search (when a key is set), and page reading. `ask`: a page address that
/// came from something Cookie read goes to the person first.
pub fn tools(root: Option<PathBuf>, search: Option<Search>, ask: bool) -> Vec<Arc<dyn Tool>> {
    let http = reqwest::Client::builder()
        .user_agent(concat!("cookie/", env!("CARGO_PKG_VERSION"), " (+https://github.com/DevbyNaveen/cookie-agent)"))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap_or_default();
    let mut out: Vec<Arc<dyn Tool>> = Vec::new();
    if let Some(root) = root {
        let root = Arc::new(root);
        let r = root.clone();
        out.push(Arc::new(
            tool(
                "search_files",
                "Search the folder Cookie was opened in: file names and lines that contain the words. Returns path:line and the line.",
                json!({"type": "object", "properties": {"query": {"type": "string", "description": "words to look for"}}, "required": ["query"]}),
                Effect::Read,
                move |args: Value| {
                    let root = r.clone();
                    async move {
                        let query = args["query"].as_str().unwrap_or_default().to_string();
                        tokio::task::spawn_blocking(move || search_files(&root, &query)).await.map_err(|e| e.to_string())?
                    }
                },
            )
            .parallel_safe(),
        ));
        out.push(Arc::new(
            tool(
                "read_file",
                "Read a file in the folder, with line numbers. `path` is relative to the folder; `from_line` starts later in a long file.",
                json!({"type": "object", "properties": {"path": {"type": "string"}, "from_line": {"type": "integer", "minimum": 1}}, "required": ["path"]}),
                Effect::Read,
                move |args: Value| {
                    let root = root.clone();
                    async move {
                        let path = args["path"].as_str().unwrap_or_default().to_string();
                        let from = args["from_line"].as_u64().unwrap_or(1).max(1) as usize;
                        tokio::task::spawn_blocking(move || read_file(&root, &path, from)).await.map_err(|e| e.to_string())?
                    }
                },
            )
            .parallel_safe(),
        ));
    }
    if let Some(search) = search {
        let http = http.clone();
        out.push(Arc::new(
            tool(
                "web_search",
                "Search the web. Returns titles, addresses and passages from each page.",
                json!({"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}),
                Effect::Read,
                move |args: Value| {
                    let (search, http) = (search.clone(), http.clone());
                    async move {
                        let query = args["query"].as_str().unwrap_or_default().trim().to_string();
                        if query.is_empty() {
                            return Err("Say what to search for.".to_string());
                        }
                        search.search(&http, &query).await
                    }
                },
            )
            .parallel_safe(),
        ));
    }
    let robots = Arc::new(Mutex::new(HashMap::<String, Vec<(bool, String)>>::new()));
    let read = tool(
        "read_url",
        "Read a web page (https only) as text. Respects the site's robots.txt.",
        json!({"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}),
        Effect::Read,
        move |args: Value| {
            let (http, robots) = (http.clone(), robots.clone());
            async move { read_url(&http, &robots, args["url"].as_str().unwrap_or_default()).await }
        },
    )
    .parallel_safe();
    out.push(if ask { Arc::new(read.guard("url")) } else { Arc::new(read) });
    out
}

/// Folders never searched: version control, dependencies, build output.
const SKIP_DIRS: &[&str] = &[".git", "node_modules", "target", ".venv", "venv", "__pycache__", "dist", "build", ".next"];
const MAX_FILES: usize = 20_000;
const MAX_FILE_BYTES: u64 = 1_000_000;
const MAX_HITS: usize = 40;

/// A path inside the folder, refusing `..`, absolute paths and links that lead out.
fn inside(root: &Path, rel: &str) -> Result<PathBuf, String> {
    let rel = Path::new(rel.trim());
    if rel.is_absolute() || rel.components().any(|c| matches!(c, Component::ParentDir | Component::Prefix(_))) {
        return Err("Give a path inside the folder, like `src/main.rs`.".into());
    }
    let root = root.canonicalize().map_err(|e| format!("the folder can't be read: {e}"))?;
    let path = root.join(rel).canonicalize().map_err(|_| format!("`{}` isn't in the folder.", rel.display()))?;
    if !path.starts_with(&root) {
        return Err("That path leads outside the folder.".into());
    }
    Ok(path)
}

fn is_text(bytes: &[u8]) -> bool {
    !bytes[..bytes.len().min(8_192)].contains(&0)
}

pub fn search_files(root: &Path, query: &str) -> Result<String, String> {
    let words: Vec<String> = query.split_whitespace().map(str::to_lowercase).collect();
    if words.is_empty() {
        return Err("Say what to look for.".into());
    }
    let root = root.canonicalize().map_err(|e| format!("the folder can't be read: {e}"))?;
    let (mut hits, mut files, mut stack) = (Vec::new(), 0usize, vec![root.clone()]);
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let name = entry.file_name().to_string_lossy().to_string();
            // `file_type` does not follow links, so a link never leads out of the folder.
            let Ok(kind) = entry.file_type() else { continue };
            if name.starts_with('.') && name != ".github" {
                continue;
            }
            let path = entry.path();
            if kind.is_dir() {
                if !SKIP_DIRS.contains(&name.as_str()) {
                    stack.push(path);
                }
                continue;
            }
            if !kind.is_file() || entry.metadata().map_or(true, |m| m.len() > MAX_FILE_BYTES) {
                continue;
            }
            files += 1;
            if files > MAX_FILES {
                break;
            }
            let rel = path.strip_prefix(&root).unwrap_or(&path).display().to_string();
            if words.iter().all(|w| rel.to_lowercase().contains(w.as_str())) {
                hits.push(format!("{rel} (file name)"));
            }
            let Ok(bytes) = std::fs::read(&path) else { continue };
            if !is_text(&bytes) {
                continue;
            }
            for (n, line) in String::from_utf8_lossy(&bytes).lines().enumerate() {
                let lower = line.to_lowercase();
                if words.iter().all(|w| lower.contains(w.as_str())) {
                    hits.push(format!("{rel}:{}: {}", n + 1, clip(line.trim(), 200)));
                    if hits.len() >= MAX_HITS {
                        break;
                    }
                }
            }
            if hits.len() >= MAX_HITS {
                break;
            }
        }
        if hits.len() >= MAX_HITS || files > MAX_FILES {
            break;
        }
    }
    Ok(match hits.len() {
        0 => format!("Nothing in the folder has all of: {query}."),
        n if n >= MAX_HITS => format!("{}\n(first {MAX_HITS} matches; narrow the words for more)", hits.join("\n")),
        _ => hits.join("\n"),
    })
}

const READ_LINES: usize = 400;

pub fn read_file(root: &Path, rel: &str, from: usize) -> Result<String, String> {
    let path = inside(root, rel)?;
    let meta = std::fs::metadata(&path).map_err(|e| e.to_string())?;
    if meta.is_dir() {
        let mut names: Vec<String> = std::fs::read_dir(&path)
            .map_err(|e| e.to_string())?
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string() + if e.path().is_dir() { "/" } else { "" })
            .filter(|n| !n.starts_with('.'))
            .collect();
        names.sort();
        return Ok(format!("`{rel}` is a folder:\n{}", names.join("\n")));
    }
    if meta.len() > 10 * MAX_FILE_BYTES {
        return Err("That file is too large to read.".into());
    }
    let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
    if !is_text(&bytes) {
        return Err("That file isn't text.".into());
    }
    let text = String::from_utf8_lossy(&bytes);
    let lines: Vec<&str> = text.lines().collect();
    if from > lines.len().max(1) {
        return Err(format!("`{rel}` has {} lines.", lines.len()));
    }
    let end = (from - 1 + READ_LINES).min(lines.len());
    let mut out: Vec<String> = lines[from - 1..end].iter().enumerate().map(|(i, l)| format!("{:>5}  {l}", from + i)).collect();
    if end < lines.len() {
        out.push(format!("… {} more lines; read again with from_line {}", lines.len() - end, end + 1));
    }
    Ok(out.join("\n"))
}

const MAX_PAGE_BYTES: usize = 2_000_000;
const PAGE_CHARS: usize = 20_000;

/// A web page as text: https only, never an address on this machine or its
/// network, only where robots.txt allows, at most 2 MB, no redirects followed
/// blindly (a redirect is reported, so the next address is checked too).
async fn read_url(http: &reqwest::Client, robots: &Mutex<HashMap<String, Vec<(bool, String)>>>, raw: &str) -> Result<String, String> {
    let url = url::Url::parse(raw.trim()).map_err(|_| "That isn't a web address.".to_string())?;
    if url.scheme() != "https" {
        return Err("Only https pages can be read.".into());
    }
    let host = url.host_str().unwrap_or_default().to_lowercase();
    if !public_host(&url) {
        return Err("That address is on this machine or a private network; it can't be read.".into());
    }
    let rules = match robots.lock().ok().and_then(|r| r.get(&host).cloned()) {
        Some(rules) => rules,
        None => {
            let text = fetch_text(http, &format!("https://{host}/robots.txt"), 200_000).await.map(|(_, t)| t).unwrap_or_default();
            let rules = robots_rules(&text);
            if let Ok(mut r) = robots.lock() {
                r.insert(host.clone(), rules.clone());
            }
            rules
        }
    };
    let path = &url[url::Position::BeforePath..];
    if !robots_allow(&rules, path) {
        return Err(format!("{host}'s robots.txt asks agents not to read that page."));
    }
    let (kind, body) = fetch_text(http, url.as_str(), MAX_PAGE_BYTES).await?;
    let text = if kind.contains("html") { strip_html(&body) } else { body };
    let text = text.trim();
    if text.is_empty() {
        return Err(format!("{host} sent back an empty page."));
    }
    Ok(clip(text, PAGE_CHARS))
}

fn public_host(url: &url::Url) -> bool {
    match url.host() {
        Some(url::Host::Domain(d)) => {
            let d = d.to_lowercase();
            d.contains('.') && !d.ends_with(".local") && !d.ends_with(".internal") && !d.ends_with(".localhost") && d != "localhost"
        }
        // An address literal is never read: a model could aim it at this machine's network.
        _ => false,
    }
}

async fn fetch_text(http: &reqwest::Client, url: &str, cap: usize) -> Result<(String, String), String> {
    let mut resp = http.get(url).timeout(Duration::from_secs(15)).send().await.map_err(|e| format!("couldn't reach the page: {e}"))?;
    let status = resp.status();
    if status.is_redirection() {
        let to = resp.headers().get("location").and_then(|l| l.to_str().ok()).unwrap_or_default();
        let to = url::Url::parse(url).ok().and_then(|base| base.join(to).ok()).map(|u| u.to_string()).unwrap_or_default();
        return Err(format!("The page moved to {to}. Read that address instead."));
    }
    if !status.is_success() {
        return Err(format!("The page answered {status}."));
    }
    let kind = resp.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_lowercase();
    if !(kind.is_empty() || kind.starts_with("text/") || kind.contains("json") || kind.contains("xml")) {
        return Err(format!("That page is `{kind}`, not text."));
    }
    let mut body = Vec::new();
    while let Some(chunk) = resp.chunk().await.map_err(|e| format!("the page stopped: {e}"))? {
        body.extend_from_slice(&chunk);
        if body.len() >= cap {
            body.truncate(cap);
            break;
        }
    }
    Ok((kind, String::from_utf8_lossy(&body).to_string()))
}

/// robots.txt rules for any agent (`*`) or Cookie: `(allow, path prefix)`.
pub fn robots_rules(text: &str) -> Vec<(bool, String)> {
    let (mut rules, mut ours, mut in_agents) = (Vec::new(), false, false);
    for line in text.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        let Some((key, value)) = line.split_once(':') else { continue };
        let (key, value) = (key.trim().to_lowercase(), value.trim());
        match key.as_str() {
            "user-agent" => {
                // Consecutive user-agent lines share one group.
                if !in_agents {
                    ours = false;
                }
                in_agents = true;
                let agent = value.to_lowercase();
                ours |= agent == "*" || agent.starts_with("cookie");
            }
            "allow" | "disallow" => {
                in_agents = false;
                if ours && !value.is_empty() {
                    rules.push((key == "allow", value.to_string()));
                }
            }
            _ => in_agents = false,
        }
    }
    rules
}

/// The longest matching rule decides; a tie goes to Allow; no rule allows.
pub fn robots_allow(rules: &[(bool, String)], path: &str) -> bool {
    let path = if path.is_empty() { "/" } else { path };
    rules
        .iter()
        .filter(|(_, prefix)| path.starts_with(prefix.trim_end_matches('*').trim_end_matches('$')))
        .max_by_key(|(allow, prefix)| (prefix.len(), *allow))
        .is_none_or(|(allow, _)| *allow)
}

/// Readable text from HTML: no scripts, styles or markup; blocks on their own lines.
pub fn strip_html(html: &str) -> String {
    let mut s = html.to_string();
    for tag in ["script", "style", "noscript", "svg", "head", "template"] {
        loop {
            // ASCII-only lowering keeps every byte where it was, so positions
            // found in `lower` are positions in `s` (`to_lowercase` can grow a string).
            let lower = s.to_ascii_lowercase();
            let Some(start) = lower.find(&format!("<{tag}")) else { break };
            let end = lower[start..].find(&format!("</{tag}>")).map_or(s.len(), |e| start + e + tag.len() + 3);
            s.replace_range(start..end, " ");
        }
    }
    let mut out = String::with_capacity(s.len() / 2);
    let mut rest = s.as_str();
    while let Some(open) = rest.find('<') {
        out.push_str(&rest[..open]);
        let Some(close) = rest[open..].find('>') else { break };
        let tag = rest[open + 1..open + close].trim_start_matches('/').to_lowercase();
        let name: String = tag.chars().take_while(|c| c.is_ascii_alphanumeric()).collect();
        if matches!(name.as_str(), "br" | "p" | "div" | "li" | "tr" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "section" | "article" | "blockquote" | "pre") {
            out.push('\n');
        }
        rest = &rest[open + close + 1..];
    }
    out.push_str(rest);
    decode_entities(&out).lines().map(one_line).filter(|l| !l.is_empty()).collect::<Vec<_>>().join("\n")
}

fn decode_entities(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        let after = &rest[amp + 1..];
        let end = after.find(';').filter(|e| *e <= 10);
        let decoded = end.and_then(|e| match &after[..e] {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" | "#39" => Some('\''),
            "nbsp" => Some(' '),
            n if n.starts_with("#x") || n.starts_with("#X") => u32::from_str_radix(&n[2..], 16).ok().and_then(char::from_u32),
            n if n.starts_with('#') => n[1..].parse().ok().and_then(char::from_u32),
            _ => None,
        });
        match (decoded, end) {
            (Some(c), Some(e)) => {
                out.push(c);
                rest = &after[e + 1..];
            }
            _ => {
                out.push('&');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn html_in_any_language_strips_without_breaking() {
        let page = "<p>İstanbul ÄRI</p><SCRIPT>x()</SCRIPT><p>Tööäpäev 東京</p><style>a{}</style>";
        let text = strip_html(page);
        assert!(text.contains("İstanbul ÄRI") && text.contains("Tööäpäev 東京") && !text.contains("x()"), "{text}");
    }

    #[test]
    fn html_reads_as_text_without_scripts_styles_or_tags() {
        let page = "<html><head><title>x</title><style>p{}</style></head><body><nav>Home</nav><h1>Acme &amp; Co</h1>\
                    <script>alert(1)</script><p>Raised&nbsp;$12M&#33;</p><p>In <b>Riga</b>.</p></body></html>";
        assert_eq!(strip_html(page), "Home\nAcme & Co\nRaised $12M!\nIn Riga.");
    }

    #[test]
    fn robots_txt_is_respected_for_any_agent_and_for_cookie() {
        let rules = robots_rules("User-agent: Googlebot\nDisallow: /\n\nUser-agent: *\nDisallow: /private\nAllow: /private/ok\n");
        assert!(robots_allow(&rules, "/blog"));
        assert!(!robots_allow(&rules, "/private/x"));
        assert!(robots_allow(&rules, "/private/ok/page"), "the longer Allow wins");
        assert!(robots_allow(&robots_rules(""), "/anything"), "no robots.txt allows");
        assert!(!robots_allow(&robots_rules("User-agent: cookie\nDisallow: /\n"), "/x"));
    }

    #[test]
    fn only_public_named_hosts_are_read() {
        for (url, ok) in [
            ("https://example.com/a", true),
            ("https://127.0.0.1/", false),
            ("https://[::1]/", false),
            ("https://localhost/", false),
            ("https://printer.local/", false),
            ("https://intranet/", false),
        ] {
            assert_eq!(public_host(&url::Url::parse(url).unwrap()), ok, "{url}");
        }
    }

    #[test]
    fn the_folder_is_searched_and_read_and_nothing_outside_it_is() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("src")).unwrap();
        std::fs::create_dir_all(dir.path().join("node_modules/x")).unwrap();
        std::fs::write(dir.path().join("src/refunds.rs"), "fn a() {}\n// Refunds go back within 14 days\n").unwrap();
        std::fs::write(dir.path().join("node_modules/x/refunds.js"), "refunds within days").unwrap();
        let found = search_files(dir.path(), "refunds days").unwrap();
        assert!(found.contains("src/refunds.rs:2: // Refunds go back within 14 days"), "{found}");
        assert!(!found.contains("node_modules"), "dependencies are never searched: {found}");
        assert!(read_file(dir.path(), "src/refunds.rs", 2).unwrap().starts_with("    2  // Refunds"));
        assert!(read_file(dir.path(), "../etc/passwd", 1).is_err());
        assert!(read_file(dir.path(), "/etc/passwd", 1).is_err());
        assert!(read_file(dir.path(), "src", 1).unwrap().contains("refunds.rs"), "a folder lists its files");
        assert!(search_files(dir.path(), "nowhere-to-be-found").unwrap().starts_with("Nothing in the folder"));
    }

    #[test]
    fn search_results_read_the_same_from_every_engine() {
        let list = vec![json!({"title": "Acme", "url": "https://acme.dev", "snippet": "We  build"})];
        let text = results("acme", Some(&list), |r| (str_of(r, "title"), str_of(r, "url"), one_line(&str_of(r, "snippet"))));
        assert!(text.contains("1. Acme\n   https://acme.dev\n   We build\n"), "{text}");
        assert!(results("q", None, |_| Default::default()).starts_with("No web results"));
    }
}
