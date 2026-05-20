const std = @import("std");
const platform = @import("../platform.zig");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const CronScheduler = cron.CronScheduler;
const loadSchedulerForContext = @import("cron_add.zig").loadSchedulerForContext;
const saveSchedulerForContext = @import("cron_add.zig").saveSchedulerForContext;
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

/// CronRun tool — force-runs a cron job immediately by its ID, regardless of schedule.
pub const CronRunTool = struct {
    config: ?*const config_mod.Config = null,

    pub const tool_name = "cron_run";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Trigger a cron job immediately.",
        .use_when = &.{
            "first scenario",
            "second scenario",
        },
        .do_not_use_for = &.{
            "web_search — for external queries",
            "memory_store — for persistence",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("cron_run", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description = "Low-level raw cron operator tool. Force-run a raw cron job immediately by ID; agent-managed jobs must run through the scheduler/runtime path.";
    pub const tool_params =
        \\{"type":"object","properties":{"job_id":{"type":"string","description":"The ID of the cron job to run"}},"required":["job_id"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *CronRunTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *CronRunTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const job_id = root.getString(args, "job_id") orelse
            return ToolResult.fail("Missing 'job_id' parameter");

        const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
            error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
            else => return ToolResult.fail("Failed to load scheduler state"),
        };
        var scheduler = loaded.scheduler;
        const tenant = loaded.tenant;
        defer scheduler.deinit();

        // Check that the job exists
        const job = scheduler.getJob(job_id) orelse {
            const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{job_id});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        if (job.job_type == .agent) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Job {s} is agent-managed. Raw cron cannot execute it manually; use the normal scheduler/runtime path instead.",
                .{job_id},
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        // Execute the command
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ platform.getShell(), platform.getShellFlag(), job.command },
            .max_output_bytes = 65536,
        }) catch |err| {
            // Update last_status to error
            if (scheduler.getMutableJob(job_id)) |mutable_job| {
                mutable_job.last_status = "error";
                mutable_job.last_run_secs = std.time.timestamp();
            }
            saveSchedulerForContext(&scheduler, tenant) catch {};

            const msg = try std.fmt.allocPrint(allocator, "Job '{s}' execution failed: {s}", .{ job_id, @errorName(err) });
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code: u8 = switch (result.term) {
            .Exited => |code| code,
            else => 1,
        };
        const success = exit_code == 0;
        const status_str: []const u8 = if (success) "ok" else "error";

        // Update job last_run and last_status
        if (scheduler.getMutableJob(job_id)) |mutable_job| {
            mutable_job.last_status = status_str;
            mutable_job.last_run_secs = std.time.timestamp();
        }
        saveSchedulerForContext(&scheduler, tenant) catch {};

        const status_label: []const u8 = if (success) "ok" else "error";
        const output = if (result.stdout.len > 0) result.stdout else result.stderr;
        const msg = try std.fmt.allocPrint(allocator, "Job {s} ran: {s} (exit {d})\n{s}", .{
            job_id,
            status_label,
            exit_code,
            output,
        });
        return ToolResult{ .success = true, .output = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "cron_run tool name" {
    var crt = CronRunTool{};
    const t = crt.tool();
    try std.testing.expectEqualStrings("cron_run", t.name());
}

test "cron_run schema has job_id" {
    var crt = CronRunTool{};
    const t = crt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "job_id") != null);
}

test "cron_run_requires_job_id" {
    var crt = CronRunTool{};
    const t = crt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_id") != null);
}

test "cron_run_not_found" {
    var store = try TestCronStore.init();
    defer store.deinit();
    var crt = CronRunTool{};
    const t = crt.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"nonexistent-xyz\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
}

test "cron_run_executes_command" {
    var store = try TestCronStore.init();
    defer store.deinit();
    // Create a scheduler with a job, save it, then run via tool
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();
    cron.loadJobs(&scheduler) catch {};

    const job = try scheduler.addJob("*/5 * * * *", "echo hello");
    const job_id = try std.testing.allocator.dupe(u8, job.id);
    defer std.testing.allocator.free(job_id);

    try cron.saveJobs(&scheduler);

    // Now execute the cron_run tool
    var crt = CronRunTool{};
    const t = crt.tool();
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"job_id\": \"{s}\"}}", .{job_id});
    defer std.testing.allocator.free(args);
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();

    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);

    var loaded = CronScheduler.init(std.testing.allocator, 10, true);
    defer loaded.deinit();
    try cron.loadJobsStrict(&loaded);
    const loaded_job = loaded.getJob(job_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(loaded_job.last_run_secs != null);
    try std.testing.expect(loaded_job.last_status != null);
    try std.testing.expectEqualStrings("ok", loaded_job.last_status.?);
}

test "cron_run returns guidance for agent jobs without executing them" {
    var store = try TestCronStore.init();
    defer store.deinit();

    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/5 * * * *", "daily_morning_brief");
    job.job_type = .agent;
    job.prompt = try std.testing.allocator.dupe(u8, "Prepare the morning brief");
    job.prompt_owned = true;
    const job_id = try std.testing.allocator.dupe(u8, job.id);
    defer std.testing.allocator.free(job_id);

    try cron.saveJobs(&scheduler);

    var crt = CronRunTool{};
    const t = crt.tool();
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"job_id\": \"{s}\"}}", .{job_id});
    defer std.testing.allocator.free(args);
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();

    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "agent-managed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "cannot execute it manually") != null);

    var loaded = CronScheduler.init(std.testing.allocator, 10, true);
    defer loaded.deinit();
    try cron.loadJobsStrict(&loaded);
    const loaded_job = loaded.getJob(job_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(loaded_job.last_run_secs == null);
    try std.testing.expect(loaded_job.last_status == null);
}
