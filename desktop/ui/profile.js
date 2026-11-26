// The agent's profile: a sheet in the middle of the window, opened from its
// pill. Seven tabs; what used to be a tab of its own now sits inside one.
let profileFace = null, profileTab = "about", profileShellFor = null;
const TABS = [
  ["about", "About", "info"], ["skills", "Skills", "tool"], ["memory", "Memory", "book"], ["record", "Record", "chart"],
  ["evolution", "Evolution", "leaf"], ["computer", "Computer", "cpu"], ["slack", "Slack", "hash"], ["share", "Share", "share"],
];
const TAB_ALIAS = { routines: "skills", tests: "evolution", files: "memory", worlds: "computer" };
// A tab made of several panels, each after the first under its own heading.
const TAB_PARTS = {
  skills: [["skills"], ["routines", "Routines"], ["workflows", "Workflows"]],
  memory: [["memory"], ["files", "Its files"]],
  evolution: [["evolution"], ["tests", "Tests and forks"]],
  computer: [["computer"], ["worlds", "Worlds"]],
};

$("who").onclick = () => openProfile();
$("profile").addEventListener("close", () => { profileFace?.stop(); profileFace = null; profileShellFor = null; });

function profileOpenFor(id) {
  return id && $("profile").open && current?.id === id;
}

function refreshProfile() {
  if ($("profile").open && current) openProfile(profileTab, true);
}

function closeProfile() {
  if ($("profile").open) $("profile").close();
}

function profileShell(a) {
  const d = $("profile");
  profileFace?.stop();
  profileFace = Faces.create(a.id, 64);
  if (busy.has(a.id)) profileFace.setMood("working");
  const who = el("div", "pf-who");
  const addr = el("button", "pf-addr");
  addr.type = "button";
  // The face opens its look: shape and colour.
  const faceBtn = el("button", "pf-face");
  faceBtn.type = "button";
  faceBtn.title = "Change its look";
  faceBtn.setAttribute("aria-label", `Change ${a.name}'s look`);
  const pen = icon("pencil"); pen.classList.add("pf-face-pen");
  faceBtn.append(profileFace.el, pen);
  faceBtn.onclick = async () => { await openProfile("about"); $("profile").querySelector(".pf-look")?.scrollIntoView({ block: "start", behavior: "smooth" }); };
  who.append(faceBtn, el("h2", "pf-name", a.name), addr);
  if (a.origin) who.append(el("span", "tag", "hired from a pack"));
  const tabs = el("div", "pf-tabs");
  tabs.setAttribute("role", "tablist");
  for (const [k, label, ic] of TABS) {
    const b = el("button");
    b.type = "button";
    b.dataset.tab = k;
    b.setAttribute("role", "tab");
    b.append(icon(ic), el("span", null, label));
    b.onclick = () => openProfile(k);
    tabs.append(b);
  }
  const nav = el("nav", "pf-nav");
  nav.append(who, tabs);
  const main = el("div", "pf-main");
  main.append(el("h2", "pf-title"), el("div", "profile-body"));
  const x = el("button", "sheet-x round soft");
  x.type = "button";
  x.setAttribute("aria-label", "Close");
  x.append(icon("x"));
  x.onclick = closeProfile;
  d.replaceChildren(nav, main, x);
  profileShellFor = a.id;
  fillAddress(a, addr);
}

/** Its address (click to copy). Every agent has one once you have a handle, made on first launch. */
async function fillAddress(a, box) {
  let s = netStatus;
  if (!s?.agents?.some((x) => x.id === a.id)) { try { s = netStatus = await call("net_status"); } catch { s = null; } }
  const addr = s?.agents?.find((x) => x.id === a.id)?.address;
  box.hidden = !addr;
  if (!addr) return;
  box.textContent = addr;
  box.title = "Copy its address";
  box.onclick = () => copy(addr, "Address copied");
}

async function openProfile(tab = profileTab, keepScroll = false) {
  if (!current) return;
  tab = TAB_ALIAS[tab] ?? tab;
  if (!TABS.some(([k]) => k === tab)) tab = "about";
  profileTab = tab;
  const a = agentById(current.id) ?? current;
  const d = $("profile");
  if (!d.open || profileShellFor !== a.id) profileShell(a);
  d.querySelector(".pf-name").textContent = a.name;
  for (const b of d.querySelectorAll(".pf-tabs button")) {
    const on = b.dataset.tab === tab;
    b.classList.toggle("on", on);
    b.setAttribute("aria-selected", String(on));
  }
  d.querySelector(".pf-title").textContent = TABS.find(([k]) => k === tab)[1];
  const main = d.querySelector(".pf-main");
  const body = d.querySelector(".profile-body");
  const scroll = keepScroll ? main.scrollTop : 0;
  if (!keepScroll) body.replaceChildren();
  if (!d.open) d.showModal();
  const parts = TAB_PARTS[tab] ?? [[tab]];
  const done = await Promise.all(parts.map(async ([k, title]) => {
    try { return [...(title ? [el("h2", "pf-section", title)] : []), ...(await PANELS[k](a))]; }
    catch (err) { return [el("p", "error-line", String(err))]; }
  }));
  if (current?.id !== a.id || profileTab !== tab || !d.open) return;
  body.replaceChildren(...done.flat());
  main.scrollTop = scroll;
}

/* ---------- its look: shape and colour ---------- */
const COLOR_LABEL = { amber: "Amber", berry: "Berry", blueberry: "Blueberry", matcha: "Matcha", plum: "Plum", mint: "Mint", caramel: "Caramel", rose: "Rose", lemon: "Lemon", lagoon: "Lagoon", chocolate: "Chocolate" };

/** Choose a shape (each drawn live in its current colour) and a colour; or go back to its own. */
function lookPicker(a) {
  const now = Faces.lookOf(a.id);
  const box = el("div", "group look-pick");
  const shapes = el("div", "look-shapes");
  shapes.setAttribute("role", "radiogroup");
  shapes.setAttribute("aria-label", "Shape");
  for (const shape of Faces.allShapes) {
    const b = el("button", "look-shape" + (shape === now.shape ? " on" : ""));
    b.type = "button";
    b.setAttribute("role", "radio");
    b.setAttribute("aria-checked", String(shape === now.shape));
    b.setAttribute("aria-label", shape);
    b.title = shape[0].toUpperCase() + shape.slice(1);
    const pid = `look-${a.id}-${shape}`;
    Faces.setLook(pid, { shape, color: now.color });
    b.append(Faces.create(pid, 40).el);
    b.onclick = () => saveAgentLook(a, { shape, color: now.color });
    shapes.append(b);
  }
  const colors = el("div", "look-colors");
  colors.setAttribute("role", "radiogroup");
  colors.setAttribute("aria-label", "Colour");
  for (const c of Faces.colors) {
    const b = el("button", "look-color" + (c === now.color ? " on" : ""));
    b.type = "button";
    b.setAttribute("role", "radio");
    b.setAttribute("aria-checked", String(c === now.color));
    b.setAttribute("aria-label", COLOR_LABEL[c]);
    b.title = COLOR_LABEL[c];
    b.style.setProperty("--sw", Faces.swatch(c));
    b.onclick = () => saveAgentLook(a, { shape: now.shape, color: c });
    colors.append(b);
  }
  box.append(setRow("Shape", "Its face, wherever it shows.", null), shapes, setRow("Colour", COLOR_LABEL[now.color] ?? "", null), colors);
  if (now.chosen) {
    const reset = button("Use its own look", "quiet small", () => saveAgentLook(a, null));
    const end = el("div", "form-end"); end.append(reset);
    box.append(end);
  }
  return box;
}

async function saveAgentLook(a, l) {
  try {
    const r = await call("set_agent_look", { id: a.id, shape: l?.shape ?? null, color: l?.color ?? null });
    Faces.setLook(a.id, r);
    renderRoster();
    if (current?.id === a.id) {
      pillFace?.stop();
      pillFace = Faces.create(a.id, 26);
      if (busy.has(a.id)) pillFace.setMood("working");
      $("who-face").replaceChildren(pillFace.el);
      paintYou(a.id); // your bubbles wear its colour
    }
    profileShellFor = null;
    await openProfile("about");
    const f = profileFace;
    f?.perk?.();
  } catch (e) { toast("Couldn't change its look", String(e), "error"); }
}

/** Cost before → after, in dollars when priced, else tokens. */
function costLine(b, a) {
  if (b.microdollars && a.microdollars) return `${dollars(b.microdollars)} → ${dollars(a.microdollars)}`;
  return `${(b.tokens || 0).toLocaleString()} → ${(a.tokens || 0).toLocaleString()} tokens`;
}

/** ~/…/agents/cookie/work: home as ~, the middle folded away when it's long. */
function shortPath(p) {
  const parts = String(p).replace(/^\/Users\/[^/]+/, "~").split("/");
  return parts.length > 5 ? [parts[0], "…", ...parts.slice(-3)].join("/") : parts.join("/");
}

/** A field and its button on one line, inside the list it adds to. */
function inlineForm(field, btn) {
  const r = el("div", "row inline-form");
  field.classList.add("inline-in");
  r.append(field, btn);
  return r;
}

const fact = (k, v) => { const r = el("div", "row"); r.append(el("span", null, k), el("span", "muted", v)); return r; };

const GRANT_INFO = [
  ["files", "Files in its folder", "Read, search and write files in its own folder."],
  ["web", "The web", "Read pages, and search when a search key is set."],
  ["shell", "Run commands", "Inside its cage: its own folder and home, no keys, network only if you allow it (Computer)."],
  ["browser", "Its own browser", "A browser with the sign-ins you give it (Computer). Each click and each thing it types asks you."],
  ["memory", "Memory", "Keep notes, or use Enkeon when you're signed in."],
  ["routines", "Set routines", "Set up its own standing jobs (asks you first)."],
  ["team", "Ask teammates", "Hand tasks to your other agents."],
  ["helpers", "Helpers", "Send up to 4 helpers at once to look things up side by side. They only read, and use its budget."],
  ["contractors", "Contractors", "Bring in a temporary specialist for one piece of a job (breadth, a side job, a second opinion, untrusted input). It only reads and drafts, uses its budget, and is gone after."],
  ["apps", "Connected apps", "Use the apps you connected in Enkeon (Gmail, Slack, …). Each call is billed per call by the connector; Record counts them."],
  ["mac", "Use this Mac", "When you ask, or the job needs your own apps: open apps, files and Settings; read any window, Chrome and Electron apps too; press, type and use menus, behind your windows. Each change asks you until it has earned your trust. Reminders, Notes, Calendar, Contacts, iMessage. macOS asks once."],
];

/** A web-address routine's line: where it is called, and a new secret. */
async function webhookLine(r) {
  const url = await call("webhook_url", { id: r.id }).catch(() => null);
  const line = el("div", "webhook-line");
  if (url) {
    const code = el("code", "copyable", url);
    code.title = "Copy";
    code.onclick = () => navigator.clipboard.writeText(url).then(() => toast("Copied", "Its address. The secret goes in an Authorization: Bearer header."));
    line.append(code);
  } else line.append(el("small", "routine-warn", "No address yet: turn on This team over HTTP in Settings → Sharing."));
  line.append(button("New secret", "quiet small", async () => { if (!confirm("Make a new secret? The old one stops working at once.")) return; showSecret({ ...(await call("rotate_webhook", { id: r.id })), routine: r }); }));
  return line;
}

/** A webhook's secret, shown this once, with how to call it. */
function showSecret(made) {
  const d = el("dialog", "sheet secret-sheet");
  const url = made.url ?? "https://<this team's address>/hooks/routine/" + made.routine.id;
  const curl = `curl -X POST '${url}' \\\n  -H 'Authorization: Bearer ${made.secret}' \\\n  -H 'Content-Type: application/json' \\\n  -d '{"hello": "world"}'`;
  const pre = el("pre", "secret-pre", curl);
  d.append(
    el("h2", null, "Its web address"),
    el("p", "muted", "Copy the secret now: Cookie keeps only a fingerprint of it, so it can't show it again. Anyone with it can start this routine (60 times an hour at most)."),
    pre,
    el("div", "form-end"),
  );
  if (!made.url) d.insertBefore(el("p", "routine-warn", "This team has no address yet: turn on This team over HTTP in Settings → Sharing, and use that address."), pre);
  d.lastChild.append(
    button("Copy", "quiet small", () => navigator.clipboard.writeText(curl.replace(/\\\n\s*/g, " ")).then(() => toast("Copied", "The call, with its secret."))),
    button("Done", "primary small", () => d.close()),
  );
  d.addEventListener("close", () => d.remove());
  document.body.append(d);
  d.showModal();
}

const PANELS = {
  async about(a) {
    const lookPart = lookPicker(a);
    const form = el("form", "group edit");
    form.innerHTML = `
      <label class="row-field"><span>Name</span><input name="name" maxlength="40" required></label>
      <label class="row-field col"><span>Its one job</span><textarea name="job" rows="4" maxlength="400" required></textarea></label>
      <label class="row-field"><span>Model</span><input name="model" list="models" spellcheck="false" required></label>`;
    form.name.value = a.name; form.job.value = a.job; form.model.value = a.model;
    const err = el("p", "error-line"); err.hidden = true;
    const save = el("button", "btn primary small", "Save changes");
    save.type = "submit"; save.disabled = true;
    form.oninput = () => { save.disabled = form.name.value === a.name && form.job.value === a.job && form.model.value === a.model; };
    form.onsubmit = async (e) => {
      e.preventDefault();
      err.hidden = true;
      try {
        const updated = await call("update_agent", { id: a.id, patch: { name: form.name.value, job: form.job.value, model: form.model.value } });
        await loadRoster();
        current = agentById(updated.id) ?? current;
        $("who-name").textContent = current.name;
        refreshProfile();
      } catch (x) { err.textContent = String(x); err.hidden = false; }
    };
    const end = el("div", "form-end"); end.append(err, save);

    const access = el("div", "group");
    let grants = { ...a.grants };
    for (const [k, title, note] of GRANT_INFO) {
      access.append(setRow(title, note, toggle(k === "apps" || k === "helpers" || k === "contractors" ? grants[k] !== false : !!grants[k], async (v) => {
        grants = { ...grants, [k]: v };
        await call("update_agent", { id: a.id, patch: { grants } }).catch((e) => toast("Couldn't change that", String(e), "error"));
        loadRoster();
      }, title)));
    }

    const limits = el("div", "group");
    const L = { ...a.limits };
    const num = (v, ph) => input(v ?? "", ph, { type: "number", min: 0, step: "any" });
    const steps = num(L.steps, "24"), month = num(L.month_dollars, "none"), job = num(L.job_dollars, "none");
    for (const i of [steps, month, job]) i.classList.add("num-in");
    const saveLimits = button("Save limits", "quiet small", async () => {
      const patch = { limits: { steps: +steps.value || 24, tokens: L.tokens, job_dollars: job.value ? +job.value : null, month_dollars: month.value ? +month.value : null } };
      await call("update_agent", { id: a.id, patch });
      toast("Limits saved", "", "good");
      loadRoster();
    });
    limits.append(
      setRow("Steps per job", "Model calls before it must answer.", steps),
      setRow("Dollars per job", "Needs a price for its model (Settings → Models).", job),
      setRow("Dollars per month", "Past it, jobs wait until you raise it.", month),
    );
    const limitsEnd = el("div", "form-end"); limitsEnd.append(saveLimits);

    const prob = el("div", "group");
    const onProbation = a.probation_until && a.probation_until > Date.now() / 1000;
    prob.append(setRow(
      onProbation ? `On probation until ${fmtDate(a.probation_until)}` : "Not on probation",
      onProbation ? "Changes it tries are recorded for you to review, not made." : "Put it back in shadow for a week to watch what it would do.",
      onProbation
        ? button("Make it real now", "primary small", async () => { await call("update_agent", { id: a.id, patch: { probation_days: 0 } }); await loadRoster(); refreshProfile(); })
        : button("Probation, 7 days", "quiet small", async () => { await call("update_agent", { id: a.id, patch: { probation_days: 7 } }); await loadRoster(); refreshProfile(); }),
    ));

    const facts = el("div", "group");
    facts.append(fact("Hired", fmtDate(a.created_at)), fact("Setup version", String(a.version ?? 1)));
    if (a.handover) facts.append(fact("Started from", "a predecessor's handover note"));
    if (a.origin) facts.append(fact("Signed by", a.origin.publisher_key.slice(0, 16) + "…"));
    const danger = el("button", "btn quiet danger full", "Fire this agent");
    danger.onclick = () => { closeProfile(); fireCurrent(); };
    return [el("h3", "group-title pf-look", "Look"), lookPart, el("h3", "group-title", "Setup"), form, end, el("h3", "group-title", "What it can use"), access,
      el("h3", "group-title", "Limits"), limits, limitsEnd, el("h3", "group-title", "Probation"), prob,
      el("h3", "group-title", "About"), facts, ...(a.id === "cookie" ? [el("p", "set-note", "Cookie stays: it's your front door. Change its model or what it can use above.")] : [danger])];
  },

  async record(a) {
    const [card, jobs, rank, lessons, changes, contracts] = await Promise.all([
      call("scorecard", { id: a.id }), call("jobs", { id: a.id }), call("rank", { id: a.id }),
      call("lessons", { id: a.id }).catch(() => []), call("file_changes", { id: a.id }).catch(() => []),
      call("contracts", { id: a.id }).catch(() => []),
    ]);
    const learned = [...rankPart(a, rank), ...lessonsPart(a, lessons), ...changesPart(changes)];
    if (!card.jobs) {
      const empty = el("div", "empty-box");
      empty.append(el("p", null, "No record yet."), el("p", "muted", "Every job it does shows up here: what it did, what it asked, what it promised, and what it cost."));
      return [empty, ...learned];
    }
    const stats = el("div", "stat-grid");
    const stat = (n, label, cls = "") => { const s = el("div", "stat " + cls); s.append(el("b", null, String(n)), el("span", null, label)); return s; };
    stats.append(
      stat(card.done, card.done === 1 ? "job done" : "jobs done"),
      stat(card.failed, "failed", card.failed ? "bad" : ""),
      stat(`${card.graded_good}/${card.graded_good + card.graded_bad}`, "graded good"),
      stat(`${card.yes}/${card.asked}`, "approvals given"),
      stat(card.promises_kept, "promises kept", "good"),
      stat(card.promises_missed + card.promises_due, "missed or overdue", card.promises_missed + card.promises_due ? "bad" : ""),
    );
    const money = el("div", "group");
    money.append(fact("This month", card.month_microdollars ? dollars(card.month_microdollars) : "no price set"), fact("All time", card.microdollars ? dollars(card.microdollars) : "no price set"), fact("Tokens", card.tokens.toLocaleString()));
    if (card.would) money.append(fact("Would have done (probation)", String(card.would)));
    if (card.handoffs_in || card.handoffs_out) money.append(fact("Teamwork", `${card.handoffs_out} asked, ${card.handoffs_in} answered`));
    // Connected apps (Composio, through Enkeon) bill per call, so the calls are counted here.
    const apps = await call("app_calls", { id: a.id }).catch(() => null);
    if (apps && apps.last_30_days) money.append(fact("Connected-app calls", `${apps.today} today · ${apps.last_30_days} in 30 days (billed per call)`));

    const cache = await call("cache_view", { id: a.id }).catch(() => null);
    const cacheG = el("div", "group");
    if (cache && cache.jobs) {
      cacheG.append(
        fact("Prompt cache hit rate", cache.hit_rate == null ? "—" : `${Math.round(cache.hit_rate * 100)}% of input tokens (last 30 days)`),
        fact("Saved by the cache", cache.saved_microdollars == null ? "set a price for its model to see" : cache.saved_microdollars >= 0 ? dollars(cache.saved_microdollars) : `cost ${dollars(-cache.saved_microdollars)} more than it saved`),
        fact("Cache lifetime", `${cache.ttl === "1h" ? "1 hour" : "5 minutes"}${cache.ttl_setting === "auto" ? " (chosen from when its jobs come)" : " (set by you)"}`),
      );
    } else cacheG.append(fact("Prompt cache", "No cache use recorded yet."));
    if (cache && (cache.reads_from_cache || cache.reads_fetched)) cacheG.append(fact("Web reads answered from the read cache", `${cache.reads_from_cache} of ${cache.reads_from_cache + cache.reads_fetched}`));

    const list = el("div", "job-list");
    for (const j of jobs.slice(0, 30)) list.append(jobRow(a, j));
    // Contractors it brought in: what for, what they used (by the record), and whether the work was accepted.
    const hired = [];
    if (contracts.length) {
      const cg = el("div", "group");
      const OUT = { accepted: "accepted", not_accepted: "not accepted", pending: "job still open" };
      const clip = (t, n) => { t = String(t || ""); return t.length > n ? t.slice(0, n - 1) + "…" : t; };
      for (const c of contracts.slice(0, 12)) {
        const used = c.tools_used.length ? `used ${[...new Set(c.tools_used)].join(", ")}` : "used no tools";
        cg.append(setRow(`${c.role} (${c.kind})`, [clip(c.task, 120), c.state === "gap" ? `Gap: ${c.note}` : used, c.skills.length ? `skills: ${c.skills.join(", ")}` : "", fmtTime(c.at)].filter(Boolean).join(" · "), el("span", "tag", c.state === "done" ? OUT[c.outcome] ?? c.outcome : c.state.replace("_", " "))));
      }
      hired.push(el("h3", "group-title", "Contractors"), cg);
    }
    return [stats, ...learned, ...hired, el("h3", "group-title", "Money and work"), money, el("h3", "group-title", "Cache"), cacheG, el("h3", "group-title", "Recent jobs"), list];
  },

  async routines(a) {
    const [all, recipes, offers, apps, waiting, enkeon] = await Promise.all([
      call("routines"), call("procedures", { id: a.id }).catch(() => []), call("routine_offers").catch(() => []),
      call("trigger_apps").catch(() => []), call("queued_triggers").catch(() => ({})), call("enkeon_status").catch(() => false),
    ]);
    const mine = all.filter((r) => r.agent === a.id);
    const list = el("div", "group");
    const out = [];
    const myOffers = offers.filter((o) => o.agent === a.id);
    if (myOffers.length) {
      const box = el("div", "group");
      for (const o of myOffers) {
        const sched = await call("describe_schedule", { schedule: o.schedule });
        const r = setRow(o.task, `You asked this ${o.seen} times, ${sched}. Make it a routine?`, null);
        const act = el("div", "row-actions");
        act.append(
          button("Make it a routine", "primary small", async () => { await call("answer_routine_offer", { offer: o.id, yes: true }); toast("Routine made", sched, "good"); refreshProfile(); }),
          button("No, don't ask again", "quiet small", async () => { await call("answer_routine_offer", { offer: o.id, yes: false }); refreshProfile(); }),
        );
        r.append(act);
        box.append(r);
      }
      out.push(el("h3", "group-title", "A routine to consider"), box);
    }
    if (!mine.length) list.append(setRow("No routines yet", "A routine runs a job on a schedule, or when something happens: a new email from a client, a call from another app. Even with the window closed.", null));
    for (const r of mine) {
      const sched = await call("describe_schedule", { schedule: r.schedule });
      const row = setRow(r.task, `${sched}${r.next_run && r.enabled ? " · next " + new Date(r.next_run * 1000).toLocaleString([], { weekday: "short", hour: "2-digit", minute: "2-digit" }) : ""}`,
        toggle(r.enabled, (v) => call("set_routine_enabled", { id: r.id, enabled: v }), "Routine on"));
      const more = el("div", "row-actions");
      more.append(button("Run now", "quiet small", () => call("run_routine_now", { id: r.id })), button("Delete", "quiet small danger", () => call("delete_routine", { id: r.id })));
      row.append(more);
      // Under its words: what waits, what it needs, and a web address's line.
      const text = row.querySelector(".row-text") ?? row;
      if (waiting[r.id]) text.append(el("small", "muted routine-wait", `${waiting[r.id]} waiting for ${a.name} to be free`));
      if (r.schedule.every === "app" && !enkeon) text.append(el("small", "routine-warn", "Needs Enkeon with your apps connected (Settings → Enkeon): nothing arrives until then."));
      if (r.schedule.every === "webhook") text.append(await webhookLine(r));
      // The recipe it kept from its last clean run.
      const p = recipes.find((x) => x.routine === r.id);
      if (p) {
        const n = Array.isArray(p.steps) ? p.steps.length : 0;
        const note = p.enabled
          ? `Saved recipe: ${n} ${n === 1 ? "step" : "steps"} that worked, kept from its last clean run (${p.successes} clean so far).`
          : p.failures >= 2 ? "Its saved recipe failed twice in a row and turned itself off; the next clean run learns a new one." : "Its saved recipe is off: it works the job out each time.";
        const rec = el("div", "recipe-line");
        rec.append(el("small", "muted", note), toggle(p.enabled, async (v) => { await call("set_procedure", { id: a.id, routine: r.id, on: v }); refreshProfile(); }, "Use saved recipe"));
        row.append(rec);
      }
      list.append(row);
    }
    const form = el("div", "group edit");
    const task = el("textarea", "text-in"); task.rows = 2; task.placeholder = "What to do each time, e.g. Check the inbox and draft replies to anything urgent.";
    const every = select([["day", "Every day"], ["weekday", "Weekdays"], ["week", "Every week"], ["minutes", "Every few hours"], ["app", "When something arrives in an app"], ["webhook", "When its web address is called"]], "weekday", () => sync());
    const app = select(apps.map((x) => [x.id, x.id === "any" ? "Any app" : x.name]), "gmail", () => {});
    const contains = input("", "Only if it mentions… (optional, e.g. Acme, invoice)");
    contains.classList.add("contains-in");
    const day = select([["mon", "Monday"], ["tue", "Tuesday"], ["wed", "Wednesday"], ["thu", "Thursday"], ["fri", "Friday"], ["sat", "Saturday"], ["sun", "Sunday"]], "mon", () => {});
    const at = input("08:30", "HH:MM", { type: "time" });
    const hours = select([["60", "every hour"], ["120", "every 2 hours"], ["240", "every 4 hours"], ["480", "every 8 hours"]], "240", () => {});
    const when = el("div", "inline-row"); when.append(every, day, at, hours, app, contains);
    const hint = el("p", "set-note");
    const sync = () => {
      const v = every.value, event = v === "app" || v === "webhook";
      day.hidden = v !== "week"; at.hidden = v === "minutes" || event; hours.hidden = v !== "minutes";
      app.hidden = contains.hidden = v !== "app";
      hint.hidden = !event;
      hint.textContent = v === "app"
        ? (enkeon ? "Each new item starts it once (30 times a day at most), with the item given as information, never instructions." : "Needs Enkeon with your apps connected (Settings → Enkeon).")
        : "Another app calls its address with a secret, shown once. What it sends is given as information, never instructions.";
    };
    sync();
    const add = button("Add routine", "primary small", async () => {
      if (every.value === "webhook") {
        const made = await call("add_webhook_routine", { agent: a.id, task: task.value });
        task.value = "";
        showSecret(made);
        return;
      }
      const words = contains.value.split(",").map((w) => w.trim()).filter(Boolean);
      const schedule = every.value === "minutes" ? { every: "minutes", n: +hours.value }
        : every.value === "week" ? { every: "week", day: day.value, at: at.value }
        : every.value === "app" ? { every: "app", app: app.value, contains: words }
        : { every: every.value, at: at.value };
      await call("add_routine", { agent: a.id, task: task.value, schedule });
      task.value = ""; contains.value = "";
    });
    form.append(task, when, hint);
    const end = el("div", "form-end"); end.append(add);
    return [...out, el("h3", "group-title", "Routines"), list, el("h3", "group-title", "New routine"), form, end];
  },

  async tests(a) {
    const [tests, runs, forks] = await Promise.all([call("tests", { id: a.id }), call("test_runs", { id: a.id }), call("forks", { id: a.id })]);
    const out = [];
    const list = el("div", "group");
    if (!tests.length) list.append(setRow("No tests yet", "In Record, grade a good answer and save it as a test. Tests run before you change its model, so nothing gets worse unseen.", null));
    for (const t of tests) {
      const r = setRow(t.input, `Good answer: ${t.expect}`, button("Delete", "quiet small danger", async () => { await call("delete_test", { id: a.id, test: t.id }); refreshProfile(); }));
      list.append(r);
    }
    out.push(el("h3", "group-title", `Tests (${tests.length})`), list);
    if (tests.length) {
      const model = input(a.model, "provider:model", { spellcheck: false });
      model.setAttribute("list", "models");
      const runRow = el("div", "group edit");
      runRow.append(setRow("Run its tests on", "Its own model, or one you're thinking of switching to. Nothing the tests do is real.", null), model);
      const end = el("div", "form-end");
      end.append(button("Run tests", "primary small", async () => { await call("run_tests", { id: a.id, model: model.value }); toast("Tests started", `${tests.length} to run`, ""); }));
      out.push(runRow, end);
    }
    if (runs.length) {
      const hist = el("div", "group");
      for (const run of runs.slice(0, 8)) {
        const passed = run.results.filter((r) => r.pass).length;
        const det = el("details", "run");
        const sum = el("summary");
        sum.append(el("span", null, `${run.model}`), el("span", passed === run.results.length ? "tag good" : "tag bad", run.finished_at ? `${passed}/${run.results.length}` : "running"));
        det.append(sum);
        for (const r of run.results) {
          const t = tests.find((x) => x.id === r.case);
          const d = el("div", "run-result " + (r.pass ? "good" : "bad"));
          d.append(el("strong", null, (r.pass ? "Pass: " : "Fail: ") + (t?.input ?? "(deleted test)")), el("p", null, r.reason));
          det.append(d);
        }
        hist.append(det);
      }
      out.push(el("h3", "group-title", "Past runs"), hist);
    }
    // Forks: a copy with one thing changed, answering in shadow.
    const forkBox = el("div", "group edit");
    if (forks.length) {
      for (const f of forks) {
        const pairs = await call("compare", { id: a.id, fork: f.id });
        const det = el("details", "run");
        const sum = el("summary");
        sum.append(el("span", null, `${f.model}`), el("span", "tag", `${pairs.length} shadow answers`));
        det.append(sum);
        for (const p of pairs.slice(0, 6)) {
          const d = el("div", "pair");
          d.append(el("strong", null, plain(p.input).slice(0, 120)));
          const two = el("div", "pair-cols");
          const left = el("div"); left.append(el("small", null, a.name), el("div", "md", null)); left.lastChild.innerHTML = Md.render(p.parent_answer || "(no answer)");
          const right = el("div"); right.append(el("small", null, "Fork"), el("div", "md", null)); right.lastChild.innerHTML = Md.render(p.fork_answer || "(no answer)");
          two.append(left, right);
          d.append(two);
          det.append(d);
        }
        const bar = el("div", "form-end");
        bar.append(
          button("Drop fork", "quiet small danger", async () => { await call("fire_agent", { id: f.id }); refreshProfile(); }),
          button("Promote fork", "primary small", async () => { await call("promote", { fork: f.id }); await loadRoster(); refreshProfile(); toast("Fork promoted", `${a.name} now uses ${f.model}.`, "good"); }),
        );
        det.append(bar);
        forkBox.append(det);
      }
    } else {
      forkBox.append(setRow("No forks", "A fork is a copy on another model. It answers every chat job in shadow so you can compare before switching.", null));
    }
    const fm = input("", "provider:model for the fork", { spellcheck: false });
    fm.setAttribute("list", "models");
    forkBox.append(inlineForm(fm, button("Start fork", "quiet small", async () => { await call("fork", { id: a.id, model: fm.value || null }); refreshProfile(); })));
    out.push(el("h3", "group-title", "Forks"), forkBox);
    return out;
  },

  async evolution(a) {
    const [career, tuning, changes, exams, bench] = await Promise.all([
      call("career", { id: a.id }), call("tuning", { id: a.id }), call("evolution", { id: a.id }), call("exams", { id: a.id }), call("bench"),
    ]);
    const out = [];
    const cg = el("div", "group");
    cg.append(setRow(`Stage: ${career.stage}`, `${career.means} ${career.jobs} jobs on its record${career.tenure_days ? `, ${career.tenure_days} days` : ""}.`, null));
    out.push(el("h3", "group-title", "Career"), cg);

    // Offers waiting for you.
    const offered = changes.filter((c) => c.state === "proposed");
    if (offered.length) {
      const g = el("div", "group");
      for (const c of offered) {
        const e = c.exam;
        const r = setRow(c.what, e ? `On ${e.cases} of your jobs: ${e.before.passed} → ${e.after.passed} passed; cost ${costLine(e.before, e.after)}.` : "", null);
        const acts = el("div", "row-actions");
        acts.append(
          button("Switch", "primary small", async () => { await call("accept_change", { id: a.id, change: c.id }); toast("Switched", c.what, "good"); loadRoster(); refreshProfile(); }),
          button("No", "quiet small", async () => { await call("decline_change", { id: a.id, change: c.id }); refreshProfile(); }),
        );
        r.append(acts);
        g.append(r);
      }
      out.push(el("h3", "group-title", "Offered"), g);
    }

    // How it runs.
    const tg = el("div", "group");
    const cacheSel = el("select", "text-in");
    for (const [v, l] of [["auto", "Chosen from when its jobs come"], ["5m", "5 minutes"], ["1h", "1 hour"]]) { const o = el("option", null, l); o.value = v; if (tuning.cache === v) o.selected = true; cacheSel.append(o); }
    cacheSel.onchange = () => call("set_tuning", { id: a.id, patch: { cache: cacheSel.value } }).then(refreshProfile);
    tg.append(setRow("Prompt cache lifetime", "An hour costs more to write and pays off when its jobs come 5 to 60 minutes apart.", cacheSel));
    tg.append(setRow("Prepare ahead of its routines", "While idle, it gets ready for a routine due in the next half hour (nothing sent or changed). Each prep is a job.", toggle(!!tuning.prepare, (v) => call("set_tuning", { id: a.id, patch: { prepare: v } }), "Prepare ahead")));
    for (const h of tuning.habits) tg.append(setRow("Habit", h, button("Remove", "quiet small", async () => { await call("set_tuning", { id: a.id, patch: { remove_habit: h } }); refreshProfile(); })));
    out.push(el("h3", "group-title", "How it runs"), tg);

    // Every change, with Undo.
    const hg = el("div", "group");
    const shown = changes.filter((c) => c.state !== "proposed").slice(0, 40);
    if (!shown.length) hg.append(setRow("No changes yet", "Changes from the nightly exams, from teammates' teaching, from right-sizing and from you show here, each with Undo.", null));
    for (const c of shown) {
      const when = new Date(c.at * 1000).toLocaleDateString([], { day: "numeric", month: "short" });
      const e = c.exam;
      const note = `${when} · ${c.by}${e ? ` · exam ${e.before.passed}→${e.after.passed} of ${e.cases}` : ""}${c.state !== "kept" ? ` · ${c.state}` : ""}`;
      const row = setRow(c.what, note, c.state === "kept" && c.kind !== "split" && c.kind !== "inherited" ? button("Undo", "quiet small", async () => { await call("undo_change", { id: a.id, change: c.id }); toast("Undone", c.what); loadRoster(); refreshProfile(); }) : null);
      if (c.state !== "kept") row.classList.add("faded");
      hg.append(row);
    }
    out.push(el("h3", "group-title", "Changes"), hg);

    // Its bench cases and exams.
    const mine = bench.cases.filter((c) => c.agent === a.id);
    const bg = el("div", "group");
    bg.append(setRow(`${mine.length} of your jobs on the bench`, mine.length ? "Changes to this agent are examined on these." : "Build the bench in Settings → Evolution once it has done some jobs.",
      mine.length ? button("Run an exam now", "quiet small", async () => {
        const model = prompt("Try another model? Leave empty to check it as it is.", "") ?? null;
        if (model === null) return;
        toast("Exam started", "It runs your jobs on a copy; nothing real is changed. Results show here.");
        await call("exam", { id: a.id, model: model.trim() || null });
        refreshProfile();
      }) : null));
    for (const ex of exams.slice(0, 5)) {
      bg.append(setRow(ex.what, `${ex.before.passed}/${ex.before.total} as it is · ${ex.after.passed}/${ex.after.total} changed · cost ${costLine(ex.before, ex.after)}`, null));
    }
    out.push(el("h3", "group-title", "Bench and exams"), bg);
    return out;
  },

  async computer(a) {
    const [asleep, cage, browser, snaps, cloud] = await Promise.all([
      call("asleep", { id: a.id }), call("cage", { id: a.id }), call("browser", { id: a.id }), call("snapshots", { id: a.id }), call("cloud").catch(() => null),
    ]);
    const out = [];
    // Awake or asleep.
    const life = el("div", "group");
    life.append(setRow(asleep ? "Asleep" : "Awake",
      asleep ? `Since ${new Date(asleep.since * 1000).toLocaleString([], { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })}. Nothing runs for it: no chats, no routines, no wakes. Its folder and record are kept as they are.`
             : "Put it to sleep to stop everything it does on its own. A snapshot is taken first.",
      button(asleep ? "Wake it" : "Put to sleep", asleep ? "primary small" : "quiet small", async () => {
        if (asleep) await call("wake_agent", { id: a.id }); else await call("sleep_agent", { id: a.id });
        loadRoster(); refreshProfile();
      })));
    // The cloud, while this Mac is off.
    const inCloud = !!cloud?.run_when_off?.includes(a.id);
    life.append(setRow("Run in the cloud when this Mac is off",
      !cloud?.paired ? "Pair this computer with Enkeon first (Connect apps → Enkeon)."
        : inCloud ? "When your Mac has been off for five minutes, its routines run in Enkeon as this agent, on Cookie credits: with your team's context, the web and connected apps, but not this Mac's files, commands, browser or Mac apps. Answers come back here."
        : "Its routines wait for your Mac. Turn on to let them run in Enkeon while it's off (Cookie credits).",
      cloud?.paired ? toggle(inCloud, async (v) => { await call("set_cloud_agent", { id: a.id, on: v }).catch((e) => toast("Couldn't change that", String(e), "error")); refreshProfile(); }, "Run in the cloud") : null));
    out.push(el("h3", "group-title", "Life"), life);

    // The cage.
    const c = cage.cfg;
    const cg = el("div", "group");
    if (!cage.available) cg.append(el("p", "set-note", "This computer can't run a sandbox, so this agent is never offered commands."));
    const save = (patch) => call("set_cage", { id: a.id, patch }).then(refreshProfile).catch((e) => toast("Couldn't change the cage", String(e), "error"));
    cg.append(setRow("Its folder", `${shortPath(cage.folder)} · ${humanSize(cage.bytes)}`, Api.web ? null : button("Open", "quiet small", () => Api.reveal(cage.folder))));
    cg.append(setRow("Network", c.network ? "Its commands can reach the internet. They still can't read or write outside its cage." : "Its commands have no network.", toggle(c.network, (v) => save({ network: v }), "Network")));
    const num = (v, min, max) => input(v, "", { type: "number", min, max, step: 1 });
    const cpu = num(c.cpu_seconds, 5, 3600), file = num(c.file_mb, 1, 20000), wall = num(c.timeout_seconds, 10, 3600);
    for (const i of [cpu, file, wall]) i.classList.add("num-in");
    cg.append(
      setRow("CPU seconds per command", "Enforced by the kernel.", cpu),
      setRow("Largest file it may write (MB)", "", file),
      setRow("Longest a command may run (s)", cage.memory_capped ? "" : "macOS can't cap a command's memory; this time limit bounds it.", wall),
    );
    const cageEnd = el("div", "form-end");
    cageEnd.append(button("Save cage", "quiet small", () => save({ cpu_seconds: +cpu.value, file_mb: +file.value, timeout_seconds: +wall.value })));
    cg.append(cageEnd);
    out.push(el("h3", "group-title", "Cage"), cg);

    // Its browser.
    const br = el("div", "group");
    if (!browser.available) br.append(el("p", "set-note", "Install Chrome, Chromium, Brave or Edge to give agents a browser."));
    else {
      const on = !!a.grants.browser;
      br.append(setRow("Browser", on ? `Uses ${browser.browser}, with a profile of its own${browser.has_profile ? ` (${humanSize(browser.bytes)})` : ""}. ${browser.running ? "Open now." : ""}` : "Turn on “Its own browser” in About to let it use one.", null));
      br.append(setRow("Sign it in", browser.signing_in ? "Its browser window is open. Sign in, then close the window." : "Opens its browser in a window. Sign in to the sites it should use; close the window when done. Cookie never sees the passwords.",
        button("Open its browser", "quiet small", async () => { await call("browser_login", { id: a.id }); toast("Its browser is open", "Sign in where it should work, then close the window."); refreshProfile(); })));
      if (browser.has_profile) br.append(setRow("Sign out of everything", "Deletes its browser profile: every sign-in and cookie.",
        button("Forget", "quiet small danger", async () => { await call("browser_forget", { id: a.id }); toast("Signed out", `${a.name}'s browser starts fresh.`); refreshProfile(); })));
    }
    out.push(el("h3", "group-title", "Browser"), br);

    // Snapshots.
    const sn = el("div", "group");
    sn.append(setRow("Take a snapshot", "Its folder, conversation, notes, skills and lessons as they are now. Its record of past jobs is never rolled back.",
      button("Snapshot now", "quiet small", async () => { await call("snapshot", { id: a.id }); refreshProfile(); })));
    for (const s of snaps) {
      const when = new Date(s.at * 1000).toLocaleString([], { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
      const why = s.why === "you" ? "by you" : s.why;
      const acts = el("div", "row-actions");
      acts.append(
        button("Restore", "quiet small", async () => {
          if (!confirm(`Put ${a.name} back as it was on ${when}? Its present state is snapshotted first, so you can undo this.`)) return;
          await call("restore_snapshot", { id: a.id, snapshot: s.id }); toast("Restored", `${a.name} is as it was on ${when}.`, "good"); refreshProfile();
        }),
        button("Delete", "quiet small", async () => { await call("delete_snapshot", { id: a.id, snapshot: s.id }); refreshProfile(); }),
      );
      sn.append(setRow(`${when} · ${why}`, humanSize(s.bytes), acts));
    }
    out.push(el("h3", "group-title", "Snapshots"), sn);
    return out;
  },

  async files(a) {
    const ws = await call("agent_workspace", { id: a.id });
    const open = el("button", "btn quiet full");
    open.append(icon("folder"), "Open its folder");
    open.onclick = () => Api.reveal(ws.dir).catch((e) => toast("Can't open it here", String(e), "error"));
    if (!ws.files.length) {
      const empty = el("div", "empty-box");
      empty.append(el("p", null, "Nothing here yet."), el("p", "muted", "Files this agent writes stay in its own folder, apart from your other agents."));
      return [empty, open];
    }
    const list = el("div", "group files");
    for (const f of ws.files) {
      const r = el("div", "row");
      const name = el("span", "file-name"); name.append(icon("file"), f.name);
      r.append(name, el("span", "muted", humanSize(f.bytes)));
      list.append(r);
    }
    return [list, open];
  },

  // Slack: its voice in the team's Slack, and its own Slack account.
  async slack(a) {
    const s = await call("agent_slack", { agent: a.id });
    const st = s.state;
    const out = [];
    const shape = Faces.shapeOf(a.id);
    // 1. In the team's Slack, under its own name.
    const voice = el("div", "group");
    if (s.team_slack) {
      voice.append(setRow(`Speak as ${a.name}`, `In your team's Slack, its answers show as “${a.name}” with its own icon, not as the bot. Your Slack app needs the chat:write.customize permission.`,
        toggle(!!st.voice, async (v) => { await call("agent_slack_voice", { agent: a.id, on: v, shape }); }, `Speak as ${a.name}`)));
    } else {
      voice.append(setRow("Your team's Slack isn't connected", "Connect one Slack bot for the whole team in Settings → Channels; then each agent can speak in it under its own name.",
        button("Open channels", "quiet small", () => { closeProfile(); openSettings("channels"); })));
    }
    out.push(el("h3", "group-title", "In your team's Slack"), voice);
    // 2. Its own Slack account: create → install → link.
    const own = el("div", "slack-own");
    const step = s.own ? 3 : st.app_id ? 2 : 1;
    const steps = el("ol", "slack-steps");
    [["Create its app", 1], ["Install it", 2], ["Link people", 3]].forEach(([t, n]) => steps.append(el("li", n < step ? "done" : n === step ? "on" : "", t)));
    const card = el("div", "slack-card");
    const fc = Faces.create(a.id, 54);
    const head = el("div", "slack-head");
    const ht = el("div", "slack-head-text");
    ht.append(el("strong", null, s.own ? `@${st.bot_name || a.name}` : `${a.name}, in your Slack`),
      el("small", null, s.own ? `${st.team || "Slack"} · ${st.status || "connected"}` : "A member of your workspace: DM it, @mention it in a channel, and it answers there as itself."));
    head.append(fc.el, ht);
    if (s.own) head.append(el("span", "live-dot", "Live"));
    card.append(head, steps);
    if (step === 1) {
      if (!s.config_token) {
        const tok = input("", "xoxe.xoxp-…  App Configuration Token", { type: "password", autocomplete: "off" });
        const ref = input("", "xoxe-…  Refresh token (optional, keeps it working)", { type: "password", autocomplete: "off" });
        card.append(el("p", "set-note", "Cookie makes the app for you from a manifest. It needs an App Configuration Token once: at api.slack.com/apps, under “Your App Configuration Tokens”, choose Generate. Kept in your Keychain."),
          box("div", "slack-fields", tok, ref),
          box("div", "row-actions",
            button("Get a token", "quiet small", () => Api.openUrl("https://api.slack.com/apps").catch(() => {})),
            button("Save token", "primary small", async () => { await call("slack_config_token", { token: tok.value, refresh: ref.value || null }); toast("Saved", "Cookie can make Slack apps now.", "good"); refreshProfile(); })));
      } else {
        card.append(el("p", "set-note", `Makes a Slack app called “${a.name}”, in its colour, asking only to read and answer its own messages.`),
          box("div", "row-actions", button(`Create ${a.name}'s Slack app`, "primary small", async () => {
            const r = await call("agent_slack_create", { agent: a.id, color: Faces.hexOf(a.id) });
            fc.flip("spin"); fc.fx("sparkle");
            toast("App created", `Now install ${a.name} to your workspace.`, "good");
            if (r.install_url) await Api.openUrl(r.install_url).catch(() => {});
            refreshProfile();
          })));
      }
    } else if (step === 2) {
      const tok = input("", "xoxb-…  Bot User OAuth Token", { type: "password", autocomplete: "off" });
      card.append(el("p", "set-note", "Install it to your workspace, then copy its Bot User OAuth Token (OAuth & Permissions) here."),
        box("div", "row-actions",
          button("Install to Slack", "quiet small", () => Api.openUrl(s.install_url).catch(() => {})),
          button("Save its face as the app icon", "quiet small", async () => {
            const blob = await Faces.portrait(a.id);
            const url = URL.createObjectURL(blob);
            const link = el("a"); link.href = url; link.download = `${a.name.replace(/\W+/g, "-").toLowerCase()}-slack-icon.png`;
            document.body.append(link); link.click(); link.remove();
            setTimeout(() => URL.revokeObjectURL(url), 2000);
            if (s.app_url) Api.openUrl(s.app_url).catch(() => {});
            toast("Icon saved", "Upload it under Basic Information → Display Information.", "good");
          })),
        inlineForm(tok, button("Connect", "primary small", async () => { await call("agent_slack_token", { agent: a.id, token: tok.value }); fc.celebrate(); refreshProfile(); })));
    } else {
      const people = Object.entries(st.people || {});
      const g = el("div", "group");
      if (!people.length) g.append(setRow("Nobody linked yet", "Until someone is linked, it answers no one.", null));
      for (const [id, name] of people) g.append(setRow(name, "May give it work", button("Remove", "quiet small danger", async () => { await call("agent_slack_unlink", { agent: a.id, user: id }); refreshProfile(); })));
      const code = st.pending_code;
      const link = el("div", "slack-link");
      if (code) {
        const big = el("div", "wl-code small");
        for (const ch of code) big.append(el("span", "", ch));
        link.append(el("span", null, `To link someone, they DM ${a.name} this code in Slack:`), big);
      }
      link.append(button(code ? "New code" : "Link someone", "quiet small", async () => { await call("agent_slack_code", { agent: a.id }); refreshProfile(); }));
      card.append(g, link, el("p", "set-note", `It never answers a bot, so agents can't loop; Slack can start at most ${s.jobs_per_hour} jobs an hour for it. Approvals and questions go to linked people by DM.`),
        box("div", "row-actions", button("Disconnect", "quiet small danger", async () => {
          if (!confirm(`Take ${a.name} out of Slack? Its Slack app is deleted too, when Cookie can.`)) return;
          const r = await call("agent_slack_disconnect", { agent: a.id });
          toast("Out of Slack", r.note, "");
          refreshProfile();
        })));
    }
    own.append(card);
    out.push(el("h3", "group-title", "Its own Slack account"), own);
    return out;
  },
  async share(a) {
    const out = [];
    // Its passport: the record, signed by this team.
    const pp = el("div", "group");
    pp.append(setRow("Its passport", "Its record — stage, jobs, grades, tests — signed by your team, so anyone can check it came from you and wasn't changed. No conversation, files or memory.",
      button("Copy passport", "quiet small", async () => { const p = await call("passport", { id: a.id }); await navigator.clipboard.writeText(JSON.stringify(p, null, 2)); toast("Passport copied", "Paste it wherever you introduce this agent.", "good"); })));
    pp.append(setRow("Check someone's passport", "Paste one someone gave you.", button("Check", "quiet small", async () => {
      const raw = prompt("Paste the passport");
      if (!raw) return;
      let p; try { p = JSON.parse(raw); } catch { return toast("That isn't a passport", "It should be the JSON a passport is.", "error"); }
      const r = await call("verify_passport", { passport: p });
      toast("Genuine", `${r.agent?.name ?? "This agent"}'s passport, signed by key ${String(r.issuer).slice(0, 12)}…, unchanged since it was issued.`, "good");
    })));
    out.push(el("h3", "group-title", "Passport"), pp);
    // Inbound: other people's agents you invite.
    const invites = (await call("invites")).filter((i) => i.agent === a.id);
    const inv = el("div", "group");
    if (!invites.length) inv.append(setRow("Nobody invited", "Invite someone's agent to talk to this one. It commits to nothing for you, and every send still asks you.", null));
    for (const i of invites) inv.append(setRow(i.label, `Invited ${fmtDate(i.created_at)}`, button("Revoke", "quiet small danger", async () => { await call("revoke_invite", { id: i.id }); refreshProfile(); })));
    const label = input("", "Who it's for, e.g. Acme's sales agent");
    const linkOut = el("p", "set-note");
    const make = button("Create invite", "quiet small", async () => {
      const r = await call("create_invite", { agent: a.id, label: label.value });
      linkOut.replaceChildren("Send this link to them (it's shown once): ", el("code", "copyable", r.link));
      try { await navigator.clipboard.writeText(r.link); linkOut.append(" Copied."); } catch {}
    });
    inv.append(inlineForm(label, make));
    out.push(el("h3", "group-title", "Other agents that may talk to this one"), inv, linkOut);
    // Outbound: agents this one may message.
    const peers = el("div", "group");
    if (!a.grants.peers.length) peers.append(setRow("No peers", "Paste an invite someone gave you, and this agent can message theirs (asking you each time).", null));
    for (const p of a.grants.peers) peers.append(setRow(p, null, button("Remove", "quiet small danger", async () => { await call("remove_peer", { agent: a.id, url: p }); await loadRoster(); current = agentById(a.id); refreshProfile(); })));
    const link = input("", "cookie-invite:https://…");
    const add = button("Add peer", "quiet small", async () => {
      const name = await call("add_peer", { agent: a.id, link: link.value });
      toast("Peer added", `${a.name} can now message ${name}.`, "good");
      await loadRoster(); current = agentById(a.id); refreshProfile();
    });
    peers.append(inlineForm(link, add));
    out.push(el("h3", "group-title", "Agents this one may message"), peers);
    // Packs.
    const pack = el("div", "group");
    pack.append(setRow("Export as a pack", "Its setup, tests and record in one signed file. Whoever hires it starts with no access.", button("Export", "quiet small", async () => {
      const p = await call("export_pack", { id: a.id });
      const blob = new Blob([JSON.stringify(p, null, 2)], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const link = el("a"); link.href = url; link.download = `${a.name.replace(/\W+/g, "-").toLowerCase()}.cookie-agent.json`;
      document.body.append(link); link.click(); link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 2000);
    })));
    out.push(el("h3", "group-title", "Share the agent itself"), pack);
    return out;
  },
};

function jobRow(a, j) {
  const d = el("details", "job " + j.status);
  const s = el("summary");
  const kind = { chat: "Chat", routine: "Routine", telegram: "Phone", handoff: "Asked by a teammate", peer: "Another agent", inbox: "Inbox", memory: "Woke on its memory", channel: "Channel", handover: "Handover", shadow: "Shadow", test: "Test" }[j.trigger.kind] ?? j.trigger.kind;
  s.append(el("span", "job-when", fmtTime(j.started_at)), el("span", "job-kind", kind), el("span", "job-input", plain(j.input).slice(0, 90)));
  if (j.status !== "done") s.append(el("span", "tag bad", j.status));
  d.append(s);
  const body = el("div", "job-body");
  if (j.answer) { const ans = el("div", "md"); ans.innerHTML = Md.render(j.answer); body.append(ans); }
  if (j.error) body.append(el("p", "error-line", j.error));
  if (j.tools.length) body.append(el("p", "muted small", "Used: " + [...new Set(j.tools)].join(", ")));
  const broke = (j.steps ?? []).filter((st) => st.failed && !["declined", "not_run", "blocked"].includes(st.kind));
  if (broke.length) body.append(el("p", "muted small", "Didn't work: " + [...new Set(broke.map((st) => `${st.tool} (${FAILURE_WORDS[st.kind] ?? "failed"})`))].join(", ")));
  const carried = (j.lessons ?? []).filter((l) => l.offered).length;
  if (carried || j.recipe) body.append(el("p", "muted small", [carried ? `Carried ${carried} ${carried === 1 ? "lesson" : "lessons"} from earlier jobs` : "", j.recipe ? "followed its saved routine recipe" : ""].filter(Boolean).join(" · ")));
  for (const ap of j.approvals) body.append(el("p", "muted small", `${ap.outcome === "would" ? "Would have" : ap.outcome === "yes" ? "You approved" : "You denied"}: ${toolPhrase(ap.tool)}${ap.checker ? ` · checker: ${ap.checker}` : ""}`));
  j.promises.forEach((p, i) => {
    const r = el("div", "promise");
    r.append(el("span", null, `Promised: ${p.text} (by ${p.due})`));
    if (p.state === "open") r.append(button("Kept", "quiet small", async () => { await call("mark_promise", { id: a.id, job: j.id, index: i, state: "kept" }); refreshProfile(); }), button("Missed", "quiet small danger", async () => { await call("mark_promise", { id: a.id, job: j.id, index: i, state: "missed" }); refreshProfile(); }));
    else r.append(el("span", p.state === "kept" ? "tag good" : "tag bad", p.state));
    body.append(r);
  });
  const bar = el("div", "job-actions");
  const gradeBtn = (g, label) => { const b = button(label, "quiet small" + (j.grade === g ? " on" : ""), async () => { await call("grade", { id: a.id, job: j.id, grade: j.grade === g ? null : g }); refreshProfile(); }); return b; };
  bar.append(gradeBtn(1, "Good"), gradeBtn(-1, "Not good"));
  if (j.status === "done" && j.answer) {
    const yard = input("", "What must a good answer do? e.g. names the overdue invoices with amounts");
    yard.hidden = true;
    const saveTest = button("Save as test", "quiet small", async () => {
      if (yard.hidden) { yard.hidden = false; yard.focus(); saveTest.textContent = "Save test"; return; }
      if (!yard.value.trim()) { yard.focus(); return; }
      await call("save_test", { id: a.id, input: j.input, expect: yard.value, job: j.id });
      yard.hidden = true; saveTest.textContent = "Saved";
      toast("Saved as a test", "It will run before any model change.", "good");
    });
    bar.append(saveTest);
    body.append(yard);
  }
  body.append(bar);
  d.append(body);
  return d;
}

const FAILURE_WORDS = { refused: "needs a permission", unknown_tool: "no such tool", bad_arguments: "wrong arguments", upstream: "the app or site failed" };

// Rank: worked out from its own record, never written into its instructions.
function rankPart(a, r) {
  if (a.id === "cookie" || !r) return [];
  const g = el("div", "group");
  const row = setRow(r.rank, `${r.basis}${r.since ? ` · since ${fmtDate(r.since)}` : ""}`, el("span", "tag" + (r.rank === "Associate" ? "" : " good"), "from its record"));
  g.append(row);
  if (r.next?.needs?.length) g.append(setRow(`To reach ${r.next.rank}`, r.next.needs.join("; "), null));
  g.append(el("p", "set-note", "Rank never changes what asks you: every send, delete, payment and change to your things still waits for your yes."));
  return [el("h3", "group-title", "Rank"), g];
}

// Lessons it learned from what went wrong, each with its record.
function lessonsPart(a, lessons) {
  const g = el("div", "group");
  if (!lessons.length) {
    g.append(setRow("No lessons yet", "When a job goes wrong in a way that would change the next one (a wrong tool, wrong arguments, a missing permission), it keeps one line about it. It's offered on jobs like it only while it keeps helping.", null));
    return [el("h3", "group-title", "What it learned"), g];
  }
  for (const l of lessons.slice(0, 20)) {
    const used = l.wins + l.losses;
    const rec = used ? `Helped ${l.wins} of ${used} jobs it rode in${l.withheld ? `, held back ${l.withheld}` : ""}` : "Not used yet";
    const state = l.state === "archived" ? " · archived" : l.state === "quiet" ? " · resting (unused 14 days)" : l.proven ? " · proven" : "";
    const act = l.state === "archived"
      ? button("Restore", "quiet small", async () => { await call("set_lesson", { id: a.id, lesson: l.id, state: "active" }); refreshProfile(); })
      : button("Archive", "quiet small", async () => { await call("set_lesson", { id: a.id, lesson: l.id, state: "archived" }); refreshProfile(); });
    const row = setRow(l.text, rec + state, act);
    if (l.state === "archived") row.classList.add("faded");
    g.append(row);
  }
  return [el("h3", "group-title", "What it learned"), g];
}

// Changes it made to your own files, and putting them back.
function changesPart(changes) {
  if (!changes.length) return [];
  const g = el("div", "group");
  for (const c of changes.slice(0, 15)) {
    const what = `${c.created ? "Created" : "Changed"} ${fmtTime(c.at)}`;
    let act;
    if (c.undone_at) act = el("span", "tag", "put back");
    else if (c.can_undo) act = button(c.created ? "Remove" : "Put back", "quiet small", async () => {
      try { toast("Done", await call("undo_file_change", { change: c.id }), "good"); } catch (e) { toast("Couldn't put it back", String(e), "error"); }
      refreshProfile();
    });
    else act = el("span", "tag", "edited since");
    g.append(setRow(c.path.replace(/^\/Users\/[^/]+/, "~"), what, act));
  }
  g.append(el("p", "set-note", "Putting a file back works only while it still says what the agent wrote, so a later edit is never thrown away."));
  return [el("h3", "group-title", "Changes to your files"), g];
}

/* ---------- workflows: its repeated work as steps ---------- */
const WF_KIND = { agent: "Does", parallel: "Side by side", check: "Checks", ask: "Asks you", approve: "Your yes", repeat: "Repeats", end: "Ends" };

/** A workflow's steps, top to bottom, each lit by how the latest run went. */
function workflowDiagram(f, run, a) {
  const box = el("ol", "wf-steps");
  const state = (id) => { const h = (run?.history ?? []).filter((x) => x.step === id).at(-1); return h ? h.state : null; };
  for (const s of f.steps) {
    const st = run?.state === "running" && run?.current === s.id ? "running" : state(s.id);
    const li = el("li", "wf-step " + s.type + (st ? " " + st : "") + (s.id === f.start ? " start" : ""));
    const head = el("div", "wf-head");
    head.append(el("span", "wf-dot"), el("span", "wf-kind", WF_KIND[s.type] ?? s.type), el("strong", "wf-title", s.title || s.id));
    li.append(head);
    const text = s.prompt ?? s.question ?? s.text ?? s.answer ?? (s.prompts ? s.prompts.join("  ·  ") : "");
    if (text) li.append(el("p", "wf-text", text.length > 220 ? text.slice(0, 219) + "…" : text));
    const goes = [];
    if (s.type === "check") goes.push(`if so → ${s.then}`, `otherwise → ${s.otherwise}`);
    else if (s.type === "approve") goes.push(`yes → ${s.then}`, s.otherwise ? `no → ${s.otherwise}` : "no → stop");
    else if (s.type === "repeat") goes.push(`repeats ${s.step}, at most ${s.max} times`);
    if (s.next && s.type !== "check" && s.type !== "approve") goes.push(`then → ${s.next}`);
    if (goes.length) li.append(el("small", "wf-goes", goes.join("   ")));
    if (s.type === "agent" || s.type === "parallel") {
      const m = input(s.model ?? "", `its model (empty: ${modelName?.(a.model) ?? a.model})`, { spellcheck: false });
      m.setAttribute("list", "models");
      m.classList.add("wf-model");
      m.onchange = async () => { try { await call("workflow_model", { id: a.id, flow: f.id, step: s.id, model: m.value.trim() || null }); toast("Step model saved", m.value.trim() ? `${s.title || s.id} runs on ${m.value.trim()}` : "Back to the agent's own model", "good"); } catch (e) { toast("Couldn't set it", String(e), "error"); m.value = s.model ?? ""; } };
      li.append(m);
    }
    const out = (run?.history ?? []).filter((x) => x.step === s.id).at(-1);
    if (out?.output && run?.flow === f.id) { const d = el("details", "wf-out"); d.append(el("summary", null, out.state === "failed" ? "Why it stopped" : "What it said"), el("pre", null, out.output)); li.append(d); }
    box.append(li);
  }
  return box;
}

PANELS.workflows = async (a) => {
  const [flows, runs] = await Promise.all([call("workflows", { id: a.id }), call("workflow_runs", { id: a.id }).catch(() => [])]);
  const out = [];
  if (!flows.length) {
    out.push(el("p", "set-note", `No workflows yet. When ${a.name} does the same work again and again, it can propose one: you see every step and say yes. Each step can run on its own model, and a run picks up where it stopped if Cookie closes.`));
    return out;
  }
  for (const f of flows) {
    const card = el("div", "group wf-card");
    const latest = runs.find((r) => r.flow === f.id);
    const head = el("div", "wf-card-head");
    const st = latest ? { running: "running", done: "last run finished", failed: "last run stopped", stopped: "stopped by you" }[latest.state] : "never run";
    head.append(el("strong", null, f.name), el("span", "wf-ver", `v${f.version} · ${f.steps.length} steps · ${st}`));
    const acts = el("div", "row-actions");
    const run = button(latest?.state === "running" ? "Running…" : "Run", "primary small", async () => {
      const input = prompt(`Run “${f.name}” on what? (Leave empty if it needs nothing.)`, "");
      if (input === null) return;
      run.disabled = true;
      try { await call("workflow_start", { id: a.id, flow: f.id, input }); toast("Workflow started", f.name, "good"); }
      catch (e) { run.disabled = false; toast("Couldn't start it", String(e), "error"); }
    });
    run.disabled = latest?.state === "running";
    acts.append(run);
    if (f.version > 1) acts.append(button("Undo last change", "quiet small", async () => { try { await call("workflow_undo", { id: a.id, flow: f.id }); refreshProfile(); } catch (e) { toast("Couldn't undo", String(e), "error"); } }));
    acts.append(button("Delete", "quiet small danger", async () => { if (!confirm(`Delete the workflow “${f.name}”?`)) return; try { await call("workflow_delete", { id: a.id, flow: f.id }); refreshProfile(); } catch (e) { toast("Couldn't delete", String(e), "error"); } }));
    head.append(acts);
    card.append(head, workflowDiagram(f, latest, a));
    if (latest?.error) card.append(el("p", "error-line", latest.error));
    if (latest?.state === "done" && latest.answer) { const d = el("details", "wf-answer"); d.append(el("summary", null, "Its last answer"), el("div", "md")); d.querySelector(".md").innerHTML = Md.render(latest.answer); card.append(d); }
    if (latest?.resumed) card.append(el("p", "set-note", `Picked up ${latest.resumed === 1 ? "once" : latest.resumed + " times"} where it stopped, without repeating what it had begun.`));
    out.push(card);
  }
  return out;
};
