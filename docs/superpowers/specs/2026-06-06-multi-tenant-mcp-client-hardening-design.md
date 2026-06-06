---
tags: [prose, prose/specs]
status: draft
date: 2026-06-06
---

# Design: Multi-tenant MCP client hardening + unified hub foundation (native Zig)

**Author:** brainstorming session (Mohammad + Claude)
**Date:** 2026-06-06
**Status:** Draft (**rev 4** — adds S-tier hardening + reference-agent reuse §12
after the pressure test; rev 3 dropped the Node/TS sidecar for the native-Zig
unified-core + edge-auth architecture per
`2026-06-06-adr-nullalis-mcp-hub-architecture.md`). Pending user review, then
`writing-plans`.

> **Architecture is set by the ADR.** This spec is the **client half +
> foundation** of the MCP hub. **Spec B** (`2026-06-06-agent-as-mcp-server-design.md`)
> is the **server half**. Both rev 3 conform to the ADR: one unified native-Zig
> core, two faces, edge inbound auth, native outbound OAuth client, **no
> sidecar**.

> **Scope boundary.** Separate workstream from the `agent-browser` K8s backend
> (native tools, not MCP). The per-user-pod idea for arbitrary stdio (§6, Phase 8)
> deliberately reuses that workstream's K8s harness.

---

## 1. Context & problem

Nullalis is a self-hosted Zig AI-agent gateway, single binary, multi-tenant via
isolated per-user `TenantRuntime`s (`src/gateway.zig`), and an MCP **client**
(`src/mcp.zig`, `src/mcp/transport.zig`). Code recon + a recon of two mature
reference clients (opencode, claude-code) found the client is **single-tenant in
disguise**: correct for one user, latently unsafe the moment a tenant-sensitive
server is wired.

### 1.1 Already correct — do not "fix"

- **`McpServer` instances are per-user** (`src/gateway.zig:1990`); the per-server
  mutex (`src/mcp.zig:109`) only serializes *within* a user — the canonical
  per-user isolation primitive, not a cross-tenant bug.
- **Tool concurrency is real but tenant-safe** — a thread per tool call
  (`src/agent/root.zig:2969`), sharing *that user's* `McpServer`/mutex; never
  crosses tenants.

### 1.2 The real gaps (verified against source)

1. **Per-user credential isolation (critical).** Credentials are **static**,
   boot-time, operator-set (`env`/`headers`/`url` in `McpServerConfig`,
   `src/config_types.zig:1472-1510`), **no per-user override, no substitution**
   (`src/mcp/transport.zig:176-178`, `:465-468`). MCP exposed in tenant mode with
   **no gating** (`src/gateway.zig:1990`). Every user → one shared identity.
   *Latent today* (no tenant-sensitive server wired) → time bomb, not live leak.
2. **Scaling.** stdio spawns a child per `McpServer` (`src/mcp/transport.zig:157`)
   eagerly at init (`src/mcp.zig:593`) → **N×M children** on first request.
3. **Staleness.** `TenantRuntime`s are cached (LRU 2048 / idle TTL 1800s,
   `src/gateway.zig:1084-1085`); MCP connects once at init; `PUT /secrets`
   **doesn't** invalidate the runtime (`src/gateway.zig:19875`) while
   `PATCH /settings` does (`:19574`). Connect-time resolution ⇒ **stale token up
   to 30 min** after rotation.
4. **Intra-user fairness (minor).** Mutex held across the full round-trip; no
   per-call timeout, no per-user quota → one slow call head-of-lines the user.

### 1.3 Why native Zig + edge auth (not a sidecar) — see ADR

rev 2 proposed a Node/TS sidecar to "buy" OAuth + full Streamable HTTP from the
official SDK (there is **no official Zig SDK**; `mcp.zig` is single-maintainer
community). The ADR supersedes that: by moving **inbound** auth to the **edge**
(standard OIDC/OAuth proxy / gateway), the sidecar's main justification
evaporates, and native Zig keeps the **single binary + one supply chain** without
putting npm transitive deps in the auth path. The cost map that drove the
decision:

- **Cheap / already native** (keep in Zig): JSON-RPC framing, stdio transport,
  HTTP POST client, the tool registry, tenancy, the vault, the policy plane.
- **Expensive** (the only contested part): inbound **OAuth resource-server**
  crypto → **moved to the edge**; full **Streamable-HTTP server** streaming →
  bounded native work; **outbound OAuth client** → bounded native work, deferred
  until a third-party OAuth upstream is needed.

Reference-client facts that still shape the design (independent of sidecar):
nullalis's HTTP is **POST-only curl** (`src/mcp/transport.zig:447-511`) — no GET
stream, no SSE fallback, no `DELETE`, and `tools/list_changed` is skipped (cached
catalog goes stale); opencode/claude-code get these from the SDK. The ecosystem
is **stdio-dominated** (the `npx @modelcontextprotocol/server-*` long tail), which
is why forbidding stdio on the shared path needs the per-user-pod escape (§6).

### 1.4 Spec-canonical model (MCP 2025-06-18 authorization)

OAuth 2.1 audience-bound tokens (RFC 8707), re-asserted per request; injecting a
user's *third-party* token as the MCP `Authorization` is the **token-passthrough
anti-pattern** (legit only for first-party servers or as transitional debt);
`Mcp-Session-Id` ≠ identity (non-deterministic, bound `<user_id>:<session_id>`,
never used for auth).

### 1.5 End-state goal (this spec's slice) + honest scope

> The end user can connect their agent to **any remote MCP server** —
> operator-provided or user-registered (BYO) — under **their own identity**, **no
> user affecting another**, credentials correct (no passthrough) + fresh (no
> staleness). **Arbitrary stdio** ("the npx long tail") is delivered in layers:
> bundled-in-process now-ish, **per-user pod** as the named endgame (§6).

(The inverse — the agent *being* a server, incl. aggregator/mesh/curated — is
**Spec B**, built on the same core.)

## 2. Goals / non-goals

**Goals**
- MCP **off by default in tenant mode**; explicit operator opt-in; precise
  shared-identity warning.
- Per-tenant **own credential per server, resolved per request** (no staleness),
  via a pluggable provider (static now; native OAuth client later).
- **No arbitrary stdio in a shared process, ever**; remote-only on the shared
  path; stdio long-tail via in-process (blessed) + per-user pod (future).
- **BYO user-registered remote servers** under operator policy + untrusted-server
  safety.
- Build the **unified core** (shared tool registry + single policy plane) that
  Spec B's server face reuses — natively in Zig, single binary.
- Per-call timeout + per-user concurrency quota.

**Non-goals**
- **Single-user mode unchanged** — stdio, static config, current flow keep working
  when `!tenant.enabled`.
- Do **not** relax the per-server mutex / frame-routing; Phase 7 adds timeout+quota
  *around* it.
- Do **not** build the server face (Spec B), nor an inbound OAuth resource-server
  (edge concern per ADR).
- Do **not** implement MCP `sampling` (still deferred).
- **No Node/TS sidecar** (ADR).

## 3. Architecture

### 3.1 The unified core (native Zig) — foundation for both faces

```
┌─ Nullalis Zig core — THE AUTHORITY (single binary) ─────────────────┐
│  • Tenancy/identity      • Encrypted vault (sole secret/token source)│
│  • UNIFIED TOOL REGISTRY: agent tools + skills + client-discovered   │
│    upstream MCP tools — one namespace, provenance + per-entry policy │
│  • SINGLE policy plane: (principal, tool) -> allow/deny + which      │
│    identity to use   ← used by the agent loop AND (Spec B) the server│
│  • Agent loop                                                        │
│                                                                     │
│  CLIENT FACE (this spec): native MCP client over                    │
│    stdio + Streamable HTTP + SSE; per-request credential resolver;   │
│    native outbound OAuth client (bounded, later phase); discovered   │
│    tools flow INTO the registry.                                     │
└─────────────────────────────────────────────────────────────────────┘
        │ JSON-RPC over stdio / Streamable HTTP (native Zig transports)
        ▼
   remote MCP servers (operator-provided + user BYO)  — remote on shared path
```

The registry + policy plane are the linchpin: Spec B's server face exposes a
policy-filtered view of this same registry (aggregator/curated/mesh fall out for
free). No second protocol stack, no sidecar.

### 3.2 Per-request `CredentialResolver`

Every MCP tool call resolves the user's credential **fresh** from the vault and
attaches it to **that** request — never baked at connect. The tool closure runs
in the per-user `TenantRuntime`, so `user_id` is free; per-request = re-read the
vault each call → kills staleness, satisfies "auth on every request", minimizes
per-user state.

```
McpTool.call(args)                         (inside user U's TenantRuntime)
  └─ resolver.resolve(U, server) -> RequestAuth   NEW src/mcp/credential.zig
       ├─ static → credref substitution (vault / operator / user.id)
       └─ oauth  → current per-user token (native OAuth client; vault-persisted)
  └─ McpServer.callTool(args, RequestAuth)   auth threaded per request
```

### 3.3 `credref` — static substitution engine (pure, tested)

`src/mcp/credref.zig`, no I/O. `resolve(allocator, template, ctx)`.

| Form | Resolves to | Class |
|---|---|---|
| `${user.secret:KEY}` | `getSecret(user_id, KEY)` (encrypted `user_secrets`, `src/zaki_state.zig:3351`) | per-user |
| `${user.id}` | requesting user's id (cf. Composio `entity_id`) | per-user (non-secret) |
| `${operator.secret:KEY}` | operator-scoped secret (config map / env) | **shared** |
| `$${` | literal `${` (escape) | — |

**Hard rules:** **fail closed** (missing `${user.secret}` ⇒ `error.MissingCredential`
→ server absent for that user only, never a blank credential); **no silent
passthrough** (unknown `${…}` ⇒ error); **no `${env:VAR}`** (audit-opaque; operator
env flows through `${operator.secret}`, statically detectable as shared).

### 3.4 Server trust + auth classification

New `McpServerConfig` fields:

```
trust: enum { first_party, third_party } = .third_party,  // safe default
auth:  enum { none, static, oauth }      = .static,
allow_shared_identity: bool = false,
```

- **per-user** iff every credential value uses only `${user.*}` (or `auth=oauth`)
  → no ack.
- **shared-identity** if any value is literal-nonempty or `${operator.secret:…}`
  → requires `allow_shared_identity=true` in tenant mode, else refused+warned.
- **token-passthrough guard:** `third_party` + a `${user.secret}` in an
  `Authorization`-class header ⇒ WARN (transitional; prefer `auth=oauth`).
- **Status enum** (stolen from opencode): `connected | disabled | failed{err} |
  needs_auth | needs_client_registration{err}` — surfaced actionably.

### 3.5 Discovery / invocation split + per-user session

Catalog (names/schemas) is user-independent → discovered **once per server**
(shared in the registry), refreshed when the native client receives
`tools/list_changed` (new: the frame router must surface it, not just skip it).
**Invocation** attaches the per-user credential **per request**. Per-user state =
a tiny **session handle** bound `<user_id>:<session_id>`, never shared across
users. **Credential re-binding to server-URL** (opencode `auth.ts:69`) defeats
confused-deputy: stored tokens refused if the configured URL changed.

### 3.6 Gating + shared-path remote-only

At `initMcpTools` (`src/gateway.zig:1990`) thread the tenant flag
(`state.tenant_enabled`, `:1081`):
- **single-user** (`!tenant_enabled`): unchanged — stdio included.
- **tenant + `mcp_enabled=false`** (new `tenant.mcp_enabled`, default false): skip
  MCP; log once.
- **tenant + `mcp_enabled=true`**: classify per server; **stdio refused on the
  shared path** (→ in-process or per-user pod, §6); shared-identity-without-ack
  refused+warned. MCP stays **additive-safe** (`src/gateway.zig:1991`).

### 3.7 BYO — user-registered outbound servers (remote only on shared path)

- **Storage:** per-user registry in Postgres (the `user_config` pattern,
  `src/zaki_state.zig:2801`), visible only to that user; merged with operator
  servers (collision → operator wins, user server logged shadowed).
- **Operator policy** `tenant.mcp_byo`: `disabled` (default) / `allowlist` / `open`.
- **Remote-only on shared path** — a user can never register a shared-infra stdio
  server; arbitrary stdio is per-user-pod only (§6 / Phase 8).
- **Untrusted-server safety:** user servers are `third_party` by construction.
  SSRF/egress validation at registration + per request (HTTPS-only; block
  private/link-local/metadata; optional operator egress allowlist).
  Tool descriptions/results are **untrusted** — surfaced with provenance, no
  autonomy elevation, counted under existing approval gates. Credentials are the
  user's own (`${user.secret}` or native OAuth).

## 4. "Connect to any MCP" — capability matrix (honest)

| Server kind | Single-user mode | Tenant mode (this spec) |
|---|---|---|
| Remote HTTP/SSE, operator | ✅ today | ✅ Phase 1–4 (per-user creds; native transport + OAuth) |
| Remote HTTP/SSE, user BYO | n/a | ✅ Phase 6 |
| stdio, operator-blessed/bundled | ✅ today | ✅ Phase 5 (in-process, no child proc) |
| **stdio, arbitrary user `npx`** | ✅ today | ⛔ shared path; ✅ **Phase 8 (per-user pod)** |

**Bottom line:** after Phases 1–6, a SaaS tenant connects to **any remote MCP** +
**blessed local** servers under their own identity. **Literally any MCP (incl.
arbitrary stdio)** = Phase 8 (per-user pod), tied to the K8s workstream.

## 5. Phases (sequenced; Phase 1 ships first)

| # | Phase | Dep | Value |
|---|---|---|---|
| 1 | **Gating + shared-path remote-only** | — | Closes latent shared-identity risk *today* |
| 2 | **Native Streamable HTTP/SSE client completion** | — | GET stream + `DELETE` + SSE fallback + `list_changed`; replaces POST-only curl |
| 3 | **Per-request resolver + `credref` + trust class + registry** | 1 | Per-user identity; staleness fixed; shared tool registry (Spec B foundation) |
| 4 | **Native outbound OAuth client (vault-backed tokens)** | 2,3 | Per-user OAuth to upstream; kills passthrough |
| 5 | **In-process blessed local servers** | 2 | Common stdio-like servers, no child process |
| 6 | **BYO user-registered remote servers** | 3,4 | "Connect to any remote MCP" |
| 7 | **Per-call timeout + per-user quota** | — | Intra-user fairness |
| 8 | **Per-user pod stdio execution (K8s)** *(named endgame)* | 2; K8s workstream | Literally *any* MCP incl. arbitrary `npx` |

Phase 1 is the cheap safeguard — land before any tenant-sensitive server. Phases
1, 3, 5, 7 are pure-Zig and independently shippable; 2/4 complete native
transport/OAuth; 8 reuses the K8s harness.

### Per-phase specifics
- **P1:** `tenant.mcp_enabled:bool=false`; thread flag into `initMcpTools`; three
  branches (§3.6); refuse stdio on shared path; shared-identity WARN.
- **P2:** complete the native Zig Streamable HTTP client (GET event-stream, SSE,
  session `DELETE`) and surface `tools/list_changed` in the frame router; keep
  stdio + POST as-is. (`mcp.zig` reference only.)
- **P3:** `credref.zig` (pure) + `credential.zig` resolver + `static` provider;
  new `McpServerConfig` fields; per-call `RequestAuth`; fail-closed; passthrough
  WARN; the **unified tool registry** + status enum.
- **P4:** native outbound OAuth client — **evolve the existing `src/auth.zig`**
  (PKCE/RFC 7636 + device flow/RFC 8628 + credential store already implemented;
  add discovery/refresh/RFC 8707 + per-server token scoping). Per-user browser
  consent (localhost callback); tokens persisted to the vault (replace `auth.zig`'s
  single-user `~/.nullalis/auth.json` with the per-user encrypted vault); cred
  re-binding to server-URL; SSRF defenses on discovery fetches.
- **P5:** in-process transport for a curated bundled-server set (claude-code
  `client.ts:909-943` pattern); not exposed to `tenant.mcp_byo`.
- **P6:** per-user registry storage + merge; `tenant.mcp_byo` policy; registration
  validation (remote-only, SSRF); untrusted provenance + autonomy handling.
- **P7:** hard per-invocation wall-clock budget; per-user concurrent-call quota →
  fast "MCP busy"; transport-tiered concurrency; mutex/frame-routing untouched;
  `zig build test-mcp-live` must still pass.
- **P8 (endgame):** user's stdio server in that user's pod/microVM (agent-browser
  K8s harness, `nullalis-abk8s`), bridged over native HTTP; process-tree reaping;
  per-pod egress controls. Own brainstorm before build.

## 6. stdio strategy (the safety law)

**Arbitrary user stdio = arbitrary code execution ⇒ per-user isolation or
nothing.** Layers: (1) shared path remote-only; (2) in-process *blessed* (only
code we ship; no child process); (3) per-user pod for arbitrary user stdio. Never
a shared pod (claude-code `routes/mcp.ts:130-139` — `execSync` with full
`process.env` — is the anti-example).

## 7. Security posture (explicit)

- **Token passthrough:** documented; enforced via trust-class WARN; native OAuth
  (P4) is the correct path.
- **Fail closed:** missing per-user credential ⇒ server absent for that user only.
- **Edge inbound auth (ADR):** any *inbound* auth (Spec B) is validated at the
  edge; this client spec never accepts inbound tokens. Outbound creds always come
  from the vault, never from a caller.
- **Single policy plane:** one `(principal, tool)` decision used by the agent loop
  now and the server face later — no dual auth, defeats confused-deputy by
  construction.
- **Session ≠ identity:** non-deterministic, per-user bound, never auth.
- **Confused-deputy:** credential re-binding to server-URL; per-client consent;
  exact `redirect_uri`; single-use `state`.
- **SSRF/egress:** OAuth discovery (P4) + BYO registration/per-request (P6) +
  per-pod (P8) — HTTPS-only, block private/link-local/metadata.
- **Untrusted MCP output:** provenance, no autonomy elevation, existing approval
  gates.
- **No principal collapse:** reject any mode flattening users to one identity
  (claude-code `auth.ts:50-66` anti-example).
- **Secret hygiene:** secrets in memory only at call time; logs carry key *names*
  + server names, never values; no npm deps in the auth path (native Zig).

## 8. Testing strategy

- **`credref` unit tests** (pure): forms, `$${` escape, fail-closed,
  unknown-token, mixed, per-user vs shared classification.
- **Resolver tests:** static + oauth against mocked vault/token store; refresh;
  expiry; `MissingCredential`.
- **Native transport tests:** Streamable HTTP GET stream + SSE + `DELETE`;
  `tools/list_changed` updates the registry.
- **Gating matrix:** single-user passthrough; tenant disabled; per-user; third
  `+static` warns; shared without ack refused; with ack allowed+warned; **stdio
  refused on shared path**.
- **Per-request freshness:** rotate secret mid-runtime → next call uses new token
  (targets the `:19875` gap).
- **OAuth tests:** 401→discovery→token; audience binding; CSRF state double-check;
  SSRF rejection of private-range discovery URLs; cred re-binding on URL change.
- **BYO tests:** registration rejects stdio + private-range URL; policy
  disabled/allowlist/open; operator name shadows user server.
- **Concurrency:** timeout → tool-error; quota → fast busy; **`NULLALIS_MCP_LIVE_TEST=1
  zig build test-mcp-live` passes unchanged**.
- **Cross-tenant isolation:** user A's missing/invalid cred never affects user B;
  two tenants with the **same server name** never clobber (opencode `index.ts:119`
  anti-test).

## 9. Documentation

`docs/mcp-client.md` gains a **"Multi-tenant mode"** section: gating; the unified
core + edge-auth architecture (link the ADR); the capability matrix (§4);
credential-ref table + fail-closed; trust classes + `auth` modes + native OAuth +
passthrough warning; BYO (registration, `mcp_byo` policy, remote-only/SSRF); stdio
strategy (§6). **Correct the misleading `Bearer ${TOKEN}` example** (lines 33-36 —
*not* substituted today) to real `${user.secret:…}` / OAuth forms.

## 10. Confidence & open questions

**Confidence:** Phases 1, 3, 5, 7 (pure-Zig): **high** — validated by code truth +
both refs. Phase 2 (native Streamable HTTP server-stream/SSE): **medium** — real
new work, but bounded and `mcp.zig` proves feasibility. Phase 4 (native outbound
OAuth client): **medium** — security-critical but the *client* half only, and
deferrable. Phase 6 (BYO remote): **high**. Phase 8 (per-user pod): **medium** —
depends on K8s workstream; own brainstorm.

**Open:**
- The nullalis-internal client/registry API shape — settle in P3.
- Tool-count/context bloat with many BYO servers (neither ref mitigates) — may
  need lazy/relevance-gated tool exposure.
- Scope-gated OAuth catalogs → per-(user,server) catalog cache w/ TTL if common.
- **Spec B** reuses this core (registry + policy plane + native transports) for
  the server face.

## 11. Code-truth & reference index

| Claim | Evidence |
|---|---|
| MCP init per `TenantRuntime`, no gating | `src/gateway.zig:1990` |
| Per-user `McpServer`, per-server mutex | `src/mcp.zig:109`, `:582-685` |
| Static creds, no substitution | `src/config_types.zig:1472-1510`, `src/mcp/transport.zig:176-178,465-468` |
| HTTP = POST-only curl, no GET/DELETE/SSE | `src/mcp/transport.zig:447-511` |
| stdio child per server, eager spawn | `src/mcp/transport.zig:157`, `src/mcp.zig:593` |
| TenantRuntime cached LRU+TTL | `src/gateway.zig:1084-1085`, `:2609-2654` |
| Secret PUT doesn't invalidate runtime | `src/gateway.zig:19875` vs `:19574` |
| Tool concurrency real | `src/agent/root.zig:2969` |
| Encrypted per-user vault | `src/zaki_state.zig:3351` |
| Tenant mode flag | `src/gateway.zig:1081`, `:5424` |

**Reference repos:** opencode `packages/opencode/src/mcp/*` (all-3 transports,
`list_changed` `index.ts:476-484`, cred re-binding `auth.ts:69`, cross-tenant
pitfall `index.ts:119`); claude-code `src/services/mcp/client.ts:909-943`
(in-process transport), `routes/mcp.ts:130-139` (stdio-in-shared-pod RCE
anti-example). **No official Zig SDK** (<https://modelcontextprotocol.io/docs/sdk>);
`mcp.zig` reference only. Architecture: see ADR
`2026-06-06-adr-nullalis-mcp-hub-architecture.md`.

## 12. S-tier hardening & reference-agent reuse (rev 4)

A pressure test against best-practice gateways (IBM ContextForge, Cloudflare MCP
Portals, Solo.io Virtual MCP) and reference agents (**hermes**, **openclaw**)
graded the architecture: **4 of 6 core choices VALIDATED, edge-auth VALIDATED with
conditions, native-no-SDK DEFENSIBLE** (and de-risked because the native server +
PKCE already exist). To make the *spec* (not just the architecture) S-tier, the
client face adds:

### 12.1 Hardening (client-face items; see ADR pillars 7–11)
- **Tool-poisoning / rug-pull defense** (new phase, alongside P3/P6): on discovery,
  **fingerprint each server + pin tool definitions + detect changes**; treat tool
  descriptions/results as untrusted; **scan descriptions for injection** and run an
  **OSV/malware check before any (per-pod, P8) stdio spawn**. Over 30% of surveyed
  MCP servers had exploitable vulns — this is not optional for BYO.
- **OpenTelemetry GenAI tracing** (cross-cutting): emit a span per MCP tool call,
  nested in the model-call trace (latency/error/throughput). Table stakes 2026.
- **Conformance harness** (cross-cutting, justifies no-SDK): pin + negotiate
  protocol versions; test Streamable-HTTP resumability (`Last-Event-Id`) + session
  teardown against the official MCP inspector.
- **Dynamic, permission-scoped tool filtering**: the registry returns only the
  caller-allowed tool slice — fixes context bloat (the open question in §10) *and*
  is a security control. Mitigates the many-BYO-servers tool-count problem.
- **Edge-trust invariant** (client relevance): the outbound resolver **never
  forwards an inbound token** upstream — always mints a separate per-user upstream
  credential from the vault (confused-deputy defense; already core to §3.2).

### 12.2 Concrete reuse (verified, lifts cleanly)
- **From hermes** (`.codex-tmp/hermes-agent/tools/mcp_tool.py`, `mcp_oauth.py`):
  MCP tool-description **injection scanning** (`_scan_mcp_description`), **OSV
  pre-spawn malware check**, **credential redaction in errors** (`_sanitize_error`),
  stdio **env-var allowlisting**, governed **sampling** (rate/model/loop caps),
  and a mature PKCE OAuth client → feeds 12.1 + P4.
- **From openclaw** (`src/agents/pi-bundle-mcp-*.ts`): **config-fingerprint catalog
  cache + in-flight dedup**, **per-upstream failure isolation** during catalog
  build (one bad server never kills the catalog), **tool-name namespacing +
  collision-suffixing + provider-safe sanitization + stable sort**, and the
  `SessionMcpRuntimeManager` lifecycle discipline (study before building P8 pods).
  Note openclaw's gaps to *avoid*: no `list_changed` handling (we do both
  fingerprint-cache **and** honor upstream `list_changed`, §3.5); no outbound MCP
  OAuth (P4 is our differentiator); module-global cross-tenant state.

### 12.3 Prior-art reconciliation (verified in the working repo)
- The native MCP **server** already exists (`src/mcp_server.zig`,
  `src/mcp/server_{auth,handlers,policy,protocol}.zig`) — Spec B **extends** it, not
  greenfield. Its **deny-by-default exposure policy** (`server_policy.zig`: 7 safe
  + 4 memory tools, `NULLALIS_MCP_EXPOSE_ALL`) is the proven base for curated
  export + scoped filtering.
- **OAuth/PKCE/device flow + store** exist (`src/auth.zig`) → P4 evolves them
  (per-server scoping + per-user vault), not from scratch.

### 12.4 A2A note (client side)
A2A is promoted to a first-class peer protocol (ADR rev 2); the **server** side
(Agent Cards + Task lifecycle + federation) is **Spec B**. The **client** face may
*consume* A2A agents as delegation targets — this spec reserves the resolver +
registry seams for that; the mesh loop guards (`max_hops`/`max_depth` + cycle
detection) live with the A2A surface in Spec B.

### 12.5 Updated confidence
Architecture: **high** (consensus-validated + half already built). Spec-as-S-tier:
**medium-high** once 12.1 lands — the additions are hardening, not redesign. Phase 2
(Streamable-HTTP server-stream + conformance) and the A2A surface (Spec B) remain
the largest net-new work.
