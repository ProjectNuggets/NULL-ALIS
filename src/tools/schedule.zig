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

const MIN_ONCE_DELAY_SECS: i64 = 60;
const AUTOMATIONS_FILENAME = "AUTOMATIONS.json";

const DesiredJobKind = enum {
    auto,
    command,
    reminder,
    brief,
    report,
    follow_up,
};

const EnsureMode = enum {
    recurring,
    once,
};

const EnsureRequest = struct {
    mode: EnsureMode,
    expression: ?[]const u8 = null,
    delay: ?[]const u8 = null,
    command: []const u8,
    requested_id: ?[]const u8 = null,
    kind: DesiredJobKind = .auto,
};

const RegistryJobSpec = struct {
    id: ?[]const u8 = null,
    enabled: bool = false,
    kind: ?[]const u8 = null,
    expression: ?[]const u8 = null,
    delay: ?[]const u8 = null,
    command: ?[]const u8 = null,
};

fn validateOnceDelay(delay: []const u8) !void {
    const delay_secs = try cron.parseDuration(delay);
    if (delay_secs < MIN_ONCE_DELAY_SECS) return error.DelayTooShort;
}

fn parseDesiredJobKind(raw: ?[]const u8) DesiredJobKind {
    const value = raw orelse return .auto;
    if (std.ascii.eqlIgnoreCase(value, "command")) return .command;
    if (std.ascii.eqlIgnoreCase(value, "reminder")) return .reminder;
    if (std.ascii.eqlIgnoreCase(value, "brief")) return .brief;
    if (std.ascii.eqlIgnoreCase(value, "report")) return .report;
    if (std.ascii.eqlIgnoreCase(value, "follow_up")) return .follow_up;
    if (std.ascii.eqlIgnoreCase(value, "follow-up")) return .follow_up;
    return .auto;
}

fn buildAgentTaskPrompt(
    allocator: std.mem.Allocator,
    kind: DesiredJobKind,
    command: []const u8,
) ![]const u8 {
    return switch (kind) {
        .brief => std.fmt.allocPrint(
            allocator,
            "Prepare the scheduled brief now. Brief specification: {s}. " ++
                "Read HEARTBEAT.md in workspace only as wake policy if it is relevant. " ++
                "Use runtime_info and schedule first for runtime truth. Then gather data using read-only integrations/tools as needed (calendar/email/news/weather). " ++
                "Deliver one concise Telegram-ready brief suitable for scheduler delivery. Do not call the message tool in this turn; scheduler delivery sends the final output. Do not create/update scheduler jobs in this turn.",
            .{command},
        ),
        .report => std.fmt.allocPrint(
            allocator,
            "Prepare the scheduled report now. Report specification: {s}. " ++
                "Read HEARTBEAT.md in workspace only as wake policy if it is relevant. Use runtime_info and schedule first for runtime truth. " ++
                "Gather data using read-only tools only. Deliver one concise Telegram-ready report suitable for scheduler delivery. " ++
                "Do not call the message tool in this turn; scheduler delivery sends the final output. Do not create/update scheduler jobs in this turn.",
            .{command},
        ),
        .follow_up => std.fmt.allocPrint(
            allocator,
            "Perform the scheduled follow-up now. Follow-up specification: {s}. " ++
                "Read HEARTBEAT.md in workspace only as wake policy if it is relevant. Use runtime_info and schedule first for runtime truth. " ++
                "Deliver one concise Telegram-ready follow-up suitable for scheduler delivery. Do not call the message tool in this turn; scheduler delivery sends the final output. Do not create/update scheduler jobs in this turn.",
            .{command},
        ),
        .reminder => std.fmt.allocPrint(
            allocator,
            "Send exactly this reminder text to the user with no extra words: {s}",
            .{command},
        ),
        else => allocator.dupe(u8, command),
    };
}

fn normalizeIdToken(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n");
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

fn replaceOwnedString(
    allocator: std.mem.Allocator,
    field: *[]const u8,
    value: []const u8,
) !bool {
    if (std.mem.eql(u8, field.*, value)) return false;
    allocator.free(field.*);
    field.* = try allocator.dupe(u8, value);
    return true;
}

fn replaceOptionalOwnedString(
    allocator: std.mem.Allocator,
    field: *?[]const u8,
    owned: *bool,
    value: ?[]const u8,
) !bool {
    if (field.*) |existing| {
        if (value) |new_value| {
            if (std.mem.eql(u8, existing, new_value)) return false;
        } else {
            if (owned.*) allocator.free(existing);
            field.* = null;
            owned.* = false;
            return true;
        }
        if (owned.*) allocator.free(existing);
    } else if (value == null) {
        return false;
    }

    if (value) |new_value| {
        field.* = try allocator.dupe(u8, new_value);
        owned.* = true;
    } else {
        field.* = null;
        owned.* = false;
    }
    return true;
}

fn resetJobExecutionState(job: *cron.CronJob) void {
    job.last_status = null;
    job.cooldown_until_secs = null;
    job.consecutive_failures = 0;
    job.burst_count_in_window = 0;
    job.burst_window_start_secs = 0;
}

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

fn normalizeAgentManagedJob(
    scheduler: *CronScheduler,
    allocator: std.mem.Allocator,
    tenant: root.ToolTenantContext,
    job_id: []const u8,
    desired_id: ?[]const u8,
    command: []const u8,
    prompt: []const u8,
) !void {
    const job = scheduler.getMutableJob(job_id) orelse return error.JobNotFound;

    if (desired_id) |target_id| {
        _ = try replaceOwnedString(allocator, &job.id, target_id);
    }
    _ = try replaceOwnedString(allocator, &job.command, command);
    _ = try replaceOptionalOwnedString(allocator, &job.prompt, &job.prompt_owned, prompt);

    job.session_target = .isolated;
    job.wake_mode = .now;
    job.job_type = .agent;

    job.delivery.mode = .always;
    job.delivery.best_effort = true;
    _ = try replaceOptionalOwnedString(allocator, &job.delivery.channel, &job.delivery_channel_owned, "telegram");
    if (try resolveTelegramDeliveryTarget(allocator, tenant)) |resolved_target| {
        var target = resolved_target;
        defer target.deinit(allocator);
        _ = try replaceOptionalOwnedString(allocator, &job.delivery.to, &job.delivery_to_owned, target.chat_id);
    }

    resetJobExecutionState(job);
}

fn normalizeJobForRequest(
    scheduler: *CronScheduler,
    allocator: std.mem.Allocator,
    tenant: root.ToolTenantContext,
    job_id: []const u8,
    request: EnsureRequest,
) !void {
    switch (request.kind) {
        .brief, .report, .follow_up, .reminder => {
            const prompt = try buildAgentTaskPrompt(allocator, request.kind, request.command);
            defer allocator.free(prompt);
            return normalizeAgentManagedJob(
                scheduler,
                allocator,
                tenant,
                job_id,
                request.requested_id,
                request.command,
                prompt,
            );
        },
        .command => {
            const job = scheduler.getMutableJob(job_id) orelse return error.JobNotFound;
            if (request.requested_id) |target_id| {
                _ = try replaceOwnedString(allocator, &job.id, target_id);
            }
            _ = try replaceOwnedString(allocator, &job.command, request.command);
            job.job_type = .shell;
            job.session_target = .isolated;
            job.wake_mode = .now;
            job.delivery.mode = .none;
            _ = try replaceOptionalOwnedString(allocator, &job.prompt, &job.prompt_owned, null);
            _ = try replaceOptionalOwnedString(allocator, &job.delivery.channel, &job.delivery_channel_owned, null);
            _ = try replaceOptionalOwnedString(allocator, &job.delivery.to, &job.delivery_to_owned, null);
            resetJobExecutionState(job);
            return;
        },
        .auto => {
            const job = scheduler.getMutableJob(job_id) orelse return error.JobNotFound;
            if (request.requested_id) |target_id| {
                _ = try replaceOwnedString(allocator, &job.id, target_id);
            }
            _ = try replaceOwnedString(allocator, &job.command, request.command);
            return applyTenantDefaults(scheduler, allocator, job.id, request.command);
        },
    }
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

fn trimRegistryValue(raw: ?[]const u8) ?[]const u8 {
    const value = raw orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn registryEntryMatchesRequest(entry: RegistryJobSpec, request: EnsureRequest) bool {
    if (!entry.enabled) return false;
    const requested_id = request.requested_id orelse return false;
    const entry_id = trimRegistryValue(entry.id) orelse return false;
    const entry_command = trimRegistryValue(entry.command) orelse return false;
    const entry_kind = trimRegistryValue(entry.kind) orelse return false;

    if (!std.mem.eql(u8, entry_id, requested_id)) return false;
    if (!std.mem.eql(u8, entry_command, request.command)) return false;
    _ = parseDesiredJobKind(entry_kind);

    if (request.kind != .auto) {
        if (parseDesiredJobKind(entry_kind) != request.kind) return false;
    }

    return switch (request.mode) {
        .recurring => blk: {
            const expr = trimRegistryValue(entry.expression) orelse break :blk false;
            break :blk std.mem.eql(u8, expr, request.expression.?);
        },
        .once => blk: {
            const delay = trimRegistryValue(entry.delay) orelse break :blk false;
            break :blk std.mem.eql(u8, delay, request.delay.?);
        },
    };
}

fn oneShotExpressionMatchesDelay(job: *const cron.CronJob, delay: []const u8) bool {
    var buf: [80]u8 = undefined;
    const expr = std.fmt.bufPrint(&buf, "@once:{s}", .{delay}) catch return false;
    return std.mem.eql(u8, job.expression, expr);
}

fn automationRegistryAllowsRequest(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    request: EnsureRequest,
) bool {
    if (request.requested_id == null) return false;

    const registry_path = std.fs.path.join(allocator, &.{ workspace_dir, AUTOMATIONS_FILENAME }) catch return false;
    defer allocator.free(registry_path);

    const file = std.fs.openFileAbsolute(registry_path, .{}) catch return false;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 256 * 1024) catch return false;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const version_value = parsed.value.object.get("version") orelse return false;
    if (version_value != .integer or version_value.integer != 1) return false;
    const jobs_value = parsed.value.object.get("jobs") orelse return false;
    if (jobs_value != .array) return false;

    for (jobs_value.array.items) |entry_value| {
        if (entry_value != .object) continue;
        const match = RegistryJobSpec{
            .id = if (entry_value.object.get("id")) |v| if (v == .string) v.string else null else null,
            .enabled = if (entry_value.object.get("enabled")) |v| if (v == .bool) v.bool else false else false,
            .kind = if (entry_value.object.get("kind")) |v| if (v == .string) v.string else null else null,
            .expression = if (entry_value.object.get("expression")) |v| if (v == .string) v.string else null else null,
            .delay = if (entry_value.object.get("delay")) |v| if (v == .string) v.string else null else null,
            .command = if (entry_value.object.get("command")) |v| if (v == .string) v.string else null else null,
        };
        if (registryEntryMatchesRequest(match, request)) return true;
    }

    return false;
}

fn parseEnsureRequest(args: JsonObjectMap) !EnsureRequest {
    const command = root.getString(args, "command") orelse return error.MissingCommand;
    const expression = root.getString(args, "expression");
    const delay = root.getString(args, "delay");

    if ((expression == null and delay == null) or (expression != null and delay != null)) {
        return error.InvalidEnsureTiming;
    }
    if (delay) |value| try validateOnceDelay(value);

    const requested_id = normalizeRequestedId(root.getString(args, "id"));
    const kind = parseDesiredJobKind(root.getString(args, "kind"));

    return .{
        .mode = if (expression != null) .recurring else .once,
        .expression = expression,
        .delay = delay,
        .command = command,
        .requested_id = requested_id,
        .kind = kind,
    };
}

fn jobMatchesEnsureRequest(job: *const cron.CronJob, request: EnsureRequest, now_s: i64) bool {
    if (request.requested_id) |requested_id| {
        if (std.mem.eql(u8, job.id, requested_id)) return true;
    }

    return switch (request.mode) {
        .recurring => !job.one_shot and std.mem.eql(u8, job.expression, request.expression.?) and std.mem.eql(u8, job.command, request.command),
        .once => job.one_shot and job.next_run_secs >= now_s and job.last_run_secs == null and std.mem.eql(u8, job.command, request.command),
    };
}

fn findEnsureWinner(scheduler: *CronScheduler, request: EnsureRequest, now_s: i64) ?*cron.CronJob {
    var winner: ?*cron.CronJob = null;
    for (scheduler.jobs.items) |*job| {
        if (!jobMatchesEnsureRequest(job, request, now_s)) continue;
        if (winner == null) {
            winner = job;
            continue;
        }
        if (!winner.?.enabled and job.enabled) winner = job;
    }
    return winner;
}

fn disableEnsureDuplicates(
    scheduler: *CronScheduler,
    winner: *const cron.CronJob,
    request: EnsureRequest,
    now_s: i64,
) usize {
    var disabled: usize = 0;
    for (scheduler.jobs.items) |*job| {
        if (!jobMatchesEnsureRequest(job, request, now_s)) continue;
        if (job == winner) continue;
        if (job.enabled or !job.paused) {
            job.enabled = false;
            job.paused = true;
            disabled += 1;
        }
    }
    return disabled;
}

fn syncRecurringTiming(
    scheduler: *CronScheduler,
    allocator: std.mem.Allocator,
    job_id: []const u8,
    expression: []const u8,
) !void {
    if (!scheduler.updateJob(allocator, job_id, .{ .expression = expression })) {
        return error.InvalidCronExpression;
    }
    const job = scheduler.getMutableJob(job_id) orelse return error.JobNotFound;
    job.one_shot = false;
    job.delete_after_run = false;
}

fn syncOneShotTiming(
    allocator: std.mem.Allocator,
    job: *cron.CronJob,
    delay: []const u8,
) !void {
    const delay_secs = try cron.parseDuration(delay);
    const now_s = std.time.timestamp();
    const expr = try std.fmt.allocPrint(allocator, "@once:{s}", .{delay});
    defer allocator.free(expr);
    _ = try replaceOwnedString(allocator, &job.expression, expr);
    job.next_run_secs = now_s + delay_secs;
    job.one_shot = true;
    job.delete_after_run = false;
}

fn ensureBackgroundRequestAuthorized(
    allocator: std.mem.Allocator,
    workspace_dir: ?[]const u8,
    request: EnsureRequest,
) bool {
    const turn_ctx = root.getTurnContext();
    if (!root.isBackgroundTurnOrigin(turn_ctx.origin)) return true;
    const dir = workspace_dir orelse return false;
    return automationRegistryAllowsRequest(allocator, dir, request);
}

fn ensureScheduleJob(
    scheduler: *CronScheduler,
    allocator: std.mem.Allocator,
    tenant: root.ToolTenantContext,
    workspace_dir: ?[]const u8,
    request: EnsureRequest,
) !ToolResult {
    if (!ensureBackgroundRequestAuthorized(allocator, workspace_dir, request)) {
        return ToolResult.fail("Background schedule ensure requires a matching enabled job in AUTOMATIONS.json");
    }

    const now_s = std.time.timestamp();
    var winner = findEnsureWinner(scheduler, request, now_s);
    var changed = false;
    var created = false;

    if (winner == null) {
        const new_job = switch (request.mode) {
            .recurring => scheduler.addJob(request.expression.?, request.command),
            .once => scheduler.addOnce(request.delay.?, request.command),
        } catch |err| {
            if (err == error.MaxTasksReached) {
                const msg = try maxTasksReachedError(allocator, scheduler.max_tasks);
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            }
            const msg = try std.fmt.allocPrint(allocator, "Failed to ensure job: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        winner = new_job;
        created = true;
        changed = true;
    }

    const job = winner.?;
    switch (request.mode) {
        .recurring => {
            if (job.one_shot or !std.mem.eql(u8, job.expression, request.expression.?)) {
                try syncRecurringTiming(scheduler, allocator, job.id, request.expression.?);
                changed = true;
            }
        },
        .once => {
            if (!job.one_shot or job.last_run_secs != null or !oneShotExpressionMatchesDelay(job, request.delay.?)) {
                try syncOneShotTiming(allocator, job, request.delay.?);
                changed = true;
            }
        },
    }
    if (!job.enabled) {
        job.enabled = true;
        changed = true;
    }
    if (job.paused) {
        job.paused = false;
        changed = true;
    }

    try normalizeJobForRequest(scheduler, allocator, tenant, job.id, request);
    changed = true;

    const disabled_duplicates = disableEnsureDuplicates(scheduler, job, request, now_s);
    if (disabled_duplicates > 0) changed = true;

    if (changed) saveSchedulerForContext(scheduler, tenant) catch {};

    const verb = if (created) "Ensured new job" else "Ensured job";
    const suffix = if (disabled_duplicates > 0)
        try std.fmt.allocPrint(allocator, " (disabled {d} duplicate(s))", .{disabled_duplicates})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(suffix);

    const msg = try std.fmt.allocPrint(allocator, "{s} {s} | {s} | cmd: {s}{s}", .{
        verb,
        job.id,
        job.expression,
        job.command,
        suffix,
    });
    return ToolResult{ .success = true, .output = msg };
}

fn repairHintForJob(job: *const cron.CronJob) []const u8 {
    if (job.paused or !job.enabled) return "resume";
    if (job.last_status) |status| {
        if (std.ascii.eqlIgnoreCase(status, "error")) return "ensure";
    }
    return "none";
}

fn describePauseResumeResult(
    allocator: std.mem.Allocator,
    id: []const u8,
    is_pause: bool,
    result: cron.JobPauseResumeResult,
    job: ?*const cron.CronJob,
) !ToolResult {
    return switch (result) {
        .changed => blk: {
            const verb: []const u8 = if (is_pause) "Paused" else "Resumed";
            const msg = try std.fmt.allocPrint(allocator, "{s} job {s}", .{ verb, id });
            break :blk ToolResult{ .success = true, .output = msg };
        },
        .already_paused => blk: {
            const msg = try std.fmt.allocPrint(allocator, "Job {s} is already paused", .{id});
            break :blk ToolResult{ .success = true, .output = msg };
        },
        .already_active => blk: {
            if (!is_pause and job != null) {
                const resolved_job = job.?;
                if (resolved_job.last_status) |status| {
                    if (std.ascii.eqlIgnoreCase(status, "error")) {
                        const msg = try std.fmt.allocPrint(
                            allocator,
                            "Job {s} is already active but last_status=error; resume does not repair error. Use schedule ensure.",
                            .{id},
                        );
                        break :blk ToolResult{ .success = false, .output = "", .error_msg = msg };
                    }
                }
            }
            const msg = try std.fmt.allocPrint(allocator, "Job {s} is already active", .{id});
            break :blk ToolResult{ .success = true, .output = msg };
        },
        .not_found => blk: {
            const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{id});
            break :blk ToolResult{ .success = false, .output = "", .error_msg = msg };
        },
    };
}

fn applyTenantDefaults(
    scheduler: *CronScheduler,
    allocator: std.mem.Allocator,
    job_id: []const u8,
    command: []const u8,
) !void {
    const tenant = root.getTenantContext();
    if (tenant.numeric_user_id == null) return;
    const job = scheduler.getMutableJob(job_id) orelse return error.JobNotFound;
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
    pub const tool_description = "Manage scheduled tasks for the user. Preferred tool for reminders, briefs, recurring follow-ups, and other proactive jobs. Tasks may be agent-managed, delivery-managed, or raw commands depending on the request. Use schedule ensure for canonical durable job repair.";
    pub const tool_params =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["create","add","once","ensure","list","get","cancel","remove","pause","resume"],"description":"Action to perform"},"expression":{"type":"string","description":"Cron expression for recurring tasks"},"delay":{"type":"string","description":"Delay for one-shot tasks (e.g. '30m', '2h')"},"command":{"type":"string","description":"Task intent, reminder text, agent prompt, delivery text, or raw command depending on the task type"},"kind":{"type":"string","enum":["command","reminder","brief","report","follow_up"],"description":"Optional durable automation kind used for canonical schedule ensure and richer agent-managed jobs"},"id":{"type":"string","description":"Task ID (optional deterministic ID for create/add/once/ensure, required for get/cancel/pause/resume)"}},"required":["action"]}
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
                const status = job.last_status orelse "pending";
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "Job {s} | {s} | next={d}\n  enabled={s} paused={s} type={s} delivery={s} last_status={s} repair_hint={s}\n  cmd: {s}",
                    .{
                        job.id,
                        job.expression,
                        job.next_run_secs,
                        if (job.enabled) "true" else "false",
                        if (job.paused) "true" else "false",
                        job.job_type.asStr(),
                        job.delivery.mode.asStr(),
                        status,
                        repairHintForJob(job),
                        job.command,
                    },
                );
                return ToolResult{ .success = true, .output = msg };
            }
            const msg = try std.fmt.allocPrint(allocator, "Job '{s}' not found", .{id});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        if (std.mem.eql(u8, action, "ensure")) {
            const request = parseEnsureRequest(args) catch |err| switch (err) {
                error.MissingCommand => return ToolResult.fail("Missing 'command' parameter"),
                error.InvalidEnsureTiming => return ToolResult.fail("Provide exactly one of 'expression' or 'delay' for ensure"),
                error.DelayTooShort => return ToolResult.fail("Delay too short; minimum is 60s"),
                else => return ToolResult.fail("Invalid ensure request"),
            };

            const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
                error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
                else => return ToolResult.fail("Failed to load scheduler state"),
            };
            var scheduler = loaded.scheduler;
            defer scheduler.deinit();

            return ensureScheduleJob(&scheduler, allocator, loaded.tenant, if (self.config) |cfg| cfg.workspace_dir else null, request);
        }

        if (std.mem.eql(u8, action, "create") or std.mem.eql(u8, action, "add")) {
            const command = root.getString(args, "command") orelse
                return ToolResult.fail("Missing 'command' parameter");
            const expression = root.getString(args, "expression") orelse
                return ToolResult.fail("Missing 'expression' parameter for cron job");
            const kind = parseDesiredJobKind(root.getString(args, "kind"));
            const requested_id = normalizeRequestedId(root.getString(args, "id"));
            const request: EnsureRequest = .{
                .mode = .recurring,
                .expression = expression,
                .command = command,
                .requested_id = requested_id,
                .kind = kind,
            };

            const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
                error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
                else => return ToolResult.fail("Failed to load scheduler state"),
            };
            var scheduler = loaded.scheduler;
            defer scheduler.deinit();

            if (requested_id) |id| {
                if (scheduler.getJob(id)) |existing| {
                    if (!existing.enabled) {
                        _ = scheduler.removeJob(id);
                    } else {
                        normalizeJobForRequest(&scheduler, allocator, loaded.tenant, existing.id, request) catch {};
                        saveSchedulerForContext(&scheduler, loaded.tenant) catch {};
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

            normalizeJobForRequest(&scheduler, allocator, loaded.tenant, job.id, request) catch |err| {
                _ = scheduler.removeJob(job.id);
                const msg = try std.fmt.allocPrint(allocator, "Failed to normalize scheduled job: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
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
            const kind = parseDesiredJobKind(root.getString(args, "kind"));
            const requested_id = normalizeRequestedId(root.getString(args, "id"));
            const request: EnsureRequest = .{
                .mode = .once,
                .delay = delay,
                .command = command,
                .requested_id = requested_id,
                .kind = kind,
            };
            validateOnceDelay(delay) catch {
                return ToolResult.fail("Delay too short; minimum is 60s");
            };

            const loaded = loadSchedulerForContext(allocator, self.config) catch |err| switch (err) {
                error.MissingTenantStateContext => return ToolResult.fail("Tenant scheduler context is missing for postgres runtime"),
                else => return ToolResult.fail("Failed to load scheduler state"),
            };
            var scheduler = loaded.scheduler;
            defer scheduler.deinit();

            if (requested_id) |id| {
                if (scheduler.getJob(id)) |existing| {
                    if (!existing.enabled) {
                        _ = scheduler.removeJob(id);
                    } else {
                        normalizeJobForRequest(&scheduler, allocator, loaded.tenant, existing.id, request) catch {};
                        saveSchedulerForContext(&scheduler, loaded.tenant) catch {};
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

            normalizeJobForRequest(&scheduler, allocator, loaded.tenant, job.id, request) catch |err| {
                _ = scheduler.removeJob(job.id);
                const msg = try std.fmt.allocPrint(allocator, "Failed to normalize scheduled job: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
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
            const result = if (is_pause) scheduler.pauseJob(id) else scheduler.resumeJob(id);

            if (result == .changed) {
                saveSchedulerForContext(&scheduler, loaded.tenant) catch {};
            }
            return describePauseResumeResult(allocator, id, is_pause, result, scheduler.getJob(id));
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

const TestTmpDir = @TypeOf(std.testing.tmpDir(.{}));
const TestCronStore = struct {
    tmp: TestTmpDir,
    path: []u8,
    workspace_dir: []u8,

    fn init() !@This() {
        var tmp = std.testing.tmpDir(.{});
        const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
        defer std.testing.allocator.free(dir_path);
        const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "cron.json" });
        const workspace_dir = try std.fs.path.join(std.testing.allocator, &.{dir_path});
        cron.setTestStorePathOverride(path);
        return .{ .tmp = tmp, .path = path, .workspace_dir = workspace_dir };
    }

    fn deinit(self: *@This()) void {
        cron.setTestStorePathOverride(null);
        std.testing.allocator.free(self.workspace_dir);
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

fn schedule_test_output_is_heap_owned(output: []const u8) bool {
    return output.len > 0 and !std.mem.eql(u8, output, "No scheduled jobs.");
}

fn schedule_test_error_is_heap_owned(error_msg: []const u8) bool {
    if (std.mem.eql(u8, error_msg, "Missing 'action' parameter")) return false;
    if (std.mem.eql(u8, error_msg, "Missing 'id' parameter for get action")) return false;
    if (std.mem.eql(u8, error_msg, "Missing 'command' parameter")) return false;
    if (std.mem.eql(u8, error_msg, "Provide exactly one of 'expression' or 'delay' for ensure")) return false;
    if (std.mem.eql(u8, error_msg, "Missing 'expression' parameter for cron job")) return false;
    if (std.mem.eql(u8, error_msg, "Missing 'delay' parameter for one-shot task")) return false;
    if (std.mem.eql(u8, error_msg, "Delay too short; minimum is 60s")) return false;
    if (std.mem.eql(u8, error_msg, "Missing 'id' parameter for cancel action")) return false;
    if (std.mem.eql(u8, error_msg, "Missing 'id' parameter")) return false;
    if (std.mem.eql(u8, error_msg, "Failed to load scheduler state")) return false;
    if (std.mem.eql(u8, error_msg, "Background schedule ensure requires a matching enabled job in AUTOMATIONS.json")) return false;
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

fn writeScheduleTestAutomations(dir: std.testing.TmpDir, content: []const u8) !void {
    try dir.dir.writeFile(.{
        .sub_path = AUTOMATIONS_FILENAME,
        .data = content,
    });
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

test "schedule get shows diagnostic repair hint for errored active job" {
    var store = try TestCronStore.init();
    defer store.deinit();

    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();
    const job = try scheduler.addJob("0 15 * * *", "daily_afternoon_brief");
    std.testing.allocator.free(job.id);
    job.id = try std.testing.allocator.dupe(u8, "afternoon-brief");
    job.job_type = .agent;
    job.last_status = "error";
    try cron.saveJobs(&scheduler);

    var cfg = config_mod.Config{
        .workspace_dir = store.workspace_dir,
        .config_path = "/tmp/nullalis-test-config.json",
        .allocator = std.testing.allocator,
    };

    var st = ScheduleTool{ .config = &cfg };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\":\"get\",\"id\":\"afternoon-brief\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "last_status=error") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "repair_hint=ensure") != null);
}

test "schedule resume is honest for active errored job" {
    var store = try TestCronStore.init();
    defer store.deinit();

    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();
    const job = try scheduler.addJob("0 15 * * *", "daily_afternoon_brief");
    std.testing.allocator.free(job.id);
    job.id = try std.testing.allocator.dupe(u8, "afternoon-brief");
    job.job_type = .agent;
    job.last_status = "error";
    job.paused = false;
    job.enabled = true;
    try cron.saveJobs(&scheduler);

    var cfg = config_mod.Config{
        .workspace_dir = store.workspace_dir,
        .config_path = "/tmp/nullalis-test-config.json",
        .allocator = std.testing.allocator,
    };

    var st = ScheduleTool{ .config = &cfg };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\":\"resume\",\"id\":\"afternoon-brief\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "resume does not repair error") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "schedule ensure") != null);
}

test "schedule pause and resume report already states honestly" {
    var store = try TestCronStore.init();
    defer store.deinit();

    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();
    const job = try scheduler.addJob("0 9 * * *", "echo hello");
    std.testing.allocator.free(job.id);
    job.id = try std.testing.allocator.dupe(u8, "hello-job");
    job.paused = true;
    try cron.saveJobs(&scheduler);

    var cfg = config_mod.Config{
        .workspace_dir = store.workspace_dir,
        .config_path = "/tmp/nullalis-test-config.json",
        .allocator = std.testing.allocator,
    };

    var st = ScheduleTool{ .config = &cfg };
    const t = st.tool();

    const pause_parsed = try root.parseTestArgs("{\"action\":\"pause\",\"id\":\"hello-job\"}");
    defer pause_parsed.deinit();
    const pause_result = try t.execute(std.testing.allocator, pause_parsed.value.object);
    defer free_schedule_test_output_if_owned(pause_result.output);
    defer free_schedule_test_error_if_owned(pause_result.error_msg);
    try std.testing.expect(pause_result.success);
    try std.testing.expect(std.mem.indexOf(u8, pause_result.output, "already paused") != null);

    const resume_parsed = try root.parseTestArgs("{\"action\":\"resume\",\"id\":\"hello-job\"}");
    defer resume_parsed.deinit();
    const resume_result = try t.execute(std.testing.allocator, resume_parsed.value.object);
    defer free_schedule_test_output_if_owned(resume_result.output);
    defer free_schedule_test_error_if_owned(resume_result.error_msg);
    try std.testing.expect(resume_result.success);
    try std.testing.expect(std.mem.indexOf(u8, resume_result.output, "Resumed job hello-job") != null);
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

test "automation registry authorization requires version enabled id and command" {
    var store = try TestCronStore.init();
    defer store.deinit();

    try writeScheduleTestAutomations(store.tmp,
        \\{
        \\  "version": 1,
        \\  "jobs": [
        \\    {
        \\      "id": "morning-brief",
        \\      "enabled": true,
        \\      "kind": "brief",
        \\      "expression": "0 8 * * *",
        \\      "command": "daily_morning_brief"
        \\    }
        \\  ]
        \\}
    );

    const request: EnsureRequest = .{
        .mode = .recurring,
        .expression = "0 8 * * *",
        .command = "daily_morning_brief",
        .requested_id = "morning-brief",
        .kind = .brief,
    };
    try std.testing.expect(automationRegistryAllowsRequest(std.testing.allocator, store.workspace_dir, request));
}

test "schedule ensure blocks background auto-create without automation registry" {
    var store = try TestCronStore.init();
    defer store.deinit();

    var cfg = config_mod.Config{
        .workspace_dir = store.workspace_dir,
        .config_path = "/tmp/nullalis-test-config.json",
        .allocator = std.testing.allocator,
    };

    var st = ScheduleTool{ .config = &cfg };
    const t = st.tool();
    root.setTurnContext(.{ .origin = .wake });
    defer root.clearTurnContext();

    const parsed = try root.parseTestArgs("{\"action\":\"ensure\",\"id\":\"morning-brief\",\"kind\":\"brief\",\"expression\":\"0 8 * * *\",\"command\":\"daily_morning_brief\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "AUTOMATIONS.json") != null);
}

test "schedule ensure blocks background repair without automation registry even when job exists" {
    var store = try TestCronStore.init();
    defer store.deinit();

    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();
    const job = try scheduler.addJob("0 8 * * *", "echo status");
    job.enabled = false;
    job.paused = true;
    try cron.saveJobs(&scheduler);

    var cfg = config_mod.Config{
        .workspace_dir = store.workspace_dir,
        .config_path = "/tmp/nullalis-test-config.json",
        .allocator = std.testing.allocator,
    };

    var st = ScheduleTool{ .config = &cfg };
    const t = st.tool();
    root.setTurnContext(.{ .origin = .wake });
    defer root.clearTurnContext();

    const parsed = try root.parseTestArgs("{\"action\":\"ensure\",\"id\":\"status-job\",\"kind\":\"command\",\"expression\":\"0 8 * * *\",\"command\":\"echo status\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "AUTOMATIONS.json") != null);
}

test "schedule ensure creates canonical brief job from automation registry" {
    var store = try TestCronStore.init();
    defer store.deinit();

    try writeScheduleTestAutomations(store.tmp,
        \\{
        \\  "version": 1,
        \\  "jobs": [
        \\    {
        \\      "id": "morning-brief",
        \\      "enabled": true,
        \\      "kind": "brief",
        \\      "expression": "0 8 * * *",
        \\      "command": "daily_morning_brief"
        \\    }
        \\  ]
        \\}
    );

    var cfg = config_mod.Config{
        .workspace_dir = store.workspace_dir,
        .config_path = "/tmp/nullalis-test-config.json",
        .allocator = std.testing.allocator,
    };

    var st = ScheduleTool{ .config = &cfg };
    const t = st.tool();
    root.setTurnContext(.{ .origin = .wake });
    defer root.clearTurnContext();

    const parsed = try root.parseTestArgs("{\"action\":\"ensure\",\"id\":\"morning-brief\",\"kind\":\"brief\",\"expression\":\"0 8 * * *\",\"command\":\"daily_morning_brief\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(result.success);

    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();
    try cron.loadJobsStrict(&scheduler);
    const job = scheduler.getJob("morning-brief") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(cron.JobType.agent, job.job_type);
    try std.testing.expectEqual(cron.DeliveryMode.always, job.delivery.mode);
    try std.testing.expectEqualStrings("daily_morning_brief", job.command);
}

test "schedule ensure disables duplicate recurring jobs and keeps one enabled" {
    var store = try TestCronStore.init();
    defer store.deinit();

    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();
    _ = try scheduler.addJob("0 8 * * *", "echo status");
    _ = try scheduler.addJob("0 8 * * *", "echo status");
    scheduler.jobs.items[0].enabled = true;
    scheduler.jobs.items[1].enabled = true;
    try cron.saveJobs(&scheduler);

    var cfg = config_mod.Config{
        .workspace_dir = store.workspace_dir,
        .config_path = "/tmp/nullalis-test-config.json",
        .allocator = std.testing.allocator,
    };

    var st = ScheduleTool{ .config = &cfg };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\":\"ensure\",\"kind\":\"command\",\"expression\":\"0 8 * * *\",\"command\":\"echo status\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(result.success);

    var loaded = CronScheduler.init(std.testing.allocator, 16, true);
    defer loaded.deinit();
    try cron.loadJobsStrict(&loaded);
    var enabled_count: usize = 0;
    for (loaded.listJobs()) |job| {
        if (std.mem.eql(u8, job.command, "echo status") and job.enabled) enabled_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), enabled_count);
}

test "schedule ensure resumes paused recurring job" {
    var store = try TestCronStore.init();
    defer store.deinit();

    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();
    const job = try scheduler.addJob("0 8 * * *", "echo status");
    job.enabled = false;
    job.paused = true;
    try cron.saveJobs(&scheduler);

    var cfg = config_mod.Config{
        .workspace_dir = store.workspace_dir,
        .config_path = "/tmp/nullalis-test-config.json",
        .allocator = std.testing.allocator,
    };

    var st = ScheduleTool{ .config = &cfg };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\":\"ensure\",\"expression\":\"0 8 * * *\",\"command\":\"echo status\",\"kind\":\"command\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(result.success);

    var loaded = CronScheduler.init(std.testing.allocator, 16, true);
    defer loaded.deinit();
    try cron.loadJobsStrict(&loaded);
    const resumed = loaded.getJob(job.id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(resumed.enabled);
    try std.testing.expect(!resumed.paused);
}

test "schedule ensure repairs paused recurring job from automation registry" {
    var store = try TestCronStore.init();
    defer store.deinit();

    var scheduler = CronScheduler.init(std.testing.allocator, 16, true);
    defer scheduler.deinit();
    const job = try scheduler.addJob("0 8 * * *", "echo status");
    std.testing.allocator.free(job.id);
    job.id = try std.testing.allocator.dupe(u8, "status-job");
    job.enabled = false;
    job.paused = true;
    try cron.saveJobs(&scheduler);

    try writeScheduleTestAutomations(store.tmp,
        \\{
        \\  "version": 1,
        \\  "jobs": [
        \\    {
        \\      "id": "status-job",
        \\      "enabled": true,
        \\      "kind": "command",
        \\      "expression": "0 8 * * *",
        \\      "command": "echo status"
        \\    }
        \\  ]
        \\}
    );

    var cfg = config_mod.Config{
        .workspace_dir = store.workspace_dir,
        .config_path = "/tmp/nullalis-test-config.json",
        .allocator = std.testing.allocator,
    };

    var st = ScheduleTool{ .config = &cfg };
    const t = st.tool();
    root.setTurnContext(.{ .origin = .wake });
    defer root.clearTurnContext();

    const parsed = try root.parseTestArgs("{\"action\":\"ensure\",\"id\":\"status-job\",\"kind\":\"command\",\"expression\":\"0 8 * * *\",\"command\":\"echo status\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(result.success);

    var loaded = CronScheduler.init(std.testing.allocator, 16, true);
    defer loaded.deinit();
    try cron.loadJobsStrict(&loaded);
    const resumed = loaded.getJob(job.id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(resumed.enabled);
    try std.testing.expect(!resumed.paused);
}

test "schedule create with explicit id preserves tenant reminder normalization" {
    var store = try TestCronStore.init();
    defer store.deinit();

    var cfg = config_mod.Config{
        .workspace_dir = store.workspace_dir,
        .config_path = "/tmp/nullalis-test-config.json",
        .allocator = std.testing.allocator,
    };

    root.setTenantContext(.{
        .user_id = "15",
        .numeric_user_id = 15,
        .session_key = "agent:zaki-bot:user:15:main",
    });
    defer root.clearTenantContext();

    root.setMessageTurnContext(.{
        .channel = "telegram",
        .chat_id = "chat-15",
    });
    defer root.clearMessageTurnContext();

    var st = ScheduleTool{ .config = &cfg };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\":\"create\",\"id\":\"custom-reminder\",\"expression\":\"0 8 * * *\",\"command\":\"message \\\"Drink water\\\"\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(result.success);

    var loaded = CronScheduler.init(std.testing.allocator, 16, true);
    defer loaded.deinit();
    try cron.loadJobsStrict(&loaded);
    const job = loaded.getJob("custom-reminder") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(cron.JobType.agent, job.job_type);
    try std.testing.expectEqual(cron.DeliveryMode.always, job.delivery.mode);
    try std.testing.expectEqualStrings("telegram", job.delivery.channel.?);
    try std.testing.expectEqualStrings("chat-15", job.delivery.to.?);
    try std.testing.expectEqualStrings("Drink water", job.command);
    try std.testing.expect(job.prompt != null);
}

test "schedule ensure with explicit id preserves tenant reminder normalization" {
    var store = try TestCronStore.init();
    defer store.deinit();

    var cfg = config_mod.Config{
        .workspace_dir = store.workspace_dir,
        .config_path = "/tmp/nullalis-test-config.json",
        .allocator = std.testing.allocator,
    };

    root.setTenantContext(.{
        .user_id = "15",
        .numeric_user_id = 15,
        .session_key = "agent:zaki-bot:user:15:main",
    });
    defer root.clearTenantContext();

    root.setMessageTurnContext(.{
        .channel = "telegram",
        .chat_id = "chat-15",
    });
    defer root.clearMessageTurnContext();

    root.setTurnContext(.{ .origin = .user });
    defer root.clearTurnContext();

    var st = ScheduleTool{ .config = &cfg };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"action\":\"ensure\",\"id\":\"custom-reminder\",\"expression\":\"0 8 * * *\",\"command\":\"message \\\"Drink water\\\"\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer free_schedule_test_output_if_owned(result.output);
    defer free_schedule_test_error_if_owned(result.error_msg);
    try std.testing.expect(result.success);

    var loaded = CronScheduler.init(std.testing.allocator, 16, true);
    defer loaded.deinit();
    try cron.loadJobsStrict(&loaded);
    const job = loaded.getJob("custom-reminder") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(cron.JobType.agent, job.job_type);
    try std.testing.expectEqual(cron.DeliveryMode.always, job.delivery.mode);
    try std.testing.expectEqualStrings("telegram", job.delivery.channel.?);
    try std.testing.expectEqualStrings("chat-15", job.delivery.to.?);
    try std.testing.expectEqualStrings("Drink water", job.command);
    try std.testing.expect(job.prompt != null);
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
