---
tags: [prose, prose/docs]
---

# v1 Productization Plan (Multi-User, User-Facing BOT)

Status: implementation-ready  
Date: 2026-03-13  
Owner: platform + BFF + frontend

## 1) Product Decision Baseline

1. Launch model: managed B2B.
2. Control plane: ZAKI API BFF (frontend never talks to gateway directly).
3. User settings UX: simple presets only.
4. Telegram model in v1: per-user bot token onboarding.
5. Monetization in v1: metering + soft limits.
6. Hard entitlements/billing enforcement: v1.1.

## 2) Runtime/Gateway Ground Truth (This Repo)

Already available as internal APIs in gateway:
1. `POST /api/v1/users/provision`
2. `GET /api/v1/users/{user_id}/onboarding`
3. `PUT /api/v1/users/{user_id}/onboarding`
4. `PATCH /api/v1/users/{user_id}/config`
5. `POST /api/v1/chat/stream`
6. `POST /api/v1/users/{user_id}/channels/telegram/connect`
7. `POST /api/v1/users/{user_id}/channels/telegram/disconnect`
8. `DELETE /api/v1/users/{user_id}/channels/telegram/disconnect`

Internal security boundary:
1. `/api/v1/*` requires `X-Internal-Token`.
2. Tenant chat path requires `X-Zaki-User-Id`.
3. Gateway remains private/internal network only.

## 3) v1 Target Architecture

1. Frontend -> BFF only.
2. BFF authenticates user, resolves internal `user_id`.
3. BFF -> gateway with `X-Internal-Token` + injected `X-Zaki-User-Id`.
4. Runtime handles canonical session key + tenant isolation.

## 4) User Journey (v1)

1. User signs in.
2. User clicks "Create my BOT".
3. BFF provisions runtime user.
4. User connects Telegram via token wizard.
5. User sends Telegram test message and sees successful reply.
6. User applies preset settings.
7. User chats via app and/or Telegram.
8. User sees usage and soft-limit warnings.

## 5) BFF Public API Contract

1. `POST /v1/me/bot/provision` -> `POST /api/v1/users/provision`
2. `GET /v1/me/bot/onboarding` -> `GET /api/v1/users/{user_id}/onboarding`
3. `PUT /v1/me/bot/onboarding` -> `PUT /api/v1/users/{user_id}/onboarding`
4. `POST /v1/me/bot/chat/stream` -> `POST /api/v1/chat/stream`
5. `GET /v1/me/bot/settings` -> read product profile settings
6. `PATCH /v1/me/bot/settings` -> map profile -> `PATCH /api/v1/users/{user_id}/config`
7. `POST /v1/me/bot/telegram/connect` -> `POST /api/v1/users/{user_id}/channels/telegram/connect`
8. `POST /v1/me/bot/telegram/disconnect` -> `POST /api/v1/users/{user_id}/channels/telegram/disconnect`
9. `GET /v1/me/bot/usage` -> metering + soft-limit state

Security constraints:
1. BFF never accepts client-supplied `user_id`.
2. BFF never exposes internal token.
3. BFF enforces principal -> `user_id` binding.

## 6) User-Facing Settings Schema and Runtime Mapping

Settings schema:
```json
{
  "assistant_mode": "fast|balanced|deep",
  "group_activation": "mention|always",
  "proactive_updates": true,
  "voice_replies": false,
  "session_timeout_minutes": 30
}
```

Deterministic mapping:
1. `assistant_mode=fast` -> `queue_mode=latest`, `queue_cap=8`, `queue_drop=newest`, `compact_context=true`
2. `assistant_mode=balanced` -> `queue_mode=serial`, `queue_cap=12`, `queue_drop=summarize`, `compact_context=true`
3. `assistant_mode=deep` -> `queue_mode=serial`, `queue_cap=20`, `queue_drop=summarize`, `compact_context=true`, higher history retention
4. `group_activation` -> `activation_mode`
5. `proactive_updates=false` -> `send_mode=off`; true -> `send_mode=inherit`
6. `voice_replies=true` -> `tts_mode=inbound`, `tts_audio=true`; false -> `tts_mode=off`, `tts_audio=false`
7. `session_timeout_minutes` -> `session_ttl_secs` with clamp `5..180` minutes
8. Slash commands remain runtime override only; they do not persist profile settings

## 7) Telegram v1 Contract (Per-User Bot Token)

1. BFF onboarding wizard collects `bot_token`, `webhook_base_url`, optional allowlist.
2. BFF stores token via user-scoped secret path through gateway.
3. BFF connect payload:
   - `account_id`
   - `bot_token`
   - `webhook_base_url`
   - `webhook_secret_token` (optional)
   - `allow_from` (optional)
4. BFF confirms connect response, then marks integration connected.
5. Disconnect is idempotent and supports token rotation through reconnect.
6. UX-normalized errors:
   - `invalid_token`
   - `webhook_rejected`
   - `secret_mismatch`
   - `not_connected`

## 8) BFF Persistence Additions

1. `bot_settings` keyed by `user_id`.
2. `bot_integrations` keyed by `(user_id, channel)` with connection status/timestamps.
3. `bot_usage_daily` keyed by `(user_id, date)` for request/token/session counters.
4. `bot_events` append-only lifecycle log (provision, connect, disconnect, setting-change, warnings).

## 9) Phased Delivery Plan

Phase 0: contracts
1. Freeze BFF API + setting schema + mapping library.
2. Publish FE/BFF contract tests.

Phase 1: BFF secure gateway client
1. Auth principal -> runtime user binding.
2. Internal header injection, retry/timeout policy, circuit guard.

Phase 2: provision and chat
1. Provision endpoint.
2. SSE stream proxy endpoint.
3. Standardized error mapping.

Phase 3: Telegram onboarding
1. Connect/disconnect proxy endpoints.
2. FE token wizard and test ping.
3. Reconnect/token rotate path.

Phase 4: settings UX
1. Build simple settings controls.
2. Persist profile settings and apply deterministic runtime patch mapping.
3. Reset-to-default.

Phase 5: metering + soft limits
1. Implement `/v1/me/bot/usage`.
2. Add thresholds: `normal`, `warning`, `near_limit`.
3. Operator dashboards for soft-limit posture.

Phase 6: staging readiness and rollout
1. Validate multi-pod health.
2. Validate sticky routing + `tenant_lock_backend=postgres_lease`.
3. Run two consecutive 20/50/100 canary sets.
4. Rollout order: internal cohort -> pilot customers -> wider cohort.

## 10) Acceptance Gates

1. Functional: onboarding + Telegram + settings + chat all pass end-to-end.
2. Security: no cross-user mutation/read path; token secrecy verified.
3. Reliability: two consecutive canary sets pass agreed thresholds.
4. Ops: sticky-routing and lease-backend proof artifacts exist.
5. Product: user can self-serve without operator intervention.

## 11) Test Matrix

1. User A cannot read/mutate User B settings.
2. SSE stream proxy hides internal headers.
3. Telegram connect valid token succeeds; invalid token maps clean UX error.
4. Telegram disconnect stops inbound replies.
5. Preset mapping generates exact runtime config payload.
6. Slash runtime override does not mutate persisted profile.
7. Soft-limit warnings trigger deterministically.
8. Concurrency preserves session/tenant isolation.
9. Staging shows sticky affinity for same user.
10. Diagnostics shows `tenant_lock_backend=postgres_lease` in target env.

## 12) What Is Implemented Here vs External

Implemented in this runtime repo:
1. Internal gateway contract required by v1 BFF.
2. Telegram disconnect supports both `POST` and `DELETE` for BFF action-style parity.
3. Updated internal OpenAPI to document both disconnect methods.

Requires ZAKI API / frontend repos:
1. `/v1/me/bot/*` endpoint implementation.
2. User-facing onboarding/settings/usage pages.
3. BFF storage tables and metering logic.
