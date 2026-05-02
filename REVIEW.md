---
phase: v1.6-commits-5a-5b1-5b2
reviewed: 2026-05-02
reviewer: Claude (self-review, same bar as gsd-code-reviewer)
scope_commits:
  - 7e899dd V1.6 5a   — dual-output prompt (substrate green precision 0.92)
  - 3aed0c3 V1.6 5b.1 — extracted-fact JSON parser (8 unit tests)
  - 4b9bbf2 V1.6 5b.2 — persistExtracted + compaction wiring (opt-in via config)
files_reviewed:
  - src/agent/compaction.zig (prompt + summarizeSlice signature + Pass C wiring)
  - src/agent/extraction_persist.zig (parser + persistExtracted + helpers)
  - tests/compaction_corpus/score.py (Python prompt mirror + harness changes)
findings:
  critical: 0
  warning: 2
  info: 5
status: ship_with_warnings_addressed_in_5b3
---

# V1.6 Commits 5a / 5b.1 / 5b.2 Review — Pre-Wire-Up Gate

**Reviewed:** 2026-05-02
**Bar:** S-tier — same standard the FE agent's GSD review pass applied to Phase-1.
**Pre-condition:** V1.5.5 substrate validation passed iter2 (precision 0.92 ≥ gate 0.90).

## Summary

Three commits implementing the heart of V1.6 atomic-fact extraction. Prompt extends Pass C to dual-output, parser handles the JSON tail, persist function writes through state_mgr with V1.6 schema columns. Provider-agnostic design — Nova's parallel memory-pipeline work can reuse the same persist entry point.

**Critical: 0. Warning: 2 (must land in 5b.3 before extraction goes live). Info: 5.**

Verdict: **ship 5a/5b.1/5b.2 as-is**, but 5b.3 must close WR-1 + WR-2 before populating `extraction_state_mgr` in CompactionConfig at runtime. Otherwise duplicate facts flood the brain page on every compaction.

---

## Warnings — must land in 5b.3

### WR-1: No MD5 content_hash dedup at write time → duplicate facts on every compaction

**File:** `src/agent/extraction_persist.zig::persistExtracted`

**Issue:** Compaction Pass C fires at 70/80/90% context pressure. Each trigger summarizes the prior (older) segment. After a compaction lands, the next trigger's input includes the previously-archived prose summary — the LLM is likely to re-emit the same atomic facts as JSON. Without dedup, after 5-10 compactions on Nova's session, the brain page will accumulate near-duplicates of the same fact ("user prefers Helix", "user uses Helix as editor", "user switched to Helix from NeoVim", etc.).

The schema already has `content_hash TEXT` on every memory row, populated by `computeContentHash` at write time. There's an existing index `idx_memories_hash ON memories(user_id, content_hash)`. Wiring an MD5 pre-filter is cheap:

```zig
// Before persistExtracted's upsert call, in the per-fact loop:
const new_hash = try computeContentHash(allocator, m.text);
defer allocator.free(new_hash);
if (try state_mgr.findMemoryByContentHash(user_id, new_hash)) |existing| {
    log.info("extraction.duplicate_skipped key={s} matches_existing={s}", .{key, existing.key});
    result.skipped_md5_dup += 1;
    continue;
}
```

**Required addition:** new `state_mgr.findMemoryByContentHash(user_id, hash) → ?MemoryEntry` method on `zaki_state.Manager`. Single SQL `SELECT id FROM {schema}.memories WHERE user_id = $1 AND content_hash = $2 LIMIT 1` — uses `idx_memories_hash` directly.

**Severity:** warning. Without this, V1.6 ships visible duplicates on the brain page. Spec §4.4 D4-mitigation already documented; just needs to land.

**Action:** add to 5b.3 alongside the wire-up.

### WR-2: /brain/graph typed-edge surface still pending (carries IN-3 from prior review)

**File:** `src/gateway.zig::handleBrainGraph`

**Issue:** Commits 2-4 review (`66a1c92`) flagged IN-3 as a forward-action for commit 5: "when typed atomic-fact edges land, the importance degree counter must be extended in the same commit." Commit 5b.2 wires the WRITE side (subject/predicate/object_key columns get populated) but the READ side hasn't caught up — `/brain/graph` still emits only `session`, `semantic`, `reference` edge types. Memories that are connected only via subject/object relationships won't show as connected on the FE.

Worse: the importance scoring (commit 4) won't count typed-edge participation, so a hub memory with 10 typed edges will look isolated on the FE.

**Required addition:** in `handleBrainGraph` after `buildBrainReferenceEdges`:

1. Build a 4th edge type `"typed"` connecting nodes that share `subject`, OR connecting `subject_node → object_key target` when `object_key` resolves to another node's key
2. Update the `degree` HashMap to include typed edges in the count
3. Emit typed edges in the JSON edge array

The schema is ready (commit 2 added `subject`/`predicate`/`object_key` columns + `idx_memories_subject` + `idx_memories_object_key` indexes). Just needs the gateway to read them and build edges.

**Severity:** warning. Without this, V1.6 atomic facts persist invisibly — the FE won't see typed relationships, defeating half the second-brain pillar in Nova's vision.

**Action:** must land in 5b.3 alongside the wire-up.

---

## Info-level findings

### IN-1: No cosine dedup at write time (D4 mitigation deferred)

**File:** `src/agent/extraction_persist.zig::persistExtracted`

**Issue:** MD5 dedup (WR-1) catches exact-duplicate content. But the LLM emits slightly-different phrasings of the same fact ("user prefers Helix" vs "Helix is the user's editor" vs "Alex uses Helix") — MD5 won't match those. Spec D4 requires cosine ≥ 0.92 dedup vs recent rows in same session.

**Why deferred:** cosine dedup needs `MemoryRuntime` plumbing through `CompactionConfig` (not currently wired) plus an embedding call per fact (cost). MD5 covers the high-frequency case (Pass C re-summarizing prose); cosine is the polish that catches paraphrases.

**Severity:** info. WR-1 closes the worst case. Cosine catches the long tail.

**Action:** track for V1.6 follow-up commit (between commit 7 entity-coreference and ship gate).

### IN-2: `extracted_<unix>_<hex8>` keys are visible raw on /brain page

**File:** `src/agent/extraction_persist.zig::deriveExtractionKey` + FE rendering

**Issue:** The key shape `extracted_1714521600_a1b2c3d4` is correct (collision-resistant, addressable) but ugly when the FE renders the raw key on hover or in the M3 drilldown panel. The FE should derive its display label from `subject - predicate - object` instead of the raw key.

**Severity:** info. Backend contract is correct; this is an FE rendering choice.

**Action:** flag in V1.6 commit 10 (M3 drilldown handler) — `/brain/memory/{key}` response should include a `display_label: "<subject> <predicate> <object>"` field for FE convenience.

### IN-3: REJECTED_PREDICATES list is finite

**File:** `src/agent/extraction_persist.zig::REJECTED_PREDICATES`

**Issue:** 15 hardcoded meta-predicates (GREETED, SAID, etc.) cover what we observed in V1.5.5 iter1 regression. The LLM may invent novel meta-predicates not on the list (e.g., "MENTIONED_TOPIC", "STARTED_DISCUSSING").

**Severity:** info. The blacklist is defense-in-depth; the prompt's RULE 1 + RULE 4 are the primary guard. Belt + suspenders.

**Action:** monitor production. Expand list as new meta-predicates surface. Could grow to a regex pattern (`SAID_*`, `ASKED_*`, `MENTIONED_*`) if the long tail demands it.

### IN-4: `extraction_user_id: i64 = 0` sentinel is brittle

**File:** `src/agent/compaction.zig::CompactionConfig`

**Issue:** Using `0` as the "extraction disabled" sentinel works because no production user has `user_id = 0`, but it's a magic value. Cleaner: `?i64 = null`. Refactor would require updating call sites and the gate condition (`config.extraction_user_id != 0` → `config.extraction_user_id != null`).

**Severity:** info. Functionally correct; stylistic.

**Action:** backlog for V1.7 cleanup.

### IN-5: `emotional` type-precision dipped 0.91 → 0.75 in 5a iter2

**File:** V1.5.5 corpus `emotional/` cases

**Issue:** Strengthening the NO FACTS guard for casual conversations may have pulled the LLM toward over-aggressive omission on emotional conversations (where tone-as-fact is legitimate). Dropped from V1.5.5 iter2 baseline. Still well above the 0.70 type-floor gate.

**Severity:** info. Not a regression to substrate gate; per-type observation.

**Action:** monitor in V1.6 production. If user-visible quality dips on emotional content, iterate the prompt with emotional-fact-preservation guidance.

---

## What stays clean across all three commits

- **No silent-catch on memory writes** — V1.5.1 hardening pattern preserved in `persistExtracted` (every per-fact failure logs structured `metric=extraction.X`)
- **Memory ownership is correct** — `parseExtractedJson` errdefer covers partial-output cleanup; `persistExtracted` defers free for key + metadata_json before each loop iteration
- **V1.5 callers unaffected** — `summarizeSlice` signature change is the only API delta; both internal callers updated; external callers don't exist
- **Provider-agnostic** — `persistExtracted` accepts any `[]ExtractedMemory` source; future caller (parallel memory-pipeline work) plugs in without re-architecture
- **Substrate validation** — V1.5.5 corpus re-run on 5a iter2 confirmed precision 0.92 / recall 0.92 / all type-floors ≥0.75

---

## Acceptance gates

- ✅ All commits build clean (Debug + ReleaseFast verified per commit)
- ✅ V1.5.5 corpus re-validates on the strengthened 5a prompt
- ✅ 8 new unit tests in `extraction_persist.zig` (parser tolerance to malformed input, control char escaping, etc.)
- ✅ 0 critical, 0 warning IN BLOCKING SCOPE for the work-as-shipped — WR-1 + WR-2 are forward-actions for 5b.3 (the gate before atomic facts go live)

---

## Verdict

**Ship 5a/5b.1/5b.2 as-is** — they form a coherent, testable, non-breaking set. `extraction_state_mgr` defaults to null, so atomic-fact extraction is OPT-IN; nothing changes in production until 5b.3 populates it.

**5b.3 scope (mandatory before extraction goes live):**
1. **WR-1 fix**: add `state_mgr.findMemoryByContentHash` + MD5 pre-filter in `persistExtracted`
2. **WR-2 fix**: typed-edge surface in `/brain/graph` + degree counter extension
3. **Wire-up**: populate `CompactionConfig.extraction_state_mgr` + `extraction_user_id` at agent runtime init
4. **PG smoke test**: end-to-end fixture exercising compaction → extract → persist → /brain/graph visibility
5. **Live verification on Nova's user_id=1**: trigger real compaction → confirm extracted rows + typed edges

Without WR-1 + WR-2, atomic-fact extraction would ship with visible duplicate facts AND no typed-edge connectivity on the FE.

— signed by the backend, V1.6 5a/5b.1/5b.2 self-review, 2026-05-02.
