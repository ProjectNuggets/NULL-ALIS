# Project TrustMesh

Status: strategy document  
Date: 2026-03-25  
Position: next major program after Digital Twin Core hardening

## Summary

Project TrustMesh is the nullALIS strategy for moving from a single persistent
digital twin to a safe, auditable, monetizable **trusted delegation network**.

This program is aligned to:
- `/Users/nova/Downloads/PLAN.md`: digital twin first, network effects second,
  platform surfaces third
- `docs/plan-v02.md`: current Phase 1 remains reliability, multitenant safety,
  integration quality, and monetization foundation

TrustMesh is therefore:
1. a **Phase 2 program**
2. same-tenant first
3. B2B-first in commercial sequencing
4. dual-track in long-term product design
5. explicitly not LDAP-first, federation-first, or marketplace-first

Core framing:
- not agent chat
- not open autonomous swarms
- not public federation
- **trusted delegation between explicitly identified agents under policy**

## Product Thesis

nullALIS should eventually support:
1. one user with multiple specialist agents under one coherent twin
2. one team or org with role-specific agents that can safely delegate work
3. durable, replayable, auditable inter-agent task handoff
4. policy-based trust, revocation, and budget control
5. later expansion into trusted external agents, curated memory inheritance,
   marketplace overlays, and callable agent APIs

What TrustMesh must preserve:
1. one trusted central twin per user
2. strict tenant isolation
3. deterministic routing and session semantics
4. explicit provenance for delegated work
5. business packaging based on outcomes, not framework complexity

## Strategic Position

### Why this matters

From the broader product plan, the network effect comes **after** users trust
the core digital twin. That means the correct sequence is:
1. win Digital Twin Core
2. add safe trusted delegation
3. add external network and marketplace surfaces later

### What we are building

TrustMesh is the combination of:
1. an agent identity plane
2. a trust and authorization plane
3. a durable mailbox/task plane
4. an orchestration policy plane
5. observability, audit, and support tooling

### What we are not building first

TrustMesh v1 explicitly excludes:
1. cross-user trusted-friend delegation
2. cross-tenant federation
3. LDAP as runtime source of truth
4. public agent discovery
5. open marketplace behavior
6. live inherited memory sharing

## Architecture Principles

1. Identity is separate from communication.
2. Communication is separate from orchestration.
3. Orchestration is separate from observability.
4. Trust is explicit, scoped, revocable, and auditable.
5. Same-tenant first; cross-user and cross-tenant later.
6. Additive architecture first; do not break current twin/session semantics.
7. Durable structured envelopes first; no free-form agent-chat primitive.
8. Preserve tenant/session-key isolation and fail-closed policy defaults.
9. Reuse strong external patterns without importing their full complexity.
10. Every phase must be independently testable and rollbackable.

## External Systems To Learn From

Use these as pattern sources, not architecture lock-in:

### `nulltickets`
Borrow:
1. durable task/envelope lifecycle
2. claim/lease/retry/dead-letter
3. artifact/result tracking
4. event log as source of truth

### `nullboiler`
Borrow:
1. separation of tracker/orchestrator/executor
2. policy engine boundaries
3. capability-based routing
4. explicit orchestration states

### `nullwatch`
Borrow:
1. traces and chain visibility
2. auditability as first-class design
3. debugging and evaluation mindset

### `lldap`
Borrow:
1. identity modeling discipline
2. principal/group thinking

Do not borrow:
1. LDAP-first runtime architecture
2. directory as communication plane

## Phase Plan

## Phase 0 — Strategy And Contract Freeze

Goal:
Lock the product and architecture contract before runtime implementation.

Deliverables:
1. strategy doc
2. trust model doc
3. technical contract doc
4. rollout and gate doc
5. business packaging note

Locked decisions:
1. v1 = same-tenant only
2. B2B-first commercialization
3. B2C trusted-social flows designed now, shipped later
4. no LDAP runtime dependency
5. no public federation in v1

## Phase 1 — Agent Identity Plane

Goal:
Turn `agent_id` into a first-class durable identity model.

Minimum fields:
1. `agent_id`
2. `tenant_id`
3. `owner_principal_type`
4. `owner_principal_id`
5. `agent_type`
6. `display_name`
7. `description`
8. `capabilities`
9. `status`
10. `visibility`
11. `origin`
12. timestamps

Rules:
1. every delegatable agent has a stable ID
2. IDs are immutable after creation
3. IDs are unique within tenant
4. existing routing/session-key behavior must continue to work

## Phase 2 — Trust And Authorization Plane

Goal:
Define who may delegate to whom, for which capability, under what constraints.

Required policy checks:
1. same tenant
2. trust edge exists
3. capability allowed
4. source/target status valid
5. budget available
6. hop count below max
7. timeout window available

Required denial classes:
1. `cross_tenant_forbidden`
2. `trust_missing`
3. `capability_forbidden`
4. `target_unavailable`
5. `budget_exhausted`
6. `hop_limit_reached`
7. `delegation_disabled`

## Phase 3 — Durable Mailbox / Task Plane

Goal:
Replace ad hoc delegation with a structured, durable envelope system.

Required objects:
1. `agent_envelopes`
2. `agent_tasks`
3. `agent_task_events`
4. optional `agent_artifacts`
5. optional `agent_dlq`

Required states:
1. queued
2. claimed
3. running
4. completed
5. failed
6. timed_out
7. dead_lettered
8. canceled

Required worker semantics:
1. claim with lease
2. renew lease
3. bounded retry
4. deterministic dead-letter path
5. dedupe by correlation/idempotency key

## Phase 4 — Orchestration Policy Plane

Goal:
Separate “who can talk” from “how work gets routed.”

Responsibilities:
1. capability-based routing
2. timeout and retry policy
3. fallback target selection
4. escalation policy
5. cost/budget enforcement
6. hop-limit enforcement

Important rule:
`delegate` and `spawn` should evolve into adapters over this plane rather than
remaining the final architecture.

## Phase 5 — Safety, Privacy, And Abuse Controls

Goal:
Make the system safe enough for real use before any external or social
expansion.

Required controls:
1. same-tenant hard enforcement
2. per-capability allowlists
3. per-agent action budgets
4. rate limits
5. anti-loop protections
6. secret isolation
7. provenance on every delegated result
8. owner-visible audit trail

Deferred to later consumer/social phase:
1. trust-request flow
2. friend-to-friend trusted delegation
3. social abuse handling
4. blocked-contact semantics

## Phase 6 — Observability And Operator Surfaces

Goal:
Make delegation operable and commercially measurable.

Required metrics:
1. envelopes created/claimed/completed/failed
2. lease timeouts
3. retry counts
4. dead-letter counts
5. trust denials by reason
6. capability denials by reason
7. delegation depth
8. queue depth and latency
9. budget exhaustion counts

Required diagnostics:
1. effective trust policy
2. recent delegation chain
3. active leases
4. dead-letter inspection
5. per-agent status/backlog

## Phase 7 — Product Surfaces

### B2B v1

Ship:
1. specialist agents inside one tenant or org
2. controlled delegation
3. visible provenance
4. audit/reporting surfaces
5. plan-based limits

### B2C v1

Ship:
1. one user, multiple owned agents
2. planner/researcher/helper patterns
3. unified twin experience
4. no external trust graph yet

### B2C v2

Later:
1. trusted external/social delegation
2. scoped permissions
3. consent and revocation
4. explicit notification and disclosure

## Commercial Position

### Before TrustMesh
nullALIS competes as:
1. persistent digital twin
2. proactive agent runtime
3. multichannel memory system
4. secure-ish multitenant execution substrate

### After TrustMesh v1
nullALIS competes as:
1. trusted delegation runtime
2. specialist-agent orchestration product
3. auditable AI workforce substrate inside a tenant
4. stronger B2B chief-of-staff operating system

### Packaging guidance
Pro:
1. multiple owned specialist agents
2. delegation quotas
3. richer proactive workflows

Team:
1. shared service agents
2. trust policy templates
3. audit and usage views
4. org controls

Enterprise later:
1. external directory sync
2. advanced retention/compliance
3. federation controls
4. dedicated trust modules

## Existing nullALIS Primitives To Evolve

Current code to evolve:
1. `src/tools/delegate.zig`
2. `src/tools/spawn.zig`
3. `src/subagent.zig`
4. `src/agent_routing.zig`

Migration rule:
1. keep current primitives working
2. refactor them onto the new identity/trust/orchestration layers
3. preserve twin behavior while migration gates remain active

## Multi-Agent Delivery Workstreams

This program is parallelizable.

### Workstream A — Strategy And Specs
1. strategy doc
2. trust model
3. envelope/task contract
4. rollout gates
5. business packaging note

### Workstream B — Identity And Trust
1. agent registry schema
2. trust edge schema
3. policy evaluator
4. revocation model
5. capability model

### Workstream C — Task Plane
1. durable envelope/task schema
2. lease/retry/dead-letter runtime
3. idempotency and artifact support
4. migration path from `spawn`/`delegate`

### Workstream D — Orchestration
1. routing and capability selection
2. depth/budget policy
3. target resolution
4. fallback/escalation rules

### Workstream E — Observability And Ops
1. metrics
2. traces
3. diagnostics
4. operator tools
5. support playbooks

### Workstream F — Product Surface
1. B2B specialist-agent UX
2. B2C owned-agent UX
3. provenance presentation
4. audit/usage pages
5. later trusted-social design docs only

Dependency rules:
1. no product rollout before identity + trust + mailbox + observability exist
2. no external trust before abuse controls exist
3. no public API exposure before operator tooling exists

## Test And Rollout Gates

### Required tests
1. ID normalization and uniqueness
2. trust decision engine
3. capability scope checks
4. task lifecycle and lease behavior
5. same-tenant delegation success
6. cross-tenant denial
7. provenance correctness
8. no secret or memory leakage across delegated work
9. no delegation loops
10. mailbox throughput and latency under concurrency

### Rollout gates
1. docs/spec only
2. hidden internal runtime behind flag
3. operator-only same-tenant service-agent testing
4. owned-specialist-agents for one user
5. B2B controlled beta
6. broader same-tenant rollout
7. later trusted-external design review

### Stop conditions
1. ambiguous trust decisions
2. tenant leakage
3. audit trail gaps
4. unbounded queue growth
5. recurring lease orphaning
6. unexplained failures in diagnostics/support paths

## Final Position

TrustMesh is the right next strategic program for nullALIS, but only in the
order locked by the broader vision:

1. Digital Twin Core first
2. trusted delegation second
3. marketplace, external trust, and public platform surfaces later

That sequencing preserves both:
1. product trust
2. engineering discipline

and gives nullALIS the best path to becoming an S-tier digital twin platform
instead of an overextended agent framework.
