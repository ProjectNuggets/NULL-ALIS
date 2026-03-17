#!/usr/bin/env bash
set -euo pipefail

: "${NAMESPACE:?Set NAMESPACE, e.g. zaki-bot-staging}"
: "${LABEL_SELECTOR:=app.kubernetes.io/name=nullclaw}"
: "${CONTAINER_NAME:=nullclaw}"
: "${SINCE:=30m}"
: "${OUT_DIR:=_artifacts/runtime-evidence}"

mkdir -p "${OUT_DIR}"

pods="$(kubectl -n "${NAMESPACE}" get pods -l "${LABEL_SELECTOR}" -o name)"
if [[ -z "${pods}" ]]; then
  echo "no pods found for selector ${LABEL_SELECTOR} in namespace ${NAMESPACE}" >&2
  exit 1
fi

echo "writing runtime evidence to ${OUT_DIR}"

for pod_ref in ${pods}; do
  pod_name="${pod_ref#pod/}"
  pod_dir="${OUT_DIR}/${pod_name}"
  mkdir -p "${pod_dir}"

  echo "collecting ${pod_name}"

  kubectl -n "${NAMESPACE}" get "${pod_ref}" -o wide > "${pod_dir}/get.txt"
  kubectl -n "${NAMESPACE}" describe "${pod_ref}" > "${pod_dir}/describe.txt"

  kubectl -n "${NAMESPACE}" get "${pod_ref}" -o jsonpath='{range .status.containerStatuses[*]}{.name}{" restart_count="}{.restartCount}{" ready="}{.ready}{" last_exit_code="}{.lastState.terminated.exitCode}{" last_reason="}{.lastState.terminated.reason}{" last_signal="}{.lastState.terminated.signal}{"\n"}{end}' \
    > "${pod_dir}/container-status.txt"

  kubectl -n "${NAMESPACE}" logs "${pod_ref}" -c "${CONTAINER_NAME}" --since="${SINCE}" \
    > "${pod_dir}/logs.txt" 2>&1 || true
  kubectl -n "${NAMESPACE}" logs "${pod_ref}" -c "${CONTAINER_NAME}" --previous --since="${SINCE}" \
    > "${pod_dir}/logs-previous.txt" 2>&1 || true

  grep -E 'chat\.stream\.complete|message\.process|ownership_lock_conflict|session\.lock_wait|/internal/drain|/internal/shutdown|drain|shutdown|warning\(|error\(' \
    "${pod_dir}/logs.txt" > "${pod_dir}/logs-filtered.txt" || true
  grep -E 'chat\.stream\.complete|message\.process|ownership_lock_conflict|session\.lock_wait|/internal/drain|/internal/shutdown|drain|shutdown|warning\(|error\(' \
    "${pod_dir}/logs-previous.txt" > "${pod_dir}/logs-previous-filtered.txt" || true
done

echo "runtime evidence collection complete"
