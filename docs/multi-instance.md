---
tags: [prose, prose/docs]
---

# Multi-Instance Deployment Guide

This guide covers running multiple `nullalis` instances for tenant scale-out.

## Scope

- Shared canonical state: Postgres (`state.backend=postgres`)
- Tenant ownership arbitration:
  - Postgres lease table (`tenant_user_leases`) when `state_effective=postgres`
  - file lease fallback (`.nullalis-owner.lock`) when runtime is file mode
- App routing: ZAKI backend routes by `user_id`

## Ownership Backend Model

The gateway uses one ownership backend at runtime:

1. `postgres_lease` (preferred):
- enabled when tenant mode is on and effective state backend is Postgres.
- lock ownership is coordinated through `{schema}.tenant_user_leases`.
- no shared filesystem is required for lock correctness.

2. `file_lock` (fallback/file mode):
- lock ownership is coordinated via lock files under each user root.
- requires shared `tenant.data_root` across instances for correctness.

Operational rule:
1. In tenant+Postgres production, ownership arbitration should report `tenant_lock_backend=postgres_lease`.
2. If it reports `file_lock`, treat deployment as degraded for multi-instance ownership safety until corrected.

## Setup

1. Point all instances to the same Postgres:
   `state.postgres.connection_string`
2. Use unique owner IDs:
   `NULLALIS_OWNER_ID` per instance (or rely on `HOSTNAME` fallback).
3. Tenant root strategy:
   - Postgres ownership mode: shared root optional for lock correctness, but recommended if you need cross-node workspace/file portability.
   - File-lock mode: shared root required (`tenant.data_root` must be identical across nodes).
4. Keep tenant mode enabled:
   `tenant.enabled=true`

## Routing Model (ZAKI Backend)

1. Chat SSE/API requests route by `user_id`.
2. Telegram webhooks include `user_id`; proxy routes to the corresponding instance.
3. Each instance exposes `/health`, `/ready`, `/metrics`.

## Failover

1. Ownership uses lease TTL (`tenant_lock_lease_secs`, default 300s) for both backends.
2. If an instance dies, leases expire after TTL.
3. Other instances acquire orphaned users on subsequent scheduler/heartbeat sweeps.

For faster failover, reduce lease TTL (for example 60s) with care for clock skew and lock churn.

## Scale Operations

### Scale Up

1. Add new instance.
2. Ensure Postgres connectivity and unique owner ID.
3. If using file-lock mode, ensure shared tenant mount.
4. New instance starts claiming users naturally via lease locks.

### Scale Down

1. Drain instance traffic.
2. Stop instance.
3. Remaining instances reclaim users after lock TTL.

No manual user rebalancing is required with correct sticky routing and ownership arbitration.

## Diagnostics and Monitoring

Use `/internal/diagnostics` on each instance:

1. `instance_id`
2. `owned_users_count`
3. `tenant_lock_backend`
4. `tenant_lock_lease_secs`
5. `runtime_mode`, `bus`, `pool`
6. `startup_self_check` state backend + scheduler backend

Use `/metrics` for transport and gateway counters, including pool and lock-conflict metrics.

## Verification Checklist

1. `state_effective=postgres` in startup self-check logs
2. Distinct `instance_id` per instance
3. `tenant_lock_backend=postgres_lease` for tenant+postgres production
4. `owned_users_count` non-overlapping under steady load
5. No sustained increase in lock conflict metrics
6. Cron/heartbeat actions observed once per user window (no duplicates)

> Env-var note (2026-07-11): `NULLALIS_OWNER_ID` is primary; legacy `NULLCLAW_OWNER_ID` remains a supported fallback.
