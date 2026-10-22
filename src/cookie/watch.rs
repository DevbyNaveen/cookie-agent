//! Watching a page. A person asks Cookie to keep an eye on a page (a pricing
//! page, a changelog, a job board); the client fetches it now and then, and
//! only when the words changed is that news — the model never runs to find
//! out nothing happened (Hermes's monitor mode does the same with a hash).
//! What counts as a change, and how it is said, live here.

use serde_json::{json, Value};

pub fn tool_decl() -> Value {
    json!({
        "name": "watch_page",
        "description": "Keep an eye on a web page for the person: Cookie checks it every few hours and tells them when what it says changes. Use when they ask to watch, track or monitor a page.",
        "schema": {"type": "object", "properties": {
            "url": {"type": "string", "description": "The page, as a full web address."},
            "focus": {"type": "string", "description": "What matters on it, e.g. \"prices\". Leave out for any change."}
        }, "required": ["url"]},
        "effect": "write",
        "parallel_safe": false
    })
}

/// A page's words, one line per block, spaces collapsed: what is compared.
pub fn normalize(text: &str) -> String {
    text.lines().map(|l| l.split_whitespace().collect::<Vec<_>>().join(" ")).filter(|l| !l.is_empty()).collect::<Vec<_>>().join("\n")
}

/// What changed, said in a few lines — `None` when nothing a person would
/// notice did. Lines are compared as sets, so a line that only moved is no
/// change; a `focus` keeps only changed lines that mention it.
pub fn change(old: &str, new: &str, focus: Option<&str>) -> Option<String> {
    let (old, new) = (normalize(old), normalize(new));
    if old == new {
        return None;
    }
    let before: std::collections::HashSet<&str> = old.lines().collect();
    let after: std::collections::HashSet<&str> = new.lines().collect();
    let keep = |l: &&str| l.chars().count() > 3 && focus.is_none_or(|f| f.split_whitespace().any(|w| l.to_lowercase().contains(&w.to_lowercase())));
    let added: Vec<&str> = new.lines().filter(|l| !before.contains(l)).filter(keep).take(8).collect();
    let gone: Vec<&str> = old.lines().filter(|l| !after.contains(l)).filter(keep).take(4).collect();
    if added.is_empty() && gone.is_empty() {
        return None;
    }
    let mut out = String::new();
    if !added.is_empty() {
        out.push_str(&format!("Now says:\n{}", added.iter().map(|l| format!("+ {}", clip(l, 200))).collect::<Vec<_>>().join("\n")));
    }
    if !gone.is_empty() {
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&format!("No longer says:\n{}", gone.iter().map(|l| format!("- {}", clip(l, 200))).collect::<Vec<_>>().join("\n")));
    }
    Some(out)
}

fn clip(s: &str, n: usize) -> String {
    if s.chars().count() <= n { s.to_string() } else { format!("{}…", s.chars().take(n).collect::<String>()) }
}

/// One `watch` line: `{old, new, focus?}` → `{changed, summary?}`.
pub fn rpc(m: &Value) -> Result<Value, String> {
    let (old, new) = (m["old"].as_str().unwrap_or(""), m["new"].as_str().ok_or("`new` is missing")?);
    Ok(match change(old, new, m["focus"].as_str().filter(|f| !f.trim().is_empty())) {
        Some(summary) => json!({"changed": true, "summary": summary}),
        None => json!({"changed": false}),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_words_that_changed_are_news() {
        let old = "Pricing\nStarter  €9 / month\nPro €29 / month\nContact us";
        assert_eq!(change(old, "Pricing\nStarter €9 / month\nPro €29 / month\nContact us", None), None, "spacing is no change");
        assert_eq!(change(old, "Pricing\nPro €29 / month\nStarter €9 / month\nContact us", None), None, "a line that moved is no change");
        let new = "Pricing\nStarter €12 / month\nPro €29 / month\nContact us";
        let said = change(old, new, None).unwrap();
        assert!(said.contains("+ Starter €12 / month") && said.contains("- Starter €9 / month"));
        assert_eq!(change(old, "Pricing\nStarter €9 / month\nPro €29 / month\nContact sales", Some("price month")), None, "outside the focus");
        assert!(rpc(&json!({"old": old, "new": new}))
            .unwrap()["summary"]
            .as_str()
            .unwrap()
            .contains("Now says"));
    }
}
