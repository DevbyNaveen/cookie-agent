// Blocks an agent writes as plain text in a page or an answer, drawn here:
// ```flow (boxes and arrows: A -> B, A --> B optional, A: detail), ```chart (bars, lines, a donut), ```form (several
// answers at once, sent back to the agent as the person's message) and
// ```board (a live board the person and agents work on). md.js leaves each as a
// placeholder holding its text; hydrateBlocks draws it. The text stays the
// source: copy a page and it is still readable Markdown.

const SVG_NS = "http://www.w3.org/2000/svg";
const svgEl = (tag, attrs = {}) => { const e = document.createElementNS(SVG_NS, tag); for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v); return e; };
const PALETTE = ["#e3955f", "#82b4f2", "#8fcf7c", "#d08ae0", "#e8b26a", "#6fd0c8", "#ec8a80", "#b5b0a8"];

let measureCtx = null;
function textWidth(text, font = "500 14px -apple-system, system-ui, sans-serif") {
  measureCtx ??= document.createElement("canvas").getContext("2d");
  measureCtx.font = font;
  return measureCtx.measureText(text).width;
}

/** Draw every block placeholder under `root`. */
function hydrateBlocks(root, agentId) {
  for (const ph of root.querySelectorAll(".md-block:not([data-drawn])")) {
    ph.dataset.drawn = "1";
    const src = ph.dataset.src ?? "";
    try {
      if (ph.classList.contains("md-flow")) ph.replaceChildren(drawFlow(src));
      else if (ph.classList.contains("md-chart")) ph.replaceChildren(drawChart(src));
      else if (ph.classList.contains("md-form")) ph.replaceChildren(drawForm(src, agentId));
      else if (ph.classList.contains("md-board")) ph.replaceChildren(boardPreview(src.trim().split("\n")[0].trim(), agentId));
    } catch (e) {
      // A block that can't be drawn shows as the text it is.
      const pre = el("pre", "block-raw", src);
      ph.replaceChildren(el("small", "md-missing", `Couldn't draw this block: ${e.message ?? e}`), pre);
    }
  }
}

/* ---------- flow: one step per line, A -> B, A --> B for optional, A: detail ---------- */

function parseFlow(src) {
  const nodes = new Map(), edges = [];
  const node = (label) => {
    const k = label.trim();
    if (!nodes.has(k)) nodes.set(k, { label: k, detail: "", order: nodes.size });
    return nodes.get(k);
  };
  for (const raw of src.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#") || line.startsWith("//")) continue;
    // Arrows are -> (a step), --> (an optional one) and ==>; a → inside a name is just part of it.
    const parts = line.split(/\s*(-->|->|==>)\s*/);
    if (parts.length > 1) {
      for (let i = 0; i + 2 < parts.length; i += 2) {
        if (!parts[i] || !parts[i + 2]) continue;
        edges.push({ from: node(parts[i]), to: node(parts[i + 2]), optional: parts[i + 1] === "-->" });
      }
      continue;
    }
    const d = line.match(/^(.+?):\s+(.+)$/);
    if (d) node(d[1]).detail = d[2].trim();
    else node(line);
  }
  if (!nodes.size) throw new Error("no steps");
  if (nodes.size > 40) throw new Error("more than 40 steps");
  return { nodes: [...nodes.values()], edges };
}

/** A layered drawing, top to bottom: each step in the row after the longest path to it, rows ordered to cross less. */
function drawFlow(src) {
  const { nodes, edges } = parseFlow(src);
  // Rows: the longest path from a start (a loop can't push a step past the number of steps).
  const level = new Map(nodes.map((n) => [n, 0]));
  for (let pass = 0; pass < nodes.length; pass++) {
    let moved = false;
    for (const e of edges) if (level.get(e.to) < level.get(e.from) + 1 && level.get(e.from) + 1 < nodes.length) { level.set(e.to, level.get(e.from) + 1); moved = true; }
    if (!moved) break;
  }
  const rows = [];
  for (const n of nodes) (rows[level.get(n)] ??= []).push(n);
  rows.forEach((r) => r.sort((a, b) => a.order - b.order));
  // Two passes of ordering each row by where its parents sit.
  for (let pass = 0; pass < 2; pass++) {
    for (let r = 1; r < rows.length; r++) {
      const pos = new Map(rows[r - 1].map((n, i) => [n, i]));
      const bary = (n) => { const ps = edges.filter((e) => e.to === n && pos.has(e.from)).map((e) => pos.get(e.from)); return ps.length ? ps.reduce((a, b) => a + b, 0) / ps.length : 1e9 + n.order; };
      rows[r].sort((a, b) => bary(a) - bary(b));
    }
  }
  // Sizes: each box fits its words.
  const W = (n) => Math.min(300, Math.max(n.detail ? 150 : 90, Math.max(textWidth(n.label), n.detail ? textWidth(n.detail, "400 12.5px -apple-system, system-ui, sans-serif") : 0) + 36));
  const H = (n) => (n.detail ? 58 : 40);
  const GX = 28, GY = 46, PAD = 20;
  const rowW = rows.map((r) => r.reduce((s, n) => s + W(n), 0) + GX * (r.length - 1));
  const width = Math.max(...rowW) + PAD * 2;
  const rowH = rows.map((r) => Math.max(...r.map(H)));
  const box = new Map();
  let y = PAD;
  rows.forEach((r, i) => {
    let x = (width - rowW[i]) / 2;
    for (const n of r) { box.set(n, { x, y: y + (rowH[i] - H(n)) / 2, w: W(n), h: H(n) }); x += W(n) + GX; }
    y += rowH[i] + GY;
  });
  const height = y - GY + PAD;
  const svg = svgEl("svg", { viewBox: `0 0 ${width} ${height}`, class: "flow-svg", role: "img", "aria-label": `Flow: ${nodes.map((n) => n.label).join(", ")}` });
  svg.style.maxWidth = `${width}px`;
  const defs = svgEl("defs");
  const marker = svgEl("marker", { id: "flow-arrow", viewBox: "0 0 10 10", refX: "8", refY: "5", markerWidth: "7", markerHeight: "7", orient: "auto-start-reverse" });
  marker.append(svgEl("path", { d: "M1 1L9 5L1 9", class: "flow-head" }));
  defs.append(marker);
  svg.append(defs);
  for (const e of edges) {
    const a = box.get(e.from), b = box.get(e.to);
    const x1 = a.x + a.w / 2, y1 = a.y + a.h, x2 = b.x + b.w / 2, y2 = b.y - 2;
    const up = y2 <= y1; // a loop back: round the side
    const d = up
      ? `M${a.x + a.w} ${a.y + a.h / 2} C ${a.x + a.w + 60} ${a.y + a.h / 2}, ${b.x + b.w + 60} ${b.y + b.h / 2}, ${b.x + b.w + 2} ${b.y + b.h / 2}`
      : `M${x1} ${y1} C ${x1} ${y1 + (y2 - y1) / 2}, ${x2} ${y1 + (y2 - y1) / 2}, ${x2} ${y2}`;
    svg.append(svgEl("path", { d, class: "flow-edge" + (e.optional ? " optional" : ""), "marker-end": "url(#flow-arrow)" }));
  }
  for (const n of nodes) {
    const r = box.get(n);
    const g = svgEl("g", { class: "flow-node" + (n.detail ? " detail" : "") });
    g.append(svgEl("rect", { x: r.x, y: r.y, width: r.w, height: r.h, rx: n.detail ? 10 : r.h / 2 }));
    if (n.detail) {
      g.append(svgEl("rect", { x: r.x + 10, y: r.y + 12, width: 2.5, height: r.h - 24, rx: 1.25, class: "flow-bar" }));
      const t = svgEl("text", { x: r.x + 22, y: r.y + 24, class: "flow-label" }); t.textContent = n.label; g.append(t);
      const s = svgEl("text", { x: r.x + 22, y: r.y + 43, class: "flow-detail" }); s.textContent = n.detail; g.append(s);
    } else {
      const t = svgEl("text", { x: r.x + r.w / 2, y: r.y + r.h / 2 + 5, class: "flow-label", "text-anchor": "middle" }); t.textContent = n.label; g.append(t);
    }
    svg.append(g);
  }
  const wrap = el("div", "flow-wrap");
  wrap.append(svg);
  return wrap;
}

/* ---------- chart: type, title, then `label: number` lines or a table ---------- */

function parseChart(src) {
  const meta = {}, rows = [];
  let series = ["Value"];
  const lines = src.split("\n").map((l) => l.trim()).filter(Boolean);
  const tableLines = lines.filter((l) => l.startsWith("|"));
  for (const l of lines.filter((l) => !l.startsWith("|"))) {
    const m = l.match(/^(type|title|unit)\s*:\s*(.+)$/i);
    if (m) { meta[m[1].toLowerCase()] = m[2].trim(); continue; }
    const d = l.match(/^[-*]?\s*(.+?)\s*[:=]\s*(-?[\d.,]+)\s*%?\s*$/);
    if (d) rows.push({ label: d[1], values: [parseFloat(d[2].replace(/,/g, ""))] });
  }
  if (tableLines.length >= 2) {
    const cells = (l) => l.replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
    series = cells(tableLines[0]).slice(1);
    for (const l of tableLines.slice(1)) {
      if (/^\|?\s*:?-+/.test(l)) continue;
      const c = cells(l);
      rows.push({ label: c[0], values: c.slice(1).map((v) => parseFloat(v.replace(/[,%$€£]/g, ""))) });
    }
  }
  if (!rows.length) throw new Error("no numbers");
  return { type: (meta.type || (series.length > 1 ? "line" : "bar")).toLowerCase(), title: meta.title, unit: meta.unit ?? "", series, rows: rows.slice(0, 40) };
}

function drawChart(src) {
  const c = parseChart(src);
  const wrap = el("figure", "chart");
  if (c.title) wrap.append(el("figcaption", null, c.title));
  const fmt = (v) => (Number.isFinite(v) ? (Math.abs(v) >= 1000 ? v.toLocaleString() : String(+v.toFixed(2))) + (c.unit ? (c.unit === "%" ? "%" : " " + c.unit) : "") : "–");
  const label = c.rows.map((r) => `${r.label} ${r.values.map(fmt).join(", ")}`).join("; ");
  if (c.type === "donut" || c.type === "pie") {
    const total = c.rows.reduce((s, r) => s + Math.max(0, r.values[0] || 0), 0) || 1;
    const svg = svgEl("svg", { viewBox: "0 0 120 120", class: "chart-donut", role: "img", "aria-label": label });
    let a = -Math.PI / 2;
    c.rows.forEach((r, i) => {
      const f = Math.max(0, r.values[0] || 0) / total;
      if (f <= 0) return;
      const b = a + f * Math.PI * 2;
      const big = f > 0.5 ? 1 : 0;
      const p = (t, rad) => `${60 + rad * Math.cos(t)} ${60 + rad * Math.sin(t)}`;
      const d = f >= 0.999 ? "M60 12 A48 48 0 1 1 59.99 12 L59.99 30 A30 30 0 1 0 60 30 Z" : `M${p(a, 48)} A48 48 0 ${big} 1 ${p(b, 48)} L${p(b, 30)} A30 30 0 ${big} 0 ${p(a, 30)} Z`;
      svg.append(svgEl("path", { d, fill: PALETTE[i % PALETTE.length] }));
      a = b;
    });
    const legend = el("div", "chart-legend");
    c.rows.forEach((r, i) => { const it = el("span"); const dot = el("i"); dot.style.background = PALETTE[i % PALETTE.length]; it.append(dot, `${r.label} · ${fmt(r.values[0])} (${Math.round(((r.values[0] || 0) / total) * 100)}%)`); legend.append(it); });
    const body = el("div", "chart-donut-wrap");
    body.append(svg, legend);
    wrap.append(body);
    return wrap;
  }
  if (c.type === "line") {
    const W = 560, H = 220, L = 44, R = 12, T = 12, B = 28;
    const all = c.rows.flatMap((r) => r.values).filter(Number.isFinite);
    const lo = Math.min(0, ...all), hi = Math.max(...all) || 1;
    const X = (i) => L + (c.rows.length === 1 ? (W - L - R) / 2 : (i * (W - L - R)) / (c.rows.length - 1));
    const Y = (v) => T + (1 - (v - lo) / (hi - lo || 1)) * (H - T - B);
    const svg = svgEl("svg", { viewBox: `0 0 ${W} ${H}`, class: "chart-svg", role: "img", "aria-label": label });
    for (let k = 0; k <= 4; k++) {
      const v = lo + ((hi - lo) * k) / 4, yy = Y(v);
      svg.append(svgEl("line", { x1: L, x2: W - R, y1: yy, y2: yy, class: "chart-grid" }));
      const t = svgEl("text", { x: L - 6, y: yy + 4, class: "chart-axis", "text-anchor": "end" }); t.textContent = fmt(v); svg.append(t);
    }
    const step = Math.ceil(c.rows.length / 8);
    c.rows.forEach((r, i) => { if (i % step) return; const t = svgEl("text", { x: X(i), y: H - 8, class: "chart-axis", "text-anchor": "middle" }); t.textContent = r.label; svg.append(t); });
    c.series.forEach((s, si) => {
      const pts = c.rows.map((r, i) => [X(i), r.values[si]]).filter(([, v]) => Number.isFinite(v));
      svg.append(svgEl("path", { d: pts.map(([x, v], i) => `${i ? "L" : "M"}${x} ${Y(v)}`).join(" "), class: "chart-line", stroke: PALETTE[si % PALETTE.length] }));
      for (const [x, v] of pts) svg.append(svgEl("circle", { cx: x, cy: Y(v), r: 3, fill: PALETTE[si % PALETTE.length] }));
    });
    wrap.append(svg);
    if (c.series.length > 1) {
      const legend = el("div", "chart-legend");
      c.series.forEach((s, i) => { const it = el("span"); const dot = el("i"); dot.style.background = PALETTE[i % PALETTE.length]; it.append(dot, s); legend.append(it); });
      wrap.append(legend);
    }
    return wrap;
  }
  // Bars, across: easy to read with long labels.
  const max = Math.max(...c.rows.flatMap((r) => r.values).filter(Number.isFinite), 0) || 1;
  const list = el("div", "chart-bars");
  list.setAttribute("role", "img");
  list.setAttribute("aria-label", label);
  for (const r of c.rows) {
    const row = el("div", "chart-bar-row");
    const bars = el("div", "chart-bar-track");
    r.values.forEach((v, si) => { const b = el("span", "chart-bar"); b.style.width = `${Math.max(0, (v / max) * 100)}%`; b.style.background = PALETTE[si % PALETTE.length]; bars.append(b); });
    row.append(el("span", "chart-bar-label", r.label), bars, el("span", "chart-bar-value", r.values.map(fmt).join(" · ")));
    list.append(row);
  }
  wrap.append(list);
  return wrap;
}

/* ---------- form: several answers at once, sent back as the person's message ---------- */

function parseForm(src) {
  const f = { title: "", submit: "Send", fields: [] };
  for (const raw of src.split("\n")) {
    const line = raw.trim().replace(/^[-*]\s+/, "");
    if (!line) continue;
    const meta = line.match(/^(title|submit)\s*:\s*(.+)$/i);
    if (meta) { f[meta[1].toLowerCase()] = meta[2].trim(); continue; }
    const m = line.match(/^(.+?)(\*)?\s*:\s*(text|long|number|date|email|yesno|choice|multi)\s*(?:\((.*)\))?\s*$/i);
    if (m) f.fields.push({ label: m[1].trim(), required: !!m[2], type: m[3].toLowerCase(), options: (m[4] ?? "").split(",").map((o) => o.trim()).filter(Boolean) });
    else if (/^.+\*?$/.test(line)) f.fields.push({ label: line.replace(/\*$/, "").trim(), required: line.endsWith("*"), type: "text", options: [] });
  }
  if (!f.fields.length) throw new Error("no fields");
  return f;
}

const formKey = (agentId, src) => { let h = 0; for (const ch of src) h = (h * 31 + ch.charCodeAt(0)) | 0; return `cookie.form.${agentId}.${h}`; };

function drawForm(src, agentId) {
  const spec = parseForm(src);
  const form = el("form", "md-form-box");
  form.noValidate = true;
  if (spec.title) form.append(el("div", "form-title", spec.title));
  const get = [];
  spec.fields.forEach((f, i) => {
    const id = `f${Math.random().toString(36).slice(2, 8)}${i}`;
    const row = el("div", "form-field");
    const lab = el("label", null, f.label + (f.required ? " *" : ""));
    lab.htmlFor = id;
    row.append(lab);
    if (f.type === "choice" || f.type === "multi" || f.type === "yesno") {
      const opts = f.type === "yesno" ? ["Yes", "No"] : f.options;
      const group = el("div", "form-pills");
      group.setAttribute("role", f.type === "multi" ? "group" : "radiogroup");
      group.setAttribute("aria-label", f.label);
      const picked = new Set();
      for (const o of opts) {
        const b = el("button", "form-pill", o);
        b.type = "button";
        b.setAttribute("aria-pressed", "false");
        b.onclick = () => {
          if (f.type !== "multi") { picked.clear(); group.querySelectorAll(".form-pill").forEach((x) => x.setAttribute("aria-pressed", "false")); }
          if (picked.has(o)) picked.delete(o); else picked.add(o);
          b.setAttribute("aria-pressed", String(picked.has(o)));
        };
        group.append(b);
      }
      row.append(group);
      get.push(() => [...picked].join(", "));
    } else {
      const input = f.type === "long" ? el("textarea", "text-in") : el("input", "text-in");
      input.id = id;
      if (f.type === "long") input.rows = 3; else input.type = { number: "number", date: "date", email: "email" }[f.type] ?? "text";
      row.append(input);
      get.push(() => input.value.trim());
    }
    form.append(row);
  });
  const end = el("div", "form-end");
  const status = el("small", "muted form-status");
  const send = el("button", "btn primary small", spec.submit);
  send.type = "submit";
  end.append(status, send);
  form.append(end);
  const key = formKey(agentId, src);
  const done = () => { form.classList.add("sent"); form.querySelectorAll("input,textarea,.form-pill").forEach((x) => (x.disabled = true)); send.textContent = "Sent"; send.disabled = true; };
  try { if (localStorage.getItem(key)) done(); } catch {}
  form.onsubmit = async (e) => {
    e.preventDefault();
    const values = get.map((g) => g());
    const missing = spec.fields.filter((f, i) => f.required && !values[i]);
    if (missing.length) { status.textContent = `Still needed: ${missing.map((f) => f.label).join(", ")}`; return; }
    const text = `${spec.title ? `**${spec.title}**\n` : ""}${spec.fields.map((f, i) => `- ${f.label}: ${values[i] || "(left blank)"}`).join("\n")}`;
    done();
    try { localStorage.setItem(key, "1"); } catch {}
    if (current?.id === agentId && view === "chat") {
      closePage?.();
      $("input").value = text;
      autosize();
      $("composer").requestSubmit();
    } else {
      try { await call("send", { id: agentId, text }); toast("Sent", `Your answers went to ${agentById(agentId)?.name ?? "the agent"}.`, "good"); }
      catch (err) { toast("Couldn't send it", String(err), "error"); }
    }
  };
  return form;
}

/* ---------- boards: live columns of cards ---------- */

const boardAgentName = (by) => (by === "you" ? "You" : agentById(by)?.name ?? "An agent");

/** A board inside a message: its columns at a glance, live, and a click to open it whole. */
function boardPreview(id, agentId) {
  const box = el("button", "board-card");
  box.type = "button";
  box.dataset.boardId = id;
  const fill = async () => {
    let b;
    try { b = await call("board", { id }); } catch (e) { box.replaceWith(el("span", "md-missing", `Board ${id}: ${String(e)}`)); return; }
    box.dataset.boardId = b.id;
    const head = el("div", "board-card-head");
    head.append(icon("grid"), el("span", "board-card-title", b.title), el("small", "muted", `${b.cards.length} card${b.cards.length === 1 ? "" : "s"}`));
    const cols = el("div", "board-mini");
    for (const c of b.columns) {
      const col = el("div", "board-mini-col");
      const cards = b.cards.filter((x) => x.column === c);
      col.append(el("div", "board-mini-name", `${c} · ${cards.length}`));
      for (const x of cards.slice(0, 3)) col.append(el("div", "board-mini-card", x.title));
      if (cards.length > 3) col.append(el("small", "muted", `+${cards.length - 3} more`));
      cols.append(col);
    }
    box.replaceChildren(head, cols);
    box.onclick = () => openBoard(b.id, agentId);
  };
  box.refresh = fill;
  fill();
  return box;
}

let boardOpen = null;

/** A board open over the chat: drag cards between columns, add, edit; live as agents work. */
async function openBoard(id, agentId) {
  const v = $("doc-view");
  let b;
  try { b = await call("board", { id }); } catch (e) { toast("Couldn't open the board", String(e), "error"); return; }
  boardOpen = { id: b.id, agentId };
  const head = el("div", "doc-head");
  const pill = el("div", "pill doc-pill");
  pill.append(icon("grid"), el("span", null, b.title));
  const acts = el("div", "doc-acts");
  const x = el("button", "round soft doc-x");
  x.type = "button";
  x.setAttribute("aria-label", "Close board");
  x.append(icon("x"));
  x.onclick = closePage;
  acts.append(x);
  head.append(pill, acts);
  const body = el("div", "doc-body board-body");
  body.append(boardColumns(b));
  v.replaceChildren(head, body);
  v.hidden = false;
  v.dataset.board = b.id;
  $("chat").classList.add("doc-open");
  requestAnimationFrame(() => v.classList.add("open"));
}

function boardColumns(b) {
  const wrap = el("div", "board");
  let dragging = null;
  for (const c of b.columns) {
    const col = el("section", "board-col");
    col.setAttribute("aria-label", c);
    const cards = b.cards.filter((x) => x.column === c);
    const head = el("div", "board-col-head");
    head.append(el("span", null, c), el("small", "muted", String(cards.length)));
    const list = el("div", "board-list");
    for (const card of cards) {
      const it = el("article", "board-item");
      it.draggable = true;
      it.tabIndex = 0;
      it.dataset.card = card.id;
      it.append(el("div", "board-item-title", card.title));
      if (card.notes) it.append(el("div", "board-item-notes", card.notes.slice(0, 160)));
      const foot = el("div", "board-item-foot");
      if (card.by !== "you") foot.append(Faces.create(card.by, 16).el);
      foot.append(el("small", null, `${boardAgentName(card.by)} · ${fmtTime(card.at)}`));
      it.append(foot);
      it.ondragstart = (e) => { dragging = card.id; it.classList.add("dragging"); e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", card.id); };
      it.ondragend = () => { dragging = null; it.classList.remove("dragging"); wrap.querySelectorAll(".drop-here").forEach((n) => n.classList.remove("drop-here")); };
      it.onclick = () => editCard(b, card);
      it.onkeydown = (e) => { if (e.key === "Enter") editCard(b, card); };
      list.append(it);
    }
    list.ondragover = (e) => { if (!dragging) return; e.preventDefault(); list.classList.add("drop-here"); };
    list.ondragleave = () => list.classList.remove("drop-here");
    list.ondrop = async (e) => {
      e.preventDefault();
      list.classList.remove("drop-here");
      const card = e.dataTransfer.getData("text/plain") || dragging;
      if (!card) return;
      // Dropped on a card: before it; on the column: at its end.
      const over = e.target.closest?.(".board-item")?.dataset.card;
      try { await call("move_card", { board: b.id, card, column: c, before: over && over !== card ? over : null }); } catch (err) { toast("Couldn't move it", String(err), "error"); }
    };
    const add = el("button", "board-add", "+ Add a card");
    add.type = "button";
    add.onclick = () => {
      const input = el("input", "text-in board-add-in");
      input.placeholder = "What needs doing?";
      add.replaceWith(input);
      input.focus();
      const done = async (save) => {
        const title = input.value.trim();
        if (save && title) { try { await call("add_card", { board: b.id, title, column: c }); } catch (err) { toast("Couldn't add it", String(err), "error"); } }
        input.replaceWith(add);
      };
      input.onkeydown = (e) => { if (e.key === "Enter") done(true); if (e.key === "Escape") { e.stopPropagation(); done(false); } };
      input.onblur = () => done(true);
    };
    col.append(head, list, add);
    wrap.append(col);
  }
  return wrap;
}

function editCard(b, card) {
  const d = el("dialog", "sheet secret-sheet card-sheet");
  const title = el("input", "text-in"); title.value = card.title;
  const notes = el("textarea", "text-in"); notes.rows = 6; notes.value = card.notes; notes.placeholder = "Notes";
  const where = select(b.columns.map((c) => [c, c]), card.column, () => {});
  d.append(el("h2", null, "Card"), title, notes, (() => { const r = el("div", "inline-row"); r.append(el("span", "muted", "Column"), where); return r; })(),
    el("p", "set-note", `${boardAgentName(card.by)} · ${fmtTime(card.at)}`));
  const end = el("div", "form-end");
  end.append(
    button("Delete", "quiet small danger", async () => { if (!confirm("Delete this card?")) return; await call("delete_card", { board: b.id, card: card.id }).catch((e) => toast("Couldn't delete it", String(e), "error")); d.close(); }),
    button("Save", "primary small", async () => {
      try {
        await call("edit_card", { board: b.id, card: card.id, title: title.value, notes: notes.value });
        if (where.value !== card.column) await call("move_card", { board: b.id, card: card.id, column: where.value });
        d.close();
      } catch (e) { toast("Couldn't save it", String(e), "error"); }
    }),
  );
  d.append(end);
  d.addEventListener("close", () => d.remove());
  document.body.append(d);
  d.showModal();
}

/** A board changed: every view of it redraws. */
async function onBoardChanged(id) {
  document.querySelectorAll(`.board-card[data-board-id="${CSS.escape(id)}"]`).forEach((n) => n.refresh?.());
  const v = $("doc-view");
  if (!v.hidden && v.dataset.board === id) {
    try {
      const b = await call("board", { id });
      const body = v.querySelector(".board-body");
      if (body) { const top = body.scrollTop; body.replaceChildren(boardColumns(b)); body.scrollTop = top; }
    } catch { closePage(); }
  }
  if (typeof refreshDesk === "function" && current?.id === "cookie") refreshDesk();
}
