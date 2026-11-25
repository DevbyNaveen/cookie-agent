//! `hands`: Cookie Hands from the command line, for inside a vault (or any machine).
//!
//!   hands apps
//!   hands look [--app NAME] [--limit N]
//!   hands act  [--app NAME] --steps '[{"role":"button","name":"OK","do":"press"}]'

use std::collections::HashMap;

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(body) = cookie_hands::body() else {
        eprintln!("No hands on this system (is the accessibility bus running?).");
        std::process::exit(2);
    };
    if let Err(e) = body.ready() {
        eprintln!("{e}");
        std::process::exit(2);
    }
    let look = cookie_hands::Look { app: flag(&args, "--app"), pid: None, limit: flag(&args, "--limit").and_then(|n| n.parse().ok()).unwrap_or(250) };
    let out = match args.first().map(String::as_str) {
        Some("apps") => body.apps().map(|a| a.iter().map(|x| format!("{}{}", x.name, if x.front { " (in front)" } else { "" })).collect::<Vec<_>>().join("\n")),
        Some("look") => body.look(&look).map(|s| cookie_hands::render(&s)),
        Some("act") => {
            let steps: Result<Vec<cookie_hands::Step>, String> = flag(&args, "--steps").ok_or("act needs --steps (a JSON list).".to_string()).and_then(|s| serde_json::from_str(&s).map_err(|e| format!("--steps: {e}")));
            steps.and_then(|steps| cookie_hands::run(body, &look, &steps, &HashMap::new())).map(|d| {
                let mut t = String::new();
                if !d.did.is_empty() {
                    t.push_str(&format!("Did ({} ms): {}\n", d.took_ms, d.did.join(" → ")));
                }
                if let Some(f) = &d.failed {
                    t.push_str(&format!("Stopped at {f}\n"));
                }
                if d.changes.len() > 30 || d.changes.iter().any(|c| c.starts_with("~ app") || c.starts_with("~ window")) {
                    t.push_str("A lot changed; the window now:\n");
                    t.push_str(&cookie_hands::render(&d.after));
                } else if d.changes.is_empty() {
                    t.push_str("Nothing on screen changed.\n");
                } else {
                    t.push_str("Changed (refs are current):\n");
                    t.push_str(&d.changes.join("\n"));
                }
                t
            })
        }
        _ => Err("hands apps | look [--app NAME] [--limit N] | act [--app NAME] --steps JSON".into()),
    };
    match out {
        Ok(t) => println!("{t}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
