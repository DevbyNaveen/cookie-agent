//! Small shared pieces: time, ids, and files written whole.

use std::path::Path;

use serde::{de::DeserializeOwned, Serialize};

/// Seconds since the Unix epoch.
pub fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// A short id: a readable slug of `name` (when given) and 24 random bits.
pub fn new_id(name: &str) -> String {
    let slug: String = name.to_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    let slug = slug.split('-').filter(|s| !s.is_empty()).take(6).collect::<Vec<_>>().join("-");
    let mut bytes = [0u8; 3];
    let _ = ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes);
    let tail = format!("{:02x}{:02x}{:02x}", bytes[0], bytes[1], bytes[2]);
    if slug.is_empty() { format!("x-{tail}") } else { format!("{slug}-{tail}") }
}

/// Random bytes as lowercase hex (tokens, codes).
pub fn random_hex(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    let _ = ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut buf);
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

/// Write JSON whole, then rename into place: a crash never leaves half a file.
pub fn write_json<T: Serialize + ?Sized>(path: &Path, value: &T) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let bytes = serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?;
    let tmp = path.with_extension(format!("tmp-{}", random_hex(4)));
    std::fs::write(&tmp, bytes).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

/// Read JSON, or the default when the file is missing or unreadable.
pub fn read_json<T: DeserializeOwned + Default>(path: &Path) -> T {
    std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

/// Append one JSON line.
pub fn append_jsonl<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    use std::io::Write;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let mut line = serde_json::to_vec(value).map_err(|e| e.to_string())?;
    line.push(b'\n');
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(path).map_err(|e| e.to_string())?;
    f.write_all(&line).map_err(|e| e.to_string())
}

/// Every line that parses; a torn last line (a crash mid-write) is skipped.
pub fn read_jsonl<T: DeserializeOwned>(path: &Path) -> Vec<T> {
    std::fs::read_to_string(path)
        .map(|s| s.lines().filter_map(|l| serde_json::from_str(l).ok()).collect())
        .unwrap_or_default()
}

/// Rewrite a JSON-lines file whole (after an edit to one line).
pub fn write_jsonl<T: Serialize>(path: &Path, items: &[T]) -> Result<(), String> {
    let mut out = Vec::new();
    for item in items {
        out.extend(serde_json::to_vec(item).map_err(|e| e.to_string())?);
        out.push(b'\n');
    }
    let tmp = path.with_extension(format!("tmp-{}", random_hex(4)));
    std::fs::write(&tmp, out).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

/// Shorten text to `max` characters on a character boundary, marking the cut.
pub fn clip(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let mut s: String = text.chars().take(max).collect();
    s.push('…');
    s
}

/// A path inside `root` from a relative name the model gave, or None if it
/// tries to leave (absolute, `..`, or a symlink pointing out).
pub fn inside(root: &Path, rel: &str) -> Option<std::path::PathBuf> {
    let rel = Path::new(rel.trim());
    if rel.as_os_str().is_empty() || rel.is_absolute() {
        return None;
    }
    if rel.components().any(|c| !matches!(c, std::path::Component::Normal(_))) {
        return None;
    }
    let joined = root.join(rel);
    let root_real = std::fs::canonicalize(root).ok()?;
    // The deepest part that exists must stay under the root once resolved.
    let mut probe = joined.clone();
    while !probe.exists() {
        probe = probe.parent()?.to_path_buf();
    }
    std::fs::canonicalize(&probe).ok()?.starts_with(&root_real).then_some(joined)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_slugged_and_distinct() {
        let a = new_id("Lead Pipeline Desk!");
        assert!(a.starts_with("lead-pipeline-desk-"), "{a}");
        assert_ne!(a, new_id("Lead Pipeline Desk!"));
        assert!(new_id("!!").starts_with("x-"));
    }

    #[test]
    fn inside_refuses_escapes() {
        let dir = tempfile::tempdir().unwrap();
        assert!(inside(dir.path(), "notes/a.md").is_some());
        assert!(inside(dir.path(), "../x").is_none());
        assert!(inside(dir.path(), "/etc/passwd").is_none());
        assert!(inside(dir.path(), "").is_none());
    }

    #[test]
    fn jsonl_round_trips_and_skips_torn_lines() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("x.jsonl");
        append_jsonl(&p, &serde_json::json!({"a": 1})).unwrap();
        std::fs::OpenOptions::new().append(true).open(&p).map(|mut f| std::io::Write::write_all(&mut f, b"{\"a\":")).unwrap().unwrap();
        let v: Vec<serde_json::Value> = read_jsonl(&p);
        assert_eq!(v.len(), 1);
    }
}
