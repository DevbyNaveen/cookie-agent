//! Big jobs split into parts. Cookie may hand a job with clearly separate
//! parts (several companies, several questions) to `plan_parts`: each part
//! runs as its own job, side by side, and a last job puts their answers
//! together for the person. The client runs the parts; what a plan may be,
//! and the words each part and the join read, live here.

use serde_json::{json, Value};

pub const MAX_PARTS: usize = 5;

/// What Cookie is told about splitting a job.
pub const PLANNING: &str = "- If the job has clearly separate parts that each need their own research (several companies, \
several questions, several markets), split it with `plan_parts` instead of doing everything in one go: two to five \
parts, each a whole task on its own, and say how to put their answers together. Each part runs as its own job and \
the person gets one answer at the end. A job that one or two lookups answer is never split.\n";

pub fn tool_decl() -> Value {
    json!({
        "name": "plan_parts",
        "description": "Split a big job into 2 to 5 separate parts that run side by side as their own jobs; a last job puts their answers together. Use only for jobs with clearly separate parts. After calling it, stop: end your turn with one short line.",
        "schema": {"type": "object", "properties": {
            "parts": {"type": "array", "minItems": 2, "maxItems": MAX_PARTS, "items": {"type": "object", "properties": {
                "title": {"type": "string", "description": "A few words, e.g. \"Acme: pricing and customers\"."},
                "task": {"type": "string", "description": "The part as a whole task, in plain words, with everything it needs from the job."}
            }, "required": ["title", "task"]}},
            "join": {"type": "string", "description": "How to put the parts' answers together for the person, e.g. \"a comparison table, then a recommendation\"."}
        }, "required": ["parts", "join"]},
        "effect": "write",
        "parallel_safe": false
    })
}

/// A plan, checked.
#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    pub parts: Vec<(String, String)>,
    pub join: String,
}

pub fn check(args: &Value) -> Result<Plan, String> {
    let parts: Vec<(String, String)> = args["parts"]
        .as_array()
        .ok_or("`parts` is a list of {title, task}")?
        .iter()
        .map(|p| (p["title"].as_str().unwrap_or("").trim().to_string(), p["task"].as_str().unwrap_or("").trim().to_string()))
        .collect();
    if !(2..=MAX_PARTS).contains(&parts.len()) {
        return Err(format!("a plan has 2 to {MAX_PARTS} parts, not {}", parts.len()));
    }
    for (title, task) in &parts {
        if title.is_empty() || title.chars().count() > 80 {
            return Err("each part needs a title of a few words".into());
        }
        if task.chars().count() < 10 || task.chars().count() > 1_500 {
            return Err(format!("the part \"{title}\" needs a task of 10 to 1,500 characters"));
        }
    }
    let join = args["join"].as_str().unwrap_or("").trim().to_string();
    if join.is_empty() || join.chars().count() > 1_000 {
        return Err("say in `join` how to put the parts together".into());
    }
    Ok(Plan { parts, join })
}

/// What one part's job is given: its task as the input, the whole job as
/// context.
pub fn part_input(job: &str, plan: &Plan, index: usize) -> (String, String) {
    let (title, task) = &plan.parts[index];
    let input = format!("{task}\n\n(This is part {} of {} of a bigger job: {title}. Do only this part.)", index + 1, plan.parts.len());
    let context = format!("The whole job this part belongs to, in the person's words:\n{job}");
    (input, context)
}

/// What the joining job is given: the job and how to join as its input,
/// each part's answer as context (Cookie's own work, read as such).
pub fn join_input(job: &str, join: &str, answers: &[(String, Option<String>)]) -> (String, String) {
    let input = format!("{job}\n\n(The parts of this job are done. Put their answers together for the person: {join}.)");
    let parts: Vec<String> = answers
        .iter()
        .enumerate()
        .map(|(i, (title, a))| match a {
            Some(a) => format!("Part {}: {title}\n{a}", i + 1),
            None => format!("Part {}: {title}\n(this part did not finish — say so)", i + 1),
        })
        .collect();
    (input, format!("What each part found:\n\n{}", parts.join("\n\n")))
}

/// One `plan` line: `{op: "check", args}` → `{parts: [[title, task]], join}`,
/// or `{op: "part", job, args, index}` → `{input, context}`, or `{op: "join",
/// job, join, answers: [[title, answer|null]]}` → `{input, context}`.
pub fn rpc(m: &Value) -> Result<Value, String> {
    match m["op"].as_str().unwrap_or_default() {
        "check" => {
            let p = check(&m["args"])?;
            Ok(json!({"parts": p.parts, "join": p.join}))
        }
        "part" => {
            let p = check(&m["args"])?;
            let i = m["index"].as_u64().ok_or("`index`")? as usize;
            if i >= p.parts.len() {
                return Err("no such part".into());
            }
            let (input, context) = part_input(m["job"].as_str().unwrap_or(""), &p, i);
            Ok(json!({"input": input, "context": context}))
        }
        "join" => {
            let answers: Vec<(String, Option<String>)> = serde_json::from_value(m["answers"].clone()).map_err(|e| format!("`answers`: {e}"))?;
            let (input, context) = join_input(m["job"].as_str().unwrap_or(""), m["join"].as_str().unwrap_or(""), &answers);
            Ok(json!({"input": input, "context": context}))
        }
        other => Err(format!("unknown plan op `{other}`")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan() -> Value {
        json!({"parts": [{"title": "Acme", "task": "Find Acme's pricing and top customers."}, {"title": "Beta", "task": "Find Beta's pricing and top customers."}],
               "join": "a comparison table, then which to pick"})
    }

    #[test]
    fn a_plan_is_two_to_five_whole_parts_with_a_join() {
        assert_eq!(check(&plan()).unwrap().parts.len(), 2);
        assert!(check(&json!({"parts": [{"title": "A", "task": "only one part here"}], "join": "x"})).is_err());
        let six: Vec<Value> = (0..6).map(|i| json!({"title": format!("P{i}"), "task": "a task long enough"})).collect();
        assert!(check(&json!({"parts": six, "join": "x"})).is_err());
        assert!(check(&json!({"parts": [{"title": "A", "task": "short"}, {"title": "B", "task": "long enough task"}], "join": "x"})).is_err());
        assert!(check(&json!({"parts": plan()["parts"], "join": ""})).is_err());
    }

    #[test]
    fn a_part_does_only_its_part_and_the_join_reads_every_answer() {
        let p = check(&plan()).unwrap();
        let (input, context) = part_input("Compare Acme and Beta", &p, 1);
        assert!(input.starts_with("Find Beta's pricing") && input.contains("part 2 of 2"));
        assert!(context.contains("Compare Acme and Beta"));
        let (input, context) = join_input("Compare Acme and Beta", &p.join, &[("Acme".into(), Some("A costs 5".into())), ("Beta".into(), None)]);
        assert!(input.contains("a comparison table"));
        assert!(context.contains("Part 1: Acme\nA costs 5") && context.contains("did not finish"));
        assert_eq!(rpc(&json!({"op": "check", "args": plan()})).unwrap()["parts"][0][0], "Acme");
    }
}
