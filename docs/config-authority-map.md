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

## 2) Rules

1. If a field changes platform/runtime behavior, it is operator-owned and must come from Helm.
2. If a field is a user behavior choice, it belongs in `/settings`.
3. If a field is a token, webhook, credential, account link, or channel setup record, it belongs in the channel/secrets/bindings surfaces.
4. Derived fields are never persisted as authority and are never user-writable.
5. New channels must use dedicated `connect`/`disconnect` flows with channel-specific validation.
6. New global features must add explicit Helm values, rendered runtime config, diagnostics coverage, and validation checks.

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
5. Derived runtime state

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
