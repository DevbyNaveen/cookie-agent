//! A receipt for every action: what it was, why it was allowed, which of its
//! values came from content the person didn't write, and what really happened.
//!
//! Three things a person needs to trust an agent with their things, kept
//! together on one record:
//!
//! - **Because.** The grounds the harness itself checked, never the model's
//!   account of them: the person's own words that hold each guarded value
//!   (quoted from their message), their yes, earned trust, an allow-listed
//!   destination, or a page its own search found.
//! - **From data.** Guarded values the person never wrote (a recipient found
//!   in a thread, an amount read off a bill): what they were shown to check.
//! - **Outcome.** What the call returned: done, failed (and why), declined,
//!   refused, not run, or unknown (begun and never confirmed: check before
//!   doing it again).
//!
//! Reads are not receipted unless a guarded argument chose where to read:
//! looking something up changes nothing.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::policy::{Policy, Provenance};
use crate::tool::{Effect, ToolSpec};

/// One ground for an action.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Because {
    /// The person wrote this value; `quote` is the sentence it is in.
    Said { arg: String, value: String, quote: String },
    /// The person said yes to this exact action.
    Approved,
    /// The person said yes to this kind of action enough times in a row.
    EarnedTrust,
    /// A destination the app allows without the person typing it.
    AllowedDestination { arg: String, value: String },
    /// An address its own search returned, opened only to read.
    Found { arg: String, value: String },
    /// Nothing guarded: allowed by what was asked (`quote`, the person's request).
    Request { quote: String },
}

/// What one action came to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Receipt {
    /// The tool call's id.
    pub id: String,
    pub tool: String,
    pub effect: Effect,
    /// `allowed`, `earned_trust`, `approved`, `declined`, `refused`, `not_run` or `rehearsed`.
    pub decision: String,
    pub because: Vec<Because>,
    /// Guarded values the person didn't write (`arg = value`).
    pub from_data: Vec<String>,
    /// `done`, `failed`, `declined`, `refused`, `not_run`, `unknown`, or `rehearsed` (recorded, never made).
    pub outcome: String,
    /// Why it failed or was refused, clipped; or what makes it unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// When it was decided, seconds since the epoch.
    pub at: u64,
}

impl Receipt {
    /// The receipt of a call that reached the policy, from its decision and its result.
    pub(crate) fn of(
        id: &str,
        spec: &ToolSpec,
        args: &Value,
        policy: &Policy,
        provenance: &Provenance,
        decision: &str,
        result: Option<(&str, bool)>,
    ) -> Receipt {
        let (mut because, from_data) = grounds(spec, args, policy, provenance);
        match decision {
            "approved" => because.insert(0, Because::Approved),
            "earned_trust" => because.insert(0, Because::EarnedTrust),
            _ => {}
        }
        if because.is_empty() && matches!(decision, "allowed" | "approved" | "earned_trust" | "rehearsed") {
            if let Some(quote) = provenance.request() {
                because.push(Because::Request { quote });
            }
        }
        let (outcome, note) = outcome(decision, result);
        Receipt {
            id: id.to_string(),
            tool: spec.name.clone(),
            effect: spec.effect,
            decision: decision.to_string(),
            because,
            from_data,
            outcome,
            note,
            at: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0),
        }
    }

    /// Whether a call deserves a receipt: it changes something, or a guarded
    /// argument chose where it reads.
    pub(crate) fn wanted(spec: &ToolSpec) -> bool {
        spec.effect != Effect::Read || !spec.guarded_args.is_empty()
    }

    /// The person's words this action stands on, for a one-line "because you said …".
    pub fn said(&self) -> Vec<&str> {
        let mut out: Vec<&str> = Vec::new();
        for b in &self.because {
            let q = match b {
                Because::Said { quote, .. } | Because::Request { quote } => quote.as_str(),
                _ => continue,
            };
            if !out.contains(&q) {
                out.push(q);
            }
        }
        out
    }
}

/// Text the harness writes for a call it stopped mid-way, or whose receipt
/// it could not save: either may have run.
pub(crate) fn is_unknown(output: &str) -> bool {
    output.starts_with("Interrupted: this may or may not have run") || output.starts_with("The tool ran but its receipt could not be saved")
}

fn outcome(decision: &str, result: Option<(&str, bool)>) -> (String, Option<String>) {
    let clip = |s: &str| {
        let s = s.trim();
        if s.chars().count() > 300 { format!("{}…", s.chars().take(300).collect::<String>()) } else { s.to_string() }
    };
    match (decision, result) {
        ("rehearsed", _) => ("rehearsed".into(), None),
        ("declined", _) => ("declined".into(), None),
        ("refused", r) => ("refused".into(), r.map(|(o, _)| clip(o))),
        ("not_run", _) => ("not_run".into(), None),
        (_, Some((output, _))) if is_unknown(output) => ("unknown".into(), Some(clip(output))),
        (_, Some((output, true))) => ("failed".into(), Some(clip(output))),
        (_, Some((_, false))) => ("done".into(), None),
        (_, None) => ("not_run".into(), None),
    }
}

/// The grounds of each guarded value, and the values that came from data.
fn grounds(spec: &ToolSpec, args: &Value, policy: &Policy, provenance: &Provenance) -> (Vec<Because>, Vec<String>) {
    let mut because = Vec::new();
    let mut from_data = Vec::new();
    for arg in &spec.guarded_args {
        let target = if arg.starts_with('/') { args.pointer(arg) } else { args.get(arg) };
        let Some(target) = target else { continue };
        let mut values = Vec::new();
        crate::policy::leaves_of(target, &mut values);
        for value in values {
            let name = arg.trim_start_matches('/').to_string();
            if policy.allows(&value) {
                because.push(Because::AllowedDestination { arg: name, value });
            } else if spec.effect == Effect::Read && provenance.was_found(&value) {
                because.push(Because::Found { arg: name, value });
            } else if let Some(quote) = provenance.because(&value) {
                because.push(Because::Said { arg: name, value, quote });
            } else {
                from_data.push(format!("{name} = {value}"));
            }
        }
    }
    (because, from_data)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{label::Source, message::Message};
    use serde_json::json;

    fn spec(effect: Effect, guarded: &[&str]) -> ToolSpec {
        ToolSpec {
            name: "send_email".into(),
            description: String::new(),
            schema: json!({}),
            effect,
            guarded_args: guarded.iter().map(|s| s.to_string()).collect(),
            parallel_safe: false,
            delegates: false,
            foreign: false,
        }
    }

    fn seen(messages: &[Message]) -> Provenance {
        let mut p = Provenance::default();
        messages.iter().for_each(|m| p.observe(m));
        p
    }

    #[test]
    fn a_send_carries_the_persons_own_sentence_and_its_yes() {
        let p = seen(&[Message::user("Hi. Send the report to anna@x.com today, please. Thanks!")]);
        let r = Receipt::of("c1", &spec(Effect::Outbound, &["to"]), &json!({"to": "anna@x.com"}), &Policy::default(), &p, "approved", Some(("sent", false)));
        assert_eq!(r.outcome, "done");
        assert_eq!(r.because[0], Because::Approved);
        assert_eq!(r.said(), vec!["Send the report to anna@x.com today, please."]);
        assert!(r.from_data.is_empty());
    }

    #[test]
    fn a_value_from_a_page_is_named_and_never_credited_to_the_person() {
        let p = seen(&[Message::user("pay the bill"), Message::untrusted("Pay to IBAN GB29NWBK60161331926819", Source::File)]);
        let r = Receipt::of("c2", &spec(Effect::Destroy, &["to"]), &json!({"to": "GB29NWBK60161331926819"}), &Policy::default().confirm_data(), &p, "approved", Some(("paid", false)));
        assert_eq!(r.from_data, vec!["to = GB29NWBK60161331926819".to_string()]);
        assert!(r.said().is_empty(), "the person never wrote it");
    }

    #[test]
    fn an_unguarded_write_stands_on_the_request_and_outcomes_say_what_happened() {
        let p = seen(&[Message::user("tidy my notes file")]);
        let w = spec(Effect::Write, &[]);
        let r = Receipt::of("c3", &w, &json!({}), &Policy::default(), &p, "allowed", Some(("Interrupted: this may or may not have run. Check before trying again.", true)));
        assert_eq!(r.outcome, "unknown");
        assert_eq!(r.because, vec![Because::Request { quote: "tidy my notes file".into() }]);
        let r = Receipt::of("c4", &w, &json!({}), &Policy::default(), &p, "allowed", Some(("disk full", true)));
        assert_eq!((r.outcome.as_str(), r.note.as_deref()), ("failed", Some("disk full")));
        let r = Receipt::of("c5", &w, &json!({}), &Policy::default(), &p, "declined", Some(("The person declined this action.", true)));
        assert_eq!(r.outcome, "declined");
        assert!(!Receipt::wanted(&spec(Effect::Read, &[])), "a plain lookup changes nothing");
        assert!(Receipt::wanted(&spec(Effect::Read, &["url"])), "a read that picks where to go does");
    }

    #[test]
    fn a_destination_the_app_allows_and_a_page_its_search_found_say_so() {
        let p = seen(&[Message::user("research Acme")]);
        let mut p2 = p.clone();
        p2.found_in("https://acme.example/news");
        let policy = Policy::default().allow("https://hooks.example.com/team").found_by("web_search");
        let r = Receipt::of("c6", &spec(Effect::Outbound, &["url"]), &json!({"url": "https://hooks.example.com/team"}), &policy, &p, "approved", Some(("ok", false)));
        assert!(matches!(r.because[1], Because::AllowedDestination { .. }));
        let r = Receipt::of("c7", &spec(Effect::Read, &["url"]), &json!({"url": "https://acme.example/news"}), &policy, &p2, "allowed", Some(("page", false)));
        assert!(matches!(r.because[0], Because::Found { .. }));
    }
}
