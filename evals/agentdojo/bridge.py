"""Run AgentDojo tasks through the Cookie Agent Harness (via the Python client).

`CookiePipeline` is one AgentDojo pipeline element that does the whole agent
loop: it hands the task to `cookie serve`, runs AgentDojo's tools when the
harness calls them, and records every executed call in AgentDojo's message
format so its utility and security checks read a normal trace.

Two arms, same model, same system message, same tools:
  trust  each tool gets the effect and guards in TRUST_MAP
  off    every tool is `read` with no guards, so nothing is gated or asked
Both arms approve every request that reaches the approver: there is no person
in a benchmark. The trust arm's protection is therefore only what the
harness decides by itself (guards over where values came from).
"""

from __future__ import annotations

import itertools
import json
import re
import sys
from collections.abc import Sequence
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bindings" / "python" / "src"))

from agentdojo.agent_pipeline.agent_pipeline import load_system_message  # noqa: E402
from agentdojo.agent_pipeline.base_pipeline_element import BasePipelineElement  # noqa: E402
from agentdojo.agent_pipeline.errors import AbortAgentError  # noqa: E402
from agentdojo.agent_pipeline.tool_execution import tool_result_to_str  # noqa: E402
from agentdojo.functions_runtime import EmptyEnv, Env, FunctionCall, FunctionsRuntime  # noqa: E402
from agentdojo.types import (  # noqa: E402
    ChatAssistantMessage,
    ChatMessage,
    ChatSystemMessage,
    ChatToolResultMessage,
    ChatUserMessage,
    text_content_block_from_string,
)

from cookie_harness import Agent, CookieError, Tool  # noqa: E402

READ = ("read", [])

# (effect, guarded arguments) for every tool in AgentDojo v1.2.2's four suites.
# Anything that sends, shares or invites is `outbound`; anything that deletes,
# cancels, pays or books is `destroy`. Guards sit on the arguments that choose
# who receives, who is paid, or where data goes. Tools not named here are reads.
TRUST_MAP: dict[str, tuple[str, list[str]]] = {
    # workspace / travel: email
    "send_email": ("outbound", ["recipients", "cc", "bcc"]),
    "delete_email": ("destroy", []),
    # calendar: participants receive an invitation
    "create_calendar_event": ("outbound", ["participants"]),
    "add_calendar_event_participants": ("outbound", ["participants"]),
    "cancel_calendar_event": ("destroy", []),
    "reschedule_calendar_event": ("write", []),
    # cloud drive
    "create_file": ("write", []),
    "append_to_file": ("write", []),
    "delete_file": ("destroy", []),
    "share_file": ("outbound", ["email"]),
    # travel: a booking pays the venue named
    "reserve_hotel": ("destroy", ["hotel"]),
    "reserve_car_rental": ("destroy", ["company"]),
    "reserve_restaurant": ("destroy", ["restaurant"]),
    # banking
    "send_money": ("destroy", ["recipient"]),
    "schedule_transaction": ("destroy", ["recipient"]),
    "update_scheduled_transaction": ("destroy", ["recipient"]),
    "update_password": ("destroy", ["password"]),
    "update_user_info": ("write", []),
    # slack
    "send_direct_message": ("outbound", ["recipient"]),
    "send_channel_message": ("outbound", ["channel"]),
    "invite_user_to_slack": ("outbound", ["user", "user_email"]),
    "add_user_to_channel": ("write", ["user"]),
    "remove_user_from_slack": ("destroy", ["user"]),
    "post_webpage": ("outbound", ["url"]),
    "get_webpage": ("read", ["url"]),  # a fetched URL can carry data out
}

# The reads, named so a tool new to a suite version is noticed, not defaulted.
KNOWN_READS = {
    "get_unread_emails", "get_sent_emails", "get_received_emails", "get_draft_emails", "search_emails",
    "search_contacts_by_name", "search_contacts_by_email", "get_current_day", "search_calendar_events",
    "get_day_calendar_events", "search_files_by_filename", "get_file_by_id", "list_files", "search_files",
    "get_user_information", "get_all_hotels_in_city", "get_hotels_prices", "get_rating_reviews_for_hotels",
    "get_hotels_address", "get_all_restaurants_in_city", "get_cuisine_type_for_restaurants",
    "get_restaurants_address", "get_rating_reviews_for_restaurants", "get_dietary_restrictions_for_all_restaurants",
    "get_contact_information_for_restaurants", "get_price_for_restaurants", "check_restaurant_opening_hours",
    "get_all_car_rental_companies_in_city", "get_car_types_available", "get_rating_reviews_for_car_rental",
    "get_car_fuel_options", "get_car_rental_address", "get_car_price_per_day", "get_flight_information",
    "get_iban", "get_balance", "get_most_recent_transactions", "get_scheduled_transactions", "read_file",
    "get_user_info", "get_channels", "read_channel_messages", "read_inbox", "get_users_in_channel",
}

ARMS = ("trust", "off")

# Ends that are the agent failing the task (scored as a failed task), not the
# setup failing. Anything else stops the benchmark so it is seen.
AGENT_FAILURES = ("budget reached", "the model ran out of output tokens", "stopped a loop")


def effect_and_guard(name: str, arm: str) -> tuple[str, list[str]]:
    if arm == "off":
        return READ
    if name in TRUST_MAP:
        return TRUST_MAP[name]
    if name in KNOWN_READS:
        return READ
    raise KeyError(f"no effect chosen for AgentDojo tool `{name}`: add it to TRUST_MAP or KNOWN_READS")


def yes(_request) -> bool:
    return True


class SpendCapReached(Exception):
    """The benchmark's dollar cap is spent. Not an agent failure: it stops the run."""


class Spend:
    """Dollars spent by the whole benchmark, from the provider's own token counts.

    Every run appends one line to `ledger` (JSONL), so a rerun that continues
    from the logs also counts what earlier runs spent. `prices` are dollars per
    million tokens: {input, output, cache_read, cache_write}. The cap is checked
    before each run, so the total can pass it by at most one run. Tokens of a
    stream that failed mid-way are not reported by the harness and are missing
    here: check the provider's own meter too.
    """

    KEYS = {"input": "input_tokens", "output": "output_tokens",
            "cache_read": "cache_read_tokens", "cache_write": "cache_write_tokens"}

    def __init__(self, ledger: Path, prices: dict, cap: float):
        if set(prices) != set(self.KEYS):
            raise ValueError(f"prices need exactly {sorted(self.KEYS)}")
        self.ledger, self.prices, self.cap = Path(ledger), prices, cap
        self.total = 0.0
        if self.ledger.exists():
            with self.ledger.open() as f:
                self.total = sum(json.loads(line)["dollars"] for line in f if line.strip())

    def check(self) -> None:
        if self.total >= self.cap:
            raise SpendCapReached(f"spent ${self.total:.2f} of the ${self.cap:.2f} cap")

    def charge(self, label: str, usage: dict) -> None:
        dollars = sum(usage.get(field, 0) * self.prices[key] for key, field in self.KEYS.items()) / 1e6
        self.total += dollars
        self.ledger.parent.mkdir(parents=True, exist_ok=True)
        with self.ledger.open("a") as f:
            f.write(json.dumps({"run": label, **usage, "dollars": round(dollars, 6)}) + "\n")


class CookiePipeline(BasePipelineElement):
    def __init__(self, model: str, arm: str, cookie_bin: str | None = None, system_message: str | None = None,
                 spend: Spend | None = None):
        if arm not in ARMS:
            raise ValueError(f"arm must be one of {ARMS}")
        self.model = model
        self.arm = arm
        self.cookie_bin = cookie_bin
        self.spend = spend
        self.system_message = system_message if system_message is not None else load_system_message(None)
        # AgentDojo names the log directory after this, and the attack finds the
        # model's name in it (see register_model_name).
        self.name = f"cookie-{arm}-{model_token(model)}"

    def tools_for(self, runtime: FunctionsRuntime, env: Env, messages: list[ChatMessage]) -> list[Tool]:
        ids = itertools.count(1)
        tools = []
        for function in runtime.functions.values():
            effect, guard = effect_and_guard(function.name, self.arm)

            def call(_name=function.name, **kwargs):
                fc = FunctionCall(function=_name, args=kwargs, id=f"call_{next(ids)}")
                messages.append(ChatAssistantMessage(role="assistant", content=None, tool_calls=[fc]))
                result, error = runtime.run_function(env, _name, kwargs, raise_on_error=False)
                text = tool_result_to_str(result) if error is None else ""
                messages.append(ChatToolResultMessage(role="tool", content=[text_content_block_from_string(text)],
                                                      tool_call_id=fc.id, tool_call=fc, error=error))
                if error is not None:
                    raise RuntimeError(error)
                return text

            tools.append(Tool(function.name, call, effect=effect, description=function.description,
                              schema=function.parameters.model_json_schema(), guard=guard))
        return tools

    def query(self, query: str, runtime: FunctionsRuntime, env: Env = EmptyEnv(),
              messages: Sequence[ChatMessage] = [], extra_args: dict = {}):
        messages = [
            *messages,
            ChatSystemMessage(role="system", content=[text_content_block_from_string(self.system_message)]),
            ChatUserMessage(role="user", content=[text_content_block_from_string(query)]),
        ]
        if self.spend is not None:
            self.spend.check()
        agent = Agent(self.model, tools=self.tools_for(runtime, env, messages), instructions=self.system_message,
                      enkeon=False, approver=yes, cookie_bin=self.cookie_bin)
        usage: dict[str, int] = {}
        answer = ""
        try:
            for event in agent.stream(query):
                if event.get("type") == "usage":
                    for field, n in event["data"].items():
                        usage[field] = usage.get(field, 0) + n
                elif event.get("type") == "done":
                    answer = event["answer"]
        except CookieError as e:
            if str(e).startswith(AGENT_FAILURES):
                raise AbortAgentError(f"cookie: {e}", messages, env) from e
            raise
        finally:
            agent.close()
            if self.spend is not None:
                self.spend.charge(f"{self.name}: {query[:80]}", usage)
        messages.append(ChatAssistantMessage(role="assistant", content=[text_content_block_from_string(answer)], tool_calls=None))
        return query, runtime, env, messages, extra_args


def model_token(model: str) -> str:
    """`bedrock:eu.anthropic.claude-sonnet-4-6` -> `eu.anthropic.claude-sonnet-4-6`, safe for a path."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", model.split(":", 1)[-1])


def register_model_name(model: str, prose: str) -> None:
    """The important_instructions attack addresses the model by name and only
    knows models from its own list. Add this one (in place: the attack module
    holds the same dict)."""
    from agentdojo.models import MODEL_NAMES

    MODEL_NAMES[model_token(model)] = prose
