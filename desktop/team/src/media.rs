//! Making images and video with Higgsfield, for agents with "Connected apps" on.
//!
//! The API as Higgsfield documents it (docs.higgsfield.ai, read 2026-11-26):
//! `https://api.higgsfield.ai`, the header `Authorization: Key <id>:<secret>`,
//! a POST to the model's path that answers `queued` with a `request_id` and a
//! `status_url`, then polling until `completed` (with `images[].url` or
//! `video.url`), `failed`, `nsfw` or `canceled`. Each submission carries an
//! `Idempotency-Key`, so a retry never pays twice.
//!
//! Only model paths read from Higgsfield's own pages are offered. A
//! generation costs credits on the person's Higgsfield account and sends the
//! prompt outside, so every call is an approval card first. What it makes is
//! downloaded into the agent's folder (Higgsfield deletes outputs after a
//! while), where the person, the agent and Parallax's engines can use it.

use std::sync::{Arc, Weak};
use std::time::Duration;

use cookie_harness::tool::{tool, Effect, Tool};
use serde_json::{json, Value};

use crate::{util, Team};

const BASE: &str = "https://api.higgsfield.ai";

/// (name, path, kind, needs an image URL, what it is) — each path from Higgsfield's documentation.
pub const MODELS: [(&str, &str, &str, bool, &str); 4] = [
    ("soul", "/higgsfield-ai/soul/standard", "image", false, "Soul: photoreal images (aspect_ratio like 1:1, 16:9, 9:16; resolution like 720p)"),
    ("soul-2", "/higgsfield-ai/soul/v2/standard", "image", false, "Soul 2: images"),
    ("kling-3-pro", "/kling-video/v3.0/pro/text-to-video", "video", false, "Kling 3 Pro: video from a prompt"),
    ("wan-2.6", "/wan/v2.6/image-to-video", "video", true, "Wan 2.6: video from an image (image_url) and a prompt"),
];

fn creds() -> Option<String> {
    let id = std::env::var("HF_API_KEY_ID").ok().filter(|v| !v.trim().is_empty())?;
    let secret = std::env::var("HF_API_KEY_SECRET").ok().filter(|v| !v.trim().is_empty())?;
    Some(format!("Key {}:{}", id.trim(), secret.trim()))
}

/// Higgsfield is set up on this Mac.
pub fn ready() -> bool {
    creds().is_some()
}

fn http() -> &'static reqwest::Client {
    static C: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    C.get_or_init(|| reqwest::Client::builder().connect_timeout(Duration::from_secs(15)).user_agent("cookie-desktop").build().unwrap_or_default())
}

/// The output URLs of a finished request, from its status answer.
pub fn outputs(v: &Value) -> Vec<String> {
    let mut out: Vec<String> = v["images"].as_array().into_iter().flatten().filter_map(|i| i["url"].as_str().map(str::to_string)).collect();
    for k in ["video", "audio"] {
        if let Some(u) = v[k]["url"].as_str() {
            out.push(u.to_string());
        }
    }
    out
}

/// Submit, wait, download. Returns the files written (relative to the agent's folder) and the request id.
async fn generate(team: &Team, agent: &str, model: &str, body: Value, wait: Duration) -> Result<(Vec<String>, String), String> {
    let auth = creds().ok_or("Higgsfield isn't set up: add its API key ID and secret in Settings → Models (from console.higgsfield.ai).")?;
    let (_, path, kind, _, _) = MODELS.iter().find(|m| m.0 == model).ok_or_else(|| format!("No model {model}. One of: {}.", MODELS.iter().map(|m| m.0).collect::<Vec<_>>().join(", ")))?;
    let idem = util::random_hex(16);
    let r = http().post(format!("{BASE}{path}")).header("Authorization", &auth).header("Idempotency-Key", &idem).json(&body).timeout(Duration::from_secs(60)).send().await.map_err(|e| e.to_string())?;
    let status = r.status();
    let v: Value = r.json().await.unwrap_or(Value::Null);
    if !status.is_success() {
        return Err(match status.as_u16() {
            401 => "Higgsfield refused the key (401). Check the key ID and secret in Settings → Models.".into(),
            402 => "Higgsfield says the account is out of credits (402).".into(),
            404 | 423 | 503 => format!("That model isn't available to this Higgsfield account right now ({status})."),
            _ => format!("Higgsfield answered {status}: {}", util::clip(&v.to_string(), 300)),
        });
    }
    let id = v["request_id"].as_str().ok_or("Higgsfield gave no request id.")?.to_string();
    let status_url = v["status_url"].as_str().map(str::to_string).unwrap_or_else(|| format!("{BASE}/requests/{id}/status"));
    let deadline = std::time::Instant::now() + wait;
    let done = loop {
        tokio::time::sleep(Duration::from_secs(4)).await;
        let s: Value = match http().get(&status_url).header("Authorization", &auth).timeout(Duration::from_secs(30)).send().await {
            Ok(r) => r.json().await.unwrap_or(Value::Null),
            Err(_) => Value::Null,
        };
        match s["status"].as_str().unwrap_or("") {
            "completed" => break s,
            "failed" => return Err(format!("Higgsfield couldn't make it: {}", s["error"].as_str().unwrap_or("no reason given"))),
            "nsfw" => return Err("Higgsfield's moderation refused it (nsfw).".into()),
            "canceled" => return Err("The request was canceled.".into()),
            _ => {}
        }
        if std::time::Instant::now() > deadline {
            return Err(format!("Still not done after {} minutes; request {id} keeps going at Higgsfield.", wait.as_secs() / 60));
        }
    };
    let dir = team.paths.work(agent).join("media");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut files = Vec::new();
    for (i, url) in outputs(&done).into_iter().enumerate() {
        let bytes = http().get(&url).timeout(Duration::from_secs(300)).send().await.map_err(|e| e.to_string())?.bytes().await.map_err(|e| e.to_string())?;
        let ext = url.split('?').next().and_then(|u| u.rsplit('.').next()).filter(|e| e.len() <= 4 && e.chars().all(|c| c.is_ascii_alphanumeric())).unwrap_or(if *kind == "video" { "mp4" } else { "png" });
        let name = format!("{model}-{}-{i}.{ext}", &id[..id.len().min(8)]);
        std::fs::write(dir.join(&name), &bytes).map_err(|e| e.to_string())?;
        files.push(format!("media/{name}"));
    }
    if files.is_empty() {
        return Err("Higgsfield finished but returned no files.".into());
    }
    Ok((files, id))
}

/// `make_image` and `make_video`.
pub(crate) fn tools(team: &Arc<Team>, agent: &str) -> Vec<Arc<dyn Tool>> {
    let w: Weak<Team> = Arc::downgrade(team);
    let aid = agent.to_string();
    let image_models: Vec<&str> = MODELS.iter().filter(|m| m.2 == "image").map(|m| m.0).collect();
    let video_models: Vec<&str> = MODELS.iter().filter(|m| m.2 == "video").map(|m| m.0).collect();
    let list = |kind: &str| MODELS.iter().filter(|m| m.2 == kind).map(|m| format!("{} ({})", m.0, m.4)).collect::<Vec<_>>().join("; ");
    let image = tool(
        "make_image",
        &format!("Make an image with Higgsfield from a prompt; it is saved in your folder (media/). Costs credits on the person's Higgsfield account, so they approve it first. Models: {}.", list("image")),
        json!({"type": "object", "properties": {
            "prompt": {"type": "string"},
            "model": {"type": "string", "enum": image_models},
            "aspect_ratio": {"type": "string", "description": "like 1:1, 16:9, 9:16, 4:5"},
            "options": {"type": "object", "description": "other fields the model's Higgsfield page lists"}
        }, "required": ["prompt"]}),
        Effect::Outbound,
        {
            let (w, aid) = (w.clone(), aid.clone());
            move |args: Value| {
                let (w, aid) = (w.clone(), aid.clone());
                async move {
                    let team = w.upgrade().ok_or("Cookie is closing.")?;
                    let model = args["model"].as_str().unwrap_or("soul").to_string();
                    let mut body = args["options"].as_object().cloned().unwrap_or_default();
                    body.insert("prompt".into(), json!(args["prompt"].as_str().unwrap_or("")));
                    if let Some(a) = args["aspect_ratio"].as_str() {
                        body.insert("aspect_ratio".into(), json!(a));
                    }
                    let (files, id) = generate(&team, &aid, &model, Value::Object(body), Duration::from_secs(300)).await?;
                    Ok(format!("Made with Higgsfield ({model}, request {id}): {}", files.join(", ")))
                }
            }
        },
    )
    .with_preview(|a| format!("Make an image with Higgsfield ({}), using the person's credits:\n{}", a["model"].as_str().unwrap_or("soul"), util::clip(a["prompt"].as_str().unwrap_or(""), 600)));
    let video = tool(
        "make_video",
        &format!("Make a video with Higgsfield from a prompt (or an image URL and a prompt); it is saved in your folder (media/). Costs credits, so the person approves it first. Models: {}. For titles, charts and motion graphics, use Parallax's motion engine instead.", list("video")),
        json!({"type": "object", "properties": {
            "prompt": {"type": "string"},
            "model": {"type": "string", "enum": video_models},
            "image_url": {"type": "string", "description": "for an image-to-video model: a public https address of the image"},
            "options": {"type": "object", "description": "other fields the model's Higgsfield page lists (duration, aspect ratio…)"}
        }, "required": ["prompt"]}),
        Effect::Outbound,
        move |args: Value| {
            let (w, aid) = (w.clone(), aid.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                let model = args["model"].as_str().unwrap_or("kling-3-pro").to_string();
                let needs_image = MODELS.iter().any(|m| m.0 == model && m.3);
                let mut body = args["options"].as_object().cloned().unwrap_or_default();
                body.insert("prompt".into(), json!(args["prompt"].as_str().unwrap_or("")));
                match args["image_url"].as_str().filter(|u| u.starts_with("https://")) {
                    Some(u) => {
                        body.insert("image_url".into(), json!(u));
                    }
                    None if needs_image => return Err(format!("{model} makes video from an image: give image_url, a public https address.")),
                    None => {}
                }
                let (files, id) = generate(&team, &aid, &model, Value::Object(body), Duration::from_secs(900)).await?;
                Ok(format!("Made with Higgsfield ({model}, request {id}): {}", files.join(", ")))
            }
        },
    )
    .with_preview(|a| format!("Make a video with Higgsfield ({}), using the person's credits:\n{}", a["model"].as_str().unwrap_or("kling-3-pro"), util::clip(a["prompt"].as_str().unwrap_or(""), 600)));
    vec![Arc::new(image), Arc::new(video)]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outputs_are_read_from_each_kind_of_answer() {
        assert_eq!(outputs(&json!({"status": "completed", "images": [{"url": "https://a/1.jpg"}, {"url": "https://a/2.jpg"}]})), vec!["https://a/1.jpg", "https://a/2.jpg"]);
        assert_eq!(outputs(&json!({"status": "completed", "video": {"url": "https://a/v.mp4"}})), vec!["https://a/v.mp4"]);
        assert!(outputs(&json!({"status": "queued"})).is_empty());
    }

    #[test]
    fn every_model_has_a_documented_path() {
        for (name, path, kind, _, _) in MODELS {
            assert!(path.starts_with('/') && !path.contains(' '), "{name}");
            assert!(matches!(kind, "image" | "video"));
        }
    }
}
