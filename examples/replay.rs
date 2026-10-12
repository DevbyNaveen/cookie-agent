//! cargo run --example replay -- session.jsonl
//! Runs a recorded session again from its log — no model, no tools — and
//! says whether it reproduced.

use cookie_harness::{replay::Replay, Session};

#[tokio::main]
async fn main() -> cookie_harness::Result<()> {
    let path = std::env::args().nth(1).expect("usage: replay <session.jsonl>");
    let recorded = Session::load(&path).await?;
    let replayed = Replay::from_session(&recorded).run().await?;
    println!("reproduced: {} messages", replayed.messages().len());
    Ok(())
}
