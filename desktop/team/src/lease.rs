//! One change to one file at a time.
//!
//! Two agents (or two jobs of one) can reach for the same file of the
//! person's: both read it, both are approved, and the second write would
//! silently drop the first one's change. So a job remembers what each file
//! said when it read it, and a write to a file that changed since then is
//! refused with the reason: read it again and redo the change on what it
//! says now. A write in flight also holds its file, so two writes can't
//! land at once. Nothing has to release a hold: it ends with the write.
//!
//! Ported from the super console (gateway `cookie/lease.rs`), for files on
//! the Mac in place of records in an app.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};

use sha2::{Digest, Sha256};

/// Files being written right now, across every job.
static WRITING: LazyLock<Mutex<HashSet<PathBuf>>> = LazyLock::new(Default::default);

pub fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().take(16).map(|b| format!("{b:02x}")).collect()
}

fn now_digest(path: &Path) -> Option<String> {
    std::fs::read(path).ok().map(|b| digest(&b))
}

/// What one job saw of each file it read. Made fresh for every job.
#[derive(Clone, Default)]
pub struct Seen(Arc<Mutex<HashMap<PathBuf, String>>>);

impl Seen {
    /// The job read this file, as it is now.
    pub fn read(&self, path: &Path) {
        if let Some(d) = now_digest(path) {
            self.0.lock().unwrap().insert(path.to_path_buf(), d);
        }
    }

    /// The job wrote this file: what it says now is what this job knows.
    pub fn wrote(&self, path: &Path) {
        self.read(path);
    }

    /// May this job write the file now? Refused when it changed since the job
    /// read it, or another write to it is in flight. On yes, the file is held
    /// until the returned guard is dropped.
    pub fn hold(&self, path: &Path) -> Result<Hold, String> {
        if let (Some(saw), Some(now)) = (self.0.lock().unwrap().get(path).cloned(), now_digest(path)) {
            if saw != now {
                return Err(format!("{} changed since you read it (someone or another agent edited it). Read it again and make your change on what it says now.", path.display()));
            }
        }
        let mut w = WRITING.lock().unwrap();
        if !w.insert(path.to_path_buf()) {
            return Err(format!("Another job is writing {} right now. Try again in a moment.", path.display()));
        }
        Ok(Hold(path.to_path_buf()))
    }
}

#[derive(Debug)]
pub struct Hold(PathBuf);

impl Drop for Hold {
    fn drop(&mut self) {
        WRITING.lock().unwrap().remove(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_changed_since_it_was_read_is_not_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("plan.md");
        std::fs::write(&p, "v1").unwrap();
        let (a, b) = (Seen::default(), Seen::default());
        a.read(&p);
        b.read(&p);
        {
            let _h = a.hold(&p).unwrap();
            assert!(b.hold(&p).unwrap_err().contains("writing"), "one write at a time");
            std::fs::write(&p, "a's change").unwrap();
            a.wrote(&p);
        }
        assert!(b.hold(&p).unwrap_err().contains("changed since you read it"), "b read v1; a changed it");
        b.read(&p);
        assert!(b.hold(&p).is_ok(), "after reading again, b may write");
        let fresh = Seen::default();
        assert!(fresh.hold(&dir.path().join("new.md")).is_ok(), "a new file holds nothing");
    }
}
