# Cookie Agent Harness

A tiny agent loop where text the model read can never, on its own, decide
who gets sent what.

```rust
let agent = Agent::new("anthropic:claude-sonnet-4-6")?.tool(weather);
println!("{}", agent.run("Weather in Riga?").await?);
```

You always name the model (`provider:model`); there is no default.

| Provider | Model id | Needs |
|---|---|---|
| Anthropic | `anthropic:claude-sonnet-4-6` | `ANTHROPIC_API_KEY` |
| OpenAI | `openai:<model>` | `OPENAI_API_KEY` (`OPENAI_BASE_URL` for other compatible servers) |
| Ollama | `ollama:qwen3` | a running Ollama (`OLLAMA_HOST`, default `localhost:11434`) |
| Amazon Bedrock | `bedrock:eu.anthropic.claude-sonnet-4-6` | feature `bedrock` (Rust 1.91+); `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` for ids without `eu.`/`us.` |

Keys are read from the environment and never enter the conversation.
Anthropic streams; OpenAI-compatible and Bedrock report each reply when it completes.

## Five concepts

| | |
|---|---|
| `Agent` | model + instructions + tools + policy |
| `Tool` | a plain async function, a JSON schema, and an effect: `Read`, `Write`, `Outbound`, `Destroy` |
| `Session` | an append-only JSONL file: resume, branch, replay |
| `Policy` | deterministic gates over effects and where values came from |
| `Provider` | the model backend |

## The trust rule

Every message is labelled by the runtime: the person's words, the
developer's instructions, the model, or **untrusted** (tool output, web,
files, screens, other agents). Arguments that pick who, where or how much
(`.guard("to")`, or a JSON pointer like `.guard("/message/to")`) must be
words the person actually wrote, or on an allow-list. Guard them on every
effect class, `Read` included: a fetch URL can carry data out. `Outbound`
and `Destroy` always ask an `Approver` with a preview of what will
actually happen; the default approver says no.

See `examples/outbound_gate.rs`: a web page tells the agent to email
`evil@x.com`; the call is refused before anyone is asked.

Prompt injection is not solved by this. It limits what an injected
model can *do*.

## MCP servers and skills

```rust
let github = McpServer::stdio("github-mcp", &[])
    .effect("search_issues", Effect::Read)   // everything else asks a person
    .guard("create_issue", "repo")
    .pin("3f2a…")                            // refuse it if its tools change
    .connect()
    .await?;
let agent = Agent::new("anthropic:claude-sonnet-4-6")?
    .tools(github.tools)
    .tools(Skills::from_dir("skills")?.into_tools());
```

Every MCP tool asks a person unless you lower it; a server's own hints can
only make a tool stricter. The first connection is trust-on-first-use: `connect()` returns
the tool list's SHA-256, and `pin` refuses a server whose tools changed since —
it cannot catch a server that changes what a tool does behind the same
description, which is why tool output is always untrusted. `connect()` returns the tool list's SHA-256 so
you can pin it. Skills (`SKILL.md`) are offered through one `use_skill`
tool and loaded on demand; `read_agents_md` gives you `AGENTS.md` to put in
your instructions — nothing is added behind your back.

## From the terminal, or from any language

```sh
cookie run anthropic:claude-sonnet-4-6 "Weather in Riga?" --session riga.jsonl
cookie chat anthropic:claude-sonnet-4-6 --session riga.jsonl   # one run per line
cookie replay riga.jsonl   # run it again from the log: exit 0 if it reproduced
cookie serve    # one JSON object per line on stdin/stdout
```

`cookie chat` asks approvals on the same terminal it reads your lines from;
Ctrl-C stops the answer being written, `/exit` or Ctrl-D leaves. `cookie
replay` calls no model and runs no tool: each reply and each tool result
comes from the file, so it shows whether the loop still does what it did, and
names the first message that differs. In Rust, `Replay::from_session(&s)`
gives the same, and `ReplayProvider` alone replays the model against new tools.

`cookie serve` speaks a small protocol. You send
`{"type":"run","id":"r1","model":"…","input":"…","tools":[{"name":"lookup","effect":"read","schema":{…}}]}`;
you get `event` lines while it works, `tool_call` when the model calls one of
your tools (answer with `tool_result`), `approval` when something needs a
person (answer with `approve` — no answer means no), and `done` or `error`.
`cancel` stops a run now, `finish_turn` after this turn. Your tools go
through the same gates as Rust ones, and their results are untrusted.

A `run` may also carry, besides `instructions`, `session` (a file to resume),
`allow` (values the person approved in advance) and `enkeon: false`:

```json
"budget": {"max_steps": 10, "max_tokens": 50000},
"mcp": [
  {"command": "github-mcp", "args": [], "effects": {"search_issues": "read"},
   "guards": {"create_issue": ["repo"]}, "pin": "3f2a…"},
  {"url": "https://mcp.example.com/mcp", "headers": {"Authorization": "Bearer …"}, "prefix": "ex"}
]
```

A limit left out keeps its default (25 model calls, 200,000 tokens). Each MCP
server is connected for that run only and works as in Rust: every tool asks
a person unless `effects` lowers it, and a `pin` refuses a server whose tool
list changed. A server that can't be reached, or fails its pin, ends that
run with an `error`. Unknown fields are refused, here as everywhere.

## Tracing

Every run emits OpenTelemetry GenAI spans through `tracing`:
`invoke_agent`, `chat {model}` and `execute_tool {tool}`, with provider,
model, token usage, tool call id and `error.type` — never message content.
Export them with `tracing-opentelemetry`. The GenAI conventions are still
marked Development, so the names may change.

## Enkeon (on when you have a key)

Set `ENKEON_API_KEY` and every agent gets the person's context from
[Enkeon](https://enkeon.com): a `recall` tool to look things up and a
`remember` tool to save what lands. The system prompt gains one paragraph,
`ENKEON_INSTRUCTIONS` — read it in `src/enkeon.rs`; nothing else is added.

```rust
let agent = Agent::new("anthropic:claude-sonnet-4-6")?;                 // with ENKEON_API_KEY set: on
let agent = Agent::new("anthropic:claude-sonnet-4-6")?.without_enkeon(); // off
```

What `recall` returns is tool output: untrusted, so a stored memory can't
choose who gets sent what. A memory may hold text from a web page, so once a
run has recalled or read anything, `remember` asks a person first — set an
`approver`, or the default declines and nothing is saved. Sub-agents can
recall but not save. If Enkeon can't be reached within 10 s the run still
answers and you get `Event::EnkeonUnavailable`. The key is only sent over
https (or to this machine) and never follows a redirect. No key, no
connection — and since the key comes from the environment, call
`.without_enkeon()` in tests that assert on prompts or tools. Remote MCP servers work the same way: `McpServer::http(url)`.

## Several agents

```rust
let researcher = SubAgent::reader("research", "Looks things up", research_agent)?;
let mailer = SubAgent::writer("mailer", "Sends email", mail_agent)?;
let lead = Agent::new("anthropic:claude-sonnet-4-6")?.tool(researcher).tool(mailer);
```

A sub-agent is a tool: it runs in a fresh context that holds only its task,
and its answer comes back as untrusted output. It inherits the parent's
trust exactly — a recipient the parent couldn't use, the child can't use
either, because the task is the parent model's words, not the person's.
Readers hold only `Read` tools; one agent per tree may change things.
Children spend from the parent's budget and stop when the parent is
cancelled. Delegation goes at most 3 levels deep.

## Long sessions

`.compaction(Compaction { clear_tool_results_after, summarize_above_tokens, keep_recent_turns, ..Compaction::default() })` (`.with_prompt(..)` replaces the summary instruction)
clears old tool output from what the model sees and, past the token limit,
replaces older turns with a summary (`SUMMARY_PROMPT`, public). The session
file keeps every message. What the person wrote before a summary still
counts as theirs; a summary of untrusted content stays untrusted.

## Licence

MIT
