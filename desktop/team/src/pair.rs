//! Pairing this computer with Enkeon, from inside Cookie.
//!
//! The same browser sign-in the Enkeon CLI uses (`enkeon login`: RFC 8628's
//! device flow, adapted by the gateway): Cookie asks the gateway for a code,
//! opens the Console, and polls while the person approves. With the short-lived
//! account token it gets back it lists the person's memories (projects), picks
//! the one they chose (or their only one), and mints a **personal key** for
//! this computer — the same kind `enkeon connect` mints, acting as the person.
//!
//! - The key is kept in the Keychain (`enkeon:key`); the project, the gateway
//!   and the key's id in `enkeon.json`. The account token is never written down:
//!   it lives in memory for the minutes pairing takes.
//! - Every Enkeon use in Cookie reads the paired key first ([`enkeon`]), then
//!   `ENKEON_API_KEY`, then the CLI's sign-in, so a person who already used the
//!   CLI needs no pairing at all.
//! - Unpairing forgets the key here. The key itself stays valid until it is
//!   revoked in the Console (Keys); Cookie says so rather than claim otherwise.
//!
//! Paths and bodies are the gateway's, as the CLI calls them
//! (`packages/cli/src/api.mjs` in the cloud repo).

use std::sync::{Arc, LazyLock, Mutex, RwLock};
use std::time::Duration;

use cookie_harness::enkeon::Enkeon;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{util, Team};

pub const DEFAULT_GATEWAY: &str = "https://api.enkeon.com";
#[cfg_attr(test, allow(dead_code))]
const KEY_NAME: &str = "enkeon:key";

/// The paired key and its MCP address, read once at start and on every pair/unpair.
static PAIRED: LazyLock<RwLock<Option<(String, String)>>> = LazyLock::new(|| RwLock::new(None));

/// Enkeon for Cookie: the paired key, else `ENKEON_API_KEY`, else the CLI's sign-in.
pub fn enkeon() -> Option<Enkeon> {
    if let Some((key, url)) = PAIRED.read().ok().and_then(|g| g.clone()) {
        return Some(Enkeon::new(&key).url(&url));
    }
    Enkeon::from_env()
}

/// The gateway and key the stream and REST calls use: the paired ones, or the
/// CLI's. `None` when neither is there (only `ENKEON_API_KEY` without a gateway
/// counts as the default gateway).
pub fn gateway_and_key() -> Option<(String, String)> {
    if let Some((key, url)) = PAIRED.read().ok().and_then(|g| g.clone()) {
        return Some((url.trim_end_matches("/mcp").to_string(), key));
    }
    if let Ok(key) = std::env::var("ENKEON_API_KEY") {
        let key = key.trim().to_string();
        if !key.is_empty() {
            let url = std::env::var("ENKEON_URL").ok().map(|u| u.trim().trim_end_matches('/').trim_end_matches("/mcp").to_string()).filter(|u| !u.is_empty());
            return Some((url.unwrap_or_else(|| DEFAULT_GATEWAY.into()), key));
        }
    }
    let home = std::env::var("HOME").ok()?;
    let config: Value = serde_json::from_str(&std::fs::read_to_string(std::path::Path::new(&home).join(".thinkingroot/config.json")).ok()?).ok()?;
    let project = config["projectId"].as_str().or(config["project"].as_str())?;
    let key = config["projects"][project]["engineKey"].as_str().filter(|k| !k.is_empty())?;
    let gateway = config["gatewayUrl"].as_str().filter(|g| !g.is_empty()).unwrap_or(DEFAULT_GATEWAY);
    Some((gateway.trim_end_matches('/').to_string(), key.to_string()))
}

/// What is kept on disk about the pairing (never the key).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Paired {
    pub gateway: String,
    pub project: String,
    pub project_name: String,
    pub key_id: Option<String>,
    pub by: String,
    pub at: u64,
}

/// One pairing in progress.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Pairing {
    /// waiting · choose · done · failed · expired · denied
    pub state: String,
    pub user_code: String,
    pub url: String,
    pub expires_at: u64,
    /// When the person has more than one memory: the ones to choose from.
    pub projects: Vec<ProjectChoice>,
    pub error: Option<String>,
    #[serde(skip)]
    token: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectChoice {
    pub id: String,
    pub name: String,
}

static PAIRING: LazyLock<Mutex<Option<Pairing>>> = LazyLock::new(|| Mutex::new(None));

fn http() -> &'static reqwest::Client {
    static C: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    C.get_or_init(|| reqwest::Client::builder().timeout(Duration::from_secs(20)).user_agent(concat!("cookie-desktop/", env!("CARGO_PKG_VERSION"))).build().unwrap_or_default())
}

/// The gateway's `{ok, data}` envelope, unwrapped as the CLI does.
fn unwrap(v: Value) -> Value {
    match v {
        Value::Object(ref m) if m.contains_key("ok") && m.contains_key("data") => m["data"].clone(),
        v => v,
    }
}

pub(crate) async fn request(method: reqwest::Method, url: String, token: Option<&str>, body: Option<Value>) -> Result<Value, String> {
    let mut r = http().request(method, &url);
    if let Some(t) = token {
        r = r.bearer_auth(t);
    }
    if let Some(b) = body {
        r = r.json(&b);
    }
    let resp = r.send().await.map_err(|e| format!("Couldn't reach Enkeon: {e}"))?;
    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    let v: Value = serde_json::from_str(&text).unwrap_or(Value::String(text));
    if !status.is_success() {
        let msg = v.pointer("/error/message").or(v.get("error")).or(v.get("message")).and_then(Value::as_str).map(str::to_string);
        return Err(msg.unwrap_or_else(|| format!("Enkeon answered {status}.")));
    }
    Ok(unwrap(v))
}

fn gateway_ok(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("http://127.0.0.1") || url.starts_with("http://localhost")
}

impl Team {
    fn paired_path(&self) -> std::path::PathBuf {
        self.paths.root.join("enkeon.json")
    }

    fn paired_key(&self) -> Option<String> {
        #[cfg(test)]
        return std::fs::read_to_string(self.paths.root.join("test-enkeon-key")).ok();
        #[cfg(not(test))]
        self.keys.get(KEY_NAME)
    }

    fn store_paired_key(&self, key: Option<&str>) -> Result<(), String> {
        #[cfg(test)]
        {
            let f = self.paths.root.join("test-enkeon-key");
            return match key {
                Some(k) => std::fs::write(f, k).map_err(|e| e.to_string()),
                None => {
                    let _ = std::fs::remove_file(f);
                    Ok(())
                }
            };
        }
        #[cfg(not(test))]
        match key {
            Some(k) => self.keys.set(KEY_NAME, k),
            None => self.keys.remove(KEY_NAME),
        }
    }

    /// Read the pairing into the process (at start, and after it changes).
    pub fn load_pairing(&self) {
        let p: Option<Paired> = self.paired_path().exists().then(|| util::read_json(&self.paired_path()));
        let next = paired_from(p, self.paired_key());
        if let Ok(mut g) = PAIRED.write() {
            *g = next;
        }
    }

    /// Where Cookie's Enkeon comes from now.
    pub fn enkeon_status(&self) -> Value {
        let paired: Option<Paired> = self.paired_path().exists().then(|| util::read_json(&self.paired_path()));
        let is_paired = paired.is_some() && self.paired_key().is_some();
        let source = if is_paired {
            "paired"
        } else if std::env::var("ENKEON_API_KEY").map(|k| !k.trim().is_empty()).unwrap_or(false) {
            "env"
        } else if Enkeon::from_env().is_some() {
            "cli"
        } else {
            "none"
        };
        let pairing = PAIRING.lock().ok().and_then(|g| g.clone());
        json!({
            "connected": source != "none",
            "source": source,
            "paired": paired.filter(|_| is_paired),
            "pairing": pairing,
        })
    }

    /// Start pairing: a code to confirm in the browser. The caller opens `url`.
    pub async fn pair_start(self: &Arc<Self>, gateway: Option<String>) -> Result<Pairing, String> {
        let gateway = gateway.map(|g| g.trim().trim_end_matches('/').to_string()).filter(|g| !g.is_empty()).unwrap_or_else(|| DEFAULT_GATEWAY.into());
        if !gateway_ok(&gateway) {
            return Err("Enkeon's address must be https, so the key is never sent in the clear.".into());
        }
        let start = request(reqwest::Method::POST, format!("{gateway}/identity/auth/device/start"), None, Some(json!({}))).await?;
        let device_code = start["device_code"].as_str().ok_or("Enkeon didn't send a sign-in code.")?.to_string();
        let interval = start["interval"].as_u64().unwrap_or(5).max(2);
        let expires_in = start["expires_in"].as_u64().unwrap_or(900);
        let p = Pairing {
            state: "waiting".into(),
            user_code: start["user_code"].as_str().unwrap_or_default().to_string(),
            url: start["verification_uri_complete"].as_str().or(start["verification_uri"].as_str()).unwrap_or_default().to_string(),
            expires_at: util::now() + expires_in,
            ..Pairing::default()
        };
        *PAIRING.lock().unwrap() = Some(p.clone());
        let team = self.clone();
        tokio::spawn(async move {
            let outcome = team.pair_poll(&gateway, &device_code, interval, expires_in).await;
            if let Err(e) = outcome {
                set_pairing(|p| {
                    if p.state == "waiting" || p.state == "choose" {
                        p.state = "failed".into();
                        p.error = Some(e.clone());
                    }
                });
            }
        });
        Ok(p)
    }

    async fn pair_poll(self: &Arc<Self>, gateway: &str, device_code: &str, interval: u64, expires_in: u64) -> Result<(), String> {
        let deadline = util::now() + expires_in;
        let token = loop {
            if util::now() > deadline {
                set_pairing(|p| p.state = "expired".into());
                return Ok(());
            }
            tokio::time::sleep(Duration::from_secs(interval)).await;
            if PAIRING.lock().unwrap().is_none() {
                return Ok(()); // cancelled
            }
            let r = match request(reqwest::Method::POST, format!("{gateway}/identity/auth/device/poll"), None, Some(json!({"device_code": device_code}))).await {
                Ok(r) => r,
                Err(e) => {
                    tracing::info!(error = %e, "pairing: poll failed; trying again");
                    continue;
                }
            };
            match r["status"].as_str() {
                Some("approved") => break r["jwt"].as_str().ok_or("Enkeon approved but sent no sign-in.")?.to_string(),
                Some("expired") => {
                    set_pairing(|p| p.state = "expired".into());
                    return Ok(());
                }
                Some("denied") => {
                    set_pairing(|p| p.state = "denied".into());
                    return Ok(());
                }
                _ => {}
            }
        };
        let me = request(reqwest::Method::GET, format!("{gateway}/identity/me"), Some(&token), None).await?;
        let org = me["orgs"].as_array().and_then(|o| o.first()).and_then(|o| o["id"].as_str().or(o["org_id"].as_str()).or(o.pointer("/org/id").and_then(Value::as_str))).map(str::to_string);
        let Some(org) = org else {
            return Err("Your Enkeon account has no organisation yet. Open enkeon.com, create one, and pair again.".into());
        };
        let list = request(reqwest::Method::GET, format!("{gateway}/provisioner/api/v1/projects?org={org}"), Some(&token), None).await?;
        let projects: Vec<ProjectChoice> = list
            .as_array()
            .or(list.get("projects").and_then(Value::as_array))
            .into_iter()
            .flatten()
            .filter_map(|p| Some(ProjectChoice { id: p["id"].as_str()?.to_string(), name: p["name"].as_str().or(p["slug"].as_str()).unwrap_or("Memory").to_string() }))
            .collect();
        let by = me.pointer("/user/name").or(me.pointer("/user/email")).and_then(Value::as_str).unwrap_or_default().to_string();
        match projects.len() {
            0 => Err("You have no Enkeon memory yet. Create one at enkeon.com, then pair again.".into()),
            1 => self.pair_finish(gateway, &token, &projects[0], &by).await,
            _ => {
                set_pairing(|p| {
                    p.state = "choose".into();
                    p.projects = projects.clone();
                    p.token = Some(token.clone());
                });
                // Remember who, for when they choose.
                PAIRING_BY.lock().unwrap().replace((gateway.to_string(), by));
                Ok(())
            }
        }
    }

    /// The person picked which memory this computer pairs with.
    pub async fn pair_choose(self: &Arc<Self>, project: &str) -> Result<Value, String> {
        let (token, choice) = {
            let g = PAIRING.lock().unwrap();
            let p = g.as_ref().filter(|p| p.state == "choose").ok_or("There is no pairing waiting for a choice.")?;
            let choice = p.projects.iter().find(|c| c.id == project).cloned().ok_or("That memory isn't one of yours.")?;
            (p.token.clone().ok_or("The sign-in has ended; pair again.")?, choice)
        };
        let (gateway, by) = PAIRING_BY.lock().unwrap().clone().unwrap_or_else(|| (DEFAULT_GATEWAY.into(), String::new()));
        self.pair_finish(&gateway, &token, &choice, &by).await?;
        Ok(self.enkeon_status())
    }

    async fn pair_finish(self: &Arc<Self>, gateway: &str, token: &str, project: &ProjectChoice, by: &str) -> Result<(), String> {
        let host = std::process::Command::new("scutil").args(["--get", "ComputerName"]).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).filter(|h| !h.is_empty()).unwrap_or_else(|| "this computer".into());
        let name: String = format!("cookie-desktop-{host}").chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' }).take(60).collect();
        let res = request(reqwest::Method::POST, format!("{gateway}/v1/projects/{}/keys", project.id), Some(token), Some(json!({"name": name, "personal": true}))).await?;
        let plaintext = res["plaintext"].as_str().or(res.pointer("/key/plaintext").and_then(Value::as_str)).ok_or("Enkeon didn't send a key back.")?;
        let key_id = res["id"].as_str().or(res.pointer("/key/id").and_then(Value::as_str)).map(str::to_string);
        self.store_paired_key(Some(plaintext))?;
        // The account sign-in stays in memory a while, so apps can be connected straight away.
        crate::apps::remember_account(gateway, token);
        util::write_json(&self.paired_path(), &Paired { gateway: gateway.into(), project: project.id.clone(), project_name: project.name.clone(), key_id, by: by.into(), at: util::now() })?;
        self.load_pairing();
        set_pairing(|p| {
            p.state = "done".into();
            p.token = None;
            p.projects.clear();
        });
        *PAIRING_BY.lock().unwrap() = None;
        self.emit(crate::events::TeamEvent::EnkeonChanged);
        Ok(())
    }

    pub fn pair_cancel(&self) {
        *PAIRING.lock().unwrap() = None;
        *PAIRING_BY.lock().unwrap() = None;
    }

    /// Forget the pairing on this computer.
    pub fn unpair(&self) -> Result<Value, String> {
        let p: Paired = util::read_json(&self.paired_path());
        self.store_paired_key(None)?;
        let _ = std::fs::remove_file(self.paired_path());
        self.load_pairing();
        self.pair_cancel();
        self.emit(crate::events::TeamEvent::EnkeonChanged);
        Ok(json!({
            "note": format!("This computer no longer uses Enkeon's key. The key ({}) still works until you revoke it in the Enkeon Console under Keys.", p.key_id.unwrap_or_else(|| "cookie-desktop".into())),
            "status": self.enkeon_status(),
        }))
    }
}

/// The key and MCP address a pairing on disk gives, if it is whole.
fn paired_from(p: Option<Paired>, key: Option<String>) -> Option<(String, String)> {
    match (p, key) {
        (Some(p), Some(key)) if !p.gateway.is_empty() && !key.trim().is_empty() => Some((key.trim().to_string(), format!("{}/mcp", p.gateway.trim_end_matches('/')))),
        _ => None,
    }
}

static PAIRING_BY: LazyLock<Mutex<Option<(String, String)>>> = LazyLock::new(|| Mutex::new(None));

fn set_pairing(f: impl FnOnce(&mut Pairing)) {
    if let Some(p) = PAIRING.lock().unwrap().as_mut() {
        f(p);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_gateway_envelope_unwraps_like_the_cli() {
        assert_eq!(unwrap(json!({"ok": true, "data": {"a": 1}})), json!({"a": 1}));
        assert_eq!(unwrap(json!({"a": 1})), json!({"a": 1}));
    }

    #[test]
    fn a_key_never_goes_over_plain_http() {
        assert!(gateway_ok("https://api.enkeon.com") && gateway_ok("http://127.0.0.1:8080"));
        assert!(!gateway_ok("http://api.enkeon.com"));
    }

    #[test]
    fn a_paired_key_is_kept_and_forgotten_outside_the_keychain_in_tests() {
        let dir = tempfile::tempdir().unwrap();
        let t = Team::open(dir.path()).unwrap();
        t.store_paired_key(Some("tr_sk_test")).unwrap();
        util::write_json(&t.paired_path(), &Paired { gateway: "https://g.example".into(), project: "p".into(), ..Paired::default() }).unwrap();
        let on_disk: Paired = util::read_json(&t.paired_path());
        assert_eq!(paired_from(Some(on_disk), t.paired_key()), Some(("tr_sk_test".into(), "https://g.example/mcp".into())));
        assert_eq!(paired_from(Some(Paired::default()), Some("k".into())), None, "no gateway, no pairing");
        t.unpair().unwrap();
        assert!(t.paired_key().is_none() && !t.paired_path().exists());
    }
}
