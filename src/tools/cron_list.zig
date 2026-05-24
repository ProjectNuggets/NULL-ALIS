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

/// CronList tool — lists all scheduled cron jobs with their status and next run time.
pub const CronListTool = struct {
    config: ?*const config_mod.Config = null,

    pub const tool_name = "cron_list";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Low-level raw-cron inventory: list jobs with type, status, and next-run time.",
        .use_when = &.{
            "Operator inspection of the raw scheduler queue",
            "Pre-flight check before cron_update / cron_remove to confirm job IDs",
            "Debugging why a scheduled job has not fired (status + next-run reveals stale entries)",
        },
        .do_not_use_for = &.{
            "schedule — for the user-facing list of reminders and proactive jobs",
            "cron_runs — for execution history of a specific job rather than the inventory",
            "task_list — for transient task tracking rather than recurring schedules",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("cron_list", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description = "Inspect raw cron jobs, their types, status, and next run time. Low-level scheduler inspection surface.";
    pub const tool_params =
        \\{"type":"object","properties":{}}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *CronListTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *CronListTool, allocator: std.mem.Allocator, _: JsonObjectMap) !ToolResult {
        const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
            error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
            else => {
                return ToolResult{ .success = true, .output = try allocator.dupe(u8, "No scheduled cron jobs.") };
            },
        };
        var scheduler = loaded.scheduler;
        _ = loaded.tenant;
        defer scheduler.deinit();
        if (scheduler.listJobs().len == 0) {
            return ToolResult{ .success = true, .output = try allocator.dupe(u8, "No scheduled cron jobs.") };
        }
        const jobs = scheduler.listJobs();

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        for (jobs) |job| {
            const runtime_status: []const u8 = if (job.paused) "paused" else "enabled";
            const last_status = job.last_status orelse "pending";
            try w.print("- {s} | {s} | type={s} | runtime={s} | last_status={s} | next: {d} | cmd: {s}\n", .{
                job.id,
                job.expression,
                job.job_type.asStr(),
                runtime_status,
                last_status,
                job.next_run_secs,
                job.command,
            });
        }
        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "cron_list_empty" {
    // An empty scheduler should produce no formatted output
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const jobs = scheduler.listJobs();
    try std.testing.expectEqual(@as(usize, 0), jobs.len);
}

test "cron_list_with_jobs" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/5 * * * *", "echo hello");
    job.last_status = "ok";
    try std.testing.expect(scheduler.listJobs().len == 1);

    // Format output the same way the tool does, to verify content
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    const runtime_status: []const u8 = if (job.paused) "paused" else "enabled";
    const last_status = job.last_status orelse "pending";
    try w.print("- {s} | {s} | type={s} | runtime={s} | last_status={s} | next: {d} | cmd: {s}\n", .{
        job.id,
        job.expression,
        job.job_type.asStr(),
        runtime_status,
        last_status,
        job.next_run_secs,
        job.command,
    });
    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, job.id) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "enabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "type=shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "last_status=ok") != null);
}

test "cron_list_shows_paused" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("0 * * * *", "echo paused_test");
    try std.testing.expectEqual(cron.JobPauseResumeResult.changed, scheduler.pauseJob(job.id));

    const jobs = scheduler.listJobs();
    try std.testing.expect(jobs.len == 1);
    try std.testing.expect(jobs[0].paused);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    const runtime_status: []const u8 = if (jobs[0].paused) "paused" else "enabled";
    const last_status = jobs[0].last_status orelse "pending";
    try w.print("- {s} | {s} | type={s} | runtime={s} | last_status={s} | next: {d} | cmd: {s}\n", .{
        jobs[0].id,
        jobs[0].expression,
        jobs[0].job_type.asStr(),
        runtime_status,
        last_status,
        jobs[0].next_run_secs,
        jobs[0].command,
    });
    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "paused") != null);
}

test "cron_list tool name" {
    var cl = CronListTool{};
    const t = cl.tool();
    try std.testing.expectEqualStrings("cron_list", t.name());
}

test "cron_list tool parameters" {
    var cl = CronListTool{};
    const t = cl.tool();
    const params = t.parametersJson();
    try std.testing.expect(params[0] == '{');
}

test "cron_list execute returns success" {
    var store = try TestCronStore.init();
    defer store.deinit();
    var cl = CronListTool{};
    const t = cl.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    // Either "No scheduled cron jobs." or a formatted job list
    try std.testing.expect(result.output.len > 0);
}
