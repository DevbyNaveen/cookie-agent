//! Windows hands: UI Automation, Windows' own accessibility layer.
//!
//! - **Reading** walks the app's top window through the control view: each
//!   element's control type, name, value (Value, RangeValue and Toggle
//!   patterns), enabled, focus and bounds. Passwords are never read.
//! - **Acting uses the element's own patterns** (Invoke, Toggle, Value,
//!   RangeValue, ExpandCollapse, ScrollItem, SelectionItem): no mouse, and it
//!   works on windows that aren't in front.
//! - **Keys** go to the window in front (`SendInput`): when an agent sends keys
//!   to an app behind others, Cookie brings its window forward first and says so.
//!
//! UI Automation's COM objects stay on the one thread that made them, so a
//! single worker thread owns the automation object and every ref; the
//! protocol's calls are sent to it and wait for the answer.

use std::collections::HashMap;
use std::sync::mpsc::{channel, Sender};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use uiautomation::patterns::{UIExpandCollapsePattern, UIInvokePattern, UIRangeValuePattern, UIScrollItemPattern, UISelectionItemPattern, UITogglePattern, UIValuePattern};
use uiautomation::types::ControlType;
use uiautomation::{UIAutomation, UIElement, UITreeWalker};

use crate::{Act, AppInfo, Body, Combo, Look, Node, Snapshot};

struct State {
    auto: UIAutomation,
    walker: UITreeWalker,
    /// The latest look's elements per app.
    refs: HashMap<i32, Vec<UIElement>>,
}

type Job = Box<dyn FnOnce(&mut State) + Send>;

pub struct Win {
    jobs: Mutex<Sender<Job>>,
}

pub fn body() -> Option<&'static Win> {
    static B: OnceLock<Option<Win>> = OnceLock::new();
    B.get_or_init(|| {
        let (tx, rx) = channel::<Job>();
        let (ready_tx, ready_rx) = channel::<bool>();
        std::thread::Builder::new()
            .name("cookie-hands-uia".into())
            .spawn(move || {
                let made = UIAutomation::new().and_then(|auto| auto.get_control_view_walker().map(|walker| (auto, walker)));
                let Ok((auto, walker)) = made else {
                    let _ = ready_tx.send(false);
                    return;
                };
                let _ = ready_tx.send(true);
                let mut state = State { auto, walker, refs: HashMap::new() };
                while let Ok(job) = rx.recv() {
                    job(&mut state);
                }
            })
            .ok()?;
        ready_rx.recv().ok().filter(|ok| *ok)?;
        Some(Win { jobs: Mutex::new(tx) })
    })
    .as_ref()
}

impl Win {
    /// Run on the automation thread and wait for the answer.
    fn on<T: Send + 'static>(&self, f: impl FnOnce(&mut State) -> T + Send + 'static) -> Result<T, String> {
        let (tx, rx) = channel();
        self.jobs.lock().unwrap().send(Box::new(move |s| {
            let _ = tx.send(f(s));
        })).map_err(|_| "Windows automation stopped.".to_string())?;
        rx.recv_timeout(Duration::from_secs(30)).map_err(|_| "The app didn't answer in time.".to_string())
    }
}

fn e(err: impl std::fmt::Display) -> String {
    err.to_string()
}

/// Top-level windows, with their process.
fn windows(s: &State) -> Vec<(UIElement, i32, String)> {
    let mut out = Vec::new();
    let Ok(root) = s.auto.get_root_element() else { return out };
    let mut next = s.walker.get_first_child(&root).ok();
    while let Some(w) = next {
        let name = w.get_name().unwrap_or_default();
        let pid = w.get_process_id().unwrap_or(0) as i32;
        if !name.is_empty() && !w.is_offscreen().unwrap_or(true) {
            out.push((w.clone(), pid, name));
        }
        next = s.walker.get_next_sibling(&w).ok();
    }
    out
}

fn front_pid(s: &State) -> i32 {
    s.auto.get_focused_element().and_then(|f| f.get_process_id()).map(|p| p as i32).unwrap_or(0)
}

/// An app is named by its window's title; the last part after " - " is usually the app ("Report.docx - Word").
fn app_name(title: &str) -> String {
    title.rsplit(" - ").next().unwrap_or(title).trim().to_string()
}

fn plain(ct: ControlType) -> String {
    match ct {
        ControlType::Edit => "textfield".into(),
        ControlType::Hyperlink => "link".into(),
        ControlType::Text => "text".into(),
        ControlType::RadioButton => "radio".into(),
        ControlType::CheckBox => "checkbox".into(),
        ControlType::ComboBox => "combobox".into(),
        ControlType::MenuItem => "menuitem".into(),
        ControlType::TabItem => "tab".into(),
        ControlType::Spinner => "stepper".into(),
        ControlType::SplitButton => "button".into(),
        ControlType::Document => "page".into(),
        ControlType::ListItem | ControlType::TreeItem | ControlType::DataItem => "item".into(),
        other => format!("{other:?}").to_lowercase(),
    }
}

fn usable(ct: ControlType) -> bool {
    matches!(
        ct,
        ControlType::Button
            | ControlType::SplitButton
            | ControlType::CheckBox
            | ControlType::RadioButton
            | ControlType::Edit
            | ControlType::ComboBox
            | ControlType::Hyperlink
            | ControlType::MenuItem
            | ControlType::TabItem
            | ControlType::Slider
            | ControlType::Spinner
            | ControlType::ListItem
            | ControlType::TreeItem
    )
}

fn value_of(el: &UIElement, ct: ControlType) -> String {
    if el.is_password().unwrap_or(false) {
        return "•••".into();
    }
    if let Ok(t) = el.get_pattern::<UITogglePattern>() {
        if let Ok(state) = t.get_toggle_state() {
            return if format!("{state:?}").to_lowercase().contains("on") { "on".into() } else { "off".into() };
        }
    }
    if ct == ControlType::Slider || ct == ControlType::Spinner {
        if let Ok(r) = el.get_pattern::<UIRangeValuePattern>() {
            if let Ok(n) = r.get_value() {
                return if n.fract() == 0.0 { format!("{}", n as i64) } else { format!("{n:.2}") };
            }
        }
    }
    if let Ok(v) = el.get_pattern::<UIValuePattern>() {
        return v.get_value().unwrap_or_default();
    }
    String::new()
}

fn look_in(s: &mut State, q: &Look) -> Result<Snapshot, String> {
    let started = Instant::now();
    let wins = windows(s);
    let front = front_pid(s);
    let want = q.app.as_deref().map(|a| a.trim().to_lowercase()).filter(|a| !a.is_empty());
    let pick = match (q.pid, want) {
        (Some(pid), _) => wins.iter().find(|w| w.1 == pid),
        (None, Some(w)) => wins.iter().find(|x| app_name(&x.2).to_lowercase() == w).or_else(|| wins.iter().find(|x| x.2.to_lowercase().contains(&w))),
        (None, None) => wins.iter().find(|w| w.1 == front).or(wins.first()),
    };
    let (win, pid, title) = pick.cloned().ok_or("That app has no window open.")?;
    let limit = if q.limit == 0 { 250 } else { q.limit.clamp(10, 1500) };
    let deadline = started + Duration::from_millis(4000);
    let (mut nodes, mut held, mut truncated) = (Vec::new(), Vec::new(), false);
    let mut stack: Vec<(UIElement, u16)> = Vec::new();
    let mut kid = s.walker.get_first_child(&win).ok();
    let mut firsts = Vec::new();
    while let Some(k) = kid {
        kid = s.walker.get_next_sibling(&k).ok();
        firsts.push(k);
    }
    for k in firsts.into_iter().rev() {
        stack.push((k, 0));
    }
    let mut visited = 0;
    while let Some((el, depth)) = stack.pop() {
        visited += 1;
        if nodes.len() >= limit || visited > 6000 || Instant::now() > deadline {
            truncated = true;
            break;
        }
        if el.is_offscreen().unwrap_or(false) {
            continue;
        }
        let ct = el.get_control_type().unwrap_or(ControlType::Custom);
        let name = el.get_name().unwrap_or_default();
        let value = value_of(&el, ct);
        let use_it = usable(ct);
        let shown = use_it || !name.is_empty() || !value.is_empty();
        let skip = matches!(ct, ControlType::Pane | ControlType::Group | ControlType::Custom | ControlType::ScrollBar | ControlType::Thumb) && name.is_empty();
        let mut child_depth = depth;
        if shown && !skip {
            let frame = el.get_bounding_rectangle().ok().map(|r| [r.get_left(), r.get_top(), r.get_width(), r.get_height()]);
            nodes.push(Node {
                id: nodes.len() as u32 + 1,
                role: plain(ct),
                name: name.replace('\n', " "),
                value: if value == name { String::new() } else { value.replace('\n', " ⏎ ") },
                depth,
                enabled: el.is_enabled().unwrap_or(true),
                focused: el.has_keyboard_focus().unwrap_or(false),
                frame,
            });
            held.push(el.clone());
            child_depth = depth + 1;
        }
        if use_it && !name.is_empty() && !matches!(ct, ControlType::ComboBox | ControlType::MenuItem | ControlType::TreeItem) {
            continue;
        }
        let mut kids = Vec::new();
        let mut kid = s.walker.get_first_child(&el).ok();
        while let Some(k) = kid {
            kid = s.walker.get_next_sibling(&k).ok();
            kids.push(k);
        }
        for k in kids.into_iter().rev() {
            stack.push((k, child_depth));
        }
    }
    s.refs.insert(pid, held);
    Ok(Snapshot { app: app_name(&title), pid, window: title, nodes, truncated, took_ms: started.elapsed().as_millis() as u64, url: None })
}

fn act_in(s: &mut State, pid: i32, id: u32, act: &Act) -> Result<String, String> {
    let el = s.refs.get(&pid).ok_or("Look at the app first; refs come from a look.")?.get(id.saturating_sub(1) as usize).cloned().ok_or_else(|| format!("There's no e{id} in the latest look; look again."))?;
    let gone = |_| "That can't be used that way, or it's gone; look again.".to_string();
    match act {
        Act::Press => {
            if let Ok(p) = el.get_pattern::<UIInvokePattern>() {
                return p.invoke().map(|_| "pressed".into()).map_err(e);
            }
            if let Ok(p) = el.get_pattern::<UITogglePattern>() {
                return p.toggle().map(|_| "toggled".into()).map_err(e);
            }
            if let Ok(p) = el.get_pattern::<UISelectionItemPattern>() {
                return p.select().map(|_| "selected".into()).map_err(e);
            }
            if let Ok(p) = el.get_pattern::<UIExpandCollapsePattern>() {
                return p.expand().map(|_| "opened".into()).map_err(e);
            }
            Err("That can't be pressed.".into())
        }
        Act::Set(v) => {
            if let (Ok(n), Ok(p)) = (v.trim().parse::<f64>(), el.get_pattern::<UIRangeValuePattern>()) {
                return p.set_value(n).map(|_| "set".into()).map_err(e);
            }
            let p = el.get_pattern::<UIValuePattern>().map_err(|_| "That field can't be set directly; focus it and type.".to_string())?;
            p.set_value(v).map_err(e)?;
            Ok("set".into())
        }
        Act::Focus => el.set_focus().map(|_| "focused".into()).map_err(e),
        Act::Show => el.get_pattern::<UIScrollItemPattern>().map_err(gone)?.scroll_into_view().map(|_| "shown".into()).map_err(e),
        Act::Menu => el.get_pattern::<UIExpandCollapsePattern>().map_err(gone)?.expand().map(|_| "menu open".into()).map_err(e),
        Act::Increment | Act::Decrement => {
            let p = el.get_pattern::<UIRangeValuePattern>().map_err(gone)?;
            let now = p.get_value().map_err(e)?;
            p.set_value(if *act == Act::Increment { now + 1.0 } else { now - 1.0 }).map(|_| "changed".into()).map_err(e)
        }
        Act::Confirm => el.get_pattern::<UIInvokePattern>().map_err(gone)?.invoke().map(|_| "confirmed".into()).map_err(e),
        Act::Cancel => Err("Press its Cancel button, or the escape key.".into()),
        Act::Raise => el.set_focus().map(|_| "raised".into()).map_err(e),
    }
}

/// `{ctrl}{shift}t`, `{enter}`: the syntax `Keyboard::send_keys` reads.
fn keys_text(c: &Combo) -> String {
    let mut s = String::new();
    for (on, m) in [(c.ctrl, "{ctrl}"), (c.alt, "{alt}"), (c.shift, "{shift}"), (c.cmd, "{win}")] {
        if on {
            s.push_str(m);
        }
    }
    let k = match c.key.as_str() {
        "return" | "enter" => "{enter}".to_string(),
        "forwarddelete" => "{delete}".to_string(),
        "delete" | "backspace" => "{backspace}".to_string(),
        "{" | "}" | "(" | ")" => format!("{{{}}}", c.key),
        k if k.chars().count() > 1 => format!("{{{k}}}"),
        k => k.to_string(),
    };
    s.push_str(&k);
    s
}

/// Keys go to the window in front: bring the app's window forward first.
fn bring_forward(s: &State, pid: Option<i32>) {
    if let Some(pid) = pid {
        if front_pid(s) != pid {
            if let Some((w, _, _)) = windows(s).into_iter().find(|w| w.1 == pid) {
                let _ = w.set_focus();
                std::thread::sleep(Duration::from_millis(120));
            }
        }
    }
}

impl Body for Win {
    fn system(&self) -> &'static str {
        "windows"
    }

    fn ready(&self) -> Result<(), String> {
        Ok(())
    }

    fn apps(&self) -> Result<Vec<AppInfo>, String> {
        self.on(|s| {
            let front = front_pid(s);
            let mut seen = std::collections::HashSet::new();
            windows(s)
                .into_iter()
                .filter(|w| seen.insert(w.1))
                .map(|(_, pid, title)| AppInfo { name: app_name(&title), pid, bundle: title, front: pid == front })
                .collect()
        })
    }

    fn look(&self, q: &Look) -> Result<Snapshot, String> {
        let q = q.clone();
        self.on(move |s| look_in(s, &q))?
    }

    fn act(&self, pid: i32, id: u32, act: &Act) -> Result<String, String> {
        let act = act.clone();
        self.on(move |s| act_in(s, pid, id, &act))?
    }

    fn keys(&self, pid: Option<i32>, c: &Combo) -> Result<(), String> {
        let text = keys_text(c);
        self.on(move |s| {
            bring_forward(s, pid);
            uiautomation::inputs::Keyboard::new().send_keys(&text).map_err(e)
        })?
    }

    fn type_text(&self, pid: Option<i32>, text: &str) -> Result<(), String> {
        let text = text.to_string();
        self.on(move |s| {
            bring_forward(s, pid);
            uiautomation::inputs::Keyboard::new().send_text(&text).map_err(e)
        })?
    }

    fn wait_change(&self, _pid: i32, timeout: Duration) -> bool {
        // UI Automation has change events; the first version polls in short steps.
        std::thread::sleep(timeout.min(Duration::from_millis(200)));
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_are_written_the_way_windows_reads_them() {
        assert_eq!(keys_text(&Combo::parse("ctrl+shift+t").unwrap()), "{ctrl}{shift}t");
        assert_eq!(keys_text(&Combo::parse("return").unwrap()), "{enter}");
        assert_eq!(keys_text(&Combo::parse("cmd+left").unwrap()), "{win}{left}");
        assert_eq!(app_name("Report.docx - Word"), "Word");
    }
}
