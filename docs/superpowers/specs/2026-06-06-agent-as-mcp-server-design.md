---
tags: [prose, prose/specs]
status: stub
date: 2026-06-06
---

# Design (companion stub): Agent-as-MCP-server — the inbound surface (native Zig + edge auth)

**Author:** brainstorming session (Mohammad + Claude)
**Date:** 2026-06-06
**Status:** **Stub** (**rev 4** — A2A promoted to first-class peer protocol;
corrects the "greenfield" framing: a native MCP server **already exists** and is
**extended**, not built from scratch. Conforms to
`2026-06-06-adr-nullalis-mcp-hub-architecture.md`: native-Zig server face over the
unified core, **inbound auth at the edge**, **no sidecar**). Full design after
Spec A's core (registry + policy plane + native transports) lands.

> **Sibling spec.** Spec B is the **server half** of the MCP hub; **Spec A**
> (`2026-06-06-multi-tenant-mcp-client-hardening-design.md`) is the **client half
> + the shared unified core**. Per the ADR, both faces are **two views over one
> native-Zig core** — the server face exposes a policy-filtered view of the same
> tool registry the client face populates. This stub captures scope + the
> dependency contract so Spec A builds the core with B's needs in mind.

---

## 1. The end-state half this covers — all four server purposes

The symmetric end state: *"any user's Agent should be able to be an MCP server
itself, if allowed."* The four confirmed purposes are **emergent properties of
the unified core**, not separate builds:

- **Agent-as-a-tool** — expose the user's agent as one invokable registry entry.
- **Aggregator / gateway** — re-expose the client-face-discovered upstream tools
  (already in the registry) as one clean endpoint.
- **Curated tool/skill export** — a policy filter on the registry per principal.
- **Agent mesh (A2A) — first-class peer protocol** (rev 4, per ADR rev 2). The hub
  exposes an **A2A surface** (Agent Cards for capability discovery + the Task
  lifecycle for delegation), not a private MCP-mesh convention, so cross-vendor
  agents (Google A2A ecosystem; IBM ContextForge federates A2A as a peer)
  interoperate. Governed by the same registry/policy plane; needs `max_hops` +
  `max_depth` + cycle-detection loop guards.

```
External MCP client (Claude Desktop / Cursor / another nullalis agent)
   │  JSON-RPC over Streamable HTTP, Authorization: Bearer <token>
   ▼
EDGE auth (OIDC/OAuth proxy / API gateway / IdP)   ← validates token (ADR)
   │  injects validated principal (user identity) — token crypto is NOT our code
   ▼
nullalis native MCP server face (Zig)              NEW surface (this spec)
   ├─ emit MCP metadata: /.well-known/oauth-protected-resource + WWW-Authenticate
   ├─ map injected principal → user_id → THAT user's TenantRuntime ONLY
   ├─ expose the policy-filtered slice of the SHARED tool registry
   └─ per-user <user_id>:<session_id> binding; per-request re-check
```

## 2. Why it is a separate spec (not a Spec-A phase)

- **Inverse data-flow + new endpoint surface.** A *served* MCP Streamable-HTTP
  endpoint (inbound request routing, session lifecycle, capability negotiation)
  is a distinct subsystem from the client transport — even though both are native
  Zig over the same core.
- **Distinct threat model.** Internet-facing inbound: caller authz (at the edge),
  capability scoping, abuse/rate limiting, and the hard guarantee that an inbound
  call reaches exactly one user's runtime.
- **Auth is at the edge (ADR), not in-app.** nullalis does **not** hand-roll an
  OAuth resource-server; the edge validates tokens and injects identity. The Zig
  server face only emits MCP-specific metadata/challenge and trusts the injected
  principal. This is the key simplification rev 2 lacked.

## 2b. What exists vs what's new (corrects rev-1's "greenfield")

**The MCP server protocol mechanics already exist natively** (verified in the
working repo): `src/mcp_server.zig` + `src/mcp/server_{auth,handlers,policy,
protocol}.zig` implement a native-Zig MCP server (stdio, JSON-RPC) with a
**deny-by-default exposure policy** (`server_policy.zig`: 7 safe + 4 memory tools,
`NULLALIS_MCP_EXPOSE_ALL` escape hatch) and token auth (`server_auth.zig`). Spec B
**extends** this — the curated-export purpose is largely *already implemented*.

**What is genuinely new (the multi-tenant inbound layer):** edge-validated caller
identity, **tenant mapping**, **isolation**, a **shared/sticky session store**,
**network transport** (today's server is stdio), and the **aggregator** + **A2A**
surfaces. No reusable reference exists for this: claude-code's `mcp-server/` is a
*what-not-to-ship* baseline (shared static bearer off-by-default `http.ts:34`,
in-process session `Map` that breaks across K8s replicas `http.ts:52`, zero tenant
mapping); hermes's `mcp serve` and openclaw's channel-bridge are single-owner. The
multi-tenant inbound layer is ours to design — but on top of a working native
server, not a blank page.

## 3. Dependency contract — what Spec B needs from Spec A's core

- **The shared tool registry + single policy plane** (Spec A §3.1). The server
  face exposes a *policy-filtered view* of the registry; aggregator/curated/mesh
  all fall out of this. No second protocol stack.
- **Native Streamable HTTP/SSE transport** (Spec A Phase 2) — reused server-side
  (`StreamableHTTPServerTransport` equivalent in Zig: GET stream, POST, `DELETE`,
  SSE). This is why Phase 2 completes the native transport once, for both faces.
- **Edge-auth integration contract:** how the validated principal is injected
  (header/mTLS/JWT claims) and mapped to `user_id` → `TenantRuntime`, with **no
  principal-collapse mode** (Spec A §7 anti-pattern).
- **A shared/sticky session store** (NOT in-process; Postgres/`zaki_state`-backed)
  — required from day one because nullalis runs multi-replica (Helm/K8s);
  `<user_id>:<session_id>` binding lives here.
- **Trust + session model:** non-deterministic IDs, per-user binding, "never
  authenticate via session", per-request re-check on the inbound path.
- **SSRF/egress posture + untrusted-input provenance** conventions, reused for
  inbound capability exposure and (for aggregator) re-exposed upstream tools.

## 4. Scope sketch (to be expanded)

**In scope (future full spec):**
- A per-user MCP server endpoint, addressable/token-scoped, routed to the owning
  `TenantRuntime` via the edge-injected principal — **extending the existing native
  `src/mcp_server.zig`** to network transport + multi-tenant.
- An **A2A surface** (Agent Cards + Task lifecycle + A2A-server federation) as a
  peer to the MCP server face, over the same registry/policy plane.
- Per-user **opt-in** + operator **policy gate** ("if allowed").
- **Capability scoping** per token/scope across all purposes (agent-as-tool,
  aggregator, curated, A2A mesh) — built on `server_policy.zig`'s deny-by-default.
- **Dynamic permission-scoped tool filtering** (return only the caller's allowed
  slice) — fixes context bloat *and* is a security control.
- MCP metadata emission (`/.well-known/oauth-protected-resource`,
  `WWW-Authenticate`) — the only auth-adjacent code nullalis owns; validation is
  the edge's job. **Invariant:** advertised resource URI == edge-validated token
  audience == canonical hub URI.
- **Tool-poisoning defense for the aggregator face:** fingerprint + pin + change-
  detect re-exposed upstream tools (rug-pull guard).
- **OpenTelemetry GenAI tracing** of inbound tool/Task calls.
- Hard tenant isolation of inbound calls; abuse/rate controls; mesh loop guards
  (`max_hops`/`max_depth`/cycle detection).

**Open questions for B's brainstorm:**
- Exposure granularity per purpose and per principal.
- **Edge choice:** which OIDC/OAuth proxy or gateway (oauth2-proxy / Envoy / cloud
  gateway / the existing nullalis gateway auth) and the principal-injection
  contract.
- Addressing: one endpoint with token-selected tenant vs per-user URLs.
- Mesh: depth/origin headers + policy for agent-to-agent calls.
- Relationship to the existing channel/gateway auth surfaces (likely the edge).

## 5. Next action

Expand this stub into a full design **after Spec A's unified core (Phases 2–3:
native transport + registry/policy plane) lands**, via a dedicated brainstorm →
spec → `writing-plans` cycle. Do not begin B's implementation before the core
exists.
