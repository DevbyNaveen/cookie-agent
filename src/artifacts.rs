//! Artifacts by reference: a sub-agent's long answer is kept aside and the
//! parent gets its start and an id, then reads more with `read_artifact`
//! only if it needs to. What it reads is still untrusted, and says whose it is.

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde_json::{json, Value};

use crate::tool::{Effect, Tool, ToolSpec};

/// Answers longer than this become artifacts; the parent sees this much.
pub(crate) const INLINE_LIMIT: usize = 4_000;
const PREVIEW: usize = 1_000;
const PAGE: usize = 4_000;

struct Artifact {
    id: String,
    from: String,
    text: String,
}

/// Ids are unique in this process, so an id from another run or another
/// hop never opens the wrong text.
static NEXT_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

/// One run's artifacts. Ids are `art-1`, `art-2`, … in order.
#[derive(Clone, Default)]
pub(crate) struct Artifacts(Arc<Mutex<Vec<Artifact>>>);

impl Artifacts {
    /// `text` as it should reach the parent: whole if short, else a preview
    /// and the id to read the rest by.
    pub(crate) fn keep(&self, from: &str, text: String) -> String {
        let length = text.chars().count();
        if length <= INLINE_LIMIT {
            return text;
        }
        let preview: String = text.chars().take(PREVIEW).collect();
        let id = format!("art-{}", NEXT_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
        self.0.lock().unwrap().push(Artifact { id: id.clone(), from: from.to_string(), text });
        format!("[{id} from {from}: {length} characters; this is the start — read more with read_artifact]\n{preview}…")
    }

    pub(crate) fn tool(&self) -> Arc<dyn Tool> {
        Arc::new(ReadArtifact { artifacts: self.clone(), spec: spec() })
    }
}

fn spec() -> ToolSpec {
    ToolSpec {
        name: "read_artifact".into(),
        description: format!("Read part of a sub-agent's long answer by its id (e.g. art-1), {PAGE} characters at a time from `offset`."),
        schema: json!({"type": "object", "properties": {"id": {"type": "string"}, "offset": {"type": "integer", "minimum": 0}}, "required": ["id"]}),
        effect: Effect::Read,
        guarded_args: Vec::new(),
        parallel_safe: true,
        delegates: false,
        foreign: false,
    }
}

struct ReadArtifact {
    artifacts: Artifacts,
    spec: ToolSpec,
}

#[async_trait]
impl Tool for ReadArtifact {
    fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    async fn call(&self, args: Value) -> std::result::Result<String, String> {
        let id = args["id"].as_str().unwrap_or_default();
        let offset = args["offset"].as_u64().unwrap_or(0) as usize;
        let all = self.artifacts.0.lock().unwrap();
        let Some(artifact) = all.iter().find(|a| a.id == id) else {
            return Err(format!("There is no artifact `{id}`."));
        };
        let length = artifact.text.chars().count();
        let page: String = artifact.text.chars().skip(offset).take(PAGE).collect();
        let end = offset.saturating_add(PAGE).min(length);
        Ok(format!("[{id} from {}: characters {offset}–{end} of {length}]\n{page}", artifact.from))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{agent::Agent, providers::scripted::Scripted, subagent::SubAgent};
    use serde_json::json;
    use std::sync::Arc;

    /// Delegates, then reads the artifact whose id the preview names — as a
    /// model would — then answers.
    struct Parent;

    #[async_trait::async_trait]
    impl crate::provider::Provider for Parent {
        async fn complete(&self, request: crate::provider::ModelRequest<'_>) -> crate::Result<crate::provider::ModelResponse> {
            let last = |m: &crate::message::Message| match m.content().first() {
                Some(crate::message::Content::ToolResult { output, .. }) => output.clone(),
                _ => String::new(),
            };
            let reply = match request.messages.len() {
                1 => Scripted::call("d1", "research", json!({"task": "dig"})),
                3 => {
                    let preview = last(&request.messages[2]);
                    let id = preview.trim_start_matches('[').split(' ').next().unwrap_or_default().to_string();
                    Scripted::call("r1", "read_artifact", json!({"id": id, "offset": 8_000}))
                }
                _ => Scripted::text(&last(request.messages.last().unwrap())),
            };
            Ok(reply)
        }
    }

    #[tokio::test]
    async fn a_long_answer_comes_back_as_a_reference_the_parent_can_read() {
        let long = "x".repeat(9_000) + "THE END";
        let child = Agent::with_provider(Arc::new(Scripted::new(vec![Scripted::text(&long)])), "m");
        let parent = Agent::with_provider(Arc::new(Parent), "m").tool(SubAgent::reader("research", "x", child).unwrap());
        let read = parent.run("go").await.unwrap();
        assert!(read.contains("THE END") && read.contains("from research"), "{read}");
    }

    #[tokio::test]
    async fn ids_are_never_reused_and_a_huge_offset_is_harmless() {
        let store = Artifacts::default();
        let a = store.keep("r", "y".repeat(INLINE_LIMIT + 1));
        let b = store.keep("r", "y".repeat(INLINE_LIMIT + 1));
        assert_ne!(a.split(' ').next(), b.split(' ').next());
        let id = a.trim_start_matches('[').split(' ').next().unwrap().to_string();
        let out = store.tool().call(json!({"id": id, "offset": u64::MAX})).await.unwrap();
        assert!(out.contains("characters"), "{out}");
    }

    #[tokio::test]
    async fn without_sub_agents_there_is_no_read_artifact() {
        let p = Arc::new(Scripted::new(vec![Scripted::text("ok")]));
        Agent::with_provider(p.clone(), "m").run("hi").await.unwrap();
        assert!(p.asked()[0].1.is_empty());
    }
}
