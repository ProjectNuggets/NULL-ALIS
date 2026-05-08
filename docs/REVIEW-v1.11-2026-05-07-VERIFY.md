# V1.11 Code Review — Verification Pass

**Verified:** 2026-05-07
**Source SHA snapshot:** post `b42f4c3`
**Method:** read current source, compare against original finding, check for regressions or half-measures.

## Per-finding verdicts

### CR-01 — /approve UAF — **PASS**
- `src/agent/root.zig:1722-1751`: `executeApprovedPendingTool` no longer carries `defer self.clearPendingToolApproval()`. New comment correctly documents caller-owned clear + `approval_bypass_active` re-entry guard.
- `src/agent/commands.zig:2548-2626`: caller holds pending live across the `executeApprovedPendingTool` call, builds `synthetic` from `pending.tool_name` (line 2613), then calls `clearPendingToolApproval()` at line 2626 — AFTER the slice has been read into the owned buffer. Error path at 2549 clears before returning. Legacy `!continues_turn` branch clears via `defer` at 2589. Deny path clears at 2523. All four return paths clear pending before exit.
- No early-return path leaves stale pending state.

### CR-02 — SSE publish race — **PASS**
- `src/gateway.zig:763-766`: mutex held across `subscriber.enqueue`. No early unlock between `get` and `enqueue`.
- `AppEventsSubscriber.enqueue` (gateway.zig:639-650) only touches the subscriber's own `mutex` + `allocator.dupe` via `LiveAppCompletionEvent.initOwned`; no callback into the registry. Lock-order registry → subscriber preserved. No deadlock risk.

### CR-03 — NaN/Infinity in /brain/graph JSON — **PASS**
- `src/zaki_state.zig:6610-6613` and `:6707-6710`: both edge parser sites add `isFinite` clamp on `conf_raw` and `weight_raw`.
- `src/gateway.zig:131-139`: `jsonSafeFloat` (f64) and `jsonSafeFloatF32` (f32) helpers present.
- All four scoped emit sites wrapped: `12161` (similarity), `12188` (confidence+weight), `12608` (weight+confidence), `13353` (weight). NaN/Infinity row → finite default in JSON.
- Note: importance/score emits at `gateway.zig:12085, 12323, 13302` remain unwrapped, but those columns were not in CR-03 scope (originate from runtime computation, not edge storage). Out of scope for this verification.

### HI-01 — completeTask leak — **PASS**
- `src/subagent.zig:592-602`: `transferred` bool + `defer if (!transferred)` block frees `owned_result`/`owned_err` on the no-task-found path.
- `transferred = true` is set at line 617, immediately after `state.error_msg = owned_err` (line 616). The intervening lines 614-616 are pure scalar/pointer assignments — no fallible ops between transfer and flag-set. Correctly placed.

### HI-02 — stale executeApprovedPendingTool comment — **PASS**
- `src/agent/root.zig:1717-1731`: old "Clear pending state first" wording gone. New comment cites CR-01 fix date, explains caller ownership, and names `approval_bypass_active` as the re-entry guard.

### HI-03 — listOrphanMemories docstring + test — **PASS**
- Docstring `src/zaki_state.zig:3795-3805`: states "does NOT apply MEMORIES_VALIDITY_FILTER" with V1.11 / 2026-05-07 rationale citing Nova's "don't filter" directive.
- Test `src/zaki_state.zig:11371-11393`: `seen_superseded_orphan` flag declared (11374), set in loop (11380), positively asserted (11392). Negative assertion against `mem_superseded_orphan` removed. Expected count is `4` (11393).
- `zig build test` exit=0 with the inverted acceptance.

### HI-04 — root.zig:927 stale comment — **PASS**
- `src/agent/root.zig:925-935`: comment updated to (1) clarify 50% is advisory-only, (2) cite 70% Pass A and 90% Pass C as actual fire thresholds, (3) note Pass B was deleted in iter28. Stale "/B" reference is gone.

### ME-01 — getJobsJson NULL handling — **PASS**
- `src/zaki_state.zig:2148`: innermost `jsonb_set` now wraps `raw_job` in `COALESCE(raw_job, '{}'::jsonb)`. NULL raw_job → empty object → finite jsonb chain → no NULL element in array.

### ME-02 — getJobsJson unbounded — **PASS**
- `src/zaki_state.zig:2158`: `ORDER BY created_at LIMIT 500` present inside the inner subquery before the closing paren. Comment cites BRAIN_DEFAULT_MAX_NODES sibling rationale.

### ME-05 — composeFinalReply whitespace-only reasoning — **PASS**
- `src/agent/commands.zig:3855-3859`: `trimmed_reasoning` computed once. `has_reasoning = trimmed_reasoning.len > 0` (trimmed length, not raw).
- Fallback at `:3879-3884` uses `trimmed_reasoning` directly — no second trim. Whitespace-only reasoning_content correctly fails the gate.

## New issues introduced by fixes
None observed. All fixes are surgical and additive; no regressions, no new bugs.

## Demo-ship verdict — **YES**
All ten claimed fixes verified clean. CR-01/02/03 are the user-visible blockers (UAF crash, SSE race, brain JSON corruption) — all three resolved with sound reasoning and no residue. Tests pass. Ship.

---

_Verifier: Claude (gsd-code-reviewer)_
_Depth: targeted verification_
_Build: `zig build test` exit=0_
