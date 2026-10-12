//! Talks to the real Enkeon (read-only recall): ENKEON_API_KEY=… cargo test --test enkeon_live -- --ignored

use cookie_harness::{McpServer, Effect};
use serde_json::json;

#[tokio::test]
#[ignore = "needs ENKEON_API_KEY and the network"]
async fn recalls_from_the_real_enkeon() {
    let key = std::env::var("ENKEON_API_KEY").expect("ENKEON_API_KEY");
    let url = std::env::var("ENKEON_URL").unwrap_or_else(|_| "https://api.thinkingroot.com/mcp".into());
    let server = McpServer::http(&url)
        .header("Authorization", &format!("Bearer {key}"))
        .effect("recall", Effect::Read)
        .effect("remember", Effect::Write)
        .connect()
        .await
        .unwrap();
    let recall = server.tools.iter().find(|t| t.spec().name == "recall").expect("recall offered");
    let out = recall
        .call(json!({"query": "Cookie Agent Harness", "branch": null, "as_of": null, "budget_tokens": 200, "check": null, "folder": null}))
        .await
        .unwrap();
    assert!(!out.is_empty());
    println!("tools={} recall_chars={}", server.tools.len(), out.len());
}
