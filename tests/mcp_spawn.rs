//! Spawns a real MCP server process (needs python3): cargo test -- --ignored

use cookie_harness::{Effect, McpServer};
use serde_json::json;

#[tokio::test]
#[ignore = "needs python3"]
async fn talks_to_a_real_server_process() {
    let server = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/echo_mcp.py");
    let tools = McpServer::stdio("python3", &[server]).effect("echo", Effect::Read).connect().await.unwrap();
    assert_eq!(tools.tools.len(), 1);
    assert_eq!(tools.tools[0].call(json!({"text": "hello"})).await.unwrap(), "hello");
}
