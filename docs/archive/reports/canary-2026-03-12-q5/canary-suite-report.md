---
tags: [prose, prose/docs]
---

# Canary Suite Report — 2026-03-12 (Q5 Stage)

Environment:
1. local gateway (`127.0.0.1:3000`)
2. tenant mode enabled
3. multi-user synthetic load via `scripts/load-burst.py`

Gate profile A (north-star target):
1. `p50 < 8s`
2. `p95 < 20s`
3. `p99 < 35s`
4. error rate `< 1%`

Gate profile B (v0.2 rollout guardrail):
1. 20-user: `p50 < 20s`, `p95 < 35s`, `p99 < 50s`, error `< 1%`
2. 50-user: `p50 < 40s`, `p95 < 70s`, `p99 < 90s`, error `< 1%`
3. 100-user: `p50 < 100s`, `p95 < 160s`, `p99 < 220s`, error `< 1%`

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
2. Gate profile A latency: FAIL (north-star targets not met).
3. Gate profile B latency: PASS (rollout guardrails met).
4. Isolation check (same-user contention profile): PASS (`max_requests_on_single_user_session=1` across scenarios).

## Deploy Go/No-Go Dashboard

| Gate | Hard threshold | Current evidence (Q5) | Status | Deploy action |
|---|---|---|---|---|
| Build/test gate | `zig build test --summary all` and `zig build -Dengines=base,sqlite,postgres` pass | Passed on branch `f73b63d` | PASS | Keep |
| Error budget | Error rate `< 1%` | `0/20`, `0/50`, `0/100` errors | PASS | Keep |
| Latency (profile A) | `p50<8s, p95<20s, p99<35s` | fails on all three scenarios | FAIL | NO-GO for scale claim |
| Latency (profile B) | `20/50/100` guardrails from runbook | all three scenarios pass | PASS | GO for controlled rollout |
| Isolation (noisy-neighbor) | unaffected cohort p95 delta `<= 15%` | Not measured in this Q5 set | NOT VERIFIED | NO-GO for scale claim |
| Sticky routing | One canonical user hashes to one instance in steady state | Tooling in place (`stickiness-probe.sh`), staged cluster evidence pending | NOT VERIFIED | Run staged canary proof |
| Ownership backend | Tenant+Postgres production should report `tenant_lock_backend=postgres_lease` | Runtime path implemented; cluster evidence pending | PARTIAL | Verify in staging before promote |

Overall decision:
1. **GO for controlled rollout** under profile-B guardrails and rollout caps.
2. **NO-GO for scale-ready claim** until profile-A latency and isolation verification pass.

## Decision

1. Promotion: CONDITIONAL GO (controlled rollout only).
2. Keep strict claim gate closed until profile-A + isolation pass.
3. Move to Q6 capacity/cost refresh using measured values from these artifacts.
