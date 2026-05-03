---
tags: [prose, prose/docs]
---

# S1 DB Identity Mapping Core (2026-03-12)

## Objective
Make channel identity mapping DB-authoritative in `zaki_state`, with deterministic upsert/resolve/list/delete semantics.

## Files
- `src/zaki_state.zig`
- `src/config_types.zig`
- `src/config_parse.zig`
- `src/zaki_session.zig`
- `src/inbound_canonicalizer.zig`
- `src/root.zig`

## Implemented
### Schema + Indexes
- Added `channel_identity_bindings` table in Postgres migration path.
- Added unique lookup and hot-path indexes:
  - unique `(channel, account_id, principal_key, scope_key, thread_key_norm)`
  - user/channel index
  - lookup index

### State APIs
- Added manager methods:
  - `upsertChannelIdentityBinding(...)`
  - `resolveUserByChannelIdentity(...)`
  - `listChannelIdentityBindings(...)`
  - `deleteChannelIdentityBinding(...)`
  - `listTelegramBackfillCandidates(...)`

### Quality/Safety Hardening
- Fixed partial-allocation cleanup in list APIs (initialized-count cleanup, no invalid free).
- Removed silent parse fallbacks (`catch 0`) for mapping rows.
- Added nullable result helper for optional columns.

### Tests
- Added integration test:
  - `postgres channel identity bindings upsert resolve list delete and backfill candidates`

## Gate Results
- `zig build test --summary all`:
  - passed: `4528`
  - skipped: `6`
  - failed: `0`
- `zig build -Dengines=base,sqlite,postgres`:
  - success

## Risks/Open Points
- Backfill execution against live tenant data is operational follow-up (S0.5 artifact defines manual review queue).
- Canonicalizer wiring into inbound dispatch paths is next slice (S3/S4).
