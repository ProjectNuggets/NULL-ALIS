# nullALIS — SOTA Agent Runtime

## Vision

nullALIS (ZAKI BOT) is a Zig-native agent runtime that delivers a best-in-class persistent digital twin. The target product is:

> "Claude Code quality execution and coding workflow, with OpenClaw quality online control-plane and always-on session model, delivered through Nullalis."

## Product Identity

- **Nullalis = ZAKI BOT** — one persistent personal agent per user
- **Postgres is canonical state** — filesystem workspace remains first-class
- **Digital Twin Core first** — then network, marketplace, inheritance (plan.md Tracks B-G)

## Technical Stack

- **Language:** Zig (single binary, no GC, minimal footprint)
- **Architecture:** Per-user cell pods with tenant isolation
- **Transport:** HTTP + SSE (primary), WebSocket where channel protocols require it
- **Storage:** Postgres (canonical) + SQLite + markdown mirror
- **Memory:** 10+ backends, 9-stage retrieval pipeline, vector plane with circuit breakers
- **Channels:** 19 implementations (Telegram, Discord, Slack, WhatsApp, Signal, Matrix, etc.)
- **Tools:** 42 tool implementations via vtable dispatch
- **Security:** 5 sandbox backends, encrypted secrets, audit logging

## Constraints

1. Zig runtime core — no rewrite to another language
2. Multitenant safety — per-user isolation is non-negotiable
3. Pod-isolated execution — cell architecture stays
4. API/SSE/CLI-first — no WebSocket-only paths for core
5. Additive API changes only — no breaking changes without explicit approval
6. `zig build test --summary all` must pass on every branch
7. `zig build -Doptimize=ReleaseSmall` must succeed on every branch

## What Already Works

- M1 (Kernel UX) — complete and merged
- M2 (Context Introspection) — complete and merged
- Per-user cell pods — production
- 19 channel implementations — production
- 42 tools — production
- Memory pipeline (10+ backends, 9-stage retrieval) — production
- Voice/STT for Telegram — production
- Hardware/IoT tools (I2C, SPI, MaixCam) — production

## Source Documents

- `docs/sota-agent-feature-map.md` — competitive analysis and feature inventory
- `docs/sota-agent-roadmap.md` — full sprint plan with dependencies
- `/Users/nova/Downloads/plan.md` — long-term vision (Tracks A-G)
