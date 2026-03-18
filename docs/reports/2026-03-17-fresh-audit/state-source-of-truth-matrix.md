# State Source-of-Truth Matrix

Date: 2026-03-17  
Purpose: clarify which persistence surface is authoritative in each runtime mode.

## Summary

The repository contains multiple persistence styles, but they are not all
intended to be co-authoritative at the same time. The key distinction is:

- `canonical state`: data that directly affects agent behavior
- `diagnostic state`: data used for ops, visibility, or debugging

## By Module

| Module | Store | Primary purpose | Canonical in tenant Postgres mode |
|---|---|---|---|
| [`src/zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig) | PostgreSQL | Tenant user/product state: config, secrets, heartbeat, onboarding, jobs, channel state, identities, leases, memory metadata | Yes |
| [`src/cron.zig`](/Users/nova/Desktop/nullalis/src/cron.zig) | `cron.json` | File-mode scheduler persistence and generic cron serialization helpers | No |
| [`src/daemon.zig`](/Users/nova/Desktop/nullalis/src/daemon.zig) | `daemon_state.json` | Daemon health/supervision snapshot for diagnostics | No |
| [`src/state.zig`](/Users/nova/Desktop/nullalis/src/state.zig) | `state.json` | Legacy/general runtime last-channel metadata helper | No |

## By Runtime Mode

### 1) Tenant + Postgres

Authoritative state:

- User config: [`src/zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig)
- Secrets: [`src/zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig)
- Heartbeat config/state inputs: [`src/zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig)
- Onboarding: [`src/zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig)
- Channel state / Telegram linkage: [`src/zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig)
- Jobs / scheduler claims: [`src/zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig)
- Identity bindings: [`src/zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig)

Non-canonical artifacts:

- `daemon_state.json`: diagnostics only
- `cron.json`: file-mode path, not the intended tenant Postgres authority
- `state.json`: not an active source of truth for tenant Postgres behavior

### 2) Tenant + File State

Authoritative state is file-backed per user under the tenant data root.

Examples:

- `config.json`
- `cron.json`
- `heartbeat.json`
- `channel_state.json`
- `telegram.json`
- `secrets/`

In this mode, there is no Postgres tenant authority layer.

### 3) Non-tenant / Generic Runtime

Authoritative state is generally workspace-local and file-backed unless a
specific backend is configured for a subsystem.

Examples:

- `cron.json` for scheduler jobs
- backend-specific memory stores
- `daemon_state.json` for supervision visibility

## Operational Rule

When tenant Postgres state is healthy, behavior should prefer
[`src/zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig) over
file artifacts for canonical user/product state decisions.

## Follow-up Direction

If we want stronger harmonization later, the next code step should be a thin
facade that centralizes storage authority decisions without changing the
underlying backends yet.
