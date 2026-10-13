"""Dry tests of the AgentDojo bridge: no model, a scripted fake `cookie serve`."""

import contextlib
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path

from agentdojo.agent_pipeline.errors import AbortAgentError
from agentdojo.attacks.attack_registry import load_attack
from agentdojo.functions_runtime import FunctionsRuntime
from agentdojo.task_suite.load_suites import get_suite

import run
from bridge import KNOWN_READS, TRUST_MAP, CookiePipeline, Pace, Spend, SpendCapReached, effect_and_guard, register_model_name
from cookie_harness import CookieError

FAKE = Path(__file__).resolve().parents[2] / "bindings" / "python" / "tests" / "fake_serve.py"
SUITES = {name: get_suite("v1.2.2", name) for name in run.SUITES}


def fake_bin(script):
    """A `cookie` that plays `script` (see fake_serve.py) and logs what it reads."""
    d = tempfile.mkdtemp()
    with open(os.path.join(d, "script.json"), "w") as f:
        json.dump(script, f)
    log = os.path.join(d, "log.jsonl")
    open(log, "w").close()
    path = os.path.join(d, "cookie")
    with open(path, "w") as f:
        f.write(f'#!/bin/sh\nFAKE_SCRIPT="{d}/script.json" FAKE_LOG="{log}" exec "{sys.executable}" "{FAKE}" "$@"\n')
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    return path, log, d


def received(log, kind):
    with open(log) as f:
        return [m for m in map(json.loads, filter(str.strip, f)) if m.get("type") == kind]


class MappingTest(unittest.TestCase):
    def test_every_tool_in_every_suite_has_an_effect_and_guards_name_real_arguments(self):
        seen = set()
        for suite in SUITES.values():
            for function in suite.tools:
                seen.add(function.name)
                effect, guard = effect_and_guard(function.name, "trust")
                self.assertIn(effect, ("read", "write", "outbound", "destroy"))
                params = function.parameters.model_json_schema().get("properties", {})
                for arg in guard:
                    self.assertIn(arg, params, f"{function.name} has no argument {arg}")
        self.assertEqual(set(TRUST_MAP) | KNOWN_READS, seen, "no stale or missing names")
        self.assertFalse(set(TRUST_MAP) & KNOWN_READS)

    def test_what_sends_pays_or_deletes_is_gated(self):
        for name in ["send_email", "share_file", "send_money", "schedule_transaction", "post_webpage",
                     "send_direct_message", "invite_user_to_slack", "delete_file", "reserve_hotel"]:
            effect, guard = effect_and_guard(name, "trust")
            self.assertIn(effect, ("outbound", "destroy"), name)
        self.assertEqual(effect_and_guard("send_money", "trust"), ("destroy", ["recipient"]))
        self.assertEqual(effect_and_guard("send_email", "trust"), ("outbound", ["recipients", "cc", "bcc"]))
        self.assertEqual(effect_and_guard("get_webpage", "trust"), ("read", ["url"]))

    def test_the_off_arm_is_all_reads_with_no_guards(self):
        for suite in SUITES.values():
            for function in suite.tools:
                self.assertEqual(effect_and_guard(function.name, "off"), ("read", []))

    def test_a_tool_new_to_the_suite_is_refused_not_defaulted(self):
        with self.assertRaisesRegex(KeyError, "wire_funds"):
            effect_and_guard("wire_funds", "trust")


class PipelineTest(unittest.TestCase):
    def setUp(self):
        self.suite = SUITES["banking"]
        self.task = self.suite.get_user_task_by_id("user_task_0")

    def pipeline(self, script, arm="trust"):
        path, log, d = fake_bin(script)
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        return CookiePipeline("anthropic:claude-sonnet-4-6", arm, cookie_bin=path), log

    def query(self, pipeline):
        runtime = FunctionsRuntime(self.suite.tools)
        env = self.task.init_environment(self.suite.load_and_inject_default_environment({}))
        return env, pipeline.query(self.task.PROMPT, runtime, env)

    def test_a_call_runs_against_the_environment_and_lands_in_the_trace(self):
        args = {"recipient": "UK12345678901234567890", "amount": 98.7, "subject": "bill", "date": "2022-01-01"}
        pipeline, log = self.pipeline([
            {"read": "run"},
            {"write": {"type": "tool_call", "id": "t1", "name": "send_money", "args": args}},
            {"read": "tool_result"},
            {"write": {"type": "done", "answer": "Paid."}},
        ])
        env, (_, _, env_out, messages, _) = self.query(pipeline)
        [run_msg] = received(log, "run")
        declared = {t["name"]: t for t in run_msg["tools"]}
        self.assertEqual((declared["send_money"]["effect"], declared["send_money"]["guard"]), ("destroy", ["recipient"]))
        self.assertEqual(run_msg["enkeon"], False)
        self.assertEqual(run_msg["instructions"], pipeline.system_message)
        self.assertEqual(env_out.bank_account.transactions[-1].recipient, args["recipient"])
        self.assertEqual([m["role"] for m in messages], ["system", "user", "assistant", "tool", "assistant"])
        self.assertEqual((messages[2]["tool_calls"][0].function, messages[2]["tool_calls"][0].args), ("send_money", args))
        self.assertEqual(messages[-1]["content"][0]["content"], "Paid.")
        [result] = received(log, "tool_result")
        self.assertFalse(result["is_error"])

    def test_the_off_arm_declares_every_tool_a_read(self):
        pipeline, log = self.pipeline([{"read": "run"}, {"write": {"type": "done", "answer": "ok"}}], arm="off")
        self.query(pipeline)
        tools = received(log, "run")[0]["tools"]
        self.assertTrue(tools and all(t["effect"] == "read" and t["guard"] == [] for t in tools))

    def test_a_failed_call_is_an_error_to_the_model_and_in_the_trace(self):
        pipeline, log = self.pipeline([
            {"read": "run"},
            {"write": {"type": "tool_call", "id": "t1", "name": "send_money", "args": {"recipient": "x"}}},
            {"read": "tool_result"},
            {"write": {"type": "done", "answer": "Could not pay."}},
        ])
        _, (_, _, _, messages, _) = self.query(pipeline)
        [result] = received(log, "tool_result")
        self.assertTrue(result["is_error"])
        self.assertTrue(messages[3]["error"])

    def test_the_agent_running_out_of_budget_fails_the_task_and_a_setup_error_stops_everything(self):
        pipeline, _ = self.pipeline([{"read": "run"}, {"write": {"type": "error", "message": "budget reached: 20 model calls (limit 20)"}}])
        with self.assertRaises(AbortAgentError):
            self.query(pipeline)
        pipeline, _ = self.pipeline([{"read": "run"}, {"write": {"type": "error", "message": "unknown provider `nope`"}}])
        with self.assertRaisesRegex(CookieError, "unknown provider"):
            self.query(pipeline)

    def test_the_attack_addresses_the_model_by_the_registered_name(self):
        pipeline = CookiePipeline("bedrock:eu.anthropic.claude-sonnet-4-6", "trust")
        register_model_name(pipeline.model, "Claude")
        self.assertEqual(load_attack("important_instructions", self.suite, pipeline).model_name, "Claude")


class SpendTest(unittest.TestCase):
    PRICES = {"input": 3.3, "output": 16.5, "cache_read": 0.33, "cache_write": 4.125}

    def setUp(self):
        self.suite = SUITES["banking"]
        self.task = self.suite.get_user_task_by_id("user_task_0")
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d, ignore_errors=True)

    def query(self, pipeline):
        runtime = FunctionsRuntime(self.suite.tools)
        env = self.task.init_environment(self.suite.load_and_inject_default_environment({}))
        return pipeline.query(self.task.PROMPT, runtime, env)

    def test_every_model_call_is_charged_and_the_cap_stops_the_next_run_before_it_starts(self):
        usage = {"input_tokens": 1_000_000, "output_tokens": 100_000, "cache_read_tokens": 0, "cache_write_tokens": 0}
        path, log, d = fake_bin([
            {"read": "run"},
            {"write": {"type": "event", "event": {"type": "usage", "data": usage}}},
            {"write": {"type": "event", "event": {"type": "usage", "data": usage}}},
            {"write": {"type": "done", "answer": "ok"}},
        ])
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        spend = Spend(Path(self.d) / "spend.jsonl", self.PRICES, cap=9.0)
        pipeline = CookiePipeline("anthropic:claude-sonnet-4-6", "trust", cookie_bin=path, spend=spend)
        self.query(pipeline)
        self.assertAlmostEqual(spend.total, 2 * (3.3 + 1.65))
        self.assertEqual(len(received(log, "run")), 1)
        with self.assertRaises(SpendCapReached):
            self.query(pipeline)
        self.assertEqual(len(received(log, "run")), 1, "a run past the cap must not reach the model")
        # A rerun reads the ledger back, so it does not start from zero.
        self.assertAlmostEqual(Spend(Path(self.d) / "spend.jsonl", self.PRICES, cap=9.0).total, spend.total)

    def test_a_run_that_fails_is_still_charged_for_what_it_used(self):
        path, _, d = fake_bin([
            {"read": "run"},
            {"write": {"type": "event", "event": {"type": "usage", "data": {"input_tokens": 1_000_000, "output_tokens": 0}}}},
            {"write": {"type": "error", "message": "budget reached: 25 model calls (limit 25)"}},
        ])
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        spend = Spend(Path(self.d) / "spend.jsonl", self.PRICES, cap=100.0)
        with self.assertRaises(AbortAgentError):
            self.query(CookiePipeline("anthropic:claude-sonnet-4-6", "trust", cookie_bin=path, spend=spend))
        self.assertAlmostEqual(spend.total, 3.3)

    def test_prices_and_cap_go_together(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            run.parse(["--model", "anthropic:claude-sonnet-4-6", "--max-dollars", "60"])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            run.parse(["--model", "anthropic:claude-sonnet-4-6", "--max-dollars", "60", "--prices", "1,2,3"])
        args = run.parse(["--model", "anthropic:claude-sonnet-4-6", "--max-dollars", "60", "--prices", "3.3,16.5,0.33,4.125"])
        self.assertEqual(args.prices, self.PRICES)


class PaceTest(unittest.TestCase):
    def test_calls_are_spaced_to_the_rate_and_a_slow_caller_waits_for_nothing(self):
        now, slept = [100.0], []
        pace = Pace(10, clock=lambda: now[0], sleep=lambda s: (slept.append(s), now.__setitem__(0, now[0] + s)))
        pace.wait()
        pace.wait()
        now[0] += 2.0
        pace.wait()
        self.assertEqual([round(s, 6) for s in slept], [6.0, 4.0])
        now[0] += 30.0
        pace.wait()
        self.assertEqual(len(slept), 2)

    def test_the_run_and_every_tool_result_are_paced(self):
        suite = SUITES["banking"]
        task = suite.get_user_task_by_id("user_task_0")
        path, _, d = fake_bin([
            {"read": "run"},
            {"write": {"type": "tool_call", "id": "t1", "name": "get_balance", "args": {}}},
            {"read": "tool_result"},
            {"write": {"type": "done", "answer": "ok"}},
        ])
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        waits = []
        pace = Pace(10)
        pace.wait = lambda: waits.append(1)
        pipeline = CookiePipeline("anthropic:claude-sonnet-4-6", "trust", cookie_bin=path, pace=pace)
        env = task.init_environment(suite.load_and_inject_default_environment({}))
        pipeline.query(task.PROMPT, FunctionsRuntime(suite.tools), env)
        self.assertEqual(len(waits), 2)


class EndToEndTest(unittest.TestCase):
    def test_run_py_scores_both_arms_on_one_task_pair(self):
        path, _, d = fake_bin([{"read": "run"}, {"write": {"type": "done", "answer": "Nothing to do."}}])
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        logdir = Path(d) / "runs"
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = run.main(["--model", "anthropic:claude-sonnet-4-6", "--suite", "banking", "--user-task", "user_task_0",
                             "--injection-task", "injection_task_0", "--logdir", str(logdir), "--cookie-bin", path])
        self.assertEqual(code, 0)
        rows = json.loads((logdir / "results-claude-sonnet-4-6.json").read_text())["rows"]
        self.assertEqual([(r["arm"], r["tasks"], r["pairs"]) for r in rows], [("trust", 1, 1), ("off", 1, 1)])
        # An agent that does nothing is useless and never attacked successfully.
        self.assertTrue(all(r["utility"] == 0 and r["targeted_asr"] == 0 for r in rows))

    def test_a_model_that_is_not_claude_needs_its_name(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            run.parse(["--model", "openai:gpt-5"])
        self.assertEqual(run.parse(["--model", "openai:gpt-5", "--model-name", "GPT-4"]).model_name, "GPT-4")


if __name__ == "__main__":
    unittest.main()
