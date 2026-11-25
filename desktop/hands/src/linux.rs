//! Linux hands: AT-SPI2, the desktop accessibility bus (GTK, Qt, Chromium,
//! Electron, LibreOffice, Firefox), over D-Bus in pure Rust (`atspi`).
//!
//! - **Reading** walks the app's window on the accessibility bus: role, name,
//!   description, state, and a field's text or a slider's number.
//! - **Acting needs no input device.** Press is the element's own action,
//!   set is `EditableText`/`Value`, focus is `Component.grab_focus`: these work
//!   on X11 and on Wayland, in the person's session or a hidden one.
//! - **Keys** go through the bus's device event controller (works on X11 and
//!   in hidden sessions); on a Wayland desktop that refuses them, `wtype` or
//!   `ydotool` is used when installed, and the agent is told when neither is.
//!
//! Chromium and Electron apps join the bus when the session has accessibility
//! on (`ACCESSIBILITY_ENABLED=1` or a running at-spi bus); Cookie switches the
//! session's accessibility on when it starts looking.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use atspi::proxy::accessible::AccessibleProxy;
use atspi::proxy::device_event_controller::{DeviceEventControllerProxy, KeySynthType};
use atspi::proxy::proxy_ext::ProxyExt;
use atspi::zbus;
use atspi::{CoordType, Interface, Role, ScrollType, State};

use crate::{Act, AppInfo, Body, Combo, Look, Node, Snapshot};

pub struct Linux {
    rt: tokio::runtime::Runtime,
    conn: zbus::Connection,
    /// The latest look's things per app: (bus name, object path).
    refs: Mutex<HashMap<i32, Vec<(String, String)>>>,
}

static BODY: OnceLock<Result<Linux, String>> = OnceLock::new();

pub fn body() -> Option<&'static Linux> {
    BODY.get_or_init(|| {
        let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().map_err(|e| e.to_string())?;
        let conn = rt.block_on(async {
            // Chromium and Electron join the bus only when the session says accessibility is on.
            let _ = atspi::connection::set_session_accessibility(true).await;
            atspi::AccessibilityConnection::new().await.map(|c| c.connection().clone())
        });
        let conn = conn.map_err(|e| format!("The accessibility bus isn't running: {e}"))?;
        Ok(Linux { rt, conn, refs: Mutex::new(HashMap::new()) })
    })
    .as_ref()
    .ok()
}

fn e(err: impl std::fmt::Display) -> String {
    err.to_string()
}

async fn proxy(conn: &zbus::Connection, dest: &str, path: &str) -> Result<AccessibleProxy<'static>, String> {
    AccessibleProxy::builder(conn)
        .destination(dest.to_string())
        .map_err(e)?
        .path(path.to_string())
        .map_err(e)?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()
        .await
        .map_err(e)
}

fn parts(r: &atspi::ObjectRefOwned) -> Option<(String, String)> {
    Some((r.name_as_str()?.to_string(), r.path_as_str().to_string()))
}

async fn pid_of(conn: &zbus::Connection, bus: &str) -> i32 {
    let Ok(dbus) = zbus::fdo::DBusProxy::new(conn).await else { return 0 };
    match zbus::names::BusName::try_from(bus.to_string()) {
        Ok(name) => dbus.get_connection_unix_process_id(name).await.map(|p| p as i32).unwrap_or(0),
        Err(_) => 0,
    }
}

/// "_OK" → "OK", "Save _As…" → "Save As…"; a doubled "__" stays one underscore.
fn mnemonic_free(name: &str) -> String {
    name.replace("__", "\u{0}").replace('_', "").replace('\u{0}', "_")
}

/// The plain role an agent reads.
fn plain(role: Role) -> String {
    match role {
        Role::ToggleButton | Role::Button => "button".into(),
        Role::Entry | Role::PasswordText | Role::Text => if role == Role::PasswordText { "password".into() } else { "textfield".into() },
        Role::Label | Role::Static | Role::Paragraph => "text".into(),
        Role::CheckBox | Role::CheckMenuItem => "checkbox".into(),
        Role::RadioButton | Role::RadioMenuItem => "radio".into(),
        Role::ComboBox => "combobox".into(),
        Role::MenuItem => "menuitem".into(),
        Role::Menu => "menu".into(),
        Role::PageTab => "tab".into(),
        Role::Link => "link".into(),
        Role::Slider => "slider".into(),
        Role::SpinButton => "stepper".into(),
        Role::Heading => "heading".into(),
        Role::DocumentWeb | Role::DocumentFrame => "page".into(),
        Role::Image | Role::Icon => "image".into(),
        r => r.name().replace(' ', ""),
    }
}

fn usable(role: Role) -> bool {
    matches!(
        role,
        Role::ToggleButton
            | Role::Button
            | Role::Entry
            | Role::PasswordText
            | Role::CheckBox
            | Role::CheckMenuItem
            | Role::RadioButton
            | Role::RadioMenuItem
            | Role::ComboBox
            | Role::MenuItem
            | Role::Menu
            | Role::PageTab
            | Role::Link
            | Role::Slider
            | Role::SpinButton
    )
}

impl Linux {
    async fn app_list(&self) -> Result<Vec<(AppInfo, String, String)>, String> {
        let root = proxy(&self.conn, "org.a11y.atspi.Registry", "/org/a11y/atspi/accessible/root").await?;
        let mut out = Vec::new();
        for child in root.get_children().await.map_err(e)? {
            let Some((bus, path)) = parts(&child) else { continue };
            let Ok(app) = proxy(&self.conn, &bus, &path).await else { continue };
            let name = app.name().await.unwrap_or_default();
            if name.is_empty() {
                continue;
            }
            // In front: one of its windows is active.
            let mut front = false;
            for w in app.get_children().await.unwrap_or_default() {
                if let Some((wb, wp)) = parts(&w) {
                    if let Ok(win) = proxy(&self.conn, &wb, &wp).await {
                        if win.get_state().await.is_ok_and(|s| s.contains(State::Active)) {
                            front = true;
                            break;
                        }
                    }
                }
            }
            let pid = pid_of(&self.conn, &bus).await;
            out.push((AppInfo { name, pid, bundle: bus.clone(), front }, bus, path));
        }
        Ok(out)
    }

    async fn look_async(&self, q: &Look) -> Result<Snapshot, String> {
        let started = Instant::now();
        let apps = self.app_list().await?;
        let want = q.app.as_deref().map(|a| a.trim().to_lowercase()).filter(|a| !a.is_empty());
        let (app, bus, path) = match (q.pid, want) {
            (Some(pid), _) => apps.into_iter().find(|a| a.0.pid == pid),
            (None, Some(w)) => {
                let exact = apps.iter().position(|a| a.0.name.to_lowercase() == w);
                let i = exact.or_else(|| apps.iter().position(|a| a.0.name.to_lowercase().contains(&w)));
                i.map(|i| apps.into_iter().nth(i).unwrap())
            }
            (None, None) => apps.into_iter().find(|a| a.0.front),
        }
        .ok_or("That app isn't open (or isn't on the accessibility bus).")?;
        let root = proxy(&self.conn, &bus, &path).await?;
        // The active window, else the first.
        let mut window = None;
        for w in root.get_children().await.map_err(e)? {
            let Some((wb, wp)) = parts(&w) else { continue };
            let Ok(p) = proxy(&self.conn, &wb, &wp).await else { continue };
            let active = p.get_state().await.is_ok_and(|s| s.contains(State::Active));
            if active || window.is_none() {
                window = Some((p, wb, wp));
            }
            if active {
                break;
            }
        }
        let limit = if q.limit == 0 { 250 } else { q.limit.clamp(10, 1500) };
        let deadline = started + Duration::from_millis(4000);
        let mut nodes = Vec::new();
        let mut held = Vec::new();
        let mut truncated = false;
        let mut title = "(no window)".to_string();
        if let Some((win, wb, wp)) = window {
            title = win.name().await.unwrap_or_default();
            let mut stack: Vec<(String, String, u16)> = vec![(wb, wp, 0)];
            let mut visited = 0;
            while let Some((b, p, depth)) = stack.pop() {
                visited += 1;
                if nodes.len() >= limit || visited > 6000 || Instant::now() > deadline {
                    truncated = true;
                    break;
                }
                let Ok(el) = proxy(&self.conn, &b, &p).await else { continue };
                let state = el.get_state().await.unwrap_or_default();
                if !state.contains(State::Showing) && depth > 0 {
                    continue;
                }
                let role = el.get_role().await.unwrap_or(Role::Invalid);
                // GTK marks a shortcut letter with "_" ("_OK"): people read "OK".
                let mut name = mnemonic_free(&el.name().await.unwrap_or_default());
                if name.is_empty() {
                    name = el.description().await.unwrap_or_default();
                }
                let ifaces = el.get_interfaces().await.unwrap_or_default();
                let px = el.proxies().await.ok();
                let mut value = String::new();
                if role == Role::PasswordText {
                    value = "•••".into();
                } else if ifaces.contains(Interface::Value) {
                    if let Some(v) = px.as_ref() {
                        if let Ok(vp) = v.value().await {
                            value = vp.current_value().await.map(|n| if n.fract() == 0.0 { format!("{}", n as i64) } else { format!("{n:.2}") }).unwrap_or_default();
                        }
                    }
                } else if ifaces.contains(Interface::Text) && matches!(role, Role::Entry | Role::Text | Role::Label | Role::Static | Role::Paragraph | Role::Heading | Role::Link) {
                    if let Some(v) = px.as_ref() {
                        if let Ok(tp) = v.text().await {
                            value = tp.get_text(0, -1).await.unwrap_or_default();
                        }
                    }
                }
                if matches!(role, Role::Label | Role::Static | Role::Paragraph) && name.is_empty() {
                    name = std::mem::take(&mut value);
                }
                let use_it = usable(role);
                let shown = use_it || role == Role::Heading || !name.is_empty() || !value.is_empty();
                let skip = matches!(role, Role::Frame | Role::Window | Role::Application | Role::ScrollBar | Role::Filler | Role::Panel | Role::Section) && name.is_empty();
                let mut child_depth = depth;
                if shown && !skip {
                    let frame = match px.as_ref() {
                        Some(v) => match v.component().await {
                            Ok(c) => c.get_extents(CoordType::Screen).await.ok().map(|(x, y, w, h)| [x, y, w, h]),
                            Err(_) => None,
                        },
                        None => None,
                    };
                    nodes.push(Node {
                        id: nodes.len() as u32 + 1,
                        role: plain(role),
                        name: name.replace('\n', " "),
                        value: value.replace('\n', " ⏎ "),
                        depth,
                        enabled: state.contains(State::Enabled) || state.contains(State::Sensitive),
                        focused: state.contains(State::Focused),
                        frame,
                    });
                    held.push((b.clone(), p.clone()));
                    child_depth = depth + 1;
                }
                if use_it && !name.is_empty() && !matches!(role, Role::Menu | Role::ComboBox) {
                    continue;
                }
                let kids = el.get_children().await.unwrap_or_default();
                for k in kids.iter().rev() {
                    if let Some((kb, kp)) = parts(k) {
                        stack.push((kb, kp, child_depth));
                    }
                }
            }
        }
        self.refs.lock().unwrap().insert(app.pid, held);
        Ok(Snapshot { app: app.name, pid: app.pid, window: title, nodes, truncated, took_ms: started.elapsed().as_millis() as u64, url: None })
    }

    async fn act_async(&self, pid: i32, id: u32, act: &Act) -> Result<String, String> {
        let (b, p) = {
            let refs = self.refs.lock().unwrap();
            let list = refs.get(&pid).ok_or("Look at the app first; refs come from a look.")?;
            list.get(id.saturating_sub(1) as usize).cloned().ok_or_else(|| format!("There's no e{id} in the latest look; look again."))?
        };
        let el = proxy(&self.conn, &b, &p).await?;
        let px = el.proxies().await.map_err(|_| "That is gone from the screen; look again.".to_string())?;
        let by_name = |names: &'static [&'static str]| async move {
            let a = px.action().await.map_err(|_| "That can't be used that way.".to_string())?;
            let actions = a.get_actions().await.map_err(e)?;
            let i = actions.iter().position(|x| names.contains(&x.name.to_lowercase().as_str())).or(if names.contains(&"*") { Some(0) } else { None });
            match i {
                Some(i) if a.do_action(i as i32).await.map_err(e)? => Ok("done".to_string()),
                Some(_) => Err("The app refused.".to_string()),
                None => Err(format!("It has no {} action.", names[0])),
            }
        };
        match act {
            Act::Press => by_name(&["click", "press", "activate", "toggle", "jump", "open", "*"]).await.map(|_| "pressed".into()),
            Act::Set(v) => {
                let px = el.proxies().await.map_err(e)?;
                if let Ok(n) = v.trim().parse::<f64>() {
                    if let Ok(val) = px.value().await {
                        return val.set_current_value(n).await.map(|_| "set".into()).map_err(e);
                    }
                }
                let t = px.editable_text().await.map_err(|_| "That field can't be set directly; focus it and type.".to_string())?;
                if t.set_text_contents(v).await.map_err(e)? {
                    Ok("set".into())
                } else {
                    Err("The app didn't take the text; focus it and type instead.".into())
                }
            }
            Act::Focus => {
                let c = el.proxies().await.map_err(e)?.component().await.map_err(|_| "That can't take focus.".to_string())?;
                if c.grab_focus().await.map_err(e)? {
                    Ok("focused".into())
                } else {
                    Err("The app didn't give it focus.".into())
                }
            }
            Act::Show => {
                let c = el.proxies().await.map_err(e)?.component().await.map_err(|_| "That can't be scrolled to.".to_string())?;
                c.scroll_to(ScrollType::Anywhere).await.map_err(e).map(|_| "shown".into())
            }
            Act::Menu => by_name(&["showmenu", "menu", "popup", "show menu"]).await.map(|_| "menu open".into()),
            Act::Increment => by_name(&["increment", "increase"]).await.map(|_| "increased".into()),
            Act::Decrement => by_name(&["decrement", "decrease"]).await.map(|_| "decreased".into()),
            Act::Confirm => by_name(&["confirm", "activate", "default"]).await.map(|_| "confirmed".into()),
            Act::Cancel => by_name(&["cancel", "close", "dismiss"]).await.map(|_| "cancelled".into()),
            Act::Raise => by_name(&["raise", "activate"]).await.map(|_| "raised".into()),
        }
    }

    async fn dec(&self) -> Result<DeviceEventControllerProxy<'static>, String> {
        DeviceEventControllerProxy::builder(&self.conn).cache_properties(zbus::proxy::CacheProperties::No).build().await.map_err(e)
    }
}

/// X keysym names for named keys.
fn keysym(k: &str) -> String {
    match k {
        "return" | "enter" => "Return".into(),
        "tab" => "Tab".into(),
        "space" => "space".into(),
        "delete" | "backspace" => "BackSpace".into(),
        "forwarddelete" => "Delete".into(),
        "escape" | "esc" => "Escape".into(),
        "home" => "Home".into(),
        "end" => "End".into(),
        "pageup" => "Page_Up".into(),
        "pagedown" => "Page_Down".into(),
        "left" => "Left".into(),
        "right" => "Right".into(),
        "up" => "Up".into(),
        "down" => "Down".into(),
        f if f.starts_with('f') && f[1..].parse::<u8>().is_ok() => f.to_uppercase(),
        c => c.to_string(),
    }
}

/// X modifier masks: Shift 1, Control 4, Mod1 (Alt) 8, Mod4 (Super) 64.
fn mask(c: &Combo) -> i32 {
    (if c.shift { 1 } else { 0 }) | (if c.ctrl { 4 } else { 0 }) | (if c.alt { 8 } else { 0 }) | (if c.cmd { 64 } else { 0 })
}

/// On a Wayland desktop the bus may refuse keys: a tool that speaks Wayland's input protocols, if installed.
fn wayland_keys(c: Option<&Combo>, text: Option<&str>) -> Result<(), String> {
    if std::env::var_os("WAYLAND_DISPLAY").is_none() {
        return Err("The desktop refused the keys.".into());
    }
    let has = |t: &str| std::process::Command::new("sh").arg("-c").arg(format!("command -v {t}")).output().is_ok_and(|o| o.status.success());
    if has("wtype") {
        let mut args: Vec<String> = Vec::new();
        if let Some(c) = c {
            for (on, m) in [(c.ctrl, "ctrl"), (c.alt, "alt"), (c.shift, "shift"), (c.cmd, "logo")] {
                if on {
                    args.extend(["-M".into(), m.into()]);
                }
            }
            if c.key.chars().count() == 1 {
                args.push(c.key.clone());
            } else {
                args.extend(["-k".into(), keysym(&c.key)]);
            }
        }
        if let Some(t) = text {
            args.push(t.to_string());
        }
        let ok = std::process::Command::new("wtype").args(&args).status().is_ok_and(|s| s.success());
        return if ok { Ok(()) } else { Err("wtype couldn't send the keys.".into()) };
    }
    Err("This Wayland desktop doesn't take keys from apps; install `wtype` (wlroots desktops) or use a hidden session.".into())
}

impl Body for Linux {
    fn system(&self) -> &'static str {
        "linux"
    }

    fn ready(&self) -> Result<(), String> {
        Ok(())
    }

    fn apps(&self) -> Result<Vec<AppInfo>, String> {
        self.rt.block_on(self.app_list()).map(|v| v.into_iter().map(|a| a.0).collect())
    }

    fn look(&self, q: &Look) -> Result<Snapshot, String> {
        self.rt.block_on(self.look_async(q))
    }

    fn act(&self, pid: i32, id: u32, act: &Act) -> Result<String, String> {
        self.rt.block_on(self.act_async(pid, id, act))
    }

    fn keys(&self, _pid: Option<i32>, c: &Combo) -> Result<(), String> {
        let sent = self.rt.block_on(async {
            let dec = self.dec().await?;
            let m = mask(c);
            if m != 0 {
                dec.generate_keyboard_event(m, "", KeySynthType::Lockmodifiers).await.map_err(e)?;
            }
            let r = dec.generate_keyboard_event(0, &keysym(&c.key), KeySynthType::Sym).await.map_err(e);
            if m != 0 {
                let _ = dec.generate_keyboard_event(m, "", KeySynthType::Unlockmodifiers).await;
            }
            r
        });
        sent.or_else(|_| wayland_keys(Some(c), None))
    }

    fn type_text(&self, _pid: Option<i32>, text: &str) -> Result<(), String> {
        let sent = self.rt.block_on(async { self.dec().await?.generate_keyboard_event(0, text, KeySynthType::String).await.map_err(e) });
        sent.or_else(|_| wayland_keys(None, Some(text)))
    }

    fn wait_change(&self, _pid: i32, timeout: Duration) -> bool {
        // The bus has change events; the first version polls in short steps.
        std::thread::sleep(timeout.min(Duration::from_millis(200)));
        false
    }
}
