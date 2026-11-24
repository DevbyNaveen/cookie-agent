// Today: the home screen. What needs you, what's promised, who's waiting on
// you, what your team is doing, and hires Scout thinks you'd want.
let inboxResult = null, inboxRunning = false;

function openToday() {
  current = null;
  closePops();
  show("today");
  renderRoster();
  renderToday();
}

async function renderToday() {
  // The agents with news since you last looked hop in turn down the list: a standup.
  try {
    const seenAt = Number(sessionStorage.getItem("cookie.today.seen") || 0);
    const fresh = [...new Set(notices.filter((n) => n.at > seenAt && agentById(n.agent)).map((n) => n.agent))];
    if (fresh.length) setTimeout(() => Faces.wave(fresh, 180), 250);
    sessionStorage.setItem("cookie.today.seen", String(Date.now()));
  } catch {}
  if (view !== "today") return;
  const box = $("today-body");
  const parts = [];
  const hour = new Date().getHours();
  const hello = el("div", "today-hero");
  hello.append(el("h1", null, hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"), el("p", "muted", summaryLine()));
  parts.push(hello);

  // Needs your yes.
  if (approvals.length) {
    parts.push(el("h2", "today-h", `Needs your yes (${approvals.length})`));
    for (const a of approvals) parts.push(approvalCard(a));
  }

  // Questions your agents asked.
  if (questions.length) {
    parts.push(el("h2", "today-h", `Asked you (${questions.length})`));
    for (const q of questions) parts.push(questionCard(q));
  }

  // Working right now.
  const working = rows.filter((r) => busy.has(r.id));
  if (working.length) {
    parts.push(el("h2", "today-h", "Working now"));
    const list = el("div", "group");
    for (const r of working) {
      const row = el("button", "row link-row");
      const f = Faces.create(r.id, 28); f.setMood("working");
      const t = el("div", "row-text"); t.append(el("span", null, r.name), el("small", null, statusOf.get(r.id) ?? "Working…"));
      row.append(f.el, t);
      row.onclick = () => openAgent(r.id);
      list.append(row);
    }
    parts.push(list);
  }

  // Promised.
  const promises = await call("open_promises").catch(() => []);
  if (promises.length) {
    parts.push(el("h2", "today-h", "Promised"));
    const list = el("div", "group");
    const today = new Date().toISOString().slice(0, 10);
    for (const p of promises.slice(0, 12)) {
      const r = setRow(p.text, `${p.agent_name} · by ${p.due}${p.due < today ? " · overdue" : ""}`, null);
      if (p.due < today) r.classList.add("overdue");
      const acts = el("div", "row-actions");
      acts.append(
        button("Kept", "quiet small", async () => { await call("mark_promise", { id: p.agent, job: p.job, index: p.index, state: "kept" }); renderToday(); }),
        button("Missed", "quiet small danger", async () => { await call("mark_promise", { id: p.agent, job: p.job, index: p.index, state: "missed" }); renderToday(); }),
      );
      r.append(acts);
      list.append(r);
    }
    parts.push(list);
  }

  // Who's waiting on you (mail, through Enkeon).
  parts.push(el("h2", "today-h", "Who's waiting on you"));
  parts.push(inboxCard());

  // Scout.
  const ideas = await call("scout").catch(() => []);
  if (ideas.length) {
    parts.push(el("h2", "today-h", "Scout noticed"));
    for (const idea of ideas) {
      const c = el("div", "idea");
      const f = Faces.create("scout-" + idea.id, 36);
      const t = el("div", "row-text");
      t.append(el("strong", null, `You did "${idea.steps.join(" → ")}" in ${idea.app} on ${idea.days} days`), el("small", null, "Want an agent for it? Cookie can't press buttons in other apps; this agent prepares the work and reminds you."));
      const acts = el("div", "row-actions");
      acts.append(
        button("Not now", "quiet small", async () => { await call("scout_dismiss", { proposal: idea.id }); renderToday(); }),
        button("Hire", "primary small", () => openHire({ name: idea.name, job: idea.job })),
      );
      c.append(f.el, t, acts);
      parts.push(c);
    }
  }

  // News this session.
  if (notices.length) {
    parts.push(el("h2", "today-h", "Recent news"));
    const list = el("div", "group");
    for (const n of notices.slice(0, 10)) {
      const r = el("button", "row link-row");
      const f = Faces.create(n.agent, 28);
      const t = el("div", "row-text"); t.append(el("span", null, n.title), el("small", null, plain(n.body).slice(0, 160)));
      r.append(f.el, t, el("span", "muted small", new Date(n.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })));
      r.onclick = () => openAgent(n.agent);
      list.append(r);
    }
    parts.push(list);
  }

  if (!rows.length) {
    const c = el("div", "empty-box");
    c.append(el("p", null, "No agents yet."), button("Build your team", "primary small", () => openHire()));
    parts.push(c);
  }
  box.replaceChildren(...parts);
}

function summaryLine() {
  const bits = [];
  if (approvals.length) bits.push(`${approvals.length} waiting for your yes`);
  if (questions.length) bits.push(`${questions.length} question${questions.length === 1 ? "" : "s"} for you`);
  const working = rows.filter((r) => busy.has(r.id)).length;
  if (working) bits.push(`${working} working`);
  bits.push(`${rows.length} on your team`);
  return bits.join(" · ");
}

function inboxCard() {
  const c = el("div", "inbox-card");
  if (inboxRunning) {
    const st = el("div", "status");
    const f = Faces.create("inbox", 22); f.setMood("working");
    st.append(f.el, el("span", null, "Reading your mail (read only)…"));
    c.append(st);
    return c;
  }
  if (!inboxResult) {
    c.append(el("p", null, "See who's been waiting on you, and who you're waiting on, from the last two weeks of mail. Cookie only reads; nothing is sent or changed."));
    const model = suggestions()[0] || localStorage.getItem("cookie.lastModel") || "";
    c.append(button("Check my mail", "primary small", () => scanInbox(model)));
    return c;
  }
  if (inboxResult.error) {
    c.append(el("p", "error-line", inboxResult.error), button("Try again", "quiet small", () => { inboxResult = null; renderToday(); }));
    return c;
  }
  const w = inboxResult;
  const counts = el("div", "stat-grid two");
  const stat = (n, label) => { const s = el("div", "stat"); s.append(el("b", null, String(n)), el("span", null, label)); return s; };
  counts.append(stat(w.waiting_on_you.length, "people waiting on you"), stat(w.you_wait_on.length, "you're waiting on"));
  c.append(counts);
  const list = (items, title) => {
    if (!items.length) return null;
    const g = el("div", "group");
    for (const t of items.slice(0, 8)) g.append(setRow(`${t.who}: ${t.subject}`, [t.since, t.ask].filter(Boolean).join(" · "), null));
    const wrap = el("div"); wrap.append(el("h3", "group-title", title), g); return wrap;
  };
  const a = list(w.waiting_on_you, "Waiting on you"), b = list(w.you_wait_on, "You're waiting on");
  if (a) c.append(a);
  if (b) c.append(b);
  if (w.waiting_on_you.length) {
    c.append(button("Have an agent draft the replies", "primary small", async () => {
      let agent = rows.find((r) => r.name === "Inbox Triage");
      if (!agent) {
        const hired = await call("hire_agent", { hire: { name: "Inbox Triage", job: STARTERS[0].job, model: suggestions()[0] || localStorage.getItem("cookie.lastModel") } });
        await loadRoster();
        agent = agentById(hired.id);
      }
      await openAgent(agent.id);
      $("input").value = "Draft a reply for each of these threads and save the drafts in your folder (or as drafts in my mail if you can). Send nothing.\n\n" +
        w.waiting_on_you.map((t) => `- ${t.who}: ${t.subject} (${t.ask})`).join("\n");
      autosize(); syncSend(); $("input").focus();
    }));
  }
  return c;
}

async function scanInbox(model) {
  inboxRunning = true;
  renderToday();
  try { inboxResult = await call("inbox_scan", { model }); }
  catch (e) { inboxResult = { error: String(e) }; }
  inboxRunning = false;
  renderToday();
}
