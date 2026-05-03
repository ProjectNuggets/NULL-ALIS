---
tags: [prose, prose/docs]
---

# Lock-Wait Stabilization Decision

Date: 2026-03-16  
Branch: `v0.7-open-beta-hardening`

## Scope Completed

1. Background/main lane guard added for cron execution:
   - non-user cron turns targeting `main` are forced to `isolated`.
2. Additive diagnostics for reroutes:
   - `background_main_reroutes_total`
   - `background_main_reroutes_last_job_id`
3. Runtime profile applied in `~/.nullalis/config.json`:
   - `agent.message_timeout_secs=120`
   - `agent.queue_mode="serial"`
   - `agent.queue_cap=0`
   - `tenant.ownership_lock_lease_secs=90`
   - `tenant.ownership_lock_wait_ms=500`
   - `tenant.ownership_lock_retry_min_ms=25`
   - `tenant.ownership_lock_retry_max_ms=80`

## Gates

1. `zig build test --summary all` -> pass (`4661/4682`, `21 skipped`)
2. `zig build -Dengines=base,sqlite,postgres` -> pass

## Smoke Evidence

Artifacts:

1. `smoke-main-only.json`
2. `smoke-thread-per-request.json`

Results:

1. `main_only` (single-user, 2 req, 1 worker, 60s timeout):
   - success: 2
   - errors: 0
   - p95: 12990 ms
2. `thread_per_request` (single-user, 2 req, 1 worker, 60s timeout):
   - success: 2
   - errors: 0
   - p95: 23093 ms

## Runtime Verification (fresh gateway on `127.0.0.1:3001`)

Diagnostics confirmed:

1. `tenant_lock_lease_secs=90`
2. `tenant_lock_wait_ms=500`
3. `tenant_lock_retry_min_ms=25`
4. `tenant_lock_retry_max_ms=80`
5. `background_main_reroutes_total=0` (no main-target background jobs were present in this smoke run)

## Notes / Residuals

1. Existing live gateway on `:3000` must be restarted to pick up new config values from `~/.nullalis/config.json`.
2. Reroute counter is implemented and tested, but remained zero during smoke because no legacy/background jobs targeting `main` executed in this run.
3. Queue policy is intentionally no-drop (`serial` + `cap=0`); under heavy bursts, latency can increase while preserving message integrity.
