// The desk: what waits for you sits at the end of the chat it belongs to, like
// a messaging app, not on a page of its own. Each agent's chat ends with what
// it holds for you: what its worlds want to send, offers from the nightly round
// (split, retire), a routine it could make, a wake to label, a promise to mark.
// Cookie's chat, the front desk, also holds what's about the whole team: the
// morning recap, who's waiting on you in your mail, and hires Scout suggests.
// Approvals and questions keep their own cards (app.js, learn.js).
let inboxResult = null, inboxRunning = false;
let deskSeq = 0;

/** Redraw the open chat's desk, when anything it shows may have changed. */
function refreshDesk() {
  if (view === "chat" && current) renderDesk(current.id);
}

/** A card on the desk: a face, a title, and what to do. */
function deskCard(agentId, title, ...body) {
  const c = el("div", "desk-card");
  const head = el("div", "desk-head");
  head.append(Faces.create(agentId, 20).el, el("span", "desk-title", title));
  c.append(head, ...body);
  return c;
}

async function renderDesk(agentId) {
  const seq = ++deskSeq;
  const box = $("desk");
  if (!box) return;
  const who = agentById(agentId);
  const parts = [];
  const stale = () => seq !== deskSeq || current?.id !== agentId || view !== "chat" || !box.isConnected;

  // What its worlds tried to send, pay or put live waits for your yes.
  const mine = new Set((typeof wallWorlds === "undefined" ? [] : wallWorlds).filter((w) => w.owner === agentId).map((w) => w.id));
  const wall = (typeof wallWaiting === "undefined" ? [] : wallWaiting).filter((e) => mine.has(e.world));
  if (wall.length) parts.push(deskCard(agentId, `From its worlds, waiting for your yes (${wall.length})`, wallGroup(wall)));

  const [evs, wk, offers, promises] = await Promise.all([
    call("evolve_status").catch(() => null),
    call("wakes").catch(() => null),
    call("routine_offers").catch(() => []),
    call("open_promises").catch(() => []),
  ]);
  if (stale()) return;

  // Offers from the nightly round: split an agent doing two kinds of work, or retire one with none.
  for (const o of (evs?.offers || []).filter((o) => o.agent === agentId).slice(0, 2)) {
    const g = el("div", "group");
    const r = setRow(o.kind === "split" ? `Split ${who.name} in two?` : `Retire ${who.name}?`, o.kind === "split" ? `${o.why} For example: “${(o.kinds[1] || [])[0] ?? ""}”.` : `${o.why} What it learned is kept for whoever you hire next.`, null);
    const acts = el("div", "row-actions");
    if (o.kind === "split") acts.append(button("Split", "primary small", async () => {
      const name = prompt(`Name the new agent that takes work like “${(o.kinds[1] || [])[0] ?? ""}”`);
      if (!name) return;
      const job = prompt("Its one job, in a sentence");
      if (!job) return;
      const child = await call("accept_split", { offer: o.id, name, job });
      await loadRoster(); toast("Split", `${child.name} takes that work now.`, "good"); refreshDesk();
    }));
    else acts.append(button("Retire", "primary small", async () => {
      if (!confirm(`Retire ${who.name}? It writes a handover note, what it learned is kept for a successor, and it is let go.`)) return;
      await call("accept_retire", { offer: o.id }); await loadRoster(); toast("Retired", `What ${who.name} learned is kept: hire someone and start from it.`);
    }));
    acts.append(button("Not now", "quiet small", async () => { await call("decline_offer", { offer: o.id }); refreshDesk(); }));
    r.append(acts);
    g.append(r);
    parts.push(deskCard(agentId, "From last night's round", g));
  }

  // It woke because its memory changed: a label makes the next wake better judged.
  const woke = (wk?.wakes || []).filter((w) => w.agent === agentId && !w.label && Date.now() / 1000 - w.at < 3 * 86400).slice(0, 3);
  if (woke.length) {
    const g = el("div", "group");
    for (const w of woke) {
      const r = setRow(`Woke: ${w.title}`, w.held ? `${w.why} It was asleep or busy, so it starts when it can.` : w.why, null);
      const acts = el("div", "row-actions");
      const lab = (label, text) => button(text, "quiet small", async () => { await call("label_wake", { id: w.id, label }); refreshDesk(); });
      acts.append(lab("useful", "Useful"), lab("not_useful", "Not useful"), lab("wrong", "Wrong"));
      r.append(acts);
      g.append(r);
    }
    parts.push(deskCard(agentId, "Woke on its own", g));
  }

  // A job you keep giving: offered once as a routine.
  for (const o of offers.filter((o) => o.agent === agentId).slice(0, 2)) {
    const sched = await call("describe_schedule", { schedule: o.schedule }).catch(() => "");
    if (stale()) return;
    const r = setRow("Make it a routine?", `You've asked this ${o.seen} times, ${sched}: "${plain(o.task).slice(0, 120)}"`, null);
    const acts = el("div", "row-actions");
    acts.append(
      button("Yes, " + sched, "primary small", async () => { await call("answer_routine_offer", { offer: o.id, yes: true }); toast("Routine made", `${who.name}, ${sched}`, "good"); refreshDesk(); }),
      button("No, don't ask again", "quiet small", async () => { await call("answer_routine_offer", { offer: o.id, yes: false }); refreshDesk(); }),
    );
    r.append(acts);
    const g = el("div", "group"); g.append(r);
    parts.push(deskCard(agentId, "A routine it could take on", g));
  }

  // What it promised in its answers, for you to mark.
  const promised = promises.filter((p) => p.agent === agentId);
  if (promised.length) {
    const list = el("div", "group");
    const today = new Date().toISOString().slice(0, 10);
    for (const p of promised.slice(0, 8)) {
      const r = setRow(p.text, `By ${p.due}${p.due < today ? " · overdue" : ""}`, null);
      if (p.due < today) r.classList.add("overdue");
      const acts = el("div", "row-actions");
      acts.append(
        button("Kept", "quiet small", async () => { await call("mark_promise", { id: p.agent, job: p.job, index: p.index, state: "kept" }); refreshDesk(); }),
        button("Missed", "quiet small danger", async () => { await call("mark_promise", { id: p.agent, job: p.job, index: p.index, state: "missed" }); refreshDesk(); }),
      );
      r.append(acts);
      list.append(r);
    }
    parts.push(deskCard(agentId, `Promised (${promised.length})`, list));
  }

  // The front desk also holds what's about the whole team.
  if (agentId === "cookie") parts.push(...await teamDesk());
  if (stale()) return;
  box.replaceChildren(...parts);
  box.hidden = parts.length === 0;
}

/** Cookie's share of the desk: the morning recap, your mail, and Scout. */
async function teamDesk() {
  const out = [];
  const [retro, ideas] = await Promise.all([call("retro").catch(() => null), call("scout").catch(() => [])]);
  // The morning recap: what happened since yesterday, from the record (none on a quiet day).
  if (retro && Date.now() / 1000 - retro.at < 36 * 3600) {
    const [head, ...lines] = retro.text.split("\n");
    const body = el("div", "retro-lines");
    for (const l of lines) body.append(el("p", l.startsWith("  ") ? "retro-sub" : null, l.replace(/^\s*[-·]\s*/, "")));
    const c = deskCard("cookie", head, body);
    c.classList.add("retro-card");
    c.querySelector(".desk-head").append(el("small", "muted", fmtTime(retro.at)));
    out.push(c);
  }
  // Boards the team keeps: open one, or start one.
  const boards = await call("boards").catch(() => []);
  const bl = el("div", "group");
  for (const b of boards.slice(0, 6)) {
    const by = b.created_by === "you" ? "You" : agentById(b.created_by)?.name ?? "An agent";
    bl.append(setRow(b.title, `${b.cards} card${b.cards === 1 ? "" : "s"} · ${by} · ${fmtTime(b.updated_at)}`, button("Open", "quiet small", () => openBoard(b.id, "cookie"))));
  }
  if (!boards.length) bl.append(setRow("No boards yet", "A board is columns of cards you and your agents work on together. Ask an agent to keep one for a project, or start one.", null));
  bl.append(setRow("", null, button("New board", "quiet small", async () => {
    const title = prompt("What is the board for?");
    if (!title?.trim()) return;
    try { const b = await call("create_board", { title }); openBoard(b.id, "cookie"); } catch (e) { toast("Couldn't make it", String(e), "error"); }
  })));
  out.push(deskCard("cookie", `Boards${boards.length ? ` (${boards.length})` : ""}`, bl));
  // Who's waiting on you (mail, through Enkeon).
  out.push(deskCard("cookie", "Who's waiting on you", inboxCard()));
  // Hires Scout thinks you'd want.
  for (const idea of ideas) {
    const c = el("div", "idea");
    const f = Faces.create("scout-" + idea.id, 36);
    const t = el("div", "row-text");
    t.append(el("strong", null, `You did "${idea.steps.join(" → ")}" in ${idea.app} on ${idea.days} days`), el("small", null, "Want an agent for it? Cookie can't press buttons in other apps; this agent prepares the work and reminds you."));
    const acts = el("div", "row-actions");
    acts.append(
      button("Not now", "quiet small", async () => { await call("scout_dismiss", { proposal: idea.id }); refreshDesk(); }),
      button("Hire", "primary small", () => openHire({ name: idea.name, job: idea.job })),
    );
    c.append(f.el, t, acts);
    out.push(deskCard("cookie", "Scout noticed", c));
  }
  return out;
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
    c.append(el("p", "error-line", inboxResult.error), button("Try again", "quiet small", () => { inboxResult = null; refreshDesk(); }));
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
  refreshDesk();
  try { inboxResult = await call("inbox_scan", { model }); }
  catch (e) { inboxResult = { error: String(e) }; }
  inboxRunning = false;
  refreshDesk();
}
