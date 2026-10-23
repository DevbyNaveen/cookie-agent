//! Models tried in order when the one asked is out of reach: throttled,
//! overloaded, broken on its side or silent (`Error::Unavailable`), after
//! its provider's own retries. A request that was refused for what it is
//! (auth, validation, a full context) is never sent elsewhere, and neither is
//! one whose reply had already started reaching the caller: the next model
//! would say it again, differently.

use std::{
    collections::HashMap,
    sync::{Arc, LazyLock, Mutex},
    time::{Duration, Instant},
};

use async_trait::async_trait;

use crate::{
    error::Result,
    provider::{ModelRequest, ModelResponse, Provider, ProviderEvent},
};

/// How long a model that was out of reach is tried after the others.
pub const COOLDOWN: Duration = Duration::from_secs(60);

// ponytail: one table per process, keyed by model name. A run that is a
// process of its own (`cookie serve` per job) remembers only its own turns;
// across processes the caller's breaker is the memory.
static COOLING: LazyLock<Mutex<HashMap<String, Instant>>> = LazyLock::new(Default::default);

pub struct Fallback {
    primary: Arc<dyn Provider>,
    /// After the model the request names, in order: `(model, provider)`.
    then: Vec<(String, Arc<dyn Provider>)>,
}

impl Fallback {
    pub fn new(primary: Arc<dyn Provider>, then: Vec<(String, Arc<dyn Provider>)>) -> Self {
        Self { primary, then }
    }

    /// The order to try at `now`: as listed, with models still cooling down
    /// moved to the back (in their listed order).
    fn order<'a>(&'a self, asked: &'a str, now: Instant) -> Vec<(&'a str, &'a Arc<dyn Provider>)> {
        let listed = std::iter::once((asked, &self.primary)).chain(self.then.iter().map(|(m, p)| (m.as_str(), p)));
        let cooling = COOLING.lock().expect("cooldown lock");
        let (warm, cold): (Vec<_>, Vec<_>) = listed.partition(|(m, _)| cooling.get(*m).is_none_or(|until| *until <= now));
        warm.into_iter().chain(cold).collect()
    }
}

fn cool(model: &str, now: Instant) {
    COOLING.lock().expect("cooldown lock").insert(model.to_string(), now + COOLDOWN);
}

fn warm(model: &str) {
    COOLING.lock().expect("cooldown lock").remove(model);
}

#[async_trait]
impl Provider for Fallback {
    async fn complete(&self, request: ModelRequest<'_>) -> Result<ModelResponse> {
        // Nothing streams, so nothing is reported: a fallback here is in the log.
        self.stream(request, &mut |_| {}).await
    }

    async fn stream(&self, request: ModelRequest<'_>, on: &mut (dyn FnMut(ProviderEvent) + Send)) -> Result<ModelResponse> {
        let order = self.order(request.model, Instant::now());
        let mut tried = order.into_iter().peekable();
        loop {
            let (model, provider) = tried.next().expect("the asked model is always in the order");
            let mut streamed = false;
            let attempt = ModelRequest {
                model,
                system: request.system,
                messages: request.messages,
                tools: request.tools.clone(),
                reasoning: request.reasoning,
                output_schema: request.output_schema,
            };
            let reply = provider
                .stream(attempt, &mut |event| {
                    streamed |= matches!(event, ProviderEvent::TextDelta(_) | ProviderEvent::ToolCallStarted { .. });
                    on(event)
                })
                .await;
            match reply {
                Err(error) if error.may_fall_back() => {
                    cool(model, Instant::now());
                    let Some((next, _)) = tried.peek().filter(|_| !streamed) else { return Err(error) };
                    let reason = error.to_string();
                    tracing::warn!(from = %model, to = %next, "error.type" = %crate::telemetry::error_type(&error), "model fell back");
                    on(ProviderEvent::FellBack { from: model.to_string(), to: next.to_string(), reason });
                }
                Ok(response) => {
                    warm(model);
                    return Ok(response);
                }
                Err(error) => return Err(error),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{error::Error, message::Message, providers::scripted::Scripted};
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Fails with `error` (when set) `times` times, then answers `answer`;
    /// optionally says a word first.
    struct Flaky {
        answer: &'static str,
        error: fn() -> Error,
        times: AtomicUsize,
        says_first: bool,
        calls: AtomicUsize,
        asked: Mutex<Vec<String>>,
    }

    fn flaky(answer: &'static str, error: fn() -> Error, times: usize) -> Arc<Flaky> {
        Arc::new(Flaky { answer, error, times: AtomicUsize::new(times), says_first: false, calls: AtomicUsize::new(0), asked: Mutex::new(Vec::new()) })
    }

    #[async_trait]
    impl Provider for Flaky {
        async fn complete(&self, _: ModelRequest<'_>) -> Result<ModelResponse> {
            unreachable!()
        }
        async fn stream(&self, request: ModelRequest<'_>, on: &mut (dyn FnMut(ProviderEvent) + Send)) -> Result<ModelResponse> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.asked.lock().unwrap().push(request.model.to_string());
            if self.says_first {
                on(ProviderEvent::TextDelta("The".into()));
            }
            if self.times.load(Ordering::SeqCst) > 0 {
                self.times.fetch_sub(1, Ordering::SeqCst);
                return Err((self.error)());
            }
            Ok(Scripted::text(self.answer))
        }
    }

    fn dynp(p: &Arc<Flaky>) -> Arc<dyn Provider> {
        p.clone()
    }

    fn busy() -> Error {
        Error::Unavailable("HTTP 529: overloaded".into())
    }

    async fn ask(f: &Fallback, model: &str) -> (Result<ModelResponse>, Vec<ProviderEvent>) {
        let history = vec![Message::user("hi")];
        let mut events = Vec::new();
        let out = f.stream(ModelRequest { model, system: "", messages: &history, tools: vec![], ..Default::default() }, &mut |e| events.push(e)).await;
        (out, events)
    }

    fn text(r: &Result<ModelResponse>) -> String {
        Message::assistant(r.as_ref().unwrap().content.clone()).text()
    }

    #[tokio::test]
    async fn an_out_of_reach_model_falls_to_the_next_in_order_and_says_so() {
        let (a, b, c) = (flaky("a", busy, 1), flaky("b", busy, 1), flaky("c", busy, 0));
        let f = Fallback::new(a.clone(), vec![("order-b".into(), dynp(&b)), ("order-c".into(), dynp(&c))]);
        let (out, events) = ask(&f, "order-a").await;
        assert_eq!(text(&out), "c");
        assert_eq!(*b.asked.lock().unwrap(), ["order-b"], "each model is asked by its own name");
        assert_eq!(events, vec![
            ProviderEvent::FellBack { from: "order-a".into(), to: "order-b".into(), reason: busy().to_string() },
            ProviderEvent::FellBack { from: "order-b".into(), to: "order-c".into(), reason: busy().to_string() },
        ]);
    }

    #[tokio::test]
    async fn a_refused_request_is_never_sent_to_another_model() {
        for error in [|| Error::Provider("HTTP 403: denied".into()), || Error::ContextFull, || Error::Provider("HTTP 400: bad".into())] {
            let (a, b) = (flaky("a", error, 1), flaky("b", busy, 0));
            let f = Fallback::new(a, vec![("refused-b".into(), dynp(&b))]);
            let (out, events) = ask(&f, "refused-a").await;
            assert!(out.is_err() && events.is_empty());
            assert_eq!(b.calls.load(Ordering::SeqCst), 0);
        }
    }

    #[tokio::test]
    async fn no_fallback_once_the_reply_has_started_reaching_the_caller() {
        let a = Arc::new(Flaky { says_first: true, ..Arc::into_inner(flaky("a", busy, 1)).unwrap() });
        let b = flaky("b", busy, 0);
        let f = Fallback::new(a, vec![("started-b".into(), dynp(&b))]);
        let (out, events) = ask(&f, "started-a").await;
        assert!(matches!(out, Err(Error::Unavailable(_))), "fails honestly: {out:?}");
        assert_eq!(events, vec![ProviderEvent::TextDelta("The".into())]);
        assert_eq!(b.calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn the_last_model_out_of_reach_is_the_error() {
        let f = Fallback::new(flaky("a", busy, 1), vec![("last-b".into(), dynp(&flaky("b", busy, 1)))]);
        let (out, events) = ask(&f, "last-a").await;
        assert!(matches!(out, Err(Error::Unavailable(_))));
        assert_eq!(events.len(), 1, "one fallback, then nothing left to try");
    }

    #[tokio::test]
    async fn a_model_that_failed_cools_down_before_it_is_tried_first_again() {
        let (a, b) = (flaky("a", busy, 1), flaky("b", busy, 0));
        let f = Fallback::new(a.clone(), vec![("cool-b".into(), dynp(&b))]);
        assert_eq!(text(&ask(&f, "cool-a").await.0), "b");
        // The next call goes to the warm model first; the cold one is not asked.
        let (out, events) = ask(&f, "cool-a").await;
        assert_eq!(text(&out), "b");
        assert!(events.is_empty());
        assert_eq!(a.calls.load(Ordering::SeqCst), 1);
        let now = Instant::now();
        assert_eq!(f.order("cool-a", now).iter().map(|(m, _)| *m).collect::<Vec<_>>(), ["cool-b", "cool-a"]);
        assert_eq!(f.order("cool-a", now + COOLDOWN).iter().map(|(m, _)| *m).collect::<Vec<_>>(), ["cool-a", "cool-b"], "and first again after it");
    }
}
