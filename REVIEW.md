---
phase: v1.5.1-brain-hygiene
reviewed: 2026-05-01
reviewer: Claude (self-review, same bar as gsd-code-reviewer)
scope_commits:
  - d0c86db feat(brain): hide agent bookkeeping from /brain/* surfaces
  - 5654e65 fix(brain): lazy-init tenant runtime in /brain/graph dispatch
files_reviewed:
  - src/memory/root.zig (isBrainVisibleKey, classifyArtifactKey audit_shell/ extension)
  - src/zaki_state.zig (BRAIN_USER_KEY_FILTER, listMemoriesBrainVisible, listMemoriesTimeline filter, cross-check test)
  - src/gateway.zig (handleBrainGraph switch, /brain/graph dispatch lazy init)
findings:
  critical: 0
  warning: 2
  info: 3
  obsidian_parity_gaps: 3
status: ship_with_warnings_addressed
---

# V1.5.1 Brain Hygiene + semantic_degraded — Self Code Review

**Reviewed:** 2026-05-01
**Bar:** S-tier — same standard the FE agent applied to Phase-1.

## Summary

Two commits land brain-page hygiene + restore semantic edges. The structure is sound: single Zig predicate as source of truth, SQL constant mirroring it, cross-check test pinning the two together. End-to-end verification on live PG passed.

Two warnings worth fixing before "we move on":

1. **WR-01:** Cross-check test is textual-grep, not behavioral. Won't catch a regex that *contains* the prefix string but doesn't *match* it (e.g. someone wraps a prefix in `(?:...)` with a typo).
2. **WR-02:** No PG smoke test exists for the brain-hygiene path. The integration test pattern is established (chunk 3A/3C/4A test at zaki_state:4257) but I didn't extend it. A live-DB roundtrip catches drift the unit test can't.

Three info-level notes. Three Obsidian-parity gaps that are V1.6+ enhancements, not V1.5 blockers.

---

## Warnings

### WR-01: Cross-check test asserts substring presence, not regex behavior

**File:** `src/zaki_state.zig` (the `BRAIN_USER_KEY_FILTER mirrors memory_root.isBrainVisibleKey` test)

**Issue:** The SQL-side assertions are `std.mem.indexOf(u8, filter, "autosave_") != null`. This is a textual presence check. A future edit could:

```zig
// Bug example: typo in regex group separator, but prefix string still present
pub const BRAIN_USER_KEY_FILTER =
    "key !~ '^(autosave_session_checkpoint_audit_shell/...)' ..."; // missing |
```

Test passes because `"autosave_"` is in the string, but the regex is broken — it only matches the literal concatenation. Brain hygiene silently fails in production.

**Fix:** Replace the textual assertions with a behavioral simulation. Each test case already has `(key, expect_visible)`. For each key, simulate the SQL filter using `std.mem.startsWith` over the prefix list (extracted as a `comptime` array — single source of truth for both Zig predicate and the regex constant). Or write a hand-rolled regex matcher that walks the alternation. Either way, the test must produce the same `true/false` for every key as `isBrainVisibleKey` does.

Cleanest path: pull the prefix list into a `comptime const HIDDEN_PREFIXES = [_][]const u8{...}` array exposed from `memory_root`. `isBrainVisibleKey` iterates it. The SQL constant is generated at comptime by joining with `|`. Test verifies the comptime constant matches the runtime constant by character. Zero possibility of drift — they share the source.

**Severity:** warning, not critical, because the existing unit test plus end-to-end live-PG verification already catch this class of error in practice. But it's the kind of test debt that bites in 6 months.

### WR-02: No PG roundtrip smoke test for /brain/* hygiene

**File:** `src/zaki_state.zig` test slot

**Issue:** The chunk 3A/3C/4A integration test (around line 4257) writes memories to a live PG schema and reads them back through state-manager methods. I extended the unit test for the predicate but did not add the analogous PG roundtrip for `listMemoriesBrainVisible` and the `listMemoriesTimeline` brain-filtered path. A regression in the SQL constant — say someone deletes one prefix from the regex — would slip past the unit test.

**Fix:** Add a smoke test that:
1. Provisions an isolated schema
2. Inserts representative memories: one user-authored (`user_lang`), one continuity (`summary_latest/sess_x`), one audit (`session_checkpoint_123`), one tombstone, one `audit_shell/123`
3. Calls `listMemoriesBrainVisible` and `listMemoriesTimeline`
4. Asserts only the user-authored entry is returned
5. Tears down the schema

~30 lines, follows the existing pattern. Fixes a real coverage gap.

**Severity:** warning. Not shipping without a smoke test for a SQL-mirrored predicate.

---

## Info

### IN-01: SQL regex performance at scale

**File:** `src/zaki_state.zig::BRAIN_USER_KEY_FILTER`

The filter is a Postgres regex `~` operator over the `key` column. At 7K rows it's invisible. At 100K+ rows on a hot endpoint it would be measurable. /brain/* is a low-frequency surface — accept for V1.5.

If brain calls scale to a hot path later (e.g. real-time collab on shared brain views), revisit with a `WHERE key NOT LIKE 'autosave\_%' ESCAPE '\'` cascade so the b-tree index on (user_id, key) can be partially used. But premature today.

### IN-02: Cold-start 465ms latency on first /brain/graph per user per gateway lifetime

**File:** `src/gateway.zig` /brain/graph dispatch

Lazy `getTenantRuntime` triggers full agent runtime init (provider load, MCP servers, prompt assembly). On a freshly-restarted gateway with no warm runtimes, the user's first brain page load takes ~465ms vs ~39ms warm. Acceptable for a low-frequency surface; documented in the commit.

If this becomes painful, the right architectural fix is a lightweight gateway-level vector store accessor that doesn't require full runtime init — but that's a larger refactor. Out of scope for V1.5.1.

### IN-03: docs/frontend-vision-brief.md doesn't mention the hygiene filter

**File:** `docs/frontend-vision-brief.md`

The /brain/graph + /brain/timeline addendums describe the response shape but don't tell the FE agent that some entries are intentionally hidden. A future FE engineer might wonder why their corpus count differs from a `SELECT COUNT(*)` on the memories table. One paragraph noting the filter would prevent confusion.

**Fix:** Add a brief addendum: "The /brain/* surfaces filter agent bookkeeping (continuity summaries, autosaves, checkpoints, audit logs, tombstones, bootstrap prompts). `total_nodes_in_corpus` reflects the filtered count, not the raw row count." 5 minutes.

---

## Obsidian-parity gaps (V1.6+ candidates, not V1.5 blockers)

The FE agent is implementing graph polish against the existing contract. Three backend additions would meaningfully raise the ceiling for visual quality:

### OP-01: GET /brain/memory/{key} — per-node drilldown

When a user clicks a node, Obsidian opens the note. Our equivalent would be a per-memory endpoint returning `{ key, content, metadata, valid_history[] }`. Today the FE has to keep all selected node content in the graph payload (truncated to 200 chars) — fine for hover, insufficient for click-to-read.

Estimated 1h backend, unblocks Obsidian-level node interaction.

### OP-02: ?q=<text> on /brain/graph

Obsidian highlights nodes matching a search query. Our `node_kinds` filter is too coarse. A full-text query parameter routed through `recallMemories` (existing FTS5/likeSearch path) would let the FE highlight match-set without extra round trips.

Estimated 30min backend.

### OP-03: node.importance hint

Currently nodes are sized uniformly in the FE; Obsidian sizes by incoming-link count. We could expose `incoming_edge_count` or `recency_rank` per node so the FE has a cheap signal for visual hierarchy without computing it client-side at 60fps over 500 nodes.

Estimated 30min backend.

---

## Verdict

**Ship with WR-01 + WR-02 fixed.** IN-01/02/03 are accept-as-is. Obsidian-parity gaps queued for V1.6 strategy.

The structure is right: single source of truth, drift-resistant, agent-retrieval untouched, end-to-end verified. The warnings are about hardening the test layer — important for 6-month rot resistance, not for tomorrow's ship.

Estimated time to close warnings: **30 minutes total** (15 for WR-01 comptime refactor, 15 for WR-02 smoke test).

— signed by the backend, V1.5.1 self-review.
