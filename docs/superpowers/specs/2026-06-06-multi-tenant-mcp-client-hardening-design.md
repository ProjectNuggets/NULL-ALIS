---
tags: [prose, prose/specs]
status: draft
date: 2026-06-06
---

# Design: Nullalis MCP hub — foundation & multi-tenant client (native Zig, S-tier)

**Author:** brainstorming session (Mohammad + Claude)
**Date:** 2026-06-06
**Status:** Draft (**rev 5 — S-tier foundation**: hardening integrated into the
plan; stable foundation contracts defined). Conforms to
`2026-06-06-adr-nullalis-mcp-hub-architecture.md`. Pending user review, then
`writing-plans`.

> **This is the FOUNDATION spec.** Everything else — BYO servers, the inbound
> server face (**Spec B**, `2026-06-06-agent-as-mcp-server-design.md`), the
> aggregator, A2A mesh — depends on the contracts in §3–§4. Those contracts are
> designed to be **stable**: additive evolution only, no breaking changes once
> Phase 3 lands.

> **Scope boundary.** Separate workstream from the `agent-browser` K8s backend
> (native tools, not MCP). The per-user-pod stdio idea (§7, Phase 8) reuses that
> workstream's K8s harness.

---

## 1. Context & problem

Nullalis is a self-hosted Zig AI-agent gateway, single binary, multi-tenant via
isolated per-user `TenantRuntime`s (`src/gateway.zig`), and an MCP **client**
(`src/mcp.zig`, `src/mcp/transport.zig`). It also already has a native MCP
**server** (`src/mcp_server.zig`, `src/mcp/server_{auth,handlers,policy,protocol}.zig`)
and OAuth+PKCE (`src/auth.zig`) — see §11. Code recon + a pressure test against
mature reference agents (opencode, claude-code, **hermes**) and best-practice
gateways (IBM ContextForge, Cloudflare MCP Portals, Solo.io) found the client is
**single-tenant in disguise**: correct for one user, latently unsafe the moment a
tenant-sensitive server is wired, and missing the hub/observability/safety layers
that define S-tier in 2026.

### 1.1 Already correct — do not "fix"

- **`McpServer` instances are per-user** (`src/gateway.zig:1990`); the per-server
  mutex (`src/mcp.zig:109`) only serializes *within* a user — the canonical
  isolation primitive, not a cross-tenant bug.
- **Tool concurrency is real but tenant-safe** — thread-per-tool
  (`src/agent/root.zig:2969`), sharing *that user's* `McpServer`/mutex.

### 1.2 The real gaps (verified)

1. **Per-user credential isolation (critical).** Static, boot-time, operator-set
   creds (`src/config_types.zig:1472-1510`), no per-user override, no substitution
   (`src/mcp/transport.zig:176-178`, `:465-468`), no tenant gating
   (`src/gateway.zig:1990`) → one shared identity for all users. Latent → time bomb.
2. **Scaling.** stdio = child per `McpServer` (`src/mcp/transport.zig:157`), eager
   at init (`src/mcp.zig:593`) → N×M children on first request.
3. **Staleness.** Cached `TenantRuntime` (LRU 2048 / TTL 1800s, `:1084-1085`);
   `PUT /secrets` doesn't invalidate (`:19875`) while `PATCH /settings` does
   (`:19574`) → connect-time creds go stale up to 30 min.
4. **Partial transport.** HTTP is POST-only curl (`src/mcp/transport.zig:447-511`):
   no GET stream, no SSE, no `DELETE`, `tools/list_changed` skipped → stale catalog.
5. **Fairness.** Mutex across full round-trip; no per-call timeout/quota.
6. **S-tier layers absent:** no unified registry/policy plane, no observability,
   no tool-poisoning defense, no conformance harness, no scoped tool filtering.

### 1.3 Pressure-test outcome (the S-tier bar)

Architecture validated: unified registry + per-upstream creds + edge auth +
stdio-per-pod are the **consensus pattern**; the native-Zig bet is **proven** (the
server + PKCE already exist). To make the *spec* S-tier, this rev integrates:
A2A (peer protocol — full surface in Spec B), a **conformance harness**,
**OpenTelemetry GenAI tracing**, **tool-poisoning/rug-pull defense**, **edge-trust
invariants**, and **dynamic scoped tool filtering** — woven into the phases (§5),
not appended. Spec-canonical auth model: MCP 2025-06-18 (audience-bound tokens
RFC 8707, re-asserted per request; no token-passthrough; session ≠ identity).

### 1.4 End-state goal (this spec's slice)

> A tenant connects to **any remote MCP server** (operator or BYO) under **their
> own identity**, with **no user affecting another**, credentials **correct**
> (no passthrough) + **fresh** (no staleness), every call **traced**, untrusted
> servers **contained**. Arbitrary stdio = per-user pod (Phase 8). The server face,
> aggregator, and A2A mesh (Spec B) build on the **same stable core**.

## 2. Goals / non-goals

**Goals**
- MCP **off by default in tenant mode**; explicit opt-in; precise shared-identity
  warning.
- Per-tenant **own credential per server, resolved per request** (no staleness).
- A **stable foundation core** (§4): unified tool registry, single policy plane,
  credential resolver, transport vtable, shared session store, telemetry, edge-auth
  contract — reused unchanged by Spec B.
- **Complete native transport** (stdio + Streamable HTTP + SSE) with a
  **conformance harness**.
- **No arbitrary stdio in a shared process, ever**; remote-only shared path; stdio
  long-tail via in-process (blessed) + per-user pod.
- **BYO remote servers** under policy + tool-poisoning defense.
- **S-tier cross-cutting**: OTel tracing, tool-poisoning defense, scoped filtering,
  edge-trust invariants, fail-closed everywhere.

**Non-goals**
- **Single-user mode unchanged** when `!tenant.enabled` (native client + existing
  `mcp serve` keep working).
- Do **not** relax the per-server mutex / frame-routing (verified stability fix);
  Phase 7 adds timeout+quota *around* it.
- Do **not** build the inbound server face / A2A server surface (Spec B). This spec
  only **reserves the seams** and **defines the contracts** they consume.
- Do **not** put inbound OAuth resource-server crypto in-app (edge concern, ADR).
- No MCP `sampling` server-callback (deferred); no Node/TS sidecar (ADR).

## 3. Architecture — the unified core (native Zig)

```
┌─ Nullalis Zig core — THE AUTHORITY (single binary) ─────────────────────────┐
│  Tenancy/identity · encrypted vault (sole secret/token source)              │
│                                                                             │
│  ToolRegistry ───────────────┐   PolicyPlane ──────────┐  Telemetry ─────┐  │
│  agent tools + skills +       │  decide(principal,tool) │  OTel GenAI span │  │
│  client-discovered upstream   │  -> {allow, identity}   │  per tool call   │  │
│  tools; one namespace;        │  + dynamic scoped       │                  │  │
│  provenance; fingerprint/pin  │  filtering              │                  │  │
│  └── consumed by: agent loop (now) AND server face (Spec B)                 │  │
│                                                                             │
│  CredentialResolver ─ per-request: static(credref) | oauth(native, vault)   │
│  SessionStore ─ <user_id>:<session_id>, shared/sticky (Postgres)            │
│  EdgeAuthContract ─ how an injected principal maps to user_id (Spec B uses)  │
│                                                                             │
│  CLIENT FACE (this spec): native MCP client over stdio + Streamable HTTP    │
│    + SSE; discovered tools → registry (fingerprinted); per-request creds.    │
└──────────────────────────────────────────────────────────────────────────┘
        │ JSON-RPC over stdio / Streamable HTTP (native Zig Transport vtable)
        ▼   remote MCP servers (operator + BYO) — remote-only on shared path
```

### 3.1 Per-request credential resolution (kills staleness)

Every tool call resolves the user's credential **fresh** from the vault and
attaches it to **that** request — never baked at connect. `user_id` is captured
from the per-user `TenantRuntime`. Satisfies "auth on every request", minimizes
per-user state.

### 3.2 `credref` — static substitution (pure, tested) — `src/mcp/credref.zig`

| Form | Resolves to | Class |
|---|---|---|
| `${user.secret:KEY}` | `getSecret(user_id, KEY)` (encrypted `user_secrets`, `src/zaki_state.zig:3351`) | per-user |
| `${user.id}` | requesting user's id | per-user (non-secret) |
| `${operator.secret:KEY}` | operator-scoped secret | **shared** |
| `$${` | literal `${` (escape) | — |

**Fail closed** (missing `${user.secret}` ⇒ `error.MissingCredential` → server
absent for that user only); **no silent passthrough** (unknown `${…}` ⇒ error);
**no `${env:VAR}`** (audit-opaque).

### 3.3 Trust + auth classification (`McpServerConfig` new fields)

```
trust: enum { first_party, third_party } = .third_party,  // safe default
auth:  enum { none, static, oauth }      = .static,
allow_shared_identity: bool = false,
```
- **per-user** iff all creds use only `${user.*}` (or `auth=oauth`) → no ack.
- **shared-identity** if any literal/`${operator.secret}` → needs
  `allow_shared_identity=true` in tenant mode, else refused+warned.
- **Token-passthrough guard:** `third_party` + `${user.secret}` in an
  `Authorization`-class header ⇒ WARN (transitional; prefer `auth=oauth`).
- **Status enum** (from opencode): `connected | disabled | failed{err} | needs_auth
  | needs_client_registration{err}`.

## 4. Foundation contracts (stable interfaces — everything depends on these)

These are the load-bearing seams. Once Phase 3 lands they evolve **additively
only**. Shapes are illustrative (final Zig in `writing-plans`).

| Contract | Module | Responsibility | Consumers |
|---|---|---|---|
| **Transport** | `src/mcp/transport.zig` | stdio + Streamable HTTP (GET/POST/DELETE) + SSE; frame routing; `list_changed` surfaced | client face; server face (Spec B) |
| **ToolRegistry** | `src/mcp/registry.zig` (new) | one namespace; provenance (`origin: builtin\|skill\|mcp:<server>\|a2a:<agent>`); **fingerprint + pinned definition + change detection**; `list_changed` refresh | agent loop; server face; aggregator |
| **PolicyPlane** | `src/mcp/policy.zig` (new) | `decide(principal, tool, action) -> Decision{allow, identity_ref, reason}`; **dynamic scoped filtering** (`visibleTools(principal)`); deny-by-default | agent loop; server face |
| **CredentialResolver** | `src/mcp/credential.zig` (new) | `resolve(user_id, server) -> RequestAuth`; providers `static` (credref) + `oauth` (native); fail-closed | client face; aggregator outbound |
| **SessionStore** | `src/mcp/session.zig` (new, Postgres-backed) | `<user_id>:<session_id>` binding; non-deterministic ids; never used for auth; sticky across K8s replicas | client sessions; server face |
| **Telemetry** | `src/mcp/telemetry.zig` (new) | OTel GenAI span per tool call (latency/error/tokens), nested in the model-call trace | all faces |
| **EdgeAuthContract** | doc + `src/mcp/principal.zig` (new) | how an edge-injected principal (header/mTLS claims) maps to `user_id`; **invariant: advertised resource URI == validated-token audience == canonical hub URI**; strip client-supplied identity headers | server face (Spec B) |
| **ServerCatalogView** | derived from ToolRegistry + PolicyPlane | the policy-filtered, per-principal tool slice the server face exposes | server face (Spec B) |

**Provenance + fingerprinting** in `ToolRegistry` is the linchpin for both the
aggregator (re-expose upstream tools) and **tool-poisoning defense** (pin tool
definitions; a silently changed description = rug-pull → quarantine + alert).

## 5. Phases (S-tier; hardening woven in, not appended)

| # | Phase | Dep | Hardening it carries | Value |
|---|---|---|---|---|
| 1 | **Gating + shared-path remote-only + edge-auth contract** | — | shared-identity warning; define EdgeAuthContract + invariants | Closes latent risk *today* |
| 2 | **Native Streamable HTTP/SSE + conformance harness + telemetry** | — | conformance suite (version pin/negotiate, `Last-Event-Id` resume, session DELETE); OTel spans from day one | Full transport; observability foundation |
| 3 | **ToolRegistry + PolicyPlane + resolver + credref + trust + tool-poisoning** | 1,2 | fingerprint/pin/change-detect; description injection scan; dynamic scoped filtering; fail-closed; passthrough WARN | **The stable core** |
| 4 | **Native outbound OAuth client (evolve `src/auth.zig`) + vault tokens** | 2,3 | PKCE/discovery/refresh/RFC 8707; cred re-binding to URL; SSRF on discovery; never forward inbound token | Per-user OAuth; kills passthrough |
| 5 | **In-process blessed local servers** | 2,3 | OSV/desc-scan reused; no user-supplied commands | Common stdio-like, no child proc |
| 6 | **BYO user-registered remote servers** | 3,4 | `mcp_byo` policy; SSRF; tool-poisoning on untrusted; scoped exposure | "Connect to any remote MCP" |
| 7 | **Per-call timeout + per-user quota + fairness** | — | hard per-invocation budget; concurrency quota; transport-tiered throttling | One slow call can't starve a tenant |
| 8 | **Per-user pod stdio execution (K8s)** *(endgame)* | 2; K8s | OSV pre-spawn; process-tree reaping; per-pod egress | Literally *any* MCP incl. arbitrary `npx` |

**Cross-cutting (every phase):** OTel tracing, fail-closed, secret hygiene
(key-names-only logs), edge-trust invariants, and conformance tests. Phases 1, 7
are pure-Zig and independently shippable; **Phase 1 ships first** (safety
insurance — land before any tenant-sensitive server). Phases 2–3 are the stable
foundation Spec B depends on.

### Per-phase specifics
- **P1:** `tenant.mcp_enabled:bool=false`; thread flag into `initMcpTools`
  (`src/gateway.zig:1990`); single-user passthrough / tenant-disabled-skip /
  tenant-enabled-classify branches; **stdio refused on shared path**;
  shared-identity WARN; **write the EdgeAuthContract + the audience/PRM/header
  invariants** (consumed by Spec B; defined now so the core is stable).
- **P2:** complete the native Zig Streamable HTTP client (GET event-stream, SSE
  fallback, session `DELETE`, `Last-Event-Id` resumability) and **surface
  `tools/list_changed`** (today skipped); stand up the **conformance harness**
  (pin + negotiate protocol versions; test against the official MCP inspector) and
  the **Telemetry** contract (OTel GenAI span per call). `mcp.zig` reference only.
- **P3:** `ToolRegistry` + `PolicyPlane` (deny-by-default, building on
  `server_policy.zig`'s proven 7-safe+4-memory posture; add dynamic scoped
  filtering) + `CredentialResolver` + `credref.zig` (pure) + the trust fields;
  per-call `RequestAuth`; **tool-poisoning defense** (fingerprint + pin +
  change-detect + description injection scan, lift from hermes
  `tools/mcp_tool.py:_scan_mcp_description`); status enum; **config-fingerprint
  catalog cache + per-upstream failure isolation** (from openclaw
  `pi-bundle-mcp-runtime.ts`); tool-name namespacing/sanitization + stable sort.
- **P4:** evolve `src/auth.zig` (PKCE/RFC 7636 + device flow already present) →
  add discovery (RFC 8414) + refresh + resource indicators (RFC 8707) + per-server
  scoping; per-user browser consent (localhost callback, double CSRF state); move
  token store from single-user `~/.nullalis/auth.json` to the per-user encrypted
  vault; cred re-binding to server-URL (opencode `auth.ts:69`); SSRF defenses;
  **never forward an inbound token upstream**.
- **P5:** in-process transport for a curated bundled set (claude-code
  `client.ts:909-943`); no `mcp_byo` exposure; OSV/desc-scan reused.
- **P6:** per-user registry (Postgres `user_config` pattern, `src/zaki_state.zig:2801`)
  + merge (collision → operator wins); `tenant.mcp_byo` ∈ `disabled|allowlist|open`;
  registration validation (remote-only, SSRF); untrusted provenance + autonomy
  gating + tool-poisoning defense; scoped exposure.
- **P7:** hard per-invocation wall-clock budget; per-user concurrent-call quota →
  fast "MCP busy"; transport-tiered concurrency (throttle heavier paths); mutex /
  frame-routing untouched; `zig build test-mcp-live` must still pass.
- **P8 (endgame):** user's stdio server in that user's pod/microVM (agent-browser
  K8s harness, `nullalis-abk8s`), bridged over native HTTP; **OSV malware check
  before spawn** (hermes pattern); process-tree reaping; per-pod egress controls.
  Own brainstorm before build.

### A2A (client-side seam)
A2A is a first-class peer protocol (ADR rev 2); the **server** surface (Agent
Cards + Task lifecycle + federation) is **Spec B**. This spec reserves the seams:
`ToolRegistry` provenance includes `a2a:<agent>`, and the `CredentialResolver` +
`PolicyPlane` accept A2A delegation targets so the client face can *consume* A2A
agents once Spec B exists. Mesh loop guards (`max_hops`/`max_depth` + cycle
detection) live with the A2A surface in Spec B.

## 6. "Connect to any MCP" — capability matrix (honest)

| Server kind | Single-user | Tenant mode (this spec) |
|---|---|---|
| Remote HTTP/SSE, operator | ✅ today | ✅ P1–4 |
| Remote HTTP/SSE, user BYO | n/a | ✅ P6 |
| stdio, operator-blessed/bundled | ✅ today | ✅ P5 (in-process) |
| **stdio, arbitrary user `npx`** | ✅ today | ⛔ shared path; ✅ **P8 (per-user pod)** |

After P1–6: any remote MCP + blessed local under the tenant's own identity.
Literally *any* MCP (arbitrary stdio) = P8.

## 7. stdio strategy (the safety law)

**Arbitrary user stdio = arbitrary code execution ⇒ per-user isolation or
nothing.** (1) shared path remote-only; (2) in-process *blessed* (our code, no
child process); (3) per-user pod for arbitrary stdio. Never a shared pod
(claude-code `routes/mcp.ts:130-139`, `execSync` w/ full `process.env`, is the
anti-example).

## 8. Security posture (S-tier, explicit)

- **Token passthrough:** documented anti-pattern; trust-class WARN; native OAuth
  (P4) is the correct path; **inbound tokens never forwarded upstream**.
- **Fail closed:** missing per-user cred ⇒ server absent for that user only.
- **Edge-trust invariants (P1 contract):** only the edge injects identity (mTLS /
  network boundary); app **strips client-supplied identity headers**; **advertised
  resource URI == validated-token audience == canonical hub URI**.
- **Single policy plane:** one `(principal,tool)` decision for the agent loop now
  and the server face later — defeats confused-deputy by construction.
- **Session ≠ identity:** non-deterministic, per-user bound, sticky store, never
  auth.
- **Tool-poisoning / rug-pull:** fingerprint + pin + change-detect; descriptions
  treated as untrusted (injection-scanned); **no dynamic registration on the
  shared path**; OSV pre-spawn for any (per-pod) stdio.
- **Scope minimization + scoped filtering:** registry returns only the caller's
  allowed slice (security control *and* context-bloat fix).
- **SSRF/egress:** OAuth discovery (P4) + BYO registration/per-request (P6) +
  per-pod (P8) — HTTPS-only; block private/link-local/metadata.
- **Observability:** every tool call traced (OTel GenAI) — detection + audit.
- **No principal collapse:** reject any mode flattening users to one identity
  (claude-code `auth.ts:50-66` anti-example).
- **Secret hygiene:** secrets in memory only at call time; logs carry key *names*
  + server names, never values; no npm deps in the auth path.

## 9. Testing strategy (S-tier coverage)

- **`credref` unit** (pure): forms, `$${`, fail-closed, unknown-token, mixed,
  per-user vs shared classification.
- **Resolver:** static + oauth vs mocked vault/token store; refresh; expiry;
  `MissingCredential`.
- **Conformance harness:** Streamable HTTP GET stream + SSE + `DELETE` +
  `Last-Event-Id` resume; protocol-version negotiation; against the official MCP
  inspector. `list_changed` updates the registry.
- **Telemetry:** every tool call emits a span nested in the model trace; error/
  latency recorded.
- **Tool-poisoning:** pinned definition + changed description ⇒ quarantine + alert;
  injection-laden description flagged; OSV check blocks a known-bad pre-spawn.
- **Policy/scoped filtering:** `visibleTools(principal)` returns only allowed
  slice; deny-by-default holds; per-principal differences.
- **Gating matrix:** single-user passthrough; tenant disabled; per-user; third
  `+static` warns; shared without ack refused; with ack allowed+warned; **stdio
  refused on shared path**.
- **Per-request freshness:** rotate secret mid-runtime → next call uses new token
  (targets the `:19875` gap).
- **Edge-trust:** forged client identity header rejected; audience-mismatch
  rejected; inbound token never appears on an upstream request.
- **OAuth:** 401→discovery→token; audience binding; CSRF double-check; SSRF
  rejection of private-range discovery; cred re-binding on URL change.
- **BYO:** registration rejects stdio + private-range URL; policy
  disabled/allowlist/open; operator name shadows user server.
- **Concurrency:** timeout → tool-error; quota → fast busy; **`NULLALIS_MCP_LIVE_TEST=1
  zig build test-mcp-live` passes unchanged**.
- **Cross-tenant isolation:** user A's missing/invalid cred never affects user B;
  same-server-name across tenants never clobbers (opencode `index.ts:119` anti-test).

## 10. Documentation

`docs/mcp-client.md` gains **"Multi-tenant mode"**: gating; the unified core +
edge-auth (link ADR); foundation contracts (§4); capability matrix; credential-ref
table + fail-closed; trust classes + `auth` + native OAuth + passthrough warning;
tool-poisoning posture; tracing; BYO (registration, `mcp_byo`, remote-only/SSRF);
stdio strategy. **Correct the misleading `Bearer ${TOKEN}` example** (lines 33-36,
*not* substituted today) to real `${user.secret:…}` / OAuth forms.

## 11. Code-truth, prior art & references

| Claim | Evidence |
|---|---|
| MCP init per `TenantRuntime`, no gating | `src/gateway.zig:1990` |
| Per-user `McpServer`, per-server mutex | `src/mcp.zig:109`, `:582-685` |
| Static creds, no substitution | `src/config_types.zig:1472-1510`, `src/mcp/transport.zig:176-178,465-468` |
| HTTP = POST-only curl | `src/mcp/transport.zig:447-511` |
| stdio child per server, eager spawn | `src/mcp/transport.zig:157`, `src/mcp.zig:593` |
| TenantRuntime cached LRU+TTL | `src/gateway.zig:1084-1085`, `:2609-2654` |
| Secret PUT doesn't invalidate | `src/gateway.zig:19875` vs `:19574` |
| Tool concurrency real | `src/agent/root.zig:2969` |
| Encrypted per-user vault | `src/zaki_state.zig:3351` |
| **Native MCP server already exists** | `src/mcp_server.zig`, `src/mcp/server_{auth,handlers,policy,protocol}.zig` |
| **Deny-by-default exposure policy** | `src/mcp/server_policy.zig` (7 safe + 4 memory, `NULLALIS_MCP_EXPOSE_ALL`) |
| **OAuth+PKCE+device flow + store** | `src/auth.zig` (RFC 7636/8628) |

**Reuse (verified, lifts cleanly):** hermes `.codex-tmp/hermes-agent/tools/mcp_tool.py`
(`_scan_mcp_description` injection scan, OSV pre-spawn check, `_sanitize_error`
redaction, env-var allowlisting, governed sampling) + `mcp_oauth.py` (PKCE client);
openclaw `src/agents/pi-bundle-mcp-*.ts` (config-fingerprint catalog cache,
per-upstream failure isolation, tool-name namespacing/sanitization, lifecycle
discipline). **Avoid:** openclaw module-global cross-tenant state (`index.ts:119`),
no-`list_changed`; claude-code shared-pod stdio RCE (`routes/mcp.ts:130-139`),
principal-collapse (`auth.ts:50-66`).

**Best-practice gateways validating the pattern:** IBM ContextForge (virtual
servers, A2A federation), Cloudflare MCP Portals, Solo.io Virtual MCP. **No
official Zig SDK** (<https://modelcontextprotocol.io/docs/sdk>); `mcp.zig`
reference only. **Architecture authority:** ADR
`2026-06-06-adr-nullalis-mcp-hub-architecture.md`.

## 12. S-tier readiness

Every S-tier criterion from the pressure test is now in the **plan**, not an
appendix: unified registry + policy plane (P3), edge-auth contract + invariants
(P1), native transport + conformance (P2), per-request per-user creds + native
OAuth (P3–4), tool-poisoning defense (P3/P6/P8), OTel tracing (P2 cross-cutting),
scoped filtering (P3), stdio-per-pod (P8), A2A seam (client) + Spec B (server).
**Confidence the foundation is S-tier and stable: high** — the core contracts (§4)
are explicit and additive-only, half the surface already exists in-repo, and the
design matches the cross-industry consensus. The largest net-new builds are P2
(Streamable-HTTP streaming + conformance) and P8 (per-user pods).
