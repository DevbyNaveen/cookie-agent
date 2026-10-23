//! Word documents and web pages: make and read.

use std::io::{Cursor, Read};

use docx_rs::{
    AbstractNumbering, BreakType, Docx, IndentLevel, Level, LevelJc, LevelText, LineSpacing, NumberFormat, Numbering,
    NumberingId, Paragraph, Run, Shading, SpecialIndentType, Start, Style, StyleType, Table, TableCell, TableRow, WidthType,
};
use serde_json::Value;

use crate::{
    args::{plain_text, strings, Args},
    paths::{extension, human_size, read_bytes, write_file, Roots},
};

pub const MAX_BLOCKS: usize = 5_000;
/// The most text `read_document` returns.
const MAX_OUTPUT_CHARS: usize = 100_000;
/// The most `word/document.xml` may expand to.
const MAX_XML_BYTES: u64 = 50 * 1024 * 1024;

#[derive(Debug, PartialEq)]
pub enum Block {
    Heading(String, u8),
    Paragraph(String),
    Bullets(Vec<String>),
    Numbered(Vec<String>),
    Table(Vec<String>, Vec<Vec<String>>),
    PageBreak,
    Html(String),
}

pub fn parse_blocks(list: &[Value], allow_html: bool) -> Result<Vec<Block>, String> {
    if list.len() > MAX_BLOCKS {
        return Err(format!("{} blocks is over the limit of {MAX_BLOCKS}", list.len()));
    }
    let kinds: &[&str] = if allow_html {
        &["heading", "paragraph", "bullets", "numbered", "table", "page_break", "html"]
    } else {
        &["heading", "paragraph", "bullets", "numbered", "table", "page_break"]
    };
    let mut allowed = kinds.to_vec();
    allowed.push("level");
    list.iter()
        .enumerate()
        .map(|(i, value)| {
            let what = format!("blocks[{i}]");
            let b = Args::new(value, &what, &allowed)?;
            let present: Vec<&str> = kinds.iter().copied().filter(|k| b.has(k)).collect();
            let [kind] = present[..] else {
                return Err(format!("{what} needs exactly one of: {}", kinds.join(", ")));
            };
            Ok(match kind {
                "heading" => {
                    let level = b.opt_u64("level")?.unwrap_or(1);
                    if !(1..=3).contains(&level) {
                        return Err(format!("{what}: `level` is 1, 2 or 3"));
                    }
                    Block::Heading(clean(b.str("heading")?), level as u8)
                }
                "paragraph" => Block::Paragraph(clean(b.str("paragraph")?)),
                "bullets" => Block::Bullets(strings(&value["bullets"], &format!("{what}.bullets"))?.iter().map(|s| clean(s)).collect()),
                "numbered" => Block::Numbered(strings(&value["numbered"], &format!("{what}.numbered"))?.iter().map(|s| clean(s)).collect()),
                "table" => {
                    let t = Args::new(&value["table"], &format!("{what}.table"), &["header", "rows"])?;
                    let header = t.get("header").map(|h| strings(h, &format!("{what}.table.header"))).transpose()?.unwrap_or_default();
                    let rows = t
                        .array("rows")?
                        .iter()
                        .map(|row| {
                            row.as_array()
                                .ok_or_else(|| format!("{what}.table.rows must be lists of cells"))?
                                .iter()
                                .map(|c| plain_text(c).map(|t| clean(&t)))
                                .collect::<Result<Vec<_>, _>>()
                        })
                        .collect::<Result<Vec<_>, _>>()?;
                    Block::Table(header.iter().map(|s| clean(s)).collect(), rows)
                }
                "page_break" => Block::PageBreak,
                "html" => Block::Html(b.str("html")?.to_string()),
                _ => unreachable!(),
            })
        })
        .collect()
}

/// Text without the control characters XML cannot hold.
fn clean(text: &str) -> String {
    text.chars().filter(|c| !c.is_control() || matches!(c, '\t' | '\n')).collect()
}

// ---------- make_document ----------

fn heading_style(id: &str, name: &str, size: usize, outline: usize, before: u32) -> Style {
    Style::new(id, StyleType::Paragraph)
        .name(name)
        .based_on("Normal")
        .next("Normal")
        .q_format(true)
        .bold()
        .size(size)
        .outline_lvl(outline)
        .line_spacing(LineSpacing::new().before(before).after(120))
}

fn text_paragraph(text: &str) -> Paragraph {
    let mut run = Run::new();
    for (i, line) in text.split('\n').enumerate() {
        if i > 0 {
            run = run.add_break(BreakType::TextWrapping);
        }
        for (j, part) in line.split('\t').enumerate() {
            if j > 0 {
                run = run.add_tab();
            }
            if !part.is_empty() {
                run = run.add_text(part);
            }
        }
    }
    Paragraph::new().add_run(run)
}

fn list_level(format: &str, text: &str) -> Level {
    Level::new(0, Start::new(1), NumberFormat::new(format), LevelText::new(text), LevelJc::new("left"))
        .indent(Some(720), Some(SpecialIndentType::Hanging(360)), None, None)
}

pub fn make_document(roots: &Roots, args: &Value) -> Result<String, String> {
    let a = Args::new(args, "make_document", &["path", "title", "blocks", "overwrite", "create_dirs"])?;
    let target = roots.write_target(a.str("path")?, a.bool("create_dirs")?)?;
    if extension(&target) != "docx" {
        return Err("make_document writes .docx files; end `path` with .docx".into());
    }
    let blocks = parse_blocks(a.array("blocks")?, false)?;
    let mut doc = Docx::new()
        .default_size(22)
        .default_line_spacing(LineSpacing::new().after(160).line(276))
        .add_style(heading_style("Title", "Title", 52, 0, 0))
        .add_style(heading_style("Heading1", "heading 1", 32, 0, 360))
        .add_style(heading_style("Heading2", "heading 2", 26, 1, 240))
        .add_style(heading_style("Heading3", "heading 3", 24, 2, 240))
        .add_abstract_numbering(AbstractNumbering::new(1).add_level(list_level("bullet", "•")))
        .add_numbering(Numbering::new(1, 1));
    if let Some(title) = a.opt_str("title")? {
        doc = doc.add_paragraph(text_paragraph(&clean(title)).style("Title"));
    }
    let mut next_list = 2;
    let (mut tables, mut words) = (0, 0);
    for block in &blocks {
        doc = match block {
            Block::Heading(text, level) => {
                words += text.split_whitespace().count();
                doc.add_paragraph(text_paragraph(text).style(&format!("Heading{level}")).keep_next(true))
            }
            Block::Paragraph(text) => {
                words += text.split_whitespace().count();
                doc.add_paragraph(text_paragraph(text))
            }
            Block::Bullets(items) => items.iter().fold(doc, |doc, item| {
                words += item.split_whitespace().count();
                doc.add_paragraph(text_paragraph(item).numbering(NumberingId::new(1), IndentLevel::new(0)))
            }),
            Block::Numbered(items) => {
                // Each list gets its own numbering so it starts again at 1.
                let id = next_list;
                next_list += 1;
                let doc = doc
                    .add_abstract_numbering(AbstractNumbering::new(id).add_level(list_level("decimal", "%1.")))
                    .add_numbering(Numbering::new(id, id));
                items.iter().fold(doc, |doc, item| {
                    words += item.split_whitespace().count();
                    doc.add_paragraph(text_paragraph(item).numbering(NumberingId::new(id), IndentLevel::new(0)))
                })
            }
            Block::Table(header, rows) => {
                tables += 1;
                let cols = rows.iter().map(Vec::len).chain([header.len()]).max().unwrap_or(0).max(1);
                // equal columns over the usable width of an A4/Letter page.
                let width = 9_000 / cols;
                let cell = |text: &str, bold: bool| {
                    let mut p = text_paragraph(text);
                    if bold {
                        p = p.bold();
                    }
                    let c = TableCell::new().width(width, WidthType::Dxa).add_paragraph(p);
                    if bold {
                        c.shading(Shading::new().fill("F2F2F2"))
                    } else {
                        c
                    }
                };
                let row = |cells: &[String], bold: bool| {
                    TableRow::new((0..cols).map(|i| cell(cells.get(i).map(String::as_str).unwrap_or(""), bold)).collect())
                };
                let mut table_rows = Vec::new();
                if !header.is_empty() {
                    table_rows.push(row(header, true));
                }
                table_rows.extend(rows.iter().map(|r| row(r, false)));
                if table_rows.is_empty() {
                    doc
                } else {
                    let table = Table::new(table_rows).set_grid(vec![width; cols]).width(width * cols, WidthType::Dxa);
                    doc.add_table(table).add_paragraph(Paragraph::new())
                }
            }
            Block::PageBreak => doc.add_paragraph(Paragraph::new().add_run(Run::new().add_break(BreakType::Page))),
            Block::Html(_) => unreachable!("parse_blocks refuses html for documents"),
        };
    }
    let mut bytes = Cursor::new(Vec::new());
    doc.build().pack(&mut bytes).map_err(|e| format!("could not build the document: {e}"))?;
    let bytes = bytes.into_inner();
    write_file(roots, &target, &bytes, a.bool("overwrite")?)?;
    Ok(format!(
        "Wrote {} ({}): {} blocks, about {words} words{}.",
        roots.show(&target),
        human_size(bytes.len() as u64),
        blocks.len(),
        match tables {
            0 => String::new(),
            1 => ", 1 table".into(),
            n => format!(", {n} tables"),
        }
    ))
}

// ---------- read_document ----------

pub fn read_document(roots: &Roots, args: &Value) -> Result<String, String> {
    let a = Args::new(args, "read_document", &["path"])?;
    let path = roots.read_target(a.str("path")?)?;
    let bytes = read_bytes(&path)?;
    let text = match extension(&path).as_str() {
        "docx" => docx_text(&bytes)?,
        "txt" | "md" | "markdown" | "text" => String::from_utf8_lossy(&bytes).trim_start_matches('\u{feff}').to_string(),
        "html" | "htm" => html_text(&String::from_utf8_lossy(&bytes)),
        _ => return Err("read_document reads .docx, .txt, .md and .html files (spreadsheets: read_spreadsheet)".into()),
    };
    let total = text.chars().count();
    let mut out = format!("{} ({} characters)\n\n", roots.show(&path), total);
    if total > MAX_OUTPUT_CHARS {
        out.extend(text.chars().take(MAX_OUTPUT_CHARS));
        out.push_str(&format!("\n\n… the remaining {} characters are not shown.", total - MAX_OUTPUT_CHARS));
    } else {
        out.push_str(&text);
    }
    Ok(out)
}

/// The text of a .docx body: `#` headings, `- ` list items, tables as `a | b` rows.
pub fn docx_text(bytes: &[u8]) -> Result<String, String> {
    use quick_xml::events::Event;
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes)).map_err(|e| format!("not a .docx file: {e}"))?;
    let mut xml = String::new();
    archive
        .by_name("word/document.xml")
        .map_err(|_| "not a .docx file: word/document.xml is missing".to_string())?
        .take(MAX_XML_BYTES)
        .read_to_string(&mut xml)
        .map_err(|e| format!("could not read the document: {e}"))?;
    let mut reader = quick_xml::Reader::from_str(&xml);
    let mut out = String::new();
    let mut para = String::new();
    let mut prefix = String::new();
    let mut in_text = false;
    let mut in_tab_stops = false;
    let mut table_depth = 0;
    let mut row: Vec<String> = Vec::new();
    let mut cell = String::new();
    loop {
        let event = reader.read_event().map_err(|e| format!("the document XML is broken: {e}"))?;
        match event {
            Event::Start(ref e) | Event::Empty(ref e) => {
                let opening = matches!(event, Event::Start(_));
                match e.local_name().as_ref() {
                    b"t" if opening => in_text = true,
                    b"tabs" if opening => in_tab_stops = true,
                    b"tab" if !in_tab_stops => para.push('\t'),
                    b"br" | b"cr" => para.push('\n'),
                    b"tbl" if opening => table_depth += 1,
                    b"pStyle" => {
                        let style = e
                            .try_get_attribute("w:val")
                            .ok()
                            .flatten()
                            .and_then(|v| v.normalized_value(quick_xml::XmlVersion::Implicit1_0).ok().map(|v| v.into_owned()))
                            .unwrap_or_default();
                        let lower = style.to_ascii_lowercase();
                        prefix = match lower.strip_prefix("heading") {
                            Some(n) => format!("{} ", "#".repeat(n.trim().parse::<usize>().unwrap_or(1).clamp(1, 6))),
                            None if lower == "title" => "# ".into(),
                            None => prefix,
                        };
                    }
                    b"numPr" if prefix.is_empty() => prefix = "- ".into(),
                    _ => {}
                }
            }
            Event::Text(t) if in_text => para.push_str(&t.decode().map_err(|e| e.to_string())?),
            Event::GeneralRef(r) if in_text => {
                if let Ok(Some(ch)) = r.resolve_char_ref() {
                    para.push(ch);
                } else if let Some(s) = quick_xml::escape::resolve_predefined_entity(&r.decode().map_err(|e| e.to_string())?) {
                    para.push_str(s);
                }
            }
            Event::CData(t) if in_text => para.push_str(&String::from_utf8_lossy(&t)),
            Event::End(e) => match e.local_name().as_ref() {
                b"t" => in_text = false,
                b"tabs" => in_tab_stops = false,
                b"p" => {
                    let text = std::mem::take(&mut para);
                    let line = format!("{}{}", std::mem::take(&mut prefix), text.trim_end());
                    if table_depth > 0 {
                        if !cell.is_empty() {
                            cell.push(' ');
                        }
                        cell.push_str(text.trim());
                    } else if !text.trim().is_empty() {
                        out.push_str(&line);
                        out.push('\n');
                    }
                }
                b"tc" if table_depth == 1 => row.push(std::mem::take(&mut cell).replace('\n', " ")),
                b"tr" if table_depth == 1 => {
                    out.push_str(&std::mem::take(&mut row).join(" | "));
                    out.push('\n');
                }
                b"tbl" => {
                    table_depth -= 1;
                    if table_depth == 0 {
                        out.push('\n');
                    }
                }
                _ => {}
            },
            Event::Eof => break,
            _ => {}
        }
    }
    Ok(out.trim_end().to_string())
}

/// The visible text of an HTML page; scripts and styles are dropped.
///
/// ammonia parses the page (html5ever) and keeps only structural tags with no
/// attributes; its serialiser's output is then simple enough to walk by hand:
/// text never holds a raw `<`, and only five entities appear.
pub fn html_text(html: &str) -> String {
    use std::collections::{HashMap, HashSet};
    const BLOCK: [&str; 28] = [
        "p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "blockquote", "pre", "ul", "ol",
        "li", "table", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "dl", "dt", "dd", "figcaption", "title",
    ];
    let tags: HashSet<&str> = BLOCK.iter().copied().chain(["br", "td", "th"]).collect();
    let clean = ammonia::Builder::empty()
        .tags(tags)
        .generic_attributes(HashSet::new())
        .tag_attributes(HashMap::new())
        .link_rel(None)
        .clean(html)
        .to_string();
    let unescape = |t: &str| {
        t.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&nbsp;", "\u{a0}").replace("&amp;", "&")
    };
    let mut out = String::new();
    let mut pre = 0usize;
    let newline = |out: &mut String| {
        while out.ends_with(' ') {
            out.pop();
        }
        if !out.is_empty() && !out.ends_with('\n') {
            out.push('\n');
        }
    };
    let mut rest = clean.as_str();
    while !rest.is_empty() {
        let (text, after) = rest.split_at(rest.find('<').unwrap_or(rest.len()));
        let text = unescape(text);
        if pre > 0 {
            out.push_str(&text);
        } else {
            let words = text.split_whitespace().collect::<Vec<_>>().join(" ");
            if text.starts_with(char::is_whitespace) && !out.is_empty() && !out.ends_with([' ', '\n']) {
                out.push(' ');
            }
            out.push_str(&words);
            if !words.is_empty() && text.ends_with(char::is_whitespace) {
                out.push(' ');
            }
        }
        let Some(close) = after.find('>') else { break };
        let tag = &after[1..close];
        rest = &after[close + 1..];
        let (closing, name) = match tag.strip_prefix('/') {
            Some(name) => (true, name),
            None => (false, tag),
        };
        if BLOCK.contains(&name) {
            newline(&mut out);
        }
        match (closing, name) {
            (false, "br") => {
                while out.ends_with(' ') {
                    out.pop();
                }
                out.push('\n');
            }
            (false, "li") => out.push_str("- "),
            (false, "h1" | "h2" | "h3" | "h4" | "h5" | "h6") => {
                out.push_str(&"#".repeat(usize::from(name.as_bytes()[1] - b'0')));
                out.push(' ');
            }
            (false, "td" | "th") if !out.is_empty() && !out.ends_with('\n') => out.push_str(" | "),
            (false, "pre") => pre += 1,
            (true, "pre") => pre = pre.saturating_sub(1),
            _ => {}
        }
    }
    let mut text = String::new();
    let mut blank = 0;
    for line in out.lines().map(str::trim_end) {
        blank = if line.trim().is_empty() { blank + 1 } else { 0 };
        if blank < 2 {
            text.push_str(line);
            text.push('\n');
        }
    }
    text.trim().to_string()
}

// ---------- make_page ----------

/// HTML with every markup character escaped.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

/// Only safe markup survives: no scripts, no `on…` handlers, no `javascript:` links,
/// no frames or forms (ammonia's allow-list).
pub fn sanitize(html: &str) -> String {
    ammonia::Builder::default().clean(html).to_string()
}

const PAGE_STYLE: &str = r#":root{color-scheme:light dark;--fg:#1d1d1f;--muted:#6e6e73;--bg:#fbfbfd;--line:#d9d9de;--accent:#0a66c2;--soft:#f0f0f4}
@media (prefers-color-scheme:dark){:root{--fg:#ececf1;--muted:#a1a1aa;--bg:#141416;--line:#34343a;--accent:#6aa9ff;--soft:#1f1f24}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:17px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
main{max-width:760px;margin:0 auto;padding:56px 24px 96px}
h1{font-size:2.1em;line-height:1.2;letter-spacing:-.02em;margin:0 0 .8em}
h2{font-size:1.45em;line-height:1.3;margin:2em 0 .6em}
h3{font-size:1.2em;margin:1.6em 0 .5em}
h4{font-size:1em;margin:1.4em 0 .4em}
p,ul,ol,table,blockquote,pre{margin:0 0 1.1em}
ul,ol{padding-left:1.4em}
li{margin:.25em 0}
a{color:var(--accent)}
img{max-width:100%;height:auto}
blockquote{border-left:3px solid var(--line);padding-left:1em;color:var(--muted)}
code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em;background:var(--soft);border-radius:6px}
code{padding:.1em .3em}
pre{padding:1em;overflow-x:auto}
.table{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:.95em}
th,td{text-align:left;padding:.55em .8em;border-bottom:1px solid var(--line);vertical-align:top}
th{font-weight:600;background:var(--soft)}
hr,.page-break{border:0;border-top:1px solid var(--line);margin:2.5em 0}
@media print{body{background:#fff;color:#000}main{padding:0}.page-break{border:0;margin:0;break-after:page}}"#;

pub fn make_page(roots: &Roots, args: &Value) -> Result<String, String> {
    let a = Args::new(args, "make_page", &["path", "title", "blocks", "overwrite", "create_dirs"])?;
    let target = roots.write_target(a.str("path")?, a.bool("create_dirs")?)?;
    if !matches!(extension(&target).as_str(), "html" | "htm") {
        return Err("make_page writes .html files; end `path` with .html".into());
    }
    let title = a.str("title")?;
    let blocks = parse_blocks(a.array("blocks")?, true)?;
    let paragraph = |t: &str| escape(t).replace('\n', "<br>");
    let mut body = String::new();
    let mut sanitized = 0;
    for block in &blocks {
        match block {
            // The page title is the only h1; heading levels 1–3 become h2–h4.
            Block::Heading(text, level) => body.push_str(&format!("<h{n}>{}</h{n}>\n", escape(text), n = level + 1)),
            Block::Paragraph(text) => body.push_str(&format!("<p>{}</p>\n", paragraph(text))),
            Block::Bullets(items) | Block::Numbered(items) => {
                let tag = if matches!(block, Block::Bullets(_)) { "ul" } else { "ol" };
                body.push_str(&format!("<{tag}>\n"));
                for item in items {
                    body.push_str(&format!("<li>{}</li>\n", paragraph(item)));
                }
                body.push_str(&format!("</{tag}>\n"));
            }
            Block::Table(header, rows) => {
                body.push_str("<div class=\"table\"><table>\n");
                if !header.is_empty() {
                    body.push_str("<thead><tr>");
                    for h in header {
                        body.push_str(&format!("<th>{}</th>", paragraph(h)));
                    }
                    body.push_str("</tr></thead>\n");
                }
                body.push_str("<tbody>\n");
                for row in rows {
                    body.push_str("<tr>");
                    for c in row {
                        body.push_str(&format!("<td>{}</td>", paragraph(c)));
                    }
                    body.push_str("</tr>\n");
                }
                body.push_str("</tbody></table></div>\n");
            }
            Block::PageBreak => body.push_str("<div class=\"page-break\"></div>\n"),
            Block::Html(html) => {
                sanitized += 1;
                body.push_str(&sanitize(html));
                body.push('\n');
            }
        }
    }
    // The policy is a second wall: even markup that slipped past the sanitiser cannot run script.
    let page = format!(
        "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src https: data:; style-src 'unsafe-inline'\">\n<meta name=\"color-scheme\" content=\"light dark\">\n<title>{t}</title>\n<style>\n{PAGE_STYLE}\n</style>\n</head>\n<body>\n<main>\n<h1>{t}</h1>\n{body}</main>\n</body>\n</html>\n",
        t = escape(&clean(title))
    );
    write_file(roots, &target, page.as_bytes(), a.bool("overwrite")?)?;
    let note = if sanitized > 0 { format!(" {sanitized} html blocks were sanitised (scripts, event handlers and javascript: links removed).") } else { String::new() };
    Ok(format!(
        "Wrote {} ({}): {} blocks, a self-contained page that runs no scripts and works in light and dark mode.{note}",
        roots.show(&target),
        human_size(page.len() as u64),
        blocks.len()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn setup() -> (tempfile::TempDir, Roots) {
        let dir = tempfile::tempdir().unwrap();
        let roots = Roots::new(&[dir.path().to_path_buf()], Some(dir.path().to_path_buf())).unwrap();
        (dir, roots)
    }

    fn blocks() -> Value {
        json!([
            {"heading": "Overview", "level": 1},
            {"paragraph": "Costs <rose> & \"fell\".\nSecond line"},
            {"heading": "Detail", "level": 2},
            {"bullets": ["one", "two"]},
            {"numbered": ["first", "second"]},
            {"table": {"header": ["Name", "Qty"], "rows": [["Pens", 3], ["Ink", null, "extra"]]}},
            {"page_break": true},
            {"paragraph": "After the break"}
        ])
    }

    #[test]
    fn make_document_reads_back() {
        let (dir, roots) = setup();
        let text = make_document(&roots, &json!({"path": "r.docx", "title": "Q3 Report", "blocks": blocks()})).unwrap();
        assert!(text.contains("8 blocks") && text.contains("1 table"), "{text}");
        let body = docx_text(&std::fs::read(dir.path().join("r.docx")).unwrap()).unwrap();
        for expected in [
            "# Q3 Report",
            "# Overview",
            "Costs <rose> & \"fell\".\nSecond line",
            "## Detail",
            "- one\n- two",
            "- first\n- second",
            "Name | Qty | \nPens | 3 | \nInk |  | extra",
            "After the break",
        ] {
            assert!(body.contains(expected), "missing {expected:?} in:\n{body}");
        }
        let shown = read_document(&roots, &json!({"path": "r.docx"})).unwrap();
        assert!(shown.contains("# Overview"), "{shown}");
        // An existing document is not replaced.
        assert!(make_document(&roots, &json!({"path": "r.docx", "blocks": []})).unwrap_err().contains("already exists"));
    }

    #[test]
    fn blocks_are_validated() {
        assert!(parse_blocks(&[json!({"paragraph": "a", "heading": "b"})], false).unwrap_err().contains("exactly one"));
        assert!(parse_blocks(&[json!({"html": "<p>x</p>"})], false).unwrap_err().contains("unknown field `html`"));
        assert!(parse_blocks(&[json!({"heading": "h", "level": 4})], false).unwrap_err().contains("1, 2 or 3"));
        let many = vec![json!({"paragraph": "x"}); MAX_BLOCKS + 1];
        assert!(parse_blocks(&many, false).unwrap_err().contains("limit"));
        assert_eq!(parse_blocks(&[json!({"paragraph": "a\u{0}b"})], false).unwrap(), vec![Block::Paragraph("ab".into())]);
    }

    #[test]
    fn sanitize_removes_scripts_handlers_and_javascript_links() {
        let dirty = r#"<p onclick="steal()">Hi <b>there</b></p><script>alert(1)</script><a href="javascript:alert(2)">x</a><a href="https://example.com">ok</a><img src=x onerror=alert(3)><iframe src="https://evil"></iframe><style>body{}</style>"#;
        let clean = sanitize(dirty);
        for banned in ["<script", "alert", "onclick", "onerror", "javascript:", "<iframe", "<style"] {
            assert!(!clean.contains(banned), "{banned} survived: {clean}");
        }
        assert!(clean.contains("<b>there</b>") && clean.contains(r#"href="https://example.com""#), "{clean}");
    }

    #[test]
    fn make_page_escapes_text_and_sanitises_html() {
        let (dir, roots) = setup();
        let mut list = blocks().as_array().unwrap().clone();
        list.push(json!({"html": "<p>kept <em>markup</em></p><script>evil()</script><a href=\"javascript:x()\" onmouseover=\"y()\">link</a>"}));
        let text = make_page(&roots, &json!({"path": "p.html", "title": "<Q3> & \"you\"", "blocks": list})).unwrap();
        assert!(text.contains("sanitised"), "{text}");
        let page = std::fs::read_to_string(dir.path().join("p.html")).unwrap();
        assert!(page.contains("<title>&lt;Q3&gt; &amp; &quot;you&quot;</title>"), "{page}");
        assert!(page.contains("<h1>&lt;Q3&gt; &amp; &quot;you&quot;</h1>"));
        assert!(page.contains("<p>Costs &lt;rose&gt; &amp; &quot;fell&quot;.<br>Second line</p>"));
        assert!(page.contains("<h2>Overview</h2>") && page.contains("<h3>Detail</h3>"));
        assert!(page.contains("<ul>\n<li>one</li>") && page.contains("<ol>\n<li>first</li>"));
        assert!(page.contains("<th>Name</th>") && page.contains("<td>Pens</td><td>3</td>"));
        assert!(page.contains("<em>markup</em>") && !page.contains("evil") && !page.contains("javascript:") && !page.contains("onmouseover"));
        assert!(page.contains("Content-Security-Policy") && page.contains("prefers-color-scheme:dark") && page.contains("max-width:760px"));
        // The page reads back as text.
        let shown = read_document(&roots, &json!({"path": "p.html"})).unwrap();
        assert!(shown.contains("# <Q3> & \"you\"") && shown.contains("## Overview") && shown.contains("- one") && shown.contains("Name | Qty"), "{shown}");
        assert!(!shown.contains("prefers-color-scheme"), "styles are not text: {shown}");
    }

    #[test]
    fn read_document_reads_text_and_html() {
        let (dir, roots) = setup();
        std::fs::write(dir.path().join("n.md"), "\u{feff}# Notes\nplain").unwrap();
        assert!(read_document(&roots, &json!({"path": "n.md"})).unwrap().ends_with("# Notes\nplain"));
        std::fs::write(
            dir.path().join("w.html"),
            "<html><head><title>T</title><script>var secret=1</script></head><body><p>A&amp;B&nbsp;C</p><pre>  x\n  y</pre></body></html>",
        )
        .unwrap();
        let text = read_document(&roots, &json!({"path": "w.html"})).unwrap();
        assert!(text.contains("A&B C") && text.contains("  x\n  y") && !text.contains("secret"), "{text}");
        assert!(read_document(&roots, &json!({"path": "x.pdf"})).is_err());
    }
}
