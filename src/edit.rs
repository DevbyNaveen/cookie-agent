//! `edit_file`: change part of a text file by exact replacement, instead of
//! writing the whole file again. The model names the text it saw and the text
//! to put there; the edit lands only if that text is in the file exactly once
//! (or everywhere, when it says so), so an edit made from a stale read fails
//! loudly instead of landing in the wrong place.
//!
//! Several edits in one call are applied in order, all or nothing, and the
//! file is replaced in one rename: a reader never sees half an edit.

use std::path::{Component, Path, PathBuf};

use serde_json::{json, Value};

use crate::tool::{tool, Effect, Tool};

/// The largest file this edits. Bigger files are rarely text a model should
/// be changing in place.
pub const MAX_BYTES: usize = 8_000_000;

/// One replacement.
#[derive(Debug, Clone, PartialEq)]
pub struct Edit {
    pub old: String,
    pub new: String,
    pub all: bool,
}

/// What an applied set of edits did: the new text and, per edit, the first
/// line it changed.
#[derive(Debug)]
pub struct Applied {
    pub text: String,
    pub lines: Vec<(usize, usize)>,
}

/// Applies `edits` to `text` in order. Each edit's old text must be in the
/// text as it stands after the edits before it.
pub fn apply(text: &str, edits: &[Edit]) -> Result<Applied, String> {
    if edits.is_empty() {
        return Err("Give at least one edit.".into());
    }
    let mut text = text.to_string();
    let mut lines = Vec::new();
    for (i, e) in edits.iter().enumerate() {
        let which = if edits.len() > 1 { format!("Edit {}: ", i + 1) } else { String::new() };
        if e.old.is_empty() {
            return Err(format!("{which}`old_text` is empty. To make a new file, write it instead."));
        }
        if e.old == e.new {
            return Err(format!("{which}`old_text` and `new_text` are the same."));
        }
        // A file saved with Windows line ends still matches text the model
        // copied with plain ones.
        let (old, new) = if !text.contains(&e.old) && text.contains("\r\n") && !e.old.contains("\r\n") {
            (e.old.replace('\n', "\r\n"), e.new.replace('\n', "\r\n"))
        } else {
            (e.old.clone(), e.new.clone())
        };
        let at: Vec<usize> = text.match_indices(&old).map(|(at, _)| at).collect();
        let line_of = |byte: usize| text[..byte].matches('\n').count() + 1;
        match at.len() {
            0 => return Err(format!("{which}that text isn't in the file{}. Read the file again and copy the text exactly.", near(&text, &e.old))),
            n if n > 1 && !e.all => {
                let at_lines: Vec<String> = at.iter().take(8).map(|b| line_of(*b).to_string()).collect();
                return Err(format!(
                    "{which}that text is in the file {n} times (lines {}). Include more of the lines around it so it is found once, or set replace_all.",
                    at_lines.join(", ")
                ));
            }
            n => {
                lines.push((line_of(at[0]), n));
                text = if e.all { text.replace(&old, &new) } else { text.replacen(&old, &new, 1) };
            }
        }
    }
    Ok(Applied { text, lines })
}

/// When old text is missing, the line in the file most like its first line,
/// so the model can see what it got wrong (often only the indentation).
fn near(text: &str, old: &str) -> String {
    let first = old.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
    if first.is_empty() {
        return String::new();
    }
    text.lines()
        .enumerate()
        .find(|(_, l)| l.trim() == first)
        .map(|(i, l)| format!(" (line {} has `{}`: check the spaces and the lines around it)", i + 1, l.trim_end()))
        .unwrap_or_default()
}

/// A path inside `root` that already exists, refusing `..`, absolute paths
/// and links that lead out.
pub fn existing_inside(root: &Path, rel: &str) -> Result<PathBuf, String> {
    let rel = Path::new(rel.trim());
    if rel.as_os_str().is_empty() || rel.is_absolute() || rel.components().any(|c| matches!(c, Component::ParentDir | Component::Prefix(_))) {
        return Err("Give a path inside the folder, like `notes/plan.md`.".into());
    }
    let root = root.canonicalize().map_err(|e| format!("the folder can't be read: {e}"))?;
    let path = root.join(rel).canonicalize().map_err(|_| format!("`{}` doesn't exist. To make a new file, write it.", rel.display()))?;
    if !path.starts_with(&root) {
        return Err("That path leads outside the folder.".into());
    }
    Ok(path)
}

/// Reads, edits and replaces one file. Returns what changed, for the model.
pub fn edit_file(root: &Path, rel: &str, edits: &[Edit]) -> Result<String, String> {
    let path = existing_inside(root, rel)?;
    if path.is_dir() {
        return Err(format!("`{rel}` is a folder."));
    }
    let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
    if bytes.len() > MAX_BYTES {
        return Err("That file is too large to edit in place.".into());
    }
    let text = String::from_utf8(bytes).map_err(|_| format!("`{rel}` isn't UTF-8 text."))?;
    let applied = apply(&text, edits)?;
    write_atomically(&path, applied.text.as_bytes())?;
    let said: Vec<String> = applied
        .lines
        .iter()
        .map(|(line, n)| if *n > 1 { format!("{n} places from line {line}") } else { format!("line {line}") })
        .collect();
    Ok(format!("Edited {rel}: {} ({} → {} bytes).", said.join("; "), text.len(), applied.text.len()))
}

/// Writes next to the file and renames over it, keeping its permissions.
fn write_atomically(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let dir = path.parent().ok_or("the file has no folder")?;
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let tmp = dir.join(format!(".{name}.cookie-edit-{}", std::process::id()));
    std::fs::write(&tmp, bytes).map_err(|e| e.to_string())?;
    if let Ok(meta) = std::fs::metadata(path) {
        let _ = std::fs::set_permissions(&tmp, meta.permissions());
    }
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        e.to_string()
    })
}

/// The edits a call asks for: one (`old_text`, `new_text`) or a list in `edits`.
pub fn edits_of(args: &Value) -> Result<Vec<Edit>, String> {
    let one = |v: &Value| -> Result<Edit, String> {
        Ok(Edit {
            old: v["old_text"].as_str().ok_or("Each edit needs `old_text`.")?.to_string(),
            new: v["new_text"].as_str().ok_or("Each edit needs `new_text`.")?.to_string(),
            all: v["replace_all"].as_bool().unwrap_or(false),
        })
    };
    match args["edits"].as_array() {
        Some(list) if !list.is_empty() => list.iter().map(one).collect(),
        _ => Ok(vec![one(args)?]),
    }
}

/// The `edit_file` tool, scoped to `root`.
pub fn tool_for(root: PathBuf) -> impl Tool {
    tool(
        "edit_file",
        "Change part of a text file in your folder by exact replacement: `old_text` is text now in the file (copy it exactly, \
         with enough lines around it to be found once) and `new_text` replaces it. For several changes to one file, give \
         `edits` instead; they apply in order, all or none. Set replace_all to change every place. Faster and safer than \
         writing the whole file again.",
        json!({"type": "object", "properties": {
            "path": {"type": "string", "description": "relative path, e.g. drafts/plan.md"},
            "old_text": {"type": "string"},
            "new_text": {"type": "string"},
            "replace_all": {"type": "boolean"},
            "edits": {"type": "array", "items": {"type": "object", "properties": {
                "old_text": {"type": "string"}, "new_text": {"type": "string"}, "replace_all": {"type": "boolean"}
            }, "required": ["old_text", "new_text"]}}
        }, "required": ["path"]}),
        Effect::Write,
        move |args: Value| {
            let root = root.clone();
            async move {
                let rel = args["path"].as_str().unwrap_or_default().to_string();
                let edits = edits_of(&args)?;
                tokio::task::spawn_blocking(move || edit_file(&root, &rel, &edits)).await.map_err(|e| e.to_string())?
            }
        },
    )
    .with_preview(|args| {
        let edits = edits_of(args).unwrap_or_default();
        let mut out = format!("Edit {}:", args["path"].as_str().unwrap_or("?"));
        for e in edits.iter().take(5) {
            let clip = |s: &str| s.chars().take(600).collect::<String>();
            out.push_str(&format!("\n- {}\n+ {}", clip(&e.old).replace('\n', "\n- "), clip(&e.new).replace('\n', "\n+ ")));
        }
        out
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e(old: &str, new: &str) -> Edit {
        Edit { old: old.into(), new: new.into(), all: false }
    }

    #[test]
    fn an_edit_lands_only_where_its_text_is_found_once() {
        let out = apply("a\nb\nc\n", &[e("b", "B")]).unwrap();
        assert_eq!(out.text, "a\nB\nc\n");
        assert_eq!(out.lines, vec![(2, 1)]);
        let twice = apply("x\nx\n", &[e("x", "y")]).unwrap_err();
        assert!(twice.contains("2 times") && twice.contains("lines 1, 2"), "{twice}");
        let all = apply("x\nx\n", &[Edit { all: true, ..e("x", "y") }]).unwrap();
        assert_eq!(all.text, "y\ny\n");
    }

    #[test]
    fn a_missing_text_points_at_the_line_that_looks_like_it() {
        let err = apply("fn main() {\n    run();\n}\n", &[e("\trun();", "\tgo();")]).unwrap_err();
        assert!(err.contains("line 2"), "{err}");
    }

    #[test]
    fn several_edits_are_all_or_nothing() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("f.txt"), "one two three").unwrap();
        let bad = edit_file(dir.path(), "f.txt", &[e("one", "1"), e("four", "4")]).unwrap_err();
        assert!(bad.starts_with("Edit 2:"), "{bad}");
        assert_eq!(std::fs::read_to_string(dir.path().join("f.txt")).unwrap(), "one two three", "nothing landed");
        edit_file(dir.path(), "f.txt", &[e("one", "1"), e("1 two", "1 2")]).unwrap();
        assert_eq!(std::fs::read_to_string(dir.path().join("f.txt")).unwrap(), "1 2 three", "each edit sees the one before");
    }

    #[test]
    fn windows_line_ends_still_match() {
        assert_eq!(apply("a\r\nb\r\n", &[e("a\nb", "c\nd")]).unwrap().text, "c\r\nd\r\n");
    }

    #[test]
    fn it_stays_inside_its_folder() {
        let dir = tempfile::tempdir().unwrap();
        assert!(edit_file(dir.path(), "../etc/passwd", &[e("a", "b")]).is_err());
        assert!(edit_file(dir.path(), "/etc/passwd", &[e("a", "b")]).is_err());
        assert!(edit_file(dir.path(), "new.txt", &[e("a", "b")]).unwrap_err().contains("doesn't exist"));
    }

    #[test]
    fn one_edit_or_a_list() {
        assert_eq!(edits_of(&json!({"old_text": "a", "new_text": "b"})).unwrap(), vec![e("a", "b")]);
        assert_eq!(edits_of(&json!({"edits": [{"old_text": "a", "new_text": "b"}, {"old_text": "c", "new_text": "d", "replace_all": true}]})).unwrap().len(), 2);
        assert!(edits_of(&json!({"path": "x"})).is_err());
    }
}
