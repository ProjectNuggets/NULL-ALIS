# ZAKI Frontend Handoff Spec (ZAKI-agent UX)

This is the UI contract for the dedicated `ZAKI-agent` space powered by Nullclaw through ZAKI backend.

## 1) Space model

- Add fixed sidebar entry: `ZAKI-agent`.
- This is not a normal workspace.
- Hardcode identity in frontend state:
  - `space_id = "zaki-agent"`
  - `thread_id = "main"`
- Disable thread create/delete/rename in this space.

## 2) Chat input and stream behavior

UI sends chat only to backend route:

- `POST /api/agent/chat/stream`

Request body:

```json
{"message":"..."}
```

Stream parser rules:

1. Parse SSE incrementally.
2. On `event: token`, append `data.delta` (fallback `data.content`).
3. On `event: error`, show inline recoverable error state.
4. On `event: done`, close stream and persist final assistant message.
5. If network drops after some `token` events, keep partial content visible.

## 3) Right-side controls (required)

### Secrets

- CRUD UI for user secrets via backend passthrough:
  - `GET/PUT/DELETE /api/v1/users/{id}/secrets/{key}`
- Minimum keys to expose:
  - `telegram_bot_token`
  - any future integration keys (email/calendar/etc.)

### Telegram

- Connection status + action buttons:
  - Connect: `POST /api/v1/users/{id}/channels/telegram/connect`
  - Disconnect: `DELETE /api/v1/users/{id}/channels/telegram/disconnect`
- Show states:
  - `connected`
  - `not connected`
  - `connect failed` with server error text

### Agent Configuration

- Read/update:
  - `GET/PATCH /api/v1/users/{id}/config`
- Include autonomy controls surfaced in UX:
  - quiet hours
  - notification rate cap
  - retry budget

## 4) Onboarding wizard (show exactly once)

Backend state source:

- `GET /api/v1/users/{id}/onboarding`

If `completed=false`, show wizard:

1. playful “agent just came alive”
2. ask user to name the agent
3. ask profile basics
4. explain Telegram + jobs + proactive behavior

Complete wizard call:

- `PUT /api/v1/users/{id}/onboarding`

Payload can include:

- `completed: true`
- `identity`, `user`, `soul`, `heartbeat`, optional `bootstrap`

After completion:

- hide wizard permanently for that user

## 5) Cron and heartbeat management UI

Use backend passthrough APIs:

- `GET/PUT /api/v1/users/{id}/heartbeat`
- `GET/POST/PATCH/DELETE /api/v1/users/{id}/cron`

Cron editor must support:

- `job_type`: `shell` or `agent`
- `session_target`: `main` for unified timeline behavior
- delivery channel settings for Telegram notifications

## 6) UX error-state contract

Map status/errors to user-friendly banners:

- `401 unauthorized` -> session/auth issue
- `409 ownership_lock_conflict` -> “Agent is busy on another node, retrying...”
- `503 gateway_draining` or overload -> “Agent is updating, retrying...”
- `500 chat_failed` -> transient agent failure, allow retry

For stream errors, keep existing typed text and allow resend.

## 7) Local QA acceptance checklist

1. Sidebar shows fixed `ZAKI-agent` entry.
2. Only one thread is visible and writable.
3. Chat renders incremental SSE tokens.
4. Onboarding appears first time only.
5. Telegram connect succeeds and status updates.
6. Telegram inbound messages appear in same `main` timeline.
7. Cron `job_type=agent` sends proactive output to same agent context.
8. Drain/409/503 errors show clear recoverable UI messages.
