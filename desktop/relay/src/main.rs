//! The Cookie Network relay.
//!
//! - Holds each person's signed profile. A handle belongs to the first key
//!   that signs a profile for it; only that key can update it.
//! - Carries sealed messages to mailboxes. It cannot read them: only the
//!   recipient's key opens them. A Cookie collects its mail by long-polling
//!   with a signed request, so it needs no public address of its own.
//! - Serves public pages: `/<handle>` (a person and their listed agents) and
//!   `/<handle>/<agent>` (one agent's card, with guest chat when its owner
//!   allows it). Guests seal their messages in the browser.
//!
//! cookie-relay [--dir DIR] [--bind 127.0.0.1] [--port 4700] [--trust-proxy]

use std::collections::{HashMap, VecDeque};
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::{ConnectInfo, Path, Query, State};
use axum::http::{header, HeaderMap, StatusCode, Uri};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post, put};
use axum::{Json, Router};
use cookie_net::{Sealed, SignedProfile};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::Notify;

/// Undelivered mail is dropped after a week.
const TTL: u64 = 7 * 86_400;
const MEMBER_BOX_CAP: usize = 1000;
const GUEST_BOX_CAP: usize = 200;
/// Sends per sender address per minute.
const SENDS_PER_MINUTE: u32 = 60;
const LONGEST_WAIT: u64 = 25;

const PAGE: &str = include_str!("page.html");
const FACE_JS: &str = include_str!("../../ui/face.js");
const MD_JS: &str = include_str!("../../ui/md.js");

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Item {
    seq: u64,
    at: u64,
    sealed: Sealed,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Mailbox {
    next: u64,
    items: VecDeque<Item>,
}

impl Mailbox {
    fn expire(&mut self, now: u64) -> bool {
        let before = self.items.len();
        self.items.retain(|i| now.saturating_sub(i.at) < TTL);
        before != self.items.len()
    }
}

struct Relay {
    dir: PathBuf,
    trust_proxy: bool,
    profiles: Mutex<HashMap<String, SignedProfile>>,
    boxes: Mutex<HashMap<String, Mailbox>>,
    bells: Mutex<HashMap<String, Arc<Notify>>>,
    rate: Mutex<HashMap<IpAddr, (u64, u32)>>,
}

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn is_guest_box(name: &str) -> bool {
    name.strip_prefix("guest-").is_some_and(|k| k.len() == 64 && k.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()))
}

fn err(code: StatusCode, msg: impl Into<String>) -> Response {
    (code, Json(json!({ "error": msg.into() }))).into_response()
}

fn write_atomic(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(tmp, path)
}

impl Relay {
    fn open(dir: PathBuf, trust_proxy: bool) -> std::io::Result<Self> {
        std::fs::create_dir_all(dir.join("boxes"))?;
        let profiles: HashMap<String, SignedProfile> = std::fs::read(dir.join("profiles.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let mut boxes = HashMap::new();
        for e in std::fs::read_dir(dir.join("boxes"))?.flatten() {
            let name = e.file_name().to_string_lossy().trim_end_matches(".json").to_string();
            if let Some(mb) = std::fs::read(e.path()).ok().and_then(|b| serde_json::from_slice::<Mailbox>(&b).ok()) {
                boxes.insert(name, mb);
            }
        }
        Ok(Relay { dir, trust_proxy, profiles: Mutex::new(profiles), boxes: Mutex::new(boxes), bells: Mutex::new(HashMap::new()), rate: Mutex::new(HashMap::new()) })
    }

    fn save_profiles(&self, p: &HashMap<String, SignedProfile>) {
        if let Ok(b) = serde_json::to_vec(p) {
            let _ = write_atomic(&self.dir.join("profiles.json"), &b);
        }
    }

    fn save_box(&self, name: &str, mb: &Mailbox) {
        let path = self.dir.join("boxes").join(format!("{name}.json"));
        if mb.items.is_empty() {
            // Keep the counter so sequence numbers never repeat for a reader holding a cursor.
            let _ = write_atomic(&path, &serde_json::to_vec(&Mailbox { next: mb.next, items: VecDeque::new() }).unwrap_or_default());
        } else if let Ok(b) = serde_json::to_vec(mb) {
            let _ = write_atomic(&path, &b);
        }
    }

    fn bell(&self, name: &str) -> Arc<Notify> {
        self.bells.lock().unwrap().entry(name.to_string()).or_insert_with(|| Arc::new(Notify::new())).clone()
    }

    fn client_ip(&self, peer: SocketAddr, headers: &HeaderMap) -> IpAddr {
        if self.trust_proxy {
            if let Some(ip) = headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()).and_then(|v| v.split(',').next()).and_then(|v| v.trim().parse().ok()) {
                return ip;
            }
        }
        peer.ip()
    }

    fn allow_send(&self, ip: IpAddr) -> bool {
        let minute = now() / 60;
        let mut rate = self.rate.lock().unwrap();
        if rate.len() > 50_000 {
            rate.retain(|_, (m, _)| *m == minute);
        }
        let e = rate.entry(ip).or_insert((minute, 0));
        if e.0 != minute {
            *e = (minute, 0);
        }
        e.1 += 1;
        e.1 <= SENDS_PER_MINUTE
    }

    /// Mail since `after`, waiting up to `wait` seconds for some to arrive.
    async fn collect(&self, name: &str, after: u64, wait: u64) -> Vec<Item> {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(wait.min(LONGEST_WAIT));
        loop {
            let bell = self.bell(name);
            let notified = bell.notified();
            {
                let mut boxes = self.boxes.lock().unwrap();
                if let Some(mb) = boxes.get_mut(name) {
                    mb.expire(now());
                    let items: Vec<Item> = mb.items.iter().filter(|i| i.seq > after).cloned().collect();
                    if !items.is_empty() {
                        return items;
                    }
                }
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                return Vec::new();
            }
        }
    }
}

type Shared = Arc<Relay>;

async fn put_profile(State(r): State<Shared>, Json(sp): Json<SignedProfile>) -> Response {
    if let Err(e) = sp.verify() {
        return err(StatusCode::BAD_REQUEST, e);
    }
    if sp.profile.at > now() + cookie_net::CLOCK_SKEW {
        return err(StatusCode::BAD_REQUEST, "The profile is dated in the future.");
    }
    let mut profiles = r.profiles.lock().unwrap();
    if let Some(old) = profiles.get(&sp.profile.handle) {
        if old.profile.sign != sp.profile.sign {
            return err(StatusCode::CONFLICT, format!("@{} is taken.", sp.profile.handle));
        }
        if sp.profile.at < old.profile.at {
            return err(StatusCode::CONFLICT, "A newer profile is already published.");
        }
    }
    let handle = sp.profile.handle.clone();
    profiles.insert(handle.clone(), sp);
    r.save_profiles(&profiles);
    Json(json!({ "ok": handle })).into_response()
}

async fn get_profile(State(r): State<Shared>, Path(handle): Path<String>) -> Response {
    match r.profiles.lock().unwrap().get(&handle.to_lowercase()) {
        Some(p) => Json(p.clone()).into_response(),
        None => err(StatusCode::NOT_FOUND, format!("Nobody is @{handle} on this relay.")),
    }
}

#[derive(Deserialize)]
struct DirQuery {
    #[serde(default)]
    q: String,
}

async fn directory(State(r): State<Shared>, Query(q): Query<DirQuery>) -> Response {
    let q = q.q.trim().to_lowercase();
    let profiles = r.profiles.lock().unwrap();
    let mut out = Vec::new();
    for sp in profiles.values() {
        for a in sp.profile.agents.iter().filter(|a| a.listed) {
            let hay = format!("{} {} {} {}", sp.profile.handle, sp.profile.name, a.name, a.job).to_lowercase();
            if q.is_empty() || q.split_whitespace().all(|w| hay.contains(w)) {
                out.push(json!({ "address": format!("@{}/{}", sp.profile.handle, a.slug), "person": sp.profile.name, "sign": sp.profile.sign, "card": a }));
            }
        }
    }
    out.sort_by(|a, b| b["card"]["record"]["jobs"].as_u64().cmp(&a["card"]["record"]["jobs"].as_u64()));
    out.truncate(50);
    Json(out).into_response()
}

#[derive(Deserialize)]
struct SendBody {
    to: String,
    sealed: Sealed,
}

async fn send(State(r): State<Shared>, ConnectInfo(peer): ConnectInfo<SocketAddr>, headers: HeaderMap, Json(b): Json<SendBody>) -> Response {
    if !r.allow_send(r.client_ip(peer, &headers)) {
        return err(StatusCode::TOO_MANY_REQUESTS, "Too many messages from here; wait a minute.");
    }
    let to = b.to.trim_start_matches('@').to_lowercase();
    let guest = is_guest_box(&to);
    if !guest && !r.profiles.lock().unwrap().contains_key(&to) {
        return err(StatusCode::NOT_FOUND, format!("Nobody is @{to} on this relay."));
    }
    if serde_json::to_vec(&b.sealed).map(|v| v.len()).unwrap_or(usize::MAX) > cookie_net::MAX_SEALED {
        return err(StatusCode::PAYLOAD_TOO_LARGE, "That message is too long.");
    }
    let t = now();
    let seq = {
        let mut boxes = r.boxes.lock().unwrap();
        let mb = boxes.entry(to.clone()).or_default();
        mb.expire(t);
        if mb.items.len() >= if guest { GUEST_BOX_CAP } else { MEMBER_BOX_CAP } {
            return err(StatusCode::INSUFFICIENT_STORAGE, "Their mailbox is full; try again later.");
        }
        mb.next += 1;
        let seq = mb.next;
        mb.items.push_back(Item { seq, at: t, sealed: b.sealed });
        r.save_box(&to, mb);
        seq
    };
    r.bell(&to).notify_waiters();
    Json(json!({ "ok": seq })).into_response()
}

#[derive(Deserialize)]
struct InboxQuery {
    #[serde(default)]
    after: u64,
    #[serde(default)]
    wait: u64,
}

fn authed(r: &Relay, headers: &HeaderMap, method: &str, uri: &Uri) -> Result<String, Response> {
    let h = headers.get("x-cookie-auth").and_then(|v| v.to_str().ok()).ok_or_else(|| err(StatusCode::UNAUTHORIZED, "Sign the request."))?;
    let pq = uri.path_and_query().map(|p| p.as_str()).unwrap_or("/");
    let profiles = r.profiles.lock().unwrap();
    cookie_net::check_auth(h, method, pq, now(), |handle| profiles.get(handle).map(|p| p.profile.sign.clone())).map_err(|e| err(StatusCode::UNAUTHORIZED, e))
}

async fn inbox(State(r): State<Shared>, headers: HeaderMap, uri: Uri, Query(q): Query<InboxQuery>) -> Response {
    let handle = match authed(&r, &headers, "GET", &uri) {
        Ok(h) => h,
        Err(e) => return e,
    };
    Json(json!({ "items": r.collect(&handle, q.after, q.wait).await })).into_response()
}

#[derive(Deserialize)]
struct AckQuery {
    upto: u64,
}

async fn ack(State(r): State<Shared>, headers: HeaderMap, uri: Uri, Query(q): Query<AckQuery>) -> Response {
    let handle = match authed(&r, &headers, "POST", &uri) {
        Ok(h) => h,
        Err(e) => return e,
    };
    let mut boxes = r.boxes.lock().unwrap();
    if let Some(mb) = boxes.get_mut(&handle) {
        mb.items.retain(|i| i.seq > q.upto);
        r.save_box(&handle, mb);
    }
    Json(json!({ "ok": q.upto })).into_response()
}

/// A guest's replies: sealed to the guest's own key, so anyone may fetch them.
async fn guest_box(State(r): State<Shared>, Path(key): Path<String>, Query(q): Query<InboxQuery>) -> Response {
    let name = format!("guest-{}", key.to_lowercase());
    if !is_guest_box(&name) {
        return err(StatusCode::BAD_REQUEST, "That isn't a guest key.");
    }
    Json(json!({ "items": r.collect(&name, q.after, q.wait).await })).into_response()
}

async fn page() -> Html<&'static str> {
    Html(PAGE)
}

fn script(body: &'static str) -> Response {
    ([(header::CONTENT_TYPE, "text/javascript; charset=utf-8"), (header::CACHE_CONTROL, "public, max-age=300")], body).into_response()
}

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let (mut dir, mut bind, mut port, mut trust_proxy) = (PathBuf::from("cookie-relay-data"), "127.0.0.1".to_string(), 4700u16, false);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--dir" => dir = args.next().map(PathBuf::from).unwrap_or(dir),
            "--bind" => bind = args.next().unwrap_or(bind),
            "--port" => port = args.next().and_then(|p| p.parse().ok()).unwrap_or(port),
            "--trust-proxy" => trust_proxy = true,
            "-h" | "--help" => {
                println!("cookie-relay [--dir DIR] [--bind 127.0.0.1] [--port 4700] [--trust-proxy]");
                return;
            }
            other => {
                eprintln!("unknown option {other}");
                std::process::exit(2);
            }
        }
    }
    let relay = Arc::new(Relay::open(dir.clone(), trust_proxy).unwrap_or_else(|e| {
        eprintln!("cookie-relay can't use {}: {e}", dir.display());
        std::process::exit(1)
    }));
    // Drop week-old mail even from mailboxes nobody reads.
    let sweeper = relay.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(3600)).await;
            let t = now();
            let mut boxes = sweeper.boxes.lock().unwrap();
            for (name, mb) in boxes.iter_mut() {
                if mb.expire(t) {
                    sweeper.save_box(name, mb);
                }
            }
        }
    });
    let app = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/face.js", get(|| async { script(FACE_JS) }))
        .route("/md.js", get(|| async { script(MD_JS) }))
        .route("/v1/profile", put(put_profile))
        .route("/v1/id/{handle}", get(get_profile))
        .route("/v1/directory", get(directory))
        .route("/v1/send", post(send))
        .route("/v1/inbox", get(inbox))
        .route("/v1/ack", post(ack))
        .route("/v1/guest/{key}", get(guest_box))
        .route("/", get(page))
        .route("/{handle}", get(page))
        .route("/{handle}/{agent}", get(page))
        .layer(axum::extract::DefaultBodyLimit::max(cookie_net::MAX_SEALED * 2))
        .with_state(relay);
    let addr = format!("{bind}:{port}");
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap_or_else(|e| {
        eprintln!("cookie-relay can't listen on {addr}: {e}");
        std::process::exit(1)
    });
    println!("Cookie relay on http://{addr} (data in {})", dir.display());
    let _ = axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await;
}
