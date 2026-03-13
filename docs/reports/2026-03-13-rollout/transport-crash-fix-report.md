# Transport Crash Fix Report (Embedding Path)

Date: 2026-03-13  
Owner: Codex (runtime/platform)  
Scope: fix gateway crash path under concurrency in embedding transport

## Issue

High-concurrency runs were crashing the gateway process (`SIGABRT`) with stacks repeatedly involving:
- `memory.vector.embeddings.OpenAiEmbedding.implEmbed`
- `http.Client.fetch`
- `crypto.tls.Client.readIndirect`

Crash artifact (pre-fix runtime):
- `~/Library/Logs/DiagnosticReports/nullalis-2026-03-13-020207.ips`

## Fix Implemented

Changed file:
- `src/memory/vector/embeddings.zig`

Change:
1. `OpenAiEmbedding.implEmbed` no longer uses `std.http.Client.fetch` directly.
2. It now routes embedding HTTP calls through:
   - `http_util.request_with_mode(..., .{ .mode = .curl_only }, .{ .subsystem = .providers, ... })`
3. Response/status handling behavior is preserved (same auth/policy/rejected error mapping semantics).

## Validation

Build gates:
1. `zig build test --summary all` -> pass (`4544` passed, `17` skipped)
2. `zig build -Dengines=base,sqlite,postgres` -> pass

Runtime repro (post-restart on patched binary):
1. 100-user burst replay executed (`/tmp/transport-fix-100-postrestart.json`).
2. Gateway stayed alive (`/health` remained `{"status":"ok"}`).
3. No newer crash report was generated after this run.

Transport counters:
- `nullalis_http_transport_native_total{subsystem="providers"} 0`
- `nullalis_http_transport_curl_total{subsystem="providers"} 1410`

This confirms provider-class transport is staying on curl path during the stress run.

## Current Decision Impact

The crash signature is mitigated for this path, but rollout remains `HOLD` because:
1. canary hard gates are still not met.
2. current failures are now dominated by upstream chat/provider errors (`chat_failed`) rather than process crash.

## Next Step

Re-run the two-set confirmatory canary cycle (20/50/100 with isolation probe) on this patched SHA and re-evaluate GO/HOLD/ROLLBACK.
