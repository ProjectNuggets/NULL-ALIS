# Browser backend — deploy runbook (DOKS)

Operational steps to deploy the browser backend to a DigitalOcean Kubernetes
(DOKS) cluster. For architecture, isolation tiers, and the local k3d dev loop
see [`agent-browser-backend.md`](agent-browser-backend.md). Residual hardening
items are tracked in
[`superpowers/plans/2026-06-06-hardening-deploy-backlog.md`](superpowers/plans/2026-06-06-hardening-deploy-backlog.md).

> **CRITICAL — CNI requirement.** The egress and ingress NetworkPolicies are the
> primary access controls (SSRF egress lockdown + orchestrator API ingress gate).
> They are only enforced by a NetworkPolicy-aware CNI. **DOKS default Cilium
> enforces them.** A flannel-only CNI silently no-ops every policy, leaving the
> worker egress and the orchestrator API wide open. Confirm your cluster's CNI
> before relying on these manifests.

## (a) Build & push images

Preferred: the CI workflow [`.github/workflows/browser-images.yml`](../.github/workflows/browser-images.yml)
builds both images (`linux/amd64,linux/arm64`) and pushes them to DOCR on every
push to `services/browser-orchestrator/**` or `deploy/k8s/browser/Dockerfile.worker`
(or via `workflow_dispatch`). Configure once:

- `secrets.DOCR_TOKEN` — DigitalOcean API/registry token.
- `vars.DOCR_REGISTRY` — e.g. `registry.digitalocean.com/nullalis`.

Manual fallback (buildx):

```sh
export DOCR_TOKEN=...           # DO API/registry token
export DOCR_REGISTRY=registry.digitalocean.com/nullalis
echo "$DOCR_TOKEN" | docker login registry.digitalocean.com -u "$DOCR_TOKEN" --password-stdin
TAG="$(git rev-parse HEAD)"

docker buildx build --platform linux/amd64,linux/arm64 --push \
  -f services/browser-orchestrator/Dockerfile \
  -t "$DOCR_REGISTRY/browser-orchestrator:$TAG" services/browser-orchestrator

docker buildx build --platform linux/amd64,linux/arm64 --push \
  -f deploy/k8s/browser/Dockerfile.worker \
  -t "$DOCR_REGISTRY/browser-worker:$TAG" deploy/k8s/browser
```

Then edit `deploy/k8s/browser/orchestrator-deployment.yaml`: replace
`REPLACE_REGISTRY` (e.g. `nullalis`) and `REPLACE_TAG` (the SHA) in both the
container `image` and the `BROWSER_WORKER_IMAGE` env.

## (b) Create the three Secrets

These are created out-of-band and never committed (see
`orchestrator-secret.example.yaml` for templates).

```sh
kubectl create namespace browser --dry-run=client -o yaml | kubectl apply -f -

# Master key — encrypts every user auth-state vault. >=32 bytes CSPRNG.
kubectl -n browser create secret generic browser-state-master \
  --from-literal=master-key="$(openssl rand -hex 32)"

# Orchestrator HTTP API bearer token. If absent the orchestrator disables auth
# (WARN) and relies solely on the ingress NetworkPolicy.
kubectl -n browser create secret generic browser-orchestrator-auth \
  --from-literal=token="$(openssl rand -hex 32)"

# DOCR image pull secret.
kubectl -n browser create secret docker-registry docr-creds \
  --docker-server=registry.digitalocean.com \
  --docker-username="$DOCR_TOKEN" \
  --docker-password="$DOCR_TOKEN"
```

## (c) Optional — stronger worker isolation

Pick one (or both). Defaults ship the validated baseline (PodSecurity
`restricted`, non-root, ro-rootfs, drop-ALL caps, seccomp, egress NetworkPolicy).

**gVisor (runsc):** only on a node pool whose containerd has the `runsc` handler.

```sh
kubectl apply -f deploy/k8s/browser/runtimeclass-gvisor.yaml
# then set on the orchestrator Deployment:
#   env BROWSER_WORKER_RUNTIME_CLASS=gvisor
```

(Verify DOKS supports `runsc` on the target pool — managed pools may not. See
the gVisor note in `agent-browser-backend.md`.)

**Dedicated tainted node pool:** isolate worker pods on their own nodes.

```sh
kubectl taint nodes <node> nullalis.dev/browser=true:NoSchedule
kubectl label nodes <node> nullalis.dev/pool=browser
# then set on the orchestrator Deployment:
#   env BROWSER_WORKER_NODE_SELECTOR=nullalis.dev/pool=browser
```

## (d) Deploy

```sh
./scripts/deploy-browser.sh
```

The script verifies the three Secrets exist, applies
`kubectl apply -k deploy/k8s/browser` (kustomize), and prints rollout status.
It intentionally does **not** apply `runtimeclass-gvisor.yaml` or
`worker-pod.yaml`. It is idempotent — safe to re-run.

## (e) Label the gateway

The orchestrator API ingress is restricted to clients labelled
`nullalis.dev/browser-client=true`. `deploy-browser.sh` attempts this using
`GATEWAY_NAMESPACE` (default `nullalis`) / `GATEWAY_POD_SELECTOR`; if the target
is absent it prints the command instead of failing. Apply manually if needed:

```sh
# label the gateway namespace…
kubectl label namespace nullalis nullalis.dev/browser-client=true --overwrite
# …or the gateway pods
kubectl -n nullalis label pods -l app=gateway nullalis.dev/browser-client=true --overwrite
```

Without this label the gateway cannot reach the orchestrator.
