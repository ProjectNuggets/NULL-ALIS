---
tags: [prose, prose/docs]
---

# Rollout Decision Report (Single Set Only: Set6)

Date: 2026-03-13  
Owner: Codex (runtime/platform)  
Scope: one-shot canary set only (no Set B), per operator instruction

## Run Posture

- Endpoint: `/api/v1/chat/stream`
- Token: `dev-internal-token`
- Isolation probe: user `1000`, count `3`, interval `250ms`
- Lane strategy by tier:
  - 20 users: `main_only`
  - 50 users: `mixed_real`
  - 100 users: `main_only`

Artifacts:
- `canary-set6-20.json`
- `canary-set6-50.json`
- `canary-set6-100.json`
- `set6-postrun-diagnostics.json`

## Results

20 users (`canary-set6-20.json`)
- success: `0/20` (error rate `100%`)
- latency: `p50=0ms`, `p95=0ms`, `p99=0ms`
- errors: `exception=5`, `stream_no_done=15`
- isolation gate: `inconclusive`

50 users (`canary-set6-50.json`)
- success: `0/50` (error rate `100%`)
- latency: `p50=0ms`, `p95=0ms`, `p99=0ms`
- errors: `http_error=15`, `sse_error_done=35`
- isolation gate: `inconclusive`

100 users (`canary-set6-100.json`)
- success: `0/100` (error rate `100%`)
- latency: `p50=0ms`, `p95=0ms`, `p99=0ms`
- errors: `http_error=15`, `sse_error_done=85`
- isolation gate: `inconclusive`

## Crash / Failure Evidence

Observed crash during set execution:
- file: `~/Library/Logs/DiagnosticReports/nullalis-2026-03-13-022030.ips`
- signal: `SIGABRT`
- faulting stack (top relevant frames):
  - `debug.FullPanic(...).memcpyAlias`
  - `mem.Allocator.dupe`
  - `agent.root.Agent.loadHistory`
  - `session.SessionManager.getOrCreate`
  - `gateway.TenantRuntime.processMessage`
  - `gateway.handleApiChatStreamSseConnection`

This is a runtime safety panic under concurrent history-load path, not a strict-channel policy failure.

Post-run diagnostics (`set6-postrun-diagnostics.json`):
- `tenant_lock_backend=postgres_lease`
- route lock conflicts observed (`chat_stream_sse`)
- identity-mapping counters stayed at `0` in this run (chat stream path, not webhook strict-ingress path)

## Decision

Decision: **HOLD** (no rollout increase)

Reason:
1. Single set has `100%` errors on all three tiers.
2. Crash still present under concurrent chat-stream path.
3. Isolation gate is inconclusive due run instability.

## Next Required Action (P0)

Patch and test the transport/runtime crash path in `Agent.loadHistory` (`memcpyAlias` / duplicate-buffer safety), then rerun one clean set with identical posture.
