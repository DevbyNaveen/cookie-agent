"""AgentDojo through the Cookie Agent Harness, trust layer on vs off.

    python run.py --model anthropic:claude-sonnet-4-6 --suite banking --arm trust --arm off

For each arm and suite it runs the user tasks with no attack (utility), then
every user task x injection task under the attack (utility under attack, and
targeted attack success rate = mean of AgentDojo's `security_results`, which
is True when the injection's goal was carried out). Logs go under --logdir;
a rerun skips tasks already logged unless --force-rerun.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from agentdojo.attacks.attack_registry import load_attack
from agentdojo.benchmark import benchmark_suite_with_injections, benchmark_suite_without_injections
from agentdojo.logging import OutputLogger
from agentdojo.task_suite.load_suites import get_suite

from bridge import ARMS, CookiePipeline, Pace, Spend, register_model_name

SUITES = ("workspace", "travel", "banking", "slack")


def mean(results: dict) -> float | None:
    return sum(results.values()) / len(results) if results else None


def parse(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", required=True, help="cookie model id, provider:model (e.g. anthropic:claude-sonnet-4-6)")
    p.add_argument("--model-name", help="how the attack addresses the model (default: Claude for claude models; required otherwise)")
    p.add_argument("--suite", action="append", choices=SUITES, help="repeatable; default: all four")
    p.add_argument("--arm", action="append", choices=ARMS, help="repeatable; default: both")
    p.add_argument("--attack", default="important_instructions")
    p.add_argument("--benchmark-version", default="v1.2.2")
    p.add_argument("--user-task", action="append", help="repeatable, e.g. user_task_0; default: all")
    p.add_argument("--injection-task", action="append", help="repeatable, e.g. injection_task_0; default: all")
    p.add_argument("--logdir", type=Path, default=Path("runs"))
    p.add_argument("--cookie-bin", help="the cookie binary (else COOKIE_BIN, else cookie on PATH)")
    p.add_argument("--force-rerun", action="store_true")
    p.add_argument("--no-attack", action="store_true", help="utility only")
    p.add_argument("--max-dollars", type=float, help="stop the benchmark once this much is spent (needs --prices)")
    p.add_argument("--rpm", type=float, help="at most this many model calls a minute (the provider's quota)")
    p.add_argument("--prices", help="dollars per million tokens: input,output,cache_read,cache_write")
    args = p.parse_args(argv)
    if (args.max_dollars is None) != (args.prices is None):
        p.error("--max-dollars and --prices go together")
    if args.prices is not None:
        try:
            values = [float(v) for v in args.prices.split(",")]
        except ValueError:
            values = []
        if len(values) != 4:
            p.error("--prices needs four numbers: input,output,cache_read,cache_write")
        args.prices = dict(zip(("input", "output", "cache_read", "cache_write"), values))
    if args.model_name is None:
        if "claude" not in args.model.lower():
            p.error("--model-name is required for a model that is not Claude (e.g. --model-name GPT-4)")
        args.model_name = "Claude"
    return args


def main(argv=None) -> int:
    args = parse(argv)
    register_model_name(args.model, args.model_name)
    rows = []
    # One ledger for the whole benchmark, both arms, kept across reruns.
    spend = Spend(args.logdir / "spend.jsonl", args.prices, args.max_dollars) if args.prices else None
    pace = Pace(args.rpm) if args.rpm else None
    with OutputLogger(str(args.logdir)):
        for arm in args.arm or list(ARMS):
            pipeline = CookiePipeline(args.model, arm, cookie_bin=args.cookie_bin, spend=spend, pace=pace)
            for suite_name in args.suite or list(SUITES):
                suite = get_suite(args.benchmark_version, suite_name)
                clean = benchmark_suite_without_injections(
                    pipeline, suite, logdir=args.logdir, force_rerun=args.force_rerun,
                    user_tasks=args.user_task, benchmark_version=args.benchmark_version,
                )
                row = {"arm": arm, "suite": suite_name, "utility": mean(clean["utility_results"]),
                       "utility_under_attack": None, "targeted_asr": None, "tasks": len(clean["utility_results"]), "pairs": 0}
                if not args.no_attack:
                    attack = load_attack(args.attack, suite, pipeline)
                    attacked = benchmark_suite_with_injections(
                        pipeline, suite, attack, logdir=args.logdir, force_rerun=args.force_rerun,
                        user_tasks=args.user_task, injection_tasks=args.injection_task,
                        benchmark_version=args.benchmark_version,
                    )
                    row.update(utility_under_attack=mean(attacked["utility_results"]),
                               targeted_asr=mean(attacked["security_results"]),
                               pairs=len(attacked["security_results"]))
                rows.append(row)
    print(f"{'arm':6} {'suite':10} {'utility':>8} {'util/att':>9} {'ASR':>7} {'tasks':>6} {'pairs':>6}")
    pct = lambda v: "-" if v is None else f"{100 * v:.1f}%"  # noqa: E731
    for r in rows:
        print(f"{r['arm']:6} {r['suite']:10} {pct(r['utility']):>8} {pct(r['utility_under_attack']):>9} "
              f"{pct(r['targeted_asr']):>7} {r['tasks']:>6} {r['pairs']:>6}")
    args.logdir.mkdir(parents=True, exist_ok=True)
    out = args.logdir / f"results-{CookiePipeline(args.model, 'trust').name.removeprefix('cookie-trust-')}.json"
    out.write_text(json.dumps({"model": args.model, "attack": args.attack, "benchmark_version": args.benchmark_version,
                               "rows": rows}, indent=2))
    print(f"wrote {out}", file=sys.stderr)
    if spend is not None:
        print(f"spent ${spend.total:.2f} of ${spend.cap:.2f} (ledger {spend.ledger})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
