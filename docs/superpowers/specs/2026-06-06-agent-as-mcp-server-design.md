---
tags: [prose, prose/specs]
status: stub
date: 2026-06-06
---

# Design (companion stub): Agent-as-MCP-server — the inbound surface

**Author:** brainstorming session (Mohammad + Claude)
**Date:** 2026-06-06
**Status:** **Stub** — scoped, not yet designed in full. Depends on Spec A.

> **Sibling spec.** This is **Spec B** of a two-spec set. It **consumes the
> foundation** built by **Spec A**
> (`2026-06-06-multi-tenant-mcp-client-hardening-design.md`) and turns nullalis
> from an MCP *client* into a *bidirectional* MCP node: each user's agent can
> **be** an MCP server that external clients call. This stub captures scope and
> the dependency contract so Spec A is designed with B's needs in mind; it will
> be expanded into a full design (its own brainstorm → spec → plan) **after Spec
> A's OAuth/credential foundation lands.**

---

## 1. The end-state half this covers

The symmetric end state: *"any user's Agent should be able to be an MCP server
itself, if allowed."* Where Spec A makes nullalis a correct multi-tenant MCP
**client** (outbound — consuming servers under each user's identity), Spec B
makes each tenant a multi-tenant MCP **server** (inbound — exposing the user's
agent / a scoped subset of their tools to external MCP clients like Claude
Desktop, Cursor, or *another* nullalis user's agent).

```
External MCP client (Claude Desktop / Cursor / another agent)
   │  JSON-RPC over Streamable HTTP, Authorization: Bearer <audience-bound token>
   ▼
nullalis MCP server endpoint              NEW surface (this spec)
   ├─ OAuth 2.1 Resource Server: validate token, derive user_id
   ├─ route to THAT user's TenantRuntime ONLY  (hard tenant isolation)
   ├─ expose: the agent as a tool, and/or a scoped subset of the user's tools
   └─ per-user <user_id>:<session_id> binding, per-request re-validation
```

## 2. Why it is a separate spec (not a Spec-A phase)

- **Inverse role.** In Spec A nullalis is the OAuth **client**; here it is the
  OAuth **Resource Server** — it must *issue/validate* audience-bound tokens
  (RFC 8707), implement RFC 9728 protected-resource-metadata, and reject
  passthrough tokens. New responsibilities, not a new provider.
- **New endpoint surface.** A served MCP Streamable-HTTP endpoint (request
  routing, session lifecycle, capability negotiation) — a distinct subsystem
  from the curl-based client transport.
- **Distinct threat model.** Inbound, internet-facing: authn/authz of *callers*,
  capability scoping, abuse/rate limiting, and the cross-tenant-isolation
  guarantee that an inbound call can reach exactly one user's runtime.

Keeping it separate keeps each spec implementable as one coherent unit
(brainstorming decomposition rule).

## 2b. Recon finding — the hard part is greenfield

A recon of claude-code (which ships an `mcp-server/`) found **no reusable
multi-tenant inbound reference**: its `mcp-server/src/http.ts` is a naive
baseline — a single **shared static bearer** token, **off by default**
(`if (!API_KEY) return next()`, `http.ts:34`), an **in-process** `Map` of
sessions that breaks across K8s replicas (`http.ts:52`), and **zero tenant
mapping** (a request maps to a transport, not a principal). Its real
"agent-as-MCP" entrypoint (`src/entrypoints/mcp.ts`) is **single-user/local
stdio**. So the inbound trio — **caller auth + token→tenant mapping + isolation
+ a shared/sticky session store** — is genuinely novel work. Treat `http.ts`
as a *what-not-to-ship* baseline, not a model. This is why B is its own spec and
why its difficulty was understated in Spec A rev 1.

## 3. Dependency contract — what Spec B needs from Spec A

Spec A must build these so B can consume them without rework:

- **The MCP sidecar (Node/TS, official SDK).** Spec A introduces a sidecar that
  owns the MCP *client* protocol. The **same sidecar process can host the
  *server* side** (the SDK's `StreamableHTTPServerTransport`), so B gets full
  inbound Streamable HTTP/SSE + session lifecycle for free instead of
  hand-rolling an MCP server in Zig. B adds the resource-server auth + tenant
  routing *in front of* it.
- **OAuth 2.1 machinery** usable in the **Resource Server** direction
  (token validation, audience/`resource` binding, discovery metadata), not only
  the client direction.
- **A shared/sticky session store** (NOT in-process) — required from day one
  because nullalis runs multi-replica (Helm/K8s); `<user_id>:<session_id>`
  binding lives here.
- **Credential/identity mapping** that turns a validated inbound token into a
  `user_id` → `TenantRuntime` (mirror of Spec A's per-user resolver), with **no
  principal-collapse mode** (Spec A §7 anti-pattern).
- **Trust + session model:** non-deterministic, per-user `<user_id>:<session_id>`
  binding; "never authenticate via session"; per-request re-validation — applied
  to the *inbound* path.
- **SSRF/egress posture** and **untrusted-input provenance** conventions, reused
  for inbound capability exposure.

## 4. Scope sketch (to be expanded)

**In scope (future full spec):**
- A per-user MCP server endpoint, addressable/token-scoped, routed to the owning
  `TenantRuntime`.
- Per-user **opt-in** + operator **policy gate** ("if allowed").
- **Capability scoping:** which of the user's tools/skills (or just an
  "invoke-agent" tool) are exposed, per token/scope.
- OAuth 2.1 Resource Server: token validation, audience binding, consent.
- Hard tenant isolation of inbound calls; abuse/rate controls.

**Open questions for B's brainstorm:**
- Exposure granularity: whole-agent-as-tool vs curated tool/skill subset?
- Token issuance: does nullalis act as its own Authorization Server, or
  delegate to an external IdP?
- Addressing: one endpoint with token-selected tenant, vs per-user URLs?
- Relationship to the existing channel/gateway auth surfaces.

## 5. Next action

Expand this stub into a full design **after Spec A Phase 4 (OAuth) lands**, via a
dedicated brainstorm → spec → `writing-plans` cycle. Do not begin B's
implementation before A's foundation exists.
