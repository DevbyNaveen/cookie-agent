# Durable action admission and verification

The harness works without Enkeon. An embedding application can opt into a local
write-ahead action ledger:

```rust,no_run
use cookie_harness::{Agent, durable::ActionLedger};
fn configure(agent: Agent) -> cookie_harness::Result<Agent> {
    Ok(agent.action_ledger(ActionLedger::open("./receipts", "job-42/revision-1")?))
}
```

`cookie serve` accepts the equivalent run field:

```json
{"action_ledger":{"directory":"./receipts","scope":"job-42/revision-1"}}
```

Keep the directory on persistent local storage and reuse the same application-owned
scope on restart. The model must not choose scopes. Configure every writing agent
with the appropriate ledger; this setting is per agent, not an implicit delegation
permission. This does not automatically restart the Mac application or reconstruct
its user interface. The embedding app owns scheduling and job identity.

The ledger uses exclusive file creation and fsync before a non-read tool call.
An interrupted attempt remains unknown. A successful return is acknowledged,
not verified. Repeated attempts are refused even if the result file is missing.
Stored files contain tool names and hashes, not arguments or response contents.
Do not delete a receipt to blindly retry. This is at-most-once admission for the
same operation and scope, not exactly-once delivery, distributed locking or
semantic deduplication of differently phrased operations.

`Agent::verify_with` and the serve `verification` field accept application-owned
rules matching a write tool to a read tool. Both resource identity and desired
field values must match using exact JSON pointers. A successful unrelated read
does not clear the pending verification reminder. A reminder or a model answer
is not an independently verified receipt.

The answer checker returns `supported`, `unsupported` or `unavailable`. Missing,
malformed or failed checks cannot return success. Clients should keep that status
when displaying, evaluating or learning from an answer.

Run the normal harness suite plus the Python MCP integration on the designated
AWS test box. Live provider tests require their own credentials and measurements;
unit-test success does not establish SOTA accuracy or security.
