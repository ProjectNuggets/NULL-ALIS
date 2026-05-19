#!/usr/bin/env python3
"""Official-score passthrough and failure triage for tau-bench Airline runs."""

from __future__ import annotations

import math
from collections import Counter, defaultdict
from pathlib import Path
from statistics import mean
from typing import Any, Iterable

LOCOMO_CATEGORIES = [
    "agentic_execution",
    "error_recovery_depth",
    "memory_recall",
    "multi_turn_coherence",
    "persona_fidelity",
    "proactive_research",
    "professional_synthesis",
    "safety_refusal",
    "self_awareness",
    "subagent_dispatch",
    "tool_chaining",
    "tool_discipline",
]


def _percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    idx = max(0, math.ceil(pct * len(ordered)) - 1)
    return ordered[min(idx, len(ordered) - 1)]


def summarize(results: Iterable[Any]) -> dict[str, Any]:
    """Summarize tau-bench EnvRunResult values without changing rewards."""

    rows = list(results)
    rewards = [float(getattr(row, "reward", 0.0)) for row in rows]
    infos = [getattr(row, "info", {}) or {} for row in rows]
    task_latencies = [float(info.get("latency_ms", 0.0)) for info in infos]
    tool_calls = [int(info.get("tool_calls", 0)) for info in infos]
    ttft_values: list[float] = []
    for info in infos:
        ttft_values.extend(float(v) for v in info.get("ttft_ms", []) if v is not None)

    return {
        "task_count": len(rows),
        "passed": sum(1 for reward in rewards if reward >= 1.0 - 1e-6),
        "pass_rate": (mean(rewards) if rewards else 0.0),
        "mean_tool_calls": (mean(tool_calls) if tool_calls else 0.0),
        "mean_latency_ms": (mean(task_latencies) if task_latencies else 0.0),
        "p50_ttft_ms": _percentile(ttft_values, 0.50),
        "p95_ttft_ms": _percentile(ttft_values, 0.95),
    }


def _reward_info(info: dict[str, Any]) -> dict[str, Any]:
    reward_info = info.get("reward_info") or {}
    if isinstance(reward_info, dict):
        return reward_info
    return {}


def classify_failure(result: Any) -> str:
    """Map failures into the same 12 top-level categories as LoCoMo triage."""

    info = getattr(result, "info", {}) or {}
    if float(getattr(result, "reward", 0.0)) >= 1.0 - 1e-6:
        return "passed"
    if info.get("error"):
        return "error_recovery_depth"
    if info.get("parse_errors", 0) or info.get("unknown_actions", 0):
        return "tool_discipline"
    if info.get("stopped_reason") == "max_steps":
        return "multi_turn_coherence"
    reward_info = _reward_info(info)
    if reward_info.get("r_outputs") == 0.0:
        return "professional_synthesis"
    expected = [str(name) for name in info.get("expected_actions", [])]
    actual = [str(name) for name in info.get("actual_actions", [])]
    if expected and not actual:
        return "tool_discipline"
    if any("search" in name or "get_" in name for name in expected):
        return "proactive_research"
    if len(actual) < len(expected):
        return "tool_chaining"
    if any("passenger" in name or "user" in name for name in expected):
        return "persona_fidelity"
    if reward_info.get("r_actions") == 0.0:
        return "agentic_execution"
    return "agentic_execution"


def write_triage(results: list[Any], summary: dict[str, Any], out_path: Path) -> None:
    counts: Counter[str] = Counter()
    by_category: dict[str, list[Any]] = defaultdict(list)
    for result in results:
        category = classify_failure(result)
        if category == "passed":
            continue
        counts[category] += 1
        by_category[category].append(result)

    lines = [
        "# tau-bench Airline triage",
        "",
        "Official tau-bench reward is the scoring source of truth. This file only buckets failures for nullalis iteration planning.",
        "",
        "## Summary",
        "",
        f"- tasks: {summary['task_count']}",
        f"- pass_rate: {summary['pass_rate']:.3f}",
        f"- mean_tool_calls: {summary['mean_tool_calls']:.2f}",
        f"- mean_latency_ms: {summary['mean_latency_ms']:.0f}",
        f"- p50_ttft_ms: {_fmt_optional(summary.get('p50_ttft_ms'))}",
        f"- p95_ttft_ms: {_fmt_optional(summary.get('p95_ttft_ms'))}",
        "",
        "## 12-category breakdown",
        "",
        "| Category | Failures |",
        "|---|---:|",
    ]
    for category in LOCOMO_CATEGORIES:
        lines.append(f"| {category} | {counts.get(category, 0)} |")

    lines.extend(["", "## Failed tasks", ""])
    for category in LOCOMO_CATEGORIES:
        failed = by_category.get(category, [])
        if not failed:
            continue
        lines.extend([f"### {category}", ""])
        for result in failed:
            info = getattr(result, "info", {}) or {}
            expected = ",".join(info.get("expected_actions", [])) or "none"
            actual = ",".join(info.get("actual_actions", [])) or "none"
            error = _error_kind(info.get("error", ""))
            lines.append(
                f"- task {getattr(result, 'task_id', '?')}: "
                f"steps={info.get('steps', 0)} tool_calls={info.get('tool_calls', 0)} "
                f"parse_errors={info.get('parse_errors', 0)} stopped={info.get('stopped_reason', '')} "
                f"expected=[{expected}] actual=[{actual}] error={error}"
            )
        lines.append("")

    out_path.write_text("\n".join(lines) + "\n")


def _fmt_optional(value: Any) -> str:
    return "na" if value is None else f"{float(value):.0f}"


def _error_kind(error: Any) -> str:
    if not error:
        return "none"
    text = str(error)
    if "RateLimitError" in text:
        return "RateLimitError"
    if "APIError" in text:
        return "APIError"
    first = text.split(":", 1)[0].strip()
    return first[:80] if first else "error"
