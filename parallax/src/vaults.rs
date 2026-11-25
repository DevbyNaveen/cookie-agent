//! Vaults an agent keeps: a whole Linux computer of its own, with a desktop.
//!
//! - **Its own machine.** Each vault is a Firecracker microVM booted from the
//!   host's vault image (`<images>/vmlinux`, `<images>/rootfs.ext4`): its own
//!   kernel, its own disk (a copy of the image, made once), no network, and a
//!   hidden desktop (Xvfb, the accessibility bus) its apps draw on.
//! - **Hands inside.** `look` and `act` run Cookie Hands in the vault
//!   (`hands look`, `hands act`): the same outline with refs, the same steps.
//! - **Asleep is files.** `sleep` pauses it at once and writes its memory and
//!   state to disk in the background; the next use waits for that, then
//!   restores it exactly where it was, in well under a second.
//! - **The internet, only when asked.** A vault made with `network` gets its
//!   own tap device and a /30 of its own behind the host's NAT; the host lets
//!   it reach the internet and nothing else: not the instance's metadata
//!   (its credentials), not the private network, not other vaults, not the
//!   host. Without it, a vault has no network at all. The choice is made when
//!   the vault is made, and kept.
//! - **Each agent sees only its own** (vault names are kept per owner).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::{json, Value};

use crate::sizes::{Vault, VaultImage, VaultNet};

/// Running vaults, by their key (`owner/name`). Shared, so a long command in
/// one vault never holds up another.
fn running() -> &'static tokio::sync::Mutex<HashMap<String, Arc<Vault>>> {
    static R: OnceLock<tokio::sync::Mutex<HashMap<String, Arc<Vault>>>> = OnceLock::new();
    R.get_or_init(Default::default)
}

/// Vaults writing themselves to disk right now.
fn sleeping() -> &'static Mutex<std::collections::HashSet<String>> {
    static S: OnceLock<Mutex<std::collections::HashSet<String>>> = OnceLock::new();
    S.get_or_init(Default::default)
}

/// The /30 for vault number `n`: 172.30.0.0/16 holds 16,384 of them.
fn net_for(n: u32) -> VaultNet {
    let base = n * 4;
    let ip = |x: u32| format!("172.30.{}.{}", (base + x) >> 8, (base + x) & 0xff);
    VaultNet { tap: format!("pxt{n}"), guest_mac: format!("06:00:ac:1e:{:02x}:{:02x}", (n >> 8) & 0xff, n & 0xff), host_ip: ip(1), guest_ip: ip(2) }
}

/// The smallest vault number no vault on this host uses.
fn free_net_number(home: &Path) -> u32 {
    let mut used = std::collections::HashSet::new();
    for owner in std::fs::read_dir(home.join("vaults")).into_iter().flatten().flatten() {
        for v in std::fs::read_dir(owner.path()).into_iter().flatten().flatten() {
            if let Ok(t) = std::fs::read_to_string(v.path().join("net")) {
                if let Ok(n) = t.trim().parse::<u32>() {
                    used.insert(n);
                }
            }
        }
    }
    (0..16_384).find(|n| !used.contains(n)).unwrap_or(0)
}

/// The host side of a vault's link: its tap device, up, with the host's address.
async fn tap_up(n: &VaultNet) -> Result<(), String> {
    let sh = |c: String| async move { tokio::process::Command::new("sh").arg("-c").arg(c).output().await.map(|o| o.status.success()).unwrap_or(false) };
    // Made fresh each time, so a restored vault finds its device as it left it.
    sh(format!("ip link del {} 2>/dev/null", n.tap)).await;
    if !sh(format!("ip tuntap add dev {} mode tap && ip addr add {}/30 dev {} && ip link set {} up", n.tap, n.host_ip, n.tap, n.tap)).await {
        return Err("Couldn't set up the vault's network on the host.".into());
    }
    Ok(())
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
        let going = sleeping().lock().unwrap().contains(&key(owner, &name));
        let asleep = e.path().join("state").exists();
        let network = e.path().join("net").exists();
        out.push(json!({"name": name, "network": network, "state": if awake { "awake" } else if going { "going to sleep" } else if asleep { "asleep" } else { "off" }}));
    }
    json!(out)
}

/// Open a vault: wake it from its snapshot, or boot it fresh (the first time, its disk is copied from the image).
pub async fn open(home: &Path, owner: &str, name: &str, network: Option<bool>) -> Result<Value, String> {
    let name = clean(name)?;
    let k = key(owner, &name);
    // Still writing itself to disk: wait for that (at most three minutes).
    for _ in 0..360 {
        if !sleeping().lock().unwrap().contains(&k) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
    if running().lock().await.contains_key(&k) {
        return Ok(json!({"vault": name, "state": "awake"}));
    }
    if !opening().lock().unwrap().insert(k.clone()) {
        return Err("That vault is opening already; try again in a moment.".into());
    }
    let r = open_inner(home, owner, &name, &k, network).await;
    opening().lock().unwrap().remove(&k);
    r
}

async fn open_inner(home: &Path, owner: &str, name: &str, k: &str, network: Option<bool>) -> Result<Value, String> {
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
    // Its network, chosen when it was made and kept: a number for its /30, or none.
    let net_file = dir.join("net");
    if fresh && network.unwrap_or(false) {
        std::fs::write(&net_file, free_net_number(home).to_string()).map_err(|e| e.to_string())?;
    }
    let net = std::fs::read_to_string(&net_file).ok().and_then(|t| t.trim().parse::<u32>().ok()).map(net_for);
    if let Some(n) = &net {
        tap_up(n).await?;
    }
    let image = VaultImage { kernel, rootfs: disk, vcpus: 2, mem_mib: 2048 };
    let (state, mem) = (dir.join("state"), dir.join("mem"));
    // A stale socket from before would stop Firecracker from binding it again.
    let rt = dir.join("run");
    let _ = std::fs::remove_dir_all(&rt);
    let snapshot = (state.exists() && mem.exists()).then_some((state.as_path(), mem.as_path()));
    let restored = snapshot.is_some();
    let v = Vault::start(name, &rt, &image, snapshot, net.as_ref()).await?;
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
    running().lock().await.insert(k.to_string(), Arc::new(v));
    Ok(json!({"vault": name, "state": "awake", "network": net.is_some(), "how": if restored { "woke from its snapshot" } else if fresh { "booted for the first time" } else { "booted" }, "ms": started.elapsed().as_millis() as u64}))
}

/// Run a shell command in a vault (its desktop is `DISPLAY=:0`). Output is cut at 16 KB.
pub async fn run(home: &Path, owner: &str, name: &str, command: &str, timeout: u64) -> Result<Value, String> {
    let name = clean(name)?;
    let k = key(owner, &name);
    if !running().lock().await.contains_key(&k) {
        open(home, owner, &name, None).await?;
    }
    let v = running().lock().await.get(&k).cloned().ok_or("The vault isn't open.")?;
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

/// Take a vault out of the running set and wait until no call is using it.
async fn take(k: &str) -> Option<Vault> {
    let arc = running().lock().await.remove(k)?;
    let mut arc = arc;
    for _ in 0..600 {
        match Arc::try_unwrap(arc) {
            Ok(v) => return Some(v),
            Err(a) => {
                arc = a;
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        }
    }
    None
}

async fn write_to_disk(home: &Path, owner: &str, name: &str, v: Vault) -> Result<(), String> {
    let dir = dir_of(home, owner, name);
    let r = v.snapshot(&dir.join("state"), &dir.join("mem")).await;
    v.stop().await;
    r
}

/// Sleep a vault: it stops at once and writes its memory and state to disk in
/// the background. Free while asleep; the next use wakes it exactly there.
pub async fn sleep(home: &Path, owner: &str, name: &str) -> Result<Value, String> {
    let name = clean(name)?;
    let k = key(owner, &name);
    if !running().lock().await.contains_key(&k) {
        return Err("That vault isn't awake.".into());
    }
    sleeping().lock().unwrap().insert(k.clone());
    let (home, owner2, name2) = (home.to_path_buf(), owner.to_string(), name.clone());
    tokio::spawn(async move {
        if let Some(v) = take(&k).await {
            if let Err(e) = write_to_disk(&home, &owner2, &name2, v).await {
                eprintln!("parallax: vault {k} couldn't sleep: {e}");
            }
        }
        sleeping().lock().unwrap().remove(&k);
    });
    Ok(json!({"vault": name, "state": "going to sleep", "note": "It's being written to disk; using it again wakes it as soon as that's done."}))
}

/// Sleep every awake vault and wait until each is on disk (the host is going to sleep).
pub async fn sleep_all(home: &Path) -> usize {
    let keys: Vec<String> = running().lock().await.keys().cloned().collect();
    let mut n = 0;
    for k in keys {
        if let (Some((owner, name)), Some(v)) = (k.split_once('/'), take(&k).await) {
            if write_to_disk(home, owner, name, v).await.is_ok() {
                n += 1;
            }
        }
    }
    // And any still writing in the background.
    for _ in 0..360 {
        if sleeping().lock().unwrap().is_empty() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
    n
}

/// Throw a vault away: its disk, memory and state.
pub async fn discard(home: &Path, owner: &str, name: &str) -> Result<Value, String> {
    let name = clean(name)?;
    if let Some(v) = take(&key(owner, &name)).await {
        v.stop().await;
    }
    let dir = dir_of(home, owner, &name);
    if let Some(n) = std::fs::read_to_string(dir.join("net")).ok().and_then(|t| t.trim().parse::<u32>().ok()) {
        let _ = tokio::process::Command::new("ip").args(["link", "del", &net_for(n).tap]).output().await;
    }
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

    #[test]
    fn each_vault_gets_its_own_small_network() {
        let a = net_for(0);
        assert_eq!((a.host_ip.as_str(), a.guest_ip.as_str(), a.tap.as_str()), ("172.30.0.1", "172.30.0.2", "pxt0"));
        let b = net_for(64);
        assert_eq!((b.host_ip.as_str(), b.guest_ip.as_str()), ("172.30.1.1", "172.30.1.2"), "64 × 4 = 256: the next /24");
        assert!(net_for(16_383).tap.len() <= 15, "Linux device names are 15 characters at most");
        assert_ne!(net_for(1).guest_mac, net_for(2).guest_mac);
        let home = std::env::temp_dir().join(format!("px-net-{}", std::process::id()));
        std::fs::create_dir_all(home.join("vaults/a/one")).unwrap();
        std::fs::write(home.join("vaults/a/one/net"), "0").unwrap();
        assert_eq!(free_net_number(&home), 1, "a used number isn't given twice");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn without_an_image_a_vault_says_so() {
        let home = std::env::temp_dir().join(format!("px-vault-{}", std::process::id()));
        let e = open(&home, "a", "x", None).await.unwrap_err();
        assert!(e.contains("no vault image"), "{e}");
        assert_eq!(list(&home, "a").await, json!([]));
        let _ = std::fs::remove_dir_all(&home);
    }
}
