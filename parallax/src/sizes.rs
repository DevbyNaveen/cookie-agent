//! Three sizes, picked per task.
//!
//! - **Cell** — one pure function: a WebAssembly module run in-process by an
//!   interpreter (`wasmi`) with a fuel budget, no files, no network, no clock.
//!   Starts in well under a millisecond; for a formula, a parser, a check.
//! - **World** — a process in a cage on the world's copy-on-write folder: it
//!   reads the system and the world, writes only the world, no network unless
//!   asked, no keys in its environment, and CPU, file-size and open-file
//!   limits. Seatbelt on a Mac, bubblewrap on Linux.
//! - **Vault** — a Firecracker microVM, for a browser, untrusted code or
//!   another party's agent: its own kernel. Linux with KVM only; on a Mac it
//!   says so. Booted from a kernel and root image through Firecracker's API
//!   socket, snapshotted to disk when idle and restored from the snapshot
//!   (so many vaults start from one warm snapshot); a command runs inside
//!   through the guest agent on vsock (`parallax guest`, port 52).

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{json, Value};

/* ---------------- Cell ---------------- */

/// Run `func` exported by a WebAssembly module with i64 arguments, within
/// `fuel` units of work. The module may import nothing: a Cell touches
/// nothing outside itself.
pub fn cell_run(wasm: &[u8], func: &str, args: &[i64], fuel: u64) -> Result<Vec<i64>, String> {
    use wasmi::{Config, Engine, Linker, Module, Store, Val};
    let mut config = Config::default();
    config.consume_fuel(true);
    let engine = Engine::new(&config);
    let module = Module::new(&engine, wasm).map_err(|e| format!("Not a WebAssembly module: {e}"))?;
    if module.imports().len() > 0 {
        return Err("A cell's module may not import anything.".into());
    }
    let mut store = Store::new(&engine, ());
    store.set_fuel(fuel).map_err(|e| e.to_string())?;
    let linker = Linker::<()>::new(&engine);
    let instance = linker.instantiate(&mut store, &module).and_then(|p| p.start(&mut store)).map_err(|e| e.to_string())?;
    let f = instance.get_func(&store, func).ok_or_else(|| format!("The module has no function `{func}`."))?;
    let ty = f.ty(&store);
    if ty.params().len() != args.len() {
        return Err(format!("`{func}` takes {} arguments.", ty.params().len()));
    }
    let params: Vec<Val> = args.iter().zip(ty.params()).map(|(a, t)| match t {
        wasmi::core::ValType::I32 => Val::I32(*a as i32),
        _ => Val::I64(*a),
    }).collect();
    let mut results: Vec<Val> = ty.results().iter().map(|t| match t {
        wasmi::core::ValType::I32 => Val::I32(0),
        _ => Val::I64(0),
    }).collect();
    f.call(&mut store, &params, &mut results).map_err(|e| if store.get_fuel().is_ok_and(|f| f == 0) { "The cell ran out of fuel.".to_string() } else { e.to_string() })?;
    Ok(results.iter().map(|v| match v {
        Val::I32(x) => *x as i64,
        Val::I64(x) => *x,
        _ => 0,
    }).collect())
}

/* ---------------- World ---------------- */

const SYSTEM_READ: &[&str] = &["/usr", "/bin", "/sbin", "/System", "/Library", "/opt", "/private/etc", "/private/var/db/timezone", "/private/var/select", "/dev", "/Applications/Xcode.app", "/Library/Developer/CommandLineTools"];

fn seatbelt_profile(network: bool) -> String {
    let mut p = String::from(include_str!("seatbelt_base_policy.sbpl"));
    p.push_str("\n(allow file-read-metadata)\n(allow file-read* (literal \"/\"))\n");
    for s in SYSTEM_READ {
        p.push_str(&format!("(allow file-read* (subpath \"{s}\"))\n"));
    }
    p.push_str("(allow file-read* file-write* (subpath (param \"WORLD\")))\n(allow file-write* (regex #\"^/private/tmp/xcrun_db-\"))\n");
    if network {
        p.push_str("(allow network-outbound)\n(allow network-inbound (local ip))\n(allow network-bind (local ip \"localhost:*\"))\n(allow system-socket)\n(allow mach-lookup (global-name \"com.apple.dnssd.service\") (global-name \"com.apple.trustd\") (global-name \"com.apple.trustd.agent\") (global-name \"com.apple.SystemConfiguration.configd\") (global-name \"com.apple.SystemConfiguration.DNSConfiguration\"))\n(allow file-read* (literal \"/private/var/run/resolv.conf\") (subpath \"/private/var/run/mDNSResponder\"))\n(allow network-outbound (literal \"/private/var/run/mDNSResponder\"))\n");
    }
    p.push_str("(deny mach-lookup (xpc-service-name-prefix \"\"))\n(deny system-fcntl (fcntl-command 80 110))\n");
    p
}

/// The command line that runs `sh -c command` caged in `world`.
pub fn world_command(world: &Path, command: &str, network: bool) -> Result<(String, Vec<String>), String> {
    let world = std::fs::canonicalize(world).map_err(|e| e.to_string())?;
    let home = world.join(".parallax/home");
    let tmp = world.join(".parallax/tmp");
    std::fs::create_dir_all(&home).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
    let limits = "ulimit -t 300 2>/dev/null; ulimit -f 1048576 2>/dev/null; ulimit -n 512 2>/dev/null; ";
    let env = vec!["/usr/bin/env".to_string(), "-i".into(), format!("HOME={}", home.display()), format!("TMPDIR={}", tmp.display()), "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin".into(), "LANG=en_US.UTF-8".into(), "/bin/sh".into(), "-c".into(), format!("{limits}{command}")];
    if cfg!(target_os = "macos") {
        let mut argv = vec!["-p".to_string(), seatbelt_profile(network), format!("-DWORLD={}", world.display()), "--".into()];
        argv.extend(env);
        Ok(("/usr/bin/sandbox-exec".into(), argv))
    } else {
        let bwrap = ["/usr/bin/bwrap", "/bin/bwrap"].iter().find(|p| Path::new(p).exists()).ok_or("A world needs bubblewrap (bwrap) on Linux.")?;
        let w = world.display().to_string();
        let mut argv: Vec<String> = ["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp", "--bind", &w, &w, "--chdir", &w, "--die-with-parent", "--new-session"].iter().map(|s| s.to_string()).collect();
        if !network {
            argv.push("--unshare-net".into());
        }
        argv.push("--".into());
        argv.extend(env);
        Ok((bwrap.to_string(), argv))
    }
}

/// Run a shell command caged in a world: (exit code, stdout + stderr).
pub async fn world_run(world: &Path, command: &str, network: bool, timeout_secs: u64) -> Result<(i32, String), String> {
    let (prog, argv) = world_command(world, command, network)?;
    let child = tokio::process::Command::new(prog).args(argv).current_dir(world).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped()).kill_on_drop(true).spawn().map_err(|e| e.to_string())?;
    let out = tokio::time::timeout(Duration::from_secs(timeout_secs), child.wait_with_output()).await.map_err(|_| format!("It ran longer than {timeout_secs} seconds and was stopped."))?.map_err(|e| e.to_string())?;
    let mut text = String::from_utf8_lossy(&out.stdout).to_string();
    let err = String::from_utf8_lossy(&out.stderr);
    if !err.trim().is_empty() {
        text.push_str("\n");
        text.push_str(&err);
    }
    Ok((out.status.code().unwrap_or(-1), crate::util::clip(&text, 32_000)))
}

/* ---------------- Vault ---------------- */

/// What a vault boots from.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct VaultImage {
    pub kernel: PathBuf,
    pub rootfs: PathBuf,
    pub vcpus: u8,
    pub mem_mib: u32,
}

/// One microVM, driven through Firecracker's API socket.
pub struct Vault {
    pub id: String,
    pub api: PathBuf,
    pub vsock: PathBuf,
    child: Option<tokio::process::Child>,
}

/// Can this machine run vaults? Linux, `/dev/kvm`, and a `firecracker` binary.
pub fn vault_available() -> Result<PathBuf, String> {
    if !cfg!(target_os = "linux") {
        return Err("Vaults are Firecracker microVMs: they need Linux with KVM (a Parallax host). On a Mac, use a World.".into());
    }
    if !Path::new("/dev/kvm").exists() {
        return Err("This Linux machine has no /dev/kvm: vaults need hardware virtualisation.".into());
    }
    ["/usr/local/bin/firecracker", "/usr/bin/firecracker"].iter().map(PathBuf::from).find(|p| p.exists()).ok_or_else(|| "No firecracker binary in /usr/local/bin or /usr/bin.".into())
}

/// One HTTP request over Firecracker's Unix socket (its API is plain HTTP/1.1).
#[cfg(unix)]
async fn api(sock: &Path, method: &str, path: &str, body: &Value) -> Result<String, String> {
    // Writing or loading a snapshot moves the vault's whole memory: give it time.
    let wait = if path.starts_with("/snapshot") { 180 } else { 10 };
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut s = tokio::net::UnixStream::connect(sock).await.map_err(|e| format!("Firecracker's socket: {e}"))?;
    let b = body.to_string();
    let req = format!("{method} {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nAccept: application/json\r\nContent-Length: {}\r\n\r\n{b}", b.len());
    s.write_all(req.as_bytes()).await.map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; 16 * 1024];
    let n = tokio::time::timeout(Duration::from_secs(wait), s.read(&mut buf)).await.map_err(|_| "Firecracker didn't answer.")?.map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&buf[..n]).to_string();
    let status: u16 = text.split_whitespace().nth(1).and_then(|c| c.parse().ok()).unwrap_or(0);
    if !(200..300).contains(&status) {
        return Err(format!("Firecracker refused {method} {path}: {}", text.lines().last().unwrap_or("")));
    }
    Ok(text)
}

#[cfg(unix)]
impl Vault {
    /// Boot a vault from an image, or restore it from a snapshot (memory + state) when given one.
    pub async fn start(id: &str, runtime_dir: &Path, image: &VaultImage, snapshot: Option<(&Path, &Path)>) -> Result<Vault, String> {
        let bin = vault_available()?;
        let dir = runtime_dir.join(id);
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let api_sock = dir.join("api.sock");
        let vsock = dir.join("vsock.sock");
        let _ = std::fs::remove_file(&api_sock);
        let child = tokio::process::Command::new(bin).arg("--api-sock").arg(&api_sock).kill_on_drop(true).stdin(std::process::Stdio::null()).spawn().map_err(|e| e.to_string())?;
        for _ in 0..100 {
            if api_sock.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let v = Vault { id: id.into(), api: api_sock.clone(), vsock: vsock.clone(), child: Some(child) };
        match snapshot {
            Some((state, mem)) => {
                api(&api_sock, "PUT", "/snapshot/load", &json!({"snapshot_path": state, "mem_backend": {"backend_type": "File", "backend_path": mem}, "resume_vm": true})).await?;
            }
            None => {
                api(&api_sock, "PUT", "/boot-source", &json!({"kernel_image_path": image.kernel, "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"})).await?;
                api(&api_sock, "PUT", "/drives/rootfs", &json!({"drive_id": "rootfs", "path_on_host": image.rootfs, "is_root_device": true, "is_read_only": false})).await?;
                api(&api_sock, "PUT", "/machine-config", &json!({"vcpu_count": image.vcpus.max(1), "mem_size_mib": image.mem_mib.max(128)})).await?;
                api(&api_sock, "PUT", "/vsock", &json!({"guest_cid": 3, "uds_path": vsock})).await?;
                api(&api_sock, "PUT", "/actions", &json!({"action_type": "InstanceStart"})).await?;
            }
        }
        Ok(v)
    }

    /// Pause and write memory and state to disk: an idle vault costs only disk.
    pub async fn snapshot(&self, state: &Path, mem: &Path) -> Result<(), String> {
        api(&self.api, "PATCH", "/vm", &json!({"state": "Paused"})).await?;
        api(&self.api, "PUT", "/snapshot/create", &json!({"snapshot_type": "Full", "snapshot_path": state, "mem_file_path": mem})).await?;
        Ok(())
    }

    /// Run a command inside through the guest agent (vsock port 52): Firecracker's
    /// host side of vsock is a Unix socket that takes `CONNECT <port>`.
    pub async fn exec(&self, command: &str, timeout_secs: u64) -> Result<(i32, String), String> {
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
        let mut s = tokio::net::UnixStream::connect(&self.vsock).await.map_err(|e| format!("The vault's vsock: {e}"))?;
        s.write_all(b"CONNECT 52\n").await.map_err(|e| e.to_string())?;
        let mut r = BufReader::new(s);
        let mut ok = String::new();
        r.read_line(&mut ok).await.map_err(|e| e.to_string())?;
        if !ok.starts_with("OK") {
            return Err(format!("The guest agent isn't listening: {}", ok.trim()));
        }
        let mut s = r.into_inner();
        s.write_all(format!("{}\n", json!({"command": command, "timeout": timeout_secs})).as_bytes()).await.map_err(|e| e.to_string())?;
        let mut r = BufReader::new(s);
        let mut line = String::new();
        tokio::time::timeout(Duration::from_secs(timeout_secs + 5), r.read_line(&mut line)).await.map_err(|_| "The vault didn't answer in time.")?.map_err(|e| e.to_string())?;
        let v: Value = serde_json::from_str(line.trim()).map_err(|e| format!("The guest agent's answer: {e}"))?;
        Ok((v["code"].as_i64().unwrap_or(-1) as i32, v["output"].as_str().unwrap_or("").to_string()))
    }

    pub async fn stop(mut self) {
        let _ = api(&self.api, "PUT", "/actions", &json!({"action_type": "SendCtrlAltDel"})).await;
        if let Some(mut c) = self.child.take() {
            let _ = tokio::time::timeout(Duration::from_secs(3), c.wait()).await;
            let _ = c.kill().await;
        }
    }
}

/// The guest agent that runs inside a vault: listens on vsock port 52 and runs
/// one command per connection, answering `{code, output}` as one JSON line.
#[cfg(target_os = "linux")]
pub fn guest_agent() -> Result<(), String> {
    use std::io::{BufRead, BufReader, Write};
    use std::os::fd::FromRawFd;
    unsafe {
        let fd = libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM, 0);
        if fd < 0 {
            return Err("No vsock in this kernel.".into());
        }
        let mut addr: libc::sockaddr_vm = std::mem::zeroed();
        addr.svm_family = libc::AF_VSOCK as libc::sa_family_t;
        addr.svm_port = 52;
        addr.svm_cid = libc::VMADDR_CID_ANY;
        if libc::bind(fd, &addr as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_vm>() as u32) != 0 || libc::listen(fd, 8) != 0 {
            return Err("Couldn't listen on vsock port 52.".into());
        }
        loop {
            let c = libc::accept(fd, std::ptr::null_mut(), std::ptr::null_mut());
            if c < 0 {
                continue;
            }
            let stream = std::fs::File::from_raw_fd(c);
            let mut reader = BufReader::new(stream.try_clone().map_err(|e| e.to_string())?);
            let mut line = String::new();
            if reader.read_line(&mut line).is_err() {
                continue;
            }
            let req: Value = serde_json::from_str(line.trim()).unwrap_or_default();
            // A time limit the command can't outlast (coreutils' timeout, then a kill).
            let secs = req["timeout"].as_u64().unwrap_or(60).clamp(1, 600).to_string();
            let out = std::process::Command::new("/usr/bin/timeout").args(["--kill-after=2", &secs, "/bin/sh", "-c"]).arg(req["command"].as_str().unwrap_or("true")).output();
            let answer = match out {
                Ok(o) => json!({"code": o.status.code().unwrap_or(-1), "output": format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr))}),
                Err(e) => json!({"code": -1, "output": e.to_string()}),
            };
            let mut w = stream;
            let _ = writeln!(w, "{answer}");
        }
    }
}

#[cfg(not(target_os = "linux"))]
pub fn guest_agent() -> Result<(), String> {
    Err("The guest agent runs inside a Linux vault.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// (module (func (export "add") (param i64 i64) (result i64) local.get 0 local.get 1 i64.add))
    const ADD: &[u8] = &[0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 126, 126, 1, 126, 3, 2, 1, 0, 7, 7, 1, 3, 97, 100, 100, 0, 0, 10, 9, 1, 7, 0, 32, 0, 32, 1, 124, 11];
    /// (module (func (export "spin") (loop br 0)))
    const SPIN: &[u8] = &[0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 7, 8, 1, 4, 115, 112, 105, 110, 0, 0, 10, 9, 1, 7, 0, 3, 64, 12, 0, 11, 11];

    #[test]
    fn a_cell_computes_and_runs_out_of_fuel_rather_than_forever() {
        assert_eq!(cell_run(ADD, "add", &[40, 2], 10_000).unwrap(), vec![42]);
        assert!(cell_run(SPIN, "spin", &[], 10_000).unwrap_err().contains("fuel"));
        assert!(cell_run(b"nope", "x", &[], 10).is_err());
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn a_world_process_writes_only_its_world() {
        let d = tempfile::tempdir().unwrap();
        let w = std::fs::canonicalize(d.path()).unwrap().join("w");
        std::fs::create_dir_all(&w).unwrap();
        let outside = d.path().join("outside.txt");
        let (code, out) = world_run(&w, &format!("echo hi > in.txt; echo x > {}; cat in.txt", outside.display()), false, 20).await.unwrap();
        assert!(out.contains("hi"), "{out} {code}");
        assert!(w.join("in.txt").exists() && !outside.exists());
    }

    #[test]
    fn a_vault_says_where_it_can_run() {
        if !cfg!(target_os = "linux") {
            assert!(vault_available().unwrap_err().contains("Linux"));
        }
    }
}
