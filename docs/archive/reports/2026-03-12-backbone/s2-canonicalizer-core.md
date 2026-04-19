# S2 Canonicalizer Core (2026-03-12)

## Objective
Introduce a single pre-dispatch canonicalizer module with explicit decisions and cache-backed DB lookups.

## Files
- `src/inbound_canonicalizer.zig`
- `src/channel_identity_key.zig`
- `src/zaki_session.zig`
- `src/root.zig`
- `src/config_types.zig`
- `src/config_parse.zig`

## Implemented
### Canonicalizer Module
- Added `canonicalizeInboundTurn(...)` with deterministic outcomes:
  - `canonical`
  - `degraded_compat`
  - `strict_reject`
- Added typed envelope:
  - `InboundIdentityEnvelope`
  - canonical lane enum `CanonicalSessionLane`

### Cache + Metrics
- Added positive and negative TTL caches in front of DB lookup.
- Added metrics snapshot:
  - mapped/unmapped/strict_rejected/degraded_compat
  - cache hit/miss/stale
  - DB lookup count and duration total

### Cache Safety
- Added explicit cache invalidation APIs:
  - `invalidateAllCache()`
  - `invalidateCacheForIdentity(...)`
- Fixed lock/error safety: no deferred unlock on already-unlocked mutex paths.

### Session Lane Builders
- Added canonical builders in `zaki_session`:
  - `userThreadSessionKey(...)`
  - `userTaskSessionKey(...)`
  - existing `userMainSessionKey(...)`, `userCronSessionKey(...)`

### Config Support
- Added tenant canonicalization controls:
  - `identity_mapping_enforcement`
  - `identity_mapping_strict_channels`
  - `identity_mapping_positive_ttl_secs`
  - `identity_mapping_negative_ttl_secs`

## Tests
- Added/updated unit tests for:
  - strict reject path when manager missing
  - strict reject path when identity keys missing
  - compat fallback when tenant mapping is not required
  - deterministic lane key builders

## Gate Results
- `zig build test --summary all`: pass
- `zig build -Dengines=base,sqlite,postgres`: pass

## Open Point
- Canonicalizer is implemented but not yet wired into all inbound dispatch paths (next slices S3/S4).
