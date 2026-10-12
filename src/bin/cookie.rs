//! `cookie run <provider:model> <prompt>` — one run in the terminal.
//! `cookie serve` — the harness over stdio, one JSON object per line.

use std::io::{IsTerminal, Write};

use async_trait::async_trait;
use cookie_harness::{serve::serve, Agent, ApprovalRequest, Approver, Event, Message, RunControl, Session};
use tokio::io::{AsyncBufReadExt, BufReader};

const USAGE: &str = "usage:
  cookie run <provider:model> <prompt> [--session FILE] [--instructions TEXT] [--no-enkeon]
  cookie serve
  cookie --version";

/// Asks on the terminal. With no terminal there is no person, so: no.
struct Terminal;

#[async_trait]
impl Approver for Terminal {
    async fn approve(&self, request: &ApprovalRequest) -> bool {
        if !std::io::stdin().is_terminal() {
            eprintln!("\ncookie: `{}` needs a person and there is no terminal to ask; declined.", request.tool);
            return false;
        }
        eprint!("\n{}\n{}\nAllow? [y/N] ", request.reason, request.preview);
        let _ = std::io::stderr().flush();
        let mut answer = String::new();
        let _ = BufReader::new(tokio::io::stdin()).read_line(&mut answer).await;
        matches!(answer.trim(), "y" | "Y" | "yes")
    }
}

async fn run(args: &[String]) -> Result<(), String> {
    let (mut positional, mut session, mut instructions, mut enkeon) = (Vec::new(), None, None, true);
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--session" => session = Some(args.next().ok_or("--session needs a file")?.clone()),
            "--instructions" => instructions = Some(args.next().ok_or("--instructions needs text")?.clone()),
            "--no-enkeon" => enkeon = false,
            flag if flag.starts_with("--") => return Err(format!("unknown flag `{flag}`")),
            value => positional.push(value.to_string()),
        }
    }
    let [model, prompt] = <[String; 2]>::try_from(positional).map_err(|_| "cookie run <provider:model> <prompt>".to_string())?;
    let mut agent = Agent::new(&model).map_err(|e| e.to_string())?.approver(Terminal);
    if let Some(text) = instructions {
        agent = agent.instructions(text);
    }
    if !enkeon {
        agent = agent.without_enkeon();
    }
    let mut session = match session {
        Some(path) => Session::open(path).await.map_err(|e| e.to_string())?,
        None => Session::in_memory(),
    };
    let mut streamed = false;
    let answer = agent
        .run_streaming(&mut session, Message::user(&prompt), &RunControl::default(), &mut |event| match event {
            Event::TextDelta(text) => {
                streamed = true;
                print!("{text}");
                let _ = std::io::stdout().flush();
            }
            Event::EnkeonUnavailable { reason } => eprintln!("cookie: running without Enkeon: {reason}"),
            _ => {}
        })
        .await
        .map_err(|e| e.to_string())?;
    if streamed {
        println!();
    } else {
        println!("{answer}");
    }
    Ok(())
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        Some("--version") => {
            println!("cookie {}", env!("CARGO_PKG_VERSION"));
            0
        }
        Some("serve") => {
            let made = serve(BufReader::new(tokio::io::stdin()), tokio::io::stdout(), |request| Agent::new(&request.model)).await;
            i32::from(made.is_err())
        }
        Some("run") => match run(&args[1..]).await {
            Ok(()) => 0,
            Err(message) if message.starts_with("cookie run") => {
                eprintln!("{USAGE}");
                2
            }
            Err(message) => {
                eprintln!("cookie: {message}");
                1
            }
        },
        _ => {
            eprintln!("{USAGE}");
            2
        }
    };
    std::process::exit(code);
}
