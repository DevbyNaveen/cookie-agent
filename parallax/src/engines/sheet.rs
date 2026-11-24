//! Sheet: a real spreadsheet without a screen.
//!
//! A sheet is a `.sheet.json` file: named columns over rows of cells, each a
//! value or a formula (`=SUM(B2:B9)*1.21`). Formulas know cell references
//! (`B3`), ranges (`B2:B9`), `+ - * / ^`, `&` to join text, comparisons
//! (`= <> < > <= >=`), parentheses, and SUM, AVERAGE, MIN, MAX, COUNT, IF,
//! ROUND, ABS. A formula that refers to itself, directly or through others, is
//! an error, never a hang. Sheets import and export CSV.

use std::collections::{BTreeMap, HashSet};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::engine::{s, ActionSpec, Ctx, Effect, Engine};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Book {
    /// Column titles, A, B, C… in order (row 1 is the titles; data starts at row 2).
    pub columns: Vec<String>,
    /// "B3" → "12" or "=B2*2".
    pub cells: BTreeMap<String, String>,
}

/// "B12" → (column 1, row 12).
pub fn parse_ref(r: &str) -> Option<(usize, usize)> {
    let r = r.trim().to_ascii_uppercase();
    let letters: String = r.chars().take_while(|c| c.is_ascii_alphabetic()).collect();
    let digits = &r[letters.len()..];
    if letters.is_empty() || digits.is_empty() || !digits.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let col = letters.chars().fold(0usize, |acc, c| acc * 26 + (c as usize - 'A' as usize + 1)) - 1;
    Some((col, digits.parse().ok()?))
}

pub fn col_name(mut c: usize) -> String {
    let mut s = String::new();
    loop {
        s.insert(0, (b'A' + (c % 26) as u8) as char);
        if c < 26 {
            break;
        }
        c = c / 26 - 1;
    }
    s
}

#[derive(Debug, Clone, PartialEq)]
pub enum V {
    N(f64),
    T(String),
    B(bool),
    List(Vec<V>),
}

impl V {
    fn num(&self) -> Result<f64, String> {
        match self {
            V::N(n) => Ok(*n),
            V::B(b) => Ok(f64::from(u8::from(*b))),
            V::T(t) if t.trim().is_empty() => Ok(0.0),
            V::T(t) => t.trim().parse().map_err(|_| format!("“{t}” isn't a number")),
            V::List(_) => Err("a range where one value belongs".into()),
        }
    }
    fn text(&self) -> String {
        match self {
            V::N(n) if n.fract() == 0.0 && n.abs() < 1e15 => format!("{}", *n as i64),
            V::N(n) => format!("{n}"),
            V::T(t) => t.clone(),
            V::B(b) => if *b { "TRUE".into() } else { "FALSE".into() },
            V::List(l) => l.iter().map(V::text).collect::<Vec<_>>().join(","),
        }
    }
    fn flat(&self) -> Vec<V> {
        match self {
            V::List(l) => l.iter().flat_map(V::flat).collect(),
            v => vec![v.clone()],
        }
    }
}

struct Eval<'a> {
    book: &'a Book,
    seen: HashSet<String>,
}

impl Eval<'_> {
    fn cell(&mut self, r: &str) -> Result<V, String> {
        let key = r.to_ascii_uppercase();
        let raw = self.book.cells.get(&key).cloned().unwrap_or_default();
        if let Some(f) = raw.strip_prefix('=') {
            if !self.seen.insert(key.clone()) {
                return Err(format!("{key} refers to itself"));
            }
            let v = self.formula(f);
            self.seen.remove(&key);
            return v;
        }
        Ok(raw.trim().parse::<f64>().map(V::N).unwrap_or(V::T(raw)))
    }

    fn formula(&mut self, f: &str) -> Result<V, String> {
        let toks = tokens(f)?;
        let mut p = Parser { t: toks, i: 0 };
        let v = self.expr(&mut p, 0)?;
        if p.i != p.t.len() {
            return Err(format!("didn't understand “{f}”"));
        }
        Ok(v)
    }

    fn expr(&mut self, p: &mut Parser, min: u8) -> Result<V, String> {
        let mut lhs = self.unary(p)?;
        loop {
            let Some(Tok::Op(op)) = p.peek().cloned() else { break };
            let prec = match op.as_str() {
                "=" | "<>" | "<" | ">" | "<=" | ">=" => 1,
                "&" => 2,
                "+" | "-" => 3,
                "*" | "/" => 4,
                "^" => 5,
                _ => break,
            };
            if prec < min {
                break;
            }
            p.i += 1;
            let rhs = self.expr(p, if op == "^" { prec } else { prec + 1 })?;
            lhs = match op.as_str() {
                "+" => V::N(lhs.num()? + rhs.num()?),
                "-" => V::N(lhs.num()? - rhs.num()?),
                "*" => V::N(lhs.num()? * rhs.num()?),
                "/" => {
                    let d = rhs.num()?;
                    if d == 0.0 {
                        return Err("division by zero".into());
                    }
                    V::N(lhs.num()? / d)
                }
                "^" => V::N(lhs.num()?.powf(rhs.num()?)),
                "&" => V::T(lhs.text() + &rhs.text()),
                cmp => {
                    let o = match (lhs.num(), rhs.num()) {
                        (Ok(a), Ok(b)) => a.partial_cmp(&b),
                        _ => Some(lhs.text().to_lowercase().cmp(&rhs.text().to_lowercase())),
                    };
                    use std::cmp::Ordering::*;
                    V::B(match cmp {
                        "=" => o == Some(Equal),
                        "<>" => o != Some(Equal),
                        "<" => o == Some(Less),
                        ">" => o == Some(Greater),
                        "<=" => matches!(o, Some(Less | Equal)),
                        _ => matches!(o, Some(Greater | Equal)),
                    })
                }
            };
        }
        Ok(lhs)
    }

    fn unary(&mut self, p: &mut Parser) -> Result<V, String> {
        if let Some(Tok::Op(o)) = p.peek() {
            if o == "-" {
                p.i += 1;
                return Ok(V::N(-self.unary(p)?.num()?));
            }
        }
        self.atom(p)
    }

    fn atom(&mut self, p: &mut Parser) -> Result<V, String> {
        match p.next().ok_or("the formula ends too soon")? {
            Tok::Num(n) => Ok(V::N(n)),
            Tok::Str(s) => Ok(V::T(s)),
            Tok::Open => {
                let v = self.expr(p, 0)?;
                p.expect(Tok::Close)?;
                Ok(v)
            }
            Tok::Name(n) => {
                if matches!(p.peek(), Some(Tok::Open)) {
                    p.i += 1;
                    let mut args = Vec::new();
                    if !matches!(p.peek(), Some(Tok::Close)) {
                        loop {
                            args.push(self.expr(p, 0)?);
                            match p.next() {
                                Some(Tok::Comma) => continue,
                                Some(Tok::Close) => break,
                                _ => return Err(format!("{n}( is missing its )")),
                            }
                        }
                    } else {
                        p.i += 1;
                    }
                    return func(&n, args);
                }
                if matches!(p.peek(), Some(Tok::Colon)) {
                    p.i += 1;
                    let Some(Tok::Name(end)) = p.next() else { return Err("a range needs an end".into()) };
                    let ((c1, r1), (c2, r2)) = (parse_ref(&n).ok_or("bad range")?, parse_ref(&end).ok_or("bad range")?);
                    let mut out = Vec::new();
                    for r in r1.min(r2)..=r1.max(r2) {
                        for c in c1.min(c2)..=c1.max(c2) {
                            out.push(self.cell(&format!("{}{r}", col_name(c)))?);
                        }
                    }
                    return Ok(V::List(out));
                }
                match n.to_ascii_uppercase().as_str() {
                    "TRUE" => Ok(V::B(true)),
                    "FALSE" => Ok(V::B(false)),
                    _ if parse_ref(&n).is_some() => self.cell(&n),
                    _ => Err(format!("“{n}” isn't a cell or a function")),
                }
            }
            t => Err(format!("unexpected {t:?}")),
        }
    }
}

fn func(name: &str, args: Vec<V>) -> Result<V, String> {
    let nums = || -> Result<Vec<f64>, String> { args.iter().flat_map(V::flat).filter(|v| !matches!(v, V::T(t) if t.trim().is_empty())).map(|v| v.num()).collect() };
    match name.to_ascii_uppercase().as_str() {
        "SUM" => Ok(V::N(nums()?.iter().sum())),
        "AVERAGE" => {
            let n = nums()?;
            if n.is_empty() { Err("AVERAGE of nothing".into()) } else { Ok(V::N(n.iter().sum::<f64>() / n.len() as f64)) }
        }
        "MIN" => Ok(V::N(nums()?.into_iter().fold(f64::INFINITY, f64::min))),
        "MAX" => Ok(V::N(nums()?.into_iter().fold(f64::NEG_INFINITY, f64::max))),
        "COUNT" => Ok(V::N(args.iter().flat_map(V::flat).filter(|v| v.num().is_ok() && !matches!(v, V::T(t) if t.trim().is_empty())).count() as f64)),
        "ABS" => Ok(V::N(args.first().ok_or("ABS needs a value")?.num()?.abs())),
        "ROUND" => {
            let x = args.first().ok_or("ROUND needs a value")?.num()?;
            let d = args.get(1).map(|v| v.num()).transpose()?.unwrap_or(0.0);
            let f = 10f64.powi(d as i32);
            Ok(V::N((x * f).round() / f))
        }
        "IF" => {
            let c = match args.first().ok_or("IF needs a condition")? {
                V::B(b) => *b,
                v => v.num().map(|n| n != 0.0).unwrap_or(!v.text().is_empty()),
            };
            Ok(if c { args.get(1).cloned().unwrap_or(V::B(true)) } else { args.get(2).cloned().unwrap_or(V::B(false)) })
        }
        other => Err(format!("{other} isn't a function sheets know")),
    }
}

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Num(f64),
    Str(String),
    Name(String),
    Op(String),
    Open,
    Close,
    Comma,
    Colon,
}

struct Parser {
    t: Vec<Tok>,
    i: usize,
}

impl Parser {
    fn peek(&self) -> Option<&Tok> {
        self.t.get(self.i)
    }
    fn next(&mut self) -> Option<Tok> {
        let t = self.t.get(self.i).cloned();
        self.i += 1;
        t
    }
    fn expect(&mut self, t: Tok) -> Result<(), String> {
        if self.next() == Some(t.clone()) { Ok(()) } else { Err(format!("expected {t:?}")) }
    }
}

fn tokens(f: &str) -> Result<Vec<Tok>, String> {
    let c: Vec<char> = f.chars().collect();
    let (mut i, mut out) = (0, Vec::new());
    while i < c.len() {
        let ch = c[i];
        if ch.is_whitespace() {
            i += 1;
        } else if ch.is_ascii_digit() || (ch == '.' && c.get(i + 1).is_some_and(|d| d.is_ascii_digit())) {
            let st = i;
            while i < c.len() && (c[i].is_ascii_digit() || c[i] == '.') {
                i += 1;
            }
            out.push(Tok::Num(c[st..i].iter().collect::<String>().parse().map_err(|_| "a bad number")?));
        } else if ch.is_ascii_alphabetic() {
            let st = i;
            while i < c.len() && (c[i].is_ascii_alphanumeric() || c[i] == '_') {
                i += 1;
            }
            out.push(Tok::Name(c[st..i].iter().collect()));
        } else if ch == '"' {
            let st = i + 1;
            i += 1;
            while i < c.len() && c[i] != '"' {
                i += 1;
            }
            if i >= c.len() {
                return Err("a text without its closing quote".into());
            }
            out.push(Tok::Str(c[st..i].iter().collect()));
            i += 1;
        } else {
            let two: String = c[i..(i + 2).min(c.len())].iter().collect();
            let t = match (two.as_str(), ch) {
                ("<>" | "<=" | ">=", _) => {
                    i += 2;
                    Tok::Op(two)
                }
                (_, '+' | '-' | '*' | '/' | '^' | '&' | '=' | '<' | '>') => {
                    i += 1;
                    Tok::Op(ch.to_string())
                }
                (_, '(') => { i += 1; Tok::Open }
                (_, ')') => { i += 1; Tok::Close }
                (_, ',' | ';') => { i += 1; Tok::Comma }
                (_, ':') => { i += 1; Tok::Colon }
                _ => return Err(format!("“{ch}” doesn't belong in a formula")),
            };
            out.push(t);
        }
    }
    Ok(out)
}

impl Book {
    /// A cell's computed value, as text (or an error, with `#`).
    pub fn value(&self, r: &str) -> String {
        match (Eval { book: self, seen: HashSet::new() }).cell(r) {
            Ok(v) => v.text(),
            Err(e) => format!("#{e}"),
        }
    }

    fn rows(&self) -> usize {
        self.cells.keys().filter_map(|k| parse_ref(k)).map(|(_, r)| r).max().unwrap_or(1).max(1)
    }

    /// The computed table: titles, then every row's values.
    pub fn table(&self) -> Vec<Vec<String>> {
        let width = self.columns.len().max(self.cells.keys().filter_map(|k| parse_ref(k)).map(|(c, _)| c + 1).max().unwrap_or(0));
        let mut out = vec![(0..width).map(|c| self.columns.get(c).cloned().unwrap_or_else(|| col_name(c))).collect()];
        for r in 2..=self.rows() {
            out.push((0..width).map(|c| self.value(&format!("{}{r}", col_name(c)))).collect());
        }
        out
    }

    pub fn to_csv(&self) -> String {
        self.table().iter().map(|row| row.iter().map(|v| if v.contains([',', '"', '\n']) { format!("\"{}\"", v.replace('"', "\"\"")) } else { v.clone() }).collect::<Vec<_>>().join(",")).collect::<Vec<_>>().join("\n")
    }

    pub fn from_csv(text: &str) -> Book {
        let mut rows = csv_rows(text).into_iter();
        let columns = rows.next().unwrap_or_default();
        let mut cells = BTreeMap::new();
        for (i, row) in rows.enumerate() {
            for (c, v) in row.into_iter().enumerate() {
                if !v.is_empty() {
                    cells.insert(format!("{}{}", col_name(c), i + 2), v);
                }
            }
        }
        Book { columns, cells }
    }
}

/// A formula with its references to row `from` moved to row `to` (text in quotes untouched).
pub fn shift_row(f: &str, from: usize, to: usize) -> String {
    let c: Vec<char> = f.chars().collect();
    let (mut i, mut out, mut quoted) = (0, String::new(), false);
    while i < c.len() {
        if c[i] == '"' {
            quoted = !quoted;
            out.push(c[i]);
            i += 1;
        } else if !quoted && c[i].is_ascii_alphabetic() && (i == 0 || !c[i - 1].is_ascii_alphanumeric()) {
            let st = i;
            while i < c.len() && c[i].is_ascii_alphabetic() {
                i += 1;
            }
            let ds = i;
            while i < c.len() && c[i].is_ascii_digit() {
                i += 1;
            }
            let word: String = c[st..i].iter().collect();
            let digits: String = c[ds..i].iter().collect();
            if !digits.is_empty() && digits.parse::<usize>().ok() == Some(from) && (i >= c.len() || !c[i].is_ascii_alphanumeric()) {
                out.push_str(&c[st..ds].iter().collect::<String>());
                out.push_str(&to.to_string());
            } else {
                out.push_str(&word);
            }
        } else {
            out.push(c[i]);
            i += 1;
        }
    }
    out
}

/// CSV with quoted fields.
pub fn csv_rows(text: &str) -> Vec<Vec<String>> {
    let (mut rows, mut row, mut field, mut quoted) = (Vec::new(), Vec::new(), String::new(), false);
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match (c, quoted) {
            ('"', true) if chars.peek() == Some(&'"') => {
                field.push('"');
                chars.next();
            }
            ('"', _) => quoted = !quoted,
            (',', false) => row.push(std::mem::take(&mut field)),
            ('\n', false) => {
                row.push(std::mem::take(&mut field));
                rows.push(std::mem::take(&mut row));
            }
            ('\r', false) => {}
            (c, _) => field.push(c),
        }
    }
    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        rows.push(row);
    }
    rows
}

pub struct Sheet;

fn load(ctx: &Ctx, path: &str) -> Result<Book, String> {
    let raw = std::fs::read(ctx.path(path)?).map_err(|_| format!("No sheet at {path}."))?;
    serde_json::from_slice(&raw).map_err(|e| format!("{path} isn't a sheet: {e}"))
}

fn save(ctx: &Ctx, path: &str, b: &Book) -> Result<(), String> {
    let p = ctx.path(path)?;
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    std::fs::write(p, serde_json::to_vec_pretty(b).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}

fn sheet_path(p: &str) -> Result<&str, String> {
    if p.ends_with(".sheet.json") { Ok(p) } else { Err("A sheet's file ends in .sheet.json.".into()) }
}

#[async_trait]
impl Engine for Sheet {
    fn name(&self) -> &'static str {
        "sheet"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let path = json!({"type": "string", "description": "the sheet, e.g. budget.sheet.json"});
        vec![
            ActionSpec::new("sheet", "create", "Make a sheet with column titles.", json!({"type": "object", "properties": {"path": path, "columns": {"type": "array", "items": {"type": "string"}}}, "required": ["path", "columns"]}), Effect::Local),
            ActionSpec::new("sheet", "set", "Set cells: values or formulas (\"=SUM(B2:B9)\"). Row 1 is the titles; data starts at row 2.", json!({"type": "object", "properties": {"path": path, "cells": {"type": "object", "additionalProperties": {"type": "string"}, "description": "{\"B3\": \"12\", \"C3\": \"=B3*2\"}"}}, "required": ["path", "cells"]}), Effect::Local),
            ActionSpec::new("sheet", "add_row", "Add a row at the end: values by column title.", json!({"type": "object", "properties": {"path": path, "values": {"type": "object"}}, "required": ["path", "values"]}), Effect::Local),
            ActionSpec::new("sheet", "add_column", "Add a column (after the last, or after `after`), optionally with a formula for every row using {row}: \"=B{row}*C{row}\".", json!({"type": "object", "properties": {"path": path, "title": {"type": "string"}, "after": {"type": "string"}, "formula": {"type": "string"}}, "required": ["path", "title"]}), Effect::Local),
            ActionSpec::new("sheet", "get", "Read computed values: a cell, a range (\"A1:C9\"), or the whole table.", json!({"type": "object", "properties": {"path": path, "range": {"type": "string"}}, "required": ["path"]}), Effect::Read),
            ActionSpec::new("sheet", "import_csv", "Make a sheet from a CSV file in the world.", json!({"type": "object", "properties": {"path": path, "csv": {"type": "string"}}, "required": ["path", "csv"]}), Effect::Local),
            ActionSpec::new("sheet", "export_csv", "Write the computed sheet to a CSV file in the world.", json!({"type": "object", "properties": {"path": path, "csv": {"type": "string"}}, "required": ["path", "csv"]}), Effect::Local),
        ]
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        let path = sheet_path(s(args, "path")?)?;
        match action {
            "create" => {
                if ctx.path(path)?.exists() {
                    return Err("A sheet is already there.".into());
                }
                let columns: Vec<String> = serde_json::from_value(args["columns"].clone()).map_err(|e| e.to_string())?;
                save(ctx, path, &Book { columns, cells: BTreeMap::new() })?;
                Ok(json!({"made": path}))
            }
            "set" => {
                let mut b = load(ctx, path)?;
                let cells: BTreeMap<String, Value> = serde_json::from_value(args["cells"].clone()).map_err(|e| e.to_string())?;
                for (k, v) in cells {
                    let (c, r) = parse_ref(&k).ok_or_else(|| format!("{k} isn't a cell."))?;
                    if r < 2 {
                        return Err("Row 1 holds the titles; data starts at row 2.".into());
                    }
                    let v = match v { Value::String(s) => s, Value::Null => String::new(), v => v.to_string() };
                    let key = format!("{}{r}", col_name(c));
                    if v.is_empty() { b.cells.remove(&key); } else { b.cells.insert(key, v); }
                }
                save(ctx, path, &b)?;
                Ok(json!({"table": b.table()}))
            }
            "add_row" => {
                let mut b = load(ctx, path)?;
                let r = b.rows() + 1;
                let values = args["values"].as_object().ok_or("Needs `values`.")?;
                for (title, v) in values {
                    let c = b.columns.iter().position(|t| t.eq_ignore_ascii_case(title)).ok_or_else(|| format!("No column “{title}”."))?;
                    let v = match v { Value::String(s) => s.clone(), v => v.to_string() };
                    b.cells.insert(format!("{}{r}", col_name(c)), v);
                }
                // A column whose row above holds a formula carries it down, its same-row references moved to this row.
                if r > 2 {
                    for c in 0..b.columns.len() {
                        let key = format!("{}{r}", col_name(c));
                        if b.cells.contains_key(&key) {
                            continue;
                        }
                        if let Some(f) = b.cells.get(&format!("{}{}", col_name(c), r - 1)).filter(|f| f.starts_with('=')).cloned() {
                            b.cells.insert(key, shift_row(&f, r - 1, r));
                        }
                    }
                }
                save(ctx, path, &b)?;
                Ok(json!({"row": r, "table": b.table()}))
            }
            "add_column" => {
                let mut b = load(ctx, path)?;
                let title = s(args, "title")?.to_string();
                if b.columns.iter().any(|t| t.eq_ignore_ascii_case(&title)) {
                    return Err(format!("There is already a column “{title}”."));
                }
                let at = match args["after"].as_str() {
                    Some(a) => b.columns.iter().position(|t| t.eq_ignore_ascii_case(a)).ok_or_else(|| format!("No column “{a}”."))? + 1,
                    None => b.columns.len(),
                };
                // Shift cells right of the new column one place, from the right.
                let mut moved = BTreeMap::new();
                for (k, v) in std::mem::take(&mut b.cells) {
                    let (c, r) = parse_ref(&k).unwrap_or((0, 0));
                    let nc = if c >= at { c + 1 } else { c };
                    moved.insert(format!("{}{r}", col_name(nc)), v);
                }
                b.cells = moved;
                b.columns.insert(at, title.clone());
                if let Some(f) = args["formula"].as_str() {
                    for r in 2..=b.rows() {
                        b.cells.insert(format!("{}{r}", col_name(at)), f.replace("{row}", &r.to_string()));
                    }
                }
                save(ctx, path, &b)?;
                Ok(json!({"column": col_name(at), "title": title, "table": b.table()}))
            }
            "get" => {
                let b = load(ctx, path)?;
                match args["range"].as_str() {
                    None => Ok(json!({"columns": b.columns, "table": b.table()})),
                    Some(r) if r.contains(':') => {
                        let (a, z) = r.split_once(':').unwrap();
                        let ((c1, r1), (c2, r2)) = (parse_ref(a).ok_or("bad range")?, parse_ref(z).ok_or("bad range")?);
                        let rows: Vec<Vec<String>> = (r1.min(r2)..=r1.max(r2)).map(|r| (c1.min(c2)..=c1.max(c2)).map(|c| b.value(&format!("{}{r}", col_name(c)))).collect()).collect();
                        Ok(json!({"range": r, "values": rows}))
                    }
                    Some(c) => Ok(json!({"cell": c, "value": b.value(c), "raw": b.cells.get(&c.to_ascii_uppercase())})),
                }
            }
            "import_csv" => {
                let text = std::fs::read_to_string(ctx.path(s(args, "csv")?)?).map_err(|e| e.to_string())?;
                let b = Book::from_csv(&text);
                save(ctx, path, &b)?;
                Ok(json!({"made": path, "columns": b.columns, "rows": b.rows() - 1}))
            }
            "export_csv" => {
                let b = load(ctx, path)?;
                let out = ctx.path(s(args, "csv")?)?;
                std::fs::write(&out, b.to_csv()).map_err(|e| e.to_string())?;
                Ok(json!({"written": s(args, "csv")?}))
            }
            other => Err(format!("The sheet engine has no action {other}.")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn book(cells: &[(&str, &str)]) -> Book {
        Book { columns: vec!["Item".into(), "Qty".into(), "Price".into()], cells: cells.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect() }
    }

    #[test]
    fn formulas_compute_like_a_spreadsheet() {
        let b = book(&[("B2", "2"), ("C2", "10"), ("B3", "3"), ("C3", "5"), ("D2", "=B2*C2"), ("D3", "=B3*C3"), ("D4", "=SUM(D2:D3)*1.21"), ("E2", "=IF(D4>40,\"big\",\"small\")"), ("F2", "=ROUND(AVERAGE(C2:C3),1)"), ("G2", "=A2&\"!\""), ("A2", "pens")]);
        assert_eq!(b.value("D4"), "42.35");
        assert_eq!(b.value("E2"), "big");
        assert_eq!(b.value("F2"), "7.5");
        assert_eq!(b.value("G2"), "pens!");
        assert_eq!(book(&[("A2", "=2+3*4^2")]).value("A2"), "50");
        assert_eq!(book(&[("A2", "=-(1-4)")]).value("A2"), "3");
    }

    #[test]
    fn a_loop_or_a_bad_formula_is_an_error_not_a_hang() {
        let b = book(&[("A2", "=B2+1"), ("B2", "=A2+1"), ("C2", "=1/0"), ("D2", "=NOPE(1)")]);
        assert!(b.value("A2").starts_with('#'));
        assert!(b.value("C2").contains("zero"));
        assert!(b.value("D2").starts_with('#'));
    }

    #[test]
    fn csv_round_trips_with_quotes() {
        let b = Book::from_csv("Name,Note\n\"Smith, J\",\"says \"\"hi\"\"\"\n");
        assert_eq!(b.value("A2"), "Smith, J");
        assert_eq!(b.value("B2"), "says \"hi\"");
        assert!(b.to_csv().contains("\"Smith, J\""));
        assert_eq!(col_name(27), "AB");
        assert_eq!(shift_row("=B5*C5+SUM(B2:B5)&\"B5\"", 5, 6), "=B6*C6+SUM(B2:B6)&\"B5\"");
        assert_eq!(parse_ref("AB3"), Some((27, 3)));
    }
}
