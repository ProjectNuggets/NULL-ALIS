#!/usr/bin/env python3
"""tau-bench Agent implementation backed by the nullalis gateway."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import traceback
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

import requests
from tau_bench.agents.base import Agent
from tau_bench.envs import get_env
from tau_bench.envs.base import Env
from tau_bench.envs.airline.tasks_test import TASKS as AIRLINE_TASKS
from tau_bench.run import display_metrics
from tau_bench.types import Action, EnvRunResult, RESPOND_ACTION_NAME, SolveResult

try:
    from .scorer import summarize, write_triage
    from .tool_mapper import catalog_for_prompt
except ImportError:
    from scorer import summarize, write_triage
    from tool_mapper import catalog_for_prompt


DEFAULT_CHAT_URL = "http://127.0.0.1:3000/api/v1/chat/stream"


class GatewayReply:
    def __init__(self, text: str, latency_ms: int, ttft_ms: Optional[int], events: list[dict[str, Any]]):
        self.text = text
        self.latency_ms = latency_ms
        self.ttft_ms = ttft_ms
        self.events = events


class NullalisAgent(Agent):
    def __init__(
        self,
        chat_url: str,
        token: str,
        user_id_base: int,
        increment_user_ids: bool,
        out_dir: Path,
        run_id: str,
        request_timeout: int = 180,
    ) -> None:
        self.chat_url = chat_url
        self.token = token
        self.user_id_base = user_id_base
        self.increment_user_ids = increment_user_ids
        self.out_dir = out_dir
        self.run_id = run_id
        self.request_timeout = request_timeout

    def solve(self, env: Env, task_index: Optional[int] = None, max_num_steps: int = 30) -> SolveResult:
        if task_index is None:
            task_index = env.task_index
        session_key = self._session_key(task_index)
        setup = self._setup_prompt(env, task_index)
        messages: list[dict[str, Any]] = []
        latency_values: list[int] = []
        ttft_values: list[int] = []
        parse_errors = 0
        unknown_actions = 0
        tool_calls = 0
        actual_actions: list[str] = []
        stopped_reason = "max_steps"
        messages.append({"role": "benchmark_setup", "content": setup})

        reset = env.reset(task_index=task_index)
        observation = reset.observation
        source = reset.info.source or "user"
        reward = 0.0
        final_info: dict[str, Any] = {}

        for step_idx in range(max_num_steps):
            prompt = self._action_prompt(source, observation)
            if step_idx == 0:
                prompt = f"{setup}\n\n{prompt}"
            gateway_reply = self._chat(prompt, session_key, task_index, f"step{step_idx}")
            latency_values.append(gateway_reply.latency_ms)
            if gateway_reply.ttft_ms is not None:
                ttft_values.append(gateway_reply.ttft_ms)

            action, parse_error, unknown_action = parse_action(gateway_reply.text, env.tools_map.keys())
            parse_errors += 1 if parse_error else 0
            unknown_actions += 1 if unknown_action else 0
            if action.name != RESPOND_ACTION_NAME:
                tool_calls += 1
                actual_actions.append(action.name)

            messages.append(
                {
                    "role": "assistant",
                    "content": gateway_reply.text,
                    "parsed_action": action.model_dump(),
                    "parse_error": parse_error,
                    "unknown_action": unknown_action,
                    "latency_ms": gateway_reply.latency_ms,
                    "ttft_ms": gateway_reply.ttft_ms,
                }
            )

            response = env.step(action)
            observation = response.observation
            source = response.info.source or action.name
            messages.append(
                {
                    "role": "environment",
                    "source": source,
                    "observation": observation,
                    "reward": response.reward,
                    "done": response.done,
                }
            )
            if response.done:
                reward = float(response.reward)
                stopped_reason = "done"
                if response.info.reward_info is not None:
                    final_info["reward_info"] = response.info.reward_info.model_dump()
                break

        expected_actions = [
            action.name for action in env.task.actions if action.name != RESPOND_ACTION_NAME
        ]
        final_info.update(
            {
                "session_key": session_key,
                "steps": sum(1 for message in messages if message.get("role") == "assistant"),
                "tool_calls": tool_calls,
                "actual_actions": actual_actions,
                "expected_actions": expected_actions,
                "parse_errors": parse_errors,
                "unknown_actions": unknown_actions,
                "latency_ms": sum(latency_values),
                "gateway_call_latencies_ms": latency_values,
                "ttft_ms": ttft_values,
                "stopped_reason": stopped_reason,
            }
        )
        return SolveResult(reward=reward, messages=messages, info=final_info, total_cost=None)

    def _setup_prompt(self, env: Env, task_index: int) -> str:
        return (
            f"You are the nullalis agent inside tau-bench Airline task {task_index}.\n"
            "You are an airline customer-support agent. The benchmark environment will execute exactly one action per reply.\n\n"
            "Reply with exactly one JSON object and no markdown:\n"
            '{"name":"tool_name_or_respond","arguments":{...}}\n\n'
            f"Use {RESPOND_ACTION_NAME} only to send a customer-visible message:\n"
            '{"name":"respond","arguments":{"content":"message to customer"}}\n\n'
            "Never invent tool results. Use the available tools when data or mutations are needed.\n\n"
            "AIRLINE POLICY WIKI:\n"
            f"{env.wiki}\n\n"
            "AIRLINE TOOL CATALOG:\n"
            f"{catalog_for_prompt(env.tools_info)}"
        )

    def _action_prompt(self, source: str, observation: str) -> str:
        return (
            f"Observation from {source}:\n{observation}\n\n"
            "Choose the next benchmark action. Reply with exactly one JSON object and no markdown."
        )

    def _session_key(self, task_index: int) -> str:
        user_id = self._user_id(task_index)
        return f"agent:zaki-bot:user:{user_id}:task:tau_airline_{self.run_id}_t{task_index}"

    def _user_id(self, task_index: int) -> int:
        if self.increment_user_ids:
            return self.user_id_base + task_index
        return self.user_id_base

    def _headers(self, task_index: int) -> dict[str, str]:
        if not self.token:
            raise RuntimeError("GATEWAY_TOKEN is required")
        return {
            "X-Internal-Token": self.token,
            "X-Zaki-User-Id": str(self._user_id(task_index)),
            "Content-Type": "application/json",
        }

    def _chat(self, message: str, session_key: str, task_index: int, label: str) -> GatewayReply:
        body = {"message": message, "session_key": session_key}
        started_ns = time.time_ns()
        events: list[dict[str, Any]] = []
        current: dict[str, Any] = {}
        trace_path = self.out_dir / f"task_{task_index:02d}_{label}.sse"
        with requests.post(
            self.chat_url,
            headers=self._headers(task_index),
            data=json.dumps(body),
            stream=True,
            timeout=self.request_timeout,
        ) as resp, trace_path.open("w") as trace:
            if resp.status_code == 401:
                raise RuntimeError("gateway returned 401; check GATEWAY_TOKEN")
            if resp.status_code not in (200, 201, 409):
                raise RuntimeError(f"gateway returned HTTP {resp.status_code}: {resp.text[:200]}")
            for raw_line in resp.iter_lines(decode_unicode=True):
                if raw_line is None:
                    continue
                received_ns = time.time_ns()
                line = raw_line.rstrip("\n")
                trace.write(f"{received_ns}\t{line}\n")
                if not line.strip():
                    if current:
                        events.append(current)
                        current = {}
                    continue
                if line.startswith("event:"):
                    current["event"] = line[len("event:") :].strip()
                    current.setdefault("received_ns", received_ns)
                elif line.startswith("data:"):
                    current["received_ns"] = received_ns
                    payload = line[len("data:") :].strip()
                    try:
                        current["data"] = json.loads(payload)
                    except json.JSONDecodeError:
                        current["data"] = payload
            if current:
                events.append(current)

        ended_ns = time.time_ns()
        reply = extract_reply_text(events)
        ttft_ns = first_final_token_ns(events)
        return GatewayReply(
            text=reply,
            latency_ms=(ended_ns - started_ns) // 1_000_000,
            ttft_ms=((ttft_ns - started_ns) // 1_000_000) if ttft_ns is not None else None,
            events=events,
        )


def extract_reply_text(events: list[dict[str, Any]]) -> str:
    parts: list[str] = []
    for event in events:
        data = event.get("data")
        if event.get("event") != "token" or not isinstance(data, dict):
            continue
        if data.get("stream_kind") and data.get("stream_kind") != "final_reply":
            continue
        delta = data.get("delta") or data.get("content") or ""
        if delta:
            parts.append(str(delta))
    if parts:
        return "".join(parts).strip()
    for event in events:
        data = event.get("data")
        if isinstance(data, dict) and data.get("content"):
            return str(data["content"]).strip()
    return ""


def first_final_token_ns(events: list[dict[str, Any]]) -> Optional[int]:
    for event in events:
        data = event.get("data")
        if event.get("event") != "token" or not isinstance(data, dict):
            continue
        if data.get("stream_kind") and data.get("stream_kind") != "final_reply":
            continue
        if data.get("delta") or data.get("content"):
            return int(event.get("received_ns", 0))
    return None


def parse_action(reply: str, valid_tool_names: Any) -> tuple[Action, bool, bool]:
    valid_tools = set(valid_tool_names)
    parse_error = False
    unknown_action = False
    obj = _parse_json_object(reply)
    if obj is None:
        parse_error = True
        return Action(name=RESPOND_ACTION_NAME, kwargs={"content": reply or "I need a moment to check that."}), parse_error, unknown_action

    name = obj.get("name") or obj.get("action") or obj.get("tool")
    args = obj.get("arguments", obj.get("kwargs", obj.get("parameters", {})))
    if not isinstance(name, str):
        parse_error = True
        name = RESPOND_ACTION_NAME
    if not isinstance(args, dict):
        parse_error = True
        args = {}
    if name == "final":
        name = RESPOND_ACTION_NAME
    if name not in valid_tools and name != RESPOND_ACTION_NAME:
        unknown_action = True
        return Action(name=RESPOND_ACTION_NAME, kwargs={"content": reply}), parse_error, unknown_action
    if name == RESPOND_ACTION_NAME and "content" not in args:
        args = {"content": str(args) if args else reply}
    return Action(name=name, kwargs=args), parse_error, unknown_action


def _parse_json_object(reply: str) -> Optional[dict[str, Any]]:
    text = reply.strip()
    if not text:
        return None
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if fenced:
        text = fenced.group(1)
    candidates = [text]
    first = text.find("{")
    last = text.rfind("}")
    if first != -1 and last != -1 and last > first:
        candidates.append(text[first : last + 1])
    for candidate in candidates:
        try:
            value = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    return None


def sanitize_error_text(text: str) -> str:
    redactions = [
        (r"org_[A-Za-z0-9_]+", "org_[redacted]"),
        (r"user_[A-Za-z0-9_]{12,}", "user_[redacted]"),
        (r"sk-[A-Za-z0-9_-]+", "sk-[redacted]"),
        (r"gsk_[A-Za-z0-9_-]+", "gsk_[redacted]"),
        (r"tgp_v1_[A-Za-z0-9_-]+", "tgp_v1_[redacted]"),
    ]
    sanitized = text
    for pattern, replacement in redactions:
        sanitized = re.sub(pattern, replacement, sanitized)
    return sanitized


def ensure_provider_key(provider: str) -> None:
    provider_env = {
        "openrouter": ("OPENROUTER_API_KEY", "openrouter"),
        "groq": ("GROQ_API_KEY", "groq"),
        "together_ai": ("TOGETHER_API_KEY", "together"),
    }
    if provider not in provider_env:
        return
    env_name, config_name = provider_env[provider]
    if os.environ.get(env_name):
        return
    config_path = Path.home() / ".nullalis" / "config.json"
    if not config_path.exists():
        return
    try:
        cfg = json.loads(config_path.read_text())
    except Exception:
        return
    providers = cfg.get("models", {}).get("providers", {})
    provider_config = providers.get(config_name)
    if isinstance(provider_config, dict) and provider_config.get("api_key"):
        os.environ[env_name] = str(provider_config["api_key"])


def selected_task_ids(args: argparse.Namespace) -> list[int]:
    if args.tasks:
        ids: list[int] = []
        for part in args.tasks.split(","):
            part = part.strip()
            if part:
                ids.append(int(part))
        return ids
    if args.smoke:
        return [0]
    end = len(AIRLINE_TASKS) if args.end_index == -1 else min(args.end_index, len(AIRLINE_TASKS))
    return list(range(args.start_index, end))


def append_results_row(path: Path, label: str, summary: dict[str, Any], description: str) -> None:
    header = ""
    if path.exists():
        header = path.read_text().splitlines()[0]
    use_v2 = "p50_ttft_ms" in header and "p95_ttft_ms" in header
    fields = [
        label,
        f"{summary['pass_rate']:.3f}",
        f"{summary['mean_tool_calls']:.2f}",
        f"{summary['mean_latency_ms']:.0f}",
    ]
    if use_v2:
        fields.extend([_fmt_optional(summary.get("p50_ttft_ms")), _fmt_optional(summary.get("p95_ttft_ms"))])
    fields.extend(["baseline", description])
    with path.open("a") as f:
        f.write("\t".join(fields) + "\n")


def _fmt_optional(value: Any) -> str:
    return "na" if value is None else f"{float(value):.0f}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tasks", default="", help="comma-separated task ids")
    parser.add_argument("--start-index", type=int, default=0)
    parser.add_argument("--end-index", type=int, default=-1)
    parser.add_argument("--max-steps", type=int, default=30)
    parser.add_argument("--smoke", action="store_true", help="run task 0 only")
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--append-results", action="store_true")
    parser.add_argument("--results-tsv", default=".spike/results.tsv")
    parser.add_argument("--label", default="iter22-tau-airline-baseline")
    parser.add_argument("--description", default="first tau-bench Airline run")
    parser.add_argument("--user-strategy", default=os.environ.get("TAU_USER_STRATEGY", "llm"))
    parser.add_argument("--user-model-provider", default=os.environ.get("TAU_USER_MODEL_PROVIDER", "groq"))
    parser.add_argument("--user-model", default=os.environ.get("TAU_USER_MODEL", "llama-3.3-70b-versatile"))
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    ensure_provider_key(args.user_model_provider)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    base_dir = Path(__file__).resolve().parents[1]
    out_dir = Path(args.out_dir) if args.out_dir else base_dir / "runs" / timestamp
    out_dir.mkdir(parents=True, exist_ok=True)
    run_id = f"{timestamp}_{uuid.uuid4().hex[:6]}"
    task_ids = selected_task_ids(args)

    agent = NullalisAgent(
        chat_url=os.environ.get("NULLALIS_CHAT_URL", DEFAULT_CHAT_URL),
        token=os.environ.get("GATEWAY_TOKEN", ""),
        user_id_base=int(os.environ.get("TAU_USER_ID_BASE", "1")),
        increment_user_ids=os.environ.get("TAU_INCREMENT_USER_IDS", "0") == "1",
        out_dir=out_dir,
        run_id=run_id,
    )

    manifest = {
        "timestamp": timestamp,
        "run_id": run_id,
        "env": "airline",
        "task_split": "test",
        "airline_task_count": len(AIRLINE_TASKS),
        "task_ids": task_ids,
        "user_strategy": args.user_strategy,
        "user_model_provider": args.user_model_provider,
        "user_model": args.user_model,
    }
    (out_dir / "task_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    results: list[EnvRunResult] = []
    for task_id in task_ids:
        if not args.quiet:
            print(f"Running tau-bench Airline task {task_id}", flush=True)
        try:
            env = get_env(
                "airline",
                user_strategy=args.user_strategy,
                user_model=args.user_model,
                user_provider=args.user_model_provider,
                task_split="test",
                task_index=task_id,
            )
            solve_result = agent.solve(env=env, task_index=task_id, max_num_steps=args.max_steps)
            result = EnvRunResult(
                task_id=task_id,
                reward=solve_result.reward,
                info=solve_result.info,
                traj=solve_result.messages,
                trial=0,
            )
        except Exception as exc:
            result = EnvRunResult(
                task_id=task_id,
                reward=0.0,
                info={
                    "error": sanitize_error_text(str(exc)),
                    "traceback": sanitize_error_text(traceback.format_exc()),
                },
                traj=[],
                trial=0,
            )
        results.append(result)
        (out_dir / "results.json").write_text(json.dumps([r.model_dump() for r in results], indent=2) + "\n")
        if not args.quiet:
            print(("PASS" if result.reward >= 1.0 - 1e-6 else "FAIL"), f"task_id={task_id}", result.info, flush=True)

    summary = summarize(results)
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    write_triage(results, summary, out_dir / "triage.md")

    if not args.quiet:
        display_metrics(results)
        print(f"Results: {out_dir / 'results.json'}", flush=True)
        print(f"Triage:  {out_dir / 'triage.md'}", flush=True)
        print(
            "summary "
            f"pass_rate={summary['pass_rate']:.3f} "
            f"mean_tool_calls={summary['mean_tool_calls']:.2f} "
            f"mean_latency_ms={summary['mean_latency_ms']:.0f} "
            f"p50_ttft_ms={_fmt_optional(summary.get('p50_ttft_ms'))} "
            f"p95_ttft_ms={_fmt_optional(summary.get('p95_ttft_ms'))}",
            flush=True,
        )

    if args.append_results:
        append_results_row(Path(args.results_tsv), args.label, summary, args.description)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
