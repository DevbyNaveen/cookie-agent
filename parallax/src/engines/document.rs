//! Document: Markdown documents by heading, and conversion between formats
//! (`textutil` on a Mac: txt, html, rtf, doc, docx, odt).

use async_trait::async_trait;
use serde_json::{json, Value};

use crate::engine::{s, ActionSpec, Ctx, Effect, Engine};

pub struct Document;

/// (heading line index, level, title) for every Markdown heading.
fn headings(text: &str) -> Vec<(usize, usize, String)> {
    let mut fenced = false;
    text.lines()
        .enumerate()
        .filter_map(|(i, l)| {
            if l.trim_start().starts_with("```") {
                fenced = !fenced;
            }
            if fenced {
                return None;
            }
            let level = l.chars().take_while(|c| *c == '#').count();
            (level > 0 && level <= 6 && l.chars().nth(level) == Some(' ')).then(|| (i, level, l[level..].trim().to_string()))
        })
        .collect()
}

/// Replace the body under one heading (up to the next heading of the same or higher level).
pub fn set_section(text: &str, title: &str, body: &str) -> Result<String, String> {
    let lines: Vec<&str> = text.lines().collect();
    let hs = headings(text);
    let (at, level) = hs.iter().find(|(_, _, t)| t.eq_ignore_ascii_case(title.trim())).map(|(i, l, _)| (*i, *l)).ok_or_else(|| format!("No heading “{title}”."))?;
    let end = hs.iter().find(|(i, l, _)| *i > at && *l <= level).map(|(i, _, _)| *i).unwrap_or(lines.len());
    let mut out: Vec<String> = lines[..=at].iter().map(|s| s.to_string()).collect();
    out.push(String::new());
    out.extend(body.trim_end().lines().map(str::to_string));
    out.push(String::new());
    out.extend(lines[end..].iter().map(|s| s.to_string()));
    Ok(out.join("\n").trim_end().to_string() + "\n")
}

#[async_trait]
impl Engine for Document {
    fn name(&self) -> &'static str {
        "document"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let p = json!({"type": "string"});
        vec![
            ActionSpec::new("document", "outline", "The headings of a Markdown document.", json!({"type": "object", "properties": {"path": p}, "required": ["path"]}), Effect::Read),
            ActionSpec::new("document", "section", "Read the text under one heading.", json!({"type": "object", "properties": {"path": p, "heading": p}, "required": ["path", "heading"]}), Effect::Read),
            ActionSpec::new("document", "set_section", "Replace the text under one heading (the rest stays as it is).", json!({"type": "object", "properties": {"path": p, "heading": p, "text": p}, "required": ["path", "heading", "text"]}), Effect::Local),
            ActionSpec::new("document", "append", "Add text at the end, optionally under a new heading.", json!({"type": "object", "properties": {"path": p, "heading": p, "text": p}, "required": ["path", "text"]}), Effect::Local),
            ActionSpec::new("document", "convert", "Convert a document to another format: txt, html, rtf, doc, docx, odt (macOS textutil).", json!({"type": "object", "properties": {"path": p, "to": {"type": "string", "enum": ["txt", "html", "rtf", "doc", "docx", "odt"]}}, "required": ["path", "to"]}), Effect::Local),
        ]
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        let path = s(args, "path")?;
        let read = || std::fs::read_to_string(ctx.path(path)?).map_err(|e| e.to_string());
        match action {
            "outline" => Ok(json!(headings(&read()?).into_iter().map(|(_, l, t)| json!({"level": l, "title": t})).collect::<Vec<_>>())),
            "section" => {
                let text = read()?;
                let hs = headings(&text);
                let lines: Vec<&str> = text.lines().collect();
                let (at, level) = hs.iter().find(|(_, _, t)| t.eq_ignore_ascii_case(s(args, "heading").unwrap_or_default().trim())).map(|(i, l, _)| (*i, *l)).ok_or("No such heading.")?;
                let end = hs.iter().find(|(i, l, _)| *i > at && *l <= level).map(|(i, _, _)| *i).unwrap_or(lines.len());
                Ok(json!({"text": lines[at + 1..end].join("\n").trim().to_string()}))
            }
            "set_section" => {
                let out = set_section(&read()?, s(args, "heading")?, s(args, "text")?)?;
                std::fs::write(ctx.path(path)?, out).map_err(|e| e.to_string())?;
                Ok(json!({"updated": path}))
            }
            "append" => {
                let mut text = read().unwrap_or_default();
                if !text.is_empty() && !text.ends_with('\n') {
                    text.push('\n');
                }
                if let Some(h) = args["heading"].as_str() {
                    text.push_str(&format!("\n## {h}\n\n"));
                }
                text.push_str(s(args, "text")?.trim_end());
                text.push('\n');
                let p = ctx.path(path)?;
                if let Some(d) = p.parent() {
                    std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
                }
                std::fs::write(p, text).map_err(|e| e.to_string())?;
                Ok(json!({"updated": path}))
            }
            "convert" => {
                let tu = super::tool(&["textutil"]).ok_or("Converting documents needs textutil (macOS).")?;
                let to = s(args, "to")?;
                if !["txt", "html", "rtf", "doc", "docx", "odt"].contains(&to) {
                    return Err("txt, html, rtf, doc, docx or odt.".into());
                }
                let src = ctx.path(path)?;
                let out = src.with_extension(to);
                let rel_out = out.strip_prefix(&ctx.files).unwrap_or(&out).to_string_lossy().to_string();
                ctx.path(&rel_out)?;
                super::run(&tu, &["-convert", to, src.to_str().unwrap_or(""), "-output", out.to_str().unwrap_or("")], &ctx.files).await?;
                Ok(json!({"written": rel_out}))
            }
            other => Err(format!("The document engine has no action {other}.")),
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn one_section_changes_and_the_rest_stays() {
        let doc = "# Plan\n\nintro\n\n## Monday\n\nlegs\n\n## Tuesday\n\narms\n";
        let out = super::set_section(doc, "monday", "chest and back").unwrap();
        assert!(out.contains("## Monday\n\nchest and back\n\n## Tuesday\n\narms"));
        assert!(super::set_section(doc, "Sunday", "x").is_err());
    }
}
