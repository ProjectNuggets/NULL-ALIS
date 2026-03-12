# S8 Stage 2A Report — Slack Strict

Date: 2026-03-12  
Owner: Codex (runtime/platform)  
Stage: 2A  
Channel set: `slack`

## Config + Baseline

Stage config applied for canary window:
- `tenant.identity_mapping_enforcement = "staged_strict"`
- `tenant.identity_mapping_strict_channels = ["telegram","slack"]`
- local Slack HTTP canary account (`account_id=stage2a`) added for webhook validation

Artifacts:
- `s8-stage-2a-config-summary.json`
- `s8-stage-2a-baseline-diagnostics.json`
- `s8-stage-2a-baseline-status.txt`
- `s8-stage-2a-baseline-doctor.txt`

## Track A — Chat-Stream Stability

Artifacts:
- `s8-stage-2a-chatstream-20.json`
- `s8-stage-2a-chatstream-50.json`

Results:
- 20 users (`main_only`): `20/20`, `0%` errors, `p50=34057ms`, `p95=54144ms`, `p99=69635ms`
- 50 users (`mixed_real`): `50/50`, `0%` errors, `p50=41911ms`, `p95=58082ms`, `p99=66128ms`

Gate status:
- runtime error-rate gate: **PASS**

## Track B — Slack Strict-Ingress Correctness

Artifact:
- `s8-stage-2a-slack-strict-ingress.json`

Results:
- mapped ingress accepted (`200`) — PASS
- unmapped ingress accepted (`200`) — FAIL
- explicit strict reject on unmapped ingress: **not observed**

Observability note:
- `strict_rejected_delta` changed, but canary pass criteria uses explicit unmapped strict-reject response only.

## Decision

Decision: **ROLLBACK (config-only)**

Reason:
- strict correctness gate failed for Slack ingress (`unmapped` request was accepted instead of strict-rejected)

Rollback action:
- removed `slack` from `tenant.identity_mapping_strict_channels`
- kept `telegram` strict active
- captured rollback snapshot:
  - `s8-stage-2a-post-rollback-diagnostics.json`

## Next Step

Before Stage 2A re-attempt:
1. Wire Slack webhook ingress through canonicalizer/strict decision path (same enforcement model as Telegram path).
2. Re-run this exact two-track Stage 2A canary set.
