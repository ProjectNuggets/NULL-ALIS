//! SubagentManager — background task execution via isolated agent instances.
//!
//! Spawns subagents in separate OS threads with restricted tool sets
//! (no message, spawn, delegate — to prevent infinite loops).
//! Task results are routed via the event bus as system InboundMessages.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bus_mod = @import("bus.zig");
const config_mod = @import("config.zig");
const providers = @import("providers/root.zig");

const log = std.log.scoped(.subagent);

// ── Task types ──────────────────────────────────────────────────

pub const TaskStatus = enum {
    running,
    completed,
    failed,
};

pub const TaskState = struct {
    status: TaskStatus,
    label: []const u8,
    session_key: ?[]const u8 = null,
    origin_channel: ?[]const u8 = null,
    origin_chat_id: ?[]const u8 = null,
    result: ?[]const u8 = null,
    error_msg: ?[]const u8 = null,
    started_at: i64,
    completed_at: ?i64 = null,
    thread: ?std.Thread = null,
};

pub const SubagentConfig = struct {
    max_iterations: u32 = 15,
    max_concurrent: u32 = 4,
};

// ── ThreadContext — passed to each spawned thread ────────────────

const ThreadContext = struct {
    manager: *SubagentManager,
    task_id: u64,
    task: []const u8,
    label: []const u8,
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

    allocator: Allocator,
    tasks: std.AutoHashMapUnmanaged(u64, *TaskState),
    next_id: u64,
    mutex: std.Thread.Mutex,
    config: SubagentConfig,
    bus: ?*bus_mod.Bus,

    // Context needed for creating providers in subagent threads
    api_key: ?[]const u8,
    default_provider: []const u8,
    default_model: ?[]const u8,
    workspace_dir: []const u8,
    agents: []const config_mod.NamedAgentConfig,
    http_enabled: bool,
    completion_runner: ?CompletionRunnerFn = null,
    completion_runner_ctx: ?*anyopaque = null,

    pub fn init(
        allocator: Allocator,
        cfg: *const config_mod.Config,
        bus: ?*bus_mod.Bus,
        subagent_config: SubagentConfig,
    ) SubagentManager {
        return .{
            .allocator = allocator,
            .tasks = .{},
            .next_id = 1,
            .mutex = .{},
            .config = subagent_config,
            .bus = bus,
            .api_key = cfg.defaultProviderKey(),
            .default_provider = cfg.default_provider,
            .default_model = cfg.default_model,
            .workspace_dir = cfg.workspace_dir,
            .agents = cfg.agents,
            .http_enabled = cfg.http_request.enabled,
        };
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
            if (state.origin_channel) |channel| self.allocator.free(channel);
            if (state.origin_chat_id) |chat| self.allocator.free(chat);
            self.allocator.free(state.label);
            self.allocator.destroy(state);
        }
        self.tasks.deinit(self.allocator);
    }

    /// Spawn a background subagent. Returns task_id immediately.
    pub fn spawn(
        self: *SubagentManager,
        task: []const u8,
        label: []const u8,
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
        const state_session = try self.allocator.dupe(u8, origin_chat_id);
        errdefer self.allocator.free(state_session);
        const state_channel = try self.allocator.dupe(u8, origin_channel);
        errdefer self.allocator.free(state_channel);
        const state_chat = try self.allocator.dupe(u8, origin_chat_id);
        errdefer self.allocator.free(state_chat);
        state.* = .{
            .status = .running,
            .label = state_label,
            .session_key = state_session,
            .origin_channel = state_channel,
            .origin_chat_id = state_chat,
            .started_at = std.time.milliTimestamp(),
        };

        try self.tasks.put(self.allocator, task_id, state);
        errdefer _ = self.tasks.remove(task_id);

        const task_copy = try self.allocator.dupe(u8, task);
        errdefer self.allocator.free(task_copy);
        const label_copy = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(label_copy);
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
            .origin_channel = origin_channel_copy,
            .origin_chat_id = origin_chat_copy,
        };

        state.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, subagentThreadFn, .{ctx});

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
            if (entry.value_ptr.*.status == .running) count += 1;
        }
        return count;
    }

    /// Mark a task as completed or failed. Thread-safe.
    fn completeTask(self: *SubagentManager, task_id: u64, result: ?[]const u8, err_msg: ?[]const u8) void {
        // Dupe result/error into manager's allocator (source may be arena-backed)
        const owned_result = if (result) |r| self.allocator.dupe(u8, r) catch null else null;
        const owned_err = if (err_msg) |e| self.allocator.dupe(u8, e) catch null else null;

        var label: []const u8 = "subagent";
        var origin_channel: []const u8 = "system";
        var origin_chat_id: []const u8 = "agent";
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.tasks.get(task_id)) |state| {
                state.status = if (owned_err != null) .failed else .completed;
                state.result = owned_result;
                state.error_msg = owned_err;
                state.completed_at = std.time.milliTimestamp();
                label = state.label;
                origin_channel = state.origin_channel orelse "system";
                origin_chat_id = state.origin_chat_id orelse "agent";
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
                origin_chat_id,
            ) catch {
                self.allocator.free(content);
                return;
            };
            self.allocator.free(content);

            b.publishInbound(msg) catch |err| {
                msg.deinit(self.allocator);
                log.err("subagent: failed to publish result to bus: {}", .{err});
            };
        }
    }
};

// ── Thread function ─────────────────────────────────────────────

fn subagentThreadFn(ctx: *ThreadContext) void {
    defer {
        ctx.manager.allocator.free(ctx.task);
        ctx.manager.allocator.free(ctx.label);
        ctx.manager.allocator.free(ctx.origin_channel);
        ctx.manager.allocator.free(ctx.origin_chat_id);
        ctx.manager.allocator.destroy(ctx);
    }

    // Use the legacy complete path — simple, works with any provider,
    // no need to replicate the full ProviderHolder pattern.
    // Build a config-like struct for providers.completeWithSystem().
    const system_prompt = "You are a background subagent. Complete the assigned task concisely and accurately. You have no access to interactive tools — focus on reasoning and analysis.";

    var cfg_arena = std.heap.ArenaAllocator.init(ctx.manager.allocator);
    defer cfg_arena.deinit();

    // Build a config-like struct that providers.completeWithSystem() accepts
    const cfg = .{
        .api_key = ctx.manager.api_key,
        .default_provider = ctx.manager.default_provider,
        .default_model = ctx.manager.default_model,
        .temperature = @as(f64, 0.7),
        .max_tokens = @as(?u64, null),
    };

    const result = blk: {
        if (ctx.manager.completion_runner) |runner| {
            break :blk runner(
                ctx.manager.completion_runner_ctx,
                cfg_arena.allocator(),
                system_prompt,
                ctx.task,
            ) catch |err| {
                ctx.manager.completeTask(ctx.task_id, null, @errorName(err));
                return;
            };
        }
        break :blk providers.completeWithSystem(
            cfg_arena.allocator(),
            &cfg,
            system_prompt,
            ctx.task,
        ) catch |err| {
            ctx.manager.completeTask(ctx.task_id, null, @errorName(err));
            return;
        };
    };

    ctx.manager.completeTask(ctx.task_id, result, null);
}

// ── Tests ───────────────────────────────────────────────────────

test "SubagentManager init and deinit" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
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
    try std.testing.expect(@intFromEnum(TaskStatus.running) != @intFromEnum(TaskStatus.completed));
    try std.testing.expect(@intFromEnum(TaskStatus.completed) != @intFromEnum(TaskStatus.failed));
}

test "TaskState initial defaults" {
    const state = TaskState{
        .status = .running,
        .label = "test",
        .started_at = 0,
    };
    try std.testing.expect(state.result == null);
    try std.testing.expect(state.error_msg == null);
    try std.testing.expect(state.completed_at == null);
    try std.testing.expect(state.thread == null);
}

test "SubagentManager getRunningCount empty" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
}

test "SubagentManager getTaskStatus unknown id" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expect(mgr.getTaskStatus(999) == null);
}

test "SubagentManager getTaskResult unknown id" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();
    try std.testing.expect(mgr.getTaskResult(999) == null);
}

test "SubagentManager completeTask updates state" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    // Manually insert a task state to test completeTask
    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .running,
        .label = try std.testing.allocator.dupe(u8, "test-task"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.completeTask(1, "done!", null);

    try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(1).?);
    try std.testing.expectEqualStrings("done!", mgr.getTaskResult(1).?);
}

test "SubagentManager completeTask with error" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .running,
        .label = try std.testing.allocator.dupe(u8, "fail-task"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.completeTask(1, null, "timeout");

    try std.testing.expectEqual(TaskStatus.failed, mgr.getTaskStatus(1).?);
    try std.testing.expect(mgr.getTaskResult(1) == null);
}

test "SubagentManager completeTask routes via bus" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var bus = bus_mod.Bus.init();
    defer bus.close();

    var mgr = SubagentManager.init(std.testing.allocator, &cfg, &bus, .{});
    defer mgr.deinit();

    const state = try std.testing.allocator.create(TaskState);
    state.* = .{
        .status = .running,
        .label = try std.testing.allocator.dupe(u8, "bus-task"),
        .started_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(std.testing.allocator, 1, state);

    mgr.completeTask(1, "result text", null);

    // Check bus received the message — verify depth increased
    try std.testing.expect(bus.inboundDepth() > 0);

    // Drain the bus to avoid memory leak
    bus.close();
    if (bus.consumeInbound()) |msg| {
        msg.deinit(std.testing.allocator);
    }
}

test "SubagentManager spawn stores session key" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer mgr.deinit();

    const task_id = try mgr.spawn("quick task", "session-check", "agent", "session:42");
    mgr.mutex.lock();
    defer mgr.mutex.unlock();
    const state = mgr.tasks.get(task_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(state.session_key != null);
    try std.testing.expectEqualStrings("session:42", state.session_key.?);
}

test "SubagentManager spawn rollback removes task on out-of-memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = alloc,
    };
    var mgr = SubagentManager.init(alloc, &cfg, null, .{});
    defer mgr.deinit();

    try mgr.tasks.ensureTotalCapacity(alloc, 1);
    failing.fail_index = failing.alloc_index + 4;

    try std.testing.expectError(
        error.OutOfMemory,
        mgr.spawn("oom-task", "oom-label", "agent", "session:oom"),
    );
    try std.testing.expectEqual(@as(usize, 0), mgr.tasks.count());
    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
}

fn waitForTaskTerminal(mgr: *SubagentManager, task_id: u64, timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        const status = mgr.getTaskStatus(task_id) orelse return error.TestUnexpectedResult;
        if (status != .running) return;
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

    const task_id = try mgr.spawn("summarize this", "e2e", "agent", "session:e2e");
    try waitForTaskTerminal(&mgr, task_id, 2_000);

    try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(task_id).?);
    try std.testing.expectEqualStrings("completed: summarize this", mgr.getTaskResult(task_id).?);
    try std.testing.expect(bus.inboundDepth() > 0);

    var msg = bus.consumeInbound() orelse return error.TestUnexpectedResult;
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("agent", msg.channel);
    try std.testing.expectEqualStrings("session:e2e", msg.chat_id);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "completed: summarize this") != null);
}

test "SubagentManager spawn stress enforces live concurrency limit" {
    const cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var runner = BlockingCompletionRunner{};
    var mgr = SubagentManager.init(std.testing.allocator, &cfg, null, .{
        .max_concurrent = 8,
    });
    mgr.completion_runner = BlockingCompletionRunner.run;
    mgr.completion_runner_ctx = @ptrCast(&runner);
    defer mgr.deinit();

    var task_ids: [8]u64 = undefined;
    for (&task_ids, 0..) |*task_id, i| {
        task_id.* = try mgr.spawn("stress task", "stress", "agent", "session:stress");
        _ = i;
    }

    const extra = mgr.spawn("overflow", "stress", "agent", "session:stress");
    try std.testing.expectError(error.TooManyConcurrentSubagents, extra);

    runner.releaseAll();

    for (task_ids) |task_id| {
        try waitForTaskTerminal(&mgr, task_id, 2_000);
        try std.testing.expectEqual(TaskStatus.completed, mgr.getTaskStatus(task_id).?);
    }

    try std.testing.expectEqual(@as(u32, 0), mgr.getRunningCount());
    try std.testing.expect(runner.peak_active >= 2);
}
