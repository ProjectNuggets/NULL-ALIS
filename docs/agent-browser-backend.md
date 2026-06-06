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

## Master key
- The orchestrator encrypts every user auth-state vault under the master key
  read from `AGENT_BROWSER_STATE_MASTER_KEY`, which is wired from the
  `browser-state-master` Secret (`deploy/k8s/browser/orchestrator-secret.example.yaml`
  is a template — never commit a real key). Create the real Secret out-of-band:
  ```
  kubectl -n browser create secret generic browser-state-master \
    --from-literal=master-key="$(openssl rand -hex 32)"
  ```
- The key must be >=32 bytes of CSPRNG entropy. Rotating it re-keys all user
  vaults (they must be re-established). Keep the Secret tightly RBAC'd.
- The orchestrator **fails closed** without it: if the Secret/env var is absent,
  it will not start (or will refuse to persist/inject state), so auth-state is
  never written or read unencrypted.

## Local dev loop
- One-command bring-up: `./scripts/browser-worker-setup.sh` (builds the image,
  creates the k3d cluster `browser-dev`, imports the image, applies all manifests,
  and waits for the pod to be Ready).
- Validate: `./scripts/browser-worker-smoke.sh` then `./scripts/browser-worker-egress-test.sh`.
- Teardown: `./scripts/browser-worker-teardown.sh`.
