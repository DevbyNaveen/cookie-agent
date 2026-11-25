//! Cookie Hands: one protocol for using apps, on every system.
//!
//! An agent does three things with an app, whatever the system underneath:
//!
//! - **look**: the app's window as a short outline, every button, field, label
//!   and switch with a ref (`e12 button "Send"`), read from the system's own
//!   accessibility layer, never a picture;
//! - **act**: press, set, focus, open a menu, type or press keys, by ref or by
//!   role and name, one step or a batch checked between steps;
//! - **see what changed**: after acting, only the difference comes back.
//!
//! Each system is a [`Body`]: macOS through the Accessibility API, called
//! in-process (`mac`). Windows (UI Automation) and Linux (AT-SPI2) bodies
//! speak the same protocol. Everything above a body (batches, waits, recipes,
//! the outline, the diff) is written once, here.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

#[cfg(target_os = "macos")]
pub mod mac;
#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "windows")]
pub mod windows;

/// One thing on screen an agent can read or use.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Node {
    /// The ref (`e12`) for this look; a new look gives new refs.
    pub id: u32,
    /// Plain role: button, textfield, text, checkbox, link, tab, menuitem…
    pub role: String,
    pub name: String,
    /// A field's text, a checkbox's on/off, a slider's number. Never a password.
    pub value: String,
    /// How deep it sits among the things shown (containers without a name are skipped).
    pub depth: u16,
    pub enabled: bool,
    pub focused: bool,
    /// x, y, width, height in screen points, when the system gives it.
    pub frame: Option<[i32; 4]>,
}

/// An app's window, as an agent reads it.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Snapshot {
    pub app: String,
    pub pid: i32,
    pub window: String,
    pub nodes: Vec<Node>,
    /// More was there than the limit allowed.
    pub truncated: bool,
    pub took_ms: u64,
}

/// What to look at.
#[derive(Debug, Clone, Default)]
pub struct Look {
    /// An app's name; the app in front when empty.
    pub app: Option<String>,
    pub pid: Option<i32>,
    /// Most things to list.
    pub limit: usize,
}

/// An app that is open.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppInfo {
    pub name: String,
    pub pid: i32,
    pub bundle: String,
    pub front: bool,
}

/// What to do to one thing.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Act {
    Press,
    /// Put this text in a field (replacing what's there), or a number in a slider.
    Set(String),
    Focus,
    /// Its context or pop-up menu.
    Menu,
    Increment,
    Decrement,
    Confirm,
    Cancel,
    Raise,
    /// Scroll it into view.
    Show,
}

impl Act {
    pub fn parse(word: &str, value: Option<&str>) -> Result<Self, String> {
        Ok(match word.trim().to_lowercase().as_str() {
            "press" | "click" | "toggle" | "open" | "choose" | "select" => Act::Press,
            "set" | "fill" | "enter" => Act::Set(value.ok_or("`set` needs a `value`.")?.to_string()),
            "focus" => Act::Focus,
            "menu" | "right_click" | "context" => Act::Menu,
            "increment" | "up" => Act::Increment,
            "decrement" | "down" => Act::Decrement,
            "confirm" => Act::Confirm,
            "cancel" => Act::Cancel,
            "raise" => Act::Raise,
            "show" | "scroll" => Act::Show,
            w => return Err(format!("I don't know how to {w:?}. Use press, set, focus, menu, increment, decrement, confirm, cancel, raise or show.")),
        })
    }
}

/// A key with modifiers: `cmd+shift+t`.
#[derive(Debug, Clone, PartialEq)]
pub struct Combo {
    pub key: String,
    pub cmd: bool,
    pub shift: bool,
    pub alt: bool,
    pub ctrl: bool,
}

impl Combo {
    pub fn parse(text: &str) -> Result<Self, String> {
        let mut c = Combo { key: String::new(), cmd: false, shift: false, alt: false, ctrl: false };
        for part in text.split('+').map(|p| p.trim().to_lowercase()).filter(|p| !p.is_empty()) {
            match part.as_str() {
                "cmd" | "command" | "⌘" | "super" | "win" | "meta" => c.cmd = true,
                "shift" | "⇧" => c.shift = true,
                "opt" | "option" | "alt" | "⌥" => c.alt = true,
                "ctrl" | "control" | "⌃" => c.ctrl = true,
                k if c.key.is_empty() => c.key = k.to_string(),
                _ => return Err(format!("{text:?} has two keys; press one key with modifiers, like cmd+shift+t.")),
            }
        }
        if c.key.is_empty() {
            return Err(format!("{text:?} has no key."));
        }
        if c.key.chars().count() > 1 && !NAMED_KEYS.contains(&c.key.as_str()) {
            return Err(format!("I don't know the key {:?}. Use a character or one of: {}.", c.key, NAMED_KEYS.join(", ")));
        }
        Ok(c)
    }
}

pub const NAMED_KEYS: &[&str] = &[
    "return", "enter", "tab", "space", "delete", "backspace", "escape", "esc", "forwarddelete", "home", "end", "pageup", "pagedown", "left", "right", "up",
    "down", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
];

/// A system's hands.
pub trait Body: Send + Sync {
    /// "macos", "windows", "linux".
    fn system(&self) -> &'static str;
    /// Ok when the system lets Cookie read and use apps; else what the person must allow.
    fn ready(&self) -> Result<(), String>;
    fn apps(&self) -> Result<Vec<AppInfo>, String>;
    fn look(&self, q: &Look) -> Result<Snapshot, String>;
    /// Do something to a thing from this app's latest look.
    fn act(&self, pid: i32, id: u32, act: &Act) -> Result<String, String>;
    /// Press keys into an app (in the background where the system allows), or the app in front.
    fn keys(&self, pid: Option<i32>, combo: &Combo) -> Result<(), String>;
    fn type_text(&self, pid: Option<i32>, text: &str) -> Result<(), String>;
    /// Sleep until the app's screen changes (event-driven where the system has events), or the time is up. True if it changed.
    fn wait_change(&self, pid: i32, timeout: Duration) -> bool;
    /// A picture of the app's front window (PNG), for what its outline can't show: a canvas, a chart, a game.
    /// Only that window, never the whole screen.
    fn screenshot(&self, _pid: i32) -> Result<Shot, String> {
        Err("Pictures of windows aren't available on this system yet.".into())
    }
    /// Click a point in the app's latest picture (its pixels). Moves the pointer, so it's the last resort.
    fn click_at(&self, _pid: i32, _x: f64, _y: f64) -> Result<(), String> {
        Err("Clicking a point isn't available on this system yet.".into())
    }
}

/// A picture of one window.
#[derive(Debug, Clone)]
pub struct Shot {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// This system's hands, if it has them.
pub fn body() -> Option<&'static dyn Body> {
    #[cfg(target_os = "macos")]
    {
        return Some(mac::body());
    }
    #[cfg(target_os = "linux")]
    {
        return linux::body().map(|b| b as &'static dyn Body);
    }
    #[cfg(target_os = "windows")]
    {
        return windows::body().map(|b| b as &'static dyn Body);
    }
    #[allow(unreachable_code)]
    None
}

/* ---------- the outline ---------- */

/// What the agent reads: one line per thing, indented by depth.
pub fn render(s: &Snapshot) -> String {
    let mut out = format!("app {} · window {:?} · {} items in {} ms{}\n", s.app, s.window, s.nodes.len(), s.took_ms, if s.truncated { " (more not shown; look with a higher limit)" } else { "" });
    for n in &s.nodes {
        out.push_str(&line(n));
        out.push('\n');
    }
    if s.nodes.is_empty() {
        out.push_str("(nothing readable in this window: the app may not expose its contents; try keys, its menus, or another route)\n");
    }
    out
}

fn line(n: &Node) -> String {
    let mut l = format!("{}e{} {}", "  ".repeat(n.depth.min(8) as usize), n.id, n.role);
    if !n.name.is_empty() {
        l.push_str(&format!(" {:?}", clip(&n.name, 120)));
    }
    if !n.value.is_empty() && n.value != n.name {
        l.push_str(&format!(" = {:?}", clip(&n.value, 160)));
    }
    if !n.enabled {
        l.push_str(" (off)");
    }
    if n.focused {
        l.push_str(" (focused)");
    }
    l
}

pub fn clip(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        s.to_string()
    } else {
        format!("{}…", s.chars().take(n).collect::<String>())
    }
}

/* ---------- what changed ---------- */

/// Things keyed by role and name (and which of that kind), so a ref change isn't a change.
fn keyed(s: &Snapshot) -> Vec<(String, &Node)> {
    let mut seen: HashMap<(String, String), u32> = HashMap::new();
    s.nodes
        .iter()
        .map(|n| {
            let k = (n.role.clone(), n.name.clone());
            let i = seen.entry(k.clone()).or_default();
            *i += 1;
            (format!("{}\u{1f}{}\u{1f}{}", k.0, k.1, i), n)
        })
        .collect()
}

/// The difference between two looks, as lines: `+` new, `-` gone, `~` changed. Refs are the new look's.
pub fn diff(before: &Snapshot, after: &Snapshot) -> Vec<String> {
    let mut out = Vec::new();
    if before.app != after.app {
        out.push(format!("~ app {} → {}", before.app, after.app));
    }
    if before.window != after.window {
        out.push(format!("~ window {:?} → {:?}", before.window, after.window));
    }
    let b: HashMap<String, &Node> = keyed(before).into_iter().collect();
    let a = keyed(after);
    let a_keys: std::collections::HashSet<&String> = a.iter().map(|(k, _)| k).collect();
    for (k, n) in &a {
        match b.get(k) {
            None => out.push(format!("+ {}", line(n).trim_start())),
            Some(old) if old.value != n.value => out.push(format!("~ e{} {} {:?}: {:?} → {:?}", n.id, n.role, clip(&n.name, 60), clip(&old.value, 80), clip(&n.value, 80))),
            Some(old) if old.enabled != n.enabled || old.focused != n.focused => out.push(format!("~ {}", line(n).trim_start())),
            _ => {}
        }
    }
    for (k, n) in keyed(before) {
        if !a_keys.contains(&k) {
            out.push(format!("- {} {:?}", n.role, clip(&n.name, 80)));
        }
    }
    out
}

/* ---------- finding things ---------- */

/// A thing by role and name: an exact name first, then one that contains it. Role is optional.
pub fn find(s: &Snapshot, role: Option<&str>, name: &str) -> Option<u32> {
    let name = name.trim().to_lowercase();
    let role = role.map(|r| r.trim().to_lowercase()).filter(|r| !r.is_empty());
    let fits = |n: &&Node| role.as_deref().is_none_or(|r| n.role == r);
    let label = |n: &Node| if n.name.is_empty() { n.value.to_lowercase() } else { n.name.to_lowercase() };
    s.nodes.iter().filter(fits).find(|n| label(n) == name).or_else(|| s.nodes.iter().filter(fits).find(|n| !name.is_empty() && label(n).contains(&name))).map(|n| n.id)
}

/* ---------- steps, batches and waits ---------- */

/// One step of a batch or a recipe: what to touch (a ref, or role and name) and what to do.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Step {
    /// `e12` from the latest look.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub r#ref: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// press, set, focus, menu, increment, decrement, confirm, cancel, raise, show — or keys, type.
    pub r#do: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
}

impl Step {
    pub fn describe(&self) -> String {
        let what = match (&self.r#ref, &self.role, &self.name) {
            (_, Some(r), Some(n)) => format!("{r} {n:?}"),
            (_, None, Some(n)) => format!("{n:?}"),
            (Some(r), _, _) => r.clone(),
            _ => String::new(),
        };
        match (self.r#do.as_str(), &self.value) {
            ("keys", Some(v)) => format!("press {v}"),
            ("click_at", Some(v)) => format!("click at {v} in the picture"),
            ("type", Some(v)) => format!("type {:?}{}", clip(v, 80), if what.is_empty() { String::new() } else { format!(" into {what}") }),
            (d, Some(v)) => format!("{d} {what} to {:?}", clip(v, 80)),
            (d, None) => format!("{d} {what}"),
        }
    }
}

/// What a batch did.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Done {
    /// Steps done, in order, as they were described.
    pub did: Vec<String>,
    /// Steps resolved to role and name, ready to save as a recipe.
    pub resolved: Vec<Step>,
    pub failed: Option<String>,
    pub changes: Vec<String>,
    pub after: Snapshot,
    pub took_ms: u64,
}

fn ref_id(r: &str) -> Option<u32> {
    r.trim().trim_start_matches('e').parse().ok()
}

/// Run steps in one app, checking the screen between them. Stops at the first step that can't be done.
pub fn run(body: &dyn Body, look: &Look, steps: &[Step], vars: &HashMap<String, String>) -> Result<Done, String> {
    let started = Instant::now();
    let fill = |s: &str| vars.iter().fold(s.to_string(), |acc, (k, v)| acc.replace(&format!("{{{{{k}}}}}"), v));
    let before = body.look(look)?;
    let pid = before.pid;
    let mut current = before.clone();
    let here = Look { app: None, pid: Some(pid), limit: look.limit };
    let (mut did, mut resolved, mut failed) = (Vec::new(), Vec::new(), None);
    for (i, step) in steps.iter().enumerate() {
        let value = step.value.as_deref().map(fill);
        let word = step.r#do.trim().to_lowercase();
        let mut node: Option<Node> = None;
        let target = if step.r#ref.is_some() || step.name.is_some() {
            let by_ref = step.r#ref.as_deref().and_then(ref_id).filter(|id| current.nodes.iter().any(|n| n.id == *id));
            let id = by_ref.or_else(|| step.name.as_deref().map(fill).and_then(|n| find(&current, step.role.as_deref(), &n)));
            match id {
                Some(id) => {
                    node = current.nodes.iter().find(|n| n.id == id).cloned();
                    Some(id)
                }
                None => {
                    failed = Some(format!("step {}: nothing matches {} on screen now", i + 1, step.describe()));
                    break;
                }
            }
        } else {
            None
        };
        let outcome = match (word.as_str(), target) {
            ("click_at", _) => {
                let v = value.clone().unwrap_or_default();
                let mut xy = v.split(',').map(|n| n.trim().parse::<f64>());
                match (xy.next(), xy.next()) {
                    (Some(Ok(x)), Some(Ok(y))) => body.click_at(pid, x, y).map(|_| String::new()),
                    _ => Err("click_at takes `value` as x,y in the picture's pixels.".to_string()),
                }
            }
            ("keys", _) => Combo::parse(value.as_deref().unwrap_or_default()).and_then(|c| body.keys(Some(pid), &c)).map(|_| String::new()),
            ("type", Some(id)) => {
                // Into a field: set it directly (instant, works behind other windows), else focus and type.
                let old = node.as_ref().map(|n| n.value.clone()).unwrap_or_default();
                let text = value.clone().unwrap_or_default();
                body.act(pid, id, &Act::Set(format!("{old}{text}"))).or_else(|_| body.act(pid, id, &Act::Focus).and_then(|_| body.type_text(Some(pid), &text).map(|_| String::new())))
            }
            ("type", None) => body.type_text(Some(pid), value.as_deref().unwrap_or_default()).map(|_| String::new()),
            (w, Some(id)) => Act::parse(w, value.as_deref()).and_then(|a| body.act(pid, id, &a)),
            (w, None) => Err(format!("`{w}` needs a thing to act on: a ref, or a role and name.")),
        };
        if let Err(e) = outcome {
            failed = Some(format!("step {}: {} — {e}", i + 1, step.describe()));
            break;
        }
        did.push(step.describe());
        resolved.push(Step { r#ref: None, role: node.as_ref().map(|n| n.role.clone()).or(step.role.clone()), name: node.as_ref().map(|n| if n.name.is_empty() { n.value.clone() } else { n.name.clone() }).or(step.name.clone()), r#do: word, value: step.value.clone() });
        // Let the app answer before the next step: wakes on its first change, never waits long.
        if i + 1 < steps.len() {
            body.wait_change(pid, Duration::from_millis(400));
            current = body.look(&here)?;
        }
    }
    if steps.len() > 1 || failed.is_some() || current.nodes.is_empty() {
        body.wait_change(pid, Duration::from_millis(250));
    } else {
        body.wait_change(pid, Duration::from_millis(400));
    }
    let after = body.look(&here)?;
    let changes = diff(&before, &after);
    Ok(Done { did, resolved, failed, changes, after, took_ms: started.elapsed().as_millis() as u64 })
}

/// Wait until some text shows up (or goes away) in an app's window. Wakes on the app's own changes.
pub fn wait_for(body: &dyn Body, look: &Look, text: &str, gone: bool, timeout: Duration) -> Result<(bool, Snapshot), String> {
    let deadline = Instant::now() + timeout;
    let want = text.trim().to_lowercase();
    loop {
        let s = body.look(look)?;
        let seen = s.window.to_lowercase().contains(&want) || s.nodes.iter().any(|n| n.name.to_lowercase().contains(&want) || n.value.to_lowercase().contains(&want));
        if seen != gone {
            return Ok((true, s));
        }
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Ok((false, s));
        }
        body.wait_change(s.pid, left.min(Duration::from_secs(1)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    fn node(id: u32, role: &str, name: &str, value: &str) -> Node {
        Node { id, role: role.into(), name: name.into(), value: value.into(), depth: 0, enabled: true, focused: false, frame: None }
    }

    /// A pretend app: a field and a Send button that, once pressed, shows "Sent".
    struct Fake {
        field: Mutex<String>,
        sent: Mutex<bool>,
        keys: Mutex<Vec<String>>,
    }

    impl Body for Fake {
        fn system(&self) -> &'static str {
            "test"
        }
        fn ready(&self) -> Result<(), String> {
            Ok(())
        }
        fn apps(&self) -> Result<Vec<AppInfo>, String> {
            Ok(vec![AppInfo { name: "Mail".into(), pid: 7, bundle: "x".into(), front: true }])
        }
        fn look(&self, _q: &Look) -> Result<Snapshot, String> {
            let mut nodes = vec![node(1, "textfield", "To", &self.field.lock().unwrap()), node(2, "button", "Send", "")];
            if *self.sent.lock().unwrap() {
                nodes.push(node(3, "text", "", "Sent"));
            }
            Ok(Snapshot { app: "Mail".into(), pid: 7, window: "New Message".into(), nodes, truncated: false, took_ms: 1 })
        }
        fn act(&self, _pid: i32, id: u32, act: &Act) -> Result<String, String> {
            match (id, act) {
                (1, Act::Set(v)) => {
                    *self.field.lock().unwrap() = v.clone();
                    Ok("set".into())
                }
                (2, Act::Press) => {
                    *self.sent.lock().unwrap() = true;
                    Ok("pressed".into())
                }
                _ => Err("can't".into()),
            }
        }
        fn keys(&self, _pid: Option<i32>, c: &Combo) -> Result<(), String> {
            self.keys.lock().unwrap().push(c.key.clone());
            Ok(())
        }
        fn type_text(&self, _pid: Option<i32>, _t: &str) -> Result<(), String> {
            Ok(())
        }
        fn wait_change(&self, _pid: i32, _t: Duration) -> bool {
            false
        }
    }

    fn fake() -> Fake {
        Fake { field: Mutex::new(String::new()), sent: Mutex::new(false), keys: Mutex::new(Vec::new()) }
    }

    #[test]
    fn keys_and_acts_are_read_the_way_people_say_them() {
        assert_eq!(Combo::parse("cmd+shift+T").unwrap(), Combo { key: "t".into(), cmd: true, shift: true, alt: false, ctrl: false });
        assert!(Combo::parse("cmd").is_err() && Combo::parse("cmd+a+b").is_err() && Combo::parse("cmd+hyper").is_err());
        assert_eq!(Act::parse("click", None).unwrap(), Act::Press);
        assert_eq!(Act::parse("set", Some("hi")).unwrap(), Act::Set("hi".into()));
        assert!(Act::parse("set", None).is_err() && Act::parse("dance", None).is_err());
    }

    #[test]
    fn a_batch_resolves_by_name_reports_only_changes_and_can_be_replayed() {
        let f = fake();
        let steps = vec![
            Step { role: Some("textfield".into()), name: Some("To".into()), r#do: "type".into(), value: Some("{{who}}".into()), ..Default::default() },
            Step { r#ref: Some("e2".into()), r#do: "press".into(), ..Default::default() },
            Step { r#do: "keys".into(), value: Some("cmd+w".into()), ..Default::default() },
        ];
        let vars = HashMap::from([("who".to_string(), "anna@example.com".to_string())]);
        let done = run(&f, &Look::default(), &steps, &vars).unwrap();
        assert!(done.failed.is_none(), "{:?}", done.failed);
        assert_eq!(done.did.len(), 3);
        assert!(done.changes.iter().any(|c| c.contains("anna@example.com")), "{:?}", done.changes);
        assert!(done.changes.iter().any(|c| c.starts_with("+ e3 text") && c.contains("Sent")), "{:?}", done.changes);
        assert!(!done.changes.iter().any(|c| c.contains("Send\"") && c.starts_with('-')), "unchanged things aren't reported");
        // Saved steps name things by role and name, so they replay without refs.
        assert_eq!(done.resolved[1], Step { role: Some("button".into()), name: Some("Send".into()), r#do: "press".into(), ..Default::default() });
        assert_eq!(f.keys.lock().unwrap().as_slice(), ["w"]);
    }

    #[test]
    fn a_batch_stops_at_the_first_thing_it_cannot_find() {
        let f = fake();
        let steps = vec![Step { name: Some("Archive".into()), r#do: "press".into(), ..Default::default() }, Step { r#ref: Some("e2".into()), r#do: "press".into(), ..Default::default() }];
        let done = run(&f, &Look::default(), &steps, &HashMap::new()).unwrap();
        assert!(done.failed.unwrap().contains("Archive"));
        assert!(done.did.is_empty() && !*f.sent.lock().unwrap(), "nothing after a failed step runs");
    }

    #[test]
    fn waiting_sees_text_appear_and_the_outline_reads_cleanly() {
        let f = fake();
        let (seen, _) = wait_for(&f, &Look::default(), "sent", false, Duration::from_millis(10)).unwrap();
        assert!(!seen);
        *f.sent.lock().unwrap() = true;
        let (seen, s) = wait_for(&f, &Look::default(), "sent", false, Duration::from_millis(10)).unwrap();
        assert!(seen);
        let out = render(&s);
        assert!(out.contains("e2 button \"Send\"") && out.contains("e1 textfield \"To\""), "{out}");
        assert_eq!(find(&s, Some("button"), "send"), Some(2));
        assert_eq!(find(&s, None, "sen"), Some(2), "contains, when nothing matches exactly");
    }
}
