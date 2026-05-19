---
phase: v1.14-edge-richness
reviewed: 2026-05-08T00:00:00Z
depth: deep
files_reviewed: 4
files_reviewed_list:
  - src/zaki_state.zig
  - src/agent/extraction_persist.zig
  - src/agent/compaction.zig
  - src/agent/entity_pipeline.zig
commits_reviewed:
  - 5218e98 feat(brain): edge richness — fact + temporal_anchor + episodes (V1.14)
  - 68f0745 feat(brain): wiki_link path also populates fact + episodes (V1.14.2)
findings:
  critical: 0
  high: 0
  medium: 4
  low: 4
  info: 3
  total: 11
status: ship_with_followups
---

# V1.14 Final Code Review — Edge Richness

**Branch:** `v1.14/edge-richness`
**HEAD:** `68f0745`
**Reviewed:** 2026-05-08
**Depth:** deep (cross-file, SQL semantic verification, hand-traced date arithmetic)
**Verdict:** SHIP. The two commits are correct, additive, backwards-compat, and build clean. No CRITICAL or HIGH findings. Four MEDIUMs and four LOWs are queued for V1.15 follow-up — none block ship.

## Summary

V1.14 is the first edge-schema change since V1.6 cmt7 (the original `memory_edges` materialized graph). The work plumbs three new columns (`fact TEXT`, `temporal_anchor_unix BIGINT`, `episodes TEXT[]`) end-to-end from extractor LLM → JSON parser → SQL upsert, plus a follow-up that wires the wiki_link entity_pipeline path through the same rich variant. Schema migration is idempotent (`ADD COLUMN IF NOT EXISTS`), columns are nullable / default-empty so existing rows are unaffected, no downstream `SELECT *` exists on `memory_edges`, and the legacy 6-arg `upsertMemoryEdge` is preserved as a wrapper so the 5 existing callers (gateway tests + 4 in-file tests) compile unchanged.

The primary risk surface — getting the 9-param SQL upsert correct, particularly the `episodes` array dedup-on-append idiom and the 9/9 params/lengths array shape — checks out. The minor risk surface — the hand-rolled ISO-8601 date parser — is correct for valid inputs and fails-soft on malformed ones.

The remaining items are quality concerns, not correctness concerns. Most material: the `fact = COALESCE(existing, new)` semantic chooses **first-mention prose wins**, which is debatable; for stable predicates this is fine, for evolving facts it freezes the first phrasing forever. Acceptable for V1.14 ship; flag for V1.15 reconsideration.

---

## Medium Findings

### MD-01: `fact` COALESCE semantic freezes first phrasing forever

**File:** `src/zaki_state.zig:6792`
**Issue:** The ON CONFLICT update uses `fact = COALESCE({schema}.memory_edges.fact, EXCLUDED.fact)`. This keeps the **first** non-null fact prose across re-mentions of the same triple. The commit message explicitly documents this as "keep first non-null prose", and the comment at line 6764 also says "keep first non-null prose". So code matches intent.

But the user-facing implication is non-obvious: if the LLM extracts "Alfred works at Google" on day 1 and later extracts a more detailed "Alfred works at Google as VP of engineering since 2024" on day 5, the brain page will render the day-1 phrasing forever. The richer day-5 prose is silently dropped at the edge level (the source memory row still has it, but the materialized edge does not).

For `temporal_anchor_unix` keeping the **oldest** anchor is unambiguously correct (you want when-the-fact-began, not when-it-was-last-mentioned), so the COALESCE order there is right. For `fact` it's a value judgement.

**Severity:** MEDIUM — semantic, not a bug. Worth a deliberate decision in V1.15.

**Fix options for V1.15:**
1. Keep latest: `fact = COALESCE(EXCLUDED.fact, {schema}.memory_edges.fact)` — newest wins. Simple but loses early phrasing.
2. Keep longest: `fact = CASE WHEN length(COALESCE(EXCLUDED.fact, '')) > length(COALESCE({schema}.memory_edges.fact, '')) THEN EXCLUDED.fact ELSE {schema}.memory_edges.fact END` — heuristic for "more detailed wins".
3. Append all to a `facts TEXT[]` column — most flexible, mirrors how `episodes` works. Probably the right long-term shape.

No change required for V1.14 ship. Flag in V1.15 plan.

---

### MD-02: Empty-string fact is written as empty string, not NULL — inconsistent with attribution

**File:** `src/zaki_state.zig:6818-6836`
**Issue:** The `attribution` parameter handling (line 6809-6812 region):
```zig
if (attr_text.len == 0) null else attr_z,
```
treats empty-string-but-non-null as if it were NULL. The `fact` parameter handling (line 6836):
```zig
if (fact == null) null else fact_z,
```
checks only for the optional being null — an explicit empty string `""` would be sent as a non-NULL empty string to PG. Then COALESCE(memory_edges.fact, EXCLUDED.fact) treats `''` as a valid non-null value, and the empty string sticks for all future re-mentions of that triple.

**Impact in practice:** Low risk on the extraction path because `parseExtractedJson` rejects `text.string.len < 3` (line 251). The wiki_link path uses `std.fmt.allocPrint("{s} co-occurred with {s} ...")` which always produces non-empty output. So no current caller can hit this. But it's a latent footgun: any future caller passing `""` will pollute the column.

**Severity:** MEDIUM — latent, not active. Trivial to fix.

**Fix:**
```zig
if (fact == null or fact.?.len == 0) null else fact_z,
```
And similarly for `episode_key`:
```zig
if (episode_key == null or episode_key.?.len == 0) null else ep_z,
```
The `episode_key` empty-string case would cause `array_append(episodes, '')` — silently inserting an empty string into the provenance array. Same fix.

---

### MD-03: `emitCooccurrenceEdges` allocator inconsistency — uses `std.heap.page_allocator` while sibling `emitSpeakerEdges` takes an allocator parameter

**File:** `src/agent/entity_pipeline.zig:564-568, 591-596`
**Issue:** `emitCooccurrenceEdges` signature does NOT take an allocator:
```zig
pub fn emitCooccurrenceEdges(
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    resolved: []const ResolvedEntity,
    confidence: f64,
) !EmitResult
```
Yet inside it allocates `fact_buf` from `std.heap.page_allocator`. Sibling `emitSpeakerEdges` (line 624) DOES take an allocator parameter and uses it. The asymmetry is jarring and the page_allocator choice is wasteful — page_allocator rounds every allocation up to a 4 KiB OS page. A turn with 10 resolved entities produces up to 45 cooccurrence pairs; that's 45 × 4 KiB = 180 KiB churn per emit for ~80-byte fact strings.

Functionally correct (page_allocator is a real allocator and `defer free` matches), but a code smell.

**Severity:** MEDIUM — wastes memory, signals that the allocator threading was incomplete. Not a bug.

**Fix for V1.15:** Add an `allocator: std.mem.Allocator` parameter to `emitCooccurrenceEdges` and update the single caller in `runEntityPipeline` (orchestrator block ~line 670+). Match the signature shape of `emitSpeakerEdges`.

---

### MD-04: Date parser accepts impossible dates (Feb 30, April 31)

**File:** `src/agent/extraction_persist.zig:278-280`
**Issue:** The validation is range-only:
```zig
if (year < 1970 or year > 2100) break :blk null;
if (month < 1 or month > 12) break :blk null;
if (day < 1 or day > 31) break :blk null;
```
There's no per-month day-count check. The LLM could emit `"2020-02-30"` and the parser would silently produce a wrong-by-2 unix timestamp (computes day 31+28+29 = day 88 of year, i.e. ~March 30). Similarly `"2026-04-31"` becomes May 1.

I traced the leap-year arithmetic by hand for several cases (1970-01-01, 1970-03-01, 2020-03-01, 2020-02-15, 2020-02-29, 2021-03-01) — the **valid-input** logic is correct, including the leap-day handling on month==1 (February has the leap-day check inside the inner loop body, only triggered when crossing past February). No off-by-one in the leap math.

**Severity:** MEDIUM — silent data corruption rather than a crash. Probability of LLM emitting an impossible date is low (Kimi K2.6 is well-calibrated on dates) but non-zero.

**Fix:**
```zig
const max_day: u8 = switch (month) {
    1, 3, 5, 7, 8, 10, 12 => 31,
    4, 6, 9, 11 => 30,
    2 => blk2: {
        const leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
        break :blk2 if (leap) 29 else 28;
    },
    else => unreachable,
};
if (day < 1 or day > max_day) break :blk null;
```

---

## Low Findings

### LO-01: `fact` column is write-only — no read path renders it yet

**File:** all V1.14 changes
**Issue:** V1.14 plumbs writes for `fact`, `temporal_anchor_unix`, and `episodes`, but no SELECT statement on `memory_edges` projects these columns. The brain page rendering and agent recall block continue to return predicate triples without prose. The commit message and inline docs both promise "Brain page rendering becomes scannable; agent recall returns prose instead of triple soup" — that promise is **deferred** until a read patch lands.

This is fine — the writes need to land first so a future read patch has data to project — but the V1.14 ship note should be explicit that user-visible improvement is V1.14.x or V1.15, not V1.14 itself.

**Severity:** LOW — accuracy of release messaging.

**Fix:** Add a "V1.14.3 read-projection" item to the V1.15 plan: extend the relevant SELECT statements (search for `FROM {schema}.memory_edges` — lines 4076, 4133, 4230, 4298, 5670, 6967, 7061 are candidates) to include `fact`, `temporal_anchor_unix`, `episodes` and surface them in the brain page + agent recall renderers.

---

### LO-02: ISO-8601 parser drops time component — anchors land at midnight UTC

**File:** `src/agent/extraction_persist.zig:264-302`
**Issue:** The parser reads only `iso[0..10]` (YYYY-MM-DD), ignoring any `Thh:mm:ss[Z]` suffix that the prompt encourages the LLM to emit (`"2020-01-01T00:00:00Z"`). Result is `days * 86400` — exactly midnight UTC of the named date. The comment acknowledges this: "Acceptable approximation but losing the time component if the LLM produced one."

For brain-graph time anchoring this is fine; we don't need second-resolution. Documenting the choice clearly so it doesn't surprise future-Mohammad.

**Severity:** LOW — documented limitation, not a bug.

**Fix for V1.15:** If sub-day resolution becomes needed, parse `iso[11..13]` hour, `iso[14..16]` minute, `iso[17..19]` second, add the seconds to the result. Keep failure-soft (extra parse failures → fall back to midnight).

---

### LO-03: `entity_pipeline` synthesized facts use static templates — no canonical_name escaping

**File:** `src/agent/entity_pipeline.zig:591, 641`
**Issue:** Templates:
- `"{s} co-occurred with {s} in conversation"`
- `"user mentioned {s}"`

`canonical_name` is interpolated raw. If a canonical_name contains a quote or a brace, it lands in the `fact` TEXT column unchanged. PG TEXT handles arbitrary bytes fine, so no SQL injection risk (libpq parameterization protects us). But the rendered prose on the brain page could contain characters that break HTML/markdown rendering depending on the renderer's escape discipline.

Out of scope for V1.14 (the brain page renderer is the right place to escape, not the writer). Flagging because the data shape now includes user-controlled prose in a column whose downstream consumer hasn't been audited.

**Severity:** LOW — defensive; no current attack surface.

**Fix for V1.15 read-projection patch:** When the brain page consumes `fact`, ensure HTML escape on render. (This is standard practice — flagging only because V1.14 introduces the first user-controlled prose column on `memory_edges`.)

---

### LO-04: Test coverage gap — no unit tests for V1.14 paths

**File:** repo-wide
**Issue:** Test count is 5972/6032 unchanged from V1.13. The new code paths exercised:
- `parseExtractedJson` with `valid_at` field (positive, malformed, missing — all three branches)
- `upsertMemoryEdgeRich` with NULL-vs-non-NULL combinations (especially the `episodes` dedup-on-append idempotency)
- The 6-arg `upsertMemoryEdge` wrapper still works (regression coverage for existing callers)
- `entity_pipeline` rich-path edge emission

are exercised only by integration / live verify (the V1.14.2 commit message confirms live verify caught the wiki_link gap).

**Severity:** LOW — V1 ship convention is integration-tested; flag as V1.15 follow-up.

**Fix for V1.15:** Add a `test "upsertMemoryEdgeRich idempotent episodes append"` next to the existing `upsertMemoryEdge` tests around line 10918. Three cases worth covering:
1. First insert with `episode_key="m1"` → row has `episodes={'m1'}`.
2. Re-mention with `episode_key="m2"` → row has `episodes={'m1','m2'}`, weight bumped.
3. Re-mention with `episode_key="m1"` again → row has `episodes={'m1','m2'}` (dedup), weight bumped.

Plus a parser test: feed a JSON with `valid_at: "2020-06-15"` and assert `temporal_anchor_unix == 1592179200` (verify by hand: 50yr + 31+29+31+30+31+14 = days; days * 86400).

---

## Info

### IN-01: SQL idiom verification — `$9::text = ANY(arr)` membership check

**File:** `src/zaki_state.zig:6796`
**Verified:** This is the canonical PG idiom for "does this scalar exist in this array". Uses the array's element-equality operator. Returns false for empty arrays, true for arrays containing the scalar. The `::text` cast ensures unambiguous typing when the parameter is sent in text format.

The `CASE WHEN $9::text IS NULL THEN '{}'::text[] ELSE ARRAY[$9::text] END` initial-value idiom is also correct PG. `'{}'::text[]` is the empty text array literal; `ARRAY[$9::text]` is a single-element constructor. Both produce `text[]` so the CASE branches type-unify. ✓

### IN-02: 9 params, 9 lengths — count match verified

**File:** `src/zaki_state.zig:6829-6849`
**Verified:** Hand-counted both arrays:

params: `user_s.ptr, src_z, tgt_z, pred_z, attr_or_null, conf_or_null, fact_or_null, anchor_or_null, ep_or_null` → 9 entries.

lengths: `user_s.len, src_key.len, tgt_key.len, predicate.len, attr_text.len, conf_text.len, fact_text.len, anchor_text.len, ep_text.len` → 9 entries.

Query has `$1..$9`. All three numbers agree. ✓

(Side note: `lengths` is largely a no-op in this code path. `execParams` calls `PQexecParams` with `paramFormats=null`, meaning all params are interpreted as text format, and for text format libpq ignores `lengths` and uses null-termination. Lengths matters only for binary-format params. So the array shape correctness here is defense-in-depth — wrong-length-but-right-count would still execute correctly.)

### IN-03: Schema migration safety verified

**File:** `src/zaki_state.zig:1488-1490`
**Verified:** All three statements are `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, which is idempotent per PG. Re-running migrate is safe. PG ≥ 11 fast-paths `ADD COLUMN` with non-volatile DEFAULT (the `'{}'` literal qualifies) — no table rewrite, no downtime, existing rows logically read the default. Confirmed no `SELECT *` on `memory_edges` anywhere in the codebase, so column-position-dependent reads cannot break. ✓

---

## Concerns Addressed

The user explicitly listed seven critical concerns. Status:

| Concern | Status |
|---|---|
| 1a. `CASE WHEN $9::text IS NULL THEN '{}'::text[] ELSE ARRAY[$9::text] END` PG idiom | ✓ Verified correct (IN-01) |
| 1b. ON CONFLICT episodes dedup-on-append | ✓ Verified correct; `$9 = ANY(arr)` is the canonical idiom (IN-01) |
| 1c. `COALESCE(existing.fact, EXCLUDED.fact)` first-vs-latest semantic | Documented as MD-01 — debatable, not a bug |
| 1d. 9 params vs 9 lengths count match | ✓ Verified (IN-02) |
| 1e. `if (fact == null) null else fact_z` empty-string edge case | Caught as MD-02 — latent, no current caller hits it |
| 2a. emitCooccurrenceEdges page_allocator | Caught as MD-03 — wasteful, not incorrect |
| 2b. emitSpeakerEdges allocator inconsistency | Same root cause as MD-03 |
| 2c. defer pattern handles early-return | ✓ Verified — defers are inside loop bodies, no early returns post-alloc |
| 3. Date parser leap-year off-by-one | ✓ Verified by hand for 6 cases; logic correct |
| 3. Date parser invalid-day check | Caught as MD-04 — accepts Feb 30 |
| 3. Loses time component | Documented as LO-02 — acceptable |
| 4a. Existing rows with NULL fact break read paths | ✓ No read paths project new columns yet (LO-01) |
| 4b. 6-arg wrapper preserves existing callers | ✓ Verified — wrapper delegates with NULLs, all 5+ existing callers unchanged |
| 5. Test coverage gap | Documented as LO-04 |
| 6a. ALTER TABLE idempotent | ✓ Verified (IN-03) |
| 6b. SELECT * on memory_edges | ✓ None exist; column position safe |
| 7a. JSON parser tolerates new optional field | ✓ Verified — uses `object.get()` selectively |
| 7b. LLM "OMIT" guidance compliance | Out of scope for static review — runtime behavior; recommend live-verify against Kimi K2.6 |

---

## Ship Recommendation

**SHIP.** Both commits are correct, the schema migration is safe, the SQL is right, the date arithmetic is right, the legacy 6-arg wrapper preserves backwards compat, and the build is clean.

Open V1.15 work items derived from this review:

1. **MD-01** — Decide `fact` COALESCE direction (or move to `facts TEXT[]`)
2. **MD-02** — Treat empty-string fact/episode_key as NULL (defensive)
3. **MD-03** — Thread allocator into `emitCooccurrenceEdges`
4. **MD-04** — Per-month day-count validation in date parser
5. **LO-01** — V1.14.3 read-projection: surface fact/anchor/episodes in brain page + recall block
6. **LO-02** — Optionally extend ISO-8601 parser to read time component
7. **LO-03** — HTML-escape `fact` on the brain page renderer
8. **LO-04** — Unit tests for `upsertMemoryEdgeRich` idempotency + `parseExtractedJson` valid_at variants

None block V1.14 ship.

---

_Reviewed: 2026-05-08_
_Reviewer: Claude (gsd-code-reviewer, opus 4.7 / 1M context)_
_Depth: deep_
_HEAD: 68f0745c858d3ea2ff87b9b850ff4a657f51c256_
