const std = @import("std");
const platform = @import("platform.zig");
const bus = @import("bus.zig");
const json_util = @import("json_util.zig");
const http_util = @import("http_util.zig");

const log = std.log.scoped(.cron);

pub const JobType = enum {
    shell,
    agent,

    pub fn asStr(self: JobType) []const u8 {
        return switch (self) {
            .shell => "shell",
            .agent => "agent",
        };
    }

    pub fn parse(raw: []const u8) JobType {
        if (std.ascii.eqlIgnoreCase(raw, "agent")) return .agent;
        return .shell;
    }
};

pub const SessionTarget = enum {
    isolated,
    main,

    pub fn asStr(self: SessionTarget) []const u8 {
        return switch (self) {
            .isolated => "isolated",
            .main => "main",
        };
    }

    pub fn parse(raw: []const u8) SessionTarget {
        if (std.ascii.eqlIgnoreCase(raw, "main")) return .main;
        return .isolated;
    }
};

pub const ScheduleKind = enum { cron, at, every };

pub const Schedule = union(ScheduleKind) {
    cron: struct { expr: []const u8, tz: ?[]const u8 },
    at: struct { timestamp_s: i64 },
    every: struct { every_ms: u64 },
};

pub const DeliveryMode = enum {
    none,
    always,
    on_error,
    on_success,

    pub fn asStr(self: DeliveryMode) []const u8 {
        return switch (self) {
            .none => "none",
            .always => "always",
            .on_error => "on_error",
            .on_success => "on_success",
        };
    }

    pub fn parse(raw: []const u8) DeliveryMode {
        if (std.ascii.eqlIgnoreCase(raw, "always")) return .always;
        if (std.ascii.eqlIgnoreCase(raw, "on_error")) return .on_error;
        if (std.ascii.eqlIgnoreCase(raw, "on_success")) return .on_success;
        return .none;
    }
};

pub const DeliveryConfig = struct {
    mode: DeliveryMode = .none,
    channel: ?[]const u8 = null,
    to: ?[]const u8 = null,
    best_effort: bool = true,
};

pub const CronRun = struct {
    id: u64,
    job_id: []const u8,
    started_at_s: i64,
    finished_at_s: i64,
    status: []const u8,
    output: ?[]const u8,
    duration_ms: ?i64,
};

pub const CronJobPatch = struct {
    expression: ?[]const u8 = null,
    command: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    name: ?[]const u8 = null,
    enabled: ?bool = null,
    model: ?[]const u8 = null,
    delete_after_run: ?bool = null,
};

/// A scheduled cron job.
pub const CronJob = struct {
    id: []const u8,
    expression: []const u8,
    command: []const u8,
    next_run_secs: i64 = 0,
    last_run_secs: ?i64 = null,
    last_status: ?[]const u8 = null,
    paused: bool = false,
    one_shot: bool = false,
    job_type: JobType = .shell,
    session_target: SessionTarget = .isolated,
    prompt: ?[]const u8 = null,
    prompt_owned: bool = false,
    name: ?[]const u8 = null,
    name_owned: bool = false,
    model: ?[]const u8 = null,
    model_owned: bool = false,
    enabled: bool = true,
    delete_after_run: bool = false,
    created_at_s: i64 = 0,
    last_output: ?[]const u8 = null,
    last_output_owned: bool = false,
    delivery: DeliveryConfig = .{},
    delivery_channel_owned: bool = false,
    delivery_to_owned: bool = false,
};

/// Duration unit for "once" delay parsing.
pub const DurationUnit = enum {
    seconds,
    minutes,
    hours,
    days,
    weeks,
};

/// Parse a human delay string like "30m", "2h", "1d" into seconds.
pub fn parseDuration(input: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyDelay;

    // Check if last char is a unit letter
    const last = trimmed[trimmed.len - 1];
    var num_str: []const u8 = undefined;
    var multiplier: i64 = undefined;

    if (std.ascii.isAlphabetic(last)) {
        num_str = trimmed[0 .. trimmed.len - 1];
        multiplier = switch (last) {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            'd' => 86400,
            'w' => 604800,
            else => return error.UnknownDurationUnit,
        };
    } else {
        num_str = trimmed;
        multiplier = 60; // default to minutes
    }

    const n = std.fmt.parseInt(i64, std.mem.trim(u8, num_str, " "), 10) catch return error.InvalidDurationNumber;
    if (n <= 0) return error.InvalidDurationNumber;

    const secs = std.math.mul(i64, n, multiplier) catch return error.DurationTooLarge;
    return secs;
}

/// Normalize a cron expression (5 fields -> prepend "0" for seconds).
pub fn normalizeExpression(expression: []const u8) !CronNormalized {
    const trimmed = std.mem.trim(u8, expression, " \t\r\n");
    var field_count: usize = 0;
    var in_field = false;

    for (trimmed) |c| {
        if (c == ' ' or c == '\t') {
            if (in_field) {
                in_field = false;
            }
        } else {
            if (!in_field) {
                field_count += 1;
                in_field = true;
            }
        }
    }

    return switch (field_count) {
        5 => .{ .expression = trimmed, .needs_second_prefix = true },
        6, 7 => .{ .expression = trimmed, .needs_second_prefix = false },
        else => error.InvalidCronExpression,
    };
}

pub const CronNormalized = struct {
    expression: []const u8,
    needs_second_prefix: bool,
};

const MAX_CRON_LOOKAHEAD_MINUTES: usize = 8 * 366 * 24 * 60;

const ParsedCronExpression = struct {
    minutes: [60]bool = .{false} ** 60,
    hours: [24]bool = .{false} ** 24,
    day_of_month: [32]bool = .{false} ** 32, // 1..31
    months: [13]bool = .{false} ** 13, // 1..12
    day_of_week: [7]bool = .{false} ** 7, // 0..6 (0=Sun)
    day_of_month_any: bool = false,
    day_of_week_any: bool = false,
};

fn parseCronRawValue(raw: []const u8, min: u8, max: u8, allow_sunday_7: bool) !u8 {
    const value = std.fmt.parseInt(u8, std.mem.trim(u8, raw, " \t"), 10) catch return error.InvalidCronExpression;
    const max_allowed: u8 = if (allow_sunday_7) 7 else max;
    if (value < min or value > max_allowed) return error.InvalidCronExpression;
    return value;
}

fn normalizeCronValue(raw_value: u8, allow_sunday_7: bool) u8 {
    if (allow_sunday_7 and raw_value == 7) return 0;
    return raw_value;
}

fn clearBoolSlice(values: []bool) void {
    for (values) |*entry| entry.* = false;
}

fn parseCronField(raw_field: []const u8, min: u8, max: u8, allow_sunday_7: bool, out: []bool) !bool {
    if (out.len <= max) return error.InvalidCronExpression;
    clearBoolSlice(out);

    const field = std.mem.trim(u8, raw_field, " \t");
    if (field.len == 0) return error.InvalidCronExpression;
    const is_any = std.mem.eql(u8, field, "*");

    var saw_value = false;
    var parts = std.mem.splitScalar(u8, field, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) return error.InvalidCronExpression;

        var range_part = part;
        var step: u8 = 1;
        if (std.mem.indexOfScalar(u8, part, '/')) |slash_idx| {
            range_part = std.mem.trim(u8, part[0..slash_idx], " \t");
            const step_raw = std.mem.trim(u8, part[slash_idx + 1 ..], " \t");
            if (range_part.len == 0 or step_raw.len == 0) return error.InvalidCronExpression;
            step = std.fmt.parseInt(u8, step_raw, 10) catch return error.InvalidCronExpression;
            if (step == 0) return error.InvalidCronExpression;
        }

        var start_raw: u8 = min;
        var end_raw: u8 = max;
        if (std.mem.eql(u8, range_part, "*")) {
            // full range
        } else if (std.mem.indexOfScalar(u8, range_part, '-')) |dash_idx| {
            const start_part = std.mem.trim(u8, range_part[0..dash_idx], " \t");
            const end_part = std.mem.trim(u8, range_part[dash_idx + 1 ..], " \t");
            if (start_part.len == 0 or end_part.len == 0) return error.InvalidCronExpression;
            start_raw = try parseCronRawValue(start_part, min, max, allow_sunday_7);
            end_raw = try parseCronRawValue(end_part, min, max, allow_sunday_7);
            if (start_raw > end_raw) return error.InvalidCronExpression;
        } else {
            start_raw = try parseCronRawValue(range_part, min, max, allow_sunday_7);
            end_raw = start_raw;
        }

        var raw_value = start_raw;
        while (raw_value <= end_raw) {
            const normalized = normalizeCronValue(raw_value, allow_sunday_7);
            if (normalized < min or normalized > max) return error.InvalidCronExpression;
            out[normalized] = true;
            saw_value = true;

            const next = @addWithOverflow(raw_value, step);
            if (next[1] != 0 or next[0] <= raw_value) break;
            raw_value = next[0];
        }
    }

    if (!saw_value) return error.InvalidCronExpression;
    return is_any;
}

fn parseCronExpression(expression: []const u8) !ParsedCronExpression {
    const trimmed = std.mem.trim(u8, expression, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidCronExpression;

    var fields: [7][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    while (it.next()) |field| {
        if (count >= fields.len) return error.InvalidCronExpression;
        fields[count] = field;
        count += 1;
    }

    if (count < 5 or count > 7) return error.InvalidCronExpression;

    const minute_field: []const u8 = switch (count) {
        5 => fields[0],
        6, 7 => fields[1],
        else => unreachable,
    };
    const hour_field: []const u8 = switch (count) {
        5 => fields[1],
        6, 7 => fields[2],
        else => unreachable,
    };
    const dom_field: []const u8 = switch (count) {
        5 => fields[2],
        6, 7 => fields[3],
        else => unreachable,
    };
    const month_field: []const u8 = switch (count) {
        5 => fields[3],
        6, 7 => fields[4],
        else => unreachable,
    };
    const dow_field: []const u8 = switch (count) {
        5 => fields[4],
        6, 7 => fields[5],
        else => unreachable,
    };

    var parsed = ParsedCronExpression{};
    _ = try parseCronField(minute_field, 0, 59, false, parsed.minutes[0..]);
    _ = try parseCronField(hour_field, 0, 23, false, parsed.hours[0..]);
    parsed.day_of_month_any = try parseCronField(dom_field, 1, 31, false, parsed.day_of_month[0..]);
    _ = try parseCronField(month_field, 1, 12, false, parsed.months[0..]);
    parsed.day_of_week_any = try parseCronField(dow_field, 0, 6, true, parsed.day_of_week[0..]);

    return parsed;
}

fn cronExpressionMatches(parsed: *const ParsedCronExpression, ts: i64) bool {
    if (ts < 0) return false;

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const minute: u8 = day_seconds.getMinutesIntoHour();
    const hour: u8 = day_seconds.getHoursIntoDay();
    const day_of_month: u8 = @as(u8, @intCast(month_day.day_index + 1));
    const month: u8 = month_day.month.numeric();
    const day_of_week: u8 = @as(u8, @intCast((epoch_day.day + 4) % 7)); // 1970-01-01 was Thursday (4)

    if (!parsed.minutes[minute]) return false;
    if (!parsed.hours[hour]) return false;
    if (!parsed.months[month]) return false;

    const dom_match = parsed.day_of_month[day_of_month];
    const dow_match = parsed.day_of_week[day_of_week];

    const day_match = if (parsed.day_of_month_any and parsed.day_of_week_any)
        true
    else if (parsed.day_of_month_any)
        dow_match
    else if (parsed.day_of_week_any)
        dom_match
    else
        dom_match or dow_match;

    return day_match;
}

fn alignToNextMinute(from_secs: i64) i64 {
    var start = from_secs + 1;
    if (start < 0) start = 0;
    const rem = @mod(start, 60);
    if (rem == 0) return start;
    return start + (60 - rem);
}

fn nextRunForCronExpression(expression: []const u8, from_secs: i64) !i64 {
    const parsed = try parseCronExpression(expression);
    var candidate = alignToNextMinute(from_secs);

    var i: usize = 0;
    while (i < MAX_CRON_LOOKAHEAD_MINUTES) : (i += 1) {
        if (cronExpressionMatches(&parsed, candidate)) return candidate;
        candidate += 60;
    }
    return error.NoFutureRunFound;
}

/// In-memory cron job store (no SQLite dependency for the minimal Zig port).
pub const CronScheduler = struct {
    pub const AgentRunnerFn = *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        scheduler: *const CronScheduler,
        job: *const CronJob,
        prompt: []const u8,
    ) anyerror![]const u8;

    jobs: std.ArrayListUnmanaged(CronJob),
    runs: std.ArrayListUnmanaged(CronRun) = .empty,
    next_run_id: u64 = 1,
    max_tasks: usize,
    enabled: bool,
    allocator: std.mem.Allocator,
    store_path: ?[]const u8 = null,
    context_user_id: ?[]const u8 = null,
    context_user_root: ?[]const u8 = null,
    context_workspace: ?[]const u8 = null,
    agent_runner: ?AgentRunnerFn = null,
    agent_runner_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, max_tasks: usize, enabled: bool) CronScheduler {
        return .{
            .jobs = .empty,
            .max_tasks = max_tasks,
            .enabled = enabled,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CronScheduler) void {
        if (self.store_path) |p| self.allocator.free(p);
        if (self.context_user_id) |v| self.allocator.free(v);
        if (self.context_user_root) |v| self.allocator.free(v);
        if (self.context_workspace) |v| self.allocator.free(v);
        for (self.runs.items) |r| {
            self.allocator.free(r.job_id);
            self.allocator.free(r.status);
            if (r.output) |o| self.allocator.free(o);
        }
        self.runs.deinit(self.allocator);
        self.clearJobs();
        self.jobs.deinit(self.allocator);
    }

    fn clearJobs(self: *CronScheduler) void {
        for (self.jobs.items) |job| {
            self.deinitJob(job);
        }
        self.jobs.clearRetainingCapacity();
    }

    fn deinitJob(self: *CronScheduler, job: CronJob) void {
        self.allocator.free(job.id);
        self.allocator.free(job.expression);
        self.allocator.free(job.command);
        if (job.prompt_owned) if (job.prompt) |v| self.allocator.free(v);
        if (job.name_owned) if (job.name) |v| self.allocator.free(v);
        if (job.model_owned) if (job.model) |v| self.allocator.free(v);
        if (job.delivery_channel_owned) if (job.delivery.channel) |v| self.allocator.free(v);
        if (job.delivery_to_owned) if (job.delivery.to) |v| self.allocator.free(v);
        if (job.last_output_owned) if (job.last_output) |o| self.allocator.free(o);
    }

    pub fn setStorePath(self: *CronScheduler, path: []const u8) !void {
        if (self.store_path) |old| self.allocator.free(old);
        self.store_path = try self.allocator.dupe(u8, path);
    }

    pub fn setExecutionContext(
        self: *CronScheduler,
        user_id: ?[]const u8,
        user_root: ?[]const u8,
        workspace: ?[]const u8,
    ) !void {
        if (self.context_user_id) |v| self.allocator.free(v);
        if (self.context_user_root) |v| self.allocator.free(v);
        if (self.context_workspace) |v| self.allocator.free(v);
        self.context_user_id = if (user_id) |v| try self.allocator.dupe(u8, v) else null;
        self.context_user_root = if (user_root) |v| try self.allocator.dupe(u8, v) else null;
        self.context_workspace = if (workspace) |v| try self.allocator.dupe(u8, v) else null;
    }

    pub fn setAgentRunner(self: *CronScheduler, runner: ?AgentRunnerFn, runner_ctx: ?*anyopaque) void {
        self.agent_runner = runner;
        self.agent_runner_ctx = runner_ctx;
    }

    /// Add a recurring cron job.
    pub fn addJob(self: *CronScheduler, expression: []const u8, command: []const u8) !*CronJob {
        if (self.jobs.items.len >= self.max_tasks) return error.MaxTasksReached;

        // Validate expression
        _ = try normalizeExpression(expression);
        const now = std.time.timestamp();
        const next_run_secs = try nextRunForCronExpression(expression, now);

        // Generate a simple numeric ID
        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "job-{d}", .{self.jobs.items.len + 1}) catch "job-?";

        try self.jobs.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .expression = try self.allocator.dupe(u8, expression),
            .command = try self.allocator.dupe(u8, command),
            .next_run_secs = next_run_secs,
            .created_at_s = now,
        });

        return &self.jobs.items[self.jobs.items.len - 1];
    }

    /// Add a one-shot delayed task.
    pub fn addOnce(self: *CronScheduler, delay: []const u8, command: []const u8) !*CronJob {
        if (self.jobs.items.len >= self.max_tasks) return error.MaxTasksReached;

        const delay_secs = try parseDuration(delay);
        const now = std.time.timestamp();

        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "once-{d}", .{self.jobs.items.len + 1}) catch "once-?";

        var expr_buf: [64]u8 = undefined;
        const expr = std.fmt.bufPrint(&expr_buf, "@once:{s}", .{delay}) catch "@once";

        try self.jobs.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .expression = try self.allocator.dupe(u8, expr),
            .command = try self.allocator.dupe(u8, command),
            .next_run_secs = now + delay_secs,
            .one_shot = true,
            .created_at_s = now,
        });

        return &self.jobs.items[self.jobs.items.len - 1];
    }

    /// List all jobs.
    pub fn listJobs(self: *const CronScheduler) []const CronJob {
        return self.jobs.items;
    }

    /// Get a job by ID.
    pub fn getJob(self: *const CronScheduler, id: []const u8) ?*const CronJob {
        for (self.jobs.items) |*job| {
            if (std.mem.eql(u8, job.id, id)) return job;
        }
        return null;
    }

    /// Get a mutable pointer to a job by ID.
    pub fn getMutableJob(self: *CronScheduler, id: []const u8) ?*CronJob {
        for (self.jobs.items) |*job| {
            if (std.mem.eql(u8, job.id, id)) return job;
        }
        return null;
    }

    /// Update a job's fields from a patch.
    pub fn updateJob(self: *CronScheduler, allocator: std.mem.Allocator, id: []const u8, patch: CronJobPatch) bool {
        const job = self.getMutableJob(id) orelse return false;
        if (patch.expression) |expr| {
            const next_run_secs = nextRunForCronExpression(expr, std.time.timestamp()) catch return false;
            const new_expr = allocator.dupe(u8, expr) catch return false;
            allocator.free(job.expression);
            job.expression = new_expr;
            job.next_run_secs = next_run_secs;
        }
        if (patch.command) |cmd| {
            const new_cmd = allocator.dupe(u8, cmd) catch return false;
            allocator.free(job.command);
            job.command = new_cmd;
        }
        if (patch.prompt) |value| {
            const new_val = allocator.dupe(u8, value) catch return false;
            if (job.prompt_owned) if (job.prompt) |old| allocator.free(old);
            job.prompt = new_val;
            job.prompt_owned = true;
        }
        if (patch.name) |value| {
            const new_val = allocator.dupe(u8, value) catch return false;
            if (job.name_owned) if (job.name) |old| allocator.free(old);
            job.name = new_val;
            job.name_owned = true;
        }
        if (patch.model) |value| {
            const new_val = allocator.dupe(u8, value) catch return false;
            if (job.model_owned) if (job.model) |old| allocator.free(old);
            job.model = new_val;
            job.model_owned = true;
        }
        if (patch.enabled) |ena| {
            job.enabled = ena;
            job.paused = !ena;
        }
        if (patch.delete_after_run) |d| {
            job.delete_after_run = d;
            job.one_shot = d;
        }
        return true;
    }

    /// Record a completed run for a job.
    pub fn addRun(self: *CronScheduler, allocator: std.mem.Allocator, job_id: []const u8, started_at_s: i64, finished_at_s: i64, status: []const u8, output: ?[]const u8, max_history: usize) !void {
        const entry = CronRun{
            .id = self.next_run_id,
            .job_id = try allocator.dupe(u8, job_id),
            .started_at_s = started_at_s,
            .finished_at_s = finished_at_s,
            .status = try allocator.dupe(u8, status),
            .output = if (output) |o| try allocator.dupe(u8, o) else null,
            .duration_ms = (finished_at_s - started_at_s) * 1000,
        };
        self.next_run_id += 1;
        try self.runs.append(allocator, entry);
        // Prune to max_history per job_id
        if (max_history > 0) {
            var count: usize = 0;
            var i: usize = self.runs.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, self.runs.items[i].job_id, job_id)) {
                    count += 1;
                    if (count > max_history) {
                        // Free strings of the pruned run
                        allocator.free(self.runs.items[i].job_id);
                        allocator.free(self.runs.items[i].status);
                        if (self.runs.items[i].output) |o| allocator.free(o);
                        _ = self.runs.orderedRemove(i);
                    }
                }
            }
        }
    }

    /// List recent runs for a given job_id, up to `limit` entries.
    pub fn listRuns(self: *const CronScheduler, job_id: []const u8, limit: usize) []const CronRun {
        // Return last `limit` runs for given job_id (from end of slice)
        var count: usize = 0;
        var start: usize = self.runs.items.len;
        var i: usize = self.runs.items.len;
        while (i > 0 and count < limit) {
            i -= 1;
            if (std.mem.eql(u8, self.runs.items[i].job_id, job_id)) {
                start = i;
                count += 1;
            }
        }
        if (count == 0) return &.{};
        return self.runs.items[start..];
    }

    /// Remove a job by ID, freeing its owned strings.
    pub fn removeJob(self: *CronScheduler, id: []const u8) bool {
        for (self.jobs.items, 0..) |job, i| {
            if (std.mem.eql(u8, job.id, id)) {
                self.deinitJob(job);
                _ = self.jobs.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Pause a job.
    pub fn pauseJob(self: *CronScheduler, id: []const u8) bool {
        for (self.jobs.items) |*job| {
            if (std.mem.eql(u8, job.id, id)) {
                job.paused = true;
                return true;
            }
        }
        return false;
    }

    /// Resume a job.
    pub fn resumeJob(self: *CronScheduler, id: []const u8) bool {
        for (self.jobs.items) |*job| {
            if (std.mem.eql(u8, job.id, id)) {
                job.paused = false;
                return true;
            }
        }
        return false;
    }

    /// Get due (non-paused) jobs whose next_run <= now.
    pub fn dueJobs(self: *const CronScheduler, allocator: std.mem.Allocator, now_secs: i64) ![]const CronJob {
        var result: std.ArrayListUnmanaged(CronJob) = .empty;
        for (self.jobs.items) |job| {
            if (!job.paused and job.next_run_secs <= now_secs) {
                try result.append(allocator, job);
            }
        }
        return result.items;
    }

    /// Main scheduler loop: check all jobs, execute due ones, sleep until next.
    /// If `out_bus` is provided, job results are delivered to channels per delivery config.
    pub fn run(self: *CronScheduler, poll_secs: u64, out_bus: ?*bus.Bus) void {
        if (!self.enabled) return;

        const poll_ns: u64 = poll_secs * std.time.ns_per_s;

        while (true) {
            const now = std.time.timestamp();
            _ = self.tick(now, out_bus);
            std.Thread.sleep(poll_ns);
        }
    }

    /// Execute one tick of the scheduler: run all due jobs, deliver results, handle one-shots.
    /// Separated from `run` for testability.
    pub fn tick(self: *CronScheduler, now: i64, out_bus: ?*bus.Bus) bool {
        var changed = false;

        // Collect indices of one-shot jobs to remove after iteration
        var remove_indices: [64]usize = undefined;
        var remove_count: usize = 0;

        for (self.jobs.items, 0..) |*job, idx| {
            if (job.paused or job.next_run_secs > now) continue;
            changed = true;

            switch (job.job_type) {
                .shell => {
                    const command_to_run = blk: {
                        if (self.context_workspace) |workspace| {
                            if (self.context_user_id) |user_id| {
                                const user_root = self.context_user_root orelse "";
                                break :blk std.fmt.allocPrint(
                                    self.allocator,
                                    "NULLCLAW_USER_ID=\"{s}\" NULLCLAW_USER_ROOT=\"{s}\" cd \"{s}\" && {s}",
                                    .{ user_id, user_root, workspace, job.command },
                                ) catch null;
                            }
                            break :blk std.fmt.allocPrint(
                                self.allocator,
                                "cd \"{s}\" && {s}",
                                .{ workspace, job.command },
                            ) catch null;
                        }
                        break :blk self.allocator.dupe(u8, job.command) catch null;
                    } orelse {
                        job.last_status = "error";
                        job.last_run_secs = now;
                        continue;
                    };
                    defer self.allocator.free(command_to_run);

                    // Execute shell command via child process
                    const result = std.process.Child.run(.{
                        .allocator = self.allocator,
                        .argv = &.{ platform.getShell(), platform.getShellFlag(), command_to_run },
                    }) catch |err| {
                        log.err("cron job '{s}' failed to start: {}", .{ job.id, err });
                        job.last_status = "error";
                        job.last_run_secs = now;
                        if (job.last_output_owned) {
                            if (job.last_output) |old| self.allocator.free(old);
                        }
                        job.last_output = null;
                        job.last_output_owned = false;
                        // Deliver error notification
                        if (out_bus) |b| {
                            _ = deliverResult(self.allocator, job.delivery, "cron job failed to start", false, b) catch {};
                        }
                        continue;
                    };
                    defer self.allocator.free(result.stderr);

                    const success = switch (result.term) {
                        .Exited => |code| code == 0,
                        else => false,
                    };
                    job.last_run_secs = now;
                    job.last_status = if (success) "ok" else "error";

                    // Store and deliver stdout
                    if (job.last_output_owned) {
                        if (job.last_output) |old| self.allocator.free(old);
                    }
                    job.last_output = if (result.stdout.len > 0) result.stdout else blk: {
                        self.allocator.free(result.stdout);
                        break :blk null;
                    };
                    job.last_output_owned = job.last_output != null;

                    if (out_bus) |b| {
                        const output = job.last_output orelse "";
                        _ = deliverResultForContext(self.allocator, self.context_user_root, job.delivery, output, success, b) catch {};
                    }
                },
                .agent => {
                    const agent_input = job.prompt orelse job.command;
                    var success = true;
                    const agent_output = blk: {
                        if (self.agent_runner) |runner| {
                            break :blk runner(
                                self.agent_runner_ctx,
                                self.allocator,
                                self,
                                job,
                                agent_input,
                            ) catch |err| {
                                success = false;
                                break :blk std.fmt.allocPrint(
                                    self.allocator,
                                    "agent cron failed: {s}",
                                    .{@errorName(err)},
                                ) catch null;
                            };
                        }
                        break :blk self.allocator.dupe(u8, agent_input) catch null;
                    };
                    job.last_run_secs = now;
                    job.last_status = if (success) "ok" else "error";

                    if (job.last_output_owned) {
                        if (job.last_output) |old| self.allocator.free(old);
                    }
                    job.last_output = agent_output;
                    job.last_output_owned = job.last_output != null;

                    if (out_bus) |b| {
                        _ = deliverResultForContext(self.allocator, self.context_user_root, job.delivery, job.last_output orelse "", success, b) catch {};
                    }
                },
            }

            if (job.one_shot or job.delete_after_run) {
                if (remove_count < remove_indices.len) {
                    remove_indices[remove_count] = idx;
                    remove_count += 1;
                } else {
                    // Fallback: just pause it
                    job.paused = true;
                }
            } else {
                job.next_run_secs = nextRunForCronExpression(job.expression, now) catch |err| blk: {
                    log.warn("cron job '{s}' schedule parse failed ({s}); fallback to +60s", .{ job.id, @errorName(err) });
                    break :blk now + 60;
                };
            }
        }

        // Remove one-shot jobs in reverse order to keep indices valid
        if (remove_count > 0) {
            var i: usize = remove_count;
            while (i > 0) {
                i -= 1;
                const rm_idx = remove_indices[i];
                const job = self.jobs.items[rm_idx];
                self.deinitJob(job);
                _ = self.jobs.orderedRemove(rm_idx);
            }
        }

        return changed;
    }
};

const LoadPolicy = enum {
    best_effort,
    strict,
};

fn loadJobsWithPolicy(scheduler: *CronScheduler, policy: LoadPolicy) !void {
    const path = try cronStorePathForScheduler(scheduler.allocator, scheduler);
    defer scheduler.allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(scheduler.allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return,
        else => switch (policy) {
            .best_effort => return,
            .strict => return err,
        },
    };
    defer scheduler.allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, scheduler.allocator, content, .{}) catch |err| switch (policy) {
        .best_effort => return,
        .strict => return err,
    };
    defer parsed.deinit();

    if (parsed.value != .array) switch (policy) {
        .best_effort => return,
        .strict => return error.InvalidCronStoreFormat,
    };

    for (parsed.value.array.items) |item| {
        if (item != .object) switch (policy) {
            .best_effort => continue,
            .strict => return error.InvalidCronStoreFormat,
        };
        appendJobFromJsonObjectWithPolicy(scheduler, item.object, policy) catch |err| switch (policy) {
            .best_effort => {
                log.warn("skipping invalid cron job entry: {s}", .{@errorName(err)});
                continue;
            },
            .strict => return err,
        };
    }
}

fn appendJobFromJsonObjectWithPolicy(scheduler: *CronScheduler, obj: std.json.ObjectMap, policy: LoadPolicy) !void {
    const id = blk: {
        if (obj.get("id")) |v| {
            if (v == .string and v.string.len > 0) break :blk v.string;
        }
        return error.InvalidCronStoreFormat;
    };
    const expression = blk: {
        if (obj.get("expression")) |v| {
            if (v == .string and v.string.len > 0) break :blk v.string;
        }
        return error.InvalidCronStoreFormat;
    };
    const command = blk: {
        if (obj.get("command")) |v| {
            if (v == .string and v.string.len > 0) break :blk v.string;
        }
        return error.InvalidCronStoreFormat;
    };

    const next_run_secs: i64 = blk: {
        if (obj.get("next_run_secs")) |v| {
            if (v == .integer) break :blk v.integer;
        }
        break :blk std.time.timestamp() + 60;
    };

    const paused = blk: {
        if (obj.get("paused")) |v| {
            if (v == .bool) break :blk v.bool;
        }
        break :blk false;
    };

    const one_shot = blk: {
        if (obj.get("one_shot")) |v| {
            if (v == .bool) break :blk v.bool;
        }
        break :blk false;
    };
    const job_type = blk: {
        if (obj.get("job_type")) |v| {
            if (v == .string) break :blk JobType.parse(v.string);
        }
        break :blk JobType.shell;
    };
    const session_target = blk: {
        if (obj.get("session_target")) |v| {
            if (v == .string) break :blk SessionTarget.parse(v.string);
        }
        break :blk SessionTarget.isolated;
    };
    const enabled = blk: {
        if (obj.get("enabled")) |v| {
            if (v == .bool) break :blk v.bool;
        }
        break :blk !paused;
    };
    const delete_after_run = blk: {
        if (obj.get("delete_after_run")) |v| {
            if (v == .bool) break :blk v.bool;
        }
        break :blk one_shot;
    };
    const created_at_s = blk: {
        if (obj.get("created_at_s")) |v| {
            if (v == .integer) break :blk v.integer;
        }
        break :blk 0;
    };
    const last_run_secs: ?i64 = blk: {
        if (obj.get("last_run_secs")) |v| {
            if (v == .integer) break :blk v.integer;
        }
        break :blk null;
    };
    const last_status: ?[]const u8 = blk: {
        if (obj.get("last_status")) |v| {
            if (v == .string) {
                if (std.ascii.eqlIgnoreCase(v.string, "ok")) break :blk "ok";
                if (std.ascii.eqlIgnoreCase(v.string, "error")) break :blk "error";
            }
        }
        break :blk null;
    };

    var prompt: ?[]const u8 = null;
    errdefer if (prompt) |v| scheduler.allocator.free(v);
    if (obj.get("prompt")) |v| {
        if (v == .string and v.string.len > 0) {
            prompt = try scheduler.allocator.dupe(u8, v.string);
        }
    }
    var name: ?[]const u8 = null;
    errdefer if (name) |v| scheduler.allocator.free(v);
    if (obj.get("name")) |v| {
        if (v == .string and v.string.len > 0) {
            name = try scheduler.allocator.dupe(u8, v.string);
        }
    }
    var model: ?[]const u8 = null;
    errdefer if (model) |v| scheduler.allocator.free(v);
    if (obj.get("model")) |v| {
        if (v == .string and v.string.len > 0) {
            model = try scheduler.allocator.dupe(u8, v.string);
        }
    }
    var last_output: ?[]const u8 = null;
    errdefer if (last_output) |v| scheduler.allocator.free(v);
    if (obj.get("last_output")) |v| {
        if (v == .string and v.string.len > 0) {
            last_output = try scheduler.allocator.dupe(u8, v.string);
        }
    }

    var delivery_channel: ?[]const u8 = null;
    errdefer if (delivery_channel) |v| scheduler.allocator.free(v);
    var delivery_to: ?[]const u8 = null;
    errdefer if (delivery_to) |v| scheduler.allocator.free(v);
    var delivery = DeliveryConfig{};
    if (obj.get("delivery")) |v| {
        if (v == .object) {
            if (v.object.get("mode")) |mode_val| {
                if (mode_val == .string) delivery.mode = DeliveryMode.parse(mode_val.string);
            }
            if (v.object.get("channel")) |channel_val| {
                if (channel_val == .string and channel_val.string.len > 0) {
                    delivery_channel = try scheduler.allocator.dupe(u8, channel_val.string);
                }
            }
            if (v.object.get("to")) |to_val| {
                if (to_val == .string and to_val.string.len > 0) {
                    delivery_to = try scheduler.allocator.dupe(u8, to_val.string);
                }
            }
            if (v.object.get("best_effort")) |be_val| {
                if (be_val == .bool) delivery.best_effort = be_val.bool;
            }
        } else switch (policy) {
            .best_effort => {},
            .strict => return error.InvalidCronStoreFormat,
        }
    }
    delivery.channel = delivery_channel;
    delivery.to = delivery_to;

    try scheduler.jobs.append(scheduler.allocator, .{
        .id = try scheduler.allocator.dupe(u8, id),
        .expression = try scheduler.allocator.dupe(u8, expression),
        .command = try scheduler.allocator.dupe(u8, command),
        .next_run_secs = next_run_secs,
        .last_run_secs = last_run_secs,
        .last_status = last_status,
        .paused = paused,
        .one_shot = one_shot,
        .job_type = job_type,
        .session_target = session_target,
        .prompt = prompt,
        .prompt_owned = prompt != null,
        .name = name,
        .name_owned = name != null,
        .model = model,
        .model_owned = model != null,
        .enabled = enabled,
        .delete_after_run = delete_after_run,
        .created_at_s = created_at_s,
        .last_output = last_output,
        .last_output_owned = last_output != null,
        .delivery = delivery,
        .delivery_channel_owned = delivery.channel != null,
        .delivery_to_owned = delivery.to != null,
    });
}

pub fn appendJobFromJsonObject(scheduler: *CronScheduler, obj: std.json.ObjectMap) !void {
    return appendJobFromJsonObjectWithPolicy(scheduler, obj, .strict);
}

pub fn loadJobFromJsonSlice(scheduler: *CronScheduler, content: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, scheduler.allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCronStoreFormat;
    try appendJobFromJsonObject(scheduler, parsed.value.object);
}

fn appendJobJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, job: CronJob) !void {
    try buf.appendSlice(allocator, "{");

    try json_util.appendJsonKeyValue(buf, allocator, "id", job.id);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(buf, allocator, "expression", job.expression);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(buf, allocator, "command", job.command);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "next_run_secs", job.next_run_secs);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "last_run_secs");
    if (job.last_run_secs) |lrs| {
        var int_buf: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&int_buf, "{d}", .{lrs}) catch unreachable;
        try buf.appendSlice(allocator, text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "last_status");
    if (job.last_status) |ls| {
        try json_util.appendJsonString(buf, allocator, ls);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "paused");
    try buf.appendSlice(allocator, if (job.paused) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "one_shot");
    try buf.appendSlice(allocator, if (job.one_shot) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(buf, allocator, "job_type", job.job_type.asStr());
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(buf, allocator, "session_target", job.session_target.asStr());
    try buf.appendSlice(allocator, ",");
    try appendNullableJsonStringField(buf, allocator, "prompt", job.prompt);
    try buf.appendSlice(allocator, ",");
    try appendNullableJsonStringField(buf, allocator, "name", job.name);
    try buf.appendSlice(allocator, ",");
    try appendNullableJsonStringField(buf, allocator, "model", job.model);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "enabled");
    try buf.appendSlice(allocator, if (job.enabled) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "delete_after_run");
    try buf.appendSlice(allocator, if (job.delete_after_run) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(buf, allocator, "created_at_s", job.created_at_s);
    try buf.appendSlice(allocator, ",");
    try appendNullableJsonStringField(buf, allocator, "last_output", job.last_output);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "delivery");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonKeyValue(buf, allocator, "mode", job.delivery.mode.asStr());
    try buf.appendSlice(allocator, ",");
    try appendNullableJsonStringField(buf, allocator, "channel", job.delivery.channel);
    try buf.appendSlice(allocator, ",");
    try appendNullableJsonStringField(buf, allocator, "to", job.delivery.to);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "best_effort");
    try buf.appendSlice(allocator, if (job.delivery.best_effort) "true" else "false");
    try buf.appendSlice(allocator, "}");

    try buf.appendSlice(allocator, "}");
}

pub fn jobToJson(allocator: std.mem.Allocator, job: *const CronJob) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try appendJobJson(&buf, allocator, job.*);
    return buf.toOwnedSlice(allocator);
}

pub fn saveJobsToSlice(allocator: std.mem.Allocator, scheduler: *const CronScheduler) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "[\n");
    for (scheduler.jobs.items, 0..) |job, i| {
        if (i > 0) try buf.appendSlice(allocator, ",\n");
        try buf.appendSlice(allocator, "  ");
        try appendJobJson(&buf, allocator, job);
    }
    try buf.appendSlice(allocator, "\n]\n");
    return buf.toOwnedSlice(allocator);
}

// ── Delivery ─────────────────────────────────────────────────────

/// Deliver a cron job result to a channel via the outbound bus.
/// Returns true if a message was published, false if delivery was skipped.
pub fn deliverResult(
    allocator: std.mem.Allocator,
    delivery: DeliveryConfig,
    output: []const u8,
    success: bool,
    out_bus: *bus.Bus,
) !bool {
    // Skip if mode is none
    if (delivery.mode == .none) return false;

    // Skip if no channel configured
    const channel = delivery.channel orelse return false;

    // Check mode-specific conditions
    switch (delivery.mode) {
        .none => return false,
        .on_success => if (!success) return false,
        .on_error => if (success) return false,
        .always => {},
    }

    // Skip empty output
    if (output.len == 0) return false;

    const chat_id = delivery.to orelse "default";
    const msg = try bus.makeOutbound(allocator, channel, chat_id, output);
    out_bus.publishOutbound(msg) catch |err| {
        // If best_effort, swallow the error after cleaning up
        if (delivery.best_effort) {
            msg.deinit(allocator);
            return false;
        }
        msg.deinit(allocator);
        return err;
    };
    return true;
}

fn shouldDeliver(delivery: DeliveryConfig, output: []const u8, success: bool) bool {
    if (delivery.mode == .none) return false;
    if (delivery.channel == null) return false;
    if (output.len == 0) return false;
    switch (delivery.mode) {
        .none => return false,
        .on_success => return success,
        .on_error => return !success,
        .always => return true,
    }
}

const AutonomyPolicy = struct {
    quiet_hours_enabled: bool = false,
    quiet_start_hour: u8 = 22,
    quiet_end_hour: u8 = 8,
    quiet_timezone_offset_minutes: i32 = 0,
    notification_rate_limit_per_hour: u32 = 20,
    retry_budget: u8 = 2,
};

const NotificationRateState = struct {
    window_start_s: i64,
    sent_count: u32,
};

fn applyAutonomyPolicyFields(policy: *AutonomyPolicy, obj: anytype) void {
    if (obj.get("notification_rate_limit_per_hour")) |v| {
        if (v == .integer) {
            const clamped = std.math.clamp(v.integer, @as(i64, 0), @as(i64, std.math.maxInt(u32)));
            policy.notification_rate_limit_per_hour = @intCast(clamped);
        }
    }
    if (obj.get("retry_budget")) |v| {
        if (v == .integer) {
            const clamped = std.math.clamp(v.integer, @as(i64, 0), @as(i64, std.math.maxInt(u8)));
            policy.retry_budget = @intCast(clamped);
        }
    }

    if (obj.get("quiet_hours")) |qh| {
        if (qh == .object) {
            var has_hours = false;
            if (qh.object.get("start_hour")) |v| {
                if (v == .integer and v.integer >= 0 and v.integer <= 23) {
                    policy.quiet_start_hour = @intCast(v.integer);
                    has_hours = true;
                }
            }
            if (qh.object.get("end_hour")) |v| {
                if (v == .integer and v.integer >= 0 and v.integer <= 23) {
                    policy.quiet_end_hour = @intCast(v.integer);
                    has_hours = true;
                }
            }
            if (qh.object.get("timezone_offset_minutes")) |v| {
                if (v == .integer) {
                    const clamped = std.math.clamp(v.integer, @as(i64, -24 * 60), @as(i64, 24 * 60));
                    policy.quiet_timezone_offset_minutes = @intCast(clamped);
                }
            }
            if (qh.object.get("enabled")) |v| {
                if (v == .bool) {
                    policy.quiet_hours_enabled = v.bool;
                }
            } else if (has_hours) {
                policy.quiet_hours_enabled = true;
            }
        }
    }
}

fn loadAutonomyPolicy(allocator: std.mem.Allocator, user_root: []const u8) !AutonomyPolicy {
    var policy = AutonomyPolicy{};
    const path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{user_root});
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return policy,
        else => return err,
    };
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, 256 * 1024);
    defer allocator.free(raw);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return policy;
    defer parsed.deinit();
    if (parsed.value != .object) return policy;

    if (parsed.value.object.get("autonomy_policy")) |policy_obj| {
        if (policy_obj == .object) {
            applyAutonomyPolicyFields(&policy, policy_obj.object);
        }
    }
    if (parsed.value.object.get("autonomy")) |policy_obj| {
        if (policy_obj == .object) {
            applyAutonomyPolicyFields(&policy, policy_obj.object);
        }
    }

    return policy;
}

fn jsonBoolField(body: []const u8, key: []const u8) ?bool {
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, body, pattern) orelse return null;
    const after_key = body[key_pos + pattern.len ..];
    const colon = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    const raw = std.mem.trim(u8, after_key[colon + 1 ..], " \t\r\n");
    if (std.mem.startsWith(u8, raw, "true")) return true;
    if (std.mem.startsWith(u8, raw, "false")) return false;
    return null;
}

fn readTrimmedFileOwned(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(content);
    return out;
}

fn parseChatIdString(raw: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn notificationRateStatePath(allocator: std.mem.Allocator, user_root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/notification_rate.json", .{user_root});
}

fn loadNotificationRateState(
    allocator: std.mem.Allocator,
    user_root: []const u8,
    now_s: i64,
) NotificationRateState {
    const path = notificationRateStatePath(allocator, user_root) catch return .{
        .window_start_s = now_s,
        .sent_count = 0,
    };
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return .{
        .window_start_s = now_s,
        .sent_count = 0,
    };
    defer file.close();
    const raw = file.readToEndAlloc(allocator, 64 * 1024) catch return .{
        .window_start_s = now_s,
        .sent_count = 0,
    };
    defer allocator.free(raw);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return .{
        .window_start_s = now_s,
        .sent_count = 0,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{
        .window_start_s = now_s,
        .sent_count = 0,
    };

    var state = NotificationRateState{
        .window_start_s = now_s,
        .sent_count = 0,
    };
    if (parsed.value.object.get("window_start_s")) |v| {
        if (v == .integer) state.window_start_s = v.integer;
    }
    if (parsed.value.object.get("sent_count")) |v| {
        if (v == .integer and v.integer >= 0) {
            const clamped = std.math.clamp(v.integer, @as(i64, 0), @as(i64, std.math.maxInt(u32)));
            state.sent_count = @intCast(clamped);
        }
    }
    return state;
}

fn saveNotificationRateState(
    allocator: std.mem.Allocator,
    user_root: []const u8,
    state: NotificationRateState,
) !void {
    const path = try notificationRateStatePath(allocator, user_root);
    defer allocator.free(path);

    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = body.writer(allocator);
    try w.print("{{\"window_start_s\":{d},\"sent_count\":{d}}}", .{
        state.window_start_s,
        state.sent_count,
    });
    try writeFileAtomic(allocator, path, body.items);
}

fn allowNotificationByRateLimit(
    allocator: std.mem.Allocator,
    user_root: []const u8,
    per_hour_limit: u32,
    now_s: i64,
) !bool {
    if (per_hour_limit == 0) return true;

    var state = loadNotificationRateState(allocator, user_root, now_s);
    if (now_s - state.window_start_s >= 3600 or now_s < state.window_start_s) {
        state.window_start_s = now_s;
        state.sent_count = 0;
    }
    if (state.sent_count >= per_hour_limit) return false;
    state.sent_count += 1;
    try saveNotificationRateState(allocator, user_root, state);
    return true;
}

fn isInQuietHours(policy: AutonomyPolicy, now_s: i64) bool {
    if (!policy.quiet_hours_enabled) return false;
    if (policy.quiet_start_hour == policy.quiet_end_hour) return false;

    const shifted_now = now_s + @as(i64, policy.quiet_timezone_offset_minutes) * 60;
    const day_seconds = @mod(shifted_now, 24 * 3600);
    const hour: u8 = @intCast(@divFloor(day_seconds, 3600));

    if (policy.quiet_start_hour < policy.quiet_end_hour) {
        return hour >= policy.quiet_start_hour and hour < policy.quiet_end_hour;
    }
    return hour >= policy.quiet_start_hour or hour < policy.quiet_end_hour;
}

fn loadTelegramChatIdFromChannelState(allocator: std.mem.Allocator, user_root: []const u8) ?i64 {
    const path = std.fmt.allocPrint(allocator, "{s}/channel_state.json", .{user_root}) catch return null;
    defer allocator.free(path);
    const content = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer content.close();
    const raw = content.readToEndAlloc(allocator, 64 * 1024) catch return null;
    defer allocator.free(raw);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const telegram_obj = parsed.value.object.get("telegram") orelse return null;
    if (telegram_obj != .object) return null;
    const chat_id = telegram_obj.object.get("chat_id") orelse return null;
    if (chat_id == .integer) return chat_id.integer;
    if (chat_id == .string) return parseChatIdString(chat_id.string);
    return null;
}

fn deliverTenantTelegram(
    allocator: std.mem.Allocator,
    user_root: []const u8,
    delivery: DeliveryConfig,
    output: []const u8,
    success: bool,
) !bool {
    if (!shouldDeliver(delivery, output, success)) return false;
    const channel = delivery.channel orelse return false;
    if (!std.ascii.eqlIgnoreCase(channel, "telegram")) return false;
    const now_s = std.time.timestamp();
    const policy = loadAutonomyPolicy(allocator, user_root) catch AutonomyPolicy{};
    if (isInQuietHours(policy, now_s)) return false;
    if (!(try allowNotificationByRateLimit(allocator, user_root, policy.notification_rate_limit_per_hour, now_s))) {
        return false;
    }

    const token_path = try std.fmt.allocPrint(allocator, "{s}/secrets/telegram_bot_token", .{user_root});
    defer allocator.free(token_path);
    const token_owned = try readTrimmedFileOwned(allocator, token_path);
    defer if (token_owned) |v| allocator.free(v);
    const bot_token = token_owned orelse return false;
    if (bot_token.len == 0) return false;

    const chat_id = if (delivery.to) |to|
        parseChatIdString(to) orelse return false
    else
        loadTelegramChatIdFromChannelState(allocator, user_root) orelse return false;

    const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{bot_token});
    defer allocator.free(url);

    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    try body.append(allocator, '{');
    try json_util.appendJsonInt(&body, allocator, "chat_id", chat_id);
    try body.append(allocator, ',');
    try json_util.appendJsonKeyValue(&body, allocator, "text", output);
    try body.append(allocator, '}');

    const max_attempts: u32 = @as(u32, policy.retry_budget) + 1;
    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const response = http_util.curlPostWithProxy(allocator, url, body.items, &.{}, null, "30") catch |err| {
            if (attempt + 1 >= max_attempts) {
                if (delivery.best_effort) return false;
                return err;
            }
            const backoff_ms: u64 = @intCast(@min(@as(u32, 5000), @as(u32, 500) * (attempt + 1)));
            std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(response);
        const ok = jsonBoolField(response, "ok") orelse false;
        if (ok) return true;
        if (attempt + 1 >= max_attempts) {
            if (delivery.best_effort) return false;
            return error.DeliveryFailed;
        }
        const backoff_ms: u64 = @intCast(@min(@as(u32, 5000), @as(u32, 500) * (attempt + 1)));
        std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
    }
    return false;
}

fn deliverResultForContext(
    allocator: std.mem.Allocator,
    context_user_root: ?[]const u8,
    delivery: DeliveryConfig,
    output: []const u8,
    success: bool,
    out_bus: *bus.Bus,
) !bool {
    if (context_user_root) |user_root| {
        if (delivery.channel) |channel| {
            if (std.ascii.eqlIgnoreCase(channel, "telegram")) {
                return deliverTenantTelegram(allocator, user_root, delivery, output, success) catch |err| blk: {
                    if (!delivery.best_effort) return err;
                    break :blk false;
                };
            }
        }
    }
    return deliverResult(allocator, delivery, output, success, out_bus);
}

// ── JSON Persistence ─────────────────────────────────────────────

/// Serializable representation of a cron job for JSON persistence.
const JsonCronJob = struct {
    id: []const u8,
    expression: []const u8,
    command: []const u8,
    next_run_secs: i64,
    last_run_secs: ?i64,
    last_status: ?[]const u8,
    paused: bool,
    one_shot: bool,
};

/// Get the default cron.json path: ~/.nullclaw/cron.json
fn cronJsonPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".nullclaw", "cron.json" });
}

fn cronStorePathForScheduler(allocator: std.mem.Allocator, scheduler: *const CronScheduler) ![]const u8 {
    if (scheduler.store_path) |path| {
        return allocator.dupe(u8, path);
    }
    return cronJsonPath(allocator);
}

fn ensureCronDirForPath(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn appendNullableJsonStringField(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    value: ?[]const u8,
) !void {
    try json_util.appendJsonKey(buf, allocator, key);
    if (value) |v| {
        try json_util.appendJsonString(buf, allocator, v);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

/// Save scheduler jobs to ~/.nullclaw/cron.json.
pub fn saveJobs(scheduler: *const CronScheduler) !void {
    const path = try cronStorePathForScheduler(scheduler.allocator, scheduler);
    defer scheduler.allocator.free(path);
    try ensureCronDirForPath(path);
    const content = try saveJobsToSlice(scheduler.allocator, scheduler);
    defer scheduler.allocator.free(content);
    try writeFileAtomic(scheduler.allocator, path, content);
}

pub fn saveJobsToPath(scheduler: *CronScheduler, path: []const u8) !void {
    try scheduler.setStorePath(path);
    try saveJobs(scheduler);
}

/// Load jobs from ~/.nullclaw/cron.json into the scheduler.
pub fn loadJobs(scheduler: *CronScheduler) !void {
    try loadJobsWithPolicy(scheduler, .best_effort);
}

/// Load jobs from ~/.nullclaw/cron.json; unlike loadJobs, this returns
/// parse/read errors (except missing file/path).
pub fn loadJobsStrict(scheduler: *CronScheduler) !void {
    try loadJobsWithPolicy(scheduler, .strict);
}

pub fn loadJobsFromPath(scheduler: *CronScheduler, path: []const u8) !void {
    try scheduler.setStorePath(path);
    try loadJobs(scheduler);
}

pub fn loadJobsStrictFromPath(scheduler: *CronScheduler, path: []const u8) !void {
    try scheduler.setStorePath(path);
    try loadJobsStrict(scheduler);
}

/// Replace in-memory jobs with the persisted store content.
pub fn reloadJobs(scheduler: *CronScheduler) !void {
    var loaded = CronScheduler.init(scheduler.allocator, scheduler.max_tasks, scheduler.enabled);
    defer loaded.deinit();
    if (scheduler.store_path) |path| {
        try loaded.setStorePath(path);
    }
    loadJobsStrict(&loaded) catch |err| {
        if (isRecoverableCronStoreError(err)) {
            // Heal malformed/truncated cron.json by persisting current in-memory jobs.
            // This prevents endless reload warnings after upgrades or interrupted writes.
            try saveJobs(scheduler);
            return;
        }
        return err;
    };
    std.mem.swap(std.ArrayListUnmanaged(CronJob), &scheduler.jobs, &loaded.jobs);
}

fn writeFileAtomic(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const tmp_file = try std.fs.createFileAbsolute(tmp_path, .{});
    errdefer tmp_file.close();
    try tmp_file.writeAll(data);
    tmp_file.close();

    std.fs.renameAbsolute(tmp_path, path) catch {
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(data);
    };
}

fn isRecoverableCronStoreError(err: anyerror) bool {
    return switch (err) {
        error.UnexpectedEndOfInput,
        error.SyntaxError,
        error.InvalidCronStoreFormat,
        => true,
        else => false,
    };
}

// ── CLI entry points (called from main.zig) ──────────────────────

/// CLI: list all cron jobs.
pub fn cliListJobs(allocator: std.mem.Allocator) !void {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    const jobs = scheduler.listJobs();
    if (jobs.len == 0) {
        log.info("No scheduled tasks yet.", .{});
        log.info("Usage:", .{});
        log.info("  nullclaw cron add '*/10 * * * *' 'echo hello'", .{});
        log.info("  nullclaw cron once 30m 'echo reminder'", .{});
        return;
    }

    log.info("Scheduled jobs ({d}):", .{jobs.len});
    for (jobs) |job| {
        const flags: []const u8 = blk: {
            if (job.paused and job.one_shot) break :blk " [paused, one-shot]";
            if (job.paused) break :blk " [paused]";
            if (job.one_shot) break :blk " [one-shot]";
            break :blk "";
        };
        const status = job.last_status orelse "n/a";
        log.info("- {s} | {s} | next={d} | status={s}{s} cmd: {s}", .{
            job.id,
            job.expression,
            job.next_run_secs,
            status,
            flags,
            job.command,
        });
    }
}

/// CLI: add a recurring cron job.
pub fn cliAddJob(allocator: std.mem.Allocator, expression: []const u8, command: []const u8) !void {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    const job = try scheduler.addJob(expression, command);
    try saveJobs(&scheduler);

    log.info("Added cron job {s}", .{job.id});
    log.info("  Expr: {s}", .{job.expression});
    log.info("  Next: {d}", .{job.next_run_secs});
    log.info("  Cmd : {s}", .{job.command});
}

/// CLI: add a one-shot delayed task.
pub fn cliAddOnce(allocator: std.mem.Allocator, delay: []const u8, command: []const u8) !void {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    const job = try scheduler.addOnce(delay, command);
    try saveJobs(&scheduler);

    log.info("Added one-shot task {s}", .{job.id});
    log.info("  Runs at: {d}", .{job.next_run_secs});
    log.info("  Cmd    : {s}", .{job.command});
}

/// CLI: remove a cron job by ID.
pub fn cliRemoveJob(allocator: std.mem.Allocator, id: []const u8) !void {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    if (scheduler.removeJob(id)) {
        try saveJobs(&scheduler);
        log.info("Removed cron job {s}", .{id});
    } else {
        log.warn("Cron job '{s}' not found", .{id});
    }
}

/// CLI: pause a cron job by ID.
pub fn cliPauseJob(allocator: std.mem.Allocator, id: []const u8) !void {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    if (scheduler.pauseJob(id)) {
        try saveJobs(&scheduler);
        log.info("Paused job {s}", .{id});
    } else {
        log.warn("Cron job '{s}' not found", .{id});
    }
}

/// CLI: resume a paused cron job by ID.
pub fn cliResumeJob(allocator: std.mem.Allocator, id: []const u8) !void {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    if (scheduler.resumeJob(id)) {
        try saveJobs(&scheduler);
        log.info("Resumed job {s}", .{id});
    } else {
        log.warn("Cron job '{s}' not found", .{id});
    }
}

pub fn cliRunJob(allocator: std.mem.Allocator, id: []const u8) !void {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    if (scheduler.getJob(id)) |job| {
        log.info("Running job '{s}': {s}", .{ id, job.command });
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ platform.getShell(), platform.getShellFlag(), job.command },
        }) catch |err| {
            log.err("Job '{s}' failed: {s}", .{ id, @errorName(err) });
            return;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.stdout.len > 0) log.info("{s}", .{result.stdout});
        const exit_code: u8 = switch (result.term) {
            .Exited => |code| code,
            else => 1,
        };
        log.info("Job '{s}' completed (exit {d}).", .{ id, exit_code });
    } else {
        log.warn("Cron job '{s}' not found", .{id});
    }
}

/// CLI: update a cron job's expression, command, or enabled state.
pub fn cliUpdateJob(
    allocator: std.mem.Allocator,
    id: []const u8,
    expression: ?[]const u8,
    command: ?[]const u8,
    enabled: ?bool,
) !void {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    const patch = CronJobPatch{
        .expression = expression,
        .command = command,
        .enabled = enabled,
    };
    if (scheduler.updateJob(allocator, id, patch)) {
        try saveJobs(&scheduler);
        log.info("Updated job {s}", .{id});
    } else {
        log.warn("Cron job '{s}' not found", .{id});
    }
}

/// CLI: list run history for a cron job.
pub fn cliListRuns(allocator: std.mem.Allocator, id: []const u8) !void {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    defer scheduler.deinit();
    try loadJobs(&scheduler);

    if (scheduler.getJob(id)) |job| {
        log.info("Run history for job {s} ({s}):", .{ id, job.command });
        const status = job.last_status orelse "never run";
        log.info("  Last status: {s}", .{status});
        log.info("  Next run:    {d}", .{job.next_run_secs});
    } else {
        log.warn("Cron job '{s}' not found", .{id});
    }
}

// ── Backwards-compatible type alias ──────────────────────────────────

pub const Task = CronJob;

// ── Tests ────────────────────────────────────────────────────────────

test "parseDuration minutes" {
    try std.testing.expectEqual(@as(i64, 1800), try parseDuration("30m"));
}

test "parseDuration hours" {
    try std.testing.expectEqual(@as(i64, 7200), try parseDuration("2h"));
}

test "parseDuration days" {
    try std.testing.expectEqual(@as(i64, 86400), try parseDuration("1d"));
}

test "parseDuration weeks" {
    try std.testing.expectEqual(@as(i64, 604800), try parseDuration("1w"));
}

test "parseDuration seconds" {
    try std.testing.expectEqual(@as(i64, 30), try parseDuration("30s"));
}

test "parseDuration default unit is minutes" {
    try std.testing.expectEqual(@as(i64, 300), try parseDuration("5"));
}

test "parseDuration empty returns error" {
    try std.testing.expectError(error.EmptyDelay, parseDuration(""));
}

test "parseDuration unknown unit" {
    try std.testing.expectError(error.UnknownDurationUnit, parseDuration("5x"));
}

test "normalizeExpression 5 fields" {
    const result = try normalizeExpression("*/5 * * * *");
    try std.testing.expect(result.needs_second_prefix);
}

test "normalizeExpression 6 fields" {
    const result = try normalizeExpression("0 */5 * * * *");
    try std.testing.expect(!result.needs_second_prefix);
}

test "normalizeExpression 4 fields invalid" {
    try std.testing.expectError(error.InvalidCronExpression, normalizeExpression("* * * *"));
}

test "nextRunForCronExpression supports step minutes" {
    try std.testing.expectEqual(@as(i64, 300), try nextRunForCronExpression("*/5 * * * *", 0));
}

test "nextRunForCronExpression supports hourly schedule" {
    try std.testing.expectEqual(@as(i64, 3600), try nextRunForCronExpression("0 * * * *", 0));
}

test "nextRunForCronExpression supports fixed time schedule" {
    try std.testing.expectEqual(@as(i64, 9000), try nextRunForCronExpression("30 2 * * *", 0));
}

test "nextRunForCronExpression supports sunday aliases 0 and 7" {
    const next_sun_zero = try nextRunForCronExpression("0 0 * * 0", 0);
    const next_sun_seven = try nextRunForCronExpression("0 0 * * 7", 0);
    try std.testing.expectEqual(next_sun_zero, next_sun_seven);
}

test "nextRunForCronExpression handles leap-day schedules beyond one year" {
    try std.testing.expectEqual(@as(i64, 68169600), try nextRunForCronExpression("0 0 29 2 *", 0));
}

test "CronScheduler add and list" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/10 * * * *", "echo roundtrip");
    try std.testing.expectEqualStrings("*/10 * * * *", job.expression);
    try std.testing.expectEqualStrings("echo roundtrip", job.command);
    try std.testing.expect(!job.one_shot);
    try std.testing.expect(!job.paused);

    const listed = scheduler.listJobs();
    try std.testing.expectEqual(@as(usize, 1), listed.len);
}

test "CronScheduler addOnce creates one-shot" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addOnce("30m", "echo once");
    try std.testing.expect(job.one_shot);
}

test "CronScheduler remove" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/10 * * * *", "echo test");
    try std.testing.expect(scheduler.removeJob(job.id));
    try std.testing.expectEqual(@as(usize, 0), scheduler.listJobs().len);
}

test "CronScheduler pause and resume" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/5 * * * *", "echo pause");
    try std.testing.expect(scheduler.pauseJob(job.id));
    try std.testing.expect(scheduler.getJob(job.id).?.paused);
    try std.testing.expect(scheduler.resumeJob(job.id));
    try std.testing.expect(!scheduler.getJob(job.id).?.paused);
}

test "CronScheduler max tasks enforced" {
    var scheduler = CronScheduler.init(std.testing.allocator, 1, true);
    defer scheduler.deinit();

    _ = try scheduler.addJob("*/10 * * * *", "echo first");
    try std.testing.expectError(error.MaxTasksReached, scheduler.addJob("*/11 * * * *", "echo second"));
}

test "CronScheduler getJob found and missing" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addJob("*/5 * * * *", "echo found");
    try std.testing.expect(scheduler.getJob(job.id) != null);
    try std.testing.expect(scheduler.getJob("nonexistent") == null);
}

test "save and load roundtrip" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    _ = try scheduler.addJob("*/10 * * * *", "echo roundtrip");
    _ = try scheduler.addOnce("5m", "echo oneshot");

    // Save to disk
    try saveJobs(&scheduler);

    // Load into a new scheduler
    var scheduler2 = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler2.deinit();
    try loadJobs(&scheduler2);

    try std.testing.expectEqual(@as(usize, 2), scheduler2.listJobs().len);

    const loaded = scheduler2.listJobs();
    try std.testing.expectEqualStrings("*/10 * * * *", loaded[0].expression);
    try std.testing.expectEqualStrings("echo roundtrip", loaded[0].command);
    try std.testing.expect(loaded[1].one_shot);
}

test "reloadJobs auto-recovers malformed store and keeps runtime jobs" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();
    _ = try scheduler.addJob("*/10 * * * *", "echo keep");
    try saveJobs(&scheduler);

    var runtime = CronScheduler.init(std.testing.allocator, 10, true);
    defer runtime.deinit();
    try loadJobs(&runtime);
    try std.testing.expectEqual(@as(usize, 1), runtime.listJobs().len);

    const path = try cronJsonPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    const bad_file = try std.fs.createFileAbsolute(path, .{});
    defer bad_file.close();
    try bad_file.writeAll("{bad-json");

    try reloadJobs(&runtime);
    try std.testing.expectEqual(@as(usize, 1), runtime.listJobs().len);

    // Store should be healed and parseable again.
    var healed = CronScheduler.init(std.testing.allocator, 10, true);
    defer healed.deinit();
    try loadJobsStrict(&healed);
    try std.testing.expectEqual(@as(usize, 1), healed.listJobs().len);
}

test "save and load roundtrip with JSON-sensitive command characters" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    const cmd = "printf \"line1\\nline2\" && echo \\\"ok\\\"";
    _ = try scheduler.addJob("*/5 * * * *", cmd);

    try saveJobs(&scheduler);

    var loaded = CronScheduler.init(std.testing.allocator, 10, true);
    defer loaded.deinit();
    try loadJobsStrict(&loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.listJobs().len);
    try std.testing.expectEqualStrings(cmd, loaded.listJobs()[0].command);
}

test "save and load preserves extended cron fields" {
    var scheduler = CronScheduler.init(std.testing.allocator, 10, true);
    defer scheduler.deinit();

    _ = try scheduler.addJob("*/5 * * * *", "echo extended");
    scheduler.jobs.items[0].job_type = .agent;
    scheduler.jobs.items[0].session_target = .main;
    scheduler.jobs.items[0].prompt = try std.testing.allocator.dupe(u8, "daily summary");
    scheduler.jobs.items[0].prompt_owned = true;
    scheduler.jobs.items[0].name = try std.testing.allocator.dupe(u8, "Daily Summary");
    scheduler.jobs.items[0].name_owned = true;
    scheduler.jobs.items[0].model = try std.testing.allocator.dupe(u8, "openai/gpt-4.1");
    scheduler.jobs.items[0].model_owned = true;
    scheduler.jobs.items[0].delete_after_run = true;
    scheduler.jobs.items[0].delivery = .{
        .mode = .always,
        .channel = try std.testing.allocator.dupe(u8, "telegram"),
        .to = try std.testing.allocator.dupe(u8, "chat-1"),
        .best_effort = false,
    };
    scheduler.jobs.items[0].delivery_channel_owned = true;
    scheduler.jobs.items[0].delivery_to_owned = true;

    try saveJobs(&scheduler);

    var loaded = CronScheduler.init(std.testing.allocator, 10, true);
    defer loaded.deinit();
    try loadJobsStrict(&loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.listJobs().len);

    const job = loaded.listJobs()[0];
    try std.testing.expectEqual(JobType.agent, job.job_type);
    try std.testing.expectEqual(SessionTarget.main, job.session_target);
    try std.testing.expectEqualStrings("daily summary", job.prompt.?);
    try std.testing.expectEqualStrings("Daily Summary", job.name.?);
    try std.testing.expectEqualStrings("openai/gpt-4.1", job.model.?);
    try std.testing.expect(job.delete_after_run);
    try std.testing.expectEqual(DeliveryMode.always, job.delivery.mode);
    try std.testing.expectEqualStrings("telegram", job.delivery.channel.?);
    try std.testing.expectEqualStrings("chat-1", job.delivery.to.?);
    try std.testing.expect(!job.delivery.best_effort);
}

fn testAgentRunner(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: *const CronScheduler,
    _: *const CronJob,
    prompt: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "ran:{s}", .{prompt});
}

test "JobType parse and asStr" {
    try std.testing.expectEqual(JobType.shell, JobType.parse("shell"));
    try std.testing.expectEqual(JobType.agent, JobType.parse("agent"));
    try std.testing.expectEqual(JobType.agent, JobType.parse("AGENT"));
    try std.testing.expectEqualStrings("shell", JobType.shell.asStr());
    try std.testing.expectEqualStrings("agent", JobType.agent.asStr());
}

test "SessionTarget parse and asStr" {
    try std.testing.expectEqual(SessionTarget.isolated, SessionTarget.parse("isolated"));
    try std.testing.expectEqual(SessionTarget.main, SessionTarget.parse("main"));
    try std.testing.expectEqual(SessionTarget.main, SessionTarget.parse("MAIN"));
    try std.testing.expectEqualStrings("isolated", SessionTarget.isolated.asStr());
    try std.testing.expectEqualStrings("main", SessionTarget.main.asStr());
}

test "CronJob has new fields" {
    const job = CronJob{
        .id = "test",
        .expression = "* * * * *",
        .command = "echo hi",
        .job_type = .agent,
        .session_target = .main,
        .enabled = true,
        .delete_after_run = false,
        .created_at_s = 1000000,
    };
    try std.testing.expectEqual(JobType.agent, job.job_type);
    try std.testing.expectEqual(SessionTarget.main, job.session_target);
    try std.testing.expect(job.enabled);
    try std.testing.expectEqual(@as(i64, 1000000), job.created_at_s);
}

test "getMutableJob returns mutable pointer" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();
    _ = try scheduler.addJob("* * * * *", "echo test");
    const jobs = scheduler.listJobs();
    const id = jobs[0].id;
    const job = scheduler.getMutableJob(id);
    try std.testing.expect(job != null);
    try std.testing.expectEqualStrings(id, job.?.id);
}

test "updateJob modifies job fields" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();
    _ = try scheduler.addJob("* * * * *", "echo original");
    const jobs = scheduler.listJobs();
    const id = jobs[0].id;
    const patch = CronJobPatch{ .command = "echo updated", .enabled = false };
    try std.testing.expect(scheduler.updateJob(allocator, id, patch));
    const updated = scheduler.getJob(id).?;
    try std.testing.expectEqualStrings("echo updated", updated.command);
    try std.testing.expect(!updated.enabled);
    try std.testing.expect(updated.paused);
}

test "getMutableJob returns null for unknown id" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();
    try std.testing.expect(scheduler.getMutableJob("nonexistent") == null);
}

test "addRun and listRuns" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();
    _ = try scheduler.addJob("* * * * *", "echo test");
    const jobs = scheduler.listJobs();
    const id = jobs[0].id;
    try scheduler.addRun(allocator, id, 1000, 1001, "success", "output", 10);
    try scheduler.addRun(allocator, id, 1001, 1002, "error", null, 10);
    const runs = scheduler.listRuns(id, 10);
    try std.testing.expect(runs.len > 0);
}

test "addRun prunes history" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();
    _ = try scheduler.addJob("* * * * *", "echo test");
    const jobs = scheduler.listJobs();
    const id = jobs[0].id;
    // Add 5 runs with max_history=3
    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        try scheduler.addRun(allocator, id, i, i + 1, "success", null, 3);
    }
    const runs = scheduler.listRuns(id, 100);
    try std.testing.expect(runs.len <= 3);
}

// ── Delivery + Bus integration tests ────────────────────────────

test "deliverResult creates correct OutboundMessage" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .always,
        .channel = "telegram",
        .to = "chat123",
    };

    const delivered = try deliverResult(allocator, delivery, "job output here", true, &test_bus);
    try std.testing.expect(delivered);

    // Consume and verify the message
    var msg = test_bus.consumeOutbound().?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("telegram", msg.channel);
    try std.testing.expectEqualStrings("chat123", msg.chat_id);
    try std.testing.expectEqualStrings("job output here", msg.content);
}

test "deliverResult with mode none does nothing" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .none,
        .channel = "telegram",
        .to = "chat1",
    };

    const delivered = try deliverResult(allocator, delivery, "should not appear", true, &test_bus);
    try std.testing.expect(!delivered);
    try std.testing.expectEqual(@as(usize, 0), test_bus.outboundDepth());
}

test "deliverResult with no channel does nothing" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .always,
        .channel = null,
        .to = "chat1",
    };

    const delivered = try deliverResult(allocator, delivery, "should not appear", true, &test_bus);
    try std.testing.expect(!delivered);
    try std.testing.expectEqual(@as(usize, 0), test_bus.outboundDepth());
}

test "deliverResult on_success skips on failure" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .on_success,
        .channel = "telegram",
        .to = "chat1",
    };

    const delivered = try deliverResult(allocator, delivery, "error output", false, &test_bus);
    try std.testing.expect(!delivered);
    try std.testing.expectEqual(@as(usize, 0), test_bus.outboundDepth());
}

test "deliverResult on_error skips on success" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .on_error,
        .channel = "telegram",
        .to = "chat1",
    };

    const delivered = try deliverResult(allocator, delivery, "ok output", true, &test_bus);
    try std.testing.expect(!delivered);
    try std.testing.expectEqual(@as(usize, 0), test_bus.outboundDepth());
}

test "deliverResult on_error delivers on failure" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .on_error,
        .channel = "discord",
        .to = "room42",
    };

    const delivered = try deliverResult(allocator, delivery, "crash log", false, &test_bus);
    try std.testing.expect(delivered);

    var msg = test_bus.consumeOutbound().?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("discord", msg.channel);
    try std.testing.expectEqualStrings("room42", msg.chat_id);
    try std.testing.expectEqualStrings("crash log", msg.content);
}

test "deliverResult uses default chat_id when to is null" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .always,
        .channel = "webhook",
        .to = null,
    };

    const delivered = try deliverResult(allocator, delivery, "hello", true, &test_bus);
    try std.testing.expect(delivered);

    var msg = test_bus.consumeOutbound().?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("default", msg.chat_id);
}

test "deliverResult skips empty output" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const delivery = DeliveryConfig{
        .mode = .always,
        .channel = "telegram",
        .to = "chat1",
    };

    const delivered = try deliverResult(allocator, delivery, "", true, &test_bus);
    try std.testing.expect(!delivered);
    try std.testing.expectEqual(@as(usize, 0), test_bus.outboundDepth());
}

test "deliverResult best_effort swallows closed bus error" {
    const allocator = std.testing.allocator;
    var test_bus = bus.Bus.init();
    test_bus.close(); // close before delivery

    const delivery = DeliveryConfig{
        .mode = .always,
        .channel = "telegram",
        .to = "chat1",
        .best_effort = true,
    };

    // Should not return error because best_effort is true
    const delivered = try deliverResult(allocator, delivery, "msg", true, &test_bus);
    try std.testing.expect(!delivered);
}

test "one-shot job deleted after tick execution" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addOnce("1s", "echo oneshot");
    // Verify job was created
    try std.testing.expect(job.one_shot);
    try std.testing.expectEqual(@as(usize, 1), scheduler.listJobs().len);

    // Force the job to be due now
    scheduler.jobs.items[0].next_run_secs = 0;

    // Tick without bus — the shell command "echo oneshot" will actually run
    _ = scheduler.tick(std.time.timestamp(), null);

    // One-shot job should have been removed
    try std.testing.expectEqual(@as(usize, 0), scheduler.listJobs().len);
}

test "shell job delivers stdout via bus" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    var test_bus = bus.Bus.init();
    defer test_bus.close();

    const job = try scheduler.addJob("* * * * *", "echo hello_cron");
    _ = job;

    // Configure delivery
    scheduler.jobs.items[0].delivery = .{
        .mode = .always,
        .channel = "telegram",
        .to = "chat99",
    };
    scheduler.jobs.items[0].next_run_secs = 0;

    _ = scheduler.tick(std.time.timestamp(), &test_bus);

    // Verify delivery happened
    try std.testing.expect(test_bus.outboundDepth() > 0);
    var msg = test_bus.consumeOutbound().?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("telegram", msg.channel);
    try std.testing.expectEqualStrings("chat99", msg.chat_id);
    // The content should contain "hello_cron" from the echo command
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "hello_cron") != null);
}

test "agent job delivers result via bus" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    var test_bus = bus.Bus.init();
    defer test_bus.close();

    // Create an agent-type job with a prompt
    try scheduler.jobs.append(allocator, .{
        .id = try allocator.dupe(u8, "agent-1"),
        .expression = try allocator.dupe(u8, "* * * * *"),
        .command = try allocator.dupe(u8, "summarize"),
        .job_type = .agent,
        .prompt = "Summarize today's news",
        .next_run_secs = 0,
        .delivery = .{
            .mode = .always,
            .channel = "discord",
            .to = "general",
        },
    });

    _ = scheduler.tick(std.time.timestamp(), &test_bus);

    // Verify delivery
    try std.testing.expect(test_bus.outboundDepth() > 0);
    var msg = test_bus.consumeOutbound().?;
    defer msg.deinit(allocator);
    try std.testing.expectEqualStrings("discord", msg.channel);
    try std.testing.expectEqualStrings("general", msg.chat_id);
    try std.testing.expectEqualStrings("Summarize today's news", msg.content);
}

test "agent job uses configured runner when available" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();
    scheduler.setAgentRunner(testAgentRunner, null);

    try scheduler.jobs.append(allocator, .{
        .id = try allocator.dupe(u8, "agent-runner-1"),
        .expression = try allocator.dupe(u8, "* * * * *"),
        .command = try allocator.dupe(u8, "fallback"),
        .job_type = .agent,
        .prompt = try allocator.dupe(u8, "hello-runner"),
        .prompt_owned = true,
        .next_run_secs = 0,
    });

    _ = scheduler.tick(std.time.timestamp(), null);
    try std.testing.expectEqualStrings("ok", scheduler.jobs.items[0].last_status.?);
    try std.testing.expect(scheduler.jobs.items[0].last_output != null);
    try std.testing.expectEqualStrings("ran:hello-runner", scheduler.jobs.items[0].last_output.?);
}

test "DeliveryMode parse and asStr" {
    try std.testing.expectEqual(DeliveryMode.none, DeliveryMode.parse("none"));
    try std.testing.expectEqual(DeliveryMode.always, DeliveryMode.parse("always"));
    try std.testing.expectEqual(DeliveryMode.on_error, DeliveryMode.parse("on_error"));
    try std.testing.expectEqual(DeliveryMode.on_success, DeliveryMode.parse("on_success"));
    try std.testing.expectEqual(DeliveryMode.none, DeliveryMode.parse("unknown"));
    try std.testing.expectEqual(DeliveryMode.always, DeliveryMode.parse("ALWAYS"));

    try std.testing.expectEqualStrings("none", DeliveryMode.none.asStr());
    try std.testing.expectEqualStrings("always", DeliveryMode.always.asStr());
    try std.testing.expectEqualStrings("on_error", DeliveryMode.on_error.asStr());
    try std.testing.expectEqualStrings("on_success", DeliveryMode.on_success.asStr());
}

test "tick without bus still executes jobs" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    _ = try scheduler.addJob("* * * * *", "echo silent");
    scheduler.jobs.items[0].next_run_secs = 0;

    // Tick with null bus — should not crash
    _ = scheduler.tick(std.time.timestamp(), null);

    // Job should have been executed and rescheduled
    try std.testing.expectEqualStrings("ok", scheduler.jobs.items[0].last_status.?);
    try std.testing.expect(scheduler.jobs.items[0].next_run_secs > 0);
}

test "tick reschedules recurring job using cron expression" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    _ = try scheduler.addJob("*/10 * * * *", "echo periodic");
    scheduler.jobs.items[0].next_run_secs = 0;

    _ = scheduler.tick(0, null);
    try std.testing.expectEqual(@as(i64, 600), scheduler.jobs.items[0].next_run_secs);
}

test "job json roundtrip preserves agent delivery fields" {
    const allocator = std.testing.allocator;
    var scheduler = CronScheduler.init(allocator, 10, true);
    defer scheduler.deinit();

    const job = try scheduler.addOnce("5m", "message \"hello\"");
    job.job_type = .agent;
    job.session_target = .main;
    job.prompt = try allocator.dupe(u8, "remind me");
    job.prompt_owned = true;
    job.name = try allocator.dupe(u8, "Reminder");
    job.name_owned = true;
    job.model = try allocator.dupe(u8, "openrouter/moonshotai/kimi-k2.5");
    job.model_owned = true;
    job.enabled = true;
    job.delete_after_run = true;
    job.delivery = .{
        .mode = .always,
        .channel = try allocator.dupe(u8, "telegram"),
        .to = try allocator.dupe(u8, "chat-1"),
        .best_effort = false,
    };
    job.delivery_channel_owned = true;
    job.delivery_to_owned = true;

    const json = try jobToJson(allocator, job);
    defer allocator.free(json);

    var loaded = CronScheduler.init(allocator, 10, true);
    defer loaded.deinit();
    try loadJobFromJsonSlice(&loaded, json);

    try std.testing.expectEqual(@as(usize, 1), loaded.jobs.items.len);
    const restored = loaded.jobs.items[0];
    try std.testing.expectEqual(JobType.agent, restored.job_type);
    try std.testing.expectEqual(SessionTarget.main, restored.session_target);
    try std.testing.expect(restored.delete_after_run);
    try std.testing.expect(restored.one_shot);
    try std.testing.expect(restored.enabled);
    try std.testing.expectEqual(DeliveryMode.always, restored.delivery.mode);
    try std.testing.expectEqualStrings("telegram", restored.delivery.channel.?);
    try std.testing.expectEqualStrings("chat-1", restored.delivery.to.?);
    try std.testing.expect(!restored.delivery.best_effort);
    try std.testing.expectEqualStrings("remind me", restored.prompt.?);
    try std.testing.expectEqualStrings("Reminder", restored.name.?);
    try std.testing.expectEqualStrings("openrouter/moonshotai/kimi-k2.5", restored.model.?);
}

test "loadTelegramChatIdFromChannelState reads tenant channel state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("tenant");

    const user_root = try tmp.dir.realpathAlloc(std.testing.allocator, "tenant");
    defer std.testing.allocator.free(user_root);

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/channel_state.json", .{user_root});
    defer std.testing.allocator.free(path);
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("{\"telegram\":{\"connected\":true,\"chat_id\":-100777}}");

    const chat_id = loadTelegramChatIdFromChannelState(std.testing.allocator, user_root);
    try std.testing.expect(chat_id != null);
    try std.testing.expectEqual(@as(i64, -100777), chat_id.?);
}

test "parseChatIdString handles valid and invalid values" {
    try std.testing.expect(parseChatIdString("12345") != null);
    try std.testing.expectEqual(@as(i64, 12345), parseChatIdString("12345").?);
    try std.testing.expect(parseChatIdString("  -42  ") != null);
    try std.testing.expectEqual(@as(i64, -42), parseChatIdString("  -42  ").?);
    try std.testing.expect(parseChatIdString("abc") == null);
}

test "loadAutonomyPolicy parses autonomy_policy fields from user config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("tenant");

    const user_root = try tmp.dir.realpathAlloc(std.testing.allocator, "tenant");
    defer std.testing.allocator.free(user_root);

    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{user_root});
    defer std.testing.allocator.free(config_path);

    const file = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(
        \\{
        \\  "autonomy_policy": {
        \\    "notification_rate_limit_per_hour": 7,
        \\    "retry_budget": 3,
        \\    "quiet_hours": {
        \\      "enabled": true,
        \\      "start_hour": 23,
        \\      "end_hour": 6,
        \\      "timezone_offset_minutes": 120
        \\    }
        \\  }
        \\}
    );

    const policy = try loadAutonomyPolicy(std.testing.allocator, user_root);
    try std.testing.expect(policy.quiet_hours_enabled);
    try std.testing.expectEqual(@as(u8, 23), policy.quiet_start_hour);
    try std.testing.expectEqual(@as(u8, 6), policy.quiet_end_hour);
    try std.testing.expectEqual(@as(i32, 120), policy.quiet_timezone_offset_minutes);
    try std.testing.expectEqual(@as(u32, 7), policy.notification_rate_limit_per_hour);
    try std.testing.expectEqual(@as(u8, 3), policy.retry_budget);
}

test "isInQuietHours handles same-day and overnight windows" {
    const daytime_policy = AutonomyPolicy{
        .quiet_hours_enabled = true,
        .quiet_start_hour = 9,
        .quiet_end_hour = 17,
    };
    try std.testing.expect(isInQuietHours(daytime_policy, 10 * 3600));
    try std.testing.expect(!isInQuietHours(daytime_policy, 18 * 3600));

    const overnight_policy = AutonomyPolicy{
        .quiet_hours_enabled = true,
        .quiet_start_hour = 22,
        .quiet_end_hour = 8,
    };
    try std.testing.expect(isInQuietHours(overnight_policy, 23 * 3600));
    try std.testing.expect(isInQuietHours(overnight_policy, 6 * 3600));
    try std.testing.expect(!isInQuietHours(overnight_policy, 12 * 3600));
}

test "allowNotificationByRateLimit enforces and resets persisted hourly quota" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("tenant");

    const user_root = try tmp.dir.realpathAlloc(std.testing.allocator, "tenant");
    defer std.testing.allocator.free(user_root);

    const now_s: i64 = 1_700_000_000;
    try std.testing.expect(try allowNotificationByRateLimit(std.testing.allocator, user_root, 2, now_s));
    try std.testing.expect(try allowNotificationByRateLimit(std.testing.allocator, user_root, 2, now_s + 1));
    try std.testing.expect(!(try allowNotificationByRateLimit(std.testing.allocator, user_root, 2, now_s + 2)));

    // After one hour window passes, notifications are allowed again.
    try std.testing.expect(try allowNotificationByRateLimit(std.testing.allocator, user_root, 2, now_s + 3601));
}

test "cron module compiles" {}
