# Cookie Agent Harness

A tiny agent loop where text the model read can never, on its own, decide
who gets sent what.

```rust
let agent = Agent::new("anthropic:claude-sonnet-4-6")?.tool(weather);
println!("{}", agent.run("Weather in Riga?").await?);
```

You always name the model (`provider:model`); there is no default.

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
(`.guard("to")`) must come from the person or an allow-list. `Outbound`
and `Destroy` always ask an `Approver` with a preview of what will
actually happen; the default approver says no.

See `examples/outbound_gate.rs`: a web page tells the agent to email
`evil@x.com`; the call is refused before anyone is asked.

Prompt injection is not solved by this. It limits what an injected
model can *do*.

## Licence

MIT
