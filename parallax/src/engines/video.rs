//! Video: what a video is, cut a part, take a frame, take the sound (`ffmpeg`).

use async_trait::async_trait;
use serde_json::{json, Value};

use crate::engine::{s, ActionSpec, Ctx, Effect, Engine};

pub struct Video;

fn need(name: &str) -> Result<String, String> {
    super::tool(&[name]).ok_or_else(|| format!("The video engine uses {name} (ffmpeg); install ffmpeg to use it."))
}

/// "75.5" or "1:15.5" or "0:01:15" → seconds.
pub fn seconds(t: &str) -> Result<f64, String> {
    let parts: Vec<&str> = t.trim().split(':').collect();
    let mut total = 0.0;
    for p in &parts {
        total = total * 60.0 + p.parse::<f64>().map_err(|_| format!("“{t}” isn't a time"))?;
    }
    if parts.len() > 3 || total < 0.0 { Err(format!("“{t}” isn't a time")) } else { Ok(total) }
}

#[async_trait]
impl Engine for Video {
    fn name(&self) -> &'static str {
        "video"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let p = json!({"type": "string"});
        vec![
            ActionSpec::new("video", "info", "Length, size and streams of a video.", json!({"type": "object", "properties": {"path": p}, "required": ["path"]}), Effect::Read),
            ActionSpec::new("video", "cut", "Keep from `start` to `end` (seconds or m:ss), into `to`.", json!({"type": "object", "properties": {"path": p, "start": p, "end": p, "to": p}, "required": ["path", "start", "end", "to"]}), Effect::Local),
            ActionSpec::new("video", "frame", "Save the frame at `at` as an image, into `to` (.png or .jpg).", json!({"type": "object", "properties": {"path": p, "at": p, "to": p}, "required": ["path", "at", "to"]}), Effect::Local),
            ActionSpec::new("video", "sound", "Save the sound track, into `to` (.m4a or .mp3).", json!({"type": "object", "properties": {"path": p, "to": p}, "required": ["path", "to"]}), Effect::Local),
        ]
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        let src = ctx.path(s(args, "path")?)?.to_string_lossy().to_string();
        if action == "info" {
            let out = super::run(&need("ffprobe")?, &["-v", "error", "-print_format", "json", "-show_format", "-show_streams", &src], &ctx.files).await?;
            let v: Value = serde_json::from_str(&out).map_err(|e| e.to_string())?;
            let streams: Vec<Value> = v["streams"].as_array().into_iter().flatten().map(|s| json!({"kind": s["codec_type"], "codec": s["codec_name"], "width": s["width"], "height": s["height"]})).collect();
            return Ok(json!({"seconds": v["format"]["duration"].as_str().and_then(|d| d.parse::<f64>().ok()), "bytes": v["format"]["size"].as_str().and_then(|d| d.parse::<u64>().ok()), "streams": streams}));
        }
        let to_rel = s(args, "to")?;
        let to = ctx.path(to_rel)?.to_string_lossy().to_string();
        let ff = need("ffmpeg")?;
        let a: Vec<String> = match action {
            "cut" => {
                let (a, b) = (seconds(s(args, "start")?)?, seconds(s(args, "end")?)?);
                if b <= a {
                    return Err("The end comes after the start.".into());
                }
                vec!["-y".into(), "-v".into(), "error".into(), "-ss".into(), a.to_string(), "-to".into(), b.to_string(), "-i".into(), src, "-c".into(), "copy".into(), to]
            }
            "frame" => vec!["-y".into(), "-v".into(), "error".into(), "-ss".into(), seconds(s(args, "at")?)?.to_string(), "-i".into(), src, "-frames:v".into(), "1".into(), to],
            "sound" => vec!["-y".into(), "-v".into(), "error".into(), "-i".into(), src, "-vn".into(), to],
            other => return Err(format!("The video engine has no action {other}.")),
        };
        let refs: Vec<&str> = a.iter().map(String::as_str).collect();
        super::run(&ff, &refs, &ctx.files).await?;
        Ok(json!({"written": to_rel}))
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn times_read_as_people_write_them() {
        assert_eq!(super::seconds("75.5").unwrap(), 75.5);
        assert_eq!(super::seconds("1:15.5").unwrap(), 75.5);
        assert_eq!(super::seconds("0:01:15").unwrap(), 75.0);
        assert!(super::seconds("soon").is_err());
    }
}
