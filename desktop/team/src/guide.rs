//! What every agent knows about Cookie itself.
//!
//! `guide.md` is the app's own guide, one section per feature or screen,
//! shipped inside the build so it always matches the app the person runs.
//! From it come two things:
//! - the map: one line per section, in every agent's instructions (cached
//!   with them), so "can you…" and "where is…" are answered from the app, not
//!   from a model's guess;
//! - `app_help`: the full section(s) a question needs, found on demand.
//!
//! The map is made from the sections' own summaries, so the two never
//! disagree; tests fail the build when a setting or a Settings tab has no
//! place in the guide.

use std::sync::Arc;

use cookie_harness::tool::{tool, Effect, Tool};
use serde_json::{json, Value};

const GUIDE: &str = include_str!("guide.md");

/// One section: `## id | Title`, then `> summary`, then the body.
pub(crate) struct Section {
    pub id: &'static str,
    pub title: &'static str,
    pub summary: &'static str,
    pub body: &'static str,
}

pub(crate) fn sections() -> &'static [Section] {
    static ALL: std::sync::OnceLock<Vec<Section>> = std::sync::OnceLock::new();
    ALL.get_or_init(|| parse(GUIDE))
}

fn parse(text: &'static str) -> Vec<Section> {
    let mut out = Vec::new();
    let mut starts: Vec<usize> = text.match_indices("\n## ").map(|(i, _)| i + 1).collect();
    starts.push(text.len());
    for w in starts.windows(2) {
        let chunk = &text[w[0]..w[1]];
        let (head, rest) = chunk.split_once('\n').unwrap_or((chunk, ""));
        let Some((id, title)) = head.trim_start_matches("## ").split_once('|') else { continue };
        let rest = rest.trim_start();
        let (summary, body) = match rest.strip_prefix('>') {
            Some(r) => r.split_once('\n').map(|(s, b)| (s.trim(), b.trim())).unwrap_or((r.trim(), "")),
            None => ("", rest.trim()),
        };
        out.push(Section { id: id.trim(), title: title.trim(), summary, body });
    }
    out
}

/// The always-on map of the app, for every agent's instructions.
pub(crate) fn map() -> String {
    let mut s = String::from(
        "About Cookie, the app you are part of (the person's Mac app where they hire focused AI agents like you). \
         What it has, one line each:\n",
    );
    for x in sections() {
        // Title and the start of its summary: enough to know it exists; app_help has the rest.
        let words: Vec<&str> = x.summary.split_whitespace().collect();
        let short = if words.len() > 12 { format!("{}…", words[..12].join(" ").trim_end_matches([',', ';', ':', '.'])) } else { x.summary.to_string() };
        s.push_str(&format!("- {}: {}\n", x.title, short));
    }
    s.push_str(
        "Before telling the person the app can't do something, or how to do something in it, look it up with app_help: never from memory. \
         To see or change a setting for them, use settings_search and settings_set (the person approves each change).",
    );
    s
}

/// The sections that answer a question, best first.
pub(crate) fn lookup(query: &str, k: usize) -> Vec<&'static Section> {
    let docs: Vec<crate::shelf::Doc> = sections()
        .iter()
        .map(|x| crate::shelf::Doc { key: x.id.into(), name: x.title.into(), description: x.summary.into(), body: x.body.into() })
        .collect();
    // An exact id or title wins outright.
    let q = query.trim().to_lowercase();
    if let Some(x) = sections().iter().find(|x| x.id == q || x.title.to_lowercase() == q) {
        return vec![x];
    }
    crate::shelf::rank(query, &docs, k, 1).into_iter().filter_map(|(id, _)| sections().iter().find(|x| x.id == id)).collect()
}

/// `app_help`: how the app works, from its own guide.
pub(crate) fn help_tool() -> Arc<dyn Tool> {
    Arc::new(tool(
        "app_help",
        "How Cookie (this app) works, from its own guide: what a feature does, where it is, how the person does something, and what \
         you can do about it yourself. Look here before saying the app can't do something.",
        json!({"type": "object", "properties": {
            "query": {"type": "string", "description": "the question or feature, e.g. 'schedule a routine', 'connect Telegram', 'what is a contractor'"}
        }, "required": ["query"]}),
        Effect::Read,
        |a: Value| async move {
            let q = a["query"].as_str().unwrap_or("").trim().to_string();
            let hits = lookup(&q, 2);
            if hits.is_empty() {
                let all: Vec<&str> = sections().iter().map(|x| x.title).collect();
                return Ok(format!("Nothing in the guide matches \"{q}\". Its sections: {}.", all.join(", ")));
            }
            Ok(hits.iter().map(|x| format!("## {}\n{}\n\n{}", x.title, x.summary, x.body)).collect::<Vec<_>>().join("\n\n"))
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_guide_is_well_formed() {
        let all = sections();
        assert!(all.len() >= 30, "the guide has {} sections", all.len());
        let mut ids: Vec<&str> = all.iter().map(|x| x.id).collect();
        ids.sort();
        let n = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), n, "section ids are unique");
        for x in all {
            assert!(!x.summary.is_empty() && x.summary.len() <= 200, "{} needs a one-line summary", x.id);
            assert!(x.body.split_whitespace().count() >= 30, "{} needs a body", x.id);
            assert!(x.id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'), "{}", x.id);
        }
        // The map stays small enough to ride along with every agent.
        assert!(map().split_whitespace().count() < 1_100, "the map is {} words", map().split_whitespace().count());
    }

    /// Drift guard: every Settings tab and every setting an agent can change has a place in the guide.
    #[test]
    fn every_settings_tab_and_setting_is_in_the_guide() {
        let html = include_str!("../../ui/index.html");
        let nav = html.split("id=\"set-nav\"").nth(1).and_then(|r| r.split("</nav>").next()).unwrap_or("");
        let text = GUIDE.to_lowercase();
        for b in nav.split("data-tab=\"").skip(1) {
            let label = b.split("</svg>").nth(1).and_then(|r| r.split('<').next()).unwrap_or("").trim().to_lowercase();
            assert!(!label.is_empty());
            assert!(text.contains(&format!("settings → {label}")) || text.contains(&format!("settings > {label}")) || sections().iter().any(|s| s.title.to_lowercase().contains(&label)), "Settings → {label} isn't in the guide");
        }
        for k in crate::appsettings::KEYS {
            let words: Vec<String> = crate::shelf::terms(k.title);
            let found = lookup(k.title, 3).iter().any(|s| {
                let body = crate::shelf::terms(&format!("{} {} {}", s.title, s.summary, s.body));
                words.iter().filter(|w| body.contains(w)).count() * 2 >= words.len()
            });
            assert!(found, "the setting \"{}\" ({}) isn't explained in the guide", k.title, k.id);
        }
    }

    #[test]
    fn questions_find_their_section() {
        assert!(!lookup("hire a new agent", 2).is_empty());
        assert!(!lookup("change the model", 2).is_empty());
    }
}
