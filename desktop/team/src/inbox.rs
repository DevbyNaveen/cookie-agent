//! The first-run moment: who is waiting on you, and who you are waiting on.
//!
//! Mail is read through Enkeon, which connects Gmail and others in one click
//! and enforces its own permission floor (a send or a delete always waits for
//! the person). Nothing here sends: the scan only reads, and drafting replies
//! is a job for an agent the person hires, under its own approvals.

use cookie_harness::approval::DenyAll;
use cookie_harness::{Agent, Message, Session};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::Team;

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct Thread {
    pub who: String,
    pub subject: String,
    #[serde(default)]
    pub since: String,
    /// What they want, in a few words.
    #[serde(default)]
    pub ask: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct Waiting {
    pub waiting_on_you: Vec<Thread>,
    pub you_wait_on: Vec<Thread>,
}

const PROMPT: &str = "Look through my mail from the last 14 days using my connected mail app. \
Find (1) threads where someone wrote to me, asked or needs something, and I haven't replied; \
(2) threads where I asked someone something and they haven't replied. Skip newsletters, receipts, \
notifications and anything automatic. Read only: draft, send, archive and delete nothing. \
For each, give who, the subject, since when (like '3 days'), and for (1) what they want in a few words.";

fn schema() -> serde_json::Value {
    let thread = json!({"type": "object", "properties": {
        "who": {"type": "string"}, "subject": {"type": "string"}, "since": {"type": "string"}, "ask": {"type": "string"}
    }, "required": ["who", "subject", "since", "ask"], "additionalProperties": false});
    json!({"type": "object", "properties": {
        "waiting_on_you": {"type": "array", "items": thread},
        "you_wait_on": {"type": "array", "items": thread}
    }, "required": ["waiting_on_you", "you_wait_on"], "additionalProperties": false})
}

impl Team {
    /// Read mail through Enkeon and sort who waits on whom. Read only.
    pub async fn inbox_scan(&self, model: &str) -> Result<Waiting, String> {
        let enkeon = crate::pair::enkeon().ok_or(
            "Mail is read through Enkeon. Sign in with `enkeon connect` in a terminal (or set ENKEON_API_KEY), connect Gmail there, then try again.",
        )?;
        let agent = Agent::new(model)
            .map_err(|e| e.to_string())?
            .instructions("You read the person's mail to tell them who is waiting on whom. You only read.")
            .enkeon(enkeon)
            .approver(DenyAll)
            .output_schema(schema())
            .close_with_answer();
        let mut s = Session::in_memory();
        let cancel = cookie_harness::CancellationToken::new();
        let run = agent.run_in(&mut s, Message::user(PROMPT), &cancel);
        let raw = tokio::time::timeout(std::time::Duration::from_secs(240), run)
            .await
            .map_err(|_| { cancel.cancel(); "Reading your mail took more than four minutes; try again.".to_string() })?
            .map_err(|e| e.to_string())?;
        serde_json::from_str(&raw).map_err(|e| format!("The scan's answer couldn't be read: {e}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_answer_shape_parses() {
        let w: Waiting = serde_json::from_str(r#"{"waiting_on_you":[{"who":"Anna","subject":"Quote","since":"2 days","ask":"price for 50"}],"you_wait_on":[]}"#).unwrap();
        assert_eq!(w.waiting_on_you[0].who, "Anna");
        assert!(schema()["required"].as_array().unwrap().len() == 2);
    }
}
