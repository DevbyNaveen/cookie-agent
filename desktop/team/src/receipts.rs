//! Receipts: every action an agent took, why it was allowed, which of its
//! values came from content the person didn't write, and what it came to.
//!
//! The harness writes them (`cookie_harness::receipt`), from the checks it
//! made itself, never from what the model says it did. Each job keeps its own
//! (`Job::receipts`); the chat shows them under the answer, and every receipt
//! of every agent can be read back or exported (`all`, `csv`).

use cookie_harness::receipt::{Because, Receipt};
use serde::{Deserialize, Serialize};

use crate::Team;

/// A receipt as a job keeps it: the harness's record plus the step's words.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ActionReceipt {
    #[serde(flatten)]
    pub receipt: Receipt,
    /// What it did, as the chat says it ("Sent an email to anna@x.com").
    #[serde(default)]
    pub did: String,
}

impl ActionReceipt {
    /// The ground in one line, as a person reads it.
    pub fn because_line(&self) -> String {
        let said = self.receipt.said();
        let mut parts: Vec<String> = Vec::new();
        if !said.is_empty() {
            parts.push(format!("you said “{}”", said.join("” and “")));
        }
        for b in &self.receipt.because {
            match b {
                Because::Approved => parts.push("you said yes".into()),
                Because::EarnedTrust => parts.push("you have said yes to this kind of action every time".into()),
                Because::AllowedDestination { value, .. } => parts.push(format!("{value} is a destination you allowed")),
                Because::Found { value, .. } => parts.push(format!("its own search found {value}")),
                Because::Said { .. } | Because::Request { .. } => {}
            }
        }
        parts.join("; ")
    }
}

/// The receipts one job collects while it runs, tied to each step's words.
#[derive(Default)]
pub(crate) struct Collector {
    words: std::collections::HashMap<String, String>,
    kept: Vec<ActionReceipt>,
}

impl Collector {
    pub(crate) fn words(&mut self, id: &str, did: &str) {
        self.words.insert(id.to_string(), did.to_string());
    }

    pub(crate) fn add(&mut self, receipt: Receipt) -> ActionReceipt {
        let did = self.words.get(&receipt.id).cloned().unwrap_or_else(|| receipt.tool.clone());
        let r = ActionReceipt { receipt, did };
        self.kept.push(r.clone());
        r
    }

    pub(crate) fn take(&mut self) -> Vec<ActionReceipt> {
        std::mem::take(&mut self.kept)
    }
}

/// One receipt with the job and agent it belongs to, for the list and the export.
#[derive(Debug, Clone, Serialize)]
pub struct Listed {
    pub agent: String,
    pub agent_name: String,
    pub job: String,
    pub request: String,
    #[serde(flatten)]
    pub receipt: ActionReceipt,
    pub because_line: String,
}

impl Team {
    /// Every receipt, newest first: of one agent, or of all. At most `limit`.
    pub async fn receipts(&self, agent: Option<&str>, limit: usize) -> Vec<Listed> {
        let mut out = Vec::new();
        for a in self.agents().await {
            if agent.is_some_and(|id| id != a.id) || crate::bench::is_probe(&a.id) {
                continue;
            }
            for job in self.jobs(&a.id) {
                for r in job.receipts {
                    out.push(Listed {
                        agent: a.id.clone(),
                        agent_name: a.name.clone(),
                        job: job.id.clone(),
                        request: crate::util::clip(&job.input, 300),
                        because_line: r.because_line(),
                        receipt: r,
                    });
                }
            }
        }
        out.sort_by(|a, b| b.receipt.receipt.at.cmp(&a.receipt.receipt.at));
        out.truncate(limit);
        out
    }

    /// Every receipt as CSV, newest first, for the person to keep.
    pub async fn receipts_csv(&self) -> String {
        let field = |s: &str| format!("\"{}\"", s.replace('"', "\"\"").replace(['\n', '\r'], " "));
        let mut out = String::from("time,agent,job,action,tool,effect,decision,outcome,because,from_data,note\n");
        for l in self.receipts(None, usize::MAX).await {
            let r = &l.receipt.receipt;
            let time = chrono::DateTime::from_timestamp(r.at as i64, 0).map(|t| t.to_rfc3339()).unwrap_or_default();
            let effect = serde_json::to_value(r.effect).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
            let row = [
                time,
                l.agent_name.clone(),
                l.job.clone(),
                l.receipt.did.clone(),
                r.tool.clone(),
                effect,
                r.decision.clone(),
                r.outcome.clone(),
                l.because_line.clone(),
                r.from_data.join("; "),
                r.note.clone().unwrap_or_default(),
            ];
            out.push_str(&row.iter().map(|s| field(s)).collect::<Vec<_>>().join(","));
            out.push('\n');
        }
        out
    }

    /// Every receipt written to a CSV file in Cookie's folder (`exports/`); its path.
    pub async fn export_receipts(&self) -> Result<String, String> {
        let dir = self.paths.root.join("exports");
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let path = dir.join(format!("receipts-{}.csv", chrono::Local::now().format("%Y-%m-%d-%H%M")));
        std::fs::write(&path, self.receipts_csv().await).map_err(|e| e.to_string())?;
        Ok(path.to_string_lossy().into_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cookie_harness::tool::Effect;

    fn receipt(because: Vec<Because>, from_data: Vec<String>) -> Receipt {
        Receipt {
            id: "c1".into(),
            tool: "send_email".into(),
            effect: Effect::Outbound,
            decision: "approved".into(),
            because,
            from_data,
            outcome: "done".into(),
            note: None,
            at: 1,
        }
    }

    #[test]
    fn a_receipt_reads_as_one_line_and_keeps_the_steps_words() {
        let mut c = Collector::default();
        c.words("c1", "Sent an email to anna@x.com");
        let r = c.add(receipt(
            vec![Because::Approved, Because::Said { arg: "to".into(), value: "anna@x.com".into(), quote: "Send it to anna@x.com.".into() }],
            vec![],
        ));
        assert_eq!(r.did, "Sent an email to anna@x.com");
        assert_eq!(r.because_line(), "you said “Send it to anna@x.com.”; you said yes");
        assert_eq!(c.take().len(), 1);
        assert!(c.take().is_empty());
        // A round trip keeps every field, the harness's ones flattened in.
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["outcome"], "done");
        assert_eq!(serde_json::from_value::<ActionReceipt>(json).unwrap(), r);
    }
}
