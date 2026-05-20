const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const CronScheduler = cron.CronScheduler;
const loadSchedulerForContext = @import("cron_add.zig").loadSchedulerForContext;
const config_mod = @import("../config.zig");

const TestTmpDir = @TypeOf(std.testing.tmpDir(.{}));
const TestCronStore = struct {
    tmp: TestTmpDir,
    path: []u8,

    fn init() !@This() {
        var tmp = std.testing.tmpDir(.{});
        const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
        defer std.testing.allocator.free(dir_path);
        const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "cron.json" });
        cron.setTestStorePathOverride(path);
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *@This()) void {
        cron.setTestStorePathOverride(null);
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

/// Cron runs tool — shows execution history for a cron job.
pub const CronRunsTool = struct {
    config: ?*const config_mod.Config = null,

    pub const tool_name = "cron_runs";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "List historical runs of a cron job.",
        .use_when = &.{
            "first scenario",
            "second scenario",
        },
        .do_not_use_for = &.{
            "web_search — for web queries",
            "memory_store — for persistence",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("cron_runs", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description = "Inspect recent execution history for a raw scheduled job. Low-level scheduler reporting surface.";
    pub const tool_params =
        \\{"type":"object","properties":{"job_id":{"type":"string","description":"ID of the cron job"},"limit":{"type":"integer","description":"Max runs to show (default 10)"}},"required":["job_id"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *CronRunsTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *CronRunsTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const job_id = root.getString(args, "job_id") orelse
            return ToolResult.fail("Missing 'job_id' parameter");

        const limit: usize = blk: {
            const raw = root.getInt(args, "limit") orelse 10;
            break :blk if (raw > 0) @intCast(raw) else 10;
        };

        const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
            error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
            else => {
                const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{job_id});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
        };
        var scheduler = loaded.scheduler;
        _ = loaded.tenant;
        defer scheduler.deinit();

        const job = scheduler.getJob(job_id) orelse {
            const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{job_id});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        var persisted_runs: ?[]cron.CronRun = null;
        defer if (persisted_runs) |runs| freeRuns(allocator, runs);

        if (loaded.tenant.state_mgr) |mgr| {
            if (loaded.tenant.numeric_user_id) |user_id| {
                const runs = try mgr.listJobRuns(allocator, user_id, job_id, limit);
                if (runs.len > 0) persisted_runs = runs else allocator.free(runs);
            }
        }

        const runs = persisted_runs orelse scheduler.listRuns(job_id, limit);

        if (runs.len == 0) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            const w = buf.writer(allocator);

            const last_run_str: []const u8 = if (job.last_run_secs) |lrs| blk: {
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{lrs});
            } else "never";
            defer if (job.last_run_secs != null) allocator.free(last_run_str);

            const last_status = job.last_status orelse "pending";
            const output_str = if (job.last_output) |o|
                if (o.len > 80) o[0..80] else o
            else
                "(none)";
            try w.print("Job {s} | type={s} | last_run: {s} | last_status: {s}\n", .{
                job_id,
                job.job_type.asStr(),
                last_run_str,
                last_status,
            });
            try w.print("No run history is available for this job yet.\n", .{});
            try w.print("Last output: {s}\n", .{output_str});
            return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
        }

        // Format output
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        // Header with job info
        const last_run_str: []const u8 = if (job.last_run_secs) |lrs| blk: {
            break :blk try std.fmt.allocPrint(allocator, "{d}", .{lrs});
        } else "never";
        defer if (job.last_run_secs != null) allocator.free(last_run_str);

        const last_status = job.last_status orelse "pending";
        try w.print("Job {s} | last_run: {s} | last_status: {s}\n", .{ job_id, last_run_str, last_status });
        try w.print("Recent runs ({d}):\n", .{runs.len});

        for (runs) |run| {
            const output_str = if (run.output) |o|
                if (o.len > 80) o[0..80] else o
            else
                "(none)";
            const duration = run.duration_ms orelse 0;
            try w.print("- Run #{d}: {s} | started: {d} | duration: {d}ms | output: {s}\n", .{
                run.id,
                run.status,
                run.started_at_s,
                duration,
                output_str,
            });
        }

        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }

    fn freeRuns(allocator: std.mem.Allocator, runs: []cron.CronRun) void {
        for (runs) |run| {
            allocator.free(@constCast(run.job_id));
            allocator.free(@constCast(run.status));
            if (run.output) |value| allocator.free(@constCast(value));
        }
        allocator.free(runs);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "cron_runs_requires_job_id" {
    var crt = CronRunsTool{};
    const t = crt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_id") != null);
}

test "cron_runs_not_found" {
    var store = try TestCronStore.init();
    defer store.deinit();
    var crt = CronRunsTool{};
    const t = crt.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"nonexistent-xyz\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
}

test "cron_runs_no_history falls back to persisted last run summary" {
    var store = try TestCronStore.init();
    defer store.deinit();
    const allocator = std.testing.allocator;

    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();
    const job = try scheduler.addJob("* * * * *", "echo test");
    job.last_run_secs = 1234;
    job.last_status = "ok";
    job.last_output = try allocator.dupe(u8, "latest output");
    job.last_output_owned = true;
    const job_id = try allocator.dupe(u8, job.id);
    defer allocator.free(job_id);
    try cron.saveJobs(&scheduler);

    var crt = CronRunsTool{};
    const t = crt.tool();
    const args = try std.fmt.allocPrint(allocator, "{{\"job_id\": \"{s}\"}}", .{job_id});
    defer allocator.free(args);
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    defer if (result.error_msg) |e| allocator.free(e);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "No run history is available") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "last_status: ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Last output: latest output") != null);
}

test "cron_runs_shows_history" {
    const allocator = std.testing.allocator;
    // Create a scheduler with a job and add runs directly (no file I/O)
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/5 * * * *", "echo hello");
    const job_id = job.id;

    try scheduler.addRun(allocator, job_id, 1000, 1001, "success", "hello world", 10);
    try scheduler.addRun(allocator, job_id, 2000, 2002, "error", null, 10);

    // Verify runs are stored
    const runs = scheduler.listRuns(job_id, 10);
    try std.testing.expectEqual(@as(usize, 2), runs.len);
    try std.testing.expectEqualStrings("success", runs[0].status);
    try std.testing.expectEqualStrings("error", runs[1].status);
    try std.testing.expectEqual(@as(u64, 1), runs[0].id);
    try std.testing.expectEqual(@as(u64, 2), runs[1].id);
    try std.testing.expectEqual(@as(i64, 1000), runs[0].started_at_s);
    try std.testing.expectEqual(@as(?i64, 1000), runs[0].duration_ms);
    try std.testing.expectEqualStrings("hello world", runs[0].output.?);
    try std.testing.expect(runs[1].output == null);
}

test "cron_runs tool name" {
    var crt = CronRunsTool{};
    const t = crt.tool();
    try std.testing.expectEqualStrings("cron_runs", t.name());
}

test "cron_runs schema has job_id" {
    var crt = CronRunsTool{};
    const t = crt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "job_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "limit") != null);
}
