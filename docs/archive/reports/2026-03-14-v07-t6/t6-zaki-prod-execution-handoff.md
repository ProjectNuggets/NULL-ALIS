---
tags: [prose, prose/docs]
---

# T6 ZAKI Prod Execution Handoff

Date: 2026-03-14  
Target repo: `zaki-prod`

## Objective
Implement a shared product-facing BFF API layer (`/v1/me/bot/*`) that is frontend-agnostic and mapped to nullalis internal API.

## Implementation Order (Decision-Complete)
1. Add shared DTO package:
   - `BotProvisionStatus`
   - `BotOnboardingState`
   - `BotSettingsProfile`
   - `BotUsageSummary`
   - `TelegramConnectionState`
   - `ProductError`
2. Add stable error catalog mapping:
   - `temporary_contention`
   - `unauthorized`
   - `forbidden`
   - `invalid_telegram_token`
   - `provision_failed`
   - `settings_update_failed`
   - `usage_unavailable`
3. Implement endpoint family:
   - `POST /v1/me/bot/provision`
   - `GET/PUT /v1/me/bot/onboarding`
   - `GET/PATCH /v1/me/bot/settings`
   - `POST /v1/me/bot/chat/stream`
   - `POST /v1/me/bot/telegram/connect`
   - `POST /v1/me/bot/telegram/disconnect`
   - `GET /v1/me/bot/usage`
4. Enforce auth-binding and identity isolation:
   - derive internal user id from auth principal
   - never trust client-supplied internal user id
   - validate `session_key` belongs to the authenticated user
   - reject missing or invalid lane keys before proxying
5. Add chat session lane contract on `POST /v1/me/bot/chat/stream`:
   - require raw `session_key`
   - allow only `main`, `thread:<id>`, `task:<id>`, `cron:<id>`
   - forward the validated `session_key` unchanged to nullalis
6. Implement lock conflict retry policy:
   - retry only `409 + ownership_lock_conflict`
   - max attempts: `3`
   - max wall-time: `1500ms`
   - backoff from `retry_after_ms`; fallback `100/250/500ms` with jitter ±20%
7. SSE behavior:
   - retries only before stream establishment
   - no retry after first SSE byte forwarded
   - mid-stream errors emitted as normalized SSE error event
8. Publish BFF contract examples and snapshots.

## Validation Checklist
1. Auth isolation:
   - user A cannot read/write B user data.
2. Retry correctness:
   - recovers within retry budget when lock clears.
3. Retry exhaustion:
   - returns `503 temporary_contention`.
4. SSE guard:
   - pre-stream retry allowed, mid-stream replay forbidden.
5. Chat session contract:
   - missing `session_key` rejected
   - wrong-user `session_key` rejected
   - valid `thread`/`task` keys proxy cleanly
6. Settings:
   - 5-field profile roundtrip, no UI fields.
7. Telegram:
   - invalid token mapped to `invalid_telegram_token`.
8. Usage:
   - unavailable state mapped to `usage_unavailable`.

## Required T6 Staging E2E
1. provision
2. telegram connect
3. settings save
4. chat stream
5. usage read
6. lock contention recovery path
7. disconnect/reconnect telegram

Artifacts to capture:
1. retry counters
2. conflict outcomes
3. SSE trace
4. normalized error samples
5. final `t6-decision-report.md` (GO/HOLD)
