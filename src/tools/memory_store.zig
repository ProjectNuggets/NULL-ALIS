const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;
const MemoryCategory = mem_root.MemoryCategory;

/// Memory store tool — lets the agent persist facts to long-term memory.
/// When a MemoryRuntime is available, also triggers vector sync after store.
pub const MemoryStoreTool = struct {
    memory: ?Memory = null,
    mem_rt: ?*mem_root.MemoryRuntime = null,

    pub const tool_name = "memory_store";
    pub const tool_description = "Store durable user facts, preferences, and decisions in long-term memory. Use category 'core' for stable facts, 'daily' for session notes, 'conversation' for important context only. Do not store routine greetings or every chat message.";
    pub const tool_params =
        \\{"type":"object","properties":{"key":{"type":"string","description":"Unique key for this memory"},"content":{"type":"string","description":"The information to remember"},"category":{"type":"string","enum":["core","daily","conversation"],"description":"Memory category"},"scope":{"type":"string","enum":["session","global"],"description":"Memory scope (default: session lane)"},"session_id":{"type":"string","description":"Optional explicit session lane override"}},"required":["key","content"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryStoreTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *MemoryStoreTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const key = root.getString(args, "key") orelse
            return ToolResult.fail("Missing 'key' parameter");
        if (key.len == 0) return ToolResult.fail("'key' must not be empty");

        const content = root.getString(args, "content") orelse
            return ToolResult.fail("Missing 'content' parameter");
        if (content.len == 0) return ToolResult.fail("'content' must not be empty");

        const category_str = root.getString(args, "category") orelse "core";
        const category = MemoryCategory.fromString(category_str);
        const session_id = resolveSessionId(args) catch |err| switch (err) {
            error.InvalidScope => return ToolResult.fail("Invalid 'scope' parameter. Expected 'session' or 'global'."),
            error.InvalidSessionId => return ToolResult.fail("Invalid 'session_id' parameter. Must be non-empty when provided."),
        };

        const m = self.memory orelse {
            const msg = try std.fmt.allocPrint(allocator, "Memory backend not configured. Cannot store: {s} = {s}", .{ key, content });
            return ToolResult{ .success = false, .output = msg };
        };

        m.store(key, content, category, session_id) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to store memory '{s}': {s}", .{ key, @errorName(err) });
            return ToolResult{ .success = false, .output = msg };
        };

        // Vector sync: embed and upsert into vector store (best-effort)
        if (self.mem_rt) |rt| {
            rt.syncVectorAfterStore(allocator, key, content);
        }

        const msg = try std.fmt.allocPrint(allocator, "Stored memory: {s} ({s})", .{ key, category.toString() });
        return ToolResult{ .success = true, .output = msg };
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
        if (std.ascii.eqlIgnoreCase(scope, "session")) return root.getTurnContext().session_key;
        return error.InvalidScope;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "memory_store tool name" {
    var mt = MemoryStoreTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_store", t.name());
}

test "memory_store schema has key and content" {
    var mt = MemoryStoreTool{};
    const t = mt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "key") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "content") != null);
}

test "memory_store executes without backend" {
    var mt = MemoryStoreTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"lang\", \"content\": \"Prefers Zig\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "not configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "lang") != null);
}

test "memory_store missing key" {
    var mt = MemoryStoreTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"content\": \"no key\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "memory_store missing content" {
    var mt = MemoryStoreTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"no_content\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "memory_store with real backend" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryStoreTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"lang\", \"content\": \"Prefers Zig\", \"category\": \"core\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Stored memory: lang") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "core") != null);
}

test "memory_store default category is core" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryStoreTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"test\", \"content\": \"value\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "core") != null);
}

test "memory_store with daily category" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryStoreTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"note\", \"content\": \"today's note\", \"category\": \"daily\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "daily") != null);
}

test "memory_store defaults to current turn session scope" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:main" });
    defer root.clearTurnContext();

    var mt = MemoryStoreTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"lane_pref\",\"content\":\"session scoped\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    try std.testing.expect(result.success);

    const entry = (try mem.get(allocator, "lane_pref")) orelse return error.TestUnexpectedResult;
    defer entry.deinit(allocator);
    try std.testing.expect(entry.session_id != null);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", entry.session_id.?);
}

test "memory_store supports explicit global scope" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:1:main" });
    defer root.clearTurnContext();

    var mt = MemoryStoreTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"global_pref\",\"content\":\"all lanes\",\"scope\":\"global\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    try std.testing.expect(result.success);

    const entry = (try mem.get(allocator, "global_pref")) orelse return error.TestUnexpectedResult;
    defer entry.deinit(allocator);
    try std.testing.expect(entry.session_id == null);
}

test "memory_store rejects invalid scope value" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryStoreTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"x\",\"content\":\"y\",\"scope\":\"tenant\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid 'scope'") != null);
}
