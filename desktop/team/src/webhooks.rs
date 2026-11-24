//! WhatsApp and Microsoft Teams: channels that call Cookie, so they need a
//! public address (a cloud runner, or a home runner behind a tunnel).
//!
//! Each works like every other channel (`channels`): a chat is linked with a
//! one-time code Cookie shows, nothing from an unlinked chat reaches an agent,
//! and answers, approvals and questions come back to the linked chat.
//!
//! - **WhatsApp** (Meta's Cloud API): Meta checks the webhook once with the
//!   verify token Cookie shows; every message after that is signed with the
//!   app secret (`X-Hub-Signature-256`, HMAC-SHA256 over the body) and
//!   refused unsigned. A WhatsApp chat is always one person.
//! - **Teams** (Bot Framework): every activity carries a Bot Framework token
//!   (RS256) checked against Microsoft's published keys: its issuer, that it
//!   is for this app, that it hasn't expired, and that its service address is
//!   the activity's. Personal chats only. Answers go back with Cookie's own
//!   token from Microsoft, to the service address a verified activity named.
//!
//! Dark until connected in Settings, and only on a runner with a public address.
//! Ported from the super console (gateway `cookie/channels.rs`).

use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::{json, Value};

use crate::Team;

pub const KINDS: [&str; 2] = ["whatsapp", "teams"];
const GRAPH: &str = "https://graph.facebook.com/v21.0";

fn b64url(s: &str) -> Result<Vec<u8>, String> {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(s.trim_end_matches('=')).map_err(|e| e.to_string())
}

/// Constant-time equality for secrets.
pub fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/* ---------- WhatsApp ---------- */

/// `X-Hub-Signature-256: sha256=<hex>` over the raw body, with the app secret.
pub fn whatsapp_verified(app_secret: &str, header: &str, body: &[u8]) -> bool {
    let Some(hex) = header.strip_prefix("sha256=") else { return false };
    let Some(sig) = (0..hex.len()).step_by(2).map(|i| hex.get(i..i + 2).and_then(|h| u8::from_str_radix(h, 16).ok())).collect::<Option<Vec<u8>>>() else { return false };
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, app_secret.as_bytes());
    ring::hmac::verify(&key, body, &sig).is_ok()
}

/// The text messages in one webhook call: `(phone, text)`.
pub fn whatsapp_messages(v: &Value) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for entry in v["entry"].as_array().into_iter().flatten() {
        for change in entry["changes"].as_array().into_iter().flatten() {
            for m in change.pointer("/value/messages").and_then(Value::as_array).into_iter().flatten() {
                if let (Some(from), Some(text)) = (m["from"].as_str(), m.pointer("/text/body").and_then(Value::as_str)) {
                    out.push((from.to_string(), text.to_string()));
                }
            }
        }
    }
    out
}

/* ---------- Teams ---------- */

/// A personal-chat message: `(conversation, service_url, text)`.
pub fn teams_message(a: &Value) -> Option<(String, String, String)> {
    if a["type"] != "message" || a.pointer("/conversation/conversationType").and_then(Value::as_str) != Some("personal") {
        return None;
    }
    let text = a["text"].as_str()?.trim().to_string();
    let conversation = a.pointer("/conversation/id")?.as_str()?.to_string();
    let service = a["serviceUrl"].as_str()?.trim_end_matches('/').to_string();
    service.starts_with("https://").then_some((conversation, service, text))
}

/// Microsoft's signing keys, kept an hour; Cookie's own token, kept until shortly before it ends.
static TEAMS_KEYS: Mutex<Option<(Instant, Vec<Value>)>> = Mutex::new(None);
static TEAMS_TOKEN: Mutex<Option<(Instant, String)>> = Mutex::new(None);

async fn teams_keys(http: &reqwest::Client) -> Result<Vec<Value>, String> {
    if let Some((at, keys)) = TEAMS_KEYS.lock().unwrap().clone() {
        if at.elapsed() < Duration::from_secs(3600) {
            return Ok(keys);
        }
    }
    let meta: Value = http.get("https://login.botframework.com/v1/.well-known/openidconfiguration").timeout(Duration::from_secs(10)).send().await.map_err(|e| e.to_string())?.json().await.map_err(|e| e.to_string())?;
    let uri = meta["jwks_uri"].as_str().ok_or("no jwks_uri")?;
    let jwks: Value = http.get(uri).timeout(Duration::from_secs(10)).send().await.map_err(|e| e.to_string())?.json().await.map_err(|e| e.to_string())?;
    let keys = jwks["keys"].as_array().cloned().unwrap_or_default();
    *TEAMS_KEYS.lock().unwrap() = Some((Instant::now(), keys.clone()));
    Ok(keys)
}

/// Check a Bot Framework token against the given keys. Pure, for tests.
pub fn teams_token_ok(bearer: &str, keys: &[Value], app_id: &str, service_url: &str, now: u64) -> Result<(), String> {
    let mut parts = bearer.split('.');
    let (Some(h), Some(p), Some(s), None) = (parts.next(), parts.next(), parts.next(), parts.next()) else { return Err("not a token".into()) };
    let header: Value = serde_json::from_slice(&b64url(h)?).map_err(|e| e.to_string())?;
    if header["alg"] != "RS256" {
        return Err("not RS256".into());
    }
    let kid = header["kid"].as_str().ok_or("no kid")?;
    let key = keys.iter().find(|k| k["kid"] == kid).ok_or("unknown key")?;
    let n = b64url(key["n"].as_str().ok_or("no n")?)?;
    let e = b64url(key["e"].as_str().ok_or("no e")?)?;
    let signed = format!("{h}.{p}");
    ring::signature::RsaPublicKeyComponents { n: &n, e: &e }
        .verify(&ring::signature::RSA_PKCS1_2048_8192_SHA256, signed.as_bytes(), &b64url(s)?)
        .map_err(|_| "bad signature".to_string())?;
    let c: Value = serde_json::from_slice(&b64url(p)?).map_err(|e| e.to_string())?;
    if c["iss"] != "https://api.botframework.com" {
        return Err("wrong issuer".into());
    }
    let aud_ok = match &c["aud"] {
        Value::String(a) => a == app_id,
        Value::Array(a) => a.iter().any(|x| x == app_id),
        _ => false,
    };
    if !aud_ok {
        return Err("not for this app".into());
    }
    let leeway = 300;
    if c["exp"].as_u64().is_none_or(|exp| exp + leeway < now) || c["nbf"].as_u64().is_some_and(|nbf| nbf > now + leeway) {
        return Err("expired".into());
    }
    let said = c["serviceurl"].as_str().unwrap_or("").trim_end_matches('/');
    if said.is_empty() || said != service_url.trim_end_matches('/') {
        return Err("the token's service address is not the activity's".into());
    }
    Ok(())
}

impl Team {
    pub(crate) async fn teams_verified(&self, bearer: &str, service_url: &str) -> Result<(), String> {
        let app_id = self.channel_states().get("teams").and_then(|s| s.config["app_id"].as_str().map(str::to_string)).ok_or("Teams isn't connected")?;
        let keys = teams_keys(&self.chans.http).await?;
        teams_token_ok(bearer, &keys, &app_id, service_url, crate::util::now())
    }

    pub(crate) async fn teams_token(&self, app_id: &str, password: &str) -> Result<String, String> {
        if let Some((until, t)) = TEAMS_TOKEN.lock().unwrap().clone() {
            if Instant::now() < until {
                return Ok(t);
            }
        }
        let r: Value = self
            .chans
            .http
            .post("https://login.microsoftonline.com/botframework.com/oauth2/v2.0/token")
            .form(&[("grant_type", "client_credentials"), ("client_id", app_id), ("client_secret", password), ("scope", "https://api.botframework.com/.default")])
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .map_err(|e| e.to_string())?
            .json()
            .await
            .map_err(|e| e.to_string())?;
        let token = r["access_token"].as_str().ok_or_else(|| format!("Microsoft refused: {}", r["error_description"].as_str().unwrap_or("no token")))?.to_string();
        let secs = r["expires_in"].as_u64().unwrap_or(3600).saturating_sub(300);
        *TEAMS_TOKEN.lock().unwrap() = Some((Instant::now() + Duration::from_secs(secs), token.clone()));
        Ok(token)
    }

    /// WhatsApp: check the token can use the phone number.
    pub(crate) async fn whatsapp_check(&self, token: &str, phone_id: &str) -> Result<Value, String> {
        let r = self.chans.http.get(format!("{GRAPH}/{phone_id}?fields=display_phone_number,verified_name")).bearer_auth(token).timeout(Duration::from_secs(15)).send().await.map_err(|e| e.to_string())?;
        let ok = r.status().is_success();
        let v: Value = r.json().await.unwrap_or_default();
        if !ok {
            return Err(format!("Meta refused it: {}", v.pointer("/error/message").and_then(Value::as_str).unwrap_or("unknown error")));
        }
        Ok(v)
    }

    pub(crate) async fn whatsapp_send(&self, token: &str, phone_id: &str, to: &str, text: &str) -> Result<(), String> {
        let r = self
            .chans
            .http
            .post(format!("{GRAPH}/{phone_id}/messages"))
            .bearer_auth(token)
            .json(&json!({"messaging_product": "whatsapp", "to": to, "type": "text", "text": {"body": text}}))
            .timeout(Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if r.status().is_success() { Ok(()) } else { Err(format!("HTTP {}: {}", r.status(), crate::util::clip(&r.text().await.unwrap_or_default(), 200))) }
    }

    pub(crate) async fn teams_send(&self, app_id: &str, password: &str, service_url: &str, conversation: &str, text: &str) -> Result<(), String> {
        if !service_url.starts_with("https://") {
            return Err("no Teams service address for that chat".into());
        }
        let token = self.teams_token(app_id, password).await?;
        let r = self
            .chans
            .http
            .post(format!("{}/v3/conversations/{conversation}/activities", service_url.trim_end_matches('/')))
            .bearer_auth(token)
            .json(&json!({"type": "message", "text": text}))
            .timeout(Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if r.status().is_success() { Ok(()) } else { Err(format!("HTTP {}", r.status())) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whatsapp_messages_are_signed_with_the_app_secret() {
        let body = br#"{"entry":[{"changes":[{"value":{"messages":[{"from":"37120000000","text":{"body":"hi"}}]}}]}]}"#;
        let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, b"s3cret");
        let tag: String = ring::hmac::sign(&key, body).as_ref().iter().map(|b| format!("{b:02x}")).collect();
        assert!(whatsapp_verified("s3cret", &format!("sha256={tag}"), body));
        assert!(!whatsapp_verified("other", &format!("sha256={tag}"), body));
        assert!(!whatsapp_verified("s3cret", &tag, body), "the sha256= prefix is required");
        let v: Value = serde_json::from_slice(body).unwrap();
        assert_eq!(whatsapp_messages(&v), vec![("37120000000".into(), "hi".into())]);
    }

    #[test]
    fn teams_takes_only_personal_chats_and_refuses_bad_tokens() {
        let a = json!({"type": "message", "text": "hi", "serviceUrl": "https://smba.trafficmanager.net/emea/", "conversation": {"id": "a:1", "conversationType": "personal"}});
        assert_eq!(teams_message(&a), Some(("a:1".into(), "https://smba.trafficmanager.net/emea".into(), "hi".into())));
        let group = json!({"type": "message", "text": "hi", "serviceUrl": "https://x", "conversation": {"id": "g", "conversationType": "groupChat"}});
        assert!(teams_message(&group).is_none());
        assert!(teams_token_ok("a.b", &[], "app", "https://x", 0).is_err());
        let h = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(br#"{"alg":"none","kid":"k"}"#);
        assert_eq!(teams_token_ok(&format!("{h}.e30.x"), &[], "app", "https://x", 0).unwrap_err(), "not RS256", "alg none is refused");
    }
}
