# S8 Stage 1 Report — Telegram Strict

Date: 2026-03-12  
Owner: Codex (runtime/platform)  
Stage: 1  
Channel set: `telegram`

## Update (P1 Re-run)

- Follow-up recovery rerun recorded in:
- `docs/reports/2026-03-12-backbone/s8-stage-1-rerun.md`
- Current promotion state remains: **HOLD/ROLLBACK** pending strict-ingress precondition fix and revalidation.

## Config Change

Before stage:
- `tenant.identity_mapping_enforcement = null` (compat effective)
- `tenant.identity_mapping_strict_channels = null`

Stage config:
- `tenant.identity_mapping_enforcement = "staged_strict"`
- `tenant.identity_mapping_strict_channels = ["telegram"]`

Rollback config (applied):
- `tenant.identity_mapping_enforcement = null`
- `tenant.identity_mapping_strict_channels = null`

Evidence:
- `s8-stage-1-config-summary.json`
- `s8-stage-1-diagnostics-before-summary.json`
- `s8-stage-1-diagnostics-after-config-summary.json`
- `s8-stage-1-diagnostics-post-rollback-summary.json`

## Canary Artifacts

- `s8-stage-1-20.json`
- `s8-stage-1-50.json`
- `s8-stage-1-100.json`

## Results

### 20-user (`main_only`)
- success: `20/20`
- error rate: `0.0%`
- latency: `p50=11965ms`, `p95=18163ms`, `p99=18167ms`

### 50-user (`mixed_real`)
- success: `50/50`
- error rate: `0.0%`
- latency: `p50=36430ms`, `p95=58776ms`, `p99=59754ms`

### 100-user (`main_only`)
- success: `90/100`
- error rate: `10.0%`
- latency: `p50=30908ms`, `p95=55913ms`, `p99=58852ms`
- error reasons: `exception=5`, `http_error=5`

## Strict-Reject Distribution

- `strict_rejected = 0` in diagnostics snapshots collected for this stage window.
- Interpretation: this canary profile exercised chat-stream load heavily but did not produce observable strict-reject events in the sampled diagnostics.

## Mapping Coverage Delta

- Pre-stage diagnostics snapshot (from running system) showed identity mapping activity (`mapped=3`, `unmapped=0`, `strict_rejected=0`).
- Post-config/rollback snapshots during canary window showed no additional mapping counter deltas (`mapped=0`, `strict_rejected=0`) in sampled snapshots.

## Hard Gates

Stage hard-gate check:
1. error rate `< 1%`: **FAIL** (`10%` in 100-user sample)
2. strict rejects expected/explainable: **INCONCLUSIVE** (none observed)
3. no cross-user leakage evidence: **PASS** (no leakage evidence in canary summaries)
4. chat stream contract regression: **PASS** (responses remained valid)
5. build/test gates:
   - `zig build test --summary all`: **PASS**
   - `zig build -Dengines=base,sqlite,postgres`: **PASS**

## Decision

Decision: **ROLLBACK**

Reason:
- hard-gate error-rate target failed in stage sample (`10%` vs `<1%` threshold).

Action taken:
- removed `telegram` from strict channels by restoring pre-stage config.
- restarted gateway and captured post-rollback diagnostics artifact.

## Next Action

1. Hold S8 promotion.
2. Root-cause report completed:
- `docs/reports/2026-03-12-backbone/s8-stage-1-root-cause.md`
3. Execute remediation in order:
- fix high-concurrency crash in `zaki_state` session message load path
- improve ownership-lease conflict diagnostics
- run strict-path Telegram ingress canary separately from chat-stream burst canary
4. Re-run Stage 1 after remediation with same canary posture and artifact schema.
