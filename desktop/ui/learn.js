// Learning and working together: questions an agent asks you, its live plan,
// undoing what it changed, its skills, and what your team knows about you.
let questions = [];
const todosOf = new Map(); // agent id -> [{text, state}]

/* ---------- questions ---------- */
async function loadQuestions() {
  try { questions = await call("questions"); } catch { questions = []; }
  renderNeeds();
}

/** What you answered, by question id: the card keeps it once the job moves on. */
const askedAnswers = new Map();
const LETTERS = "ABCDE";

/** Answer a question: the waiting tool call gets it, the job carries on. Never a new message. */
async function answerQuestion(id, answer) {
  askedAnswers.set(id, answer);
  try { await call("answer_question", { id, answer }); return true; }
  catch (e) { askedAnswers.delete(id); toast("Couldn't answer", String(e), "error"); return false; }
}

/** A question in the chat, Nod-style: lettered choices in one list, the last row your own words. */
function questionCard(q) {
  const row = el("div", "msg agent ask-row");
  row.dataset.question = q.id;
  const c = el("div", "ask-card");
  const body = el("div", "ask-q md");
  body.innerHTML = Md.render(q.question);
  c.append(body);

  const list = el("div", "ask-list");
  list.setAttribute("role", "listbox");
  list.setAttribute("aria-label", q.question);
  const rows = [];
  const lock = (on) => { c.classList.toggle("sending", on); rows.forEach((r) => (r.disabled = on)); ownIn.disabled = on; };
  const pick = async (answer, r) => {
    if (c.classList.contains("sending")) return;
    rows.forEach((x) => x.classList.toggle("chosen", x === r));
    lock(true);
    if (!(await answerQuestion(q.id, answer))) { lock(false); r?.classList.remove("chosen"); }
  };
  (q.choices ?? []).forEach((ch, i) => {
    const r = el("button", "ask-opt");
    r.type = "button";
    r.setAttribute("role", "option");
    r.append(el("span", "ask-key", LETTERS[i]), el("span", "ask-text", ch));
    r.onclick = () => pick(ch, r);
    rows.push(r);
    list.append(r);
  });

  // The last row: type your own answer right here.
  const own = el("form", "ask-opt ask-own");
  const pen = el("span", "ask-key ask-pen");
  pen.innerHTML = '<svg><use href="#i-pencil"/></svg>';
  const ownIn = el("input", "ask-own-in");
  ownIn.placeholder = q.choices?.length ? "Type your own answer" : "Type your answer";
  ownIn.setAttribute("aria-label", ownIn.placeholder);
  const go = el("button", "ask-go");
  go.type = "submit";
  go.setAttribute("aria-label", "Send answer");
  go.innerHTML = '<svg><use href="#i-up"/></svg>';
  own.append(pen, ownIn, go);
  own.onclick = (e) => { if (e.target === own || e.target === pen) ownIn.focus(); };
  own.onsubmit = (e) => { e.preventDefault(); const v = ownIn.value.trim(); if (v) pick(v, own); };
  ownIn.addEventListener("input", () => own.classList.toggle("typed", !!ownIn.value.trim()));
  list.append(own);
  c.append(list);

  const foot = el("div", "ask-foot");
  foot.append(el("span", null, `${q.agent_name} is waiting on you`), el("span", "ask-hint", q.choices?.length ? `Press ${LETTERS.slice(0, q.choices.length).split("").join(" ")} or type below` : "Or reply in the box below"));
  c.append(foot);
  row.append(c);
  return row;
}

/** The card once answered: the question, and the answer you gave, marked. */
function answeredCard(q, answer, by) {
  const row = el("div", "msg agent ask-row");
  const c = el("div", "ask-card answered");
  const body = el("div", "ask-q md");
  body.innerHTML = Md.render(q.question);
  c.append(body);
  if (answer) {
    const list = el("div", "ask-list");
    const i = (q.choices ?? []).indexOf(answer);
    const r = el("div", "ask-opt chosen");
    r.append(i >= 0 ? el("span", "ask-key", LETTERS[i]) : (() => { const k = el("span", "ask-key ask-pen"); k.innerHTML = '<svg><use href="#i-pencil"/></svg>'; return k; })(), el("span", "ask-text", answer));
    list.append(r);
    c.append(list);
  }
  c.append(el("div", "ask-foot", by === "timeout" ? "Unanswered: it carried on without" : by === "telegram" ? "Answered from your phone" : by === "mail" ? "Answered by mail" : "Answered"));
  row.append(c);
  return row;
}

// A–E pick a choice on the newest open card, when you aren't typing somewhere.
addEventListener("keydown", (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey || e.repeat) return;
  const t = e.target;
  if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
  if (document.querySelector("dialog[open]")) return;
  const i = LETTERS.indexOf(e.key.toUpperCase());
  if (i < 0) return;
  const cards = [...document.querySelectorAll("#log .ask-row:not(:has(.answered)) .ask-card:not(.sending)")];
  const opt = cards.at(-1)?.querySelectorAll("button.ask-opt")[i];
  if (opt) { e.preventDefault(); opt.click(); }
});

function onQuestion(q) {
  questions.push(q);
  renderNeeds();
  renderRoster();
  setMood(q.agent, "waiting");
  if (current?.id === q.agent && view === "chat") { $("log").append(questionCard(q)); scrollDown(true); }
}

function onQuestionAnswered(ev) {
  const q = questions.find((x) => x.id === ev.id);
  if (!q) return false;
  questions = questions.filter((x) => x.id !== ev.id);
  const answer = ev.by === "timeout" ? undefined : askedAnswers.get(ev.id);
  askedAnswers.delete(ev.id);
  document.querySelectorAll(`[data-question="${ev.id}"]`).forEach((c) => c.replaceWith(answeredCard(q, answer, ev.by)));
  renderNeeds();
  renderRoster();
  if (busy.has(q.agent)) setMood(q.agent, "working");
  return true;
}

/* ---------- the live plan ---------- */
function onTodos(ev) {
  if (ev.items.length) todosOf.set(ev.agent, ev.items); else todosOf.delete(ev.agent);
  renderTodos(ev.agent);
}

function renderTodos(agent) {
  if (current?.id !== agent || view !== "chat") return;
  let box = $("log").querySelector(".todo-box:not(.todo-saved)");
  const items = todosOf.get(agent);
  if (!items?.length) { box?.remove(); return; }
  if (!box) {
    box = el("div", "todo-box");
    const live = [...live_jobs()].find((j) => j.agent === agent)?.ui?.status;
    if (live?.isConnected) live.after(box); else $("log").append(box);
  }
  const done = items.filter((t) => t.state === "done").length;
  const head = el("div", "todo-head");
  head.append(el("span", null, "Plan"), el("span", "muted", `${done} of ${items.length}`));
  const list = el("ol", "todo-list");
  for (const t of items) {
    const li = el("li", "todo " + t.state);
    const mark = el("span", "todo-mark");
    mark.setAttribute("aria-hidden", "true");
    li.append(mark, el("span", null, t.text));
    li.setAttribute("aria-label", `${t.text}: ${t.state}`);
    list.append(li);
  }
  box.replaceChildren(head, list);
  scrollDown();
}

function live_jobs() { return live.values(); }

/* ---------- undo ---------- */
function confirmSheet(title, lines, ok, danger = false) {
  return new Promise((resolve) => {
    const d = el("dialog", "sheet small-sheet");
    const h = el("h3", null, title);
    const list = el("ul", "changed-list");
    for (const l of lines.slice(0, 12)) list.append(el("li", null, l));
    if (lines.length > 12) list.append(el("li", "muted", `and ${lines.length - 12} more`));
    const bar = el("div", "approve-actions");
    bar.append(button("Cancel", "quiet small", () => { d.close(); resolve(false); }), button(ok, (danger ? "primary danger-fill" : "primary") + " small", () => { d.close(); resolve(true); }));
    d.append(h, list, bar);
    d.addEventListener("close", () => { d.remove(); resolve(false); });
    document.body.append(d);
    d.showModal();
  });
}

async function undoLast(agent = current) {
  closePops();
  if (!agent) return;
  const cps = await call("checkpoints", { id: agent.id }).catch(() => []);
  const cp = cps.find((c) => c.changed.length && !String(c.job).startsWith("undo-"));
  if (!cp) { toast("Nothing to undo", `${agent.name}'s folder hasn't changed since its last checkpoint.`); return; }
  await undoTo(agent, cp);
}

async function undoTo(agent, cp) {
  const yes = await confirmSheet(`Put ${agent.name}'s folder back to ${fmtTime(cp.at)}?`, cp.changed.map((c) => c.replace(/^added /, "Remove ").replace(/^changed /, "Restore ").replace(/^removed /, "Bring back ")), "Undo changes", true);
  if (!yes) return;
  try {
    const changed = await call("restore_checkpoint", { id: agent.id, job: cp.job });
    toast("Undone", `${changed.length} file change${changed.length === 1 ? "" : "s"} reversed. This undo can itself be undone from Files.`, "good");
    if (profileOpenFor(agent.id)) refreshProfile();
  } catch (e) { toast("Couldn't undo", String(e), "error"); }
}

/* ---------- learning ---------- */
function onLearned(ev) {
  if (profileOpenFor(ev.agent) && ["skills", "about"].includes(profileTab)) refreshProfile();
}

const ORIGIN = { learned: "learned here", written: "written", bundled: "from Cookie", imported: "added by you", shelf: "from the shelf" };
const STAGE = {
  core: ["Core", "Loaded by itself when a task fits."],
  oncall: ["On call", "Found with find_skill when a task asks for it."],
  trial: ["Being tested", "Tried with and without, on tests it never sees."],
  retired: ["Retired", "It did as well without these. One click restores one."],
};
const CHANGE_WORD = { picked: "Picked", core: "Now core", oncall: "On call", retired: "Retired", edited: "Improved", new: "New skill", not_kept: "Not kept", updated: "Updated", added_by_you: "You added", undone: "Undone" };

function testLine(t) {
  if (!t) return "";
  const m = typeof modelName === "function" ? modelName(t.model) : t.model;
  return `With it ${t.with}/${t.total} · without ${t.without}/${t.total} · ${m} · ${fmtDate(t.at)}`;
}

async function skillsPanel(a) {
  const [view, learning] = await Promise.all([call("skills_view", { id: a.id }), call("learning", { id: a.id })]);
  const parts = [];
  const g = el("div", "group");
  g.append(setRow("Learns from your conversations", `Every ${learning.memory_every} conversations it proposes small improvements from what you said and decided. Each is tested first and kept only if it's no worse.`, toggle(learning.enabled, async (on) => { await call("set_learning", { id: a.id, on }); }, "Learns from your conversations")));
  g.append(setRow("Learn now", "Review the latest conversation right away.", button("Learn now", "quiet small", async (e) => {
    const b = e.currentTarget; b.disabled = true; b.textContent = "Learning…";
    try {
      const r = await call("learn_now", { id: a.id });
      toast(r.changes.length ? `${a.name} proposed changes` : "Nothing new to keep", r.changes.length ? "They're tested next, and kept only if no worse." : r.summary, r.changes.length ? "good" : "");
      refreshProfile();
    } catch (err) { toast("Couldn't learn", String(err), "error"); b.disabled = false; b.textContent = "Learn now"; }
  })));
  parts.push(g);

  // What Cookie is doing on its own.
  const auto = el("p", "muted small skills-auto");
  const spent = view.tests.spent_microdollars ? `$${(view.tests.spent_microdollars / 1e6).toFixed(2)}` : `${(view.tests.spent_tokens || 0).toLocaleString()} tokens`;
  auto.textContent = `Cookie picks, tests and updates ${a.name}'s skills itself. ` + (view.picked_at ? `Picked ${fmtDate(view.picked_at)}. ` : "Picking them now. ") + (view.tests.on ? `Tests this month: ${spent} of $${view.tests.month_dollars}.` : "Tests are off (Settings → Skills).");
  parts.push(auto);
  if (view.waiting || view.proposed.length) {
    const w = el("div", "group");
    if (view.waiting) w.append(setRow(`${view.waiting} proposed change${view.waiting === 1 ? "" : "s"} waiting for tests`, "Kept only if its tests are no worse with them.", null));
    for (const p of view.proposed) w.append(setRow(`New: ${p.name}`, `Came up in ${p.seen} of ${p.needs} reviews before it's tried.`, null));
    parts.push(w);
  }

  for (const stage of ["core", "oncall", "trial", "retired"]) {
    const list = view.skills.filter((s) => s.stage === stage);
    if (!list.length && stage !== "core") continue;
    const [title, note] = STAGE[stage];
    parts.push(el("h3", "group-title", stage === "core" ? `${title} (${list.length} of 3)` : `${title} (${list.length})`));
    const box = el("div", "group");
    const testing = view.skills.some((x) => x.stage === "trial");
    if (!list.length) box.append(setRow("None yet", testing ? "Its picks are being tested: a skill becomes core only if it helps." : view.picked_at ? "Nothing on the shelf helped enough yet. It finds skills while it works, and learns its own." : "Cookie is choosing and testing them.", null));
    for (const s of list) box.append(skillRow(a, s));
    parts.push(box, el("p", "muted small", note));
  }

  if (view.changes.length) {
    parts.push(el("h3", "group-title", "Recent changes"));
    const ch = el("div", "group");
    for (const c of view.changes.slice(0, 12)) {
      const r = setRow(`${CHANGE_WORD[c.kind] ?? c.kind}: ${c.skill}`, [c.what, testLine(c.test), fmtTime(c.at)].filter(Boolean).join(" · "), null);
      if (c.version) {
        const acts = el("div", "row-actions");
        acts.append(button("See change", "quiet small", () => showDiff(a, c.skill, c.version, r)), button("Undo", "quiet small", async () => {
          try { await call("skill_undo", { id: a.id, name: c.skill, version: c.version }); toast("Undone", `${c.skill} is as it was.`, "good"); refreshProfile(); }
          catch (e) { toast("Couldn't undo", String(e), "error"); }
        }));
        r.append(acts);
      }
      ch.append(r);
    }
    parts.push(ch);
  }

  const acts = el("div", "row-actions wrap");
  acts.append(
    button("Test again", "quiet small", async () => { await call("skills_retest", { id: a.id }); toast("Testing", `${a.name}'s core skills, with and without.`, ""); }),
    button("Pick again", "quiet small", async () => { await call("skills_pick_again", { id: a.id }); toast("Picking", `Cookie reads ${a.name}'s job and the shelf again.`, ""); }),
  );
  parts.push(acts);
  parts.push(...byHandSection(a));
  return parts;
}

/** A change, line by line, under its row. */
async function showDiff(a, name, version, row) {
  const open = row.nextElementSibling?.classList.contains("skill-diff");
  if (open) { row.nextElementSibling.remove(); return; }
  try {
    const lines = await call("skill_diff", { id: a.id, name, version });
    const pre = el("pre", "skill-diff");
    for (const l of lines.filter((l, i, all) => !l.startsWith("  ") || all.slice(Math.max(0, i - 2), i + 3).some((x) => !x.startsWith("  ")))) {
      const span = el("span", l.startsWith("+ ") ? "add" : l.startsWith("- ") ? "del" : "same", l);
      pre.append(span, "\n");
    }
    row.after(pre);
  } catch (e) { toast("Couldn't show it", String(e), "error"); }
}

function skillRow(a, s) {
  const r = el("button", "row link-row skill-row");
  const t = el("div", "row-text");
  const lines = [s.description];
  if (s.why) lines.push(s.why);
  const tl = testLine(s.test);
  if (tl) lines.push(tl);
  if (s.wins || s.losses) lines.push(`Went well ${s.wins} of ${s.wins + s.losses} times it was used`);
  t.append(el("span", null, s.name), el("small", null, lines.join(" · ")));
  const tags = el("div", "skill-tags");
  tags.append(el("span", "tag", s.source?.source?.startsWith("github:") ? s.source.source.slice(7) : ORIGIN[s.origin] ?? s.origin));
  if (s.update_available) tags.append(el("span", "tag", "update"));
  r.append(t, tags);
  r.onclick = () => openSkill(a, { ...s, archived: s.stage === "retired" });
  return r;
}

async function openSkill(a, s, file = "SKILL.md") {
  const body = $("profile").querySelector(".profile-body");
  let text = "";
  try { text = await call("skill_read", { id: a.id, name: s.name, file }); } catch (e) { toast("Couldn't open it", String(e), "error"); return; }
  const back = button("← Skills", "quiet small", () => openProfile("skills"));
  const head = el("div", "skill-head");
  head.append(back, strong(s.name));
  const view = el("div", "skill-view bubble md");
  view.innerHTML = Md.render(text.replace(/^---[\s\S]*?---\n/, ""));
  const files = el("div", "skill-files");
  for (const f of ["SKILL.md", ...(s.files ?? [])]) {
    const b = button(f.split("/").pop(), "quiet small" + (f === file ? " on" : ""), () => openSkill(a, s, f));
    b.title = f;
    files.append(b);
  }
  const acts = el("div", "row-actions wrap");
  if (!s.archived) {
    acts.append(button("Edit", "quiet small", () => editSkill(a, s, file, text)));
    acts.append(button(s.pinned ? "Unpin" : "Pin", "quiet small", async () => { await call("skill_set", { id: a.id, name: s.name, action: s.pinned ? "unpin" : "pin" }); openProfile("skills"); }));
    acts.append(button("Archive", "quiet small", async () => { await call("skill_set", { id: a.id, name: s.name, action: "archive" }); openProfile("skills"); }));
  } else {
    acts.append(button("Restore", "primary small", async () => { await call("skill_set", { id: a.id, name: s.name, action: "restore" }); openProfile("skills"); }));
  }
  acts.append(button("Delete", "quiet small danger", async () => {
    if (await confirmSheet(`Delete ${s.name}?`, ["The skill and all its earlier versions are removed for good. Archive keeps it instead."], "Delete", true)) {
      await call("skill_set", { id: a.id, name: s.name, action: "delete" }); openProfile("skills");
    }
  }));
  const versions = await call("skill_versions", { id: a.id, name: s.name }).catch(() => []);
  const vbox = el("div", "group");
  for (const v of versions.filter((v) => v.files.includes(file)).slice(0, 8)) {
    const row = setRow(`Before ${fmtTime(v.at)}`, file, null);
    const acts = el("div", "row-actions");
    if (file === "SKILL.md") acts.append(button("See change", "quiet small", () => showDiff(a, s.name, v.version, row)));
    acts.append(button("Put back", "quiet small", async () => {
      try { await call("skill_revert", { id: a.id, name: s.name, version: v.version, file }); toast("Put back", `${s.name}/${file} as it was`, "good"); openSkill(a, s, file); }
      catch (e) { toast("Couldn't put it back", String(e), "error"); }
    }));
    row.append(acts);
    vbox.append(row);
  }
  body.replaceChildren(head, files, view, acts, ...(vbox.children.length ? [el("h3", "group-title", "Earlier versions"), vbox] : []));
}

function editSkill(a, s, file = "SKILL.md", text = "") {
  const body = $("profile").querySelector(".profile-body");
  const name = input(s?.name ?? "", "kind-of-task, e.g. weekly-report");
  name.disabled = !!s;
  const ta = el("textarea", "text-in skill-edit");
  ta.rows = 18;
  ta.spellcheck = false;
  ta.value = s ? text : "---\nname: \ndescription: When to use it, in one line\n---\n\n# Steps\n\n1. \n\n# Pitfalls\n\n- ";
  name.addEventListener("input", () => { name.value = name.value.toLowerCase().replace(/[^a-z0-9-]/g, ""); ta.value = ta.value.replace(/^name: .*$/m, `name: ${name.value}`); });
  const save = button("Save", "primary small", async () => {
    try {
      await call("skill_save", { id: a.id, name: s?.name ?? name.value, file, content: ta.value });
      toast("Saved", `${s?.name ?? name.value}/${file}`, "good");
      openProfile("skills");
    } catch (e) { toast("Couldn't save", String(e), "error"); }
  });
  body.replaceChildren(el("div", "skill-head"), name, ta, el("p", "muted small", "A skill is how to do a kind of task: the steps in order, what the result should look like, and the pitfalls. No secrets."), save);
  body.firstChild.append(button("Cancel", "quiet small", () => s ? openSkill(a, s, file) : openProfile("skills")), strong(s ? `${s.name}/${file}` : "New skill"));
}

/* ---------- by hand: the fallback ---------- */
function byHandSection(a) {
  const det = el("details", "by-hand");
  det.append(el("summary", null, "Add a skill yourself"));
  const find = el("form", "group edit about-add");
  const q = input("", "Search Cookie's shelf, e.g. spreadsheet, meeting notes");
  find.append(q, button("Search", "quiet small", () => find.requestSubmit()));
  const results = el("div", "group");
  results.hidden = true;
  find.onsubmit = async (e) => {
    e.preventDefault();
    const found = await call("shelf_search", { query: q.value }).catch(() => []);
    results.replaceChildren(...(found.length ? found.map((it) => setRow(it.name, it.description, button("Add", "quiet small", async () => {
      try { await call("skill_add_by_hand", { id: a.id, shelf: it.name }); toast("Added", `${it.name} is being tested for ${a.name}.`, "good"); refreshProfile(); }
      catch (err) { toast("Couldn't add it", String(err), "error"); }
    }))) : [setRow("Nothing on the shelf matches", "Try other words.", null)]));
    results.hidden = false;
  };
  det.append(find, results);
  if (!Api.web) {
    const f = el("form", "group edit about-add");
    const p = input("", "A folder on this Mac with a SKILL.md, e.g. ~/skills/cold-email");
    f.append(p, button("Add", "quiet small", () => f.requestSubmit()));
    f.onsubmit = async (e) => {
      e.preventDefault();
      try { const n = await call("skill_add_by_hand", { id: a.id, path: p.value }); toast("Added", `${n} is being tested for ${a.name}.`, "good"); refreshProfile(); }
      catch (err) { toast("Couldn't add it", String(err), "error"); }
    };
    det.append(f);
  }
  det.append(button("Write one yourself", "quiet small", () => editSkill(a, null)), el("p", "muted small", "Whatever you add goes through the same checks and tests as the skills Cookie picks."));
  return [det];
}

/* ---------- Settings → Skills: the shelf ---------- */
async function skillsSettings() {
  const [shelf, cfg] = await Promise.all([call("shelf"), call("auto_skills_cfg")]);
  const parts = [el("h2", null, "Skills")];
  parts.push(el("p", "muted", "Agents draw skills only from Cookie's shelf, never straight from the internet. Every skill on it passed a format and licence check, a content scan for instructions aimed at the agent, and a check of what power it needs. Cookie refreshes it daily and tests each skill on each agent before relying on it."));
  const g = el("div", "group");
  g.append(setRow("Test skills automatically", "Each skill runs with and without on practice tasks before an agent relies on it. Tests use model calls.", toggle(cfg.tests, async (on) => { await call("set_auto_skills_cfg", { tests: on }); })));
  const cap = input(String(cfg.month_dollars), "3");
  cap.type = "number"; cap.min = 0; cap.step = "0.5"; cap.classList.add("num-in");
  cap.onchange = async () => { try { await call("set_auto_skills_cfg", { month_dollars: +cap.value }); toast("Saved", `Skill tests stop at $${cap.value} a month.`, "good"); } catch (e) { toast("Couldn't save", String(e), "error"); } };
  g.append(setRow("Monthly limit for tests", "Tests wait for next month past it.", cap));
  parts.push(g);

  parts.push(el("h3", "group-title", "The shelf"));
  const s = el("div", "group");
  s.append(setRow(`${shelf.vetted} vetted skill${shelf.vetted === 1 ? "" : "s"}`, (shelf.refreshed_at ? `Checked ${fmtTime(shelf.refreshed_at)}` : "Not checked yet") + (shelf.refused ? ` · ${shelf.refused} refused` : "") + (shelf.last_error ? ` · ${shelf.last_error}` : ""), button("Check now", "quiet small", async (e) => {
    const b = e.currentTarget; b.disabled = true; b.textContent = "Checking…";
    try { const r = await call("shelf_refresh"); toast("Shelf checked", `${r.added?.length ?? 0} new, ${r.changed?.length ?? 0} updated, ${r.refused?.length ?? 0} refused.`, "good"); refreshSettings(); }
    catch (err) { toast("Couldn't check", String(err), "error"); b.disabled = false; b.textContent = "Check now"; }
  })));
  parts.push(s);

  if (shelf.held.length) {
    parts.push(el("h3", "group-title", "Updates that want more"));
    const h = el("div", "group");
    for (const it of shelf.held) {
      const r = setRow(it.name, `${it.grew.join("; ")}. Agents keep the old version until you decide.`, null);
      const acts = el("div", "row-actions");
      acts.append(button("Keep old", "quiet small", async () => { await call("shelf_decide", { name: it.name, accept: false }); refreshSettings(); }), button("Let it in", "primary small", async () => { await call("shelf_decide", { name: it.name, accept: true }); toast("Updated", `${it.name} is tested again on each agent.`, "good"); refreshSettings(); }));
      r.append(acts);
      h.append(r);
    }
    parts.push(h);
  }

  parts.push(el("h3", "group-title", "Sources"));
  const src = el("form", "group edit about-add");
  const si = input(shelf.sources.map((x) => x.replace(/^github:/, "")).join(", "), "owner/repo, owner/repo");
  src.append(si, button("Save", "quiet small", () => src.requestSubmit()));
  src.onsubmit = async (e) => {
    e.preventDefault();
    try { await call("shelf_sources", { sources: si.value.split(",").map((x) => x.trim()).filter(Boolean) }); toast("Sources saved", "They're read at the next check.", "good"); refreshSettings(); }
    catch (err) { toast("Couldn't save", String(err), "error"); }
  };
  parts.push(src, el("p", "muted small", "Public GitHub repositories of skills (Agent Skills format). Only skills under an open licence are kept."));

  const list = shelf.skills.slice().sort((x, y) => x.state.localeCompare(y.state) || x.name.localeCompare(y.name));
  const det = el("details", "by-hand");
  det.append(el("summary", null, `Everything on the shelf (${list.length})`));
  const all = el("div", "group");
  for (const k of list) {
    const why = k.state === "refused" ? `Refused: ${k.reasons.join("; ")}` : [k.description, k.source === "bundled" ? "from Cookie" : k.source.replace(/^github:/, ""), k.license, k.power?.scripts?.length ? `scripts: ${k.power.scripts.length}` : "", k.power?.network ? "uses the network" : ""].filter(Boolean).join(" · ");
    all.append(setRow(k.name, why, el("span", "tag", k.state)));
  }
  det.append(all);
  parts.push(det);
  return parts;
}
SETTINGS.skills = skillsSettings;

/* ---------- about you (Settings) ---------- */
async function aboutYouPane() {
  const lines = await call("about_you");
  const parts = [el("h2", null, "About you")];
  parts.push(el("p", "muted", "What every agent on your team knows about you and how you like things done. Agents add lines when you tell them something lasting; you can change anything here."));
  const g = el("div", "group");
  if (!lines.length) g.append(setRow("Nothing yet", "Tell any agent something like “I'm Naveen, keep emails short” and it keeps it.", null));
  for (const l of lines) {
    g.append(setRow(l, null, button("Remove", "quiet small", async () => { await call("about_you_remove", { line: l }); refreshSettings(); })));
  }
  parts.push(g);
  const add = el("form", "group edit about-add");
  const inp = input("", "Add a line, e.g. I work in Riga time (UTC+2)");
  inp.maxLength = 300;
  add.append(inp, button("Add", "primary small", () => add.requestSubmit()));
  add.onsubmit = async (e) => {
    e.preventDefault();
    try { await call("about_you_add", { line: inp.value }); refreshSettings(); }
    catch (err) { toast("Couldn't add it", String(err), "error"); }
  };
  parts.push(add);
  return parts;
}

/* ---------- wiring into the other panels ---------- */
PANELS.skills = skillsPanel;
SETTINGS.you = aboutYouPane;

// Files: also the folder's checkpoints, to undo what a job changed.
const filesPanel = PANELS.files;
PANELS.files = async (a) => {
  const parts = await filesPanel(a);
  const cps = (await call("checkpoints", { id: a.id }).catch(() => [])).filter((c) => c.changed.length);
  if (cps.length) {
    parts.push(el("h3", "group-title", "Undo"));
    const g = el("div", "group");
    for (const cp of cps.slice(0, 8)) {
      g.append(setRow(`${String(cp.job).startsWith("undo-") ? "Before your undo" : "Before a job"} · ${fmtTime(cp.at)}`, cp.changed.slice(0, 4).join(", ") + (cp.changed.length > 4 ? ` and ${cp.changed.length - 4} more` : ""), button("Put back", "quiet small", () => undoTo(a, cp))));
    }
    parts.push(g);
  }
  return parts;
};

$("undo-last").onclick = () => undoLast();
