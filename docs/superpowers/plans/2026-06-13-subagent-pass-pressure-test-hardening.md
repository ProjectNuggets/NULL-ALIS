# Subagent Pass — Pressure-Test Hardening + Locked Decisions

> Read alongside the Phase 4 (`...phase-4-fanout.md`) and Phase 5 (`...phase-5-superpowers-mode.md`) plans. This doc records the adversarial pressure-test findings, the fixes that MUST be applied during the build, and the product decisions the owner locked. Executors must apply these deltas — the original task code is hardened by what's below.

## Locked decisions (product owner)

1. **Billing = meter subagents at REAL cost + reserve.** Each subagent turn bills its actual tokens; the "Superpowers premium" is the N× real usage. **Drop the flat 5× parent multiplier.**
2. **Access = toggle-only.** No paid-tier entitlement gate — anyone can flip ⚡ Superpowers. Cost safety comes from the financial gate (reserve vs balance), not a tier check.
3. **Hard cut, not delayed catch-up.** The wallet is enforced at the **reserve gate** (before spending), not reconciled-late-to-allow-overspend. Insufficient balance → **refuse → the #51 paywall card** (upgrade / top-up).
4. **Per-tenant isolation confirmed** — `max_concurrent` is per-tenant; no user starves another's subagent budget. No global cap change needed. (Host RAM/CPU is a capacity-planning concern at scale, not a per-user bug.)

---

## Phase 4 hardening (apply during the fan-out build)

### H1 — Barrier dangling-pointer [Critical]
In `completeTask`, `batch_wake_id` must NOT point into tracker-owned memory read OUTSIDE the lock (the reaper could free the batch concurrently). **Dupe the batch_id inside the lock**, free after the wake:
```zig
var batch_id_to_wake: ?[]const u8 = null;
{
    self.mutex.lock(); defer self.mutex.unlock();
    if (st.batch_id) |bid| {
        emit_per_task_wake = false;
        self.batches.markTerminal(bid, task_id);
        if (self.batches.allTerminal(bid) and self.batches.tryClaimWake(bid))
            batch_id_to_wake = self.allocator.dupe(u8, bid) catch null;  // DUPE under lock
    }
}
if (batch_id_to_wake) |b| { defer self.allocator.free(b); /* enqueue batch wake */ }
```

### H2 — Reaper TOCTOU [Critical]
`reapBatchDeadlines` must read the tracker (overdue batches + their task_ids) UNDER the lock, then release before calling `completeTask` (which re-locks). Add `overdueBatchesWithTaskIds(allocator, now)` to BatchTracker that returns `[]struct{ batch_id, task_ids }` (both duped under the lock). Never call `taskIds()` outside the lock in the reaper.
```zig
pub fn reapBatchDeadlines(self: *SubagentManager, now_ms: i64) void {
    const overdue = blk: { self.mutex.lock(); defer self.mutex.unlock();
        break :blk self.batches.overdueBatchesWithTaskIds(self.allocator, now_ms) catch &.{}; };
    defer freeOverdue(self.allocator, overdue);
    for (overdue) |o| for (o.task_ids) |tid|
        self.completeTask(tid, .{ .status = .timeout, .text = "batch deadline exceeded", .err = "batch_deadline_exceeded" }, null);
}
```
(The reaper holds NO lock when calling completeTask — no reentrant deadlock. Add a test asserting this.)

### H3 — spawnMany capacity race (TOCTOU) [Important]
The capacity pre-check and the per-task spawn must be ONE lock acquisition, else two concurrent `spawn_many` calls can exceed `max_concurrent`. Hold the lock across pre-check + the whole spawn loop using a no-relock internal spawn:
```zig
{
    self.mutex.lock(); defer self.mutex.unlock();
    if (specs.len > self.remainingCapacityLocked()) return error.TooManyConcurrentSubagents;
    const seq = self.next_id;
    batch_id_local = try std.fmt.bufPrint(&idbuf, "batch:{d}:{d}", .{ seq, now });
    for (specs) |spec| { const tid = self.spawnInBatchLocked(spec, ..., batch_id_local) catch break; try ids.append(self.allocator, tid); }
    self.batches.register(batch_id_local, ids.items, request_session_key, now, now + budget_ms) catch {};
}
```
Refactor `spawnInBatch` → a `spawnInBatchLocked` (assumes the lock is held) + a public `spawnInBatch`/`spawn` that locks then calls it.

### H4 — Batch lifetime / cleanup leak [Critical]
Batches must be removed from the tracker or they accumulate forever. Add:
- `BatchTracker.expireBatch(batch_id)` (free the BatchState + its task_index entries).
- A `consumeBatch(batch_id)` manager method, and have the reaper sweep **expire** batches that are all-terminal + wake-claimed + older than a TTL (e.g. 30 min). Also expire on `subagent_batch_result` collection if the batch is terminal. Add a test that an expired batch is gone + frees memory.

### H5 — Restart mid-batch resilience [Medium, document + mitigate]
In-memory batch state is lost on a pod restart; the per-task completions are still durable (Phase 1 recovery re-delivers them per-task). To avoid the coordinator HANGING waiting for a batch wake that never comes: the **coordinator skill (Phase 5) must teach a polling fallback** — "if the batch wake doesn't arrive in a reasonable time, call `subagent_batch_result(batch_id)` / `task_get` to collect; do not block." Document the in-memory limitation; durable batch membership = a prod follow-up (Phase 6).

### H6 — Deadline-vs-completion race = CORRECT (document, no fix)
If the reaper marks a task `.timeout` and the thread finishes ~simultaneously, first-terminal-wins (the existing single-lock idempotency) resolves it: thread-finished-first → `completed`; reaper-at-deadline-first → `timeout`. A task PAST its deadline being `timeout` is correct behavior. Document; no code change.

### H7 — `subagent_batch_result` for unknown/expired batch [Minor]
`getBatchResults(unknown_id)` → return `error.UnknownBatch`; the tool returns a clear "batch not found / expired" message (don't return empty/None ambiguously).

### H8 — Partial spawn failure [Important — clarify]
With H3 (single-lock), a mid-loop spawn failure is rare. If it happens, register the batch with the ids that DID spawn and the `spawn_many` tool returns `{ batch_id, task_ids, count, requested, note }` where `note` says "k of N spawned" so the coordinator knows. Never silently drop.

---

## Subagent metering fix (money-critical — fixes a PRE-EXISTING gap; prerequisite for Superpowers)

**Finding:** subagent turns run `processMessageWithContext` with default `entry_kind=.http` + `usage_rt=null`, so their `turn_usage` row records **tokens=0**, and the BFF reconciliation sweep only debits `entry_kind='daemon'` rows → **subagent LLM spend is not billed.** (Verify against the live metering as step 1.) Fan-out multiplies this 8×.

**Fix (engine + BFF):**
1. **Engine — tag subagent turns:** in `subagentThreadFn`, pass `entry_kind = .daemon` (or a new `.subagent` entry_kind, if cleaner) to `processMessageWithContext`, so the turn is reconcilable (not assumed pre-settled via a done-frame that subagents don't emit). VERIFY which entry_kind the BFF sweep reconciles + matches.
2. **Engine — capture real tokens:** the subagent's `turn_usage` row must record the subagent loop's ACTUAL input/output tokens (today `usage_rt` is gateway-only → 0). Wire a usage accumulator for the subagent loop (mirror the gateway `usage_rt` path) so `insertTurnUsage` writes real tokens. This also finally populates `SubagentResult.tokens`/`turns` (the Phase-2 deferral).
3. **BFF — reconcile subagent rows:** ensure the reconciliation sweep (`agent-usage-reconcile.js`) debits subagent `turn_usage` rows (the matching `entry_kind`) to the wallet + emits the usage event. Test: a subagent turn with N tokens → wallet debited by N's cost.
4. **TDD + verify on staging:** spawn a subagent, confirm its tokens are recorded + reconciled to the wallet (not $0).

> This is its own focused workstream (it fixes today's single-spawn gap too). Build it BETWEEN Phase 4 and Phase 5 (Superpowers depends on it for the reserve estimate + correct settle).

---

## Phase 5 deltas (Superpowers mode)

### D1 — Drop the flat 5×; meter real cost
Remove the "flat 5× on the parent" tier. Superpowers cost = the parent turn (metered normally) + the N subagents (metered at real cost via the metering fix above). Optionally a SMALL fixed "coordination" surcharge on the parent (product knob, default 0). The BFF `hasSuperpowers` classification is now informational/telemetry (tag the turn `agent_superpowers` for analytics), NOT a flat multiplier.

### D2 — Toggle-only (no entitlement gate)
Do NOT add a paid-tier entitlement check. Any user can send `reasoning_effort="superpowers"`. The financial safety is the reserve gate (D3), not a tier gate.

### D3 — Fan-out cost gate = BOUNDED-OVERAGE (LOCKED 2026-06-12)
**Decision (owner):** Bounded-overage, NOT a pre-spawn reserve. Recon finding: the **engine has zero wallet access** — the reserve gate is entirely BFF-side, *before* the turn. A true pre-spawn reserve would need a new engine↔BFF reserve round-trip (a real architecture change / own workstream). Rejected for v1.

**How bounded-overage delivers the hard cut with NO new engine code** (all three pieces already exist):
1. **Subagents are billed** — the metering fix (this doc, above) tags subagent turns `entry_kind=.daemon`, so the BFF reconcile sweep debits them.
2. **Force-debit even into negative** — the reconcile sweep already uses `reserveUnits(allowOverdraw=true)` (agent-usage-reconcile.js), so a fan-out that overruns the balance still settles (the cost is never leaked).
3. **Hard cut at the NEXT turn** — the existing per-turn reserve gate (T13, BFF) refuses the next turn with 429 → the **#51 paywall card** once the balance is depleted.

**Net:** cost is always captured; max overspend = **one in-flight fan-out**; the cut lands at the next turn. The only gap vs a strict pre-spawn cut is that one bounded fan-out. A true pre-spawn reserve is a documented future hardening (needs engine↔BFF reserve). **No `spawn_many` reserve-gate task in the Phase 5 build** — D3 is satisfied by Group A's metering fix + existing BFF infra. The coordinator SKILL (D4) must be transparent that Superpowers burns real credits and can hit the paywall.

### D4 — Coordinator skill: add the polling-fallback (H5)
The `coordinator` SKILL.md (Phase 5 Task 4) must include: "Results normally arrive together as one batch wake. If they don't arrive promptly (e.g. after a restart), call `subagent_batch_result(batch_id)` to collect — never block indefinitely." (Resolves the restart-hang risk.)

### D5 — Engine-first deploy + safe mapping (already noted)
`mapReasoningEffort("superpowers") → {superpowers:true, effort:"high"}` MUST cover every consumer so the provider never sees "superpowers" raw (else 400). An un-upgraded engine maps unknown effort → default (safe, feature-inert). Ship engine before FE.

### D6 — Coordinator reliability = product-accepted
Prompt-driven fan-out isn't guaranteed (the model may answer directly for small tasks — by design per the skill). Acceptable; the verify step confirms fan-out fires on genuinely-parallel asks.

---

## Revised build order (high confidence after these)

1. **Phase 4** (fan-out primitives) + H1–H8 hardening.
2. **Subagent metering fix** (real token billing — money-critical).
3. **Phase 5** (Superpowers: toggle + coordinator + gate + D3 reserve gate → hard cut → #51 card).

Each: subagent-driven, review gates + holistic review, CI green (incl. linux+postgres), staging-first, prod `values.yaml` untouched.
