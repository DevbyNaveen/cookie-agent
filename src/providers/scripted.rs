//! A provider that replays a script: for tests and offline examples.

use std::{collections::VecDeque, sync::Mutex};

use async_trait::async_trait;
use serde_json::Value;

use crate::{
    error::{Error, Result},
    message::{Content, Message},
    provider::{ModelRequest, ModelResponse, Provider, StopReason, Usage},
};

pub struct Scripted {
    replies: Mutex<VecDeque<ModelResponse>>,
    seen: Mutex<Vec<Vec<Message>>>,
    /// The system prompt and tool names of each request.
    asked: Mutex<Vec<(String, Vec<String>)>>,
}

impl Scripted {
    pub fn new(replies: Vec<ModelResponse>) -> Self {
        Self { replies: Mutex::new(replies.into()), seen: Mutex::new(Vec::new()), asked: Mutex::new(Vec::new()) }
    }

    /// Several tool calls in one turn.
    pub fn call_many(calls: &[(&str, &str, Value)]) -> ModelResponse {
        ModelResponse {
            content: calls.iter().map(|(id, name, input)| Content::ToolCall { id: id.to_string(), name: name.to_string(), args: input.clone() }).collect(),
            stop: StopReason::ToolUse,
            usage: Usage { input_tokens: 10, output_tokens: 5, ..Usage::default() },
        }
    }

    pub fn text(text: &str) -> ModelResponse {
        ModelResponse {
            content: vec![Content::Text { text: text.to_string() }],
            stop: StopReason::EndTurn,
            usage: Usage { input_tokens: 10, output_tokens: 5, ..Usage::default() },
        }
    }

    pub fn call(id: &str, name: &str, args: Value) -> ModelResponse {
        ModelResponse {
            content: vec![Content::ToolCall { id: id.to_string(), name: name.to_string(), args }],
            stop: StopReason::ToolUse,
            usage: Usage { input_tokens: 10, output_tokens: 5, ..Usage::default() },
        }
    }

    /// Every message history the provider was called with, in order.
    pub fn asked(&self) -> Vec<(String, Vec<String>)> {
        self.asked.lock().unwrap().clone()
    }

    pub fn seen(&self) -> Vec<Vec<Message>> {
        self.seen.lock().unwrap().clone()
    }
}

#[async_trait]
impl Provider for Scripted {
    async fn complete(&self, request: ModelRequest<'_>) -> Result<ModelResponse> {
        self.seen.lock().unwrap().push(request.messages.to_vec());
        self.asked.lock().unwrap().push((request.system.to_string(), request.tools.iter().map(|t| t.name.clone()).collect()));
        self.replies.lock().unwrap().pop_front().ok_or_else(|| Error::Provider("script exhausted".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{message::Message, provider::Provider};
    use serde_json::json;

    #[tokio::test]
    async fn replays_its_script_and_records_what_it_saw() {
        let p = Scripted::new(vec![Scripted::call("c1", "weather", json!({"city": "Riga"})), Scripted::text("9°C")]);
        let history = vec![Message::user("weather?")];
        let req = || ModelRequest { model: "m", system: "", messages: &history, tools: vec![] };
        assert_eq!(p.complete(req()).await.unwrap().stop, StopReason::ToolUse);
        assert_eq!(p.complete(req()).await.unwrap().stop, StopReason::EndTurn);
        assert!(p.complete(req()).await.is_err(), "an exhausted script is an error");
        assert_eq!(p.seen().len(), 3);
    }

    #[test]
    fn unknown_providers_are_refused() {
        let id = crate::model_id::ModelId::parse("nope:model").unwrap();
        assert!(matches!(crate::providers::resolve(&id), Err(crate::Error::UnknownProvider(_))));
    }

    #[tokio::test]
    async fn the_default_stream_reports_text_and_tool_calls() {
        let p = Scripted::new(vec![ModelResponse {
            content: vec![
                Content::Text { text: "checking".into() },
                Content::ToolCall { id: "c1".into(), name: "weather".into(), args: json!({}) },
            ],
            stop: StopReason::ToolUse,
            usage: Usage::default(),
        }]);
        let history = vec![Message::user("weather?")];
        let mut events = Vec::new();
        p.stream(ModelRequest { model: "m", system: "", messages: &history, tools: vec![] }, &mut |e| events.push(e))
            .await
            .unwrap();
        assert_eq!(events, vec![
            crate::provider::ProviderEvent::TextDelta("checking".into()),
            crate::provider::ProviderEvent::ToolCallStarted { id: "c1".into(), name: "weather".into() },
        ]);
    }
}
