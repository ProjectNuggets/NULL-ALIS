//! v1.14.18 Step 7 (V4) — subagent → task-ledger lifecycle integration.
//!
//! The per-module unit tests in `subagent.zig` already pin the bridge
//! mechanics against a hand-built `TaskDelivery`. This satellite test pins
//! the *cross-module contract* the V4 fix delivers: that a `SubagentManager`
//! constructed the way the standalone CLI / channel-loop paths construct it
//! — with no explicit `attachTaskDelivery` — still mirrors a spawned
//! subagent's full lifecycle into a real `TaskLedger`.
//!
//!   1. spawn → the canonical ledger gains a `task_<id>` entry.
//!   2. completion → that ledger entry transitions to `succeeded`.
//!   3. failure path → the ledger entry transitions to `failed`.
//!
//! Pre-V4 the default `task_delivery` was null and steps 1–3 produced an
//! empty ledger for these construction paths. The test fails loudly if the
//! bridge ever regresses back to opt-in.
//!
//! No backend, no postgres — the default bridge is a pure in-memory ledger.
//! Runs under every engine profile.

const std = @import("std");
const nullalis = @import("nullalis");

const subagent = nullalis.subagent;
const tasks = nullalis.tasks;
const config_mod = nullalis.config;

const SubagentManager = subagent.SubagentManager;

/// Completion runner that succeeds immediately, echoing the task text.
fn okRunner(_: ?*anyopaque, allocator: std.mem.Allocator, system_prompt: []const u8, task: []const u8) ![]const u8 {
    try std.testing.expect(system_prompt.len > 0);
    return std.fmt.allocPrint(allocator, "done: {s}", .{task});
}

/// Completion runner that fails — drives the failed-status branch.
fn failRunner(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) ![]const u8 {
    return error.SubagentRunnerFailure;
}

fn waitForSubagentTerminal(mgr: *SubagentManager, task_id: u64, timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        const status = mgr.getTaskStatus(task_id) orelse return error.TestUnexpectedResult;
        switch (status) {
            .completed, .failed, .cancelled => return,
            else => std.Thread.sleep(1 * std.time.ns_per_ms),
        }
    }
    return error.TestTimeout;
}

fn canonicalIdSlice(buf: *[tasks.ledger.TASK_ID_LEN]u8, task_id: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, "task_{x:0>11}", .{task_id});
}

test "V4: subagent spawn → default ledger bridge → succeeded round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/nullalis-task-lifecycle/config.json",
        .allocator = std.testing.allocator,
    };

    // Construct the manager the standalone way — no attachTaskDelivery.
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.completion_runner = okRunner;
    defer mgr.deinit();

    // V4 contract: the bridge is wired by default (manager-owned fallback).
    const delivery = mgr.task_delivery orelse return error.TestUnexpectedResult;

    const task_id = try mgr.spawn("summarize the changelog", "lifecycle", "session:lc", "agent", "session:lc");

    // Step 1 — the ledger gained an entry the instant spawn returned.
    var id_buf: [tasks.ledger.TASK_ID_LEN]u8 = undefined;
    const id_slice = try canonicalIdSlice(&id_buf, task_id);
    {
        const entry = delivery.ledger.getTask(id_slice) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("session:lc", entry.owner_session);
    }

    // Step 2 — completion drives the ledger entry to succeeded.
    try waitForSubagentTerminal(&mgr, task_id, 5_000);
    try std.testing.expectEqual(subagent.TaskStatus.completed, mgr.getTaskStatus(task_id).?);
    const entry = delivery.ledger.getTask(id_slice) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(tasks.TaskStatus.succeeded, entry.status);
}

test "V4: subagent failure → default ledger bridge reflects failed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/nullalis-task-lifecycle/config.json",
        .allocator = std.testing.allocator,
    };

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.completion_runner = failRunner;
    defer mgr.deinit();

    const delivery = mgr.task_delivery orelse return error.TestUnexpectedResult;
    const task_id = try mgr.spawn("a task that fails", "lifecycle", "session:lc-fail", "agent", "session:lc-fail");

    try waitForSubagentTerminal(&mgr, task_id, 5_000);
    try std.testing.expectEqual(subagent.TaskStatus.failed, mgr.getTaskStatus(task_id).?);

    var id_buf: [tasks.ledger.TASK_ID_LEN]u8 = undefined;
    const id_slice = try canonicalIdSlice(&id_buf, task_id);
    const entry = delivery.ledger.getTask(id_slice) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(tasks.TaskStatus.failed, entry.status);
}

test "V4: explicit attachTaskDelivery overrides the owned fallback" {
    // The gateway path attaches a real per-tenant delivery; it must win
    // over the manager-owned fallback.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/nullalis-task-lifecycle/config.json",
        .allocator = std.testing.allocator,
    };

    var ledger_inst = tasks.TaskLedger.init(std.testing.allocator);
    defer ledger_inst.deinit();
    var noop = nullalis.observability.NoopObserver{};
    var explicit = tasks.TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.completion_runner = okRunner;
    mgr.attachTaskDelivery(&explicit);
    defer mgr.deinit();

    try std.testing.expectEqual(&explicit, mgr.task_delivery.?);

    const task_id = try mgr.spawn("attached", "lifecycle", "session:attached", "agent", "session:attached");
    try waitForSubagentTerminal(&mgr, task_id, 5_000);

    var id_buf: [tasks.ledger.TASK_ID_LEN]u8 = undefined;
    const id_slice = try canonicalIdSlice(&id_buf, task_id);
    const entry = ledger_inst.getTask(id_slice) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(tasks.TaskStatus.succeeded, entry.status);
}
