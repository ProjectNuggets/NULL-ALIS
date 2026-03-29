const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const CronScheduler = cron.CronScheduler;
const loadSchedulerForContext = @import("cron_add.zig").loadSchedulerForContext;
const saveSchedulerForContext = @import("cron_add.zig").saveSchedulerForContext;
const message_tool = @import("message.zig");
const runtime_resolver = @import("../delivery/runtime_resolver.zig");
const config_mod = @import("../config.zig");
const morning_brief = @import("../morning_brief.zig");

const MIN_ONCE_DELAY_SECS: i64 = 60;
const MORNING_BRIEF_JOB_ID = morning_brief.MORNING_BRIEF_JOB_ID;
const MORNING_BRIEF_AGENT_COMMAND = morning_brief.MORNING_BRIEF_AGENT_COMMAND;
const MORNING_BRIEF_AGENT_PROMPT = morning_brief.MORNING_BRIEF_AGENT_PROMPT;

fn validateOnceDelay(delay: []const u8) !void {
    const delay_secs = try cron.parseDuration(delay);
    if (delay_secs < MIN_ONCE_DELAY_SECS) return error.DelayTooShort;
}

fn normalizeIdToken(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n");
}

fn isMorningBriefId(id: []const u8) bool {
    return morning_brief.isMorningBriefId(normalizeIdToken(id));
}

fn shouldCanonicalizeMorningBrief(requested_id: ?[]const u8, created_job_id: []const u8, command: []const u8) bool {
    return morning_brief.shouldCanonicalize(requested_id, created_job_id, command);
}

const TelegramDeliveryTarget = struct {
    account_id: []const u8 = "main",
    account_id_owned: bool = false,
    chat_id: []u8,

    fn deinit(self: *TelegramDeliveryTarget, allocator: std.mem.Allocator) void {
        if (self.account_id_owned) allocator.free(self.account_id);
        allocator.free(self.chat_id);
    }
};

fn maxTasksReachedError(allocator: std.mem.Allocator, max_tasks: usize) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Scheduler at max capacity ({d} jobs). Remove old jobs or increase scheduler.max_tasks.",
        .{max_tasks},
    );
}

fn resolveTelegramDeliveryTarget(allocator: std.mem.Allocator, tenant: root.ToolTenantContext) !?TelegramDeliveryTarget {
    const turn = message_tool.MessageTool.getTurnContext();
    const target_hint = if (turn.channel != null and std.ascii.eqlIgnoreCase(turn.channel.?, "telegram")) turn.chat_id else null;
    var resolved = runtime_resolver.resolveRuntimeDeliveryContext(allocator, .{
        .channel = "telegram",
        .tenant_ctx = .{
            .state_mgr = tenant.state_mgr,
            .numeric_user_id = tenant.numeric_user_id,
            .expect_postgres_state = tenant.expect_postgres_state,
        },
        .target_hint = target_hint,
    }) catch return null;
    defer resolved.deinit(allocator);

    runtime_resolver.requireConnectedTarget(&resolved) catch return null;
    const chat_id_text = resolved.target_id orelse return null;

    var target = TelegramDeliveryTarget{
        .chat_id = try allocator.dupe(u8, chat_id_text),
    };
    errdefer target.deinit(allocator);

    if (resolved.account_id) |account_id| {
        target.account_id = try allocator.dupe(u8, account_id);
        target.account_id_owned = true;
    }
    return target;
}

fn normalizeMorningBriefJob(
    scheduler: *CronScheduler,
    allocator: std.mem.Allocator,
    tenant: root.ToolTenantContext,
    job_id: []const u8,
) !void {
    const job = scheduler.getMutableJob(job_id) orelse return error.JobNotFound;
    job.session_target = .isolated;
    job.wake_mode = .now;
    job.job_type = .agent;

    allocator.free(job.command);
    job.command = try allocator.dupe(u8, MORNING_BRIEF_AGENT_COMMAND);

    if (job.prompt_owned) {
        if (job.prompt) |existing| allocator.free(existing);
    }
    job.prompt = try allocator.dupe(u8, MORNING_BRIEF_AGENT_PROMPT);
    job.prompt_owned = true;

    if (job.delivery_channel_owned) {
        if (job.delivery.channel) |existing| allocator.free(existing);
    }
    job.delivery.mode = .always;
    job.delivery.best_effort = true;
    job.delivery.channel = try allocator.dupe(u8, "telegram");
    job.delivery_channel_owned = true;
    if (try resolveTelegramDeliveryTarget(allocator, tenant)) |resolved_target| {
        var target = resolved_target;
        defer target.deinit(allocator);
        if (job.delivery_to_owned) {
            if (job.delivery.to) |existing| allocator.free(existing);
        }
        job.delivery.to = try allocator.dupe(u8, target.chat_id);
        job.delivery_to_owned = true;
    }

    job.last_status = null;
    job.cooldown_until_secs = null;
    job.consecutive_failures = 0;
    job.burst_count_in_window = 0;
    job.burst_window_start_secs = 0;
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
    job.session_target = .isolated;

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
    config: ?*const config_mod.Config = null,

    pub const tool_name = "schedule";
    pub const tool_description = "Manage scheduled tasks for the user. Preferred tool for reminders, briefs, recurring follow-ups, and other proactive jobs. Tasks may be agent-managed, delivery-managed, or raw commands depending on the request.";
    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["create","add","once","list","get","cancel","remove","pause","resume"],"description":"Action to perform"},"expression":{"type":"string","description":"Cron expression for recurring tasks"},"delay":{"type":"string","description":"Delay for one-shot tasks (e.g. '30m', '2h')"},"command":{"type":"string","description":"Task intent, reminder text, agent prompt, delivery text, or raw command depending on the task type"},"id":{"type":"string","description":"Task ID (optional deterministic ID for create/add/once, required for get/cancel/pause/resume)"}},"required":["action"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ScheduleTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ScheduleTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing 'action' parameter");

        if (std.mem.eql(u8, action, "list")) {
            const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
                error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
                else => return ToolResult.ok("No scheduled jobs."),
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

            const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
                error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
                else => {
                    const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{id});
                    return ToolResult{ .success = false, .output = "", .error_msg = msg };
                },
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
            const requested_id_raw = normalizeRequestedId(root.getString(args, "id"));
            const morning_brief_request = shouldCanonicalizeMorningBrief(requested_id_raw, requested_id_raw orelse "", command);
            const requested_id: ?[]const u8 = if (morning_brief_request) MORNING_BRIEF_JOB_ID else requested_id_raw;

            const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
                error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
                else => return ToolResult.fail("Failed to load scheduler state"),
            };
            var scheduler = loaded.scheduler;
            defer scheduler.deinit();

            if (morning_brief_request) {
                while (findMorningBriefJob(scheduler.listJobs())) |existing| {
                    if (!existing.enabled) {
                        const inactive_id = try allocator.dupe(u8, existing.id);
                        defer allocator.free(inactive_id);
                        _ = scheduler.removeJob(inactive_id);
                        continue;
                    }
                    normalizeMorningBriefJob(&scheduler, allocator, loaded.tenant, existing.id) catch {};
                    saveSchedulerForContext(&scheduler, loaded.tenant) catch {};
                    const msg = try std.fmt.allocPrint(allocator, "Job {s} already exists | {s} | cmd: {s}", .{
                        existing.id,
                        existing.expression,
                        existing.command,
                    });
                    return ToolResult{ .success = true, .output = msg };
                }
            }

            if (requested_id) |id| {
                if (scheduler.getJob(id)) |existing| {
                    if (!existing.enabled) {
                        _ = scheduler.removeJob(id);
                    } else {
                        const msg = try std.fmt.allocPrint(allocator, "Job {s} already exists | {s} | cmd: {s}", .{
                            existing.id,
                            existing.expression,
                            existing.command,
                        });
                        return ToolResult{ .success = true, .output = msg };
                    }
                }
            }

            if (findMatchingRecurringJob(scheduler.listJobs(), expression, command)) |existing| {
                const msg = try std.fmt.allocPrint(allocator, "Job already exists {s} | {s} | cmd: {s}", .{
                    existing.id,
                    existing.expression,
                    existing.command,
                });
                return ToolResult{ .success = true, .output = msg };
            }

            const job = scheduler.addJob(expression, command) catch |err| {
                if (err == error.MaxTasksReached) {
                    const msg = try maxTasksReachedError(allocator, scheduler.max_tasks);
                    return ToolResult{ .success = false, .output = "", .error_msg = msg };
                }
                const msg = try std.fmt.allocPrint(allocator, "Failed to create job: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            if (requested_id) |id| {
                allocator.free(job.id);
                job.id = try allocator.dupe(u8, id);
            }

            if (shouldCanonicalizeMorningBrief(requested_id, job.id, command)) {
                normalizeMorningBriefJob(&scheduler, allocator, loaded.tenant, job.id) catch |err| {
                    _ = scheduler.removeJob(job.id);
                    const message = switch (err) {
                        else => "Failed to normalize morning-brief job",
                    };
                    const msg = try allocator.dupe(u8, message);
                    return ToolResult{ .success = false, .output = "", .error_msg = msg };
                };
            } else {
                try applyTenantDefaults(&scheduler, allocator, job.id, command);
            }
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
            const requested_id_raw = normalizeRequestedId(root.getString(args, "id"));
            const morning_brief_request = shouldCanonicalizeMorningBrief(requested_id_raw, requested_id_raw orelse "", command);
            const requested_id: ?[]const u8 = if (morning_brief_request) MORNING_BRIEF_JOB_ID else requested_id_raw;
            validateOnceDelay(delay) catch {
                return ToolResult.fail("Delay too short; minimum is 60s");
            };

            const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
                error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
                else => return ToolResult.fail("Failed to load scheduler state"),
            };
            var scheduler = loaded.scheduler;
            defer scheduler.deinit();

            if (morning_brief_request) {
                while (findMorningBriefJob(scheduler.listJobs())) |existing| {
                    if (!existing.enabled) {
                        const inactive_id = try allocator.dupe(u8, existing.id);
                        defer allocator.free(inactive_id);
                        _ = scheduler.removeJob(inactive_id);
                        continue;
                    }
                    normalizeMorningBriefJob(&scheduler, allocator, loaded.tenant, existing.id) catch {};
                    saveSchedulerForContext(&scheduler, loaded.tenant) catch {};
                    const msg = try std.fmt.allocPrint(allocator, "Job {s} already exists | {s} | cmd: {s}", .{
                        existing.id,
                        existing.expression,
                        existing.command,
                    });
                    return ToolResult{ .success = true, .output = msg };
                }
            }

            if (requested_id) |id| {
                if (scheduler.getJob(id)) |existing| {
                    if (!existing.enabled) {
                        _ = scheduler.removeJob(id);
                    } else {
                        const msg = try std.fmt.allocPrint(allocator, "Job {s} already exists | {s} | cmd: {s}", .{
                            existing.id,
                            existing.expression,
                            existing.command,
                        });
                        return ToolResult{ .success = true, .output = msg };
                    }
                }
            }

            const job = scheduler.addOnce(delay, command) catch |err| {
                if (err == error.MaxTasksReached) {
                    const msg = try maxTasksReachedError(allocator, scheduler.max_tasks);
                    return ToolResult{ .success = false, .output = "", .error_msg = msg };
                }
                const msg = try std.fmt.allocPrint(allocator, "Failed to create one-shot task: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            if (requested_id) |id| {
                allocator.free(job.id);
                job.id = try allocator.dupe(u8, id);
            }

            if (shouldCanonicalizeMorningBrief(requested_id, job.id, command)) {
                normalizeMorningBriefJob(&scheduler, allocator, loaded.tenant, job.id) catch |err| {
                    _ = scheduler.removeJob(job.id);
                    const message = switch (err) {
                        else => "Failed to normalize morning-brief job",
                    };
                    const msg = try allocator.dupe(u8, message);
                    return ToolResult{ .success = false, .output = "", .error_msg = msg };
                };
            } else {
                try applyTenantDefaults(&scheduler, allocator, job.id, command);
            }
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

            const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
                error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
                else => return ToolResult.fail("Failed to load scheduler state"),
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

            const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
                error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
                else => return ToolResult.fail("Failed to load scheduler state"),
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

fn normalizeRequestedId(raw: ?[]const u8) ?[]const u8 {
    const value = raw orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn findMatchingRecurringJob(
    jobs: []const cron.CronJob,
    expression: []const u8,
    command: []const u8,
) ?*const cron.CronJob {
    for (jobs) |*job| {
        if (!job.enabled) continue;
        if (job.one_shot) continue;
        if (!std.mem.eql(u8, job.expression, expression)) continue;
        if (!std.mem.eql(u8, job.command, command)) continue;
        return job;
    }
    return null;
}

fn findMorningBriefJob(jobs: []const cron.CronJob) ?*const cron.CronJob {
    for (jobs) |*job| {
        if (isMorningBriefId(job.id)) return job;
        if (morning_brief.commandLooksMorningBrief(job.command)) return job;
    }
    return null;
}

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

test "schedule fails fast when postgres tenant context is missing" {
    var st = ScheduleTool{};
    const t = st.tool();
    root.setTenantContext(.{
        .user_id = "42",
        .expect_postgres_state = true,
    });
    defer root.clearTenantContext();

    const parsed = try root.parseTestArgs("{\"action\":\"list\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "context") != null);
}

test "schedule validateOnceDelay enforces minimum" {
    try std.testing.expectError(error.DelayTooShort, validateOnceDelay("10s"));
    try validateOnceDelay("60s");
}

test "schedule normalizeRequestedId trims and drops empty values" {
    try std.testing.expect(normalizeRequestedId(null) == null);
    try std.testing.expect(normalizeRequestedId("   ") == null);
    try std.testing.expectEqualStrings("morning-brief", normalizeRequestedId("  morning-brief  ").?);
}

test "schedule canonicalization does not treat generic heartbeat commands as morning brief" {
    try std.testing.expect(shouldCanonicalizeMorningBrief(null, "job-1", "send morning brief at 8"));
    try std.testing.expect(shouldCanonicalizeMorningBrief(null, "job-1", "daily_morning_brief"));
    try std.testing.expect(!shouldCanonicalizeMorningBrief(null, "job-1", "heartbeat run now"));
}

test "schedule canonicalization trigger matches id legacy and semantic hints" {
    try std.testing.expect(shouldCanonicalizeMorningBrief("morning-brief", "job-1", "echo hello"));
    try std.testing.expect(shouldCanonicalizeMorningBrief(null, "job-1", "schedule morning-brief"));
    try std.testing.expect(shouldCanonicalizeMorningBrief(null, "job-1", "daily_morning_brief"));
    try std.testing.expect(shouldCanonicalizeMorningBrief(null, "job-1", "send morning brief at 8"));
    try std.testing.expect(!shouldCanonicalizeMorningBrief(null, "job-1", "echo hello"));
}

test "schedule findMatchingRecurringJob returns recurring exact match only" {
    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();

    _ = try scheduler.addJob("0 8 * * *", "send morning brief");
    _ = try scheduler.addJob("*/15 * * * *", "send heartbeat");
    _ = try scheduler.addOnce("30m", "send morning brief");

    const found = findMatchingRecurringJob(scheduler.listJobs(), "0 8 * * *", "send morning brief");
    try std.testing.expect(found != null);
    try std.testing.expect(!found.?.one_shot);

    try std.testing.expect(findMatchingRecurringJob(scheduler.listJobs(), "0 9 * * *", "send morning brief") == null);
}

test "schedule findMatchingRecurringJob ignores disabled recurring jobs" {
    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("0 8 * * *", "send morning brief");
    job.enabled = false;
    job.paused = true;

    try std.testing.expect(findMatchingRecurringJob(scheduler.listJobs(), "0 8 * * *", "send morning brief") == null);
}

fn schedule_test_output_is_heap_owned(output: []const u8) bool {
    return output.len > 0 and !std.mem.eql(u8, output, "No scheduled jobs.");
}

fn schedule_test_error_is_heap_owned(error_msg: []const u8) bool {
    if (std.mem.eql(u8, error_msg, "Missing 'action' parameter")) return false;
    if (std.mem.eql(u8, error_msg, "Missing 'id' parameter for get action")) return false;
    if (std.mem.eql(u8, error_msg, "Missing 'command' parameter")) return false;
    if (std.mem.eql(u8, error_msg, "Missing 'expression' parameter for cron job")) return false;
    if (std.mem.eql(u8, error_msg, "Missing 'delay' parameter for one-shot task")) return false;
    if (std.mem.eql(u8, error_msg, "Delay too short; minimum is 60s")) return false;
    if (std.mem.eql(u8, error_msg, "Missing 'id' parameter for cancel action")) return false;
    if (std.mem.eql(u8, error_msg, "Missing 'id' parameter")) return false;
    if (std.mem.eql(u8, error_msg, "Failed to load scheduler state")) return false;
    return true;
}

fn free_schedule_test_output_if_owned(output: []const u8) void {
    if (schedule_test_output_is_heap_owned(output)) {
        std.testing.allocator.free(output);
    }
}

fn free_schedule_test_error_if_owned(error_msg: ?[]const u8) void {
    if (error_msg) |msg| {
        if (schedule_test_error_is_heap_owned(msg)) {
            std.testing.allocator.free(msg);
        }
    }
}

test "schedule list returns success" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"list\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
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
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unknown action") != null);
}

test "schedule create with expression" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"create\", \"expression\": \"*/5 * * * *\", \"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    // Succeeds if HOME/.nullalis is writable, otherwise may fail gracefully
    if (result.success) {
        try std.testing.expect(
            std.mem.indexOf(u8, result.output, "Created job") != null or
                std.mem.indexOf(u8, result.output, "already exists") != null,
        );
    }
}

// ── Additional schedule tests ───────────────────────────────────

test "schedule missing action" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "action") != null);
}

test "schedule get missing id" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"get\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "id") != null);
}

test "schedule get nonexistent job" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"get\", \"id\": \"nonexistent-123\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not found") != null);
}

test "schedule cancel requires id" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"cancel\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(!result.success);
}

test "schedule cancel nonexistent job returns not found" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"cancel\", \"id\": \"job-nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
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
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
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
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
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
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
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
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
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
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    if (result.success) {
        try std.testing.expect(
            std.mem.indexOf(u8, result.output, "Created job") != null or
                std.mem.indexOf(u8, result.output, "already exists") != null,
        );
    }
}

test "schedule create missing command" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"create\", \"expression\": \"* * * * *\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "command") != null);
}

test "schedule create missing expression" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"create\", \"command\": \"echo hi\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "expression") != null);
}

test "schedule once missing delay" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"once\", \"command\": \"echo hi\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "delay") != null);
}

test "schedule pause requires id" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"pause\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(!result.success);
}

test "schedule resume requires id" {
    var st = ScheduleTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\": \"resume\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
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
    try std.testing.expectEqual(cron.SessionTarget.isolated, updated.session_target);
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
    try std.testing.expectEqual(cron.SessionTarget.isolated, updated.session_target);
    try std.testing.expectEqual(cron.DeliveryMode.none, updated.delivery.mode);
    try std.testing.expectEqualStrings("echo-shell-output >/tmp/task.log", updated.command);
    try std.testing.expect(updated.prompt == null);
}
