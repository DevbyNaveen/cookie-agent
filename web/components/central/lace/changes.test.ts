import { strict as assert } from "node:assert";
import { test } from "node:test";
import { actionLabel, changeOutcome, changesOf } from "./changes.ts";

const name = (a: string) => (a === "hubspot" ? "HubSpot" : a);

test("an action name reads as words, without its app", () => {
  assert.equal(actionLabel("hubspot", "HUBSPOT_UPDATE_DEAL"), "Update deal");
  assert.equal(actionLabel("googledrive", "GOOGLEDRIVE_CREATE_FILE"), "Create file");
  assert.equal(actionLabel("linear", "CREATE_ISSUE"), "Create issue");
});

test("a run's changes leave reads out and find their approval", () => {
  const run = {
    steps: [
      { at_ms: 1, tool: "app_call", what: "", ok: true, action: { app: "hubspot", name: "HUBSPOT_GET_DEAL", effect: "read", state: "done" } },
      { at_ms: 2, tool: "app_call", what: "", ok: true, action: { app: "hubspot", name: "HUBSPOT_UPDATE_DEAL", effect: "write", state: "waiting", approval: "apr_1" } },
      { at_ms: 3, tool: "recall", what: "", ok: true },
    ],
  } as never;
  const approvals = [{ id: "apr_1", slug: "hubspot", tool: "HUBSPOT_UPDATE_DEAL", class: "write", status: "pending", detail: "stage: won", result: null, created_at: "", expires_at: "" }];
  const changes = changesOf(run, approvals);
  assert.equal(changes.length, 1);
  assert.equal(changes[0].approval?.id, "apr_1");
  assert.equal(changeOutcome(changes[0].action, changes[0].approval, name), null, "waiting shows the buttons, not an outcome");
});

test("each end of a change says what happened", () => {
  const a = { app: "hubspot", name: "HUBSPOT_UPDATE_DEAL", effect: "write", state: "waiting", approval: "apr_1" };
  const ap = (status: string, result: string | null = null) => ({ id: "apr_1", slug: "hubspot", tool: a.name, class: "write", status, detail: null, result, created_at: "", expires_at: "" });
  assert.equal(changeOutcome(a, ap("approved"), name), "Done in HubSpot");
  assert.equal(changeOutcome(a, ap("denied"), name), "You said no — nothing was changed");
  assert.equal(changeOutcome(a, ap("expired"), name), "Expired before a yes — nothing was changed");
  assert.equal(changeOutcome(a, ap("failed", "deal not found"), name), "HubSpot did not take it: deal not found");
  assert.equal(changeOutcome({ ...a, state: "unknown", approval: undefined }, undefined, name), "Unconfirmed — check HubSpot");
  assert.equal(changeOutcome({ ...a, state: "refused", approval: undefined }, undefined, name), "HubSpot is set not to allow this");
});
