---
tags: [prose, prose/specs, prose/adr]
status: accepted
date: 2026-06-06
---

# ADR: Nullalis MCP hub — unified native-Zig core, dual-role (client + server), edge inbound auth

**Status:** Accepted (2026-06-06) · **rev 2** (adds A2A as a first-class peer
protocol + the S-tier hardening pillars, after a reference-agent + best-practice
pressure test: hermes, openclaw, IBM ContextForge, Cloudflare, Solo.io).
**Deciders:** Mohammad + Claude (brainstorming session)
**Supersedes:** the Node/TS **sidecar** decision in Spec A & B rev 2
(`2026-06-06-multi-tenant-mcp-client-hardening-design.md`,
`2026-06-06-agent-as-mcp-server-design.md`) — both reconciled to this ADR at
rev 3+ (rev 4 folds in the A2A + hardening additions below).

---

## Context

Nullalis (Zig AI-agent gateway, single binary, multi-tenant-capable) is today an
MCP **client** only, with operator-owned static credentials. We want it to be a
full **MCP hub** — both a client and a server — serving four purposes the user
confirmed are all in scope:

1. **Agent-as-a-tool** — external MCP clients call the Nullalis agent.
2. **Aggregator / gateway** — connect to many upstream MCP servers and re-expose
   them (plus own tools) as one endpoint.
3. **Agent mesh (A2A)** — Nullalis agents delegate to each other. **rev 2: via
   the A2A protocol as a first-class peer to MCP** (was "over MCP").
4. **Curated tool/skill export** — expose a policy-filtered subset.

Both **local single-binary** and **multi-tenant SaaS** must be first-class.

Key facts established by recon + research:
- **No official Zig MCP SDK exists or is announced** (official: TS, Python, Go,
  Kotlin, Java, C#, Swift, Rust, Ruby, PHP). A single-maintainer community lib
  `mcp.zig` exists (spec 2025-11-25). <https://modelcontextprotocol.io/docs/sdk>
- Mature clients (opencode, claude-code) "buy" the protocol from
  `@modelcontextprotocol/sdk`; rev 2 (of the specs) therefore proposed a sidecar.
- **Nullalis already owns more than half the hub natively** (verified in the
  working repo): JSON-RPC framing, stdio transport, HTTP POST client (`src/mcp/*`);
  **a native MCP *server*** (`src/mcp_server.zig`, `src/mcp/server_{auth,handlers,
  policy,protocol}.zig`) with **deny-by-default tool exposure** (7 safe + 4 memory
  tools, `NULLALIS_MCP_EXPOSE_ALL` escape hatch); **OAuth 2.0 + PKCE + device flow
  + credential store** (`src/auth.zig`, RFC 7636/8628); tenancy + the encrypted
  vault (`src/zaki_state.zig:3351`). The native-Zig bet is **proven, not theory.**
- The expensive remaining half: (a) inbound **OAuth resource-server** crypto →
  **moved to the edge**; (b) full **Streamable-HTTP server** streaming
  (resumability/`Last-Event-Id`); (c) spec-pace.
- **A2A is the ecosystem standard for cross-vendor agent delegation** (Google →
  Linux Foundation, 150+ orgs; Agent Cards + Task lifecycle). The leading gateway
  (IBM ContextForge) federates A2A as a first-class peer to MCP. Mesh-over-MCP-only
  is an interop gap — hence the rev-2 promotion of A2A.
- **Edge auth is spec-compliant**: the MCP spec defines the resource-server role
  *by role, not by process*, so terminating OAuth at a gateway/proxy satisfies
  RFC 9728/8707 **iff** the edge's validated-token audience == the app's advertised
  protected-resource URI == the canonical hub URI.

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
6. **A2A is a first-class peer protocol, not subsumed by MCP** (rev 2). The hub
   speaks **both** MCP (agent↔tools) and **A2A** (agent↔agent: Agent Cards for
   capability discovery + the Task lifecycle for delegation), like IBM
   ContextForge. Mesh delegations use A2A so cross-vendor agents interoperate;
   the unified registry/policy plane governs both.

**The four purposes are emergent properties of this one design**, not separate
builds: agent-as-tool = a registry entry; aggregator = client-discovered tools
re-exposed by the server face; curated = a policy filter on the registry; mesh =
an A2A Agent Card + Task surface over the same registry, with `max_hops`/`max_depth`
+ cycle-detection loop guards.

### S-tier hardening pillars (rev 2 — required to claim best-practice, not optional)

These are **additive to**, not corrections of, the decisions above. The pressure
test (external best-practice + reference agents) showed the architecture is sound
but that "S-tier in 2026" demands:

7. **Protocol conformance harness.** Pin + negotiate protocol versions; test
   Streamable-HTTP resumability (`Last-Event-Id`) and session teardown against the
   official MCP inspector/test tooling. This is what makes "native, no SDK"
   *durable* against spec churn.
8. **OpenTelemetry GenAI tracing.** Model call + tool call in **one trace**;
   per-tool latency/error. Table stakes for an agent platform in 2026.
9. **Tool-poisoning / rug-pull defense.** Tool-definition **pinning + change
   detection + server fingerprinting**; treat tool descriptions/results as
   untrusted; **no dynamic registration on the shared path**; scan descriptions for
   injection and run an OSV/malware check before any (per-pod) stdio spawn
   (lift from hermes `tools/mcp_tool.py`).
10. **Edge-trust invariants (written, enforced).** Only the edge may inject
    identity (mTLS / network boundary); the app **strips client-supplied identity
    headers**; **emitted protected-resource audience == validated-token audience ==
    canonical hub URI**; the inbound token is **never** forwarded upstream
    (mint a separate per-user upstream token from the vault — confused-deputy
    defense).
11. **Scope minimization + step-up auth + DLP/guardrail scanning** on the policy
    plane; **dynamic permission-scoped tool filtering** (return only the caller's
    allowed tools — fixes context bloat *and* is a security control).

## Consequences

**Positive**
- Single binary, one language, one supply chain; no npm transitive deps in the
  auth path; no second runtime / IPC hop / version-skew.
- Best-practice inbound auth (edge) with the least security-critical code we own.
- The aggregator and single security plane fall out of the unified core; no
  bolted-on proxy and no dual auth system (kills confused-deputy by construction).
- Leaner SaaS footprint (no per-pod Node runtime).
- **Validated as the consensus pattern** (unified registry + virtual-server view +
  edge auth + per-upstream creds) by IBM ContextForge, Cloudflare MCP Portals,
  Solo.io Virtual MCP — and converged on independently by openclaw's
  `trusted-proxy`/header-injection auth.
- **Much of it already exists natively** (server, policy, PKCE OAuth) → lower risk,
  smaller build than rev-1 assumed; Spec B is **extend, not greenfield**.
- **A2A first-class** closes the only real interop gap → cross-vendor agent
  delegation without a private convention.

**Negative / costs we accept**
- We own **spec-pace** for the MCP protocol.
- **Streamable-HTTP server** streaming (GET stream, SSE, resumability/`Last-Event-Id`,
  session `DELETE`) is genuinely new work (current HTTP is POST-only client).
- Native **outbound OAuth client** is ours to write (bounded; deferrable until a
  third-party OAuth upstream is needed).
- A hard dependency on operating an **edge auth layer** in SaaS (already true).
- **A2A is added scope** (Agent Cards + Task lifecycle + federation) — a second
  protocol surface, justified by cross-vendor interop but real work.
- The **S-tier pillars (7–11)** are non-trivial: conformance harness, OTel
  tracing, tool-poisoning defense, edge-trust invariants, scoped filtering.

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
- **Stable foundation contracts** (Transport, ToolRegistry, PolicyPlane,
  CredentialResolver, SessionStore, Telemetry, EdgeAuthContract, ServerCatalogView)
  — defined in **Spec A rev 5 §4**; additive-only once Phase 3 lands. Everything
  downstream depends on these.
- Client + foundation (registry, policy plane, per-user creds, native transports,
  native outbound OAuth client, conformance harness, tracing, tool-poisoning
  defense): **Spec A rev 5**.
- Server face (edge inbound auth, aggregator/curated exposure, **A2A first-class**,
  shared session store): **Spec B rev 4**, consuming Spec A §4 contracts.
