# Browser Backend — Hardening & Deploy Backlog (from the holistic cross-component review)

> Captured 2026-06-06 after the end-to-end integration (Plans 1–4) + a holistic
> cross-component code review. The FIX-NOW items from that review are **already
> fixed + validated** (allowlist flag hardening, exec-path server injection,
> exit_code honoring, 429 distinction, orchestrator Dockerfile, ingress
> NetworkPolicy, config.example stanza). This file tracks what was deliberately
> deferred — product decisions and larger deploy work — so it isn't lost.

## A. Security / autonomy (needs a product decision or a focused hardening pass)

1. **Approval policy & `risk_level` — RESOLVED BY DESIGN (operator decision, 2026-06-06).** `ApprovalPolicy.forTool` branches on `read_only`/`mutating`, not `risk_level`, so in **`full` autonomy** all mutating tools (incl. `browser_*`/`extension_*` on logged-in sessions) auto-approve. **Decision: this is intended** — choosing `full` autonomy *is* the operator opting into unattended action on logged-in sessions; there is **no hard floor** in `full`. `supervised` keeps its existing `confirm_once` for mutating tools; `read_only` keeps `deny` for mutating. No code change. (If a future operator wants a floor, the lever is wiring `risk_level`/`auth_profile` into `forTool` — left unwired by design.) Session-riding (#2) is therefore an accepted property of `full` autonomy.

2. **Session-riding read-exfil (MEDIUM-HIGH, mitigated by #1).** A logged-in session lets the agent `snapshot`/`get`/`screenshot` the user's authenticated content back to itself — inherent to the feature; the #1 approval gate is the mitigation, plus a prompt-injection-aware posture (page content is untrusted input).

3. **Master-key blast radius (HIGH, largely inherent).** The orchestrator holds the HKDF master key (env) **and** can `get` all `bstate-*` vault Secrets in `browser` ns → a running-orchestrator compromise decrypts every user's vault. Per-user HKDF only protects at-rest. Mitigations: run the orchestrator in Nullalis's security sandbox (it's currently unsandboxed like all MCP/sidecars), move the master key to a KMS/external-secrets the SA can't `get`, and keep `browser` ns free of unrelated secrets. RBAC already lacks `list` (good).

4. **Orchestrator app-layer auth + per-session ownership (defense beyond the ingress policy).** The HTTP API is unauthenticated; the new ingress NetworkPolicy is the access gate. Add bearer/mTLS between gateway↔orchestrator and a `meta[id].userID == caller` ownership check on `exec`/`close`/`delete-vault` for multi-tenant defense-in-depth (session ids are 128-bit random, so cross-tenant requires either reaching `:8080` — now blocked — or guessing an id).

5. **Orchestrator-side URL pre-check (defense-in-depth, already tracked).** `browser_navigate`/`browser_exec` send URLs the gateway doesn't sanitize; the pod NetworkPolicy is the enforced, proven backstop. Add a URL pre-check in the orchestrator on `open`/`goto`/`navigate` (covers both tools), reusing the shared SSRF block-list (single-source with Plan 6). **Document that the NetworkPolicy requires a NetworkPolicy-enforcing CNI** (silent no-op otherwise — k3s/Cilium/Calico enforce; flannel-only does not).

## B. Deployability (a "deploy plan" — mostly forward-looking)

6. **Image build+push pipeline (PLAN-IT).** A CI job to build `Dockerfile.worker` (amd64+arm64) and `services/browser-orchestrator/Dockerfile`, push to DOCR digest-pinned, and set the orchestrator Deployment's `image` + `BROWSER_WORKER_IMAGE` to the pinned DOCR refs. (Today: local `k3d image import` only.)

7. **DOCR pull creds (PLAN-IT).** `kubectl create secret docker-registry` + `imagePullSecrets` on the orchestrator Deployment **and** in the Go `podTemplate()` for worker pods.

8. **Coherent apply (PLAN-IT).** A deploy script / Kustomize overlay that: creates the real `browser-state-master` Secret first (not the placeholder example), creates the DOCR pull secret, applies ns→quota→rbac→netpol→deployment in order, and **skips `worker-pod.yaml`** (a Plan-1 dev fixture used by the smoke/egress scripts — must not run in prod). Also label the gateway pod `nullalis.dev/browser-client: "true"` for the ingress policy.

9. **Node-pool isolation / gVisor on DOKS (PLAN-IT).** Validate `runsc`/Kata RuntimeClass on managed DOKS; if unavailable, a dedicated **tainted** browser node pool + toleration/nodeSelector on worker pods. Baseline (hardened pods + NetworkPolicy) is sufficient to ship without gVisor.

## C. Plan-3b carry-forwards still open
- Orchestrator HTTP `ReadTimeout`/`WriteTimeout`/`IdleTimeout` + graceful shutdown + cancellable janitor context.
- Rate-limiter per-user bucket map is unbounded (cap/LRU/sweep).
- `EXEC_PATH` is now injected by the orchestrator (✅ resolves the earlier carry-forward).
