#!/usr/bin/env bash
# scripts/browser-worker-teardown.sh — remove the local k3d harness.
set -euo pipefail
# Delete the dev namespace (and everything in it). Avoid `-f <dir>`: the dir now
# holds a prod kustomization.yaml that `kubectl delete -f` cannot parse.
kubectl delete namespace browser --ignore-not-found || true
kubectl delete -f deploy/k8s/browser/runtimeclass-gvisor.yaml --ignore-not-found || true
k3d cluster delete browser-dev || true
echo "torn down"
