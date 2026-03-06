# Multi-Instance Deployment Guide

This guide covers running multiple `nullalis` instances for tenant scale-out.

## Scope

- Shared canonical state: Postgres (`state.backend=postgres`)
- Tenant ownership: file-based lease locks (`.nullalis-owner.lock`)
- App routing: ZAKI backend routes by `user_id`

## Critical Requirement: Shared Tenant Storage

Current ownership locks are file-based under each user root.  
For multi-instance correctness, all instances must see the same lock files.

Required for multi-instance mode:

1. Use a shared filesystem for `tenant.data_root` across pods/nodes (NFS/EFS/GlusterFS).
2. Do not use per-pod local disks for tenant roots in multi-instance mode.

If tenant roots are not shared, separate instances will not coordinate ownership and may double-process users.

## Setup

1. Point all instances to the same Postgres:
   `state.postgres.connection_string`
2. Use unique owner IDs:
   `NULLCLAW_OWNER_ID` per instance (or rely on `HOSTNAME` fallback).
3. Mount shared tenant root:
   `tenant.data_root` must be the same shared path for all instances.
4. Keep tenant mode enabled:
   `tenant.enabled=true`

## Routing Model (ZAKI Backend)

1. Chat SSE/API requests route by `user_id`.
2. Telegram webhooks include `user_id`; proxy routes to the corresponding instance.
3. Each instance exposes `/health`, `/ready`, `/metrics`.

## Failover

1. Ownership locks use lease TTL (`tenant_lock_lease_secs`, default 300s).
2. If an instance dies, its locks expire after TTL.
3. Other instances acquire orphaned users on subsequent scheduler/heartbeat sweeps.

For faster failover, reduce lease TTL (for example 60s) with care for clock skew and lock churn.

## Scale Operations

### Scale Up

1. Add new instance.
2. Ensure shared tenant mount + Postgres connectivity.
3. New instance starts claiming users naturally via lease locks.

### Scale Down

1. Drain instance traffic.
2. Stop instance.
3. Remaining instances reclaim users after lock TTL.

No manual user rebalancing is required with correct routing + shared lock storage.

## Diagnostics and Monitoring

Use `/internal/diagnostics` on each instance:

1. `instance_id`
2. `owned_users_count`
3. `tenant_lock_lease_secs`
4. `runtime_mode`, `bus`, `pool`
5. `startup_self_check` state backend + scheduler backend

Use `/metrics` for transport and gateway counters, including pool and lock-conflict metrics.

## Verification Checklist

1. `state_effective=postgres` in startup self-check logs
2. Distinct `instance_id` per instance
3. `owned_users_count` non-overlapping under steady load
4. No sustained increase in lock conflict metrics
5. Cron/heartbeat actions observed once per user window (no duplicates)

