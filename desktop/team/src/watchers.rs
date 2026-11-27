//! Watchers an agent writes for itself: the cheapest way to wait for the world.
//!
//! "Tell me when this page's price drops under 500", "when the build goes
//! green", "when a new file lands in the shared folder": asking a model every
//! few minutes whether anything changed costs a full call each time, and is
//! almost always "no". A watcher is a small program the agent writes once. It
//! runs on its schedule in the agent's own cage, with no model at all: it gets
//! the state it left last time, prints whether it saw what it is watching for,
//! and keeps its state for next time. Only a hit wakes the agent — or, when the
//! watcher belongs to a goal, wakes that goal — and that wake is silent work,
//! never an interruption of the person. After the Rule of Two, a watcher that
//! reaches the web has no access to the person's private data: it is given
//! only its own state.
//!
//! A watcher's program prints one JSON object as its last line:
//! `{"hit": true|false, "what": "what it saw", "state": <anything to keep>}`.

use std::sync::Arc;
use std::time::Duration;

use cookie_harness::tool::{tool, Effect, Tool};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::store::Trigger;
use crate::{util, Team};

const TICK: Duration = Duration::from_secs(60);
/// The most often a watcher may run.
const SOONEST_MINUTES: u64 = 2;
/// Wakes one watcher may cause in a day: a guard against one that always says "hit".
const HITS_A_DAY: u32 = 24;
/// Watchers one agent may keep.
const MOST: usize = 50;
/// Failed runs in a row before a watcher stops itself (and says so).
const FAILS_IN_A_ROW: u32 = 5;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Watcher {
    pub id: String,
    pub agent: String,
    /// The goal it wakes, when it belongs to one.
    pub goal: Option<String>,
    pub what: String,
    pub code: String,
    pub every_minutes: u64,
    pub online: bool,
    pub active: bool,
    #[serde(default)]
    pub state: Value,
    #[serde(default)]
    pub last_run: u64,
    #[serde(default)]
    pub runs: u64,
    #[serde(default)]
    pub hits: u64,
    #[serde(default)]
    pub fails_in_a_row: u32,
    /// Hits today, and the day (days since the epoch) they were counted on.
    #[serde(default)]
    pub today: (u64, u32),
    #[serde(default)]
    pub last_said: String,
    pub created_at: u64,
}

impl Team {
    fn watchers_path(&self) -> std::path::PathBuf {
        self.paths.root.join("watchers.json")
    }

    pub fn watchers(&self) -> Vec<Watcher> {
        util::read_json(&self.watchers_path())
    }

    fn edit_watchers<T>(&self, f: impl FnOnce(&mut Vec<Watcher>) -> T) -> Result<T, String> {
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _g = LOCK.lock().unwrap();
        let mut all = self.watchers();
        let out = f(&mut all);
        util::write_json(&self.watchers_path(), &all)?;
        Ok(out)
    }

    pub fn stop_watcher(&self, id: &str) -> Result<(), String> {
        self.edit_watchers(|all| {
            let w = all.iter_mut().find(|w| w.id == id).ok_or("No such watcher.")?;
            w.active = false;
            Ok::<_, String>(())
        })?
    }

    /// Runs every watcher that is due, once.
    pub(crate) async fn tick_watchers(self: &Arc<Self>) {
        let now = util::now();
        let due: Vec<Watcher> = self.watchers().into_iter().filter(|w| w.active && now >= w.last_run + w.every_minutes * 60).collect();
        for w in due {
            let r = crate::forge::run_program(self, &w.agent, &w.code, &json!({"state": w.state}), w.online).await;
            let reading = r.as_ref().map_err(|e| e.clone()).and_then(|out| reading_of(out));
            let today = now / 86_400;
            let mut wake: Option<String> = None;
            let _ = self.edit_watchers(|all| {
                let Some(x) = all.iter_mut().find(|x| x.id == w.id) else { return };
                x.last_run = now;
                x.runs += 1;
                match &reading {
                    Ok((hit, what, state)) => {
                        x.fails_in_a_row = 0;
                        if !state.is_null() {
                            x.state = state.clone();
                        }
                        x.last_said = util::clip(what, 300);
                        let hits_today = if x.today.0 == today { x.today.1 } else { 0 };
                        if *hit && hits_today < HITS_A_DAY {
                            x.hits += 1;
                            x.today = (today, hits_today + 1);
                            wake = Some(what.clone());
                        }
                    }
                    Err(e) => {
                        x.fails_in_a_row += 1;
                        x.last_said = util::clip(&format!("failed: {e}"), 300);
                        if x.fails_in_a_row >= FAILS_IN_A_ROW {
                            x.active = false;
                        }
                    }
                }
            });
            if reading.is_err() && w.fails_in_a_row + 1 >= FAILS_IN_A_ROW {
                let _ = self.give_work(&w.agent, format!("Your watcher “{}” failed {FAILS_IN_A_ROW} times in a row and stopped itself. Its last error: {}. Fix it (set_watcher again) or let it go.", w.what, util::clip(&reading.clone().err().unwrap_or_default(), 600)), Trigger::Watch { watcher: w.id.clone() }).await;
            }
            // A hit goes through attention, the one gate for everything that can wake an agent: the
            // person's labels on earlier hits ("not useful") are what decide whether this one counts.
            if let Some(what) = wake {
                self.watcher_cue(&w, &what);
            }
        }
    }
}

impl Team {
    /// A watcher's hit, as a cue on its own subject. While the person's labels still want this
    /// watcher's hits, the cue is hard and goes through at once; once they have said "not useful"
    /// enough, it only builds up, and a stray hit fades.
    pub(crate) fn watcher_cue(&self, w: &Watcher, what: &str) {
        let now = util::now() as f64;
        let branch = format!("watch:{}", w.id);
        let about = vec![w.what.clone()];
        let wanted = {
            let subs: std::collections::BTreeMap<String, cookie_harness::attention::Subject> = util::read_json(&self.paths.agent(&w.agent).join("attention.json"));
            let (key, _) = cookie_harness::attention::subject_of(&branch, &about);
            subs.get(&key).map_or(1.0, |s| s.wanted("watch", now))
        };
        let signal = cookie_harness::attention::Signal {
            id: format!("{}#{}", w.id, w.runs),
            kind: "watch".into(),
            why: util::clip(what, 300),
            salience: 10.0,
            at: now,
            hard: wanted >= 0.5,
            what: w.what.clone(),
            changed_at: now,
            ..Default::default()
        };
        self.add_cue(&w.agent, &branch, &about, signal, now);
    }
}

/// The last JSON line a watcher printed: whether it hit, what it saw, its state.
fn reading_of(out: &str) -> Result<(bool, String, Value), String> {
    let v = out
        .lines()
        .rev()
        .find_map(|l| serde_json::from_str::<Value>(l.trim()).ok().filter(Value::is_object))
        .ok_or_else(|| format!("its last line wasn't a JSON object like {{\"hit\": false, \"what\": \"…\", \"state\": …}}: {}", util::clip(out, 300)))?;
    Ok((v["hit"].as_bool().unwrap_or(false), v["what"].as_str().unwrap_or("").to_string(), v.get("state").cloned().unwrap_or(Value::Null)))
}

pub(crate) fn spawn(team: Arc<Team>) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(TICK);
        loop {
            tick.tick().await;
            team.tick_watchers().await;
        }
    });
}

/// `set_watcher` and `stop_watcher`, for an agent with its own cage.
pub(crate) fn tools(team: &Arc<Team>, agent: &str, trigger: &Trigger) -> Vec<Arc<dyn Tool>> {
    if team.cage(agent).is_none() {
        return Vec::new();
    }
    let goal = match trigger {
        Trigger::Goal { goal } => Some(goal.clone()),
        _ => None,
    };
    let (w, a) = (Arc::downgrade(team), agent.to_string());
    let set = tool(
        "set_watcher",
        "Watch for something without spending anything while you wait: a small Python 3 program that runs every few minutes in your \
         sandbox, with no model. It reads {\"state\": what it kept last time} as JSON on stdin and prints, as its last line, \
         {\"hit\": true|false, \"what\": \"what it saw\", \"state\": what to keep}. A hit wakes you (in a goal's sitting: wakes that \
         goal). Set online=true to let it read the web; it never gets the person's private data. Use it instead of checking back yourself.",
        json!({"type": "object", "properties": {
            "what": {"type": "string", "description": "what it watches for, in a few words"},
            "code": {"type": "string"},
            "every_minutes": {"type": "integer", "minimum": SOONEST_MINUTES},
            "online": {"type": "boolean"}
        }, "required": ["what", "code", "every_minutes"]}),
        Effect::Write,
        move |args: Value| {
            let (w, a, goal) = (w.clone(), a.clone(), goal.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                let code = args["code"].as_str().unwrap_or_default().to_string();
                let what = args["what"].as_str().unwrap_or_default().trim().to_string();
                if code.trim().is_empty() || what.is_empty() {
                    return Err("Say what it watches for, and give its code.".into());
                }
                let online = args["online"].as_bool().unwrap_or(false);
                // It runs once now: a watcher that can't run is never set.
                let first = crate::forge::run_program(&team, &a, &code, &json!({"state": null}), online).await.map_err(|e| format!("Its first run failed, so it wasn't set:\n{e}"))?;
                let (hit, said, state) = reading_of(&first).map_err(|e| format!("Its first run didn't report properly, so it wasn't set: {e}"))?;
                let every = args["every_minutes"].as_u64().unwrap_or(15).max(SOONEST_MINUTES);
                let id = team.edit_watchers(|all| {
                    if all.iter().filter(|x| x.agent == a && x.active).count() >= MOST {
                        return Err(format!("You have {MOST} watchers; stop one first."));
                    }
                    let id = util::new_id("watch");
                    all.push(Watcher { id: id.clone(), agent: a.clone(), goal, what: util::clip(&what, 200), code, every_minutes: every, online, active: true, state, last_run: util::now(), runs: 1, created_at: util::now(), last_said: util::clip(&said, 300), ..Watcher::default() });
                    Ok(id)
                })??;
                Ok(format!("Watching ({id}), every {every} minutes. First look: {}{}", if hit { "it already sees it: " } else { "not yet. " }, util::clip(&said, 300)))
            }
        },
    )
    .with_preview(|args| format!("Watch for: {} (every {} minutes{})\n\n{}", args["what"].as_str().unwrap_or(""), args["every_minutes"].as_u64().unwrap_or(15), if args["online"].as_bool().unwrap_or(false) { ", reading the web" } else { "" }, util::clip(args["code"].as_str().unwrap_or(""), 3000)));
    let (w, a) = (Arc::downgrade(team), agent.to_string());
    let stop = tool(
        "stop_watcher",
        "Stop one of your watchers (by its id), or list them with no id.",
        json!({"type": "object", "properties": {"id": {"type": "string"}}}),
        Effect::Write,
        move |args: Value| {
            let (w, a) = (w.clone(), a.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                match args["id"].as_str().filter(|s| !s.is_empty()) {
                    Some(id) if team.watchers().iter().any(|x| x.id == id && x.agent == a) => team.stop_watcher(id).map(|_| "Stopped.".to_string()),
                    Some(_) => Err("No watcher of yours has that id.".into()),
                    None => Ok(team
                        .watchers()
                        .into_iter()
                        .filter(|x| x.agent == a && x.active)
                        .map(|x| format!("{}: {} (every {} min; {} runs, {} hits; last: {})", x.id, x.what, x.every_minutes, x.runs, x.hits, x.last_said))
                        .collect::<Vec<_>>()
                        .join("\n"))
                    .map(|s| if s.is_empty() { "No watchers.".into() } else { s }),
                }
            }
        },
    );
    vec![Arc::new(set), Arc::new(stop)]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_watcher_reports_on_its_last_line() {
        let (hit, what, state) = reading_of("exit code: 0\nstdout:\nfetching…\n{\"hit\": true, \"what\": \"price 480\", \"state\": {\"last\": 480}}\nstderr:\n").unwrap();
        assert!(hit && what == "price 480" && state["last"] == 480);
        assert!(reading_of("exit code: 0\nstdout:\nnothing\n").is_err());
    }

    #[tokio::test]
    #[cfg(target_os = "macos")]
    async fn a_watcher_keeps_its_state_and_wakes_only_on_a_hit() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        let _ = std::fs::create_dir_all(team.paths.work("a"));
        let tools = tools(&team, "a", &Trigger::Chat);
        let Some(set) = tools.iter().find(|t| t.spec().name == "set_watcher") else { return }; // no sandbox here
        // Counts up each run; hits on the third.
        let code = "import json,sys\ns=json.load(sys.stdin)['state'] or {'n':0}\ns['n']+=1\nprint(json.dumps({'hit': s['n']>=3, 'what': 'run %d' % s['n'], 'state': s}))\n";
        let said = set.call(json!({"what": "the third run", "code": code, "every_minutes": 2})).await.unwrap();
        assert!(said.contains("not yet"), "{said}");
        team.edit_watchers(|all| all[0].last_run = 0).unwrap();
        team.tick_watchers().await;
        assert_eq!(team.watchers()[0].hits, 0);
        assert_eq!(team.watchers()[0].state["n"], 2, "its state carried over");
        team.edit_watchers(|all| all[0].last_run = 0).unwrap();
        team.tick_watchers().await;
        assert_eq!(team.watchers()[0].hits, 1, "the third run hit");
        team.tick_watchers().await;
        assert_eq!(team.watchers()[0].runs, 3, "not due again yet: it waits its minutes");
    }
}
