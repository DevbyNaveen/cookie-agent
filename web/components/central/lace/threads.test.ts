import { strict as assert } from "node:assert";
import { test } from "node:test";
import { doingOf, onBoard, thoughtOf, threadsOf, titleOf } from "./threads.ts";

const run = (id: string, at: string, extra: Record<string, unknown> = {}) =>
  ({ id, trigger: "page", subject: id, status: "done", started_at: at, steps: [], ...extra }) as never;

test("a follow-up and an answer to Cookie's questions stay in the conversation they began in", () => {
  const t = threadsOf([
    run("ok", "2026-10-22T17:21:30Z", { parent_run_id: "leads" }),
    run("leads", "2026-10-22T17:21:00Z"),
    run("more", "2026-10-22T17:25:00Z", { conversation: "ok" }),
    run("hey", "2026-10-20T09:00:00Z"),
    run("slack", "2026-10-21T09:00:00Z", { trigger: "slack", mine: false, who: "Anna" }),
  ]);
  assert.deepEqual(t.map((x) => x.key), ["leads", "slack", "hey"]);
  assert.deepEqual(t[0].runs.map((r) => r.id), ["leads", "ok", "more"]);
  assert.equal(titleOf(t[0]), "leads");
  assert.equal(t[0].last.id, "more");
  assert.equal(t[1].mine, false);
  assert.equal(t[1].who, "Anna");
});

test("a working job says what it is doing in a few words", () => {
  assert.equal(doingOf(run("a", "x", { steps: [{ tool: "read_url", what: "https://www.techcrunch.com/x" }] })), "Reading techcrunch.com");
  assert.equal(doingOf(run("a", "x", { steps: [{ tool: "web_search", what: "leads" }] })), "Searching the web");
  assert.equal(doingOf(run("a", "x", { queued: true })), "Waiting for a turn");
  assert.equal(doingOf(run("a", "x")), "Reading the request");
});

test("a follow-up's board keeps what the conversation read before, its own sources still pointing right", () => {
  const first = run("a", "2026-10-22T17:00:00Z", { steps: [{ tool: "recall", what: "acme", at_ms: 900, ok: true }, { tool: "helper", helper: "h1", what: "find", at_ms: 5000, ok: true }] });
  const next = run("b", "2026-10-22T17:05:00Z", {
    conversation: "a",
    steps: [{ tool: "web_search", what: "acme news", at_ms: 800, ok: true }, { tool: "read_url", what: "https://acme.com", at_ms: 1500, via: 0, ok: true }],
    answer_sources: [[1]],
  });
  const b = onBoard(next as never, [first, next] as never);
  assert.equal(b.steps.length, 4);
  assert.deepEqual(b.steps.map((s) => Boolean(s.prior)), [true, true, false, false]);
  assert.equal(b.steps[1].helper, "a:h1", "an earlier message's helper never collides with this one's");
  assert.equal(b.steps[3].via, 2, "a page still hangs from its own search");
  assert.deepEqual(b.answer_sources, [[3]], "the answer still cites its own page");
  assert.equal(onBoard(first as never, [first, next] as never), first, "the first message's board is its own");
});

test("Cookie's thought follows what it is doing, and rests when it rests", () => {
  const working = (extra: Record<string, unknown>) => run("a", "x", { status: "running", ...extra });
  assert.equal(thoughtOf(working({ steps: [{ tool: "web_search", what: "AI startups Riga" }] }) as never), "Searching “AI startups Riga”…");
  assert.equal(thoughtOf(working({ steps: [{ tool: "read_url", what: "https://www.spotwise.lv/x" }] }) as never), "Reading spotwise.lv…");
  assert.equal(thoughtOf(working({ live_text: "Here" }) as never), "Writing it up…");
  assert.equal(thoughtOf(run("a", "x") as never), null, "nothing while it rests");
});
