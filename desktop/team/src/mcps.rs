//! Your own MCP servers: any tool that speaks MCP, added once in Connect apps.
//!
//! - **A URL or a command.** A remote server (`https://…/mcp`, with an optional
//!   token sent as `Authorization: Bearer`) or a local one started on this Mac
//!   (`npx -y @some/server`). The token lives in the Keychain, never in the file.
//! - **Checked when added, pinned after.** Adding one connects to it and lists
//!   its tools; the tool list's hash is saved. If the server later changes its
//!   tools, Cookie refuses it until you look again ([`Team::mcp_recheck`]).
//! - **Agents with "Apps" on get its tools,** named `<server>__<tool>`. Every
//!   call asks you first unless the server marks that tool read-only.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use cookie_harness::{McpServer, Tool};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{util, Team};

/// How long to wait for a server when a job starts; a slow one is skipped, not waited on.
const CONNECT_WAIT: Duration = Duration::from_secs(8);
/// Reconnect after this long, so a restarted server is picked up.
const FRESH_FOR: Duration = Duration::from_secs(600);

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct McpEntry {
    pub id: String,
    pub name: String,
    pub url: Option<String>,
    pub command: Option<String>,
    pub args: Vec<String>,
    /// A token is saved in the Keychain as `mcp:<id>`.
    pub has_token: bool,
    /// The tool list's hash when it was added or last rechecked.
    pub pin: Option<String>,
    pub tools: Vec<String>,
    pub on: bool,
    pub added: u64,
}

type Cached = (Instant, Vec<Arc<dyn Tool>>);
fn cache() -> &'static Mutex<HashMap<String, Cached>> {
    static C: OnceLock<Mutex<HashMap<String, Cached>>> = OnceLock::new();
    C.get_or_init(Default::default)
}

/// A tool-name-safe prefix: letters, digits and `_`, at most 20.
fn prefix_of(name: &str) -> String {
    let p: String = name.to_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
    let p = p.trim_matches('_').chars().take(20).collect::<String>();
    if p.is_empty() { "mcp".into() } else { p }
}

/// Split a command line on spaces, keeping "quoted parts" together.
fn split_command(line: &str) -> Vec<String> {
    let (mut out, mut cur, mut quote) = (Vec::new(), String::new(), None::<char>);
    for c in line.trim().chars() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (None, '"' | '\'') => quote = Some(c),
            (None, c) if c.is_whitespace() => {
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
            }
            (_, c) => cur.push(c),
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

impl McpEntry {
    fn server(&self, token: Option<String>) -> Result<McpServer, String> {
        let mut s = match (&self.url, &self.command) {
            (Some(url), _) => {
                let s = McpServer::http(url);
                match token {
                    Some(t) => s.header("Authorization", &format!("Bearer {t}")),
                    None => s,
                }
            }
            (None, Some(cmd)) => McpServer::stdio(cmd, &self.args.iter().map(String::as_str).collect::<Vec<_>>()),
            _ => return Err("A server is a URL or a command.".into()),
        };
        s = s.prefix(&prefix_of(&self.name)).timeout(Duration::from_secs(60));
        if let Some(p) = &self.pin {
            s = s.pin(p);
        }
        Ok(s)
    }

    fn view(&self) -> Value {
        json!({
            "id": self.id, "name": self.name, "url": self.url.as_deref().map(crate::privacy::scrub),
            "command": self.command.as_ref().map(|c| std::iter::once(c.clone()).chain(self.args.iter().cloned()).collect::<Vec<_>>().join(" ")),
            "has_token": self.has_token, "tools": self.tools, "on": self.on, "added": self.added,
        })
    }
}

impl Team {
    fn mcps_path(&self) -> std::path::PathBuf {
        self.paths.root.join("mcp-servers.json")
    }

    fn mcp_entries(&self) -> Vec<McpEntry> {
        util::read_json(&self.mcps_path())
    }

    fn save_mcps(&self, list: &[McpEntry]) -> Result<(), String> {
        util::write_json(&self.mcps_path(), &list)
    }

    pub fn mcps(&self) -> Value {
        json!({"servers": self.mcp_entries().iter().map(McpEntry::view).collect::<Vec<_>>()})
    }

    /// Connect once, list its tools, then save it with their hash pinned.
    pub async fn mcp_add(&self, name: &str, target: &str, token: Option<&str>) -> Result<Value, String> {
        let name = name.trim();
        let target = target.trim();
        if name.is_empty() || target.is_empty() {
            return Err("Give it a name, and a URL or a command.".into());
        }
        let mut list = self.mcp_entries();
        if list.iter().any(|e| prefix_of(&e.name) == prefix_of(name)) {
            return Err(format!("You already have a server called {name}."));
        }
        let mut e = McpEntry { id: format!("mcp-{}", util::random_hex(4)), name: name.to_string(), on: true, added: util::now(), ..Default::default() };
        if target.starts_with("https://") || target.starts_with("http://localhost") || target.starts_with("http://127.0.0.1") {
            e.url = Some(target.to_string());
        } else if target.starts_with("http://") {
            return Err("Use https for a server on the internet.".into());
        } else {
            let mut parts = split_command(target);
            if parts.is_empty() {
                return Err("That command is empty.".into());
            }
            e.command = Some(parts.remove(0));
            e.args = parts;
        }
        let token = token.map(str::trim).filter(|t| !t.is_empty()).map(str::to_string);
        if token.is_some() && e.url.is_none() {
            return Err("A token is for a URL; a command takes its keys from its own setup.".into());
        }
        let found = tokio::time::timeout(Duration::from_secs(30), e.server(token.clone())?.connect())
            .await
            .map_err(|_| "The server didn't answer within 30 seconds.".to_string())?
            .map_err(|err| format!("Couldn't connect: {}", crate::privacy::scrub(&err.to_string())))?;
        e.pin = Some(found.hash);
        e.tools = found.tools.iter().map(|t| t.spec().name.clone()).collect();
        if let Some(t) = &token {
            self.keys.set(&format!("mcp:{}", e.id), t)?;
            e.has_token = true;
        }
        cache().lock().unwrap().insert(e.id.clone(), (Instant::now(), found.tools));
        let view = e.view();
        list.push(e);
        self.save_mcps(&list)?;
        Ok(view)
    }

    pub fn mcp_remove(&self, id: &str) -> Result<Value, String> {
        let mut list = self.mcp_entries();
        let Some(i) = list.iter().position(|e| e.id == id) else { return Err("No such server.".into()) };
        let e = list.remove(i);
        if e.has_token {
            let _ = self.keys.remove(&format!("mcp:{}", e.id));
        }
        cache().lock().unwrap().remove(id);
        self.save_mcps(&list)?;
        Ok(self.mcps())
    }

    pub fn mcp_toggle(&self, id: &str, on: bool) -> Result<Value, String> {
        let mut list = self.mcp_entries();
        let e = list.iter_mut().find(|e| e.id == id).ok_or("No such server.")?;
        e.on = on;
        self.save_mcps(&list)?;
        Ok(self.mcps())
    }

    /// Its tools changed: look again and pin what it offers now.
    pub async fn mcp_recheck(&self, id: &str) -> Result<Value, String> {
        let mut list = self.mcp_entries();
        let e = list.iter_mut().find(|e| e.id == id).ok_or("No such server.")?;
        let token = if e.has_token { self.keys.get(&format!("mcp:{}", e.id)) } else { None };
        let mut unpinned = e.clone();
        unpinned.pin = None;
        let found = tokio::time::timeout(Duration::from_secs(30), unpinned.server(token)?.connect())
            .await
            .map_err(|_| "The server didn't answer within 30 seconds.".to_string())?
            .map_err(|err| format!("Couldn't connect: {}", crate::privacy::scrub(&err.to_string())))?;
        e.pin = Some(found.hash);
        e.tools = found.tools.iter().map(|t| t.spec().name.clone()).collect();
        cache().lock().unwrap().insert(e.id.clone(), (Instant::now(), found.tools));
        self.save_mcps(&list)?;
        Ok(self.mcps())
    }

    /// The tools of every server that's on, for a job. A server that's slow,
    /// down or changed is left out of this job and logged, never waited on.
    pub(crate) async fn mcp_tools(&self) -> Vec<Arc<dyn Tool>> {
        let mut out = Vec::new();
        for e in self.mcp_entries().into_iter().filter(|e| e.on) {
            let fresh = cache().lock().unwrap().get(&e.id).filter(|(at, _)| at.elapsed() < FRESH_FOR).map(|(_, t)| t.clone());
            if let Some(t) = fresh {
                out.extend(t);
                continue;
            }
            let token = if e.has_token { self.keys.get(&format!("mcp:{}", e.id)) } else { None };
            let Ok(server) = e.server(token) else { continue };
            match tokio::time::timeout(CONNECT_WAIT, server.connect()).await {
                Ok(Ok(found)) => {
                    cache().lock().unwrap().insert(e.id.clone(), (Instant::now(), found.tools.clone()));
                    out.extend(found.tools);
                }
                Ok(Err(err)) => tracing::warn!(server = %e.name, error = %crate::privacy::scrub(&err.to_string()), "mcp server left out of this job"),
                Err(_) => tracing::warn!(server = %e.name, "mcp server too slow; left out of this job"),
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_commands_are_read_the_way_people_type_them() {
        assert_eq!(prefix_of("My Notion!"), "my_notion");
        assert_eq!(prefix_of("  "), "mcp");
        assert_eq!(split_command(r#"npx -y "@scope/server name" --flag"#), vec!["npx", "-y", "@scope/server name", "--flag"]);
    }

    /// A two-tool Streamable HTTP MCP server on localhost.
    async fn fake_server() -> String {
        use axum::{routing::post, Json, Router};
        async fn answer(Json(m): Json<Value>) -> axum::response::Response {
            use axum::response::IntoResponse;
            let id = m["id"].clone();
            let result = match m["method"].as_str().unwrap_or_default() {
                "initialize" => json!({"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}),
                "tools/list" => json!({"tools": [
                    {"name": "lookup", "description": "Look a thing up", "inputSchema": {"type": "object"}, "annotations": {"readOnlyHint": true}},
                    {"name": "send", "description": "Send a thing", "inputSchema": {"type": "object"}}
                ]}),
                _ => return axum::http::StatusCode::ACCEPTED.into_response(),
            };
            Json(json!({"jsonrpc": "2.0", "id": id, "result": result})).into_response()
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, Router::new().route("/mcp", post(answer))).await.unwrap() });
        format!("http://127.0.0.1:{}/mcp", addr.port())
    }

    #[tokio::test]
    async fn a_server_is_checked_pinned_offered_and_removed() {
        let server = fake_server().await;
        let dir = std::env::temp_dir().join(format!("cookie-mcps-{}", util::random_hex(4)));
        let team = Team::open(&dir).unwrap();
        assert!(team.mcp_add("x", "http://example.com/mcp", None).await.is_err(), "plain http only on this Mac");
        let added = team.mcp_add("Fake", &server, None).await.unwrap();
        assert!(!added["tools"].as_array().unwrap().is_empty());
        assert!(team.mcp_add("fake", &server, None).await.is_err(), "one name once");
        let id = added["id"].as_str().unwrap().to_string();
        assert!(team.mcp_tools().await.iter().all(|t| t.spec().name.starts_with("fake__")));
        team.mcp_toggle(&id, false).unwrap();
        assert!(team.mcp_tools().await.is_empty(), "off means not offered");
        team.mcp_remove(&id).unwrap();
        assert!(team.mcps()["servers"].as_array().unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
