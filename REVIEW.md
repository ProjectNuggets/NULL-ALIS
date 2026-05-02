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

---

## Parallel V1.7 Agent Review

**Reviewer:** Independent (Claude Opus 4.7, 1M ctx) — invoked by Nova to cross-check parallel-agent-authored commits while V1.6 commit 6 was landing.
**Scope:** `58e064b`, `b4b77d1`, `4e41c2a` (V1.7 episodes / Tier-3 / conflict surfacing + maintenance schedule kind).
**Method:** `git show <sha>` per-commit diffs + post-merge file state cross-checked against V1.6 commit 6 (`ed97644`) and V1.6 columns commit (`4471cd0`). Specs cross-referenced from `/Users/nova/Desktop/nullalis-research/{graphiti,mem0,supermemory}_spec.md`.
**Reviewed:** 2026-05-02

### Verdict

**One CRITICAL bug**, two WARNINGs, four INFO. The CRITICAL is a real regression — Tier-3 promotion is silently reverted by the very next `upsertMemory` call to a promoted key, producing flapping core rows and false-positive conflict markers (defeating LR-03). The second-pass fixes in `4e41c2a` did genuinely close the issues the first pass left open (HR-03 / LR-03 / NF-01 are correct), but they did not catch this deeper interaction. Hold the V1.7 ship until CRITICAL-1 is fixed; the rest can land as follow-ups.

The work does **not** materially conflict with V1.6 commit 6's `setMemoryInvalidation` close-out — extraction-classifier writes use timestamp+random keys (`deriveExtractionKey`) so the cross-session ON CONFLICT path can't be hit by extraction. `compose_memory` (HR-03 path) firing markers on extraction-derived keys is therefore not a real risk. V1.6 columns are consumed read-only by V1.7.

### CRITICAL-1: Tier-3 promotion is silently reverted by next `upsertMemory`, producing flapping core/non-core rows + false-positive conflict markers

**File:** `src/zaki_state.zig:2415-2429` (upsertMemory ON CONFLICT clause) interacting with `:2497-2521` (post-update guards).

**Mechanism:**

1. `promoteMemoryToCore` (line 2528) sets `memory_type='core', session_id=NULL`.
2. The next `upsertMemory` for the same key from any session fires the ON CONFLICT path, whose SET clause unconditionally writes:
   ```sql
   session_id = EXCLUDED.session_id,
   memory_type = EXCLUDED.memory_type,
   ```
   (lines 2416-2417). The WHERE gate is `IS DISTINCT FROM` on session/content/type, which is TRUE because stored.session_id is NULL after promotion. The update fires and **overwrites the core promotion**: `memory_type` reverts to whatever `categoryToMemoryType(category)` returns (typically `'episodic'`), `session_id` reverts to the new session.
3. RETURNING reflects post-update state, so `returned_type='episodic'`, not `'core'`.
4. The post-update guards then do this on every subsequent cross-session write:
   - `seen_count >= 2 AND returned_type != "core"` → TRUE → `promoteMemoryToCore` re-fires (wasted SQL).
   - `seen_count > 1 AND returned_type != "core"` → TRUE → **`writePendingConflictMarker` fires**, exactly the false-positive LR-03 was meant to prevent.

**Net effect:** every active user whose cross-session-corroborated key gets a third (or later) cross-session write sees a `pending_conflicts` marker. LR-03's `returned_type != "core"` check looks correct in isolation but reads a value that the same SQL statement already clobbered.

**Why the seen_count CASE doesn't save it:** the CASE requires `stored.session_id IS NOT NULL` to increment. Post-promotion stored.session_id is NULL, so count freezes at 2 forever after promotion — the count grows once, sticks, and the row oscillates type forever.

**Fix:** the ON CONFLICT SET must preserve the promoted state. Two viable shapes:

```sql
-- Option A (simplest): don't overwrite memory_type/session_id when stored is core.
memory_type = CASE WHEN {schema}.memories.memory_type = 'core' THEN 'core' ELSE EXCLUDED.memory_type END,
session_id  = CASE WHEN {schema}.memories.memory_type = 'core' THEN NULL  ELSE EXCLUDED.session_id  END,

-- Option B: gate the entire UPDATE WHERE on `memory_type != 'core'`, and let core rows
-- accept content updates only via a separate explicit code path.
```

Option A is the smaller change and matches the spirit of `promoteMemoryToCore` (line 2531) which already includes `AND memory_type != 'core'` to avoid clobbering. The same idempotency must extend to the upsert SET.

**Coverage gap:** there is no PG smoke test that writes a key from session A, then session B (promotion), then session C (regression), then asserts `memory_type='core'` and no `pending_conflicts` row. Such a test would have caught this immediately. CRITICAL-1's fix MUST land with that test.

### WARNING-1: `pending_conflicts` is not in `BRAIN_HIDDEN_EXACT_KEYS` — it leaks to /brain/graph as a user-visible "core memory"

**File:** `src/memory/root.zig:558-562` (`BRAIN_HIDDEN_EXACT_KEYS`) — does not include `pending_conflicts`.
**File:** `src/zaki_state.zig:2567` writes the marker with `memory_type = 'core'`.

The brain visibility filter is the source of truth for `/brain/*` surfaces. Writing a `core`-typed row with key `pending_conflicts` into the memories table without adding it to `BRAIN_HIDDEN_EXACT_KEYS` means the user's `/brain/graph` and `/brain/timeline` will display:

```
type=pending_conflicts
key=user_birthday
session=...
at=...
instruction=One or more facts you know were updated...
```

as if it were a core memory the user had stored about themselves. The internals comment on `BRAIN_HIDDEN_EXACT_KEYS` (memory/root.zig:558) is explicit that this is the single source of truth for hygiene; V1.7 took a partial step (the `isSystemMemoryKey` predicate at zaki_state.zig:2598) but missed this surface.

**Fix:** add `"pending_conflicts"` to `BRAIN_HIDDEN_EXACT_KEYS` (memory/root.zig:558). The companion test at `zaki_state.zig:4331 "BRAIN_USER_KEY_FILTER mirrors memory_root.isBrainVisibleKey"` will validate the SQL filter automatically.

### WARNING-2: zero PG smoke tests for V1.7 — three new methods + a hot-path SQL change shipped untested at the DB level

**Files:**
- `src/zaki_state.zig:2399-2522` — modified `upsertMemory` hot path (CASE arithmetic + post-update branches).
- `src/zaki_state.zig:2528-2542` — new `promoteMemoryToCore`.
- `src/zaki_state.zig:2550-2594` — new `writePendingConflictMarker`.
- `src/zaki_state.zig:2626-2676` — new `insertEpisodeEvent`.

The V1.6 commit 6 reviewer's pattern is two PG smoke tests per surface (close-out filter test + related-fetch scope test, both under `if (!build_options.enable_postgres) return error.SkipZigTest`). V1.7 ships zero. Specifically missing:

- **promotion roundtrip:** insert key from session A, insert from B, assert `memory_type='core' AND session_id IS NULL AND seen_in_session_count=2 AND confidence_score=0.9`.
- **conflict marker visibility:** insert from A then B, assert a `pending_conflicts` row exists with `memory_type='core'`; call `getMemory(pending_conflicts)` and assert content includes the conflicted key.
- **conflict marker suppression for core rows** (LR-03 acceptance): insert A, B (promotes), C → assert no new pending_conflicts row OR same row (this is what CRITICAL-1 will fail).
- **isSystemMemoryKey gate:** insert `summary_latest/x` from two sessions, assert no promotion and no conflict marker.
- **episode event payload shape:** call `implStore("timeline_summary/sess1/123", "...")`, query `memory_events WHERE event_type='episode'`, assert payload JSON parses with `session_id="sess1"` and `trigger="checkpoint"`.

CRITICAL-1's fix must land coupled with at least the promotion-roundtrip and conflict-suppression tests above.

### INFO-1: HR-03 creates a behavioral asymmetry between `memory_store` and `compose_memory`

**File:** `src/zaki_state.zig:2138-2241` (upsertMemoryWithMetadata).

By design (per HR-03 commit message), `compose_memory` writes track `seen_in_session_count` and fire conflict markers, but **do not** trigger Tier-3 promotion. This means:

- `memory_store("user_birthday", "March 5", session=A)` then same from session B → row promotes to core.
- `compose_memory("user_birthday", "March 5", session=A)` then same from session B → row stays warm; conflict marker fires.

Two paths, same key, same content, different durability tier. The asymmetry is defensible (compose_memory is agent-synthesized; tool-store is user-attested), but it should be documented in the agent-facing memory tool descriptions (`src/tools/compose_memory.zig` and `src/tools/memory.zig`) so the agent doesn't expect promotion via compose. Today neither tool description mentions the tier-3 contract.

### INFO-2: First-commit conflict-marker condition (`seen_count == 2`) was correct intent; CR-02 changing to `seen_count > 1` is not strictly an improvement

**File:** `src/zaki_state.zig:2509` (after CR-02 + LR-03).

The commit-message rationale for CR-02 ("a key updated a third time after user resolution would never re-surface") assumes `seen_count` keeps climbing. It does not — once promoted, the CASE clause never increments again (because stored.session_id is NULL post-promotion), and on non-promoted rows it freezes at whatever value triggered promotion. So `seen_count > 1` and `seen_count == 2` are functionally equivalent for the post-promotion case (both fire), and only differ for the pre-promotion case (which is a single transition). The change is not harmful, but the commit message slightly misreads the SQL behavior.

This becomes material only after CRITICAL-1 is fixed AND if the team decides whether `seen_in_session_count` should reset on promotion (the deferred LR-03 in `b4b77d1`).

### INFO-3: Three operator cron jobs claimed in commit message do not exist in the repo

**Source:** `58e064b` commit body says "3 operator cron jobs (memory-nightly-distill, memory-session-flush, memory-weekly-prune) as backup catch-up layer".
**Verified:** `grep -rn "memory-nightly\|memory-session-flush\|memory-weekly" src/ config*.json` → no hits.

The `maintenance` job-kind plumbing is in place (schedule.zig:24, :103-108, :294-315) and tested at the schedule.zig unit level, but no jobs actually use it yet. Either the operator is expected to define them externally, or this is a partial ship and the seed jobs were dropped before commit. Either way, the commit message overstates what landed.

### INFO-4: `insertEpisodeEvent` payload truncation is UTF-8 safe but emits empty `summary` on certain edge cases

**File:** `src/zaki_state.zig:2640-2645` (LR-02 fix).

The boundary walk `while (end > 0 and summary[end] & 0xC0 == 0x80) end -= 1` correctly retreats past UTF-8 continuation bytes. Edge case: a 2049-byte payload whose byte at index 2048 is a continuation byte (0x80–0xBF) and where every byte from 0..2048 is also a continuation byte (impossible for valid UTF-8, but possible for adversarial input or corrupted text) walks `end` to 0 and emits `summary[0..0]`. The `jsonString` of an empty slice is `""`, which is valid JSON, so the postgres ::jsonb cast won't fail — it just records an episode event with no summary content. This is acceptable degradation; not a bug, but worth a one-line comment that the empty-summary case is intentional. (Compare to `memory_loader.truncateUtf8` which has the same property.)

---

**Summary of required-before-ship items:**
1. **CRITICAL-1** — preserve `memory_type='core'` and `session_id=NULL` across upsertMemory ON CONFLICT writes (Option A: CASE-guard the SET clause). MUST ship with a PG smoke test that writes A → B → C and asserts the row stays core.
2. **WARNING-1** — add `"pending_conflicts"` to `BRAIN_HIDDEN_EXACT_KEYS` so the sentinel doesn't leak to /brain/graph.

The other findings can land as follow-ups; they don't block.

— signed by the V1.7 parallel-agent reviewer, 2026-05-02.


---

## Nullclaw Cherry-Pick WIP Review

**Reviewed:** 2026-05-02
**Reviewer:** Claude (gsd-code-reviewer style, depth=deep)
**Files reviewed:** 13 (9 modified, 4 new)
**Verdict:** **BLOCK** — three test failures and two correctness gaps must be fixed before commit.

### Build + Test Results (vs baseline 5727 passed)

- **`zig build -Dengines=all`:** PASS (clean, zero output)
- **`zig build test -Dengines=all`:** **FAIL** — 5805/5808 passed, **3 failed**, 41 skipped
  - Net delta: +78 new tests added (+81 attempted), but 3 stale tool-count assertions break
  - All 3 failures are in `src/tools/root.zig` (lines 2142, 2159, 2287): hardcoded tool counts (`35`, `31`, `31`) need to become `38`, `34`, `34` because `calculator + file_read_hashed + file_edit_hashed` are now in `allTools`. Trivially fixable; comments above each assertion also need updating.
  - The fourth log line ("bootstrap.integration_test … the following test command failed") is **not** an independent failure — it is the next test in the same compiled binary that didn't get to run after the tools/root tests halted execution. Build summary line confirms: `5802/5846 tests passed; 41 skipped; 3 failed`.

### Cross-Repo Verification (re: nullclaw source)

The user said the parent codebase is `nullclaw` at `/Users/nova/Desktop/claude-code/`. That path is a **TypeScript** project (`package.json`, `bun.lock`, `tsconfig.json`, `src/` is TS). It is not the Zig source these files were cherry-picked from. Searched siblings (`nullalis-research`, `nullalis-prod`, `nullalis-sprint3`) — none contain `calculator.zig`, `teams.zig`, or `file_read_hashed.zig`. **Cannot do byte-level cherry-pick comparison.** Reviewed on intrinsic Zig correctness instead and noted divergences below where the nullclaw shape can be inferred.

---

### CRITICAL — must fix before commit

#### CR-WIP-01: Three tool-count tests fail [BLOCK]
- **Files:** `src/tools/root.zig:2142, 2159, 2287`
- **Issue:** New tools added to `allTools` (lines 1000–1009) without updating the count assertions in the existing tests.
- **Fix:** Bump `35 → 38` and both `31 → 34`. Update the comments at 2139-2141, 2154-2158, 2285-2286 to mention `+ calculator + file_read_hashed + file_edit_hashed`. Also add membership tests like the existing `cron_add` / `pushover` style — currently the new tools have execute-level tests but no "is in `allTools`" guard, so a future regression would silently drop them.

#### CR-WIP-02: Teams channel is dead code (not wired) [BLOCK]
- **File:** `src/channels/teams.zig` (entire file) + `src/channel_catalog.zig:25,64,86,108,131`
- **Issue:** `TeamsChannel` is exported, the build flag `-Dchannels=teams` exists, the config block parses, but **nothing instantiates it**. Every other channel (signal, telegram, maixcam, line, …) is started in `src/channel_manager.zig` — search for `TeamsChannel` in that file returns zero hits. End result: a user sets `channels.teams` in their config, the catalog reports the count, but the bot never connects to Teams. The 666-line file ships unreachable.
- **Fix (pick one):**
  1. Wire it up in `channel_manager.zig` alongside signal/maixcam (preferred — the implementation looks complete).
  2. Hold the file in a feature branch; do not commit.
  3. If shipping now, gate every export behind `if (build_options.enable_channel_teams)` AND add a bold `// EXPERIMENTAL — not yet started by channel_manager` banner.
- **Per memory `feedback_scope_before_delete.md` and `project_subtraction_decisions.md`:** the project's discipline is "either fully landed or flag-gated", never "live but stubbed".

#### CR-WIP-03: `last_executed_tool` is a borrowed slice that may dangle across turns [BLOCK or downgrade with note]
- **File:** `src/agent/root.zig:421, 1981, 2975-2978`
- **Issue:** `self.last_executed_tool = call.name;` borrows from `ParsedToolCall.name`, which is allocated in `iter_arena` inside `runTurn` (line 2949) and **freed at turn end via `defer iter_arena.deinit()`**. The field is never reset between turns. Path that triggers UAF / garbage string in cancel reply:
  1. Turn N runs a tool; `last_executed_tool` points into turn N's arena.
  2. Turn N completes, arena is freed; the slice now points to reusable memory.
  3. Turn N+1 starts; cancellation token fires **before** any tool runs in N+1.
  4. Line 2975-2976: `allocPrint("[Cancelled: last tool was {s}]", .{self.last_executed_tool})` reads freed memory — best case prints garbage, worst case page-faults.
- **Fix:** Either (a) reset `self.last_executed_tool = ""` at the top of `runTurn`, or (b) on assignment, free the prior copy and `dupe` into `self.allocator`. (b) preserves the cross-turn "what tool last ran" semantic; (a) is simpler and matches what the field name suggests (current turn).
- **Why this didn't trip the test suite:** no test currently exercises "cancel a fresh turn that follows a turn with tool calls". Fragile.

---

### WARNING — fix before merge

#### WR-WIP-01: `delegate.zig` system-prompt resolution path leaks on every call
- **File:** `src/tools/delegate.zig:94-119`
- **Issue:** `base_sys_prompt` is freed via `defer`, then `sys_prompt` is built from it and *also* freed via `defer`. This is correct *if* `system_prompt` is then dupe'd by the downstream consumer. But: the `base_sys_prompt` block also dupes the inline `ac.system_prompt` (line 105) into a fresh allocation, only to free it 12 lines later — a useless allocation/free pair on every delegate invocation. Cheap to fix:

  ```zig
  // Use a slice that may or may not need freeing:
  var base_owned: bool = false;
  const base_sys_prompt: []const u8 = blk: {
      if (ac.system_prompt_path) |spp| {
          base_owned = true;
          break :blk std.fs.cwd().readFileAlloc(allocator, spp, 1024 * 1024) catch |err| {…};
      }
      break :blk ac.system_prompt orelse "You are a helpful assistant. Respond concisely.";
  };
  defer if (base_owned) allocator.free(base_sys_prompt);
  ```

- **Severity rationale:** correctness is OK (no leak, no UAF — defers match), but the design wastes one allocation per call, and the `system_prompt` happy path adds a `dupe` that the original code didn't need. Style-only if you don't care, but it's the kind of thing the review bar would flag.

#### WR-WIP-02: `delegate.zig` `system_prompt_path` failure path leaks
- **File:** `src/tools/delegate.zig:96-103`
- **Issue:** When `readFileAlloc` fails, the error path calls `std.fmt.allocPrint(... ) catch return ToolResult.fail("Delegation failed")`. If the *outer* `allocPrint` itself fails, the function returns a `ToolResult.fail` carrying a static string `"Delegation failed"`, but: looking at this carefully, the catch only catches the inner `allocPrint`'s error, so on success it returns `ToolResult{ .success = false, .output = "", .error_msg = msg }` — which is correct. The pattern is OK. **Downgrading from initial concern to INFO**: the variable name `msg` is owned and the caller frees `error_msg` per `ToolResult` ownership contract. Not a bug.

#### WR-WIP-03: `file_read.zig` extension table is case-sensitive
- **File:** `src/tools/file_read.zig:38-49`
- **Issue:** `EXTENSION_TYPES` table compared via `std.mem.eql(u8, ext, entry[0])` — `Photo.JPG` returns `"binary file"`. Magic-byte detection still catches PNG/JPEG/etc., so the regression is just the human-readable label. Common practice is to lowercase the extension before comparison.
- **Fix:** Lowercase `ext` into a small stack buffer before the loop, or use `std.ascii.eqlIgnoreCase`.

#### WR-WIP-04: Teams `acquireToken` token-cache replace can leak under specific OOM
- **File:** `src/channels/teams.zig:136-139`
- **Issue:**
  ```zig
  if (self.cached_token) |old| self.allocator.free(old);
  self.cached_token = try self.allocator.dupe(u8, token_val.string);
  ```
  If the `dupe` `try` errors, `self.cached_token` has already been freed — but the field still points at the freed memory. Subsequent `getToken()` calls read `self.cached_token` (line 147: `if (self.cached_token) |token|`), which is non-null but dangling. Standard fix: dupe first, then free old.
  ```zig
  const new_tok = try self.allocator.dupe(u8, token_val.string);
  if (self.cached_token) |old| self.allocator.free(old);
  self.cached_token = new_tok;
  ```
  Identical pattern to fix in `loadConversationRef` lines 310-311 and 316-317 (`conv_ref_service_url` / `conv_ref_conversation_id`).

#### WR-WIP-05: Teams `cachePlaceholder` evict-and-shift while holding the new entry creates duplicate-target eviction race
- **File:** `src/channels/teams.zig:432-438`
- **Issue:** When the cache is full, the eviction loop frees `placeholder_entries[0]`, shifts all entries down, then appends. But if `cachePlaceholder` is called twice concurrently with the same target after the cache is full, the "replace existing entry" loop at 410-418 won't find the duplicate because the duplicate is being created in this branch. Result: two entries with the same target, and the next `takePlaceholder(target)` returns the older one while the newer leaks. Mutex prevents simultaneous execution, but the design is fragile.
- **Fix (optional polish):** The "Replace existing entry" path at 410-418 isn't reached for cache-full evictions because it's above the second loop. Move it inside a unified scan-then-insert helper, or change the second `for` (at 426-431) to also check for target match.
- **Severity:** The mutex makes this *not* a concurrency bug, just a maintenance hazard. Tests pass.

#### WR-WIP-06: `file_edit_hashed` hint compensation under-compensates for extreme drift in tail
- **File:** `src/tools/file_edit_hashed.zig:188-200`
- **Issue:** When start drifts by more than RADIUS (50) lines and the end_target's adjusted hint also lands more than RADIUS away from the real position, the hash search returns `not_found` even though the line exists. This is by design (drift > 50 is treated as a stale read), but the error message ("Hash mismatch for end target. Context changed.") doesn't say "drift exceeded ±50; re-read file". Add that hint to the message so the LLM knows what to do.
- **Severity:** UX, not correctness.

---

### INFO — nice-to-have

#### IN-WIP-01: `getArray` helper added but `getInt` already exists nearby
- **File:** `src/tools/root.zig:54-60`
- **Note:** Good addition, mirrors `getString`/`getBool`/`getInt`. No issue.

#### IN-WIP-02: `calculator.zig` is high quality — covers regressions in tests
- **File:** `src/tools/calculator.zig` (54 tests)
- **Note:** Test bodies explicitly call out regressions ("used to double-free the values buffer", "used to ignore values past 1024 items", "used to surface 'inf' instead of a failed tool result"). Inferred provenance: this is a port of mature code from the parent. Tests look complete; allocator hygiene verified (`errdefer free(values)`, single ownership of `result.output`). No bugs found.

#### IN-WIP-03: `file_read_hashed.zig` FNV-1a hash with parent context is sensible
- **File:** `src/tools/file_read_hashed.zig:16-25`
- **Note:** 12-bit hash → 4096 buckets per parent → birthday collision risk when files have ~75 lines with the same parent (50% collision at √4096 ≈ 64). Tests already exercise the ambiguous-collision path. The existing `RADIUS=50` window combined with the parent prefix makes this practically robust for typical edits, but **flag in the tool description that very repetitive files (CSV, generated boilerplate) may produce ambiguous matches more often.** Already mentioned in the description.

#### IN-WIP-04: Teams test for `cachePlaceholder` evict-when-full doesn't assert eviction order
- **File:** `src/channels/teams.zig:747-783`
- **Note:** Test calls eviction `cachePlaceholder("target-overflow", "overflow")` after filling, then asserts `target-1` is still gettable. But the FIFO eviction logic frees `entries[0]` (i.e., `target-0`), so `target-1` *should* survive — the test is right. But the test never asserts `target-0` is gone (the supposed eviction victim). Add `try std.testing.expect(ch.takePlaceholder("target-0") == null);` to lock the FIFO behavior.

#### IN-WIP-05: `config_types.zig` `TeamsConfig` has 4 required string fields without defaults
- **File:** `src/config_types.zig:621-630`
- **Note:** `client_id`, `client_secret`, `tenant_id` are non-optional and have no default. If a user writes `"teams": [{}]` in config.json, parsing into this struct would fail with `error.MissingField` from `std.json.parseFromValue`. Fine — but verify `config_parse.zig` actually parses Teams entries and surfaces a clean error message. **Critical: I see no `cfg.channels.teams` parsing logic in `config_parse.zig`.** Consequence: even if Teams were wired up, config parsing would silently leave the teams array empty. Adds to the CR-WIP-02 verdict — Teams is **not actually accessible to users yet**.

#### IN-WIP-06: V1.6 / V1.5 invariants — clean
- **Diff scope of `agent/root.zig` is 8 lines**, all in cancellation handling. Does NOT touch:
  - `extraction_state_mgr` or `extraction_user_id` (V1.6 5b.3 fields, lines 371/374) — preserved
  - sub-agent inheritance at line 874-875 — preserved
  - byte-stable prefix building (lines 2668, 2764) — preserved
  - `elideUnverifiedHistory` (line 4476) — preserved
  - compaction force-compress path — preserved
- The cherry-pick correctly only adds; it doesn't conflict with V1.6 commit 6.

#### IN-WIP-07: `file_read.zig` binary signatures table is accurate but missing TIFF / BMP / OGG / FLAC / SQLite
- **File:** `src/tools/file_read.zig:14-25`
- **Note:** Common practice covers more formats. Not bugs — additions:
  - TIFF: `II*\x00` or `MM\x00*`
  - BMP: `BM`
  - SQLite: `SQLite format 3\x00`
  - OGG: `OggS`
  - FLAC: `fLaC`
  - Class file: `\xCA\xFE\xBA\xBE`
  Optional follow-up.

---

### Final verdict

**BLOCK as-is.** Two minimal fixes unblock commit:

1. **Update three tool-count assertions** in `src/tools/root.zig` (CR-WIP-01) — 30 seconds of work, zero risk.
2. **Pick a discipline for Teams** (CR-WIP-02): either fully wire it into `channel_manager.zig` + `config_parse.zig` OR move `teams.zig` to a side branch / experimental folder. Shipping a 666-line dead-code channel violates the "scope before delete / no half-built features" rule from `feedback_scope_before_delete.md`.

3. (Recommended same-commit) **Reset `last_executed_tool` at turn start** (CR-WIP-03) — three lines.

Tests `5805/5808 → 5808/5808` after CR-WIP-01. The 78 new tests are high quality; the calculator and hashed-file tools are well-engineered ports. The Teams channel implementation looks faithful and complete; it just isn't wired in.

— signed by gsd-code-reviewer, nullclaw cherry-pick WIP, 2026-05-02.
