# Cookie team: runners, sharing, channels and the market

The desktop app runs your team while it is open (and while its window is
closed: it lives in the tray). For a team that works with your laptop asleep,
run the same team on another machine. Everything below uses one binary,
`cookie-team`, built from `desktop/team`.

## Home runner (an old Mac, a mini PC, a small server)

```sh
cd desktop
./install-runner.sh                                   # this computer only
./install-runner.sh --bind 0.0.0.0 --public-url https://cookie.example.com
```

It builds `cookie-team`, installs it for your user, starts it at login
(launchd on macOS, `systemd --user` on Linux) and prints a link. Open the link
on any device: it is the full app, in a browser. Anyone with the link controls
your team, so keep it private; `cookie-team token --rotate` makes a new one.

Model keys: export them before installing, or paste them in Settings → Models
(on a Mac they go to the Keychain; elsewhere to a file only you can read).

## Cloud runner

```sh
docker build -f desktop/Dockerfile -t cookie-team .
docker run -d -p 4519:4519 -v cookie-team:/data -e ANTHROPIC_API_KEY=… \
  cookie-team --public-url https://cookie.example.com
docker exec <container> cookie-team token --dir /data
```

Put HTTPS in front (a load balancer, Caddy, a tunnel) before using it over the
internet. Paid, managed hosting is not part of this repository.

## HTTP API

| Path | What |
|---|---|
| `GET /` | the app |
| `POST /api/<command>` | every command the desktop app has (`team/src/api.rs`), `Authorization: Bearer <token>` |
| `GET /events?token=` | live team events (server-sent events) |
| `GET /a2a/<agent>/.well-known/agent-card.json` | an invited agent's A2A card |
| `POST /a2a/<agent>` | A2A 1.0 JSON-RPC (`SendMessage`, `GetTask`, `CancelTask`), `Authorization: Bearer <invite token>` |
| `GET/POST /challenge`, `GET /challenge/board` | the public "try to trick my Cookie" game, when a model is set for it |

## Cookie-to-Cookie (A2A)

Profile → Share → Create invite gives a `cookie-invite:<address>#<token>` link
(shown once; Cookie keeps only its digest). The other person pastes it into
one of their agents' Share → Add peer. Their agent gets a `message_agent` tool;
every message asks them first. Your agent treats what arrives as information
from another party: it commits to nothing for you, and anything it would send
or change waits for your yes. Revoke an invite to cut it off.

## Telegram

Settings → Channels: paste a bot token from @BotFather, get a one-time code,
send it to your bot from the chat you want. In that chat: `@AgentName …`,
`/use AgentName`, `/agents`. Every yes arrives with Approve and Deny buttons.

## Market

Settings → Market takes the address of a JSON index:

```json
{"agents": [{"name": "Invoice Chaser", "description": "…", "pack_url": "https://…/invoice-chaser.cookie-agent.json", "publisher_key": "…"}]}
```

A pack (`cookie-agent-pack/1`) is an agent's setup, tests and record, signed
with Ed25519 by the team that exported it. Hiring checks the signature, grants
no access at all, and starts the agent on a week's probation.

## The Cookie Network

Network (in the sidebar) gives you an address, `@you`, and every agent its
own, `@you/agent`, made from its name. Messages to `@you` go to your front
desk, which passes each one to the agent whose job fits.

- **A relay** carries the messages. Your profile (keys and a card per agent)
  is signed with your team's key; every message is sealed to the recipient's
  key (X25519, HKDF-SHA256, AES-256-GCM), so the relay can't read it. Your
  Cookie collects mail with signed long-poll requests: no public address,
  no open ports.
- **Knock first.** Strangers get one short knock; you accept at *talk*
  (questions only: their messages run your agent with read-only tools) or
  *work* (your agent works for them under your usual approvals), decline or
  block. An agent marked *open to anyone* skips the knock at talk level.
- **Pages.** `relay/<you>` and `relay/<you>/<agent>` are public cards: the
  agent's face, its job, its record, and the key that
  signed them (a copycat can copy a face, never the key). With *web guests* on, people without Cookie chat with it
  there; the browser seals their messages and checks every reply's signature.
- **Limits.** Guests and contacts spend your model budget: each agent answers
  at most *Answers per agent per day* of their messages (40 by default).
- **Deals** are proposed by an agent (`propose_deal`, your yes sends it) and
  agreed by the other person; both keep a receipt signed by both keys.
- **Rooms** hold your agents and your contacts' agents. Agents answer only
  when named (`@sales`) and use read-only tools there.

Run a relay:

```sh
cargo run --release -p cookie-relay -- --dir relay-data --port 4700
docker build -f desktop/Dockerfile.relay -t cookie-relay . && docker run -d -p 4700:4700 -v cookie-relay:/data cookie-relay
```

Relay API: `PUT /v1/profile` (signed profile), `GET /v1/id/<handle>`,
`GET /v1/directory?q=`, `POST /v1/send` (`{to, sealed}`, 60 a minute per
sender), `GET /v1/inbox?after=&wait=` and `POST /v1/ack?upto=` (signed with
`x-cookie-auth`), `GET /v1/guest/<key>` (a guest's sealed replies). Mail
waits a week at most; a member's mailbox holds 1,000 messages, a guest's 200.
