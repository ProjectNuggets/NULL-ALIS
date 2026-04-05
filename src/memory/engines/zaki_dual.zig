const std = @import("std");
const root = @import("../root.zig");

pub const ZakiDualMemory = struct {
    allocator: std.mem.Allocator,
    primary: root.Memory,
    markdown_impl: *root.MarkdownMemory,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        primary: root.Memory,
        workspace_dir: []const u8,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const markdown_impl = try allocator.create(root.MarkdownMemory);
        errdefer allocator.destroy(markdown_impl);
        markdown_impl.* = try root.MarkdownMemory.init(allocator, workspace_dir);

        self.* = .{
            .allocator = allocator,
            .primary = primary,
            .markdown_impl = markdown_impl,
        };
        return self;
    }

    pub fn memory(self: *Self) root.Memory {
        return .{ .ptr = @ptrCast(self), .vtable = &mem_vtable };
    }

    pub fn syncFromMarkdown(self: *Self, allocator: std.mem.Allocator) !void {
        const tombstoned_keys = try self.markdown_impl.readTombstonedKeys(allocator);
        defer {
            for (tombstoned_keys) |key| allocator.free(key);
            allocator.free(tombstoned_keys);
        }
        for (tombstoned_keys) |target_key| {
            _ = self.primary.forget(target_key) catch {};
        }

        const entries = try self.markdown_impl.memory().list(allocator, null, null);
        defer root.freeEntries(allocator, entries);

        for (entries) |entry| {
            if (!shouldSyncEntry(entry)) continue;
            try self.primary.store(entry.key, entry.content, entry.category, entry.session_id);
        }
    }

    fn shouldSyncEntry(entry: root.MemoryEntry) bool {
        if (root.isInternalMemoryEntryKeyOrContent(entry.key, entry.content)) return false;
        if (entry.category == .core and std.mem.startsWith(u8, entry.key, "MEMORY:")) {
            return false;
        }
        return true;
    }

    fn implName(_: *anyopaque) []const u8 {
        return "zaki_dual";
    }

    fn implStore(ptr: *anyopaque, key: []const u8, content: []const u8, category: root.MemoryCategory, session_id: ?[]const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.primary.store(key, content, category, session_id);
        try self.markdown_impl.memory().store(key, content, category, session_id);
    }

    fn implRecall(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) anyerror![]root.MemoryEntry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.primary.recall(allocator, query, limit, session_id);
    }

    fn implGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?root.MemoryEntry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.primary.get(allocator, key);
    }

    fn implList(ptr: *anyopaque, allocator: std.mem.Allocator, category: ?root.MemoryCategory, session_id: ?[]const u8) anyerror![]root.MemoryEntry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.primary.list(allocator, category, session_id);
    }

    fn implForget(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const forgotten_primary = self.primary.forget(key) catch false;
        if (root.isInternalMemoryKey(key) or root.isMarkdownLineKey(key) or root.isSystemManagedMemoryKey(key)) {
            return forgotten_primary;
        }

        const markdown_entry = self.markdown_impl.memory().get(self.allocator, key) catch null;
        defer if (markdown_entry) |*entry| entry.deinit(self.allocator);

        if (forgotten_primary or markdown_entry != null) {
            try self.markdown_impl.appendTombstone(key, self.allocator);
            return true;
        }
        return false;
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.primary.count();
    }

    fn implHealthCheck(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.primary.healthCheck();
    }

    fn implDeinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.primary.deinit();
        self.markdown_impl.deinit();
        self.allocator.destroy(self.markdown_impl);
        self.allocator.destroy(self);
    }

    pub const mem_vtable = root.Memory.VTable{
        .name = &implName,
        .store = &implStore,
        .recall = &implRecall,
        .get = &implGet,
        .list = &implList,
        .forget = &implForget,
        .count = &implCount,
        .healthCheck = &implHealthCheck,
        .deinit = &implDeinit,
    };
};

test "zaki dual memory syncs markdown into canonical memory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    var mem_impl = root.InMemoryLruMemory.init(allocator, 128);

    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace);
    var mem = dual.memory();

    try mem.store("user_name", "Nova", .core, null);
    const recalled = try mem.recall(allocator, "Nova", 5, null);
    defer root.freeEntries(allocator, recalled);
    try std.testing.expect(recalled.len >= 1);

    const memory_path = try std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{workspace});
    defer allocator.free(memory_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, memory_path, 4096);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "user_name") != null);

    mem.deinit();
}

test "zaki dual memory ingests manual markdown edits into canonical memory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    const memory_path = try std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{workspace});
    defer allocator.free(memory_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = memory_path,
        .data = "# MEMORY.md - Long-Term Memory\n\n- **favorite_color**: teal\n",
    });

    var mem_impl = root.InMemoryLruMemory.init(allocator, 128);
    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace);
    var mem = dual.memory();
    try dual.syncFromMarkdown(allocator);

    const got = (try mem.get(allocator, "favorite_color")).?;
    defer got.deinit(allocator);
    try std.testing.expectEqualStrings("teal", got.content);

    mem.deinit();
}

test "zaki dual memory skips scaffold core lines during sync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    const memory_path = try std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{workspace});
    defer allocator.free(memory_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = memory_path,
        .data = "# MEMORY.md - Long-Term Memory\n\nThis file stores curated, durable context for main sessions.\n- **favorite_color**: teal\n",
    });

    var mem_impl = root.InMemoryLruMemory.init(allocator, 128);
    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace);
    var mem = dual.memory();
    try dual.syncFromMarkdown(allocator);

    try std.testing.expect((try mem.get(allocator, "MEMORY:0")) == null);
    const got = (try mem.get(allocator, "favorite_color")).?;
    defer got.deinit(allocator);
    try std.testing.expectEqualStrings("teal", got.content);

    mem.deinit();
}

test "zaki dual memory ignores internal markdown entries during sync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    const memory_path = try std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{workspace});
    defer allocator.free(memory_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = memory_path,
        .data = "# MEMORY.md - Long-Term Memory\n\n" ++
            "- **favorite_color**: teal\n" ++
            "- **autosave_user_123**: internal turn\n" ++
            "- **__bootstrap.prompt.SOUL.md**: internal persona\n" ++
            "- **last_hygiene_at**: 1700000000\n",
    });

    var mem_impl = root.InMemoryLruMemory.init(allocator, 128);
    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace);
    var mem = dual.memory();
    try dual.syncFromMarkdown(allocator);

    const favorite = (try mem.get(allocator, "favorite_color")).?;
    defer favorite.deinit(allocator);
    try std.testing.expectEqualStrings("teal", favorite.content);
    try std.testing.expect((try mem.get(allocator, "autosave_user_123")) == null);
    try std.testing.expect((try mem.get(allocator, "__bootstrap.prompt.SOUL.md")) == null);
    try std.testing.expect((try mem.get(allocator, "last_hygiene_at")) == null);

    mem.deinit();
}

test "zaki dual memory forget writes tombstone and prevents resurrection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    var mem_impl = root.InMemoryLruMemory.init(allocator, 128);
    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace);
    var mem = dual.memory();

    try mem.store("user_name", "Nova", .core, null);
    try std.testing.expect(try mem.forget("user_name"));
    try std.testing.expect((try mem.get(allocator, "user_name")) == null);

    try dual.syncFromMarkdown(allocator);
    try std.testing.expect((try mem.get(allocator, "user_name")) == null);

    mem.deinit();
}

test "zaki dual memory store clears tombstone for restored mutable key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    var mem_impl = root.InMemoryLruMemory.init(allocator, 128);
    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace);
    var mem = dual.memory();

    try mem.store("user_name", "Nova", .core, null);
    try std.testing.expect(try mem.forget("user_name"));
    try mem.store("user_name", "Nova Restored", .core, null);

    const entry = (try mem.get(allocator, "user_name")) orelse return error.TestUnexpectedResult;
    defer entry.deinit(allocator);
    try std.testing.expectEqualStrings("Nova Restored", entry.content);

    const tombstoned = try dual.markdown_impl.readTombstonedKeys(allocator);
    defer {
        for (tombstoned) |key| allocator.free(key);
        allocator.free(tombstoned);
    }
    try std.testing.expectEqual(@as(usize, 0), tombstoned.len);

    mem.deinit();
}

test "zaki dual memory runtime markdown edits do not override canonical primary state until explicit sync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    var mem_impl = root.InMemoryLruMemory.init(allocator, 128);
    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace);
    var mem = dual.memory();

    try mem.store("favorite_color", "teal", .core, null);

    const memory_path = try std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{workspace});
    defer allocator.free(memory_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = memory_path,
        .data = "# MEMORY.md - Long-Term Memory\n\n- **favorite_color**: orange\n",
    });

    const runtime_get = (try mem.get(allocator, "favorite_color")) orelse return error.TestUnexpectedResult;
    defer runtime_get.deinit(allocator);
    try std.testing.expectEqualStrings("teal", runtime_get.content);

    const runtime_recall = try mem.recall(allocator, "favorite_color", 5, null);
    defer root.freeEntries(allocator, runtime_recall);
    try std.testing.expect(runtime_recall.len >= 1);
    try std.testing.expectEqualStrings("teal", runtime_recall[0].content);

    try dual.syncFromMarkdown(allocator);

    const imported_get = (try mem.get(allocator, "favorite_color")) orelse return error.TestUnexpectedResult;
    defer imported_get.deinit(allocator);
    try std.testing.expectEqualStrings("orange", imported_get.content);

    mem.deinit();
}
