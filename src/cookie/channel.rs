//! Chat channels beyond mail and Slack — Telegram, Discord, WhatsApp,
//! Microsoft Teams. Who may give Cookie a job there is decided the same way
//! everywhere: a person links their chat account to their team account with
//! a one-time code that only their own Cookie settings show, so a message is
//! a job only from someone who proved they are on the team. Answers go back
//! to that person alone (a private chat, or a reply only they can see), so
//! nothing reaches anyone outside the team. What a code is, how a message is
//! read, and how an answer is cut to each channel's size live here; the
//! client verifies each platform's signature and sends.

use serde_json::{json, Value};

/// The channels, with the longest message each takes.
pub fn max_chars(channel: &str) -> usize {
    match channel {
        "telegram" => 4_096,
        "discord" => 2_000,
        "whatsapp" => 4_096,
        "teams" => 25_000,
        _ => 2_000,
    }
}

/// A link code: six characters from an alphabet with nothing to misread.
pub const CODE_ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
pub const CODE_LEN: usize = 6;
/// How long a code works.
pub const CODE_MINUTES: i64 = 15;

/// A code from random bytes (the client supplies them).
pub fn code_from(random: &[u8]) -> String {
    random.iter().take(CODE_LEN).map(|b| CODE_ALPHABET[*b as usize % CODE_ALPHABET.len()] as char).collect()
}

/// What a message asks: link this chat to a team account (`/start CODE`,
/// `link CODE`, or the code alone), or a job.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Said {
    Link(String),
    Job(String),
    Nothing,
}

pub fn read(text: &str) -> Said {
    let t = text.trim();
    if t.is_empty() {
        return Said::Nothing;
    }
    let words: Vec<&str> = t.split_whitespace().collect();
    let code = |w: &str| {
        let w = w.trim().to_ascii_uppercase();
        (w.len() == CODE_LEN && w.bytes().all(|b| CODE_ALPHABET.contains(&b))).then_some(w)
    };
    match words.as_slice() {
        [cmd, c] if matches!(cmd.to_ascii_lowercase().trim_start_matches('/'), "start" | "link") => match code(c) {
            Some(c) => Said::Link(c),
            None => Said::Job(t.to_string()),
        },
        [c] if code(c).is_some() => Said::Link(code(c).unwrap_or_default()),
        ["/start"] => Said::Nothing,
        _ => Said::Job(t.trim_start_matches("/ask").trim().to_string()),
    }
}

/// An answer cut to a channel's size, on paragraphs where it can be.
pub fn chunks(text: &str, max: usize) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    for para in text.split("\n\n") {
        let candidate = if cur.is_empty() { para.to_string() } else { format!("{cur}\n\n{para}") };
        if candidate.chars().count() <= max {
            cur = candidate;
            continue;
        }
        if !cur.is_empty() {
            out.push(std::mem::take(&mut cur));
        }
        // A paragraph longer than a message: cut on characters.
        let chars: Vec<char> = para.chars().collect();
        for piece in chars.chunks(max) {
            let piece: String = piece.iter().collect();
            if piece.chars().count() == max {
                out.push(piece);
            } else {
                cur = piece;
            }
        }
    }
    if !cur.trim().is_empty() {
        out.push(cur);
    }
    out
}

/// What Cookie says in a channel when it does not run, or asks first.
pub fn notice(kind: &str, team: &str, link: &str) -> String {
    let more = if link.is_empty() { String::new() } else { format!("\n\nSee it on Cookie's page: {link}") };
    match kind {
        "not_linked" => format!(
            "This chat isn't linked to {team} yet. Open Cookie's settings in Enkeon, choose this app under Chat apps, and send the code it shows here."
        ),
        "linked" => format!("Linked. You can give Cookie jobs for {team} here; answers come back only to you."),
        "bad_code" => "That code didn't work. Codes last 15 minutes — open Cookie's settings for a new one.".to_string(),
        "out_of_credits" => format!("Cookie has used this month's credits for {team}, so it can't take this one."),
        "working" => "On it.".to_string(),
        "failed" => format!("Cookie couldn't finish this one, sorry. Try again, or ask it in smaller steps.{more}"),
        _ => String::new(),
    }
}

/// One `channel` line: `{op: "read", text}` → `{said: link|job|nothing, code?, job?}`;
/// `{op: "chunks", channel, text}` → `{chunks}`; `{op: "notice", kind, team, link?}` → `{text}`;
/// `{op: "code", random: [bytes]}` → `{code, minutes}`.
pub fn rpc(m: &Value) -> Result<Value, String> {
    match m["op"].as_str().unwrap_or_default() {
        "read" => Ok(match read(m["text"].as_str().unwrap_or("")) {
            Said::Link(c) => json!({"said": "link", "code": c}),
            Said::Job(j) => json!({"said": "job", "job": j}),
            Said::Nothing => json!({"said": "nothing"}),
        }),
        "chunks" => {
            let channel = m["channel"].as_str().unwrap_or("");
            Ok(json!({"chunks": chunks(m["text"].as_str().unwrap_or(""), max_chars(channel))}))
        }
        "notice" => Ok(json!({"text": notice(m["kind"].as_str().unwrap_or(""), m["team"].as_str().unwrap_or("your team"), m["link"].as_str().unwrap_or(""))})),
        "code" => {
            let random: Vec<u8> = serde_json::from_value(m["random"].clone()).map_err(|e| format!("`random`: {e}"))?;
            if random.len() < CODE_LEN {
                return Err("`random` needs at least six bytes".into());
            }
            Ok(json!({"code": code_from(&random), "minutes": CODE_MINUTES}))
        }
        other => Err(format!("unknown channel op `{other}`")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_code_links_and_anything_else_is_a_job() {
        assert_eq!(read("/start K7PQ2M"), Said::Link("K7PQ2M".into()));
        assert_eq!(read("link k7pq2m"), Said::Link("K7PQ2M".into()));
        assert_eq!(read("K7PQ2M"), Said::Link("K7PQ2M".into()));
        assert_eq!(read("/start"), Said::Nothing);
        assert_eq!(read("When does Acme renew?"), Said::Job("When does Acme renew?".into()));
        assert_eq!(read("/ask brief me on Acme"), Said::Job("brief me on Acme".into()));
        assert_eq!(read("start the report"), Said::Job("start the report".into()), "a word that is not a code is a job");
        assert_eq!(read("O0I1LX"), Said::Job("O0I1LX".into()), "letters that are easy to misread are never in a code");
    }

    #[test]
    fn an_answer_is_cut_on_paragraphs_to_each_channels_size() {
        let text = format!("{}\n\n{}", "a".repeat(1_500), "b".repeat(1_500));
        let c = chunks(&text, max_chars("discord"));
        assert_eq!(c.len(), 2);
        assert!(c.iter().all(|p| p.chars().count() <= 2_000));
        let long = "c".repeat(4_500);
        assert_eq!(chunks(&long, 2_000).len(), 3);
        assert_eq!(chunks("short", 2_000), vec!["short"]);
        assert_eq!(code_from(&[0, 1, 2, 3, 4, 31]).len(), CODE_LEN);
    }
}
