//! What a step of a job is doing, in the person's words: "Messaging Writer",
//! "Searching the web for flights to Riga", and, once done, "Messaged Writer".
//! Shown live while the step runs and folded into one line after.

use serde_json::Value;

use crate::{util, Team};

/// (doing, did, teammate it talks to) for one call.
pub(crate) fn words(team: &Team, name: &str, args: &Value) -> (String, String, Option<String>) {
    let s = |k: &str| args[k].as_str().map(str::trim).filter(|v| !v.is_empty()).map(|v| util::clip(v, 60));
    let quoted = |k: &str| s(k).map(|v| format!(" for “{v}”")).unwrap_or_default();
    let host = |k: &str| s(k).and_then(|u| u.split("//").nth(1).map(|r| r.split('/').next().unwrap_or(r).trim_start_matches("www.").to_string()));
    let file = |k: &str| s(k).map(|p| p.rsplit('/').next().unwrap_or(&p).to_string());
    let (doing, did, with): (String, String, Option<String>) = match name {
        "message" | "ask_agent" => {
            let to = s("to").or_else(|| s("agent")).unwrap_or_default();
            let mate = teammate(team, &to);
            let who = mate.as_ref().map(|(_, n)| n.clone()).unwrap_or_else(|| to.trim_start_matches('@').to_string());
            (format!("Messaging {who}"), format!("Messaged {who}"), mate.map(|(id, _)| id))
        }
        "hire_agent" => {
            let n = s("name").unwrap_or_else(|| "a teammate".into());
            (format!("Hiring {n}"), format!("Hired {n}"), None)
        }
        "web_search" => (format!("Searching the web{}", quoted("query")), format!("Searched the web{}", quoted("query")), None),
        "read_url" | "read_page" => {
            let h = host("url").map(|h| format!(" on {h}")).unwrap_or_default();
            (format!("Reading a page{h}"), format!("Read a page{h}"), None)
        }
        "read_file" => {
            let f = file("path").map(|f| format!(" {f}")).unwrap_or_else(|| " a file".into());
            (format!("Reading{f}"), format!("Read{f}"), None)
        }
        "write_file" => {
            let f = file("path").map(|f| format!(" {f}")).unwrap_or_else(|| " a file".into());
            (format!("Writing{f}"), format!("Wrote{f}"), None)
        }
        "run_command" => ("Running a command".into(), "Ran a command".into(), None),
        "recall" => (format!("Remembering{}", quoted("query")), format!("Checked memory{}", quoted("query")), None),
        "remember" | "save_note" => ("Saving to memory".into(), "Saved to memory".into(), None),
        "team_overview" => ("Checking on the team".into(), "Checked on the team".into(), None),
        "connector_actions" => ("Looking in your apps".into(), "Looked in your apps".into(), None),
        "connector_call" | "app_call" => {
            let a = s("action").or_else(|| s("tool")).map(|a| format!(": {}", a.replace(['_', '-'], " ").to_lowercase())).unwrap_or_default();
            (format!("Working in your apps{a}"), format!("Worked in your apps{a}"), None)
        }
        "find_skill" | "load_skill" | "use_skill" => ("Picking up a skill".into(), "Picked up a skill".into(), None),
        "hire_contractor" => ("Bringing in a contractor".into(), "Brought in a contractor".into(), None),
        "helper" => ("Sending out a helper".into(), "Sent out a helper".into(), None),
        "make_image" => ("Making an image".into(), "Made an image".into(), None),
        "make_video" => ("Making a video".into(), "Made a video".into(), None),
        "screenshot" => ("Looking at the screen".into(), "Looked at the screen".into(), None),
        "todo_list" => ("Planning the steps".into(), "Planned the steps".into(), None),
        "ask_person" => ("Writing you a question".into(), "Asked you".into(), None),
        "tool_search" => ("Finding the right tool".into(), "Found a tool".into(), None),
        "app_help" => (format!("Checking the app guide{}", quoted("query")), format!("Checked the app guide{}", quoted("query")), None),
        "settings_search" => ("Looking at settings".into(), "Looked at settings".into(), None),
        "settings_set" => {
            let k = s("key").and_then(|k| crate::appsettings::key(&k).map(|k| k.title.to_lowercase())).unwrap_or_else(|| "a setting".into());
            (format!("Changing {k}"), format!("Changed {k}"), None)
        }
        "app_settings" => ("Checking how Cookie is set up".into(), "Checked how Cookie is set up".into(), None),
        _ => ("Working on it".into(), String::new(), None),
    };
    let did = if did.is_empty() { "Did a step".to_string() } else { did };
    (doing, did, with)
}

/// A teammate by address (`@writing-desk`) or name: its id and name.
fn teammate(team: &Team, to: &str) -> Option<(String, String)> {
    let agents = team.agents.try_read().ok()?.clone();
    let want = to.trim_start_matches('@').to_lowercase();
    agents
        .iter()
        .find(|a| team.slug_of(a).to_lowercase() == want || a.name.to_lowercase() == want || a.id == want)
        .map(|a| (a.id.clone(), a.name.clone()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn steps_read_as_sentences() {
        let dir = std::env::temp_dir().join(format!("steps-{}", std::process::id()));
        let team = Team::open(&dir).unwrap();
        let (doing, did, with) = words(&team, "web_search", &json!({"query": "flights to Riga"}));
        assert_eq!(doing, "Searching the web for “flights to Riga”");
        assert_eq!(did, "Searched the web for “flights to Riga”");
        assert!(with.is_none());
        assert_eq!(words(&team, "read_url", &json!({"url": "https://www.example.com/a/b"})).0, "Reading a page on example.com");
        assert_eq!(words(&team, "message", &json!({"to": "@nobody"})).0, "Messaging nobody");
        assert_eq!(words(&team, "mystery_tool", &json!({})).1, "Did a step");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
