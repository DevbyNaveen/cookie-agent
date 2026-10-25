//! `cookie run <provider:model> <prompt>` — one run in the terminal.
//! `cookie chat <provider:model>` — a conversation, one run per line.
//! `cookie replay <session.jsonl>` — run a recording again from its log.
//! `cookie serve` — the harness over stdio, one JSON object per line.
//! `cookie local [folder]` — Cookie on your machine: your key, your folder, the web.

use std::{
    io::{IsTerminal, Write},
    sync::Arc,
};

use cookie_harness::{
    chat::{chat, Input, LineApprover},
    local,
    serve::serve,
    Agent, Error, Event, Message, Policy, Replay, RunControl, Session,
};
use tokio::{
    io::{BufReader, Stdin},
    sync::{mpsc, Mutex},
};

const USAGE: &str = "usage:
  cookie local [folder] [--model provider:model] [--permission ask|full] [--session FILE] [--instructions TEXT] [--no-enkeon] [--fallback-model provider:model]...
  cookie page [folder] [--model provider:model] [--permission ask|full] [--port 4747] [--home DIR] [--page DIR]
  cookie run <provider:model> <prompt> [--session FILE] [--instructions TEXT] [--no-enkeon] [--fallback-model provider:model]... [-- <prompt starting with ->]
  cookie chat <provider:model> [--session FILE] [--instructions TEXT] [--no-enkeon] [--fallback-model provider:model]...
  cookie replay <session.jsonl>
  cookie trace verify <file> --key <public key> [--head HASH --count N]
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
    /// Asked in order when the model before is out of reach.
    fallbacks: Vec<String>,
}

fn options(args: &[String]) -> Result<Options, Failure> {
    let mut options = Options { positional: Vec::new(), session: None, instructions: None, enkeon: true, fallbacks: Vec::new() };
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
            "--fallback-model" if flags => {
                options.fallbacks.push(args.next().ok_or(Failure::Usage("--fallback-model needs provider:model".into()))?.clone())
            }
            flag if flags && flag.starts_with("--") => return Err(Failure::Usage(format!("unknown flag `{flag}`"))),
            value => options.positional.push(value.to_string()),
        }
    }
    Ok(options)
}

/// The agent and session the options describe, asking on the terminal
/// through `input`, the one reader of stdin.
async fn setup(model: &str, options: &Options, input: &Input<BufReader<Stdin>>) -> Result<(Agent, Session), Failure> {
    let mut agent = Agent::new(model).map_err(failed)?.fallback_models(&options.fallbacks).map_err(failed)?.approver(LineApprover::new(input.clone(), std::io::stdin().is_terminal()));
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

const LOCAL_HELP: &str = "cookie local [folder] — Cookie on your own machine.

It answers from the folder you open it in (read only; default: this one),
the web through your search key if you set one, and pages it reads. It can't
send, delete or change your files. Without Enkeon it keeps a few notes between
conversations in ~/.cookie/NOTES.md (COOKIE_HOME moves it): a file you can read
and edit, refused when full rather than trimmed. With Enkeon, context goes there.

  --model provider:model   which model (default: anthropic:claude-sonnet-4-6
                           when ANTHROPIC_API_KEY is set; or COOKIE_MODEL)
  --permission ask|full    ask (default): a page address Cookie found in a page,
                           a file or a result is shown to you first; full: read it
  --session FILE           keep the conversation in a file and pick it up later
  --instructions TEXT      more instructions, after Cookie's own
  --no-enkeon              don't use Enkeon even if ENKEON_API_KEY is set

Web search, from the first key set: EXA_API_KEY, TINYFISH_API_KEY (free),
BRAVE_SEARCH_API_KEY. Without one, Cookie reads only pages you name.";

/// Where Cookie keeps what it keeps on this computer: COOKIE_HOME, else ~/.cookie.
fn cookie_home() -> Option<std::path::PathBuf> {
    std::env::var_os("COOKIE_HOME")
        .map(Into::into)
        .or_else(|| std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".cookie")))
}

/// `cookie local`: the chat, with Cookie's local tools, instructions and
/// permission, on a model picked from the environment when none is named.
async fn local_command(args: &[String]) -> Result<(), Failure> {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("{LOCAL_HELP}");
        return Ok(());
    }
    // Its own flags first; the rest are the ones `chat` takes.
    let (mut model, mut ask, mut rest) = (None, true, Vec::new());
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--model" => model = Some(it.next().ok_or(Failure::Usage("--model needs provider:model".into()))?.clone()),
            "--permission" => {
                ask = match it.next().map(String::as_str) {
                    Some("ask") => true,
                    Some("full") => false,
                    _ => return Err(Failure::Usage("--permission is `ask` or `full`".into())),
                }
            }
            _ => rest.push(arg.clone()),
        }
    }
    let mut options = options(&rest)?;
    let folder = match options.positional.as_slice() {
        [] => ".".to_string(),
        [folder] => folder.clone(),
        _ => return Err(Failure::Usage("cookie local takes one folder".into())),
    };
    let root = std::path::PathBuf::from(&folder);
    if !root.is_dir() {
        return Err(Failure::Usage(format!("`{folder}` isn't a folder")));
    }
    let model = match model {
        Some(m) => m,
        None => local::default_model().map_err(Failure::Run)?,
    };
    options.instructions = Some(match options.instructions.take() {
        Some(more) => format!("{}\n\n{more}", local::LOCAL_INSTRUCTIONS),
        None => local::LOCAL_INSTRUCTIONS.to_string(),
    });
    let input = stdin();
    let (agent, mut session) = setup(&model, &options, &input).await?;
    let search = local::Search::from_env();
    let shown = root.canonicalize().map(|p| p.display().to_string()).unwrap_or(folder);
    let web = search.as_ref().map_or("reading pages you name (set EXA_API_KEY or TINYFISH_API_KEY to search)".to_string(), |s| {
        format!("searching the web with {}", s.name())
    });
    let mut agent = agent.tools(local::tools(Some(root), search, ask));
    if let Some(home) = cookie_home() {
        agent = agent.notes(home.join("NOTES.md"));
    }
    if ask {
        agent = agent.policy(Policy::default().confirm_data());
    }
    let (interrupt, mut interrupts) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        while tokio::signal::ctrl_c().await.is_ok() && interrupt.send(()).is_ok() {}
    });
    let prompt = std::io::stdin().is_terminal();
    if prompt {
        eprintln!(
            "Cookie, on {model}. Reading {shown} (read only), {web}. It can't send, delete or change your files.\n\
             Try: \"What does this project do?\" · \"Where do we handle refunds?\" · \"Summarise https://…\"\n\
             /exit or Ctrl-D to leave; Ctrl-C stops an answer."
        );
    }
    chat(&agent, &mut session, input, &mut std::io::stdout(), &mut interrupts, prompt).await.map_err(failed)
}

const PAGE_HELP: &str = "cookie page [folder] — Cookie's page on your own machine.

The board, the conversations and the chat, as Enkeon's teams use them, for the
folder you open it in (read only; default: this one). Jobs run as in `cookie
local`; a page address Cookie found in what it read waits for your yes on the
page. Everything is kept in --home (default ~/.cookie): one file per job, one
per conversation, your routines (each job runs at its hour on this computer's
clock), SOUL.md, your own words on how Cookie should be, and NOTES.md, the
few notes Cookie keeps between conversations when Enkeon isn't connected.

  --model provider:model   the model (default: Anthropic when ANTHROPIC_API_KEY is set)
  --permission ask|full    ask before opening an address from what it read (default: ask)
  --port 4747              where it listens, on 127.0.0.1 only
  --home DIR               where jobs and conversations are kept
  --page DIR               the built page (cd web && npm run build → web/out); default: COOKIE_PAGE_DIR, else ./web/out
  --origin URL             another page origin allowed to ask (the dev server: http://localhost:4748 is allowed already)";

async fn page_command(args: &[String]) -> Result<(), Failure> {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("{PAGE_HELP}");
        return Ok(());
    }
    let (mut model, mut ask, mut port, mut home, mut page, mut origins, mut folder) = (None, true, 4747u16, None, None, Vec::new(), None);
    let mut it = args.iter();
    let value = |flag: &str, v: Option<&String>| v.cloned().ok_or_else(|| Failure::Usage(format!("{flag} needs a value")));
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--model" => model = Some(value("--model", it.next())?),
            "--permission" => {
                ask = match it.next().map(String::as_str) {
                    Some("ask") => true,
                    Some("full") => false,
                    _ => return Err(Failure::Usage("--permission is `ask` or `full`".into())),
                }
            }
            "--port" => port = value("--port", it.next())?.parse().map_err(|_| Failure::Usage("--port is a number".into()))?,
            "--home" => home = Some(std::path::PathBuf::from(value("--home", it.next())?)),
            "--page" => page = Some(std::path::PathBuf::from(value("--page", it.next())?)),
            "--origin" => origins.push(value("--origin", it.next())?.trim_end_matches('/').to_string()),
            flag if flag.starts_with("--") => return Err(Failure::Usage(format!("cookie page doesn't take {flag}"))),
            _ if folder.is_none() => folder = Some(arg.clone()),
            _ => return Err(Failure::Usage("cookie page takes one folder".into())),
        }
    }
    let folder = folder.unwrap_or_else(|| ".".into());
    let root = std::path::PathBuf::from(&folder);
    if !root.is_dir() {
        return Err(Failure::Usage(format!("`{folder}` isn't a folder")));
    }
    let model = match model {
        Some(m) => m,
        None => local::default_model().map_err(Failure::Run)?,
    };
    // A model that can't be reached is said now, not on the first job.
    Agent::new(&model).map_err(failed)?;
    let home = match home.or_else(cookie_home) {
        Some(home) => home,
        None => return Err(Failure::Usage("set --home".into())),
    };
    // The built page: given, or this repo's `web/out`, or `page/` beside the binary (a release
    // archive carries it there).
    let beside = std::env::current_exe().ok().and_then(|exe| exe.parent().map(|dir| dir.join("page")));
    let page_dir = page
        .or_else(|| std::env::var_os("COOKIE_PAGE_DIR").map(Into::into))
        .or_else(|| Some(std::path::PathBuf::from("web/out")).filter(|d| d.join("me").is_dir()))
        .or_else(|| beside.filter(|d| d.join("me").is_dir()));
    origins.extend(["http://localhost:4748".to_string(), "http://127.0.0.1:4748".to_string()]);
    std::fs::create_dir_all(&home).map_err(|e| failed(format!("{}: {e}", home.display())))?;
    let key = cookie_harness::page::trace_key(&home).map_err(failed)?.public();
    eprintln!("Each job's actions are signed into {}/runs/<job>.trace.jsonl (cookie trace verify <file> --key {key})", home.display());
    match &page_dir {
        Some(_) => eprintln!("Cookie's page: http://localhost:{port}{}", cookie_harness::page::PAGE_PATH),
        None => eprintln!("Cookie answers on http://127.0.0.1:{port}. For the page: cd web && npm run dev, then open http://localhost:4748"),
    }
    cookie_harness::page::serve(cookie_harness::page::PageOptions { root, model, ask, home, port, page_dir, origins })
        .await
        .map_err(failed)
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

/// `cookie trace verify <file> --key <public key>`: every record hashed,
/// chained and signed by that key; with `--head` and `--count` (as stored
/// when the run ended) the log must also end exactly there.
fn trace_command(args: &[String]) -> Result<(), Failure> {
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let ["verify", path, rest @ ..] = &args[..] else {
        return Err(Failure::Usage("cookie trace verify <file> --key <public key>".into()));
    };
    let (mut key, mut hash, mut count) = (None, None, None);
    let mut it = rest.iter();
    while let Some(flag) = it.next() {
        let value = it.next().ok_or_else(|| Failure::Usage(format!("{flag} needs a value")))?.to_string();
        match *flag {
            "--key" => key = Some(value),
            "--head" => hash = Some(value),
            "--count" => count = Some(value.parse::<u64>().map_err(|_| Failure::Usage("--count is a number".into()))?),
            other => return Err(Failure::Usage(format!("cookie trace verify doesn't take {other}"))),
        }
    }
    let key = key.ok_or(Failure::Usage("cookie trace verify needs --key".into()))?;
    let head = match (hash, count) {
        (Some(hash), Some(count)) => Some(cookie_harness::trace::Head { hash, count }),
        (None, None) => None,
        _ => return Err(Failure::Usage("--head and --count go together".into())),
    };
    let text = std::fs::read_to_string(path).map_err(|e| failed(format!("{path}: {e}")))?;
    let end = cookie_harness::trace::verify_text(&text, &key, head.as_ref()).map_err(|e| failed(format!("{path}: {e}")))?;
    println!("ok: {} records, head {}", end.count, end.hash);
    Ok(())
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
        Some("serve") => {
            // Spans and warnings as JSON on stderr, which whoever runs it reads.
            cookie_harness::telemetry::log_json_to_stderr("warn");
            serve(BufReader::new(tokio::io::stdin()), tokio::io::stdout(), |request| Agent::new(&request.model)).await.map_err(failed)
        }
        Some("local") => local_command(rest).await,
        Some("page") => page_command(rest).await,
        Some("run") => run(rest).await,
        Some("chat") => chat_command(rest).await,
        Some("replay") => replay(rest).await,
        Some("trace") => trace_command(rest),
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
