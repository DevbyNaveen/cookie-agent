//! The engines: the brains of everyday software, without screens.
//!
//! files · sheet · document · pdf · image · video · data · browser · web ·
//! blocks (the building blocks agents' own software is made of: tracker,
//! board, calendar, chart, form). Each uses what the machine already has
//! where it can (`sips` for images, `ffmpeg` for video, `sqlite3` for data,
//! `pdftotext` and `textutil` for documents, Chrome for the browser) and says
//! plainly when something is missing rather than pretending.

pub mod blocks;
pub mod browser;
pub mod data;
pub mod document;
pub mod files;
pub mod image;
pub mod pdf;
pub mod sheet;
pub mod video;
pub mod web;

use std::sync::Arc;

use crate::engine::Registry;

pub fn register_all(r: &mut Registry) {
    r.register("files", || Arc::new(files::Files));
    r.register("sheet", || Arc::new(sheet::Sheet));
    r.register("document", || Arc::new(document::Document));
    r.register("pdf", || Arc::new(pdf::Pdf));
    r.register("image", || Arc::new(image::Image));
    r.register("video", || Arc::new(video::Video));
    r.register("data", || Arc::new(data::Data));
    r.register("browser", || Arc::new(browser::Browser::default()));
    r.register("web", || Arc::new(web::Web));
    r.register("blocks", || Arc::new(blocks::Blocks));
    r.register("app", || Arc::new(crate::preview::App));
    r.register("hosting", || Arc::new(crate::preview::Hosting));
}

/// A program found where it is usually installed, never on an arbitrary PATH.
pub(crate) fn tool(names: &[&str]) -> Option<String> {
    for n in names {
        for dir in ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin", "/bin"] {
            let p = format!("{dir}/{n}");
            if std::path::Path::new(&p).exists() {
                return Some(p);
            }
        }
    }
    None
}

/// Run a program with arguments (no shell), its output or why it failed.
pub(crate) async fn run(program: &str, args: &[&str], cwd: &std::path::Path) -> Result<String, String> {
    let out = tokio::time::timeout(std::time::Duration::from_secs(300), tokio::process::Command::new(program).args(args).current_dir(cwd).stdin(std::process::Stdio::null()).output())
        .await
        .map_err(|_| format!("{program} took longer than five minutes."))?
        .map_err(|e| format!("{program}: {e}"))?;
    if !out.status.success() {
        return Err(format!("{}: {}", program.rsplit('/').next().unwrap_or(program), String::from_utf8_lossy(&out.stderr).trim().chars().take(600).collect::<String>()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}
