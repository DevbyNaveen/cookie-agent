//! Embed Cookie's skill catalog (desktop/skills-catalog) in the binary, so
//! every install — desktop, home runner, cloud — offers the same skills.
use std::path::Path;

fn walk(root: &Path, dir: &Path, out: &mut Vec<String>) {
    let mut entries: Vec<_> = std::fs::read_dir(dir).into_iter().flatten().flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for e in entries {
        let p = e.path();
        let name = e.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        if p.is_dir() {
            walk(root, &p, out);
        } else if let Ok(rel) = p.strip_prefix(root) {
            out.push(rel.to_string_lossy().replace('\\', "/"));
        }
    }
}

fn main() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../skills-catalog");
    println!("cargo:rerun-if-changed={}", root.display());
    let mut files = Vec::new();
    walk(&root, &root, &mut files);
    let mut src = String::from("/// Cookie's skill catalog: (path inside the catalog, contents).\npub static FILES: &[(&str, &str)] = &[\n");
    for f in &files {
        if f.contains('/') {
            println!("cargo:rerun-if-changed={}", root.join(f).display());
            src.push_str(&format!("    ({f:?}, include_str!({:?})),\n", root.join(f).canonicalize().unwrap().display().to_string()));
        }
    }
    src.push_str("];\n");
    let out = Path::new(&std::env::var("OUT_DIR").unwrap()).join("catalog.rs");
    std::fs::write(out, src).unwrap();
}
