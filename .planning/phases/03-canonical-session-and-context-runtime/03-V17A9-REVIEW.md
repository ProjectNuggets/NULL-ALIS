---
phase: 03-canonical-session-and-context-runtime
sprint: V1.7a-9 (communities — 4 atomic commits)
reviewed: 2026-05-03T23:30:00Z
depth: deep
commits_reviewed:
  - 21c6c37  # 9a — schema + 5 state fns
  - 9f017e7  # 9b — LPA pure-data
  - e10b089  # 9c — pipeline + injectable namer
  - 4a8e52e  # 9d — endpoint surface
files_reviewed_list:
  - src/memory/root.zig
  - src/zaki_state.zig
  - src/agent.zig
  - src/agent/communities.zig
  - src/agent/community_pipeline.zig
  - src/gateway.zig
findings:
  blocker: 0
  warn: 7
  info: 8
  total: 15
status: issues_found
---

# V1.7a-9 Communities — Independent Code Review

Honest second-opinion pass over the 4 atomic commits. SQL/scoping/memory/race/algorithm focus. No blockers found — the sprint is broadly sound and PG-test-covered. Several WARN-level latent footguns and design-correctness items worth tracking before V1.7b.

## Summary

Storage primitives are clean and follow project conventions (`MEMORIES_VALIDITY_FILTER`, cross-tenant `WHERE user_id = $1`, idempotent batch writes). The LPA core is deterministic by construction (reverse-sorted async + lowest-string tie-break + snapshot-free in-place updates). The pipeline correctly defers PG mutations to the end and isolates LLM calls behind an injectable callback. The endpoint surface is purely additive on `/brain/graph` and degrades gracefully when state is unavailable.

The most material concerns are: (1) a **silent truncation** in `computeStableCommunityId` if top_k ever exceeds 128, (2) the LLM-name **cache hash is functionally redundant** with the community_id (both derived from the same FNV input), (3) **no concurrency guard** on `/brain/communities/recompute` (concurrent calls double-do work and race on writes), and (4) `RecomputeConfig.now_unix=0` default is a **degenerate-importance footgun** for any direct caller that forgets to set it.

---

## WARN — 7 issues

### WR-01: `computeStableCommunityId` silently truncates at 128 keys

**File:** `src/agent/community_pipeline.zig:344-356`
**Issue:** Stack buffer `var sorted_buf: [128][]const u8 = undefined` and `const n = @min(top_k_keys.len, sorted_buf.len)`. If a future caller bumps `RecomputeConfig.top_k_members` above 128, the hash silently drops keys past 128 — collisions become much more likely AND results become input-order-sensitive (which 128 of N you happen to feed in first). Today `top_k_members=5` so it never trips, but there's no compile-time guard or runtime assertion.
**Fix:** Either (a) `std.debug.assert(top_k_keys.len <= sorted_buf.len)` at the top, or (b) heap-allocate when `top_k_keys.len > 128`, or (c) make the buffer size a `comptime` parameter tied to `RecomputeConfig.top_k_members`. (a) is cheapest and converts a silent corruption into a panic in dev/test.

### WR-02: `member_set_hash` is functionally redundant with `community_id`

**File:** `src/agent/community_pipeline.zig:376-379` (`computeMemberSetHash`)
**Issue:** Both the stable id AND the cache hash are derived from the **same FNV-1a 32-bit hash of the same sorted top-K keys**. `computeMemberSetHash` literally does `computeStableCommunityId(...)` then hex-formats it. So:
  - Cache lookup is by `stable_id` → row PK includes the same id
  - If row exists, its `member_set_hash` MUST match current top-K hash (because both = same id)
  - The `!std.mem.eql(u8, c.member_set_hash, set_hash)` check at `community_pipeline.zig:312-315` is always false when the row exists
  
The cache is functionally `cached != null`, not "membership changed". When membership actually changes, `stable_id` changes → no row found → naming runs. The hash compare adds cost without semantic value. Worse: there's no protection against FNV collisions across different member sets — both id AND hash collide together.
**Fix:** Either (a) drop the hash comparison and use `cached != null` (simpler, equivalent behavior, makes the intent honest), OR (b) make `member_set_hash` a SEPARATE hash function (e.g. SHA-256 or Wyhash with a different seed) so it can actually detect collisions and trigger re-naming on hash mismatch even when ids collide. (a) is the V1 fix; (b) is the long-term answer if 32-bit FNV collisions become a real concern at scale.

### WR-03: `/brain/communities/recompute` has no concurrency guard

**File:** `src/gateway.zig:11211-11250` (`handleBrainCommunitiesRecompute`)
**Issue:** Endpoint is synchronous but stateless on the server side. Two concurrent POSTs for the same `user_id`:
  1. Both pull the same edges
  2. Both run LPA → same labels (deterministic, OK)
  3. Both call `setMemoryCommunityIds` and `setCommunityName` — last writer wins per row, but interleaving can produce a transient state where some memories have id from run-1 and others from run-2. If membership churned mid-pipeline (ingest also writing), the two recomputes can disagree on top-K → different stable_ids → some members get id_A, others get id_B → no community is internally coherent until the next recompute.
  4. Wasted LLM cost (each runs its own naming loop).
**Fix:** Per-user mutex on the GatewayState (a `std.StringHashMap(std.Thread.Mutex)` keyed by `user_id`, lazy-init), grabbed for the duration of the pipeline call. Or PG advisory lock: `SELECT pg_try_advisory_lock(hashtext('communities:' || user_id))` at the top of `recomputeCommunitiesForUser`, return early if not acquired with a "recompute_in_progress" stat. Advisory lock is more robust because it protects against multi-process recompute (e.g. nightly scheduler + manual trigger).

### WR-04: `RecomputeConfig.now_unix = 0` default produces degenerate importance scores

**File:** `src/agent/community_pipeline.zig:187` and `src/agent/communities.zig:153`
**Issue:** Both `RecomputeConfig.now_unix` and `LpaConfig.now_unix` default to 0. The LPA module documents this and short-circuits recency_decay to 1.0 when `now_unix == 0` (`communities.zig:281` — `if (config.now_unix == 0) return edge.weight * attr_mult`), which is fine. But `selectTopKByImportance` forwards `config.now_unix` (which can be 0) into `importance.computeImportance(created_at, now=0, deg)` — and `recencyDecay(created_at_in_2026, now=0)` clamps the "future timestamp" path to 1.0 for ALL keys (per `importance.zig:86`, "Future timestamps clamp to 1.0"). Result: importance score collapses to `0.5 + 0.5 * edgeCountNormalized(deg)` — recency contributes nothing, top-K becomes pure-degree. In a small community where many keys share degree, the lowest-string tie-break wins → top-K becomes alphabetical → stable_id is determined by `min(K alphabetical keys)`, which may not actually represent the community's "important" members.

Currently both call sites (gateway + tests) pass `std.time.timestamp()` so production is correct. The footgun is that any future direct caller (e.g. a nightly scheduler in V1.7b) that forgets to set `now_unix` ships a silently-degenerate top-K.
**Fix:** Either (a) make `now_unix` non-defaulting in `RecomputeConfig` so callers must set it explicitly, or (b) inside `recomputeCommunitiesForUser` substitute `if (config.now_unix == 0) std.time.timestamp() else config.now_unix` and document that 0 means "use wall clock". (a) is safer; it surfaces the contract.

### WR-05: `recomputeCommunitiesForUser` does NOT apply BRAIN_USER_KEY_FILTER

**File:** `src/agent/community_pipeline.zig:218` (`listMemoryEdgesForCommunityCompute`)
**Issue:** The state fn pulls every live edge between live memories — including system/hidden keys (`task.*`, `corpus.*`, etc. matched by `BRAIN_HIDDEN_PREFIXES`). Those memories will get a `community_id` assigned and persisted on `memories.community_id`. They won't show on `/brain/graph` (which applies the brain filter), but they DO consume FNV id space, can become "leader" keys (lowest-string is `cache.x` < `m_user_thing`), and could anchor a community whose visible members all map to the same id. The pipeline docstring claims "Brain-hygiene NOT applied here — it's applied at the consumer level" (zaki_state.zig comment for the state fn), which is a deliberate choice but worth confirming. If a hidden-key cluster ends up as the dominant component, leaders propagate to user-visible nodes via cross-edges and the community structure becomes user-confusing.
**Fix:** Either (a) add `BRAIN_USER_KEY_FILTER` to the EXISTS subqueries in `listMemoryEdgesForCommunityCompute` so the pipeline only sees user-facing edges, OR (b) document explicitly that hidden-key leaders are intentional and add a sanity test that confirms a hidden-key cluster does NOT capture user-visible memories. Recommend (a) — it's one extra `AND` per subquery and prevents a class of silent UX bugs.

### WR-06: PG NULL vs empty-string conflation in `listCommunities` name decoding

**File:** `src/zaki_state.zig:511-522` (in `listCommunities`)
**Issue:** `dupeResultValue` returns `""` for a SQL NULL (zaki_state.zig:6170). `listCommunities` then maps `name_str.len == 0` → null Option (lines 512, 518). This conflates "PG NULL" with "empty string" — a community whose name was set to literal `""` becomes indistinguishable from an unnamed cluster. `setCommunityName` doesn't reject empty-string names. Today nothing writes empty strings, but `setCommunityName(user, id, "", "llm", ...)` from a misbehaving LLM (returns blank) would silently disappear from the FE legend.
**Fix:** Either (a) use `dupeNullableResultValue` (already exists at zaki_state.zig:6181) for the name + name_source columns and check the `?[]u8` directly, OR (b) add a `if (name.len == 0) return error.InvalidCommunityName` guard in `setCommunityName`. (a) is the cleaner fix and matches the intent of the column being nullable. Same issue applies to `getCommunityName` decoding `name_source` field (zaki_state.zig:444 area).

### WR-07: `/brain/graph` community lookup leaks request allocator on partial failure

**File:** `src/gateway.zig:11710-11729`
**Issue:** Two issues nested here:
  1. When `getMemoryCommunityIds` succeeds and returns owned-keys map, the `defer` frees keys with `allocator` (good). When it errors, the `catch std.StringHashMapUnmanaged(i32){}` returns a fresh empty map and the defer iterates 0 keys (also good). BUT — if the inner state fn errors **after** populating some keys but before returning (e.g. after `try out.put(...)` then a later `parseInt` fails — though current code uses `catch continue` for parseInt so this can't happen today), those keys would leak. Today this is bounded by the state fn's own `errdefer` which frees all keys before bubbling. Verify this stays true if anyone touches `getMemoryCommunityIds` later.
  2. `community_summaries: []memory_mod.CommunitySummary = &.{}` initialized to empty literal, then conditionally re-assigned. The `defer memory_mod.freeCommunitySummaries(allocator, community_summaries)` fires on whatever it ends up pointing to. `freeCommunitySummaries` on an empty slice (`&.{}`) calls `allocator.free(empty_slice)` — Zig's allocator generally tolerates freeing zero-length slices, but it depends on the allocator implementation. Worth a defensive `if (community_summaries.len > 0) memory_mod.freeCommunitySummaries(...)`.
**Fix:** (1) Add a code-comment in `getMemoryCommunityIds` warning that any added decode step must preserve the `errdefer` over `out`. (2) Either `defer if (community_summaries.len > 0) memory_mod.freeCommunitySummaries(allocator, community_summaries);` or guard inside `freeCommunitySummaries` itself with `if (summaries.len == 0) return;`.

---

## INFO — 8 items

### IN-01: `assignments_buf` batch is queued but only flushed at end — ordering risk on partial failure
**File:** `src/agent/community_pipeline.zig:284-372`
The pipeline queues all assignments AND writes names for each community inside the loop, then flushes assignments at the very end. If `setCommunityName` errors mid-loop, names are partially written but `setMemoryCommunityIds` never runs → memories keep their PRE-recompute community_id (or NULL). Names point to ids no memory has. The docstring says "next recompute heals" — true, but transient `/brain/communities` shows ghost rows with member_count=0. The LEFT JOIN in `listCommunities` already filters those out via the live count subquery (good). Just confirming the design.

### IN-02: `getOrPut` in LPA init may invalidate `value_ptr` from prior iteration on rehash
**File:** `src/agent/communities.zig:174-180`
```
const src_gop = try labels.getOrPut(allocator, e.source_key);
if (!src_gop.found_existing) src_gop.value_ptr.* = e.source_key;
const tgt_gop = try labels.getOrPut(allocator, e.target_key);
if (!tgt_gop.found_existing) tgt_gop.value_ptr.* = e.target_key;
```
`tgt_gop` GetOrPut can rehash and invalidate `src_gop.value_ptr` — but `src_gop.value_ptr.*` is **already written** before `tgt_gop` runs. So safe today. Adding an unrelated `getOrPut` between them in the future would break this; worth a code comment.

### IN-03: LPA inner loop walks ALL edges per node — O(N·E) per iteration
**File:** `src/agent/communities.zig:216-235`
The neighbor lookup per node walks the full edge slice and does two `eql` checks per edge. For V1 corpora (≤500 nodes, ≤2000 edges, ≤10 iter) this is ~10M ops, sub-100ms. At 5K nodes / 50K edges, it becomes ~2.5B ops per recompute — multi-second territory. Out of v1 perf scope per the review charter, but flagging because the comment claims "sub-millisecond" which is only true at the smallest end.
**Fix (later):** Pre-build adjacency index once before the iteration loop: `StringHashMap(ArrayList(struct{neighbor_key, edge_idx}))`. Trades O(E) memory for O(degree) per node-update.

### IN-04: `attributionMultiplier` accepts unknown attributions silently with 0.8
**File:** `src/agent/communities.zig:293-298`
Empty string and any unknown attribution (`"future_source"`, mis-tagged data) get 0.8x. This is reasonable defensive default. But if a new attribution type is added in 9b/10/etc and this fn isn't updated, those edges silently lose 20% vote weight. Add a `log.debug` scoped warning for unknown attribution (sample 1-in-N to avoid log spam) so it's visible at code-search time.

### IN-05: `selectTopKByImportance` ignores `recency_half_life_seconds` parameter
**File:** `src/agent/community_pipeline.zig:306` (`_: f64`)
The parameter is intentionally ignored ("importance.computeImportance has its own constant; reserved for future tuning"). Fine, but the docstring at the call site implies the half-life is honored. Either remove the unused param or thread it into a `computeImportanceCustom` variant. The dead parameter is misleading.

### IN-06: 32-bit FNV-1a id collision math
**File:** `src/agent/community_pipeline.zig:343-368`
After masking high bit, id space is 2^31 = 2.1B. Birthday-paradox 50% collision around √(2·2^31) ≈ 65K communities globally. Per-user it's vanishingly unlikely (typical user has <100 communities). But the index `idx_memories_community` is per-(user_id, community_id), and `memory_communities` PK is also (user_id, community_id), so collisions are bounded to within-user — and within-user 65K communities is impossible. Acceptable. Could note this in the docstring so future readers don't worry.

### IN-07: Community endpoint unit tests cover only the 405/400 fast-path
**File:** `src/gateway.zig:25580-25603`
The 4 new gateway tests construct `var dummy_state: GatewayState = undefined` and exercise only method/user_id rejection paths. No test exercises the happy path of `handleBrainCommunities` returning a real summaries body, or `handleBrainCommunitiesRecompute` calling the pipeline. The commit message acknowledges this ("Full /brain/graph integration with community fields surfaces requires GatewayState construction with no existing scaffolding"). Same pattern as V1.7a-8b. End-to-end coverage IS provided via the V1.7a-9c PG smoke test of the pipeline. Fine for V1; if a gateway test scaffold lands in V1.7b, retro-add happy-path coverage.

### IN-08: `community_summaries: []memory_mod.CommunitySummary = &.{}` defer-pattern is non-obvious
**File:** `src/gateway.zig:11720-11721`
The pattern of "init to empty, conditionally reassign, defer free always" works because `freeCommunitySummaries` on `&.{}` is a no-op-ish (frees 0-length slice). The reassignment moves ownership without leaking (the original `&.{}` literal isn't an allocation). Worth a one-line code comment so the pattern is recognized when copy-pasted: `// owned-or-empty: defer always frees; empty literal is a no-op free`.

---

## Cross-Cutting Observations

- **SQL injection**: All UNNEST + ANY array-text escapes correctly handle `"` and `\` (the only PG array meta-chars inside double-quoted elements). NULL bytes in keys would truncate at the `dupeZ` boundary — not a known issue since memory keys come from controlled producers, but worth a project-wide audit.
- **Cross-tenant scoping**: Every PG query in 9a + 9c + 9d correctly includes `WHERE user_id = $1`. Test #6 in 9a explicitly verifies user 99 sees nothing of user 2's data. Good.
- **Bi-temporal hygiene**: `listMemoryEdgesForCommunityCompute` correctly applies `is_latest` on edges + `MEMORIES_VALIDITY_FILTER` on both endpoints. `listCommunities` live-count subquery applies `MEMORIES_VALIDITY_FILTER`. 
- **Memory ownership**: All `errdefer` paths in 9a state fns are paired correctly. The `initialized` counter pattern in `listMemoryEdgesForCommunityCompute` and `listCommunities` correctly partial-frees on mid-loop failure.
- **Determinism**: 9b's reverse-sorted async + lowest-string tie-break gives byte-stable output. 9c's stable-id FNV is also byte-stable. 100-run determinism test in 9b is the right shape.
- **Test coverage vs commit-message contract bullets**: 9a covers 6/6, 9b covers 8/8, 9c covers 5/5 PG smoke + 6/6 unit, 9d covers 4 endpoint shape + relies on 9a/9c for happy path. Self-reported pass count matches `5986/5996` baseline. Reasonable v1 coverage.

---

## Recommended Tier-1 Fixes (before V1.7b)

1. **WR-03** — concurrency guard on recompute (PG advisory lock is the lowest-friction fix; one additional state fn).
2. **WR-04** — make `now_unix` non-defaulting OR auto-substitute wall clock when 0.
3. **WR-01** — assert top_k ≤ 128 OR heap-allocate. Five-line change, prevents future silent corruption.

## Tier-2 (track for V1.7b cleanup)

4. **WR-02** — drop redundant cache hash compare or split it into a real second hash.
5. **WR-05** — apply `BRAIN_USER_KEY_FILTER` at the edge fetch.
6. **WR-06** — `dupeNullableResultValue` for community name decoding.
7. **WR-07** — defensive guard in `freeCommunitySummaries` for empty slice.

---

_Reviewed: 2026-05-03_
_Reviewer: Claude (gsd-code-reviewer, deep)_
