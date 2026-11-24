// Settings and Connect apps.
let settingsTab = "general";

function refreshSettings() {
  if ($("settings").open) openSettings(settingsTab);
}

const SETTINGS = {
  async general() {
    const name = $("me-name").textContent;
    const acct = el("div", "group");
    const who = el("div", "row account");
    const id = el("div", "row-text"); id.append(el("span", null, name), el("small", null, Api.web ? "Signed in to this runner." : "Signed in to this computer. Cookie keeps everything here."));
    who.append(el("span", "initials", $("me-initials").textContent), id);
    acct.append(who);
    const look = el("div", "group");
    look.append(
      setRow("Theme", null, select([["system", "Follow system"], ["dark", "Dark"], ["light", "Light"], ["white", "White"], ["glass", "Glass"]], prefs.get("theme", "system"), (v) => prefs.set("theme", v))),
      setRow("Check spelling while typing", null, toggle(prefs.get("spell", true), (v) => prefs.set("spell", v), "Check spelling")),
      setRow("Send with ⌘↵", "Enter starts a new line; ⌘↵ sends.", toggle(prefs.get("cmdEnter", false), (v) => prefs.set("cmdEnter", v), "Send with Command Enter")),
    );
    const s = await call("settings");
    const attention = el("div", "group");
    const cap = input(String(s.daily_notices), "8", { type: "number", min: 0, max: 50 });
    cap.classList.add("num-in");
    cap.onchange = () => call("update_settings", { patch: { daily_notices: +cap.value } });
    attention.append(setRow("News per day", "Interruptions from routines and other agents, across your team. A request for your yes always gets through.", cap));
    attention.append(setRow("Wake agents when their memory changes", "With Enkeon: when something worth their attention lands in an agent's memory, it starts a job on it. Each agent wakes a few times a day at most.", toggle(s.wake !== false, (v) => call("update_settings", { patch: { wake: v } }), "Wake agents")));
    return [el("h2", null, "General"), el("h3", "group-title", "Account"), acct, el("h3", "group-title", "Appearance"), look, el("h3", "group-title", "Attention"), attention];
  },

  async models() {
    const [list, s] = await Promise.all([call("key_providers"), call("settings")]);
    const keys = el("div", "group");
    for (const p of list) {
      const field = input("", p.set ? "Saved" : "Paste a key", { type: "password", autocomplete: "off", spellcheck: false });
      field.classList.add("key-in");
      const save = button(p.set ? "Replace" : "Save", "quiet small", async () => {
        await call("set_key", { provider: p.id, value: field.value });
        field.value = "";
        providers = await call("providers");
        toast(`${p.label} key saved`, Api.web ? "Saved on the runner." : "It's in your Keychain, not in Cookie's folder.", "good");
        refreshSettings();
      });
      const ctl = el("div", "inline-row"); ctl.append(el("span", "status-pill" + (p.set ? " ok" : ""), p.set ? "Set" : "None"), field, save);
      keys.append(setRow(p.label, p.env, ctl));
    }
    const check = el("div", "group");
    const checker = input(s.checker_model ?? "", "e.g. openai:gpt-6 (another provider)", { spellcheck: false });
    checker.setAttribute("list", "models");
    checker.onchange = () => call("update_settings", { patch: { checker_model: checker.value } }).then(() => toast("Checker saved", checker.value ? `${checker.value} reads every send before you see it.` : "No checker.", "good"));
    check.append(setRow("Checker model", "Reads every send, post, delete or payment before you see it. Pick another provider's model: two makers rarely share a blind spot.", null), checker);

    // Prices: per million tokens, set by you (none ship with Cookie).
    const prices = el("div", "group");
    const models = [...new Set([...rows.map((r) => r.model), ...Object.keys(s.prices)])];
    for (const m of models) {
      const p = s.prices[m] ?? {};
      const i = input(p.input ?? "", "in $/M", { type: "number", min: 0, step: "any" }), o = input(p.output ?? "", "out $/M", { type: "number", min: 0, step: "any" });
      i.classList.add("num-in"); o.classList.add("num-in");
      const save = () => {
        const next = { ...s.prices };
        if (i.value === "" && o.value === "") delete next[m];
        else next[m] = { input: +i.value || 0, output: +o.value || 0, cache_read: p.cache_read ?? 0, cache_write: p.cache_write ?? 0 };
        s.prices = next;
        call("update_settings", { patch: { prices: next } });
      };
      i.onchange = save; o.onchange = save;
      const ctl = el("div", "inline-row"); ctl.append(i, o);
      prices.append(setRow(m, null, ctl));
    }
    if (!models.length) prices.append(setRow("No models in use yet", "Hire an agent first.", null));
    const def = el("div", "group");
    const all = Object.values(MODELS).flat();
    const cur = localStorage.getItem("cookie.lastModel") || all[0];
    def.append(setRow("Model for new hires", "Filled in when you hire. You can always type another.", select(all.map((m) => [m, m]), all.includes(cur) ? cur : all[0], (v) => { try { localStorage.setItem("cookie.lastModel", v); } catch {} })));
    return [el("h2", null, "Models"), el("h3", "group-title", "Keys"), keys, el("h3", "group-title", "Checker"), check,
      el("h3", "group-title", "Prices (dollars per million tokens)"), prices, el("p", "set-note", "Cookie ships no price table: prices change and a stale one lies. Set them, and every job shows what it cost and limits can be in dollars."),
      el("h3", "group-title", "Defaults"), def];
  },

  async channels() {
    const t = await call("telegram_status");
    const g = el("div", "group edit");
    const out = [el("h2", null, "Channels")];
    if (!t.has_token) {
      const tok = input("", "Bot token from @BotFather", { type: "password", spellcheck: false });
      g.append(setRow("Telegram", "Talk to your agents and approve from your phone. Make a bot with @BotFather in Telegram, then paste its token here.", null), tok);
      const end = el("div", "form-end");
      end.append(button("Connect", "primary small", async () => { const name = await call("telegram_connect", { token: tok.value }); toast("Telegram connected", `Your bot is ${name}.`, "good"); refreshSettings(); }));
      out.push(g, end);
      return out;
    }
    g.append(setRow("Telegram", `${t.chats} chat${t.chats === 1 ? "" : "s"} linked`, button("Disconnect", "quiet small danger", async () => { await call("telegram_disconnect"); refreshSettings(); })));
    const link = el("div", "group edit");
    if (t.code) link.append(setRow("Link a chat", `Send this to your bot from the chat you want to use: ${t.code}`, el("code", "copyable big", t.code)));
    else link.append(setRow("Link a chat", "Get a one-time code and send it to your bot.", button("Get a code", "quiet small", async () => { await call("telegram_code"); refreshSettings(); })));
    const how = el("p", "set-note", "In a linked chat: @AgentName and what you need, /use AgentName to pick who plain messages go to, /agents for the list. Every yes arrives with Approve and Deny buttons.");
    out.push(g, link, how);
    return out;
  },

  async sharing() {
    const st = await call("server_status");
    const g = el("div", "group");
    g.append(setRow("Serve this team", "Lets your phone, another computer, or other people's agents reach your team over HTTP.", toggle(st.enabled, async (v) => { await call("update_settings", { patch: { server: { enabled: v } } }); setTimeout(refreshSettings, 400); }, "Serve this team")));
    const bind = input(st.bind, "127.0.0.1"), port = input(String(st.port), "4519", { type: "number" }), pub = input(st.public_url ?? "", "https://cookie.example.com");
    port.classList.add("num-in");
    const save = button("Save", "quiet small", async () => { await call("update_settings", { patch: { server: { bind: bind.value, port: +port.value, public_url: pub.value } } }); setTimeout(refreshSettings, 400); });
    const net = el("div", "group edit");
    net.append(setRow("Listen on", "127.0.0.1 keeps it on this computer. 0.0.0.0 opens it to your network: put HTTPS in front first.", null), el("div", "inline-row", null));
    net.lastChild.append(bind, port);
    net.append(setRow("Public address", "Where others reach it (behind HTTPS, e.g. a tunnel). Needed for invites.", null), pub);
    const end = el("div", "form-end"); end.append(save);
    const out = [el("h2", null, "Sharing"), g, net, end];
    if (st.listening) {
      const token = await call("runner_token");
      const base = st.public_url ?? `http://${st.bind}:${st.port}`;
      const link = `${base}/#token=${token}`;
      const open = el("div", "group edit");
      open.append(setRow("Open on another device", `Listening on ${st.listening}. Anyone with this link controls your team: keep it private.`, null), el("code", "copyable", link));
      const acts = el("div", "form-end");
      acts.append(
        button("Copy link", "quiet small", async () => { await navigator.clipboard.writeText(link); toast("Link copied", "", "good"); }),
        button("New link", "quiet small danger", async () => { await call("runner_token", { rotate: true }); refreshSettings(); }),
      );
      out.push(el("h3", "group-title", "Your link"), open, acts);
    }
    // Job links: opening Cookie from a link it sent, with a PIN.
    const ls = await call("links_status").catch(() => null);
    if (ls) {
      const pin = el("div", "group edit");
      pin.append(setRow(ls.pin_set ? "PIN is set" : "Set a PIN for job links", "Links in Cookie's messages open this team on another device only with your six-digit PIN. Five wrong tries end a link; three in a row lock it for 15 minutes.", ls.sessions ? button(`Sign out ${ls.sessions} device${ls.sessions === 1 ? "" : "s"}`, "quiet small danger", async () => { await call("end_link_sessions"); refreshSettings(); }) : null));
      const p = input("", "Six digits", { type: "password", inputmode: "numeric", maxlength: 6 });
      pin.append(p);
      const pe = el("div", "form-end");
      pe.append(button(ls.pin_set ? "Change PIN" : "Set PIN", "quiet small", async () => {
        try { await call("set_link_pin", { pin: p.value }); toast("PIN saved", "Devices opened with a link sign in again.", "good"); refreshSettings(); } catch (e) { toast("Couldn't save it", String(e), "error"); }
      }));
      out.push(el("h3", "group-title", "Job links"), pin, pe);
    }
    const runner = el("div", "group");
    runner.append(setRow("Always on, with this computer asleep", "Run the same team on an old Mac or a small server: `cookie-team serve --bind 0.0.0.0 --public-url https://…` (see desktop/RUNNER.md). Open its link from anywhere.", null));
    out.push(el("h3", "group-title", "Home or cloud runner"), runner);
    return out;
  },

  async market() {
    const s = await call("settings");
    const g = el("div", "group edit");
    const url = input(s.market_url ?? "", "https://… /index.json");
    const save = button("Save", "quiet small", async () => { await call("update_settings", { patch: { market_url: url.value } }); refreshSettings(); });
    g.append(setRow("Market address", "An index of agent packs others published. Every pack's signature is checked, and a hired agent starts with no access.", null), url);
    const end = el("div", "form-end"); end.append(save);
    const out = [el("h2", null, "Market"), g, end];
    // Import a pack file.
    const file = el("input"); file.type = "file"; file.accept = ".json,application/json"; file.hidden = true;
    file.onchange = async () => {
      const f = file.files[0]; if (!f) return;
      try {
        const pack = JSON.parse(await f.text());
        const hired = await call("import_pack", { pack, model: suggestions()[0] || null });
        await loadRoster();
        toast(`${hired.name} hired from a pack`, "It has no access yet: grant what it needs in its profile. It's on probation for a week.", "good");
        $("settings").close();
        openAgent(hired.id);
      } catch (e) { toast("That pack didn't check out", String(e), "error"); }
    };
    const imp = el("div", "group"); imp.append(setRow("Hire from a pack file", "A .cookie-agent.json someone sent you.", button("Choose file", "quiet small", () => file.click())), file);
    out.push(imp);
    if (s.market_url) {
      const list = el("div", "group");
      try {
        const agents = await call("market");
        if (!agents.length) list.append(setRow("The market is empty", null, null));
        for (const a of agents) {
          list.append(setRow(a.name ?? "Unnamed", a.description ?? a.job ?? "", button("Hire", "primary small", async () => {
            const hired = await call("install", { url: a.pack_url, model: suggestions()[0] || null });
            await loadRoster();
            toast(`${hired.name} hired`, "No access until you grant it; on probation for a week.", "good");
          })));
        }
      } catch (e) { list.append(el("p", "error-line", String(e))); }
      out.push(el("h3", "group-title", "Listed"), list);
    }
    const key = await call("publisher_key").catch(() => "");
    out.push(el("p", "set-note", `Packs you export are signed with your key ${key.slice(0, 16)}…`));
    return out;
  },

  async privacy() {
    const dir = await call("data_dir");
    const s = await call("settings");
    const g = el("div", "group");
    g.append(setRow("Cookie's folder", dir, Api.web ? null : button("Open", "quiet small", () => Api.reveal(dir))));
    const walls = el("div", "group");
    walls.append(
      setRow("Each agent has its own folder", "Its conversation and files stay apart from your other agents.", el("span", "status-pill ok", "On")),
      setRow("Text it reads is never an instruction", "Files, pages, mail and other agents' words are data. They can't tell an agent to send or delete.", el("span", "status-pill ok", "On")),
      setRow("Sending, deleting and paying ask you first", "No agent earns the right to skip that, however good its record.", el("span", "status-pill ok", "Always")),
      setRow("Every action is signed", "Each agent keeps a hashed, chained, signed log of what it did.", el("span", "status-pill ok", "On")),
    );
    const ch = el("div", "group edit");
    const model = input(s.challenge_model ?? "", "model for the public challenge, or empty for off", { spellcheck: false });
    model.setAttribute("list", "models");
    model.onchange = () => call("update_settings", { patch: { challenge_model: model.value } }).then(refreshSettings);
    ch.append(setRow("“Try to trick my Cookie”", "A public page (/challenge on your shared address) where anyone tries to make a demo agent leak a code or send it. Nothing it does can cause harm; every try is on the board.", null), model);
    return [el("h2", null, "Privacy"), el("h3", "group-title", "Where your data lives"), g, el("h3", "group-title", "Walls"), walls, el("h3", "group-title", "Proof"), ch];
  },

  async about() {
    const g = el("div", "group");
    g.append(setRow("Version", null, el("span", "muted", await call("version"))), setRow("Made by", null, el("span", "muted", "Enkeon")));
    const hero = el("div", "about-hero");
    const f = Faces.create("cookie", 72);
    hero.append(f.el, el("h3", null, "Cookie"), el("p", "muted", "A team of focused agents, each behind its own walls."));
    return [el("h2", null, "About"), hero, g];
  },
};

async function openSettings(tab = "general") {
  settingsTab = SETTINGS[tab] ? tab : "general";
  const d = $("settings");
  $("set-nav").querySelectorAll("button").forEach((b) => b.classList.toggle("on", b.dataset.tab === settingsTab));
  try { $("set-body").replaceChildren(...(await SETTINGS[settingsTab]())); }
  catch (e) { $("set-body").replaceChildren(el("p", "error-line", String(e))); }
  if (!d.open) d.showModal();
}
$("set-nav").onclick = (e) => { const t = e.target.closest("[data-tab]")?.dataset.tab; if (t) openSettings(t); };

/* ---------- Enkeon pairing ---------- */
const PAIR_WORDS = {
  waiting: "Confirm this code in the browser window that opened.",
  expired: "The code expired before it was confirmed. Pair again.",
  denied: "The sign-in was turned down in the browser.",
};
let pairTimer = null;

/** Pair this computer with Enkeon: a code, the browser, then a key kept in the Keychain. */
async function openEnkeon() {
  clearTimeout(pairTimer);
  const d = $("connect");
  const body = $("connect-body");
  let st;
  try { st = await call("enkeon"); } catch (e) { body.replaceChildren(el("p", "error-line", String(e))); if (!d.open) d.showModal(); return; }
  const out = [el("h2", null, "Enkeon")];
  const p = st.pairing;
  if (st.paired) {
    out.push(el("p", "set-note", `Paired with “${st.paired.project_name}”${st.paired.by ? ` as ${st.paired.by}` : ""}. Every agent keeps its own space there, and reads your shared material.`));
    out.push(button("Unpair this computer", "quiet small danger", async () => {
      try { const r = await call("unpair"); toast("Unpaired", r.note); openEnkeon(); } catch (e) { toast("Couldn't unpair", String(e), "err"); }
    }));
  } else if (st.source === "cli" || st.source === "env") {
    out.push(el("p", "set-note", st.source === "cli" ? "Connected through the Enkeon CLI's sign-in on this computer. Pairing here gives Cookie its own key instead." : "Connected through ENKEON_API_KEY. Pairing here gives Cookie its own key instead."));
  } else {
    out.push(el("p", "set-note", "Pair once and every agent gets memory with proof, and Gmail, Drive, Slack and more through Enkeon's connectors."));
  }
  if (p && p.state === "waiting") {
    const code = el("div", "pair-code", p.user_code);
    out.push(code, el("p", "set-note", PAIR_WORDS.waiting));
    out.push(el("div", "row-actions", button("Open the browser again", "quiet small", () => Api.openUrl(p.url).catch((e) => toast("Couldn't open it", String(e), "err"))), button("Cancel", "quiet small", async () => { await call("pair_cancel"); openEnkeon(); })));
    pairTimer = setTimeout(() => { if (d.open) openEnkeon(); }, 2500);
  } else if (p && p.state === "choose") {
    out.push(el("p", "set-note", "Which memory should this computer use?"));
    for (const proj of p.projects) {
      out.push(button(proj.name, "quiet", async () => {
        try { await call("pair_choose", { project: proj.id }); toast("Paired", `Cookie now uses “${proj.name}”.`); openEnkeon(); }
        catch (e) { toast("Couldn't pair", String(e), "err"); }
      }));
    }
  } else if (p && p.state === "done") {
    out.push(el("p", "set-note ok", "Paired."));
  } else if (p && (p.state === "failed" || p.state === "expired" || p.state === "denied")) {
    out.push(el("p", "error-line", p.error || PAIR_WORDS[p.state]));
  }
  if (!st.paired && !(p && (p.state === "waiting" || p.state === "choose"))) {
    out.push(button(st.connected ? "Pair Cookie with its own key" : "Pair with Enkeon", "primary", async () => {
      try { const r = await call("pair_start"); if (r.url) await Api.openUrl(r.url).catch(() => {}); openEnkeon(); }
      catch (e) { toast("Couldn't start pairing", String(e), "err"); }
    }));
  }
  body.replaceChildren(...out);
  if (!d.open) d.showModal();
}

/* ---------- connect apps ---------- */
const APPS = [
  ["Enkeon", "Memory with proof, and Gmail, Drive, Slack and more through its connectors", "Connected", "#d97706", "enkeon"],
  ["Telegram", "Talk to your agents and approve from your phone", "Connected", "#229ed9", "telegram"],
  ["Other people's agents", "Invite theirs, or let yours message them (A2A)", "Connected", "#7c3aed", "peers"],
  ["Slack", "Talk to your agents in Slack", "Channels", "#4a154b", "channel"], ["Discord", "Talk to your agents in Discord", "Channels", "#5865f2", "channel"],
  ["iMessage", "Text your agents from your iPhone", "Channels", "#34c759", "channel"], ["Signal", "Talk to your agents on Signal", "Channels", "#3a76f0", "channel"],
  ["Calendar", "See your days, add events", "This Mac", "#ef4444", "mac"],
  ["Notes", "Find, read and save notes", "This Mac", "#eab308", "mac"], ["Reminders", "Check, add and complete reminders", "This Mac", "#f97316", "mac"],
  ["Contacts", "Look up emails and numbers", "This Mac", "#64748b", "mac"],
  ["Messages", "Send iMessages (asks you each time)", "This Mac", "#22c55e", "mac"],
  ["Mail", "Read and draft replies in Apple Mail", "This Mac", "#3b82f6"],
  ["MCP server", "Any tool that speaks MCP", "Developer", "#0ea5e9"],
];

async function openConnect(filter = "All", q = "") {
  const d = $("connect");
  const body = $("connect-body");
  const [enkeon, tg] = await Promise.all([call("enkeon_status").catch(() => false), call("telegram_status").catch(() => ({}))]);
  const live = { enkeon: !!enkeon, telegram: !!tg.has_token, peers: true };
  const cats = ["All", ...new Set(APPS.map((a) => a[2]))];
  const head = el("div", "connect-head");
  head.append(el("h2", null, "Connect apps"), el("span", "status-pill" + (live.enkeon || live.telegram ? " ok" : ""), `${[live.enkeon, live.telegram].filter(Boolean).length} connected`));
  const search = el("div", "search-wrap connect-search");
  const inp = el("input");
  inp.type = "search"; inp.placeholder = "Search apps"; inp.value = q;
  inp.oninput = () => openConnect(filter, inp.value);
  search.append(icon("search"), inp);
  const chips = el("div", "chip-row");
  for (const c of cats) { const b = el("button", c === filter ? "on" : "", c); b.onclick = () => openConnect(c, inp.value); chips.append(b); }
  const shown = APPS.filter((a) => (filter === "All" || a[2] === filter) && (!q || a[0].toLowerCase().includes(q.toLowerCase())));
  const groups = filter === "All" ? cats.slice(1) : [filter];
  const sections = groups.map((g) => {
    const items = shown.filter((a) => a[2] === g);
    if (!items.length) return null;
    const sec = el("section", "app-sec");
    const grid = el("div", "app-grid");
    for (const [name, what, , color, kind] of items) {
      const card = el("div", "app");
      const tile = el("span", "app-tile", name[0]);
      tile.style.background = color;
      const t = el("div", "row-text"); t.append(el("span", null, name), el("small", null, what));
      let b;
      if (kind === "enkeon") b = button(live.enkeon ? "Manage" : "Pair", "quiet small", () => { d.close(); openEnkeon(); });
      else if (kind === "telegram") b = button(live.telegram ? "Manage" : "Connect", "quiet small", () => { d.close(); openSettings("channels"); });
      else if (kind === "peers") b = button("Open", "quiet small", () => { d.close(); if (current) openProfile("share"); else openSettings("sharing"); });
      else if (kind === "channel") b = button("Set up", "quiet small", () => { d.close(); openSettings("channels"); });
      else if (kind === "mac") b = button("Turn on", "quiet small", () => {
        d.close();
        if (current) { openProfile("about"); toast("Turn on Mac apps", `Switch on “Mac apps” for ${current.name}. macOS asks once per app the first time.`); }
        else toast("Turn on Mac apps", "Open an agent, then its profile → Mac apps. Each agent gets them only if you say so.");
      });
      else { b = el("button", "btn quiet small", "Soon"); b.disabled = true; }
      card.append(tile, t, b);
      grid.append(card);
    }
    sec.append(el("h3", "group-title", g), grid);
    return sec;
  }).filter(Boolean);
  const note = el("p", "set-note", "Mac apps are per agent: turn them on in an agent's profile. Apple Mail and MCP servers aren't connected yet. Gmail, Drive and Slack already work through Enkeon.");
  body.replaceChildren(head, search, chips, ...(sections.length ? sections : [el("p", "set-note", "No app matches.")]), note);
  if (!d.open) d.showModal();
  if (q) { inp.focus(); inp.setSelectionRange(q.length, q.length); }
}
