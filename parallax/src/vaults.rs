//! Vaults an agent keeps: a whole Linux computer of its own, with a desktop.
//!
//! - **Its own machine.** Each vault is a Firecracker microVM booted from the
//!   host's vault image (`<images>/vmlinux`, `<images>/rootfs.ext4`): its own
//!   kernel, its own disk (a copy of the image, made once), no network, and a
//!   hidden desktop (Xvfb, the accessibility bus) its apps draw on.
//! - **Hands inside.** `look` and `act` run Cookie Hands in the vault
//!   (`hands look`, `hands act`): the same outline with refs, the same steps.
//! - **Asleep is files.** `sleep` pauses it and writes its memory and state to
//!   disk; the next use restores it exactly where it was, in about a second.
//! - **Each agent sees only its own** (vault names are kept per owner).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use serde_json::{json, Value};

use crate::sizes::{Vault, VaultImage};

/// Running vaults, by their key (`owner/name`).
fn running() -> &'static tokio::sync::Mutex<HashMap<String, Vault>> {
    static R: OnceLock<tokio::sync::Mutex<HashMap<String, Vault>>> = OnceLock::new();
    R.get_or_init(Default::default)
}

/// One open at a time per vault, so two calls never boot it twice.
fn opening() -> &'static Mutex<std::collections::HashSet<String>> {
    static O: OnceLock<Mutex<std::collections::HashSet<String>>> = OnceLock::new();
    O.get_or_init(Default::default)
}

/// Where the vault image lives: `PARALLAX_VAULT_IMAGES`, else `<home>/images`.
fn images(home: &Path) -> PathBuf {
    std::env::var_os("PARALLAX_VAULT_IMAGES").map(PathBuf::from).unwrap_or_else(|| home.join("images"))
}

/// A name a person or agent can read, safe as a folder: letters, digits, - and _.
fn clean(name: &str) -> Result<String, String> {
    let n: String = name.trim().chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '-' }).collect();
    let n = n.trim_matches('-').chars().take(40).collect::<String>();
    if n.is_empty() {
        Err("Give the vault a name, like \"spreadsheets\".".into())
    } else {
        Ok(n)
    }
}

fn owner_dir(owner: &str) -> String {
    clean(owner).unwrap_or_else(|_| "local".into())
}

fn dir_of(home: &Path, owner: &str, name: &str) -> PathBuf {
    home.join("vaults").join(owner_dir(owner)).join(name)
}

fn key(owner: &str, name: &str) -> String {
    format!("{}/{name}", owner_dir(owner))
}

/// Quote for `sh -c`: one argument, whatever it holds.
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// The vaults an owner has: awake or asleep.
pub async fn list(home: &Path, owner: &str) -> Value {
    let run = running().lock().await;
    let base = home.join("vaults").join(owner_dir(owner));
    let mut out = Vec::new();
    for e in std::fs::read_dir(&base).into_iter().flatten().flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        let awake = run.contains_key(&key(owner, &name));
        let asleep = e.path().join("state").exists();
        out.push(json!({"name": name, "state": if awake { "awake" } else if asleep { "asleep" } else { "off" }}));
    }
    json!(out)
}

/// Open a vault: wake it from its snapshot, or boot it fresh (the first time, its disk is copied from the image).
pub async fn open(home: &Path, owner: &str, name: &str) -> Result<Value, String> {
    let name = clean(name)?;
    let k = key(owner, &name);
    if running().lock().await.contains_key(&k) {
        return Ok(json!({"vault": name, "state": "awake"}));
    }
    if !opening().lock().unwrap().insert(k.clone()) {
        return Err("That vault is opening already; try again in a moment.".into());
    }
    let r = open_inner(home, owner, &name, &k).await;
    opening().lock().unwrap().remove(&k);
    r
}

async fn open_inner(home: &Path, owner: &str, name: &str, k: &str) -> Result<Value, String> {
    let imgs = images(home);
    let kernel = imgs.join("vmlinux");
    let base = imgs.join("rootfs.ext4");
    if !kernel.exists() || !base.exists() {
        return Err(format!("This host has no vault image yet ({}).", imgs.display()));
    }
    let dir = dir_of(home, owner, name);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let disk = dir.join("disk.ext4");
    let started = std::time::Instant::now();
    let fresh = !disk.exists();
    if fresh {
        let ok = tokio::process::Command::new("cp").arg("--reflink=auto").arg("--sparse=always").arg(&base).arg(&disk).status().await.map_err(|e| e.to_string())?.success();
        if !ok {
            return Err("Couldn't make the vault's disk.".into());
        }
    }
    let image = VaultImage { kernel, rootfs: disk, vcpus: 2, mem_mib: 2048 };
    let (state, mem) = (dir.join("state"), dir.join("mem"));
    // A stale socket from before would stop Firecracker from binding it again.
    let rt = dir.join("run");
    let _ = std::fs::remove_dir_all(&rt);
    let snapshot = (state.exists() && mem.exists()).then_some((state.as_path(), mem.as_path()));
    let restored = snapshot.is_some();
    let v = Vault::start(name, &rt, &image, snapshot).await?;
    // Wait for the agent inside (a fresh boot takes a few seconds; a restore, none).
    let mut ready = false;
    for _ in 0..60 {
        if v.exec("true", 5).await.is_ok() {
            ready = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
    }
    if !ready {
        v.stop().await;
        return Err("The vault started but its agent never answered.".into());
    }
    running().lock().await.insert(k.to_string(), v);
    Ok(json!({"vault": name, "state": "awake", "how": if restored { "woke from its snapshot" } else if fresh { "booted for the first time" } else { "booted" }, "ms": started.elapsed().as_millis() as u64}))
}

/// Run a shell command in a vault (its desktop is `DISPLAY=:0`). Output is cut at 16 KB.
pub async fn run(home: &Path, owner: &str, name: &str, command: &str, timeout: u64) -> Result<Value, String> {
    let name = clean(name)?;
    let k = key(owner, &name);
    if !running().lock().await.contains_key(&k) {
        open(home, owner, &name).await?;
    }
    let run = running().lock().await;
    let v = run.get(&k).ok_or("The vault isn't open.")?;
    let (code, output) = v.exec(command, timeout.clamp(1, 600)).await?;
    let output = if output.len() > 16_000 { format!("{}…", &output[..output.char_indices().nth(16_000).map(|(i, _)| i).unwrap_or(output.len())]) } else { output };
    Ok(json!({"code": code, "output": output}))
}

/// Start an app on the vault's desktop, detached, so the call returns at once.
pub async fn launch(home: &Path, owner: &str, name: &str, app: &str) -> Result<Value, String> {
    let cmd = format!("setsid -f sh -c {} >/dev/null 2>&1 </dev/null; sleep 1; echo started", sh_quote(app));
    run(home, owner, name, &cmd, 15).await
}

/// Cookie Hands inside the vault: `hands look` and `hands act`.
pub async fn look(home: &Path, owner: &str, name: &str, app: Option<&str>) -> Result<Value, String> {
    let app = app.map(|a| format!(" --app {}", sh_quote(a))).unwrap_or_default();
    run(home, owner, name, &format!("hands look{app}"), 30).await
}

pub async fn act(home: &Path, owner: &str, name: &str, app: Option<&str>, steps: &Value) -> Result<Value, String> {
    let app = app.map(|a| format!(" --app {}", sh_quote(a))).unwrap_or_default();
    run(home, owner, name, &format!("hands act{app} --steps {}", sh_quote(&steps.to_string())), 60).await
}

/// Sleep a vault: pause it, write its memory and state to disk, stop it. Free while asleep.
pub async fn sleep(home: &Path, owner: &str, name: &str) -> Result<Value, String> {
    let name = clean(name)?;
    let v = running().lock().await.remove(&key(owner, &name)).ok_or("That vault isn't awake.")?;
    let dir = dir_of(home, owner, &name);
    let (state, mem) = (dir.join("state"), dir.join("mem"));
    let r = v.snapshot(&state, &mem).await;
    v.stop().await;
    r?;
    Ok(json!({"vault": name, "state": "asleep"}))
}

/// Sleep every awake vault (the host is going to sleep).
pub async fn sleep_all(home: &Path) -> usize {
    let keys: Vec<String> = running().lock().await.keys().cloned().collect();
    let mut n = 0;
    for k in keys {
        if let Some((owner, name)) = k.split_once('/') {
            if sleep(home, owner, name).await.is_ok() {
                n += 1;
            }
        }
    }
    n
}

/// Throw a vault away: its disk, memory and state.
pub async fn discard(home: &Path, owner: &str, name: &str) -> Result<Value, String> {
    let name = clean(name)?;
    if let Some(v) = running().lock().await.remove(&key(owner, &name)) {
        v.stop().await;
    }
    let dir = dir_of(home, owner, &name);
    if dir.starts_with(home.join("vaults")) && dir.exists() {
        std::fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
    }
    Ok(json!({"vault": name, "state": "gone"}))
}

/// How many are awake: the host stays up while any is.
pub async fn awake_count() -> usize {
    running().lock().await.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_safe_folders_and_each_owner_has_their_own() {
        assert_eq!(clean(" My Sheets! ").unwrap(), "My-Sheets");
        assert_eq!(clean("../../etc").unwrap(), "etc", "no way out of the vaults folder");
        assert!(clean("  ").is_err());
        let home = Path::new("/h");
        assert_ne!(dir_of(home, "anna", "x"), dir_of(home, "ben", "x"));
        assert!(dir_of(home, "../x", "y").starts_with("/h/vaults"));
        assert_eq!(sh_quote("it's"), "'it'\\''s'");
    }

    #[tokio::test]
    async fn without_an_image_a_vault_says_so() {
        let home = std::env::temp_dir().join(format!("px-vault-{}", std::process::id()));
        let e = open(&home, "a", "x").await.unwrap_err();
        assert!(e.contains("no vault image"), "{e}");
        assert_eq!(list(&home, "a").await, json!([]));
        let _ = std::fs::remove_dir_all(&home);
    }
}
