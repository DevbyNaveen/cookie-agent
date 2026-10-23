//! cookie-tools: a stdio MCP server that makes and edits files on this Mac,
//! only inside the folders given with `--root`.

mod args;
mod docs;
mod paths;
mod sheets;

use std::{
    io::{self, BufRead, Read, Write},
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
};

use serde_json::{json, Value};

use paths::Roots;

/// Protocol versions this server speaks, newest first.
const VERSIONS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];
/// The longest message accepted from the client.
const MAX_LINE: u64 = 64 * 1024 * 1024;

const NEVER: &str = "Never writes outside the folders Cookie allows, never overwrites an existing file unless `overwrite` is true, never uses the network, never runs programs or macros.";

fn main() {
    let roots = match parse_args(std::env::args().skip(1).collect()) {
        Ok(roots) => roots,
        Err(error) => {
            eprintln!("cookie-tools: {error}\nusage: cookie-tools --root <folder> [--root <folder>…]");
            std::process::exit(2);
        }
    };
    // A panic inside a tool becomes that call's error; the hook keeps stderr quiet.
    std::panic::set_hook(Box::new(|info| eprintln!("cookie-tools: internal error: {info}")));
    let stdin = io::stdin();
    let mut input = stdin.lock();
    let stdout = io::stdout();
    let mut out = stdout.lock();
    let mut line = Vec::new();
    loop {
        line.clear();
        match (&mut input).take(MAX_LINE + 1).read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        if line.len() as u64 > MAX_LINE {
            // Drop the rest of the oversized line, then say so.
            if !line.ends_with(b"\n") {
                let mut rest = Vec::new();
                if input.read_until(b'\n', &mut rest).is_err() {
                    break;
                }
            }
            let reply = error_reply(&Value::Null, -32700, "message too large");
            if send(&mut out, &reply).is_err() {
                break;
            }
            continue;
        }
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        if let Some(reply) = handle(&roots, &line) {
            if send(&mut out, &reply).is_err() {
                break;
            }
        }
    }
}

fn send(out: &mut impl Write, message: &Value) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(message)?;
    bytes.push(b'\n');
    out.write_all(&bytes)?;
    out.flush()
}

fn parse_args(args: Vec<String>) -> Result<Roots, String> {
    let mut dirs = Vec::new();
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => dirs.push(PathBuf::from(args.next().ok_or("--root needs a folder")?)),
            other => match other.strip_prefix("--root=") {
                Some(dir) => dirs.push(PathBuf::from(dir)),
                None => return Err(format!("unknown argument `{other}`")),
            },
        }
    }
    Roots::new(&dirs, std::env::var_os("HOME").map(PathBuf::from))
}

fn error_reply(id: &Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

/// One message in, at most one reply out (notifications get none).
fn handle(roots: &Roots, line: &[u8]) -> Option<Value> {
    let Ok(message) = serde_json::from_slice::<Value>(line) else {
        return Some(error_reply(&Value::Null, -32700, "parse error"));
    };
    let Some(method) = message.get("method").and_then(Value::as_str) else {
        // A response to us (we send no requests) or something malformed.
        return message.get("id").filter(|_| message.get("result").is_none() && message.get("error").is_none())
            .map(|id| error_reply(id, -32600, "invalid request"));
    };
    let id = message.get("id")?.clone(); // no id: a notification
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    let result = match method {
        "initialize" => {
            let asked = params["protocolVersion"].as_str().unwrap_or_default();
            let version = VERSIONS.iter().find(|v| **v == asked).copied().unwrap_or(VERSIONS[0]);
            json!({
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": "cookie-tools", "version": env!("CARGO_PKG_VERSION")},
                "instructions": format!(
                    "Makes and edits spreadsheets (.xlsx, .csv), Word documents (.docx) and web pages (.html), and reads them back. Files may be written only inside: {}. A relative path is put in the first of these.",
                    roots.list().join(", ")
                ),
            })
        }
        "ping" => json!({}),
        "tools/list" => json!({"tools": tool_list()}),
        "tools/call" => {
            let Some(name) = params["name"].as_str() else {
                return Some(error_reply(&id, -32602, "tools/call needs `name`"));
            };
            let Some(tool) = tool_fn(name) else {
                return Some(error_reply(&id, -32602, &format!("unknown tool `{name}`")));
            };
            let arguments = match &params["arguments"] {
                Value::Null => json!({}),
                other => other.clone(),
            };
            let outcome = catch_unwind(AssertUnwindSafe(|| tool(roots, &arguments)))
                .unwrap_or_else(|_| Err("the file could not be processed (the reader failed on it); nothing was written".into()));
            let (text, is_error) = match outcome {
                Ok(text) => (text, false),
                Err(text) => (text, true),
            };
            json!({"content": [{"type": "text", "text": text}], "isError": is_error})
        }
        _ => return Some(error_reply(&id, -32601, &format!("method `{method}` is not supported"))),
    };
    Some(json!({"jsonrpc": "2.0", "id": id, "result": result}))
}

type ToolFn = fn(&Roots, &Value) -> Result<String, String>;

fn tool_fn(name: &str) -> Option<ToolFn> {
    Some(match name {
        "make_spreadsheet" => sheets::make_spreadsheet,
        "read_spreadsheet" => sheets::read_spreadsheet,
        "edit_spreadsheet" => sheets::edit_spreadsheet,
        "make_document" => docs::make_document,
        "read_document" => docs::read_document,
        "make_page" => docs::make_page,
        "make_csv" => sheets::make_csv,
        _ => return None,
    })
}

fn tool_list() -> Value {
    let path = json!({"type": "string", "description": "Where the file goes, e.g. ~/Documents/report.xlsx. Must be inside an allowed folder; `..` is refused."});
    let overwrite = json!({"type": "boolean", "description": "Replace the file if it already exists. Default false: an existing file is never touched."});
    let create_dirs = json!({"type": "boolean", "description": "Make missing folders (inside an allowed folder). Default false."});
    let cell = json!({"anyOf": [
        {"type": "string"}, {"type": "number"}, {"type": "boolean"}, {"type": "null"},
        {"type": "object", "properties": {"formula": {"type": "string", "description": "Starts with =, e.g. =SUM(B2:B9)"}}, "required": ["formula"], "additionalProperties": false}
    ]});
    let plain_cell = json!({"type": ["string", "number", "boolean", "null"]});
    let text_list = json!({"type": "array", "items": {"type": "string"}});
    let block_props = |html: bool| {
        let mut props = json!({
            "heading": {"type": "string"},
            "level": {"type": "integer", "minimum": 1, "maximum": 3, "description": "Heading level, default 1"},
            "paragraph": {"type": "string", "description": "Plain text; a newline is a line break"},
            "bullets": text_list,
            "numbered": text_list,
            "table": {"type": "object", "properties": {
                "header": text_list,
                "rows": {"type": "array", "items": {"type": "array", "items": plain_cell}}
            }, "required": ["rows"]},
            "page_break": {"type": "boolean"},
        });
        if html {
            props["html"] = json!({"type": "string", "description": "Markup inserted after sanitising: scripts, event handlers, javascript: links, frames and forms are removed"});
        }
        json!({"type": "array", "maxItems": docs::MAX_BLOCKS, "items": {"type": "object", "properties": props, "additionalProperties": false}})
    };
    let write = json!({"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false});
    let read = json!({"readOnlyHint": true, "openWorldHint": false});
    json!([
        {
            "name": "make_spreadsheet",
            "title": "Make a spreadsheet",
            "description": format!("Create a new Excel workbook (.xlsx) with one or more sheets: values, formulas (a cell {{\"formula\": \"=SUM(B2:B9)\"}}), bold frozen header with filter, column widths, number formats per column (\"#,##0.00\", \"0%\", \"yyyy-mm-dd\" — text like 2026-03-01 in a date column becomes a real date), charts (column, bar, line, pie, scatter) and Excel tables. `summary` adds a sheet that totals data by group with COUNTIFS/SUMIFS formulas — a formula summary, NOT a PivotTable (this tool cannot make PivotTables). Formulas are stored as formulas and calculate when the file is opened in Excel/Numbers. Limit {} cells. {NEVER}", sheets::MAX_CELLS),
            "inputSchema": {"type": "object", "properties": {
                "path": path,
                "sheets": {"type": "array", "minItems": 1, "items": {"type": "object", "properties": {
                    "name": {"type": "string"},
                    "rows": {"type": "array", "items": {"type": "array", "items": cell}, "description": "Rows of cells, first row first"},
                    "header": {"type": "boolean", "description": "First row is column names: bold, frozen, with filter buttons"},
                    "column_widths": {"type": "array", "items": {"type": ["number", "null"]}, "description": "Widths in characters, by column"},
                    "number_formats": {"type": "array", "items": {"type": ["string", "null"]}, "description": "Excel number format by column, e.g. \"#,##0.00\", \"0%\", \"yyyy-mm-dd\""},
                    "charts": {"type": "array", "items": {"type": "object", "properties": {
                        "type": {"enum": ["column", "bar", "line", "pie", "scatter"]},
                        "title": {"type": "string"},
                        "categories": {"type": "string", "description": "e.g. Sales!A2:A9 (quote names with spaces: 'Q1 Sales'!A2:A9)"},
                        "values": {"type": "array", "items": {"type": "string"}, "description": "One range per series, e.g. [\"Sales!B2:B9\"]"},
                        "series_names": text_list,
                        "anchor": {"type": "string", "description": "Top-left cell of the chart, e.g. E2"}
                    }, "required": ["type", "values"], "additionalProperties": false}},
                    "table": {"type": "boolean", "description": "Format the data as an Excel table (banded rows, filter buttons)"}
                }, "required": ["rows"], "additionalProperties": false}},
                "summary": {"type": "object", "properties": {
                    "source_sheet": {"type": "string"},
                    "group_by_column": {"type": "string", "description": "Column name from the header row, or a letter"},
                    "sum_columns": {"type": "array", "items": {"type": "string"}},
                    "target_sheet": {"type": "string", "description": "Name of the new summary sheet"}
                }, "required": ["source_sheet", "group_by_column", "sum_columns"], "additionalProperties": false},
                "overwrite": overwrite, "create_dirs": create_dirs
            }, "required": ["path", "sheets"], "additionalProperties": false},
            "annotations": write,
        },
        {
            "name": "read_spreadsheet",
            "title": "Read a spreadsheet",
            "description": "Read a spreadsheet (.xlsx, .xlsm, .xlsb, .xls, .ods or .csv): the sheet names and the cells of one sheet as a table with row numbers and column letters. Formulas show as =FORMULA → last calculated value. Defaults to the first sheet and 200 rows; use `range` (\"A1:F50\") and `max_rows` for more. Reads files up to 10 MB inside the allowed folders only. Never changes the file, never runs macros, never uses the network.",
            "inputSchema": {"type": "object", "properties": {
                "path": {"type": "string"},
                "sheet": {"type": "string"},
                "range": {"type": "string", "description": "e.g. A1:F50"},
                "max_rows": {"type": "integer", "minimum": 1, "maximum": 10000, "default": 200}
            }, "required": ["path"], "additionalProperties": false},
            "annotations": read,
        },
        {
            "name": "edit_spreadsheet",
            "title": "Edit a spreadsheet",
            "description": format!("Change cells in an existing .xlsx — a value or a formula per cell — and optionally add sheets, keeping the rest of the workbook. Saves to `save_as` (a new file); changes the original only with `overwrite: true`. Formulas calculate when the file is opened in Excel/Numbers. Parts of a workbook the editor does not model (for example PivotTables, macros, some chart formatting) may not survive the save, which is why saving to a new file is the default. {NEVER}"),
            "inputSchema": {"type": "object", "properties": {
                "path": {"type": "string", "description": "The existing .xlsx"},
                "edits": {"type": "array", "items": {"type": "object", "properties": {
                    "sheet": {"type": "string", "description": "Needed when the workbook has more than one sheet"},
                    "cell": {"type": "string", "description": "e.g. B7"},
                    "value": plain_cell,
                    "formula": {"type": "string", "description": "Starts with =, e.g. =B5*1.2"}
                }, "required": ["cell"], "additionalProperties": false}},
                "add_sheet": {"anyOf": [{"type": "string"}, text_list], "description": "New sheet name(s), added before the edits run"},
                "save_as": {"type": "string", "description": "New .xlsx path for the edited copy"},
                "overwrite": {"type": "boolean", "description": "Without save_as: change the original file. With save_as: replace that file if it exists."},
                "create_dirs": create_dirs
            }, "required": ["path"], "additionalProperties": false},
            "annotations": write,
        },
        {
            "name": "make_document",
            "title": "Make a Word document",
            "description": format!("Create a new Word document (.docx) from blocks: headings (levels 1–3), paragraphs, bulleted and numbered lists, tables and page breaks, with a title at the top. Text is written as plain text. At most {} blocks. {NEVER}", docs::MAX_BLOCKS),
            "inputSchema": {"type": "object", "properties": {
                "path": path, "title": {"type": "string"}, "blocks": block_props(false),
                "overwrite": overwrite, "create_dirs": create_dirs
            }, "required": ["path", "blocks"], "additionalProperties": false},
            "annotations": write,
        },
        {
            "name": "read_document",
            "title": "Read a document",
            "description": "Read the text of a document: .docx (headings marked with #, list items with -, table rows as a | b), .txt, .md, or .html (visible text only; scripts and styles dropped). Files up to 10 MB inside the allowed folders; returns at most 100,000 characters. Never changes the file, never runs anything in it, never uses the network.",
            "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"], "additionalProperties": false},
            "annotations": read,
        },
        {
            "name": "make_page",
            "title": "Make a web page",
            "description": format!("Create a self-contained, readable web page (.html) from a title and blocks (the same blocks as make_document, plus `html` for markup of your own). All text is escaped; `html` blocks are sanitised (no scripts, event handlers, javascript: links, frames or forms) and the page carries a policy that blocks scripts. Light and dark mode, prints cleanly. It loads nothing from the network except https images you put in an `html` block. At most {} blocks. {NEVER}", docs::MAX_BLOCKS),
            "inputSchema": {"type": "object", "properties": {
                "path": path, "title": {"type": "string"}, "blocks": block_props(true),
                "overwrite": overwrite, "create_dirs": create_dirs
            }, "required": ["path", "title", "blocks"], "additionalProperties": false},
            "annotations": write,
        },
        {
            "name": "make_csv",
            "title": "Make a CSV file",
            "description": format!("Create a .csv file (UTF-8 with a byte-order mark so Excel reads accents, comma-separated, quoted per RFC 4180) from rows of plain values. Text that a spreadsheet would run as a formula (starting with = + - @) is written with a leading apostrophe. A CSV holds no formulas, formats or sheets — use make_spreadsheet for those. Limit {} cells. {NEVER}", sheets::MAX_CELLS),
            "inputSchema": {"type": "object", "properties": {
                "path": path,
                "rows": {"type": "array", "items": {"type": "array", "items": plain_cell}},
                "bom": {"type": "boolean", "description": "Start with a UTF-8 byte-order mark (default true; Excel on the Mac needs it)."},
                "overwrite": overwrite, "create_dirs": create_dirs
            }, "required": ["path", "rows"], "additionalProperties": false},
            "annotations": write,
        },
    ])
}
