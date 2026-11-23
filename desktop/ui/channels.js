// Settings → Channels: Slack, Discord, iMessage and Signal, beside Telegram.
// Each links chats with a one-time code; nothing from an unlinked chat
// reaches an agent.
const CHANNELS = [
  { kind: "slack", name: "Slack", what: "Talk to your agents in Slack channels or DMs. Make a Slack app with a bot token (chat:write, channels:history, groups:history, im:history), invite it to the channels, and list their IDs.", fields: [["secret", "Bot token (xoxb-…)", true], ["channels", "Channel IDs, comma separated (C0123ABCD, D0456…)"]] },
  { kind: "discord", name: "Discord", what: "Talk to your agents in a Discord server or DM. Make a bot in the Developer Portal, switch on its Message Content intent, invite it, and paste its token.", fields: [["secret", "Bot token", true]] },
  { kind: "imessage", name: "iMessage", what: "Text your agents from your iPhone. Cookie reads this Mac's Messages (macOS asks for Full Disk Access) and answers through Messages. Works best with its own Apple ID signed in on this Mac.", fields: [] },
  { kind: "signal", name: "Signal", what: "Talk to your agents on Signal through signal-cli (brew install signal-cli, then register or link a number).", fields: [["account", "Number signal-cli uses, e.g. +37120000000"]] },
];

const telegramPane = SETTINGS.channels;
SETTINGS.channels = async () => {
  const out = await telegramPane();
  const states = await call("channels").catch(() => ({}));
  for (const c of CHANNELS) {
    const st = states[c.kind] ?? {};
    const g = el("div", "group edit channel-card");
    if (!st.enabled) {
      g.append(setRow(c.name, c.what, null));
      const inputs = {};
      for (const [key, ph, secret] of c.fields) {
        const i = input("", ph, secret ? { type: "password", spellcheck: false } : { spellcheck: false });
        inputs[key] = i;
        g.append(i);
      }
      const end = el("div", "form-end");
      end.append(button("Connect", "primary small", async (e) => {
        const b = e.currentTarget; b.disabled = true; b.textContent = "Connecting…";
        const config = {};
        if (inputs.channels) config.channels = inputs.channels.value.split(/[\s,]+/).filter(Boolean);
        if (inputs.account) config.account = inputs.account.value;
        try { await call("channel_connect", { kind: c.kind, secret: inputs.secret?.value || null, config }); toast(`${c.name} connected`, "Now link a chat with the code below.", "good"); refreshSettings(); }
        catch (err) { toast(`Couldn't connect ${c.name}`, String(err), "error"); b.disabled = false; b.textContent = "Connect"; }
      }));
      out.push(g, end);
      continue;
    }
    const n = Object.keys(st.chats ?? {}).length;
    const ok = st.status === "connected";
    g.append(setRow(c.name, `${ok ? "Connected" : st.status || "Starting…"} · ${n} chat${n === 1 ? "" : "s"} linked`, button("Disconnect", "quiet small danger", async () => { await call("channel_disconnect", { kind: c.kind }); refreshSettings(); })));
    for (const chat of Object.keys(st.chats ?? {})) {
      g.append(setRow(chat, st.chats[chat] ? `talks to ${agentById(st.chats[chat])?.name ?? "an agent"} by default` : "pick an agent with /use Name", button("Unlink", "quiet small", async () => { await call("channel_unlink", { kind: c.kind, chat }); refreshSettings(); })));
    }
    if (st.code) g.append(setRow("Link a chat", `Send this from the ${c.kind === "imessage" || c.kind === "signal" ? "phone number" : "channel"} you want to use: ${st.code}`, el("code", "copyable big", st.code)));
    else g.append(setRow("Link a chat", "Get a one-time code and send it from the chat.", button("Get a code", "quiet small", async () => { await call("channel_code", { kind: c.kind }); refreshSettings(); })));
    out.push(g);
  }
  out.push(el("p", "set-note", "On Slack, Discord, iMessage and Signal, approvals and questions arrive as text with a short code: reply “yes K7Q2”, “no K7Q2”, or “K7Q2 your answer”."));
  return out;
};
