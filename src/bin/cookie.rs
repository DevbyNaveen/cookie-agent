//! `cookie run <provider:model> <prompt>` — one run in the terminal.
//! `cookie serve` — the harness over stdio, one JSON object per line.

use std::io::{IsTerminal, Write};

use async_trait::async_trait;
use cookie_harness::{serve::serve, Agent, ApprovalRequest, Approver, Event, Message, RunControl, Session};
use tokio::{
    io::{AsyncBufReadExt, BufReader, Stdin},
    sync::Mutex,
};

const USAGE: &str = "usage:
  cookie run <provider:model> <prompt> [--session FILE] [--instructions TEXT] [--no-enkeon] [-- <prompt starting with ->]
  cookie serve
  cookie --version";

/// Asks on the terminal. With no terminal there is no person, so: no. One
/// reader for the whole run, so an answer typed early is not lost.
struct Terminal(Mutex<BufReader<Stdin>>);

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
        let _ = self.0.lock().await.read_line(&mut answer).await;
        matches!(answer.trim(), "y" | "Y" | "yes")
    }
}

enum Failure {
    /// The command line was wrong: print usage, exit 2.
    Usage(String),
    /// The run failed: exit 1.
    Run(String),
}

async fn run(args: &[String]) -> Result<(), Failure> {
    let (mut positional, mut session, mut instructions, mut enkeon) = (Vec::new(), None, None, true);
    let mut args = args.iter();
    let mut flags = true;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            // Everything after `--` is a value, even if it starts with dashes.
            "--" if flags => flags = false,
            "--session" if flags => session = Some(args.next().ok_or(Failure::Usage("--session needs a file".into()))?.clone()),
            "--instructions" if flags => {
                instructions = Some(args.next().ok_or(Failure::Usage("--instructions needs text".into()))?.clone())
            }
            "--no-enkeon" if flags => enkeon = false,
            flag if flags && flag.starts_with("--") => return Err(Failure::Usage(format!("unknown flag `{flag}`"))),
            value => positional.push(value.to_string()),
        }
    }
    let [model, prompt] = <[String; 2]>::try_from(positional)
        .map_err(|_| Failure::Usage("cookie run needs a model and a prompt".into()))?;
    let mut agent = Agent::new(&model)
        .map_err(|e| Failure::Run(e.to_string()))?
        .approver(Terminal(Mutex::new(BufReader::new(tokio::io::stdin()))));
    if let Some(text) = instructions {
        agent = agent.instructions(text);
    }
    if !enkeon {
        agent = agent.without_enkeon();
    }
    let mut session = match session {
        Some(path) => Session::open(path).await.map_err(|e| Failure::Run(e.to_string()))?,
        None => Session::in_memory(),
    };
    // Ctrl-C cancels the run; what already happened stays in the session.
    let control = RunControl::default();
    let cancel = control.cancel.clone();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            cancel.cancel();
        }
    });
    let mut streamed = false;
    let answer = agent
        .run_streaming(&mut session, Message::user(&prompt), &control, &mut |event| match event {
            Event::TextDelta(text) => {
                streamed = true;
                print!("{text}");
                let _ = std::io::stdout().flush();
            }
            Event::EnkeonUnavailable { reason } => eprintln!("cookie: running without Enkeon: {reason}"),
            _ => {}
        })
        .await
        .map_err(|e| Failure::Run(e.to_string()))?;
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
            Err(Failure::Usage(message)) => {
                eprintln!("cookie: {message}\n{USAGE}");
                2
            }
            Err(Failure::Run(message)) => {
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
