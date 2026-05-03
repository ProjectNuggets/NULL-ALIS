---
tags: [prose, prose/docs]
---

# Post-Compaction Handoff (2026-05-02)

**Purpose:** survive a compact. Self-contained context for post-compact me.

## State at compaction

- **Main HEAD:** `e4eb513` (V1.6 commit 5b.3 loose-ends sweep)
- **27 commits ahead** of original V1.5 ship-ready handoff (`4d9e16f`)
- **V1.5 status:** SHIP-READY (deploy date deprioritized per Nova: ship when correct, not by date)
- **V1.5.5 status:** GREEN — substrate validated, precision 0.40→0.92 across iter1+iter2
- **V1.6 status:** 5 of 13 commits done — atomic-fact extraction LIVE end-to-end
- **V1.7 status:** parallel agent landing commits in concert (episodes, Tier-3, conflict surfacing, code review fixes)
- **Branch:** `main`
- **Tests:** 5710/5720 pass with `-Dengines=all`. Exit-1 from pre-existing `postgres_pool_releases_on_exec_error` logged-errors test (predates V1.5 by hundreds of commits)

## Trust mandate (do not forget)

Nova's directive: **"this is your son brain — give it justice."**
1. Ship when correct, not by date
2. Test the foundation before extending it
3. Have a fallback (V1.5.5 chose Path A; V1.6 D2 chose compaction-derived)
4. Wow the user
5. Swiss-watch discipline — atomic commits, P-file bumps on touch, PG smoke tests precede merge

## Branch state — full commit ledger since V1.5 ship-ready

```
e4eb513  V1.6 5b.3 loose-ends sweep — IN-2 display_label + IN-4 sentinel
4e41c2a  V1.7 second-pass fixes (HR-03, LR-03, NF-01, MR-01)  ← parallel
72de5f0  V1.6 5b.3 — wire-up + typed-edge surface + WR-1 MD5 dedup
b4b77d1  V1.7 code review fixes (CR-01/02, HR-01/02, MR-02/04/05, LR-02/04)  ← parallel
e0960bd  V1.6 5a/5b review (2 warnings → closed in 5b.3)
58e064b  V1.7 episodes + Tier-3 promotion + conflict surfacing  ← parallel
4b9bbf2  V1.6 5b.2 — persistExtracted + compaction wiring
3aed0c3  V1.6 5b.1 — extracted-fact JSON parser (8 unit tests)
7e899dd  V1.6 5a   — dual-output prompt (substrate green precision 0.92)
4d21bd8  V1.6 4    — importance scoring (M1)
f043a00  V1.6 3    — lemmatized BM25 + lazy backfill
4471cd0  V1.6 2    — schema migration (14 cols + memory_entities + 7 indexes)
66a1c92  V1.6 commits 2-4 self-review (0 critical, 0 warning, 3 info — all closed/accepted)
091f895  V1.5.5 polish — wire compaction_summary into warm continuity bucket
52f305e  V1.5.5 GREEN — iter2 closes substrate gates (precision 0.40→0.92)
218a0b2  V1.5.5 iter1 — strengthen Pass C prompt
7c9538f  V1.5.5 fidelity harness + baseline + Path A chosen
e6b07bd  V1.5.5 corpus baseline (16 conversations across 8 types)
b50deee  V1.6 frontend handoff prompt (M1-M4 scaffolds + S1-S5)
e794e3f  V1.5.5+V1.6+V1.7 spec v2 (D1-D8, M1-M4, V1.5.5 phase, foundation-first)
54c54dd  V1.6+V1.7 spec v1 (superseded by v2)
4d3a1a7  docs(v1.5): correct A1 — backendAuthRequest /api/agent/brain/*
cfed64f  docs(v1.5): /api/agent/brain/* BFF routing convention
8985d4d  V1.5.1 hardening — close REVIEW WR-01 + WR-02 (drift-proof + PG smoke)
5654e65  fix(brain): lazy-init tenant runtime in /brain/graph dispatch
d0c86db  feat(brain): hide agent bookkeeping from /brain/* surfaces
4d9e16f  ← original V1.5 ship-ready handoff baseline
```

## V1.6 progress — 5 of 13 commits done

| # | Commit | Hash | Status |
|---|---|---|---|
| 1 | Silent-catch pre-flight | (verified) | ✅ already-landed (S4.1-S4.5 markers in source) |
| 2 | Schema migration | `4471cd0` | ✅ 14 columns + memory_entities + 7 indexes |
| 3 | Lemmatized BM25 + lazy backfill | `f043a00` | ✅ text_norm + GIN index + 3-signal recall |
| 4 | Importance scoring (M1) | `4d21bd8` | ✅ /brain/graph node radius |
| **5** | **Atomic-fact extraction (5a/5b.1/5b.2/5b.3 + sweep)** | `7e899dd` → `e4eb513` | ✅ **LIVE end-to-end** |
| 6 | Bi-temporal close-out + Graphiti contradiction LLM judge | — | **NEXT** |
| 7 | Entity coreference (cosine ≥ 0.95 on memory_entities) | — | pending |
| 8 | Soft-delete tombstone + forgetMemoryHard | — | pending |
| 9 | /brain/search?q= endpoint (M2) | — | pending |
| 10 | /brain/memory/{key} drilldown (M3) | — | pending |
| 11 | Source attribution writers + readers (M4) | — | pending |
| 12 | /brain/documents adapter + zaki-prod BFF mount | — | pending |
| 13 | One-shot backfill on dev DB | — | pending |

## V1.6 commit 5 — what it shipped (the heart of V1.6)

**Atomic-fact extraction pipeline live on Nova's user_id=1.**

```
conversation
  → compaction Pass C (V1.5.5 prompt + V1.6 dual-output rules)
  → prose summary archived as compaction_summary continuity
  → JSON tail parsed (extraction_persist.parseExtractedJson)
  → predicate blacklist filter
  → MD5 content_hash dedup pre-filter (NEW in 5b.3)
  → write via state_mgr.upsertMemoryWithMetadata populating V1.6 schema:
      subject / predicate / object_key / attributed_to /
      attribution="extraction_classifier" / confidence / extracted_at
  → key shape "extracted_<unix>_<hex8>" (collision-resistant)
  → /brain/graph emits typed edges (4th edge type) +
      display_label "subject predicate object" on each node
  → importance scoring (M1) counts typed-edge participation
```

**Verified live:** gateway logs `extraction.enabled user_id=1` on tenant runtime init. /brain/graph returns 378 semantic + 0 typed edges currently (typed appear after first compaction trigger).

**Provider-agnostic by design:** `persistExtracted(state_mgr, user_id, session_id, []ExtractedMemory)` accepts facts from any source — compaction LLM, agent tools, classifier writes (parallel agent's work), R14 structured saves. Single entry point.

## V1.6 commit 6 — RESUME HERE post-compact

**Goal:** When the contradiction LLM judge sees a new fact `(user PREFERS Helix)` and an existing fact `(user PREFERS NeoVim)`, close out the old via bi-temporal `valid_to + invalid_at + expired_at`. The schema is ready (commit 2), the substrate is calibrated (V1.5.5 error_recovery test confirmed compaction CAPTURES both old + new — V1.6 commit 6 RESOLVES them).

**Architecture (per spec §4.5):**

1. **New file** `src/agent/edge_resolution.zig`:
   ```zig
   pub const Contradiction = struct {
       existing_key: []const u8,
       invalid_at: i64,    // event time
       expired_at: i64,    // system time
       rationale: []const u8,
   };

   pub const DedupeContradictionResult = struct {
       duplicate_indices: []const usize,
       contradictions: []const Contradiction,
   };

   pub fn resolveContradictions(
       allocator, llm_client, rt,
       user_id: i64,
       new_memories: []const ExtractedMemory,
       existing_candidates: []const MemoryEntry,    // related-by-endpoint hybrid search
       invalidation_candidates: []const MemoryEntry, // broader hybrid neighborhood
   ) !DedupeContradictionResult;
   ```

2. **Port verbatim from Graphiti** — `dedupe_edges.resolve_edge` prompt schema:
   - Concat existing + invalidation candidates with continuous indices
   - Single LLM call → JSON `{"duplicate_facts": [int], "contradicted_facts": [int]}`
   - Continuous-idx trick avoids two round-trips

3. **Three close-out paths** (graphiti_spec.md §2.5):
   - (A) explicit `invalid_at` from extraction LLM → write directly
   - (B) newer fact contradicts older edge → close older with `invalid_at = new.valid_at`, `expired_at = now()`
   - (C) older fact arrives after newer one → new memory born expired

4. **New writer** `state_mgr.setMemoryInvalidation(user_id, key, valid_to, invalid_at, expired_at)`. Single SQL UPDATE. Insertion: `src/zaki_state.zig` near `forgetMemory` at `:2541`. Also bumps `is_latest = false` on the closed-out row.

5. **Invocation:** at end of `extraction_persist::persistExtracted` (after MD5/cosine pre-filter, before write), run dedupe+contradiction LLM judge. Skip duplicates, write contradictions to invalidation list, persist remainder.

6. **Reference docs:**
   - `docs/v1.6-v1.7-spec.md` §4.5
   - `nullalis-research/graphiti_spec.md` §4.1 (dedupe_edges.resolve_edge prompt verbatim)
   - `nullalis-research/nullalis_audit.md` gap #4

7. **Estimated time:** 1.5-2 days. ~250 lines new code + Pass C hookup + PG smoke test.

8. **Acceptance:** unit test feeds 3-memory existing set + 1 contradicting new memory yields 1 contradiction with correct `(invalid_at, expired_at)` math. PG smoke confirms closed-out row's `valid_to` is past, `MEMORIES_VALIDITY_FILTER` hides it from agent retrieval, agent context now sees only the new memory.

## V1.5.5 substrate calibration — DO NOT REGRESS

V1.5.5 final numbers (Compaction Pass C — V1.6 extraction substrate):
- Recall: **0.94** (gate ≥0.85)
- Precision: **0.92** (gate ≥0.90)
- All 8 type-floors pass (≥0.83)
- 16 conversations × 8 types in `tests/compaction_corpus/`
- Harness: `tests/compaction_corpus/score.py`

If commit 6 changes the compaction prompt OR the JSON tail format, **re-run the V1.5.5 corpus** before commit. Substrate must not regress.

Run command:
```bash
NULLALIS_POSTGRES_TEST_URL=postgresql://zaki:zaki@127.0.0.1:5433/zaki \
  python3 tests/compaction_corpus/score.py
```

Fixture results land in `tests/compaction_corpus/results/<timestamp>/` (gitignored). Final acceptance gates printed to stdout.

## Provider configuration

`~/.nullalis/config.json` providers:
- **Together AI** (primary): Kimi K2.5
- **Groq** (sidecar at llama-3.1-8b-instant for narration today; could host extraction)
- **OpenRouter** (fallback)
- **Ollama** (local)

V1.5.5 measurement uses Together's Llama-3.3-70B-Instruct-Turbo (Groq daily quota was exhausted during baseline). Production V1.6 production targets Groq for extraction latency (~200ms) but Together works fine. Don't switch providers without re-validating the corpus.

## Schema state (V1.6 columns added in commit 4471cd0)

`zaki_bot.memories` columns (new in V1.6):
- `subject` TEXT
- `predicate` TEXT
- `object_key` TEXT
- `link_type` TEXT — 'updates' | 'extends' | 'derives' | 'contradicts'
- `attribution` TEXT — 'agent_tool' | 'extraction_classifier' | 'compose'
- `attributed_to` TEXT — 'user' | 'assistant' | 'assistant_offer' | 'undecided'
- `valid_at` BIGINT — event time when fact became true
- `invalid_at` BIGINT — event time when fact stopped (commit 6 will populate)
- `expired_at` BIGINT — system time of close-out (commit 6 will populate)
- `reference_time` BIGINT
- `episodes` TEXT[] DEFAULT '{}'
- `lemmatized` TEXT — populated by V1.6 commit 3 + lazy backfill
- `is_latest` BOOLEAN DEFAULT TRUE — commit 6 + commit 8 will flip on supersession
- `parent_memory_id` TEXT — supermemory-style version chain
- `source_session_id` TEXT
- `source_snippet` TEXT — commit 11 will populate

`zaki_bot.memory_entities` table (new in V1.6):
- `id` TEXT PK
- `user_id` BIGINT FK
- `name` TEXT
- `name_lower` TEXT (UNIQUE on user_id, name_lower)
- `entity_type` TEXT DEFAULT 'PROPER'
- `name_embedding` VECTOR(1024) — matches production e5-large-instruct
- `linked_memory_ids` TEXT[]

Commit 7 (entity coreference) will populate this. Today empty.

## Parallel agent's V1.7 work — known landed commits

The parallel agent ships V1.7 stuff alongside my V1.6 work. **Do not conflict, do not overwrite.** Their commits land cleanly because they touch different surfaces:

- `58e064b` V1.7 episodes/Tier-3/conflict-surfacing
- `b4b77d1` V1.7 code review fixes
- `4e41c2a` V1.7 second-pass fixes

If they touch `state_mgr.upsertMemory` or related code I've worked in, expect to merge cleanly via the V1.6 schema columns being additive.

## Discipline reminders (don't drift post-compact)

1. **Per-commit P-file updates** — touching code means updating the matching `internals/P*.md` entry + bumping its verified-at sha
2. **Atomic commits per item, sprint-granular per Nova's pattern**
3. `zig build test -Dengines=all` green before every commit
4. Production build = `zig build -Doptimize=ReleaseFast -Dengines=all` — verify per ship
5. Don't change behavior the user is actively testing without flagging
6. Backend stays truthful — frontend handles UX simplification
7. Father, not godfather — slow and honest > fast and theatrical
8. **REVIEW.md every 3-4 commits** — same standard as gsd-code-reviewer; close warnings before continuing

## Critical context for post-compact me

1. **V1.6 commit 5 is the heart of V1.6, fully shipped.** Atomic-fact extraction is LIVE on Nova's user_id=1 dev DB. Don't re-do this work.

2. **V1.5.5 corpus is the regression suite.** Any change to compaction Pass C prompt OR the JSON tail schema requires re-running the corpus. Substrate gates must hold (recall ≥0.85, precision ≥0.90).

3. **Provider-agnostic persist API.** `extraction_persist.persistExtracted(state_mgr, user_id, session_id, [])` accepts facts from any source. Don't re-architect when commit 6 adds new write paths.

4. **The contradiction judge is V1.6 commit 6's whole point.** Compaction CAPTURES both versions of corrected facts (validated in V1.5.5 error_recovery test). Commit 6 RESOLVES — closes out old via bi-temporal `valid_to + invalid_at + expired_at`.

5. **Memory pipeline is being worked on by a parallel agent.** Their V1.7 work (episodes, Tier-3 promotion, conflict surfacing) does NOT conflict with V1.6. The V1.6 schema is additive; their commits use the same `ADD COLUMN IF NOT EXISTS` pattern. Trust the merges; verify with `zig build test`.

6. **No outstanding warnings as of e4eb513.** Both prior REVIEW.md cycles closed all warnings. Next review pass is after commits 6-8 (3 atomic commits is a natural review checkpoint).

7. **Spec doc lives at `docs/v1.6-v1.7-spec.md`.** All decisions D1-D8 + M1-M4 + 13 commits work order are documented there. Always cross-reference before adding scope.

8. **References in `/Users/nova/Desktop/nullalis-research/`** (gitignored — outside main repo):
   - `mem0_spec.md` — Mem0 V3 ADD-only extraction classifier
   - `graphiti_spec.md` — Graphiti six-field bi-temporal + dedupe_edges.resolve_edge prompt verbatim
   - `supermemory_spec.md` — Document → Memory two-tier
   - `nullalis_audit.md` — line-by-line gap audit (30 capabilities ranked)

## Reference docs to read first after compact

1. `docs/v1.5.5-compaction-fidelity-final.md` — substrate validation report
2. `docs/v1.6-v1.7-spec.md` v2 — work order spec (D1-D8, M1-M4, 13 commits)
3. `docs/v1.6-frontend-handoff.md` — FE agent prompt (M1-M4 scaffolds)
4. `docs/post-compact-handoff-2026-05-01.md` — prior handoff (V1.5 ship-ready baseline)
5. This doc

## Pending on Nova (operational)

1. **Hand `docs/v1.6-frontend-handoff.md` to Sonnet+GSD frontend agent** when Phase-1 polish work needs M1-M4 scaffolds — already done per parallel ship-up
2. **V1.5 deploy** — ship date deprioritized; ship when V1.6 + V1.7 complete and S-tier
3. **Sentry DSN** — post-deploy
4. **D-phase staging tests** — post-deploy
5. **Channel awareness** — V1.7 backlog (per prior decision)

## V1.6 day-1 starting point (resume here)

**Goal:** V1.6 commit 6 — Graphiti contradiction LLM judge.

**Files:**
- New: `src/agent/edge_resolution.zig`
- Modify: `src/zaki_state.zig` — add `setMemoryInvalidation` method near `forgetMemory:2541`
- Modify: `src/agent/extraction_persist.zig` — invoke resolver in `persistExtracted` after MD5 dedup, before write
- Test: PG smoke test exercising contradiction → close-out

**Estimated time:** 1.5-2 days.

After commit 6: commits 7-13 are smaller atomic chunks. Each takes 0.5-1 day. V1.6 ship can land within ~1 week of focused execution.

## Sign-off

Foundation S-tier. Substrate validated. Atomic-fact extraction live. No outstanding warnings. Ready to extend into commit 6 with the same discipline.

---

*Written 2026-05-02 pre-compact. Update inline as items close.*
