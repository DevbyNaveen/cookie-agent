//! The wall, and the ledger kept outside the worlds.
//!
//! Everything inside a world can be undone: it is files, and a world can be
//! rewound. What reaches the world outside cannot: a sent mail, a payment, a
//! post, an app going live. Such an action never runs from inside a world on
//! its own. It stops at the wall: it is written to the ledger as `waiting`,
//! and runs only when a person says yes (`approve`); a no is kept too.
//!
//! The ledger lives beside the worlds, never in one: rewinding a world, or
//! discarding it, never rewrites what really happened. Each entry carries the
//! hash of the one before it, so a changed or removed entry shows (`verify`).

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::util;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Entry {
    pub id: String,
    pub at: u64,
    pub world: String,
    pub engine: String,
    pub action: String,
    pub args: Value,
    /// What will happen, for the person.
    pub preview: String,
    /// `waiting` · `approved` · `refused` · `done` · `failed`
    pub state: String,
    pub by: Option<String>,
    pub result: Option<String>,
    /// The hash of the entry before this one (`""` for the first).
    pub prev: String,
    pub hash: String,
}

fn hash_of(e: &Entry) -> String {
    let mut c = e.clone();
    c.hash = String::new();
    util::sha256_hex(serde_json::to_string(&c).unwrap_or_default().as_bytes())
}

#[derive(Debug, Clone)]
pub struct Ledger {
    pub path: PathBuf,
}

impl Ledger {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn all(&self) -> Vec<Entry> {
        util::read_jsonl(&self.path)
    }

    /// The latest state of each entry (an entry's later lines supersede it).
    pub fn current(&self) -> Vec<Entry> {
        let mut by_id: std::collections::BTreeMap<String, Entry> = std::collections::BTreeMap::new();
        let mut order = Vec::new();
        for e in self.all() {
            if !by_id.contains_key(&e.id) {
                order.push(e.id.clone());
            }
            by_id.insert(e.id.clone(), e);
        }
        order.into_iter().filter_map(|id| by_id.remove(&id)).collect()
    }

    pub fn get(&self, id: &str) -> Option<Entry> {
        self.current().into_iter().find(|e| e.id == id)
    }

    fn append(&self, mut e: Entry) -> Result<Entry, String> {
        e.prev = self.all().last().map(|l| l.hash.clone()).unwrap_or_default();
        e.at = util::now();
        e.hash = hash_of(&e);
        util::append_jsonl(&self.path, &e)?;
        Ok(e)
    }

    /// An outside action stops at the wall.
    pub fn hold(&self, world: &str, engine: &str, action: &str, args: &Value, preview: &str) -> Result<Entry, String> {
        self.append(Entry { id: util::new_id("out"), world: world.into(), engine: engine.into(), action: action.into(), args: args.clone(), preview: util::clip(preview, 4_000), state: "waiting".into(), ..Entry::default() })
    }

    /// The person's answer.
    pub fn decide(&self, id: &str, yes: bool, by: &str) -> Result<Entry, String> {
        let mut e = self.get(id).ok_or("No such waiting action.")?;
        if e.state != "waiting" {
            return Err(format!("That action is already {}.", e.state));
        }
        e.state = if yes { "approved" } else { "refused" }.into();
        e.by = Some(by.into());
        self.append(e)
    }

    /// What came of an approved action.
    pub fn finish(&self, id: &str, ok: bool, result: &str) -> Result<Entry, String> {
        let mut e = self.get(id).ok_or("No such action.")?;
        e.state = if ok { "done" } else { "failed" }.into();
        e.result = Some(util::clip(result, 4_000));
        self.append(e)
    }

    pub fn waiting(&self) -> Vec<Entry> {
        self.current().into_iter().filter(|e| e.state == "waiting").collect()
    }

    /// Every line chains to the one before, and says what it is.
    pub fn verify(&self) -> Result<usize, String> {
        let all = self.all();
        let mut prev = String::new();
        for (i, e) in all.iter().enumerate() {
            if e.prev != prev || hash_of(e) != e.hash {
                return Err(format!("The ledger was changed at line {}.", i + 1));
            }
            prev = e.hash.clone();
        }
        Ok(all.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_outside_action_waits_and_the_ledger_chains() {
        let d = tempfile::tempdir().unwrap();
        let l = Ledger::new(d.path().join("ledger.jsonl"));
        let e = l.hold("w1", "mail", "send", &serde_json::json!({"to": "mara"}), "Send to Mara").unwrap();
        assert_eq!(l.waiting().len(), 1);
        assert!(l.decide(&e.id, true, "naveen").is_ok());
        assert!(l.decide(&e.id, true, "naveen").is_err(), "decided once");
        l.finish(&e.id, true, "sent").unwrap();
        assert_eq!(l.get(&e.id).unwrap().state, "done");
        assert_eq!(l.verify().unwrap(), 3);
        // Change one line: the chain shows it.
        let raw = std::fs::read_to_string(&l.path).unwrap().replace("Send to Mara", "Send to Eve");
        std::fs::write(&l.path, raw).unwrap();
        assert!(l.verify().is_err());
    }
}
