# V1.14.3 — End-to-End Code Review

**Date:** 2026-05-08
**Reviewer:** gsd-code-reviewer subagent + author response
**Branch:** main (uncommitted at review time, will commit after this doc lands)
**Files reviewed:** `src/agent/entity_pipeline.zig`, `src/agent/prompt.zig`, `src/agent/root.zig`, `src/daemon.zig`, `src/tools/wiki_link.zig`
**Closures:** G-03 (episode_key plumbing), G-07 (skill_executions recall block), G-08 (WM-empty fallback)
**Build status:** 5975/6035 tests pass (60 skipped). Same after HIGH-1 fix.

---

## Verdict: **SHIP** (after HIGH-1 fix landed)

Pre-fix verdict was **SHIP-WITH-FIXES**. The reviewer caught one real reachable bug and one over-claimed test contract. Both addressed in this same branch.

---

## Findings

### HIGH-1 — G-08 gate didn't verify identity content. **FIXED.**

**Location:** `src/agent/root.zig:2719`

**Issue (pre-fix):** Gate was `wm_owns_identity = if (turn_wm_block) |b| b.len > 0 else false`. This checks "WM has any content" — but `extraction_persist.promoteSlot` writes `open_loop` / `active_goal` / `recent_entity` slots without requiring an identity slot. So a real reachable scenario:

1. `pinIdentityFromUserState` returns 0 facts (truly empty user, postgres flake at session creation, listIdentityFacts whitespace-only).
2. Extraction promotes a goal/loop slot mid-session.
3. `turn_wm_block` is non-empty → `wm_owns_identity = true` → `skip_legacy_identity = true` → legacy `<active_identity>` is suppressed by `memory_loader.zig:1048`.
4. **Agent prompt has zero identity content.**

This is the exact failure mode G-08's comment claimed to close.

**Fix:** Iterate `set.slots` and check for `slot_type == "identity"`:

```zig
const wm_owns_identity: bool = blk: {
    const set = turn_wm_render_set_opt orelse break :blk false;
    for (set.slots) |s| {
        if (std.mem.eql(u8, s.slot_type, working_memory.SlotType.identity)) {
            break :blk true;
        }
    }
    break :blk false;
};
```

Plus comment updated to honestly describe the fix and the failure mode it closes. ~10 lines.

### MEDIUM-1 — G-08 test scope was overclaimed. **FIXED.**

**Location:** `src/agent/prompt.zig:1834`

**Issue (pre-fix):** Test title said "_legacy identity must take over upstream_" but the test exercises only `buildVolatileSystemPrompt` rendering behavior — it does not exercise the `wm_owns_identity` gate in root.zig. A `wm_owns_identity` regression would not be caught by this test.

**Fix:** Renamed to `"buildVolatileSystemPrompt G-08: empty working_memory_block omits the <working_memory> tag"`. Added a SCOPE comment block explaining what the test does and does not cover, and pointing future readers at root.zig's HIGH-1 fix as the load-bearing closure.

A real integration test of `Agent.chatTurn` against a slots-without-identity state-manager fixture would be ideal, but is out-of-scope for V1.14.3. Filed as a V1.15 follow-up (see "Open follow-ups" below).

### MEDIUM-2 — Daemon's empty-string-to-null pre-coercion is redundant. **NO CHANGE.**

**Location:** `src/daemon.zig:1226`

**Note:** `upsertMemoryEdgeRich` already coerces empty-string to NULL (MD-02 fix at `zaki_state.zig:6843`). The daemon's pre-coercion is defensive duplication, not load-bearing.

**Decision:** Leave as-is. Defense in depth is fine; the comment is now corrected to call out that this is defensive, not necessity. No code change.

### LOW-1 — G-07 prompt language slightly overclaims per-skill recall. **NO CHANGE.**

**Location:** `src/agent/prompt.zig:792`

**Note:** Brain briefing reads "_The most-recent 3 traces for the active skill render in your volatile prompt_". Reality is `GENERIC_SKILL_NAME` (the only skill today). The internal code comment at root.zig:2809 acknowledges this.

**Decision:** Acceptable today since `GENERIC_SKILL_NAME` IS the active skill. Will tighten when V1.15+ adds per-skill detection. No change for V1.14.3.

### LOW-2 — Memory-safety walkthrough confirmed clean (positive finding)

The reviewer traced the G-08 hoisting carefully:
- Function-scope defers at root.zig:2708 + 2717 own the lifetime
- Inner-scope `wm_block` alias is a borrowed copy of the optional slice header
- Prompt is fully built (memcpy'd into `full_system`) before inner scope ends
- OOM paths cleanly unwind via function-scope defers

No double-free, no use-after-free, no leak. Mechanically clean.

### LOW-3 — `procedural_memory.loadForRender` `catch &.{}` idiom is safe (informational)

`Allocator.free` on zero-length slices is documented safe in Zig 0.14+. Pattern is established codebase-wide.

### LOW-4 — G-03 plumbing is clean and complete (positive finding)

`ExtractionJob.session_id` allocator-owned, freed via `job.deinit` at daemon.zig:1184. `runOnTurn` returns synchronously; job outlives the call. The slice is `dupeZ`'d locally inside `upsertMemoryEdgeRich`. `array_append IF NOT ANY` at zaki_state.zig:6796-6797 makes re-runs idempotent.

---

## Tests added in this branch

1. `prompt.zig` — "G-07: skill_traces_block renders after memory_slot" — ordering + presence
2. `prompt.zig` — "G-07: skill_traces_block omitted when null" — negative case
3. `prompt.zig` — "G-08: empty working_memory_block omits the <working_memory> tag" — rendering invariant only (NOT the upstream gate)

Test count delta: **+3** from V1.14 baseline (5972 → 5975 passing; 6032 → 6035 total).

---

## Booth-week stability addendum

- All three closures are read-side (G-07) or additive plumbing (G-03, G-08). No write-path changes. Rollback risk minimal — `git revert` is clean.
- G-07 adds 1 query per turn (`listRecentSkillExecutions`). Indexed (`idx_skill_exec_user_time`); cheap. Flag for post-booth profiling if turn-latency variance changes.
- G-08 HIGH-1 fix removes a real (low-frequency) hole. Net safety improvement.

---

## Open follow-ups

| ID | Item | Tier | Notes |
|---|---|---|---|
| F-1 | Integration test: `Agent.chatTurn` with slots-without-identity fixture asserting prompt contains identity | V1.15 | Real coverage for the G-08 gate; out of scope for V1.14.3 |
| F-2 | Per-skill detection in `procedural_memory.captureSession` | V1.15 | Today: GENERIC_SKILL_NAME for everything. Refine when skill_registry tool calls become detectable. |
| F-3 | G-12 PII scrubbing admin CLI | V1.15 | Legal/GDPR for B2C launch. Tier-2 close-forever item from triage. |

---

## Files changed

```
src/agent/entity_pipeline.zig |  33 +++++++++--    G-03
src/agent/prompt.zig          | 122 +++++++++++++  G-07 + G-08 tests
src/agent/root.zig            | 145 +++++++++++++  G-07 + G-08 (HIGH-1 fix)
src/daemon.zig                |   9 +++           G-03 caller
src/tools/wiki_link.zig       |   7 +++           G-03 caller
docs/REVIEW-v1.14.3-2026-05-08.md  +200          this doc
```

Verdict: **SHIP.**

---

## Second-pass review (2026-05-09)

**Scope:** Verify the HIGH-1 + MEDIUM-1 fixes landed correctly post-commit `18da32c`, and surface anything the first pass missed. No code modifications. All findings cite post-commit line numbers.

### Verification of HIGH-1 fix

- **String-constant agreement: CONFIRMED.** `working_memory.SlotType.identity = "identity"` at `src/agent/working_memory.zig:59` is the single canonical reference. Writers (`pinIdentitySlot` at line 327, `pinPersonaSlot` at line 346, `extraction_persist.predicateToSlotType` at lines 899-911 via `working_memory.SlotType.*`) all reference the constant — no string literal drift. Reader gate at `src/agent/root.zig:2739` uses the same constant. Zero risk of silent fail-open from string mismatch.

- **`set.slots` is the right collection: CONFIRMED.** `RenderSet` at `src/agent/working_memory.zig:99-105` exposes `slots: []WorkingMemorySlot` as the only field. There is no parallel "entries" or pre-render filter. `loadForRender` (lines 111-147) returns either the full list (≤10) or a copy of the top-N from the SQL ordering — no filter that drops `slot_type=identity` rows.

- **`working_memory` import already present: CONFIRMED.** `pub const working_memory = @import("working_memory.zig");` at `src/agent/root.zig:78`. No new import needed.

- **Pinned-vs-unpinned distinction: NO HIDDEN HOLE.** `pinIdentitySlot` always writes `pinned=true` (line 331), `pinPersonaSlot` likewise (line 351). The reader gate ignores the `pinned` field and matches purely on `slot_type == "identity"`. Even if a future writer pinned an identity slot with `pinned=false` (unlikely; nothing today does this), the gate would still recognize it. Conversely, persona slots are typed `identity` (per the comment "persona is conceptually identity-class") which means the gate accepts persona-only as identity coverage. That matches the documented architectural contract that slots 0+1 are both identity-class.

- **No silent drop between DB and `set.slots`: CONFIRMED.** `listWorkingMemorySlots` at `src/zaki_state.zig:7264-7336` orders by `pinned DESC, (importance × exp(-age/3600)) DESC LIMIT 15`. The render set takes top-10 from those 15. Identity is always pinned and importance=1.0, so it sorts to position 0 deterministically — never trimmed.

- **Session-handoff race: NOT A RACE.** `pinIdentityFromUserState` is called synchronously inside `getOrCreateInternal` (`src/session.zig:386`) BEFORE the session is added to the map (line 393). Subsequent turns that resolve the session via `getOrCreate` see the pinned identity slot already in postgres. No goroutine/thread interleaving. The first pass's "race concern" is unfounded.

### Verification of MEDIUM-1 fix

- **Renamed test scope is honest: CONFIRMED.** `src/agent/prompt.zig:1834` test title now reads "G-08: empty working_memory_block omits the <working_memory> tag" — purely a rendering-invariant claim. The embedded SCOPE comment block (lines 1835-1849) explicitly disclaims the upstream-gate contract and points readers to root.zig HIGH-1 fix. No new false claim.

- **Test asserts the inverse case (Case C): NICE TOUCH.** Lines 1873-1885 verify a populated `working_memory_block` actually emits the tag — defends against trivial-pass regression where the tag is never emitted under any condition. The first pass did not flag this; it's just a positive observation.

- **Minor:** Test Case B uses `working_memory_block = ""` but production never produces an empty-string value (root.zig wraps `set.slots.len == 0 → break :blk null`). Harmless extra coverage; flagging only as informational.

### G-07 token-cost contribution (asked-for analysis)

- **Per-turn cost: 1 SQL roundtrip + ≤3 traces × ~250 bytes prompt.** `listRecentSkillExecutions` at `src/zaki_state.zig:7715-7797` issues `WHERE user_id=$1 AND skill_name=$2 ORDER BY created_at DESC LIMIT 3`. The index `idx_skill_exec_user_time(user_id, skill_name, created_at DESC)` at `src/zaki_state.zig:1691` is a perfect prefix-match — index-only scan possible if PG decides to. Author's claim "indexed; cheap" is correct.

- **Skill-name cardinality concern: ACKNOWLEDGED.** Today every row has `skill_name = "generic_multi_tool"` (writer at procedural_memory.zig:151), so the second index column has cardinality 1 per user. This means the index degenerates to `(user_id, created_at DESC)` effectively. **It still works** — the planner can still satisfy ORDER BY via the index. When V1.15+ adds per-skill detection (F-2), cardinality grows naturally. No action.

- **Render budget:** `procedural_memory.renderBlock` (lines 81-115) emits `<recent_skill_traces skill="..." count="N">` plus 3 lines per trace × 3 traces ≈ 12 lines × ~80 chars = ~960 bytes. Fits easily inside the volatile-block budget. Steps_executed JSON is truncated to 200 chars (line 108) per trace.

### G-03 idempotency claim (asked-for verification)

- **Confirmed:** `src/zaki_state.zig:6794-6798`:
  ```sql
  episodes = CASE
    WHEN $9::text IS NULL THEN memory_edges.episodes
    WHEN $9::text = ANY(memory_edges.episodes) THEN memory_edges.episodes
    ELSE array_append(memory_edges.episodes, $9::text)
  END
  ```
  Dedup is by **exact-string match** on the full `episode_key` (not prefix, not normalized). Re-running the same job (same `session_id` → same episode_key) is a true no-op on the array. Different sessions producing the same edge → both episode_keys append, by design (correct provenance semantics).

- **Empty-string guard:** Daemon coerces `job.session_id.len == 0 → null`; upsert further treats `episode_key == null or ep_text.len == 0` as null param ($9 IS NULL), which the CASE handles in branch 1 (no-op on episodes). Defense in depth; both layers correct.

### Test coverage of HIGH-1 itself (asked-for analysis)

- **The gate logic is NOT directly tested.** The G-08 test in prompt.zig is rendering-only by design (per MEDIUM-1 fix). There's no integration test that drives root.zig::generateTurn with a fixture state-manager returning slots-without-identity and asserts the legacy `<active_identity>` block fires. F-1 in Open follow-ups names this gap honestly.

- **Indirect coverage:** `working_memory.zig` test "renderBlock includes pinned identity" at line 442+ confirms `slot_type == "identity"` round-trips through the render path. `listWorkingMemorySlots` is exercised by integration tests in zaki_state.zig. The string-constant chain has unit-level coverage; the **gate flag** does not. Booth-week ship-bar tolerates this gap because (a) failure mode is silent prompt-degradation not crash, (b) HIGH-1 was caught and fixed in code-review, (c) the pre-V1.14.3 4-condition gate was strictly broader (always returning true when infrastructure present), and the V1.14.3 gate is strictly narrower with safe fallback. Net regression risk: zero. Net safety: better.

### Documentation drift (spot-checked 4 cited locations)

- Doc says HIGH-1 at root.zig:2719 → comment block actually starts at 2719; the literal `const wm_owns_identity` is at 2736. **OK** — citation points to the comment-block opening; defensible.
- Doc says MEDIUM-1 at prompt.zig:1834 → test starts at line 1834. **EXACT.**
- Doc says LOW-1 at prompt.zig:792 → brain-briefing line is at 792. **EXACT.**
- Doc says MD-02 fix at zaki_state.zig:6843 → empty-string guard line is 6843. **EXACT.**

No drift requiring correction.

### New findings (things first pass may have missed)

- **NEW-INFO-1 (informational, no action):** `pinIdentityFromUserState` returns `0` for both `listIdentityFacts` postgres-error path AND the truly-empty path (line 372-377 in working_memory.zig). The session caller cannot distinguish. With the HIGH-1 fix this is **safe** (gate falls back to legacy `<active_identity>` either way), but it does mean a postgres-flake at session-create silently degrades to legacy-identity for the entire session lifetime. Not a bug; not in V1.14.3 scope. Flag for V1.15: consider returning a sum type (`enum { ok: usize, db_err, empty }`) so the caller can retry on `db_err`.

- **NEW-INFO-2 (informational, no action):** The defer pattern at root.zig:2698 — `defer if (turn_wm_render_set_opt) |s| s.deinit(self.allocator);` — captures `s` by value. `RenderSet.deinit` takes `*const Self`. The auto-deref `(&s).deinit(...)` operates on the deferred-frame copy of the struct, but the inner slice header still points at allocator-owned memory. Free is correct. Pattern is identical to the prior in-block usage at the original (now deleted) wm_render_set lines, and matches conventions used elsewhere in the codebase. No issue; flagging because the lifetime narrative warrants confirmation.

- **NEW-INFO-3 (informational, no action):** All three new test-builder calls in prompt.zig use `.workspace_dir = "/tmp/nonexistent"`. Reading the buildVolatileSystemPrompt body suggests workspace prompt-file scanning is failure-soft when the dir doesn't exist. Confirmed: tests that use this idiom already pass (5975 passing). No portability concern (e.g., on macOS `/tmp` exists; nonexistent subdir is the actual test).

- **No latent bugs found.** No memory-safety, lifetime, or correctness issues beyond what the first pass caught.

### Pushback / disagreement

- **First-pass MEDIUM-2 severity: AGREE WITH NO-CHANGE DECISION, but the severity might better be LOW.** The daemon's empty-string→null pre-coercion is genuinely defensive given that `upsertMemoryEdgeRich`'s param-binding logic already handles it (zaki_state.zig:6843). Two layers of guard with the same effect is fine for booth-week — but if any future refactor moves either layer, the duplication could rot into "looks redundant, delete one, miss the other was the actual safety net" territory. Mitigation: the daemon's comment at line 1222-1225 explicitly cross-cites MD-02. Reasonable. Recommend leaving as-is per author's decision; severity LOW would be more honest than MEDIUM.

- **First-pass LOW-1 (G-07 prompt language overclaim): AGREE.** The brain-briefing language "the most-recent 3 traces for the active skill" is technically misleading today — there is exactly one skill, GENERIC_SKILL_NAME. But the agent can't tell the difference between "active skill" and "generic skill" today, and the language reads correctly to the agent. Tightening pre-V1.15 would be churn for no behavioral change. Author's decision to defer is correct.

### Booth-week ship judgment

The committed branch is **production-ready for booth-week**. HIGH-1 fix is mechanically correct, well-commented, and the failure mode it closes is real-but-low-frequency. MEDIUM-1 is honest scope-shrinking with the integration gap honestly filed as F-1. G-03 plumbing is clean end-to-end. G-07 token cost is bounded and indexed. No new latent bugs surfaced.

The author has been refreshingly honest about the F-1 coverage gap. The first pass's verdict (SHIP after HIGH-1) was correct; this second pass confirms.

### Final verdict: **SHIP**

No blockers. No follow-up work required pre-booth. Recommend tracking F-1 (HIGH-1 integration test) and the NEW-INFO-1 sum-type refactor for V1.15.

---

_Second-pass review by gsd-code-reviewer (Claude Opus 4.7, 1M context). 2026-05-09._
