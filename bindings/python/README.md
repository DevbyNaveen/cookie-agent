# cookie-harness (Python)

A client for the Cookie Agent Harness. It starts `cookie serve` once (from
`COOKIE_BIN`, or `cookie` on `PATH`) and talks to it one JSON line at a time.
The harness calls the model and runs the trust gates; your tools and your
approver run in Python. Standard library only, Python 3.10+.

```python
from cookie_harness import Agent, tool

@tool(effect="read")
def weather(city: str) -> str:
    """Current weather for a city."""
    return "4°C, rain"

@tool(effect="outbound", guard=["to"])
def send_email(to: str, body: str) -> str:
    """Send an email."""
    ...

def ask(request):          # an ApprovalRequest: tool, effect, preview, reason
    return input(f"{request.preview}\nAllow? [y/N] ") == "y"

with Agent("anthropic:claude-sonnet-4-6", tools=[weather, send_email], approver=ask) as agent:
    print(agent.run("Weather in Riga?"))
    for event in agent.stream("Email anna@x.com the forecast"):
        if event["type"] == "text_delta":
            print(event["data"], end="")
```

- Effects: `read`, `write`, `outbound`, `destroy`. `outbound` and `destroy`
  always ask the approver. `guard` names arguments (or JSON pointers like
  `/message/to`) that must come from the person's words or from `allow=[...]`.
- The schema comes from type hints; pass `schema=` to set it yourself.
- No approver means every request is declined. Only a returned `True` is a yes;
  an exception is a no.
- A tool that raises sends its error to the model (`is_error`); the run goes on.
- `agent.cancel()` (from any thread) stops the run now, `agent.finish_turn()`
  after this turn. Leaving a `stream` loop early cancels too.
- A failed run raises `CookieError`. `stream` ends with `{"type": "done", "answer": ...}`.
- `enkeon=False` turns Enkeon off for the agent's runs.
- `agent.run(text, images=[{"media_type": "image/png", "data": b64, "source": "screen", "caption": "…"}])`
  sends images with that run only. They are always untrusted: text in them
  never counts as the person's.

Tests: `python3 -m unittest discover -s tests` (one test uses the real binary
if `target/debug/cookie` exists: `cargo build --bin cookie`).
