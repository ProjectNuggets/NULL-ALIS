---
phase: v1.12-wiki-link-brain (Day 1-3)
reviewed: 2026-05-08
depth: standard+
files_reviewed: 6
files_reviewed_list:
  - src/agent/entity_pipeline.zig
  - src/tools/wiki_link.zig
  - src/agent/root.zig
  - src/agent/commands.zig
  - src/tools/root.zig
  - src/capabilities.zig
  - src/gateway.zig
findings:
  critical: 0
  high: 2
  medium: 5
  low: 6
  total: 13
status: issues_found
build: green
tests: green (zig build test passes; entity_pipeline tests included)
---

# V1.12 Wiki-Link Brain — Code Review (Days 1–3)

**Branch:** `v1.12/wiki-link-brain`
**Base:** `v1.11-channels`
**Commits reviewed:**
- `e5fa5b6` feat(brain): wiki-link entity pipeline + per-3-turn trigger (Day 1)
- `24a9eda` feat(brain): wire bindWikiLinkContext from gateway init (Day 2.1)
- `dc20979` feat(brain): session_end entity-pipeline trigger (Day 3.1)

## Summary

Solid, deliberate work. The pipeline is small and reuses existing primitives correctly (`findEntityByCosine`, `upsertEntity`, `upsertMemoryEdge`). Failure-soft contract is mostly honored. Test coverage on the JSON parser is good and exercises real adversarial inputs (code fences, prose prefix, Arabic/Mandarin, pronoun rejection, OOM-shaped large arrays).

Two HIGH-severity issues stand out:

1. **The per-3-turn trigger runs synchronously inside the user-visible turn loop**, before the reply is returned to the gateway. On non-streaming clients (and on the post-stream housekeeping path for streaming clients), this adds up to a 30-second LLM-call worst case to every third turn. The work is "best-effort enrichment", not user-blocking work — it should not be on the critical path.

2. **The `looksLikePronoun` Latin-only filter has buggy tokens** that include trailing commas as part of the string literal (`"yo,"`, `"tu,"`). Dead weight, but evidence the table was hand-rolled without verification, and `"él"` won't match capitalized forms because `std.ascii.toLower` no-ops on bytes ≥ 128. The defensive backstop is cosmetic for non-Latin scripts; that's acknowledged in the docstring, but the typos should be cleaned up.

Everything else is medium/low: a documented OOM-leak path in `runOnTurn` (acknowledged in code), an undocumented memory leak in the JSON parse struct-literal path on partial OOM, a stats field (`edges_skipped`) declared but never set, and several observability/UX papercuts.

No critical issues. No security concerns. Allocator hygiene across module boundaries (specifically `upsertEntity` returning caller-allocator-owned memory) is correctly preserved.

---

## Critical Issues

(none)

---

## High

### HI-01: Per-3-turn trigger blocks the user-visible turn

**Files:**
- `src/agent/root.zig:3851-3913` (per-3-turn trigger)
- `src/agent/commands.zig:1462-1500` (session_end pass)

**Issue:**
The trigger runs `entity_pipeline.runOnTurn(...)` synchronously inside the iteration loop, in the post-reply housekeeping block (after `final_text` is computed but before `turn_complete` is recorded). The pipeline does:

1. One LLM call (`extractMentions`, `timeout_secs=30`)
2. N embedding calls (one per resolved mention, up to 24)
3. N cosine queries against `memory_entities`
4. O(N²) edge upserts

In the non-streaming code path, `agent.turn()` doesn't return to the gateway until every byte of this finishes. On streaming clients the user has already seen tokens by the time this fires, but the SSE `turn_complete` frame is delayed accordingly — and any subsequent input from the user is gated on the previous turn finishing (session mutex held).

The pipeline is forward-flow enrichment of the brain graph. It has no semantic dependency on the user's current reply. It is not on the critical path for any user-visible behavior. Putting it here means every 3rd turn (and every session-end) eats the latency budget of a Kimi K2.6 round trip plus N embedding calls.

**Why this is HIGH not MEDIUM:**
Three reasons compound:
- The per-3-turn cadence and the session-end pass can both fire in close succession (turn 3 hits the cadence; eviction or hibernate kicks in shortly after; same path runs again).
- The 30s timeout means a flaky provider call lengthens the user's perceived turn duration to 30s+ even when the actual reply was generated in 2s.
- The session-end pass runs from `evictIdle` while holding `session.mutex`, blocking any new request that races against eviction for the same session.

**Fix:**
Move both triggers off the critical path. Two acceptable shapes:

a) **Background goroutine**: spawn a detached Zig thread that owns its own arena allocator, runs the pipeline, and uses the existing observer event bus to surface stats. The `state_mgr`, `provider`, and `embedder` are already thread-shared in the rest of the codebase.

b) **Outbox pattern**: enqueue a "wiki_link_due" job to the durable outbox (which `mem_rt.drainOutbox` already runs at end of turn — see `root.zig:3760-3766`). The drain runs after `turn_complete` and is already designed for this kind of best-effort post-turn work.

Option (b) is closer to what `extraction_persist` does today and reuses existing failure-soft machinery. Pick whichever matches the V1.11 outbox contract.

If you must keep this synchronous in V1.12, drop the timeout to ~5s and document the latency budget in the trigger comment. Don't ship this as-is at 30s without a UX-visible "linking brain..." indicator.

---

### HI-02: `looksLikePronoun` table contains malformed entries

**File:** `src/agent/entity_pipeline.zig:319-324`

**Issue:**
```zig
const tokens = [_][]const u8{
    "i",   "me",   "you",  "he",  "she", "it",
    "we",  "they", "them", "us",  "him", "her",
    "yo",  "tu",   "él",   "yo,", "je",  "tu,",
    "wo",  "ni",   "ta",
};
```

`"yo,"` and `"tu,"` are dead entries — they include literal trailing commas inside the string. They will never match a clean canonical form (no production-quality LLM emits a comma inside an entity name). They look like the result of a copy-paste from a comma-separated list where the editor didn't strip the trailing comma. Harmless, but it's a tell that the table wasn't proof-read.

`"él"` is bytes `0xC3 0xA9` (UTF-8). The lowercase compare uses `std.ascii.toLower` which only acts on ASCII; capitalized `"Él"` (`0xC3 0x89`) would not match because byte `0x89` stays `0x89`. The Spanish variant only triggers if the LLM happens to lowercase its output. The docstring says this is "NOT a primary defense" — fine — but if the goal is to catch slipped pronouns, the failure mode is ~50% effective at best for non-ASCII.

**Why this is HIGH not LOW:**
The bug is small in code, but it sits inside the only multilingual safety net the pipeline has. A V1.12 brain page that surfaces "yo" as a PERSON node because the LLM slipped is a visible quality bug, attributed to Mohammad's brain page launch. Better to fix the table now than apologize later.

**Fix:**
1. Drop the `"yo,"` and `"tu,"` entries. They are typos.
2. Either case-fold UTF-8 properly (use `std.unicode` + a small lowercase map for accented Latin) or remove `"él"` and document the limitation explicitly.
3. Add a test that asserts the canonical-form table contains no commas: `for (tokens) |t| try std.testing.expect(std.mem.indexOfScalar(u8, t, ',') == null);` so regressions fail loud.

---

## Medium

### ME-01: `RunStats.edges_skipped` declared but never written

**File:** `src/agent/entity_pipeline.zig:135`

**Issue:**
```zig
pub const RunStats = struct {
    mentions_extracted: usize = 0,
    entities_resolved: usize = 0,
    entities_minted: usize = 0,
    edges_emitted: usize = 0,
    edges_skipped: usize = 0,    // ← declared, never assigned
    llm_latency_ms: i64 = 0,
    failed_mentions: usize = 0,
};
```

`emitCooccurrenceEdges` and `emitSpeakerEdges` count emitted edges and silently drop failures (`continue` on error). The skipped count is never propagated up. Either implement it (return `(emitted, skipped)` tuple from each emit fn and aggregate) or remove the field. Right now it's a documentation lie — the brain page or any consumer reading `stats.edges_skipped` will always see 0 and believe nothing was skipped.

**Fix:** Change the emit-edge helpers to return both counts, aggregate, and record. ~10 lines.

---

### ME-02: Memory leak on partial-OOM in `parseMentionsJson` struct-literal construction

**File:** `src/agent/entity_pipeline.zig:264-269`

**Issue:**
```zig
try out.append(allocator, .{
    .surface = try allocator.dupe(u8, surface),
    .canonical = try allocator.dupe(u8, canonical),
    .entity_type = try allocator.dupe(u8, entity_type),
    .confidence = conf,
});
```

If `dupe(canonical)` succeeds but `dupe(entity_type)` OOMs, the bytes for `surface` and `canonical` are leaked because the struct is never constructed and `errdefer` only frees items already in `out`. Same issue if `dupe(canonical)` OOMs after `dupe(surface)` succeeded.

**Fix:** Dupe into local variables first, then append; on failure free the locals via `errdefer`. Or swap to an arena allocator scoped to the parse function. The latter is what most Zig codebases use for parser ergonomics.

```zig
const surface_dup = try allocator.dupe(u8, surface);
errdefer allocator.free(surface_dup);
const canonical_dup = try allocator.dupe(u8, canonical);
errdefer allocator.free(canonical_dup);
const type_dup = try allocator.dupe(u8, entity_type);
errdefer allocator.free(type_dup);
try out.append(allocator, .{
    .surface = surface_dup,
    .canonical = canonical_dup,
    .entity_type = type_dup,
    .confidence = conf,
});
```

---

### ME-03: `runOnTurn` cannot surface "LLM call failed" vs "no entities found"

**File:** `src/agent/entity_pipeline.zig:558-568`

**Issue:**
When `extractMentions` itself fails (HTTP error, 429, etc.) it logs and returns an empty slice. `runOnTurn` then sees `mentions.len == 0` and returns `stats` with `mentions_extracted = 0`. The wiki_link tool's stat summary now reads:

```
wiki_link: extracted 0 mentions, resolved 0 (minted 0), emitted 0 edges, 0 failed (latency 1834ms)
```

A reader can't distinguish:
- `0 mentions` because the turn was small talk → expected behavior
- `0 mentions` because the LLM call timed out → silent failure

This collides with the "no silent fallback" project rule (the binding principle in `observability.zig:132-136`).

**Fix:** Add `extractor_status: enum { ok, llm_error, parse_error, empty }` to `RunStats`, set it in `extractMentions` and propagate. The tool can then echo it. Less than 20 lines.

---

### ME-04: `entity_pipeline` events not in the canonical observability vocabulary

**File:** `src/agent/root.zig:3904-3910`

**Issue:**
The trigger emits a `turn_stage` event with `stage = "entity_pipeline"`. The canonical `turn_stage` field set is `{stage, iteration, duration_ms, count, tool_use_id, task_id, group_id, heartbeat, command, files, run_id}`. The trigger sets `iteration`, `count = stats.edges_emitted`, `run_id` — but does NOT set `duration_ms`, even though `stats.llm_latency_ms` is right there.

Other stages (post_reply_compaction, autosave_assistant, drain_outbox, compose_final_reply) all populate `duration_ms`. The brain page or operator dashboard plotting "wall-clock spent in each turn stage" will silently undercount entity_pipeline time.

The session_end pass in `commands.zig` emits no observability event at all — only a `log.info` line. Inconsistent with the trigger in `root.zig` and inconsistent with the rest of `persistSessionSemanticSummary` which emits structured events for the summarizer stage.

**Fix:**
1. In `root.zig:3904`, set `.duration_ms = @intCast(@max(0, stats.llm_latency_ms))`.
2. In `commands.zig:1487`, emit an `ObserverEvent.turn_stage` matching the root.zig shape.

---

### ME-05: Extraction LLM call is not cached or deduped against the user's own message

**File:** `src/agent/entity_pipeline.zig:339-407`

**Issue:**
`extractMentions` always calls `provider.chat`. The same conversation pair (`user: hi` + `assistant: hello`) on consecutive turn-3 boundaries with identical prompt would re-call the LLM. There is no fingerprint check against a recent-extraction LRU. For the per-3-turn cadence this is fine, but the session-end pass fires over the whole session transcript every time — and a long-running session with multiple `compact:auto` boundaries would re-extract the same prefix many times.

This isn't a correctness issue (idempotent edge writes preserve correctness), but it's a cost issue: every persistSessionCheckpoint call eats one LLM round-trip and N embedding calls.

**Fix:**
A simple md5 of the truncated turn_text → store in `extraction_state_mgr`'s scratch table → skip the call if hashed within the last hour. Or just accept the cost and document it. Either is fine; pick one.

---

## Low

### LO-01: `runOnTurn` documented OOM leak path

**File:** `src/agent/entity_pipeline.zig:589-594`

The comment `// r leaks here; acceptable on OOM` is honest. Acceptable for V1.12.

If you ever see this leak fire in production logs (the `append failed` log line), revisit. For now: ✓ acknowledged.

---

### LO-02: `buildRecentTurnText` uses O(N²) prepend pattern

**File:** `src/agent/root.zig:4960-4965`

```zig
try line_buf.writer(allocator).print("{s}: {s}\n", .{ role_str, content_slice });
try collected.insertSlice(allocator, 0, line_buf.items);
```

The `insertSlice(0, ...)` pattern memmoves the entire collected buffer for each prepend. Bounded by `MAX_BYTES = 3072` and `msgs_collected < 8`, the worst-case work is ~24 KB of memmove. Acceptable, but if you ever loosen those caps this will become a real cost.

The simpler shape:
1. Walk newest→oldest, append to a list of messages (don't write yet).
2. Reverse the list.
3. Print each in order into the final buffer.

But again — at 8×3KB the savings are imperceptible. Fix only if it migrates to a hot path.

---

### LO-03: Empty `allocator.alloc(u8, 0)` returns

**File:** `src/agent/entity_pipeline.zig:208, 213, 219`

`parseMentionsJson` returns `try allocator.alloc(EntityMention, 0)` for a few short-circuit paths. This is safe in practice (Zig's standard allocators accept zero-length frees), but emits an allocation that the caller must remember to free. `freeMentions` correctly handles empty slices (`for` over empty slice is a no-op, free of empty slice is allocator-defined). Tested via `parseMentionsJson — empty array` test. ✓

Mention only because some tooling/sanitizers complain about zero-length allocs — if Nova ever turns on AddressSanitizer-style auditing, this surfaces. Not a bug today.

---

### LO-04: Tool-tests for `WikiLinkTool` exercise only the unwired-tenant path

**File:** `src/tools/wiki_link.zig:164-184`

The two `execute` tests only assert that calling without tenant returns `success = false`. There is no test that exercises a wired tool against a stub provider + stub state_mgr (the way `extraction_persist` tests do). The pipeline itself is tested via JSON-parse tests in `entity_pipeline.zig`, but the orchestrator path (`runOnTurn`) has no end-to-end test.

V1.12 Day 4/5 should add at least one stub-provider test that proves: stub returns `[{"surface":"X","canonical":"X","type":"PERSON","confidence":0.9}]` → tool returns `success=true` with `mentions_extracted=1`.

---

### LO-05: `WIKI_LINK_ATTRIBUTION` constant not surfaced in any consumer-facing schema

**File:** `src/agent/entity_pipeline.zig:85`

The `"wiki_link"` attribution string is hardcoded here and lives in the database. Hygiene jobs / brain page rendering need to know the magic string to filter wiki-link edges from extraction-classifier edges. Right now the only documentation is the comment in this file. If a consumer (BFF, brain page, hygiene job) hardcodes their own copy of the string and these drift, you get silent classification bugs.

**Fix:** Move `WIKI_LINK_ATTRIBUTION` to `memory/root.zig` next to `EntityRow` so both `entity_pipeline.zig` and any consumer (`brain_graph.zig`, future hygiene jobs) can `@import` it from one source of truth. Same advice for `COOCCURS_PREDICATE` and `SPEAKER_PREDICATE`.

---

### LO-06: `extractMentions` does not propagate `reasoning_content` cleanup before `parseMentionsJson` could panic on short alloc

**File:** `src/agent/entity_pipeline.zig:382-399`

The defer block frees `resp.content`, `resp.model`, `resp.reasoning_content`, and `resp.tool_calls`. Style is correct (matches `agent/edge_resolution.zig::freeChatResponse` and `agent/root.zig::freeResponseFields`). However, by inlining the free instead of calling a shared helper, this is the third copy of "how to free a ChatResponse" in the codebase. If the response struct grows a new owned field, this is the file most likely to be missed.

**Fix:** Promote `freeChatResponse` from `agent/edge_resolution.zig:469` to `providers/root.zig` as `pub fn ChatResponse.deinit(self: *ChatResponse, allocator)` so all callers get fixed at once. Out of scope for V1.12 Day 4 but worth tracking.

---

## Answers to your direct questions

1. **Memory leaks in the LLM response cleanup (defer block in `extractMentions`)?**
   No primary leaks. The defer block matches the canonical pattern in `edge_resolution.zig::freeChatResponse`. Free order is correct (free fields, no double-free). The duped strings inside `parseMentionsJson` are independent of `resp.content`'s lifetime. ✓

2. **Is `runOnTurn` truly failure-soft on every error path?**
   Yes for surface failures. Every `try` is wrapped in a `catch` that logs and continues. The one acknowledged leak (resolved.append on OOM) is tolerable. ✓ — modulo HI-01 which says: failure-soft *and* on the user's critical path is the worst combination, because a hung LLM call still steals 30s of the user's turn even though it "didn't fail loudly".

3. **Does the per-3-turn trigger correctly handle empty/all-system/all-tool history?**
   Yes. `buildRecentTurnText` filters to user/assistant only, returns empty slice for no-content history. `runOnTurn` short-circuits at `if (turn_text.len < 8) return stats;`. ✓

4. **Is the observability event emission consistent with existing patterns?**
   Mostly. See ME-04: missing `duration_ms` on the trigger event, and the session-end pass emits no event at all. Otherwise the field shape is correct.

5. **Concurrency hazards if entity_pipeline is called from session_end while a turn is in flight?**
   No data-race hazards on the same session — `evictIdle` requires `session.active_refs == 0` AND `session.mutex.tryLock()` succeeds before the candidate is checkpointed. So there's no concurrent turn on the same session.
   But: while session_end runs the LLM call (~30s timeout), the session mutex is held. A new request for the same session will block on the mutex for the duration. That's not a bug — it's the contract of `evictIdle` — but it does mean a user who reconnects right at eviction time waits 30s for the wiki_link pass to finish before their new turn begins. See HI-01 for the mitigation.

   No data races on `memory_entities`/`memory_edges`: those writes are protected by the database (PostgreSQL row locks, ON CONFLICT). The pipeline doesn't share Zig-level state across threads.

---

## Build + test status

- `zig build` — clean (no errors, no warnings on this branch).
- `zig build test` — green. Includes the 14 new tests in `entity_pipeline.zig` and the 4 new tests in `wiki_link.zig`. The "tools count = 44" assertions in `tools/root.zig` were updated correctly.

---

_Reviewed: 2026-05-08_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard+ (single-language Zig + cross-file wiring trace)_
