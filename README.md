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
    .tool(Skills::from_dir("skills")?.tool());
```

Every MCP tool asks a person unless you lower it; a server's own hints can
only make a tool stricter. `connect()` returns the tool list's SHA-256 so
you can pin it. Skills (`SKILL.md`) are offered through one `use_skill`
tool and loaded on demand; `read_agents_md` gives you `AGENTS.md` to put in
your instructions — nothing is added behind your back.

## Long sessions

`.compaction(Compaction { clear_tool_results_after, summarize_above_tokens, keep_recent_turns })`
clears old tool output from what the model sees and, past the token limit,
replaces older turns with a summary (`SUMMARY_PROMPT`, public). The session
file keeps every message. What the person wrote before a summary still
counts as theirs; a summary of untrusted content stays untrusted.

## Licence

MIT
