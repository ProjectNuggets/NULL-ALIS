#!/usr/bin/env python3
"""
LoCoMo benchmark adapter for nullalis.

Loads a LoCoMo conversation into a fresh nullalis session via the gateway's
/api/v1/chat/stream SSE endpoint, then probes recall by asking each QA
question and capturing the agent's reply. Scores via simple exact-match +
substring containment as a first cut; LLM-judge scoring is a follow-up.

Usage:
  python run_bench.py --sample 0 --max-sessions 3 --max-qa 5     # smoke
  python run_bench.py --sample 0 --max-sessions 27 --max-qa 199  # full conv 0
  python run_bench.py --all                                       # all 10 conversations

Environment:
  GATEWAY_URL          default http://127.0.0.1:3000
  GATEWAY_TOKEN        required (X-Internal-Token)
  USER_ID              default 1
  LOCOMO_DATA          default ../locomo/data/locomo10.json
  OUT_DIR              default ./runs/<timestamp>
"""
import argparse
import json
import os
import re
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

import requests

GATEWAY_URL = os.environ.get("GATEWAY_URL", "http://127.0.0.1:3000")
GATEWAY_TOKEN = os.environ.get("GATEWAY_TOKEN", "")
USER_ID = int(os.environ.get("USER_ID", "1"))
DEFAULT_DATA = Path(__file__).resolve().parent.parent / "locomo" / "data" / "locomo10.json"
LOCOMO_DATA = Path(os.environ.get("LOCOMO_DATA", str(DEFAULT_DATA)))

CHAT_PATH = "/api/v1/chat/stream"

# Session key shape mandated by gateway: agent:<bot>:user:<id>:<lane>
def session_key_for(run_id: str) -> str:
    # Use main lane (only one accepted besides thread:/task:/cron: prefixes per
    # gateway error). Different run IDs go on different sessions via the
    # bench-suffix trick: we use task:<run_id> which is allowed.
    return f"agent:zaki-bot:user:{USER_ID}:task:locomo_{run_id}"


def headers() -> dict[str, str]:
    if not GATEWAY_TOKEN:
        sys.exit("ERROR: set GATEWAY_TOKEN env var to the gateway internal token")
    return {
        "X-Internal-Token": GATEWAY_TOKEN,
        "X-Zaki-User-Id": str(USER_ID),
        "Content-Type": "application/json",
    }


def parse_sse_events(stream: requests.Response) -> list[dict[str, Any]]:
    """Parse SSE response into a list of {event, data} dicts."""
    events: list[dict[str, Any]] = []
    current: dict[str, Any] = {}
    for raw_line in stream.iter_lines(decode_unicode=True):
        if raw_line is None:
            continue
        line = raw_line.strip()
        if not line:
            if current:
                events.append(current)
                current = {}
            continue
        if line.startswith("event:"):
            current["event"] = line[len("event:") :].strip()
        elif line.startswith("data:"):
            try:
                current["data"] = json.loads(line[len("data:") :].strip())
            except json.JSONDecodeError:
                current["data"] = line[len("data:") :].strip()
    if current:
        events.append(current)
    return events


def extract_reply_text(events: list[dict[str, Any]]) -> str:
    """Extract the final reply text from SSE events.

    nullalis gateway emits the final user-facing reply as `event: token`
    with `data={delta:"...", content:"...", seq:N, stream_kind:"final_reply"}`.
    Verified live via curl probe 2026-05-09.
    """
    final_reply: list[str] = []
    for ev in events:
        et = ev.get("event")
        d = ev.get("data") or {}
        if not isinstance(d, dict):
            continue
        if et == "token":
            # Only count tokens marked stream_kind=final_reply (skip
            # progress/thinking tokens that may use the same event).
            if d.get("stream_kind") and d.get("stream_kind") != "final_reply":
                continue
            delta = d.get("delta") or d.get("content") or ""
            if delta:
                final_reply.append(delta)
    return "".join(final_reply).strip()


def chat_send(message: str, sk: str, max_retries: int = 30) -> str:
    """POST one user turn to the gateway, return the assistant reply.

    Handles:
      - HTTP 200 + SSE stream (normal path)
      - HTTP 409 Conflict + SSE error body (ownership_lock_conflict — wait+retry)
      - HTTP 401 (fail loud — bad token)
      - HTTP 429/503 (transient — backoff)
    """
    body = {"message": message, "session_key": sk}
    backoff = 3.0
    for attempt in range(max_retries):
        with requests.post(
            f"{GATEWAY_URL}{CHAT_PATH}",
            headers=headers(),
            data=json.dumps(body),
            stream=True,
            timeout=180,
        ) as resp:
            if resp.status_code == 401:
                sys.exit("ERROR: 401 unauthorized — check GATEWAY_TOKEN")
            if resp.status_code in (200, 201, 409):
                events = parse_sse_events(resp)
            elif resp.status_code in (429, 503):
                time.sleep(backoff)
                backoff = min(backoff * 1.5, 15.0)
                continue
            else:
                raise RuntimeError(
                    f"transport error {resp.status_code}: {resp.text[:200]}"
                )

        # Look for ownership_lock_conflict in SSE body (regardless of HTTP status)
        lock_wait = None
        for ev in events:
            d = ev.get("data") or {}
            if isinstance(d, dict) and d.get("code") == "ownership_lock_conflict":
                lock_wait = max(d.get("retry_after_ms", 2000), 2000) / 1000.0
                # Also extract lease_until if present so we can sleep long enough
                lease = d.get("lease_until_s")
                if lease:
                    now = time.time()
                    until = float(lease) - now + 1.0
                    if until > lock_wait:
                        lock_wait = min(until, 90.0)
                break

        if lock_wait is not None:
            print(f"      [lock conflict; sleeping {lock_wait:.1f}s, attempt {attempt+1}/{max_retries}]", flush=True)
            time.sleep(lock_wait)
            continue

        reply = extract_reply_text(events)
        return reply

    raise RuntimeError(f"chat_send: gave up after {max_retries} retries on lock")


def load_conversation_into_session(conv: dict[str, Any], sk: str, max_sessions: int):
    """Feed each LoCoMo session as a single combined message into nullalis.

    LoCoMo each session = 18 dialog turns between Caroline and Melanie. We
    package each session as ONE user message containing the full session
    transcript prefixed with the date. This is a compromise: feeding turn-
    by-turn (more authentic) costs ~20× more turns/calls. Session-as-message
    still triggers V1.14's wiki extraction pipeline + memory storage.
    """
    speaker_a = conv.get("speaker_a", "PersonA")
    speaker_b = conv.get("speaker_b", "PersonB")
    sessions = sorted(
        [k for k in conv.keys() if k.startswith("session_") and "date" not in k],
        key=lambda x: int(x.split("_")[1]),
    )[:max_sessions]

    print(f"  loading {len(sessions)} sessions for {speaker_a} ↔ {speaker_b}", flush=True)
    for i, sess_key in enumerate(sessions):
        sess_turns = conv[sess_key]
        date_key = f"{sess_key}_date_time"
        date_val = conv.get(date_key, "")
        lines = [f"# Session {i+1} of {len(sessions)} — {date_val}"]
        for t in sess_turns:
            sp = t.get("speaker", "?")
            txt = t.get("text", "")
            lines.append(f"{sp}: {txt}")
        body = "\n".join(lines)
        # Prefix tells the agent this is historical context, not a current request
        msg = (
            f"[Loading historical conversation — please acknowledge briefly with 'noted'. "
            f"This is context for future questions about {speaker_a} and {speaker_b}.]\n\n"
            f"{body}"
        )
        try:
            reply = chat_send(msg, sk)
            print(f"    session_{i+1}: ack={reply[:60]!r}", flush=True)
        except Exception as e:
            print(f"    session_{i+1}: FAILED — {e}", flush=True)


def probe_qa(qa_pairs: list[dict[str, Any]], sk: str, max_qa: int) -> list[dict[str, Any]]:
    """Run the QA probes against the loaded session. Capture replies."""
    results = []
    for i, qa in enumerate(qa_pairs[:max_qa]):
        question = qa.get("question", "")
        answer = qa.get("answer", "")
        category = qa.get("category", "?")
        evidence = qa.get("evidence", [])
        try:
            reply = chat_send(question, sk)
        except Exception as e:
            reply = f"[ERROR: {e}]"
        results.append(
            {
                "qa_id": i,
                "category": category,
                "question": question,
                "ground_truth": answer,
                "reply": reply,
                "evidence": evidence,
            }
        )
        print(f"    qa_{i} cat={category}: {question[:60]!r} → {reply[:80]!r}", flush=True)
    return results


def simple_score(qa_result: dict[str, Any]) -> dict[str, Any]:
    """First-cut scoring: substring containment + token overlap.

    Per LoCoMo paper, formal scoring uses LLM-judge (GPT-4 prompted to judge
    answer correctness). This first cut gives a directional baseline.
    """
    truth_raw = qa_result.get("ground_truth")
    truth = "" if truth_raw is None else str(truth_raw).lower().strip()
    reply = (qa_result.get("reply") or "").lower().strip()
    if not truth or not reply:
        return {**qa_result, "score": 0, "score_method": "missing"}

    # Exact substring containment
    if truth in reply:
        return {**qa_result, "score": 1, "score_method": "exact_substring"}

    # Token Jaccard overlap >= 0.5 = pass
    truth_tokens = set(re.findall(r"\w+", truth))
    reply_tokens = set(re.findall(r"\w+", reply))
    if not truth_tokens:
        return {**qa_result, "score": 0, "score_method": "no_truth_tokens"}
    overlap = len(truth_tokens & reply_tokens) / len(truth_tokens)
    score = 1 if overlap >= 0.5 else 0
    return {
        **qa_result,
        "score": score,
        "score_method": f"jaccard_{overlap:.2f}",
    }


def aggregate(results: list[dict[str, Any]]) -> dict[str, Any]:
    by_cat: dict[Any, dict[str, int]] = {}
    for r in results:
        c = r.get("category", "?")
        by_cat.setdefault(c, {"correct": 0, "total": 0})
        by_cat[c]["total"] += 1
        if r.get("score") == 1:
            by_cat[c]["correct"] += 1
    cat_scores = {
        c: {
            **v,
            "accuracy": (v["correct"] / v["total"]) if v["total"] else 0.0,
        }
        for c, v in by_cat.items()
    }
    total_correct = sum(v["correct"] for v in by_cat.values())
    total = sum(v["total"] for v in by_cat.values())
    return {
        "overall_accuracy": (total_correct / total) if total else 0.0,
        "total_correct": total_correct,
        "total_qa": total,
        "by_category": cat_scores,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", type=int, default=0, help="LoCoMo sample index 0-9")
    ap.add_argument("--max-sessions", type=int, default=3, help="cap # sessions to load")
    ap.add_argument("--max-qa", type=int, default=5, help="cap # QA probes")
    ap.add_argument("--all", action="store_true", help="run all 10 samples (overrides --sample)")
    ap.add_argument("--out-dir", default=None, help="output directory")
    args = ap.parse_args()

    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = Path(args.out_dir or f"runs/{ts}")
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"== LoCoMo runner ==", flush=True)
    print(f"  data: {LOCOMO_DATA}", flush=True)
    print(f"  gateway: {GATEWAY_URL}", flush=True)
    print(f"  user_id: {USER_ID}", flush=True)
    print(f"  out: {out_dir}", flush=True)

    with open(LOCOMO_DATA) as f:
        dataset = json.load(f)

    samples = list(range(len(dataset))) if args.all else [args.sample]

    all_results = []
    for s_idx in samples:
        sample = dataset[s_idx]
        run_id = f"s{s_idx}_{uuid.uuid4().hex[:6]}"
        sk = session_key_for(run_id)
        print(f"\n--- sample {s_idx} (sk={sk}) ---", flush=True)
        load_conversation_into_session(sample["conversation"], sk, args.max_sessions)
        # Brief pause for extraction queue to drain
        print(f"  draining extraction queue (10s)...", flush=True)
        time.sleep(10)
        results = probe_qa(sample["qa"], sk, args.max_qa)
        scored = [simple_score(r) for r in results]
        agg = aggregate(scored)
        all_results.append(
            {
                "sample_id": sample.get("sample_id", s_idx),
                "session_key": sk,
                "results": scored,
                "summary": agg,
            }
        )
        print(f"  sample {s_idx} accuracy: {agg['overall_accuracy']:.3f} ({agg['total_correct']}/{agg['total_qa']})", flush=True)

    out_path = out_dir / "results.json"
    with open(out_path, "w") as f:
        json.dump(
            {
                "timestamp": ts,
                "samples_run": samples,
                "max_sessions": args.max_sessions,
                "max_qa": args.max_qa,
                "results": all_results,
                "overall": aggregate([r for s in all_results for r in s["results"]]),
            },
            f,
            indent=2,
        )
    print(f"\n== written {out_path}", flush=True)


if __name__ == "__main__":
    main()
