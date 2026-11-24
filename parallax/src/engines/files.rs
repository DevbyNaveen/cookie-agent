//! Files: list, read, search, write, move and delete inside the world.

use async_trait::async_trait;
use serde_json::{json, Value};

use crate::engine::{s, ActionSpec, Ctx, Effect, Engine};

pub struct Files;

const READ_CAP: usize = 200_000;

#[async_trait]
impl Engine for Files {
    fn name(&self) -> &'static str {
        "files"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let p = |extra: Value| {
            let mut props = json!({"path": {"type": "string", "description": "a path inside the world"}});
            if let (Some(a), Some(b)) = (props.as_object_mut(), extra.as_object()) {
                a.extend(b.clone());
            }
            props
        };
        vec![
            ActionSpec::new("files", "list", "List a folder in the world (\".\" for the top).", json!({"type": "object", "properties": p(json!({}))}), Effect::Read),
            ActionSpec::new("files", "read", "Read a text file.", json!({"type": "object", "properties": p(json!({})), "required": ["path"]}), Effect::Read),
            ActionSpec::new("files", "search", "Find files whose name or text contains words.", json!({"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}), Effect::Read),
            ActionSpec::new("files", "write", "Write a text file (made or replaced).", json!({"type": "object", "properties": p(json!({"text": {"type": "string"}})), "required": ["path", "text"]}), Effect::Local),
            ActionSpec::new("files", "move", "Move or rename a file.", json!({"type": "object", "properties": p(json!({"to": {"type": "string"}})), "required": ["path", "to"]}), Effect::Local),
            ActionSpec::new("files", "delete", "Delete a file or an empty folder.", json!({"type": "object", "properties": p(json!({})), "required": ["path"]}), Effect::Local),
        ]
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        match action {
            "list" => {
                let rel = args["path"].as_str().unwrap_or(".");
                let dir = if rel == "." || rel.is_empty() { ctx.files.clone() } else { ctx.path(rel)? };
                let mut out = Vec::new();
                for e in std::fs::read_dir(&dir).map_err(|e| e.to_string())?.flatten() {
                    let name = e.file_name().to_string_lossy().to_string();
                    if name == ".parallax" {
                        continue;
                    }
                    let m = e.metadata().map_err(|e| e.to_string())?;
                    out.push(json!({"name": name, "folder": m.is_dir(), "bytes": m.len()}));
                }
                out.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
                Ok(json!(out))
            }
            "read" => {
                let b = std::fs::read(ctx.path(s(args, "path")?)?).map_err(|e| e.to_string())?;
                let text = String::from_utf8(b).map_err(|_| "That file isn't text; use its engine (pdf, image, …).")?;
                Ok(json!({"text": crate::util::clip(&text, READ_CAP), "chars": text.chars().count()}))
            }
            "search" => {
                let q = s(args, "query")?.to_lowercase();
                let words: Vec<&str> = q.split_whitespace().collect();
                let mut hits = Vec::new();
                for (path, _) in crate::world::digests(&ctx.files) {
                    let full = ctx.files.join(&path);
                    let text = std::fs::read_to_string(&full).unwrap_or_default().to_lowercase();
                    let hay = format!("{} {}", path.to_lowercase(), text);
                    if words.iter().all(|w| hay.contains(w)) {
                        let line = text.lines().find(|l| words.iter().any(|w| l.contains(w))).map(|l| crate::util::clip(l.trim(), 160));
                        hits.push(json!({"path": path, "line": line}));
                        if hits.len() >= 50 {
                            break;
                        }
                    }
                }
                Ok(json!(hits))
            }
            "write" => {
                let p = ctx.path(s(args, "path")?)?;
                if let Some(d) = p.parent() {
                    std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
                }
                let text = s(args, "text")?;
                std::fs::write(&p, text).map_err(|e| e.to_string())?;
                Ok(json!({"written": s(args, "path")?, "bytes": text.len()}))
            }
            "move" => {
                let (from, to) = (ctx.path(s(args, "path")?)?, ctx.path(s(args, "to")?)?);
                if to.exists() {
                    return Err("Something is already there; delete or rename it first.".into());
                }
                if let Some(d) = to.parent() {
                    std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
                }
                std::fs::rename(from, to).map_err(|e| e.to_string())?;
                Ok(json!({"moved": s(args, "path")?, "to": s(args, "to")?}))
            }
            "delete" => {
                let p = ctx.path(s(args, "path")?)?;
                if p.is_dir() { std::fs::remove_dir(&p) } else { std::fs::remove_file(&p) }.map_err(|e| e.to_string())?;
                Ok(json!({"deleted": s(args, "path")?}))
            }
            other => Err(format!("The files engine has no action {other}.")),
        }
    }
}
