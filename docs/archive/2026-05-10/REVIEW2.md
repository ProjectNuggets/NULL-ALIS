# Integration Review — commit b711142

**Reviewed:** 2026-05-02
**Depth:** deep (cross-surface)
**Surfaces:** (a) V1.6 cmt6 W1/W2/I3, (b) V1.7 Tier-3 CASE-guards + pending_conflicts hide, (c) Nullclaw cherry-pick + reviewer fixes
**Status:** PASS WITH ONE LATENT BUG — surfaces (a) × (b) interact at the closed-out-row + upsert seam to produce a silent "zombie row" + a dead-promote-to-core path. Not exploited by current call sites; pin before V1.6 commit 8 (soft-delete) lands.

---

## Findings by Severity

### WARNING — W-INT-01: Zombie row + dead-core-promotion at close-out × upsert seam (surfaces a × b)

**Files:**
- `src/zaki_state.zig:2426-2451` (upsertMemory ON CONFLICT CASE-guard)
- `src/zaki_state.zig:2161-2185` (upsertMemoryWithMetadata ON CONFLICT CASE-guard)
- `src/zaki_state.zig:2568-2582` (promoteMemoryToCore — no validity filter)
- `src/zaki_state.zig:3164-3197` (setMemoryInvalidation — only writer of valid_to/is_latest/invalid_at/expired_at)

**Scenario:** A row is closed out by `setMemoryInvalidation` (sets `valid_to=ts`, `invalid_at=ts`, `expired_at=ts`, `is_latest=false`; leaves `memory_type` untouched). A subsequent `upsertMemory` for the same `(user_id, key)` from a different session triggers the ON CONFLICT path. The new CASE-guards correctly preserve `memory_type='core'` for already-promoted rows — but a closed-out **non-core** row (the common case for extraction-derived `episodic` keys that just got contradicted) goes down the EXCLUDED branch:

- `content`, `content_hash`, `lemmatized` overwrite to fresh values (intent: a "reincarnation")
- `memory_type` resets from EXCLUDED (typically still episodic)
- `session_id` becomes the new session
- `valid_to`/`invalid_at`/`expired_at`/`is_latest` are NOT in the SET clause — they keep the old close-out timestamps
- `seen_in_session_count` increments because session diverged (line ~2453)

**Result 1 (zombie):** After the upsert, the row carries new content but `valid_to <= NOW()`. `MEMORIES_VALIDITY_FILTER` (line 52) hides it from every retrieval query — `getMemory`, `findMemoryByContentHash`, `recallMemories`, `listMemories`, `findRelatedExtractedMemories`. The agent's write claims success; the data is unreachable. The user re-states the fact, gets a fresh write, still hidden. Until something explicitly resets `valid_to=NULL`, the key is permanently dead.

**Result 2 (dead-promote):** If the closed-out row's `seen_in_session_count` reaches ≥2 after the upsert, line 2540 calls `promoteMemoryToCore`. That UPDATE has `WHERE user_id=$1 AND key=$2 AND memory_type != 'core'` — **no validity filter** (line 2570-2571). The closed-out row gets `memory_type='core'`, `session_id=NULL`, `confidence_score=0.9`, but its `valid_to` is still in the past. Now the new CASE-guard makes it **immortal as core** for all future upserts — and still invisible to all retrieval. Worse: `pending_conflicts` markers will never fire again for this key (line 2549 suppresses on `returned_type == 'core'`). The user has lost a memory key forever with no audit trail surfaced.

**Why this isn't biting today:** Today's call graph has ONE writer of the close-out columns (`edge_resolution.zig:245` → `setMemoryInvalidation`), and that writer is invoked from the V1.6 cmt6 contradiction-judge path which always happens BEFORE a fresh upsertMemory rewrite for the same key (the judge close-out runs in extraction_persist as part of the SAME extraction batch that writes the new fact under a NEW key). The closed-out key + same-key re-upsert sequence requires a re-extraction in a later session that produces the SAME atomic fact key — which the V1.6 5b.3 dedup pre-filter (`findMemoryByContentHash`) is designed to short-circuit, but ONLY if the content_hash matches. Re-stated facts with rephrased content escape dedup and hit the upsert path. So the bug fires when: (i) Pass C extracts a contradicting fact, (ii) judge closes the old row, (iii) a future session re-extracts a similar-but-not-identical fact that lands under the SAME key. Probability rises with `findRelatedExtractedMemories`-driven keys that derive from `subject` and shared key namespaces.

**Fix (pick one):**
1. Add `valid_to IS NULL OR valid_to > EXTRACT(EPOCH FROM NOW())::bigint` to the ON CONFLICT WHERE clause so closed-out rows are NOT updated by upsert (the INSERT branch fires instead because the row "doesn't logically exist"). But ON CONFLICT can't have a WHERE that gates the UPDATE — only `ON CONFLICT ... DO UPDATE ... WHERE` (postgres 9.5+). Pattern:
   ```sql
   ON CONFLICT (user_id, key) DO UPDATE SET ...
   WHERE {schema}.memories.valid_to IS NULL OR {schema}.memories.valid_to > EXTRACT(EPOCH FROM NOW())::bigint
   ```
   This makes the upsert a no-op for closed-out rows. The caller sees zero affected rows → the new fact is lost silently. Pair with a returning-zero-rows check that falls through to a fresh INSERT under a different key, or that resurrects the row.
2. Better: add `valid_to`, `invalid_at`, `expired_at`, `is_latest` to the SET clause with reset semantics — `valid_to = CASE WHEN {schema}.memories.memory_type = 'core' THEN {schema}.memories.valid_to ELSE NULL END`, mirroring the existing CASE-guard pattern. A non-core upsert resurrects the row; a core row stays as-is. Add the same to `is_latest = TRUE` (in the non-core branch). This makes the upsert "I am writing this key NOW, supersede any prior close-out" semantics, which matches the agent's mental model.
3. Add `WHERE memory_type != 'core' AND (valid_to IS NULL OR valid_to > NOW()::epoch)` to `promoteMemoryToCore` (line 2571) so closed-out rows can never be promoted. Cheap, catches the worst arm (irreversible immortal-zombie).

**Recommendation:** ship fix #2 (resurrect-on-upsert) plus #3 (defensive guard on promote). Add a regression test: close out a row → upsert same key from new session → assert `getMemory` returns the new content, `valid_to` is NULL, `is_latest` is TRUE.

---

### INFO — I-INT-02: JSONB partial-index predicate may not be picked by planner (surface a)

**File:** `src/zaki_state.zig:1040` (index DDL), `src/zaki_state.zig:3119-3124` (query)

The new index `idx_memories_metadata_subject ON {schema}.memories(user_id, (metadata->>'subject')) WHERE metadata ? 'subject'` is correctly typed (`metadata` is `JSONB` per line 953). However, the `findRelatedExtractedMemories` query uses `WHERE ... AND metadata->>'subject' = $2 AND ...` without `AND metadata ? 'subject'`. PostgreSQL's planner needs the index's WHERE predicate to be **syntactically** implied by the query's WHERE for partial-index match — semantic implication (`->>` returning non-NULL implies key exists) is not always recognized.

**Behavior in practice:** PG 12+ has improved at recognizing simple implications, but the safe and portable fix is to add `metadata ? 'subject'` to the query WHERE. Without it, the planner may fall back to the typed `idx_memories_subject` index (which is on the `subject` column, currently unpopulated by `upsertMemoryWithMetadata` per the doc-comment at line 3104) or seq-scan.

**Fix:** add the predicate to the query at line 3120-3124:
```sql
WHERE user_id = $1
  AND metadata ? 'subject'
  AND metadata->>'subject' = $2
  AND metadata->>'attribution' = 'extraction_classifier'
  AND <validity filter>
```

EXPLAIN on a populated test schema would confirm. Not blocking — the seq-scan is bounded by `user_id` filter and `LIMIT $3`, so latency is small at current scale.

---

### PASS notes (no findings) — surface interactions verified

**3. BRAIN_HIDDEN_EXACT_KEYS comptime SQL derivation (surface b):**
`src/memory/root.zig:558-567` adds `"pending_conflicts"`. `src/zaki_state.zig:65-89` defines `BRAIN_USER_KEY_FILTER` via `comptime blk: { ... for (memory_root.BRAIN_HIDDEN_EXACT_KEYS, 0..) |exact, i| { ... s = s ++ "'" ++ exact ++ "'"; } ... }`. The new entry is picked up automatically; the emitted SQL contains `key NOT IN ('context_anchor_current', 'timeline_index/current', 'last_hygiene_at', 'pending_conflicts')`. The /brain SQL surfaces at lines 2826 + 2970 both reference this constant. Verified.

**5. sanitizeFactForPrompt × audit-trail (surface a):**
`src/agent/edge_resolution.zig:279-298` — sanitizer runs only on the COPY interpolated into the LLM prompt (line 325-327, 337-339, 347-349), with `try buf.appendSlice(allocator, capped)` followed by `defer allocator.free(safe)`. The DB-side `MemoryEntry.content` is read-only here. Audit trail intact. Confirmed by reading the function: `sanitizeFactForPrompt` allocates a fresh slice and the original `m.content` is never mutated.

**6. last_executed_tool reset × turn entry (surface c):**
`src/agent/root.zig:2949` resets in `runSingleTurn` (enclosing function `turnOutcome` at line 2491). `turnOutcome` is the per-user-message turn driver — invoked once per inbound message. Sub-agent delegation in `src/tools/delegate.zig` spawns a fresh `Agent` instance with its own `last_executed_tool: []const u8 = ""` default (line 421 in agent/root.zig). No shared state across delegation. The reset is correct.

**7. Tool count assertions (surface c):**
The new tool registrations at `src/tools/root.zig:1000-1010` add exactly 3 tools (`calculator`, `file_read_hashed`, `file_edit_hashed`) via `try list.append(allocator, ...)`. Test counts updated 31→34 (excludes browser/http_request/web_fetch/web_search) and 35→38 (includes them). Math checks: 31+3=34, 35+3=38. The third assertion at line 2289 also lifts to 34 with the same delta. Verified.

**8. Teams + Nostr build flags (surface c):**
`build.zig:51-52` defines `enable_channel_teams: bool = false` and `enable_channel_nostr: bool = false` as ChannelSelection fields. `enableAll()` at line 72-73 sets both true ONLY when `-Dchannels=all` is passed (or `-Dchannels=teams`/`-Dchannels=nostr` explicitly). `-Dengines=all` is a separate option family (line 313-318) and does NOT touch channel flags. Production build per `docs/post-compact-handoff-2026-05-02.md` (`zig build -Dengines=all`) produces `enable_channel_teams=false`, `enable_channel_nostr=false`. `channel_catalog.isBuildEnabled(.teams)` returns `false`, so `isConfigured` returns `false` for any teams account, so `channel_manager.startChannels` never instantiates `TeamsChannel`. The `pub const teams = @import("teams.zig")` at `src/channels/root.zig:149-150` is **unconditional**, but Zig's lazy analysis means the module's top-level `const` declarations compile (they only `@import("std")`) while `TeamsChannel.acquireToken` etc. are lazy and never analyzed in production unless referenced. `grep -rn "TeamsChannel\|NostrChannel"` outside of the channel files themselves and `channels/root.zig` returns ZERO consumers. Production-build behavior: code is parsed + imported, no runtime instantiation, no runtime cost. Acceptable for the documented "WIP behind flag" status.

**9. Calculator + file_read_hashed + file_edit_hashed sandbox (surface c):**
- `src/tools/calculator.zig` — pure compute; no `std.fs`, no `std.process.Child`, no FFI. Inputs are JSON numbers, outputs are formatted strings. No filesystem or network surface. Safe.
- `src/tools/file_read_hashed.zig:6-7` imports `path_security.{isPathSafe, isResolvedPathAllowed}`; line 76 enforces `if (!isResolvedPathAllowed(allocator, resolved, ws_resolved orelse "", self.allowed_paths)) return ToolResult.fail(...)` BEFORE `std.fs.openFileAbsolute(resolved, .{})` at line 79. Same `workspace_dir` + `allowed_paths` plumbing as canonical `file_read.zig`. Safe.
- `src/tools/file_edit_hashed.zig:6-7` same imports; line 131 enforces `isResolvedPathAllowed` BEFORE `std.fs.openFileAbsolute(resolved, .{})` at line 134, AND before `std.fs.createFileAbsolute(resolved, .{ .truncate = true })` at line 225 (the resolved path is the same one already validated above — flow control guarantees it). Same sandbox as canonical `file_edit.zig`. Safe.

No tool-sandbox bypass. The only fs-touching call sites in the new tools all gate through `path_security`.

---

## Summary

Three of the four high-risk integration seams are clean. The one finding (W-INT-01) is a real latent bug at the V1.6 cmt6 close-out × V1.7 CASE-guard upsert seam — the bi-temporal close-out columns are write-only today (no retrieval reads `is_latest`; only `valid_to` filters), and the new CASE-guards correctly preserve core but do NOT clear close-out columns on the resurrect path. Combined with the unfiltered `promoteMemoryToCore`, an extraction-derived key that gets re-stated across sessions can become an immortal hidden core row. Fix is small (CASE-clear `valid_to`/`is_latest` on non-core branch + add validity filter to promote). Ship before V1.6 commit 8 lands soft-delete + the `is_latest` UI consumers, which would amplify the symptom from "silent" to "user-visible-but-wrong."

The Nullclaw cherry-pick (surface c) integrates cleanly: tool counts mathematically check out, sandbox plumbing is consistent with canonical tools, channel flag-gating is correct under the documented production build invocation, and the dangling-slice + dupe-then-free fixes are both correctly placed.

---

_Reviewed: 2026-05-02_
_Reviewer: Claude (gsd integration reviewer)_
_Depth: deep — cross-surface_

## Side-Effect Audit (Surfaces A + B)

**Reviewed:** 2026-05-02 (post-b711142, post-053fc3c)
**Depth:** deep — side-effect pass beyond stated scope of parallel agents
**Status:** ONE WARNING (binary-detect false positive on 2-byte signatures), TWO INFO, FIVE PASS-NOTE

---

### WARNING — SE-WIP-01: `MZ` 2-byte signature triggers false-positive binary detection (surface b)

**File:** `src/tools/file_read.zig:24` (signature table), `src/tools/file_read_hashed.zig:103-112` (consumer)

**Issue:** `BINARY_SIGNATURES` includes `{ .magic = "MZ", .type_name = "Windows executable" }`. `isBinaryContent` checks `std.mem.startsWith(u8, data, sig.magic)` — for `MZ` this matches any text file whose first two bytes are `0x4D 0x5A`. Plausible false positives: a markdown file beginning with "MZ Industries quarterly report", a test fixture starting with "MZ" as a label, ASCII art with `MZ` as the first glyph. Consumer (`file_read_hashed.zig:111`) returns `"[Binary file detected: Windows executable, size: N bytes...]"` and discards content — agent never sees the actual lines, cannot edit via `file_edit_hashed`. Silent data hiding.

**Why MZ is the only worry:** all other signatures in the table are ≥3 bytes (`%PDF`, `Rar!`, `GIF87a`, `\x89PNG`, `PK\x03\x04`, etc.) or contain non-ASCII bytes (`\xFF\xD8\xFF`, `\x7FELF`, `\x89PNG`, `7z\xBC\xAF\x27\x1C`). Only `MZ` is 2 ASCII bytes that can plausibly start a text file.

**Fix (pick one):**
1. Drop `MZ` from the table — Windows executables in a Zig agent's workspace are rare and the null-byte fallback (line 60-62: any `0x00` in first 8KB → binary) catches real PE files anyway (every PE has nulls in the DOS header padding).
2. Strengthen the check: require `MZ` PLUS PE-typical bytes (e.g., `data.len >= 0x40 and data[0x3C] != 0x00 or data[0x3D] != 0x00 or data[0x3E] != 0x00 or data[0x3F] != 0x00` — the e_lfanew offset). Verbose; option 1 is cleaner.

Recommendation: option 1. Add a regression test reading a markdown file starting with "MZ Industries 2026 Q1 — note that the PE format begins with these bytes" and asserting `isBinaryContent == false`.

---

### INFO — SE-V17-01: Promoted-to-core rows drop from `memory_list` per-session listings (surface a)

**File:** `src/zaki_state.zig:2606` (promote sets session_id=NULL), `src/zaki_state.zig:2820,2838` (listMemories filters `WHERE session_id = $X`), `src/tools/memory_list.zig:41-49` (caller)

**Issue:** `memory_list` with `scope=session` calls `listMemories(category, session_id)`, which filters by `session_id = $X`. Promoted-to-core rows (session_id=NULL) silently disappear from per-session results. Conceptually correct ("promoted = transcends sessions"), but a user/agent debugging "where did my fact go?" via `memory_list scope=session` after promotion will see it vanish. The fact is still discoverable via `scope=global` and `memory_recall`. Marginal — flag for tool-description clarity, not a bug.

**Recommendation:** add one line to `memory_list.zig`'s `tool_description` clarifying scope=session excludes promoted core memories. Or: have `listMemories(session_id)` do `WHERE session_id = $X OR (memory_type = 'core' AND session_id IS NULL)` to surface promoted facts in session view too. Defer until users hit it.

---

### INFO — SE-V17-02: `pending_conflicts` marker text wording is mildly ambiguous (surface a)

**File:** `src/zaki_state.zig:2630`

**Issue:** Marker content reads `"... call memory_store to update it and memory_forget(\"pending_conflicts\") to clear this flag."`. The "it" refers to the conflicted key (shown above as `key={s}`). A literal-minded LLM could mis-read this as "call memory_store on `pending_conflicts`" then "memory_forget pending_conflicts" — leaving the actual conflicted key untouched. The conflicted key IS shown in the marker, so a competent agent will get it right; a small model might not. `memory_forget("pending_conflicts")` itself works correctly: lifecycle-lookup classifies the key as `editable` (pure `core`, not in `isSystemManagedMemoryKey` list, not append-only), so the delete succeeds.

**Recommendation:** rewrite as `"call memory_store(key=\"<KEY ABOVE>\", content=...) to update the conflicted fact, then call memory_forget(key=\"pending_conflicts\") to clear this flag."`. One-line text fix.

---

### PASS-NOTE — SE-V17-03: `insertEpisodeEvent` writes to `memory_events`, not `completion_events` — no collision

**Files:** `src/zaki_state.zig:2702-2752` (insertEpisodeEvent → `memory_events`), `src/zaki_state.zig:2070-2113` (loadCompletionEvents reads `completion_events`)

These are distinct tables. `loadCompletionEvents` returns `CompletionEvent` rows from `completion_events` ordered by `created_at, id` — `insertEpisodeEvent` cannot affect its results. Existing `event_type='upsert'` aggregations on `memory_events` (lines 5421, 5443) filter by exact event_type match (`compose`, `traversal`); `'episode'` rows do not enter those COUNTs.

---

### PASS-NOTE — SE-V17-04: `pending_conflicts` IS deliberately injected into agent context — by design, not a leak

**Files:** `src/agent/memory_loader.zig:432, 592` (appendDirectEntry on session-load), `src/memory/root.zig:558-567` (BRAIN_HIDDEN_EXACT_KEYS)

The `pending_conflicts` marker IS supposed to surface to the agent at session start (entire point of V1.7 Item 3). The `BRAIN_HIDDEN_EXACT_KEYS` entry only hides it from `/brain/*` (user-facing surfaces); the agent-context loader explicitly reads it. The marker content uses a structured `type=...` prefix that the agent recognizes and does not parrot to the user verbatim. Confirmed working as designed.

---

### PASS-NOTE — SE-V17-05: `confidence_score = 0.9` on promotion does not affect retrieval ranking

**Files:** `src/zaki_state.zig:2606`, `src/memory/importance.zig:23` (gap-analysis comment)

`importance.zig` explicitly notes `confidence_score` is column-only, NOT consumed by importance scoring as of V1.6. Grep confirms no retrieval path SELECTs or sorts by `confidence_score`. Promoted rows do not unfairly outrank organic ones.

---

### PASS-NOTE — SE-V17-06: `seen_in_session_count` column has no out-of-V1.7 readers

**File:** `src/zaki_state.zig:1066` (ALTER TABLE), `src/zaki_state.zig:2186-2193, 2481-2494` (only writers/readers in upsert RETURNING)

ALTER TABLE adds with `DEFAULT 1 NOT NULL`. Only readers are the RETURNING clauses of upsertMemory + upsertMemoryWithMetadata. No SELECT path reads it; no risk to non-V1.7 code. Backfill of pre-existing rows handled by NOT NULL DEFAULT 1.

---

### PASS-NOTE — SE-WIP-02: `delegate.zig` default-branch behavior unchanged for callers without new fields

**File:** `src/tools/delegate.zig:98-121`

When `agent_cfg.system_prompt_path == null` AND `agent_cfg.workspace_path == null`, code falls through to `ac.system_prompt orelse "You are a helpful assistant. Respond concisely."` — exact pre-cherrypick behavior. Existing delegate calls without these fields are byte-identical. Bonus: `sys_prompt_owned` flag correctly gates the deferred free, no leak when borrowed.

---

### PASS-NOTE — SE-WIP-03: `getArray` helper used by calculator only; correctly handles `.array` JsonValue

**Files:** `src/tools/root.zig:54-60` (helper), `src/tools/calculator.zig:33` (sole caller)

Switch on `JsonValue` correctly returns `null` for non-array variants. No risk of UB on string/object/number inputs.

---

### PASS-NOTE — SE-WIP-04: Teams + Nostr modules build cleanly under `-Dchannels=all`; type errors would surface in production-equivalent build

**Files:** `src/channels/root.zig:149-150` (unconditional pub const), `build.zig:72-73` (`-Dchannels=all` enables both)

Verified `zig build -Dchannels=all` exits 0. The `pub const teams = @import("teams.zig")` at root.zig:149 is consistent with every other channel and does not force module analysis on its own (Zig's lazy semantic analysis), but `-Dchannels=all` is the canonical CI/release invocation per build.zig and exercises full type-checking. Channel-manager wire-up is still pending (CR-WIP-02 note in REVIEW.md), but that's a feature gap, not a side-effect.

---

### PASS-NOTE — SE-WIP-05: TeamsConfig + NostrConfig parse safely from configs missing those blocks

**File:** `src/config_types.zig:672-673`

`teams: []const TeamsConfig = &.{}, nostr: []const NostrConfig = &.{}` — Zig std.json honors struct defaults, missing fields parse to empty slices. Existing `config.json` files without these blocks load unchanged.

---

_Side-effect audit: 2026-05-02_
_Auditor: Claude (gsd integration reviewer)_
_Scope: surfaces beyond the parallel agents' stated targets_
