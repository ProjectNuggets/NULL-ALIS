#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:3000}"
INTERNAL_TOKEN="${INTERNAL_TOKEN:-}"
USER_ID="${USER_ID:-}"
SAMPLES="${SAMPLES:-20}"
SLEEP_MS="${SLEEP_MS:-100}"

if [[ -z "${INTERNAL_TOKEN}" ]]; then
  echo "error: INTERNAL_TOKEN is required" >&2
  exit 2
fi

if [[ -z "${USER_ID}" ]]; then
  echo "error: USER_ID is required" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 2
fi

if ! [[ "${SAMPLES}" =~ ^[0-9]+$ ]] || [[ "${SAMPLES}" -lt 1 ]]; then
  echo "error: SAMPLES must be a positive integer" >&2
  exit 2
fi

if ! [[ "${SLEEP_MS}" =~ ^[0-9]+$ ]]; then
  echo "error: SLEEP_MS must be an integer" >&2
  exit 2
fi

declare -A counts=()
declare -A lock_backends=()

for ((i = 1; i <= SAMPLES; i++)); do
  payload="$(
    curl -fsS \
      -H "X-Internal-Token: ${INTERNAL_TOKEN}" \
      -H "X-Zaki-User-Id: ${USER_ID}" \
      "${BASE_URL}/internal/diagnostics"
  )"

  instance_id="$(jq -r '.instance_id // "unknown"' <<<"${payload}")"
  lock_backend="$(jq -r '.tenant_lock_backend // "unknown"' <<<"${payload}")"

  counts["${instance_id}"]=$(( ${counts["${instance_id}"]:-0} + 1 ))
  lock_backends["${lock_backend}"]=$(( ${lock_backends["${lock_backend}"]:-0} + 1 ))

  if [[ "${SLEEP_MS}" -gt 0 && "${i}" -lt "${SAMPLES}" ]]; then
    sleep "$(awk "BEGIN { printf \"%.3f\", ${SLEEP_MS}/1000 }")"
  fi
done

echo "stickiness probe summary"
echo "  base_url: ${BASE_URL}"
echo "  user_id: ${USER_ID}"
echo "  samples: ${SAMPLES}"
echo "  instances:"
for key in "${!counts[@]}"; do
  echo "    ${key}: ${counts[${key}]}"
done
echo "  tenant_lock_backend:"
for key in "${!lock_backends[@]}"; do
  echo "    ${key}: ${lock_backends[${key}]}"
done

if [[ "${#counts[@]}" -ne 1 ]]; then
  echo "result: FAIL (stickiness drift detected: ${#counts[@]} instances observed)" >&2
  exit 1
fi

echo "result: PASS (single instance observed)"
