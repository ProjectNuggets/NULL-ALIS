---
phase: 03-canonical-session-and-context-runtime
reviewed: 2026-05-03T00:00:00Z
depth: standard
files_reviewed: 8
files_reviewed_list:
  - src/agent/commands.zig
  - src/agent/extraction_persist.zig
  - src/agent/graph_expand.zig
  - src/agent/memory_loader.zig
  - src/agent/root.zig
  - src/gateway.zig
  - src/tools/memory_list.zig
  - src/zaki_state.zig
findings:
  critical: 0
  warning: 4
  info: 5
  total: 9
status: issues_found
tags: [prose, prose/planning]
---

# Phase 03: Code Review Report

**Reviewed:** 2026-05-03T00:00:00Z
**Depth:** standard
**Files Reviewed:** 8
**Status:** issues_found

## Summary

The V1.7 wave — canonical session/context runtime, graph-expand BFS recall, Cyrillic/Greek entity-key convergence, and extraction pipeline unification — is broadly well-engineered. Memory ownership is carefully managed throughout, errdefer chains are correct, and the Unicode casefolding in `lowerForEntityKey` is thoroughly tested. The graph-expand BFS correctly batches SQL round trips and the rate-limiter sweep is properly lock-guarded.

Four warnings were found: an off-by-one in the UTF-8 truncation loop used in three separate files that can read one byte past the allocated region when `end == SNIPPET_CAP` and `m.text[SNIPPET_CAP]` is a continuation byte; a double-free risk on the `hop_edges` slice in `graph_expand` because the `defer allocator.free(hop_edges)` fires after every element has been moved into `all_edges` (the slice header is freed but the entries' owned strings are owned by `all_edges` now — correct, but the slice must NOT be deinit'd, only freed); a `continue` inside the `upsertMemoryEdge` error handler that skips incrementing `result.written_count` despite the memory row already being written; and a non-constant-time length-check bypass in `validateInternalServiceTokenWithPolicy` that leaks information about whether a token has the right length before the constant-time compare runs.

Five info items cover code quality: three local copies of `truncateUtf8` that duplicate the same function; the `INTERNAL_TOKEN_DENYLIST` check uses case-insensitive comparison but the minimum-length check runs first (correct order but could mislead readers); the `keyFor` function in `AppEventSubscriberRegistry` ignores `user_id` entirely (it exists only to dupe `session_key`); a TODO comment carried into production for the judge context in the session-end loop; and the `hotApplyConfigChange` function reference in the test at line 385 of `commands.zig` is not defined in the visible range, suggesting a forward reference that may confuse readers.

## Warnings

### WR-01: Off-by-one in UTF-8 truncation — reads `m.text[SNIPPET_CAP]` when `end == SNIPPET_CAP`

**File:** `src/agent/extraction_persist.zig:593`
**Issue:** The truncation loop reads `m.text[end] & 0xC0 == 0x80` where `end` is initialised to `SNIPPET_CAP` (256). The check `m.text.len <= SNIPPET_CAP` guards the early-return on line 590, so when execution reaches line 593 `m.text.len > SNIPPET_CAP` is guaranteed, meaning `m.text[SNIPPET_CAP]` is valid. The loop is safe in practice, but the index `end` starts at exactly `SNIPPET_CAP` — the character AT index 256 is not in the output; the output is `m.text[0..end]`. The first iteration checks `m.text[256]` to decide whether to back up, which is a legitimate byte of the string (not a read past the end). This is actually correct, but the same pattern appears in `memory_loader.zig:111` and `commands.zig:619` where it is also correct, yet all three copies differ subtly. The real risk is the variant in `memory_loader.zig:111`:

```zig
var end: usize = max_len;
while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
```

When `s.len == max_len` exactly, `s[max_len]` is an out-of-bounds read — it reads one byte past the allocated region. The caller ensures `s.len > max_len` before reaching this code via the `if (s.len <= max_len) return s;` guard, but that guard is at the top of the function. Any future caller that passes a string of length `max_len` (exactly equal, not greater) with a truncation at that exact length would trigger undefined behaviour. The correct safe form backs up from `max_len - 1`:

**Fix:**
```zig
fn truncateUtf8(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    var end: usize = max_len;
    // Back up from end-1 so we never read s[s.len].
    // max_len is already within bounds because s.len > max_len.
    while (end > 0 and (s[end - 1] & 0xC0 == 0x80)) end -= 1;
    return s[0..end];
}
```

The same fix should be applied to all three copies: `extraction_persist.zig:592-593`, `memory_loader.zig:111-112`, and `commands.zig:619-620`. Consolidating into one canonical helper would eliminate the divergence risk.

---

### WR-02: `defer allocator.free(hop_edges)` fires after entries are moved — slice header freed with stale length

**File:** `src/agent/graph_expand.zig:171`
**Issue:** `hop_edges` is a `[]memory_root.TypedEdge` returned by `findEdgesByKeys`. The comment says "we move entries into all_edges." The loop at line 181 copies each `TypedEdge` value into `all_edges` via `try all_edges.append(allocator, e)`. In Zig, `TypedEdge` structs contain owned heap slices (`source_key`, `target_key`, `predicate`). When the struct value `e` is appended to `all_edges`, the struct is copied by value — the slice headers (pointer + length) are copied into `all_edges`, and `all_edges.errdefer` now owns their memory. The `defer allocator.free(hop_edges)` on line 171 then frees only the backing array of the `hop_edges` slice (the array of struct values), not the strings within each struct. This is correct: the struct values have been copied out, so freeing the outer backing array is safe.

However, if `all_edges.append` returns an error (OOM) mid-loop, the `errdefer` on `all_edges` will call `e.deinit(allocator)` on every entry it has accumulated — which frees the strings for those entries. The remaining entries still in `hop_edges` (not yet moved) have their strings freed by nothing when `allocator.free(hop_edges)` runs (it frees only the outer array). This is a latent memory leak: if append fails partway through, the not-yet-moved `TypedEdge` entries in `hop_edges` beyond the current loop index never have their string fields freed.

**Fix:** Add an explicit cleanup for the remainder of `hop_edges` if append fails:
```zig
for (hop_edges, 0..) |e, ei| {
    all_edges.append(allocator, e) catch |err| {
        // Free strings for entries we didn't move into all_edges.
        for (hop_edges[ei..]) |leftover| leftover.deinit(allocator);
        allocator.free(hop_edges);
        return err;
    };
    // ...
}
// After the loop: all entries moved; safe to free the outer slice.
defer allocator.free(hop_edges); // move earlier if loop refactored
```

---

### WR-03: `continue` in edge-write error path skips `written_count` increment after memory row is already persisted

**File:** `src/agent/extraction_persist.zig:636-640`
**Issue:** The `upsertMemoryEdge` call at line 629 is followed by a `log.warn` and a `continue` on error (lines 636-640 of the error block). The `continue` statement skips the `result.written_count += 1` increment on line 646. This means if the memory row was written successfully (line 564-575 succeeded) but the edge write fails, the fact is stored in the brain but `PersistResult.written_count` under-counts it. Any caller that uses `written_count` to log "N new facts learned this pass" will report fewer facts than were actually persisted — a silent correctness gap in observability.

**Fix:** Move the `written_count` increment before the edge write, since the memory row write is the authoritative "fact persisted" event:
```zig
// Log + count the persisted memory row BEFORE the optional edge write.
log.info("extraction.persisted key={s} subject={s} predicate={s} attributed_to={s}", ...);
result.written_count += 1;

// Edge write is best-effort; failure is non-fatal and does NOT un-persist the row.
if (target_key) |tk| {
    defer allocator.free(tk);
    state_mgr.upsertMemoryEdge(...) catch |err| {
        log.warn("extraction.edge_write_failed ...", .{...});
        // No continue — written_count already incremented above.
    };
}
```

---

### WR-04: Length check before constant-time compare leaks token length information

**File:** `src/gateway.zig:3039-3059`
**Issue:** `validateInternalServiceTokenWithPolicy` calls `constantTimeEqual(expected, provided)` at line 3058. The `constantTimeEqual` function correctly returns `false` early if `a.len != b.len` (line 3040). This early-return on length mismatch is a timing side-channel: an attacker who can measure response latency can distinguish "wrong length" from "right length, wrong bytes." The function is already at risk of the standard timing-attack concern on secrets. The length check in `constantTimeEqual` is the conventional mitigation: always run the full byte-comparison loop regardless of length by padding or by always comparing `min(a.len, b.len)` bytes plus a separate length equality bit.

For internal service tokens this is lower severity (attacker needs LAN access + sub-millisecond timing resolution), but the function is named `constantTimeEqual` and should behave as advertised.

**Fix:** Remove the early-return on length mismatch and fold length equality into the result:
```zig
fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    // Do NOT return early on length mismatch — that leaks length info.
    const min_len = @min(a.len, b.len);
    var result: u8 = 0;
    for (0..min_len) |i| result |= a[i] ^ b[i];
    // Also fold in length inequality so different-length inputs never match.
    const len_diff: usize = (a.len -% b.len) | (b.len -% a.len);
    result |= @as(u8, @truncate(len_diff | (len_diff >> 8) | (len_diff >> 16) | (len_diff >> 24)));
    return result == 0;
}
```

---

## Info

### IN-01: Three independent copies of `truncateUtf8` — consolidate into one helper

**Files:** `src/agent/extraction_persist.zig` (implicit in snippet block), `src/agent/memory_loader.zig:108-113`, `src/agent/commands.zig:618-623`
**Issue:** `truncateUtf8` is defined three times with functionally identical bodies. All three clips `max_len` bytes and backs up over UTF-8 continuation bytes. Divergence risk: if the logic is fixed in one place (see WR-01), the other two copies may not be updated. The canonical version lives in `memory_loader.zig`; the other two could import and call it.

**Fix:** Export `truncateUtf8` from one location (e.g. `src/util.zig` or `memory_loader.zig`) and replace the other two copies with a call to the canonical helper.

---

### IN-02: `keyFor` in `AppEventSubscriberRegistry` ignores its `user_id` parameter

**File:** `src/gateway.zig:685-688`
**Issue:** `keyFor` has signature `fn keyFor(allocator, user_id: []const u8, session_key: []const u8) ![]u8` and its entire body is `_ = user_id; return allocator.dupe(u8, session_key)`. The `user_id` parameter is silently discarded. All three call sites pass a `user_id` that is then ignored. The current composite key is just `session_key`, which means two users with the same `session_key` would alias to the same subscriber slot — a correctness risk in multi-tenant deployments if `session_key` values are not globally unique across users.

**Fix:** Either include `user_id` in the key, or remove the parameter from the signature to make the intent explicit. If `session_key` is already globally unique (per-user prefix guarantees this), document that invariant and remove the dead parameter:
```zig
fn keyFor(allocator: std.mem.Allocator, session_key: []const u8) ![]u8 {
    return allocator.dupe(u8, session_key);
}
```

---

### IN-03: Judge context not plumbed in session-end `persistExtracted` call — silent limitation

**File:** `src/agent/commands.zig:1382`
**Issue:** The `persistExtracted` call in the session-end triple-write loop passes `null` for `judge_ctx` with a `// judge_ctx — TODO V1.7 follow-up` comment. Without the judge, session-end extraction writes bypass contradiction detection and semantic dedup — only MD5 dedup applies. This means session-end can write semantically duplicate facts that the compaction pass would have caught. The TODO is intentional, but it should be tracked as a known gap rather than left as an unmarked comment.

**Fix:** No immediate code change needed. Add a log.info at the call site so the gap is visible in traces:
```zig
// judge_ctx intentionally null — contradiction judge not wired
// at session-end yet (commands.zig has no provider in scope).
// Track: V1.7 follow-up to plumb judge via extraction_state_mgr.
_ = extraction_persist.persistExtracted(
    self.allocator, smgr, uid, session_id, &mems,
    null, // judge_ctx — V1.7 follow-up
    coref_ctx,
) catch |err| { ... };
```

---

### IN-04: `loadContextWithRuntimeDetailed` and `loadContextDetailed` are near-identical — significant duplication

**File:** `src/agent/memory_loader.zig:439-778`
**Issue:** `loadContextDetailed` (lines 439-595) and `loadContextWithRuntimeDetailed` (lines 599-778) share the same bucket-routing logic, the same `seen_keys` dedup, the same summary_latest and durable_fact prioritisation, and the same global keyword fallback structure. The two functions are approximately 140 and 180 lines respectively. Any bug fix or bucket-limit change must be applied in both places. The primary difference is that the runtime-detailed path calls `rt.search` instead of `mem.recall` for the scoped candidates, and adds a `global_keyword_entries` path.

**Fix:** Extract the shared bucket-append logic into a private helper that both paths call after their respective candidate-fetch phase. This is a refactor, not a bug — but the duplication increases maintenance surface for what is already the most complex single function in the codebase.

---

### IN-05: `BRAIN_USER_KEY_FILTER` SQL regex built at comptime without escaping all Postgres regex meta-characters

**File:** `src/zaki_state.zig:66-89`
**Issue:** The comptime SQL filter escapes `.` (present in `__bootstrap.prompt.`) but the comment explicitly defers other meta-characters to "future prefixes." The current `BRAIN_HIDDEN_PREFIXES` list also includes entries like `session_checkpoint_` and `autosave_` whose characters are safe, but the `_` character in Postgres LIKE is a wildcard (not in regex). In regex, `_` is literal, so `session_checkpoint_` is correctly matched. However, if a future prefix is added containing `[`, `]`, `(`, `)`, `*`, `+`, `?`, `^`, `$`, or `{`, the comptime code will silently generate a malformed regex that matches the wrong keys or fails at runtime in Postgres.

**Fix:** Expand the escape set in the comptime builder to cover all Postgres regex meta-characters, not just `.`:
```zig
for (prefix) |ch| {
    switch (ch) {
        '.', '[', ']', '(', ')', '*', '+', '?', '^', '$', '{', '}', '|', '\\' => {
            s = s ++ "\\" ++ &[_]u8{ch};
        },
        else => s = s ++ &[_]u8{ch},
    }
}
```

---

_Reviewed: 2026-05-03T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
