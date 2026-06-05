# Browser backend — operator guide

## Worker image
- `deploy/k8s/browser/Dockerfile.worker`: Debian-slim + system `chromium`
  + `agent-browser@0.27.1`, non-root (uid 10001), Chromium launched
  `--no-sandbox` via `/usr/local/bin/chromium-ns`.
- Uniform across amd64/arm64 (system chromium avoids the missing
  Chrome-for-Testing arm64 build).

## Isolation tier (spec §8.4 / §17)
- **Baseline (default, validated on k3d):** PodSecurity `restricted`,
  non-root, `readOnlyRootFilesystem`, `drop ALL` caps, seccomp
  `RuntimeDefault`, `automountServiceAccountToken: false`, plus the
  egress NetworkPolicy. Chromium `--no-sandbox` (no setuid sandbox in a
  container; isolation is the pod boundary).
- **gVisor (optional, stronger):** apply `runtimeclass-gvisor.yaml` and set
  `runtimeClassName: gvisor`. Requires node containerd to have the `runsc`
  handler. LOCAL RESULT: Not available on stock k3d — probe pod stayed in ContainerCreating with event 'Failed to create pod sandbox: rpc error: code = Unknown desc = failed to get sandbox runtime: no runtime for "runsc" is configured'.
- **DOKS ACTION (open):** confirm whether managed DOKS node pools permit a
  `runsc`/Kata RuntimeClass (custom node pool may be required). If not,
  ship the baseline on a dedicated tainted browser node pool.

## Egress
- `networkpolicy.yaml` blocks RFC1918 / link-local / cloud-metadata / CGNAT,
  allows DNS + public 80/443. Proven by `scripts/browser-worker-egress-test.sh`
  (verified on k3d: public reachable; API ClusterIP + metadata blocked; a
  control pod not selected by the policy reached the API ClusterIP, confirming
  the block is the NetworkPolicy).

## Local dev loop
- `k3d cluster create browser-dev` → `k3d image import browser-worker:dev`
  → `kubectl apply -f deploy/k8s/browser/` → `./scripts/browser-worker-smoke.sh`
  → `./scripts/browser-worker-egress-test.sh`. Teardown: `./scripts/browser-worker-teardown.sh`.
