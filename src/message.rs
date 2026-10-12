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
    /// Set on a summary: the number of earlier session messages it replaces.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    summary_of: Option<usize>,
}

impl Message {
    pub fn user(text: impl Into<String>) -> Self {
        Self { role: Role::User, content: vec![Content::Text { text: text.into() }], origin: Origin::User, summary_of: None }
    }

    /// Content the person didn't write (a page, a file, a screen) given to the model as context.
    pub fn untrusted(text: impl Into<String>, source: Source) -> Self {
        Self { role: Role::User, content: vec![Content::Text { text: text.into() }], origin: Origin::Untrusted(source), summary_of: None }
    }

    /// A task written by another agent's model: followed as an instruction,
    /// never credited as the person's words.
    pub(crate) fn delegated(task: impl Into<String>) -> Self {
        Self { role: Role::User, content: vec![Content::Text { text: task.into() }], origin: Origin::Model, summary_of: None }
    }

    pub(crate) fn assistant(content: Vec<Content>) -> Self {
        Self { role: Role::Assistant, content, origin: Origin::Model, summary_of: None }
    }

    pub(crate) fn tool_results(results: Vec<Content>, origin: Origin) -> Self {
        Self { role: Role::User, content: results, origin, summary_of: None }
    }

    /// Read one stored message. Crate-only: a session file is trusted state,
    /// and nothing outside the runtime may mint an origin.
    pub(crate) fn decode(line: &str) -> serde_json::Result<Self> {
        #[derive(Deserialize)]
        struct Stored {
            role: Role,
            content: Vec<Content>,
            origin: Origin,
            #[serde(default)]
            summary_of: Option<usize>,
        }
        let stored: Stored = serde_json::from_str(line)?;
        Ok(Self { role: stored.role, content: stored.content, origin: stored.origin, summary_of: stored.summary_of })
    }

    /// A summary of the first `covers` session messages. Its origin says
    /// whether it was written from untrusted content.
    pub(crate) fn summary(text: String, covers: usize, origin: Origin) -> Self {
        Self {
            role: Role::User,
            content: vec![Content::Text { text: format!("Summary of the earlier conversation:\n{text}") }],
            origin,
            summary_of: Some(covers),
        }
    }

    pub fn summary_of(&self) -> Option<usize> {
        self.summary_of
    }

    /// The same turn as plain text (tool calls and results written out), for
    /// requests that declare no tools, such as a summary. Keeps the label.
    pub(crate) fn as_plain_text(&self) -> Option<Message> {
        let text = self
            .content
            .iter()
            .map(|c| match c {
                Content::Text { text } => text.clone(),
                Content::ToolCall { name, args, .. } => format!("[called {name} with {args}]"),
                Content::ToolResult { output, is_error: true, .. } => format!("[tool error: {output}]"),
                Content::ToolResult { output, .. } => format!("[tool result: {output}]"),
            })
            .filter(|t| !t.trim().is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        (!text.trim().is_empty()).then(|| Message {
            role: self.role,
            content: vec![Content::Text { text }],
            origin: self.origin.clone(),
            summary_of: None,
        })
    }

    /// Replace tool output with a short note, keeping ids and labels.
    pub(crate) fn clear_tool_outputs(&mut self, turn: usize) {
        for content in &mut self.content {
            if let Content::ToolResult { output, .. } = content {
                if !output.starts_with("[cleared:") {
                    let size = output.chars().count();
                    *output = format!("[cleared: tool output from turn {turn}, {size} characters — ask again if you need it]");
                }
            }
        }
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
