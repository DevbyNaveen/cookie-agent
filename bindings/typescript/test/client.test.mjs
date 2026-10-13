// The client against a scripted fake `cookie serve`, and once against the real one.
import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { Agent, CookieError, tool } from "../dist/index.js";

const here = dirname(fileURLToPath(import.meta.url));
const COOKIE = join(here, "..", "..", "..", "target", "debug", "cookie");

function fake(script) {
  const dir = mkdtempSync(join(tmpdir(), "cookie-fake-"));
  const log = join(dir, "log.jsonl");
  writeFileSync(join(dir, "script.json"), JSON.stringify(script));
  writeFileSync(log, "");
  const bin = join(dir, "cookie");
  writeFileSync(
    bin,
    `#!/bin/sh\nFAKE_SCRIPT="${join(dir, "script.json")}" FAKE_LOG="${log}" exec "${process.execPath}" "${join(here, "fake-serve.mjs")}" "$@"\n`,
  );
  chmodSync(bin, 0o755);
  const received = () => readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  return { bin, received, sent: (type) => received().filter((m) => m.type === type) };
}

const done = (answer) => ({ write: { type: "done", answer } });

function agent(t, script, options = {}) {
  const f = fake(script);
  const a = new Agent({ model: "x:m", cookieBin: f.bin, ...options });
  t.after(() => a.close());
  return [a, f];
}

const lookup = tool({
  name: "lookup",
  description: "Look something up.",
  effect: "read",
  schema: { type: "object", properties: { q: { type: "string" } }, required: ["q"] },
  run: async ({ q }) => `found ${q}`,
});

const sendEmail = tool({
  name: "send_email",
  description: "Send an email.",
  effect: "outbound",
  guard: ["to"],
  schema: { type: "object", properties: { to: { type: "string" } }, required: ["to"] },
  run: ({ to }) => `sent to ${to}`,
});

test("run sends the declared run and returns the answer", async (t) => {
  const [a, f] = agent(t, [{ read: "run" }, { write: { type: "event", event: { type: "text_delta", data: "hi" } } }, done("hi there")], {
    tools: [sendEmail],
    instructions: "Be brief.",
    allow: ["anna@x.com"],
    enkeon: false,
  });
  assert.equal(await a.run("email anna"), "hi there");
  await a.close();
  assert.deepEqual(f.sent("run"), [
    {
      type: "run",
      id: "r1",
      model: "x:m",
      input: "email anna",
      instructions: "Be brief.",
      allow: ["anna@x.com"],
      enkeon: false,
      tools: [
        {
          name: "send_email",
          description: "Send an email.",
          effect: "outbound",
          guard: ["to"],
          schema: { type: "object", properties: { to: { type: "string" } }, required: ["to"] },
        },
      ],
    },
  ]);
});

test("session, budget, prices and mcp are passed through", async (t) => {
  const [a, f] = agent(t, [{ read: "run" }, done("ok")], {
    session: "s.jsonl",
    budget: { max_steps: 5, max_dollars: 0.5 },
    prices: { input: 3, output: 15, cache_read: 0.3, cache_write: 3.75 },
    mcp: [{ command: "github-mcp", effects: { search: "read" } }],
  });
  await a.run("hi");
  await a.close();
  const [run] = f.sent("run");
  assert.equal(run.session, "s.jsonl");
  assert.deepEqual(run.budget, { max_steps: 5, max_dollars: 0.5 });
  assert.equal(run.prices.output, 15);
  assert.deepEqual(run.mcp, [{ command: "github-mcp", effects: { search: "read" } }]);
});

test("images go with one run only", async (t) => {
  const [a, f] = agent(t, [{ read: "run" }, done("a mail"), { read: "run" }, done("ok")]);
  const shot = { media_type: "image/png", data: "iVBORw0KGgp4eA==", source: "screen", caption: "Mail.app" };
  assert.equal(await a.run("what is this?", { images: [shot] }), "a mail");
  assert.equal(await a.run("thanks"), "ok");
  await a.close();
  const [first, second] = f.sent("run");
  assert.deepEqual(first.images, [shot]);
  assert.equal("images" in second, false);
});

test("unset options are left out of the run", async (t) => {
  const [a, f] = agent(t, [{ read: "run" }, done("ok")]);
  await a.run("hi");
  await a.close();
  assert.deepEqual(f.sent("run"), [{ type: "run", id: "r1", model: "x:m", input: "hi", tools: [] }]);
});

test("stream yields events then done, and runs reuse one process", async (t) => {
  const [a, f] = agent(t, [
    { read: "run" },
    { write: { type: "event", event: { type: "text_delta", data: "a" } } },
    { write: { type: "event", event: { type: "usage", data: { input_tokens: 3 } } } },
    done("a"),
    { read: "run" },
    done("b"),
  ]);
  const events = [];
  for await (const e of a.stream("one")) events.push(e);
  assert.deepEqual(events, [
    { type: "text_delta", data: "a" },
    { type: "usage", data: { input_tokens: 3 } },
    { type: "done", answer: "a" },
  ]);
  assert.equal(await a.run("two"), "b");
  await a.close();
  assert.equal(f.sent("_started").length, 1);
  assert.deepEqual(f.sent("run").map((r) => r.id), ["r1", "r2"]);
});

test("a client tool is called and its output sent back", async (t) => {
  const [a, f] = agent(t, [{ read: "run" }, { write: { type: "tool_call", id: "t1", name: "lookup", args: { q: "riga" } } }, { read: "tool_result" }, done("ok")], {
    tools: [lookup],
  });
  assert.equal(await a.run("look"), "ok");
  await a.close();
  assert.deepEqual(f.sent("tool_result"), [{ type: "tool_result", id: "t1", output: "found riga", is_error: false }]);
});

test("a tool that throws, or one that does not exist, answers with is_error; other results go as JSON", async (t) => {
  const broken = tool({ name: "broken", effect: "write", run: () => { throw new RangeError("disk full"); } });
  const numbers = tool({ name: "numbers", effect: "read", run: () => [1, 2] });
  const [a, f] = agent(t, [
    { read: "run" },
    { write: { type: "tool_call", id: "t1", name: "broken", args: {} } },
    { read: "tool_result" },
    { write: { type: "tool_call", id: "t2", name: "missing", args: {} } },
    { read: "tool_result" },
    { write: { type: "tool_call", id: "t3", name: "numbers", args: {} } },
    { read: "tool_result" },
    done("ok"),
  ], { tools: [broken, numbers] });
  await a.run("go");
  await a.close();
  const [r1, r2, r3] = f.sent("tool_result");
  assert.deepEqual(r1, { type: "tool_result", id: "t1", output: "RangeError: disk full", is_error: true });
  assert.ok(r2.is_error && r2.output.includes("missing"));
  assert.deepEqual(r3, { type: "tool_result", id: "t3", output: "[1,2]", is_error: false });
});

const approvalScript = () => [
  { read: "run" },
  { write: { type: "approval", id: "a1", tool: "send_email", effect: "outbound", preview: "to anna", reason: "sends" } },
  { read: "approve" },
  done("ok"),
];

test("the approver is asked and its yes is sent", async (t) => {
  const asked = [];
  const [a, f] = agent(t, approvalScript(), { tools: [sendEmail], approver: async (r) => (asked.push(r), true) });
  await a.run("email anna");
  await a.close();
  assert.deepEqual(asked, [{ tool: "send_email", effect: "outbound", preview: "to anna", reason: "sends" }]);
  assert.deepEqual(f.sent("approve"), [{ type: "approve", id: "a1", allow: true }]);
});

test("no approver, a throwing approver or anything but true is a no", async (t) => {
  for (const approver of [undefined, () => { throw new Error("nobody home"); }, async () => { throw new Error("x"); }, () => "yes", () => 1, () => false]) {
    const [a, f] = agent(t, approvalScript(), { tools: [sendEmail], approver });
    await a.run("email anna");
    await a.close();
    assert.deepEqual(f.sent("approve"), [{ type: "approve", id: "a1", allow: false }]);
  }
});

test("cancel ends the run and the next run works", async (t) => {
  const [a] = agent(t, [
    { read: "run" },
    { write: { type: "event", event: { type: "text_delta", data: "thinking" } } },
    { read: "cancel" },
    { write: { type: "error", message: "the run was cancelled" } },
    { read: "run" },
    done("second"),
  ]);
  const events = a.stream("think");
  assert.equal((await events.next()).value.type, "text_delta");
  setTimeout(() => a.cancel(), 50);
  await assert.rejects(events.next(), (e) => e instanceof CookieError && /cancelled/.test(e.message));
  assert.equal(await a.run("again"), "second");
});

test("leaving a stream early cancels and drains; a call that raced the cancel never runs", async (t) => {
  let ran = 0;
  const counted = tool({ name: "lookup", effect: "read", run: () => (ran++, "x") });
  const [a, f] = agent(t, [
    { read: "run" },
    { write: { type: "event", event: { type: "text_delta", data: "a" } } },
    { read: "cancel" },
    { write: { type: "tool_call", id: "t1", name: "lookup", args: {} } },
    { write: { type: "error", message: "the run was cancelled" } },
    { read: "run" },
    done("next"),
  ], { tools: [counted] });
  for await (const _ of a.stream("go")) break;
  assert.equal(await a.run("again"), "next");
  await a.close();
  assert.equal(ran, 0);
  assert.deepEqual(f.sent("tool_result"), []);
});

test("finishTurn is sent", async (t) => {
  const [a] = agent(t, [
    { read: "run" },
    { write: { type: "event", event: { type: "text_delta", data: "a" } } },
    { read: "finish_turn" },
    done("stopped"),
  ]);
  const events = a.stream("go");
  await events.next();
  a.finishTurn();
  assert.deepEqual((await events.next()).value, { type: "done", answer: "stopped" });
});

test("an error line for the run rejects", async (t) => {
  const [a] = agent(t, [{ read: "run" }, { write: { type: "error", message: "unknown provider `nope`" } }]);
  await assert.rejects(a.run("hi"), /unknown provider/);
});

test("an error about a line we sent stops the run and rejects", async (t) => {
  const [a] = agent(t, [
    { read: "run" },
    { write: { type: "error", run: null, message: "nothing is waiting for `t9`" } },
    { read: "cancel" },
    { write: { type: "error", message: "the run was cancelled" } },
    { read: "run" },
    done("fine"),
  ]);
  await assert.rejects(a.run("hi"), /nothing is waiting/);
  assert.equal(await a.run("again"), "fine");
});

test("unknown messages and other runs' lines are skipped", async (t) => {
  const [a] = agent(t, [
    { read: "run" },
    { write: { type: "progress_v9", pct: 50 } },
    { write: { type: "done", run: "r0", answer: "stale" } },
    { write: { type: "event", event: { type: "something_new", data: 1 } } },
    done("real"),
  ]);
  const events = [];
  for await (const e of a.stream("hi")) events.push(e);
  assert.deepEqual(events, [{ type: "something_new", data: 1 }, { type: "done", answer: "real" }]);
});

test("a server that dies mid-run rejects and the next run starts a new one", async (t) => {
  const [a, f] = agent(t, [{ read: "run" }, { exit: 7 }]);
  await assert.rejects(a.run("hi"), /exited \(code 7\)/);
  await assert.rejects(a.run("again"), CookieError);
  assert.equal(f.sent("_started").length, 2);
});

test("a line that is not JSON rejects", async (t) => {
  const [a] = agent(t, [{ read: "run" }, { write_raw: "garbage\n" }]);
  await assert.rejects(a.run("hi"), /not JSON/);
});

test("one run at a time", async (t) => {
  const [a] = agent(t, [{ read: "run" }, done("ok")]);
  const first = a.run("one");
  await assert.rejects(a.run("two"), /already going/);
  assert.equal(await first, "ok");
});

test("the binary comes from COOKIE_BIN, then PATH", async () => {
  const f = fake([{ read: "run" }, done("from env")]);
  const saved = { ...process.env };
  try {
    process.env.COOKIE_BIN = f.bin;
    const a = new Agent({ model: "x:m" });
    assert.equal(await a.run("hi"), "from env");
    await a.close();
    delete process.env.COOKIE_BIN;
    process.env.PATH = mkdtempSync(join(tmpdir(), "empty-"));
    await assert.rejects(new Agent({ model: "x:m" }).run("hi"), /COOKIE_BIN/);
  } finally {
    process.env = saved;
  }
});

test("bad declarations are refused", () => {
  assert.throws(() => tool({ name: "x", effect: "teleport", run: () => "" }), /teleport/);
  assert.throws(() => new Agent({ model: "x:m", tools: [lookup, lookup] }), /twice/);
});

test("a script that forgets close() still exits", () => {
  const f = fake([{ read: "run" }, done("ok")]);
  const script = `import { Agent } from ${JSON.stringify(join(here, "..", "dist", "index.js"))};
    const a = new Agent({ model: "x:m", cookieBin: ${JSON.stringify(f.bin)} });
    console.log(await a.run("hi"));`;
  const out = execFileSync(process.execPath, ["--input-type=module", "-e", script], { timeout: 10_000 });
  assert.equal(out.toString().trim(), "ok");
});

test("the real binary: a bad model rejects and the process keeps serving", { skip: !existsSync(COOKIE) && "cargo build --bin cookie" }, async () => {
  const saved = process.env.ENKEON_API_KEY;
  delete process.env.ENKEON_API_KEY;
  const a = new Agent({ model: "nope:x", cookieBin: COOKIE, tools: [lookup] });
  try {
    await assert.rejects(a.run("hi"), (e) => e instanceof CookieError && /nope/.test(e.message));
    await assert.rejects(a.run("again"), /nope/);
  } finally {
    await a.close();
    if (saved !== undefined) process.env.ENKEON_API_KEY = saved;
  }
});
