# Subagent Pass (Phases 1–3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make async subagent returns reliable and automatic (push, not poll), carry structured metadata back to the parent, and let subagents produce user-visible artifacts — fixing the three reported gaps.

**Architecture:** Layer onto the *existing* delivery path. `completeTask()` already appends the result to the parent session history + SSE in tenant mode; we (1) persist the result durably **before** delivering and **wake the parent's turn** via the existing `heartbeat_wake` queue, idempotent on `task_id` and recoverable after restart; (2) replace the text-only `result` with a structured `SubagentResult`; (3) give subagents the `artifact_create`/`produce_document` tools and carry the resulting `ArtifactRef`s back in the completion so the parent re-surfaces them. Durability mirrors the P0-4 `pending_approvals` Postgres pattern verbatim.

**Tech Stack:** Zig; libpq via `zaki_state.zig` (`buildQuery` + `execParams`, schema-per-tenant, `user_id` column); embedded SQL migrations (`src/migrations.zig`); thread-local tool observer (`observability.zig`); `heartbeat_wake.zig` async-turn wake queue; tests via `zig build test` (inline `test "..."` blocks, `-Dtest-filter=`).

**Spec:** `/Users/nova/Desktop/zaki-infra/docs/saas-v1/SPEC-2026-06-13-subagent-pass.md`

**Scope guard:** Phases 1–3 ONLY. Phase 4 (fan-out / `spawn_many` + per-tenant bounds) is a SEPARATE plan written after 1–3 validate on staging. Do NOT build fan-out here. Prod overlay (`charts/nullalis/values.yaml` in zaki-infra) stays untouched.

---

## Grounding facts (verified by recon — re-verify exact line numbers before editing; files drift)

- `src/subagent.zig`
  - `TaskState` struct ~L39–53; `result: ?[]const u8 = null` ~L48; `error_msg` ~L49; `status` ~L40; parent linkage `session_key`/`runtime_session_key`/`origin_channel`/`origin_chat_id` ~L44–47.
  - `SubagentManager` struct ~L95–167; fields `tasks: AutoHashMapUnmanaged(u64,*TaskState)`, `mutex`, `allocator`, `bus: ?*bus_mod.Bus`, `config_ref: *const config_mod.Config`, `ledger_state_mgr: ?*zaki_state.Manager`, `ledger_user_id: ?i64`, `completion_delivery: ?CompletionDeliveryFn`, `completion_delivery_ctx: ?*anyopaque`, `task_delivery: ?*tasks_mod.TaskDelivery`.
  - `CompletionDeliveryFn` ~L102–106: `*const fn (ctx: ?*anyopaque, session_key: []const u8, content: []const u8) anyerror!void`.
  - `spawn()` ~L273–379 (returns `u64` task_id; OS thread `subagentThreadFn`).
  - `getTaskResult()` ~L390–397 (mutex read of `state.result` — the manual query path; KEEP).
  - `completeTask()` ~L636–833 (dupes result into `self.allocator`; precedence `completion_delivery` then `bus`; delivery outside lock).
  - `subagentThreadFn` ~L911; result freed ~L1007; `parseUserIdFromSessionKey` referenced ~L1084.
  - Existing tests from ~L1227 (`test "SubagentManager init and deinit"`).
- `src/zaki_state.zig` — P0-4 template: `PendingApprovalInput` ~L518–536, `PendingApprovalRow` ~L538–558, `upsertPendingApproval` ~L10285–10340, load ~L10348–10397, resolve ~L10404–10429, status lookup ~L10435–10452; helpers `buildQuery` ~L11645, `execParams` ~L11791; `ensureUserRow` chokepoint; pool shared, `user_id BIGINT REFERENCES {schema}.users(user_id)`.
- `src/migrations.zig` — `MIGRATIONS` array ~L79–137; entries `0001`…`0006` seen (`0002_artifacts`, `0004_turn_usage`, `0005_pending_approvals`). **Next free version = highest existing + 1 (recon saw 0006; verify).** Idempotency test `assertGuardedDdl` ~L527.
- `src/migrations/` — `NNNN_name.sql`, `{schema}` placeholder, `IF NOT EXISTS` mandatory, `@embedFile`.
- `src/heartbeat_wake.zig` — `enqueue(user_id_opt: ?[]const u8, reason: []const u8) !void` ~L58; `dequeue()` ~L95. Drained by heartbeat thread `daemon.zig` ~L1174 → `runTenantHeartbeatSweep(..., reason, /*forced=*/true, ...)` → `processMessageWithContext(session_key, prompt, ...)` (`session.zig` ~L999, the turn entry).
- `src/tools/root.zig` — `subagentTools()` ~L2590–2634 (3-step create→init→append per tool; opts `http_enabled`, `allowed_paths`, `policy`); `getToolObserver()`/`setToolObserver()` ~L1928 (thread-local `current_tool_observer`); full set `allTools()` ~L1155 includes `artifact_create` + `produce_document`.
- `src/tools/artifact_create.zig` — emits `ObserverEvent{ .artifact_event = .{ op, artifact_id, title, kind, version, url } }` via `root.getToolObserver().?.recordEvent(&evt)` ~L129–145; persists to `artifacts`/`artifact_versions` (migration `0002`).
- `src/tools/produce_document.zig` — `ProduceDocumentTool{ workspace_dir, branding }`; renders pdf/docx/xlsx/pptx/html files (no event).
- `src/observability.zig` — `ObserverEvent.artifact_event` fields ~L180–189; `Observer{ ptr, record_event }` vtable ~L532–538.
- `build.zig` — `zig build test` ~L687; PG-backed step `agent_pg_tests`; `task_lifecycle_tests`; `-Dtest-filter="..."` ~L313.

---

## File structure (created / modified)

**Created:**
- `src/migrations/0007_subagent_results.sql` — durable completion outbox table (verify number).
- `src/subagent_result.zig` — `SubagentResult` + `ArtifactRef` types + JSON (de)serialize + `ArtifactCollector` observer. Keeps `subagent.zig` focused; one clear responsibility (the result value object + its capture).

**Modified:**
- `src/migrations.zig` — register `0007`.
- `src/zaki_state.zig` — `SubagentResultInput`/`SubagentResultRow` + `upsertSubagentResult`/`loadPendingSubagentResults`/`markSubagentResultDelivered`/`subagentResultStatus` (mirror P0-4).
- `src/subagent.zig` — `TaskState.result` type → `?SubagentResult`; persist+wake+idempotent-deliver in `completeTask()`; collector observer in `subagentThreadFn`; startup recovery; `getTaskResult()` signature follow-through.
- `src/tools/root.zig` — add `artifact_create` + `produce_document` to `subagentTools()`.
- (zaki-infra) `charts/nullalis/values-staging.yaml` — bump `image.tag` at deploy (NOT values.yaml).

---

# PHASE 1 — Push + durable completion (the keystone)

Fixes the #1 reported bug ("the parent needs a scheduled job to check completions"). After this phase the parent is **woken automatically** when a subagent finishes, and a completion **survives a pod restart**.

> Phase-1 note: `SubagentResult` (Phase 2) does not exist yet. To keep tasks independently committable, Phase 1 persists/delivers the existing **text** result and a minimal status, storing the text in `result_json` as `{"status":"...","text":"..."}`. Phase 2 swaps the payload to the full struct without changing the table or the wake path.

### Task 1.1: Durable `subagent_results` table

**Files:**
- Create: `src/migrations/0007_subagent_results.sql`
- Modify: `src/migrations.zig` (register in `MIGRATIONS`)
- Test: inline in `src/migrations.zig` (the existing `assertGuardedDdl` loop already covers new entries)

- [ ] **Step 1: Verify the next free migration version**

Run: `grep -nE '\.version = [0-9]+' src/migrations.zig | tail -5`
Expected: highest is `6`. Use `7`. If higher, use highest+1 and rename the file accordingly.

- [ ] **Step 2: Write the migration SQL**

Create `src/migrations/0007_subagent_results.sql`:

```sql
-- Durable outbox for subagent completions (Subagent Pass Phase 1).
-- Mirrors the pending_approvals durability pattern: schema-per-tenant, user_id FK,
-- status ledger, idempotent on (user_id, task_id). A row is written BEFORE the parent
-- is woken; status flips pending -> delivered once the parent has been notified, so a
-- crash between persist and deliver is recovered by re-delivering 'pending' rows.
CREATE TABLE IF NOT EXISTS {schema}.subagent_results (
    result_id    TEXT PRIMARY KEY,           -- formatted "subagent:<task_id>"
    user_id      BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    session_key  TEXT NOT NULL,              -- parent session to wake/deliver to
    task_id      BIGINT NOT NULL,            -- numeric subagent task id
    status       TEXT NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'delivered')),
    result_json  TEXT NOT NULL,              -- serialized SubagentResult (Phase 2); {status,text} in Phase 1
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    delivered_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_subagent_results_idem
    ON {schema}.subagent_results (user_id, task_id);

CREATE INDEX IF NOT EXISTS idx_subagent_results_recover
    ON {schema}.subagent_results (session_key)
    WHERE status = 'pending';
```

- [ ] **Step 3: Register the migration**

In `src/migrations.zig`, append to the `MIGRATIONS` array (after the highest existing entry), matching the existing entry style:

```zig
    .{
        .version = 7,
        .name = "0007_subagent_results",
        .sql = @embedFile("migrations/0007_subagent_results.sql"),
    },
```

- [ ] **Step 4: Run the idempotency + build test**

Run: `zig build test -Dtest-filter="idempotently re-appliable"`
Expected: PASS (the existing `assertGuardedDdl` loop now also validates `0007`; all DDL is `IF NOT EXISTS`-guarded).

- [ ] **Step 5: Commit**

```bash
git add src/migrations/0007_subagent_results.sql src/migrations.zig
git commit -m "feat(subagent): durable subagent_results outbox table (Phase 1)"
```

---

### Task 1.2: Postgres APIs for `subagent_results` (mirror P0-4)

**Files:**
- Modify: `src/zaki_state.zig` (structs near `PendingApprovalInput` ~L518; functions near `upsertPendingApproval` ~L10285)
- Test: inline `test "..."` in `src/zaki_state.zig`, run via `agent_pg_tests`

- [ ] **Step 1: Write the failing test**

Add near the other PG tests in `src/zaki_state.zig` (these run only when a test Postgres is configured, same as existing approval tests — mirror an existing `pending_approvals` test's guard/skip prelude exactly):

```zig
test "subagent_results upsert is idempotent and loads pending" {
    var mgr = (try testManagerOrSkip()) orelse return; // mirror existing PG-test skip helper
    defer mgr.deinit();
    try mgr.ensureUserRow(42);

    const input = SubagentResultInput{
        .result_id = "subagent:7",
        .user_id = 42,
        .session_key = "agent:zaki-bot:user:42:main",
        .task_id = 7,
        .result_json = "{\"status\":\"completed\",\"text\":\"done\"}",
    };
    try mgr.upsertSubagentResult(input);
    try mgr.upsertSubagentResult(input); // second write must be a no-op (ON CONFLICT DO NOTHING)

    var rows = try mgr.loadPendingSubagentResults(std.testing.allocator, 42);
    defer { for (rows) |*r| r.deinit(std.testing.allocator); std.testing.allocator.free(rows); }
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 7), rows[0].task_id);

    try mgr.markSubagentResultDelivered("subagent:7");
    var rows2 = try mgr.loadPendingSubagentResults(std.testing.allocator, 42);
    defer std.testing.allocator.free(rows2);
    try std.testing.expectEqual(@as(usize, 0), rows2.len); // delivered → no longer pending
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test -Dtest-filter="subagent_results upsert"`
Expected: FAIL — `SubagentResultInput`/`upsertSubagentResult` undefined.

- [ ] **Step 3: Add the structs**

Near `PendingApprovalInput`/`PendingApprovalRow` (~L518–558) in `src/zaki_state.zig`:

```zig
/// Borrowed-slice input for upsertSubagentResult (caller owns the memory).
pub const SubagentResultInput = struct {
    result_id: []const u8,
    user_id: i64,
    session_key: []const u8,
    task_id: i64,
    result_json: []const u8,
};

/// Owned-slice row rehydrated from subagent_results. Call deinit() to free.
pub const SubagentResultRow = struct {
    result_id: []const u8,
    session_key: []const u8,
    task_id: i64,
    result_json: []const u8,

    pub fn deinit(self: *SubagentResultRow, allocator: std.mem.Allocator) void {
        allocator.free(self.result_id);
        allocator.free(self.session_key);
        allocator.free(self.result_json);
    }
};
```

- [ ] **Step 4: Add the API functions**

Near `upsertPendingApproval` (~L10285) in `src/zaki_state.zig`, mirroring its `buildQuery`+`dupeZ`+`execParams` idiom exactly:

```zig
pub fn upsertSubagentResult(self: *Self, row: SubagentResultInput) !void {
    try self.ensureUserRow(row.user_id);
    const q = try self.buildQuery(
        "INSERT INTO {schema}.subagent_results " ++
            "(result_id, user_id, session_key, task_id, result_json, status) " ++
            "VALUES ($1, $2, $3, $4, $5, 'pending') " ++
            "ON CONFLICT (result_id) DO NOTHING",
    );
    defer self.allocator.free(q);

    var user_buf: [32]u8 = undefined;
    const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{row.user_id});
    var task_buf: [32]u8 = undefined;
    const task_s = try std.fmt.bufPrintZ(&task_buf, "{d}", .{row.task_id});
    const id_z = try self.allocator.dupeZ(u8, row.result_id);
    defer self.allocator.free(id_z);
    const session_z = try self.allocator.dupeZ(u8, row.session_key);
    defer self.allocator.free(session_z);
    const json_z = try self.allocator.dupeZ(u8, row.result_json);
    defer self.allocator.free(json_z);

    const params = [_]?[*:0]const u8{ id_z.ptr, user_s.ptr, session_z.ptr, task_s.ptr, json_z.ptr };
    const lengths = [_]c_int{
        @intCast(row.result_id.len), @intCast(user_s.len), @intCast(row.session_key.len),
        @intCast(task_s.len), @intCast(row.result_json.len),
    };
    const result = try self.execParams(q, &params, &lengths);
    c.PQclear(result);
}

pub fn loadPendingSubagentResults(self: *Self, allocator: std.mem.Allocator, user_id: i64) ![]SubagentResultRow {
    const q = try self.buildQuery(
        "SELECT result_id, session_key, task_id, result_json FROM {schema}.subagent_results " ++
            "WHERE user_id = $1 AND status = 'pending' ORDER BY created_at ASC",
    );
    defer self.allocator.free(q);
    var user_buf: [32]u8 = undefined;
    const user_s = try std.fmt.bufPrintZ(&user_buf, "{d}", .{user_id});
    const params = [_]?[*:0]const u8{user_s.ptr};
    const lengths = [_]c_int{@intCast(user_s.len)};
    const res = try self.execParams(q, &params, &lengths);
    defer c.PQclear(res);

    const n: usize = @intCast(c.PQntuples(res));
    var out = try std.ArrayList(SubagentResultRow).initCapacity(allocator, n);
    errdefer { for (out.items) |*r| r.deinit(allocator); out.deinit(allocator); }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ri: c_int = @intCast(i);
        const id = try allocator.dupe(u8, std.mem.span(c.PQgetvalue(res, ri, 0)));
        const sk = try allocator.dupe(u8, std.mem.span(c.PQgetvalue(res, ri, 1)));
        const tid = std.fmt.parseInt(i64, std.mem.span(c.PQgetvalue(res, ri, 2)), 10) catch 0;
        const rj = try allocator.dupe(u8, std.mem.span(c.PQgetvalue(res, ri, 3)));
        try out.append(allocator, .{ .result_id = id, .session_key = sk, .task_id = tid, .result_json = rj });
    }
    return out.toOwnedSlice(allocator);
}

pub fn markSubagentResultDelivered(self: *Self, result_id: []const u8) !void {
    const q = try self.buildQuery(
        "UPDATE {schema}.subagent_results SET status = 'delivered', delivered_at = NOW() " ++
            "WHERE result_id = $1 AND status = 'pending'",
    );
    defer self.allocator.free(q);
    const id_z = try self.allocator.dupeZ(u8, result_id);
    defer self.allocator.free(id_z);
    const params = [_]?[*:0]const u8{id_z.ptr};
    const lengths = [_]c_int{@intCast(result_id.len)};
    const result = try self.execParams(q, &params, &lengths);
    c.PQclear(result);
}
```

> Note: match the local `std.ArrayList` API version used elsewhere in `zaki_state.zig` (the codebase uses the unmanaged-style `append(allocator, x)` / `toOwnedSlice(allocator)` — confirm against a neighboring function and mirror it exactly). Use the same row-reading helpers (`PQgetvalue`/`PQntuples`) the existing load functions use.

- [ ] **Step 5: Run the test to verify it passes**

Run: `zig build test -Dtest-filter="subagent_results upsert"`
Expected: PASS (skips cleanly if no test Postgres; runs green where `agent_pg_tests` has a DB).

- [ ] **Step 6: Commit**

```bash
git add src/zaki_state.zig
git commit -m "feat(subagent): subagent_results PG APIs — upsert/load-pending/mark-delivered (Phase 1)"
```

---

### Task 1.3: Persist the result durably in `completeTask()` (before delivery)

**Files:**
- Modify: `src/subagent.zig` `completeTask()` ~L636–693 (inside the locked section, after `state.result`/`state.status` are set)
- Test: inline `test` in `src/subagent.zig`

- [ ] **Step 1: Write the failing test**

In `src/subagent.zig` near the existing subagent tests (~L1227). Use the test-only `completion_runner` hook the manager already exposes for the no-PG path; assert that completing a task records a durable row when a state manager is attached. If wiring a full PG manager in-test is heavy, assert the narrower invariant: `completeTask` calls `persistSubagentResultLocked` which formats `result_id = "subagent:<task_id>"`. Concretely test the helper:

```zig
test "formatSubagentResultId formats stable id" {
    var buf: [40]u8 = undefined;
    const id = try formatSubagentResultId(&buf, 7);
    try std.testing.expectEqualStrings("subagent:7", id);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test -Dtest-filter="formatSubagentResultId"`
Expected: FAIL — `formatSubagentResultId` undefined.

- [ ] **Step 3: Add the helper + persist call**

Add the helper near `formatCanonicalTaskId` in `src/subagent.zig`:

```zig
fn formatSubagentResultId(buf: []u8, task_id: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, "subagent:{d}", .{task_id});
}
```

Inside `completeTask()`, in the locked block right after `self.persistTaskSnapshotLocked(task_id, state);` (~L668), add a best-effort durable persist (Phase-1 minimal JSON; Phase 2 replaces the payload):

```zig
// Durable outbox: persist the completion BEFORE we wake/deliver, so a crash
// between persist and deliver is recovered (loadPendingSubagentResults on boot).
if (self.ledger_state_mgr) |sm| {
    if (state.session_key) |skey| {
        const uid = zaki_session.parseUserIdFromSessionKey(skey) catch null;
        if (uid) |user_id| {
            var idbuf: [40]u8 = undefined;
            const rid = formatSubagentResultId(&idbuf, task_id) catch null;
            if (rid) |result_id| {
                // Phase 1 payload: minimal {status,text}. Phase 2 swaps to full SubagentResult JSON.
                const status_str: []const u8 = if (state.status == .failed) "failed" else "completed";
                const text_src: []const u8 = state.result orelse (state.error_msg orelse "");
                const payload = std.json.Stringify.valueAlloc(self.allocator, .{
                    .status = status_str,
                    .text = text_src,
                }, .{}) catch null;
                if (payload) |pj| {
                    defer self.allocator.free(pj);
                    sm.upsertSubagentResult(.{
                        .result_id = result_id,
                        .user_id = user_id,
                        .session_key = skey,
                        .task_id = @intCast(task_id),
                        .result_json = pj,
                    }) catch |err| log.warn("subagent: durable persist failed task_id={d}: {}", .{ task_id, err });
                }
            }
        }
    }
}
```

> Verify: the JSON-stringify call must match the Zig std version in this tree (some use `std.json.stringifyAlloc`). Grep a neighboring JSON write in `subagent.zig`/`zaki_state.zig` and mirror it. Verify `zaki_session.parseUserIdFromSessionKey` import is in scope (referenced ~L1084) and its error/optional shape; adapt the `catch null` accordingly. Verify the manager field name (`ledger_state_mgr`) and that it is the `*zaki_state.Manager` carrying the PG APIs.

- [ ] **Step 4: Run the test + build**

Run: `zig build test -Dtest-filter="formatSubagentResultId"` then `zig build`
Expected: test PASS; build OK.

- [ ] **Step 5: Commit**

```bash
git add src/subagent.zig
git commit -m "feat(subagent): persist completion to durable outbox before delivery (Phase 1)"
```

---

### Task 1.4: Wake the parent on completion (push, not poll)

**Files:**
- Modify: `src/subagent.zig` `completeTask()` — after the delivery block (~L832, after both `completion_delivery` and `bus` branches), enqueue a wake.
- Test: inline `test` asserting wake enqueue happens for a completed task.

- [ ] **Step 1: Write the failing test**

`heartbeat_wake` has a global queue with `dequeue()`. Test that completing a task enqueues a wake for the parent's user. Mirror the existing subagent test setup (`SubagentManager.init`, then drive a completion through the test `completion_runner`/`completeTask`), then:

```zig
test "completeTask enqueues a heartbeat wake for the parent user" {
    // ... set up mgr with a task whose session_key = "agent:zaki-bot:user:42:main" ...
    // drive completion (use the same path the existing completion tests use)
    // then:
    const req = heartbeat_wake.dequeue();
    try std.testing.expect(req != null);
    defer { var m = req.?; m.deinit(); }
    try std.testing.expect(std.mem.indexOf(u8, req.?.reason, "subagent_completion") != null);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test -Dtest-filter="enqueues a heartbeat wake"`
Expected: FAIL — no wake enqueued.

- [ ] **Step 3: Add the wake enqueue**

At the end of `completeTask()` (after delivery, outside the lock), in `src/subagent.zig`:

```zig
// Push, not poll: wake the parent's turn so it processes the completion that we
// just appended to its session history. Reuses the heartbeat wake queue that the
// daemon already drains into processMessageWithContext (the turn entry point).
if (state_session_for_wake) |skey| {
    if (zaki_session.parseUserIdFromSessionKey(skey) catch null) |user_id| {
        var ubuf: [32]u8 = undefined;
        const uid_s = std.fmt.bufPrint(&ubuf, "{d}", .{user_id}) catch null;
        var rbuf: [64]u8 = undefined;
        const reason = std.fmt.bufPrint(&rbuf, "subagent_completion:{d}", .{task_id}) catch "subagent_completion";
        heartbeat_wake.enqueue(uid_s, reason) catch |err|
            log.warn("subagent: wake enqueue failed task_id={d}: {}", .{ task_id, err });
    }
}
```

Capture `state_session_for_wake` inside the locked block alongside the existing `request_session_key` capture (~L672): `const state_session_for_wake = state.session_key;` — hoist a copy to a `completeTask`-scope `var` so it is available after the lock (the existing code already hoists `request_session_key`; reuse that variable if it holds the session key). Ensure `heartbeat_wake` and `zaki_session` are imported at the top of `subagent.zig`.

> Threading note: `heartbeat_wake.enqueue` dupes into `std.heap.c_allocator` and is mutex-guarded — safe to call from the subagent thread. Do NOT call `processMessageWithContext` directly from the subagent thread (it locks the parent session and would run the parent turn on the subagent thread). The wake queue is the correct decoupled path.

- [ ] **Step 4: Verify the woken turn surfaces the completion**

The completion is already appended to the parent session history by the existing `completion_delivery` callback (`appendSubagentCompletionToGatewaySession`). Read how `runTenantHeartbeatForUser(forced=true)` builds its prompt (`daemon.zig` → `runCronAgentTurnWithBus` → `processMessageWithContext`). Confirm a forced heartbeat turn includes recent session history (so the agent sees the `[Subagent ... completed]` entry). If the heartbeat prompt does NOT nudge the agent to act on completions, add one clause to the forced-wake prompt when `reason` starts with `subagent_completion` (e.g. "A background subagent finished; review its result above and continue."). Keep this surgical.

Run: `zig build test -Dtest-filter="enqueues a heartbeat wake"` then `zig build`
Expected: test PASS; build OK.

- [ ] **Step 5: Commit**

```bash
git add src/subagent.zig
git commit -m "feat(subagent): wake parent turn on completion via heartbeat_wake (push not poll) (Phase 1)"
```

---

### Task 1.5: Idempotent delivery (redelivery = no-op) + mark delivered

**Files:**
- Modify: `src/subagent.zig` `completeTask()` delivery branch — after a successful deliver/wake, mark the durable row `delivered`.
- Modify: the delivery callback site OR the persist so re-delivery does not double-append history. Keep dedup keyed on `task_id`.
- Test: inline `test` — completing the same `task_id` twice does not enqueue two wakes / appends two history entries.

- [ ] **Step 1: Write the failing test**

```zig
test "duplicate completion of same task_id is idempotent (no double wake)" {
    // complete task_id=7 once → drain one wake
    // call the completion path for task_id=7 again
    // assert: second call does not enqueue a second wake (already delivered)
    // (drain queue; expect exactly one wake total across both calls)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test -Dtest-filter="duplicate completion of same task_id"`
Expected: FAIL — second completion enqueues a second wake.

- [ ] **Step 3: Implement idempotency**

Two layers (defense in depth):
1. **Outbox dedup** (already present): `upsertSubagentResult` uses `ON CONFLICT (result_id) DO NOTHING`, so persisting the same `task_id` twice writes one row.
2. **Deliver-once gate**: after a successful deliver+wake, call `markSubagentResultDelivered(result_id)`. Before delivering, check status — if already `delivered`, skip deliver+wake. Add a manager helper:

```zig
fn alreadyDeliveredLocked(self: *SubagentManager, result_id: []const u8) bool {
    const sm = self.ledger_state_mgr orelse return false;
    // status lookup: 'delivered' → true; 'pending'/absent → false
    return sm.subagentResultStatusIsDelivered(result_id) catch false;
}
```

Add `subagentResultStatusIsDelivered` to `zaki_state.zig` (SELECT status WHERE result_id; return `std.mem.eql(u8, status, "delivered")`), mirroring the P0-4 `pendingApprovalStatus` lookup (~L10435). In `completeTask`, gate the deliver+wake on `!alreadyDeliveredLocked(result_id)`, and call `markSubagentResultDelivered` immediately after a successful deliver.

> The in-memory `tasks` map also guards this within a single process lifetime (a completed task transitions out of `running`); the durable status gate is what makes it correct across a restart-driven recovery re-delivery.

- [ ] **Step 4: Run the test + build**

Run: `zig build test -Dtest-filter="duplicate completion of same task_id"` then `zig build`
Expected: PASS; build OK.

- [ ] **Step 5: Commit**

```bash
git add src/subagent.zig src/zaki_state.zig
git commit -m "feat(subagent): deliver-once idempotency gate on durable status (Phase 1)"
```

---

### Task 1.6: Startup recovery — re-deliver completions that survived a restart

**Files:**
- Modify: the engine boot path that constructs the `SubagentManager` per tenant (find where `ledger_state_mgr`/`ledger_user_id` are attached — grep `attachCompletionDelivery` / `ledger_state_mgr =`). Add a recovery sweep that loads `pending` rows and re-delivers+wakes.
- Test: inline `test` — a `pending` row present at init triggers a re-delivery+wake.

- [ ] **Step 1: Write the failing test**

```zig
test "recoverPendingSubagentResults re-delivers and wakes for pending rows" {
    // seed a pending row (via upsertSubagentResult, status pending)
    // call mgr.recoverPendingSubagentResults(user_id)
    // assert: a wake was enqueued for that user AND the row is now marked delivered
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test -Dtest-filter="recoverPendingSubagentResults"`
Expected: FAIL — function undefined.

- [ ] **Step 3: Implement recovery**

Add to `SubagentManager` in `src/subagent.zig`:

```zig
/// Re-deliver completions that were persisted but not confirmed-delivered before a
/// restart. Idempotent: re-delivery is safe because the parent dedups on task_id and
/// we mark each row delivered after waking. Best-effort; logs and continues on error.
pub fn recoverPendingSubagentResults(self: *SubagentManager, user_id: i64) void {
    const sm = self.ledger_state_mgr orelse return;
    const rows = sm.loadPendingSubagentResults(self.allocator, user_id) catch |err| {
        log.warn("subagent: recovery load failed user_id={d}: {}", .{ user_id, err });
        return;
    };
    defer { for (rows) |*r| r.deinit(self.allocator); self.allocator.free(rows); }
    for (rows) |row| {
        // Re-deliver to the parent session history via the same callback, then wake.
        if (self.completion_delivery) |delivery| {
            const content = std.fmt.allocPrint(self.allocator,
                "[Subagent task_id={d} completed — recovered after restart]", .{row.task_id}) catch continue;
            defer self.allocator.free(content);
            delivery(self.completion_delivery_ctx, row.session_key, content) catch {};
        }
        var ubuf: [32]u8 = undefined;
        const uid_s = std.fmt.bufPrint(&ubuf, "{d}", .{user_id}) catch null;
        heartbeat_wake.enqueue(uid_s, "subagent_completion:recovered") catch {};
        sm.markSubagentResultDelivered(row.result_id) catch {};
    }
}
```

Call `recoverPendingSubagentResults(ledger_user_id)` once at the point where the per-tenant manager is initialized with its `ledger_state_mgr` + `ledger_user_id` (the same place `attachCompletionDelivery` is wired). Guard with `if (self.ledger_user_id) |uid| self.recoverPendingSubagentResults(uid);`.

> The Phase-1 recovery content is a minimal marker; Phase 2 will re-hydrate the full `SubagentResult` text from `result_json` so the recovered turn carries the actual answer. That is fine — recovery's job is to guarantee the parent is woken; the full result is also already in session history from the pre-crash append in the common case.

- [ ] **Step 4: Run the test + build**

Run: `zig build test -Dtest-filter="recoverPendingSubagentResults"` then `zig build`
Expected: PASS; build OK.

- [ ] **Step 5: Commit**

```bash
git add src/subagent.zig
git commit -m "feat(subagent): startup recovery re-delivers pending completions after restart (Phase 1)"
```

---

# PHASE 2 — Structured metadata (replace text-only `result`)

Fixes "no metadata shared with the main agent." Introduces `SubagentResult` and threads it through the durable row + delivery. No table change (reuses `result_json`).

### Task 2.1: `SubagentResult` + `ArtifactRef` types with JSON round-trip

**Files:**
- Create: `src/subagent_result.zig`
- Test: inline `test` in `src/subagent_result.zig`

- [ ] **Step 1: Write the failing test**

In `src/subagent_result.zig`:

```zig
const std = @import("std");

test "SubagentResult round-trips through JSON" {
    const a = std.testing.allocator;
    const original = SubagentResult{
        .status = .completed,
        .text = "the answer",
        .artifacts = &.{.{ .id = "art_1", .kind = "markdown", .title = "Report", .url = "/api/v1/artifacts/art_1", .version = 1 }},
        .tokens = 1234,
        .turns = 3,
        .tools_used = &.{ "shell", "produce_document" },
        .err = null,
        .duration_ms = 4200,
    };
    const json = try original.toJsonAlloc(a);
    defer a.free(json);
    var parsed = try SubagentResult.fromJsonAlloc(a, json);
    defer parsed.deinit(a);
    try std.testing.expectEqual(Status.completed, parsed.value.status);
    try std.testing.expectEqualStrings("the answer", parsed.value.text);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.artifacts.len);
    try std.testing.expectEqualStrings("art_1", parsed.value.artifacts[0].id);
    try std.testing.expectEqual(@as(u64, 1234), parsed.value.tokens);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test -Dtest-filter="SubagentResult round-trips"`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement the types**

In `src/subagent_result.zig`:

```zig
pub const Status = enum { completed, failed, timeout };

pub const ArtifactRef = struct {
    id: []const u8,
    kind: []const u8,
    title: []const u8,
    url: []const u8,
    version: u64 = 1,
};

pub const SubagentResult = struct {
    status: Status,
    text: []const u8,
    artifacts: []const ArtifactRef = &.{},
    tokens: u64 = 0,
    turns: u32 = 0,
    tools_used: []const []const u8 = &.{},
    err: ?[]const u8 = null,
    duration_ms: u64 = 0,

    pub fn toJsonAlloc(self: SubagentResult, allocator: std.mem.Allocator) ![]u8 {
        // Mirror the JSON-write idiom already used in this codebase (verify std version).
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    pub const Parsed = struct {
        value: SubagentResult,
        arena: *std.heap.ArenaAllocator,
        pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };

    pub fn fromJsonAlloc(allocator: std.mem.Allocator, json: []const u8) !Parsed {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer { arena.deinit(); allocator.destroy(arena); }
        const parsed = try std.json.parseFromSliceLeaky(SubagentResult, arena.allocator(), json, .{ .ignore_unknown_fields = true });
        return .{ .value = parsed, .arena = arena };
    }
};
```

> Verify the std.json API names against the Zig version in this tree (`Stringify.valueAlloc` vs `stringifyAlloc`; `parseFromSliceLeaky` vs `parseFromSlice`). Mirror an existing parse/stringify call in `zaki_state.zig`. The enum must serialize as its tag name ("completed"); if the local std emits ints, add an explicit `jsonStringify`/`jsonParse` or map via strings.

- [ ] **Step 4: Run the test + build**

Run: `zig build test -Dtest-filter="SubagentResult round-trips"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/subagent_result.zig
git commit -m "feat(subagent): SubagentResult + ArtifactRef value types with JSON round-trip (Phase 2)"
```

---

### Task 2.2: Capture real metadata in the subagent loop

**Files:**
- Modify: `src/subagent.zig` `subagentThreadFn` (~L911) — accumulate `turns`, `tokens`, `tools_used`, `duration_ms` during the agent loop and pass them to `completeTask`.
- Modify: `completeTask` signature to accept a `SubagentResult` (or a metadata struct) instead of `?[]const u8`.
- Test: inline `test` — a completed task's `SubagentResult` carries non-zero turns/duration and the tools used.

- [ ] **Step 1: Write the failing test** — assert `completeTask` stores a `SubagentResult` whose `tools_used` includes a tool the subagent invoked and `turns >= 1`. (Drive via the existing test harness that runs a minimal subagent loop, or a focused unit that calls `completeTask` with a constructed `SubagentResult` and reads it back via `getTaskResult`.)

- [ ] **Step 2: Run it** → FAIL (`completeTask` still takes `?[]const u8`).

- [ ] **Step 3: Implement**
  - Change `TaskState.result: ?[]const u8` → `result: ?subagent_result.SubagentResult` (import `subagent_result`). Update `deinit`/free sites (the struct's slices are manager-owned; add a `freeSubagentResult(allocator, *SubagentResult)` helper and call it where `state.result` was freed at ~L661 and in manager `deinit` ~L211/419).
  - Change `completeTask(self, task_id, result: ?SubagentResult, err_msg: ?[]const u8)`. Where the thread currently produces the text result (~L1009), build a `SubagentResult{ .status=..., .text=<final answer>, .tokens=<loop tokens>, .turns=<loop turns>, .tools_used=<distinct names>, .duration_ms=now-started_at }`.
  - Find the loop's token/turn counters: grep the subagent agent-loop for the per-turn usage already recorded (Wave 2 added `turn_usage`/`usage_rt`); reuse those counters rather than inventing new ones. `tools_used` = distinct tool names observed by the collector observer (Task 3.2) — for Phase 2 you may collect names in the loop directly.
  - `completeTask` now serializes `result.toJsonAlloc` into the durable `result_json` (replacing the Phase-1 minimal `{status,text}`), and formats the delivery `content` from `result.text` (+ a one-line metadata footer: tokens/turns).

> This task changes a core type — compile the whole tree and fix every `state.result` reference. Expect touches in `getTaskResult` (returns the text or the struct — keep a `getTaskResultText` for the manual query path), `persistTaskSnapshotLocked`, and any serialization of `TaskState`.

- [ ] **Step 4: Run** `zig build test -Dtest-filter="subagent"` then `zig build` → PASS / build OK.

- [ ] **Step 5: Commit**

```bash
git add src/subagent.zig src/subagent_result.zig
git commit -m "feat(subagent): carry structured SubagentResult (status/tokens/turns/tools/duration) (Phase 2)"
```

---

### Task 2.3: Recovery re-hydrates the full result text

**Files:**
- Modify: `src/subagent.zig` `recoverPendingSubagentResults` — parse `row.result_json` into `SubagentResult` and deliver `result.text` (not the minimal marker).
- Test: inline `test` — a pending row with a full `SubagentResult` JSON re-delivers the actual text.

- [ ] **Step 1–2:** Write/assert the recovered delivery content contains the result text → run → FAIL.
- [ ] **Step 3:** In recovery, `var parsed = SubagentResult.fromJsonAlloc(self.allocator, row.result_json) catch continue; defer parsed.deinit(self.allocator);` and deliver `parsed.value.text`.
- [ ] **Step 4:** `zig build test -Dtest-filter="recover"` → PASS.
- [ ] **Step 5:** Commit `feat(subagent): recovery re-hydrates full result text from durable row (Phase 2)`.

---

# PHASE 3 — Artifact handoff

Fixes "the artifact tool is not available for him." Subagents can now produce user-visible artifacts; the `ArtifactRef`s ride back in `SubagentResult.artifacts` (already a field from Phase 2) and the parent re-surfaces them.

### Task 3.1: Add `artifact_create` + `produce_document` to `subagentTools()`

**Files:**
- Modify: `src/tools/root.zig` `subagentTools()` ~L2590–2634
- Test: inline `test` — `subagentTools()` returns a list whose tool names include `artifact_create` and `produce_document`.

- [ ] **Step 1: Write the failing test** (near `tools/root.zig` tests ~L2638):

```zig
test "subagentTools includes the artifact tools" {
    const tools = try subagentTools(std.testing.allocator, ".", .{});
    defer { for (tools) |t| t.deinit(std.testing.allocator); std.testing.allocator.free(tools); }
    var has_artifact = false;
    var has_doc = false;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name(), "artifact_create")) has_artifact = true;
        if (std.mem.eql(u8, t.name(), "produce_document")) has_doc = true;
    }
    try std.testing.expect(has_artifact);
    try std.testing.expect(has_doc);
}
```

> Verify the `Tool` name accessor (`t.name()` vs a `.name` field) against how existing `tools/root.zig` tests read a tool's name; mirror it.

- [ ] **Step 2: Run it** → FAIL (artifact tools absent).

- [ ] **Step 3: Add the tools** — in `subagentTools()`, before `return list.toOwnedSlice(allocator);`, append using the same create→init→append pattern (imports `artifact_create` and `produce_document` are already used by `allTools()` in the same file — reuse them):

```zig
    const act = try allocator.create(artifact_create.ArtifactCreateTool);
    act.* = .{ .workspace_dir = workspace_dir };
    try list.append(allocator, act.tool());

    const pdt = try allocator.create(produce_document.ProduceDocumentTool);
    pdt.* = .{ .workspace_dir = workspace_dir };
    try list.append(allocator, pdt.tool());
```

> Verify `ArtifactCreateTool`'s actual init fields by reading its struct in `src/tools/artifact_create.zig` (it may need more than `workspace_dir` — e.g. a state-manager/observer handle to persist; match exactly how `allTools()` constructs it ~L1155+ and copy that initializer verbatim). If `artifact_create` requires a PG/state handle that subagents don't have, fall back to `produce_document` only for Phase 3 and note it — but prefer wiring `artifact_create` since it is the user-visible canvas path.

- [ ] **Step 4: Run** `zig build test -Dtest-filter="subagentTools includes"` then `zig build` → PASS / OK.

- [ ] **Step 5: Commit** `feat(subagent): expose artifact_create + produce_document to subagents (Phase 3)`.

---

### Task 3.2: `ArtifactCollector` observer — capture subagent artifacts

**Files:**
- Create/extend: `src/subagent_result.zig` — add an `ArtifactCollector` that implements the `Observer` vtable and accumulates `ArtifactRef`s from `artifact_event`s.
- Modify: `src/subagent.zig` `subagentThreadFn` — install the collector as the thread-local observer for the subagent's loop; drain it into the `SubagentResult.artifacts` at completion.
- Test: inline `test` — recording an `artifact_event` into the collector yields one `ArtifactRef`.

- [ ] **Step 1: Write the failing test** in `src/subagent_result.zig`:

```zig
test "ArtifactCollector captures artifact_event into ArtifactRef" {
    const a = std.testing.allocator;
    var collector = ArtifactCollector.init(a);
    defer collector.deinit();
    const obs = collector.observer();
    const evt = observability.ObserverEvent{ .artifact_event = .{
        .op = "created", .artifact_id = "art_9", .title = "Doc", .kind = "markdown", .version = 1, .url = "/api/v1/artifacts/art_9",
    } };
    obs.recordEvent(&evt);
    const refs = collector.refs();
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("art_9", refs[0].id);
}
```

- [ ] **Step 2: Run it** → FAIL (`ArtifactCollector` undefined).

- [ ] **Step 3: Implement the collector**

In `src/subagent_result.zig` (add `const observability = @import("observability.zig");`):

```zig
pub const ArtifactCollector = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayListUnmanaged(ArtifactRef) = .{},
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) ArtifactCollector {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *ArtifactCollector) void {
        for (self.list.items) |r| {
            self.allocator.free(r.id); self.allocator.free(r.kind);
            self.allocator.free(r.title); self.allocator.free(r.url);
        }
        self.list.deinit(self.allocator);
    }
    pub fn observer(self: *ArtifactCollector) observability.Observer {
        return .{ .ptr = self, .record_event = recordEventThunk };
    }
    pub fn refs(self: *ArtifactCollector) []const ArtifactRef {
        return self.list.items;
    }
    fn recordEventThunk(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
        const self: *ArtifactCollector = @ptrCast(@alignCast(ptr));
        switch (event.*) {
            .artifact_event => |ae| {
                if (!std.mem.eql(u8, ae.op, "created") and !std.mem.eql(u8, ae.op, "updated")) return;
                self.mutex.lock();
                defer self.mutex.unlock();
                const ref = ArtifactRef{
                    .id = self.allocator.dupe(u8, ae.artifact_id) catch return,
                    .kind = self.allocator.dupe(u8, ae.kind) catch return,
                    .title = self.allocator.dupe(u8, ae.title) catch return,
                    .url = self.allocator.dupe(u8, ae.url) catch return,
                    .version = ae.version,
                };
                self.list.append(self.allocator, ref) catch {};
            },
            else => {},
        }
    }
};
```

> Verify the `Observer` struct shape (`ptr` + `record_event` fn pointer) and `ObserverEvent.artifact_event` field names against `observability.zig` (~L180, ~L532) and mirror exactly. If a real observer is already installed for the subagent thread (forwarding to the parent SSE), CHAIN rather than replace: have the collector hold the previous observer and forward each event to it after capturing, so nothing that already works breaks.

- [ ] **Step 4: Install + drain in the thread**

In `subagentThreadFn` (`src/subagent.zig` ~L911), before the agent loop:

```zig
var artifact_collector = subagent_result.ArtifactCollector.init(arena_or_manager_allocator);
defer artifact_collector.deinit();
const prev_obs = root_tools.getToolObserver();
root_tools.setToolObserver(&artifact_collector.observerChaining(prev_obs)); // chain if prev exists; else just collector
defer root_tools.setToolObserver(prev_obs);
```

After the loop, pass `artifact_collector.refs()` into the `SubagentResult` built for `completeTask` (dupe the refs into the manager allocator inside `completeTask`, consistent with how `text` is duped). Implement `observerChaining` (or, if simpler, set the collector directly when `prev_obs == null`, which is the common subagent case per recon).

- [ ] **Step 5: Run** `zig build test -Dtest-filter="ArtifactCollector"` then `zig build` → PASS / OK.

- [ ] **Step 6: Commit** `feat(subagent): ArtifactCollector observer captures subagent artifacts into SubagentResult (Phase 3)`.

---

### Task 3.3: Parent re-surfaces subagent artifacts on completion

**Files:**
- Modify: the parent-side completion consumption — when the woken parent turn processes a `subagent_completion`, re-emit each `ArtifactRef` as an `artifact_event` to the PARENT's (live) observer so the FE side panel shows it. Locate where the parent turn reads the completion (the delivery callback `appendSubagentCompletionToGatewaySession` in `gateway.zig`, or the heartbeat-forced turn) and emit there.
- Test: inline `test` — given a `SubagentResult` with one `ArtifactRef`, the re-surface path calls `recordEvent` once with a matching `artifact_event`.

- [ ] **Step 1: Write the failing test** — construct a fake parent observer that counts `artifact_event`s; call the new `resurfaceArtifacts(parent_observer, result)` helper; assert one event with `artifact_id == "art_1"`.

- [ ] **Step 2: Run it** → FAIL (`resurfaceArtifacts` undefined).

- [ ] **Step 3: Implement** a small helper (in `src/subagent_result.zig`):

```zig
pub fn resurfaceArtifacts(obs: observability.Observer, result: SubagentResult) void {
    for (result.artifacts) |ref| {
        const evt = observability.ObserverEvent{ .artifact_event = .{
            .op = "created", .artifact_id = ref.id, .title = ref.title,
            .kind = ref.kind, .version = ref.version, .url = ref.url,
        } };
        obs.recordEvent(&evt);
    }
}
```

Wire it where the completion is delivered to the parent: in the delivery callback (`appendSubagentCompletionToGatewaySession`, `gateway.zig`) the result text is already appended; after that, parse the durable `result_json` (or pass the `SubagentResult` through) and call `resurfaceArtifacts(parent_live_observer, result)`. The parent live observer is the gateway's per-session SSE observer (the one the FE listens to) — grep how `gateway.zig` obtains the active run observer for the session and pass it.

> The artifacts are already persisted (the subagent's `artifact_create` wrote them to the `artifacts` table with the same `{schema}`/`user_id`), so re-emitting only the event makes them appear in the FE — no content re-upload. Confirm the artifact rows are visible to the parent's tenant (same schema/user) — subagents run under the parent's tenant, so they are.

- [ ] **Step 4: Run** `zig build test -Dtest-filter="resurface"` then `zig build` → PASS / OK.

- [ ] **Step 5: Commit** `feat(subagent): parent re-surfaces subagent artifacts to the FE on completion (Phase 3)`.

---

# Build, Deploy & Verify (staging)

> Holistic review + validation gates per the mission's standing preference. Prod overlay untouched.

- [ ] **B1 — Full test suite:** `zig build test` → all green (PG-backed tests run where `agent_pg_tests` has a DB; otherwise skip cleanly). Then `zig build` (release path the CI uses) → binary builds.
- [ ] **B2 — Holistic review:** dispatch a review over the full diff (all phase commits) — memory safety (every `dupe`/`allocPrint` has a matching free; the `SubagentResult` slice ownership across the durable row + delivery + re-surface), thread safety (collector mutex; wake from subagent thread), idempotency (redelivery + recovery do not double-wake/double-append), and prod-overlay isolation. Fix findings before deploy.
- [ ] **B3 — Push to main → CI image:** push the engine branch/PR to `main`; `deploy-zaki-runtime.yml` builds → smoke → promotes `sha-<commit>`. Capture the immutable tag.
- [ ] **B4 — Bump staging overlay ONLY:** in `zaki-infra`, set `charts/nullalis/values-staging.yaml` `image.tag: sha-<commit>` (do NOT touch `values.yaml`). Commit on the `staging` branch; let ArgoCD `staging-nullalis` sync.
- [ ] **B5 — Live verification on staging** (do-fra1-nova-cloud, ns `zaki`):
  - **P1 (push):** start a turn that spawns a subagent for a slow task; confirm the parent **auto-continues** with the result with NO `task_get` polling and NO scheduled job — watch logs for `subagent.delivery path=direct` followed by a `heartbeat_wake` dequeue + a forced turn that surfaces the result.
  - **P1 (durable/recovery):** spawn a subagent; while it runs, roll the pod (or kill it after the row is `pending`); confirm on restart the completion is re-delivered and the parent is woken (`recovered`), and the durable row ends `delivered`.
  - **P1 (idempotency):** confirm no double history entry / double wake for one `task_id`.
  - **P2 (metadata):** confirm the completion the parent receives carries structured metadata (tokens/turns/tools), not just text — inspect the durable `result_json` and the parent-visible footer.
  - **P3 (artifact):** ask the agent to have a subagent produce a document; confirm the artifact appears in the FE side panel **after** the subagent finishes (parent re-surfaced it) and is downloadable/consumable.
- [ ] **B6 — Record results** in `zaki-infra/staging/AGENT-SPOKE-RESULTS.md` (proofs per check) and update the board: Phase 1–3 done → Phase 4 (fan-out) plan next.

---

## Self-review (run after writing; fix inline)

- **Spec coverage:** G1 push+durable → Tasks 1.1–1.6 ✓. G1 reliability/restart → 1.6 ✓. G2 structured metadata → 2.1–2.3 ✓. G3 artifact tool + handoff → 3.1–3.3 ✓. On-completion timing (not live) → parent re-surface in 3.3 ✓. delegate untouched ✓. Phase 4 explicitly excluded ✓.
- **Placeholders:** none — every step has real SQL/Zig/commands. Residual "verify against std version / exact field" notes are deliberate guardrails for code drift, not missing content; each names the exact thing to confirm and the neighbor to mirror.
- **Type consistency:** `SubagentResult`/`ArtifactRef`/`Status` defined in `src/subagent_result.zig` (Task 2.1) and used identically in 2.2/2.3/3.2/3.3; `subagent_results` columns defined in 1.1 and matched by the APIs in 1.2 and the persist in 1.3; `result_id = "subagent:<task_id>"` format consistent (1.3 helper, used by 1.2 idem + 1.5 gate + 1.6 recovery); `heartbeat_wake.enqueue(?[]const u8, []const u8)` used consistently in 1.4/1.6.
- **Ordering risk:** `TaskState.result` type changes from `?[]const u8` (Phase 1 still uses text via `result_json` minimal payload) to `?SubagentResult` in Task 2.2 — flagged in 2.2 as a tree-wide recompile; Phase 1 deliberately avoids depending on the struct so its tasks stay independently committable.
