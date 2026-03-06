# Phase 2.5: Multi-Instance Readiness

## Prerequisites

Both Phase 1 (Agent A) and Phase 2 (Agent B) must be merged into `dogfood-stable` before starting this phase.

## Context

nullalis already has infrastructure for multi-instance deployment:
- `src/tenant_lock.zig` — file-based lease lock per user with TTL (300s default)
- `src/zaki_state.zig` — Postgres backend for canonical tenant state (shared DB)
- Per-user session isolation via `Session.mutex`
- Per-user runtime cache in gateway (`tenant_runtime_cache_max_users: 2048`)

What needs fixing:
- Cron and heartbeat sweep ALL user directories regardless of ownership
- No instance_id in diagnostics
- No deployment documentation
- **Critical**: File-based tenant locks only coordinate instances that share the same filesystem. If Kubernetes pods use separate local disks (emptyDir, local PVC), each instance's lock files are invisible to others. This must be addressed before multi-instance is viable.

## Multi-Instance Architecture

```
ZAKI Backend (routes by user_id)
    |
    +-- nullalis-1  (users 1-500, owns via tenant_lock)
    +-- nullalis-2  (users 501-1000, owns via tenant_lock)
    +-- nullalis-3  (users 1001-1500, owns via tenant_lock)

Shared: Postgres (canonical state)
Each instance: ~3MB binary, ~500MB RAM for 500 users
```

## Steps

### Step M0: Resolve Tenant Lock Storage

**Goal**: Ensure tenant locks work across multiple instances.

**Problem**: `tenant_lock.zig` uses file-based lease locks (`.nullalis-owner.lock` per user directory). This only coordinates instances that share the same filesystem. Kubernetes pods with separate local disks will NOT see each other's locks.

**Options**:
- **(a) Require shared filesystem** (NFS, EFS, GlusterFS): Simplest. All instances mount the same `tenant.data_root`. File locks work as-is. Downside: shared filesystem is a dependency and potential bottleneck.
- **(b) Migrate locks to Postgres**: Add a `tenant_locks` table to `zaki_state.zig`. Use `INSERT ... ON CONFLICT` with TTL column for lease semantics. All instances share the database already. Downside: more code, Postgres becomes a hard dependency for multi-instance.
- **(c) External coordination** (Redis, etcd, Consul): Overkill for this stage. Defer.

**Recommendation**: Option (a) for initial multi-instance. Option (b) as follow-up when Postgres is already canonical state backend.

**Actions**:
1. Document the shared filesystem requirement in deployment docs.
2. If Postgres lock migration is chosen: add `tenant_locks` table with columns `(user_id, owner_id, lock_token, expires_at)`. Implement `acquireUserOwnershipLock()` and `release()` as SQL operations. Keep file-based lock as fallback for single-instance mode.

**Acceptance**: Lock strategy documented. If Postgres: lock table created and tested.

---

### Step M1: Cron Respects Tenant Lock

**Goal**: Cron scheduler only runs jobs for users owned by this instance.

**Files to modify**: `src/daemon.zig` — `schedulerThread` and tenant cron sweep

**Actions**:
1. In the cron execution path (daemon.zig, inside `schedulerThread`), before running a job for a user, call `tenant_lock.acquireUserOwnershipLock()`.
2. If returns `error.LockHeld`, skip that user's jobs — another instance owns them.
3. If lock acquired, proceed with job execution as normal.
4. Same pattern for heartbeat sweep — before running heartbeat for a user, check ownership.
5. Add test: two simulated instances, verify no duplicate job execution.

**Acceptance**: Cron only runs jobs for owned users. `zig build test --summary all` passes.

---

### Step M2: Instance Diagnostics

**Goal**: Add instance identity to diagnostics.

**Files to modify**: `src/gateway.zig` — diagnostics endpoint

**Actions**:
1. Add `"instance_id"` to diagnostics JSON — from `tenant_lock.resolveOwnerId()`.
2. Add `"owned_users_count"` — count of users this instance has active locks for.
3. Add `"tenant_lock_lease_secs"` — current TTL setting.

**Acceptance**: Diagnostics shows instance identity. `zig build test --summary all` passes.

---

### Step M3: Document Multi-Instance Deployment

**Goal**: Operational documentation for running N instances.

**Actions**:
Create `docs/multi-instance.md` covering:

1. **Setup**: How to run N instances with shared Postgres
   - All instances point to same `state.postgres.connection_string`
   - Each instance gets unique `NULLCLAW_OWNER_ID` env (or auto-generates from hostname)
   - Separate `tenant.data_root` or shared NFS/EFS mount

2. **User routing**: ZAKI backend routes by user_id
   - Chat SSE: route to instance owning the user
   - Telegram webhooks: webhook URL contains user_id, ZAKI backend routes accordingly
   - Health: each instance exposes `/health`

3. **Failover**: Tenant lock TTL handles instance death
   - Default TTL: 300s (5 minutes)
   - Dead instance's locks expire after TTL
   - Surviving instances pick up orphaned users on next sweep
   - Reduce TTL to 60s for faster failover (configurable)

4. **Scaling up/down**:
   - Add instance: new instance auto-claims unowned users
   - Remove instance: users redistributed after lock TTL
   - No manual rebalancing needed

5. **Monitoring**:
   - Per-instance: `/internal/diagnostics` shows instance_id, owned_users_count
   - Cross-instance: Prometheus scrape all instances, alert on unowned users

**Acceptance**: Documentation committed and reviewed.
