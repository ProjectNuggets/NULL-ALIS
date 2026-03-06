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
- Files touched: `channel_loop.zig`, `daemon.zig`, `bus.zig`, `config_types.zig`, `config_parse.zig`, `gateway.zig`
- Branch: feature branch from `dogfood-stable`

### Agent B: Phase 2 — Transport Native & Connection Pooling
- See: `docs/scale-agent-b-phase2.md`
- Files touched: `http_native/`, `http_util.zig`, `tools/web_search.zig`, `tools/message.zig`, `gateway.zig` (metrics only)
- Branch: `transport-native-v1`

### Phase 2.5: Multi-Instance Readiness (after both merge)
- See: `docs/scale-phase-2-5-multi-instance.md`

**Zero file overlap between Agent A and Agent B** — they can work in parallel.

## Scale Projections

| Instances | Users | RAM Total | Notes |
|-----------|-------|-----------|-------|
| 1 | 1,000-2,000 | 500 MB-1 GB | After Phase 1+2 |
| 2 | 2,000-4,000 | 1-2 GB | After Phase 2.5 |
| 5 | 5,000-10,000 | 2.5-5 GB | Horizontal scaling |
| 10 | 10,000-20,000 | 5-10 GB | Horizontal scaling |

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

6. **Tenant lock already supports multi-instance** — file-based lease lock with TTL (300s). Postgres backend for shared state. Infrastructure for horizontal scaling exists.
