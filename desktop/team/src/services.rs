//! Services the person connects by hand: a broker's API, a machine on their
//! network (a 3D printer, Home Assistant, a CNC controller), a phone line.
//!
//! The person gives each one a name, its address and its key, once (the key
//! goes to the Keychain, or the sealed key file on a server, never into
//! Cookie's folder). Agents then reach it only at that address:
//!
//! - `service_read` (GET) reads: positions, quotes, a printer's status. It is
//!   a read, but the address is fixed by the person and only the path is the
//!   agent's, so nothing can be carried to anywhere else.
//! - `service_act` (POST, PUT, PATCH, DELETE) changes something in the world:
//!   an order, a print job, a light, a call. Every one asks the person, with
//!   the exact request in front of them, whatever trust was earned, and no
//!   mandate can ever cover it. A DELETE counts as something that can't be
//!   undone.
//! - `phone_call` places a call through Twilio: it says it is an AI calling
//!   for the person before anything else, and the number must come from the
//!   person's own words.
//!
//! A machine that moves in the real world needs a stop outside Cookie: Cookie
//! never says it is one.

use std::sync::Arc;
use std::time::Duration;

use cookie_harness::tool::{tool, Effect, Tool};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{util, Team};

pub const ACT_TOOL: &str = "service_act";
pub const CALL_TOOL: &str = "phone_call";
const MOST_BODY: usize = 64 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Service {
    pub name: String,
    /// `broker`, `machine`, `phone` (Twilio) or `api`.
    pub kind: String,
    /// Where it is: `https://api.kite.trade`, `http://192.168.1.40` (only on the person's own network).
    pub base_url: String,
    /// How the key is sent: `bearer`, `basic` (the key is `user:password`), or a header name.
    pub auth: String,
    pub added_at: u64,
}

fn key_name(name: &str) -> String {
    format!("service:{name}")
}

/// An address agents may be sent to: https anywhere, or plain http only on this computer or a private network.
fn safe_base(url: &str) -> Result<url::Url, String> {
    let u = url::Url::parse(url.trim()).map_err(|_| "That isn't a web address.".to_string())?;
    let host = u.host_str().unwrap_or_default().to_string();
    let private = host == "localhost"
        || host.ends_with(".local")
        || host.parse::<std::net::IpAddr>().is_ok_and(|ip| match ip {
            std::net::IpAddr::V4(v4) => v4.is_private() || v4.is_loopback(),
            std::net::IpAddr::V6(v6) => v6.is_loopback(),
        });
    match u.scheme() {
        "https" => Ok(u),
        "http" if private => Ok(u),
        _ => Err("Use an https:// address (plain http only for a machine on your own network).".into()),
    }
}

/// The full address of `path` under the service, refusing anything that would leave it.
pub(crate) fn address(base: &str, path: &str) -> Result<String, String> {
    let path = path.trim();
    if !path.starts_with('/') || path.contains("://") || path.contains("..") || path.starts_with("//") || path.contains('@') || path.contains('\\') {
        return Err("Give a path on the service, starting with /, like /portfolio/positions.".into());
    }
    let base = safe_base(base)?;
    Ok(format!("{}{}", base.as_str().trim_end_matches('/'), path))
}

impl Team {
    fn services_path(&self) -> std::path::PathBuf {
        self.paths.root.join("services.json")
    }

    pub fn services(&self) -> Vec<Service> {
        util::read_json(&self.services_path())
    }

    /// The person connects a service (its key goes to the key store).
    pub fn add_service(&self, name: &str, kind: &str, base_url: &str, auth: &str, secret: &str) -> Result<Service, String> {
        let name = name.trim().to_lowercase();
        if name.is_empty() || name.len() > 40 || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
            return Err("Name it with letters, numbers, - or _.".into());
        }
        if !matches!(kind, "broker" | "machine" | "phone" | "api") {
            return Err("A service is a broker, a machine, a phone line or an api.".into());
        }
        safe_base(base_url)?;
        let auth = auth.trim();
        if auth.is_empty() || auth.contains(char::is_whitespace) {
            return Err("Say how the key is sent: bearer, basic, or a header name.".into());
        }
        if secret.trim().is_empty() {
            return Err("Give its key.".into());
        }
        self.keys.set(&key_name(&name), secret)?;
        let s = Service { name: name.clone(), kind: kind.into(), base_url: base_url.trim().trim_end_matches('/').into(), auth: auth.into(), added_at: util::now() };
        let mut all = self.services();
        all.retain(|x| x.name != name);
        all.push(s.clone());
        util::write_json(&self.services_path(), &all)?;
        Ok(s)
    }

    pub fn remove_service(&self, name: &str) -> Result<(), String> {
        let mut all = self.services();
        all.retain(|x| x.name != name);
        let _ = self.keys.remove(&key_name(name));
        util::write_json(&self.services_path(), &all)
    }

    async fn service_request(&self, name: &str, method: &str, path: &str, body: Option<&Value>, form: Option<&[(String, String)]>) -> Result<String, String> {
        let s = self.services().into_iter().find(|x| x.name == name).ok_or_else(|| format!("No service named `{name}` is connected."))?;
        let url = address(&s.base_url, path)?;
        let secret = self.keys.get(&key_name(&s.name)).ok_or("Its key is missing; connect it again.")?;
        let http = reqwest::Client::builder().redirect(reqwest::redirect::Policy::none()).timeout(Duration::from_secs(60)).build().map_err(|e| e.to_string())?;
        let method = reqwest::Method::from_bytes(method.as_bytes()).map_err(|_| "That isn't an HTTP method.")?;
        let mut req = http.request(method, &url);
        req = match s.auth.as_str() {
            "bearer" => req.bearer_auth(&secret),
            "basic" => {
                let (u, p) = secret.split_once(':').unwrap_or((secret.as_str(), ""));
                req.basic_auth(u, Some(p))
            }
            header => req.header(header, &secret),
        };
        if let Some(b) = body {
            req = req.json(b);
        }
        if let Some(f) = form {
            req = req.form(f);
        }
        let r = req.send().await.map_err(|e| format!("{name} is out of reach: {e}"))?;
        let status = r.status();
        let text = r.text().await.unwrap_or_default();
        let text = cookie_harness::redact::secrets(&text).into_owned();
        if status.is_success() {
            Ok(util::clip(&text, 30_000))
        } else {
            Err(format!("{name} answered HTTP {}: {}", status.as_u16(), util::clip(&text, 2000)))
        }
    }
}

/// The service tools, when the person has connected any.
pub(crate) fn tools(team: &Arc<Team>) -> Vec<Arc<dyn Tool>> {
    let all = team.services();
    if all.is_empty() {
        return Vec::new();
    }
    let names: Vec<Value> = all.iter().filter(|s| s.kind != "phone").map(|s| json!(s.name)).collect();
    let listing = all.iter().map(|s| format!("{} ({}, {})", s.name, s.kind, s.base_url)).collect::<Vec<_>>().join("; ");
    let mut out: Vec<Arc<dyn Tool>> = Vec::new();
    if !names.is_empty() {
        let w = Arc::downgrade(team);
        out.push(Arc::new(
            tool(
                "service_read",
                &format!("Read from a service the person connected (GET): {listing}. Only its own address; you give the path (and query)."),
                json!({"type": "object", "properties": {"service": {"type": "string", "enum": names}, "path": {"type": "string", "description": "like /portfolio/positions?limit=20"}}, "required": ["service", "path"]}),
                Effect::Read,
                move |args: Value| {
                    let w = w.clone();
                    async move {
                        let team = w.upgrade().ok_or("Cookie is closing.")?;
                        team.service_request(args["service"].as_str().unwrap_or(""), "GET", args["path"].as_str().unwrap_or(""), None, None).await
                    }
                },
            )
            .parallel_safe(),
        ));
        let w = Arc::downgrade(team);
        let services = all.clone();
        let act = tool(
            ACT_TOOL,
            &format!(
                "Do something through a service the person connected (POST, PUT, PATCH or DELETE): place an order, start a print, switch a device. \
                 Every one asks the person with the exact request, every time. Never place a trade or move a machine they didn't ask for. {listing}"
            ),
            json!({"type": "object", "properties": {
                "service": {"type": "string", "enum": names},
                "method": {"type": "string", "enum": ["POST", "PUT", "PATCH", "DELETE"]},
                "path": {"type": "string"},
                "body": {"type": "object"}
            }, "required": ["service", "method", "path"]}),
            Effect::Outbound,
            move |args: Value| {
                let w = w.clone();
                async move {
                    let team = w.upgrade().ok_or("Cookie is closing.")?;
                    let body = args.get("body").filter(|b| b.is_object());
                    if body.is_some_and(|b| b.to_string().len() > MOST_BODY) {
                        return Err("That request is too large.".into());
                    }
                    team.service_request(args["service"].as_str().unwrap_or(""), args["method"].as_str().unwrap_or("POST"), args["path"].as_str().unwrap_or(""), body, None).await
                }
            },
        )
        .with_preview(move |args| {
            let name = args["service"].as_str().unwrap_or("?");
            let kind = services.iter().find(|s| s.name == name).map(|s| s.kind.as_str()).unwrap_or("api");
            let warn = match kind {
                "broker" => "\nThis moves money. Check the instrument, side, quantity and price.",
                "machine" => "\nThis moves a machine in the real world. Make sure it is safe to.",
                _ => "",
            };
            format!(
                "{} {} on {name}{}\n{}{warn}",
                args["method"].as_str().unwrap_or("POST"),
                args["path"].as_str().unwrap_or(""),
                if args["method"] == "DELETE" { " (can't be undone)" } else { "" },
                util::clip(&args.get("body").map(|b| serde_json::to_string_pretty(b).unwrap_or_default()).unwrap_or_default(), 1500)
            )
        });
        out.push(Arc::new(act));
    }
    if let Some(phone) = all.iter().find(|s| s.kind == "phone") {
        let (w, line) = (Arc::downgrade(team), phone.clone());
        let call = tool(
            CALL_TOOL,
            "Call a phone number and say a message (through the person's Twilio line). The call opens by saying it is an AI assistant \
             calling for the person. The number must be one the person gave you. Asks the person first, every time.",
            json!({"type": "object", "properties": {
                "to": {"type": "string", "description": "the number, with country code, like +447700900123"},
                "from": {"type": "string", "description": "the person's Twilio number to call from"},
                "message": {"type": "string", "description": "what to say"},
                "for_whom": {"type": "string", "description": "the person's name, as the call should say it"}
            }, "required": ["to", "from", "message", "for_whom"]}),
            Effect::Outbound,
            move |args: Value| {
                let (w, line) = (w.clone(), line.clone());
                async move {
                    let team = w.upgrade().ok_or("Cookie is closing.")?;
                    let number = |k: &str| -> Result<String, String> {
                        let n: String = args[k].as_str().unwrap_or("").chars().filter(|c| c.is_ascii_digit() || *c == '+').collect();
                        if n.starts_with('+') && (8..=16).contains(&n.len()) { Ok(n) } else { Err(format!("`{k}` must be a number with its country code, like +447700900123.")) }
                    };
                    let (to, from) = (number("to")?, number("from")?);
                    let message = args["message"].as_str().unwrap_or("").trim();
                    if message.is_empty() {
                        return Err("Say what the call says.".into());
                    }
                    let twiml = twiml(args["for_whom"].as_str().unwrap_or("the person"), message);
                    let account = team.keys.get(&key_name(&line.name)).and_then(|k| k.split_once(':').map(|(u, _)| u.to_string())).ok_or("The phone line's key must be AccountSID:AuthToken.")?;
                    let form = vec![("To".to_string(), to), ("From".to_string(), from), ("Twiml".to_string(), twiml)];
                    team.service_request(&line.name, "POST", &format!("/2010-04-01/Accounts/{account}/Calls.json"), None, Some(&form)).await
                }
            },
        )
        .with_preview(|args| format!("Call {} and say (after saying it is an AI calling for {}):\n{}", args["to"].as_str().unwrap_or("?"), args["for_whom"].as_str().unwrap_or("you"), util::clip(args["message"].as_str().unwrap_or(""), 1500)))
        .guard("to");
        out.push(Arc::new(call));
    }
    out
}

/// What the call says: who it is first, then the message, as plain speech.
fn twiml(for_whom: &str, message: &str) -> String {
    let esc = |s: &str| s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;");
    format!("<Response><Say>Hello. This is an AI assistant calling for {}.</Say><Pause length=\"1\"/><Say>{}</Say></Response>", esc(&util::clip(for_whom, 80)), esc(&util::clip(message, 1500)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_service_is_reached_only_at_its_own_address() {
        assert_eq!(address("https://api.kite.trade", "/portfolio/positions").unwrap(), "https://api.kite.trade/portfolio/positions");
        assert_eq!(address("http://192.168.1.40", "/api/printer").unwrap(), "http://192.168.1.40/api/printer");
        for bad in ["portfolio", "//evil.example/x", "/x/../../y", "/a?u=http://evil", "/@evil.example"] {
            assert!(address("https://api.kite.trade", bad).is_err(), "{bad}");
        }
        assert!(address("http://api.example.com", "/x").is_err(), "plain http only on the person's own network");
    }

    #[test]
    fn a_call_says_it_is_an_ai_first_and_carries_no_markup_from_the_message() {
        let t = twiml("Naveen", "Your table is booked. <Hangup/>");
        assert!(t.starts_with("<Response><Say>Hello. This is an AI assistant calling for Naveen."));
        assert!(t.contains("&lt;Hangup/&gt;") && !t.contains("<Hangup/>"));
    }

    #[tokio::test]
    async fn a_read_and_an_action_reach_the_service_with_its_key() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let s2 = seen.clone();
        tokio::spawn(async move {
            for _ in 0..2 {
                let (mut sock, _) = listener.accept().await.unwrap();
                let mut buf = vec![0u8; 8192];
                let n = sock.read(&mut buf).await.unwrap();
                s2.lock().unwrap().push(String::from_utf8_lossy(&buf[..n]).to_string());
                let body = "{\"status\":\"printing\"}";
                sock.write_all(format!("HTTP/1.1 200 OK\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
            }
        });
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        let name = format!("cookie-test-{}", util::random_hex(4));
        team.add_service(&name, "machine", &base, "bearer", "printer-key").unwrap();
        let read = team.service_request(&name, "GET", "/api/job", None, None).await;
        let act = team.service_request(&name, "POST", "/api/job", Some(&json!({"command": "start"})), None).await;
        team.remove_service(&name).unwrap();
        assert_eq!(read.unwrap(), "{\"status\":\"printing\"}");
        assert!(act.is_ok());
        let seen = seen.lock().unwrap();
        assert!(seen[0].starts_with("GET /api/job") && seen[0].to_lowercase().contains("authorization: bearer printer-key"), "{}", seen[0]);
        assert!(seen[1].starts_with("POST /api/job") && seen[1].contains("\"command\":\"start\""), "{}", seen[1]);
        assert!(team.keys.get(&key_name(&name)).is_none(), "its key is gone with it");
    }

    #[test]
    fn connecting_checks_what_it_is_given() {
        let dir = tempfile::tempdir().unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let team = rt.block_on(async { Team::open(dir.path()).unwrap() });
        assert!(team.add_service("kite", "broker", "http://api.kite.trade", "bearer", "k").is_err());
        assert!(team.add_service("kite", "casino", "https://api.kite.trade", "bearer", "k").is_err());
        assert!(team.add_service("bad name", "api", "https://x.example", "bearer", "k").is_err());
    }
}
