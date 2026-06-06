---
tags: [prose, prose/specs]
status: draft
date: 2026-06-05
---

# Design: `agent-browser` on K8s as the default browser-control backend

**Author:** brainstorming session (Mohammad + Claude)
**Date:** 2026-06-05
**Status:** Draft — pending user review, then `writing-plans`.

> **v3.** Runtime pivoted from Vercel Sandbox → **self-hosted K8s (DigitalOcean
> DOKS)** browser pods, behind a provider seam. Transport pivoted from an MCP
> sidecar → **native Zig `browser_*` tools over HTTP** to a browser orchestrator.
> v2's security/cost/concurrency depth is retained. §17 lists residual risks.

> **✅ Validation spike (2026-06-05) — foundational assumption PROVEN.** Installed
> `agent-browser 0.27.1` and ran it for real, headless, **inside a Linux container**:
> `open` → `snapshot` (returned `@e1/@e2` refs) → `screenshot` → encrypted `--state`
> save→close→reopen round-trip all passed (`doctor` 7/0/0). Verb surface matches §4.
> Two concrete findings folded in below: **(a)** Chrome-for-Testing has **no
> linux-arm64 build** → amd64 worker nodes use bundled Chrome, arm64 nodes need
> system `chromium` + `--executable-path` (or the `lightpanda` engine); **(b)**
> Chromium needs `--no-sandbox` in a container (no setuid sandbox without
> `SYS_ADMIN`) → isolation must come from the **pod/gVisor/NetworkPolicy** layer
> (already the §8.4 design), and **(c)** agent-browser **encrypts the state vault
> at rest** via `AGENT_BROWSER_ENCRYPTION_KEY` (writes `.enc`) — we reuse this for
> §6 rather than building crypto.

---

## 1. Context & problem

Nullalis (a self-hosted Zig AI-agent gateway, deployed on a **DigitalOcean DOKS** cluster) has only weak browser surfaces today:

- `src/tools/browser.zig` — `curl` fetch (`read`, dup of `web_fetch`) + system-browser launch (`open`, a no-op on headless hosts). CDP actions were stripped at v1.14.13 ("BROWSER-HONESTY").
- `src/tools/browser_open.zig` — allowlisted system-browser launcher.
- `src/tools/extension_*.zig` (10 tools) + `src/extension_ws/` — drive the **user's real Chrome** over a per-user WebSocket hub. Gateway side shipped (v1.0.0); client (`clients/extension/`) is a v0.1 prototype.
- `.spike/playwright-mcp/` — an unwired Playwright MCP prototype.

So today: internet **read** access exists (`web_search`/`web_fetch`/`http_request`); **interactive, headless, autonomous** browsing does **not**.

Vercel's `agent-browser` ([vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser)) is a Rust CLI+daemon driving headless Chrome over CDP: ~60+ verbs, an accessibility-snapshot `@eN` ref model, auth/state injection, per-action safety flags. **It is just a binary** — it runs anywhere Chromium runs, including a container. We use it as the in-pod engine and run it on our own cluster.

**Goal:** make `agent-browser` running in **K8s browser pods** the **default** browser backend, captured through **native Zig tools**, with a production-grade safety/cost/concurrency posture — while keeping + productionizing the extension as the "real browser" lane and cleaning up superseded surfaces.

The seam exists but is dormant: `BrowserConfig.backend` already defaults to `"agent_browser"` and nothing reads it.

## 2. Goals / non-goals

**Goals**
- `agent-browser` on K8s is the default backend when `config.browser.backend == "agent_browser"`.
- Full verb surface (native ergonomic tools + an `exec` passthrough); `@eN` snapshot model first-class.
- Per-session authenticated automation via encrypted, **per-user-keyed** `--state` injection.
- **Gateway-owned safety**: action-approval, prompt-injection-aware untrusted-content handling, hard resource/cost guardrails.
- **Native cross-session concurrency** (no MCP single-mutex serialization).
- **Runtime stays in-cluster**: logged-in session data never leaves DOKS. A **provider seam** keeps Vercel Sandbox / Browserbase as optional drivers.
- Two lanes (§11): **in-app browser** the user *watches* (pod session streamed to Zaki) + **extension** lane that *controls the user's real browser*.
- Tenant-isolated per-session **view-feed contract** for Zaki.
- Decommission superseded surfaces + dead config (§15). Productionize the extension client.

**Non-goals**
- No `agent-browser` `chat` LLM loop — Nullalis is the brain.
- No **Sandbox co-browse** (forwarding user input into a pod) — in-app lane is watch-only; the extension is the "user drives a real browser" lane.
- No Zaki **UI** work — only the gateway-side contract.
- No MCP for this backend (native tools instead; the MCP client is untouched).
- **Do not** delete `browser.computer_use` config — reserved for host-computer-control (§15).

## 3. Architecture (native Zig tools → HTTP orchestrator → K8s browser pods)

```
Nullalis agent (Zig pod in DOKS)
  ├─ native browser_* tools (mirror extension_*; per-user bound) ── HTTP/JSON ──┐
  │     · we own concurrency (per-session lock, parallel requests)              │
  ├─ action-approval gate (autonomy system)                                     │
  ├─ view-feed proxy (authz) → Zaki                                             ▼
  │                                          browser-orchestrator (NEW K8s Service, control plane)
  │                                            ├─ SandboxProvider seam: [k8s | vercel | browserbase]
  │                                            ├─ k8s driver: create/route browser-worker pods (K8s API)
  │                                            ├─ session→pod registry (shared; any gateway instance)
  │                                            ├─ per-user-keyed encrypted state store (inject/persist)
  │                                            ├─ 3-layer egress control (URL check + --allowed-domains + NetworkPolicy)
  │                                            ├─ caps · warm pool · idle/wall-clock reaper · metrics
  │                                            └─ frame emitter (per session)
  │                                                  │
  │                                                  ▼
  │                                      browser-worker pods (image: Chromium + pinned agent-browser)
  │                                        · agent-browser daemon over CDP
  │                                        · NetworkPolicy egress firewall · isolation tier (see §8.4)
  └─ secrets: state master key, registry creds — via K8s Secrets / external-secrets
```

Three units:

1. **Native Zig `browser_*` tools (new, small).** ~12 thin structs cloned from the `extension_*` pattern: parse args → HTTP POST to the orchestrator → parse JSON result. They carry per-user binding (`bindBrowserSessionTools`, extending the verified `bindExtensionTools` pattern), declare safety metadata directly, and use the existing `http_util` curl client. **No MCP, no alias layer, no `mcp_servers` mutation** — they're first-class tools named `browser_navigate`, etc.
2. **browser-orchestrator (new K8s Service).** The control plane. Owns pod lifecycle via the K8s API, the `SandboxProvider` seam, the state store, egress/SSRF policy, caps, metrics, and frame emission. **Recommended language: Go** (native `client-go`/controller-runtime); Node acceptable (`@kubernetes/client-node`) if matching the existing TS spikes is preferred. Holds the **session→pod registry** centrally, so any gateway instance can serve any user (relaxes the multi-instance affinity concern — §10).
3. **browser-worker pods (new image).** A container image (Chromium + pinned `agent-browser` daemon), pushed to DOCR, **pinned by digest**. One session ⇒ one worker (warm-pooled). The orchestrator dispatches CDP-level commands to the worker's agent-browser daemon.

### Why this shape
- **Native tools** kill the three MCP workarounds (alias/pool/injection) and put approval metadata directly in the autonomy path.
- **K8s runtime** is native to your infra: NetworkPolicy = egress control, HPA/cluster-autoscaler = scaling, your Prometheus = observability, your registry = the "snapshot." Sensitive logged-in-session data **stays in-cluster**.
- **Provider seam** = no lock-in: the orchestrator's `lease/route/destroy` is an interface; `k8s` is default, `vercel`/`browserbase` are optional drivers (e.g. for burst overflow or stronger isolation).

## 4. Tool surface (full value, native)

Every tool takes a `session_id`. Names are clean (`browser_*`) — no prefix.

**Ergonomic (hot path):** `browser_navigate`, `browser_snapshot` (a11y tree + `@e1/@e2` refs), `browser_click`, `browser_type`, `browser_fill_form`, `browser_get_text`, `browser_screenshot`, `browser_wait_for`, `browser_scroll`.

**Full-verb passthrough:** `browser_exec { session_id, command, args[] }` — forwards a *structured* agent-browser invocation (`network`, `cookies`, `storage`, `frame`, `dialog`, `trace`, `console`, `react tree`, `vitals`, `pdf`, `drag`, `upload`, `select`, `check`, `find …`). **Orchestrator enforces a command allowlist** — `eval`/`run-code`, `network route` rewriting, raw CDP are deny-by-default (§8.6).

**Session lifecycle:** `browser_new_session { auth_profile? }` → `{ session_id }` (rate-limited, cap-checked), `browser_close_session`, `browser_list_sessions`.

## 5. Session & worker-pod lifecycle

- **Keying:** `session_id` is an **unguessable random capability** (not user/conversation-derived — §8.2), mapped in the orchestrator registry to `(user_id, pod)`.
- **Warm pool + reapers:** small pre-warmed pod pool; reaped on **idle TTL** *and* a **per-session wall-clock cap** (§9). Scaled by HPA on pool pressure.
- **Image, not snapshot:** the worker image (Chromium + pinned `agent-browser`) is **digest-pinned** in DOCR; rebuilt on version *and* CVE triggers (§8.9). The K8s-native equivalent of the Vercel snapshot. **Validated build (see validation banner at top):** `amd64` image = `npm i -g agent-browser && agent-browser install` (bundled Chrome-for-Testing); **`arm64` image** = `apt install chromium` + run with `--executable-path /usr/bin/chromium` (no CfT arm64 build). Chromium is launched with **`--no-sandbox --disable-dev-shm-usage`** (via the daemon's launch options on first `open`); pod/gVisor/NetworkPolicy provide isolation.
- **Per-command persistence:** agent-browser's daemon keeps page/cookie state across commands within a session's pod.

## 6. Authentication / state injection

- **Store:** per-user encrypted `--state` (cookies + localStorage; validated format `{cookies, origins}`), keyed `(user_id, auth_profile)`, in the orchestrator. **Per-user key derivation** (HKDF from a K8s-Secret/external-secrets master key + `user_id`) — one key never decrypts all vaults (§8.5). **Reuse agent-browser's built-in vault encryption:** pass the derived key as **`AGENT_BROWSER_ENCRYPTION_KEY`** into the pod so `state save` writes an encrypted `.enc` vault and `--state` decrypts it (validated — see banner at top) — no bespoke crypto.
- **Inject on create:** `browser_new_session { auth_profile }` writes the (encrypted) state into the worker pod and the daemon launches with `--state` on first `open`.
- **Persist on teardown, domain-scoped:** re-encrypt updated state on close/evict — **only** cookies/storage for the auth_profile's declared domain(s), so a wandered session can't poison the stored profile.
- **First-login/2FA:** seeded operationally or via the extension lane.
- **Boundary:** decrypted state lives only in orchestrator + worker pod; never reaches the gateway.

## 7. Data flow (representative)
`browser_new_session{auth_profile}` → orchestrator leases a warm pod, injects state, returns `session_id` → `browser_navigate` → `browser_snapshot` (`@eN`) → **approval gate if next action is state-changing** (§8.1) → `browser_click{ref:"@e7"}` → exotic via `browser_exec` → `browser_close_session` persists domain-scoped state, reaper deletes the pod. Gateway↔orchestrator is HTTP/JSON inside the cluster; the gateway never touches a cloud provider API.

## 8. Security, safety & threat model

The agent reads **untrusted page content** and acts on the user's **logged-in** sessions — the highest-blast-radius capability. Safety is gateway-owned, fail-safe, layered.

**8.1 Action approval (gateway-owned, fail-safe).** State-changing actions on authenticated sessions require approval by default. Tools declare `ToolMetadata{ mutating=true, risk_level=high }` (verified gating via `AutonomyConfig.require_approval_for_medium_risk` — [config_types.zig:81](src/config_types.zig:81)); a **destructive-action classifier** (submits, payments, sends, deletes, downloads) escalates to `risk_level=critical` → always-approve, surfaced through the Zaki view-feed (the human is already watching). agent-browser's own `--confirm-actions` is an *additional* layer with a safe non-empty default.

**8.2 View-feed authz & tenant isolation.** `session_id` is an unguessable capability bound to its owner; the view-feed proxy authenticates each subscriber and enforces `session.owner == subscriber` on **every** frame.

**8.3 Prompt injection.** Page-derived text (`get_text`, `snapshot`, console, DOM) is fenced as **untrusted input**, not instructions; §8.1 approval is the backstop.

**8.4 Egress / SSRF — three layers, K8s-native.** (1) URL pre-check in the orchestrator (reuse the spike's block-list). (2) `agent-browser --allowed-domains` (verify it governs sub-resources/`fetch`/XHR/WebSocket). (3) **`NetworkPolicy`** (and/or a Cilium/egress-gateway policy) on the worker pods blocking link-local/`169.254.169.254`/RFC1918/cluster-internal CIDRs, so an in-page `fetch()` or redirect/DNS-rebind cannot reach cloud metadata, the K8s API, or other tenants' services. This is the layer a URL string check can't provide — and on K8s it's a first-class primitive.
> **Isolation tier (the one real tradeoff vs microVMs):** pods share the host kernel. Ladder: hardened PodSecurity + seccomp + read-only rootfs + NetworkPolicy (baseline) → **gVisor** (`runsc` RuntimeClass) → **Kata Containers** (microVM-grade). **DOKS caveat:** managed DOKS may not permit custom node runtimes/RuntimeClass without a dedicated/custom node pool — **validate before committing to a tier** (§17). Until validated, default to the hardened-pod baseline on an isolated, tainted node pool dedicated to browser workers.

**8.5 Secrets, key management, blast radius.** State master key + registry creds via K8s Secrets / external-secrets (not raw `config.json`). Per-user key derivation (§6). Rotation: re-derive + re-encrypt on master-key rotation. **Blast radius:** orchestrator compromise = ability to decrypt vaults *as users are active* + pod-spawn rights (bounded by its RBAC ServiceAccount — scope it tightly to the browser namespace). Per-user derivation limits at-rest exposure.

**8.6 `browser_exec` allowlist.** Deny-by-default `eval`/`run-code`, `network route` rewriting, raw CDP; allow safe read/inspect/interact verbs. Enforced in the orchestrator.

**8.7 File downloads/uploads.** Downloads land in a size-capped, content-type-checked sink in the pod; transfer to the agent workspace is explicit, sanitized filenames (no traversal), size-limited. Uploads restricted to an allowlisted source. If not built this milestone, disable those verbs via 8.6.

**8.8 PII / retention.** View-feed frames are **ephemeral (retention 0)**. Logs redact tokens-in-URLs, form values, snapshot text. The encrypted, per-user-keyed, domain-scoped state store is the only persisted sensitive data.

**8.9 Supply chain & licensing.** Worker image pinned by digest; rebuild on agent-browser/Chromium version **and** CVE triggers. One-line license check (agent-browser + Chromium redistribution in the image) before publishing.

## 9. Resource governance, cost & observability

In-milestone config, hard limits:
- **`max_sessions_per_user`** (default 3), **`max_total_sessions`** (default 20) — `new_session` fails closed past the cap (and bounded by cluster capacity / namespace ResourceQuota).
- **`session_wall_clock_ms`** (default 600_000) + per-session action budget — reaped/aborted past either.
- **`new_session_rate_limit`** (per-user burst) to protect the warm pool.
- **Resource ceiling:** per-pod CPU/memory limits + a namespace `ResourceQuota` so browser workers can't starve the cluster; HPA/cluster-autoscaler bounds. (Replaces v2's Vercel "spend circuit-breaker" — on your own cluster the ceiling is node capacity + quota, which is the natural cost guard.)
- **Observability (mirrors the extension hub + standard K8s):** live pod/session count, pod-provisioning latency, action latency, error rates, per-user session count — to Prometheus/Grafana.

## 10. Concurrency & scaling

- **Cross-session parallelism is native** — each session has its own worker pod, and the Zig tools issue independent HTTP requests. The MCP per-server mutex ([mcp.zig:282](src/mcp.zig:282)) is **not in the path** at all (we don't use MCP for this).
- **Intra-session serialization:** the orchestrator serializes commands per `session_id` (one pod, ordered actions); distinct sessions run fully in parallel.
- **Multi-instance:** the orchestrator is a clustered K8s Service holding the **shared** session→pod registry, so **any** gateway instance can drive **any** session — no per-instance affinity needed (simpler than v2's lease-bound model). Gateway↔orchestrator load-balances normally.

## 11. The two browser lanes (product end-state)

| | **In-app browser** (agent-browser/K8s) | **Real browser** (extension) |
|---|---|---|
| Engine | Headless Chrome in a K8s worker pod | User's real local Chrome |
| UX | User **watches** the agent (frames → Zaki) | Agent **controls the user's own** browser |
| Auth | Per-user `--state` store | Live logged-in session |
| Best for | Default autonomous browsing, scraping, QA, parallel agents | Logged-in flows, hard logins, user-present actions |
| Status after milestone | New, default | **Productionized** from v0.1 (tracked) |

The extension lane also **seeds credentials** for the in-app lane (§6).

### 11a. In-app view-feed contract
- **What:** after each action + on heartbeat, the orchestrator emits the latest frame for a `session_id` — screenshot + URL/title (+ optional `@eN` snapshot). Reuses the gateway's existing SSE/`StreamCallback`/`ObserverEvent` bus (verified reusable) via a new `browser_frame` event.
- **Authz:** §8.2. **Watch-only** (co-browse is a non-goal). **Boundary:** Zaki consumes `{frame, url, title, lane_status}` through the gateway only.

## 12. Configuration

```jsonc
{
  "browser": {
    "enabled": true,
    "backend": "agent_browser",
    "agent_browser": {
      "orchestrator_url": "http://browser-orchestrator.browser.svc.cluster.local:8080",
      "provider": "k8s",              // SandboxProvider: k8s | vercel | browserbase
      "isolation": "hardened",        // hardened | gvisor | kata  (validate on DOKS — §17)
      "view_feed": true,
      "allowed_domains": [],          // SSRF layer-2 (also -> --allowed-domains)
      "confirm_actions": ["submit","download","payment"],  // safe default, NOT empty
      "max_sessions_per_user": 3,
      "max_total_sessions": 20,
      "session_wall_clock_ms": 600000,
      "new_session_rate_limit_per_min": 6
    }
  }
}
```
- Removed dead fields: `native_headless`, `native_webdriver_url`, `native_chrome_path`, `session_name` (safe — parser ignores unknown fields, verified [config_parse.zig:287](src/config_parse.zig:287)).
- **Kept untouched:** `browser.computer_use.*` (reserved for host-computer-control), annotated "reserved."
- **Orchestrator secrets** via K8s Secrets/external-secrets, never in agent-visible config: state master key, DOCR pull creds. Orchestrator runs under a **tightly-scoped RBAC ServiceAccount** (create/delete pods in the browser namespace only).

Gate on boot when `backend=="agent_browser"` && `browser.enabled`: register the native `browser_*` tools, install `bindBrowserSessionTools` for per-user keying, declare safety metadata, advertise via `capabilities.zig`. (No `mcp_servers`, no alias layer.)

## 13. Error handling & degradation

- Orchestrator unreachable, no capacity, cap/quota hit → structured tool error (`backend_unavailable`, `cap_exceeded`, `no_capacity`); SSRF/policy/approval-deny → `blocked_by_policy`; state decrypt fail → fail closed.
- **Degradation / SPOF (stated & accepted):** with the legacy `browser` tool removed, if the orchestrator/worker pods are down the agent has **no interactive browsing** — it falls back to `web_fetch`/`web_search` for **read-only** retrieval. The extension lane (opt-in, paired) is not a general fallback. Mitigations: warm pool, HPA, multi-replica orchestrator, clear errors.

## 14. Testing strategy

- **Orchestrator unit:** verb mapping, `@eN` parsing, 3-layer egress (lift the spike's sanitize tests), per-user-key derivation + domain-scoped write-back, `browser_exec` allowlist (deny eval/run-code), download-sink limits, caps/rate-limit, frame emission, pod lifecycle (K8s API mocked).
- **Orchestrator integration (gated, real cluster / kind):** new-session→navigate→snapshot→click→close on a fixture; **egress test asserting in-page `fetch` to `169.254.169.254`/RFC1918 is blocked by NetworkPolicy**.
- **Zig tool tests:** `browser_*` registered with clean names; `bindBrowserSessionTools` keys sessions per user; **legacy `browser`/`browser_open` absent** from registry/metadata/capabilities; safety metadata present; HTTP error paths → clear ToolResult failures.
- **Approval/authz tests:** state-changing action triggers approval; view-feed rejects `owner != subscriber`.
- **E2E smoke:** gateway + orchestrator + real worker pods; concurrency test proving two sessions run without serialization.

## 15. Decommission & cleanup (in-scope, after the backend lands)

**Remove:** `src/tools/browser.zig`, `src/tools/browser_open.zig` (+ registration, metadata, capabilities); `.spike/playwright-mcp/` (lift its SSRF sanitizer/tests into the orchestrator first — single source of truth).
**Remove dead config:** `native_headless`, `native_webdriver_url`, `native_chrome_path`, `session_name`.
**Keep:** `browser.computer_use.*` — reserved for host-computer-control; annotate, don't delete.
**Reconcile docs:** `docs/ROADMAP.md` + `docs/STATUS.md` ("Wave 3" names Playwright MCP → repoint to agent-browser-on-K8s + extension lanes); `docs/sandbox-tool-coverage.md` (`browser` row obsolete → orchestrator trust-boundary note); add `docs/agent-browser-backend.md`.
**SSRF single source:** one documented block-list spec + parity tests shared by the Zig extension-lane sanitizer and the orchestrator sanitizer.
**Productionize extension:** `clients/extension/` → shippable (real icons; **distribution = self-hosted signed CRX via private update URL** for v1; deferred HMAC request-signing).

## 16. Rollout / phasing

0. **Local-first dev loop:** stand up the orchestrator + worker pods on local K8s (kind/k3d/Docker-Desktop) — full develop/E2E cycle before any DOKS deploy; DOKS is the deployment target, not a dev dependency.
1. Worker image (Chromium + pinned agent-browser, digest-pinned in DOCR) + K8s manifests (namespace, tainted node pool, ResourceQuota, NetworkPolicy, RBAC ServiceAccount).
2. Orchestrator skeleton: `SandboxProvider` seam + **k8s driver** (create/route/destroy pods), session registry, health.
3. Core verbs + `@eN` snapshot (orchestrator → worker agent-browser).
4. `browser_exec` passthrough + command allowlist.
5. Auth/state: per-user-keyed store, inject, domain-scoped persist.
6. Security: action-approval gate, prompt-injection fencing, 3-layer egress (incl. NetworkPolicy), secrets/RBAC, isolation-tier validation on DOKS.
7. Resource governance: caps, rate-limit, wall-clock reaper, ResourceQuota/HPA, metrics → Prometheus.
8. Native Zig `browser_*` tools + `bindBrowserSessionTools` + safety metadata + capabilities; **remove** dead config fields.
9. In-app view-feed (§11a): `browser_frame` event, gateway proxy + authz, lane-status.
10. Decommission (§15) + doc reconciliation.
11. Extension productionization.
12. Tests + E2E + operator docs.

## 17. Residual risks — explicitly accepted / to validate

- **Isolation tier on DOKS (must validate).** Pods share a kernel; microVM-grade isolation needs gVisor/Kata, whose support on *managed* DOKS is uncertain. **Action:** validate RuntimeClass support early; if unavailable, ship the hardened-pod baseline on a dedicated tainted node pool + NetworkPolicy, and treat gVisor/Kata as a follow-up. This is the main isolation gap vs Vercel microVMs and is consciously accepted for in-cluster data residency + native ops. *Note:* the orchestrator, workers, NetworkPolicy egress, and even a local gVisor RuntimeClass can be exercised on **local K8s (kind/k3d/Docker-Desktop)** during development — only managed-DOKS runtime-class support is the genuinely cloud-specific unknown.
- **New operational surface.** The orchestrator + worker node pool is infra you run (Go/Node service, image pipeline, autoscaling). Mitigated by it being standard K8s patterns on infra you already operate.
- **Interactive-browsing SPOF** — accepted per §13 (read-only fallback only).
- **Orchestrator trust** — holds the state-decrypt key + pod-spawn RBAC; scope its ServiceAccount tightly and consider running it in its own namespace. (Analogous to v2's "sidecar unsandboxed" risk, but with K8s RBAC as the bound.)

## 18. Files touched (anticipated)

- **New:** `services/browser-orchestrator/` (Go recommended; k8s driver, state store, 3-layer egress, caps, frame emitter) + `deploy/k8s/browser/*` (namespace, node pool, ResourceQuota, NetworkPolicy, RBAC, Deployment), worker `Dockerfile`, `docs/agent-browser-backend.md`.
- **New (Zig):** `src/tools/browser_navigate.zig` … (≈12 native `browser_*` tools, cloned from `extension_*`).
- **Modified (Zig):** `src/config_types.zig` (+`agent_browser` sub-config; remove dead fields; annotate `computer_use`), `src/config_parse.zig`, `src/gateway.zig` (register browser tools, view-feed proxy + authz, action-approval surfacing, metrics), `src/capabilities.zig`, `src/tools/root.zig` (remove `browser`/`browser_open`; register `browser_*`; add `bindBrowserSessionTools`), `src/tools/metadata.zig` (browser safety metadata).
- **Removed:** `src/tools/browser.zig`, `src/tools/browser_open.zig`, `.spike/playwright-mcp/`.
- **Docs updated:** `docs/ROADMAP.md`, `docs/STATUS.md`, `docs/sandbox-tool-coverage.md`.
- **Productionized:** `clients/extension/`.
- **Unchanged:** `src/mcp.zig`, `src/mcp/transport.zig` (not used by this backend), `src/extension_ws/*` (hub), `browser.computer_use` config.
