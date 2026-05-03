---
tags: [prose, prose/docs]
---

# S8 Stage 1 Root-Cause Isolation — 2026-03-12

Date: 2026-03-12  
Owner: Codex (runtime/platform)  
Scope: isolate Stage 1 (`telegram`) 100-user failure classes with deeper diagnostics

## Artifacts

1. `s8-rca-compat-100-v2.json`
2. `s8-rca-strict-telegram-100.json`
3. `s8-stage-1-100.json` (original rollback sample)

## Harness Upgrade Applied

`scripts/load-burst.py` was hardened to emit:
1. `error_details` buckets (`status_codes`, `exception_classes`, `detail_counts`)
2. `failure_samples` with `error_detail` and optional error body
3. optional diagnostics snapshots (`--capture-diagnostics`) before/after run
4. run labels (`--run-label`) for artifact attribution

This makes `http_error`/`exception` actionable instead of opaque.

## Findings

## A) Compat posture (`identity_mapping_enforcement = null`)

Artifact: `s8-rca-compat-100-v2.json`

1. `0/100` success, `100/100` errors.
2. Error split:
   - `84` `sse_error_done` with detail `chat_failed: chat failed`
   - `16` `http_error` status `409` with detail `ownership_lock_conflict`
3. Identity-mapping counters remained flat (`strict_rejected = 0`).

Interpretation:
1. Primary failure mode is provider chat failure under this burst.
2. Secondary failure mode is tenant ownership lease conflict.

## B) Strict posture (`staged_strict`, `["telegram"]`)

Artifact: `s8-rca-strict-telegram-100.json`

1. `0/100` success, `100/100` errors.
2. Error split:
   - `73` `exception` (`ConnectionResetError`)
   - `11` `sse_error_done` (`chat_failed: chat failed`)
   - `16` `stream_no_done`
3. Diagnostics after-run failed with `connection refused`.

Gateway log captured a runtime crash:
1. panic: `incorrect alignment`
2. stack points to:
   - `src/zaki_state.zig:1887` (`dupeResultValue`)
   - `src/zaki_state.zig:920` (`loadSessionMessages`)
   - `src/session.zig:159` (`getOrCreate`)
   - `src/gateway.zig:842` (`processMessage`)

Interpretation:
1. This is a general high-concurrency stability bug in session/message-load path.
2. Crash signature is unrelated to strict identity checks.

## Strict-Path Specificity Check

The canary profile uses `/api/v1/chat/stream` (internal API path).  
Current strict identity canonicalizer wiring is on inbound adapter flows (webhook/polling/daemon), not on this chat-stream route.

Result:
1. Stage-1 canary failures are not evidence of strict-canonicalizer regression.
2. Stage-1 strict promotion remains blocked, but blocker is runtime stability + provider/lease behavior under burst.

## Root Causes (ordered)

1. **Runtime crash under burst**  
   `incorrect alignment` panic in Postgres-backed message load path (`zaki_state.loadSessionMessages`).
2. **Provider saturation/failure path**  
   `chat_failed` dominates SSE failures in compat and strict samples.
3. **Lease contention path**  
   `ownership_lock_conflict` (`409`) appears in burst sample; likely stale/contended ownership leases during rapid restart/load windows.

## Immediate Remediation Plan

1. Fix crash first (P0):
   - patch `zaki_state` message-value duplication/alignment path
   - add targeted high-concurrency regression test around `loadSessionMessages`
2. Add lease diagnostics (P1):
   - include owner id + lease age counters in diagnostics snapshot
   - separate stale-lease vs active-conflict visibility
3. Split S8 validation tracks (P1):
   - keep `/api/v1/chat/stream` burst as general runtime stability gate
   - add channel-specific strict-path canary for Telegram webhook ingress
4. Re-run Stage 1 only after P0 + P1 pass.

## Decision

Status: **HOLD**  
Reason: root-cause isolated; strict promotion still blocked until crash + saturation paths are remediated and re-verified.
