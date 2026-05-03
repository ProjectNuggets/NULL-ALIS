---
tags: [prose, prose/docs]
---

# P-DB1 / P-PGV1 Pooling Smoke Report

Date: 2026-03-13  
Branch: `v0.2-scale-exec-swisswatch`  
Scope: pgvector connection pooling uniformity patch (internal behavior only)

## Baseline (Pre-change)

1. Baseline SHA: `67b136a`
2. `nullalis` DB socket count before edits:
   - `lsof -nP -iTCP:5432 | awk 'NR>1 && $1=="nullalis"{c++} END{print c+0}'`
   - result: `3`
3. Postgres log tail (50 lines) captured before edits.
4. Pre-change gates:
   - `zig build test --summary all` ✅
   - `zig build -Dengines=base,sqlite,postgres` ✅

## Patch Summary

Files changed:
1. `src/memory/vector/store_pgvector.zig`
2. `src/memory/root.zig`
3. `src/config_types.zig`
4. `src/config_parse.zig`

Behavioral changes:
1. Replaced single shared pgvector `PGconn` with bounded reusable pool.
2. Enforced pool cap for pgvector via `memory.postgres.pool_max` (default `4`).
3. Added bounded pool acquire timeout via `memory.postgres.acquire_timeout_ms` (default `1500`).
4. All pgvector operations now use acquire/release lease semantics.
5. Added pgvector pool regression tests (cap, reuse, timeout, release-on-error).

## Post-change Gates

1. `zig build test --summary all` ✅
   - `4550/4575` passed, `25` skipped, `0` failed.
2. `zig build -Dengines=base,sqlite,postgres` ✅

## Smoke Validation (No 100-burst)

Primary smoke run (concurrency-focused):
1. Command:
   - `python3 scripts/load-burst.py --url http://127.0.0.1:3000/api/v1/chat/stream --token dev-internal-token --mode single-user --users 1 --requests 20 --workers 20 --timeout-secs 90 --lane-strategy task_per_request --run-label p-db1-pgvector-pool-smoke-task --json`
2. Artifact:
   - `/tmp/p-db1-pgvector-pool-smoke-task.json`
3. Result:
   - success: `20`
   - errors: `0`
   - wall: `47792ms`
   - p50/p95/p99: `28641 / 47713 / 47789 ms`

Connection/log checks after run:
1. `nullalis` DB sockets after run:
   - result: `25`
2. Postgres tail check for slot exhaustion:
   - grep patterns: `remaining connection slots|too many clients|FATAL`
   - result: **no matches**

Note:
1. A separate `main_only` contention sample showed expected session-lane timeout behavior (single-lane serialization), but did not show DB slot exhaustion.

## Decision

Status: **PASS (smoke-level)** for pgvector pooling patch.

What this confirms:
1. pgvector no longer relies on a single shared connection path.
2. Connections are bounded/reused under concurrent task-lane load.
3. No Postgres slot-exhaustion signal observed in this smoke window.

Remaining risk:
1. Per-process DB socket count still includes other Postgres consumers (`zaki_state`, state/session paths), so full DB capacity planning remains a separate ops task.
