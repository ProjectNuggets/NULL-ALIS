#!/usr/bin/env python3
"""
nullalis multi-user burst load check for /api/v1/chat/stream.

Default intent:
- one request per distinct user (realistic burst profile)
- parse SSE until terminal done/error
- report p50/p95/p99 and wall-clock time
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import json
import statistics
from collections import Counter, defaultdict
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass


@dataclass
class RequestResult:
    ok: bool
    user_id: str
    request_id: int
    elapsed_ms: int
    reason: str
    status_code: int | None = None
    error_class: str | None = None
    error_detail: str | None = None
    error_body: str | None = None


def percentile(values: list[int], pct: float) -> int:
    if not values:
        return 0
    if len(values) == 1:
        return values[0]
    ordered = sorted(values)
    idx = int(round((pct / 100.0) * (len(ordered) - 1)))
    idx = max(0, min(idx, len(ordered) - 1))
    return ordered[idx]


def lane_from_session_key(session_key: str | None) -> str:
    if not session_key:
        return "none"
    marker = ":thread:"
    idx = session_key.rfind(marker)
    if idx >= 0:
        return "thread"
    parts = session_key.split(":")
    if not parts:
        return "unknown"
    tail = parts[-2] if len(parts) >= 2 else parts[-1]
    if tail in {"main", "task", "cron", "bench"}:
        return tail
    return parts[-1] if parts[-1] in {"main", "task", "cron", "bench"} else "custom"


def build_lane_strategy_session_key(strategy: str, user_id: str, request_id: int) -> tuple[str | None, str]:
    if strategy == "main_only":
        return f"agent:zaki-bot:user:{user_id}:main", "main"
    if strategy == "thread_per_request":
        return f"agent:zaki-bot:user:{user_id}:thread:req-{request_id}", "thread"
    if strategy == "task_per_request":
        return f"agent:zaki-bot:user:{user_id}:task:req-{request_id}", "task"
    if strategy == "cron_per_request":
        return f"agent:zaki-bot:user:{user_id}:cron:req-{request_id}", "cron"
    if strategy == "mixed_real":
        bucket = request_id % 20
        if bucket < 16:
            return f"agent:zaki-bot:user:{user_id}:thread:mix-{request_id}", "thread"
        if bucket < 19:
            return f"agent:zaki-bot:user:{user_id}:task:mix-{request_id}", "task"
        return f"agent:zaki-bot:user:{user_id}:cron:mix-{request_id}", "cron"
    raise ValueError(f"unsupported lane strategy: {strategy}")


def compact_detail(raw: str | None, *, limit: int = 240) -> str | None:
    if not raw:
        return None
    text = " ".join(raw.split())
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."


def extract_sse_error_detail(payload: str | None) -> str | None:
    if not payload:
        return None
    text = payload.strip()
    if not text:
        return None
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            code = obj.get("code")
            message = obj.get("message")
            if isinstance(code, str) and isinstance(message, str):
                return f"{code}: {message}"
            if isinstance(code, str):
                return code
            if isinstance(message, str):
                return message
    except Exception:
        pass
    return compact_detail(text)


def fetch_diagnostics(*, url: str, token: str, timeout_secs: int) -> tuple[dict | None, str | None]:
    req = urllib.request.Request(
        url=url,
        method="GET",
        headers={
            "X-Internal-Token": token,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout_secs) as resp:
            if resp.getcode() < 200 or resp.getcode() >= 300:
                return None, f"http_status:{resp.getcode()}"
            data = resp.read().decode("utf-8", errors="replace")
            return json.loads(data), None
    except urllib.error.HTTPError as err:
        detail = None
        try:
            detail = compact_detail(err.read().decode("utf-8", errors="replace"))
        except Exception:
            detail = None
        suffix = f" body={detail}" if detail else ""
        return None, f"http_error:{err.code}{suffix}"
    except Exception as err:
        return None, f"{err.__class__.__name__}:{compact_detail(str(err), limit=120) or ''}"


def run_probe_series(
    *,
    url: str,
    token: str,
    timeout_secs: int,
    message: str,
    user_id: str,
    session_key: str | None,
    count: int,
    interval_ms: int,
    request_id_offset: int,
) -> list[RequestResult]:
    results: list[RequestResult] = []
    for idx in range(count):
        results.append(
            run_one(
                url=url,
                token=token,
                timeout_secs=timeout_secs,
                message=message,
                user_id=user_id,
                request_id=request_id_offset + idx,
                session_key=session_key,
            )
        )
        if idx + 1 < count and interval_ms > 0:
            time.sleep(interval_ms / 1000.0)
    return results


def summarize_probe_results(results: list[RequestResult]) -> dict:
    success = [r for r in results if r.ok]
    failures = [r for r in results if not r.ok]
    latencies = [r.elapsed_ms for r in success]
    error_reasons: Counter[str] = Counter()
    for row in failures:
        error_reasons[row.reason] += 1
    return {
        "count": len(results),
        "success": len(success),
        "errors": len(failures),
        "latency_ms": {
            "p50": percentile(latencies, 50),
            "p95": percentile(latencies, 95),
            "p99": percentile(latencies, 99),
            "mean": int(statistics.mean(latencies)) if latencies else 0,
            "min": min(latencies) if latencies else 0,
            "max": max(latencies) if latencies else 0,
        },
        "error_reasons": dict(sorted(error_reasons.items())),
    }


def run_one(
    *,
    url: str,
    token: str,
    timeout_secs: int,
    message: str,
    user_id: str,
    request_id: int,
    session_key: str | None,
) -> RequestResult:
    started = time.time()
    body_obj = {"message": message}
    if session_key:
        body_obj["session_key"] = session_key
    body = json.dumps(body_obj).encode("utf-8")
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

    try:
        with urllib.request.urlopen(req, timeout=timeout_secs) as resp:
            status = resp.getcode()
            if status < 200 or status >= 300:
                elapsed_ms = int((time.time() - started) * 1000)
                return RequestResult(
                    False,
                    user_id,
                    request_id,
                    elapsed_ms,
                    "http_status",
                    status,
                    "HTTPStatus",
                    f"non_2xx_status:{status}",
                )

            saw_done = False
            saw_error = False
            current_event: str | None = None
            current_data: list[str] = []
            first_error_payload: str | None = None
            for raw in resp:
                line = raw.decode("utf-8", errors="replace").strip()
                if not line:
                    if current_event == "error":
                        saw_error = True
                        if first_error_payload is None and current_data:
                            first_error_payload = "\n".join(current_data)
                    if current_event == "done":
                        saw_done = True
                        break
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
            if saw_done and not saw_error:
                return RequestResult(True, user_id, request_id, elapsed_ms, "ok", status)
            if saw_done and saw_error:
                sse_detail = extract_sse_error_detail(first_error_payload)
                return RequestResult(
                    False,
                    user_id,
                    request_id,
                    elapsed_ms,
                    "sse_error_done",
                    status,
                    "SSE",
                    sse_detail or "received_done_after_error_event",
                    compact_detail(first_error_payload, limit=1000),
                )
            return RequestResult(
                False,
                user_id,
                request_id,
                elapsed_ms,
                "stream_no_done",
                status,
                "SSE",
                "stream_closed_without_terminal_done",
            )
    except urllib.error.HTTPError as err:
        elapsed_ms = int((time.time() - started) * 1000)
        error_body: str | None = None
        try:
            error_body = compact_detail(err.read().decode("utf-8", errors="replace"), limit=1000)
        except Exception:
            error_body = None
        error_detail = error_body
        if error_body:
            try:
                payload = json.loads(error_body)
                if isinstance(payload, dict):
                    if isinstance(payload.get("error"), str):
                        error_detail = payload["error"]
                    elif isinstance(payload.get("message"), str):
                        error_detail = payload["message"]
            except Exception:
                pass
        return RequestResult(
            False,
            user_id,
            request_id,
            elapsed_ms,
            "http_error",
            err.code,
            err.__class__.__name__,
            compact_detail(error_detail),
            error_body,
        )
    except TimeoutError as err:
        elapsed_ms = int((time.time() - started) * 1000)
        return RequestResult(
            False,
            user_id,
            request_id,
            elapsed_ms,
            "timeout",
            None,
            err.__class__.__name__,
            compact_detail(str(err)),
        )
    except urllib.error.URLError as err:
        elapsed_ms = int((time.time() - started) * 1000)
        reason = err.reason
        reason_class = reason.__class__.__name__ if reason is not None else err.__class__.__name__
        return RequestResult(
            False,
            user_id,
            request_id,
            elapsed_ms,
            "url_error",
            None,
            reason_class,
            compact_detail(str(reason)),
        )
    except Exception as err:
        elapsed_ms = int((time.time() - started) * 1000)
        return RequestResult(
            False,
            user_id,
            request_id,
            elapsed_ms,
            "exception",
            None,
            err.__class__.__name__,
            compact_detail(str(err)),
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Run nullalis burst load against /api/v1/chat/stream")
    parser.add_argument("--url", default="http://127.0.0.1:3000/api/v1/chat/stream")
    parser.add_argument("--token", required=True, help="X-Internal-Token value")
    parser.add_argument("--mode", choices=["multi-user", "single-user"], default="multi-user")
    parser.add_argument("--users", type=int, default=20, help="Distinct users to include")
    parser.add_argument("--requests", type=int, default=0, help="Total requests; 0 means users count")
    parser.add_argument("--workers", type=int, default=0, help="Thread workers; 0 means requests count")
    parser.add_argument("--timeout-secs", type=int, default=240)
    parser.add_argument("--message", default="health check")
    parser.add_argument("--run-label", default="", help="Optional run label included in JSON output")
    parser.add_argument(
        "--capture-diagnostics",
        action="store_true",
        help="Capture /internal/diagnostics snapshots before and after the run",
    )
    parser.add_argument(
        "--diagnostics-url",
        default="http://127.0.0.1:3000/internal/diagnostics",
        help="Diagnostics endpoint used when --capture-diagnostics is set",
    )
    parser.add_argument(
        "--failure-samples-limit",
        type=int,
        default=20,
        help="Max failed-request sample rows to include in JSON output",
    )
    parser.add_argument(
        "--lane-strategy",
        choices=[
            "template",
            "main_only",
            "thread_per_request",
            "task_per_request",
            "cron_per_request",
            "mixed_real",
        ],
        default="template",
        help=(
            "Session lane strategy. 'template' uses --session-key-template exactly. "
            "All other modes derive deterministic session_key values."
        ),
    )
    parser.add_argument(
        "--session-key-template",
        default="agent:zaki-bot:user:{user_id}:main",
        help=(
            "Session key template. Default targets each user's main lane. "
            "Use empty string to omit session_key, or include {request_id} for isolated-per-request lanes. "
            "Only used when --lane-strategy=template."
        ),
    )
    parser.add_argument(
        "--isolation-probe-user-id",
        default="",
        help="Optional unaffected cohort probe user id. When set with --isolation-probe-count>0, records baseline and under-load probe latencies.",
    )
    parser.add_argument(
        "--isolation-probe-count",
        type=int,
        default=0,
        help="Number of probe requests to send for baseline and under-load phases.",
    )
    parser.add_argument(
        "--isolation-probe-interval-ms",
        type=int,
        default=250,
        help="Delay between probe requests in each phase.",
    )
    parser.add_argument(
        "--isolation-probe-session-key-template",
        default="agent:zaki-bot:user:{user_id}:main",
        help="Session key template for isolation probes; set empty string to omit session_key.",
    )
    parser.add_argument(
        "--isolation-probe-message",
        default="isolation probe",
        help="Message payload used by isolation probes.",
    )
    parser.add_argument(
        "--isolation-gate-p95-max-degradation-pct",
        type=float,
        default=15.0,
        help="Maximum allowed unaffected cohort p95 degradation percentage.",
    )
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON summary")
    args = parser.parse_args()

    total_requests = args.requests if args.requests > 0 else args.users
    workers = args.workers if args.workers > 0 else total_requests
    workers = max(1, workers)
    run_started_utc = datetime.datetime.now(datetime.timezone.utc).isoformat()

    user_ids: list[str] = []
    if args.mode == "single-user":
        user_ids = ["1"] * total_requests
    else:
        # Round-robin requests across users 1..N.
        user_count = max(1, args.users)
        for i in range(total_requests):
            user_ids.append(str((i % user_count) + 1))

    isolation_probe_enabled = bool(args.isolation_probe_user_id) and args.isolation_probe_count > 0
    isolation_probe_session_key = None
    if isolation_probe_enabled and args.isolation_probe_session_key_template:
        isolation_probe_session_key = args.isolation_probe_session_key_template.format(
            user_id=args.isolation_probe_user_id
        )
    isolation_probe_baseline_results: list[RequestResult] = []
    isolation_probe_under_load_results: list[RequestResult] = []

    if isolation_probe_enabled:
        isolation_probe_baseline_results = run_probe_series(
            url=args.url,
            token=args.token,
            timeout_secs=args.timeout_secs,
            message=args.isolation_probe_message,
            user_id=args.isolation_probe_user_id,
            session_key=isolation_probe_session_key,
            count=args.isolation_probe_count,
            interval_ms=args.isolation_probe_interval_ms,
            request_id_offset=1_000_000,
        )

    started = time.time()
    results: list[RequestResult] = []
    diagnostics_before = None
    diagnostics_before_error = None
    if args.capture_diagnostics:
        diagnostics_before, diagnostics_before_error = fetch_diagnostics(
            url=args.diagnostics_url, token=args.token, timeout_secs=args.timeout_secs
        )

    isolation_probe_done = threading.Event()

    def run_under_load_probe() -> None:
        nonlocal isolation_probe_under_load_results
        isolation_probe_under_load_results = run_probe_series(
            url=args.url,
            token=args.token,
            timeout_secs=args.timeout_secs,
            message=args.isolation_probe_message,
            user_id=args.isolation_probe_user_id,
            session_key=isolation_probe_session_key,
            count=args.isolation_probe_count,
            interval_ms=args.isolation_probe_interval_ms,
            request_id_offset=2_000_000,
        )
        isolation_probe_done.set()

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = []
        request_plan: list[tuple[str, str | None, str]] = []
        isolation_probe_thread: threading.Thread | None = None
        if isolation_probe_enabled:
            isolation_probe_thread = threading.Thread(
                target=run_under_load_probe,
                name="isolation-probe-under-load",
                daemon=True,
            )
            isolation_probe_thread.start()
        for req_id, user_id in enumerate(user_ids):
            session_key: str | None = None
            lane = "none"
            if args.lane_strategy == "template":
                if args.session_key_template:
                    session_key = args.session_key_template.format(user_id=user_id, request_id=req_id)
                lane = lane_from_session_key(session_key)
            else:
                session_key, lane = build_lane_strategy_session_key(args.lane_strategy, user_id, req_id)
            request_plan.append((user_id, session_key, lane))
            futures.append(
                pool.submit(
                    run_one,
                    url=args.url,
                    token=args.token,
                    timeout_secs=args.timeout_secs,
                    message=args.message,
                    user_id=user_id,
                    request_id=req_id,
                    session_key=session_key,
                )
            )

        for f in concurrent.futures.as_completed(futures):
            results.append(f.result())
        if isolation_probe_thread is not None and not isolation_probe_done.is_set():
            isolation_probe_thread.join()

    wall_ms = int((time.time() - started) * 1000)
    run_finished_utc = datetime.datetime.now(datetime.timezone.utc).isoformat()
    success = [r for r in results if r.ok]
    failures = [r for r in results if not r.ok]
    latencies = [r.elapsed_ms for r in success]
    diagnostics_after = None
    diagnostics_after_error = None
    if args.capture_diagnostics:
        diagnostics_after, diagnostics_after_error = fetch_diagnostics(
            url=args.diagnostics_url, token=args.token, timeout_secs=args.timeout_secs
        )

    distinct_users = len(set(user_ids))
    distinct_session_keys = len({sk for _, sk, _ in request_plan if sk})
    lane_counts = Counter([lane for _, _, lane in request_plan])
    per_user_session_counts: defaultdict[str, Counter[str]] = defaultdict(Counter)
    for user_id, session_key, _ in request_plan:
        key = session_key if session_key is not None else "<none>"
        per_user_session_counts[user_id][key] += 1
    all_user_session_counts = [count for sessions in per_user_session_counts.values() for count in sessions.values()]
    sessions_per_user = [len(sessions) for sessions in per_user_session_counts.values()]
    same_user_contention_profile = {
        "max_requests_on_single_user_session": max(all_user_session_counts) if all_user_session_counts else 0,
        "users_with_multi_sessions": sum(1 for v in sessions_per_user if v > 1),
        "mean_sessions_per_user": round(statistics.mean(sessions_per_user), 2) if sessions_per_user else 0.0,
        "mean_requests_per_user_session": round(statistics.mean(all_user_session_counts), 2) if all_user_session_counts else 0.0,
    }

    summary = {
        "run_label": args.run_label,
        "run_started_utc": run_started_utc,
        "run_finished_utc": run_finished_utc,
        "mode": args.mode,
        "lane_strategy": args.lane_strategy,
        "requested_users": args.users,
        "distinct_users": distinct_users,
        "distinct_session_keys": distinct_session_keys,
        "requests": total_requests,
        "workers": workers,
        "success": len(success),
        "errors": len(failures),
        "wall_ms": wall_ms,
        "latency_ms": {
            "p50": percentile(latencies, 50),
            "p95": percentile(latencies, 95),
            "p99": percentile(latencies, 99),
            "mean": int(statistics.mean(latencies)) if latencies else 0,
            "min": min(latencies) if latencies else 0,
            "max": max(latencies) if latencies else 0,
        },
        "error_reasons": {},
        "error_details": {
            "status_codes": {},
            "exception_classes": {},
            "detail_counts": {},
        },
        "failure_samples": [],
        "lane_counts": dict(sorted(lane_counts.items())),
        "same_user_contention_profile": same_user_contention_profile,
    }
    if isolation_probe_enabled:
        baseline_probe = summarize_probe_results(isolation_probe_baseline_results)
        under_load_probe = summarize_probe_results(isolation_probe_under_load_results)
        baseline_p95 = baseline_probe["latency_ms"]["p95"]
        under_load_p95 = under_load_probe["latency_ms"]["p95"]
        degradation_pct_p95 = None
        gate_pass = False
        gate_status = "inconclusive"
        if baseline_probe["errors"] == 0 and under_load_probe["errors"] == 0 and baseline_p95 > 0:
            degradation_pct_p95 = round(((under_load_p95 - baseline_p95) * 100.0) / baseline_p95, 2)
            gate_pass = degradation_pct_p95 <= args.isolation_gate_p95_max_degradation_pct
            gate_status = "pass" if gate_pass else "fail"
        isolation_probe_overlap_with_load_users = args.isolation_probe_user_id in set(user_ids)
        summary["isolation_probe"] = {
            "enabled": True,
            "user_id": args.isolation_probe_user_id,
            "session_key": isolation_probe_session_key,
            "count_per_phase": args.isolation_probe_count,
            "interval_ms": args.isolation_probe_interval_ms,
            "gate_max_p95_degradation_pct": args.isolation_gate_p95_max_degradation_pct,
            "overlap_with_load_users": isolation_probe_overlap_with_load_users,
            "baseline": baseline_probe,
            "under_load": under_load_probe,
            "degradation_pct_p95": degradation_pct_p95,
            "gate_pass": gate_pass,
            "gate_status": gate_status,
        }
    else:
        summary["isolation_probe"] = {
            "enabled": False,
        }
    status_code_counts: Counter[str] = Counter()
    exception_class_counts: Counter[str] = Counter()
    detail_counts: Counter[str] = Counter()
    for err in failures:
        summary["error_reasons"][err.reason] = summary["error_reasons"].get(err.reason, 0) + 1
        if err.status_code is not None:
            status_code_counts[str(err.status_code)] += 1
        if err.error_class:
            exception_class_counts[err.error_class] += 1
        if err.error_detail:
            detail_counts[err.error_detail] += 1
        if len(summary["failure_samples"]) < args.failure_samples_limit:
            summary["failure_samples"].append(
                {
                    "request_id": err.request_id,
                    "user_id": err.user_id,
                    "reason": err.reason,
                    "status_code": err.status_code,
                    "error_class": err.error_class,
                    "error_detail": err.error_detail,
                    "error_body": err.error_body,
                    "elapsed_ms": err.elapsed_ms,
                }
            )
    summary["error_details"]["status_codes"] = dict(sorted(status_code_counts.items()))
    summary["error_details"]["exception_classes"] = dict(sorted(exception_class_counts.items()))
    summary["error_details"]["detail_counts"] = dict(sorted(detail_counts.items(), key=lambda item: (-item[1], item[0])))
    if args.capture_diagnostics:
        summary["diagnostics"] = {
            "url": args.diagnostics_url,
            "before_error": diagnostics_before_error,
            "after_error": diagnostics_after_error,
            "before": diagnostics_before,
            "after": diagnostics_after,
        }

    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(
            f"[load-burst] mode={summary['mode']} requested_users={summary['requested_users']} "
            f"distinct_users={summary['distinct_users']} distinct_session_keys={summary['distinct_session_keys']} "
            f"requests={summary['requests']} workers={summary['workers']}"
        )
        print(f"[load-burst] lane_strategy={summary['lane_strategy']} lane_counts={summary['lane_counts']}")
        print(
            f"[load-burst] success={summary['success']} errors={summary['errors']} "
            f"wall_ms={summary['wall_ms']}"
        )
        lat = summary["latency_ms"]
        print(
            "[load-burst] latency_ms "
            f"p50={lat['p50']} p95={lat['p95']} p99={lat['p99']} "
            f"mean={lat['mean']} min={lat['min']} max={lat['max']}"
        )
        if summary["error_reasons"]:
            print(f"[load-burst] errors_by_reason={summary['error_reasons']}")
        if summary["error_details"]["status_codes"]:
            print(f"[load-burst] errors_by_status={summary['error_details']['status_codes']}")
        if summary["error_details"]["exception_classes"]:
            print(f"[load-burst] errors_by_exception={summary['error_details']['exception_classes']}")
        if summary["error_details"]["detail_counts"]:
            top_detail = next(iter(summary["error_details"]["detail_counts"].items()))
            print(f"[load-burst] top_error_detail={top_detail[0]!r} count={top_detail[1]}")
        if args.capture_diagnostics:
            print(
                "[load-burst] diagnostics_capture "
                f"before_error={diagnostics_before_error} after_error={diagnostics_after_error}"
            )
        if summary["isolation_probe"]["enabled"]:
            probe = summary["isolation_probe"]
            print(
                "[load-burst] isolation_probe "
                f"user_id={probe['user_id']} overlap_with_load_users={probe['overlap_with_load_users']} "
                f"baseline_p95={probe['baseline']['latency_ms']['p95']} "
                f"under_load_p95={probe['under_load']['latency_ms']['p95']} "
                f"degradation_pct_p95={probe['degradation_pct_p95']} gate_pass={probe['gate_pass']}"
            )

    # CI-friendly: non-zero when any request failed.
    return 0 if len(failures) == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
