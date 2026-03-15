const std = @import("std");

pub const MORNING_BRIEF_JOB_ID = "morning-brief";
pub const MORNING_BRIEF_AGENT_COMMAND = "daily_morning_brief";
pub const MORNING_BRIEF_AGENT_PROMPT =
    "Prepare the daily morning brief now. Read HEARTBEAT.md in workspace for exact format and requirements. " ++
    "Use runtime_info and schedule first for runtime truth. Then gather data using read-only integrations/tools as needed (calendar/email/news/weather). " ++
    "Deliver one concise Telegram-ready brief suitable for scheduler delivery. Do not call the message tool in this turn; scheduler delivery sends the final output. Do not create/update scheduler jobs in this turn.";

pub fn isMorningBriefId(id: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, id, " \t\r\n"), MORNING_BRIEF_JOB_ID);
}

pub fn commandLooksMorningBrief(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return false;

    var lowered: [256]u8 = undefined;
    const clipped_len = @min(trimmed.len, lowered.len);
    _ = std.ascii.lowerString(lowered[0..clipped_len], trimmed[0..clipped_len]);
    const value = lowered[0..clipped_len];

    if (std.mem.indexOf(u8, value, MORNING_BRIEF_AGENT_COMMAND) != null) return true;
    if (std.mem.indexOf(u8, value, MORNING_BRIEF_JOB_ID) != null) return true;
    if (std.mem.indexOf(u8, value, "morning brief") != null) return true;

    return containsAsciiWord(value, "morning") and containsAsciiWord(value, "brief");
}

pub fn shouldCanonicalize(requested_id: ?[]const u8, created_job_id: ?[]const u8, command: []const u8) bool {
    if (requested_id) |id| {
        if (isMorningBriefId(id)) return true;
    }
    if (created_job_id) |id| {
        if (isMorningBriefId(id)) return true;
    }
    return commandLooksMorningBrief(command);
}

fn isAsciiWordBoundary(ch: u8) bool {
    const is_alpha = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
    const is_digit = ch >= '0' and ch <= '9';
    return !(is_alpha or is_digit or ch == '_');
}

fn containsAsciiWord(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!std.mem.eql(u8, haystack[i .. i + needle.len], needle)) continue;
        const left_ok = i == 0 or isAsciiWordBoundary(haystack[i - 1]);
        const right_ok = i + needle.len == haystack.len or isAsciiWordBoundary(haystack[i + needle.len]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

test "commandLooksMorningBrief matches canonical command and semantic tokens" {
    try std.testing.expect(commandLooksMorningBrief("daily_morning_brief"));
    try std.testing.expect(commandLooksMorningBrief("send morning brief at 8"));
    try std.testing.expect(commandLooksMorningBrief("schedule morning-brief"));
    try std.testing.expect(!commandLooksMorningBrief("heartbeat run now"));
    try std.testing.expect(!commandLooksMorningBrief("echo hello"));
}

test "shouldCanonicalize requires explicit id or morning brief semantic command" {
    try std.testing.expect(shouldCanonicalize("morning-brief", null, "echo hi"));
    try std.testing.expect(shouldCanonicalize(null, "morning-brief", "echo hi"));
    try std.testing.expect(shouldCanonicalize(null, null, "daily_morning_brief"));
    try std.testing.expect(!shouldCanonicalize(null, null, "heartbeat run now"));
}
