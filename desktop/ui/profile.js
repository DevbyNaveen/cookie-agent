// The agent's profile: its setup and walls, its record, its routines, its
// tests and forks, its folder, and who else may talk to it.
let profileFace = null, profileTab = "about";
const TABS = [["about", "About"], ["skills", "Skills"], ["record", "Record"], ["routines", "Routines"], ["tests", "Tests"], ["files", "Files"], ["computer", "Computer"], ["share", "Share"]];

$("who").onclick = () => ($("profile").hidden ? openProfile() : closeProfile());

function profileOpenFor(id) {
  return id && !$("profile").hidden && current?.id === id;
}

function refreshProfile() {
  if (!$("profile").hidden && current) openProfile(profileTab, true);
}

function closeProfile() {
  $("profile").hidden = true;
  document.querySelector(".pane").classList.remove("with-profile");
  profileFace?.stop();
}

async function openProfile(tab = profileTab, keepScroll = false) {
  if (!current) return;
  profileTab = tab;
  const a = agentById(current.id) ?? current;
  const box = $("profile");
  const scroll = keepScroll ? box.scrollTop : 0;
  document.querySelector(".pane").classList.add("with-profile");
  box.hidden = false;
  profileFace?.stop();
  profileFace = Faces.create(a.id, 84);
  if (busy.has(a.id)) profileFace.setMood("working");
  const x = el("button", "round soft profile-x");
  x.setAttribute("aria-label", "Close profile");
  x.append(icon("x"));
  x.onclick = closeProfile;
  const head = el("div", "profile-head");
  head.append(profileFace.el, el("h2", null, a.name), el("p", "profile-model", a.model));
  if (a.origin) head.append(el("span", "tag", "hired from a pack"));
  const tabs = el("div", "seg tabs-wrap");
  for (const [k, label] of TABS) {
    const b = el("button", k === tab ? "on" : "", label);
    b.onclick = () => openProfile(k);
    tabs.append(b);
  }
  const body = el("div", "profile-body");
  box.replaceChildren(x, head, tabs, body);
  try {
    const parts = await PANELS[tab](a);
    if (current?.id !== a.id || profileTab !== tab) return;
    body.append(...parts);
  } catch (err) {
    body.append(el("p", "error-line", String(err)));
  }
  box.scrollTop = scroll;
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
  ["mac", "Mac apps", "Reminders, Notes, Calendar, Contacts; send iMessages (each asks you). macOS asks once per app."],
];

const PANELS = {
  async about(a) {
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
      access.append(setRow(title, note, toggle(!!grants[k], async (v) => {
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
    danger.onclick = fireCurrent;
    return [el("h3", "group-title", "Setup"), form, end, el("h3", "group-title", "What it can use"), access,
      el("h3", "group-title", "Limits"), limits, limitsEnd, el("h3", "group-title", "Probation"), prob,
      el("h3", "group-title", "About"), facts, ...(a.id === "cookie" ? [el("p", "set-note", "Cookie stays: it's your front door. Change its model or what it can use above.")] : [danger])];
  },

  async record(a) {
    const [card, jobs, rank, lessons, changes] = await Promise.all([
      call("scorecard", { id: a.id }), call("jobs", { id: a.id }), call("rank", { id: a.id }),
      call("lessons", { id: a.id }).catch(() => []), call("file_changes", { id: a.id }).catch(() => []),
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

    const list = el("div", "job-list");
    for (const j of jobs.slice(0, 30)) list.append(jobRow(a, j));
    return [stats, ...learned, el("h3", "group-title", "Money and work"), money, el("h3", "group-title", "Recent jobs"), list];
  },

  async routines(a) {
    const [all, recipes, offers] = await Promise.all([call("routines"), call("procedures", { id: a.id }).catch(() => []), call("routine_offers").catch(() => [])]);
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
    if (!mine.length) list.append(setRow("No routines yet", "A routine runs a job on a schedule, even with the window closed.", null));
    for (const r of mine) {
      const sched = await call("describe_schedule", { schedule: r.schedule });
      const row = setRow(r.task, `${sched}${r.next_run && r.enabled ? " · next " + new Date(r.next_run * 1000).toLocaleString([], { weekday: "short", hour: "2-digit", minute: "2-digit" }) : ""}`,
        toggle(r.enabled, (v) => call("set_routine_enabled", { id: r.id, enabled: v }), "Routine on"));
      const more = el("div", "row-actions");
      more.append(button("Run now", "quiet small", () => call("run_routine_now", { id: r.id })), button("Delete", "quiet small danger", () => call("delete_routine", { id: r.id })));
      row.append(more);
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
    const every = select([["day", "Every day"], ["weekday", "Weekdays"], ["week", "Every week"], ["minutes", "Every few hours"]], "weekday", () => sync());
    const day = select([["mon", "Monday"], ["tue", "Tuesday"], ["wed", "Wednesday"], ["thu", "Thursday"], ["fri", "Friday"], ["sat", "Saturday"], ["sun", "Sunday"]], "mon", () => {});
    const at = input("08:30", "HH:MM", { type: "time" });
    const hours = select([["60", "every hour"], ["120", "every 2 hours"], ["240", "every 4 hours"], ["480", "every 8 hours"]], "240", () => {});
    const when = el("div", "inline-row"); when.append(every, day, at, hours);
    const sync = () => { day.hidden = every.value !== "week"; at.hidden = every.value === "minutes"; hours.hidden = every.value !== "minutes"; };
    sync();
    const add = button("Add routine", "primary small", async () => {
      const schedule = every.value === "minutes" ? { every: "minutes", n: +hours.value } : every.value === "week" ? { every: "week", day: day.value, at: at.value } : { every: every.value, at: at.value };
      await call("add_routine", { agent: a.id, task: task.value, schedule });
      task.value = "";
    });
    form.append(task, when);
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
    const fe = el("div", "form-end");
    fe.append(button("Start fork", "quiet small", async () => { await call("fork", { id: a.id, model: fm.value || null }); refreshProfile(); }));
    forkBox.append(fm);
    out.push(el("h3", "group-title", "Forks"), forkBox, fe);
    return out;
  },

  async computer(a) {
    const [asleep, cage, browser, snaps] = await Promise.all([
      call("asleep", { id: a.id }), call("cage", { id: a.id }), call("browser", { id: a.id }), call("snapshots", { id: a.id }),
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
    out.push(el("h3", "group-title", "Life"), life);

    // The cage.
    const c = cage.cfg;
    const cg = el("div", "group");
    if (!cage.available) cg.append(el("p", "set-note", "This computer can't run a sandbox, so this agent is never offered commands."));
    const save = (patch) => call("set_cage", { id: a.id, patch }).then(refreshProfile).catch((e) => toast("Couldn't change the cage", String(e), "error"));
    cg.append(setRow("Its folder", `${cage.folder} · ${humanSize(cage.bytes)}`, Api.web ? null : button("Open", "quiet small", () => Api.reveal(cage.folder))));
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

  async share(a) {
    const out = [];
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
    const invForm = el("div", "group edit"); invForm.append(label);
    const invEnd = el("div", "form-end"); invEnd.append(make);
    out.push(el("h3", "group-title", "Other agents that may talk to this one"), inv, invForm, invEnd, linkOut);
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
    const pf = el("div", "group edit"); pf.append(link);
    const pe = el("div", "form-end"); pe.append(add);
    out.push(el("h3", "group-title", "Agents this one may message"), peers, pf, pe);
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
