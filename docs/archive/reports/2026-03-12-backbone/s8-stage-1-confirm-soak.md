# S8 Stage 1 Confirm Soak (Two-Track)

Date: 2026-03-12  
Owner: Codex (runtime/platform)  
Scope: repeatability check after Stage 1 GO

## Baseline

- `s8-stage-1-confirm-baseline-diagnostics.json`
- `s8-stage-1-confirm-baseline-status.txt`
- `s8-stage-1-confirm-baseline-doctor.txt`

## Track A — Chat-Stream Stability

Artifacts:
- `s8-stage-1-confirm-chatstream-20.json`
- `s8-stage-1-confirm-chatstream-50.json`

Results:
- 20 users (`main_only`): `20/20`, `0%` errors, `p50=13419ms`, `p95=18960ms`, `p99=19372ms`
- 50 users (`mixed_real`): `49/50`, `2%` errors, `p50=37758ms`, `p95=65511ms`, `p99=71794ms`
- failure signature: single long-tail timeout (`elapsed_ms~605008`) in one request

## Track B — Telegram Strict-Ingress Correctness

Artifact:
- `s8-stage-1-confirm-telegram-strict-ingress.json`

Results:
- mapped ingress accepted (`200`)
- unmapped ingress strict-rejected (`403`, `strict_identity_reject`)
- strict observability delta: `+1`

## Decision

Decision: **HOLD (promotion repeatability not fully clean)**  

Reason:
- strict correctness stayed correct
- runtime stability repeatability did not meet hard `<1%` error gate in this confirm sample (`2%`)

Operational interpretation:
- keep Stage 1 Telegram strict in place (no rollback)
- treat Stage 1 runtime repeatability as still under watch until next clean soak
