//! Image: size and format, resize, convert, rotate, crop (`sips`, built into macOS).

use async_trait::async_trait;
use serde_json::{json, Value};

use crate::engine::{s, ActionSpec, Ctx, Effect, Engine};

pub struct Image;

fn sips() -> Result<String, String> {
    super::tool(&["sips"]).ok_or_else(|| "The image engine uses sips (macOS); it isn't on this machine.".into())
}

#[async_trait]
impl Engine for Image {
    fn name(&self) -> &'static str {
        "image"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let p = json!({"type": "string"});
        let n = json!({"type": "integer"});
        vec![
            ActionSpec::new("image", "info", "Width, height and format of an image.", json!({"type": "object", "properties": {"path": p}, "required": ["path"]}), Effect::Read),
            ActionSpec::new("image", "resize", "Resize to fit within `max` pixels on the longer side, into `to`.", json!({"type": "object", "properties": {"path": p, "max": n, "to": p}, "required": ["path", "max", "to"]}), Effect::Local),
            ActionSpec::new("image", "convert", "Convert to jpeg, png, heic, tiff or gif, into `to`.", json!({"type": "object", "properties": {"path": p, "format": {"type": "string", "enum": ["jpeg", "png", "heic", "tiff", "gif"]}, "to": p}, "required": ["path", "format", "to"]}), Effect::Local),
            ActionSpec::new("image", "rotate", "Rotate by degrees (clockwise), into `to`.", json!({"type": "object", "properties": {"path": p, "degrees": n, "to": p}, "required": ["path", "degrees", "to"]}), Effect::Local),
            ActionSpec::new("image", "crop", "Crop to `width` × `height` around the centre, into `to`.", json!({"type": "object", "properties": {"path": p, "width": n, "height": n, "to": p}, "required": ["path", "width", "height", "to"]}), Effect::Local),
        ]
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        let src = ctx.path(s(args, "path")?)?;
        let src_s = src.to_string_lossy().to_string();
        let num = |k: &str| args[k].as_i64().filter(|v| *v > 0).map(|v| v.to_string()).ok_or_else(|| format!("Needs `{k}`, a positive number."));
        if action == "info" {
            let out = super::run(&sips()?, &["-g", "pixelWidth", "-g", "pixelHeight", "-g", "format", &src_s], &ctx.files).await?;
            let get = |k: &str| out.lines().find_map(|l| l.trim().strip_prefix(&format!("{k}: ")).map(str::trim).map(str::to_string));
            return Ok(json!({"width": get("pixelWidth").and_then(|v| v.parse::<u64>().ok()), "height": get("pixelHeight").and_then(|v| v.parse::<u64>().ok()), "format": get("format")}));
        }
        let to_rel = s(args, "to")?;
        let to = ctx.path(to_rel)?.to_string_lossy().to_string();
        let a: Vec<String> = match action {
            "resize" => vec!["-Z".into(), num("max")?, src_s, "--out".into(), to],
            "convert" => {
                let f = s(args, "format")?;
                if !["jpeg", "png", "heic", "tiff", "gif"].contains(&f) {
                    return Err("jpeg, png, heic, tiff or gif.".into());
                }
                vec!["-s".into(), "format".into(), f.into(), src_s, "--out".into(), to]
            }
            "rotate" => vec!["-r".into(), args["degrees"].as_i64().ok_or("Needs `degrees`.")?.to_string(), src_s, "--out".into(), to],
            "crop" => vec!["-c".into(), num("height")?, num("width")?, src_s, "--out".into(), to],
            other => return Err(format!("The image engine has no action {other}.")),
        };
        let refs: Vec<&str> = a.iter().map(String::as_str).collect();
        super::run(&sips()?, &refs, &ctx.files).await?;
        Ok(json!({"written": to_rel}))
    }
}
