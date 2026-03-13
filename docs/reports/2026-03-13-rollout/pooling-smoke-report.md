# P-DB1 Pooling Smoke Report (2026-03-13)

## Scope
- Patch: bounded `zaki_state` Postgres connection pool (`state.postgres.pool_max` enforced).
- Validation mode: smoke-only (no 100-burst rerun).

## Phase 0 Baseline Evidence
- Branch/SHA at start: `v0.2-scale-exec-swisswatch` / `747cd7f`.
- Pre-change Postgres sockets held by `nullalis`:
  - `lsof -nP -iTCP:5432 | awk 'NR>1 && $1=="nullalis"{c++} END{print c+0}'`
  - Result: `34`
- Baseline Postgres log evidence (historical):
  - `tail -n 50 /opt/homebrew/var/log/postgresql@17.log`
  - Contains repeated `remaining connection slots are reserved for roles with the SUPERUSER attribute`.

## Gate Results (Pre-change)
- `zig build test --summary all` ✅
- `zig build -Dengines=base,sqlite,postgres` ✅

## Implementation Summary
- Removed thread-local libpq ownership from `src/zaki_state.zig`.
- Added manager-owned bounded pool with:
  - hard cap (`pool_max`, clamped 1..256)
  - acquire/release + timed wait path
  - pooled connection reuse
  - unhealthy-connection retirement on release
- Rewired `exec`, `execMigrateStatement`, `execParams` to pool leases.
- Added regression tests:
  - `postgres_pool_enforces_cap_under_concurrency`
  - `postgres_pool_reuses_connections`
  - `postgres_pool_timeout_when_exhausted`
  - `postgres_pool_releases_on_exec_error`

## Gate Results (Post-change)
- `zig build test --summary all` ✅
- `zig build -Dengines=base,sqlite,postgres` ✅

## Smoke Validation

### Notes
- Initial smoke attempt with host-only URL returned 404 (`/api/v1/chat/stream` path missing) and was discarded.
- A high-contention same-lane run (`30 req / 20 workers`) showed request timeouts as expected from session-lane serialization, but no DB slot exhaustion.

### Recorded smoke runs
1. `p-db1-pool-smoke-v2` (`10 req / 4 workers / single user / main lane`)
   - Output: `/tmp/p-db1-pool-smoke-v2.json`
   - Result: `success=9`, `errors=1` (single timeout), `wall_ms=142844`
2. `p-db1-pool-smoke-v3` (`6 req / 2 workers / single user / main lane`)
   - Output: `/tmp/p-db1-pool-smoke-v3.json`
   - Result: `success=6`, `errors=0`, `wall_ms=157630`

### DB socket boundedness
- Pre-smoke (`v2`): `3`
- Post-smoke (`v2`): `5`
- Post-smoke (`v3`): `5`
- Observation: connection count remained bounded and far below prior saturation levels.

### Postgres log check
- Log baseline line index captured before smoke: `7294`
- New lines scanned after smoke:
  - `sed -n "$((START+1)),999999p" /opt/homebrew/var/log/postgresql@17.log`
- `remaining connection slots...` occurrences in new lines: `0`
- Remaining observed noise: known migration warning `permission denied for table zaki_users`.

## Conclusion
- P-DB1 objective met for smoke scope:
  - no unbounded `zaki_state` connection growth observed,
  - no new Postgres slot-exhaustion events during smoke window,
  - build/test gates remained green.
- Deferred by design:
  - `pgvector` pooling changes,
  - 100-burst validation rerun.
