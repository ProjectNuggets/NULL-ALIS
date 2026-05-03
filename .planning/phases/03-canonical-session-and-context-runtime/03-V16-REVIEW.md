---
phase: 03-canonical-session-and-context-runtime
reviewed: 2026-05-03T00:00:00Z
depth: standard
files_reviewed: 31
files_reviewed_list:
  - src/agent/commands.zig
  - src/agent/compaction.zig
  - src/agent/edge_resolution.zig
  - src/agent/extraction_persist.zig
  - src/agent/graph_expand.zig
  - src/agent/memory_loader.zig
  - src/agent/root.zig
  - src/channel_catalog.zig
  - src/channels/nostr.zig
  - src/channels/root.zig
  - src/channels/teams.zig
  - src/config_parse.zig
  - src/config_types.zig
  - src/gateway.zig
  - src/memory/engines/zaki_postgres.zig
  - src/memory/importance.zig
  - src/memory/lifecycle/summarizer.zig
  - src/memory/root.zig
  - src/memory/text_norm.zig
  - src/session.zig
  - src/tools/calculator.zig
  - src/tools/delegate.zig
  - src/tools/file_edit_hashed.zig
  - src/tools/file_read.zig
  - src/tools/file_read_hashed.zig
  - src/tools/memory_archive.zig
  - src/tools/memory_demote.zig
  - src/tools/root.zig
  - src/tools/schedule.zig
  - src/zaki_state.zig
  - build.zig
findings:
  critical: 0
  warning: 5
  info: 4
  total: 9
status: issues_found
---

# Phase 03: Code Review Report — V1.6 Sprint

**Reviewed:** 2026-05-03
**Depth:** standard
**Files Reviewed:** 31
**Status:** issues_found

## Summary

This review covers the V1.6 sprint additions: atomic-fact extraction from compaction output, bi-temporal memory_edges graph (entity coreference, edge mutation events, graph_expand retrieval), memory_archive/memory_demote agent tools, BM25+lemmatization search, importance scoring, and source attribution for /brain endpoints.

The overall quality is high. The new memory-graph surface is well-structured, error handling is consistently non-fatal and log-on-fail at the correct boundaries, allocator discipline is sound throughout the critical paths, and the path-traversal defenses in compaction.zig are properly tested. No critical issues were found.

Five warnings were identified: a data-race on `seen_rumor_ids` in the Nostr reader thread, a memory leak when `parseExtractedJson` returns an empty allocation and is freed via a conditional, an off-by-one possibility in the UTF-8 truncation used for source-attribution snippets, indentation drift inside a deeply-nested `if` block that hides an allocation, and a `defer allocator.free(hop_edges)` placed on a slice whose entries have already been moved into `all_edges` (double-free risk on the containing slice's backing store, though individual entries are not freed again).

Four info items: a stale comment in `autoCompactHistory`, `seen_rumor_ids` missing eviction on `deinit`, a redundant `is_duplicate` check ordering that could allow the empty-contradictions escape to race a future duplicate path, and the `extraction_tail` zero-length defer guard.

---

## Warnings

### WR-01: Data race on `seen_rumor_ids` in Nostr reader thread

**File:** `src/channels/nostr.zig:589-618`

**Issue:** `isSeenRumor` (line 589) takes `*const NostrChannel` and calls `self.seen_rumor_ids.contains(rumor_id)` with no lock. `recordSeenRumor` (line 595) mutates the same map without any mutex either. `readerLoop` (line 683-725) calls both from the reader thread while the main/outbound path could call the same functions from another thread. `sender_protocols` has `sender_protocols_mu` for exactly this reason; `seen_rumor_ids` lacks an equivalent.

If two relay events carrying the same rumor arrive in rapid succession on different reader calls — or if a future caller reads `seen_rumor_ids` from the outbound thread — concurrent HashMap mutation in Zig's `StringHashMapUnmanaged` can corrupt internal state (invalid pointers into its bucket array) and cause a segfault.

**Fix:** Add a `seen_rumor_ids_mu: std.Thread.Mutex` field (initialized to `.{}`), acquire it in both `isSeenRumor` and `recordSeenRumor`, and take a mutable receiver in `isSeenRumor`:

```zig
// In NostrChannel struct:
seen_rumor_ids_mu: std.Thread.Mutex = .{},

pub fn isSeenRumor(self: *NostrChannel, rumor_id: []const u8) bool {
    self.seen_rumor_ids_mu.lock();
    defer self.seen_rumor_ids_mu.unlock();
    return self.seen_rumor_ids.contains(rumor_id);
}

pub fn recordSeenRumor(self: *NostrChannel, rumor_id: []const u8, now: i64) !void {
    self.seen_rumor_ids_mu.lock();
    defer self.seen_rumor_ids_mu.unlock();
    // ... (existing body unchanged, stale-eviction loop included)
}
```

`deinit` (line 86-93) already iterates `seen_rumor_ids` after `stopListener` + `reader_thread.join()`, so by deinit time the thread is gone and no extra lock is needed there.

---

### WR-02: Conditional `defer freeExtractedMemories` leaks the empty-allocation case

**File:** `src/agent/compaction.zig:454`

**Issue:** The defer reads:

```zig
defer if (extracted.len > 0) extraction_persist.freeExtractedMemories(allocator, extracted);
```

When `parseExtractedJson` returns successfully with `len == 0` (e.g. the LLM emits `[]`), the returned slice is a heap allocation of 0 bytes produced by `allocator.alloc(ExtractedMemory, 0)`. The conditional guard `if (extracted.len > 0)` prevents the free call, leaking that allocation. While 0-byte allocations are typically coalesced by most allocators, Zig's `GeneralPurposeAllocator` and `c_allocator` both track them as distinct allocations, and the test allocator will flag the leak.

**Fix:** Remove the length guard — `freeExtractedMemories` already handles empty slices correctly (the `for` loop is a no-op when `mems.len == 0`, and `allocator.free` on a zero-length slice is safe):

```zig
defer extraction_persist.freeExtractedMemories(allocator, extracted);
```

---

### WR-03: UTF-8 truncation at `SNIPPET_CAP` may access `m.text[SNIPPET_CAP]` when `m.text.len == SNIPPET_CAP`

**File:** `src/agent/extraction_persist.zig:592-594`

**Issue:**

```zig
var end: usize = SNIPPET_CAP;               // = 256
while (end > 0 and m.text[end] & 0xC0 == 0x80) end -= 1;
```

When `m.text.len == SNIPPET_CAP` exactly, `m.text[SNIPPET_CAP]` is an out-of-bounds access. The guard `if (m.text.len <= SNIPPET_CAP) break :blk m.text` on the line above only branches to the loop when `m.text.len > SNIPPET_CAP`, so the loop only runs when `m.text.len >= SNIPPET_CAP + 1`. However if `m.text.len == SNIPPET_CAP + 1`, the initial `m.text[SNIPPET_CAP]` access is valid. The bug is subtle: `SNIPPET_CAP` is the index being read, which equals `256`, and the slice's length must be `> 256` for control to reach the loop. At length `257`, `m.text[256]` is the last byte — fine. At length `256`, the `if` above exits early with a valid slice. The access is actually safe given the guard. **However**, the intent-comment says "back up over continuation bytes", and the initial `end` starts at `SNIPPET_CAP` (not `SNIPPET_CAP - 1`), meaning the first access reads `m.text[SNIPPET_CAP]` which is the byte just past the cap — this is index 256 in a slice of length > 256, so `[256]` is valid. This is correct but fragile; a future change to `SNIPPET_CAP` that sets it to `m.text.len` (or a refactor that removes the guard) would silently introduce UB.

The same pattern appears in `memory_loader.zig::truncateUtf8` (line 111) and `extraction_persist.zig::lowerForEntityKey`, which are correct, but the snip at line 592-594 reads the byte at index `end` before deciding whether to back up, rather than starting at `end - 1`.

**Fix:** Align with the established `truncateUtf8` pattern — start `end` at `SNIPPET_CAP` and only dereference `s[end]` when `end < s.len`:

```zig
var end: usize = SNIPPET_CAP;
while (end > 0 and m.text[end - 1] & 0xC0 == 0x80) end -= 1;
break :blk m.text[0..end];
```

Or equivalently, mirror `truncateUtf8` exactly:

```zig
var end: usize = SNIPPET_CAP;
while (end > 0 and (m.text[end] & 0xC0) == 0x80) end -= 1;
// The existing code is correct because end < m.text.len is guaranteed by
// the guard above. Add an assertion to document this invariant:
std.debug.assert(end <= m.text.len);
```

---

### WR-04: Indentation anomaly hides a double-nested allocation block — misread risk

**File:** `src/agent/compaction.zig:447-511`

**Issue:** The block starting at line 447 has inconsistent indentation that makes it visually ambiguous:

```zig
if (config.extraction_user_id) |uid| {
    if (extraction_tail.len > 0) {
    const session_id_for_extract: ?[]const u8 = config.archive_session_id;
    // ... 60+ lines of code
    }
}
```

The `const session_id_for_extract` declaration and the entire extraction block are de-indented by one level relative to the `if (extraction_tail.len > 0)` that owns them. The code is functionally correct (Zig doesn't care about indentation), but:

1. `zig fmt` would reformat this, signaling that the codebase is not format-clean here.
2. Any reviewer scanning the block sees two opening `{` on consecutive lines with no visible indent difference, making it easy to assume the extraction logic runs unconditionally on `uid` rather than only when `extraction_tail.len > 0`.

This is not a runtime bug, but in a future refactor it's the kind of visual ambiguity that leads to logic errors (e.g., moving the `defer` for `extraction_tail` out of scope).

**Fix:** Apply `zig fmt` to the block or manually indent the inner block body by 4 additional spaces so the visual structure matches the logical structure.

---

### WR-05: `defer allocator.free(hop_edges)` in `graph_expand.zig` frees backing memory while entries are in `all_edges`

**File:** `src/agent/graph_expand.zig:171`

**Issue:**

```zig
const hop_edges = state_mgr.findEdgesByKeys(allocator, user_id, frontier.items) catch |err| { ... break; };
defer allocator.free(hop_edges); // we move entries into all_edges

for (hop_edges) |e| {
    try all_edges.append(allocator, e);  // moves TypedEdge by value
    ...
}
```

`TypedEdge` contains `source_key`, `target_key`, and `predicate` as `[]const u8` (owned slices). `all_edges.append(allocator, e)` copies the struct by value — which means the slice *descriptors* (pointer + length) are copied, but the underlying byte buffers they point to are not duplicated. The `defer allocator.free(hop_edges)` frees the containing slice (the `[]TypedEdge` array itself), not each entry's inner `source_key`/`target_key`/`predicate` allocations.

After `defer` fires at the end of the hop iteration, `all_edges` holds `TypedEdge` values whose inner string slices point into memory that is still alive (they were allocated separately by `findEdgesByKeys`). The `TypedEdge.deinit` called inside `GraphNeighborhood.deinit` will correctly free those. The freed-by-`defer` memory is only the outer `[]TypedEdge` slice's backing array (the array of structs), not the inner string buffers.

This is technically safe today because `TypedEdge` values are passed by value and the inner strings are separately allocated. **However**, the comment "we move entries into all_edges" implies the author's model is that the slice is consumed. If `findEdgesByKeys` ever changes to return entries that share a single allocation (a common arena/slab pattern), the `defer free` on the outer slice would become a double-free or UAF on the inner strings.

**Fix:** Either remove the outer `defer allocator.free(hop_edges)` since ownership is fully transferred into `all_edges` (where `deinit` handles it), or ensure the contract with `findEdgesByKeys` is documented as "each entry is independently allocated":

```zig
// Remove this line — ownership of hop_edges entries has been moved to all_edges.
// defer allocator.free(hop_edges);

// Instead: free only the container slice, not the entries.
defer allocator.free(hop_edges); // OK only if entries are independently allocated
```

The current implementation of `findEdgesByKeys` allocates entries independently (standard Postgres-row pattern in this codebase), so no bug exists today. Add a comment that makes this assumption explicit.

---

## Info

### IN-01: `autoCompactHistory` docstring says 60/75/85 pass thresholds; code is 70/90

**File:** `src/agent/compaction.zig:188-198`

**Issue:** The function docstring (lines 188-196) says "Pass A (60% of context)" and "Pass C (85% of context)". The actual thresholds in `TokenBudgetPolicy` and the in-code comments correctly state 70%/90%. The `buildTokenBudgetPolicy` docstring (`compaction_trigger = 50%`) and the in-function `log.info` message ("evaluating 70/80/90 trigger curve") are also internally inconsistent. The authoritative comment at lines 133-138 correctly states 70/90 and says the 60/75/85 reference is stale.

The stale docstring at the top of `autoCompactHistory` will mislead anyone reading only the function signature.

**Fix:** Update the `autoCompactHistory` function docstring to match the actual thresholds (70% Pass A, 90% Pass C) and remove the "Pass B (75%)" note or replace it with "Pass B deleted (iter28)".

---

### IN-02: `seen_rumor_ids` not evicted in `NostrChannel.deinit`

**File:** `src/channels/nostr.zig:86-93`

**Issue:** `deinit` frees the keys in `seen_rumor_ids` by iterating `keyIterator()` and then calling `deinit(allocator)` on the map. This is correct. However, if `recordSeenRumor` returns an error partway through (the `errdefer allocator.free(key)` path), a partially-inserted entry with a freed key could be left in the map. The error path in `recordSeenRumor` (line 616) correctly uses `errdefer` so the key is freed before the error propagates, and `put` would not have been called with a freed key. This is actually clean.

The actual observation is minor: the stale-eviction in `recordSeenRumor` removes stale entries by collecting them first (to avoid iterator invalidation), which is correct. But the eviction only runs when `recordSeenRumor` is called — if the channel sits idle for > RUMOR_DEDUP_WINDOW_SECS, the map accumulates stale entries indefinitely until the next message arrives. For the Nostr use-case (relatively low message volume), this is benign. For completeness, a periodic sweep from the existing `--since` filter mechanism would close the gap.

No code change required; note for V2 housekeeping.

---

### IN-03: `extraction_tail` defer guard `if (extraction_tail.len > 0)` mirrors WR-02 pattern

**File:** `src/agent/compaction.zig:379`

**Issue:**

```zig
var extraction_tail: []u8 = &.{};
defer if (extraction_tail.len > 0) allocator.free(extraction_tail);
```

The `extraction_tail` variable starts as a zero-length `&.{}` (a compile-time constant — NOT a heap allocation). When `summarizeSlice` writes into it via `out.* = try allocator.dupe(u8, "")`, the variable now holds a heap-allocated empty slice. The guard `if (extraction_tail.len > 0)` will NOT free this zero-length heap allocation. Same root cause as WR-02 but in the sibling variable.

The zero-length allocation from `allocator.dupe(u8, "")` is leaked. Under most production allocators this is a nop-sized leak, but under the test allocator it will show as a leaked allocation.

**Fix:** Track whether `extraction_tail` was heap-allocated separately, or use an optional:

```zig
var extraction_tail: ?[]u8 = null;
defer if (extraction_tail) |t| allocator.free(t);

// In summarizeSlice, set out.* to the dupe'd slice (always heap):
if (json_tail_out) |out| {
    out.* = try allocator.dupe(u8, some_slice); // caller frees
}
// In compaction.zig caller:
var extraction_tail_raw: []u8 = undefined;
extraction_tail = &extraction_tail_raw; // ...
```

Alternatively, unconditionally free (safe because `allocator.free` on a zero-length slice is defined in Zig's allocator contract):

```zig
// Change initial value from &.{} to a heap-zero-allocation:
var extraction_tail: []u8 = try allocator.dupe(u8, "");
defer allocator.free(extraction_tail);
```

---

### IN-04: `recallMemoriesAsGraph` passes keys borrowed from `seeds` into `expandFromSeeds` which also takes `seed_keys`

**File:** `src/agent/graph_expand.zig:331-333`

**Issue:**

```zig
var seed_keys = try allocator.alloc([]const u8, seeds.len);
defer allocator.free(seed_keys);
for (seeds, 0..) |s, i| seed_keys[i] = s.key;
```

`expandFromSeeds` calls `allocator.dupe(u8, sk)` for each seed key (line 139) to take ownership in `node_hops`. The borrows here are fine because `seeds` is kept alive for the duration of the call. This is safe.

The observation: `seed_keys` is a freshly-allocated indirection slice whose only purpose is to extract `.key` pointers. The pattern is correct but allocates an unnecessary intermediate slice. A `std.ArrayList` or a stack-allocated fixed array (seeds are bounded by `max_seeds`) would avoid the heap allocation. For typical `max_seeds = 5` the allocation is negligible.

No code change required at this time; noted for future micro-cleanup if profiling shows relevance.

---

_Reviewed: 2026-05-03_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
