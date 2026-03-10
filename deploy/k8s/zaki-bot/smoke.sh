#!/usr/bin/env bash
set -euo pipefail

: "${BASE_URL:?Set BASE_URL, e.g. https://agent-staging.zaki.com}"
: "${INTERNAL_TOKEN:?Set INTERNAL_TOKEN}"
: "${USER_ID:?Set USER_ID}"
: "${TELEGRAM_BOT_TOKEN:?Set TELEGRAM_BOT_TOKEN}"
: "${WEBHOOK_BASE_URL:?Set WEBHOOK_BASE_URL, e.g. https://agent-staging.zaki.com}"
: "${TELEGRAM_WEBHOOK_SECRET:?Set TELEGRAM_WEBHOOK_SECRET}"
: "${PGBOUNCER_EXPECTED:=false}"

auth=(-H "X-Internal-Token: ${INTERNAL_TOKEN}")
json=(-H "Content-Type: application/json")

echo "[1/9] health and ready"
curl -fsS "${BASE_URL}/health" >/dev/null
curl -fsS "${BASE_URL}/ready" >/dev/null

if [[ "${PGBOUNCER_EXPECTED}" == "true" ]]; then
  echo "[1b/9] verify runtime is routed via PgBouncer"
  pg_port="$(curl -fsS "${BASE_URL}/internal/diagnostics" "${auth[@]}" | jq -r '.startup_self_check.pg_port // ""')"
  if [[ "${pg_port}" != "6432" ]]; then
    echo "expected pg_port=6432 (PgBouncer), got: ${pg_port}" >&2
    exit 1
  fi
fi

echo "[2/9] provision user"
curl -fsS -X POST "${BASE_URL}/api/v1/users/provision" "${auth[@]}" "${json[@]}" \
  -d "{\"user_id\":\"${USER_ID}\"}" >/dev/null

echo "[3/9] set config/heartbeat/cron"
curl -fsS -X PATCH "${BASE_URL}/api/v1/users/${USER_ID}/config" "${auth[@]}" "${json[@]}" \
  -d '{"autonomy":{"enabled":true}}' >/dev/null

curl -fsS -X PUT "${BASE_URL}/api/v1/users/${USER_ID}/heartbeat" "${auth[@]}" "${json[@]}" \
  -d '{"enabled":true,"interval_minutes":30}' >/dev/null

curl -fsS -X POST "${BASE_URL}/api/v1/users/${USER_ID}/cron" "${auth[@]}" "${json[@]}" \
  -d '[{"id":"health-check","expression":"*/30 * * * *","command":"echo tenant-cron-ok"}]' >/dev/null

echo "[4/9] store telegram bot token secret"
curl -fsS -X PUT "${BASE_URL}/api/v1/users/${USER_ID}/secrets/telegram_bot_token" "${auth[@]}" "${json[@]}" \
  -d "{\"value\":\"${TELEGRAM_BOT_TOKEN}\"}" >/dev/null

echo "[5/9] connect telegram"
curl -fsS -X POST "${BASE_URL}/api/v1/users/${USER_ID}/channels/telegram/connect" "${auth[@]}" "${json[@]}" \
  -d "{\"bot_token\":\"${TELEGRAM_BOT_TOKEN}\",\"webhook_base_url\":\"${WEBHOOK_BASE_URL}\",\"webhook_secret_token\":\"${TELEGRAM_WEBHOOK_SECRET}\",\"drop_pending_updates\":false}" >/dev/null

echo "[6/9] chat stream"
curl -fsS -N -X POST "${BASE_URL}/api/v1/chat/stream" "${auth[@]}" "${json[@]}" \
  -H "X-Zaki-User-Id: ${USER_ID}" \
  -d '{"message":"Say hello from smoke test"}' | head -n 20

echo "[7/9] telegram webhook + duplicate idempotency"
update='{"update_id":999001,"message":{"chat":{"id":123456789},"from":{"id":123456789},"text":"hello-from-telegram"}}'
curl -fsS -X POST "${BASE_URL}/webhook/telegram?user_id=${USER_ID}" \
  -H "Content-Type: application/json" \
  -H "X-Telegram-Bot-Api-Secret-Token: ${TELEGRAM_WEBHOOK_SECRET}" \
  -d "${update}"

curl -fsS -X POST "${BASE_URL}/webhook/telegram?user_id=${USER_ID}" \
  -H "Content-Type: application/json" \
  -H "X-Telegram-Bot-Api-Secret-Token: ${TELEGRAM_WEBHOOK_SECRET}" \
  -d "${update}"

echo "[8/9] drain and undrain"
curl -fsS -X POST "${BASE_URL}/internal/drain" "${auth[@]}" >/dev/null
curl -sS -o /dev/null -w "ready status after drain: %{http_code}\n" "${BASE_URL}/ready"
curl -fsS -X POST "${BASE_URL}/internal/undrain" "${auth[@]}" >/dev/null

echo "[9/9] disconnect telegram"
curl -fsS -X DELETE "${BASE_URL}/api/v1/users/${USER_ID}/channels/telegram/disconnect" "${auth[@]}" "${json[@]}" \
  -d "{\"bot_token\":\"${TELEGRAM_BOT_TOKEN}\",\"drop_pending_updates\":false}" >/dev/null

echo "smoke test complete"
