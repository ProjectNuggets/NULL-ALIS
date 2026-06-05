#!/usr/bin/env bash
# scripts/browser-worker-smoke.sh
# Proves agent-browser runs headless inside the worker pod and the @eN
# snapshot works. Exits non-zero on failure (CI-friendly).
set -euo pipefail
NS=browser
POD=browser-worker-0

out=$(kubectl -n "$NS" exec "$POD" -- sh -c '
  agent-browser --executable-path /usr/local/bin/chromium-ns open https://example.com >/dev/null 2>&1
  agent-browser snapshot 2>&1
  agent-browser close --all >/dev/null 2>&1
')
echo "$out"
echo "$out" | grep -q 'ref=e1' || { echo "FAIL: no @eN ref in snapshot"; exit 1; }
echo "PASS: headless open + @eN snapshot in pod"
