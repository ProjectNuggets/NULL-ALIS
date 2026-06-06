# Backlog Closure — Implementation Plan (Plan 8 of 8)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** Close **every remaining code/deploy item** in `2026-06-06-hardening-deploy-backlog.md` so nothing is left to do *as code*. After this, the only residual work is purely operational (create live secrets, configure CI registry creds, validate runsc on real DOKS, run the deploy) — none of which is code.

**Branch:** `spec/agent-browser-k8s-backend` in worktree `/Users/nova/Desktop/nullalis-abk8s` (isolated — the main checkout is on another agent's branch; DO NOT touch it).

**Non-code items (closed by decision, no work):** A1 approval policy (resolved by design), A2 session-riding (accepted property of `full`), A5 orchestrator URL pre-check (already shipped in Plan 6), D3 url-logging (accepted, consistent with existing). These get marked CLOSED in the backlog doc in Task 6.

---

## Shared contracts (every task conforms to these — pin them)

### Auth contract (orchestrator ↔ gateway)
- **Bearer:** orchestrator reads env `BROWSER_ORCHESTRATOR_AUTH_TOKEN`. If non-empty, an HTTP middleware requires `Authorization: Bearer <token>` (constant-time compare via `crypto/subtle`) on **all `/v1/...` routes**. `GET /healthz` and `GET /metrics` are exempt (liveness + Prometheus scrape; the ingress NetworkPolicy guards them). If the env is **unset**, log a startup `WARN` ("orchestrator auth DISABLED — set BROWSER_ORCHESTRATOR_AUTH_TOKEN") and allow all — preserves envs that haven't configured it; prod sets it.
- **Ownership:** session-scoped routes (`POST/DELETE /v1/sessions/{id}...`, `GET .../frame`) accept header `X-Nullalis-User: <userID>`. If the header is present **and** the session's stored owner (`meta[id].userID`) is non-empty **and** they differ → `403 {"error":"session owner mismatch"}`. Header absent → skip (bearer already authenticated a trusted caller; back-compat). `DELETE /v1/state` compares the header to the body `user_id` the same way.
- **Zig client** sends both headers on every request when configured (`auth_token`, `user_id`). The token comes from `config.browser.agent_browser.auth_token` or env `BROWSER_ORCHESTRATOR_AUTH_TOKEN`; `user_id` is the per-user binding already used by `bindBrowserSessionTools`.

### Master-key loading (A3)
- main.go: if `AGENT_BROWSER_STATE_MASTER_KEY_FILE` is set, read the key from that file (trim trailing whitespace/newline) — lets the key arrive via a CSI/external-secrets mount the SA can't `get` as env. Else fall back to `AGENT_BROWSER_STATE_MASTER_KEY` (existing). Fail closed if neither yields ≥1 byte.

### Worker pod prod knobs (B7/B9), all env-gated → local k3d unaffected when unset
- `BROWSER_WORKER_IMAGE_PULL_SECRET` → `Spec.ImagePullSecrets`.
- `BROWSER_WORKER_RUNTIME_CLASS` (e.g. `gvisor`) → `Spec.RuntimeClassName`.
- `BROWSER_WORKER_NODE_SELECTOR` as `key=value` → `Spec.NodeSelector`; when set, also add toleration `{key:"nullalis.dev/browser", operator:"Equal", value:"true", effect:"NoSchedule"}` so a dedicated tainted browser node pool schedules workers.

---

## Task 1 — Provider hardening (Go): Frame latency/race + ownership accessor + pod prod knobs
**Files:** `services/browser-orchestrator/{k8s_provider.go,provider.go,k8s_provider_test.go,server_test.go (stub)}`

- [ ] **D1+D2 — Frame in one round-trip, unique temp file.** Replace `Frame()`'s four exec round-trips (screenshot, base64, get url, get title) with a **single** `execRaw` `sh -c` that: makes a unique temp file (`mktemp /tmp/vf.XXXXXX.png`), runs `agent-browser screenshot "$f"`, then emits delimited sections `\nFRAME\n<base64>\nURL\n<url>\nTITLE\n<title>\n` (base64 the png; `agent-browser get url`/`get title`), then `rm -f "$f"`. Parse the sections in Go into `Frame{PNGBase64,URL,Title}` (trim each). This is orchestrator-controlled (no agent input) so bypassing the verb-allowlist via `execRaw` is safe. Keep behavior identical on success; on parse failure return an error (best-effort emit is the caller's concern).
- [ ] **A4 — ownership accessor.** Add `Owner(sessionID string) (string, bool)` to the `SandboxProvider` interface (`provider.go`), implement on `K8sProvider` (read `meta[id].userID` under the mutex), and update the **stub provider** used in `server_test.go` to implement it (return a canned owner). Keep `go build ./... && go vet ./... && go test ./...` green.
- [ ] **B7/B9 — pod prod knobs (env-gated).** In `podTemplate()` add, only when the corresponding env is non-empty: `ImagePullSecrets` (from `BROWSER_WORKER_IMAGE_PULL_SECRET`), `RuntimeClassName` (from `BROWSER_WORKER_RUNTIME_CLASS`), `NodeSelector` (parse `BROWSER_WORKER_NODE_SELECTOR` `key=value`) + the browser-pool toleration. Defaults (all unset) must reproduce the current pod spec exactly. Add a unit test asserting: unset → no runtimeClass/nodeSelector/pullSecret; set → present.
- [ ] `GOTOOLCHAIN=local go test ./...` green; pins held (k8s v0.31.1, go 1.23). Commit `feat(orchestrator): single-roundtrip frame + owner accessor + env-gated pod prod knobs (pull-secret/runtimeclass/nodeselector)`.

## Task 2 — Core hardening (Go): bearer auth + ownership + lifecycle + bounded rate-limiter + key-file
**Files:** `services/browser-orchestrator/{main.go,server.go,caps.go,server_test.go,caps_test.go}`

- [ ] **A4 bearer middleware** (server.go): wrap the mux so `/v1/...` requires `Authorization: Bearer <token>` (constant-time) when a token is configured; `/healthz` + `/metrics` exempt; unset token → allow + the caller logged the WARN at startup. Thread the token into `NewServer` (or read env in `Handler()` construction — prefer explicit field set from main.go).
- [ ] **A4 ownership checks** in `handleExec`/`handleCloseSession`/`handleFrame` (via `provider.Owner`) and `handleDeleteVault` (vs body `user_id`) per the contract → 403 on mismatch.
- [ ] **C lifecycle** (main.go): replace `http.ListenAndServe` with an `http.Server{ReadHeaderTimeout:10s, ReadTimeout:65s, IdleTimeout:120s, WriteTimeout:0}` (WriteTimeout 0 with a comment: per-handler `context.WithTimeout` — create=150s — bounds response time; a fixed WriteTimeout < 150s would truncate creates). Add SIGINT/SIGTERM handling: on signal, cancel the **janitor context** and `srv.Shutdown(ctx, 20s)`. Make the janitor goroutine take a `context.Context` and return on `<-ctx.Done()` (stop the ticker).
- [ ] **C bounded rate-limiter** (caps.go): give each bucket a `lastSeen time.Time`; add a `maxBuckets` hard cap and a `sweep()` that drops buckets idle > TTL **and** fully replenished (`limiter.Tokens() >= burst` → no limiting state lost), evicting oldest when over the cap. Run `sweep()` from a goroutine on a ticker tied to the same shutdown context. Unit test: a stale+replenished bucket is swept; an active one is kept; the cap is enforced. (Inject a clock or expose `sweepNow(now)` so the test is deterministic — no `time.Now()` flakiness.)
- [ ] **A3 key-file** (main.go): load master key from `AGENT_BROWSER_STATE_MASTER_KEY_FILE` (file, trimmed) with fallback to the env var; fail closed if neither non-empty.
- [ ] **Tests** (server_test.go): bearer set → no header = 401, wrong = 401, right = 200; ownership: matching `X-Nullalis-User` = 200, mismatched = 403, absent = allowed. `go test ./...` green. Commit `feat(orchestrator): bearer auth + per-session ownership + graceful shutdown + bounded rate-limiter + master-key file`.

## Task 3 — Deploy artifacts (yaml / CI / scripts) — B6/B7/B8
**Files:** `deploy/k8s/browser/{orchestrator-deployment.yaml,orchestrator-secret.example.yaml,kustomization.yaml}`, `scripts/deploy-browser.sh`, `.github/workflows/browser-images.yml`, `docs/agent-browser-deploy.md`

- [ ] **orchestrator-deployment.yaml:** add `imagePullSecrets:[{name: docr-creds}]`; add env `BROWSER_ORCHESTRATOR_AUTH_TOKEN` from `secretKeyRef{browser-orchestrator-auth, token}`; add commented-optional `AGENT_BROWSER_STATE_MASTER_KEY_FILE` + the `BROWSER_WORKER_*` prod knobs with explanatory comments. Keep image refs as placeholders (`registry.digitalocean.com/REPLACE/...`).
- [ ] **orchestrator-secret.example.yaml:** add a second example Secret `browser-orchestrator-auth` (`token: REPLACE_WITH_openssl_rand_hex_32`) with the same "do not commit real" warning + the `kubectl create secret` one-liner.
- [ ] **kustomization.yaml** (prod resource list, in order; **excludes** `worker-pod.yaml` (Plan-1 dev fixture), `*secret.example*`, `runtimeclass-gvisor.yaml` (apply only if the node pool supports it)).
- [ ] **scripts/deploy-browser.sh:** preconditions (real `browser-state-master` + `browser-orchestrator-auth` Secrets + `docr-creds` exist, else abort with the create commands); apply ns→quota→rbac→networkpolicies→deployment; **label the gateway** pod/ns `nullalis.dev/browser-client=true`; explicitly NOT apply worker-pod.yaml; print post-checks. Idempotent; `set -euo pipefail`.
- [ ] **.github/workflows/browser-images.yml:** on push to paths (`services/browser-orchestrator/**`, `deploy/k8s/browser/Dockerfile.worker`), buildx build+push **both** images (amd64+arm64) to DOCR digest-pinned using `secrets.DOCR_TOKEN` + `vars.DOCR_REGISTRY`; output the digests. Document required secrets/vars in a header comment.
- [ ] **docs/agent-browser-deploy.md:** the deploy runbook — the residual *operational* steps (create the 3 secrets, set CI creds, optional gVisor/tainted node pool + the `BROWSER_WORKER_*` envs, run `deploy-browser.sh`), explicitly noting the NetworkPolicy needs a NetworkPolicy-enforcing CNI. `kustomize build` / `kubectl --dry-run=client` validates if available. Commit `feat(deploy): DOCR image CI + pull-secrets + auth secret + kustomize/apply script + deploy runbook`.

## Task 4 — Zig client auth (Zig) — A4 client side
**Files:** `src/browser_backend/client.zig`, `src/config_types.zig`, `src/config_parse.zig`, `src/tools/root.zig` (binding), `scripts/local-e2e-agent-browser.sh`

- [ ] Extend the `Transport.sendFn` signature to carry request headers (or add an explicit `headers` arg), and have `curlSend` forward them via `http_util.curlRequest` (which already accepts a headers slice). Add `auth_token: ?[]const u8 = null` and `user_id: ?[]const u8 = null` to `OrchestratorClient`; build `Authorization: Bearer <token>` and `X-Nullalis-User: <user_id>` headers when set, on **every** request (newSession/exec/getFrame/closeSession). Update `TestTransportPub` + existing tests for the new signature; add a test capturing that the headers are emitted when configured and absent when not.
- [ ] Config: add `auth_token` to the `agent_browser` browser config (`config_types.zig`+`config_parse.zig`); env `BROWSER_ORCHESTRATOR_AUTH_TOKEN` overrides. In `root.zig`, construct the client with `auth_token` + the bound `user_id`.
- [ ] e2e script: export `BROWSER_ORCHESTRATOR_AUTH_TOKEN` for the orchestrator launch **and** for the Zig live test, so the authenticated path is what's exercised. The live test sends the header via the client.
- [ ] `zig build && zig build test` green. Commit `feat(browser): client sends bearer + X-Nullalis-User; auth_token config; authenticated e2e`.

## Task 5 — Extension hardening (Zig + TS) — Plan-7 carry-forwards
**Files:** `src/extension_ws/**` (hub), `.spike/nullalis-extension/**` (client), `.spike/nullalis-extension/vite.config.*`

- [ ] **Read first** the current extension pairing/auth handshake in `src/extension_ws/` and the client. Then add a **per-connection handshake nonce** (server issues a fresh random nonce on connect; the client echoes it in the pair message; the server rejects a stale/replayed nonce) to close the replay gap noted in the Plan-7 decision. Keep it minimal and covered by a unit test on both sides.
- [ ] **Token rotation:** allow the hub to accept a rotated token without dropping config reload semantics (support a current+previous token window, or reload from config/env), so operators can rotate the extension token without a hard cutover. Unit-test acceptance of the new token and rejection after the window.
- [ ] **vite sourcemap:** set `build.sourcemap=false` for the shipped extension build so source isn't shipped in the CRX/zip.
- [ ] `zig build test -Dtest-filter=extension` green; `cd .spike/nullalis-extension && npm run build && npm test` green. Commit `feat(extension): handshake nonce (anti-replay) + token rotation window + sourcemap off`.

## Task 6 — Reconcile the backlog doc + STATUS
**Files:** `docs/superpowers/plans/2026-06-06-hardening-deploy-backlog.md`, `docs/STATUS.md`

- [ ] Mark every item CLOSED with where it was closed (A1/A2/A5/D3 = by decision/already-done; the rest = Plan 8 tasks). Re-title the doc's residual section to **"Deploy Runbook — operational steps only (no code remaining)"** listing: create the 3 secrets, set CI DOCR creds, optional gVisor/tainted node pool, run `deploy-browser.sh`, validate the CNI enforces NetworkPolicy on DOKS. Update STATUS to "agent-browser backend: code-complete + hardened; deploy = ops-only." Commit `docs: close hardening/deploy backlog — all code done; residual is ops-only`.

---

## Done criteria (Plan 8)
- Orchestrator: bearer auth + ownership enforced (unit-tested 401/403/200); graceful shutdown + bounded rate-limiter + key-file; single-round-trip frame with a unique temp file; env-gated pull-secret/runtimeclass/nodeselector on worker pods. `go test ./...` green, pins held.
- Zig client sends bearer + user headers; authenticated local e2e path. `zig build test` green.
- Deploy: CI image pipeline + pull-secrets + auth secret example + kustomize + apply script + runbook (validates with `--dry-run` where possible).
- Extension: handshake nonce + token rotation + sourcemap off; extension + gateway tests green.
- Backlog doc + STATUS reconciled — **no code item left open**; residual is ops-only.
- Both my worktrees (`nullalis-abk8s`, `zaki-prod feature/browser-view-feed`) committed clean.
