// Cookie: the window over the team. Everything the team does arrives as
// events (Api.listen); this file owns the roster, the chat, the composer,
// hiring, and the shared helpers the other panels use.
const call = Api.call;
const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
const icon = (name) => { const s = document.createElementNS("http://www.w3.org/2000/svg", "svg"); s.innerHTML = `<use href="#i-${name}"/>`; return s; };
const strong = (t) => el("strong", null, t);
/** An element holding other elements (el() takes text only). */
const box = (tag, cls, ...kids) => { const n = el(tag, cls); n.append(...kids.filter((k) => k != null)); return n; };

// The project's own model ids (README, examples, the Swift app): suggestions, never a default.
const MODELS = {
  // Signed in with Enkeon: Bedrock's models through Enkeon, on Cookie credits. No keys of your own.
  enkeon: ["enkeon:eu.anthropic.claude-sonnet-4-6"],
  anthropic: ["anthropic:claude-sonnet-4-6", "anthropic:claude-haiku-4-5", "anthropic:claude-opus-4-6"],
  // Your own AWS account (Settings → Models): the model Enkeon's cloud runs on.
  bedrock: ["bedrock:eu.anthropic.claude-sonnet-4-6"],
  // Filled at start with every model pulled into Ollama on this Mac.
  ollama: [],
  openai: ["openai:gpt-6"],
  gemini: ["gemini:gemini-3.8-flash"],
};
const PROVIDER_NAME = { enkeon: "Enkeon", anthropic: "Anthropic", bedrock: "AWS", ollama: "This Mac", openai: "OpenAI", gemini: "Google" };
// Each starter wears its own shape, so the whole crew shows every look.
const STARTERS = [
  { name: "Inbox Triage", shape: "bot", job: "Sort my inbox every morning, tell me which threads need me, and draft a reply for each one. Never send anything yourself." },
  { name: "Research Scout", shape: "orb", job: "Answer research questions with sources. Every fact names the page it came from, and you say plainly when you could not find something." },
  { name: "Chief of Staff", shape: "star", job: "Help me plan the week: what matters, what can wait, and what I promised people. Ask before assuming." },
  // Comes with its own software (a plan, a workout log, a body tracker, a progress chart, a check-in form).
  { name: "Gym Trainer", shape: "mochi", template: "gym-trainer", job: "Be my gym coach. Plan my week in the plan calendar, log every workout I tell you about in the workout log, keep my body tracker up to date, and read the progress chart before you change my plan. Keep it safe: never push through pain." },
  { name: "Writing Desk", shape: "wisp", job: "Turn my rough notes into posts and emails in my own voice. Keep it short and plain." },
  { name: "Lead Pipeline Desk", shape: "crystal", job: "Qualify new inbound leads against my notes and draft a short, personal first reply for the good ones." },
  { name: "Invoice Chaser", shape: "macaron", job: "Keep track of invoices I tell you about and draft polite reminders for the ones that are overdue." },
  { name: "Meeting Notes", shape: "cloud", job: "Turn my meeting notes and transcripts into decisions, owners and next steps, and remind me of what I promised." },
  { name: "Daily Brief", shape: "ghost", job: "Every morning, brief me in five lines: my day, what's waiting on me, and the news I follow." },
  { name: "Travel Planner", shape: "gumdrop", job: "Plan my trips: options with prices and times, a day-by-day plan and a packing list. Never book or pay for anything yourself." },
  { name: "Learning Coach", shape: "bun", job: "Teach me what I want to learn in small daily lessons, quiz me, and keep track of what I've got and what to review." },
];

let rows = [];
let current = null;
let view = "chat";
let providers = [];
let pending = [];              // attachments for the next message
let approvals = [];            // everything waiting for a yes
const busy = new Set();        // agent ids with a job in flight
const live = new Map();        // job id -> { agent, trigger, input, acc, started, ui }
const statusOf = new Map();    // agent id -> what it is doing, for the sidebar
const faces = new Map();       // agent id -> roster face
let pillFace = null;

/* ---------- small shared pieces ---------- */
const fmtTime = (secs) => {
  if (!secs) return "";
  const d = new Date(secs * 1000), now = new Date();
  if (d.toDateString() === now.toDateString()) return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  const days = (now - d) / 864e5;
  if (days < 6) return d.toLocaleDateString([], { weekday: "short" });
  return d.toLocaleDateString([], { day: "numeric", month: "short" });
};
const fmtDate = (secs) => new Date(secs * 1000).toLocaleDateString([], { day: "numeric", month: "long", year: "numeric" });
const dollars = (micro) => micro >= 10_000 ? `$${(micro / 1e6).toFixed(2)}` : micro > 0 ? "under $0.01" : "$0";
const humanSize = (b) => b < 1024 ? `${b} B` : b < 1048576 ? `${(b / 1024).toFixed(1)} KB` : `${(b / 1048576).toFixed(1)} MB`;
// The sidebar preview: Markdown marks dropped, one line.
const plain = (t) => (t ?? "").replace(/```[\s\S]*?```/g, " ").replace(/[*`#>]+/g, "").replace(/(^|\s)_+|_+(?=\s|$)/g, "$1").replace(/\[([^\]]+)\]\([^)]+\)/g, "$1").replace(/\s+/g, " ").trim();
/** "search_inbox" → "Using search inbox". The tool's own name, made readable; never invented. */
const toolPhrase = (name) => "Using " + name.replace(/^external::[^:]+::/, "").replace(/[_\-.]+/g, " ").trim();
const agentById = (id) => rows.find((r) => r.id === id);

function select(options, value, onChange) {
  const s = el("select", "pick");
  for (const [v, label] of options) { const o = el("option", null, label); o.value = v; s.append(o); }
  s.value = value;
  s.onchange = () => onChange(s.value);
  return s;
}

function toggle(value, onChange, label) {
  const b = el("button", "switch" + (value ? " on" : ""));
  b.type = "button";
  b.setAttribute("role", "switch");
  b.setAttribute("aria-checked", String(value));
  b.setAttribute("aria-label", label);
  b.onclick = () => { value = !value; b.classList.toggle("on", value); b.setAttribute("aria-checked", String(value)); onChange(value); };
  return b;
}

function setRow(title, note, control) {
  const r = el("div", "row");
  const t = el("div", "row-text");
  t.append(el("span", null, title));
  if (note) t.append(el("small", null, note));
  r.append(t);
  if (control) r.append(control);
  return r;
}

function button(text, cls, onClick) {
  const b = el("button", "btn " + (cls || "quiet small"), text);
  b.type = "button";
  b.onclick = async (e) => {
    b.disabled = true;
    try { await onClick(e); } catch (err) { toast("Couldn't do that", String(err), "error"); } finally { b.disabled = false; }
  };
  return b;
}

function input(value, placeholder, attrs = {}) {
  const i = el("input", "text-in");
  i.value = value ?? "";
  i.placeholder = placeholder ?? "";
  Object.assign(i, attrs);
  return i;
}

/* ---------- toasts: news within the day's budget ---------- */
function toast(title, body, cls = "", onOpen, agent) {
  const t = el("div", "toast " + cls);
  const x = el("button", "toast-x");
  x.setAttribute("aria-label", "Dismiss");
  x.append(icon("x"));
  x.onclick = (e) => { e.stopPropagation(); t.remove(); if (agent) call("notice_feedback", { agent, dismissed: true }).catch(() => {}); };
  const text = el("div", "toast-text");
  text.append(el("strong", null, title));
  if (body) text.append(el("span", null, plain(body).slice(0, 220)));
  if (agent && agentById(agent)) { const f = Faces.create(agent, 28); t.append(f.el); }
  t.append(text, x);
  if (onOpen) t.onclick = () => { t.remove(); if (agent) call("notice_feedback", { agent, dismissed: false }).catch(() => {}); onOpen(); };
  $("toasts").append(t);
  setTimeout(() => t.classList.add("leaving"), 7000);
  setTimeout(() => t.remove(), 7400);
}

/* ---------- roster ---------- */
async function loadRoster() {
  rows = await call("list_agents");
  for (const r of rows) if (r.busy) busy.add(r.id);
  renderRoster();
  renderNeeds();
}

/** What an agent holds for you: approvals, questions, and what its worlds want to send. */
function needsOf(id) {
  const worlds = new Set((typeof wallWorlds === "undefined" ? [] : wallWorlds).filter((w) => w.owner === id).map((w) => w.id));
  return {
    count: approvals.filter((a) => a.agent === id).length + questions.filter((q) => q.agent === id).length
      + (typeof wallWaiting === "undefined" ? 0 : wallWaiting.filter((e) => worlds.has(e.world)).length),
    // The newest of them: something new for you moves the agent up, like a new message.
    at: Math.max(0, ...approvals.filter((a) => a.agent === id).map((a) => a.asked_at ?? 0), ...questions.filter((q) => q.agent === id).map((q) => q.asked_at ?? 0),
      ...(typeof wallWaiting === "undefined" ? [] : wallWaiting.filter((e) => worlds.has(e.world)).map((e) => e.at ?? 0))),
  };
}

/** Latest activity first, like a messaging app: a message, or anything new it holds for you. */
function sortRows() {
  const at = (r) => Math.max(r.last_at ?? r.created_at, needsOf(r.id).at);
  rows.sort((a, b) => at(b) - at(a));
}
let needsOnly = false; // the "Needs you" filter at the top of the list

function renderRoster() {
  sortRows();
  const q = $("search").value.trim().toLowerCase();
  const matches = rows.filter((r) => !q || r.name.toLowerCase().includes(q) || r.job.toLowerCase().includes(q));
  // Searching finds hidden agents too; otherwise they wait behind "Hidden".
  const shown = matches.filter((r) => (q || showHidden || !r.hidden) && (!needsOnly || needsOf(r.id).count > 0));
  faces.forEach((f) => f.stop());
  faces.clear();
  const item = (r) => {
    const unread = r.unread > 0 && !(view === "chat" && current?.id === r.id);
    const li = el("li", "agent" + (view === "chat" && current?.id === r.id ? " active" : "") + (unread ? " unread" : ""));
    li.dataset.id = r.id;
    li.tabIndex = 0;
    li.setAttribute("role", "button");
    li.setAttribute("aria-label", r.name);
    li.title = r.name;
    const face = Faces.create(r.id, 46);
    const needs = needsOf(r.id).count;
    const waiting = needs > 0;
    if (busy.has(r.id)) face.setMood(waiting ? "waiting" : "working");
    faces.set(r.id, face);
    const meta = el("div", "meta");
    const preview = busy.has(r.id) ? (waiting ? "Waiting for your yes" : statusOf.get(r.id) ?? "Working…") : plain(r.last ?? r.job);
    meta.append(el("div", "name", r.name), el("div", "preview" + (busy.has(r.id) ? " busy" : ""), preview));
    const right = el("div", "row-right");
    right.append(el("time", null, fmtTime(r.last_at ?? r.created_at)));
    // Amber: it needs your yes or an answer. Green: messages you haven't read.
    const badges = el("span", "badges");
    if (waiting) { const b = el("span", "dot-badge", String(needs)); b.title = `${needs} waiting for you`; badges.append(b); }
    if (unread) badges.append(el("span", "unread-badge", String(r.unread)));
    if (waiting || unread) right.append(badges);
    if (r.probation_until && r.probation_until > Date.now() / 1000) right.append(el("span", "tag", "probation"));
    if (r.pinned) right.append(svgIcon("i-pin", "pin-mark"));
    if (r.hidden) li.classList.add("is-hidden");
    li.append(face.el, meta, right);
    li.onmouseenter = () => face.peek(true);
    li.onmouseleave = () => face.peek(false);
    li.onclick = () => openAgent(r.id);
    li.onkeydown = (e) => {
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); openAgent(r.id); }
      if (e.key === "ContextMenu" || (e.shiftKey && e.key === "F10")) { e.preventDefault(); const b = li.getBoundingClientRect(); openRowMenu(r.id, b.left + 40, b.bottom - 6); }
    };
    li.oncontextmenu = (e) => { e.preventDefault(); openRowMenu(r.id, e.clientX, e.clientY); };
    return li;
  };
  const head = (text) => { const h = el("li", "roster-head", text); h.setAttribute("role", "presentation"); return h; };
  // Pinned first, then everything by latest activity (Cookie too), then each section in name order.
  const rest = shown;
  const pinned = rest.filter((r) => r.pinned);
  const loose = rest.filter((r) => !r.pinned && !r.section);
  const sections = [...new Set(rest.filter((r) => !r.pinned && r.section).map((r) => r.section))].sort((a, b) => a.localeCompare(b));
  const out = [];
  if (pinned.length) { if (!q) out.push(head("Pinned")); out.push(...pinned.map(item)); }
  if (loose.length) { if (!q && (pinned.length || sections.length)) out.push(head("Recent")); out.push(...loose.map(item)); }
  for (const name of sections) {
    if (!q) out.push(head(name));
    out.push(...rest.filter((r) => !r.pinned && r.section === name).map(item));
  }
  const hiddenCount = rows.filter((r) => r.hidden).length;
  if (!q && hiddenCount) {
    const t = el("li", "roster-hidden-toggle");
    const b = el("button", null, showHidden ? "Hide hidden agents" : `Hidden (${hiddenCount})`);
    b.onclick = () => { showHidden = !showHidden; renderRoster(); };
    t.append(b);
    out.push(t);
  }
  $("roster").replaceChildren(...out);
  $("no-match").hidden = !((q || needsOnly) && shown.length === 0);
  $("no-match").textContent = needsOnly && !q ? "Nothing needs you right now." : "No agent matches.";
  $("no-agents").hidden = rows.length > 0;
}

/** The "Needs you" chip at the top of the list, and the count on the app's icon. */
function renderNeeds() {
  const n = approvals.length + (typeof questions === "undefined" ? 0 : questions.length) + (typeof wallWaiting === "undefined" ? 0 : wallWaiting.length);
  const chip = $("needs-chip");
  if (n === 0 && needsOnly) { needsOnly = false; renderRoster(); }
  chip.hidden = n === 0;
  chip.classList.toggle("active", needsOnly);
  chip.setAttribute("aria-pressed", String(needsOnly));
  $("needs-count").textContent = String(n);
  if (n !== lastBadge) { lastBadge = n; Api.setBadge(n).catch(() => {}); }
  document.querySelectorAll(".net-btn").forEach((b) => b.classList.toggle("active", view === "network"));
}
let lastBadge = -1;

/* ---------- views ---------- */
function show(v) {
  view = v;
  for (const id of ["chat", "hire", "network"]) $(id).hidden = id !== v;
  if (v !== "chat") { closeProfile(); closeWorkspace(); }
  if (v !== "hire") stopCrew();
  renderNeeds();
}

const drafts = new Map(); // agent id -> unsent text, kept when you switch

// Your bubbles take the colour of the agent you're talking to (a yellow agent, a
// yellow bubble), with dark or light words, whichever reads better on it.
function paintYou(id) {
  const c = Faces.color(id);
  const [r, g, b] = (c.match(/\d+/g) ?? [173, 92, 39]).map(Number);
  const lin = (v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; };
  const lum = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  const chat = $("chat");
  chat.style.setProperty("--you-bg", c);
  chat.style.setProperty("--you-ink", lum > 0.36 ? "#1c140a" : "#fff");
}

async function openAgent(id) {
  const r = agentById(id);
  if (!r) return;
  closePage();
  if (current && current.id !== id) drafts.set(current.id, $("input").value);
  closeTalk();
  current = r;
  renderModelChip();
  paintYou(r.id);
  if (r.unread) { r.unread = 0; call("mark_read", { id }).catch(() => {}); }
  $("input").value = drafts.get(id) ?? "";
  autosize();
  closePops();
  show("chat");
  renderRoster();
  syncSend();
  pillFace?.stop();
  pillFace = Faces.create(r.id, 26);
  if (busy.has(r.id)) pillFace.setMood("working");
  $("who-face").replaceChildren(pillFace.el);
  $("who-name").textContent = r.name;
  if (typeof loadPin === "function") loadPin(current.id);
  if (typeof madeFor !== "undefined" && madeFor) openMadePanel();
  if (!$("workspace").hidden) openWorkspace();
  const lines = await call("history", { id: r.id });
  if (current?.id !== id) return;
  renderLog(r, lines);
  renderSuggest(r, lines.length === 0 && !busy.has(r.id) && needsOf(r.id).count === 0);
  // What it holds for you sits at the end of its chat (today.js), then what waits for your yes.
  const desk = el("div", "desk");
  desk.id = "desk";
  desk.hidden = true;
  $("log").append(desk);
  renderDesk(r.id);
  for (const a of approvals.filter((a) => a.agent === r.id)) $("log").append(approvalCard(a));
  for (const q of questions.filter((q) => q.agent === r.id)) $("log").append(questionCard(q));
  for (const job of live.values()) if (job.agent === r.id) attachLive(job);
  scrollDown(true);
  $("input").focus();
}

/** Starters for an empty chat, from the agent's own job. Click one to fill the box. */
function renderSuggest(r, show) {
  const box = $("suggest");
  box.hidden = !show;
  if (!show) return;
  const job = r.job.replace(/\.$/, "");
  const ideas = [
    "What do you need from me to get started?",
    `Show me how you'd do this: ${job.charAt(0).toLowerCase() + job.slice(1)}`,
    "What can't you do yet?",
  ];
  box.replaceChildren(...ideas.map((t) => {
    const b = el("button", null, t);
    b.type = "button";
    b.onclick = () => { $("input").value = t; autosize(); syncSend(); $("input").focus(); };
    return b;
  }));
}

function renderLog(r, lines) {
  const log = $("log");
  log.replaceChildren();
  const intro = el("div", "intro");
  const f = Faces.create(r.id, 96);
  intro.append(f.el, el("h2", null, r.name), el("p", null, r.job));
  log.append(intro);
  log.append(event([icon("sparkle"), "Hired ", strong(fmtDate(r.created_at))]));
  if (r.probation_until && r.probation_until > Date.now() / 1000) {
    log.append(event([icon("shield"), "On probation until ", strong(fmtDate(r.probation_until)), ": changes it tries are recorded, not made"], "ask"));
  }
  for (const l of lines) log.append(line(l));
}

function event(parts, cls = "") {
  const div = el("div", "event " + cls);
  div.append(...parts);
  return div;
}

const TALK_TOOLS = new Set(["ask_agent", "message_contact", "message_agent", "propose_deal"]);

/** The salt that draws the other agent's face: yours for teammates, theirs for contacts. */
const talkSalt = () => undefined;

/** "2 messages with Writer": a conversation this agent had with another agent, inline where it happened. */
function talkPill(t) {
  const row = el("div", "talk-row");
  const b = el("button", "talk-pill");
  b.type = "button";
  const n = t.messages.length;
  b.append(el("span", null, `${n} message${n === 1 ? "" : "s"} with`), Faces.create(t.with_id, 20, talkSalt(t)).el, el("span", "talk-name", t.with_name));
  b.setAttribute("aria-label", `Open ${n} messages with ${t.with_name}`);
  b.onclick = () => openTalk(t);
  row.append(b);
  return row;
}

function openTalk(t) {
  const v = $("talk-view");
  const me = current;
  const head = el("div", "talk-head");
  const pair = el("div", "pill talk-pair");
  pair.id = "talk-title";
  pair.append(Faces.create(me.id, 22).el, el("span", null, me.name), icon("swap"), Faces.create(t.with_id, 22, talkSalt(t)).el, el("span", null, t.with_name));
  head.append(pair);
  if (t.with_address) head.append(el("small", "talk-addr", t.kind === "network" ? `${t.with_address} · another person's agent` : t.with_address));
  const list = el("div", "talk-list");
  t.messages.forEach((m, i) => {
    const item = el("div", "talk-msg" + (m.mine ? " mine" : ""));
    const name = el("div", "talk-who", m.who);
    name.style.color = m.mine ? Faces.color(me.id) : Faces.color(t.with_id, talkSalt(t));
    const bubble = el("div", "bubble md");
    bubble.innerHTML = Md.render(m.text);
    if (m.mine) hydrateMd(bubble, me.id);
    const body = el("div", "talk-body");
    body.append(name, bubble);
    // The face sits beside the last message in each run, like a chat app.
    const lastOfRun = !t.messages[i + 1] || t.messages[i + 1].mine !== m.mine;
    const slot = el("div", "talk-face");
    if (lastOfRun) slot.append(m.mine ? Faces.create(me.id, 26).el : Faces.create(t.with_id, 26, talkSalt(t)).el);
    item.append(slot, body, actions(m.text));
    list.append(item);
  });
  const close = el("button", "pill talk-close", "Close Chat");
  close.type = "button";
  close.onclick = closeTalk;
  v.replaceChildren(head, list, close);
  v.hidden = false;
  requestAnimationFrame(() => { v.classList.add("open"); close.focus({ preventScroll: true }); });
}

function closeTalk() {
  const v = $("talk-view");
  if (v.hidden) return;
  v.classList.remove("open");
  setTimeout(() => { v.hidden = true; v.replaceChildren(); }, 180);
}

/* ---------- rich replies: pictures, recordings, videos and files an agent shows ---------- */
const FILE_KIND = { image: "Image", video: "Video", audio: "Audio", pdf: "PDF", sheet: "Sheet", document: "Document", slides: "Slides", text: "Text", archive: "Archive", other: "File" };
const fileCache = new Map();
/** One file the agent named, from where it may read (`chat_file`); asked once per agent and path. */
function chatFile(agentId, src) {
  const key = `${agentId}\u0000${src}`;
  if (!fileCache.has(key)) {
    const p = call("chat_file", { id: agentId, path: src });
    p.catch(() => fileCache.delete(key)); // a file made later is worth asking about again
    fileCache.set(key, p);
  }
  return fileCache.get(key);
}
// An absolute or home path with an extension, in `code`: a file worth a card.
const PATH_IN_CODE = /^(?:\/|~\/)[^\s`]+\.[A-Za-z0-9]{1,5}$/;

/** A file as a card: what it is, and (on this computer) open it or show it in Finder. */
function fileCard(agentId, f, label) {
  const card = el("div", "file-card");
  const ic = el("span", `file-ic k-${f.kind}`);
  ic.append(icon(f.kind === "image" ? "sparkle" : f.kind === "video" || f.kind === "audio" ? "wave" : "file"));
  const meta = el("div", "file-meta");
  meta.append(el("div", "file-name", label && label !== f.name ? `${label} · ${f.name}` : f.name), el("div", "file-sub", `${FILE_KIND[f.kind] ?? "File"} · ${humanSize(f.size)}`));
  card.append(ic, meta);
  if (!Api.web) {
    const acts = el("div", "file-acts");
    if (f.openable) acts.append(button("Open", "quiet small", () => Api.openFile(agentId, f.path).catch((e) => toast("Couldn't open it", String(e), "error"))));
    acts.append(button("Show in Finder", "quiet small", () => Api.openFile(agentId, f.path, true).catch((e) => toast("Couldn't show it", String(e), "error"))));
    card.append(acts);
  }
  return card;
}

/** A picture to look at closely: the whole window, Esc or a click to close. */
function lightbox(src, alt) {
  const v = el("div", "lightbox");
  v.setAttribute("role", "dialog");
  v.setAttribute("aria-label", alt || "Image");
  const img = el("img");
  img.src = src;
  img.alt = alt || "";
  v.append(img);
  const close = () => { v.remove(); removeEventListener("keydown", onKey, true); };
  const onKey = (e) => { if (e.key === "Escape") { e.stopPropagation(); close(); } };
  v.onclick = close;
  addEventListener("keydown", onKey, true);
  document.body.append(v);
}

function mediaEl(f, alt) {
  const src = `data:${f.media_type};base64,${f.data}`;
  if (f.kind === "image") {
    const img = el("img", "md-img");
    img.src = src;
    img.alt = alt || f.name;
    img.loading = "lazy";
    img.tabIndex = 0;
    img.onclick = () => lightbox(src, img.alt);
    img.onkeydown = (e) => { if (e.key === "Enter") lightbox(src, img.alt); };
    return img;
  }
  const m = el(f.kind === "video" ? "video" : "audio", f.kind === "video" ? "md-video" : "md-audio");
  m.controls = true;
  m.preload = "metadata";
  m.src = src;
  return m;
}

/** A picture on the web: loads only when clicked, and tells the site nothing about where it was shown. */
function remoteImage(url, alt) {
  let host = url;
  try { host = new URL(url).host; } catch {}
  // Wikimedia's image server serves only public files that exist (find_images): shown at once.
  if (/^https:\/\/upload\.wikimedia\.org\/wikipedia\/commons\/[\w/%.()-]+$/.test(url)) {
    const img = el("img", "md-img");
    img.referrerPolicy = "no-referrer";
    img.loading = "lazy";
    img.alt = alt || "";
    img.src = url;
    img.onclick = () => lightbox(url, img.alt);
    img.onerror = () => img.replaceWith(el("span", "md-missing", "The picture didn't load."));
    return img;
  }
  const b = el("button", "md-remote");
  b.type = "button";
  b.append(icon("eye"), el("span", null, `Show image from ${host}`));
  b.title = url;
  b.onclick = () => {
    const img = el("img", "md-img");
    img.referrerPolicy = "no-referrer";
    img.alt = alt || "";
    img.src = url;
    img.onclick = () => lightbox(url, img.alt);
    img.onerror = () => img.replaceWith(el("span", "md-missing", `The image from ${host} didn't load.`));
    b.replaceWith(img);
  };
  return b;
}

/** A place, in reading order, right after `block` for something that arrives later. */
function slotAfter(block) {
  let box = block.nextElementSibling;
  if (!box?.classList.contains("md-attach")) { box = el("div", "md-attach"); block.after(box); }
  const slot = el("div", "md-slot");
  box.append(slot);
  return slot;
}

/** Fill in what a rendered reply points at: its pictures, recordings, videos and files. */
function hydrateMd(root, agentId) {
  if (!root || !agentId) return;
  hydrateBlocks(root, agentId);
  for (const ph of root.querySelectorAll(".md-media:not([data-done])")) {
    ph.dataset.done = "1";
    const { src, alt } = ph.dataset;
    if (/^https?:\/\//.test(src)) { ph.replaceChildren(remoteImage(src, alt)); continue; }
    chatFile(agentId, src).then((f) => ph.replaceChildren(f.data ? mediaEl(f, alt) : fileCard(agentId, f, alt)))
      .catch((e) => ph.replaceChildren(el("span", "md-missing", `${alt || src}: ${String(e)}`)));
  }
  for (const ph of root.querySelectorAll(".md-file:not([data-done])")) {
    ph.dataset.done = "1";
    const label = ph.textContent;
    const slot = slotAfter(ph.closest("p, li, td") ?? ph);
    if (PAGE_KIND[extOf(ph.dataset.src)]) { slot.replaceWith(pageCard(agentId, ph.dataset.src, label)); continue; }
    chatFile(agentId, ph.dataset.src).then((f) => slot.replaceWith(f.data ? mediaEl(f, label) : fileCard(agentId, f, label)))
      .catch(() => slot.remove()); // not a file it can show: the words stay as words
  }
  let cards = 0;
  for (const c of root.querySelectorAll("p code, li code")) {
    const text = c.textContent.trim();
    if (!PATH_IN_CODE.test(text) || c.dataset.done || cards >= 6) continue;
    c.dataset.done = "1";
    cards++;
    const slot = slotAfter(c.closest("p, li") ?? c);
    if (PAGE_KIND[extOf(text)]) { chatFile(agentId, text).then(() => slot.replaceWith(pageCard(agentId, text))).catch(() => slot.remove()); continue; }
    chatFile(agentId, text).then((f) => slot.replaceWith(f.data ? mediaEl(f) : fileCard(agentId, f))).catch(() => slot.remove());
  }
}

// Copy a code block, from any reply.
document.addEventListener("click", async (e) => {
  const b = e.target.closest?.(".md-copy");
  if (!b) return;
  const code = b.closest(".md-code")?.querySelector("pre")?.textContent ?? "";
  try { await navigator.clipboard.writeText(code); b.textContent = "Copied"; setTimeout(() => (b.textContent = "Copy"), 1200); } catch {}
});

/* ---------- pages: documents an agent made, as cards that open over the chat ---------- */
const PAGE_KIND = { md: "Page", markdown: "Page", html: "Web page", htm: "Web page", pdf: "PDF" };
const extOf = (p) => (String(p).split(/[?#]/)[0].match(/\.([a-z0-9]+)$/i)?.[1] ?? "").toLowerCase();

/** What a Markdown page says about itself: its title, first paragraph and sections. */
function pageOutline(md) {
  const lines = md.replace(/\r/g, "").split("\n");
  const h1 = lines.find((l) => /^#\s+/.test(l))?.replace(/^#\s+/, "").trim();
  const sections = lines.filter((l) => /^##\s+/.test(l)).map((l) => l.replace(/^##\s+/, "").trim()).slice(0, 14);
  const para = md.split(/\n{2,}/).map((b) => b.trim()).find((b) => b && !/^(#|>|[-*+]\s|\d+[.)]\s|```|\||<)/.test(b));
  return { title: h1, about: para ? plain(para).slice(0, 280) : "", sections };
}

/** A web page's title and first words, read without running or showing it. */
function htmlOutline(html) {
  const doc = new DOMParser().parseFromString(html, "text/html");
  const title = doc.querySelector("title")?.textContent?.trim() || doc.querySelector("h1")?.textContent?.trim();
  const about = (doc.querySelector('meta[name="description"]')?.getAttribute("content") || doc.querySelector("p")?.textContent || "").trim().slice(0, 280);
  const sections = [...doc.querySelectorAll("h2")].map((h) => h.textContent.trim()).filter(Boolean).slice(0, 14);
  return { title, about, sections };
}

/** A document as a card, like a page in a messaging app: its title, what it's about, its sections. */
function pageCard(agentId, src, label) {
  const card = el("button", "page-card");
  card.type = "button";
  const preview = el("div", "page-preview");
  const foot = el("div", "page-foot");
  const ic = el("span", "page-ic");
  ic.append(icon("file"));
  const meta = el("div", "page-meta");
  const name = el("div", "page-name", label || src.split("/").pop());
  const kind = el("div", "page-kind", PAGE_KIND[extOf(src)] ?? "Document");
  meta.append(name, kind);
  foot.append(ic, meta);
  card.append(preview, foot);
  card.disabled = true;
  chatFile(agentId, src).then((f) => {
    const o = f.text ? (extOf(f.name) === "md" || extOf(f.name) === "markdown" ? pageOutline(f.text) : htmlOutline(f.text)) : { title: null, about: "", sections: [] };
    const title = o.title || label || f.name.replace(/\.[^.]+$/, "");
    name.textContent = title;
    kind.textContent = `${PAGE_KIND[extOf(f.name)] ?? "Document"} · ${humanSize(f.size)}`;
    preview.append(el("div", "page-title", title));
    if (o.about) preview.append(el("p", "page-about", o.about));
    if (o.sections.length) {
      const toc = el("div", "page-toc");
      toc.append(el("small", null, "On this page"), ...o.sections.map((s) => el("span", null, s)));
      preview.append(toc);
    } else if (extOf(f.name) === "pdf") preview.append(el("p", "page-about", `${humanSize(f.size)} PDF`));
    card.disabled = false;
    card.onclick = () => openPage(agentId, f, title);
  }).catch((e) => { card.replaceWith(el("span", "md-missing", `${label || src}: ${String(e)}`)); });
  return card;
}

/** A page open over the chat: read it, share it, close it; the message box stays at hand. */
function openPage(agentId, f, title) {
  const v = $("doc-view");
  const head = el("div", "doc-head");
  const pill = el("div", "pill doc-pill");
  pill.append(icon("file"), el("span", null, title));
  const acts = el("div", "doc-acts");
  const share = el("button", "pill doc-btn", "Share");
  share.type = "button";
  share.onclick = (e) => {
    e.stopPropagation();
    const items = [];
    if (f.text) items.push(["Copy its text", () => navigator.clipboard.writeText(f.text).then(() => toast("Copied", title))]);
    if (!Api.web) {
      if (f.openable) items.push(["Open in its app", () => Api.openFile(agentId, f.path).catch((err) => toast("Couldn't open it", String(err), "error"))]);
      items.push(["Show in Finder", () => Api.openFile(agentId, f.path, true).catch((err) => toast("Couldn't show it", String(err), "error"))]);
    }
    const menu = el("div", "pop menu doc-menu");
    for (const [t, fn] of items) { const b = el("button", null, t); b.type = "button"; b.onclick = () => { menu.remove(); fn(); }; menu.append(b); }
    acts.querySelector(".doc-menu")?.remove();
    acts.append(menu);
    setTimeout(() => addEventListener("click", () => menu.remove(), { once: true }), 0);
  };
  const x = el("button", "round soft doc-x");
  x.type = "button";
  x.setAttribute("aria-label", "Close page");
  x.append(icon("x"));
  x.onclick = closePage;
  acts.append(share, x);
  head.append(pill, acts);
  const body = el("div", "doc-body");
  const ext = extOf(f.name);
  if (ext === "pdf" && f.data) {
    const blob = new Blob([Uint8Array.from(atob(f.data), (c) => c.charCodeAt(0))], { type: "application/pdf" });
    const frame = el("iframe", "doc-pdf");
    frame.title = title;
    frame.src = URL.createObjectURL(blob);
    body.classList.add("pdf");
    body.append(frame);
  } else if ((ext === "html" || ext === "htm") && f.text) {
    // Shown, never run: no scripts, no reaching the web, no reaching Cookie.
    const frame = el("iframe", "doc-html");
    frame.title = title;
    frame.setAttribute("sandbox", "");
    frame.setAttribute("referrerpolicy", "no-referrer");
    frame.srcdoc = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:">` + f.text;
    body.classList.add("html");
    body.append(frame);
  } else if (f.text) {
    const page = el("article", "doc-page md");
    page.innerHTML = Md.render(f.text);
    hydrateMd(page, agentId);
    // "On this page": its sections, each a jump.
    const hs = [...page.querySelectorAll("h4")];
    if (hs.length > 2) {
      const toc = el("nav", "doc-toc");
      toc.append(el("small", null, "On this page"));
      hs.forEach((h) => { const b = el("button", null, h.textContent); b.type = "button"; b.onclick = () => h.scrollIntoView({ behavior: "smooth", block: "start" }); toc.append(b); });
      const first = page.querySelector("h3 ~ p, h3 + *") ?? page.firstElementChild;
      (page.querySelector("h3")?.nextElementSibling?.tagName === "P" ? page.querySelector("h3").nextElementSibling : first)?.after(toc);
    }
    body.append(page);
  } else body.append(el("p", "md-missing", "This document is too large to show here: open it in its app."));
  v.replaceChildren(head, body);
  v.hidden = false;
  $("chat").classList.add("doc-open");
  requestAnimationFrame(() => v.classList.add("open"));
}

function closePage() {
  const v = $("doc-view");
  if (v.hidden) return;
  v.classList.remove("open");
  delete v.dataset.board;
  delete v.dataset.made;
  $("made-btn")?.classList.remove("on");
  $("chat").classList.remove("doc-open");
  v.querySelectorAll("iframe.doc-pdf").forEach((fr) => URL.revokeObjectURL(fr.src));
  setTimeout(() => { v.hidden = true; v.replaceChildren(); }, 160);
}

/** The documents a job made, under its answer. */
function documentsLine(agentId, paths) {
  const row = el("div", "msg agent pages");
  const col = el("div", "page-col");
  for (const p of paths) col.append(pageCard(agentId, p));
  row.append(col);
  return row;
}

/* ---------- helpers: the read-only assistants a job sends out side by side ---------- */
const HELPER_STATE = { waiting: "Waiting", working: "Working", done: "Done", failed: "Couldn't finish" };

/** A card of the helpers one job sent: each task while it works, then its report, a click away. */
function helpersCard(agentId) {
  const card = el("div", "helpers");
  const head = el("div", "helpers-head");
  const face = Faces.create(agentId, 18);
  const title = el("span", "helpers-title");
  const count = el("span", "helpers-count");
  head.append(face.el, title, count);
  const list = el("ol", "helpers-list");
  card.append(head, list);
  const rows = new Map();
  const name = agentById(agentId)?.name ?? "It";
  const tally = () => {
    const all = [...rows.values()];
    const done = all.filter((r) => r.state === "done" || r.state === "failed").length;
    title.textContent = `${name} sent ${all.length} helper${all.length === 1 ? "" : "s"}`;
    count.textContent = done === all.length ? "" : `${done} of ${all.length} back`;
    card.classList.toggle("busy", done < all.length);
  };
  return {
    el: card,
    /** Add or move on helper `n`: its task, `waiting` / `working` / `done` / `failed`, and its report. */
    set(n, task, state, note = "") {
      let r = rows.get(n);
      if (!r) {
        const li = el("li", "helper");
        const btn = el("button", "helper-row");
        btn.type = "button";
        const num = el("span", "helper-n", String(n));
        const text = el("span", "helper-task", task);
        const st = el("span", "helper-state");
        btn.append(num, text, st);
        const report = el("div", "helper-report md");
        report.hidden = true;
        btn.onclick = () => {
          if (!r.note) return;
          report.hidden = !report.hidden;
          li.classList.toggle("open", !report.hidden);
          btn.setAttribute("aria-expanded", String(!report.hidden));
        };
        li.append(btn, report);
        list.append(li);
        r = { li, btn, st, report, text, state: "", note: "" };
        rows.set(n, r);
      }
      if (task) r.text.textContent = task;
      r.state = state;
      r.note = note;
      r.li.className = `helper ${state}${r.report.hidden ? "" : " open"}`;
      r.st.replaceChildren(...(state === "done" ? [icon("check")] : state === "failed" ? [icon("x")] : []), HELPER_STATE[state] ?? state);
      r.btn.disabled = !note;
      r.btn.setAttribute("aria-label", `Helper ${n}: ${task || r.text.textContent}. ${HELPER_STATE[state] ?? state}${note ? ". Show its report" : ""}`);
      if (note) { r.report.innerHTML = Md.render(note); hydrateMd(r.report, agentId); }
      tally();
    },
  };
}

function line(l) {
  if (l.from === "talk") return talkPill(l.talk);
  if (l.from === "documents") return documentsLine(current?.id, l.text.split("\n").filter(Boolean));
  if (l.from === "helpers") {
    const c = helpersCard(current?.id);
    l.helpers.forEach((h, i) => c.set(i + 1, h.task, h.failed ? "failed" : "done", h.report));
    return c.el;
  }
  if (l.from === "file") {
    const row = el("div", "msg file");
    const chip = el("div", "file-chip");
    const name = l.text.split("\n")[0].replace(/ \(an image, below\)$/, "");
    if (l.image) {
      const img = el("img", "file-thumb");
      img.src = l.image;
      img.alt = name;
      img.onclick = () => lightbox(l.image, name);
      chip.append(img);
    } else chip.append(icon("clip"));
    chip.append(name);
    row.append(chip);
    return row;
  }
  // Another of your agents, brought in with @: its face and name over its answer.
  if (l.from === "guest") {
    const row = el("div", "msg agent guest");
    const col = el("div", "guest-col");
    const b = el("div", "bubble md");
    b.innerHTML = Md.render(l.text);
    hydrateMd(b, l.by);
    col.append(guestHead(l.by), b);
    row.append(col, actions(l.text));
    return row;
  }
  const row = el("div", "msg " + l.from);
  const b = el("div", "bubble");
  if (l.from === "agent") { b.classList.add("md"); b.innerHTML = Md.render(l.text); hydrateMd(b, current?.id); }
  else b.textContent = l.text;
  row.append(b, actions(l.text));
  return row;
}

/** Shown on hover beside a message: copy its text. */
function actions(text) {
  const bar = el("div", "msg-actions");
  const copy = el("button");
  copy.type = "button";
  copy.title = "Copy";
  copy.setAttribute("aria-label", "Copy message");
  copy.append(icon("copy"));
  copy.onclick = async () => {
    try { await navigator.clipboard.writeText(text); copy.classList.add("done"); setTimeout(() => copy.classList.remove("done"), 1200); } catch {}
  };
  bar.append(copy);
  const speak = typeof speakButton === "function" ? speakButton(text) : null;
  if (speak) bar.append(speak);
  return bar;
}

const scrollDown = (force) => {
  const log = $("log");
  if (force || log.scrollHeight - log.scrollTop - log.clientHeight < 160) log.scrollTop = log.scrollHeight;
};

/* ---------- approvals: one card, every surface ---------- */
function approvalCard(a) {
  const c = el("div", "approve-card");
  c.dataset.approval = a.id;
  const head = el("div", "approve-head");
  const f = Faces.create(a.agent, 24); f.setMood("waiting");
  head.append(f.el, el("span", null, `${a.agent_name} needs your yes`), el("span", "tag", a.effect));
  const tool = el("div", "approve-tool", toolPhrase(a.tool));
  const pre = el("pre", "approve-preview", a.preview);
  c.append(head, tool, pre);
  if (a.from_data?.length) c.append(el("p", "approve-warn", `Not from you, check these: ${a.from_data.join(", ")}`));
  if (a.checker) {
    const ch = el("p", "approve-checker " + a.checker.verdict);
    ch.append(strong(`Checker (${a.checker.model}): `), a.checker.note);
    c.append(ch);
  }
  const bar = el("div", "approve-actions");
  bar.append(
    button("Deny", "quiet small", () => call("answer", { id: a.id, yes: false })),
    button("Approve", "primary small", () => call("answer", { id: a.id, yes: true })),
  );
  c.append(bar);
  return c;
}

async function loadApprovals() {
  approvals = await call("approvals");
  renderNeeds();
}

/* ---------- live jobs ---------- */
function setStatus(id, text) {
  if (text) statusOf.set(id, text); else statusOf.delete(id);
  const li = [...$("roster").children].find((n) => n.dataset.id === id);
  const p = li?.querySelector(".preview");
  if (p && text) { p.textContent = text; p.classList.add("busy"); }
}

function setMood(id, mood) {
  // Every face of this agent on screen moves together: the list, the header, a call.
  const all = new Set([faces.get(id), current?.id === id ? pillFace : null, ...Faces.of(id)].filter(Boolean));
  all.forEach((f) => f.setMood(mood));
}
const allFaces = (id, fn) => new Set([faces.get(id), current?.id === id ? pillFace : null, ...Faces.of(id)].filter(Boolean)).forEach(fn);

/** A handoff: the asking agent glances at the one it asked, who turns to look back. */
function glanceBetween(fromId, toId) {
  const a = faces.get(fromId), b = faces.get(toId);
  if (!a || !b) return;
  const ra = a.rect(), rb = b.rect();
  if (!ra.width || !rb.width) return;
  a.glanceAt(rb.left + rb.width / 2, rb.top + rb.height / 2, 1600);
  setTimeout(() => b.glanceAt(ra.left + ra.width / 2, ra.top + ra.height / 2, 1300), 260);
}

const TRIGGER_LABEL = {
  routine: () => "Routine",
  telegram: () => "From your phone",
  handoff: (t) => `Asked by ${agentById(t.from)?.name ?? "another agent"}`,
  peer: (t) => `From ${t.label}`,
  contact: (t) => `From ${t.label}`,
  inbox: () => "Inbox scan",
  memory: () => "Woke: its memory changed",
};

/** The chat a job shows in: its own agent's, or, for an agent brought in with @, the chat it was asked in. */
const chatOf = (job) => (job.trigger?.kind === "mention" ? job.trigger.chat : job.agent);

/** A reply's header in a chat it is a guest in: its face and name, like a group chat. */
function guestHead(agentId) {
  const h = el("div", "guest-head");
  h.append(Faces.create(agentId, 18).el, el("span", null, agentById(agentId)?.name ?? "An agent"));
  return h;
}

/** Give a job in flight its place in the open chat: a status line, then its answer. */
function attachLive(job) {
  if (current?.id !== chatOf(job) || view !== "chat") return;
  const guest = chatOf(job) !== job.agent;
  job.ui?.status?.remove();
  const label = guest ? null : TRIGGER_LABEL[job.trigger.kind];
  if (label && !job.ui?.announced) {
    $("log").append(event([icon("sparkle"), strong(label(job.trigger)), ": ", plain(job.input).slice(0, 160)]));
  }
  const status = el("div", "status");
  const face = Faces.create(job.agent, 22);
  face.setMood(job.acc ? "working" : "thinking");
  const text = el("span", null, guest ? `${agentById(job.agent)?.name ?? "It"} is answering` : job.statusText ?? "Thinking it through");
  status.append(face.el, text);
  const row = el("div", "msg agent" + (guest ? " guest" : ""));
  const reply = el("div", "bubble md");
  if (guest) { const col = el("div", "guest-col"); col.append(guestHead(job.agent), reply); row.append(col); } else row.append(reply);
  if (job.acc) { reply.innerHTML = Md.render(job.acc); $("log").append(row); }
  else $("log").append(status);
  job.ui = { status, face, text, row, reply, announced: true };
  if (job.helpers) for (const h of job.helpers.values()) placeHelpers(job).set(h.n, h.task, h.state, h.note);
  renderTodos(job.agent);
  scrollDown();
}

/** The job's helpers card, in the chat just above where its answer is coming. */
function placeHelpers(job) {
  if (!job.ui.helpers?.el.isConnected) {
    job.ui.helpers = helpersCard(job.agent);
    const before = job.ui.status.isConnected ? job.ui.status : job.ui.row.isConnected ? job.ui.row : null;
    if (before) before.before(job.ui.helpers.el); else $("log").append(job.ui.helpers.el);
  }
  return job.ui.helpers;
}

function onTeamEvent(ev) {
  switch (ev.kind) {
    case "job_started": {
      const job = { agent: ev.agent, trigger: ev.trigger, input: ev.input, acc: "", started: false, ui: null, mine: ev.trigger.kind === "chat" };
      // Another agent asked this one: on its own, outside the chat; it folds into a conversation when done.
      job.inbound = ["handoff", "peer", "contact", "mention"].includes(ev.trigger.kind);
      if (["test", "shadow"].includes(ev.trigger.kind)) return; // private runs: their panels follow them
      live.set(ev.job, job);
      busy.add(ev.agent);
      const row = agentById(ev.agent);
      if (row) { row.last_at = Math.floor(Date.now() / 1000); renderRoster(); }
      setStatus(ev.agent, "Thinking…");
      setMood(ev.agent, "received");
      if (ev.trigger.kind === "handoff" && ev.trigger.from) glanceBetween(ev.trigger.from, ev.agent);
      if (current?.id === chatOf(job)) { $("suggest").hidden = true; attachLive(job); syncSend(); }
      break;
    }
    case "text": {
      const job = live.get(ev.job);
      if (!job) return;
      job.acc += ev.text;
      if (typeof Voice !== "undefined") Voice.onText(ev);
      if (!job.started || job.toolOn) { job.started = true; job.toolOn = false; setMood(ev.agent, "writing"); allFaces(ev.agent, (f) => f.tool(null)); setStatus(ev.agent, "Writing…"); }
      if (job.ui && current?.id === chatOf(job)) {
        if (job.ui.status.isConnected) { job.ui.status.replaceWith(job.ui.row); job.ui.face.stop(); }
        job.ui.reply.innerHTML = Md.render(job.acc);
        scrollDown();
      }
      break;
    }
    case "tool": {
      const job = live.get(ev.job);
      if (!job) return;
      job.statusText = TALK_TOOLS.has(ev.name) ? "Talking with another agent" : ev.name === "helper" ? "Sending out helpers" : toolPhrase(ev.name);
      if (TALK_TOOLS.has(ev.name)) job.talked = true;
      setMood(ev.agent, "working");
      job.toolOn = true;
      allFaces(ev.agent, (f) => f.tool(ev.name));
      if (job.ui) job.ui.face.tool?.(ev.name);
      setStatus(ev.agent, job.statusText + "…");
      if (job.ui) { job.ui.text.textContent = job.statusText; job.ui.face.setMood("working"); }
      break;
    }
    case "asked": {
      approvals.push(ev.approval);
      renderNeeds();
      renderRoster();
      setMood(ev.approval.agent, "waiting");
      if (current?.id === ev.approval.agent && view === "chat") { $("log").append(approvalCard(ev.approval)); scrollDown(true); }
      refreshDesk();
      break;
    }
    case "helper": {
      const job = live.get(ev.job);
      if (!job) return;
      (job.helpers ??= new Map()).set(ev.n, ev);
      if (ev.state === "working" || ev.state === "waiting") { job.statusText = "Working with helpers"; setStatus(ev.agent, "Working with helpers…"); if (job.ui?.status) job.ui.text.textContent = job.statusText; }
      if (job.ui && current?.id === ev.agent && view === "chat") { placeHelpers(job).set(ev.n, ev.task, ev.state, ev.note); scrollDown(); }
      break;
    }
    case "board": onBoardChanged(ev.id); break;
    case "chat_changed": {
      // An answer from an agent brought in with @ was kept: redraw from the record.
      if (current?.id === ev.agent && view === "chat") {
        const r = agentById(ev.agent);
        call("history", { id: ev.agent }).then((lines) => { if (current?.id === ev.agent && view === "chat") { renderLog(r, lines); scrollDown(true); renderDesk(r.id); } }).catch(() => {});
      }
      break;
    }
    case "question": onQuestion(ev.question); break;
    case "todos": onTodos(ev); break;
    case "learned": onLearned(ev); break;
    case "answered": {
      if (onQuestionAnswered(ev)) break;
      const was = approvals.find((a) => a.id === ev.id);
      // A yes to something that goes out into the world: a small celebration, in its colours.
      if (ev.yes && was && was.effect === "outbound") allFaces(was.agent, (f) => f.celebrate());
      approvals = approvals.filter((a) => a.id !== ev.id);
      document.querySelectorAll(`[data-approval="${ev.id}"]`).forEach((c) => {
        c.replaceWith(event([ev.yes ? "Approved" : ev.by === "stopped" ? "No longer needed" : "Denied", ev.by === "telegram" ? " from your phone" : ""]));
      });
      renderNeeds();
      renderRoster();
      if (ev.agent && busy.has(ev.agent)) setMood(ev.agent, "working");
      break;
    }
    case "would": {
      if (current?.id === ev.agent && view === "chat") $("log").append(event([icon("shield"), "Would have: ", strong(toolPhrase(ev.tool)), " (recorded, not done)"], "ask"));
      break;
    }
    case "steered": {
      if (current?.id === ev.agent && view === "chat") $("log").append(event([icon("sparkle"), strong(agentById(ev.agent)?.name ?? ""), " took in what you added"]));
      break;
    }
    case "job_finished": {
      const job = live.get(ev.job);
      if (typeof Voice !== "undefined") Voice.onDone(ev, job);
      if (!job) { if (profileOpenFor(ev.agent)) refreshProfile(); return; }
      live.delete(ev.job);
      busy.delete(ev.agent);
      allFaces(ev.agent, (f) => f.tool(null));
      if (ev.status === "failed") setTimeout(() => allFaces(ev.agent, (f) => f.error()), 60);
      // A routine reporting in: a hop, so a morning of reports reads as a standup down the list.
      if (job.trigger?.kind === "routine" && ev.status === "done") setTimeout(() => allFaces(ev.agent, (f) => f.perk()), 900);
      setStatus(ev.agent, null);
      const here = current?.id === ev.agent && view === "chat";
      if (job.ui) {
        job.ui.face.stop();
        job.ui.status.remove();
        if (ev.status === "done" && job.acc) {
          hydrateMd(job.ui.reply, ev.agent);
          job.ui.row.append(actions(job.acc));
          // Pages it made that the answer didn't already show.
          const shown = new Set([...job.ui.reply.querySelectorAll(".page-card .page-name")].map((n) => n.textContent));
          const fresh = (ev.made || []).filter((p) => ![...shown].some((s) => p.endsWith(s)));
          if (fresh.length && chatOf(job) === ev.agent) job.ui.row.after(documentsLine(ev.agent, fresh));
        }
        else job.ui.row.remove();
      }
      if (here) {
        if (ev.status === "done" && !job.acc && ev.answer) $("log").append(line({ from: "agent", text: ev.answer }));
        if (ev.status === "stopped") $("log").append(event(["You stopped ", strong(agentById(ev.agent)?.name ?? "it")]));
        if (ev.status === "failed") $("log").append(event([ev.error ?? "It hit a problem."], "error"));
        scrollDown();
        syncSend();
        // It talked with another agent: redraw from the record so the conversation sits where it happened.
        if ((job.talked && ev.status === "done") || job.inbound) {
          const r = agentById(ev.agent);
          call("history", { id: ev.agent }).then((lines) => { if (current?.id === ev.agent && view === "chat") { renderLog(r, lines); scrollDown(true); } }).catch(() => {});
        }
      }
      const seen = here && document.visibilityState === "visible";
      (seen ? call("mark_read", { id: ev.agent }).catch(() => {}) : Promise.resolve())
        .then(loadRoster)
        .then(() => setMood(ev.agent, ev.status === "done" && job.started ? "done" : "idle"));
      if (profileOpenFor(ev.agent)) refreshProfile();
      refreshMade(ev.agent);
      break;
    }
    case "notice": {
      const visible = document.visibilityState === "visible" && document.hasFocus();
      const fromNet = ev.agent === "network";
      if (visible && !(current?.id === ev.agent && view === "chat")) toast(ev.title, ev.body, "", () => (fromNet ? openNetwork() : openAgent(ev.agent)), fromNet ? undefined : ev.agent);
      notices.unshift({ ...ev, at: Date.now() });
      notices.splice(30);
      refreshDesk();
      break;
    }
    case "roster_changed": loadRoster(); loadAddresses(); break;
    case "routines_changed": if (profileOpenFor(current?.id) && profileTab === "skills") refreshProfile(); refreshDesk(); break;
    case "retro": if (current?.id === "cookie") refreshDesk(); break;
    case "evolved": if (profileOpenFor(ev.agent)) refreshProfile(); break;
    case "workspace": refreshWorkspace(ev.agent); break;
    case "worlds": refreshWall(); if (profileOpenFor(current?.id) && profileTab === "computer") refreshProfile(); break;
    case "test_progress":
    case "test_finished": if (profileOpenFor(ev.agent) && profileTab === "evolution") refreshProfile(); if (ev.kind === "test_finished") toast("Tests finished", `${ev.passed} of ${ev.total} passed`, ev.passed === ev.total ? "good" : "", () => { openAgent(ev.agent).then(() => openProfile("tests")); }); break;
    case "channel":
      if ($("settings").open) refreshSettings();
      if (String(ev.name).startsWith("slack:") && profileTab === "slack") refreshProfile();
      break;
    case "enkeon_changed": onEnkeonChanged(); break;
    case "network": onNetworkEvent(ev.what); if (ev.what === "contacts") loadAddresses(); break;
  }
}
const notices = [];

/* ---------- sending ---------- */
// The send button: ↑ sends (or, while the agent works, adds to its job); ■ stops it.
// Empty and idle it is the voice button (talk with the agent); while dictating, ↑ sends what you said.
function syncSend() {
  const working = current && busy.has(current.id);
  const has = !!$("input").value.trim();
  const dictating = document.body.classList.contains("dictating");
  const stopMode = working && !has && !dictating;
  const voiceMode = !working && !has && !dictating;
  const s = $("send");
  s.classList.toggle("stop", stopMode);
  s.classList.toggle("voice", voiceMode);
  const label = stopMode ? "Stop" : voiceMode ? (current ? `Talk with ${current.name}` : "Talk") : working ? "Add to what it is doing" : "Send";
  s.setAttribute("aria-label", label);
  s.title = label;
  s.disabled = !current;
  if (current && !dictating) $("input").placeholder = working ? `Add to what ${current.name} is doing…` : `Message ${current.name}`;
}

function autosize() {
  const t = $("input");
  t.style.height = "auto";
  t.style.height = Math.min(t.scrollHeight, 220) + "px";
}

$("input").addEventListener("input", () => { autosize(); syncSend(); atSuggest(); });

/* ---------- @addresses in the composer ---------- */
// Type @ and pick: your agents (@writing-desk) and your contacts (@bob/sales).
// The agent you're talking to writes to them with its `message` tool.
let addressBook = [], atPick = 0, atOpen = false;
async function loadAddresses() { try { addressBook = await call("addresses"); } catch { addressBook = []; } }

function atToken() {
  const ta = $("input");
  const upto = ta.value.slice(0, ta.selectionStart);
  const m = upto.match(/(^|\s)(@[a-z0-9\-/]*)$/i);
  return m ? { start: upto.length - m[2].length, text: m[2].toLowerCase() } : null;
}

function atSuggest() {
  const menu = $("at-menu");
  const tok = atToken();
  const hits = tok ? addressBook.filter((a) => a.id !== current?.id && (a.address.includes(tok.text) || a.name.toLowerCase().includes(tok.text.slice(1)))).slice(0, 8) : [];
  atOpen = hits.length > 0;
  menu.hidden = !atOpen;
  if (!atOpen) return;
  atPick = Math.min(atPick, hits.length - 1);
  menu.replaceChildren(...hits.map((a, i) => {
    const b = el("button", "at-item" + (i === atPick ? " on" : ""));
    b.type = "button";
    b.setAttribute("role", "option");
    b.setAttribute("aria-selected", String(i === atPick));
    const t = el("div", "row-text");
    t.append(el("span", null, a.name), el("small", null, a.kind === "team" ? `${a.address} · your agent` : `${a.address} · ${a.job || "on the network"}`));
    b.append(Faces.create(a.id, 24).el, t);
    b.onmousedown = (e) => { e.preventDefault(); atInsert(a); };
    return b;
  }));
  menu.dataset.hits = JSON.stringify(hits.map((h) => h.address));
}

function atInsert(a) {
  const ta = $("input");
  const tok = atToken();
  if (!tok) return;
  ta.value = ta.value.slice(0, tok.start) + a.address + " " + ta.value.slice(ta.selectionStart);
  const caret = tok.start + a.address.length + 1;
  ta.setSelectionRange(caret, caret);
  $("at-menu").hidden = true; atOpen = false; atPick = 0;
  autosize(); syncSend(); ta.focus();
}

// Before the composer's own keys: while the list is open, arrows move and Enter picks.
$("input").addEventListener("keydown", (e) => {
  if (!atOpen) return;
  const hits = JSON.parse($("at-menu").dataset.hits || "[]");
  if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); e.stopImmediatePropagation(); atPick = (atPick + (e.key === "ArrowDown" ? 1 : hits.length - 1)) % hits.length; atSuggest(); }
  else if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); e.stopImmediatePropagation(); const a = addressBook.find((x) => x.address === hits[atPick]); if (a) atInsert(a); }
  else if (e.key === "Escape") { e.preventDefault(); e.stopImmediatePropagation(); $("at-menu").hidden = true; atOpen = false; }
}, true);
$("input").addEventListener("blur", () => setTimeout(() => { $("at-menu").hidden = true; atOpen = false; }, 120));
$("input").addEventListener("keydown", (e) => {
  if (e.key === "ArrowUp" && !$("input").value) {
    const mine = [...$("log").querySelectorAll(".msg.you .bubble")].pop();
    if (mine) { e.preventDefault(); $("input").value = mine.textContent; autosize(); syncSend(); }
    return;
  }
  if (e.key !== "Enter" || e.shiftKey || e.isComposing) return;
  const cmd = prefs.get("cmdEnter", false);
  if (!cmd || e.metaKey || e.ctrlKey) { e.preventDefault(); $("composer").requestSubmit(); }
});

$("composer").onsubmit = async (e) => {
  e.preventDefault();
  if (!current) return;
  if (typeof Voice !== "undefined") {
    if (Voice.dictating()) { Voice.finishDictation(true); return; }
    if (e.submitter === $("send") && $("send").classList.contains("voice")) { Voice.startCall(); return; }
  }
  const agent = current;
  const text = $("input").value.trim();
  // Naming another of your agents brings it in to answer here, even while this one works.
  const naming = [...text.matchAll(/(?:^|[^\w.])@([a-z0-9][a-z0-9-]*)(?![\w/-])/gi)].some((m) => addressBook.some((x) => x.kind === "team" && x.id !== agent.id && x.address.toLowerCase() === "@" + m[1].toLowerCase()));
  if (busy.has(agent.id) && !naming) {
    if (!text) { await call("stop", { id: agent.id }); return; }
    // Mid-job: the words join the job in flight instead of starting a new one.
    if (await call("steer", { id: agent.id, text })) {
      $("input").value = ""; autosize(); drafts.delete(agent.id);
      const you = line({ from: "you", text });
      you.querySelector(".bubble").classList.add("steer");
      const statusRow = $("log").querySelector(".status");
      statusRow ? statusRow.before(you) : $("log").append(you);
      scrollDown(true);
      syncSend();
      return;
    }
  }
  if (!text && !pending.length) return;
  if (pending.some((f) => f.card?.busy)) { toast("Still getting a file ready", "Send again in a moment.", ""); return; }
  // Named with @: each agent named hops, wherever its face is.
  for (const m of text.matchAll(/@([a-z0-9][a-z0-9-]*)(?![\w/-])/gi)) {
    const hit = addressBook.find((x) => x.kind === "team" && x.address.toLowerCase() === "@" + m[1].toLowerCase());
    if (hit) allFaces(hit.id, (f) => f.perk());
  }
  $("suggest").hidden = true;
  drafts.delete(agent.id);
  const files = pending;
  pending = [];
  renderChips();
  $("input").value = "";
  autosize();
  $("log").append(line({ from: "you", text }));
  for (const f of files) $("log").append(line({ from: "file", text: f.card?.label ? `${f.name} · ${f.card.label}` : f.name, image: f.card?.thumb || (f.data ? `data:${f.media_type};base64,${f.data}` : undefined) }));
  scrollDown(true);
  try {
    await call("send", { id: agent.id, text: text || (files.length === 1 ? `Here's ${files[0].name}.` : `Here are ${files.length} files.`), attachments: files.flatMap((f) => f.attachments ?? [f]) });
  } catch (err) {
    $("log").append(event([String(err)], "error"));
    scrollDown(true);
  }
  syncSend();
};

/* ---------- attachments ---------- */
const IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"];
// The + menu: any file (Cookie sorts out each kind itself), a whole folder, and apps.
function attachMenu() {
  const old = document.querySelector(".attach-menu");
  if (old) { old.remove(); return; }
  const m = el("div", "pop attach-menu");
  m.setAttribute("role", "menu");
  const item = (ic, label, side, run) => {
    const b = el("button");
    b.type = "button";
    b.setAttribute("role", "menuitem");
    b.append(icon(ic), el("span", "am-label", label));
    if (side) b.append(side);
    b.onclick = () => { m.remove(); run(); };
    m.append(b);
    return b;
  };
  item("clip", "Add files or photos", el("kbd", "am-key", "⌘U"), pickAndAttach);
  item("folder", "Add folder", null, addFolder);
  const note = el("span", "am-side");
  const chev = icon("up"); chev.classList.add("am-chev");
  const side = el("span", "am-right"); side.append(note, chev);
  item("plug", "Connect apps", side, () => openConnect());
  call("apps").then((st) => {
    const n = (st?.apps || []).filter((x) => x.state === "reconnect" || x.state === "failed").length;
    if (n) note.textContent = `${n} need${n === 1 ? "s" : ""} attention`;
  }).catch(() => {});
  ($("attach").closest(".composer") ?? document.body).append(m);
  const away = (e) => { if (!m.contains(e.target) && !$("attach").contains(e.target)) { m.remove(); document.removeEventListener("mousedown", away); } };
  setTimeout(() => document.addEventListener("mousedown", away), 0);
  m.addEventListener("keydown", (e) => {
    const items = [...m.querySelectorAll("button")];
    const i = items.indexOf(document.activeElement);
    if (e.key === "Escape") { m.remove(); $("attach").focus(); }
    else if (e.key === "ArrowDown") { e.preventDefault(); items[(i + 1) % items.length].focus(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
  });
  m.querySelector("button")?.focus();
}
async function pickAndAttach() {
  const paths = await Api.pickFiles(null).catch((e) => { toast("Couldn't open the chooser", String(e), "error"); return []; });
  if (paths === null) return $("file").click(); // a browser: its own chooser
  if (paths.length) await attachPaths(paths);
}
/** A whole folder: the real one is shared with agents (nothing copied), shown as a chip. */
async function addFolder() {
  const agent = current;
  if (!agent) return;
  const path = await Api.pickFolder().catch(() => null);
  if (!path) return;
  try {
    const r = await call("add_folder", { agent: agent.id, path });
    agent.grants = { ...(agent.grants || {}), files: true };
    const words = `${r.files >= 20000 ? "20,000+" : r.files.toLocaleString()} file${r.files === 1 ? "" : "s"}`;
    pending.push({ name: r.name, card: { name: r.name, label: `Folder · ${words}`, folder: true }, attachments: [{ name: r.name, text: `The folder ${r.path} (${words}) is shared with you now: list, search and read it with mac_files_list, mac_files_search and mac_files_read (full paths under ${r.path}). Changing a file there asks the person first.` }] });
    renderChips();
    syncSend();
    $("input").focus();
  } catch (e) { toast("Couldn't add that folder", String(e), "error"); }
}
$("attach").onclick = attachMenu;

/** A card while a file is prepared, replaced by the real one (or dropped on failure). */
function preparing(name) {
  const p = { name, card: { name, label: "Getting it ready…", busy: true }, attachments: [] };
  pending.push(p);
  renderChips();
  return p;
}
function prepared(slot, r) {
  const i = pending.indexOf(slot);
  if (i < 0) return;
  if (!r) pending.splice(i, 1);
  else pending[i] = { name: r.card.name, card: r.card, attachments: r.attachments };
  renderChips();
  syncSend();
}
async function attachPaths(paths) {
  const agent = current;
  if (!agent) return;
  const slots = paths.map((p) => preparing(p.split("/").pop()));
  try {
    const out = await call("attach_paths", { agent: agent.id, paths });
    slots.forEach((slot, i) => prepared(slot, out[i]));
  } catch (e) {
    slots.forEach((slot) => prepared(slot, null));
    toast("Couldn't add that", String(e), "error");
  }
  $("input").focus();
}
async function addFiles(list) {
  const agent = current;
  if (!agent) return;
  for (const file of list) {
    if (file.size > 200_000_000) { toast(`${file.name} is over 200 MB`, "Add a big file with the + button instead: it's copied straight from disk.", "error"); continue; }
    const slot = preparing(file.name);
    try {
      const data = await new Promise((ok, no) => { const r = new FileReader(); r.onload = () => ok(String(r.result).split(",")[1] ?? ""); r.onerror = no; r.readAsDataURL(file); });
      prepared(slot, await call("attach_bytes", { agent: agent.id, name: file.name || "pasted.png", data }));
    } catch (e) {
      prepared(slot, null);
      toast(`Couldn't add ${file.name}`, String(e), "error");
    }
  }
  $("input").focus();
}
$("file").onchange = async () => { await addFiles($("file").files); $("file").value = ""; };
$("input").addEventListener("paste", (e) => { if (e.clipboardData?.files?.length) { e.preventDefault(); addFiles(e.clipboardData.files); } });
let dragDepth = 0;
$("chat").addEventListener("dragenter", (e) => { if (e.dataTransfer?.types?.includes("Files")) { dragDepth++; $("drop").hidden = false; } });
$("chat").addEventListener("dragleave", () => { if (--dragDepth <= 0) { dragDepth = 0; $("drop").hidden = true; } });
$("chat").addEventListener("dragover", (e) => e.preventDefault());
$("chat").addEventListener("drop", (e) => { e.preventDefault(); dragDepth = 0; $("drop").hidden = true; if (e.dataTransfer?.files?.length) addFiles(e.dataTransfer.files); });

function renderChips() {
  $("chips").hidden = pending.length === 0;
  $("chips").replaceChildren(...pending.map((f, i) => {
    const c = el("span", "chip" + (f.card?.busy ? " busy" : ""));
    const thumb = f.card?.thumb || (f.data ? `data:${f.media_type};base64,${f.data}` : null);
    if (thumb) { const t = el("img", "chip-thumb"); t.src = thumb; t.alt = ""; c.append(t); }
    else if (f.card?.folder) { const fi = icon("folder"); fi.classList.add("chip-ic"); c.append(fi); }
    const words = el("span", "chip-words");
    words.append(el("span", "chip-name", f.name));
    if (f.card?.label) words.append(el("small", "chip-kind", f.card.size && !f.card.busy ? `${f.card.label} · ${f.card.size}` : f.card.label));
    c.append(words);
    const x = el("button");
    x.type = "button";
    x.setAttribute("aria-label", `Remove ${f.name}`);
    x.append(icon("x"));
    x.onclick = () => { pending.splice(i, 1); renderChips(); syncSend(); };
    c.append(x);
    return c;
  }));
}

/* ---------- hire ---------- */
/* ---------- hire: faces doing tricks; pick one, hire it ---------- */
// Each face loops its own tricks. A 2D body never turns like a card: it jumps (a crouch,
// a stretch up, a squash on landing), its face rolls round it mid-air, and a shadow on
// the ground shrinks as it rises. Cartwheels and twirls turn in the picture's own plane.
// Tricks happen in the face's own 3D: a real jump (its shadow stays on the table), a roll
// round any axis, and an effect round it. [jump height (share of size), ms, roll, effects]
const TRICKS = {
  frontflip: [0.46, 980, "front", ["swoosh"]],
  backflip: [0.46, 980, "back", ["swoosh"]],
  doubleflip: [0.7, 1300, "double", ["fire", "sparkle@0.9"]],
  spin: [0.26, 860, "spin", ["wind"]],
  tornado: [0.4, 1100, "spin2", ["wind"]],
  corkscrew: [0.52, 1150, "corkscrew", ["wind", "sparkle@0.9"]],
  blaze: [0.18, 1100, null, ["fire"]],
  levitate: [0.55, 1700, "spin", ["stardust"]],
  zap: [0.12, 900, null, ["zap"]],
  supernova: [0.62, 1400, "spin2", ["stardust", "wind", "sparkle@0.88"]],
  hops: null,
  jelly: null,
  moonwalk: null,
};
const TRICK_NAMES = Object.keys(TRICKS);
const noMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
let crew = [], picked = null, crewTimers = [];

function trick(c, name) {
  if (noMotion || c.busy) return;
  const n = name ?? TRICK_NAMES.filter((t) => t !== c.last)[Math.floor(Math.random() * (TRICK_NAMES.length - 1))];
  c.last = n; c.busy = true;
  const f = c.face;
  let ms;
  if (TRICKS[n]) {
    const [h, dur, roll, effects] = TRICKS[n];
    ms = dur;
    // Effects start with the take-off; "name@0.9" starts at 90% of the trick (a landing sparkle).
    for (const e of effects) {
      const [kind, at] = e.split("@");
      if (at) setTimeout(() => f.fx(kind), dur * Number(at));
      else f.fx(kind, n === "blaze" ? dur : dur * 0.85);
    }
    if (n === "blaze") setTimeout(() => f.jump(h, 520), 380);
    else if (n === "zap") { f.error(); setTimeout(() => f.jelly(), 500); }
    else f.jump(h, dur);
    // The body rolls while it's in the air: after the take-off, done before the landing.
    if (roll) setTimeout(() => f.flip(roll, dur * 0.6), dur * 0.2);
    else f.perk();
  } else if (n === "hops") {
    ms = 1150;
    [[0.3, 380, 0], [0.22, 340, 400], [0.14, 300, 760]].forEach(([h, d, at]) => setTimeout(() => f.jump(h, d), at));
  } else if (n === "jelly") {
    ms = 900; f.jelly();
  } else {
    // A moonwalk: it slides back along the table (shadow and all), glancing behind.
    ms = 1200;
    c.acro.animate([{ transform: "translateX(0)" }, { transform: "translateX(-18%)", offset: 0.3 }, { transform: "translateX(-28%)", offset: 0.5 }, { transform: "translateX(-8%)", offset: 0.75 }, { transform: "translateX(0)" }], { duration: ms, easing: "cubic-bezier(.34,.12,.3,1)" });
    const r = f.rect(); f.glanceAt(r.right + 200, r.top + r.height / 2, 700);
  }
  setTimeout(() => {
    c.busy = false;
    if (Math.random() < 0.35) f.setMood("done");
  }, ms);
}

// One face per role for this session: come back and the one you liked is still there.
const crewIds = new Map();
const slugOf = (name) => name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40) || "agent";
function slugId(name, shape) {
  if (crewIds.has(name)) return crewIds.get(name);
  const id = Faces.idFor(slugOf(name), shape);
  crewIds.set(name, id);
  return id;
}
let lookFaces = [];

function stopCrew() {
  crewTimers.forEach(clearTimeout); crewTimers = [];
  crew.forEach((c) => c.face?.stop());
  crew = [];
  lookFaces.forEach((f) => f.stop()); lookFaces = [];
  $("hire-looks")?.setAttribute("hidden", "");
}

function renderStarters() {
  stopCrew();
  // The whole crew, always: one you already have shows its own face, marked Hired.
  const have = new Map(rows.map((r) => [r.name.toLowerCase(), r]));
  const cards = STARTERS.map((s) => {
    const hired = have.get(s.name.toLowerCase()) ?? null;
    const id = hired ? hired.id : slugId(s.name, s.shape);
    const face = Faces.create(id, 108, undefined, { view: 2.5 });
    return { ...s, id, face, hired };
  });
  cards.push({ own: true, name: "Your own" });
  $("starter-list").replaceChildren(...cards.map((c, i) => {
    const li = el("li");
    const b = el("button", "crew-card" + (c.own ? " own" : "") + (c.hired ? " hired" : ""));
    b.type = "button";
    b.setAttribute("role", "option");
    b.setAttribute("aria-selected", "false");
    const acro = el("span", "acro");
    if (c.own) { const plus = el("span", "plus-face"); plus.append(icon("plus")); acro.append(plus); }
    else acro.append(c.face.el);
    const stage = el("span", "acro-stage");
    stage.append(acro);
    b.append(stage, el("span", "crew-name", c.name));
    if (c.hired) b.append(el("span", "crew-tag", "Hired"));
    c.card = b; c.acro = acro;
    b.onmouseenter = () => !c.own && trick(c);
    b.onclick = () => (c.hired ? (stopCrew(), openAgent(c.hired.id)) : pick(c));
    b.ondblclick = () => !c.own && !c.hired && hireNow();
    li.append(b);
    // Its own rhythm: a first trick soon, then one every few seconds.
    if (!c.own) {
      const loop = () => { trick(c); crewTimers.push(setTimeout(loop, 2600 + Math.random() * 3800)); };
      crewTimers.push(setTimeout(loop, 500 + i * 380 + Math.random() * 900));
    }
    return li;
  }));
  crew = cards;
}

function pick(c) {
  picked = c;
  for (const x of crew) { x.card.classList.toggle("on", x === c); x.card.setAttribute("aria-selected", String(x === c)); }
  $("hire-form").hidden = !c.own || false;
  if (c.own) { $("hire-form").hidden = false; $("hire-form").name.focus(); }
  else { $("hire-form").hidden = true; trick(c, "doubleflip"); setTimeout(() => c.face.celebrate?.(), 650); }
  showLooks(c);
  syncHireBtn();
}

// Pick a look: one option in every shape (new colours on "More"). The face picked is the
// face hired, because a face is drawn from the id it's hired with.
function showLooks(c) {
  let box = $("hire-looks");
  if (!box) { box = el("div", "hire-looks"); box.id = "hire-looks"; $("hire-form").before(box); }
  lookFaces.forEach((f) => f.stop()); lookFaces = [];
  const slug = c.own ? "agent" : slugOf(c.name);
  const row = el("div", "looks");
  row.setAttribute("role", "listbox");
  row.setAttribute("aria-label", "Looks");
  for (const shape of Faces.shapes) {
    const id = c.id && Faces.look(c.id).shape === shape && !c.own ? c.id : Faces.idFor(slug, shape);
    const b = el("button", "look" + (id === c.id ? " on" : ""));
    b.type = "button";
    b.title = shape[0].toUpperCase() + shape.slice(1);
    b.setAttribute("aria-label", b.title);
    const f = Faces.create(id, 50);
    lookFaces.push(f);
    b.append(f.el);
    b.onmouseenter = () => f.perk();
    b.onclick = () => setLook(c, id, b);
    row.append(b);
  }
  const more = el("button", "btn quiet looks-more", "More colours");
  more.type = "button";
  more.onclick = () => showLooks(c);
  box.replaceChildren(el("p", "looks-title", "Pick a look"), row, more);
  box.hidden = false;
}

function setLook(c, id, b) {
  for (const x of b.parentNode.children) x.classList.toggle("on", x === b);
  c.id = id;
  if (!c.own) crewIds.set(c.name, id);
  c.face?.stop();
  c.face = Faces.create(id, 108, undefined, { view: 2.5 });
  c.acro.replaceChildren(c.face.el);
  c.busy = false;
  trick(c, "supernova");
}

function syncHireBtn() {
  const f = $("hire-form");
  const ready = picked && (!picked.own || (f.name.value.trim() && f.job.value.trim()));
  $("hire-btn").disabled = !ready;
  $("hire-btn").textContent = picked && !picked.own ? `Hire ${picked.name}` : picked?.own && f.name.value.trim() ? `Hire ${f.name.value.trim()}` : "Hire";
}

function defaultModel() {
  return localStorage.getItem("cookie.lastModel") || rows.find((r) => r.id !== "cookie")?.model || rows[0]?.model || suggestions()[0] || "";
}

async function openHire(prefill) {
  current = null;
  renderModelChip();
  closePops();
  show("hire");
  renderRoster();
  picked = null;
  const form = $("hire-form");
  form.reset();
  form.hidden = true;
  form.model.value = defaultModel();
  // The model only asks to be chosen when there's none to use.
  form.model.hidden = !!form.model.value;
  $("hire-error").hidden = true;
  $("hire-cancel").hidden = rows.length === 0;
  $("hire-title").textContent = rows.filter((r) => r.id !== "cookie").length ? "Hire" : "Build your team";
  renderStarters();
  const [handovers, archives] = await Promise.all([call("handovers").catch(() => []), call("archives").catch(() => [])]);
  form.handover.hidden = handovers.length + archives.length === 0;
  // A retired agent's archive brings its lessons, skills, tests and habits with its handover note.
  const learned = archives.map((a) => { const o = el("option", null, `Everything ${a.name} learned (${a.lessons} lessons, ${a.skills} skills)`); o.value = "archive:" + a.id; return o; });
  form.handover.replaceChildren(el("option", null, "Start fresh"), ...learned, ...handovers.map((h) => { const o = el("option", null, h.title); o.value = h.file; return o; }));
  form.handover.options[0].value = "";
  if (prefill) {
    const own = crew.find((c) => c.own);
    pick(own);
    form.name.value = prefill.name; form.job.value = prefill.job;
    syncHireBtn();
  }
  syncHireBtn();
  $("hire").scrollTop = 0;
}

function suggestions() {
  return providers.flatMap((p) => MODELS[p] || []);
}

$("hire-form").addEventListener("input", syncHireBtn);
$("hire-form").onsubmit = (e) => { e.preventDefault(); hireNow(); };

async function hireNow() {
  if (!picked) return;
  const form = $("hire-form");
  const model = form.model.value.trim() || defaultModel();
  $("hire-error").hidden = true;
  if (!model) { form.hidden = false; form.model.hidden = false; form.model.focus(); $("hire-error").textContent = "Add a model key in Settings → Models first."; $("hire-error").hidden = false; return; }
  const hire = picked.own
    ? (form.handover.value.startsWith("archive:")
        ? { name: form.name.value, job: form.job.value, model, inherit: form.handover.value.slice("archive:".length) }
        : { name: form.name.value, job: form.job.value, model, handover: form.handover.value || null })
    : { name: picked.name, job: picked.job, model, id: picked.id, template: picked.template ?? null };
  // A look picked for your own agent comes with it.
  if (picked.own && picked.id) hire.id = picked.id;
  $("hire-btn").disabled = true;
  try {
    const agent = await call("hire_agent", { hire });
    crewIds.delete(hire.name);
    try { localStorage.setItem("cookie.lastModel", agent.model); } catch {}
    stopCrew();
    await loadRoster();
    openAgent(agent.id);
    setTimeout(() => allFaces(agent.id, (f) => f.celebrate()), 400);
  } catch (err) {
    $("hire-error").textContent = String(err);
    $("hire-error").hidden = false;
    syncHireBtn();
  }
}

$("hire-btn").onclick = hireNow;
$("hire-cancel").onclick = () => { stopCrew(); rows.length && openAgent(rows[0].id); };
$("new-agent").onclick = () => openHire();

/* ---------- fire ---------- */
async function fireCurrent(agent) {
  closePops();
  const a = agent?.id ? agent : current;
  if (!a) return;
  const d = $("fire-dialog");
  $("fire-title").textContent = `Fire ${a.name}?`;
  $("fire-handover").checked = !!a.last;
  $("fire-handover-row").hidden = !a.last;
  d.showModal();
  $("fire-go").onclick = async () => {
    $("fire-go").disabled = true;
    $("fire-go").textContent = $("fire-handover").checked ? "Writing its handover…" : "Firing…";
    try {
      const note = await call("fire_agent", { id: a.id, handover: $("fire-handover").checked });
      d.close();
      if (current?.id === a.id) { current = null; closeProfile(); }
      await loadRoster();
      if (note) toast(`${a.name} left a handover note`, "Pick it when you hire its successor.", "good");
      if (!current) rows.length ? openAgent(rows[0].id) : openHire();
    } catch (err) {
      toast("Couldn't fire it", String(err), "error");
    } finally {
      $("fire-go").disabled = false;
      $("fire-go").textContent = "Fire";
    }
  };
}
$("fire").onclick = () => fireCurrent();
$("fire-cancel").onclick = () => $("fire-dialog").close();

/* ---------- menus ---------- */
function closePops() {
  ["more-menu", "me-menu", "row-menu"].forEach((id) => { $(id).hidden = true; });
  $("me-btn").setAttribute("aria-expanded", "false");
}

document.addEventListener("click", (e) => {
  if (!e.target.closest(".pop, #more, #me-btn")) closePops();
});
// The rail is app chrome: no browser "Reload / Inspect Element" menu on it.
document.querySelector(".rail").addEventListener("contextmenu", (e) => { if (!e.target.closest("input, textarea")) e.preventDefault(); });
document.addEventListener("scroll", () => { if (!$("row-menu").hidden) closePops(); }, true);
window.addEventListener("blur", () => { if (!$("row-menu").hidden) closePops(); });

/* ---------- agent row menu (right-click) ---------- */
let showHidden = false;

function svgIcon(id, cls) {
  const s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  if (cls) s.setAttribute("class", cls);
  const u = document.createElementNS("http://www.w3.org/2000/svg", "use");
  u.setAttribute("href", "#" + id);
  s.append(u);
  return s;
}

async function arrange(id, patch) {
  try { await call("arrange", { id, patch }); await loadRoster(); }
  catch (err) { toast("Couldn't change the sidebar", String(err), "error"); }
}

function openRowMenu(id, x, y) {
  const r = agentById(id);
  if (!r) return;
  closePops();
  const m = $("row-menu");
  const item = (icon, label, fn, cls) => {
    const b = el("button", cls ?? null);
    b.setAttribute("role", "menuitem");
    b.append(svgIcon(icon), el("span", null, label));
    b.onclick = (e) => { e.stopPropagation(); closePops(); fn(); };
    return b;
  };
  const parts = [
    item("i-pin", r.pinned ? "Unpin" : "Pin", () => arrange(id, { pinned: !r.pinned })),
    item("i-section", r.section ? "Move to another section" : "Move to new section", () => sectionPrompt(r)),
  ];
  if (r.section) parts.push(item("i-x", `Take out of "${r.section}"`, () => arrange(id, { section: "" })));
  parts.push(
    r.unread > 0
      ? item("i-bell", "Mark as read", () => call("mark_read", { id }).then(loadRoster))
      : item("i-bell", "Mark as unread", () => arrange(id, { unread: true })),
    item("i-window", "New window", () => Api.openWindow(id, r.name).catch((err) => toast("Couldn't open a window", String(err), "error"))),
    el("hr"),
    item("i-copy", "Copy agent ID", async () => {
      try { await navigator.clipboard.writeText(id); toast("Agent ID copied", id, "good"); }
      catch { toast("Couldn't reach the clipboard", id, "error"); }
    }),
    el("hr"),
    item(r.hidden ? "i-eye" : "i-eyeoff", r.hidden ? "Show in sidebar" : "Hide from sidebar", () => arrange(id, { hidden: !r.hidden })),
    item("i-trash", "Delete", () => fireCurrent(r), "danger"),
  );
  m.replaceChildren(...parts);
  m.hidden = false;
  // Keep it on screen: flip up or left when it would spill over the edge.
  const w = m.offsetWidth, h = m.offsetHeight;
  m.style.left = Math.max(8, Math.min(x, innerWidth - w - 8)) + "px";
  m.style.top = Math.max(8, y + h > innerHeight - 8 ? y - h : y) + "px";
  m.querySelector("button")?.focus({ preventScroll: true });
}

/** "Move to new section": name it in place, or pick one that already exists. */
function sectionPrompt(r) {
  const m = $("row-menu");
  const names = [...new Set(rows.map((x) => x.section).filter(Boolean))].filter((n) => n !== r.section).sort();
  const input = el("input");
  input.placeholder = "Section name";
  input.maxLength = 40;
  input.setAttribute("aria-label", "Section name");
  const go = (name) => { if (name.trim()) { closePops(); arrange(r.id, { section: name.trim(), pinned: false }); } };
  input.onkeydown = (e) => { if (e.key === "Enter") go(input.value); if (e.key === "Escape") closePops(); };
  const parts = [el("div", "menu-title", `Move ${r.name} to`), input];
  for (const n of names) {
    const b = el("button");
    b.append(svgIcon("i-folder"), el("span", null, n));
    b.onclick = (e) => { e.stopPropagation(); go(n); };
    parts.push(b);
  }
  m.replaceChildren(...parts);
  m.hidden = false;
  if (m.getBoundingClientRect().bottom > innerHeight - 8) m.style.top = Math.max(8, innerHeight - m.offsetHeight - 8) + "px";
  input.focus();
}
$("row-menu").addEventListener("keydown", (e) => {
  const items = [...$("row-menu").querySelectorAll("button")];
  const i = items.indexOf(document.activeElement);
  if (e.key === "ArrowDown") { e.preventDefault(); items[(i + 1) % items.length]?.focus(); }
  if (e.key === "ArrowUp") { e.preventDefault(); items[(i - 1 + items.length) % items.length]?.focus(); }
  if (e.key === "Escape") closePops();
});
document.addEventListener("keydown", (e) => {
  const mod = e.metaKey || e.ctrlKey;
  if (e.key === "Escape" && !$("talk-view").hidden) { closeTalk(); return; }
  if (e.key === "Escape") closePops();
  if (mod && e.key === "n") { e.preventDefault(); openHire(); }
  if (mod && e.key === "f") { e.preventDefault(); toggleSearch(true); }
  if (mod && e.key === ",") { e.preventDefault(); openSettings("general"); }
  if (mod && (e.key === "u" || e.key === "U") && current && !document.querySelector("dialog[open]")) { e.preventDefault(); pickAndAttach(); }
  if (mod && e.key === "\\") { e.preventDefault(); toggleRail(); }
  if (mod && e.key === "t") { e.preventDefault(); openNextNeed(); }
  if (e.key === "Escape" && !$("doc-view").hidden && !document.querySelector("dialog[open]")) { e.preventDefault(); closePage(); return; }
});

$("more").onclick = () => { const open = $("more-menu").hidden; closePops(); $("more-menu").hidden = !open; };

$("copy-chat").onclick = async () => {
  closePops();
  const text = [...$("log").querySelectorAll(".msg")].map((m) => (m.classList.contains("you") ? "You: " : m.classList.contains("file") ? "File: " : `${current.name}: `) + m.querySelector(".bubble, .file-chip").innerText).join("\n\n");
  try { await navigator.clipboard.writeText(text); $("log").append(event(["Conversation copied"])); scrollDown(true); }
  catch { $("log").append(event(["Couldn't reach the clipboard."], "error")); }
};

/* ---------- account drop-up ---------- */
$("me-btn").onclick = () => {
  const open = $("me-menu").hidden;
  closePops();
  $("me-menu").hidden = !open;
  $("me-btn").setAttribute("aria-expanded", String(open));
};
$("apps-btn").onclick = () => openConnect();
$("apps-mini").onclick = () => openConnect();
$("new-agent-mini").onclick = () => openHire();
$("needs-chip").onclick = () => { needsOnly = !needsOnly; renderRoster(); renderNeeds(); };

/** ⌘T: the next agent that needs you, newest first. */
function openNextNeed() {
  sortRows();
  const next = rows.find((r) => needsOf(r.id).count > 0 && r.id !== current?.id) ?? rows.find((r) => needsOf(r.id).count > 0);
  if (next) openAgent(next.id); else toast("Nothing needs you", "Every agent is fine on its own right now.");
}
$("me-menu").onclick = async (e) => {
  const go = e.target.closest("[data-go]")?.dataset.go;
  if (!go) return;
  closePops();
  if (go === "expand") toggleRail();
  else if (go === "connect") openConnect();
  else if (go === "photo") changeMyPhoto();
  else if (go === "folder") Api.reveal(await call("data_dir")).catch((err) => toast("Can't open it here", String(err), "error"));
  else openSettings(go);
};

/* ---------- preferences (this window only) ---------- */
const prefs = (() => {
  let p = {};
  try { p = JSON.parse(localStorage.getItem("cookie.prefs") || "{}"); } catch {}
  return {
    get: (k, d) => (k in p ? p[k] : d),
    set: (k, v) => { p[k] = v; try { localStorage.setItem("cookie.prefs", JSON.stringify(p)); } catch {} applyPrefs(); },
  };
})();

function applyPrefs() {
  const theme = prefs.get("theme", "system");
  if (theme === "system") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.dataset.theme = theme;
  // Glass asks the window for real frosted glass; without it the page keeps a tinted stand-in.
  const glass = theme === "glass";
  const native = window.__TAURI__?.core?.invoke;
  if (native) native("set_glass", { on: glass }).then((on) => document.documentElement.classList.toggle("glass-native", !!on)).catch(() => document.documentElement.classList.remove("glass-native"));
  $("input").spellcheck = prefs.get("spell", true);
}

/* ---------- sheets ---------- */
document.querySelectorAll("dialog.sheet").forEach((d) => {
  d.querySelector("[data-close]")?.addEventListener("click", () => d.close());
  d.addEventListener("click", (e) => { if (e.target === d) d.close(); });
});

/* ---------- sidebar: drag to resize, collapse to faces ---------- */
const RAIL = { min: 210, max: 420, collapsed: 96, snap: 170 };
function setRail(w, save = true) {
  const collapsed = w < RAIL.snap;
  const width = collapsed ? RAIL.collapsed : Math.min(RAIL.max, Math.max(RAIL.min, w));
  document.body.style.setProperty("--rail-w", width + "px");
  document.body.classList.toggle("rail-collapsed", collapsed);
  if (collapsed) { $("search-wrap").hidden = true; closePops(); }
  if (save) try { localStorage.setItem("cookie.rail", String(width)); if (!collapsed) localStorage.setItem("cookie.railOpen", String(width)); } catch {}
}
function toggleRail() {
  const collapsed = document.body.classList.contains("rail-collapsed");
  let open = 272;
  try { open = +localStorage.getItem("cookie.railOpen") || 272; } catch {}
  setRail(collapsed ? open : 0);
}
$("rail-resize").ondblclick = toggleRail;
$("rail-resize").onpointerdown = (e) => {
  e.preventDefault();
  const h = $("rail-resize");
  h.setPointerCapture(e.pointerId);
  document.body.classList.add("resizing");
  h.onpointermove = (m) => setRail(m.clientX, false);
  h.onpointerup = (u) => {
    h.onpointermove = h.onpointerup = null;
    document.body.classList.remove("resizing");
    setRail(u.clientX);
  };
};
$("rail-resize").onkeydown = (e) => {
  const w = parseInt(getComputedStyle(document.body).getPropertyValue("--rail-w")) || 272;
  if (e.key === "ArrowLeft") setRail(w <= RAIL.min ? 0 : w - 16);
  if (e.key === "ArrowRight") setRail(w <= RAIL.collapsed ? RAIL.min : w + 16);
};
try { setRail(+localStorage.getItem("cookie.rail") || 272, false); } catch { setRail(272, false); }

/* ---------- search ---------- */
function toggleSearch(force) {
  const wrap = $("search-wrap");
  const open = force ?? wrap.hidden;
  wrap.hidden = !open;
  if (open) $("search").focus();
  else { $("search").value = ""; renderRoster(); }
}
$("search-toggle").onclick = () => toggleSearch();
$("search").addEventListener("input", renderRoster);
$("search").addEventListener("keydown", (e) => { if (e.key === "Escape") toggleSearch(false); });

/* ---------- boot ---------- */
async function boot() {
  // Opened from a job link: the PIN first, then straight to that agent.
  let fromLink = null;
  if (Api.pendingLink) {
    fromLink = await askLinkPin();
    if (!fromLink) return;
  }
  if (!Api.signedIn()) { document.body.classList.add("signed-out"); return; }
  applyPrefs();
  Api.listen(onTeamEvent);
  const [name, keys] = await Promise.all([call("me"), call("providers")]);
  providers = keys;
  // Local models: whatever Ollama has pulled, free and offline.
  try { const lm = await call("local_models"); MODELS.ollama = (lm.installed || []).map((m) => "ollama:" + m); if (MODELS.ollama.length) providers.push("ollama"); } catch {}
  $("me-name").textContent = name || "You";
  $("me-btn").setAttribute("aria-label", `${name || "You"}: account and settings`);
  meInitials = (name || "You").split(/\s+/).map((w) => w[0]).slice(0, 2).join("").toUpperCase();
  mePhoto = await call("me_photo").catch(() => null);
  paintMe();
  $("models").replaceChildren(...Object.values(MODELS).flat().map((m) => { const o = el("option"); o.value = m; return o; }));
  await loadApprovals();
  await loadQuestions();
  await loadRoster();
  ensureAddress();
  refreshWall();
  loadAddresses();
  if (fromLink && agentById(fromLink.agent)) { openAgent(fromLink.agent); return; }
  // First launch: the welcome (sign in, apps, hire) before anything else.
  if (await maybeWelcome()) return;
  const only = new URLSearchParams(location.search).get("agent");
  if (only && agentById(only)) {
    // A window of its own: just this conversation, rail folded away.
    document.body.classList.add("agent-window");
    document.body.classList.add("rail-collapsed");
    openAgent(only);
  } else if (rows.length) {
    // The chat that needs you most recently, else the most recent one: like opening a messaging app.
    sortRows();
    openAgent((rows.find((r) => needsOf(r.id).count > 0) ?? rows[0]).id);
  } else openHire();
}
// After every script has loaded: the panels (profile, the desk, settings) are defined in their own files.
window.addEventListener("DOMContentLoaded", () => boot().catch((e) => toast("Cookie couldn't start", String(e), "error")));
// A script error in this window becomes a crash report — only if you turned them on (the engine checks).
let uiErrors = 0;
const reportUiError = (message, detail) => { if (uiErrors++ < 20) call("report_ui_error", { message: String(message).slice(0, 500), detail: String(detail || "").slice(0, 6000) }).catch(() => {}); };
window.addEventListener("error", (e) => reportUiError(e.message, `${e.filename}:${e.lineno}:${e.colno}\n${e.error?.stack ?? ""}`));
window.addEventListener("unhandledrejection", (e) => reportUiError(e.reason?.message ?? e.reason, e.reason?.stack));

// The PIN for a job link, in place of the app until it's right.
function askLinkPin() {
  return new Promise((resolve) => {
    document.body.classList.add("signed-out");
    const box = document.querySelector(".signed-out-msg");
    const pin = el("input", "text-in pin-in");
    Object.assign(pin, { type: "password", inputMode: "numeric", maxLength: 6, autocomplete: "one-time-code", placeholder: "••••••" });
    const err = el("p", "error-line"); err.hidden = true;
    const go = button("Open", "primary", async () => {
      err.hidden = true;
      try {
        const opened = await Api.openLink(pin.value.trim());
        document.body.classList.remove("signed-out");
        resolve(opened);
      } catch (e) { err.textContent = String(e); err.hidden = false; pin.value = ""; pin.focus(); }
    });
    pin.onkeydown = (e) => { if (e.key === "Enter") go.click(); };
    box.replaceChildren(el("h1", null, "Your PIN"), el("p", null, "This link opens your Cookie. Enter the six-digit PIN you set in Settings → Sharing."), pin, err, go);
    pin.focus();
  });
}

/* ---------- the model, under the composer ---------- */
function modelName(id) {
  const [prov, rest = ""] = String(id || "").split(/:(.*)/s);
  const m = rest.match(/(opus|sonnet|haiku)-(\d+)-(\d+)/i);
  if (m) return `${m[1][0].toUpperCase()}${m[1].slice(1)} ${m[2]}.${m[3]}`;
  return rest.replace(/^eu\.|^us\./, "") || prov;
}
function modelHint(id) {
  const t = /opus/i.test(id) ? "Hardest jobs, costs most" : /sonnet/i.test(id) ? "Everyday work" : /haiku/i.test(id) ? "Fast and cheapest" : id.startsWith("ollama:") ? "Free, on this Mac" : "";
  const prov = PROVIDER_NAME[id.split(":")[0]] || id.split(":")[0];
  return t ? `${t} · ${prov}` : prov;
}
function renderModelChip() {
  const b = $("model-chip");
  if (!b) return;
  b.hidden = !current;
  if (!current) return;
  b.replaceChildren(el("span", null, modelName(current.model)), el("small", null, PROVIDER_NAME[current.model.split(":")[0]] || ""));
  b.title = `${current.name} answers with ${current.model}. Click to change.`;
}
$("model-chip").onclick = () => {
  const old = document.querySelector(".model-menu");
  if (old) { old.remove(); return; }
  const agent = current;
  if (!agent) return;
  const m = el("div", "pop model-menu");
  m.setAttribute("role", "menu");
  const ids = [...new Set([agent.model, ...suggestions()])];
  for (const id of ids) {
    const b = el("button");
    b.type = "button";
    b.setAttribute("role", "menuitemradio");
    b.setAttribute("aria-checked", String(id === agent.model));
    const t = el("span", "row-text");
    t.append(el("span", null, modelName(id)), el("small", null, modelHint(id)));
    b.append(t);
    if (id === agent.model) b.append(icon("check"));
    b.onclick = async () => {
      m.remove();
      if (id === agent.model) return;
      try {
        await call("update_agent", { id: agent.id, patch: { model: id } });
        agent.model = id;
        renderModelChip();
        toast(`${agent.name} now uses ${modelName(id)}`, "From its next message.", "good");
      } catch (e) { toast("Couldn't change the model", String(e), "error"); }
    };
    m.append(b);
  }
  $("composer").append(m);
  const away = (e) => { if (!m.contains(e.target) && !$("model-chip").contains(e.target)) { m.remove(); document.removeEventListener("mousedown", away); } };
  setTimeout(() => document.addEventListener("mousedown", away), 0);
  m.addEventListener("keydown", (e) => { if (e.key === "Escape") m.remove(); });
  m.querySelector('[aria-checked="true"]')?.focus();
};

/* ---------- your photo ---------- */
let meInitials = "";
let mePhoto = null;
/** Your face: your photo when you've set one, else your initials. */
function meFace(cls = "initials") {
  const f = el("span", cls + (mePhoto ? " has-photo" : ""));
  if (mePhoto) { const i = el("img"); i.src = mePhoto; i.alt = ""; f.append(i); }
  else f.textContent = meInitials;
  return f;
}
/** Every place your face shows. */
function paintMe() {
  const slot = $("me-initials");
  slot.classList.toggle("has-photo", !!mePhoto);
  if (mePhoto) { const i = el("img"); i.src = mePhoto; i.alt = ""; slot.replaceChildren(i); }
  else slot.textContent = meInitials;
  document.querySelectorAll(".me-face-slot").forEach((n) => {
    n.classList.toggle("has-photo", !!mePhoto);
    if (mePhoto) { const i = el("img"); i.src = mePhoto; i.alt = ""; n.replaceChildren(i); } else n.textContent = meInitials;
  });
  if (typeof showMyAddress === "function") showMyAddress();
}
async function changeMyPhoto() {
  try {
    const picked = await Api.pickFiles("images");
    let r;
    if (picked === null) {
      // A browser: its own chooser.
      const file = await new Promise((ok) => { const i = el("input"); i.type = "file"; i.accept = "image/*"; i.onchange = () => ok(i.files[0]); i.click(); });
      if (!file) return;
      const data = await new Promise((ok, no) => { const fr = new FileReader(); fr.onload = () => ok(String(fr.result).split(",")[1] ?? ""); fr.onerror = no; fr.readAsDataURL(file); });
      r = await call("set_me_photo", { data });
    } else {
      if (!picked.length) return;
      r = await call("set_me_photo", { path: picked[0] });
    }
    mePhoto = r;
    paintMe();
    toast("Photo updated", "It shows wherever you do in Cookie.", "good");
  } catch (e) { toast("Couldn't use that picture", String(e), "error"); }
}
async function removeMyPhoto() {
  await call("clear_me_photo").catch(() => {});
  mePhoto = null;
  paintMe();
}
