//! Keeping long sessions within reach: old tool output is cleared from what
//! the model sees, and older turns are replaced by a summary. The session
//! file is never rewritten; only the view sent to the model changes.

use crate::{
    label::Origin,
    message::{Content, Message},
};

/// The instruction for the summary call. Public so a developer can read it
/// (no hidden prompts) and pass their own via `Compaction::with_prompt` later.
pub const SUMMARY_PROMPT: &str = "Summarise the conversation so far for whoever continues it. \
Keep every decision, open question, name, number, address and file path exactly as written. \
Say which facts came from the person and which came from tools, pages or files. \
Plain prose, no preamble.";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Compaction {
    /// Tool output from turns older than the most recent N is cleared.
    pub clear_tool_results_after: usize,
    /// Summarise older turns once the view is estimated above this many tokens.
    pub summarize_above_tokens: u64,
    /// Turns always kept word for word when summarising (at least 1).
    pub keep_recent_turns: usize,
}

/// About four characters per token: an estimate for deciding when to compact,
/// never a bill.
pub fn estimate_tokens(messages: &[Message]) -> u64 {
    let chars: usize = messages
        .iter()
        .flat_map(|m| m.content())
        .map(|c| match c {
            Content::Text { text } => text.chars().count(),
            Content::ToolCall { name, args, .. } => name.len() + args.to_string().len(),
            Content::ToolResult { output, .. } => output.chars().count(),
        })
        .sum();
    (chars as u64).div_ceil(4)
}

/// A turn starts where the person spoke, so a boundary there never splits a
/// tool call from its result.
fn turn_starts(messages: &[Message]) -> Vec<usize> {
    messages.iter().enumerate().filter(|(_, m)| m.origin() == &Origin::User).map(|(i, _)| i).collect()
}

/// What to send: the latest summary and the turns after it, with tool output
/// from older turns cleared.
pub fn context_view(messages: &[Message], policy: &Compaction) -> Vec<Message> {
    let mut view: Vec<Message> = match messages.iter().rposition(|m| m.summary_of().is_some()) {
        Some(at) => {
            let covers = messages[at].summary_of().unwrap_or(0).min(at);
            std::iter::once(messages[at].clone())
                .chain(messages[covers..].iter().filter(|m| m.summary_of().is_none()).cloned())
                .collect()
        }
        None => messages.to_vec(),
    };
    let starts = turn_starts(&view);
    let cutoff = if policy.clear_tool_results_after == 0 {
        view.len()
    } else if starts.len() > policy.clear_tool_results_after {
        starts[starts.len() - policy.clear_tool_results_after]
    } else {
        0
    };
    for (index, message) in view.iter_mut().enumerate().take(cutoff) {
        let turn = starts.iter().filter(|start| **start <= index).count();
        message.clear_tool_outputs(turn);
    }
    view
}

/// Where a summary can end: the start of the oldest turn kept word for word.
/// `None` when there is nothing older than the kept turns.
pub fn summary_boundary(messages: &[Message], keep_recent_turns: usize) -> Option<usize> {
    let starts = turn_starts(messages);
    let keep = keep_recent_turns.max(1);
    if starts.len() <= keep {
        return None;
    }
    let boundary = starts[starts.len() - keep];
    (boundary > 0).then_some(boundary)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        label::{Origin, Source},
        message::{Content, Message},
    };
    use serde_json::json;

    fn turn(i: usize, output: &str) -> Vec<Message> {
        vec![
            Message::user(format!("question {i}")),
            Message::assistant(vec![Content::ToolCall { id: format!("c{i}"), name: "read".into(), args: json!({}) }]),
            Message::tool_results(
                vec![Content::ToolResult { id: format!("c{i}"), output: output.into(), is_error: false }],
                Origin::Untrusted(Source::Tool("read".into())),
            ),
            Message::assistant(vec![Content::Text { text: format!("answer {i}") }]),
        ]
    }

    fn output_of(m: &Message) -> String {
        match &m.content()[0] {
            Content::ToolResult { output, .. } => output.clone(),
            other => panic!("not a tool result: {other:?}"),
        }
    }

    #[test]
    fn estimates_about_four_characters_per_token() {
        assert_eq!(estimate_tokens(&[Message::user("abcdefgh")]), 2);
        assert_eq!(estimate_tokens(&[Message::user("abc")]), 1);
    }

    #[test]
    fn clears_tool_output_older_than_the_recent_turns_and_nothing_else() {
        let messages: Vec<Message> = (0..4).flat_map(|i| turn(i, &"x".repeat(100))).collect();
        let policy = Compaction { clear_tool_results_after: 2, summarize_above_tokens: u64::MAX, keep_recent_turns: 2 };
        let view = context_view(&messages, &policy);
        assert_eq!(view.len(), messages.len());
        assert!(output_of(&view[2]).starts_with("[cleared: tool output from turn 1, 100 characters"));
        assert!(output_of(&view[6]).starts_with("[cleared: tool output from turn 2"));
        assert_eq!(output_of(&view[10]), "x".repeat(100));
        assert_eq!(output_of(&view[14]), "x".repeat(100));
        assert_eq!(view[0].text(), "question 0", "the person's words are never cleared");
        assert!(view[2].origin().is_untrusted(), "clearing keeps the label");
    }

    #[test]
    fn the_latest_summary_replaces_the_turns_it_covers() {
        let mut messages: Vec<Message> = (0..3).flat_map(|i| turn(i, "data")).collect();
        messages.push(Message::summary("earlier: three readings".into(), 8, Origin::Model));
        let policy = Compaction { clear_tool_results_after: 99, summarize_above_tokens: u64::MAX, keep_recent_turns: 1 };
        let view = context_view(&messages, &policy);
        assert_eq!(view[0].text(), "Summary of the earlier conversation:\nearlier: three readings");
        assert_eq!(view[1].text(), "question 2");
        assert_eq!(view.len(), 1 + 4);
    }

    #[test]
    fn a_boundary_never_splits_a_tool_call_from_its_result() {
        let messages: Vec<Message> = (0..5).flat_map(|i| turn(i, "data")).collect();
        let boundary = summary_boundary(&messages, 2).unwrap();
        assert_eq!(boundary, 12, "keeps the last two turns whole");
        assert_eq!(messages[boundary].origin(), &Origin::User);
        assert!(summary_boundary(&messages[..8], 2).is_none(), "nothing older than the kept turns");
    }
}
