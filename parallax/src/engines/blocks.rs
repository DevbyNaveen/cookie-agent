//! Blocks: the parts an agent's own software is made of.
//!
//! An agent's workspace is a layout (`workspace/layout.json`) of blocks, each
//! kept as a file in the world:
//!
//! - **tracker** — typed columns and rows (a workout log: date, exercise,
//!   sets, reps, weight). Columns can be added and removed ("add a protein
//!   column"), and every row change is checked against the column types.
//! - **board** — cards in stages (leads: new → talking → won / lost).
//! - **calendar** — events with a start, an end and an optional weekly repeat.
//! - **chart** — a line or bar chart of one tracker's columns: it holds no
//!   data of its own, it reads the tracker when drawn.
//! - **form** — fields to fill; each submission is kept.
//! - **sheet**, **document**, **pdf** — a file the other engines work on,
//!   placed in the layout.
//!
//! Every change is a local action: previewable, undoable, branchable. An agent
//! changes its own software by adding, removing or reshaping blocks: tested
//! parts rearranged, never new code.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::engine::{s, ActionSpec, Ctx, Effect, Engine};

pub const KINDS: &[&str] = &["tracker", "board", "calendar", "chart", "form", "sheet", "document", "pdf"];
const COLUMN_TYPES: &[&str] = &["text", "number", "date", "yes/no", "choice"];

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Placed {
    pub name: String,
    pub kind: String,
    /// The block's file in the world.
    pub path: String,
    pub title: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Layout {
    pub title: String,
    pub blocks: Vec<Placed>,
}

fn good_name(n: &str) -> bool {
    !n.is_empty() && n.len() <= 40 && n.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// A value checked against a column's type; numbers come back as numbers.
pub fn typed(value: &Value, kind: &str, options: &[String]) -> Result<Value, String> {
    if value.is_null() || value.as_str().is_some_and(|s| s.trim().is_empty()) {
        return Ok(Value::Null);
    }
    match kind {
        "number" => match value {
            Value::Number(_) => Ok(value.clone()),
            Value::String(s) => s.trim().parse::<f64>().map(|n| json!(n)).map_err(|_| format!("“{s}” isn't a number")),
            _ => Err(format!("{value} isn't a number")),
        },
        "date" => {
            let s = value.as_str().ok_or("a date is written YYYY-MM-DD")?;
            let ok = s.len() == 10 && s.as_bytes()[4] == b'-' && s.as_bytes()[7] == b'-' && s[..4].parse::<u32>().is_ok() && s[5..7].parse::<u32>().is_ok_and(|m| (1..=12).contains(&m)) && s[8..].parse::<u32>().is_ok_and(|d| (1..=31).contains(&d));
            if ok { Ok(value.clone()) } else { Err(format!("“{s}” isn't a date (YYYY-MM-DD)")) }
        }
        "yes/no" => match value {
            Value::Bool(_) => Ok(value.clone()),
            Value::String(s) if matches!(s.to_lowercase().as_str(), "yes" | "true" | "y") => Ok(json!(true)),
            Value::String(s) if matches!(s.to_lowercase().as_str(), "no" | "false" | "n") => Ok(json!(false)),
            _ => Err(format!("{value} isn't yes or no")),
        },
        "choice" => {
            let s = value.as_str().ok_or("a choice is text")?;
            if options.iter().any(|o| o == s) { Ok(value.clone()) } else { Err(format!("“{s}” isn't one of {}", options.join(", "))) }
        }
        _ => Ok(match value { Value::String(_) => value.clone(), v => json!(v.to_string()) }),
    }
}

pub struct Blocks;

fn layout_path() -> &'static str {
    "workspace/layout.json"
}

fn load_layout(ctx: &Ctx) -> Layout {
    ctx.path(layout_path()).ok().and_then(|p| std::fs::read(p).ok()).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn write(ctx: &Ctx, rel: &str, v: &impl Serialize) -> Result<(), String> {
    let p = ctx.path(rel)?;
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    std::fs::write(p, serde_json::to_vec_pretty(v).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}

fn read_block(ctx: &Ctx, name: &str) -> Result<(Placed, Value), String> {
    let l = load_layout(ctx);
    let b = l.blocks.into_iter().find(|b| b.name == name).ok_or_else(|| format!("No block “{name}” in the workspace."))?;
    let v: Value = std::fs::read(ctx.path(&b.path)?).ok().and_then(|x| serde_json::from_slice(&x).ok()).unwrap_or(Value::Null);
    Ok((b, v))
}

fn need_kind(b: &Placed, kind: &str) -> Result<(), String> {
    if b.kind == kind { Ok(()) } else { Err(format!("“{}” is a {}, not a {kind}.", b.name, b.kind)) }
}

fn columns(v: &Value) -> Vec<(String, String, Vec<String>)> {
    v["columns"].as_array().into_iter().flatten().map(|c| (c["name"].as_str().unwrap_or("").to_string(), c["type"].as_str().unwrap_or("text").to_string(), c["options"].as_array().into_iter().flatten().filter_map(|o| o.as_str().map(str::to_string)).collect())).collect()
}

/// A row's values checked against the tracker's columns.
fn check_row(v: &Value, values: &Map<String, Value>, partial: bool) -> Result<Map<String, Value>, String> {
    let cols = columns(v);
    let mut out = Map::new();
    for (k, val) in values {
        let (_, kind, opts) = cols.iter().find(|(n, _, _)| n.eq_ignore_ascii_case(k)).ok_or_else(|| format!("No column “{k}”. Columns: {}.", cols.iter().map(|c| c.0.as_str()).collect::<Vec<_>>().join(", ")))?;
        let name = cols.iter().find(|(n, _, _)| n.eq_ignore_ascii_case(k)).map(|c| c.0.clone()).unwrap_or_default();
        out.insert(name, typed(val, kind, opts).map_err(|e| format!("{k}: {e}"))?);
    }
    if !partial && out.is_empty() {
        return Err("A row needs at least one value.".into());
    }
    Ok(out)
}

fn new_id() -> String {
    crate::util::random_hex(4)
}

#[async_trait]
impl Engine for Blocks {
    fn name(&self) -> &'static str {
        "blocks"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let st = json!({"type": "string"});
        let name = json!({"type": "string", "description": "the block's name (lowercase, digits, -)"});
        let obj = json!({"type": "object"});
        let a = |n: &str, d: &str, props: Value, req: &[&str], e: Effect| ActionSpec::new("blocks", n, d, json!({"type": "object", "properties": props, "required": req}), e);
        vec![
            a("layout", "The workspace: its blocks in order.", json!({}), &[], Effect::Read),
            a("add_block", "Add a block: tracker {columns:[{name,type,options?}]}, board {stages:[…]}, calendar {}, chart {source, x, y:[…], kind:line|bar}, form {fields:[{name,type,required?}]}, or sheet/document/pdf {path}. Column types: text, number, date, yes/no, choice.", json!({"name": name, "kind": {"type": "string", "enum": KINDS}, "title": st, "setup": obj}), &["name", "kind"], Effect::Local),
            a("remove_block", "Take a block out of the workspace (its file stays, so Undo brings it back).", json!({"name": name}), &["name"], Effect::Local),
            a("get", "A block's contents (a chart's series computed from its tracker).", json!({"name": name}), &["name"], Effect::Read),
            a("add_row", "Tracker: add a row (values by column).", json!({"name": name, "values": obj}), &["name", "values"], Effect::Local),
            a("update_row", "Tracker: change a row's values.", json!({"name": name, "row": st, "values": obj}), &["name", "row", "values"], Effect::Local),
            a("delete_row", "Tracker: remove a row.", json!({"name": name, "row": st}), &["name", "row"], Effect::Local),
            a("add_column", "Tracker: add a column (name, type, options for a choice).", json!({"name": name, "column": st, "type": {"type": "string", "enum": COLUMN_TYPES}, "options": {"type": "array", "items": st}}), &["name", "column", "type"], Effect::Local),
            a("remove_column", "Tracker: remove a column and its values.", json!({"name": name, "column": st}), &["name", "column"], Effect::Local),
            a("add_card", "Board: add a card to a stage.", json!({"name": name, "title": st, "stage": st, "notes": st}), &["name", "title"], Effect::Local),
            a("move_card", "Board: move a card to another stage.", json!({"name": name, "card": st, "stage": st}), &["name", "card", "stage"], Effect::Local),
            a("add_event", "Calendar: add an event (start/end as YYYY-MM-DDTHH:MM; repeat: weekly).", json!({"name": name, "title": st, "start": st, "end": st, "repeat": st}), &["name", "title", "start"], Effect::Local),
            a("remove_event", "Calendar: remove an event.", json!({"name": name, "event": st}), &["name", "event"], Effect::Local),
            a("submit", "Form: submit an answer (values by field).", json!({"name": name, "values": obj}), &["name", "values"], Effect::Local),
        ]
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        if action == "layout" {
            return Ok(serde_json::to_value(load_layout(ctx)).unwrap_or_default());
        }
        let name = s(args, "name")?;
        match action {
            "add_block" => {
                if !good_name(name) {
                    return Err("A block's name is lowercase letters, digits and -.".into());
                }
                let kind = s(args, "kind")?;
                if !KINDS.contains(&kind) {
                    return Err(format!("A block is one of: {}.", KINDS.join(", ")));
                }
                let mut l = load_layout(ctx);
                if l.blocks.iter().any(|b| b.name == name) {
                    return Err(format!("There is already a block “{name}”."));
                }
                let setup = args.get("setup").cloned().unwrap_or(json!({}));
                let path = match kind {
                    "sheet" | "document" | "pdf" => {
                        let p = setup["path"].as_str().ok_or("A sheet, document or pdf block names its file (`setup.path`).")?;
                        ctx.path(p)?;
                        p.to_string()
                    }
                    _ => format!("workspace/{name}.{kind}.json"),
                };
                let body = match kind {
                    "tracker" => {
                        let cols: Vec<Value> = setup["columns"].as_array().cloned().unwrap_or_default();
                        for c in &cols {
                            let t = c["type"].as_str().unwrap_or("text");
                            if c["name"].as_str().unwrap_or("").trim().is_empty() || !COLUMN_TYPES.contains(&t) {
                                return Err(format!("Each column has a name and a type ({}).", COLUMN_TYPES.join(", ")));
                            }
                        }
                        Some(json!({"columns": cols, "rows": []}))
                    }
                    "board" => Some(json!({"stages": setup["stages"].as_array().cloned().unwrap_or_else(|| vec![json!("To do"), json!("Doing"), json!("Done")]), "cards": []})),
                    "calendar" => Some(json!({"events": []})),
                    "chart" => {
                        let src = setup["source"].as_str().ok_or("A chart names its tracker (`setup.source`).")?;
                        let (sb, sv) = read_block(ctx, src)?;
                        need_kind(&sb, "tracker")?;
                        let cols = columns(&sv);
                        let has = |c: &str| cols.iter().any(|(n, _, _)| n.eq_ignore_ascii_case(c));
                        let x = setup["x"].as_str().ok_or("A chart needs `x`, a column.")?;
                        let ys: Vec<String> = setup["y"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_string)).collect();
                        if !has(x) || ys.is_empty() || !ys.iter().all(|y| cols.iter().any(|(n, t, _)| n.eq_ignore_ascii_case(y) && t == "number")) {
                            return Err("A chart's x is a column of its tracker, and each y a number column.".into());
                        }
                        Some(json!({"source": src, "x": x, "y": ys, "kind": if setup["kind"] == "bar" { "bar" } else { "line" }}))
                    }
                    "form" => Some(json!({"fields": setup["fields"].as_array().cloned().unwrap_or_default(), "responses": []})),
                    _ => None,
                };
                if let Some(b) = &body {
                    write(ctx, &path, b)?;
                }
                l.blocks.push(Placed { name: name.into(), kind: kind.into(), path: path.clone(), title: args["title"].as_str().unwrap_or(name).into() });
                write(ctx, layout_path(), &l)?;
                Ok(json!({"added": name, "kind": kind, "path": path}))
            }
            "remove_block" => {
                let mut l = load_layout(ctx);
                let before = l.blocks.len();
                l.blocks.retain(|b| b.name != name);
                if l.blocks.len() == before {
                    return Err(format!("No block “{name}”."));
                }
                write(ctx, layout_path(), &l)?;
                Ok(json!({"removed": name}))
            }
            "get" => {
                let (b, v) = read_block(ctx, name)?;
                if b.kind == "chart" {
                    let (_, t) = read_block(ctx, v["source"].as_str().unwrap_or(""))?;
                    let x = v["x"].as_str().unwrap_or("");
                    let series: Vec<Value> = v["y"].as_array().into_iter().flatten().filter_map(|y| y.as_str()).map(|y| {
                        let points: Vec<Value> = t["rows"].as_array().into_iter().flatten().filter_map(|r| r[y].as_f64().map(|n| json!([r[x].clone(), n]))).collect();
                        json!({"name": y, "points": points})
                    }).collect();
                    return Ok(json!({"kind": "chart", "chart": v["kind"], "source": v["source"], "x": x, "y": v["y"], "series": series}));
                }
                Ok(json!({"kind": b.kind, "title": b.title, "path": b.path, "data": v}))
            }
            other => {
                let (b, mut v) = read_block(ctx, name)?;
                let ok = |b: &Placed, v: &Value| -> Result<(), String> { write(ctx, &b.path, v) };
                match other {
                    "add_row" => {
                        need_kind(&b, "tracker")?;
                        let mut row = check_row(&v, args["values"].as_object().ok_or("Needs `values`.")?, false)?;
                        let id = new_id();
                        row.insert("_id".into(), json!(id));
                        v["rows"].as_array_mut().ok_or("A broken tracker.")?.push(Value::Object(row));
                        ok(&b, &v)?;
                        Ok(json!({"row": id}))
                    }
                    "update_row" | "delete_row" => {
                        need_kind(&b, "tracker")?;
                        let id = s(args, "row")?;
                        let checked = if other == "update_row" { Some(check_row(&v, args["values"].as_object().ok_or("Needs `values`.")?, true)?) } else { None };
                        let rows = v["rows"].as_array_mut().ok_or("A broken tracker.")?;
                        let i = rows.iter().position(|r| r["_id"] == id).ok_or_else(|| format!("No row {id}."))?;
                        match checked {
                            Some(c) => {
                                for (k, val) in c {
                                    rows[i][k] = val;
                                }
                            }
                            None => {
                                rows.remove(i);
                            }
                        }
                        ok(&b, &v)?;
                        Ok(json!({"row": id, "done": other}))
                    }
                    "add_column" => {
                        need_kind(&b, "tracker")?;
                        let col = s(args, "column")?.trim();
                        let kind = s(args, "type")?;
                        if col.is_empty() || col == "_id" || !COLUMN_TYPES.contains(&kind) {
                            return Err(format!("A column has a name and a type ({}).", COLUMN_TYPES.join(", ")));
                        }
                        if columns(&v).iter().any(|(n, _, _)| n.eq_ignore_ascii_case(col)) {
                            return Err(format!("There is already a column “{col}”."));
                        }
                        let options: Vec<String> = args["options"].as_array().into_iter().flatten().filter_map(|o| o.as_str().map(str::to_string)).collect();
                        if kind == "choice" && options.is_empty() {
                            return Err("A choice column lists its options.".into());
                        }
                        v["columns"].as_array_mut().ok_or("A broken tracker.")?.push(json!({"name": col, "type": kind, "options": options}));
                        ok(&b, &v)?;
                        Ok(json!({"added_column": col, "type": kind}))
                    }
                    "remove_column" => {
                        need_kind(&b, "tracker")?;
                        let col = s(args, "column")?;
                        let cols = v["columns"].as_array_mut().ok_or("A broken tracker.")?;
                        let before = cols.len();
                        cols.retain(|c| !c["name"].as_str().unwrap_or("").eq_ignore_ascii_case(col));
                        if cols.len() == before {
                            return Err(format!("No column “{col}”."));
                        }
                        for r in v["rows"].as_array_mut().into_iter().flatten() {
                            if let Some(o) = r.as_object_mut() {
                                o.retain(|k, _| !k.eq_ignore_ascii_case(col));
                            }
                        }
                        ok(&b, &v)?;
                        Ok(json!({"removed_column": col}))
                    }
                    "add_card" | "move_card" => {
                        need_kind(&b, "board")?;
                        let stages: Vec<String> = v["stages"].as_array().into_iter().flatten().filter_map(|x| x.as_str().map(str::to_string)).collect();
                        let stage = args["stage"].as_str().map(str::to_string).unwrap_or_else(|| stages.first().cloned().unwrap_or_default());
                        if !stages.contains(&stage) {
                            return Err(format!("No stage “{stage}”. Stages: {}.", stages.join(", ")));
                        }
                        let cards = v["cards"].as_array_mut().ok_or("A broken board.")?;
                        let id = if other == "add_card" {
                            let id = new_id();
                            cards.push(json!({"id": id, "title": s(args, "title")?, "stage": stage, "notes": args["notes"].as_str().unwrap_or("")}));
                            id
                        } else {
                            let id = s(args, "card")?.to_string();
                            let c = cards.iter_mut().find(|c| c["id"] == id.as_str()).ok_or_else(|| format!("No card {id}."))?;
                            c["stage"] = json!(stage);
                            id
                        };
                        ok(&b, &v)?;
                        Ok(json!({"card": id, "stage": stage}))
                    }
                    "add_event" | "remove_event" => {
                        need_kind(&b, "calendar")?;
                        let events = v["events"].as_array_mut().ok_or("A broken calendar.")?;
                        if other == "remove_event" {
                            let id = s(args, "event")?;
                            let before = events.len();
                            events.retain(|e| e["id"] != id);
                            if events.len() == before {
                                return Err(format!("No event {id}."));
                            }
                            ok(&b, &v)?;
                            return Ok(json!({"removed": id}));
                        }
                        let when = |k: &str| -> Result<Option<String>, String> {
                            match args[k].as_str() {
                                None => Ok(None),
                                Some(t) if t.len() >= 10 && typed(&json!(t[..10]), "date", &[]).is_ok() => Ok(Some(t.to_string())),
                                Some(t) => Err(format!("“{t}” isn't a time (YYYY-MM-DDTHH:MM)")),
                            }
                        };
                        let start = when("start")?.ok_or("An event needs `start`.")?;
                        let end = when("end")?;
                        if end.as_deref().is_some_and(|e| e < start.as_str()) {
                            return Err("An event ends after it starts.".into());
                        }
                        let repeat = args["repeat"].as_str().filter(|r| *r == "weekly");
                        let id = new_id();
                        events.push(json!({"id": id, "title": s(args, "title")?, "start": start, "end": end, "repeat": repeat}));
                        ok(&b, &v)?;
                        Ok(json!({"event": id}))
                    }
                    "submit" => {
                        need_kind(&b, "form")?;
                        let values = args["values"].as_object().ok_or("Needs `values`.")?;
                        let mut answer = Map::new();
                        for f in v["fields"].as_array().cloned().unwrap_or_default() {
                            let n = f["name"].as_str().unwrap_or("");
                            let val = values.get(n).cloned().unwrap_or(Value::Null);
                            let t = typed(&val, f["type"].as_str().unwrap_or("text"), &[]).map_err(|e| format!("{n}: {e}"))?;
                            if f["required"] == true && t.is_null() {
                                return Err(format!("“{n}” is required."));
                            }
                            answer.insert(n.into(), t);
                        }
                        answer.insert("_at".into(), json!(crate::util::now()));
                        v["responses"].as_array_mut().ok_or("A broken form.")?.push(Value::Object(answer));
                        ok(&b, &v)?;
                        Ok(json!({"submitted": true}))
                    }
                    other => Err(format!("The blocks engine has no action {other}.")),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_workout_log_gets_a_protein_column_and_a_chart() {
        let d = tempfile::tempdir().unwrap();
        let ctx = Ctx { world: "w".into(), files: d.path().to_path_buf(), state: d.path().join(".parallax"), home: d.path().join("home") };
        let b = Blocks;
        b.call(&ctx, "add_block", &json!({"name": "log", "kind": "tracker", "title": "Workout log", "setup": {"columns": [{"name": "date", "type": "date"}, {"name": "exercise", "type": "text"}, {"name": "weight", "type": "number"}]}})).await.unwrap();
        b.call(&ctx, "add_row", &json!({"name": "log", "values": {"date": "2026-11-24", "exercise": "squat", "weight": "80"}})).await.unwrap();
        assert!(b.call(&ctx, "add_row", &json!({"name": "log", "values": {"date": "24/11", "weight": 80}})).await.unwrap_err().contains("date"));
        assert!(b.call(&ctx, "add_row", &json!({"name": "log", "values": {"weight": "heavy"}})).await.is_err());
        b.call(&ctx, "add_column", &json!({"name": "log", "column": "protein", "type": "number"})).await.unwrap();
        b.call(&ctx, "add_row", &json!({"name": "log", "values": {"date": "2026-11-25", "weight": 85, "protein": 140}})).await.unwrap();
        b.call(&ctx, "add_block", &json!({"name": "progress", "kind": "chart", "setup": {"source": "log", "x": "date", "y": ["weight"]}})).await.unwrap();
        let c = b.call(&ctx, "get", &json!({"name": "progress"})).await.unwrap();
        assert_eq!(c["series"][0]["points"], json!([["2026-11-24", 80.0], ["2026-11-25", 85.0]]));
        assert!(b.call(&ctx, "add_block", &json!({"name": "bad", "kind": "chart", "setup": {"source": "log", "x": "date", "y": ["exercise"]}})).await.is_err(), "a chart only draws number columns");
        let l = b.call(&ctx, "layout", &json!({})).await.unwrap();
        assert_eq!(l["blocks"].as_array().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn boards_calendars_and_forms_check_what_they_take() {
        let d = tempfile::tempdir().unwrap();
        let ctx = Ctx { world: "w".into(), files: d.path().to_path_buf(), state: d.path().join(".parallax"), home: d.path().join("home") };
        let b = Blocks;
        b.call(&ctx, "add_block", &json!({"name": "leads", "kind": "board", "setup": {"stages": ["new", "won"]}})).await.unwrap();
        let card = b.call(&ctx, "add_card", &json!({"name": "leads", "title": "Acme"})).await.unwrap();
        assert!(b.call(&ctx, "move_card", &json!({"name": "leads", "card": card["card"], "stage": "lost"})).await.is_err());
        b.call(&ctx, "move_card", &json!({"name": "leads", "card": card["card"], "stage": "won"})).await.unwrap();
        b.call(&ctx, "add_block", &json!({"name": "week", "kind": "calendar"})).await.unwrap();
        assert!(b.call(&ctx, "add_event", &json!({"name": "week", "title": "Legs", "start": "2026-11-26T18:00", "end": "2026-11-26T17:00"})).await.is_err());
        b.call(&ctx, "add_event", &json!({"name": "week", "title": "Legs", "start": "2026-11-26T18:00", "repeat": "weekly"})).await.unwrap();
        b.call(&ctx, "add_block", &json!({"name": "checkin", "kind": "form", "setup": {"fields": [{"name": "weight", "type": "number", "required": true}]}})).await.unwrap();
        assert!(b.call(&ctx, "submit", &json!({"name": "checkin", "values": {}})).await.is_err());
        b.call(&ctx, "submit", &json!({"name": "checkin", "values": {"weight": "81.5"}})).await.unwrap();
    }
}
