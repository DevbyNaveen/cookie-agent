//! Retiring and inheritance: what an agent learned outlives it.
//!
//! Retiring an agent first keeps what it learned in an archive
//! (`handovers/archive/<id>/`): its lessons and recipes, its skills, its tests,
//! its proven habits, its notes, and a signed passport of its record. Then it
//! writes its handover note and is let go as any fired agent is (its folder,
//! conversation and memories go).
//!
//! A new hire can start from an archive: it gets the lessons, recipes,
//! skills, tests and habits, and the handover note. The lessons keep the
//! record they earned, so the successor starts from what was proven, and the
//! bandit keeps testing them on the new agent's own jobs.

use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::{util, Team};

/// What an archive keeps, by file in the agent's folder.
const KEPT: &[&str] = &["lessons.json", "procedures.json", "skills", "tests.json", "NOTES.md"];

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Archive {
    pub id: String,
    pub agent: String,
    pub name: String,
    pub job: String,
    pub model: String,
    pub retired_at: u64,
    pub handover: Option<String>,
    pub habits: Vec<String>,
    pub lessons: usize,
    pub skills: usize,
    pub tests: usize,
    pub passport: Option<serde_json::Value>,
}

impl Team {
    fn archives_dir(&self) -> std::path::PathBuf {
        self.paths.handovers().join("archive")
    }

    pub fn archives(&self) -> Vec<Archive> {
        let mut v: Vec<Archive> = std::fs::read_dir(self.archives_dir())
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| serde_json::from_slice(&std::fs::read(e.path().join("archive.json")).ok()?).ok())
            .collect();
        v.sort_by_key(|a: &Archive| std::cmp::Reverse(a.retired_at));
        v
    }

    /// Keep what an agent learned, then let it go with a handover note. Returns the archive id.
    pub async fn retire(self: &Arc<Self>, agent: &str) -> Result<String, String> {
        if agent == crate::front::COOKIE_ID {
            return Err("Cookie stays: it's your front door.".into());
        }
        let rec = self.agent(agent).await?;
        if self.runs.lock().unwrap().contains_key(agent) {
            return Err(format!("{} is working. Let it finish first.", rec.name));
        }
        let id = format!("{}-{}", rec.id, util::now());
        let dir = self.archives_dir().join(&id);
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let home = self.paths.agent(agent);
        for part in KEPT {
            let src = home.join(part);
            if src.exists() {
                crate::sleep::clone_path(&src, &dir.join(part))?;
            }
        }
        let passport = self.passport(agent).await.ok().and_then(|p| serde_json::to_value(p).ok());
        let mut a = Archive {
            id: id.clone(),
            agent: rec.id.clone(),
            name: rec.name.clone(),
            job: rec.job.clone(),
            model: rec.model.clone(),
            retired_at: util::now(),
            handover: None,
            habits: self.tuning(agent).habits,
            lessons: self.lessons(agent).len(),
            skills: std::fs::read_dir(home.join("skills")).map(|d| d.count()).unwrap_or(0),
            tests: self.tests(agent).len(),
            passport,
        };
        // Its memory stays in Enkeon for a successor (`brain::succeed`), not erased like a firing's.
        crate::brain::keep_space(agent);
        // Its handover note needs it awake for one last job.
        if self.is_asleep(agent) {
            self.wake_agent(agent).await?;
        }
        a.handover = self.fire(agent, true).await?;
        util::write_json(&dir.join("archive.json"), &a)?;
        Ok(id)
    }

    /// A new agent starts from what a retired one learned.
    pub(crate) fn inherit_into(&self, archive: &str, agent: &str) -> Result<Archive, String> {
        if archive.contains('/') || archive.contains("..") || archive.is_empty() {
            return Err("No such archive.".into());
        }
        let dir = self.archives_dir().join(archive);
        let a: Archive = serde_json::from_slice(&std::fs::read(dir.join("archive.json")).map_err(|_| "No such archive.")?).map_err(|e| e.to_string())?;
        let home = self.paths.agent(agent);
        std::fs::create_dir_all(&home).map_err(|e| e.to_string())?;
        // What its predecessor knew: it follows the old space, and takes over the spaces it owned.
        self.succeed(&a.agent, agent, &a.name);
        for part in KEPT {
            let src = dir.join(part);
            if src.exists() && !home.join(part).exists() {
                crate::sleep::clone_path(&src, &home.join(part))?;
            }
        }
        if !a.habits.is_empty() {
            let mut t = self.tuning(agent);
            t.habits = a.habits.clone();
            util::write_json(&home.join("tuning.json"), &t.clamp())?;
        }
        let c = crate::tuning::Change { id: util::new_id("chg"), agent: agent.into(), at: util::now(), kind: "inherited".into(), what: format!("Started from what {} learned ({} lessons, {} skills, {} tests)", a.name, a.lessons, a.skills, a.tests), by: a.name.clone(), state: "kept".into(), ..Default::default() };
        let _ = util::append_jsonl(&home.join("evolution.jsonl"), &c);
        Ok(a)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_successor_gets_the_archive_and_never_outside_it() {
        let dir = tempfile::tempdir().unwrap();
        let t = Team::open(dir.path()).unwrap();
        let arch = t.archives_dir().join("old-1");
        std::fs::create_dir_all(arch.join("skills")).unwrap();
        std::fs::write(arch.join("skills/s.md"), "a skill").unwrap();
        std::fs::write(arch.join("lessons.json"), "[]").unwrap();
        util::write_json(&arch.join("archive.json"), &Archive { id: "old-1".into(), name: "Old".into(), habits: vec!["Check the date.".into()], ..Archive::default() }).unwrap();
        let a = t.inherit_into("old-1", "new-1").unwrap();
        assert_eq!(a.name, "Old");
        assert!(t.paths.agent("new-1").join("skills/s.md").exists());
        assert_eq!(t.tuning("new-1").habits, vec!["Check the date.".to_string()]);
        assert!(t.inherit_into("../x", "new-1").is_err());
        assert_eq!(t.archives().len(), 1);
    }
}
