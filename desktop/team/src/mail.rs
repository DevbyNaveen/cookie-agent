//! Mail to Cookie: a runner with its own address answers your mail.
//!
//! Mail reaches the runner from whatever receives it for Cookie's domain
//! (an email worker, an MTA pipe, an inbound-mail service) as the raw
//! message, POSTed to `/hooks/mail` with the secret Cookie shows once. Then:
//! claim (each message once) → who wrote → run → answer.
//!
//! Where an answer goes is decided by the harness's mail rules
//! (`cookie::mail`), never by the model:
//!
//! - you wrote, the mail proves it (a DKIM signature over the whole body,
//!   aligned with your From domain, checked here on the raw bytes), and
//!   nobody outside is on the thread → Cookie answers in the thread;
//! - someone else is on the thread → you get a private draft; it goes to the
//!   thread only when your own verified reply says `send`;
//! - Cookie was only blind-copied, or the mail is automatic → nothing;
//! - anyone else wrote → nothing runs; you get one line in the app a day;
//! - your address, but the mail doesn't prove it → nothing runs; you're told.
//!
//! Replies go out over SMTP (any provider) from `<local>@<domain>`.
//! Dark until connected in Settings, and only on a runner with a public address.
//! Ported from the super console (gateway `cookie/inbound.rs`, `cookie/auth.rs`).

use std::collections::BTreeMap;
use std::sync::{Arc, OnceLock};

use cookie_harness::cookie::mail::{self as rules, Mail, Reply, Route, RouteFacts};
use mail_auth::{AuthenticatedMessage, DkimResult, MessageAuthenticator};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::store::Trigger;
use crate::{util, Team};

/// What a job's mail keeps, to answer it when the job ends.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct MailJob {
    mail: Mail,
    subject: String,
}

/// A reply waiting for your `send`.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Draft {
    to: Vec<String>,
    cc: Vec<String>,
    subject: String,
    body: String,
    in_reply_to: String,
    references: Vec<String>,
    /// The subject of your mail that started it, for "unclear" answers.
    asked: String,
    at: u64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
struct MailBook {
    /// Message-IDs already handled (the newest 1,000).
    seen: Vec<String>,
    jobs: BTreeMap<String, MailJob>,
    drafts: BTreeMap<String, Draft>,
    /// The day an "outside sender" line was last shown.
    outsider_day: String,
}

/// The runner's mail settings (`channels.json` → `mail.config`); the SMTP
/// password and the inbound secret are in the Keychain.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct MailConfig {
    pub domain: String,
    pub local: String,
    /// Your own addresses: mail from these, proven, is you.
    pub you: Vec<String>,
    pub smtp_host: String,
    pub smtp_port: u16,
    pub smtp_user: String,
    /// The name your replies are signed with.
    pub name: String,
}

impl MailConfig {
    pub fn address(&self) -> String {
        format!("{}@{}", self.local, self.domain)
    }
}

fn authenticator() -> Option<&'static MessageAuthenticator> {
    static A: OnceLock<Option<MessageAuthenticator>> = OnceLock::new();
    A.get_or_init(|| match MessageAuthenticator::new_cloudflare_tls() {
        Ok(a) => Some(a),
        Err(e) => {
            tracing::error!("mail: no DNS resolver for DKIM ({e}); no mail will be trusted");
            None
        }
    })
    .as_ref()
}

/// Does the raw message prove its From? Fails closed: no resolver, no parse,
/// no passing whole-body signature → false.
pub async fn sender_proven(raw: &[u8], from: &str) -> bool {
    let Some(auth) = authenticator() else { return false };
    let Some(msg) = AuthenticatedMessage::parse(raw) else { return false };
    let passed: Vec<String> = auth
        .verify_dkim(&msg)
        .await
        .iter()
        .filter(|o| o.result() == &DkimResult::Pass)
        .filter_map(|o| o.signature())
        .filter(|s| s.l == 0) // a signature over part of the body lets anyone append below it
        .map(|s| s.d.clone())
        .collect();
    rules::proves_from(from, &passed)
}

/// The raw message as the rules read it.
pub fn parse(raw: &[u8]) -> Option<Mail> {
    use mail_parser::MessageParser;
    let msg = MessageParser::default().parse(raw)?;
    let ids = |h: &str| -> Vec<String> {
        msg.header_raw(h).unwrap_or_default().split_whitespace().map(|s| s.trim_matches(|c| c == '<' || c == '>').to_string()).filter(|s| !s.is_empty()).collect()
    };
    let list = |a: Option<&mail_parser::Address>| -> Vec<String> { a.map(|a| a.iter().filter_map(|x| x.address()).map(|s| s.trim().to_ascii_lowercase()).filter(|s| s.contains('@')).collect()).unwrap_or_default() };
    let automatic = rules::is_automatic(msg.header_raw("Auto-Submitted").unwrap_or_default(), msg.header_raw("Precedence").unwrap_or_default(), msg.header_raw("X-Autoreply").is_some() || msg.header_raw("X-Autorespond").is_some());
    Some(Mail {
        message_id: ids("Message-ID").into_iter().next().unwrap_or_default(),
        in_reply_to: ids("In-Reply-To").into_iter().next().unwrap_or_default(),
        references: ids("References"),
        from: list(msg.from()).into_iter().next().unwrap_or_default(),
        to: list(msg.to()),
        cc: list(msg.cc()),
        subject: msg.subject().unwrap_or_default().to_string(),
        text: msg.body_text(0).map(|t| t.to_string()).unwrap_or_default(),
        automatic,
    })
}

impl Team {
    fn mail_path(&self) -> std::path::PathBuf {
        self.paths.root.join("mail.json")
    }

    fn mail_book(&self) -> MailBook {
        util::read_json(&self.mail_path())
    }

    fn save_mail_book(&self, b: &MailBook) {
        let _ = util::write_json(&self.mail_path(), b);
    }

    pub fn mail_config(&self) -> Option<MailConfig> {
        let st = self.channel_states().get("mail").cloned()?;
        if !st.enabled {
            return None;
        }
        serde_json::from_value(st.config).ok().filter(|c: &MailConfig| !c.domain.is_empty() && !c.local.is_empty())
    }

    fn is_you(cfg: &MailConfig, addr: &str) -> bool {
        cfg.you.iter().any(|y| y.trim().eq_ignore_ascii_case(addr.trim()))
    }

    /// One raw message from the mail hook. `recipients`: the envelope's, when the forwarder gives them.
    pub async fn mail_inbound(self: &Arc<Self>, raw: &[u8], recipients: &[String]) -> Result<&'static str, String> {
        let cfg = self.mail_config().ok_or("Mail isn't connected.")?;
        let mail = parse(raw).ok_or("unreadable message")?;
        let rcpt = recipients
            .iter()
            .chain(mail.to.iter())
            .chain(mail.cc.iter())
            .find(|r| rules::parse_address(r, &cfg.domain).is_some())
            .map(|r| r.to_ascii_lowercase())
            .ok_or("not addressed to Cookie")?;
        let address = rules::parse_address(&rcpt, &cfg.domain).unwrap_or_default();
        if address.local != cfg.local {
            return Ok("not this Cookie's address");
        }
        // Each message once: a forwarder's retry is not a second job.
        let key = if mail.message_id.is_empty() { format!("raw:{}", crate::lease::digest(raw)) } else { mail.message_id.clone() };
        {
            let mut b = self.mail_book();
            if b.seen.contains(&key) {
                return Ok("already handled");
            }
            b.seen.push(key);
            let over = b.seen.len().saturating_sub(1000);
            b.seen.drain(..over);
            self.save_mail_book(&b);
        }
        let member = Self::is_you(&cfg, &mail.from).then(|| "you".to_string());
        let proven = member.is_some() && sender_proven(raw, &mail.from).await;
        let route = rules::route(&RouteFacts { mail: mail.clone(), cookie_domain: cfg.domain.clone(), cookie_rcpt: rcpt, address, member, proven, asked_ok: false });
        match route {
            Route::Silent { .. } => Ok("silent"),
            Route::Outsider { sender_domain } => {
                let today = chrono::Local::now().format("%Y-%m-%d").to_string();
                let mut b = self.mail_book();
                if b.outsider_day != today {
                    b.outsider_day = today;
                    self.save_mail_book(&b);
                    let from = if sender_domain.is_empty() { "an unknown address".to_string() } else { sender_domain };
                    self.notice(crate::front::COOKIE_ID, "Cookie didn't reply to an outside sender", &format!("Someone at {from} emailed Cookie. They aren't you, so Cookie didn't reply or do anything."), None, false);
                }
                Ok("outsider")
            }
            Route::Unproven => {
                let n = rules::notice("unproven", &rules::NoticeFacts { team: cfg.name.clone(), subject: mail.subject.clone(), ..Default::default() })?;
                self.notice(crate::front::COOKIE_ID, &n.subject, "A mail from your address couldn't be verified as yours, so Cookie did nothing.", None, true);
                let _ = self.smtp_send(&cfg, std::slice::from_ref(&mail.from), &[], &n.subject, &n.text, None, "", &[]).await;
                Ok("unproven")
            }
            Route::Draft { draft_id } => self.mail_draft_answer(&cfg, &mail, &draft_id, proven).await,
            Route::Answers { .. } => Ok("silent"),
            Route::Job { own, context, subject, .. } => {
                let from = rules::from_line("email", &mail.from, "you");
                let input = rules::input_for(&subject, &from, &own, None);
                let outsiders: Vec<String> = rules::thread_people(&mail, &cfg.domain).into_iter().filter(|p| !Self::is_you(&cfg, p)).collect();
                let ctx = rules::context_for(&outsiders, false, &context);
                let attachments = if ctx.trim().is_empty() { Vec::new() } else { vec![crate::runtime::Attachment { name: "The rest of the thread (quoted)".into(), text: ctx }] };
                let job = self.start_job(crate::front::COOKIE_ID, input, attachments, Trigger::Channel { channel: "mail".into(), chat: mail.from.clone() }).await?;
                let mut b = self.mail_book();
                b.jobs.insert(job, MailJob { mail, subject });
                self.save_mail_book(&b);
                Ok("job")
            }
        }
    }

    /// Your reply to a draft: `send` sends it, `skip` drops it.
    async fn mail_draft_answer(&self, cfg: &MailConfig, mail: &Mail, draft_id: &str, proven: bool) -> Result<&'static str, String> {
        if !Self::is_you(cfg, &mail.from) || !proven {
            return Ok("ignored"); // only you, proven, decide a draft
        }
        let mut b = self.mail_book();
        let Some(d) = b.drafts.get(draft_id).cloned() else { return Ok("no such draft") };
        let (own, _) = rules::split_own_text(&mail.text);
        match rules::decision(&own) {
            rules::Decision::Send => {
                self.smtp_send(cfg, &d.to, &d.cc, &d.subject, &d.body, None, &d.in_reply_to, &d.references).await?;
                b.drafts.remove(draft_id);
                self.save_mail_book(&b);
                Ok("sent")
            }
            rules::Decision::Skip => {
                b.drafts.remove(draft_id);
                self.save_mail_book(&b);
                Ok("skipped")
            }
            rules::Decision::Unclear => {
                let n = rules::notice("draft_unclear", &rules::NoticeFacts { subject: d.asked.clone(), local: cfg.local.clone(), draft_id: draft_id.to_string(), cookie_domain: cfg.domain.clone(), ..Default::default() })?;
                self.smtp_send(cfg, std::slice::from_ref(&mail.from), &[], &n.subject, &n.text, n.reply_to.as_deref(), &mail.message_id, &rules::thread_refs(mail)).await?;
                Ok("unclear")
            }
        }
    }

    /// A mail job ended: answer where the rules say.
    pub(crate) async fn mail_job_finished(&self, job: &str, agent: &str, answer: &str) {
        let Some(cfg) = self.mail_config() else { return };
        let mut b = self.mail_book();
        let Some(mj) = b.jobs.remove(job) else { return };
        self.save_mail_book(&b);
        let outsiders: Vec<String> = rules::thread_people(&mj.mail, &cfg.domain).into_iter().filter(|p| !Self::is_you(&cfg, p)).collect();
        let link = self.job_link(agent, job).await.unwrap_or_default();
        let facts = rules::ReplyFacts {
            mail: Some(mj.mail.clone()),
            member_email: mj.mail.from.clone(),
            local: cfg.local.clone(),
            cookie_domain: cfg.domain.clone(),
            run_id: job.to_string(),
            team: cfg.name.clone(),
            subject: mj.subject.clone(),
            outsiders,
            answer: (!answer.trim().is_empty()).then(|| answer.to_string()),
            questions: None,
            link,
            draft_id: format!("d_{}", util::random_hex(6)),
        };
        let sent = match rules::plan_reply(&facts) {
            Ok(Reply::Thread { to, cc, subject, text, in_reply_to, references }) => self.smtp_send(&cfg, &to, &cc, &subject, &text, None, &in_reply_to, &references).await,
            Ok(Reply::Failure { to, subject, text, in_reply_to, references }) | Ok(Reply::Questions { to, subject, text, in_reply_to, references, .. }) => {
                self.smtp_send(&cfg, &to, &[], &subject, &text, None, &in_reply_to, &references).await
            }
            Ok(Reply::Draft { draft, notice }) => {
                let id = notice.reply_to.split('+').nth(1).and_then(|t| t.split('@').next()).unwrap_or_default().to_string();
                let mut b = self.mail_book();
                b.drafts.insert(id, Draft { to: draft.to, cc: draft.cc, subject: draft.subject, body: draft.body, in_reply_to: draft.in_reply_to, references: draft.references, asked: mj.subject.clone(), at: util::now() });
                self.save_mail_book(&b);
                self.smtp_send(&cfg, &notice.to, &[], &notice.subject, &notice.text, Some(&notice.reply_to), "", &[]).await
            }
            Err(e) => Err(e),
        };
        if let Err(e) = sent {
            self.notice(crate::front::COOKIE_ID, "Cookie couldn't send a mail reply", &e, Some(job), true);
        }
    }

    /// One message out, from Cookie's address.
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn smtp_send(&self, cfg: &MailConfig, to: &[String], cc: &[String], subject: &str, text: &str, reply_to: Option<&str>, in_reply_to: &str, references: &[String]) -> Result<(), String> {
        use lettre::message::{header::ContentType, Mailbox};
        use lettre::transport::smtp::authentication::Credentials;
        use lettre::{AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor};
        let password = self.keys.get("channel:mail").ok_or("No SMTP password is saved.")?;
        let from: Mailbox = format!("{} <{}>", if cfg.name.is_empty() { "Cookie" } else { &cfg.name }, cfg.address()).parse().map_err(|e| format!("Cookie's address: {e}"))?;
        let mut m = Message::builder().from(from).subject(subject);
        for a in to {
            m = m.to(a.parse().map_err(|e| format!("{a}: {e}"))?);
        }
        for a in cc {
            m = m.cc(a.parse().map_err(|e| format!("{a}: {e}"))?);
        }
        if let Some(r) = reply_to {
            m = m.reply_to(r.parse().map_err(|e| format!("{r}: {e}"))?);
        }
        if !in_reply_to.is_empty() {
            m = m.in_reply_to(format!("<{in_reply_to}>"));
        }
        if !references.is_empty() {
            m = m.references(references.iter().map(|r| format!("<{r}>")).collect::<Vec<_>>().join(" "));
        }
        let msg = m.header(ContentType::TEXT_PLAIN).body(text.to_string()).map_err(|e| e.to_string())?;
        let port = if cfg.smtp_port == 0 { 587 } else { cfg.smtp_port };
        let builder = if port == 465 { AsyncSmtpTransport::<Tokio1Executor>::relay(&cfg.smtp_host) } else { AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&cfg.smtp_host) }.map_err(|e| e.to_string())?;
        let mailer = builder.port(port).credentials(Credentials::new(cfg.smtp_user.clone(), password)).build();
        mailer.send(msg).await.map(|_| ()).map_err(|e| format!("SMTP: {e}"))
    }

    pub fn mail_status(&self) -> Value {
        let b = self.mail_book();
        json!({"address": self.mail_config().map(|c| c.address()), "drafts": b.drafts.len(), "waiting_jobs": b.jobs.len()})
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RAW: &[u8] = b"From: Ana <ana@acme.com>\r\nTo: me@cookie.example.com\r\nCc: bob@outside.org\r\nSubject: The Q3 numbers\r\nMessage-ID: <m1@acme.com>\r\n\r\nCan you pull the Q3 numbers?\r\n\r\nOn Mon, Bob wrote:\r\n> earlier text\r\n";

    #[test]
    fn a_mail_is_read_into_the_rules_shape() {
        let m = parse(RAW).unwrap();
        assert_eq!(m.from, "ana@acme.com");
        assert_eq!(m.to, vec!["me@cookie.example.com"]);
        assert_eq!(m.cc, vec!["bob@outside.org"]);
        assert_eq!(m.message_id, "m1@acme.com");
        assert!(!m.automatic);
        let auto = parse(b"From: a@b.com\r\nTo: me@cookie.example.com\r\nAuto-Submitted: auto-replied\r\nSubject: Away\r\n\r\nout of office\r\n").unwrap();
        assert!(auto.automatic, "an out-of-office is never an instruction");
    }

    #[tokio::test]
    async fn an_unsigned_mail_from_your_address_proves_nothing() {
        assert!(!sender_proven(RAW, "ana@acme.com").await, "no DKIM signature, no trust");
    }

    #[test]
    fn the_rules_decide_where_an_answer_goes() {
        let mail = parse(RAW).unwrap();
        let facts = |member: Option<&str>, proven| RouteFacts {
            mail: mail.clone(),
            cookie_domain: "cookie.example.com".into(),
            cookie_rcpt: "me@cookie.example.com".into(),
            address: rules::parse_address("me@cookie.example.com", "cookie.example.com").unwrap(),
            member: member.map(str::to_string),
            proven,
            asked_ok: false,
        };
        assert!(matches!(rules::route(&facts(None, false)), Route::Outsider { .. }));
        assert!(matches!(rules::route(&facts(Some("you"), false)), Route::Unproven));
        let Route::Job { own, context, .. } = rules::route(&facts(Some("you"), true)) else { panic!("a proven job") };
        assert_eq!(own, "Can you pull the Q3 numbers?");
        assert!(context.contains("earlier text"), "the quoted part is context, never the job");
    }
}
