#!/usr/bin/env bash
# scripts/browser-worker-teardown.sh — remove the local k3d harness.
set -euo pipefail
kubectl delete -f deploy/k8s/browser/ --ignore-not-found || true
k3d cluster delete browser-dev || true
echo "torn down"
