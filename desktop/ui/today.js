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

  const [evs, wk, offers, promises, council] = await Promise.all([
    call("evolve_status").catch(() => null),
    call("wakes").catch(() => null),
    call("routine_offers").catch(() => []),
    call("open_promises").catch(() => []),
    call("council").catch(() => null),
  ]);
  if (stale()) return;

  // The council: proposals about this agent (and, at the front desk, every one waiting on you).
  const now = Date.now() / 1000;
  const recent = (p) => ["voting", "testing", "queued", "to_person"].includes(p.state) || (p.state === "applied" && now - (p.decided_at || p.at) < 7 * 86400) || (["rejected", "failed_test", "declined", "approved", "undone"].includes(p.state) && now - (p.decided_at || p.at) < 2 * 86400);
  const mineToo = (p) => p.target === agentId || (agentId === "cookie" && p.state === "to_person");
  if (agentId === "cookie" && council?.stand_in) parts.push(standInCard(council.stand_in));
  for (const p of (council?.proposals || []).filter((p) => mineToo(p) && recent(p)).slice(0, 4)) parts.push(councilCard(p));

  // Offers from the nightly round: split an agent doing two kinds of work, or retire one with none.
  for (const o of (evs?.offers || []).filter((o) => o.agent === agentId).slice(0, 2)) {
    const g = el("div", "group");
    const hireName = o.kind === "hire" ? (o.kinds[0] || [])[0] ?? "" : "";
    const r = setRow(o.kind === "split" ? `Split ${who.name} in two?` : o.kind === "hire" ? `Hire a ${hireName} for good?` : `Retire ${who.name}?`, o.kind === "split" ? `${o.why} For example: “${(o.kinds[1] || [])[0] ?? ""}”.` : o.kind === "hire" ? `${o.why} Its job: “${(o.kinds[0] || [])[1] ?? ""}”.` : `${o.why} What it learned is kept for whoever you hire next.`, null);
    const acts = el("div", "row-actions");
    if (o.kind === "split") acts.append(button("Split", "primary small", async () => {
      const name = prompt(`Name the new agent that takes work like “${(o.kinds[1] || [])[0] ?? ""}”`);
      if (!name) return;
      const job = prompt("Its one job, in a sentence");
      if (!job) return;
      const child = await call("accept_split", { offer: o.id, name, job });
      await loadRoster(); toast("Split", `${child.name} takes that work now.`, "good"); refreshDesk();
    }));
    else if (o.kind === "hire") acts.append(button("Hire", "primary small", async () => {
      const name = prompt("Its name", hireName);
      if (!name) return;
      const job = prompt("Its one job", (o.kinds[0] || [])[1] ?? "");
      if (!job) return;
      try {
        const hired = await call("accept_hire_offer", { offer: o.id, name, job });
        await loadRoster(); toast("Hired", `${hired.name} is on the team; Cookie is picking its skills.`, "good"); refreshDesk();
      } catch (e) { toast("Couldn't hire", String(e), "error"); }
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

  // A real specialist: its own ledger and goal (`specialists`). Offered to an agent whose job is invoices.
  const specialty = await call("specialty", { agent: agentId }).catch(() => null);
  if (stale()) return;
  if (specialty === "invoices") {
    const ledger = await call("invoices", { agent: agentId }).catch(() => []);
    if (stale()) return;
    const today = new Date().toISOString().slice(0, 10);
    const open = ledger.filter((i) => i.status === "open" || i.status === "reminded");
    const g = el("div", "group");
    g.append(setRow(`${ledger.length} invoices in its ledger`, `${open.length} open · ${ledger.filter((i) => i.status === "paid").length} paid`, null));
    for (const i of open.slice(0, 6)) {
      const r = setRow(`${i.who}: ${i.amount} ${i.currency}`, `Due ${i.due}${i.due < today ? " · overdue" : ""} · ${i.status}`, null);
      if (i.due < today) r.classList.add("overdue");
      g.append(r);
    }
    parts.push(deskCard(agentId, "Its ledger", g));
  } else if (/invoice/i.test(`${who.name} ${who.job}`)) {
    const g = el("div", "group");
    const r = setRow("Make it a real invoice chaser", "It gets a ledger of your invoices, records each invoice email that arrives, and owns one goal: no invoice more than 14 days overdue without a reminder, checked against the ledger. Reminders still ask you.", null);
    const acts = el("div", "row-actions");
    acts.append(button("Set it up", "primary small", async () => {
      try { await call("make_invoice_chaser", { agent: agentId }); toast("Set up", `${who.name} has its ledger, its routine on your mail, and its goal.`, "good"); refreshDesk(); }
      catch (e) { toast("Couldn't set it up", String(e), "error"); }
    }));
    r.append(acts); g.append(r);
    parts.push(deskCard(agentId, "A specialist, for real", g));
  }

  // What it owns for days: its goals, what it is watching for, and work waiting its turn.
  const [goals, watching, queued] = await Promise.all([
    call("goals", { agent: agentId }).catch(() => []),
    call("watchers", { agent: agentId }).catch(() => []),
    call("queued", { agent: agentId }).catch(() => []),
  ]);
  if (stale()) return;
  const live = goals.filter((g) => g.status !== "done" || Date.now() / 1000 - (g.finished_at || 0) < 3 * 86400);
  if (live.length) {
    const list = el("div", "group");
    for (const g of live.slice(0, 6)) {
      const spent = `$${(g.spent_microdollars / 1e6).toFixed(2)}${g.budget_dollars ? ` of $${g.budget_dollars.toFixed(2)}` : ""}`;
      const when = g.status === "done" ? `Done: ${g.evidence}` : g.status !== "active" ? (g.status === "out_of_budget" ? `Stopped at its budget (${spent}).` : "Stopped.")
        : g.next_at ? `Next look ${new Date(g.next_at * 1000).toLocaleString()}: ${g.next_why}. ${spent} · ${g.sittings.length} sittings.` : `Waiting for a watcher. ${spent}.`;
      const r = setRow(g.objective, `${g.progress ? plain(g.progress).slice(0, 220) + " · " : ""}${when}`, null);
      const acts = el("div", "row-actions");
      if (g.status === "active") acts.append(button("Stop", "quiet small danger", async () => { await call("goal_status", { id: g.id, status: "stopped" }); refreshDesk(); }));
      else if (g.status !== "done") acts.append(button("Go on", "quiet small", async () => { await call("goal_status", { id: g.id, status: "active" }); refreshDesk(); }));
      r.append(acts);
      list.append(r);
    }
    parts.push(deskCard(agentId, `Goals it owns (${live.length})`, list));
  }
  const watchingNow = watching.filter((w) => w.active);
  if (watchingNow.length) {
    const list = el("div", "group");
    for (const w of watchingNow.slice(0, 8)) {
      const r = setRow(`Watching for: ${w.what}`, `Every ${w.every_minutes} min${w.online ? ", on the web" : ""} · ${w.runs} looks, ${w.hits} hits · last: ${w.last_said}`, null);
      const acts = el("div", "row-actions");
      acts.append(button("Stop", "quiet small", async () => { await call("stop_watcher", { id: w.id }); refreshDesk(); }));
      r.append(acts);
      list.append(r);
    }
    parts.push(deskCard(agentId, "Watching, for free", list));
  }
  if (queued.length) {
    const list = el("div", "group");
    for (const q of queued.slice(0, 5)) list.append(setRow(plain(q.text).slice(0, 160), `Waiting its turn since ${new Date(q.at * 1000).toLocaleTimeString()}`, null));
    parts.push(deskCard(agentId, `Next up (${queued.length})`, list));
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
  // The morning table: the whole team on one screen, read from its records.
  const m = await call("morning").catch(() => null);
  if (m && (m.done.length || m.goals.length || m.waiting_for_you || m.due.length || m.queued || m.waiting_for_mac || m.watching)) {
    const g = el("div", "group");
    const c = m.counts;
    const judged = [c.verified && `${c.verified} shown right`, c.corrected && `${c.corrected} you corrected`, c.failed && `${c.failed} failed`, c.unknown && `${c.unknown} not yet checked`].filter(Boolean).join(" · ");
    g.append(setRow(`Since yesterday: ${m.done.length} done on their own${m.dollars ? `, $${m.dollars.toFixed(2)}` : ""}`, judged || "Nothing ran.", null));
    const waits = [m.waiting_for_you && `${m.waiting_for_you} waiting for your yes`, m.due.length && `${m.due.length} promised for today`, m.waiting_for_mac && `${m.waiting_for_mac} waiting for your Mac`, m.queued && `${m.queued} queued`].filter(Boolean);
    if (waits.length) g.append(setRow("Waiting", waits.join(" · "), null));
    const live = m.goals.filter((x) => x.status === "active");
    if (live.length || m.watching) g.append(setRow(`Carrying on its own: ${live.length} goal${live.length === 1 ? "" : "s"}, ${m.watching} watcher${m.watching === 1 ? "" : "s"}`, live.slice(0, 3).map((x) => `${agentById(x.agent)?.name ?? x.agent}: ${x.objective}`).join(" · ") + (m.watcher_hits_today ? ` · ${m.watcher_hits_today} watcher hits today` : ""), null));
    for (const d of m.done.slice(0, 6)) {
      const tag = { verified: "shown right", corrected: "corrected", failed: "failed", unknown: "not checked" }[d.end] || d.end;
      const r = setRow(`${d.name}: ${plain(d.what)}`, `${tag} · ${plain(d.said)}`, null);
      if (d.end === "failed") r.classList.add("overdue");
      const acts = el("div", "row-actions");
      acts.append(button("Open", "quiet small", () => openAgent(d.agent)));
      r.append(acts);
      g.append(r);
    }
    out.push(deskCard("cookie", "This morning", g));
  }
  // Work a cloud team parked because it needs this Mac (`hand`): it runs when Cookie is open here.
  const mac = await call("waiting_on_mac").catch(() => null);
  if (mac?.parked?.length) {
    const list = el("div", "group");
    for (const c of mac.parked.slice(0, 6)) list.append(setRow(`${agentById(c.agent)?.name ?? c.agent}: ${c.tool.replace(/_/g, " ")}`, `Parked ${new Date(c.at * 1000).toLocaleString()}`, null));
    out.push(deskCard("cookie", `Waiting for your Mac (${mac.parked.length})`, list, el("p", "set-note", mac.mac_connected ? "Your Mac is connected: these run now." : "These run when Cookie is open on your Mac.")));
  }
  const ideas = await call("scout").catch(() => []);
  // Hires Scout thinks you'd want.
  for (const idea of ideas) {
    const c = el("div", "idea");
    const f = Faces.create("scout-" + idea.id, 36);
    const t = el("div", "row-text");
    t.append(el("strong", null, `You did "${idea.steps.join(" → ")}" in ${idea.app} on ${idea.days} days`), el("small", null, "Want an agent for it? With “Use this Mac” on, it can do the steps in the app; each press asks you until it has earned your trust."));
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

/* ---------- the council: agents improving each other, with every vote shown ---------- */
const COUNCIL_STATE = { voting: "Voting", testing: "Testing on a copy", queued: "Agreed, tested tomorrow", to_person: "Yours to decide", applied: "Changed", undone: "Undone", rejected: "Not changed", failed_test: "Test said no", approved: "You said yes", declined: "You said no" };

/** The last vote of each voter, and whether a second round changed it. */
function councilVotes(votes) {
  const last = new Map();
  for (const v of votes || []) {
    const was = last.get(v.voter);
    if (!was || v.round >= was.round) last.set(v.voter, { ...v, changed: was ? was.yes !== v.yes : false });
  }
  return [...last.values()];
}

/** One proposal: what, why, who said what (and why), the test, and what you can do. */
function councilCard(p) {
  const body = el("div", "council");
  const head = el("div", "council-head");
  head.append(el("strong", "council-what", p.kind === "stand_in" ? `${agentById(p.change)?.name ?? "A teammate"} stands in for ${p.target_name}` : councilWhat(p)), el("span", "council-state " + p.state, COUNCIL_STATE[p.state] ?? p.state));
  body.append(head);
  const by = el("p", "council-why");
  by.append(el("span", "council-by", p.by === "council" ? "The council's own check: " : `${p.by_name} proposed: `), p.why);
  body.append(by);
  const votes = councilVotes(p.votes);
  if (votes.length) {
    const yes = votes.filter((v) => v.yes).length;
    const list = el("div", "council-votes");
    list.append(el("span", "council-tally", `${yes}–${votes.length - yes}`));
    for (const v of votes) {
      const row = el("div", "vote " + (v.yes ? "yes" : "no"));
      row.append(Faces.create(v.voter, 20).el, el("span", "vote-name", v.name), el("span", "vote-mark", v.yes ? "Yes" : "No"));
      if (v.changed) row.append(el("span", "vote-changed", "changed after reading the others"));
      row.append(el("span", "vote-reason", v.reason));
      list.append(row);
    }
    body.append(list);
  } else if (p.state === "voting") body.append(el("p", "council-note", "Three teammates are voting, each on their own."));
  if (p.exam) body.append(el("p", "council-test", `Test on a copy: ${p.exam.before?.passed}/${p.exam.cases} → ${p.exam.after?.passed}/${p.exam.cases}`));
  if (p.note) body.append(el("p", "council-note", p.note));
  const acts = el("div", "row-actions");
  if (p.state === "to_person") acts.append(
    button("Decline", "quiet small", async () => { try { await call("council_decide", { id: p.id, yes: false }); refreshDesk(); } catch (e) { toast("Couldn't", String(e), "error"); } }),
    button(p.kind === "stand_in" ? "Let it stand in" : "Approve", "primary small", async () => { try { await call("council_decide", { id: p.id, yes: true }); toast("Done", councilWhat(p), "good"); await loadRoster(); refreshDesk(); } catch (e) { toast("Couldn't", String(e), "error"); } }),
  );
  if (p.change_id && ["applied", "approved"].includes(p.state)) acts.append(button("Undo", "quiet small", async () => { try { await call("council_undo", { id: p.id }); toast("Undone", councilWhat(p)); refreshDesk(); } catch (e) { toast("Couldn't undo", String(e), "error"); } }));
  if (acts.childElementCount) body.append(acts);
  return deskCard(p.target, "The council", body);
}

function councilWhat(p) {
  const name = p.target_name;
  if (p.kind === "habit") return `New habit for ${name}: “${p.change}”`;
  if (p.kind === "drop_habit") return `${name} drops a habit: “${p.change}”`;
  if (p.kind === "model") return `${name} moves to ${modelName(p.change)}`;
  if (p.kind === "grant") return `${name}: ${p.change.replace("=", " → ")}`;
  if (p.kind === "limit") return `${name}: limit ${p.change.replace("=", " → ")}`;
  return p.change;
}

/** A teammate answering in Cookie's place, and the way back. */
function standInCard(s) {
  const who = agentById(s.agent);
  const g = el("div", "council");
  g.append(el("p", "council-why", `${who?.name ?? "A teammate"} answers what you send to Cookie, here and on your phone, until Cookie passes its own tests again (checked once a day). Your approvals stay yours.`));
  if (s.why) g.append(el("p", "council-note", s.why));
  const acts = el("div", "row-actions");
  acts.append(button("Cookie takes over again", "quiet small", async () => { await call("council_end_stand_in"); await loadRoster(); refreshDesk(); }));
  g.append(acts);
  return deskCard(s.agent, `Standing in for Cookie since ${new Date(s.since * 1000).toLocaleDateString([], { day: "numeric", month: "short" })}`, g);
}
