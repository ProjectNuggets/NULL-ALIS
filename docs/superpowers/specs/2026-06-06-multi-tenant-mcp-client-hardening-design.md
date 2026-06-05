---
tags: [prose, prose/specs]
status: draft
date: 2026-06-06
---

# Design: Multi-tenant hardening of the nullalis MCP client (+ BYO outbound servers)

**Author:** brainstorming session (Mohammad + Claude)
**Date:** 2026-06-06
**Status:** Draft — pending user review, then `writing-plans`.

> **Sibling spec.** This is **Spec A** of a two-spec set. Spec A builds the
> per-user credential / trust / OAuth **foundation** for nullalis as an MCP
> **client** (outbound), including user-registered "bring-your-own" (BYO)
> servers. **Spec B** — *agent-as-MCP-server* (inbound surface) — *consumes*
> this foundation and is specced separately
> (`2026-06-06-agent-as-mcp-server-design.md`). The end state is a **symmetric
> MCP node**: every tenant both consumes MCP servers and (if allowed) is one.

> **Scope boundary.** This is a **separate workstream** from the
> `agent-browser` K8s backend (`2026-06-05-agent-browser-default-backend-design.md`).
> That backend uses **native tools**, not MCP. Nothing here touches it.

---

## 1. Context & problem

nullalis is a self-hosted Zig AI-agent gateway that can run **multi-tenant**:
one process serves many users, each with an isolated `TenantRuntime`
(`src/gateway.zig`). It is also an **MCP client** — it consumes external Model
Context Protocol tool servers and exposes their tools to the agent
(`src/mcp.zig`, `src/mcp/transport.zig`, `docs/mcp-client.md`).

A code recon (verified against source for this spec) found that the MCP client
is **single-tenant in disguise**: it works correctly for one user but has
latent multi-tenant gaps that become live the moment a tenant-sensitive MCP
server is wired.

### 1.1 What is already correct (do not "fix")

- **`McpServer` instances are per-user.** `initMcpTools` runs inside each
  `TenantRuntime` (`src/gateway.zig:1990`), so MCP state is isolated per user
  and the per-server mutex (`src/mcp.zig:109`) only serializes *within* one
  user. This is **not** a cross-tenant bug — it is the right isolation
  primitive, and external research confirms "one instance/session per user" is
  the canonical per-tenant isolation pattern.
- **Tool concurrency is real but tenant-safe.** The agent spawns a thread per
  tool call in parallel mode (`src/agent/root.zig:2969`, default-on), but those
  threads share *that user's* `McpServer` and mutex — concurrency never crosses
  tenants.

### 1.2 The real gaps (verified)

1. **Per-user credential isolation (critical).** MCP credentials are **static**,
   set at boot from operator config — `env` / `headers` / `url` in
   `McpServerConfig` (`src/config_types.zig:1472-1510`) with **no per-user
   override and no variable substitution** (`src/mcp/transport.zig:176-178`
   env injection, `:465-468` header injection). MCP tools are exposed in tenant
   mode with **no gating** (`src/gateway.zig:1990`). So every user hits a shared
   server under **one shared identity**. `config.zig:110-114` documents
   "mcp_servers… NOT tenant-settable" but never names the cross-user identity
   consequence. *Latent today* — no tenant-sensitive server is wired in
   production — so this is a **time bomb, not an active leak.**

2. **Scaling.** stdio transport spawns one child process per `McpServer`
   (`src/mcp/transport.zig:157`), eagerly at init (`src/mcp.zig:593`), and
   `McpServer`s are per-user → **N users × M servers = N×M child processes**,
   all spawned on the user's *first* request.

3. **Staleness (discovered while designing).** `TenantRuntime`s are **cached**
   (LRU `tenant_runtime_cache_max_users` default 2048; idle TTL
   `tenant_runtime_idle_ttl_secs` default 1800s — `src/gateway.zig:1084-1085`).
   MCP servers connect **once at init**. `PUT /secrets/<key>` does **not**
   invalidate the cached runtime (`src/gateway.zig:19875`), whereas
   `PATCH /settings` **does** (`src/gateway.zig:19574`). Any "resolve
   credentials at connect time" design therefore serves a **stale token for up
   to 30 minutes** after a user rotates it.

4. **Intra-user concurrency/fairness (minor).** The per-server mutex is held
   across the full blocking round-trip; there is no per-call timeout (only a
   per-`readLine` / curl `--max-time` budget) and no per-user concurrency quota,
   so one slow MCP call head-of-lines that user's other MCP calls.

### 1.3 Spec research — the spec-canonical multi-tenant MCP model

External research against the **MCP 2025-06-18 authorization spec** and 2025
security guidance reframed two of our early instincts:

- **OAuth 2.1 is the intended multi-tenant mechanism**, not static injected
  tokens. An MCP HTTP server is an OAuth 2.1 **Resource Server**; the client
  runs PKCE, discovers the auth server via RFC 9728 protected-resource-metadata
  (off a `401` + `WWW-Authenticate`), and obtains an access token
  **audience-bound to the MCP server URI** (RFC 8707 resource indicators),
  re-asserted on **every** request.
  <https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization>
- **Injecting a user's *third-party* token (e.g. their GitHub PAT) as the MCP
  `Authorization` header is the named "token passthrough" anti-pattern** — *if*
  the server is third-party or forwards it downstream. The MCP `Authorization`
  token must be audience-bound to the MCP server, not to GitHub. Static-token
  injection is legitimate only for **first-party servers you fully control**, or
  as an explicitly **transitional** per-request-header workaround.
  <https://modelcontextprotocol.io/docs/tutorials/security/security_best_practices>
- **A session ID is not an identity credential.** `Mcp-Session-Id` must be
  non-deterministic, bound per-user (`<user_id>:<session_id>`), and **never**
  used for authentication; auth is re-validated per request.

### 1.4 End-state goal (this spec's slice)

> The end user can connect their agent to **any** MCP server — operator-provided
> **or** user-registered (BYO) — and the agent acts under **that user's own
> identity**, with **no user able to affect another**, and with credentials that
> are correct (no token-passthrough), fresh (no staleness), and OAuth-ready.

(The inverse — the user's agent *being* an MCP server — is **Spec B**.)

## 2. Goals / non-goals

**Goals**
- MCP is **off by default in tenant mode**; an operator opts in explicitly and
  is warned precisely when a server exposes a shared identity.
- Each tenant's agent uses **its own credential** per MCP server, resolved
  **per request** (no staleness), via a pluggable provider (static **or**
  delegated OAuth 2.1).
- **stdio is forbidden in tenant mode**; HTTP-only eliminates the N×M
  process blowup by construction.
- **Users can register their own outbound MCP servers (BYO)**, HTTP-only, under
  operator policy, with untrusted-server safety.
- Per-call timeout + per-user concurrency quota so one slow call can't starve a
  user's turn.
- The credential / trust / OAuth core is built so **Spec B (agent-as-server)**
  reuses it without rework.

**Non-goals**
- **Single-user mode behavior is unchanged** — stdio, static config, today's
  flow all keep working when `!tenant.enabled`.
- We do **not** relax the per-server mutex / frame-routing (the verified
  multi-turn stability fix). Phase 6 adds timeout + quota *around* it, not
  inside it.
- We do **not** build the agent-as-MCP-server surface here (Spec B).
- We do **not** implement MCP `sampling` (still deferred, per
  `docs/mcp-client.md`).

## 3. Architecture

### 3.1 The central abstraction: a per-request `CredentialResolver`

Every MCP tool call resolves the requesting user's credential **fresh** and
attaches it to **that** request — never baked at connect. Because the MCP tool
closure already runs inside the per-user `TenantRuntime`, `user_id` is captured
for free; "per-request" means re-reading the vault / token store **each call**,
which:

- structurally kills the staleness bug (no dependence on runtime invalidation),
- satisfies MCP's "auth on every request" rule,
- is the cheapest scale model (per-user MCP state shrinks to near-zero).

```
agent tool call  (inside user U's TenantRuntime)
  └─ McpTool.call(args)                         src/mcp.zig (wrapper)
       └─ resolver.resolve(U, server, request)  NEW  src/mcp/credential.zig
            ├─ static  → credref substitution (vault / operator / user.id)
            └─ oauth   → per-user access token (refresh on expiry)
       └─ McpServer.callTool(args, request_auth) src/mcp.zig (auth threaded in)
            └─ transport.request(..., request_auth) attaches per-request headers
```

**Provider interface (shape, not final Zig):**

```
const RequestAuth = struct { headers: []const Header, /* opaque */ };

const CredentialProvider = struct {
    /// Resolve THIS user's auth for THIS server, for ONE request.
    /// Returns error.MissingCredential to fail closed.
    resolve: fn (ctx: ResolveCtx) ResolveError!RequestAuth,
};

const ResolveCtx = struct {
    user_id: []const u8,
    server: *const McpServerConfig,
    vault: VaultHandle,        // state_mgr.getSecret(numeric_user_id, key)
    token_store: TokenStore,   // per-user OAuth tokens (Phase 4)
};
```

Two providers ship: `static` (Phase 2) and `oauth` (Phase 4). The provider is
selected by the server's `auth` field (§3.3).

### 3.2 `credref` — the static substitution engine

A small, **pure, no-I/O**, fully-tested module (`src/mcp/credref.zig`).
Interface: `resolve(allocator, template, ctx) -> ResolvedValue | error`.
Supported forms inside any `env` value, `header` value, or `url`:

| Form | Resolves to | Identity class |
|---|---|---|
| `${user.secret:KEY}` | `getSecret(user_id, KEY)` from the encrypted `user_secrets` vault (`src/zaki_state.zig:3351`, ChaCha20Poly1305) | **per-user** |
| `${user.id}` | the requesting user's id string (cf. Composio `entity_id = user_id`, `src/gateway.zig:1969`) | per-user (non-secret) |
| `${operator.secret:KEY}` | operator-scoped secret (operator config map and/or process env) | **shared** |
| `$${` | literal `${` (escape) | — |

**Hard rules:**
- **Fail closed.** A missing `${user.secret:KEY}` ⇒ `error.MissingCredential`;
  the call returns a tool-error and the server is **absent for that user only**
  (other users unaffected). Never an empty/blank credential on the wire.
- **No silent passthrough.** Any unknown `${…}` token ⇒ error (never emit it
  unexpanded).
- There is intentionally **no `${env:VAR}` form** — raw env would be
  indistinguishable from a per-user ref at audit time. Operator env is sourced
  *through* `${operator.secret:KEY}`, which is statically detectable as shared.

### 3.3 Server trust + auth classification

New `McpServerConfig` fields (`src/config_types.zig:1472`):

```
trust: enum { first_party, third_party } = .third_party,  // default safe
auth:  enum { none, static, oauth }      = .static,
allow_shared_identity: bool = false,      // operator ack for shared-identity
```

**Classification drives gating and the token-passthrough warning:**

- A server is **per-user** iff every credential-bearing value resolves using
  *only* `${user.*}` refs (or `auth = oauth`). Needs no acknowledgment.
- A server is **shared-identity** if any credential value is literal-nonempty or
  uses `${operator.secret:…}`. In tenant mode it requires
  `allow_shared_identity = true`, else it is **refused + warned**.
- **Token-passthrough guard:** `trust = third_party` **and** a `${user.secret}`
  injected into an `Authorization`-class header ⇒ **WARN** (transitional debt):
  *"server '<name>' is third_party but receives a per-user bearer — this is the
  MCP token-passthrough anti-pattern; prefer auth=oauth."* `first_party + static`
  is allowed silently (legitimate first-party use).

### 3.4 Discovery / invocation split + per-user session handle

A tool **catalog** (names / schemas) is user-independent, so:

- **Discovery** (`tools/list`, resources, prompts) is done **once per server**
  and the catalog is **shared** across that operator-server's users. (For OAuth
  servers whose catalog is scope-gated, discovery falls back to per-user-on-
  first-use, cached per user — an acknowledged edge case.)
- **Invocation** attaches the per-user credential **per request**.
- Per-user state collapses to a tiny **session handle**: `Mcp-Session-Id` +
  `next_id` + mutex, created lazily on first call, **bound to the user**
  (`<user_id>:<session_id>`), evicted with the runtime. Never shared across
  users (cross-tenant leak vector per research).

This is lighter than today's full per-user re-discovery and matches the
spec-blessed "shared server, per-request auth, per-user session" model.

### 3.5 Tenant-mode gating + HTTP-only

At `initMcpTools` (`src/gateway.zig:1990`) the tenant flag (`state.tenant_enabled`,
`src/gateway.zig:1081`) is threaded through:

- **single-user** (`!tenant_enabled`): unchanged — full current behavior,
  stdio included.
- **tenant + `mcp_enabled == false`** (new `tenant.mcp_enabled` default false):
  skip MCP entirely; log once.
- **tenant + `mcp_enabled == true`**: per-server classification (§3.3); any
  `stdio` server (explicit or inferred) is **refused** with a clear operator
  error pointing to HTTP; shared-identity servers without ack are refused +
  warned.

MCP remains **additive-safe**: any refusal/skip/resolution error leaves the
agent running on builtin tools (today's behavior at `src/gateway.zig:1991`).

### 3.6 BYO — user-registered outbound servers

The end-user "connect to any MCP" capability. This **reverses** the
operator-only invariant (`config.zig:110-114`) in a controlled way:

- **Storage.** A per-user MCP server registry persisted in Postgres alongside
  per-user config (`{schema}.user_config` pattern, `src/zaki_state.zig:2801`),
  visible only to that user. Operator-provided servers and user-registered
  servers merge into the user's effective catalog (name-collision → operator
  wins, user server logged as shadowed).
- **Operator policy** (new `tenant.mcp_byo` enum): `disabled` (default) /
  `allowlist` (operator host/domain allowlist) / `open`. `disabled` means BYO is
  off regardless of per-user settings.
- **HTTP-only, always.** A user can **never** register a stdio server — no
  arbitrary process spawn on shared infra. Enforced at registration and at init.
- **Untrusted-server safety.** A user-registered server is `trust = third_party`
  by construction. Defenses:
  - **SSRF / egress:** validate the URL at registration and per request —
    HTTPS-only, block private / link-local / metadata ranges, optional operator
    egress allowlist. (Shared with Phase 4 discovery defenses.)
  - **Tool-poisoning / prompt-injection:** server-supplied tool *descriptions*
    and *results* are untrusted input. They are surfaced to the model with
    provenance ("from user-registered server X"), never granted elevated
    autonomy, and counted under the user's existing approval/autonomy gates.
  - **Credentials:** the user's own — `${user.secret:…}` or per-user OAuth.
- BYO reuses §3.1 resolver + §3.4 split + §4 OAuth wholesale; it adds storage +
  policy + registration UX, not a new transport path.

## 4. Phases (sequenced; Phase 1 ships first)

| # | Phase | Depends on | Ships value |
|---|---|---|---|
| 1 | **Gating + HTTP-only** | — | Closes the latent shared-identity risk *today* |
| 2 | **Per-request resolver + `credref` + trust classification** | 1 | Per-user identity correctness; staleness fixed |
| 3 | **Discovery/invocation split + per-user session handle** | 2 | Scaling; spec-correct session model |
| 4 | **Delegated OAuth 2.1 client provider** | 2 | Spec-canonical per-user auth; kills passthrough |
| 5 | **BYO user-registered outbound servers** | 2, 4 | "Connect to any MCP" |
| 6 | **Per-call timeout + per-user concurrency quota** | — (independent) | Intra-user fairness |

### Phase 1 — Tenant-mode gating + HTTP-only
- New `tenant.mcp_enabled: bool = false`.
- Thread tenant flag into `initMcpTools`; implement the three branches (§3.5).
- Refuse stdio in tenant mode; emit the per-server shared-identity WARN.
- **Cheapest immediate safeguard — land before any tenant-sensitive server.**

### Phase 2 — Per-request resolver + `credref` + trust classification
- `src/mcp/credref.zig` (pure, §3.2).
- `src/mcp/credential.zig` — the resolver + `static` provider (§3.1).
- New `McpServerConfig` fields `trust` / `auth` / `allow_shared_identity` (§3.3).
- Thread `RequestAuth` through `McpServer.callTool` → `transport.request`;
  resolve **per call**. Fail-closed wiring.
- Token-passthrough WARN.

### Phase 3 — Discovery/invocation split + per-user session handle
- Hoist catalog discovery to per-server (shared); introduce the lazy per-user
  session handle bound `<user_id>:<session_id>` (§3.4).
- Remove redundant per-user re-discovery.

### Phase 4 — Delegated OAuth 2.1 client provider
- `oauth` provider plugging into the resolver.
- PKCE; RFC 9728 protected-resource-metadata discovery via `WWW-Authenticate` on
  `401`; RFC 8414 AS metadata; RFC 7591 dynamic client registration (SHOULD);
  **RFC 8707 resource indicators** (audience-bind to server URI on auth + token
  requests).
- Per-user token store (encrypted, vault-backed) + refresh-on-expiry.
- **SSRF defenses** on every discovery fetch: HTTPS-only, block private /
  link-local / metadata ranges, validate redirect hops.
- Per-user browser **consent flow** (authorize URL issuance + callback capture).

### Phase 5 — BYO user-registered outbound servers
- Per-user MCP registry storage + merge (§3.6).
- `tenant.mcp_byo` policy enum; allowlist enforcement.
- Registration validation (HTTP-only, SSRF, optional egress allowlist).
- Untrusted-server provenance + autonomy handling.

### Phase 6 — Per-call timeout + per-user concurrency quota
- Promote `read_line_timeout_secs` / curl `--max-time` into a guaranteed
  **per-invocation** wall-clock budget (hung call ⇒ tool-error, not a stalled
  turn).
- Per-user **concurrent-MCP-call quota** (small configurable N); excess ⇒ fast
  "MCP busy" tool-error.
- Mutex / frame-routing untouched.

## 5. Security posture (explicit)

- **Token passthrough:** documented as an anti-pattern; enforced via the
  trust-class WARN (§3.3); OAuth (Phase 4) is the named correct path.
- **Fail closed:** missing per-user credential ⇒ server absent for that user
  only; never an empty token.
- **Session ≠ identity:** non-deterministic server-issued IDs, bound per-user,
  never reused cross-user, never used for auth.
- **SSRF / egress:** enforced on OAuth discovery (Phase 4) and BYO registration
  + per-request (Phase 5) — HTTPS-only, block private/link-local/metadata.
- **Untrusted MCP output:** server tool descriptions/results carry provenance,
  no autonomy elevation, counted under existing approval gates.
- **Secret hygiene:** secrets enter memory only at call time; logs carry key
  *names* + server names, never values.

## 6. Testing strategy

- **`credref` unit tests** (pure): each form, `$${` escape, missing-secret
  fail-closed, unknown-token error, mixed literal+ref, per-user vs shared
  classification.
- **Resolver tests:** `static` + `oauth` providers against a mocked vault /
  token store; refresh; expiry; `error.MissingCredential` path.
- **Gating matrix:** single-user passthrough; tenant disabled; tenant per-user;
  tenant `third_party + static` warns; tenant shared without ack refused; tenant
  shared with ack allowed+warned; **tenant stdio refused**.
- **Per-request freshness test:** rotate a user's secret mid-runtime → the
  *next* call uses the new token (proves staleness fixed — directly targets the
  `src/gateway.zig:19875` gap).
- **OAuth tests:** `401 → discovery → token`; audience (`resource`) binding;
  SSRF rejection of private-range discovery URLs.
- **BYO tests:** registration rejects stdio; rejects private-range URL; policy
  `disabled`/`allowlist`/`open`; operator-server name shadows user server.
- **Concurrency:** per-call timeout returns tool-error; quota returns fast
  busy-error; **`NULLALIS_MCP_LIVE_TEST=1 zig build test-mcp-live` still passes
  unchanged** (frame routing not perturbed).
- **Cross-tenant isolation:** user A's missing/invalid credential never affects
  user B's catalog or calls.

## 7. Documentation

`docs/mcp-client.md` gains a **"Multi-tenant mode"** section:
- gating (`tenant.mcp_enabled`), HTTP-only rule, the N×M rationale;
- credential-ref table (`${user.secret}` / `${user.id}` / `${operator.secret}`,
  `$${` escape) and fail-closed semantics;
- trust classes (`first_party` / `third_party`), `auth` modes, OAuth setup +
  user consent, the token-passthrough warning;
- BYO: how a user registers a server, operator `mcp_byo` policy, HTTP-only +
  SSRF constraints;
- **correct the misleading `Bearer ${TOKEN}` example** (lines 33-36 today — it is
  *not* substituted by current code) to the real `${user.secret:…}` / OAuth
  forms.

## 8. Open questions / future work

- **Catalog for scope-gated OAuth servers:** §3.4 falls back to per-user
  discovery when a server's tool list varies by scope. If this proves common,
  a per-(user,server) catalog cache with TTL may be warranted.
- **Operator egress proxy** (Smokescreen-style) for BYO/OAuth fetches — named,
  not specced.
- **Spec B (agent-as-MCP-server)** consumes this foundation; see its companion
  doc.

## 9. Code-truth reference index

| Claim | Evidence |
|---|---|
| MCP init per `TenantRuntime`, no gating | `src/gateway.zig:1990` |
| Per-user `McpServer`, per-server mutex | `src/mcp.zig:109`, `:582-685` |
| Static creds, no substitution | `src/config_types.zig:1472-1510`, `src/mcp/transport.zig:176-178,465-468` |
| stdio = child per server, eager spawn | `src/mcp/transport.zig:157`, `src/mcp.zig:593` |
| HTTP = curl per request, session cached | `src/mcp/transport.zig:447-511` |
| TenantRuntime cached LRU+TTL | `src/gateway.zig:1084-1085`, `:2609-2654` |
| Secret PUT does not invalidate runtime | `src/gateway.zig:19875` vs `:19574` |
| Tool concurrency real (thread/tool) | `src/agent/root.zig:2969` |
| Encrypted per-user vault | `src/zaki_state.zig:3351` (`getSecret`/`putSecret`) |
| "not tenant-settable" note | `src/config.zig:110-114` |
| Tenant mode flag | `src/gateway.zig:1081`, `:5424` |

### External sources
- MCP authorization (2025-06-18): <https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization>
- MCP security best practices: <https://modelcontextprotocol.io/docs/tutorials/security/security_best_practices>
- MCP Streamable HTTP (2025-03-26): <https://modelcontextprotocol.io/specification/2025-03-26/basic/transports>
- Multi-user authorization discussion #234: <https://github.com/modelcontextprotocol/modelcontextprotocol/discussions/234>
- Cloudflare enterprise MCP reference architecture: <https://blog.cloudflare.com/enterprise-mcp/>
