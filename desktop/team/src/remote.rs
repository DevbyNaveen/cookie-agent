//! The Mac app as a window onto a team that lives elsewhere: in the cloud,
//! beside its Parallax worlds, or on a home runner.
//!
//! Signed in to a remote team, the app sends every command there (`call`),
//! shows that team's live events (`follow`), and — when the person allows it —
//! lends this Mac to it as a hand (`hand::serve_as_hand`). Nothing needs
//! syncing: there is one team, and every surface (this app, a phone, Telegram,
//! WhatsApp) is a client of it. The app's own local team is opened only to
//! build the Mac's own tools, and never started.

use std::path::{Path, PathBuf};
use std::time::Duration;

use futures::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::keys::Keys;

/// Where the Mac app's remote team is, kept beside its data (the token in the Keychain).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Remote {
    /// The team's address, like `https://team.cookie.enkeon.com` or `http://192.168.1.20:4519`.
    pub url: String,
    /// The person lets the remote team use this Mac (its files, apps, Hands).
    #[serde(default)]
    pub hand: bool,
}

const TOKEN_KEY: &str = "remote-token";

fn path(dir: &Path) -> PathBuf {
    dir.join("remote.json")
}

/// The remote team this app is attached to, with its token, if any.
pub fn load(dir: &Path) -> Option<(Remote, String)> {
    let r: Remote = crate::util::read_json(&path(dir));
    if r.url.is_empty() {
        return None;
    }
    let token = Keys::new(dir).get(TOKEN_KEY)?;
    Some((r, token))
}

/// Attach to a remote team: checks the address and token answer first.
pub async fn attach(dir: &Path, url: &str, token: &str, hand: bool) -> Result<Value, String> {
    let url = url.trim().trim_end_matches('/').to_string();
    if !(url.starts_with("https://") || url.starts_with("http://127.0.0.1") || url.starts_with("http://localhost") || url.starts_with("http://192.168.") || url.starts_with("http://10.")) {
        return Err("Use the team's https:// address (plain http only on this computer or your own network).".into());
    }
    let remote = Remote { url: url.clone(), hand };
    let agents = call(&remote, token, "list_agents", json!({})).await.map_err(|e| format!("That team didn't answer: {e}"))?;
    Keys::new(dir).set(TOKEN_KEY, token)?;
    crate::util::write_json(&path(dir), &remote)?;
    Ok(json!({"url": url, "hand": hand, "agents": agents.as_array().map_or(0, Vec::len)}))
}

/// Back to the team on this Mac.
pub fn detach(dir: &Path) -> Result<(), String> {
    let _ = std::fs::remove_file(path(dir));
    Keys::new(dir).remove(TOKEN_KEY)
}

fn client() -> reqwest::Client {
    reqwest::Client::builder().connect_timeout(Duration::from_secs(10)).build().unwrap_or_default()
}

/// One command on the remote team, answered as the local team would answer it.
pub async fn call(remote: &Remote, token: &str, cmd: &str, args: Value) -> Result<Value, String> {
    let r = client()
        .post(format!("{}/api/{cmd}", remote.url))
        .bearer_auth(token)
        .timeout(Duration::from_secs(600))
        .json(&args)
        .send()
        .await
        .map_err(|e| format!("The team at {} is out of reach: {e}", remote.url))?;
    let status = r.status();
    let body: Value = r.json().await.unwrap_or_default();
    match (body.get("ok"), body["error"].as_str()) {
        (Some(v), _) if status.is_success() => Ok(v.clone()),
        (_, Some(e)) => Err(e.to_string()),
        _ => Err(format!("The team answered HTTP {status}.")),
    }
}

/// The remote team's live events, one JSON value each, until `stop`.
/// Reconnects by itself; `on_state` hears `connected` / `reconnecting`.
pub async fn follow(remote: Remote, token: String, stop: tokio_util::sync::CancellationToken, mut on: impl FnMut(Value) + Send, mut on_state: impl FnMut(&str) + Send) {
    let mut backoff = 1u64;
    while !stop.is_cancelled() {
        let url = format!("{}/events?token={}", remote.url, urlencode(&token));
        let resp = tokio::select! {
            r = client().get(url).send() => r,
            _ = stop.cancelled() => return,
        };
        match resp {
            Ok(r) if r.status().is_success() => {
                backoff = 1;
                on_state("connected");
                let mut stream = r.bytes_stream();
                let mut buf = String::new();
                loop {
                    let chunk = tokio::select! {
                        c = stream.next() => c,
                        _ = stop.cancelled() => return,
                    };
                    let Some(Ok(bytes)) = chunk else { break };
                    buf.push_str(&String::from_utf8_lossy(&bytes));
                    while let Some(end) = buf.find("\n\n") {
                        let frame: String = buf.drain(..end + 2).collect();
                        for line in frame.lines() {
                            if let Some(data) = line.strip_prefix("data:") {
                                if let Ok(v) = serde_json::from_str::<Value>(data.trim()) {
                                    on(v);
                                }
                            }
                        }
                    }
                }
            }
            _ => {}
        }
        on_state("reconnecting");
        tokio::time::sleep(Duration::from_secs(backoff)).await;
        backoff = (backoff * 2).min(30);
    }
}

fn urlencode(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_remote_team_is_called_and_followed_as_if_it_were_here() {
        // A real team behind the real server, on this machine.
        let dir = tempfile::tempdir().unwrap();
        let team = crate::Team::open(dir.path()).unwrap();
        let token = crate::server::token(&team, false).unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let app = crate::server::router(team.clone());
        tokio::spawn(async move { axum::serve(listener, app.into_make_service_with_connect_info::<std::net::SocketAddr>()).await.unwrap() });
        let remote = Remote { url: url.clone(), hand: false };
        let agents = call(&remote, &token, "list_agents", json!({})).await.unwrap();
        assert!(agents.is_array(), "{agents}");
        assert!(call(&remote, "wrong", "list_agents", json!({})).await.is_err(), "a wrong token is refused");
        // Its events arrive here.
        let stop = tokio_util::sync::CancellationToken::new();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let follower = tokio::spawn(follow(remote, token, stop.clone(), move |v| { let _ = tx.send(v); }, |_| {}));
        tokio::time::sleep(Duration::from_millis(300)).await;
        team.emit(crate::events::TeamEvent::Channel { name: "test".into(), status: "hello".into() });
        let got = tokio::time::timeout(Duration::from_secs(5), rx.recv()).await.expect("an event").unwrap();
        assert!(got.to_string().contains("hello"), "{got}");
        stop.cancel();
        let _ = follower.await;
    }

    #[test]
    fn only_a_safe_address_is_accepted() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let e = rt.block_on(attach(dir.path(), "http://team.example.com", "t", false)).unwrap_err();
        assert!(e.contains("https://"), "{e}");
    }
}
