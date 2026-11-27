//! Working while you are away: this Mac stays awake, and Cookie comes back.
//!
//! - **Keep awake** (`settings.keep_awake`): while Cookie runs and this Mac is
//!   plugged in, it does not go to sleep on its own, so routines run through
//!   the night. The screen may still turn off. Closing the lid still sleeps a
//!   laptop (without an outside display): that is the Mac's rule, not ours.
//!   On battery nothing is held, so a forgotten laptop doesn't drain.
//! - **Start at login** (`settings.start_at_login`): a login item starts Cookie
//!   when you log in and starts it again if it crashes. Quitting it yourself
//!   is respected: it stays closed until the next login.
//!
//! Both are the Mac's own tools (`caffeinate`, a launch agent); on other
//! systems the settings say so and do nothing.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use crate::Team;

/// The login item's name, and its file in `~/Library/LaunchAgents`.
pub const LABEL: &str = "com.enkeon.cookie.desktop";

pub fn supported() -> bool {
    cfg!(target_os = "macos")
}

fn plist_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/LaunchAgents").join(format!("{LABEL}.plist")))
}

fn xml(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// The launch agent: run at login, start again after a crash, not after a quit.
fn plist(exe: &str, log: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{LABEL}</string>
  <key>ProgramArguments</key><array><string>{}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>20</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>{}</string>
</dict>
</plist>
"#,
        xml(exe),
        xml(log)
    )
}

/// Is the login item in place, and for this copy of Cookie?
pub fn login_item() -> bool {
    let (Some(p), Ok(exe)) = (plist_path(), std::env::current_exe()) else { return false };
    std::fs::read_to_string(p).is_ok_and(|s| s.contains(&xml(&exe.to_string_lossy())))
}

/// Was this Cookie started by its login item (so a crash brings it back)?
pub fn kept() -> bool {
    std::env::var("XPC_SERVICE_NAME").is_ok_and(|n| n == LABEL)
}

fn uid() -> String {
    std::process::Command::new("/usr/bin/id").arg("-u").output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default()
}

impl Team {
    /// Add or remove the login item. Added, it starts Cookie at the next
    /// login; `restart_kept` hands this running Cookie over to it now.
    pub async fn set_start_at_login(self: &Arc<Self>, on: bool) -> Result<(), String> {
        if !supported() {
            return Err("Starting at login is set up for the Mac only, so far.".into());
        }
        let path = plist_path().ok_or("This account has no home folder.")?;
        if on {
            let exe = std::env::current_exe().map_err(|e| e.to_string())?;
            std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
            std::fs::write(&path, plist(&exe.to_string_lossy(), &self.paths.root.join("cookie.err.log").to_string_lossy())).map_err(|e| format!("Couldn't write the login item: {e}"))?;
        } else {
            let _ = std::fs::remove_file(&path);
            // Not started by it: nothing to unload. Started by it: unloading would end this
            // Cookie, so it is left running and simply not started again.
            if !kept() {
                let _ = std::process::Command::new("/bin/launchctl").args(["bootout", &format!("gui/{}/{LABEL}", uid())]).output();
            }
        }
        self.update_settings(move |s| s.start_at_login = on).await.map(|_| ())
    }

    /// Close this Cookie and let its login item start it, so that from now on
    /// a crash brings it back. The window reopens in a couple of seconds.
    pub fn restart_kept(&self) -> Result<(), String> {
        let path = plist_path().filter(|p| p.exists()).ok_or("Turn on “Start at login” first.")?;
        let target = format!("gui/{}", uid());
        // A helper outlives this process: it waits for us to go, then loads the item (which runs it).
        let script = format!("sleep 1.5; /bin/launchctl bootout {target}/{LABEL} 2>/dev/null; sleep 0.5; /bin/launchctl bootstrap {target} '{}'", path.display().to_string().replace('\'', "'\\''"));
        std::process::Command::new("/bin/sh").arg("-c").arg(script).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn().map_err(|e| format!("Couldn't hand over to the login item: {e}"))?;
        tokio::spawn(async {
            tokio::time::sleep(Duration::from_millis(400)).await;
            std::process::exit(0);
        });
        Ok(())
    }

    /// What the Settings screen shows.
    pub async fn power_view(&self) -> serde_json::Value {
        let s = self.settings.read().await;
        serde_json::json!({
            "supported": supported(),
            "keep_awake": s.keep_awake,
            "start_at_login": s.start_at_login && login_item(),
            "kept": kept(),
            "approval_wait_minutes": s.approval_wait_minutes,
        })
    }
}

/// Hold the Mac awake while the setting is on. `caffeinate -s` holds only on
/// mains power, and `-w` ends it with Cookie, however Cookie ends.
pub fn spawn(team: Arc<Team>) {
    if !supported() {
        return;
    }
    tokio::spawn(async move {
        let mut held: Option<tokio::process::Child> = None;
        loop {
            let want = team.settings.read().await.keep_awake;
            let alive = held.as_mut().is_some_and(|c| c.try_wait().ok().flatten().is_none());
            if want && !alive {
                held = tokio::process::Command::new("/usr/bin/caffeinate")
                    .args(["-s", "-i", "-w", &std::process::id().to_string()])
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .kill_on_drop(true)
                    .spawn()
                    .ok();
            } else if !want {
                if let Some(mut c) = held.take() {
                    let _ = c.kill().await;
                }
            }
            tokio::time::sleep(Duration::from_secs(15)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_login_item_restarts_after_a_crash_and_not_after_a_quit() {
        let p = plist("/Applications/Cookie & Co.app/Contents/MacOS/cookie", "/tmp/e.log");
        assert!(p.contains("<key>RunAtLoad</key><true/>"));
        assert!(p.contains("<key>SuccessfulExit</key><false/>"), "a clean quit stays quit");
        assert!(p.contains("Cookie &amp; Co.app"), "paths are escaped");
        assert!(p.contains(LABEL));
    }
}
