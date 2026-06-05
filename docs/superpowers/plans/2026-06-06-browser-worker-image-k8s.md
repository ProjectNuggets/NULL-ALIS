# Browser-Worker Image + K8s Harness — Implementation Plan (Plan 1 of 7)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a hardened, digest-pinned `browser-worker` container image that runs `agent-browser` headless, deployable to a local k3d cluster, with NetworkPolicy egress lockdown proven to block cloud-metadata/RFC1918 while allowing public web — the foundation Plan 2's orchestrator drives.

**Architecture:** A single Debian-slim image with system Chromium (uniform across amd64/arm64 — sidesteps the missing Chrome-for-Testing arm64 build) launched via a `--no-sandbox` wrapper (containers have no setuid sandbox; isolation comes from the pod + NetworkPolicy). Validated on a local k3d cluster (k3s ships a NetworkPolicy controller). gVisor isolation is attempted best-effort and documented; the hardened-pod baseline is the default.

**Tech Stack:** Docker (buildx), Debian bookworm-slim, `agent-browser@0.27.1` (npm), system `chromium`, k3d/k3s, `kubectl`, Kubernetes NetworkPolicy + ResourceQuota + PodSecurity.

> **Reference:** spec at `docs/superpowers/specs/2026-06-05-agent-browser-default-backend-design.md` (§5 image, §8.4 egress/isolation, §9 resource governance, §17 DOKS validation). The headless-in-container behavior, `@eN` snapshot, and `--state` round-trip were already proven in the 2026-06-05 validation spike; this plan codifies that into versioned artifacts + a repeatable harness.

---

## File Structure

All new files; nothing in this plan touches Zig or existing code.

- `deploy/k8s/browser/Dockerfile.worker` — the worker image (system chromium + agent-browser + no-sandbox wrapper, non-root).
- `deploy/k8s/browser/namespace.yaml` — `browser` namespace with PodSecurity `restricted`-ish labels.
- `deploy/k8s/browser/resourcequota.yaml` — caps total pods/CPU/memory in the namespace (§9 ceiling).
- `deploy/k8s/browser/networkpolicy.yaml` — default-deny egress except DNS + public internet, **blocking** RFC1918/link-local/metadata (§8.4 layer 3).
- `deploy/k8s/browser/worker-pod.yaml` — a single hardened test pod (the Deployment/pool comes in Plan 2).
- `deploy/k8s/browser/runtimeclass-gvisor.yaml` — optional gVisor RuntimeClass (best-effort isolation tier).
- `scripts/browser-worker-smoke.sh` — exec-based smoke test: open→snapshot→assert `@eN`.
- `scripts/browser-worker-egress-test.sh` — proves metadata/RFC1918 blocked, public allowed.
- `docs/agent-browser-backend.md` — operator doc (started here; extended in later plans).

---

## Task 1: Worker image — Dockerfile

**Files:**
- Create: `deploy/k8s/browser/Dockerfile.worker`

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# deploy/k8s/browser/Dockerfile.worker
# Browser worker: system Chromium + agent-browser, headless, non-root.
# Uniform across amd64/arm64 (system chromium) — avoids the missing
# Chrome-for-Testing arm64 build. Chromium runs --no-sandbox (no setuid
# sandbox in a container); isolation is provided by the pod + NetworkPolicy.
FROM node:24-bookworm-slim

# tini = PID1 reaper for the agent-browser daemon + chromium child procs.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates fonts-liberation tini chromium \
    && rm -rf /var/lib/apt/lists/*

# Pin agent-browser to the validated version.
RUN npm i -g agent-browser@0.27.1

# --no-sandbox wrapper; agent-browser launches Chromium via --executable-path.
RUN printf '#!/bin/sh\nexec /usr/bin/chromium --no-sandbox --disable-dev-shm-usage "$@"\n' \
      > /usr/local/bin/chromium-ns && chmod +x /usr/local/bin/chromium-ns

# Non-root runtime user; agent-browser writes state under $HOME/.agent-browser.
RUN useradd -m -u 10001 browser
USER browser
WORKDIR /home/browser
# Note: agent-browser is invoked with --executable-path /usr/local/bin/chromium-ns
# explicitly on first `open` (see scripts); no env contract is assumed.

ENTRYPOINT ["tini","--"]
CMD ["sleep","infinity"]
```

- [ ] **Step 2: Build the image (native arch)**

Run:
```bash
docker build -f deploy/k8s/browser/Dockerfile.worker -t browser-worker:dev deploy/k8s/browser
```
Expected: build succeeds, ends with `naming to docker.io/library/browser-worker:dev`.

- [ ] **Step 3: Smoke the image directly with `docker run` (pre-K8s)**

Run:
```bash
docker run --rm browser-worker:dev sh -c '
  agent-browser --executable-path /usr/local/bin/chromium-ns open https://example.com 2>&1 | tail -2
  agent-browser snapshot 2>&1 | head -3
  agent-browser close --all >/dev/null 2>&1
'
```
Expected: prints `✓ Example Domain` and a snapshot line containing `ref=e1`. (This reproduces the validated spike behavior from the versioned image.)

- [ ] **Step 4: Commit**

```bash
git add deploy/k8s/browser/Dockerfile.worker
git commit -m "feat(browser): hardened browser-worker image (system chromium + agent-browser)"
```

---

## Task 2: Namespace + ResourceQuota

**Files:**
- Create: `deploy/k8s/browser/namespace.yaml`
- Create: `deploy/k8s/browser/resourcequota.yaml`

- [ ] **Step 1: Write the namespace manifest**

```yaml
# deploy/k8s/browser/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: browser
  labels:
    # Enforce the PodSecurity "restricted" profile on this namespace.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
```

- [ ] **Step 2: Write the ResourceQuota (the §9 cluster-cost ceiling)**

```yaml
# deploy/k8s/browser/resourcequota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: browser-quota
  namespace: browser
spec:
  hard:
    pods: "20"                 # spec §9 max_total_sessions ceiling
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi
```

- [ ] **Step 3: Commit**

```bash
git add deploy/k8s/browser/namespace.yaml deploy/k8s/browser/resourcequota.yaml
git commit -m "feat(browser): browser namespace (PodSecurity restricted) + ResourceQuota"
```

---

## Task 3: NetworkPolicy — egress lockdown (spec §8.4 layer 3)

**Files:**
- Create: `deploy/k8s/browser/networkpolicy.yaml`

- [ ] **Step 1: Write the NetworkPolicy**

```yaml
# deploy/k8s/browser/networkpolicy.yaml
# Default-deny egress for browser-worker pods, then allow:
#   - DNS to kube-dns
#   - public internet EXCEPT RFC1918 / link-local / cloud-metadata / CGNAT
# This blocks in-page fetch() to 169.254.169.254, the K8s API, and other
# tenants' cluster IPs even after a page has loaded (SSRF layer the URL
# pre-check cannot provide).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: browser-worker-egress
  namespace: browser
spec:
  podSelector:
    matchLabels:
      app: browser-worker
  policyTypes: ["Egress"]
  egress:
    # DNS resolution (UDP+TCP 53) to kube-dns in kube-system.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Public web (HTTP/HTTPS) — everything EXCEPT private/meta ranges.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 169.254.0.0/16     # link-local + cloud metadata
              - 100.64.0.0/10      # CGNAT
      ports:
        - protocol: TCP
          port: 80
        - protocol: TCP
          port: 443
```

- [ ] **Step 2: Commit**

```bash
git add deploy/k8s/browser/networkpolicy.yaml
git commit -m "feat(browser): NetworkPolicy egress lockdown (block RFC1918/metadata)"
```

---

## Task 4: Hardened worker pod manifest

**Files:**
- Create: `deploy/k8s/browser/worker-pod.yaml`

- [ ] **Step 1: Write the pod manifest (PodSecurity restricted-compliant)**

```yaml
# deploy/k8s/browser/worker-pod.yaml
# Single test pod for Plan 1. Plan 2 replaces this with an
# orchestrator-managed Deployment/pool. Labels match the NetworkPolicy.
apiVersion: v1
kind: Pod
metadata:
  name: browser-worker-0
  namespace: browser
  labels:
    app: browser-worker
spec:
  automountServiceAccountToken: false   # workers need no K8s API access
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: worker
      image: browser-worker:dev
      imagePullPolicy: IfNotPresent
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: "500m"
          memory: 1Gi
        limits:
          cpu: "2"
          memory: 2Gi
      volumeMounts:
        - name: home
          mountPath: /home/browser    # $HOME: agent-browser state + daemon socket
        - name: tmp
          mountPath: /tmp             # writable /tmp (rootfs is read-only)
        - name: dshm
          mountPath: /dev/shm         # Chromium shared memory
  volumes:
    - name: home
      emptyDir: {}
    - name: tmp
      emptyDir: {}
    - name: dshm
      emptyDir:
        medium: Memory
        sizeLimit: 256Mi
```

- [ ] **Step 2: Commit**

```bash
git add deploy/k8s/browser/worker-pod.yaml
git commit -m "feat(browser): hardened worker pod manifest (non-root, ro-rootfs, no caps)"
```

---

## Task 5: Local k3d cluster + deploy

**Files:** none (operational); commands only.

- [ ] **Step 1: Create a local k3d cluster**

Run:
```bash
k3d cluster create browser-dev --wait
kubectl cluster-info
```
Expected: `Kubernetes control plane is running at https://...`.

- [ ] **Step 2: Import the worker image into the cluster**

Run:
```bash
k3d image import browser-worker:dev -c browser-dev
```
Expected: `Successfully imported image(s)` (so the pod can `IfNotPresent` it without a registry).

- [ ] **Step 3: Apply namespace, quota, network policy, pod**

Run:
```bash
kubectl apply -f deploy/k8s/browser/namespace.yaml
kubectl apply -f deploy/k8s/browser/resourcequota.yaml
kubectl apply -f deploy/k8s/browser/networkpolicy.yaml
kubectl apply -f deploy/k8s/browser/worker-pod.yaml
kubectl -n browser wait --for=condition=Ready pod/browser-worker-0 --timeout=120s
```
Expected: `pod/browser-worker-0 condition met`.

- [ ] **Step 4: Commit nothing; record success in the doc (Task 8).**

---

## Task 6: In-pod smoke test (headless + `@eN`)

**Files:**
- Create: `scripts/browser-worker-smoke.sh`

- [ ] **Step 1: Write the smoke script**

```bash
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
```

- [ ] **Step 2: Make it executable and run it**

Run:
```bash
chmod +x scripts/browser-worker-smoke.sh
./scripts/browser-worker-smoke.sh
```
Expected: ends with `PASS: headless open + @eN snapshot in pod`.

- [ ] **Step 3: Commit**

```bash
git add scripts/browser-worker-smoke.sh
git commit -m "test(browser): in-pod headless + @eN snapshot smoke test"
```

---

## Task 7: Egress test (prove §8.4 layer 3 works)

**Files:**
- Create: `scripts/browser-worker-egress-test.sh`

- [ ] **Step 1: Write the egress test**

```bash
#!/usr/bin/env bash
# scripts/browser-worker-egress-test.sh
# Proves the NetworkPolicy blocks RFC1918 + cloud-metadata egress while
# allowing public HTTPS. Uses node's TCP connect (present in the image) so we
# distinguish "blocked at network layer" (timeout) from "reachable". The
# Kubernetes API ClusterIP is a real RFC1918 endpoint reachable WITHOUT the
# policy, so blocking it genuinely proves enforcement (not just an absent target).
set -euo pipefail
NS=browser
POD=browser-worker-0

probe() {  # host port -> REACHABLE | BLOCKED | BLOCKED:<code>
  kubectl -n "$NS" exec "$POD" -- node -e '
    const net=require("net");
    const s=net.connect({host:process.argv[1],port:+process.argv[2],timeout:5000});
    s.on("connect",()=>{console.log("REACHABLE");s.destroy();process.exit(0)});
    s.on("timeout",()=>{console.log("BLOCKED");s.destroy();process.exit(0)});
    s.on("error",e=>{console.log("BLOCKED:"+e.code);process.exit(0)});
  ' "$1" "$2"
}

API_IP=$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
echo "cluster API ClusterIP (RFC1918): $API_IP"

echo "=== 1. public HTTPS must be REACHABLE ==="
pub=$(probe example.com 443); echo "example.com:443 -> $pub"
echo "$pub" | grep -q REACHABLE || { echo "FAIL: public HTTPS blocked unexpectedly"; exit 1; }

echo "=== 2. in-cluster RFC1918 (API server) must be BLOCKED ==="
api=$(probe "$API_IP" 443); echo "$API_IP:443 -> $api"
echo "$api" | grep -q BLOCKED || { echo "FAIL: RFC1918 reachable — NetworkPolicy NOT enforced"; exit 1; }

echo "=== 3. cloud-metadata IP must be BLOCKED ==="
meta=$(probe 169.254.169.254 80); echo "169.254.169.254:80 -> $meta"
echo "$meta" | grep -q BLOCKED || { echo "FAIL: metadata reachable"; exit 1; }

echo "PASS: public reachable; RFC1918 + metadata blocked (NetworkPolicy enforced)"
```

- [ ] **Step 2: Run it**

Run:
```bash
chmod +x scripts/browser-worker-egress-test.sh
./scripts/browser-worker-egress-test.sh
```
Expected: ends with `PASS: public allowed, metadata blocked`.
> If it FAILS on metadata being reachable, the cluster's CNI is not enforcing NetworkPolicy. k3s enforces it by default; if you swapped CNIs, install a policy-enforcing CNI (Calico/Cilium). Record the outcome in Task 8.

- [ ] **Step 3: Commit**

```bash
git add scripts/browser-worker-egress-test.sh
git commit -m "test(browser): NetworkPolicy egress test (RFC1918 + metadata blocked, public allowed)"
```

---

## Task 8: Isolation-tier spike (gVisor) + operator doc (spec §17)

**Files:**
- Create: `deploy/k8s/browser/runtimeclass-gvisor.yaml`
- Create: `docs/agent-browser-backend.md`

- [ ] **Step 1: Write the optional gVisor RuntimeClass**

```yaml
# deploy/k8s/browser/runtimeclass-gvisor.yaml
# OPTIONAL stronger isolation. Requires the node's containerd to have the
# runsc (gVisor) runtime handler configured. Apply the worker pod with
# spec.runtimeClassName: gvisor to use it. If the handler is absent the
# pod will fail to schedule — that is the signal the tier is unavailable.
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
```

- [ ] **Step 2: Attempt the gVisor tier and record the result**

Run:
```bash
kubectl apply -f deploy/k8s/browser/runtimeclass-gvisor.yaml
# Try a gvisor-scheduled copy of the worker pod:
kubectl -n browser run gvisor-probe --image=browser-worker:dev --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"gvisor","containers":[{"name":"gvisor-probe","image":"browser-worker:dev","command":["sleep","30"]}]}}' \
  2>&1 || true
kubectl -n browser get pod gvisor-probe -o wide 2>&1 || true
kubectl -n browser describe pod gvisor-probe 2>&1 | grep -iE 'runtime|runsc|fail|event' | tail -10 || true
kubectl -n browser delete pod gvisor-probe --ignore-not-found
```
Expected: on stock k3d, the probe will likely stay `Pending`/`ContainerCreating` with a "RuntimeClass handler not found" style event — that confirms gVisor is **not** available on this node, which is the expected local result. Record whichever outcome you observe.

- [ ] **Step 3: Write the operator doc capturing the validated baseline**

```markdown
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
  handler. LOCAL RESULT: <record gVisor probe outcome from Task 8 Step 2>.
- **DOKS ACTION (open):** confirm whether managed DOKS node pools permit a
  `runsc`/Kata RuntimeClass (custom node pool may be required). If not,
  ship the baseline on a dedicated tainted browser node pool.

## Egress
- `networkpolicy.yaml` blocks RFC1918 / link-local / cloud-metadata / CGNAT,
  allows DNS + public 80/443. Proven by `scripts/browser-worker-egress-test.sh`.

## Local dev loop
- `k3d cluster create browser-dev` → `k3d image import browser-worker:dev`
  → `kubectl apply -f deploy/k8s/browser/` → `./scripts/browser-worker-smoke.sh`.
```

- [ ] **Step 4: Run the full apply-all + both tests as a final gate**

Run:
```bash
kubectl apply -f deploy/k8s/browser/
kubectl -n browser wait --for=condition=Ready pod/browser-worker-0 --timeout=120s
./scripts/browser-worker-smoke.sh && ./scripts/browser-worker-egress-test.sh
```
Expected: both scripts end in `PASS`.

- [ ] **Step 5: Commit**

```bash
git add deploy/k8s/browser/runtimeclass-gvisor.yaml docs/agent-browser-backend.md
git commit -m "docs(browser): operator guide + gVisor isolation-tier spike result"
```

---

## Task 9: Teardown helper (clean local state)

**Files:**
- Create: `scripts/browser-worker-teardown.sh`

- [ ] **Step 1: Write the teardown script**

```bash
#!/usr/bin/env bash
# scripts/browser-worker-teardown.sh — remove the local k3d harness.
set -euo pipefail
kubectl delete -f deploy/k8s/browser/ --ignore-not-found || true
k3d cluster delete browser-dev || true
echo "torn down"
```

- [ ] **Step 2: Make executable + commit**

```bash
chmod +x scripts/browser-worker-teardown.sh
git add scripts/browser-worker-teardown.sh
git commit -m "chore(browser): local k3d teardown helper"
```

---

## Done criteria (Plan 1)

- `browser-worker:dev` builds and runs `agent-browser` headless with a working `@eN` snapshot — both via `docker run` and inside a k3d pod.
- The pod is PodSecurity-`restricted` compliant (non-root, ro-rootfs, no caps, no SA token).
- NetworkPolicy proven: public HTTPS allowed, cloud-metadata/RFC1918 blocked.
- gVisor tier attempted; result recorded; DOKS RuntimeClass support flagged as the one open cloud-specific item.
- All artifacts committed under `deploy/k8s/browser/` and `scripts/`.

**Hands off to Plan 2:** the orchestrator (Go) replaces the static `worker-pod.yaml` with managed pods, adds the SandboxProvider seam, session registry, and the HTTP API the native Zig tools will call.
