---
phase: V1.11-code-review
reviewed: 2026-05-07
depth: deep
files_reviewed: 8
files_reviewed_list:
  - src/subagent.zig
  - src/gateway.zig
  - src/agent/commands.zig
  - src/agent/root.zig
  - src/agent/compaction.zig
  - src/agent/context_builder.zig
  - src/agent/model_capabilities.zig
  - src/zaki_state.zig
findings:
  critical: 3
  high: 4
  medium: 7
  low: 9
  nit: 4
  total: 27
status: issues_found
ship_verdict: conditional
---

# nullalis V1.11 Code Review — Web Summit Demo Readiness

**Reviewed:** 2026-05-07
**Depth:** deep (cross-file trace of subagent → gateway → SSE → session)
**Files Reviewed:** 8 (Tier-1 demo paths + V1.11 deltas)
**Status:** issues found — three CRITICAL bugs

## Executive Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 3     |
| HIGH     | 4     |
| MEDIUM   | 7     |
| LOW      | 9     |
| NIT      | 4     |
| **Total**| **27**|

### Top 3 Demo Risks

1. **CR-01 — Use-after-free in `/approve` handler.** `handleGenericToolApprove` keeps a struct copy of `pending_tool_approval` whose slice fields point into `Agent` memory. `executeApprovedPendingTool` frees that memory via `defer self.clearPendingToolApproval()` before returning. The caller then dereferences the dangling slices to format the synthetic continuation prompt. This is the booth-demo path: click approve → crash or scrambled prompt to the LLM.
2. **CR-02 — Use-after-free race on `/chat/events` SSE subscriber.** `AppEventSubscriberRegistry.publish` reads the subscriber pointer under the registry mutex, releases the mutex, then calls `subscriber.?.enqueue` after release. The subscriber is stack-allocated in `handleChatEvents`; if that handler returns between the unlock and the enqueue, a subagent-completion publish from a different thread dereferences a freed stack frame.
3. **CR-03 — `findEdgesByKeys` can leak NaN/Inf into `/brain/graph` JSON.** `confidence` and `weight` are Postgres `float`/`bigint`-derived `f64`; they are emitted with `{d:.3}` formatter which prints `nan`/`inf` for non-finite values. `JSON.parse()` on the FE rejects this, breaking the brain page entirely on the first poisoned row.

### Ship-as-is verdict for the demo

**Conditional.** Fix CR-01 (the user-visible click-approve crash) and CR-03 (one-bad-row-kills-brain). CR-02 is a narrow race that probably never fires in a 30-minute booth session but is an unbounded liability post-demo. Tier-2 issues (HI-01..HI-04) are paper cuts, not blockers.

---

# Tier 1 — Demo Killers

## CR-01 — Use-after-free of pending_tool_approval slices in /approve

**File:** `src/agent/commands.zig:2488,2542,2596-2607`
**Companion:** `src/agent/root.zig:1717-1729`
**Severity:** CRITICAL

### What's wrong

`handleGenericToolApprove` line 2488:
```zig
const pending = self.pending_tool_approval.?;
```
This is a **struct copy** of `?PendingToolApproval` (def at root.zig:1444). Its `tool_name`, `arguments_json`, `tool_call_id`, and `reason` are `[]const u8` slices pointing into `Agent.allocator`-owned memory.

Line 2542 calls `self.executeApprovedPendingTool(arena.allocator())`. Inside (root.zig:1729):
```zig
defer self.clearPendingToolApproval();
```
which frees `pending.tool_name`, `pending.arguments_json`, `pending.reason`, and `pending.tool_call_id` before returning.

Back in commands.zig, line 2596-2607 builds the synthetic continuation prompt:
```zig
const synthetic = try std.fmt.allocPrint(
    self.allocator,
    "[Approved tool execution: id={d} tool={s} status={s}{s}]\n\n...",
    .{ id_snapshot, pending.tool_name, ... }
);
```
`pending.tool_name` is now a slice into freed memory. `std.fmt.allocPrint` reads it to format the string.

This is the path the booth demo flows through every time a user clicks approve in the chat UI.

### Symptoms (likely)

- ALSAN/UBSAN crash in debug builds.
- In release builds: garbled tool name in the LLM-facing prompt → LLM produces a nonsense reply, OR a plain segfault if the freed pages are unmapped, OR (best case) the bytes happen to still be valid because no other allocation has reused them yet. The race window is the time between `clearPendingToolApproval` running and `allocPrint` reading.

### Fix

Snapshot the strings into stack buffers or arena-allocated copies BEFORE calling `executeApprovedPendingTool`. Minimal patch:
```zig
// At top of handleGenericToolApprove, after const pending = ...
const tool_name_snap = try self.allocator.dupe(u8, pending.tool_name);
defer self.allocator.free(tool_name_snap);
// then use tool_name_snap in line 2601 instead of pending.tool_name
```

Or — cleaner — change `executeApprovedPendingTool` to NOT clear pending state internally, and have `handleGenericToolApprove` clear it as the LAST step (after the synthetic prompt is built). The current arrangement has the wrong ownership boundary.

### How to verify the fix

1. Build with `-Doptimize=Debug` and run the existing tests under `valgrind` or zig's GeneralPurposeAllocator with safety checks on.
2. New unit test: set up an `Agent` with a stub tool that requires approval, drive `handleGenericToolApprove`, assert the returned synthetic-prompt string contains the original tool name verbatim, and assert no UAF (GPA panic) on close.
3. Manual: in the FE, click approve and confirm the agent's continuation message names the tool correctly.

### Bonus finding (same function)

Line 2615: `const continuation_result: anyerror![]const u8 = self.turn(synthetic);`. Note `synthetic` is `defer self.allocator.free(synthetic);` (line 2608). If `self.turn()` returns by storing or aliasing `synthetic` in agent history, the defer breaks that aliasing. (Spot-check shows `turn` likely dupes; verify.)

---

## CR-02 — Use-after-free race in AppEventSubscriberRegistry.publish

**File:** `src/gateway.zig:731-739`
**Companion:** `src/gateway.zig:8922-8928` (subscriber lifetime), `src/gateway.zig:425-430` (publish caller)
**Severity:** CRITICAL

### What's wrong

```zig
fn publish(self, ..., key, ...) !bool {
    self.mutex.lock();
    const subscriber = self.subscribers.get(key);
    self.mutex.unlock();                              // ← unlock BEFORE deref
    if (subscriber == null) return false;
    return try subscriber.?.enqueue(...);             // ← may UAF
}
```

Subscriber lifetime in `handleChatEvents`:
```zig
var subscriber = AppEventsSubscriber{};               // stack-allocated
defer subscriber.deinit(state.allocator);             // runs LAST
state.app_event_subscribers.register(...);
defer state.app_event_subscribers.unregister(...);    // runs FIRST
```

Race:
1. Thread S (subagent completion delivery): `publish` acquires registry mutex, reads `subscriber` ptr, **releases mutex**.
2. Thread H (the SSE client disconnects, `handleChatEvents` is unwinding): `unregister` runs (acquires registry mutex, removes entry, releases), then the function returns. The `subscriber` stack frame is reclaimed. Mutex memory inside the struct is now garbage.
3. Thread S: calls `subscriber.?.enqueue(...)` → calls `self.mutex.lock()` on freed stack memory. UAF.

### Likelihood

Narrow — tens of microseconds between unregister and stack reclamation. But: a flaky internet booth, an aggressive client like Chrome closing /chat/events on tab-blur, or a load test will hit this.

### Fix

Hold the registry mutex across the entire enqueue call. The contract is: subscribers MUST NOT call back into the registry from inside enqueue (no re-entrancy), so holding the mutex is safe. Or: refcount the subscriber. The mutex-hold version is simplest:

```zig
fn publish(self, ..., key, ...) !bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    const subscriber = self.subscribers.get(key) orelse return false;
    return try subscriber.enqueue(...);
}
```

Note `enqueue` takes its own internal mutex; lock-order is registry → subscriber, no inversion.

### How to verify

1. ThreadSanitizer if available, or stress test: spin up 100 SSE connect/disconnect loops while a subagent completion is publishing in a tight loop. Pre-fix should crash; post-fix should not.
2. Static check: confirm no caller holds subscriber.mutex before calling registry.publish (would cause inversion).

---

## CR-03 — NaN / Infinity leak into /brain/graph JSON breaks FE

**File:** `src/gateway.zig:12158-12160`
**Companion:** `src/zaki_state.zig:6675-6676` (parser is permissive), `src/gateway.zig:11174-11175` (struct layout)
**Severity:** CRITICAL (for the brain demo specifically), HIGH otherwise

### What's wrong

The new V1.11 emission path:
```zig
w.print("\",\"confidence\":{d:.3},\"weight\":{d:.3}}}", .{ e.confidence, e.weight });
```

Zig's `{d:.3}` formatter on f64 produces `"nan"` / `"inf"` / `"-inf"` for non-finite inputs — none of which are valid JSON. The frontend's `JSON.parse(response)` throws `SyntaxError: Unexpected token n in JSON at position N` and the entire brain graph fails to render.

How could a non-finite value get there?

1. `findEdgesByKeys` (zaki_state.zig:6675-6676) parses the columns with `std.fmt.parseFloat(f64, ...) catch 1.0`. **`parseFloat` accepts `"NaN"` and `"Infinity"` strings successfully**, so the catch only triggers on truly malformed strings — a stored `'NaN'::float` flows through.
2. Postgres allows `'NaN'::float` and `'Infinity'::float` in float columns. Whether anything in the corpus pipeline writes those today is the question; the upsert paths for `memory_edges` use `COALESCE((metadata->>'confidence')::float, 1.0)` (zaki_state.zig:1433). If `metadata->>'confidence'` ever returns `'NaN'` (extractor bug, weird LLM output), it lands as NaN.
3. `weight` is more comfortable — defaults to `1.0` from a vote count — but the cast path is identical and could in principle parse `'NaN'`.

A single bad row poisons the entire response (json_agg-style emission with a bad number breaks parse for the whole array).

### Fix

Sanitize at the emit site. Pattern (also handles -inf):

```zig
fn safeFloat3(v: f64) f64 {
    if (std.math.isFinite(v)) return v;
    return 0.0; // or 1.0 if you want default-confidence semantics
}
// usage:
w.print("\",\"confidence\":{d:.3},\"weight\":{d:.3}}}", .{
    safeFloat3(e.confidence),
    safeFloat3(e.weight),
});
```

Or (better): clamp at the parser in `findEdgesByKeys` — `if (!std.math.isFinite(conf)) conf = 1.0;` so the bad value is caught at the source-of-truth boundary.

### How to verify

1. Test: `INSERT INTO memory_edges (... confidence) VALUES (..., 'NaN'::float)`, hit `/brain/graph`, assert `JSON.parse(body)` succeeds, assert `confidence` is finite.
2. Add a debug log at the parser that warns when a non-finite value is observed — surfaces stored corruption without breaking the response.

### Adjacent finding (same site)

Line 12133: `w.print("\",\"weight\":{d:.4}}}", .{e.similarity});` — same NaN risk for the **semantic** edge weight. Fix in the same patch.

---

## HI-01 — Subagent completeTask leaks owned_result/owned_err on missing-task race

**File:** `src/subagent.zig:587-700`
**Severity:** HIGH (memory leak; not a crash)

### What's wrong

```zig
fn completeTask(self, task_id, result, err_msg) void {
    const owned_result = if (result) |r| self.allocator.dupe(u8, r) catch null else null;
    const owned_err    = if (err_msg) |e| self.allocator.dupe(u8, e) catch null else null;

    {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.get(task_id)) |state| {
            // state.result = owned_result;   ← only here is ownership transferred
            // state.error_msg = owned_err;
        }
        // else: task missing. owned_result and owned_err are LEAKED.
    }

    // ... routing path uses owned_result.? to build content, frees content,
    // but owned_result and owned_err are never freed if the if-branch above
    // didn't execute.
}
```

If the task entry was removed between thread spawn and completion (e.g., `clearTasksLocked` during `attachPostgresLedger`, or a future cancellation path that frees state out of band), the dupes leak forever.

### Fix

Release the unowned dupes at the end of the function if state-transfer didn't happen:

```zig
var transferred = false;
{
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.tasks.get(task_id)) |state| {
        // ... existing logic ...
        state.result = owned_result;
        state.error_msg = owned_err;
        transferred = true;
    }
}
defer {
    if (!transferred) {
        if (owned_result) |r| self.allocator.free(r);
        if (owned_err) |e| self.allocator.free(e);
    }
}
```

### How to verify

GPA leak check on a test that calls `completeTask` for a task_id that was removed from the map first.

---

## HI-02 — Stale comment in executeApprovedPendingTool ("Clear pending state first")

**File:** `src/agent/root.zig:1727-1729`
**Severity:** HIGH (misleads readers; near-miss for double-fault)

### What's wrong

```zig
// Clear pending state first so the tool cannot trigger re-approval
// during its own execution path.
defer self.clearPendingToolApproval();
```

Defer runs at scope exit, NOT first. Pending state is cleared AFTER `executeToolUnchecked`. The actual re-approval guard is `approval_bypass_active = true` (line 1725), which DOES apply during execution. The comment describes a different (incorrect) defense.

This same misreading by a future contributor could lead to a "let me move clearPendingToolApproval to be earlier" change — which would directly cause the UAF in CR-01 even sooner.

### Fix

Replace the comment:
```zig
// Clear pending state on scope exit (LIFO defer order: runs AFTER tool
// execution, BEFORE approval_bypass_active reset). Re-approval during
// execution is prevented by approval_bypass_active above, not by the
// pending state being null.
defer self.clearPendingToolApproval();
```

---

## HI-03 — Stale docstring on listOrphanMemories + test acceptance #6 will fail

**File:** `src/zaki_state.zig:3779-3812`, `src/zaki_state.zig:11269-11270`, `src/zaki_state.zig:11345`
**Severity:** HIGH (test breakage; comment lies)

### What's wrong

V1.11 commit `61b322e` deliberately removed `MEMORIES_VALIDITY_FILTER` from `listOrphanMemories`, but:

1. Lines 3779-3788 still claim **"Bi-temporal correctness: applies MEMORIES_VALIDITY_FILTER to the memories row"**. False — it does not.
2. The test at line 11272 codifies acceptance criterion #6: **"Superseded memory (validity-filtered) → NOT returned even with no edges"**.
3. Line 11345 asserts `try std.testing.expect(!std.mem.eql(u8, e.key, "mem_superseded_orphan"));` — but `mem_superseded_orphan` IS now expected to appear under V1.11 semantics.

If the test suite hasn't been re-run with `-Doptimize=Debug -Dtest=true`, this regression is dormant; if it has, CI is broken. Either way the comment is now a lie.

### Fix

1. Update the docstring (lines 3779-3812): replace "applies MEMORIES_VALIDITY_FILTER" wording with the V1.11 rationale already partially captured in the inline comment at line 3806.
2. Update the test:
   - Line 11269: change criterion #6 to its inverse — superseded orphan SHOULD appear.
   - Line 11345: flip the assertion.
   - Add a positive assertion: `seen_superseded_orphan` flag plus expect-true.
3. Run `zig build test` to confirm.

### How to verify

`zig build test 2>&1 | grep "listOrphanMemories"` — should pass.

---

## HI-04 — Tier 1 token-budget: compaction_trigger=50% but Pass A fires at 70%

**File:** `src/agent/compaction.zig:141-142, 169` and `src/agent/root.zig:927`
**Severity:** HIGH (operator-misleading; not a runtime bug)

### What's wrong

`TokenBudgetPolicy.compaction_trigger` is computed as `(token_limit * 50) / 100` (compaction.zig:169). This drives `token_compaction_triggered` in the snapshot used by `/context` reporting (context_builder.zig:262). Operators reading the report see "compaction triggered" at 50% pressure — but actual compaction passes don't fire until 70% (Pass A) or 90% (Pass C).

Compounding it: root.zig:927 says **"Fires at compaction_trigger (50% of model window) via Pass A/B/C"** — but Pass B was deleted in iter28. So the comment is wrong on both the threshold AND the pass list.

### Fix

Two paths:
1. **Code-truth path:** rename `compaction_trigger` to `compaction_recommended_at` and document it as "the operator-facing 'we'd recommend compacting at this point' threshold; actual passes fire at 70/90 inside autoCompactHistory."
2. **Honesty path:** set `compaction_trigger = (token_limit * 70) / 100` so it matches Pass A.

Either is fine. Today's 50% number is a phantom — it fires neither a pass nor a UI behavior anyone consumes. Lean toward path 2.

Also fix root.zig:927 to drop the "/B" and update the percentage.

---

# Tier 2 — V1.11 Recent Changes

## ME-01 — getJobsJson: jsonb_set chain returns NULL if raw_job is NULL

**File:** `src/zaki_state.zig:2130-2159`
**Severity:** MEDIUM

### What's wrong

```sql
jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(raw_job, '{enabled}', ...), ...), ...), ...), ...)
```

If `raw_job` IS NULL for any row, the entire chain returns NULL, and `jsonb_agg` includes a NULL element in the output array (`[null, {...}, ...]`). The FE has to handle nulls or it'll throw on `.map`. Real risk depends on schema — if `raw_job` is `NOT NULL` the issue is moot; if it's nullable, you have a sharp edge.

### Fix

```sql
jsonb_set(COALESCE(raw_job, '{}'::jsonb), '{enabled}', ...)
```

Or filter at SELECT: `WHERE raw_job IS NOT NULL`.

### How to verify

`SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='jobs' AND column_name='raw_job' AND is_nullable='YES');` — if YES, fix needed.

---

## ME-02 — getJobsJson is unbounded and may leak agent-internal fields

**File:** `src/zaki_state.zig:2130-2159` and `src/gateway.zig:9923-9956`
**Severity:** MEDIUM

### What's wrong

1. **Unbounded result.** No `LIMIT`. A user with thousands of cron jobs would materialize all of them as one allocator dupe. The SSE handler has SSE_KEEPALIVE etc.; the JSON list endpoint has no analog.
2. **Raw splice of `raw_job`** into the FE response (line 9952). Whatever the agent stored in `raw_job` (full prompt? secret references? source channel info?) is exposed verbatim. If the schema includes any field the FE shouldn't see, it leaks.

### Fix

Add `LIMIT 500` (or whatever the FE pagination wants). Whitelist fields before emit — pick out `id, schedule, summary, enabled, paused, last_status, ...` explicitly instead of splicing raw_job.

### How to verify

Inspect `raw_job` payload for one user; manually decide what should be public.

---

## ME-03 — Subagent route precedence comment is correct but easy to break

**File:** `src/subagent.zig:634-700`
**Severity:** MEDIUM

The big comment at lines 634-659 explaining "completion_delivery FIRST, bus SECOND" is excellent. However, the code that implements it is one `if/else if` chain — a future contributor adding a third sink (e.g., a metrics tap) above the existing ones could accidentally swap precedence. Consider extracting `route_completion(self, content, request_session_key, ...)` into a helper with a hard-coded ordering and a unit test that asserts: when both sinks are attached, completion_delivery is called and bus is NOT.

(There's a test at line 1299 — good — but it lives in this file, not in a regression suite that catches the more subtle "dual-attach plus a third future hook".)

### Fix

Optional refactor; not blocking demo.

---

## ME-04 — Same content delivered twice produces double-reply (no dedup at session history layer)

**File:** `src/gateway.zig:421-431`, `src/session.zig:868-877`
**Severity:** MEDIUM

`appendAssistantMessage(delivery_key, content)` followed by `saveCompletionEvent` followed by `publish`. There's NO deduplication on the assistant-message side — a process restart that replays a queued subagent task would write the same `content` to history twice. Subscriber dedup (`delivered_ids`) only prevents the SSE frame from being sent twice; the canonical history is double-stamped.

### Fix

Either:
1. Hash content + (label, task_id) and dedup in `appendAssistantMessage`, OR
2. Move `appendAssistantMessage` to be idempotent on `(session_key, completion_event_id)` if event_id is present.

Lower priority for the demo (a process restart mid-demo is unlikely).

---

## ME-05 — composeFinalReply: whitespace-only reasoning_content emits empty reply

**File:** `src/agent/commands.zig:3829-3856`
**Severity:** MEDIUM

```zig
const has_reasoning = reasoning_content != null and reasoning_content.?.len > 0;
...
const final_base: []const u8 = if (has_visible_text)
    trimmed_base
else if (has_reasoning)
    std.mem.trim(u8, reasoning_content.?, " \t\r\n")  // ← could trim to empty
else
    base_text;
```

If `reasoning_content` is `"   \n  "` (length > 0 but all whitespace), `has_reasoning=true`, we fall into the `else if` arm and trim to an empty slice. The user receives an empty reply — the exact bug V1.11 was supposed to fix.

### Fix

Test the trimmed length, not the raw length:
```zig
const trimmed_reasoning: []const u8 = if (reasoning_content) |r| std.mem.trim(u8, r, " \t\r\n") else "";
const has_reasoning = trimmed_reasoning.len > 0;
const final_base: []const u8 = if (has_visible_text) trimmed_base
    else if (has_reasoning) trimmed_reasoning
    else base_text;
```

### How to verify

Unit test: pass `base_text=""`, `reasoning_content="  \n  "`, assert returned reply is non-empty (or document the empty-reply contract explicitly).

---

## ME-06 — Subagent thread allocation lifecycle: spawn-then-mirror ordering risk

**File:** `src/subagent.zig:304-330`
**Severity:** MEDIUM

Order:
1. Line 304: `state.thread = std.Thread.spawn(...)` — the thread is now LIVE.
2. Lines 322-327: `td.createTaskWithNumericId` — mirror to canonical ledger.

The thread will block on `markTaskRunning` (line 793) until `spawn`'s mutex unlock (which happens when spawn returns at line 329). So the in-spawn ordering is safe as documented.

But: if the thread inherits `attachTaskDelivery` being called LATER (after spawn but before the thread observes `task_delivery`), there's a TOCTOU on `self.task_delivery`. `markTaskRunning` reads `self.task_delivery` under mutex — that part is fine. But a transition that mirrors to td (e.g., line 715) reads `self.task_delivery` and calls `td.markRunning(id)`. If between spawn-time `task_delivery=nil` and now `task_delivery=td_new`, the canonical ledger never saw `createTaskWithNumericId` for this task and `markRunning` will fail or no-op.

### Fix

Either snapshot `task_delivery` at spawn time and store on the TaskState, or guarantee `attachTaskDelivery` is called once at startup before any `spawn`. Code review of bootstrap would tell.

### Severity rationale

Not a crash. Worst case is canonical ledger missing a row for the duration of one task — observability hole, not data loss.

---

## ME-07 — appendSubagentCompletionToGatewaySession leaks completion_event_id on partial failures

**File:** `src/gateway.zig:421-482`
**Severity:** MEDIUM

```zig
const completion_event_id = try router.session_mgr.saveCompletionEvent(...);
defer if (completion_event_id) |value| router.session_mgr.allocator.free(value);
```

For zaki_app path (line 425-431), event_id is published and the function returns. The DB row is NOT deleted (unlike the bus path at line 480-482). The intent is that the SSE handler deletes the row after frame delivery (line 8946). But:

- If no SSE handler is attached at the moment, the row sits in `completion_events` forever until next reconnect, then dedups on `delivered_ids`. That's intended.
- However: if `subscribers.publish(...)` returns `false` (no subscriber), there's no log indicating "row left for catch-up" vs "row dropped". The catch-up reconnect path will pick it up — eventual consistency. OK.
- BUT: the bus-path catch at line 466 calls `dispatchSubagentCompletionLocally` AND `deleteCompletionEvent` if dispatch succeeds. Ownership of `outbound` is transferred (`outbound_transferred = true`). If `dispatchSubagentCompletionLocally` errors, the catch propagates `try` which makes the function return WITHOUT ever calling `deleteCompletionEvent` — so the row is left for the SSE catch-up path to discover. That's actually fine (event will be retried), but the comment "If err == error.Closed" path doesn't fall through correctly: on Closed, it goes to `dispatchSubagentCompletionLocally` then deletes event. On any other error, return without delete. If "any other error" is "transient publish failure", the next outbound channel attempt is dropped silently. 

Worth a comment audit.

---

# Tier 3 — Diagnoses Sanity Check

## ME-08 — Subscriber publish/subscribe semantics confirmed (modulo CR-02)

The publish/subscribe model is structurally sound:
- `register` replaces a prior subscriber for the same key (closes the old one — line 712-715).
- `enqueue` dedupes against `delivered_ids` (line 624) and against unsorted queue (line 625-627). Two-tier dedup is safe.
- `markDelivered` is idempotent and removes any queued copy (line 645-654).
- The catch-up path (handler line 8930-8947) reads pending events from DB before entering wait loop. Crucial: `publish` is called AFTER `saveCompletionEvent` so any pre-register-time events ARE in DB and picked up by `loadCompletionEvents`.

**CR-02 is the only race.** Fix it and this layer is solid.

### One follow-up worth checking

Line 712-715: `if (try self.subscribers.fetchPut(...)) |previous|` — closes the old subscriber. But the OLD handler that owns the old subscriber is still running (its `defer subscriber.deinit` hasn't fired). Two threads now hold pointers to the same subscriber via different paths (registry's previous-replace path closes it, and the original handler will deinit it on return). Closing twice is safe (close just flips a bool). Deinit twice would not be — but only one handler does the deinit. OK.

---

# Low-severity Findings

## LO-01 — Subagent allocator early-exits silently on OOM
**File:** `src/subagent.zig:660-669`
The `catch return` ladder drops owned_result/owned_err on alloc failure with no log. Add `log.err("subagent.completion_format_failed task_id={d}", .{task_id});` before each `return`.

## LO-02 — getRunningCount linearly scans tasks map
**File:** `src/subagent.zig:356-363`
With max_concurrent=4 this is fine. If max_concurrent ever scales, switch to an atomic counter. Defer.

## LO-03 — `state.thread = null` not set to null in completeTask
The thread reference lives in `state.thread` until deinit/joins. Tasks transitioning to `.completed`/`.failed` keep their `?std.Thread` field populated. `deinit` joins all (subagent.zig:167-169) which is correct, but a long-running daemon accumulates joined-but-unjoined Thread handles. Cosmetic.

## LO-04 — `freeTaskState` is referenced in errdefer but not loose-defined as exported (verify)
**File:** `src/subagent.zig:275, 437, 758`
Function appears used in `errdefer` blocks. Confirm it's defined elsewhere in the file; if not, the build wouldn't compile. (Likely fine — flagged for due diligence only.)

## LO-05 — handleSessionApprove unpins after error but mutex acquisition is sequential
**File:** `src/gateway.zig:11014-11036`
The pattern lock-fetch-bump-unlock-process-relock-decrement is correct under "active_refs > 0 prevents eviction" contract, but it's verbose and error-prone. Consider a `sessionPin(mgr, key) -> ?*PinHandle` helper with `defer pin.release()` semantics.

## LO-06 — Brain `BRAIN_SEMANTIC_THRESHOLD` defined but f32, while emit uses f64-ish format on `e.similarity`
**File:** `src/gateway.zig:11108` (`f32`) vs `src/gateway.zig:12133` (`{d:.4}` on similarity)
If `e.similarity` is f32 and contains NaN/Inf (cosine on a degenerate embedding), same NaN-in-JSON failure. See CR-03.

## LO-07 — `executeApprovedPendingTool` re-runs preflight which re-validates security/budget; if these now block, `pending` is cleared but `approval_bypass_active=false` runs first by LIFO defer order
**File:** `src/agent/root.zig:1725-1734`
Defers run LIFO: `clearPendingToolApproval` first, then `approval_bypass_active=false`. This is the correct order for normal exit. For the `.blocked` arm, no tool is executed, but pending is still cleared. The user's decision was "approve" but the tool ran into a budget block — the response will be the block message AND the pending approval has been cleared. User can't retry without re-issuing the original prompt. Documented behavior? Verify.

## LO-08 — `stats.orphans` count: not located in this review
The prompt asks whether the `stats.orphans` count "still returns correct counts" after V1.11. I did not find a `stats.orphans` aggregation in zaki_state.zig or gateway.zig in this pass. If counts are computed by a separate count query (e.g., `SELECT COUNT(*) FROM ... NOT EXISTS ...`), make sure it ALSO removed the validity filter — otherwise FE-displayed "X orphans" will disagree with the list length.

## LO-09 — Comment says "Pass A/B/C" but Pass B was deleted in iter28
**File:** `src/agent/root.zig:927`
See HI-04 fix.

---

# Nits

## NT-01 — Inconsistent log level for completion-event delete failure
**File:** `src/gateway.zig:8984-8987`
Uses `log.warn`. Given it's a metrics-tracked failure (`recordCompletionEventDeleteFailure`), `log.err` would match severity better.

## NT-02 — Magic numbers in compaction.zig
**File:** `src/agent/compaction.zig:158-159`
`reply_reserve` floor 8192, `tool_reserve` cap 16384, `safety_reserve` cap 8192 — promote to `pub const` with comments explaining the choice.

## NT-03 — `MAX_SYNTHETIC_OUTPUT_CHARS = 4000`
**File:** `src/agent/commands.zig:2585`
Magic number; promote to const at file scope.

## NT-04 — Brain edge dedup ordering test only against (source, target, predicate) — no assert that confidence/weight ordering is stable for ties
**File:** `src/gateway.zig:11517-11525`
Sort is fine for stable JSON output. But two edges with identical (source, target, predicate) but different confidence/weight will sort identically, leaving emission order non-deterministic against DB return order. If FE caches by edge fingerprint, this could flap. Add `.confidence DESC` as a tiebreaker.

---

# Closing — Demo Verdict

**Conditional ship.** Three CRITICAL findings:

| # | Bug | Demo impact |
|---|-----|-------------|
| CR-01 | Approve flow UAF | Approve button → garbage prompt → crash |
| CR-02 | SSE publish race | Booth WiFi flake → tab-blur → segfault |
| CR-03 | NaN in /brain JSON | One bad row → brain page blank |

**Pre-demo must-fix:** CR-01 and CR-03. They are deterministic, user-reachable, and have small patches. CR-02 is a race that probably won't fire in 30 minutes of booth time, but pre-fix is one mutex change — do it.

**Post-demo:** HI-01 through HI-04 (leak, comment, stale doc, threshold confusion), and the medium tier. None block the demo.

**Tests not run by this review.** Recommend: `zig build test 2>&1 | tee test-v1.11.log` before traveling. Specifically check the listOrphanMemories test (HI-03) which I expect to fail.

**What I did NOT review (out of scope or no time):**
- Cron / scheduler internals beyond `getJobsJson`.
- The full `src/channels/` family (channel adapters).
- Postgres migration safety.
- Provider fallback chains.
- Any `tools/*` implementations.

Reviewed: 2026-05-07
Reviewer: Claude Opus 4.7 (deep cross-file)
