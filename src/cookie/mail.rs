//! Cookie by mail: the channel rules. Who a message is from decides whether
//! anything runs; who is on the thread decides where the answer goes — by
//! rules, never by the model.
//!
//! * a verified teammate wrote, and everyone else on the thread is on the
//!   team → Cookie answers in the thread;
//! * someone outside the team is on the thread → the teammate gets a private
//!   draft; it goes to the thread only when their own verified reply says
//!   `send`;
//! * Cookie was only blind-copied → it says nothing (answering would reveal
//!   the BCC);
//! * an outsider wrote → nothing runs; the team's owners get one line;
//! * a teammate's address the mail does not prove → nothing runs; the real
//!   teammate is told, at their own address.
//!
//! Everything here is pure. The client parses the MIME into a [`Mail`],
//! verifies DKIM itself (it sends `proven`), looks people up, keeps runs and
//! drafts, checks credits, and sends what [`plan_reply`] says to send.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// An inbound message, as the client parsed it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Mail {
    pub message_id: String,
    pub in_reply_to: String,
    pub references: Vec<String>,
    pub from: String,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub subject: String,
    pub text: String,
    /// An out-of-office, a list or a bulk send: never instructions, and
    /// answering one invites a mail loop (RFC 3834). See [`is_automatic`].
    pub automatic: bool,
}

/// RFC 3834 `Auto-Submitted` (anything but `no`), `Precedence: bulk | list |
/// junk | auto_reply`, and the common vendor flags (`X-Autoreply`,
/// `X-Autorespond`).
pub fn is_automatic(auto_submitted: &str, precedence: &str, x_autoreply: bool) -> bool {
    let a = auto_submitted.trim().to_ascii_lowercase();
    let p = precedence.trim().to_ascii_lowercase();
    (!a.is_empty() && a != "no") || matches!(p.as_str(), "bulk" | "list" | "junk" | "auto_reply") || x_autoreply
}

/// The sender's own words, and everything quoted or forwarded below them.
/// Only the first is ever treated as an instruction.
pub fn split_own_text(text: &str) -> (String, String) {
    let lines: Vec<&str> = text.lines().collect();
    let cut = lines.iter().position(|l| {
        let t = l.trim();
        t.starts_with('>')
            || (t.starts_with("On ") && t.ends_with("wrote:"))
            || t.starts_with("-----Original Message-----")
            || t.contains("Forwarded message")
            || (t.starts_with("From:") && t.contains('@'))
    });
    match cut {
        Some(i) => (lines[..i].join("\n").trim().to_string(), lines[i..].join("\n").trim().to_string()),
        None => (text.trim().to_string(), String::new()),
    }
}

/// What a teammate's reply to a draft decides.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Send,
    Skip,
    Unclear,
}

impl Decision {
    pub fn as_str(self) -> &'static str {
        match self {
            Decision::Send => "send",
            Decision::Skip => "skip",
            Decision::Unclear => "unclear",
        }
    }
}

/// Read only the first word of the reply's own text, so a quoted draft that
/// happens to contain "send" never decides anything.
pub fn decision(own_text: &str) -> Decision {
    let first = own_text
        .split_whitespace()
        .next()
        .unwrap_or("")
        .trim_matches(|c: char| !c.is_alphanumeric())
        .to_ascii_lowercase();
    match first.as_str() {
        "send" | "yes" | "ok" | "okay" => Decision::Send,
        "skip" | "no" | "cancel" | "don't" | "dont" => Decision::Skip,
        _ => Decision::Unclear,
    }
}

/// `Re: <subject>`, without stacking prefixes.
pub fn reply_subject(subject: &str) -> String {
    let s = subject.trim();
    // `get`, not `[..3]`: a subject whose third byte is inside a character
    // must not panic.
    if s.get(..3).is_some_and(|p| p.eq_ignore_ascii_case("re:")) {
        s.to_string()
    } else if s.is_empty() {
        "Re: your message".to_string()
    } else {
        format!("Re: {s}")
    }
}

/// The line under every reply Cookie writes for a team.
pub fn signature(team: &str) -> String {
    format!("\n\n—\nCookie · from {team}'s context, by Enkeon")
}

/// Everyone on the thread except Cookie, de-duplicated, From first.
pub fn thread_people(mail: &Mail, cookie_domain: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for a in std::iter::once(&mail.from).chain(mail.to.iter()).chain(mail.cc.iter()) {
        let a = a.to_ascii_lowercase();
        if a.is_empty() || parse_address(&a, cookie_domain).is_some() || out.contains(&a) {
            continue;
        }
        out.push(a);
    }
    out
}

const MONTHS: [&str; 12] =
    ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

/// The UTC month (1–12) of a Unix time, by the proleptic Gregorian calendar
/// (Howard Hinnant's `civil_from_days`).
fn month_of(epoch_secs: i64) -> usize {
    let z = epoch_secs.div_euclid(86_400) + 719_468;
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    (if mp < 10 { mp + 3 } else { mp - 9 }) as usize
}

/// ("October", "1 November") for a time in October.
pub fn month_name(epoch_secs: i64) -> (String, String) {
    let m = month_of(epoch_secs);
    (MONTHS[m - 1].to_string(), format!("1 {}", MONTHS[m % 12]))
}

/// "Cookie has used its 500 credits for October…" — said the same way in
/// mail and Slack. `now` is Unix seconds.
pub fn out_of_credits_line(allowance: i64, now: i64) -> String {
    let (this, next) = month_name(now);
    format!("Cookie has used its {allowance} credits for {this}, so it can't take this one. They renew on {next}.")
}

/// The first lookup's words: the subject and the job together — once. A job
/// asked on the page has its question as its subject, and "hy" looked up as
/// "hy hy" reads to the brain as a different query.
pub fn lookup_query(subject: &str, own: &str) -> String {
    let (a, b) = (subject.trim(), own.trim());
    let (la, lb) = (a.to_lowercase(), b.to_lowercase());
    if la.contains(&lb) {
        a.to_string()
    } else if lb.contains(&la) {
        b.to_string()
    } else {
        format!("{a} {b}")
    }
}

/// What a mail run keeps of its thread, so a reply to Cookie's questions can
/// answer in the original thread with the original people.
pub fn mail_origin(mail: &Mail) -> Value {
    json!({
        "message_id": mail.message_id,
        "references": mail.references,
        "from": mail.from,
        "to": mail.to,
        "cc": mail.cc,
        "subject": mail.subject,
    })
}

/// The thread back out of a run's origin (`{"mail": …}`).
pub fn mail_from_origin(origin: &Value) -> Option<Mail> {
    let m = origin.get("mail")?;
    let s = |k: &str| m.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let list = |k: &str| -> Vec<String> {
        m.get(k).and_then(Value::as_array).map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default()
    };
    Some(Mail {
        message_id: s("message_id"),
        in_reply_to: String::new(),
        references: list("references"),
        from: s("from"),
        to: list("to"),
        cc: list("cc"),
        subject: s("subject"),
        text: String::new(),
        automatic: false,
    })
}

/// The thread's References for a reply: what it carried, then its own id.
pub fn thread_refs(mail: &Mail) -> Vec<String> {
    mail.references.iter().cloned().chain(std::iter::once(mail.message_id.clone()).filter(|m| !m.is_empty())).collect()
}

/// Who the job is from, as the model reads it. `trigger` is `email` | `page`
/// | `slack` | `tool`; `mail_from` is the mail's From ("" without a mail).
pub fn from_line(trigger: &str, mail_from: &str, member_name: &str) -> String {
    match (trigger, mail_from) {
        ("slack", _) => format!("{member_name}, in Slack (on your team)"),
        (_, f) if !f.is_empty() => format!("{f} (on your team)"),
        _ => format!("{member_name} (on your team)"),
    }
}

/// The context a run reads (never obeys): who outside the team can see the
/// answer's place, then what the job came with.
pub fn context_for(outsiders: &[String], ext_shared: bool, context: &str) -> String {
    let mut out = String::new();
    if !outsiders.is_empty() {
        out.push_str(&format!("People outside the team on this thread: {}.\n\n", outsiders.join(", ")));
    }
    if ext_shared {
        out.push_str("This Slack channel includes people outside the team.\n\n");
    }
    out.push_str(context);
    out
}

/// The words the model reads as the member's: the job, or — answering
/// Cookie's questions — the job (`parent.0`), the questions (`parent.1`) and
/// the answer together.
pub fn input_for(subject: &str, from_line: &str, own: &str, parent: Option<(&str, &str)>) -> String {
    match parent {
        None => format!("Subject: {subject}\nFrom: {from_line}\n\n{own}"),
        Some((job, questions)) => format!(
            "Subject: {subject}\nFrom: {from_line}\n\nThe job:\n{job}\n\nBefore starting, you asked:\n{questions}\n\nTheir answer:\n{own}\n\nNow do the job."
        ),
    }
}

// ── Addresses ───────────────────────────────────────────────────────────────

/// `Display Name <Addr@Host>` → `addr@host`; "" when it is not one address.
fn normalize_address(raw: &str) -> String {
    let s = raw.trim();
    let inner = match (s.rfind('<'), s.rfind('>')) {
        (Some(a), Some(b)) if b > a => &s[a + 1..b],
        _ => s,
    };
    let inner = inner.trim().trim_matches('"').trim();
    let mut parts = inner.rsplitn(2, '@');
    let host = parts.next().unwrap_or("");
    let local = parts.next().unwrap_or("");
    if local.is_empty() || host.is_empty() || local.contains('@') {
        return String::new();
    }
    format!("{}@{}", local.to_ascii_lowercase(), host.to_ascii_lowercase())
}

/// The domain half of an address.
fn address_domain(addr: &str) -> &str {
    addr.rsplit_once('@').map(|(_, d)| d).unwrap_or("")
}

/// A Cookie address taken apart: the team's local part and, for a reply to a
/// draft, the draft it answers (`honeyb+d_<id>@…`), or for a reply to
/// Cookie's questions, the run that asked them (`honeyb+q_<hex>@…` → `ck_<hex>`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Address {
    pub local: String,
    pub draft: Option<String>,
    pub question: Option<String>,
}

/// `Some` only for an address on the Cookie domain. Case-insensitive, as mail
/// addresses are in practice.
pub fn parse_address(addr: &str, domain: &str) -> Option<Address> {
    let addr = normalize_address(addr);
    let domain = domain.trim().to_ascii_lowercase();
    if domain.is_empty() {
        return None;
    }
    let (local, host) = addr.rsplit_once('@')?;
    if host != domain || local.is_empty() {
        return None;
    }
    let id = |tag: &str, prefix: &str| {
        tag.strip_prefix(prefix).filter(|d| !d.is_empty() && d.chars().all(|c| c.is_ascii_alphanumeric())).map(str::to_string)
    };
    match local.split_once('+') {
        Some((team, tag)) => Some(Address {
            local: team.to_string(),
            draft: id(tag, "d_").map(|d| format!("d_{d}")),
            question: id(tag, "q_").map(|q| format!("ck_{q}")),
        }),
        None => Some(Address { local: local.to_string(), draft: None, question: None }),
    }
}

// ── Who may instruct ────────────────────────────────────────────────────────

/// The organisational domain (registrable domain, by the public suffix list).
/// `None` for a bare suffix or garbage.
pub fn org_domain(host: &str) -> Option<String> {
    let host = host.trim().trim_end_matches('.').to_ascii_lowercase();
    psl::domain_str(&host).map(str::to_owned)
}

/// Relaxed DMARC alignment (RFC 7489 §3.1.1): same organisational domain.
pub fn aligned(signing_domain: &str, from_domain: &str) -> bool {
    match (org_domain(signing_domain), org_domain(from_domain)) {
        (Some(a), Some(b)) => a == b,
        _ => false,
    }
}

/// Does any verified DKIM signature prove the `From` domain? `signing_domains`
/// are the `d=` of signatures that verified over the WHOLE body: one with
/// `l=` lets anyone append text under it, so the verifier leaves it out.
pub fn proves_from(from_address: &str, signing_domains: &[String]) -> bool {
    let Some((_, from_domain)) = from_address.rsplit_once('@') else {
        return false;
    };
    signing_domains.iter().any(|d| aligned(d, from_domain))
}

// ── Route: what an inbound mail is ──────────────────────────────────────────

/// What the client knows about one inbound mail.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct RouteFacts {
    pub mail: Mail,
    pub cookie_domain: String,
    /// The recipient that is Cookie's (lowercase).
    pub cookie_rcpt: String,
    pub address: Address,
    /// The member whose address the mail is From, if any.
    pub member: Option<String>,
    /// The mail proves its From (DKIM-aligned, whole body).
    pub proven: bool,
    /// The `+q_` run asked questions of this member, in this project.
    pub asked_ok: bool,
}

/// What an inbound mail is. Credits are not decided here: the client checks
/// them after `answers` and `job`.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Route {
    /// A reply to a draft. Only the member it was written for, proven,
    /// decides it ([`decision`] on the own text); anyone else is ignored.
    /// (`draft_id`, not `id`: the line's reply carries its own `id`.)
    Draft { draft_id: String },
    /// A reply to Cookie's questions: the job starts now, once the client
    /// claims the questions. A claim already taken → route again with
    /// `asked_ok: false`, and the mail is read as an ordinary message.
    Answers { run: String, own: String },
    /// `automatic` | `bcc`: recorded, never answered.
    Silent { why: String },
    /// Not a member: nothing runs; the owners get [`notice`] `owner`.
    Outsider { sender_domain: String },
    /// A member's address the mail does not prove: nothing runs; the member
    /// gets [`notice`] `unproven` at their own address.
    Unproven,
    /// A verified teammate's job.
    Job { own: String, context: String, subject: String, origin: Value },
}

pub fn route(f: &RouteFacts) -> Route {
    let mail = &f.mail;
    if let Some(id) = &f.address.draft {
        return Route::Draft { draft_id: id.clone() };
    }
    if let (Some(run), Some(_)) = (&f.address.question, &f.member) {
        if f.proven && f.asked_ok {
            return Route::Answers { run: run.clone(), own: split_own_text(&mail.text).0 };
        }
    }
    if mail.automatic {
        return Route::Silent { why: "automatic".into() };
    }
    let visible = mail.to.iter().chain(mail.cc.iter()).any(|a| {
        a.eq_ignore_ascii_case(&f.cookie_rcpt) || parse_address(a, &f.cookie_domain).is_some_and(|x| x.local == f.address.local)
    });
    if !visible {
        return Route::Silent { why: "bcc".into() };
    }
    if f.member.is_none() {
        return Route::Outsider { sender_domain: address_domain(&mail.from).to_string() };
    }
    if !f.proven {
        return Route::Unproven;
    }
    let (own, context) = split_own_text(&mail.text);
    Route::Job { own, context, subject: mail.subject.clone(), origin: json!({"mail": mail_origin(mail)}) }
}

// ── Reply: where the answer goes ────────────────────────────────────────────

/// What the client knows when a mail, page or tool run ends.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct ReplyFacts {
    /// The job's thread; absent for a page or tool job.
    pub mail: Option<Mail>,
    /// The member's own address, for a job with no thread.
    pub member_email: String,
    /// The team's Cookie local part.
    pub local: String,
    pub cookie_domain: String,
    pub run_id: String,
    pub team: String,
    /// The job's subject.
    pub subject: String,
    /// People on the thread who are not on the team.
    pub outsiders: Vec<String>,
    pub answer: Option<String>,
    pub questions: Option<String>,
    /// The job's page ("" for none).
    pub link: String,
    /// A fresh `d_…` id, used only when a draft is made.
    pub draft_id: String,
}

/// The draft waiting for the member: sent as written when they say `send`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DraftPlan {
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub subject: String,
    pub body: String,
    pub in_reply_to: String,
    pub references: Vec<String>,
}

/// The private mail that shows the member a draft.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DraftNotice {
    pub to: Vec<String>,
    pub reply_to: String,
    pub subject: String,
    pub text: String,
}

/// What to send when a run ends (the run is recorded as `asked`, `failed`,
/// `replied` or `drafted` accordingly).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Reply {
    /// To the member alone, whoever else is on the thread; their reply comes
    /// back tagged to this run.
    Questions { to: Vec<String>, reply_to: String, subject: String, text: String, in_reply_to: String, references: Vec<String> },
    Failure { to: Vec<String>, subject: String, text: String, in_reply_to: String, references: Vec<String> },
    /// Only the team can see the thread: answer it.
    Thread { to: Vec<String>, cc: Vec<String>, subject: String, text: String, in_reply_to: String, references: Vec<String> },
    /// Someone outside the team is on the thread: a private draft first.
    Draft { draft: DraftPlan, notice: DraftNotice },
}

pub fn plan_reply(f: &ReplyFacts) -> Result<Reply, String> {
    let sig = signature(&f.team);
    let link = if f.link.is_empty() { String::new() } else { format!("\nSee how Cookie worked it out: {}", f.link) };
    // The thread to answer in: the mail's, or — for a page or tool job — a
    // fresh one to the member's own address.
    let (to_member, in_reply_to, references, subject) = match f.mail.as_ref().filter(|m| !m.from.is_empty()) {
        Some(m) => (m.from.clone(), m.message_id.clone(), thread_refs(m), reply_subject(&m.subject)),
        None if !f.member_email.trim().is_empty() => {
            (f.member_email.trim().to_ascii_lowercase(), String::new(), Vec::new(), format!("Cookie: {}", f.subject))
        }
        None => return Err("the member has no email to answer at".into()),
    };

    if let Some(qs) = &f.questions {
        return Ok(Reply::Questions {
            to: vec![to_member],
            reply_to: format!("{}+q_{}@{}", f.local, f.run_id.trim_start_matches("ck_"), f.cookie_domain),
            subject,
            text: format!("Before I start, a few quick questions:\n\n{qs}\n\nReply to this email and I'll get going.{sig}{link}"),
            in_reply_to,
            references,
        });
    }

    let Some(answer) = f.answer.as_deref().map(str::trim).filter(|a| !a.is_empty()) else {
        return Ok(Reply::Failure {
            to: vec![to_member],
            subject,
            text: format!("Cookie couldn't finish this one, sorry. Try again, or ask it in smaller steps.{sig}{link}"),
            in_reply_to,
            references,
        });
    };

    if f.outsiders.is_empty() {
        let cc: Vec<String> = f
            .mail
            .as_ref()
            .map(|m| thread_people(m, &f.cookie_domain).into_iter().filter(|p| !p.eq_ignore_ascii_case(&to_member)).collect())
            .unwrap_or_default();
        return Ok(Reply::Thread { to: vec![to_member], cc, subject, text: format!("{answer}{sig}{link}"), in_reply_to, references });
    }

    let mail = f.mail.as_ref().ok_or("outsiders come only from a mail thread")?;
    if f.draft_id.is_empty() {
        return Err("a draft needs `draft_id`".into());
    }
    let mut to: Vec<String> = Vec::new();
    for a in std::iter::once(&mail.from).chain(mail.to.iter()) {
        let a = a.to_ascii_lowercase();
        if parse_address(&a, &f.cookie_domain).is_none() && !to.contains(&a) {
            to.push(a);
        }
    }
    let cc: Vec<String> = mail
        .cc
        .iter()
        .map(|a| a.to_ascii_lowercase())
        .filter(|a| parse_address(a, &f.cookie_domain).is_none() && !to.contains(a))
        .collect();
    let body = format!("{answer}{sig}");
    let text = format!(
        "Here's a reply for the thread. It goes to {} — people outside your team — so it waits for you.\n\n\
         Reply \"send\" to send it as Cookie, or \"skip\".\n\n\
         ─────────────\n{body}\n─────────────\n{link}",
        f.outsiders.join(", "),
    );
    Ok(Reply::Draft {
        notice: DraftNotice {
            to: vec![to_member],
            reply_to: format!("{}+{}@{}", f.local, f.draft_id, f.cookie_domain),
            subject: format!("Draft: {subject}"),
            text,
        },
        draft: DraftPlan { to, cc, subject, body, in_reply_to: mail.message_id.clone(), references },
    })
}

// ── Notices ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct NoticeFacts {
    pub team: String,
    /// `owner`: the outside sender's domain ("" when unknown).
    pub sender_domain: String,
    /// `unproven`, `out_of_credits`, `draft_unclear`: the inbound mail's subject.
    pub subject: String,
    /// `out_of_credits`: this month's allowance.
    pub allowance: i64,
    /// `out_of_credits`: Unix seconds.
    pub now: f64,
    /// `draft_unclear`: where the member's next reply goes.
    pub local: String,
    pub draft_id: String,
    pub cookie_domain: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Notice {
    pub subject: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
}

/// The one-line mails Cookie sends when it does not run: `owner` (an outsider
/// wrote; to the first owner, at most one a day), `unproven` (to the
/// member's own address), `out_of_credits` (to the sender, in the thread),
/// `draft_unclear` (a reply to a draft that neither sends nor skips).
pub fn notice(kind: &str, f: &NoticeFacts) -> Result<Notice, String> {
    let sig = signature(&f.team);
    Ok(match kind {
        "owner" => Notice {
            subject: "Cookie didn't reply to an outside sender".into(),
            text: format!(
                "Someone at {} emailed Cookie. They aren't on your team, so Cookie didn't reply or do anything.{sig}",
                if f.sender_domain.is_empty() { "an unknown address" } else { f.sender_domain.as_str() },
            ),
            reply_to: None,
        },
        "unproven" => Notice {
            subject: "Cookie couldn't verify an email from you".into(),
            text: format!(
                "Cookie got an email from your address (\"{}\") that it couldn't verify was really sent by you, so it did \
                 nothing. If it was you, try again from your work email account.{sig}",
                f.subject.chars().take(120).collect::<String>(),
            ),
            reply_to: None,
        },
        "out_of_credits" => Notice {
            subject: reply_subject(&f.subject),
            text: format!("{}{sig}", out_of_credits_line(f.allowance, f.now as i64)),
            reply_to: None,
        },
        "draft_unclear" => Notice {
            subject: reply_subject(&f.subject),
            text: "Cookie didn't send anything. Reply \"send\" to send the draft, or \"skip\".".into(),
            reply_to: Some(format!("{}+{}@{}", f.local, f.draft_id, f.cookie_domain)),
        },
        other => return Err(format!("unknown notice `{other}`")),
    })
}

// ── The line protocol ───────────────────────────────────────────────────────

fn field<T: serde::de::DeserializeOwned>(m: &Value, k: &str) -> Result<T, String> {
    serde_json::from_value(m.get(k).cloned().unwrap_or(Value::Null)).map_err(|e| format!("`{k}`: {e}"))
}

fn text(m: &Value, k: &str) -> String {
    m.get(k).and_then(Value::as_str).unwrap_or_default().to_string()
}

/// One `mail` line: `op` is
///
/// * `route` — [`RouteFacts`] fields (`address` may be left out: it is read
///   from `cookie_rcpt`) → a [`Route`];
/// * `reply` — [`ReplyFacts`] fields → a [`Reply`];
/// * `notice` — `{kind, …NoticeFacts}` → `{subject, text, reply_to?}`;
/// * `split {text}` → `{own, quoted}`; `decision {text}` → `{decision}`
///   (`send` | `skip` | `unclear`, read from the own text only);
/// * `automatic {auto_submitted, precedence, x_autoreply}` → `{automatic}`;
/// * `input {subject, own, parent?: {job, questions}, from_line? | trigger +
///   from + member_name, outsiders?, ext_shared?, context?}` → `{input,
///   from_line, context}`; `lookup {subject, own}` → `{query}`;
/// * `people {mail, cookie_domain}` → `{people}`; `origin {mail}` →
///   `{origin}`; `from_origin {origin}` → `{mail}` (null when absent);
/// * `address {address, cookie_domain}` → `{address}` (null when not Cookie's);
/// * `refs {mail}` → `{references}` for a reply in its thread;
/// * `out_of_credits_line {allowance, now}` → `{text}` (no signature).
pub fn rpc(m: &Value) -> Result<Value, String> {
    match m.get("op").and_then(Value::as_str).unwrap_or_default() {
        "route" => {
            let mut f: RouteFacts = serde_json::from_value(m.clone()).map_err(|e| format!("route: {e}"))?;
            if m.get("address").is_none_or(Value::is_null) {
                f.address = parse_address(&f.cookie_rcpt, &f.cookie_domain).ok_or("`cookie_rcpt` is not a Cookie address")?;
            }
            serde_json::to_value(route(&f)).map_err(|e| e.to_string())
        }
        "reply" => {
            let f: ReplyFacts = serde_json::from_value(m.clone()).map_err(|e| format!("reply: {e}"))?;
            serde_json::to_value(plan_reply(&f)?).map_err(|e| e.to_string())
        }
        "notice" => {
            let f: NoticeFacts = serde_json::from_value(m.clone()).map_err(|e| format!("notice: {e}"))?;
            serde_json::to_value(notice(&text(m, "kind"), &f)?).map_err(|e| e.to_string())
        }
        "split" => {
            let (own, quoted) = split_own_text(&text(m, "text"));
            Ok(json!({"own": own, "quoted": quoted}))
        }
        "decision" => Ok(json!({"decision": decision(&split_own_text(&text(m, "text")).0).as_str()})),
        "automatic" => Ok(json!({"automatic": is_automatic(
            &text(m, "auto_submitted"),
            &text(m, "precedence"),
            m.get("x_autoreply").and_then(Value::as_bool).unwrap_or(false),
        )})),
        "input" => {
            let from = match m.get("from_line").and_then(Value::as_str) {
                Some(l) => l.to_string(),
                None => from_line(&text(m, "trigger"), &text(m, "from"), &text(m, "member_name")),
            };
            let parent = m.get("parent").filter(|p| !p.is_null()).map(|p| (text(p, "job"), text(p, "questions")));
            let outsiders: Vec<String> = m.get("outsiders").map(|_| field(m, "outsiders")).transpose()?.unwrap_or_default();
            let ext_shared = m.get("ext_shared").and_then(Value::as_bool).unwrap_or(false);
            Ok(json!({
                "input": input_for(&text(m, "subject"), &from, &text(m, "own"), parent.as_ref().map(|(j, q)| (j.as_str(), q.as_str()))),
                "from_line": from,
                "context": context_for(&outsiders, ext_shared, &text(m, "context")),
            }))
        }
        "lookup" => Ok(json!({"query": lookup_query(&text(m, "subject"), &text(m, "own"))})),
        "people" => {
            let mail: Mail = field(m, "mail")?;
            Ok(json!({"people": thread_people(&mail, &text(m, "cookie_domain"))}))
        }
        "origin" => {
            let mail: Mail = field(m, "mail")?;
            Ok(json!({"origin": {"mail": mail_origin(&mail)}}))
        }
        "from_origin" => Ok(json!({"mail": mail_from_origin(m.get("origin").unwrap_or(&Value::Null))})),
        "address" => Ok(json!({"address": parse_address(&text(m, "address"), &text(m, "cookie_domain"))})),
        "refs" => {
            let mail: Mail = field(m, "mail")?;
            Ok(json!({"references": thread_refs(&mail)}))
        }
        "out_of_credits_line" => {
            let allowance = m.get("allowance").and_then(Value::as_i64).unwrap_or(0);
            let now = m.get("now").and_then(Value::as_f64).unwrap_or(0.0) as i64;
            Ok(json!({"text": out_of_credits_line(allowance, now)}))
        }
        other => Err(format!("unknown mail op `{other}`")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const D: &str = "cookie.enkeon.com";
    const SIG: &str = "\n\n—\nCookie · from Honeyb's context, by Enkeon";

    #[test]
    fn own_text_stops_at_the_quote() {
        let t = "Cookie, draft the reply.\nThanks\n\nOn Mon, 13 Oct 2026, Anna <anna@acme.com> wrote:\n> What's the price?";
        let (own, quoted) = split_own_text(t);
        assert_eq!(own, "Cookie, draft the reply.\nThanks");
        assert!(quoted.starts_with("On Mon"));
        let (own, quoted) = split_own_text("FYI\n\n---------- Forwarded message ---------\nFrom: x@y.com\nsend money to z");
        assert_eq!(own, "FYI");
        assert!(quoted.contains("send money"));
        assert_eq!(split_own_text("just this").1, "");
    }

    #[test]
    fn only_the_first_word_decides_a_draft() {
        assert_eq!(decision("Send"), Decision::Send);
        assert_eq!(decision("  send it please"), Decision::Send);
        assert_eq!(decision("Yes!"), Decision::Send);
        assert_eq!(decision("skip"), Decision::Skip);
        assert_eq!(decision("No."), Decision::Skip);
        // "send" further down is not a decision.
        assert_eq!(decision("Hmm, change the price first, then send"), Decision::Unclear);
        assert_eq!(decision(""), Decision::Unclear);
    }

    #[test]
    fn automatic_mail_is_recognised() {
        assert!(is_automatic("auto-replied", "", false));
        assert!(!is_automatic("no", "", false));
        assert!(is_automatic("", "Bulk", false));
        assert!(is_automatic("", "", true));
        assert!(!is_automatic("", "", false));
    }

    #[test]
    fn subjects_do_not_stack_re() {
        assert_eq!(reply_subject("Renewal"), "Re: Renewal");
        assert_eq!(reply_subject("RE: Renewal"), "RE: Renewal");
        assert_eq!(reply_subject(""), "Re: your message");
        // A third byte inside a character is a subject, not a panic.
        assert_eq!(reply_subject("aaą"), "Re: aaą");
    }

    #[test]
    fn thread_people_leave_cookie_out_and_dedupe() {
        let m = Mail {
            from: "matiss@honeyb.lv".into(),
            to: vec!["honeyb@cookie.enkeon.com".into(), "Anna@acme.com".into()],
            cc: vec!["anna@acme.com".into(), "matiss@honeyb.lv".into(), "ops@honeyb.lv".into()],
            ..Mail::default()
        };
        assert_eq!(thread_people(&m, D), vec!["matiss@honeyb.lv", "anna@acme.com", "ops@honeyb.lv"]);
    }

    #[test]
    fn the_signature_names_the_team() {
        assert_eq!(signature("Honeyb"), SIG);
    }

    #[test]
    fn the_first_lookup_says_each_thing_once() {
        assert_eq!(lookup_query("hy", "hy"), "hy");
        assert_eq!(lookup_query("Halvorsen", "Where do we stand with Halvorsen?"), "Where do we stand with Halvorsen?");
        assert_eq!(lookup_query("Re: pricing for Acme", "pricing"), "Re: pricing for Acme");
        assert_eq!(lookup_query("Brief me", "Northwind before Thursday"), "Brief me Northwind before Thursday");
    }

    #[test]
    fn months_come_from_unix_seconds() {
        assert_eq!(month_name(0), ("January".into(), "1 February".into()));
        // 2024-02-29 00:00 and 2024-03-01 00:00 UTC (a leap day).
        assert_eq!(month_name(1_709_164_800).0, "February");
        assert_eq!(month_name(1_709_251_200).0, "March");
        // 2024-12-31 23:59:59 → December, renewing in January.
        assert_eq!(month_name(1_735_689_599), ("December".into(), "1 January".into()));
        assert_eq!(month_name(1_735_689_600).0, "January");
        // 2023-11-14 22:13:20.
        assert_eq!(month_name(1_700_000_000).0, "November");
        // Before 1970: 1969-12-31 23:59:59.
        assert_eq!(month_name(-1).0, "December");
        assert_eq!(
            out_of_credits_line(500, 1_792_627_200), // 2026-10-22
            "Cookie has used its 500 credits for October, so it can't take this one. They renew on 1 November."
        );
    }

    #[test]
    fn origin_round_trips_the_thread() {
        let m = mail();
        let back = mail_from_origin(&json!({"mail": mail_origin(&m)})).unwrap();
        assert_eq!(back, Mail { text: String::new(), in_reply_to: String::new(), ..m });
        assert_eq!(mail_from_origin(&json!({})), None);
    }

    #[test]
    fn inputs_carry_the_job_and_the_answers() {
        assert_eq!(input_for("Brief", "m@h.lv (on your team)", "Acme", None), "Subject: Brief\nFrom: m@h.lv (on your team)\n\nAcme");
        assert_eq!(
            input_for("Leads", "Matiss (on your team)", "Baltics", Some(("Find leads", "Which region?"))),
            "Subject: Leads\nFrom: Matiss (on your team)\n\nThe job:\nFind leads\n\nBefore starting, you asked:\nWhich region?\n\nTheir answer:\nBaltics\n\nNow do the job."
        );
        assert_eq!(from_line("slack", "", "Matiss"), "Matiss, in Slack (on your team)");
        assert_eq!(from_line("email", "m@h.lv", "Matiss"), "m@h.lv (on your team)");
        assert_eq!(from_line("page", "", "Matiss"), "Matiss (on your team)");
        assert_eq!(
            context_for(&["anna@acme.com".into()], true, "quoted"),
            "People outside the team on this thread: anna@acme.com.\n\nThis Slack channel includes people outside the team.\n\nquoted"
        );
    }

    #[test]
    fn alignment_is_by_organisational_domain() {
        assert!(aligned("acme.com", "acme.com"));
        assert!(aligned("mail.acme.com", "acme.com"), "relaxed: a subdomain signs for its organisation");
        assert!(aligned("acme.co.uk", "sales.acme.co.uk"));
        assert!(!aligned("acme.com", "acme.co"));
        assert!(!aligned("co.uk", "acme.co.uk"), "a public suffix is nobody's domain");
        assert!(!aligned("evilacme.com", "acme.com"));
    }

    #[test]
    fn only_an_aligned_signature_proves_the_sender() {
        let d = |s: &str| vec![s.to_string()];
        assert!(proves_from("matiss@honeyb.lv", &d("honeyb.lv")));
        // Gmail-style: the provider signs for its own domain, which IS the From domain.
        assert!(proves_from("someone@gmail.com", &d("gmail.com")));
        // A mailing service signing only as itself proves nothing about the From.
        assert!(!proves_from("matiss@honeyb.lv", &d("sendgrid.net")));
        assert!(!proves_from("matiss@honeyb.lv", &[]));
        assert!(!proves_from("not-an-address", &d("honeyb.lv")));
    }

    #[test]
    fn addresses_parse_team_and_draft() {
        let plain = Address { local: "honeyb".into(), draft: None, question: None };
        assert_eq!(parse_address("Cookie <HoneyB@Cookie.Enkeon.com>", D), Some(plain.clone()));
        assert_eq!(parse_address("honeyb+d_abc123@cookie.enkeon.com", D), Some(Address { draft: Some("d_abc123".into()), ..plain.clone() }));
        assert_eq!(parse_address("honeyb+q_9f8e@cookie.enkeon.com", D), Some(Address { question: Some("ck_9f8e".into()), ..plain.clone() }));
        // A tag that is not a draft or a question is ignored, not trusted.
        assert_eq!(parse_address("honeyb+x@cookie.enkeon.com", D), Some(plain.clone()));
        assert_eq!(parse_address("honeyb+d_@cookie.enkeon.com", D), Some(plain.clone()));
        assert_eq!(parse_address("honeyb+q_x-y@cookie.enkeon.com", D), Some(plain));
        assert_eq!(parse_address("honeyb@enkeon.com", D), None);
        assert_eq!(parse_address("honeyb@evil-cookie.enkeon.com.attacker.io", D), None);
        assert_eq!(parse_address("x@cookie.enkeon.com", ""), None);
    }

    fn mail() -> Mail {
        Mail {
            message_id: "m1@honeyb.lv".into(),
            in_reply_to: "a0@acme.com".into(),
            references: vec!["a0@acme.com".into()],
            from: "matiss@honeyb.lv".into(),
            to: vec!["honeyb@cookie.enkeon.com".into(), "anna@acme.com".into()],
            cc: vec!["ops@honeyb.lv".into()],
            subject: "Renewal".into(),
            text: "Cookie, draft the reply.\n\nOn Mon, Anna wrote:\n> price?".into(),
            automatic: false,
        }
    }

    fn facts() -> RouteFacts {
        RouteFacts {
            mail: mail(),
            cookie_domain: D.into(),
            cookie_rcpt: "honeyb@cookie.enkeon.com".into(),
            address: parse_address("honeyb@cookie.enkeon.com", D).unwrap(),
            member: Some("usr_1".into()),
            proven: true,
            asked_ok: false,
        }
    }

    #[test]
    fn a_verified_teammate_gets_a_job_with_only_their_own_words() {
        match route(&facts()) {
            Route::Job { own, context, subject, origin } => {
                assert_eq!(own, "Cookie, draft the reply.");
                assert!(context.starts_with("On Mon"));
                assert_eq!(subject, "Renewal");
                assert_eq!(origin["mail"]["message_id"], "m1@honeyb.lv");
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_reply_to_a_draft_is_routed_to_the_draft_first() {
        let mut f = facts();
        f.address = parse_address("honeyb+d_abc@cookie.enkeon.com", D).unwrap();
        // Even unproven and automatic: the draft's own check decides.
        f.proven = false;
        f.mail.automatic = true;
        assert_eq!(route(&f), Route::Draft { draft_id: "d_abc".into() });
    }

    #[test]
    fn answers_start_only_for_the_proven_member_who_was_asked() {
        let mut f = facts();
        f.address = parse_address("honeyb+q_9f8e@cookie.enkeon.com", D).unwrap();
        f.mail.to = vec!["honeyb+q_9f8e@cookie.enkeon.com".into()];
        f.cookie_rcpt = "honeyb+q_9f8e@cookie.enkeon.com".into();
        f.asked_ok = true;
        assert_eq!(route(&f), Route::Answers { run: "ck_9f8e".into(), own: "Cookie, draft the reply.".into() });
        // Not the asked member, or unproven → read as an ordinary message.
        f.asked_ok = false;
        assert!(matches!(route(&f), Route::Job { .. }));
        f.asked_ok = true;
        f.proven = false;
        assert_eq!(route(&f), Route::Unproven);
    }

    #[test]
    fn automatic_and_blind_copied_mail_is_never_answered() {
        let mut f = facts();
        f.mail.automatic = true;
        assert_eq!(route(&f), Route::Silent { why: "automatic".into() });
        let mut f = facts();
        f.mail.to = vec!["anna@acme.com".into()];
        f.mail.cc = vec![];
        assert_eq!(route(&f), Route::Silent { why: "bcc".into() });
        // Cookie visible under another tag of the same team counts.
        f.mail.cc = vec!["HoneyB+d_x@cookie.enkeon.com".into()];
        assert!(matches!(route(&f), Route::Job { .. }));
    }

    #[test]
    fn outsiders_and_unproven_teammates_run_nothing() {
        let mut f = facts();
        f.member = None;
        f.mail.from = "anna@acme.com".into();
        assert_eq!(route(&f), Route::Outsider { sender_domain: "acme.com".into() });
        let mut f = facts();
        f.proven = false;
        assert_eq!(route(&f), Route::Unproven);
    }

    #[test]
    fn route_over_the_line_reads_the_address_from_the_recipient() {
        let m = json!({"type": "mail", "op": "route", "mail": mail(), "cookie_domain": D,
                       "cookie_rcpt": "honeyb@cookie.enkeon.com", "member": "usr_1", "proven": true});
        let r = rpc(&m).unwrap();
        assert_eq!(r["kind"], "job");
        assert_eq!(r["own"], "Cookie, draft the reply.");
        let bad = json!({"op": "route", "cookie_domain": D, "cookie_rcpt": "x@elsewhere.com"});
        assert!(rpc(&bad).is_err());
    }

    fn reply_facts() -> ReplyFacts {
        ReplyFacts {
            mail: Some(mail()),
            member_email: "matiss@honeyb.lv".into(),
            local: "honeyb".into(),
            cookie_domain: D.into(),
            run_id: "ck_9f8e".into(),
            team: "Honeyb".into(),
            subject: "Renewal".into(),
            outsiders: vec![],
            answer: None,
            questions: None,
            link: "https://x/j".into(),
            draft_id: String::new(),
        }
    }

    #[test]
    fn questions_go_to_the_member_alone_with_their_reply_routed_back() {
        let f = ReplyFacts { questions: Some("1. Which region?".into()), outsiders: vec!["anna@acme.com".into()], ..reply_facts() };
        assert_eq!(
            plan_reply(&f).unwrap(),
            Reply::Questions {
                to: vec!["matiss@honeyb.lv".into()],
                reply_to: "honeyb+q_9f8e@cookie.enkeon.com".into(),
                subject: "Re: Renewal".into(),
                text: format!("Before I start, a few quick questions:\n\n1. Which region?\n\nReply to this email and I'll get going.{SIG}\nSee how Cookie worked it out: https://x/j"),
                in_reply_to: "m1@honeyb.lv".into(),
                references: vec!["a0@acme.com".into(), "m1@honeyb.lv".into()],
            }
        );
        // The reply-to round-trips to the run.
        let Reply::Questions { reply_to, .. } = plan_reply(&f).unwrap() else { unreachable!() };
        assert_eq!(parse_address(&reply_to, D).unwrap().question.as_deref(), Some("ck_9f8e"));
    }

    #[test]
    fn no_answer_is_a_failure_note_and_a_page_job_answers_at_the_members_address() {
        let f = ReplyFacts { mail: None, member_email: "Matiss@Honeyb.lv".into(), answer: Some("  ".into()), link: String::new(), ..reply_facts() };
        assert_eq!(
            plan_reply(&f).unwrap(),
            Reply::Failure {
                to: vec!["matiss@honeyb.lv".into()],
                subject: "Cookie: Renewal".into(),
                text: format!("Cookie couldn't finish this one, sorry. Try again, or ask it in smaller steps.{SIG}"),
                in_reply_to: String::new(),
                references: vec![],
            }
        );
        let nobody = ReplyFacts { mail: None, member_email: String::new(), ..reply_facts() };
        assert!(plan_reply(&nobody).is_err());
    }

    #[test]
    fn a_team_only_thread_is_answered_in_place_with_everyone_copied() {
        let mut m = mail();
        m.to = vec!["honeyb@cookie.enkeon.com".into(), "Ilze@honeyb.lv".into()];
        let f = ReplyFacts { mail: Some(m), answer: Some(" Price is 40. ".into()), ..reply_facts() };
        assert_eq!(
            plan_reply(&f).unwrap(),
            Reply::Thread {
                to: vec!["matiss@honeyb.lv".into()],
                cc: vec!["ilze@honeyb.lv".into(), "ops@honeyb.lv".into()],
                subject: "Re: Renewal".into(),
                text: format!("Price is 40.{SIG}\nSee how Cookie worked it out: https://x/j"),
                in_reply_to: "m1@honeyb.lv".into(),
                references: vec!["a0@acme.com".into(), "m1@honeyb.lv".into()],
            }
        );
    }

    #[test]
    fn outsiders_on_the_thread_make_a_private_draft() {
        let f = ReplyFacts { answer: Some("Price is 40.".into()), outsiders: vec!["anna@acme.com".into()], draft_id: "d_abc".into(), ..reply_facts() };
        let Reply::Draft { draft, notice } = plan_reply(&f).unwrap() else { panic!("not a draft") };
        assert_eq!(
            draft,
            DraftPlan {
                to: vec!["matiss@honeyb.lv".into(), "anna@acme.com".into()],
                cc: vec!["ops@honeyb.lv".into()],
                subject: "Re: Renewal".into(),
                body: format!("Price is 40.{SIG}"),
                in_reply_to: "m1@honeyb.lv".into(),
                references: vec!["a0@acme.com".into(), "m1@honeyb.lv".into()],
            }
        );
        assert_eq!(notice.to, vec!["matiss@honeyb.lv"]);
        assert_eq!(notice.reply_to, "honeyb+d_abc@cookie.enkeon.com");
        assert_eq!(notice.subject, "Draft: Re: Renewal");
        assert_eq!(
            notice.text,
            format!(
                "Here's a reply for the thread. It goes to anna@acme.com — people outside your team — so it waits for you.\n\nReply \"send\" to send it as Cookie, or \"skip\".\n\n─────────────\nPrice is 40.{SIG}\n─────────────\n\nSee how Cookie worked it out: https://x/j"
            )
        );
        assert!(plan_reply(&ReplyFacts { draft_id: String::new(), ..f }).is_err(), "a draft needs its id");
    }

    #[test]
    fn notices_say_what_did_not_happen() {
        let f = NoticeFacts { team: "Honeyb".into(), sender_domain: "acme.com".into(), ..NoticeFacts::default() };
        let n = notice("owner", &f).unwrap();
        assert_eq!(n.subject, "Cookie didn't reply to an outside sender");
        assert_eq!(n.text, format!("Someone at acme.com emailed Cookie. They aren't on your team, so Cookie didn't reply or do anything.{SIG}"));
        assert!(notice("owner", &NoticeFacts { sender_domain: String::new(), ..f.clone() }).unwrap().text.starts_with("Someone at an unknown address"));
        let n = notice("unproven", &NoticeFacts { subject: "Send the deck".into(), ..f.clone() }).unwrap();
        assert_eq!(
            n.text,
            format!("Cookie got an email from your address (\"Send the deck\") that it couldn't verify was really sent by you, so it did nothing. If it was you, try again from your work email account.{SIG}")
        );
        let n = notice("out_of_credits", &NoticeFacts { subject: "Renewal".into(), allowance: 100, now: 1_792_627_200.0, ..f.clone() }).unwrap();
        assert_eq!(n.subject, "Re: Renewal");
        assert!(n.text.starts_with("Cookie has used its 100 credits for October"));
        let n = notice("draft_unclear", &NoticeFacts { subject: "Draft: Re: Renewal".into(), local: "honeyb".into(), draft_id: "d_abc".into(), cookie_domain: D.into(), ..f.clone() }).unwrap();
        assert_eq!(n.text, "Cookie didn't send anything. Reply \"send\" to send the draft, or \"skip\".");
        assert_eq!(n.reply_to.as_deref(), Some("honeyb+d_abc@cookie.enkeon.com"));
        assert!(notice("nope", &f).is_err());
    }

    #[test]
    fn small_ops_answer_over_the_line() {
        assert_eq!(rpc(&json!({"op": "decision", "text": "Send\n\nOn Mon, x wrote:\n> skip"})).unwrap()["decision"], "send");
        assert_eq!(rpc(&json!({"op": "split", "text": "hi\n> q"})).unwrap(), json!({"own": "hi", "quoted": "> q"}));
        assert_eq!(rpc(&json!({"op": "lookup", "subject": "hy", "own": "hy"})).unwrap()["query"], "hy");
        assert_eq!(rpc(&json!({"op": "address", "address": "honeyb+d_a1@cookie.enkeon.com", "cookie_domain": D})).unwrap()["address"]["draft"], "d_a1");
        assert_eq!(rpc(&json!({"op": "address", "address": "a@b.com", "cookie_domain": D})).unwrap()["address"], Value::Null);
        let i = rpc(&json!({"op": "input", "subject": "S", "own": "O", "trigger": "page", "member_name": "Matiss", "parent": {"job": "J", "questions": "Q"}})).unwrap();
        assert_eq!(i["from_line"], "Matiss (on your team)");
        assert!(i["input"].as_str().unwrap().ends_with("Their answer:\nO\n\nNow do the job."));
        assert_eq!(rpc(&json!({"op": "people", "mail": mail(), "cookie_domain": D})).unwrap()["people"], json!(["matiss@honeyb.lv", "anna@acme.com", "ops@honeyb.lv"]));
        let o = rpc(&json!({"op": "origin", "mail": mail()})).unwrap();
        assert_eq!(rpc(&json!({"op": "from_origin", "origin": o["origin"]})).unwrap()["mail"]["from"], "matiss@honeyb.lv");
        assert_eq!(rpc(&json!({"op": "automatic", "precedence": "list"})).unwrap()["automatic"], true);
        assert!(rpc(&json!({"op": "nope"})).is_err());
    }
}
