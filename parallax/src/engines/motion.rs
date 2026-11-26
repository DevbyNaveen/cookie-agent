//! Motion: motion graphics written as HTML and rendered to video, with
//! HyperFrames (HeyGen's open-source renderer, Apache-2.0: an HTML page with a
//! timeline, captured frame by frame in a headless browser and encoded with
//! FFmpeg). Titles, explainers, charts that move, captions, logo reveals.
//!
//! A motion project is a folder in the world (`index.html` and its
//! compositions). The engine scaffolds one, checks it (lint, layout,
//! contrast), shows the timeline, takes still frames to look at, and renders
//! it. Everything it writes stays in the world, so it can be undone, branched
//! and raced like any other change.
//!
//! The version is pinned, so a render today and a render next month use the
//! same code. It runs with `npx` (Node 22 or later) and needs FFmpeg; when
//! either is missing it says so rather than pretending.

use std::path::Path;
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{json, Value};

use crate::engine::{s, ActionSpec, Ctx, Effect, Engine};

/// The HyperFrames release every world uses.
pub const HYPERFRAMES: &str = "hyperframes@0.9.96";
/// How long a render may take; everything else gets five minutes.
const RENDER_WAIT: Duration = Duration::from_secs(30 * 60);
const STEP_WAIT: Duration = Duration::from_secs(5 * 60);
const QUALITIES: [&str; 3] = ["draft", "looks", "delivery"];
const FORMATS: [&str; 4] = ["mp4", "webm", "mov", "gif"];
const RESOLUTIONS: [&str; 6] = ["landscape", "portrait", "square", "landscape-4k", "portrait-4k", "square-4k"];

pub struct Motion;

/// `npx`, and a PATH that finds `node` and `ffmpeg` beside it (an app started from the Dock has a bare PATH).
fn npx() -> Result<(String, String), String> {
    let npx = super::tool(&["npx"]).ok_or("The motion engine uses Node.js 22 or later (npx); install Node to make motion graphics.")?;
    super::tool(&["ffmpeg"]).ok_or("The motion engine renders with FFmpeg; install ffmpeg to make motion graphics.")?;
    let dir = Path::new(&npx).parent().map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
    let path = format!("{dir}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin");
    Ok((npx, path))
}

/// Run `npx hyperframes …` in `cwd`, its output or why it failed (its `✗` and `Fix:` lines are kept).
async fn hyperframes(args: &[&str], cwd: &Path, wait: Duration) -> Result<String, String> {
    let (npx, path) = npx()?;
    let mut full = vec!["-y", HYPERFRAMES];
    full.extend_from_slice(args);
    let out = tokio::time::timeout(
        wait,
        tokio::process::Command::new(&npx)
            .args(&full)
            .current_dir(cwd)
            .env("PATH", path)
            // No AI-skill installs into the person's tools, no prompts.
            .env("HYPERFRAMES_SKIP_SKILLS", "1")
            .env("CI", "1")
            .stdin(std::process::Stdio::null())
            .output(),
    )
    .await
    .map_err(|_| format!("HyperFrames took longer than {} minutes.", wait.as_secs() / 60))?
    .map_err(|e| format!("npx: {e}"))?;
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        let why: String = stderr.lines().chain(stdout.lines()).filter(|l| l.contains('✗') || l.contains("Fix:") || l.to_lowercase().contains("error")).take(8).collect::<Vec<_>>().join("\n");
        return Err(if why.is_empty() { stderr.trim().chars().take(800).collect() } else { why });
    }
    Ok(stdout)
}

/// The JSON a command printed (it may print progress lines before it).
fn json_out(text: &str) -> Value {
    text.find(['{', '['])
        .and_then(|i| serde_json::Deserializer::from_str(&text[i..]).into_iter::<Value>().next())
        .and_then(Result::ok)
        .unwrap_or_else(|| json!({"text": text.chars().take(4000).collect::<String>()}))
}

/// A project folder inside the world that holds a composition.
fn project(ctx: &Ctx, args: &Value) -> Result<std::path::PathBuf, String> {
    let dir = ctx.path(s(args, "dir")?)?;
    if !dir.join("index.html").is_file() {
        return Err("That folder has no index.html. Start one with motion.new.".into());
    }
    Ok(dir)
}

#[async_trait]
impl Engine for Motion {
    fn name(&self) -> &'static str {
        "motion"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let p = json!({"type": "string"});
        vec![
            ActionSpec::new(
                "motion",
                "new",
                "Start a motion-graphics project in folder `dir`: index.html is the film (HTML and CSS, animated on a timeline). \
                 `resolution`: landscape (1920×1080, default), portrait, square, or a -4k one. Then write the scenes into index.html.",
                json!({"type": "object", "properties": {"dir": p, "resolution": {"type": "string", "enum": RESOLUTIONS}}, "required": ["dir"]}),
                Effect::Local,
            ),
            ActionSpec::new(
                "motion",
                "check",
                "Check the project as it will render: errors, layout, contrast. Fix every error before rendering.",
                json!({"type": "object", "properties": {"dir": p}, "required": ["dir"]}),
                Effect::Read,
            ),
            ActionSpec::new(
                "motion",
                "timeline",
                "The film's clips with their start and end times.",
                json!({"type": "object", "properties": {"dir": p}, "required": ["dir"]}),
                Effect::Read,
            ),
            ActionSpec::new(
                "motion",
                "snapshot",
                "Still frames to look at, at times `at` (seconds, comma separated, e.g. \"1,3.5,8\"); returns the PNG paths. Look before rendering.",
                json!({"type": "object", "properties": {"dir": p, "at": p}, "required": ["dir"]}),
                Effect::Local,
            ),
            ActionSpec::new(
                "motion",
                "render",
                "Render the film to `to` (mp4, webm, mov or gif by its ending). `quality`: draft while trying, looks (default), delivery for the final.",
                json!({"type": "object", "properties": {"dir": p, "to": p, "quality": {"type": "string", "enum": QUALITIES}}, "required": ["dir", "to"]}),
                Effect::Local,
            ),
        ]
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        match action {
            "new" => {
                let rel = s(args, "dir")?;
                let dir = ctx.path(rel)?;
                if dir.join("index.html").exists() {
                    return Err(format!("{rel} already holds a project."));
                }
                let parent = dir.parent().ok_or("No folder to make it in.")?;
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                let name = dir.file_name().map(|n| n.to_string_lossy().to_string()).ok_or("Name the folder.")?;
                let mut a = vec!["init", name.as_str(), "--non-interactive", "--skip-skills"];
                let res = args["resolution"].as_str().filter(|r| RESOLUTIONS.contains(r)).map(|r| format!("--resolution={r}"));
                if let Some(r) = &res {
                    a.push(r);
                }
                hyperframes(&a, parent, STEP_WAIT).await?;
                if !dir.join("index.html").is_file() {
                    return Err("HyperFrames made no index.html.".into());
                }
                Ok(json!({"made": rel, "edit": format!("{rel}/index.html")}))
            }
            "check" => Ok(json_out(&hyperframes(&["check", "--json"], &project(ctx, args)?, STEP_WAIT).await?)),
            "timeline" => Ok(json_out(&hyperframes(&["timeline", "--json"], &project(ctx, args)?, STEP_WAIT).await?)),
            "snapshot" => {
                let dir = project(ctx, args)?;
                let at = args["at"].as_str().map(str::trim).filter(|t| !t.is_empty());
                if let Some(t) = at {
                    if !t.split(',').all(|x| x.trim().parse::<f64>().is_ok()) {
                        return Err("`at` is seconds, comma separated, like \"1,3.5,8\".".into());
                    }
                }
                let flag = at.map(|t| format!("--at={t}"));
                let mut a = vec!["snapshot"];
                if let Some(f) = &flag {
                    a.push(f);
                }
                hyperframes(&a, &dir, STEP_WAIT).await?;
                let shots = dir.join(".hyperframes/artifacts/snapshots");
                let mut pngs: Vec<String> = std::fs::read_dir(&shots)
                    .into_iter()
                    .flatten()
                    .flatten()
                    .filter(|e| e.path().extension().is_some_and(|x| x == "png"))
                    .filter_map(|e| e.path().strip_prefix(&ctx.files).ok().map(|p| p.to_string_lossy().to_string()))
                    .collect();
                pngs.sort();
                Ok(json!({"frames": pngs}))
            }
            "render" => {
                let dir = project(ctx, args)?;
                let to_rel = s(args, "to")?;
                let to = ctx.path(to_rel)?;
                let ext = to.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
                if !FORMATS.contains(&ext.as_str()) {
                    return Err("Render to a .mp4, .webm, .mov or .gif.".into());
                }
                let quality = args["quality"].as_str().filter(|q| QUALITIES.contains(q)).unwrap_or("looks");
                if let Some(p) = to.parent() {
                    std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
                }
                let (o, q, f) = (format!("--output={}", to.to_string_lossy()), format!("--quality={quality}"), format!("--format={ext}"));
                hyperframes(&["render", ".", &o, &q, &f, "--quiet"], &dir, RENDER_WAIT).await?;
                let bytes = std::fs::metadata(&to).map(|m| m.len()).unwrap_or(0);
                if bytes == 0 {
                    return Err("The render finished but wrote nothing.".into());
                }
                // Its real length, from the file itself.
                let seconds = match super::tool(&["ffprobe"]) {
                    Some(ff) => super::run(&ff, &["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", &to.to_string_lossy()], &ctx.files).await.ok().and_then(|d| d.trim().parse::<f64>().ok()),
                    None => None,
                };
                Ok(json!({"written": to_rel, "bytes": bytes, "seconds": seconds, "quality": quality}))
            }
            other => Err(format!("The motion engine has no action {other}.")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_is_read_past_progress_lines() {
        assert_eq!(json_out("Checking…\n{\"ok\": true}\n")["ok"], true);
        assert_eq!(json_out("[1,2]")[1], 2);
        assert!(json_out("no json here")["text"].as_str().unwrap().contains("no json"));
    }

    #[test]
    fn the_version_is_pinned() {
        assert!(HYPERFRAMES.starts_with("hyperframes@") && HYPERFRAMES.split('@').nth(1).unwrap().split('.').count() == 3);
    }
}

#[cfg(test)]
mod live {
    use super::*;

    /// `cargo test -- --ignored live_motion`: needs Node, FFmpeg and the network for the first npx run.
    #[tokio::test]
    #[ignore]
    async fn live_motion_makes_checks_and_renders_a_film() {
        let dir = std::env::temp_dir().join(format!("px-motion-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let ctx = Ctx { world: "w".into(), files: dir.clone(), state: dir.join(".parallax"), home: dir.join("home") };
        let m = Motion;
        let made = m.call(&ctx, "new", &json!({"dir": "promo", "resolution": "landscape"})).await.unwrap();
        println!("new: {made}");
        let checked = m.call(&ctx, "check", &json!({"dir": "promo"})).await;
        println!("check: {}", checked.map(|v| v.to_string().chars().take(300).collect::<String>()).unwrap_or_else(|e| e));
        let out = m.call(&ctx, "render", &json!({"dir": "promo", "to": "out/promo.mp4", "quality": "draft"})).await.unwrap();
        println!("render: {out}");
        assert!(out["bytes"].as_u64().unwrap() > 1000);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
