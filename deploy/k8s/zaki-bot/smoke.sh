#!/usr/bin/env bash
set -euo pipefail

# SMOKE_MODE: "full" (default) requires Telegram vars; "app" skips Telegram steps (4-7, 9).
# Use SMOKE_MODE=app for internal-only smoke where nullalis has no public DNS.
: "${SMOKE_MODE:=full}"

: "${BASE_URL:?Set BASE_URL (internal: http://nullclaw.zaki.svc.cluster.local:3000 or port-forward)}"
: "${INTERNAL_TOKEN:?Set INTERNAL_TOKEN}"
: "${USER_ID:?Set USER_ID}"

if [[ "${SMOKE_MODE}" == "full" ]]; then
  : "${TELEGRAM_BOT_TOKEN:?Set TELEGRAM_BOT_TOKEN (or use SMOKE_MODE=app to skip Telegram steps)}"
  : "${WEBHOOK_BASE_URL:?Set WEBHOOK_BASE_URL (or use SMOKE_MODE=app to skip Telegram steps)}"
  : "${TELEGRAM_WEBHOOK_SECRET:?Set TELEGRAM_WEBHOOK_SECRET (or use SMOKE_MODE=app to skip Telegram steps)}"
fi

: "${PGBOUNCER_EXPECTED:=false}"
: "${EXPECT_NOT_DEGRADED:=false}"
: "${EXPECT_STATE_EFFECTIVE:=}"
: "${EXPECT_SCHEDULER_BACKEND:=}"
: "${EXPECT_BASE_URL_DNS:=false}"
: "${EXPECT_WEBHOOK_BASE_URL_DNS:=false}"

total_steps=9
[[ "${SMOKE_MODE}" == "app" ]] && total_steps=5

auth=(-H "X-Internal-Token: ${INTERNAL_TOKEN}")
user_auth=(-H "X-Internal-Token: ${INTERNAL_TOKEN}" -H "X-Zaki-User-Id: ${USER_ID}")
json=(-H "Content-Type: application/json")

extract_host() {
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
  echo "[0a] verify BASE_URL DNS resolves (${base_host})"
  if ! host_resolves "${base_host}"; then
    echo "BASE_URL host does not resolve: ${base_host}" >&2
    exit 1
  fi
fi

if [[ "${EXPECT_WEBHOOK_BASE_URL_DNS}" == "true" ]]; then
  webhook_host="$(extract_host "${WEBHOOK_BASE_URL}")"
  echo "[0b] verify WEBHOOK_BASE_URL DNS resolves (${webhook_host})"
  if ! host_resolves "${webhook_host}"; then
    echo "WEBHOOK_BASE_URL host does not resolve: ${webhook_host}" >&2
    exit 1
  fi
fi

echo "[1/${total_steps}] health and ready"
curl -fsS "${BASE_URL}/health" >/dev/null
curl -fsS "${BASE_URL}/ready" >/dev/null

diagnostics_json="$(curl -fsS "${BASE_URL}/internal/diagnostics" "${auth[@]}")"
state_effective="$(jq -r '.startup_self_check.state_backend_effective // ""' <<<"${diagnostics_json}")"
degraded_flag="$(jq -r '.startup_self_check.degraded | tostring' <<<"${diagnostics_json}")"
scheduler_backend="$(jq -r '.startup_self_check.scheduler_backend // ""' <<<"${diagnostics_json}")"

if [[ "${PGBOUNCER_EXPECTED}" == "true" ]]; then
  echo "[1b] verify runtime is routed via PgBouncer"
  pg_port="$(jq -r '.startup_self_check.postgres_port // .startup_self_check.pg_port // ""' <<<"${diagnostics_json}")"
  if [[ "${pg_port}" != "6432" ]]; then
    echo "expected postgres_port=6432 (PgBouncer), got: ${pg_port}" >&2
    exit 1
  fi
fi

if [[ -n "${EXPECT_STATE_EFFECTIVE}" ]]; then
  echo "[1c] verify effective state backend (${EXPECT_STATE_EFFECTIVE})"
  if [[ "${state_effective}" != "${EXPECT_STATE_EFFECTIVE}" ]]; then
    echo "expected startup_self_check.state_effective=${EXPECT_STATE_EFFECTIVE}, got: ${state_effective}" >&2
    exit 1
  fi
fi

if [[ "${EXPECT_NOT_DEGRADED}" == "true" ]]; then
  echo "[1d] verify runtime is not degraded"
  if [[ "${degraded_flag}" != "false" ]]; then
    degraded_reason="$(jq -r '.startup_self_check.degraded_reason // "none"' <<<"${diagnostics_json}")"
    echo "expected startup_self_check.degraded=false, got: ${degraded_flag} (${degraded_reason})" >&2
    exit 1
  fi
fi

if [[ -n "${EXPECT_SCHEDULER_BACKEND}" ]]; then
  echo "[1e] verify scheduler backend (${EXPECT_SCHEDULER_BACKEND})"
  if [[ "${scheduler_backend}" != "${EXPECT_SCHEDULER_BACKEND}" ]]; then
    echo "expected startup_self_check.scheduler_backend=${EXPECT_SCHEDULER_BACKEND}, got: ${scheduler_backend}" >&2
    exit 1
  fi
fi

echo "[2/${total_steps}] provision user"
curl -fsS -X POST "${BASE_URL}/api/v1/users/provision" "${user_auth[@]}" "${json[@]}" \
  -d "{\"user_id\":\"${USER_ID}\"}" >/dev/null

echo "[3/${total_steps}] set settings/heartbeat/cron"
curl -fsS -X PATCH "${BASE_URL}/api/v1/users/${USER_ID}/settings" "${auth[@]}" "${json[@]}" \
  -d '{"assistant_mode":"balanced","proactive_updates":true,"voice_replies":false,"session_timeout_minutes":30}' >/dev/null

curl -fsS -X PUT "${BASE_URL}/api/v1/users/${USER_ID}/heartbeat" "${auth[@]}" "${json[@]}" \
  -d '{"enabled":true,"interval_minutes":30}' >/dev/null

curl -fsS -X POST "${BASE_URL}/api/v1/users/${USER_ID}/cron" "${auth[@]}" "${json[@]}" \
  -d '[{"id":"health-check","expression":"*/30 * * * *","command":"echo tenant-cron-ok"}]' >/dev/null

if [[ "${SMOKE_MODE}" == "full" ]]; then
  echo "[4/${total_steps}] store telegram bot token secret"
  curl -fsS -X PUT "${BASE_URL}/api/v1/users/${USER_ID}/secrets/telegram_bot_token" "${auth[@]}" "${json[@]}" \
    -d "{\"value\":\"${TELEGRAM_BOT_TOKEN}\"}" >/dev/null

  echo "[5/${total_steps}] connect telegram"
  curl -fsS -X POST "${BASE_URL}/api/v1/users/${USER_ID}/channels/telegram/connect" "${auth[@]}" "${json[@]}" \
    -d "{\"bot_token\":\"${TELEGRAM_BOT_TOKEN}\",\"webhook_base_url\":\"${WEBHOOK_BASE_URL}\",\"webhook_secret_token\":\"${TELEGRAM_WEBHOOK_SECRET}\",\"drop_pending_updates\":false}" >/dev/null
fi

step_chat=$( [[ "${SMOKE_MODE}" == "app" ]] && echo 4 || echo 6 )
echo "[${step_chat}/${total_steps}] chat stream"
session_key="agent:zaki-bot:user:${USER_ID}:main"
curl -sS -N -X POST "${BASE_URL}/api/v1/chat/stream" "${auth[@]}" "${json[@]}" \
  -H "X-Zaki-User-Id: ${USER_ID}" \
  -d "{\"message\":\"Say hello from smoke test\",\"session_key\":\"${session_key}\"}" | head -n 20 || true

if [[ "${SMOKE_MODE}" == "full" ]]; then
  echo "[7/${total_steps}] telegram webhook + duplicate idempotency"
  update='{"update_id":999001,"message":{"chat":{"id":123456789},"from":{"id":123456789},"text":"hello-from-telegram"}}'
  curl -fsS -X POST "${BASE_URL}/webhook/telegram?user_id=${USER_ID}" \
    -H "Content-Type: application/json" \
    -H "X-Telegram-Bot-Api-Secret-Token: ${TELEGRAM_WEBHOOK_SECRET}" \
    -d "${update}"

  curl -fsS -X POST "${BASE_URL}/webhook/telegram?user_id=${USER_ID}" \
    -H "Content-Type: application/json" \
    -H "X-Telegram-Bot-Api-Secret-Token: ${TELEGRAM_WEBHOOK_SECRET}" \
    -d "${update}"
fi

step_drain=$( [[ "${SMOKE_MODE}" == "app" ]] && echo 5 || echo 8 )
echo "[${step_drain}/${total_steps}] drain and undrain"
curl -fsS -X POST "${BASE_URL}/internal/drain" "${auth[@]}" >/dev/null
curl -sS -o /dev/null -w "ready status after drain: %{http_code}\n" "${BASE_URL}/ready"
curl -fsS -X POST "${BASE_URL}/internal/undrain" "${auth[@]}" >/dev/null

if [[ "${SMOKE_MODE}" == "full" ]]; then
  echo "[9/${total_steps}] disconnect telegram"
  curl -fsS -X DELETE "${BASE_URL}/api/v1/users/${USER_ID}/channels/telegram/disconnect" "${auth[@]}" "${json[@]}" \
    -d "{\"bot_token\":\"${TELEGRAM_BOT_TOKEN}\",\"drop_pending_updates\":false}" >/dev/null
fi

echo ""
echo "smoke test complete (mode=${SMOKE_MODE})"
