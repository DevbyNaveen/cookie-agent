// Learning and working together: questions an agent asks you, its live plan,
// undoing what it changed, its skills, and what your team knows about you.
let questions = [];
const todosOf = new Map(); // agent id -> [{text, state}]

/* ---------- questions ---------- */
async function loadQuestions() {
  try { questions = await call("questions"); } catch { questions = []; }
  renderTodayRow();
}

function questionCard(q) {
  const c = el("div", "approve-card ask-card");
  c.dataset.question = q.id;
  const head = el("div", "approve-head");
  const f = Faces.create(q.agent, 24); f.setMood("waiting");
  head.append(f.el, el("span", null, `${q.agent_name} asks`));
  const body = el("div", "ask-q bubble md");
  body.innerHTML = Md.render(q.question);
  c.append(head, body);
  const send = async (answer) => {
    try { await call("answer_question", { id: q.id, answer }); }
    catch (e) { toast("Couldn't answer", String(e), "error"); }
  };
  if (q.choices?.length) {
    const choices = el("div", "ask-choices");
    for (const ch of q.choices) choices.append(button(ch, "quiet small ask-choice", () => send(ch)));
    c.append(choices);
  }
  const own = el("form", "ask-own");
  const inp = input("", q.choices?.length ? "Or answer in your own words" : "Your answer");
  own.append(inp, button("Answer", "primary small", () => own.requestSubmit()));
  own.onsubmit = (e) => { e.preventDefault(); if (inp.value.trim()) send(inp.value); };
  c.append(own);
  return c;
}

function onQuestion(q) {
  questions.push(q);
  renderTodayRow();
  renderRoster();
  setMood(q.agent, "waiting");
  if (current?.id === q.agent && view === "chat") { $("log").append(questionCard(q)); scrollDown(true); }
  if (view === "today") renderToday();
}

function onQuestionAnswered(ev) {
  const q = questions.find((x) => x.id === ev.id);
  if (!q) return false;
  questions = questions.filter((x) => x.id !== ev.id);
  document.querySelectorAll(`[data-question="${ev.id}"]`).forEach((c) => {
    c.replaceWith(event([ev.by === "timeout" ? "Unanswered: it carried on without" : "Answered", ev.by === "telegram" ? " from your phone" : ""]));
  });
  renderTodayRow();
  if (busy.has(q.agent)) setMood(q.agent, "working");
  if (view === "today") renderToday();
  return true;
}

/* ---------- the live plan ---------- */
function onTodos(ev) {
  if (ev.items.length) todosOf.set(ev.agent, ev.items); else todosOf.delete(ev.agent);
  renderTodos(ev.agent);
}

function renderTodos(agent) {
  if (current?.id !== agent || view !== "chat") return;
  let box = $("log").querySelector(".todo-box");
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

const ORIGIN = { learned: "learned", written: "written", bundled: "from Cookie", imported: "added" };

async function skillsPanel(a) {
  const [skills, learning] = await Promise.all([call("skills", { id: a.id }), call("learning", { id: a.id })]);
  const parts = [];
  const g = el("div", "group");
  g.append(setRow("Learns from your conversations", `Every ${learning.memory_every} conversations it re-reads the latest and keeps what should last: how you like this work done, as skills you can read, change and undo.`, toggle(learning.enabled, async (on) => { await call("set_learning", { id: a.id, on }); })));
  const learnRow = setRow("Learn now", "Review the latest conversation right away.", button("Learn now", "quiet small", async (e) => {
    const b = e.currentTarget; b.disabled = true; b.textContent = "Learning…";
    try {
      const r = await call("learn_now", { id: a.id });
      toast(r.changes.length ? `${a.name} learned` : "Nothing new to keep", r.changes.length ? r.changes.join(" · ") : r.summary, r.changes.length ? "good" : "");
      refreshProfile();
    } catch (err) { toast("Couldn't learn", String(err), "error"); b.disabled = false; b.textContent = "Learn now"; }
  }));
  g.append(learnRow);
  parts.push(g);

  const live = skills.filter((s) => !s.archived), old = skills.filter((s) => s.archived);
  parts.push(el("h3", "group-title", `Skills (${live.length})`));
  const list = el("div", "group");
  if (!live.length) list.append(setRow("No skills yet", "Correct it the way you'd correct a colleague; it keeps the lesson here. Or add one from Cookie's catalog below.", null));
  for (const s of live) list.append(skillRow(a, s));
  parts.push(list);
  parts.push(button("New skill", "quiet small", () => editSkill(a, null)));
  if (old.length) {
    parts.push(el("h3", "group-title", `Archived (${old.length})`));
    const ol = el("div", "group");
    for (const s of old) ol.append(skillRow(a, s));
    parts.push(ol);
  }
  if (typeof catalogSection === "function") parts.push(...(await catalogSection(a)));
  return parts;
}

function skillRow(a, s) {
  const r = el("button", "row link-row skill-row");
  const t = el("div", "row-text");
  t.append(el("span", null, s.name), el("small", null, s.description));
  const tags = el("div", "skill-tags");
  tags.append(el("span", "tag", ORIGIN[s.origin] ?? s.origin));
  if (s.pinned) tags.append(el("span", "tag", "pinned"));
  if (s.uses) tags.append(el("span", "muted small", `used ${s.uses}×`));
  r.append(t, tags);
  r.onclick = () => openSkill(a, s);
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
    vbox.append(setRow(`Before ${fmtTime(v.at)}`, file, button("Put back", "quiet small", async () => {
      try { await call("skill_revert", { id: a.id, name: s.name, version: v.version, file }); toast("Put back", `${s.name}/${file} as it was`, "good"); openSkill(a, s, file); }
      catch (e) { toast("Couldn't put it back", String(e), "error"); }
    })));
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

/* ---------- Cookie's catalog, and skills from a folder ---------- */
async function catalogSection(a) {
  const items = await call("skill_catalog", { id: a.id }).catch(() => []);
  const out = [el("h3", "group-title", "From Cookie's catalog")];
  const g = el("div", "group");
  for (const it of items) {
    g.append(setRow(it.name, it.description, it.installed ? el("span", "tag", "added") : button("Add", "quiet small", async () => {
      try { await call("install_skill", { id: a.id, folder: it.folder }); toast("Skill added", `${a.name} now has ${it.name}.`, "good"); openProfile("skills"); }
      catch (e) { toast("Couldn't add it", String(e), "error"); }
    })));
  }
  out.push(g);
  if (!Api.web) {
    const f = el("form", "group edit about-add");
    const p = input("", "A folder on this Mac with a SKILL.md, e.g. ~/skills/cold-email");
    f.append(p, button("Add", "quiet small", () => f.requestSubmit()));
    f.onsubmit = async (e) => {
      e.preventDefault();
      try { const n = await call("import_skill", { id: a.id, path: p.value }); toast("Skill added", n, "good"); openProfile("skills"); }
      catch (err) { toast("Couldn't add it", String(err), "error"); }
    };
    out.push(el("h3", "group-title", "From a folder"), f, el("p", "muted small", "Every file is checked first: no secrets, no instructions aimed at the agent, no shell pipes from the internet."));
  }
  out.push(el("p", "muted small", "Catalog skills adapted from Hermes Agent (MIT, Nous Research)."));
  return out;
}

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
