//! Replay a recorded session: the model's replies and the tools' results come
//! from the log, so nothing is called. `Replay::run` reproduces every run and
//! says where it diverged; `ReplayProvider` alone replays the model against
//! tools of your choosing, for evals.

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde_json::{json, Value};
use tokio_util::sync::CancellationToken;

use crate::{
    agent::Agent,
    budget::Budget,
    error::{Error, Result},
    message::{Content, Message, Role},
    provider::{ModelRequest, ModelResponse, Provider, StopReason, Usage},
    session::Session,
    tool::{valid_tool_name, Effect, Tool, ToolSpec},
};

/// The recorded messages, without summaries: compaction only changes what a
/// model was shown, so it is not replayed. `number` maps each kept message
/// back to its place in the session (1-based).
#[derive(Clone)]
struct Log {
    messages: Vec<Message>,
    number: Vec<usize>,
}

impl Log {
    fn of(session: &Session) -> Arc<Self> {
        let (number, messages) =
            session.messages().iter().enumerate().filter(|(_, m)| m.summary_of().is_none()).map(|(i, m)| (i + 1, m.clone())).unzip();
        Arc::new(Self { messages, number })
    }

    /// The session's own number for kept message `index`, or one past the end.
    fn at(&self, index: usize) -> usize {
        self.number.get(index).copied().unwrap_or_else(|| self.number.last().copied().unwrap_or(0) + 1)
    }

    /// Where `replayed` first differs from the first `upto` recorded
    /// messages, as an error.
    fn compare(&self, replayed: &[Message], upto: usize) -> Option<Error> {
        let recorded = &self.messages[..upto.min(self.messages.len())];
        let index = (0..replayed.len().max(recorded.len())).find(|&i| replayed.get(i) != recorded.get(i))?;
        Some(Error::Replay(format!(
            "diverged at message {}: the recording has {}, the replay has {}",
            self.at(index),
            describe(recorded.get(index)),
            describe(replayed.get(index)),
        )))
    }
}

fn describe(message: Option<&Message>) -> String {
    let Some(message) = message else { return "nothing".into() };
    let mut content = serde_json::to_string(message.content()).unwrap_or_default();
    if content.chars().count() > 120 {
        content = content.chars().take(120).collect::<String>() + "…";
    }
    let role = match message.role() {
        Role::User => "user",
        Role::Assistant => "assistant",
    };
    format!("{role} {content}")
}

/// A run starts at each message the caller gave: anything from the user's
/// side that is not tool results.
fn is_input(message: &Message) -> bool {
    message.role() == Role::User && !message.content().iter().any(|c| matches!(c, Content::ToolResult { .. }))
}

/// Answers each model call with the reply the recording has after the same
/// history. A different history is an error naming the first difference.
pub struct ReplayProvider(Arc<Log>);

impl ReplayProvider {
    pub fn from_session(session: &Session) -> Self {
        Self(Log::of(session))
    }
}

#[async_trait]
impl Provider for ReplayProvider {
    async fn complete(&self, request: ModelRequest<'_>) -> Result<ModelResponse> {
        let log = &self.0;
        let asked = request.messages.len();
        if let Some(error) = log.compare(request.messages, asked) {
            return Err(error);
        }
        match log.messages.get(asked) {
            Some(reply) if reply.role() == Role::Assistant => Ok(ModelResponse {
                content: reply.content().to_vec(),
                stop: if reply.tool_calls().next().is_some() { StopReason::ToolUse } else { StopReason::EndTurn },
                usage: Usage::default(),
            }),
            next => Err(Error::Replay(format!(
                "diverged at message {}: the replay asked the model for a reply, the recording has {}",
                log.at(asked),
                describe(next),
            ))),
        }
    }
}

/// One recorded call: its arguments and result, and whether a replay used it.
struct Recorded {
    args: Value,
    output: String,
    is_error: bool,
    used: bool,
}

/// Stands in for a tool: returns the recorded result for a call with the
/// same arguments, each recorded call once, in order.
struct ReplayTool {
    spec: ToolSpec,
    calls: Mutex<Vec<Recorded>>,
}

#[async_trait]
impl Tool for ReplayTool {
    fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    async fn call(&self, args: Value) -> std::result::Result<String, String> {
        let mut calls = self.calls.lock().expect("replay lock");
        let Some(call) = calls.iter_mut().find(|c| !c.used && c.args == args) else {
            return Err(format!("Replay: the recording has no `{}` call with these arguments: {args}", self.spec.name));
        };
        call.used = true;
        if call.is_error {
            Err(call.output.clone())
        } else {
            Ok(call.output.clone())
        }
    }
}

/// Everything needed to run a recorded session again without a model or tools.
pub struct Replay(Arc<Log>);

impl Replay {
    pub fn from_session(session: &Session) -> Self {
        Self(Log::of(session))
    }

    pub fn provider(&self) -> ReplayProvider {
        ReplayProvider(self.0.clone())
    }

    /// One tool per name the model called, answering with the recorded
    /// results. They are `Read` with no guards, so the gates pass every call
    /// through and the recorded outcome (a refusal included) comes back as it
    /// was; the loop labels it as it did the first time.
    pub fn tools(&self) -> Vec<Arc<dyn Tool>> {
        let messages = &self.0.messages;
        let mut tools: Vec<ReplayTool> = Vec::new();
        for (index, message) in messages.iter().enumerate() {
            for (id, name, args) in message.tool_calls() {
                let result = messages[index + 1..].iter().flat_map(|m| m.content()).find_map(|c| match c {
                    Content::ToolResult { id: done, output, is_error } if done == id => Some((output.clone(), *is_error)),
                    _ => None,
                });
                let (Some((output, is_error)), true) = (result, valid_tool_name(name)) else { continue };
                let recorded = Recorded { args: args.clone(), output, is_error, used: false };
                match tools.iter_mut().find(|t| t.spec.name == name) {
                    Some(tool) => tool.calls.get_mut().expect("replay lock").push(recorded),
                    None => tools.push(ReplayTool {
                        spec: ToolSpec {
                            name: name.to_string(),
                            description: "Replayed from a recorded session.".into(),
                            schema: json!({"type": "object"}),
                            effect: Effect::Read,
                            guarded_args: Vec::new(),
                            parallel_safe: false,
                            delegates: false,
                        },
                        calls: Mutex::new(vec![recorded]),
                    }),
                }
            }
        }
        tools.into_iter().map(|t| Arc::new(t) as Arc<dyn Tool>).collect()
    }

    /// Run every recorded input again, in memory. `Ok` with the replayed
    /// session if it came out the same; `Error::Replay` naming the first
    /// message that differs otherwise.
    pub async fn run(&self) -> Result<Session> {
        let agent = Agent::with_provider(Arc::new(self.provider()), "replay")
            .tools(self.tools())
            .without_enkeon()
            // The recording's own limits stopped it where they did; the replay
            // stops there too, because the recording has no reply past it.
            .budget(Budget { max_steps: usize::MAX, max_tokens: u64::MAX, max_dollars: None });
        let log = &self.0;
        let mut session = Session::in_memory();
        let mut stopped: Option<String> = None;
        for input in log.messages.iter().filter(|m| is_input(m)) {
            // A run that ends where its recording ended stops on the provider's
            // "no reply here"; one that went elsewhere differs in the session.
            stopped = match agent.run_in(&mut session, input.clone(), &CancellationToken::new()).await {
                // The provider's own report says no more than the comparison below.
                Ok(_) | Err(Error::Replay(_)) => None,
                Err(error) => Some(error.to_string()),
            };
            if let Some(error) = log.compare(session.messages(), session.messages().len()) {
                return Err(with_reason(error, &stopped));
            }
        }
        match log.compare(session.messages(), log.messages.len()) {
            Some(error) => Err(with_reason(error, &stopped)),
            None => Ok(session),
        }
    }
}

/// Adds why the replayed run before stopped, when it did.
fn with_reason(error: Error, stopped: &Option<String>) -> Error {
    match (error, stopped) {
        (Error::Replay(what), Some(why)) => Error::Replay(format!("{what} (the replayed run stopped: {why})")),
        (error, _) => error,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        approval::FnApprover,
        providers::scripted::Scripted,
        tool::tool,
    };
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn weather(answer: &'static str) -> impl Tool {
        tool("weather", "Weather for a city", json!({"type": "object"}), Effect::Read, move |args| async move {
            Ok(format!("{}: {answer}", args["city"].as_str().unwrap_or("?")))
        })
        .parallel_safe()
    }

    fn failing() -> impl Tool {
        tool("flaky", "Fails", json!({"type": "object"}), Effect::Read, |_| async move { Err("down".to_string()) })
    }

    fn send_email(sent: Arc<AtomicUsize>) -> impl Tool {
        tool("send_email", "Send an email", json!({"type": "object"}), Effect::Outbound, move |_| {
            let sent = sent.clone();
            async move {
                sent.fetch_add(1, Ordering::SeqCst);
                Ok("sent".to_string())
            }
        })
        .guard("to")
    }

    /// Records three runs with tools (parallel calls, an error, a declined
    /// send, a refused recipient, an unknown tool) to a file.
    async fn record(path: &std::path::Path) {
        let sent = Arc::new(AtomicUsize::new(0));
        let p = Arc::new(Scripted::new(vec![
            Scripted::call_many(&[("c1", "weather", json!({"city": "Riga"})), ("c2", "weather", json!({"city": "Oslo"}))]),
            Scripted::text("Riga 9, Oslo 4."),
            Scripted::call_many(&[("c3", "flaky", json!({})), ("c4", "send_email", json!({"to": "anna@x.com"}))]),
            Scripted::call("c5", "send_email", json!({"to": "evil@x.com"})),
            Scripted::call("c6", "nope", json!({})),
            Scripted::text("Not sent."),
            Scripted::call("c7", "weather", json!({"city": "Riga"})),
            Scripted::text("Still 9."),
        ]));
        let agent = Agent::with_provider(p, "m")
            .tool(weather("9°C"))
            .tool(failing())
            .tool(send_email(sent.clone()))
            .approver(FnApprover(|_: &crate::ApprovalRequest| false));
        let mut session = Session::open(path).await.unwrap();
        for input in ["weather in Riga and Oslo?", "email anna@x.com", "and Riga again?"] {
            agent.run_in(&mut session, Message::user(input), &CancellationToken::new()).await.unwrap();
        }
        assert_eq!(sent.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn a_recorded_run_with_tools_replays_to_the_same_session() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rec.jsonl");
        record(&path).await;
        let recorded = Session::load(&path).await.unwrap();
        let replayed = Replay::from_session(&recorded).run().await.unwrap();
        assert_eq!(replayed.messages(), recorded.messages());
        assert!(recorded.messages().len() > 10);
    }

    #[tokio::test]
    async fn a_cancelled_run_and_a_crash_mid_call_replay_too() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("stop.jsonl");
        let cancel = CancellationToken::new();
        let stopper = cancel.clone();
        let stops = tool("stops", "Cancels the run", json!({"type": "object"}), Effect::Read, move |_| {
            let stopper = stopper.clone();
            async move {
                stopper.cancel();
                Ok("done".to_string())
            }
        });
        let p = Arc::new(Scripted::new(vec![Scripted::call("c1", "stops", json!({})), Scripted::text("after")]));
        let agent = Agent::with_provider(p, "m").tool(stops);
        let mut session = Session::open(&path).await.unwrap();
        assert!(agent.run_in(&mut session, Message::user("go"), &cancel).await.is_err());
        agent.run_in(&mut session, Message::user("again"), &CancellationToken::new()).await.unwrap();
        // A crash between a call and its result: the next open repairs it.
        session.append(Message::user("weather?")).await.unwrap();
        session.append(Message::assistant(vec![Content::ToolCall { id: "c9".into(), name: "weather".into(), args: json!({}) }])).await.unwrap();
        drop(session);
        let mut session = Session::open(&path).await.unwrap();
        let p = Arc::new(Scripted::new(vec![Scripted::text("fine")]));
        Agent::with_provider(p, "m").run_in(&mut session, Message::user("still there?"), &CancellationToken::new()).await.unwrap();
        drop(session);

        let recorded = Session::load(&path).await.unwrap();
        let replayed = Replay::from_session(&recorded).run().await.unwrap();
        assert_eq!(replayed.messages(), recorded.messages());
    }

    #[tokio::test]
    async fn a_different_tool_result_is_a_divergence_named_by_message() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rec.jsonl");
        record(&path).await;
        let recorded = Session::load(&path).await.unwrap();
        // The recorded model against a tool that answers differently.
        let agent = Agent::with_provider(Arc::new(ReplayProvider::from_session(&recorded)), "m").tool(weather("12°C"));
        let error = agent.run("weather in Riga and Oslo?").await.unwrap_err();
        let Error::Replay(message) = error else { panic!("{error}") };
        assert!(message.contains("message 3") && message.contains("9°C") && message.contains("12°C"), "{message}");
    }

    #[tokio::test]
    async fn a_call_the_recording_does_not_have_is_refused_by_name() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rec.jsonl");
        record(&path).await;
        let tools = Replay::from_session(&Session::load(&path).await.unwrap()).tools();
        let weather = tools.iter().find(|t| t.spec().name == "weather").unwrap();
        assert_eq!(weather.call(json!({"city": "Riga"})).await.unwrap(), "Riga: 9°C");
        assert_eq!(weather.call(json!({"city": "Riga"})).await.unwrap(), "Riga: 9°C", "recorded twice");
        let refused = weather.call(json!({"city": "Riga"})).await.unwrap_err();
        assert!(refused.contains("no `weather` call") && refused.contains("Riga"), "{refused}");
        let flaky = tools.iter().find(|t| t.spec().name == "flaky").unwrap();
        assert_eq!(flaky.call(json!({})).await.unwrap_err(), "down", "a recorded error stays an error");
    }

    #[tokio::test]
    async fn a_log_the_loop_would_not_have_written_diverges_where_it_differs() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("odd.jsonl");
        let mut session = Session::open(&path).await.unwrap();
        session.append(Message::user("hi")).await.unwrap();
        session.append(Message::assistant(vec![Content::ToolCall { id: "c1".into(), name: "bad name".into(), args: json!({}) }])).await.unwrap();
        // The loop answers a call to an invalid name with "There is no tool called"; this log says otherwise.
        let results = vec![Content::ToolResult { id: "c1".into(), output: "fine".into(), is_error: false }];
        session
            .append(Message::tool_results(results, crate::label::Origin::Untrusted(crate::label::Source::Tool("bad name".into()))))
            .await
            .unwrap();
        session.append(Message::assistant(vec![Content::Text { text: "ok".into() }])).await.unwrap();
        drop(session);
        let Err(Error::Replay(message)) = Replay::from_session(&Session::load(&path).await.unwrap()).run().await else {
            panic!("replayed without diverging")
        };
        assert!(message.contains("message 3") && message.contains("fine") && message.contains("There is no tool"), "{message}");
    }
}
