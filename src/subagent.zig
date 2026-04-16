//! SubagentManager — background task execution via isolated agent instances.
//!
//! Spawns subagents in separate OS threads. Each subagent runs a full
//! ChannelRuntime agent loop (tool access, memory, multi-turn) in an isolated
//! task session. Subagent runtimes use a dedicated tool profile that excludes
//! recursive spawn/delegate/message tools, and the event bus is not wired so
//! they cannot emit proactive messages directly. Task results are routed back
//! to the caller via the event bus as system InboundMessages once the agent
//! loop completes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bus_mod = @import("bus.zig");
const config_mod = @import("config.zig");
const channel_loop = @import("channel_loop.zig");
const json_util = @import("json_util.zig");
const zaki_session = @import("zaki_session.zig");
const zaki_state = @import("zaki_state.zig");

const log = std.log.scoped(.subagent);
const TASK_LEDGER_FILE_NAME = "subagent_tasks.jsonl";
const RECOVERY_FAILURE_REASON = "process_restarted_before_completion";

// ── Task types ──────────────────────────────────────────────────

pub const TaskStatus = enum {
    queued,
    running,
    completed,
    failed,
};

pub const TaskState = struct {
    status: TaskStatus,
    label: []const u8,
    task_summary: []const u8,
    task_prompt: []const u8,
    session_key: ?[]const u8 = null,
    runtime_session_key: ?[]const u8 = null,
    origin_channel: ?[]const u8 = null,
    origin_chat_id: ?[]const u8 = null,
    result: ?[]const u8 = null,
    error_msg: ?[]const u8 = null,
    started_at: i64,
    completed_at: ?i64 = null,
    thread: ?std.Thread = null,
};

pub const SubagentConfig = struct {
    /// Maximum agent loop iterations per subagent (passed to ChannelRuntime).
    max_iterations: u32 = 15,
    max_concurrent: u32 = 4,
};

// ── ThreadContext — passed to each spawned thread ────────────────

const ThreadContext = struct {
    manager: *SubagentManager,
    task_id: u64,
    task: []const u8,
    label: []const u8,
    request_session_key: []const u8,
    origin_channel: []const u8,
    origin_chat_id: []const u8,
};

// ── SubagentManager ─────────────────────────────────────────────

pub const SubagentManager = struct {
    pub const CompletionRunnerFn = *const fn (
        ctx: ?*anyopaque,
        allocator: Allocator,
        system_prompt: []const u8,
        task: []const u8,
    ) anyerror![]const u8;
    pub const CompletionDeliveryFn = *const fn (
        ctx: ?*anyopaque,
        session_key: []const u8,
        content: []const u8,
    ) anyerror!void;

    allocator: Allocator,
    tasks: std.AutoHashMapUnmanaged(u64, *TaskState),
    next_id: u64,
    mutex: std.Thread.Mutex,
    config: SubagentConfig,
    bus: ?*bus_mod.Bus,
    config_ref: *const config_mod.Config,
    ledger_path: []const u8,
    ledger_state_mgr: ?*zaki_state.Manager = null,
    ledger_user_id: ?i64 = null,
    ledger_recovery_pending: bool,

    completion_runner: ?CompletionRunnerFn = null,
    completion_runner_ctx: ?*anyopaque = null,
    completion_delivery: ?CompletionDeliveryFn = null,
    completion_delivery_ctx: ?*anyopaque = null,

    pub fn init(
        allocator: Allocator,
        cfg: *const config_mod.Config,
        bus: ?*bus_mod.Bus,
        subagent_config: SubagentConfig,
    ) SubagentManager {
        const ledger_path = std.fs.path.join(allocator, &.{ cfg.workspace_dir, "state", TASK_LEDGER_FILE_NAME }) catch "";
        var manager = SubagentManager{
            .allocator = allocator,
            .tasks = .{},
            .next_id = 1,
            .mutex = .{},
            .config = subagent_config,
            .bus = bus,
            .config_ref = cfg,
            .ledger_path = ledger_path,
            .ledger_recovery_pending = cfg.tenant.enabled and std.mem.eql(u8, cfg.state.backend, "postgres"),
        };
        if (!manager.ledger_recovery_pending) {
            manager.recoverDurableState() catch |err| {
                log.warn("subagent: failed to recover file ledger: {}", .{err});
            };
        }
        return manager;
    }

    pub fn deinit(self: *SubagentManager) void {
        // Join all running threads and free task states
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr.*;
            if (state.thread) |thread| {
                thread.join();
            }
            if (state.result) |r| self.allocator.free(r);
            if (state.error_msg) |e| self.allocator.free(e);
            if (state.session_key) |sk| self.allocator.free(sk);
            if (state.runtime_session_key) |sk| self.allocator.free(sk);
            if (state.origin_channel) |channel| self.allocator.free(channel);
            if (state.origin_chat_id) |chat| self.allocator.free(chat);
            self.allocator.free(state.label);
            self.allocator.free(state.task_summary);
            self.allocator.free(state.task_prompt);
            self.allocator.destroy(state);
        }
        self.tasks.deinit(self.allocator);
        if (self.ledger_path.len > 0) self.allocator.free(self.ledger_path);
    }

    pub fn attachPostgresLedger(self: *SubagentManager, state_mgr: *zaki_state.Manager, user_id: i64) void {
        self.mutex.lock();
        self.ledger_state_mgr = state_mgr;
        self.ledger_user_id = user_id;
        self.ledger_recovery_pending = false;
        self.clearTasksLocked();
        self.mutex.unlock();

        self.recoverDurableState() catch |err| {
            log.warn("subagent: failed to recover postgres ledger user_id={d}: {}", .{ user_id, err });
        };
    }

    pub fn attachCompletionDelivery(
        self: *SubagentManager,
        ctx: ?*anyopaque,
        delivery: CompletionDeliveryFn,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.completion_delivery_ctx = ctx;
        self.completion_delivery = delivery;
    }

    /// Spawn a background subagent. Returns task_id immediately.
    pub fn spawn(
        self: *SubagentManager,
        task: []const u8,
        label: []const u8,
        request_session_key: []const u8,
        origin_channel: []const u8,
        origin_chat_id: []const u8,
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.getRunningCountLocked() >= self.config.max_concurrent)
            return error.TooManyConcurrentSubagents;

        const task_id = self.next_id;
        self.next_id += 1;

        const state = try self.allocator.create(TaskState);
        errdefer self.allocator.destroy(state);
        const state_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(state_label);
        const state_task_summary = try summarizeTaskForDisplay(self.allocator, task);
        errdefer self.allocator.free(state_task_summary);
        const state_prompt = try self.allocator.dupe(u8, task);
        errdefer self.allocator.free(state_prompt);
        const state_session = try self.allocator.dupe(u8, request_session_key);
        errdefer self.allocator.free(state_session);
        var runtime_session_buf: [128]u8 = undefined;
        const runtime_session_text = deriveTaskRuntimeSessionKey(&runtime_session_buf, request_session_key, task_id);
        const state_runtime_session = try self.allocator.dupe(u8, runtime_session_text);
        errdefer self.allocator.free(state_runtime_session);
        const state_channel = try self.allocator.dupe(u8, origin_channel);
        errdefer self.allocator.free(state_channel);
        const state_chat = try self.allocator.dupe(u8, origin_chat_id);
        errdefer self.allocator.free(state_chat);
        const created_at = std.time.milliTimestamp();
        state.* = .{
            .status = .queued,
            .label = state_label,
            .task_summary = state_task_summary,
            .task_prompt = state_prompt,
            .session_key = state_session,
            .runtime_session_key = state_runtime_session,
            .origin_channel = state_channel,
            .origin_chat_id = state_chat,
            .started_at = created_at,
        };

        try self.tasks.put(self.allocator, task_id, state);
        errdefer {
            if (self.tasks.fetchRemove(task_id)) |removed| {
                freeTaskState(self.allocator, removed.value);
            }
        }
        self.persistTaskSnapshotLocked(task_id, state);

        const task_copy = try self.allocator.dupe(u8, task);
        errdefer self.allocator.free(task_copy);
        const label_copy = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(label_copy);
        const request_session_copy = try self.allocator.dupe(u8, request_session_key);
        errdefer self.allocator.free(request_session_copy);
        const origin_channel_copy = try self.allocator.dupe(u8, origin_channel);
        errdefer self.allocator.free(origin_channel_copy);
        const origin_chat_copy = try self.allocator.dupe(u8, origin_chat_id);
        errdefer self.allocator.free(origin_chat_copy);

        // Build thread context
        const ctx = try self.allocator.create(ThreadContext);
        errdefer self.allocator.destroy(ctx);
        ctx.* = .{
            .manager = self,
            .task_id = task_id,
            .task = task_copy,
            .label = label_copy,
            .request_session_key = request_session_copy,
            .origin_channel = origin_channel_copy,
            .origin_chat_id = origin_chat_copy,
        };

        state.thread = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, subagentThreadFn, .{ctx}) catch |err| {
            const owned_err = self.allocator.dupe(u8, @errorName(err)) catch null;
            state.status = .failed;
            state.error_msg = owned_err;
            state.completed_at = std.time.milliTimestamp();
            self.persistTaskSnapshotLocked(task_id, state);
            self.allocator.free(task_copy);
            self.allocator.free(label_copy);
            self.allocator.free(request_session_copy);
            self.allocator.free(origin_channel_copy);
            self.allocator.free(origin_chat_copy);
            self.allocator.destroy(ctx);
            return err;
        };

        return task_id;
    }

    pub fn getTaskStatus(self: *SubagentManager, task_id: u64) ?TaskStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.get(task_id)) |state| {
            return state.status;
        }
        return null;
    }

    pub fn getTaskResult(self: *SubagentManager, task_id: u64) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.get(task_id)) |state| {
            return state.result;
        }
        return null;
    }

    pub fn getRunningCount(self: *SubagentManager) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.getRunningCountLocked();
    }

    fn getRunningCountLocked(self: *SubagentManager) u32 {
        var count: u32 = 0;
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.status == .queued or entry.value_ptr.*.status == .running) count += 1;
        }
        return count;
    }

    fn clearTasksLocked(self: *SubagentManager) void {
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr.*;
            if (state.thread) |thread| thread.join();
            if (state.result) |value| self.allocator.free(value);
            if (state.error_msg) |value| self.allocator.free(value);
            if (state.session_key) |value| self.allocator.free(value);
            if (state.runtime_session_key) |value| self.allocator.free(value);
            if (state.origin_channel) |value| self.allocator.free(value);
            if (state.origin_chat_id) |value| self.allocator.free(value);
            self.allocator.free(state.label);
            self.allocator.free(state.task_summary);
            self.allocator.free(state.task_prompt);
            self.allocator.destroy(state);
        }
        self.tasks.clearRetainingCapacity();
        self.next_id = 1;
    }

    fn recoverDurableState(self: *SubagentManager) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.ledger_state_mgr != null and self.ledger_user_id != null) {
            try self.recoverFromPostgresLocked();
        } else if (self.ledger_path.len > 0) {
            try self.recoverFromFileLocked();
        }
        self.finalizeRecoveredInFlightLocked();
    }

    fn recoverFromPostgresLocked(self: *SubagentManager) !void {
        const state_mgr = self.ledger_state_mgr orelse return;
        const user_id = self.ledger_user_id orelse return;
        const snapshots = try state_mgr.listTaskSnapshots(self.allocator, user_id);
        defer {
            for (snapshots) |*entry| entry.deinit(self.allocator);
            self.allocator.free(snapshots);
        }

        var max_id: u64 = 0;
        for (snapshots) |*snapshot| {
            const task_id = std.fmt.parseInt(u64, snapshot.id, 10) catch continue;
            max_id = @max(max_id, task_id);
            const state = try self.taskStateFromSnapshot(snapshot);
            try self.tasks.put(self.allocator, task_id, state);
        }
        self.next_id = max_id + 1;
    }

    fn recoverFromFileLocked(self: *SubagentManager) !void {
        if (self.ledger_path.len == 0) return;
        const file = openLedgerFileRead(self.ledger_path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const raw = try file.readToEndAlloc(self.allocator, 4 * 1024 * 1024);
        defer self.allocator.free(raw);

        var lines = std.mem.splitScalar(u8, raw, '\n');
        var max_id: u64 = 0;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            var snapshot = try parseLedgerSnapshot(self.allocator, trimmed);
            defer snapshot.deinit(self.allocator);
            max_id = @max(max_id, snapshot.id);
            if (self.tasks.fetchRemove(snapshot.id)) |existing| {
                freeTaskState(self.allocator, existing.value);
            }
            const state = try self.taskStateFromLedger(&snapshot);
            try self.tasks.put(self.allocator, snapshot.id, state);
        }
        self.next_id = max_id + 1;
    }

    fn finalizeRecoveredInFlightLocked(self: *SubagentManager) void {
        const recovered_at = std.time.milliTimestamp();
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const task_id = entry.key_ptr.*;
            const state = entry.value_ptr.*;
            if (state.status != .queued and state.status != .running) continue;
            if (state.error_msg) |value| self.allocator.free(value);
            state.status = .failed;
            state.error_msg = self.allocator.dupe(u8, RECOVERY_FAILURE_REASON) catch null;
            state.completed_at = recovered_at;
            self.persistTaskSnapshotLocked(task_id, state);
        }
    }

    fn taskStateFromSnapshot(self: *SubagentManager, snapshot: *const zaki_state.TaskSnapshot) !*TaskState {
        const label = try self.allocator.dupe(u8, snapshot.label);
        errdefer self.allocator.free(label);
        const task_summary = try summarizeTaskForDisplay(self.allocator, snapshot.prompt);
        errdefer self.allocator.free(task_summary);
        const task_prompt = try self.allocator.dupe(u8, snapshot.prompt);
        errdefer self.allocator.free(task_prompt);
        const task_id = std.fmt.parseInt(u64, snapshot.id, 10) catch 0;
        const session_key = if (snapshot.request_session_id) |value|
            try self.allocator.dupe(u8, value)
        else if (snapshot.session_id) |value|
            if (!isTaskSessionKey(value)) try self.allocator.dupe(u8, value) else null
        else
            null;
        errdefer if (session_key) |value| self.allocator.free(value);
        const runtime_session_key = if (snapshot.session_id) |value|
            if (snapshot.request_session_id == null and !isTaskSessionKey(value)) blk: {
                var session_buf: [128]u8 = undefined;
                break :blk try self.allocator.dupe(u8, deriveTaskRuntimeSessionKey(&session_buf, value, task_id));
            } else try self.allocator.dupe(u8, value)
        else blk: {
            if (session_key) |value| {
                var session_buf: [128]u8 = undefined;
                break :blk try self.allocator.dupe(u8, deriveTaskRuntimeSessionKey(&session_buf, value, task_id));
            }
            break :blk null;
        };
        errdefer if (runtime_session_key) |value| self.allocator.free(value);
        const result = if (snapshot.result) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (result) |value| self.allocator.free(value);
        const error_msg = if (snapshot.error_msg) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (error_msg) |value| self.allocator.free(value);

        const state = try self.allocator.create(TaskState);
        state.* = .{
            .status = parseTaskStatus(snapshot.status),
            .label = label,
            .task_summary = task_summary,
            .task_prompt = task_prompt,
            .session_key = session_key,
            .runtime_session_key = runtime_session_key,
            .result = result,
            .error_msg = error_msg,
            .started_at = if (snapshot.started_at_ms) |value| value else snapshot.created_at_ms,
            .completed_at = snapshot.completed_at_ms,
            .thread = null,
        };
        return state;
    }

    fn taskStateFromLedger(self: *SubagentManager, snapshot: *const LedgerSnapshot) !*TaskState {
        const label = try self.allocator.dupe(u8, snapshot.label);
        errdefer self.allocator.free(label);
        const task_summary = try self.allocator.dupe(u8, snapshot.task_summary);
        errdefer self.allocator.free(task_summary);
        const task_prompt = try self.allocator.dupe(u8, snapshot.task_prompt);
        errdefer self.allocator.free(task_prompt);
        const session_key = if (snapshot.session_key) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (session_key) |value| self.allocator.free(value);
        const runtime_session_key = if (snapshot.runtime_session_key) |value| try self.allocator.dupe(u8, value) else blk: {
            if (session_key) |value| {
                var session_buf: [128]u8 = undefined;
                break :blk try self.allocator.dupe(u8, deriveTaskRuntimeSessionKey(&session_buf, value, snapshot.id));
            }
            break :blk null;
        };
        errdefer if (runtime_session_key) |value| self.allocator.free(value);
        const origin_channel = if (snapshot.origin_channel) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (origin_channel) |value| self.allocator.free(value);
        const origin_chat_id = if (snapshot.origin_chat_id) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (origin_chat_id) |value| self.allocator.free(value);
        const result = if (snapshot.result) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (result) |value| self.allocator.free(value);
        const error_msg = if (snapshot.error_msg) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (error_msg) |value| self.allocator.free(value);

        const state = try self.allocator.create(TaskState);
        state.* = .{
            .status = snapshot.status,
            .label = label,
            .task_summary = task_summary,
            .task_prompt = task_prompt,
            .session_key = session_key,
            .runtime_session_key = runtime_session_key,
            .origin_channel = origin_channel,
            .origin_chat_id = origin_chat_id,
            .result = result,
            .error_msg = error_msg,
            .started_at = snapshot.started_at,
            .completed_at = snapshot.completed_at,
            .thread = null,
        };
        return state;
    }

    fn persistTaskSnapshotLocked(self: *SubagentManager, task_id: u64, state: *const TaskState) void {
        self.persistTaskSnapshot(task_id, state) catch |err| {
            log.warn("subagent: failed to persist task #{d}: {}", .{ task_id, err });
        };
    }

    fn persistTaskSnapshot(self: *SubagentManager, task_id: u64, state: *const TaskState) !void {
        if (self.ledger_state_mgr) |state_mgr| {
            if (self.ledger_user_id) |user_id| {
                var task_id_buf: [32]u8 = undefined;
                const task_id_text = try std.fmt.bufPrint(&task_id_buf, "{d}", .{task_id});
                try state_mgr.upsertTaskSnapshot(
                    user_id,
                    task_id_text,
                    state.runtime_session_key,
                    state.session_key,
                    state.label,
                    state.task_prompt,
                    taskStatusText(state.status),
                    state.result,
                    state.error_msg,
                    state.started_at,
                    if (state.status == .queued) null else state.started_at,
                    state.completed_at,
                );
                return;
            }
        }
        if (self.ledger_path.len == 0) return;
        try appendLedgerSnapshot(self.allocator, self.ledger_path, task_id, state);
    }

    /// Mark a task as completed or failed. Thread-safe.
    fn completeTask(self: *SubagentManager, task_id: u64, result: ?[]const u8, err_msg: ?[]const u8) void {
        // Dupe result/error into manager's allocator (source may be arena-backed)
        const owned_result = if (result) |r| self.allocator.dupe(u8, r) catch null else null;
        const owned_err = if (err_msg) |e| self.allocator.dupe(u8, e) catch null else null;

        var label: []const u8 = "subagent";
        var origin_channel: []const u8 = "system";
        var origin_chat_id: []const u8 = "agent";
        var request_session_key: []const u8 = "agent";
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.tasks.get(task_id)) |state| {
                if (state.result) |value| self.allocator.free(value);
                if (state.error_msg) |value| self.allocator.free(value);
                state.status = if (owned_err != null) .failed else .completed;
                state.result = owned_result;
                state.error_msg = owned_err;
                state.completed_at = std.time.milliTimestamp();
                self.persistTaskSnapshotLocked(task_id, state);
                label = state.label;
                origin_channel = state.origin_channel orelse "system";
                origin_chat_id = state.origin_chat_id orelse "agent";
                request_session_key = state.session_key orelse origin_chat_id;
            }
        }

        // Route result via bus (outside lock)
        if (self.bus) |b| {
            const content = if (owned_result) |r|
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' completed]\n{s}", .{ label, r }) catch return
            else if (owned_err) |e|
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' failed]\n{s}", .{ label, e }) catch return
            else
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' finished]", .{label}) catch return;

            const msg = bus_mod.makeInbound(
                self.allocator,
                origin_channel,
                "subagent",
                origin_chat_id,
                content,
                request_session_key,
            ) catch {
                self.allocator.free(content);
                return;
            };
            self.allocator.free(content);

            b.publishInbound(msg) catch |err| {
                msg.deinit(self.allocator);
                log.err("subagent: failed to publish result to bus: {}", .{err});
            };
        } else if (self.completion_delivery) |delivery| {
            const content = if (owned_result) |r|
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' completed]\n{s}", .{ label, r }) catch return
            else if (owned_err) |e|
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' failed]\n{s}", .{ label, e }) catch return
            else
                std.fmt.allocPrint(self.allocator, "[Subagent '{s}' finished]", .{label}) catch return;
            defer self.allocator.free(content);

            delivery(self.completion_delivery_ctx, request_session_key, content) catch |err| {
                log.err("subagent: failed to append local completion: {}", .{err});
            };
        }
    }

    fn markTaskRunning(self: *SubagentManager, task_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.get(task_id)) |state| {
            if (state.status == .queued) {
                state.status = .running;
                self.persistTaskSnapshotLocked(task_id, state);
            }
        }
    }
};

// ── Thread function ─────────────────────────────────────────────

fn subagentThreadFn(ctx: *ThreadContext) void {
    defer {
        ctx.manager.allocator.free(ctx.task);
        ctx.manager.allocator.free(ctx.label);
        ctx.manager.allocator.free(ctx.request_session_key);
        ctx.manager.allocator.free(ctx.origin_channel);
        ctx.manager.allocator.free(ctx.origin_chat_id);
        ctx.manager.allocator.destroy(ctx);
    }

    ctx.manager.markTaskRunning(ctx.task_id);

    // Test path: injected runner bypasses the full runtime (used in unit tests).
    if (ctx.manager.completion_runner) |runner| {
        const system_prompt = "You are a background subagent. Complete the assigned task concisely and accurately.";
        var test_arena = std.heap.ArenaAllocator.init(ctx.manager.allocator);
        defer test_arena.deinit();
        const result = runner(
            ctx.manager.completion_runner_ctx,
            test_arena.allocator(),
            system_prompt,
            ctx.task,
        ) catch |err| {
            ctx.manager.completeTask(ctx.task_id, null, @errorName(err));
            return;
        };
        ctx.manager.completeTask(ctx.task_id, result, null);
        return;
    }

    // Production path: full ChannelRuntime agent loop in an isolated task lane.
    // The subagent tool profile removes recursive spawn/delegate/message tools.
    var runtime = channel_loop.ChannelRuntime.initWithProfile(
        ctx.manager.allocator,
        ctx.manager.config_ref,
        null, // event_bus — deliberately omitted for proactive-message isolation
        .subagent,
    ) catch |err| {
        ctx.manager.completeTask(ctx.task_id, null, @errorName(err));
        return;
    };
    defer runtime.deinit();

    var session_buf: [128]u8 = undefined;
    const session_key = deriveTaskRuntimeSessionKey(&session_buf, ctx.request_session_key, ctx.task_id);

    const result = runtime.session_mgr.processMessageWithContext(
        session_key,
        ctx.task,
        null,
        .{ .turn_origin = .proactive },
    ) catch |err| {
        ctx.manager.completeTask(ctx.task_id, null, @errorName(err));
        return;
    };
    defer ctx.manager.allocator.free(result);

    ctx.manager.completeTask(ctx.task_id, result, null);
}

fn summarizeTaskForDisplay(allocator: Allocator, task: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, task, " \t\r\n");
    const first_line = std.mem.sliceTo(trimmed, '\n');
    const clipped = if (first_line.len > 80) first_line[0..80] else first_line;
    return allocator.dupe(u8, clipped);
}

const LedgerSnapshot = struct {
    id: u64,
    status: TaskStatus,
    label: []u8,
    task_summary: []u8,
    task_prompt: []u8,
    session_key: ?[]u8 = null,
    runtime_session_key: ?[]u8 = null,
    origin_channel: ?[]u8 = null,
    origin_chat_id: ?[]u8 = null,
    result: ?[]u8 = null,
    error_msg: ?[]u8 = null,
    started_at: i64,
    completed_at: ?i64 = null,

    fn deinit(self: *LedgerSnapshot, allocator: Allocator) void {
        allocator.free(self.label);
        allocator.free(self.task_summary);
        allocator.free(self.task_prompt);
        if (self.session_key) |value| allocator.free(value);
        if (self.runtime_session_key) |value| allocator.free(value);
        if (self.origin_channel) |value| allocator.free(value);
        if (self.origin_chat_id) |value| allocator.free(value);
        if (self.result) |value| allocator.free(value);
        if (self.error_msg) |value| allocator.free(value);
    }
};

fn freeTaskState(allocator: Allocator, state: *TaskState) void {
    if (state.thread) |thread| thread.join();
    if (state.result) |value| allocator.free(value);
    if (state.error_msg) |value| allocator.free(value);
    if (state.session_key) |value| allocator.free(value);
    if (state.runtime_session_key) |value| allocator.free(value);
    if (state.origin_channel) |value| allocator.free(value);
    if (state.origin_chat_id) |value| allocator.free(value);
    allocator.free(state.label);
    allocator.free(state.task_summary);
    allocator.free(state.task_prompt);
    allocator.destroy(state);
}

fn taskStatusText(status: TaskStatus) []const u8 {
    return switch (status) {
        .queued => "queued",
        .running => "running",
        .completed => "completed",
        .failed => "failed",
    };
}

fn parseTaskStatus(raw: []const u8) TaskStatus {
    if (std.mem.eql(u8, raw, "queued")) return .queued;
    if (std.mem.eql(u8, raw, "running")) return .running;
    if (std.mem.eql(u8, raw, "completed")) return .completed;
    return .failed;
}

fn isTaskSessionKey(session_key: []const u8) bool {
    return std.mem.startsWith(u8, session_key, "task:") or std.mem.indexOf(u8, session_key, ":task:") != null;
}

fn deriveTaskRuntimeSessionKey(buf: []u8, request_session_key: []const u8, task_id: u64) []const u8 {
    const user_id = zaki_session.parseUserIdFromSessionKey(request_session_key) orelse
        return std.fmt.bufPrint(buf, "subagent:{d}", .{task_id}) catch "subagent:bg";
    var task_id_buf: [32]u8 = undefined;
    const task_id_text = std.fmt.bufPrint(&task_id_buf, "{d}", .{task_id}) catch "0";
    return zaki_session.userTaskSessionKey(buf, user_id, task_id_text);
}

fn appendOptionalJsonString(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: ?[]const u8) !void {
    if (value) |resolved| {
        try json_util.appendJsonString(buf, allocator, resolved);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn appendLedgerSnapshot(allocator: Allocator, path: []const u8, task_id: u64, state: *const TaskState) !void {
    if (path.len == 0) return;
    try ensureLedgerParent(path);
    var file = openLedgerFileAppend(path) catch return;
    defer file.close();
    try file.seekFromEnd(0);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{");
    try buf.writer(allocator).print("\"id\":{d},", .{task_id});
    try buf.appendSlice(allocator, "\"status\":");
    try json_util.appendJsonString(&buf, allocator, taskStatusText(state.status));
    try buf.appendSlice(allocator, ",\"label\":");
    try json_util.appendJsonString(&buf, allocator, state.label);
    try buf.appendSlice(allocator, ",\"task_summary\":");
    try json_util.appendJsonString(&buf, allocator, state.task_summary);
    try buf.appendSlice(allocator, ",\"task_prompt\":");
    try json_util.appendJsonString(&buf, allocator, state.task_prompt);
    try buf.appendSlice(allocator, ",\"session_key\":");
    try appendOptionalJsonString(&buf, allocator, state.runtime_session_key orelse state.session_key);
    try buf.appendSlice(allocator, ",\"request_session_key\":");
    try appendOptionalJsonString(&buf, allocator, state.session_key);
    try buf.appendSlice(allocator, ",\"runtime_session_key\":");
    try appendOptionalJsonString(&buf, allocator, state.runtime_session_key);
    try buf.appendSlice(allocator, ",\"origin_channel\":");
    try appendOptionalJsonString(&buf, allocator, state.origin_channel);
    try buf.appendSlice(allocator, ",\"origin_chat_id\":");
    try appendOptionalJsonString(&buf, allocator, state.origin_chat_id);
    try buf.appendSlice(allocator, ",\"result\":");
    try appendOptionalJsonString(&buf, allocator, state.result);
    try buf.appendSlice(allocator, ",\"error\":");
    try appendOptionalJsonString(&buf, allocator, state.error_msg);
    try buf.writer(allocator).print(",\"started_at\":{d},\"completed_at\":", .{state.started_at});
    if (state.completed_at) |value| {
        try buf.writer(allocator).print("{d}", .{value});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, "}\n");
    _ = try file.write(buf.items);
}

fn parseLedgerSnapshot(allocator: Allocator, raw: []const u8) !LedgerSnapshot {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTaskLedgerEntry;
    const obj = parsed.value.object;
    const id_value = obj.get("id") orelse return error.InvalidTaskLedgerEntry;
    if (id_value != .integer) return error.InvalidTaskLedgerEntry;
    const label = objectString(obj, "label") orelse return error.InvalidTaskLedgerEntry;
    const task_summary = objectString(obj, "task_summary") orelse label;
    const task_prompt = objectString(obj, "task_prompt") orelse task_summary;
    const status_text = objectString(obj, "status") orelse return error.InvalidTaskLedgerEntry;
    const started_value = obj.get("started_at") orelse return error.InvalidTaskLedgerEntry;
    if (started_value != .integer) return error.InvalidTaskLedgerEntry;
    const request_session_value = objectString(obj, "request_session_key") orelse objectString(obj, "session_key");
    const runtime_session_value = blk: {
        if (objectString(obj, "runtime_session_key")) |value| break :blk value;
        if (objectString(obj, "request_session_key")) |request_value| {
            var session_buf: [128]u8 = undefined;
            break :blk deriveTaskRuntimeSessionKey(&session_buf, request_value, @intCast(id_value.integer));
        }
        break :blk null;
    };

    return .{
        .id = @intCast(id_value.integer),
        .status = parseTaskStatus(status_text),
        .label = try allocator.dupe(u8, label),
        .task_summary = try allocator.dupe(u8, task_summary),
        .task_prompt = try allocator.dupe(u8, task_prompt),
        .session_key = if (request_session_value) |value| try allocator.dupe(u8, value) else null,
        .runtime_session_key = if (runtime_session_value) |value| try allocator.dupe(u8, value) else null,
        .origin_channel = if (objectString(obj, "origin_channel")) |value| try allocator.dupe(u8, value) else null,
        .origin_chat_id = if (objectString(obj, "origin_chat_id")) |value| try allocator.dupe(u8, value) else null,
        .result = if (objectString(obj, "result")) |value| try allocator.dupe(u8, value) else null,
        .error_msg = if (objectString(obj, "error")) |value| try allocator.dupe(u8, value) else null,
        .started_at = started_value.integer,
        .completed_at = if (obj.get("completed_at")) |value| switch (value) {
            .integer => value.integer,
            else => null,
        } else null,
    };
}

fn objectString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn ensureLedgerParent(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (std.fs.path.isAbsolute(dir)) {
        try makeAbsolutePath(dir);
    } else {
        try std.fs.cwd().makePath(dir);
    }
}

fn makeAbsolutePath(path: []const u8) !void {
    if (path.len == 0) return;
    if (std.fs.openDirAbsolute(path, .{})) |opened_dir| {
        var dir = opened_dir;
        dir.close();
        return;
    } else |_| {}
    if (std.fs.path.dirname(path)) |parent| {
        if (!std.mem.eql(u8, parent, path)) try makeAbsolutePath(parent);
    }
    try std.fs.makeDirAbsolute(path);
}

fn openLedgerFileAppend(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.createFileAbsolute(path, .{ .truncate = false, .read = true });
    return std.fs.cwd().createFile(path, .{ .truncate = false, .read = true });
}

fn openLedgerFileRead(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.openFileAbsolute(path, .{});
    return std.fs.cwd().openFile(path, .{});
}

// ── Tests ───────────────────────────────────────────────────────

test "SubagentManager init and deinit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expectEqual(@as(u64, 1), mgr.next_id);
    try std.testing.expect(mgr.bus == null);
}

test "SubagentConfig defaults" {
    const sc = SubagentConfig{};
    try std.testing.expectEqual(@as(u32, 15), sc.max_iterations);
    try std.testing.expectEqual(@as(u32, 4), sc.max_concurrent);
}

test "TaskStatus enum values" {
    try std.testing.expect(@intFromEnum(TaskStatus.queued) != @intFromEnum(TaskStatus.running));
    try std.testing.expect(@intFromEnum(TaskStatus.running) != @intFromEnum(TaskStatus.completed));
    try std.testing.expect(@intFromEnum(TaskStatus.completed) != @intFromEnum(TaskStatus.failed));
}

test "TaskState initial defaults" {
    const state = TaskState{
        .status = .queued,
        .label = "test",
        .task_summary = "do test work",
        .task_prompt = "do test work",
        .started_at = 0,
    };
    try std.testing.expect(state.result == null);
    try std.testing.expect(state.error_msg == null);
    try std.testing.expect(state.completed_at == null);
    try std.testing.expect(state.thread == null);
}

test "SubagentManager getRunningCount empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
}

test "SubagentManager getTaskStatus unknown id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expect(mgr.getTaskStatus(999) == null);
}

test "SubagentManager getTaskResult unknown id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expect(mgr.getTaskResult(999) == null);
}

test "SubagentManager completeTask updates state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    // Manually insert a task state to test completeTask
    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "test-task"),
        .task_summary = try std.testing.allocator.dupe(u8, "do test work"),
        .task_prompt = try std.testing.allocator.dupe(u8, "do test work"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.markTaskRunning(1);
    try std.testing.expectEqual(TaskStatus.running, mgr.getTaskStatus(1).?);
    mgr.completeTask(1, "done!", null);

    try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(1).?);
    try std.testing.expectEqualStrings("done!", mgr.getTaskResult(1).?);
}

test "SubagentManager completeTask with error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "fail-task"),
        .task_summary = try std.testing.allocator.dupe(u8, "will fail"),
        .task_prompt = try std.testing.allocator.dupe(u8, "will fail"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.markTaskRunning(1);
    mgr.completeTask(1, null, "timeout");

    try std.testing.expectEqual(TaskStatus.failed, mgr.getTaskStatus(1).?);
    try std.testing.expect(mgr.getTaskResult(1) == null);
}

test "SubagentManager completeTask routes via bus" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var bus = bus_mod.Bus.init();
    defer bus.close();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, &bus, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "bus-task"),
        .task_summary = try std.testing.allocator.dupe(u8, "publish result"),
        .task_prompt = try std.testing.allocator.dupe(u8, "publish result"),
        .session_key = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:main"),
        .origin_channel = try std.testing.allocator.dupe(u8, "telegram"),
        .origin_chat_id = try std.testing.allocator.dupe(u8, "12345"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.markTaskRunning(1);
    mgr.completeTask(1, "result text", null);

    // Check bus received the message — verify depth increased
    var msg = try waitForInboundMessage(&bus, 50);
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("telegram", msg.channel);
    try std.testing.expectEqualStrings("12345", msg.chat_id);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", msg.session_key);
}

test "SubagentManager completeTask falls back to local completion delivery without bus" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var recorder = RecordingCompletionDelivery{};
    defer recorder.deinit();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    mgr.attachCompletionDelivery(@ptrCast(&recorder), RecordingCompletionDelivery.run);
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .queued,
        .label = try std.testing.allocator.dupe(u8, "local-task"),
        .task_summary = try std.testing.allocator.dupe(u8, "publish local result"),
        .task_prompt = try std.testing.allocator.dupe(u8, "publish local result"),
        .session_key = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:thread:main"),
        .origin_channel = try std.testing.allocator.dupe(u8, "agent"),
        .origin_chat_id = try std.testing.allocator.dupe(u8, "chat-1"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.markTaskRunning(1);
    mgr.completeTask(1, "result text", null);

    try std.testing.expect(recorder.session_key != null);
    try std.testing.expect(recorder.content != null);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:thread:main", recorder.session_key.?);
    try std.testing.expect(std.mem.indexOf(u8, recorder.content.?, "result text") != null);
}

test "SubagentManager spawn stores session key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const task_id = try mgr.spawn("quick task", "session-check", "session:42", "agent", "session:42");
    mgr.mutex.lock();
    defer mgr.mutex.unlock();
    const state = mgr.tasks.get(task_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(state.session_key != null);
    try std.testing.expect(state.runtime_session_key != null);
    try std.testing.expectEqualStrings("session:42", state.session_key.?);
    try std.testing.expectEqualStrings("subagent:1", state.runtime_session_key.?);
    try std.testing.expect(state.task_summary.len > 0);
}

test "SubagentManager spawn derives canonical user task runtime session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const task_id = try mgr.spawn("ship fix", "canonical-lane", "agent:zaki-bot:user:42:main", "agent", "session:42");
    mgr.mutex.lock();
    defer mgr.mutex.unlock();
    const state = mgr.tasks.get(task_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:main", state.session_key.?);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:task:1", state.runtime_session_key.?);
}

test "SubagentManager spawn falls back to local runtime session when requester is non-canonical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const task_id = try mgr.spawn("ship fix", "fallback-lane", "session:ephemeral", "agent", "session:ephemeral");
    mgr.mutex.lock();
    defer mgr.mutex.unlock();
    const state = mgr.tasks.get(task_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("session:ephemeral", state.session_key.?);
    try std.testing.expectEqualStrings("subagent:1", state.runtime_session_key.?);
}

test "taskStateFromSnapshot derives runtime lane for legacy requester-only snapshot" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    var snapshot = zaki_state.TaskSnapshot{
        .id = try std.testing.allocator.dupe(u8, "7"),
        .session_id = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:main"),
        .request_session_id = null,
        .label = try std.testing.allocator.dupe(u8, "legacy"),
        .prompt = try std.testing.allocator.dupe(u8, "repair legacy"),
        .status = try std.testing.allocator.dupe(u8, "completed"),
        .result = null,
        .error_msg = null,
        .created_at_ms = 42,
        .started_at_ms = 42,
        .completed_at_ms = 84,
    };
    defer snapshot.deinit(std.testing.allocator);

    const state = try mgr.taskStateFromSnapshot(&snapshot);
    defer freeTaskState(std.testing.allocator, state);

    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", state.session_key.?);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:task:7", state.runtime_session_key.?);
}

test "taskStateFromSnapshot preserves explicit requester and runtime lanes" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    var snapshot = zaki_state.TaskSnapshot{
        .id = try std.testing.allocator.dupe(u8, "9"),
        .session_id = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:task:9"),
        .request_session_id = try std.testing.allocator.dupe(u8, "agent:zaki-bot:user:1:main"),
        .label = try std.testing.allocator.dupe(u8, "modern"),
        .prompt = try std.testing.allocator.dupe(u8, "preserve split"),
        .status = try std.testing.allocator.dupe(u8, "completed"),
        .result = null,
        .error_msg = null,
        .created_at_ms = 42,
        .started_at_ms = 42,
        .completed_at_ms = 84,
    };
    defer snapshot.deinit(std.testing.allocator);

    const state = try mgr.taskStateFromSnapshot(&snapshot);
    defer freeTaskState(std.testing.allocator, state);

    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", state.session_key.?);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:task:9", state.runtime_session_key.?);
}

test "summarizeTaskForDisplay clips first line for founder-readable task truth" {
    const summary = try summarizeTaskForDisplay(std.testing.allocator, "first line task\nsecond line detail");
    defer std.testing.allocator.free(summary);
    try std.testing.expectEqualStrings("first line task", summary);
}

test "SubagentManager recovers completed task from file ledger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    {
        var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
        mgr.completion_runner = immediateCompletionRunner;
        defer mgr.deinit();

        const task_id = try mgr.spawn("recover me", "recover", "agent:zaki-bot:user:1:main", "agent", "session:recover");
        try waitForTaskTerminal(&mgr, task_id, 2_000);
    }

    var recovered = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer recovered.deinit();

    try std.testing.expectEqual(@as(u64, 2), recovered.next_id);
    try std.testing.expectEqual(TaskStatus.completed, recovered.getTaskStatus(1).?);
    try std.testing.expectEqualStrings("completed: recover me", recovered.getTaskResult(1).?);
}

test "SubagentManager recovery marks in-flight task as failed explicitly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };

    const ledger_path = try std.fs.path.join(std.testing.allocator, &.{ workspace, "state", TASK_LEDGER_FILE_NAME });
    defer std.testing.allocator.free(ledger_path);
    try ensureLedgerParent(ledger_path);

    const state = TaskState{
        .status = .running,
        .label = "recover",
        .task_summary = "recover",
        .task_prompt = "recover prompt",
        .session_key = "agent:zaki-bot:user:1:main",
        .started_at = 42,
    };
    try appendLedgerSnapshot(std.testing.allocator, ledger_path, 7, &state);

    var recovered = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer recovered.deinit();

    try std.testing.expectEqual(TaskStatus.failed, recovered.getTaskStatus(7).?);
    const task_state = recovered.tasks.get(7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(RECOVERY_FAILURE_REASON, task_state.error_msg.?);
}

test "SubagentManager spawn rollback removes task on out-of-memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    var cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = alloc,
    };
    var mgr = SubagentManager.init(alloc, &cfg, null, .{});
    defer mgr.deinit();

    try mgr.tasks.ensureTotalCapacity(alloc, 1);
    failing.fail_index = failing.alloc_index + 4;

    try std.testing.expectError(
        error.OutOfMemory,
        mgr.spawn("oom-task", "oom-label", "session:oom", "agent", "session:oom"),
    );
    try std.testing.expectEqual(@as(usize, 0), mgr.tasks.count());
    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
}

fn waitForTaskTerminal(mgr: *SubagentManager, task_id: u64, timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        const status = mgr.getTaskStatus(task_id) orelse return error.TestUnexpectedResult;
        if (status == .completed or status == .failed) return;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestTimeout;
}

fn waitForInboundMessage(bus: *bus_mod.Bus, timeout_ms: u64) !bus_mod.InboundMessage {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        if (bus.consumeInbound()) |msg| return msg;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestTimeout;
}

fn waitForActiveRunnerCount(runner: *BlockingCompletionRunner, expected_active: usize, timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        runner.mutex.lock();
        const active = runner.active;
        runner.mutex.unlock();
        if (active >= expected_active) return;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestTimeout;
}

fn immediateCompletionRunner(_: ?*anyopaque, allocator: Allocator, system_prompt: []const u8, task: []const u8) ![]const u8 {
    try std.testing.expect(system_prompt.len > 0);
    return std.fmt.allocPrint(allocator, "completed: {s}", .{task});
}

const BlockingCompletionRunner = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    release: bool = false,
    active: usize = 0,
    peak_active: usize = 0,

    fn run(ctx: ?*anyopaque, allocator: Allocator, _: []const u8, task: []const u8) ![]const u8 {
        const self: *BlockingCompletionRunner = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        self.active += 1;
        if (self.active > self.peak_active) self.peak_active = self.active;
        while (!self.release) {
            self.cond.wait(&self.mutex);
        }
        self.active -= 1;
        self.mutex.unlock();
        return std.fmt.allocPrint(allocator, "released: {s}", .{task});
    }

    fn releaseAll(self: *BlockingCompletionRunner) void {
        self.mutex.lock();
        self.release = true;
        self.cond.broadcast();
        self.mutex.unlock();
    }
};

const RecordingCompletionDelivery = struct {
    session_key: ?[]const u8 = null,
    content: ?[]const u8 = null,

    fn run(ctx: ?*anyopaque, session_key: []const u8, content: []const u8) !void {
        const self: *RecordingCompletionDelivery = @ptrCast(@alignCast(ctx.?));
        if (self.session_key) |value| std.testing.allocator.free(value);
        if (self.content) |value| std.testing.allocator.free(value);
        self.session_key = try std.testing.allocator.dupe(u8, session_key);
        self.content = try std.testing.allocator.dupe(u8, content);
    }

    fn deinit(self: *RecordingCompletionDelivery) void {
        if (self.session_key) |value| std.testing.allocator.free(value);
        if (self.content) |value| std.testing.allocator.free(value);
    }
};

test "SubagentManager spawn e2e completes and publishes bus message" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var bus = bus_mod.Bus.init();
    defer bus.close();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, &bus, .{});
    mgr.completion_runner = immediateCompletionRunner;
    defer mgr.deinit();

    const task_id = try mgr.spawn("summarize this", "e2e", "session:e2e", "agent", "session:e2e");
    try waitForTaskTerminal(&mgr, task_id, 2_000);

    try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(task_id).?);
    try std.testing.expectEqualStrings("completed: summarize this", mgr.getTaskResult(task_id).?);
    var msg = try waitForInboundMessage(&bus, 250);
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("agent", msg.channel);
    try std.testing.expectEqualStrings("session:e2e", msg.chat_id);
    try std.testing.expectEqualStrings("session:e2e", msg.session_key);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "completed: summarize this") != null);
}

// ── Baseline characterization tests (Phase 00-01) ───────────────

test "baseline: SubagentConfig defaults max_iterations to 15" {
    const cfg = SubagentConfig{};
    try std.testing.expectEqual(@as(u32, 15), cfg.max_iterations);
}

test "baseline: SubagentConfig defaults max_concurrent to 4" {
    const cfg = SubagentConfig{};
    try std.testing.expectEqual(@as(u32, 4), cfg.max_concurrent);
}

test "baseline: TaskStatus has exactly 4 states" {
    // Characterize the complete set of task states: queued, running, completed, failed
    const info = @typeInfo(TaskStatus);
    try std.testing.expectEqual(@as(usize, 4), info.@"enum".fields.len);
    // Verify each state exists and has expected ordinal
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(TaskStatus.queued));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(TaskStatus.running));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(TaskStatus.completed));
    try std.testing.expectEqual(@as(u2, 3), @intFromEnum(TaskStatus.failed));
}

test "baseline: TaskState tracks required lifecycle fields" {
    // Use @hasField instead of runtime iteration (comptime-safe in Zig 0.15).
    try std.testing.expect(@hasField(TaskState, "status"));
    try std.testing.expect(@hasField(TaskState, "label"));
    try std.testing.expect(@hasField(TaskState, "session_key"));
    try std.testing.expect(@hasField(TaskState, "runtime_session_key"));
    try std.testing.expect(@hasField(TaskState, "result"));
    try std.testing.expect(@hasField(TaskState, "started_at"));
    try std.testing.expect(@hasField(TaskState, "completed_at"));
}

test "baseline: SubagentManager init respects custom config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{
        .max_concurrent = 8,
        .max_iterations = 30,
    });
    defer mgr.deinit();
    try std.testing.expectEqual(@as(u32, 8), mgr.config.max_concurrent);
    try std.testing.expectEqual(@as(u32, 30), mgr.config.max_iterations);
    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
}

test "baseline: SubagentManager getTaskStatus returns null for unknown task" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expect(mgr.getTaskStatus(99999) == null);
    try std.testing.expect(mgr.getTaskResult(99999) == null);
}

test "baseline: TASK_LEDGER_FILE_NAME is subagent_tasks.jsonl" {
    try std.testing.expectEqualStrings("subagent_tasks.jsonl", TASK_LEDGER_FILE_NAME);
}

test "SubagentManager spawn stress enforces live concurrency limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const concurrency_cap: u32 = 8;
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var runner = BlockingCompletionRunner{};
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{
        .max_concurrent = concurrency_cap,
    });
    mgr.completion_runner = BlockingCompletionRunner.run;
    mgr.completion_runner_ctx = @ptrCast(&runner);
    defer mgr.deinit();

    var task_ids: [8]u64 = undefined;
    for (&task_ids, 0..) |*task_id, i| {
        task_id.* = try mgr.spawn("stress task", "stress", "session:stress", "agent", "session:stress");
        _ = i;
    }

    const extra = mgr.spawn("overflow", "stress", "session:stress", "agent", "session:stress");
    try std.testing.expectError(error.TooManyConcurrentSubagents, extra);
    try waitForActiveRunnerCount(&runner, concurrency_cap, 2_000);

    runner.releaseAll();

    for (task_ids) |task_id| {
        try waitForTaskTerminal(&mgr, task_id, 2_000);
        try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(task_id).?);
    }

    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
    try std.testing.expectEqual(@as(usize, concurrency_cap), runner.peak_active);
}
