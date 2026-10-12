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
    from: String,
    text: String,
}

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
        let mut all = self.0.lock().unwrap();
        all.push(Artifact { from: from.to_string(), text });
        let id = format!("art-{}", all.len());
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
        let index = id.strip_prefix("art-").and_then(|n| n.parse::<usize>().ok()).filter(|n| (1..=all.len()).contains(n));
        let Some(artifact) = index.map(|n| &all[n - 1]) else {
            return Err(format!("There is no artifact `{id}`."));
        };
        let length = artifact.text.chars().count();
        let page: String = artifact.text.chars().skip(offset).take(PAGE).collect();
        let end = (offset + PAGE).min(length);
        Ok(format!("[{id} from {}: characters {offset}–{end} of {length}]\n{page}", artifact.from))
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        agent::Agent,
        providers::scripted::Scripted,
        subagent::SubAgent,
    };
    use serde_json::json;
    use std::sync::Arc;

    #[tokio::test]
    async fn a_long_answer_comes_back_as_a_reference_the_parent_can_read() {
        let long = "x".repeat(9_000) + "THE END";
        let child_p = Arc::new(Scripted::new(vec![Scripted::text(&long)]));
        let child = Agent::with_provider(child_p, "m");
        let parent_p = Arc::new(Scripted::new(vec![
            Scripted::call("d1", "research", json!({"task": "dig"})),
            Scripted::call("r1", "read_artifact", json!({"id": "art-1", "offset": 8_000})),
            Scripted::text("done"),
        ]));
        let parent = Agent::with_provider(parent_p.clone(), "m").tool(SubAgent::reader("research", "x", child).unwrap());
        assert_eq!(parent.run("go").await.unwrap(), "done");
        assert!(parent_p.asked()[0].1.contains(&"read_artifact".to_string()), "offered when there are sub-agents");
        let result = |turn: usize| match &parent_p.seen()[turn].last().unwrap().content()[0] {
            crate::message::Content::ToolResult { output, .. } => output.clone(),
            other => panic!("{other:?}"),
        };
        let preview = result(1);
        assert!(preview.contains("art-1") && preview.contains("research") && preview.len() < 2_000, "{}", &preview[..200]);
        let rest = result(2);
        assert!(rest.contains("THE END") && rest.contains("research"));
    }

    #[tokio::test]
    async fn without_sub_agents_there_is_no_read_artifact() {
        let p = Arc::new(Scripted::new(vec![Scripted::text("ok")]));
        Agent::with_provider(p.clone(), "m").run("hi").await.unwrap();
        assert!(p.asked()[0].1.is_empty());
    }
}
