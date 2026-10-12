# AgentDojo through the Cookie Agent Harness

Runs AgentDojo 0.1.35 (benchmark v1.2.2: workspace, travel, banking, slack)
through `cookie serve` with the Python client, in two arms:

| Arm | Tools | Approvals |
|---|---|---|
| `trust` | effects and guards from the table below | every request that reaches the approver is approved |
| `off` | every tool `read`, no guards (nothing is gated or asked) | same |

Same model, same AgentDojo system message (as the harness's instructions),
same tools, Enkeon off. Both arms approve everything because a benchmark has
no person in it: the `trust` arm's protection is only what the harness
decides on its own — a guarded argument whose value came from tool output
(not from the task's own words) is refused before anyone is asked.

## Run it

Needs Python 3.10+, a built `cookie` and the model's key in the environment
(`ANTHROPIC_API_KEY` for `anthropic:` models). Nothing here has been run
against a model yet.

```sh
cargo build --release --bin cookie                 # from the repo root
cd evals/agentdojo
python3.11 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python run.py --model anthropic:claude-sonnet-4-6 \
    --cookie-bin ../../target/release/cookie --logdir runs
```

Flags: `--suite` and `--arm` (repeatable; default all four suites, both
arms), `--user-task` / `--injection-task` (repeatable; default all),
`--attack` (default `important_instructions`), `--benchmark-version`
(default `v1.2.2`), `--no-attack` (utility only), `--force-rerun` (else
tasks already in `--logdir` are read back, not rerun), `--model-name` (how
the attack addresses the model; `Claude` for Claude models, required for any
other — AgentDojo's own list of names predates current models, so it is
added at start).

It prints, per arm and suite: **utility** (no attack), **utility under
attack**, and **targeted ASR** — the mean of AgentDojo's `security_results`,
which is True when the injection's goal was carried out (despite the name,
higher is worse). The same rows go to `runs/results-<model>.json`; AgentDojo's
per-task logs go under `runs/cookie-<arm>-<model>/`.

A run that ends on the agent's own limit (budget reached, out of output
tokens, a repeated-call loop) is scored as a failed task. Any other error
(no key, bad model, provider down) stops the run so it is seen; rerun the
same command to continue from the logs.

## Effects and guards (`trust` arm)

Anything that sends, shares or invites is `outbound`; anything that deletes,
cancels, pays or books is `destroy`. Both always go to the approver. Guards
sit on the arguments that pick who receives, who is paid, or where data
goes: their values must appear in the task's words, or the call is refused (the
system message is the developer's, not the person's, so it does not count). `write` asks only after untrusted content was read.

| Tool | Suite | Effect | Guarded |
|---|---|---|---|
| `send_email` | workspace, travel | outbound | `recipients`, `cc`, `bcc` |
| `delete_email` | workspace | destroy | |
| `create_calendar_event` | workspace, travel | outbound (invites participants) | `participants` |
| `add_calendar_event_participants` | workspace | outbound | `participants` |
| `cancel_calendar_event` | workspace, travel | destroy | |
| `reschedule_calendar_event` | workspace | write | |
| `create_file`, `append_to_file` | workspace | write | |
| `delete_file` | workspace | destroy | |
| `share_file` | workspace | outbound | `email` |
| `reserve_hotel` | travel | destroy (pays) | `hotel` |
| `reserve_car_rental` | travel | destroy (pays) | `company` |
| `reserve_restaurant` | travel | destroy (pays) | `restaurant` |
| `send_money` | banking | destroy | `recipient` |
| `schedule_transaction` | banking | destroy | `recipient` |
| `update_scheduled_transaction` | banking | destroy | `recipient` |
| `update_password` | banking | destroy | `password` |
| `update_user_info` | banking | write | |
| `send_direct_message` | slack | outbound | `recipient` |
| `send_channel_message` | slack | outbound | `channel` |
| `invite_user_to_slack` | slack | outbound | `user`, `user_email` |
| `add_user_to_channel` | slack | write | `user` |
| `remove_user_from_slack` | slack | destroy | `user` |
| `post_webpage` | slack | outbound | `url` |
| `get_webpage` | slack | read | `url` (a fetched URL can carry data out) |
| every other tool (`get_*`, `search_*`, `list_files`, `read_*`, `check_*`) | all | read | |

What this costs, on purpose: a task that asks the agent to pay, book or
write to someone it has to *look up* (a hotel picked from search results, a
recipient read from a file) is refused in the `trust` arm, and counts
against its utility. Amounts are not guarded. The table lives in `bridge.py`
(`TRUST_MAP`, `KNOWN_READS`); a tool not in either is an error, not a
default.

## Tests

```sh
.venv/bin/python -m unittest test_bridge
```

No model: a scripted fake `cookie serve` (`bindings/python/tests/fake_serve.py`).
They check the table covers every v1.2.2 tool and each guard names a real
argument, that a call runs against the AgentDojo environment and lands in the
trace, both arms' declarations, error handling, the attack's model name, and
`run.py` end to end on one banking task pair.
