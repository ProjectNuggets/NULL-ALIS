const std = @import("std");
const root = @import("../root.zig");

const log = std.log.scoped(.zaki_dual);

pub const ZakiDualMemory = struct {
    allocator: std.mem.Allocator,
    primary: root.Memory,
    /// v1.14.18 Step 9 (V7) — null when the markdown mirror is OFF
    /// (`memory.enable_markdown_mirror=false`, the new default). When
    /// null, every store/forget/sync hook below short-circuits — only
    /// Postgres sees writes. The "dual" name predates the opt-in; a
    /// rename to `zaki_postgres.zig` is deferred (D49) because the
    /// touch radius (every `@import`) is out of scope for this sprint.
    markdown_impl: ?*root.MarkdownMemory,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        primary: root.Memory,
        workspace_dir: []const u8,
        enable_markdown_mirror: bool,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        var markdown_impl: ?*root.MarkdownMemory = null;
        if (enable_markdown_mirror) {
            const md = try allocator.create(root.MarkdownMemory);
            errdefer allocator.destroy(md);
            md.* = try root.MarkdownMemory.init(allocator, workspace_dir);
            markdown_impl = md;
        }

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

    /// V1.14.12 (Memory audit Finding 5 fix, 2026-05-19) — restore the
    /// canonical-Postgres invariant the implStore comment promised but
    /// the code violated. Pre-fix, syncFromMarkdown unconditionally
    /// stored every Markdown entry into primary, so a stale or
    /// hand-edited MEMORY.md could overwrite newer DB facts on restart.
    /// Now: skip keys already present in primary (additive-only import).
    /// Tombstones still propagate as forgets — that's an explicit user
    /// signal to delete.
    ///
    /// Note: this changes the import semantics to "MEMORY.md adds keys
    /// the DB doesn't know about" rather than "MEMORY.md replaces the
    /// DB's view." For an intentional override, the user can delete
    /// the row via /forget (or memory_archive), then re-run sync.
    pub fn syncFromMarkdown(self: *Self, allocator: std.mem.Allocator) !void {
        // V7 — mirror OFF means there is no markdown source to sync from.
        const md = self.markdown_impl orelse return;

        const tombstoned_keys = try md.readTombstonedKeys(allocator);
        defer {
            for (tombstoned_keys) |key| allocator.free(key);
            allocator.free(tombstoned_keys);
        }
        for (tombstoned_keys) |target_key| {
            _ = self.primary.forget(target_key) catch |err| {
                log.warn("zaki_dual: syncFromMarkdown failed to forget tombstoned key '{s}': {}", .{ target_key, err });
            };
        }

        const entries = try md.memory().list(allocator, null, null);
        defer root.freeEntries(allocator, entries);

        var imported: usize = 0;
        var skipped_already_present: usize = 0;
        for (entries) |entry| {
            if (!shouldSyncEntry(entry)) continue;
            // V1.14.12 (Finding 5 fix) — additive-only: never overwrite
            // an existing primary value with the Markdown copy. The
            // Postgres row is canonical by construction (every runtime
            // store path writes there first, see implStore).
            const existing = self.primary.get(allocator, entry.key) catch null;
            if (existing) |e| {
                e.deinit(allocator);
                skipped_already_present += 1;
                continue;
            }
            try self.primary.store(entry.key, entry.content, entry.category, entry.session_id);
            imported += 1;
        }
        if (imported > 0 or skipped_already_present > 0) {
            log.info("zaki_dual: syncFromMarkdown imported={d} skipped_already_present={d}", .{
                imported, skipped_already_present,
            });
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
        // Postgres (primary) is canonical — write it first and fail hard if it errors.
        try self.primary.store(key, content, category, session_id);
        // V7 — Markdown is an opt-in write-through mirror for human
        // inspection / restart sync. When OFF (the default), Postgres
        // is the only writer. When ON: if the mirror fails, log a
        // warning — on the next restart syncFromMarkdown will see a
        // stale (or absent) entry for this key and MUST NOT override
        // the Postgres value (additive-only). A future timestamp-based
        // merge would handle this gracefully.
        if (self.markdown_impl) |md| {
            md.memory().store(key, content, category, session_id) catch |err| {
                log.warn("zaki_dual: markdown mirror write failed for key '{s}': {} — " ++
                    "Postgres is authoritative; manual MEMORY.md sync may be needed", .{ key, err });
            };
        }
    }

    /// V1.14.12 (Memory audit Finding 4 fix, 2026-05-19) — implement the
    /// metadata-aware write so dual-mode tenants retain `references`,
    /// `link_type`, and provenance JSONB. Pre-fix, this slot was missing
    /// from the vtable, so memory/root.zig::storeWithMetadata fell back
    /// to plain `store()` and silently dropped the metadata — agent
    /// compose_memory + extraction writes lost their structural payload
    /// in tenant/dual mode.
    ///
    /// Strategy mirrors implStore: primary (Postgres) gets the full
    /// metadata write; markdown gets a content-only mirror (Markdown has
    /// no metadata schema — there's nothing to encode the JSONB into).
    fn implStoreWithMetadata(ptr: *anyopaque, key: []const u8, content: []const u8, category: root.MemoryCategory, session_id: ?[]const u8, metadata_json: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.primary.storeWithMetadata(key, content, category, session_id, metadata_json);
        if (self.markdown_impl) |md| {
            md.memory().store(key, content, category, session_id) catch |err| {
                log.warn("zaki_dual: markdown mirror metadata-write failed for key '{s}': {} — " ++
                    "Postgres has the canonical metadata; manual MEMORY.md sync may be needed", .{ key, err });
            };
        }
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
        // V7 — mirror OFF: Postgres is the only source of truth.
        const md = self.markdown_impl orelse return forgotten_primary;

        const markdown_entry = md.memory().get(self.allocator, key) catch null;
        defer if (markdown_entry) |*entry| entry.deinit(self.allocator);

        if (forgotten_primary or markdown_entry != null) {
            try md.appendTombstone(key, self.allocator);
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
        if (self.markdown_impl) |md| {
            md.deinit();
            self.allocator.destroy(md);
        }
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
        // V1.14.12 (Memory audit Finding 4 fix, 2026-05-19) — wire the
        // metadata-aware write slot. Pre-fix this was unset, so
        // memory/root.zig::storeWithMetadata fell back to plain `store()`
        // and silently dropped metadata in tenant/dual mode.
        .store_with_metadata = &implStoreWithMetadata,
    };
};

test "V1.14.12 (Memory audit Finding 4): zaki_dual vtable wires store_with_metadata" {
    // Pre-fix the vtable's `store_with_metadata` slot was null, so
    // memory/root.zig::storeWithMetadata fell back to plain `store()`
    // and silently dropped metadata.references / link_type / provenance
    // in tenant/dual mode. Lock the wiring.
    try std.testing.expect(ZakiDualMemory.mem_vtable.store_with_metadata != null);
}

test "zaki dual memory syncs markdown into canonical memory (mirror ON)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    var mem_impl = root.InMemoryLruMemory.init(allocator, 128);

    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace, true);
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

test "zaki dual memory ingests manual markdown edits into canonical memory (mirror ON)" {
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
    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace, true);
    var mem = dual.memory();
    try dual.syncFromMarkdown(allocator);

    const got = (try mem.get(allocator, "favorite_color")).?;
    defer got.deinit(allocator);
    try std.testing.expectEqualStrings("teal", got.content);

    mem.deinit();
}

test "V7: zaki dual memory writes ONLY to primary when mirror is OFF (default)" {
    // v1.14.18 Step 9 (V7) — `enable_markdown_mirror=false` (the new
    // default) must produce a pure-primary runtime: no MEMORY.md is
    // written, syncFromMarkdown is a no-op, and forget does not need
    // tombstone bookkeeping. Locks the default-off honesty contract.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    var mem_impl = root.InMemoryLruMemory.init(allocator, 128);

    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace, false);
    var mem = dual.memory();
    defer mem.deinit();

    // The mirror is not constructed at all.
    try std.testing.expect(dual.markdown_impl == null);

    try mem.store("user_color", "violet", .core, null);

    // Primary saw the write…
    const got = (try mem.get(allocator, "user_color")).?;
    defer got.deinit(allocator);
    try std.testing.expectEqualStrings("violet", got.content);

    // …but no MEMORY.md was written on disk.
    const memory_path = try std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{workspace});
    defer allocator.free(memory_path);
    const stat_result = std.fs.cwd().statFile(memory_path);
    try std.testing.expectError(error.FileNotFound, stat_result);

    // syncFromMarkdown is a no-op (must not error even though MEMORY.md is absent).
    try dual.syncFromMarkdown(allocator);

    // forget on a non-system key still works through the primary.
    try mem.store("ephemeral", "value", .core, null);
    const forgotten = try mem.forget("ephemeral");
    try std.testing.expect(forgotten);
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
    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace, true);
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
    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace, true);
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
    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace, true);
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
    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace, true);
    var mem = dual.memory();

    try mem.store("user_name", "Nova", .core, null);
    try std.testing.expect(try mem.forget("user_name"));
    try mem.store("user_name", "Nova Restored", .core, null);

    const entry = (try mem.get(allocator, "user_name")) orelse return error.TestUnexpectedResult;
    defer entry.deinit(allocator);
    try std.testing.expectEqualStrings("Nova Restored", entry.content);

    const md = dual.markdown_impl orelse return error.TestUnexpectedResult;
    const tombstoned = try md.readTombstonedKeys(allocator);
    defer {
        for (tombstoned) |key| allocator.free(key);
        allocator.free(tombstoned);
    }
    try std.testing.expectEqual(@as(usize, 0), tombstoned.len);

    mem.deinit();
}

test "V1.14.12 (Memory audit Finding 5): syncFromMarkdown does NOT override canonical primary state" {
    // Pre-fix: syncFromMarkdown unconditionally stored every Markdown
    // entry into primary, so a stale MEMORY.md could overwrite newer
    // DB facts on restart. The implStore comment at line ~72 explicitly
    // said "must NOT override the Postgres value" but the code didn't
    // enforce it; this test pre-fix asserted the WRONG behavior.
    //
    // Post-fix: syncFromMarkdown is additive-only — it imports keys
    // the primary doesn't have, but never replaces a key that already
    // exists. For intentional override, the user can /forget the row
    // and re-sync.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    var mem_impl = root.InMemoryLruMemory.init(allocator, 128);
    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace, true);
    var mem = dual.memory();

    try mem.store("favorite_color", "teal", .core, null);

    const memory_path = try std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{workspace});
    defer allocator.free(memory_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = memory_path,
        .data = "# MEMORY.md - Long-Term Memory\n\n- **favorite_color**: orange\n",
    });

    // Pre-sync: primary holds the runtime value.
    const runtime_get = (try mem.get(allocator, "favorite_color")) orelse return error.TestUnexpectedResult;
    defer runtime_get.deinit(allocator);
    try std.testing.expectEqualStrings("teal", runtime_get.content);

    try dual.syncFromMarkdown(allocator);

    // Post-sync: primary STILL holds the runtime value. Markdown's
    // "orange" did NOT override.
    const post_sync = (try mem.get(allocator, "favorite_color")) orelse return error.TestUnexpectedResult;
    defer post_sync.deinit(allocator);
    try std.testing.expectEqualStrings("teal", post_sync.content);

    mem.deinit();
}

test "V1.14.12 (Memory audit Finding 5): syncFromMarkdown imports keys absent from primary (additive)" {
    // The other side of the contract: a key in MEMORY.md that doesn't
    // exist in primary IS imported on sync. This preserves the original
    // intent of syncFromMarkdown (recover state from a fresh restart
    // with a populated MEMORY.md), just without the overwrite footgun.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);

    const memory_path = try std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{workspace});
    defer allocator.free(memory_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = memory_path,
        .data = "# MEMORY.md - Long-Term Memory\n\n- **fresh_key**: imported\n",
    });

    var mem_impl = root.InMemoryLruMemory.init(allocator, 128);
    const dual = try ZakiDualMemory.init(allocator, mem_impl.memory(), workspace, true);
    var mem = dual.memory();
    // Primary starts empty for `fresh_key`.
    try std.testing.expect((try mem.get(allocator, "fresh_key")) == null);

    try dual.syncFromMarkdown(allocator);

    const imported = (try mem.get(allocator, "fresh_key")) orelse return error.TestUnexpectedResult;
    defer imported.deinit(allocator);
    try std.testing.expectEqualStrings("imported", imported.content);

    mem.deinit();
}
