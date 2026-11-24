//! A live link between a folder on a Mac and a world on a Parallax host.
//!
//! Not through GitHub, not a copy: `parallax link <folder> <host>` keeps the
//! two in step.
//!
//! - **Only changed bytes travel.** Files are cut into content-defined chunks
//!   (a gear rolling hash: about 16 KB on average, 4–64 KB), named by their
//!   SHA-256. An edit in the middle of a file changes one or two chunks; the
//!   rest are already on the host and are not sent again.
//! - **The world starts at once.** The file list arrives first and the world
//!   exists; each file is written into it as soon as its chunks are there.
//! - **Back to the Mac.** What changed in the world (an agent's work) comes
//!   back the same way, chunk by chunk.
//! - **Never overwritten.** A file changed on both sides since they last
//!   agreed is not overwritten on the Mac: the world's version is written
//!   beside it as `name (Parallax).ext`, and both are reported.
//! - **Secrets stay home.** `.env` files, keys and certificates, `.ssh`,
//!   `.aws`, credential files, and the usual build folders are never sent.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::util;

const MIN: usize = 4 * 1024;
const AVG_MASK: u64 = (1 << 14) - 1; // ~16 KB
const MAX: usize = 64 * 1024;

/// The gear table: 256 fixed pseudo-random words (SplitMix64 from a fixed seed).
fn gear() -> &'static [u64; 256] {
    static G: std::sync::OnceLock<[u64; 256]> = std::sync::OnceLock::new();
    G.get_or_init(|| {
        let mut t = [0u64; 256];
        let mut x: u64 = 0x5eed_9a11_a7a5_0001;
        for v in t.iter_mut() {
            x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = x;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            *v = z ^ (z >> 31);
        }
        t
    })
}

/// Cut bytes at content-defined boundaries: the same content cuts the same way
/// wherever it sits in the file.
pub fn chunks(data: &[u8]) -> Vec<&[u8]> {
    let g = gear();
    let mut out = Vec::new();
    let mut start = 0;
    while start < data.len() {
        let end = (start + MAX).min(data.len());
        let mut cut = end;
        let mut h: u64 = 0;
        let mut i = start + MIN.min(end - start);
        while i < end {
            h = (h << 1).wrapping_add(g[data[i] as usize]);
            if h & AVG_MASK == 0 {
                cut = i + 1;
                break;
            }
            i += 1;
        }
        out.push(&data[start..cut]);
        start = cut;
    }
    out
}

/// Never leaves the Mac.
pub fn is_secret_or_build(rel: &str) -> bool {
    let lower = rel.to_lowercase();
    let name = lower.rsplit('/').next().unwrap_or(&lower);
    let parts: Vec<&str> = lower.split('/').collect();
    parts.iter().any(|p| matches!(*p, ".ssh" | ".aws" | ".gnupg" | ".git" | "node_modules" | "target" | ".venv" | "__pycache__" | ".parallax" | ".next" | "dist" | "build"))
        || name.starts_with(".env")
        || name.starts_with("id_rsa")
        || name.starts_with("id_ed25519")
        || [".pem", ".key", ".p12", ".pfx", ".keychain", ".kdbx"].iter().any(|e| name.ends_with(e))
        || name.contains("credential")
        || name.contains("secret")
        || name == ".netrc"
        || name == ".npmrc"
        || name == ".ds_store"
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct FileEntry {
    pub size: u64,
    /// SHA-256 of the whole file.
    pub sha: String,
    /// Its chunks, in order.
    pub blocks: Vec<String>,
}

pub type Manifest = BTreeMap<String, FileEntry>;

/// What a folder holds now, cut into chunks (secrets and build folders left out).
/// Returns the manifest and the chunk bytes by name.
pub fn scan(root: &Path) -> (Manifest, BTreeMap<String, Vec<u8>>) {
    let mut m = Manifest::new();
    let mut data = BTreeMap::new();
    for (rel, sha) in crate::world::digests(root) {
        if is_secret_or_build(&rel) {
            continue;
        }
        let Ok(bytes) = std::fs::read(root.join(&rel)) else { continue };
        let mut blocks = Vec::new();
        for c in chunks(&bytes) {
            let h = util::sha256_hex(c);
            data.entry(h.clone()).or_insert_with(|| c.to_vec());
            blocks.push(h);
        }
        m.insert(rel, FileEntry { size: bytes.len() as u64, sha, blocks });
    }
    (m, data)
}

/* ---------------- the host's side ---------------- */

/// A link on the host: its world, the manifest both sides last agreed on, and chunks by name.
pub struct Host {
    pub dir: PathBuf,
    pub blocks: PathBuf,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
struct LinkState {
    world: String,
    /// What the Mac last sent (and what was last sent back): the agreed base.
    base: Manifest,
    /// Files still waiting for chunks.
    pending: BTreeMap<String, FileEntry>,
}

fn good_link_name(n: &str) -> bool {
    !n.is_empty() && n.len() <= 64 && n.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn good_sha(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

impl Host {
    pub fn new(home: &Path) -> Self {
        Self { dir: home.join("links"), blocks: home.join("blocks") }
    }

    fn block_path(&self, sha: &str) -> PathBuf {
        self.blocks.join(&sha[..2]).join(sha)
    }

    pub fn has_block(&self, sha: &str) -> bool {
        good_sha(sha) && self.block_path(sha).exists()
    }

    fn state(&self, link: &str) -> Result<LinkState, String> {
        if !good_link_name(link) {
            return Err("A link's name is letters, digits, - and _.".into());
        }
        Ok(util::read_json(&self.dir.join(link).join("state.json")))
    }

    fn save(&self, link: &str, s: &LinkState) -> Result<(), String> {
        util::write_json(&self.dir.join(link).join("state.json"), s)
    }

    /// The Mac's changes: a new manifest. The world exists at once; the
    /// answer names the chunks the host still needs.
    pub fn push(&self, px: &crate::Parallax, link: &str, manifest: &Manifest) -> Result<Value, String> {
        let mut st = self.state(link)?;
        if st.world.is_empty() || px.worlds.get(&st.world).is_err() {
            st.world = px.worlds.create(&format!("link: {link}"), None, "link")?.id;
        }
        let files = px.worlds.files(&st.world)?;
        for (path, entry) in manifest {
            if is_secret_or_build(path) {
                continue;
            }
            util::inside(&files, path)?;
            if st.base.get(path) != Some(entry) {
                st.pending.insert(path.clone(), entry.clone());
            }
        }
        // Gone from the Mac: gone from the world (unless the world changed it since).
        let world_now = crate::world::digests(&files);
        for (path, old) in st.base.clone() {
            if !manifest.contains_key(&path) {
                if world_now.get(&path) == Some(&old.sha) {
                    let _ = std::fs::remove_file(files.join(&path));
                }
                st.base.remove(&path);
            }
        }
        let need: BTreeSet<String> = st.pending.values().flat_map(|e| e.blocks.iter().cloned()).filter(|b| !self.has_block(b)).collect();
        self.materialize(px, &mut st)?;
        self.save(link, &st)?;
        Ok(json!({"world": st.world, "need": need, "waiting_files": st.pending.len()}))
    }

    /// One chunk, checked against its name; files it completes are written.
    pub fn put_block(&self, px: &crate::Parallax, link: &str, sha: &str, bytes: &[u8]) -> Result<Value, String> {
        if !good_sha(sha) || util::sha256_hex(bytes) != sha {
            return Err("That chunk doesn't match its name.".into());
        }
        let p = self.block_path(sha);
        if let Some(d) = p.parent() {
            std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
        }
        std::fs::write(&p, bytes).map_err(|e| e.to_string())?;
        let mut st = self.state(link)?;
        let written = self.materialize(px, &mut st)?;
        self.save(link, &st)?;
        Ok(json!({"written": written, "waiting_files": st.pending.len()}))
    }

    pub fn get_block(&self, sha: &str) -> Result<Vec<u8>, String> {
        if !self.has_block(sha) {
            return Err("No such chunk.".into());
        }
        std::fs::read(self.block_path(sha)).map_err(|e| e.to_string())
    }

    /// Write every pending file whose chunks have all arrived.
    fn materialize(&self, px: &crate::Parallax, st: &mut LinkState) -> Result<Vec<String>, String> {
        let files = px.worlds.files(&st.world)?;
        let ready: Vec<String> = st.pending.iter().filter(|(_, e)| e.blocks.iter().all(|b| self.has_block(b))).map(|(p, _)| p.clone()).collect();
        for path in &ready {
            let e = st.pending.remove(path).unwrap_or_default();
            let mut bytes = Vec::with_capacity(e.size as usize);
            for b in &e.blocks {
                bytes.extend(std::fs::read(self.block_path(b)).map_err(|e| e.to_string())?);
            }
            if util::sha256_hex(&bytes) != e.sha {
                return Err(format!("{path} didn't reassemble to what was sent."));
            }
            let dst = util::inside(&files, path)?;
            if let Some(d) = dst.parent() {
                std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
            }
            std::fs::write(dst, bytes).map_err(|e| e.to_string())?;
            st.base.insert(path.clone(), e);
        }
        Ok(ready)
    }

    /// What changed in the world since the base: for the Mac to take back.
    /// The world's new chunks are stored so the Mac can fetch them.
    pub fn changes(&self, px: &crate::Parallax, link: &str) -> Result<Value, String> {
        let st = self.state(link)?;
        if st.world.is_empty() {
            return Ok(json!({"files": {}, "removed": []}));
        }
        let (now, data) = scan(&px.worlds.files(&st.world)?);
        let mut files = Manifest::new();
        for (path, e) in &now {
            if st.base.get(path).map(|b| &b.sha) != Some(&e.sha) && !st.pending.contains_key(path) {
                files.insert(path.clone(), e.clone());
            }
        }
        for e in files.values() {
            for b in &e.blocks {
                if !self.has_block(b) {
                    let p = self.block_path(b);
                    if let Some(d) = p.parent() {
                        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
                    }
                    std::fs::write(p, &data[b]).map_err(|e| e.to_string())?;
                }
            }
        }
        let removed: Vec<&String> = st.base.keys().filter(|p| !now.contains_key(*p) && !st.pending.contains_key(*p)).collect();
        Ok(json!({"files": files, "removed": removed}))
    }

    /// The Mac took these back: they are the base now.
    pub fn agreed(&self, link: &str, taken: &Manifest, removed: &[String]) -> Result<(), String> {
        let mut st = self.state(link)?;
        for (p, e) in taken {
            st.base.insert(p.clone(), e.clone());
        }
        for p in removed {
            st.base.remove(p);
        }
        self.save(link, &st)
    }
}

/* ---------------- the Mac's side ---------------- */

/// Write the world's version of a file into the Mac's folder, unless the Mac
/// changed it since the base: then beside it, as `name (Parallax).ext`.
pub fn take_back(root: &Path, path: &str, bytes: &[u8], base_sha: Option<&str>) -> Result<String, String> {
    let dst = util::inside(root, path)?;
    let mine = std::fs::read(&dst).ok().map(|b| util::sha256_hex(&b));
    let clash = match (&mine, base_sha) {
        (Some(m), Some(b)) => m != b,
        (Some(_), None) => true,
        (None, _) => false,
    };
    let target = if clash {
        let stem = dst.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        let ext = dst.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
        dst.with_file_name(format!("{stem} (Parallax){ext}"))
    } else {
        dst
    };
    if let Some(d) = target.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    std::fs::write(&target, bytes).map_err(|e| e.to_string())?;
    Ok(if clash { "beside" } else { "written" }.into())
}

/// Keep a folder linked to a host: push changes, send needed chunks, take the world's changes back.
pub async fn run(folder: &Path, host: &str, token: &str, link: &str) -> Result<(), String> {
    let folder = std::fs::canonicalize(folder).map_err(|e| e.to_string())?;
    let host = host.trim_end_matches('/');
    if !(host.starts_with("https://") || host.starts_with("http://127.0.0.1") || host.starts_with("http://localhost")) {
        return Err("The host must be https (or this machine).".into());
    }
    let http = reqwest::Client::builder().timeout(std::time::Duration::from_secs(60)).build().map_err(|e| e.to_string())?;
    let mut sent = Manifest::new();
    loop {
        let (now, data) = scan(&folder);
        if now != sent {
            let r: Value = http.post(format!("{host}/link/{link}/push")).bearer_auth(token).json(&json!({"manifest": now})).send().await.map_err(|e| e.to_string())?.json().await.map_err(|e| e.to_string())?;
            if let Some(e) = r.get("error") {
                return Err(e.to_string());
            }
            for sha in r["need"].as_array().into_iter().flatten().filter_map(Value::as_str) {
                if let Some(b) = data.get(sha) {
                    http.put(format!("{host}/link/{link}/block/{sha}")).bearer_auth(token).body(b.clone()).send().await.map_err(|e| e.to_string())?;
                }
            }
            sent = now.clone();
        }
        // The world's changes, back to the Mac.
        let ch: Value = http.get(format!("{host}/link/{link}/changes")).bearer_auth(token).send().await.map_err(|e| e.to_string())?.json().await.map_err(|e| e.to_string())?;
        let files: Manifest = serde_json::from_value(ch["files"].clone()).unwrap_or_default();
        let removed: Vec<String> = serde_json::from_value(ch["removed"].clone()).unwrap_or_default();
        if !files.is_empty() || !removed.is_empty() {
            for (path, e) in &files {
                let mut bytes = Vec::new();
                for b in &e.blocks {
                    match data.get(b) {
                        Some(local) => bytes.extend_from_slice(local),
                        None => bytes.extend(http.get(format!("{host}/link/{link}/block/{b}")).bearer_auth(token).send().await.map_err(|e| e.to_string())?.bytes().await.map_err(|e| e.to_string())?),
                    }
                }
                if util::sha256_hex(&bytes) != e.sha {
                    continue;
                }
                let how = take_back(&folder, path, &bytes, sent.get(path).map(|b| b.sha.as_str()))?;
                eprintln!("parallax link: {path} {how}");
            }
            for path in &removed {
                let p = util::inside(&folder, path)?;
                let unchanged = std::fs::read(&p).ok().map(|b| util::sha256_hex(&b)) == sent.get(path).map(|e| e.sha.clone());
                if unchanged {
                    let _ = std::fs::remove_file(p);
                }
            }
            http.post(format!("{host}/link/{link}/agreed")).bearer_auth(token).json(&json!({"files": files, "removed": removed})).send().await.map_err(|e| e.to_string())?;
            sent = scan(&folder).0;
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_edit_in_the_middle_changes_few_chunks() {
        let mut x: u64 = 7;
        let data: Vec<u8> = (0..400_000).map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            (x & 0xff) as u8
        }).collect();
        let a: Vec<String> = chunks(&data).iter().map(|c| util::sha256_hex(c)).collect();
        let mut edited = data.clone();
        edited.splice(200_000..200_000, b"an inserted sentence".iter().copied());
        let b: Vec<String> = chunks(&edited).iter().map(|c| util::sha256_hex(c)).collect();
        let shared = b.iter().filter(|h| a.contains(h)).count();
        assert!(a.len() > 10 && b.len() - shared <= 2, "{} chunks, {} new after an insertion", b.len(), b.len() - shared);
        assert!(chunks(&data).iter().all(|c| c.len() <= MAX));
    }

    #[test]
    fn secrets_and_build_folders_never_leave() {
        for p in [".env", ".env.local", "deploy/id_rsa", "certs/server.pem", ".ssh/config", "node_modules/x/index.js", "app/.git/HEAD", "aws_credentials.json"] {
            assert!(is_secret_or_build(p), "{p}");
        }
        for p in ["src/main.rs", "README.md", "docs/environment.md"] {
            assert!(!is_secret_or_build(p), "{p}");
        }
    }

    #[test]
    fn host_world_gets_files_as_chunks_arrive_and_changes_come_back_without_overwriting() {
        let d = tempfile::tempdir().unwrap();
        let px = crate::Parallax::open(d.path().join("px")).unwrap();
        let host = Host::new(&px.home);
        let mac = d.path().join("mac");
        std::fs::create_dir_all(&mac).unwrap();
        std::fs::write(mac.join("plan.md"), "v1\n").unwrap();
        std::fs::write(mac.join(".env"), "KEY=1").unwrap();
        let (m, data) = scan(&mac);
        assert!(!m.contains_key(".env"));
        let r = host.push(&px, "proj", &m).unwrap();
        let world = r["world"].as_str().unwrap().to_string();
        assert!(!px.worlds.files(&world).unwrap().join("plan.md").exists(), "waits for its chunks");
        for sha in r["need"].as_array().unwrap() {
            let sha = sha.as_str().unwrap();
            host.put_block(&px, "proj", sha, &data[sha]).unwrap();
        }
        let wf = px.worlds.files(&world).unwrap();
        assert_eq!(std::fs::read_to_string(wf.join("plan.md")).unwrap(), "v1\n");
        assert!(host.put_block(&px, "proj", &"0".repeat(64), b"x").is_err(), "a chunk must match its name");
        // The agent edits in the world; the person edits on the Mac too.
        std::fs::write(wf.join("plan.md"), "agent v2\n").unwrap();
        std::fs::write(wf.join("new.md"), "made by the agent\n").unwrap();
        std::fs::write(mac.join("plan.md"), "person v2\n").unwrap();
        let ch = host.changes(&px, "proj").unwrap();
        let files: Manifest = serde_json::from_value(ch["files"].clone()).unwrap();
        assert_eq!(files.len(), 2);
        for (path, e) in &files {
            let bytes: Vec<u8> = e.blocks.iter().flat_map(|b| host.get_block(b).unwrap()).collect();
            take_back(&mac, path, &bytes, m.get(path).map(|x| x.sha.as_str())).unwrap();
        }
        assert_eq!(std::fs::read_to_string(mac.join("plan.md")).unwrap(), "person v2\n", "never overwritten");
        assert_eq!(std::fs::read_to_string(mac.join("plan (Parallax).md")).unwrap(), "agent v2\n");
        assert_eq!(std::fs::read_to_string(mac.join("new.md")).unwrap(), "made by the agent\n");
    }
}
