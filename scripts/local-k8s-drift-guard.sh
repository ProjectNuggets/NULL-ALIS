#!/usr/bin/env bash
set -euo pipefail

CANONICAL_NAMESPACE="${CANONICAL_NAMESPACE:-zaki-bot-staging}"
CANONICAL_DEPLOYMENT="${CANONICAL_DEPLOYMENT:-nullclaw}"
ARCHIVED_NAMESPACE="${ARCHIVED_NAMESPACE:-nullalis-local}"
EXPECTED_IMAGE="${EXPECTED_IMAGE:-docker.io/library/nullalis@sha256:6e5819072e7197bb6768ddf73a2641efb8c2ae1cfdeeae660985a1008205cbc9}"
PORT_FORWARD_PORT="${PORT_FORWARD_PORT:-38080}"

required_keys=(
  INTERNAL_SERVICE_TOKEN
  OPENROUTER_API_KEY
  POSTGRES_CONNECTION_STRING
  PGBOUNCER_CONNECTION_STRING
  PGBOUNCER_DB_HOST
  PGBOUNCER_DB_NAME
  PGBOUNCER_DB_PASSWORD
  PGBOUNCER_DB_PORT
  PGBOUNCER_DB_USER
  TELEGRAM_BOT_TOKEN
  TELEGRAM_WEBHOOK_SECRET
)

critical_config_keys=(
  GATEWAY_HOST
  GATEWAY_PORT
  GATEWAY_MAX_WORKERS
  GATEWAY_MAX_QUEUED_REQUESTS
  STATE_BACKEND
  POSTGRES_SCHEMA
  POSTGRES_POOL_MAX
  POSTGRES_STATEMENT_TIMEOUT_MS
  POSTGRES_LOCK_TIMEOUT_MS
  POSTGRES_USE_PGBOUNCER
  PGBOUNCER_PORT
  PGBOUNCER_POOL_MODE
  PGBOUNCER_MAX_CLIENT_CONN
  PGBOUNCER_DEFAULT_POOL_SIZE
  PGBOUNCER_RESERVE_POOL_SIZE
  PGBOUNCER_MIN_POOL_SIZE
  PGBOUNCER_MAX_DB_CONNECTIONS
  SESSION_CROSS_CHANNEL_SHARED_MAIN
  TENANT_DATA_ROOT
  TENANT_RUNTIME_CACHE_MAX_USERS
  TENANT_RUNTIME_IDLE_TTL_SECS
  TENANT_PROACTIVE_DEDUPE_WINDOW_SECS
  TENANT_PROACTIVE_RATE_WINDOW_SECS
  TENANT_PROACTIVE_RATE_LIMIT_PER_WINDOW
)

fail() {
  echo "DRIFT: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

for cmd in kubectl jq curl shasum; do
  need_cmd "$cmd"
done

canonical_replicas="$(kubectl -n "$CANONICAL_NAMESPACE" get deploy "$CANONICAL_DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
[[ "${canonical_replicas}" =~ ^[0-9]+$ ]] || fail "unable to read canonical replica count"
(( canonical_replicas > 0 )) || fail "canonical deployment is scaled to zero"

archived_active="$(kubectl -n "$ARCHIVED_NAMESPACE" get deploy -o json | jq '[.items[] | select((.spec.replicas // 0) > 0)] | length')"
[[ "$archived_active" == "0" ]] || fail "archived namespace still has active deployments"

current_image="$(kubectl -n "$CANONICAL_NAMESPACE" get deploy "$CANONICAL_DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}')"
[[ "$current_image" == "$EXPECTED_IMAGE" ]] || fail "image drift: expected $EXPECTED_IMAGE got $current_image"

secret_name="$(kubectl -n "$CANONICAL_NAMESPACE" get secret -o json | jq -r '.items[] | select(.type=="Opaque") | .metadata.name' | rg '^nullclaw-runtime-secrets$' -m 1)"
[[ -n "$secret_name" ]] || fail "canonical secret not found"

for key in "${required_keys[@]}"; do
  value_b64="$(kubectl -n "$CANONICAL_NAMESPACE" get secret "$secret_name" -o "jsonpath={.data.${key}}" 2>/dev/null || true)"
  [[ -n "$value_b64" ]] || fail "missing secret key: $key"
  value_len="$(printf '%s' "$value_b64" | base64 --decode | wc -c | tr -d ' ')"
  (( value_len > 0 )) || fail "empty secret key: $key"
  echo "secret:$key=present"
done

configmap_name="nullclaw-runtime-config"
config_lines=()
for key in "${critical_config_keys[@]}"; do
  value="$(kubectl -n "$CANONICAL_NAMESPACE" get configmap "$configmap_name" -o "jsonpath={.data.${key}}" 2>/dev/null || true)"
  [[ -n "$value" ]] || fail "missing config key: $key"
  config_lines+=("${key}=${value}")
done

config_fingerprint="$(
  printf '%s\n' "${config_lines[@]}" | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
)"
echo "config_fingerprint_sha256=${config_fingerprint}"

internal_token="$(kubectl -n "$CANONICAL_NAMESPACE" get secret "$secret_name" -o jsonpath='{.data.INTERNAL_SERVICE_TOKEN}' | base64 --decode)"

kubectl -n "$CANONICAL_NAMESPACE" port-forward "svc/${CANONICAL_DEPLOYMENT}" "${PORT_FORWARD_PORT}:80" >/tmp/nullalis-local-drift-guard-port-forward.log 2>&1 &
pf_pid=$!
cleanup() {
  kill "$pf_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT_FORWARD_PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

health_json="$(curl -fsS "http://127.0.0.1:${PORT_FORWARD_PORT}/health")"
ready_json="$(curl -fsS "http://127.0.0.1:${PORT_FORWARD_PORT}/ready")"
diag_json="$(
  curl -fsS "http://127.0.0.1:${PORT_FORWARD_PORT}/internal/diagnostics" \
    -H "X-Internal-Token: ${internal_token}" \
    -H 'X-Zaki-User-Id: 1'
)"

[[ "$(jq -r '.status' <<<"$health_json")" == "ok" ]] || fail "/health is not ok"
[[ "$(jq -r '.status' <<<"$ready_json")" == "ready" ]] || fail "/ready is not ready"
[[ "$(jq -r '.startup_self_check.state_backend_effective' <<<"$diag_json")" == "postgres" ]] || fail "state backend is not postgres"
[[ "$(jq -r '.startup_self_check.degraded' <<<"$diag_json")" == "false" ]] || fail "runtime is degraded"
[[ "$(jq -r '.tenant_lock_backend' <<<"$diag_json")" == "postgres_lease" ]] || fail "tenant lock backend is not postgres_lease"
[[ "$(jq -r '.startup_self_check.chat_provider_effective' <<<"$diag_json")" == "openrouter" ]] || fail "chat provider drift detected"
[[ "$(jq -r '.startup_self_check.postgres_port' <<<"$diag_json")" == "6432" ]] || fail "postgres port drift detected"
[[ "$(jq -r '.effective_config_hash' <<<"$diag_json")" != "null" ]] || fail "effective config hash missing"
[[ "$(jq -r '.effective_config_source' <<<"$diag_json")" == "postgres_seeded_from_file" ]] || fail "unexpected config source"

echo "diagnostics_effective_config_hash=$(jq -r '.effective_config_hash' <<<"$diag_json")"
echo "diagnostics_effective_config_source=$(jq -r '.effective_config_source' <<<"$diag_json")"
echo "diagnostics_backend=$(jq -r '.startup_self_check.state_backend_effective' <<<"$diag_json")"
echo "diagnostics_lock_backend=$(jq -r '.tenant_lock_backend' <<<"$diag_json")"
echo "DRIFT_GUARD_OK"
