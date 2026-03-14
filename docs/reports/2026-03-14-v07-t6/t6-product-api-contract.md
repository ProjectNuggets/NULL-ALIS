# T6 Product API Contract (BFF Surface)

Date: 2026-03-14  
Audience: ZAKI BFF + any current/future frontend client  
Rule: endpoint contracts are product-capability oriented and frontend-agnostic.

## Stable Error Catalog (Locked)
1. `temporary_contention`
2. `unauthorized`
3. `forbidden`
4. `invalid_telegram_token`
5. `provision_failed`
6. `settings_update_failed`
7. `usage_unavailable`

Standard error shape:
```json
{
  "error": "temporary_contention",
  "message": "Agent is busy on another node. Retry shortly.",
  "retryable": true,
  "request_id": "req_123"
}
```

## Endpoint Contracts and Examples

### 1) `POST /v1/me/bot/provision`
Product capability: create/prepare bot runtime for authenticated user.

Success example:
```json
{ "status": "provisioned" }
```

Validation error example:
```json
{
  "error": "provision_failed",
  "message": "provision request invalid",
  "retryable": false,
  "request_id": "req_123"
}
```

Lock-conflict upstream example (gateway):
```json
{
  "error": "ownership_lock_conflict",
  "retry_after_ms": 250
}
```

Normalized BFF error example:
```json
{
  "error": "temporary_contention",
  "message": "Agent is busy on another node. Retry shortly.",
  "retryable": true,
  "request_id": "req_123"
}
```

SSE error event example: `not_applicable`  
Reusable by second frontend unchanged: `yes`

### 2) `GET /v1/me/bot/onboarding`
Product capability: fetch onboarding state for authenticated user.

Success example:
```json
{
  "completed": false,
  "completed_at_s": null
}
```

Validation error example: `not_applicable` (read endpoint, no body)  
Lock-conflict upstream example: `not_applicable`  
Normalized BFF error example:
```json
{
  "error": "forbidden",
  "message": "onboarding state not accessible",
  "retryable": false,
  "request_id": "req_123"
}
```

SSE error event example: `not_applicable`  
Reusable by second frontend unchanged: `yes`

### 3) `PUT /v1/me/bot/onboarding`
Product capability: persist onboarding state for authenticated user.

Success example:
```json
{
  "completed": true,
  "completed_at_s": 1760000000
}
```

Validation error example:
```json
{
  "error": "forbidden",
  "message": "onboarding payload invalid",
  "retryable": false,
  "request_id": "req_123"
}
```

Lock-conflict upstream example (gateway):
```json
{
  "error": "ownership_lock_conflict",
  "retry_after_ms": 250
}
```

Normalized BFF error example:
```json
{
  "error": "temporary_contention",
  "message": "Agent is busy on another node. Retry shortly.",
  "retryable": true,
  "request_id": "req_123"
}
```

SSE error event example: `not_applicable`  
Reusable by second frontend unchanged: `yes`

### 4) `GET /v1/me/bot/settings`
Product capability: fetch canonical product settings profile.

Success example:
```json
{
  "assistant_mode": "balanced",
  "group_activation": "mention",
  "proactive_updates": true,
  "voice_replies": false,
  "session_timeout_minutes": 30
}
```

Validation error example: `not_applicable`  
Lock-conflict upstream example: `not_applicable`  
Normalized BFF error example:
```json
{
  "error": "settings_update_failed",
  "message": "settings unavailable",
  "retryable": false,
  "request_id": "req_123"
}
```

SSE error event example: `not_applicable`  
Reusable by second frontend unchanged: `yes`

### 5) `PATCH /v1/me/bot/settings`
Product capability: update canonical product settings profile.

Success example:
```json
{
  "assistant_mode": "deep",
  "group_activation": "always",
  "proactive_updates": true,
  "voice_replies": false,
  "session_timeout_minutes": 45
}
```

Validation error example:
```json
{
  "error": "settings_update_failed",
  "message": "invalid session_timeout_minutes",
  "retryable": false,
  "request_id": "req_123"
}
```

Lock-conflict upstream example (gateway):
```json
{
  "error": "ownership_lock_conflict",
  "retry_after_ms": 250
}
```

Normalized BFF error example:
```json
{
  "error": "temporary_contention",
  "message": "Agent is busy on another node. Retry shortly.",
  "retryable": true,
  "request_id": "req_123"
}
```

SSE error event example: `not_applicable`  
Reusable by second frontend unchanged: `yes`

### 6) `POST /v1/me/bot/chat/stream` (SSE)
Product capability: stream model response for authenticated user turn.

Success example (SSE):
```text
event: status
data: {"state":"processing"}

event: token
data: {"text":"hello"}

event: done
data: {"ok":true}
```

Validation error example:
```json
{
  "error": "forbidden",
  "message": "invalid chat payload",
  "retryable": false,
  "request_id": "req_123"
}
```

Lock-conflict upstream example (pre-stream gateway):
```json
{
  "error": "ownership_lock_conflict",
  "retry_after_ms": 250
}
```

Normalized BFF error example (pre-stream exhaustion):
```json
{
  "error": "temporary_contention",
  "message": "Agent is busy on another node. Retry shortly.",
  "retryable": true,
  "request_id": "req_123"
}
```

SSE error event example (mid-stream, no retry):
```text
event: error
data: {"code":"temporary_contention","message":"Agent is busy on another node. Retry shortly.","retryable":true}
```

Reusable by second frontend unchanged: `yes`

### 7) `POST /v1/me/bot/telegram/connect`
Product capability: bind user bot token/webhook to user runtime.

Success example:
```json
{
  "status": "connected",
  "channel": "telegram"
}
```

Validation error example:
```json
{
  "error": "invalid_telegram_token",
  "message": "telegram token is invalid",
  "retryable": false,
  "request_id": "req_123"
}
```

Lock-conflict upstream example (gateway):
```json
{
  "error": "ownership_lock_conflict",
  "retry_after_ms": 250
}
```

Normalized BFF error example:
```json
{
  "error": "temporary_contention",
  "message": "Agent is busy on another node. Retry shortly.",
  "retryable": true,
  "request_id": "req_123"
}
```

SSE error event example: `not_applicable`  
Reusable by second frontend unchanged: `yes`

### 8) `POST /v1/me/bot/telegram/disconnect`
Product capability: unbind telegram channel from user runtime.

Success example:
```json
{
  "status": "disconnected",
  "channel": "telegram"
}
```

Validation error example:
```json
{
  "error": "forbidden",
  "message": "telegram disconnect request invalid",
  "retryable": false,
  "request_id": "req_123"
}
```

Lock-conflict upstream example (gateway): `not_applicable` (route not lock-protected in current gateway contract)  
Normalized BFF error example:
```json
{
  "error": "forbidden",
  "message": "telegram channel not connected",
  "retryable": false,
  "request_id": "req_123"
}
```

SSE error event example: `not_applicable`  
Reusable by second frontend unchanged: `yes`

### 9) `GET /v1/me/bot/usage`
Product capability: return product usage summary and soft-limit state.

Success example:
```json
{
  "state": "normal",
  "requests_day": 42,
  "tokens_day": 12000,
  "tokens_month": 190000
}
```

Validation error example: `not_applicable`  
Lock-conflict upstream example: `not_applicable`  
Normalized BFF error example:
```json
{
  "error": "usage_unavailable",
  "message": "usage telemetry unavailable",
  "retryable": true,
  "request_id": "req_123"
}
```

SSE error event example: `not_applicable`  
Reusable by second frontend unchanged: `yes`

## Notes on Frontend-Agnostic Design
1. All payloads represent durable product capabilities/states.
2. No endpoint includes layout/screen-specific fields.
3. Web/mobile/desktop clients can consume the same contracts unchanged.
