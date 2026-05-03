---
tags: [prose, prose/docs]
---

# S3 Gateway Inbound Wiring (Telegram First) — 2026-03-12

## Objective
Apply centralized canonicalization before tenant Telegram webhook dispatch.

## Files
- `src/gateway.zig`
- `src/zaki_state.zig` (minor type safety fix surfaced during engine build)

## Implemented
### Pre-dispatch Canonicalization
- Tenant Telegram webhook path now:
  1. derives normalized identity (`principal_key`, `scope_key`, optional `thread_key`)
  2. calls `canonicalizeInboundTurn(...)`
  3. dispatches only with canonical/degraded decision session key
  4. strict-rejects unmapped inbound traffic with structured reason code

### Strict Reject Behavior
- On strict reject, webhook fails closed (no dispatch) and returns:
  - `403 Forbidden`
  - payload with structured code: `strict_identity_reject` + canonicalizer `reason_code`
- Best-effort user-visible Telegram explanation is sent for the rejected message.

### Mapping Coverage Improvement in Live Path
- For tenant Telegram private chats (`!is_group`) with known user scope:
  - webhook path upserts DB binding (channel/account/principal/scope/thread)
  - canonicalizer cache entry for that identity is invalidated immediately

This prevents stale cache misses after a new binding write.

## Gate Results
- `zig build test --summary all`: pass (`4528 passed`, `6 skipped`)
- `zig build -Dengines=base,sqlite,postgres`: pass

## Open Point
- S4 still pending: daemon/bus/polling paths must be moved to the same canonicalizer authority model.
