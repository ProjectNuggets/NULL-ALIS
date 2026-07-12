# ZAKI BOT Product and Platform Plan — S-Tier Digital Twin First, Then Network and Marketplace

## Summary

This plan builds ZAKI BOT as a trusted, persistent digital twin product first, then expands it into a networked agent platform.

The strategy is deliberate:

1. **Win the core product first**
- one user
- one living agent
- one trusted memory graph
- one central conversation
- full operational usefulness

2. **Add safe network effects second**
- agent-to-agent access with explicit consent
- shareable personas
- memory inheritance via curated snapshots

3. **Add platform surfaces third**
- Agent-as-API
- marketplace
- certificates
- third-party embeddings into the ecosystem

This sequence matches the current codebase and avoids premature platform complexity before trust, state integrity, permissioning, and cross-channel behavior are production-safe.

## Decisions Locked

From the current repo state and your preferences, these are locked:

1. Product identity:
- `Nullalis = ZAKI BOT`
- dedicated fixed space in ZAKI
- one persistent main conversation per user

2. Storage architecture:
- **Postgres is canonical state**
- filesystem workspace remains first-class
- markdown memory remains live and synchronized

3. Default product wedge:
- **Digital Twin Core first**

4. Agent-to-agent policy:
- **explicit consent by default**

5. Memory inheritance model:
- **read-only curated snapshot first**
- not live shared memory in v1

6. Secret management model:
- agent may orchestrate secret updates
- backend remains security authority
- explicit confirmation required
- no plaintext secret reveal after save

---

## Product Vision

ZAKI BOT becomes:

1. **A chief-of-staff digital twin**
- remembers
- plans
- acts
- follows up
- works while user sleeps

2. **A trusted operating layer**
- channels
- jobs
- memory
- files
- integrations
- peripherals
- API

3. **A graph node in an agent ecosystem**
- can ask other agents
- can inherit curated expertise
- can publish callable expertise

---

## Product Tracks

## Track A — Digital Twin Core (Primary Wedge)

### Goal
Deliver the best persistent personal agent experience in the market.

### Core user promise
1. one central conversation
2. persistent memory that stays useful over months/years
3. proactive work and follow-up
4. integrated channels and tools
5. trusted identity and secrets

### Required capabilities
1. canonical main session per user
2. durable memory with markdown + Postgres sync
3. jobs, reminders, heartbeat, quiet hours
4. Telegram + app shared timeline
5. per-user config and secret vault
6. safe agent-managed integrations
7. scalable multitenant backend

### V1 user-facing features
1. `ZAKI BOT` fixed space
2. one persistent thread
3. onboarding in first conversation
4. Telegram connect
5. scheduled reminders/jobs
6. memory recall and curation
7. secret vault
8. proactive follow-up
9. workspace artifacts and files
10. strong web/tools/integration capabilities

---

## Track B — Agent Network Effect

### Goal
Let agents talk to agents, with trust and permissioning designed correctly from the start.

### V1.5 model
User A asks:
- `What did Sarah think about Q4?`

System behavior:
1. ZAKI BOT checks if Sarah granted access
2. routes a request to Sarah’s agent API
3. Sarah’s agent answers from her documented memory or explicit authored position
4. Sarah receives a notification/audit event

### Why this works
1. creates viral team loops
2. increases switching cost
3. turns each user into a graph node
4. creates organizational memory effects

### Required policy defaults
1. default = no access
2. access scopes:
- read summary only
- ask questions
- retrieve authored opinions
- no private memory access unless granted
3. consent artifacts:
- direct user grants
- org/team grants
- revocable and auditable

### Required architectural additions
1. agent identity registry
2. permission graph
3. signed cross-agent request envelope
4. scoped response policy
5. rate limits and abuse controls
6. audit log for every cross-agent query

---

## Track C — Persona Marketplace

### Goal
Turn ZAKI from “make one bot” into “subscribe to expertise.”

### Product model
1. users can publish personas
2. users can subscribe to personas
3. personas may be:
- public
- paid
- org-private
- invite-only

### Persona types
1. public expert persona
2. company knowledge persona
3. creator/coach persona
4. operational persona
5. historical/synthetic persona

### V1 marketplace rules
1. no fully autonomous public agents at first
2. personas are callable or subscribable overlays
3. every persona has:
- owner
- source provenance
- rights declaration
- model policy
- memory source policy

### Product constraints
1. explicit provenance is mandatory
2. generated or synthetic personas must be labeled
3. publishing flow requires rights and safety checks
4. persona overlays must not silently pollute a user’s private core memory

### Technical model
1. persona package = metadata + prompt/persona layer + optional memory snapshot + capability policy
2. persona subscription attaches as:
- advisory overlay
- alternate voice/expert mode
- callable subagent
3. persona state is isolated from user-private memory unless explicitly allowed

---

## Track D — Memory Inheritance

### Goal
Create a powerful emotional and knowledge continuity feature without unsafe or messy live-memory sharing.

### V1 model: Curated snapshot
A user can export:
1. selected memories
2. selected files
3. selected advice/identity/context
4. selected timelines or summaries

Recipient gets:
1. read-only inherited memory bundle
2. provenance of source
3. owner identity
4. timestamped transfer record

### Use cases
1. founder -> successor
2. parent -> child
3. expert -> student
4. advisor -> team
5. operator -> business continuity

### Important rules
1. inherited memory is not the origin agent’s live state
2. inherited memory must be reviewable before transfer
3. inherited memory can later be:
- attached as a reference library
- imported selectively
- forked in later versions

### Future path
V2 may add:
1. forked memory inheritance
2. live shared knowledge streams
3. expiring or renewable access

---

## Track E — Universal Remote

### Goal
Position ZAKI BOT as the one agent controlling the user’s life/work stack.

### Integrations to prioritize
1. Telegram
2. Email
3. Calendar
4. Browser/web
5. Code/runtime/MCP
6. Files and local workspace
7. Smart home/peripherals
8. CRM/project systems
9. finance read-only first

### Product framing
- not a chatbot
- not only an assistant
- a chief of staff and operations layer

### Execution policy
1. read-only by default for sensitive domains
2. approval required for destructive or financial actions
3. configurable autonomy by domain
4. action history and rollback/audit where possible

---

## Track F — Agent Certificates

### Goal
Create credibility and distribution.

### Certificate types
1. domain capability
- legal research
- PM
- support
- coding
- medical triage, not diagnosis

2. compliance mode
- HIPAA-aware
- enterprise-safe
- org policy compliant

3. benchmark competence
- scenario tests
- repeatable eval suites

### V1 implementation
1. internal certification spec
2. signed badge metadata
3. display in profile and marketplace
4. no unverifiable “marketing only” badges

### Technical model
1. certification record references:
- test suite version
- persona version
- model/provider profile
- tool policy profile
- score threshold

---

## Track G — Agent-as-API

### Goal
Turn ZAKI BOT into callable infrastructure.

### Product model
Each user can expose:
1. private API endpoint
2. org-private API endpoint
3. public API persona endpoint

### V1 endpoint model
Example:
- `POST /api/v1/agents/{agent_id}/chat`
- `POST /api/v1/agents/{agent_id}/actions/...`
- `POST /api/v1/agents/{agent_id}/query_memory`

### Policies
1. endpoint access token or OAuth
2. rate-limited
3. auditable
4. per-scope permissions
5. can be disabled by owner

### Why it matters
1. turns agents into infrastructure
2. enables developer ecosystem
3. increases viral integration surface

---

## Suggested Additional Features

These fit the digital twin direction and current architecture.

### 1. Trust Graph
A visible relationship map:
- self
- advisors
- team members
- inherited sources
- personas
- external agents

Why:
- makes permissions and provenance understandable

### 2. Decision Journal
The agent keeps structured decision records:
- what was decided
- why
- which memories/facts were used
- what changed

Why:
- improves trust
- helps with memory hygiene
- creates explainability

### 3. Simulation Mode
Before action, user can ask:
- `simulate what you'd do this week`
- `simulate how you'd respond to this email`

Why:
- builds trust before autonomy is increased

### 4. Relationship Modes
Different personality/interaction layers:
- chief of staff
- teacher
- therapist-like reflective coach
- operator
- executive assistant

Why:
- makes the same core digital twin adaptable without fragmenting identity

### 5. Private Playbooks
Users or orgs can define reusable execution playbooks:
- sales follow-up
- incident response
- recruiting pipeline
- travel planning

Why:
- makes autonomy more predictable and scalable

---

## Architecture Plan

## 1. Canonical state model

Use current direction as the foundation:

### Canonical state in Postgres
Schema:
- `zaki_bot`

Tables:
1. `users`
2. `user_config`
3. `user_secrets`
4. `sessions`
5. `messages`
6. `memories`
7. `memory_events`
8. `channel_state`
9. `telegram_updates`
10. `heartbeat`
11. `jobs`
12. `job_runs`
13. `tasks`

### Workspace layer on disk
Remain on RWX filesystem:
1. `BOOTSTRAP.md`
2. `IDENTITY.md`
3. `USER.md`
4. `SOUL.md`
5. `HEARTBEAT.md`
6. `MEMORY.md`
7. `memory/YYYY-MM-DD.md`
8. artifacts and files

### Rule
Postgres = runtime truth  
workspace files = readable/editable user-visible state

---

## 2. Memory architecture

### V1 target
1. canonical durable memory in Postgres
2. markdown memory remains live
3. bidirectional sync with filtering and audit
4. memory retrieval prioritizes canonical store
5. file edits are ingested on sync pass

### Future memory improvements
1. better long-horizon summarization
2. memory aging and promotion
3. semantic retrieval with pgvector
4. relationship-aware memory graph
5. inherited memory provenance tags
6. persona memory overlays
7. user-confirmed core memories

### Do not do
1. do not merge ZAKI BOT memory into Spaces memory
2. do not remove markdown memory
3. do not make workspace memory read-only

---

## 3. Secret architecture

### Global deployment secrets
Remain platform-only:
1. OpenRouter key
2. Brave key
3. internal service tokens
4. encryption master keys

### Per-user secrets
Encrypted in canonical store:
1. Telegram bot token
2. email/calendar connector tokens
3. future OAuth/app credentials

### Secret mutation policy
1. agent can orchestrate updates
2. backend is authority
3. UI confirmation required
4. no plaintext reveal after save
5. audit trail on every mutation

---

## 4. Scheduler and autonomy architecture

### Source of truth
- `zaki_bot.jobs`

### Job kinds
1. `delivery`
2. `agent`
3. `integration`
4. `shell` internal/advanced only

### Execution model
1. Postgres-backed due-job query
2. lease-based claiming
3. `job_runs` history
4. per-user context execution
5. channel-aware delivery
6. quiet hours and rate limits
7. retry budget and capped backoff

### Core autonomy controls
1. quiet hours
2. proactive frequency
3. domain-level approval policies
4. notification routing
5. safe defaults for action categories

---

## 5. Cross-agent architecture

### New schema additions
Add:
1. `agent_profiles`
2. `agent_permissions`
3. `agent_relationships`
4. `agent_requests`
5. `agent_access_events`

### Core flow
1. caller agent submits scoped request
2. target access policy evaluated
3. request enters target agent request queue
4. target agent returns:
- direct answer
- curated summary
- denial
- async later answer
5. owner gets audit trail and notifications

### Request envelope
Fields:
1. `request_id`
2. `caller_user_id`
3. `target_user_id`
4. `scope`
5. `intent`
6. `question`
7. `requester_context`
8. `consent_basis`
9. `created_at`

### Response envelope
Fields:
1. `request_id`
2. `status`
3. `answer`
4. `citations`
5. `visibility_level`
6. `generated_at`

---

## 6. Marketplace architecture

### New schema additions
1. `persona_packages`
2. `persona_versions`
3. `persona_subscriptions`
4. `persona_rights`
5. `persona_certifications`
6. `persona_usage_events`

### Persona package contents
1. metadata
2. display information
3. rights/provenance
4. prompt/persona layer
5. optional memory snapshot
6. tool policy profile
7. pricing/visibility rules

### Subscription modes
1. advisory overlay
2. callable expert agent
3. org shared expert
4. private invite-only expert

---

## 7. Memory inheritance architecture

### New schema additions
1. `memory_exports`
2. `memory_export_items`
3. `memory_imports`
4. `memory_inheritance_policies`

### V1 export format
1. selected memories
2. selected files
3. selected summaries
4. selected identity or advice context
5. immutable snapshot metadata

### Required provenance
1. origin user
2. export timestamp
3. content manifest
4. version
5. recipient
6. permission terms

---

## 8. Agent-as-API architecture

### New schema additions
1. `agent_api_keys`
2. `agent_api_scopes`
3. `agent_api_usage`
4. `agent_endpoints`

### API scopes
1. chat
2. query memory
3. ask persona
4. trigger workflow
5. read status
6. no secret mutation by external API in v1

### V1 policy
1. private or org-private first
2. public endpoints later
3. strict rate limits
4. full audit trail

---

## Public APIs / Interfaces / Type Changes

## Nullclaw backend additions

### Secret orchestration
1. `GET /api/v1/users/{id}/secrets/{key}`
- returns metadata only

2. `POST /api/v1/users/{id}/secrets/{key}/prepare`
- creates confirmation token for mutation

3. `PUT /api/v1/users/{id}/secrets/{key}`
- requires confirmation token

4. `DELETE /api/v1/users/{id}/secrets/{key}`
- requires confirmation token

### Cross-agent
1. `POST /api/v1/agents/{id}/requests`
2. `GET /api/v1/agents/{id}/requests`
3. `POST /api/v1/agents/{id}/requests/{request_id}/respond`
4. `GET /api/v1/agents/{id}/permissions`
5. `PUT /api/v1/agents/{id}/permissions`

### Marketplace
1. `POST /api/v1/personas`
2. `GET /api/v1/personas`
3. `GET /api/v1/personas/{id}`
4. `POST /api/v1/personas/{id}/subscribe`
5. `DELETE /api/v1/personas/{id}/subscribe`

### Memory inheritance
1. `POST /api/v1/users/{id}/memory/exports`
2. `GET /api/v1/users/{id}/memory/exports`
3. `POST /api/v1/users/{id}/memory/imports`

### Agent-as-API
1. `POST /api/v1/agents/{id}/api_keys`
2. `DELETE /api/v1/agents/{id}/api_keys/{key_id}`
3. `POST /api/v1/agents/{id}/chat`
4. `POST /api/v1/agents/{id}/query_memory`

## New core types
1. `SecretMetadata`
2. `SecretMutationRequest`
3. `AgentPermissionPolicy`
4. `CrossAgentRequest`
5. `CrossAgentResponse`
6. `PersonaPackage`
7. `MemoryExportManifest`
8. `AgentApiScope`
9. `CertificationRecord`

---

## Implementation Sequence

## Phase 1 — Trustworthy Digital Twin Core
Priority: immediate

### Objectives
1. finish canonical Postgres state path
2. stabilize cross-channel behavior
3. stabilize secrets and autonomy policies
4. complete ZAKI BOT product loop

### Deliverables
1. secret confirmation model
2. vault metadata API
3. Telegram connect UX via backend
4. production-ready config split
5. sustained memory correctness
6. stable jobs/autonomy controls
7. local and staging validation

### Acceptance
1. user can onboard, chat, connect Telegram, set secrets, schedule jobs
2. app and Telegram share one timeline
3. memory persists correctly over time
4. agent can manage user secrets with confirmation

---

## Phase 2 — Relationship and Trust Graph
Priority: next

### Objectives
1. represent people, personas, inherited sources, and permissions explicitly
2. prepare for network effects safely

### Deliverables
1. trust graph data model
2. relationship UI
3. permission grant flows
4. audit visibility
5. notification model for agent-to-agent access

### Acceptance
1. users can explicitly grant another agent scoped access
2. all access is visible and revocable
3. no unauthorized cross-agent queries succeed

---

## Phase 3 — Agent Network Effect
Priority: after trust graph

### Objectives
1. allow scoped inter-agent questions
2. create viral team loops

### Deliverables
1. cross-agent request APIs
2. cross-agent routing and response policy
3. notifications and audit
4. org/team permission defaults configuration
5. UX for “ask another agent”

### Acceptance
1. agent A can query agent B only with permission
2. target owner sees audit and notification
3. answers remain within granted scope

---

## Phase 4 — Persona Marketplace
Priority: after network basics

### Objectives
1. let users subscribe to expertise
2. enable public/private persona packages

### Deliverables
1. persona package schema
2. persona publishing flow
3. subscription flow
4. provenance and rights checks
5. marketplace listing/search

### Acceptance
1. users can discover and subscribe to personas
2. persona overlays do not corrupt core user memory
3. provenance and rights are explicit

---

## Phase 5 — Memory Inheritance
Priority: after marketplace primitives

### Objectives
1. allow transfer of curated knowledge bundles
2. create emotional and practical continuity

### Deliverables
1. snapshot export/import flow
2. bundle preview and review
3. provenance/audit
4. read-only inherited memory layer

### Acceptance
1. owner can export selected memory bundle
2. recipient can use inherited bundle
3. inherited content remains attributable and immutable

---

## Phase 6 — Universal Remote Expansion
Priority: ongoing

### Objectives
1. broaden useful integrations
2. increase action coverage safely

### Deliverables
1. email read/draft/send with approval
2. calendar scheduling
3. MCP and workflow connectors
4. smart-home/peripheral controls
5. domain-specific autonomy controls

### Acceptance
1. agent can act across multiple domains safely
2. approvals are enforced per policy
3. every action is auditable

---

## Phase 7 — Agent Certificates
Priority: after marketplace maturity

### Objectives
1. add credibility and enterprise trust

### Deliverables
1. eval framework
2. signed certification records
3. profile/marketplace display
4. versioned competency reports

### Acceptance
1. certifications are reproducible and versioned
2. users can inspect what the badge means
3. badges are not pure marketing artifacts

---

## Phase 8 — Agent-as-API
Priority: platform stage

### Objectives
1. make agents programmable infrastructure
2. enable third-party embedding and ecosystem growth

### Deliverables
1. API key management
2. scoped endpoint surface
3. org/public visibility controls
4. billing/usage tracking hooks

### Acceptance
1. agent endpoints are callable with scoped auth
2. usage is metered and auditable
3. unsafe scopes are not exposed by default

---

## ZAKI-PROD Work Needed

## Backend
1. proxy new secret confirmation endpoints
2. proxy future cross-agent and persona APIs
3. enforce caller identity and ownership
4. issue confirmation tokens
5. attach audit and request IDs

## Frontend
1. fixed `ZAKI BOT` space remains central
2. add vault metadata UI
3. add confirmation sheets for secret mutations
4. add relationship/trust graph views
5. add “Connect Telegram” flow through proper API
6. later add marketplace, inheritance, and network UI

---

## Stability and Scalability Requirements

## State
1. Postgres canonical state
2. pooled or per-worker-safe DB connections
3. no global file state for tenant-critical operations

## Scheduler
1. lease-based jobs
2. indexed due-job queries
3. bounded retries and backoff

## Memory
1. canonical durable state in Postgres
2. markdown sync with filtering
3. future vector retrieval through pgvector

## Networked features
1. explicit permission checks
2. rate limits
3. audit logging
4. notification and revocation support

## Secrets
1. encrypted at rest
2. metadata-only reads
3. confirmation for writes/deletes
4. audit every mutation

---

## Test Cases and Scenarios

## Digital Twin Core
1. onboarding completes once and persists
2. app + Telegram share the same timeline
3. memory writes persist to canonical store and markdown
4. manual markdown edit syncs back correctly
5. secret set/replace/delete requires confirmation
6. jobs execute with quiet hours and retry policies

## Agent Network
1. unauthorized cross-agent query is denied
2. authorized scoped query succeeds
3. target owner gets audit event
4. revoked permission immediately blocks future calls

## Marketplace
1. persona publish validates rights metadata
2. subscription attaches persona overlay safely
3. unsubscribe removes overlay cleanly
4. persona memory cannot silently mutate private core memory

## Memory Inheritance
1. export bundle contains only selected items
2. import produces read-only inherited layer
3. provenance metadata survives
4. no live linkage exists in v1 snapshot mode

## Universal Remote
1. email/calendar actions obey approval policy
2. MCP actions honor domain policy
3. sensitive actions are audited

## Certificates
1. certification record references exact persona/model/policy version
2. badge display matches underlying eval record

## Agent-as-API
1. private endpoint requires valid scoped key
2. scope violation is rejected
3. usage and rate limits are recorded

---

## Assumptions and Defaults Chosen

1. `ZAKI BOT` remains the primary product identity
2. digital twin core is the first wedge
3. explicit consent is default for cross-agent access
4. memory inheritance starts as read-only snapshot
5. Postgres is canonical state in production
6. markdown memory remains live and synchronized
7. user secrets are agent-manageable with confirmation
8. global deployment secrets are never exposed to agent workflows
9. marketplace starts with packaged personas, not fully autonomous public bots
10. Agent-as-API starts private/org-private before public endpoints
11. shell jobs remain advanced/internal, not default user automation

---

## Success Criteria

This plan is successful when:

1. ZAKI BOT is the best-in-class personal digital twin product before network expansion
2. the product is trustworthy enough for users to store life/work memory and secrets
3. the architecture supports months/years of memory growth without degrading usability
4. cross-agent and marketplace features are added on top of explicit trust and provenance, not hacks
5. ZAKI BOT becomes both:
- an emotionally sticky digital twin
- a scalable agent platform

