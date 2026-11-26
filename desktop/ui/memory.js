// The Memory tab: what this agent knows, where it lives, and the person's hand
// on it. Ask what it knows about something (exactly what it would recall),
// teach it a fact, correct a memory (Enkeon keeps the old words as history),
// or forget one for good. With Enkeon each agent has its own space; it also
// reads the person's shared memory, and no other agent can read its space.

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
  if (view.mode === "enkeon") parts.push(...(await followsSection(a)));

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

/* ---------- the spaces it follows (`brain`) ---------- */
async function followsSection(a) {
  const [follows, sv] = await Promise.all([call("followed", { id: a.id }).catch(() => []), call("spaces_view").catch(() => null)]);
  const out = [el("h3", "group-title", `Spaces it follows (${follows.length})`)];
  const g = el("div", "group");
  if (!follows.length) g.append(setRow("None yet", "Cookie gives it the spaces that belong to its job (a lead's, a repository's) as they appear. You can add any.", null));
  for (const f of follows.slice(0, 40)) {
    const note = [f.owns ? (f.wakes ? "It owns this: new things here can wake it" : "It owns this") : "It reads this", f.memory_count != null ? `${f.memory_count} memories` : ""].filter(Boolean).join(" · ");
    g.append(setRow(f.space, note, f.owns ? el("span", "tag", "owner") : button("Stop", "quiet small", async () => { await call("set_follow", { id: a.id, space: f.space, on: false }); refreshProfile(); })));
  }
  if (follows.length > 40) g.append(setRow(`And ${follows.length - 40} more`, "Settings → Spaces lists them all.", null));
  out.push(g);
  if (sv?.spaces?.length) {
    const add = el("form", "group edit about-add");
    const pick = el("select", "pick");
    pick.append(el("option", null, "Follow another space…"));
    for (const s of sv.spaces.filter((s) => !follows.some((f) => f.space === s.name))) { const o = el("option", null, `${s.name} (${s.memory_count})`); o.value = s.name; pick.append(o); }
    pick.onchange = async () => { if (!pick.value || pick.selectedIndex === 0) return; await call("set_follow", { id: a.id, space: pick.value, on: true }); refreshProfile(); };
    add.append(pick);
    out.push(add);
  }
  out.push(el("p", "muted small", "It reads its own space, your shared memory and these; it writes only to its own. Before each job Cookie hands it what bears on the task from them."));
  return out;
}

/* ---------- Settings → Spaces ---------- */
async function spacesSettings() {
  const v = await call("spaces_view");
  const parts = [el("h2", null, "Spaces")];
  parts.push(el("p", "muted", "Your memory is kept in spaces: one per client, lead, repository and project. Cookie gives each new one to the agent whose job it belongs to, which reads it and is woken by what's new there. The rest stay with Cookie, read but never waking it. Your choice always stands."));
  const head = el("div", "group");
  head.append(setRow(`${v.spaces.length} spaces`, (v.read_at ? `Read ${fmtTime(v.read_at)}` : "Not read yet") + (v.plans ? ` · ${v.plans} open plans watched` : "") + (v.last_error ? ` · ${v.last_error}` : ""), button("Read now", "quiet small", async (e) => {
    const b = e.currentTarget; b.disabled = true; b.textContent = "Reading…";
    try { const r = await call("spaces_refresh"); toast("Spaces read", `${r.new?.length ?? 0} new, ${r.assigned?.length ?? 0} given an owner.`, "good"); refreshSettings(); }
    catch (err) { toast("Couldn't read them", String(err), "error"); b.disabled = false; b.textContent = "Read now"; }
  })));
  parts.push(head);
  const names = Object.fromEntries(v.agents.map((x) => [x.id, x.name]));
  const filter = input("", "Find a space");
  const list = el("div", "group");
  const draw = () => {
    const q = filter.value.trim().toLowerCase();
    const rows = v.spaces.filter((s) => !q || s.name.includes(q) || (names[s.owner] ?? "").toLowerCase().includes(q)).slice(0, 80);
    list.replaceChildren(...rows.map((s) => {
      const sel = el("select", "pick");
      for (const ag of v.agents) { const o = el("option", null, ag.name); o.value = ag.id; o.selected = s.owner === ag.id; sel.append(o); }
      if (!s.owner) { const o = el("option", null, "Nobody yet"); o.selected = true; o.value = ""; sel.prepend(o); }
      sel.onchange = async () => { try { await call("set_space_owner", { space: s.name, owner: sel.value || null }); toast("Owner set", `${s.name} → ${names[sel.value] ?? "Cookie"}`, "good"); refreshSettings(); } catch (e) { toast("Couldn't set it", String(e), "error"); } };
      const wake = toggle(!!s.wakes, async (on) => { await call("set_space_owner", { space: s.name, owner: s.owner, wakes: on }); }, `${s.name} wakes its owner`);
      const ctl = el("div", "row-actions");
      ctl.append(sel, wake);
      return setRow(s.name, [`${s.memory_count} memories`, s.held_plans ? `${s.held_plans} open plans` : "", s.why, s.by === "you" ? "your choice" : ""].filter(Boolean).join(" · "), ctl);
    }));
  };
  filter.oninput = draw;
  draw();
  parts.push(filter, list);
  if (v.shared?.length) {
    parts.push(el("h3", "group-title", "Shared with the whole team"));
    const sh = el("div", "group");
    for (const f of v.shared.slice(0, 20)) sh.append(setRow(f.statement, `${names[f.agent] ?? f.agent} · ${f.why} · ${fmtTime(f.at)}`, null));
    parts.push(sh);
  }
  return parts;
}
SETTINGS.spaces = spacesSettings;
