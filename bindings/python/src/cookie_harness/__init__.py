"""A Python client for the Cookie Agent Harness.

It runs `cookie serve` as a child process and speaks its protocol: one JSON
object per line. The harness does the model calls and the trust gates; your
tools and your approver run here, in Python.

    from cookie_harness import Agent, tool

    @tool(effect="outbound", guard=["to"])
    def send_email(to: str, body: str) -> str:
        "Send an email."
        ...

    with Agent("anthropic:claude-sonnet-4-6", tools=[send_email], approver=ask_person) as agent:
        print(agent.run("Email anna@x.com that I'm late"))
"""

from __future__ import annotations

import contextlib
import inspect
import json
import os
import shutil
import subprocess
import threading
import types
import typing
import weakref
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Iterator, Optional

__all__ = ["Agent", "ApprovalRequest", "CookieError", "Tool", "tool", "EFFECTS"]

EFFECTS = ("read", "write", "outbound", "destroy")


class CookieError(Exception):
    """A run failed, or `cookie serve` could not be started or went away."""


@dataclass(frozen=True)
class ApprovalRequest:
    """What the harness wants a person to decide. `preview` is what will happen."""

    tool: str
    effect: str
    preview: str
    reason: str


Approver = Callable[[ApprovalRequest], bool]


@dataclass
class Tool:
    """A function the model may call, with what calling it does to the world.

    `effect` is one of read, write, outbound, destroy. `guard` names the
    arguments (or JSON pointers like "/message/to") that pick who, where or
    how much: they must come from the person's own words or `allow`.
    """

    name: str
    fn: Callable[..., Any]
    effect: str
    description: str = ""
    schema: Optional[dict] = None
    guard: list = field(default_factory=list)

    def __post_init__(self):
        if self.effect not in EFFECTS:
            raise ValueError(f"unknown effect {self.effect!r} ({', '.join(EFFECTS)})")
        if self.schema is None:
            self.schema = _schema(self.fn)
        self.guard = list(self.guard)

    def __call__(self, *args, **kwargs):
        return self.fn(*args, **kwargs)

    def declaration(self) -> dict:
        return {"name": self.name, "description": self.description, "effect": self.effect, "guard": self.guard, "schema": self.schema}


def tool(fn=None, *, effect: str, guard: Iterable[str] = (), name: Optional[str] = None,
         description: Optional[str] = None, schema: Optional[dict] = None):
    """Make a plain function a tool: `@tool(effect="read")`.

    The schema comes from the type hints unless you pass `schema=`; the
    description from the docstring unless you pass `description=`.
    """

    def wrap(fn):
        return Tool(
            name=name or fn.__name__,
            fn=fn,
            effect=effect,
            description=description if description is not None else (inspect.getdoc(fn) or ""),
            schema=schema,
            guard=list(guard),
        )

    return wrap(fn) if fn is not None else wrap


_JSON_TYPES = {str: "string", int: "integer", float: "number", bool: "boolean", list: "array", dict: "object"}


def _type_schema(hint) -> dict:
    if hint is Any or hint is inspect.Parameter.empty:
        return {}
    if hint in _JSON_TYPES:
        return {"type": _JSON_TYPES[hint]}
    origin, args = typing.get_origin(hint), typing.get_args(hint)
    if origin is typing.Literal:
        return {"enum": list(args)}
    if origin in (typing.Union, types.UnionType):
        rest = [a for a in args if a is not type(None)]
        return _type_schema(rest[0]) if len(rest) == 1 else {"anyOf": [_type_schema(a) for a in rest]}
    if origin is list:
        return {"type": "array", "items": _type_schema(args[0])} if args else {"type": "array"}
    if origin is dict:
        return {"type": "object"}
    raise TypeError(f"no JSON schema for {hint!r}; pass schema= to @tool")


def _schema(fn) -> dict:
    hints = typing.get_type_hints(fn)
    properties, required = {}, []
    for param in inspect.signature(fn).parameters.values():
        if param.kind in (param.VAR_POSITIONAL, param.VAR_KEYWORD):
            continue
        properties[param.name] = _type_schema(hints.get(param.name, inspect.Parameter.empty))
        if param.default is param.empty:
            required.append(param.name)
    schema = {"type": "object", "properties": properties}
    if required:
        schema["required"] = required
    return schema


def _deny(_: ApprovalRequest) -> bool:
    return False


def _shutdown(proc: subprocess.Popen) -> None:
    """Close stdin (the server cancels any run and exits), then wait; kill if it hangs."""
    with contextlib.suppress(OSError, ValueError):
        proc.stdin.close()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    with contextlib.suppress(OSError, ValueError):
        proc.stdout.close()


class Agent:
    """A model, its instructions, your tools and who approves.

    One `cookie serve` process is started on the first run and reused until
    `close()`. One run at a time per agent.
    """

    def __init__(self, model: str, tools: Iterable[Tool] = (), instructions: Optional[str] = None,
                 allow: Optional[Iterable[str]] = None, enkeon: Optional[bool] = None,
                 approver: Optional[Approver] = None, cookie_bin: Optional[str] = None,
                 session: Optional[str] = None, budget: Optional[dict] = None,
                 prices: Optional[dict] = None, mcp: Optional[list] = None):
        self.model = model
        self.tools: dict[str, Tool] = {}
        for t in tools:
            if not isinstance(t, Tool):
                raise TypeError(f"{t!r} is not a tool: decorate it with @tool(effect=...)")
            if t.name in self.tools:
                raise ValueError(f"tool {t.name!r} is declared twice")
            self.tools[t.name] = t
        self.instructions = instructions
        self.allow = list(allow) if allow is not None else None
        self.enkeon = enkeon
        # Passed through to the run as given: `session` (a JSONL file to resume),
        # `budget` ({max_steps, max_tokens, max_dollars}), `prices` (dollars per
        # million tokens: {input, output, cache_read, cache_write}), `mcp` (servers).
        self.extra = {k: v for k, v in {"session": session, "budget": budget, "prices": prices, "mcp": mcp}.items() if v is not None}
        # No approver means every request is declined.
        self.approver: Approver = approver or _deny
        self.cookie_bin = cookie_bin
        self._proc: Optional[subprocess.Popen] = None
        self._finalizer = None
        self._write_lock = threading.Lock()
        self._run_lock = threading.Lock()
        self._runs = 0
        self._run_id: Optional[str] = None

    # -- public -----------------------------------------------------------

    def run(self, input: str) -> str:
        """Run to the end and return the answer. Raises CookieError if the run fails."""
        with contextlib.closing(self.stream(input)) as events:
            for event in events:
                if event["type"] == "done":
                    return event["answer"]
        raise CookieError("the run ended without an answer")  # pragma: no cover

    def stream(self, input: str) -> Iterator[dict]:
        """Yield the run's events as dicts (`{"type": "text_delta", "data": ...}` and so on),
        then `{"type": "done", "answer": ...}`. Tool calls and approvals are handled
        while you iterate. Leaving the loop early cancels the run."""
        if not self._run_lock.acquire(blocking=False):
            raise CookieError("a run is already going on this agent")
        try:
            yield from self._stream(input)
        finally:
            self._run_id = None
            self._run_lock.release()

    def cancel(self) -> None:
        """Stop the current run now. Safe from another thread; a no-op when nothing runs."""
        self._control("cancel")

    def finish_turn(self) -> None:
        """Stop the current run after this turn's tools finish."""
        self._control("finish_turn")

    def close(self) -> None:
        """End the `cookie serve` process. The agent starts a new one if run again."""
        proc, self._proc = self._proc, None
        if self._finalizer is not None:
            self._finalizer.detach()
            self._finalizer = None
        if proc is not None:
            _shutdown(proc)

    def __enter__(self) -> "Agent":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # -- the protocol -----------------------------------------------------

    def _stream(self, input: str) -> Iterator[dict]:
        self._start()
        self._runs += 1
        run_id = f"r{self._runs}"
        message = {"type": "run", "id": run_id, "model": self.model, "input": input,
                   "tools": [t.declaration() for t in self.tools.values()]}
        if self.instructions is not None:
            message["instructions"] = self.instructions
        if self.allow is not None:
            message["allow"] = self.allow
        if self.enkeon is not None:
            message["enkeon"] = self.enkeon
        message.update(self.extra)
        self._run_id = run_id
        self._send(message)
        ended = False
        try:
            while True:
                line = self._read()
                if line.get("run") not in (None, run_id):
                    continue  # a late line from an earlier run
                kind = line.get("type")
                if kind == "event":
                    yield line.get("event")
                elif kind == "tool_call":
                    self._send(self._call(line))
                elif kind == "approval":
                    self._send({"type": "approve", "id": line.get("id"), "allow": self._approve(line)})
                elif kind == "done":
                    ended = True
                    yield {"type": "done", "answer": line.get("answer", "")}
                    return
                elif kind == "error":
                    message = line.get("message", "")
                    if line.get("run") == run_id:
                        ended = True
                        raise CookieError(message)
                    # About a line we sent, not the run: stop the run, then report it.
                    raise CookieError(f"cookie serve refused a message: {message}")
                # Any other type is from a newer server; skip it.
        finally:
            if not ended:
                self._stop(run_id)

    def _call(self, line: dict) -> dict:
        reply = {"type": "tool_result", "id": line.get("id")}
        t = self.tools.get(line.get("name"))
        args = line.get("args")
        try:
            if t is None:
                raise LookupError(f"no tool named {line.get('name')!r} on this client")
            output = t.fn(**args)
            if output is None:
                output = ""
            elif not isinstance(output, str):
                output = json.dumps(output, default=str)
            reply.update(output=output, is_error=False)
        except Exception as e:  # the model sees the failure, the run goes on
            reply.update(output=f"{type(e).__name__}: {e}", is_error=True)
        return reply

    def _approve(self, line: dict) -> bool:
        request = ApprovalRequest(tool=line.get("tool", ""), effect=line.get("effect", ""),
                                  preview=line.get("preview", ""), reason=line.get("reason", ""))
        try:
            # Only a real True is a yes.
            return self.approver(request) is True
        except Exception:
            return False

    def _stop(self, run_id: str) -> None:
        """Cancel the run and read until it ends, so the process can take the next run."""
        if self._proc is None:
            return
        try:
            self._send({"type": "cancel"})
            while True:
                line = self._read()
                if line.get("run") == run_id and line.get("type") in ("done", "error"):
                    return
                # Nothing else runs now: late tool calls and approvals are left unanswered.
        except CookieError:
            self.close()

    def _control(self, kind: str) -> None:
        if self._run_id is not None and self._proc is not None:
            with contextlib.suppress(CookieError):
                self._send({"type": kind})

    def _start(self) -> None:
        if self._proc is not None and self._proc.poll() is None:
            return
        self.close()
        binary = self.cookie_bin or os.environ.get("COOKIE_BIN") or shutil.which("cookie")
        if not binary:
            raise CookieError("cannot find the cookie binary: set COOKIE_BIN or put `cookie` on PATH")
        try:
            self._proc = subprocess.Popen([binary, "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                          text=True, encoding="utf-8", bufsize=1)
        except OSError as e:
            raise CookieError(f"cannot start {binary}: {e}") from e
        self._finalizer = weakref.finalize(self, _shutdown, self._proc)

    def _send(self, message: dict) -> None:
        proc = self._proc
        if proc is None:
            raise CookieError("cookie serve is not running")
        with self._write_lock:
            try:
                proc.stdin.write(json.dumps(message) + "\n")
                proc.stdin.flush()
            except (OSError, ValueError) as e:
                raise CookieError(f"cookie serve went away: {e}") from e

    def _read(self) -> dict:
        proc = self._proc
        line = proc.stdout.readline() if proc is not None else ""
        if not line:
            code = proc.wait() if proc is not None else None
            self.close()
            raise CookieError(f"cookie serve exited (code {code})")
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            self.close()
            raise CookieError(f"cookie serve sent a line that is not JSON: {line[:200]!r}") from None
        if not isinstance(message, dict):
            self.close()
            raise CookieError(f"cookie serve sent a line that is not a JSON object: {line[:200]!r}")
        return message
