const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const SessionStore = mem_root.SessionStore;
const MessageEntry = mem_root.MessageEntry;

/// Transcript read — cold-memory deep-dive over persisted raw session messages.
///
/// This is the "second line" recall path. First line is `memory_timeline`
/// (browse summaries) and `memory_recall` (semantic search over memory
/// artifacts). When those don't surface the exact detail needed — the
/// precise tool arguments, the verbatim user phrasing, an image reference,
/// the literal response on turn 47 — the agent calls this tool to read the
/// raw transcript directly from persisted session storage.
///
/// Data comes from SessionStore.loadMessages which is per-user-scoped at the
/// backend level (zaki_postgres binds user_id at runtime init; the caller
/// cannot escape their own tenant via a crafted session_id).
///
/// Output is paginated by index range + a per-message char cap to prevent
/// runaway responses. If the session has more messages than the range
/// returns, the agent can issue further calls with narrower windows.
pub const TranscriptReadTool = struct {
    session_store: ?SessionStore = null,

    pub const tool_name = "transcript_read";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Read conversation history or transcript data.",
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
        @import("lint.zig").lintToolDescription("transcript_read", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description =
        "Read raw session transcript messages (user/assistant/tool) directly " ++
        "from persisted storage. Use this as the SECOND line of session recall " ++
        "AFTER memory_timeline and memory_recall have been tried — summaries are " ++
        "cheaper and usually sufficient. Fall back here when you need verbatim " ++
        "content: exact user phrasing, precise tool arguments, or content that " ++
        "was placeholder-truncated during in-session compaction. Scoped to the " ++
        "current user's sessions; session_id is optional and defaults to the " ++
        "current session.";
    pub const tool_params =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"Exact session key (e.g. agent:zaki-bot:user:1:thread:main). Omit to use the current session."},"from_index":{"type":"integer","description":"0-based start index within the session's full message log. Default 0."},"to_index":{"type":"integer","description":"Exclusive end index. Default from_index+limit."},"last_n":{"type":"integer","description":"Shortcut: return the last N messages. Overrides from_index/to_index when set."},"limit":{"type":"integer","description":"Max messages per call. Default 50, max 200."},"max_chars_per_message":{"type":"integer","description":"Truncate each message content to this many characters. Default 2000, max 10000."}}}
    ;

    const DEFAULT_LIMIT: usize = 50;
    const MAX_LIMIT: usize = 200;
    const DEFAULT_CHAR_CAP: usize = 2000;
    const MAX_CHAR_CAP: usize = 10_000;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *TranscriptReadTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const Args = struct {
        session_id: ?[]const u8,
        from_index: ?usize,
        to_index: ?usize,
        last_n: ?usize,
        limit: usize,
        char_cap: usize,
    };

    fn parseArgs(args: JsonObjectMap) error{InvalidSessionId}!Args {
        const session_id = blk: {
            const raw = root.getString(args, "session_id") orelse break :blk null;
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) return error.InvalidSessionId;
            break :blk trimmed;
        };

        const from_index: ?usize = if (root.getInt(args, "from_index")) |n|
            (if (n >= 0) @intCast(n) else null)
        else
            null;

        const to_index: ?usize = if (root.getInt(args, "to_index")) |n|
            (if (n >= 0) @intCast(n) else null)
        else
            null;

        const last_n: ?usize = if (root.getInt(args, "last_n")) |n|
            (if (n > 0) @intCast(n) else null)
        else
            null;

        const limit_raw: usize = if (root.getInt(args, "limit")) |n|
            (if (n > 0) @intCast(n) else DEFAULT_LIMIT)
        else
            DEFAULT_LIMIT;
        const limit = @min(limit_raw, MAX_LIMIT);

        const char_cap_raw: usize = if (root.getInt(args, "max_chars_per_message")) |n|
            (if (n > 0) @intCast(n) else DEFAULT_CHAR_CAP)
        else
            DEFAULT_CHAR_CAP;
        const char_cap = @min(char_cap_raw, MAX_CHAR_CAP);

        return .{
            .session_id = session_id,
            .from_index = from_index,
            .to_index = to_index,
            .last_n = last_n,
            .limit = limit,
            .char_cap = char_cap,
        };
    }

    pub fn execute(self: *TranscriptReadTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const store = self.session_store orelse {
            return ToolResult.fail(
                "Session store not configured. Raw transcript is unavailable in this deployment. " ++
                    "Try memory_timeline or memory_recall instead.",
            );
        };

        const parsed = parseArgs(args) catch |err| switch (err) {
            error.InvalidSessionId => return ToolResult.fail("Invalid 'session_id' — must be non-empty when provided."),
        };

        const resolved_session_id = parsed.session_id orelse
            root.getTurnContext().session_key orelse
            return ToolResult.fail("No session_id provided and no current session context — cannot determine transcript to read.");

        const messages = store.loadMessages(allocator, resolved_session_id) catch |err| {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Failed to load transcript for session '{s}': {s}",
                .{ resolved_session_id, @errorName(err) },
            );
            return ToolResult{ .success = false, .output = msg };
        };
        defer mem_root.freeMessages(allocator, messages);

        if (messages.len == 0) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "No persisted messages for session '{s}'. Either the session is new, or has no stored messages (check session store configuration).",
                .{resolved_session_id},
            );
            return ToolResult{ .success = true, .output = msg };
        }

        const slice = sliceRange(messages, parsed);
        return formatSlice(allocator, resolved_session_id, messages.len, slice.from, slice.items, parsed.char_cap);
    }

    const SliceResult = struct {
        from: usize,
        items: []const MessageEntry,
    };

    fn sliceRange(messages: []const MessageEntry, parsed: Args) SliceResult {
        if (parsed.last_n) |n| {
            const count = @min(n, messages.len);
            const from = messages.len - count;
            return .{ .from = from, .items = messages[from..] };
        }

        const start = @min(parsed.from_index orelse 0, messages.len);
        const end_candidate = parsed.to_index orelse (start + parsed.limit);
        const end = @min(@min(end_candidate, start + parsed.limit), messages.len);
        return .{ .from = start, .items = messages[start..end] };
    }

    fn formatSlice(
        allocator: std.mem.Allocator,
        session_id: []const u8,
        total: usize,
        from: usize,
        items: []const MessageEntry,
        char_cap: usize,
    ) !ToolResult {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.writer(allocator).print(
            "Transcript for {s} — showing {d} message(s) [{d}..{d}) of {d} total.\n\n",
            .{ session_id, items.len, from, from + items.len, total },
        );

        for (items, 0..) |msg, idx| {
            const absolute_idx = from + idx;
            try buf.writer(allocator).print("[{d}] {s}:\n", .{ absolute_idx, msg.role });

            if (msg.content.len <= char_cap) {
                try buf.appendSlice(allocator, msg.content);
                try buf.append(allocator, '\n');
            } else {
                try buf.appendSlice(allocator, msg.content[0..char_cap]);
                try buf.writer(allocator).print(
                    "\n… [truncated {d} chars — raise max_chars_per_message to see more]\n",
                    .{msg.content.len - char_cap},
                );
            }
            try buf.append(allocator, '\n');
        }

        if (from + items.len < total) {
            try buf.writer(allocator).print(
                "More messages follow (total {d}). Call transcript_read again with from_index={d} to continue.\n",
                .{ total, from + items.len },
            );
        }

        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "transcript_read tool name" {
    var tr = TranscriptReadTool{};
    const t = tr.tool();
    try std.testing.expectEqualStrings("transcript_read", t.name());
}

test "transcript_read fails when session store missing" {
    var tr = TranscriptReadTool{};
    const t = tr.tool();
    var args = std.json.ObjectMap.init(std.testing.allocator);
    defer args.deinit();
    const result = try t.execute(std.testing.allocator, args);
    // ToolResult.fail uses a static string in error_msg; nothing to free.
    try std.testing.expect(!result.success);
    const msg = if (result.error_msg) |m| m else result.output;
    try std.testing.expect(std.mem.indexOf(u8, msg, "Session store not configured") != null);
}

test "sliceRange last_n returns tail" {
    const msgs = [_]MessageEntry{
        .{ .role = "user", .content = "one" },
        .{ .role = "assistant", .content = "two" },
        .{ .role = "user", .content = "three" },
        .{ .role = "assistant", .content = "four" },
    };
    const result = TranscriptReadTool.sliceRange(&msgs, .{
        .session_id = null,
        .from_index = null,
        .to_index = null,
        .last_n = 2,
        .limit = 50,
        .char_cap = 2000,
    });
    try std.testing.expectEqual(@as(usize, 2), result.from);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("three", result.items[0].content);
    try std.testing.expectEqualStrings("four", result.items[1].content);
}

test "sliceRange from_index respects limit" {
    const msgs = [_]MessageEntry{
        .{ .role = "user", .content = "a" },
        .{ .role = "assistant", .content = "b" },
        .{ .role = "user", .content = "c" },
        .{ .role = "assistant", .content = "d" },
    };
    const result = TranscriptReadTool.sliceRange(&msgs, .{
        .session_id = null,
        .from_index = 1,
        .to_index = null,
        .last_n = null,
        .limit = 2,
        .char_cap = 2000,
    });
    try std.testing.expectEqual(@as(usize, 1), result.from);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("b", result.items[0].content);
    try std.testing.expectEqualStrings("c", result.items[1].content);
}
