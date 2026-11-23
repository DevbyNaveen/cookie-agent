// The Memory tab: what this agent knows, where it lives, and the person's hand
// on it. Ask what it knows about something (exactly what it would recall),
// teach it a fact, correct a memory (Enkeon keeps the old words as history),
// or forget one for good. With Enkeon each agent has its own space; it also
// reads the person's shared memory, and no other agent can read its space.
TABS.splice(2, 0, ["memory", "Memory"]);

const KIND_LABEL = { fact: "fact", decision: "decision", preference: "preference", plan: "plan", requirement: "rule", opinion: "opinion", procedure: "how-to", correction: "correction", insight: "insight", metric: "number", definition: "term", episode: "moment" };
const BY_LABEL = { agent: "it learned", review: "learned on review", you: "you told it" };

function memSince(secs) {
  if (!secs) return "";
  const d = Math.max(0, Date.now() / 1000 - secs);
  if (d < 90) return "just now";
  if (d < 3600) return `${Math.round(d / 60)} min ago`;
  if (d < 86400) return `${Math.round(d / 3600)} h ago`;
  if (d < 86400 * 30) return `${Math.round(d / 86400)} d ago`;
  return fmtTime(secs);
}

PANELS.memory = async (a) => {
  const view = await call("memory", { id: a.id });
  const parts = [];

  // Where it lives.
  const where = el("div", "mem-where");
  const glyph = el("span", "mem-glyph");
  glyph.append(icon(view.mode === "enkeon" ? "globe" : view.mode === "local" ? "file" : "eyeoff"));
  const wt = el("div", "row-text");
  if (view.mode === "enkeon") {
    wt.append(el("span", null, "Its own space in Enkeon"), el("small", "mono", view.place),
      el("small", null, "It also reads your shared memory. No other agent can read this space, and firing it erases it."));
  } else if (view.mode === "local") {
    wt.append(el("span", null, "Notes on this Mac"), el("small", "mono", "NOTES.md, in its folder"),
      el("small", null, "Sign in to Enkeon (the Enkeon CLI) to give it a real memory: its own space, searchable, with history."));
  } else {
    wt.append(el("span", null, "Memory is off"), el("small", null, "It starts every conversation fresh. Turn memory on in About."));
  }
  where.append(glyph, wt);
  parts.push(where);
  if (view.pending_erase) parts.push(el("p", "mem-note", `${view.pending_erase} memor${view.pending_erase === 1 ? "y" : "ies"} of fired agents still wait to be erased from Enkeon; Cookie retries when it starts.`));
  if (view.mode === "off") return parts;

  // Ask what it knows.
  const ask = el("form", "mem-ask");
  const q = el("input", "mem-input");
  q.type = "search";
  q.placeholder = `What does ${a.name} know about…`;
  q.setAttribute("aria-label", `Ask what ${a.name} knows`);
  const s = el("span", "mem-ask-ic"); s.append(icon("search"));
  ask.append(s, q);
  const found = el("div", "mem-found");
  found.hidden = true;
  ask.onsubmit = async (e) => {
    e.preventDefault();
    const query = q.value.trim();
    if (!query) { found.hidden = true; return; }
    found.hidden = false;
    found.replaceChildren(el("p", "mem-note shimmer", "Recalling…"));
    try {
      const hits = await call("memory_search", { id: a.id, query });
      if (!hits.length) { found.replaceChildren(el("p", "mem-note", "Nothing on this. It would say it doesn't know.")); return; }
      found.replaceChildren(el("p", "mem-note", "What it would recall, best first:"), ...hits.map((h) => {
        const r = el("div", "mem-hit" + (h.mine ? " mine" : ""));
        const meta = el("div", "mem-meta");
        meta.append(el("span", "mem-chip " + (h.mine ? "own" : "shared"), h.mine ? "its own" : "shared from you"));
        if (h.kind && KIND_LABEL[h.kind]) meta.append(el("span", "mem-kind", KIND_LABEL[h.kind]));
        if (h.proof === "source_changed") meta.append(el("span", "mem-proof warn", "source changed since"));
        else if (h.proof === "source_matched" || h.proof === "saved_intact") meta.append(el("span", "mem-proof", "✓ verified"));
        r.append(el("p", "mem-text", h.text), meta);
        return r;
      }));
    } catch (err) { found.replaceChildren(el("p", "mem-note error-line", String(err))); }
  };
  parts.push(ask, found);

  // Teach it.
  const teach = el("form", "mem-teach");
  const t = el("textarea", "mem-input");
  t.rows = 1;
  t.placeholder = "Tell it something to keep…";
  t.setAttribute("aria-label", "Something for it to remember");
  const keep = button("Keep", "primary small", null);
  keep.type = "submit";
  keep.onclick = null; // the form's submit does the work
  keep.disabled = true;
  t.oninput = () => { keep.disabled = !t.value.trim(); t.style.height = "auto"; t.style.height = Math.min(t.scrollHeight, 120) + "px"; };
  t.onkeydown = (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); teach.requestSubmit(); } };
  teach.onsubmit = async (e) => {
    e.preventDefault();
    const text = t.value.trim();
    if (!text) return;
    keep.disabled = true; keep.textContent = "Keeping…";
    try { await call("memory_add", { id: a.id, text }); toast(`${a.name} will remember`, text, "good"); refreshProfile(); }
    catch (err) { toast("Couldn't keep it", String(err), "error"); keep.disabled = false; keep.textContent = "Keep"; }
  };
  teach.append(t, keep);
  parts.push(teach);

  // What it knows.
  parts.push(el("h3", "group-title", view.items.length ? `What it knows (${view.items.length})` : "What it knows"));
  if (!view.items.length) {
    parts.push(el("p", "mem-empty", view.mode === "enkeon"
      ? "Nothing yet. As you work together it keeps what will matter later (how you like things, facts about your work), and each one shows up here."
      : "No notes yet. It keeps a note when you tell it something that will matter later."));
    return parts;
  }
  const list = el("div", "mem-list");
  for (const m of view.items) list.append(memRow(a, m, view.mode));
  parts.push(list);
  return parts;
};

function memRow(a, m, mode) {
  const r = el("div", "mem-item");
  const text = el("p", "mem-text", m.text);
  const meta = el("div", "mem-meta");
  if (m.kind && KIND_LABEL[m.kind]) meta.append(el("span", "mem-kind", KIND_LABEL[m.kind]));
  if (m.by) meta.append(el("span", null, BY_LABEL[m.by] ?? m.by));
  if (m.at) meta.append(el("span", null, memSince(m.at)));
  if (m.versions) meta.append(el("span", null, `corrected ${m.versions}×`));
  const tools = el("div", "mem-tools");
  const edit = el("button", "mem-tool"); edit.type = "button"; edit.title = "Correct it"; edit.setAttribute("aria-label", "Correct it"); edit.append(icon("pencil"));
  const del = el("button", "mem-tool danger"); del.type = "button"; del.title = "Forget it"; del.setAttribute("aria-label", "Forget it"); del.append(icon("trash"));
  tools.append(edit, del);
  r.append(text, meta, tools);

  edit.onclick = () => {
    const box = el("textarea", "mem-input mem-edit");
    box.value = m.text;
    const save = button("Save", "primary small", null);
    const cancel = button("Cancel", "quiet small", () => r.replaceWith(memRow(a, m, mode)));
    const row = el("div", "mem-edit-row");
    row.append(el("small", "muted", mode === "enkeon" ? "The old words stay in Enkeon as history." : ""), cancel, save);
    r.replaceChildren(box, row);
    box.style.height = Math.min(box.scrollHeight + 2, 160) + "px";
    box.focus(); box.setSelectionRange(box.value.length, box.value.length);
    box.onkeydown = (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) save.click(); if (e.key === "Escape") cancel.click(); };
    save.onclick = async () => {
      const next = box.value.trim();
      if (next === m.text) { cancel.click(); return; }
      save.disabled = true; save.textContent = "Saving…";
      try { await call("memory_edit", { id: a.id, memory: m.id, text: next }); refreshProfile(); }
      catch (err) { toast("Couldn't change it", String(err), "error"); save.disabled = false; save.textContent = "Save"; }
    };
  };

  // Two steps: the first tap asks, the second forgets.
  let armed = null;
  del.onclick = async () => {
    if (!del.classList.contains("armed")) {
      del.classList.add("armed"); del.title = "Tap again to forget it for good";
      del.setAttribute("aria-label", del.title);
      armed = setTimeout(() => { del.classList.remove("armed"); del.title = "Forget it"; del.setAttribute("aria-label", "Forget it"); }, 3000);
      return;
    }
    clearTimeout(armed);
    r.classList.add("leaving");
    try { await call("memory_forget", { id: a.id, memory: m.id }); toast("Forgotten", m.text.slice(0, 120), ""); refreshProfile(); }
    catch (err) { r.classList.remove("leaving"); toast("Couldn't forget it", String(err), "error"); }
  };
  return r;
}
