// Settings → Channels: Slack, Discord, iMessage and Signal, beside Telegram.
// Each links chats with a one-time code; nothing from an unlinked chat
// reaches an agent.
const CHANNELS = [
  { kind: "slack", name: "Slack", what: "Talk to your agents in Slack channels or DMs. Make a Slack app with a bot token (chat:write, channels:history, groups:history, im:history), invite it to the channels, and list their IDs.", fields: [["secret", "Bot token (xoxb-…)", true], ["channels", "Channel IDs, comma separated (C0123ABCD, D0456…)"]] },
  { kind: "discord", name: "Discord", what: "Talk to your agents in a Discord server or DM. Make a bot in the Developer Portal, switch on its Message Content intent, invite it, and paste its token.", fields: [["secret", "Bot token", true]] },
  { kind: "imessage", name: "iMessage", what: "Text your agents from your iPhone. Cookie reads this Mac's Messages (macOS asks for Full Disk Access) and answers through Messages. Works best with its own Apple ID signed in on this Mac.", fields: [] },
  { kind: "signal", name: "Signal", what: "Talk to your agents on Signal through signal-cli (brew install signal-cli, then register or link a number).", fields: [["account", "Number signal-cli uses, e.g. +37120000000"]] },
  // These call Cookie, so they need a runner with a public address (Settings → Sharing).
  { kind: "whatsapp", name: "WhatsApp", hook: true, what: "Talk to your agents on WhatsApp, through Meta's Cloud API. Every message is checked with your app secret; unsigned ones are refused.", fields: [["secret", "Access token", true], ["phone_id", "Phone number ID"], ["app_secret", "App secret (App settings → Basic)", true]] },
  { kind: "teams", name: "Microsoft Teams", hook: true, what: "Talk to your agents in a Teams personal chat, through an Azure bot. Every message's token is checked against Microsoft's keys.", fields: [["secret", "Bot client secret", true], ["app_id", "Microsoft App ID"]] },
  { kind: "mail", name: "Mail to Cookie", hook: true, what: "Give Cookie its own address and mail it jobs. Only mail from your addresses, proven by DKIM, gives a job; when someone else is on the thread you get a draft to send or skip.", fields: [["local", "Cookie's address: local part (e.g. me)"], ["domain", "Cookie's address: domain (e.g. cookie.example.com)"], ["you", "Your own addresses, comma separated"], ["name", "Name your replies are signed with"], ["smtp_host", "SMTP server (e.g. smtp.example.com)"], ["smtp_port", "SMTP port (587 or 465)"], ["smtp_user", "SMTP user"], ["secret", "SMTP password", true]] },
];
// A secret Cookie shows once, after connecting (the mail forwarder's).
const shownOnce = {};

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
        for (const [key] of c.fields) {
          if (key === "secret" || !inputs[key]) continue;
          const v = inputs[key].value.trim();
          config[key] = key === "channels" || key === "you" ? v.split(/[\s,]+/).filter(Boolean) : key === "smtp_port" ? +v || 587 : v;
        }
        try {
          const st = await call("channel_connect", { kind: c.kind, secret: inputs.secret?.value || null, config });
          if (st?.config?.inbound_secret) shownOnce[c.kind] = st.config.inbound_secret;
          toast(`${c.name} connected`, c.kind === "mail" ? "Point your mail forwarder at the address below." : "Now link a chat with the code below.", "good");
          refreshSettings();
        }
        catch (err) { toast(`Couldn't connect ${c.name}`, String(err), "error"); b.disabled = false; b.textContent = "Connect"; }
      }));
      out.push(g, end);
      continue;
    }
    if (c.hook && st.config?.webhook) {
      const where = el("div", "group edit");
      where.append(setRow(c.kind === "mail" ? "Your forwarder posts each raw message to" : `Webhook for ${c.name}`, c.kind === "whatsapp" ? `Set it in Meta → WhatsApp → Configuration, with the verify token ${st.config.verify_token}.` : c.kind === "teams" ? "Set it as the bot's messaging endpoint in Azure." : "With the header X-Cookie-Mail-Secret, and X-Cookie-Rcpt with the envelope recipients when it has them.", null), el("code", "copyable", st.config.webhook));
      if (shownOnce[c.kind]) where.append(setRow("Mail secret (shown once)", "Copy it into the forwarder now; Cookie won't show it again.", null), el("code", "copyable", shownOnce[c.kind]));
      out.push(where);
    }
    if (c.kind === "mail") {
      const m = await call("mail_status").catch(() => null);
      g.append(setRow(c.name, `${m?.address ?? ""} · ${m?.drafts ?? 0} draft${m?.drafts === 1 ? "" : "s"} waiting for your send`, button("Disconnect", "quiet small danger", async () => { await call("channel_disconnect", { kind: c.kind }); refreshSettings(); })));
      out.push(g);
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
  out.push(el("p", "set-note", "WhatsApp, Teams and Mail work only on a runner with a public address: Meta, Microsoft and your mail forwarder call it."));
  out.push(el("p", "set-note", "On Slack, Discord, iMessage and Signal, approvals and questions arrive as text with a short code: reply “yes K7Q2”, “no K7Q2”, or “K7Q2 your answer”."));
  return out;
};
