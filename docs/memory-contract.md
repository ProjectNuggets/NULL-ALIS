# Memory Contract

Normative. Code and this doc must agree; `src/memory/contract_test.zig` is the
executable form of the truth table below — if you change either, change both.
PRs touching memory classification are reviewed against this file.

## Buckets

Every piece of content at a memory boundary lands in exactly one bucket:

| Bucket | Definition | Storage fate |
|---|---|---|
| **knowledge** | Facts about the user & world (outward-facing): preferences, people, decisions, open-loops, events | `memories` + `memory_entities`/`memory_edges`; embedded; recallable; durable or decayable by `memory_type` |
| **derived** | The agent's synthesis OF memory: continuity summaries, communities, insights, dream logs | Persisted, injectable (warm-start), but NOT embedded into fact-recall space |
| **bookkeeping** | The agent's own machinery: system scaffold, internal-tool dumps, traces, audit shells, tombstones | Never extracted, never embedded, never an entity, hidden from /brain by default |
| **transient** | Live scratchpad: working memory (Layer 0), the in-flight turn | Bounded (15 slots), reaped, cleared on /reset |

## Decision axes

The bucket is decided by these axes — never by content matching:

1. **Provenance** — which role (`.system` never extracts) / which tool
   (introspection tools never extract) / which writer (key prefix).
2. **Referent** — outward (user/world) vs inward (the agent's own state).
3. **Novelty** — re-surfaced own memory (recall/list) is already-stored;
   re-extraction is redundant-not-poison; verbatim dumps are excluded,
   recall stays (coref context).
4. **Durability** — orthogonal, WITHIN knowledge only: `DURABLE_MEMORY_TYPES`
   = {core, preference, decision, person, open_loop};
   `EVERGREEN_MEMORY_TYPES` = durable minus open_loop (open_loop decays but
   cannot resurrect/demote).

## Truth table

(Executable form: `src/memory/contract_test.zig`. Rows marked [E] are
enforced in extraction-builder tests inside `src/agent/extraction/runner.zig`.)

| Input | Bucket | Enforced behavior |
|---|---|---|
| `.system` message at extraction [E] | bookkeeping | dropped by role, both transcript builders |
| `.tool` result from `memory_doctor`, `memory_maintain`, `brain_graph`, `context_snapshot`, `trace_query`, `runtime_info`, `memory_list`, `memory_timeline`, `transcript_read` [E] | bookkeeping | dropped by exact tool identity |
| `.tool` result from data tools (`web_search`, `web_fetch`, `file_read`, …) [E] | knowledge (candidate) | extracted |
| `.tool` result, `name == null` [E] | unknown | fail-open: extracted |
| Entity named in `scaffold_entity_names` at persist boundary | bookkeeping | write rejected (denylist backstop) |
| `memory_store` (inline path) with a scaffold-entity, system-managed, default-hidden-bookkeeping, or >255-byte key | bookkeeping | tool call rejected with redirect message (`inlineKeyGuard`); the unified-triple path is exempt — it derives its own `extracted_<hash>` key and ignores the caller's |
| Keys `summary_latest/ timeline_summary/ session_summary/ summary_fallback/` | derived | not embedded (`shouldEmbedMemoryEntry`=false), semantic-bookkeeping (excluded from fact recall), hidden from the /brain view (`isBrainVisibleKey`=false) but NOT default-hidden — stays injectable for warm-start (P4) |
| Keys `audit_shell/ __tombstone__/ compaction_* autosave_* session_checkpoint_*` | bookkeeping | hidden from the /brain view (`BRAIN_HIDDEN_PREFIXES`); internal/audit families also default-hidden (`isDefaultHiddenMemoryKey`); append-only or system-managed |
| `durable_fact/*` keys | knowledge | curable (archive/forget/edit — H1), system-write-disciplined |
| `memory_type` in EVERGREEN set | knowledge (durable) | exempt from decay (in-memory + persistent SQL), resurrect-proof, promote-no-clobber |
| `memory_type == open_loop` | knowledge (durable) | decays in ranking; still resurrect-proof/demotable-guard |
| Working-memory slots | transient | ≤15 slots, reaper, cleared on reset |

## Enforcement map

(Symbol-name references — locate with `grep -n "<symbol>" <file>`. Line numbers
are deliberately omitted: they rot on unrelated edits; symbols survive refactors.)

- Role filter (keystone): `src/agent/extraction/runner.zig` `buildEpisodeTranscript` / `buildTranscript`
- Tool-identity filter: `runner.zig` `internal_extraction_tool_names` (pub = test-only surface) + `isInternalExtractionToolName`
- Entity denylist: `src/agent/context_builder.zig` `scaffold_entity_names` (comptime drift-guarded vs `stable_prompt_markers`; normalized forms precomputed at comptime)
- Key predicates: `src/memory/root.zig` — `isInternalMemoryKey`, `isContinuityArtifactKey`, `isContinuitySummaryKey`, `isDefaultHiddenMemoryKey`, `isBrainVisibleKey`, `BRAIN_HIDDEN_PREFIXES` / `BRAIN_HIDDEN_EXACT_KEYS`, `isSemanticBookkeepingKey`, `shouldEmbedMemoryEntry`, `isTombstoneKey`, `isAppendOnlyMemoryKey`, `isSystemManagedMemoryKey`, `isMutableMemoryEntry`, `isEditableMemoryEntry`
- Type sets: `src/memory/root.zig` `EVERGREEN_MEMORY_TYPES` / `DURABLE_MEMORY_TYPES` (+SQL fragments, comptime drift guard)
- Store-boundary guard: `src/tools/memory_store.zig` `inlineKeyGuard` (inline path only — see truth table)
- Registry cross-check: `src/memory/contract_test.zig`
- Output lane: daemon-brief scrub (`src/tools/schedule.zig`, PR #128); detection-only recurrence tap (`src/agent/root.zig` `containsScaffoldSection`)

## Invariants

1. Bookkeeping never becomes knowledge (no extraction, no entities, no embedding).
2. The line is drawn by PROVENANCE, never content — rewording cannot cross it.
3. Unknown identity fails OPEN into extraction (data loss is worse than redundancy) but fails CLOSED at explicit write boundaries (denylist, store guard).
4. Derived artifacts are persisted and injectable but never pollute fact recall.
5. Durability is a property of `memory_type` only; curability is provenance; aliveness is state (`valid_to`/`is_latest`). Never proxy one axis through another.
6. **Every agent-facing write tool carries its own fail-closed key guard.** The engine API (`Memory.store`/`storeWithMetadata`) is UNGUARDED BY DESIGN — internal writers (promotion, learning, session-end, timeline) legitimately write system-managed keys through it. Therefore the guard obligation sits at the tool layer: `memory_store` uses `inlineKeyGuard`; `compose_memory` satisfies it via its `compose:` key-namespace allowlist (equivalent mechanism). A NEW write tool must add one of the two — a namespace allowlist or `inlineKeyGuard`-style denylist — before it ships; a tool calling the engine API with agent-chosen keys and no guard violates this contract.

## Deferred register

- Tool `introspection` metadata flag replacing the curated denylist (Phase-1 classifier).
- `audit_shell/` + `memory_health_` divergent list reconciliation.
- `is_latest` written-but-not-read in memories retrieval filter.
- Near-dup semantic MERGE at write time (C0 reports only).
- `task_list`/`cron_runs`/`skill_registry` extraction judgment (kept fail-open deliberately).
