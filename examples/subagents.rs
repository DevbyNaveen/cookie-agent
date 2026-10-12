//! cargo run --example subagents   (needs ANTHROPIC_API_KEY)
//! A lead that delegates research to a reader and hands billing questions on.

use cookie_harness::{tool, Agent, Effect, Handoff, SubAgent};
use serde_json::json;

#[tokio::main]
async fn main() -> cookie_harness::Result<()> {
    let search = tool("search", "Search the docs", json!({"type": "object", "properties": {"q": {"type": "string"}}}), Effect::Read, |args| async move {
        Ok(format!("Docs about {}: invoices are sent on the 1st.", args["q"]))
    });
    let researcher = Agent::new("anthropic:claude-haiku-4-5")?.instructions("Answer from the docs only.").tool(search);
    let billing = Agent::new("anthropic:claude-sonnet-4-6")?.instructions("You handle billing questions.");
    let lead = Agent::new("anthropic:claude-sonnet-4-6")?
        .tool(SubAgent::reader("research", "Looks things up in the docs", researcher)?)
        .tool(Handoff::to("billing", "Anything about invoices or payments", billing));
    println!("{}", lead.run("When do invoices go out, and can I change my billing address?").await?);
    Ok(())
}
