// An agent's own software, beside the chat (its workspace: tested blocks in a
// Parallax world, every change undoable), and the watch window over every
// world: side by side, what changed, a timeline to scrub and rewind, and what
// waits at the wall for your yes.
let wsFor = null, wsBusy = false;

const COLUMN_TYPES = ["text", "number", "date", "yes/no", "choice"];

function wsOpenFor(id) { return id && !$("workspace").hidden && wsFor === id; }

$("ws-btn").onclick = () => ($("workspace").hidden || wsFor !== current?.id ? openWorkspace() : closeWorkspace());

function closeWorkspace() {
  $("workspace").hidden = true;
  $("ws-btn").classList.remove("on");
  document.querySelector(".pane").classList.remove("with-workspace");
  wsFor = null;
}

async function openWorkspace(keepScroll = false) {
  if (!current) return;
  closeProfile();
  const id = current.id;
  const box = $("workspace");
  const scroll = keepScroll ? box.scrollTop : 0;
  wsFor = id;
  document.querySelector(".pane").classList.add("with-workspace");
  $("ws-btn").classList.add("on");
  box.hidden = false;
  let ws;
  try { ws = await call("workspace", { id }); } catch (e) { box.replaceChildren(wsHead(current.name), el("p", "error-line", String(e))); return; }
  if (wsFor !== id) return;
  const body = el("div", "ws-body");
  if (!ws.blocks.length) body.append(wsEmpty(id));
  for (const b of ws.blocks) body.append(blockCard(id, b));
  const parts = [wsHead(current.name), body];
  if (ws.history.length) parts.push(historyCard(id, ws.history));
  box.replaceChildren(...parts);
  box.scrollTop = scroll;
}

function refreshWorkspace(agent) { if (wsOpenFor(agent)) openWorkspace(true); }

function wsHead(name) {
  const h = el("div", "ws-head");
  const x = el("button", "round soft profile-x");
  x.setAttribute("aria-label", "Close workspace");
  x.append(icon("x"));
  x.onclick = closeWorkspace;
  const t = el("div");
  t.append(el("h2", null, "Workspace"), el("p", "muted", `${name}'s own software. You and ${name} both work here; every change can be undone.`));
  h.append(t, x);
  return h;
}

function wsEmpty(id) {
  const e = el("div", "empty-box");
  e.append(el("p", null, "No software yet."), el("p", "muted", "Ask it for what it needs (“keep a log of my workouts with a weekly chart”) and it builds it here from tested blocks: trackers, boards, calendars, charts, forms."));
  e.append(button("Start from the Gym Trainer's", "quiet small", async () => { await wsDo(id, () => call("workspace_template", { id, template: "gym-trainer" })); }));
  return e;
}

// Every change goes through Do; an error shows where it happened, not as a toast storm.
async function wsDo(id, fn, card) {
  if (wsBusy) return;
  wsBusy = true;
  try { await fn(); } catch (e) {
    if (card) { card.querySelector(".ws-err")?.remove(); const p = el("p", "error-line ws-err", String(e)); card.append(p); }
    else toast("Couldn't change that", String(e), "error");
    wsBusy = false;
    return false;
  }
  wsBusy = false;
  await openWorkspace(true);
  return true;
}
const change = (id, engine, action, args, card) => wsDo(id, () => call("workspace_do", { id, engine, action, args }), card);

function blockCard(id, b) {
  const card = el("section", "ws-card");
  const head = el("div", "ws-card-head");
  head.append(el("h3", null, b.title || b.name), el("span", "tag", b.kind));
  const rm = el("button", "round soft tiny");
  rm.title = "Take it out (Undo brings it back)"; rm.setAttribute("aria-label", "Take this block out");
  rm.append(icon("trash"));
  rm.onclick = () => change(id, "blocks", "remove_block", { name: b.name }, card);
  head.append(rm);
  card.append(head);
  const c = b.content || {};
  if (c.error) { card.append(el("p", "error-line", c.error)); return card; }
  const draw = { tracker: trackerView, board: boardView, calendar: calendarView, chart: chartView, form: formView, sheet: sheetView, document: documentView, pdf: pdfView }[b.kind];
  if (draw) card.append(...draw(id, b, c, card));
  return card;
}

/* ---------- tracker ---------- */
function fieldInput(col, value) {
  if (col.type === "yes/no") { const i = el("input"); i.type = "checkbox"; i.checked = value === true; return i; }
  if (col.type === "choice") {
    const s = el("select", "pick");
    s.append(el("option", null, "—"), ...(col.options || []).map((o) => { const x = el("option", null, o); x.value = o; return x; }));
    s.options[0].value = ""; s.value = value ?? "";
    return s;
  }
  const i = el("input");
  i.type = col.type === "number" ? "number" : col.type === "date" ? "date" : "text";
  if (col.type === "number") i.step = "any";
  i.value = value ?? "";
  i.placeholder = col.name;
  return i;
}
const valueOf = (col, i) => col.type === "yes/no" ? i.checked : (i.value.trim() === "" ? null : i.value);
const shown = (col, v) => v == null ? "" : col.type === "yes/no" ? (v ? "✓" : "") : String(v);

function trackerView(id, b, c, card) {
  const cols = c.data?.columns || [];
  const rowsData = c.data?.rows || [];
  const wrap = el("div", "ws-table-wrap");
  const table = el("table", "ws-table");
  const hr = el("tr");
  for (const col of cols) {
    const th = el("th", null, col.name);
    th.title = `${col.type} — click to remove the column`;
    th.onclick = () => { if (confirm(`Remove the column “${col.name}” and its values? (Undo brings it back.)`)) change(id, "blocks", "remove_column", { name: b.name, column: col.name }, card); };
    hr.append(th);
  }
  hr.append(el("th"));
  table.append(hr);
  for (const r of rowsData) {
    const tr = el("tr");
    for (const col of cols) {
      const td = el("td", col.type === "number" ? "num" : "", shown(col, r[col.name]));
      td.tabIndex = 0;
      const edit = () => {
        if (td.querySelector("input,select")) return;
        const i = fieldInput(col, r[col.name]);
        td.replaceChildren(i); i.focus();
        const save = () => { const v = valueOf(col, i); if (v === (r[col.name] ?? null)) { td.textContent = shown(col, r[col.name]); return; } change(id, "blocks", "update_row", { name: b.name, row: r._id, values: { [col.name]: v } }, card); };
        if (col.type === "yes/no" || col.type === "choice") i.onchange = save; else { i.onblur = save; i.onkeydown = (e) => { if (e.key === "Enter") i.blur(); if (e.key === "Escape") td.textContent = shown(col, r[col.name]); }; }
      };
      td.onclick = edit; td.onkeydown = (e) => { if (e.key === "Enter") edit(); };
      tr.append(td);
    }
    const del = el("td", "ws-row-x");
    const x = el("button", "round soft tiny"); x.setAttribute("aria-label", "Delete row"); x.append(icon("x"));
    x.onclick = () => change(id, "blocks", "delete_row", { name: b.name, row: r._id }, card);
    del.append(x); tr.append(del);
    table.append(tr);
  }
  // A new row, typed as its columns are.
  const add = el("tr", "ws-add-row");
  const inputs = cols.map((col) => { const td = el("td"); const i = fieldInput(col, col.type === "date" ? new Date().toISOString().slice(0, 10) : null); td.append(i); add.append(td); return [col, i]; });
  const go = el("td");
  const plus = el("button", "round soft tiny"); plus.setAttribute("aria-label", "Add row"); plus.append(icon("plus"));
  plus.onclick = () => {
    const values = Object.fromEntries(inputs.map(([col, i]) => [col.name, valueOf(col, i)]).filter(([, v]) => v !== null && v !== false));
    if (!Object.keys(values).length) return;
    change(id, "blocks", "add_row", { name: b.name, values }, card);
  };
  go.append(plus); add.append(go);
  if (cols.length) table.append(add);
  wrap.append(table);
  const out = [wrap];
  if (!rowsData.length) out.push(el("p", "muted ws-hint", "No rows yet: fill the last line, or ask the agent to log something."));
  out.push(columnAdder(id, b, card));
  return out;
}

function columnAdder(id, b, card) {
  const d = el("details", "ws-more");
  d.append(el("summary", null, "Add a column"));
  const f = el("form", "ws-inline");
  const name = input("", "Column name", { required: true, maxlength: 40 });
  const type = el("select", "pick");
  type.append(...COLUMN_TYPES.map((t) => { const o = el("option", null, t); o.value = t; return o; }));
  const opts = input("", "Options, comma separated");
  opts.hidden = true;
  type.onchange = () => { opts.hidden = type.value !== "choice"; };
  const ok = el("button", "btn quiet small", "Add"); ok.type = "submit";
  f.append(name, type, opts, ok);
  f.onsubmit = (e) => {
    e.preventDefault();
    const args = { name: b.name, column: name.value.trim(), type: type.value };
    if (type.value === "choice") args.options = opts.value.split(",").map((s) => s.trim()).filter(Boolean);
    change(id, "blocks", "add_column", args, card);
  };
  d.append(f);
  return d;
}

/* ---------- board ---------- */
function boardView(id, b, c, card) {
  const stages = c.data?.stages || [];
  const cards = c.data?.cards || [];
  const board = el("div", "ws-board");
  for (const s of stages) {
    const col = el("div", "ws-stage");
    col.append(el("h4", null, `${s} · ${cards.filter((x) => x.stage === s).length}`));
    col.ondragover = (e) => { e.preventDefault(); col.classList.add("over"); };
    col.ondragleave = () => col.classList.remove("over");
    col.ondrop = (e) => { e.preventDefault(); col.classList.remove("over"); const cid = e.dataTransfer.getData("text/card"); if (cid) change(id, "blocks", "move_card", { name: b.name, card: cid, stage: s }, card); };
    for (const k of cards.filter((x) => x.stage === s)) {
      const it = el("div", "ws-card-item");
      it.draggable = true;
      it.ondragstart = (e) => e.dataTransfer.setData("text/card", k.id);
      it.append(el("b", null, k.title));
      if (k.notes) it.append(el("span", "muted", k.notes));
      // Keyboard and no-drag path: move with a select.
      const mv = el("select", "pick tiny-pick");
      mv.setAttribute("aria-label", "Move to");
      mv.append(...stages.map((x) => { const o = el("option", null, x); o.value = x; return o; }));
      mv.value = s;
      mv.onchange = () => change(id, "blocks", "move_card", { name: b.name, card: k.id, stage: mv.value }, card);
      it.append(mv);
      col.append(it);
    }
    board.append(col);
  }
  const f = el("form", "ws-inline");
  const title = input("", "New card", { required: true, maxlength: 200 });
  const ok = el("button", "btn quiet small", "Add"); ok.type = "submit";
  f.append(title, ok);
  f.onsubmit = (e) => { e.preventDefault(); change(id, "blocks", "add_card", { name: b.name, title: title.value.trim(), stage: stages[0] }, card); };
  return [board, f];
}

/* ---------- calendar ---------- */
function calendarView(id, b, c, card) {
  const events = [...(c.data?.events || [])].sort((x, y) => x.start.localeCompare(y.start));
  const list = el("div", "ws-events");
  if (!events.length) list.append(el("p", "muted ws-hint", "Nothing planned yet."));
  let day = null;
  for (const ev of events) {
    const d = ev.start.slice(0, 10);
    if (d !== day) { day = d; list.append(el("h4", "ws-day", new Date(d + "T00:00").toLocaleDateString([], { weekday: "long", day: "numeric", month: "short" }))); }
    const r = el("div", "ws-event");
    const time = ev.start.length > 10 ? ev.start.slice(11, 16) + (ev.end && ev.end.length > 10 ? "–" + ev.end.slice(11, 16) : "") : "all day";
    r.append(el("span", "ws-time", time), el("span", null, ev.title + (ev.repeat ? " · every week" : "")));
    const x = el("button", "round soft tiny"); x.setAttribute("aria-label", "Remove event"); x.append(icon("x"));
    x.onclick = () => change(id, "blocks", "remove_event", { name: b.name, event: ev.id }, card);
    r.append(x);
    list.append(r);
  }
  const f = el("form", "ws-inline");
  const title = input("", "What", { required: true, maxlength: 200 });
  const start = el("input"); start.type = "datetime-local"; start.required = true;
  const weekly = el("label", "check-row small"); const wk = el("input"); wk.type = "checkbox"; weekly.append(wk, " weekly");
  const ok = el("button", "btn quiet small", "Add"); ok.type = "submit";
  f.append(title, start, weekly, ok);
  f.onsubmit = (e) => { e.preventDefault(); change(id, "blocks", "add_event", { name: b.name, title: title.value.trim(), start: start.value.slice(0, 16), repeat: wk.checked ? "weekly" : null }, card); };
  return [list, f];
}

/* ---------- chart ---------- */
function chartView(id, b, c) {
  const series = c.series || [];
  const pts = series.flatMap((s) => s.points);
  if (!pts.length) return [el("p", "muted ws-hint", `Draws ${(c.y || []).join(", ")} by ${c.x} from “${c.source}” once it has rows.`)];
  const W = 480, H = 180, P = { l: 40, r: 12, t: 10, b: 26 };
  const xs = [...new Set(pts.map((p) => String(p[0])))].sort();
  const ys = pts.map((p) => p[1]);
  let lo = Math.min(0, ...ys), hi = Math.max(...ys);
  if (hi === lo) hi = lo + 1;
  const X = (x) => P.l + (xs.length === 1 ? (W - P.l - P.r) / 2 : (xs.indexOf(String(x)) / (xs.length - 1)) * (W - P.l - P.r));
  const Y = (y) => H - P.b - ((y - lo) / (hi - lo)) * (H - P.t - P.b);
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", `0 0 ${W} ${H}`); svg.setAttribute("class", "ws-chart"); svg.setAttribute("role", "img");
  svg.setAttribute("aria-label", `${b.title || b.name}: ${series.map((s) => s.name).join(", ")} by ${c.x}`);
  const add = (tag, attrs, text) => { const n = document.createElementNS(ns, tag); for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v); if (text != null) n.textContent = text; svg.append(n); return n; };
  for (const t of [lo, (lo + hi) / 2, hi]) { add("line", { x1: P.l, x2: W - P.r, y1: Y(t), y2: Y(t), class: "grid" }); add("text", { x: P.l - 6, y: Y(t) + 4, "text-anchor": "end", class: "axis" }, +t.toFixed(1)); }
  const step = Math.max(1, Math.ceil(xs.length / 5));
  xs.forEach((x, i) => { if (i % step === 0 || i === xs.length - 1) add("text", { x: X(x), y: H - 8, "text-anchor": "middle", class: "axis" }, x.length === 10 ? x.slice(5) : x); });
  series.forEach((s, si) => {
    const cls = `s${si % 4}`;
    const sorted = [...s.points].sort((a, b2) => String(a[0]).localeCompare(String(b2[0])));
    if (c.chart === "bar") {
      const bw = Math.max(4, (W - P.l - P.r) / Math.max(1, xs.length) / Math.max(1, series.length) * 0.7);
      for (const [x, y] of sorted) add("rect", { x: X(x) - (bw * series.length) / 2 + si * bw, y: Y(Math.max(0, y)), width: bw, height: Math.abs(Y(y) - Y(0)), class: "bar " + cls, rx: 2 });
    } else {
      add("polyline", { points: sorted.map(([x, y]) => `${X(x)},${Y(y)}`).join(" "), class: "line " + cls });
      for (const [x, y] of sorted) { const d = add("circle", { cx: X(x), cy: Y(y), r: 3, class: "dot " + cls }); const t = document.createElementNS(ns, "title"); t.textContent = `${x}: ${y}`; d.append(t); }
    }
  });
  const legend = el("div", "ws-legend");
  series.forEach((s, si) => { const k = el("span"); k.append(el("i", `s${si % 4}`), s.name); legend.append(k); });
  return [svg, legend];
}

/* ---------- form ---------- */
function formView(id, b, c, card) {
  const fields = c.data?.fields || [];
  const responses = c.data?.responses || [];
  const f = el("form", "ws-form");
  const inputs = fields.map((fd) => {
    const l = el("label", "ws-field");
    const i = fieldInput(fd, null);
    if (fd.required) i.required = true;
    l.append(el("span", null, fd.name.replace(/_/g, " ") + (fd.required ? " *" : "")), i);
    f.append(l);
    return [fd, i];
  });
  const ok = el("button", "btn primary small", "Submit"); ok.type = "submit";
  f.append(ok);
  f.onsubmit = (e) => { e.preventDefault(); change(id, "blocks", "submit", { name: b.name, values: Object.fromEntries(inputs.map(([fd, i]) => [fd.name, valueOf(fd, i)])) }, card); };
  const out = [f];
  if (responses.length) {
    const last = responses[responses.length - 1];
    out.push(el("p", "muted ws-hint", `${responses.length} ${responses.length === 1 ? "answer" : "answers"} so far; the last ${fmtTime(last._at)}.`));
  }
  return out;
}

/* ---------- sheet, document, pdf ---------- */
function sheetView(id, b, c) {
  const t = c.table || [];
  const wrap = el("div", "ws-table-wrap");
  const table = el("table", "ws-table");
  t.forEach((row, i) => { const tr = el("tr"); for (const v of row) tr.append(el(i ? "td" : "th", /^-?\d+(\.\d+)?$/.test(v) ? "num" : "", v)); table.append(tr); });
  wrap.append(table);
  return [wrap, el("p", "muted ws-hint", `${b.path} — ask the agent to change cells or formulas.`)];
}
function documentView(id, b, c, card) {
  const ta = el("textarea", "ws-doc");
  ta.value = c.text ?? "";
  ta.rows = Math.min(16, Math.max(4, (c.text || "").split("\n").length + 1));
  const save = button("Save", "quiet small", () => change(id, "document", "write", { path: b.path, text: ta.value }, card));
  save.disabled = true;
  ta.oninput = () => { save.disabled = false; };
  return [ta, save];
}
function pdfView(id, b, c) { return [el("p", "muted ws-hint", `${b.path} · ${c.pages} ${c.pages === 1 ? "page" : "pages"}`)]; }

/* ---------- history ---------- */
function historyCard(id, history) {
  const card = el("section", "ws-card ws-history");
  card.append(el("h3", null, "Changes"));
  for (const h of history) {
    const r = el("div", "ws-change");
    r.append(el("span", null, h.what), el("time", null, fmtTime(h.at)));
    if (h.change) r.append(button("Undo", "quiet small", () => wsDo(id, () => call("workspace_undo", { id, change: h.change }), card)));
    card.append(r);
  }
  return card;
}

/* ---------- worlds: in each agent's profile (Computer), the wall in its chat ---------- */
let watchSel = new Set(), watchScrub = new Map();
let wallWaiting = [], wallWorlds = [];

/** What waits at the wall: in its agent's chat, its badge and place in the list, and the app's count. */
async function refreshWall() {
  try { const w = await call("watch"); wallWaiting = w.waiting || []; wallWorlds = w.worlds || []; } catch { return; }
  renderNeeds();
  renderRoster();
  refreshDesk();
}

/** Each thing trying to leave a world, with Yes and No. */
function wallGroup(entries) {
  const g = el("div", "group wall");
  for (const e of entries) {
    const owner = wallWorlds.find((x) => x.id === e.world)?.owner;
    const who = agentById(owner)?.name ?? owner ?? "";
    const r = el("div", "row wall-row");
    const t = el("div", "row-text");
    t.append(el("span", null, e.preview), el("small", null, `${who ? who + " · " : ""}${e.engine}.${e.action} · ${fmtTime(e.at)}`));
    const acts = el("div", "row-actions");
    acts.append(button("No", "quiet small", () => wallDecide(e.id, false)), button("Yes", "primary small", () => wallDecide(e.id, true)));
    r.append(t, acts);
    g.append(r);
  }
  return g;
}

async function wallDecide(entry, yes) {
  try { await call("decide_wall", { entry, yes }); toast(yes ? "Done" : "Refused", yes ? "It went through the wall." : "Nothing left the world."); }
  catch (e) { toast("Couldn't decide that", String(e), "error"); }
  await refreshWall();
  refreshProfile();
}

/** The Worlds part of an agent's Computer tab: its switch, its worlds side by side, a timeline to scrub back. */
PANELS.worlds = async (a) => {
  const w = await call("watch");
  wallWaiting = w.waiting || []; wallWorlds = w.worlds || [];
  const on = !!a.grants.worlds;
  const sw = el("div", "group");
  sw.append(setRow(on ? "On" : "Off",
    on ? "It tries things in copies of its folder first. Every step can be undone; anything that leaves a world waits for your yes."
       : "Let it try things in copies of its folder first: undo any step, race attempts, rewind, and keep only what worked.",
    toggle(on, async (v) => {
      try { await call("update_agent", { id: a.id, patch: { grants: { ...a.grants, worlds: v } } }); } catch (e) { toast("Couldn't change that", String(e), "error"); }
      await loadRoster(); current = agentById(a.id) ?? current; refreshProfile();
    }, "Worlds")));
  const out = [sw];
  const mine = w.worlds.filter((x) => x.owner === a.id && (x.state === "awake" || x.state === "asleep")).sort((x, y) => y.touched_at - x.touched_at);
  const ids = new Set(mine.map((x) => x.id));
  const waiting = wallWaiting.filter((e) => ids.has(e.world));
  if (waiting.length) out.push(el("h3", "group-title", "Waiting for your yes"), wallGroup(waiting));
  if (!mine.length) {
    if (on) out.push(el("p", "set-note", "No worlds right now. When it starts one for a job, it shows here: what changed, a timeline to scrub back, and Keep or Throw away."));
    return out;
  }
  for (const id of [...watchSel]) if (!w.worlds.some((x) => x.id === id)) watchSel.delete(id);
  if (!mine.some((x) => watchSel.has(x.id))) mine.slice(0, 2).forEach((x) => watchSel.add(x.id));
  if (mine.length > 1) {
    const chips = el("div", "watch-chips");
    for (const x of mine) {
      const b = el("button", "chip-btn" + (watchSel.has(x.id) ? " on" : ""), x.name);
      b.type = "button";
      b.title = x.id;
      b.onclick = () => { watchSel.has(x.id) ? watchSel.delete(x.id) : watchSel.add(x.id); refreshProfile(); };
      chips.append(b);
    }
    out.push(chips);
  }
  const sel = mine.filter((x) => watchSel.has(x.id)).slice(0, 2);
  const grid = el("div", "watch-grid");
  grid.append(...(await Promise.all(sel.map((x) => worldColumn(x)))));
  grid.style.setProperty("--n", String(Math.max(1, sel.length)));
  out.push(grid);
  if (sel.length === 2) out.push(await pairDiff(sel[0], sel[1]));
  return out;
};

async function worldColumn(w) {
  const col = el("section", "world-col");
  const t = await call("world_timeline", { world: w.id }).catch(() => ({ timeline: [] }));
  const tl = t.timeline || [];
  const head = el("div", "world-head");
  head.append(el("b", null, w.name), el("span", "muted", `${w.state}${w.origin ? " · from " + w.origin.split("/").pop() : ""}`));
  col.append(head);
  // The scrubber: every checkpoint on the timeline, the present at the right end.
  const cps = tl.filter((e) => e.checkpoint != null && (e.kind === "checkpoint" || e.kind === "do" || e.kind === "rewind")).map((e) => e.checkpoint);
  const uniq = [...new Set(cps)].sort((a, b) => a - b);
  const scrub = el("div", "scrub");
  const range = el("input"); range.type = "range"; range.min = "0"; range.max = String(uniq.length); range.step = "1";
  range.value = String(watchScrub.get(w.id) ?? uniq.length);
  range.setAttribute("aria-label", "Timeline");
  const label = el("span", "muted");
  const view = el("div", "world-view");
  const actions = el("div", "world-actions");
  const draw = async () => {
    const i = Number(range.value);
    watchScrub.set(w.id, i);
    actions.replaceChildren();
    if (i >= uniq.length) {
      label.textContent = "Now";
      view.replaceChildren(timelineList(tl));
      if (w.origin) actions.append(button("Keep (write back)", "primary small", () => worldAct("parallax_keep", { world: w.id }, `Writes this world back to ${w.origin}.`)));
      actions.append(button("Throw away", "quiet small danger", () => worldAct("parallax_discard", { world: w.id }, "Throws this world away.")));
      return;
    }
    const cp = uniq[i];
    label.textContent = `Checkpoint ${cp}`;
    const d = await call("world_call", { tool: "parallax_diff", args: { world: w.id, checkpoint: cp } }).catch((e) => ({ error: String(e) }));
    view.replaceChildren(diffView(d, `What changed since checkpoint ${cp}`));
    actions.append(button(`Rewind to ${cp}`, "primary small", () => worldAct("parallax_rewind", { world: w.id, checkpoint: cp }, "The present is kept as a checkpoint first, so this can be undone.")));
  };
  range.oninput = draw;
  scrub.append(range, label);
  col.append(scrub, actions, view);
  await draw();
  return col;
}

async function worldAct(tool, args, note) {
  if (!confirm(note)) return;
  try { await call("world_call", { tool, args }); } catch (e) { toast("Couldn't do that", String(e), "error"); }
  await refreshWall();
  refreshProfile();
}

function timelineList(tl) {
  const list = el("ol", "timeline");
  for (const e of [...tl].reverse().slice(0, 40)) {
    const li = el("li", "tl-" + e.kind);
    li.append(el("span", null, e.what), el("time", null, fmtTime(e.at)));
    const files = Object.entries(e.files || {});
    if (files.length) li.append(el("span", "muted tl-files", files.slice(0, 4).map(([p, k]) => `${k === "added" ? "+" : k === "removed" ? "−" : "~"} ${p}`).join("  ") + (files.length > 4 ? `  +${files.length - 4}` : "")));
    list.append(li);
  }
  return list;
}

function diffView(d, title) {
  const box = el("div", "diff");
  if (d.error) { box.append(el("p", "error-line", d.error)); return box; }
  box.append(el("h4", null, d.count ? `${title}: ${d.count} ${d.count === 1 ? "file" : "files"}` : `${title}: nothing`));
  for (const f of d.files || []) {
    const fe = el("details", "diff-file");
    fe.open = (d.files || []).length <= 3;
    fe.append(el("summary", null, `${f.change === "added" ? "+" : f.change === "removed" ? "−" : "~"} ${f.path}`));
    if (f.lines) { const pre = el("pre"); for (const l of f.lines) pre.append(el("span", l.startsWith("+") ? "add" : l.startsWith("-") ? "del" : "", l + "\n")); fe.append(pre); }
    box.append(fe);
  }
  return box;
}

async function pairDiff(a, b) {
  const d = await call("world_call", { tool: "parallax_diff", args: { world: b.id, other: a.id } }).catch((e) => ({ error: String(e) }));
  const s = el("section", "group pair-diff");
  s.append(diffView(d, `${b.name} against ${a.name}`));
  return s;
}

