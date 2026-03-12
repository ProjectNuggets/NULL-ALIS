# Canary Suite Report — 2026-03-12 (Q5 Stage)

Environment:
1. local gateway (`127.0.0.1:3000`)
2. tenant mode enabled
3. multi-user synthetic load via `scripts/load-burst.py`

SLO gates (runbook):
1. `p50 < 8s`
2. `p95 < 20s`
3. `p99 < 35s`
4. error rate `< 1%`

## Results

| Scenario | Requests | Success | Errors | Wall (ms) | p50 (ms) | p95 (ms) | p99 (ms) |
|---|---:|---:|---:|---:|---:|---:|---:|
| `multi-user-20` (`main_only`) | 20 | 20 | 0 | 33,832 | 14,416 | 27,601 | 33,829 |
| `multi-user-50` (`mixed_real`) | 50 | 50 | 0 | 60,241 | 29,909 | 50,516 | 60,227 |
| `multi-user-100` (`main_only`) | 100 | 100 | 0 | 224,269 | 82,834 | 134,275 | 144,389 |

Artifacts:
1. `canary-20-main.json`
2. `canary-50-mixed.json`
3. `canary-100-main.json`

## Gate Evaluation

1. Error-rate gate: PASS (`0%` errors in all three scenarios).
2. Latency gates (`p50/p95/p99`): FAIL (all three scenarios exceed targets).
3. Isolation check (same-user contention profile): PASS (`max_requests_on_single_user_session=1` across scenarios).

## Decision

1. Promotion: HOLD.
2. Keep current rollout posture; do not increase traffic percentage.
3. Move to Q6 capacity/cost refresh using measured values from these artifacts.
