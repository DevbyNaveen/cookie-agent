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
        "hire_contractor" => {
            let r = s("role").unwrap_or_else(|| "a specialist".into());
            (format!("Working with a contractor: {r}"), format!("Worked with a contractor: {r}"), None)
        }
        "helper" => {
            let t = helper_title(args);
            (format!("Helper: {t}"), format!("Helper: {t}"), None)
        }
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
        "read_artifact" => ("Reading a helper's full report".into(), "Read a helper's full report".into(), None),
        "message_agent" => ("Messaging a teammate".into(), "Messaged a teammate".into(), None),
        "send_email" | "send_mail" | "draft" => ("Writing an email".into(), "Wrote an email".into(), None),
        "messages_send" => ("Sending a message".into(), "Sent a message".into(), None),
        "calendar_events" => ("Checking your calendar".into(), "Checked your calendar".into(), None),
        "calendar_add" => ("Adding to your calendar".into(), "Added to your calendar".into(), None),
        "reminders_list" => ("Checking your reminders".into(), "Checked your reminders".into(), None),
        "reminders_add" => ("Adding a reminder".into(), "Added a reminder".into(), None),
        "reminders_complete" => ("Ticking off a reminder".into(), "Ticked off a reminder".into(), None),
        "notes_read" | "notes_search" => ("Looking through your notes".into(), "Looked through your notes".into(), None),
        "notes_create" | "note" => ("Writing a note".into(), "Wrote a note".into(), None),
        "contacts_find" => ("Looking up a contact".into(), "Looked up a contact".into(), None),
        "mac_files_list" | "mac_files_search" | "search_files" => ("Looking through your files".into(), "Looked through your files".into(), None),
        "mac_files_read" | "read_src" => {
            let f = file("path").map(|f| format!(" {f}")).unwrap_or_else(|| " a file".into());
            (format!("Reading{f}"), format!("Read{f}"), None)
        }
        "open_app" | "open_item" | "open_settings" => ("Opening it on your Mac".into(), "Opened it on your Mac".into(), None),
        "quit_app" => ("Closing an app".into(), "Closed an app".into(), None),
        "list_apps" => ("Checking your apps".into(), "Checked your apps".into(), None),
        "look" | "see" | "browser_screenshot" => ("Looking at the screen".into(), "Looked at the screen".into(), None),
        "act" | "choose_menu" | "browser_click" | "browser_type" => ("Working on the screen".into(), "Worked on the screen".into(), None),
        "browser_open" | "browser_read" | "browser_back" => {
            let h = host("url").map(|h| format!(" {h}")).unwrap_or_default();
            (format!("Browsing{h}"), format!("Browsed{h}"), None)
        }
        "find_images" => ("Looking for images".into(), "Found images".into(), None),
        "weather" => ("Checking the weather".into(), "Checked the weather".into(), None),
        "route_planner" => ("Planning the route".into(), "Planned the route".into(), None),
        "search_history" => ("Looking back through past chats".into(), "Looked back through past chats".into(), None),
        "note_about_person" => ("Noting something about you".into(), "Noted something about you".into(), None),
        "forget_about_person" | "forget_note" => ("Forgetting something".into(), "Forgot something".into(), None),
        "set_routine" => ("Setting up a routine".into(), "Set up a routine".into(), None),
        "list_routines" => ("Checking routines".into(), "Checked routines".into(), None),
        "stop_routine" => ("Stopping a routine".into(), "Stopped a routine".into(), None),
        "board" => ("Updating the board".into(), "Updated the board".into(), None),
        "share_with_team" => ("Sharing with the team".into(), "Shared with the team".into(), None),
        "skill_view" | "skills_list" | "skill_manage" | "propose_new_skill" | "propose_skill_edit" => ("Working on its skills".into(), "Worked on its skills".into(), None),
        "run_code" | "sh" => ("Running code".into(), "Ran code".into(), None),
        "workspace_look" => ("Looking at its workspace".into(), "Looked at its workspace".into(), None),
        "workspace_change" => ("Changing its workspace".into(), "Changed its workspace".into(), None),
        "workspace_undo" => ("Undoing a change".into(), "Undid a change".into(), None),
        "sign_in" | "logins" => ("Signing in".into(), "Signed in".into(), None),
        "wait_for" => ("Waiting for it to finish".into(), "Waited for it to finish".into(), None),
        "propose_deal" => ("Writing up a deal".into(), "Wrote up a deal".into(), None),
        "recipes" | "run_recipe" | "save_recipe" | "read_order" => ("Working through a recipe".into(), "Worked through a recipe".into(), None),
        "tool_invoke" => ("Using one of your tools".into(), "Used one of your tools".into(), None),
        // A tool with no words yet (an app's own, a new one): its name, read as words, never "a step".
        other => {
            let words = other.trim_start_matches("use_tool_").replace(['_', '-', '.'], " ");
            let words = words.trim();
            if words.is_empty() { ("Working on it".into(), "Worked on it".into(), None) } else { (format!("Using {words}"), format!("Used {words}"), None) }
        }
    };
    (doing, did, with)
}

/// What kind of step this is and its one short detail, for folding steps the way a reader
/// takes them in: "Searched 2 queries · read 3 sites", with the queries and sites a click away.
pub(crate) fn brief(name: &str, args: &Value) -> (&'static str, Option<String>) {
    let s = |k: &str| args[k].as_str().map(str::trim).filter(|v| !v.is_empty()).map(str::to_string);
    let host = |k: &str| s(k).and_then(|u| u.split("//").nth(1).map(|r| r.split(['/', '?', '#']).next().unwrap_or(r).trim_start_matches("www.").to_lowercase()));
    let file = |k: &str| s(k).map(|p| p.rsplit('/').next().unwrap_or(&p).to_string());
    match name {
        "web_search" | "find_images" => ("search", s("query").map(|q| util::clip(&q, 120))),
        "read_url" | "read_page" | "browser_open" | "browser_read" => ("page", host("url")),
        "recall" | "search_history" => ("memory", s("query").map(|q| util::clip(&q, 120))),
        "read_file" | "mac_files_read" | "read_src" => ("file", file("path")),
        _ => ("other", None),
    }
}

/// The key that ties a helper's or contractor's step to its own thread (`TeamEvent::Step::thread`).
pub(crate) fn thread_key(name: &str, args: &Value) -> Option<String> {
    let task = args["task"].as_str().unwrap_or_default().trim();
    match name {
        crate::helpers::NAME => Some(util::clip(task, 400)),
        crate::contractors::NAME => Some(util::clip(&format!("{}: {task}", args["role"].as_str().unwrap_or_default().trim()), 400)),
        _ => None,
    }
}

/// What a helper is called on screen: its own short title, else the start of its task.
pub(crate) fn helper_title(args: &Value) -> String {
    if let Some(t) = args["title"].as_str().map(str::trim).filter(|t| !t.is_empty()) {
        return util::clip(t, 48);
    }
    let task = args["task"].as_str().unwrap_or_default().trim();
    // The task's first clause, at most seven words: "Research the current AI agent market".
    let first = task.split(['.', '\n', ':', ';', '?']).next().unwrap_or(task);
    let words: Vec<&str> = first.split_whitespace().take(7).collect();
    if words.is_empty() { "A helper".into() } else { words.join(" ") }
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
        assert_eq!(words(&team, "mystery_tool", &json!({})).1, "Used mystery tool", "never a bare 'did a step'");
        assert_eq!(words(&team, "read_artifact", &json!({})).1, "Read a helper's full report");
        assert_eq!(helper_title(&json!({"title": "Competitor pricing"})), "Competitor pricing");
        assert_eq!(brief("web_search", &json!({"query": "acme bot pricing"})), ("search", Some("acme bot pricing".into())));
        assert_eq!(brief("read_url", &json!({"url": "https://www.TechCrunch.com/2026/x"})), ("page", Some("techcrunch.com".into())));
        assert_eq!(brief("message", &json!({"to": "@a"})), ("other", None));
        assert_eq!(helper_title(&json!({"task": "Research the current AI agent market in 2025-2026. I need pricing."})), "Research the current AI agent market in");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
