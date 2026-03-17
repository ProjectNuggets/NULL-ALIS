# Next Implementation Plan (From Sweep Findings)

## Objective
Reduce user-perceived latency spikes without weakening correctness-first serial processing.

## Ordered Steps

1. Session lock visibility and gating (P0)
- Surface lock wait and queue depth in progress path.
- Enforce one active turn per session lane at ingress/BFF to avoid hidden same-lane pileups.

2. Balanced short-turn guardrails (P1)
- Prevent unnecessary tool loops on trivial prompts.
- Preserve tool usage for clearly tool-dependent requests.

3. Memory activation correctness (P1)
- Correct semantic default gating so intended hybrid/pgvector mode can activate when expected.
- Verify with `memory plan resolved` logs after restart.

4. Revalidation gates (P0/P1)
- Re-run S1/S2/S4 + isolated control.
- Pass only if:
  - S4 lock-wait p95 materially reduced,
  - S1 no timeout pattern on clean lane,
  - no deep-turn correctness regressions.

## Why this order
- Step 1 addresses the biggest proven blocker (`session_lock_wait`) with lowest semantic risk.
- Step 2 removes avoidable model/tool inflation on short turns.
- Step 3 restores memory quality and durability confidence once latency path is stabilized.
