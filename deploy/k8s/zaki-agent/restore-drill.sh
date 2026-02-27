#!/usr/bin/env bash
set -euo pipefail

: "${NAMESPACE:=zaki-agent-staging}"
: "${APP_SELECTOR:=app.kubernetes.io/name=nullclaw}"
: "${LITESTREAM_S3_BUCKET:?set LITESTREAM_S3_BUCKET}"
: "${LITESTREAM_S3_PREFIX:=nullclaw/users}"
: "${USER_IDS:?set USER_IDS as comma-separated ids (e.g. user-a,user-b)}"

pod="${POD_NAME:-}"
if [[ -z "${pod}" ]]; then
  pod="$(kubectl -n "${NAMESPACE}" get pods -l "${APP_SELECTOR}" -o jsonpath='{.items[0].metadata.name}')"
fi

if [[ -z "${pod}" ]]; then
  echo "no nullclaw pod found in namespace ${NAMESPACE}" >&2
  exit 1
fi

echo "using pod: ${pod}"

failed=0
IFS=',' read -r -a users <<<"${USER_IDS}"
for raw_user in "${users[@]}"; do
  user_id="$(echo "${raw_user}" | tr -d '[:space:]')"
  if [[ -z "${user_id}" ]]; then
    continue
  fi

  remote_url="s3://${LITESTREAM_S3_BUCKET}/${LITESTREAM_S3_PREFIX}/${user_id}/memory.db"
  restore_path="/tmp/restore-drill-${user_id}-memory.db"
  echo "restoring sample user ${user_id} from ${remote_url}"

  if kubectl -n "${NAMESPACE}" exec "${pod}" -c litestream -- /bin/sh -c \
    "set -eu; rm -f '${restore_path}'; litestream restore -if-replica-exists -o '${restore_path}' '${remote_url}' >/dev/null; test -s '${restore_path}'"; then
    echo "  ok: ${user_id}"
  else
    echo "  failed: ${user_id}" >&2
    failed=$((failed + 1))
  fi
done

if [[ "${failed}" -gt 0 ]]; then
  echo "restore drill failed for ${failed} user(s)" >&2
  exit 1
fi

echo "restore drill completed successfully"
