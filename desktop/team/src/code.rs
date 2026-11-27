//! Code that calls tools: the agent writes one Python script that calls its
//! read-only tools as functions, loops and filters, and prints only what
//! matters. Many steps become one turn, and the in-between results never
//! enter the conversation.
//!
//! The script runs in the agent's cage (its folder only). It asks for a tool
//! by writing a request file in its folder; Cookie, outside the sandbox,
//! answers it, with the same consent as a call the agent makes itself.
//!
//! Two modes, after the Rule of Two (a run may hold at most two of: content
//! it didn't write, the person's private data, a way out):
//! - **offline** (the default): no network of its own; it may call every tool
//!   the agent has, so it can read the person's things but can't carry them
//!   anywhere except through tools that ask.
//! - **online**: the network is open, so it can fetch, scrape, call public
//!   APIs and install packages; and then it can't call any tool that reads the
//!   person's private data (mail, apps, Mac, memory, signed-in browser). What
//!   it can reach out with, it has never been shown.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use cookie_harness::tool::{tool, Effect, Tool};
use serde_json::{json, Value};

const RUN_LIMIT: Duration = Duration::from_secs(1_800);
const MAX_CALLS: usize = 5_000;
const OUTPUT_MAX: usize = 20_000;

/// The tools a script may call: all of the agent's own, but not the ones that
/// steer the conversation itself (asking the person, its to-do list, finding
/// hidden tools, running another script). Without an approver (no person to
/// ask), only reads of this computer.
fn script_may_call(t: &Arc<dyn Tool>, can_ask: bool) -> bool {
    let n = t.spec().name.as_str();
    if matches!(n, "ask_person" | "todo_list" | "tool_search" | "run_code") || n.starts_with("use_tool") {
        return false;
    }
    can_ask || (t.spec().effect == Effect::Read && t.spec().guarded_args.is_empty() && !matches!(n, "web_search" | "read_url"))
}

/// The tools an online script may still call: none that read the person's
/// private data. Its own folder, the public web, and making things.
const ONLINE_TOOLS: [&str; 10] = ["web_search", "read_url", "read_url_fields", "read_file", "search_files", "write_file", "edit_file", "make_image", "make_video", "run_command"];

fn online_may_call(t: &Arc<dyn Tool>) -> bool {
    ONLINE_TOOLS.contains(&t.spec().name.as_str())
}

/// Does a call from a script need the person's yes? Anything that is not a
/// plain read, and any read whose arguments pick a destination (a URL): a
/// script can't show where its arguments came from, so they are taken as
/// not the person's.
pub fn needs_yes(t: &dyn Tool) -> bool {
    t.spec().effect != Effect::Read || !t.spec().guarded_args.is_empty()
}

fn helper(tools: &[Arc<dyn Tool>]) -> String {
    let mut s = String::from(
        r#""""Cookie's tools, callable from this script. Each returns the tool's text answer."""
import json, os, time, uuid
_DIR = os.path.dirname(os.path.abspath(__file__))

def call(tool, **args):
    rid = uuid.uuid4().hex[:12]
    tmp = os.path.join(_DIR, ".req-" + rid + ".tmp")
    with open(tmp, "w") as f:
        json.dump({"id": rid, "tool": tool, "args": args}, f)
    os.rename(tmp, os.path.join(_DIR, "req-" + rid + ".json"))
    res = os.path.join(_DIR, "res-" + rid + ".json")
    start = time.time()
    while not os.path.exists(res):
        if time.time() - start > 600:
            raise TimeoutError(tool + " took more than ten minutes")
        time.sleep(0.02)
    with open(res) as f:
        r = json.load(f)
    os.remove(res)
    if not r.get("ok"):
        raise RuntimeError(tool + ": " + str(r.get("error")))
    return r["result"]
"#,
    );
    for t in tools {
        let name = &t.spec().name;
        let doc = t.spec().description.replace('"', "'").replace('\\', "/");
        s.push_str(&format!("\ndef {name}(**args):\n    \"\"\"{doc}\"\"\"\n    return call({name:?}, **args)\n"));
    }
    s
}

/// The `run_code` tool, built from the agent's own tools for this job.
/// `cage`: the agent's own (`cage`); `None` uses the harness's plain sandbox.
/// `approver`: the job's own (`approvals::Broker`); every call that needs a
/// yes is put to the person through it, as the same call would be outside a script.
pub(crate) fn run_code_tool(work: &Path, tools: &[Arc<dyn Tool>], cage: Option<Arc<crate::cage::Cage>>, approver: Option<Arc<dyn cookie_harness::Approver>>, may_go_online: bool) -> Option<Arc<dyn Tool>> {
    // A script's cage lasts as long as a script may run, whatever a single command may.
    let script_cfg = |c: &crate::cage::Cage, network: bool| crate::cage::CageCfg {
        network,
        timeout_seconds: RUN_LIMIT.as_secs() as u32,
        cpu_seconds: (RUN_LIMIT.as_secs() as u32).max(c.cfg.cpu_seconds),
        ..c.cfg.clone()
    };
    let (offline, online): (Arc<dyn cookie_harness::sandbox::Sandbox>, Option<Arc<dyn cookie_harness::sandbox::Sandbox>>) = match &cage {
        Some(c) => (
            Arc::new(crate::cage::Cage { cfg: script_cfg(c, false), ..(**c).clone() }),
            may_go_online.then(|| Arc::new(crate::cage::Cage { cfg: script_cfg(c, true), ..(**c).clone() }) as Arc<dyn cookie_harness::sandbox::Sandbox>),
        ),
        // The harness's plain sandbox has no network switch: offline only.
        None => (cookie_harness::sandbox::detect().filter(|s| s.confines())?, None),
    };
    if !Path::new("/usr/bin/python3").exists() && which_python().is_none() {
        return None;
    }
    let allowed: Vec<Arc<dyn Tool>> = tools.iter().filter(|t| script_may_call(t, approver.is_some())).cloned().collect();
    if allowed.is_empty() && online.is_none() {
        return None;
    }
    let online_allowed: Vec<Arc<dyn Tool>> = allowed.iter().filter(|t| online_may_call(t)).cloned().collect();
    let list = |tools: &[Arc<dyn Tool>]| {
        tools
            .iter()
            .map(|t| format!("{}({}){}", t.spec().name, t.spec().schema["properties"].as_object().map(|p| p.keys().map(|k| format!("{k}=…")).collect::<Vec<_>>().join(", ")).unwrap_or_default(), if needs_yes(t.as_ref()) { " [asks the person]" } else { "" }))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let listing = list(&allowed);
    let online_note = if online.is_some() {
        format!(
            " Set online=true for a script that needs the internet (fetch pages, call public APIs, pip install into your folder): it then \
             has the network, and can call only {} — never a tool that reads the person's private data.",
            if online_allowed.is_empty() { "no tools".to_string() } else { list(&online_allowed) }
        )
    } else {
        String::new()
    };
    let work = work.to_path_buf();
    let minutes = RUN_LIMIT.as_secs() / 60;
    Some(Arc::new(tool(
        "run_code",
        &format!(
            "Run a Python script that calls your tools as functions, to do many steps in one go: loop over files, filter, \
             count, combine, and print only the result. `from cookie_tools import *` gives you: {listing}. Each returns the \
             tool's text. The script's working directory is your folder (os.listdir and open work on your files); offline it has no \
             network of its own.{online_note} A tool marked [asks the person] waits for their yes, exactly as when you call it yourself, \
             and raises an error if they say no. It may run up to {minutes} minutes. Prints are what you get back (up to 20 KB)."
        ),
        json!({"type": "object", "properties": {
            "code": {"type": "string", "description": "a Python 3 script"},
            "online": {"type": "boolean", "description": "give the script the internet (and no private-data tools)"}
        }, "required": ["code"]}),
        Effect::Write,
        move |args: Value| {
            let (offline, online, allowed, online_allowed, work, approver) = (offline.clone(), online.clone(), allowed.clone(), online_allowed.clone(), work.clone(), approver.clone());
            async move {
                let code = args["code"].as_str().unwrap_or_default();
                match (args["online"].as_bool().unwrap_or(false), online) {
                    (true, Some(net)) => run(net, online_allowed, &work, code, approver).await,
                    (true, None) => Err("Scripts can't go online for this agent (it has no web access, or no cage of its own).".into()),
                    (false, _) => run(offline, allowed, &work, code, approver).await,
                }
            }
        },
    )
    .with_preview(|args| {
        let net = if args["online"].as_bool().unwrap_or(false) { "online, with no access to your private data" } else { "offline" };
        format!("Run this script in its folder, {net} (anything it would change or send asks you first):\n{}", crate::util::clip(args["code"].as_str().unwrap_or(""), 3000))
    })))
}

fn which_python() -> Option<String> {
    ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"].iter().find(|p| Path::new(p).exists()).map(|p| p.to_string())
}

async fn run(sandbox: Arc<dyn cookie_harness::sandbox::Sandbox>, allowed: Vec<Arc<dyn Tool>>, work: &Path, code: &str, approver: Option<Arc<dyn cookie_harness::Approver>>) -> Result<String, String> {
    if code.trim().is_empty() {
        return Err("Write the script.".into());
    }
    let rpc = work.join(".cookie_rpc");
    let _ = std::fs::remove_dir_all(&rpc);
    std::fs::create_dir_all(&rpc).map_err(|e| e.to_string())?;
    std::fs::write(rpc.join("cookie_tools.py"), helper(&allowed)).map_err(|e| e.to_string())?;
    std::fs::write(rpc.join("script.py"), code).map_err(|e| e.to_string())?;
    let python = if Path::new("/usr/bin/python3").exists() { "/usr/bin/python3".to_string() } else { which_python().unwrap_or_default() };
    let cmd = cookie_harness::sandbox::command_tool("run", sandbox, work).map_err(|e| e.to_string())?;
    // From the agent's folder, so the script sees its files; the helper is importable from .cookie_rpc.
    let command = format!("PYTHONPATH=.cookie_rpc PYTHONDONTWRITEBYTECODE=1 {python} -u .cookie_rpc/script.py");
    let by_name: HashMap<String, Arc<dyn Tool>> = allowed.into_iter().map(|t| (t.spec().name.clone(), t)).collect();
    let script = cmd.call(json!({"command": command}));
    tokio::pin!(script);
    let mut deadline = tokio::time::Instant::now() + RUN_LIMIT;
    let mut calls = 0usize;
    let output = loop {
        tokio::select! {
            out = &mut script => break out,
            _ = tokio::time::sleep(Duration::from_millis(30)) => {
                if tokio::time::Instant::now() > deadline {
                    let _ = std::fs::remove_dir_all(&rpc);
                    return Err(format!("The script ran longer than {} minutes and was stopped.", RUN_LIMIT.as_secs() / 60));
                }
                // Answer every request the script left.
                for e in std::fs::read_dir(&rpc).into_iter().flatten().flatten() {
                    let name = e.file_name().to_string_lossy().to_string();
                    if !(name.starts_with("req-") && name.ends_with(".json")) {
                        continue;
                    }
                    let req: Value = std::fs::read(e.path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
                    let _ = std::fs::remove_file(e.path());
                    let id: String = req["id"].as_str().unwrap_or_default().chars().filter(|c| c.is_ascii_alphanumeric()).collect();
                    if id.is_empty() { continue; }
                    calls += 1;
                    let answer = if calls > MAX_CALLS {
                        json!({"ok": false, "error": format!("more than {MAX_CALLS} tool calls in one script")})
                    } else {
                        match by_name.get(req["tool"].as_str().unwrap_or_default()) {
                            Some(t) => {
                                let args = req["args"].clone();
                                // Consent kept: what needs a yes outside a script needs one inside it.
                                let allowed_now = if needs_yes(t.as_ref()) {
                                    match &approver {
                                        Some(a) => {
                                            let asked = tokio::time::Instant::now();
                                            let request = cookie_harness::ApprovalRequest {
                                                tool: t.spec().name.clone(),
                                                effect: t.spec().effect,
                                                preview: format!("From a script: {}", t.preview(&args)),
                                                reason: "A script the agent wrote calls this.".into(),
                                                from_data: t.spec().guarded_args.iter().filter_map(|g| args.get(g).map(|v| format!("{g} = {v}"))).collect(),
                                            };
                                            let yes = a.approve(&request).await;
                                            // Time waiting for the person is not the script's time.
                                            deadline += asked.elapsed();
                                            yes
                                        }
                                        None => false,
                                    }
                                } else {
                                    true
                                };
                                if allowed_now {
                                    match t.call(args).await {
                                        Ok(r) => json!({"ok": true, "result": r}),
                                        Err(e) => json!({"ok": false, "error": e}),
                                    }
                                } else {
                                    json!({"ok": false, "error": "the person said no (or wasn't asked); it was not done"})
                                }
                            }
                            None => json!({"ok": false, "error": "that tool isn't available to scripts"}),
                        }
                    };
                    let tmp = rpc.join(format!(".res-{id}.tmp"));
                    if std::fs::write(&tmp, answer.to_string()).is_ok() {
                        let _ = std::fs::rename(&tmp, rpc.join(format!("res-{id}.json")));
                    }
                }
            }
        }
    };
    let _ = std::fs::remove_dir_all(&rpc);
    let out = output?;
    Ok(format!("{}{}", crate::util::clip(&out, OUTPUT_MAX), if calls > 0 { format!("\n({calls} tool call{} from the script)", if calls == 1 { "" } else { "s" }) } else { String::new() }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_online_script_never_holds_a_tool_that_reads_private_data() {
        let t = |name: &str| -> Arc<dyn Tool> { Arc::new(tool(name, "x", json!({}), Effect::Read, |_a: Value| async { Ok(String::new()) })) };
        for private in ["mac_files_read", "connector_call", "recall", "browser_read", "mac_notes_read", "search_history"] {
            assert!(!online_may_call(&t(private)), "{private}");
        }
        for public in ["web_search", "read_url", "read_file", "write_file"] {
            assert!(online_may_call(&t(public)), "{public}");
        }
    }

    #[tokio::test]
    #[cfg(target_os = "macos")]
    async fn a_script_calls_tools_through_files_inside_the_sandbox() {
        let dir = tempfile::tempdir().unwrap();
        let work = std::fs::canonicalize(dir.path()).unwrap();
        std::fs::write(work.join("a.txt"), "alpha").unwrap();
        std::fs::write(work.join("b.txt"), "beta").unwrap();
        let root = work.clone();
        let reader: Arc<dyn Tool> = Arc::new(tool("read_file", "read a file", json!({"type": "object", "properties": {"path": {"type": "string"}}}), Effect::Read, move |a: Value| {
            let root = root.clone();
            async move { std::fs::read_to_string(root.join(a["path"].as_str().unwrap_or(""))).map_err(|e| e.to_string()) }
        }));
        let sender: Arc<dyn Tool> = Arc::new(tool("messages_send", "send", json!({"type": "object"}), Effect::Outbound, |_a: Value| async { Ok("sent".to_string()) }));
        let Some(t) = run_code_tool(&work, &[reader, sender], None, None, false) else { return }; // no sandbox on this machine
        let code = "from cookie_tools import *\nprint('total', sum(len(read_file(path=p)) for p in ['a.txt', 'b.txt']))\ntry:\n    call('messages_send')\nexcept Exception as e:\n    print('refused', 'available' in str(e))\n";
        let out = t.call(json!({"code": code})).await.unwrap();
        assert!(out.contains("total 9"), "{out}");
        assert!(out.contains("refused True"), "{out}");
        assert!(out.contains("3 tool calls"), "{out}");
        assert!(!work.join(".cookie_rpc").exists());
    }

    #[tokio::test]
    #[cfg(target_os = "macos")]
    async fn a_script_may_send_only_with_the_persons_yes() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        for (say, want) in [(false, "said no"), (true, "sent")] {
            let dir = tempfile::tempdir().unwrap();
            let work = std::fs::canonicalize(dir.path()).unwrap();
            let sent = Arc::new(AtomicUsize::new(0));
            let s2 = sent.clone();
            let sender: Arc<dyn Tool> = Arc::new(tool("messages_send", "send", json!({"type": "object", "properties": {"to": {"type": "string"}}}), Effect::Outbound, move |_a: Value| {
                let s = s2.clone();
                async move {
                    s.fetch_add(1, Ordering::SeqCst);
                    Ok("sent".to_string())
                }
            }));
            let asked = Arc::new(AtomicUsize::new(0));
            let a2 = asked.clone();
            let approver: Arc<dyn cookie_harness::Approver> = Arc::new(cookie_harness::FnApprover(move |r: &cookie_harness::ApprovalRequest| {
                a2.fetch_add(1, Ordering::SeqCst);
                assert!(r.preview.starts_with("From a script:"));
                say
            }));
            let Some(t) = run_code_tool(&work, &[sender], None, Some(approver), false) else { return };
            let code = "from cookie_tools import *\ntry:\n    print(messages_send(to='mara'))\nexcept Exception as e:\n    print('error', e)\n";
            let out = t.call(json!({"code": code})).await.unwrap();
            assert!(out.contains(want), "{out}");
            assert_eq!(asked.load(Ordering::SeqCst), 1, "asked once");
            assert_eq!(sent.load(Ordering::SeqCst), usize::from(say), "done only on a yes");
        }
    }
}
