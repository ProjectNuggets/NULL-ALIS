#!/usr/bin/env python3
"""
F-S1.5 — LLM-judge scoring for LoCoMo benchmark results.

Apples-to-apples methodology with mem0 / Letta / Zep papers:
  - Judge model: openai/gpt-4o-mini via OpenRouter (same model these
    papers use for their judge — convention, not optimal)
  - Binary YES/NO equivalence per (question, ground_truth, agent_reply)
  - Cost: ~$0.06-0.10 for 600 QAs total
  - No agent execution — just judges already-collected replies

Disclosure: judge model is gpt-4o-mini. Reviewers cross-checking with
the mem0 paper methodology can directly compare.

Usage:
  python judge.py --in runs/.../results.json --out runs/.../judged.json
  python judge.py --in runs/.../results.json --judge-model openai/gpt-4o
"""
import argparse
import json
import os
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Any, Optional

import requests

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

# Judge prompt: standard form used across mem0/Letta/Zep evaluations.
# Asks for binary YES/NO equivalence — captures semantic match while
# tolerating different phrasing/formatting.
JUDGE_SYSTEM = (
    "You are an evaluator scoring whether a candidate answer is "
    "semantically equivalent to the ground-truth answer for a given "
    "question. Reply with ONLY 'YES' or 'NO' — no explanation."
)
JUDGE_USER_TEMPLATE = """Question: {question}
Ground truth: {ground_truth}
Candidate answer: {candidate}

Is the candidate answer semantically correct given the ground truth? Reply YES if the candidate captures the same meaning (even if phrased differently or with extra context). Reply NO if the candidate is missing the key information, contradicts the truth, says it cannot find the answer, or is wrong.

Reply with only YES or NO."""


def get_openrouter_key() -> str:
    """Pull OpenRouter key from nullalis config (already wired) or env."""
    env_key = os.environ.get("OPENROUTER_API_KEY")
    if env_key:
        return env_key
    config_path = Path.home() / ".nullalis" / "config.json"
    if config_path.exists():
        with open(config_path) as f:
            cfg = json.load(f)
        for prov in cfg.get("models", {}).get("providers", {}).values():
            ak = prov.get("api_key", "")
            if ak.startswith("sk-or-"):
                return ak
    sys.exit("ERROR: set OPENROUTER_API_KEY env var or have it in ~/.nullalis/config.json")


def judge_one(
    question: str,
    ground_truth: str,
    candidate: str,
    api_key: str,
    judge_model: str,
    max_retries: int = 3,
) -> Optional[bool]:
    """Single judge call. Returns True/False or None on parse failure."""
    body = {
        "model": judge_model,
        "messages": [
            {"role": "system", "content": JUDGE_SYSTEM},
            {
                "role": "user",
                "content": JUDGE_USER_TEMPLATE.format(
                    question=question,
                    ground_truth=ground_truth,
                    candidate=candidate[:2000],  # cap reply length to control input cost
                ),
            },
        ],
        "max_tokens": 8,
        "temperature": 0.0,
    }
    backoff = 2.0
    for attempt in range(max_retries):
        try:
            resp = requests.post(
                OPENROUTER_URL,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                data=json.dumps(body),
                timeout=60,
            )
            if resp.status_code == 429:
                time.sleep(backoff)
                backoff = min(backoff * 1.5, 15.0)
                continue
            if resp.status_code != 200:
                print(f"      judge http {resp.status_code}: {resp.text[:200]}", file=sys.stderr)
                return None
            data = resp.json()
            content = data["choices"][0]["message"]["content"].strip().upper()
            # Tolerate common variants
            if content.startswith("YES"):
                return True
            if content.startswith("NO"):
                return False
            # Sometimes models reply with longer text starting with "yes," etc.
            if "YES" in content[:20] and "NO" not in content[:20]:
                return True
            if "NO" in content[:20] and "YES" not in content[:20]:
                return False
            print(f"      judge ambiguous reply: {content!r}", file=sys.stderr)
            return None
        except requests.RequestException as e:
            time.sleep(backoff)
            backoff = min(backoff * 1.5, 15.0)
    return None


def normalize_truth(truth) -> str:
    """LoCoMo cat-3 splits ground truth on `;`; truth-list flattening."""
    if truth is None:
        return ""
    if isinstance(truth, list):
        return " | ".join(str(t) for t in truth)
    return str(truth)


def judge_results(
    src: Path,
    judge_model: str,
    api_key: str,
    out_path: Path,
) -> None:
    with open(src) as f:
        prior = json.load(f)

    print(f"== F-S1.5 LLM-judge ==", flush=True)
    print(f"  src: {src}", flush=True)
    print(f"  judge: {judge_model}", flush=True)
    print(f"  out: {out_path}", flush=True)

    new_samples = []
    total_judged = 0
    total_yes = 0
    total_skip = 0
    total_cost_estimate = 0.0  # gpt-4o-mini: ~$0.15/M input + $0.60/M output

    for sample in prior.get("results", []):
        scored = []
        sample_yes = 0
        sample_total = 0
        for r in sample.get("results", []):
            sample_total += 1
            total_judged += 1
            question = r.get("question", "")
            truth = normalize_truth(r.get("ground_truth"))
            reply = r.get("reply", "") or ""

            # Skip ERROR-prefix replies (transport failures, never reached agent)
            if reply.startswith("[ERROR"):
                judged = False
                method = "skipped_transport_error"
            elif not truth or not reply:
                judged = False
                method = "missing_truth_or_reply"
            else:
                verdict = judge_one(question, truth, reply, api_key, judge_model)
                if verdict is None:
                    judged = r.get("score", 0) == 1  # fall back to recall score
                    method = "judge_fallback_to_recall"
                    total_skip += 1
                else:
                    judged = verdict
                    method = f"judge_{judge_model}"
                    if verdict:
                        sample_yes += 1
                        total_yes += 1
            scored.append(
                {
                    **r,
                    "judge_score": 1 if judged else 0,
                    "judge_method": method,
                }
            )
        # Per-sample aggregate
        cat_correct: dict = Counter()
        cat_total: dict = Counter()
        for r in scored:
            c = r.get("category", "?")
            cat_total[c] += 1
            if r.get("judge_score") == 1:
                cat_correct[c] += 1
        cat_scores = {
            c: {
                "correct": cat_correct[c],
                "total": cat_total[c],
                "accuracy": (cat_correct[c] / cat_total[c]) if cat_total[c] else 0.0,
            }
            for c in cat_total
        }
        agg = {
            "overall_accuracy": (sample_yes / sample_total) if sample_total else 0.0,
            "total_correct": sample_yes,
            "total_qa": sample_total,
            "by_category": cat_scores,
        }
        new_samples.append(
            {
                "sample_id": sample.get("sample_id"),
                "session_key": sample.get("session_key"),
                "results": scored,
                "judge_summary": agg,
                "recall_summary": sample.get("summary"),
            }
        )
        print(
            f"  sample {sample.get('sample_id')}: judge {agg['overall_accuracy']*100:.1f}% ({sample_yes}/{sample_total}) | recall {sample.get('summary',{}).get('overall_accuracy',0)*100:.1f}%",
            flush=True,
        )

    # Overall
    all_results = [r for s in new_samples for r in s["results"]]
    cat_correct: dict = Counter()
    cat_total: dict = Counter()
    for r in all_results:
        c = r.get("category", "?")
        cat_total[c] += 1
        if r.get("judge_score") == 1:
            cat_correct[c] += 1
    overall = {
        "overall_accuracy": (total_yes / total_judged) if total_judged else 0.0,
        "total_correct": total_yes,
        "total_qa": total_judged,
        "judge_skipped": total_skip,
        "by_category": {
            c: {
                "correct": cat_correct[c],
                "total": cat_total[c],
                "accuracy": (cat_correct[c] / cat_total[c]) if cat_total[c] else 0.0,
            }
            for c in cat_total
        },
        "judge_model": judge_model,
    }
    print(f"\n  OVERALL judge: {overall['overall_accuracy']*100:.2f}% ({total_yes}/{total_judged})", flush=True)
    print(f"  judge skipped (parse failure): {total_skip}", flush=True)
    print("  by category:", flush=True)
    for c in sorted(overall["by_category"].keys()):
        v = overall["by_category"][c]
        print(f"    cat {c}: {v['accuracy']*100:.1f}% ({v['correct']}/{v['total']})", flush=True)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(
            {
                "timestamp_judged": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "judge_model": judge_model,
                "judge_methodology": "openai/gpt-4o-mini via OpenRouter; matches mem0/Letta/Zep paper convention",
                "scored_from": str(src),
                "results": new_samples,
                "overall": overall,
            },
            f,
            indent=2,
        )
    print(f"\n== written {out_path}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True, help="input results.json from run_bench.py")
    ap.add_argument("--out", dest="out", default=None, help="output path (default: <src>.judged.json)")
    ap.add_argument("--judge-model", default="openai/gpt-4o-mini", help="OpenRouter model id (default: openai/gpt-4o-mini, matches mem0/Letta/Zep)")
    args = ap.parse_args()

    src = Path(args.src)
    if not src.exists():
        sys.exit(f"ERROR: --in path does not exist: {src}")
    out = Path(args.out or src.parent / f"{src.stem}.judged.json")

    api_key = get_openrouter_key()
    judge_results(src, args.judge_model, api_key, out)


if __name__ == "__main__":
    main()
