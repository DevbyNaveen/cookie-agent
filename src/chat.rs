//! A conversation in the terminal: one run per line, all on one session.
//! The prompt and the approvals read from one shared input, and only one of
//! them reads at a time: between runs the prompt, during a run the approver.

use std::{io::Write, sync::Arc};

use async_trait::async_trait;
use tokio::{
    io::{AsyncBufRead, AsyncBufReadExt},
    sync::{mpsc, Mutex},
};

use crate::{
    agent::{Agent, Event, RunControl},
    approval::{ApprovalRequest, Approver},
    error::Result,
    message::Message,
    session::Session,
};

/// The one reader both the prompt and the approver use.
pub type Input<R> = Arc<Mutex<R>>;

/// Asks a person on the shared input. With no person there (`present` is
/// false, e.g. stdin is not a terminal), it says no.
pub struct LineApprover<R> {
    input: Input<R>,
    present: bool,
}

impl<R> LineApprover<R> {
    pub fn new(input: Input<R>, present: bool) -> Self {
        Self { input, present }
    }
}

#[async_trait]
impl<R: AsyncBufRead + Unpin + Send> Approver for LineApprover<R> {
    async fn approve(&self, request: &ApprovalRequest) -> bool {
        if !self.present {
            eprintln!("\ncookie: `{}` needs a person and there is no terminal to ask; declined.", request.tool);
            return false;
        }
        eprint!("\n{}\n{}\nAllow? [y/N] ", request.reason, request.preview);
        let _ = std::io::stderr().flush();
        let mut answer = String::new();
        let _ = self.input.lock().await.read_line(&mut answer).await;
        matches!(answer.trim(), "y" | "Y" | "yes")
    }

    fn is_person(&self) -> bool {
        self.present
    }
}

/// Run each line of `input` on `session` until `/exit` or the input ends,
/// writing answers to `out` as they stream. A message on `interrupts`
/// cancels the run going on, never the chat; one sent between runs is
/// dropped. A run that fails is reported and the chat goes on.
pub async fn chat<R: AsyncBufRead + Unpin + Send>(
    agent: &Agent,
    session: &mut Session,
    input: Input<R>,
    out: &mut (dyn Write + Send),
    interrupts: &mut mpsc::UnboundedReceiver<()>,
    prompt: bool,
) -> Result<()> {
    loop {
        if prompt {
            eprint!("> ");
            let _ = std::io::stderr().flush();
        }
        let mut line = String::new();
        // Released before the run starts, so the approver can read.
        if input.lock().await.read_line(&mut line).await? == 0 {
            return Ok(());
        }
        let line = line.trim();
        if line == "/exit" {
            return Ok(());
        }
        if line.is_empty() {
            continue;
        }
        while interrupts.try_recv().is_ok() {}
        let control = RunControl::default();
        let mut streamed = false;
        let result = {
            let mut on_event = |event: Event| match event {
                Event::TextDelta(text) => {
                    streamed = true;
                    let _ = write!(out, "{text}");
                    let _ = out.flush();
                }
                Event::EnkeonUnavailable { reason } => eprintln!("cookie: running without Enkeon: {reason}"),
                _ => {}
            };
            let run = agent.run_streaming(session, Message::user(line), &control, &mut on_event);
            tokio::pin!(run);
            loop {
                tokio::select! {
                    result = &mut run => break result,
                    Some(()) = interrupts.recv() => control.cancel.cancel(),
                }
            }
        };
        match result {
            Ok(_) if streamed => writeln!(out)?,
            Ok(answer) => writeln!(out, "{answer}")?,
            Err(error) => {
                if streamed {
                    writeln!(out)?;
                }
                eprintln!("cookie: {error}");
            }
        }
        out.flush()?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        provider::{ModelRequest, ModelResponse, Provider},
        providers::scripted::Scripted,
        tool::{tool, Effect},
    };
    use serde_json::json;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{AsyncWriteExt, BufReader};

    type Pipe = BufReader<tokio::io::DuplexStream>;

    /// A shared input that will read `text`.
    fn input(text: &str) -> Input<Pipe> {
        let (mut write, read) = tokio::io::duplex(4096);
        let text = text.to_string();
        tokio::spawn(async move { write.write_all(text.as_bytes()).await });
        Arc::new(Mutex::new(BufReader::new(read)))
    }

    #[tokio::test]
    async fn each_line_is_a_run_on_the_same_session_until_exit() {
        let p = Arc::new(Scripted::new(vec![Scripted::text("one"), Scripted::text("two"), Scripted::text("never")]));
        let agent = Agent::with_provider(p.clone(), "m");
        let mut session = Session::in_memory();
        let mut out = Vec::new();
        let (_tx, mut rx) = mpsc::unbounded_channel();
        chat(&agent, &mut session, input("first\n\nsecond\n/exit\nthird\n"), &mut out, &mut rx, false).await.unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "one\ntwo\n");
        assert_eq!(session.messages().len(), 4, "both runs on one session");
        assert_eq!(p.seen()[1].len(), 3, "the second run saw the first");
    }

    #[tokio::test]
    async fn the_end_of_the_input_ends_the_chat() {
        let agent = Agent::with_provider(Arc::new(Scripted::new(vec![Scripted::text("hi")])), "m");
        let mut out = Vec::new();
        let (_tx, mut rx) = mpsc::unbounded_channel();
        chat(&agent, &mut Session::in_memory(), input("hello"), &mut out, &mut rx, false).await.unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "hi\n");
    }

    #[tokio::test]
    async fn an_approval_reads_the_next_line_from_the_same_input() {
        for (answer, sends) in [("y", 1), ("n", 0)] {
            let sent = Arc::new(AtomicUsize::new(0));
            let counter = sent.clone();
            let send = tool("send_email", "Send", json!({"type": "object"}), Effect::Outbound, move |_| {
                let counter = counter.clone();
                async move {
                    counter.fetch_add(1, Ordering::SeqCst);
                    Ok("sent".to_string())
                }
            })
            .guard("to");
            let p = Arc::new(Scripted::new(vec![
                Scripted::call("e1", "send_email", json!({"to": "anna@x.com"})),
                Scripted::text("done"),
                Scripted::text("next"),
            ]));
            let lines = input(&format!("email anna@x.com\n{answer}\nthanks\n"));
            let agent = Agent::with_provider(p, "m").tool(send).approver(LineApprover::new(lines.clone(), true));
            let mut session = Session::in_memory();
            let mut out = Vec::new();
            let (_tx, mut rx) = mpsc::unbounded_channel();
            chat(&agent, &mut session, lines, &mut out, &mut rx, false).await.unwrap();
            assert_eq!(sent.load(Ordering::SeqCst), sends, "answer {answer}");
            assert_eq!(String::from_utf8(out).unwrap(), "done\nnext\n", "the answer was not taken as a prompt");
        }
    }

    #[tokio::test]
    async fn with_no_person_present_an_approval_is_a_no_and_reads_nothing() {
        let send = tool("send_email", "Send", json!({"type": "object"}), Effect::Outbound, |_| async { Ok("sent".to_string()) }).guard("to");
        let p = Arc::new(Scripted::new(vec![Scripted::call("e1", "send_email", json!({"to": "anna@x.com"})), Scripted::text("not sent"), Scripted::text("ok")]));
        let lines = input("email anna@x.com\ny\n");
        let agent = Agent::with_provider(p, "m").tool(send).approver(LineApprover::new(lines.clone(), false));
        let mut out = Vec::new();
        let (_tx, mut rx) = mpsc::unbounded_channel();
        chat(&agent, &mut Session::in_memory(), lines, &mut out, &mut rx, false).await.unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "not sent\nok\n", "`y` was the next prompt, not an answer");
    }

    /// Hangs on its first call, answers after.
    struct HangsOnce(AtomicUsize);

    #[async_trait]
    impl Provider for HangsOnce {
        async fn complete(&self, _: ModelRequest<'_>) -> Result<ModelResponse> {
            if self.0.fetch_add(1, Ordering::SeqCst) == 0 {
                std::future::pending::<()>().await;
            }
            Ok(Scripted::text("back"))
        }
    }

    #[tokio::test]
    async fn an_interrupt_cancels_the_run_not_the_chat() {
        let agent = Agent::with_provider(Arc::new(HangsOnce(AtomicUsize::new(0))), "m");
        let (tx, mut rx) = mpsc::unbounded_channel();
        tx.send(()).unwrap(); // at the prompt: dropped, not kept for the next run
        let (mut write, read) = tokio::io::duplex(4096);
        let lines = Arc::new(Mutex::new(BufReader::new(read)));
        write.write_all(b"think\n").await.unwrap();
        let mut out = Vec::new();
        let mut session = Session::in_memory();
        let chatting = chat(&agent, &mut session, lines, &mut out, &mut rx, false);
        let driving = async {
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            tx.send(()).unwrap();
            write.write_all(b"again\n").await.unwrap();
            drop(write);
        };
        let (ended, ()) = tokio::time::timeout(std::time::Duration::from_secs(3), async { tokio::join!(chatting, driving) }).await.expect("chat hung");
        ended.unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "back\n");
        assert_eq!(session.messages().len(), 4, "the cancelled run's input and its stop note stay, then the second run");
        assert!(session.messages()[1].text().contains("stopped before answering"));
    }
}
