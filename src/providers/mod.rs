//! `provider:model` → a provider. No defaults: an unknown name is an error.

use std::sync::Arc;

use crate::{error::{Error, Result}, model_id::ModelId, provider::Provider};

pub mod anthropic;
#[cfg(feature = "bedrock")]
pub mod bedrock;
#[cfg(feature = "bedrock")]
pub mod eventstream;
pub mod failover;
mod fence;
pub mod fallback;
pub mod gemini;
pub mod openai;
pub mod scripted;
mod sse;

pub fn resolve(id: &ModelId) -> Result<Arc<dyn Provider>> {
    match id.provider.as_str() {
        "anthropic" => Ok(Arc::new(anthropic::AnthropicProvider::from_env()?)),
        "openai" => Ok(Arc::new(openai::OpenAiProvider::openai_from_env()?)),
        "gemini" => Ok(Arc::new(gemini::GeminiProvider::from_env()?)),
        "ollama" => Ok(Arc::new(openai::OpenAiProvider::ollama_from_env())),
        "openrouter" => Ok(Arc::new(openai::OpenAiProvider::openrouter_from_env()?)),
        #[cfg(feature = "bedrock")]
        "bedrock" => Ok(Arc::new(bedrock::BedrockProvider::from_env()?)),
        #[cfg(not(feature = "bedrock"))]
        "bedrock" => Err(Error::UnknownProvider("bedrock (enable the `bedrock` cargo feature)".into())),
        // Bedrock's models through Enkeon's gateway, on Enkeon credits (same wire, a bearer key).
        #[cfg(feature = "bedrock")]
        "enkeon" => Ok(Arc::new(bedrock::BedrockProvider::enkeon_from_env()?)),
        other => Err(Error::UnknownProvider(other.to_string())),
    }
}

/// The HTTP client every provider uses. A server that connects but goes
/// quiet fails after the read timeout instead of hanging the run; requests
/// never follow a redirect, so a key header can't be carried elsewhere.
///
/// One client for the whole process (a clone shares its connection pool):
/// providers are made per run, and a client per run paid a fresh TCP + TLS
/// handshake on every first model call. Shared, the second run reuses the
/// first run's connection, and `warm` can open one ahead of a run.
// ponytail: a pooled connection belongs to the tokio runtime that opened it, so
// this assumes one runtime per process (true of `cookie` and `cookie serve`);
// tests get a client each, because every #[tokio::test] has its own runtime.
pub(crate) fn http_client() -> reqwest::Client {
    if cfg!(test) {
        return new_http_client(std::time::Duration::from_secs(1));
    }
    static SHARED: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    SHARED.get_or_init(|| new_http_client(std::time::Duration::from_secs(120))).clone()
}

fn new_http_client(read: std::time::Duration) -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(10))
        .read_timeout(read)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("a TLS backend is compiled in")
}

/// The host a model is called on, for `warm`: nil for a provider that is not
/// worth warming (a local server) or that can't be placed yet.
pub fn warm_url(id: &ModelId) -> Option<String> {
    let var = |name: &str| std::env::var(name).ok().filter(|v| !v.is_empty());
    match id.provider.as_str() {
        "anthropic" => Some(var("ANTHROPIC_BASE_URL").unwrap_or_else(|| "https://api.anthropic.com".into())),
        "openai" => Some("https://api.openai.com".into()),
        "gemini" => Some("https://generativelanguage.googleapis.com".into()),
        "openrouter" => Some("https://openrouter.ai".into()),
        #[cfg(feature = "bedrock")]
        "bedrock" => {
            let region = bedrock::region_for_model(var("AWS_REGION").or_else(|| var("AWS_DEFAULT_REGION")).as_deref(), &id.model).ok()?;
            Some(format!("https://bedrock-runtime.{region}.amazonaws.com"))
        }
        _ => None,
    }
}

/// Opens (or keeps) a pooled connection to the model's host, so the run that
/// follows skips the DNS, TCP and TLS round trips. Cookie for Mac asks for
/// this when the talk key goes down: the handshakes then overlap the
/// person's speech. Unauthenticated and bodiless (a HEAD of the root); its
/// status is ignored — only the connection matters. Returns whether the host
/// answered at all.
pub async fn warm(id: &ModelId) -> bool {
    let Some(url) = warm_url(id) else { return false };
    http_client().head(url).timeout(std::time::Duration::from_secs(10)).send().await.is_ok()
}

/// An HTTP failure, keeping the status even when the body isn't JSON. A
/// request refused because the conversation is longer than the model's
/// window is said as itself, so the run can summarise and send it again.
pub fn http_error(status: u16, body: &str) -> Error {
    if context_full(status, body) {
        return Error::ContextFull;
    }
    let detail: String = body.chars().take(500).collect();
    let said = format!("HTTP {status}: {detail}");
    // Throttled, timed out, overloaded (529) or broken on their side.
    if matches!(status, 408 | 429 | 500..=599) {
        return Error::Unavailable(said);
    }
    Error::Provider(said)
}

/// Tries for a server error or a dropped connection.
pub const ATTEMPTS: u32 = 4;
/// Tries for a rate limit. Quotas are per minute, so a refusal now says
/// little about twenty seconds from now: a burst rides through the window
/// instead of failing the run.
pub const THROTTLED_ATTEMPTS: u32 = 7;
/// The longest single wait, whatever the provider's `retry-after` says.
const LONGEST_WAIT: std::time::Duration = std::time::Duration::from_secs(60);

/// Sends one request, retrying what is worth another try: throttling (429),
/// overload (529) and server errors, and connections that dropped before an
/// answer. Nothing has reached the caller yet, so a retry can't say anything
/// twice. A call that timed out is not sent again: it may still be running
/// at the provider, and a second one could pay twice. The provider's own
/// `retry-after` is honoured, up to a minute.
pub(crate) async fn send_retrying(build: impl Fn() -> reqwest::RequestBuilder) -> Result<reqwest::Response> {
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        let wait = match build().send().await {
            Ok(response) if response.status().is_success() => return Ok(response),
            Ok(response) => {
                let status = response.status().as_u16();
                let after = retry_after(response.headers());
                let text = response.text().await.unwrap_or_default();
                let error = http_error(status, &text);
                let throttled = status == 429;
                let limit = if throttled { THROTTLED_ATTEMPTS } else { ATTEMPTS };
                if !error.may_fall_back() || attempt >= limit {
                    return Err(error);
                }
                after.unwrap_or_else(|| if throttled { throttle_backoff(attempt) } else { backoff(attempt) })
            }
            Err(e) if e.is_builder() || e.is_timeout() || attempt >= ATTEMPTS => return Err(send_error(e)),
            Err(_) => backoff(attempt),
        };
        tracing::debug!(attempt, wait_ms = wait.as_millis() as u64, "model call retried");
        tokio::time::sleep(wait.min(LONGEST_WAIT)).await;
    }
}

/// `retry-after` in seconds (the form every model API sends), or
/// `retry-after-ms`, which OpenAI and Anthropic also send.
fn retry_after(headers: &reqwest::header::HeaderMap) -> Option<std::time::Duration> {
    let number = |name: &str| headers.get(name)?.to_str().ok()?.trim().parse::<f64>().ok().filter(|n| n.is_finite() && *n >= 0.0);
    number("retry-after-ms").map(|ms| std::time::Duration::from_millis(ms as u64)).or_else(|| number("retry-after").map(std::time::Duration::from_secs_f64))
}

fn jitter() -> f64 {
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
    f64::from(nanos % 1_000_000) / 1_000_000.0
}

/// "Full jitter": a random wait up to 1, 2, 4… s, so callers that failed
/// together don't retry together.
fn backoff(attempt: u32) -> std::time::Duration {
    std::time::Duration::from_secs(1 << attempt.saturating_sub(1).min(5)).mul_f64(jitter())
}

/// After throttling, "equal jitter": at least half of 2, 4, 8… s, so each
/// retry lands later in the window while callers still spread out.
fn throttle_backoff(attempt: u32) -> std::time::Duration {
    let cap = std::time::Duration::from_secs(1 << attempt.clamp(1, 5));
    cap / 2 + (cap / 2).mul_f64(jitter())
}

/// A request that never got an HTTP answer, or a reply cut off on the way:
/// the provider was out of reach, unless the request itself could not be built.
pub(crate) fn send_error(e: reqwest::Error) -> Error {
    if e.is_builder() {
        Error::Provider(e.to_string())
    } else {
        Error::Unavailable(e.to_string())
    }
}

/// How each API words "the input is longer than the window": a 400 (413 for
/// some) whose message says so. Providers give no code of their own for it
/// except OpenAI's `context_length_exceeded`.
fn context_full(status: u16, body: &str) -> bool {
    const SAID: [&str; 6] = [
        "context_length_exceeded",
        "maximum context length",
        "prompt is too long",
        "input is too long",
        "exceeds the maximum number of tokens",
        "model_context_window_exceeded",
    ];
    let body = body.to_lowercase();
    matches!(status, 400 | 413) && SAID.iter().any(|s| body.contains(s))
}

#[cfg(test)]
mod tests {
    use crate::Error;

    #[test]
    fn every_providers_full_context_refusal_is_context_full() {
        for (status, body) in [
            (400, r#"{"error":{"type":"invalid_request_error","message":"prompt is too long: 210000 tokens > 200000 maximum"}}"#),
            (400, r#"{"error":{"message":"This model's maximum context length is 128000 tokens.","code":"context_length_exceeded"}}"#),
            (400, r#"{"error":{"code":400,"message":"The input token count (1200000) exceeds the maximum number of tokens allowed (1048576)."}}"#),
            (400, r#"{"message":"Input is too long for requested model."}"#),
        ] {
            assert!(matches!(super::http_error(status, body), Error::ContextFull), "{body}");
        }
        assert!(matches!(super::http_error(400, r#"{"message":"messages: field required"}"#), Error::Provider(_)));
        assert!(matches!(super::http_error(500, "prompt is too long"), Error::Unavailable(_)), "only a refusal of the request says so");
    }

    #[test]
    fn only_a_provider_out_of_reach_may_fall_back() {
        for status in [408, 429, 500, 502, 503, 504, 529] {
            let e = super::http_error(status, "busy");
            assert!(e.may_fall_back(), "{status}");
            assert_eq!(e.kind(), "provider", "the kind a client counts is unchanged");
            assert!(e.to_string().contains(&status.to_string()));
        }
        for status in [400, 401, 403, 404, 422] {
            assert!(!super::http_error(status, "no").may_fall_back(), "{status}");
        }
        assert!(!super::http_error(400, "prompt is too long").may_fall_back(), "a full context is full everywhere");
        for e in [Error::ContextFull, Error::Cancelled, Error::MaxTokens, Error::Budget("x".into()), Error::Provider("x".into())] {
            assert!(!e.may_fall_back(), "{e}");
        }
    }

    /// A server that answers each connection with the next canned reply.
    async fn serve(replies: Vec<&'static str>) -> (String, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = hits.clone();
        tokio::spawn(async move {
            for reply in replies {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut buf = [0u8; 4096];
                let _ = socket.read(&mut buf).await;
                counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                socket.write_all(reply.as_bytes()).await.unwrap();
                let _ = socket.shutdown().await;
            }
        });
        (url, hits)
    }

    const THROTTLED: &str = "HTTP/1.1 429 Too Many Requests\r\nretry-after-ms: 5\r\ncontent-length: 4\r\nconnection: close\r\n\r\nslow";
    const OVERLOADED: &str = "HTTP/1.1 529 Overloaded\r\nretry-after: 0\r\ncontent-length: 4\r\nconnection: close\r\n\r\nbusy";
    const OK: &str = "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok";
    const REFUSED: &str = "HTTP/1.1 401 Unauthorized\r\ncontent-length: 3\r\nconnection: close\r\n\r\nkey";

    #[tokio::test]
    async fn a_throttled_or_overloaded_call_is_sent_again_until_it_answers() {
        let (url, hits) = serve(vec![THROTTLED, OVERLOADED, OK]).await;
        let client = super::http_client();
        let response = super::send_retrying(|| client.get(&url)).await.unwrap();
        assert_eq!(response.text().await.unwrap(), "ok");
        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn a_refusal_is_not_sent_again() {
        let (url, hits) = serve(vec![REFUSED, OK]).await;
        let client = super::http_client();
        let e = super::send_retrying(|| client.get(&url)).await.unwrap_err();
        assert!(e.to_string().contains("401"), "{e}");
        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn retries_stop_at_the_limit_and_say_the_last_error() {
        let (url, hits) = serve(vec![OVERLOADED; super::ATTEMPTS as usize + 2]).await;
        let client = super::http_client();
        let e = super::send_retrying(|| client.get(&url)).await.unwrap_err();
        assert!(e.may_fall_back(), "the caller may still try another model: {e}");
        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), super::ATTEMPTS as usize);
    }

    #[test]
    fn warming_names_the_host_the_model_is_called_on() {
        let id = |text: &str| crate::model_id::ModelId::parse(text).unwrap();
        assert_eq!(super::warm_url(&id("ollama:qwen3")), None, "a local server is not warmed");
        assert_eq!(super::warm_url(&id("openai:gpt-6")).as_deref(), Some("https://api.openai.com"));
        #[cfg(feature = "bedrock")]
        assert_eq!(
            super::warm_url(&id("bedrock:eu.anthropic.claude-sonnet-4-6")).as_deref(),
            Some("https://bedrock-runtime.eu-central-1.amazonaws.com")
        );
    }

    #[test]
    fn openrouter_is_a_known_provider_that_needs_its_key_and_takes_any_labs_model_name() {
        let id = crate::model_id::ModelId::parse("openrouter:anthropic/claude-sonnet-4.5").unwrap();
        assert_eq!(id.model, "anthropic/claude-sonnet-4.5", "the lab's name stays in the model");
        match super::resolve(&id) {
            Ok(_) => assert!(std::env::var("OPENROUTER_API_KEY").is_ok()),
            Err(crate::Error::Provider(m)) => assert!(m.contains("OPENROUTER_API_KEY"), "{m}"),
            Err(other) => panic!("{other}"),
        }
        assert_eq!(super::warm_url(&id).as_deref(), Some("https://openrouter.ai"));
    }

    #[test]
    fn gemini_is_a_known_provider_that_needs_its_key() {
        let id = crate::model_id::ModelId::parse("gemini:gemini-3.8-flash").unwrap();
        match super::resolve(&id) {
            Ok(_) => assert!(std::env::var("GEMINI_API_KEY").is_ok()),
            Err(crate::Error::Provider(m)) => assert!(m.contains("GEMINI_API_KEY"), "{m}"),
            Err(other) => panic!("{other}"),
        }
    }

    #[cfg(not(feature = "bedrock"))]
    #[test]
    fn bedrock_without_the_feature_says_which_feature_to_enable() {
        let id = crate::model_id::ModelId::parse("bedrock:eu.anthropic.claude-sonnet-4-6").unwrap();
        assert!(matches!(super::resolve(&id), Err(crate::Error::UnknownProvider(m)) if m.contains("`bedrock` cargo feature")));
    }
}
