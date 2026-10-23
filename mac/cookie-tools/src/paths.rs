//! Where files may be read and written: only inside the allowed roots.

use std::{
    fs,
    io::{self, Read, Write},
    path::{Component, Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

/// The most a tool reads from one file.
pub const MAX_READ_BYTES: u64 = 10 * 1024 * 1024;

pub struct Roots {
    roots: Vec<PathBuf>,
    home: Option<PathBuf>,
}

impl Roots {
    /// Canonical roots; each must be an existing folder.
    pub fn new(dirs: &[PathBuf], home: Option<PathBuf>) -> Result<Self, String> {
        if dirs.is_empty() {
            return Err("give at least one --root <folder>".into());
        }
        let mut roots = Vec::new();
        for dir in dirs {
            let dir = expand_home(dir, home.as_deref())?;
            let canonical = fs::canonicalize(&dir).map_err(|e| format!("root {}: {e}", dir.display()))?;
            if !canonical.is_dir() {
                return Err(format!("root {} is not a folder", dir.display()));
            }
            roots.push(canonical);
        }
        Ok(Self { roots, home })
    }

    pub fn list(&self) -> Vec<String> {
        self.roots.iter().map(|r| self.show(r)).collect()
    }

    fn inside(&self, path: &Path) -> bool {
        self.roots.iter().any(|root| path.starts_with(root))
    }

    /// A path as the person would write it (`~/…`).
    pub fn show(&self, path: &Path) -> String {
        match &self.home {
            Some(home) => match path.strip_prefix(home) {
                Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
                Ok(rest) => format!("~/{}", rest.display()),
                Err(_) => path.display().to_string(),
            },
            None => path.display().to_string(),
        }
    }

    fn absolute(&self, raw: &str) -> Result<PathBuf, String> {
        if raw.trim().is_empty() {
            return Err("`path` is empty".into());
        }
        if raw.contains('\0') {
            return Err("`path` contains a NUL character".into());
        }
        let path = expand_home(Path::new(raw), self.home.as_deref())?;
        if path.components().any(|c| matches!(c, Component::ParentDir)) {
            return Err(format!("`{raw}`: `..` is not allowed in a path"));
        }
        // a relative path lands in the first root.
        Ok(if path.is_absolute() { path } else { self.roots[0].join(path) })
    }

    fn outside(&self, raw: &str) -> String {
        format!("`{raw}` is outside the folders Cookie may use ({})", self.list().join(", "))
    }

    /// An existing file to read, after following every symlink.
    pub fn read_target(&self, raw: &str) -> Result<PathBuf, String> {
        let path = self.absolute(raw)?;
        let canonical = fs::canonicalize(&path).map_err(|e| match e.kind() {
            io::ErrorKind::NotFound => format!("`{raw}` does not exist"),
            _ => format!("`{raw}`: {e}"),
        })?;
        if !self.inside(&canonical) {
            return Err(self.outside(raw));
        }
        let meta = fs::metadata(&canonical).map_err(|e| format!("`{raw}`: {e}"))?;
        if !meta.is_file() {
            return Err(format!("`{raw}` is not a file"));
        }
        if meta.len() > MAX_READ_BYTES {
            return Err(format!("`{raw}` is {} — the limit for reading is 10 MB", human_size(meta.len())));
        }
        Ok(canonical)
    }

    /// Where a new file goes: its folder resolved through symlinks and checked,
    /// the file name kept as given. Missing folders are made only with `create_dirs`.
    pub fn write_target(&self, raw: &str, create_dirs: bool) -> Result<PathBuf, String> {
        let path = self.absolute(raw)?;
        let name = match path.components().next_back() {
            Some(Component::Normal(name)) if !raw.ends_with('/') => name.to_owned(),
            _ => return Err(format!("`{raw}` does not name a file")),
        };
        let parent = path.parent().ok_or_else(|| format!("`{raw}` does not name a file"))?;
        let folder = match fs::canonicalize(parent) {
            Ok(folder) => folder,
            Err(e) if e.kind() == io::ErrorKind::NotFound && create_dirs => self.make_dirs(raw, parent)?,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                return Err(format!(
                    "the folder {} does not exist; pass `create_dirs: true` to make it",
                    self.show(parent)
                ))
            }
            Err(e) => return Err(format!("`{raw}`: {e}")),
        };
        if !self.inside(&folder) {
            return Err(self.outside(raw));
        }
        if !folder.is_dir() {
            return Err(format!("{} is not a folder", self.show(&folder)));
        }
        Ok(folder.join(name))
    }

    /// Make the missing folders of `parent`, checking that the deepest existing
    /// one is inside a root before making anything.
    fn make_dirs(&self, raw: &str, parent: &Path) -> Result<PathBuf, String> {
        let mut existing = parent;
        let mut missing = Vec::new();
        let base = loop {
            match fs::canonicalize(existing) {
                Ok(base) => break base,
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    missing.push(existing.file_name().ok_or_else(|| self.outside(raw))?.to_owned());
                    existing = existing.parent().ok_or_else(|| self.outside(raw))?;
                }
                Err(e) => return Err(format!("`{raw}`: {e}")),
            }
        };
        if !self.inside(&base) {
            return Err(self.outside(raw));
        }
        let mut folder = base;
        for name in missing.into_iter().rev() {
            folder.push(name);
            match fs::create_dir(&folder) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(format!("could not make {}: {e}", self.show(&folder))),
            }
        }
        // Re-resolve: a folder made by someone else meanwhile may be a symlink.
        fs::canonicalize(&folder).map_err(|e| format!("`{raw}`: {e}"))
    }
}

fn expand_home(path: &Path, home: Option<&Path>) -> Result<PathBuf, String> {
    let text = path.to_string_lossy();
    if text == "~" || text.starts_with("~/") {
        let home = home.ok_or("`~` was used but HOME is not set")?;
        return Ok(home.join(text.trim_start_matches('~').trim_start_matches('/')));
    }
    if text.starts_with('~') {
        return Err(format!("`{text}`: only `~/` (your home folder) is understood"));
    }
    Ok(path.to_path_buf())
}

/// Write `bytes` to `target` all at once: a temporary file in the same folder,
/// then a link (fails if the name is taken) or, with `overwrite`, a rename.
pub fn write_file(roots: &Roots, target: &Path, bytes: &[u8], overwrite: bool) -> Result<(), String> {
    if !overwrite && fs::symlink_metadata(target).is_ok() {
        return Err(exists_error(roots, target));
    }
    let folder = target.parent().ok_or("no folder")?;
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or_default();
    let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let temp = folder.join(format!(".{name}.cookie-{}-{stamp}.tmp", std::process::id()));
    let result = (|| {
        let mut file = fs::OpenOptions::new().write(true).create_new(true).open(&temp).map_err(|e| e.to_string())?;
        file.write_all(bytes).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        drop(file);
        if overwrite {
            return fs::rename(&temp, target).map_err(|e| e.to_string());
        }
        match fs::hard_link(&temp, target) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Err(exists_error(roots, target)),
            // volumes without hard links (exFAT) get check-then-rename; a file
            // created in the same instant could be replaced.
            Err(_) if fs::symlink_metadata(target).is_err() => fs::rename(&temp, target).map_err(|e| e.to_string()),
            Err(_) => Err(exists_error(roots, target)),
        }
    })();
    let _ = fs::remove_file(&temp);
    result.map_err(|e| if e.contains("already exists") { e } else { format!("could not write {}: {e}", roots.show(target)) })
}

fn exists_error(roots: &Roots, target: &Path) -> String {
    format!(
        "{} already exists. Nothing was written. Use a new name such as {}, or pass `overwrite: true` to replace it.",
        roots.show(target),
        roots.show(&free_name(target))
    )
}

/// `report.xlsx` → `report-2.xlsx`, the first name not taken.
pub fn free_name(target: &Path) -> PathBuf {
    let stem = target.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = target.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    (2..1000)
        .map(|n| target.with_file_name(format!("{stem}-{n}{ext}")))
        .find(|p| fs::symlink_metadata(p).is_err())
        .unwrap_or_else(|| target.to_path_buf())
}

/// A file's bytes, at most `MAX_READ_BYTES`.
pub fn read_bytes(path: &Path) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    fs::File::open(path)
        .and_then(|f| f.take(MAX_READ_BYTES + 1).read_to_end(&mut bytes))
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_READ_BYTES {
        return Err("the file is larger than 10 MB".into());
    }
    Ok(bytes)
}

pub fn human_size(bytes: u64) -> String {
    match bytes {
        b if b < 1024 => format!("{b} bytes"),
        b if b < 1024 * 1024 => format!("{:.1} KB", b as f64 / 1024.0),
        b => format!("{:.1} MB", b as f64 / (1024.0 * 1024.0)),
    }
}

/// The lower-case extension of a path.
pub fn extension(path: &Path) -> String {
    path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> (tempfile::TempDir, tempfile::TempDir, Roots) {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let roots = Roots::new(&[a.path().to_path_buf()], Some(a.path().to_path_buf())).unwrap();
        (a, b, roots)
    }

    #[test]
    fn a_file_in_a_root_is_allowed() {
        let (a, _b, roots) = setup();
        let target = roots.write_target(&a.path().join("x.csv").to_string_lossy(), false).unwrap();
        assert_eq!(target, fs::canonicalize(a.path()).unwrap().join("x.csv"));
        // `~/` is the home folder, a relative path the first root.
        assert_eq!(roots.write_target("~/y.csv", false).unwrap(), fs::canonicalize(a.path()).unwrap().join("y.csv"));
        assert_eq!(roots.write_target("z.csv", false).unwrap(), fs::canonicalize(a.path()).unwrap().join("z.csv"));
    }

    #[test]
    fn dot_dot_is_refused_even_when_it_stays_inside() {
        let (a, _b, roots) = setup();
        fs::create_dir(a.path().join("sub")).unwrap();
        let raw = a.path().join("sub/../x.csv");
        assert!(roots.write_target(&raw.to_string_lossy(), false).unwrap_err().contains(".."));
        assert!(roots.write_target("../escape.csv", false).unwrap_err().contains(".."));
    }

    #[test]
    fn another_folder_is_refused() {
        let (_a, b, roots) = setup();
        let raw = b.path().join("x.csv");
        assert!(roots.write_target(&raw.to_string_lossy(), false).unwrap_err().contains("outside"));
        fs::write(&raw, "secret").unwrap();
        assert!(roots.read_target(&raw.to_string_lossy()).unwrap_err().contains("outside"));
        assert!(roots.write_target("/etc/passwd", true).unwrap_err().contains("outside"));
        assert!(roots.write_target("~root/x", false).is_err());
    }

    #[test]
    fn a_symlink_out_of_the_root_is_refused() {
        let (a, b, roots) = setup();
        std::os::unix::fs::symlink(b.path(), a.path().join("link")).unwrap();
        let through = a.path().join("link/x.csv");
        assert!(roots.write_target(&through.to_string_lossy(), false).unwrap_err().contains("outside"));
        assert!(roots.write_target(&a.path().join("link/new/x.csv").to_string_lossy(), true).unwrap_err().contains("outside"));
        // A symlinked file pointing out is refused for reading.
        fs::write(b.path().join("secret.txt"), "s").unwrap();
        std::os::unix::fs::symlink(b.path().join("secret.txt"), a.path().join("s.txt")).unwrap();
        assert!(roots.read_target(&a.path().join("s.txt").to_string_lossy()).unwrap_err().contains("outside"));
        // Overwriting a symlink replaces the link, never the file it points to.
        let target = roots.write_target(&a.path().join("s.txt").to_string_lossy(), false).unwrap();
        assert!(write_file(&roots, &target, b"new", false).unwrap_err().contains("already exists"));
        write_file(&roots, &target, b"new", true).unwrap();
        assert_eq!(fs::read_to_string(b.path().join("secret.txt")).unwrap(), "s");
    }

    #[test]
    fn a_second_root_is_allowed() {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let roots = Roots::new(&[a.path().to_path_buf(), b.path().to_path_buf()], None).unwrap();
        assert!(roots.write_target(&b.path().join("x.csv").to_string_lossy(), false).is_ok());
    }

    #[test]
    fn missing_folders_need_create_dirs() {
        let (a, _b, roots) = setup();
        let raw = a.path().join("new/deeper/x.csv");
        assert!(roots.write_target(&raw.to_string_lossy(), false).unwrap_err().contains("create_dirs"));
        let target = roots.write_target(&raw.to_string_lossy(), true).unwrap();
        assert!(target.parent().unwrap().is_dir());
    }

    #[test]
    fn an_existing_file_is_not_overwritten() {
        let (a, _b, roots) = setup();
        let target = roots.write_target(&a.path().join("x.csv").to_string_lossy(), false).unwrap();
        write_file(&roots, &target, b"one", false).unwrap();
        let error = write_file(&roots, &target, b"two", false).unwrap_err();
        assert!(error.contains("already exists") && error.contains("x-2.csv"), "{error}");
        assert_eq!(fs::read(&target).unwrap(), b"one");
        write_file(&roots, &target, b"two", true).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"two");
        // No temporary files are left behind.
        assert_eq!(fs::read_dir(a.path()).unwrap().count(), 1);
    }

    #[test]
    fn reading_is_capped_at_ten_megabytes() {
        let (a, _b, roots) = setup();
        let big = a.path().join("big.txt");
        fs::File::create(&big).unwrap().set_len(MAX_READ_BYTES + 1).unwrap();
        assert!(roots.read_target(&big.to_string_lossy()).unwrap_err().contains("10 MB"));
    }
}
