const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;
const MemoryCategory = mem_root.MemoryCategory;
const zaki_state = @import("../zaki_state.zig");
const supersede_filter = @import("supersede_filter.zig");

pub const MemoryListTool = struct {
    memory: ?Memory = null,
    /// V1.10-D — supersede filter binding. Without it, listing returns
    /// flagged-as-stale rows alongside live ones (the V1.9-era bug
    /// ZAKI named in his stress-test report).
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "memory_list";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "List canonical memory entries in recency order. Defaults to the current session unless scope=global ",
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
        @import("lint.zig").lintToolDescription("memory_list", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description = "List canonical memory entries in recency order. Defaults to the current session unless scope=global is provided; use include_internal=true for transcript/autosave inspection. Note: scope=session filters strictly by session_id, so memories that were promoted to durable core (session_id=NULL after V1.7 promotion) will NOT appear in scope=session results — use scope=global to see promoted core memories.";
    pub const tool_params =
        \\{"type":"object","properties":{"limit":{"type":"integer","description":"Max entries to return (default: 5, max: 100)"},"category":{"type":"string","description":"Optional category filter (core|daily|conversation|custom)"},"scope":{"type":"string","enum":["session","global"],"description":"List scope (default: session). Use global for durable or cross-session records."},"session_id":{"type":"string","description":"Optional explicit session filter override"},"include_content":{"type":"boolean","description":"Include content preview (default: true)"},"include_internal":{"type":"boolean","description":"Include internal autosave/hygiene keys for transcript/audit inspection (default: false)"}}}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryListTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *MemoryListTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const m = self.memory orelse {
            const msg = try std.fmt.allocPrint(allocator, "Memory backend not configured. Cannot list entries.", .{});
            return ToolResult{ .success = false, .output = msg };
        };

        const limit_raw = root.getInt(args, "limit") orelse 5;
        const limit: usize = if (limit_raw > 0 and limit_raw <= 100) @intCast(limit_raw) else 5;

        const category_opt: ?MemoryCategory = if (root.getString(args, "category")) |cat_raw|
            if (cat_raw.len > 0) MemoryCategory.fromString(cat_raw) else null
        else
            null;

        const session_id_opt = resolveSessionId(args) catch |err| switch (err) {
            error.InvalidScope => return ToolResult.fail("Invalid 'scope' parameter. Expected 'session' or 'global'."),
            error.InvalidSessionId => return ToolResult.fail("Invalid 'session_id' parameter. Must be non-empty when provided."),
        };

        const include_content = root.getBool(args, "include_content") orelse true;
        const include_internal = root.getBool(args, "include_internal") orelse false;

        // V1.10-D — fetch supersede skip-set. Drops flagged rows from
        // listings unless `include_internal=true` (which is documented
        // as "for transcript/audit inspection" and should still see
        // everything). Graceful degrade on null state_mgr.
        const superseded_keys = supersede_filter.fetchSupersededKeys(allocator, self.state_mgr, self.user_id);
        defer supersede_filter.freeKeys(allocator, superseded_keys);

        const entries = m.list(allocator, category_opt, session_id_opt) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to list memory entries: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer mem_root.freeEntries(allocator, entries);

        var filtered_total: usize = 0;
        for (entries) |entry| {
            if (!include_internal and mem_root.isInternalMemoryEntryKeyOrContent(entry.key, entry.content)) continue;
            if (!include_internal and supersede_filter.isKeySuperseded(entry.key, superseded_keys)) continue;
            filtered_total += 1;
        }

        if (filtered_total == 0) {
            const msg = if (category_opt != null)
                "No memory entries found for this filter."
            else
                "No memory entries found.";
            return ToolResult{ .success = true, .output = msg };
        }

        const shown = @min(limit, filtered_total);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        const w = out.writer(allocator);
        try w.print("Memory entries: showing {d}/{d}\n", .{ shown, filtered_total });

        var written: usize = 0;
        for (entries) |entry| {
            if (!include_internal and mem_root.isInternalMemoryEntryKeyOrContent(entry.key, entry.content)) continue;
            if (!include_internal and supersede_filter.isKeySuperseded(entry.key, superseded_keys)) continue;
            if (written >= shown) break;
            const provenance = mem_root.resolveStoredMemoryProvenance(entry.content, entry.session_id, entry.key);
            try w.print("  {d}. {s} [{s}] role={s} channel={s} lane={s}", .{
                written + 1,
                entry.key,
                entry.category.toString(),
                mem_root.classifyArtifactKey(entry.key).toSlice(),
                provenance.channel,
                provenance.lane,
            });
            if (provenance.session_id) |session_id| {
                try w.print(" session={s}", .{session_id});
            }
            try w.print(" {s}\n", .{entry.timestamp});
            if (include_content) {
                const preview = truncateUtf8(entry.content, 120);
                try w.print("     {s}{s}\n", .{ preview, if (entry.content.len > preview.len) "..." else "" });
            }
            written += 1;
        }

        return ToolResult{ .success = true, .output = try out.toOwnedSlice(allocator) };
    }

    fn resolveSessionId(args: JsonObjectMap) error{ InvalidScope, InvalidSessionId }!?[]const u8 {
        if (root.getString(args, "session_id")) |sid_raw| {
            const sid = std.mem.trim(u8, sid_raw, " \t\r\n");
            if (sid.len == 0) return error.InvalidSessionId;
            return sid;
        }

        const scope_raw = root.getString(args, "scope") orelse "session";
        const scope = std.mem.trim(u8, scope_raw, " \t\r\n");
        if (scope.len == 0) return error.InvalidScope;
        if (std.ascii.eqlIgnoreCase(scope, "global")) return null;
        if (std.ascii.eqlIgnoreCase(scope, "session")) {
            const session_key = root.getTurnContext().session_key orelse return error.InvalidSessionId;
            if (session_key.len == 0) return error.InvalidSessionId;
            return session_key;
        }
        return error.InvalidScope;
    }

    fn truncateUtf8(s: []const u8, max_len: usize) []const u8 {
        if (s.len <= max_len) return s;
        var end: usize = max_len;
        while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
        return s[0..end];
    }
};

test "memory_list tool name" {
    var mt = MemoryListTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_list", t.name());
}

test "memory_list executes without backend" {
    var mt = MemoryListTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "not configured") != null);
}

test "memory_list filters internal keys by default" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("autosave_user_1", "hello", .conversation, null);
    try mem.store("user_language", "ru", .core, null);
    try mem.store("last_hygiene_at", "1772051598", .core, null);

    var mt = MemoryListTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"limit\":10,\"scope\":\"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "user_language") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "autosave_user_") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "last_hygiene_at") == null);
}

test "memory_list filters audit and index artifacts by default" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("session_checkpoint_1", "type=session_checkpoint\nrecent_user:\n- shipping\n", .daily, null);
    try mem.store("timeline_index/current", "{\"session\":\"agent:zaki-bot:user:1:main\"}", .core, null);
    try mem.store("timeline_summary/agent:zaki-bot:user:1:main/1", "focus: shipping", .daily, null);

    var mt = MemoryListTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"limit\":10,\"scope\":\"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "timeline_summary/agent:zaki-bot:user:1:main/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "session_checkpoint_1") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "timeline_index/current") == null);
}

test "memory_list include_internal true includes autosave entries" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("autosave_user_1", "hello", .conversation, null);

    var mt = MemoryListTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"include_internal\":true,\"scope\":\"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "autosave_user_1") != null);
}

test "memory_list filters markdown-encoded internal keys in content" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("MEMORY:3", "**last_hygiene_at**: 1772051598", .core, null);
    try mem.store("MEMORY:4", "**Name**: User", .core, null);

    var mt = MemoryListTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"limit\":10,\"scope\":\"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "last_hygiene_at") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "**Name**: User") != null);
}

test "memory_list filters bootstrap internal keys by default" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("__bootstrap.prompt.AGENTS.md", "internal-agents", .core, null);
    try mem.store("user_topic", "shipping", .core, null);

    var mt = MemoryListTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"limit\":10,\"scope\":\"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "user_topic") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__bootstrap.prompt.AGENTS.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "internal-agents") == null);
}

test "memory_list defaults to session scope" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("global_only", "visible globally", .core, null);
    try mem.store("session_only", "visible in session", .core, "agent:zaki-bot:user:1:main");

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:main" });
    defer root.clearTurnContext();

    var mt = MemoryListTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"limit\":10}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "session_only") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "global_only") == null);
}

test "memory_list supports explicit global scope" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("global_only", "visible globally", .core, null);
    try mem.store("session_only", "visible in session", .core, "agent:zaki-bot:user:1:main");

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:main" });
    defer root.clearTurnContext();

    var mt = MemoryListTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"limit\":10,\"scope\":\"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "global_only") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "session_only") != null);
}

test "memory_list shows derived provenance" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("session_only", "visible in session", .core, "agent:zaki-bot:user:1:main");

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:main" });
    defer root.clearTurnContext();

    var mt = MemoryListTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"limit\":10}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "channel=app") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "lane=main") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "session=agent:zaki-bot:user:1:main") != null);
}

test "memory_list prefers explicit origin metadata" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "summary_latest/agent:zaki-bot:user:1:thread:telegram:thread:1110331014",
        "type=summary_latest\nsession=agent:zaki-bot:user:1:thread:telegram:thread:1110331014\nchannel=telegram\nlane=thread\norigin_channel=telegram\norigin_lane=thread\nsource_key=timeline_summary/agent:zaki-bot:user:1:thread:telegram:thread:1110331014/1\nat=2026-03-29T12:00:00Z\nfocus: shipping\n",
        .core,
        null,
    );

    var mt = MemoryListTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"limit\":10,\"scope\":\"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "channel=telegram") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "lane=thread") != null);
}
