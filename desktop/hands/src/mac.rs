//! macOS hands: the Accessibility API, called in-process.
//!
//! - **One call per thing.** Each element's role, name, value, state, place and
//!   children come back in one `AXUIElementCopyMultipleAttributeValues` call,
//!   not a dozen; no `osascript` process is started for anything.
//! - **Chrome and Electron wake up.** They build their accessibility tree only
//!   when an assistive app asks: Cookie sets `AXManualAccessibility` (Electron's
//!   documented switch) and, for Chromium browsers, `AXEnhancedUserInterface`.
//! - **Behind your windows.** Pressing and setting values work on windows that
//!   aren't in front; keys go to the app's process (`CGEventPostToPid`) unless it
//!   is in front, so your cursor and typing stay yours.
//! - **Waits wake on the app's own events** (`AXObserver`: values, focus,
//!   windows, layout), never on a guess.

use std::collections::{HashMap, HashSet};
use std::ffi::c_void;
use std::ptr::null;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use core_foundation::array::{CFArray, CFArrayRef};
use core_foundation::base::{CFType, CFTypeID, CFTypeRef, TCFType};
use core_foundation::boolean::CFBoolean;
use core_foundation::number::CFNumber;
use core_foundation::string::{CFString, CFStringRef};
use core_foundation_sys::runloop::{kCFRunLoopDefaultMode, CFRunLoopAddSource, CFRunLoopGetCurrent, CFRunLoopRemoveSource, CFRunLoopRunInMode, CFRunLoopSourceRef, CFRunLoopStop};
use core_graphics::event::{CGEvent, CGEventFlags, CGEventTapLocation};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};

use crate::{Act, AppInfo, Body, Combo, Look, Node, Shot, Snapshot};

type AXUIElementRef = CFTypeRef;
type AXObserverRef = CFTypeRef;

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestScreenCaptureAccess() -> bool;
}

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXUIElementCreateApplication(pid: i32) -> AXUIElementRef;
    fn AXUIElementCopyAttributeValue(e: AXUIElementRef, attr: CFStringRef, value: *mut CFTypeRef) -> i32;
    fn AXUIElementCopyMultipleAttributeValues(e: AXUIElementRef, attrs: CFArrayRef, options: u32, values: *mut CFArrayRef) -> i32;
    fn AXUIElementSetAttributeValue(e: AXUIElementRef, attr: CFStringRef, value: CFTypeRef) -> i32;
    fn AXUIElementPerformAction(e: AXUIElementRef, action: CFStringRef) -> i32;
    fn AXUIElementSetMessagingTimeout(e: AXUIElementRef, seconds: f32) -> i32;
    fn AXValueGetTypeID() -> CFTypeID;
    fn AXValueGetType(v: CFTypeRef) -> u32;
    fn AXValueGetValue(v: CFTypeRef, kind: u32, out: *mut c_void) -> bool;
    fn AXObserverCreate(pid: i32, cb: extern "C" fn(AXObserverRef, AXUIElementRef, CFStringRef, *mut c_void), out: *mut AXObserverRef) -> i32;
    fn AXObserverAddNotification(o: AXObserverRef, e: AXUIElementRef, note: CFStringRef, refcon: *mut c_void) -> i32;
    fn AXObserverGetRunLoopSource(o: AXObserverRef) -> CFRunLoopSourceRef;
}

const AX_VALUE_CGPOINT: u32 = 1;
const AX_VALUE_CGSIZE: u32 = 2;

const ERR_INVALID_ELEMENT: i32 = -25202;
const ERR_CANNOT_COMPLETE: i32 = -25204;
const ERR_ATTR_UNSUPPORTED: i32 = -25205;
const ERR_ACTION_UNSUPPORTED: i32 = -25206;
const ERR_API_DISABLED: i32 = -25211;

/// Read in one call per element, in this order.
const ATTRS: [&str; 11] = ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXChildren", "AXEnabled", "AXFocused", "AXPosition", "AXSize", "AXPlaceholderValue"];

/// Things an agent can use, by AX role.
const USABLE: &[&str] = &[
    "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton", "AXMenuButton", "AXLink", "AXSlider", "AXIncrementor",
    "AXDisclosureTriangle", "AXMenuItem", "AXMenuBarItem", "AXColorWell", "AXDateField", "AXSegmentedControl", "AXStepper",
];

/// Chromium browsers: their tree needs `AXEnhancedUserInterface`.
const CHROMIUM: &[&str] = &["com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"];

/// What an app tells us when its screen changes.
const CHANGES: &[&str] = &[
    "AXValueChanged", "AXUIElementDestroyed", "AXCreated", "AXFocusedUIElementChanged", "AXFocusedWindowChanged", "AXWindowCreated", "AXTitleChanged",
    "AXLayoutChanged", "AXSelectedChildrenChanged", "AXMenuOpened", "AXSheetCreated", "AXRowCountChanged", "AXSelectedTextChanged",
];

/// An element kept between a look and the acts on it.
struct Held(CFType);
// SAFETY: AXUIElement is a CF object whose API is safe from any thread; only the reference moves.
unsafe impl Send for Held {}

pub struct Mac {
    /// The latest look's elements per app: ref e{n} is index n-1.
    refs: Mutex<HashMap<i32, Vec<Held>>>,
    woken: Mutex<HashSet<i32>>,
    /// The latest picture per app: the window's top-left on screen, and points per picture pixel.
    shots: Mutex<HashMap<i32, (f64, f64, f64)>>,
}

pub fn body() -> &'static Mac {
    static B: OnceLock<Mac> = OnceLock::new();
    B.get_or_init(|| Mac { refs: Mutex::new(HashMap::new()), woken: Mutex::new(HashSet::new()), shots: Mutex::new(HashMap::new()) })
}

fn app_element(pid: i32) -> CFType {
    // SAFETY: Create rule: we own the returned reference.
    let e = unsafe { CFType::wrap_under_create_rule(AXUIElementCreateApplication(pid)) };
    unsafe { AXUIElementSetMessagingTimeout(e.as_CFTypeRef(), 1.5) };
    e
}

fn attr(e: &CFType, name: &str) -> Option<CFType> {
    let mut v: CFTypeRef = null();
    let err = unsafe { AXUIElementCopyAttributeValue(e.as_CFTypeRef(), CFString::new(name).as_concrete_TypeRef(), &mut v) };
    (err == 0 && !v.is_null()).then(|| unsafe { CFType::wrap_under_create_rule(v) })
}

fn set_attr(e: &CFType, name: &str, value: &CFType) -> i32 {
    unsafe { AXUIElementSetAttributeValue(e.as_CFTypeRef(), CFString::new(name).as_concrete_TypeRef(), value.as_CFTypeRef()) }
}

fn perform(e: &CFType, action: &str) -> i32 {
    unsafe { AXUIElementPerformAction(e.as_CFTypeRef(), CFString::new(action).as_concrete_TypeRef()) }
}

fn text_of(v: &CFType) -> Option<String> {
    if let Some(s) = v.downcast::<CFString>() {
        return Some(s.to_string());
    }
    if let Some(b) = v.downcast::<CFBoolean>() {
        return Some(if bool::from(b) { "on".into() } else { "off".into() });
    }
    if let Some(n) = v.downcast::<CFNumber>() {
        let f = n.to_f64()?;
        return Some(if f.fract() == 0.0 { format!("{}", f as i64) } else { format!("{f:.2}") });
    }
    None
}

fn bool_of(v: &CFType) -> Option<bool> {
    v.downcast::<CFBoolean>().map(bool::from)
}

fn point_of(v: &CFType, kind: u32) -> Option<(f64, f64)> {
    if v.type_of() != unsafe { AXValueGetTypeID() } || unsafe { AXValueGetType(v.as_CFTypeRef()) } != kind {
        return None;
    }
    let mut out = [0f64; 2];
    unsafe { AXValueGetValue(v.as_CFTypeRef(), kind, out.as_mut_ptr() as *mut c_void) }.then_some((out[0], out[1]))
}

fn children_of(v: &CFType) -> Vec<CFType> {
    match v.downcast::<CFArray>() {
        Some(a) => a.get_all_values().into_iter().filter(|p| !p.is_null()).map(|p| unsafe { CFType::wrap_under_get_rule(p) }).collect(),
        None => Vec::new(),
    }
}

/// The plain role an agent reads.
fn plain(role: &str, subrole: &str) -> String {
    match subrole {
        "AXSearchField" => return "searchfield".into(),
        "AXSecureTextField" => return "password".into(),
        "AXSwitch" | "AXToggle" => return "switch".into(),
        "AXTabButton" => return "tab".into(),
        "AXCloseButton" => return "close".into(),
        "AXMinimizeButton" => return "minimize".into(),
        "AXFullScreenButton" | "AXZoomButton" => return "zoom".into(),
        _ => {}
    }
    match role {
        "AXStaticText" => "text".into(),
        "AXTextField" => "textfield".into(),
        "AXTextArea" => "textarea".into(),
        "AXCheckBox" => "checkbox".into(),
        "AXRadioButton" => "radio".into(),
        "AXPopUpButton" => "popup".into(),
        "AXMenuButton" => "menubutton".into(),
        "AXComboBox" => "combobox".into(),
        "AXMenuItem" => "menuitem".into(),
        "AXMenuBarItem" => "menu".into(),
        "AXDisclosureTriangle" => "disclosure".into(),
        "AXWebArea" => "page".into(),
        r => r.trim_start_matches("AX").to_lowercase(),
    }
}

struct Walk {
    nodes: Vec<Node>,
    held: Vec<Held>,
    truncated: bool,
}

fn walk(root: CFType, limit: usize, deadline: Instant) -> Walk {
    let names: Vec<CFString> = ATTRS.iter().map(|a| CFString::new(a)).collect();
    let names = CFArray::from_CFTypes(&names);
    let mut out = Walk { nodes: Vec::new(), held: Vec::new(), truncated: false };
    // (element, depth among the shown things)
    let mut stack: Vec<(CFType, u16)> = vec![(root, 0)];
    let mut visited = 0usize;
    while let Some((el, depth)) = stack.pop() {
        visited += 1;
        if out.nodes.len() >= limit || visited > 8000 || Instant::now() > deadline {
            out.truncated = true;
            break;
        }
        let mut raw: CFArrayRef = null();
        let err = unsafe { AXUIElementCopyMultipleAttributeValues(el.as_CFTypeRef(), names.as_concrete_TypeRef(), 0, &mut raw) };
        if err != 0 || raw.is_null() {
            continue;
        }
        let vals: CFArray<CFType> = unsafe { CFArray::wrap_under_create_rule(raw) };
        let get = |i: usize| vals.get(i as isize).map(|v| v.clone());
        let s = |i: usize| get(i).and_then(|v| text_of(&v)).unwrap_or_default();
        let role = s(0);
        let subrole = s(1);
        let size = get(9).and_then(|v| point_of(&v, AX_VALUE_CGSIZE));
        // Collapsed or hidden: neither it nor what's inside it is on screen.
        if matches!(size, Some((w, h)) if w < 1.0 || h < 1.0) && role != "AXApplication" {
            continue;
        }
        let mut name = s(2);
        if name.is_empty() {
            name = s(3);
        }
        if name.is_empty() {
            name = s(10);
        }
        let mut value = if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            if s(4).is_empty() { String::new() } else { "•••".into() }
        } else {
            s(4)
        };
        if role == "AXStaticText" && name.is_empty() {
            name = std::mem::take(&mut value);
        }
        let usable = USABLE.contains(&role.as_str());
        let shown = usable || role == "AXHeading" || !name.is_empty() || (!value.is_empty() && role != "AXGroup");
        let skip_kinds = matches!(role.as_str(), "AXWindow" | "AXApplication" | "AXScrollBar" | "AXValueIndicator" | "AXGrowArea" | "AXSplitter");
        let mut child_depth = depth;
        if shown && !skip_kinds {
            let frame = get(8).and_then(|v| point_of(&v, AX_VALUE_CGPOINT)).zip(size).map(|((x, y), (w, h))| [x as i32, y as i32, w as i32, h as i32]);
            out.nodes.push(Node {
                id: out.nodes.len() as u32 + 1,
                role: plain(&role, &subrole),
                name: name.replace('\n', " "),
                value: value.replace('\n', " ⏎ "),
                depth,
                enabled: get(6).and_then(|v| bool_of(&v)).unwrap_or(true),
                focused: get(7).and_then(|v| bool_of(&v)).unwrap_or(false),
                frame,
            });
            out.held.push(Held(el.clone()));
            child_depth = depth + 1;
        }
        // A button's label inside it is the button's name, not a second thing.
        if usable && role != "AXRadioButton" && !name.is_empty() {
            continue;
        }
        if role == "AXScrollBar" {
            continue;
        }
        let kids = get(5).map(|v| children_of(&v)).unwrap_or_default();
        for k in kids.into_iter().rev() {
            stack.push((k, child_depth));
        }
    }
    out
}

fn ax_error(code: i32, what: &str) -> String {
    match code {
        ERR_INVALID_ELEMENT => "That is gone from the screen; look again.".into(),
        ERR_CANNOT_COMPLETE => "The app didn't answer in time.".into(),
        ERR_ATTR_UNSUPPORTED | ERR_ACTION_UNSUPPORTED => format!("That can't be {what}."),
        ERR_API_DISABLED => NOT_ALLOWED.into(),
        c => format!("The app refused ({c})."),
    }
}

const NOT_ALLOWED: &str = "macOS hasn't let Cookie use apps yet: switch Cookie on in System Settings → Privacy & Security → Accessibility (once), then try again.";

/// US layout key codes; other characters are typed as text.
fn key_code(k: &str) -> Option<u16> {
    Some(match k {
        "return" | "enter" => 36,
        "tab" => 48,
        "space" | " " => 49,
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
        "f1" => 122,
        "f2" => 120,
        "f3" => 99,
        "f4" => 118,
        "f5" => 96,
        "f6" => 97,
        "f7" => 98,
        "f8" => 100,
        "f9" => 101,
        "f10" => 109,
        "f11" => 103,
        "f12" => 111,
        "a" => 0, "s" => 1, "d" => 2, "f" => 3, "h" => 4, "g" => 5, "z" => 6, "x" => 7, "c" => 8, "v" => 9, "b" => 11, "q" => 12, "w" => 13, "e" => 14,
        "r" => 15, "y" => 16, "t" => 17, "1" => 18, "2" => 19, "3" => 20, "4" => 21, "6" => 22, "5" => 23, "=" => 24, "9" => 25, "7" => 26, "-" => 27,
        "8" => 28, "0" => 29, "]" => 30, "o" => 31, "u" => 32, "[" => 33, "i" => 34, "p" => 35, "l" => 37, "j" => 38, "'" => 39, "k" => 40, ";" => 41,
        "\\" => 42, "," => 43, "/" => 44, "n" => 45, "m" => 46, "." => 47, "`" => 50,
        _ => return None,
    })
}


/// The app's front window on screen: its number and its bounds in points.
fn front_window(pid: i32) -> Option<(u32, [f64; 4])> {
    use core_foundation::dictionary::CFDictionary;
    use core_graphics::window::{copy_window_info, kCGNullWindowID, kCGWindowBounds, kCGWindowLayer, kCGWindowListExcludeDesktopElements, kCGWindowListOptionOnScreenOnly, kCGWindowNumber, kCGWindowOwnerPID};
    let list = copy_window_info(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID)?;
    let key = |k: CFStringRef| unsafe { CFString::wrap_under_get_rule(k) };
    let num = |d: &CFDictionary<CFString, CFType>, k: CFStringRef| d.find(key(k)).and_then(|v| v.downcast::<CFNumber>()).and_then(|n| n.to_f64());
    // Front to back: the first normal window of this app is its front one.
    for item in list.get_all_values() {
        let d: CFDictionary<CFString, CFType> = unsafe { CFDictionary::wrap_under_get_rule(item as _) };
        if num(&d, unsafe { kCGWindowOwnerPID }) != Some(pid as f64) || num(&d, unsafe { kCGWindowLayer }) != Some(0.0) {
            continue;
        }
        let id = num(&d, unsafe { kCGWindowNumber })? as u32;
        let b: CFDictionary<CFString, CFType> = d.find(key(unsafe { kCGWindowBounds })).and_then(|v| v.downcast::<CFDictionary>()).map(|x| unsafe { CFDictionary::wrap_under_get_rule(x.as_concrete_TypeRef()) })?;
        let f = |k: &str| b.find(CFString::new(k)).and_then(|v| v.downcast::<CFNumber>()).and_then(|n| n.to_f64()).unwrap_or(0.0);
        return Some((id, [f("X"), f("Y"), f("Width"), f("Height")]));
    }
    None
}

/// A PNG's width and height, from its header.
fn png_size(png: &[u8]) -> Option<(u32, u32)> {
    (png.len() > 24 && png.starts_with(b"\x89PNG")).then(|| (u32::from_be_bytes(png[16..20].try_into().unwrap()), u32::from_be_bytes(png[20..24].try_into().unwrap())))
}

extern "C" fn on_change(_o: AXObserverRef, _e: AXUIElementRef, _n: CFStringRef, refcon: *mut c_void) {
    // SAFETY: refcon is the AtomicBool `wait_change` keeps alive until its run loop has stopped.
    unsafe {
        (*(refcon as *const AtomicBool)).store(true, Ordering::SeqCst);
        CFRunLoopStop(CFRunLoopGetCurrent());
    }
}

impl Mac {
    fn front(&self) -> Option<AppInfo> {
        self.apps().ok()?.into_iter().find(|a| a.front)
    }

    fn resolve(&self, q: &Look) -> Result<AppInfo, String> {
        let apps = self.apps()?;
        if let Some(pid) = q.pid {
            return apps.into_iter().find(|a| a.pid == pid).ok_or_else(|| "That app isn't open any more.".to_string());
        }
        match q.app.as_deref().map(str::trim).filter(|a| !a.is_empty()) {
            None => self.front().ok_or_else(|| "No app is in front.".to_string()),
            Some(want) => {
                let w = want.to_lowercase();
                apps.iter()
                    .find(|a| a.name.to_lowercase() == w || a.bundle.to_lowercase() == w)
                    .or_else(|| apps.iter().find(|a| a.name.to_lowercase().contains(&w)))
                    .cloned()
                    .ok_or_else(|| format!("{want} isn't open. Open it first (open_app), then look."))
            }
        }
    }

    /// Chrome and Electron apps build their tree only when asked. Once per app.
    fn wake(&self, app: &AppInfo, el: &CFType) -> bool {
        if !self.woken.lock().unwrap().insert(app.pid) {
            return false;
        }
        let on = CFBoolean::true_value().as_CFType();
        let electron = electron_app(app.pid);
        let chromium = CHROMIUM.contains(&app.bundle.as_str());
        if electron || chromium {
            set_attr(el, "AXManualAccessibility", &on);
        }
        if chromium {
            set_attr(el, "AXEnhancedUserInterface", &on);
        }
        electron || chromium
    }

    fn held(&self, pid: i32, id: u32) -> Result<CFType, String> {
        let refs = self.refs.lock().unwrap();
        let list = refs.get(&pid).ok_or("Look at the app first; refs come from a look.")?;
        list.get(id.saturating_sub(1) as usize).map(|h| h.0.clone()).ok_or_else(|| format!("There's no e{id} in the latest look; look again."))
    }
}

/// An Electron app carries Electron's framework in its bundle.
fn electron_app(pid: i32) -> bool {
    let path = objc2_app_kit::NSRunningApplication::runningApplicationWithProcessIdentifier(pid).and_then(|a| a.bundleURL()).and_then(|u| u.path()).map(|p| p.to_string());
    path.is_some_and(|p| std::path::Path::new(&p).join("Contents/Frameworks/Electron Framework.framework").exists())
}

impl Body for Mac {
    fn system(&self) -> &'static str {
        "macos"
    }

    fn ready(&self) -> Result<(), String> {
        if unsafe { AXIsProcessTrusted() } {
            Ok(())
        } else {
            Err(NOT_ALLOWED.into())
        }
    }

    fn apps(&self) -> Result<Vec<AppInfo>, String> {
        use objc2_app_kit::{NSApplicationActivationPolicy, NSWorkspace};
        let ws = NSWorkspace::sharedWorkspace();
        let list = ws.runningApplications();
        let mut out = Vec::new();
        for a in list.iter() {
            if a.activationPolicy() != NSApplicationActivationPolicy::Regular {
                continue;
            }
            let name = a.localizedName().map(|s| s.to_string()).unwrap_or_default();
            if name.is_empty() {
                continue;
            }
            out.push(AppInfo {
                name,
                pid: a.processIdentifier(),
                bundle: a.bundleIdentifier().map(|s| s.to_string()).unwrap_or_default(),
                front: a.isActive(),
            });
        }
        Ok(out)
    }

    fn look(&self, q: &Look) -> Result<Snapshot, String> {
        self.ready()?;
        let started = Instant::now();
        let app = self.resolve(q)?;
        let el = app_element(app.pid);
        if self.wake(&app, &el) {
            std::thread::sleep(Duration::from_millis(400));
        }
        let window = attr(&el, "AXFocusedWindow").or_else(|| attr(&el, "AXMainWindow")).or_else(|| attr(&el, "AXWindows").and_then(|w| children_of(&w).into_iter().next()));
        let limit = if q.limit == 0 { 250 } else { q.limit.clamp(10, 1500) };
        let (title, w) = match window {
            Some(win) => (attr(&win, "AXTitle").and_then(|t| text_of(&t)).unwrap_or_default(), walk(win, limit, started + Duration::from_millis(2500))),
            None => ("(no window)".to_string(), Walk { nodes: Vec::new(), held: Vec::new(), truncated: false }),
        };
        self.refs.lock().unwrap().insert(app.pid, w.held);
        Ok(Snapshot { app: app.name, pid: app.pid, window: title, nodes: w.nodes, truncated: w.truncated, took_ms: started.elapsed().as_millis() as u64 })
    }

    fn act(&self, pid: i32, id: u32, act: &Act) -> Result<String, String> {
        self.ready()?;
        let el = self.held(pid, id)?;
        let done = |code: i32, what: &str, ok: &str| if code == 0 { Ok(ok.to_string()) } else { Err(ax_error(code, what)) };
        match act {
            Act::Press => {
                let mut code = perform(&el, "AXPress");
                for alt in ["AXConfirm", "AXPick", "AXOpen"] {
                    if code == ERR_ACTION_UNSUPPORTED {
                        code = perform(&el, alt);
                    }
                }
                done(code, "pressed", "pressed")
            }
            Act::Set(v) => {
                let role = attr(&el, "AXRole").and_then(|r| text_of(&r)).unwrap_or_default();
                let value: CFType = match (role.as_str(), v.trim().parse::<f64>()) {
                    ("AXSlider" | "AXIncrementor", Ok(n)) => CFNumber::from(n).as_CFType(),
                    _ => CFString::new(v).as_CFType(),
                };
                let code = set_attr(&el, "AXValue", &value);
                if code != 0 {
                    return Err(ax_error(code, "set"));
                }
                let now = attr(&el, "AXValue").and_then(|x| text_of(&x)).unwrap_or_default();
                if role == "AXSecureTextField" || now == *v || now.trim_end_matches('0').trim_end_matches('.') == v.trim() {
                    Ok("set".into())
                } else {
                    Err("The app didn't take the text; focus it and type instead.".into())
                }
            }
            Act::Focus => done(set_attr(&el, "AXFocused", &CFBoolean::true_value().as_CFType()), "focused", "focused"),
            Act::Menu => done(perform(&el, "AXShowMenu"), "given a menu", "menu open"),
            Act::Increment => done(perform(&el, "AXIncrement"), "increased", "increased"),
            Act::Decrement => done(perform(&el, "AXDecrement"), "decreased", "decreased"),
            Act::Confirm => done(perform(&el, "AXConfirm"), "confirmed", "confirmed"),
            Act::Cancel => done(perform(&el, "AXCancel"), "cancelled", "cancelled"),
            Act::Raise => done(perform(&el, "AXRaise"), "raised", "raised"),
            Act::Show => done(perform(&el, "AXScrollToVisible"), "scrolled to", "shown"),
        }
    }

    fn keys(&self, pid: Option<i32>, c: &Combo) -> Result<(), String> {
        self.ready()?;
        let src = CGEventSource::new(CGEventSourceStateID::HIDSystemState).map_err(|_| "Couldn't make key events.".to_string())?;
        let mut flags = CGEventFlags::CGEventFlagNull;
        if c.cmd {
            flags |= CGEventFlags::CGEventFlagCommand;
        }
        if c.shift {
            flags |= CGEventFlags::CGEventFlagShift;
        }
        if c.alt {
            flags |= CGEventFlags::CGEventFlagAlternate;
        }
        if c.ctrl {
            flags |= CGEventFlags::CGEventFlagControl;
        }
        let code = key_code(&c.key);
        // The app in front takes keys from the system; one behind takes them at its process.
        let target = pid.filter(|p| self.front().map(|f| f.pid) != Some(*p));
        for down in [true, false] {
            let ev = CGEvent::new_keyboard_event(src.clone(), code.unwrap_or(0), down).map_err(|_| "Couldn't make a key event.".to_string())?;
            if code.is_none() {
                ev.set_string(&c.key);
            }
            ev.set_flags(flags);
            match target {
                Some(p) => ev.post_to_pid(p),
                None => ev.post(CGEventTapLocation::HID),
            }
        }
        Ok(())
    }

    fn type_text(&self, pid: Option<i32>, text: &str) -> Result<(), String> {
        self.ready()?;
        let src = CGEventSource::new(CGEventSourceStateID::HIDSystemState).map_err(|_| "Couldn't make key events.".to_string())?;
        let target = pid.filter(|p| self.front().map(|f| f.pid) != Some(*p));
        let post = |ev: &CGEvent| match target {
            Some(p) => ev.post_to_pid(p),
            None => ev.post(CGEventTapLocation::HID),
        };
        for (i, line) in text.split('\n').enumerate() {
            if i > 0 {
                for down in [true, false] {
                    let ev = CGEvent::new_keyboard_event(src.clone(), 36, down).map_err(|_| "Couldn't make a key event.".to_string())?;
                    post(&ev);
                }
            }
            let units: Vec<u16> = line.encode_utf16().collect();
            for chunk in units.chunks(20) {
                let s = String::from_utf16_lossy(chunk);
                for down in [true, false] {
                    let ev = CGEvent::new_keyboard_event(src.clone(), 0, down).map_err(|_| "Couldn't make a key event.".to_string())?;
                    ev.set_string(&s);
                    post(&ev);
                }
                std::thread::sleep(Duration::from_millis(3));
            }
        }
        Ok(())
    }

    fn wait_change(&self, pid: i32, timeout: Duration) -> bool {
        let changed = Box::new(AtomicBool::new(false));
        let refcon = &*changed as *const AtomicBool as *mut c_void;
        let mut raw: AXObserverRef = null();
        if unsafe { AXObserverCreate(pid, on_change, &mut raw) } != 0 || raw.is_null() {
            std::thread::sleep(timeout.min(Duration::from_millis(150)));
            return false;
        }
        let observer = unsafe { CFType::wrap_under_create_rule(raw) };
        let app = app_element(pid);
        for n in CHANGES {
            unsafe { AXObserverAddNotification(observer.as_CFTypeRef(), app.as_CFTypeRef(), CFString::new(n).as_concrete_TypeRef(), refcon) };
        }
        let source = unsafe { AXObserverGetRunLoopSource(observer.as_CFTypeRef()) };
        let rl = unsafe { CFRunLoopGetCurrent() };
        unsafe { CFRunLoopAddSource(rl, source, kCFRunLoopDefaultMode) };
        let deadline = Instant::now() + timeout;
        while !changed.load(Ordering::SeqCst) {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            unsafe { CFRunLoopRunInMode(kCFRunLoopDefaultMode, left.as_secs_f64(), 1) };
        }
        let hit = changed.load(Ordering::SeqCst);
        if hit {
            // A change comes in a burst: let it land before the next look.
            let settle = Instant::now() + Duration::from_millis(120);
            while Instant::now() < settle {
                changed.store(false, Ordering::SeqCst);
                unsafe { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.06, 1) };
                if !changed.load(Ordering::SeqCst) {
                    break;
                }
            }
        }
        unsafe { CFRunLoopRemoveSource(rl, source, kCFRunLoopDefaultMode) };
        drop(observer);
        hit
    }
    fn screenshot(&self, pid: i32) -> Result<Shot, String> {
        if !unsafe { CGPreflightScreenCaptureAccess() } {
            unsafe { CGRequestScreenCaptureAccess() };
            return Err("macOS hasn't let Cookie take pictures of windows yet: switch Cookie on in System Settings → Privacy & Security → Screen & System Audio Recording (once), then try again.".into());
        }
        let (id, [x, y, w, _h]) = front_window(pid).ok_or("That app has no window on screen.")?;
        let path = std::env::temp_dir().join(format!("cookie-shot-{pid}-{}.png", std::process::id()));
        let ok = std::process::Command::new("/usr/sbin/screencapture").args(["-x", "-o", "-t", "png", &format!("-l{id}")]).arg(&path).status().is_ok_and(|s| s.success());
        if !ok {
            return Err("The picture couldn't be taken.".into());
        }
        // At most 1280 pixels across: enough to read, few tokens.
        let _ = std::process::Command::new("/usr/bin/sips").args(["-Z", "1280"]).arg(&path).output();
        let png = std::fs::read(&path).map_err(|e| e.to_string());
        let _ = std::fs::remove_file(&path);
        let png = png?;
        let (pw, ph) = png_size(&png).ok_or("The picture came out unreadable.")?;
        self.shots.lock().unwrap().insert(pid, (x, y, w / pw.max(1) as f64));
        Ok(Shot { png, width: pw, height: ph })
    }

    fn click_at(&self, pid: i32, x: f64, y: f64) -> Result<(), String> {
        use core_graphics::event::{CGEventType, CGMouseButton};
        use core_graphics::geometry::CGPoint;
        self.ready()?;
        let (ox, oy, scale) = *self.shots.lock().unwrap().get(&pid).ok_or("Take a picture of the window first; points come from a picture.")?;
        let at = CGPoint::new(ox + x * scale, oy + y * scale);
        let src = CGEventSource::new(CGEventSourceStateID::HIDSystemState).map_err(|_| "Couldn't make a click.".to_string())?;
        for kind in [CGEventType::MouseMoved, CGEventType::LeftMouseDown, CGEventType::LeftMouseUp] {
            let ev = CGEvent::new_mouse_event(src.clone(), kind, at, CGMouseButton::Left).map_err(|_| "Couldn't make a click.".to_string())?;
            ev.post(CGEventTapLocation::HID);
            std::thread::sleep(Duration::from_millis(30));
        }
        Ok(())
    }
}
