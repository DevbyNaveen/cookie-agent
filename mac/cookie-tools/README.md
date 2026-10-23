# cookie-tools

A stdio MCP server that makes and edits files on this Mac for Cookie: Excel
workbooks, Word documents, web pages and CSV files. Cookie starts one for
every run; it reads JSON-RPC from stdin, writes JSON-RPC to stdout, and
touches only the folders it was started with.

```sh
cookie-tools --root ~/Documents --root ~/Desktop
```

It speaks MCP `2025-06-18` (and answers `2025-03-26` / `2024-11-05` clients in
their own version): `initialize`, `ping`, `tools/list`, `tools/call`. Tool
failures come back as `isError: true` with a sentence saying what to do;
unknown tools and methods are JSON-RPC errors.

## Tools

| Tool | Arguments | Never |
|---|---|---|
| `make_spreadsheet` | `path`, `sheets: [{name, rows, header?, column_widths?, number_formats?, charts?: [{type, title?, categories?, values, series_names?, anchor?}], table?}]`, `summary?: {source_sheet, group_by_column, sum_columns, target_sheet?}`, `overwrite?`, `create_dirs?` | makes a PivotTable |
| `read_spreadsheet` | `path`, `sheet?`, `range?` (`"A1:F50"`), `max_rows?` (200) | changes the file |
| `edit_spreadsheet` | `path`, `edits: [{sheet?, cell, value \| formula}]`, `add_sheet?`, `save_as?`, `overwrite?`, `create_dirs?` | changes the original without `overwrite: true` |
| `make_document` | `path`, `title?`, `blocks`, `overwrite?`, `create_dirs?` | — |
| `read_document` | `path` (.docx, .txt, .md, .html) | runs anything in the file |
| `make_page` | `path`, `title`, `blocks` (plus `{html}`), `overwrite?`, `create_dirs?` | lets a script run |
| `make_csv` | `path`, `rows`, `overwrite?`, `create_dirs?` | writes formulas |

A cell is text, a number, `true`/`false`, `null`, or `{"formula": "=SUM(A2:A9)"}`.
Text that starts with `=` stays text. Blocks are `{heading, level?}`,
`{paragraph}`, `{bullets}`, `{numbered}`, `{table: {header?, rows}}`,
`{page_break: true}`, and for pages `{html}`.

- **Formulas** are written as formulas. The workbook asks Excel to recalculate
  on open; every result says *formulas will calculate when the file is opened
  in Excel/Numbers*. The `summary` sheet also stores the totals it computed,
  so Quick Look shows numbers, except for groups that sum a formula.
- **Dates**: in a column whose number format is a date (`"yyyy-mm-dd"`), text
  like `2026-03-01` is written as a real date.
- **Summary, not PivotTable**: no MIT/Apache Rust crate writes real Excel
  PivotTables, so `summary` writes a sheet of COUNTIFS/SUMIFS formulas grouped
  by one column, with a total row. It says so in its description and result.
- **Editing** uses umya-spreadsheet, which rewrites the whole workbook.
  Values, formulas, other sheets, charts and tables made by `make_spreadsheet`
  survive (tested); parts it does not model (PivotTables, macros, some chart
  formatting) may not, which is why `save_as` to a new file is the default.
- **Reading** shows formulas as `=FORMULA → value`, where the value is what the
  program that last saved the file calculated. `.xls` files show values only.

## Safety

- Every path must end up inside a `--root`. `~/` is the home folder; a
  relative path goes in the first root. `..` is refused outright. The folder
  is resolved through symlinks before the check, so a link out of a root is
  refused, and a file being read is resolved too.
- A missing folder is an error unless `create_dirs: true`, and then folders
  are made only under a root.
- An existing file is never replaced unless `overwrite: true`; the error names
  a free name such as `report-2.xlsx`. Writes go to a temporary file in the same
  folder and are then linked into place (the link fails if the name is taken),
  so nobody sees a half-written file. Replacing a symlink replaces the link,
  never the file it points to.
- Limits: 200,000 cells per spreadsheet or CSV write, 10 MB per file read,
  5,000 blocks per document or page, 100,000 characters of text returned.
- `make_page` escapes all text; `{html}` blocks go through ammonia's
  allow-list (no `<script>`, no `on…` attributes, no `javascript:` URLs, no
  frames or forms), and the page carries a Content-Security-Policy that blocks
  scripts. It loads nothing but `https:` images an `{html}` block names.
- No network access, no subprocesses. A crash inside a file library becomes
  that call's error; the server keeps running.

## How Cookie starts it

With Cookie's core, as a first-party server whose read tools are lowered to
`Read` and whose writers are `Write` (the annotations are `readOnlyHint` for
the readers and `destructiveHint: false` for the writers, which the harness
treats as "ask a person" until the run lowers them):

```rust
let files = McpServer::stdio("cookie-tools", &["--root", &documents, "--root", &desktop])
    .first_party()
    .effect("read_spreadsheet", Effect::Read)
    .effect("read_document", Effect::Read)
    .effect("make_spreadsheet", Effect::Write)
    .effect("edit_spreadsheet", Effect::Write)
    .effect("make_document", Effect::Write)
    .effect("make_page", Effect::Write)
    .effect("make_csv", Effect::Write)
    .connect()
    .await?;
```

`overwrite: true` replaces a person's file; to have that value come only from
the person, also `.guard("<tool>", "overwrite")` on the writers.

## Build and test

```sh
cargo test                     # 21 unit tests + 2 that spawn the binary and speak MCP
cargo clippy --all-targets
cargo build --release          # target/release/cookie-tools
```

## THIRD_PARTY

Direct dependencies, pinned in `Cargo.toml`:

| Crate | Version | Licence | Used for |
|---|---|---|---|
| rust_xlsxwriter | 0.99.1 | MIT OR Apache-2.0 | writing .xlsx |
| calamine | 0.36.1 | MIT | reading .xlsx/.xls/.xlsb/.ods |
| umya-spreadsheet | 3.1.1 | MIT | editing .xlsx |
| docx-rs | 0.4.22 (no default features) | MIT | writing .docx |
| zip | 8.6.0 (deflate only) | MIT | opening .docx to read it |
| quick-xml | 0.41.0 | MIT | reading `word/document.xml` |
| ammonia | 4.2.3 | MIT OR Apache-2.0 | sanitising HTML, HTML to text |
| serde_json | 1.0.154 | MIT OR Apache-2.0 | JSON-RPC |
| tempfile (tests only) | 3.27.0 | MIT OR Apache-2.0 | test folders |

Transitive dependencies (163 crates in the build) are MIT and/or Apache-2.0
except: `cssparser` and `dtoa-short` (MPL-2.0, through ammonia; file-level
copyleft, unmodified here), the ICU4X crates (`icu_*`, `zerovec`, `yoke`,
`tinystr`, … — Unicode-3.0), `encoding_rs` (MIT/Apache-2.0 AND BSD-3-Clause),
`zlib-rs` (Zlib), `zopfli` (Apache-2.0), and `memchr`, `aho-corasick`,
`byteorder`, `jiff` (Unlicense OR MIT). `cargo tree -e normal --format '{p} {l}'`
prints the full list.
