# Capacity + Cost Refresh (No LLM Cost) — 2026-03-12

Source artifacts:
1. `canary-20-main.json`
2. `canary-50-mixed.json`
3. `canary-100-main.json`
4. `canary-suite-report.md`

## Measured Throughput/Latency Snapshot

| Scenario | Success | Error % | p50 | p95 | p99 |
|---|---:|---:|---:|---:|---:|
| 20 users (`main_only`) | 20/20 | 0.0% | 14.4s | 27.6s | 33.8s |
| 50 users (`mixed_real`) | 50/50 | 0.0% | 29.9s | 50.5s | 60.2s |
| 100 users (`main_only`) | 100/100 | 0.0% | 82.8s | 134.3s | 144.4s |

Interpretation:
1. correctness/stability is strong (0 errors).
2. latency scales unfavorably at higher active concurrency.
3. current posture is queue-safe but not yet SLO-safe for the strict interactive target.

## Capacity Envelope (Current Build, Heavy Turns)

Conservative envelope for planning:
1. Strict interactive (`p95 < 20s`): treat current cell capacity as **~10-14 active heavy users**.
2. Relaxed power-user (`p95 < 35s`): treat current cell capacity as **~18-24 active heavy users**.
3. Burst correctness (not latency-quality): cell can complete far more requests with rising queue delay.

## Cost Model (Infra Only, Excluding LLM)

Definitions:
1. `C_cell_month`: all-in monthly infra cost per cell (compute + storage + network + DB share + observability share).
2. `U_paid_cell`: paid users allocated to that cell at target SLO tier.
3. `Cost_per_user_month = C_cell_month / U_paid_cell`.

Reference table (sensitivity):

| `C_cell_month` | `U_paid_cell=20` | `U_paid_cell=40` | `U_paid_cell=80` |
|---:|---:|---:|---:|
| $150 | $7.50 | $3.75 | $1.88 |
| $300 | $15.00 | $7.50 | $3.75 |
| $600 | $30.00 | $15.00 | $7.50 |

Operational reading:
1. your per-user infra cost is dominated by effective users-per-cell at SLO, not by raw request success.
2. improving p95/p99 under load directly improves margin by increasing `U_paid_cell`.

## Recommended Next Step

1. Keep rollout at HOLD until canary latency gates improve.
2. Run Q5 in staged cell rollout environments (10→25→50→75→100%) with same JSON schema.
3. Recompute this report with real `C_cell_month` from your cloud bill and observed `U_paid_cell` at gate-passing latency.
