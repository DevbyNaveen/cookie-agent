//! `cookie-team`: your Cookie team without the window. A home runner on an
//! old Mac or a small server, or a cloud runner: the same agents, routines,
//! approvals, Telegram and A2A, reachable from the desktop app, a phone
//! browser, or other people's agents.
//!
//!   cookie-team serve [--dir DIR] [--bind 0.0.0.0] [--port 4519] [--public-url https://…]
//!   cookie-team token [--dir DIR] [--rotate]

use std::path::PathBuf;

fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

fn default_dir() -> PathBuf {
    std::env::var("COOKIE_TEAM_DIR").map(PathBuf::from).unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
        PathBuf::from(home).join(".cookie-team")
    })
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "warn".into())).init();
    let args: Vec<String> = std::env::args().collect();
    let dir = arg(&args, "--dir").map(PathBuf::from).unwrap_or_else(default_dir);
    let team = match cookie_team::Team::open(&dir) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Cookie couldn't open {}: {e}", dir.display());
            std::process::exit(1);
        }
    };
    match args.get(1).map(String::as_str) {
        Some("serve") => {
            let bind = arg(&args, "--bind");
            let port = arg(&args, "--port").and_then(|p| p.parse::<u16>().ok());
            let public = arg(&args, "--public-url");
            let s = team
                .update_settings(|s| {
                    s.server.enabled = true;
                    if let Some(b) = bind { s.server.bind = b; }
                    if let Some(p) = port { s.server.port = p; }
                    if public.is_some() { s.server.public_url = public.map(|u| u.trim_end_matches('/').to_string()); }
                })
                .await
                .expect("settings");
            let token = cookie_team::server::token(&team, false).expect("token");
            team.start();
            let base = s.server.public_url.clone().unwrap_or_else(|| format!("http://{}:{}", s.server.bind, s.server.port));
            println!("Cookie team running from {}", dir.display());
            println!("Open on any device: {base}/#token={token}");
            println!("Agents: {}", team.agents().await.len());
            if s.server.bind != "127.0.0.1" && !base.starts_with("https://") {
                println!("Note: put this behind HTTPS (Caddy, a tunnel) before using it over the internet.");
            }
            let _ = tokio::signal::ctrl_c().await;
        }
        Some("token") => {
            let rotate = args.iter().any(|a| a == "--rotate");
            println!("{}", cookie_team::server::token(&team, rotate).expect("token"));
        }
        _ => {
            eprintln!("usage:\n  cookie-team serve [--dir DIR] [--bind ADDR] [--port N] [--public-url URL]\n  cookie-team token [--dir DIR] [--rotate]");
            std::process::exit(2);
        }
    }
}
