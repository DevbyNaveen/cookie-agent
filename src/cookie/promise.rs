//! What Cookie itself promised in an answer, by when: "I'll send the draft
//! Friday", "I'll check again tomorrow". The client keeps each as a plan in
//! the team's context, so the promise is seen, reminded and closed like any
//! other.
//!
//! Deterministic on purpose, no model call: a sentence in Cookie's own first
//! person, with a forward verb of doing and a day it names. A question, a
//! negation, a condition or an offer ("I can …", "Want me to …") is no
//! promise, and neither is anything in a letter Cookie drafted for someone
//! (from its greeting to its sign-off), a quote or a code block: those are
//! the person's words, not Cookie's.

use serde::Serialize;
use serde_json::{json, Value};

/// Promises kept from one answer, at most.
pub const MAX: usize = 3;

/// One promise: the sentence as written, and the day it is due (`YYYY-MM-DD`, UTC).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Promise {
    pub text: String,
    pub due: String,
}

/// Cookie's own dated promises in `answer`, in order, deduplicated by
/// their words, at most [`MAX`]. `now` is seconds since the Unix epoch.
pub fn promises_in(answer: &str, now: i64) -> Vec<Promise> {
    let today = now.div_euclid(86_400);
    let mut out: Vec<Promise> = Vec::new();
    for s in own_sentences(answer) {
        let l = s.to_lowercase().replace('\u{2019}', "'");
        if !is_promise(&l) {
            continue;
        }
        let Some(day) = due_in(&l, today) else { continue };
        let key: String = l.split_whitespace().collect::<Vec<_>>().join(" ");
        if out.iter().any(|p| p.text.to_lowercase().replace('\u{2019}', "'").split_whitespace().collect::<Vec<_>>().join(" ") == key) {
            continue;
        }
        out.push(Promise { text: s, due: ymd(day) });
        if out.len() == MAX {
            break;
        }
    }
    out
}

/// The client's line: `{answer, now}` → `{promises: [{text, due}]}`.
pub fn rpc(m: &Value) -> Result<Value, String> {
    let answer = m["answer"].as_str().ok_or("`answer` is required")?;
    let now = m["now"].as_f64().ok_or("`now` is required")? as i64;
    Ok(json!({"promises": promises_in(answer, now)}))
}

/// The sentences Cookie wrote in its own voice: outside code blocks, quotes
/// and drafted letters.
fn own_sentences(answer: &str) -> Vec<String> {
    let mut own = String::new();
    let (mut fenced, mut letter) = (false, false);
    for line in answer.lines() {
        let t = line.trim();
        if t.starts_with("```") {
            fenced = !fenced;
            continue;
        }
        if fenced || t.starts_with('>') {
            continue;
        }
        let l = t.to_lowercase();
        if letter {
            if is_sign_off(&l) {
                letter = false;
            }
            continue;
        }
        if is_greeting(&l) {
            letter = true;
            continue;
        }
        own.push_str(t);
        own.push('\n');
    }
    const ENDS: [char; 4] = ['.', '!', '?', '\n'];
    own.split(ENDS)
        .zip(own.split_inclusive(ENDS))
        // A question is never a promise: keep the mark that ended it.
        .filter(|(_, with_mark)| !with_mark.ends_with('?'))
        .map(|(s, _)| s.trim().trim_start_matches(['-', '*', '•']).trim().to_string())
        .filter(|s| (8..=300).contains(&s.chars().count()))
        .collect()
}

/// "Hi Anna," / "Dear team," / "Hello," — the start of a drafted letter.
fn is_greeting(l: &str) -> bool {
    ["hi ", "hi,", "hello", "dear ", "hey ", "hey,", "good morning", "good afternoon"].iter().any(|g| l.starts_with(g))
        && l.ends_with(',')
        && l.split_whitespace().count() <= 5
}

/// "Best," / "Thanks," / "Kind regards" — the end of one.
fn is_sign_off(l: &str) -> bool {
    let l = l.trim_end_matches([',', '.', '!']);
    ["best", "best regards", "kind regards", "regards", "thanks", "thank you", "many thanks", "cheers", "sincerely", "warm regards", "all the best"]
        .contains(&l)
}

/// A sentence in which Cookie commits to doing something itself.
fn is_promise(l: &str) -> bool {
    let negated = ["won't", "will not", "can't", "cannot", "not going to", "never"].iter().any(|n| l.contains(n));
    // A condition or an offer waits on the person: no promise yet.
    let conditional = l.starts_with("if ") || l.contains(" if ") || l.contains("unless") || l.contains("want me to") || l.contains("would you like");
    if negated || conditional {
        return false;
    }
    // Only "I": a "we" may be the team, and the team's promises are theirs.
    let first_person = ["i'll ", "i will ", "i'm going to ", "i am going to "];
    if !first_person.iter().any(|m| l.starts_with(m) || l.contains(&format!(" {m}"))) {
        return false;
    }
    let acts = [
        "send", "share", "get back", "follow up", "confirm", "deliver", "review", "book", "schedule", "update", "circulate", "forward",
        "prepare", "finish", "look into", "check", "let you know", "write", "draft", "remind", "report", "chase", "ping", "try again",
    ];
    acts.iter().any(|a| l.contains(a))
}

/// The day a sentence names, as days since the epoch: an ISO date, "today",
/// "tonight", "tomorrow", "end of the week" (Friday), "next week" (Monday),
/// a weekday (the next such day, never today), or a month and day in either
/// order.
fn due_in(l: &str, today: i64) -> Option<i64> {
    let words: Vec<&str> = l.split(|c: char| !c.is_ascii_alphanumeric() && c != '-').filter(|w| !w.is_empty()).collect();
    if let Some(d) = words.iter().find_map(|w| parse_ymd(w)) {
        return Some(d);
    }
    let has = |w: &str| words.contains(&w);
    if has("tomorrow") {
        return Some(today + 1);
    }
    if has("today") || has("tonight") {
        return Some(today);
    }
    let next = |wd: i64, from: i64| (from..from + 7).find(|d| weekday(*d) == wd);
    if l.contains("end of the week") || l.contains("end of week") {
        return next(4, today);
    }
    if l.contains("next week") {
        return next(0, today + 1);
    }
    const DAYS: [&str; 7] = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];
    if let Some(wd) = DAYS.iter().position(|d| has(d)) {
        return next(wd as i64, today + 1);
    }
    const MONTHS: [&[&str]; 12] = [
        &["january", "jan"], &["february", "feb"], &["march", "mar"], &["april", "apr"], &["may"], &["june", "jun"],
        &["july", "jul"], &["august", "aug"], &["september", "sept", "sep"], &["october", "oct"], &["november", "nov"], &["december", "dec"],
    ];
    let day_of = |w: &str| -> Option<i64> {
        let digits = w.trim_end_matches(|c: char| c.is_ascii_alphabetic());
        let ok = !digits.is_empty() && digits.len() <= 2 && matches!(&w[digits.len()..], "" | "st" | "nd" | "rd" | "th");
        digits.parse().ok().filter(|d| ok && (1..=31).contains(d))
    };
    for (i, w) in words.iter().enumerate() {
        let Some(m) = MONTHS.iter().position(|names| names.contains(w)) else { continue };
        let day = words.get(i + 1).and_then(|n| day_of(n)).or_else(|| i.checked_sub(1).and_then(|p| day_of(words[p])));
        let Some(day) = day else { continue };
        let (year, _, _) = civil(today);
        let this = days_from_civil(year, m as i64 + 1, day)?;
        return if this >= today { Some(this) } else { days_from_civil(year + 1, m as i64 + 1, day) };
    }
    None
}

/// Monday = 0. The epoch was a Thursday.
fn weekday(day: i64) -> i64 {
    (day + 3).rem_euclid(7)
}

fn parse_ymd(w: &str) -> Option<i64> {
    let mut p = w.splitn(3, '-');
    let (y, m, d) = (p.next()?, p.next()?, p.next()?);
    if y.len() != 4 || m.len() != 2 || d.len() != 2 {
        return None;
    }
    days_from_civil(y.parse().ok()?, m.parse().ok()?, d.parse().ok()?)
}

fn ymd(day: i64) -> String {
    let (y, m, d) = civil(day);
    format!("{y:04}-{m:02}-{d:02}")
}

/// Days since the epoch to (year, month, day) — Howard Hinnant's algorithm.
fn civil(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(month <= 2), month, day)
}

/// (year, month, day) to days since the epoch; `None` for a day the month
/// does not have.
fn days_from_civil(y: i64, m: i64, d: i64) -> Option<i64> {
    if !(1..=12).contains(&m) || d < 1 {
        return None;
    }
    let y2 = if m <= 2 { y - 1 } else { y };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    (civil(days) == (y, m, d)).then_some(days)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Friday 2026-10-23, 21:00 UTC.
    const NOW: i64 = 1_792_789_200;

    fn dues(answer: &str) -> Vec<(String, String)> {
        promises_in(answer, NOW).into_iter().map(|p| (p.text, p.due)).collect()
    }

    #[test]
    fn days_are_read_as_the_next_such_day() {
        let today = NOW / 86_400;
        assert_eq!(ymd(today), "2026-10-23");
        assert_eq!(weekday(today), 4, "a Friday");
        let at = |s: &str| due_in(s, today).map(ymd);
        assert_eq!(at("tomorrow").as_deref(), Some("2026-10-24"));
        assert_eq!(at("by tonight").as_deref(), Some("2026-10-23"));
        assert_eq!(at("on friday").as_deref(), Some("2026-10-30"), "today's weekday is next week's");
        assert_eq!(at("monday morning").as_deref(), Some("2026-10-26"));
        assert_eq!(at("end of the week").as_deref(), Some("2026-10-23"));
        assert_eq!(at("next week").as_deref(), Some("2026-10-26"));
        assert_eq!(at("on 2026-11-02").as_deref(), Some("2026-11-02"));
        assert_eq!(at("by 31 october").as_deref(), Some("2026-10-31"));
        assert_eq!(at("on jan 5th").as_deref(), Some("2027-01-05"), "a month gone by is next year's");
        assert_eq!(at("on 2026-02-30"), None, "no such day");
        assert_eq!(at("in the market soon"), None, "mar in market is no month");
        assert_eq!(days_from_civil(2024, 2, 29).map(ymd).as_deref(), Some("2024-02-29"));
    }

    #[test]
    fn cookies_own_dated_promises_are_caught() {
        let answer = "Here is what I found about Acme.\n\nI\u{2019}ll send the draft Friday. I'll check again tomorrow!\n- I will follow up with the pricing page on 2026-11-02.";
        assert_eq!(
            dues(answer),
            [
                ("I\u{2019}ll send the draft Friday".to_string(), "2026-10-30".to_string()),
                ("I'll check again tomorrow".to_string(), "2026-10-24".to_string()),
                ("I will follow up with the pricing page on 2026-11-02".to_string(), "2026-11-02".to_string()),
            ]
        );
    }

    #[test]
    fn what_is_not_cookies_dated_promise_is_left_alone() {
        for answer in [
            "I'll send the draft.",                                  // no day
            "Should I send the draft Friday?",                       // a question
            "I won't send anything before Friday.",                  // a negation
            "If you want, I'll send the draft Friday.",              // a condition
            "Want me to check again tomorrow",                       // an offer
            "I can send the draft Friday.",                          // an offer, not a promise
            "Anna will send the contract Friday.",                   // someone else's
            "You'll get the invoice tomorrow from finance.",         // not first person
            "We'll send the deck Friday.",                           // the team's, maybe
            "I'll be in Riga tomorrow.",                             // nothing to do
            "> I'll send the deck Friday.",                          // a quote
            "```\nI'll send the deck Friday.\n```",                  // a code block
        ] {
            assert!(promises_in(answer, NOW).is_empty(), "{answer}");
        }
    }

    #[test]
    fn a_letter_drafted_for_the_person_holds_their_promises_not_cookies() {
        let answer = "A reply you can send:\n\nHi Anna,\nThanks for the call. I'll send the signed contract on Monday.\nBest,\nMarta\n\nI'll check tomorrow whether she answered.";
        assert_eq!(dues(answer), [("I'll check tomorrow whether she answered".to_string(), "2026-10-24".to_string())]);
    }

    #[test]
    fn three_at_most_and_the_same_words_once() {
        let answer = "I'll send it today. I'll  send it today. I'll check it tomorrow. I'll update it Monday. I'll review it Tuesday.";
        let p = dues(answer);
        assert_eq!(p.len(), MAX);
        assert_eq!(p[0].0, "I'll send it today");
        assert_eq!(p[1].0, "I'll check it tomorrow", "the same words twice are one promise");
    }

    #[test]
    fn any_text_reads_without_a_panic() {
        for t in ["", "?", "I'll", "i'll send 31st of", "I'll send on 9999-99-99 friday", "🍪 I'll send tomorrow 🍪", "Hi x,\n", "```"] {
            let _ = promises_in(t, NOW);
            let _ = promises_in(t, i64::MIN / 4);
        }
        assert_eq!(rpc(&json!({"answer": "I'll ping Anna tomorrow.", "now": NOW as f64})).unwrap()["promises"][0]["due"], "2026-10-24");
        assert!(rpc(&json!({"now": 1})).is_err());
    }
}
