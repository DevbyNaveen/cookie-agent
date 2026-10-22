//! Optional local write-ahead receipts for applications without a hosted store.
//! An attempt is durable before the tool runs. Restarting never replays it.
//! This is at-most-once admission, not exactly-once delivery or outcome proof.
use crate::{Error, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone)]
pub struct ActionLedger {
    directory: PathBuf,
}

impl ActionLedger {
    /// Use the same trusted job/revision scope across restarts. Do not derive
    /// it from model output. Keep the directory on a durable local filesystem.
    pub fn open(root: impl AsRef<Path>, scope: &str) -> Result<Self> {
        if scope.trim().is_empty() {
            return Err(Error::Session("durable action scope is empty".into()));
        }
        let directory = root
            .as_ref()
            .join(format!("{:x}", Sha256::digest(scope.as_bytes())));
        fs::create_dir_all(&directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        }
        fs::File::open(root.as_ref())?.sync_all()?;
        Ok(Self { directory })
    }

    fn key(tool: &str, args: &Value) -> String {
        format!(
            "{:x}",
            Sha256::digest(json!([tool, args]).to_string().as_bytes())
        )
    }

    fn write_once(&self, name: &str, value: &Value) -> Result<()> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut f = options.open(self.directory.join(name))?;
        f.write_all(serde_json::to_string(value)?.as_bytes())?;
        f.sync_all()?;
        fs::File::open(&self.directory)?.sync_all()?;
        Ok(())
    }

    pub(crate) fn begin(&self, tool: &str, args: &Value) -> Result<String> {
        let key = Self::key(tool, args);
        self.write_once(&format!("{key}.attempt"),&json!({"tool":tool,"state":"unknown"}))
            .map_err(|e|Error::Tool(format!("Action not admitted: an earlier attempt exists or durable storage failed ({e}). Inspect its receipt; do not change arguments to bypass it.")))?;
        Ok(key)
    }

    pub(crate) fn acknowledged(&self, key: &str) -> Result<()> {
        self.write_once(
            &format!("{key}.result"),
            &json!({"state":"acknowledged","verified":false}),
        )
    }

    /// Absence means no recorded attempt. A partial file, interrupted write or
    /// missing result remains unknown. Receipts contain no tool arguments.
    pub fn status(&self, tool: &str, args: &Value) -> Result<Option<&'static str>> {
        let key = Self::key(tool, args);
        match fs::metadata(self.directory.join(format!("{key}.attempt"))) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
            Ok(_) => {}
        }
        let result = fs::read(self.directory.join(format!("{key}.result")))
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok());
        Ok(Some(
            if result.is_some_and(|v| v["state"] == "acknowledged") {
                "acknowledged"
            } else {
                "unknown"
            },
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn restart_never_repeats_unknown_or_acknowledged_changes() {
        let root = tempfile::tempdir().unwrap();
        let args = json!({"id":"42"});
        let first = ActionLedger::open(root.path(), "job-1/revision-1").unwrap();
        let key = first.begin("update", &args).unwrap();
        let restarted = ActionLedger::open(root.path(), "job-1/revision-1").unwrap();
        assert_eq!(restarted.status("update", &args).unwrap(), Some("unknown"));
        assert!(restarted.begin("update", &args).is_err());
        first.acknowledged(&key).unwrap();
        assert_eq!(
            restarted.status("update", &args).unwrap(),
            Some("acknowledged")
        );
        assert!(restarted.begin("update", &args).is_err());
    }
    #[test]
    fn concurrent_process_handles_admit_only_one_attempt() {
        let root = tempfile::tempdir().unwrap();
        let a = ActionLedger::open(root.path(), "same-job").unwrap();
        let b = a.clone();
        let t =
            std::thread::spawn(move || a.begin("send", &json!({"to":"a@example.test"})).is_ok());
        let second = b.begin("send", &json!({"to":"a@example.test"})).is_ok();
        assert_ne!(t.join().unwrap(), second);
    }
}
