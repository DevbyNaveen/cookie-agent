//! Working with the person mid-job, and undoing what an agent changed.
//!
//! - `ask_person`: a question with choices (or a free answer). The job waits
//!   for the answer, shown as a card in the chat (its row moves up with an amber count), and on Telegram.
//! - `todo_list`: the agent's plan for a long job, shown live as a checklist.
//! - Checkpoints: before a job that may change files, the agent's folder is
//!   copied aside; the person can put it back the way it was ("Undo").
//!
//! Adapted from Hermes Agent's clarify and todo tools and its checkpoints
//! (MIT, Nous Research), and pi's per-turn git checkpoint (MIT).

use std::path::Path;
use std::sync::{Arc, Weak};
use std::time::Duration;

use cookie_harness::tool::{tool, Effect, Tool};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::events::TeamEvent;
use crate::store::Trigger;
use crate::{util, Team};

/// How long a question waits for the person before the job carries on without.
const ASK_WAIT: Duration = Duration::from_secs(30 * 60);
/// Checkpoints kept per agent, and the most a checkpoint may copy.
const KEEP: usize = 15;
const MAX_BYTES: u64 = 200 * 1024 * 1024;
const MAX_FILE: u64 = 20 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Question {
    pub id: String,
    pub agent: String,
    pub agent_name: String,
    pub question: String,
    pub choices: Vec<String>,
    pub asked_at: u64,
}

pub(crate) struct PendingQuestion {
    pub question: Question,
    pub answer: tokio::sync::oneshot::Sender<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Todo {
    pub text: String,
    /// `pending`, `doing`, or `done`.
    pub state: String,
}

impl Team {
    pub fn questions(&self) -> Vec<Question> {
        let mut v: Vec<Question> = self.questions.lock().unwrap().values().map(|p| p.question.clone()).collect();
        v.sort_by_key(|q| q.asked_at);
        v
    }

    pub fn answer_question(&self, id: &str, answer: &str, by: &str) -> Result<(), String> {
        let p = self.questions.lock().unwrap().remove(id).ok_or("That question was already answered.")?;
        let answer = answer.trim().to_string();
        if answer.is_empty() {
            self.questions.lock().unwrap().insert(id.to_string(), p);
            return Err("Write an answer, or pick one.".into());
        }
        let _ = p.answer.send(answer.clone());
        self.emit(TeamEvent::Answered { id: id.to_string(), agent: p.question.agent.clone(), yes: true, by: by.to_string() });
        Ok(())
    }

    pub fn todos(&self, agent: &str) -> Vec<Todo> {
        self.todo_lists.lock().unwrap().get(agent).cloned().unwrap_or_default()
    }

    /* ---------- checkpoints ---------- */

    fn checkpoints_dir(&self, id: &str) -> std::path::PathBuf {
        self.paths.agent(id).join("checkpoints")
    }

    /// Copy the agent's folder aside before a job (when anything is in it).
    pub(crate) fn checkpoint(&self, id: &str, job: &str) {
        let work = self.paths.work(id);
        let mut files = Vec::new();
        collect(&work, &work, &mut files);
        if files.is_empty() {
            return;
        }
        let total: u64 = files.iter().map(|(_, n)| *n).sum();
        if total > MAX_BYTES {
            tracing::warn!("{id}: folder too large to checkpoint ({total} bytes)");
            return;
        }
        let dst = self.checkpoints_dir(id).join(job);
        for (rel, _) in &files {
            let to = dst.join(rel);
            if let Some(p) = to.parent() {
                let _ = std::fs::create_dir_all(p);
            }
            // A real copy: a file edited in place must not change its checkpoint too.
            let _ = std::fs::copy(work.join(rel), &to);
        }
        let _ = util::write_json(&dst.with_extension("json"), &json!({"job": job, "at": util::now(), "files": files.len()}));
        // Keep the newest few.
        let mut all: Vec<(u64, String)> = std::fs::read_dir(self.checkpoints_dir(id))
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .filter_map(|e| {
                let v: Value = util::read_json(&e.path());
                Some((v["at"].as_u64()?, v["job"].as_str()?.to_string()))
            })
            .collect();
        all.sort();
        while all.len() > KEEP {
            let (_, old) = all.remove(0);
            let _ = std::fs::remove_dir_all(self.checkpoints_dir(id).join(&old));
            let _ = std::fs::remove_file(self.checkpoints_dir(id).join(format!("{old}.json")));
        }
    }

    /// Checkpoints, newest first, with what changed in the folder since each.
    pub fn checkpoints(&self, id: &str) -> Vec<Value> {
        let work = self.paths.work(id);
        let mut now_files = Vec::new();
        collect(&work, &work, &mut now_files);
        let mut out: Vec<Value> = std::fs::read_dir(self.checkpoints_dir(id))
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .filter_map(|e| {
                let v: Value = util::read_json(&e.path());
                let job = v["job"].as_str()?.to_string();
                let dir = self.checkpoints_dir(id).join(&job);
                let mut then = Vec::new();
                collect(&dir, &dir, &mut then);
                let changed = diff(&work, &now_files, &dir, &then);
                Some(json!({"job": job, "at": v["at"], "files": then.len(), "changed": changed}))
            })
            .collect();
        out.sort_by(|a, b| b["at"].as_u64().cmp(&a["at"].as_u64()));
        out
    }

    /// Put the folder back the way it was before `job`. What is there now is
    /// kept as a checkpoint of its own, so the undo can be undone.
    pub fn restore_checkpoint(&self, id: &str, job: &str) -> Result<Vec<String>, String> {
        if job.contains('/') || job.contains("..") {
            return Err("No such checkpoint.".into());
        }
        if self.runs.lock().unwrap().contains_key(id) {
            return Err("It's working right now. Stop it first, then undo.".into());
        }
        let snap = self.checkpoints_dir(id).join(job);
        if !snap.is_dir() {
            return Err("That checkpoint is gone.".into());
        }
        let work = self.paths.work(id);
        let mut now_files = Vec::new();
        collect(&work, &work, &mut now_files);
        let mut then = Vec::new();
        collect(&snap, &snap, &mut then);
        let changed = diff(&work, &now_files, &snap, &then);
        self.checkpoint(id, &format!("undo-{}", util::now()));
        let _ = std::fs::remove_dir_all(&work);
        std::fs::create_dir_all(&work).map_err(|e| e.to_string())?;
        for (rel, _) in &then {
            let to = work.join(rel);
            if let Some(p) = to.parent() {
                std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
            }
            std::fs::copy(snap.join(rel), &to).map_err(|e| e.to_string())?;
        }
        Ok(changed)
    }
}

fn collect(root: &Path, dir: &Path, out: &mut Vec<(String, u64)>) {
    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = e.path();
        let Ok(meta) = std::fs::symlink_metadata(&p) else { continue };
        if meta.file_type().is_symlink() {
            continue;
        }
        if meta.is_dir() {
            collect(root, &p, out);
        } else if meta.len() <= MAX_FILE {
            if let Ok(rel) = p.strip_prefix(root) {
                out.push((rel.to_string_lossy().to_string(), meta.len()));
            }
        }
    }
}

/// Files added, removed or changed between a checkpoint and now.
fn diff(work: &Path, now: &[(String, u64)], snap: &Path, then: &[(String, u64)]) -> Vec<String> {
    let mut out = Vec::new();
    for (rel, _) in now {
        match then.iter().find(|(r, _)| r == rel) {
            None => out.push(format!("added {rel}")),
            Some(_) => {
                if std::fs::read(work.join(rel)).ok() != std::fs::read(snap.join(rel)).ok() {
                    out.push(format!("changed {rel}"));
                }
            }
        }
    }
    for (rel, _) in then {
        if !now.iter().any(|(r, _)| r == rel) {
            out.push(format!("removed {rel}"));
        }
    }
    out
}

/* ---------- tools ---------- */

pub(crate) fn tools(team: &Arc<Team>, agent: &str, agent_name: &str, trigger: &Trigger) -> Vec<Arc<dyn Tool>> {
    let mut out: Vec<Arc<dyn Tool>> = vec![Arc::new(todo_tool(Arc::downgrade(team), agent.to_string()))];
    // A board the person can watch: never for someone else's agent or a test run.
    if !matches!(trigger, Trigger::Contact { .. } | Trigger::Room { .. } | Trigger::Peer { .. } | Trigger::Test { .. } | Trigger::Shadow { .. } | Trigger::Prep { .. }) {
        out.push(crate::boards::board_tool(Arc::downgrade(team), agent.to_string()));
    }
    // Someone outside can't make the agent question the person.
    if !matches!(trigger, Trigger::Contact { .. } | Trigger::Room { .. } | Trigger::Peer { .. } | Trigger::Test { .. } | Trigger::Shadow { .. }) {
        out.push(Arc::new(ask_tool(Arc::downgrade(team), agent.to_string(), agent_name.to_string())));
    }
    out
}

fn ask_tool(team: Weak<Team>, agent: String, agent_name: String) -> impl Tool {
    tool(
        "ask_person",
        "Ask the person you work for a question and wait for the answer: when a choice is theirs to make, or something you need \
         isn't anywhere you can look. Offer 2 to 5 short choices when the answer is one of a few; they can also write their own. \
         Don't ask what you can find out yourself, and don't ask permission for an action (making the call asks for you).",
        json!({"type": "object", "properties": {
            "question": {"type": "string"},
            "choices": {"type": "array", "items": {"type": "string"}, "maxItems": 5}
        }, "required": ["question"]}),
        Effect::Read,
        move |args: Value| {
            let (team, agent, agent_name) = (team.clone(), agent.clone(), agent_name.clone());
            async move {
                let team = team.upgrade().ok_or("Cookie is closing.")?;
                let question = args["question"].as_str().unwrap_or_default().trim().to_string();
                if question.is_empty() {
                    return Err("Ask a question.".into());
                }
                let choices: Vec<String> = args["choices"].as_array().into_iter().flatten().filter_map(|c| c.as_str()).map(|c| util::clip(c.trim(), 120)).filter(|c| !c.is_empty()).take(5).collect();
                let q = Question { id: util::new_id("q"), agent: agent.clone(), agent_name: agent_name.clone(), question: util::clip(&question, 1000), choices, asked_at: util::now() };
                let (tx, rx) = tokio::sync::oneshot::channel();
                team.questions.lock().unwrap().insert(q.id.clone(), PendingQuestion { question: q.clone(), answer: tx });
                team.emit(TeamEvent::Question { question: q.clone() });
                team.notice(&agent, &format!("{agent_name} has a question"), &util::clip(&q.question, 200), None, true);
                // A job you started by mail asks by mail too; the app and your linked chats still show it.
                team.mail_question(&q).await;
                let id = q.id.clone();
                match tokio::time::timeout(ASK_WAIT, rx).await {
                    Ok(Ok(answer)) => Ok(format!("The person answered: {answer}")),
                    _ => {
                        team.questions.lock().unwrap().remove(&id);
                        team.emit(TeamEvent::Answered { id, agent, yes: false, by: "timeout".into() });
                        Ok("The person didn't answer within 30 minutes. Carry on with what doesn't depend on it, and say what's still open.".into())
                    }
                }
            }
        },
    )
}

fn todo_tool(team: Weak<Team>, agent: String) -> impl Tool {
    tool(
        "todo_list",
        "Your plan for a job with several steps, shown to the person as a live checklist. Pass the whole list each time \
         (each item: text, and state pending, doing or done); call it without `todos` to read it. Keep one item `doing` at a time.",
        json!({"type": "object", "properties": {
            "todos": {"type": "array", "items": {"type": "object", "properties": {
                "text": {"type": "string"},
                "state": {"type": "string", "enum": ["pending", "doing", "done"]}
            }, "required": ["text", "state"]}}
        }}),
        Effect::Read,
        move |args: Value| {
            let (team, agent) = (team.clone(), agent.clone());
            async move {
                let team = team.upgrade().ok_or("Cookie is closing.")?;
                if let Some(items) = args["todos"].as_array() {
                    let list: Vec<Todo> = items
                        .iter()
                        .take(30)
                        .filter_map(|t| {
                            let text = util::clip(t["text"].as_str()?.trim(), 200);
                            let state = t["state"].as_str().filter(|s| matches!(*s, "pending" | "doing" | "done")).unwrap_or("pending").to_string();
                            (!text.is_empty()).then_some(Todo { text, state })
                        })
                        .collect();
                    team.todo_lists.lock().unwrap().insert(agent.clone(), list.clone());
                    team.emit(TeamEvent::Todos { agent: agent.clone(), items: list });
                }
                let list = team.todos(&agent);
                if list.is_empty() {
                    return Ok("No plan yet.".into());
                }
                Ok(list.iter().map(|t| format!("[{}] {}", match t.state.as_str() { "done" => "x", "doing" => ">", _ => " " }, t.text)).collect::<Vec<_>>().join("\n"))
            }
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diff_sees_added_changed_and_removed() {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        std::fs::write(a.path().join("same.md"), "x").unwrap();
        std::fs::write(b.path().join("same.md"), "x").unwrap();
        std::fs::write(a.path().join("edit.md"), "new").unwrap();
        std::fs::write(b.path().join("edit.md"), "old").unwrap();
        std::fs::write(a.path().join("added.md"), "+").unwrap();
        std::fs::write(b.path().join("gone.md"), "-").unwrap();
        let (mut now, mut then) = (Vec::new(), Vec::new());
        collect(a.path(), a.path(), &mut now);
        collect(b.path(), b.path(), &mut then);
        let mut d = diff(a.path(), &now, b.path(), &then);
        d.sort();
        assert_eq!(d, vec!["added added.md", "changed edit.md", "removed gone.md"]);
    }
}
