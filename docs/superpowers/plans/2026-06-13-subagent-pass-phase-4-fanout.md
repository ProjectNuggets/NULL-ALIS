# Subagent Pass — Phase 4: Multi-Subagent Fan-Out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the main agent spawn MANY subagents at once and get one aggregated result when they all finish — `spawn_many` → barrier-collect → wake-once, with per-tenant bounds and survivors-on-partial-failure.

**Architecture:** Builds on the deployed Phase 1–3 machinery (durable push-completion, structured `SubagentResult`, per-tenant `SubagentManager`, `heartbeat_wake`). Adds (1) a `batch_id` tag on `TaskState` + an in-memory **batch tracker** in `SubagentManager`; (2) a `spawn_many` tool that fans out N tagged subagents under one capacity-checked batch; (3) a **barrier** in `completeTask` that suppresses per-task wakes for batched tasks and wakes the parent **once** when all N are terminal, delivering an aggregated result; (4) a **batch-deadline reaper** (modeled on the existing tenant-runtime maintenance thread) that marks stragglers `.timeout` so the barrier always completes. Partial failure falls out for free — the barrier waits for all N *terminal* (completed/failed/timeout) and returns survivors + errors.

**Tech Stack:** Zig; `src/subagent.zig` (SubagentManager + completeTask + thread); `src/subagent_result.zig` (SubagentResult); `src/tools/` (spawn_many, batch_result tools); `heartbeat_wake`; tests via `zig build test -Dtest-filter=...` (PG tests skip locally, validated on CI postgres profile).

**Spec:** `/Users/nova/Desktop/zaki-infra/docs/saas-v1/SPEC-2026-06-13-subagent-pass.md` §3.4.

**Scope guard:** Phase 4 only. Build on a fresh branch off `origin/main` (`b678ce00`). Prod `values.yaml` untouched; staging overlay only. Do NOT touch the Phase 1–3 single-spawn path except where explicitly noted (the barrier branch in `completeTask`).

---

## Grounding facts (verified by recon — re-verify exact lines; files drift)

- `SubagentManager.spawn(task, label, request_session_key, origin_channel, origin_chat_id) !u64` — `src/subagent.zig:359`. Concurrency cap `getRunningCountLocked() >= self.config.max_concurrent` (`max_concurrent=64`, per-tenant manager; `SubagentConfig` ~L71–95). Returns `task_id` (u64).
- `TaskState` ~`src/subagent.zig:52` — fields incl. `status`, `label`, `session_key`, `origin_channel`, `origin_chat_id`, `result: ?SubagentResult`, `error_msg`, `started_at`, `completed_at`, `thread`.
- `completeTask(self, task_id, result: ?SubagentResult, err_msg: ?[]const u8)` ~`src/subagent.zig:759` — single-lock terminal transition + durable upsert + Layer-A/B idempotency + delivery + `markSubagentResultDelivered` + **per-task** `heartbeat_wake.enqueue(uid, "subagent_completion:{task_id}")` ~L1067.
- `SubagentResult { status: enum{completed,failed,timeout}, text, artifacts, tokens, turns, tools_used, err, duration_ms }` — `src/subagent_result.zig:207`; `toJsonAlloc`/`fromJsonAlloc`.
- spawn tool — `src/tools/spawn.zig` (`tool_name "spawn"`, schema `{task,label}`). Registered default-on in `src/agent/commands.zig` (~L3404/3448/3503); EXCLUDED from `subagentTools()` (depth guard).
- `subagentThreadFn` ~`src/subagent.zig:1151` runs ONE `processMessageWithContext(...)`. **`SubagentConfig.max_iterations` is NOT wired into the loop** (vestigial; the subagent's single turn is already bounded by the agent's `max_tool_iterations`). So no new per-subagent *turn* cap is needed — the **batch deadline** is the straggler bound.
- Maintenance-thread reaper pattern: `pruneTenantRuntimeCache(state, now_s)` (`src/gateway.zig:2571`) + the dedicated maintenance thread (`gateway.zig:24717+`). Model the batch reaper on this (periodic sweep, shutdown-responsive).
- `getTaskResult`/`getTaskResultText` (`src/subagent.zig:476+`); `task_get` tool (`src/tools/task_get.zig`).

---

## File structure

**Created:**
- `src/subagent_batch.zig` — `BatchState` + `BatchTracker` (the in-memory batch registry; one clear responsibility: track which task_ids belong to a batch, their terminal status, the parent session_key, and the deadline; answer "are all terminal?"). Keeps `subagent.zig` from growing further.
- `src/tools/spawn_many.zig` — the `spawn_many` tool (fan-out N tagged subagents under one capacity-checked batch).
- `src/tools/subagent_batch_result.zig` — the `subagent_batch_result` tool (collect the N structured results on demand).

**Modified:**
- `src/subagent.zig` — `TaskState.batch_id`; `SubagentManager` holds a `BatchTracker`; `spawnInBatch()` variant (spawn() delegates with null); `completeTask` barrier branch; `reapBatchDeadlines()` + wire into a maintenance tick; aggregation accessor.
- `src/agent/commands.zig` — register `spawn_many` + `subagent_batch_result` tools (default-on; NOT in subagentTools).
- (zaki-infra) `charts/nullalis/values-staging.yaml` `image.tag` at deploy.

---

## Task 1 — `batch_id` on TaskState + the BatchTracker

**Files:**
- Create: `src/subagent_batch.zig`
- Modify: `src/subagent.zig` (`TaskState` + `SubagentManager` field)
- Test: inline in `src/subagent_batch.zig`

- [ ] **Step 1: Write the failing test** in `src/subagent_batch.zig`:

```zig
const std = @import("std");

test "BatchTracker registers tasks and detects all-terminal" {
    const a = std.testing.allocator;
    var bt = BatchTracker.init(a);
    defer bt.deinit();
    try bt.register("batch_1", &[_]u64{ 10, 11, 12 }, "agent:zaki-bot:user:42:main", 1000, 1000 + 60_000);
    try std.testing.expect(!bt.allTerminal("batch_1"));
    bt.markTerminal("batch_1", 10);
    bt.markTerminal("batch_1", 11);
    try std.testing.expect(!bt.allTerminal("batch_1"));
    bt.markTerminal("batch_1", 12);
    try std.testing.expect(bt.allTerminal("batch_1"));
    // wake-once guard
    try std.testing.expect(bt.tryClaimWake("batch_1"));   // first claim wins
    try std.testing.expect(!bt.tryClaimWake("batch_1"));   // second is a no-op
    const sk = bt.sessionKey("batch_1").?;
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:main", sk);
}

test "BatchTracker batchOf maps a task to its batch" {
    const a = std.testing.allocator;
    var bt = BatchTracker.init(a);
    defer bt.deinit();
    try bt.register("b", &[_]u64{ 1, 2 }, "agent:zaki-bot:user:1:main", 0, 60_000);
    try std.testing.expectEqualStrings("b", bt.batchOf(2).?);
    try std.testing.expect(bt.batchOf(999) == null);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /Users/nova/.config/superpowers/worktrees/nullalis/subagent-pass && zig build test -Dtest-filter="BatchTracker"`
Expected: FAIL — types undefined. (First build on this branch may be slow; allow 900000 ms.)

- [ ] **Step 3: Implement `src/subagent_batch.zig`**

```zig
const std = @import("std");

/// One fan-out batch: the N task ids, their terminal status, the parent session
/// to wake, and the absolute wall-clock deadline. In-memory only (v1): individual
/// completions remain durable via subagent_results, so a mid-batch pod restart
/// degrades gracefully to per-task delivery via the existing recovery sweep.
pub const BatchState = struct {
    task_ids: []u64,                 // owned
    terminal: []bool,                // owned, parallel to task_ids
    session_key: []const u8,         // owned
    created_at_ms: i64,
    deadline_ms: i64,                // absolute (created_at + budget)
    wake_claimed: bool = false,

    fn allTerminal(self: *const BatchState) bool {
        for (self.terminal) |t| if (!t) return false;
        return true;
    }
};

pub const BatchTracker = struct {
    allocator: std.mem.Allocator,
    batches: std.StringHashMapUnmanaged(*BatchState) = .{},
    // task_id → owned batch_id (for O(1) batchOf lookup in completeTask)
    task_index: std.AutoHashMapUnmanaged(u64, []const u8) = .{},

    pub fn init(allocator: std.mem.Allocator) BatchTracker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BatchTracker) void {
        var it = self.batches.iterator();
        while (it.next()) |e| {
            const bs = e.value_ptr.*;
            self.allocator.free(bs.task_ids);
            self.allocator.free(bs.terminal);
            self.allocator.free(bs.session_key);
            self.allocator.destroy(bs);
            self.allocator.free(e.key_ptr.*);
        }
        self.batches.deinit(self.allocator);
        self.task_index.deinit(self.allocator);
    }

    pub fn register(self: *BatchTracker, batch_id: []const u8, task_ids: []const u64, session_key: []const u8, created_at_ms: i64, deadline_ms: i64) !void {
        const key = try self.allocator.dupe(u8, batch_id);
        errdefer self.allocator.free(key);
        const ids = try self.allocator.dupe(u64, task_ids);
        errdefer self.allocator.free(ids);
        const term = try self.allocator.alloc(bool, task_ids.len);
        errdefer self.allocator.free(term);
        @memset(term, false);
        const sk = try self.allocator.dupe(u8, session_key);
        errdefer self.allocator.free(sk);
        const bs = try self.allocator.create(BatchState);
        bs.* = .{ .task_ids = ids, .terminal = term, .session_key = sk, .created_at_ms = created_at_ms, .deadline_ms = deadline_ms };
        try self.batches.put(self.allocator, key, bs);
        for (task_ids) |tid| try self.task_index.put(self.allocator, tid, key);
    }

    pub fn batchOf(self: *BatchTracker, task_id: u64) ?[]const u8 {
        return self.task_index.get(task_id);
    }

    pub fn markTerminal(self: *BatchTracker, batch_id: []const u8, task_id: u64) void {
        const bs = self.batches.get(batch_id) orelse return;
        for (bs.task_ids, 0..) |tid, i| {
            if (tid == task_id) { bs.terminal[i] = true; return; }
        }
    }

    pub fn allTerminal(self: *BatchTracker, batch_id: []const u8) bool {
        const bs = self.batches.get(batch_id) orelse return false;
        return bs.allTerminal();
    }

    /// Wake-once guard: returns true exactly once per batch.
    pub fn tryClaimWake(self: *BatchTracker, batch_id: []const u8) bool {
        const bs = self.batches.get(batch_id) orelse return false;
        if (bs.wake_claimed) return false;
        bs.wake_claimed = true;
        return true;
    }

    pub fn sessionKey(self: *BatchTracker, batch_id: []const u8) ?[]const u8 {
        const bs = self.batches.get(batch_id) orelse return null;
        return bs.session_key;
    }

    pub fn taskIds(self: *BatchTracker, batch_id: []const u8) ?[]const u64 {
        const bs = self.batches.get(batch_id) orelse return null;
        return bs.task_ids;
    }

    /// For the reaper: batch ids whose deadline < now and not yet wake-claimed.
    pub fn overdueBatches(self: *BatchTracker, allocator: std.mem.Allocator, now_ms: i64) ![][]const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer out.deinit(allocator);
        var it = self.batches.iterator();
        while (it.next()) |e| {
            const bs = e.value_ptr.*;
            if (!bs.wake_claimed and now_ms >= bs.deadline_ms and !bs.allTerminal()) {
                try out.append(allocator, e.key_ptr.*);
            }
        }
        return out.toOwnedSlice(allocator);
    }
};
```

> Verify the `std.ArrayListUnmanaged`/`StringHashMapUnmanaged` idiom against neighboring code (the codebase uses unmanaged collections). The tracker is NOT internally locked — it is always called UNDER `SubagentManager.mutex` (Task 3/4 ensure this). Document that invariant in a doc-comment.

- [ ] **Step 4: Add `batch_id` to TaskState + a `BatchTracker` to SubagentManager**

In `src/subagent.zig`: add `batch_id: ?[]const u8 = null` to `TaskState` (owned; freed in the TaskState free path alongside `label`/`session_key` — find `freeTaskState`/`clearTasksLocked` and free it there). Add `const subagent_batch = @import("subagent_batch.zig");` and a field `batches: subagent_batch.BatchTracker` to `SubagentManager` (init in `SubagentManager.init`, deinit in `SubagentManager.deinit`).

- [ ] **Step 5: Run tests + build**

Run: `zig build test -Dtest-filter="BatchTracker"` → PASS; then `zig build` → clean.

- [ ] **Step 6: Commit**

```bash
git add src/subagent_batch.zig src/subagent.zig
git commit -m "feat(subagent): BatchTracker + TaskState.batch_id (Phase 4 fan-out scaffolding)"
```

---

## Task 2 — `spawnInBatch` + capacity check

**Files:**
- Modify: `src/subagent.zig` (`spawn` → delegate to `spawnInBatch`; add a batch-capacity helper)
- Test: inline in `src/subagent.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "spawnInBatch tags tasks with batch_id and registers the batch" {
    // construct a SubagentManager (mirror existing subagent test setup, null ledger/bus),
    // set config.max_concurrent small for the capacity test in Task 2 step 4.
    // call mgr.spawnInBatch(task, label, session_key, channel, chat_id, "batch_x")
    // assert: returned task_id's TaskState.batch_id == "batch_x"
    //         AND mgr.batches.batchOf(task_id).? == "batch_x"
}

test "remainingCapacity reflects max_concurrent minus running" {
    // with max_concurrent = N and k running, mgr.remainingCapacityLocked() == N - k
}
```

- [ ] **Step 2: Run → FAIL** (`spawnInBatch`/`remainingCapacityLocked` undefined).

- [ ] **Step 3: Implement**
- Rename the body of `spawn()` into `spawnInBatch(self, task, label, request_session_key, origin_channel, origin_chat_id, batch_id: ?[]const u8) !u64`; have `spawn(...)` call `return self.spawnInBatch(task, label, request_session_key, origin_channel, origin_chat_id, null);` (keeps all existing spawn-tool callers unchanged).
- In `spawnInBatch`, after the existing TaskState fields are set under the lock, set `state.batch_id = if (batch_id) |b| try self.allocator.dupe(u8, b) else null;` (free on the TaskState free path).
- Add `fn remainingCapacityLocked(self: *SubagentManager) u32 { const running = self.getRunningCountLocked(); return if (running >= self.config.max_concurrent) 0 else self.config.max_concurrent - running; }` (caller holds the mutex).

- [ ] **Step 4: Run tests + build** → PASS / clean.

- [ ] **Step 5: Commit**

```bash
git add src/subagent.zig
git commit -m "feat(subagent): spawnInBatch variant + remainingCapacityLocked (Phase 4)"
```

---

## Task 3 — `spawnMany` manager API + capacity-checked fan-out

**Files:**
- Modify: `src/subagent.zig` (add `spawnMany`)
- Test: inline in `src/subagent.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "spawnMany fans out N tasks under one batch within capacity" {
    // mgr with max_concurrent >= 3.
    // const res = try mgr.spawnMany(&[_]SpawnSpec{ .{.task="a",.label="la"}, .{.task="b",.label="lb"}, .{.task="c",.label="lc"} }, session_key, channel, chat_id, 60_000);
    // assert res.task_ids.len == 3; all three TaskStates share res.batch_id; tracker.taskIds(res.batch_id).len==3.
}

test "spawnMany rejects when N exceeds remaining capacity (all-or-nothing)" {
    // mgr with max_concurrent = 2; spawnMany of 3 → error.TooManyConcurrentSubagents; NO task spawned (count unchanged).
}
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** in `src/subagent.zig`:

```zig
pub const SpawnSpec = struct { task: []const u8, label: []const u8 };
pub const BatchHandle = struct { batch_id: []const u8, task_ids: []u64 }; // caller frees both via the manager allocator

/// Fan out N subagents under one batch. All-or-nothing on capacity: if N exceeds
/// remaining capacity, spawn nothing and return error.TooManyConcurrentSubagents.
/// budget_ms is the batch wall-clock deadline (relative to now).
pub fn spawnMany(self: *SubagentManager, specs: []const SpawnSpec, request_session_key: []const u8, origin_channel: []const u8, origin_chat_id: []const u8, budget_ms: i64) !BatchHandle {
    if (specs.len == 0) return error.EmptyBatch;
    const now = std.time.milliTimestamp();

    // Capacity check (all-or-nothing) under the lock.
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (specs.len > self.remainingCapacityLocked()) return error.TooManyConcurrentSubagents;
    }

    // Generate a batch id (reuse the manager's next_id counter under the lock for determinism).
    var idbuf: [48]u8 = undefined;
    const seq = blk: { self.mutex.lock(); defer self.mutex.unlock(); const s = self.next_id; break :blk s; };
    const batch_id_local = try std.fmt.bufPrint(&idbuf, "batch:{d}:{d}", .{ seq, now });

    var ids = std.ArrayListUnmanaged(u64){};
    errdefer ids.deinit(self.allocator);
    // Spawn each tagged with the batch id. (spawnInBatch re-checks per-call capacity; the
    // pre-check above makes the batch atomic in the common case. If a mid-loop spawn fails,
    // we still register the batch with the ids that DID spawn so the barrier can complete.)
    for (specs) |spec| {
        const tid = self.spawnInBatch(spec.task, spec.label, request_session_key, origin_channel, origin_chat_id, batch_id_local) catch break;
        try ids.append(self.allocator, tid);
    }
    if (ids.items.len == 0) return error.SpawnFailed;

    // Register the batch in the tracker (under the lock).
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.batches.register(batch_id_local, ids.items, request_session_key, now, now + budget_ms) catch |err| {
            log.warn("subagent: batch register failed: {}", .{err});
        };
    }

    const owned_batch_id = try self.allocator.dupe(u8, batch_id_local);
    return .{ .batch_id = owned_batch_id, .task_ids = try ids.toOwnedSlice(self.allocator) };
}
```

> Verify: `next_id` is the spawn counter (used for task ids); reusing it for the batch seq is fine (it monotonically increments). Confirm the lock discipline (register under the mutex, since the tracker isn't self-locked). The `SpawnSpec`/`BatchHandle` slices are manager-allocator-owned — the tool (Task 4) frees them after building its result.

- [ ] **Step 4: Run tests + build** → PASS / clean.

- [ ] **Step 5: Commit** `feat(subagent): spawnMany — capacity-checked batch fan-out (Phase 4)`.

---

## Task 4 — `spawn_many` tool

**Files:**
- Create: `src/tools/spawn_many.zig`
- Modify: `src/agent/commands.zig` (register default-on)
- Test: inline in `src/tools/spawn_many.zig`

- [ ] **Step 1: Write the failing test** — schema parse + that execute calls `manager.spawnMany` and returns `{batch_id, task_ids}` JSON (mirror `src/tools/spawn.zig`'s test if present; otherwise a focused parse test).

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** `src/tools/spawn_many.zig` mirroring `spawn.zig`'s structure (manager pointer, turn context for session_key/channel/chat_id):

```zig
// tool_name = "spawn_many"
// schema: {"type":"object","properties":{
//   "tasks":{"type":"array","minItems":1,"maxItems":8,"items":{"type":"object",
//     "properties":{"task":{"type":"string","minLength":1},"label":{"type":"string"}},"required":["task"]}},
//   "budget_seconds":{"type":"integer","description":"Batch wall-clock deadline; default 300, max 900"}},
//   "required":["tasks"]}
// execute(): parse tasks[] into []SpawnSpec (label defaults "subagent"); budget_ms = clamp(budget_seconds||300, 30, 900)*1000;
//   resolve session_key/channel/chat_id like spawn.zig; call manager.spawnMany(specs, session_key, channel, chat_id, budget_ms);
//   on error.TooManyConcurrentSubagents → ToolResult.fail("Too many concurrent subagents for this batch; spawn fewer or wait.");
//   success → JSON {"batch_id":"...","task_ids":[...],"count":N,"note":"Results will arrive together when all complete; or call subagent_batch_result."}
//   free the BatchHandle.batch_id + task_ids (manager allocator) after building output.
```

Provide the full Zig in implementation (mirror `spawn.zig` exactly for the manager-wiring, turn-context resolution, and ToolResult construction; cap `maxItems` at 8 to bound fan-out width).

- [ ] **Step 4: Register** in `src/agent/commands.zig` next to the `spawn` tool registration (default-on, main profile). DO NOT add to `subagentTools()` — subagents must not fan-out (depth guard). Mirror the `spawn_tool` wiring (`var spawn_many_tool = spawn_many_mod.SpawnManyTool{ .manager = &manager };`).

- [ ] **Step 5: Run tests + build** → PASS / clean.

- [ ] **Step 6: Commit** `feat(subagent): spawn_many tool — fan-out N subagents (Phase 4)`.

---

## Task 5 — Barrier wake-once in `completeTask`

**Files:**
- Modify: `src/subagent.zig` (`completeTask` wake section ~L1067)
- Test: inline in `src/subagent.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "batch barrier: per-task wakes suppressed; one wake when all terminal" {
    // mgr (null ledger). spawnMany 2 tasks → batch_id B (drain any wake from spawn).
    // drive completeTask for task 1 (a completed SubagentResult) → assert heartbeat_wake.dequeue() == null (suppressed; batch not done).
    // drive completeTask for task 2 → assert exactly ONE wake whose reason contains "subagent_batch_complete".
}
```

- [ ] **Step 2: Run → FAIL** (per-task wake still fires for batched tasks).

- [ ] **Step 3: Implement** — in `completeTask`, replace the unconditional per-task wake (~L1067) with batch-aware logic. Under the manager lock (where the tracker is safe to touch), after the task is marked terminal, determine the wake:

```zig
// Determine wake: batched tasks suppress per-task wake; the LAST terminal task in
// the batch claims a single batch wake. Non-batched tasks keep the per-task wake.
var batch_wake_id: ?[]const u8 = null;  // batch_id to wake, if this completion finished the batch
var emit_per_task_wake = true;
{
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.tasks.get(task_id)) |st| {
        if (st.batch_id) |bid| {
            emit_per_task_wake = false;                 // suppress per-task wake for batched tasks
            self.batches.markTerminal(bid, task_id);
            if (self.batches.allTerminal(bid) and self.batches.tryClaimWake(bid)) {
                batch_wake_id = bid;                    // points into tracker-owned memory; used immediately below
            }
        }
    }
}
if (emit_per_task_wake) {
    // EXISTING per-task wake (unchanged) — heartbeat_wake.enqueue(uid, "subagent_completion:{task_id}")
    ...
} else if (batch_wake_id) |bid| {
    if (zaki_session.parseUserIdFromSessionKey(request_session_key)) |uid_str| {
        var rbuf: [80]u8 = undefined;
        const reason = std.fmt.bufPrint(&rbuf, "subagent_batch_complete:{s}", .{bid}) catch "subagent_batch_complete";
        heartbeat_wake.enqueue(uid_str, reason) catch |err| log.warn("subagent: batch wake enqueue failed: {}", .{err});
    }
}
```

> The DURABLE per-task persist + delivery (Layer A/B + completion_delivery/bus + markDelivered) stays UNCHANGED — every task still durably records its own result; only the WAKE is batched. So the parent, when woken once, can collect all N via Task 6. Verify `batch_wake_id` is read while still valid (it points into tracker memory which lives until batch cleanup — safe within this function). Re-verify the exact structure of the existing wake block you're replacing.

- [ ] **Step 4: Run tests + build** → PASS / clean. Also run `-Dtest-filter="ubagent"` to confirm no Phase-1/2/3 regression (single-spawn per-task wake still fires for non-batched tasks).

- [ ] **Step 5: Commit** `feat(subagent): batch barrier — suppress per-task wakes, wake once when all terminal (Phase 4)`.

---

## Task 6 — `subagent_batch_result` aggregation tool

**Files:**
- Create: `src/tools/subagent_batch_result.zig`
- Modify: `src/subagent.zig` (add `getBatchResults`), `src/agent/commands.zig` (register)
- Test: inline

- [ ] **Step 1: Write the failing test** — `getBatchResults(allocator, batch_id)` returns one entry per task (task_id, status, text/err) including survivors + a `.timeout`; the tool serializes them to a JSON array.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement**
- `SubagentManager.getBatchResults(self, allocator, batch_id) ![]BatchResultEntry` where `BatchResultEntry = struct { task_id: u64, status: []const u8, text: []const u8, err: ?[]const u8 }`. Under the lock, for each task_id in `self.batches.taskIds(batch_id)`, read its `TaskState.status` + `.result`/`.error_msg`, dupe into `allocator`. (Survivors + errors + timeouts all included.)
- `src/tools/subagent_batch_result.zig`: tool_name `"subagent_batch_result"`, schema `{"type":"object","properties":{"batch_id":{"type":"string"}},"required":["batch_id"]}`; execute → `manager.getBatchResults` → JSON array `[{task_id,status,text,error?}]`. Free entries after.
- Register in `commands.zig` default-on (NOT subagentTools).

- [ ] **Step 4: Run tests + build** → PASS / clean.

- [ ] **Step 5: Commit** `feat(subagent): subagent_batch_result tool — collect N results (survivors+errors) (Phase 4)`.

---

## Task 7 — Batch-deadline reaper

**Files:**
- Modify: `src/subagent.zig` (`reapBatchDeadlines`) + wire into a periodic tick (the existing maintenance path)
- Test: inline

- [ ] **Step 1: Write the failing test**

```zig
test "reapBatchDeadlines marks still-running batch tasks timeout past the deadline" {
    // spawnMany 2 with a tiny budget; mark task 1 terminal; advance "now" past deadline;
    // call mgr.reapBatchDeadlines(now_past_deadline);
    // assert task 2 is now terminal (.timeout) AND the batch is all-terminal AND a batch wake was enqueued.
}
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** `reapBatchDeadlines(self, now_ms)`:
- `const overdue = self.batches.overdueBatches(self.allocator, now_ms)` (under lock; then release to call completeTask which re-locks). For each overdue batch, for each non-terminal task_id, call `self.completeTask(task_id, SubagentResult{ .status = .timeout, .text = "subagent exceeded batch deadline", .err = "batch_deadline_exceeded" }, null)`. completeTask marks it terminal + (via Task 5) the last one claims the batch wake. The still-running thread's eventual real completion is idempotent-skipped (Layer A). Free `overdue`.
- Wire a call to `reapBatchDeadlines(std.time.milliTimestamp())` into a periodic tick. PREFER hooking the existing tenant maintenance thread (`gateway.zig:24717+` / `pruneTenantRuntimeCache`) so no new thread is added — call `mgr.reapBatchDeadlines(now)` for each tenant's manager during the sweep. If the manager isn't reachable from that sweep, add a minimal shutdown-responsive ticker in `SubagentManager` modeled on the idle-reaper (verify the existing maintenance wiring before choosing).

> v1 limitation (document in code + the §results doc): the reaper marks the task `.timeout` for the barrier but does NOT forcibly kill the runaway OS thread (unsafe in Zig); the thread finishes on its own and its completion is idempotent-skipped. The concurrency slot frees when the thread exits. Acceptable for staging.

- [ ] **Step 4: Run tests + build** → PASS / clean.

- [ ] **Step 5: Commit** `feat(subagent): batch-deadline reaper — stragglers timeout so the barrier completes (Phase 4)`.

---

## Build, Deploy & Verify (staging)

- [ ] **B1 — Full suite:** `zig build test` → green (PG tests skip locally); `zig build` → clean.
- [ ] **B2 — Holistic review** of the whole Phase 4 diff: memory safety (BatchTracker dupes/frees; the BatchHandle ownership across spawnMany→tool; the barrier reads tracker memory under-lock); thread safety (tracker only touched under manager mutex; reaper re-locks via completeTask); no Phase-1/2/3 regression (non-batched single-spawn per-task wake unchanged); depth guard (spawn_many NOT in subagentTools); multi-tenant (batch confined to the spawning manager/tenant); the reaper's runaway-thread limitation documented.
- [ ] **B3 — PR → main → CI:** push the branch, open a PR; CI must be green incl. linux + postgres (run + watch); merge → image build → `sha-<commit>`.
- [ ] **B4 — Bump staging overlay ONLY:** `charts/nullalis/values-staging.yaml` `image.tag: sha-<commit>` (prod `values.yaml` untouched). Commit on `staging`; ArgoCD `staging-nullalis` syncs + rolls.
- [ ] **B5 — Live verify on staging:** ask the agent to fan out (e.g. "spawn 3 subagents to research X, Y, Z and report back together"); confirm in engine logs: 3 spawns under one `batch:` id, per-task wakes SUPPRESSED, ONE `subagent_batch_complete:<id>` wake, the parent collects all 3 results (survivors). Test partial failure (one task that errors) → batch still completes with survivors+error. Test the deadline (a slow task) → straggler `.timeout`, barrier completes.
- [ ] **B6 — Record** in `zaki-infra/staging/AGENT-SPOKE-RESULTS.md`; mark the subagent pass fully complete (Phases 1–4).

---

## Self-review

- **Spec §3.4 coverage:** barrier-collect (Task 5) ✓; `spawn_many` (Tasks 3–4) ✓; per-user cap = max_concurrent capacity check (Tasks 2–3) ✓; per-subagent budget — turn cap is inherent (max_tool_iterations; documented), batch deadline (Task 7) ✓, token budget DEFERRED (noted) ✓; batch deadline → timeout (Task 7) ✓; survivors+errors (Tasks 5–6, completeTask per-task handling unchanged) ✓; depth guard (spawn_many excluded from subagentTools, Task 4) ✓.
- **Placeholders:** the tool files (Tasks 4, 6) say "mirror spawn.zig" + give the schema/behavior rather than the full byte-for-byte Zig — the executor MUST produce the complete tool code by mirroring the existing `spawn.zig`/`task_get.zig` structure (manager wiring, turn-context, ToolResult). This is the one place full code is deferred to the executor against a concrete in-repo template; flagged here intentionally.
- **Type consistency:** `BatchTracker` API (register/batchOf/markTerminal/allTerminal/tryClaimWake/sessionKey/taskIds/overdueBatches) used consistently across Tasks 1/3/5/6/7; `SpawnSpec`/`BatchHandle`/`BatchResultEntry` defined in subagent.zig and consumed by the tools; `spawnInBatch`/`spawnMany`/`getBatchResults`/`reapBatchDeadlines` signatures stable.
- **Ordering:** Task 5 (barrier) depends on Task 1 (tracker) + Task 3 (spawnMany registers batches). Task 7 (reaper) depends on Task 5 (the barrier wake it triggers). Sequenced correctly.
