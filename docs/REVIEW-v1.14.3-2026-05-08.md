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
