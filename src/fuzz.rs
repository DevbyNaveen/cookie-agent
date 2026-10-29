//! Seeded random text for tests. Every function that cuts, finds, lowers or
//! slices text runs here over thousands of strings in every script, so a
//! byte index that lands inside a character fails in a test, not on a
//! customer's page (a live job died on `ä` on 2026-10-22). Deterministic:
//! a failure names its seed and its input, and reruns the same.
//!
//! Every bug becomes a test: an input that ever broke a text function goes
//! into [`CRASHED`], so it is tried by every fuzz test from then on.

/// xorshift64*: small, fast and the same on every machine.
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }
    pub fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    pub fn below(&mut self, n: usize) -> usize {
        if n == 0 { 0 } else { (self.next() % n as u64) as usize }
    }
}

/// What the strings are built from: plain text, the punctuation the parsers
/// look for, letters of every width (1–4 bytes, combining marks, ZWJ
/// sequences, flags, zero-width and BOM), and the shapes real inputs take
/// (markdown links, source tags, HTML, entities, JSON, the page envelope,
/// secrets and headers).
const PIECES: &[&str] = &[
    "a", "Z", "0", "9", "word", "Acme", " ", "  ", "\n", "\n\n", "\r\n", "\t", "[", "]", "(", ")", "<", ">", "=", ":", "&", ";", "#", "-",
    "_", "/", ".", ",", "*", "+", "\"", "'", "\\", "{", "}", "|", "?", "!", "%", "@", "…", "—", "ä", "ö", "ü", "õ", "š", "ž", "ł", "ß",
    "İ", "ı", "ẞ", "Ä", "Ö", "e\u{301}", "東京", "中文", "日本語", "한국어", "مرحبا", "שלום", "😀", "👨\u{200d}👩\u{200d}👧", "🇱🇻", "🏳\u{fe0f}\u{200d}🌈",
    "\u{200b}", "\u{200d}", "\u{feff}", "\u{0}", "\u{7f}", "\u{fffd}", "[s3]", "[source s12]", "[s1, s2]", "[s", "](https://x.y/ä)",
    "[link](https://example.com/a?b=c)", "[](", "* [Home](https://x.io/)", "+ Solutions - [Find](https://x.io/f)", "# Title", "<p>", "</p>",
    "<script>", "</script>", "<SCRIPT>", "<STYLE>", "</style>", "<a href=\"x\">", "<!-- c -->", "<br/>", "&amp;", "&lt;", "&#228;", "&#x1F600;",
    "&#xZZ;", "&#99999999;", "&bogus;", "&", "{\"content\": [{\"type\": \"text\", \"text\": \"{\\\"status\\\": 200, \\\"content\\\": [\\\"Tööäpäev\\\"], \\\"url\\\": \\\"https://ä.ee\\\"}\"}]}",
    "\"status\": 403", "\\\"", "\\n", "\\u00e4", "api_key=", "api_key: ", "\"password\": \"", "token=", "Bearer ", "sk-", "sk-ant-", "ghp_", "xoxb-",
    "AKIA", "eyJhbGciOiJIUzI1NiJ9.", "-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----", "http://", "https://", "www.", "mailto:", "re:",
    "Re: ", "Fwd: ", "---\n", "name: ", "description: ", "From: ", "On Mon, Anna wrote:", "> quoted", "NO:", "YES", "NONE", "deal_id", "dealId",
    "User-agent: *", "Disallow: /", "Allow: /a", "1234567890abcdef", "ck_0ec0135180384d428c7abcd78d8b20c2",
    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "ääääääääääääääääääääääääääääääääääääääääääääääääää", "😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀",
    // The shapes the voice check looks for.
    "–", "’", "it's not ", "It isn’t ", ", it's ", ". It is ", "No ", "no ", " and no ", " -- ", "&mdash;", "Москва", "not just ", " but ",
    "As an AI", "delve", "。", "，",
];

/// Inputs that broke a text function on real data. Tried first, every time.
pub const CRASHED: &[&str] = &[
    // 2026-10-22: redaction stepped one byte past the last character before a
    // secret's name. `😀token=sk-mailto:9` crashes the code before 5de2384
    // (byte 1 inside `😀`); the two above it are the same shape with `ä`.
    "Tööäpäevtoken=12",
    "äapi_key=sk-abcdefghijklmnopqrstuvwx",
    "😀token=sk-mailto:9",
    "ä:",
    // 2026-10-22: page stripping found positions in `to_lowercase()` (which grows `İ`) and cut the original.
    "<p>İstanbul ÄRI</p><SCRIPT>x()</SCRIPT><p>Tööäpäev 東京</p><style>a{}</style>",
    "İİİİ<script>x</script>",
];

/// One string of up to `max` pieces.
pub fn text(rng: &mut Rng, max: usize) -> String {
    let n = rng.below(max + 1);
    (0..n).map(|_| PIECES[rng.below(PIECES.len())]).collect()
}

/// The crashed inputs, then `n` seeded strings.
pub fn cases(seed: u64, n: usize) -> impl Iterator<Item = String> {
    let mut rng = Rng::new(seed);
    CRASHED.iter().map(|s| s.to_string()).chain((0..n).map(move |_| text(&mut rng, 40)))
}

/// Run `check` on every case, naming the seed and input of the one that fails.
pub fn each(seed: u64, n: usize, check: impl Fn(&str)) {
    for (i, t) in cases(seed, n).enumerate() {
        guard(seed, i, &format!("{t:?}"), || check(&t));
    }
}

/// Two strings per case, for functions of two texts.
pub fn pairs(seed: u64, n: usize, check: impl Fn(&str, &str)) {
    for (i, (a, b)) in cases(seed, n).zip(cases(seed.wrapping_add(7_919), n).skip(CRASHED.len()).chain(cases(seed, 0))).enumerate() {
        guard(seed, i, &format!("{a:?} / {b:?}"), || check(&a, &b));
    }
}

fn guard(seed: u64, i: usize, input: &str, f: impl FnOnce()) {
    if let Err(e) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        let why = e.downcast_ref::<String>().cloned().or_else(|| e.downcast_ref::<&str>().map(|s| s.to_string())).unwrap_or_default();
        panic!("case {i} (seed {seed}) broke: {why}\ninput: {input}");
    }
}

const N: usize = 5_000;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cookie::{channel, check, mail, permission, slack, watch};
    use serde_json::json;

    #[test]
    fn redaction_never_breaks_and_masking_twice_changes_nothing() {
        each(1, N, |t| {
            let once = crate::redact::secrets(t).into_owned();
            assert_eq!(crate::redact::secrets(&once), once, "masked text masks the same again");
            let _ = crate::redact::value(&json!({"a": t, "b": [t, {"c": t}]}));
        });
    }

    #[test]
    fn pages_strip_and_robots_parse_in_any_language() {
        each(2, N, |t| {
            let text = crate::local::strip_html(t);
            assert!(!text.to_ascii_lowercase().contains("<script"), "no script survives: {text:?}");
            let _ = crate::local::robots_rules(t);
        });
    }

    #[test]
    fn source_tags_split_in_any_language() {
        each(3, N, |t| {
            let usable: Vec<bool> = (0..t.len() % 20).map(|i| i % 3 != 0).collect();
            let (clean, sources) = crate::cookie::split_sources(t, &usable);
            assert!(sources.iter().flatten().all(|&s| usable.get(s).copied().unwrap_or(false)), "only usable steps are named");
            let _ = clean;
        });
    }

    #[test]
    fn the_answer_check_reads_and_builds_any_text() {
        pairs(4, N, |answer, source| {
            let read = vec![(0usize, source.to_string()), (3, answer.to_string())];
            let _ = check::check_input(source, answer, &read);
            let _ = check::parse_check(answer);
            let _ = check::revise_input(source, answer, &[json!({"paragraph": 1, "why": source})], &read);
            let _ = permission::parse_judgment(answer);
            let _ = permission::judge_input(&[source.to_string()], answer, source, &json!({"x": answer}));
            let _ = permission::reversibility(answer, source);
        });
    }

    #[test]
    fn chat_messages_are_read_and_cut_to_size_in_any_language() {
        each(5, N, |t| {
            let _ = channel::read(t);
            for max in [1usize, 2, 7, 40, 300] {
                let parts = channel::chunks(t, max);
                assert!(parts.iter().all(|p| p.chars().count() <= max), "a chunk is never longer than {max}");
                let parts = slack::sections(t, max);
                assert!(parts.iter().all(|p| p.chars().count() <= max), "a section is never longer than {max}");
            }
            let _ = slack::clean_text(t);
            let _ = slack::escape(t);
            let _ = slack::link_line(t);
        });
    }

    #[test]
    fn mail_is_read_in_any_language() {
        pairs(6, N, |t, other| {
            let _ = mail::split_own_text(t);
            let _ = mail::decision(t);
            let once = mail::reply_subject(t);
            assert_eq!(mail::reply_subject(&once), once, "a reply's subject is stable");
            let _ = mail::lookup_query(t, other);
            let _ = mail::parse_address(t, other);
            let _ = mail::org_domain(t);
            let _ = mail::aligned(t, other);
            let _ = mail::proves_from(t, &[other.to_string()]);
            let _ = mail::from_line("email", t, other);
            let _ = mail::context_for(&[t.to_string()], true, other);
            let _ = mail::input_for(t, other, t, Some((other, t)));
        });
    }

    #[test]
    fn watched_pages_compare_in_any_language() {
        pairs(7, N, |old, new| {
            let once = watch::normalize(old);
            assert_eq!(watch::normalize(&once), once, "normalizing twice changes nothing");
            let _ = watch::change(old, new, Some(new));
            let _ = watch::change(old, new, None);
        });
    }

    #[test]
    fn lessons_match_and_parse_in_any_language() {
        pairs(8, N, |a, b| {
            let s = crate::lessons::similarity(a, b);
            assert!((0.0..=1.0).contains(&s), "similarity is a share: {s}");
            let _ = crate::lessons::words(a);
            let _ = crate::lessons::is_correction(a);
            let _ = crate::lessons::screen(a);
            let _ = crate::lessons::parse_lesson(a);
            let _ = crate::lessons::parse_procedure(a);
            let _ = crate::lessons::is_duplicate(a, &[b]);
            let _ = crate::lessons::duplicate_of(a, &[b, a]);
            let _ = crate::lessons::most_like(a, &[(b.to_string(), a.to_string())]);
            let _ = crate::lessons::routine(a, &[(b.to_string(), 1.7e9), (a.to_string(), 1.7e9 + 604_800.0), (a.to_string(), 1.7e9 + 1_209_600.0)], 120, &[b.to_string()]);
        });
    }

    #[test]
    fn attention_names_subjects_in_any_language() {
        pairs(9, N, |a, b| {
            let _ = crate::attention::subject_of(a, &[b.to_string(), a.to_string()]);
            let _ = crate::attention::branch_in(a);
            let _ = crate::policy::words(a);
            let _ = crate::mcp::redact_url(a);
            let _ = crate::mcp::foreign_description(b);
        });
    }

    #[test]
    fn plans_check_any_text() {
        pairs(10, N, |a, b| {
            if let Ok(plan) = crate::cookie::plan::check(&json!({"parts": [[a, b], [b, a]], "join": a})) {
                let _ = crate::cookie::plan::part_input(a, &plan, 0);
                let _ = crate::cookie::plan::join_input(a, b, &[(a.to_string(), Some(b.to_string())), (b.to_string(), None)]);
            }
        });
    }

    #[test]
    fn the_voice_check_reads_any_text() {
        each(11, N, |t| {
            let found = crate::cookie::voice::check(t);
            assert!(found.len() <= crate::cookie::voice::MAX_PROBLEMS);
            assert!(found.iter().all(|p| !p.excerpt.is_empty()), "every problem shows its words");
            let _ = crate::cookie::voice::in_args(&json!({"body": t, "x": [{"subject": t}]}), &["body".into(), "subject".into()]);
            let _ = crate::cookie::voice::note(&found);
        });
    }

    #[test]
    fn the_crashed_inputs_are_tried_first() {
        let first: Vec<String> = cases(0, 0).collect();
        assert_eq!(first, CRASHED.iter().map(|s| s.to_string()).collect::<Vec<_>>());
    }
}
