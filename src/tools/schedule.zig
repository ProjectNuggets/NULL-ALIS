const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const CronScheduler = cron.CronScheduler;
const loadScheduler = @import("cron_add.zig").loadScheduler;
const message_tool = @import("message.zig");

fn loadSchedulerForContext(allocator: std.mem.Allocator) !struct {
    scheduler: CronScheduler,
    tenant: root.ToolTenantContext,
} {
    const tenant = root.getTenantContext();
    var scheduler = CronScheduler.init(allocator, 1024, true);
    if (tenant.state_mgr) |mgr| {
        if (tenant.numeric_user_id) |user_id| {
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
    return .{ .scheduler = scheduler, .tenant = tenant };
}

fn saveSchedulerForContext(scheduler: *CronScheduler, tenant: root.ToolTenantContext) !void {
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

fn parseMessageCommand(command: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "message ")) return null;
    var content = std.mem.trim(u8, trimmed["message ".len..], " \t\r\n");
    if (content.len >= 2) {
        const first = content[0];
        const last = content[content.len - 1];
        if ((first == '"' or first == '\'') and first == last) {
            content = content[1 .. content.len - 1];
        }
    }
    return std.mem.trim(u8, content, " \t\r\n");
}

fn parseEchoCommand(command: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "echo ")) return null;
    var content = std.mem.trim(u8, trimmed["echo ".len..], " \t\r\n");
    if (content.len >= 2) {
        const first = content[0];
        const last = content[content.len - 1];
        if ((first == '"' or first == '\'') and first == last) {
            content = content[1 .. content.len - 1];
        }
    }
    return std.mem.trim(u8, content, " \t\r\n");
}

fn applyTenantDefaults(
    scheduler: *CronScheduler,
    allocator: std.mem.Allocator,
    job_id: []const u8,
    command: []const u8,
) !void {
    const tenant = root.getTenantContext();
    if (tenant.numeric_user_id == null) return;
    const job = scheduler.getMutableJob(job_id) orelse return;
    job.session_target = .main;

    const turn = message_tool.MessageTool.getTurnContext();
    const reminder_text = parseMessageCommand(command) orelse parseEchoCommand(command) orelse return;
    const reminder_copy = try allocator.dupe(u8, reminder_text);
    errdefer allocator.free(reminder_copy);
    const has_live_target = turn.channel != null and turn.chat_id != null;

    if (parseEchoCommand(command) != null and has_live_target) {
        if (job.delivery_channel_owned) {
            if (job.delivery.channel) |existing| allocator.free(existing);
        }
        if (job.delivery_to_owned) {
            if (job.delivery.to) |existing| allocator.free(existing);
        }
        job.delivery.mode = .always;
        job.delivery.channel = try allocator.dupe(u8, turn.channel.?);
        job.delivery_channel_owned = true;
        job.delivery.to = try allocator.dupe(u8, turn.chat_id.?);
        job.delivery_to_owned = true;
        allocator.free(reminder_copy);
        return;
    }

    allocator.free(job.command);
    job.job_type = .agent;
    job.command = reminder_copy;
    if (job.prompt_owned) {
        if (job.prompt) |existing| allocator.free(existing);
    }
    job.prompt = try std.fmt.allocPrint(allocator, "Send exactly this reminder text to the user with no extra words: {s}", .{reminder_copy});
    job.prompt_owned = true;

    if (turn.channel) |channel| {
        if (job.delivery_channel_owned) {
            if (job.delivery.channel) |existing| allocator.free(existing);
        }
        job.delivery.mode = .always;
        job.delivery.channel = try allocator.dupe(u8, channel);
        job.delivery_channel_owned = true;
    }
    if (turn.chat_id) |chat_id| {
        if (job.delivery_to_owned) {
            if (job.delivery.to) |existing| allocator.free(existing);
        }
        job.delivery.to = try allocator.dupe(u8, chat_id);
        job.delivery_to_owned = true;
    }
}

/// Schedule tool — lets the agent manage recurring and one-shot scheduled tasks.
/// Delegates to the CronScheduler from the cron module for persistent job management.
pub const ScheduleTool = struct {
    pub const tool_name = "schedule";
    pub const tool_description = "Manage scheduled tasks. Actions: create/add/once/list/get/cancel/remove/pause/resume";
    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["create","add","once","list","get","cancel","remove","pause","resume"],"description":"Action to perform"},"expression":{"type":"string","description":"Cron expression for recurring tasks"},"delay":{"type":"string","description":"Delay for one-shot tasks (e.g. '30m', '2h')"},"command":{"type":"string","description":"Shell command to execute"},"id":{"type":"string","description":"Task ID"}},"required":["action"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ScheduleTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(_: *ScheduleTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing 'action' parameter");

        if (std.mem.eql(u8, action, "list")) {
            const loaded = loadSchedulerForContext(allocator) catch {
                return ToolResult.ok("No scheduled jobs.");
            };
            var scheduler = loaded.scheduler;
            defer scheduler.deinit();

            const jobs = scheduler.listJobs();
            if (jobs.len == 0) {
                return ToolResult.ok("No scheduled jobs.");
            }

            // Format job list
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            const w = buf.writer(allocator);
            try w.print("Scheduled jobs ({d}):\n", .{jobs.len});
            for (jobs) |job| {
                const flags: []const u8 = blk: {
                    if (job.paused and job.one_shot) break :blk " [paused, one-shot]";
                    if (job.paused) break :blk " [paused]";
                    if (job.one_shot) break :blk " [one-shot]";
                    break :blk "";
                };
                const status = job.last_status orelse "pending";
                try w.print("- {s} | {s} | status={s}{s} | cmd: {s}\n", .{
                    job.id,
                    job.expression,
                    status,
                    flags,
                    job.command,
                });
            }
            return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
        }

        if (std.mem.eql(u8, action, "get")) {
            const id = root.getString(args, "id") orelse
                return ToolResult.fail("Missing 'id' parameter for get action");

            const loaded = loadSchedulerForContext(allocator) catch {
                const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{id});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            var scheduler = loaded.scheduler;
            defer scheduler.deinit();

            if (scheduler.getJob(id)) |job| {
                const flags: []const u8 = blk: {
                    if (job.paused and job.one_shot) break :blk " [paused, one-shot]";
                    if (job.paused) break :blk " [paused]";
                    if (job.one_shot) break :blk " [one-shot]";
                    break :blk "";
                };
                const status = job.last_status orelse "pending";
                const msg = try std.fmt.allocPrint(allocator, "Job {s} | {s} | next={d} | status={s}{s}\n  cmd: {s}", .{
                    job.id,
                    job.expression,
                    job.next_run_secs,
                    status,
                    flags,
                    job.command,
                });
                return ToolResult{ .success = true, .output = msg };
            }
            const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{id});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        if (std.mem.eql(u8, action, "create") or std.mem.eql(u8, action, "add")) {
            const command = root.getString(args, "command") orelse
                return ToolResult.fail("Missing 'command' parameter");
            const expression = root.getString(args, "expression") orelse
                return ToolResult.fail("Missing 'expression' parameter for cron job");

            const loaded = loadSchedulerForContext(allocator) catch {
                return ToolResult.fail("Failed to load scheduler state");
            };
            var scheduler = loaded.scheduler;
            defer scheduler.deinit();

            const job = scheduler.addJob(expression, command) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to create job: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            try applyTenantDefaults(&scheduler, allocator, job.id, command);
            saveSchedulerForContext(&scheduler, loaded.tenant) catch {};

            const msg = try std.fmt.allocPrint(allocator, "Created job {s} | {s} | cmd: {s}", .{
                job.id,
                job.expression,
                job.command,
            });
            return ToolResult{ .success = true, .output = msg };
        }

        if (std.mem.eql(u8, action, "once")) {
            const command = root.getString(args, "command") orelse
                return ToolResult.fail("Missing 'command' parameter");
            const delay = root.getString(args, "delay") orelse
                return ToolResult.fail("Missing 'delay' parameter for one-shot task");

            const loaded = loadSchedulerForContext(allocator) catch {
                return ToolResult.fail("Failed to load scheduler state");
            };
            var scheduler = loaded.scheduler;
            defer scheduler.deinit();

            const job = scheduler.addOnce(delay, command) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to create one-shot task: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            try applyTenantDefaults(&scheduler, allocator, job.id, command);
            saveSchedulerForContext(&scheduler, loaded.tenant) catch {};

            const msg = try std.fmt.allocPrint(allocator, "Created one-shot task {s} | runs at {d} | cmd: {s}", .{
                job.id,
                job.next_run_secs,
                job.command,
            });
            return ToolResult{ .success = true, .output = msg };
        }

        if (std.mem.eql(u8, action, "cancel") or std.mem.eql(u8, action, "remove")) {
            const id = root.getString(args, "id") orelse
                return ToolResult.fail("Missing 'id' parameter for cancel action");

            const loaded = loadSchedulerForContext(allocator) catch {
                return ToolResult.fail("Failed to load scheduler state");
            };
            var scheduler = loaded.scheduler;
            defer scheduler.deinit();

            if (scheduler.removeJob(id)) {
                saveSchedulerForContext(&scheduler, loaded.tenant) catch {};
                const msg = try std.fmt.allocPrint(allocator, "Cancelled job {s}", .{id});
                return ToolResult{ .success = true, .output = msg };
            }
            const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{id});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        if (std.mem.eql(u8, action, "pause") or std.mem.eql(u8, action, "resume")) {
            const id = root.getString(args, "id") orelse
                return ToolResult.fail("Missing 'id' parameter");

            const loaded = loadSchedulerForContext(allocator) catch {
                return ToolResult.fail("Failed to load scheduler state");
            };
            var scheduler = loaded.scheduler;
            defer scheduler.deinit();

            const is_pause = std.mem.eql(u8, action, "pause");
            const found = if (is_pause) scheduler.pauseJob(id) else scheduler.resumeJob(id);

            if (found) {
                saveSchedulerForContext(&scheduler, loaded.tenant) catch {};
                const verb: []const u8 = if (is_pause) "Paused" else "Resumed";
                const msg = try std.fmt.allocPrint(allocator, "{s} job {s}", .{ verb, id });
                return ToolResult{ .success = true, .output = msg };
            }
            const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{id});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        const msg = try std.fmt.allocPrint(allocator, "Unknown action '{s}'", .{action});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "schedule tool name" {
    var st = ScheduleTool{};
    const t = st.tool();
    try std.testing.expectEqualStrings("schedule", t.name());
}

test "schedule schema has action" {
    var st = ScheduleTool{};
    const t = st.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "action") != null);
}

test "schedule list returns success" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"list\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    // Either "No scheduled jobs." or a formatted job list
    try std.testing.expect(result.output.len > 0);
}

test "schedule unknown action" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"explode\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unknown action") != null);
}

test "schedule create with expression" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"create\", \"expression\": \"*/5 * * * *\", \"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    // Succeeds if HOME/.nullalis is writable, otherwise may fail gracefully
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Created job") != null);
    }
}

// ── Additional schedule tests ───────────────────────────────────

test "schedule missing action" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "action") != null);
}

test "schedule get missing id" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"get\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "id") != null);
}

test "schedule get nonexistent job" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"get\", \"id\": \"nonexistent-123\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
}

test "schedule cancel requires id" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"cancel\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "schedule cancel nonexistent job returns not found" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"cancel\", \"id\": \"job-nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    // Job doesn't exist in the real scheduler, so cancel returns not-found or success if previously created
    if (!result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
    }
}

test "schedule remove nonexistent job returns not found" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"remove\", \"id\": \"job-nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    if (!result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
    }
}

test "schedule pause nonexistent job returns not found" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"pause\", \"id\": \"job-nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    if (!result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
    }
}

test "schedule resume nonexistent job returns not found" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"resume\", \"id\": \"job-nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);
    if (!result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
    }
}

test "schedule once creates one-shot task" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"once\", \"delay\": \"30m\", \"command\": \"echo later\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "one-shot") != null);
    }
}

test "schedule add creates recurring job" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"add\", \"expression\": \"0 * * * *\", \"command\": \"echo hourly\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Created job") != null);
    }
}

test "schedule create missing command" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"create\", \"expression\": \"* * * * *\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "command") != null);
}

test "schedule create missing expression" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"create\", \"command\": \"echo hi\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "expression") != null);
}

test "schedule once missing delay" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"once\", \"command\": \"echo hi\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "delay") != null);
}

test "schedule pause requires id" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"pause\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "schedule resume requires id" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"resume\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "schedule tenant defaults normalize message reminder into agent job" {
    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();

    const job = try scheduler.addOnce("30m", "message \"Meeting starts now\"");

    root.setTenantContext(.{
        .user_id = "15",
        .numeric_user_id = 15,
        .session_key = "agent:zaki-bot:user:15:main",
    });
    defer root.clearTenantContext();

    message_tool.MessageTool.setTurnContext(.{
        .channel = "telegram",
        .chat_id = "chat-15",
    });
    defer message_tool.MessageTool.clearTurnContext();

    try applyTenantDefaults(&scheduler, std.testing.allocator, job.id, job.command);
    const updated = scheduler.getJob(job.id).?;
    try std.testing.expectEqual(cron.JobType.agent, updated.job_type);
    try std.testing.expectEqual(cron.DeliveryMode.always, updated.delivery.mode);
    try std.testing.expectEqualStrings("telegram", updated.delivery.channel.?);
    try std.testing.expectEqualStrings("chat-15", updated.delivery.to.?);
    try std.testing.expectEqualStrings("Meeting starts now", updated.command);
    try std.testing.expect(updated.prompt != null);
}

test "schedule tenant defaults normalize echo reminder into delivery job" {
    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();

    const job = try scheduler.addOnce("30m", "echo \"Meeting starts now\"");

    root.setTenantContext(.{
        .user_id = "15",
        .numeric_user_id = 15,
        .session_key = "agent:zaki-bot:user:15:main",
    });
    defer root.clearTenantContext();

    message_tool.MessageTool.setTurnContext(.{
        .channel = "telegram",
        .chat_id = "chat-15",
    });
    defer message_tool.MessageTool.clearTurnContext();

    try applyTenantDefaults(&scheduler, std.testing.allocator, job.id, job.command);
    const updated = scheduler.getJob(job.id).?;
    try std.testing.expectEqual(cron.JobType.shell, updated.job_type);
    try std.testing.expectEqual(cron.DeliveryMode.always, updated.delivery.mode);
    try std.testing.expectEqualStrings("telegram", updated.delivery.channel.?);
    try std.testing.expectEqualStrings("chat-15", updated.delivery.to.?);
    try std.testing.expectEqualStrings("echo \"Meeting starts now\"", updated.command);
}

test "schedule tenant defaults convert echo without live target into agent reminder" {
    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();

    const job = try scheduler.addOnce("30m", "echo \"Meeting starts now\"");

    root.setTenantContext(.{
        .user_id = "15",
        .numeric_user_id = 15,
        .session_key = "agent:zaki-bot:user:15:main",
    });
    defer root.clearTenantContext();

    message_tool.MessageTool.clearTurnContext();

    try applyTenantDefaults(&scheduler, std.testing.allocator, job.id, job.command);
    const updated = scheduler.getJob(job.id).?;
    try std.testing.expectEqual(cron.JobType.agent, updated.job_type);
    try std.testing.expectEqual(cron.SessionTarget.main, updated.session_target);
    try std.testing.expectEqual(cron.DeliveryMode.none, updated.delivery.mode);
    try std.testing.expectEqualStrings("Meeting starts now", updated.command);
    try std.testing.expect(updated.prompt != null);
}

test "schedule tenant defaults keep normal shell commands intact" {
    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/5 * * * *", "echo-shell-output >/tmp/task.log");

    root.setTenantContext(.{
        .user_id = "15",
        .numeric_user_id = 15,
        .session_key = "agent:zaki-bot:user:15:main",
    });
    defer root.clearTenantContext();

    message_tool.MessageTool.setTurnContext(.{
        .channel = "telegram",
        .chat_id = "chat-15",
    });
    defer message_tool.MessageTool.clearTurnContext();

    try applyTenantDefaults(&scheduler, std.testing.allocator, job.id, job.command);
    const updated = scheduler.getJob(job.id).?;
    try std.testing.expectEqual(cron.JobType.shell, updated.job_type);
    try std.testing.expectEqual(cron.SessionTarget.main, updated.session_target);
    try std.testing.expectEqual(cron.DeliveryMode.none, updated.delivery.mode);
    try std.testing.expectEqualStrings("echo-shell-output >/tmp/task.log", updated.command);
    try std.testing.expect(updated.prompt == null);
}
