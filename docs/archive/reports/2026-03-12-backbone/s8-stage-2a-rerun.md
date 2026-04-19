# S8 Stage 2A Rerun Report — Slack Strict

Date: 2026-03-12  
Owner: Codex (runtime/platform)  
Stage: 2A (rerun)  
Channel set: `slack`

## Scope

Rerun Stage 2A with two-track interpretation:
1. chat-stream stability = general runtime gate
2. Slack strict-ingress canary = strict correctness gate

## Baseline + Config

Strict canary window config:
- `tenant.identity_mapping_enforcement = "staged_strict"`
- `tenant.identity_mapping_strict_channels = ["telegram","slack"]`
- Slack HTTP canary account `stage2a` on `/slack/events`

Artifacts:
- `s8-stage-2a-rerun-config-summary.json`
- `s8-stage-2a-rerun-baseline-diagnostics.json`
- `s8-stage-2a-rerun-baseline-status.txt`
- `s8-stage-2a-rerun-baseline-doctor.txt`

## Track A — Chat-Stream Stability

Artifacts:
- `s8-stage-2a-rerun-chatstream-20.json`
- `s8-stage-2a-rerun-chatstream-50.json`

Results:
- 20 users (`main_only`): `20/20`, `0%` errors, `p50=12580ms`, `p95=23598ms`, `p99=24765ms`, `wall=24769ms`
- 50 users (`mixed_real`): `50/50`, `0%` errors, `p50=73474ms`, `p95=114107ms`, `p99=120433ms`, `wall=120445ms`

Gate status:
- runtime error-rate gate: **PASS**

## Track B — Slack Strict-Ingress Correctness

Artifact:
- `s8-stage-2a-rerun-slack-strict-ingress.json`

Results:
- mapped ingress accepted: **PASS** (`200`)
- unmapped ingress strict-rejected: **PASS** (`403`, `error=strict_identity_reject`, `code=identity_mapping_not_found`)
- strict reject observability: **PASS** (`strict_rejected_delta=1`)

## Decision

Decision: **GO (Stage 2A rerun passed)**

Reason:
- strict correctness gate passed for Slack ingress
- runtime error-rate gate passed (`0%` for 20 and 50 user samples)

Post-decision diagnostics artifact:
- `s8-stage-2a-rerun-post-decision-diagnostics.json`

## Operational Note

After collecting rerun evidence, local developer config was restored to the pre-rerun baseline (`/tmp/nullalis-config-pre-stage2a-rerun.json`) and gateway restarted.
