//! Cookie in Slack: the channel rules. `@Cookie …` in a channel, or a DM to
//! Cookie, is a job; the answer goes in the thread it was asked in — unless
//! the channel is shared with another company (Slack Connect), where people
//! outside the team would read it: then it goes to the member privately with
//! "Post in thread" / "Skip", the same rule as a mail thread with outsiders.
//!
//! Everything here is pure. The client verifies Slack's signature, holds the
//! bot token, tells members apart by their Slack email, and makes the API
//! calls [`plan_reply`] describes.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Slack's mrkdwn treats `&`, `<` and `>` as markup: Cookie's text is text.
pub fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// Text cut into pieces a section block takes (3,000 characters), on
/// paragraph breaks where it can.
pub fn sections(text: &str, max: usize) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for para in text.split("\n\n") {
        let mut para = para.to_string();
        while para.chars().count() > max {
            let head: String = para.chars().take(max).collect();
            let cut = head.rfind([' ', '\n']).filter(|&i| i > max / 2).unwrap_or(head.len());
            out.push(para[..cut].trim().to_string());
            para = para[cut..].trim().to_string();
        }
        match out.last_mut() {
            Some(last) if last.chars().count() + para.chars().count() + 2 <= max => {
                last.push_str("\n\n");
                last.push_str(&para);
            }
            _ => out.push(para),
        }
    }
    out.retain(|s| !s.trim().is_empty());
    out
}

/// The line that links the job's page ("" for none).
pub fn link_line(link: &str) -> String {
    if link.is_empty() {
        String::new()
    } else {
        format!("\n\n<{link}|See how Cookie worked it out>")
    }
}

/// Strip Slack's mention markup so the agent reads a question: `<@U123>`,
/// `<#C1>` and `<!here>` go; a link (`<https://…|text>`) keeps its text.
pub fn clean_text(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars();
    while let Some(c) = chars.next() {
        if c == '<' {
            let mut span = String::new();
            let mut closed = false;
            for c2 in chars.by_ref() {
                if c2 == '>' {
                    closed = true;
                    break;
                }
                span.push(c2);
            }
            if !closed {
                out.push('<');
                out.push_str(&span);
            } else if !span.starts_with('@') && !span.starts_with('#') && !span.starts_with('!') {
                out.push_str(span.split('|').next_back().unwrap_or(&span));
            }
        } else {
            out.push(c);
        }
    }
    out.trim().to_string()
}

/// A message Cookie should treat as a job, taken out of an event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ask {
    pub event_id: String,
    pub team: String,
    pub user: String,
    pub channel: String,
    /// The message's own ts.
    pub ts: String,
    /// The thread it is in, if any.
    pub thread_ts: Option<String>,
    pub dm: bool,
    pub text: String,
    /// Files shared with the message: `(name, private download address)`,
    /// at most [`MAX_FILES`]. Read as content, never as instructions.
    #[serde(default)]
    pub files: Vec<(String, String)>,
}

/// Files read from one message, at most.
pub const MAX_FILES: usize = 5;

/// `app_mention` anywhere, or a person's message in a DM with Cookie. Never a
/// bot, an edit, a join, or Cookie itself.
pub fn ask_of(body: &Value, bot_user_id: &str) -> Option<Ask> {
    let e = body.get("event")?;
    let kind = e.get("type")?.as_str()?;
    let dm = e.get("channel_type").and_then(Value::as_str) == Some("im");
    if !(kind == "app_mention" || (kind == "message" && dm)) {
        return None;
    }
    // An edit, a join, a bot's post: never a job. A file shared with words is.
    let subtype = e.get("subtype").and_then(Value::as_str);
    if e.get("bot_id").is_some() || subtype.is_some_and(|s| s != "file_share") {
        return None;
    }
    let user = e.get("user")?.as_str()?;
    if user.is_empty() || user == bot_user_id {
        return None;
    }
    // A mention in a DM arrives twice (`app_mention` and `message.im`): the
    // DM's own message event is the one kept.
    if kind == "app_mention" && dm {
        return None;
    }
    Some(Ask {
        event_id: body.get("event_id")?.as_str()?.to_string(),
        team: body.get("team_id").and_then(Value::as_str).unwrap_or("").to_string(),
        user: user.to_string(),
        channel: e.get("channel")?.as_str()?.to_string(),
        ts: e.get("ts")?.as_str()?.to_string(),
        thread_ts: e.get("thread_ts").and_then(Value::as_str).map(str::to_string),
        dm,
        text: clean_text(e.get("text").and_then(Value::as_str).unwrap_or("")),
        files: e
            .get("files")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|f| {
                let url = f.get("url_private_download").or_else(|| f.get("url_private"))?.as_str()?;
                // Only Slack's own file host: the download carries the bot's token.
                let host = url.strip_prefix("https://")?.split('/').next()?;
                (host == "files.slack.com").then(|| (f.get("name").and_then(Value::as_str).unwrap_or("file").to_string(), url.to_string()))
            })
            .take(MAX_FILES)
            .collect(),
    })
}

/// The thread anything said back goes in: the ask's thread, or a new thread
/// under the message — except a top-level DM message, answered in the DM.
pub fn reply_thread(ask: &Ask) -> Option<String> {
    if ask.dm && ask.thread_ts.is_none() {
        None
    } else {
        Some(ask.thread_ts.clone().unwrap_or_else(|| ask.ts.clone()))
    }
}

/// The lines Cookie says when it does not run: `not_member` (shown only to
/// the asker), `empty` (a mention with no job), `out_of_credits` (`now` in
/// Unix seconds).
pub fn notice(kind: &str, team: &str, allowance: i64, now: i64) -> Result<String, String> {
    Ok(match kind {
        "not_member" => format!("Cookie only takes jobs from people on {team}."),
        "empty" => "What should I do? Ask me in the same message.".to_string(),
        "out_of_credits" => escape(&super::mail::out_of_credits_line(allowance, now)),
        other => return Err(format!("unknown notice `{other}`")),
    })
}

/// Where a Slack post goes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "to", rename_all = "snake_case")]
pub enum Place {
    /// The channel (or DM) the job was asked in, in its thread.
    Thread { channel: String, thread_ts: Option<String> },
    /// The member's DM with Cookie (`conversations.open`), top level.
    Dm { user: String },
}

/// What the run ends with, as the client knows it. `place` is the job's
/// Slack place: `{channel, user, thread_ts, ext_shared, message_ts}`.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct ReplyFacts {
    pub place: Value,
    pub answer: Option<String>,
    pub questions: Option<String>,
    /// The job's page ("" for none).
    pub link: String,
    /// A fresh `d_…` id, used only when a draft is made.
    pub draft_id: String,
}

/// Where the draft goes once the member presses "Post in thread".
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DraftPlace {
    pub channel: String,
    pub thread_ts: Option<String>,
    /// The answer as written, kept on the draft.
    pub body: String,
    /// What is posted on "Post in thread" (the body, escaped).
    pub post: String,
}

/// What to post when a Slack run ends. The client removes the eyes from
/// `place.message_ts` first.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Reply {
    /// `record_asked_in`: asked in the DM (the channel is shared outside the
    /// team), so the run must record the DM's channel as `asked_in` — the
    /// answer comes from there. Asked in the thread, the thread says where.
    Questions { place: Place, text: String, record_asked_in: bool },
    Failure { place: Place, text: String },
    Thread { place: Place, text: String },
    /// Shared with another company: a private draft with two buttons.
    Draft { place: Place, text: String, blocks: Value, draft: DraftPlace },
}

pub fn plan_reply(f: &ReplyFacts) -> Result<Reply, String> {
    let s = |k: &str| f.place.get(k).and_then(Value::as_str).map(str::to_string);
    let (Some(channel), Some(user)) = (s("channel"), s("user")) else {
        return Err("no Slack channel".into());
    };
    let thread = s("thread_ts");
    // Can't tell → treat as shared: a private answer is never a leak.
    let ext_shared = f.place.get("ext_shared").and_then(Value::as_bool).unwrap_or(true);
    let link = link_line(&f.link);
    let here = Place::Thread { channel: channel.clone(), thread_ts: thread.clone() };
    let private = Place::Dm { user };

    if let Some(qs) = &f.questions {
        let text = format!("Before I start, a few quick questions:\n\n{}\n\nAnswer here, mentioning me, and I'll get going.", escape(qs));
        let text = if ext_shared { text.replace("Answer here, mentioning me,", "Answer here") } else { text };
        return Ok(Reply::Questions {
            place: if ext_shared { private } else { here },
            text: format!("{text}{link}"),
            record_asked_in: ext_shared,
        });
    }

    let Some(answer) = f.answer.as_deref().map(str::trim).filter(|a| !a.is_empty()) else {
        return Ok(Reply::Failure {
            place: if ext_shared { private } else { here },
            text: format!("Cookie couldn't finish this one, sorry. Try again, or ask it in smaller steps.{link}"),
        });
    };

    if !ext_shared {
        return Ok(Reply::Thread { place: here, text: format!("{}{link}", escape(answer)) });
    }

    if f.draft_id.is_empty() {
        return Err("a draft needs `draft_id`".into());
    }
    let mut blocks = vec![json!({"type": "section", "text": {"type": "mrkdwn",
        "text": format!("Here's a reply for <#{channel}>. That channel includes people outside your team, so it waits for you.")}})];
    for part in sections(&escape(answer), 2_900) {
        blocks.push(json!({"type": "section", "text": {"type": "mrkdwn", "text": part}}));
    }
    blocks.push(json!({"type": "actions", "elements": [
        {"type": "button", "text": {"type": "plain_text", "text": "Post in thread"}, "style": "primary", "action_id": "cookie_draft_send", "value": f.draft_id},
        {"type": "button", "text": {"type": "plain_text", "text": "Skip"}, "action_id": "cookie_draft_skip", "value": f.draft_id},
    ]}));
    if !f.link.is_empty() {
        blocks.push(json!({"type": "context", "elements": [{"type": "mrkdwn", "text": format!("<{}|See how Cookie worked it out>", f.link)}]}));
    }
    Ok(Reply::Draft {
        place: private,
        text: "A reply is waiting for you".into(),
        blocks: Value::Array(blocks),
        draft: DraftPlace { channel, thread_ts: thread, body: answer.to_string(), post: escape(answer) },
    })
}

/// One `slack` line: `op` is
///
/// * `ask {body, bot_user_id}` → `{ask, thread}` (`ask` null when the event
///   is not a job; `thread` per [`reply_thread`]);
/// * `reply` — [`ReplyFacts`] fields → a [`Reply`];
/// * `notice {kind, team?, allowance?, now?}` → `{text}`;
/// * `escape {text}` → `{text}`; `sections {text, max?}` → `{sections}`
///   (`max` defaults to 2,900).
pub fn rpc(m: &Value) -> Result<Value, String> {
    let text = |k: &str| m.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
    match m.get("op").and_then(Value::as_str).unwrap_or_default() {
        "ask" => {
            let ask = ask_of(m.get("body").unwrap_or(&Value::Null), &text("bot_user_id"));
            let thread = ask.as_ref().and_then(reply_thread);
            Ok(json!({"ask": ask, "thread": thread}))
        }
        "reply" => {
            let f: ReplyFacts = serde_json::from_value(m.clone()).map_err(|e| format!("reply: {e}"))?;
            serde_json::to_value(plan_reply(&f)?).map_err(|e| e.to_string())
        }
        "notice" => {
            let allowance = m.get("allowance").and_then(Value::as_i64).unwrap_or(0);
            let now = m.get("now").and_then(Value::as_f64).unwrap_or(0.0) as i64;
            Ok(json!({"text": notice(&text("kind"), &text("team"), allowance, now)?}))
        }
        "escape" => Ok(json!({"text": escape(&text("text"))})),
        "sections" => {
            let max = m.get("max").and_then(Value::as_u64).map(|n| n as usize).unwrap_or(2_900).max(1);
            Ok(json!({"sections": sections(&text("text"), max)}))
        }
        other => Err(format!("unknown slack op `{other}`")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(kind: &str, extra: Value) -> Value {
        let mut e = json!({"type": kind, "user": "U1", "channel": "C1", "ts": "111.1", "text": "<@UBOT> brief me on Acme"});
        for (k, v) in extra.as_object().unwrap() {
            e[k] = v.clone();
        }
        json!({"type": "event_callback", "team_id": "T1", "event_id": "Ev1", "event": e})
    }

    #[test]
    fn a_mention_or_a_dm_is_a_job_and_nothing_else_is() {
        let a = ask_of(&event("app_mention", json!({})), "UBOT").unwrap();
        assert_eq!(a.text, "brief me on Acme");
        assert_eq!((a.dm, a.thread_ts.as_deref(), a.team.as_str()), (false, None, "T1"));
        let t = ask_of(&event("app_mention", json!({"thread_ts": "100.0"})), "UBOT").unwrap();
        assert_eq!(t.thread_ts.as_deref(), Some("100.0"));
        assert!(ask_of(&event("message", json!({"channel_type": "im"})), "UBOT").unwrap().dm);
        // A plain channel message (no mention) is not for Cookie.
        assert!(ask_of(&event("message", json!({"channel_type": "channel"})), "UBOT").is_none());
        // Bots, edits, and Cookie itself never start a job.
        assert!(ask_of(&event("app_mention", json!({"bot_id": "B1"})), "UBOT").is_none());
        assert!(ask_of(&event("message", json!({"channel_type": "im", "subtype": "message_changed"})), "UBOT").is_none());
        assert!(ask_of(&event("app_mention", json!({"user": "UBOT"})), "UBOT").is_none());
        // The same DM mention arrives twice; only the message event counts.
        assert!(ask_of(&event("app_mention", json!({"channel_type": "im"})), "UBOT").is_none());
    }

    #[test]
    fn replies_go_in_the_thread_except_a_top_level_dm() {
        let a = ask_of(&event("app_mention", json!({})), "UBOT").unwrap();
        assert_eq!(reply_thread(&a).as_deref(), Some("111.1"), "a new thread under the mention");
        let t = ask_of(&event("app_mention", json!({"thread_ts": "100.0"})), "UBOT").unwrap();
        assert_eq!(reply_thread(&t).as_deref(), Some("100.0"));
        let dm = ask_of(&event("message", json!({"channel_type": "im"})), "UBOT").unwrap();
        assert_eq!(reply_thread(&dm), None);
        let dm_thread = ask_of(&event("message", json!({"channel_type": "im", "thread_ts": "100.0"})), "UBOT").unwrap();
        assert_eq!(reply_thread(&dm_thread).as_deref(), Some("100.0"));
    }

    #[test]
    fn mention_markup_is_removed_but_links_survive() {
        assert_eq!(clean_text("<@U123> what did we tell Acme?"), "what did we tell Acme?");
        assert_eq!(clean_text("<@U1> <#C2> hi"), "hi");
        // A real link is content. Dropping it would delete the thing being asked about.
        assert_eq!(clean_text("check <https://x.com|this>"), "check this");
        assert_eq!(clean_text("plain question"), "plain question");
        // An unterminated bracket is text, not a mention to swallow.
        assert_eq!(clean_text("a < b"), "a < b");
    }

    #[test]
    fn slack_text_is_escaped_and_cut_on_paragraphs() {
        assert_eq!(escape("a < b && c > d"), "a &lt; b &amp;&amp; c &gt; d");
        let text = format!("{}\n\n{}", "a".repeat(10), "b".repeat(25));
        let parts = sections(&text, 20);
        assert_eq!(parts[0], "a".repeat(10));
        assert!(parts.iter().all(|p| p.chars().count() <= 20), "{parts:?}");
        assert_eq!(parts.concat().replace("\n\n", ""), format!("{}{}", "a".repeat(10), "b".repeat(25)));
        assert_eq!(sections("one\n\ntwo", 100), vec!["one\n\ntwo"]);
        assert_eq!(link_line(""), "");
        assert_eq!(link_line("https://x/j"), "\n\n<https://x/j|See how Cookie worked it out>");
    }

    fn facts(ext_shared: Option<bool>) -> ReplyFacts {
        let mut place = json!({"channel": "C1", "user": "U1", "thread_ts": "100.0", "message_ts": "111.1"});
        if let Some(x) = ext_shared {
            place["ext_shared"] = json!(x);
        }
        ReplyFacts { place, link: "https://x/j".into(), ..ReplyFacts::default() }
    }

    fn here() -> Place {
        Place::Thread { channel: "C1".into(), thread_ts: Some("100.0".into()) }
    }

    #[test]
    fn questions_ask_in_the_thread_or_privately_when_the_channel_is_shared() {
        let f = ReplyFacts { questions: Some("Which <region>?".into()), ..facts(Some(false)) };
        assert_eq!(
            plan_reply(&f).unwrap(),
            Reply::Questions {
                place: here(),
                text: "Before I start, a few quick questions:\n\nWhich &lt;region&gt;?\n\nAnswer here, mentioning me, and I'll get going.\n\n<https://x/j|See how Cookie worked it out>".into(),
                record_asked_in: false,
            }
        );
        let f = ReplyFacts { questions: Some("Which region?".into()), ..facts(Some(true)) };
        assert_eq!(
            plan_reply(&f).unwrap(),
            Reply::Questions {
                place: Place::Dm { user: "U1".into() },
                text: "Before I start, a few quick questions:\n\nWhich region?\n\nAnswer here and I'll get going.\n\n<https://x/j|See how Cookie worked it out>".into(),
                record_asked_in: true,
            }
        );
    }

    #[test]
    fn a_failure_is_said_where_the_answer_would_have_gone() {
        let f = ReplyFacts { answer: Some(" ".into()), ..facts(Some(false)) };
        assert_eq!(
            plan_reply(&f).unwrap(),
            Reply::Failure {
                place: here(),
                text: "Cookie couldn't finish this one, sorry. Try again, or ask it in smaller steps.\n\n<https://x/j|See how Cookie worked it out>".into()
            }
        );
        // Unknown sharing counts as shared.
        let Reply::Failure { place, .. } = plan_reply(&facts(None)).unwrap() else { panic!() };
        assert_eq!(place, Place::Dm { user: "U1".into() });
    }

    #[test]
    fn a_team_only_channel_gets_the_answer_in_its_thread() {
        let f = ReplyFacts { answer: Some("Acme pays <40>.".into()), ..facts(Some(false)) };
        assert_eq!(
            plan_reply(&f).unwrap(),
            Reply::Thread { place: here(), text: "Acme pays &lt;40&gt;.\n\n<https://x/j|See how Cookie worked it out>".into() }
        );
    }

    #[test]
    fn a_shared_channel_gets_a_private_draft_with_two_buttons() {
        let f = ReplyFacts { answer: Some("Acme pays <40>.".into()), draft_id: "d_abc".into(), ..facts(Some(true)) };
        let Reply::Draft { place, text, blocks, draft } = plan_reply(&f).unwrap() else { panic!("not a draft") };
        assert_eq!(place, Place::Dm { user: "U1".into() });
        assert_eq!(text, "A reply is waiting for you");
        assert_eq!(blocks[0]["text"]["text"], "Here's a reply for <#C1>. That channel includes people outside your team, so it waits for you.");
        assert_eq!(blocks[1]["text"]["text"], "Acme pays &lt;40&gt;.");
        assert_eq!(blocks[2]["elements"][0]["action_id"], "cookie_draft_send");
        assert_eq!(blocks[2]["elements"][0]["value"], "d_abc");
        assert_eq!(blocks[2]["elements"][1]["text"]["text"], "Skip");
        assert_eq!(blocks[3]["elements"][0]["text"], "<https://x/j|See how Cookie worked it out>");
        assert_eq!(
            draft,
            DraftPlace { channel: "C1".into(), thread_ts: Some("100.0".into()), body: "Acme pays <40>.".into(), post: "Acme pays &lt;40&gt;.".into() }
        );
        assert!(plan_reply(&ReplyFacts { draft_id: String::new(), ..f }).is_err());
        assert!(plan_reply(&ReplyFacts { place: json!({"channel": "C1"}), ..ReplyFacts::default() }).is_err(), "no user");
    }

    #[test]
    fn notices_and_ops_over_the_line() {
        assert_eq!(notice("not_member", "Honeyb", 0, 0).unwrap(), "Cookie only takes jobs from people on Honeyb.");
        assert_eq!(notice("empty", "", 0, 0).unwrap(), "What should I do? Ask me in the same message.");
        assert!(notice("out_of_credits", "", 500, 1_792_627_200).unwrap().contains("credits for October"));
        let r = rpc(&json!({"op": "ask", "body": event("app_mention", json!({})), "bot_user_id": "UBOT"})).unwrap();
        assert_eq!(r["ask"]["text"], "brief me on Acme");
        assert_eq!(r["thread"], "111.1");
        assert_eq!(rpc(&json!({"op": "ask", "body": {}, "bot_user_id": "UBOT"})).unwrap()["ask"], Value::Null);
        assert_eq!(rpc(&json!({"op": "escape", "text": "a&b"})).unwrap()["text"], "a&amp;b");
        assert_eq!(rpc(&json!({"op": "sections", "text": "one\n\ntwo"})).unwrap()["sections"], json!(["one\n\ntwo"]));
        let r = rpc(&json!({"op": "reply", "place": {"channel": "C1", "user": "U1", "ext_shared": false}, "answer": "hi"})).unwrap();
        assert_eq!(r, json!({"kind": "thread", "place": {"to": "thread", "channel": "C1", "thread_ts": null}, "text": "hi"}));
        assert!(rpc(&json!({"op": "nope"})).is_err());
    }

    #[test]
    fn a_file_shared_with_words_is_a_job_and_only_slacks_own_file_host_is_kept() {
        let body = json!({"event_id": "Ev9", "team_id": "T1", "event": {"type": "message", "channel_type": "im", "subtype": "file_share",
            "user": "U1", "channel": "D1", "ts": "1.1", "text": "summarise this",
            "files": [{"name": "contract.pdf", "url_private_download": "https://files.slack.com/files-pri/T1-F1/download/contract.pdf"},
                      {"name": "evil", "url_private_download": "https://evil.io/steal"}]}});
        let ask = ask_of(&body, "UBOT").unwrap();
        assert_eq!(ask.files, vec![("contract.pdf".to_string(), "https://files.slack.com/files-pri/T1-F1/download/contract.pdf".to_string())]);
        let edited = json!({"event_id": "Ev9", "event": {"type": "message", "channel_type": "im", "subtype": "message_changed", "user": "U1", "channel": "D1", "ts": "1.1"}});
        assert!(ask_of(&edited, "UBOT").is_none());
    }

}
