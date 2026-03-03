# ZAKI Backend Handoff Spec (Nullclaw Integration)

This document is the implementation contract for ZAKI backend to integrate with Nullclaw for the dedicated `ZAKI BOT` space.

## 1) Base setup

- Nullclaw base URL (local/staging/prod): `NULLCLAW_BASE_URL`
- Internal auth token: `NULLCLAW_INTERNAL_TOKEN`
- Feature flag: `ZAKI_AGENT_BACKEND_ENABLED=true`

All backend-to-Nullclaw requests must include:

- `X-Internal-Token: <NULLCLAW_INTERNAL_TOKEN>`
- `X-Zaki-User-Id: <canonical_user_id>` (required for chat stream in tenant mode)
- `X-Request-Id: <uuid>` (recommended for tracing)

Browser must never receive `X-Internal-Token`.

## 2) Required backend endpoint

Add ZAKI backend proxy route:

- `POST /api/agent/chat/stream`

Behavior:

1. Authenticate user with existing backend auth.
2. Resolve canonical `user_id`.
3. Forward request body to `POST {NULLCLAW_BASE_URL}/api/v1/chat/stream`.
4. Inject headers above.
5. Stream SSE bytes through unchanged (no semantic rewrite).
6. Preserve Nullclaw status code (`200/400/401/409/500/503`).

## 3) Nullclaw API map to expose via backend

- `POST /api/v1/users/provision`
- `GET/PATCH /api/v1/users/{id}/config`
- `GET/PUT/DELETE /api/v1/users/{id}/secrets/{key}`
- `GET/PUT /api/v1/users/{id}/heartbeat`
- `GET/POST/PATCH/DELETE /api/v1/users/{id}/cron`
- `GET/PUT /api/v1/users/{id}/onboarding`
- `POST /api/v1/users/{id}/channels/telegram/connect`
- `DELETE /api/v1/users/{id}/channels/telegram/disconnect`

Authorization rule:

- Backend must enforce caller can only access their own `{id}`.

## 4) Chat stream contract (exact current behavior)

Request to Nullclaw:

```http
POST /api/v1/chat/stream
Content-Type: application/json
X-Internal-Token: ...
X-Zaki-User-Id: user_123

{"message":"hello"}
```

Accepted request body fields:

- `message` (preferred)
- `text` (fallback)

Success response:

- HTTP `200`
- `Content-Type: text/event-stream; charset=utf-8`
- Events:
  - `event: token` with `{"delta":"...","content":"...","seq":<int>}`
  - `event: done` with `{"status":"ok","session_id":"...","message_id":"..."}`

Error stream response (example):

- HTTP `409` or `503` or `500`
- `Content-Type: text/event-stream; charset=utf-8`
- Events:
  - `event: error` with `{"code":"...","message":"..."}`
  - `event: done` with `{"status":"error"}`

Important:

- Preserve partial token text if stream ends after token events.
- Treat `event: done` as terminal.

## 5) Expected status code handling

- `400`: missing/invalid request fields (e.g. missing `message`, missing `X-Zaki-User-Id`)
- `401`: invalid `X-Internal-Token`
- `409`: tenant ownership lock conflict (same user active on another pod)
- `503`: gateway draining or overloaded
- `500`: runtime/internal failure
- `502`: Telegram bot API upstream failure in connect/disconnect calls

## 6) Telegram connect/disconnect contract

### Connect

Request:

```http
POST /api/v1/users/{id}/channels/telegram/connect
Content-Type: application/json

{
  "bot_token": "<user_bot_token>",
  "webhook_base_url": "https://agent-staging.zaki.com",
  "webhook_secret_token": "optional_min_8_chars",
  "drop_pending_updates": false
}
```

Notes:

- If `webhook_secret_token` missing, Nullclaw generates one.
- `webhook_base_url` must be `https://`.
- Resulting webhook URL is `{base}/webhook/telegram?user_id={id}`.
- Nullclaw validates Telegram `setWebhook` and `getWebhookInfo`.

### Disconnect

Request:

```http
DELETE /api/v1/users/{id}/channels/telegram/disconnect
Content-Type: application/json

{"drop_pending_updates":false}
```

Effects:

- Calls Telegram `deleteWebhook`.
- Removes tenant `telegram.json` and `channel_state.json`.

## 7) Telegram webhook ingress expectations

Telegram sends directly to Nullclaw:

- `POST /webhook/telegram?user_id={id}`
- Header `X-Telegram-Bot-Api-Secret-Token` must match per-user stored token.

Nullclaw behavior:

- Rejects missing/invalid `user_id` or secret token.
- Deduplicates by `update_id`.
- Writes latest chat mapping to tenant `channel_state.json`.
- Routes inbound Telegram message into same main session key as app:
  - `agent:zaki-bot:user:{id}:main`

## 8) Local integration checklist

1. Start Nullclaw gateway locally with tenant mode enabled.
2. Start ZAKI backend with `NULLCLAW_BASE_URL` and `NULLCLAW_INTERNAL_TOKEN`.
3. `POST /api/v1/users/provision` for current test user.
4. Verify `POST /api/agent/chat/stream` renders SSE tokens.
5. Connect Telegram for same user, send Telegram message, verify same timeline.
6. Add cron job with `job_type=agent` and verify it executes under same user context.

## 9) Copy-paste curl smoke snippets

```bash
BASE=http://127.0.0.1:3000
TOK=replace_me
UID=user_local_1

curl -sS -X POST "$BASE/api/v1/users/provision" \
  -H "X-Internal-Token: $TOK" \
  -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$UID\"}"

curl -N -sS -X POST "$BASE/api/v1/chat/stream" \
  -H "X-Internal-Token: $TOK" \
  -H "X-Zaki-User-Id: $UID" \
  -H "Content-Type: application/json" \
  -d '{"message":"say hello in one sentence"}'
```
