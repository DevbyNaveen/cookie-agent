//! Tool search, on every provider: past a number of tools, the model gets a
//! `search_tools` tool instead of every definition, and the tools it finds
//! are offered from then on. Fewer tokens per request; nothing is hidden —
//! every tool can still be found and every call still goes through the gates.

use std::{
    collections::HashSet,
    sync::{Arc, Mutex},
};

use async_trait::async_trait;
use serde_json::{json, Value};

use crate::tool::{Effect, Tool, ToolSpec};

pub const SEARCH_TOOL: &str = "search_tools";

/// Turn search on when an agent has more than `after` tools; each search
/// offers at most `top_k` more.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ToolSearch {
    pub after: usize,
    pub top_k: usize,
}

/// One run's search: the tool, and the names found so far.
pub(crate) struct Searcher {
    pub(crate) tool: Arc<dyn Tool>,
    found: Arc<Mutex<HashSet<String>>>,
}

impl Searcher {
    /// `None` when the agent has few enough tools to send them all.
    pub(crate) fn new(tools: &[Arc<dyn Tool>], config: ToolSearch) -> Option<Self> {
        if tools.len() <= config.after {
            return None;
        }
        let found: Arc<Mutex<HashSet<String>>> = Arc::default();
        let catalog = tools.iter().map(|t| (t.spec().name.clone(), t.spec().description.clone())).collect();
        let tool = Arc::new(SearchTool { spec: spec(), catalog, found: found.clone(), top_k: config.top_k.max(1) });
        Some(Self { tool, found })
    }

    /// What this request offers: the search tool and everything found.
    pub(crate) fn offered<'a>(&self, tools: &'a [Arc<dyn Tool>]) -> Vec<&'a ToolSpec> {
        let found = self.found.lock().unwrap();
        // `read_artifact` is always offered: a long answer points to it.
        tools
            .iter()
            .map(|t| t.spec())
            .filter(|s| s.name == SEARCH_TOOL || s.name == "read_artifact" || found.contains(&s.name))
            .collect()
    }
}

fn spec() -> ToolSpec {
    ToolSpec {
        name: SEARCH_TOOL.into(),
        description: "Find tools for a task by describing it in a few words. Tools you find can be called from then on.".into(),
        schema: json!({"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}),
        effect: Effect::Read,
        guarded_args: Vec::new(),
        parallel_safe: true,
        delegates: false,
        foreign: false,
    }
}

struct SearchTool {
    spec: ToolSpec,
    catalog: Vec<(String, String)>,
    found: Arc<Mutex<HashSet<String>>>,
    top_k: usize,
}

fn words(text: &str) -> HashSet<String> {
    text.split(|c: char| !c.is_alphanumeric()).filter(|w| w.len() > 1).map(str::to_lowercase).collect()
}

#[async_trait]
impl Tool for SearchTool {
    fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    /// Ranks tools by the query words they contain, rarer words counting more.
    async fn call(&self, args: Value) -> std::result::Result<String, String> {
        let query = words(args["query"].as_str().unwrap_or_default());
        let docs: Vec<HashSet<String>> = self.catalog.iter().map(|(name, about)| words(&format!("{} {about}", name.replace('_', " ")))).collect();
        let total = docs.len() as f64;
        let weight = |word: &String| (total / docs.iter().filter(|d| d.contains(word)).count().max(1) as f64).ln() + 1.0;
        let mut ranked: Vec<(f64, usize)> = docs
            .iter()
            .enumerate()
            .map(|(i, doc)| (query.iter().filter(|w| doc.contains(*w)).map(weight).sum::<f64>(), i))
            .filter(|(score, _)| *score > 0.0)
            .collect();
        ranked.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)));
        if ranked.is_empty() {
            return Ok("No tool matches. Try other words.".into());
        }
        let mut found = self.found.lock().unwrap();
        let lines: Vec<String> = ranked
            .into_iter()
            .take(self.top_k)
            .map(|(_, i)| {
                let (name, about) = &self.catalog[i];
                found.insert(name.clone());
                format!("- {name}: {about}")
            })
            .collect();
        Ok(format!("Found (you can call these now):\n{}", lines.join("\n")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        agent::Agent,
        providers::scripted::Scripted,
        tool::{tool, Effect, Tool},
    };
    use serde_json::json;
    use std::sync::Arc;

    fn many() -> Vec<Arc<dyn Tool>> {
        let mut tools: Vec<Arc<dyn Tool>> = (0..30)
            .map(|i| Arc::new(tool(&format!("crm_field_{i}"), &format!("Update CRM field number {i}"), json!({"type": "object"}), Effect::Read, |_| async move { Ok(String::new()) })) as Arc<dyn Tool>)
            .collect();
        tools.push(Arc::new(tool("weather", "Current weather for a city", json!({"type": "object"}), Effect::Read, |_| async move { Ok("9C".to_string()) })));
        tools
    }

    #[tokio::test]
    async fn the_model_finds_a_tool_and_then_can_use_it() {
        let p = Arc::new(Scripted::new(vec![
            Scripted::call("s1", "search_tools", json!({"query": "weather in a city"})),
            Scripted::call("w1", "weather", json!({"city": "Riga"})),
            Scripted::text("9C"),
        ]));
        let agent = Agent::with_provider(p.clone(), "m").tools(many()).tool_search(ToolSearch { after: 10, top_k: 3 });
        assert_eq!(agent.run("weather?").await.unwrap(), "9C");
        let asked = p.asked();
        assert_eq!(asked[0].1, ["search_tools"], "first only the search tool");
        assert!(asked[1].1.contains(&"weather".to_string()) && asked[1].1.len() <= 4, "then what it found: {:?}", asked[1].1);
        let found = match &p.seen()[1].last().unwrap().content()[0] {
            crate::message::Content::ToolResult { output, .. } => output.clone(),
            other => panic!("{other:?}"),
        };
        assert!(found.contains("weather") && found.contains("Current weather"), "{found}");
    }

    #[tokio::test]
    async fn below_the_threshold_every_tool_is_sent() {
        let p = Arc::new(Scripted::new(vec![Scripted::text("ok")]));
        let agent = Agent::with_provider(p.clone(), "m").tools(many().into_iter().take(5)).tool_search(ToolSearch { after: 10, top_k: 3 });
        agent.run("hi").await.unwrap();
        assert_eq!(p.asked()[0].1.len(), 5);
    }

    #[tokio::test]
    async fn read_artifact_is_always_offered_beside_search() {
        let child = Agent::with_provider(Arc::new(Scripted::new(vec![Scripted::text("x")])), "m");
        let p = Arc::new(Scripted::new(vec![Scripted::text("ok")]));
        let agent = Agent::with_provider(p.clone(), "m")
            .tools(many())
            .tool(crate::subagent::SubAgent::reader("research", "x", child).unwrap())
            .tool_search(ToolSearch { after: 10, top_k: 3 });
        agent.run("hi").await.unwrap();
        assert!(p.asked()[0].1.contains(&"read_artifact".to_string()), "{:?}", p.asked()[0].1);
    }
}
