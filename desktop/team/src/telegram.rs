//! Telegram: your team on your phone.
//!
//! You make a bot with @BotFather and paste its token into Cookie (it goes to
//! the Keychain). Cookie shows a one-time code; you send it to your bot, and
//! that chat is linked. Only linked chats can give jobs (the harness's channel
//! rule: a message is a job only from someone who proved they are you).
//!
//! In a linked chat: `@Name what you need` (or `Name: …`) talks to that agent;
//! plain text goes to the chat's current agent (`/use Name` to switch);
//! `/agents` lists them; every yes an agent needs arrives with Approve and Deny
//! buttons, and news from routines arrives within the day's notice budget.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cookie_harness::cookie::channel;
use serde_json::{json, Value};

use crate::events::TeamEvent;
use crate::store::Trigger;
use crate::{util, Team};

const API: &str = "https://api.telegram.org";

struct Bot {
    http: reqwest::Client,
    token: String,
}

impl Bot {
    async fn call(&self, method: &str, body: Value) -> Result<Value, String> {
        let url = format!("{API}/bot{}/{method}", self.token);
        let v: Value = self.http.post(url).json(&body).send().await.map_err(|e| e.without_url().to_string())?.json().await.map_err(|e| e.without_url().to_string())?;
        if v["ok"].as_bool() == Some(true) {
            Ok(v["result"].clone())
        } else {
            Err(v["description"].as_str().unwrap_or("Telegram refused the request.").to_string())
        }
    }

    /// The bytes of a file someone sent (a voice note).
    async fn download(&self, file_id: &str) -> Result<Vec<u8>, String> {
        let f = self.call("getFile", json!({"file_id": file_id})).await?;
        let path = f["file_path"].as_str().ok_or("Telegram didn't say where the file is.")?;
        let url = format!("{API}/file/bot{}/{path}", self.token);
        let bytes = self.http.get(url).send().await.map_err(|e| e.without_url().to_string())?.bytes().await.map_err(|e| e.without_url().to_string())?;
        Ok(bytes.to_vec())
    }

    async fn say(&self, chat: &str, text: &str) {
        for part in channel::chunks(text, channel::max_chars("telegram")) {
            let _ = self.call("sendMessage", json!({"chat_id": chat, "text": part})).await;
        }
    }
}

impl Team {
    /// Save the bot token (to the Keychain), check it, and switch Telegram on.
    pub async fn telegram_connect(&self, token: &str) -> Result<String, String> {
        let bot = Bot { http: reqwest::Client::new(), token: token.trim().to_string() };
        let me = bot.call("getMe", json!({})).await.map_err(|e| format!("That token didn't work: {e}"))?;
        self.keys.set("telegram", token.trim())?;
        self.update_settings(|s| s.telegram.enabled = true).await?;
        self.emit(TeamEvent::Channel { name: "telegram".into(), status: "connected".into() });
        Ok(me["username"].as_str().map(|u| format!("@{u}")).unwrap_or_default())
    }

    pub async fn telegram_disconnect(&self) -> Result<(), String> {
        self.keys.remove("telegram")?;
        self.update_settings(|s| {
            s.telegram = Default::default();
        })
        .await?;
        self.emit(TeamEvent::Channel { name: "telegram".into(), status: "off".into() });
        Ok(())
    }

    /// A fresh one-time code to send to the bot from the chat to link.
    pub async fn telegram_code(&self) -> Result<String, String> {
        let mut bytes = [0u8; 8];
        let _ = ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes);
        let code = channel::code_from(&bytes);
        let c = code.clone();
        self.update_settings(|s| s.telegram.pending_code = Some(c)).await?;
        Ok(code)
    }
}

pub(crate) fn spawn(team: Arc<Team>) {
    let jobs: Arc<Mutex<HashMap<String, String>>> = Default::default();
    // Poller: reads messages and button presses.
    let (t, j) = (team.clone(), jobs.clone());
    tokio::spawn(async move {
        loop {
            let s = t.settings().await;
            let token = if s.telegram.enabled { t.keys.get("telegram") } else { None };
            match token {
                Some(token) => {
                    let bot = Bot { http: reqwest::Client::builder().timeout(Duration::from_secs(40)).build().unwrap_or_default(), token };
                    if let Err(e) = poll_once(&t, &bot, &j).await {
                        t.emit(TeamEvent::Channel { name: "telegram".into(), status: format!("error: {e}") });
                        tokio::time::sleep(Duration::from_secs(10)).await;
                    }
                }
                None => tokio::time::sleep(Duration::from_secs(5)).await,
            }
        }
    });
    // Forwarder: answers, approvals and news go out to linked chats.
    tokio::spawn(async move {
        let mut rx = team.subscribe();
        loop {
            let ev = match rx.recv().await {
                Ok(ev) => ev,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => return,
            };
            let s = team.settings().await;
            if !s.telegram.enabled || s.telegram.chats.is_empty() {
                continue;
            }
            let Some(token) = team.keys.get("telegram") else { continue };
            let bot = Bot { http: reqwest::Client::new(), token };
            match ev {
                TeamEvent::JobFinished { job, answer, error, .. } => {
                    let chat = jobs.lock().unwrap().remove(&job);
                    if let Some(chat) = chat {
                        let text = if answer.is_empty() { error.unwrap_or_else(|| "Stopped.".into()) } else { answer };
                        bot.say(&chat, &text).await;
                    }
                }
                TeamEvent::Asked { approval } => {
                    let mut text = format!("{} needs your yes\n\n{}", approval.agent_name, util::clip(&approval.preview, 3000));
                    if let Some(c) = &approval.checker {
                        text.push_str(&format!("\n\nChecker ({}): {}", c.verdict, c.note));
                    }
                    if !approval.from_data.is_empty() {
                        text.push_str(&format!("\n\nCheck these (not from you): {}", approval.from_data.join(", ")));
                    }
                    let keyboard = json!({"inline_keyboard": [[{"text": "Approve", "callback_data": format!("y:{}", approval.id)}, {"text": "Deny", "callback_data": format!("n:{}", approval.id)}]]});
                    for chat in s.telegram.chats.keys() {
                        let _ = bot.call("sendMessage", json!({"chat_id": chat, "text": text, "reply_markup": keyboard})).await;
                    }
                }
                TeamEvent::Question { question } => {
                    // Choices as buttons; any other answer as a reply to this message.
                    let text = format!("{} asks:\n\n{}\n\nReply to this message to answer in your own words. [{}]", question.agent_name, question.question, question.id);
                    let rows: Vec<Value> = question.choices.iter().enumerate().map(|(i, c)| json!([{"text": c, "callback_data": format!("q:{}:{i}", question.id)}])).collect();
                    for chat in s.telegram.chats.keys() {
                        let mut body = json!({"chat_id": chat, "text": text});
                        if !rows.is_empty() {
                            body["reply_markup"] = json!({"inline_keyboard": rows});
                        }
                        let _ = bot.call("sendMessage", body).await;
                    }
                }
                TeamEvent::Notice { title, body, .. } => {
                    for chat in s.telegram.chats.keys() {
                        bot.say(chat, &format!("{title}\n{body}")).await;
                    }
                }
                _ => {}
            }
        }
    });
}

async fn poll_once(team: &Arc<Team>, bot: &Bot, jobs: &Arc<Mutex<HashMap<String, String>>>) -> Result<(), String> {
    let offset = team.settings().await.telegram.offset;
    let updates = bot.call("getUpdates", json!({"offset": offset, "timeout": 25, "allowed_updates": ["message", "callback_query"]})).await?;
    for u in updates.as_array().cloned().unwrap_or_default() {
        let id = u["update_id"].as_i64().unwrap_or(0);
        team.update_settings(|s| s.telegram.offset = id + 1).await?;
        if let Some(cb) = u.get("callback_query") {
            handle_button(team, bot, cb).await;
        } else if let Some(m) = u.get("message") {
            handle_message(team, bot, m, jobs).await;
        }
    }
    Ok(())
}

async fn handle_button(team: &Arc<Team>, bot: &Bot, cb: &Value) {
    let chat = cb["message"]["chat"]["id"].to_string();
    let linked = team.settings().await.telegram.chats.contains_key(&chat);
    let data = cb["data"].as_str().unwrap_or_default();
    let reply = if !linked {
        "This chat isn't linked.".to_string()
    } else if let Some(rest) = data.strip_prefix("q:") {
        let (id, i) = rest.rsplit_once(':').unwrap_or((rest, ""));
        let choice = team.questions().into_iter().find(|q| q.id == id).and_then(|q| q.choices.get(i.parse::<usize>().unwrap_or(usize::MAX)).cloned());
        match choice {
            Some(c) => match team.answer_question(id, &c, "telegram") {
                Ok(()) => format!("Answered: {c}"),
                Err(e) => e,
            },
            None => "That question was already answered.".into(),
        }
    } else if let Some((yes, id)) = data.split_once(':') {
        match team.answer(id, yes == "y", "telegram") {
            Ok(()) => if yes == "y" { "Approved." } else { "Denied." }.to_string(),
            Err(e) => e,
        }
    } else {
        "Unknown button.".into()
    };
    let _ = bot.call("answerCallbackQuery", json!({"callback_query_id": cb["id"], "text": reply})).await;
    let _ = bot
        .call("editMessageReplyMarkup", json!({"chat_id": chat, "message_id": cb["message"]["message_id"], "reply_markup": {"inline_keyboard": []}}))
        .await;
    let _ = bot.say(&chat, &reply).await;
}

async fn handle_message(team: &Arc<Team>, bot: &Bot, m: &Value, jobs: &Arc<Mutex<HashMap<String, String>>>) {
    let chat = m["chat"]["id"].to_string();
    let mut text = m["text"].as_str().or(m["caption"].as_str()).unwrap_or_default().trim().to_string();
    // A voice note: transcribe it, show what was heard, and carry on as text.
    let voice = m["voice"]["file_id"].as_str().or(m["audio"]["file_id"].as_str());
    if text.is_empty() {
        if let Some(file) = voice {
            if !team.settings().await.telegram.chats.contains_key(&chat) {
                return;
            }
            match bot.download(file).await {
                Ok(bytes) => match team.transcribe(&bytes, "ogg").await {
                    Ok(heard) => {
                        bot.say(&chat, &format!("Heard: {heard}")).await;
                        text = heard;
                    }
                    Err(e) => {
                        bot.say(&chat, &e).await;
                        return;
                    }
                },
                Err(e) => {
                    bot.say(&chat, &format!("Couldn't get the voice note: {e}")).await;
                    return;
                }
            }
        }
    }
    if text.is_empty() {
        return;
    }
    let s = team.settings().await;
    // A reply to an agent's question answers it.
    if s.telegram.chats.contains_key(&chat) {
        let replied = m["reply_to_message"]["text"].as_str().unwrap_or_default();
        if let Some(id) = replied.rsplit_once('[').and_then(|(_, t)| t.strip_suffix(']')).filter(|t| t.starts_with("q-")) {
            let reply = match team.answer_question(id, &text, "telegram") {
                Ok(()) => "Answered.".to_string(),
                Err(e) => e,
            };
            bot.say(&chat, &reply).await;
            return;
        }
    }
    if !s.telegram.chats.contains_key(&chat) {
        let sent = text.trim_start_matches("/start").trim();
        if s.telegram.pending_code.as_deref().is_some_and(|c| c.eq_ignore_ascii_case(sent)) {
            let c = chat.clone();
            let _ = team
                .update_settings(|s| {
                    s.telegram.chats.insert(c, None);
                    s.telegram.pending_code = None;
                })
                .await;
            team.emit(TeamEvent::Channel { name: "telegram".into(), status: "linked".into() });
            bot.say(&chat, "Linked. Write @AgentName and what you need, or /agents to see your team.").await;
        } else {
            bot.say(&chat, "This chat isn't linked to Cookie. Send the code Cookie shows in Settings → Channels.").await;
        }
        return;
    }
    let agents = team.agents().await;
    if text == "/agents" || text == "/start" {
        let list = agents.iter().filter(|a| a.shadow_of.is_none()).map(|a| format!("@{} — {}", a.name.replace(' ', "_"), util::clip(&a.job, 80))).collect::<Vec<_>>().join("\n");
        bot.say(&chat, if list.is_empty() { "You have no agents yet. Hire one in Cookie." } else { &list }).await;
        return;
    }
    if let Some(name) = text.strip_prefix("/use ") {
        match team.agent_named(&name.replace('_', " ")).await {
            Some(a) => {
                let (c, id) = (chat.clone(), a.id.clone());
                let _ = team.update_settings(|s| { s.telegram.chats.insert(c, Some(id)); }).await;
                bot.say(&chat, &format!("Now talking to {}.", a.name)).await;
            }
            None => bot.say(&chat, "No agent by that name. /agents lists them.").await,
        }
        return;
    }
    // "@Name rest" or "Name: rest" picks the agent; else the chat's current one.
    let (agent, task) = pick(&agents, &text).or_else(|| s.telegram.chats.get(&chat).cloned().flatten().and_then(|id| agents.iter().find(|a| a.id == id).map(|a| (a.clone(), text.clone())))).unzip();
    let (Some(agent), Some(task)) = (agent, task) else {
        bot.say(&chat, "Who is it for? Start with @AgentName, or /use AgentName.").await;
        return;
    };
    if team.steer(&agent.id, &task) {
        bot.say(&chat, &format!("Added to what {} is doing.", agent.name)).await;
        return;
    }
    match team.start_job(&agent.id, task, Vec::new(), Trigger::Telegram { chat: chat.clone() }).await {
        Ok(job) => {
            jobs.lock().unwrap().insert(job, chat.clone());
            let _ = bot.call("sendChatAction", json!({"chat_id": chat, "action": "typing"})).await;
        }
        Err(e) => bot.say(&chat, &e).await,
    }
}

pub(crate) fn pick(agents: &[crate::AgentRecord], text: &str) -> Option<(crate::AgentRecord, String)> {
    let lower = text.to_lowercase();
    let mut best: Option<(crate::AgentRecord, String)> = None;
    for a in agents.iter().filter(|a| a.shadow_of.is_none()) {
        let n = a.name.to_lowercase();
        for prefix in [format!("@{}", n.replace(' ', "_")), format!("@{n}"), format!("{n}:")] {
            if lower.starts_with(&prefix) {
                let rest = text[prefix.len()..].trim_start_matches([':', ',', ' ']).trim().to_string();
                if best.as_ref().is_none_or(|(b, _)| b.name.len() < a.name.len()) {
                    best = Some((a.clone(), rest));
                }
            }
        }
    }
    best.filter(|(_, rest)| !rest.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(name: &str) -> crate::AgentRecord {
        crate::AgentRecord {
            id: name.to_lowercase(), name: name.into(), model: "m:x".into(), job: "j".into(), created_at: 0, grants: Default::default(),
            limits: Default::default(), probation_until: None, parent: None, shadow_of: None, handover: None, origin: None, version: 1,
        }
    }

    #[test]
    fn picks_the_named_agent_longest_name_first() {
        let team = [a("Sales"), a("Sales Desk")];
        assert_eq!(pick(&team, "@Sales_Desk quote Acme").map(|(x, r)| (x.name, r)), Some(("Sales Desk".into(), "quote Acme".into())));
        assert_eq!(pick(&team, "sales: hi").map(|(x, r)| (x.name, r)), Some(("Sales".into(), "hi".into())));
        assert!(pick(&team, "hello").is_none());
        assert!(pick(&team, "@Sales").is_none());
    }
}
