//! OpenTelemetry GenAI spans, emitted through `tracing`. Export them with
//! `tracing-opentelemetry`, which names each span from its `otel.name`.
//! Conventions: open-telemetry/semantic-conventions-genai (status:
//! Development). Message content is never recorded.

/// `gen_ai.provider.name` for a `provider:` prefix.
pub(crate) fn provider_name(prefix: &str) -> String {
    match prefix {
        "bedrock" => "aws.bedrock".into(),
        "gemini" => "gcp.gemini".into(),
        other => other.into(),
    }
}

/// `invoke_agent [{gen_ai.agent.name}]`, INTERNAL.
pub(crate) fn agent_span(name: Option<&str>, model: &str, provider: Option<&str>) -> tracing::Span {
    tracing::info_span!(
        "invoke_agent",
        "otel.name" = %name.map_or_else(|| "invoke_agent".to_string(), |n| format!("invoke_agent {n}")),
        "otel.kind" = "internal",
        "gen_ai.operation.name" = "invoke_agent",
        "gen_ai.agent.name" = name,
        "gen_ai.provider.name" = provider.unwrap_or("_OTHER"),
        "gen_ai.request.model" = %model,
        "error.type" = tracing::field::Empty,
    )
}

/// `chat {gen_ai.request.model}`, CLIENT. Every request streams.
pub(crate) fn chat_span(model: &str, provider: Option<&str>) -> tracing::Span {
    tracing::info_span!(
        "chat",
        "otel.name" = %format!("chat {model}"),
        "otel.kind" = "client",
        "gen_ai.operation.name" = "chat",
        "gen_ai.provider.name" = provider.unwrap_or("_OTHER"),
        "gen_ai.request.model" = %model,
        "gen_ai.request.stream" = true,
        "gen_ai.usage.input_tokens" = tracing::field::Empty,
        "gen_ai.usage.output_tokens" = tracing::field::Empty,
        "gen_ai.usage.cache_read.input_tokens" = tracing::field::Empty,
        "gen_ai.usage.cache_write.input_tokens" = tracing::field::Empty,
        "error.type" = tracing::field::Empty,
    )
}

/// Usage on success (input counts cached input, as the convention says;
/// providers report it apart), `error.type` on failure.
pub(crate) fn record_chat(span: &tracing::Span, response: &crate::Result<crate::provider::ModelResponse>) {
    match response {
        Ok(r) => {
            span.record("gen_ai.usage.input_tokens", r.usage.input_tokens + r.usage.cache_read_tokens + r.usage.cache_write_tokens);
            span.record("gen_ai.usage.output_tokens", r.usage.output_tokens);
            span.record("gen_ai.usage.cache_read.input_tokens", r.usage.cache_read_tokens);
            span.record("gen_ai.usage.cache_write.input_tokens", r.usage.cache_write_tokens);
        }
        Err(error) => {
            span.record("error.type", error_type(error));
        }
    }
}

/// `execute_tool {gen_ai.tool.name}`, INTERNAL.
pub(crate) fn tool_span(name: &str, id: &str) -> tracing::Span {
    tracing::info_span!(
        "execute_tool",
        "otel.name" = %format!("execute_tool {name}"),
        "otel.kind" = "internal",
        "gen_ai.operation.name" = "execute_tool",
        "gen_ai.tool.name" = %name,
        "gen_ai.tool.call.id" = %id,
        "error.type" = tracing::field::Empty,
    )
}

/// `error.type`: the error's kind, e.g. `Budget`, `Cancelled`.
pub(crate) fn error_type(error: &crate::Error) -> String {
    format!("{error:?}").split(['(', ' ', '{']).next().unwrap_or("_OTHER").to_string()
}

#[cfg(test)]
mod tests {
    use std::{
        collections::HashMap,
        sync::{Arc, Mutex},
    };

    use serde_json::json;
    use tracing::{
        field::{Field, Visit},
        span::{Attributes, Id, Record},
        Subscriber,
    };
    use tracing_subscriber::{layer::Context, prelude::*, registry::LookupSpan, Layer};

    use crate::{agent::Agent, providers::scripted::Scripted, tool::{tool, Effect}};

    type Spans = Arc<Mutex<Vec<(u64, HashMap<String, String>)>>>;

    struct Fields<'a>(&'a mut HashMap<String, String>);

    impl Visit for Fields<'_> {
        fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
            self.0.insert(field.name().to_string(), format!("{value:?}").trim_matches('"').to_string());
        }
        fn record_str(&mut self, field: &Field, value: &str) {
            self.0.insert(field.name().to_string(), value.to_string());
        }
    }

    struct Capture(Spans);

    impl<S: Subscriber + for<'a> LookupSpan<'a>> Layer<S> for Capture {
        fn on_new_span(&self, attrs: &Attributes<'_>, id: &Id, _: Context<'_, S>) {
            let mut fields = HashMap::new();
            attrs.record(&mut Fields(&mut fields));
            self.0.lock().unwrap().push((id.into_u64(), fields));
        }
        fn on_record(&self, id: &Id, values: &Record<'_>, _: Context<'_, S>) {
            let mut spans = self.0.lock().unwrap();
            if let Some((_, fields)) = spans.iter_mut().rev().find(|(s, _)| *s == id.into_u64()) {
                values.record(&mut Fields(fields));
            }
        }
    }

    #[tokio::test]
    async fn a_run_emits_agent_chat_and_tool_spans_without_content() {
        let spans: Spans = Arc::default();
        let _guard = tracing::subscriber::set_default(tracing_subscriber::registry().with(Capture(spans.clone())));
        let mut cached = Scripted::text("9C");
        cached.usage.cache_read_tokens = 4;
        cached.usage.cache_write_tokens = 3;
        let p = Arc::new(Scripted::new(vec![Scripted::call("w1", "weather", json!({"city": "Riga"})), cached]));
        let weather = tool("weather", "w", json!({"type": "object"}), Effect::Read, |_| async move { Ok("9C".to_string()) });
        let agent = Agent::with_provider(p, "m").tool(weather);
        agent.run("my secret question").await.unwrap();

        let spans = spans.lock().unwrap().clone();
        let named = |name: &str| spans.iter().map(|(_, f)| f).find(|f| f.get("otel.name").map(String::as_str) == Some(name)).cloned();
        let agent_span = named("invoke_agent").expect("invoke_agent span");
        assert_eq!(agent_span["otel.kind"], "internal");
        assert_eq!(agent_span["gen_ai.operation.name"], "invoke_agent");
        let chat = named("chat m").expect("chat span");
        assert_eq!(chat["otel.kind"], "client");
        assert_eq!(chat["gen_ai.operation.name"], "chat");
        assert_eq!(chat["gen_ai.request.model"], "m");
        assert!(chat.contains_key("gen_ai.usage.output_tokens"));
        // The convention counts cached input in input_tokens; providers report it apart.
        let cached = spans.iter().map(|(_, f)| f).filter(|f| f.get("otel.name").map(String::as_str) == Some("chat m")).nth(1).unwrap();
        assert_eq!(cached["gen_ai.usage.input_tokens"], "17", "10 uncached + 4 read + 3 written");
        let exec = named("execute_tool weather").expect("execute_tool span");
        assert_eq!(exec["gen_ai.tool.name"], "weather");
        assert_eq!(exec["gen_ai.tool.call.id"], "w1");
        assert_eq!(exec["otel.kind"], "internal");
        assert!(spans.iter().all(|(_, f)| f.values().all(|v| !v.contains("secret") && !v.contains("Riga"))), "no content");
    }

    #[test]
    fn provider_names_follow_the_convention() {
        assert_eq!(super::provider_name("anthropic"), "anthropic");
        assert_eq!(super::provider_name("bedrock"), "aws.bedrock");
        assert_eq!(super::provider_name("openai"), "openai");
        assert_eq!(super::provider_name("ollama"), "ollama");
        assert_eq!(super::provider_name("gemini"), "gcp.gemini");
    }
}
