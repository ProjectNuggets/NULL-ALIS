---
tags: [prose, prose/docs]
---

# State Alignment Panic Fix Report (`zaki_state`)

Date: 2026-03-13  
Owner: Codex (runtime/platform)  
Scope: fix `incorrectAlignment` abort in Postgres message-load path

## Issue

Gateway crash (`SIGABRT`) showed:
- `debug.FullPanic.incorrectAlignment`
- `zaki_state.dupeResultValue`
- `zaki_state.ManagerImpl.loadSessionMessages`

Crash evidence:
- `~/Library/Logs/DiagnosticReports/nullalis-2026-03-13-020207.ips`

## Fix Implemented

Changed:
- `src/zaki_state.zig`

Details:
1. `dupeResultValue` no longer duplicates by slicing `PQgetvalue` directly.
2. It now:
   - reads `PQgetlength`
   - casts source pointer to `[*]align(1)const u8`
   - allocates destination bytes
   - copies with `@memcpy`
3. Added regression test:
   - `dupeResultValue byte-copy path tolerates misaligned source pointers`

## Validation

Build/test gates:
1. `zig build test --summary all` -> pass (`4546` passed, `17` skipped)
2. `zig build -Dengines=base,sqlite,postgres` -> pass

Runtime replay after restart on patched binary:
1. 100-user burst replay executed (`/tmp/post-fix-zakistate-100.json`).
2. No new crash report file was generated.
3. Gateway remained healthy (`/health` returned `{"status":"ok"}`).

Observed result profile in this replay:
- requests failed as `sse_error_done` with `chat_failed: chat failed` (provider/runtime failure mode),
- but no process abort.

## Conclusion

`zaki_state` alignment panic path is mitigated on this SHA.  
Rollout remains `HOLD` due provider/chat failure gates, not gateway crash.
