# Nullalis Scale Program: Phase 1 + Phase 2 + Horizontal Scaling

## Summary

Two parallel workstreams to push nullalis from ~200 user ceiling to 1,000-2,000 per instance, with horizontal scaling to 10,000+ via multiple instances. No reactor/async rewrite needed.

## Architecture (Current State)

- 25-35 OS threads, blocking I/O, Mutex+Condition queues
- TWO inbound processing models (polling channels bypass bus; gateway channels use bus)
- Single inbound dispatcher thread (all gateway channel messages serialized)
- Single outbound dispatcher thread
- curl subprocesses for HTTP (215+ calls)
- Native HTTP client exists but no connection pooling
- Bus capacity: 100 messages per direction

## Architecture (After Phase 1 + 2)

- Unified inbound model (all channels through bus)
- 4 parallel inbound workers (configurable)
- 2 parallel outbound workers (configurable)
- Native HTTP with connection pooling (keep-alive reuse)
- curl only for arbitrary user-supplied URLs
- Bus capacity: 1024 messages per direction
- Multi-instance ready via tenant lock + Postgres shared state

## Workstream Split

### Agent A: Phase 1 — Inbound Unification & Parallel Dispatch
- See: `docs/scale-agent-a-phase1.md`
- Files touched: `channel_loop.zig`, `daemon.zig`, `bus.zig`, `config_types.zig`, `config_parse.zig`
- Branch: feature branch from `main` (after `heartbeat-config-source` merges)

### Agent B: Phase 2 — Transport Native & Connection Pooling
- See: `docs/scale-agent-b-phase2.md`
- Files touched: `http_native/`, `http_util.zig`, `tools/web_search.zig`, `tools/message.zig`
- Branch: `transport-native-v1` (from `main`)

### Phase 2.5: Multi-Instance Readiness (after both merge)
- See: `docs/scale-phase-2-5-multi-instance.md`

### Shared File: `gateway.zig`

Both agents need to add diagnostics/metrics to `gateway.zig`. To avoid conflicts:
- **Agent A merges first**. Agent A adds bus queue depth fields to `internalDiagnosticsPayload()` (line ~2887).
- **Agent B rebases after Agent A merges**, then adds transport pool metrics to both `metricsPayload()` (line ~2668) and `internalDiagnosticsPayload()`.
- If timelines overlap, Agent B works only in `http_native/` and `http_util.zig` until Agent A's gateway changes are merged.

### Merge Order

1. Agent A merges Phase 1 into `main`
2. Agent B rebases `transport-native-v1` onto updated `main`, resolves any gateway.zig conflicts
3. Agent B merges Phase 2 into `main`
4. Phase 2.5 starts from updated `main`

## Scale Projections

| Instances | Users | RAM Total | Notes |
|-----------|-------|-----------|-------|
| 1 | 1,000-2,000 | 500 MB-1 GB | After Phase 1+2 |
| 2 | 2,000-4,000 | 1-2 GB | After Phase 2.5 |
| 5 | 5,000-10,000 | 2.5-5 GB | Horizontal scaling |
| 10 | 10,000-20,000 | 5-10 GB | Horizontal scaling |

### Throughput Caveats

- **Per-session mutex serializes turns**: `Session.mutex` (session.zig:38) is held for the entire agent turn (1-60s). Parallel inbound workers help different users run concurrently, but a single heavy user is always bounded by model latency. This is by design — turns for the same session must be sequential.
- **Effective parallelism = min(inbound_workers, active_users)**: 4 workers with 100 concurrent users means 4 users processed simultaneously. The remaining 96 queue in the bus.
- **Projections assume typical DTaaS load**: Bursty webhook traffic, not sustained high-QPS per user. For sustained high-QPS workloads (e.g., batch processing), the numbers are lower.

## Validation

Every step must pass:
```bash
zig build test --summary all    # all tests pass, 0 leaks
zig build -Doptimize=ReleaseSmall  # binary compiles clean
```

## Key Findings From Analysis

1. **Telegram/Signal/Matrix bypass the bus entirely** — they call `session_mgr.processMessageWithToolContext()` inline in their polling threads. This is the primary unification target.

2. **Single inbound dispatcher is the main bottleneck** — all Discord, Slack, IRC, Mattermost, iMessage messages are processed by ONE thread sequentially.

3. **Session mutex provides per-user serialization** — `Session.mutex` (session.zig:38) is held for the entire agent turn (1-60s). This means parallel workers naturally serialize on the same user while different users run in parallel.

4. **Native HTTP has no connection pooling** — `Connection: close` is hardcoded at `http_native/root.zig:308`. PoolConfig is defined in types.zig but unused.

5. **Bus capacity of 100 is too small** — at scale with proactive heartbeat + cron, this will backpressure constantly.

6. **Tenant lock needs shared storage for multi-instance** — file-based lease lock with TTL (300s) only works if all instances share the same filesystem (NFS/EFS). If pods use separate local disks, locks are not globally visible. Phase 2.5 must address this — either require shared storage or migrate locks to Postgres.

## Known Risks

1. **gateway.zig overlap**: Both agents touch this file. Strict merge order required (Agent A first).
2. **Telegram regression**: Phase 1 Step A3 changes the core Telegram message path. Channel-specific metadata (typing indicators, reply semantics, media handling, session key format) must be preserved exactly. See preservation checklist in `docs/scale-agent-a-phase1.md`.
3. **Tenant lock locality**: File-based locks only coordinate instances sharing the same filesystem. Kubernetes pods with separate PVCs will NOT see each other's locks.
4. **Per-session bottleneck**: Parallel workers do not help a single heavy user. Model latency (1-60s) is the hard floor per turn.
5. **Diagnostics constant drift**: Do not duplicate bus capacity values in gateway JSON. Read through a bus accessor to avoid stale constants after future changes.
6. **Worker cap mismatch**: If inbound/outbound worker counts are hard-capped in code (e.g., fixed array size), document and expose that cap clearly in config validation and diagnostics.
7. **Typing lifecycle leak**: Bus publish failures or long queue delays can leave Telegram typing indicators active unless stop/timeout cleanup is explicit on all error paths.
