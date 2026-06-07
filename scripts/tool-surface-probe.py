#!/usr/bin/env python3
"""
Run live Nullalis agent turns and print provider-bound tool/context facts.

This is an operator probe, not a deterministic test: it requires a running
gateway, a valid internal token, and whatever provider keys the local config
uses. It intentionally prints sanitized diagnostics only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


def compact(text: str | None, limit: int = 300) -> str | None:
    if not text:
        return None
    one_line = " ".join(text.split())
    if len(one_line) <= limit:
        return one_line
    return one_line[: limit - 3] + "..."


def session_ref(session_key: str) -> str:
    return hashlib.sha256(session_key.encode("utf-8")).hexdigest()[:16]


def request_json(url: str, *, token: str, user_id: str, timeout: int) -> dict[str, Any]:
    req = urllib.request.Request(
        url=url,
        method="GET",
        headers={
            "X-Internal-Token": token,
            "X-Zaki-User-Id": user_id,
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
        return json.loads(raw)


def post_chat_stream(
    url: str,
    *,
    token: str,
    user_id: str,
    session_key: str,
    message: str,
    timeout: int,
) -> dict[str, Any]:
    started = time.time()
    body = json.dumps({"message": message, "session_key": session_key}).encode("utf-8")
    req = urllib.request.Request(
        url=url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-Internal-Token": token,
            "X-Zaki-User-Id": user_id,
        },
    )

    events: list[dict[str, Any]] = []
    called_tools: list[str] = []
    failed_tools: list[str] = []
    saw_done = False
    saw_error = False
    response_cache_hit = False
    first_token_ms: int | None = None
    first_tool_ms: int | None = None
    tool_start_events = 0
    tool_result_events = 0
    reply_parts: list[str] = []
    current_event: str | None = None
    current_data: list[str] = []

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.getcode()
            for raw_line in resp:
                elapsed_ms = int((time.time() - started) * 1000)
                if elapsed_ms > timeout * 1000:
                    raise TimeoutError(f"stream exceeded timeout_secs={timeout}")
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line:
                    if current_event:
                        payload_text = "\n".join(current_data)
                        payload: dict[str, Any] = {}
                        if payload_text:
                            try:
                                decoded = json.loads(payload_text)
                                if isinstance(decoded, dict):
                                    payload = decoded
                            except json.JSONDecodeError:
                                payload = {"raw": compact(payload_text)}
                        events.append({"event": current_event, "payload": payload})
                        if current_event == "token":
                            delta = payload.get("delta") or payload.get("content")
                            if isinstance(delta, str) and delta:
                                reply_parts.append(delta)
                            if first_token_ms is None:
                                first_token_ms = elapsed_ms
                        if current_event == "progress":
                            if payload.get("label") == "Using cached response":
                                response_cache_hit = True
                            tool = payload.get("tool")
                            if isinstance(tool, str) and tool:
                                if first_tool_ms is None:
                                    first_tool_ms = elapsed_ms
                                if tool not in called_tools:
                                    called_tools.append(tool)
                                if payload.get("state") == "error" and tool not in failed_tools:
                                    failed_tools.append(tool)
                        if current_event == "tool_start":
                            tool_start_events += 1
                            tool = payload.get("tool")
                            if isinstance(tool, str) and tool:
                                if first_tool_ms is None:
                                    first_tool_ms = elapsed_ms
                                if tool not in called_tools:
                                    called_tools.append(tool)
                        if current_event == "tool_result":
                            tool_result_events += 1
                            tool = payload.get("tool")
                            if isinstance(tool, str) and tool:
                                if tool not in called_tools:
                                    called_tools.append(tool)
                                if payload.get("success") is False and tool not in failed_tools:
                                    failed_tools.append(tool)
                        if current_event == "done":
                            saw_done = True
                            break
                        if current_event == "error":
                            saw_error = True
                    current_event = None
                    current_data.clear()
                    continue
                if line.startswith("event:"):
                    current_event = line.split(":", 1)[1].strip()
                    continue
                if line.startswith("data:"):
                    current_data.append(line.split(":", 1)[1].strip())
                    continue

            elapsed_ms = int((time.time() - started) * 1000)
            return {
                "ok": saw_done and not saw_error,
                "http_status": status,
                "elapsed_ms": elapsed_ms,
                "first_token_ms": first_token_ms,
                "first_tool_ms": first_tool_ms,
                "saw_done": saw_done,
                "saw_error": saw_error,
                "response_cache_hit": response_cache_hit,
                "called_tools": called_tools,
                "failed_tools": failed_tools,
                "tool_start_events": tool_start_events,
                "tool_result_events": tool_result_events,
                "reply_preview": compact("".join(reply_parts), 1200),
                "event_counts": event_counts(events),
            }
    except urllib.error.HTTPError as err:
        detail = None
        try:
            detail = err.read().decode("utf-8", errors="replace")
        except Exception:
            pass
        return {
            "ok": False,
            "http_status": err.code,
            "elapsed_ms": int((time.time() - started) * 1000),
            "error": f"http_error:{err.code}",
            "detail": compact(detail),
        }
    except Exception as err:
        return {
            "ok": False,
            "elapsed_ms": int((time.time() - started) * 1000),
            "error": err.__class__.__name__,
            "detail": compact(str(err)),
        }


def event_counts(events: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for event in events:
        name = str(event.get("event") or "unknown")
        counts[name] = counts.get(name, 0) + 1
    return dict(sorted(counts.items()))


def nested(obj: dict[str, Any], *keys: str) -> Any:
    current: Any = obj
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def summarize_context(ctx: dict[str, Any]) -> dict[str, Any]:
    report = ctx.get("report") if isinstance(ctx.get("report"), dict) else {}
    prompt_shape = ctx.get("prompt_shape")
    if not isinstance(prompt_shape, dict):
        prompt_shape = report.get("prompt_shape") if isinstance(report, dict) else {}
    if not isinstance(prompt_shape, dict):
        prompt_shape = {}
    tool_surface = prompt_shape.get("tool_surface") if isinstance(prompt_shape.get("tool_surface"), dict) else {}
    provider_shape = prompt_shape.get("provider") if isinstance(prompt_shape.get("provider"), dict) else {}
    last_turn = ctx.get("last_turn") if isinstance(ctx.get("last_turn"), dict) else report.get("last_turn", {})
    provider_usage = ctx.get("provider_usage_last_turn")
    if not isinstance(provider_usage, dict):
        provider_usage = report.get("provider_usage_last_turn") if isinstance(report, dict) else {}
    if not isinstance(provider_usage, dict):
        provider_usage = {}

    xml_prose_bytes = int(tool_surface.get("xml_tool_catalog_bytes") or 0) + int(tool_surface.get("prompt_tool_catalog_bytes") or 0)
    return {
        "provider": ctx.get("model_provider") or report.get("model_provider"),
        "model": ctx.get("model") or report.get("model"),
        "pressure_token_source": ctx.get("pressure_token_source") or provider_shape.get("pressure_token_source"),
        "provider_prompt_tokens": ctx.get("provider_prompt_tokens") or provider_usage.get("prompt_tokens"),
        "provider_cached_prompt_tokens": ctx.get("provider_cached_prompt_tokens") or provider_usage.get("cached_prompt_tokens"),
        "cache_hit_percent": provider_usage.get("cache_hit_percent") or nested(ctx, "cache", "last_cache_hit_percent"),
        "pressure_percent": ctx.get("pressure_percent") or ctx.get("context_pressure_percent"),
        "tool_mode": nested(last_turn, "tool_mode") if isinstance(last_turn, dict) else None,
        "tool_diagnostics": {
            "native_tools_sent": nested(last_turn, "native_tools_sent") if isinstance(last_turn, dict) else None,
            "tool_choice": nested(last_turn, "tool_choice") if isinstance(last_turn, dict) else None,
            "provider_finish_reason": nested(last_turn, "provider_finish_reason") if isinstance(last_turn, dict) else None,
            "native_tool_call_count": nested(last_turn, "native_tool_call_count") if isinstance(last_turn, dict) else None,
            "xml_fallback_call_count": nested(last_turn, "xml_fallback_call_count") if isinstance(last_turn, dict) else None,
            "xml_fallback_reason": nested(last_turn, "xml_fallback_reason") if isinstance(last_turn, dict) else None,
            "stream_tool_call_chunks": nested(last_turn, "stream_tool_call_chunks") if isinstance(last_turn, dict) else None,
            "tool_call_ids_present": nested(last_turn, "tool_call_ids_present") if isinstance(last_turn, dict) else None,
        },
        "tool_surface": {
            "mode": tool_surface.get("mode"),
            "native_strict_canary": tool_surface.get("native_strict_canary"),
            "provider_supports_native_tools": tool_surface.get("provider_supports_native_tools"),
            "native_tool_count": tool_surface.get("native_tool_count"),
            "native_schema_bytes": tool_surface.get("native_tool_schema_bytes"),
            "xml_prose_bytes": xml_prose_bytes,
            "xml_tool_catalog_present": tool_surface.get("xml_tool_catalog_present"),
            "prompt_tool_catalog_present": tool_surface.get("prompt_tool_catalog_present"),
            "xml_fallback_protocol_present": tool_surface.get("xml_fallback_protocol_present"),
            "largest_tool_schemas": tool_surface.get("largest_tool_schemas") or [],
        },
    }


def scenario_messages(name: str) -> list[str]:
    if name == "no-tool":
        return ["Reply with one concise sentence: hello from the live probe."]
    if name == "schedule":
        return ["List scheduled jobs with limit 25 offset 0, then summarize total count, shown count, and next offset."]
    if name == "cron":
        return ["List cron jobs with limit 25 offset 0, then summarize total count, shown count, and next offset."]
    if name == "combined":
        return ["List scheduled jobs limit 25 offset 0 and cron jobs limit 25 offset 0 in one turn. Do not repeat the same inventory page."]
    if name == "memory":
        return [
            "Remember this exact operator preference for the current session: context probes should print native/XML ratio.",
            "Recall the operator preference you just stored and answer in one sentence.",
        ]
    if name == "todo":
        return [
            "Create a user-visible todo list titled Probe checklist with two items: verify native tool diagnostics, verify context pressure.",
            "Mark item 1 complete without restating the list id if there is exactly one current todo list, then show the current todo list.",
        ]
    if name == "task-plan":
        return [
            "Make an internal task plan, then list scheduled jobs limit 25 offset 0, recall any memory about tool diagnostics, and finish with a concise summary. Do not create a todo list unless explicitly needed by the user."
        ]
    if name == "multi-tool":
        return ["In one turn, list scheduled jobs limit 25 offset 0 and recall memory about native tool diagnostics, then summarize both."]
    if name == "error-recovery":
        return ["Try to update todo item 1 as complete without a list id. If the tool reports ambiguity or missing state, recover by listing current todos and explaining the exact next call needed."]
    raise ValueError(f"unsupported scenario: {name}")


def default_session_key(user_id: str) -> str:
    return f"agent:zaki-bot:user:{user_id}:thread:tool-surface-probe-{time.time_ns()}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Live tool-surface/context probe for a running Nullalis gateway")
    parser.add_argument("--base-url", default=os.environ.get("NULLALIS_BASE_URL", "http://127.0.0.1:3000"))
    parser.add_argument("--token", default=os.environ.get("NULLALIS_INTERNAL_TOKEN") or os.environ.get("INTERNAL_TOKEN"))
    parser.add_argument("--user-id", default=os.environ.get("ZAKI_USER_ID", "1"))
    parser.add_argument("--session-key", default="")
    parser.add_argument(
        "--scenario",
        choices=["no-tool", "schedule", "cron", "combined", "memory", "todo", "task-plan", "multi-tool", "error-recovery"],
        default="schedule",
    )
    parser.add_argument("--message", action="append", default=[], help="Override scenario prompt; repeat for multi-turn probes")
    parser.add_argument("--timeout-secs", type=int, default=240)
    parser.add_argument("--compact", action="store_true", help="Emit compact JSON lines instead of pretty JSON")
    args = parser.parse_args()

    if not args.token:
        print("tool-surface-probe: --token or NULLALIS_INTERNAL_TOKEN is required", file=sys.stderr)
        return 2

    base = args.base_url.rstrip("/")
    chat_url = f"{base}/api/v1/chat/stream"
    messages = args.message if args.message else scenario_messages(args.scenario)
    session_key = args.session_key or default_session_key(args.user_id)
    encoded_key = urllib.parse.quote(session_key, safe="")
    context_url = f"{base}/api/v1/users/{urllib.parse.quote(args.user_id, safe='')}/sessions/{encoded_key}/context"

    rows: list[dict[str, Any]] = []
    for index, message in enumerate(messages, start=1):
        stream = post_chat_stream(
            chat_url,
            token=args.token,
            user_id=args.user_id,
            session_key=session_key,
            message=message,
            timeout=args.timeout_secs,
        )
        context_summary: dict[str, Any] | None = None
        context_error: str | None = None
        try:
            context_summary = summarize_context(
                request_json(context_url, token=args.token, user_id=args.user_id, timeout=args.timeout_secs)
            )
        except Exception as err:
            context_error = f"{err.__class__.__name__}:{compact(str(err), limit=160)}"

        rows.append(
            {
                "turn": index,
                "session_ref": session_ref(session_key),
                "stream": stream,
                "context": context_summary,
                "context_error": context_error,
            }
        )

    if args.compact:
        for row in rows:
            print(json.dumps(row, sort_keys=True, separators=(",", ":")))
    else:
        print(json.dumps(rows, indent=2, sort_keys=True))
    return 0 if all(row["stream"].get("ok") for row in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
