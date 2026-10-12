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
