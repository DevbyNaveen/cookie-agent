//! A session is a plain JSONL file: one message per line, append-only.
//! Open it again to resume; copy a prefix to branch; replay by reading it.

use std::path::{Path, PathBuf};

use tokio::{fs::OpenOptions, io::AsyncWriteExt};

use crate::{
    error::{Error, Result},
    label::{Origin, Source},
    message::{Content, Message, Role},
};

pub struct Session {
    path: Option<PathBuf>,
    messages: Vec<Message>,
    /// Held while the session is open: one writer per file.
    _lock: Option<std::fs::File>,
}

impl Session {
    pub fn in_memory() -> Self {
        Self { path: None, messages: Vec::new(), _lock: None }
    }

    pub async fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref().to_path_buf();
        if let Some(dir) = path.parent() {
            if !dir.as_os_str().is_empty() {
                tokio::fs::create_dir_all(dir).await?;
            }
        }
        // An advisory lock on the file itself: a second process (or a second
        // Session in this one) opening it to write is refused, not interleaved.
        let lock = std::fs::OpenOptions::new().create(true).append(true).open(&path)?;
        match lock.try_lock() {
            Ok(()) => {}
            Err(std::fs::TryLockError::WouldBlock) => {
                return Err(Error::Session(format!("{} is in use by another writer", path.display())));
            }
            Err(std::fs::TryLockError::Error(e)) => return Err(e.into()),
        }
        let mut messages = Vec::new();
        match tokio::fs::read_to_string(&path).await {
            Ok(text) => {
                let lines: Vec<&str> = text.lines().collect();
                for (index, line) in lines.iter().enumerate() {
                    if line.trim().is_empty() {
                        continue;
                    }
                    match Message::decode(line) {
                        Ok(message) => messages.push(message),
                        // A crash mid-write leaves a torn last line with no newline:
                        // those bytes were never a whole message, so cut them off.
                        Err(_) if index + 1 == lines.len() && !text.ends_with('\n') => {
                            let file = OpenOptions::new().write(true).open(&path).await?;
                            file.set_len((text.len() - line.len()) as u64).await?;
                        }
                        Err(e) => {
                            return Err(Error::Session(format!("{} line {}: {e}", path.display(), index + 1)));
                        }
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        let mut session = Self { path: Some(path), messages, _lock: Some(lock) };
        session.repair().await?;
        Ok(session)
    }

    pub fn messages(&self) -> &[Message] {
        &self.messages
    }

    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    pub(crate) async fn append(&mut self, message: Message) -> Result<()> {
        if let Some(path) = &self.path {
            let mut line = serde_json::to_string(&message)?;
            line.push('\n');
            let mut file = OpenOptions::new().create(true).append(true).open(path).await?;
            file.write_all(line.as_bytes()).await?;
            file.flush().await?;
            // On disk before the run goes on: a power cut loses nothing it reported.
            file.sync_data().await?;
        }
        self.messages.push(message);
        Ok(())
    }

    /// A stop between a tool call and its result leaves the model's request
    /// unanswered, which providers reject. Answer it as interrupted.
    pub(crate) async fn repair(&mut self) -> Result<()> {
        let Some(last) = self.messages.last() else { return Ok(()) };
        if last.role() != Role::Assistant {
            return Ok(());
        }
        let calls: Vec<(String, String)> =
            last.tool_calls().map(|(id, name, _)| (id.to_string(), name.to_string())).collect();
        if calls.is_empty() {
            return Ok(());
        }
        let results = calls
            .iter()
            .map(|(id, _)| Content::ToolResult {
                id: id.clone(),
                output: "Interrupted: this may or may not have run. Check before trying again.".into(),
                is_error: true,
            })
            .collect();
        let names = calls.iter().map(|(_, name)| name.as_str()).collect::<Vec<_>>().join(",");
        self.append(Message::tool_results(results, Origin::Untrusted(Source::Tool(names)))).await
    }

    /// A new session holding the first `keep` messages. Refuses a non-empty target.
    pub async fn branch(&self, keep: usize, path: impl AsRef<Path>) -> Result<Session> {
        let mut branch = Session::open(path).await?;
        if !branch.messages.is_empty() {
            return Err(Error::Session("branch target already has messages".into()));
        }
        for message in self.messages.iter().take(keep).cloned() {
            branch.append(message).await?;
        }
        branch.repair().await?;
        Ok(branch)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::{Content, Message};
    use serde_json::json;

    #[tokio::test]
    async fn appends_survive_a_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s/one.jsonl");
        let mut s = Session::open(&path).await.unwrap();
        s.append(Message::user("hi")).await.unwrap();
        s.append(Message::assistant(vec![Content::Text { text: "hello".into() }])).await.unwrap();
        let before = s.messages().to_vec();
        drop(s); // the writer is gone, as after the process exits
        let again = Session::open(&path).await.unwrap();
        assert_eq!(again.messages(), before.as_slice());
        assert_eq!(again.messages().len(), 2);
    }

    #[tokio::test]
    async fn a_crash_between_a_tool_call_and_its_result_is_repaired_on_open() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("crash.jsonl");
        let mut s = Session::open(&path).await.unwrap();
        s.append(Message::user("weather?")).await.unwrap();
        s.append(Message::assistant(vec![Content::ToolCall { id: "c1".into(), name: "weather".into(), args: json!({}) }]))
            .await
            .unwrap();
        drop(s); // the crash
        let reopened = Session::open(&path).await.unwrap();
        let last = reopened.messages().last().unwrap();
        assert!(last.origin().is_untrusted());
        assert!(matches!(&last.content()[0], Content::ToolResult { id, is_error: true, .. } if id == "c1"));
    }

    #[tokio::test]
    async fn branching_copies_the_first_messages_into_a_new_file() {
        let dir = tempfile::tempdir().unwrap();
        let mut s = Session::open(dir.path().join("a.jsonl")).await.unwrap();
        for text in ["one", "two", "three"] {
            s.append(Message::user(text)).await.unwrap();
        }
        let b = s.branch(2, dir.path().join("b.jsonl")).await.unwrap();
        assert_eq!(b.messages().len(), 2);
        drop(b);
        assert_eq!(Session::open(dir.path().join("b.jsonl")).await.unwrap().messages().len(), 2);
        assert!(s.branch(1, dir.path().join("b.jsonl")).await.is_err(), "never overwrite an existing branch");
    }

    #[tokio::test]
    async fn a_torn_last_line_from_a_crash_mid_write_is_dropped() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("torn.jsonl");
        let mut s = Session::open(&path).await.unwrap();
        s.append(Message::user("hi")).await.unwrap();
        drop(s); // the crash mid-write
        let mut text = tokio::fs::read_to_string(&path).await.unwrap();
        text.push_str("{\"role\":\"us");
        tokio::fs::write(&path, &text).await.unwrap();
        let reopened = Session::open(&path).await.unwrap();
        assert_eq!(reopened.messages().len(), 1);
        assert!(tokio::fs::read_to_string(&path).await.unwrap().ends_with('\n'), "the torn bytes are gone from the file");
    }

    #[tokio::test]
    async fn a_corrupt_line_is_an_error_not_silent_data_loss() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("bad.jsonl");
        tokio::fs::write(&path, "not json\n").await.unwrap();
        assert!(matches!(Session::open(&path).await, Err(crate::Error::Session(_))));
    }

    #[tokio::test]
    async fn a_session_file_has_one_writer_at_a_time() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.jsonl");
        let first = Session::open(&path).await.unwrap();
        assert!(matches!(Session::open(&path).await, Err(Error::Session(m)) if m.contains("in use")));
        drop(first);
        assert!(Session::open(&path).await.is_ok(), "free again once the first is dropped");
    }
}
