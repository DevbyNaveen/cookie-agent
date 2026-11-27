//! The Mac as a hand: a team that lives in the cloud, beside its Parallax
//! worlds, reaches the person's Mac only for what lives there (their files,
//! their Mac apps, apps used through Hands, their 1Password).
//!
//! - **On the server.** Each Mac-only tool an agent holds is a proxy with the
//!   same name, schema, effect and guarded arguments, so the policy and the
//!   person's yes work exactly as on the Mac. Once allowed, the call goes into
//!   a queue the Mac app collects (`GET /hand/next`, a long poll) and answers
//!   (`POST /hand/result`).
//! - **Mac away.** A call that finds no Mac connected, or that the Mac doesn't
//!   pick up in time, is parked on disk and the agent is told so at once: the
//!   rest of the job carries on. When the Mac app opens, it runs what was
//!   parked, and each result is handed back to its agent as a new job.
//! - **On the Mac.** The app runs a hand loop only when the person turned on
//!   "Let my cloud team use this Mac". It runs only the Mac-only tools, built
//!   from this Mac's own settings (the folders the person gave, the apps it
//!   allowed). Consent was given in the cloud, where the policy ran; the Mac
//!   runs nothing that isn't on its own list.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use cookie_harness::tool::{Tool, ToolSpec};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::store::Trigger;
use crate::{util, Team};

/// A Mac that polled within this long is connected.
const CONNECTED_FOR: Duration = Duration::from_secs(45);
/// How long a call waits for a connected Mac to answer before it is parked.
const ANSWER_WITHIN: Duration = Duration::from_secs(15 * 60);
/// How long one long poll from the Mac waits for work.
pub const POLL_WAIT: Duration = Duration::from_secs(25);
/// A parked call older than this is dropped (and its agent told) rather than run late.
const PARKED_KEEP: u64 = 7 * 86_400;

/// One call for the Mac.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HandCall {
    pub id: String,
    pub agent: String,
    pub job: String,
    pub tool: String,
    pub args: Value,
    pub at: u64,
    /// Parked: no Mac was there; its result comes back as a new job.
    #[serde(default)]
    pub parked: bool,
}

#[derive(Default)]
struct Queue {
    pending: VecDeque<HandCall>,
    /// Calls the Mac took and hasn't answered: who is waiting for each.
    waiting: HashMap<String, tokio::sync::oneshot::Sender<Result<String, String>>>,
    last_seen: Option<Instant>,
}

fn queue() -> &'static (Mutex<Queue>, tokio::sync::Notify) {
    static Q: OnceLock<(Mutex<Queue>, tokio::sync::Notify)> = OnceLock::new();
    Q.get_or_init(|| (Mutex::new(Queue::default()), tokio::sync::Notify::new()))
}

/// Whether a Mac is connected right now.
pub fn connected() -> bool {
    queue().0.lock().unwrap().last_seen.is_some_and(|t| t.elapsed() < CONNECTED_FOR)
}

impl Team {
    fn parked_path(&self) -> std::path::PathBuf {
        self.paths.root.join("hand-parked.jsonl")
    }

    pub(crate) fn parked_calls(&self) -> Vec<HandCall> {
        util::read_jsonl(&self.parked_path())
    }

    fn save_parked(&self, calls: &[HandCall]) {
        let path = self.parked_path();
        let body: String = calls.iter().filter_map(|c| serde_json::to_string(c).ok()).map(|l| l + "\n").collect();
        let _ = std::fs::write(path, body);
    }

    fn park(&self, call: HandCall) {
        let mut all = self.parked_calls();
        all.push(HandCall { parked: true, ..call });
        self.save_parked(&all);
    }

    /// The Mac asks for work: everything queued now, or what arrives within `POLL_WAIT`.
    /// Parked calls come first, so what waited longest runs first when the Mac returns.
    pub async fn hand_next(self: &Arc<Self>) -> Vec<HandCall> {
        let (q, notify) = queue();
        q.lock().unwrap().last_seen = Some(Instant::now());
        let now = util::now();
        let parked: Vec<HandCall> = self.parked_calls();
        if !parked.is_empty() {
            let (fresh, stale): (Vec<_>, Vec<_>) = parked.into_iter().partition(|c| now.saturating_sub(c.at) <= PARKED_KEEP);
            for c in stale {
                let _ = self.give_work(&c.agent, format!("What was waiting for the person's Mac was dropped after a week without it: `{}` ({}). Decide whether it still matters.", c.tool, util::clip(&c.args.to_string(), 300)), Trigger::Inbox).await;
            }
            self.save_parked(&[]);
            if !fresh.is_empty() {
                return fresh;
            }
        }
        let deadline = tokio::time::Instant::now() + POLL_WAIT;
        loop {
            {
                let mut g = q.lock().unwrap();
                g.last_seen = Some(Instant::now());
                if !g.pending.is_empty() {
                    return g.pending.drain(..).collect();
                }
            }
            if tokio::time::timeout_at(deadline, notify.notified()).await.is_err() {
                return Vec::new();
            }
        }
    }

    /// The Mac's answer to one call.
    pub async fn hand_result(self: &Arc<Self>, call: HandCall, result: Result<String, String>) {
        let waiter = queue().0.lock().unwrap().waiting.remove(&call.id);
        // The job is still waiting for it: hand it over. Parked, or its job moved on: the result
        // comes back to the agent as new work.
        let handed = match waiter {
            Some(tx) => tx.send(result.clone()).is_ok(),
            None => false,
        };
        match handed {
            true => {}
            false => {
                let said = match &result {
                    Ok(r) => format!("Result:\n{}", util::clip(r, 6000)),
                    Err(e) => format!("It failed: {e}"),
                };
                let text = format!(
                    "The person's Mac came back and ran what was waiting for it: `{}` ({}). {said}\n\nCarry on with the work it was for.",
                    call.tool,
                    util::clip(&call.args.to_string(), 400)
                );
                if let Err(e) = self.give_work(&call.agent, text, Trigger::Inbox).await {
                    tracing::warn!("a result from the Mac couldn't reach {}: {e}", call.agent);
                }
            }
        }
    }
}

/// A Mac-only tool, run on the person's Mac from a team in the cloud.
pub struct HandProxy {
    inner: Arc<dyn Tool>,
    team: Weak<Team>,
    agent: String,
    job: String,
}

#[async_trait]
impl Tool for HandProxy {
    fn spec(&self) -> &ToolSpec {
        self.inner.spec()
    }

    async fn call(&self, args: Value) -> Result<String, String> {
        let team = self.team.upgrade().ok_or("Cookie is closing.")?;
        let call = HandCall { id: util::new_id("hand"), agent: self.agent.clone(), job: self.job.clone(), tool: self.inner.spec().name.clone(), args, at: util::now(), parked: false };
        let name = call.tool.clone();
        let parked_note = move |why: &str| {
            format!(
                "Parked: `{name}` needs the person's Mac, and {why}. It will run when the Mac app is open, and its result will come back to you as a new message. \
                 Carry on with everything that doesn't need it, and say in your answer what is waiting for the Mac."
            )
        };
        if !connected() {
            team.park(call.clone());
            return Ok(parked_note("the Mac isn't connected right now"));
        }
        let (tx, rx) = tokio::sync::oneshot::channel();
        {
            let (q, notify) = queue();
            let mut g = q.lock().unwrap();
            g.waiting.insert(call.id.clone(), tx);
            g.pending.push_back(call.clone());
            notify.notify_one();
        }
        match tokio::time::timeout(ANSWER_WITHIN, rx).await {
            Ok(Ok(result)) => result,
            _ => {
                // Not picked up (or not answered) in time: if it is still queued, park it.
                let still_queued = {
                    let mut g = queue().0.lock().unwrap();
                    let before = g.pending.len();
                    g.pending.retain(|c| c.id != call.id);
                    g.pending.len() < before
                };
                if still_queued {
                    queue().0.lock().unwrap().waiting.remove(&call.id);
                    team.park(call);
                    Ok(parked_note("the Mac didn't pick it up in time"))
                } else {
                    // The Mac has it: its answer will arrive as a new job (`hand_result`).
                    Ok(format!("`{}` is running on the person's Mac and is taking long; its result will come back to you as a new message.", self.inner.spec().name))
                }
            }
        }
    }

    fn preview(&self, args: &Value) -> String {
        format!("On your Mac: {}", self.inner.preview(args))
    }
}

/// Whether this team's Mac-only tools must reach a Mac elsewhere: it runs
/// somewhere that isn't the person's Mac (a cloud runner).
pub fn remote_hands() -> bool {
    !cfg!(target_os = "macos") || std::env::var("COOKIE_HANDS").is_ok_and(|v| v == "remote")
}

/// `tools` (all of them Mac-only), each as a proxy to the person's Mac.
pub(crate) fn proxied(team: &Arc<Team>, agent: &str, job: &str, tools: Vec<Arc<dyn Tool>>) -> Vec<Arc<dyn Tool>> {
    tools.into_iter().map(|t| Arc::new(HandProxy { inner: t, team: Arc::downgrade(team), agent: agent.to_string(), job: job.to_string() }) as Arc<dyn Tool>).collect()
}

/* ---------- on the Mac ---------- */

/// The Mac-only tools for `agent`: the person's files beyond its folder (with
/// `files`), and the Mac's own apps, Hands and 1Password (with `mac`). Built
/// from this Mac's own settings when it runs them, and as proxies in the cloud.
pub fn local_hand_tools(team: &Arc<Team>, agent: &str, job: &str, files: bool, mac: bool) -> Vec<Arc<dyn Tool>> {
    let mut out: Vec<Arc<dyn Tool>> = Vec::new();
    if files {
        out.extend(crate::access::tools(team, agent, job));
    }
    if mac {
        out.extend(crate::mac::tools());
        out.extend(crate::control::tools());
        out.extend(crate::hands::tools(team, agent));
        if !team.onepassword().vaults.is_empty() {
            out.extend(crate::onepassword::tools(team));
        }
    }
    out
}

/// Run as the cloud team's hand until `stop` is cancelled: collect calls,
/// run each with this Mac's own tools, send the results back.
pub async fn serve_as_hand(team: Arc<Team>, base: String, token: String, stop: tokio_util::sync::CancellationToken) {
    let http = reqwest::Client::builder().timeout(POLL_WAIT + Duration::from_secs(20)).build().unwrap_or_default();
    let base = base.trim_end_matches('/').to_string();
    let mut backoff = 1u64;
    while !stop.is_cancelled() {
        let next = http.get(format!("{base}/hand/next")).bearer_auth(&token).send();
        let reply = tokio::select! {
            r = next => r,
            _ = stop.cancelled() => return,
        };
        let calls: Vec<HandCall> = match reply {
            Ok(r) if r.status().is_success() => {
                backoff = 1;
                r.json().await.unwrap_or_default()
            }
            other => {
                if let Ok(r) = other {
                    tracing::warn!("the cloud team refused this Mac as its hand: HTTP {}", r.status());
                }
                tokio::time::sleep(Duration::from_secs(backoff)).await;
                backoff = (backoff * 2).min(60);
                continue;
            }
        };
        for call in calls {
            // Only what this Mac's own list holds: the cloud can ask, never widen it.
            let tools = local_hand_tools(&team, &call.agent, &call.job, true, true);
            let result = match tools.iter().find(|t| t.spec().name == call.tool) {
                Some(t) => t.call(call.args.clone()).await,
                None => Err(format!("This Mac doesn't run `{}` for the cloud team.", call.tool)),
            };
            let body = json!({"call": call, "ok": result.as_ref().ok(), "error": result.as_ref().err()});
            for attempt in 0..5u32 {
                match http.post(format!("{base}/hand/result")).bearer_auth(&token).json(&body).send().await {
                    Ok(r) if r.status().is_success() => break,
                    _ => tokio::time::sleep(Duration::from_secs(1 << attempt)).await,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // One test, in order: the queue is the process's own, shared by every test that touches it.
    #[tokio::test]
    async fn a_call_with_no_mac_is_parked_and_runs_when_it_returns_and_a_connected_mac_answers_directly() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        queue().0.lock().unwrap().last_seen = None;
        let tool = |name: &str| -> Arc<dyn Tool> { Arc::new(cookie_harness::tool::tool(name, "read", json!({}), cookie_harness::tool::Effect::Read, |_a: Value| async { Ok("local".to_string()) })) };
        // No Mac: parked, and the job is told so at once.
        let proxy = proxied(&team, "a", "job-1", vec![tool("mac_files_read")]).remove(0);
        assert_eq!(proxy.spec().name, "mac_files_read", "the same tool, as the policy sees it");
        let said = proxy.call(json!({"path": "~/Documents/plan.md"})).await.unwrap();
        assert!(said.starts_with("Parked:"), "{said}");
        let parked = team.parked_calls();
        assert_eq!(parked.len(), 1);
        assert!(parked[0].parked && parked[0].tool == "mac_files_read");
        // The Mac comes back: what was parked is the first thing it gets, and only once.
        assert_eq!(team.hand_next().await.len(), 1);
        assert!(team.parked_calls().is_empty());
        assert!(connected(), "polling marks the Mac connected");
        // A connected Mac answers the waiting job directly.
        let proxy = proxied(&team, "a", "job-2", vec![tool("notes_read")]).remove(0);
        let t2 = team.clone();
        let mac = tokio::spawn(async move {
            let calls = t2.hand_next().await;
            let c = calls.into_iter().find(|c| c.tool == "notes_read").unwrap();
            t2.hand_result(c, Ok("the note".into())).await;
        });
        assert_eq!(proxy.call(json!({})).await.unwrap(), "the note");
        mac.await.unwrap();
        queue().0.lock().unwrap().last_seen = None;
    }
}
