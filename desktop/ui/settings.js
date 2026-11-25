// Settings and Connect apps.
let settingsTab = "general";

function refreshSettings() {
  if ($("settings").open) openSettings(settingsTab);
}

/** What leaves this Mac, crash reports (off unless you say), and deleting it all. */
async function yourDataPart() {
  // Privacy and your data: what leaves this Mac, crash reports (off unless you say), deleting it all.
  const data = await call("data_summary");
  const priv = el("div", "group");
  const leaves = el("ul", "plain-list");
  for (const t of [
    "The model you pick for an agent reads its jobs and what its tools return. Local models (Ollama) never leave this Mac.",
    "Signed in with Enkeon: each agent's memories, what you connect there, and — for agents you let run in the cloud — their names, jobs and routines.",
    "Chats you link (Slack, Telegram, …) carry the messages you send through them; web search sends the search words.",
    "Crash reports are never sent. Turned on, they're written on this Mac for you to read and share.",
  ]) leaves.append(el("li", null, t));
  priv.append(setRow("What leaves this Mac", null, null), leaves);
  priv.append(setRow("Crash reports", "Off unless you turn them on. A crash is written to this Mac — what failed and where, never a conversation, file or key.",
    toggle(!!data.crash_reports, async (v) => { await call("set_crash_reports", { on: v }); refreshSettings(); }, "Crash reports")));
  if (data.crashes) {
    priv.append(setRow(`${data.crashes} crash report${data.crashes === 1 ? "" : "s"}`, "Copy one to share it, or clear them.", box("div", "row-actions",
      button("Copy newest", "quiet small", async () => { const [r] = await call("crash_reports"); const full = await call("crash_report", { id: r.id }); await navigator.clipboard.writeText(JSON.stringify(full, null, 2)); toast("Copied", "The newest crash report is on your clipboard.", "good"); }),
      button("Clear", "quiet small", async () => { await call("clear_crash_reports"); refreshSettings(); }))));
  }
  priv.append(setRow("Delete everything on this Mac", `Every agent, chat, memory ledger, file and setting in ${data.folder} (${humanSize(data.bytes || 0)}), and every key Cookie saved in the Keychain. Your Enkeon brain stays in Enkeon.`,
    button("Delete…", "quiet small danger", async () => {
      const word = prompt("This can't be undone. Type DELETE to erase everything Cookie keeps on this Mac.");
      if (word == null) return;
      const r = await call("erase_everything", { confirm: word });
      toast("Deleted", r.note, "");
    })));
  return [el("h3", "group-title", "Your data"), priv];
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

  async evolution() {
    const [s, bench, ev, local] = await Promise.all([call("settings"), call("bench"), call("evolve_status"), call("local_models").catch(() => null)]);
    const e = s.evolve;
    const out = [el("h2", null, "Evolution")];
    const g = el("div", "group");
    g.append(setRow("Tune agents at night", "Each night, one change per agent is tried on a copy against your own jobs, and kept only if it does as well or better. Every change shows in the agent's Evolution tab with Undo. Exams use real model calls, so the night has a budget.", toggle(!!e.nightly, (v) => call("update_settings", { patch: { evolve: { nightly: v } } }), "Tune at night")));
    const hour = input(String(e.hour), "3", { type: "number", min: 0, max: 23 }), dollarsIn = input(String(e.max_dollars), "1", { type: "number", min: 0, step: "0.5" }), cases = input(String(e.cases), "6", { type: "number", min: 3, max: 20 });
    for (const i of [hour, dollarsIn, cases]) i.classList.add("num-in");
    g.append(setRow("Hour it starts", "Your local time, when nothing is working.", hour), setRow("Most a night may spend ($)", "Needs prices set for the models (Models); without them, a few exams at most.", dollarsIn), setRow("Jobs per exam", "Each runs twice: as it is, and changed.", cases));
    const end = el("div", "form-end");
    end.append(button("Save", "quiet small", async () => { await call("update_settings", { patch: { evolve: { hour: +hour.value, max_dollars: +dollarsIn.value, cases: +cases.value } } }); toast("Saved", "", "good"); }),
      button("Run tonight's round now", "quiet small", async () => { await call("evolve_now"); toast("Started", "Results show in each agent's Evolution tab, and in a note from Cookie."); }));
    out.push(g, end);

    const b = el("div", "group");
    b.append(setRow(`The bench: ${bench.count} of your jobs`, bench.count >= 30 ? "Changes are examined on these: jobs your agents finished cleanly, the ones you graded good first." : `Aim is 30 to 50. It has what your agents did cleanly so far (${bench.count}); it grows as they work and is never padded with made-up tasks.`,
      button(bench.built_at ? "Choose again" : "Build it", "quiet small", async () => { await call("build_bench"); refreshSettings(); })));
    for (const c of bench.cases.slice(0, 50)) {
      const who = agentById(c.agent)?.name ?? "an agent";
      b.append(setRow(plain(c.input).slice(0, 110), `${who}${c.graded_good ? " · graded good" : ""}`, button("Drop", "quiet small", async () => { await call("drop_bench_case", { case: c.id }); refreshSettings(); })));
    }
    out.push(el("h3", "group-title", "Bench"), b);

    if (ev.last_night) {
      const n = el("div", "group");
      n.append(setRow(`Last round: ${ev.last_night.day}`, `${ev.last_night.exams} exams${ev.last_night.spent_microdollars ? `, ${dollars(ev.last_night.spent_microdollars)}` : ""}.`, null));
      for (const l of ev.last_night.log.slice(0, 20)) n.append(el("p", "set-note", l));
      out.push(el("h3", "group-title", "Last round"), n);
    }

    if (local && (local.used.length || local.loaded.length)) {
      const l = el("div", "group");
      if (!local.reachable) l.append(setRow("Ollama", `Not reachable at ${local.server}.`, null));
      for (const m of local.loaded) l.append(setRow(m.model, `In memory: ${humanSize(m.bytes || 0)}${m.agents.length ? ` · shared by ${m.agents.join(", ")}` : ""}`, null));
      for (const d of local.doubles) l.append(setRow(`Two copies of ${d.base}`, `Your agents use ${d.tags.join(" and ")}; Ollama loads each separately. Put them on one tag to share memory.`, null));
      out.push(el("h3", "group-title", "Local models"), l);
    }
    return out;
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
    const out = [el("h2", null, "Sharing"), ...(await addressPart()), ...(await aiToolsPart(st)), el("h3", "group-title", "This team over HTTP"), g, net, end];
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
      // The phone app: scan once, and it keeps the address and the key in its own secure storage.
      const pairUrl = `cookie://pair?u=${encodeURIComponent(base)}&t=${encodeURIComponent(token)}`;
      const qr = await call("net_qr", { text: pairUrl }).catch(() => null);
      if (qr) {
        const phone = el("div", "group edit");
        const box = el("div", "phone-qr");
        box.innerHTML = qr;
        phone.append(setRow("Cookie on your phone", st.public_url ? "Open Cookie on your phone and scan this. Anyone who scans it controls your team: show it only to your own phone." : "Set a public address above (behind HTTPS) so your phone can reach this computer away from home, then scan this with Cookie on your phone.", null), box);
        out.push(el("h3", "group-title", "Phone"), phone);
      }
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
    out.push(imp, ...teamsPart());
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
    return [el("h2", null, "Privacy"), el("h3", "group-title", "Where your data lives"), g, ...(await yourDataPart()), el("h3", "group-title", "Walls"), walls, el("h3", "group-title", "Proof"), ch];
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
    const [cl, s] = await Promise.all([call("cloud").catch(() => null), call("settings")]);
    const g = el("div", "group");
    g.append(setRow("Keep approvals, notices and answers in Enkeon", "So your phone and the Console see them, and you can say yes or no from there. Only the words: never your files.", toggle(!!s.cloud?.store, (v) => call("update_settings", { patch: { cloud_store: v } }), "Cloud store")));
    if (cl) g.append(setRow("Last contact", cl.last_error ? `Not reached: ${cl.last_error}` : cl.last_ok ? new Date(cl.last_ok * 1000).toLocaleString() : "Not yet", null));
    out.push(g);
    const grid = el("div", "apps-grid compact");
    out.push(el("h3", "group-title", "Apps your agents use"), grid);
    setTimeout(() => renderApps(grid), 0);
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
    out.push(box("div", "row-actions", button("Open the browser again", "quiet small", () => Api.openUrl(p.url).catch((e) => toast("Couldn't open it", String(e), "err"))), button("Cancel", "quiet small", async () => { await call("pair_cancel"); openEnkeon(); })));
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
// [name, what, group, logo key or brand colour, kind]
const APPS = [
  ["Enkeon", "Memory with proof, and your apps through its connectors", "Connected", "enkeon", "enkeon"],
  ["Telegram", "Talk to your agents and approve from your phone", "Channels", "telegram", "telegram"],
  ["Slack", "Talk to your agents in Slack", "Channels", "slack", "channel"], ["Discord", "Talk to your agents in Discord", "Channels", "discord", "channel"],
  ["iMessage", "Text your agents from your iPhone", "Channels", "imessage", "channel"], ["Signal", "Talk to your agents on Signal", "Channels", "signal", "channel"],
  ["Other people's agents", "Invite theirs, or let yours message them (A2A)", "Channels", "#7c3aed", "peers"],
  ["Calendar", "See your days, add events", "This Mac", "calendar", "mac"],
  ["Notes", "Find, read and save notes", "This Mac", "notes", "mac"], ["Reminders", "Check, add and complete reminders", "This Mac", "reminders", "mac"],
  ["Contacts", "Look up emails and numbers", "This Mac", "contacts", "mac"],
  ["Messages", "Send iMessages (asks you each time)", "This Mac", "messages", "mac"],
  ["Mail", "Read and draft replies in Apple Mail", "This Mac", "mail"],
];
const CONNECT_GROUPS = ["All", "Connected", "Apps", "Channels", "This Mac", "Passwords", "Developer"];
let connectState = { filter: "All", q: "", data: null, timer: null };

/** A logo: the app's own icon, a brand mark on its colour, or a letter. */
function logoTile(key, name) {
  const t = el("span", "app-tile");
  const src = (typeof LOGOS !== "undefined" && LOGOS[key]) || (typeof APP_LOGOS !== "undefined" && APP_LOGOS[key]);
  if (src) {
    const img = el("img"); img.src = src; img.alt = "";
    if (LOGO_BG[key]) { t.classList.add("glyph"); t.style.background = LOGO_BG[key]; }
    else if (LOGOS[key]) t.classList.add("bare");
    else t.classList.add("mark");
    t.append(img);
  } else if (key === "peers" || (key || "").startsWith("#")) {
    t.style.background = key.startsWith("#") ? key : "#7c3aed"; t.append(icon("share"));
  } else { t.textContent = name[0]; t.style.background = "#3f3f46"; }
  return t;
}

async function loadConnect() {
  const [enkeon, tg, apps, mcps, op] = await Promise.all([
    call("enkeon_status").catch(() => false), call("telegram_status").catch(() => ({})),
    call("apps").catch(() => null), call("mcps").catch(() => ({ servers: [] })),
    call("onepassword_status").catch(() => ({ installed: false, allowed: [] })),
  ]);
  connectState.data = { enkeon: !!enkeon, telegram: !!tg.has_token, apps, mcps: mcps.servers || [], op };
}

async function openConnect(filter = "All", q = "") {
  connectState.filter = filter; connectState.q = q;
  const d = $("connect");
  const body = $("connect-body");
  const top = el("div", "connect-top");
  const head = el("div", "connect-head");
  const pill = el("span", "status-pill");
  const x = el("button", "round soft connect-x"); x.setAttribute("aria-label", "Close"); x.append(icon("x")); x.onclick = () => d.close();
  head.append(el("h2", null, "Connect apps"), pill, x);
  const search = el("div", "search-wrap connect-search");
  const inp = el("input");
  inp.type = "search"; inp.placeholder = "Search apps and servers"; inp.value = q;
  search.append(icon("search"), inp);
  const chips = el("div", "chip-row");
  const list = el("div", "connect-list");
  const paint = () => {
    chips.replaceChildren(...CONNECT_GROUPS.map((c) => { const b = el("button", c === connectState.filter ? "on" : "", c); b.onclick = () => { connectState.filter = c; paint(); }; return b; }));
    renderConnectList(list, pill);
  };
  inp.oninput = () => { connectState.q = inp.value; renderConnectList(list, pill); };
  top.append(head, search, chips);
  body.replaceChildren(top, list);
  if (!d.open) { d.showModal(); inp.focus({ preventScroll: true }); d.addEventListener("close", () => clearTimeout(connectState.timer), { once: true }); }
  list.replaceChildren(el("p", "set-note", "Loading…"));
  await loadConnect();
  paint();
  inp.focus({ preventScroll: true });
  if (q) inp.setSelectionRange(q.length, q.length);
}

/** Refresh in place (a connect finished, a server was added). */
async function refreshConnect() {
  const d = $("connect");
  if (!d?.open) return;
  await loadConnect();
  const list = d.querySelector(".connect-list"), pill = d.querySelector(".connect-head .status-pill");
  if (list) renderConnectList(list, pill);
}

function renderConnectList(list, pill) {
  const d = $("connect");
  const data = connectState.data;
  if (!data) return;
  const { filter } = connectState;
  const q = connectState.q.trim().toLowerCase();
  const match = (name, what = "") => !q || name.toLowerCase().includes(q) || what.toLowerCase().includes(q);
  const st = data.apps;
  const linked = (st?.apps || []).filter((a) => a.state === "connected");
  const opOn = data.op?.installed && (data.op.allowed || []).length > 0;
  const count = (data.enkeon ? 1 : 0) + (data.telegram ? 1 : 0) + (opOn ? 1 : 0) + linked.length + data.mcps.filter((m) => m.on).length;
  pill.className = "status-pill" + (count ? " ok" : "");
  pill.textContent = `${count} connected`;

  const row = (logo, name, what, action, extra) => {
    const card = el("div", "app" + (extra ? " " + extra : ""));
    const t = el("div", "row-text"); t.append(el("span", null, name), el("small", null, what));
    card.append(logo, t, action || el("span"));
    return card;
  };
  const sections = [];
  const section = (title, items, note) => {
    const kept = items.filter(Boolean);
    if (!kept.length) return;
    const sec = el("section", "app-sec");
    const grid = el("div", "app-grid"); grid.append(...kept);
    sec.append(el("h3", "group-title", title), grid);
    if (note) sec.append(note);
    sections.push(sec);
  };
  const want = (g) => filter === "All" || filter === g;

  // Connected: only what really is.
  if (want("Connected")) {
    const items = [];
    if (data.enkeon && match("Enkeon")) items.push(row(logoTile("enkeon", "Enkeon"), "Enkeon", "Your brain: memory with proof", button("Manage", "quiet small", () => { d.close(); openEnkeon(); })));
    if (data.telegram && match("Telegram")) items.push(row(logoTile("telegram", "Telegram"), "Telegram", "Your bot is on", button("Manage", "quiet small", () => { d.close(); openSettings("channels"); })));
    if (opOn && match("1Password", "passwords")) items.push(row(logoTile("1password", "1Password"), "1Password", `${data.op.allowed.length} vault${data.op.allowed.length === 1 ? "" : "s"} for agents · they never see a password`, button("Manage", "quiet small", () => openOnePassword())));
    for (const a of linked) if (match(a.name, a.what)) items.push(row(logoTile(a.slug, a.name), a.name, a.synced ? `${Number(a.synced).toLocaleString()} synced · through Enkeon` : "Connected through Enkeon", el("span", "conn-dot", "On")));
    for (const m of data.mcps.filter((m) => m.on)) if (match(m.name)) items.push(row(logoTile("mcp", m.name), m.name, `MCP · ${m.tools.length} tool${m.tools.length === 1 ? "" : "s"}`, el("span", "conn-dot", "On")));
    if (!items.length && filter === "Connected") sections.push(el("p", "set-note", q ? "Nothing connected matches." : "Nothing connected yet."));
    section("Connected", items);
  }

  // Apps through Enkeon (Gmail, Drive, Slack…).
  if (want("Apps")) {
    const items = [];
    if (!data.enkeon && !q) items.push(row(logoTile("enkeon", "Enkeon"), "Sign in with Enkeon", "Your apps connect through your Enkeon account", button("Sign in", "primary small", () => { d.close(); openEnkeon(); })));
    else if (st && !st.signed_in && st.paired && !q) {
      const s = st.signin;
      const act = s?.state === "waiting" ? el("span", "conn-dot wait", `Code ${s.user_code}`) : button("Sign in", "quiet small", async () => {
        try { const r = await call("apps_signin"); if (r.url) await Api.openUrl(r.url).catch(() => {}); } catch (e) { toast("Couldn't start sign-in", String(e), "error"); }
        refreshConnect();
      });
      items.push(row(logoTile("enkeon", "Enkeon"), "Sign in to manage apps", s?.state === "waiting" ? "Confirm the code in your browser" : "Connecting an app takes your Enkeon sign-in", act));
    }
    for (const a of (st?.apps || []).filter((a) => a.state !== "connected")) {
      if (!match(a.name, a.what)) continue;
      const label = { connecting: "Connecting…", reconnect: "Reconnect", failed: "Try again" }[a.state] || "Connect";
      const b = button(label, "quiet small", async () => {
        if (!st.signed_in) return toast("Sign in first", "Connecting an app takes your Enkeon sign-in.", "");
        b.disabled = true; b.textContent = "Opening…";
        try {
          const r = await call("app_connect", { slug: a.slug });
          if (r.authorize_url) await Api.openUrl(r.authorize_url).catch(() => {});
          else if (r.state !== "connected") toast(`Couldn't connect ${a.name}`, r.reason || "Enkeon couldn't start it.", "error");
        } catch (e) { toast(`Couldn't connect ${a.name}`, String(e), "error"); }
        refreshConnect();
      });
      b.disabled = !data.enkeon || a.state === "connecting";
      items.push(row(logoTile(a.slug, a.name), a.name, a.what, b));
    }
    section("Apps", items);
  }

  if (want("Channels")) section("Channels", APPS.filter((a) => a[2] === "Channels" && match(a[0], a[1])).map(([name, what, , key, kind]) =>
    row(logoTile(key, name), name, what, kind === "peers"
      ? button("Open", "quiet small", () => { d.close(); if (current) openProfile("share"); else openSettings("sharing"); })
      : button(kind === "telegram" && data.telegram ? "Manage" : "Set up", "quiet small", () => { d.close(); openSettings("channels"); }))));

  if (want("This Mac")) section("This Mac", APPS.filter((a) => a[2] === "This Mac" && match(a[0], a[1])).map(([name, what, , key, kind]) => {
    let b;
    if (kind === "mac") b = button("Turn on", "quiet small", () => {
      d.close();
      if (current) { openProfile("about"); toast("Turn on Mac apps", `Switch on “Mac apps” for ${current.name}. macOS asks once per app the first time.`); }
      else toast("Turn on Mac apps", "Open an agent, then its profile → Mac apps. Each agent gets them only if you say so.");
    });
    else { b = el("button", "btn quiet small", "Soon"); b.disabled = true; }
    return row(logoTile(key, name), name, what, b);
  }), el("p", "set-note", "Mac apps are per agent: turn them on in an agent's profile."));

  // Password managers: agents sign in for you, never seeing a password.
  if (want("Passwords") && match("1Password", "password manager sign in")) {
    section("Password managers", [row(logoTile("1password", "1Password"), "1Password",
      opOn ? "Agents sign in for you; they never see a password" : data.op?.installed ? "Choose which vaults agents may use" : "Let agents sign in for you, without ever seeing a password",
      button(opOn ? "Manage" : "Set up", opOn ? "quiet small" : "primary small", () => openOnePassword()))],
      el("p", "set-note", "Cookie fills the login straight into the sign-in form, only on the login's own website, and asks you each time. 1Password asks for Touch ID."));
  }

  // Developer: your own MCP servers.
  if (want("Developer")) {
    const items = data.mcps.filter((m) => match(m.name, m.url || m.command || "")).map((m) => {
      const acts = el("div", "conn-acts");
      const sw = el("button", "switch" + (m.on ? " on" : "")); sw.title = m.on ? "On for agents with Apps" : "Off";
      sw.onclick = async () => { try { await call("mcp_toggle", { id: m.id, on: !m.on }); refreshConnect(); } catch (e) { toast("Couldn't change it", String(e), "error"); } };
      const more = el("button", "round soft"); more.title = "Remove"; more.append(icon("trash"));
      more.onclick = async () => { if (!confirm(`Remove ${m.name}?`)) return; try { await call("mcp_remove", { id: m.id }); refreshConnect(); } catch (e) { toast("Couldn't remove it", String(e), "error"); } };
      acts.append(sw, more);
      const r = row(logoTile("mcp", m.name), m.name, `${m.url || m.command} · ${m.tools.length} tool${m.tools.length === 1 ? "" : "s"}`, acts);
      r.title = m.tools.join(", ");
      return r;
    });
    if (match("MCP server", "custom add")) items.push(row(logoTile("mcp", "MCP"), "Add an MCP server", "Any tool that speaks MCP: a URL, or a command on this Mac", button("Add", "primary small", () => addMcp())));
    section("Developer", items, el("p", "set-note", "Agents with Apps on get its tools. Cookie asks before every call unless the server marks a tool read-only, and refuses the server if its tools change until you look again."));
  }

  list.replaceChildren(...(sections.length ? sections : [el("p", "set-note", "No app matches.")]));
  clearTimeout(connectState.timer);
  const busy = (st?.apps || []).some((a) => a.state === "connecting") || st?.signin?.state === "waiting";
  if (d.open) connectState.timer = setTimeout(refreshConnect, busy ? 2500 : 15000);
}

/** 1Password: install, connect (Touch ID), and choose the vaults agents may use. */
async function openOnePassword() {
  const d = el("dialog", "sheet secret-sheet op-sheet");
  const body = el("div", "op-body");
  const close = button("Done", "quiet small", () => d.close());
  const foot = box("div", "form-end", close);
  /** The sheet's one row of buttons: this step's action, then Done. */
  const actions = (...b) => foot.replaceChildren(...b, close);
  d.append(el("h2", null, "1Password"), el("p", "muted", "Agents sign in for you: Cookie puts the login straight into the sign-in form, only on that login's own website, after you say yes. The agent is told only \u201cfilled\u201d; it never sees a username, password or code."), body, foot);
  d.addEventListener("close", () => { d.remove(); refreshConnect(); });
  document.body.append(d); d.showModal(); close.blur();
  const paint = async (deep) => {
    body.replaceChildren(el("p", "set-note", deep ? "Asking 1Password… (it may ask for Touch ID)" : "Checking…"));
    const st = await call("onepassword_status", { deep }).catch((e) => ({ installed: false, reason: String(e) }));
    if (!st.installed) {
      const cmd = "brew install 1password-cli";
      const copy = button("Copy", "quiet small", async () => { await navigator.clipboard.writeText(cmd).catch(() => {}); toast("Copied", cmd, "good"); });
      body.replaceChildren(
        el("h3", "group-title", "Three steps, once"),
        box("ol", "op-steps",
          box("li", null, el("span", null, "Install the 1Password app and sign in. "), button("Get 1Password", "quiet small", () => Api.openUrl("https://1password.com/downloads/mac").catch(() => {}))),
          box("li", null, el("span", null, "In 1Password: Settings → Developer → switch on \u201cIntegrate with 1Password CLI\u201d.")),
          box("li", null, el("span", null, "Install its command-line tool in Terminal:"), box("div", "op-cmd", el("code", null, cmd), copy))));
      actions(button("Check again", "primary small", () => paint(false)));
      return;
    }
    if (!deep) {
      body.replaceChildren(el("p", "set-note", (st.allowed || []).length ? `${st.allowed.length} vault${st.allowed.length === 1 ? "" : "s"} allowed for agents.` : "1Password is installed. Connect to choose the vaults agents may use."));
      actions(button("Connect", "primary small", () => paint(true)));
      return;
    }
    if (!st.signed_in) {
      body.replaceChildren(el("p", "error-line", st.reason || "1Password didn't let Cookie in."),
        el("p", "set-note", "Open the 1Password app, unlock it, and check Settings → Developer → \u201cIntegrate with 1Password CLI\u201d is on."));
      actions(button("Try again", "primary small", () => paint(true)));
      return;
    }
    const allowed = new Set(st.allowed || []);
    const list = el("div", "group");
    for (const v of st.vaults || []) {
      list.append(setRow(v.name, allowed.has(v.id) ? "Agents may sign in with its logins" : "Agents can't see it", toggle(allowed.has(v.id), async (on) => {
        on ? allowed.add(v.id) : allowed.delete(v.id);
        try { await call("onepassword_set_vaults", { vaults: [...allowed] }); } catch (e) { toast("Couldn't save that", String(e), "error"); }
      }, v.name)));
    }
    body.replaceChildren(
      el("p", "set-note ok", `Connected to ${st.account}.`),
      el("h3", "group-title", "Vaults agents may use"),
      list,
      el("p", "set-note", "Tip: make a vault called \u201cCookie\u201d holding only the logins agents need, and allow just that one."));
    actions();
  };
  paint(false);
}

/** Add your own MCP server: checked once, its tools pinned. */
function addMcp() {
  const d = el("dialog", "sheet secret-sheet mcp-sheet");
  const name = input("", "Name, like Linear or My tools");
  const target = input("", "https://…/mcp   or   npx -y @scope/server");
  const token = input("", "Token (optional, for a URL)"); token.type = "password";
  const err = el("p", "error-line"); err.hidden = true;
  const end = el("div", "form-end");
  const go = button("Connect", "primary small", async () => {
    err.hidden = true; go.disabled = true; go.textContent = "Checking…";
    try {
      const r = await call("mcp_add", { name: name.value, target: target.value, token: token.value || null });
      d.close();
      toast(`${r.name} is connected`, `${r.tools.length} tools, for agents with Apps on.`, "good");
      connectState.filter = "Developer"; refreshConnect();
    } catch (e) { err.textContent = String(e); err.hidden = false; }
    go.disabled = false; go.textContent = "Connect";
  });
  end.append(button("Cancel", "quiet small", () => d.close()), go);
  d.append(el("h2", null, "Add an MCP server"), el("p", "muted", "Cookie connects once to list its tools and remembers them. The token is kept in your Keychain."), name, target, token, err, end);
  d.addEventListener("close", () => d.remove());
  document.body.append(d); d.showModal(); name.focus();
}

/** Your address: @handle for you, @handle/agent for each agent. Online through a relay when you set one. */
/** Teams as one Markdown file: share yours, add someone's after a review. */
function teamsPart() {
  const share = el("div", "group");
  share.append(setRow("Share your team", "One TEAM.md: each agent's job, model, what it asks to use and its routines, with a playbook anyone can read. Signed with your key. Never keys, chats, memory or files.",
    button("Make TEAM.md", "quiet small", async () => {
      try {
        const name = `${($("me-name").textContent || "My").trim()}'s team`;
        showTeamFile(name, await call("export_team", { name }));
      } catch (e) { toast("Couldn't make it", String(e), "error"); }
    })));
  const add = el("div", "group edit");
  const link = input("", "A link to a TEAM.md (GitHub works), or paste the file below");
  const paste = el("textarea", "text-in team-paste"); paste.rows = 3; paste.placeholder = "+++\nformat = \"cookie-team/1\"\n…";
  const file = el("input"); file.type = "file"; file.accept = ".md,text/markdown,text/plain"; file.hidden = true;
  file.onchange = async () => { const f = file.files[0]; if (f) { paste.value = await f.text(); file.value = ""; } };
  const end = el("div", "form-end");
  end.append(button("Choose file", "quiet small", () => file.click()), button("Review", "primary small", async () => {
    try {
      const p = await call("preview_team", link.value.trim() ? { url: link.value.trim() } : { text: paste.value });
      reviewTeam(p);
    } catch (e) { toast("That team didn't check out", String(e), "error"); }
  }));
  add.append(setRow("Add a team", "You see every agent before anything is added. Each starts with no access and on probation; its routines arrive paused.", null), link, paste, file, end);
  return [el("h3", "group-title", "Teams"), share, add];
}

/** A team file just made: copy it, or keep it in Downloads. */
function showTeamFile(name, text) {
  const d = el("dialog", "sheet secret-sheet");
  d.append(el("h2", null, "Your TEAM.md"), el("p", "muted", "Share it anywhere: a message, a gist, a repo. Someone adds it in Cookie under Settings → Market → Add a team; anyone can follow it by hand."), el("pre", "secret-pre team-pre", text));
  const end = el("div", "form-end");
  end.append(
    button("Save to Downloads", "quiet small", async () => { try { const p = await call("save_team_file", { name, text }); toast("Saved", p.replace(/^.*\/Downloads\//, "Downloads/"), "good"); } catch (e) { toast("Couldn't save it", String(e), "error"); } }),
    button("Copy", "quiet small", () => navigator.clipboard.writeText(text).then(() => toast("Copied", "The whole TEAM.md."))),
    button("Done", "primary small", () => d.close()),
  );
  d.append(end);
  d.addEventListener("close", () => d.remove());
  document.body.append(d);
  d.showModal();
}

/** What adding a team would do, before anything is added. */
function reviewTeam(p) {
  const d = el("dialog", "sheet secret-sheet team-review");
  const trust = el("p", "team-trust " + (p.signed ? "signed" : "unsigned"),
    p.yours ? "Signed by you." : p.signed ? `Signed by key ${String(p.by).slice(0, 16)}…: it hasn't changed since it was signed.` : "Unsigned: anyone could have written it. Its agents still start with no access.");
  const list = el("div", "group");
  for (const a of p.agents) {
    const r = setRow(`${a.name}${a.taken ? " (you have one by this name: it'll be " + a.name + " 2)" : ""}`, a.job, null);
    const t = r.querySelector(".row-text");
    t.append(el("small", "muted", `${a.model_ok ? a.model : a.model ? a.model + ": no key here, uses the model below" : "Uses the model below"}${a.asks_for.length ? " · asks to use " + a.asks_for.join(", ") : ""}`));
    for (const rt of a.routines) t.append(el("small", "muted", `Paused routine: ${rt.when}: ${rt.task}`));
    list.append(r);
  }
  const needModel = p.agents.some((a) => !a.model_ok);
  const model = select(suggestions().map((m) => [m, m]), suggestions()[0] ?? "", () => {});
  d.append(el("h2", null, `Add ${p.name}?`), trust);
  if (p.about) d.append(el("p", "muted", p.about));
  d.append(list);
  if (needModel) { const m = el("div", "inline-row"); m.append(el("span", "muted", "Model for the agents without one here"), model); d.append(m); }
  d.append(el("p", "set-note", "Nothing is granted: each agent lists what it asks to use, and you turn that on in its profile. It's on probation for a week. Routines arrive paused."));
  const end = el("div", "form-end");
  end.append(button("Cancel", "quiet small", () => d.close()), button(`Add ${p.agents.length} agent${p.agents.length === 1 ? "" : "s"}`, "primary small", async () => {
    try {
      const hired = await call("install_team", { text: p.text, model: needModel ? model.value : null });
      d.close();
      await loadRoster();
      toast(`${p.name} added`, `${hired.length} agent${hired.length === 1 ? "" : "s"}, with no access yet: grant what each needs in its profile.`, "good");
      $("settings").close();
      if (hired[0]) openAgent(hired[0].id);
    } catch (e) { toast("Couldn't add the team", String(e), "error"); }
  }));
  d.append(end);
  d.addEventListener("close", () => d.remove());
  document.body.append(d);
  d.showModal();
}

/** AI tools: Claude Desktop, Cursor and Claude Code hand your agents work over MCP, through Cookie itself. */
async function aiToolsPart(st) {
  const g = el("div", "group");
  g.append(setRow("Let AI tools on this computer use your team", "Claude Desktop, Cursor, Claude Code and other MCP tools can see your agents, hand them work and read their answers. They can't approve anything: what an agent would send, change or pay still asks you here.",
    toggle(st.enabled, async (v) => { await call("update_settings", { patch: { server: { enabled: v } } }); setTimeout(refreshSettings, 400); }, "AI tools")));
  const out = [el("h3", "group-title", "AI tools"), g];
  if (!st.enabled) return out;
  const mc = await call("mcp_command").catch(() => null);
  if (!mc) return out;
  const q = (s) => (/[\s"']/.test(s) ? `"${s.replace(/"/g, '\\"')}"` : s);
  const json = JSON.stringify({ mcpServers: { cookie: { command: mc.command, args: mc.args } } }, null, 2);
  const snip = (title, where, text) => {
    const box = el("div", "group edit mcp-snip");
    const head = el("div", "mcp-snip-head");
    head.append(el("div", "row-text"), button("Copy", "quiet small", () => navigator.clipboard.writeText(text).then(() => toast("Copied", title))));
    head.firstChild.append(el("span", null, title), el("small", null, where));
    box.append(head, el("pre", "mcp-pre", text));
    return box;
  };
  out.push(
    snip("Claude Desktop", "Settings → Developer → Edit Config, then restart Claude", json),
    snip("Cursor", "~/.cursor/mcp.json (or Settings → MCP → Add)", json),
    snip("Claude Code", "Run once in a terminal", `claude mcp add cookie -- ${[mc.command, ...mc.args].map(q).join(" ")}`),
    el("p", "set-note", "Cookie must be open for them to reach it. Everything stays on this computer: the tool starts Cookie's own bridge, which talks to this app."),
  );
  return out;
}

async function addressPart() {
  const ns = netStatus = await call("net_status");
  const out = [el("h3", "group-title", "Your address")];
  const g = el("div", "group");
  const handle = input(ns.handle ?? "", "naveen", { spellcheck: false });
  handle.setAttribute("autocapitalize", "off");
  const save = button("Save", "quiet small", async () => {
    try { netStatus = await call("net_handle", { handle: handle.value }); toast("Address saved", netStatus.address, "good"); refreshNetBadge(); refreshSettings(); }
    catch (e) { toast("Couldn't use that handle", String(e), "error"); }
  });
  g.append(setRow(ns.address ?? "No address yet", "You are @handle; each agent is @handle/its-name. 3 to 24 letters, numbers or dashes.", null), inlineForm(handle, save));
  out.push(g);
  const r = el("div", "group");
  if (!ns.relay) {
    const relay = input("", "https://relay.example.com", { spellcheck: false });
    const go = button("Go online", "quiet small", async () => {
      try { netStatus = await call("net_setup", { relay: relay.value, handle: ns.handle ?? handle.value }); toast("You're online", netStatus.address, "good"); refreshNetBadge(); refreshSettings(); }
      catch (e) { toast("Couldn't go online", String(e), "error"); }
    });
    r.append(setRow("Talk to other people", "A relay carries sealed messages between you and other people's agents; it can't read them. Until you set one, your address works on this computer only.", null), inlineForm(relay, go));
  } else {
    const state = !ns.enabled ? "Offline" : ns.connected ? "Online" : ns.error ? `Can't reach the relay: ${ns.error}` : "Connecting…";
    r.append(setRow(state, ns.relay, toggle(ns.enabled, async (on) => {
      try { netStatus = await call("net_enable", { on }); refreshNetBadge(); refreshSettings(); } catch (e) { toast("Couldn't change it", String(e), "error"); }
    }, "Online")));
    r.append(setRow("Contacts, knocks and rooms", "Who your agents talk to.", button("Open Network", "quiet small", () => { $("settings").close(); openNetwork(); })));
  }
  out.push(r);
  return out;
}
