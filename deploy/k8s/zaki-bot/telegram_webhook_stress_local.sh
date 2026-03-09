#!/usr/bin/env bash
set -euo pipefail

: "${BASE_URL:=http://127.0.0.1:3010}"
: "${USER_ID:=42}"
: "${CHAT_ID:=1110331014}"
: "${COUNT:=20}"
: "${CONCURRENCY:=5}"
: "${BASE_ID:=7000000}"
: "${PROMPT:=reply exactly ok no tools}"

SECRET_PATH="${SECRET_PATH:-$HOME/.nullalis/data/users/${USER_ID}/telegram.json}"
if [[ ! -f "${SECRET_PATH}" && "${SECRET_PATH}" == "$HOME/.nullalis/data/users/${USER_ID}/telegram.json" && -f "$HOME/.nullclaw/data/users/${USER_ID}/telegram.json" ]]; then
  SECRET_PATH="$HOME/.nullclaw/data/users/${USER_ID}/telegram.json"
fi
if [[ ! -f "${SECRET_PATH}" ]]; then
  echo "missing secret file: ${SECRET_PATH}" >&2
  exit 1
fi
SECRET="$(jq -r '.webhook_secret_token' "${SECRET_PATH}")"
if [[ -z "${SECRET}" || "${SECRET}" == "null" ]]; then
  echo "missing webhook_secret_token in ${SECRET_PATH}" >&2
  exit 1
fi

RESULTS_FILE="$(mktemp -t telegram-stress-results.XXXXXX)"
cleanup() {
  rm -f "${RESULTS_FILE}"
}
trap cleanup EXIT

run_one() {
  local id="$1"
  local body
  body="$(printf '{"update_id":%d,"message":{"message_id":%d,"chat":{"id":%d,"type":"private"},"from":{"id":%d,"username":"nova"},"text":"%s #%d"}}' \
    "${id}" "${id}" "${CHAT_ID}" "${CHAT_ID}" "${PROMPT}" "${id}")"
  curl -sS -o /dev/null -w "${id} %{http_code} %{time_total}\n" \
    -X POST "${BASE_URL}/webhook/telegram?user_id=${USER_ID}" \
    -H "Content-Type: application/json" \
    -H "X-Telegram-Bot-Api-Secret-Token: ${SECRET}" \
    -d "${body}"
}

for i in $(seq 1 "${COUNT}"); do
  while [[ "$(jobs -p | wc -l | tr -d ' ')" -ge "${CONCURRENCY}" ]]; do
    sleep 0.05
  done
  (
    id=$((BASE_ID + i))
    run_one "${id}" >>"${RESULTS_FILE}"
  ) &
done
wait

echo "status counts:"
awk '{print $2}' "${RESULTS_FILE}" | sort | uniq -c
echo
echo "sample:"
head -n 10 "${RESULTS_FILE}"
