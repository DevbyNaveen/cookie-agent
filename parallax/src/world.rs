//! Worlds: copies of everything an agent touches, made instantly.
//!
//! A world is a folder (`worlds/<id>/files`) and its story. Forking a world,
//! taking a checkpoint and rewinding are all copies of that folder; on a Mac
//! they are APFS clones (`clonefile(2)` through `cp -c`): instant, and sharing
//! every block until a file changes, so a hundred worlds of a 300 MB project
//! cost what they change. Elsewhere they are plain copies.
//!
//! - **Fork**: a new world from another, at its current state.
//! - **Checkpoint**: the files as they are, kept under `checkpoints/<n>`.
//!   Every `Do` takes one first (`verbs`), so every change can be undone.
//! - **Rewind**: the files put back as a checkpoint had them. The present is
//!   checkpointed first, so a rewind is itself undoable.
//! - **Keep**: a world made from a real folder writes its changes back to it,
//!   but never over a file that changed there since the world was made
//!   (that file is left as it is and reported).
//! - **Sleep**: a world unused for a while is asleep: its engines' processes
//!   (a browser) are closed and only its files remain, on disk. It wakes on
//!   the next call.
//!
//! The timeline (`timeline.jsonl`) is every change, checkpoint, rewind and
//! fork, in order: what the watch window scrubs back through.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::util;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct World {
    pub id: String,
    pub name: String,
    /// The world it was forked from.
    pub parent: Option<String>,
    /// The real folder it was made from, which `keep` writes back to.
    pub origin: Option<String>,
    pub created_at: u64,
    pub touched_at: u64,
    /// `awake` · `asleep` · `kept` · `discarded`
    pub state: String,
    /// The next checkpoint's number.
    pub next_checkpoint: u64,
    /// Who opened it: an agent's name, an AI client.
    pub owner: String,
    /// A web app it serves inside, for its preview address (`preview`).
    pub app_port: Option<u16>,
}

/// One line of a world's story.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Event {
    pub at: u64,
    /// `made` · `forked` · `checkpoint` · `do` · `undo` · `rewind` · `kept` · `wall`
    pub kind: String,
    pub checkpoint: Option<u64>,
    pub change: Option<String>,
    pub engine: Option<String>,
    pub action: Option<String>,
    pub args: Option<Value>,
    /// In words, for the person.
    pub what: String,
    /// Files it changed: path → `added` · `changed` · `removed`.
    pub files: BTreeMap<String, String>,
}

/// Copy a tree: an APFS clone on a Mac, a copy elsewhere. Links are not followed.
pub fn clone_tree(src: &Path, dst: &Path) -> Result<(), String> {
    if let Some(p) = dst.parent() {
        std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
    }
    if !src.exists() {
        return std::fs::create_dir_all(dst).map_err(|e| e.to_string());
    }
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("/bin/cp").args(["-c", "-R", "-p"]).arg(src).arg(dst).output().map_err(|e| e.to_string())?;
        if out.status.success() {
            return Ok(());
        }
    }
    copy_tree(src, dst)
}

fn copy_tree(src: &Path, dst: &Path) -> Result<(), String> {
    let meta = std::fs::symlink_metadata(src).map_err(|e| e.to_string())?;
    if meta.file_type().is_symlink() {
        return Ok(());
    }
    if meta.is_dir() {
        std::fs::create_dir_all(dst).map_err(|e| e.to_string())?;
        for e in std::fs::read_dir(src).map_err(|e| e.to_string())?.flatten() {
            copy_tree(&e.path(), &dst.join(e.file_name()))?;
        }
        Ok(())
    } else {
        std::fs::copy(src, dst).map(|_| ()).map_err(|e| e.to_string())
    }
}

/// Every file under `root` (relative path → its SHA-256), skipping Parallax's own folder.
pub fn digests(root: &Path) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    walk(root, root, &mut out);
    out
}

fn walk(root: &Path, dir: &Path, out: &mut BTreeMap<String, String>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        let Ok(ft) = e.file_type() else { continue };
        let rel = p.strip_prefix(root).unwrap_or(&p).to_string_lossy().replace('\\', "/");
        if rel == ".parallax" || rel.starts_with(".parallax/") {
            continue;
        }
        if ft.is_dir() {
            walk(root, &p, out);
        } else if ft.is_file() {
            if let Ok(b) = std::fs::read(&p) {
                out.insert(rel, util::sha256_hex(&b));
            }
        }
    }
}

/// What differs from `before` to `after`: path → added · changed · removed.
pub fn changed(before: &BTreeMap<String, String>, after: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for (p, h) in after {
        match before.get(p) {
            None => {
                out.insert(p.clone(), "added".into());
            }
            Some(b) if b != h => {
                out.insert(p.clone(), "changed".into());
            }
            _ => {}
        }
    }
    for p in before.keys() {
        if !after.contains_key(p) {
            out.insert(p.clone(), "removed".into());
        }
    }
    out
}

/// Where worlds live, and the operations on them.
#[derive(Debug, Clone)]
pub struct Worlds {
    pub root: PathBuf,
}

impl Worlds {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    fn dir(&self, id: &str) -> Result<PathBuf, String> {
        if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
            return Err("No such world.".into());
        }
        Ok(self.root.join(id))
    }

    /// A world's own files: what its engines and scripts see.
    pub fn files(&self, id: &str) -> Result<PathBuf, String> {
        Ok(self.dir(id)?.join("files"))
    }

    pub fn get(&self, id: &str) -> Result<World, String> {
        let p = self.dir(id)?.join("world.json");
        let raw = std::fs::read(&p).map_err(|_| format!("No world {id}."))?;
        serde_json::from_slice(&raw).map_err(|e| e.to_string())
    }

    pub fn save(&self, w: &World) -> Result<(), String> {
        util::write_json(&self.dir(&w.id)?.join("world.json"), w)
    }

    pub fn list(&self) -> Vec<World> {
        let mut v: Vec<World> = std::fs::read_dir(&self.root)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| serde_json::from_slice(&std::fs::read(e.path().join("world.json")).ok()?).ok())
            .filter(|w: &World| w.state != "discarded")
            .collect();
        v.sort_by_key(|w| std::cmp::Reverse(w.touched_at));
        v
    }

    pub fn timeline(&self, id: &str) -> Vec<Event> {
        self.dir(id).map(|d| util::read_jsonl(&d.join("timeline.jsonl"))).unwrap_or_default()
    }

    pub fn log(&self, id: &str, e: &Event) -> Result<(), String> {
        util::append_jsonl(&self.dir(id)?.join("timeline.jsonl"), e)
    }

    /// A new world: empty, or a copy of a real folder.
    pub fn create(&self, name: &str, from: Option<&Path>, owner: &str) -> Result<World, String> {
        let id = util::new_id("w");
        let dir = self.dir(&id)?;
        match from {
            Some(f) => {
                let f = std::fs::canonicalize(f).map_err(|_| format!("No folder at {}.", f.display()))?;
                if !f.is_dir() {
                    return Err(format!("{} is not a folder.", f.display()));
                }
                clone_tree(&f, &dir.join("files"))?;
                // What the real folder held when the world was made: `keep` never overwrites a later change there.
                util::write_json(&dir.join("origin-base.json"), &digests(&f))?;
            }
            None => std::fs::create_dir_all(dir.join("files")).map_err(|e| e.to_string())?,
        }
        let now = util::now();
        let w = World {
            id: id.clone(),
            name: if name.trim().is_empty() { "world".into() } else { name.trim().chars().take(80).collect() },
            origin: from.and_then(|f| std::fs::canonicalize(f).ok()).map(|p| p.to_string_lossy().to_string()),
            created_at: now,
            touched_at: now,
            state: "awake".into(),
            owner: owner.into(),
            ..World::default()
        };
        self.save(&w)?;
        self.log(&id, &Event { at: now, kind: "made".into(), what: format!("Made {}", w.name), ..Event::default() })?;
        Ok(w)
    }

    /// A copy of a world at its current state.
    pub fn fork(&self, id: &str, name: Option<&str>) -> Result<World, String> {
        let parent = self.get(id)?;
        let new_id = util::new_id("w");
        let dir = self.dir(&new_id)?;
        clone_tree(&self.files(id)?, &dir.join("files"))?;
        let base = self.dir(id)?.join("origin-base.json");
        if base.exists() {
            clone_tree(&base, &dir.join("origin-base.json"))?;
        }
        let now = util::now();
        let w = World {
            id: new_id.clone(),
            name: name.map(str::to_string).unwrap_or_else(|| format!("{} (copy)", parent.name)),
            parent: Some(id.into()),
            origin: parent.origin.clone(),
            created_at: now,
            touched_at: now,
            state: "awake".into(),
            owner: parent.owner.clone(),
            ..World::default()
        };
        self.save(&w)?;
        self.log(&new_id, &Event { at: now, kind: "forked".into(), what: format!("Forked from {}", parent.name), ..Event::default() })?;
        Ok(w)
    }

    /// Bring the work of `forks` back into `base`, file by file. `before` is
    /// how `base` was when they were forked from it (`digests`). A file only
    /// one fork changed is taken from it; a file two forks changed differently,
    /// or that changed in `base` meanwhile, is a conflict: left as `base` has
    /// it and named, never guessed. `base` is checkpointed first, so the whole
    /// merge can be rewound.
    pub fn merge(&self, base: &str, before: &BTreeMap<String, String>, forks: &[String]) -> Result<Value, String> {
        let base_files = self.files(base)?;
        let now_base = digests(&base_files);
        // path → (fork, its digest after, or None when it removed the file)
        let mut wants: BTreeMap<String, Vec<(String, Option<String>)>> = BTreeMap::new();
        for f in forks {
            let after = digests(&self.files(f)?);
            for (path, how) in changed(before, &after) {
                wants.entry(path.clone()).or_default().push((f.clone(), if how == "removed" { None } else { after.get(&path).cloned() }));
            }
        }
        let checkpoint = self.checkpoint(base, "Before merging the workers' copies")?;
        let (mut applied, mut conflicts) = (Vec::new(), Vec::new());
        for (path, by) in &wants {
            let distinct: std::collections::BTreeSet<&Option<String>> = by.iter().map(|(_, d)| d).collect();
            let moved_in_base = now_base.get(path) != before.get(path);
            if distinct.len() > 1 || moved_in_base {
                conflicts.push(json!({"path": path, "forks": by.iter().map(|(f, _)| f).collect::<Vec<_>>(), "why": if moved_in_base { "it changed in the original too" } else { "copies changed it differently" }}));
                continue;
            }
            let (fork, digest) = &by[0];
            let target = base_files.join(path);
            match digest {
                Some(_) => {
                    if let Some(dir) = target.parent() {
                        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
                    }
                    std::fs::copy(self.files(fork)?.join(path), &target).map_err(|e| format!("{path}: {e}"))?;
                }
                None => {
                    let _ = std::fs::remove_file(&target);
                }
            }
            applied.push(json!({"path": path, "from": fork, "how": if digest.is_some() { "written" } else { "removed" }}));
        }
        let after = digests(&base_files);
        self.log(base, &Event { at: util::now(), kind: "merge".into(), checkpoint: Some(checkpoint), what: format!("Merged {} copies: {} files, {} conflicts", forks.len(), applied.len(), conflicts.len()), files: changed(&now_base, &after), ..Event::default() })?;
        Ok(json!({"applied": applied, "conflicts": conflicts, "undo_checkpoint": checkpoint}))
    }

    /// Keep the files as they are now. Returns the checkpoint's number.
    pub fn checkpoint(&self, id: &str, what: &str) -> Result<u64, String> {
        let mut w = self.get(id)?;
        let n = w.next_checkpoint;
        clone_tree(&self.files(id)?, &self.dir(id)?.join("checkpoints").join(n.to_string()))?;
        w.next_checkpoint += 1;
        w.touched_at = util::now();
        self.save(&w)?;
        self.log(id, &Event { at: util::now(), kind: "checkpoint".into(), checkpoint: Some(n), what: what.into(), ..Event::default() })?;
        Ok(n)
    }

    pub fn checkpoint_files(&self, id: &str, n: u64) -> Result<PathBuf, String> {
        let p = self.dir(id)?.join("checkpoints").join(n.to_string());
        p.exists().then_some(p).ok_or_else(|| format!("World {id} has no checkpoint {n}."))
    }

    /// Put the files back as checkpoint `n` had them; the present is kept first.
    pub fn rewind(&self, id: &str, n: u64) -> Result<u64, String> {
        let src = self.checkpoint_files(id, n)?;
        let saved = self.checkpoint(id, &format!("Before rewinding to {n}"))?;
        let before = digests(&self.files(id)?);
        let files = self.files(id)?;
        let staged = self.dir(id)?.join(".rewinding");
        let _ = std::fs::remove_dir_all(&staged);
        clone_tree(&src, &staged)?;
        let old = self.dir(id)?.join(".old-files");
        let _ = std::fs::remove_dir_all(&old);
        std::fs::rename(&files, &old).map_err(|e| e.to_string())?;
        if let Err(e) = std::fs::rename(&staged, &files) {
            let _ = std::fs::rename(&old, &files);
            return Err(e.to_string());
        }
        let _ = std::fs::remove_dir_all(&old);
        let after = digests(&files);
        self.log(id, &Event { at: util::now(), kind: "rewind".into(), checkpoint: Some(n), what: format!("Rewound to checkpoint {n} (the present is checkpoint {saved})"), files: changed(&before, &after), ..Event::default() })?;
        Ok(saved)
    }

    /// Write a world's changes back to the folder it came from. A file that
    /// changed there since the world was made is left alone and reported.
    pub fn keep(&self, id: &str) -> Result<Value, String> {
        let mut w = self.get(id)?;
        let origin = PathBuf::from(w.origin.clone().ok_or("This world wasn't made from a folder; there is nothing to write back to.")?);
        let base: BTreeMap<String, String> = util::read_json(&self.dir(id)?.join("origin-base.json"));
        let now_there = digests(&origin);
        let mine = digests(&self.files(id)?);
        let mut written = Vec::new();
        let mut conflicts = Vec::new();
        for (path, change) in changed(&base, &mine) {
            // Changed in the real folder since the world was made: never overwritten.
            if now_there.get(&path) != base.get(&path) {
                conflicts.push(path);
                continue;
            }
            let dst = origin.join(&path);
            match change.as_str() {
                "removed" => {
                    let _ = std::fs::remove_file(&dst);
                }
                _ => {
                    if let Some(p) = dst.parent() {
                        std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
                    }
                    std::fs::copy(self.files(id)?.join(&path), &dst).map_err(|e| e.to_string())?;
                }
            }
            written.push(path);
        }
        // The real folder now matches what was kept: the new base.
        util::write_json(&self.dir(id)?.join("origin-base.json"), &digests(&origin))?;
        w.state = "kept".into();
        w.touched_at = util::now();
        self.save(&w)?;
        self.log(id, &Event { at: util::now(), kind: "kept".into(), what: format!("Kept: {} files written back, {} left because they changed there", written.len(), conflicts.len()), ..Event::default() })?;
        Ok(serde_json::json!({"written": written, "left_alone": conflicts, "folder": origin}))
    }

    pub fn discard(&self, id: &str) -> Result<(), String> {
        let mut w = self.get(id)?;
        w.state = "discarded".into();
        self.save(&w)?;
        let _ = std::fs::remove_dir_all(self.files(id)?);
        let _ = std::fs::remove_dir_all(self.dir(id)?.join("checkpoints"));
        Ok(())
    }

    /// Mark a world used now; wake it if it slept.
    pub fn touch(&self, id: &str) -> Result<World, String> {
        let mut w = self.get(id)?;
        if w.state == "discarded" {
            return Err("That world was discarded.".into());
        }
        w.touched_at = util::now();
        if w.state == "asleep" {
            w.state = "awake".into();
        }
        self.save(&w)?;
        Ok(w)
    }

    /// Worlds unused for `idle_secs` go to sleep (their engines are closed by the caller).
    pub fn put_idle_to_sleep(&self, idle_secs: u64) -> Vec<String> {
        let now = util::now();
        let mut slept = Vec::new();
        for mut w in self.list() {
            if w.state == "awake" && now.saturating_sub(w.touched_at) >= idle_secs {
                w.state = "asleep".into();
                if self.save(&w).is_ok() {
                    slept.push(w.id);
                }
            }
        }
        slept
    }
}

/// A line diff of two texts, as `-`/`+`/` ` lines (longest common subsequence;
/// texts over 3,000 lines are reported as changed without the lines).
pub fn text_diff(a: &str, b: &str) -> Vec<String> {
    let x: Vec<&str> = a.lines().collect();
    let y: Vec<&str> = b.lines().collect();
    if x.len() > 3_000 || y.len() > 3_000 {
        return vec![format!("(too long to show: {} lines → {} lines)", x.len(), y.len())];
    }
    let (n, m) = (x.len(), y.len());
    let mut lcs = vec![vec![0u32; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[i][j] = if x[i] == y[j] { lcs[i + 1][j + 1] + 1 } else { lcs[i + 1][j].max(lcs[i][j + 1]) };
        }
    }
    let (mut i, mut j, mut out) = (0, 0, Vec::new());
    while i < n || j < m {
        if i < n && j < m && x[i] == y[j] {
            out.push(format!(" {}", x[i]));
            i += 1;
            j += 1;
        } else if i < n && (j == m || lcs[i + 1][j] >= lcs[i][j + 1]) {
            // A removed line before the line that replaces it, as unified diffs show it.
            out.push(format!("-{}", x[i]));
            i += 1;
        } else {
            out.push(format!("+{}", y[j]));
            j += 1;
        }
    }
    out
}

/// What differs between two folders, with line diffs of changed text files.
pub fn diff_dirs(a: &Path, b: &Path) -> Value {
    let (da, db) = (digests(a), digests(b));
    let files = changed(&da, &db);
    let mut out = Vec::new();
    for (path, kind) in &files {
        let read = |root: &Path| std::fs::read(root.join(path)).ok().and_then(|b| String::from_utf8(b).ok());
        let lines = match kind.as_str() {
            "changed" => match (read(a), read(b)) {
                (Some(x), Some(y)) => {
                    let d: Vec<String> = text_diff(&x, &y).into_iter().filter(|l| !l.starts_with(' ')).take(200).collect();
                    Some(d)
                }
                _ => None,
            },
            _ => None,
        };
        out.push(serde_json::json!({"path": path, "change": kind, "lines": lines}));
    }
    serde_json::json!({"files": out, "count": files.len()})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workers_copies_merge_back_and_a_clash_is_named_not_guessed() {
        let dir = tempfile::tempdir().unwrap();
        let ws = Worlds::new(dir.path());
        let base = ws.create("base", None, "a").unwrap().id;
        let files = ws.files(&base).unwrap();
        std::fs::write(files.join("shared.md"), "v0").unwrap();
        std::fs::write(files.join("old.md"), "bye").unwrap();
        let before = digests(&files);
        let (one, two) = (ws.fork(&base, None).unwrap().id, ws.fork(&base, None).unwrap().id);
        std::fs::write(ws.files(&one).unwrap().join("a.md"), "from one").unwrap();
        std::fs::create_dir_all(ws.files(&two).unwrap().join("sub")).unwrap();
        std::fs::write(ws.files(&two).unwrap().join("sub/b.md"), "from two").unwrap();
        std::fs::remove_file(ws.files(&two).unwrap().join("old.md")).unwrap();
        std::fs::write(ws.files(&one).unwrap().join("shared.md"), "one's").unwrap();
        std::fs::write(ws.files(&two).unwrap().join("shared.md"), "two's").unwrap();
        let r = ws.merge(&base, &before, &[one, two]).unwrap();
        assert_eq!(std::fs::read_to_string(files.join("a.md")).unwrap(), "from one");
        assert_eq!(std::fs::read_to_string(files.join("sub/b.md")).unwrap(), "from two");
        assert!(!files.join("old.md").exists(), "a removal lands too");
        assert_eq!(std::fs::read_to_string(files.join("shared.md")).unwrap(), "v0", "a clash is left as it was");
        assert_eq!(r["conflicts"].as_array().unwrap().len(), 1);
        assert_eq!(r["conflicts"][0]["path"], "shared.md");
        let n = r["undo_checkpoint"].as_u64().unwrap();
        ws.rewind(&base, n).unwrap();
        assert!(files.join("old.md").exists() && !files.join("a.md").exists(), "the whole merge rewinds");
    }

    #[test]
    fn fork_checkpoint_rewind_and_keep() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("project");
        std::fs::create_dir_all(&real).unwrap();
        std::fs::write(real.join("a.txt"), "one\n").unwrap();
        std::fs::write(real.join("b.txt"), "bee\n").unwrap();
        let ws = Worlds::new(dir.path().join("worlds"));
        let w = ws.create("proj", Some(&real), "test").unwrap();
        let f = ws.files(&w.id).unwrap();
        assert_eq!(std::fs::read_to_string(f.join("a.txt")).unwrap(), "one\n");
        let c0 = ws.checkpoint(&w.id, "start").unwrap();
        std::fs::write(f.join("a.txt"), "two\n").unwrap();
        let fork = ws.fork(&w.id, None).unwrap();
        assert_eq!(std::fs::read_to_string(ws.files(&fork.id).unwrap().join("a.txt")).unwrap(), "two\n");
        // Rewind: back to "one", and the present is kept first.
        let saved = ws.rewind(&w.id, c0).unwrap();
        assert_eq!(std::fs::read_to_string(f.join("a.txt")).unwrap(), "one\n");
        ws.rewind(&w.id, saved).unwrap();
        assert_eq!(std::fs::read_to_string(f.join("a.txt")).unwrap(), "two\n", "a rewind is undoable");
        // Keep: a.txt goes back; b.txt changed in the real folder meanwhile, so it is left alone.
        std::fs::write(f.join("b.txt"), "world bee\n").unwrap();
        std::fs::write(real.join("b.txt"), "your bee\n").unwrap();
        let k = ws.keep(&w.id).unwrap();
        assert_eq!(std::fs::read_to_string(real.join("a.txt")).unwrap(), "two\n");
        assert_eq!(std::fs::read_to_string(real.join("b.txt")).unwrap(), "your bee\n");
        assert_eq!(k["left_alone"], serde_json::json!(["b.txt"]));
        assert!(ws.timeline(&w.id).iter().any(|e| e.kind == "rewind"));
        assert!(ws.get("../x").is_err());
    }

    #[test]
    fn a_diff_shows_only_what_changed() {
        let d = text_diff("a\nb\nc\n", "a\nB\nc\nd\n");
        assert_eq!(d, vec![" a", "-b", "+B", " c", "+d"]);
    }
}
