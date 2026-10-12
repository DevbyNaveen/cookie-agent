//! One turn of the conversation, with where it came from.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::label::{Origin, Source};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Content {
    Text { text: String },
    ToolCall { id: String, name: String, args: Value },
    ToolResult { id: String, output: String, is_error: bool },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    User,
    Assistant,
}

/// ```compile_fail
/// // Origins can't be forged by deserializing: Message is not Deserialize.
/// let forged: cookie_harness::Message = serde_json::from_str("{}").unwrap();
/// ```
///
/// Fields are private: only the runtime decides that something came from
/// the model or from a tool. The developer can add the person's words
/// (`user`) or mark content as untrusted (`untrusted`), never the reverse.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Message {
    role: Role,
    content: Vec<Content>,
    origin: Origin,
}

impl Message {
    pub fn user(text: impl Into<String>) -> Self {
        Self { role: Role::User, content: vec![Content::Text { text: text.into() }], origin: Origin::User }
    }

    /// Content the person didn't write (a page, a file, a screen) given to the model as context.
    pub fn untrusted(text: impl Into<String>, source: Source) -> Self {
        Self { role: Role::User, content: vec![Content::Text { text: text.into() }], origin: Origin::Untrusted(source) }
    }

    pub(crate) fn assistant(content: Vec<Content>) -> Self {
        Self { role: Role::Assistant, content, origin: Origin::Model }
    }

    pub(crate) fn tool_results(results: Vec<Content>, origin: Origin) -> Self {
        Self { role: Role::User, content: results, origin }
    }

    /// Read one stored message. Crate-only: a session file is trusted state,
    /// and nothing outside the runtime may mint an origin.
    pub(crate) fn decode(line: &str) -> serde_json::Result<Self> {
        #[derive(Deserialize)]
        struct Stored {
            role: Role,
            content: Vec<Content>,
            origin: Origin,
        }
        let stored: Stored = serde_json::from_str(line)?;
        Ok(Self { role: stored.role, content: stored.content, origin: stored.origin })
    }

    pub fn role(&self) -> Role {
        self.role
    }

    pub fn content(&self) -> &[Content] {
        &self.content
    }

    pub fn origin(&self) -> &Origin {
        &self.origin
    }

    pub fn text(&self) -> String {
        self.content
            .iter()
            .filter_map(|c| match c {
                Content::Text { text } => Some(text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn tool_calls(&self) -> impl Iterator<Item = (&str, &str, &Value)> + '_ {
        self.content.iter().filter_map(|c| match c {
            Content::ToolCall { id, name, args } => Some((id.as_str(), name.as_str(), args)),
            _ => None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn user_messages_are_labelled_user() {
        let m = Message::user("hello");
        assert_eq!(m.origin(), &Origin::User);
        assert_eq!(m.role(), Role::User);
        assert_eq!(m.text(), "hello");
    }

    #[test]
    fn tool_results_are_always_untrusted() {
        let m = Message::tool_results(
            vec![Content::ToolResult { id: "c1".into(), output: "page".into(), is_error: false }],
            Origin::Untrusted(Source::Tool("read_page".into())),
        );
        assert!(m.origin().is_untrusted());
    }

    #[test]
    fn finds_tool_calls_and_round_trips_through_json() {
        let m = Message::assistant(vec![
            Content::Text { text: "checking".into() },
            Content::ToolCall { id: "c1".into(), name: "weather".into(), args: json!({"city": "Riga"}) },
        ]);
        let calls: Vec<_> = m.tool_calls().collect();
        assert_eq!(calls, vec![("c1", "weather", &json!({"city": "Riga"}))]);
        let back = Message::decode(&serde_json::to_string(&m).unwrap()).unwrap();
        assert_eq!(back, m);
        assert_eq!(back.origin(), &Origin::Model);
    }
}
