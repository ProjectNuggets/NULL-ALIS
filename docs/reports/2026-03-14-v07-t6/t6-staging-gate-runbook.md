# T6 Staging Gate Runbook

Date: 2026-03-14  
Owner: staging operator / deployment team  
Goal: execute final T6 GO/HOLD gate with evidence.

## Preconditions
1. nullalis deployed from commit `72a732a`.
2. zaki-prod T6 BFF slice deployed in staging.
3. Environment variables set:
   - `BFF_BASE_URL`
   - `BFF_AUTH_TOKEN`
   - `NULLALIS_BASE_URL`
   - `NULLALIS_INTERNAL_TOKEN`
4. One test user account with valid auth token.

## Naming Note
1. This runbook uses `NULLALIS_*` variable names for operator clarity.
2. Some runtime internals still use historical `NULLCLAW_*` env prefixes; that is legacy naming in code, not a product rename.

## Evidence Directory
Create local evidence directory:
```bash
mkdir -p /tmp/t6-staging-evidence
```

## 1) Provision
```bash
curl -i -sS \
  -H "Authorization: Bearer $BFF_AUTH_TOKEN" \
  -X POST "$BFF_BASE_URL/v1/me/bot/provision" \
  | tee /tmp/t6-staging-evidence/01-provision.txt
```

## 2) Telegram Connect (valid)
```bash
curl -i -sS \
  -H "Authorization: Bearer $BFF_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$BFF_BASE_URL/v1/me/bot/telegram/connect" \
  -d '{"bot_token":"<STAGING_TEST_BOT_TOKEN>"}' \
  | tee /tmp/t6-staging-evidence/02-telegram-connect.txt
```

## 3) Settings Save
```bash
curl -i -sS \
  -H "Authorization: Bearer $BFF_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -X PATCH "$BFF_BASE_URL/v1/me/bot/settings" \
  -d '{"assistant_mode":"balanced","group_activation":"mention","proactive_updates":true,"voice_replies":false,"session_timeout_minutes":30}' \
  | tee /tmp/t6-staging-evidence/03-settings-patch.txt
```

## 4) Chat Stream (SSE success trace)
```bash
curl -N -i -sS \
  -H "Authorization: Bearer $BFF_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$BFF_BASE_URL/v1/me/bot/chat/stream" \
  -d '{"message":"t6 staging validation ping"}' \
  | tee /tmp/t6-staging-evidence/04-chat-stream-success.sse
```

## 5) Usage Read
```bash
curl -i -sS \
  -H "Authorization: Bearer $BFF_AUTH_TOKEN" \
  "$BFF_BASE_URL/v1/me/bot/usage" \
  | tee /tmp/t6-staging-evidence/05-usage.txt
```

## 6) Lock Contention Trace
Run two concurrent writes to force same-user contention:
```bash
(curl -i -sS -H "Authorization: Bearer $BFF_AUTH_TOKEN" -H "Content-Type: application/json" -X PATCH "$BFF_BASE_URL/v1/me/bot/settings" -d '{"assistant_mode":"fast"}' > /tmp/t6-staging-evidence/06a-contention.txt) &
(curl -i -sS -H "Authorization: Bearer $BFF_AUTH_TOKEN" -H "Content-Type: application/json" -X PATCH "$BFF_BASE_URL/v1/me/bot/settings" -d '{"assistant_mode":"deep"}' > /tmp/t6-staging-evidence/06b-contention.txt) &
wait
```

Collect BFF retry metrics and nullalis diagnostics:
```bash
curl -i -sS \
  -H "Authorization: Bearer $BFF_AUTH_TOKEN" \
  "$BFF_BASE_URL/internal/metrics/t6-lock-retry" \
  | tee /tmp/t6-staging-evidence/06c-bff-retry-metrics.txt || true

curl -i -sS \
  -H "X-Internal-Token: $NULLALIS_INTERNAL_TOKEN" \
  "$NULLALIS_BASE_URL/internal/diagnostics" \
  | tee /tmp/t6-staging-evidence/06d-nullalis-diagnostics.json
```

## 7) Telegram Disconnect/Reconnect
```bash
curl -i -sS \
  -H "Authorization: Bearer $BFF_AUTH_TOKEN" \
  -X POST "$BFF_BASE_URL/v1/me/bot/telegram/disconnect" \
  | tee /tmp/t6-staging-evidence/07a-telegram-disconnect.txt

curl -i -sS \
  -H "Authorization: Bearer $BFF_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$BFF_BASE_URL/v1/me/bot/telegram/connect" \
  -d '{"bot_token":"<STAGING_TEST_BOT_TOKEN>"}' \
  | tee /tmp/t6-staging-evidence/07b-telegram-reconnect.txt
```

## 8) Negative Traces Required
### invalid telegram token
```bash
curl -i -sS \
  -H "Authorization: Bearer $BFF_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$BFF_BASE_URL/v1/me/bot/telegram/connect" \
  -d '{"bot_token":"bad-token"}' \
  | tee /tmp/t6-staging-evidence/08a-invalid-telegram-token.txt
```

### disconnect when not connected
```bash
curl -i -sS \
  -H "Authorization: Bearer $BFF_AUTH_TOKEN" \
  -X POST "$BFF_BASE_URL/v1/me/bot/telegram/disconnect" \
  | tee /tmp/t6-staging-evidence/08b-disconnect-not-connected.txt
```

## GO Checklist
1. All `/v1/me/bot/*` endpoints return expected product DTO shapes.
2. No raw `ownership_lock_conflict` leaks to client-facing responses.
3. Retry exhaustion maps to `503 temporary_contention`.
4. SSE stream has no post-start replay behavior.
5. Usage payload shape matches contract.
6. Traces and counters are attached to `t6-decision-report.md`.
