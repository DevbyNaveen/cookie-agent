//! `cookie run <provider:model> <prompt>` — one run in the terminal.
//! `cookie chat <provider:model>` — a conversation, one run per line.
//! `cookie replay <session.jsonl>` — run a recording again from its log.
//! `cookie serve` — the harness over stdio, one JSON object per line.

use std::{
    io::{IsTerminal, Write},
    sync::Arc,
};

use cookie_harness::{
    chat::{chat, Input, LineApprover},
    serve::serve,
    Agent, Error, Event, Message, Replay, RunControl, Session,
};
use tokio::{
    io::{BufReader, Stdin},
    sync::{mpsc, Mutex},
};

const USAGE: &str = "usage:
  cookie run <provider:model> <prompt> [--session FILE] [--instructions TEXT] [--no-enkeon] [-- <prompt starting with ->]
  cookie chat <provider:model> [--session FILE] [--instructions TEXT] [--no-enkeon]
  cookie replay <session.jsonl>
  cookie serve
  cookie --version";

enum Failure {
    /// The command line was wrong: print usage, exit 2.
    Usage(String),
    /// The run failed: exit 1.
    Run(String),
}

fn failed(error: impl ToString) -> Failure {
    Failure::Run(error.to_string())
}

/// What `run` and `chat` share: the words that are not flags, and the flags.
struct Options {
    positional: Vec<String>,
    session: Option<String>,
    instructions: Option<String>,
    enkeon: bool,
}

fn options(args: &[String]) -> Result<Options, Failure> {
    let mut options = Options { positional: Vec::new(), session: None, instructions: None, enkeon: true };
    let mut args = args.iter();
    let mut flags = true;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            // Everything after `--` is a value, even if it starts with dashes.
            "--" if flags => flags = false,
            "--session" if flags => options.session = Some(args.next().ok_or(Failure::Usage("--session needs a file".into()))?.clone()),
            "--instructions" if flags => {
                options.instructions = Some(args.next().ok_or(Failure::Usage("--instructions needs text".into()))?.clone())
            }
            "--no-enkeon" if flags => options.enkeon = false,
            flag if flags && flag.starts_with("--") => return Err(Failure::Usage(format!("unknown flag `{flag}`"))),
            value => options.positional.push(value.to_string()),
        }
    }
    Ok(options)
}

/// The agent and session the options describe, asking on the terminal
/// through `input`, the one reader of stdin.
async fn setup(model: &str, options: &Options, input: &Input<BufReader<Stdin>>) -> Result<(Agent, Session), Failure> {
    let mut agent = Agent::new(model).map_err(failed)?.approver(LineApprover::new(input.clone(), std::io::stdin().is_terminal()));
    if let Some(text) = &options.instructions {
        agent = agent.instructions(text.clone());
    }
    if !options.enkeon {
        agent = agent.without_enkeon();
    }
    let session = match &options.session {
        Some(path) => Session::open(path).await.map_err(failed)?,
        None => Session::in_memory(),
    };
    Ok((agent, session))
}

fn stdin() -> Input<BufReader<Stdin>> {
    Arc::new(Mutex::new(BufReader::new(tokio::io::stdin())))
}

async fn run(args: &[String]) -> Result<(), Failure> {
    let options = options(args)?;
    let [model, prompt] = <[String; 2]>::try_from(options.positional.clone())
        .map_err(|_| Failure::Usage("cookie run needs a model and a prompt".into()))?;
    let (agent, mut session) = setup(&model, &options, &stdin()).await?;
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
        .map_err(failed)?;
    if streamed {
        println!();
    } else {
        println!("{answer}");
    }
    Ok(())
}

async fn chat_command(args: &[String]) -> Result<(), Failure> {
    let options = options(args)?;
    let [model] = <[String; 1]>::try_from(options.positional.clone())
        .map_err(|_| Failure::Usage("cookie chat needs a model, and nothing else".into()))?;
    let input = stdin();
    let (agent, mut session) = setup(&model, &options, &input).await?;
    // Ctrl-C from here on cancels the run going on, never the chat.
    let (interrupt, mut interrupts) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        while tokio::signal::ctrl_c().await.is_ok() && interrupt.send(()).is_ok() {}
    });
    let prompt = std::io::stdin().is_terminal();
    if prompt {
        eprintln!("cookie chat with {model}. /exit or Ctrl-D to leave; Ctrl-C stops an answer.");
    }
    chat(&agent, &mut session, input, &mut std::io::stdout(), &mut interrupts, prompt).await.map_err(failed)
}

async fn replay(args: &[String]) -> Result<(), Failure> {
    let [path] = args else { return Err(Failure::Usage("cookie replay needs one session file".into())) };
    let recorded = Session::load(path).await.map_err(|e| failed(format!("{path}: {e}")))?;
    match Replay::from_session(&recorded).run().await {
        Ok(replayed) => {
            println!("reproduced: {} messages", replayed.messages().len());
            Ok(())
        }
        Err(Error::Replay(what)) => {
            println!("{what}");
            Err(Failure::Run(String::new()))
        }
        Err(error) => Err(failed(error)),
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let rest = args.get(1..).unwrap_or_default();
    let ended = match args.first().map(String::as_str) {
        Some("--version") => {
            println!("cookie {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Some("serve") => serve(BufReader::new(tokio::io::stdin()), tokio::io::stdout(), |request| Agent::new(&request.model)).await.map_err(failed),
        Some("run") => run(rest).await,
        Some("chat") => chat_command(rest).await,
        Some("replay") => replay(rest).await,
        _ => Err(Failure::Usage(String::new())),
    };
    let code = match ended {
        Ok(()) => 0,
        Err(Failure::Usage(message)) if message.is_empty() => {
            eprintln!("{USAGE}");
            2
        }
        Err(Failure::Usage(message)) => {
            eprintln!("cookie: {message}\n{USAGE}");
            2
        }
        Err(Failure::Run(message)) => {
            if !message.is_empty() {
                eprintln!("cookie: {message}");
            }
            1
        }
    };
    std::process::exit(code);
}
