//! Using this Mac, for agents with "Use this Mac" on: open apps, files, links
//! and System Settings panes; read what's on screen; press buttons and menus;
//! type and press keys.
//!
//! - **Reading the screen is text, not pictures.** macOS's accessibility tree
//!   gives every button, field and label of the front window by name, which
//!   any model can act on, and it never sends a screenshot anywhere.
//! - **Opening is free; acting asks.** Opening an app, a pane, a link or a
//!   document changes nothing, so it runs alone (scripts and installers are
//!   refused). Pressing, typing and quitting change things, so they ask like any
//!   other change until the agent has earned your trust.
//! - **macOS asks you once.** Reading and pressing need Cookie in System
//!   Settings → Privacy & Security → Accessibility; when it isn't, the agent is
//!   told, and the pane opens for you.

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

/// Named keys to their key codes; anything else is typed as itself.
fn key_code(k: &str) -> Option<u16> {
    Some(match k {
        "return" | "enter" => 36,
        "tab" => 48,
        "space" => 49,
        "delete" | "backspace" => 51,
        "escape" | "esc" => 53,
        "forwarddelete" => 117,
        "home" => 115,
        "end" => 119,
        "pageup" => 116,
        "pagedown" => 121,
        "left" => 123,
        "right" => 124,
        "down" => 125,
        "up" => 126,
        _ => return None,
    })
}

/// "cmd+shift+t" → (key, is_code, [cmd, shift, option, control]).
fn parse_combo(combo: &str) -> Result<(String, bool, [bool; 4]), String> {
    let mut mods = [false; 4];
    let mut key = None;
    for part in combo.split('+').map(|p| p.trim().to_lowercase()).filter(|p| !p.is_empty()) {
        match part.as_str() {
            "cmd" | "command" | "⌘" => mods[0] = true,
            "shift" | "⇧" => mods[1] = true,
            "opt" | "option" | "alt" | "⌥" => mods[2] = true,
            "ctrl" | "control" | "⌃" => mods[3] = true,
            k if key.is_none() => key = Some(k.to_string()),
            _ => return Err(format!("{combo:?} has two keys; press one key with modifiers, like cmd+shift+t.")),
        }
    }
    let key = key.ok_or_else(|| format!("{combo:?} has no key."))?;
    match key_code(&key) {
        Some(code) => Ok((code.to_string(), true, mods)),
        None if key.chars().count() == 1 => Ok((key, false, mods)),
        None => Err(format!("I don't know the key {key:?}. Use a letter or one of return, tab, space, delete, escape, left, right, up, down, home, end, pageup, pagedown.")),
    }
}

/// What a document may not be: something that runs.
fn runs_something(path: &str) -> bool {
    let p = path.to_lowercase();
    [".app", ".command", ".sh", ".tool", ".pkg", ".mpkg", ".scpt", ".applescript", ".workflow", ".terminal", ".dmg", ".jar", ".py"].iter().any(|x| p.ends_with(x) || p.contains(&format!("{x}/")))
}

const READ_SCREEN: &str = r#"
on clean(x)
  try
    set t to x as text
    if t is "missing value" then return ""
    return t
  on error
    return ""
  end try
end clean
on run argv
  set limit to (item 1 of argv) as integer
  tell application "System Events"
    set p to first application process whose frontmost is true
    set out to "app" & tab & (name of p)
    try
      set AppleScript's text item delimiters to ", "
      set out to out & linefeed & "menus" & tab & ((name of menu bar items of menu bar 1 of p) as text)
      set AppleScript's text item delimiters to ""
    end try
    try
      set w to front window of p
    on error
      return out & linefeed & "(no window)"
    end try
    set out to out & linefeed & "window" & tab & my clean(name of w)
    set n to 0
    repeat with e in (entire contents of w)
      if n ≥ limit then exit repeat
      try
        set r to role of e
        if r is in {"AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXPopUpButton", "AXMenuButton", "AXLink", "AXStaticText", "AXTab", "AXSwitch", "AXSlider", "AXComboBox", "AXSearchField", "AXCell", "AXHeading", "AXDisclosureTriangle"} then
          set t to my clean(name of e)
          if t is "" then set t to my clean(description of e)
          set v to ""
          try
            set v to my clean(value of e)
          end try
          if t is not "" or v is not "" then
            set out to out & linefeed & r & tab & t & tab & v
            set n to n + 1
          end if
        end if
      end try
    end repeat
    return out
  end tell
end run
"#;

const PRESS: &str = r#"
on clean(x)
  try
    set t to x as text
    if t is "missing value" then return ""
    return t
  on error
    return ""
  end try
end clean
on run argv
  set want to item 1 of argv
  tell application "System Events"
    set p to first application process whose frontmost is true
    set hit to missing value
    repeat with e in (entire contents of front window of p)
      try
        if my clean(name of e) is want or my clean(description of e) is want then
          set hit to e
          exit repeat
        end if
      end try
    end repeat
    if hit is missing value then return "none"
    set r to role of hit
    if r is "AXTextField" or r is "AXTextArea" or r is "AXSearchField" or r is "AXComboBox" then
      set focused of hit to true
      return "focused " & r
    end if
    click hit
    return "pressed " & r
  end tell
end run
"#;

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

const KEYS: &str = r#"
on run argv
  set mods to {}
  if item 3 of argv is "1" then set end of mods to command down
  if item 4 of argv is "1" then set end of mods to shift down
  if item 5 of argv is "1" then set end of mods to option down
  if item 6 of argv is "1" then set end of mods to control down
  tell application "System Events"
    if item 2 of argv is "1" then
      key code ((item 1 of argv) as integer) using mods
    else
      keystroke (item 1 of argv) using mods
    end if
  end tell
  return "ok"
end run
"#;

const TYPE: &str = r#"
on run argv
  tell application "System Events" to keystroke (item 1 of argv)
  return "ok"
end run
"#;

const APPS: &str = r#"
tell application "System Events"
  set out to ""
  repeat with p in (application processes whose background only is false)
    set out to out & (name of p) & tab & (frontmost of p) & linefeed
  end repeat
  return out
end tell
"#;

const QUIT: &str = r#"
on run argv
  tell application (item 1 of argv) to quit
  return "ok"
end run
"#;

const ACCESSIBILITY_PANE: &str = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility";

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

async fn open(args: &[&str]) -> Result<(), String> {
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
    out.push(Arc::new(tool(
        "read_screen",
        "Read what's on screen: the front app, its window, and its buttons, fields, labels and switches as text (role, name, value). \
         Use it before pressing anything, and again after, to see what changed.",
        json!({"type": "object", "properties": {"limit": {"type": "integer", "description": "most items to list (default 120)"}}}),
        Effect::Read,
        |a: Value| async move {
            let limit = a["limit"].as_u64().unwrap_or(120).clamp(10, 400);
            osa(READ_SCREEN, &[limit.to_string()]).await
        },
    )));
    out.push(Arc::new(tool(
        "list_apps",
        "The apps open on this Mac, and which one is in front.",
        json!({"type": "object", "properties": {}}),
        Effect::Read,
        |_a: Value| async move { osa(APPS, &[]).await },
    )));
    out.push(Arc::new(
        tool(
            "press",
            "Press a button, switch, tab, link or checkbox in the front window by its exact name (as read_screen shows it). \
             A text field is focused instead, ready for type_text.",
            json!({"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}),
            Effect::Write,
            |a: Value| async move {
                match osa(PRESS, &[s(&a, "name")]).await? {
                    r if r == "none" => Err("Nothing in the front window has exactly that name; read_screen again.".into()),
                    r => Ok(r),
                }
            },
        )
        .with_preview(|a| format!("Press “{}”", s(a, "name"))),
    ));
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
            "type_text",
            "Type text into whatever has focus in the front app.",
            json!({"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}),
            Effect::Write,
            |a: Value| async move { osa(TYPE, &[a["text"].as_str().unwrap_or_default().to_string()]).await.map(|_| "Typed.".into()) },
        )
        .with_preview(|a| format!("Type: {}", crate::util::clip(a["text"].as_str().unwrap_or_default(), 120))),
    ));
    out.push(Arc::new(
        tool(
            "press_keys",
            "Press a key, with modifiers: \"return\", \"escape\", \"cmd+t\", \"cmd+shift+n\", \"down\".",
            json!({"type": "object", "properties": {"keys": {"type": "string"}}, "required": ["keys"]}),
            Effect::Write,
            |a: Value| async move {
                let (key, code, m) = parse_combo(&s(&a, "keys"))?;
                let b = |x: bool| if x { "1".to_string() } else { "0".to_string() };
                osa(KEYS, &[key, b(code), b(m[0]), b(m[1]), b(m[2]), b(m[3])]).await.map(|_| "Pressed.".into())
            },
        )
        .with_preview(|a| format!("Press {}", s(a, "keys"))),
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
    fn panes_keys_and_documents_are_read_the_way_people_say_them() {
        assert_eq!(pane_for("Wi-Fi"), Some("com.apple.wifi-settings-extension"));
        assert_eq!(pane_for("bluetooth settings"), Some("com.apple.BluetoothSettings"));
        assert_eq!(pane_for("turn on dark mode"), Some("com.apple.Appearance-Settings.extension"));
        assert_eq!(pane_for("nonsense"), None);
        assert_eq!(parse_combo("cmd+shift+T").unwrap(), ("t".into(), false, [true, true, false, false]));
        assert_eq!(parse_combo("return").unwrap(), ("36".into(), true, [false; 4]));
        assert!(parse_combo("cmd+a+b").is_err() && parse_combo("cmd").is_err() && parse_combo("cmd+hyper").is_err());
        assert!(runs_something("/Applications/Evil.app") && runs_something("~/x/run.command") && runs_something("/x/Foo.app/Contents/MacOS/foo"));
        assert!(!runs_something("~/Documents/plan.pdf"));
    }
}
