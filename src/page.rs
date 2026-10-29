//! `cookie page`: Cookie's page on your own machine.
//!
//! The page in `web/` is the one Enkeon's teams use. It asks a server for an
//! overview, starts jobs, follows a working job live and stops one; in Enkeon
//! the gateway answers. Here Cookie answers the same requests itself, at the
//! same paths, for one person and one folder, and serves the built page from
//! the same address, so the page and its answers share one origin.
//!
//! Jobs run exactly as `cookie local` runs them: the folder read only, the web
//! through the person's search key, pages read over https. Each job is kept as
//! one JSON file, each conversation as one session file, all under `home`.
//! A page address Cookie found in what it read waits for a yes on the page's
//! approval card, as it does in Enkeon.
//!
//! A routine ("every Tuesday at 17:00, clean up my inbox") is kept here too and
//! starts its job on this computer's own clock, as Enkeon starts one on the
//! person's: at most once per time it is due, and not at all when Cookie was
//! off for more than twelve hours past it.
//!
//! It listens on 127.0.0.1 only. A request whose `Host` is not this machine
//! (DNS rebinding) or whose `Origin` is not the page (another site in the same
//! browser) is refused before anything else is read.

use std::{
    collections::HashMap,
    convert::Infallible,
    hash::{BuildHasher, Hasher},
    path::{Component, Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use async_trait::async_trait;
use bytes::Bytes;
use http_body_util::{combinators::UnsyncBoxBody, BodyExt, Full, Limited, StreamBody};
use hyper::{
    body::{Frame, Incoming},
    header, Method, Request, Response, StatusCode,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::{oneshot, watch};

use crate::{
    agent::{Agent, Event, RunControl},
    approval::{ApprovalRequest, Approver},
    local,
    message::Message,
    policy::Policy,
    session::Session,
    tool::{Tool, ToolContext, ToolSpec},
    CancellationToken, Error,
};

/// The one project and person a local page has.
pub const PROJECT: &str = "local";
const ORG_SLUG: &str = "me";
const PROJECT_SLUG: &str = "local";
const MEMBER: &str = "me";
/// Where the page opens.
pub const PAGE_PATH: &str = "/me/local/cookie";
/// Jobs the overview lists, newest first.
const RECENT: usize = 50;
/// A request body larger than this is refused (a job's words, a SOUL).
const BODY_LIMIT: usize = 256 * 1024;
/// A SOUL longer than this is cut, as Enkeon cuts it.
const SOUL_CHARS: usize = 2_000;
/// How long a stream ticket opens a stream, and how long an approval waits.
const TICKET_TTL: Duration = Duration::from_secs(60);
const APPROVAL_TTL: Duration = Duration::from_secs(600);
/// How often due routines are looked for.
const ROUTINE_TICK: Duration = Duration::from_secs(30);
/// A run missed while Cookie was off still runs once if it is no later than
/// this; an older one is skipped (Enkeon's rule).
const ROUTINE_LATE_SECS: i64 = 12 * 3_600;
/// As many routines as the board lists; one more would run where nobody could pause it.
const MOST_ROUTINES: usize = 20;
/// A routine's job, as long as a job may be.
const JOB_CHARS: usize = 4_000;
/// A comment line on an open stream, so nothing between closes it as idle.
const KEEP_ALIVE: Duration = Duration::from_secs(15);
/// At most this often a stream sends a frame (about twenty a second).
const FRAME_EVERY: Duration = Duration::from_millis(50);

pub struct PageOptions {
    /// The folder Cookie reads (read only).
    pub root: PathBuf,
    pub model: String,
    /// Ask before reading a page address that came from what Cookie read.
    pub ask: bool,
    /// Where jobs, conversations and the SOUL are kept.
    pub home: PathBuf,
    pub port: u16,
    /// The built page (`web/out`), served at `/`; `None` serves the answers only
    /// (for `npm run dev`, which proxies to them).
    pub page_dir: Option<PathBuf>,
    /// Origins allowed besides this address itself (the dev server's).
    pub origins: Vec<String>,
}

/// One job, in the shape the page reads (`CookieRun`).
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Run {
    id: String,
    trigger: String,
    subject: String,
    status: String,
    delivery: Option<String>,
    credits: u32,
    steps: Vec<Value>,
    answer: Option<String>,
    started_at: String,
    finished_at: Option<String>,
    conversation: Option<String>,
    member_id: Option<String>,
    mine: bool,
    block: Option<String>,
    /// Where the job's action log ends (`runs/<id>.trace.jsonl`): `{head, count, key}`.
    #[serde(default)]
    trace: Option<Value>,
}

/// A working job: what the stream sends, and how to stop it.
struct Live {
    state: Mutex<LiveState>,
    changed: watch::Sender<u64>,
    cancel: CancellationToken,
}

#[derive(Default)]
struct LiveState {
    text: String,
    steps: Vec<Value>,
    done: bool,
}

impl Live {
    fn update(&self, f: impl FnOnce(&mut LiveState)) {
        f(&mut self.state.lock().expect("live lock"));
        self.changed.send_modify(|v| *v += 1);
    }
}

/// Something Cookie does on a cadence, in the shape the page reads
/// (`CookieRoutine`): `weekday` 1 = Monday … 7 = Sunday, the hour and minute
/// on this computer's clock.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Routine {
    id: String,
    job: String,
    /// `daily` | `weekly` | `hourly`.
    cadence: String,
    weekday: i16,
    hour: i16,
    minute: i16,
    seen: u32,
    /// `active` | `paused` (made here, never offered).
    state: String,
    last_run_at: Option<String>,
    created_at: String,
    /// When it last became active, and the due time it last ran for (seconds
    /// since 1970): a routine never runs for a time before it was on.
    #[serde(default)]
    since: i64,
    #[serde(default)]
    fired: i64,
}

struct Pending {
    view: Value,
    answer: oneshot::Sender<bool>,
}

struct State {
    opts: PageOptions,
    /// Every job, loaded from `home/runs` at start.
    runs: Mutex<HashMap<String, Run>>,
    live: Mutex<HashMap<String, Arc<Live>>>,
    approvals: Mutex<HashMap<String, Pending>>,
    tickets: Mutex<HashMap<String, (String, Instant)>>,
    routines: Mutex<Vec<Routine>>,
    origins: Vec<String>,
    hosts: Vec<String>,
}

type Body = UnsyncBoxBody<Bytes, Infallible>;

/// Serve the page and its answers until the process ends.
pub async fn serve(opts: PageOptions) -> Result<(), String> {
    for dir in ["runs", "conversations"] {
        std::fs::create_dir_all(opts.home.join(dir)).map_err(|e| format!("{}: {e}", opts.home.join(dir).display()))?;
    }
    let runs = load_runs(&opts.home.join("runs"));
    let routines: Vec<Routine> = std::fs::read(opts.home.join("routines.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    let port = opts.port;
    let hosts = vec![format!("127.0.0.1:{port}"), format!("localhost:{port}"), format!("[::1]:{port}")];
    let mut origins: Vec<String> = hosts.iter().map(|h| format!("http://{h}")).collect();
    origins.extend(opts.origins.iter().cloned());
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port)).await.map_err(|e| format!("127.0.0.1:{port}: {e}"))?;
    let state = Arc::new(State {
        opts,
        runs: Mutex::new(runs),
        live: Mutex::new(HashMap::new()),
        approvals: Mutex::new(HashMap::new()),
        tickets: Mutex::new(HashMap::new()),
        routines: Mutex::new(routines),
        origins,
        hosts,
    });
    tokio::spawn(fire_routines(state.clone()));
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(accepted) => accepted,
            Err(e) => {
                tracing::warn!("cookie page: accept failed: {e}");
                continue;
            }
        };
        let state = state.clone();
        tokio::spawn(async move {
            let service = hyper::service::service_fn(move |req| {
                let state = state.clone();
                async move { Ok::<_, Infallible>(handle(state, req).await) }
            });
            let _ = hyper::server::conn::http1::Builder::new()
                .serve_connection(hyper_util::rt::TokioIo::new(stream), service)
                .await;
        });
    }
}

fn load_runs(dir: &Path) -> HashMap<String, Run> {
    let mut runs = HashMap::new();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let Ok(text) = std::fs::read_to_string(entry.path()) else { continue };
        let Ok(mut run) = serde_json::from_str::<Run>(&text) else { continue };
        // A job still running when Cookie last stopped did not finish.
        if run.status == "running" {
            run.status = "failed".into();
            run.delivery = Some("failed".into());
            run.finished_at = run.finished_at.or_else(|| Some(utc_iso(SystemTime::now())));
        }
        runs.insert(run.id.clone(), run);
    }
    runs
}

async fn handle(state: Arc<State>, req: Request<Incoming>) -> Response<Body> {
    // Only this machine, and only the page: checked before anything is read.
    let host = req.headers().get(header::HOST).and_then(|h| h.to_str().ok()).unwrap_or_default().to_ascii_lowercase();
    if !state.hosts.contains(&host) {
        return error(StatusCode::FORBIDDEN, "forbidden", "Cookie answers only on this computer.");
    }
    let origin = req.headers().get(header::ORIGIN).and_then(|h| h.to_str().ok()).map(str::to_string);
    if let Some(o) = &origin {
        if !state.origins.contains(o) {
            return error(StatusCode::FORBIDDEN, "forbidden", "Cookie answers only its own page.");
        }
    }
    let cors = origin.as_deref();
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let query = req.uri().query().unwrap_or_default().to_string();
    if method == Method::OPTIONS {
        return with_cors(Response::builder().status(StatusCode::NO_CONTENT).body(empty()).expect("response"), cors);
    }
    // The page asks through `/api/gw/*` and `/api/cookie/*` (Enkeon's paths);
    // the dev server strips `/api/gw` before proxying, the built page does not.
    let api = path.strip_prefix("/api/gw").unwrap_or(&path).to_string();
    let response = match (method.clone(), api.as_str()) {
        (Method::GET, "/api/cookie/who") => ok(json!({"signed_in": true, "session": null})),
        (Method::POST, "/api/cookie/logout") => ok(json!({"ok": true})),
        (Method::GET, "/identity/me") => ok(json!({
            "user": {"id": MEMBER, "email": "", "display_name": "You"},
            "orgs": [{"id": ORG_SLUG, "slug": ORG_SLUG, "name": "You"}],
        })),
        (Method::GET, "/provisioner/api/v1/projects") => ok(json!([{
            "id": PROJECT, "org_id": ORG_SLUG, "slug": PROJECT_SLUG, "name": team_name(&state.opts.root),
            "workspace_name": "main", "status": "active",
        }])),
        (Method::POST, "/v1/stream-tickets") => match body_json(req).await {
            Ok(body) => mint_ticket(&state, &body),
            Err(e) => e,
        },
        _ if api.starts_with(&format!("/v1/projects/{PROJECT}/cookie")) => {
            let rest = api[format!("/v1/projects/{PROJECT}/cookie").len()..].to_string();
            cookie_api(&state, method, &rest, &query, req).await
        }
        (Method::GET, _) if !path.starts_with("/api/") && !path.starts_with("/v1/") => static_file(&state, &path),
        _ => error(StatusCode::NOT_FOUND, "not_found", "Nothing here."),
    };
    with_cors(response, cors)
}

async fn cookie_api(state: &Arc<State>, method: Method, rest: &str, query: &str, req: Request<Incoming>) -> Response<Body> {
    let parts: Vec<&str> = rest.trim_start_matches('/').split('/').filter(|p| !p.is_empty()).collect();
    match (method, parts.as_slice()) {
        (Method::GET, []) => ok(overview(state)),
        (Method::POST, ["jobs"]) => match body_json(req).await {
            Ok(body) => {
                let text = body["text"].as_str().unwrap_or_default();
                match start_job(state, text, body["conversation"].as_str(), "page") {
                    Ok(id) => ok(json!({"run_id": id, "steered": false})),
                    Err(e) => *e,
                }
            }
            Err(e) => e,
        },
        (Method::POST, ["routines"]) => match body_json(req).await {
            Ok(body) => create_routine(state, &body),
            Err(e) => e,
        },
        (Method::POST, ["routines", id]) => match body_json(req).await {
            Ok(body) => decide_routine(state, id, body["action"].as_str().unwrap_or_default()),
            Err(e) => e,
        },
        (Method::GET, ["runs", id]) => match state.runs.lock().expect("runs lock").get(*id) {
            Some(run) => ok(run_view(state, run)),
            None => error(StatusCode::NOT_FOUND, "not_found", "That job isn't here."),
        },
        (Method::POST, ["runs", id, "stop"]) => {
            let live = state.live.lock().expect("live lock").get(*id).cloned();
            match live {
                Some(live) => {
                    live.cancel.cancel();
                    ok(json!({"stopping": true}))
                }
                None => ok(json!({"stopping": false})),
            }
        }
        (Method::GET, ["runs", id, "stream"]) => stream(state, id, query),
        (Method::POST, ["approvals", id]) => match body_json(req).await {
            Ok(body) => decide(state, id, body["approve"].as_bool().unwrap_or(false)),
            Err(e) => e,
        },
        (Method::PUT, ["soul"]) => match body_json(req).await {
            Ok(body) => set_soul(state, body["text"].as_str().unwrap_or_default()),
            Err(e) => e,
        },
        (Method::PUT, ["prefs"]) => match body_json(req).await {
            Ok(body) => set_prefs(state, &body),
            Err(e) => e,
        },
        _ => error(
            StatusCode::NOT_FOUND,
            "with_enkeon",
            "That comes with Enkeon: your team, your apps, Slack and email. This Cookie works on your computer.",
        ),
    }
}

fn overview(state: &State) -> Value {
    let mut runs: Vec<Run> = state.runs.lock().expect("runs lock").values().cloned().collect();
    runs.sort_by(|a, b| b.started_at.cmp(&a.started_at).then_with(|| b.id.cmp(&a.id)));
    runs.truncate(RECENT);
    let approvals: Vec<Value> = state.approvals.lock().expect("approvals lock").values().map(|p| p.view.clone()).collect();
    json!({
        "enabled": true,
        "team": team_name(&state.opts.root),
        "address": null,
        // No credits on your own computer: the page shows none.
        "credits": {"allowance": 0, "used": 0},
        "runs": runs.iter().map(|r| run_view(state, r)).collect::<Vec<_>>(),
        "waiting": [],
        "approvals": approvals,
        "routines": routines_view(state),
        "viewer": {"member_id": MEMBER, "via": "console", "pin_set": true, "soul": read_soul(&state.opts.home), "prefs": read_prefs(&state.opts.home)},
        "slack": {"available": false, "workspace": null},
    })
}

/// A job as the page reads it; a working one carries what it has done so far.
fn run_view(state: &State, run: &Run) -> Value {
    let mut view = serde_json::to_value(run).expect("run serializes");
    if run.status == "running" {
        if let Some(live) = state.live.lock().expect("live lock").get(&run.id) {
            let s = live.state.lock().expect("live lock");
            view["steps"] = Value::Array(s.steps.clone());
            view["live_text"] = json!(s.text);
        }
    }
    view
}

/// Start a job (`trigger`: `page`, or `routine` for one a routine started);
/// its id, or the refusal to send.
fn start_job(state: &Arc<State>, text: &str, conversation: Option<&str>, trigger: &str) -> Result<String, Box<Response<Body>>> {
    let text = text.trim().to_string();
    if text.is_empty() {
        return Err(Box::new(error(StatusCode::BAD_REQUEST, "empty", "Give Cookie a job first.")));
    }
    let id = format!("ck_{}", token(12));
    // A follow-up continues its conversation: the same session file, so the
    // model reads what came before.
    let conversation = conversation
        .filter(|c| is_id(c) && state.runs.lock().expect("runs lock").values().any(|r| r.conversation.as_deref() == Some(*c)))
        .map(str::to_string)
        .unwrap_or_else(|| id.clone());
    let run = Run {
        id: id.clone(),
        trigger: trigger.into(),
        subject: clip(text.lines().next().unwrap_or_default(), 80),
        status: "running".into(),
        delivery: None,
        credits: 0,
        steps: Vec::new(),
        answer: None,
        started_at: utc_iso(SystemTime::now()),
        finished_at: None,
        conversation: Some(conversation.clone()),
        member_id: Some(MEMBER.into()),
        mine: true,
        block: None,
        trace: None,
    };
    let (changed, _) = watch::channel(0);
    let live = Arc::new(Live { state: Mutex::new(LiveState::default()), changed, cancel: CancellationToken::new() });
    state.live.lock().expect("live lock").insert(id.clone(), live.clone());
    save(state, &run);
    state.runs.lock().expect("runs lock").insert(id.clone(), run);
    tokio::spawn(work(state.clone(), id.clone(), conversation, text, live));
    Ok(id)
}

// MARK: routines

fn create_routine(state: &Arc<State>, body: &Value) -> Response<Body> {
    let job: String = body["job"].as_str().unwrap_or_default().trim().chars().take(JOB_CHARS).collect();
    let cadence = body["cadence"].as_str().unwrap_or_default();
    let n = |k: &str, lo: i64, hi: i64| body[k].as_i64().filter(|v| (lo..=hi).contains(v)).map(|v| v as i16);
    // Only a weekly routine has a day; the others keep Monday, as Enkeon's do.
    let weekday = if cadence == "weekly" { n("weekday", 1, 7) } else { Some(1) };
    let (Some(weekday), Some(hour), Some(minute)) = (weekday, n("hour", 0, 23), n("minute", 0, 59)) else {
        return error(StatusCode::BAD_REQUEST, "bad_time", "A routine needs a weekday from 1 to 7 (Monday is 1), an hour from 0 to 23 and a minute from 0 to 59.");
    };
    if job.is_empty() || !matches!(cadence, "daily" | "weekly" | "hourly") {
        return error(StatusCode::BAD_REQUEST, "bad_routine", "A routine needs a job and a cadence: daily, weekly or hourly.");
    }
    let mut routines = state.routines.lock().expect("routines lock");
    // The same routine asked again while it's active is the one already there, as in Enkeon.
    let now = SystemTime::now();
    if let Some(same) = routines.iter().find(|r| {
        r.state == "active" && r.job == job && r.cadence == cadence && r.weekday == weekday && r.hour == hour && r.minute == minute
    }) {
        return ok(routine_view(same, unix(now)));
    }
    if routines.iter().filter(|r| r.state != "declined").count() >= MOST_ROUTINES {
        return error(
            StatusCode::CONFLICT,
            "conflict",
            &format!("You have {MOST_ROUTINES} routines already. Stop one on the Board first."),
        );
    }
    let routine = Routine {
        id: format!("cr_{}", token(10)),
        job,
        cadence: cadence.into(),
        weekday,
        hour,
        minute,
        seen: 0,
        state: "active".into(),
        last_run_at: None,
        created_at: utc_iso(now),
        since: unix(now),
        fired: 0,
    };
    let view = routine_view(&routine, unix(now));
    routines.push(routine);
    save_routines(state, &routines);
    ok(view)
}

/// pause / resume (and accept / decline, the same answers Enkeon takes).
fn decide_routine(state: &Arc<State>, id: &str, action: &str) -> Response<Body> {
    let mut routines = state.routines.lock().expect("routines lock");
    let Some(i) = routines.iter().position(|r| r.id == id) else {
        return error(StatusCode::NOT_FOUND, "not_found", "That routine isn't here.");
    };
    let now = unix(SystemTime::now());
    let r = &mut routines[i];
    match (action, r.state.as_str()) {
        ("resume" | "accept", "paused") => {
            r.state = "active".into();
            r.since = now;
        }
        ("pause" | "decline", "active") => r.state = "paused".into(),
        _ => return error(StatusCode::CONFLICT, "conflict", &format!("A {} routine can't be {action}d.", r.state)),
    }
    let view = routine_view(r, now);
    save_routines(state, &routines);
    ok(view)
}

fn routines_view(state: &State) -> Vec<Value> {
    let now = unix(SystemTime::now());
    state.routines.lock().expect("routines lock").iter().rev().map(|r| routine_view(r, now)).collect()
}

fn routine_view(r: &Routine, now: i64) -> Value {
    let off = local_offset(now);
    let next = (r.state == "active").then(|| next_due(r, now + off) - off);
    json!({
        "id": r.id, "job": r.job, "cadence": r.cadence, "weekday": r.weekday, "hour": r.hour, "minute": r.minute,
        "seen": r.seen, "state": r.state, "last_run_at": r.last_run_at, "created_at": r.created_at,
        "next_run_at": next.map(|t| utc_iso(UNIX_EPOCH + Duration::from_secs(t.max(0) as u64))),
    })
}

fn save_routines(state: &State, routines: &[Routine]) {
    let path = state.opts.home.join("routines.json");
    if let Err(e) = write_atomic(&path, &serde_json::to_vec_pretty(routines).expect("routines serialize")) {
        tracing::warn!("cookie page: could not save {}: {e}", path.display());
    }
}

/// Start each due routine's job once per time it is due.
async fn fire_routines(state: Arc<State>) {
    let mut tick = tokio::time::interval(ROUTINE_TICK);
    loop {
        tick.tick().await;
        let now_t = SystemTime::now();
        let now = unix(now_t);
        let off = local_offset(now);
        let due: Vec<(usize, i64)> = {
            let routines = state.routines.lock().expect("routines lock");
            routines
                .iter()
                .enumerate()
                .filter(|(_, r)| r.state == "active")
                .map(|(i, r)| (i, last_due(r, now + off) - off))
                .filter(|(i, at)| *at > routines[*i].fired.max(routines[*i].since) && now - at <= ROUTINE_LATE_SECS)
                .collect()
        };
        if due.is_empty() {
            continue;
        }
        let mut routines = state.routines.lock().expect("routines lock");
        for (i, at) in due {
            let r = &mut routines[i];
            // Claimed before it starts: a job that fails is not run again for the same time.
            r.fired = at;
            r.last_run_at = Some(utc_iso(now_t));
            if let Err(e) = start_job(&state, &r.job.clone(), None, "routine") {
                tracing::warn!("cookie page: routine {} did not start: {}", r.id, e.status());
            }
        }
        save_routines(&state, &routines);
    }
}

/// The latest time at or before `wall` (seconds on this computer's wall clock,
/// as if it were UTC) the routine was due.
fn last_due(r: &Routine, wall: i64) -> i64 {
    let (hour, minute) = (i64::from(r.hour), i64::from(r.minute));
    let day = wall.div_euclid(86_400);
    let at = day * 86_400 + hour * 3_600 + minute * 60;
    match r.cadence.as_str() {
        "hourly" => {
            let at = wall.div_euclid(3_600) * 3_600 + minute * 60;
            if at <= wall { at } else { at - 3_600 }
        }
        "weekly" => {
            // 1 January 1970 was a Thursday: day 0 is weekday 4 counting Monday as 1.
            let today = (day + 3).rem_euclid(7) + 1;
            let at = at - (today - i64::from(r.weekday)).rem_euclid(7) * 86_400;
            if at <= wall { at } else { at - 7 * 86_400 }
        }
        _ => if at <= wall { at } else { at - 86_400 },
    }
}

fn next_due(r: &Routine, wall: i64) -> i64 {
    last_due(r, wall) + match r.cadence.as_str() {
        "hourly" => 3_600,
        "weekly" => 7 * 86_400,
        _ => 86_400,
    }
}

/// This computer's offset from UTC at `secs`, in seconds, from its own time
/// zone (so its clock changes are kept).
// ponytail: other systems read their prefs' fixed offset; add a zone database if Cookie's page is ever run off Unix.
fn local_offset(secs: i64) -> i64 {
    #[cfg(unix)]
    {
        let t = secs as libc::time_t;
        // SAFETY: localtime_r writes only into `tm`, which outlives the call.
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        if !unsafe { libc::localtime_r(&t, &mut tm) }.is_null() {
            // tm_gmtoff is a C long: 64 bits here, 32 on some targets.
            #[allow(clippy::unnecessary_cast)]
            return tm.tm_gmtoff as i64;
        }
    }
    let _ = secs;
    0
}

fn unix(t: SystemTime) -> i64 {
    t.duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or_default()
}

// MARK: prefs

fn read_prefs(home: &Path) -> Value {
    std::fs::read(home.join("prefs.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_else(|| json!({"notices": true, "tz_offset_min": 0, "tz": "", "quiet_from": 22, "quiet_to": 7}))
}

/// The page's settings, as Enkeon keeps them: whether notices come, the zone
/// (IANA name and the offset), quiet hours.
fn set_prefs(state: &State, body: &Value) -> Response<Body> {
    let mut prefs = read_prefs(&state.opts.home);
    if let Some(v) = body["notices"].as_bool() {
        prefs["notices"] = json!(v);
    }
    if let Some(v) = body["tz_offset_min"].as_i64().filter(|v| v.abs() <= 14 * 60) {
        prefs["tz_offset_min"] = json!(v);
    }
    if let Some(v) = body["tz"].as_str().filter(|v| v.len() <= 64 && v.bytes().all(|b| b.is_ascii_alphanumeric() || b"/_+-".contains(&b))) {
        prefs["tz"] = json!(v);
    }
    for k in ["quiet_from", "quiet_to"] {
        if let Some(v) = body[k].as_i64().filter(|v| (0..24).contains(v)) {
            prefs[k] = json!(v);
        }
    }
    match write_atomic(&state.opts.home.join("prefs.json"), prefs.to_string().as_bytes()) {
        Ok(()) => ok(json!({"saved": true})),
        Err(e) => error(StatusCode::INTERNAL_SERVER_ERROR, "write", &format!("Couldn't save it: {e}")),
    }
}

/// The key that signs this machine's action logs, made once in `home`.
pub fn trace_key(home: &Path) -> crate::Result<crate::trace::SigningKey> {
    crate::trace::SigningKey::load_or_create(home.join("trace.key"))
}

/// A job's own action log, next to its record, from nothing.
fn job_trace(home: &Path, id: &str) -> crate::Result<crate::trace::Tracer> {
    let log = crate::trace::TraceLog::open(home.join("runs").join(format!("{id}.trace.jsonl")), trace_key(home)?, None)?;
    Ok(crate::trace::Tracer::new(Arc::new(Mutex::new(log)), id))
}

async fn work(state: Arc<State>, id: String, conversation: String, text: String, live: Arc<Live>) {
    let (outcome, trace) = match job_trace(&state.opts.home, &id) {
        Ok(tracer) => (run_job(&state, &id, &conversation, &text, &live, tracer.clone()).await, Some(tracer.anchor())),
        Err(e) => (Err(e), None),
    };
    let steps = live.state.lock().expect("live lock").steps.clone();
    let mut runs = state.runs.lock().expect("runs lock");
    let Some(run) = runs.get_mut(&id) else { return };
    run.steps = steps;
    run.trace = trace;
    run.finished_at = Some(utc_iso(SystemTime::now()));
    match outcome {
        Ok(answer) => {
            run.status = "done".into();
            run.answer = Some(answer);
        }
        Err(Error::Cancelled) | Err(Error::Stopped) => {
            run.status = "done".into();
            run.delivery = Some("stopped".into());
            let said = live.state.lock().expect("live lock").text.trim().to_string();
            run.answer = (!said.is_empty()).then_some(said);
        }
        Err(e) => {
            tracing::warn!("cookie page: job {id} failed: {e}");
            run.status = "failed".into();
            run.delivery = Some("failed".into());
        }
    }
    let finished = run.clone();
    drop(runs);
    save(&state, &finished);
    live.update(|s| s.done = true);
    state.live.lock().expect("live lock").remove(&id);
}

async fn run_job(state: &Arc<State>, id: &str, conversation: &str, text: &str, live: &Arc<Live>, trace: crate::trace::Tracer) -> crate::Result<String> {
    let opts = &state.opts;
    let mut instructions = local::LOCAL_INSTRUCTIONS.to_string();
    if let Some(soul) = read_soul(&opts.home) {
        instructions.push_str(&format!("\n\nIn the person's own words, how you should be:\n{soul}"));
    }
    let started = Instant::now();
    let tools: Vec<Arc<dyn Tool>> = local::tools(Some(opts.root.clone()), local::Search::from_env(), opts.ask)
        .into_iter()
        .map(|inner| Arc::new(Recorded { inner, live: live.clone(), started }) as Arc<dyn Tool>)
        .collect();
    let named: Vec<String> = tools.iter().map(|t| t.spec().name.clone()).collect();
    let mut agent = Agent::new(&opts.model)?
        .instructions(instructions)
        .tools(tools)
        .notes(opts.home.join("NOTES.md"))
        .approver(PageApprover { state: state.clone(), run: id.to_string() })
        .trace(trace);
    if opts.ask {
        agent = agent.policy(Policy::default().confirm_data());
    }
    let mut session = Session::open(opts.home.join("conversations").join(format!("{conversation}.jsonl"))).await?;
    let control = RunControl { cancel: live.cancel.clone(), ..RunControl::default() };
    // Tools that are not this folder's (Enkeon's `recall` and `remember` when
    // a key is set, else Cookie's notes) show from their events: the name, and
    // whether it worked.
    let mut other: HashMap<String, usize> = HashMap::new();
    agent
        .run_streaming(&mut session, Message::user(text), &control, &mut |event| match event {
            Event::TextDelta(t) => live.update(|s| s.text.push_str(&t)),
            Event::ToolCallStarted { id, name } if !named.contains(&name) => {
                let what = match name.as_str() {
                    "remember" => "Saved to your context",
                    "note" => "Kept a note",
                    "forget_note" => "Removed a note",
                    _ => "Your context",
                };
                live.update(|s| {
                    other.insert(id, s.steps.len());
                    s.steps.push(json!({"at_ms": started.elapsed().as_millis() as u64, "tool": name, "what": what, "ok": true}));
                });
            }
            Event::ToolFinished { id, is_error } => {
                if let Some(i) = other.remove(&id) {
                    live.update(|s| s.steps[i]["ok"] = json!(!is_error));
                }
            }
            _ => {}
        })
        .await
}

/// A folder or web tool whose every call lands on the board as a step: what
/// it looked up, how long it took, what came back.
struct Recorded {
    inner: Arc<dyn Tool>,
    live: Arc<Live>,
    started: Instant,
}

#[async_trait]
impl Tool for Recorded {
    fn spec(&self) -> &ToolSpec {
        self.inner.spec()
    }

    async fn call(&self, args: Value) -> Result<String, String> {
        self.inner.call(args).await
    }

    async fn call_in(&self, args: Value, context: &ToolContext) -> Result<String, String> {
        let began = Instant::now();
        let result = self.inner.call_in(args.clone(), context).await;
        let mut step = board_step(&self.spec().name, &args, &result);
        step["at_ms"] = json!(self.started.elapsed().as_millis() as u64);
        step["ms"] = json!(began.elapsed().as_millis() as u64);
        self.live.update(|s| s.steps.push(step));
        result
    }

    fn preview(&self, args: &Value) -> String {
        self.inner.preview(args)
    }
}

/// How a local call reads on the board. The folder is the person's own
/// context, so its searches and files show as notes; searches and pages as
/// the board draws them in Enkeon.
pub fn board_step(name: &str, args: &Value, result: &Result<String, String>) -> Value {
    let arg = |k: &str| args[k].as_str().unwrap_or_default().trim().to_string();
    let text = result.as_deref().unwrap_or_default();
    let ok = result.is_ok();
    match name {
        "search_files" => json!({"tool": "recall", "what": arg("query"), "ok": ok, "size": text.len(),
            "peek": {"notes": text.lines().filter(|l| !l.trim().is_empty()).take(6).map(|l| json!({"text": clip(l.trim(), 200)})).collect::<Vec<_>>()}}),
        "read_file" => json!({"tool": "recall", "what": arg("path"), "ok": ok, "size": text.len(),
            "peek": {"notes": [{"text": clip(text, 1_500)}]}}),
        "web_search" => json!({"tool": "web_search", "what": arg("query"), "ok": ok, "size": text.len(),
            "peek": {"results": search_results(text)}}),
        "read_url" => {
            let url = arg("url");
            let host = url::Url::parse(&url).ok().and_then(|u| u.host_str().map(|h| h.trim_start_matches("www.").to_string())).unwrap_or(url.clone());
            json!({"tool": "read_url", "what": host, "ok": ok, "size": text.len(), "peek": {"title": url, "text": clip(text, 1_500)}})
        }
        other => json!({"tool": other, "what": other, "ok": ok, "size": text.len()}),
    }
}

/// The titles and hosts in a `web_search` result (`local::results`' format:
/// "1. Title" then the address on the next line).
fn search_results(text: &str) -> Vec<Value> {
    let lines: Vec<&str> = text.lines().map(str::trim).collect();
    let mut out = Vec::new();
    for pair in lines.windows(2) {
        let (title, address) = (pair[0], pair[1]);
        let Some((n, title)) = title.split_once(". ") else { continue };
        if n.parse::<u32>().is_err() {
            continue;
        }
        let Some(host) = url::Url::parse(address).ok().and_then(|u| u.host_str().map(|h| h.trim_start_matches("www.").to_string())) else { continue };
        out.push(json!({"title": clip(title, 120), "host": host}));
    }
    out
}

/// A page address from what Cookie read, put to the person on the page's
/// approval card; no answer within ten minutes is a no.
struct PageApprover {
    state: Arc<State>,
    run: String,
}

#[async_trait]
impl Approver for PageApprover {
    async fn approve(&self, request: &ApprovalRequest) -> bool {
        let id = format!("ap_{}", token(10));
        let now = SystemTime::now();
        let detail = if request.from_data.is_empty() { request.preview.clone() } else { request.from_data.join("\n") };
        let view = json!({
            "id": id, "slug": "web", "tool": request.tool, "class": "read", "status": "pending",
            "detail": detail, "result": null, "run_id": self.run,
            "created_at": utc_iso(now), "expires_at": utc_iso(now + APPROVAL_TTL),
        });
        let (answer, decided) = oneshot::channel();
        self.state.approvals.lock().expect("approvals lock").insert(id.clone(), Pending { view, answer });
        let yes = matches!(tokio::time::timeout(APPROVAL_TTL, decided).await, Ok(Ok(true)));
        self.state.approvals.lock().expect("approvals lock").remove(&id);
        yes
    }

    fn is_person(&self) -> bool {
        true
    }
}

fn decide(state: &State, id: &str, approve: bool) -> Response<Body> {
    let Some(pending) = state.approvals.lock().expect("approvals lock").remove(id) else {
        return error(StatusCode::NOT_FOUND, "not_found", "That question has already been answered.");
    };
    let mut view = pending.view;
    view["status"] = json!(if approve { "approved" } else { "denied" });
    let _ = pending.answer.send(approve);
    ok(view)
}

fn mint_ticket(state: &State, body: &Value) -> Response<Body> {
    let path = body["path"].as_str().unwrap_or_default();
    let prefix = format!("/v1/projects/{PROJECT}/cookie/runs/");
    let run_ok = path.strip_prefix(&prefix).and_then(|r| r.strip_suffix("/stream")).is_some_and(is_id);
    if !run_ok {
        return error(StatusCode::BAD_REQUEST, "bad_path", "That isn't a stream.");
    }
    let ticket = token(16);
    let mut tickets = state.tickets.lock().expect("tickets lock");
    tickets.retain(|_, (_, at)| at.elapsed() < TICKET_TTL);
    tickets.insert(ticket.clone(), (path.to_string(), Instant::now()));
    ok(json!({"ticket": ticket}))
}

/// One working job, live: the first frame carries every step, later ones only
/// the new; the last says `done`.
fn stream(state: &State, id: &str, query: &str) -> Response<Body> {
    let ticket = url::form_urlencoded::parse(query.as_bytes()).find(|(k, _)| k == "ticket").map(|(_, v)| v.into_owned()).unwrap_or_default();
    let path = format!("/v1/projects/{PROJECT}/cookie/runs/{id}/stream");
    let valid = state.tickets.lock().expect("tickets lock").remove(&ticket).is_some_and(|(p, at)| p == path && at.elapsed() < TICKET_TTL);
    if !valid {
        return error(StatusCode::UNAUTHORIZED, "ticket", "That stream link has expired.");
    }
    let live = state.live.lock().expect("live lock").get(id).cloned();
    // A job that has already finished: one frame saying so.
    let finished = futures::stream::iter(live.is_none().then(|| {
        let frame = json!({"text": "", "helpers": [], "queued": false, "done": true, "steps_from": 0, "steps": []});
        Ok::<_, Infallible>(Frame::data(Bytes::from(format!("event: live\ndata: {frame}\n\n"))))
    }));
    // One receiver for the whole stream, so no change between frames is missed.
    let start = live.map(|live| {
        let changed = live.changed.subscribe();
        (live, changed)
    });
    let frames = futures::stream::unfold((start, 0usize, true), |(live, sent, first)| async move {
        let (live, mut changed) = live?;
        if !first {
            match tokio::time::timeout(KEEP_ALIVE, changed.changed()).await {
                Err(_) => {
                    let ping = Ok::<_, Infallible>(Frame::data(Bytes::from_static(b": keep-alive\n\n")));
                    return Some((ping, (Some((live, changed)), sent, false)));
                }
                Ok(Err(_)) => return None,
                // Words arrive a few at a time: one frame per moment, not per word.
                Ok(Ok(())) => tokio::time::sleep(FRAME_EVERY).await,
            }
        }
        changed.borrow_and_update();
        let (frame, total, done) = {
            let s = live.state.lock().expect("live lock");
            let from = sent.min(s.steps.len());
            let frame = json!({"text": s.text, "helpers": [], "queued": false, "done": s.done,
                "steps_from": from, "steps": s.steps[from..].to_vec()});
            (frame, s.steps.len(), s.done)
        };
        let chunk = Ok::<_, Infallible>(Frame::data(Bytes::from(format!("event: live\ndata: {frame}\n\n"))));
        Some((chunk, (if done { None } else { Some((live, changed)) }, total, false)))
    });
    let body = StreamBody::new(futures::StreamExt::chain(finished, frames)).boxed_unsync();
    Response::builder()
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-store")
        .body(body)
        .expect("response")
}

fn read_soul(home: &Path) -> Option<String> {
    let text = std::fs::read_to_string(home.join("SOUL.md")).ok()?;
    let text = text.trim();
    (!text.is_empty()).then(|| text.chars().take(SOUL_CHARS).collect())
}

fn set_soul(state: &State, text: &str) -> Response<Body> {
    let text: String = text.trim().chars().take(SOUL_CHARS).collect();
    let path = state.opts.home.join("SOUL.md");
    let written = if text.is_empty() { std::fs::remove_file(&path).or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) }) } else { write_atomic(&path, text.as_bytes()) };
    match written {
        Ok(()) => ok(json!({"saved": true})),
        Err(e) => error(StatusCode::INTERNAL_SERVER_ERROR, "write", &format!("Couldn't save it: {e}")),
    }
}

/// Save a job: written beside, then renamed over, so a crash never leaves half a file.
fn save(state: &State, run: &Run) {
    let path = state.opts.home.join("runs").join(format!("{}.json", run.id));
    let text = serde_json::to_vec_pretty(run).expect("run serializes");
    if let Err(e) = write_atomic(&path, &text) {
        tracing::warn!("cookie page: could not save {}: {e}", path.display());
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let beside = path.with_extension(format!("tmp{}", token(4)));
    std::fs::write(&beside, bytes)?;
    std::fs::rename(&beside, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&beside);
    })
}

/// A file of the built page. Only paths inside `page_dir`; a route without a
/// file extension is its `.html` (Next's export), `/` opens the page.
fn static_file(state: &State, path: &str) -> Response<Body> {
    let Some(dir) = &state.opts.page_dir else {
        return error(StatusCode::NOT_FOUND, "no_page", "Build the page first: cd web && npm run build.");
    };
    if path == "/" {
        return Response::builder().status(StatusCode::FOUND).header(header::LOCATION, PAGE_PATH).body(empty()).expect("response");
    }
    let Some(rel) = safe_relative(path) else {
        return error(StatusCode::NOT_FOUND, "not_found", "Nothing here.");
    };
    let file = dir.join(&rel);
    let candidates = if rel.extension().is_some() { vec![file] } else { vec![file.with_extension("html"), file.join("index.html")] };
    for candidate in candidates {
        if let Ok(bytes) = std::fs::read(&candidate) {
            let cache = if rel.starts_with("_next/static") { "public, max-age=31536000, immutable" } else { "no-cache" };
            return Response::builder()
                .header(header::CONTENT_TYPE, content_type(&candidate))
                .header(header::CACHE_CONTROL, cache)
                .header("x-content-type-options", "nosniff")
                .body(full(bytes))
                .expect("response");
        }
    }
    error(StatusCode::NOT_FOUND, "not_found", "Nothing here.")
}

/// A URL path as a relative file path, or `None` when any part could step
/// outside the folder (`..`, a drive, a root).
pub fn safe_relative(path: &str) -> Option<PathBuf> {
    let decoded = url::form_urlencoded::parse(format!("p={}", path.trim_start_matches('/').replace('+', "%2B")).as_bytes())
        .next()
        .map(|(_, v)| v.into_owned())?;
    if decoded.contains('\\') || decoded.contains('\0') {
        return None;
    }
    let rel = PathBuf::from(&decoded);
    rel.components().all(|c| matches!(c, Component::Normal(_))).then_some(rel).filter(|r| !r.as_os_str().is_empty())
}

fn content_type(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).unwrap_or_default() {
        "html" => "text/html; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "svg" => "image/svg+xml",
        "ico" => "image/x-icon",
        "woff2" => "font/woff2",
        "woff" => "font/woff",
        "txt" => "text/plain; charset=utf-8",
        "webmanifest" => "application/manifest+json",
        _ => "application/octet-stream",
    }
}

fn team_name(root: &Path) -> String {
    root.canonicalize().ok().and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned())).unwrap_or_else(|| "Your folder".into())
}

async fn body_json(req: Request<Incoming>) -> Result<Value, Response<Body>> {
    let bytes = Limited::new(req.into_body(), BODY_LIMIT)
        .collect()
        .await
        .map_err(|_| error(StatusCode::PAYLOAD_TOO_LARGE, "too_large", "That's too long to send."))?
        .to_bytes();
    if bytes.is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_slice(&bytes).map_err(|_| error(StatusCode::BAD_REQUEST, "bad_json", "That wasn't JSON."))
}

fn ok(value: Value) -> Response<Body> {
    Response::builder()
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::CACHE_CONTROL, "no-store")
        .body(full(value.to_string()))
        .expect("response")
}

fn error(status: StatusCode, code: &str, message: &str) -> Response<Body> {
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::CACHE_CONTROL, "no-store")
        .body(full(json!({"error": {"code": code, "message": message}}).to_string()))
        .expect("response")
}

fn with_cors(mut response: Response<Body>, origin: Option<&str>) -> Response<Body> {
    // The origin was checked against the allowed ones before this point.
    if let Some(origin) = origin.and_then(|o| header::HeaderValue::from_str(o).ok()) {
        let h = response.headers_mut();
        h.insert(header::ACCESS_CONTROL_ALLOW_ORIGIN, origin);
        h.insert(header::VARY, header::HeaderValue::from_static("origin"));
        h.insert(header::ACCESS_CONTROL_ALLOW_METHODS, header::HeaderValue::from_static("GET, POST, PUT, DELETE"));
        h.insert(header::ACCESS_CONTROL_ALLOW_HEADERS, header::HeaderValue::from_static("content-type"));
    }
    response
}

fn full(bytes: impl Into<Bytes>) -> Body {
    Full::new(bytes.into()).boxed_unsync()
}

fn empty() -> Body {
    full(Bytes::new())
}

fn is_id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 64 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn clip(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        return s.to_string();
    }
    let mut out: String = s.chars().take(n.saturating_sub(1)).collect();
    out.push('…');
    out
}

/// `bytes` random bytes as hex, from the standard library's OS-seeded hasher
/// keys (fresh per call) over a counter and the clock.
fn token(bytes: usize) -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let mut out = String::with_capacity(bytes * 2);
    while out.len() < bytes * 2 {
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u64(COUNTER.fetch_add(1, Ordering::Relaxed));
        h.write_u128(SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or_default());
        out.push_str(&format!("{:016x}", h.finish()));
    }
    out.truncate(bytes * 2);
    out
}

/// A time as `2026-10-23T21:05:09Z` (UTC, whole seconds).
pub fn utc_iso(t: SystemTime) -> String {
    let secs = t.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or_default() as i64;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Days to a civil date (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", rem / 3_600, rem % 3_600 / 60, rem % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn times_are_utc_iso() {
        assert_eq!(utc_iso(UNIX_EPOCH), "1970-01-01T00:00:00Z");
        assert_eq!(utc_iso(UNIX_EPOCH + Duration::from_secs(951_782_400)), "2000-02-29T00:00:00Z");
        assert_eq!(utc_iso(UNIX_EPOCH + Duration::from_secs(1_792_789_509)), "2026-10-23T21:05:09Z");
        assert_eq!(utc_iso(UNIX_EPOCH + Duration::from_secs(4_102_444_799)), "2099-12-31T23:59:59Z");
    }

    #[test]
    fn a_path_never_steps_outside_the_page_folder() {
        assert_eq!(safe_relative("/_next/static/a.js"), Some(PathBuf::from("_next/static/a.js")));
        assert_eq!(safe_relative("/me/local/cookie"), Some(PathBuf::from("me/local/cookie")));
        for bad in ["/../etc/passwd", "/a/../../b", "/%2e%2e/secret", "/..%2fsecret", "/a%5c..%5cb", "/", "/a%00b"] {
            assert_eq!(safe_relative(bad), None, "{bad}");
        }
    }

    #[test]
    fn local_calls_land_on_the_board_as_its_kinds() {
        let found = board_step("search_files", &json!({"query": "refunds"}), &Ok("src/pay.rs:12: fn refund()\n\nsrc/pay.rs:40: // refunds".into()));
        assert_eq!((found["tool"].as_str(), found["what"].as_str()), (Some("recall"), Some("refunds")));
        assert_eq!(found["peek"]["notes"].as_array().map(Vec::len), Some(2));
        let page = board_step("read_url", &json!({"url": "https://www.example.com/pricing"}), &Ok("Pricing".into()));
        assert_eq!((page["tool"].as_str(), page["what"].as_str()), (Some("read_url"), Some("example.com")));
        let search = board_step(
            "web_search",
            &json!({"query": "baltic saas"}),
            &Ok("Web results for \"baltic saas\":\n\n1. Spotwise careers\n   https://spotwise.lv/careers\n   text\n\n2. Levelpath\n   https://www.levelpath.com/\n".into()),
        );
        assert_eq!(search["peek"]["results"], json!([{"title": "Spotwise careers", "host": "spotwise.lv"}, {"title": "Levelpath", "host": "levelpath.com"}]));
        let failed = board_step("read_file", &json!({"path": "missing.rs"}), &Err("no such file".into()));
        assert_eq!(failed["ok"], json!(false));
    }

    #[test]
    fn ids_and_tokens_are_plain_and_unpredictable() {
        assert!(is_id("ck_0123abcd") && !is_id("../x") && !is_id("") && !is_id(&"a".repeat(65)));
        let (a, b) = (token(16), token(16));
        assert_eq!(a.len(), 32);
        assert!(a.bytes().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, b);
    }

    #[test]
    fn a_routine_is_due_at_its_own_hour_on_its_day() {
        let r = |cadence: &str, weekday: i16| Routine {
            id: "cr_t".into(), job: "inbox".into(), cadence: cadence.into(), weekday, hour: 17, minute: 0, seen: 0,
            state: "active".into(), last_run_at: None, created_at: String::new(), since: 0, fired: 0,
        };
        // Friday 23 October 2026, 18:30 on the wall clock.
        let wall = 1_792_780_200;
        let five = |days_back: i64| wall - 90 * 60 - days_back * 86_400;
        let tuesday = r("weekly", 2);
        assert_eq!(last_due(&tuesday, wall), five(3));
        assert_eq!(next_due(&tuesday, wall), five(3) + 7 * 86_400);
        assert_eq!(last_due(&r("weekly", 5), wall), five(0), "today at 17:00");
        assert_eq!(last_due(&r("weekly", 6), wall), five(6), "Saturday is still ahead: last week's");
        assert_eq!(last_due(&r("daily", 1), wall - 2 * 3_600), five(1), "16:30 is before today's 17:00");
        assert_eq!(last_due(&r("hourly", 1), wall), wall - 30 * 60);
    }

    #[test]
    fn clip_cuts_whole_characters() {
        assert_eq!(clip("äöü", 2), "ä…");
        assert_eq!(clip("short", 10), "short");
    }
}
