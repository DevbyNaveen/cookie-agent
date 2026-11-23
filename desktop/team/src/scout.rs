//! Scout: proposes new hires from how you work.
//!
//! The Mac app's Apprentice (opt-in, listen-only) keeps the structure of what
//! you do (which control you pressed, which shortcut, in which app; never the
//! text, never the screen) in `apprentice.json`. Scout looks for the same run
//! of steps on different days and offers a hire with a job already written.
//! Nothing here watches anything itself.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// Seconds between the Unix epoch and Apple's reference date (2001-01-01).
const APPLE_EPOCH: f64 = 978_307_200.0;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Step {
    date: f64,
    #[serde(rename = "appBundleID")]
    app: String,
    action: serde_json::Value,
}

#[derive(Debug, Default, Deserialize)]
struct Archive {
    #[serde(default)]
    steps: Vec<Step>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Proposal {
    pub id: String,
    pub app: String,
    pub steps: Vec<String>,
    pub days: usize,
    pub times: usize,
    pub name: String,
    pub job: String,
}

/// Swift's coding of the action enum: {"press":{"role","label"}}, {"key":{"_0":"cmd+s"}}, {"typed":{}}.
fn label(action: &serde_json::Value) -> Option<(String, String)> {
    if let Some(p) = action.get("press") {
        let label = p["label"].as_str().unwrap_or("").trim().to_string();
        let role = p["role"].as_str().unwrap_or("control").trim_start_matches("AX").to_lowercase();
        let shown = if label.is_empty() { role.clone() } else { label.clone() };
        return Some((format!("press|{role}|{}", label.to_lowercase()), shown));
    }
    if let Some(k) = action.get("key") {
        let combo = k["_0"].as_str().unwrap_or("").to_lowercase();
        if combo.split('+').any(|p| p == "cmd" || p == "ctrl") {
            return Some((format!("key|{combo}"), combo));
        }
    }
    None
}

pub fn default_archive() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    Some(PathBuf::from(home).join("Library/Application Support/Cookie/apprentice.json"))
}

fn app_name(bundle: &str) -> String {
    bundle.rsplit('.').next().unwrap_or(bundle).to_string()
}

/// Runs of 3–6 meaningful steps in one app, seen on at least two days.
pub fn propose(json: &str) -> Vec<Proposal> {
    let archive: Archive = serde_json::from_str(json).unwrap_or_default();
    let steps: Vec<(String, String, String, String)> = archive
        .steps
        .iter()
        .filter_map(|s| {
            let (key, shown) = label(&s.action)?;
            let day = chrono::DateTime::from_timestamp((s.date + APPLE_EPOCH) as i64, 0)?.format("%Y-%m-%d").to_string();
            Some((s.app.to_lowercase(), key, shown, day))
        })
        .collect();
    // key sequence → (days, times, shown labels, app)
    let mut seen: BTreeMap<Vec<String>, (BTreeSet<String>, usize, Vec<String>, String)> = BTreeMap::new();
    for len in 3..=6 {
        for w in steps.windows(len) {
            if w.iter().any(|s| s.0 != w[0].0 || s.3 != w[0].3) {
                continue; // one app, one day per occurrence
            }
            let key: Vec<String> = w.iter().map(|s| format!("{}|{}", s.0, s.1)).collect();
            let e = seen.entry(key).or_insert_with(|| (BTreeSet::new(), 0, w.iter().map(|s| s.2.clone()).collect(), w[0].0.clone()));
            e.0.insert(w[0].3.clone());
            e.1 += 1;
        }
    }
    let mut out: Vec<Proposal> = seen
        .into_iter()
        .filter(|(_, (days, times, _, _))| days.len() >= 2 && *times >= 3)
        .map(|(key, (days, times, shown, app))| {
            let app = app_name(&app);
            let title = shown.join(" → ");
            Proposal {
                id: crate::peers::sha256_hex(&key.join("\u{1f}"))[..16].to_string(),
                name: format!("{} Helper", capitalise(&app)),
                job: format!(
                    "In {app}, I keep doing: {title}. Learn what this is for, prepare everything it needs ahead of time, \
                     and remind me when it's due. Ask me before anything leaves this computer."
                ),
                app,
                steps: shown,
                days: days.len(),
                times,
            }
        })
        .collect();
    // The longest pattern wins over the shorter runs inside it.
    out.sort_by(|a, b| b.steps.len().cmp(&a.steps.len()).then(b.times.cmp(&a.times)));
    let mut kept: Vec<Proposal> = Vec::new();
    for p in out {
        let inside = kept.iter().any(|k| k.app == p.app && k.steps.windows(p.steps.len()).any(|w| w == p.steps.as_slice()));
        if !inside {
            kept.push(p);
        }
        if kept.len() == 5 {
            break;
        }
    }
    kept
}

fn capitalise(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
}

/// What Scout has to offer right now, minus what the person waved away.
pub fn proposals(dismissed: &[String]) -> Result<Vec<Proposal>, String> {
    let path = default_archive().ok_or("No home folder.")?;
    let json = match std::fs::read_to_string(&path) {
        Ok(j) => j,
        Err(_) => return Ok(Vec::new()),
    };
    Ok(propose(&json).into_iter().filter(|p| !dismissed.contains(&p.id)).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn step(day: i64, label: &str) -> serde_json::Value {
        serde_json::json!({"id": "x", "date": (day * 86_400) as f64 + 3600.0 - APPLE_EPOCH, "appBundleID": "com.apple.mail",
            "action": {"press": {"role": "AXButton", "label": label}}})
    }

    #[test]
    fn finds_a_run_repeated_on_two_days() {
        let mut steps = Vec::new();
        for day in [20_000, 20_001, 20_002] {
            for l in ["New Message", "Attach", "Send"] {
                steps.push(step(day, l));
            }
        }
        let props = propose(&serde_json::json!({"steps": steps}).to_string());
        assert_eq!(props.len(), 1);
        assert_eq!(props[0].steps, vec!["New Message", "Attach", "Send"]);
        assert_eq!(props[0].days, 3);
        assert!(props[0].job.contains("Ask me before"));
    }

    #[test]
    fn typing_alone_and_single_days_are_not_patterns() {
        let one_day: Vec<_> = (0..9).map(|i| step(20_000, ["A", "B", "C"][i % 3])).collect();
        assert!(propose(&serde_json::json!({"steps": one_day}).to_string()).is_empty());
        assert!(propose("not json").is_empty());
    }
}
