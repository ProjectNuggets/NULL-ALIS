const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;
const zaki_state = @import("../zaki_state.zig");
const supersede_filter = @import("supersede_filter.zig");

pub const MemoryTimelineTool = struct {
    memory: ?Memory = null,
    mem_rt: ?*mem_root.MemoryRuntime = null,
    /// V1.10-D — supersede filter binding. Same shape as memory_recall.
    /// Without it, timeline browsing returns superseded summaries
    /// alongside live ones (the V1.9-era bug ZAKI named).
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "memory_timeline";
    pub const tool_description = "Browse or search session summaries and timeline continuity objects. This is the FIRST line of session recall — cheap, structured, and usually sufficient. If a summary lacks the exact detail you need (verbatim phrasing, precise tool arguments, content that was placeholder-truncated during compaction), fall back to `transcript_read` for raw message access.";
    pub const tool_params =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"Optional exact session lane to inspect"},"channel":{"type":"string","description":"Optional channel filter (app, telegram, discord, slack, etc.)"},"date_from":{"type":"string","description":"Optional lower date bound in YYYY-MM-DD"},"date_to":{"type":"string","description":"Optional upper date bound in YYYY-MM-DD"},"query":{"type":"string","description":"Optional case-insensitive substring match over summary content only"},"limit":{"type":"integer","description":"Max summaries to return (default: 5, max: 20)"}}}
    ;

    const SummaryView = struct {
        entry: mem_root.MemoryEntry,
        source_key_override: ?[]const u8 = null,
        at_override: ?[]const u8 = null,

        fn deinit(self: *SummaryView, allocator: std.mem.Allocator) void {
            self.entry.deinit(allocator);
            if (self.source_key_override) |value| allocator.free(value);
            if (self.at_override) |value| allocator.free(value);
        }
    };

    const Filters = struct {
        session_id: ?[]const u8,
        channel: ?[]const u8,
        date_from: ?[]const u8,
        date_to: ?[]const u8,
        query: ?[]const u8,
        limit: usize,
    };

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryTimelineTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *MemoryTimelineTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        _ = self.mem_rt;
        const mem = self.memory orelse {
            const msg = try std.fmt.allocPrint(allocator, "Memory backend not configured. Cannot browse timeline summaries.", .{});
            return ToolResult{ .success = false, .output = msg };
        };

        const filters = parseFilters(args) catch |err| return switch (err) {
            error.InvalidSessionId => ToolResult.fail("Invalid 'session_id' parameter. Must be non-empty when provided."),
            error.InvalidDate => ToolResult.fail("Invalid date parameter. Expected YYYY-MM-DD."),
            error.InvalidLimit => ToolResult.fail("Invalid 'limit' parameter. Expected integer between 1 and 20."),
        };

        // V1.10-D — fetch supersede skip-set. Drops timeline summaries
        // whose `metadata.superseded_by_correction` is set so the user
        // doesn't see flagged-as-stale rows surface as live timeline
        // entries. Graceful degrade on null state_mgr.
        const superseded_keys = supersede_filter.fetchSupersededKeys(allocator, self.state_mgr, self.user_id);
        defer supersede_filter.freeKeys(allocator, superseded_keys);

        const views = try collectViews(allocator, mem, filters);
        defer deinitViews(allocator, views);

        if (views.len == 0) {
            return ToolResult{ .success = true, .output = try allocator.dupe(u8, "No session summaries found.") };
        }

        return formatViews(allocator, views, superseded_keys);
    }

    fn parseFilters(args: JsonObjectMap) error{ InvalidSessionId, InvalidDate, InvalidLimit }!Filters {
        const session_id = blk: {
            const raw = root.getString(args, "session_id") orelse break :blk null;
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) return error.InvalidSessionId;
            break :blk trimmed;
        };

        const channel = blk: {
            const raw = root.getString(args, "channel") orelse break :blk null;
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            break :blk if (trimmed.len == 0) null else trimmed;
        };

        const date_from = blk: {
            const raw = root.getString(args, "date_from") orelse break :blk null;
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (!isValidDate(trimmed)) return error.InvalidDate;
            break :blk trimmed;
        };

        const date_to = blk: {
            const raw = root.getString(args, "date_to") orelse break :blk null;
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (!isValidDate(trimmed)) return error.InvalidDate;
            break :blk trimmed;
        };

        const query = blk: {
            const raw = root.getString(args, "query") orelse break :blk null;
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            break :blk if (trimmed.len == 0) null else trimmed;
        };

        const limit_raw = root.getInt(args, "limit") orelse 5;
        if (limit_raw < 1 or limit_raw > 20) return error.InvalidLimit;

        return .{
            .session_id = session_id,
            .channel = channel,
            .date_from = date_from,
            .date_to = date_to,
            .query = query,
            .limit = @intCast(limit_raw),
        };
    }

    fn isValidDate(value: []const u8) bool {
        if (value.len != 10) return false;
        if (value[4] != '-' or value[7] != '-') return false;
        for (value, 0..) |ch, idx| {
            if (idx == 4 or idx == 7) continue;
            if (!std.ascii.isDigit(ch)) return false;
        }
        const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
        const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
        const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
        if (month < 1 or month > 12) return false;
        if (day < 1) return false;
        return day <= daysInMonth(year, month);
    }

    fn daysInMonth(year: u16, month: u8) u8 {
        return switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (isLeapYear(year)) 29 else 28,
            else => 0,
        };
    }

    fn isLeapYear(year: u16) bool {
        if ((year % 4) != 0) return false;
        if ((year % 100) != 0) return true;
        return (year % 400) == 0;
    }

    fn collectViews(
        allocator: std.mem.Allocator,
        mem: Memory,
        filters: Filters,
    ) ![]SummaryView {
        var views: std.ArrayListUnmanaged(SummaryView) = .empty;
        errdefer {
            for (views.items) |*view| view.deinit(allocator);
            views.deinit(allocator);
        }

        if (filters.session_id) |session_id| {
            const latest_key = try std.fmt.allocPrint(allocator, "summary_latest/{s}", .{session_id});
            defer allocator.free(latest_key);
            var latest_source_key: ?[]const u8 = null;
            if (try mem.get(allocator, latest_key)) |latest| {
                const source_key = mem_root.metadataValue(latest.content, "source_key=");
                const effective_at = mem_root.metadataValue(latest.content, "at=") orelse latest.timestamp;
                if (summaryMatchesFilters(latest.content, latest.key, source_key, effective_at, filters)) {
                    const source_key_owned = if (source_key) |value| try allocator.dupe(u8, value) else null;
                    const at_owned = if (mem_root.metadataValue(latest.content, "at=")) |value| try allocator.dupe(u8, value) else null;
                    try views.append(allocator, .{
                        .entry = latest,
                        .source_key_override = source_key_owned,
                        .at_override = at_owned,
                    });
                    latest_source_key = source_key;
                } else {
                    latest.deinit(allocator);
                }
            }

            // iter29 follow-up: timeline now recognizes multiple continuity
            // families, not just timeline_summary/. Agent can browse:
            //   - timeline_summary/{session}/*      (canonical lifecycle summary)
            //   - compaction_summary/{session}/*    (Pass C emergency summary)
            //   - summary_fallback/{session}/*      (quality=fallback preserved)
            //   - compaction_dropped/{session}/*    (force-compress archive)
            const timeline_prefix = try mem_root.timelineSummaryPrefixForSession(allocator, session_id);
            defer allocator.free(timeline_prefix);
            const compaction_prefix = try std.fmt.allocPrint(allocator, "compaction_summary/{s}/", .{session_id});
            defer allocator.free(compaction_prefix);
            const fallback_prefix = try std.fmt.allocPrint(allocator, "summary_fallback/{s}/", .{session_id});
            defer allocator.free(fallback_prefix);
            const dropped_prefix = try std.fmt.allocPrint(allocator, "compaction_dropped/{s}/", .{session_id});
            defer allocator.free(dropped_prefix);

            const entries = try mem.list(allocator, .daily, null);
            defer mem_root.freeEntries(allocator, entries);
            const daily_conversation_entries = try mem.list(allocator, .conversation, null);
            defer mem_root.freeEntries(allocator, daily_conversation_entries);

            var matches: std.ArrayListUnmanaged(mem_root.MemoryEntry) = .empty;
            defer {
                for (matches.items) |*entry| entry.deinit(allocator);
                matches.deinit(allocator);
            }

            const familyMatches = struct {
                fn check(key: []const u8, p_tl: []const u8, p_cs: []const u8, p_fb: []const u8, p_dr: []const u8) bool {
                    return std.mem.startsWith(u8, key, p_tl) or
                        std.mem.startsWith(u8, key, p_cs) or
                        std.mem.startsWith(u8, key, p_fb) or
                        std.mem.startsWith(u8, key, p_dr);
                }
            };

            for (entries) |entry| {
                if (!familyMatches.check(entry.key, timeline_prefix, compaction_prefix, fallback_prefix, dropped_prefix)) continue;
                if (latest_source_key) |source_key| {
                    if (std.mem.eql(u8, entry.key, source_key)) continue;
                }
                if (!summaryMatchesFilters(entry.content, entry.key, entry.key, entry.timestamp, filters)) continue;
                try matches.append(allocator, try cloneEntry(allocator, entry));
            }
            for (daily_conversation_entries) |entry| {
                if (!familyMatches.check(entry.key, timeline_prefix, compaction_prefix, fallback_prefix, dropped_prefix)) continue;
                if (latest_source_key) |source_key| {
                    if (std.mem.eql(u8, entry.key, source_key)) continue;
                }
                if (!summaryMatchesFilters(entry.content, entry.key, entry.key, entry.timestamp, filters)) continue;
                try matches.append(allocator, try cloneEntry(allocator, entry));
            }
            sortEntriesNewestFirst(matches.items);
            var idx: usize = 0;
            while (idx < matches.items.len and views.items.len < filters.limit) : (idx += 1) {
                try views.append(allocator, .{ .entry = try cloneEntry(allocator, matches.items[idx]) });
            }
            return views.toOwnedSlice(allocator);
        }

        collectRecentIndexViews(allocator, mem, filters, &views) catch {};
        if (views.items.len < filters.limit) {
            try collectFallbackTimelineViews(allocator, mem, filters, &views);
        }
        return views.toOwnedSlice(allocator);
    }

    fn collectRecentIndexViews(
        allocator: std.mem.Allocator,
        mem: Memory,
        filters: Filters,
        views: *std.ArrayListUnmanaged(SummaryView),
    ) !void {
        const index_entry = (try mem.get(allocator, "timeline_index/current")) orelse return;
        defer index_entry.deinit(allocator);
        var iter = std.mem.splitScalar(u8, index_entry.content, '\n');
        while (iter.next()) |line| {
            if (views.items.len >= filters.limit) break;
            {
                const parsed = try mem_root.parseTimelineIndexLine(allocator, line) orelse continue;
                defer parsed.deinit(allocator);
                if (!descriptorMatchesFilters(parsed, filters)) continue;
                if (containsSourceKey(views.items, parsed.key)) continue;

                if (try mem.get(allocator, parsed.key)) |entry| {
                    if (!summaryMatchesFilters(entry.content, entry.key, entry.key, entry.timestamp, filters)) {
                        entry.deinit(allocator);
                        continue;
                    }
                    try views.append(allocator, .{ .entry = entry });
                }
            }
        }
    }

    fn collectFallbackTimelineViews(
        allocator: std.mem.Allocator,
        mem: Memory,
        filters: Filters,
        views: *std.ArrayListUnmanaged(SummaryView),
    ) !void {
        const entries = try mem.list(allocator, .daily, null);
        defer mem_root.freeEntries(allocator, entries);
        var matches: std.ArrayListUnmanaged(mem_root.MemoryEntry) = .empty;
        defer {
            for (matches.items) |*entry| entry.deinit(allocator);
            matches.deinit(allocator);
        }
        for (entries) |entry| {
            if (!mem_root.isTimelineSummaryKey(entry.key)) continue;
            if (containsSourceKey(views.items, entry.key)) continue;
            if (!summaryMatchesFilters(entry.content, entry.key, entry.key, entry.timestamp, filters)) continue;
            try matches.append(allocator, try cloneEntry(allocator, entry));
        }
        sortEntriesNewestFirst(matches.items);
        var idx: usize = 0;
        while (idx < matches.items.len and views.items.len < filters.limit) : (idx += 1) {
            try views.append(allocator, .{ .entry = try cloneEntry(allocator, matches.items[idx]) });
        }
    }

    fn containsSourceKey(views: []const SummaryView, key: []const u8) bool {
        for (views) |view| {
            const source_key = view.source_key_override orelse view.entry.key;
            if (std.mem.eql(u8, source_key, key)) return true;
        }
        return false;
    }

    fn descriptorMatchesFilters(parsed: mem_root.TimelineIndexLine, filters: Filters) bool {
        if (filters.channel) |channel| {
            if (!std.ascii.eqlIgnoreCase(parsed.channel, channel)) return false;
        }
        if (filters.date_from) |date_from| {
            if (parsed.at.len < 10 or std.mem.order(u8, parsed.at[0..10], date_from) == .lt) return false;
        }
        if (filters.date_to) |date_to| {
            if (parsed.at.len < 10 or std.mem.order(u8, parsed.at[0..10], date_to) == .gt) return false;
        }
        return true;
    }

    fn summaryMatchesFilters(
        content: []const u8,
        key: []const u8,
        source_key: ?[]const u8,
        effective_at: []const u8,
        filters: Filters,
    ) bool {
        if (filters.session_id) |session_id| {
            const derived_session = mem_root.deriveSessionIdFromMemoryKey(source_key orelse key) orelse mem_root.deriveSessionIdFromMemoryKey(key) orelse return false;
            if (!std.mem.eql(u8, derived_session, session_id)) return false;
        }
        if (filters.channel) |channel| {
            const provenance = mem_root.resolveStoredMemoryProvenance(content, null, source_key orelse key);
            if (!std.ascii.eqlIgnoreCase(provenance.channel, channel)) return false;
        }
        if (filters.date_from) |date_from| {
            if (effective_at.len < 10 or std.mem.order(u8, effective_at[0..10], date_from) == .lt) return false;
        }
        if (filters.date_to) |date_to| {
            if (effective_at.len < 10 or std.mem.order(u8, effective_at[0..10], date_to) == .gt) return false;
        }
        if (filters.query) |query| {
            const summary_body = summaryBody(content);
            const focus = mem_root.extractSummarySection(summary_body, "focus:");
            if (containsIgnoreCase(summary_body, query) or containsIgnoreCase(focus, query)) return true;
            return false;
        }
        return true;
    }

    fn summaryBody(content: []const u8) []const u8 {
        const focus_idx = std.mem.indexOf(u8, content, "focus:") orelse return content;
        return content[focus_idx..];
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;
        var start: usize = 0;
        while (start + needle.len <= haystack.len) : (start += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
        }
        return false;
    }

    fn cloneEntry(allocator: std.mem.Allocator, entry: mem_root.MemoryEntry) !mem_root.MemoryEntry {
        return .{
            .id = try allocator.dupe(u8, entry.id),
            .key = try allocator.dupe(u8, entry.key),
            .content = try allocator.dupe(u8, entry.content),
            .category = switch (entry.category) {
                .core => .core,
                .daily => .daily,
                .conversation => .conversation,
                .custom => |name| .{ .custom = try allocator.dupe(u8, name) },
            },
            .timestamp = try allocator.dupe(u8, entry.timestamp),
            .session_id = if (entry.session_id) |sid| try allocator.dupe(u8, sid) else null,
            .score = entry.score,
        };
    }

    fn sortEntriesNewestFirst(entries: []mem_root.MemoryEntry) void {
        std.mem.sort(mem_root.MemoryEntry, entries, {}, struct {
            fn lessThan(_: void, a: mem_root.MemoryEntry, b: mem_root.MemoryEntry) bool {
                const a_ts = mem_root.parseTimelineSummaryTimestamp(a.key) orelse 0;
                const b_ts = mem_root.parseTimelineSummaryTimestamp(b.key) orelse 0;
                if (a_ts != b_ts) return a_ts > b_ts;
                return std.mem.order(u8, a.timestamp, b.timestamp) == .gt;
            }
        }.lessThan);
    }

    fn formatViews(allocator: std.mem.Allocator, views: []const SummaryView, superseded_keys: []const []u8) !ToolResult {
        // V1.10-D — count visible views first so the header reports
        // post-filter total. Iterating twice keeps the existing
        // single-pass render loop intact below.
        var visible_count: usize = 0;
        for (views) |view| {
            const source_key = view.source_key_override orelse view.entry.key;
            if (supersede_filter.isKeySuperseded(source_key, superseded_keys)) continue;
            if (supersede_filter.isKeySuperseded(view.entry.key, superseded_keys)) continue;
            visible_count += 1;
        }

        if (visible_count == 0) {
            return ToolResult{ .success = true, .output = try allocator.dupe(u8, "No session summaries found.") };
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        const w = out.writer(allocator);
        try w.print("Found {d} session summar{s}:\n", .{ visible_count, if (visible_count == 1) "y" else "ies" });
        for (views, 0..) |view, idx| {
            const source_key = view.source_key_override orelse view.entry.key;
            // V1.10-D — skip superseded summaries (both source-key and
            // entry-key checks; correction may have flagged either).
            if (supersede_filter.isKeySuperseded(source_key, superseded_keys)) continue;
            if (supersede_filter.isKeySuperseded(view.entry.key, superseded_keys)) continue;
            const provenance = mem_root.resolveStoredMemoryProvenance(view.entry.content, view.entry.session_id, source_key);
            const at = view.at_override orelse view.entry.timestamp;
            const focus = mem_root.extractSummarySection(view.entry.content, "focus:");
            const decisions = try mem_root.extractSummaryListSection(allocator, view.entry.content, "decisions:\n");
            defer allocator.free(decisions);
            const open_loops = try mem_root.extractSummaryListSection(allocator, view.entry.content, "open_loops:\n");
            defer allocator.free(open_loops);
            const next = try mem_root.extractSummaryListSection(allocator, view.entry.content, "next:\n");
            defer allocator.free(next);
            try w.print(
                "{d}. session={s} channel={s} lane={s} at={s} source_key={s}\n   focus: {s}\n   decisions: {s}\n   open_loops: {s}\n   next: {s}\n",
                .{
                    idx + 1,
                    provenance.session_id orelse "unknown",
                    provenance.channel,
                    provenance.lane,
                    at,
                    source_key,
                    focus,
                    decisions,
                    open_loops,
                    next,
                },
            );
        }
        return .{ .success = true, .output = try out.toOwnedSlice(allocator) };
    }

    fn deinitViews(allocator: std.mem.Allocator, views: []SummaryView) void {
        for (views) |*view| view.deinit(allocator);
        allocator.free(views);
    }

    fn truncateUtf8(s: []const u8, max_len: usize) []const u8 {
        if (s.len <= max_len) return s;
        var end: usize = max_len;
        while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
        return s[0..end];
    }
};

test "memory_timeline tool name" {
    var mt = MemoryTimelineTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_timeline", t.name());
}

test "memory_timeline schema has timeline filters" {
    var mt = MemoryTimelineTool{};
    const t = mt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "session_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "date_from") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "query") != null);
}

test "memory_timeline executes without backend" {
    var mt = MemoryTimelineTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "not configured") != null);
}

test "memory_timeline returns recent summaries from index" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("timeline_summary/telegram:chat:1/1774400000", "focus: Neptune planning\ndecisions:\n- plan\nopen_loops:\n- verify\nnext:\n- ship\n", .daily, null);
    try mem.store("timeline_summary/discord:room:2/1774300000", "focus: Discord recap\ndecisions:\n- align\nopen_loops:\n- none\nnext:\n- continue\n", .daily, null);
    try mem.store("timeline_index/current", "- at=2026-03-29T10:00:00Z channel=telegram lane=unknown session=telegram:chat:1 key=timeline_summary/telegram:chat:1/1774400000 focus=Neptune\n- at=2026-03-28T10:00:00Z channel=discord lane=unknown session=discord:room:2 key=timeline_summary/discord:room:2/1774300000 focus=Discord\n", .core, null);

    var mt = MemoryTimelineTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "timeline_summary/telegram:chat:1/1774400000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "focus: Neptune planning") != null);
}

test "memory_timeline session view returns latest first and timeline summaries after" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("summary_latest/agent:zaki-bot:user:1:main", "type=summary_latest\nsession=agent:zaki-bot:user:1:main\nchannel=app\nlane=main\nsource_key=timeline_summary/agent:zaki-bot:user:1:main/1774400002\nat=2026-03-29T12:00:00Z\nfocus: latest shipping\n\ndecisions:\n- keep latest\nopen_loops:\n- none\nnext:\n- ship\n", .core, null);
    try mem.store("timeline_summary/agent:zaki-bot:user:1:main/1774400002", "focus: latest shipping\ndecisions:\n- keep latest\nopen_loops:\n- none\nnext:\n- ship\n", .daily, null);
    try mem.store("timeline_summary/agent:zaki-bot:user:1:main/1774300000", "focus: earlier recap\ndecisions:\n- align\nopen_loops:\n- review\nnext:\n- follow up\n", .daily, null);

    var mt = MemoryTimelineTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"session_id\":\"agent:zaki-bot:user:1:main\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    const latest_idx = std.mem.indexOf(u8, result.output, "source_key=timeline_summary/agent:zaki-bot:user:1:main/1774400002") orelse return error.TestUnexpectedResult;
    const older_idx = std.mem.indexOf(u8, result.output, "source_key=timeline_summary/agent:zaki-bot:user:1:main/1774300000") orelse return error.TestUnexpectedResult;
    try std.testing.expect(latest_idx < older_idx);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "open_loops: review") != null);
}

test "memory_timeline filters by channel and query" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("timeline_summary/telegram:chat:1/1774400000", "focus: Neptune launch\ndecisions:\n- book time\nopen_loops:\n- none\nnext:\n- continue\n", .daily, null);
    try mem.store("timeline_summary/discord:room:2/1774300000", "focus: Different topic\ndecisions:\n- none\nopen_loops:\n- none\nnext:\n- none\n", .daily, null);

    var mt = MemoryTimelineTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"channel\":\"telegram\",\"query\":\"Neptune\",\"limit\":10}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "telegram:chat:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "discord:room:2") == null);
}

test "memory_timeline filters by date range" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("timeline_summary/telegram:chat:1/1774400000", "focus: current\ndecisions:\n- now\nopen_loops:\n- none\nnext:\n- continue\n", .daily, null);
    try mem.store("timeline_index/current", "- at=2026-03-29T10:00:00Z channel=telegram lane=unknown session=telegram:chat:1 key=timeline_summary/telegram:chat:1/1774400000 focus=current\n", .core, null);

    var mt = MemoryTimelineTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"date_from\":\"2026-03-30\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "No session summaries found.") != null);
}

test "memory_timeline rejects malformed date input" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();

    var mt = MemoryTimelineTool{ .memory = sqlite_mem.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"date_from\":\"2026/03/29\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid date") != null);
}

test "memory_timeline rejects impossible calendar date" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();

    var mt = MemoryTimelineTool{ .memory = sqlite_mem.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"date_from\":\"2026-02-30\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid date") != null);
}

test "memory_timeline accepts leap day on leap year" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    var mt = MemoryTimelineTool{ .memory = sqlite_mem.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"date_from\":\"2028-02-29\",\"date_to\":\"2028-02-29\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "No session summaries found.") != null);
}

test "memory_timeline query searches full summary content after index fetch" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("timeline_summary/telegram:chat:0/1774399999", "focus: unrelated\ndecisions:\n- stay general\nopen_loops:\n- none\nnext:\n- continue\n", .daily, null);
    try mem.store("timeline_summary/telegram:chat:1/1774400000", "focus: shipping\ndecisions:\n- Neptune rollout\nopen_loops:\n- none\nnext:\n- continue\n", .daily, null);
    try mem.store("timeline_summary/telegram:chat:2/1774400001", "focus: planning\ndecisions:\n- align\nopen_loops:\n- Neptune follow-up\nnext:\n- continue\n", .daily, null);
    try mem.store(
        "timeline_index/current",
        "- at=2026-03-29T09:59:00Z channel=telegram lane=unknown session=telegram:chat:0 key=timeline_summary/telegram:chat:0/1774399999 focus=Neptune teaser\n" ++
            "- at=2026-03-29T10:00:00Z channel=telegram lane=unknown session=telegram:chat:1 key=timeline_summary/telegram:chat:1/1774400000 focus=shipping update\n" ++
            "- at=2026-03-29T10:01:00Z channel=telegram lane=unknown session=telegram:chat:2 key=timeline_summary/telegram:chat:2/1774400001 focus=planning thread\n",
        .core,
        null,
    );

    var mt = MemoryTimelineTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"query\":\"Neptune\",\"limit\":2}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "source_key=timeline_summary/telegram:chat:1/1774400000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "source_key=timeline_summary/telegram:chat:2/1774400001") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "source_key=timeline_summary/telegram:chat:0/1774399999") == null);
}

test "memory_timeline session query ignores summary_latest metadata-only matches" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "summary_latest/agent:zaki-bot:user:1:main",
        "type=summary_latest\nsession=agent:zaki-bot:user:1:main\nchannel=app\nlane=main\nsource_key=timeline_summary/agent:zaki-bot:user:1:main/1774400002\nat=2026-03-29T12:00:00Z\nfocus: shipping\ndecisions:\n- align\nopen_loops:\n- none\nnext:\n- continue\n",
        .core,
        null,
    );
    try mem.store("timeline_summary/agent:zaki-bot:user:1:main/1774400002", "focus: shipping\ndecisions:\n- align\nopen_loops:\n- none\nnext:\n- continue\n", .daily, null);

    var mt = MemoryTimelineTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"session_id\":\"agent:zaki-bot:user:1:main\",\"query\":\"app\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("No session summaries found.", result.output);
}

test "memory_timeline session date filter uses summary_latest at metadata" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "summary_latest/agent:zaki-bot:user:1:main",
        "type=summary_latest\nsession=agent:zaki-bot:user:1:main\nchannel=app\nlane=main\nsource_key=timeline_summary/agent:zaki-bot:user:1:main/1774300000\nat=2026-03-01T12:00:00Z\nfocus: shipping\ndecisions:\n- align\nopen_loops:\n- none\nnext:\n- continue\n",
        .core,
        null,
    );
    try mem.store("timeline_summary/agent:zaki-bot:user:1:main/1774300000", "focus: shipping\ndecisions:\n- align\nopen_loops:\n- none\nnext:\n- continue\n", .daily, null);

    var mt = MemoryTimelineTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"session_id\":\"agent:zaki-bot:user:1:main\",\"date_from\":\"2026-03-15\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("No session summaries found.", result.output);
}

test "memory_timeline falls back to summaries without rewriting legacy index rows" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "timeline_summary/agent:zaki-bot:user:1:thread:telegram:thread:1110331014/1774747162",
        "focus: telegram recap\ndecisions:\n- align\nopen_loops:\n- none\nnext:\n- continue\n",
        .daily,
        null,
    );
    try mem.store(
        "timeline_index/current",
        "- at=2026-03-29T01:19:22Z channel=app lane=thread session=agent:zaki-bot:user:1:thread:telegram:thread:1110331014 key=timeline_summary/agent:zaki-bot:user:1:thread:telegram:thread:1110331014/1774747162 focus=telegram recap\n",
        .core,
        null,
    );

    var mt = MemoryTimelineTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"channel\":\"telegram\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "channel=telegram") != null);

    const index_after = (try mem.get(allocator, "timeline_index/current")) orelse return error.TestUnexpectedResult;
    defer index_after.deinit(allocator);
    try std.testing.expectEqualStrings(
        "- at=2026-03-29T01:19:22Z channel=app lane=thread session=agent:zaki-bot:user:1:thread:telegram:thread:1110331014 key=timeline_summary/agent:zaki-bot:user:1:thread:telegram:thread:1110331014/1774747162 focus=telegram recap\n",
        index_after.content,
    );
}
