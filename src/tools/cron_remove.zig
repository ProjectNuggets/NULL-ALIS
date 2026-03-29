const std = @import("std");
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

/// CronRemove tool — removes a scheduled cron job by its ID.
pub const CronRemoveTool = struct {
    config: ?*const config_mod.Config = null,

    pub const tool_name = "cron_remove";
    pub const tool_description = "Remove a scheduled cron job by its ID.";
    pub const tool_params =
        \\{"type":"object","properties":{"job_id":{"type":"string","description":"ID of the cron job to remove"}},"required":["job_id"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *CronRemoveTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *CronRemoveTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const job_id = root.getString(args, "job_id") orelse
            return ToolResult.fail("Missing required parameter: job_id");

        if (job_id.len == 0)
            return ToolResult.fail("Missing required parameter: job_id");

        const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
            error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
            else => return ToolResult.fail("Failed to load scheduler state"),
        };
        var scheduler = loaded.scheduler;
        const tenant = loaded.tenant;
        defer scheduler.deinit();

        if (scheduler.removeJob(job_id)) {
            saveSchedulerForContext(&scheduler, tenant) catch {};
            const msg = try std.fmt.allocPrint(allocator, "Removed cron job {s}", .{job_id});
            return ToolResult{ .success = true, .output = msg };
        }

        const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{job_id});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "cron_remove_requires_job_id" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try tool_iface.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_id") != null);
}

test "cron_remove_not_found" {
    var store = try TestCronStore.init();
    defer store.deinit();
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"nonexistent-999\"}");
    defer parsed.deinit();
    const result = try tool_iface.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
}

test "cron_remove_success" {
    var store = try TestCronStore.init();
    defer store.deinit();
    // First, create a job via the scheduler directly
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();
    const job = try scheduler.addJob("*/5 * * * *", "echo test");
    const job_id = try std.testing.allocator.dupe(u8, job.id);
    defer std.testing.allocator.free(job_id);
    cron.saveJobs(&scheduler) catch {};

    // Now remove it via the tool
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"job_id\": \"{s}\"}}", .{job_id});
    defer std.testing.allocator.free(args);
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();
    const result = try tool_iface.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Removed") != null);
}

test "cron_remove tool name" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    try std.testing.expectEqualStrings("cron_remove", tool_iface.name());
}

test "cron_remove schema has job_id" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const schema = tool_iface.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "job_id") != null);
}

test "cron_remove empty job_id" {
    var t = CronRemoveTool{};
    const tool_iface = t.tool();
    const parsed = try root.parseTestArgs("{\"job_id\": \"\"}");
    defer parsed.deinit();
    const result = try tool_iface.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "job_id") != null);
}
