const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;
const observability = @import("../observability.zig");

const log = std.log.scoped(.memory_forget);

/// Memory forget tool — lets the agent delete a memory entry.
/// When a MemoryRuntime is available, also cleans up the vector store.
pub const MemoryForgetTool = struct {
    memory: ?Memory = null,
    mem_rt: ?*mem_root.MemoryRuntime = null,

    pub const tool_name = "memory_forget";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Hard-delete a memory by key (GDPR-grade scrub; no audit trail kept).",
        .use_when = &.{
            "User explicitly asks to delete or forget specific personal information",
            "GDPR / data-subject erasure request that requires the row to disappear",
            "Cleaning sensitive content that must not survive as audit evidence",
        },
        .do_not_use_for = &.{
            "memory_archive — for soft-close that keeps the row as audit evidence",
            "memory_purge_topic — for bulk-removal of agent-generated artifacts on a topic",
            "memory_edit — for correcting a fact rather than scrubbing it",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("memory_forget", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description = "Remove a memory by key. Use to delete outdated facts or sensitive data.";
    pub const tool_params =
        \\{"type":"object","properties":{"key":{"type":"string","description":"The key of the memory to forget"}},"required":["key"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryForgetTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// S5 (2026-05-29, prod-readiness) — public entry point wraps the
    /// underlying executor with latency + result emit. See the parallel
    /// pattern in `memory_store.zig` for rationale.
    pub fn execute(self: *MemoryForgetTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const start_ms = std.time.milliTimestamp();
        const result = self.executeInner(allocator, args) catch |err| {
            const elapsed_ms: u64 = @intCast(@max(@as(i64, 0), std.time.milliTimestamp() - start_ms));
            observability.recordMetricGlobal(.{ .memory_op_total = .{ .op = "forget", .result = "err" } });
            observability.recordMetricGlobal(.{ .memory_op_latency_ms = .{ .op = "forget", .value = elapsed_ms } });
            return err;
        };
        const elapsed_ms: u64 = @intCast(@max(@as(i64, 0), std.time.milliTimestamp() - start_ms));
        const label: []const u8 = if (result.success) "ok" else "err";
        observability.recordMetricGlobal(.{ .memory_op_total = .{ .op = "forget", .result = label } });
        observability.recordMetricGlobal(.{ .memory_op_latency_ms = .{ .op = "forget", .value = elapsed_ms } });
        return result;
    }

    fn executeInner(self: *MemoryForgetTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const key = root.getString(args, "key") orelse
            return ToolResult.fail("Missing 'key' parameter");
        if (key.len == 0) return ToolResult.fail("'key' must not be empty");

        const m = self.memory orelse {
            const msg = try std.fmt.allocPrint(allocator, "Memory backend not configured. Cannot forget: {s}", .{key});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };

        var lookup = try mem_root.lookupMemoryLifecycleEntry(allocator, m, key);
        defer lookup.deinit(allocator);
        switch (lookup.status) {
            .missing => {
                // Idempotent (matches the existing behavior). Caller-
                // facing message stays in `output` because the call
                // succeeded (nothing to do).
                const msg = try std.fmt.allocPrint(allocator, "No memory found with key: {s}", .{key});
                return ToolResult{ .success = true, .output = msg };
            },
            .protected => {
                const msg = try std.fmt.allocPrint(allocator, "Memory key is not deletable: {s}", .{key});
                return ToolResult{ .success = false, .error_msg = msg, .output = "" };
            },
            .editable => {},
        }

        const forgotten = m.forget(key) catch |err| {
            log.warn("memory_forget delete failed key='{s}' err={s}", .{ key, @errorName(err) });
            const msg = try std.fmt.allocPrint(allocator, "Failed to forget memory '{s}': {s}", .{ key, @errorName(err) });
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };

        if (forgotten) {
            // Best-effort vector store cleanup
            if (self.mem_rt) |rt| {
                rt.deleteFromVectorStore(key);
            }
            const msg = try std.fmt.allocPrint(allocator, "Forgot memory: {s}", .{key});
            return ToolResult{ .success = true, .output = msg };
        } else {
            const msg = try std.fmt.allocPrint(allocator, "No memory found with key: {s}", .{key});
            return ToolResult{ .success = true, .output = msg };
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "memory_forget tool name" {
    var mt = MemoryForgetTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_forget", t.name());
}

test "memory_forget schema has key" {
    var mt = MemoryForgetTool{};
    const t = mt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "key") != null);
}

test "memory_forget executes without backend" {
    var mt = MemoryForgetTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"temp\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |em| std.testing.allocator.free(em);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not configured") != null);
}

test "memory_forget missing key" {
    var mt = MemoryForgetTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "memory_forget with real backend key not found" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryForgetTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "No memory found") != null);
}

test "memory_forget with real backend returns appropriate message" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryForgetTool{ .memory = backend.memory() };
    const t = mt.tool();
    // NoneMemory.forget always returns false (nothing to forget)
    const parsed = try root.parseTestArgs("{\"key\": \"test_key\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "No memory found with key: test_key") != null);
}

test "memory_forget rejects system-managed key" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("summary_latest/agent:zaki-bot:user:1:main", "focus: shipping", .core, null);

    var mt = MemoryForgetTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"summary_latest/agent:zaki-bot:user:1:main\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    defer if (result.error_msg) |em| allocator.free(em);
    try std.testing.expect(!result.success);
}

test "memory_forget deletes editable key" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("user_name", "Nova", .core, null);

    var mt = MemoryForgetTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"user_name\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect((try mem.get(allocator, "user_name")) == null);
}
