---
phase: v1.13-day1
reviewed: 2026-05-08
depth: deep
files_reviewed: 6
files_reviewed_list:
  - src/agent/working_memory.zig
  - src/memory/root.zig
  - src/zaki_state.zig
  - src/agent/prompt.zig
  - src/agent/root.zig
  - src/agent/extraction_persist.zig
findings:
  critical: 2
  high: 2
  medium: 5
  low: 4
  total: 13
status: issues_found
commit: 48f36b7
branch: v1.13/brain-elevation
---

# V1.13 Day 1 Code Review — Working Memory Layer 0

**Commit:** `48f36b7eb031f91ffd63d83370b734a9d64cb7d2`
**Branch:** `v1.13/brain-elevation`
**Diff:** 6 files, +913 insertions
**Depth:** deep (cross-file: orchestrator + storage + prompt wire + extractor wire)
**Reviewer:** Claude (gsd-code-reviewer)

## Summary

The Layer 0 storage shape, schema, and orchestrator design are sound. The composite-priority math is correct, the slot-id eviction state machine is defensive, and the failure-soft contract is honored at every hop. The 7 unit tests cover the pure-function surface adequately for a Day 1 ship.

There is one **CRITICAL latent compile error** in `extraction_persist.zig` that will trip the moment the unrelated `Io.Writer` build break (in `commands.zig` / `root.zig` line 3937, pre-existing on this branch) is fixed and the compiler reaches the auto-promotion catch block. There is one **CRITICAL realloc-failure leak** in `loadForRender` that will leak slot tail elements (and may panic under `GeneralPurposeAllocator` safety) on the truncate path when realloc fails.

Two **HIGH** issues: a dead Postgres index (`idx_wm_priority`) that does not match any query in this commit and reads as cargo-culted optimization, and UTF-8 mid-codepoint truncation in `renderBlock` (the codebase already has `text_norm.truncateUtf8` and chose not to use it).

The rest are MEDIUM/LOW — schema/cap drift surface, slot-semantics leak (reserved slots get overwritten by non-pinned writes when empty), missing test coverage for the `predicateToSlotType` mapper (free coverage), and minor polish.

---

## Critical Issues

### CR-01: `null;` as bare statement in catch block — latent compile error

**File:** `src/agent/extraction_persist.zig:794-799`

```zig
_ = working_memory.promoteSlot(
    allocator, state_mgr, user_id, sid, slot_type,
    m.text, key, @max(m.confidence, 0.5), false,
) catch |err| {
    log.warn("extraction.wm_promote_failed err={s} predicate={s}", .{
        @errorName(err), m.predicate,
    });
    null;
};
```

**Issue:** `promoteSlot` returns `!?i32`. The `catch |err| { ... }` block must yield a `?i32` (or break/return/unreachable). The current block has `null;` as a bare expression statement, which Zig 0.15 rejects with `error: value of type '@TypeOf(null)' ignored`.

Verified by isolated reproduction:
```
$ zig run /tmp/zigtest5.zig
error: value of type '@TypeOf(null)' ignored
        null;
        ^~~~
note: all non-void values must be used
note: to discard the value, assign it to '_'
```

The reason `zig build` does not currently flag this is **unrelated** — the build halts earlier on a pre-existing `Io.Writer` mismatch in `src/agent/commands.zig:1495` and `src/agent/root.zig:3937` (both `payload_buf.writer(self.allocator)` calls returning the wrong writer flavor for `std.json.Stringify.value`). The moment those upstream errors are fixed, the compiler will reach `extraction_persist.persistExtracted` and immediately fail on this `null;`.

This means the test pass count claimed in the commit message ("5966/6026 passed, 0 failed") is **stale** — those tests last passed under an earlier zig stdlib version, before the `Io.Writer` API drift. The current tree does not compile.

**Fix:** Either drop the `null;` entirely (the `_ =` already discards the return value, so a `void`-yielding catch is what we want — change the type unification by giving the block a discardable value via break, or remove the catch's value path):

```zig
_ = working_memory.promoteSlot(
    allocator, state_mgr, user_id, sid, slot_type,
    m.text, key, @max(m.confidence, 0.5), false,
) catch |err| blk: {
    log.warn("extraction.wm_promote_failed err={s} predicate={s}", .{
        @errorName(err), m.predicate,
    });
    break :blk null;
};
```

Or — cleaner — drop the `_ =` assignment and use the catch as a void-yielding statement:

```zig
if (working_memory.promoteSlot(
    allocator, state_mgr, user_id, sid, slot_type,
    m.text, key, @max(m.confidence, 0.5), false,
)) |_| {} else |err| {
    log.warn("extraction.wm_promote_failed err={s} predicate={s}", .{
        @errorName(err), m.predicate,
    });
}
```

**Severity rationale:** This is a build-blocking syntax error sitting on a hot path (auto-promotion runs on every persisted fact). It will surface as soon as the unrelated stdlib drift is resolved. Critical because it is a release blocker hidden behind another release blocker.

---

### CR-02: `loadForRender` realloc-failure path leaks tail and may panic on free

**File:** `src/agent/working_memory.zig:122-131`

```zig
if (all.len <= RENDER_TOP_N) return .{ .slots = all };

const tail = all[RENDER_TOP_N..];
for (tail) |s| s.deinit(allocator);
const truncated = allocator.realloc(all, RENDER_TOP_N) catch all;
return .{ .slots = truncated[0..RENDER_TOP_N] };
```

**Issue:** When `allocator.realloc` fails, the code falls back to `all` (still the full N-element allocation) but then returns `all[0..RENDER_TOP_N]` — a slice with a TRUNCATED length pointing at the SAME base pointer. The caller's `RenderSet.deinit` calls `freeWorkingMemorySlots(allocator, slots)`, which calls `allocator.free(slots)`.

`allocator.free(slice)` requires the slice's length to match the original allocation. Passing a length-10 slice to free a length-15 allocation:
- Under `std.heap.GeneralPurposeAllocator(.{ .safety = true })` (debug builds): triggers a panic / assertion failure on size mismatch.
- Under `c_allocator`: silently leaks the tail bytes (free() of a smaller-than-allocated region is undefined; on glibc/jemalloc it usually frees the whole chunk by base pointer, but the inner-string cleanup for tail elements 10..N has already been done so the metadata is consistent — yet relying on this is fragile).
- Under `ArenaAllocator`: leak is bounded to arena lifetime.

The deeper issue is conceptual: when realloc fails, you have already deinit'd the inner strings of tail elements (lines 128-129), so falling back to the full slice means the "phantom" elements 10..N are now WorkingMemorySlot structs with dangling pointers in their `session_id`, `slot_type`, `content`, `source_key` fields. If anything ever iterates the full original slice from a stored copy, you get use-after-free. (No code currently does this — but the contract is broken.)

**Fix:** Treat realloc failure as recoverable in-place — keep the original allocation length, return the full slice, and accept rendering all 15 instead of 10 for one turn (the renderer will format whatever you give it). Re-deinit-on-error is wrong because the strings are already freed:

```zig
if (all.len <= RENDER_TOP_N) return .{ .slots = all };

const tail = all[RENDER_TOP_N..];
for (tail) |s| s.deinit(allocator);

// Try to shrink the outer allocation. On failure, fall back by
// trimming inside the existing allocation: the slice we expose is
// length-N, but allocator.free needs the original length, so we
// keep the original and truncate the visible window only when the
// realloc actually succeeded.
if (allocator.realloc(all, RENDER_TOP_N)) |truncated| {
    return .{ .slots = truncated };
} else |_| {
    // Realloc failed. We have already freed the tail's inner
    // strings, so we must NOT expose them. Zero-out the tail
    // structs so deinit on the full slice is a no-op for them,
    // then return the full slice (caller will free length-N).
    for (all[RENDER_TOP_N..]) |*s| s.* = .{
        .user_id = 0, .session_id = "", .slot_id = -1,
        .slot_type = "", .content = "", .source_key = null,
        .importance = 0, .pinned = false,
        .created_at_unix = 0, .last_touched_at_unix = 0,
    };
    // But now WorkingMemorySlot.deinit will call allocator.free
    // on empty literals, which is undefined for most allocators.
    // Better: shrink without realloc by tracking length separately.
    return .{ .slots = all };  // accept showing all 15 this turn
}
```

The cleanest fix is to NOT try to shrink the outer allocation at all — just remember the visible length and free the original at deinit. Refactor `RenderSet`:

```zig
pub const RenderSet = struct {
    slots: []WorkingMemorySlot,    // visible window for rendering
    backing: []WorkingMemorySlot,  // original allocation for free()

    pub fn deinit(self: *const RenderSet, allocator: std.mem.Allocator) void {
        memory_root.freeWorkingMemorySlots(allocator, self.backing);
    }
};

// in loadForRender:
if (all.len <= RENDER_TOP_N) return .{ .slots = all, .backing = all };
const tail = all[RENDER_TOP_N..];
for (tail) |s| s.deinit(allocator);
// Replace tail entries with zero-init structs so backing-free is safe.
for (all[RENDER_TOP_N..]) |*s| s.* = std.mem.zeroes(WorkingMemorySlot);
return .{ .slots = all[0..RENDER_TOP_N], .backing = all };
```

But the realloc approach is fine too if you fix the failure branch correctly:

```zig
const truncated = allocator.realloc(all, RENDER_TOP_N) catch {
    // Realloc failed; tail strings already deinit'd. Replace tail
    // structs with safe zero values so deinit on full length is a
    // no-op for them, and return the full slice (caller frees N).
    for (all[RENDER_TOP_N..]) |*s| s.* = std.mem.zeroes(WorkingMemorySlot);
    return .{ .slots = all };
};
return .{ .slots = truncated };
```

Note: `WorkingMemorySlot.deinit` calls `allocator.free` on every string slice unconditionally (lines 611-614 of `memory/root.zig`). `allocator.free` on a `&.{}` literal works (verified), so zero-init is safe. The current code path on realloc-failure does NOT zero-init and DOES return a truncated slice — both wrong.

**Severity rationale:** Realloc failure is rare (effectively only OOM under shrink semantics, which most allocators never fail), but when it fires the consequences range from leak (production) to panic (debug). On a hot per-turn path. Mark Critical because the contract violation is real even if the failure probability is low.

---

## High

### HI-01: `idx_wm_priority` partial index does not accelerate any query in this commit

**File:** `src/zaki_state.zig:1519`

```sql
CREATE INDEX IF NOT EXISTS idx_wm_priority ON {schema}.working_memory(user_id, session_id, importance DESC) WHERE NOT pinned
```

**Issue:** `listWorkingMemorySlots` is the only SELECT on this table. Its ORDER BY is:
```sql
ORDER BY pinned DESC,
  (importance * EXP(-(EXTRACT(EPOCH FROM (NOW() - last_touched_at))/3600.0))) DESC
```

The index is keyed on `(user_id, session_id, importance DESC)`. The ORDER BY's second key is the **composite expression** `importance * exp(-age/3600)`, NOT raw `importance`. PostgreSQL cannot use the index to satisfy this sort. The index also includes `WHERE NOT pinned`, but the query has no `WHERE pinned = false` predicate — it reads all rows including pinned ones (because `ORDER BY pinned DESC` needs them).

The WHERE clause `user_id = $1 AND session_id = $2` is satisfied entirely by `idx_wm_session`, which is also keyed on `(user_id, session_id, ...)`. With LIMIT 15 and a per-(user, session) cap of 15, the planner will sequential-scan the matching rows regardless of index — it's bounded by the application-layer cap.

`idx_wm_priority` therefore costs write amplification (every INSERT/UPDATE updates two indexes instead of one) for zero read benefit.

**Fix:** Either drop the index outright:
```sql
-- delete idx_wm_priority creation; idx_wm_session covers all reads
```

…or rewrite it to be expression-matched and useful (matches the actual sort expression — though Postgres won't use a function-of-NOW() index so this is hard to make work too):
```sql
-- This still won't help because the composite expression
-- depends on NOW(); functional indexes can't be NOW()-dependent.
```

The honest answer is: **drop it**. With LIMIT 15 and ≤15 rows per session, the sort is on a tiny set; the WHERE clause is fully indexed by `idx_wm_session`. Add a real priority index later if benchmarks ever show a sort hotspot (they won't at this row count).

---

### HI-02: `renderBlock` truncation can split UTF-8 mid-codepoint

**File:** `src/agent/working_memory.zig:160-164`

```zig
const max_content: usize = 200;
const truncated_content = if (s.content.len > max_content)
    s.content[0..max_content]
else
    s.content;
try w.print("  {s}: {s}\n", .{ s.slot_type, truncated_content });
```

**Issue:** `s.content[0..200]` slices on byte boundaries. A multi-byte UTF-8 codepoint at position 199-200 will be split mid-sequence, producing invalid UTF-8 in the prompt block.

The codebase already has `memory/text_norm.zig::truncateUtf8(s, max_len)` (line 56) which truncates at codepoint boundaries. It is used elsewhere in the prose pipeline; not using it here is an inconsistency.

User content in working memory is real-world prose (user names, project descriptions, emotional state) — non-ASCII is normal. Arabic/Hebrew/CJK users will hit this immediately. Most LLMs are tolerant of malformed UTF-8 but: (a) tokenizers may produce different tokens for the truncated content vs. clean content, breaking byte-stable cache properties of the volatile block in subtle ways; (b) downstream tools (logging, metrics, JSON serialization of the prompt) may reject the malformed bytes.

**Fix:**

```zig
const text_norm = @import("../memory/text_norm.zig");
// ...
const truncated_content = text_norm.truncateUtf8(s.content, 200);
```

Add a test: 200-byte truncation on a string with a 3-byte codepoint at offset 198..200.

---

## Medium

### ME-01: Reserved slots (0, 1) get overwritten by non-pinned writes when empty

**File:** `src/agent/working_memory.zig:204-212`

```zig
// Try non-reserved range first (2..14).
var i: i32 = 2;
while (i < SLOT_CAP) : (i += 1) {
    if ((used_mask & (@as(u16, 1) << @intCast(i))) == 0) return i;
}
// Fall back to reserved range if free.
i = 0;
while (i < 2) : (i += 1) {
    if ((used_mask & (@as(u16, 1) << @intCast(i))) == 0) return i;
}
```

**Issue:** When slots 2..14 are all occupied AND identity has not yet been pinned (e.g., before the Day 2 identity_loader hook runs), a new auto-promoted `open_loop` slot will land at slot_id=0 or 1 (the reserved identity slots). When `pinIdentitySlot` later runs, its UPSERT will overwrite the open_loop at slot 0 — the canonical memory row survives, but the slot semantics are broken: that fact loses its working-memory presence until something re-promotes it.

This is the inverse of the documented design intent. The reserved slots are reserved by SLOT_ID, but the eviction picker treats reserved as "soft" — only used as last resort. With 13 active slots and no identity pinned, the user can saturate to 15 by filling 0..14 with whatever, then identity arrives and clobbers slot 0. From the agent's perspective, an open loop just disappeared.

**Fix:** Treat reserved as hard reserved during NORMAL writes — never use them for non-identity types even when free. Only `pinIdentitySlot` / `pinPersonaSlot` write to reserved slots (which they already do explicitly via the constants). Drop the `// Fall back to reserved range if free.` block entirely:

```zig
if (slots.len < @as(usize, @intCast(SLOT_CAP))) {
    var used_mask: u16 = 0;
    for (slots) |s| {
        if (s.slot_id >= 0 and s.slot_id < SLOT_CAP) {
            used_mask |= (@as(u16, 1) << @intCast(s.slot_id));
        }
    }
    var i: i32 = 2;
    while (i < SLOT_CAP) : (i += 1) {
        if ((used_mask & (@as(u16, 1) << @intCast(i))) == 0) return i;
    }
    // No free non-reserved slot — fall through to eviction below.
    // Reserved slots 0/1 are managed exclusively by pin*Slot APIs.
}
```

Then eviction (line 215+) will pick the lowest-priority non-reserved, non-pinned slot — which is exactly the right answer.

This drops effective capacity from 15 to 13 for auto-promoted slots, but: the "15 slots" cap was always a fuzzy budget, and having 2 always-available identity slots is the architectural contract.

---

### ME-02: `LIMIT 15` and `SLOT_CAP = 15` can drift silently

**Files:** `src/zaki_state.zig:7041` (SQL), `src/agent/working_memory.zig:193` (constant)

**Issue:** Two independent literals encode the same architectural constant (15 slots per (user, session)). Changing one without the other produces:
- App raises SLOT_CAP to 20, SQL still LIMITs to 15 → `pickSlotForWrite` thinks 5 slots are free that aren't returned → false-positive empty-slot picks → application sees `slots.len < 15` (because LIMIT 15 returns 15) and tries to insert at a slot_id that may already exist → UPSERT silently overwrites.
- App lowers SLOT_CAP to 10, SQL still LIMITs to 15 → `loadForRender` truncates to 10 (because RENDER_TOP_N=10), eviction logic uses a 10-element view from app while DB has 15 rows → ghost rows that never get evicted.

Either scenario is silent corruption.

**Fix:** Hoist the cap to a comptime const exported from `working_memory.zig` and substitute it into the SQL via `buildQuery`'s template substitution (or string concat at query-build time):

```zig
// in working_memory.zig
pub const SLOT_CAP: i32 = 15;

// in zaki_state.zig listWorkingMemorySlots
const q = try self.buildQuery(
    "SELECT ... FROM {schema}.working_memory WHERE ... ORDER BY ... LIMIT " ++
        std.fmt.comptimePrint("{d}", .{working_memory.SLOT_CAP}),
);
```

Or a CHECK constraint in the DDL that enforces it server-side (per-row, e.g. `CHECK (slot_id >= 0 AND slot_id < 15)`) — though this still doesn't unify with the LIMIT.

Lowest-friction option: a `// SYNC: keep == working_memory.SLOT_CAP` comment on both literals plus a unit test that reads both and asserts equality.

---

### ME-03: `touchSlot` defined but never wired to recall path

**File:** `src/agent/working_memory.zig:284-293` (defined), no callers

**Issue:** `compositePriority` includes a recency-decay term driven by `last_touched_at_unix`. The only thing that bumps `last_touched_at` is `upsertWorkingMemorySlot` (the SQL sets `last_touched_at = NOW()` on every UPSERT) and `touchWorkingMemorySlot` (which `touchSlot` wraps). Nothing calls `touchSlot`.

Result: a slot that is recalled, re-mentioned, or surfaced in the prompt block on turn N+1 does NOT get its recency bumped. After 1 hour of session activity, an actively-discussed slot decays to 0.5 priority alongside one that was promoted-and-forgotten. The eviction picker then can't distinguish "loaded into the prompt 3 turns ago" from "promoted 3 turns ago and never revisited."

This is a functional regression from the design intent of the half-life: if the slot is in the prompt every turn, the model is "thinking about it" and recency should reflect that.

The plan's commit message lists "session-end flush" and "identity_loader hook" as Day 2 work, but does NOT call out `touchSlot` wiring. Either it's an oversight or it's implicit-Day-2.

**Fix (Day 2):** In `agent/root.zig` after `working_memory.loadForRender` returns, iterate the loaded slot_ids and call `working_memory.touchSlot` on each (or batch into a single UPDATE). Or — better — bake the touch into `loadForRender` itself by switching its SELECT to a CTE that returns rows AND updates `last_touched_at` in one round-trip:

```sql
WITH loaded AS (
    SELECT slot_id FROM {schema}.working_memory
    WHERE user_id = $1 AND session_id = $2
    ORDER BY pinned DESC,
        (importance * EXP(-(EXTRACT(EPOCH FROM (NOW() - last_touched_at))/3600.0))) DESC
    LIMIT 15
)
UPDATE {schema}.working_memory wm
SET last_touched_at = NOW()
FROM loaded
WHERE wm.user_id = $1 AND wm.session_id = $2 AND wm.slot_id = loaded.slot_id
RETURNING wm.slot_id, wm.slot_type, wm.content, ...;
```

Single round-trip, atomic, no app-side iteration. But note: this means EVERY render bumps recency, so all rendered slots tie at `now` → eviction breaks ties on importance × type_weight, which is fine.

If touching every render is too aggressive (degenerates to "everything in the prompt is fresh"), gate the touch on whether the user message references the slot's `source_key` — but that's Day 3+ work.

For Day 2, the minimum viable fix is: explicit `touchSlot` calls from the agent loop when a slot is referenced in a user message or tool output. Document the gap in the Day 1 commit if leaving it open.

---

### ME-04: `predicateToSlotType` lacks unit test coverage

**File:** `src/agent/extraction_persist.zig:818-855`

**Issue:** This is a pure function — no I/O, no allocator, easy to test. The Day 1 test count is "+7 unit tests for working_memory.zig"; zero new tests in `extraction_persist.zig`. The mapper is the single point of truth for "which extracted predicate becomes which WM slot type"; bugs here propagate to every promotion. Examples that would catch real bugs:

- Predicate case-insensitivity: `"todo"` should map to `open_loop` (test that uppercase, lowercase, mixed all work — `eqlIgnoreCase` already does this, but pin it down with a test).
- Unknown predicate: `"FOOBAR"` should return `null` (test that the function does not panic or default-to-some-type).
- Empty predicate: `""` should return `null`.
- Whitespace-padded predicate: `" TODO "` returns `null` (current behavior — no trim — verify and document).

**Fix:**

```zig
test "predicateToSlotType maps known predicates" {
    const wm = @import("working_memory.zig");
    try std.testing.expectEqualStrings(wm.SlotType.open_loop, predicateToSlotType("TODO").?);
    try std.testing.expectEqualStrings(wm.SlotType.open_loop, predicateToSlotType("todo").?);
    try std.testing.expectEqualStrings(wm.SlotType.active_goal, predicateToSlotType("WORKING_ON").?);
    try std.testing.expectEqualStrings(wm.SlotType.decision, predicateToSlotType("DECIDED").?);
    try std.testing.expectEqualStrings(wm.SlotType.emotional, predicateToSlotType("FEELS").?);
    try std.testing.expectEqualStrings(wm.SlotType.open_question, predicateToSlotType("ASKING").?);
    try std.testing.expectEqualStrings(wm.SlotType.temporal, predicateToSlotType("HAPPENS_ON").?);
    try std.testing.expect(predicateToSlotType("FOOBAR") == null);
    try std.testing.expect(predicateToSlotType("") == null);
    try std.testing.expect(predicateToSlotType(" TODO ") == null);  // no trim
}
```

Cheap. Run it. Lock the contract.

---

### ME-05: `composite_priority` clamp is dead code (defensive but obscures math)

**File:** `src/agent/working_memory.zig:90-94`

```zig
const recency = std.math.exp(-age_seconds * std.math.ln2 / 3600.0);
const type_w = slotTypeWeight(slot.slot_type);
const composite = slot.importance * recency * type_w;
return std.math.clamp(composite, 0.0, 1.0);
```

**Issue:** `importance` enters as a `f64` from the DB, parsed via `std.fmt.parseFloat` with a fallback to 0.5 on parse error. There is NO upstream invariant that bounds importance to [0, 1] — the schema's `FLOAT NOT NULL DEFAULT 0.5` accepts any double. Auto-promotion at line 792 passes `@max(m.confidence, 0.5)` — confidence is also unbounded above.

If a future caller writes `importance = 5.0`, `composite = 5.0 * recency * type_w` could be > 1.0 and the clamp masks the bug. If clamp is intentional defense-in-depth, fine — but then the comment should say so explicitly. As written, the comment ("clamped to [0,1]") suggests the author thought the inputs were already bounded and added clamp as belt-and-suspenders, when in fact the inputs are NOT bounded.

**Fix (pick one):**

(a) Bound importance at the write site:
```zig
// in upsertWorkingMemorySlot caller (promoteSlot):
const imp = std.math.clamp(importance, 0.0, 1.0);
```
…and drop the clamp in `compositePriority`.

(b) Add a CHECK constraint in DDL:
```sql
importance FLOAT NOT NULL DEFAULT 0.5 CHECK (importance >= 0.0 AND importance <= 1.0),
```
…and add a debug assertion in `compositePriority`:
```zig
std.debug.assert(slot.importance >= 0.0 and slot.importance <= 1.0);
```

(c) Keep the clamp but rename the comment to "defensive: importance is unbounded at schema layer, clamp here so eviction ordering is well-defined."

---

## Low

### LO-01: `pinned` boolean text representation — confirmed safe but worth a regression guard

**File:** `src/zaki_state.zig:7207, 7149-7150` (write side); `src/zaki_state.zig:7152` (read side)

**Issue:** Write sends `"t"`/`"f"` as text params. PG's text input for `BOOLEAN` accepts `t/f/true/false/y/n/yes/no/1/0/on/off` — `t`/`f` are canonical. Read parses with `std.mem.eql(u8, pinned_str, "t") or std.mem.eql(u8, pinned_str, "true")`. PG's text OUTPUT for boolean is always `t` or `f` (per docs and source) — the `or "true"` branch is dead but harmless. Confirmed safe.

**Fix (optional):** Drop the `or "true"` for one less line of dead code, or add a short test that round-trips `pinned=true` and `pinned=false` through upsert + list and asserts the boolean parses correctly. Pure pure-function test of the parse expression is cheapest.

### LO-02: `freeWorkingMemorySlots` does not handle aliased slot pointers

**File:** `src/memory/root.zig:618-621`

**Issue:** If two `WorkingMemorySlot` structs ever share an inner-string pointer (e.g., via accidental aliasing in tests), `freeWorkingMemorySlots` will double-free. The orchestrator's tests (`test "renderBlock formats slots correctly"`) construct slots with string literal `.content = "user is Nova"`. These are not allocator-owned; the test does not call `deinit` on the slots. This works because the test only invokes `renderBlock` (which copies content into `buf`) and not `freeWorkingMemorySlots`. Fine.

But if a future test is written carelessly — e.g., one that simulates `loadForRender` by hand-constructing slots and then defers `RenderSet.deinit` — it will double-free or free literals.

**Fix (optional):** Guard `WorkingMemorySlot.deinit` with a debug-only invariant:
```zig
pub fn deinit(self: *const WorkingMemorySlot, allocator: std.mem.Allocator) void {
    // Caller contract: all string fields are allocator-owned.
    // Tests that construct slots from literals must NOT call deinit.
    allocator.free(self.session_id);
    // ...
}
```
…and document the contract in the doc comment. Already implicitly the rule; just make it explicit.

### LO-03: Schema `CREATE INDEX IF NOT EXISTS` — stable across re-runs but no migration record

**File:** `src/zaki_state.zig:1518-1519`

**Issue:** DDL is appended to the boot-time `ddl` array and re-executed every boot via `IF NOT EXISTS`. This works for greenfield. For schema evolution (ME-01 fix above adds CHECK constraint), `IF NOT EXISTS` won't update an existing table — you'd need an ALTER. There is no migration version registry visible in this commit's diff.

**Fix (deferred, not Day 1):** When V1.13 needs to evolve the schema (Day 2+), introduce a `schema_version` table and a migration script. Not blocking Day 1 ship.

### LO-04: `pickSlotForWrite` ignores `new_slot_type` parameter

**File:** `src/agent/working_memory.zig:184-185`

```zig
pub fn pickSlotForWrite(
    ...
    new_slot_type: []const u8,
) !?i32 {
    _ = new_slot_type; // future: weight new write against existing slots of same type
```

**Issue:** Parameter is plumbed but unused. Mild code smell — interface promises a behavior the implementation doesn't deliver. Caller has to guess whether passing slot_type matters or not. Either remove the parameter (and update callers) until the feature lands, or keep with the explicit TODO (current behavior — acceptable but should be tracked in the plan).

**Fix:** Track in `.planning/v1.13/` as a Day 2+ followup, or rename parameter to `_new_slot_type` to make the unused-ness load-bearing.

---

## Verified Correct (Sanity Checks That Passed)

- **Composite-priority math.** `recency = exp(-age * ln2 / 3600)`. At age=3600s, recency=0.5. At age=7200s, recency=0.25. Test at line 348-370 verifies this with importance=0.8 type_w=0.9 → fresh ≈ 0.72, stale ≈ 0.18. Correct.
- **Column index mapping in `listWorkingMemorySlots`.** SELECT order: slot_id, slot_type, content, source_key, importance, pinned, created_epoch, touched_epoch (8 cols). Read order matches. Verified line-by-line.
- **Param/length array length match in `upsertWorkingMemorySlot`.** 8 params, 8 lengths. `$1..$8` placeholders match. Lengths are advisory in text format (PG uses null-terminator) but kept consistent for safety.
- **Stable-block byte stability.** `working_memory_block` is consumed only by `buildVolatileSystemPrompt` (line 417). `buildStableSystemPrompt` does not reference it. Cache-prefix contract preserved.
- **PRIMARY KEY (user_id, session_id, slot_id).** Correct — UPSERT atomicity covers concurrent same-slot writes within a session. ON CONFLICT path handles eviction-driven slot reuse correctly.
- **Cascade delete.** `REFERENCES users(user_id) ON DELETE CASCADE` cleans WM rows when user is deleted. Correct.
- **Eviction state machine.** `used_mask: u16` with bit shifts up to 14 (slot_ids 0..14) — u16 has 16 bits, no overflow. `lowest_idx`/`lowest_score` lowest-priority sweep is correct (skips pinned and reserved). The "all pinned" return-null branch is reachable and is logged + skipped at the caller (correct failure-soft).
- **Empty-slice handling.** `loadForRender` failure path returns `&.{}` literal; `freeWorkingMemorySlots` on an empty slice is a no-op + safe `allocator.free` (verified with isolated repro under GeneralPurposeAllocator).
- **`predicateToSlotType` ASCII-only correctness.** Predicates from the extractor are uppercase ASCII per existing convention (`TODO`, `WILL_DO`, etc.). `std.ascii.eqlIgnoreCase` is the right call. ASCII-only is fine because predicates are a controlled vocabulary.
- **Auto-promotion ordering.** Promotion runs INSIDE the `persistExtracted` per-fact loop AFTER the memory row is written + edge-written + vector-indexed (line 776 onwards). Order is correct: no orphaned WM slots if memory write fails.
- **`renderBlock` errdefer.** `errdefer buf.deinit(allocator)` covers mid-loop OOM during `try w.print(...)`. `toOwnedSlice` transfers ownership; errdefer doesn't fire on success path. Correct.
- **`pinIdentitySlot` / `pinPersonaSlot` deferral to Day 2.** Defined but uncalled, acknowledged in commit message under "Out of scope (Day 1.7+ followups)." Not a missing wire-up — explicit.
- **Concurrency.** UPSERT is atomic in PG. Two concurrent turns racing to write the same slot_id will serialize on the unique constraint, second write wins. Correct.

---

## Recommended Sequencing

**Block before merge to `main`:**
- CR-01 (compile error)
- CR-02 (memory unsafety)

**Fix before V1.13 GA:**
- HI-01 (drop dead index)
- HI-02 (UTF-8 truncation)
- ME-01 (reserved slot semantics)

**Day 2 scope (already implicit or planned):**
- ME-03 (touchSlot wiring) — must land with identity_loader hook
- ME-04 (predicate test) — free, do it
- ME-02 (cap drift guard) — pick one fix

**Punt to V1.14:**
- LO-01, LO-02, LO-03, LO-04, ME-05

---

_Reviewed: 2026-05-08_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: deep_
