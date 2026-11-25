//! The apps your agents work with — Gmail, Calendar, Slack, Drive, Notion… —
//! connected from inside Cookie, through Enkeon (which holds the accounts,
//! via Composio, and syncs them into your memory for every agent).
//!
//! The same lifecycle the Console uses (`connector_life.rs` in the cloud):
//! Cookie asks Enkeon to start a connect, opens the app's own sign-in in your
//! browser, and asks Enkeon to finish it every few seconds. Enkeon only
//! counts an app connected once the provider has confirmed the account; the
//! address the browser comes back to proves nothing, so Cookie never trusts it.
//!
//! These routes take your **account** sign-in, not the key this Mac keeps.
//! Signing in to pair keeps that sign-in in memory for [`ACCOUNT_SECS`] so
//! you can connect apps straight away; later, "Sign in to manage apps" runs
//! the same browser sign-in again without making another key. It is never
//! written to disk.

use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};

use crate::pair::{request, Paired, DEFAULT_GATEWAY};
use crate::{util, Team};

/// How long an account sign-in is used for managing apps.
pub const ACCOUNT_SECS: u64 = 50 * 60;
const WORKSPACE: &str = "main";
/// Where the provider returns the person: the Console finishes there too.
const RETURN_ORIGIN: &str = "https://www.enkeon.com";

/// The apps Cookie offers first: (Enkeon slug, Composio toolkit, name, what agents do with it).
pub const CATALOG: [(&str, &str, &str, &str); 12] = [
    ("gmail", "gmail", "Gmail", "Read, sort and draft mail"),
    ("google_calendar", "googlecalendar", "Google Calendar", "Know your day, plan meetings"),
    ("slack", "slack", "Slack", "Follow threads, catch what needs you"),
    ("google_drive", "googledrive", "Google Drive", "Read docs and files"),
    ("notion", "notion", "Notion", "Notes, wikis and plans"),
    ("github", "github", "GitHub", "Issues, PRs and code"),
    ("outlook", "outlook", "Outlook", "Microsoft mail and calendar"),
    ("linear", "linear", "Linear", "Issues and projects"),
    ("google_sheets", "googlesheets", "Google Sheets", "Read and update sheets"),
    ("hubspot", "hubspot", "HubSpot", "Contacts, deals and leads"),
    ("jira", "jira", "Jira", "Tickets and sprints"),
    ("zoom", "zoom", "Zoom", "Meetings and recordings"),
];

struct Account {
    gateway: String,
    token: String,
    at: u64,
}

static ACCOUNT: LazyLock<Mutex<Option<Account>>> = LazyLock::new(|| Mutex::new(None));

/// A sign-in for managing apps, in progress.
#[derive(Debug, Clone, Default, Serialize)]
pub struct SignIn {
    /// waiting · done · failed · expired · denied
    pub state: String,
    pub user_code: String,
    pub url: String,
    pub error: Option<String>,
}

static SIGNIN: LazyLock<Mutex<Option<SignIn>>> = LazyLock::new(|| Mutex::new(None));

/// Pairing hands its account sign-in over, so apps can be connected right after.
pub(crate) fn remember_account(gateway: &str, token: &str) {
    *ACCOUNT.lock().unwrap() = Some(Account { gateway: gateway.into(), token: token.into(), at: util::now() });
}

fn account() -> Option<(String, String)> {
    let g = ACCOUNT.lock().unwrap();
    g.as_ref().filter(|a| util::now() - a.at < ACCOUNT_SECS).map(|a| (a.gateway.clone(), a.token.clone()))
}

fn forget_account() {
    *ACCOUNT.lock().unwrap() = None;
}

fn toolkit_of(slug: &str) -> String {
    CATALOG.iter().find(|c| c.0 == slug).map(|c| c.1.to_string()).unwrap_or_else(|| slug.to_string())
}

fn valid_slug(s: &str) -> bool {
    !s.is_empty() && s.len() <= 64 && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
}

/// An app's state in words the person reads.
pub fn plain_state(state: &str) -> &'static str {
    match state {
        "connected" | "unverified" => "connected",
        "awaiting_signin" | "completing" => "connecting",
        "needs_reconnect" | "needs_signin" => "reconnect",
        "failed" => "failed",
        _ => "off",
    }
}

fn is_signed_out(err: &str) -> bool {
    let e = err.to_lowercase();
    e.contains("401") || e.contains("unauthor") || e.contains("expired") || e.contains("invalid token") || e.contains("jwt")
}

impl Team {
    fn paired(&self) -> Option<Paired> {
        let p = self.paths.root.join("enkeon.json");
        p.exists().then(|| util::read_json::<Paired>(&p)).filter(|p| !p.project.is_empty())
    }

    /// Every app Cookie offers, with its state in Enkeon (when signed in).
    pub async fn apps(&self) -> Result<Value, String> {
        let catalog: Vec<Value> = CATALOG.iter().map(|(slug, _, name, what)| json!({"slug": slug, "name": name, "what": what, "state": "off"})).collect();
        let signin = SIGNIN.lock().unwrap().clone();
        let Some(p) = self.paired() else {
            return Ok(json!({"paired": false, "signed_in": false, "apps": catalog, "signin": signin}));
        };
        let Some((gateway, token)) = account() else {
            return Ok(json!({"paired": true, "project_name": p.project_name, "signed_in": false, "apps": catalog, "signin": signin}));
        };
        let v = match request(reqwest::Method::GET, format!("{gateway}/v1/projects/{}/connectors?workspace={WORKSPACE}", p.project), Some(&token), None).await {
            Ok(v) => v,
            Err(e) if is_signed_out(&e) => {
                forget_account();
                return Ok(json!({"paired": true, "project_name": p.project_name, "signed_in": false, "apps": catalog, "signin": signin}));
            }
            Err(e) => return Err(e),
        };
        let live: Vec<Value> = v["apps"].as_array().cloned().unwrap_or_default();
        let find = |slug: &str| live.iter().find(|a| a["slug"] == slug).cloned();
        let mut apps: Vec<Value> = CATALOG
            .iter()
            .map(|(slug, _, name, what)| {
                let a = find(slug);
                let state = a.as_ref().and_then(|a| a["state"].as_str()).map(plain_state).unwrap_or("off");
                json!({
                    "slug": slug, "name": name, "what": what, "state": state,
                    "synced": a.as_ref().and_then(|a| a.pointer("/sync/synced_count")).cloned().unwrap_or(Value::Null),
                    "last_synced_at": a.as_ref().and_then(|a| a.pointer("/sync/last_synced_at")).cloned().unwrap_or(Value::Null),
                    "reason": a.as_ref().and_then(|a| a.pointer("/attempt/reason")).cloned().unwrap_or(Value::Null),
                })
            })
            .collect();
        // Apps connected in the Console that Cookie doesn't list first still show.
        for a in &live {
            let slug = a["slug"].as_str().unwrap_or_default();
            if !slug.is_empty() && !CATALOG.iter().any(|c| c.0 == slug) {
                let state = plain_state(a["state"].as_str().unwrap_or(""));
                if state != "off" {
                    apps.push(json!({"slug": slug, "name": slug.replace('_', " "), "what": "Connected in Enkeon", "state": state, "synced": a.pointer("/sync/synced_count").cloned().unwrap_or(Value::Null)}));
                }
            }
        }
        Ok(json!({"paired": true, "project_name": p.project_name, "signed_in": true, "apps": apps, "signin": signin}))
    }

    /// Sign in again in the browser, to manage apps (no new key is made).
    pub async fn apps_signin(self: &Arc<Self>) -> Result<SignIn, String> {
        let gateway = self.paired().map(|p| p.gateway).filter(|g| !g.is_empty()).unwrap_or_else(|| DEFAULT_GATEWAY.into());
        let start = request(reqwest::Method::POST, format!("{gateway}/identity/auth/device/start"), None, Some(json!({}))).await?;
        let device = start["device_code"].as_str().ok_or("Enkeon didn't send a sign-in code.")?.to_string();
        let interval = start["interval"].as_u64().unwrap_or(5).max(2);
        let expires_in = start["expires_in"].as_u64().unwrap_or(900);
        let s = SignIn {
            state: "waiting".into(),
            user_code: start["user_code"].as_str().unwrap_or_default().into(),
            url: start["verification_uri_complete"].as_str().or(start["verification_uri"].as_str()).unwrap_or_default().into(),
            error: None,
        };
        *SIGNIN.lock().unwrap() = Some(s.clone());
        let team = self.clone();
        tokio::spawn(async move {
            let deadline = util::now() + expires_in;
            let outcome = loop {
                if util::now() > deadline {
                    break "expired".to_string();
                }
                tokio::time::sleep(Duration::from_secs(interval)).await;
                if SIGNIN.lock().unwrap().is_none() {
                    return;
                }
                let Ok(r) = request(reqwest::Method::POST, format!("{gateway}/identity/auth/device/poll"), None, Some(json!({"device_code": device}))).await else { continue };
                match r["status"].as_str() {
                    Some("approved") => match r["jwt"].as_str() {
                        Some(jwt) => {
                            remember_account(&gateway, jwt);
                            break "done".into();
                        }
                        None => break "failed".into(),
                    },
                    Some("expired") => break "expired".into(),
                    Some("denied") => break "denied".into(),
                    _ => {}
                }
            };
            if let Some(s) = SIGNIN.lock().unwrap().as_mut() {
                s.state = outcome;
            }
            team.emit(crate::events::TeamEvent::EnkeonChanged);
        });
        Ok(s)
    }

    /// Start connecting an app: the sign-in address to open. Cookie finishes it.
    pub async fn app_connect(self: &Arc<Self>, slug: &str) -> Result<Value, String> {
        if !valid_slug(slug) {
            return Err("That isn't an app Enkeon knows.".into());
        }
        let p = self.paired().ok_or("Sign in with Enkeon first.")?;
        let (gateway, token) = account().ok_or("signin")?;
        let body = json!({"workspace": WORKSPACE, "toolkit": toolkit_of(slug), "return_origin": RETURN_ORIGIN});
        let v = request(reqwest::Method::POST, format!("{gateway}/v1/projects/{}/connectors/{slug}/connect", p.project), Some(&token), Some(body)).await.map_err(|e| {
            if is_signed_out(&e) {
                forget_account();
                "signin".to_string()
            } else {
                e
            }
        })?;
        let attempt = v["attempt"]["id"].as_str().map(str::to_string);
        let url = v["authorize_url"].as_str().map(str::to_string);
        if let (Some(id), Some(_)) = (&attempt, &url) {
            // Finish it from here: the Console's return page may never be open.
            let (team, id, project) = (self.clone(), id.clone(), p.project.clone());
            tokio::spawn(async move {
                let deadline = util::now() + 15 * 60;
                while util::now() < deadline {
                    tokio::time::sleep(Duration::from_millis(2500)).await;
                    let Some((gw, tk)) = account() else { return };
                    let Ok(r) = request(reqwest::Method::POST, format!("{gw}/v1/projects/{project}/connectors/attempts/{id}/complete"), Some(&tk), Some(json!({}))).await else { continue };
                    let state = r["state"].as_str().or(r.pointer("/attempt/state").and_then(Value::as_str)).unwrap_or("");
                    if state == "connected" || state == "failed" {
                        team.emit(crate::events::TeamEvent::EnkeonChanged);
                        return;
                    }
                }
            });
        }
        Ok(json!({"authorize_url": url, "state": v["attempt"]["state"], "reason": v["attempt"]["reason"]}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_app_has_a_toolkit_and_the_drive_family_maps_to_composio_names() {
        assert_eq!(toolkit_of("google_drive"), "googledrive");
        assert_eq!(toolkit_of("google_calendar"), "googlecalendar");
        assert_eq!(toolkit_of("gmail"), "gmail");
        assert_eq!(toolkit_of("something_new"), "something_new", "anything else is named by its toolkit already");
        assert!(CATALOG.iter().all(|c| valid_slug(c.0) && valid_slug(c.1)));
    }

    #[test]
    fn states_read_plainly() {
        assert_eq!(plain_state("connected"), "connected");
        assert_eq!(plain_state("unverified"), "connected");
        assert_eq!(plain_state("awaiting_signin"), "connecting");
        assert_eq!(plain_state("needs_reconnect"), "reconnect");
        assert_eq!(plain_state("whatever"), "off");
    }

    #[test]
    fn an_account_sign_in_is_used_for_a_while_then_forgotten() {
        remember_account("https://g.example", "jwt");
        assert_eq!(account().map(|a| a.1).as_deref(), Some("jwt"));
        ACCOUNT.lock().unwrap().as_mut().unwrap().at = util::now() - ACCOUNT_SECS - 1;
        assert!(account().is_none());
        forget_account();
    }
}
