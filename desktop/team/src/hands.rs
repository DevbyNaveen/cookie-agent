//! Cookie Hands for agents: read and use the person's own apps, through the
//! system's accessibility layer (`cookie-hands`), for agents with "Use this Mac" on.
//!
//! - **look** reads an app's window as an outline with refs, in milliseconds,
//!   Chrome and Electron apps included. No screenshot is ever taken or sent.
//! - **act** does one step or a batch (press, set, focus, menu, type, keys…),
//!   checking the screen between steps, and answers with what changed. One
//!   approval covers a whole batch; it works behind the person's windows.
//! - **wait_for** wakes on the app's own events when text appears or goes.
//! - **Recipes**: a batch that worked is saved by role and name, and replays
//!   later with no model in the loop; it stops, and hands back a look, at the
//!   first thing that isn't where it was.
//!
//! Agents work in their own worlds (Parallax) first; these are for when the
//! person asks for their own app, or the job needs something only it has.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use cookie_hands::{Look, Step};
use cookie_harness::tool::{tool, Effect, Tool};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{util, Team};

/// A batch that worked, saved to replay.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Recipe {
    app: String,
    about: String,
    steps: Vec<Step>,
    by: String,
    saved: u64,
    #[serde(default)]
    runs: u32,
}

/// What each agent last did in an app this session, ready to save as a recipe.
fn last_steps() -> &'static Mutex<HashMap<String, (String, Vec<Step>)>> {
    static L: OnceLock<Mutex<HashMap<String, (String, Vec<Step>)>>> = OnceLock::new();
    L.get_or_init(Default::default)
}

fn s(a: &Value, k: &str) -> Option<String> {
    a[k].as_str().map(str::trim).filter(|v| !v.is_empty()).map(str::to_string)
}

fn look_of(a: &Value) -> Look {
    Look { app: s(a, "app"), pid: None, limit: a["limit"].as_u64().unwrap_or(250) as usize }
}

/// Run the engine off the async threads: its calls block on the app.
async fn blocking<T: Send + 'static>(f: impl FnOnce(&'static dyn cookie_hands::Body) -> Result<T, String> + Send + 'static) -> Result<T, String> {
    let body = cookie_hands::body().ok_or("Using apps isn't available on this system yet.")?;
    if let Err(e) = body.ready() {
        #[cfg(target_os = "macos")]
        {
            let _ = crate::control::open(&[crate::control::ACCESSIBILITY_PANE]).await;
            return Err(format!("{e} I opened that page in System Settings for the person."));
        }
        #[allow(unreachable_code)]
        return Err(e);
    }
    tokio::task::spawn_blocking(move || f(body)).await.map_err(|e| e.to_string())?
}

fn steps_of(a: &Value) -> Result<Vec<Step>, String> {
    let steps: Vec<Step> = match a.get("steps") {
        Some(v) if v.is_array() => serde_json::from_value(v.clone()).map_err(|e| format!("steps: {e}"))?,
        _ => vec![serde_json::from_value(a.clone()).map_err(|e| format!("step: {e}"))?],
    };
    if steps.is_empty() || steps.iter().any(|s| s.r#do.trim().is_empty()) {
        return Err("Each step needs `do` (press, set, focus, menu, type, keys…).".into());
    }
    Ok(steps)
}

fn preview(steps: &[Step], app: Option<&str>) -> String {
    let what: Vec<String> = steps.iter().map(Step::describe).collect();
    let app = app.map(|a| format!(" in {a}")).unwrap_or_default();
    if what.len() == 1 {
        format!("{}{app}", what[0])
    } else {
        format!("{} steps{app}: {}", what.len(), what.join(" → "))
    }
}

/// What an agent reads after acting: what changed, or the whole window if a lot did.
fn report(done: &cookie_hands::Done) -> String {
    let mut out = String::new();
    if !done.did.is_empty() {
        out.push_str(&format!("Did ({} ms): {}\n", done.took_ms, done.did.join(" → ")));
    }
    if let Some(f) = &done.failed {
        out.push_str(&format!("Stopped at {f}\n"));
    }
    let big = done.changes.len() > 30 || done.changes.iter().any(|c| c.starts_with("~ app") || c.starts_with("~ window"));
    if big {
        out.push_str("A lot changed; the window now:\n");
        out.push_str(&cookie_hands::render(&done.after));
    } else if done.changes.is_empty() {
        out.push_str("Nothing on screen changed (some apps change a moment later: wait_for, or look again).\n");
    } else {
        out.push_str("Changed (refs are current):\n");
        out.push_str(&done.changes.join("\n"));
        out.push('\n');
    }
    out
}

fn recipes_path(root: &PathBuf) -> PathBuf {
    root.join("hands-recipes.json")
}

pub(crate) fn tools(team: &Arc<Team>, agent: &str) -> Vec<Arc<dyn Tool>> {
    let root = team.paths.root.clone();
    let me = agent.to_string();
    let mut out: Vec<Arc<dyn Tool>> = Vec::new();

    out.push(Arc::new(tool(
        "list_apps",
        "The apps open on the person's computer, and which one is in front.",
        json!({"type": "object", "properties": {}}),
        Effect::Read,
        |_a: Value| async move {
            let apps = blocking(|b| b.apps()).await?;
            Ok(apps.iter().map(|a| format!("{}{}", a.name, if a.front { " (in front)" } else { "" })).collect::<Vec<_>>().join("\n"))
        },
    )));

    out.push(Arc::new(tool(
        "look",
        "Read an app's window on the person's computer: its buttons, fields, text, links, switches and menus, one per line with a ref \
         (e12 button \"Send\"), indented by where they sit. Milliseconds, any app, Chrome and Electron apps included; no screenshot. \
         `app` by name, or the app in front. Refs change with each look.",
        json!({"type": "object", "properties": {
            "app": {"type": "string", "description": "the app's name, e.g. Safari, Notes, System Settings; empty for the app in front"},
            "limit": {"type": "integer", "description": "most things to list (default 250)"}
        }}),
        Effect::Read,
        |a: Value| async move {
            let q = look_of(&a);
            blocking(move |b| b.look(&q)).await.map(|s| cookie_hands::render(&s))
        },
    )));

    let mine = me.clone();
    out.push(Arc::new(
        tool(
            "act",
            "Use an app on the person's computer: one step, or several in `steps` done in order with the screen checked between them \
             (one approval for all). A step names a thing by `ref` (from your latest look) or by `role` and `name`, and what to `do`: \
             press, set (a field's text or a slider's number, in `value`), focus, menu, increment, decrement, confirm, cancel, raise, show; \
             `type` (`value` into a field, or wherever the cursor is) or `keys` (`value` like cmd+t, return, escape); `click_at` \
             (`value` x,y from your latest `see` picture) only when nothing else reaches it. It works behind the person's windows where \
             the app allows. Answers with what changed, with current refs. Look first.",
            json!({"type": "object", "properties": {
                "app": {"type": "string", "description": "the app's name; empty for the app in front"},
                "ref": {"type": "string"}, "role": {"type": "string"}, "name": {"type": "string"},
                "do": {"type": "string"}, "value": {"type": "string"},
                "steps": {"type": "array", "items": {"type": "object", "properties": {
                    "ref": {"type": "string"}, "role": {"type": "string"}, "name": {"type": "string"}, "do": {"type": "string"}, "value": {"type": "string"}
                }, "required": ["do"]}}
            }}),
            Effect::Write,
            move |a: Value| {
                let mine = mine.clone();
                async move {
                    let steps = steps_of(&a)?;
                    let q = look_of(&a);
                    let done = blocking(move |b| cookie_hands::run(b, &q, &steps, &HashMap::new())).await?;
                    if !done.resolved.is_empty() {
                        let mut last = last_steps().lock().unwrap();
                        let entry = last.entry(mine).or_insert_with(|| (done.after.app.clone(), Vec::new()));
                        if entry.0 != done.after.app {
                            *entry = (done.after.app.clone(), Vec::new());
                        }
                        entry.1.extend(done.resolved.clone());
                    }
                    Ok(report(&done))
                }
            },
        )
        .with_preview(|a| preview(&steps_of(a).unwrap_or_default(), a["app"].as_str().filter(|s| !s.is_empty()))),
    ));

    out.push(Arc::new(tool(
        "see",
        "A picture of an app's front window, for what `look` can't read: a canvas, a chart, an image, a game, an app that hides \
         its contents. Only that window, never the whole screen. Comes with the window's outline. If you must click something only \
         the picture shows, use act with do: click_at and value \"x,y\" in this picture's pixels (it moves the pointer: last resort).",
        json!({"type": "object", "properties": {"app": {"type": "string", "description": "the app's name; empty for the app in front"}}}),
        Effect::Read,
        |a: Value| async move {
            let q = look_of(&a);
            let (shot, snap) = blocking(move |b| {
                let snap = b.look(&q)?;
                let shot = b.screenshot(snap.pid)?;
                Ok((shot, snap))
            })
            .await?;
            let attached = cookie_harness::attach_image("image/png", shot.png);
            let head = if attached { format!("Picture of {}'s window attached ({}x{} pixels).", snap.app, shot.width, shot.height) } else { "The picture couldn't be attached here.".to_string() };
            Ok(format!("{head}\n{}", cookie_hands::render(&snap)))
        },
    )));

    out.push(Arc::new(tool(
        "wait_for",
        "Wait until some text appears in an app's window (or, with `gone`, until it goes): a page loading, a dialog, a result. \
         Wakes the moment the app changes; at most `seconds` (default 10, at most 60).",
        json!({"type": "object", "properties": {
            "app": {"type": "string"}, "text": {"type": "string"}, "gone": {"type": "boolean"}, "seconds": {"type": "number"}
        }, "required": ["text"]}),
        Effect::Read,
        |a: Value| async move {
            let text = s(&a, "text").ok_or("Say what text to wait for.")?;
            let gone = a["gone"].as_bool().unwrap_or(false);
            let secs = a["seconds"].as_f64().unwrap_or(10.0).clamp(0.5, 60.0);
            let q = look_of(&a);
            let t = text.clone();
            let (seen, snap) = blocking(move |b| cookie_hands::wait_for(b, &q, &t, gone, Duration::from_secs_f64(secs))).await?;
            let head = match (seen, gone) {
                (true, false) => format!("{text:?} is there."),
                (true, true) => format!("{text:?} is gone."),
                (false, false) => format!("{text:?} didn't appear within {secs} s."),
                (false, true) => format!("{text:?} was still there after {secs} s."),
            };
            Ok(format!("{head}\n{}", cookie_hands::render(&snap)))
        },
    )));

    let (r, mine) = (root.clone(), me.clone());
    out.push(Arc::new(
        tool(
            "save_recipe",
            "Save what you just did in an app (your acts there this job) as a recipe, to replay next time without working it out again. \
             Name it for the job (e.g. \"turn on dark mode\"). Words that change each time go in as {{name}} in a step's value, \
             filled when it runs. `steps` replaces what was recorded, if you want to tidy it.",
            json!({"type": "object", "properties": {
                "name": {"type": "string"}, "about": {"type": "string"},
                "steps": {"type": "array", "items": {"type": "object"}}
            }, "required": ["name"]}),
            Effect::Write,
            move |a: Value| {
                let (r, mine) = (r.clone(), mine.clone());
                async move {
                    let name = s(&a, "name").ok_or("Give the recipe a name.")?.to_lowercase();
                    let (app, steps) = match a.get("steps").filter(|v| v.as_array().is_some_and(|x| !x.is_empty())) {
                        Some(v) => {
                            let app = last_steps().lock().unwrap().get(&mine).map(|l| l.0.clone()).unwrap_or_default();
                            (app, serde_json::from_value::<Vec<Step>>(v.clone()).map_err(|e| format!("steps: {e}"))?)
                        }
                        None => last_steps().lock().unwrap().get(&mine).cloned().ok_or("Nothing done in an app yet this job; act first.")?,
                    };
                    if steps.iter().any(|s| s.name.is_none() && !matches!(s.r#do.as_str(), "keys" | "type")) {
                        return Err("Every step in a recipe names its thing by role and name, not a ref.".into());
                    }
                    let path = recipes_path(&r);
                    let mut all: HashMap<String, Recipe> = util::read_json(&path);
                    let n = steps.len();
                    all.insert(name.clone(), Recipe { app: app.clone(), about: s(&a, "about").unwrap_or_default(), steps, by: mine, saved: util::now(), runs: 0 });
                    util::write_json(&path, &all)?;
                    Ok(format!("Saved \"{name}\": {n} steps in {app}. run_recipe replays it."))
                }
            },
        )
        .with_preview(|a| format!("Save recipe “{}”", a["name"].as_str().unwrap_or_default())),
    ));

    let r = root.clone();
    out.push(Arc::new(tool(
        "recipes",
        "Your team's saved recipes for using apps: each one's name, app, what it's for and its steps.",
        json!({"type": "object", "properties": {}}),
        Effect::Read,
        move |_a: Value| {
            let r = r.clone();
            async move {
                let all: HashMap<String, Recipe> = util::read_json(&recipes_path(&r));
                if all.is_empty() {
                    return Ok("No recipes yet.".into());
                }
                let mut names: Vec<_> = all.iter().collect();
                names.sort_by(|a, b| a.0.cmp(b.0));
                Ok(names.iter().map(|(n, rc)| format!("\"{n}\" in {} ({} steps, run {} times){}: {}", rc.app, rc.steps.len(), rc.runs, if rc.about.is_empty() { String::new() } else { format!(" — {}", rc.about) }, preview(&rc.steps, None))).collect::<Vec<_>>().join("\n"))
            }
        },
    )));

    let (r, shown) = (root.clone(), root);
    out.push(Arc::new(
        tool(
            "run_recipe",
            "Replay a saved recipe in its app, with `values` for its {{name}} blanks. It finds each thing by role and name; at the first \
             thing that isn't there it stops and shows you the window, to carry on yourself.",
            json!({"type": "object", "properties": {"name": {"type": "string"}, "values": {"type": "object"}}, "required": ["name"]}),
            Effect::Write,
            move |a: Value| {
                let r = r.clone();
                async move {
                    let name = s(&a, "name").ok_or("Which recipe?")?.to_lowercase();
                    let path = recipes_path(&r);
                    let mut all: HashMap<String, Recipe> = util::read_json(&path);
                    let rc = all.get(&name).cloned().ok_or_else(|| format!("There's no recipe called {name:?}; `recipes` lists them."))?;
                    let vars: HashMap<String, String> = a["values"].as_object().map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string()))).collect()).unwrap_or_default();
                    let q = Look { app: Some(rc.app.clone()), pid: None, limit: 400 };
                    let steps = rc.steps.clone();
                    let done = blocking(move |b| cookie_hands::run(b, &q, &steps, &vars)).await?;
                    if done.failed.is_none() {
                        if let Some(x) = all.get_mut(&name) {
                            x.runs += 1;
                        }
                        let _ = util::write_json(&path, &all);
                    }
                    let mut text = report(&done);
                    if done.failed.is_some() && !text.contains("the window now") {
                        text.push_str("The window now:\n");
                        text.push_str(&cookie_hands::render(&done.after));
                    }
                    Ok(text)
                }
            },
        )
        .with_preview(move |a| {
            let name = a["name"].as_str().unwrap_or_default().to_lowercase();
            let all: HashMap<String, Recipe> = util::read_json(&recipes_path(&shown));
            match all.get(&name) {
                Some(rc) => format!("Run recipe “{name}” in {}: {}", rc.app, preview(&rc.steps, None)),
                None => format!("Run recipe “{name}”"),
            }
        }),
    ));
    out
}
