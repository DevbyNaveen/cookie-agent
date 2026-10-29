//! How Cookie's words read before a person reads them. A few tells mark text
//! as written by an AI: a dash used as punctuation, an "it's not X, it's Y"
//! reveal, a list of three "no …", a handful of stock phrases, and words
//! about being an AI. They are found here without a model, so the same text
//! always gets the same answer. Cookie's own answer is sent back once to be
//! rewritten (`Agent::finish_check`), and so is a draft or message a tool
//! would carry to a person (`Tool::send_back`); never twice.
//!
//! Single words are weak evidence: word frequencies shifted after 2022, but
//! no one word marks a text as a model's (Geng & Trotta, ACL Findings 2025,
//! arXiv 2502.09606). So the list of phrases is short, and the dashes and the
//! shapes of sentences carry the weight.

use serde::Serialize;
use serde_json::{json, Value};

/// One tell, with the words around it as written.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Problem {
    /// `dash`, `reveal`, `negation_list`, `filler` or `ai_self`.
    pub rule: &'static str,
    pub excerpt: String,
}

/// Problems reported for one text, at most: enough to rewrite from.
pub const MAX_PROBLEMS: usize = 10;

/// Phrases no teammate who knows the reader writes. Each is matched as whole
/// words, any case, with either apostrophe.
const FILLER: &[&str] = &[
    // An opener for a stranger, in a message to someone you know.
    "hope this email finds you well",
    "hope this message finds you well",
    // The word that rose most in papers after ChatGPT (Geng & Trotta's list).
    "delve",
    "delves",
    "delving",
    // Marketing filler that says nothing about the thing.
    "in today's fast-paced",
    "game-changer",
    "game changer",
    "seamless",
    "seamlessly",
    // "Leverage" as a verb, where "use" says it.
    "leveraging",
    "to leverage",
    "can leverage",
    "we leverage",
    "will leverage",
    // An assistant serving a customer, not a teammate doing the job.
    "i'd be happy to",
    "i would be happy to",
    "great question",
    "let me know if you have any questions",
];

/// Words about being an AI: the reader knows who wrote it.
const AI_SELF: &[&str] = &["as an ai", "as a language model", "i'm an ai", "i am an ai", "i'm just an ai", "your ai assistant"];

/// The tells in `text`, in the order of the rules, at most [`MAX_PROBLEMS`].
pub fn check(text: &str) -> Vec<Problem> {
    let mut out = Vec::new();
    dashes(text, &mut out);
    reveals(text, &mut out);
    negation_lists(text, &mut out);
    for (rule, list) in [("filler", FILLER), ("ai_self", AI_SELF)] {
        for phrase in list {
            let mut from = 0;
            while let Some((start, end)) = find(text, phrase, from) {
                out.push(Problem { rule, excerpt: around(text, start, end) });
                from = end;
            }
        }
    }
    out.truncate(MAX_PROBLEMS);
    out
}

/// The tells in the string values of `keys` anywhere in a tool's arguments
/// (`subject`, `body`: the words a person will read).
pub fn in_args(args: &Value, keys: &[String]) -> Vec<Problem> {
    fn walk(v: &Value, keys: &[String], out: &mut Vec<Problem>) {
        match v {
            Value::Object(map) => {
                for (k, v) in map {
                    match v {
                        Value::String(s) if keys.contains(k) => out.extend(check(s)),
                        _ => walk(v, keys, out),
                    }
                }
            }
            Value::Array(items) => items.iter().for_each(|v| walk(v, keys, out)),
            _ => {}
        }
    }
    let mut out = Vec::new();
    walk(args, keys, &mut out);
    out.truncate(MAX_PROBLEMS);
    out
}

/// What the model is told when its words come back to be rewritten.
pub fn note(problems: &[Problem]) -> String {
    let lines: Vec<String> = problems.iter().map(|p| format!("- {}: \"{}\"", hint(p.rule), p.excerpt)).collect();
    format!(
        "Before this goes to a person: parts of it read like an AI wrote it. Write it again without these, in plain words, \
         keeping the meaning, the facts and about the same length:\n{}",
        lines.join("\n")
    )
}

fn hint(rule: &str) -> &'static str {
    match rule {
        "dash" => "a dash used as punctuation (use a comma, a colon, a full stop or brackets)",
        "reveal" => "a \"not this, it's that\" reveal (say what it is, plainly)",
        "negation_list" => "a list of \"no this, no that, no the other\" (say what it is instead)",
        "filler" => "a stock phrase (cut it, or say the thing itself)",
        _ => "words about being an AI (cut them)",
    }
}

/// One `voice_check` line: `{text}` → `{ok, problems: [{rule, excerpt}]}`.
pub fn rpc(m: &Value) -> Result<Value, String> {
    let text = m.get("text").and_then(Value::as_str).ok_or("`text` is missing")?;
    let problems = check(text);
    Ok(json!({"ok": problems.is_empty(), "problems": problems}))
}

/// Em and en dashes used as punctuation, their HTML names, and ` -- `
/// standing in for one. Not: a hyphen in a word or a range (`2-3`), an en
/// dash between two numbers (`2019–2021`), or a dash after Cyrillic, where
/// it is grammar (`Москва — столица`).
fn dashes(text: &str, out: &mut Vec<Problem>) {
    for (i, c) in text.char_indices() {
        if c != '\u{2014}' && c != '\u{2013}' {
            continue;
        }
        let end = i + c.len_utf8();
        let before = text[..i].chars().next_back();
        let after = text[end..].chars().next();
        if c == '\u{2013}' && before.is_some_and(|b| b.is_ascii_digit()) && after.is_some_and(|a| a.is_ascii_digit()) {
            continue;
        }
        if text[..i].chars().rev().find(|c| !c.is_whitespace()).is_some_and(|c| ('\u{0400}'..='\u{04FF}').contains(&c)) {
            continue;
        }
        out.push(Problem { rule: "dash", excerpt: around(text, i, end) });
    }
    for entity in ["&mdash;", "&ndash;"] {
        let mut from = 0;
        while let Some((start, end)) = find(text, entity, from) {
            out.push(Problem { rule: "dash", excerpt: around(text, start, end) });
            from = end;
        }
    }
    // A word, a space, `--`, a space: a dash typed with hyphens. A line that
    // is only `-- ` (a mail signature's separator) is not one.
    let mut from = 0;
    while let Some(at) = text.get(from..).and_then(|t| t.find(" -- ")).map(|at| at + from) {
        let line_before = text[..at].rsplit('\n').next().unwrap_or_default();
        if !line_before.trim().is_empty() {
            out.push(Problem { rule: "dash", excerpt: around(text, at + 1, at + 3) });
        }
        from = at + 3;
    }
}

/// Sentences, as byte ranges, cut at sentence ends and line breaks.
fn sentences(text: &str) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut start = 0;
    for (i, c) in text.char_indices() {
        if matches!(c, '.' | '!' | '?' | '\n' | '\u{3002}' | '\u{FF01}' | '\u{FF1F}') {
            out.push((start, i));
            start = i + c.len_utf8();
        }
    }
    out.push((start, text.len()));
    out.into_iter().filter(|&(a, b)| !text[a..b].trim().is_empty()).collect()
}

const SUBJECTS: [&str; 3] = ["it", "this", "that"];

/// "It's not X, it's Y", "This isn't X. It's Y", "not just X, but Y".
fn reveals(text: &str, out: &mut Vec<Problem>) {
    let negative: Vec<String> = SUBJECTS
        .iter()
        .flat_map(|s| [format!("{s}'s not "), format!("{s} is not "), format!("{s} isn't "), format!("{s} was not "), format!("{s} wasn't ")])
        .collect();
    let positive: Vec<String> = SUBJECTS.iter().flat_map(|s| [format!("{s}'s "), format!("{s} is "), format!("{s} was ")]).collect();
    let spans = sentences(text);
    for (n, &(a, b)) in spans.iter().enumerate() {
        let s = &text[a..b];
        for neg in &negative {
            let Some((_, neg_end)) = find(s, neg, 0) else { continue };
            // In the same sentence, after a comma, a semicolon or a colon.
            let turn = positive
                .iter()
                .flat_map(|p| [", ", "; ", ": "].map(|sep| format!("{sep}{p}")))
                .find_map(|p| find(s, &p, neg_end).map(|(_, end)| end));
            // Or the next sentence starts with the turn.
            let next = spans.get(n + 1).filter(|_| turn.is_none() && starts(s, neg)).and_then(|&(c, d)| {
                let t = &text[c..d];
                let lead = t.len() - t.trim_start().len();
                positive.iter().find_map(|p| matches_at(t.trim_start(), 0, p)).map(|e| c + lead + e)
            });
            if let Some(end) = turn.map(|e| a + e).or(next) {
                out.push(Problem { rule: "reveal", excerpt: around(text, a, end.min(text.len())) });
                break;
            }
        }
        if let Some((start, end)) = find(s, "not just ", 0) {
            if find(s, " but ", end).is_some() {
                out.push(Problem { rule: "reveal", excerpt: around(text, a + start, b) });
            }
        }
    }
}

/// Does `s`, its leading spaces skipped, start with `phrase`?
fn starts(s: &str, phrase: &str) -> bool {
    let t = s.trim_start();
    matches_at(t, 0, phrase).is_some()
}

/// Three or more short "no …" items in a row: "No meetings, no fluff, no
/// surprises", or the same as three sentences.
fn negation_lists(text: &str, out: &mut Vec<Problem>) {
    let mut run: Vec<(usize, usize)> = Vec::new();
    let mut items = 0;
    let flush = |run: &mut Vec<(usize, usize)>, items: &mut usize, out: &mut Vec<Problem>| {
        if *items >= 3 {
            out.push(Problem { rule: "negation_list", excerpt: around(text, run[0].0, run[run.len() - 1].1) });
        }
        run.clear();
        *items = 0;
    };
    let mut start = 0;
    let ends = text.char_indices().filter(|(_, c)| matches!(c, ',' | ';' | '.' | '!' | '?' | '\n' | '\u{3001}' | '\u{FF0C}' | '\u{3002}'));
    for (i, c) in ends.chain(std::iter::once((text.len(), ' '))) {
        let segment = &text[start..i];
        let lead = segment.len() - segment.trim_start().len();
        let words = segment.split_whitespace().count();
        let item = ["no ", "and no ", "or no ", "nor "].iter().any(|p| starts(segment, p)) && (2..=6).contains(&words);
        if item {
            run.push((start + lead, i));
            let t = segment.trim_start();
            items += 1 + [" and no ", " or no "].iter().map(|p| count(t, p)).sum::<usize>();
        } else if !segment.trim().is_empty() {
            flush(&mut run, &mut items, out);
        }
        start = (i + c.len_utf8()).min(text.len());
    }
    flush(&mut run, &mut items, out);
}

fn count(text: &str, phrase: &str) -> usize {
    let (mut n, mut from) = (0, 0);
    while let Some((_, end)) = find(text, phrase, from) {
        n += 1;
        from = end;
    }
    n
}

/// The first `phrase` in `text` at or after byte `from`, as whole words (a
/// letter or digit on neither side, where the phrase starts or ends with
/// one), ignoring ASCII case, `'` matching `’` too.
fn find(text: &str, phrase: &str, from: usize) -> Option<(usize, usize)> {
    let first = phrase.chars().next()?;
    let last = phrase.chars().next_back()?;
    text.char_indices().filter(|(i, _)| *i >= from).find_map(|(i, _)| {
        let end = matches_at(text, i, phrase)?;
        let open = !first.is_alphanumeric() || !text[..i].chars().next_back().is_some_and(char::is_alphanumeric);
        let close = !last.is_alphanumeric() || !text[end..].chars().next().is_some_and(char::is_alphanumeric);
        (open && close).then_some((i, end))
    })
}

/// Where `phrase` ends if it starts at byte `at` of `text`.
fn matches_at(text: &str, at: usize, phrase: &str) -> Option<usize> {
    let mut chars = text.get(at..)?.char_indices();
    for p in phrase.chars() {
        let (_, t) = chars.next()?;
        let same = t.eq_ignore_ascii_case(&p) || (p == '\'' && t == '\u{2019}');
        if !same {
            return None;
        }
    }
    Some(chars.next().map_or(text.len(), |(i, _)| at + i))
}

/// The words around `start..end`: up to 30 characters each side, on one line.
fn around(text: &str, start: usize, end: usize) -> String {
    const SIDE: usize = 30;
    let before: Vec<char> = text[..start].chars().rev().take(SIDE + 1).collect();
    let after: Vec<char> = text[end..].chars().take(SIDE + 1).collect();
    let mut s = String::new();
    if before.len() > SIDE {
        s.push('…');
    }
    s.extend(before.iter().take(SIDE).rev());
    s.push_str(&text[start..end]);
    s.extend(after.iter().take(SIDE));
    if after.len() > SIDE {
        s.push('…');
    }
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules(text: &str) -> Vec<&'static str> {
        check(text).into_iter().map(|p| p.rule).collect()
    }

    #[test]
    fn a_dash_used_as_punctuation_is_found_and_a_hyphen_is_not() {
        assert_eq!(rules("We shipped it \u{2014} on time."), ["dash"]);
        assert_eq!(rules("Three things \u{2013} all late."), ["dash"]);
        assert_eq!(rules("It was ready &mdash; mostly."), ["dash"]);
        assert_eq!(rules("It was ready -- mostly."), ["dash"]);
        assert_eq!(check("The price \u{2014} 40 EUR \u{2014} holds.")[0].excerpt, "The price \u{2014} 40 EUR \u{2014} holds.");
        for fine in [
            "A well-known, up-to-date list of 2-3 vendors.",
            "From 2019\u{2013}2021 they grew.",
            "Pages 10-20, see re-run.",
            "- one\n- two",
            "Thanks,\nAnna\n\n-- \nCookie \u{b7} from Northwind's context, by Enkeon",
            "cookie local --help lists everything.",
        ] {
            assert!(check(fine).is_empty(), "{fine}: {:?}", check(fine));
        }
    }

    #[test]
    fn the_reveal_shapes_are_found_and_plain_contrasts_are_not() {
        assert_eq!(rules("It's not a bug, it's a feature."), ["reveal"]);
        assert_eq!(rules("This isn\u{2019}t about price; it\u{2019}s about trust."), ["reveal"]);
        assert_eq!(rules("This is not a plan. It is a wish."), ["reveal"]);
        assert_eq!(rules("We need not just speed, but care."), ["reveal"]);
        for fine in [
            "It's not cheap, but it's worth it.",
            "It isn't ready yet. Anna will finish it on Friday.",
            "That's not what Acme asked for.",
            "Not just yet.",
            "The visit is not until March, it said in the mail.",
        ] {
            assert!(check(fine).is_empty(), "{fine}: {:?}", check(fine));
        }
    }

    #[test]
    fn three_no_items_in_a_row_are_found_and_two_are_not() {
        assert_eq!(rules("No meetings, no fluff, no surprises."), ["negation_list"]);
        assert_eq!(rules("No meetings. No fluff. No surprises."), ["negation_list"]);
        assert_eq!(rules("No meetings, no fluff and no surprises."), ["negation_list"]);
        for fine in [
            "No meetings this week, no rush.",
            "No, I didn't. No, it's fine. No.",
            "No one replied. We tried twice, and no reply came, so we called Acme instead.",
        ] {
            assert!(check(fine).is_empty(), "{fine}: {:?}", check(fine));
        }
    }

    #[test]
    fn stock_phrases_and_words_about_being_an_ai_are_found_as_whole_words() {
        assert_eq!(rules("I hope this email finds you well. Great question!"), ["filler", "filler"]);
        assert_eq!(rules("Let's delve into it and leverage our seamless flow."), ["filler", "filler"]);
        assert_eq!(rules("As an AI, I can't promise that."), ["ai_self"]);
        assert_eq!(rules("I\u{2019}d be happy to help."), ["filler"]);
        for fine in ["We have leverage in this deal.", "She was an aide to the minister.", "Seamstress jobs in Riga.", "Delvecchio signed."] {
            assert!(check(fine).is_empty(), "{fine}: {:?}", check(fine));
        }
    }

    #[test]
    fn text_in_other_languages_reads_clean_unless_it_has_the_same_tells() {
        for fine in [
            "Москва — столица России, и встреча там в среду.",
            "Die Lieferung kommt am Montag. Bitte bestätige den Termin.",
            "Le rendez-vous est confirmé pour jeudi à 10h.",
            "東京の会議は水曜日です。資料は明日送ります。",
            "الاجتماع يوم الأربعاء في الساعة العاشرة.",
            "No sé si llega el lunes, pero te aviso.",
            "Tööpäev algab kell 9; hinnad 10–20 eurot.",
        ] {
            assert!(check(fine).is_empty(), "{fine}: {:?}", check(fine));
        }
        assert_eq!(rules("Die Lieferung \u{2014} endlich."), ["dash"]);
        assert_eq!(rules("東京 \u{2014} 会議"), ["dash"]);
    }

    #[test]
    fn a_tools_text_arguments_are_read_wherever_they_sit() {
        let keys = vec!["body".to_string(), "subject".to_string()];
        let args = json!({"app": "gmail", "args": {"to": "anna@acme.com \u{2014} x", "subject": "Quick one", "body": "It's not late, it's early."}});
        let found = in_args(&args, &keys);
        assert_eq!(found.len(), 1, "only the words a person reads: {found:?}");
        assert_eq!(found[0].rule, "reveal");
        assert!(in_args(&json!({"args": [{"body": "Thanks, see you Friday."}]}), &keys).is_empty());
    }

    #[test]
    fn the_short_ask_answers_ok_and_problems() {
        assert_eq!(rpc(&json!({"text": "See you Friday."})).unwrap(), json!({"ok": true, "problems": []}));
        let r = rpc(&json!({"text": "Ready \u{2014} almost."})).unwrap();
        assert_eq!(r["ok"], false);
        assert_eq!(r["problems"][0]["rule"], "dash");
        assert_eq!(r["problems"][0]["excerpt"], "Ready \u{2014} almost.");
        assert!(rpc(&json!({})).is_err());
    }

    #[test]
    fn many_tells_are_capped_and_the_note_names_each() {
        let text = "x \u{2014} y. ".repeat(40);
        assert_eq!(check(&text).len(), MAX_PROBLEMS);
        let n = note(&check("Ready \u{2014} almost. As an AI I agree."));
        assert!(n.contains("a dash used as punctuation") && n.contains("about being an AI") && n.contains("Ready \u{2014} almost."));
        assert!(!note(&[]).contains(['\u{2014}', '\u{2013}']), "the note's own words carry no dash");
    }

    /// Every message the harness writes for a person from a template, run
    /// through the check: what Cookie asks of a model, it does itself.
    #[test]
    fn every_template_a_person_reads_is_clean() {
        use crate::cookie::{channel, mail, slack};
        let mut texts: Vec<String> = Vec::new();
        for kind in ["not_linked", "linked", "bad_code", "out_of_credits", "working", "failed"] {
            texts.push(channel::notice(kind, "Northwind", "https://x/j"));
        }
        for kind in ["not_member", "empty", "out_of_credits"] {
            texts.push(slack::notice(kind, "Northwind", 500, 1_792_627_200).unwrap());
        }
        let facts = mail::NoticeFacts { team: "Northwind".into(), sender_domain: "acme.example".into(), subject: "Prices".into(), allowance: 500, now: 1_792_627_200.0, local: "northwind".into(), draft_id: "d_1".into(), cookie_domain: "x.example".into() };
        for kind in ["owner", "unproven", "out_of_credits", "draft_unclear"] {
            let n = mail::notice(kind, &facts).unwrap();
            texts.extend([n.subject, n.text]);
        }
        texts.push(mail::signature("Northwind"));
        let thread = mail::Mail { from: "anna@acme.example".into(), subject: "Prices".into(), message_id: "m1@acme.example".into(), ..Default::default() };
        let reply = mail::ReplyFacts { mail: Some(thread), local: "northwind".into(), cookie_domain: "x.example".into(), run_id: "ck_1".into(), team: "Northwind".into(), link: "https://x/j".into(), draft_id: "d_1".into(), ..Default::default() };
        for f in [
            mail::ReplyFacts { questions: Some("Which region?".into()), ..reply.clone() },
            mail::ReplyFacts { answer: None, ..reply.clone() },
            mail::ReplyFacts { answer: Some("Price is 40.".into()), ..reply.clone() },
            mail::ReplyFacts { answer: Some("Price is 40.".into()), outsiders: vec!["anna@acme.example".into()], ..reply },
        ] {
            let v = serde_json::to_value(mail::plan_reply(&f).unwrap()).unwrap();
            for at in ["/subject", "/text", "/notice/subject", "/notice/text", "/draft/body"] {
                texts.extend(v.pointer(at).and_then(Value::as_str).map(String::from));
            }
        }
        for text in texts {
            assert!(check(&text).is_empty(), "{text:?}: {:?}", check(&text));
        }
    }
}
