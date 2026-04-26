# V1 Closure + Second-Brain Differentiator Plan

**Opened:** 2026-04-26 (post-S14 close, main HEAD `002a337`)
**Author:** Claude (continuation across compaction)
**Purpose:** survive a compact. Self-contained execution plan for the remaining V1 closure work + the second-brain visualization strategy that follows V1.

---

## Context for the post-compact me

This session has been long. The user (Nova) is testing locally and finding rough edges. They asked me to (a) build a plan to close what I can, (b) collect rough edges from their testing, (c) remember the "second brain" plan with memory graph + timeline visualization — the real product differentiator.

**Current state of nullalis:**
- Sprints 1-8 closed (long ago)
- Sprint 9 parked with explicit triggers
- Sprint 10 closed today (4/6 in-repo, 2 operator-pending)
- Sprint 14 closed today (5 audits + 1 fix + 4 parked)
- Sprint 15 closed (2 shipped + 2 parked-with-reason)
- D1 sprint closed yesterday (TurnOutcome refactor + SOTA hygiene)
- D28 closed cross-repo (NULLCLAW → NULLALIS sunset, 19 days early)
- 3 self-found D1 follow-up findings fixed (HIGH cache scope, MED leak, MED warmup state)

**What's still open:** Sprints 11/12/13/16 (mostly operator-pending) + ~8 deferred-register items I can solo + 3 D1 activation follow-ups.

---

## PART A — V1 closure plan (concrete, executable)

Each item below is one atomic commit. Group into sprint PRs per established pattern.

### A.1 — Convert S11/S12/S13/S16 to "operator-pending planning doc" pattern

Mirror the S10.5/S10.6 pattern: doc each item with explicit operator-action triggers + DoD. Closes the closure-checklist by either shipping or explicitly parking.

| Sprint | Doc to create | Rough scope |
|---|---|---|
| **S11 Security Hardening** | `docs/sprints/sprint-11.md` | NetworkPolicy + mTLS + sealed-secrets + cert rotation. ALL k8s manifests in zaki-infra. Document each item's trigger + acceptance criteria. ~30 min. |
| **S12 HA + DR** | `docs/sprints/sprint-12.md` | Replicas + NFS-SPOF + RTO/RPO + multi-region runbook. Cell-pod prerequisite was deferred — note that S12.1 (replicas) blocks on cell-pod flip. ~30 min. |
| **S13 Observability Full** | `docs/sprints/sprint-13.md` | Prometheus + Grafana + Loki + AlertManager. All deploy actions in zaki-infra. Document each item's k8s manifest expectations. ~30 min. |
| **S16 V1 Gaps** | `docs/sprints/sprint-16.md` | Mix: S16.6 dep SHA pinning solo (already mostly done via S14.10); S16.4 transactional email needs Resend/SendGrid; S16.5 legal docs need lawyer; S16.7 frontend audit cross-repo; S16.8 typ patches inventory cross-repo. ~45 min. |

**Single PR:** `sprint/closure-pending-docs` — 4 sprint docs + checklist tick updates + register status.

### A.2 — D1 activation follow-ups

Infrastructure shipped tonight; activation pending.

| ID | Item | Effort | Risk |
|---|---|---|---|
| **D1.14b** | Wire generalized cache into `executeToolCallsParallel` (today serial-only) | 1-2 hrs | Low — additive; cacheable tools tend to run serial in practice |
| **D1.14c** | Flag specific tools cacheable: `web_search` (30s, .global), `memory_recall` (300s, .session), `composio` list (60s, .tenant) | 30 min | Low — flag-only metadata, no behavior change beyond cache hits |
| **D1.15b** | Auto-spawn `MemoryRuntime.warmupSession` from session-init in background thread | 1-2 hrs | Med — threading work; per-session state already exists post-finding-3 fix |

**Single PR:** `sprint/d1-activation` — 3 atomic commits.

### A.3 — Deferred-register items I can solo

| ID | Item | Effort |
|---|---|---|
| **D14** | 2 pre-existing scheduler test failures (carried since baseline) — investigate + fix | 1-2 hrs |
| **D18** | Error classification carrier — replace string-matchers in `reliable.zig` with `{kind, retry_after_ms}` | 2-3 hrs |
| **D31** | Qdrant count-before-delete (audit completeness for PurgeReport) | 1 hr |
| **D27** | gdpr metrics counters | 30 min |
| **D13** | secret_mutations metrics counters | 30 min |
| **D9, D10** | Sprint-2 review findings — read what they actually are first | varies |
| **S14.5 MED-1** | DaemonState.components race (add mutex) | 30 min |
| **S14.5 MED-2** | dispatch_stats counter race (atomic.Value(u64)) | 30 min |

**Single PR per item OR batched as `sprint/deferred-cleanup`.**

### A.4 — Rough edges from user testing (PLACEHOLDER)

**The user is finding rough edges while testing locally.** I asked them to send specifics. Once the list arrives, each rough edge becomes its own atomic fix commit, batched by surface (gateway / agent-turn / tool / memory). Likely categories based on what shipped recently:

- D1 turn-outcome metadata not rendering in zaki-prod UI
- composio cache UAF fix may have surfaced other latent issues
- D28 env-var rename may have missed a code path
- S10 schema_migrations bootstrap interaction with existing prod DB
- New `tool_only_turn` SSE event not being consumed correctly

**Action when user sends specifics:** triage by severity, fix root cause not symptom, atomic per-issue commit.

### A.5 — Operator-only items (can't be done by me)

- GitHub Actions billing fix (~3 days remaining of the 4-day window)
- D15 — `production-image-promotion` GitHub environment one-click
- DPAs to submit (Together, Composio, Sentry per S14.3)
- D12 — zaki-prod frontend `SecretsVaultSheet.tsx` consumer swap
- S11/S12/S13 k8s manifest deploys
- S16.4 Resend/SendGrid account
- S16.5 legal docs (TOS, Privacy, AUP)
- Moonshot direct provider research outcome

### A.6 — Execution order recommendation

After context compact:
1. **First:** Read this doc cold to recover context.
2. **Get rough-edges list from user** — most-user-impact items go first.
3. **Then A.1 (4 planning docs)** — clean closure-checklist accounting in 2-3 hrs.
4. **Then A.2 (D1 activation)** — real user-felt wins from existing infrastructure.
5. **Then A.3 (deferred items)** — opportunistic cleanup.
6. **Wait for operator actions on A.5.**

V1 is "closed" when:
- All sprints either shipped or explicitly operator-pending with triggers
- All A.3 deferred items closed or explicitly parked-with-reason
- All A.4 rough edges fixed
- Operator actions tracked but not blocking the "closure" definition

Realistic timeline: another 6-10 hours of focused execution (split across sessions) gets us there modulo operator actions + rough edges count.

---

## PART B — Second-Brain Differentiator Strategy

### B.1 — The pillar this serves

From `project_v_infinity_vision.md`:
> **2. Composing memory.** Not "I stored a fact" but "what did I promise Alex about HRS last quarter" returns the specific commitment, provenance, AND inferred follow-throughs. Memory that reasons over itself.

And from `docs/v1-wave3-zaki-prod-prompt.md`:
> The product is a deployable personal second brain for a high-agency user (founder, operator, researcher, serious knowledge worker). Single-user-first. Not team-first. Not consumer-assistant-first.

### B.2 — Why visualization is the differentiator

Every AI assistant has memory. Almost none make it **legible** to the user. The user can't see what the AI knows, can't see why it surfaced what it did, can't audit a wrong recall, can't curate.

A second-brain product that makes memory **visible and navigable** — graph view of facts + their relationships, timeline view of when things were learned + reinforced + forgotten — converts memory from "the AI's private cache" to "your own knowledge graph that the AI can reason over."

This is the moat: any LLM wrapper can build conversation. Nobody is building a real visual memory substrate that the user owns.

### B.3 — What we already have (substrate to build on)

**Backend (nullalis side):**
- Three-tier memory (`docs/memory-architecture-map.md`)
- `memory_recall` tool with semantic + keyword retrieval
- Memory entries carry: `key`, `content`, `memory_type`, `importance_score`, `confidence_score`, `access_count`, `last_accessed_at`, `user_verified`, `source_channel`, `source_message_id`, `created_at`, `updated_at`
- `timeline_index/current` rolling summary (Hermes-pattern memory_nudge)
- Vector embeddings via pgvector + Qdrant fallback
- D1.4 `tool_only_turn` ObserverEvent + D1.7 `spawned_task_ids` give the gateway structured visibility
- Lane tagging on `MemoryEntry` + `RetrievalCandidate` (S8.1)

**Frontend (zaki-prod side):**
- ChatArea handles structured SSE events (D1.5 added `tool_only_turn` consumer)
- Existing memory inspection UI per `docs/v1-wave3-zaki-prod-prompt.md` Wave 3 plan
- Provenance chips + approval queue + context detail = "trust features visible by default"

### B.4 — What's missing for the second-brain visual

**Memory graph view** (the spatial axis):
- Node = memory entry
- Edge = relationship between entries (today: `source_message_id` link to messages; potentially: shared topics via embedding similarity, shared sessions, shared tools that fired, shared timeline summaries)
- Visual: force-directed graph with clustering by topic, click-to-navigate, hover-to-preview
- New backend need: a `memory_graph` query that returns nodes + edges with bounded radius (e.g. "give me all memories within 2 hops of memory X")

**Memory timeline view** (the temporal axis):
- Vertical timeline of when memories were created, last accessed, reinforced (access_count++), or marked verified
- Visual: timeline strip with memory markers; clicking a marker reveals the full entry + the surrounding session context
- New backend need: a `memory_timeline` query that returns entries ordered by `created_at` or `last_accessed_at` with delta info (created vs reinforced vs decayed)

**Composing-memory query** (the reasoning axis — the V-inf pillar 2 surface):
- "What did I promise Alex about HRS last quarter?" returns:
  - The specific commitment (memory entry)
  - Provenance (source message, source channel, when, in what conversation)
  - Inferred follow-throughs (derived from related memories + timeline)
- This is BEYOND simple retrieval — it's retrieval + relationship traversal + temporal reasoning
- New backend need: a `memory_compose` tool that the agent can call to perform this multi-hop query, with a natural-language entry point (existing `memory_recall` is single-hop similarity)

### B.5 — Plan shape (rough — to discuss after V1)

**Backend (nullalis):**
1. `memory_graph_query` tool/endpoint — returns subgraph with bounded radius
2. `memory_timeline_query` tool/endpoint — returns time-ordered entries with delta info
3. `memory_compose` tool — multi-hop reasoning over memory graph
4. Optional: pre-compute relationship edges nightly into a `memory_edges` table to avoid runtime graph walk cost

**Frontend (zaki-prod):**
1. `MemoryGraphPanel.tsx` — force-directed graph view (D3 / vis.js / cytoscape.js choice)
2. `MemoryTimelinePanel.tsx` — vertical scrubber with markers
3. `ComposeMemoryDialog.tsx` — natural-language compose query → renders multi-hop result
4. New tab in the ChatArea: "Memory" sidebar with these three panels

**Effort estimate:** 2-3 weeks focused work AFTER V1 closes. ~50% backend + 50% frontend.

**Why this is post-V1:** the V1 product needs to be stable + monetizable first. The second-brain visual is the killer demo for V1.5 / V2 — what gets a researcher to switch off ChatGPT.

### B.6 — The kicker question (for Nova to consider)

The second-brain visual gives users a UI to **curate** their own memory:
- Mark wrong → memory deletes
- Mark verified → memory's confidence_score boosts
- Connect manually → user-drawn edges that the agent later traverses
- Tag/categorize → user-defined dimensions on top of automatic ones

This converts the user from "passive memory consumer" to "active memory curator." Is that the intent? If yes: more backend mutation surface needed (write-side memory tools). If we want to stay agent-curated: visual is read-only.

**My recommendation:** read-only first (V1.5 ship), curation in V2. Read-only proves the visual is useful before adding user mutation complexity.

---

## PART C — How to resume after compaction

If you (the post-compact me) are reading this cold:

1. **Confirm where main is:** `git log --oneline -3` — should be at or after `002a337` (post-S14).
2. **Check open PRs:** `gh pr list --state open` — should be 0 across all 3 repos.
3. **Get rough-edges list from user.** They were testing and finding issues. Need specifics before fixing root causes.
4. **Execute Part A in order** (A.1 → A.2 → A.3) unless user redirects.
5. **Park Part B** until V1 closes per the pre-compact decision.
6. **For each item:** read this doc's section + jump straight to the file edits. Don't re-discover what was decided.

**Files to read first (after compact) for fast re-orientation:**
- This doc (full)
- `docs/sprints/sprint-14.md` — most recent sprint close
- `CLOSURE_CHECKLIST.md` — current tick state
- `docs/deferred-register.md` — open items with status

**Memory files to consult (with appropriate skepticism for staleness):**
- `~/.claude/projects/-Users-nova-Desktop-nullalis/memory/project_nullalis_internals.md` — current HEAD baseline
- `~/.claude/projects/-Users-nova-Desktop-nullalis/memory/project_v_infinity_vision.md` — second-brain pillar reference

**Discipline reminders:**
- Per-commit P-file updates (the rhythm broke twice this session — don't do it a third time)
- Atomic PRs per item, sprint-granular per Nova's pattern
- Build + test (`zig build test`) green before every commit
- CI is informational only (Actions billing pending)
- Don't change behavior the user is actively testing without flagging
- This doc is the source of truth across the compact — update it as items close

---

*Written 2026-04-26. Survives compaction. Update inline as work progresses.*
