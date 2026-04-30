# Post-Compaction Handoff (2026-05-01)

**Purpose:** survive a compact. Self-contained context for the post-compact me.

## State at compaction

- **Main HEAD:** `9c6f0d0` (V1.5 backend ship-ready + frontend Phase-1 playbook landed)
- **V1.5 status:** SHIP-READY. Target deploy 2026-05-05. Backend done.
- **V1.6 status:** locked plan, not started. Day-1 = per-session brain filter.
- **Tests:** 5724/5734 pass with `-Dengines=all`, 10 skipped, 2 pre-existing unrelated failures (predate V1.5 by 500+ commits)
- **Internals/:** all P-files bumped through current HEAD

## V1.5 ship is locked

5 days of work shipped across 8 commits today + the day-1/2/3/4 work earlier. Everything green at every gate.

**3 real bugs caught + fixed in code review:**
1. UTF-8 codepoint split in summary truncation (day-2 review)
2. Key-collision via upsert ON CONFLICT (day-3 review — added `compose:` prefix enforcement)
3. `std.mem.span` on `[:0]u8` slice in cursor handling (day-5 production-build verify caught it)

**V1.5 substrate fully on disk for V1.6:**
- Bi-temporal `valid_to` schema (always-null today; V1.6 populates)
- `memory_events` audit table accumulating `compose` + `traversal` rows
- Mem0 namespace pattern locked in `event_type` column
- pgvector pairwiseSimilarities primitive
- Three `/brain/*` endpoints (graph, timeline, compose)
- `compose_memory` tool registered (catalog 30→31)
- Agent prompts for todo, compose, brain-page awareness

## V1.6 locked plan (5 must-ships, ~5-6 days)

| Day | What | Files touched |
|---|---|---|
| 1 | **Per-session brain filter** — `?session_filter=<key>` on `/brain/graph` + `/brain/timeline` | `src/zaki_state.zig`, `src/gateway.zig` |
| 2 | **`memory_correct` tool + agent prompt directive** | `src/tools/memory_correct.zig` (NEW), `src/tools/root.zig`, `src/agent/prompt.zig`, `src/zaki_state.zig` |
| 3 | **Source retirement on compose** — `retire_sources: true` flag | `src/tools/compose_memory.zig`, `src/gateway.zig`, `src/zaki_state.zig` |
| 4 | **Daily-diff view** — `/brain/diff?date=<unix>` | `src/gateway.zig`, `src/zaki_state.zig`, `docs/frontend-vision-brief.md` |
| 5 | **Filter-aware reads on non-SQL engines + /brain/compose test coverage expansion** | `src/memory/engines/{markdown,redis,memory_lru,lancedb,lucid}.zig`, `src/gateway.zig` |

### Day-1 detail (per-session brain filter)

**Backend changes:**
- Extend `state_mgr.listMemoriesTimeline` to accept `session_filter: ?[]const []const u8` (already had this in earlier draft — now actually wire it). SQL: `AND session_id = ANY($N::text[])`.
- New helper: `state_mgr.listMemoriesForSessionGraph(allocator, user_id, session_keys, max_nodes)` — like `listMemories` but with session_id filter for graph builder.
- `handleBrainGraph` parses `?session_filter=<csv>` query param, threads through.
- `handleBrainTimeline` parses `?session_filter=<csv>` query param, threads through (was V1.6-queued from V1.5 day-2).
- Update frontend brief addendum for both endpoints noting the new param.

### Day-2 detail (`memory_correct` tool)

**The substrate exists.** This day is just wiring agent → bi-temporal correction.

**New tool `memory_correct`** at `src/tools/memory_correct.zig`:
```
Action: correct
Inputs:
  old_key: string (required, must exist as memory)
  new_content: string (required, the corrected fact)
  reason: string (optional, why correction)
  category: string (optional, defaults to old memory's category)

Behavior:
  1. Verify old_key exists via state_mgr.getMemory
  2. Set valid_to=now() on old memory (use new state_mgr.retireMemory method)
  3. Write new memory with metadata={"corrects":"<old_key>","reason":"...","corrected_at":<unix>}
  4. memory_event row with event_type='correction'
```

**New state method `state_mgr.retireMemory(user_id, key)`:** simple SQL `UPDATE memories SET valid_to=EXTRACT(EPOCH FROM NOW())::bigint WHERE user_id=$1 AND key=$2`.

**Agent prompt directive:** trigger on explicit user cues — "actually," "no," "I changed my mind," "X is wrong, it's actually Y," "I prefer Y not X." Emphasize: only on EXPLICIT corrections, not on every new fact.

### Day-3 detail (source retirement on compose)

`compose_memory` tool gains optional `retire_sources: bool = false` arg. When true, after writing the synthesis:
- For each key in `references[]`, call `state_mgr.retireMemory(user_id, key)` to set valid_to=now().
- Synthesis content metadata gains `retired_sources: ["k1","k2"]`.

`/brain/compose` endpoint same shape — `retire_sources` in request body (default false).

Agent prompt update: "Use retire_sources sparingly — only when the synthesis FULLY REPLACES the sources (not just summarizes them)."

### Day-4 detail (daily-diff view)

**New endpoint:** `GET /api/v1/users/{id}/brain/diff?date=<unix>` returns:
```json
{
  "date": "2026-05-01",
  "memories_added": [<MemoryEntry shape>, ...],
  "memories_corrected": [{"key":"...", "old_content":"...", "new_content":"..."}, ...],
  "memories_synthesized": [<compose memory>, ...],
  "summary": "ZAKI learned 3 new things today and corrected 1 previous understanding."
}
```

**Implementation:** SQL queries on `memory_events` table:
- `WHERE created_at >= $date AND created_at < $date + 1 day` for the day window
- `event_type IN ('upsert', 'compose', 'correction')` to filter
- Cross-reference with `memories` table for content snapshots

The `summary` field can be human-written via simple template ("learned N things, corrected M") — not LLM-generated for V1.6 (cost). V1.7 can add LLM-generated daily summaries.

**Frontend integration:** new `BrainDiffView.tsx` component on the `/brain` page, third tab alongside Graph + Timeline.

### Day-5 detail (gap closures)

**Filter-aware reads on non-SQL engines:**
- `markdown.zig`, `redis.zig`, `memory_lru.zig`, `lancedb.zig`, `lucid.zig` all need to filter `valid_to` on read.
- Current shape: they carry the field via struct passthrough but don't filter.
- For each engine, add the filter in `recall` / `list` / `get` paths.
- Tests: roundtrip an entry with valid_to=past, verify it doesn't surface.

**`/brain/compose` test coverage expansion:**
- Currently only 405 + 400 + prefix enforcement tests.
- Add: full validation chain integration test (success path with valid references, error paths for each validation rule).

## Operating model

**Decisions live in this Claude session with Nova.** Codex CLI + frontend agents are delegates. Anything substantial that lands on `main` for nullalis goes through Nova + this Claude session before merge.

**Frontend is now in flight on Sonnet+GSD** per `docs/v1.5-frontend-phase1-implementation.md`. Phase-1 ships against current zaki-prod design system. Phase-2 (visual migration to new design system) starts when Claude design returns from rate-limit.

**Discipline reminders:**
1. Per-commit P-file updates — rhythm broke once already, don't break again
2. Atomic PRs per item, sprint-granular per Nova's pattern
3. `zig build test` green before every commit
4. Production build = `zig build -Doptimize=ReleaseFast -Dengines=all` — VERIFY THIS for every backend ship (caught the cursor_id_z bug post day-2)
5. Don't change behavior the user is actively testing without flagging
6. Backend stays truthful — frontend handles UX simplification (PR #66 lesson)
7. Father, not godfather — slow and honest > fast and theatrical

## Today's commit ledger (2026-04-30 → 05-01)

```
9c6f0d0 docs(v1.5): frontend Phase-1 implementation playbook (sonnet+GSD-friendly)
cc794f5 docs(v1.5): release notes + frontend brief Phase-1/Phase-2 ship strategy
27b0d5f fix(memory): cursor_id_z slice handling + V1.5 day-3+4 PG smoke test
190d778 feat(agent/prompt): brain-page awareness directive (chunk 4B)
4e16c4a feat(api/brain): traversal-event logging (chunk 4A)
0aa5306 fix(compose_memory,api): enforce compose: prefix
10d0c31 feat(api): /brain/compose endpoint (chunk 3C)
ba3fd72 feat(tools): compose_memory tool (chunk 3B)
8138d3c feat(memory,api): metadata-canonical references (chunk 3A)
2f3b9c5 docs(design): frontend implementation handoff package
d7a9d4c fix(api/brain): UTF-8-safe truncation + deterministic edge ordering
0f82bce feat(api): /brain/timeline endpoint
2fd8b42 feat(api): /brain/graph endpoint
bc23f43 feat(memory/vector): pairwiseSimilarities primitive
fa0c5d6 refactor(memory): bi-temporal hardening
b4dc9a3 feat(memory): bi-temporal valid_to schema
```

## Pending on Nova (operational)

1. **Hand `docs/v1.5-frontend-phase1-implementation.md` to frontend agent (Sonnet+GSD)** — Phase-1 implementation
2. **2026-05-05 ship execution:**
   - Build: `zig build -Doptimize=ReleaseFast -Dengines=all`
   - Bump container tag to V1.5
   - Deploy to DO k8s
   - Smoke-test endpoints
   - Inspect memory_events for traversal rows post-deploy
3. **Sentry DSN finalize** — post-deploy
4. **D-phase staging tests** — post-deploy
5. **Channel awareness** deferred to V1.7 (user not blocked today)

## Reference docs to read first after compact

1. `docs/v1.5-release-notes.md` — what V1.5 ships + V1.6 deferred
2. `docs/v1.5-frontend-phase1-implementation.md` — frontend playbook (Phase-1 in flight on sonnet+GSD)
3. `docs/frontend-vision-brief.md` — endpoint contracts + TS types + curl
4. `docs/graph-memory-research.md` — repo verdicts (don't re-research)
5. This doc

## Critical context for post-compact me

1. **V1.5 is ship-ready and locked.** No more code changes to V1.5 unless an emergency surfaces during deploy.

2. **V1.6 must-ships are 5 items in priority order.** Do NOT add a full ADD/UPDATE/DELETE classifier — that was over-engineering from yesterday's draft. `memory_correct` is the cheap explicit-cue primitive that gives 80% of the value.

3. **Channel awareness is V1.7, not V1.6** per Nova's call. Don't re-add to V1.6.

4. **memory_events table accumulates without a retention policy on purpose.** Users want to see year-old brain history. Retention is V1.7+ if growth becomes a problem.

5. **Frontend Phase-1 in flight on Sonnet+GSD.** Backend day-1 (per-session brain filter) UNBLOCKS the frontend's "view this session's brain" button. Land it first.

6. **memory_correct + retire_sources both leverage existing bi-temporal substrate.** No schema changes. No new tables. Pure code on top of V1.5 foundation.

7. **Production build flag matters.** `zig build -Doptimize=ReleaseFast -Dengines=all` is the deploy command. Default builds skip postgres-gated paths. Always verify the production build before claiming green.

8. **The cursor_id_z bug from V1.5 day-2 was a slice-vs-pointer mistake.** Watch for similar `std.mem.span()` misuse on slice types in V1.6 work — Zig 0.15.2 only accepts `[*:0]` pointers.

## V1.6 day-1 starting point (resume here)

**Goal:** Add `?session_filter=<key1,key2,...>` query param to `/brain/graph` and `/brain/timeline`. Powers the frontend's per-session brain button.

**Files:**
- `src/zaki_state.zig` — extend `listMemoriesTimeline` with session_filter param. New helper for graph: `listMemoriesForGraph(user_id, session_keys, since, max_nodes, node_kinds)`.
- `src/gateway.zig` — `handleBrainGraph` + `handleBrainTimeline` parse the new query param.
- `docs/frontend-vision-brief.md` — addendum updates noting session_filter is now live.
- Tests: integration test against live PG verifying session_filter narrows results correctly.

**Estimated time:** ~3-4 hours.

---

*Written 2026-05-01 pre-compact. Update inline as items close.*
