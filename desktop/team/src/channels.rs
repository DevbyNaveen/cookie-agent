//! More places to reach your team: Slack, Discord, iMessage and Signal.
//!
//! Every channel works the way Telegram does. A chat (a Slack or Discord
//! channel, an iMessage or Signal number) is linked by sending it a one-time
//! code Cookie shows; nothing from an unlinked chat reaches an agent. In a
//! linked chat, `@Name …` talks to that agent, `/use Name` switches the
//! default, `/agents` lists the team. Answers come back to the chat. What
//! needs you arrives there too, with a short code: reply `yes K7Q2` or
//! `no K7Q2` to an approval, `K7Q2 your answer` (or the choice's number) to a
//! question.
//!
//! - Slack: a bot token; Cookie polls the channels you list (no public URL).
//!   Ported from HelloRoot's Slack adapter.
//! - Discord: a bot token; Cookie keeps the gateway connection itself.
//! - iMessage: reads this Mac's Messages database (macOS asks for Full Disk
//!   Access) and sends through Messages. Best with its own Apple ID on the Mac.
//! - Signal: `signal-cli`, registered to a number of yours.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::events::TeamEvent;
use crate::store::Trigger;
use crate::{util, Team};

pub const KINDS: [&str; 4] = ["slack", "discord", "imessage", "signal"];

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct ChannelState {
    pub enabled: bool,
    /// Slack: `{"channels": ["C0123…"]}`. Signal: `{"account": "+371…"}`.
    pub config: Value,
    /// Linked chats → the agent each talks to by default.
    pub chats: BTreeMap<String, Option<String>>,
    pub pending_code: Option<String>,
    /// Where reading resumes (Slack: per-channel latest ts; iMessage: last ROWID).
    pub cursor: BTreeMap<String, String>,
    pub status: String,
}

/// One live channel connection: how to send to a chat.
#[derive(Clone)]
enum Sender {
    Slack { token: String },
    Discord { token: String },
    IMessage,
    Signal { account: String, cli: String },
    /// Needs a public address (`webhooks`): Meta and Microsoft call Cookie.
    WhatsApp { token: String, phone_id: String },
    Teams { app_id: String, password: String },
}

#[derive(Default)]
pub struct Channels {
    generation: std::sync::atomic::AtomicU64,
    senders: Mutex<HashMap<String, Sender>>,
    /// Jobs started from a chat: job → (channel, chat), to send the answer back.
    jobs: Mutex<HashMap<String, (String, String)>>,
    pub(crate) http: reqwest::Client,
}

fn short(id: &str) -> String {
    id.rsplit('-').next().unwrap_or(id).chars().take(4).collect::<String>().to_uppercase()
}

impl Team {
    fn channels_path(&self) -> std::path::PathBuf {
        self.paths.root.join("channels.json")
    }

    pub fn channel_states(&self) -> BTreeMap<String, ChannelState> {
        util::read_json(&self.channels_path())
    }

    fn save_channel(&self, kind: &str, f: impl FnOnce(&mut ChannelState)) -> Result<ChannelState, String> {
        let mut all = self.channel_states();
        let st = all.entry(kind.to_string()).or_default();
        f(st);
        let out = st.clone();
        util::write_json(&self.channels_path(), &all)?;
        Ok(out)
    }

    /// Connect a channel: check its credentials, save them, start it.
    pub async fn channel_connect(self: &Arc<Self>, kind: &str, secret: Option<String>, config: Value) -> Result<ChannelState, String> {
        let http = &self.chans.http;
        match kind {
            "slack" => {
                let token = secret.filter(|t| !t.trim().is_empty()).or_else(|| self.keys.get("channel:slack")).ok_or("Paste the bot token (it starts with xoxb-).")?;
                let token = token.trim().to_string();
                let v: Value = http.post("https://slack.com/api/auth.test").bearer_auth(&token).send().await.map_err(|e| e.to_string())?.json().await.map_err(|e| e.to_string())?;
                if v["ok"] != true {
                    return Err(format!("Slack refused the token: {}", v["error"].as_str().unwrap_or("unknown")));
                }
                let channels: Vec<String> = config["channels"].as_array().into_iter().flatten().filter_map(|c| c.as_str()).map(|c| c.trim().to_string()).filter(|c| !c.is_empty()).collect();
                if channels.is_empty() {
                    return Err("List the channel IDs Cookie should watch (in Slack: the channel's details → bottom, like C0123ABCD). Invite the bot to each.".into());
                }
                self.keys.set("channel:slack", &token)?;
                self.save_channel("slack", |s| {
                    s.enabled = true;
                    s.config = json!({"channels": channels, "bot_user": v["user_id"], "team": v["team"]});
                })?;
            }
            "discord" => {
                let token = secret.filter(|t| !t.trim().is_empty()).or_else(|| self.keys.get("channel:discord")).ok_or("Paste the bot token from the Discord Developer Portal.")?;
                let token = token.trim().to_string();
                let r = http.get("https://discord.com/api/v10/users/@me").header("Authorization", format!("Bot {token}")).send().await.map_err(|e| e.to_string())?;
                if !r.status().is_success() {
                    return Err(format!("Discord refused the token ({}).", r.status()));
                }
                let me: Value = r.json().await.map_err(|e| e.to_string())?;
                self.keys.set("channel:discord", &token)?;
                self.save_channel("discord", |s| {
                    s.enabled = true;
                    s.config = json!({"bot_user": me["id"], "bot_name": me["username"]});
                })?;
            }
            "imessage" => {
                if !cfg!(target_os = "macos") {
                    return Err("iMessage works only on a Mac.".into());
                }
                let db = imessage_db();
                let probe = tokio::process::Command::new("/usr/bin/sqlite3").args(["-readonly"]).arg(&db).arg("select max(ROWID) from message;").output().await.map_err(|e| e.to_string())?;
                if !probe.status.success() {
                    return Err("Cookie can't read Messages yet. Allow it in System Settings → Privacy & Security → Full Disk Access, then connect again.".into());
                }
                let top = String::from_utf8_lossy(&probe.stdout).trim().to_string();
                self.save_channel("imessage", |s| {
                    s.enabled = true;
                    s.cursor.insert("rowid".into(), if top.is_empty() { "0".into() } else { top });
                })?;
            }
            "signal" => {
                let cli = which("signal-cli").ok_or("Needs signal-cli on this Mac: brew install signal-cli, then register or link it to your number.")?;
                let account = config["account"].as_str().map(str::trim).filter(|a| a.starts_with('+')).ok_or("Give the number signal-cli is registered to, like +37120000000.")?.to_string();
                let out = tokio::process::Command::new(&cli).args(["-a", &account, "listIdentities"]).output().await.map_err(|e| e.to_string())?;
                if !out.status.success() {
                    return Err(format!("signal-cli can't use {account}: {}", String::from_utf8_lossy(&out.stderr).lines().last().unwrap_or("").trim()));
                }
                self.save_channel("signal", |s| {
                    s.enabled = true;
                    s.config = json!({"account": account});
                })?;
            }
            "whatsapp" | "teams" | "mail" => {
                let public = self.settings().await.server.public_url.ok_or("This needs a public address: run Cookie as a cloud runner (or a home runner behind a tunnel) and set its public URL in Settings → Runner.")?;
                let public = public.trim_end_matches('/').to_string();
                match kind {
                    "whatsapp" => {
                        let token = secret.filter(|t| !t.trim().is_empty()).or_else(|| self.keys.get("channel:whatsapp")).ok_or("Paste the WhatsApp access token (Meta for Developers → your app → WhatsApp → API setup).")?;
                        let phone_id = config["phone_id"].as_str().map(str::trim).filter(|p| !p.is_empty()).ok_or("Give the phone number ID (WhatsApp → API setup).")?.to_string();
                        let app_secret = config["app_secret"].as_str().map(str::trim).filter(|p| !p.is_empty()).map(str::to_string).or_else(|| self.keys.get("channel:whatsapp:app_secret")).ok_or("Give the app secret (App settings → Basic): Cookie checks every message is from Meta with it.")?;
                        let number = self.whatsapp_check(token.trim(), &phone_id).await?;
                        let verify = util::random_hex(12);
                        self.keys.set("channel:whatsapp", token.trim())?;
                        self.keys.set("channel:whatsapp:app_secret", &app_secret)?;
                        self.keys.set("channel:whatsapp:verify", &verify)?;
                        self.save_channel("whatsapp", |s| {
                            s.enabled = true;
                            s.config = json!({"phone_id": phone_id, "number": number["display_phone_number"], "webhook": format!("{public}/hooks/whatsapp"), "verify_token": verify});
                        })?;
                    }
                    "teams" => {
                        let password = secret.filter(|t| !t.trim().is_empty()).or_else(|| self.keys.get("channel:teams")).ok_or("Paste the bot's client secret (Azure → your bot → Configuration).")?;
                        let app_id = config["app_id"].as_str().map(str::trim).filter(|p| !p.is_empty()).ok_or("Give the bot's Microsoft App ID.")?.to_string();
                        self.teams_token(&app_id, password.trim()).await?;
                        self.keys.set("channel:teams", password.trim())?;
                        self.save_channel("teams", |s| {
                            s.enabled = true;
                            s.config = json!({"app_id": app_id, "webhook": format!("{public}/hooks/teams"), "routes": {}});
                        })?;
                    }
                    _ => {
                        let password = secret.filter(|t| !t.trim().is_empty()).or_else(|| self.keys.get("channel:mail")).ok_or("Paste the SMTP password for Cookie's address.")?;
                        let cfg: crate::mail::MailConfig = serde_json::from_value(config.clone()).map_err(|e| e.to_string())?;
                        if cfg.domain.is_empty() || cfg.local.is_empty() || cfg.smtp_host.is_empty() || cfg.smtp_user.is_empty() {
                            return Err("Give Cookie's address (local part and domain), your own addresses, and the SMTP server, user and password it sends with.".into());
                        }
                        if cfg.you.is_empty() {
                            return Err("List your own addresses: only mail from them, proven by DKIM, can give Cookie a job.".into());
                        }
                        let inbound = util::random_hex(24);
                        self.keys.set("channel:mail", password.trim())?;
                        self.keys.set("channel:mail:inbound", &inbound)?;
                        let mut c = config.clone();
                        c["webhook"] = json!(format!("{public}/hooks/mail"));
                        self.save_channel("mail", |s| {
                            s.enabled = true;
                            s.config = c;
                        })?;
                        // Shown once: the forwarder sends it with every message.
                        let mut st = self.channel_states().get("mail").cloned().unwrap_or_default();
                        st.config["inbound_secret"] = json!(inbound);
                        return Ok(st);
                    }
                }
            }
            _ => return Err("Unknown channel.".into()),
        }
        self.spawn_channels();
        self.channel_code(kind).await?;
        Ok(self.channel_states().get(kind).cloned().unwrap_or_default())
    }

    pub async fn channel_disconnect(self: &Arc<Self>, kind: &str) -> Result<(), String> {
        self.save_channel(kind, |s| *s = ChannelState::default())?;
        let _ = self.keys.remove(&format!("channel:{kind}"));
        self.spawn_channels();
        Ok(())
    }

    /// A fresh one-time code to link a chat.
    pub async fn channel_code(&self, kind: &str) -> Result<String, String> {
        let code = util::random_hex(3).to_uppercase();
        let c = code.clone();
        self.save_channel(kind, |s| s.pending_code = Some(c))?;
        Ok(code)
    }

    pub fn channel_unlink(&self, kind: &str, chat: &str) -> Result<(), String> {
        self.save_channel(kind, |s| {
            s.chats.remove(chat);
        })
        .map(|_| ())
    }

    /// Start (or restart) every enabled channel.
    pub fn spawn_channels(self: &Arc<Self>) {
        let gen = self.chans.generation.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        self.chans.senders.lock().unwrap().clear();
        for (kind, st) in self.channel_states() {
            if !st.enabled {
                continue;
            }
            let team = self.clone();
            match kind.as_str() {
                "slack" => {
                    if let Some(token) = self.keys.get("channel:slack") {
                        self.chans.senders.lock().unwrap().insert(kind.clone(), Sender::Slack { token: token.clone() });
                        tokio::spawn(async move { team.run_slack(gen, token).await });
                    }
                }
                "discord" => {
                    if let Some(token) = self.keys.get("channel:discord") {
                        self.chans.senders.lock().unwrap().insert(kind.clone(), Sender::Discord { token: token.clone() });
                        tokio::spawn(async move { team.run_discord(gen, token).await });
                    }
                }
                "imessage" => {
                    self.chans.senders.lock().unwrap().insert(kind.clone(), Sender::IMessage);
                    tokio::spawn(async move { team.run_imessage(gen).await });
                }
                "whatsapp" => {
                    if let (Some(token), Some(phone_id)) = (self.keys.get("channel:whatsapp"), st.config["phone_id"].as_str().map(str::to_string)) {
                        self.chans.senders.lock().unwrap().insert(kind.clone(), Sender::WhatsApp { token, phone_id });
                        self.set_status(&kind, "waiting for Meta to call");
                    }
                }
                "teams" => {
                    if let (Some(password), Some(app_id)) = (self.keys.get("channel:teams"), st.config["app_id"].as_str().map(str::to_string)) {
                        self.chans.senders.lock().unwrap().insert(kind.clone(), Sender::Teams { app_id, password });
                        self.set_status(&kind, "waiting for Teams to call");
                    }
                }
                "signal" => {
                    if let (Some(cli), Some(account)) = (which("signal-cli"), st.config["account"].as_str().map(str::to_string)) {
                        self.chans.senders.lock().unwrap().insert(kind.clone(), Sender::Signal { account: account.clone(), cli: cli.clone() });
                        tokio::spawn(async move { team.run_signal(gen, cli, account).await });
                    }
                }
                _ => {}
            }
        }
        if gen == 1 {
            let team = self.clone();
            tokio::spawn(async move { team.forward_to_channels().await });
        }
    }

    fn live(&self, gen: u64) -> bool {
        self.chans.generation.load(std::sync::atomic::Ordering::SeqCst) == gen
    }

    fn set_status(&self, kind: &str, status: &str) {
        let changed = self.channel_states().get(kind).is_none_or(|s| s.status != status);
        if changed {
            let _ = self.save_channel(kind, |s| s.status = status.to_string());
            self.emit(TeamEvent::Channel { name: kind.to_string(), status: status.to_string() });
        }
    }

    /// Send text to one chat on one channel (chunked to the channel's limit).
    pub(crate) async fn channel_say(&self, kind: &str, chat: &str, text: &str) {
        let Some(sender) = self.chans.senders.lock().unwrap().get(kind).cloned() else { return };
        let limit = match kind {
            "discord" => 1900,
            "slack" => 3500,
            _ => 3000,
        };
        for part in cookie_harness::cookie::channel::chunks(text, limit) {
            let r = match &sender {
                Sender::Slack { token } => self.chans.http.post("https://slack.com/api/chat.postMessage").bearer_auth(token).json(&json!({"channel": chat, "text": part})).send().await.map(|_| ()).map_err(|e| e.to_string()),
                Sender::Discord { token } => self
                    .chans
                    .http
                    .post(format!("https://discord.com/api/v10/channels/{chat}/messages"))
                    .header("Authorization", format!("Bot {token}"))
                    .json(&json!({"content": part}))
                    .send()
                    .await
                    .map(|_| ())
                    .map_err(|e| e.to_string()),
                Sender::IMessage => imessage_send(chat, &part).await,
                Sender::Signal { account, cli } => tokio::process::Command::new(cli).args(["-a", account, "send", "-m", &part, chat]).output().await.map(|_| ()).map_err(|e| e.to_string()),
                Sender::WhatsApp { token, phone_id } => self.whatsapp_send(token, phone_id, chat, &part).await,
                Sender::Teams { app_id, password } => {
                    // The service address a verified activity named for this chat.
                    let service = self.channel_states().get("teams").and_then(|s| s.config["routes"][chat].as_str().map(str::to_string)).unwrap_or_default();
                    self.teams_send(app_id, password, &service, chat, &part).await
                }
            };
            if let Err(e) = r {
                tracing::warn!("{kind}: couldn't send: {e}");
            }
        }
    }

    /// Teams: remember where to answer a chat (from a verified activity only).
    pub(crate) fn teams_route(&self, conversation: &str, service_url: &str) {
        let (c, u) = (conversation.to_string(), service_url.to_string());
        let _ = self.save_channel("teams", |s| {
            if !s.config["routes"].is_object() {
                s.config["routes"] = json!({});
            }
            s.config["routes"][c] = json!(u);
        });
    }

    /// One message arrived on a channel. Returns what to answer right away, if anything.
    pub(crate) async fn channel_inbound(self: &Arc<Self>, kind: &str, chat: &str, text: &str) -> Option<String> {
        let text = text.trim();
        if text.is_empty() {
            return None;
        }
        let st = self.channel_states().get(kind).cloned().unwrap_or_default();
        if !st.chats.contains_key(chat) {
            if st.pending_code.as_deref().is_some_and(|c| text.trim_start_matches("/start").trim().eq_ignore_ascii_case(c)) {
                let c = chat.to_string();
                let _ = self.save_channel(kind, |s| {
                    s.chats.insert(c, None);
                    s.pending_code = None;
                });
                self.emit(TeamEvent::Channel { name: kind.to_string(), status: "linked".into() });
                return Some("Linked to Cookie. Write @AgentName and what you need, or /agents to see your team.".into());
            }
            // Strangers get silence: an unlinked chat never learns anything.
            return None;
        }
        // Answers to approvals and questions, by their short code.
        let mut words = text.splitn(2, char::is_whitespace);
        let first = words.next().unwrap_or("").trim_end_matches(':');
        let rest = words.next().unwrap_or("").trim();
        if matches!(first.to_lowercase().as_str(), "yes" | "no") && rest.len() == 4 {
            let code = rest.to_uppercase();
            let target = self.pending_approvals().into_iter().find(|a| short(&a.id) == code);
            return Some(match target {
                Some(a) => match self.answer(&a.id, first.eq_ignore_ascii_case("yes"), kind) {
                    Ok(()) => if first.eq_ignore_ascii_case("yes") { "Approved.".into() } else { "Denied.".into() },
                    Err(e) => e,
                },
                None => "Nothing is waiting with that code.".into(),
            });
        }
        if first.len() == 4 && !rest.is_empty() {
            if let Some(q) = self.questions().into_iter().find(|q| short(&q.id) == first.to_uppercase()) {
                let answer = rest.parse::<usize>().ok().and_then(|n| q.choices.get(n.wrapping_sub(1)).cloned()).unwrap_or_else(|| rest.to_string());
                return Some(match self.answer_question(&q.id, &answer, kind) {
                    Ok(()) => format!("Answered: {answer}"),
                    Err(e) => e,
                });
            }
        }
        let agents = self.agents().await;
        if text == "/agents" || text == "/start" {
            let list = agents.iter().filter(|a| a.shadow_of.is_none()).map(|a| format!("@{} — {}", a.name.replace(' ', "_"), util::clip(&a.job, 80))).collect::<Vec<_>>().join("\n");
            return Some(if list.is_empty() { "You have no agents yet. Hire one in Cookie.".into() } else { list });
        }
        if let Some(name) = text.strip_prefix("/use ") {
            return Some(match self.agent_named(&name.replace('_', " ")).await {
                Some(a) => {
                    let (c, id) = (chat.to_string(), a.id.clone());
                    let _ = self.save_channel(kind, |s| {
                        s.chats.insert(c, Some(id));
                    });
                    format!("Now talking to {}.", a.name)
                }
                None => "No agent by that name. /agents lists them.".into(),
            });
        }
        let picked = crate::telegram::pick(&agents, text).or_else(|| st.chats.get(chat).cloned().flatten().and_then(|id| agents.iter().find(|a| a.id == id).map(|a| (a.clone(), text.to_string()))));
        let Some((agent, task)) = picked else {
            return Some("Who is it for? Start with @AgentName, or /use AgentName.".into());
        };
        if self.steer(&agent.id, &task) {
            return Some(format!("Added to what {} is doing.", agent.name));
        }
        match self.start_job(&agent.id, task, Vec::new(), Trigger::Channel { channel: kind.to_string(), chat: chat.to_string() }).await {
            Ok(job) => {
                self.chans.jobs.lock().unwrap().insert(job, (kind.to_string(), chat.to_string()));
                None
            }
            Err(e) => Some(e),
        }
    }

    /// Answers, approvals, questions and news go out to every linked chat.
    async fn forward_to_channels(self: Arc<Self>) {
        let mut rx = self.subscribe();
        loop {
            let ev = match rx.recv().await {
                Ok(ev) => ev,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => return,
            };
            let states = self.channel_states();
            let linked: Vec<(String, String)> = states.iter().filter(|(_, s)| s.enabled).flat_map(|(k, s)| s.chats.keys().map(move |c| (k.clone(), c.clone()))).collect();
            match ev {
                TeamEvent::JobFinished { job, answer, error, agent, .. } => {
                    self.mail_job_finished(&job, &agent, &answer).await;
                    let target = self.chans.jobs.lock().unwrap().remove(&job);
                    if let Some((kind, chat)) = target {
                        let mut text = if answer.is_empty() { error.unwrap_or_else(|| "Stopped.".into()) } else { answer };
                        // On a runner with a public address and a PIN: how it worked it out.
                        if let Some(link) = self.job_link(&agent, &job).await {
                            text.push_str(&format!("\n\n{link}"));
                        }
                        self.channel_say(&kind, &chat, &text).await;
                    }
                }
                TeamEvent::Asked { approval } => {
                    let mut text = format!("{} needs your yes:\n\n{}", approval.agent_name, util::clip(&approval.preview, 2500));
                    if let Some(c) = &approval.checker {
                        text.push_str(&format!("\n\nChecker ({}): {}", c.verdict, c.note));
                    }
                    if !approval.from_data.is_empty() {
                        text.push_str(&format!("\n\nCheck these (not from you): {}", approval.from_data.join(", ")));
                    }
                    let code = short(&approval.id);
                    text.push_str(&format!("\n\nReply  yes {code}  or  no {code}"));
                    for (k, c) in &linked {
                        self.channel_say(k, c, &text).await;
                    }
                }
                TeamEvent::Question { question } => {
                    let code = short(&question.id);
                    let mut text = format!("{} asks:\n\n{}", question.agent_name, question.question);
                    for (i, c) in question.choices.iter().enumerate() {
                        text.push_str(&format!("\n{}. {c}", i + 1));
                    }
                    text.push_str(&format!("\n\nReply  {code} <number or your answer>"));
                    for (k, c) in &linked {
                        self.channel_say(k, c, &text).await;
                    }
                }
                TeamEvent::Notice { title, body, .. } => {
                    for (k, c) in &linked {
                        self.channel_say(k, c, &format!("{title}\n{body}")).await;
                    }
                }
                _ => {}
            }
        }
    }

    /* ---------- Slack: poll the listed channels ---------- */

    async fn run_slack(self: Arc<Self>, gen: u64, token: String) {
        let mut wait = Duration::from_secs(3);
        while self.live(gen) {
            let st = self.channel_states().get("slack").cloned().unwrap_or_default();
            let channels: Vec<String> = st.config["channels"].as_array().into_iter().flatten().filter_map(|c| c.as_str().map(str::to_string)).collect();
            let bot = st.config["bot_user"].as_str().unwrap_or_default().to_string();
            let mut ok = true;
            for ch in &channels {
                let oldest = st.cursor.get(ch).cloned();
                let mut req = self.chans.http.get("https://slack.com/api/conversations.history").bearer_auth(&token).query(&[("channel", ch.as_str()), ("limit", "30")]);
                if let Some(o) = &oldest {
                    req = req.query(&[("oldest", o.as_str())]);
                }
                let v: Value = match req.send().await {
                    Ok(r) => r.json().await.unwrap_or_default(),
                    Err(_) => {
                        ok = false;
                        continue;
                    }
                };
                if v["ok"] != true {
                    ok = false;
                    self.set_status("slack", &format!("Slack: {}", v["error"].as_str().unwrap_or("error")));
                    if v["error"] == "ratelimited" {
                        wait = Duration::from_secs(20);
                    }
                    continue;
                }
                let mut msgs: Vec<Value> = v["messages"].as_array().cloned().unwrap_or_default();
                msgs.sort_by(|a, b| a["ts"].as_str().unwrap_or("").partial_cmp(b["ts"].as_str().unwrap_or("")).unwrap_or(std::cmp::Ordering::Equal));
                let newest = msgs.last().and_then(|m| m["ts"].as_str()).map(str::to_string);
                // First look at a channel: start from now, don't replay its history.
                if oldest.is_some() {
                    for m in &msgs {
                        let mine = m["bot_id"].is_string() || m["user"].as_str() == Some(bot.as_str()) || m["subtype"].is_string();
                        if !mine {
                            if let Some(reply) = self.channel_inbound("slack", ch, m["text"].as_str().unwrap_or_default()).await {
                                self.channel_say("slack", ch, &reply).await;
                            }
                        }
                    }
                }
                let next = newest.or(oldest).unwrap_or_else(|| format!("{}.000000", util::now()));
                let c = ch.clone();
                let _ = self.save_channel("slack", |s| {
                    s.cursor.insert(c, next);
                });
            }
            if ok {
                self.set_status("slack", "connected");
                wait = Duration::from_secs(if channels.len() > 3 { 6 } else { 3 });
            }
            tokio::time::sleep(wait).await;
        }
    }

    /* ---------- Discord: the gateway ---------- */

    async fn run_discord(self: Arc<Self>, gen: u64, token: String) {
        let mut backoff = 2u64;
        while self.live(gen) {
            match self.discord_session(gen, &token).await {
                Ok(()) => backoff = 2,
                Err(e) => {
                    self.set_status("discord", &format!("Discord: {e}"));
                    tokio::time::sleep(Duration::from_secs(backoff)).await;
                    backoff = (backoff * 2).min(60);
                }
            }
        }
    }

    async fn discord_session(self: &Arc<Self>, gen: u64, token: &str) -> Result<(), String> {
        let (ws, _) = tokio_tungstenite::connect_async("wss://gateway.discord.gg/?v=10&encoding=json").await.map_err(|e| e.to_string())?;
        let (mut tx, mut rx) = ws.split();
        use tokio_tungstenite::tungstenite::Message as Ws;
        let hello: Value = match rx.next().await {
            Some(Ok(Ws::Text(t))) => serde_json::from_str(&t).map_err(|e| e.to_string())?,
            _ => return Err("no hello".into()),
        };
        let every = hello["d"]["heartbeat_interval"].as_u64().unwrap_or(41_250);
        // Messages in servers and DMs, with their text (a privileged intent the bot needs switched on).
        let intents = (1 << 9) | (1 << 12) | (1 << 15);
        let identify = json!({"op": 2, "d": {"token": token, "intents": intents, "properties": {"os": std::env::consts::OS, "browser": "cookie", "device": "cookie"}}});
        tx.send(Ws::Text(identify.to_string().into())).await.map_err(|e| e.to_string())?;
        let me = self.channel_states().get("discord").and_then(|s| s.config["bot_user"].as_str().map(str::to_string)).unwrap_or_default();
        let mut seq: Value = Value::Null;
        let mut beat = tokio::time::interval(Duration::from_millis(every));
        beat.tick().await;
        loop {
            if !self.live(gen) {
                let _ = tx.close().await;
                return Ok(());
            }
            tokio::select! {
                _ = beat.tick() => {
                    tx.send(Ws::Text(json!({"op": 1, "d": seq}).to_string().into())).await.map_err(|e| e.to_string())?;
                }
                msg = rx.next() => {
                    let text = match msg {
                        Some(Ok(Ws::Text(t))) => t.to_string(),
                        Some(Ok(Ws::Close(f))) => return Err(format!("closed ({})", f.map(|f| f.reason.to_string()).unwrap_or_default())),
                        Some(Ok(_)) => continue,
                        Some(Err(e)) => return Err(e.to_string()),
                        None => return Err("connection ended".into()),
                    };
                    let v: Value = serde_json::from_str(&text).unwrap_or_default();
                    if !v["s"].is_null() { seq = v["s"].clone(); }
                    match v["op"].as_u64() {
                        Some(0) if v["t"] == "READY" => self.set_status("discord", "connected"),
                        Some(0) if v["t"] == "MESSAGE_CREATE" => {
                            let d = &v["d"];
                            if d["author"]["bot"] == true || d["author"]["id"].as_str() == Some(me.as_str()) { continue; }
                            let chat = d["channel_id"].as_str().unwrap_or_default().to_string();
                            // In a server, the bot only answers when mentioned or in a linked channel.
                            let content = d["content"].as_str().unwrap_or_default().replace(&format!("<@{me}>"), "").trim().to_string();
                            if let Some(reply) = self.channel_inbound("discord", &chat, &content).await {
                                self.channel_say("discord", &chat, &reply).await;
                            }
                        }
                        Some(1) => { tx.send(Ws::Text(json!({"op": 1, "d": seq}).to_string().into())).await.map_err(|e| e.to_string())?; }
                        Some(7) | Some(9) => return Err("Discord asked to reconnect".into()),
                        _ => {}
                    }
                }
            }
        }
    }

    /* ---------- iMessage: this Mac's Messages database ---------- */

    async fn run_imessage(self: Arc<Self>, gen: u64) {
        while self.live(gen) {
            let last: i64 = self.channel_states().get("imessage").and_then(|s| s.cursor.get("rowid").cloned()).and_then(|r| r.parse().ok()).unwrap_or(0);
            let q = format!(
                "SELECT m.ROWID AS id, m.text AS text, hex(m.attributedBody) AS body, h.id AS handle FROM message m JOIN handle h ON m.handle_id = h.ROWID \
                 WHERE m.ROWID > {last} AND m.is_from_me = 0 AND m.item_type = 0 ORDER BY m.ROWID LIMIT 50;"
            );
            let out = tokio::process::Command::new("/usr/bin/sqlite3").args(["-readonly", "-json"]).arg(imessage_db()).arg(&q).output().await;
            match out {
                Ok(o) if o.status.success() => {
                    self.set_status("imessage", "connected");
                    let rows: Vec<Value> = serde_json::from_slice(&o.stdout).unwrap_or_default();
                    let mut top = last;
                    for r in rows {
                        top = top.max(r["id"].as_i64().unwrap_or(0));
                        let text = r["text"].as_str().map(str::to_string).filter(|t| !t.trim().is_empty()).or_else(|| r["body"].as_str().and_then(attributed_text)).unwrap_or_default();
                        let handle = r["handle"].as_str().unwrap_or_default().to_string();
                        if let Some(reply) = self.channel_inbound("imessage", &handle, &text).await {
                            self.channel_say("imessage", &handle, &reply).await;
                        }
                    }
                    if top > last {
                        let _ = self.save_channel("imessage", |s| {
                            s.cursor.insert("rowid".into(), top.to_string());
                        });
                    }
                }
                _ => self.set_status("imessage", "Can't read Messages: allow Full Disk Access for Cookie"),
            }
            tokio::time::sleep(Duration::from_secs(3)).await;
        }
    }

    /* ---------- Signal: signal-cli ---------- */

    async fn run_signal(self: Arc<Self>, gen: u64, cli: String, account: String) {
        while self.live(gen) {
            let out = tokio::process::Command::new(&cli).args(["-a", &account, "-o", "json", "receive", "-t", "5"]).output().await;
            match out {
                Ok(o) if o.status.success() => {
                    self.set_status("signal", "connected");
                    for line in String::from_utf8_lossy(&o.stdout).lines() {
                        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
                        let env = &v["envelope"];
                        let from = env["sourceNumber"].as_str().or(env["source"].as_str()).unwrap_or_default().to_string();
                        let text = env["dataMessage"]["message"].as_str().unwrap_or_default().to_string();
                        if from.is_empty() || text.is_empty() {
                            continue;
                        }
                        if let Some(reply) = self.channel_inbound("signal", &from, &text).await {
                            self.channel_say("signal", &from, &reply).await;
                        }
                    }
                }
                Ok(o) => {
                    self.set_status("signal", &format!("signal-cli: {}", String::from_utf8_lossy(&o.stderr).lines().last().unwrap_or("error").trim()));
                    tokio::time::sleep(Duration::from_secs(20)).await;
                }
                Err(e) => {
                    self.set_status("signal", &format!("signal-cli: {e}"));
                    tokio::time::sleep(Duration::from_secs(20)).await;
                }
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }
}

fn which(name: &str) -> Option<String> {
    let paths = std::env::var("PATH").unwrap_or_default();
    let found = paths.split(':').chain(["/opt/homebrew/bin", "/usr/local/bin"]).map(|d| std::path::PathBuf::from(d).join(name)).find(|p| p.is_file());
    found.map(|p| p.to_string_lossy().to_string())
}

fn imessage_db() -> std::path::PathBuf {
    std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default()).join("Library/Messages/chat.db")
}

async fn imessage_send(to: &str, text: &str) -> Result<(), String> {
    let script = r#"on run argv
  set {who, msg} to argv
  tell application "Messages"
    set s to 1st account whose service type = iMessage
    send msg to participant who of s
  end tell
end run"#;
    let out = tokio::process::Command::new("/usr/bin/osascript").arg("-e").arg(script).arg(to).arg(text).output().await.map_err(|e| e.to_string())?;
    if out.status.success() { Ok(()) } else { Err(String::from_utf8_lossy(&out.stderr).trim().to_string()) }
}

/// The text inside a message's `attributedBody` (an NSAttributedString in
/// Apple's typedstream format), for messages whose `text` column is empty:
/// after the `NSString` class name comes `+`, a length, then UTF-8 bytes.
pub fn attributed_text(hex: &str) -> Option<String> {
    let bytes = cookie_net::unhex(hex)?;
    let at = bytes.windows(8).position(|w| w == b"NSString")? + 8;
    let plus = at + bytes.get(at..at + 16)?.iter().position(|&b| b == b'+')?;
    let mut i = plus + 1;
    let len = match *bytes.get(i)? {
        0x81 => {
            let n = u16::from_le_bytes([*bytes.get(i + 1)?, *bytes.get(i + 2)?]) as usize;
            i += 3;
            n
        }
        0x82 => {
            let n = u32::from_le_bytes([*bytes.get(i + 1)?, *bytes.get(i + 2)?, *bytes.get(i + 3)?, *bytes.get(i + 4)?]) as usize;
            i += 5;
            n
        }
        n => {
            i += 1;
            n as usize
        }
    };
    let text = String::from_utf8_lossy(bytes.get(i..i + len)?).to_string();
    (!text.trim().is_empty()).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blob(text: &str) -> String {
        let mut b = b"streamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString\x00\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+".to_vec();
        let t = text.as_bytes();
        if t.len() < 0x80 {
            b.push(t.len() as u8);
        } else {
            b.push(0x81);
            b.extend_from_slice(&(t.len() as u16).to_le_bytes());
        }
        b.extend_from_slice(t);
        b.extend_from_slice(b"\x86\x84\x02iI\x01");
        cookie_net::hex(&b)
    }

    #[test]
    fn attributed_bodies_decode_short_and_long_text() {
        assert_eq!(attributed_text(&blob("call Anna at ten")).as_deref(), Some("call Anna at ten"));
        let long = "x".repeat(300);
        assert_eq!(attributed_text(&blob(&long)).as_deref(), Some(long.as_str()));
        assert_eq!(attributed_text("00ff"), None);
    }

    #[tokio::test]
    async fn chats_link_with_the_code_and_strangers_get_silence() {
        let dir = tempfile::tempdir().unwrap();
        let team = crate::Team::open(dir.path()).unwrap();
        team.save_channel("slack", |s| s.enabled = true).unwrap();
        let code = team.channel_code("slack").await.unwrap();
        assert_eq!(team.channel_inbound("slack", "C1", "hello").await, None, "unlinked chats are ignored");
        assert_eq!(team.channel_inbound("slack", "C1", "WRONG1").await, None);
        assert!(team.channel_inbound("slack", "C1", &code.to_lowercase()).await.unwrap().starts_with("Linked"));
        assert!(team.channel_states()["slack"].chats.contains_key("C1"));
        assert_eq!(team.channel_inbound("slack", "C2", &code).await, None, "a code works once");
        assert!(team.channel_inbound("slack", "C1", "/agents").await.unwrap().contains("no agents"));
        assert!(team.channel_inbound("slack", "C1", "yes ZZZZ").await.unwrap().contains("Nothing is waiting"));
        assert!(team.channel_inbound("slack", "C1", "do the thing").await.unwrap().contains("Who is it for"));
    }

    #[test]
    fn short_codes_are_four_characters() {
        assert_eq!(short("ask-a1b2c3"), "A1B2");
        assert_eq!(short("q-0f9e8d"), "0F9E");
    }
}
