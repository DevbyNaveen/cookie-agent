//! Spreadsheets and CSV: make, read, edit.

use std::collections::HashMap;

use calamine::{open_workbook_auto, Data, Reader};
use rust_xlsxwriter::{
    column_number_to_name, quote_sheet_name, Chart, ChartType, ExcelDateTime, Format, Formula, Table, Workbook, Worksheet,
};
use serde_json::Value;

use crate::{
    args::{plain_text, strings, Args},
    paths::{extension, human_size, read_bytes, write_file, Roots},
};

/// The most cells one call may write.
pub const MAX_CELLS: usize = 200_000;
/// The most text a read returns.
const MAX_OUTPUT_CHARS: usize = 100_000;
const MAX_ROW: u32 = 1_048_575;
const MAX_COL: u16 = 16_383;
pub const RECALC_NOTE: &str = "Formulas will calculate when the file is opened in Excel/Numbers.";

// ---------- cell references ----------

/// `B7` or `$B$7` → zero-based (row, column).
pub fn parse_cell(text: &str) -> Result<(u32, u16), String> {
    let bad = || format!("`{text}` is not a cell like B7");
    let clean: String = text.trim().chars().filter(|c| *c != '$').collect::<String>().to_ascii_uppercase();
    let split = clean.find(|c: char| c.is_ascii_digit()).ok_or_else(bad)?;
    let (letters, digits) = clean.split_at(split);
    if letters.is_empty() || letters.len() > 3 || !letters.chars().all(|c| c.is_ascii_uppercase()) {
        return Err(bad());
    }
    if digits.is_empty() || !digits.chars().all(|c| c.is_ascii_digit()) {
        return Err(bad());
    }
    let col = letters.bytes().fold(0u32, |n, b| n * 26 + u32::from(b - b'A' + 1)) - 1;
    let row = digits.parse::<u32>().map_err(|_| bad())?.checked_sub(1).ok_or_else(bad)?;
    if row > MAX_ROW || col > u32::from(MAX_COL) {
        return Err(format!("`{text}` is past the last cell a sheet can have"));
    }
    Ok((row, col as u16))
}

/// First row, first column, last row, last column (zero-based).
pub type CellRange = (u32, u16, u32, u16);

/// `A1:F50` (or one cell) → its corners.
pub fn parse_range(text: &str) -> Result<CellRange, String> {
    let (a, b) = text.split_once(':').unwrap_or((text, text));
    let (r0, c0) = parse_cell(a)?;
    let (r1, c1) = parse_cell(b)?;
    Ok((r0.min(r1), c0.min(c1), r0.max(r1), c0.max(c1)))
}

/// `Sheet!A2:A9` or `'My Sheet'!A2:A9` → (sheet name, range).
pub fn parse_sheet_range(text: &str) -> Result<(String, CellRange), String> {
    let (sheet, range) = text
        .rsplit_once('!')
        .ok_or_else(|| format!("`{text}` needs a sheet name, like Sales!B2:B9"))?;
    let sheet = sheet.trim();
    let sheet = match sheet.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')) {
        Some(quoted) => quoted.replace("''", "'"),
        None => sheet.to_string(),
    };
    Ok((sheet, parse_range(range)?))
}

fn cell_name(row: u32, col: u16) -> String {
    format!("{}{}", column_number_to_name(col), row + 1)
}

// ---------- make_spreadsheet ----------

struct SheetSpec<'a> {
    name: String,
    rows: &'a [Value],
    header: bool,
    table: bool,
    widths: Option<&'a Vec<Value>>,
    formats: Option<&'a Vec<Value>>,
    charts: Option<&'a Vec<Value>>,
}

impl SheetSpec<'_> {
    fn width(&self) -> usize {
        self.rows.iter().filter_map(Value::as_array).map(Vec::len).max().unwrap_or(0)
    }
}

pub fn make_spreadsheet(roots: &Roots, args: &Value) -> Result<String, String> {
    let a = Args::new(args, "make_spreadsheet", &["path", "sheets", "summary", "overwrite", "create_dirs"])?;
    let raw = a.str("path")?;
    let target = roots.write_target(raw, a.bool("create_dirs")?)?;
    if extension(&target) != "xlsx" {
        return Err("make_spreadsheet writes .xlsx files; end `path` with .xlsx (use make_csv for .csv)".into());
    }
    let mut specs = Vec::new();
    for (i, sheet) in a.array("sheets")?.iter().enumerate() {
        let what = format!("sheets[{i}]");
        let s = Args::new(sheet, &what, &["name", "rows", "header", "column_widths", "number_formats", "charts", "table"])?;
        let name = s.opt_str("name")?.map(str::to_string).unwrap_or_else(|| format!("Sheet{}", i + 1));
        if specs.iter().any(|p: &SheetSpec| p.name.eq_ignore_ascii_case(&name)) {
            return Err(format!("two sheets are named `{name}`"));
        }
        let rows = s.array("rows")?;
        if let Some((r, _)) = rows.iter().enumerate().find(|(_, row)| !row.is_array()) {
            return Err(format!("{what}.rows[{r}] must be a list of cells"));
        }
        specs.push(SheetSpec {
            name,
            rows,
            header: s.bool("header")?,
            table: s.bool("table")?,
            widths: s.opt_array("column_widths")?,
            formats: s.opt_array("number_formats")?,
            charts: s.opt_array("charts")?,
        });
    }
    if specs.is_empty() {
        return Err("`sheets` needs at least one sheet".into());
    }
    let summaries: Vec<&Value> = match a.get("summary") {
        None => Vec::new(),
        Some(Value::Array(list)) => list.iter().collect(),
        Some(one) => vec![one],
    };
    let mut cells: usize = specs.iter().flat_map(|s| s.rows.iter()).filter_map(Value::as_array).map(Vec::len).sum();
    if cells > MAX_CELLS {
        return Err(format!("{cells} cells is over the limit of {MAX_CELLS} per spreadsheet"));
    }

    let mut workbook = Workbook::new();
    let mut lines = Vec::new();
    let mut formulas = 0;
    for spec in &specs {
        let (line, n) = write_sheet(&mut workbook, spec, &specs)?;
        lines.push(line);
        formulas += n;
    }
    for (i, summary) in summaries.iter().enumerate() {
        let (line, n, written) = write_summary(&mut workbook, summary, i, &specs, cells)?;
        cells += written;
        lines.push(line);
        formulas += n;
    }
    let bytes = workbook.save_to_buffer().map_err(|e| format!("could not build the workbook: {e}"))?;
    write_file(roots, &target, &bytes, a.bool("overwrite")?)?;
    let mut text = format!("Wrote {} ({}).\n{}", roots.show(&target), human_size(bytes.len() as u64), lines.join("\n"));
    if formulas > 0 {
        text.push_str(&format!("\n{formulas} formulas. {RECALC_NOTE}"));
    }
    Ok(text)
}

fn is_date_format(format: &str) -> bool {
    let f = format.to_ascii_lowercase();
    (f.contains('y') || f.contains('d')) && !f.contains('0') && !f.contains('#')
}

/// `2026-03-01` or `2026-03-01 14:30[:00]` (or with `T`).
fn looks_like_iso_date(text: &str) -> bool {
    let b = text.as_bytes();
    let digits = |r: std::ops::Range<usize>| r.into_iter().all(|i| b.get(i).is_some_and(u8::is_ascii_digit));
    let date = b.len() >= 10 && digits(0..4) && b[4] == b'-' && digits(5..7) && b[7] == b'-' && digits(8..10);
    date && match b.len() {
        10 => true,
        16 | 19 => (b[10] == b' ' || b[10] == b'T') && digits(11..13) && b[13] == b':' && digits(14..16)
            && (b.len() == 16 || (b[16] == b':' && digits(17..19))),
        _ => false,
    }
}

fn write_cell(ws: &mut Worksheet, row: u32, col: u16, cell: &Value, format: Option<&Format>, date_col: bool) -> Result<bool, String> {
    let at = || cell_name(row, col);
    let mut formula = false;
    let result = match cell {
        Value::Null => return Ok(false),
        Value::String(s) if date_col && looks_like_iso_date(s) => match ExcelDateTime::parse_from_str(s) {
            Ok(date) => ws.write_datetime(row, col, &date),
            Err(_) => ws.write_string(row, col, s),
        },
        Value::String(s) => match format {
            Some(f) => ws.write_string_with_format(row, col, s, f),
            None => ws.write_string(row, col, s),
        },
        Value::Number(n) => {
            let n = n.as_f64().ok_or_else(|| format!("{}: the number is out of range", at()))?;
            match format {
                Some(f) => ws.write_number_with_format(row, col, n, f),
                None => ws.write_number(row, col, n),
            }
        }
        Value::Bool(b) => match format {
            Some(f) => ws.write_boolean_with_format(row, col, *b, f),
            None => ws.write_boolean(row, col, *b),
        },
        Value::Object(_) => {
            let f = Args::new(cell, &format!("the cell at {}", at()), &["formula"])?;
            let text = f.str("formula")?.trim();
            if !text.starts_with('=') || text.len() < 2 {
                return Err(format!("{}: a formula starts with =, like =SUM(A2:A9)", at()));
            }
            formula = true;
            match format {
                Some(f) => ws.write_formula_with_format(row, col, Formula::new(text), f),
                None => ws.write_formula(row, col, Formula::new(text)),
            }
        }
        Value::Array(_) => return Err(format!("{}: a cell cannot be a list", at())),
    };
    result.map_err(|e| format!("{}: {e}", at()))?;
    Ok(formula)
}

fn write_sheet(workbook: &mut Workbook, spec: &SheetSpec, all: &[SheetSpec]) -> Result<(String, usize), String> {
    let ws = workbook.add_worksheet();
    ws.set_name(&spec.name).map_err(|e| format!("sheet name `{}`: {e}", spec.name))?;
    let width = spec.width();
    let mut date_cols = vec![false; width.max(1)];
    // Column formats go first: a cell written without its own format takes its column's.
    for (c, format) in spec.formats.into_iter().flatten().enumerate() {
        let Some(format) = format.as_str() else {
            if format.is_null() {
                continue;
            }
            return Err(format!("sheet `{}`: number_formats must be text or null", spec.name));
        };
        let col = u16::try_from(c).ok().filter(|c| *c <= MAX_COL).ok_or("too many number_formats")?;
        ws.set_column_format(col, &Format::new().set_num_format(format)).map_err(|e| e.to_string())?;
        if let Some(slot) = date_cols.get_mut(c) {
            *slot = is_date_format(format);
        }
    }
    for (c, w) in spec.widths.into_iter().flatten().enumerate() {
        if w.is_null() {
            continue;
        }
        let w = w.as_f64().filter(|w| (0.0..=255.0).contains(w));
        let w = w.ok_or_else(|| format!("sheet `{}`: column_widths are numbers from 0 to 255 (characters)", spec.name))?;
        let col = u16::try_from(c).ok().filter(|c| *c <= MAX_COL).ok_or("too many column_widths")?;
        ws.set_column_width(col, w).map_err(|e| e.to_string())?;
    }
    let bold = Format::new().set_bold();
    let mut formulas = 0;
    for (r, row) in spec.rows.iter().enumerate() {
        let r32 = u32::try_from(r).ok().filter(|r| *r <= MAX_ROW).ok_or("more rows than a sheet can hold")?;
        let header_row = spec.header && r == 0;
        for (c, cell) in row.as_array().into_iter().flatten().enumerate() {
            let c16 = u16::try_from(c).ok().filter(|c| *c <= MAX_COL).ok_or("more columns than a sheet can hold")?;
            let format = header_row.then_some(&bold);
            let date = !header_row && date_cols.get(c).copied().unwrap_or(false);
            if write_cell(ws, r32, c16, cell, format, date).map_err(|e| format!("sheet `{}` {e}", spec.name))? {
                formulas += 1;
            }
        }
    }
    let last_row = spec.rows.len().saturating_sub(1) as u32;
    let last_col = width.saturating_sub(1) as u16;
    let mut notes = Vec::new();
    if spec.header && !spec.rows.is_empty() {
        ws.set_freeze_panes(1, 0).map_err(|e| e.to_string())?;
        notes.push("header row");
        if !spec.table && width > 0 {
            ws.autofilter(0, 0, last_row, last_col).map_err(|e| e.to_string())?;
        }
    }
    if spec.table {
        if width == 0 || (spec.header && spec.rows.len() < 2) {
            return Err(format!("sheet `{}`: a table needs a header row and at least one row of data", spec.name));
        }
        let table = Table::new().set_header_row(spec.header);
        ws.add_table(0, 0, last_row, last_col, &table).map_err(|e| format!("sheet `{}` table: {e}", spec.name))?;
        notes.push("Excel table");
    }
    let mut charts = 0;
    for (i, chart) in spec.charts.into_iter().flatten().enumerate() {
        let chart = build_chart(chart, all).map_err(|e| format!("sheet `{}` charts[{i}]: {e}", spec.name))?;
        let (row, col) = chart.1.unwrap_or((1, (last_col + 2).min(MAX_COL)));
        ws.insert_chart(row, col, &chart.0).map_err(|e| format!("sheet `{}` charts[{i}]: {e}", spec.name))?;
        charts += 1;
    }
    let chart_note = match charts {
        0 => String::new(),
        1 => "1 chart".into(),
        n => format!("{n} charts"),
    };
    let mut all_notes: Vec<String> = notes.into_iter().map(str::to_string).collect();
    if !chart_note.is_empty() {
        all_notes.push(chart_note);
    }
    let detail = if all_notes.is_empty() { String::new() } else { format!(" ({})", all_notes.join(", ")) };
    Ok((format!("Sheet \"{}\": {} rows × {} columns{detail}", spec.name, spec.rows.len(), width), formulas))
}

fn build_chart(value: &Value, all: &[SheetSpec]) -> Result<(Chart, Option<(u32, u16)>), String> {
    let c = Args::new(value, "the chart", &["type", "title", "categories", "values", "series_names", "anchor"])?;
    let kind = match c.str("type")? {
        "column" => ChartType::Column,
        "bar" => ChartType::Bar,
        "line" => ChartType::Line,
        "pie" => ChartType::Pie,
        "scatter" => ChartType::Scatter,
        other => return Err(format!("chart type `{other}` is not one of column, bar, line, pie, scatter")),
    };
    let range = |text: &str| -> Result<(String, CellRange), String> {
        let (sheet, r) = parse_sheet_range(text)?;
        let found = all.iter().find(|s| s.name.eq_ignore_ascii_case(&sheet)).ok_or_else(|| {
            format!("`{text}` names sheet `{sheet}`, which is not in this workbook")
        })?;
        Ok((found.name.clone(), r))
    };
    let values = match c.get("values") {
        Some(Value::String(one)) => vec![one.clone()],
        Some(list) => strings(list, "`values`")?,
        None => return Err("a chart needs `values`, like [\"Sales!B2:B9\"]".into()),
    };
    if values.is_empty() {
        return Err("a chart needs at least one range in `values`".into());
    }
    let names = c.get("series_names").map(|v| strings(v, "`series_names`")).transpose()?.unwrap_or_default();
    let categories = c.opt_str("categories")?.map(range).transpose()?;
    let mut chart = Chart::new(kind);
    if let Some(title) = c.opt_str("title")? {
        chart.title().set_name(title);
    }
    for (i, text) in values.iter().enumerate() {
        let (sheet, (r0, c0, r1, c1)) = range(text)?;
        let series = chart.add_series();
        series.set_values((sheet.as_str(), r0, c0, r1, c1));
        if let Some((sheet, (r0, c0, r1, c1))) = &categories {
            series.set_categories((sheet.as_str(), *r0, *c0, *r1, *c1));
        }
        if let Some(name) = names.get(i) {
            series.set_name(name.as_str());
        }
    }
    let anchor = c.opt_str("anchor")?.map(parse_cell).transpose()?;
    Ok((chart, anchor))
}

/// A summary table built from SUMIFS/COUNTIFS formulas — not a PivotTable.
fn write_summary(workbook: &mut Workbook, value: &Value, i: usize, specs: &[SheetSpec], cells: usize) -> Result<(String, usize, usize), String> {
    let what = format!("summary[{i}]");
    let s = Args::new(value, &what, &["source_sheet", "group_by_column", "sum_columns", "target_sheet"])?;
    let source_name = s.str("source_sheet")?;
    let source = specs
        .iter()
        .find(|p| p.name.eq_ignore_ascii_case(source_name))
        .ok_or_else(|| format!("{what}: no sheet named `{source_name}` in `sheets`"))?;
    let target = s.opt_str("target_sheet")?.map(str::to_string).unwrap_or_else(|| format!("{} summary", source.name));
    if specs.iter().any(|p| p.name.eq_ignore_ascii_case(&target)) {
        return Err(format!("{what}: target_sheet `{target}` is already one of `sheets`; name a new sheet"));
    }
    let header = source.rows.first().and_then(Value::as_array).ok_or_else(|| {
        format!("{what}: `{}` needs a first row of column names", source.name)
    })?;
    let column = |key: &str| -> Result<u16, String> {
        if let Some(c) = header.iter().position(|h| h.as_str().is_some_and(|h| h.trim().eq_ignore_ascii_case(key.trim()))) {
            return Ok(c as u16);
        }
        match parse_cell(&format!("{key}1")) {
            Ok((_, c)) if usize::from(c) < source.width() => Ok(c),
            _ => Err(format!("{what}: `{key}` is neither a column name in the first row of `{}` nor a column letter", source.name)),
        }
    };
    let group_col = column(s.str("group_by_column")?)?;
    let sum_cols: Vec<u16> = strings(s.get("sum_columns").ok_or_else(|| format!("{what} needs `sum_columns`"))?, "`sum_columns`")?.iter().map(|k| column(k)).collect::<Result<_, _>>()?;
    let data = &source.rows[1..];
    if data.is_empty() {
        return Err(format!("{what}: `{}` has no rows under its header", source.name));
    }
    let cell = |row: &Value, c: u16| row.as_array().and_then(|r| r.get(usize::from(c))).cloned().unwrap_or(Value::Null);
    // Groups in the order they first appear; empty group values are not counted.
    let mut groups: Vec<Value> = Vec::new();
    let mut seen = HashMap::new();
    for row in data {
        let g = cell(row, group_col);
        if matches!(&g, Value::Null) || g.as_str().is_some_and(|t| t.trim().is_empty()) || g.is_object() {
            continue;
        }
        seen.entry(g.to_string()).or_insert_with(|| {
            groups.push(g.clone());
            groups.len() - 1
        });
    }
    let written = (groups.len() + 2) * (sum_cols.len() + 2);
    if cells + written > MAX_CELLS {
        return Err(format!("the summary would take the workbook over {MAX_CELLS} cells"));
    }
    let header_text = |c: u16| plain_text(&header.get(usize::from(c)).cloned().unwrap_or(Value::Null)).unwrap_or_default();
    let src = quote_sheet_name(&source.name);
    let last = data.len() + 1;
    let col_ref = |c: u16| {
        let l = column_number_to_name(c);
        format!("{src}!${l}$2:${l}${last}")
    };
    // Cached results, so a preview that does not recalculate shows the right numbers;
    // left out for a group that sums a formula, whose value only Excel/Numbers know.
    let mut counts = vec![0u64; groups.len()];
    let mut sums: Vec<Vec<Option<f64>>> = sum_cols.iter().map(|_| vec![Some(0.0); groups.len()]).collect();
    for row in data {
        let Some(g) = seen.get(&cell(row, group_col).to_string()) else { continue };
        counts[*g] += 1;
        for (k, c) in sum_cols.iter().enumerate() {
            let slot = &mut sums[k][*g];
            match (cell(row, *c), slot.as_mut()) {
                (Value::Number(n), Some(total)) => *total += n.as_f64().unwrap_or(0.0),
                (Value::Object(_), _) => *slot = None,
                _ => {}
            }
        }
    }
    let ws = workbook.add_worksheet();
    ws.set_name(&target).map_err(|e| format!("{what}: sheet name `{target}`: {e}"))?;
    let bold = Format::new().set_bold();
    let e = |e: rust_xlsxwriter::XlsxError| format!("{what}: {e}");
    ws.write_string_with_format(0, 0, header_text(group_col), &bold).map_err(e)?;
    ws.write_string_with_format(0, 1, "Count", &bold).map_err(e)?;
    for (k, c) in sum_cols.iter().enumerate() {
        ws.write_string_with_format(0, k as u16 + 2, format!("Sum of {}", header_text(*c)), &bold).map_err(e)?;
    }
    let mut formulas = 0;
    for (g, value) in groups.iter().enumerate() {
        let row = g as u32 + 1;
        write_cell(ws, row, 0, value, None, false)?;
        let criterion = match value.as_str() {
            // Text with wildcards or a leading operator would not match itself.
            Some(t) if t.contains(['*', '?', '~']) || t.starts_with(['<', '>', '=']) => format!(
                "\"=\"&SUBSTITUTE(SUBSTITUTE(SUBSTITUTE($A{r},\"~\",\"~~\"),\"*\",\"~*\"),\"?\",\"~?\")",
                r = row + 1
            ),
            _ => format!("$A{}", row + 1),
        };
        let count = Formula::new(format!("COUNTIFS({},{criterion})", col_ref(group_col))).set_result(counts[g].to_string());
        ws.write_formula(row, 1, count).map_err(e)?;
        for (k, c) in sum_cols.iter().enumerate() {
            let mut f = Formula::new(format!("SUMIFS({},{},{criterion})", col_ref(*c), col_ref(group_col)));
            if let Some(total) = sums[k][g] {
                f = f.set_result(total.to_string());
            }
            ws.write_formula(row, k as u16 + 2, f).map_err(e)?;
        }
        formulas += 1 + sum_cols.len();
    }
    let total_row = groups.len() as u32 + 1;
    ws.write_string_with_format(total_row, 0, "Total", &bold).map_err(e)?;
    for k in 0..sum_cols.len() + 1 {
        let col = k as u16 + 1;
        let l = column_number_to_name(col);
        let mut f = Formula::new(format!("SUM({l}2:{l}{total_row})"));
        let result = match k {
            0 => Some(counts.iter().sum::<u64>() as f64),
            _ => sums[k - 1].iter().copied().sum::<Option<f64>>(),
        };
        if let Some(r) = result {
            f = f.set_result(r.to_string());
        }
        ws.write_formula_with_format(total_row, col, f, &bold).map_err(e)?;
        formulas += 1;
    }
    ws.set_freeze_panes(1, 0).map_err(e)?;
    ws.autofit();
    Ok((
        format!(
            "Sheet \"{target}\": formula summary of \"{}\" by {} — {} groups, built with COUNTIFS/SUMIFS (not a PivotTable)",
            source.name,
            header_text(group_col),
            groups.len()
        ),
        formulas,
        written,
    ))
}

// ---------- read_spreadsheet ----------

pub fn read_spreadsheet(roots: &Roots, args: &Value) -> Result<String, String> {
    let a = Args::new(args, "read_spreadsheet", &["path", "sheet", "range", "max_rows"])?;
    let path = roots.read_target(a.str("path")?)?;
    let max_rows = a.opt_u64("max_rows")?.unwrap_or(200).clamp(1, 10_000) as usize;
    let range = a.opt_str("range")?.map(parse_range).transpose()?;
    let ext = extension(&path);
    if ext == "csv" {
        let text = String::from_utf8_lossy(&read_bytes(&path)?).into_owned();
        let rows = parse_csv(text.trim_start_matches('\u{feff}'));
        let width = rows.iter().map(Vec::len).max().unwrap_or(0);
        let get = |r: u32, c: u16| rows.get(r as usize).and_then(|row| row.get(usize::from(c))).cloned().unwrap_or_default();
        let bounds = (!rows.is_empty() && width > 0).then(|| (0, 0, rows.len() as u32 - 1, width as u16 - 1));
        let mut out = format!("{} (CSV)\n", roots.show(&path));
        out.push_str(&table_text(bounds, range, max_rows, |r, c| (get(r, c), None)));
        return Ok(out);
    }
    if !["xlsx", "xlsm", "xlsb", "xls", "ods"].contains(&ext.as_str()) {
        return Err("read_spreadsheet reads .xlsx, .xlsm, .xlsb, .xls, .ods and .csv files".into());
    }
    let mut book = open_workbook_auto(&path).map_err(|e| format!("could not open {}: {e}", roots.show(&path)))?;
    let names = book.sheet_names();
    let name = match a.opt_str("sheet")? {
        Some(want) => names
            .iter()
            .find(|n| n.eq_ignore_ascii_case(want))
            .cloned()
            .ok_or_else(|| format!("no sheet named `{want}`; the sheets are: {}", names.join(", ")))?,
        None => names.first().cloned().ok_or("the workbook has no sheets")?,
    };
    let values = book.worksheet_range(&name).map_err(|e| format!("sheet `{name}`: {e}"))?;
    // formulas only where the format exposes them (xlsx/xlsb/ods); an .xls shows values.
    let formulas = book.worksheet_formula(&name).ok();
    let mut bounds: Option<CellRange> = None;
    let mut grow = |start: Option<(u32, u32)>, end: Option<(u32, u32)>| {
        if let (Some((r0, c0)), Some((r1, c1))) = (start, end) {
            let (c0, c1) = (c0.min(u32::from(MAX_COL)) as u16, c1.min(u32::from(MAX_COL)) as u16);
            bounds = Some(match bounds {
                None => (r0, c0, r1, c1),
                Some((a, b, c, d)) => (a.min(r0), b.min(c0), c.max(r1), d.max(c1)),
            });
        }
    };
    grow(values.start(), values.end());
    if let Some(f) = &formulas {
        grow(f.start(), f.end());
    }
    let mut any_formula = false;
    let body = table_text(bounds, range, max_rows, |r, c| {
        let value = values.get_value((r, u32::from(c))).map(data_text).unwrap_or_default();
        let formula = formulas
            .as_ref()
            .and_then(|f| f.get_value((r, u32::from(c))))
            .filter(|f| !f.is_empty())
            .map(|f| format!("={}", f.trim_start_matches('=')));
        any_formula |= formula.is_some();
        (value, formula)
    });
    let mut out = format!("{}\nSheets: {}\nSheet \"{name}\"", roots.show(&path), names.join(", "));
    out.push_str(&format!(":\n{body}"));
    if any_formula {
        out.push_str("\nShown as =FORMULA → value; the value is what the program that last saved the file calculated.");
    }
    Ok(out)
}

fn fmt_number(f: f64) -> String {
    if f.fract() == 0.0 && f.abs() < 1e15 {
        format!("{}", f as i64)
    } else {
        format!("{f}")
    }
}

fn data_text(data: &Data) -> String {
    match data {
        Data::Float(f) => fmt_number(*f),
        Data::Bool(b) => if *b { "TRUE" } else { "FALSE" }.into(),
        Data::DateTime(d) if d.is_datetime() => {
            let (y, mo, da, h, mi, s, _) = d.to_ymd_hms_milli();
            if (h, mi, s) == (0, 0, 0) {
                format!("{y:04}-{mo:02}-{da:02}")
            } else {
                format!("{y:04}-{mo:02}-{da:02} {h:02}:{mi:02}:{s:02}")
            }
        }
        other => other.to_string(),
    }
}

/// The cells of `bounds` (cut to `range`) as rows `N | a | b | …`, at most `max_rows`.
fn table_text(
    bounds: Option<CellRange>,
    range: Option<CellRange>,
    max_rows: usize,
    mut cell: impl FnMut(u32, u16) -> (String, Option<String>),
) -> String {
    let Some((br0, bc0, br1, bc1)) = bounds else { return "(empty)".into() };
    let used = format!("{}:{}", cell_name(br0, bc0), cell_name(br1, bc1));
    let (r0, c0, r1, c1) = match range {
        Some((r0, c0, r1, c1)) => (r0, c0, r1.min(br1), c1.min(bc1)),
        None => (br0, bc0, br1, bc1),
    };
    if r0 > r1 || c0 > c1 {
        return format!("used range {used}; nothing in the range asked for");
    }
    let mut out = format!("used range {used}\n   |");
    for c in c0..=c1 {
        out.push_str(&format!(" {} |", column_number_to_name(c)));
    }
    let escape = |t: &str| t.replace('|', "\\|").replace("\r\n", "\\n").replace(['\n', '\r'], "\\n");
    for (shown, r) in (r0..=r1).enumerate() {
        if shown == max_rows || out.len() > MAX_OUTPUT_CHARS {
            out.push_str(&format!(
                "\n… rows {}–{} not shown; ask again with `range` (e.g. \"{}:{}\") or a larger `max_rows`.",
                r + 1,
                r1 + 1,
                cell_name(r, c0),
                cell_name(r1, c1)
            ));
            break;
        }
        out.push_str(&format!("\n{} |", r + 1));
        for c in c0..=c1 {
            let (value, formula) = cell(r, c);
            let text = match formula {
                Some(f) if value.is_empty() => f,
                Some(f) => format!("{f} → {value}"),
                None => value,
            };
            out.push_str(&format!(" {} |", escape(&text)));
        }
    }
    out
}

/// RFC 4180, leniently: quoted fields may hold commas, quotes ("") and newlines.
pub fn parse_csv(text: &str) -> Vec<Vec<String>> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut rows = Vec::new();
    let mut row = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        match (quoted, ch) {
            (true, '"') if chars.peek() == Some(&'"') => {
                field.push('"');
                chars.next();
            }
            (true, '"') => quoted = false,
            (true, c) => field.push(c),
            (false, '"') if field.is_empty() => quoted = true,
            (false, ',') => row.push(std::mem::take(&mut field)),
            (false, '\r') if chars.peek() == Some(&'\n') => {}
            (false, '\n' | '\r') => {
                row.push(std::mem::take(&mut field));
                rows.push(std::mem::take(&mut row));
            }
            (false, c) => field.push(c),
        }
    }
    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        rows.push(row);
    }
    rows
}

// ---------- edit_spreadsheet ----------

pub fn edit_spreadsheet(roots: &Roots, args: &Value) -> Result<String, String> {
    let a = Args::new(args, "edit_spreadsheet", &["path", "edits", "add_sheet", "save_as", "overwrite", "create_dirs"])?;
    let source = roots.read_target(a.str("path")?)?;
    if extension(&source) != "xlsx" {
        return Err("edit_spreadsheet edits .xlsx files only".into());
    }
    let overwrite = a.bool("overwrite")?;
    let target = match a.opt_str("save_as")? {
        Some(save_as) => roots.write_target(save_as, a.bool("create_dirs")?)?,
        None if overwrite => source.clone(),
        None => {
            return Err(format!(
                "give `save_as` (a new .xlsx path such as {}) or `overwrite: true` to change {} itself",
                roots.show(&crate::paths::free_name(&source)),
                roots.show(&source)
            ))
        }
    };
    if extension(&target) != "xlsx" {
        return Err("`save_as` must end with .xlsx".into());
    }
    let new_sheets = match a.get("add_sheet") {
        None => Vec::new(),
        Some(Value::String(one)) => vec![one.clone()],
        Some(list) => strings(list, "`add_sheet`")?,
    };
    let edits = a.opt_array("edits")?.map(Vec::as_slice).unwrap_or_default();
    if edits.is_empty() && new_sheets.is_empty() {
        return Err("nothing to do: give `edits` and/or `add_sheet`".into());
    }
    if edits.len() > MAX_CELLS {
        return Err(format!("{} edits is over the limit of {MAX_CELLS}", edits.len()));
    }
    let mut book = umya_spreadsheet::reader::xlsx::read(&source).map_err(|e| format!("could not open {}: {e}", roots.show(&source)))?;
    for name in &new_sheets {
        book.new_sheet(name.as_str()).map_err(|e| format!("could not add sheet `{name}`: {e}"))?;
    }
    let sheet_names: Vec<String> = book.sheet_collection().iter().map(|s| s.name().to_string()).collect();
    let mut changed: Vec<String> = Vec::new();
    let mut formulas = 0;
    for (i, edit) in edits.iter().enumerate() {
        let what = format!("edits[{i}]");
        let e = Args::new(edit, &what, &["sheet", "cell", "value", "formula"])?;
        let sheet = match e.opt_str("sheet")? {
            Some(want) => sheet_names
                .iter()
                .find(|n| n.eq_ignore_ascii_case(want))
                .ok_or_else(|| format!("{what}: no sheet named `{want}`; the sheets are: {}", sheet_names.join(", ")))?,
            None if sheet_names.len() == 1 => &sheet_names[0],
            None => return Err(format!("{what} needs `sheet`; the sheets are: {}", sheet_names.join(", "))),
        };
        let (row, col) = parse_cell(e.str("cell")?).map_err(|m| format!("{what}: {m}"))?;
        let has_value = edit.as_object().is_some_and(|m| m.contains_key("value"));
        let ws = book.sheet_by_name_mut(sheet).map_err(|m| format!("{what}: {m}"))?;
        let cell = ws.cell_mut((u32::from(col) + 1, row + 1));
        match (e.opt_str("formula")?, has_value) {
            (Some(_), true) => return Err(format!("{what}: give `value` or `formula`, not both")),
            (Some(f), false) => {
                let f = f.trim();
                if !f.starts_with('=') || f.len() < 2 {
                    return Err(format!("{what}: a formula starts with =, like =SUM(A2:A9)"));
                }
                // Clear the old cached result so nothing shows a stale number.
                cell.set_blank();
                cell.set_formula(f.trim_start_matches('='));
                formulas += 1;
            }
            (None, true) => match &edit["value"] {
                Value::Null => {
                    cell.set_blank();
                }
                Value::String(s) => {
                    cell.set_value_string(s.as_str());
                }
                Value::Number(n) => {
                    cell.set_value_number(n.as_f64().ok_or_else(|| format!("{what}: the number is out of range"))?);
                }
                Value::Bool(b) => {
                    cell.set_value_bool(*b);
                }
                _ => return Err(format!("{what}: `value` must be text, a number, true/false or null")),
            },
            (None, false) => return Err(format!("{what} needs `value` or `formula`")),
        }
        changed.push(format!("{sheet}!{}", cell_name(row, col)));
    }
    let mut bytes = Vec::new();
    umya_spreadsheet::writer::xlsx::write_writer(&book, &mut bytes).map_err(|e| format!("could not build the workbook: {e}"))?;
    write_file(roots, &target, &bytes, overwrite)?;
    let mut text = format!("Saved {} ({}).", roots.show(&target), human_size(bytes.len() as u64));
    if !changed.is_empty() {
        let list = if changed.len() <= 20 { changed.join(", ") } else { format!("{} … and {} more", changed[..20].join(", "), changed.len() - 20) };
        text.push_str(&format!(" Changed {} cells: {list}.", changed.len()));
    }
    if !new_sheets.is_empty() {
        text.push_str(&format!(" Added sheets: {}.", new_sheets.join(", ")));
    }
    if target != source {
        text.push_str(&format!(" The original {} is unchanged.", roots.show(&source)));
    }
    if formulas > 0 || !changed.is_empty() {
        text.push_str(&format!(" {RECALC_NOTE}"));
    }
    Ok(text)
}

// ---------- make_csv ----------

pub fn make_csv(roots: &Roots, args: &Value) -> Result<String, String> {
    let a = Args::new(args, "make_csv", &["path", "rows", "overwrite", "create_dirs", "bom"])?;
    let target = roots.write_target(a.str("path")?, a.bool("create_dirs")?)?;
    if extension(&target) != "csv" {
        return Err("make_csv writes .csv files; end `path` with .csv".into());
    }
    let rows = a.array("rows")?;
    let cells: usize = rows.iter().filter_map(Value::as_array).map(Vec::len).sum();
    if cells > MAX_CELLS {
        return Err(format!("{cells} cells is over the limit of {MAX_CELLS}"));
    }
    // A byte-order mark by default: without one, Excel on the Mac reads UTF-8 as
    // Mac Roman and garbles every accented letter. Numbers and others ignore it.
    let mut out = if args.get("bom").and_then(Value::as_bool).unwrap_or(true) { String::from('\u{feff}') } else { String::new() };
    for (r, row) in rows.iter().enumerate() {
        let row = row.as_array().ok_or_else(|| format!("rows[{r}] must be a list of cells"))?;
        let fields: Vec<String> = row
            .iter()
            .map(|cell| {
                plain_text(cell)
                    // Text only: a number like -5 is data, not a formula.
                    .map(|t| if cell.is_string() { defuse_formula(&t) } else { t })
                    .map(|t| csv_field(&t))
                    .map_err(|e| format!("rows[{r}]: {e} (a CSV file has no formulas)"))
            })
            .collect::<Result<_, _>>()?;
        out.push_str(&fields.join(","));
        out.push_str("\r\n");
    }
    write_file(roots, &target, out.as_bytes(), a.bool("overwrite")?)?;
    let width = rows.iter().filter_map(Value::as_array).map(Vec::len).max().unwrap_or(0);
    Ok(format!("Wrote {} ({}): {} rows × {width} columns, UTF-8, comma-separated.", roots.show(&target), human_size(out.len() as u64), rows.len()))
}

/// Text a spreadsheet would run as a formula when the CSV is opened (=, +, -, @,
/// tab, carriage return) gets a leading apostrophe, so it shows as text
/// (OWASP "CSV injection"). Cookie writes text it found on pages and files.
pub fn defuse_formula(text: &str) -> String {
    if text.starts_with(['=', '+', '-', '@', '\t', '\r']) {
        format!("'{text}")
    } else {
        text.to_string()
    }
}

/// A field quoted when it holds a comma, quote or line break (RFC 4180).
pub fn csv_field(text: &str) -> String {
    if text.contains([',', '"', '\r', '\n']) {
        format!("\"{}\"", text.replace('"', "\"\""))
    } else {
        text.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use calamine::{open_workbook_auto, Data, Reader};
    use serde_json::json;
    use std::io::Read;

    fn setup() -> (tempfile::TempDir, Roots) {
        let dir = tempfile::tempdir().unwrap();
        let roots = Roots::new(&[dir.path().to_path_buf()], Some(dir.path().to_path_buf())).unwrap();
        (dir, roots)
    }

    fn zip_names(path: &std::path::Path) -> Vec<String> {
        let archive = zip::ZipArchive::new(std::fs::File::open(path).unwrap()).unwrap();
        archive.file_names().map(str::to_string).collect()
    }

    fn sample() -> serde_json::Value {
        json!({
            "path": "q3.xlsx",
            "sheets": [
                {
                    "name": "Sales",
                    "header": true,
                    "column_widths": [14, 10, null, 12],
                    "number_formats": [null, "#,##0.00", null, "yyyy-mm-dd"],
                    "rows": [
                        ["Region", "Revenue", "Units", "Date"],
                        ["North", 1200.5, 3, "2026-03-01"],
                        ["South", 800, 2, "2026-03-02"],
                        ["North", 300, 1, "2026-03-03"],
                        ["Total", {"formula": "=SUM(B2:B4)"}, {"formula": "=SUM(C2:C4)"}, null]
                    ],
                    "charts": [{"type": "column", "title": "Revenue", "categories": "Sales!A2:A4", "values": ["Sales!B2:B4"], "series_names": ["Revenue"]}]
                },
                {
                    "name": "My Data",
                    "header": true,
                    "table": true,
                    "rows": [["Item", "Qty"], ["a<b & \"c\"", 5], ["=not a formula", 7]],
                    "charts": [{"type": "pie", "categories": "'My Data'!A2:A3", "values": "'My Data'!B2:B3", "anchor": "E2"}]
                }
            ],
            "summary": {"source_sheet": "Sales", "group_by_column": "Region", "sum_columns": ["Revenue", "C"], "target_sheet": "By region"}
        })
    }

    #[test]
    fn cell_references_parse() {
        assert_eq!(parse_cell("B7").unwrap(), (6, 1));
        assert_eq!(parse_cell("$AA$10").unwrap(), (9, 26));
        assert!(parse_cell("7B").is_err() && parse_cell("A0").is_err() && parse_cell("XFE1").is_err());
        assert_eq!(parse_range("F50:A1").unwrap(), (0, 0, 49, 5));
        assert_eq!(parse_sheet_range("'It''s'!A1:B2").unwrap(), ("It's".into(), (0, 0, 1, 1)));
        assert!(parse_sheet_range("A1:B2").is_err());
    }

    #[test]
    fn make_spreadsheet_writes_values_formulas_charts_tables_and_a_summary() {
        let (dir, roots) = setup();
        let text = make_spreadsheet(&roots, &sample()).unwrap();
        assert!(text.contains(RECALC_NOTE), "{text}");
        assert!(text.contains("not a PivotTable"), "{text}");
        let path = dir.path().join("q3.xlsx");

        let mut book = open_workbook_auto(&path).unwrap();
        assert_eq!(book.sheet_names(), vec!["Sales", "My Data", "By region"]);
        let sales = book.worksheet_range("Sales").unwrap();
        assert_eq!(sales.get_value((0, 0)), Some(&Data::String("Region".into())));
        assert_eq!(sales.get_value((1, 1)), Some(&Data::Float(1200.5)));
        assert!(matches!(sales.get_value((1, 3)), Some(Data::DateTime(_))), "an ISO date in a date column is a real date");
        let data = book.worksheet_range("My Data").unwrap();
        assert_eq!(data.get_value((1, 0)), Some(&Data::String("a<b & \"c\"".into())));
        assert_eq!(data.get_value((2, 0)), Some(&Data::String("=not a formula".into())), "text is never turned into a formula");
        // The summary carries correct cached results, so previews show numbers.
        let summary = book.worksheet_range("By region").unwrap();
        assert_eq!(summary.get_value((0, 2)), Some(&Data::String("Sum of Revenue".into())));
        assert_eq!(summary.get_value((1, 0)), Some(&Data::String("North".into())));
        assert_eq!(summary.get_value((1, 1)), Some(&Data::Float(2.0)));
        assert_eq!(summary.get_value((1, 2)), Some(&Data::Float(1500.5)));
        assert_eq!(summary.get_value((2, 2)), Some(&Data::Float(800.0)));
        // "Total" in Sales is a group too, holding a formula: its Revenue sum has no cached value.
        assert_eq!(summary.get_value((3, 0)), Some(&Data::String("Total".into())));

        let wb = umya_spreadsheet::reader::xlsx::read(&path).unwrap();
        let sales = wb.sheet_by_name("Sales").unwrap();
        assert_eq!(sales.cell("B5").unwrap().formula(), "SUM(B2:B4)");
        let by_region = wb.sheet_by_name("By region").unwrap();
        assert_eq!(by_region.cell("B2").unwrap().formula(), "COUNTIFS(Sales!$A$2:$A$5,$A2)");
        assert_eq!(by_region.cell("C2").unwrap().formula(), "SUMIFS(Sales!$B$2:$B$5,Sales!$A$2:$A$5,$A2)");
        assert_eq!(by_region.cell("D5").unwrap().formula(), "SUM(D2:D4)");

        let names = zip_names(&path);
        assert!(names.contains(&"xl/charts/chart1.xml".to_string()) && names.contains(&"xl/charts/chart2.xml".to_string()));
        assert!(names.contains(&"xl/tables/table1.xml".to_string()));
        let mut chart2 = String::new();
        zip::ZipArchive::new(std::fs::File::open(&path).unwrap()).unwrap().by_name("xl/charts/chart2.xml").unwrap().read_to_string(&mut chart2).unwrap();
        assert!(chart2.contains("'My Data'!$B$2:$B$3"), "{chart2}");
    }

    #[test]
    fn summary_criteria_escape_wildcards() {
        let (dir, roots) = setup();
        let args = json!({"path": "w.xlsx", "sheets": [{"name": "D", "header": true, "rows": [["K", "V"], ["a*", 1], ["ab", 2]]}],
            "summary": {"source_sheet": "D", "group_by_column": "K", "sum_columns": ["V"]}});
        make_spreadsheet(&roots, &args).unwrap();
        let wb = umya_spreadsheet::reader::xlsx::read(dir.path().join("w.xlsx")).unwrap();
        let f = wb.sheet_by_name("D summary").unwrap().cell("B2").unwrap().formula().to_string();
        assert!(f.contains("SUBSTITUTE") && f.contains("~*"), "{f}");
        assert_eq!(wb.sheet_by_name("D summary").unwrap().cell("B3").unwrap().formula(), "COUNTIFS(D!$A$2:$A$3,$A3)");
    }

    #[test]
    fn an_existing_workbook_is_not_overwritten() {
        let (dir, roots) = setup();
        make_spreadsheet(&roots, &json!({"path": "a.xlsx", "sheets": [{"rows": [[1]]}]})).unwrap();
        let before = std::fs::read(dir.path().join("a.xlsx")).unwrap();
        let error = make_spreadsheet(&roots, &json!({"path": "a.xlsx", "sheets": [{"rows": [[2]]}]})).unwrap_err();
        assert!(error.contains("already exists") && error.contains("a-2.xlsx"), "{error}");
        assert_eq!(std::fs::read(dir.path().join("a.xlsx")).unwrap(), before);
        make_spreadsheet(&roots, &json!({"path": "a.xlsx", "overwrite": true, "sheets": [{"rows": [[2]]}]})).unwrap();
        assert_ne!(std::fs::read(dir.path().join("a.xlsx")).unwrap(), before);
    }

    #[test]
    fn limits_and_bad_input_are_refused() {
        let (_dir, roots) = setup();
        let row: Vec<i32> = vec![1; 1000];
        let rows: Vec<Vec<i32>> = vec![row; 201];
        let error = make_spreadsheet(&roots, &json!({"path": "big.xlsx", "sheets": [{"rows": rows}]})).unwrap_err();
        assert!(error.contains("over the limit"), "{error}");
        assert!(make_spreadsheet(&roots, &json!({"path": "x.xls", "sheets": [{"rows": [[1]]}]})).unwrap_err().contains(".xlsx"));
        assert!(make_spreadsheet(&roots, &json!({"path": "x.xlsx", "sheet": []})).unwrap_err().contains("unknown field `sheet`"));
        let bad_chart = json!({"path": "c.xlsx", "sheets": [{"name": "S", "rows": [[1]], "charts": [{"type": "column", "values": ["Nope!A1:A2"]}]}]});
        assert!(make_spreadsheet(&roots, &bad_chart).unwrap_err().contains("not in this workbook"));
        let bad_formula = json!({"path": "f.xlsx", "sheets": [{"rows": [[{"formula": "SUM(A1)"}]]}]});
        assert!(make_spreadsheet(&roots, &bad_formula).unwrap_err().contains("starts with ="));
    }

    #[test]
    fn read_spreadsheet_shows_values_and_formulas() {
        let (_dir, roots) = setup();
        make_spreadsheet(&roots, &sample()).unwrap();
        let text = read_spreadsheet(&roots, &json!({"path": "q3.xlsx"})).unwrap();
        assert!(text.contains("Sheets: Sales, My Data, By region"), "{text}");
        assert!(text.contains("| Region | Revenue | Units | Date |"), "{text}");
        assert!(text.contains("1200.5") && text.contains("2026-03-01"), "{text}");
        assert!(text.contains("=SUM(B2:B4)"), "{text}");
        let part = read_spreadsheet(&roots, &json!({"path": "q3.xlsx", "sheet": "by region", "range": "A1:B2"})).unwrap();
        assert!(part.contains("Sheet \"By region\"") && part.contains("=COUNTIFS(Sales!$A$2:$A$5,$A2) → 2"), "{part}");
        assert!(!part.contains("Sum of"), "the range cuts columns: {part}");
        let short = read_spreadsheet(&roots, &json!({"path": "q3.xlsx", "max_rows": 2})).unwrap();
        assert!(short.contains("rows 3–5 not shown"), "{short}");
    }

    #[test]
    fn edit_spreadsheet_saves_a_copy_and_keeps_the_rest() {
        let (dir, roots) = setup();
        make_spreadsheet(&roots, &sample()).unwrap();
        let original = std::fs::read(dir.path().join("q3.xlsx")).unwrap();
        assert!(edit_spreadsheet(&roots, &json!({"path": "q3.xlsx", "edits": [{"sheet": "Sales", "cell": "B2", "value": 1}]})).unwrap_err().contains("save_as"));
        let text = edit_spreadsheet(
            &roots,
            &json!({
                "path": "q3.xlsx",
                "save_as": "q3-edited.xlsx",
                "add_sheet": "Notes",
                "edits": [
                    {"sheet": "Sales", "cell": "B2", "value": 999},
                    {"sheet": "sales", "cell": "E1", "value": "Note"},
                    {"sheet": "Sales", "cell": "B6", "formula": "=B5*2"},
                    {"sheet": "Notes", "cell": "A1", "value": true},
                    {"sheet": "Sales", "cell": "C2", "value": null}
                ]
            }),
        )
        .unwrap();
        assert!(text.contains("Changed 5 cells") && text.contains("is unchanged") && text.contains(RECALC_NOTE), "{text}");
        assert_eq!(std::fs::read(dir.path().join("q3.xlsx")).unwrap(), original);
        let edited = dir.path().join("q3-edited.xlsx");
        let mut book = open_workbook_auto(&edited).unwrap();
        assert_eq!(book.sheet_names(), vec!["Sales", "My Data", "By region", "Notes"]);
        let sales = book.worksheet_range("Sales").unwrap();
        assert_eq!(sales.get_value((1, 1)), Some(&Data::Float(999.0)));
        assert_eq!(sales.get_value((0, 4)), Some(&Data::String("Note".into())));
        assert_eq!(sales.get_value((2, 0)), Some(&Data::String("South".into())), "untouched cells are kept");
        assert!(matches!(sales.get_value((1, 2)), None | Some(Data::Empty)));
        assert_eq!(book.worksheet_range("Notes").unwrap().get_value((0, 0)), Some(&Data::Bool(true)));
        let wb = umya_spreadsheet::reader::xlsx::read(&edited).unwrap();
        assert_eq!(wb.sheet_by_name("Sales").unwrap().cell("B6").unwrap().formula(), "B5*2");
        assert_eq!(wb.sheet_by_name("Sales").unwrap().cell("B5").unwrap().formula(), "SUM(B2:B4)");
        let names = zip_names(&edited);
        assert!(names.contains(&"xl/charts/chart1.xml".to_string()), "charts survive the edit: {names:?}");
        assert!(names.contains(&"xl/tables/table1.xml".to_string()), "tables survive the edit: {names:?}");
        // Overwriting the original in place.
        edit_spreadsheet(&roots, &json!({"path": "q3.xlsx", "overwrite": true, "edits": [{"sheet": "Sales", "cell": "A2", "value": "East"}]})).unwrap();
        let mut book = open_workbook_auto(dir.path().join("q3.xlsx")).unwrap();
        assert_eq!(book.worksheet_range("Sales").unwrap().get_value((1, 0)), Some(&Data::String("East".into())));
        // A bad cell reference is an error, not a crash.
        let bad = edit_spreadsheet(&roots, &json!({"path": "q3.xlsx", "overwrite": true, "edits": [{"sheet": "Sales", "cell": "B", "value": 1}]}));
        assert!(bad.unwrap_err().contains("not a cell"));
    }

    #[test]
    fn csv_text_that_a_spreadsheet_would_run_is_defused_and_excel_reads_utf8() {
        let (dir, roots) = setup();
        let rows = json!([["=HYPERLINK(\"http://x\",\"click\")", "+1+1", "-cmd", "@SUM(A1)", -5, "Rīga"]]);
        make_csv(&roots, &json!({"path": "i.csv", "rows": rows})).unwrap();
        let raw = std::fs::read_to_string(dir.path().join("i.csv")).unwrap();
        assert!(raw.starts_with('\u{feff}'), "a BOM so Excel reads UTF-8");
        assert_eq!(&raw['\u{feff}'.len_utf8()..], "\"'=HYPERLINK(\"\"http://x\"\",\"\"click\"\")\",'+1+1,'-cmd,'@SUM(A1),-5,Rīga\r\n");
        let shown = read_spreadsheet(&roots, &json!({"path": "i.csv"})).unwrap();
        assert!(shown.contains("Rīga") && !shown.contains('\u{feff}'), "{shown}");
        make_csv(&roots, &json!({"path": "n.csv", "rows": [["a"]], "bom": false})).unwrap();
        assert_eq!(std::fs::read_to_string(dir.path().join("n.csv")).unwrap(), "a\r\n");
    }

    #[test]
    fn make_csv_quotes_per_rfc_4180_and_reads_back() {
        let (dir, roots) = setup();
        let rows = json!([["name", "note", "n"], ["Ann", "says \"hi\", then leaves", 3], ["Bo", "line1\nline2", null], [true, "", 1.5]]);
        let text = make_csv(&roots, &json!({"path": "p.csv", "rows": rows, "bom": false})).unwrap();
        assert!(text.contains("4 rows × 3 columns"), "{text}");
        let raw = std::fs::read_to_string(dir.path().join("p.csv")).unwrap();
        assert_eq!(raw, "name,note,n\r\nAnn,\"says \"\"hi\"\", then leaves\",3\r\nBo,\"line1\nline2\",\r\ntrue,,1.5\r\n");
        let parsed = parse_csv(&raw);
        assert_eq!(parsed[1], vec!["Ann", "says \"hi\", then leaves", "3"]);
        assert_eq!(parsed[2], vec!["Bo", "line1\nline2", ""]);
        assert_eq!(parsed.len(), 4);
        let shown = read_spreadsheet(&roots, &json!({"path": "p.csv"})).unwrap();
        assert!(shown.contains("| Bo | line1\\nline2 |"), "{shown}");
        assert!(make_csv(&roots, &json!({"path": "f.csv", "rows": [[{"formula": "=1"}]]})).unwrap_err().contains("no formulas"));
    }
}
