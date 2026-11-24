//! Cookie for the desktop: a thin window over the team (`cookie-team`).
//!
//! Every feature lives in the core and answers through one command, `call`,
//! the same API a home runner serves over HTTP. Team events reach the window
//! as `team` events and, when the window is hidden, as notifications. Closing
//! the window keeps the team working (routines, Telegram, other people's
//! agents); quit from the tray or the menu to stop it.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Arc;

use cookie_team::{Team, TeamEvent};
use serde_json::Value;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Emitter, Manager, RunEvent, State, WindowEvent};
use tauri_plugin_notification::NotificationExt;

#[tauri::command]
async fn call(cmd: String, args: Option<Value>, team: State<'_, Arc<Team>>) -> Result<Value, String> {
    cookie_team::api::call(&team, &cmd, args.unwrap_or(Value::Null)).await
}

/// Show one of Cookie's own folders in Finder (or the system file manager).
#[tauri::command]
fn reveal(path: String, team: State<'_, Arc<Team>>) -> Result<(), String> {
    let p = std::path::PathBuf::from(&path);
    if !team.paths.owns(&p) {
        return Err("Cookie only opens its own folders.".into());
    }
    std::fs::create_dir_all(&p).map_err(|e| e.to_string())?;
    #[cfg(target_os = "macos")]
    let opener = "open";
    #[cfg(target_os = "windows")]
    let opener = "explorer";
    #[cfg(all(unix, not(target_os = "macos")))]
    let opener = "xdg-open";
    std::process::Command::new(opener).arg(&p).spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// A file an agent showed in its chat, in its own app or in Finder. Only from where the agent
/// may read (`chat_file_path`), and opening only documents and media, never something that runs.
#[tauri::command]
fn open_file(agent: String, path: String, reveal: bool, team: State<'_, Arc<Team>>) -> Result<(), String> {
    let real = team.chat_file_path(&agent, &path)?;
    if !reveal && !cookie_team::chatfiles::openable(&real) {
        return Err("Cookie doesn't open that kind of file from a chat. Show it in Finder instead.".into());
    }
    #[cfg(target_os = "macos")]
    let mut cmd = {
        let mut c = std::process::Command::new("open");
        if reveal {
            c.arg("-R");
        }
        c
    };
    #[cfg(target_os = "windows")]
    let mut cmd = {
        let mut c = std::process::Command::new("explorer");
        if reveal {
            c.arg("/select,");
        }
        c
    };
    #[cfg(all(unix, not(target_os = "macos")))]
    let mut cmd = std::process::Command::new("xdg-open");
    #[cfg(all(unix, not(target_os = "macos")))]
    let real = if reveal { real.parent().map(|p| p.to_path_buf()).unwrap_or(real) } else { real };
    cmd.arg(&real).spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// The count on the app's icon: what waits for the person (approvals, questions, worlds). 0 clears it.
#[tauri::command]
fn set_badge(count: i64, app: tauri::AppHandle) -> Result<(), String> {
    let Some(w) = app.get_webview_window("main") else { return Ok(()) };
    w.set_badge_count((count > 0).then_some(count)).map_err(|e| e.to_string())
}

/// Open a web page in the person's browser: only https (pairing with Enkeon opens its Console).
#[tauri::command]
fn open_url(url: String) -> Result<(), String> {
    if !url.starts_with("https://") || url.chars().any(|c| c.is_control() || c == ' ') {
        return Err("Cookie opens only https pages.".into());
    }
    #[cfg(target_os = "macos")]
    let opener = "open";
    #[cfg(target_os = "windows")]
    let opener = "explorer";
    #[cfg(all(unix, not(target_os = "macos")))]
    let opener = "xdg-open";
    std::process::Command::new(opener).arg(&url).spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// A second window on one agent, so two conversations can sit side by side.
#[tauri::command]
async fn open_window(app: tauri::AppHandle, agent: String, title: String) -> Result<(), String> {
    if !agent.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return Err("Not an agent id.".into());
    }
    let label = format!("agent-{agent}");
    if let Some(w) = app.get_webview_window(&label) {
        let _ = w.unminimize();
        return w.set_focus().map_err(|e| e.to_string());
    }
    let url = tauri::WebviewUrl::App(format!("index.html?agent={agent}").into());
    let builder = tauri::WebviewWindowBuilder::new(&app, label, url)
        .title(title)
        .inner_size(760.0, 720.0)
        .min_inner_size(520.0, 420.0)
        .disable_drag_drop_handler()
        .transparent(true);
    #[cfg(target_os = "macos")]
    let builder = builder
        .title_bar_style(tauri::TitleBarStyle::Overlay)
        .hidden_title(true)
        .traffic_light_position(tauri::LogicalPosition::new(20.0, 28.0));
    builder.build().map(|_| ()).map_err(|e| e.to_string())
}

/// The Mac's own folder chooser, for Settings → Your files. None when cancelled.
#[tauri::command]
async fn pick_folder() -> Result<Option<String>, String> {
    #[cfg(target_os = "macos")]
    {
        let out = tauri::async_runtime::spawn_blocking(|| {
            std::process::Command::new("osascript")
                .args(["-e", "POSIX path of (choose folder with prompt \"Choose a folder your agents may see\")"])
                .output()
        })
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| e.to_string())?;
        if !out.status.success() {
            return Ok(None); // cancelled
        }
        let path = String::from_utf8_lossy(&out.stdout).trim().trim_end_matches('/').to_string();
        Ok((!path.is_empty()).then_some(path))
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(None)
    }
}

/// The Glass theme: the window itself turns to frosted glass (macOS vibrancy), so the
/// desktop shows through, blurred, wherever the page leaves it uncovered.
#[tauri::command]
fn set_glass(window: tauri::WebviewWindow, on: bool) -> Result<bool, String> {
    #[cfg(target_os = "macos")]
    {
        use tauri::window::{Effect, EffectState, EffectsBuilder};
        let effects = on.then(|| EffectsBuilder::new().effect(Effect::UnderWindowBackground).state(EffectState::Active).build());
        window.set_effects(effects).map_err(|e| e.to_string())?;
        Ok(on)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (window, on);
        Ok(false)
    }
}

fn show_main(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn main() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            let dir = app.path().app_data_dir()?;
            let team = Team::open(&dir).map_err(|e| -> Box<dyn std::error::Error> { e.into() })?;
            app.manage(team.clone());
            // The team's background work (routines, Telegram, the server) needs the async runtime.
            let starter = team.clone();
            tauri::async_runtime::spawn(async move { starter.start() });

            // Team events → the window, and notifications when it can't be seen.
            let handle = app.handle().clone();
            let mut rx = team.subscribe();
            tauri::async_runtime::spawn(async move {
                loop {
                    let ev = match rx.recv().await {
                        Ok(ev) => ev,
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(_) => break,
                    };
                    let _ = handle.emit("team", &ev);
                    let visible = handle.get_webview_window("main").and_then(|w| w.is_visible().ok().zip(w.is_focused().ok())).is_some_and(|(v, f)| v && f);
                    let note = match &ev {
                        TeamEvent::Notice { title, body, .. } => Some((title.clone(), body.clone())),
                        TeamEvent::Asked { approval } => Some((format!("{} needs your yes", approval.agent_name), approval.preview.chars().take(180).collect())),
                        _ => None,
                    };
                    if let (Some((title, body)), false) = (note, visible) {
                        let _ = handle.notification().builder().title(title).body(body).show();
                    }
                }
            });

            // The tray: Cookie keeps working with the window closed.
            let open = MenuItem::with_id(app, "open", "Open Cookie", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Cookie", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &quit])?;
            let mut tray = TrayIconBuilder::with_id("cookie").menu(&menu).tooltip("Cookie").on_menu_event(|app, e| match e.id().as_ref() {
                "open" => show_main(app),
                "quit" => app.exit(0),
                _ => {}
            });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            // Hide the main window, don't quit: routines and approvals keep running.
            // Extra agent windows simply close.
            if let WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![call, reveal, open_file, set_badge, open_window, open_url, set_glass, pick_folder])
        .build(tauri::generate_context!())
        .expect("Cookie could not start");
    app.run(|app, event| {
        if let RunEvent::Reopen { .. } = event {
            show_main(app);
        }
    });
}
