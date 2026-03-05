const std = @import("std");

pub fn userMainSessionKey(buf: []u8, user_id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "agent:zaki-bot:user:{s}:main", .{user_id}) catch "agent:zaki-bot:user:unknown:main";
}

pub fn userCronSessionKey(buf: []u8, user_id: []const u8, job_id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "agent:zaki-bot:user:{s}:cron:{s}", .{ user_id, job_id }) catch "agent:zaki-bot:user:unknown:cron";
}

pub fn fallbackMainSessionKey() []const u8 {
    return "agent:zaki-bot:main";
}

pub fn fallbackCronSessionKey() []const u8 {
    return "agent:zaki-bot:cron";
}

test "userMainSessionKey formats canonical main session" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:main", userMainSessionKey(&buf, "42"));
}

test "userCronSessionKey formats canonical cron session" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:cron:job-7", userCronSessionKey(&buf, "42", "job-7"));
}

test "fallback session keys remain stable" {
    try std.testing.expectEqualStrings("agent:zaki-bot:main", fallbackMainSessionKey());
    try std.testing.expectEqualStrings("agent:zaki-bot:cron", fallbackCronSessionKey());
}
