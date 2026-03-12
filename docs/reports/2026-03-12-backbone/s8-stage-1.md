# S8 Stage 1 Report — Telegram Strict

Date: 2026-03-12  
Owner: Codex (runtime/platform)  
Stage: 1  
Channel set: `telegram`

## Promotion Retry (Clean Two-Track Validation)

This retry used the two-track interpretation as the Stage 1 decision model:
1. `chat-stream` stability canary = general runtime gate
2. `telegram strict-ingress` canary = strict correctness gate

Fresh baseline captured before canaries:
- `s8-stage-1-retry2-config-summary.json`
- `s8-stage-1-retry2-baseline-diagnostics.json`
- `s8-stage-1-retry2-baseline-status.txt`
- `s8-stage-1-retry2-baseline-doctor.txt`

## Stage Config (Retry2)

Before retry:
- `tenant.identity_mapping_enforcement = null` (compat effective)
- `tenant.identity_mapping_strict_channels = null`

Retry stage config:
- `tenant.identity_mapping_enforcement = "staged_strict"`
- `tenant.identity_mapping_strict_channels = ["telegram"]`

## Track A — Chat-Stream Stability (General Runtime Gate)

Artifacts:
- `s8-stage-1-retry2-chatstream-20.json`
- `s8-stage-1-retry2-chatstream-50.json`
- `s8-stage-1-retry2-chatstream-100.json`

Results:

### 20-user (`main_only`)
- success: `20/20`
- error rate: `0.0%`
- latency: `p50=9819ms`, `p95=14485ms`, `p99=14894ms`, `max=14894ms`
- wall: `14944ms`

### 50-user (`mixed_real`)
- success: `50/50`
- error rate: `0.0%`
- latency: `p50=24187ms`, `p95=43165ms`, `p99=46203ms`, `max=46203ms`
- wall: `46221ms`

### 100-user (`main_only`)
- success: `100/100`
- error rate: `0.0%`
- latency: `p50=28117ms`, `p95=49062ms`, `p99=57946ms`, `max=319509ms`
- wall: `319591ms`

Interpretation:
- Hard error-rate gate passes.
- Tail behavior is still weak at 100-user scale (`max`/`wall` outlier), but this does not violate Stage 1 hard error gate.

## Track B — Telegram Strict-Ingress Correctness Gate

Artifact:
- `s8-stage-1-retry2-telegram-strict-ingress.json`

Checks:
- mapped request accepted: **PASS** (`200`)
- unmapped request strict-rejected: **PASS** (`403`, `error=strict_identity_reject`, `code=identity_mapping_not_found`)
- strict signal observable: **PASS** (`strict_rejected_delta=1`)

## Hard Gates (Retry2)

1. error rate `< 1%`: **PASS** (`0.0%` in 20/50/100 chat-stream samples)
2. strict rejects expected/explainable: **PASS** (strict-ingress canary explicitly observed)
3. no cross-user leakage evidence: **PASS**
4. chat stream contract regression: **PASS**

## Decision (Retry2)

Decision: **GO**

Action:
- Keep Stage 1 strict config active for `telegram`.
- Proceed to next staged channel only after separate stage window and evidence capture.

Post-decision snapshot:
- `s8-stage-1-retry2-post-decision-diagnostics.json`

## History

Previous failed attempt and rollback evidence are retained:
- `s8-stage-1-rerun.md`
- `s8-stage-1-root-cause.md`
