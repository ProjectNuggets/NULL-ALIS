---
tags: [prose, prose/docs]
---

# Rollout Decision Report (Isolation-Probe Rerun)

Date: 2026-03-13  
Owner: Codex (runtime/platform)  
Scope: rerun confirmatory two-set cycle with unaffected-cohort isolation probe enabled

## Run Posture

Canary command posture:
- endpoint: `/api/v1/chat/stream`
- probe user: `1000` (non-overlapping with burst users `1..N`)
- probe count: `3` per phase
- lane strategy:
  - 20 users: `main_only`
  - 50 users: `mixed_real`
  - 100 users: `main_only`

Artifacts:
- `canary-set3-20.json`
- `canary-set3-50.json`
- `canary-set3-100.json`
- `canary-set4-20.json`
- `canary-set4-50.json`
- `canary-set4-100.json`

## Results Summary

Set #3:
- 20: `20/20`, errors `0`, `p50=5687`, `p95=10054`, `p99=14415`, isolation `pass` (degradation `-35.29%`)
- 50: `50/50`, errors `0`, `p50=10252`, `p95=18013`, `p99=18512`, isolation `fail` (degradation `114.79%`)
- 100: `100/100`, errors `0`, `p50=17279`, `p95=29930`, `p99=30807`, isolation `fail` (degradation `638.21%`)

Set #4:
- 20: `0/20`, errors `20`, isolation `inconclusive`
- 50: `0/50`, errors `50`, isolation `inconclusive`
- 100: `0/100`, errors `100`, isolation `inconclusive`

Error signatures in set #4:
- `sse_error_done`
- `stream_no_done`
- `exception`
- `url_error` (connection failures after gateway crash)

## Crash Evidence

Gateway crashed during set #4:
- crash file: `~/Library/Logs/DiagnosticReports/nullalis-2026-03-13-015734.ips`
- process: `nullalis` pid `93440`
- termination: `SIGABRT`

Crash stack shows heavy concentration in embeddings + TLS path during turn processing:
- `memory.vector.embeddings.OpenAiEmbedding.implEmbed`
- `memory.root.MemoryRuntime.syncVectorAfterStore`
- `http.Client.fetch`
- `crypto.tls.Client.readIndirect`

## Gate Decision

Decision: **HOLD (no rollout increase)**

Reason:
1. two-consecutive-set hard gate not satisfied.
2. isolation gate failed for 50/100 in set #3.
3. set #4 is invalid for promotion due runtime crash and mass request failures.

## Required Next Action

1. fix embedding transport crash path under concurrency (same class as prior native TLS failures; now in memory embedding flow).
2. rerun confirmatory two-set canaries after crash fix, preserving identical posture.
