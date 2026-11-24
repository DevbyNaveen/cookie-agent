//! Every command a surface can give, in one place. The desktop app calls it
//! through Tauri, a phone or another computer through the runner's HTTP API;
//! both get the same answers. Arguments and answers are JSON.

use std::sync::Arc;

use serde::de::DeserializeOwned;
use serde_json::{json, Value};

use crate::runtime::Attachment;
use crate::store::{Schedule, Settings, Trigger};
use crate::{keys::Keys, util, Hire, Patch, Team};

fn arg<T: DeserializeOwned>(args: &Value, name: &str) -> Result<T, String> {
    serde_json::from_value(args.get(name).cloned().unwrap_or(Value::Null)).map_err(|e| format!("`{name}`: {e}"))
}

fn opt<T: DeserializeOwned>(args: &Value, name: &str) -> Option<T> {
    args.get(name).cloned().filter(|v| !v.is_null()).and_then(|v| serde_json::from_value(v).ok())
}

fn ok<T: serde::Serialize>(v: T) -> Result<Value, String> {
    serde_json::to_value(v).map_err(|e| e.to_string())
}

/// The fields of settings a surface may change (invites and Telegram's links
/// change only through their own commands).
fn apply_settings(s: &mut Settings, p: &Value) {
    if let Some(v) = p.get("prices").and_then(|v| serde_json::from_value(v.clone()).ok()) { s.prices = v; }
    if let Some(v) = p.get("checker_model") { s.checker_model = v.as_str().map(str::trim).filter(|m| !m.is_empty()).map(str::to_string); }
    if let Some(v) = p.get("daily_notices").and_then(Value::as_i64) { s.daily_notices = v.clamp(0, 50); }
    if let Some(v) = p.get("market_url") { s.market_url = v.as_str().map(str::trim).filter(|m| !m.is_empty()).map(str::to_string); }
    if let Some(v) = p.get("challenge_model") { s.challenge_model = v.as_str().map(str::trim).filter(|m| !m.is_empty()).map(str::to_string); }
    if let Some(v) = p.get("server") {
        if let Some(b) = v.get("enabled").and_then(Value::as_bool) { s.server.enabled = b; }
        if let Some(b) = v.get("bind").and_then(Value::as_str) { s.server.bind = b.trim().to_string(); }
        if let Some(n) = v.get("port").and_then(Value::as_u64) { s.server.port = n.clamp(1024, 65535) as u16; }
        if let Some(u) = v.get("public_url") { s.server.public_url = u.as_str().map(|u| u.trim().trim_end_matches('/').to_string()).filter(|u| !u.is_empty()); }
    }
}

/// The machine user's name, for the sidebar footer.
pub fn me() -> String {
    #[cfg(target_os = "macos")]
    if let Ok(out) = std::process::Command::new("id").arg("-F").output() {
        let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !name.is_empty() {
            return name;
        }
    }
    std::env::var("USER").or_else(|_| std::env::var("USERNAME")).unwrap_or_default()
}

pub async fn call(team: &Arc<Team>, cmd: &str, args: Value) -> Result<Value, String> {
    let a = &args;
    match cmd {
        /* who and where */
        "me" => ok(me()),
        "data_dir" => ok(team.paths.root.to_string_lossy()),
        "providers" => ok(Keys::present()),
        "key_providers" => ok(crate::keys::PROVIDERS.iter().map(|(id, label, var)| json!({"id": id, "label": label, "env": var, "set": std::env::var(var).is_ok_and(|v| !v.is_empty())})).collect::<Vec<_>>()),
        "set_key" => {
            team.keys.set_provider(&arg::<String>(a, "provider")?, &arg::<String>(a, "value")?)?;
            // A first model key is enough to bring Cookie in.
            team.ensure_cookie().await;
            ok(())
        }

        /* roster */
        "list_agents" => ok(team.rows().await),
        "mark_read" => ok(team.mark_read(&arg::<String>(a, "id")?)?),
        "arrange" => ok(team.arrange(&arg::<String>(a, "id")?, arg::<crate::SidebarPatch>(a, "patch")?).await?),
        "hire_agent" => ok(team.hire(arg::<Hire>(a, "hire")?).await?),
        "update_agent" => ok(team.update(&arg::<String>(a, "id")?, arg::<Patch>(a, "patch")?).await?),
        "fire_agent" => ok(team.fire(&arg::<String>(a, "id")?, opt(a, "handover").unwrap_or(false)).await?),
        "handovers" => ok(team.handovers().into_iter().map(|(file, title)| json!({"file": file, "title": title})).collect::<Vec<_>>()),
        "agent_workspace" => {
            let id: String = arg(a, "id")?;
            let work = team.paths.work(&id);
            let mut files = Vec::new();
            for e in std::fs::read_dir(&work).into_iter().flatten().flatten() {
                let Ok(meta) = e.metadata() else { continue };
                if meta.is_file() {
                    let modified = meta.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs());
                    files.push(json!({"name": e.file_name().to_string_lossy(), "bytes": meta.len(), "modified": modified}));
                }
            }
            files.sort_by(|x, y| y["modified"].as_u64().cmp(&x["modified"].as_u64()));
            let messages = team.history(&id).await.map(|h| h.len()).unwrap_or(0);
            ok(json!({"dir": work.to_string_lossy(), "files": files, "messages": messages}))
        }

        /* jobs */
        "history" => ok(team.history(&arg::<String>(a, "id")?).await?),
        "send" => {
            let attachments: Vec<Attachment> = opt(a, "attachments").unwrap_or_default();
            ok(team.start_job(&arg::<String>(a, "id")?, arg(a, "text")?, attachments, Trigger::Chat).await?)
        }
        "stop" => ok(team.stop(&arg::<String>(a, "id")?)),
        "steer" => ok(team.steer(&arg::<String>(a, "id")?, &arg::<String>(a, "text")?)),
        "busy" => ok(team.busy().into_iter().map(|(agent, job)| json!({"agent": agent, "job": job})).collect::<Vec<_>>()),
        "jobs" => ok(team.jobs(&arg::<String>(a, "id")?)),
        "grade" => ok(team.grade(&arg::<String>(a, "id")?, &arg::<String>(a, "job")?, opt(a, "grade"))?),
        "mark_promise" => ok(team.mark_promise(&arg::<String>(a, "id")?, &arg::<String>(a, "job")?, arg(a, "index")?, &arg::<String>(a, "state")?)?),
        "scorecard" => ok(team.scorecard(&arg::<String>(a, "id")?)),
        /* what it learned from its own work */
        "rank" => ok(team.rank_view(&team.agent(&arg::<String>(a, "id")?).await?)),
        "lessons" => ok(team.lessons_view(&arg::<String>(a, "id")?)),
        "set_lesson" => ok(team.set_lesson(&arg::<String>(a, "id")?, &arg::<String>(a, "lesson")?, &arg::<String>(a, "state")?)?),
        "procedures" => ok(team.procedures(&arg::<String>(a, "id")?).into_values().collect::<Vec<_>>()),
        "set_procedure" => ok(team.set_procedure(&arg::<String>(a, "id")?, &arg::<String>(a, "routine")?, arg::<bool>(a, "on")?)?),
        "routine_offers" => ok(team.routine_offers().into_iter().filter(|o| o.state == "open").collect::<Vec<_>>()),
        "answer_routine_offer" => ok(team.answer_routine_offer(&arg::<String>(a, "offer")?, arg::<bool>(a, "yes")?).await?),
        "retro" => ok(team.retro()),
        /* job links and the PIN; mail to Cookie */
        "links_status" => ok(team.links_status()),
        "set_link_pin" => ok(team.set_link_pin(&arg::<String>(a, "pin")?)?),
        "end_link_sessions" => ok(team.end_link_sessions()?),
        "job_link" => ok(team.job_link(&arg::<String>(a, "id")?, &arg::<String>(a, "job")?).await),
        "mail_status" => ok(team.mail_status()),
        "file_changes" => ok(team.file_changes(opt::<String>(a, "id").as_deref())),
        "undo_file_change" => ok(team.undo_file_change(&arg::<String>(a, "change")?)?),
        "open_promises" => ok(team.open_promises().await),

        /* approvals and attention */
        "approvals" => ok(team.pending_approvals()),
        "answer" => ok(team.answer(&arg::<String>(a, "id")?, arg(a, "yes")?, opt::<String>(a, "by").as_deref().unwrap_or("window"))?),
        "notice_feedback" => ok(team.notice_feedback(&arg::<String>(a, "agent")?, arg(a, "dismissed")?)),

        /* routines */
        "routines" => ok(team.routines().await),
        "add_routine" => ok(team.add_routine(&arg::<String>(a, "agent")?, &arg::<String>(a, "task")?, arg::<Schedule>(a, "schedule")?).await?),
        "update_routine" => ok(team.update_routine(&arg::<String>(a, "id")?, opt(a, "task"), opt(a, "schedule")).await?),
        "set_routine_enabled" => ok(team.set_routine_enabled(&arg::<String>(a, "id")?, arg(a, "enabled")?).await?),
        "delete_routine" => ok(team.delete_routine(&arg::<String>(a, "id")?).await?),
        "run_routine_now" => ok(team.run_routine_now(&arg::<String>(a, "id")?).await?),
        "describe_schedule" => ok(crate::routines::describe(&arg::<Schedule>(a, "schedule")?)),

        /* tests, forks, probation */
        "tests" => ok(team.tests(&arg::<String>(a, "id")?)),
        "save_test" => ok(team.save_test(&arg::<String>(a, "id")?, &arg::<String>(a, "input")?, &arg::<String>(a, "expect")?, opt::<String>(a, "job").as_deref())?),
        "delete_test" => ok(team.delete_test(&arg::<String>(a, "id")?, &arg::<String>(a, "test")?)?),
        "run_tests" => ok(team.run_tests(&arg::<String>(a, "id")?, opt(a, "model")).await?),
        "test_runs" => ok(team.test_runs(&arg::<String>(a, "id")?)),
        "fork" => ok(team.fork(&arg::<String>(a, "id")?, opt(a, "model"), opt(a, "job")).await?),
        "forks" => ok(team.forks_of(&arg::<String>(a, "id")?).await),
        "compare" => ok(team.compare(&arg::<String>(a, "id")?, &arg::<String>(a, "fork")?)),
        "promote" => ok(team.promote(&arg::<String>(a, "fork")?).await?),

        /* settings */
        "settings" => ok(team.settings().await),
        "update_settings" => {
            let patch = a.get("patch").cloned().unwrap_or(Value::Null);
            let s = team.update_settings(|s| apply_settings(s, &patch)).await?;
            if patch.get("server").is_some() {
                crate::server::spawn_if_enabled(team.clone());
            }
            ok(s)
        }

        /* channels */
        "telegram_connect" => ok(team.telegram_connect(&arg::<String>(a, "token")?).await?),
        "telegram_disconnect" => ok(team.telegram_disconnect().await?),
        "telegram_code" => ok(team.telegram_code().await?),
        "telegram_status" => {
            let s = team.settings().await.telegram;
            ok(json!({"enabled": s.enabled, "has_token": team.keys.get("telegram").is_some(), "chats": s.chats.len(), "code": s.pending_code}))
        }

        /* runner and sharing */
        "runner_token" => ok(crate::server::token(team, opt(a, "rotate").unwrap_or(false))?),
        "server_status" => ok(crate::server::status(team).await),
        "invites" => ok(team.settings().await.invites.into_iter().filter(|i| !i.revoked).collect::<Vec<_>>()),
        "create_invite" => ok(team.create_invite(&arg::<String>(a, "agent")?, &opt::<String>(a, "label").unwrap_or_default()).await?),
        "revoke_invite" => ok(team.revoke_invite(&arg::<String>(a, "id")?).await?),
        "add_peer" => ok(team.add_peer(&arg::<String>(a, "agent")?, &arg::<String>(a, "link")?).await?),
        "remove_peer" => ok(team.remove_peer(&arg::<String>(a, "agent")?, &arg::<String>(a, "url")?).await?),

        /* packs and market */
        "export_pack" => ok(team.export(&arg::<String>(a, "id")?).await?),
        "import_pack" => ok(team.import(arg(a, "pack")?, opt(a, "model")).await?),
        "market" => ok(team.market().await?),
        "install" => ok(team.install(&arg::<String>(a, "url")?, opt(a, "model")).await?),
        "publisher_key" => ok(team.publisher_key()?),

        /* scout and inbox */
        "scout" => ok(crate::scout::proposals(&team.settings().await.scout_dismissed)?),
        "scout_dismiss" => {
            let id: String = arg(a, "proposal")?;
            ok(team.update_settings(|s| if !s.scout_dismissed.contains(&id) { s.scout_dismissed.push(id) }).await.map(|_| ())?)
        }
        "inbox_scan" => ok(team.inbox_scan(&arg::<String>(a, "model")?).await?),
        "enkeon_status" => ok(cookie_harness::enkeon::Enkeon::from_env().is_some()),

        /* channels: Slack, Discord, iMessage, Signal */
        "channels" => ok(team.channel_states().into_iter().map(|(k, s)| (k, json!({"enabled": s.enabled, "config": s.config, "chats": s.chats, "code": s.pending_code, "status": s.status}))).collect::<std::collections::BTreeMap<_, _>>()),
        "channel_connect" => ok(team.channel_connect(&arg::<String>(a, "kind")?, opt(a, "secret"), a.get("config").cloned().unwrap_or(Value::Null)).await?),
        "channel_disconnect" => ok(team.channel_disconnect(&arg::<String>(a, "kind")?).await?),
        "channel_code" => ok(team.channel_code(&arg::<String>(a, "kind")?).await?),
        "channel_unlink" => ok(team.channel_unlink(&arg::<String>(a, "kind")?, &arg::<String>(a, "chat")?)?),

        /* your files */
        "access" => ok(team.access()),
        "set_access" => ok(team.set_access(&arg::<String>(a, "level")?, opt::<Vec<String>>(a, "folders").unwrap_or_default())?),

        /* what an agent knows */
        "memory" => ok(team.memory(&arg::<String>(a, "id")?).await?),
        "memory_search" => ok(team.memory_search(&arg::<String>(a, "id")?, &arg::<String>(a, "query")?).await?),
        "memory_add" => ok(team.memory_add(&arg::<String>(a, "id")?, &arg::<String>(a, "text")?).await?),
        "memory_edit" => ok(team.memory_edit(&arg::<String>(a, "id")?, &arg::<String>(a, "memory")?, &arg::<String>(a, "text")?).await?),
        "memory_forget" => ok(team.memory_forget(&arg::<String>(a, "id")?, &arg::<String>(a, "memory")?).await?),

        /* voice */
        "voice_status" => ok(team.voice_status()),
        "voice_setup" => ok(team.voice_setup().await?),
        "voice_voices" => ok(team.voice_voices().await?),
        "voice_choose" => ok(team.voice_choose(&opt::<String>(a, "voice").unwrap_or_default())?),
        "voice_use_mac_key" => ok(team.voice_use_mac_key()?),
        "speak" => ok(team.speak(&arg::<String>(a, "text")?).await?),
        "transcribe" => ok(team.transcribe_b64(&arg::<String>(a, "audio")?, &opt::<String>(a, "ext").unwrap_or_else(|| "webm".into())).await?),

        /* questions, plans, undo */
        "questions" => ok(team.questions()),
        "answer_question" => ok(team.answer_question(&arg::<String>(a, "id")?, &arg::<String>(a, "answer")?, opt::<String>(a, "by").as_deref().unwrap_or("window"))?),
        "todos" => ok(team.todos(&arg::<String>(a, "id")?)),
        "checkpoints" => ok(team.checkpoints(&arg::<String>(a, "id")?)),
        "restore_checkpoint" => ok(team.restore_checkpoint(&arg::<String>(a, "id")?, &arg::<String>(a, "job")?)?),

        /* learning */
        "skills" => ok(team.skills(&arg::<String>(a, "id")?)),
        "skill_read" => ok(team.skill_view(&arg::<String>(a, "id")?, &arg::<String>(a, "name")?, opt::<String>(a, "file").as_deref())?),
        "skill_save" => ok(team.skill_write(&arg::<String>(a, "id")?, &arg::<String>(a, "name")?, &opt::<String>(a, "file").unwrap_or_else(|| "SKILL.md".into()), &arg::<String>(a, "content")?, "written")?),
        "skill_set" => ok(team.skill_set(&arg::<String>(a, "id")?, &arg::<String>(a, "name")?, &arg::<String>(a, "action")?)?),
        "skill_versions" => ok(team.skill_versions(&arg::<String>(a, "id")?, &arg::<String>(a, "name")?)),
        "skill_revert" => ok(team.skill_revert(&arg::<String>(a, "id")?, &arg::<String>(a, "name")?, &arg::<String>(a, "version")?, &opt::<String>(a, "file").unwrap_or_else(|| "SKILL.md".into()))?),
        "about_you" => ok(team.about_you()),
        "about_you_add" => ok(team.about_you_add(&arg::<String>(a, "line")?)?),
        "about_you_remove" => ok(team.about_you_remove(&arg::<String>(a, "line")?)?),
        "learning" => ok(json!({"enabled": team.learning_enabled(&arg::<String>(a, "id")?), "memory_every": crate::learning::MEMORY_NUDGE, "skills_every": crate::learning::SKILL_NUDGE})),
        "set_learning" => ok(team.set_learning(&arg::<String>(a, "id")?, arg(a, "on")?)?),
        "learn_now" => {
            let rec = team.agent(&arg::<String>(a, "id")?).await?;
            ok(team.review(&rec, true, true).await?)
        }
        "skill_catalog" => ok(team.catalog(&arg::<String>(a, "id")?)),
        "install_skill" => ok(team.install_skill(&arg::<String>(a, "id")?, &arg::<String>(a, "folder")?)?),
        "import_skill" => ok(team.import_skill_path(&arg::<String>(a, "id")?, &arg::<String>(a, "path")?)?),
        "search_history" => ok(team.search_history(&arg::<String>(a, "id")?, &arg::<String>(a, "query")?, opt(a, "limit").unwrap_or(10))),

        /* the Cookie Network */
        "addresses" => ok(team.addresses().await),
        "net_status" => ok(team.net_status().await?),
        "net_setup" => ok(team.net_setup(&arg::<String>(a, "relay")?, &arg::<String>(a, "handle")?, opt(a, "display_name")).await?),
        "net_enable" => ok(team.net_enable(arg(a, "on")?).await?),
        "net_update" => ok(team.net_update(a.get("patch").unwrap_or(&Value::Null)).await?),
        "net_agent" => ok(team.net_agent(&arg::<String>(a, "id")?, a.get("patch").unwrap_or(&Value::Null)).await?),
        "net_lookup" => ok(team.net_lookup(&arg::<String>(a, "address")?).await?),
        "net_directory" => ok(team.net_directory(&opt::<String>(a, "q").unwrap_or_default()).await?),
        "net_knock" => ok(team.net_knock(&arg::<String>(a, "address")?, opt(a, "agent"), &opt::<String>(a, "note").unwrap_or_default()).await?),
        "net_contacts" => ok(team.contacts()),
        "net_answer_knock" => ok(team.net_answer_knock(&arg::<String>(a, "id")?, arg(a, "accept")?, &opt::<String>(a, "level").unwrap_or_else(|| "talk".into())).await?),
        "net_contact_set" => ok(team.net_contact_set(&arg::<String>(a, "id")?, a.get("patch").unwrap_or(&Value::Null)).await?),
        "net_contact_remove" => ok(team.net_contact_remove(&arg::<String>(a, "id")?).await?),
        "net_threads" => ok(team.net_threads()),
        "net_thread" => ok(team.thread(&arg::<String>(a, "id")?)),
        "net_send" => ok(team.net_send(&arg::<String>(a, "id")?, &arg::<String>(a, "text")?).await?),
        "net_deals" => ok(team.deals()),
        "net_answer_deal" => ok(team.net_answer_deal(&arg::<String>(a, "id")?, arg(a, "accept")?).await?),
        "net_rooms" => ok(team.rooms()),
        "net_create_room" => ok(team.net_create_room(&arg::<String>(a, "name")?, opt(a, "agents").unwrap_or_default(), opt(a, "contacts").unwrap_or_default()).await?),
        "net_answer_room" => ok(team.net_answer_room(&arg::<String>(a, "id")?, arg(a, "accept")?).await?),
        "net_leave_room" => ok(team.net_leave_room(&arg::<String>(a, "id")?).await?),
        "net_room_send" => ok(team.net_room_send(&arg::<String>(a, "id")?, &arg::<String>(a, "text")?).await?),
        "net_qr" => ok(crate::network::qr_svg(&arg::<String>(a, "text")?)?),

        "version" => ok(env!("CARGO_PKG_VERSION")),
        "now" => ok(util::now()),
        other => Err(format!("Cookie doesn't know the command `{other}`.")),
    }
}
