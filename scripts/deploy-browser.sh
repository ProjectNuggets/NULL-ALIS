#!/usr/bin/env bash
# scripts/deploy-browser.sh — deploy the browser backend to a DOKS cluster.
#
# Idempotent: re-runnable. Uses `kubectl apply -k` (declarative), never create.
# Prerequisites (created out-of-band, NOT in this script — see agent-browser-deploy.md):
#   - Secret browser-state-master      (master-key)
#   - Secret browser-orchestrator-auth (token)
#   - Secret docr-creds                (docker-registry pull secret)
#
# NOT applied here (apply separately where appropriate):
#   - runtimeclass-gvisor.yaml  (only where the node pool supports runsc)
#   - worker-pod.yaml           (Plan-1 dev fixture; prod spawns workers dynamically)
set -euo pipefail

NS="browser"
KUSTOMIZE_DIR="deploy/k8s/browser"

# The orchestrator's NetworkPolicy ingress gate only admits clients labelled
# nullalis.dev/browser-client=true. Point these at the nullalis gateway.
# Defaults assume the gateway runs in the "nullalis" namespace with the label
# applied at the namespace level. Override via env if your topology differs;
# set GATEWAY_POD_SELECTOR to label pods instead of the namespace.
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-nullalis}"
GATEWAY_POD_SELECTOR="${GATEWAY_POD_SELECTOR:-}"   # e.g. "app=gateway"; empty => label the namespace

# Resolve repo root so the script works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

echo "==> Preconditions: required Secrets in namespace '${NS}'"
missing=0
for s in browser-state-master browser-orchestrator-auth docr-creds; do
  if ! kubectl -n "${NS}" get secret "${s}" >/dev/null 2>&1; then
    echo "    MISSING: secret/${s}"
    missing=1
  else
    echo "    ok: secret/${s}"
  fi
done

if [ "${missing}" -ne 0 ]; then
  cat <<EOF

ERROR: one or more required Secrets are missing. Create them, then re-run:

  kubectl create namespace ${NS} --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n ${NS} create secret generic browser-state-master \\
    --from-literal=master-key="\$(openssl rand -hex 32)"

  kubectl -n ${NS} create secret generic browser-orchestrator-auth \\
    --from-literal=token="\$(openssl rand -hex 32)"

  kubectl -n ${NS} create secret docker-registry docr-creds \\
    --docker-server=registry.digitalocean.com \\
    --docker-username="\${DOCR_TOKEN}" \\
    --docker-password="\${DOCR_TOKEN}"
EOF
  exit 1
fi

echo "==> Applying kustomize: ${KUSTOMIZE_DIR}"
kubectl apply -k "${KUSTOMIZE_DIR}"
echo "    NOTE: runtimeclass-gvisor.yaml and worker-pod.yaml are intentionally NOT applied."
echo "          (gVisor: apply only on a runsc-capable node pool; worker-pod: dev fixture.)"

echo "==> Labelling the gateway for the orchestrator ingress NetworkPolicy"
if [ -n "${GATEWAY_POD_SELECTOR}" ]; then
  if kubectl -n "${GATEWAY_NAMESPACE}" get pods -l "${GATEWAY_POD_SELECTOR}" \
       -o name 2>/dev/null | grep -q .; then
    kubectl -n "${GATEWAY_NAMESPACE}" label pods -l "${GATEWAY_POD_SELECTOR}" \
      nullalis.dev/browser-client=true --overwrite
    echo "    labelled pods (${GATEWAY_POD_SELECTOR}) in ns/${GATEWAY_NAMESPACE}"
  else
    echo "    WARN: no pods matching '${GATEWAY_POD_SELECTOR}' in ns/${GATEWAY_NAMESPACE}."
    echo "          Label the gateway manually so it can reach the orchestrator:"
    echo "            kubectl -n ${GATEWAY_NAMESPACE} label pods -l ${GATEWAY_POD_SELECTOR} nullalis.dev/browser-client=true --overwrite"
  fi
else
  if kubectl get namespace "${GATEWAY_NAMESPACE}" >/dev/null 2>&1; then
    kubectl label namespace "${GATEWAY_NAMESPACE}" \
      nullalis.dev/browser-client=true --overwrite
    echo "    labelled ns/${GATEWAY_NAMESPACE}"
  else
    echo "    WARN: namespace '${GATEWAY_NAMESPACE}' not found."
    echo "          Label the gateway namespace (or set GATEWAY_POD_SELECTOR) so it can reach the orchestrator:"
    echo "            kubectl label namespace ${GATEWAY_NAMESPACE} nullalis.dev/browser-client=true --overwrite"
  fi
fi

echo "==> Post-deploy checks"
kubectl -n "${NS}" rollout status deployment/browser-orchestrator --timeout=120s || true
kubectl -n "${NS}" get pods

echo "==> Done."
