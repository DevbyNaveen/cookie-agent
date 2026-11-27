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
//! Signing in once is enough: Enkeon's sign-in comes with a renewal token,
//! kept in the Keychain (`enkeon:refresh`), and Cookie trades it for a fresh
//! short sign-in whenever it manages apps. Enkeon replaces the token at each
//! use, and it ends when you sign out or unpair. Only if it has ended does
//! "Sign in to manage apps" ask for the browser again.
//!
//! **Every app Enkeon can connect** is offered, not a fixed dozen: the first
//! twelve are shown first, the rest are found by search (`more`). Databases
//! connect here too (`dbs`): read-only, checked before they are saved.

use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};

use crate::pair::{request, Paired, DEFAULT_GATEWAY};
use crate::{util, Team};

/// How long one short sign-in is used before it is renewed (Enkeon's lasts fifteen minutes).
pub const ACCOUNT_SECS: u64 = 10 * 60;
/// The renewal token's name in the Keychain.
const REFRESH_NAME: &str = "enkeon:refresh";
/// How long the list of every app is reused.
const CATALOG_SECS: u64 = 3600;
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

/// Apps whose Enkeon name differs from Composio's toolkit name (the Console's own table).
const SLUGS: [(&str, &str); 11] = [
    ("brave_search", "composio_search"),
    ("cal_com", "cal"),
    ("google_calendar", "googlecalendar"),
    ("google_drive", "googledrive"),
    ("google_meet", "googlemeet"),
    ("google_sheets", "googlesheets"),
    ("google_slides", "googleslides"),
    ("hacker_news", "hackernews"),
    ("onedrive", "one_drive"),
    ("sharepoint", "share_point"),
    ("zoho_crm", "zoho"),
];

/// Every app Enkeon can connect, as it last told us.
static ALL: LazyLock<Mutex<Option<(u64, Vec<Value>)>>> = LazyLock::new(|| Mutex::new(None));
/// One renewal at a time: Enkeon replaces the token at each use, and a second use of an old one signs the device out.
static RENEWING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

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
    CATALOG.iter().find(|c| c.0 == slug).map(|c| c.1).or_else(|| SLUGS.iter().find(|c| c.0 == slug).map(|c| c.1)).unwrap_or(slug).to_string()
}

/// `google_meet` → `Google Meet`: a readable name for an app Enkeon's list doesn't describe.
fn title_case(slug: &str) -> String {
    slug.split(['_', '-']).filter(|w| !w.is_empty()).map(|w| w[..1].to_uppercase() + &w[1..]).collect::<Vec<_>>().join(" ")
}

/// Enkeon's name for a Composio toolkit.
fn slug_of(toolkit: &str) -> String {
    SLUGS.iter().find(|c| c.1 == toolkit).map(|c| c.0).unwrap_or(toolkit).to_string()
}

/// One entry of Enkeon's list, as Cookie shows it. `None` for an app nobody can connect yet.
fn offered(t: &Value) -> Option<Value> {
    let toolkit = t["slug"].as_str().filter(|s| valid_slug(s))?;
    let auth = t["auth"].as_str().unwrap_or("");
    // `needs_our_app`: Enkeon has no sign-in registered with that provider yet.
    if !matches!(auth, "managed" | "user_key" | "none") {
        return None;
    }
    Some(json!({
        "slug": slug_of(toolkit),
        "name": t["name"].as_str().filter(|n| !n.is_empty()).unwrap_or(toolkit),
        "what": util::clip(t["description"].as_str().unwrap_or(""), 110),
        "category": t["categories"].as_array().and_then(|c| c.first()).and_then(Value::as_str).unwrap_or(""),
        "logo": t["logo"].as_str().unwrap_or(""),
        "needs_key": auth == "user_key",
        "tools": t["tools_count"],
        "state": "off",
    }))
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

    /// This month's Cookie credits, from Enkeon itself: with the person's fresh
    /// sign-in, else Cookie's own key. Never a number Enkeon didn't give.
    pub async fn enkeon_credits(&self) -> Value {
        let Some(p) = self.paired() else {
            return json!({"signed_in": false, "paired": false});
        };
        // Credits read with this computer's key; the renewal token is spent only on managing apps
        // (it is replaced at each use, so every needless use is a chance to lose it).
        let token = account().map(|a| a.1).or_else(|| self.paired_key());
        let Some(token) = token else {
            return json!({"signed_in": false, "paired": true});
        };
        let gateway = p.gateway.trim_end_matches('/').to_string();
        match request(reqwest::Method::GET, format!("{gateway}/v1/projects/{}/cookie", p.project), Some(&token), None).await {
            Ok(v) if v["credits"].is_object() => json!({
                "signed_in": true, "project": p.project_name,
                "allowance": v["credits"]["allowance"], "used": v["credits"]["used"], "saves": v["credits"]["saves"],
            }),
            Ok(_) => json!({"signed_in": true, "project": p.project_name, "available": false}),
            Err(e) => json!({"signed_in": false, "paired": true, "reason": crate::util::clip(&e, 200)}),
        }
    }

    /// Every app Cookie offers, with its state in Enkeon (when signed in).
    pub async fn apps(&self) -> Result<Value, String> {
        let catalog: Vec<Value> = CATALOG.iter().map(|(slug, _, name, what)| json!({"slug": slug, "name": name, "what": what, "state": "off"})).collect();
        let signin = SIGNIN.lock().unwrap().clone();
        let Some(p) = self.paired() else {
            return Ok(json!({"paired": false, "signed_in": false, "apps": catalog, "signin": signin}));
        };
        let Some((gateway, token)) = self.account_token().await else {
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
        // Every app Enkeon can connect: the names and pictures of the ones beyond the first twelve.
        let all = self.all_apps(&gateway, &token).await;
        // Apps connected in the Console that Cookie doesn't list first still show, under their real names.
        for a in &live {
            let slug = a["slug"].as_str().unwrap_or_default();
            if !slug.is_empty() && !CATALOG.iter().any(|c| c.0 == slug) {
                let state = plain_state(a["state"].as_str().unwrap_or(""));
                if state != "off" {
                    let known = all.iter().find(|k| k["slug"] == slug);
                    apps.push(json!({
                        "slug": slug,
                        "name": known.and_then(|k| k["name"].as_str()).map(str::to_string).unwrap_or_else(|| title_case(slug)),
                        "what": known.and_then(|k| k["what"].as_str()).filter(|w| !w.is_empty()).unwrap_or("Connected in Enkeon"),
                        "logo": known.map(|k| k["logo"].clone()).unwrap_or(Value::Null),
                        "state": state,
                        "synced": a.pointer("/sync/synced_count").cloned().unwrap_or(Value::Null),
                        "reason": a.pointer("/attempt/reason").cloned().unwrap_or(Value::Null),
                    }));
                }
            }
        }
        // Everything else Enkeon can connect, for the search: minus what is already listed.
        let shown: Vec<String> = apps.iter().filter_map(|a| a["slug"].as_str().map(str::to_string)).collect();
        let more: Vec<Value> = all.into_iter().filter(|a| !shown.iter().any(|s| a["slug"] == s.as_str())).collect();
        Ok(json!({"paired": true, "project_name": p.project_name, "signed_in": true, "apps": apps, "more": more, "signin": signin}))
    }

    /// Keep (or drop) the token that renews the account sign-in, in the Keychain.
    pub(crate) fn keep_renewal(&self, token: Option<&str>) {
        match token.filter(|t| !t.is_empty()) {
            Some(t) => match self.keys.set(REFRESH_NAME, t) {
                Ok(()) => self.signin_note("sign-in: Enkeon sent a renewal token; kept in the Keychain"),
                Err(e) => self.signin_note(&format!("sign-in: Enkeon sent a renewal token; the Keychain refused it: {e}")),
            },
            None => {
                let _ = self.keys.remove(REFRESH_NAME);
                self.signin_note("sign-in: no renewal token (Enkeon sent none, or this computer was unpaired)");
            }
        }
    }

    /// One line in `enkeon-signin.log`: what happened to the sign-in and when. Never a token or a key.
    fn signin_note(&self, what: &str) {
        use std::io::Write as _;
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(self.paths.root.join("enkeon-signin.log")) {
            let _ = writeln!(f, "{} {what}", chrono::Local::now().format("%Y-%m-%d %H:%M:%S"));
        }
    }

    /// The account sign-in to manage apps with: the one in memory while it is
    /// fresh, else a new one from the renewal token. `None`: sign in again.
    async fn account_token(&self) -> Option<(String, String)> {
        if let Some(a) = account() {
            return Some(a);
        }
        let _one = RENEWING.lock().await;
        if let Some(a) = account() {
            return Some(a);
        }
        let gateway = self.paired()?.gateway.trim_end_matches('/').to_string();
        let Some(renewal) = self.keys.get(REFRESH_NAME).filter(|t| !t.is_empty()) else {
            self.signin_note("renew: no renewal token in the Keychain");
            return None;
        };
        match request(reqwest::Method::POST, format!("{gateway}/identity/auth/refresh"), None, Some(json!({"refresh_token": renewal}))).await {
            Ok(v) => {
                // The next token is kept before anything else: an answer we can't use must not cost the sign-in.
                let next = v["refresh_token"].as_str().filter(|t| !t.is_empty());
                if let Some(next) = next {
                    let _ = self.keys.set(REFRESH_NAME, next);
                }
                let Some(jwt) = v["jwt"].as_str().filter(|j| !j.is_empty()).map(str::to_string) else {
                    self.signin_note("renew: Enkeon answered without a sign-in");
                    return None;
                };
                self.signin_note(if next.is_some() { "renew: ok, next token kept" } else { "renew: ok, Enkeon sent no next token" });
                remember_account(&gateway, &jwt);
                Some((gateway, jwt))
            }
            // Ended or revoked: it is no use any more. Any other failure (offline) keeps it.
            Err(e) if is_signed_out(&e) => {
                let _ = self.keys.remove(REFRESH_NAME);
                self.signin_note(&format!("renew: Enkeon refused the token, so it was dropped: {}", util::clip(&e, 160)));
                None
            }
            Err(e) => {
                self.signin_note(&format!("renew: couldn't ask Enkeon, token kept: {}", util::clip(&e, 160)));
                None
            }
        }
    }

    /// Every app Enkeon can connect now, from Enkeon (reused for an hour). Empty when it can't be read.
    async fn all_apps(&self, gateway: &str, token: &str) -> Vec<Value> {
        if let Some((at, list)) = ALL.lock().unwrap().as_ref() {
            if util::now() - at < CATALOG_SECS {
                return list.clone();
            }
        }
        let Ok(v) = request(reqwest::Method::GET, format!("{gateway}/v1/connectors/catalog"), Some(token), None).await else { return Vec::new() };
        let mut list: Vec<Value> = v.as_array().into_iter().flatten().filter_map(offered).collect();
        list.sort_by(|a, b| a["name"].as_str().unwrap_or("").to_lowercase().cmp(&b["name"].as_str().unwrap_or("").to_lowercase()));
        if !list.is_empty() {
            *ALL.lock().unwrap() = Some((util::now(), list.clone()));
        }
        list
    }

    /// Disconnect an app everywhere: agents can't call it, it stops feeding memory,
    /// what it synced is forgotten, and the provider's grant is revoked.
    pub async fn app_disconnect(&self, slug: &str) -> Result<(), String> {
        if !valid_slug(slug) {
            return Err("That isn't an app Enkeon knows.".into());
        }
        let p = self.paired().ok_or("Sign in with Enkeon first.")?;
        let (gateway, token) = self.account_token().await.ok_or("signin")?;
        request(reqwest::Method::DELETE, format!("{gateway}/v1/projects/{}/connectors/{slug}?workspace={WORKSPACE}", p.project), Some(&token), None).await.map_err(|e| if is_signed_out(&e) { "signin".to_string() } else { e })?;
        self.emit(crate::events::TeamEvent::EnkeonChanged);
        Ok(())
    }

    /// The databases agents may read (never write): each was tested before it was saved.
    pub async fn dbs(&self) -> Result<Value, String> {
        let Some(p) = self.paired() else { return Ok(json!({"signed_in": false, "list": []})) };
        let Some((gateway, token)) = self.account_token().await else { return Ok(json!({"signed_in": false, "list": []})) };
        let v = request(reqwest::Method::GET, format!("{gateway}/v1/projects/{}/db-connections", p.project), Some(&token), None).await?;
        let list = v.as_array().cloned().or_else(|| v["connections"].as_array().cloned()).unwrap_or_default();
        Ok(json!({"signed_in": true, "list": list}))
    }

    /// Connect a database by its address. Enkeon tests it first and refuses one it can't read safely.
    pub async fn db_add(&self, label: &str, dsn: &str) -> Result<Value, String> {
        let (label, dsn) = (label.trim(), dsn.trim());
        if label.is_empty() || dsn.is_empty() {
            return Err("Give it a name and its connection address.".into());
        }
        let p = self.paired().ok_or("Sign in with Enkeon first.")?;
        let (gateway, token) = self.account_token().await.ok_or("signin")?;
        request(reqwest::Method::POST, format!("{gateway}/v1/projects/{}/db-connections", p.project), Some(&token), Some(json!({"label": label, "dsn": dsn}))).await
    }

    pub async fn db_remove(&self, id: &str) -> Result<(), String> {
        if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
            return Err("That isn't one of your databases.".into());
        }
        let p = self.paired().ok_or("Sign in with Enkeon first.")?;
        let (gateway, token) = self.account_token().await.ok_or("signin")?;
        request(reqwest::Method::DELETE, format!("{gateway}/v1/projects/{}/db-connections/{id}", p.project), Some(&token), None).await.map(|_| ())
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
                            team.keep_renewal(r["refresh_token"].as_str());
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
        let (gateway, token) = self.account_token().await.ok_or("signin")?;
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
                    let Some((gw, tk)) = team.account_token().await else { return };
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
    fn every_app_enkeon_offers_is_listed_under_enkeons_name() {
        assert_eq!(toolkit_of("onedrive"), "one_drive");
        assert_eq!(slug_of("one_drive"), "onedrive");
        assert_eq!(slug_of("shopify"), "shopify");
        assert_eq!(title_case("trello"), "Trello");
        assert_eq!(title_case("google_meet"), "Google Meet");
        let a = offered(&json!({"slug": "googleslides", "name": "Google Slides", "description": "Decks", "categories": ["Productivity"], "auth": "managed", "tools_count": 9, "logo": "https://x/l.png"})).unwrap();
        assert_eq!((a["slug"].as_str(), a["needs_key"].as_bool()), (Some("google_slides"), Some(false)));
        assert_eq!(offered(&json!({"slug": "shopify", "name": "Shopify", "auth": "user_key"})).unwrap()["needs_key"], true);
        // No sign-in registered with the provider yet: not offered, never a dead button.
        assert!(offered(&json!({"slug": "tiktok", "name": "TikTok", "auth": "needs_our_app"})).is_none());
        assert!(offered(&json!({"slug": "Bad Slug", "auth": "managed"})).is_none());
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
