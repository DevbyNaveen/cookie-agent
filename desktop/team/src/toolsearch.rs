//! Tool search: an agent with many tools keeps the everyday ones in view and
//! finds the rest when it needs them, so their descriptions don't ride in
//! every turn.
//!
//! Hidden tools are reached through `tool_search` (find one, see its
//! arguments) and a bridge per kind of effect: `use_tool` (reads),
//! `use_tool_to_change` (writes) and `use_tool_to_send` (sends). Each bridge
//! carries its kind's effect, so approvals work exactly as if the tool were
//! called directly — same preview, same guarded values, same yes.

use std::sync::Arc;

use async_trait::async_trait;
use cookie_harness::tool::{tool, Effect, Tool, ToolContext, ToolSpec};
use serde_json::{json, Value};

/// Above this many tools, the rarely used ones go behind the search.
pub const DEFER_ABOVE: usize = 20;

/// Tools that stay in view however many there are.
fn deferrable(name: &str) -> bool {
    name.starts_with("reminders_")
        || name.starts_with("notes_")
        || name.starts_with("calendar_")
        || name.starts_with("contacts_")
        || name == "messages_send"
        || matches!(name, "set_routine" | "list_routines" | "stop_routine" | "propose_deal" | "note_about_person" | "forget_about_person" | "skill_manage" | "search_history")
}

struct Bridge {
    spec: ToolSpec,
    hidden: Vec<Arc<dyn Tool>>,
}

impl Bridge {
    fn find(&self, args: &Value) -> Option<&Arc<dyn Tool>> {
        let name = args["name"].as_str()?;
        self.hidden.iter().find(|t| t.spec().name == name)
    }
}

#[async_trait]
impl Tool for Bridge {
    fn spec(&self) -> &ToolSpec {
        &self.spec
    }
    async fn call(&self, args: Value) -> Result<String, String> {
        let t = self.find(&args).ok_or_else(|| format!("{} doesn't reach that tool. tool_search says which one does.", self.spec.name))?;
        t.call(args["args"].clone()).await
    }
    async fn call_in(&self, args: Value, context: &ToolContext) -> Result<String, String> {
        let t = self.find(&args).ok_or_else(|| format!("{} doesn't reach that tool. tool_search says which one does.", self.spec.name))?;
        t.call_in(args["args"].clone(), context).await
    }
    fn send_back(&self, args: &Value) -> Option<String> {
        self.find(args).and_then(|t| t.send_back(&args["args"]))
    }
    fn preview(&self, args: &Value) -> String {
        self.find(args).map(|t| t.preview(&args["args"])).unwrap_or_else(|| format!("{} {}", self.spec.name, args))
    }
}

fn bridge_name(effect: Effect) -> &'static str {
    match effect {
        Effect::Read => "use_tool",
        Effect::Write => "use_tool_to_change",
        _ => "use_tool_to_send",
    }
}

/// Keep `tools` as they are when there are few; otherwise move the rarely
/// used ones behind `tool_search` and the bridges. Returns the tools to offer
/// and a line for the instructions (when anything was hidden).
pub(crate) fn arrange(tools: Vec<Arc<dyn Tool>>) -> (Vec<Arc<dyn Tool>>, Option<String>) {
    if tools.len() <= DEFER_ABOVE {
        return (tools, None);
    }
    let (hidden, mut shown): (Vec<_>, Vec<_>) = tools.into_iter().partition(|t| deferrable(&t.spec().name));
    if hidden.is_empty() {
        return (shown, None);
    }
    let catalog: Vec<(String, String, Value, Effect)> = hidden.iter().map(|t| (t.spec().name.clone(), t.spec().description.clone(), t.spec().schema.clone(), t.spec().effect)).collect();
    let search = tool(
        "tool_search",
        "Find a tool you have but don't see: Mac apps (reminders, notes, calendar, contacts, iMessage), routines, deals, \
         keeping notes about the person, editing your skills, searching your past. Give a few words; it answers with matching \
         tools, their arguments, and which use_tool… to call them with.",
        json!({"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}),
        Effect::Read,
        move |args: Value| {
            let catalog = catalog.clone();
            async move {
                let q = args["query"].as_str().unwrap_or_default().to_lowercase();
                let words: Vec<&str> = q.split_whitespace().collect();
                let mut hits: Vec<(usize, &(String, String, Value, Effect))> = catalog
                    .iter()
                    .map(|c| {
                        let hay = format!("{} {}", c.0.replace('_', " "), c.1).to_lowercase();
                        (words.iter().filter(|w| hay.contains(*w)).count(), c)
                    })
                    .filter(|(n, _)| *n > 0 || words.is_empty())
                    .collect();
                hits.sort_by(|a, b| b.0.cmp(&a.0));
                if hits.is_empty() {
                    return Ok(format!("No tool matches. You have: {}.", catalog.iter().map(|c| c.0.as_str()).collect::<Vec<_>>().join(", ")));
                }
                Ok(hits
                    .iter()
                    .take(6)
                    .map(|(_, (name, desc, schema, effect))| format!("{name}: {desc}\n  call with {}(name: \"{name}\", args: {})", bridge_name(*effect), schema["properties"]))
                    .collect::<Vec<_>>()
                    .join("\n\n"))
            }
        },
    );
    shown.push(Arc::new(search));
    for effect in [Effect::Read, Effect::Write, Effect::Outbound, Effect::Destroy] {
        let group: Vec<Arc<dyn Tool>> = hidden.iter().filter(|t| t.spec().effect == effect).cloned().collect();
        if group.is_empty() {
            continue;
        }
        let names: Vec<Value> = group.iter().map(|t| json!(t.spec().name)).collect();
        let mut guarded: Vec<String> = group.iter().flat_map(|t| t.spec().guarded_args.iter().map(|g| if g.starts_with('/') { format!("/args{g}") } else { format!("/args/{g}") })).collect();
        guarded.sort();
        guarded.dedup();
        let what = match effect {
            Effect::Read => "Use a tool found with tool_search that only reads.",
            Effect::Write => "Use a tool found with tool_search that changes something (asks the person like any change).",
            _ => "Use a tool found with tool_search that sends something (always asks the person first).",
        };
        let name = match effect {
            Effect::Destroy => "use_tool_to_delete",
            e => bridge_name(e),
        };
        let spec = ToolSpec {
            name: name.into(),
            description: what.into(),
            schema: json!({"type": "object", "properties": {
                "name": {"type": "string", "enum": names},
                "args": {"type": "object", "description": "the tool's own arguments, as tool_search showed"}
            }, "required": ["name", "args"]}),
            effect,
            guarded_args: guarded,
            ..group[0].spec().clone()
        };
        shown.push(Arc::new(Bridge { spec, hidden: group }));
    }
    let note = format!(
        "Some of your tools are out of view to keep things quick: {}. Find one with tool_search, then call it through the use_tool… it names.",
        hidden.iter().map(|t| t.spec().name.clone()).collect::<Vec<_>>().join(", ")
    );
    (shown, Some(note))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(name: &str, effect: Effect) -> Arc<dyn Tool> {
        let n = name.to_string();
        Arc::new(tool(name, "a tool", json!({"type": "object", "properties": {"x": {"type": "string"}}}), effect, move |_a: Value| {
            let n = n.clone();
            async move { Ok(format!("ran {n}")) }
        }).guard("x"))
    }

    #[tokio::test]
    async fn many_tools_hide_the_rare_ones_behind_bridges_with_their_effects() {
        let mut tools: Vec<Arc<dyn Tool>> = (0..18).map(|i| t(&format!("core_{i}"), Effect::Read)).collect();
        tools.push(t("reminders_list", Effect::Read));
        tools.push(t("reminders_add", Effect::Write));
        tools.push(t("messages_send", Effect::Outbound));
        let (shown, note) = arrange(tools);
        let names: Vec<String> = shown.iter().map(|x| x.spec().name.clone()).collect();
        assert!(note.is_some());
        assert!(!names.contains(&"reminders_add".to_string()));
        assert!(names.contains(&"tool_search".to_string()));
        let send = shown.iter().find(|x| x.spec().name == "use_tool_to_send").unwrap();
        assert_eq!(send.spec().effect, Effect::Outbound);
        assert_eq!(send.spec().guarded_args, vec!["/args/x".to_string()]);
        let change = shown.iter().find(|x| x.spec().name == "use_tool_to_change").unwrap();
        assert_eq!(change.call(json!({"name": "reminders_add", "args": {"x": "1"}})).await.unwrap(), "ran reminders_add");
        assert!(change.call(json!({"name": "messages_send", "args": {}})).await.is_err(), "a bridge can't reach another effect's tool");
        let search = shown.iter().find(|x| x.spec().name == "tool_search").unwrap();
        assert!(search.call(json!({"query": "reminders"})).await.unwrap().contains("use_tool_to_change"));
    }

    #[test]
    fn few_tools_stay_as_they_are() {
        let tools: Vec<Arc<dyn Tool>> = vec![t("reminders_add", Effect::Write), t("read_file", Effect::Read)];
        let (shown, note) = arrange(tools);
        assert_eq!(shown.len(), 2);
        assert!(note.is_none());
    }
}
