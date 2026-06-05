---
tags: [prose, prose/specs]
status: draft
date: 2026-06-06
---

# Design: Multi-tenant hardening of the nullalis MCP client (+ BYO outbound servers)

**Author:** brainstorming session (Mohammad + Claude)
**Date:** 2026-06-06
**Status:** Draft (rev 2 — incorporates reference-repo recon: opencode + claude-code). Pending user review, then `writing-plans`.

> **Sibling spec.** This is **Spec A** of a two-spec set. Spec A builds the
> per-user credential / trust / OAuth **foundation** for nullalis as an MCP
> **client** (outbound), including user-registered "bring-your-own" (BYO)
> servers. **Spec B** — *agent-as-MCP-server* (inbound surface) — *consumes*
> this foundation and is specced separately
> (`2026-06-06-agent-as-mcp-server-design.md`). The end state is a **symmetric
> MCP node**: every tenant both consumes MCP servers and (if allowed) is one.

> **Scope boundary.** Separate workstream from the `agent-browser` K8s backend
> (`2026-06-05-agent-browser-default-backend-design.md`) — that uses native
> tools, not MCP. But the **sidecar** and **per-user pod** patterns are
> deliberately shared with it (see §3.1, §6.3).

---

## 1. Context & problem

nullalis is a self-hosted Zig AI-agent gateway that runs **multi-tenant**: one
process serves many users, each with an isolated `TenantRuntime`
(`src/gateway.zig`). It is also an **MCP client** (`src/mcp.zig`,
`src/mcp/transport.zig`, `docs/mcp-client.md`). A code recon (verified against
source) plus a recon of two mature reference clients (opencode, claude-code)
found the MCP client is **single-tenant in disguise**: correct for one user,
latently unsafe the moment a tenant-sensitive server is wired.

### 1.1 Already correct — do not "fix"

- **`McpServer` instances are per-user** (`src/gateway.zig:1990`); the per-server
  mutex (`src/mcp.zig:109`) only serializes *within* a user. Not a cross-tenant
  bug; research confirms per-user instance/session is the canonical isolation
  primitive.
- **Tool concurrency is real but tenant-safe** — a thread per tool call
  (`src/agent/root.zig:2969`, default-on), but threads share *that user's*
  `McpServer`/mutex; concurrency never crosses tenants.

### 1.2 The real gaps (verified against source)

1. **Per-user credential isolation (critical).** Credentials are **static**,
   boot-time, operator-set — `env`/`headers`/`url` in `McpServerConfig`
   (`src/config_types.zig:1472-1510`), **no per-user override, no substitution**
   (`src/mcp/transport.zig:176-178`, `:465-468`). MCP exposed in tenant mode with
   **no gating** (`src/gateway.zig:1990`). Every user → one shared identity.
   *Latent today* (no tenant-sensitive server wired) → a time bomb, not a live
   leak.
2. **Scaling.** stdio spawns a child per `McpServer` (`src/mcp/transport.zig:157`)
   eagerly at init (`src/mcp.zig:593`); per-user × per-server = **N×M children**
   on first request.
3. **Staleness.** `TenantRuntime`s are cached (LRU 2048 / idle TTL 1800s,
   `src/gateway.zig:1084-1085`); MCP connects once at init; `PUT /secrets`
   **does not** invalidate the runtime (`src/gateway.zig:19875`) while
   `PATCH /settings` **does** (`src/gateway.zig:19574`). Connect-time credential
   resolution ⇒ **stale token up to 30 min** after rotation.
4. **Intra-user fairness (minor).** Mutex held across the full round-trip; no
   per-call timeout, no per-user quota → one slow call head-of-lines the user.

### 1.3 Reference-repo recon — what mature clients prove (and what bites us)

We read opencode (`packages/opencode/src/mcp/*`) and claude-code
(`src/services/mcp/*`, `mcp-server/*`, `src/server/*`, `helm/*`):

- **OAuth is "buy, not build" — but only if you have an SDK.** Both delegate the
  *entire* OAuth state machine (RFC 9728/8414/7591/PKCE/8707/refresh) to
  `@modelcontextprotocol/sdk`; opencode writes only ~700 LOC of glue (provider
  adapter + localhost callback + token storage; `oauth-provider.ts`,
  `oauth-callback.ts`, `auth.ts`). **nullalis is Zig — no official SDK exists.**
  Hand-rolling those RFCs in Zig is 2–4× the cost and security-critical. ⇒ we
  introduce a **Node/TS MCP sidecar** that owns the SDK (§3.1).
- **nullalis's HTTP transport is partial.** It is **POST-only curl**
  (`src/mcp/transport.zig:447-511`): no GET server→client stream, no SSE
  fallback for older servers, no `DELETE` teardown, and `tools/list_changed` is
  *skipped* by the frame router — so a cached catalog silently goes stale.
  opencode gets full Streamable HTTP + SSE fallback + `list_changed` re-list free
  from the SDK (`index.ts:476-484`). ⇒ the sidecar also fixes this transport gap.
- **The MCP ecosystem is stdio-dominated.** The plug-and-play "any MCP server"
  case is `npx @modelcontextprotocol/server-*` (filesystem, github, …). opencode
  invests in recursive `pgrep -P` subprocess reaping because stdio servers fork
  grandchildren (`index.ts:533-540`). **Forbidding stdio in tenant mode (correct
  for safety) means SaaS tenants lose this long tail** unless we add a per-user
  execution layer (§6).
- **The ban is validated by claude-code's failure.** Its hosted server runs
  user stdio MCP in a **shared pod under a shared UID with full `process.env`**,
  and a `/test` route does `execSync(\`${command} ${args}\`, {env:{...process.env}})`
  — shell-injection RCE that **bypasses** its own command-sandbox and leaks
  `ANTHROPIC_API_KEY` (`src/server/api/routes/mcp.ts:130-139`,
  `security/command-sandbox.ts`). This is exactly what "no gating / shared
  process" buys.
- **Patterns to steal** (verified): credential **re-binding to server-URL** to
  defeat confused-deputy (opencode `auth.ts:69`); **double-layer CSRF state**;
  the **in-process transport** for blessed local servers — no child process
  (claude-code `client.ts:909-943`); transport-tiered concurrency; an actionable
  **status enum** (`needs_auth` / `needs_client_registration` / `failed` /
  `disabled`); and a **shared/sticky session store** (both refs' in-process
  session maps break under K8s multi-replica — directly relevant to nullalis).
- **Anti-patterns to avoid** (verified): opencode's module-global
  `pendingOAuthTransports` keyed by server *name* (`index.ts:119`) → cross-tenant
  clobber if two tenants share a name; tokens at rest in **plaintext** JSON
  (`auth.ts:80`); full `process.env` inherited into stdio children
  (`index.ts:399`); a token-auth mode that **collapses every user to one admin
  principal** (claude-code `api/middleware/auth.ts:50-66`).

### 1.4 Spec-canonical model (from the MCP 2025-06-18 authorization spec)

- **OAuth 2.1 is the intended multi-tenant mechanism**, not static injected
  tokens; access tokens are **audience-bound to the MCP server URI** (RFC 8707),
  re-asserted **every** request.
- **Injecting a user's *third-party* token (their GitHub PAT) as the MCP
  `Authorization`** is the named **token-passthrough anti-pattern** — legitimate
  only for **first-party** servers you control, or as explicit transitional debt.
- **`Mcp-Session-Id` ≠ identity** — non-deterministic, bound `<user_id>:<session_id>`,
  never used for auth.

### 1.5 End-state goal (this spec's slice) + honest scope

> The end user can connect their agent to **any *remote* MCP server** —
> operator-provided **or** user-registered (BYO) — acting under **that user's own
> identity**, **no user affecting another**, with credentials that are correct
> (no passthrough), fresh (no staleness), and OAuth-ready. **Arbitrary stdio
> servers** ("the npx long tail") are delivered in layers: bundled-in-process
> now-ish, **per-user pod** as the named endgame (§6).

(The inverse — the agent *being* an MCP server — is **Spec B**.)

## 2. Goals / non-goals

**Goals**
- MCP **off by default in tenant mode**; explicit operator opt-in; precise
  shared-identity warning.
- Per-tenant **own credential per server, resolved per request** (no staleness),
  via a pluggable provider (static **or** delegated OAuth 2.1).
- **No arbitrary stdio in a shared process, ever**; HTTP/remote-only in the
  shared path; stdio long-tail via in-process (blessed) + per-user pod (future).
- **BYO user-registered remote servers** under operator policy + untrusted-server
  safety.
- A **stateless Node/TS MCP sidecar** owns the MCP protocol (OAuth, full
  Streamable HTTP/SSE, `list_changed`); **nullalis owns identity + the vault +
  tenant routing**.
- Per-call timeout + per-user concurrency quota.
- Foundation reusable by **Spec B** without rework.

**Non-goals**
- **Single-user mode unchanged** — stdio, static config, current flow all keep
  working when `!tenant.enabled` (the native Zig client path stays for it).
- Do **not** relax the per-server mutex / frame-routing (the verified stability
  fix); Phase 7 adds timeout+quota *around* it.
- Do **not** build the agent-as-MCP-server surface (Spec B).
- Do **not** implement MCP `sampling` (still deferred).

## 3. Architecture

### 3.1 Topology — nullalis (Zig) ⇄ MCP sidecar (Node/TS, official SDK)

```
nullalis agent (Zig)  — per-user TenantRuntime
  ├─ owns: tenant identity, encrypted vault (token store), credential
  │        resolution, gating/trust/policy, tool catalog → agent, approval gates
  │   JSON-RPC / HTTP over a local interface  (per call: user, server, RequestAuth)
  ▼
MCP sidecar  (Node/TS, @modelcontextprotocol/sdk)   NEW — shared, STATELESS re: secrets
  ├─ owns: MCP protocol — Streamable HTTP (+GET stream/+DELETE), SSE fallback,
  │        OAuth 2.1 state machine (discovery/DCR/PKCE/refresh/RFC8707),
  │        tools/list_changed, session lifecycle
  ├─ holds NO cross-user secret state; receives the per-user credential per
  │  request; hands refreshed OAuth tokens BACK to nullalis to persist in vault
  └─ keys all transient state by (user_id, server)
        │ outbound JSON-RPC
        ▼
   remote MCP servers (operator-provided + user BYO)   HTTP/SSE only on this path
```

**Why a sidecar (decision):** it buys the OAuth RFCs and full Streamable
HTTP/SSE from the official SDK (the ~700-LOC-glue reality both refs prove),
instead of hand-rolling security-critical protocol in Zig. It reuses the exact
**Node/TS sidecar pattern** the agent-browser spec established.

**Why the sidecar is stateless about secrets (decision):** the single worst bug
in both refs is cross-tenant secret/session state in process-global maps. By
keeping nullalis's encrypted vault (`src/zaki_state.zig:3351`) the **sole**
source of truth and passing the per-user credential per request — sidecar
returning refreshed tokens to nullalis to store — we never create a second
multi-tenant secret store. The sidecar can be killed/restarted freely.

### 3.2 The central abstraction: a per-request `CredentialResolver` (nullalis side)

Every MCP tool call resolves the requesting user's credential **fresh** from the
vault / token store and passes it to the sidecar for **that** request — never
baked at connect. The MCP tool closure already runs in the per-user
`TenantRuntime`, so `user_id` is free; "per-request" = re-read the vault each
call → kills staleness, satisfies "auth on every request", minimizes per-user
state.

```
McpTool.call(args)                         (inside user U's TenantRuntime)
  └─ resolver.resolve(U, server) -> RequestAuth   NEW src/mcp/credential.zig
       ├─ static → credref substitution (vault / operator / user.id)
       └─ oauth  → current per-user token (sidecar refreshes; nullalis persists)
  └─ sidecar.callTool(user=U, server=S, auth=RequestAuth, name, args)
```

### 3.3 `credref` — the static substitution engine (pure, tested)

`src/mcp/credref.zig`, no I/O. `resolve(allocator, template, ctx)`.

| Form | Resolves to | Class |
|---|---|---|
| `${user.secret:KEY}` | `getSecret(user_id, KEY)` (encrypted `user_secrets`) | per-user |
| `${user.id}` | requesting user's id (cf. Composio `entity_id`) | per-user (non-secret) |
| `${operator.secret:KEY}` | operator-scoped secret (config map / env) | **shared** |
| `$${` | literal `${` (escape) | — |

**Hard rules:** **fail closed** (missing `${user.secret}` ⇒ `error.MissingCredential`
→ server absent for that user only, never a blank credential); **no silent
passthrough** (unknown `${…}` ⇒ error); **no `${env:VAR}` form** (raw env is
audit-opaque; operator env flows through `${operator.secret}`, statically
detectable as shared).

### 3.4 Server trust + auth classification

New `McpServerConfig` fields:

```
trust: enum { first_party, third_party } = .third_party,  // safe default
auth:  enum { none, static, oauth }      = .static,
allow_shared_identity: bool = false,
```

- **per-user** iff every credential value uses only `${user.*}` (or `auth=oauth`)
  → no ack needed.
- **shared-identity** if any value is literal-nonempty or `${operator.secret:…}`
  → requires `allow_shared_identity=true` in tenant mode, else refused+warned.
- **token-passthrough guard:** `third_party` **and** a `${user.secret}` in an
  `Authorization`-class header ⇒ WARN (transitional debt; prefer `auth=oauth`).
  `first_party + static` allowed silently.
- **Status surfaced to operator/user** with an actionable enum (stolen from
  opencode): `connected | disabled | failed{err} | needs_auth |
  needs_client_registration{err}`.

### 3.5 Discovery / invocation split + per-user session

Tool **catalog** (names/schemas) is user-independent → discovered **once per
server** (shared), refreshed on the sidecar's `tools/list_changed`. **Invocation**
attaches the per-user credential **per request**. Per-user state = a tiny
**session handle** bound `<user_id>:<session_id>`, never shared across users.
(Scope-gated OAuth catalogs fall back to per-user discovery, cached per user.)
Credential **re-binding to server-URL** (opencode `auth.ts:69`) defeats
confused-deputy: stored tokens are refused if the configured URL changed.

### 3.6 Gating + HTTP-only (shared path)

At `initMcpTools` (`src/gateway.zig:1990`) thread the tenant flag
(`state.tenant_enabled`, `:1081`):
- **single-user** (`!tenant_enabled`): unchanged — native Zig client, stdio
  included.
- **tenant + `mcp_enabled=false`** (new `tenant.mcp_enabled`, default false): skip
  MCP; log once.
- **tenant + `mcp_enabled=true`**: classify per server; **stdio refused on the
  shared path** with a clear error (→ in-process or per-user pod, §6);
  shared-identity-without-ack refused+warned. MCP stays **additive-safe** (any
  refusal leaves the agent on builtin tools, today's behavior at
  `src/gateway.zig:1991`).

### 3.7 BYO — user-registered outbound servers (remote only on shared path)

- **Storage:** per-user MCP registry in Postgres (the `user_config` pattern,
  `src/zaki_state.zig:2801`), visible only to that user; merged with operator
  servers (name collision → operator wins, user server logged shadowed).
- **Operator policy** `tenant.mcp_byo`: `disabled` (default) / `allowlist`
  (host/domain) / `open`.
- **Remote-only on the shared path.** A user can never register a stdio server
  that runs in shared infra; arbitrary stdio is only ever per-user-pod (§6.3).
- **Untrusted-server safety:** user servers are `third_party` by construction.
  SSRF/egress validation at registration + per request (HTTPS-only, block
  private/link-local/metadata; optional operator egress allowlist).
  Server-supplied tool **descriptions/results are untrusted** — surfaced with
  provenance, no autonomy elevation, counted under existing approval gates.
  Credentials are the user's own (`${user.secret}` or OAuth).

## 4. "Connect to any MCP" — capability matrix (honest)

| Server kind | Single-user mode | Tenant mode (this spec) |
|---|---|---|
| Remote HTTP/SSE, operator | ✅ today | ✅ Phase 1–4 (sidecar, per-user creds/OAuth) |
| Remote HTTP/SSE, user BYO | n/a | ✅ Phase 6 |
| stdio, operator-blessed/bundled | ✅ today | ✅ Phase 5 (in-process, no child proc) |
| **stdio, arbitrary user `npx`** | ✅ today | ⛔ shared path; ✅ **Phase 8 (per-user pod)** |

**Bottom line:** after Phases 1–6, a SaaS tenant can connect to **any remote
MCP** and **blessed local** servers under their own identity. **Literally any
MCP (incl. arbitrary stdio)** requires Phase 8 (per-user pod), the named endgame
tied to the K8s workstream.

## 5. Phases (sequenced; Phase 1 ships first)

| # | Phase | Dep | Value |
|---|---|---|---|
| 1 | **Gating + shared-path HTTP-only** | — | Closes latent shared-identity risk *today* |
| 2 | **MCP sidecar (Node/TS, SDK) for remote transports** | 1 | Full Streamable HTTP/SSE + `list_changed`; replaces POST-only curl on the tenant path |
| 3 | **Per-request resolver + `credref` + trust class** | 2 | Per-user identity; staleness fixed |
| 4 | **Delegated OAuth 2.1 (sidecar SDK; vault-backed tokens)** | 2,3 | Spec-canonical per-user auth; kills passthrough |
| 5 | **In-process blessed local servers** | 2 | Common stdio-like servers, no child process |
| 6 | **BYO user-registered remote servers** | 3,4 | "Connect to any remote MCP" |
| 7 | **Per-call timeout + per-user quota** | — | Intra-user fairness |
| 8 | **Per-user pod stdio execution (K8s)** *(named endgame)* | 2; K8s workstream | Literally *any* MCP incl. arbitrary `npx` |

Notes: Phase 1 is the cheap safeguard — land before any tenant-sensitive
server. Phases 1, 3, 7 are pure-Zig and independently shippable; 2/4/5/8 involve
the sidecar. Single-user mode keeps the native Zig client throughout (no sidecar
dependency for solo users).

### Per-phase specifics
- **P1:** `tenant.mcp_enabled:bool=false`; thread flag into `initMcpTools`;
  three branches (§3.6); refuse stdio on shared path; shared-identity WARN.
- **P2:** sidecar service + local nullalis↔sidecar interface; route tenant-mode
  remote MCP through it; sidecar holds no secrets (§3.1); health/restart-safe.
- **P3:** `credref.zig` (pure) + `credential.zig` resolver + `static` provider;
  new `McpServerConfig` fields; per-call `RequestAuth` to sidecar; fail-closed;
  passthrough WARN; status enum.
- **P4:** OAuth via sidecar SDK (discovery/DCR/PKCE/refresh/RFC8707); per-user
  **browser consent** (localhost callback in sidecar, state CSRF double-checked);
  refreshed tokens persisted to nullalis vault; SSRF defenses on discovery
  fetches; cred re-binding to server-URL.
- **P5:** in-process transport for a curated bundled-server set (claude-code
  `client.ts:909-943` pattern); no `tenant.mcp_byo` exposure.
- **P6:** per-user registry storage + merge; `tenant.mcp_byo` policy; registration
  validation (remote-only, SSRF); untrusted provenance + autonomy handling.
- **P7:** hard per-invocation wall-clock budget (promote `read_line_timeout_secs`
  / curl `--max-time`); per-user concurrent-call quota → fast "MCP busy";
  transport-tiered concurrency (throttle heavier paths); mutex/frame-routing
  untouched; `zig build test-mcp-live` must still pass.
- **P8 (endgame):** run a user's stdio server in that user's pod/microVM
  (agent-browser K8s harness, `nullalis-abk8s`), bridged via the sidecar;
  process-tree reaping; per-pod egress controls. Own brainstorm before build.

## 6. stdio strategy (the safety law)

**Arbitrary user stdio = arbitrary code execution ⇒ per-user isolation or
nothing.** Layers:
1. **Shared path: remote-only.** No per-user OS process; sidecar holds no
   secrets. Safe by construction.
2. **In-process blessed (P5):** only code nullalis ships; no child process; no
   user-supplied commands.
3. **Per-user pod (P8):** the *only* place arbitrary user stdio runs, isolated in
   the user's own pod (reuses K8s). Never a shared pod (claude-code's
   `routes/mcp.ts:130-139` is the anti-example).

## 7. Security posture (explicit)

- **Token passthrough:** documented; enforced via trust-class WARN; OAuth (P4) is
  the correct path.
- **Fail closed:** missing per-user credential ⇒ server absent for that user
  only; never an empty token.
- **Sidecar statelessness:** vault is the sole secret store; sidecar keyed by
  `(user,server)`, restart-safe — avoids both refs' process-global cross-tenant
  leak.
- **Session ≠ identity:** non-deterministic, per-user bound, never auth.
- **Confused-deputy:** credential re-binding to server-URL; per-client consent;
  exact `redirect_uri`; single-use `state`.
- **SSRF/egress:** on OAuth discovery (P4) and BYO registration + per request
  (P6) and per-pod (P8) — HTTPS-only, block private/link-local/metadata.
- **Untrusted MCP output:** provenance, no autonomy elevation, existing approval
  gates.
- **No principal collapse:** reject any auth mode that flattens users to one
  identity (claude-code `auth.ts:50-66` anti-example).
- **Secret hygiene:** secrets in memory only at call time; logs carry key *names*
  + server names, never values.

## 8. Testing strategy

- **`credref` unit tests** (pure): forms, `$${` escape, fail-closed,
  unknown-token, mixed, per-user vs shared classification.
- **Resolver tests:** static + oauth against mocked vault/token store; refresh;
  expiry; `MissingCredential`.
- **Sidecar interface tests:** nullalis↔sidecar call contract; statelessness
  (kill+restart mid-session → recovers from vault); `tools/list_changed` updates
  catalog.
- **Gating matrix:** single-user passthrough; tenant disabled; per-user; third
  `+static` warns; shared without ack refused; with ack allowed+warned; **stdio
  refused on shared path**.
- **Per-request freshness:** rotate secret mid-runtime → next call uses new token
  (targets the `:19875` gap directly).
- **OAuth tests:** 401→discovery→token; audience (`resource`) binding; CSRF state
  double-check; SSRF rejection of private-range discovery URLs; cred re-binding
  on URL change.
- **BYO tests:** registration rejects stdio + private-range URL; policy
  disabled/allowlist/open; operator name shadows user server.
- **Concurrency:** timeout → tool-error; quota → fast busy; **`NULLALIS_MCP_LIVE_TEST=1
  zig build test-mcp-live` passes unchanged**.
- **Cross-tenant isolation:** user A's missing/invalid cred never affects user B;
  two tenants with the **same server name** never clobber (the opencode
  `index.ts:119` anti-test).

## 9. Documentation

`docs/mcp-client.md` gains a **"Multi-tenant mode"** section: gating; the
**sidecar** architecture + why; the capability matrix (§4); credential-ref table
+ fail-closed; trust classes + `auth` modes + OAuth/consent + passthrough
warning; BYO (registration, `mcp_byo` policy, remote-only/SSRF); stdio strategy
(§6). **Correct the misleading `Bearer ${TOKEN}` example** (lines 33-36 — *not*
substituted by current code) to real `${user.secret:…}` / OAuth forms.

## 10. Confidence & open questions

**Confidence:** Phases 1, 3, 5, 7 (pure-Zig gating / creds / in-process /
fairness): **high** — validated by code truth + both refs. Phase 2/4 (sidecar +
OAuth): **medium-high** now that we buy the protocol via the SDK (was low when
hand-rolled). Phase 6 (BYO remote): **high**. Phase 8 (per-user pod stdio):
**medium** — depends on the K8s workstream; own brainstorm before build.

**Open:**
- Sidecar deployment shape (co-located process vs its own pod) and the
  nullalis↔sidecar interface (local HTTP vs stdio JSON-RPC) — settle in P2.
- Tool-count/context bloat with many BYO servers (neither ref mitigates) — may
  need lazy/relevance-gated tool exposure.
- Scope-gated OAuth catalogs → per-(user,server) catalog cache w/ TTL if common.
- **Spec B** consumes this foundation (esp. the sidecar can also host the
  *inbound* server, and the shared session-store requirement is shared).

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

**Reference repos (read for rev 2):**
- opencode: `packages/opencode/src/mcp/{index,auth,oauth-provider,oauth-callback}.ts`, `config/mcp.ts` — OAuth-as-SDK-glue (~700 LOC), all-3 transports, `list_changed`, cred re-binding (`auth.ts:69`), the module-global cross-tenant pitfall (`index.ts:119`).
- claude-code: `src/services/mcp/client.ts` (in-process transport `:909-943`), `mcp-server/src/http.ts` (naive inbound baseline), `src/server/api/routes/mcp.ts:130-139` (stdio-in-shared-pod RCE anti-example), `helm/*` (multi-replica → shared session store needed).

**External:** MCP authorization 2025-06-18 · MCP security best practices · MCP Streamable HTTP 2025-03-26 · `@modelcontextprotocol/sdk`.
