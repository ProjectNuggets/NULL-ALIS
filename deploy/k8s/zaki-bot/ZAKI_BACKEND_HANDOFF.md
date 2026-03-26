# ZAKI Backend Handoff Spec (Nullclaw Integration)

Reference warning:
- This handoff doc is preserved for backend contract reference.
- It is not the production source of truth for live deployment topology.
- Direct Telegram-to-Nullclaw webhook details below should be treated as legacy/reference unless the current rollout explicitly enables them.

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

Deployment contract:

- `NULLCLAW_BASE_URL` must remain the internal backend -> nullALIS service URL, for example `http://nullclaw:3000`
- `ZAKI_AGENT_WEBHOOK_BASE_URL` must be the public HTTPS ingress used by Telegram, for example `https://agent.zaki.com`
- In deployed environments `ZAKI_AGENT_WEBHOOK_BASE_URL` should be treated as required operator/deployment config for smooth Telegram connect

Default Nullclaw profile/model for this integration:

- `profile = "zaki_bot"`
- `agents.defaults.model.primary = "together-ai/moonshotai/kimi-k2.5"`

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
  - `event: progress` with `{"type":"progress","phase":"...","state":"...","label":"..."}` (optional, may appear multiple times)
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
- Pass through unknown/new SSE event types unchanged for forward compatibility.

## 5) Expected status code handling

- `400`: missing/invalid request fields (e.g. missing `message`, missing `X-Zaki-User-Id`)
- `401`: invalid `X-Internal-Token`
- `409`: tenant ownership lock conflict (same user active on another pod)
- `503`: gateway draining or overloaded
- `500`: runtime/internal failure
- `502`: Telegram bot API upstream failure in connect/disconnect calls

## 6) Telegram connect/disconnect contract

Legacy topology note:
- this section reflects the direct Nullclaw webhook model
- current internal-service-first posture may instead terminate public webhook traffic at the app/backend edge and relay internally

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

- Product contract: end users should only need to provide `bot_token`
- `account_id` and `allow_from` are optional advanced fields
- Backend should inject the webhook base automatically from `ZAKI_AGENT_WEBHOOK_BASE_URL`
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

Current posture note:
- preserve this as the reference contract for direct webhook mode
- do not assume this is the active default deployment posture without matching `zaki-infra` rollout config

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
