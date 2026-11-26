//! One agent in three places: this Mac, Enkeon's cloud when the Mac is off,
//! and your phone; and one store for what needs you.
//!
//! Needs this computer paired with Enkeon in Cookie (`pair`): the gateway
//! routes below take the paired personal key. Once a minute Cookie:
//!
//! 1. **Says it is on** (`cookie/desktop/sync`), with the agents you allowed
//!    to run in the cloud while it is off (Computer → "Run in the cloud when
//!    this Mac is off") and their routines. Only names, jobs and routine
//!    words leave the Mac: never files, notes, keys or the conversation.
//!    While the Mac is off for five minutes, a routine of theirs that comes
//!    due runs in Enkeon as that agent, on Cookie credits, with the team's
//!    context, the web and connected apps — not this Mac's files, commands,
//!    browser or Mac apps. **That work stays on the Mac.**
//! 2. **Takes back what ran** (`cookie/desktop/runs`): each cloud run joins
//!    the agent's record and conversation (marked as done in the cloud), and
//!    the routine's turn the cloud took is not run again here.
//! 3. **With the store on** (Settings → Enkeon, off by default), keeps your
//!    waiting approvals, notices and finished answers in Enkeon's one store
//!    (`cookie/desktop/items`), so your phone and the Console read them, and
//!    takes back the approvals you decided there (`cookie/desktop/decisions`).
//!    The key on this Mac can put an approval in the store and read its
//!    answer; only you, signed in, can decide it.
//!
//! A routine due right after Cookie starts waits for the first sync, so the
//! Mac and the cloud never both run the same turn.

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::events::TeamEvent;
use crate::store::{Job, JobStatus, Trigger};
use crate::{util, Team};

const TICK: Duration = Duration::from_secs(60);
const BODY_CAP: usize = 60_000;

/// The first sync was tried: routines may run here.
static FIRST_SYNC: AtomicBool = AtomicBool::new(false);

pub fn first_sync_done() -> bool {
    FIRST_SYNC.load(Ordering::Relaxed)
}

/// What is kept between syncs (`cloud.json`).
#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
struct CloudState {
    last_sync: i64,
    last_runs: i64,
    last_decisions: i64,
    /// Cloud runs already taken into the record.
    seen_runs: BTreeSet<String>,
    /// Approvals put in the store and not yet closed there.
    open_approvals: BTreeSet<String>,
    last_error: Option<String>,
    last_ok: i64,
}

/// What the store waits to send: notices and answers heard since the last tick.
#[derive(Debug, Default)]
struct Outbox {
    items: Vec<Value>,
}

static OUTBOX: std::sync::LazyLock<std::sync::Mutex<Outbox>> = std::sync::LazyLock::new(|| std::sync::Mutex::new(Outbox::default()));

fn http() -> &'static reqwest::Client {
    static C: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    C.get_or_init(|| reqwest::Client::builder().timeout(Duration::from_secs(20)).user_agent(concat!("cookie-desktop/", env!("CARGO_PKG_VERSION"))).build().unwrap_or_default())
}

/// One cloud run, as the gateway returns it.
#[derive(Debug, Clone, Deserialize)]
pub struct CloudRun {
    pub run: String,
    pub agent: Option<String>,
    pub routine: Option<String>,
    pub due_at: Option<i64>,
    pub status: String,
    #[serde(default)]
    pub task: String,
    pub answer: Option<String>,
    pub questions: Option<String>,
    pub error: Option<String>,
    pub started_at: Option<i64>,
    pub finished_at: Option<i64>,
}

/// A cloud run as a job in the agent's own record.
pub fn job_of(r: &CloudRun, agent: &str) -> Job {
    let answer = r.answer.clone().or_else(|| r.questions.clone()).unwrap_or_default();
    Job {
        id: r.run.clone(),
        agent: agent.into(),
        trigger: match &r.routine {
            Some(id) => Trigger::Routine { routine: id.clone() },
            None => Trigger::Chat,
        },
        input: r.task.clone(),
        started_at: r.started_at.unwrap_or(0).max(0) as u64,
        finished_at: r.finished_at.map(|t| t.max(0) as u64),
        status: if r.status == "done" && !answer.trim().is_empty() { JobStatus::Done } else { JobStatus::Failed },
        answer,
        error: r.error.clone(),
        place: Some("cloud".into()),
        ..Job::default()
    }
}

impl Team {
    fn cloud_path(&self) -> std::path::PathBuf {
        self.paths.root.join("cloud.json")
    }

    /// This computer's id in Enkeon: random, made once, never derived from the machine.
    pub fn device_id(&self) -> String {
        let f = self.paths.root.join("device-id");
        if let Ok(id) = std::fs::read_to_string(&f) {
            let id = id.trim().to_string();
            if (8..=64).contains(&id.len()) {
                return id;
            }
        }
        let id = format!("mac-{}", util::random_hex(12));
        let _ = std::fs::write(&f, &id);
        id
    }

    /// The pairing, when this computer was paired in Cookie: (gateway, key, project).
    fn paired_target(&self) -> Option<(String, String, String)> {
        let p: crate::pair::Paired = util::read_json(&self.paths.root.join("enkeon.json"));
        let (gateway, key) = crate::pair::gateway_and_key()?;
        (!p.project.is_empty() && !p.gateway.is_empty() && p.gateway.trim_end_matches('/') == gateway).then_some((gateway, key, p.project))
    }

    /// Allow (or stop) an agent running in the cloud while this Mac is off.
    pub async fn set_cloud_agent(&self, agent: &str, on: bool) -> Result<Value, String> {
        let rec = self.agent(agent).await?;
        self.update_settings(|s| {
            s.cloud.run_when_off.retain(|a| a != &rec.id);
            if on {
                s.cloud.run_when_off.push(rec.id.clone());
            }
        })
        .await?;
        Ok(self.cloud_status().await)
    }

    pub async fn cloud_status(&self) -> Value {
        let st: CloudState = util::read_json(&self.cloud_path());
        let s = self.settings().await;
        json!({
            "paired": self.paired_target().is_some(),
            "device": self.device_id(),
            "store": s.cloud.store,
            "run_when_off": s.cloud.run_when_off,
            "last_ok": (st.last_ok > 0).then_some(st.last_ok),
            "last_error": st.last_error,
        })
    }

    /// The agents that may run in the cloud, as the gateway reads them.
    async fn manifests(&self) -> Vec<Value> {
        let allowed = self.settings().await.cloud.run_when_off;
        let routines = self.routines.read().await.clone();
        self.agents()
            .await
            .into_iter()
            .filter(|a| allowed.contains(&a.id) && a.shadow_of.is_none() && !self.is_asleep(&a.id))
            .map(|a| {
                let rs: Vec<Value> = routines.iter().filter(|r| r.agent == a.id && !matches!(r.schedule, crate::store::Schedule::App { .. } | crate::store::Schedule::Webhook { .. })).map(|r| json!({"id": r.id, "task": r.task, "next_run": r.next_run, "enabled": r.enabled})).collect();
                json!({"id": a.id, "name": a.name, "job": a.job, "routines": rs})
            })
            .collect()
    }

    async fn cloud_tick(self: &Arc<Self>) {
        let Some((gateway, key, project)) = self.paired_target() else {
            FIRST_SYNC.store(true, Ordering::Relaxed);
            return;
        };
        let mut st: CloudState = util::read_json(&self.cloud_path());
        let r = self.cloud_round(&gateway, &key, &project, &mut st).await;
        match r {
            Ok(()) => {
                st.last_ok = util::now() as i64;
                st.last_error = None;
            }
            Err(e) => {
                tracing::info!(error = %e, "cloud: this round didn't go through; next minute");
                st.last_error = Some(e);
            }
        }
        let _ = util::write_json(&self.cloud_path(), &st);
        FIRST_SYNC.store(true, Ordering::Relaxed);
    }

    async fn cloud_round(self: &Arc<Self>, gateway: &str, key: &str, project: &str, st: &mut CloudState) -> Result<(), String> {
        let device = self.device_id();
        let base = format!("{gateway}/v1/projects/{project}/cookie/desktop");
        let host = std::process::Command::new("scutil").args(["--get", "ComputerName"]).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();
        // 1. On, and who may run while off.
        let body = json!({"device": device, "name": host, "version": env!("CARGO_PKG_VERSION"), "agents": self.manifests().await, "since": st.last_sync});
        let sync = post(&format!("{base}/sync"), key, &body).await?;
        st.last_sync = sync["now"].as_i64().unwrap_or(util::now() as i64);
        // The turns the cloud took: never run them again here.
        for f in sync["fired"].as_array().into_iter().flatten() {
            let (Some(routine), Some(due)) = (f["routine"].as_str(), f["due_at"].as_i64()) else { continue };
            self.cloud_took_turn(routine, due.max(0) as u64).await;
        }
        // 2. What ran in the cloud, into the record.
        let runs = get(&format!("{base}/runs?device={device}&since={}", st.last_runs), key).await?;
        let list: Vec<CloudRun> = serde_json::from_value(runs["runs"].clone()).unwrap_or_default();
        let mut held = false;
        for r in list {
            if st.seen_runs.contains(&r.run) {
                continue;
            }
            let Some(agent) = r.agent.clone() else { continue };
            if self.agent(&agent).await.is_err() {
                st.seen_runs.insert(r.run.clone()); // fired since
                continue;
            }
            // Mid-job: its conversation is in use; take this run on the next minute.
            if self.runs.lock().unwrap().contains_key(&agent) {
                held = true;
                continue;
            }
            st.seen_runs.insert(r.run.clone());
            if !held {
                st.last_runs = st.last_runs.max(r.finished_at.unwrap_or(0));
            }
            self.take_cloud_run(&agent, &r).await;
        }
        // Keep the seen set small: runs older than the last cursor never come back.
        if st.seen_runs.len() > 500 {
            let keep: Vec<String> = st.seen_runs.iter().rev().take(300).cloned().collect();
            st.seen_runs = keep.into_iter().collect();
        }
        // 3. The store.
        if self.settings().await.cloud.store {
            self.push_items(&base, key, &device, st).await?;
            let d = get(&format!("{base}/decisions?device={device}&since={}", st.last_decisions), key).await?;
            for x in d["decisions"].as_array().into_iter().flatten() {
                st.last_decisions = st.last_decisions.max(x["at"].as_i64().unwrap_or(0));
                let (Some(id), Some(yes)) = (x["id"].as_str(), x["yes"].as_bool()) else { continue };
                // Still waiting here? Then this is its answer.
                if self.answer(id, yes, "enkeon").is_ok() {
                    st.open_approvals.remove(id);
                }
            }
        } else {
            OUTBOX.lock().unwrap().items.clear();
        }
        Ok(())
    }

    async fn push_items(&self, base: &str, key: &str, device: &str, st: &mut CloudState) -> Result<(), String> {
        let mut items: Vec<Value> = std::mem::take(&mut OUTBOX.lock().unwrap().items);
        let pending = self.pending_approvals();
        let now_open: BTreeSet<String> = pending.iter().map(|a| a.id.clone()).collect();
        for a in &pending {
            if !st.open_approvals.contains(&a.id) {
                items.push(json!({"id": a.id, "kind": "approval", "agent": a.agent, "agent_name": a.agent_name, "title": format!("{} wants to {}", a.agent_name, a.tool), "body": util::clip(&format!("{}\n\n{}", a.preview, a.reason), BODY_CAP)}));
            }
        }
        // Answered here, or its job ended: closed in the store too.
        for gone in st.open_approvals.difference(&now_open) {
            items.push(json!({"id": gone, "kind": "approval", "state": "closed"}));
        }
        if items.is_empty() {
            return Ok(());
        }
        for chunk in items.chunks(150) {
            post(&format!("{base}/items"), key, &json!({"device": device, "items": chunk})).await.inspect_err(|_| {
                // Not lost: back in the outbox for the next minute (approvals are re-read anyway).
                OUTBOX.lock().unwrap().items.extend(chunk.iter().filter(|i| i["kind"] != "approval").cloned());
            })?;
        }
        st.open_approvals = now_open;
        Ok(())
    }

    /// The cloud took a routine's turn that came due while the Mac was off.
    async fn cloud_took_turn(&self, routine: &str, due: u64) {
        let mut rs = self.routines.write().await;
        if let Some(x) = rs.iter_mut().find(|x| x.id == routine) {
            if x.next_run.is_some_and(|n| n <= due) {
                x.last_run = Some(due);
                x.next_run = crate::routines::next_after(&x.schedule, util::now().max(due));
            }
        }
        let _ = self.save_routines(&rs).await;
    }

    /// A cloud run joins the agent's record and its conversation, and the person hears of it.
    async fn take_cloud_run(&self, agent: &str, r: &CloudRun) {
        let job = job_of(r, agent);
        let _ = util::append_jsonl(&self.paths.jobs(agent), &job);
        let note = format!(
            "While this Mac was off, you ran \"{}\" in Enkeon's cloud{}.\n\n{}",
            util::clip(&r.task, 200),
            if job.status == JobStatus::Done { "" } else { " and it didn't finish" },
            util::clip(if job.answer.is_empty() { r.error.as_deref().unwrap_or("") } else { &job.answer }, 6_000)
        );
        if let Ok(mut session) = cookie_harness::Session::open(self.paths.session(agent)).await {
            let _ = session.append(cookie_harness::Message::harness_note(note)).await;
        }
        let name = self.agent(agent).await.map(|a| a.name).unwrap_or_default();
        self.notice(agent, &format!("{name} worked in the cloud while your Mac was off"), &util::clip(&r.task, 160), Some(&r.run), false);
    }
}

async fn post(url: &str, key: &str, body: &Value) -> Result<Value, String> {
    let r = http().post(url).bearer_auth(key).json(body).send().await.map_err(|e| format!("Couldn't reach Enkeon: {e}"))?;
    answer(r).await
}

async fn get(url: &str, key: &str) -> Result<Value, String> {
    let r = http().get(url).bearer_auth(key).send().await.map_err(|e| format!("Couldn't reach Enkeon: {e}"))?;
    answer(r).await
}

async fn answer(r: reqwest::Response) -> Result<Value, String> {
    let status = r.status();
    let v: Value = r.json().await.unwrap_or(Value::Null);
    if !status.is_success() {
        let msg = v.pointer("/error/message").or(v.get("error")).or(v.get("message")).and_then(Value::as_str).map(str::to_string);
        return Err(msg.unwrap_or_else(|| format!("Enkeon answered {status}")));
    }
    Ok(match v {
        Value::Object(ref m) if m.contains_key("ok") && m.contains_key("data") => m["data"].clone(),
        v => v,
    })
}

/// The minute loop, and the outbox that hears notices and answers.
pub fn spawn(team: Arc<Team>) {
    let t = team.clone();
    let mut rx = team.subscribe();
    tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(ev) => {
                    if !t.settings().await.cloud.store {
                        continue;
                    }
                    let item = match ev {
                        TeamEvent::Notice { agent, title, body, job } => Some(json!({"id": format!("n-{}", util::random_hex(6)), "kind": "notice", "agent": agent, "title": title, "body": util::clip(&body, BODY_CAP), "job": job})),
                        TeamEvent::JobFinished { job, agent, status, answer, .. } if status == JobStatus::Done && !answer.trim().is_empty() => {
                            Some(json!({"id": job, "kind": "document", "agent": agent, "title": util::clip(answer.lines().next().unwrap_or(""), 120), "body": util::clip(&answer, BODY_CAP)}))
                        }
                        _ => None,
                    };
                    if let Some(i) = item {
                        let mut ob = OUTBOX.lock().unwrap();
                        ob.items.push(i);
                        let n = ob.items.len();
                        if n > 500 {
                            ob.items.drain(..n - 500);
                        }
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
    });
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(TICK);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tick.tick().await;
            team.cloud_tick().await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cloud_run_joins_the_record_as_a_cloud_job() {
        let r = CloudRun { run: "ck_1".into(), agent: Some("a".into()), routine: Some("r1".into()), due_at: Some(10), status: "done".into(), task: "Inbox".into(), answer: Some("3 new".into()), questions: None, error: None, started_at: Some(5), finished_at: Some(9) };
        let j = job_of(&r, "a");
        assert_eq!((j.status, j.place.as_deref(), j.finished_at), (JobStatus::Done, Some("cloud"), Some(9)));
        assert!(matches!(j.trigger, Trigger::Routine { ref routine } if routine == "r1"));
        let failed = job_of(&CloudRun { answer: None, error: Some("credits".into()), ..r }, "a");
        assert_eq!(failed.status, JobStatus::Failed, "no answer is no success");
    }

    #[tokio::test]
    async fn a_turn_the_cloud_took_is_not_run_again_here() {
        let dir = tempfile::tempdir().unwrap();
        let t = Team::open(dir.path()).unwrap();
        let r = crate::store::Routine { id: "r1".into(), agent: "a".into(), task: "x".into(), schedule: crate::store::Schedule::Day { at: "08:00".into() }, enabled: true, created_at: 0, last_run: None, next_run: Some(100), workflow: None };
        t.routines.write().await.push(r);
        t.cloud_took_turn("r1", 100).await;
        let x = t.routines.read().await[0].clone();
        assert_eq!(x.last_run, Some(100));
        assert!(x.next_run.unwrap() > util::now(), "moved to its next turn");
    }

    #[test]
    fn a_device_id_is_made_once() {
        let dir = tempfile::tempdir().unwrap();
        let t = Team::open(dir.path()).unwrap();
        let a = t.device_id();
        assert!(a.starts_with("mac-") && a == t.device_id());
    }
}
