//! The real `cookie` binary, with no network and no keys.

use std::{
    io::Write,
    process::{Command, Stdio},
};

const COOKIE: &str = env!("CARGO_BIN_EXE_cookie");

#[test]
fn serve_answers_each_line_and_reports_a_bad_model_without_stopping() {
    let mut child = Command::new(COOKIE)
        .arg("serve")
        .env_remove("ENKEON_API_KEY")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    writeln!(stdin, r#"{{"type":"run","id":"r1","model":"nope:x","input":"hi"}}"#).unwrap();
    writeln!(stdin, r#"{{"type":"wave"}}"#).unwrap();
    drop(stdin);
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    let lines: Vec<serde_json::Value> = String::from_utf8(out.stdout).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines.len(), 2, "one line per answer, nothing else on stdout");
    assert_eq!((lines[0]["type"].as_str(), lines[0]["run"].as_str()), (Some("error"), Some("r1")));
    assert!(lines[0]["message"].as_str().unwrap().contains("nope"));
    assert!(lines[1]["message"].as_str().unwrap().contains("wave"));
}

#[test]
fn run_without_a_prompt_explains_itself() {
    let out = Command::new(COOKIE).args(["run", "anthropic:claude-sonnet-4-6"]).output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("cookie run <provider:model> <prompt>"));
}

#[test]
fn version_prints_the_crate_version() {
    let out = Command::new(COOKIE).arg("--version").output().unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), format!("cookie {}", env!("CARGO_PKG_VERSION")));
}

#[test]
fn a_prompt_that_starts_with_dashes_goes_after_a_double_dash() {
    let out = Command::new(COOKIE)
        .args(["run", "anthropic:claude-sonnet-4-6", "--no-enkeon", "--", "--why is this a flag?"])
        .env_remove("ANTHROPIC_API_KEY")
        .env_remove("ENKEON_API_KEY")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(1), "{stderr}");
    assert!(!stderr.contains("unknown flag") && stderr.contains("ANTHROPIC_API_KEY"), "{stderr}");
}

/// A session file written the way the harness writes one: a question, a
/// tool call, its result, an answer.
fn recorded(dir: &std::path::Path, result: &str) -> std::path::PathBuf {
    let path = dir.join("rec.jsonl");
    let lines = [
        r#"{"role":"user","content":[{"type":"text","text":"weather?"}],"origin":{"origin":"user"}}"#.to_string(),
        r#"{"role":"assistant","content":[{"type":"tool_call","id":"c1","name":"bad name","args":{}}],"origin":{"origin":"model"}}"#.to_string(),
        format!(r#"{{"role":"user","content":[{{"type":"tool_result","id":"c1","output":"{result}","is_error":true}}],"origin":{{"origin":"untrusted","source":{{"kind":"tool","detail":"bad name"}}}}}}"#),
        r#"{"role":"assistant","content":[{"type":"text","text":"9°C"}],"origin":{"origin":"model"}}"#.to_string(),
    ];
    std::fs::write(&path, lines.join("\n") + "\n").unwrap();
    path
}

#[test]
fn replay_says_whether_a_recording_reproduced() {
    let dir = tempfile::tempdir().unwrap();
    let path = recorded(dir.path(), "There is no tool called `bad name`.");
    let out = Command::new(COOKIE).arg("replay").arg(&path).output().unwrap();
    assert_eq!(out.status.code(), Some(0), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(String::from_utf8_lossy(&out.stdout).contains("reproduced"));

    // A result the loop would never have written: the replay differs there.
    let path = recorded(dir.path(), "sunny");
    let out = Command::new(COOKIE).arg("replay").arg(&path).output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let said = String::from_utf8_lossy(&out.stdout);
    assert!(said.contains("diverged at message 3") && said.contains("sunny"), "{said}");
}

#[test]
fn replay_needs_one_readable_file() {
    let out = Command::new(COOKIE).arg("replay").output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("cookie replay <session.jsonl>"));
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("none.jsonl");
    let out = Command::new(COOKIE).arg("replay").arg(&missing).output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert!(!missing.exists(), "replay never creates the file");
}

#[test]
fn chat_checks_its_arguments_before_reading_anything() {
    let out = Command::new(COOKIE).arg("chat").stdin(Stdio::null()).output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("cookie chat <provider:model>"));
    let out = Command::new(COOKIE).args(["chat", "anthropic:claude-sonnet-4-6", "--sesion", "x"]).stdin(Stdio::null()).output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("--sesion"));
    let out = Command::new(COOKIE).args(["chat", "scripted:x"]).stdin(Stdio::null()).output().unwrap();
    assert_eq!(out.status.code(), Some(1), "no fake models in the shipping binary");
    let out = Command::new(COOKIE)
        .args(["chat", "anthropic:claude-sonnet-4-6", "--no-enkeon"])
        .env_remove("ANTHROPIC_API_KEY")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("ANTHROPIC_API_KEY"));
}
