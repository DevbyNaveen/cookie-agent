//! Waking an agent by attention when its memory changes.
//!
//! With Enkeon connected (paired, the CLI's sign-in, or `ENKEON_API_KEY`),
//! Cookie keeps one live connection to the brain's write stream
//! (`/engine/api/v1/ws/main/activity/stream`, the same stream the Console's
//! Activity tab and Enkeon's own Cookie read). Each write is handed to the
//! harness's attention ([`cookie_harness::attention`]) exactly as Enkeon's
//! Cookie hands it: who may cause a notice, salience per subject with decay
//! and habituation, then the gate. Nothing here calls a model until a subject
//! is noticed.
//!
//! - **Whose write.** A write into an agent's own space (`cookie-agent-<id>`)
//!   is that agent's; a write to `main` (the person's shared material) is
//!   Cookie's, the agent everyone has. Writes to the person's other spaces
//!   wake nobody. A write any Cookie agent made (`via` the harness) never
//!   wakes anyone: a run must not wake on what it wrote.
//! - **What it does.** A noticed subject starts one job for its agent, in its
//!   own conversation (`Trigger::Memory`), with the notice's words: what
//!   changed, why now, and the one question it raises. Approvals work as for
//!   any job. An asleep agent is not woken; the notice waits.
//! - **Caps.** The harness's own daily cap per agent, plus the person's
//!   switch (`Settings.wake`, on by default) and the agent's memory grant.
//! - **Labels.** Each wake can be labelled useful / not useful / wrong; the
//!   harness halves that kind of signal on that subject for a not useful, and
//!   raises the bar when wakes stop being useful.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use cookie_harness::attention::{self, Subject, Verdict};
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::store::Trigger;
use crate::{util, Team};

/// How often waiting subjects are scored again (they fire once quiet).
const TICK: Duration = Duration::from_secs(120);

/// One wake, as kept in `wakes.jsonl`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Wake {
    pub id: String,
    pub agent: String,
    pub subject: String,
    pub title: String,
    pub why: String,
    pub question: Option<String>,
    pub cue_kinds: Vec<String>,
    pub job: Option<String>,
    pub at: u64,
    /// useful · not_useful · wrong; None until the person says.
    pub label: Option<String>,
    /// Held: the agent was asleep or busy; it runs when it can.
    pub held: bool,
}

fn now_f() -> f64 {
    util::now() as f64
}

/// The agent a write belongs to: its own space, or Cookie for `main`.
pub fn owner_of(branch: &str, agents: &[(String, bool)]) -> Option<String> {
    let b = branch.trim();
    if b.is_empty() || b == "main" {
        return agents.iter().find(|(id, mem)| id == crate::front::COOKIE_ID && *mem).map(|(id, _)| id.clone());
    }
    agents.iter().find(|(id, mem)| *mem && crate::memory::space_of(id) == b).map(|(id, _)| id.clone())
}

/// The words a woken agent starts from.
pub fn wake_text(n: &attention::Notice) -> String {
    let mut s = format!("Something changed in your memory: {}\n\n{}", n.title, attention::why_now(n));
    let cues: Vec<String> = n.cues.iter().take(6).map(|c| format!("- {}", c.why)).collect();
    if !cues.is_empty() {
        s.push_str("\n\nWhat changed:\n");
        s.push_str(&cues.join("\n"));
    }
    if let Some(q) = &n.question {
        s.push_str(&format!("\n\nThe question it raises: {q}"));
    }
    s.push_str("\n\nDecide whether there is something to do for the person about this. If there is, do it (asking where you must); if not, say in one line why not.");
    s
}

impl Team {
    fn attention_path(&self, agent: &str) -> std::path::PathBuf {
        self.paths.agent(agent).join("attention.json")
    }

    fn wakes_path(&self) -> std::path::PathBuf {
        self.paths.root.join("wakes.jsonl")
    }

    fn subjects(&self, agent: &str) -> BTreeMap<String, Subject> {
        util::read_json(&self.attention_path(agent))
    }

    fn save_subjects(&self, agent: &str, s: &BTreeMap<String, Subject>) {
        let _ = util::write_json(&self.attention_path(agent), s);
    }

    pub fn wakes(&self) -> Vec<Wake> {
        let mut w: Vec<Wake> = util::read_jsonl(&self.wakes_path());
        w.reverse();
        w.truncate(100);
        w
    }

    /// The harness's view of how wakes have gone for one agent.
    fn wake_team(&self, agent: &str) -> attention::Team {
        let all: Vec<Wake> = util::read_jsonl(&self.wakes_path());
        let mine: Vec<&Wake> = all.iter().filter(|w| w.agent == agent).collect();
        let labelled: Vec<&&Wake> = mine.iter().rev().filter(|w| w.label.is_some()).take(50).collect();
        let now = util::now();
        attention::Team {
            labelled: labelled.len() as i64,
            useful: labelled.iter().filter(|w| w.label.as_deref() == Some("useful")).count() as i64,
            open: mine.iter().filter(|w| w.label.is_none() && now.saturating_sub(w.at) < 7 * 86_400).count(),
            noticed_today: mine.iter().filter(|w| now.saturating_sub(w.at) < 86_400).count() as i64,
        }
    }

    /// The person's label on a wake: it tunes what wakes that agent next time.
    pub fn label_wake(&self, id: &str, label: &str) -> Result<(), String> {
        if !matches!(label, "useful" | "not_useful" | "wrong") {
            return Err("A label is useful, not_useful or wrong.".into());
        }
        let mut all: Vec<Wake> = util::read_jsonl(&self.wakes_path());
        let w = all.iter_mut().find(|w| w.id == id).ok_or("No such wake.")?;
        w.label = Some(label.into());
        let (agent, subject, kinds) = (w.agent.clone(), w.subject.clone(), w.cue_kinds.clone());
        util::write_jsonl(&self.wakes_path(), &all)?;
        let mut subs = self.subjects(&agent);
        if let Some(s) = subs.get_mut(&subject) {
            attention::label(s, &kinds, label, now_f());
            self.save_subjects(&agent, &subs);
        }
        Ok(())
    }

    async fn wake_agents(&self) -> Vec<(String, bool)> {
        self.agents().await.into_iter().filter(|a| a.shadow_of.is_none()).map(|a| (a.id, a.grants.memory)).collect()
    }

    /// One write from the stream.
    async fn on_memory_write(self: &Arc<Self>, gateway: &str, key: &str, event: &Value) {
        let verb = event["verb"].as_str().unwrap_or("");
        if !matches!(verb, "remember" | "update" | "ingest") || event["ok"] != true || attention::by_cookie(event) {
            return;
        }
        if !self.settings().await.wake {
            return;
        }
        let event_branch = event["branch"].as_str().unwrap_or("main").to_string();
        let agents = self.wake_agents().await;
        let ids: Vec<String> = event.pointer("/detail/ids").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).take(5).map(str::to_string).collect()).unwrap_or_default();
        let outside = attention::from_outside(event);
        // Who wrote it: the tool, as the stream names it (the person's name is the gateway's to look up).
        let by = event["via"].as_str().unwrap_or("").to_string();
        for id in ids {
            let Some(face) = memory_face(gateway, key, &id).await else { continue };
            let own = attention::branch_in(face["source_uri"].as_str().unwrap_or(""));
            let branch = if own == "main" { event_branch.clone() } else { own };
            let Some(agent) = owner_of(&branch, &agents) else { continue };
            let about: Vec<String> = face["about"].as_array().map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default();
            let write = attention::Write {
                id: id.clone(),
                kind: face["kind"].as_str().unwrap_or("fact").into(),
                weight: face["weight"].as_str().map(str::to_string),
                feeling: face["feeling"].as_str().map(str::to_string),
                revises: face["version"].as_i64().unwrap_or(1) > 1,
                name: face["name"].as_str().unwrap_or("").into(),
                about: about.clone(),
                branch: branch.clone(),
                outside,
                by_person: !outside,
                by: by.clone(),
            };
            let now = now_f();
            let signal = attention::signal_of(&write, &[], now);
            let mut subs = self.subjects(&agent);
            let (key, _) = attention::subject_of(&branch, &about);
            let s = subs.entry(key).or_insert_with(|| Subject::new(&branch, &about, now));
            attention::add(s, signal, now);
            self.save_subjects(&agent, &subs);
        }
    }

    /// Score every waiting subject of every agent; wake the ones noticed.
    async fn consider_wakes(self: &Arc<Self>) {
        if !self.settings().await.wake {
            return;
        }
        let busy: Vec<String> = self.busy().into_iter().map(|(a, _)| a).collect();
        for (agent, memory) in self.wake_agents().await {
            if !memory {
                continue;
            }
            let asleep = self.is_asleep(&agent);
            // Held wakes first: an agent that was asleep or busy gets them once it can work.
            if !asleep && !busy.contains(&agent) {
                self.run_held_wake(&agent).await;
            }
            let mut subs = self.subjects(&agent);
            if subs.is_empty() {
                continue;
            }
            let team = self.wake_team(&agent);
            let now = now_f();
            let mut changed = false;
            for s in subs.values_mut() {
                if s.pending_since.is_none() {
                    continue;
                }
                changed = true;
                if let Verdict::Notice(n) = attention::consider(s, &team, now) {
                    let held = asleep || busy.contains(&agent);
                    self.wake(&agent, n, held).await;
                }
            }
            if changed {
                self.save_subjects(&agent, &subs);
            }
        }
    }

    async fn wake(self: &Arc<Self>, agent: &str, n: attention::Notice, held: bool) {
        let mut w = Wake {
            id: util::random_hex(8),
            agent: agent.into(),
            subject: n.subject.clone(),
            title: n.title.clone(),
            why: attention::why_now(&n),
            question: n.question.clone(),
            cue_kinds: n.cues.iter().map(|c| c.kind.clone()).collect(),
            job: None,
            at: util::now(),
            label: None,
            held,
        };
        let text = wake_text(&n);
        if !held {
            match self.start_job(agent, text.clone(), Vec::new(), Trigger::Memory { subject: n.subject.clone() }).await {
                Ok(job) => w.job = Some(job),
                Err(e) => {
                    tracing::info!(agent, error = %e, "wake: couldn't start the job; holding it");
                    w.held = true;
                }
            }
        }
        if w.held {
            let _ = util::write_json(&self.paths.agent(agent).join("held-wake.json"), &(w.id.clone(), text));
        }
        let _ = util::append_jsonl(&self.wakes_path(), &w);
        // Within the person's daily cap on interruptions, like any other news.
        self.notice(agent, &format!("Woke: {}", n.title), &w.why, w.job.as_deref(), false);
    }

    /// A wake that was held while the agent slept or worked.
    async fn run_held_wake(self: &Arc<Self>, agent: &str) {
        let f = self.paths.agent(agent).join("held-wake.json");
        let Ok(raw) = std::fs::read_to_string(&f) else { return };
        let _ = std::fs::remove_file(&f);
        let Ok((id, text)) = serde_json::from_str::<(String, String)>(&raw) else { return };
        let subject = {
            let all: Vec<Wake> = util::read_jsonl(&self.wakes_path());
            all.iter().find(|w| w.id == id).map(|w| w.subject.clone()).unwrap_or_default()
        };
        if let Ok(job) = self.start_job(agent, text, Vec::new(), Trigger::Memory { subject }).await {
            let mut all: Vec<Wake> = util::read_jsonl(&self.wakes_path());
            if let Some(w) = all.iter_mut().find(|w| w.id == id) {
                w.job = Some(job);
                w.held = false;
            }
            let _ = util::write_jsonl(&self.wakes_path(), &all);
        }
    }

    pub fn wake_status(&self) -> Value {
        serde_json::json!({
            "stream": WATCHING.lock().map(|g| g.clone()).unwrap_or_default(),
            "wakes": self.wakes().into_iter().take(30).collect::<Vec<_>>(),
        })
    }
}

/// What the stream is doing, for the person: watching · off (no Enkeon) · reconnecting.
static WATCHING: std::sync::LazyLock<std::sync::Mutex<String>> = std::sync::LazyLock::new(|| std::sync::Mutex::new("off".into()));

fn set_watching(s: &str) {
    if let Ok(mut g) = WATCHING.lock() {
        *g = s.into();
    }
}

fn stream_client() -> &'static reqwest::Client {
    static C: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    C.get_or_init(|| reqwest::Client::builder().connect_timeout(Duration::from_secs(10)).build().unwrap_or_default())
}

/// A memory's face (name, kind, about, weight, feeling, version, source_uri).
async fn memory_face(gateway: &str, key: &str, id: &str) -> Option<Value> {
    let enc: String = id.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect();
    let r = stream_client().get(format!("{gateway}/engine/api/v1/ws/main/memories/{enc}")).bearer_auth(key).timeout(Duration::from_secs(10)).send().await.ok()?;
    if !r.status().is_success() {
        return None;
    }
    let v: Value = r.json().await.ok()?;
    let v = v.get("data").cloned().unwrap_or(v);
    v.get("face").filter(|f| f.is_object()).cloned()
}

/// Keep the stream open while Enkeon is connected, and score subjects on a tick.
pub fn spawn(team: Arc<Team>) {
    // The tick: waiting subjects fire once their writes go quiet.
    let t = team.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(TICK);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tick.tick().await;
            t.consider_wakes().await;
        }
    });
    tokio::spawn(async move {
        let mut backoff = Duration::from_secs(5);
        loop {
            let Some((gateway, key)) = crate::pair::gateway_and_key() else {
                set_watching("off");
                tokio::time::sleep(Duration::from_secs(30)).await;
                continue;
            };
            set_watching("connecting");
            match watch_once(&team, &gateway, &key).await {
                Ok(()) => backoff = Duration::from_secs(5),
                Err(e) => {
                    tracing::info!(error = %e, "wake: the memory stream was lost; reconnecting");
                    backoff = (backoff * 2).min(Duration::from_secs(300));
                }
            }
            set_watching("reconnecting");
            tokio::time::sleep(backoff).await;
        }
    });
}

async fn watch_once(team: &Arc<Team>, gateway: &str, key: &str) -> Result<(), String> {
    let resp = stream_client().get(format!("{gateway}/engine/api/v1/ws/main/activity/stream")).bearer_auth(key).header("accept", "text/event-stream").send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("Enkeon answered {}", resp.status()));
    }
    set_watching("watching");
    let mut body = resp.bytes_stream();
    let mut buf = String::new();
    while let Some(chunk) = body.next().await {
        buf.push_str(&String::from_utf8_lossy(&chunk.map_err(|e| e.to_string())?));
        while let Some(end) = buf.find('\n') {
            let line: String = buf.drain(..=end).collect();
            if let Some(data) = line.trim_end().strip_prefix("data:") {
                if let Ok(event) = serde_json::from_str::<Value>(data.trim()) {
                    team.on_memory_write(gateway, key, &event).await;
                }
            }
        }
        // A pairing that changed under the stream: reconnect with the new key.
        if crate::pair::gateway_and_key().as_ref().map(|(g, k)| (g.as_str(), k.as_str())) != Some((gateway, key)) {
            return Ok(());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_write_wakes_the_agent_whose_space_it_is_in() {
        let agents = vec![(crate::front::COOKIE_ID.to_string(), true), ("a1".into(), true), ("a2".into(), false)];
        assert_eq!(owner_of("main", &agents).as_deref(), Some(crate::front::COOKIE_ID));
        assert_eq!(owner_of(&crate::memory::space_of("a1"), &agents).as_deref(), Some("a1"));
        assert_eq!(owner_of(&crate::memory::space_of("a2"), &agents), None, "no memory grant, no wake");
        assert_eq!(owner_of("acme-client", &agents), None, "the person's other spaces wake nobody");
    }

    #[test]
    fn a_wake_says_what_changed_and_asks_for_a_decision() {
        let n = attention::Notice { title: "Pricing".into(), cues: vec![attention::Signal { why: "Price moved to 12".into(), kind: "decision".into(), ..Default::default() }], question: Some("Tell Mara?".into()), ..Default::default() };
        let t = wake_text(&n);
        assert!(t.contains("Pricing") && t.contains("- Price moved to 12") && t.contains("Tell Mara?"));
    }

    #[tokio::test]
    async fn a_label_tunes_the_subject_and_bad_labels_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let t = Team::open(dir.path()).unwrap();
        let w = Wake { id: "w1".into(), agent: "a".into(), subject: "main|x".into(), cue_kinds: vec!["decision".into()], at: util::now(), ..Default::default() };
        util::append_jsonl(&t.wakes_path(), &w).unwrap();
        assert!(t.label_wake("w1", "meh").is_err());
        t.label_wake("w1", "useful").unwrap();
        assert_eq!(t.wakes()[0].label.as_deref(), Some("useful"));
        assert_eq!(t.wake_team("a").useful, 1);
    }
}
