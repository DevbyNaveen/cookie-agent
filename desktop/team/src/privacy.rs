//! Your data: what Cookie keeps, crash reports you opt into, and deleting it all.
//!
//! - **Crash reports are off until you turn them on.** On, a crash of Cookie's
//!   engine (a panic) or of its window (a script error) is written to
//!   `crashes/` on this Mac: what failed, where, the version and the OS. Never
//!   a conversation, a file or a key. Nothing is sent anywhere: you read one
//!   and share it yourself if you like ([`Team::crash_report`]).
//! - **Deleting everything on this Mac** removes every agent, conversation,
//!   memory ledger, file and setting in Cookie's folder, and every key Cookie
//!   saved in the Keychain (its own Keychain service only), then quits.
//!   What lives in Enkeon (your brain, its connected apps) stays there: it is
//!   yours to delete in the Enkeon Console, and Cookie says so.

use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{util, Team};

/// Crash reports kept; older ones go.
const KEEP: usize = 50;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Privacy {
    pub crash_reports: bool,
}

/// Where crashes are written, once known (the panic hook has no `Team`).
static CRASH_DIR: OnceLock<PathBuf> = OnceLock::new();

fn crash_dir(root: &Path) -> PathBuf {
    root.join("crashes")
}

/// Strip what must never be in a report: home paths become `~`, and anything
/// shaped like a key is cut.
pub fn scrub(text: &str) -> String {
    scrub_with(text, &std::env::var("HOME").unwrap_or_default())
}

fn scrub_with(text: &str, home: &str) -> String {
    let mut out = if home.len() > 1 { text.replace(home, "~") } else { text.to_string() };
    for prefix in ["sk-ant-", "sk-", "xoxb-", "xoxe", "xoxp-", "tr_sk_", "tr_pk_", "AKIA", "ghp_", "AIza"] {
        while let Some(i) = out.find(prefix) {
            let end = out[i..].find(|c: char| c.is_whitespace() || c == '"' || c == '\'').map(|e| i + e).unwrap_or(out.len());
            out.replace_range(i..end, "[key removed]");
        }
    }
    out
}

fn write_report(dir: &Path, kind: &str, message: &str, detail: &str) {
    let _ = std::fs::create_dir_all(dir);
    let at = util::now();
    let report = json!({
        "kind": kind,
        "at": at,
        "version": env!("CARGO_PKG_VERSION"),
        "os": format!("{} {}", std::env::consts::OS, std::env::consts::ARCH),
        "message": scrub(&util::clip(message, 2000)),
        "detail": scrub(&util::clip(detail, 12_000)),
    });
    let name = format!("{at}-{}-{}.json", kind, util::random_hex(3));
    let _ = util::write_json(&dir.join(name), &report);
    // Keep the newest few.
    if let Ok(rd) = std::fs::read_dir(dir) {
        let mut files: Vec<PathBuf> = rd.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.extension().is_some_and(|x| x == "json")).collect();
        files.sort();
        while files.len() > KEEP {
            let _ = std::fs::remove_file(files.remove(0));
        }
    }
}

impl Team {
    fn privacy_path(&self) -> PathBuf {
        self.paths.root.join("privacy.json")
    }

    pub fn privacy(&self) -> Privacy {
        util::read_json(&self.privacy_path())
    }

    /// At start: when crash reports are on, a panic anywhere in the engine is written down.
    pub fn install_crash_reports(self: &Arc<Self>) {
        let _ = CRASH_DIR.set(crash_dir(&self.paths.root));
        let flag = self.privacy_path();
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let on = util::read_json::<Privacy>(&flag).crash_reports;
            if on {
                if let Some(dir) = CRASH_DIR.get() {
                    let message = info.payload().downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| info.payload().downcast_ref::<String>().cloned()).unwrap_or_else(|| "panic".into());
                    let place = info.location().map(|l| format!("{}:{}", l.file(), l.line())).unwrap_or_default();
                    let trace = std::backtrace::Backtrace::force_capture().to_string();
                    write_report(dir, "engine", &format!("{message} at {place}"), &trace);
                }
            }
            previous(info);
        }));
    }

    pub fn set_crash_reports(&self, on: bool) -> Result<Value, String> {
        let mut p = self.privacy();
        p.crash_reports = on;
        util::write_json(&self.privacy_path(), &p)?;
        Ok(self.data_summary())
    }

    /// The window had an error (only kept when crash reports are on).
    pub fn report_ui_error(&self, message: &str, detail: &str) {
        if self.privacy().crash_reports {
            write_report(&crash_dir(&self.paths.root), "window", message, detail);
        }
    }

    pub fn crash_reports(&self) -> Vec<Value> {
        let mut out: Vec<Value> = std::fs::read_dir(crash_dir(&self.paths.root))
            .into_iter()
            .flatten()
            .filter_map(|e| e.ok())
            .filter_map(|e| {
                let v: Value = util::read_json(&e.path());
                (!v.is_null()).then(|| json!({"id": e.file_name().to_string_lossy(), "kind": v["kind"], "at": v["at"], "message": v["message"]}))
            })
            .collect();
        out.sort_by(|a, b| b["at"].as_u64().cmp(&a["at"].as_u64()));
        out
    }

    /// One report in full, to read or share.
    pub fn crash_report(&self, id: &str) -> Result<Value, String> {
        if id.contains('/') || id.contains("..") {
            return Err("No such report.".into());
        }
        let p = crash_dir(&self.paths.root).join(id);
        p.exists().then(|| util::read_json(&p)).ok_or_else(|| "No such report.".into())
    }

    pub fn clear_crash_reports(&self) -> Result<(), String> {
        let _ = std::fs::remove_dir_all(crash_dir(&self.paths.root));
        Ok(())
    }

    /// What Cookie keeps on this Mac, in numbers you can check.
    pub fn data_summary(&self) -> Value {
        fn size(p: &Path) -> u64 {
            match std::fs::symlink_metadata(p) {
                Ok(m) if m.is_dir() => std::fs::read_dir(p).into_iter().flatten().filter_map(|e| e.ok()).map(|e| size(&e.path())).sum(),
                Ok(m) => m.len(),
                Err(_) => 0,
            }
        }
        json!({
            "folder": self.paths.root.to_string_lossy().replace(&std::env::var("HOME").unwrap_or_default(), "~"),
            "bytes": size(&self.paths.root),
            "crash_reports": self.privacy().crash_reports,
            "crashes": self.crash_reports().len(),
        })
    }

    /// Delete everything Cookie keeps on this Mac, then quit. `confirm` must be "DELETE".
    pub async fn erase_everything(self: &Arc<Self>, confirm: &str) -> Result<Value, String> {
        if confirm.trim() != "DELETE" {
            return Err("Type DELETE to confirm.".into());
        }
        // Every key in Cookie's own Keychain service (never another app's).
        #[cfg(all(target_os = "macos", not(test)))]
        for _ in 0..500 {
            let gone = std::process::Command::new("security").args(["delete-generic-password", "-s", crate::keys::SERVICE]).output().map(|o| o.status.success()).unwrap_or(false);
            if !gone {
                break;
            }
        }
        let root = self.paths.root.clone();
        let entries: Vec<PathBuf> = std::fs::read_dir(&root).map_err(|e| e.to_string())?.filter_map(|e| e.ok().map(|e| e.path())).collect();
        for p in entries {
            let r = if p.is_dir() { std::fs::remove_dir_all(&p) } else { std::fs::remove_file(&p) };
            if let Err(e) = r {
                tracing::warn!(path = %p.display(), error = %e, "erase: couldn't remove");
            }
        }
        // Quit once the answer is on its way; the next start is a fresh Cookie.
        #[cfg(not(test))]
        tokio::spawn(async {
            tokio::time::sleep(std::time::Duration::from_millis(900)).await;
            std::process::exit(0);
        });
        Ok(json!({"note": "Everything Cookie kept on this Mac is deleted, with its keys in the Keychain. Your Enkeon brain and connected apps are still in Enkeon: delete them in the Enkeon Console if you want them gone too. Cookie will close now."}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_report_never_carries_a_key_or_your_home() {
        let s = scrub_with("failed at /Users/someone/Library/x with sk-ant-api03-abcdef and \"xoxb-123-456\" ok", "/Users/someone");
        assert!(!s.contains("/Users/someone") && s.contains("~/Library/x"));
        assert!(!s.contains("sk-ant-api03") && !s.contains("xoxb-123"));
        assert_eq!(s.matches("[key removed]").count(), 2);
    }

    #[tokio::test]
    async fn crash_reports_are_kept_only_when_on_and_erasing_takes_everything() {
        let dir = std::env::temp_dir().join(format!("cookie-privacy-{}", util::random_hex(4)));
        let team = Team::open(&dir).unwrap();
        team.report_ui_error("boom", "stack");
        assert!(team.crash_reports().is_empty(), "off by default: nothing written");
        team.set_crash_reports(true).unwrap();
        team.report_ui_error("TypeError: x is null", "at app.js:10");
        let list = team.crash_reports();
        assert_eq!(list.len(), 1);
        assert_eq!(team.crash_report(list[0]["id"].as_str().unwrap()).unwrap()["kind"], "window");
        assert!(team.crash_report("../agents.json").is_err());
        assert!(team.erase_everything("yes").await.is_err(), "needs the word");
        std::fs::write(dir.join("agents.json"), "[]").unwrap();
        team.erase_everything("DELETE").await.unwrap();
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
