# V1.8-7 Kimi Pass C audit — BLOCKED by gateway boot-time crash

**Date:** 2026-05-04 ~22:00 UTC
**Driver:** Claude
**Target:** verify Pass C extraction reachability on Kimi K2.5 with `agent.token_limit=8000` override
**Status:** ❌ BLOCKED. Audit could not run. Fresh gateway crashes deterministically on first real chat request.

---

## What was supposed to happen

1. Edit `/Users/nova/.nullalis/config.json` → set `agent.token_limit=8000` (triggers `token_limit_explicit=true`)
2. Restart gateway
3. Drive ~6-8 long-prompt turns to push context past 7,200 tokens (90% of 8K = Pass C trigger)
4. Watch for memory rows with key `compaction_summary/{session}/{ts}` (Pass C's audit signature per `compaction.zig:688`)
5. Snapshot memory_events table for new event_types

---

## What happened

### Attempt 1 — token_limit=8000 config
- Gateway boots fine (PID 25831, `/tmp/nullalis-gateway-v1.8-7.log`)
- T1 prompt sent (`Hello. My name is Nova...`)
- Gateway **panics** mid-request, process dies
- Curl receives `reply_start` SSE event but no body

### Attempt 2 — original config (token_limit unset)
- To rule out my edit as cause: restored config from `config.json.pre-v1.8-7-backup`
- Restarted (PID 26227, `/tmp/nullalis-gateway-v1.8-7-orig.log`)
- PROBE1 hit stale ownership-lease (no crash — short-circuited before reaching the buggy path)
- Waited 23s for lease expiry
- PROBE2 sent — gateway **panics** identically, process dies

### Attempt 3 — original config, second restart
- Started PID 26464
- PROBE3 hit stale lease from crashed PID 26227 (no crash — short-circuited)
- Did not wait for lease expiry; called the test conclusively deterministic at 2-for-2 fresh-gateway crashes

---

## Root cause (preliminary)

The panic site is identical in both attempts:

```
thread X panic: reached unreachable code
  std/debug.zig:559:14 in assert
  std/hash_map.zig:873:19 in putAssumeCapacityNoClobberContext
    assert(!self.containsContext(key, ctx))   // <-- fails
  std/hash_map.zig:1449 in grow
  std/hash_map.zig:1296 in growIfNeeded
  std/hash_map.zig:1115 in getOrPutContextAdapted
  std/hash_map.zig:1100 in getOrPutContext
  std/hash_map.zig:1026 in putContext
  std/hash_map.zig:1023 in put
  ...
  src/gateway.zig:1999:43 in getTenantRuntime
    const runtime = try TenantRuntime.init(state.allocator, config, user_ctx, ...)
  src/gateway.zig:9331:52 in handleApiChatStreamSseConnection
  src/gateway.zig:17030:45 in handleAcceptedConnection
```

Stack reaches **`grow`** during a HashMap put. Inside grow, `putAssumeCapacityNoClobberContext` asserts `!containsContext(key, ctx)` — but the key IS already present. This is a HashMap-internal invariant violation, not a duplicate `put` from caller code.

Diagnosis hypotheses (in order of likelihood):

1. **Adapted-context hash inconsistency**: `getOrPutContextAdapted` uses different hash/eq for lookup vs storage. If lookup says "not present" (so caller flow continues to grow + insert) but storage actually has the key under a different hash result, grow detects it during rebalance.
2. **Concurrent init race**: two threads racing to `getTenantRuntime` for the same user_id; both pass the existence check then both try to insert.
3. **Memory corruption**: use-after-free or stale pointer in the tenant_runtimes map state.

The hash_map TYPE is likely `std.HashMap` with custom context (Adapted) — could be string-key with case-sensitivity or interning issue.

---

## Why the previous gateway worked

Before this session, gateway PID 96786 had been running continuously and successfully completed:
- Original Phase 1 audit (12 prompts on DeepSeek)
- All M1-M6 SQL probes
- Stress testing
- Multiple `/memory` slash command invocations

→ The bug is **boot-state-specific**, not load-related. PID 96786 likely populated tenant_runtimes once successfully early in its life (race avoided by timing), and subsequent gateway restarts after `153da60` consistently lose that race.

This means: **the bug almost certainly was present at sha `153da60`** but the running gateway predated my reproduction attempt. Phases 0-4 docs commits did NOT introduce it (docs-only).

---

## Impact

- ❌ V1.8-7 cannot run (audit requires sending chat requests; gateway crashes on first one after restart)
- ⚠ Any user-facing gateway restart = 60s downtime per ownership-lease window before lease clears AND each next request crashes again
- ⚠ Production deployment is blocked on this. No restart-safe upgrade path.

---

## Recommendation for Nova

Promote this to **V1.8-0** (zero, predecessor of V1.8-1) — a stop-the-line stability fix. Triage path:

1. **Locate `state.tenant_runtimes` declaration** in gateway.zig — confirm hash-map type + context
2. **Inspect `TenantRuntime.init`** for any nested `put` into `state.tenant_runtimes` (could create the duplicate)
3. **Add temp logging** at `getTenantRuntime` entry: log user_id, current map size, hash result. Rebuild + repro.
4. **Mutex audit**: confirm tenant_runtimes mutations are guarded (likely `state.tenant_runtimes_mu` or similar). Race-condition fix is small.
5. **If Adapted hash mismatch**: probably a string-key normalization issue (e.g., user_id stored as `7777` vs stored as `"7777"` or with whitespace).

Estimated investigation: 2-4 hours; fix likely 5-30 LOC. Should land BEFORE V1.8-1 because the eval suite (V1.8-6) needs a working gateway to run repeated tests.

---

## Files captured

- `T0.snap.json` — pre-audit baseline (38 msgs, 63 mems, 9 entities, 10 edges, 102 events)
- `T1.sse` / `T1.meta` / `T1.reply` — attempt-1 truncated by crash
- `T1.snap.json` — pre-prompt = post-prompt (no state delta because crash)
- `panic-trace-attempt1-token_limit_8000.txt` — full Zig stacktrace, attempt 1
- `panic-trace-attempt2-original-config.txt` — full Zig stacktrace, attempt 2 (identical)
- `FINDINGS.md` — this document

---

## State at handoff

- Gateway PID 26464 currently RUNNING (started 22:00 UTC). Will crash on next non-lease-blocked chat request.
- `/Users/nova/.nullalis/config.json` restored to pre-edit state (no `token_limit` override).
- Backup at `/Users/nova/.nullalis/config.json.pre-v1.8-7-backup` retained for comparison.
- No code changes. No commits. No DB writes.
