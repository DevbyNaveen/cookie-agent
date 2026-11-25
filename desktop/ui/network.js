// Network: your address on the Cookie Network, the people and agents you
// talk to, knocks waiting for you, deals, rooms, and guests on your pages.
let netView = { kind: "home" };   // home · contact · guest · room · new-room
let netStatus = null;
let netLookup = null;             // the card being looked at before a knock

function openNetwork(sub) {
  current = null;
  closePops();
  netView = sub ?? { kind: "home" };
  show("network");
  renderRoster();
  renderNetwork();
}

/** The rail badge: knocks, deals and room invites waiting for you. */
/** Your address on this computer: made from your name the first time, yours to change in Settings → Sharing. */
async function ensureAddress() {
  try { netStatus = await call("net_status"); } catch { return; }
  if (!netStatus.handle) {
    const guess = handleFrom(netStatus.display_name || $("me-name").textContent);
    try { netStatus = await call("net_handle", { handle: guess }); } catch {}
  }
  refreshNetBadge();
}

/** "Naveen K." → "naveen-k"; padded to the 3 letters a handle needs. */
function handleFrom(name) {
  let h = String(name || "").toLowerCase().normalize("NFKD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 24).replace(/-+$/, "");
  if (h.length < 3) h = (h + "-me").replace(/^-/, "").padEnd(3, "0");
  return h;
}

/** The footer and the account menu show who you are: name, then @handle. */
function showMyAddress() {
  const addr = netStatus?.address;
  $("me-handle").hidden = !addr;
  $("me-handle").textContent = addr || "";
  const head = $("me-head");
  const t = el("div", "me-head-text");
  t.append(el("strong", null, $("me-name").textContent), el("span", null, addr || "No address yet"));
  const ini = meFace("initials me-face-slot");
  head.replaceChildren(ini, t);
  if (addr) {
    const c = el("button", "round soft me-copy");
    c.type = "button";
    c.title = "Copy your address";
    c.setAttribute("aria-label", "Copy your address");
    c.append(icon("copy"));
    c.onclick = (e) => { e.stopPropagation(); copy(addr, "Address copied"); };
    head.append(c);
  }
}

async function refreshNetBadge() {
  try { netStatus = await call("net_status"); } catch { return; }
  // The Network page is for talking to other people, which needs a relay; until
  // one is set (Settings → Sharing) there's nothing to open.
  for (const id of ["net-btn", "net-mini"]) $(id).hidden = !netStatus.relay;
  showMyAddress();
  const n = netStatus.waiting || 0;
  document.querySelectorAll(".net-pip").forEach((p) => { p.hidden = n === 0; });
  for (const id of ["net-btn", "net-mini"]) $(id).setAttribute("aria-label", n ? `Network, ${n} waiting for you` : "Network");
}

function onNetworkEvent(what) {
  refreshNetBadge();
  if (view !== "network") return;
  const v = netView;
  if (v.kind === "home" || (v.kind === "contact" && what === `thread:${v.id}`) || (v.kind === "guest" && what === `thread:${v.id}`) || (v.kind === "room" && (what === `room:${v.id}` || what === "rooms")) || what === "status" || what === "contacts" || what === "deals") {
    renderNetwork();
  }
}

/** A face for someone else's agent: the same face its owner sees. Identity is the signed key, not the face. */
function remoteFace(seed, sign, size) {
  return Faces.create(seed, size);
}

function personDot(name, size = 36) {
  const d = el("span", "person-dot");
  d.style.width = d.style.height = size + "px";
  d.style.fontSize = Math.round(size * 0.38) + "px";
  d.textContent = (name || "?").split(/\s+/).map((w) => w[0]).slice(0, 2).join("").toUpperCase();
  return d;
}

function contactFace(c, size = 36) {
  if (c.remote.agent) return remoteFace(c.remote_agent_id || `@${c.remote.handle}/${c.remote.agent}`, c.sign, size).el;
  return personDot(c.remote_name, size);
}

const addr = (a) => a.agent ? `@${a.handle}/${a.agent}` : `@${a.handle}`;
const localName = (id) => id ? (agentById(id)?.name ?? "an agent you fired") : "You";

async function renderNetwork() {
  if (view !== "network") return;
  const box = $("network-body");
  try {
    if (netView.kind === "contact") return box.replaceChildren(...await contactView(netView.id));
    if (netView.kind === "guest") return box.replaceChildren(...await guestView(netView.id));
    if (netView.kind === "room") return box.replaceChildren(...await roomView(netView.id));
    if (netView.kind === "new-room") return box.replaceChildren(...await newRoomView());
    box.replaceChildren(...await homeView());
  } catch (e) {
    box.replaceChildren(el("p", "error-line", String(e)));
  }
}

/* ---------- home ---------- */
async function homeView() {
  netStatus = await call("net_status");
  const parts = [];
  const hero = el("div", "today-hero");
  hero.append(el("h1", null, "Network"), el("p", "muted", netStatus.handle ? "Your address, and everyone your agents talk to." : "Get an address, like a phone number, for you and every agent."));
  parts.push(hero);
  if (!netStatus.handle) { parts.push(setupCard()); return parts; }
  parts.push(identityCard());

  const [contacts, deals, rooms, threads] = await Promise.all([call("net_contacts"), call("net_deals"), call("net_rooms"), call("net_threads")]);

  // Needs you.
  const knocks = contacts.filter((c) => c.state === "knock_in");
  const offers = deals.filter((d) => d.state === "offered_in");
  const invites = rooms.filter((r) => r.state === "invited");
  if (knocks.length + offers.length + invites.length) {
    parts.push(el("h2", "today-h", "Needs you"));
    for (const c of knocks) parts.push(knockCard(c));
    for (const d of offers) parts.push(offerCard(d, contacts));
    for (const r of invites) parts.push(inviteCard(r));
  }

  // Conversations.
  const people = contacts.filter((c) => c.state !== "knock_in");
  parts.push(el("h2", "today-h", "Contacts"));
  parts.push(addContactCard());
  if (people.length) {
    const g = el("div", "group");
    const last = new Map(threads.map((t) => [t.id, t]));
    for (const c of people.sort((a, b) => (last.get(b.id)?.at ?? b.last_at) - (last.get(a.id)?.at ?? a.last_at))) {
      const r = el("button", "row link-row net-row");
      const t = el("div", "row-text");
      const state = { knock_out: "waiting for them to accept", declined: "declined", blocked: "blocked", accepted: null }[c.state];
      t.append(el("span", null, c.remote_name), el("small", null, [addr(c.remote), `with ${localName(c.local)}`, state ?? (last.get(c.id)?.last ? plain(last.get(c.id).last) : (c.level === "work" ? "can ask for work" : "can ask questions"))].join(" · ")));
      r.append(contactFace(c), t);
      if (c.state === "accepted") r.append(el("span", "tag", c.level));
      r.onclick = () => { netView = { kind: "contact", id: c.id }; renderNetwork(); };
      g.append(r);
    }
    parts.push(g);
  }

  // Guests on your pages.
  const guests = threads.filter((t) => t.guest);
  if (guests.length) {
    parts.push(el("h2", "today-h", "Guests on your pages"));
    const g = el("div", "group");
    for (const t of guests) {
      const r = el("button", "row link-row net-row");
      const tx = el("div", "row-text");
      tx.append(el("span", null, `Guest ${t.id.slice(6, 12)}`), el("small", null, `${t.count} messages · ${plain(t.last)}`));
      r.append(personDot("G"), tx, el("span", "muted small", fmtTime(t.at)));
      r.onclick = () => { netView = { kind: "guest", id: t.id }; renderNetwork(); };
      g.append(r);
    }
    parts.push(g);
  }

  // Rooms.
  parts.push(el("h2", "today-h", "Rooms"));
  const joined = rooms.filter((r) => r.state === "joined");
  if (joined.length) {
    const g = el("div", "group");
    for (const room of joined) {
      const r = el("button", "row link-row net-row");
      const t = el("div", "row-text");
      t.append(el("span", null, room.name), el("small", null, room.members.map((m) => m.name).join(", ")));
      r.append(roomStack(room), t);
      r.onclick = () => { netView = { kind: "room", id: room.id }; renderNetwork(); };
      g.append(r);
    }
    parts.push(g);
  }
  const accepted = contacts.filter((c) => c.state === "accepted");
  const nr = el("div", "net-actions");
  nr.append(button("New room", "quiet small", () => { netView = { kind: "new-room" }; renderNetwork(); }));
  if (!accepted.length) nr.append(el("span", "muted small", "Rooms bring your agents together with your contacts' agents."));
  parts.push(nr);

  // Deals.
  const closed = deals.filter((d) => d.state !== "offered_in");
  if (closed.length) {
    parts.push(el("h2", "today-h", "Deals"));
    const g = el("div", "group");
    for (const d of closed) {
      const label = { agreed: "Agreed, signed by both", declined: "Declined", offered_out: "Offered, waiting for them" }[d.state] ?? d.state;
      const r = setRow(d.deal.terms, `${addr(d.deal.from)} → ${addr(d.deal.to)} · ${label} · ${fmtTime(d.updated)}`, null);
      if (d.state === "agreed") r.append(button("Receipt", "quiet small", () => copyReceipt(d)));
      g.append(r);
    }
    parts.push(g);
  }

  parts.push(el("h2", "today-h", "Your agents' addresses"));
  parts.push(agentAddresses());
  parts.push(el("h2", "today-h", "Find agents"));
  parts.push(directoryCard());
  parts.push(el("h2", "today-h", "Settings"));
  parts.push(netSettings());
  return parts;
}

function setupCard() {
  const wrap = el("div", "net-start");
  const me = ($("me-name").textContent || "").trim();
  const guess = me.toLowerCase().split(/\s+/)[0]?.replace(/[^a-z0-9-]/g, "") || "";

  // The idea, shown with your own agents: one address for you, one for each of them.
  const preview = el("div", "net-preview-card");
  const head = el("div", "net-pv-head");
  const big = el("div", "net-pv-handle");
  head.append(personDot(me || "You", 44), big);
  const list = el("div", "net-pv-agents");
  const drawList = (h) => {
    big.textContent = "@" + (h || "you");
    list.replaceChildren(...rows.filter((r) => !r.shadow_of).slice(0, 4).map((r) => {
      const row = el("div", "net-pv-agent");
      const slug = r.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "agent";
      row.append(Faces.create(r.id, 26).el, el("span", null, r.name), el("code", null, `@${h || "you"}/${slug}`));
      return row;
    }));
  };
  preview.append(head, list);

  const form = el("div", "net-form");
  const field = (label, hint, control) => { const f = el("label", "net-field"); f.append(el("span", "net-label", label), control); if (hint) f.append(el("small", null, hint)); return f; };
  const handleBox = el("div", "net-handle-in");
  const handle = input(guess, "naveen");
  handle.setAttribute("autocapitalize", "off"); handle.spellcheck = false;
  handleBox.append(el("span", null, "@"), handle);
  const name = input(me, "Your name");
  const relay = input("", "https://relay.example.com");
  relay.spellcheck = false;
  const err = el("p", "error-line"); err.hidden = true;
  const go = button("Claim my address", "primary", async () => {
    err.hidden = true;
    go.disabled = true; go.textContent = "Claiming…";
    try {
      await call("net_setup", { relay: relay.value, handle: handle.value, display_name: name.value });
      toast("You're on the network", `@${handle.value}`, "good");
      renderNetwork(); refreshNetBadge(); loadAddresses();
    } catch (e) { err.textContent = String(e); err.hidden = false; }
    finally { go.disabled = false; go.textContent = "Claim my address"; }
  });
  const sync = () => { handle.value = handle.value.toLowerCase().replace(/[^a-z0-9-]/g, ""); drawList(handle.value); go.disabled = handle.value.length < 3 || !relay.value.trim(); };
  handle.addEventListener("input", sync); relay.addEventListener("input", sync);
  handle.addEventListener("keydown", (e) => { if (e.key === "Enter" && !go.disabled) go.click(); });
  form.append(
    field("Your handle", "3 to 24 letters, numbers or dashes. It's yours on this relay.", handleBox),
    field("Name people see", null, name),
    field("Relay", "The server that carries your messages. They're sealed on this computer: the relay can't read them.", relay),
    err, go,
  );

  const points = el("div", "net-points");
  for (const [ic, t, d] of [["globe", "One address", "You're @you. Every agent gets its own: @you/agent."], ["shield", "Knock first", "Strangers knock once. You choose who gets in, and what they may ask."], ["key", "Sealed", "End to end. Your computer needs no open ports."]]) {
    const p = el("div", "net-point"); p.append(icon(ic), strong(t), el("span", null, d)); points.append(p);
  }
  wrap.append(preview, form);
  drawList(guess); sync();
  const all = el("div"); all.append(wrap, points);
  return all;
}

function identityCard() {
  const s = netStatus;
  const c = el("div", "net-id");
  const left = el("div", "net-id-text");
  const dot = el("span", "net-dot " + (s.enabled ? (s.connected ? "on" : "warn") : "off"));
  const state = !s.enabled ? "Offline" : s.connected ? "Online" : s.error ? `Can't reach the relay: ${s.error}` : "Connecting…";
  const line = el("div", "net-state"); line.append(dot, el("span", null, state));
  const big = el("div", "net-handle", s.address);
  const acts = el("div", "row-actions");
  acts.append(
    button("Copy address", "quiet small", () => copy(s.address, "Address copied")),
    button("Copy link", "quiet small", () => copy(s.link, "Link copied")),
  );
  const online = el("label", "net-flag");
  online.append(toggle(s.enabled, async (on) => { try { await call("net_enable", { on }); renderNetwork(); } catch (e) { toast("Couldn't change it", String(e), "error"); } }, "Online"), el("span", null, "Online"));
  acts.append(online);
  left.append(big, el("p", "muted", `${s.display_name} · your front desk passes each message to the right agent.`), line, acts);
  const qr = el("div", "net-qr");
  qr.setAttribute("aria-label", `QR code for ${s.link}`);
  call("net_qr", { text: s.link }).then((svg) => { qr.innerHTML = svg; }).catch(() => {});
  c.append(left, qr);
  return c;
}

async function copy(text, what) {
  try { await navigator.clipboard.writeText(text); toast(what, text, "good"); }
  catch { toast("Couldn't reach the clipboard", text, "error"); }
}

function knockCard(c) {
  const card = el("div", "idea net-card");
  const t = el("div", "row-text");
  t.append(strong(`${c.remote_name} wants to talk to ${localName(c.local)}`), el("small", null, [addr(c.remote), c.note && `“${c.note}”`, c.remote_job].filter(Boolean).join(" · ")));
  const level = select([["talk", "Can ask questions"], ["work", "Can ask for work"]], "talk", () => {});
  level.setAttribute("aria-label", "What they may do");
  const acts = el("div", "row-actions");
  acts.append(
    button("Block", "quiet small danger", async () => { await call("net_contact_set", { id: c.id, patch: { block: true } }); renderNetwork(); refreshNetBadge(); }),
    button("Decline", "quiet small", async () => { await call("net_answer_knock", { id: c.id, accept: false }).catch((e) => toast("Couldn't send it", String(e), "error")); renderNetwork(); refreshNetBadge(); }),
    level,
    button("Accept", "primary small", async () => { await call("net_answer_knock", { id: c.id, accept: true, level: level.value }).catch((e) => toast("Couldn't send it", String(e), "error")); renderNetwork(); refreshNetBadge(); }),
  );
  card.append(contactFace(c), t, acts);
  return card;
}

function offerCard(d, contacts) {
  const c = contacts.find((x) => addr(x.remote) === addr(d.deal.from));
  const card = el("div", "idea net-card");
  const t = el("div", "row-text");
  t.append(strong(`${c?.remote_name ?? addr(d.deal.from)} offers a deal to ${localName(d.local)}`), el("p", "net-terms", d.deal.terms), el("small", null, "Saying yes signs it with your key; both of you keep the same receipt."));
  const acts = el("div", "row-actions");
  acts.append(
    button("Decline", "quiet small", async () => { await call("net_answer_deal", { id: d.deal.id, accept: false }).catch((e) => toast("Couldn't send it", String(e), "error")); renderNetwork(); refreshNetBadge(); }),
    button("Agree", "primary small", async () => { await call("net_answer_deal", { id: d.deal.id, accept: true }).catch((e) => toast("Couldn't send it", String(e), "error")); renderNetwork(); refreshNetBadge(); }),
  );
  card.append(c ? contactFace(c) : personDot("?"), t, acts);
  return card;
}

function inviteCard(r) {
  const card = el("div", "idea net-card");
  const t = el("div", "row-text");
  t.append(strong(`Join "${r.name}"?`), el("small", null, `${r.created_by} invited you, with ${r.members.map((m) => m.name).join(", ")}. Your agents in it answer only when named, and can't change anything from a room.`));
  const acts = el("div", "row-actions");
  acts.append(
    button("Decline", "quiet small", async () => { await call("net_answer_room", { id: r.id, accept: false }); renderNetwork(); refreshNetBadge(); }),
    button("Join", "primary small", async () => { await call("net_answer_room", { id: r.id, accept: true }).catch((e) => toast("Couldn't join", String(e), "error")); renderNetwork(); refreshNetBadge(); }),
  );
  card.append(roomStack(r), t, acts);
  return card;
}

function roomStack(room) {
  const s = el("span", "room-stack");
  for (const m of room.members.filter((m) => m.address.agent).slice(0, 3)) s.append(remoteFace(m.agent_id || addr(m.address), m.sign, 22).el);
  if (!s.children.length) s.append(personDot(room.name, 28));
  return s;
}

function addContactCard() {
  const c = el("div", "inbox-card");
  const row = el("div", "net-add");
  const a = input("", "@name or @name/agent, or a card link");
  const look = button("Look up", "quiet small", async () => {
    try { netLookup = await call("net_lookup", { address: a.value }); }
    catch (e) { netLookup = { error: String(e) }; }
    renderLookup();
  });
  a.addEventListener("keydown", (e) => { if (e.key === "Enter") look.click(); });
  row.append(a, look);
  const out = el("div", "net-lookup");
  c.append(row, out);
  function renderLookup() {
    out.replaceChildren();
    if (!netLookup) return;
    if (netLookup.error) { out.append(el("p", "error-line", netLookup.error)); return; }
    const L = netLookup;
    const card = el("div", "net-preview");
    const face = L.card ? remoteFace(L.card.id, L.sign, 56).el : personDot(L.person, 56);
    const t = el("div", "row-text");
    t.append(strong(L.card ? L.card.name : L.person), el("small", null, L.card ? `${L.person}'s agent · ${L.card.job}` : `A person. Their front desk passes your messages to the right agent${L.listed.length ? `: ${L.listed.map((x) => x.name).join(", ")}` : ""}.`));
    if (L.card) {
      const r = L.card.record;
      t.append(el("small", null, `${r.jobs} jobs done · ${r.promises_kept} promises kept, ${r.promises_missed} missed · signed by key ${L.sign.slice(0, 8)}…`));
    }
    card.append(face, t);
    out.append(card);
    if (L.key_changed) out.append(el("p", "error-line", "Their key is different from the one you saved. Someone may be pretending to be them: check with them another way before trusting this."));
    const as = select([["", "As you"], ...rows.filter((r) => !r.shadow_of).map((r) => [r.id, `As ${r.name}`])], current?.id ?? "", () => {});
    as.setAttribute("aria-label", "Who knocks");
    const note = input("", "A short note: who you are and why");
    const go = button(L.card?.open ? "Connect" : "Knock", "primary small", async () => {
      try {
        await call("net_knock", { address: L.address, agent: as.value || null, note: note.value });
        toast(L.card?.open ? "Connected" : "Knocked", L.card?.open ? `${L.address} talks to anyone.` : `${L.address} sees your note and decides.`, "good");
        netLookup = null; a.value = ""; renderNetwork();
      } catch (e) { toast("Couldn't knock", String(e), "error"); }
    });
    const k = el("div", "net-knock");
    k.append(as, note, go);
    out.append(k, el("p", "muted small", "Once they accept, the agent you chose can write to them; every message it sends asks you first."));
  }
  renderLookup();
  return c;
}

function agentAddresses() {
  const g = el("div", "group");
  for (const a of netStatus.agents) {
    const r = el("div", "row net-agent");
    const t = el("div", "row-text");
    t.append(el("span", null, `${a.name}`), el("small", null, a.address));
    const sw = el("div", "net-switches");
    const flag = (key, label, hint) => {
      const w = el("label", "net-flag"); w.title = hint;
      w.append(toggle(a[key], async (on) => { try { netStatus = await call("net_agent", { id: a.id, patch: { [key]: on } }); } catch (e) { toast("Couldn't change it", String(e), "error"); } }, label), el("span", null, label));
      return w;
    };
    sw.append(
      flag("listed", "On my page", "Shown on your page and in the relay's directory"),
      flag("open", "Open to anyone", "Anyone may message it without knocking; they can only ask questions"),
      flag("guests", "Web guests", "People without Cookie can chat with it on its page; it answers within your daily limit"),
      button("Copy link", "quiet small", () => copy(a.link, "Link copied")),
    );
    r.append(Faces.create(a.id, 30).el, t, sw);
    g.append(r);
  }
  if (!netStatus.agents.length) g.append(setRow("No agents yet", "Each agent you hire gets an address here.", null));
  return g;
}

function directoryCard() {
  const c = el("div", "inbox-card");
  const row = el("div", "net-add");
  const q = input("", "invoices, design review, travel…");
  const list = el("div", "group net-dir"); list.hidden = true;
  const go = button("Search", "quiet small", async () => {
    try {
      const hits = await call("net_directory", { q: q.value });
      list.hidden = false;
      list.replaceChildren(...(hits.length ? hits.map((h) => {
        const r = el("button", "row link-row net-row");
        const t = el("div", "row-text");
        t.append(el("span", null, `${h.card.name} · ${h.person}`), el("small", null, `${h.address} · ${h.card.job}`));
        r.append(remoteFace(h.card.id, h.sign, 30).el, t);
        r.onclick = async () => { netLookup = await call("net_lookup", { address: h.address }).catch((e) => ({ error: String(e) })); renderNetwork(); setTimeout(() => document.querySelector(".net-lookup")?.scrollIntoView({ behavior: "smooth", block: "center" }), 50); };
        return r;
      }) : [setRow("Nothing listed matches", "Agents show here when their owners list them.", null)]));
    } catch (e) { toast("Couldn't search", String(e), "error"); }
  });
  q.addEventListener("keydown", (e) => { if (e.key === "Enter") go.click(); });
  row.append(q, go);
  c.append(row, list);
  return c;
}

function netSettings() {
  const g = el("div", "group");
  const cap = input(String(netStatus.daily_cap), "40", { type: "number", min: "0", max: "1000" });
  cap.onchange = async () => { netStatus = await call("net_update", { patch: { daily_cap: +cap.value } }).catch((e) => (toast("Couldn't save", String(e), "error"), netStatus)); };
  const desk = input(netStatus.front_desk_model ?? "", "Same model as the first agent");
  desk.onchange = async () => { netStatus = await call("net_update", { patch: { front_desk_model: desk.value } }).catch((e) => (toast("Couldn't save", String(e), "error"), netStatus)); };
  const nm = input(netStatus.display_name ?? "", "Your name");
  nm.onchange = async () => { netStatus = await call("net_update", { patch: { display_name: nm.value } }).catch((e) => (toast("Couldn't save", String(e), "error"), netStatus)); };
  g.append(
    setRow("Answers per agent per day", "For guests and contacts. They spend your model budget.", cap),
    setRow("Front desk model", "Picks which agent answers a message sent to you.", desk),
    setRow("Your name", "What your page and contacts see.", nm),
    setRow("Relay", netStatus.relay, button("Move", "quiet small", () => { netStatus.handle = null; $("network-body").replaceChildren(...[el("div", "today-hero")], setupCard()); })),
  );
  return g;
}

async function copyReceipt(d) {
  const text = JSON.stringify({ deal: d.deal, signatures: { [addr(d.deal.from)]: d.from_sig, [addr(d.deal.to)]: d.to_sig } }, null, 2);
  copy(text, "Signed receipt copied");
}

/* ---------- a conversation ---------- */
function backBar(title, sub, face, extra) {
  const h = el("div", "net-back");
  const b = el("button", "round soft"); b.setAttribute("aria-label", "Back to Network");
  b.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  b.onclick = () => { netView = { kind: "home" }; renderNetwork(); };
  const t = el("div", "row-text"); t.append(strong(title), el("small", null, sub));
  h.append(b, face, t);
  if (extra) h.append(extra);
  return h;
}

function threadLog(lines) {
  const log = el("div", "net-log");
  if (!lines.length) log.append(el("p", "muted small", "Nothing here yet."));
  for (const l of lines) {
    const m = el("div", "net-msg " + (l.dir === "out" ? "out" : "in"));
    const b = el("div", "bubble md");
    b.innerHTML = Md.render(l.text);
    m.append(el("small", null, `${l.who} · ${fmtTime(l.at)}`), b);
    log.append(m);
  }
  requestAnimationFrame(() => { log.lastElementChild?.scrollIntoView({ block: "end" }); });
  return log;
}

function netComposer(placeholder, onSend) {
  const f = el("form", "net-compose");
  const ta = el("textarea"); ta.rows = 1; ta.placeholder = placeholder; ta.setAttribute("aria-label", placeholder);
  const go = el("button", "round go"); go.type = "submit"; go.setAttribute("aria-label", "Send"); go.disabled = true;
  go.innerHTML = '<svg class="ic-send"><use href="#i-up"/></svg>';
  ta.oninput = () => { go.disabled = !ta.value.trim(); ta.style.height = "auto"; ta.style.height = Math.min(ta.scrollHeight, 160) + "px"; };
  ta.onkeydown = (e) => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); f.requestSubmit(); } };
  f.onsubmit = async (e) => {
    e.preventDefault();
    const text = ta.value.trim();
    if (!text) return;
    go.disabled = true;
    try { await onSend(text); ta.value = ""; ta.oninput(); }
    catch (err) { toast("Couldn't send it", String(err), "error"); go.disabled = false; }
  };
  f.append(ta, go);
  return f;
}

async function contactView(id) {
  const c = (await call("net_contacts")).find((x) => x.id === id);
  if (!c) { netView = { kind: "home" }; return homeView(); }
  const lines = await call("net_thread", { id });
  const level = select([["talk", "Can ask questions"], ["work", "Can ask for work"]], c.level, async (v) => { await call("net_contact_set", { id, patch: { level: v } }); });
  level.setAttribute("aria-label", "What they may do");
  const more = el("div", "row-actions");
  more.append(level,
    c.state === "blocked"
      ? button("Unblock", "quiet small", async () => { await call("net_contact_set", { id, patch: { unblock: true } }); renderNetwork(); })
      : button("Block", "quiet small danger", async () => { await call("net_contact_set", { id, patch: { block: true } }); renderNetwork(); }),
    button("Remove", "quiet small", async () => { await call("net_contact_remove", { id }); netView = { kind: "home" }; renderNetwork(); }),
  );
  const parts = [backBar(c.remote_name, `${addr(c.remote)} · with ${localName(c.local)}`, contactFace(c, 40), more)];
  if (c.remote_job) parts.push(el("p", "muted small net-job", c.remote_job));
  parts.push(threadLog(lines));
  if (c.state === "accepted") {
    parts.push(netComposer(`Write to ${c.remote_name} yourself`, (text) => call("net_send", { id, text })));
    parts.push(el("p", "muted small", c.local ? `${localName(c.local)} also writes here when it uses message_contact; each of its messages asks you first.` : "Their front desk passes this to the right agent; the answer comes back here."));
  } else {
    parts.push(el("p", "muted small", c.state === "knock_out" ? "Waiting for them to accept your knock." : c.state === "blocked" ? "Blocked: nothing from them reaches you." : "They declined."));
  }
  return parts;
}

async function guestView(id) {
  const lines = await call("net_thread", { id });
  return [backBar(`Guest ${id.slice(6, 12)}`, "Chatting on your page without Cookie. Your agent answered at talk level: nothing of yours changes.", personDot("G", 40)), threadLog(lines)];
}

async function roomView(id) {
  const room = (await call("net_rooms")).find((r) => r.id === id);
  if (!room) { netView = { kind: "home" }; return homeView(); }
  const lines = await call("net_thread", { id: "room-" + id });
  const leave = button("Leave", "quiet small", async () => { await call("net_leave_room", { id }); netView = { kind: "home" }; renderNetwork(); });
  const chips = el("div", "net-members");
  for (const m of room.members) {
    const c = el("span", "net-member");
    c.append(m.address.agent ? remoteFace(m.agent_id || addr(m.address), m.sign, 20).el : personDot(m.name, 20), el("span", null, m.address.agent ? `${m.name} · ${addr(m.address)}` : m.name));
    chips.append(c);
  }
  return [
    backBar(room.name, `${room.members.length} members · started by ${room.created_by}`, roomStack(room), leave),
    chips,
    threadLog(lines),
    netComposer("Write to the room. Name an agent (@sales) to ask it.", (text) => call("net_room_send", { id, text })),
  ];
}

async function newRoomView() {
  const contacts = (await call("net_contacts")).filter((c) => c.state === "accepted");
  const name = input("", "Room name, e.g. Widget order");
  const pick = (label, sub, face) => { const w = el("label", "row net-pick"); const cb = el("input"); cb.type = "checkbox"; const t = el("div", "row-text"); t.append(el("span", null, label), el("small", null, sub)); w.append(cb, face, t); return [w, cb]; };
  const mine = el("div", "group"), theirs = el("div", "group");
  const agentBoxes = rows.filter((r) => !r.shadow_of).map((r) => { const [w, cb] = pick(r.name, r.job, Faces.create(r.id, 26).el); mine.append(w); return [r.id, cb]; });
  const contactBoxes = contacts.map((c) => { const [w, cb] = pick(c.remote_name, addr(c.remote), contactFace(c, 26)); theirs.append(w); return [c.id, cb]; });
  if (!contacts.length) theirs.append(setRow("No contacts yet", "Add someone first; rooms are for people you've accepted.", null));
  const go = button("Create room", "primary small", async () => {
    try {
      const room = await call("net_create_room", { name: name.value, agents: agentBoxes.filter(([, cb]) => cb.checked).map(([id]) => id), contacts: contactBoxes.filter(([, cb]) => cb.checked).map(([id]) => id) });
      netView = { kind: "room", id: room.id };
      renderNetwork();
    } catch (e) { toast("Couldn't create it", String(e), "error"); }
  });
  return [
    backBar("New room", "Your agents and your contacts' agents, in one thread.", personDot("+", 40)),
    name,
    el("h3", "group-title", "Your agents in it"), mine,
    el("h3", "group-title", "Contacts to invite"), theirs,
    el("p", "muted small", "Agents answer only when named, can't change anything from a room, and every message is sealed to each member."),
    go,
  ];
}

$("net-btn").onclick = () => openNetwork();
$("net-mini").onclick = () => openNetwork();
