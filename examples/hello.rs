//! cargo run --example hello   (needs ANTHROPIC_API_KEY; name any model you like)

use cookie_harness::{tool, Agent, Effect};
use serde_json::json;

#[tokio::main]
async fn main() -> cookie_harness::Result<()> {
    let weather = tool(
        "weather",
        "Current weather for a city",
        json!({"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}),
        Effect::Read,
        |args| async move { Ok(format!("{}: 9°C, cloudy", args["city"].as_str().unwrap_or("?"))) },
    );
    let agent = Agent::new("anthropic:claude-sonnet-4-6")?.tool(weather);
    println!("{}", agent.run("What's the weather in Riga?").await?);
    Ok(())
}
