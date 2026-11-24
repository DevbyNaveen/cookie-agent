//! Two providers, one model: when the first fails in a way another provider
//! could get past (overloaded, rate limited, down, a refused key), the same
//! request goes to the second, with its own name for the model. A request the
//! first rejected as malformed isn't retried: the second would reject it too.
//! A streamed reply that already sent text isn't retried either, so the
//! person never sees half an answer followed by another whole one.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use async_trait::async_trait;

use crate::error::{Error, Result};
use crate::provider::{ModelRequest, ModelResponse, Provider, ProviderEvent};

pub struct Failover {
    primary: Arc<dyn Provider>,
    backup: Arc<dyn Provider>,
    /// The backup's name for the model (Bedrock and Anthropic name the same Claude differently).
    backup_model: String,
}

impl Failover {
    pub fn new(primary: Arc<dyn Provider>, backup: Arc<dyn Provider>, backup_model: impl Into<String>) -> Self {
        Self { primary, backup, backup_model: backup_model.into() }
    }
}

/// Worth trying elsewhere: anything but a request the provider called malformed.
pub fn worth_retrying(e: &Error) -> bool {
    match e {
        Error::Provider(m) => !["HTTP 400", "HTTP 404", "HTTP 413", "HTTP 422"].iter().any(|p| m.starts_with(p)),
        _ => false,
    }
}

fn on_backup<'a>(request: &ModelRequest<'a>, model: &'a str) -> ModelRequest<'a> {
    ModelRequest { model, system: request.system, messages: request.messages, tools: request.tools.clone(), reasoning: request.reasoning, output_schema: request.output_schema, prefix_ttl: request.prefix_ttl }
}

#[async_trait]
impl Provider for Failover {
    async fn complete(&self, request: ModelRequest<'_>) -> Result<ModelResponse> {
        let backup = on_backup(&request, &self.backup_model);
        match self.primary.complete(request).await {
            Err(e) if worth_retrying(&e) => {
                tracing::warn!(error = %e, "model provider failed; trying the backup");
                self.backup.complete(backup).await
            }
            other => other,
        }
    }

    async fn stream(&self, request: ModelRequest<'_>, on: &mut (dyn FnMut(ProviderEvent) + Send)) -> Result<ModelResponse> {
        let backup = on_backup(&request, &self.backup_model);
        let spoke = Arc::new(AtomicBool::new(false));
        let result = {
            let spoke = spoke.clone();
            let mut relay = |ev: ProviderEvent| {
                spoke.store(true, Ordering::SeqCst);
                on(ev)
            };
            self.primary.stream(request, &mut relay).await
        };
        match result {
            Err(e) if worth_retrying(&e) && !spoke.load(Ordering::SeqCst) => {
                tracing::warn!(error = %e, "model provider failed before answering; trying the backup");
                self.backup.stream(backup, on).await
            }
            other => other,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::Message;
    use std::sync::Mutex;

    struct Fake {
        fail: Option<&'static str>,
        seen: Mutex<Vec<String>>,
    }

    #[async_trait]
    impl Provider for Fake {
        async fn complete(&self, request: ModelRequest<'_>) -> Result<ModelResponse> {
            self.seen.lock().unwrap().push(request.model.to_string());
            match self.fail {
                Some(m) => Err(Error::Provider(m.into())),
                None => Ok(crate::providers::scripted::Scripted::text("ok")),
            }
        }
    }

    fn fake(fail: Option<&'static str>) -> Arc<Fake> {
        Arc::new(Fake { fail, seen: Mutex::new(Vec::new()) })
    }

    async fn ask(f: &Failover) -> Result<ModelResponse> {
        let messages = [Message::user("hi")];
        f.complete(ModelRequest { model: "claude-a", system: "", messages: &messages, tools: Vec::new(), reasoning: None, output_schema: None, prefix_ttl: None }).await
    }

    #[tokio::test]
    async fn an_outage_goes_to_the_backup_under_its_own_model_name() {
        let (a, b) = (fake(Some("HTTP 529: overloaded")), fake(None));
        let f = Failover::new(a.clone(), b.clone(), "eu.claude-a");
        assert!(ask(&f).await.is_ok());
        assert_eq!(*a.seen.lock().unwrap(), ["claude-a"]);
        assert_eq!(*b.seen.lock().unwrap(), ["eu.claude-a"]);
    }

    #[tokio::test]
    async fn a_malformed_request_is_not_sent_twice() {
        let (a, b) = (fake(Some("HTTP 400: bad tool schema")), fake(None));
        let f = Failover::new(a, b.clone(), "x");
        assert!(ask(&f).await.is_err());
        assert!(b.seen.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn when_both_fail_the_backups_reason_is_given() {
        let f = Failover::new(fake(Some("HTTP 503: down")), fake(Some("HTTP 429: slow down")), "x");
        assert!(ask(&f).await.unwrap_err().to_string().contains("429"));
    }

    #[test]
    fn what_counts_as_worth_retrying() {
        assert!(worth_retrying(&Error::Provider("HTTP 401: bad key".into())));
        assert!(worth_retrying(&Error::Provider("error sending request: connection refused".into())));
        assert!(!worth_retrying(&Error::Provider("HTTP 422: nope".into())));
        assert!(!worth_retrying(&Error::Cancelled), "a person stopping it isn't a failure");
    }
}
