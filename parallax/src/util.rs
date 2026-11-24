//! Small helpers: time, ids, hashes, JSON files, and paths kept inside a folder.

use std::path::{Component, Path, PathBuf};

use serde::{de::DeserializeOwned, Serialize};
use sha2::{Digest, Sha256};

pub fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

pub fn random_hex(bytes: usize) -> String {
    let mut b = vec![0u8; bytes];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut b).expect("system randomness");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// `<prefix>-<time><random>`: sortable by when, never guessed.
pub fn new_id(prefix: &str) -> String {
    format!("{prefix}-{:x}{}", now(), random_hex(4))
}

pub fn sha256_hex(b: &[u8]) -> String {
    Sha256::digest(b).iter().map(|x| format!("{x:02x}")).collect()
}

pub fn write_json<T: Serialize + ?Sized>(path: &Path, v: &T) -> Result<(), String> {
    if let Some(p) = path.parent() {
        std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension(format!("tmp-{}", random_hex(3)));
    std::fs::write(&tmp, serde_json::to_vec_pretty(v).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

pub fn read_json<T: DeserializeOwned + Default>(path: &Path) -> T {
    std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

pub fn append_jsonl<T: Serialize>(path: &Path, v: &T) -> Result<(), String> {
    use std::io::Write;
    if let Some(p) = path.parent() {
        std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
    }
    let mut line = serde_json::to_string(v).map_err(|e| e.to_string())?;
    line.push('\n');
    std::fs::OpenOptions::new().create(true).append(true).open(path).and_then(|mut f| f.write_all(line.as_bytes())).map_err(|e| e.to_string())
}

pub fn read_jsonl<T: DeserializeOwned>(path: &Path) -> Vec<T> {
    std::fs::read_to_string(path).map(|s| s.lines().filter_map(|l| serde_json::from_str(l).ok()).collect()).unwrap_or_default()
}

pub fn clip(s: &str, n: usize) -> String {
    if s.chars().count() <= n { s.to_string() } else { format!("{}…", s.chars().take(n.saturating_sub(1)).collect::<String>()) }
}

/// A path inside `root` from a relative one: no `..`, no absolute paths, no
/// symlink leading out. The file need not exist yet.
pub fn inside(root: &Path, rel: &str) -> Result<PathBuf, String> {
    let rel = rel.trim().trim_start_matches("./");
    let p = Path::new(rel);
    if rel.is_empty() || p.is_absolute() || p.components().any(|c| !matches!(c, Component::Normal(_))) {
        return Err(format!("`{rel}` isn't a path inside the world."));
    }
    let full = root.join(p);
    // The nearest existing ancestor must resolve inside the root.
    let mut probe = full.clone();
    while !probe.exists() {
        if !probe.pop() {
            break;
        }
    }
    let real_root = std::fs::canonicalize(root).map_err(|e| e.to_string())?;
    let real = std::fs::canonicalize(&probe).map_err(|e| e.to_string())?;
    if !real.starts_with(&real_root) {
        return Err(format!("`{rel}` leads outside the world."));
    }
    if rel == ".parallax" || rel.starts_with(".parallax/") {
        return Err("That is Parallax's own folder.".into());
    }
    Ok(full)
}

#[cfg(test)]
mod tests {
    #[test]
    fn paths_stay_inside() {
        let d = tempfile::tempdir().unwrap();
        assert!(super::inside(d.path(), "a/b.txt").is_ok());
        assert!(super::inside(d.path(), "../x").is_err());
        assert!(super::inside(d.path(), "/etc/passwd").is_err());
        assert!(super::inside(d.path(), ".parallax/x").is_err());
    }
}
