# Graph + Memory ecosystem research — consolidated reference

**Date:** 2026-04-30
**Purpose:** single source of truth on every graph-memory / second-brain repo evaluated for nullalis. Captures verdicts so future-us doesn't re-evaluate.
**Owners:** Nova + this Claude session

---

## Key principle

We are NOT building a graph database. We are building a **graph-shaped view + tool surface over Postgres** with bi-temporal edges. The repos below inform that view, not replace our stack.

License rule:
- **Apache / MIT / BSD** — green to vendor or borrow
- **AGPL** — read-only inspiration (would force chatzaki.com source open)
- **BSL** — read-only (forbids competing managed service)
- **Proprietary** — skip

---

## Adopted for V1.5 (ships 2026-05-05)

### Graphiti — bi-temporal model
**Repo:** [getzep/graphiti](https://github.com/getzep/graphiti) · Apache-2.0 · 10k+ stars · very active
**Pattern:** every memory edge stores `valid_at` (when fact was true in the world) AND `created_at` (when ingested). Corrections invalidate via `valid_to=now` rather than mutate. Both old + new edges stay; retrieval filters by validity.
**Use:** add nullable `valid_to: ?i64` to memory entries in V1.5 schema. V1.5 leaves it null (always-valid). V1.6 correction classifier populates it. No migration cost.
**Status:** captured in `docs/v1.5-design-kickoff.md` Addendum.

### Supermemory `packages/memory-graph` — graph view
**Repo:** [supermemoryai/supermemory](https://github.com/supermemoryai/supermemory) · MIT (package level) · 22k stars · active today
**Pattern:** hand-rolled canvas renderer + d3-force layout + `version-chain.ts` for memory evolution visualization. Zero backend coupling — feed it `{nodes, edges}` and it renders.
**Use:** vendor the package directly into zaki-prod for `/brain` graph view. Write a thin adapter from our `/brain/graph` Postgres response → their type contract. **Saves Codex 2-3 days of from-scratch graph view work.**
**Status:** locked in as primary V1.5 graph renderer; replaces earlier cosmos.gl recommendation.

### Mem0 classifier namespace reserve
**Repo:** [mem0ai/mem0](https://github.com/mem0ai/mem0) · Apache-2.0 · 30k stars · very active
**Pattern:** `ADD / UPDATE / DELETE / NONE` decision classifier — when new info arrives, LLM classifies and the system writes accordingly. Missing primitive between "log everything" and "compact everything."
**Use:** reserve `event_kind` + `decision_type` columns on V1.5 traversal-event log table. V1.5 emits only "traversal"; V1.6 classifier emits "memory_decision" rows. Avoids migration when classifier ships.
**Status:** captured in `docs/v1.5-design-kickoff.md` Addendum.

### OpenDataLoader — PDF parsing (queued)
**Repo:** [opendataloader-project/opendataloader-pdf](https://github.com/opendataloader-project/opendataloader-pdf) · Apache-2.0 · Java
**Pattern:** PDF → structured Markdown/JSON/HTML with bounding boxes. 0.907 accuracy benchmark. Solves "user sent document, agent later said I don't have it."
**Use:** spawn as subprocess (same pattern as MCP). Ingest output flows into memory store as structured chunks. ~1 day integration when PDFs become a real bottleneck.
**Status:** queued — adopt candidate per `reference_repo_scan_2026_04_20`. Not blocking V1.5.

---

## Bookmarked for V1.6 (ships ~6 weeks post-V1.5)

### Letta — agent self-edits memory
**Repo:** [letta-ai/letta](https://github.com/letta-ai/letta) · Apache-2.0 · 17k stars · very active
**Pattern:** memory-edit operations exposed as first-class agent tools (`core_memory_replace`, `archival_memory_insert`). Agent edits memory inline during reasoning, no separate reflection pass.
**Use:** V1.6 self-improvement loop — when user says "no, prefer X," agent calls a memory tool inline. Pair with Mem0's classifier (Letta = inferred-fact path; classifier = user-feedback path).

### MemOS — explicit user-correction API
**Repo:** [MemTensor/MemOS](https://github.com/MemTensor/MemOS) · Apache-2.0 · active 2026
**Pattern:** `refine_memory(memory_id, natural_language_feedback)` API for explicit corrections. Cleaner than Letta when the user is the explicit source of truth.
**Use:** V1.6 — user-facing "this is wrong, fix it" surface in MemoryViewer. Posts to a new endpoint that internally calls compose-memory + valid_to update.

### Self-RAG — reflection tokens
**Repo:** [selfrag.github.io](https://selfrag.github.io/) · MIT (research code)
**Pattern:** `[Retrieve]` / `[IsRel]` / `[IsSup]` / `[IsUse]` inline-token critique. Model emits, runtime acts.
**Use:** V1.6 — cheapest way to add self-improvement signals without restructuring agent loop. Post-classifier upgrade.

### EvoAgentX — workflow evolution
**Repo:** [EvoAgentX/EvoAgentX](https://github.com/EvoAgentX/EvoAgentX) · MIT · active 2026
**Pattern:** workflows as mutable artifacts the agent improves over time. Adjacent to OpenSpace.
**Use:** V1.6+ — "agent's prompt/tool-policy is data, not code." Corrections edit policy directly.

### Memgraph — Cypher DSL pattern
**Repo:** [memgraph/memgraph](https://github.com/memgraph/memgraph) · **BSL 1.1** ⚠️ · active today
**Pattern:** Cypher-over-property-graph mental model. `(node)-[edge]->(node)` query DSL. MAGE module structure for named graph procedures.
**Use:** V1.6 — read-only inspiration. Reimplement minimal MATCH-style DSL in Zig over Postgres for graph queries. **Do NOT vendor (BSL forbids competing managed service).** Skim their `query/procedure/` directory for procedure-registration shape.

### Kyutai delayed-streams-modeling — voice TTS (deferred per Nova)
**Repo:** [kyutai-labs/delayed-streams-modeling](https://github.com/kyutai-labs/delayed-streams-modeling) · MIT · active March 2026
**Pattern:** 100M-param TTS, runs on CPU in real time, no GPU dependency.
**Use:** V1.6 voice candidate (Nova has separate ideas; deferred to that discussion).

### gbrain — memory architecture confirmation
**Repo:** [garrytan/gbrain](https://github.com/garrytan/gbrain) · MIT · TypeScript
**Status:** Mostly confirms nullalis's direction (markdown canonical + DB as index, RRF hybrid retrieval, compiled-truth-vs-append-only-evidence split). Three patterns for V-infinity:
- Skill conformance standard (SKILL.md + tests + evals + resolver triggers)
- Minion orchestrator with parent-child DAG
- Classifier quality metrics over time (`gbrain doctor`)

### PageIndex — doc retrieval
**Repo:** VectifyAI/PageIndex · TBD license
**Pattern:** "Reasoning-based" doc retrieval via hierarchical tree, not vector. 98.7% on financial docs.
**Use:** Watch-adopt after Karpathy wiki Phase 1 lands. Complements pgvector/RRF retrieval.

---

## Bookmarked for V2

### GitNexus — code knowledge graph
**Repo:** [abhigyanpatwari/GitNexus](https://github.com/abhigyanpatwari/GitNexus) · TBD license
**Pattern:** code-as-graph for AI coding agents.
**Use:** V2 if/when nullalis adds a coding sub-agent. Not V1.5 priority — nullalis-as-personal-assistant doesn't live in coding workload.

### VibeVoice — TTS+ASR
**Repo:** [microsoft/VibeVoice](https://github.com/microsoft/VibeVoice) · MIT · Python/ML
**Use:** V2 voice — heavier ML stack than Kyutai, requires GPU. Bookmark for when GPU infra is available.

### Qwen3-TTS
**Repo:** [QwenLM/Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) · Apache-2.0
**Pattern:** 97ms TTFA, 3-second voice cloning, dual-track (acoustic + prosody parallel). Higher quality, GPU-required.
**Use:** V2 voice if/when we have GPU infra and want premium voice quality.

### future-agi — eval + simulation harness
**Repo:** [future-agi/future-agi](https://github.com/future-agi/future-agi) · Apache-2.0 · active
**Pattern:** end-to-end agent observability — tracing, evals, simulations, self-hostable.
**Use:** V2 hardening — what our `.spike/` autoresearch harness wants to grow into for regression-testing.

### Kimi K2.6 — horizontal sub-agent scheduling
**Repo:** [moonshotai/Kimi-K2.6](https://huggingface.co/moonshotai/Kimi-K2.6) · Modified MIT
**Pattern:** trillion-param MoE, 300 sub-agents executing 4,000 coordinated steps.
**Use:** V2 — different shape than per-cell pods (compute-time horizontal vs tenant-isolated horizontal). Inform long-horizon task handling within a single cell.

### awesome-ai-agent-papers (VoltAgent)
**Repo:** [VoltAgent/awesome-ai-agent-papers](https://github.com/VoltAgent/awesome-ai-agent-papers)
**Use:** curated 2026 paper list. Bookmark for V-infinity research queue.

---

## Skip list (do not adopt)

### Nebula
**Repo:** [vesoft-inc/nebula](https://github.com/vesoft-inc/nebula) · Apache-2.0 · 12k stars · 6mo stale
**Why skip:** distributed C++ graph DB, multi-process cluster (graphd/storaged/metad), wrong scale (we're <100k nodes for years), wrong runtime (Zig single-binary), 6-month commit gap. Bolting onto our stack would 10× ops surface.

### zvec
**Repo:** alibaba/zvec · Apache-2.0 · 9.5k stars · C++
**Why skip:** in-process vector DB. Conflicts with our Postgres-centric rule (pgvector already in zaki_dual). Same call as MemPalace.

### Khoj — AGPL
**Repo:** [khoj-ai/khoj](https://github.com/khoj-ai/khoj) · **AGPL-3.0** ⚠️ · 30k stars
**Why skip vendoring:** AGPL forces chatzaki.com source open. Read once, learn from the content-indexer plugin contract pattern (each source type — markdown / PDF / ical / github — implements `extract → chunk → embed → link`). Don't link.

### Reor — AGPL
**Repo:** [reorproject/reor](https://github.com/reorproject/reor) · **AGPL-3.0** ⚠️ · 8k stars
**Why skip vendoring:** same AGPL issue. Read pattern: "related notes" sidebar via cosine similarity threshold + recency decay (instead of stored graph). Cheap fallback for compose view.

---

## OpenSpace — separate status

[HKUDS/OpenSpace](https://github.com/HKUDS/OpenSpace) · MIT · 5500+ stars · active 2026

Self-evolving skills MCP server. Local install at `/Users/nova/Desktop/experiments/OpenSpace/`. Stdio MCP client wired in nullalis (`src/mcp.zig` + gateway integration commit `04f56d7`).

**Status:** smoke-tested 2026-04-20. ❌ multi-turn stability bug — gateway crashes after ~5 consecutive turns with MCP active. Adoption blocked behind:
1. Multi-turn stability fix (blocker)
2. Benchmark measurement on `.spike/`
3. C + iter11 audit of OpenSpace's auto-capture (must not launder hallucinated "successes" into canonical skills)

Currently disabled in config (key renamed to `_mcp_servers_disabled_pending_stability_fix`). Re-enable when blocker is fixed.

---

## How to use this doc

When evaluating future graph-memory repos:
1. Check this doc first — it captures every prior evaluation
2. Apply the same lens (license, runtime fit, scope vs single-binary ethos, what specific pattern is worth borrowing)
3. Add the verdict here with the same shape
4. Don't re-research repos that are already on this list — point at the existing entry

Future-us thanks present-us.
