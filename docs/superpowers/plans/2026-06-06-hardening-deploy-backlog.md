# Browser Backend — Hardening & Deploy Backlog (CLOSED)

> Captured 2026-06-06 after the end-to-end integration (Plans 1–4) + a holistic
> cross-component code review. The FIX-NOW items from that review were fixed +
> validated at capture time (allowlist flag hardening, exec-path server
> injection, exit_code honoring, 429 distinction, orchestrator Dockerfile,
> ingress NetworkPolicy, config.example stanza). This file tracked what was
> deliberately deferred — product decisions and larger deploy work.
>
> **STATUS (2026-06-06): all code/deploy items below are CLOSED.** They were
> either implemented in **Plan 8** (`2026-06-06-backlog-closure.md`, Tasks 1–5)
> or resolved **by decision** (no code). Nothing remains to do *as code*. The
> only residual work is purely **operational** — see
> [**Deploy Runbook — operational steps only**](#deploy-runbook--operational-steps-only-no-code-remaining)
> at the bottom and the full runbook at
> [`docs/agent-browser-deploy.md`](../../agent-browser-deploy.md).
>
> **Honesty note:** the deploy pipeline (CI→DOCR) and gVisor RuntimeClass are
> *authored* but **NOT yet exercised on a real DOKS cluster** — there are no DOCR
> credentials or managed cluster wired up here. They are validated only by build/
> dry-run where possible; first live deploy still needs to confirm them.

## A. Security / autonomy

1. **CLOSED — by decision (resolved by design, operator decision 2026-06-06).** Approval policy & `risk_level`: `ApprovalPolicy.forTool` branches on `read_only`/`mutating`, not `risk_level`, so in **`full` autonomy** all mutating tools (incl. `browser_*`/`extension_*` on logged-in sessions) auto-approve. **Decision: this is intended** — choosing `full` autonomy *is* the operator opting into unattended action on logged-in sessions; there is **no hard floor** in `full`. `supervised` keeps its existing `confirm_once` for mutating tools; `read_only` keeps `deny` for mutating. No code change. (If a future operator wants a floor, the lever is wiring `risk_level`/`auth_profile` into `forTool` — left unwired by design.) Session-riding (#2) is therefore an accepted property of `full` autonomy.

2. **CLOSED — by decision (accepted property of `full`, mitigated by #1).** Session-riding read-exfil (MEDIUM-HIGH): a logged-in session lets the agent `snapshot`/`get`/`screenshot` the user's authenticated content back to itself — inherent to the feature; the #1 approval gate is the mitigation, plus a prompt-injection-aware posture (page content is untrusted input).

3. **CLOSED — Plan 8 Task 2 (key-file loading; remaining blast radius is inherent + ops-mitigated).** Master-key blast radius (HIGH, largely inherent): the orchestrator holds the HKDF master key **and** can `get` all `bstate-*` vault Secrets in `browser` ns → a running-orchestrator compromise decrypts every user's vault. Per-user HKDF only protects at-rest. **Code closure:** the master key is now loadable from a file via `AGENT_BROWSER_STATE_MASTER_KEY_FILE` (precedence over the env var), enabling a CSI/external-secrets mount the SA can't `get` as env. Residual mitigations are operational: run the orchestrator in Nullalis's security sandbox, point the key at a KMS/external-secrets mount, keep `browser` ns free of unrelated secrets. RBAC already lacks `list` (good).

4. **CLOSED — Plan 8 Task 1 (owner accessor) + Task 2 (server) + Task 4 (client).** Orchestrator app-layer auth + per-session ownership (defense beyond the ingress policy): the HTTP API was unauthenticated. **Code closure:** orchestrator bearer auth (`BROWSER_ORCHESTRATOR_AUTH_TOKEN`, constant-time compare, `/healthz`+`/metrics` exempt; unset → startup WARN + allow for back-compat) + a per-session ownership check (`X-Nullalis-User` vs the stored owner `meta[id].userID`, 403 on mismatch) on `exec`/`close`/`frame`/`delete-vault`. The Zig client sends `Authorization: Bearer` + `X-Nullalis-User` on **every** request (`auth_token` config + `BROWSER_ORCHESTRATOR_AUTH_TOKEN` env override; owned per-tenant `user_id`).

5. **CLOSED — already shipped in Plan 6 (close as done).** Orchestrator-side URL pre-check (defense-in-depth): `browser_navigate`/`browser_exec` URLs are pre-checked in the orchestrator on `open`/`goto`/`navigate` reusing the shared SSRF block-list (single-source with Plan 6); the pod NetworkPolicy remains the enforced backstop. **The NetworkPolicy requires a NetworkPolicy-enforcing CNI** (silent no-op otherwise — Cilium/Calico/k3s enforce; flannel-only does not) — validating this on DOKS is an ops step (see runbook).

## B. Deployability

6. **CLOSED — Plan 8 Task 3.** Image build+push pipeline: GitHub Actions CI builds **both** images (`linux/amd64,linux/arm64`) and pushes them digest-pinned to DOCR — `.github/workflows/browser-images.yml` (triggers on `services/browser-orchestrator/**` and `deploy/k8s/browser/Dockerfile.worker`, plus `workflow_dispatch`; uses `secrets.DOCR_TOKEN` + `vars.DOCR_REGISTRY`). *Authored, not yet run against a real DOCR — first push must confirm.*

7. **CLOSED — Plan 8 Task 1 (worker) + Task 3 (orchestrator).** DOCR pull creds: `imagePullSecrets` on the orchestrator Deployment + env-gated `BROWSER_WORKER_IMAGE_PULL_SECRET` in the Go `podTemplate()` for worker pods (unset → pod spec unchanged, local k3d unaffected).

8. **CLOSED — Plan 8 Task 3.** Coherent apply: `deploy/k8s/browser/kustomization.yaml` (prod resource list in order; **excludes** the Plan-1 dev `worker-pod.yaml`, `*secret.example*`, and `runtimeclass-gvisor.yaml`) + `scripts/deploy-browser.sh` (secret preconditions for the 3 Secrets, `kubectl apply -k`, gateway labeling `nullalis.dev/browser-client=true`, idempotent, `set -euo pipefail`) + the [`docs/agent-browser-deploy.md`](../../agent-browser-deploy.md) runbook.

9. **CLOSED — Plan 8 Task 1.** Node-pool isolation / gVisor on DOKS: env-gated `BROWSER_WORKER_RUNTIME_CLASS` (e.g. `gvisor`) + `BROWSER_WORKER_NODE_SELECTOR` (`key=value`) + the browser-pool toleration in the worker `podTemplate()`; `deploy/k8s/browser/runtimeclass-gvisor.yaml` exists (applied only where the node pool supports `runsc`). Baseline (hardened pods + NetworkPolicy) ships without gVisor. *gVisor/runsc not yet validated on a managed DOKS pool — confirm on the target pool before enabling.*

## C. Plan-3b carry-forwards — CLOSED (Plan 8 Task 2)
- **CLOSED — Plan 8 Task 2.** Orchestrator HTTP `ReadHeaderTimeout`/`ReadTimeout`/`IdleTimeout` (WriteTimeout 0 by design — per-handler `context.WithTimeout` bounds response time, e.g. create=150s) + SIGINT/SIGTERM graceful shutdown (`srv.Shutdown`) + cancellable janitor context.
- **CLOSED — Plan 8 Task 2.** Rate-limiter per-user bucket map is now bounded: each bucket carries `lastSeen`, with a `maxBuckets` hard cap and a `sweep()` (on a ticker tied to the shutdown ctx) dropping buckets idle past TTL **and** fully replenished, evicting oldest over the cap.
- **CLOSED — already done.** `EXEC_PATH` is injected by the orchestrator (resolved the earlier carry-forward at capture time).

## D. Plan-5 view-feed carry-forwards — CLOSED
- **CLOSED — Plan 8 Task 1.** Frame-fetch latency + `/tmp/vf.png` race (D1+D2): `Frame()` is now a **single** pod-exec round-trip (was 4: `screenshot`+`base64`+`get url`+`get title`) using a **unique** `mktemp` temp file (was the fixed `/tmp/vf.png` that could race on concurrent same-session calls), with delimited sections parsed in Go and base64 whitespace stripped (GNU base64 line-wrap).
- **CLOSED — by decision (accepted, consistent with existing).** `url` logged in the log/otel sink arms (PNG is not) — consistent with existing URL logging; revisit if URL-logging policy tightens.

---

## Deploy Runbook — operational steps only (no code remaining)

**All code and deploy artifacts are authored and committed.** What remains is
purely operational and cluster-specific — there is no code to write. Full steps,
commands, and CNI caveat are in [`docs/agent-browser-deploy.md`](../../agent-browser-deploy.md).
Residual ops steps:

1. **Create the 3 Secrets** in the `browser` namespace (out-of-band, never committed):
   `browser-state-master` (HKDF master key, ≥32 bytes CSPRNG),
   `browser-orchestrator-auth` (bearer `token`), and `docr-creds` (DOCR image pull).
2. **Set CI DOCR creds:** `secrets.DOCR_TOKEN` + `vars.DOCR_REGISTRY` so
   `.github/workflows/browser-images.yml` can build+push both images, then pin the
   resulting digests into `orchestrator-deployment.yaml` (image + `BROWSER_WORKER_IMAGE`).
3. **Optional stronger isolation:** apply `runtimeclass-gvisor.yaml` and set
   `BROWSER_WORKER_RUNTIME_CLASS=gvisor` **only** on a node pool whose containerd
   has the `runsc` handler; and/or a dedicated **tainted** browser node pool with
   `BROWSER_WORKER_NODE_SELECTOR`.
4. **Run `scripts/deploy-browser.sh`** (verifies the 3 Secrets, `kubectl apply -k`,
   labels the gateway `nullalis.dev/browser-client=true`; idempotent).
5. **Validate the CNI enforces NetworkPolicy on DOKS.** The ingress (orchestrator
   API gate) and egress (SSRF lockdown) NetworkPolicies are the primary access
   controls and are silently no-ops under a non-enforcing CNI. DOKS default Cilium
   enforces them; confirm before relying on the manifests.

> **Not yet exercised on real DOKS.** The CI→DOCR pipeline and gVisor RuntimeClass
> are authored but unverified against a live managed cluster (no DOCR creds /
> cluster wired up here). Validate them during the first live deploy.
