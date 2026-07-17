---
tags: [prose, prose/docs]
---

# Control Plane Authority Map

This document is the canonical contract for who owns each class of config and which API or deploy surface is allowed to write it.

## 1) Control Planes

### Operator plane
- Owner: deploy/operator
- Authority: Helm-rendered runtime config
- Examples:
  - provider/model routing
  - embedding/search config
  - memory search, reliability, summarizer
  - dispatcher and parallel tools
  - TTS globals
  - Composio globals
  - gateway safety and tenant identity policy
  - assistant mode preset definitions

### Tenant preference plane
- Owner: user/product UX
- Authority: `GET|PATCH /api/v1/users/{id}/settings`
- Canonical stored shape: `product_settings`
- Current fields:
  - `assistant_mode`
  - `group_activation`
  - `proactive_updates`
  - `voice_replies`
  - `session_timeout_minutes`
  - `autonomy`
  - `dream_enabled`
  - `query_expansion_enabled`
  - `wish_matchmaking_enabled`
  - `selected_model`

| Field | Settings owner | Effective-runtime note |
|---|---|---|
| `assistant_mode` | Agent Runtime Defaults | Selects an operator-defined preset; it does not let a tenant redefine the preset. |
| `group_activation` | Channels / Agent Runtime Defaults | Controls when the agent responds in group channels. |
| `proactive_updates` | Legacy background-send compatibility field | Maps only to background agent message-tool `send_mode`; it does not start or stop heartbeat work and defaults off. ZAKI does not expose it as the proactive check-in control. |
| `voice_replies` | Channels | Enables replies for supported audio-capable channel turns. |
| `session_timeout_minutes` | Agent Runtime Defaults | Clamped to 5-180 minutes. |
| `autonomy` | Agent Runtime Defaults | Selects `read_only`, `supervised`, or `full` inside the operator security policy. |
| `dream_enabled` | Memory & Brain / Automations | Controls reconciliation of the canonical `dream_3am` job. |
| `query_expansion_enabled` | Memory & Brain | Adds the optional query-expansion stage and its associated model cost. |
| `wish_matchmaking_enabled` | Learning / privacy-controlled pilot | Default-off tenant consent for bounded wish-derived Decision Hub lookup. It must never be enabled fleet-wide for a pilot. |
| `selected_model` | Models & Providers | Selects only an engine-allowlisted model; operator provider credentials and routing remain operator-owned. |

### Per-user runtime plane
- Owner: Agent Settings → Proactive check-ins
- Authority: `GET|PUT /api/v1/users/{id}/heartbeat`
- Canonical state: `zaki_state` heartbeat JSON when the Postgres state manager is active;
  `heartbeat.json` is the file fallback/mirror
- Current writable fields: heartbeat `enabled` (default false; the engine also reads cadence/prompt from the
  canonical heartbeat document, but clients must not claim those controls until their BFF schema
  supports them)
- Derived, read-only response fields: operator availability, effective enablement, interval,
  Telegram delivery readiness, status, and `heartbeat_runtime.json` outcome
  (`last_run_s`, `last_status`, `last_reason`)

The heartbeat loop is effective only when the operator heartbeat worker is enabled **and** the per-user
heartbeat record is enabled. A tenant's `proactive_updates` preference is a separate intent field;
it is not an authority for the scheduler and must not be presented as proof that proactive delivery
ran. ZAKI ships the operator worker on, keeps each user's heartbeat off by default, and accepts an
explicit authenticated opt-in through the heartbeat route. The canonical and legacy Hub aliases use
the same handler. Heartbeat output is currently delivered only through a connected Telegram target;
it is not injected into ZAKI web chat. Cron jobs remain separately scheduled and separately revocable.

### Tenant integration plane
- Owner: user/channel onboarding flow
- Authority:
  - `/api/v1/users/{id}/secrets/*`
  - `/api/v1/users/{id}/channels/<channel>/connect`
  - `/api/v1/users/{id}/channels/<channel>/disconnect`
  - `/api/v1/users/{id}/channels/<channel>/bindings`
- Examples:
  - Telegram bot token
  - webhook URL and webhook secret
  - account/channel bindings
  - per-channel connection state

### Derived plane
- Owner: runtime only
- Authority: none
- Read path:
  - `/internal/diagnostics`
  - `zaki-prod` diagnostics relay `upstreamControlPlane`
- Examples:
  - configured/effective/source/drift
  - effective assistant mode
  - config hashes
  - degraded/runtime health
  - heartbeat last-run/status/reason and proactive status label

## 2) Rules

1. If a field changes platform/runtime behavior, it is operator-owned and must come from Helm.
2. If a field is a user behavior choice, it belongs in `/settings`.
3. If a field is a token, webhook, credential, account link, or channel setup record, it belongs in the channel/secrets/bindings surfaces.
4. If a field controls one user's live scheduler instance, it belongs in the dedicated per-user runtime API, not in `product_settings` or Helm.
5. Derived fields are never persisted as authority and are never user-writable.
6. New channels must use dedicated `connect`/`disconnect` flows with channel-specific validation.
7. New global features must add explicit Helm values, rendered runtime config, diagnostics coverage, and validation checks.
8. A product-wide launch pause must be enforced at the authenticated product boundary; a disabled UI control alone is not enforcement.

## 3) `/config` Contract

`/api/v1/users/{id}/config` is no longer a write authority.

- `GET` returns the normalized tenant-owned overlay only.
- `PATCH|PUT` returns `raw_config_writes_disabled`.

This endpoint exists only for inspection/debug during the migration away from the legacy mixed config blob.

## 4) Runtime Precedence

Highest precedence wins at runtime.

1. Operator base config from Helm
2. Operator-owned preset expansion selected by `assistant_mode`
3. Tenant preference overlay from `product_settings`
4. Tenant integration state from secrets/channels/bindings
5. Per-user runtime state from dedicated APIs such as `/heartbeat`
6. Derived runtime state

No other mutation path is authoritative.

## 5) Verification

Use diagnostics to verify the final resolved state:

```bash
TOK=$(jq -r '.gateway.internal_service_tokens[0]' ~/.nullalis/config.json)
curl -sS \
  -H "X-Internal-Token: $TOK" \
  -H "X-Zaki-User-Id: 1" \
  http://127.0.0.1:3000/internal/diagnostics \
  | jq '.control_plane'
```

Expected steady state:
- operator-owned controls show `"owner":"operator"`
- `configured` and `effective` match unless a documented derived projection applies
- `drift` is `false`
- tenant preference fields are visible through `/settings`, not through raw operator config
- heartbeat enablement comes from `/heartbeat`; `product_settings.proactive_updates` alone never
  proves that proactive delivery is active
