//! Files an agent shows in its chat: an image, a recording, a video, a PDF or a
//! sheet it made or found, shown inline or as a card to open.
//!
//! A file is shown only from where the agent itself may read: its own folder,
//! or (with Files on) the folders the person gave it in Settings → Your files,
//! never where secrets and private messages are kept (`access::resolve`).
//! Media comes back as data up to a size, so the page never reaches the disk
//! itself; anything larger is a card. Opening a file in its app is for
//! documents and media only, never something that runs.

use std::path::{Path, PathBuf};

use base64::Engine as _;
use serde_json::{json, Value};

use crate::Team;

/// The most each kind comes back inline as data.
const IMAGE_MAX: u64 = 15 * 1024 * 1024;
const AUDIO_MAX: u64 = 25 * 1024 * 1024;
const VIDEO_MAX: u64 = 40 * 1024 * 1024;

/// What a file is, by its extension: `(kind, media type)`.
pub fn kind_of(path: &Path) -> (&'static str, &'static str) {
    let ext = path.extension().map(|e| e.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
    match ext.as_str() {
        "png" => ("image", "image/png"),
        "jpg" | "jpeg" => ("image", "image/jpeg"),
        "gif" => ("image", "image/gif"),
        "webp" => ("image", "image/webp"),
        // An SVG shown as an image runs none of its scripts.
        "svg" => ("image", "image/svg+xml"),
        "mp4" | "m4v" => ("video", "video/mp4"),
        "webm" => ("video", "video/webm"),
        "mov" => ("video", "video/quicktime"),
        "mp3" => ("audio", "audio/mpeg"),
        "m4a" | "aac" => ("audio", "audio/mp4"),
        "wav" => ("audio", "audio/wav"),
        "ogg" | "oga" => ("audio", "audio/ogg"),
        "flac" => ("audio", "audio/flac"),
        "pdf" => ("pdf", "application/pdf"),
        "csv" | "tsv" | "xlsx" | "xls" | "numbers" => ("sheet", "application/octet-stream"),
        "doc" | "docx" | "pages" | "rtf" | "odt" => ("document", "application/octet-stream"),
        "ppt" | "pptx" | "key" => ("slides", "application/octet-stream"),
        "txt" | "md" | "json" | "yaml" | "yml" | "toml" | "log" | "html" | "htm" | "xml" | "ics" => ("text", "text/plain"),
        "zip" | "tar" | "gz" | "tgz" => ("archive", "application/octet-stream"),
        _ => ("other", "application/octet-stream"),
    }
}

/// A document a person reads in the chat's viewer: Markdown, a web page, a PDF.
pub fn is_document(path: &Path) -> bool {
    let ext = path.extension().map(|e| e.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
    matches!(ext.as_str(), "md" | "markdown" | "html" | "htm" | "pdf")
}

/// The most text, and the largest PDF, the viewer reads.
const DOC_TEXT_MAX: u64 = 2 * 1024 * 1024;
const PDF_MAX: u64 = 25 * 1024 * 1024;

/// Documents in `root` written at or after `since` (seconds), newest first: what a job made.
/// Bounded: a few levels deep, the first thousand files, never a hidden folder or Cookie's own copies.
pub fn documents_since(root: &Path, since: u64) -> Vec<PathBuf> {
    fn walk(dir: &Path, depth: usize, seen: &mut usize, since: u64, out: &mut Vec<(u64, PathBuf)>) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            *seen += 1;
            if *seen > 1000 {
                return;
            }
            let p = e.path();
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with('.') || matches!(name.as_str(), "node_modules" | "checkpoints" | "target") {
                continue;
            }
            let Ok(meta) = e.metadata() else { continue };
            if meta.is_dir() {
                if depth < 4 {
                    walk(&p, depth + 1, seen, since, out);
                }
            } else if is_document(&p) {
                let at = meta.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
                if at >= since {
                    out.push((at, p));
                }
            }
        }
    }
    let mut out = Vec::new();
    walk(root, 0, &mut 0, since, &mut out);
    out.sort_by(|a, b| b.0.cmp(&a.0));
    out.into_iter().map(|(_, p)| p).take(6).collect()
}

/// Kinds a click may open in their app: documents and media. Never an app, a script, an installer.
pub fn openable(path: &Path) -> bool {
    !matches!(kind_of(path).0, "other" | "archive")
}

impl Team {
    /// Where a file the agent named really is, if it may be shown: its own folder, or the person's
    /// folders when it has Files. `path` may be relative to its folder, absolute, `~/…` or `file://…`.
    pub fn chat_file_path(&self, agent: &str, path: &str) -> Result<PathBuf, String> {
        let raw = path.trim();
        let raw = raw.strip_prefix("file://").unwrap_or(raw).replace("%20", " ");
        if raw.is_empty() {
            return Err("No file named.".into());
        }
        let work = self.paths.work(agent);
        let work = work.canonicalize().unwrap_or(work);
        let p = Path::new(&raw);
        if !p.is_absolute() && !raw.starts_with('~') {
            let inside = crate::util::inside(&work, &raw).ok_or("That file isn't in its folder.")?;
            return inside.canonicalize().map_err(|_| format!("{raw} isn't there."));
        }
        let real = crate::access::expand(&raw).canonicalize().map_err(|_| format!("{raw} isn't there."))?;
        if real.starts_with(&work) {
            return Ok(real);
        }
        let grants = self.agents.try_read().ok().and_then(|a| a.iter().find(|r| r.id == agent).map(|r| r.grants.files)).unwrap_or(false);
        if !grants {
            return Err("That file is outside its folder.".into());
        }
        self.access().resolve(&raw, true)
    }

    /// A file for the chat: its name, size and kind, and for media small enough, its data.
    pub fn chat_file(&self, agent: &str, path: &str) -> Result<Value, String> {
        let real = self.chat_file_path(agent, path)?;
        let meta = std::fs::metadata(&real).map_err(|e| e.to_string())?;
        if !meta.is_file() {
            return Err("That's a folder, not a file.".into());
        }
        let (kind, media_type) = kind_of(&real);
        let cap = match kind {
            "image" => IMAGE_MAX,
            "audio" => AUDIO_MAX,
            "video" => VIDEO_MAX,
            _ => 0,
        };
        let data = (cap > 0 && meta.len() <= cap).then(|| std::fs::read(&real).ok()).flatten().map(|b| base64::engine::general_purpose::STANDARD.encode(b));
        // A document for the viewer: its text, or a PDF's bytes.
        let doc = is_document(&real);
        let pdf = kind == "pdf";
        let text = (doc && !pdf && meta.len() <= DOC_TEXT_MAX).then(|| std::fs::read_to_string(&real).ok()).flatten();
        let data = if doc && pdf && meta.len() <= PDF_MAX { std::fs::read(&real).ok().map(|b| base64::engine::general_purpose::STANDARD.encode(b)) } else { data };
        Ok(json!({
            "name": real.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
            "path": real.to_string_lossy(),
            "size": meta.len(),
            "kind": kind,
            "media_type": media_type,
            "openable": openable(&real),
            "document": doc,
            "text": text,
            "data": data,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_come_from_the_extension() {
        assert_eq!(kind_of(Path::new("a/chart.PNG")), ("image", "image/png"));
        assert_eq!(kind_of(Path::new("talk.m4a")), ("audio", "audio/mp4"));
        assert_eq!(kind_of(Path::new("demo.mov")).0, "video");
        assert_eq!(kind_of(Path::new("q3.xlsx")).0, "sheet");
        assert_eq!(kind_of(Path::new("run")).0, "other");
    }

    #[test]
    fn only_documents_and_media_open_in_their_app() {
        for ok in ["r.pdf", "c.png", "s.xlsx", "n.md", "v.mp4"] {
            assert!(openable(Path::new(ok)), "{ok}");
        }
        for no in ["evil.command", "x.sh", "y.app", "z.pkg", "a.zip", "w.workflow", "noext"] {
            assert!(!openable(Path::new(no)), "{no} must never open from a chat");
        }
    }
    #[tokio::test]
    async fn a_file_is_shown_only_from_where_the_agent_may_read() {
        let dir = std::env::temp_dir().join(format!("cookie-chatfiles-{}", crate::util::random_hex(4)));
        let team = Team::open(&dir).unwrap();
        let work = team.paths.work("a");
        std::fs::create_dir_all(work.join("out")).unwrap();
        std::fs::write(work.join("out/chart.png"), b"\x89PNG").unwrap();
        std::fs::write(dir.join("secret.txt"), b"keys").unwrap();
        assert!(team.chat_file_path("a", "out/chart.png").is_ok());
        let abs = work.join("out/chart.png").to_string_lossy().to_string();
        assert!(team.chat_file_path("a", &abs).is_ok());
        assert!(team.chat_file_path("a", &format!("file://{abs}")).is_ok());
        assert!(team.chat_file_path("a", "../../secret.txt").is_err(), "never climbs out of its folder");
        assert!(team.chat_file_path("a", &dir.join("secret.txt").to_string_lossy()).is_err(), "an unknown agent has no Files to reach further");
        assert!(team.chat_file_path("a", "out/missing.png").is_err());
        let f = team.chat_file("a", "out/chart.png").unwrap();
        assert_eq!((f["kind"].as_str(), f["size"].as_u64()), (Some("image"), Some(4)));
        assert!(f["data"].as_str().is_some(), "a small image comes back as data");
        let _ = std::fs::remove_dir_all(&dir);
    }
    #[test]
    fn a_job_s_documents_are_what_it_wrote_since_it_began() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("reports/q3")).unwrap();
        std::fs::create_dir_all(root.join(".hidden")).unwrap();
        for f in ["reports/q3/summary.md", "page.html", "deck.pdf", "notes.txt", ".hidden/secret.md"] {
            std::fs::write(root.join(f), "x").unwrap();
        }
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
        let mut got: Vec<String> = documents_since(root, now - 5).iter().map(|p| p.strip_prefix(root).unwrap().to_string_lossy().into_owned()).collect();
        got.sort();
        assert_eq!(got, ["deck.pdf", "page.html", "reports/q3/summary.md"], "documents only, never a hidden folder");
        assert!(documents_since(root, now + 60).is_empty(), "nothing written since then");
    }
}
