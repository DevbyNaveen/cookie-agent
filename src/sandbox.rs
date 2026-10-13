//! Running shell commands the model chose, confined: no network, writes
//! only inside one directory, read-only everywhere else.
//!
//! The command is the model's choice, so it is not guarded (a guard would
//! refuse every command). `command_tool` is `Effect::Write`: once a run has
//! read anything untrusted, the policy asks a person before each command,
//! showing it. The sandbox limits what a command that slips through can do.

use std::{
    path::{Path, PathBuf},
    process::Stdio,
    sync::{Arc, Mutex},
    time::Duration,
};

use async_trait::async_trait;
use serde_json::{json, Value};
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio_util::sync::CancellationToken;

use crate::{
    error::{Error, Result},
    tool::{Effect, Tool, ToolContext, ToolSpec},
};

/// Turns a command into one that runs confined.
pub trait Sandbox: Send + Sync {
    /// Shown to a person with the command, and in errors.
    fn name(&self) -> &'static str;

    /// The program and arguments that run `program args` with no network,
    /// writing only inside `writable` (a canonical path).
    fn wrap(&self, program: &str, args: &[String], writable: &Path) -> (String, Vec<String>);

    /// Whether this actually confines the command. With no sandbox, the
    /// command can send anything anywhere, so every run asks a person.
    fn confines(&self) -> bool {
        true
    }
}

/// No sandbox at all. **Unsafe**: the command can read, write and send
/// anything you can. Use it only where something else already confines it.
pub struct NoSandbox;

impl Sandbox for NoSandbox {
    fn name(&self) -> &'static str {
        "no sandbox"
    }

    fn confines(&self) -> bool {
        false
    }

    fn wrap(&self, program: &str, args: &[String], _writable: &Path) -> (String, Vec<String>) {
        (program.to_string(), args.to_vec())
    }
}

/// macOS `sandbox-exec` (Seatbelt). Apple marks the tool deprecated, but it
/// ships with macOS and is what Codex uses. Only `/usr/bin/sandbox-exec` is
/// used, never one found on `PATH`.
#[derive(Debug, Clone, Default)]
pub struct Seatbelt {
    /// Whose credentials to hide; `$HOME` when `None`.
    home: Option<PathBuf>,
}

pub const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";

/// Credentials under the home directory that a command can never read.
pub const SECRET_PATHS: &[&str] = &[
    ".ssh", ".aws", ".gnupg", ".netrc", ".npmrc", ".pypirc", ".docker", ".kube", ".azure",
    ".config/gcloud", ".config/gh", ".git-credentials", ".cargo/credentials", ".cargo/credentials.toml",
    ".terraform.d", ".codex", ".claude.json", ".thinkingroot", ".zsh_history", ".bash_history",
    "Library/Keychains", "Library/Cookies", "Library/Application Support/Google/Chrome",
    "Library/Application Support/Firefox", "Library/Application Support/BraveSoftware",
];

/// Every path to hide: each secret as named and, if it is a symlink, where
/// it really is (Seatbelt matches real paths).
fn secret_paths(home: &Path) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    for secret in SECRET_PATHS {
        let path = home.join(secret);
        if let Ok(real) = std::fs::canonicalize(&path) {
            if real != path {
                paths.push(real);
            }
        }
        paths.push(path);
    }
    paths
}

/// Codex's deny-by-default policy (processes, sysctls and a few services a
/// shell needs), unmodified — see THIRD_PARTY_NOTICES.md.
const SEATBELT_BASE: &str = include_str!("seatbelt_base_policy.sbpl");

/// The whole profile. Deny by default, so nothing not listed is allowed:
/// no network, no Apple Events, no LaunchServices (`open`), no XPC
/// services. Reads anywhere except `SECRET_PATHS`; writes only in
/// `WRITABLE_ROOT` (and xcrun's own cache file in /tmp).
pub fn seatbelt_profile() -> String {
    seatbelt_profile_for(SECRET_PATHS.len())
}

fn seatbelt_profile_for(secrets: usize) -> String {
    let mut profile = format!("{SEATBELT_BASE}\n(allow file-read*)\n");
    for i in 0..secrets {
        profile.push_str(&format!("(deny file-read* (subpath (param \"SECRET_{i}\")))\n"));
    }
    profile.push_str(concat!(
        "(allow file-write* (subpath (param \"WRITABLE_ROOT\")))\n",
        "(allow file-write* (regex #\"^/private/tmp/xcrun_db-\"))\n",
        "(deny mach-lookup (xpc-service-name-prefix \"\"))\n",
        "(deny system-fcntl (fcntl-command 80 110))\n",
    ));
    profile
}

impl Seatbelt {
    /// Hide the credentials under `home` instead of `$HOME`.
    pub fn with_home(home: impl Into<PathBuf>) -> Self {
        Self { home: Some(home.into()) }
    }
}

fn home(configured: &Option<PathBuf>) -> PathBuf {
    configured.clone().or_else(|| std::env::var_os("HOME").map(PathBuf::from)).unwrap_or_else(|| PathBuf::from("/var/empty"))
}

impl Sandbox for Seatbelt {
    fn name(&self) -> &'static str {
        "seatbelt"
    }

    fn wrap(&self, program: &str, args: &[String], writable: &Path) -> (String, Vec<String>) {
        let home = home(&self.home);
        let secrets = secret_paths(&home);
        let mut argv = vec!["-p".to_string(), seatbelt_profile_for(secrets.len()), format!("-DWRITABLE_ROOT={}", writable.display())];
        for (i, secret) in secrets.iter().enumerate() {
            argv.push(format!("-DSECRET_{i}={}", secret.display()));
        }
        argv.push("--".to_string());
        argv.push(program.to_string());
        argv.extend_from_slice(args);
        (SANDBOX_EXEC.to_string(), argv)
    }
}

/// Linux bubblewrap: the root read-only, `writable` read-write, a private
/// `/tmp`, credentials hidden, and every namespace unshared (the network
/// included). Needs unprivileged user namespaces, or a setuid `bwrap`.
#[derive(Debug, Clone, Default)]
pub struct Bubblewrap {
    home: Option<PathBuf>,
}

/// Only these, never one found on `PATH`.
const BWRAP_PATHS: &[&str] = &["/usr/bin/bwrap", "/bin/bwrap", "/usr/local/bin/bwrap"];

fn bwrap() -> &'static str {
    BWRAP_PATHS.iter().copied().find(|p| Path::new(p).exists()).unwrap_or(BWRAP_PATHS[0])
}

impl Bubblewrap {
    pub fn with_home(home: impl Into<PathBuf>) -> Self {
        Self { home: Some(home.into()) }
    }
}

impl Sandbox for Bubblewrap {
    fn name(&self) -> &'static str {
        "bubblewrap"
    }

    fn wrap(&self, program: &str, args: &[String], writable: &Path) -> (String, Vec<String>) {
        let dir = writable.display().to_string();
        let mut argv: Vec<String> =
            ["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp"].iter().map(|s| s.to_string()).collect();
        // Credentials: an empty directory over a directory, /dev/null over a file.
        let home = home(&self.home);
        for secret in secret_paths(&home) {
            let path = secret.display().to_string();
            if Path::new(&path).is_dir() {
                argv.extend(["--tmpfs".to_string(), path]);
            } else if Path::new(&path).exists() {
                argv.extend(["--ro-bind".to_string(), "/dev/null".to_string(), path]);
            }
        }
        // After the read-only root and /tmp: later mounts win.
        argv.extend(
            ["--bind", &dir, &dir, "--chdir", &dir, "--unshare-all", "--die-with-parent", "--new-session", "--", program]
                .iter()
                .map(|s| s.to_string()),
        );
        argv.extend_from_slice(args);
        (bwrap().to_string(), argv)
    }
}

/// The strongest sandbox this machine can run, after trying it once.
/// `None` when there is none: choose `NoSandbox` yourself if you must.
pub fn detect() -> Option<Arc<dyn Sandbox>> {
    let works = |program: &str, args: &[&str]| {
        std::process::Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    };
    if cfg!(target_os = "macos") && works(SANDBOX_EXEC, &["-p", "(version 1)(allow default)", "--", "/usr/bin/true"]) {
        return Some(Arc::new(Seatbelt::default()));
    }
    if cfg!(target_os = "linux") && works(bwrap(), &["--ro-bind", "/", "/", "--unshare-all", "--die-with-parent", "--", "/bin/true"]) {
        return Some(Arc::new(Bubblewrap::default()));
    }
    None
}

/// Each of stdout and stderr keeps at most this much.
pub const OUTPUT_CAP: usize = 32 * 1024;
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60);

/// A tool that runs one `sh -c` command inside `sandbox`, in `workdir`.
pub struct CommandTool {
    spec: ToolSpec,
    sandbox: Arc<dyn Sandbox>,
    workdir: PathBuf,
    timeout: Duration,
}

/// Runs a shell command in `workdir`, the only directory it may write to.
/// `Effect::Write`, one at a time. The environment is cleared (keys never
/// reach the command) except `PATH`, `HOME`, `USER`, `LANG`, `TERM`;
/// `TMPDIR` is `workdir`.
pub fn command_tool(name: &str, sandbox: Arc<dyn Sandbox>, workdir: impl AsRef<Path>) -> Result<CommandTool> {
    // Canonical, as Seatbelt matches real paths (/tmp is /private/tmp).
    let workdir = std::fs::canonicalize(workdir.as_ref())
        .map_err(|e| Error::Tool(format!("`{}`: {e}", workdir.as_ref().display())))?;
    if !workdir.is_dir() {
        return Err(Error::Tool(format!("`{}` is not a directory", workdir.display())));
    }
    Ok(CommandTool {
        spec: ToolSpec {
            name: name.to_string(),
            description: if sandbox.confines() {
                format!(
                    "Run a shell command (sh -c) in {}. It may write only there; it has no network and cannot \
                     ask other apps to act. Returns the exit code, stdout and stderr (each cut at {} KB).",
                    workdir.display(),
                    OUTPUT_CAP / 1024
                )
            } else {
                format!(
                    "Run a shell command (sh -c) in {}, with no sandbox: a person approves every command. \
                     Returns the exit code, stdout and stderr (each cut at {} KB).",
                    workdir.display(),
                    OUTPUT_CAP / 1024
                )
            },
            schema: json!({
                "type": "object",
                "properties": {"command": {"type": "string", "description": "The shell command."}},
                "required": ["command"],
            }),
            // Unconfined, a command can send or delete anything: it always asks.
            effect: if sandbox.confines() { Effect::Write } else { Effect::Outbound },
            guarded_args: Vec::new(),
            parallel_safe: false,
            delegates: false,
            foreign: false,
        },
        sandbox,
        workdir,
        timeout: DEFAULT_TIMEOUT,
    })
}

impl CommandTool {
    /// How long a command may run before it is killed (default 60 s).
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    async fn run(&self, args: &Value, cancel: &CancellationToken) -> std::result::Result<String, String> {
        let Some(command) = args["command"].as_str().filter(|c| !c.trim().is_empty()) else {
            return Err("needs a `command`".into());
        };
        let (program, argv) = self.sandbox.wrap("/bin/sh", &["-c".to_string(), command.to_string()], &self.workdir);
        let mut cmd = tokio::process::Command::new(&program);
        cmd.args(&argv)
            .current_dir(&self.workdir)
            .env_clear()
            .env("TMPDIR", &self.workdir)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        for key in ["PATH", "HOME", "USER", "LANG", "TERM"] {
            if let Some(value) = std::env::var_os(key) {
                cmd.env(key, value);
            }
        }
        // Its own process group, so what it starts in the background is killed with it.
        #[cfg(unix)]
        cmd.process_group(0);
        let mut child = cmd.spawn().map_err(|e| format!("could not start {} ({}): {e}", program, self.sandbox.name()))?;
        let stdout = Captured::start(child.stdout.take());
        let stderr = Captured::start(child.stderr.take());

        let status = tokio::select! {
            status = tokio::time::timeout(self.timeout, child.wait()) => status,
            _ = cancel.cancelled() => {
                kill_group(child.id()).await;
                return Err("cancelled".into());
            }
        };
        // Leftover background processes would hold the pipes open.
        kill_group(child.id()).await;
        let _ = child.kill().await;
        let output = format!("{}{}", stdout.finish("stdout").await, stderr.finish("stderr").await);
        match status {
            Ok(Ok(status)) => {
                let code = status.code().map_or("none (killed by a signal)".to_string(), |c| c.to_string());
                Ok(format!("exit code: {code}\n{output}"))
            }
            Ok(Err(e)) => Err(format!("could not wait for the command: {e}")),
            Err(_) => Err(format!("did not finish in {} s and was killed\n{output}", self.timeout.as_secs_f32())),
        }
    }
}

/// Kills the process group `pid` leads. A no-op once it is gone.
/// ponytail: shells out to /bin/kill to stay free of `unsafe`; libc::killpg if that ever matters.
async fn kill_group(pid: Option<u32>) {
    #[cfg(unix)]
    if let Some(pid) = pid {
        let _ = tokio::process::Command::new("/bin/kill")
            .args(["-KILL", "--", &format!("-{pid}")])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await;
    }
    #[cfg(not(unix))]
    let _ = pid;
}

/// One output stream, read to the end, keeping the first `OUTPUT_CAP` bytes.
struct Captured {
    kept: Arc<Mutex<(Vec<u8>, usize)>>,
    task: Option<tokio::task::JoinHandle<()>>,
}

impl Captured {
    fn start(stream: Option<impl AsyncRead + Unpin + Send + 'static>) -> Self {
        let kept: Arc<Mutex<(Vec<u8>, usize)>> = Arc::default();
        let task = stream.map(|mut stream| {
            let kept = kept.clone();
            tokio::spawn(async move {
                let mut chunk = [0u8; 8192];
                while let Ok(n) = stream.read(&mut chunk).await {
                    if n == 0 {
                        break;
                    }
                    let mut kept = kept.lock().unwrap();
                    let room = OUTPUT_CAP.saturating_sub(kept.0.len());
                    kept.0.extend_from_slice(&chunk[..n.min(room)]);
                    kept.1 += n;
                }
            })
        });
        Self { kept, task }
    }

    /// What was read, labelled. Waits briefly for the pipe to close: a
    /// process that left its group may hold it open.
    async fn finish(mut self, label: &str) -> String {
        if let Some(task) = self.task.take() {
            let abort = task.abort_handle();
            if tokio::time::timeout(Duration::from_secs(2), task).await.is_err() {
                abort.abort();
            }
        }
        let (bytes, total) = &*self.kept.lock().unwrap();
        let mut text = format!("{label}:\n{}", String::from_utf8_lossy(bytes));
        if *total > bytes.len() {
            text.push_str(&format!("\n[{label} truncated: {total} bytes, first {} shown]", bytes.len()));
        }
        if !text.ends_with('\n') {
            text.push('\n');
        }
        text
    }
}

#[async_trait]
impl Tool for CommandTool {
    fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    async fn call(&self, args: Value) -> std::result::Result<String, String> {
        self.run(&args, &CancellationToken::new()).await
    }

    async fn call_in(&self, args: Value, context: &ToolContext) -> std::result::Result<String, String> {
        self.run(&args, &context.cancel).await
    }

    fn preview(&self, args: &Value) -> String {
        format!(
            "Run in {} ({}): {}",
            self.workdir.display(),
            self.sandbox.name(),
            args["command"].as_str().unwrap_or("(no command)")
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(argv: &[String]) -> Vec<&str> {
        argv.iter().map(String::as_str).collect()
    }

    #[test]
    fn seatbelt_denies_by_default_and_passes_the_directory_and_secrets_as_parameters() {
        let (program, argv) = Seatbelt::with_home("/Users/a").wrap("/bin/sh", &["-c".into(), "ls".into()], Path::new("/private/tmp/w"));
        assert_eq!(program, "/usr/bin/sandbox-exec");
        let profile = seatbelt_profile();
        assert_eq!(argv[..3], ["-p".to_string(), profile.clone(), "-DWRITABLE_ROOT=/private/tmp/w".to_string()]);
        assert!(argv.contains(&"-DSECRET_0=/Users/a/.ssh".to_string()));
        assert_eq!(strings(&argv[argv.len() - 4..]), ["--", "/bin/sh", "-c", "ls"]);
        assert!(profile.contains("(deny default)") && !profile.contains("(allow default)"), "closed by default");
        assert!(!profile.contains("(allow network") && !profile.contains("appleevent") && !profile.contains("lsopen"));
    }

    #[test]
    fn bubblewrap_binds_the_directory_after_the_read_only_root_and_unshares_the_network() {
        let dir = tempfile::tempdir().unwrap();
        // Canonical, so each secret's path and real path are the same here.
        let home = std::fs::canonicalize(dir.path()).unwrap();
        std::fs::create_dir(home.join(".ssh")).unwrap();
        std::fs::write(home.join(".netrc"), "secret").unwrap();
        let (program, argv) = Bubblewrap::with_home(&home).wrap("/bin/sh", &["-c".into(), "ls".into()], Path::new("/home/a/w"));
        assert!(BWRAP_PATHS.contains(&program.as_str()), "never from PATH: {program}");
        let ssh = home.join(".ssh").display().to_string();
        let netrc = home.join(".netrc").display().to_string();
        assert_eq!(
            strings(&argv),
            [
                "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
                "--tmpfs", &ssh, "--ro-bind", "/dev/null", &netrc,
                "--bind", "/home/a/w", "/home/a/w", "--chdir", "/home/a/w",
                "--unshare-all", "--die-with-parent", "--new-session", "--", "/bin/sh", "-c", "ls",
            ]
        );
    }

    #[test]
    fn no_sandbox_changes_nothing() {
        let (program, argv) = NoSandbox.wrap("/bin/sh", &["-c".into(), "ls".into()], Path::new("/w"));
        assert_eq!((program.as_str(), strings(&argv)), ("/bin/sh", vec!["-c", "ls"]));
    }

    fn unconfined(dir: &Path) -> CommandTool {
        command_tool("sh", Arc::new(NoSandbox), dir).unwrap()
    }

    #[tokio::test]
    async fn a_command_is_a_write_tool_that_reports_its_exit_code_and_both_streams() {
        let dir = tempfile::tempdir().unwrap();
        let t = unconfined(dir.path());
        assert_eq!(t.spec().effect, Effect::Outbound, "with no sandbox every command asks a person");
        assert!(!t.spec().parallel_safe);
        let out = t.call(json!({"command": "echo out; echo err >&2; pwd; exit 3"})).await.unwrap();
        let workdir = std::fs::canonicalize(dir.path()).unwrap();
        assert_eq!(out, format!("exit code: 3\nstdout:\nout\n{}\nstderr:\nerr\n", workdir.display()));
        assert!(t.preview(&json!({"command": "ls"})).ends_with("(no sandbox): ls"));
    }

    #[tokio::test]
    async fn long_output_is_cut_and_says_so() {
        let dir = tempfile::tempdir().unwrap();
        let out = unconfined(dir.path()).call(json!({"command": "head -c 100000 /dev/zero | tr '\\0' a"})).await.unwrap();
        assert!(out.contains(&format!("[stdout truncated: 100000 bytes, first {OUTPUT_CAP} shown]")), "{}", &out[out.len() - 200..]);
        assert!(out.len() < OUTPUT_CAP + 300);
    }

    #[tokio::test]
    async fn a_command_that_runs_too_long_is_killed_with_what_it_printed() {
        let dir = tempfile::tempdir().unwrap();
        let t = unconfined(dir.path()).timeout(Duration::from_millis(300));
        let started = std::time::Instant::now();
        // The background sleep holds the pipe open: it must be killed too.
        let out = t.call(json!({"command": "echo started; sleep 30 & sleep 30"})).await.unwrap_err();
        assert!(started.elapsed() < Duration::from_secs(3), "{:?}", started.elapsed());
        assert!(out.starts_with("did not finish in 0.3 s") && out.contains("started"), "{out}");
    }

    #[tokio::test]
    async fn cancelling_the_run_kills_the_command() {
        let dir = tempfile::tempdir().unwrap();
        let t = unconfined(dir.path());
        let context = ToolContext::default();
        let cancel = context.cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(200)).await;
            cancel.cancel();
        });
        let marker = dir.path().join("late");
        let command = format!("sleep 1; touch {}", marker.display());
        let out = tokio::time::timeout(Duration::from_secs(3), t.call_in(json!({"command": command}), &context)).await.unwrap();
        assert_eq!(out.unwrap_err(), "cancelled");
        tokio::time::sleep(Duration::from_millis(1200)).await;
        assert!(!marker.exists(), "the command was killed, not left running");
    }

    #[tokio::test]
    async fn keys_in_the_environment_never_reach_the_command() {
        std::env::set_var("COOKIE_TEST_SECRET_KEY", "sk-should-not-leak");
        let dir = tempfile::tempdir().unwrap();
        let out = unconfined(dir.path()).call(json!({"command": "env"})).await.unwrap();
        assert!(!out.contains("sk-should-not-leak"), "{out}");
        assert!(out.contains("TMPDIR="));
    }

    #[test]
    fn a_missing_directory_is_refused() {
        assert!(command_tool("sh", Arc::new(NoSandbox), "/no/such/dir").is_err());
    }

    /// The real thing: sandbox-exec ships with macOS.
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn seatbelt_blocks_writes_outside_the_directory_and_the_network() {
        let sandbox = detect().expect("sandbox-exec runs on this Mac");
        assert_eq!(sandbox.name(), "seatbelt");
        let dir = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move { while listener.accept().await.is_ok() {} });
        let blocked = outside.path().join("x");
        let command = format!(
            "echo hi > inside && cat inside; echo no > {}; echo \"outside=$?\"; /usr/bin/nc -z -w 2 127.0.0.1 {port}; echo \"connect=$?\"",
            blocked.display()
        );

        // Without the sandbox both work, so a failure below is the sandbox's doing.
        let open = unconfined(dir.path()).call(json!({"command": command})).await.unwrap();
        assert!(open.contains("outside=0") && open.contains("connect=0"), "{open}");
        std::fs::remove_file(&blocked).unwrap();

        let confined = command_tool("sh", sandbox, dir.path()).unwrap().call(json!({"command": command})).await.unwrap();
        assert!(confined.contains("stdout:\nhi\n"), "writes inside work: {confined}");
        assert!(confined.contains("outside=1") && !blocked.exists(), "{confined}");
        assert!(confined.contains("connect=1"), "{confined}");
        assert!(confined.contains("Operation not permitted"), "{confined}");
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn bubblewrap_blocks_writes_outside_the_directory_and_the_network() {
        let Some(sandbox) = detect() else {
            panic!("bwrap is not installed or user namespaces are off: install bubblewrap to run this test");
        };
        assert_eq!(sandbox.name(), "bubblewrap");
        let home = std::env::var("HOME").unwrap();
        let dir = tempfile::tempdir_in(&home).unwrap();
        let outside = tempfile::tempdir_in(&home).unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move { while listener.accept().await.is_ok() {} });
        let blocked = outside.path().join("x");
        let command = format!(
            "echo hi > inside && cat inside; echo no > {}; echo \"outside=$?\"; bash -c 'echo > /dev/tcp/127.0.0.1/{port}'; echo \"connect=$?\"",
            blocked.display()
        );

        let open = unconfined(dir.path()).call(json!({"command": command})).await.unwrap();
        assert!(open.contains("outside=0") && open.contains("connect=0"), "{open}");
        std::fs::remove_file(&blocked).unwrap();

        let confined = command_tool("sh", sandbox, dir.path()).unwrap().call(json!({"command": command})).await.unwrap();
        assert!(confined.contains("stdout:\nhi\n"), "{confined}");
        assert!(confined.contains("outside=1") && !blocked.exists(), "{confined}");
        // Its own empty network namespace: the host's loopback is not there.
        assert!(confined.contains("connect=1"), "{confined}");
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn seatbelt_blocks_apple_events_launch_services_and_reading_credentials() {
        let dir = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        std::fs::create_dir(home.path().join(".ssh")).unwrap();
        std::fs::write(home.path().join(".ssh/id_test"), "PRIVATE KEY").unwrap();
        let tool = command_tool("sh", Arc::new(Seatbelt::with_home(std::fs::canonicalize(home.path()).unwrap())), dir.path()).unwrap();
        assert_eq!(tool.spec().effect, Effect::Write);
        let key = std::fs::canonicalize(home.path()).unwrap().join(".ssh/id_test");
        let out = tool
            .call(json!({"command": format!(
                "cat {}; echo \"read=$?\"; /usr/bin/osascript -e 'tell application \"System Events\" to get count of processes'; echo \"event=$?\"; /usr/bin/open -g -a TextEdit; echo \"open=$?\"",
                key.display()
            )}))
            .await
            .unwrap();
        assert!(!out.contains("PRIVATE KEY") && out.contains("read=1"), "{out}");
        assert!(out.contains("event=1"), "an Apple Event is refused: {out}");
        assert!(!out.contains("open=0"), "LaunchServices is refused: {out}");
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn everyday_tools_still_work_inside_seatbelt() {
        let dir = tempfile::tempdir().unwrap();
        let tool = command_tool("sh", Arc::new(Seatbelt::default()), dir.path()).unwrap();
        let out = tool.call(json!({"command": "ls / >/dev/null && id -un >/dev/null && git --version && echo hi > f && cat f"})).await.unwrap();
        assert!(out.starts_with("exit code: 0") && out.contains("git version") && out.contains("hi"), "{out}");
        assert!(!out.contains("couldn't create cache file"), "xcrun can write its cache: {out}");
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn a_credential_reached_through_a_symlink_stays_hidden() {
        let dir = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        let dotfiles = tempfile::tempdir().unwrap();
        std::fs::write(dotfiles.path().join("netrc"), "machine x password SECRET").unwrap();
        std::os::unix::fs::symlink(dotfiles.path().join("netrc"), home.path().join(".netrc")).unwrap();
        std::fs::create_dir_all(home.path().join(".config/gh")).unwrap();
        std::fs::write(home.path().join(".config/gh/hosts.yml"), "oauth_token: SECRET").unwrap();
        let tool = command_tool("sh", Arc::new(Seatbelt::with_home(home.path())), dir.path()).unwrap();
        let out = tool
            .call(json!({"command": format!("cat {0}/.netrc {0}/.config/gh/hosts.yml", home.path().display())}))
            .await
            .unwrap();
        assert!(!out.contains("SECRET"), "{out}");
    }
}
