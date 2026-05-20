const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// V1.9-DX1 — wall-clock awareness tool.
///
/// Per Nova directive ("you can add a time tool for you as well"):
/// the agent (and the father building him) gets a deterministic
/// "what's NOW" surface instead of inferring from message ordering
/// or session timestamps. Returns:
///
///   - unix_seconds   (i64) — POSIX epoch
///   - iso_utc        (str) — RFC 3339 / ISO-8601 in UTC
///   - day_of_week    (str) — "Mon" .. "Sun"
///   - human          (str) — "Tuesday, May 6, 2026 at 14:32 UTC"
///
/// No params. Pure read. Cheap. Always-on.
///
/// Why next-gen: lets the agent reason about temporal_decay
/// thresholds in real wall-clock terms ("this fact is 50 days old")
/// instead of opaque internal age numbers. Pairs naturally with
/// V1.9-4 temporal_decay output.
pub const TimeNowTool = struct {
    pub const tool_name = "time_now";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "time_now tool.",
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
        @import("lint.zig").lintToolDescription("time_now", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description =
        "Get the current wall-clock time. Returns unix_seconds, ISO-8601 UTC, " ++
        "day of week, and a human-readable string. Use when reasoning about " ++
        "ages, deadlines, or 'how long ago' relative timing — paired naturally " ++
        "with memory_maintain action=temporal_decay (which reports row ages " ++
        "in days).";
    pub const tool_params =
        \\{"type":"object","properties":{},"additionalProperties":false}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *TimeNowTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(_: *TimeNowTool, allocator: std.mem.Allocator, _: JsonObjectMap) !ToolResult {
        const now_s: i64 = std.time.timestamp();

        // Build ISO-8601 UTC via std.time.epoch decomposition.
        const es = std.time.epoch.EpochSeconds{ .secs = @intCast(now_s) };
        const day_secs = es.getDaySeconds();
        const epoch_day = es.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        const year: u16 = year_day.year;
        const month: u4 = month_day.month.numeric();
        const day: u5 = month_day.day_index + 1;
        const hour: u5 = day_secs.getHoursIntoDay();
        const minute: u6 = day_secs.getMinutesIntoHour();
        const second: u6 = day_secs.getSecondsIntoMinute();

        // Day-of-week: 1970-01-01 was a Thursday (index 4 if Mon=0).
        const dow_index: u3 = @intCast(@mod(@as(i64, epoch_day.day) + 3, 7));
        const dow_short = switch (dow_index) {
            0 => "Mon",
            1 => "Tue",
            2 => "Wed",
            3 => "Thu",
            4 => "Fri",
            5 => "Sat",
            6 => "Sun",
            else => "??",
        };
        const dow_long = switch (dow_index) {
            0 => "Monday",
            1 => "Tuesday",
            2 => "Wednesday",
            3 => "Thursday",
            4 => "Friday",
            5 => "Saturday",
            6 => "Sunday",
            else => "Unknown",
        };
        const month_long = switch (month) {
            1 => "January",
            2 => "February",
            3 => "March",
            4 => "April",
            5 => "May",
            6 => "June",
            7 => "July",
            8 => "August",
            9 => "September",
            10 => "October",
            11 => "November",
            12 => "December",
            else => "?",
        };

        const iso = try std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            .{ year, month, day, hour, minute, second },
        );
        defer allocator.free(iso);

        const human = try std.fmt.allocPrint(
            allocator,
            "{s}, {s} {d}, {d} at {d:0>2}:{d:0>2} UTC",
            .{ dow_long, month_long, day, year, hour, minute },
        );
        defer allocator.free(human);

        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"unix_seconds\":{d},\"iso_utc\":\"{s}\",\"day_of_week\":\"{s}\",\"human\":\"{s}\"}}",
            .{ now_s, iso, dow_short, human },
        );
        return ToolResult{ .success = true, .output = output };
    }
};
