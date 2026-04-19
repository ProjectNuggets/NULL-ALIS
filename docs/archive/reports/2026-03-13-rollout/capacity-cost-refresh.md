# Capacity + Cost Refresh (Measured Artifacts Through 2026-03-13, No LLM Cost)

## Source Artifacts

1. `docs/reports/canary-2026-03-12-q5/canary-20-main.json`
2. `docs/reports/canary-2026-03-12-q5/canary-50-mixed.json`
3. `docs/reports/canary-2026-03-12-q5/canary-100-main.json`
4. `docs/reports/2026-03-12-backbone/s8-stage-1-confirm-chatstream-20.json`
5. `docs/reports/2026-03-12-backbone/s8-stage-1-confirm-chatstream-50.json`
6. `docs/reports/2026-03-12-backbone/s8-stage-1-retry2-chatstream-20.json`
7. `docs/reports/2026-03-12-backbone/s8-stage-1-retry2-chatstream-50.json`
8. `docs/reports/2026-03-12-backbone/s8-stage-1-retry2-chatstream-100.json`
9. `docs/reports/2026-03-12-backbone/s8-stage-2a-chatstream-20.json`
10. `docs/reports/2026-03-12-backbone/s8-stage-2a-chatstream-50.json`
11. `docs/reports/2026-03-12-backbone/s8-stage-2a-rerun-chatstream-20.json`
12. `docs/reports/2026-03-12-backbone/s8-stage-2a-rerun-chatstream-50.json`

## Consolidated Measured Range

### 20-user runs (5 samples)

1. error range: `0.0%` to `0.0%`
2. `p50` range: `9.8s` to `34.1s` (median `13.4s`)
3. `p95` range: `14.5s` to `54.1s` (median `23.6s`)
4. `p99` range: `14.9s` to `69.6s` (median `24.8s`)

### 50-user runs (5 samples)

1. error range: `0.0%` to `2.0%` (one timeout-bearing sample)
2. `p50` range: `24.2s` to `73.5s` (median `37.8s`)
3. `p95` range: `43.2s` to `114.1s` (median `58.1s`)
4. `p99` range: `46.2s` to `120.4s` (median `66.1s`)

### 100-user runs (3 samples)

1. error range: `0.0%` to `0.0%`
2. `p50` range: `28.1s` to `82.8s` (median `76.6s`)
3. `p95` range: `49.1s` to `134.3s` (median `99.1s`)
4. `p99` range: `57.9s` to `144.4s` (median `102.3s`)

## Hard-Gate Decision (Rollout Increase)

Profile-B hard gates (from runbook):

1. 20-user: `p50<20s`, `p95<35s`, `p99<50s`, error `<1%`
2. 50-user: `p50<40s`, `p95<70s`, `p99<90s`, error `<1%`
3. 100-user: `p50<100s`, `p95<160s`, `p99<220s`, error `<1%`

Decision for rollout promotion from current level:

1. **HOLD (no increase)**.

Reason:

1. 50-user samples are not repeatably within hard gate (`p95` and `p99` outliers observed up to `114.1s`/`120.4s`).
2. one 50-user sample breached hard error budget (`2.0%`).
3. therefore evidence is strong enough for continued controlled operation, but not for traffic promotion.

## Capacity Envelope Refresh (Planning, Heavy Turns)

Updated conservative planning envelope (de-rated from prior report due variance):

1. strict interactive (`p95 < 20s`): **~8-12 active heavy users per cell**
2. relaxed power-user (`p95 < 35s`): **~14-20 active heavy users per cell**
3. burst correctness (queue-tolerant): substantially higher completion possible, but with tail-latency expansion

## Cost Model (Infra Only, Excluding LLM)

Definitions:

1. `C_cell_month`: monthly all-in infra cost per cell
2. `U_paid_cell`: paid users carried by a cell at target SLO tier
3. `Cost_per_user_month = C_cell_month / U_paid_cell`

Sensitivity table:

| `C_cell_month` | `U_paid_cell=12` | `U_paid_cell=20` | `U_paid_cell=40` |
|---:|---:|---:|---:|
| $150 | $12.50 | $7.50 | $3.75 |
| $300 | $25.00 | $15.00 | $7.50 |
| $600 | $50.00 | $30.00 | $15.00 |

Operational read:

1. margin is still dominated by stable users-per-cell at SLO, not raw request completion.
2. reducing p95/p99 variance is the highest-leverage margin lever before raising rollout.

## Next Action

1. keep rollout at current level (no increase).
2. run confirmatory canary set at same posture (20/50/100) and require repeat hard-gate pass before promoting.
3. if repeat pass is clean, reassess promotion; if not, tune queue/worker/DB/provider posture before retest.
