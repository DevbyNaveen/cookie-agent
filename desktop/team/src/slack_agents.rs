//! Each agent, itself in Slack.
//!
//! Two ways, chosen in the agent's profile:
//!
//! - **Its voice in your team's Slack.** The one Slack bot the team already
//!   uses (Settings → Channels) posts this agent's answers under its own name
//!   and icon, so a channel reads like a team, not one bot. Needs the bot's
//!   `chat:write.customize` scope; without it Slack posts as the bot.
//! - **Its own Slack account.** Cookie makes a Slack app for the agent from a
//!   manifest (Slack's `apps.manifest.create`, with an App Configuration Token
//!   you generate once), named and coloured as the agent. You install it to
//!   your workspace and paste its bot token here. From then on it is a member
//!   of your Slack: DM it, @mention it in a channel it was added to, and it
//!   answers there, as itself, in the thread.
//!
//! Who may give it work: nobody, until linked. Its profile shows a one-time
//! code; the person who DMs it that code is linked (you decide who sees the
//! code). Everyone else gets silence, and nothing runs. What it needs your yes
//! for, or asks, goes to its linked people by DM with a short code, the same
//! as every channel.
//!
//! Safeguards (Hermes's lessons): one bot token is one agent, never shared
//! with another agent or the team bot; an agent never answers a bot (two
//! agents can't talk each other into a loop); and Slack can start at most
//! [`JOBS_PER_HOUR`] jobs an hour per agent.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::events::TeamEvent;
use crate::store::Trigger;
use crate::{util, Team};

const SLACK: &str = "https://slack.com/api";
/// Jobs Slack may start for one agent in an hour.
pub const JOBS_PER_HOUR: usize = 30;
const CONFIG_KEY: &str = "slack:config";
const CONFIG_REFRESH_KEY: &str = "slack:config:refresh";
/// What an agent's own app asks Slack for: read and answer its DMs and the
/// channels it's in, mention-only there; see who wrote; put eyes on a message.
const BOT_SCOPES: [&str; 13] = [
    "app_mentions:read", "chat:write", "im:history", "im:read", "im:write", "mpim:history", "mpim:read",
    "channels:history", "channels:read", "groups:history", "groups:read", "users:read", "reactions:write",
];

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct AgentSlack {
    /// In the team's Slack, its answers post under its own name and icon.
    pub voice: bool,
    /// Its icon there, a Slack emoji like `:robot_face:`.
    pub emoji: String,
    /// Its own Slack app, made by Cookie.
    pub app_id: Option<String>,
    pub bot_user: Option<String>,
    pub bot_name: Option<String>,
    pub team: Option<String>,
    /// Slack user id → name: who may give it work.
    pub people: BTreeMap<String, String>,
    pub pending_code: Option<String>,
    /// Per conversation: where reading resumes.
    pub cursor: BTreeMap<String, String>,
    pub status: String,
}

/// Live pollers by agent (a generation each, so a restart stops the old one),
/// jobs Slack started (job → agent, conversation, thread), and Slack's recent starts.
#[derive(Default)]
struct Live {
    generation: HashMap<String, u64>,
    jobs: HashMap<String, (String, String, Option<String>)>,
    starts: HashMap<String, Vec<u64>>,
    forwarding: bool,
}
static LIVE: LazyLock<Mutex<Live>> = LazyLock::new(|| Mutex::new(Live::default()));

fn http() -> &'static reqwest::Client {
    static C: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    C.get_or_init(|| reqwest::Client::builder().timeout(Duration::from_secs(20)).build().unwrap_or_default())
}

fn token_key(agent: &str) -> String {
    format!("slack:agent:{agent}")
}

/// A Slack Web API call with a token: the JSON answer, or Slack's error in words.
async fn call(method: &str, token: &str, body: Value) -> Result<Value, String> {
    let v: Value = http().post(format!("{SLACK}/{method}")).bearer_auth(token).json(&body).send().await.map_err(|e| e.to_string())?.json().await.map_err(|e| e.to_string())?;
    if v["ok"] == true { Ok(v) } else { Err(slack_error(&v)) }
}

/// Some methods take form fields only (or read query parameters best that way).
async fn call_form(method: &str, token: &str, form: &[(&str, &str)]) -> Result<Value, String> {
    let v: Value = http().post(format!("{SLACK}/{method}")).bearer_auth(token).form(form).send().await.map_err(|e| e.to_string())?.json().await.map_err(|e| e.to_string())?;
    if v["ok"] == true { Ok(v) } else { Err(slack_error(&v)) }
}

fn slack_error(v: &Value) -> String {
    let e = v["error"].as_str().unwrap_or("unknown error");
    match e {
        "invalid_auth" | "not_authed" | "token_revoked" | "account_inactive" => "Slack didn't accept that token.".into(),
        "token_expired" => "That App Configuration Token has expired (they last 12 hours). Generate a new one.".into(),
        "missing_scope" => format!("The token is missing a permission Slack needs: {}.", v["needed"].as_str().unwrap_or("see Slack")),
        "ratelimited" => "Slack asked Cookie to slow down. Try again in a minute.".into(),
        "invalid_manifest" => format!("Slack refused the app's manifest: {}", v["errors"]),
        _ => format!("Slack said: {e}"),
    }
}

/// The emoji an agent uses in the team's Slack, from its shape (the UI knows the shape).
pub fn emoji_for(shape: &str) -> &'static str {
    match shape {
        "bot" => ":robot_face:",
        "orb" => ":ringed_planet:",
        "crystal" => ":gem:",
        "wisp" => ":fire:",
        "cloud" => ":cloud:",
        "star" => ":star2:",
        "ghost" => ":ghost:",
        "macaron" => ":hamburger:",
        "biscuit" => ":cookie:",
        "bun" => ":bread:",
        "mochi" => ":rice_ball:",
        _ => ":candy:",
    }
}

/// The manifest for an agent's own app: its name, its job, its colour.
pub fn manifest(name: &str, job: &str, color: &str) -> Value {
    let name: String = name.chars().filter(|c| !c.is_control()).take(35).collect();
    let mut about: String = job.chars().filter(|c| !c.is_control()).take(130).collect();
    if about.chars().count() < 10 {
        about = format!("{name}, an agent on your Cookie team.");
    }
    let color = if color.len() == 7 && color.starts_with('#') && color[1..].chars().all(|c| c.is_ascii_hexdigit()) { color.to_string() } else { "#4a154b".into() };
    json!({
        "display_information": {
            "name": name,
            "description": about,
            "long_description": format!("{name} is an AI agent on a Cookie team (cookie.enkeon.com). It answers the people who linked it from their Cookie app, in DMs and in channels it was added to when they @mention it. It never acts for anyone else. Approvals for anything it does that matters go to the person who owns it.\n\nIts job: {about}"),
            "background_color": color,
        },
        "features": {
            "app_home": { "home_tab_enabled": false, "messages_tab_enabled": true, "messages_tab_read_only_enabled": false },
            "bot_user": { "display_name": name, "always_online": true },
        },
        "oauth_config": { "scopes": { "bot": BOT_SCOPES } },
        "settings": { "org_deploy_enabled": false, "socket_mode_enabled": false, "token_rotation_enabled": false },
    })
}

/// A message an agent's own bot should take as work: not a bot's (no loops), not
/// an edit or a join, and in a channel only when it is @mentioned. The text, cleaned.
pub fn work_in(msg: &Value, bot_user: &str, is_dm: bool) -> Option<String> {
    if msg["bot_id"].is_string() || msg["subtype"].is_string() || msg["user"].as_str().is_none_or(|u| u == bot_user) {
        return None;
    }
    let text = msg["text"].as_str().unwrap_or_default();
    let tag = format!("<@{bot_user}>");
    if !is_dm && !text.contains(&tag) {
        return None;
    }
    let clean = text.replace(&tag, " ");
    let clean = clean.split_whitespace().collect::<Vec<_>>().join(" ");
    (!clean.is_empty()).then_some(clean)
}

impl Team {
    fn agent_slack_path(&self) -> std::path::PathBuf {
        self.paths.root.join("agent-slack.json")
    }

    pub fn agent_slacks(&self) -> BTreeMap<String, AgentSlack> {
        util::read_json(&self.agent_slack_path())
    }

    pub fn agent_slack_of(&self, agent: &str) -> AgentSlack {
        self.agent_slacks().remove(agent).unwrap_or_default()
    }

    fn save_agent_slack(&self, agent: &str, f: impl FnOnce(&mut AgentSlack)) -> Result<AgentSlack, String> {
        let mut all = self.agent_slacks();
        let st = all.entry(agent.to_string()).or_default();
        f(st);
        let out = st.clone();
        util::write_json(&self.agent_slack_path(), &all)?;
        Ok(out)
    }

    /// Everything the profile's Slack section shows.
    pub async fn agent_slack(&self, agent: &str) -> Result<Value, String> {
        self.agent(agent).await?;
        let st = self.agent_slack_of(agent);
        let team = self.channel_states().get("slack").filter(|s| s.enabled).map(|s| json!({"team": s.config["team"], "status": s.status}));
        Ok(json!({
            "state": st,
            "own": self.keys.get(&token_key(agent)).is_some(),
            "team_slack": team,
            "config_token": self.keys.get(CONFIG_KEY).is_some(),
            "install_url": st.app_id.as_ref().map(|a| format!("https://api.slack.com/apps/{a}/install-on-team")),
            "app_url": st.app_id.as_ref().map(|a| format!("https://api.slack.com/apps/{a}/general")),
            "jobs_per_hour": JOBS_PER_HOUR,
        }))
    }

    /// Its voice in the team's Slack: on or off, and its icon (from its shape).
    pub async fn agent_slack_voice(&self, agent: &str, on: bool, shape: &str) -> Result<Value, String> {
        self.agent(agent).await?;
        self.save_agent_slack(agent, |s| {
            s.voice = on;
            s.emoji = emoji_for(shape).into();
        })?;
        self.agent_slack(agent).await
    }

    /// Keep the App Configuration Token (and its refresh token) that lets Cookie make apps.
    pub async fn slack_config_token(&self, token: &str, refresh: Option<&str>) -> Result<(), String> {
        let token = token.trim();
        if !token.starts_with("xoxe") {
            return Err("That isn't an App Configuration Token: generate one at api.slack.com/apps → \"Your App Configuration Tokens\" (it starts with xoxe).".into());
        }
        // Slack's cheapest check of a configuration token: validating an empty-ish manifest.
        let probe = call("apps.manifest.validate", token, json!({"manifest": manifest("Cookie check", "Checks the token can make apps.", "#000000").to_string()})).await;
        if let Err(e) = probe {
            if !e.contains("manifest") {
                return Err(e);
            }
        }
        self.keys.set(CONFIG_KEY, token)?;
        match refresh.map(str::trim).filter(|r| !r.is_empty()) {
            Some(r) => self.keys.set(CONFIG_REFRESH_KEY, r)?,
            None => {
                let _ = self.keys.remove(CONFIG_REFRESH_KEY);
            }
        }
        Ok(())
    }

    /// A working configuration token: rotated with its refresh token when there is one
    /// (configuration tokens last 12 hours; a refresh token makes a new pair).
    async fn config_token(&self) -> Result<String, String> {
        if let Some(refresh) = self.keys.get(CONFIG_REFRESH_KEY) {
            let v: Value = http().post(format!("{SLACK}/tooling.tokens.rotate")).form(&[("refresh_token", refresh.as_str())]).send().await.map_err(|e| e.to_string())?.json().await.map_err(|e| e.to_string())?;
            if v["ok"] == true {
                if let (Some(t), Some(r)) = (v["token"].as_str(), v["refresh_token"].as_str()) {
                    self.keys.set(CONFIG_KEY, t)?;
                    self.keys.set(CONFIG_REFRESH_KEY, r)?;
                    return Ok(t.to_string());
                }
            }
        }
        self.keys.get(CONFIG_KEY).ok_or_else(|| "Cookie needs an App Configuration Token to make Slack apps (api.slack.com/apps → \"Your App Configuration Tokens\" → Generate).".into())
    }

    /// Make the agent's own Slack app. Returns where to install it.
    pub async fn agent_slack_create(&self, agent: &str, color: &str) -> Result<Value, String> {
        let rec = self.agent(agent).await?;
        if let Some(app) = self.agent_slack_of(agent).app_id {
            return Ok(json!({"app_id": app, "install_url": format!("https://api.slack.com/apps/{app}/install-on-team")}));
        }
        let token = self.config_token().await?;
        let v = call("apps.manifest.create", &token, json!({"manifest": manifest(&rec.name, &rec.job, color).to_string()})).await?;
        let app = v["app_id"].as_str().ok_or("Slack made the app but didn't say its id.")?.to_string();
        let a = app.clone();
        self.save_agent_slack(agent, |s| {
            s.app_id = Some(a);
            s.status = "made; install it to your workspace".into();
        })?;
        Ok(json!({"app_id": app, "install_url": format!("https://api.slack.com/apps/{app}/install-on-team"), "app_url": format!("https://api.slack.com/apps/{app}/general")}))
    }

    /// The installed app's bot token: checked, kept in the Keychain, and the agent goes live.
    pub async fn agent_slack_token(self: &Arc<Self>, agent: &str, token: &str) -> Result<Value, String> {
        self.agent(agent).await?;
        let token = token.trim();
        if !token.starts_with("xoxb-") {
            return Err("Paste the Bot User OAuth Token from the app's OAuth & Permissions page (it starts with xoxb-).".into());
        }
        let me = call("auth.test", token, json!({})).await?;
        let bot = me["user_id"].as_str().ok_or("Slack didn't say who the bot is.")?.to_string();
        // One token, one agent: never the team's bot, never another agent's.
        let team_bot = self.channel_states().get("slack").and_then(|s| s.config["bot_user"].as_str().map(str::to_string));
        if team_bot.as_deref() == Some(bot.as_str()) {
            return Err("That's your team's Slack bot (Settings → Channels). Each agent needs its own app.".into());
        }
        if let Some((other, _)) = self.agent_slacks().into_iter().find(|(id, s)| id != agent && s.bot_user.as_deref() == Some(bot.as_str())) {
            let name = self.agent(&other).await.map(|a| a.name).unwrap_or(other);
            return Err(format!("That bot already belongs to {name}. Each agent needs its own app."));
        }
        self.keys.set(&token_key(agent), token)?;
        let code = util::random_hex(3).to_uppercase();
        let (b, team, name, c) = (bot.clone(), me["team"].as_str().map(str::to_string), me["user"].as_str().map(str::to_string), code.clone());
        self.save_agent_slack(agent, |s| {
            s.bot_user = Some(b);
            s.team = team;
            s.bot_name = name;
            s.cursor.clear();
            s.pending_code = Some(c);
            s.status = "connected".into();
        })?;
        self.spawn_agent_slack(agent);
        self.agent_slack(agent).await
    }

    /// A fresh one-time code: whoever DMs it to the agent may give it work.
    pub async fn agent_slack_code(&self, agent: &str) -> Result<String, String> {
        self.agent(agent).await?;
        let code = util::random_hex(3).to_uppercase();
        let c = code.clone();
        self.save_agent_slack(agent, |s| s.pending_code = Some(c))?;
        Ok(code)
    }

    pub async fn agent_slack_unlink(&self, agent: &str, user: &str) -> Result<Value, String> {
        self.save_agent_slack(agent, |s| {
            s.people.remove(user);
        })?;
        self.agent_slack(agent).await
    }

    /// Take the agent out of Slack: its token forgotten here, and its app deleted
    /// in Slack when Cookie still can (with the configuration token).
    pub async fn agent_slack_disconnect(&self, agent: &str) -> Result<Value, String> {
        let st = self.agent_slack_of(agent);
        let _ = self.keys.remove(&token_key(agent));
        LIVE.lock().unwrap().generation.entry(agent.to_string()).and_modify(|g| *g += 1);
        let mut note = "Disconnected.".to_string();
        if let Some(app) = &st.app_id {
            match self.config_token().await {
                Ok(t) => match call("apps.manifest.delete", &t, json!({"app_id": app})).await {
                    Ok(_) => note = "Disconnected, and its Slack app is deleted.".into(),
                    Err(e) => note = format!("Disconnected. Delete its app in Slack yourself (api.slack.com/apps): {e}"),
                },
                Err(_) => note = "Disconnected. Its Slack app still exists: delete it at api.slack.com/apps.".into(),
            }
        }
        let voice = st.voice;
        let emoji = st.emoji.clone();
        self.save_agent_slack(agent, |s| *s = AgentSlack { voice, emoji, ..AgentSlack::default() })?;
        let mut out = self.agent_slack(agent).await?;
        out["note"] = json!(note);
        Ok(out)
    }

    /// Start every agent that has its own Slack (at launch).
    pub fn spawn_agent_slacks(self: &Arc<Self>) {
        for (agent, _) in self.agent_slacks() {
            if self.keys.get(&token_key(&agent)).is_some() {
                self.spawn_agent_slack(&agent);
            }
        }
    }

    fn spawn_agent_slack(self: &Arc<Self>, agent: &str) {
        let Some(token) = self.keys.get(&token_key(agent)) else { return };
        let gen = {
            let mut live = LIVE.lock().unwrap();
            let g = live.generation.entry(agent.to_string()).or_insert(0);
            *g += 1;
            let g = *g;
            if !live.forwarding {
                live.forwarding = true;
                let team = self.clone();
                tokio::spawn(async move { team.forward_agent_slack().await });
            }
            g
        };
        let (team, a) = (self.clone(), agent.to_string());
        tokio::spawn(async move { team.run_agent_slack(a, gen, token).await });
    }

    fn agent_slack_live(agent: &str, gen: u64) -> bool {
        LIVE.lock().unwrap().generation.get(agent) == Some(&gen)
    }

    fn agent_slack_status(&self, agent: &str, status: &str) {
        if self.agent_slack_of(agent).status != status {
            let _ = self.save_agent_slack(agent, |s| s.status = status.into());
            self.emit(TeamEvent::Channel { name: format!("slack:{agent}"), status: status.into() });
        }
    }

    /// Poll the agent's DMs and the channels it's in; take work from linked people.
    async fn run_agent_slack(self: Arc<Self>, agent: String, gen: u64, token: String) {
        let mut convs: Vec<String> = Vec::new();
        let mut listed_at = 0u64;
        let mut wait = Duration::from_secs(4);
        while Self::agent_slack_live(&agent, gen) {
            if self.agent(&agent).await.is_err() {
                return; // fired
            }
            if util::now() - listed_at > 60 {
                match call_form("users.conversations", &token, &[("types", "im,mpim,public_channel,private_channel"), ("exclude_archived", "true"), ("limit", "200")]).await {
                    Ok(v) => {
                        convs = v["channels"].as_array().into_iter().flatten().filter_map(|c| c["id"].as_str().map(str::to_string)).collect();
                        listed_at = util::now();
                    }
                    Err(e) => {
                        self.agent_slack_status(&agent, &e);
                        tokio::time::sleep(Duration::from_secs(30)).await;
                        continue;
                    }
                }
            }
            let st = self.agent_slack_of(&agent);
            let bot = st.bot_user.clone().unwrap_or_default();
            let mut ok = true;
            for conv in &convs {
                let oldest = st.cursor.get(conv).cloned();
                let mut form = vec![("channel", conv.as_str()), ("limit", "20")];
                if let Some(o) = &oldest {
                    form.push(("oldest", o.as_str()));
                }
                let v = match call_form("conversations.history", &token, &form).await {
                    Ok(v) => v,
                    Err(e) => {
                        ok = false;
                        if e.contains("slow down") {
                            wait = Duration::from_secs(20);
                        }
                        continue;
                    }
                };
                let mut msgs: Vec<Value> = v["messages"].as_array().cloned().unwrap_or_default();
                msgs.sort_by(|a, b| a["ts"].as_str().unwrap_or("").partial_cmp(b["ts"].as_str().unwrap_or("")).unwrap_or(std::cmp::Ordering::Equal));
                let newest = msgs.last().and_then(|m| m["ts"].as_str()).map(str::to_string);
                // First look at a conversation: start from now, never replay its history.
                if oldest.is_some() {
                    for m in &msgs {
                        let is_dm = conv.starts_with('D');
                        if let Some(text) = work_in(m, &bot, is_dm) {
                            let user = m["user"].as_str().unwrap_or_default().to_string();
                            let thread = if is_dm { None } else { m["thread_ts"].as_str().or(m["ts"].as_str()).map(str::to_string) };
                            self.agent_slack_inbound(&agent, &token, conv, thread, m["ts"].as_str().unwrap_or_default(), &user, &text, is_dm).await;
                        }
                    }
                }
                let next = newest.or(oldest).unwrap_or_else(|| format!("{}.000000", util::now()));
                let c = conv.clone();
                let _ = self.save_agent_slack(&agent, |s| {
                    s.cursor.insert(c, next);
                });
            }
            if ok {
                self.agent_slack_status(&agent, "connected");
                wait = Duration::from_secs(if convs.len() > 6 { 8 } else { 4 });
            }
            tokio::time::sleep(wait).await;
        }
    }

    #[allow(clippy::too_many_arguments)]
    async fn agent_slack_inbound(self: &Arc<Self>, agent: &str, token: &str, conv: &str, thread: Option<String>, ts: &str, user: &str, text: &str, is_dm: bool) {
        let st = self.agent_slack_of(agent);
        let say = |t: String| {
            let (token, conv, thread) = (token.to_string(), conv.to_string(), thread.clone());
            async move { post(&token, &conv, thread.as_deref(), &t).await }
        };
        if !st.people.contains_key(user) {
            // Only a DM with the code links someone. Everyone else: silence, and nothing runs.
            if is_dm && st.pending_code.as_deref().is_some_and(|c| text.trim().eq_ignore_ascii_case(c)) {
                let name = call_form("users.info", token, &[("user", user)]).await.ok().and_then(|v| v["user"]["real_name"].as_str().or(v["user"]["name"].as_str()).map(str::to_string)).unwrap_or_else(|| user.to_string());
                let (u, n) = (user.to_string(), name.clone());
                let _ = self.save_agent_slack(agent, |s| {
                    s.people.insert(u, n);
                    s.pending_code = None;
                });
                self.emit(TeamEvent::Channel { name: format!("slack:{agent}"), status: "linked".into() });
                let me = self.agent(agent).await.map(|a| a.name).unwrap_or_default();
                say(format!("Hi {name}, I'm {me}. Tell me what you need, here or by @mentioning me in a channel I'm in.")).await;
            }
            return;
        }
        // Answers to its approvals and questions, by their short code.
        let mut words = text.splitn(2, char::is_whitespace);
        let first = words.next().unwrap_or("").trim_end_matches(':');
        let rest = words.next().unwrap_or("").trim();
        if matches!(first.to_lowercase().as_str(), "yes" | "no") && rest.len() == 4 {
            let code = rest.to_uppercase();
            let reply = match self.pending_approvals().into_iter().find(|a| a.agent == agent && crate::channels::short(&a.id) == code) {
                Some(a) => match self.answer(&a.id, first.eq_ignore_ascii_case("yes"), "slack") {
                    Ok(()) => if first.eq_ignore_ascii_case("yes") { "Approved.".to_string() } else { "Denied.".to_string() },
                    Err(e) => e,
                },
                None => "Nothing of mine is waiting with that code.".into(),
            };
            say(reply).await;
            return;
        }
        if first.len() == 4 && !rest.is_empty() {
            if let Some(q) = self.questions().into_iter().find(|q| q.agent == agent && crate::channels::short(&q.id) == first.to_uppercase()) {
                let answer = rest.parse::<usize>().ok().and_then(|n| q.choices.get(n.wrapping_sub(1)).cloned()).unwrap_or_else(|| rest.to_string());
                let reply = match self.answer_question(&q.id, &answer, "slack") {
                    Ok(()) => format!("Got it: {answer}"),
                    Err(e) => e,
                };
                say(reply).await;
                return;
            }
        }
        if self.steer(agent, text) {
            say("Added to what I'm doing.".into()).await;
            return;
        }
        // At most JOBS_PER_HOUR from Slack an hour.
        let now = util::now();
        let allowed = {
            let mut live = LIVE.lock().unwrap();
            let starts = live.starts.entry(agent.to_string()).or_default();
            starts.retain(|t| now - *t < 3600);
            if starts.len() >= JOBS_PER_HOUR {
                false
            } else {
                starts.push(now);
                true
            }
        };
        if !allowed {
            say(format!("I've taken {JOBS_PER_HOUR} jobs from Slack this hour, so I'm pausing new ones for a bit. Ask in Cookie if it's urgent.")).await;
            return;
        }
        let _ = call("reactions.add", token, json!({"channel": conv, "timestamp": ts, "name": "eyes"})).await;
        match self.start_job(agent, text.to_string(), Vec::new(), Trigger::Channel { channel: "slack".into(), chat: conv.to_string() }).await {
            Ok(job) => {
                LIVE.lock().unwrap().jobs.insert(job, (agent.to_string(), conv.to_string(), thread));
            }
            Err(e) => say(e).await,
        }
    }

    /// Answers go back where they were asked; approvals and questions to linked people by DM.
    async fn forward_agent_slack(self: Arc<Self>) {
        let mut rx = self.subscribe();
        loop {
            let ev = match rx.recv().await {
                Ok(ev) => ev,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => return,
            };
            match ev {
                TeamEvent::JobFinished { job, answer, error, .. } => {
                    let target = LIVE.lock().unwrap().jobs.remove(&job);
                    if let Some((agent, conv, thread)) = target {
                        if let Some(token) = self.keys.get(&token_key(&agent)) {
                            let text = if answer.is_empty() { error.unwrap_or_else(|| "Stopped.".into()) } else { answer };
                            post(&token, &conv, thread.as_deref(), &text).await;
                        }
                    }
                }
                TeamEvent::Asked { approval } => {
                    let mut text = format!("I need your yes:\n\n{}", util::clip(&approval.preview, 2500));
                    if !approval.from_data.is_empty() {
                        text.push_str(&format!("\n\nCheck these (not from you): {}", approval.from_data.join(", ")));
                    }
                    let code = crate::channels::short(&approval.id);
                    text.push_str(&format!("\n\nReply  yes {code}  or  no {code}"));
                    self.dm_people(&approval.agent, &text).await;
                }
                TeamEvent::Question { question } => {
                    let code = crate::channels::short(&question.id);
                    let mut text = question.question.clone();
                    for (i, c) in question.choices.iter().enumerate() {
                        text.push_str(&format!("\n{}. {c}", i + 1));
                    }
                    text.push_str(&format!("\n\nReply  {code} <number or your answer>"));
                    self.dm_people(&question.agent, &text).await;
                }
                _ => {}
            }
        }
    }

    async fn dm_people(&self, agent: &str, text: &str) {
        let Some(token) = self.keys.get(&token_key(agent)) else { return };
        for user in self.agent_slack_of(agent).people.keys() {
            if let Ok(v) = call("conversations.open", &token, json!({"users": user})).await {
                if let Some(ch) = v["channel"]["id"].as_str() {
                    post(&token, ch, None, text).await;
                }
            }
        }
    }

    /// The team bot's message options for an agent speaking in its own voice, if it does.
    pub(crate) async fn slack_voice_of(&self, agent: &str) -> Option<(String, String)> {
        let st = self.agent_slack_of(agent);
        if !st.voice {
            return None;
        }
        let name = self.agent(agent).await.ok()?.name;
        Some((name, if st.emoji.is_empty() { ":candy:".into() } else { st.emoji }))
    }
}

/// Post in a conversation (in a thread when given), in Slack-sized parts.
async fn post(token: &str, conv: &str, thread: Option<&str>, text: &str) {
    for part in cookie_harness::cookie::channel::chunks(text, 3500) {
        let mut body = json!({"channel": conv, "text": part});
        if let Some(t) = thread {
            body["thread_ts"] = json!(t);
        }
        if let Err(e) = call("chat.postMessage", token, body).await {
            tracing::warn!("agent slack: couldn't post: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_agent_takes_work_from_people_not_bots_and_only_when_mentioned_in_a_channel() {
        let m = |v: Value| v;
        assert_eq!(work_in(&m(json!({"user": "U1", "text": "draft the reply"})), "B1", true).as_deref(), Some("draft the reply"));
        assert!(work_in(&m(json!({"user": "U1", "text": "lunch?"})), "B1", false).is_none(), "a channel needs a mention");
        assert_eq!(work_in(&m(json!({"user": "U1", "text": "<@B1>  summarise this thread"})), "B1", false).as_deref(), Some("summarise this thread"));
        assert!(work_in(&m(json!({"user": "U2", "bot_id": "X", "text": "<@B1> hi"})), "B1", false).is_none(), "never a bot: no loops");
        assert!(work_in(&m(json!({"user": "B1", "text": "my own"})), "B1", true).is_none(), "never itself");
        assert!(work_in(&m(json!({"user": "U1", "subtype": "channel_join", "text": "joined"})), "B1", true).is_none());
        assert!(work_in(&m(json!({"user": "U1", "text": "<@B1>"})), "B1", false).is_none(), "a bare mention is no work");
    }

    #[test]
    fn its_app_is_named_and_coloured_as_the_agent_and_asks_only_what_it_needs() {
        let m = manifest("Writing Desk", "Turn my notes into posts.", "#ff8800");
        assert_eq!(m["display_information"]["name"], "Writing Desk");
        assert_eq!(m["features"]["bot_user"]["display_name"], "Writing Desk");
        assert_eq!(m["display_information"]["background_color"], "#ff8800");
        assert_eq!(manifest("A", "short", "red")["display_information"]["background_color"], "#4a154b", "a bad colour falls back");
        let scopes: Vec<&str> = m["oauth_config"]["scopes"]["bot"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
        assert!(scopes.contains(&"chat:write") && scopes.contains(&"im:history"));
        assert!(!scopes.iter().any(|s| s.contains("admin") || s.starts_with("files:write") || s.contains("users:read.email")));
        assert!(manifest("X", "", "#000000")["display_information"]["description"].as_str().unwrap().len() >= 10, "Slack wants a description");
    }

    #[test]
    fn each_shape_has_its_slack_emoji() {
        for s in ["bot", "orb", "crystal", "wisp", "cloud", "star", "ghost", "macaron", "biscuit", "bun", "mochi", "gumdrop"] {
            assert!(emoji_for(s).starts_with(':') && emoji_for(s).ends_with(':'));
        }
    }
}
