//! Files the person gives an agent: any kind, read the way its kind reads.
//!
//! Every file is first kept in the agent's own folder (`attachments/`), so the
//! agent can keep working with the real file (its engines, its worlds). Then the
//! model is given what it can understand:
//!
//! - **a picture** as a picture (HEIC, TIFF and big ones are made into a JPEG
//!   it can read, at most 1,568 px across);
//! - **a PDF** as its text, and its first page as a picture;
//! - **Word, Pages, RTF, ODT** as text (macOS `textutil`);
//! - **text, code, CSV** as text;
//! - **a video** as a frame from it (Quick Look), its length and size;
//! - **a ZIP** as the list of what's in it, unpacked beside it (refused when it
//!   would unpack to more than 1 GB, and never outside its folder);
//! - **anything else** as its name, kind and size, the file kept for later.
//!
//! Everything the model reads from a file is untrusted, like any file.

use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use crate::runtime::Attachment;
use crate::{util, Team};

const TEXT_MAX: usize = 200_000;
/// The most a model takes in one picture (the harness checks the same number).
const IMAGE_MAX: usize = cookie_harness::message::MAX_IMAGE_BYTES;
/// Pictures bigger than this are made smaller first: past ~1568px a model sees no more
/// detail, and a smaller picture is read faster and costs less.
const IMAGE_AS_IS: usize = 1_500_000;
const UNZIP_MAX: u64 = 1 << 30;

#[derive(Debug, Clone, Copy, PartialEq)]
enum Kind {
    Image,
    Pdf,
    Document,
    Sheet,
    Text,
    Video,
    Audio,
    Zip,
    Other,
}

fn kind_of(name: &str) -> Kind {
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_lowercase()).unwrap_or_default();
    match ext.as_str() {
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "heic" | "heif" | "tif" | "tiff" | "bmp" => Kind::Image,
        "pdf" => Kind::Pdf,
        "doc" | "docx" | "rtf" | "odt" | "pages" | "rtfd" => Kind::Document,
        "xlsx" | "xls" | "numbers" | "ods" => Kind::Sheet,
        "mp4" | "mov" | "m4v" | "webm" | "avi" | "mkv" => Kind::Video,
        "mp3" | "m4a" | "wav" | "aac" | "flac" | "ogg" => Kind::Audio,
        "zip" => Kind::Zip,
        "txt" | "md" | "markdown" | "csv" | "tsv" | "json" | "log" | "html" | "htm" | "xml" | "yaml" | "yml" | "toml" | "rs" | "py" | "js" | "ts" | "tsx"
        | "jsx" | "swift" | "go" | "java" | "kt" | "c" | "h" | "cpp" | "hpp" | "css" | "scss" | "sql" | "sh" | "rb" | "php" | "ini" | "env" | "ics" | "vcf" => {
            Kind::Text
        }
        _ => Kind::Other,
    }
}

/// A name safe as a file name in the agent's folder.
fn safe_name(name: &str) -> String {
    let n: String = name.chars().map(|c| if c == '/' || c == '\\' || c == ':' || c.is_control() { '-' } else { c }).collect();
    let n = n.trim().trim_start_matches('.').to_string();
    if n.is_empty() { "file".into() } else { n.chars().take(120).collect() }
}

fn human(bytes: u64) -> String {
    match bytes {
        b if b >= 1 << 30 => format!("{:.1} GB", b as f64 / (1u64 << 30) as f64),
        b if b >= 1 << 20 => format!("{:.1} MB", b as f64 / (1u64 << 20) as f64),
        b if b >= 1 << 10 => format!("{} KB", b >> 10),
        b => format!("{b} bytes"),
    }
}

fn run(cmd: &str, args: &[&str]) -> Option<String> {
    let out = std::process::Command::new(cmd).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).to_string())
}

/// A picture the model can read: as it is when it already can, else a JPEG made with `sips`.
fn readable_image(path: &Path, tmp: &Path) -> Option<(String, Vec<u8>)> {
    let name = path.file_name()?.to_string_lossy().to_lowercase();
    let native = [("png", "image/png"), ("jpg", "image/jpeg"), ("jpeg", "image/jpeg"), ("gif", "image/gif"), ("webp", "image/webp")];
    let size = std::fs::metadata(path).ok()?.len() as usize;
    if let Some((_, mt)) = native.iter().find(|(e, _)| name.ends_with(&format!(".{e}"))) {
        if size <= IMAGE_AS_IS {
            return std::fs::read(path).ok().map(|b| (mt.to_string(), b));
        }
    }
    let out = tmp.join(format!("{}.jpg", util::random_hex(6)));
    run("/usr/bin/sips", &["-s", "format", "jpeg", "-s", "formatOptions", "80", "-Z", "1568", &path.to_string_lossy(), "--out", &out.to_string_lossy()])?;
    let b = std::fs::read(&out).ok();
    let _ = std::fs::remove_file(&out);
    b.filter(|b| b.len() <= IMAGE_MAX).map(|b| ("image/jpeg".to_string(), b))
}

/// A picture too big for a model, made small enough (1568px, JPEG): None when it can't be.
pub(crate) fn shrink_image(bytes: &[u8]) -> Option<(String, Vec<u8>)> {
    let tmp = std::env::temp_dir();
    let src = tmp.join(format!("cookie-shrink-{}.png", util::random_hex(6)));
    std::fs::write(&src, bytes).ok()?;
    let out = tmp.join(format!("{}.jpg", util::random_hex(6)));
    let r = run("/usr/bin/sips", &["-s", "format", "jpeg", "-s", "formatOptions", "80", "-Z", "1568", &src.to_string_lossy(), "--out", &out.to_string_lossy()])
        .and_then(|_| std::fs::read(&out).ok())
        .filter(|b| !b.is_empty() && b.len() <= IMAGE_MAX)
        .map(|b| ("image/jpeg".to_string(), b));
    let _ = std::fs::remove_file(&src);
    let _ = std::fs::remove_file(&out);
    r
}

/// A picture of a file (a PDF's first page, a video's frame) from Quick Look.
fn quick_look(path: &Path, tmp: &Path) -> Option<(String, Vec<u8>)> {
    let dir = tmp.join(util::random_hex(6));
    std::fs::create_dir_all(&dir).ok()?;
    run("/usr/bin/qlmanage", &["-t", "-s", "1280", "-o", &dir.to_string_lossy(), &path.to_string_lossy()]);
    let png = std::fs::read_dir(&dir).ok()?.flatten().map(|e| e.path()).find(|p| p.extension().is_some_and(|x| x == "png"));
    let r = png.and_then(|p| readable_image(&p, tmp));
    let _ = std::fs::remove_dir_all(&dir);
    r
}

/// Spotlight's facts about a media file: length and frame size.
fn media_facts(path: &Path) -> String {
    // A file just copied isn't in Spotlight yet: ffprobe reads the file itself when it's installed.
    if let Some(fp) = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].into_iter().find(|p| Path::new(p).exists()) {
        if let Some(out) = run(fp, &["-v", "error", "-show_entries", "format=duration:stream=width,height", "-of", "json", &path.to_string_lossy()]) {
            let v: Value = serde_json::from_str(&out).unwrap_or(Value::Null);
            let mut facts = Vec::new();
            if let Some(d) = v["format"]["duration"].as_str().and_then(|d| d.parse::<f64>().ok()) {
                facts.push(format!("{}:{:02} long", (d / 60.0) as u64, (d % 60.0) as u64));
            }
            if let Some(st) = v["streams"].as_array().and_then(|a| a.iter().find(|s| s["width"].is_u64())) {
                facts.push(format!("{}×{}", st["width"], st["height"]));
            }
            if !facts.is_empty() {
                return facts.join(", ");
            }
        }
    }
    let Some(out) = run("/usr/bin/mdls", &["-name", "kMDItemDurationSeconds", "-name", "kMDItemPixelWidth", "-name", "kMDItemPixelHeight", &path.to_string_lossy()]) else {
        return String::new();
    };
    let get = |k: &str| out.lines().find(|l| l.starts_with(k)).and_then(|l| l.split('=').nth(1)).map(|v| v.trim().to_string()).filter(|v| v != "(null)");
    let mut facts = Vec::new();
    if let Some(d) = get("kMDItemDurationSeconds").and_then(|d| d.parse::<f64>().ok()) {
        facts.push(format!("{}:{:02} long", (d / 60.0) as u64, (d % 60.0) as u64));
    }
    if let (Some(w), Some(h)) = (get("kMDItemPixelWidth"), get("kMDItemPixelHeight")) {
        facts.push(format!("{w}×{h}"));
    }
    facts.join(", ")
}

/// What's in a ZIP, and its total unpacked size, from `unzip -l`.
fn zip_listing(path: &Path) -> Option<(Vec<String>, u64)> {
    let out = run("/usr/bin/unzip", &["-l", &path.to_string_lossy()])?;
    let mut names = Vec::new();
    let mut total = 0u64;
    for l in out.lines() {
        let cols: Vec<&str> = l.split_whitespace().collect();
        if cols.len() >= 4 && cols[0].chars().all(|c| c.is_ascii_digit()) && cols[1].contains('-') {
            total += cols[0].parse::<u64>().unwrap_or(0);
            names.push(cols[3..].join(" "));
        }
    }
    Some((names, total))
}

/// One file, prepared: what the model reads, and a card for the chat.
pub struct Prepared {
    pub attachments: Vec<Attachment>,
    pub card: Value,
}

impl Team {
    fn attachments_dir(&self, agent: &str) -> PathBuf {
        self.paths.work(agent).join("attachments")
    }

    /// Keep a file in the agent's folder, under a name not taken yet.
    fn keep_file(&self, agent: &str, name: &str, from: Option<&Path>, bytes: Option<&[u8]>) -> Result<PathBuf, String> {
        let dir = self.attachments_dir(agent);
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let name = safe_name(name);
        let (stem, ext) = match name.rsplit_once('.') {
            Some((s, e)) if !s.is_empty() => (s.to_string(), format!(".{e}")),
            _ => (name.clone(), String::new()),
        };
        let mut to = dir.join(&name);
        let mut n = 2;
        while to.exists() {
            to = dir.join(format!("{stem} ({n}){ext}"));
            n += 1;
        }
        match (from, bytes) {
            // A clone on APFS: instant and free, however large.
            (Some(p), _) => {
                let ok = std::process::Command::new("/bin/cp").arg("-c").arg(p).arg(&to).status().is_ok_and(|s| s.success());
                if !ok {
                    std::fs::copy(p, &to).map_err(|e| format!("Couldn't copy {name}: {e}"))?;
                }
            }
            (None, Some(b)) => std::fs::write(&to, b).map_err(|e| e.to_string())?,
            _ => return Err("Nothing to keep.".into()),
        }
        Ok(to)
    }

    /// Prepare one kept file for the model.
    fn prepare(&self, agent: &str, kept: &Path) -> Prepared {
        let name = kept.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let rel = format!("attachments/{name}");
        let size = std::fs::metadata(kept).map(|m| m.len()).unwrap_or(0);
        let tmp = std::env::temp_dir();
        let kind = kind_of(&name);
        let note = |what: &str| format!("{name} — {what}, {}. Kept in your folder as {rel}.", human(size));
        let mut out: Vec<Attachment> = Vec::new();
        let mut thumb: Option<String> = None;
        let mut label = match kind {
            Kind::Image => "Image",
            Kind::Pdf => "PDF",
            Kind::Document => "Document",
            Kind::Sheet => "Spreadsheet",
            Kind::Text => "Text",
            Kind::Video => "Video",
            Kind::Audio => "Audio",
            Kind::Zip => "ZIP",
            Kind::Other => "File",
        }
        .to_string();
        let thumb_of = |mt: &str, b: &[u8]| {
            use base64::Engine;
            format!("data:{mt};base64,{}", base64::engine::general_purpose::STANDARD.encode(b))
        };
        match kind {
            Kind::Image => match readable_image(kept, &tmp) {
                Some((mt, b)) => {
                    thumb = Some(thumb_of(&mt, &b));
                    out.push(Attachment::image(&name, &mt, &b));
                }
                None => out.push(Attachment::text(&name, note("a picture that couldn't be read"))),
            },
            Kind::Pdf => {
                let (pages, text) = pdf_read(kept);
                label = match pages {
                    Some(n) => format!("PDF · {n} page{}", if n == 1 { "" } else { "s" }),
                    None => "PDF".into(),
                };
                out.push(Attachment::text(&name, format!("{}\n\n{}", note(&label), text.map(|t| t.chars().take(TEXT_MAX).collect::<String>()).unwrap_or_else(|| "(No text in it: it may be scanned pages; its first page is below.)".into()))));
                if let Some((mt, b)) = quick_look(kept, &tmp) {
                    thumb = Some(thumb_of(&mt, &b));
                    out.push(Attachment::image(format!("{name}, first page"), &mt, &b));
                }
            }
            Kind::Document => {
                let text = run("/usr/bin/textutil", &["-convert", "txt", "-stdout", &kept.to_string_lossy()]);
                out.push(Attachment::text(&name, format!("{}\n\n{}", note("a document"), text.map(|t| t.chars().take(TEXT_MAX).collect::<String>()).unwrap_or_else(|| "(Its text couldn't be read here.)".into()))));
                if let Some((mt, b)) = quick_look(kept, &tmp) {
                    thumb = Some(thumb_of(&mt, &b));
                }
            }
            Kind::Text => {
                let t = std::fs::read(kept).map(|b| String::from_utf8_lossy(&b).chars().take(TEXT_MAX).collect::<String>()).unwrap_or_default();
                out.push(Attachment::text(&name, t));
            }
            Kind::Sheet => {
                out.push(Attachment::text(&name, format!("{} Read it with the sheet engine in a world (parallax), or ask for it as CSV.", note("a spreadsheet"))));
                if let Some((mt, b)) = quick_look(kept, &tmp) {
                    thumb = Some(thumb_of(&mt, &b));
                    out.push(Attachment::image(format!("{name}, a preview"), &mt, &b));
                }
            }
            Kind::Video => {
                let facts = media_facts(kept);
                if !facts.is_empty() {
                    label = format!("Video · {facts}");
                }
                out.push(Attachment::text(&name, format!("{} A frame from it is below.", note(&label))));
                if let Some((mt, b)) = quick_look(kept, &tmp) {
                    thumb = Some(thumb_of(&mt, &b));
                    out.push(Attachment::image(format!("{name}, a frame"), &mt, &b));
                }
            }
            Kind::Audio => {
                let facts = media_facts(kept);
                if !facts.is_empty() {
                    label = format!("Audio · {facts}");
                }
                out.push(Attachment::text(&name, note(&label)));
            }
            Kind::Zip => match zip_listing(kept) {
                Some((names, total)) if total <= UNZIP_MAX => {
                    let into = kept.with_extension("");
                    let ok = std::process::Command::new("/usr/bin/ditto").args(["-x", "-k"]).arg(kept).arg(&into).status().is_ok_and(|s| s.success());
                    let rel_into = format!("attachments/{}", into.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default());
                    label = format!("ZIP · {} file{}", names.len(), if names.len() == 1 { "" } else { "s" });
                    let list: String = names.iter().take(300).map(|n| format!("- {n}\n")).collect();
                    out.push(Attachment::text(
                        &name,
                        format!("{}\n{}{}\n{list}", note(&format!("a ZIP of {} files, {} unpacked", names.len(), human(total))), if ok { format!("Unpacked into {rel_into}/.") } else { "It couldn't be unpacked.".into() }, if names.len() > 300 { " (first 300 shown)" } else { "" }),
                    ));
                }
                Some((_, total)) => out.push(Attachment::text(&name, note(&format!("a ZIP that would unpack to {}: too large to unpack here", human(total))))),
                None => out.push(Attachment::text(&name, note("a ZIP that couldn't be read"))),
            },
            Kind::Other => {
                let what = run("/usr/bin/file", &["-b", &kept.to_string_lossy()]).map(|s| s.trim().chars().take(120).collect::<String>()).unwrap_or_else(|| "a file".into());
                out.push(Attachment::text(&name, note(&what)));
            }
        }
        let _ = agent;
        Prepared { attachments: out, card: json!({"name": name, "label": label, "size": human(size), "path": rel, "thumb": thumb}) }
    }

    /// Files chosen in the picker: kept and prepared, one card each.
    pub async fn attach_paths(&self, agent: &str, paths: Vec<String>) -> Result<Value, String> {
        self.agent(agent).await?;
        let mut out = Vec::new();
        for p in paths.into_iter().take(20) {
            let path = PathBuf::from(&p);
            let name = path.file_name().map(|n| n.to_string_lossy().to_string()).ok_or("A file has no name.")?;
            if path.is_dir() {
                return Err(format!("{name} is a folder: zip it, or give it to your agents in Settings → Your files."));
            }
            let kept = self.keep_file(agent, &name, Some(&path), None)?;
            let p = tokio::task::block_in_place(|| self.prepare(agent, &kept));
            out.push(json!({"card": p.card, "attachments": p.attachments}));
        }
        Ok(json!(out))
    }

    /// A file dropped or pasted (its bytes): kept and prepared.
    pub async fn attach_bytes(&self, agent: &str, name: &str, data: &str) -> Result<Value, String> {
        use base64::Engine;
        self.agent(agent).await?;
        let bytes = base64::engine::general_purpose::STANDARD.decode(data.trim()).map_err(|_| "The file didn't arrive whole.".to_string())?;
        let kept = self.keep_file(agent, name, None, Some(&bytes))?;
        let p = tokio::task::block_in_place(|| self.prepare(agent, &kept));
        Ok(json!({"card": p.card, "attachments": p.attachments}))
    }
}

/// A PDF's page count and text (`lopdf`); no text when its pages are scans.
impl Team {
    fn me_photo_file(&self) -> PathBuf {
        self.paths.root.join("me.jpg")
    }

    /// The person's own photo, as a data URL, if they set one.
    pub fn me_photo(&self) -> Option<String> {
        use base64::Engine;
        std::fs::read(self.me_photo_file()).ok().map(|b| format!("data:image/jpeg;base64,{}", base64::engine::general_purpose::STANDARD.encode(b)))
    }

    /// Set the person's photo from a picked file (`path`) or its bytes (`data`, base64):
    /// made a square-ish 256-px JPEG, so any picture (HEIC too) works and it stays small.
    pub fn set_me_photo(&self, path: Option<String>, data: Option<String>) -> Result<Option<String>, String> {
        use base64::Engine;
        let tmp = std::env::temp_dir().join(format!("cookie-me-{}", util::random_hex(6)));
        let src = match (path, data) {
            (Some(p), _) => PathBuf::from(p),
            (None, Some(d)) => {
                let b = base64::engine::general_purpose::STANDARD.decode(d.trim()).map_err(|_| "The picture didn't arrive whole.".to_string())?;
                std::fs::write(&tmp, b).map_err(|e| e.to_string())?;
                tmp.clone()
            }
            _ => return Err("Choose a picture.".into()),
        };
        let out = tmp.with_extension("jpg");
        let made = run("/usr/bin/sips", &["-s", "format", "jpeg", "-s", "formatOptions", "85", "-Z", "256", &src.to_string_lossy(), "--out", &out.to_string_lossy()]).is_some();
        let _ = std::fs::remove_file(&tmp);
        if !made || !out.exists() {
            return Err("That isn't a picture Cookie can read: try a PNG, JPEG or HEIC.".into());
        }
        let r = std::fs::rename(&out, self.me_photo_file()).or_else(|_| std::fs::copy(&out, self.me_photo_file()).map(|_| ()));
        let _ = std::fs::remove_file(&out);
        r.map_err(|e| e.to_string())?;
        Ok(self.me_photo())
    }

    pub fn clear_me_photo(&self) -> bool {
        std::fs::remove_file(self.me_photo_file()).is_ok()
    }
}

fn pdf_read(path: &Path) -> (Option<usize>, Option<String>) {
    let Ok(doc) = lopdf::Document::load(path) else { return (None, None) };
    let pages: Vec<u32> = doc.get_pages().keys().copied().collect();
    let text = doc.extract_text(&pages).ok().map(|t| t.trim().to_string()).filter(|t| t.len() > 40);
    // Some fonts lopdf can't map; Poppler's pdftotext reads them when it's installed.
    let text = text.or_else(|| {
        let pt = ["/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext"].into_iter().find(|p| Path::new(p).exists())?;
        run(pt, &["-layout", &path.to_string_lossy(), "-"]).map(|t| t.trim().to_string()).filter(|t| t.len() > 40)
    });
    (Some(pages.len()), text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_names_and_sizes_read_as_people_expect() {
        assert_eq!(kind_of("Screenshot 2026.PNG"), Kind::Image);
        assert_eq!(kind_of("plan.pdf"), Kind::Pdf);
        assert_eq!(kind_of("CV.docx"), Kind::Document);
        assert_eq!(kind_of("clip.mov"), Kind::Video);
        assert_eq!(kind_of("site.zip"), Kind::Zip);
        assert_eq!(kind_of("data.csv"), Kind::Text);
        assert_eq!(kind_of("mystery.bin"), Kind::Other);
        assert_eq!(safe_name("../../etc/passwd"), "-..-etc-passwd");
        assert_eq!(safe_name(".hidden"), "hidden");
        assert_eq!(human(5 * 1024 * 1024), "5.0 MB");
    }

    #[test]
    fn your_photo_is_kept_small_and_only_pictures_are_taken() {
        use base64::Engine;
        let dir = std::env::temp_dir().join(format!("cookie-me-{}", util::random_hex(4)));
        let team = Team::open(&dir).unwrap();
        assert!(team.me_photo().is_none());
        assert!(team.set_me_photo(None, Some(base64::engine::general_purpose::STANDARD.encode("not a picture"))).is_err());
        // A 600x400 PNG made by sips itself.
        let png = dir.join("big.png");
        run("/usr/bin/sips", &["-s", "format", "png", "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericFolderIcon.icns", "--out", &png.to_string_lossy()]);
        if png.exists() {
            let url = team.set_me_photo(Some(png.to_string_lossy().to_string()), None).unwrap().unwrap();
            assert!(url.starts_with("data:image/jpeg;base64,"));
            assert!(std::fs::metadata(dir.join("me.jpg")).unwrap().len() < 100_000);
            assert!(team.clear_me_photo() && team.me_photo().is_none());
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_file_is_kept_in_the_agents_folder_and_never_overwrites_another() {
        let dir = std::env::temp_dir().join(format!("cookie-attach-{}", util::random_hex(4)));
        let team = Team::open(&dir).unwrap();
        let rec = team
            .add_agent(crate::AgentRecord {
                id: "a".into(), name: "A".into(), model: "anthropic:x".into(), job: "j".into(), created_at: 0,
                grants: Default::default(), limits: Default::default(), probation_until: None, parent: None, shadow_of: None, handover: None, origin: None, version: 1,
            })
            .await
            .unwrap();
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD.encode("name,reps\nsquat,12\n");
        let one = team.attach_bytes(&rec.id, "log.csv", &b64).await.unwrap();
        let two = team.attach_bytes(&rec.id, "log.csv", &b64).await.unwrap();
        assert_eq!(one["card"]["path"], "attachments/log.csv");
        assert_eq!(two["card"]["path"], "attachments/log (2).csv", "a second file never replaces the first");
        assert!(one["attachments"][0]["text"].as_str().unwrap().contains("squat,12"));
        assert!(team.attach_bytes(&rec.id, "x.txt", "not base64!!").await.is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
