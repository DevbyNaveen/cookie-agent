//! Cookie suggests a hire when a gap repeats, from evidence, not a hunch.
//!
//! The signal is Cookie's own record: requests it did itself because no
//! teammate's job fit (it handed nothing over). When two or more of them in
//! a week fall in the same lane, and no teammate's name or job covers that
//! lane, the morning card proposes a hire with the requests quoted. The
//! person decides; nothing is hired from here. A lane proposed in the last
//! two weeks is not proposed again.
//!
//! A small keyword map on purpose: a wrong suggestion costs one "no", and a
//! model call to guess would cost every morning to be wrong more eloquently.
//!
//! Ported from the super console (gateway `chat/hire_gap.rs`).

/// Lane → a suggested job title, and the words that place a request in it.
pub const LANES: &[(&str, &str, &[&str])] = &[
    ("research", "Researcher", &["research", "competitor", "market study", "find out about", "look into", "compare "]),
    ("money", "Bookkeeper", &["invoice", "receipt", "expense", "budget", "bookkeep", "accounting", "tax"]),
    ("writing", "Writer", &["write a", "draft a", "blog", "newsletter", "copy for", "rewrite", "proofread"]),
    ("mail", "Inbox keeper", &["reply to", "email", "inbox", "follow up with", "mail"]),
    ("schedule", "Scheduler", &["meeting", "calendar", "schedule", "book a", "appointment"]),
    ("sales", "Sales lead", &["lead", "prospect", "pipeline", "outreach", "deal"]),
    ("support", "Support lead", &["customer issue", "ticket", "support", "complaint", "refund"]),
    ("code", "Developer", &["code", "bug", "script", "deploy", "repository", "function"]),
    ("social", "Social media", &["tweet", "linkedin", "instagram", "post on", "social media"]),
];

/// Requests in one lane before a hire is worth the person's attention.
pub const MIN_GAPS: usize = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HireProposal {
    pub lane: &'static str,
    pub title: &'static str,
    /// The requests, as the person wrote them (at most four).
    pub evidence: Vec<String>,
}

fn lane_of(text: &str) -> Option<usize> {
    let t = format!(" {} ", text.to_lowercase());
    LANES.iter().position(|(_, _, words)| words.iter().any(|w| t.contains(w)))
}

/// A teammate whose name or job carries the lane's words covers it.
fn covered(lane: usize, team: &[(String, String)]) -> bool {
    let (_, title, words) = LANES[lane];
    team.iter().any(|(name, job)| {
        let t = format!(" {} {} ", name.to_lowercase(), job.to_lowercase());
        t.contains(&title.to_lowercase()) || words.iter().any(|w| t.contains(w.trim()))
    })
}

/// At most one proposal: the uncovered lane with the most distinct requests.
/// `team`: each teammate's (name, job), Cookie not included.
pub fn propose(requests: &[String], team: &[(String, String)], recently: &[String]) -> Option<HireProposal> {
    let mut by: Vec<(usize, Vec<String>)> = Vec::new();
    for r in requests.iter().map(|r| r.trim()).filter(|r| !r.is_empty()) {
        let Some(lane) = lane_of(r) else { continue };
        let i = by.iter().position(|(l, _)| *l == lane).unwrap_or_else(|| {
            by.push((lane, Vec::new()));
            by.len() - 1
        });
        if !by[i].1.iter().any(|e| e.eq_ignore_ascii_case(r)) {
            by[i].1.push(r.to_string());
        }
    }
    by.into_iter()
        .filter(|(_, ev)| ev.len() >= MIN_GAPS)
        .filter(|(lane, _)| !covered(*lane, team))
        .filter(|(lane, _)| !recently.iter().any(|r| r == LANES[*lane].0))
        .max_by_key(|(_, ev)| ev.len())
        .map(|(lane, mut evidence)| {
            evidence.truncate(4);
            HireProposal { lane: LANES[lane].0, title: LANES[lane].1, evidence }
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_repeated_gap_nobody_covers_becomes_one_proposal() {
        let asks = vec!["Find the receipt for the hotel".to_string(), "Sort this month's expense list".into(), "What's the weather".into()];
        let p = propose(&asks, &[("Scout".into(), "Researches competitors".into())], &[]).unwrap();
        assert_eq!((p.lane, p.title), ("money", "Bookkeeper"));
        assert_eq!(p.evidence.len(), 2);
        assert!(propose(&asks[..1], &[], &[]).is_none(), "once is not a pattern");
        assert!(propose(&asks, &[("Ledger".into(), "Keeps the invoices and expenses".into())], &[]).is_none(), "covered");
        assert!(propose(&asks, &[], &["money".into()]).is_none(), "asked recently");
    }
}
