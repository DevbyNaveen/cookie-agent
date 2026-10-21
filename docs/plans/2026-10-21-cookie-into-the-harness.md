# Cookie moves into the harness (2026-10-21)

Decision (Naveen, 2026-10-21): everything Cookie does lives in this open-source harness — the agent loop,
acting safety, noticing, learning, Cookie's tools and prompts, and its channels (mail, Slack, its page).
Enkeon keeps the brain (context over MCP), accounts, credits and billing, and runs the hosted harness for
teams. Users see no change: the `cookie.enkeon.com` addresses, @Cookie in Slack and the Cookie page stay.

Today the Cookie logic sits in Enkeon's gateway (`services/gateway/src/cookie/`, ~6,000 lines with the
2026-10-21 build on branch `build/cookie-acts-2026-10-21`). It moves here one milestone at a time; each
milestone lands with tests, then the gateway's copy is removed.

## Where the line is

| Harness (open source) | Enkeon (hosted) |
|---|---|
| The loop, providers, budgets, approvals, trust | The team's brain (recall / remember over MCP) |
| Acting safety: never twice, outcome unknown, proof before finishing, loop and refusal guards | Connected-app sign-ins and the connector gate |
| Noticing: salience, subjects, decay, habituation, hard cues, the gate | Storing Cookie's state (attention, notices, lessons, runs) |
| Learning: matching, the bandit, scoring, the lesson prompt, curation | Credits, plans, billing, accounts, members |
| Cookie's tools, instructions, skills, source tags | The mail domain, the Slack app, the Console page UI |
| Channels: mail parsing and delivery rules, Slack events, page jobs | Hosting the harness for teams |

The harness never holds a team's data between runs on its own: state comes in with a request and goes back
out with the reply (`serve`), so Enkeon stores it in Postgres and Cookie.app in a local file.

## Milestones

1. **Acting safety in the loop** — the same change is never sent twice in a run; three refusals in a row stop
   the run; a run that changed something and checked nothing is asked once to check before it finishes.
   (Outcome-unknown on an interrupted call and unknown MCP tools as `outbound` already exist.)
2. **Noticing** — `attention` module (pure) and `serve` lines `observe` / `tick` that take the state in and
   give the state and any notices back. The gateway's `cookie/notice.rs` keeps only the stream reader and
   storage.
3. **Learning** — `lessons` module (pure: match, bandit, score, curate rules, the lesson prompt and its
   parser) and `serve`: a run takes `lessons` + `baseline`, picks and injects, and reports which it gave; a
   `distill` line asks the small model for a lesson. The gateway's `cookie/learn.rs` keeps storage only.
4. **Cookie's profile** — the instructions, tool descriptions, the `find-leads` skill, source tags and
   `split_sources`, `read_site` link rules and robots.txt; tools that need Enkeon run through the Enkeon MCP
   door the harness already speaks.
5. **Channels** — mail parsing, who may instruct (DKIM), delivery rules (team-only thread, outsiders → draft,
   BCC → silence), Slack events, page jobs; Enkeon keeps the sending accounts and credits.
