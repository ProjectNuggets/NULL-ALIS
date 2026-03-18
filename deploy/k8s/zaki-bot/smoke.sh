#!/usr/bin/env bash
set -euo pipefail

: "${BASE_URL:?Set BASE_URL, e.g. https://agent-staging.zaki.com}"
: "${INTERNAL_TOKEN:?Set INTERNAL_TOKEN}"
: "${USER_ID:?Set USER_ID}"
: "${TELEGRAM_BOT_TOKEN:?Set TELEGRAM_BOT_TOKEN}"
: "${WEBHOOK_BASE_URL:?Set WEBHOOK_BASE_URL, e.g. https://agent-staging.zaki.com}"
: "${TELEGRAM_WEBHOOK_SECRET:?Set TELEGRAM_WEBHOOK_SECRET}"
: "${PGBOUNCER_EXPECTED:=false}"
: "${EXPECT_NOT_DEGRADED:=false}"
: "${EXPECT_STATE_EFFECTIVE:=}"
: "${EXPECT_BASE_URL_DNS:=false}"
: "${EXPECT_WEBHOOK_BASE_URL_DNS:=false}"

auth=(-H "X-Internal-Token: ${INTERNAL_TOKEN}")
json=(-H "Content-Type: application/json")

extract_host() {
  # Accepts URL-like values (https://host:port/path) and returns host only.
  # If input already looks like a bare host, returns it unchanged.
  local raw="$1"
  local host
  host="$(printf '%s' "${raw}" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*$##; s#:[0-9]+$##')"
  printf '%s' "${host}"
}

host_resolves() {
  local host="$1"
  if command -v getent >/dev/null 2>&1; then
    getent ahosts "${host}" >/dev/null 2>&1
    return $?
  fi
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "${host}" >/dev/null 2>&1
    return $?
  fi
  if command -v dig >/dev/null 2>&1; then
    dig +short "${host}" | grep -q '.'
    return $?
  fi
  echo "error: strict DNS check requested but no resolver tools available (need getent or nslookup or dig) for ${host}" >&2
  return 1
}

if [[ "${EXPECT_BASE_URL_DNS}" == "true" ]]; then
  base_host="$(extract_host "${BASE_URL}")"
  echo "[0a/9] verify BASE_URL DNS resolves (${base_host})"
  if ! host_resolves "${base_host}"; then
    echo "BASE_URL host does not resolve: ${base_host}" >&2
    exit 1
  fi
fi

if [[ "${EXPECT_WEBHOOK_BASE_URL_DNS}" == "true" ]]; then
  webhook_host="$(extract_host "${WEBHOOK_BASE_URL}")"
  echo "[0b/9] verify WEBHOOK_BASE_URL DNS resolves (${webhook_host})"
  if ! host_resolves "${webhook_host}"; then
    echo "WEBHOOK_BASE_URL host does not resolve: ${webhook_host}" >&2
    exit 1
  fi
fi

echo "[1/9] health and ready"
curl -fsS "${BASE_URL}/health" >/dev/null
curl -fsS "${BASE_URL}/ready" >/dev/null

diagnostics_json="$(curl -fsS "${BASE_URL}/internal/diagnostics" "${auth[@]}")"
state_effective="$(jq -r '.startup_self_check.state_effective // ""' <<<"${diagnostics_json}")"
degraded_flag="$(jq -r '.startup_self_check.degraded // ""' <<<"${diagnostics_json}")"

if [[ "${PGBOUNCER_EXPECTED}" == "true" ]]; then
  echo "[1b/9] verify runtime is routed via PgBouncer"
  pg_port="$(jq -r '.startup_self_check.pg_port // ""' <<<"${diagnostics_json}")"
  if [[ "${pg_port}" != "6432" ]]; then
    echo "expected pg_port=6432 (PgBouncer), got: ${pg_port}" >&2
    exit 1
  fi
fi

if [[ -n "${EXPECT_STATE_EFFECTIVE}" ]]; then
  echo "[1c/9] verify effective state backend (${EXPECT_STATE_EFFECTIVE})"
  if [[ "${state_effective}" != "${EXPECT_STATE_EFFECTIVE}" ]]; then
    echo "expected startup_self_check.state_effective=${EXPECT_STATE_EFFECTIVE}, got: ${state_effective}" >&2
    exit 1
  fi
fi

if [[ "${EXPECT_NOT_DEGRADED}" == "true" ]]; then
  echo "[1d/9] verify runtime is not degraded"
  if [[ "${degraded_flag}" != "false" ]]; then
    degraded_reason="$(jq -r '.startup_self_check.degraded_reason // ""' <<<"${diagnostics_json}")"
    echo "expected startup_self_check.degraded=false, got: ${degraded_flag} (${degraded_reason})" >&2
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
session_key="agent:zaki-bot:user:${USER_ID}:main"
curl -fsS -N -X POST "${BASE_URL}/api/v1/chat/stream" "${auth[@]}" "${json[@]}" \
  -H "X-Zaki-User-Id: ${USER_ID}" \
  -d "{\"message\":\"Say hello from smoke test\",\"session_key\":\"${session_key}\"}" | head -n 20

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
