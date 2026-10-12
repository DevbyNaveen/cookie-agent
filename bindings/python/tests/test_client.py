"""The client against a scripted fake `cookie serve`, and once against the real one."""

import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import typing
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))

from cookie_harness import Agent, ApprovalRequest, CookieError, Tool, tool  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[2]


class Fake:
    """A fake binary in a temp dir that plays `script` and logs what it reads."""

    def __init__(self, script):
        self.dir = tempfile.mkdtemp()
        self.log = os.path.join(self.dir, "log.jsonl")
        script_path = os.path.join(self.dir, "script.json")
        with open(script_path, "w") as f:
            json.dump(script, f)
        self.bin = os.path.join(self.dir, "cookie")
        with open(self.bin, "w") as f:
            f.write(
                "#!/bin/sh\n"
                f'FAKE_SCRIPT="{script_path}" FAKE_LOG="{self.log}" exec "{sys.executable}" "{HERE / "fake_serve.py"}" "$@"\n'
            )
        os.chmod(self.bin, os.stat(self.bin).st_mode | stat.S_IXUSR)

    def received(self):
        with open(self.log) as f:
            return [json.loads(line) for line in f if line.strip()]

    def sent(self, kind):
        return [m for m in self.received() if m.get("type") == kind]

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def done(answer):
    return {"write": {"type": "done", "answer": answer}}


@tool(effect="read")
def lookup(q: str) -> str:
    """Look something up."""
    return f"found {q}"


@tool(effect="outbound", guard=["to"])
def send_email(to: str, body: str = "") -> str:
    """Send an email."""
    return f"sent to {to}"


@tool(effect="write")
def broken(path: str) -> str:
    raise ValueError("disk full")


class ClientTest(unittest.TestCase):
    def agent(self, script, **kwargs):
        fake = Fake(script)
        self.addCleanup(fake.cleanup)
        agent = Agent("x:m", cookie_bin=fake.bin, **kwargs)
        self.addCleanup(agent.close)
        return agent, fake

    def test_run_sends_the_declared_run_and_returns_the_answer(self):
        agent, fake = self.agent(
            [{"read": "run"}, {"write": {"type": "event", "event": {"type": "text_delta", "data": "hi"}}}, done("hi there")],
            tools=[send_email],
            instructions="Be brief.",
            allow=["anna@x.com"],
            enkeon=False,
        )
        self.assertEqual(agent.run("email anna"), "hi there")
        agent.close()
        [run] = fake.sent("run")
        self.assertEqual(
            run,
            {
                "type": "run",
                "id": "r1",
                "model": "x:m",
                "input": "email anna",
                "instructions": "Be brief.",
                "allow": ["anna@x.com"],
                "enkeon": False,
                "tools": [
                    {
                        "name": "send_email",
                        "description": "Send an email.",
                        "effect": "outbound",
                        "guard": ["to"],
                        "schema": {
                            "type": "object",
                            "properties": {"to": {"type": "string"}, "body": {"type": "string"}},
                            "required": ["to"],
                        },
                    }
                ],
            },
        )

    def test_session_budget_prices_and_mcp_are_passed_through(self):
        agent, fake = self.agent(
            [{"read": "run"}, done("ok")],
            session="s.jsonl",
            budget={"max_steps": 5, "max_dollars": 0.5},
            prices={"input": 3.0, "output": 15.0, "cache_read": 0.3, "cache_write": 3.75},
            mcp=[{"command": "github-mcp", "effects": {"search": "read"}}],
        )
        agent.run("hi")
        agent.close()
        [run] = fake.sent("run")
        self.assertEqual(run["session"], "s.jsonl")
        self.assertEqual(run["budget"], {"max_steps": 5, "max_dollars": 0.5})
        self.assertEqual(run["prices"]["output"], 15.0)
        self.assertEqual(run["mcp"], [{"command": "github-mcp", "effects": {"search": "read"}}])

    def test_unset_options_are_left_out_of_the_run(self):
        agent, fake = self.agent([{"read": "run"}, done("ok")])
        agent.run("hi")
        agent.close()
        self.assertEqual(fake.sent("run"), [{"type": "run", "id": "r1", "model": "x:m", "input": "hi", "tools": []}])

    def test_stream_yields_events_then_done_and_runs_reuse_one_process(self):
        agent, fake = self.agent(
            [
                {"read": "run"},
                {"write": {"type": "event", "event": {"type": "text_delta", "data": "a"}}},
                {"write": {"type": "event", "event": {"type": "usage", "data": {"input_tokens": 3}}}},
                done("a"),
                {"read": "run"},
                done("b"),
            ]
        )
        events = list(agent.stream("one"))
        self.assertEqual(
            events,
            [{"type": "text_delta", "data": "a"}, {"type": "usage", "data": {"input_tokens": 3}}, {"type": "done", "answer": "a"}],
        )
        self.assertEqual(agent.run("two"), "b")
        agent.close()
        self.assertEqual(len(fake.sent("_started")), 1, "one process for both runs")
        self.assertEqual([r["id"] for r in fake.sent("run")], ["r1", "r2"])

    def test_a_client_tool_is_called_and_its_output_sent_back(self):
        agent, fake = self.agent(
            [
                {"read": "run"},
                {"write": {"type": "tool_call", "id": "t1", "name": "lookup", "args": {"q": "riga"}}},
                {"read": "tool_result"},
                done("ok"),
            ],
            tools=[lookup],
        )
        self.assertEqual(agent.run("look"), "ok")
        agent.close()
        self.assertEqual(fake.sent("tool_result"), [{"type": "tool_result", "id": "t1", "output": "found riga", "is_error": False}])

    def test_a_tool_that_raises_answers_with_is_error(self):
        agent, fake = self.agent(
            [
                {"read": "run"},
                {"write": {"type": "tool_call", "id": "t1", "name": "broken", "args": {"path": "/a"}}},
                {"read": "tool_result"},
                {"write": {"type": "tool_call", "id": "t2", "name": "missing", "args": {}}},
                {"read": "tool_result"},
                {"write": {"type": "tool_call", "id": "t3", "name": "lookup", "args": {"nope": 1}}},
                {"read": "tool_result"},
                done("ok"),
            ],
            tools=[broken, lookup],
        )
        agent.run("go")
        agent.close()
        results = fake.sent("tool_result")
        self.assertEqual(results[0], {"type": "tool_result", "id": "t1", "output": "ValueError: disk full", "is_error": True})
        self.assertTrue(results[1]["is_error"] and "missing" in results[1]["output"])
        self.assertTrue(results[2]["is_error"] and "TypeError" in results[2]["output"])

    def test_non_string_results_are_sent_as_json(self):
        @tool(effect="read")
        def numbers() -> list:
            return [1, 2]

        agent, fake = self.agent(
            [{"read": "run"}, {"write": {"type": "tool_call", "id": "t1", "name": "numbers", "args": {}}}, {"read": "tool_result"}, done("ok")],
            tools=[numbers],
        )
        agent.run("go")
        agent.close()
        self.assertEqual(fake.sent("tool_result")[0]["output"], "[1, 2]")

    def approval_script(self):
        return [
            {"read": "run"},
            {"write": {"type": "approval", "id": "a1", "tool": "send_email", "effect": "outbound", "preview": "to anna", "reason": "sends"}},
            {"read": "approve"},
            done("ok"),
        ]

    def test_the_approver_is_asked_and_its_yes_is_sent(self):
        asked = []
        agent, fake = self.agent(self.approval_script(), tools=[send_email], approver=lambda r: asked.append(r) or True)
        agent.run("email anna")
        agent.close()
        self.assertEqual(asked, [ApprovalRequest(tool="send_email", effect="outbound", preview="to anna", reason="sends")])
        self.assertEqual(fake.sent("approve"), [{"type": "approve", "id": "a1", "allow": True}])

    def test_no_approver_a_raising_approver_or_a_non_true_answer_is_a_no(self):
        def raises(_):
            raise RuntimeError("no one home")

        for approver in [None, raises, lambda r: "yes", lambda r: 1, lambda r: False]:
            with self.subTest(approver=approver):
                agent, fake = self.agent(self.approval_script(), tools=[send_email], approver=approver)
                agent.run("email anna")
                agent.close()
                self.assertEqual(fake.sent("approve"), [{"type": "approve", "id": "a1", "allow": False}])

    def test_cancel_from_another_thread_ends_the_run_and_the_next_run_works(self):
        agent, fake = self.agent(
            [
                {"read": "run"},
                {"write": {"type": "event", "event": {"type": "text_delta", "data": "thinking"}}},
                {"read": "cancel"},
                {"write": {"type": "error", "message": "the run was cancelled"}},
                {"read": "run"},
                done("second"),
            ]
        )
        events = agent.stream("think")
        self.assertEqual(next(events)["type"], "text_delta")
        threading.Timer(0.1, agent.cancel).start()
        with self.assertRaisesRegex(CookieError, "cancelled"):
            next(events)
        self.assertEqual(agent.run("again"), "second")

    def test_leaving_a_stream_early_cancels_and_drains_the_run(self):
        agent, fake = self.agent(
            [
                {"read": "run"},
                {"write": {"type": "event", "event": {"type": "text_delta", "data": "a"}}},
                {"read": "cancel"},
                # A call that raced the cancel: it must not run.
                {"write": {"type": "tool_call", "id": "t1", "name": "lookup", "args": {"q": "late"}}},
                {"write": {"type": "error", "message": "the run was cancelled"}},
                {"read": "run"},
                done("next"),
            ],
            tools=[lookup],
        )
        for event in agent.stream("go"):
            break
        self.assertEqual(agent.run("again"), "next")
        agent.close()
        self.assertEqual(fake.sent("tool_result"), [], "nothing ran after the cancel")

    def test_finish_turn_is_sent(self):
        agent, fake = self.agent(
            [
                {"read": "run"},
                {"write": {"type": "event", "event": {"type": "text_delta", "data": "a"}}},
                {"read": "finish_turn"},
                done("stopped"),
            ]
        )
        events = agent.stream("go")
        next(events)
        agent.finish_turn()
        self.assertEqual(list(events), [{"type": "done", "answer": "stopped"}])

    def test_an_error_line_for_the_run_raises(self):
        agent, _ = self.agent([{"read": "run"}, {"write": {"type": "error", "message": "unknown provider `nope`"}}])
        with self.assertRaisesRegex(CookieError, "unknown provider"):
            agent.run("hi")

    def test_an_error_about_a_line_we_sent_stops_the_run_and_raises(self):
        agent, fake = self.agent(
            [
                {"read": "run"},
                {"write": {"type": "error", "run": None, "message": "nothing is waiting for `t9`"}},
                {"read": "cancel"},
                {"write": {"type": "error", "message": "the run was cancelled"}},
                {"read": "run"},
                done("fine"),
            ]
        )
        with self.assertRaisesRegex(CookieError, "nothing is waiting"):
            agent.run("hi")
        self.assertEqual(agent.run("again"), "fine")

    def test_unknown_messages_and_other_runs_lines_are_ignored(self):
        agent, _ = self.agent(
            [
                {"read": "run"},
                {"write": {"type": "progress_v9", "pct": 50}},
                {"write": {"type": "done", "run": "r0", "answer": "stale"}},
                {"write": {"type": "event", "event": {"type": "something_new", "data": 1}}},
                done("real"),
            ]
        )
        events = list(agent.stream("hi"))
        self.assertEqual(events, [{"type": "something_new", "data": 1}, {"type": "done", "answer": "real"}])

    def test_a_server_that_dies_mid_run_raises_and_the_next_run_starts_a_new_one(self):
        agent, fake = self.agent([{"read": "run"}, {"exit": 7}])
        with self.assertRaisesRegex(CookieError, "exited"):
            agent.run("hi")
        with self.assertRaises(CookieError):
            agent.run("again")
        self.assertEqual(len(fake.sent("_started")), 2)

    def test_a_line_that_is_not_json_raises(self):
        agent, _ = self.agent([{"read": "run"}, {"write_raw": "garbage\n"}])
        with self.assertRaisesRegex(CookieError, "not JSON"):
            agent.run("hi")

    def test_close_ends_the_process(self):
        agent, fake = self.agent([{"read": "run"}, done("ok")])
        agent.run("hi")
        proc = agent._proc
        agent.close()
        self.assertIsNotNone(proc.poll())
        agent.close()  # twice is fine

    def test_the_binary_comes_from_cookie_bin_then_path(self):
        fake = Fake([{"read": "run"}, done("from env")])
        self.addCleanup(fake.cleanup)
        old = os.environ.get("COOKIE_BIN")
        os.environ["COOKIE_BIN"] = fake.bin
        try:
            with Agent("x:m") as agent:
                self.assertEqual(agent.run("hi"), "from env")
        finally:
            os.environ.pop("COOKIE_BIN") if old is None else os.environ.__setitem__("COOKIE_BIN", old)
        old_path, old_bin = os.environ.get("PATH", ""), os.environ.pop("COOKIE_BIN", None)
        os.environ["PATH"] = tempfile.mkdtemp()
        try:
            with self.assertRaisesRegex(CookieError, "COOKIE_BIN"):
                Agent("x:m").run("hi")
        finally:
            os.environ["PATH"] = old_path
            if old_bin is not None:
                os.environ["COOKIE_BIN"] = old_bin


class ToolTest(unittest.TestCase):
    def test_schema_from_type_hints(self):
        @tool(effect="read", guard=["/where/host"])
        def search(q: str, limit: int = 5, ratio: float = 0.5, exact: bool = False, tags: list[str] = [],
                   mode: typing.Literal["a", "b"] = "a", where: typing.Optional[dict] = None, x: "int | None" = None) -> str:
            """Search.

            Longer text."""
            return q

        self.assertEqual(search.name, "search")
        self.assertEqual(search.description, "Search.\n\nLonger text.")
        self.assertEqual(search.guard, ["/where/host"])
        self.assertEqual(
            search.schema,
            {
                "type": "object",
                "properties": {
                    "q": {"type": "string"},
                    "limit": {"type": "integer"},
                    "ratio": {"type": "number"},
                    "exact": {"type": "boolean"},
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "mode": {"enum": ["a", "b"]},
                    "where": {"type": "object"},
                    "x": {"type": "integer"},
                },
                "required": ["q"],
            },
        )
        self.assertEqual(search("hi"), "hi", "a tool is still a plain function")

    def test_explicit_schema_name_and_description_win(self):
        schema = {"type": "object", "properties": {"n": {"type": "integer", "minimum": 0}}}

        @tool(effect="destroy", schema=schema, name="rm", description="Remove.")
        def remove(**kwargs):
            return "ok"

        self.assertEqual((remove.name, remove.description, remove.schema, remove.effect), ("rm", "Remove.", schema, "destroy"))

    def test_bad_declarations_are_refused(self):
        with self.assertRaisesRegex(ValueError, "teleport"):
            tool(effect="teleport")(lambda: "")
        with self.assertRaisesRegex(TypeError, "schema="):
            @tool(effect="read")
            def f(x: set) -> str:
                return ""
        with self.assertRaisesRegex(TypeError, "@tool"):
            Agent("x:m", tools=[lambda: ""])
        with self.assertRaisesRegex(ValueError, "twice"):
            Agent("x:m", tools=[lookup, lookup])

    def test_tool_without_a_decorator(self):
        t = Tool("ping", lambda: "pong", effect="read")
        self.assertEqual((t.schema, t()), ({"type": "object", "properties": {}}, "pong"))


COOKIE = REPO / "target" / "debug" / "cookie"


@unittest.skipUnless(COOKIE.exists(), "build it first: cargo build --bin cookie")
class RealBinaryTest(unittest.TestCase):
    def test_a_bad_model_is_raised_and_the_process_keeps_serving(self):
        env = {k: v for k, v in os.environ.items() if k != "ENKEON_API_KEY"}
        old = dict(os.environ)
        os.environ.clear()
        os.environ.update(env)
        try:
            with Agent("nope:x", cookie_bin=str(COOKIE), tools=[lookup]) as agent:
                with self.assertRaisesRegex(CookieError, "nope"):
                    agent.run("hi")
                proc = agent._proc
                with self.assertRaisesRegex(CookieError, "nope"):
                    agent.run("again")
                self.assertIs(agent._proc, proc, "same process after an error")
        finally:
            os.environ.clear()
            os.environ.update(old)


if __name__ == "__main__":
    unittest.main()
