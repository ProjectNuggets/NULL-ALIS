# Rollout Increase Decision Report (Two Consecutive Canary Sets)

Date: 2026-03-13  
Owner: Codex (runtime/platform)  
Branch: `v0.2-scale-exec-swisswatch`  
Scope: rollout-increase decision from current level using hard gates

## Baseline and Gates

Pre-run baseline artifacts:
- `baseline-status-user1.txt`
- `baseline-doctor-user1.txt`
- `baseline-diagnostics-user1.json`

Build gates on rollout SHA:
- `zig build test --summary all` -> pass (`4544` passed, `17` skipped)
- `zig build -Dengines=base,sqlite,postgres` -> pass

Runtime posture during both sets:
- `tenant.identity_mapping_enforcement = staged_strict`
- `tenant.identity_mapping_strict_channels = ["telegram"]`
- diagnostics reported `tenant_lock_backend = postgres_lease`

## Canary Results

Hard thresholds:
- 20 users: `p50<20s`, `p95<35s`, `p99<50s`, `error<1%`
- 50 users: `p50<40s`, `p95<70s`, `p99<90s`, `error<1%`
- 100 users: `p50<100s`, `p95<160s`, `p99<220s`, `error<1%`
- must pass in two consecutive sets on same posture

Set #1:
- 20 users ([canary-set1-20.json](/Users/nova/Desktop/nullalis/docs/reports/2026-03-13-rollout/canary-set1-20.json)):
  - `20/20`, `0%` errors, `p50=32869ms`, `p95=87624ms`, `p99=96773ms` -> **FAIL**
- 50 users ([canary-set1-50.json](/Users/nova/Desktop/nullalis/docs/reports/2026-03-13-rollout/canary-set1-50.json)):
  - `50/50`, `0%` errors, `p50=64602ms`, `p95=112484ms`, `p99=130217ms` -> **FAIL**
- 100 users ([canary-set1-100.json](/Users/nova/Desktop/nullalis/docs/reports/2026-03-13-rollout/canary-set1-100.json)):
  - `100/100`, `0%` errors, `p50=53552ms`, `p95=85293ms`, `p99=94273ms` -> **PASS**

Set #2:
- 20 users ([canary-set2-20.json](/Users/nova/Desktop/nullalis/docs/reports/2026-03-13-rollout/canary-set2-20.json)):
  - `20/20`, `0%` errors, `p50=10387ms`, `p95=22929ms`, `p99=50790ms` -> **FAIL** (`p99` above threshold by `790ms`)
- 50 users ([canary-set2-50.json](/Users/nova/Desktop/nullalis/docs/reports/2026-03-13-rollout/canary-set2-50.json)):
  - `50/50`, `0%` errors, `p50=27226ms`, `p95=45383ms`, `p99=53250ms` -> **PASS**
- 100 users ([canary-set2-100.json](/Users/nova/Desktop/nullalis/docs/reports/2026-03-13-rollout/canary-set2-100.json)):
  - `100/100`, `0%` errors, `p50=27563ms`, `p95=45420ms`, `p99=47019ms` -> **PASS**

Consecutive-pass check:
- 20 users -> **FAIL** (set1 fail, set2 fail)
- 50 users -> **FAIL** (set1 fail, set2 pass)
- 100 users -> **PASS** (set1 pass, set2 pass)

## Isolation + Runtime Correctness Evidence

Runtime correctness:
- `tenant_lock_backend=postgres_lease` observed in diagnostics snapshots for all six runs.
- same `instance_id` observed in all runs (single-cell consistency).

Isolation gate (`unaffected cohort p95 degradation <=15%`):
- **Not proven by current artifacts**. This run executed burst tiers, but did not include an explicit unaffected-cohort split measurement.

Sticky routing verification:
- local single-cell run shows stable instance handling.
- multi-cell sticky routing evidence is still pending.

## Decision

Decision: **HOLD** (no rollout increase)

Reason:
1. hard gate requires two consecutive passes for 20/50/100; this was not met (20 and 50 failed consecutive criterion).
2. isolation gate evidence is incomplete in this run design.
3. runtime correctness for `postgres_lease` passed, but multi-cell sticky-routing proof is still pending.

## Required Next Actions

1. keep rollout at current level (no increase).
2. add explicit unaffected-cohort measurement to canary harness/report.
3. run another two-set confirmatory cycle on identical posture after p99-tail stabilization for 20/50 tiers.
