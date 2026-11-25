//! Using this Mac, for agents with "Use this Mac" on: open apps, files, links
//! and System Settings panes, choose menus, quit apps. Reading and using what's
//! in an app's window is Cookie Hands (`hands`).
//!
//! - **Opening is free; acting asks.** Opening an app, a pane, a link or a
//!   document changes nothing, so it runs alone (scripts and installers are
//!   refused). Pressing, typing and quitting change things, so they ask like any
//!   other change until the agent has earned your trust.
//! - **macOS asks you once.** Menus need Cookie in System Settings → Privacy &
//!   Security → Accessibility; when it isn't, the agent is told, and the pane
//!   opens for you.

use std::sync::Arc;
use std::time::Duration;

use cookie_harness::tool::{tool, Effect, Tool};
use serde_json::{json, Value};

/// System Settings panes by the words people use, to their real identifiers
/// (`/System/Library/ExtensionKit/Extensions`).
const PANES: &[(&[&str], &str)] = &[
    (&["wifi", "wi-fi", "wireless"], "com.apple.wifi-settings-extension"),
    (&["bluetooth"], "com.apple.BluetoothSettings"),
    (&["network", "vpn", "ethernet"], "com.apple.Network-Settings.extension"),
    (&["sound", "volume", "audio", "output", "input"], "com.apple.Sound-Settings.extension"),
    (&["displays", "display", "monitor", "night shift", "resolution"], "com.apple.Displays-Settings.extension"),
    (&["battery", "energy", "power"], "com.apple.Battery-Settings.extension"),
    (&["privacy", "security", "privacy & security", "permissions"], "com.apple.settings.PrivacySecurity.extension"),
    (&["accessibility"], "com.apple.Accessibility-Settings.extension"),
    (&["notifications"], "com.apple.Notifications-Settings.extension"),
    (&["focus", "do not disturb"], "com.apple.Focus-Settings.extension"),
    (&["screen time"], "com.apple.Screen-Time-Settings.extension"),
    (&["general"], "com.apple.systempreferences.GeneralSettings"),
    (&["appearance", "dark mode", "light mode"], "com.apple.Appearance-Settings.extension"),
    (&["control center", "menu bar"], "com.apple.ControlCenter-Settings.extension"),
    (&["desktop", "dock", "stage manager", "mission control", "hot corners"], "com.apple.Desktop-Settings.extension"),
    (&["wallpaper", "background"], "com.apple.Wallpaper-Settings.extension"),
    (&["lock screen", "screen saver"], "com.apple.Lock-Screen-Settings.extension"),
    (&["keyboard", "dictation", "shortcuts"], "com.apple.Keyboard-Settings.extension"),
    (&["trackpad"], "com.apple.Trackpad-Settings.extension"),
    (&["mouse"], "com.apple.Mouse-Settings.extension"),
    (&["users", "groups", "accounts"], "com.apple.Users-Groups-Settings.extension"),
    (&["internet accounts", "mail accounts"], "com.apple.Internet-Accounts-Settings.extension"),
    (&["software update", "update", "updates"], "com.apple.Software-Update-Settings.extension"),
    (&["storage", "disk space"], "com.apple.settings.Storage"),
    (&["airdrop", "handoff"], "com.apple.AirDrop-Handoff-Settings.extension"),
    (&["sharing", "screen sharing", "file sharing"], "com.apple.Sharing-Settings.extension"),
    (&["login items", "startup"], "com.apple.LoginItems-Settings.extension"),
    (&["date", "time", "date & time", "clock"], "com.apple.Date-Time-Settings.extension"),
    (&["language", "region", "language & region"], "com.apple.Localization-Settings.extension"),
    (&["siri", "apple intelligence"], "com.apple.Siri-Settings.extension"),
    (&["spotlight"], "com.apple.Spotlight-Settings.extension"),
    (&["touch id", "password"], "com.apple.Touch-ID-Settings.extension"),
    (&["printers", "scanners", "printer"], "com.apple.Print-Scan-Settings.extension"),
    (&["time machine", "backup"], "com.apple.Time-Machine-Settings.extension"),
];

fn pane_for(words: &str) -> Option<&'static str> {
    let w = words.trim().to_lowercase();
    let w = w.trim_end_matches(" settings").trim();
    PANES.iter().find(|(names, _)| names.iter().any(|n| *n == w)).or_else(|| PANES.iter().find(|(names, _)| names.iter().any(|n| w.contains(n)))).map(|(_, id)| *id)
}

/// What a document may not be: something that runs.
fn runs_something(path: &str) -> bool {
    let p = path.to_lowercase();
    [".app", ".command", ".sh", ".tool", ".pkg", ".mpkg", ".scpt", ".applescript", ".workflow", ".terminal", ".dmg", ".jar", ".py"].iter().any(|x| p.ends_with(x) || p.contains(&format!("{x}/")))
}

const MENU: &str = r#"
on run argv
  tell application "System Events"
    set p to first application process whose frontmost is true
    set top to item 1 of argv
    set target to menu bar item top of menu bar 1 of p
    set m to menu top of target
    set n to count of argv
    repeat with i from 2 to n - 1
      set m to menu (item i of argv) of menu item (item i of argv) of m
    end repeat
    click menu item (item n of argv) of m
    return "chose " & (name of p)
  end tell
end run
"#;

const QUIT: &str = r#"
on run argv
  tell application (item 1 of argv) to quit
  return "ok"
end run
"#;

pub(crate) const ACCESSIBILITY_PANE: &str = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility";

async fn osa(script: &str, args: &[String]) -> Result<String, String> {
    if !cfg!(target_os = "macos") {
        return Err("Using the computer is only possible on a Mac.".into());
    }
    let mut cmd = tokio::process::Command::new("/usr/bin/osascript");
    cmd.arg("-e").arg(script).args(args).kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(45), cmd.output()).await.map_err(|_| "The Mac took too long to answer (45 s).".to_string())?.map_err(|e| e.to_string())?;
    if out.status.success() {
        return Ok(String::from_utf8_lossy(&out.stdout).trim().to_string());
    }
    let err = String::from_utf8_lossy(&out.stderr);
    if err.contains("-1719") || err.contains("-25211") || err.contains("assistive access") || err.contains("not allowed to send keystrokes") {
        let _ = open(&[ACCESSIBILITY_PANE]).await;
        return Err("macOS hasn't let Cookie use the screen yet. I opened System Settings → Privacy & Security → Accessibility: switch Cookie on there (once), then ask again.".into());
    }
    if err.contains("-1743") || err.contains("Not authorized") {
        return Err("macOS hasn't let Cookie control that app yet. Allow it in System Settings → Privacy & Security → Automation, then ask again.".into());
    }
    Err(format!("The Mac said: {}", err.trim().lines().last().unwrap_or("an error")))
}

pub(crate) async fn open(args: &[&str]) -> Result<(), String> {
    let out = tokio::time::timeout(Duration::from_secs(20), tokio::process::Command::new("/usr/bin/open").args(args).kill_on_drop(true).output())
        .await
        .map_err(|_| "Opening took too long.".to_string())?
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().lines().last().unwrap_or("It couldn't be opened.").to_string())
    }
}

fn s(args: &Value, k: &str) -> String {
    args[k].as_str().unwrap_or_default().trim().to_string()
}

fn home_path(p: &str) -> String {
    match (p.strip_prefix("~/"), std::env::var("HOME")) {
        (Some(rest), Ok(h)) => format!("{h}/{rest}"),
        _ => p.to_string(),
    }
}

pub(crate) fn tools() -> Vec<Arc<dyn Tool>> {
    let mut out: Vec<Arc<dyn Tool>> = Vec::new();
    out.push(Arc::new(tool(
        "open_app",
        "Open an app on this Mac (or bring it to the front), by its name: Safari, Notes, System Settings, Spotify…",
        json!({"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}),
        Effect::Read,
        |a: Value| async move {
            let name = s(&a, "name");
            if name.is_empty() || name.contains('/') {
                return Err("Give the app's name, like Safari.".into());
            }
            open(&["-a", &name]).await.map_err(|_| format!("There's no app called {name:?} on this Mac."))?;
            Ok(format!("{name} is open and in front."))
        },
    )));
    out.push(Arc::new(tool(
        "open_settings",
        "Open System Settings at a pane: wifi, bluetooth, network, sound, displays, battery, privacy, accessibility, notifications, focus, \
         general, appearance, desktop & dock, wallpaper, lock screen, keyboard, trackpad, mouse, users, software update, storage, sharing, \
         login items, date & time, language & region, siri, spotlight, touch id, printers, time machine. Empty opens its front page.",
        json!({"type": "object", "properties": {"pane": {"type": "string"}}}),
        Effect::Read,
        |a: Value| async move {
            let pane = s(&a, "pane");
            if pane.is_empty() {
                open(&["-b", "com.apple.systempreferences"]).await?;
                return Ok("System Settings is open.".into());
            }
            match pane_for(&pane) {
                Some(id) => {
                    open(&[&format!("x-apple.systempreferences:{id}")]).await?;
                    Ok(format!("System Settings is open at {pane}."))
                }
                None => {
                    open(&["-b", "com.apple.systempreferences"]).await?;
                    Ok(format!("System Settings is open; it has no pane called {pane:?}, so it's on its front page. Use read_screen to find it."))
                }
            }
        },
    )));
    out.push(Arc::new(tool(
        "open_item",
        "Open a link (https, mailto) in its app, or a document or folder on this Mac in its usual app (Finder for a folder). \
         Never something that runs: apps, scripts and installers are refused.",
        json!({"type": "object", "properties": {"target": {"type": "string", "description": "https://…, mailto:…, or a path like ~/Documents/plan.pdf"}}, "required": ["target"]}),
        Effect::Read,
        |a: Value| async move {
            let t = s(&a, "target");
            if t.starts_with("https://") || t.starts_with("http://") || t.starts_with("mailto:") {
                open(&[&t]).await?;
                return Ok(format!("Opened {t}."));
            }
            let path = home_path(&t);
            if !path.starts_with('/') {
                return Err("Give a full path (~/… or /…) or a link.".into());
            }
            if runs_something(&path) {
                return Err("That would run something; open_item only opens documents, folders and links.".into());
            }
            if !std::path::Path::new(&path).exists() {
                return Err(format!("Nothing is at {t}."));
            }
            open(&[&path]).await?;
            Ok(format!("Opened {t}."))
        },
    )));
    out.push(Arc::new(
        tool(
            "choose_menu",
            "Choose a menu item in the front app's menu bar, by its path: [\"File\", \"New Window\"] or [\"View\", \"Sort By\", \"Name\"].",
            json!({"type": "object", "properties": {"path": {"type": "array", "items": {"type": "string"}, "minItems": 2}}, "required": ["path"]}),
            Effect::Write,
            |a: Value| async move {
                let path: Vec<String> = a["path"].as_array().map(|p| p.iter().filter_map(|x| x.as_str().map(str::to_string)).collect()).unwrap_or_default();
                if path.len() < 2 {
                    return Err("A menu path has at least two parts, like [\"File\", \"New Window\"].".into());
                }
                osa(MENU, &path).await
            },
        )
        .with_preview(|a| format!("Choose {}", a["path"].as_array().map(|p| p.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(" → ")).unwrap_or_default())),
    ));
    out.push(Arc::new(
        tool(
            "quit_app",
            "Quit an app on this Mac, by name. It may ask to save first.",
            json!({"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}),
            Effect::Write,
            |a: Value| async move { osa(QUIT, &[s(&a, "name")]).await.map(|_| "Quit.".into()) },
        )
        .with_preview(|a| format!("Quit {}", s(a, "name"))),
    ));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panes_and_documents_are_read_the_way_people_say_them() {
        assert_eq!(pane_for("Wi-Fi"), Some("com.apple.wifi-settings-extension"));
        assert_eq!(pane_for("bluetooth settings"), Some("com.apple.BluetoothSettings"));
        assert_eq!(pane_for("turn on dark mode"), Some("com.apple.Appearance-Settings.extension"));
        assert_eq!(pane_for("nonsense"), None);
        assert!(runs_something("/Applications/Evil.app") && runs_something("~/x/run.command") && runs_something("/x/Foo.app/Contents/MacOS/foo"));
        assert!(!runs_something("~/Documents/plan.pdf"));
    }
}
