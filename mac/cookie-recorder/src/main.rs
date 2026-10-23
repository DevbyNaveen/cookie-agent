//! cookie-recorder — a meeting recorded on the Mac with no bot in the call.
//!
//! `record` starts a meeting on the gateway, captures the microphone and the
//! system audio on two channels (Opus in Ogg), uploads a minute at a time,
//! and stops on `stop` (or end of input) on stdin. `decide` and `get` are
//! the two calls after. Every state change is one JSON line on stdout; the
//! bearer comes from `COOKIE_TOKEN` and is never printed.

mod api;
mod audio;
mod upload;

use api::{Api, ApiError};
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};
use upload::Channel;

const USAGE: &str = "usage:
  cookie-recorder record --project <id> --title <title> [--site <site>]
  cookie-recorder decide --project <id> --meeting <id> --keep|--discard
  cookie-recorder get    --project <id> --meeting <id>
The bearer token is read from COOKIE_TOKEN.";

/// One minute per chunk, the extension's and the desktop app's rhythm.
const CHUNK_EVERY: Duration = Duration::from_secs(60);

/// One JSON line on stdout. The stdout lock is held for the whole line,
/// so lines from the audio, upload and main threads never interleave.
pub fn emit(v: &Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{v}");
    let _ = out.flush();
}

pub fn error_line(message: &str) -> Value {
    json!({ "state": "error", "message": message })
}

fn recording_line(id: &str, secs: u64, level: f32) -> Value {
    json!({ "state": "recording", "meeting_id": id, "secs": secs, "level": (level as f64 * 1000.0).round() / 1000.0 })
}

fn mic_only_line(id: &str, why: &str) -> Value {
    json!({ "state": "mic_only", "meeting_id": id, "message": format!("system audio unavailable, recording the microphone only: {why}") })
}

fn stopped_line(id: &str) -> Value {
    json!({ "state": "stopped", "meeting_id": id })
}

#[derive(Debug, PartialEq)]
enum Cmd {
    Record { project: String, title: String, site: String },
    Decide { project: String, meeting: String, action: &'static str },
    Get { project: String, meeting: String },
}

fn parse(args: &[String]) -> Result<Cmd, String> {
    let (sub, rest) = args.split_first().ok_or(USAGE)?;
    let mut flags: Vec<(&str, Option<&str>)> = Vec::new();
    let mut it = rest.iter().map(String::as_str).peekable();
    while let Some(a) = it.next() {
        match a {
            "--keep" | "--discard" => flags.push((a, None)),
            "--project" | "--title" | "--site" | "--meeting" => {
                let v = it.next().ok_or_else(|| format!("{a} needs a value"))?;
                flags.push((a, Some(v)));
            }
            other => return Err(format!("unknown argument {other}\n{USAGE}")),
        }
    }
    let val = |k: &str| flags.iter().rev().find(|(f, _)| *f == k).and_then(|(_, v)| *v).map(str::to_string);
    let has = |k: &str| flags.iter().any(|(f, _)| *f == k);
    let id = |k: &str| -> Result<String, String> {
        let v = val(k).ok_or_else(|| format!("{k} is required\n{USAGE}"))?;
        if api::valid_id(&v) { Ok(v) } else { Err(format!("{k} is not a valid id")) }
    };
    match sub.as_str() {
        "record" => Ok(Cmd::Record {
            project: id("--project")?,
            title: val("--title").ok_or_else(|| format!("--title is required\n{USAGE}"))?,
            site: val("--site").unwrap_or_else(|| "desktop".into()),
        }),
        "decide" => {
            let action = match (has("--keep"), has("--discard")) {
                (true, false) => "keep",
                (false, true) => "discard",
                _ => return Err("decide needs exactly one of --keep or --discard".into()),
            };
            Ok(Cmd::Decide { project: id("--project")?, meeting: id("--meeting")?, action })
        }
        "get" => Ok(Cmd::Get { project: id("--project")?, meeting: id("--meeting")? }),
        _ => Err(USAGE.into()),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = match parse(&args) {
        Ok(c) => c,
        Err(e) => {
            emit(&error_line(&e));
            std::process::exit(2);
        }
    };
    let token = std::env::var("COOKIE_TOKEN").unwrap_or_default();
    if token.trim().is_empty() {
        emit(&error_line("COOKIE_TOKEN is not set"));
        std::process::exit(2);
    }
    let api = match Api::new(api::DEFAULT_BASE, token.trim()) {
        Ok(a) => a,
        Err(e) => {
            emit(&error_line(&e));
            std::process::exit(1);
        }
    };
    let code = match cmd {
        Cmd::Record { project, title, site } => record(Arc::new(api), &project, &title, &site),
        Cmd::Decide { project, meeting, action } => print_answer(api.decide(&project, &meeting, action)),
        Cmd::Get { project, meeting } => print_answer(api.get(&project, &meeting)),
    };
    std::process::exit(code);
}

fn print_answer(r: Result<Value, ApiError>) -> i32 {
    match r {
        Ok(v) => {
            emit(&v);
            0
        }
        Err(e) => {
            emit(&error_line(&e.to_string()));
            1
        }
    }
}

#[derive(Debug, PartialEq)]
enum Control {
    Stop,
    /// A renewed access token for the next requests.
    Token(String),
    Ignore,
}

/// One line on stdin: `stop`, or `token <access token>`.
fn control(line: &str) -> Control {
    let line = line.trim();
    if line == "stop" {
        return Control::Stop;
    }
    match line.strip_prefix("token ").map(str::trim) {
        Some(token) if !token.is_empty() => Control::Token(token.to_string()),
        _ => Control::Ignore,
    }
}

/// Stop on the line `stop`, or when stdin closes (the parent went away);
/// take a renewed token from `token …` lines.
fn watch_stdin(stop: Arc<AtomicBool>, api: Arc<Api>) {
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            match line.as_deref().map(control) {
                Ok(Control::Stop) | Err(_) => break,
                Ok(Control::Token(token)) => api.set_token(&token),
                Ok(Control::Ignore) => {}
            }
        }
        stop.store(true, Ordering::Relaxed);
    });
}

/// A cut handed to the uploader: channel index (0 mic, 1 tab) and pages.
type Cut = (usize, Vec<u8>);

/// The uploader thread: owns both channels' seq and pending bytes, so a
/// slow upload never stalls the encoder or the once-a-second line. A
/// failure that more tries cannot fix (401, 403, the meeting no longer
/// recording) sets `fatal` so the recording stops instead of piling up
/// audio nobody will take.
fn uploader(api: Arc<Api>, project: String, id: String, rx: mpsc::Receiver<Cut>, fatal: Arc<AtomicBool>) -> std::thread::JoinHandle<Vec<String>> {
    std::thread::spawn(move || {
        let mut chans = [Channel::new("mic"), Channel::new("tab")];
        let flush = |ch: &mut Channel, last: bool| {
            if let Err(e) = ch.flush(&api, &project, &id) {
                let held = ch.pending_bytes();
                let what = if api::transient(&e) && !last {
                    format!("{} chunk {} did not upload ({e}); {held} bytes kept in memory, retrying with the next minute", ch.name, ch.seq)
                } else {
                    if !api::transient(&e) {
                        fatal.store(true, Ordering::Relaxed);
                    }
                    format!("{} chunk {} did not upload ({e}); {held} bytes lost", ch.name, ch.seq)
                };
                emit(&error_line(&what));
            }
        };
        for (i, bytes) in rx {
            chans[i].push(&bytes);
            if !fatal.load(Ordering::Relaxed) {
                flush(&mut chans[i], false);
            }
        }
        // The tails: one last attempt for anything still held.
        let mut lost = Vec::new();
        for ch in chans.iter_mut() {
            if ch.pending_bytes() > 0 && !fatal.load(Ordering::Relaxed) {
                flush(ch, true);
            }
            if ch.pending_bytes() > 0 {
                lost.push(format!("{}#{}", ch.name, ch.seq));
            }
        }
        lost
    })
}

fn record(api: Arc<Api>, project: &str, title: &str, site: &str) -> i32 {
    let row = match api.start(project, title, site) {
        Ok(r) => r,
        Err(e) => {
            emit(&error_line(&format!("could not start the meeting: {e}")));
            return 1;
        }
    };
    let id = row.get("id").and_then(Value::as_str).unwrap_or("").to_string();
    if id.is_empty() {
        emit(&error_line("the gateway made no meeting"));
        return 1;
    }

    let (mic_tx, mic_rx) = mpsc::channel::<Vec<f32>>();
    let (sys_tx, sys_rx) = mpsc::channel::<Vec<f32>>();
    let (mut handles, sys_warning) = match audio::start(mic_tx, sys_tx) {
        Ok(x) => x,
        Err(e) => {
            emit(&error_line(&format!("could not record: {e}")));
            // Nothing was recorded: stop marks the row failed, not orphaned.
            let _ = api.stop(project, &id, 0);
            return 1;
        }
    };
    let started = Instant::now();
    let mut mic = match audio::OggOpus::new(0x7472_6d69) {
        Ok(e) => e,
        Err(e) => {
            emit(&error_line(&e));
            handles.stop.store(true, Ordering::Relaxed);
            let _ = api.stop(project, &id, 0);
            return 1;
        }
    };
    let mut sys = match &sys_warning {
        None => match audio::OggOpus::new(0x7472_7379) {
            Ok(e) => Some(e),
            Err(e) => {
                emit(&mic_only_line(&id, &e));
                None
            }
        },
        Some(w) => {
            emit(&mic_only_line(&id, w));
            None
        }
    };

    let stop = Arc::new(AtomicBool::new(false));
    let fatal = Arc::new(AtomicBool::new(false));
    watch_stdin(stop.clone(), api.clone());
    let (cut_tx, cut_rx) = mpsc::channel::<Cut>();
    let up = uploader(api.clone(), project.to_string(), id.clone(), cut_rx, fatal.clone());

    let mut last_cut = Instant::now();
    let mut last_line: Option<Instant> = None;
    let drain = |mic: &mut audio::OggOpus, sys: &mut Option<audio::OggOpus>| {
        while let Ok(buf) = mic_rx.try_recv() {
            if let Err(e) = mic.push(&buf) {
                emit(&error_line(&format!("microphone encode: {e}")));
            }
        }
        if let Some(enc) = sys.as_mut() {
            while let Ok(buf) = sys_rx.try_recv() {
                if let Err(e) = enc.push(&buf) {
                    emit(&error_line(&format!("system audio encode: {e}")));
                }
            }
        }
    };
    let cut = |mic: &mut audio::OggOpus, sys: &mut Option<audio::OggOpus>, end: bool| {
        for (i, enc) in [Some(mic), sys.as_mut()].into_iter().enumerate() {
            let Some(enc) = enc else { continue };
            match enc.take(end) {
                Ok(bytes) if !bytes.is_empty() => {
                    let _ = cut_tx.send((i, bytes));
                }
                Ok(_) => {}
                Err(e) => emit(&error_line(&format!("{} encode: {e}", ["mic", "tab"][i]))),
            }
        }
    };
    while !stop.load(Ordering::Relaxed) && !fatal.load(Ordering::Relaxed) {
        drain(&mut mic, &mut sys);
        if last_cut.elapsed() >= CHUNK_EVERY {
            cut(&mut mic, &mut sys, false);
            last_cut = Instant::now();
        }
        if last_line.is_none_or(|t| t.elapsed() >= Duration::from_secs(1)) {
            let level = f32::from_bits(handles.level.load(Ordering::Relaxed));
            emit(&recording_line(&id, started.elapsed().as_secs(), level));
            last_line = Some(Instant::now());
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    // Stop: captures off first, then whatever they delivered, then the
    // tails closed at a page boundary (end-of-stream marked).
    let secs = started.elapsed().as_secs();
    handles.stop.store(true, Ordering::Relaxed);
    for t in std::mem::take(&mut handles.threads) {
        let _ = t.join();
    }
    drain(&mut mic, &mut sys);
    cut(&mut mic, &mut sys, true);
    drop(cut_tx);
    let lost = up.join().unwrap_or_else(|_| vec!["uploader crashed".into()]);
    if !lost.is_empty() {
        emit(&error_line(&format!("audio that never reached the gateway: {}", lost.join(", "))));
    }
    match api.stop(project, &id, secs) {
        Ok(_) => {
            emit(&stopped_line(&id));
            if lost.is_empty() && !fatal.load(Ordering::Relaxed) { 0 } else { 1 }
        }
        Err(e) => {
            emit(&error_line(&format!("could not stop the meeting: {e}")));
            1
        }
    }
}

#[cfg(test)]
mod tests {

    #[test]
    fn stdin_lines_stop_or_hand_over_a_fresh_token() {
        assert_eq!(control("stop"), Control::Stop);
        assert_eq!(control("  stop \n"), Control::Stop);
        assert_eq!(control("token tra_new123"), Control::Token("tra_new123".into()));
        assert_eq!(control("token "), Control::Ignore, "an empty token is ignored, never installed");
        assert_eq!(control("hello"), Control::Ignore);
    }

    #[test]
    fn a_fresh_token_is_used_by_the_next_request() {
        let api = api::Api::new("http://127.0.0.1:9", "tra_old").unwrap();
        assert_eq!(api.bearer(), "tra_old");
        api.set_token("tra_new");
        assert_eq!(api.bearer(), "tra_new");
    }
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn the_json_lines_have_the_agreed_shape() {
        assert_eq!(recording_line("mt_1", 61, 0.123456).to_string(), r#"{"level":0.123,"meeting_id":"mt_1","secs":61,"state":"recording"}"#);
        assert_eq!(error_line("boom"), json!({"state": "error", "message": "boom"}));
        assert_eq!(stopped_line("mt_1"), json!({"state": "stopped", "meeting_id": "mt_1"}));
        let m = mic_only_line("mt_1", "permission denied");
        assert_eq!(m["state"], "mic_only");
        assert!(m["message"].as_str().unwrap().contains("permission denied"));
        assert!(!recording_line("x", 0, 0.0).to_string().contains('\n'), "one line");
    }

    #[test]
    fn arguments_parse_into_the_three_commands() {
        assert_eq!(
            parse(&s(&["record", "--project", "p1", "--title", "Weekly sync"])).unwrap(),
            Cmd::Record { project: "p1".into(), title: "Weekly sync".into(), site: "desktop".into() }
        );
        assert_eq!(
            parse(&s(&["record", "--project", "p1", "--title", "t", "--site", "zoom"])).unwrap(),
            Cmd::Record { project: "p1".into(), title: "t".into(), site: "zoom".into() }
        );
        assert_eq!(
            parse(&s(&["decide", "--project", "p1", "--meeting", "m1", "--discard"])).unwrap(),
            Cmd::Decide { project: "p1".into(), meeting: "m1".into(), action: "discard" }
        );
        assert_eq!(parse(&s(&["get", "--project", "p1", "--meeting", "m1"])).unwrap(), Cmd::Get { project: "p1".into(), meeting: "m1".into() });
        assert!(parse(&s(&["decide", "--project", "p1", "--meeting", "m1", "--keep", "--discard"])).is_err());
        assert!(parse(&s(&["record", "--project", "p1"])).is_err(), "title required");
        assert!(parse(&s(&["get", "--project", "../x", "--meeting", "m1"])).is_err(), "ids are checked");
        assert!(parse(&s(&["record", "--token", "x"])).is_err(), "no token on argv");
        assert!(parse(&[]).is_err());
    }
}
