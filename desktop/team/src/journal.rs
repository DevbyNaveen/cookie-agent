//! What an agent changed in the person's files, so they can put it back.
//!
//! Every write to a file of the person's (`mac_files_write`) is kept here:
//! which file, which agent and job, the old version (kept beside it before
//! anything changed) and a fingerprint of what the agent wrote. Putting it
//! back is allowed only while the file still says exactly what the agent
//! wrote, so a later edit by the person or another agent is never thrown
//! away. A file the agent created can be removed again on the same terms.
//!
//! Ported from the super console (gateway `cookie/journal.rs`), for files on
//! the Mac in place of records in an app.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::lease::digest;
use crate::{util, Team};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Change {
    pub id: String,
    pub agent: String,
    pub job: String,
    pub path: String,
    /// The old version, kept before the write; none when the file was new.
    pub before: Option<String>,
    /// Fingerprint of what the agent wrote.
    pub after: String,
    pub at: u64,
    /// When it was put back.
    #[serde(default)]
    pub undone_at: Option<u64>,
}

impl Team {
    fn journal_path(&self) -> PathBuf {
        self.paths.root.join("file-changes.jsonl")
    }

    pub(crate) fn journal_write(&self, agent: &str, job: &str, path: &Path, before: Option<&Path>, written: &[u8]) {
        let c = Change {
            id: util::new_id("change"),
            agent: agent.to_string(),
            job: job.to_string(),
            path: path.to_string_lossy().into(),
            before: before.map(|b| b.to_string_lossy().into()),
            after: digest(written),
            at: util::now(),
            undone_at: None,
        };
        let _ = util::append_jsonl(&self.journal_path(), &c);
    }

    /// Changes, newest first, with whether each can still be put back.
    pub fn file_changes(&self, agent: Option<&str>) -> Vec<serde_json::Value> {
        let mut all: Vec<Change> = util::read_jsonl(&self.journal_path());
        all.reverse();
        all.into_iter()
            .filter(|c| agent.is_none_or(|a| a == c.agent))
            .take(200)
            .map(|c| {
                let can = c.undone_at.is_none() && still_as_written(&c);
                serde_json::json!({"id": c.id, "agent": c.agent, "job": c.job, "path": c.path, "created": c.before.is_none(), "at": c.at, "undone_at": c.undone_at, "can_undo": can})
            })
            .collect()
    }

    /// Put a file back the way it was before the agent's change.
    pub fn undo_file_change(&self, id: &str) -> Result<String, String> {
        let path = self.journal_path();
        let mut all: Vec<Change> = util::read_jsonl(&path);
        let c = all.iter_mut().find(|c| c.id == id).ok_or("No such change.")?;
        if c.undone_at.is_some() {
            return Err("That change was already put back.".into());
        }
        if !still_as_written(c) {
            return Err("The file was changed again since, so putting it back would throw that away. Open it and fix it by hand.".into());
        }
        let file = PathBuf::from(&c.path);
        let said = match &c.before {
            Some(old) => {
                let bytes = std::fs::read(old).map_err(|e| format!("The old version is gone: {e}"))?;
                let tmp = file.with_extension("cookie-tmp");
                std::fs::write(&tmp, &bytes).map_err(|e| e.to_string())?;
                std::fs::rename(&tmp, &file).map_err(|e| e.to_string())?;
                format!("Put {} back the way it was.", c.path)
            }
            None => {
                std::fs::remove_file(&file).map_err(|e| e.to_string())?;
                format!("Removed {}, which the agent had created.", c.path)
            }
        };
        c.undone_at = Some(util::now());
        util::write_jsonl(&path, &all)?;
        Ok(said)
    }
}

fn still_as_written(c: &Change) -> bool {
    std::fs::read(&c.path).ok().is_some_and(|b| digest(&b) == c.after)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_change_goes_back_only_while_the_file_says_what_the_agent_wrote() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path().join("cookie")).unwrap();
        let f = dir.path().join("plan.md");
        let old = dir.path().join("plan.old");
        std::fs::write(&old, "v1").unwrap();
        std::fs::write(&f, "v2").unwrap();
        team.journal_write("a", "j", &f, Some(&old), b"v2");
        let id = team.file_changes(None)[0]["id"].as_str().unwrap().to_string();
        assert_eq!(team.file_changes(Some("a"))[0]["can_undo"], true);
        std::fs::write(&f, "the person's edit").unwrap();
        assert!(team.undo_file_change(&id).unwrap_err().contains("changed again"), "a later edit is never thrown away");
        std::fs::write(&f, "v2").unwrap();
        team.undo_file_change(&id).unwrap();
        assert_eq!(std::fs::read_to_string(&f).unwrap(), "v1");
        assert!(team.undo_file_change(&id).is_err(), "once");
        let new = dir.path().join("new.md");
        std::fs::write(&new, "made").unwrap();
        team.journal_write("a", "j", &new, None, b"made");
        let id = team.file_changes(None)[0]["id"].as_str().unwrap().to_string();
        team.undo_file_change(&id).unwrap();
        assert!(!new.exists());
    }
}
