const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const CronScheduler = cron.CronScheduler;
const loadSchedulerForContext = @import("cron_add.zig").loadSchedulerForContext;
const config_mod = @import("../config.zig");
const text_norm = @import("../memory/text_norm.zig");

const DEFAULT_LIST_LIMIT: usize = 25;
const MAX_LIST_LIMIT: usize = 100;
const COMMAND_PREVIEW_BYTES: usize = 240;

const ListPagination = struct {
    limit: usize = DEFAULT_LIST_LIMIT,
    offset: usize = 0,
};

fn parseListPagination(args: JsonObjectMap) ListPagination {
    var page = ListPagination{};
    if (root.getInt(args, "limit")) |limit_raw| {
        if (limit_raw > 0) {
            page.limit = @min(@as(usize, @intCast(limit_raw)), MAX_LIST_LIMIT);
        }
    }
    if (root.getInt(args, "offset")) |offset_raw| {
        if (offset_raw > 0) {
            page.offset = @as(usize, @intCast(offset_raw));
        }
    }
    return page;
}

fn listPageBounds(total_count: usize, page: ListPagination) struct { shown_count: usize, end: usize, partial: bool } {
    if (page.offset >= total_count) return .{ .shown_count = 0, .end = page.offset, .partial = false };
    const remaining = total_count - page.offset;
    const shown_count = @min(page.limit, remaining);
    const end = page.offset + shown_count;
    return .{
        .shown_count = shown_count,
        .end = end,
        .partial = end < total_count,
    };
}

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
        \\{"type":"object","properties":{"limit":{"type":"integer","description":"Max jobs to show (default 25, max 100)"},"offset":{"type":"integer","description":"Zero-based pagination offset"}}}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *CronListTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *CronListTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
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
        const page = parseListPagination(args);
        const bounds = listPageBounds(jobs.len, page);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        try w.print("Cron jobs: total_count={d} shown_count={d} limit={d} offset={d} next_offset=", .{
            jobs.len,
            bounds.shown_count,
            page.limit,
            page.offset,
        });
        if (bounds.partial) {
            try w.print("{d}", .{bounds.end});
        } else {
            try w.writeAll("null");
        }
        try w.print(" partial={s}\n", .{if (bounds.partial) "true" else "false"});

        if (bounds.shown_count == 0) {
            try w.writeAll("No cron jobs on this page.\n");
        }

        if (bounds.shown_count > 0) {
            for (jobs[page.offset..bounds.end]) |job| {
                const runtime_status: []const u8 = if (job.paused) "paused" else "enabled";
                const last_status = job.last_status orelse "pending";
                const command_preview = text_norm.truncateUtf8(job.command, COMMAND_PREVIEW_BYTES);
                try w.print("- {s} | {s} | type={s} | runtime={s} | last_status={s} | next: {d} | cmd_preview: {s}{s}\n", .{
                    job.id,
                    job.expression,
                    job.job_type.asStr(),
                    runtime_status,
                    last_status,
                    job.next_run_secs,
                    command_preview,
                    if (job.command.len > command_preview.len) "..." else "",
                });
            }
        }
        if (bounds.partial) {
            try w.print("partial:true original_count={d} shown_count={d} next_offset={d}. Fetch next page with cron_list offset={d} limit={d}. Use schedule action=get id=<job_id> for exact command/details when available.\n", .{
                jobs.len,
                bounds.shown_count,
                bounds.end,
                bounds.end,
                page.limit,
            });
        } else if (jobs.len > 0) {
            try w.writeAll("Use schedule action=get id=<job_id> for exact command/details when available.\n");
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

test "cron_list bounds large inventory with pagination metadata" {
    var store = try TestCronStore.init();
    defer store.deinit();

    var scheduler = CronScheduler.init(std.testing.allocator, 400, true);
    defer scheduler.deinit();
    var i: usize = 0;
    while (i < 313) : (i += 1) {
        const command = try std.fmt.allocPrint(std.testing.allocator, "echo cron-{d:0>3} {s}", .{ i, "x" ** 300 });
        defer std.testing.allocator.free(command);
        _ = try scheduler.addJob("*/5 * * * *", command);
    }
    try cron.saveJobsToPath(&scheduler, store.path);

    var cl = CronListTool{};
    const t = cl.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "total_count=313") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "shown_count=25") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "next_offset=25") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "partial=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "cmd_preview:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "cron-025") == null);
    try std.testing.expect(result.output.len < 20_000);
}
