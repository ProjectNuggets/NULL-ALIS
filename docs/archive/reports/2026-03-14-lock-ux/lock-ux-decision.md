# Lock UX Hardening Decision — 2026-03-14

## Scope

Implemented:
- bounded tenant lock wait with jitter (`tenant.ownership_lock_*` knobs),
- structured `ownership_lock_conflict` payload,
- `Retry-After` on conflict HTTP responses,
- SSE conflict payload includes retry metadata,
- additive conflict retry counter,
- BFF retry contract doc for T6.

## Validation Gates

- `zig build test --summary all` ✅  
  `4622 passed / 21 skipped / 0 failed`
- `zig build -Dengines=base,sqlite,postgres` ✅

## Two-Node Smoke (Contention)

Setup:
- node A: `NULLCLAW_OWNER_ID=lock-node-a`, port `3101`
- node B: `NULLCLAW_OWNER_ID=lock-node-b`, port `3102`
- same user: `user_id=1`

Conflict request on node B during active node A workload:

```http
HTTP/1.1 409 Conflict
Content-Type: application/json
Content-Length: 176
Retry-After: 2
Connection: close

{"error":"ownership_lock_conflict","message":"user is active on another node, retry shortly","retry_after_ms":2000,"owner_instance_id":"lock-node-a","lease_until_s":1773491317}
```

Post-contention retry on node B:

```json
{"status":"updated"}
```

## Diagnostics Snapshot

Node A:
- `instance_id=lock-node-a`
- `tenant_lock_backend=postgres_lease`
- `tenant_lock_conflict_retries_total=0`

Node B:
- `instance_id=lock-node-b`
- `tenant_lock_backend=postgres_lease`
- `tenant_lock_conflict_retries_total=165`
- `tenant_lock_conflicts_by_route.api=11`

## Decision

**GO** for T6 integration.

Rationale:
1. Lock conflicts are now machine-actionable.
2. Conflict responses carry deterministic retry metadata.
3. Runtime stability preserved (no panic/crash regressions).
4. Contract for BFF retry is documented and implementation-ready.

## Residual Risks

1. If sticky routing is absent, high contention can still produce repeated `409`s (now retriable).
2. User-facing smoothness still depends on BFF retry behavior (documented for T6, not implemented in this repo).
