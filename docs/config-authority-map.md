# Configuration Authority Map (System / User / Admin)

This document is the canonical map for where config comes from, who owns it, and which API/flow to use.

## 1) Source Layers and Precedence

Highest precedence wins at runtime.

1. **Per-user tenant config (Postgres `user_config.config`)**
- Written via `GET/PATCH/PUT /api/v1/users/{id}/config`
- Runtime source in diagnostics: `effective_config_source=postgres_user_config`
- This is the authoritative layer for tenant user behavior.

2. **Seeded per-user config (from base file, one-time when DB user config is empty)**
- Runtime source in diagnostics: `effective_config_source=postgres_seeded_from_file`
- Happens during tenant runtime init when Postgres user config is `{}`/missing.

3. **File fallback per-user config**
- Path: `<tenant_data_root>/<user_id>/config.json`
- Runtime source in diagnostics: `effective_config_source=file_config_fallback`
- Used when Postgres state is unavailable/degraded.

4. **Base system config file**
- Default path: `~/.nullalis/config.json`
- Optional override path: `NULLALIS_CONFIG_PATH` (absolute path)
- Loaded by `Config.load()`.

5. **Environment overrides**
- `NULLCLAW_*` variables override parts of loaded config (provider/model/temperature/gateway/workspace/bind).

## 2) API Surfaces: What Each One Owns

### `/api/v1/users/{id}/config` (full per-user config)
- Full JSON object, power-user/admin surface.
- Correct endpoint for autonomy knobs, including:
  - `autonomy.max_actions_per_hour`

### `/api/v1/users/{id}/settings` (product UX subset)
- Limited user-facing settings (assistant mode, activation, proactive, voice, timeout).
- It maps into config (agent/session/memory/product_settings), but does **not** expose all config fields.
- Do **not** use `/settings` for autonomy throttles.

## 3) Admin vs User Responsibilities

### System/Admin owned
- Base config defaults (`~/.nullalis/config.json` in local/dev, deploy template in k8s).
- Env-level operational overrides (`NULLCLAW_*`).
- Deployment profile and secrets.

### User owned
- Per-user runtime behavior through `/api/v1/users/{id}/config`.
- Product-facing preference changes through `/api/v1/users/{id}/settings`.

## 4) Autonomy Limit: Correct Write Paths

### Per-user (recommended for immediate control)
```bash
TOK=$(jq -r '.gateway.internal_service_tokens[0]' ~/.nullalis/config.json)
BASE=http://127.0.0.1:3000
USER_ID=1

cfg=$(curl -sS -H "X-Internal-Token: $TOK" -H "X-Zaki-User-Id: $USER_ID" \
  "$BASE/api/v1/users/$USER_ID/config")

cfg2=$(printf '%s' "$cfg" | jq '.autonomy.max_actions_per_hour = 200')

curl -sS -X PATCH \
  -H "X-Internal-Token: $TOK" \
  -H "X-Zaki-User-Id: $USER_ID" \
  -H "Content-Type: application/json" \
  --data "$cfg2" \
  "$BASE/api/v1/users/$USER_ID/config"
```

### Global default (new users / base runtime)
- Set `autonomy.max_actions_per_hour` in base system config.
- Existing users with explicit per-user config keep their own value unless updated.

## 5) Runtime Truth Checks

Use diagnostics to verify effective state:

```bash
TOK=$(jq -r '.gateway.internal_service_tokens[0]' ~/.nullalis/config.json)
curl -sS -H "X-Internal-Token: $TOK" -H "X-Zaki-User-Id: 1" \
  http://127.0.0.1:3000/internal/diagnostics \
  | jq '{effective_config_source,effective_config_hash,memory_search_enabled,memory_summarizer_enabled,provider_retries}'
```

Interpretation:
- `runtime_not_loaded`: user runtime has not been initialized yet in this process.
- `postgres_user_config`: user config came from Postgres (expected steady state).
- `postgres_seeded_from_file`: first-run seed path.
- `file_config_fallback`: DB unavailable/degraded path.

## 6) Rate Limits: Ownership and Knobs

### A) Tool/action rate limit (per user runtime)
- Primary knob: `autonomy.max_actions_per_hour`
- Where to set:
  - per-user: `/api/v1/users/{id}/config`
  - global default: base config (`~/.nullalis/config.json`)
- Runtime behavior:
  - enforced by `RateTracker` in a 1-hour sliding window
  - when hit, tool preflight rejects calls (commonly surfaced as `Rate limit exceeded`)

### B) Gateway request rate limits (global operator config)
- `gateway.pair_rate_limit_per_minute`
- `gateway.webhook_rate_limit_per_minute`
- Set in base/deploy config (admin/operator layer), not user settings.

### C) Proactive/background rate limits (tenant policy)
- `tenant.proactive_rate_window_secs`
- `tenant.proactive_rate_limit_per_window`
- Operator-level tenant policy, affects proactive throughput.

## 7) Lock Limits: Ownership and Knobs

### A) Tenant ownership lock (cross-instance safety)
- Knobs (tenant config):
  - `tenant.ownership_lock_lease_secs`
  - `tenant.ownership_lock_wait_ms`
  - `tenant.ownership_lock_retry_min_ms`
  - `tenant.ownership_lock_retry_max_ms`
- Typical failure signal:
  - API/SSE error code `ownership_lock_conflict`
  - payload includes `retry_after_ms` (and optional owner/lease info)

### B) Session lock and queue contention (same-session concurrency)
- Signals:
  - turn stage `session_lock_wait`
  - warning log `session.lock_wait ... wait_ms=...`
- Main tuning knobs:
  - `agent.queue_mode`
  - `agent.queue_cap`
  - `agent.queue_drop`
- These are config-level behavior controls, not transport/provider errors.

## 8) Fast Triage: Config vs RateLimit vs Lock vs Error

Use this order:

1. **Check effective runtime config**
- `/internal/diagnostics`:
  - `effective_config_source`
  - `effective_config_hash`
- If unexpected source/hash, treat as config drift first.

2. **Check rate-limit path**
- If tool calls fail with `Rate limit exceeded`, inspect:
  - `/api/v1/users/{id}/config` -> `autonomy.max_actions_per_hour`
- If too low, update `/config` (not `/settings`).

3. **Check ownership-lock path**
- If errors contain `ownership_lock_conflict`, inspect diagnostics:
  - `tenant_lock_lease_secs`
  - `tenant_lock_wait_ms`
  - `tenant_lock_retry_min_ms`
  - `tenant_lock_retry_max_ms`
  - `tenant_lock_conflicts_by_route`
  - `tenant_lock_conflict_retries_total`

4. **Check session-lock/queue contention**
- If long waits without ownership conflict, inspect runtime logs for:
  - `session_lock_wait`
  - `session.lock_wait`
- Then verify queue policy for the user/runtime (`queue_mode/cap/drop`).

5. **Then treat remaining failures as runtime/provider errors**
- Example: upstream 5xx/503, timeouts, transport failures.

## 9) Recommended Diagnostics Query

```bash
TOK=$(jq -r '.gateway.internal_service_tokens[0]' ~/.nullalis/config.json)
curl -sS -H "X-Internal-Token: $TOK" -H "X-Zaki-User-Id: 1" \
  http://127.0.0.1:3000/internal/diagnostics \
  | jq '{
    effective_config_source,
    effective_config_hash,
    memory_search_enabled,
    memory_summarizer_enabled,
    provider_retries,
    tenant_lock_lease_secs,
    tenant_lock_wait_ms,
    tenant_lock_retry_min_ms,
    tenant_lock_retry_max_ms,
    tenant_lock_conflict_retries_total,
    tenant_lock_conflicts_by_route
  }'
```
