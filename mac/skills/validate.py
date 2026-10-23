#!/usr/bin/env python3
"""Check every skills/*/SKILL.md against the core's skill loader (src/skills.rs)
and Cookie's product rules. Stdlib only. Exit 0 = all pass."""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent

EXPECTED = """research-report company-brief person-brief meeting-brief meeting-notes
outreach-draft follow-up-draft crm-update pipeline-report prospect-list
competitor-analysis gtm-plan linkedin-post landing-page proposal spreadsheet
document deck web-page teach-me do-it-on-my-mac""".split()

TOOLS = set("""start_task look press set_value type_text key scroll drag choose_menu
run_script open point_at wait_for_step make_spreadsheet read_spreadsheet
edit_spreadsheet make_document read_document make_page make_csv make_deck
web_search fetch_page fetch_pages check_quote recall remember
connector_actions connector_call""".split())

# Customer-facing wording (rule 6). Checked inside fenced blocks, which are the
# output templates; prose may name these words to forbid them.
BANNED = re.compile(r"\b(memory|memories|grounded|grounding|verifiable|provenance|citations?|audit\w*)\b", re.I)

# Cookie's own budgets. The harness itself sets none on skills (only MCP tool
# descriptions are cut at 2,000 chars); every description is resent in the
# use_skill listing on every turn, so keep them short.
MAX_DESCRIPTION = 250
MAX_BODY_LINES = 120
MAX_BYTES = 12_000


def fields(front: str) -> dict:
    """Mirror of skills.rs top_level_fields: top-level `key: value`, indented
    lines belong to the key above, `>` folds, `|` keeps, quotes stripped."""
    lines, out, i = front.split("\n"), {}, 0
    while i < len(lines):
        line = lines[i]; i += 1
        if line[:1] in (" ", "\t") or not line.strip() or line.lstrip().startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        value, block = value.strip(), []
        while i < len(lines) and (lines[i][:1] in (" ", "\t") or not lines[i].strip()):
            block.append(lines[i].strip()); i += 1
        if value.startswith(">"):
            value = " ".join(l for l in block if l)
        elif value.startswith("|"):
            value = "\n".join(block).rstrip()
        else:
            value = value.strip('"').strip("'")
        out.setdefault(key.strip(), value)
    return out


def check(dir_: pathlib.Path) -> list:
    errs, path = [], dir_ / "SKILL.md"
    if not path.is_file():
        return ["no SKILL.md (the harness skips this folder)"]
    extra = [p.name for p in dir_.iterdir() if p.name != "SKILL.md"]
    if extra:  # use_skill returns only the SKILL.md body; nothing else is reachable
        errs.append(f"extra files the harness never serves: {extra}")
    raw = path.read_text(encoding="utf-8")
    if len(raw.encode()) > MAX_BYTES:
        errs.append(f"{len(raw.encode())} bytes > {MAX_BYTES}")
    text = raw.lstrip("﻿").replace("\r\n", "\n")
    if not text.startswith("---"):
        return errs + ["must start with --- frontmatter"]
    rest = text[3:]
    end = rest.find("\n---")
    if end < 0:
        return errs + ["frontmatter is not closed with ---"]
    f, body = fields(rest[:end]), rest[end + 4:].strip()
    name, desc = f.get("name", ""), f.get("description", "")
    if not name:
        errs.append("frontmatter needs a name")
    elif name != dir_.name:
        errs.append(f"name {name!r} != directory {dir_.name!r}")
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name or "x"):
        errs.append(f"name {name!r} is not kebab-case")
    if not desc:
        errs.append("frontmatter needs a description")
    elif "\n" in desc or len(desc) > MAX_DESCRIPTION:
        errs.append(f"description must be one line <= {MAX_DESCRIPTION} chars (is {len(desc)})")
    if not body:
        errs.append("empty body")
    if body.count("\n") + 1 > MAX_BODY_LINES:
        errs.append(f"body {body.count(chr(10)) + 1} lines > {MAX_BODY_LINES}")
    prose = re.sub(r"```.*?```", "", body, flags=re.S)
    for tok in sorted(set(re.findall(r"`([^`\n]+)`", prose))):
        if re.fullmatch(r"[a-z][a-z0-9_]*", tok) and tok not in TOOLS:
            errs.append(f"unknown tool `{tok}`")
    for block in re.findall(r"```.*?```", body, flags=re.S):
        for word in sorted({m.group(0).lower() for m in BANNED.finditer(block)}):
            errs.append(f"banned customer word in template: {word!r}")
    return errs


def main() -> int:
    dirs = sorted(p for p in ROOT.iterdir() if p.is_dir() and not p.name.startswith((".", "_")))
    failed = 0
    missing = sorted(set(EXPECTED) - {d.name for d in dirs})
    if missing:
        print(f"FAIL missing skills: {missing}"); failed += 1
    for d in dirs:
        errs = check(d)
        failed += bool(errs)
        print(("ok   " if not errs else "FAIL ") + d.name + "".join(f"\n     - {e}" for e in errs))
    print(f"\n{len(dirs)} skills, {failed} failing")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
