//! Finding pictures: real, freely licensed photos from Wikimedia Commons, for
//! agents with "The web" on. No key needed. Each picture comes with its page,
//! who made it and its license, so it can be shown and credited.
//!
//! The chat shows pictures from Wikimedia's image server at once (its paths
//! are files that exist; nothing an agent read decides what else loads);
//! pictures from anywhere else still wait for the person's click.

use std::sync::Arc;
use std::time::Duration;

use cookie_harness::tool::{tool, Effect, Tool};
use serde_json::{json, Value};

const API: &str = "https://commons.wikimedia.org/w/api.php";

/// HTML in Commons' credit fields, as plain words.
fn plain(html: &str) -> String {
    let mut out = String::new();
    let mut tag = false;
    for c in html.chars() {
        match c {
            '<' => tag = true,
            '>' => tag = false,
            c if !tag => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Commons' answer as the lines an agent puts in its reply.
fn render(v: &Value) -> Vec<String> {
    let mut pages: Vec<&Value> = v["query"]["pages"].as_object().map(|m| m.values().collect()).unwrap_or_default();
    pages.sort_by_key(|p| p["index"].as_i64().unwrap_or(i64::MAX));
    pages
        .into_iter()
        .filter_map(|p| {
            let info = p["imageinfo"].get(0)?;
            // The file itself: Commons adds tracking words (`?utm_source=…`) to some addresses.
            let url = info["thumburl"].as_str().or(info["url"].as_str())?.split('?').next()?;
            if !url.starts_with("https://upload.wikimedia.org/") {
                return None;
            }
            let title = p["title"].as_str().unwrap_or("").trim_start_matches("File:");
            let name = title.rsplit_once('.').map(|(n, _)| n).unwrap_or(title).replace(['_', '[', ']'], " ");
            let meta = &info["extmetadata"];
            let by = plain(meta["Artist"]["value"].as_str().unwrap_or("unknown"));
            let license = meta["LicenseShortName"]["value"].as_str().unwrap_or("see page");
            let page = info["descriptionurl"].as_str().unwrap_or("");
            Some(format!("![{name}]({url})\n{name} — by {by}, {license} ({page})"))
        })
        .collect()
}

pub(crate) fn tools() -> Vec<Arc<dyn Tool>> {
    vec![Arc::new(tool(
        "find_images",
        "Find real photos of something (a gym machine, a plant, a place, a tool) on Wikimedia Commons: freely licensed, with \
         who made each and its license. Put the lines you want in your reply as they are (each is a picture, then its credit); \
         the person sees the pictures in the chat. Describe what to look for in plain words, e.g. \"leg press machine\".",
        json!({"type": "object", "properties": {
            "query": {"type": "string"},
            "count": {"type": "integer", "description": "how many, 1-8 (default 4)"}
        }, "required": ["query"]}),
        Effect::Read,
        |a: Value| async move {
            let q = a["query"].as_str().unwrap_or("").trim().to_string();
            if q.is_empty() {
                return Err("Say what to look for.".into());
            }
            let n = a["count"].as_u64().unwrap_or(4).clamp(1, 8);
            let search = format!("filetype:bitmap {q}");
            let resp = reqwest::Client::new()
                .get(API)
                .query(&[
                    ("action", "query"),
                    ("format", "json"),
                    ("generator", "search"),
                    ("gsrnamespace", "6"),
                    ("gsrsearch", search.as_str()),
                    ("gsrlimit", &n.to_string()),
                    ("prop", "imageinfo"),
                    ("iiprop", "url|extmetadata"),
                    ("iiurlwidth", "640"),
                    ("iiextmetadatafilter", "Artist|LicenseShortName"),
                ])
                // Wikimedia asks clients to say what they are; nothing about the person.
                .header("User-Agent", "Cookie/0.1 (desktop agents; https://enkeon.com)")
                .timeout(Duration::from_secs(20))
                .send()
                .await
                .map_err(|e| format!("Wikimedia Commons didn't answer: {e}"))?;
            let v: Value = resp.json().await.map_err(|e| e.to_string())?;
            let lines = render(&v);
            Ok(if lines.is_empty() { format!("No pictures of \"{q}\" on Wikimedia Commons. Try the name it's usually filed under (e.g. \"cable crossover\" for a cable tower), or fewer words.") } else { lines.join("\n\n") })
        },
    ))]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commons_answers_become_pictures_with_credits_in_search_order() {
        let v = json!({"query": {"pages": {
            "2": {"index": 2, "title": "File:Leg_press.jpg", "imageinfo": [{"thumburl": "https://upload.wikimedia.org/a/640px-Leg_press.jpg", "descriptionurl": "https://commons.wikimedia.org/wiki/File:Leg_press.jpg",
                "extmetadata": {"Artist": {"value": "<a href=\"x\">Jane</a> Doe"}, "LicenseShortName": {"value": "CC BY-SA 4.0"}}}]},
            "1": {"index": 1, "title": "File:Cable machine.png", "imageinfo": [{"thumburl": "https://upload.wikimedia.org/b/cable.png?utm_source=commons.wikimedia.org", "descriptionurl": "https://commons.wikimedia.org/wiki/File:Cable_machine.png", "extmetadata": {}}]},
            "3": {"index": 3, "title": "File:Elsewhere.jpg", "imageinfo": [{"thumburl": "https://evil.example/x.jpg"}]}
        }}});
        let lines = render(&v);
        assert_eq!(lines.len(), 2, "only Wikimedia's own image server");
        assert!(lines[0].starts_with("![Cable machine](https://upload.wikimedia.org/b/cable.png)"), "{}", lines[0]);
        assert!(lines[1].contains("by Jane Doe, CC BY-SA 4.0"), "credit as plain words: {}", lines[1]);
    }
}
