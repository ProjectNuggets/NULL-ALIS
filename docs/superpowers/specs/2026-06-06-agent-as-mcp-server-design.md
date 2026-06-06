---
tags: [prose, prose/specs]
status: stub
date: 2026-06-06
---

# Design (companion stub): Agent-as-MCP-server — the inbound surface (native Zig + edge auth)

**Author:** brainstorming session (Mohammad + Claude)
**Date:** 2026-06-06
**Status:** **Stub** (rev 3 — conforms to `2026-06-06-adr-nullalis-mcp-hub-architecture.md`:
native-Zig server face over the unified core, **inbound auth at the edge**, **no
sidecar**). Full design after Spec A's core (registry + policy plane + native
transports) lands.

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
- **Agent mesh (A2A)** — a "delegate-to-agent" registry entry; another nullalis
  connects client→server. Needs a call-depth/origin loop guard.

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

## 2b. Recon finding — the hard part is greenfield

claude-code ships an `mcp-server/`, but it is **no reusable multi-tenant inbound
reference**: a single **shared static bearer**, **off by default**
(`if (!API_KEY) return next()`, `http.ts:34`), an **in-process** session `Map`
that breaks across K8s replicas (`http.ts:52`), and **zero tenant mapping**. Its
real agent-as-MCP entrypoint (`src/entrypoints/mcp.ts`) is single-user/local
stdio. So the inbound trio — **edge-validated caller identity → tenant mapping →
isolation + a shared/sticky session store** — is genuinely novel work. Treat
`http.ts` as a *what-not-to-ship* baseline.

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
  `TenantRuntime` via the edge-injected principal.
- Per-user **opt-in** + operator **policy gate** ("if allowed").
- **Capability scoping** per token/scope across all four purposes (agent-as-tool,
  aggregator, curated, mesh).
- MCP metadata emission (`/.well-known/oauth-protected-resource`,
  `WWW-Authenticate`) — the only auth-adjacent code nullalis owns; validation is
  the edge's job.
- Hard tenant isolation of inbound calls; abuse/rate controls; mesh loop guard.

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
