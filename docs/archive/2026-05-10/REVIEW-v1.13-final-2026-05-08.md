---
phase: v1.13-final-merge-readiness
reviewed: 2026-05-08T00:00:00Z
depth: deep
branch: v1.13/brain-elevation
head: 5619f94d25bd82a48cee9eb86d23c8d5b0bcc62e
review_window: 78cff2c..5619f94
files_reviewed: 7
files_reviewed_list:
  - src/agent/dream.zig
  - src/agent/prompt.zig
  - src/agent/memory_loader.zig
  - src/agent/root.zig
  - src/agent/commands.zig
  - src/agent/procedural_memory.zig
  - src/agent/working_memory.zig
findings:
  critical: 1
  high: 2
  medium: 3
  low: 2
  total: 8
status: issues_found
build: clean (zig build, zig build test exit 0)
recommendation: BLOCK MERGE on CR-01 (DUP-1 fresh-session identity loss). Other findings can land as follow-ups.
---

# V1.13 Final Merge-Readiness Review

**Reviewed:** 2026-05-08
**Branch:** `v1.13/brain-elevation`
**HEAD:** `5619f94`
**Diff window:** `78cff2c..5619f94` (3 commits since Day 2-4 review)
**Status:** issues_found — one CRITICAL blocker

## Summary

Three commits added since the Day 2-4 review:
- `59bed41` — radical dream simplification (drops runDreamCycle, persistDreamLog, loadRecentTranscript, DreamResult, Provider import)
- `39422ba` — re-add dream entry point + 4-tier prompt cache reorder + new ~150-line `buildBrainArchitectureSection`
- `5619f94` — DUP-1 fix: opts-bag variant of `loadTurnMemorySlot` with `skip_legacy_identity` flag

Build is clean (`zig build` + `zig build test` exit 0). The simplification is sound — the dropped dream symbols have no remaining callers anywhere in the tree, and existing positional callers of `loadTurnMemorySlot` are preserved via a wrapper. Cache-tier reorder rationale is correct, ordering tests still hold.

**However: the DUP-1 fix has a fresh-session race condition that erases identity from the prompt entirely on turns 1..N until extraction promotes a non-identity slot.** The fix correctly suppresses the legacy `<active_identity>` block when WM infrastructure is wired, but Working Memory has zero identity slots on a fresh session because **`pinIdentitySlot` and `pinPersonaSlot` are never called by anything in the codebase**. The slots stay empty until extraction fires (turn 3+), and even then extraction's `predicateToSlotType` (extraction_persist.zig:818) only promotes open_loop / active_goal / decision / emotional / temporal — **never identity**. Net effect on a postgres-wired session: identity context is lost for the lifetime of the session. The fallback intent in the comment ("falls back to legacy when WM infra is missing") does NOT cover this case — the fallback only triggers on missing infrastructure, not on empty slots.

This is the smoking gun the review prompt anticipated. Filing as CRITICAL.

---

## CRITICAL

### CR-01: DUP-1 fix erases identity on every postgres-wired session — `pinIdentitySlot` has zero callers

**Files:**
- `src/agent/root.zig:2668-2684` (gate condition)
- `src/agent/memory_loader.zig:1043-1054` (skip logic)
- `src/agent/working_memory.zig:316-352` (`pinIdentitySlot` / `pinPersonaSlot` — uncalled)
- `src/agent/extraction_persist.zig:782-801` (`predicateToSlotType` — never produces identity)

**Issue:**

The DUP-1 fix turns off the legacy `<active_identity>` block whenever postgres + tenant + session are wired:

```zig
// root.zig:2668
const wm_owns_identity: bool = self.extraction_state_mgr != null and
    self.extraction_user_id != null and
    self.memory_session_id != null;
```

The intent is "Working Memory's `<working_memory>` block already covers identity, so don't double-emit." But this assumes Working Memory actually contains identity slots. It does not.

**Trace of the failure window:**

1. **Session starts, WM is empty.** `state_mgr.listWorkingMemorySlots(...)` returns `[]`. Nothing in the system has called `pinIdentitySlot` or `pinPersonaSlot` to seed slot 0/1.
2. **Turn 1 enrichment runs.** `loadTurnMemorySlotOpts` is called with `skip_legacy_identity = true` (all three gate conditions pass).
3. Inside `loadTurnMemorySlot` the `if (!opts.skip_legacy_identity)` guard skips `buildActiveIdentityBlock` — no `<active_identity>` injected.
4. **Back in root.zig:2755-2772**, `working_memory.loadForRender(...)` returns slots (empty). `wm_block` becomes `null` because `if (set.slots.len == 0) break :blk null`.
5. **The volatile prompt has no identity at all.** The agent does not know who the user is.
6. **Turns 2..N:** identical. Extraction runs every 3 turns. When it does fire, `predicateToSlotType` (extraction_persist.zig:818) maps NAME / IS / IS_A / WORKS_AT / etc to ... nothing. It only returns slot types for: open_loop predicates (TODO, WILL_DO, ...), active_goal (WORKING_ON, BUILDING, ...), decision (DECIDED, CHOSE), emotional, recent_entity, relationship, temporal. **Identity facts pulled from the canonical store NEVER promote into a WM slot**, even after extraction.
7. **Net effect:** the session never gets identity context in its prompt. Pre-DUP-1, the legacy `listIdentityFacts` query (memory_loader.zig:1231 → zaki_state.zig:4064) was a USER-LEVEL pinned-identity store, keyed only on `user_id`, surfacing cross-session identity from turn 1. The DUP-1 fix removed this safety net without putting anything in its place.

**Verification commands run:**

```
$ grep -rn "pinIdentitySlot\|pinPersonaSlot" --include="*.zig"
src/agent/working_memory.zig:316:pub fn pinIdentitySlot(
src/agent/working_memory.zig:335:pub fn pinPersonaSlot(

$ grep -rn "upsertWorkingMemorySlot" --include="*.zig" src/ | grep -v "zaki_state.zig" | grep -v "working_memory.zig"
(no output)
```

Zero callers, anywhere. Identity slots are never written.

**Severity rationale:** This silently degrades every postgres-wired session — the very configuration the fix was meant to optimize. The agent loses cross-session identity continuity (user name, agent identity, persona summary) which is the exact regression the legacy `<active_identity>` block was added to prevent (V1.8-9). The `~500B-2KB savings per turn` claimed in the commit message is vastly outweighed by losing the foundational user-identity anchor.

**Fix (pick one — A is recommended):**

**Option A — Tighten the gate to "WM has identity slots."** Pre-load WM slots before the gate, only skip legacy if at least one slot of `slot_type == "identity"` is present:

```zig
// In root.zig before computing wm_owns_identity:
const wm_has_identity_slot: bool = blk: {
    if (self.extraction_state_mgr) |smgr| {
        if (self.extraction_user_id) |uid| {
            if (self.memory_session_id) |sid| {
                const slots = smgr.listWorkingMemorySlots(self.allocator, uid, sid) catch break :blk false;
                defer memory_root.freeWorkingMemorySlots(self.allocator, slots);
                for (slots) |s| {
                    if (std.mem.eql(u8, s.slot_type, working_memory.SlotType.identity)) break :blk true;
                }
            }
        }
    }
    break :blk false;
};
const wm_owns_identity = wm_has_identity_slot;
```

This costs an extra slot fetch but the same fetch happens 50 lines down (`working_memory.loadForRender`). De-dup by passing the loaded slots through (or move loadForRender above and reuse).

**Option B — Wire `pinIdentitySlot` on session start.** Fetch top-K facts via `listIdentityFacts` once when a session begins, persist them into reserved slots 0 and 1. Then the existing gate works as designed. Risk: slot 0/1 stale across long sessions if user identity edits happen mid-session — needs an invalidation hook.

**Option C — Revert the DUP-1 fix.** Keep both blocks emitted; the duplication wastes 500B-2KB but is correct. Land DUP-1 properly in V1.14 with Option A or B. Lowest-risk merge path if landing today is non-negotiable.

**Recommendation:** Option C for this merge (revert DUP-1, file follow-up). The fix is structurally sound; the bug is in an underlying assumption ("WM has identity") that doesn't hold yet. Don't ship a regression to ship a micro-optimization.

---

## HIGH

### HI-01: Brain architecture briefing claims a `nullalis dream` CLI orchestrator that does not exist

**File:** `src/agent/prompt.zig:778-781` (`buildBrainArchitectureSection`)

**Issue:**

The Layer 7 paragraph in the architecture briefing tells the agent:

> "A nightly cron entry runs `nullalis dream --user-id N`. The orchestrator sweeps orphans for re-linking, recomputes importance scores, and writes a `dream_log/<date>` marker."

This contradicts what actually shipped in `dream.zig` (commits 59bed41 + 39422ba). Per the `dream.zig` doc-comment (lines 9-33), Day 5's whole architectural insight is that **there is no orchestrator** — the cron simply fires an agent turn with the `dream_system_prompt` as the user message, and the agent uses its existing tools (`memory_timeline`, `brain_graph`, `memory_recall`, `memory_store`) to reflect.

There is also no `nullalis dream` subcommand:

```
$ grep -rn "\"dream\"\|cmd.*dream\|runDream\|subcommand.*dream" --include="*.zig" src/
(no output)
```

The agent will be told to expect orphan-sweeping + importance-recompute + a marker write that no implementation produces. When asked about Layer 7, it will hallucinate behavior that doesn't exist — the same anti-pattern the briefing's own "Failure-mode honesty" section warns against.

**Fix:**

Rewrite the Layer 7 paragraph to match what actually shipped:

```zig
try w.writeAll("### Layer 7 — Dream cycle (3 AM cron)\n");
try w.writeAll("A nightly cron entry (~/.nullalis/cron.json) fires an agent turn at 3 AM with a reflection prompt. There is no separate orchestrator — the cron runs YOU with a system prompt that asks for a 7-day reflection. You read recent activity via memory_timeline, optionally query brain_graph (action=\"communities\") for cluster discovery, and persist the reflection via memory_store with key=`dream_log/<date>`. You will see prior dream_log entries in memory_timeline as evidence the cycle ran.\n\n");
```

### HI-02: Brain architecture briefing claims `<recent_skill_traces>` renders into the prompt — it doesn't

**File:** `src/agent/prompt.zig:771-773` (Layer 6 paragraph)
**Cross-ref:** `src/agent/procedural_memory.zig:54-67` (`loadForRender` defined but never called)

**Issue:**

The Layer 6 paragraph says:

> "On the next similar invocation, recall the recent traces (top 3) so you build on prior runs instead of starting cold. (Recall block in prompt: future Day 5.2 wiring.)"

The parenthetical hedge is honest, but the surrounding sentence still tells the agent it can "recall the recent traces." Right now nothing renders them:

```
$ grep -rn "procedural_memory.loadForRender\|procedural_memory.renderBlock\|recent_skill_traces" --include="*.zig" src/
src/agent/procedural_memory.zig:12, 71, 78, 92, 112, 196, 200  (all inside the module itself)
```

`procedural_memory.loadForRender` has zero external callers. The traces ARE captured (commands.zig:1531-1553 inserts rows) but nothing surfaces them in the prompt and no tool exposes them. The agent has been told it can "build on prior runs" — it cannot.

**Fix:**

Either (a) wire the render block into the volatile prompt now, parallel to `working_memory_block` (cheap — mirrors lines 2755-2772 for procedural_memory), or (b) tone down the briefing text so it doesn't promise a capability that isn't there:

```zig
try w.writeAll("### Layer 6 — Procedural memory (skill execution traces)\n");
try w.writeAll("Every multi-tool turn (≥5 tool calls) writes a skill_executions row at session end recording what you did, the tool sequence, and outcome quality. These traces accumulate now and will surface in your prompt in a future iteration; until then they are for offline analysis only.\n\n");
```

Choose (a) if Day 5.2 is landing this sprint; (b) if not. Don't ship the current text — it's the same hallucination class the briefing tells the agent to avoid.

---

## MEDIUM

### MD-01: `tool_count_proxy` uses `entries.len` (total messages) — captures procedural traces from non-skill turns

**File:** `src/agent/commands.zig:1541-1553`

**Issue:**

```zig
const tool_count_proxy: u32 = @intCast(@min(entries.len, std.math.maxInt(u32)));
if (tool_count_proxy >= procedural_memory.CAPTURE_TOOL_THRESHOLD) {  // 5
    ...
    _ = procedural_memory.captureSession(..., tool_count_proxy);
}
```

`entries.len` counts ALL messages (system + user + assistant + tool). A casual 3-turn conversation reaches 6+ entries with zero tool calls and still triggers a "procedural memory" capture. The captured row gets `outcome_quality` derived from `total_tool_calls / 20.0` (procedural_memory.zig:146) — so a 6-message chat scores 0.50, the floor. The skill_executions table fills with junk that has no procedural value.

The comment acknowledges this ("heuristic proxy until session-wide counter ships"), but still ships it. The threshold should gate on actual tool_call count or this gets disabled until the counter exists.

**Fix (pick one):**

(a) Track tool calls per session. Most agent runtimes already have counters — wire one in.

(b) Until the counter ships, gate on a more conservative proxy: count assistant messages whose content contains tool-call markers, or simply guard on `entries.len >= 15` so casual chats don't qualify.

(c) Disable capture entirely until the counter ships (early return). The render path doesn't exist yet anyway (HI-02), so capturing junk now provides zero value.

Recommend (c) for this merge — the data has no consumer yet. Don't pollute `skill_executions` with mis-tagged rows that future Day 5.2 work will have to filter or delete.

### MD-02: Brain architecture briefing claims auto-promotion predicates that may not all map

**File:** `src/agent/prompt.zig:752` (Layer 0 paragraph)

**Issue:**

The briefing tells the agent:

> "Auto-promotion fires on extraction: predicates like TODO, WILL_DO, REMINDS_ME_TO, NEEDS_TO, PROMISED → `open_loop`; WORKING_ON, BUILDING, GOAL, FOCUSING_ON → `active_goal`; DECIDED, CHOSE → `decision`; FEELS, MENTAL_STATE, STRESSED_ABOUT → `emotional`; HAPPENS_ON, BIRTHDAY, SCHEDULED_FOR → `temporal`."

This is a contract the agent will rely on when planning ("if I ask the user about deadlines and they say `BIRTHDAY`, that becomes a temporal slot"). Verify the actual `predicateToSlotType` (extraction_persist.zig:818) emits exactly the predicates listed. If the function maps a subset or different spellings (e.g., `IS_BIRTHDAY` vs `BIRTHDAY`), the briefing creates a false expectation.

I did not exhaustively trace the function during this review — flag this as MD requiring verification before merge: read extraction_persist.zig:818-870 and compare predicate-by-predicate against the briefing text. Update whichever side is stale.

### MD-03: Cache-tier reorder moves `tools` from Tier 1 (was at top) to Tier 2 (after architecture briefing)

**File:** `src/agent/prompt.zig:347-417`

**Issue:**

This is design-sound but worth surfacing: the prior ordering put `## Tools` second (after Identity). The new ordering puts it in Tier 2, AFTER link_type + brain architecture + response protocol + channel attachments + turn classification + task decomposition + safety. That means the first ~5-10 KB of the prompt is rules-about-tools before the agent has seen the tool list.

For an LLM that hasn't seen the tools section yet, the response protocol's references to specific tools ("Preferred tool paths", `runtime_info`, `schedule`, etc) are forward references. Models generally handle this fine since the section is read in full before generating, but if any provider's parser uses early-stopping or attention-window tricks on the system prompt prefix, the change shifts the rules-vs-catalog ordering meaningfully.

**Fix:**

Probably no action needed — the engineered cache-tier rationale (link_type + tools-rules are byte-stable across deploys; tools catalog changes when tools change) is correct. But I'd suggest one round of A/B prompt-eval on the new ordering before declaring victory: confirm tool selection accuracy doesn't regress. The `.audit/v1.8/evals/results/` baseline runs from this morning are a natural comparison point.

If there's any sign of regression, swap Tier 2 (tools) BEFORE the rest of Tier 1, since the tools list is comptime-stable per deploy too.

---

## LOW

### LO-01: `dream_system_prompt` test asserts size > 500 bytes — fragile against legitimate edits

**File:** `src/agent/dream.zig:79-82`

```zig
test "dream_system_prompt is non-trivial size (real instructions, not stub)" {
    try std.testing.expect(dream_system_prompt.len > 500);
    try std.testing.expect(dream_system_prompt.len < 4096);
}
```

The current prompt is ~880 bytes; a future tightening to 450 bytes that still covers all required sections (which the OTHER test verifies) would fail this test for no good reason. Either drop the size assertion or keep only the upper bound (cache-stability hygiene — too long blows the cache savings).

**Fix:** Keep `len < 4096`, drop `> 500`. The "expected sections present" test is the real coverage.

### LO-02: Brain architecture briefing emits ~3 KB of comptime text via 14 separate `w.writeAll` calls

**File:** `src/agent/prompt.zig:746-790`

**Issue:** Each `try w.writeAll(...)` is a writer-level call. For comptime-known text this is fine but readability would improve by collapsing each Layer paragraph into a single multiline string literal:

```zig
try w.writeAll(
    \\### Layer 0 — Working Memory (hot slots, this session)
    \\Up to 15 slots persist...
    \\
    \\Auto-promotion fires on extraction...
    \\
);
```

Pure style — no functional impact. Skip if reviewer time is scarce.

---

## Verification Performed

- [x] `zig build` clean (exit 0)
- [x] `zig build test` clean (exit 0; warnings are intentional test-path warnings from prior modules)
- [x] Confirmed dropped dream symbols (`runDreamCycle`, `persistDreamLog`, `loadRecentTranscript`, `DreamResult`, `Provider` import) have zero remaining references in the tree
- [x] Confirmed `loadTurnMemorySlot` wrapper preserves all positional callers (memory_loader.zig tests + context_engine reference at root.zig:5263)
- [x] Verified `loadTurnMemorySlotOpts` flag gate `if (!opts.skip_legacy_identity)` is correctly placed around the `buildActiveIdentityBlock` call (memory_loader.zig:1047-1054)
- [x] Verified `wm_owns_identity` checks all three required fields (extraction_state_mgr, extraction_user_id, memory_session_id) — root.zig:2668-2670
- [x] Existing prompt-section ordering tests still hold under the new tier order: `tc_pos < safety_pos` ✓ (both Tier 1, TC emitted first); `safety_pos < persona_pos` ✓ (Tier 1 < Tier 3, test explicitly updated)
- [x] Confirmed `brain_graph` tool with `action="communities"` exists (tools/brain_graph.zig:75, 99-103) — dream prompt's tool reference is real
- [x] Confirmed `runtime_info` tool exists (capabilities.zig:34) — briefing's "Failure-mode honesty" reference is real
- [x] **Confirmed `pinIdentitySlot` and `pinPersonaSlot` have zero callers** — basis for CR-01
- [x] Confirmed `procedural_memory.loadForRender` has zero external callers — basis for HI-02
- [x] Confirmed no `nullalis dream` CLI subcommand exists — basis for HI-01

---

## Merge Recommendation

**BLOCK on CR-01.** Pick the lowest-risk path: **revert the DUP-1 fix in 5619f94** (keep both identity blocks emitted), file a follow-up to land DUP-1 properly in V1.14 with Option A from CR-01 (gate on `wm_has_identity_slot`). The other two commits (59bed41, 39422ba) are safe to merge as-is, with HI-01 + HI-02 fixed before merge (they're 5-line edits to the briefing text).

**If the team wants to keep DUP-1 in this merge:** apply Option A from CR-01 (load WM slots once before the gate, check for any `slot_type == "identity"` slot, only skip legacy when present). The de-dup with the existing `loadForRender` call 50 lines later is straightforward.

Other findings (MD-01 through LO-02) are non-blocking follow-ups.

---

_Reviewed: 2026-05-08_
_Reviewer: Claude (gsd-code-reviewer, opus 4.7 1M)_
_Depth: deep_
