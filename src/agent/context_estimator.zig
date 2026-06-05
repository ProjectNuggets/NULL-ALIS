const std = @import("std");

pub const ESTIMATOR_NAME = "provider_bound_chars_v1";
pub const ESTIMATOR_VERSION = 1;
pub const CHARS_PER_TOKEN: u64 = 4;
pub const TOP_CONTRIBUTOR_LIMIT: usize = 5;
const LAST_TURN_TAIL_MESSAGES: usize = 4;

pub const TopContributor = struct {
    index: usize = 0,
    role: []const u8 = "unknown",
    source: []const u8 = "message_content",
    bytes: usize = 0,
    token_estimate: u64 = 0,
};

pub const Analysis = struct {
    message_count: usize = 0,
    content_bytes: u64 = 0,
    reasoning_bytes: u64 = 0,
    total_bytes: u64 = 0,
    token_estimate: u64 = 0,
    last_turn_delta_bytes: u64 = 0,
    last_turn_delta_tokens: u64 = 0,
    top_count: usize = 0,
    top_contributors: [TOP_CONTRIBUTOR_LIMIT]TopContributor = [_]TopContributor{.{}} ** TOP_CONTRIBUTOR_LIMIT,
};

pub fn tokenEstimateFromBytes(bytes: u64) u64 {
    return (bytes + (CHARS_PER_TOKEN - 1)) / CHARS_PER_TOKEN;
}

fn reasoningBytes(entry: anytype) usize {
    const EntryType = @TypeOf(entry);
    if (!@hasField(EntryType, "reasoning")) return 0;
    if (entry.reasoning) |reasoning| return reasoning.len;
    return 0;
}

fn roleName(role: anytype) []const u8 {
    return @tagName(role);
}

fn sourceName(entry: anytype, reasoning_bytes: usize) []const u8 {
    const role = roleName(entry.role);
    if (std.mem.eql(u8, role, "system")) return "system_prompt";
    if (std.mem.eql(u8, role, "user") and
        (std.mem.indexOf(u8, entry.content, "<tool_result") != null or
            std.mem.indexOf(u8, entry.content, "[Tool results]") != null))
    {
        return "tool_result_history";
    }
    if (std.mem.eql(u8, role, "assistant") and reasoning_bytes > 0) return "assistant_with_reasoning";
    if (std.mem.eql(u8, role, "tool")) return "native_tool_result";
    return "message_content";
}

fn insertTopContributor(analysis: *Analysis, contributor: TopContributor) void {
    if (contributor.bytes == 0) return;

    var insert_at: usize = analysis.top_count;
    var i: usize = 0;
    while (i < analysis.top_count) : (i += 1) {
        if (contributor.bytes > analysis.top_contributors[i].bytes) {
            insert_at = i;
            break;
        }
    }

    if (insert_at >= TOP_CONTRIBUTOR_LIMIT) return;
    if (analysis.top_count < TOP_CONTRIBUTOR_LIMIT) analysis.top_count += 1;

    var j = analysis.top_count - 1;
    while (j > insert_at) : (j -= 1) {
        analysis.top_contributors[j] = analysis.top_contributors[j - 1];
    }
    analysis.top_contributors[insert_at] = contributor;
}

pub fn analyzeHistory(history: anytype) Analysis {
    var analysis = Analysis{};
    analysis.message_count = history.items.len;

    const tail_start = history.items.len -| @min(LAST_TURN_TAIL_MESSAGES, history.items.len);

    for (history.items, 0..) |entry, index| {
        const content_bytes = entry.content.len;
        const r_bytes = reasoningBytes(entry);
        const total = content_bytes + r_bytes;

        analysis.content_bytes += content_bytes;
        analysis.reasoning_bytes += r_bytes;
        analysis.total_bytes += total;

        if (index >= tail_start and !std.mem.eql(u8, roleName(entry.role), "system")) {
            analysis.last_turn_delta_bytes += total;
        }

        insertTopContributor(&analysis, .{
            .index = index,
            .role = roleName(entry.role),
            .source = sourceName(entry, r_bytes),
            .bytes = total,
            .token_estimate = tokenEstimateFromBytes(total),
        });
    }

    analysis.token_estimate = tokenEstimateFromBytes(analysis.total_bytes);
    analysis.last_turn_delta_tokens = tokenEstimateFromBytes(analysis.last_turn_delta_bytes);
    return analysis;
}

test "analyzeHistory includes assistant reasoning bytes" {
    const FakeRole = enum { user, assistant };
    const FakeMessage = struct {
        role: FakeRole,
        content: []const u8,
        reasoning: ?[]const u8 = null,
    };
    const FakeHistory = struct {
        items: []const FakeMessage,
    };
    const messages = [_]FakeMessage{
        .{ .role = .user, .content = "1234" },
        .{ .role = .assistant, .content = "abcd", .reasoning = "reasoning" },
    };

    const analysis = analyzeHistory(FakeHistory{ .items = &messages });
    try std.testing.expectEqual(@as(u64, 9), analysis.reasoning_bytes);
    try std.testing.expectEqual(@as(u64, 17), analysis.total_bytes);
    try std.testing.expectEqual(@as(u64, 5), analysis.token_estimate);
    try std.testing.expectEqualStrings("assistant_with_reasoning", analysis.top_contributors[0].source);
}
