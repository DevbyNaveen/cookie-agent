//! The gateway's meeting doors, blocking. Adapted from the desktop app's
//! `api.rs` (thinkingrootdbcloud/apps/desktop/src-tauri/src/api.rs:316-343
//! for reading an answer, :527-548 for the meeting calls). The token comes
//! from the caller and is only ever written into the Authorization header.

use serde_json::{json, Value};
use std::time::Duration;

pub const DEFAULT_BASE: &str = "https://api.thinkingroot.com";

/// Attempts per request, counting the first.
pub const MAX_ATTEMPTS: u32 = 5;

#[derive(Debug, Clone, PartialEq)]
pub enum ApiError {
    /// The gateway answered, and the answer was no. Carries its status.
    Http(u16, String),
    /// Never reached the gateway (DNS, refused, TLS): nothing was processed.
    Connect(String),
    /// Reached it, then lost the answer (timeout, reset mid-body).
    Net(String),
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ApiError::Http(s, m) => write!(f, "HTTP {s}: {m}"),
            ApiError::Connect(m) => write!(f, "could not reach the gateway: {m}"),
            ApiError::Net(m) => write!(f, "{m}"),
        }
    }
}

/// Worth another try: the network, or the gateway saying "later".
pub fn transient(e: &ApiError) -> bool {
    match e {
        ApiError::Connect(_) | ApiError::Net(_) => true,
        ApiError::Http(s, _) => *s == 408 || *s == 429 || *s >= 500,
    }
}

/// The wait before attempt `attempt + 1` (attempt counts from 0), or None
/// to give up: 1, 2, 4, 8 units, then stop. Non-transient errors never retry.
pub fn retry_after(attempt: u32, e: &ApiError, unit: Duration) -> Option<Duration> {
    if attempt + 1 >= MAX_ATTEMPTS || !transient(e) {
        return None;
    }
    Some(unit * (1u32 << attempt.min(3)))
}

/// An id that goes into a URL path: no slashes, no query, no surprises.
pub fn valid_id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 128 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

pub struct Api {
    base: String,
    /// Replaced while recording: Cookie hands over a renewed sign-in on stdin,
    /// since a meeting can outlast the hour an access token lives.
    token: std::sync::RwLock<String>,
    http: reqwest::blocking::Client,
    /// The backoff unit; one second in production, shorter in tests.
    pub unit: Duration,
}

impl Api {
    pub fn new(base: &str, token: &str) -> Result<Self, String> {
        let http = reqwest::blocking::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(120))
            .user_agent(concat!("cookie-recorder/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| format!("http client: {e}"))?;
        Ok(Self {
            base: base.trim_end_matches('/').to_string(),
            token: std::sync::RwLock::new(token.to_string()),
            http,
            unit: Duration::from_secs(1),
        })
    }

    pub fn set_token(&self, token: &str) {
        *self.token.write().unwrap() = token.to_string();
    }

    pub fn bearer(&self) -> String {
        self.token.read().unwrap().clone()
    }

    fn once(&self, method: reqwest::Method, path: &str, body: Option<Body>) -> Result<Value, ApiError> {
        let mut req = self.http.request(method, format!("{}{}", self.base, path)).bearer_auth(self.bearer());
        match body {
            Some(Body::Json(v)) => req = req.json(&v),
            Some(Body::Bytes(b)) => req = req.header("content-type", "application/octet-stream").body(b),
            None => {}
        }
        // `without_url` keeps the error text free of anything but the cause.
        let resp = req.send().map_err(|e| {
            let connect = e.is_connect();
            let m = e.without_url().to_string();
            if connect { ApiError::Connect(m) } else { ApiError::Net(m) }
        })?;
        read(resp)
    }

    /// Send with the retry policy. `retry_on` narrows which errors may be
    /// retried for a request that is not safe to repeat.
    fn send(&self, method: reqwest::Method, path: &str, body: Option<Body>, retry_on: fn(&ApiError) -> bool) -> Result<Value, ApiError> {
        let mut attempt = 0;
        loop {
            match self.once(method.clone(), path, body.clone()) {
                Ok(v) => return Ok(v),
                Err(e) => match retry_after(attempt, &e, self.unit).filter(|_| retry_on(&e)) {
                    Some(wait) => std::thread::sleep(wait),
                    None => return Err(e),
                },
            }
            attempt += 1;
        }
    }

    /// A start that is lost after the gateway made the row would leave an
    /// orphan meeting, so it is repeated only when the gateway cannot have
    /// acted: never connected, 429, or 503.
    pub fn start(&self, project: &str, title: &str, site: &str) -> Result<Value, ApiError> {
        let body = json!({ "branch": "", "site": site, "title": title });
        self.send(reqwest::Method::POST, &format!("/v1/projects/{project}/meetings"), Some(Body::Json(body)), |e| {
            matches!(e, ApiError::Connect(_) | ApiError::Http(429 | 503, _))
        })
    }

    /// One chunk. A retry of a chunk that landed while its answer was lost
    /// is refused with 409 "expected chunk seq+1": the caller treats that
    /// as landed (see `upload::landed`).
    pub fn chunk(&self, project: &str, id: &str, channel: &str, seq: u32, bytes: Vec<u8>) -> Result<Value, ApiError> {
        let path = format!("/v1/projects/{project}/meetings/{id}/chunk?channel={channel}&seq={seq}");
        self.send(reqwest::Method::POST, &path, Some(Body::Bytes(bytes)), transient)
    }

    /// Stop with the recorder's own clock. If an earlier attempt landed and
    /// its answer was lost, the repeat gets 409 ("meeting is transcribing");
    /// then the row itself is the answer.
    pub fn stop(&self, project: &str, id: &str, secs: u64) -> Result<Value, ApiError> {
        let body = if secs > 0 { json!({ "duration_secs": secs.min(i32::MAX as u64) }) } else { json!({}) };
        let path = format!("/v1/projects/{project}/meetings/{id}/stop");
        let mut attempt = 0;
        let mut retried = false;
        loop {
            match self.once(reqwest::Method::POST, &path, Some(Body::Json(body.clone()))) {
                Ok(v) => return Ok(v),
                Err(ApiError::Http(409, m)) if retried => {
                    return match self.get(project, id) {
                        Ok(row) if row.get("state").and_then(Value::as_str) != Some("recording") => Ok(row),
                        _ => Err(ApiError::Http(409, m)),
                    }
                }
                Err(e) => match retry_after(attempt, &e, self.unit) {
                    Some(wait) => std::thread::sleep(wait),
                    None => return Err(e),
                },
            }
            attempt += 1;
            retried = true;
        }
    }

    pub fn get(&self, project: &str, id: &str) -> Result<Value, ApiError> {
        self.send(reqwest::Method::GET, &format!("/v1/projects/{project}/meetings/{id}"), None, transient)
    }

    /// keep | discard. Repeating a decide is refused by the gateway's state
    /// check rather than applied twice, so transient errors may retry.
    pub fn decide(&self, project: &str, id: &str, action: &str) -> Result<Value, ApiError> {
        let body = json!({ "action": action, "names": {} });
        self.send(reqwest::Method::POST, &format!("/v1/projects/{project}/meetings/{id}/decide"), Some(Body::Json(body)), transient)
    }
}

#[derive(Clone)]
enum Body {
    Json(Value),
    Bytes(Vec<u8>),
}

/// The desktop app's reading of an answer: 2xx → JSON (empty = null),
/// anything else → the gateway's `error.message`.
fn read(resp: reqwest::blocking::Response) -> Result<Value, ApiError> {
    let status = resp.status().as_u16();
    let body = resp.text().map_err(|e| ApiError::Net(e.without_url().to_string()))?;
    if !(200..300).contains(&status) {
        let detail = serde_json::from_str::<Value>(&body)
            .ok()
            .and_then(|v| {
                v.pointer("/error/message")
                    .or_else(|| v.get("message"))
                    .or_else(|| v.get("error"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or_else(|| format!("HTTP {status}"));
        return Err(ApiError::Http(status, detail));
    }
    if body.trim().is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_str(&body).map_err(|e| ApiError::Net(format!("bad json from the gateway: {e}")))
}

/// A tiny HTTP/1.1 server on 127.0.0.1 for tests: answers each request
/// with the next canned (status, body) and records what it was sent.
#[cfg(test)]
pub mod mock {
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    #[derive(Debug, Clone)]
    pub struct Seen {
        pub method: String,
        pub target: String,
        pub headers: Vec<(String, String)>,
        pub body: Vec<u8>,
    }

    impl Seen {
        pub fn header(&self, name: &str) -> Option<&str> {
            self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
        }
        pub fn json(&self) -> serde_json::Value {
            serde_json::from_slice(&self.body).unwrap()
        }
    }

    pub struct Mock {
        pub base: String,
        pub seen: Arc<Mutex<Vec<Seen>>>,
    }

    pub fn serve(answers: Vec<(u16, String)>) -> Mock {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        std::thread::spawn(move || {
            for (status, answer) in answers {
                let Ok((stream, _)) = listener.accept() else { return };
                let mut r = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                r.read_line(&mut line).unwrap();
                let mut parts = line.split_whitespace();
                let (method, target) = (parts.next().unwrap_or("").to_string(), parts.next().unwrap_or("").to_string());
                let mut headers = Vec::new();
                loop {
                    let mut h = String::new();
                    r.read_line(&mut h).unwrap();
                    let h = h.trim_end();
                    if h.is_empty() {
                        break;
                    }
                    if let Some((k, v)) = h.split_once(':') {
                        headers.push((k.trim().to_string(), v.trim().to_string()));
                    }
                }
                let len = headers.iter().find(|(k, _)| k.eq_ignore_ascii_case("content-length")).and_then(|(_, v)| v.parse().ok()).unwrap_or(0);
                let mut body = vec![0u8; len];
                r.read_exact(&mut body).unwrap();
                log.lock().unwrap().push(Seen { method, target, headers, body });
                let mut w = stream;
                let _ = write!(w, "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{answer}", answer.len());
            }
        });
        Mock { base, seen }
    }
}

#[cfg(test)]
mod tests {
    use super::mock::serve;
    use super::*;

    fn api(base: &str) -> Api {
        let mut a = Api::new(base, "tok_secret").unwrap();
        a.unit = Duration::from_millis(1);
        a
    }

    #[test]
    fn the_retry_policy_backs_off_and_stops() {
        let u = Duration::from_secs(1);
        let net = ApiError::Net("reset".into());
        let waits: Vec<_> = (0..6).map(|a| retry_after(a, &net, u)).collect();
        assert_eq!(waits, vec![Some(u), Some(u * 2), Some(u * 4), Some(u * 8), None, None]);
        assert!(retry_after(0, &ApiError::Http(503, "".into()), u).is_some());
        assert!(retry_after(0, &ApiError::Http(429, "".into()), u).is_some());
        assert!(retry_after(0, &ApiError::Http(408, "".into()), u).is_some());
        for s in [400, 401, 403, 404, 409, 413] {
            assert_eq!(retry_after(0, &ApiError::Http(s, "".into()), u), None, "{s} is final");
        }
    }

    #[test]
    fn ids_in_paths_are_plain() {
        assert!(valid_id("proj_0a1b2c3d"));
        assert!(valid_id("01J9ZK-abc"));
        for bad in ["", "a/b", "a?b", "..", "a b", "a%2F"] {
            assert!(!valid_id(bad), "{bad}");
        }
    }

    #[test]
    fn start_posts_the_contract_with_the_bearer() {
        let m = serve(vec![(200, r#"{"id":"mt_1","state":"recording"}"#.into())]);
        let row = api(&m.base).start("p1", "Weekly sync", "zoom").unwrap();
        assert_eq!(row["id"], "mt_1");
        let s = m.seen.lock().unwrap()[0].clone();
        assert_eq!((s.method.as_str(), s.target.as_str()), ("POST", "/v1/projects/p1/meetings"));
        assert_eq!(s.header("authorization"), Some("Bearer tok_secret"));
        assert_eq!(s.json(), json!({"branch": "", "site": "zoom", "title": "Weekly sync"}));
    }

    #[test]
    fn a_chunk_is_raw_bytes_with_channel_and_seq_in_the_query() {
        let m = serve(vec![(200, r#"{"ok":true,"channel":"tab","seq":4}"#.into())]);
        api(&m.base).chunk("p1", "mt_1", "tab", 4, b"OggS-bytes".to_vec()).unwrap();
        let s = m.seen.lock().unwrap()[0].clone();
        assert_eq!(s.target, "/v1/projects/p1/meetings/mt_1/chunk?channel=tab&seq=4");
        assert_eq!(s.header("content-type"), Some("application/octet-stream"));
        assert_eq!(s.header("authorization"), Some("Bearer tok_secret"));
        assert_eq!(s.body, b"OggS-bytes");
    }

    #[test]
    fn a_chunk_retries_a_503_then_lands() {
        let m = serve(vec![(503, r#"{"error":{"code":"x","message":"warming"}}"#.into()), (200, "{}".into())]);
        api(&m.base).chunk("p1", "mt_1", "mic", 0, b"a".to_vec()).unwrap();
        let seen = m.seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert_eq!(seen[0].body, seen[1].body, "the same bytes again");
    }

    #[test]
    fn a_403_is_final_and_carries_the_gateways_message() {
        let m = serve(vec![(403, r#"{"error":{"code":"forbidden","message":"forbidden: not your recording"}}"#.into())]);
        let e = api(&m.base).chunk("p1", "mt_1", "mic", 0, b"a".to_vec()).unwrap_err();
        assert_eq!(e, ApiError::Http(403, "forbidden: not your recording".into()));
        assert_eq!(m.seen.lock().unwrap().len(), 1);
    }

    #[test]
    fn start_is_not_repeated_after_a_500() {
        let m = serve(vec![(500, "{}".into()), (200, r#"{"id":"dup"}"#.into())]);
        assert!(matches!(api(&m.base).start("p1", "t", "s"), Err(ApiError::Http(500, _))));
        assert_eq!(m.seen.lock().unwrap().len(), 1);
    }

    #[test]
    fn stop_sends_the_measured_duration() {
        let m = serve(vec![(200, r#"{"id":"mt_1","state":"transcribing"}"#.into())]);
        let row = api(&m.base).stop("p1", "mt_1", 75).unwrap();
        assert_eq!(row["state"], "transcribing");
        let s = m.seen.lock().unwrap()[0].clone();
        assert_eq!((s.method.as_str(), s.target.as_str()), ("POST", "/v1/projects/p1/meetings/mt_1/stop"));
        assert_eq!(s.json(), json!({"duration_secs": 75}));
    }

    #[test]
    fn a_stop_whose_answer_was_lost_reads_the_row() {
        let m = serve(vec![
            (502, "{}".into()),
            (409, r#"{"error":{"message":"conflict: meeting is transcribing"}}"#.into()),
            (200, r#"{"id":"mt_1","state":"transcribing"}"#.into()),
        ]);
        let row = api(&m.base).stop("p1", "mt_1", 10).unwrap();
        assert_eq!(row["state"], "transcribing");
        let seen = m.seen.lock().unwrap();
        assert_eq!(seen[2].method, "GET");
        assert_eq!(seen[2].target, "/v1/projects/p1/meetings/mt_1");
    }

    #[test]
    fn decide_and_get_hit_their_doors() {
        let m = serve(vec![(200, r#"{"state":"discarded"}"#.into()), (200, r#"{"state":"ready","summary":"s"}"#.into())]);
        let a = api(&m.base);
        assert_eq!(a.decide("p1", "mt_1", "discard").unwrap()["state"], "discarded");
        assert_eq!(a.get("p1", "mt_1").unwrap()["summary"], "s");
        let seen = m.seen.lock().unwrap();
        assert_eq!((seen[0].method.as_str(), seen[0].target.as_str()), ("POST", "/v1/projects/p1/meetings/mt_1/decide"));
        assert_eq!(seen[0].json(), json!({"action": "discard", "names": {}}));
        assert_eq!((seen[1].method.as_str(), seen[1].target.as_str()), ("GET", "/v1/projects/p1/meetings/mt_1"));
        assert!(seen.iter().all(|s| s.header("authorization") == Some("Bearer tok_secret")));
    }
}
