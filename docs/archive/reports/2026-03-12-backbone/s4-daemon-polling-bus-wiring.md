---
tags: [prose, prose/docs]
---

# S4 — Daemon + Polling + Bus Canonicalization Wiring

## Objective
Unify non-webhook inbound paths so bus/polling inbound messages are canonicalized before dispatch in tenant+Postgres mode.

## Files Changed
- `src/daemon.zig`

## Implementation
- Added inbound canonicalization in `inboundDispatcherThread` before `processMessageWithToolContext`.
- Added per-dispatcher Postgres state manager initialization for canonicalizer DB mapping lookups.
- Added strict-reject handling for unmapped strict channels with explicit user-facing outbound message.
- Preserved explicit degraded compatibility path through canonicalizer decision output.
- Injected `state_mgr` into tool tenant context for bus-inbound turns.

## Tests Added
- `resolveInboundCanonicalSessionKey returns fallback in non-tenant mode`
- `resolveInboundCanonicalSessionKey strict rejects unmapped telegram when manager missing`

## Gates
- `zig build test --summary all` ✅
- `zig build -Dengines=base,sqlite,postgres` ✅

## Risks / Open Points
- Strict reject messaging is currently generic across channels; channel-specific phrasing can be refined later.
- Non-strict channels still intentionally allow degraded compatibility fallback during staged rollout.
