# Lock-Wait Stabilization Baseline

Date (UTC): 2026-03-16T11:19:47Z
Branch: `v0.7-open-beta-hardening`
Start SHA: `832ba34`

## Working Tree

`git status --short` at baseline: clean (no changes).

## Diagnostics Snapshot (before)

From `/internal/diagnostics` (local):

- `tenant_lock_backend=postgres_lease`
- `tenant_lock_lease_secs=90`
- `tenant_lock_wait_ms=600`
- `tenant_lock_retry_min_ms=25`
- `tenant_lock_retry_max_ms=100`
- `tenant_lock_conflicts_by_route`: all zero
- `heartbeat_runtime.available=false`

## Baseline Gates

1. `zig build test --summary all` -> pass (`4657/4678`, `21 skipped`)
2. `zig build -Dengines=base,sqlite,postgres` -> pass

## Notes

- Baseline captures pre-change lock configuration and health; lock-wait regression evidence will be captured in the post-change decision report.
