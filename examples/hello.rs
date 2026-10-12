//! cargo run --example hello   (needs ANTHROPIC_API_KEY; name any model you like)
//! Prints the answer as it streams.

use std::io::Write;

use cookie_harness::{tool, Agent, Effect, Event, Message, RunControl, Session};
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
    let mut session = Session::in_memory();
    let mut on_event = |event: Event| {
        if let Event::TextDelta(text) = event {
            print!("{text}");
            let _ = std::io::stdout().flush();
        }
    };
    agent
        .run_streaming(&mut session, Message::user("What's the weather in Riga?"), &RunControl::default(), &mut on_event)
        .await?;
    println!();
    Ok(())
}
