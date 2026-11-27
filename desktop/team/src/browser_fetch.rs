//! The browser Cookie gets for itself when the computer has none.
//!
//! Agents use an installed Chrome, Chromium, Brave or Edge when there is one.
//! When there is none, Cookie downloads **Chrome for Testing** from Google's own
//! server the first time a browser is needed, and keeps it in its data folder
//! (`browser-runtime/<version>`), outside the app.
//!
//! - **One pinned build.** The version and the SHA-256 of each platform's
//!   archive are fixed below. A download that doesn't match, byte for byte, is
//!   deleted and never run. Google signs these builds ad hoc (no Developer ID
//!   to check), so the pinned hash is what says the file is the one we chose.
//! - **A newer browser arrives with a newer Cookie**: the pin moves in a release.
//! - **Nothing is bundled.** The archive is about 200 MB and is fetched once.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use futures::StreamExt;
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;

/// The pinned build. Move all of these together.
pub const VERSION: &str = "158.0.8127.88";
/// Platform, SHA-256 of `chrome-<platform>.zip`, its size in bytes.
const BUILDS: &[(&str, &str, u64)] = &[
    ("mac-arm64", "6caf16b007aafaf6d4a4db252262be8ebbf0d91a2af005257e388996dbe463d6", 200_337_306),
    ("mac-x64", "4529a2bdbea10cf69f79b8b0ff43a5a23e8dc8b033da85cbe873afb81855579a", 213_548_436),
    ("linux64", "59e3b43f8b3aaa292238fbdcfb36a93127debd53e212510dcdc2cc8812b4b57e", 208_082_347),
    ("linux-arm64", "91669b5de79af808d498037dd974e4b09461776a1b5240b3bb656abd17e5d3ab", 205_794_810),
    ("win64", "fda73ca9ffc7f02c5c85165cb472152540a76a7cecd8ec11314ea781e4454109", 214_931_627),
];

/// Bytes fetched so far and the archive's size, while a download runs (0, 0 otherwise).
static DONE: AtomicU64 = AtomicU64::new(0);
static TOTAL: AtomicU64 = AtomicU64::new(0);
/// One download at a time.
static FETCHING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Google's name for this computer's build, when there is one.
pub fn platform() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => Some("mac-arm64"),
        ("macos", "x86_64") => Some("mac-x64"),
        ("linux", "x86_64") => Some("linux64"),
        ("linux", "aarch64") => Some("linux-arm64"),
        ("windows", "x86_64") => Some("win64"),
        _ => None,
    }
}

fn build(platform: &str) -> Option<(&'static str, &'static str, u64)> {
    BUILDS.iter().copied().find(|(p, ..)| *p == platform)
}

fn url(platform: &str) -> String {
    format!("https://storage.googleapis.com/chrome-for-testing-public/{VERSION}/{platform}/chrome-{platform}.zip")
}

/// Where the program is inside the unpacked archive.
fn program(dir: &Path, platform: &str) -> PathBuf {
    let top = dir.join(format!("chrome-{platform}"));
    if platform.starts_with("mac") {
        top.join("Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing")
    } else if platform.starts_with("win") {
        top.join("chrome.exe")
    } else {
        top.join("chrome")
    }
}

/// The fetched browser, when a whole, checked copy of the pinned build is there.
pub fn fetched(root: &Path) -> Option<PathBuf> {
    let p = program(&root.join(VERSION), platform()?);
    p.exists().then_some(p)
}

/// `(bytes so far, of bytes)` while a download runs.
pub fn progress() -> Option<(u64, u64)> {
    let total = TOTAL.load(Ordering::Relaxed);
    (total > 0).then(|| (DONE.load(Ordering::Relaxed), total))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Download the pinned build into `root`, check it, unpack it; the program's path.
pub async fn fetch(root: &Path) -> Result<PathBuf, String> {
    let _one = FETCHING.lock().await;
    if let Some(p) = fetched(root) {
        return Ok(p);
    }
    let platform = platform().ok_or("Cookie has no browser to download for this kind of computer. Install Chrome, Chromium, Brave or Edge.")?;
    let (_, sha, size) = build(platform).ok_or("No pinned browser for this computer.")?;
    std::fs::create_dir_all(root).map_err(|e| format!("Couldn't make the browser folder: {e}"))?;
    let zip = root.join(format!("{VERSION}.zip.part"));
    let res = download(&url(platform), &zip, sha, size).await;
    TOTAL.store(0, Ordering::Relaxed);
    DONE.store(0, Ordering::Relaxed);
    if let Err(e) = res {
        let _ = std::fs::remove_file(&zip);
        return Err(e);
    }
    // Unpack beside the final place, then move it in whole: a crash leaves no half browser.
    let tmp = root.join(format!("{VERSION}.unpacking"));
    let _ = std::fs::remove_dir_all(&tmp);
    let unpacked = unpack(&zip, &tmp).await;
    let _ = std::fs::remove_file(&zip);
    unpacked?;
    if !program(&tmp, platform).exists() {
        let _ = std::fs::remove_dir_all(&tmp);
        return Err("The downloaded browser isn't laid out as expected, so it wasn't kept.".into());
    }
    let dest = root.join(VERSION);
    let _ = std::fs::remove_dir_all(&dest);
    std::fs::rename(&tmp, &dest).map_err(|e| format!("Couldn't keep the browser: {e}"))?;
    // Older pinned builds are no longer used.
    for e in std::fs::read_dir(root).into_iter().flatten().flatten() {
        if e.file_name() != std::ffi::OsStr::new(VERSION) {
            let p = e.path();
            let _ = if p.is_dir() { std::fs::remove_dir_all(&p) } else { std::fs::remove_file(&p) };
        }
    }
    fetched(root).ok_or_else(|| "The browser was downloaded but can't be found.".into())
}

/// Stream `url` into `to`, refusing anything that isn't exactly the pinned file.
async fn download(url: &str, to: &Path, sha: &str, size: u64) -> Result<(), String> {
    let client = reqwest::Client::builder().connect_timeout(Duration::from_secs(20)).user_agent("cookie-desktop").build().map_err(|e| e.to_string())?;
    let resp = client.get(url).send().await.map_err(|e| format!("Couldn't reach Google's download server: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("Google's download server answered {} for the browser.", resp.status().as_u16()));
    }
    TOTAL.store(size, Ordering::Relaxed);
    DONE.store(0, Ordering::Relaxed);
    let mut file = tokio::fs::File::create(to).await.map_err(|e| format!("Couldn't save the browser: {e}"))?;
    let mut hash = Sha256::new();
    let mut got: u64 = 0;
    let mut body = resp.bytes_stream();
    while let Some(chunk) = tokio::time::timeout(Duration::from_secs(60), body.next()).await.map_err(|_| "The browser download stalled.".to_string())? {
        let chunk = chunk.map_err(|e| format!("The browser download broke off: {e}"))?;
        got += chunk.len() as u64;
        if got > size {
            return Err("The download is larger than the browser Cookie expects, so it was thrown away.".into());
        }
        hash.update(&chunk);
        file.write_all(&chunk).await.map_err(|e| format!("Couldn't save the browser (is the disk full?): {e}"))?;
        DONE.store(got, Ordering::Relaxed);
    }
    file.flush().await.map_err(|e| e.to_string())?;
    check(got, &hex(&hash.finalize()), size, sha)
}

/// The downloaded file is the pinned one, or it is refused.
fn check(got: u64, got_sha: &str, size: u64, sha: &str) -> Result<(), String> {
    if got != size || !got_sha.eq_ignore_ascii_case(sha) {
        return Err("The downloaded browser doesn't match the one Cookie expects, so it was thrown away and not run. Try again, or install Chrome yourself.".into());
    }
    Ok(())
}

/// Unpack with the system's own tool, which keeps a Mac app's links and permissions.
async fn unpack(zip: &Path, into: &Path) -> Result<(), String> {
    std::fs::create_dir_all(into).map_err(|e| e.to_string())?;
    let mut cmd = if cfg!(target_os = "macos") {
        let mut c = tokio::process::Command::new("/usr/bin/ditto");
        c.arg("-x").arg("-k").arg(zip).arg(into);
        c
    } else if cfg!(target_os = "windows") {
        let mut c = tokio::process::Command::new("tar");
        c.arg("-xf").arg(zip).arg("-C").arg(into);
        c
    } else {
        let mut c = tokio::process::Command::new("unzip");
        c.arg("-q").arg(zip).arg("-d").arg(into);
        c
    };
    let out = cmd.stdin(std::process::Stdio::null()).output().await.map_err(|e| format!("Couldn't unpack the browser: {e}"))?;
    if !out.status.success() {
        let _ = std::fs::remove_dir_all(into);
        return Err(format!("Couldn't unpack the browser: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_platform_has_a_whole_pin() {
        for (p, sha, size) in BUILDS {
            assert_eq!(sha.len(), 64, "{p}");
            assert!(sha.chars().all(|c| c.is_ascii_hexdigit()), "{p}");
            assert!(*size > 50_000_000, "{p}");
            assert!(url(p).starts_with("https://storage.googleapis.com/chrome-for-testing-public/"));
        }
        if let Some(p) = platform() {
            assert!(build(p).is_some());
        }
    }

    #[test]
    fn a_file_that_is_not_the_pinned_one_is_refused() {
        let sha = "ab".repeat(32);
        assert!(check(10, &sha, 10, &sha).is_ok());
        assert!(check(10, &sha.to_uppercase(), 10, &sha).is_ok());
        assert!(check(9, &sha, 10, &sha).is_err(), "short");
        assert!(check(10, &"cd".repeat(32), 10, &sha).is_err(), "other bytes");
    }

    #[test]
    fn the_program_is_found_inside_each_archive() {
        let d = Path::new("/x");
        assert!(program(d, "mac-arm64").ends_with("Contents/MacOS/Google Chrome for Testing"));
        assert!(program(d, "linux64").ends_with("chrome-linux64/chrome"));
        assert!(program(d, "win64").ends_with("chrome-win64/chrome.exe"));
    }

    /// The real download, check and unpack: `COOKIE_BROWSER_FETCH_TEST=1` (200 MB).
    #[tokio::test]
    async fn the_pinned_browser_downloads_and_runs() {
        if std::env::var("COOKIE_BROWSER_FETCH_TEST").is_err() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let p = fetch(dir.path()).await.unwrap();
        let out = std::process::Command::new(&p).arg("--version").output().unwrap();
        assert!(String::from_utf8_lossy(&out.stdout).contains(VERSION), "{out:?}");
    }
}
