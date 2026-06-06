---
tags: [prose, prose/specs, prose/adr]
status: accepted
date: 2026-06-06
---

# ADR: Nullalis MCP hub — unified native-Zig core, dual-role (client + server), edge inbound auth

**Status:** Accepted (2026-06-06)
**Deciders:** Mohammad + Claude (brainstorming session)
**Supersedes:** the Node/TS **sidecar** decision in Spec A & B rev 2
(`2026-06-06-multi-tenant-mcp-client-hardening-design.md`,
`2026-06-06-agent-as-mcp-server-design.md`) — both reconciled to this ADR at
rev 3.

---

## Context

Nullalis (Zig AI-agent gateway, single binary, multi-tenant-capable) is today an
MCP **client** only, with operator-owned static credentials. We want it to be a
full **MCP hub** — both a client and a server — serving four purposes the user
confirmed are all in scope:

1. **Agent-as-a-tool** — external MCP clients call the Nullalis agent.
2. **Aggregator / gateway** — connect to many upstream MCP servers and re-expose
   them (plus own tools) as one endpoint.
3. **Agent mesh (A2A)** — Nullalis agents call each other over MCP.
4. **Curated tool/skill export** — expose a policy-filtered subset.

Both **local single-binary** and **multi-tenant SaaS** must be first-class.

Key facts established by recon + research:
- **No official Zig MCP SDK exists or is announced** (official: TS, Python, Go,
  Kotlin, Java, C#, Swift, Rust, Ruby, PHP). A single-maintainer community lib
  `mcp.zig` exists (spec 2025-11-25). <https://modelcontextprotocol.io/docs/sdk>
- Mature clients (opencode, claude-code) "buy" the protocol from
  `@modelcontextprotocol/sdk`; rev 2 therefore proposed a **Node/TS sidecar**.
- Nullalis already owns the cheap/stable half natively: JSON-RPC framing, stdio
  transport, HTTP POST client (`src/mcp/*`), plus tenancy, the encrypted vault
  (`src/zaki_state.zig:3351`), and a tool/policy layer.
- The expensive half is concentrated in (a) inbound **OAuth resource-server**
  crypto, (b) full **Streamable-HTTP server** streaming, (c) spec-pace.

## Decision

**Build the MCP hub as a unified, native-Zig core with two faces, and move the
hardest piece (inbound auth) to the edge instead of into a sidecar.**

1. **Unified core, two faces.** One Zig core owns tenancy/identity, the encrypted
   vault, a **shared tool registry** (agent tools + skills + client-discovered
   upstream tools, one namespace with provenance + policy), and a **single
   (principal, tool) → allow/deny + which-identity policy plane** used by *both*
   the agent loop and the inbound server. The **client face** and **server face**
   are two views over this core.
2. **Native Zig protocol, both directions.** Extend `src/mcp/*` to complete
   client + server over stdio + Streamable HTTP + SSE. `mcp.zig` is **reference
   only** — no dependency in the security path. No Node/TS sidecar.
3. **Inbound auth at the edge.** An OIDC/OAuth proxy / API gateway / IdP
   validates caller tokens; Zig trusts the injected principal and only emits the
   MCP-specific `WWW-Authenticate` challenge + `/.well-known/oauth-protected-resource`
   metadata. The security-critical token crypto is standard infra, not our code.
4. **Outbound OAuth client is native + bounded.** When an upstream server
   requires OAuth, Nullalis runs the OAuth *client* flow (PKCE/discovery/refresh/
   RFC 8707) natively. This is the only "OAuth in Zig" we own; it is the smaller
   *client* half and only appears when a third-party OAuth upstream is actually
   needed.
5. **Single binary preserved; both deployments first-class.** Local = native Zig
   binary, simple/no inbound auth. SaaS = same binary behind the edge auth proxy
   already operated in K8s.

**The four purposes are emergent properties of this one design**, not separate
builds: agent-as-tool = a registry entry; aggregator = client-discovered tools
re-exposed by the server face; curated = a policy filter on the registry; mesh =
a delegate-to-agent entry + call-depth/origin loop guard.

## Consequences

**Positive**
- Single binary, one language, one supply chain; no npm transitive deps in the
  auth path; no second runtime / IPC hop / version-skew.
- Best-practice inbound auth (edge) with the least security-critical code we own.
- The aggregator and single security plane fall out of the unified core; no
  bolted-on proxy and no dual auth system (kills confused-deputy by construction).
- Leaner SaaS footprint (no per-pod Node runtime).

**Negative / costs we accept**
- We own **spec-pace** for the MCP protocol.
- **Streamable-HTTP server** streaming (GET stream, SSE, resumability/`Last-Event-Id`,
  session `DELETE`) is genuinely new work (current HTTP is POST-only client).
- Native **outbound OAuth client** is ours to write (bounded; deferrable until a
  third-party OAuth upstream is needed).
- A hard dependency on operating an **edge auth layer** in SaaS (already true).

**Neutral**
- Tier 1/2/3 *sequencing* (separate discussion) is unchanged — it is orthogonal
  to protocol-home. Only the Tier-2 mechanics change (native client OAuth + edge
  inbound auth, no sidecar).

## Alternatives considered

- **Node/TS sidecar owns the protocol (rev 2).** Buys OAuth + full transport from
  the official SDK; rejected because edge auth removes the main justification
  (inbound OAuth) and the sidecar taxes the single binary, adds a second
  supply chain *into the auth path*, an IPC hop, and per-pod runtime cost — a poor
  fit for a Zig shop that prioritized "best practice + smooth + single binary."
- **Native Zig with in-app inbound OAuth resource-server.** Maximal control;
  rejected as the largest, most security-critical hand-written surface with no
  upside over standard edge auth.
- **Depend on / fork `mcp.zig`.** Rejected as a live dependency (single-maintainer
  bus factor + spec-lag in a core security path); used as reference only.
- **Two independent client/server subsystems.** Rejected — aggregator + mesh
  require a shared registry + single policy plane; independence would force a
  bolted-on proxy and dual auth.

## Implementation pointers
- Client + foundation (registry, policy plane, per-user creds, native transports,
  native outbound OAuth client): **Spec A rev 3**.
- Server face (edge inbound auth, aggregator/mesh/curated exposure, shared
  session store): **Spec B rev 3**.
