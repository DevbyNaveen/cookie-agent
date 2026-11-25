// A small, safe Markdown renderer for agent replies: everything is escaped
// first, then only a known set of forms becomes markup. No raw HTML passes.
// Paragraphs, headings, lists (and task lists), quotes, tables, code (with
// its language, a copy button and light highlighting), bold, italics,
// strikethrough and links. Images and links to files become placeholders the
// app fills in (`hydrateMd`): a file from the agent's own folder shows inline,
// a picture on the web loads only when clicked (an image address is a way to
// send data out, so nothing an agent read decides what this page fetches).

const Md = (() => {
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

  // A local file: file://, /abs, ~/home, ./rel, or a bare name with an extension.
  const LOCAL = String.raw`(?:file:\/\/[^\s)]+|\/[^\s)]+|~\/[^\s)]+|\.\/[^\s)]+|[\w][\w\-.%]*(?:\/[\w\-.%]+)*\.[A-Za-z0-9]{1,5})`;
  const IMG = new RegExp(String.raw`!\[([^\]\n]*)\]\((https?:\/\/[^\s)]+|${LOCAL})(?:\s+&quot;[^&]*&quot;)?\)`, "g");
  const FILE_LINK = new RegExp(String.raw`\[([^\]\n]+)\]\((${LOCAL})\)`, "g");

  function inline(s) {
    const codes = [];
    s = s.replace(/`([^`\n]+)`/g, (_, c) => `\u0000${codes.push(c) - 1}\u0000`);
    s = esc(s)
      // Pictures and files first: `![a](b)` holds a link inside it.
      .replace(IMG, (_, alt, src) => `<span class="md-media" data-src="${src}" data-alt="${alt}"></span>`)
      .replace(FILE_LINK, (_, label, src) => `<span class="md-file" data-src="${src}">${label}</span>`)
      .replace(/\*\*([^*\n]+?)\*\*/g, "<strong>$1</strong>")
      .replace(/__([^_\n]+?)__/g, "<strong>$1</strong>")
      .replace(/~~([^~\n]+?)~~/g, "<del>$1</del>")
      .replace(/(^|[^*\w])\*([^*\n]+?)\*(?!\w)/g, "$1<em>$2</em>")
      .replace(/(^|[^_\w])_([^_\n]+?)_(?!\w)/g, "$1<em>$2</em>")
      .replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>')
      .replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, '$1<a href="$2" target="_blank" rel="noreferrer">$2</a>');
    return s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${esc(codes[+i])}</code>`);
  }

  /* ---------- code: a light, language-aware colouring ---------- */
  const KEYWORDS = new Set(("as async await break case catch class const continue def default defer del do elif else enum except export extends " +
    "false fn for from func function go if impl import in interface is let loop match mod module mut new nil none null or package pass pub " +
    "raise return self Self static struct super switch then this throw trait true try type typeof undefined unsafe use var void where while with yield " +
    "and not echo fi done esac local select insert update delete into values create table join on group order by limit having").split(" "));
  const HASH_COMMENTS = /^(py|python|sh|bash|zsh|shell|rb|ruby|yaml|yml|toml|r|perl|pl|make|makefile|dockerfile|conf|ini|nix|elixir|ex)$/i;
  const DASH_COMMENTS = /^(sql|lua|haskell|hs)$/i;

  function highlight(code, lang) {
    if (/^(text|txt|plain|output|log|diff)$/i.test(lang) || code.length > 60_000) {
      if (/^diff$/i.test(lang)) return code.split("\n").map((l) => `<span class="${l.startsWith("+") ? "tk-add" : l.startsWith("-") ? "tk-del" : ""}">${esc(l)}</span>`).join("\n");
      return esc(code);
    }
    const line = HASH_COMMENTS.test(lang) ? "#[^\\n]*" : DASH_COMMENTS.test(lang) ? "--[^\\n]*" : "\\/\\/[^\\n]*";
    const re = new RegExp(`(${line}|\\/\\*[\\s\\S]*?\\*\\/)|("(?:\\\\.|[^"\\\\\\n])*"|'(?:\\\\.|[^'\\\\\\n])*'|\`(?:\\\\.|[^\`\\\\])*\`)|\\b(\\d[\\d_]*(?:\\.\\d+)?(?:e[+-]?\\d+)?|0x[\\da-f]+)\\b|([A-Za-z_][\\w$]*)`, "gi");
    let out = "", last = 0;
    for (const m of code.matchAll(re)) {
      out += esc(code.slice(last, m.index));
      const [t, comment, str, num, word] = m;
      if (comment) out += `<span class="tk-c">${esc(t)}</span>`;
      else if (str) out += `<span class="tk-s">${esc(t)}</span>`;
      else if (num) out += `<span class="tk-n">${esc(t)}</span>`;
      else if (word && KEYWORDS.has(word)) out += `<span class="tk-k">${esc(t)}</span>`;
      else if (word && code[m.index + t.length] === "(") out += `<span class="tk-f">${esc(t)}</span>`;
      else out += esc(t);
      last = m.index + t.length;
    }
    return out + esc(code.slice(last));
  }

  // Blocks Cookie draws (blocks.js): a flow, a chart, a form, a board. The text stays as written.
  const DRAWN = new Set(["flow", "chart", "form", "board"]);

  function codeBlock(body, lang) {
    if (DRAWN.has(lang.toLowerCase())) return `<div class="md-block md-${lang.toLowerCase()}" data-src="${esc(body)}"></div>`;
    const label = lang ? esc(lang) : "code";
    return `<div class="md-code"><div class="md-code-head"><span>${label}</span><button type="button" class="md-copy" aria-label="Copy code">Copy</button></div><pre><code>${highlight(body, lang)}</code></pre></div>`;
  }

  /* ---------- status words: a table cell that is only a state reads as one ---------- */
  const STATES = {
    good: ["live", "done", "shipped", "ready", "pass", "passed", "ok", "working", "complete", "completed", "active", "on track", "healthy", "yes", "approved", "fixed", "merged", "up"],
    warn: ["at risk", "degraded", "partial", "pending", "in progress", "doing", "waiting", "in review", "review", "beta", "slow", "not asked", "draft", "needs work", "website only", "behind"],
    bad: ["missing", "broken", "failed", "fail", "failing", "blocked", "dead", "down", "error", "overdue", "no", "rejected", "off track", "critical"],
    calm: ["unused", "unknown", "n/a", "paused", "skipped", "planned", "todo", "to do", "later", "not started", "deprecated", "idea"],
  };
  const STATE_OF = new Map(Object.entries(STATES).flatMap(([k, words]) => words.map((w) => [w, k])));
  function status(cell) {
    const plainCell = cell.replace(/[*_`~]/g, "").trim();
    const k = STATE_OF.get(plainCell.toLowerCase().replace(/[.!]$/, ""));
    return k ? `<span class="state s-${k}">${esc(plainCell)}</span>` : null;
  }

  /* ---------- callouts: GitHub's > [!NOTE] ---------- */
  const CALLOUTS = { note: "Note", tip: "Tip", important: "Important", warning: "Warning", caution: "Caution" };

  /* ---------- tables ---------- */
  const SEP = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;
  const cells = (row) => {
    const parts = [];
    let cur = "";
    const r = row.trim().replace(/^\|/, "").replace(/\|$/, "");
    for (let i = 0; i < r.length; i++) {
      if (r[i] === "\\" && r[i + 1] === "|") { cur += "|"; i++; continue; }
      if (r[i] === "|") { parts.push(cur.trim()); cur = ""; continue; }
      cur += r[i];
    }
    parts.push(cur.trim());
    return parts;
  };
  const isTableStart = (lines, i) => lines[i]?.includes("|") && (lines[i + 1] ?? "").includes("|") && SEP.test(lines[i + 1] ?? "") && cells(lines[i]).length === cells(lines[i + 1]).length;

  function table(lines, i) {
    const head = cells(lines[i]);
    const align = cells(lines[i + 1]).map((c) => (c.startsWith(":") && c.endsWith(":") ? "center" : c.endsWith(":") ? "right" : ""));
    const td = (tag, c, k) => `<${tag}${align[k] ? ` style="text-align:${align[k]}"` : ""}>${tag === "td" ? status(c) ?? inline(c) : inline(c)}</${tag}>`;
    let html = `<div class="md-table"><table><thead><tr>${head.map((c, k) => td("th", c, k)).join("")}</tr></thead><tbody>`;
    i += 2;
    while (i < lines.length && lines[i].includes("|") && lines[i].trim()) {
      const row = cells(lines[i]);
      html += `<tr>${head.map((_, k) => td("td", row[k] ?? "", k)).join("")}</tr>`;
      i++;
    }
    return [html + "</tbody></table></div>", i];
  }

  const BLOCK_START = /^(```|~~~|#{1,4}\s|>|\s*([-*+]|\d+[.)])\s+)/;

  function render(text) {
    const lines = text.replace(/\r\n?/g, "\n").split("\n");
    const out = [];
    let i = 0;
    while (i < lines.length) {
      const line = lines[i];
      const fence = line.match(/^\s*(```|~~~)\s*([\w+#.-]*)[^\n]*$/);
      if (fence) {
        const body = [];
        i++;
        while (i < lines.length && !new RegExp(`^\\s*${fence[1]}\\s*$`).test(lines[i])) body.push(lines[i++]);
        i++;
        out.push(codeBlock(body.join("\n"), fence[2]));
        continue;
      }
      const h = line.match(/^(#{1,4})\s+(.*)$/);
      if (h) { out.push(`<h${Math.min(h[1].length + 2, 6)}>${inline(h[2])}</h${Math.min(h[1].length + 2, 6)}>`); i++; continue; }
      if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { out.push("<hr>"); i++; continue; }
      if (isTableStart(lines, i)) { const [html, next] = table(lines, i); out.push(html); i = next; continue; }
      if (/^>\s?/.test(line)) {
        const body = [];
        while (i < lines.length && /^>\s?/.test(lines[i])) body.push(lines[i++].replace(/^>\s?/, ""));
        const kind = body[0]?.match(/^\[!(note|tip|important|warning|caution)\]\s*(.*)$/i);
        if (kind) {
          const k = kind[1].toLowerCase();
          const title = kind[2].trim() || CALLOUTS[k];
          out.push(`<div class="callout c-${k}" role="note"><div class="callout-title">${inline(title)}</div>${render(body.slice(1).join("\n"))}</div>`);
        } else out.push(`<blockquote>${render(body.join("\n"))}</blockquote>`);
        continue;
      }
      const list = line.match(/^\s*([-*+]|\d+[.)])\s+/);
      if (list) {
        const ordered = /\d/.test(list[1]);
        const items = [];
        let tasks = false;
        while (i < lines.length && /^\s*([-*+]|\d+[.)])\s+/.test(lines[i])) {
          let item = lines[i++].replace(/^\s*([-*+]|\d+[.)])\s+/, "");
          while (i < lines.length && /^\s{2,}\S/.test(lines[i]) && !/^\s*([-*+]|\d+[.)])\s+/.test(lines[i])) item += " " + lines[i++].trim();
          const task = item.match(/^\[([ xX])\]\s+(.*)$/);
          if (task) {
            tasks = true;
            const done = task[1] !== " ";
            items.push(`<li class="md-task${done ? " done" : ""}"><span class="md-check" aria-hidden="true"></span><span>${inline(task[2])}</span><span class="sr">${done ? " (done)" : " (to do)"}</span></li>`);
          } else items.push(`<li>${inline(item)}</li>`);
        }
        const cls = tasks ? ' class="md-tasks"' : "";
        out.push(ordered ? `<ol${cls}>${items.join("")}</ol>` : `<ul${cls}>${items.join("")}</ul>`);
        continue;
      }
      if (!line.trim()) { i++; continue; }
      const para = [];
      while (i < lines.length && lines[i].trim() && !BLOCK_START.test(lines[i]) && !isTableStart(lines, i)) para.push(lines[i++]);
      out.push(`<p>${para.map(inline).join("<br>")}</p>`);
    }
    return out.join("");
  }

  return { render, highlight };
})();
