//! Code that calls tools: the agent writes one Python script that calls its
//! read-only tools as functions, loops and filters, and prints only what
//! matters. Many steps become one turn, and the in-between results never
//! enter the conversation. Adapted from Hermes Agent's programmatic tool
//! calling (MIT).
//!
//! The script runs in the same sandbox as `run_command` (its folder only, no
//! network). It can't open a socket, so it asks for a tool by writing a
//! request file in its folder; Cookie, outside the sandbox, answers it. Only
//! tools that read things on this computer are reachable: no web, no sending,
//! no changes — so a script can't carry data anywhere the person didn't see.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use cookie_harness::tool::{tool, Effect, Tool};
use serde_json::{json, Value};

const RUN_LIMIT: Duration = Duration::from_secs(180);
const MAX_CALLS: usize = 300;
const OUTPUT_MAX: usize = 20_000;

/// Read-only tools a script may call: things on this computer, nothing on the network.
fn script_may_call(t: &Arc<dyn Tool>) -> bool {
    let n = t.spec().name.as_str();
    t.spec().effect == Effect::Read && !matches!(n, "web_search" | "read_url" | "ask_person" | "todo_list" | "tool_search") && !n.starts_with("use_tool")
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
        if time.time() - start > 120:
            raise TimeoutError(tool + " took more than two minutes")
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
pub(crate) fn run_code_tool(work: &Path, tools: &[Arc<dyn Tool>]) -> Option<Arc<dyn Tool>> {
    let sandbox = cookie_harness::sandbox::detect().filter(|s| s.confines())?;
    if !Path::new("/usr/bin/python3").exists() && which_python().is_none() {
        return None;
    }
    let allowed: Vec<Arc<dyn Tool>> = tools.iter().filter(|t| script_may_call(t)).cloned().collect();
    if allowed.is_empty() {
        return None;
    }
    let listing = allowed
        .iter()
        .map(|t| format!("{}({})", t.spec().name, t.spec().schema["properties"].as_object().map(|p| p.keys().map(|k| format!("{k}=…")).collect::<Vec<_>>().join(", ")).unwrap_or_default()))
        .collect::<Vec<_>>()
        .join(", ");
    let work = work.to_path_buf();
    Some(Arc::new(tool(
        "run_code",
        &format!(
            "Run a Python script that calls your tools as functions, to do many steps in one go: loop over files, filter, \
             count, combine, and print only the result. `from cookie_tools import *` gives you: {listing}. Each returns the \
             tool's text. The script's working directory is your folder (os.listdir and open work on your files); it has no network; it can only call these tools, which read and never change \
             or send. Prints are what you get back (up to 20 KB)."
        ),
        json!({"type": "object", "properties": {"code": {"type": "string", "description": "a Python 3 script"}}, "required": ["code"]}),
        Effect::Write,
        move |args: Value| {
            let (sandbox, allowed, work) = (sandbox.clone(), allowed.clone(), work.clone());
            async move { run(sandbox, allowed, &work, args["code"].as_str().unwrap_or_default()).await }
        },
    )
    .with_preview(|args| format!("Run this script in its folder (it can only read, through its tools):\n{}", crate::util::clip(args["code"].as_str().unwrap_or(""), 3000)))))
}

fn which_python() -> Option<String> {
    ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"].iter().find(|p| Path::new(p).exists()).map(|p| p.to_string())
}

async fn run(sandbox: Arc<dyn cookie_harness::sandbox::Sandbox>, allowed: Vec<Arc<dyn Tool>>, work: &Path, code: &str) -> Result<String, String> {
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
    let deadline = tokio::time::Instant::now() + RUN_LIMIT;
    let mut calls = 0usize;
    let output = loop {
        tokio::select! {
            out = &mut script => break out,
            _ = tokio::time::sleep(Duration::from_millis(30)) => {
                if tokio::time::Instant::now() > deadline {
                    let _ = std::fs::remove_dir_all(&rpc);
                    return Err("The script ran longer than three minutes and was stopped.".into());
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
                            Some(t) => match t.call(req["args"].clone()).await {
                                Ok(r) => json!({"ok": true, "result": r}),
                                Err(e) => json!({"ok": false, "error": e}),
                            },
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
        let Some(t) = run_code_tool(&work, &[reader, sender]) else { return }; // no sandbox on this machine
        let code = "from cookie_tools import *\nprint('total', sum(len(read_file(path=p)) for p in ['a.txt', 'b.txt']))\ntry:\n    call('messages_send')\nexcept Exception as e:\n    print('refused', 'available' in str(e))\n";
        let out = t.call(json!({"code": code})).await.unwrap();
        assert!(out.contains("total 9"), "{out}");
        assert!(out.contains("refused True"), "{out}");
        assert!(out.contains("3 tool calls"), "{out}");
        assert!(!work.join(".cookie_rpc").exists());
    }
}
