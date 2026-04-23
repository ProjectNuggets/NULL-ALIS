const std = @import("std");
const build_options = @import("build_options");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const CronScheduler = cron.CronScheduler;
const config_mod = @import("../config.zig");
const entitlement_mod = @import("../entitlement.zig");

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

/// CronAdd tool — creates a new cron job with either a cron expression or a delay.
pub const CronAddTool = struct {
    config: ?*const config_mod.Config = null,

    pub const tool_name = "cron_add";
    pub const tool_description = "Low-level raw cron tool for operator or debug use. Create a scheduled raw command job with either 'expression' (cron syntax) or 'delay' (e.g. '30m', '2h') plus 'command'.";
    pub const tool_params =
        \\{"type":"object","properties":{"expression":{"type":"string","description":"Cron expression (e.g. '*/5 * * * *')"},"delay":{"type":"string","description":"Delay for one-shot tasks (e.g. '30m', '2h')"},"command":{"type":"string","description":"Raw command for the scheduler to run; prefer the schedule tool for user-facing reminders, briefs, and proactive jobs"},"name":{"type":"string","description":"Optional job name"}},"required":["command"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *CronAddTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *CronAddTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const command = root.getString(args, "command") orelse
            return ToolResult.fail("Missing required 'command' parameter");

        const expression = root.getString(args, "expression");
        const delay = root.getString(args, "delay");

        if (expression == null and delay == null)
            return ToolResult.fail("Missing schedule: provide either 'expression' (cron syntax) or 'delay' (e.g. '30m')");

        // Validate expression if provided
        if (expression) |expr| {
            _ = cron.normalizeExpression(expr) catch
                return ToolResult.fail("Invalid cron expression");
        }

        // Validate delay if provided
        if (delay) |d| {
            _ = cron.parseDuration(d) catch
                return ToolResult.fail("Invalid delay format");
        }

        const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
            error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
            else => return ToolResult.fail("Failed to load scheduler state"),
        };
        var scheduler = loaded.scheduler;
        const tenant = loaded.tenant;
        defer scheduler.deinit();

        // Per-tier active-jobs cap enforcement (S2.11). The aspirational "64
        // active jobs per user" from reliability-ops-runbook.md:108 had no
        // enforcement anywhere (P4_ops_truth drift #3). Entitlement-resolved
        // cap: free=4, pro=64, team=256, enterprise=unlimited. canceled/
        // expired collapse to free automatically via effectiveTier.
        const turn_ctx = root.getTurnContext();
        const now_unix = std.time.timestamp();
        const effective_tier = turn_ctx.entitlement.effectiveTier(now_unix);
        const active_cap = entitlement_mod.Entitlement.limitsFor(effective_tier).active_jobs_cap;
        if (scheduler.jobs.items.len >= active_cap) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Active job cap reached: {d}/{d} jobs for tier '{s}'. Remove a job with /cron remove before adding another, or upgrade for a higher cap.",
                .{ scheduler.jobs.items.len, active_cap, effective_tier.toSlice() },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        // Prefer expression (recurring) over delay (one-shot)
        if (expression) |expr| {
            const job = scheduler.addJob(expr, command) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to create job: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            saveSchedulerForContext(&scheduler, tenant) catch {};

            const msg = try std.fmt.allocPrint(allocator, "Created cron job {s}: {s} \u{2192} {s}", .{
                job.id,
                job.expression,
                job.command,
            });
            return ToolResult{ .success = true, .output = msg };
        }

        if (delay) |d| {
            const job = scheduler.addOnce(d, command) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to create one-shot task: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            saveSchedulerForContext(&scheduler, tenant) catch {};

            const msg = try std.fmt.allocPrint(allocator, "Created cron job {s}: {s} \u{2192} {s}", .{
                job.id,
                job.expression,
                job.command,
            });
            return ToolResult{ .success = true, .output = msg };
        }

        return ToolResult.fail("Unexpected state: no expression or delay");
    }
};

/// Load the CronScheduler from persisted state (~/.nullalis/cron.json).
/// Shared by cron_add, cron_list, cron_remove, and schedule tools.
pub fn loadScheduler(allocator: std.mem.Allocator) !CronScheduler {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    cron.loadJobs(&scheduler) catch {};
    return scheduler;
}

pub const LoadedSchedulerContext = struct {
    scheduler: CronScheduler,
    tenant: root.ToolTenantContext,
};

fn resolveSchedulerMaxTasks(config: ?*const config_mod.Config) usize {
    if (config) |cfg| return @max(@as(usize, 1), cfg.scheduler.max_tasks);
    return 1024;
}

pub fn loadSchedulerForContext(allocator: std.mem.Allocator, config: ?*const config_mod.Config) !LoadedSchedulerContext {
    const tenant = root.getTenantContext();
    const cfg = config orelse null;
    const tenant_postgres_expected = blk: {
        if (tenant.expect_postgres_state) break :blk true;
        if (cfg) |resolved| {
            if (resolved.tenant.enabled and std.mem.eql(u8, resolved.state.backend, "postgres") and build_options.enable_postgres and tenant.user_id != null) {
                break :blk true;
            }
        }
        break :blk false;
    };
    if (tenant_postgres_expected and (tenant.state_mgr == null or tenant.numeric_user_id == null)) {
        return error.MissingTenantStateContext;
    }

    const max_tasks = resolveSchedulerMaxTasks(config);
    var scheduler = CronScheduler.init(allocator, max_tasks, true);
    if (tenant.state_mgr) |mgr| {
        if (tenant.numeric_user_id) |user_id| {
            scheduler.max_tasks = max_tasks;
            const jobs_json = try mgr.getJobsJson(allocator, user_id);
            defer allocator.free(jobs_json);
            const trimmed = std.mem.trim(u8, jobs_json, " \t\r\n");
            if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "[]")) {
                const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
                defer parsed.deinit();
                if (parsed.value == .array) {
                    for (parsed.value.array.items) |item| {
                        if (item == .object) {
                            try cron.appendJobFromJsonObject(&scheduler, item.object);
                        }
                    }
                }
            }
            return .{ .scheduler = scheduler, .tenant = tenant };
        }
    }

    scheduler = loadScheduler(allocator) catch scheduler;
    scheduler.max_tasks = max_tasks;
    return .{ .scheduler = scheduler, .tenant = tenant };
}

pub fn saveSchedulerForContext(scheduler: *CronScheduler, tenant: root.ToolTenantContext) !void {
    if (tenant.state_mgr) |mgr| {
        if (tenant.numeric_user_id) |user_id| {
            const session_key = tenant.session_key orelse "agent:zaki-bot:main";
            const content = try cron.saveJobsToSlice(scheduler.allocator, scheduler);
            defer scheduler.allocator.free(content);
            try mgr.replaceJobsJson(user_id, session_key, content);
            return;
        }
    }
    try cron.saveJobs(scheduler);
}

// ── Tests ───────────────────────────────────────────────────────────

test "cron_add_requires_command" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"expression\": \"*/5 * * * *\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "command") != null);
}

test "cron_add_requires_schedule" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "expression") != null or
        std.mem.indexOf(u8, result.error_msg.?, "delay") != null);
}

test "cron_add_with_expression" {
    var store = try TestCronStore.init();
    defer store.deinit();
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"expression\": \"*/5 * * * *\", \"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Created cron job") != null);
    }
}

test "cron_add_with_delay" {
    var store = try TestCronStore.init();
    defer store.deinit();
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"delay\": \"30m\", \"command\": \"echo later\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Created cron job") != null);
    }
}

test "cron_add_rejects_invalid_expression" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"expression\": \"bad cron\", \"command\": \"echo fail\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid cron expression") != null);
}

test "cron_add tool name" {
    var cat = CronAddTool{};
    const t = cat.tool();
    try std.testing.expectEqualStrings("cron_add", t.name());
}

test "cron_add schema has command" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "command") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "expression") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "delay") != null);
}
