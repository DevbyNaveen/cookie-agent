# @cookie-harness/client (TypeScript)

A client for the Cookie Agent Harness. It starts `cookie serve` once (from
`cookieBin`, `COOKIE_BIN`, or `cookie` on `PATH`) and talks to it one JSON line
at a time. The harness calls the model and runs the trust gates; your tools
and your approver run in Node. Node 20+, ESM, no runtime dependencies.

```ts
import { Agent, tool } from "@cookie-harness/client";

const sendEmail = tool({
  name: "send_email",
  description: "Send an email.",
  effect: "outbound",
  guard: ["to"],
  schema: { type: "object", properties: { to: { type: "string" }, body: { type: "string" } }, required: ["to"] },
  run: async ({ to, body }) => mailer.send(to, body),
});

await using agent = new Agent({
  model: "anthropic:claude-sonnet-4-6",
  tools: [sendEmail],
  approver: async (request) => askPerson(request.preview), // must return true to allow
});
console.log(await agent.run("Email anna@x.com that I'm late"));
for await (const event of agent.stream("And Ben?")) {
  if (event.type === "text_delta") process.stdout.write(String(event.data));
}
```

- Effects: `read`, `write`, `outbound`, `destroy`. `outbound` and `destroy`
  always ask the approver. `guard` names arguments (or JSON pointers like
  `/message/to`) that must come from the person's words or from `allow`.
- No approver means every request is declined; only a returned `true` is a
  yes; a throw is a no.
- A tool that throws sends its error to the model (`is_error`); the run goes on.
- `agent.cancel()` stops the run now, `agent.finishTurn()` after this turn.
  Leaving a `for await` loop early cancels too.
- A failed run rejects with `CookieError`. `stream` ends with `{type: "done", answer}`.
- `agent.run(text, { images: [{ media_type: "image/png", data: b64, source: "screen", caption: "…" }] })`
  sends images with that run only. They are always untrusted: text in them
  never counts as the person's.
- Between runs the child process does not keep Node alive; `close()` ends it.

Build and test: `npm install && npm test` (one test uses the real binary if
`target/debug/cookie` exists: `cargo build --bin cookie`).
