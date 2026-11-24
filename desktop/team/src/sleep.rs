//! Sleep, wake and snapshots: an agent you can put down and pick up again.
//!
//! **Sleep.** An asleep agent does nothing on its own: no job starts for it
//! (chat, channels, handoffs), its routines skip their turns, and a wake from
//! its memory is held until it is awake. Its folder, conversation and record
//! stay exactly as they were. Putting it to sleep takes a snapshot first.
//!
//! **Snapshots.** A snapshot is the agent's working state at one moment: its
//! own folder, its conversation, its notes and skills, its lessons, recipes and
//! attention. On a Mac it is an APFS clone (`cp -c`: `clonefile(2)`), so it
//! costs almost nothing until files change; elsewhere a plain copy. Restoring
//! puts that state back, after taking a snapshot of the present one, so a
//! restore can itself be undone.
//!
//! **What a snapshot never rolls back.** The record of what the agent did: its
//! jobs (its rank and scorecard read them), its signed trace, its action
//! ledger, what it earned, the memories it saved to Enkeon (they live there),
//! and the changes it made to your files (put back from Changes instead).
//! Rolling those back would let a restore rewrite history.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::{util, Team};

/// What a snapshot holds, relative to the agent's folder.
pub const STATE: &[&str] = &["work", "session.jsonl", "NOTES.md", "skills", "lessons.json", "procedures.json", "attention.json"];
/// Snapshots kept per agent; the oldest go first.
pub const KEEP: usize = 12;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Asleep {
    pub since: u64,
    pub snapshot: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Snapshot {
    pub id: String,
    pub agent: String,
    pub at: u64,
    /// What it was for: "before sleep", "before restore", "you", "daily".
    pub why: String,
    pub bytes: u64,
    pub items: Vec<String>,
}

/// Copy `src` to `dst`: an APFS clone on a Mac (instant, shares blocks), a copy elsewhere.
pub fn clone_path(src: &Path, dst: &Path) -> Result<(), String> {
    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("/bin/cp").arg("-c").arg("-R").arg("-p").arg(src).arg(dst).output().map_err(|e| e.to_string())?;
        if out.status.success() {
            return Ok(());
        }
        // Not APFS (an external disk): fall through to a plain copy.
        tracing::info!(stderr = %String::from_utf8_lossy(&out.stderr), "snapshot: clone failed; copying");
    }
    copy_tree(src, dst)
}

fn copy_tree(src: &Path, dst: &Path) -> Result<(), String> {
    let meta = std::fs::symlink_metadata(src).map_err(|e| e.to_string())?;
    if meta.file_type().is_symlink() {
        return Ok(()); // never followed: a link could point anywhere
    }
    if meta.is_dir() {
        std::fs::create_dir_all(dst).map_err(|e| e.to_string())?;
        for e in std::fs::read_dir(src).map_err(|e| e.to_string())?.flatten() {
            copy_tree(&e.path(), &dst.join(e.file_name()))?;
        }
        Ok(())
    } else {
        std::fs::copy(src, dst).map(|_| ()).map_err(|e| e.to_string())
    }
}

fn size_of(p: &Path) -> u64 {
    let Ok(meta) = std::fs::symlink_metadata(p) else { return 0 };
    if meta.is_dir() {
        std::fs::read_dir(p).into_iter().flatten().flatten().map(|e| size_of(&e.path())).sum()
    } else {
        meta.len()
    }
}

fn remove(p: &Path) {
    let _ = if p.is_dir() { std::fs::remove_dir_all(p) } else { std::fs::remove_file(p) };
}

impl Team {
    fn asleep_path(&self, agent: &str) -> PathBuf {
        self.paths.agent(agent).join("asleep.json")
    }

    fn snapshots_dir(&self, agent: &str) -> PathBuf {
        self.paths.root.join("snapshots").join(agent)
    }

    pub fn is_asleep(&self, agent: &str) -> bool {
        self.asleep_path(agent).exists()
    }

    pub fn asleep(&self, agent: &str) -> Option<Asleep> {
        self.is_asleep(agent).then(|| util::read_json(&self.asleep_path(agent)))
    }

    /// Put an agent to sleep: a snapshot, then nothing runs for it until it wakes.
    pub async fn sleep_agent(&self, agent: &str) -> Result<Asleep, String> {
        let rec = self.agent(agent).await?;
        if self.runs.lock().unwrap().contains_key(agent) {
            return Err(format!("{} is working. Stop the job or let it finish, then put it to sleep.", rec.name));
        }
        if let Some(a) = self.asleep(agent) {
            return Ok(a);
        }
        let snap = self.snapshot(agent, "before sleep")?;
        let a = Asleep { since: util::now(), snapshot: Some(snap.id) };
        util::write_json(&self.asleep_path(agent), &a)?;
        self.emit(crate::events::TeamEvent::RosterChanged);
        Ok(a)
    }

    /// Wake it: its routines and held wakes run again from their next turn.
    pub async fn wake_agent(&self, agent: &str) -> Result<(), String> {
        self.agent(agent).await?;
        remove(&self.asleep_path(agent));
        self.emit(crate::events::TeamEvent::RosterChanged);
        Ok(())
    }

    /// Take a snapshot of an agent's working state now.
    pub fn snapshot(&self, agent: &str, why: &str) -> Result<Snapshot, String> {
        let from = self.paths.agent(agent);
        if !from.exists() {
            return Err("No such agent.".into());
        }
        let id = format!("{}-{}", util::now(), util::random_hex(3));
        let dir = self.snapshots_dir(agent).join(&id);
        let tmp = self.snapshots_dir(agent).join(format!(".{id}.partial"));
        std::fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
        let mut items = Vec::new();
        for name in STATE {
            let src = from.join(name);
            if src.exists() {
                clone_path(&src, &tmp.join(name)).inspect_err(|_| remove(&tmp))?;
                items.push(name.to_string());
            }
        }
        let snap = Snapshot { id: id.clone(), agent: agent.into(), at: util::now(), why: why.into(), bytes: size_of(&tmp), items };
        util::write_json(&tmp.join("snapshot.json"), &snap)?;
        // Whole or not at all: a half-made snapshot is never listed.
        std::fs::rename(&tmp, &dir).map_err(|e| e.to_string())?;
        self.prune_snapshots(agent);
        Ok(snap)
    }

    fn prune_snapshots(&self, agent: &str) {
        let mut all = self.snapshots(agent);
        // Newest first; the snapshot an asleep agent went to sleep with is always kept.
        let keep_id = self.asleep(agent).and_then(|a| a.snapshot);
        let mut kept = 0;
        for s in all.drain(..) {
            if Some(&s.id) == keep_id.as_ref() {
                continue;
            }
            kept += 1;
            if kept > KEEP {
                remove(&self.snapshots_dir(agent).join(&s.id));
            }
        }
    }

    /// An agent's snapshots, newest first.
    pub fn snapshots(&self, agent: &str) -> Vec<Snapshot> {
        let mut out: Vec<Snapshot> = std::fs::read_dir(self.snapshots_dir(agent))
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
            .filter_map(|e| serde_json::from_str(&std::fs::read_to_string(e.path().join("snapshot.json")).ok()?).ok())
            .collect();
        out.sort_by(|a: &Snapshot, b| b.at.cmp(&a.at).then(b.id.cmp(&a.id)));
        out
    }

    /// Put an agent's working state back as it was in a snapshot. The present
    /// state is snapshotted first, so this can be undone the same way.
    pub async fn restore_snapshot(&self, agent: &str, id: &str) -> Result<Snapshot, String> {
        let rec = self.agent(agent).await?;
        if self.runs.lock().unwrap().contains_key(agent) {
            return Err(format!("{} is working. Stop the job first.", rec.name));
        }
        if id.contains('/') || id.contains("..") {
            return Err("No such snapshot.".into());
        }
        let src = self.snapshots_dir(agent).join(id);
        let snap: Snapshot = serde_json::from_str(&std::fs::read_to_string(src.join("snapshot.json")).map_err(|_| "No such snapshot.")?).map_err(|e| e.to_string())?;
        let before = self.snapshot(agent, "before restore")?;
        let home = self.paths.agent(agent);
        // Stage everything first; swap each piece in by rename, so a failure
        // midway leaves either the old piece or the new, never half of one.
        let stage = home.join(".restoring");
        remove(&stage);
        for name in STATE {
            if snap.items.iter().any(|i| i == name) {
                clone_path(&src.join(name), &stage.join(name)).inspect_err(|_| remove(&stage))?;
            }
        }
        for name in STATE {
            let live = home.join(name);
            let old = home.join(format!(".old-{name}"));
            remove(&old);
            if live.exists() {
                std::fs::rename(&live, &old).map_err(|e| e.to_string())?;
            }
            let staged = stage.join(name);
            if staged.exists() {
                if let Err(e) = std::fs::rename(&staged, &live) {
                    let _ = std::fs::rename(&old, &live);
                    return Err(format!("{e} (the present state is in snapshot {})", before.id));
                }
            }
            remove(&old);
        }
        remove(&stage);
        // The folder always exists, even if the snapshot was taken before it was.
        let _ = std::fs::create_dir_all(self.paths.work(agent));
        self.emit(crate::events::TeamEvent::RosterChanged);
        Ok(snap)
    }

    pub fn delete_snapshot(&self, agent: &str, id: &str) -> Result<(), String> {
        if id.contains('/') || id.contains("..") || id.is_empty() {
            return Err("No such snapshot.".into());
        }
        if self.asleep(agent).and_then(|a| a.snapshot).as_deref() == Some(id) {
            return Err("That is the snapshot it went to sleep with. Wake it first.".into());
        }
        let dir = self.snapshots_dir(agent).join(id);
        if !dir.join("snapshot.json").exists() {
            return Err("No such snapshot.".into());
        }
        std::fs::remove_dir_all(dir).map_err(|e| e.to_string())
    }

    /// One snapshot a day of every agent that worked that day (taken on the tick).
    pub(crate) fn daily_snapshots(&self, agents: &[String]) {
        let today = util::now() / 86_400;
        for a in agents {
            let taken_today = self.snapshots(a).iter().any(|s| s.why == "daily" && s.at / 86_400 == today);
            let worked_today = std::fs::metadata(self.paths.session(a)).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).is_some_and(|d| d.as_secs() / 86_400 == today);
            if worked_today && !taken_today {
                if let Err(e) = self.snapshot(a, "daily") {
                    tracing::info!(agent = %a, error = %e, "snapshot: the daily one failed");
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn team_with(id: &str) -> (tempfile::TempDir, std::sync::Arc<Team>) {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("agents.json"), format!(r#"[{{"id":"{id}","name":"Sorter","model":"anthropic:claude-haiku-4-5","job":"tidy","created_at":1}}]"#)).unwrap();
        let t = Team::open(dir.path()).unwrap();
        (dir, t)
    }

    #[tokio::test]
    async fn a_restore_puts_the_state_back_and_never_the_record() {
        let id = "a1";
        let (_d, t) = team_with(id);
        let home = t.paths.agent(id);
        std::fs::create_dir_all(home.join("work")).unwrap();
        std::fs::write(home.join("work/plan.md"), "v1").unwrap();
        std::fs::write(home.join("session.jsonl"), "s1\n").unwrap();
        std::fs::write(home.join("jobs.jsonl"), "job-1\n").unwrap();
        let s = t.snapshot(id, "you").unwrap();
        std::fs::write(home.join("work/plan.md"), "v2").unwrap();
        std::fs::write(home.join("work/new.md"), "x").unwrap();
        std::fs::write(home.join("session.jsonl"), "s1\ns2\n").unwrap();
        std::fs::write(home.join("jobs.jsonl"), "job-1\njob-2\n").unwrap();
        t.restore_snapshot(id, &s.id).await.unwrap();
        assert_eq!(std::fs::read_to_string(home.join("work/plan.md")).unwrap(), "v1");
        assert!(!home.join("work/new.md").exists(), "the folder is as it was");
        assert_eq!(std::fs::read_to_string(home.join("session.jsonl")).unwrap(), "s1\n");
        assert_eq!(std::fs::read_to_string(home.join("jobs.jsonl")).unwrap(), "job-1\njob-2\n", "the record is never rolled back");
        // The state before the restore was kept, so the restore can be undone.
        let before = t.snapshots(id).into_iter().find(|x| x.why == "before restore").unwrap();
        t.restore_snapshot(id, &before.id).await.unwrap();
        assert_eq!(std::fs::read_to_string(home.join("work/plan.md")).unwrap(), "v2");
        assert!(t.restore_snapshot(id, "../x").await.is_err() && t.delete_snapshot(id, "../x").is_err());
    }

    #[tokio::test]
    async fn an_asleep_agent_keeps_its_sleep_snapshot() {
        let id = "a2";
        let (_d, t) = team_with(id);
        std::fs::create_dir_all(t.paths.work(id)).unwrap();
        let a = t.sleep_agent(id).await.unwrap();
        assert!(t.is_asleep(id));
        let snap = a.snapshot.unwrap();
        assert!(t.delete_snapshot(id, &snap).is_err(), "kept while it sleeps");
        t.wake_agent(id).await.unwrap();
        assert!(!t.is_asleep(id));
        t.delete_snapshot(id, &snap).unwrap();
    }

    #[test]
    fn a_clone_copies_a_tree_and_skips_links() {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("a");
        std::fs::create_dir_all(a.join("sub")).unwrap();
        std::fs::write(a.join("sub/f.txt"), "hi").unwrap();
        clone_path(&a, &dir.path().join("b")).unwrap();
        assert_eq!(std::fs::read_to_string(dir.path().join("b/sub/f.txt")).unwrap(), "hi");
        copy_tree(&a, &dir.path().join("c")).unwrap();
        assert_eq!(std::fs::read_to_string(dir.path().join("c/sub/f.txt")).unwrap(), "hi");
    }
}
