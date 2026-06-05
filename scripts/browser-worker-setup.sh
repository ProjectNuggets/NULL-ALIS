#!/usr/bin/env bash
# scripts/browser-worker-setup.sh — stand up the local k3d browser harness.
# k3s ships a kube-router-based NetworkPolicy controller, so egress policy is
# enforced on k3d (verified by browser-worker-egress-test.sh).
set -euo pipefail
docker build -f deploy/k8s/browser/Dockerfile.worker -t browser-worker:dev deploy/k8s/browser
k3d cluster create browser-dev --wait || true
k3d image import browser-worker:dev -c browser-dev
kubectl apply -f deploy/k8s/browser/
kubectl -n browser wait --for=condition=Ready pod/browser-worker-0 --timeout=120s
echo "ready: run ./scripts/browser-worker-smoke.sh && ./scripts/browser-worker-egress-test.sh"
