//! A cage per agent: its own folder, its own home, its own limits.
//!
//! Every command an agent runs (`run_command`, and the scripts of `run_code`)
//! runs inside its cage. On a Mac the cage is a Seatbelt profile written for
//! that one agent, deny-by-default (a standard base policy, unmodified; see THIRD_PARTY_NOTICES.md):
//!
//! - **Reads** the system (`/usr`, `/bin`, `/System`, `/Library`, `/opt`, …)
//!   and its own folder. Not your home folder, not Cookie's data, not another
//!   agent's folder, and never the credentials the harness hides
//!   (`sandbox::SECRET_PATHS`) — even if a later rule would allow them.
//! - **Writes** only its folder, and a home and temp folder of its own
//!   (`HOME` and `TMPDIR` point there), so tools that keep config or caches
//!   keep them in the cage, not in yours.
//! - **Network** off unless you turn it on for this agent. On, it can reach
//!   the internet (DNS and TLS included) but still cannot read or write
//!   outside its cage.
//! - **Limits** on CPU time, the size of any file it writes, and open files
//!   (`ulimit`, enforced by the kernel), besides the tool's own timeout.
//!   macOS does not enforce an address-space limit, so memory is bounded by
//!   the timeout rather than a cap; the person is told so.
//!
//! On Linux the harness's bubblewrap sandbox is used as before (writes only in
//! the folder, no network), with the same limits.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use cookie_harness::sandbox::{Sandbox, SECRET_PATHS};
use serde::{Deserialize, Serialize};

use crate::{util, Team};

/// What one agent's cage allows. Kept in `agents/<id>/cage.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct CageCfg {
    pub network: bool,
    /// CPU seconds one command may use.
    pub cpu_seconds: u32,
    /// The largest file one command may write, in MB.
    pub file_mb: u32,
    pub open_files: u32,
    /// How long one command may run, in seconds (wall clock).
    pub timeout_seconds: u32,
}

impl Default for CageCfg {
    fn default() -> Self {
        Self { network: false, cpu_seconds: 120, file_mb: 512, open_files: 256, timeout_seconds: 120 }
    }
}

impl CageCfg {
    fn clamp(mut self) -> Self {
        self.cpu_seconds = self.cpu_seconds.clamp(5, 3600);
        self.file_mb = self.file_mb.clamp(1, 20_000);
        self.open_files = self.open_files.clamp(32, 4096);
        self.timeout_seconds = self.timeout_seconds.clamp(10, 3600);
        self
    }
}

/// System places a caged command may read (and run programs from).
const SYSTEM_READ: &[&str] = &["/usr", "/bin", "/sbin", "/System", "/Library", "/opt", "/private/etc", "/private/var/db/timezone", "/private/var/select", "/dev", "/Applications/Xcode.app", "/Library/Developer/CommandLineTools"];

/// The Seatbelt profile for one cage. `secrets`: how many `SECRET_i` params follow.
pub fn profile(network: bool, secrets: usize) -> String {
    let mut p = String::from(include_str!("../../../src/seatbelt_base_policy.sbpl"));
    p.push('\n');
    // Metadata (stat, path lookup) anywhere: a program must be able to resolve
    // its own path. Contents only where listed below.
    p.push_str("(allow file-read-metadata)\n(allow file-read* (literal \"/\"))\n");
    for s in SYSTEM_READ {
        p.push_str(&format!("(allow file-read* (subpath \"{s}\"))\n"));
    }
    p.push_str("(allow file-read* file-write* (subpath (param \"CAGE\")))\n");
    p.push_str("(allow file-read* file-write* (subpath (param \"CAGE_HOME\")))\n");
    p.push_str("(allow file-read* file-write* (subpath (param \"CAGE_TMP\")))\n");
    p.push_str("(allow file-write* (regex #\"^/private/tmp/xcrun_db-\"))\n");
    if network {
        p.push_str(concat!(
            "(allow network-outbound)\n",
            "(allow network-inbound (local ip))\n",
            "(allow system-socket)\n",
            // DNS and certificate trust, which networking tools ask for by name.
            "(allow mach-lookup (global-name \"com.apple.dnssd.service\") (global-name \"com.apple.trustd\") (global-name \"com.apple.trustd.agent\") (global-name \"com.apple.SystemConfiguration.configd\") (global-name \"com.apple.SystemConfiguration.DNSConfiguration\"))\n",
            "(allow file-read* (literal \"/private/var/run/resolv.conf\") (subpath \"/private/var/run/mDNSResponder\"))\n",
            "(allow network-outbound (literal \"/private/var/run/mDNSResponder\"))\n",
        ));
    }
    // Last, so they win over every allow above.
    for i in 0..secrets {
        p.push_str(&format!("(deny file-read* file-write* (subpath (param \"SECRET_{i}\")))\n"));
    }
    p.push_str("(deny mach-lookup (xpc-service-name-prefix \"\"))\n(deny system-fcntl (fcntl-command 80 110))\n");
    p
}

/// One agent's cage, as a sandbox the harness's command tool runs through.
#[derive(Debug, Clone)]
pub struct Cage {
    pub folder: PathBuf,
    pub home: PathBuf,
    pub tmp: PathBuf,
    pub cfg: CageCfg,
    /// Whose credentials to hide.
    pub user_home: PathBuf,
}

fn canonical(p: &Path) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

impl Cage {
    /// `ulimit` lines, then the command itself (`exec`, so the limits hold for it).
    fn limits(&self) -> String {
        format!("ulimit -t {} 2>/dev/null; ulimit -f {} 2>/dev/null; ulimit -n {} 2>/dev/null; ", self.cfg.cpu_seconds, u64::from(self.cfg.file_mb) * 2048, self.cfg.open_files)
    }

    fn secrets(&self) -> Vec<PathBuf> {
        let mut out = Vec::new();
        for s in SECRET_PATHS {
            let p = self.user_home.join(s);
            if let Ok(real) = std::fs::canonicalize(&p) {
                if real != p {
                    out.push(real);
                }
            }
            out.push(p);
        }
        out
    }
}

impl Sandbox for Cage {
    fn name(&self) -> &'static str {
        "cage"
    }

    fn wrap(&self, program: &str, args: &[String], _writable: &Path) -> (String, Vec<String>) {
        // The command line: limits first, then the program, through `sh -c`
        // with the original program and arguments passed as "$@".
        let inner = format!("{}exec \"$@\"", self.limits());
        let env = |k: &str, v: &Path| format!("{k}={}", v.display());
        if cfg!(target_os = "macos") {
            let secrets = self.secrets();
            let mut argv = vec![
                "-p".to_string(),
                profile(self.cfg.network, secrets.len()),
                format!("-DCAGE={}", canonical(&self.folder).display()),
                format!("-DCAGE_HOME={}", canonical(&self.home).display()),
                format!("-DCAGE_TMP={}", canonical(&self.tmp).display()),
            ];
            for (i, s) in secrets.iter().enumerate() {
                argv.push(format!("-DSECRET_{i}={}", s.display()));
            }
            argv.extend(["--".into(), "/usr/bin/env".into(), env("HOME", &canonical(&self.home)), env("TMPDIR", &canonical(&self.tmp)), "/bin/sh".into(), "-c".into(), inner, "cage".into(), program.into()]);
            argv.extend_from_slice(args);
            (cookie_harness::sandbox::SANDBOX_EXEC.to_string(), argv)
        } else {
            // Linux: the harness's bubblewrap, with the cage's limits and home.
            let bw = cookie_harness::sandbox::Bubblewrap::with_home(&self.user_home);
            let mut wrapped = vec![env("HOME", &self.home), env("TMPDIR", &self.tmp), "/bin/sh".into(), "-c".into(), inner, "cage".into(), program.into()];
            wrapped.extend_from_slice(args);
            bw.wrap("/usr/bin/env", &wrapped, &self.folder)
        }
    }
}

impl Team {
    fn cage_path(&self, agent: &str) -> PathBuf {
        self.paths.agent(agent).join("cage.json")
    }

    pub fn cage_cfg(&self, agent: &str) -> CageCfg {
        util::read_json::<CageCfg>(&self.cage_path(agent)).clamp()
    }

    pub async fn set_cage(&self, agent: &str, patch: &serde_json::Value) -> Result<CageCfg, String> {
        self.agent(agent).await?;
        let mut c = self.cage_cfg(agent);
        if let Some(v) = patch.get("network").and_then(|v| v.as_bool()) {
            c.network = v;
        }
        for (k, f) in [("cpu_seconds", &mut c.cpu_seconds), ("file_mb", &mut c.file_mb), ("open_files", &mut c.open_files), ("timeout_seconds", &mut c.timeout_seconds)] {
            if let Some(v) = patch.get(k).and_then(|v| v.as_u64()) {
                *f = v.min(u32::MAX as u64) as u32;
            }
        }
        let c = c.clamp();
        util::write_json(&self.cage_path(agent), &c)?;
        Ok(c)
    }

    /// This agent's cage, made ready on disk. `None` where no sandbox can run
    /// (then no command tool is offered at all).
    pub fn cage(&self, agent: &str) -> Option<Arc<Cage>> {
        cookie_harness::sandbox::detect().filter(|s| s.confines())?;
        let home = self.paths.agent(agent).join("cage-home");
        let tmp = self.paths.agent(agent).join("cage-tmp");
        let folder = self.paths.work(agent);
        for d in [&home, &tmp, &folder] {
            std::fs::create_dir_all(d).ok()?;
        }
        let user_home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/var/empty"));
        Some(Arc::new(Cage { folder, home, tmp, cfg: self.cage_cfg(agent), user_home }))
    }

    /// What the person sees about an agent's cage.
    pub fn cage_view(&self, agent: &str) -> serde_json::Value {
        let cfg = self.cage_cfg(agent);
        let size = |p: PathBuf| -> u64 { dir_size(&p) };
        serde_json::json!({
            "available": cookie_harness::sandbox::detect().is_some_and(|s| s.confines()),
            "kind": if cfg!(target_os = "macos") { "seatbelt" } else { "bubblewrap" },
            "folder": self.paths.work(agent).to_string_lossy(),
            "cfg": cfg,
            "bytes": size(self.paths.work(agent)) + size(self.paths.agent(agent).join("cage-home")) + size(self.paths.agent(agent).join("cage-tmp")),
            "memory_capped": !cfg!(target_os = "macos"),
        })
    }
}

fn dir_size(p: &Path) -> u64 {
    let Ok(m) = std::fs::symlink_metadata(p) else { return 0 };
    if m.is_dir() {
        std::fs::read_dir(p).into_iter().flatten().flatten().map(|e| dir_size(&e.path())).sum()
    } else {
        m.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secrets_are_denied_last_and_network_only_when_on() {
        let off = profile(false, 2);
        let on = profile(true, 2);
        assert!(!off.contains("network-outbound") && on.contains("(allow network-outbound)"));
        let last_allow = off.rfind("(allow file-read* file-write* (subpath (param \"CAGE_TMP\")))").unwrap();
        assert!(off.rfind("SECRET_1").unwrap() > last_allow, "the secret denials come after every allow");
        assert!(!off.contains("(allow file-read*)\n"), "never read-anywhere");
    }

    #[test]
    fn limits_are_clamped() {
        let c = CageCfg { cpu_seconds: 0, file_mb: 0, open_files: 1, timeout_seconds: 1, network: false }.clamp();
        assert_eq!((c.cpu_seconds, c.file_mb, c.open_files, c.timeout_seconds), (5, 1, 32, 10));
    }

    /// The real cage on this Mac: its folder writable, the home folder unreadable,
    /// another agent's folder unreadable, no network unless on.
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn the_cage_holds_on_this_mac() {
        use cookie_harness::Tool;
        if cookie_harness::sandbox::detect().is_none() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let root = canonical(dir.path());
        let me = root.join("me");
        let other = root.join("other");
        for d in ["work", "home", "tmp"] {
            std::fs::create_dir_all(me.join(d)).unwrap();
        }
        std::fs::create_dir_all(&other).unwrap();
        std::fs::write(other.join("secret.txt"), "theirs").unwrap();
        let cage = Cage { folder: me.join("work"), home: me.join("home"), tmp: me.join("tmp"), cfg: CageCfg::default(), user_home: root.clone() };
        let run = |cage: Cage, cmd: String| async move {
            let t = cookie_harness::sandbox::command_tool("run", Arc::new(cage.clone()), &cage.folder).unwrap();
            t.call(serde_json::json!({"command": cmd})).await.map(|o| o.to_string()).unwrap_or_else(|e| e.to_string())
        };
        let out = run(cage.clone(), "echo hi > mine.txt && cat mine.txt && echo $HOME".into()).await;
        assert!(out.contains("hi") && out.contains("/me/home"), "{out}");
        let out = run(cage.clone(), format!("cat {}/secret.txt", other.display())).await;
        assert!(!out.contains("theirs"), "another agent's folder is closed: {out}");
        let out = run(cage.clone(), format!("echo x > {}/escape.txt; ls {}", other.display(), other.display())).await;
        assert!(!other.join("escape.txt").exists(), "no writes outside: {out}");
        let out = run(cage.clone(), "/usr/bin/curl -sS -m 5 -o /dev/null -w '%{http_code}' https://example.com".into()).await;
        assert!(!out.contains("200"), "no network by default: {out}");
        // The person's real home folder is closed too, and Cookie's keys never reach a command.
        let real_home = std::env::var("HOME").unwrap();
        let out = run(cage.clone(), format!("ls {real_home}/Documents >/dev/null 2>&1 && echo OPEN || echo CLOSED; echo key=${{ANTHROPIC_API_KEY:-none}}")).await;
        assert!(out.contains("CLOSED") && out.contains("key=none"), "{out}");
        // A CPU-time limit the kernel enforces.
        let tight = Cage { cfg: CageCfg { cpu_seconds: 1, ..CageCfg::default() }, ..cage.clone() };
        let out = run(tight, "ulimit -t".into()).await;
        assert!(out.contains('1'), "{out}");
        if std::env::var("COOKIE_NET_TESTS").is_ok() {
            let open = Cage { cfg: CageCfg { network: true, ..CageCfg::default() }, ..cage.clone() };
            let out = run(open, "/usr/bin/curl -sS -m 10 -o /dev/null -w '%{http_code}' https://example.com".into()).await;
            assert!(out.contains("200"), "network when on: {out}");
        }
    }
}
