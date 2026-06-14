//! Memory snapshot — export/import core memories as JSON.
//!
//! Mirrors ZeroClaw's snapshot module:
//!   - export_snapshot: dumps all Memory entries to a JSON file
//!   - hydrate_from_snapshot: restores entries from JSON
//!   - should_hydrate: checks if memory is empty but snapshot exists

const std = @import("std");
const build_options = @import("build_options");
const root = @import("../root.zig");
const json_util = @import("../../json_util.zig");
const Memory = root.Memory;
const MemoryEntry = root.MemoryEntry;
const MemoryCategory = root.MemoryCategory;
const sqlite_mod = if (build_options.enable_sqlite) @import("../engines/sqlite.zig") else @import("../engines/sqlite_disabled.zig");

/// Default snapshot filename.
pub const SNAPSHOT_FILENAME = "MEMORY_SNAPSHOT.json";

// ── Export ─────────────────────────────────────────────────────────

/// Export ALL user-facing memories to a JSON snapshot file.
/// Returns the number of entries exported.
///
/// Phase-0.5b H4: a backup must be COMPLETE. Previously this listed only
/// `.core`, so after P3 routed durable user facts onto the typed categories
/// (preference/decision/person/open_loop) plus all `.daily` facts, those were
/// silently dropped from every backup. Passing `null` category exports every
/// category (the engine's list with no category filter returns all rows),
/// so the snapshot captures the full user fact set, not just legacy core.
pub fn exportSnapshot(allocator: std.mem.Allocator, mem: Memory, workspace_dir: []const u8) !usize {
    // List ALL memories (no category filter) — backup completeness.
    const entries = try mem.list(allocator, null, null);
    defer root.freeEntries(allocator, entries);

    if (entries.len == 0) return 0;

    // Build JSON output
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer json_buf.deinit(allocator);

    try json_buf.appendSlice(allocator, "[\n");

    for (entries, 0..) |entry, i| {
        if (i > 0) try json_buf.appendSlice(allocator, ",\n");
        try json_buf.appendSlice(allocator, "  {");
        try json_util.appendJsonKeyValue(&json_buf, allocator, "key", entry.key);
        try json_buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&json_buf, allocator, "content", entry.content);
        try json_buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&json_buf, allocator, "category", entry.category.toString());
        try json_buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&json_buf, allocator, "timestamp", entry.timestamp);
        // V1.5 day-2 — emit `valid_to` (Graphiti bi-temporal) so V1.5
        // snapshots are forward-compatible with V1.6's restore path.
        // V1.5 always-null path means most rows skip this field;
        // omitting null keeps the JSON tidy. V1.6 read path will pick
        // up the field when populated.
        if (entry.valid_to) |vt| {
            var int_buf: [32]u8 = undefined;
            const int_str = std.fmt.bufPrint(&int_buf, "{d}", .{vt}) catch unreachable;
            try json_buf.appendSlice(allocator, ",\"valid_to\":");
            try json_buf.appendSlice(allocator, int_str);
        }
        try json_buf.append(allocator, '}');
    }

    try json_buf.appendSlice(allocator, "\n]\n");

    // Write to file
    const snapshot_path = try std.fs.path.join(allocator, &.{ workspace_dir, SNAPSHOT_FILENAME });
    defer allocator.free(snapshot_path);

    const file = try std.fs.cwd().createFile(snapshot_path, .{});
    defer file.close();

    try file.writeAll(json_buf.items);

    return entries.len;
}

// ── Hydrate ───────────────────────────────────────────────────────

/// A parsed snapshot entry.
const SnapshotEntry = struct {
    key: []const u8,
    content: []const u8,
    category: []const u8,
};

/// Restore memory entries from a JSON snapshot file.
/// Returns the number of entries hydrated.
pub fn hydrateFromSnapshot(allocator: std.mem.Allocator, mem: Memory, workspace_dir: []const u8) !usize {
    const snapshot_path = try std.fs.path.join(allocator, &.{ workspace_dir, SNAPSHOT_FILENAME });
    defer allocator.free(snapshot_path);

    // Read snapshot file
    const content = std.fs.cwd().readFileAlloc(allocator, snapshot_path, 10 * 1024 * 1024) catch return 0;
    defer allocator.free(content);

    if (content.len == 0) return 0;

    // Parse JSON array
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return 0;
    defer parsed.deinit();

    const array = switch (parsed.value) {
        .array => |a| a,
        else => return 0,
    };

    var hydrated: usize = 0;
    for (array.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const key_val = obj.get("key") orelse continue;
        const content_val = obj.get("content") orelse continue;

        const key = switch (key_val) {
            .string => |s| s,
            else => continue,
        };
        const entry_content = switch (content_val) {
            .string => |s| s,
            else => continue,
        };

        // Determine category
        var category: MemoryCategory = .core;
        if (obj.get("category")) |cat_val| {
            const cat_str = switch (cat_val) {
                .string => |s| s,
                else => "core",
            };
            category = MemoryCategory.fromString(cat_str);
        }

        mem.store(key, entry_content, category, null) catch continue;
        // Bi-temporal `valid_to` asymmetry — KNOWN, parked (deferred D48).
        // The export path emits `valid_to` when populated, but `mem.store`
        // has no `valid_to` parameter, so hydrate cannot replay it. This
        // is loss-free *today*: `MemoryEntry.valid_to` is V1.5-always-null
        // (no backend populates it — the correction classifier is V1.6,
        // unbuilt; see `src/memory/root.zig` MemoryEntry.valid_to doc).
        // The asymmetry only becomes a real lossy round-trip once V1.6
        // lands the classifier, at which point hydrate needs a
        // `valid_to`-aware store API. Tracked in `docs/deferred-register.md`
        // row D48 so it is not silently forgotten when V1.6 starts.
        hydrated += 1;
    }

    return hydrated;
}

// ── Should hydrate ────────────────────────────────────────────────

/// Check if we should auto-hydrate on startup.
/// Returns true if memory is empty but snapshot file exists.
pub fn shouldHydrate(allocator: std.mem.Allocator, mem: ?Memory, workspace_dir: []const u8) bool {
    // Check if memory is empty
    if (mem) |m| {
        const count = m.count() catch 0;
        if (count > 0) return false;
    }

    // Check if snapshot file exists
    const snapshot_path = std.fs.path.join(allocator, &.{ workspace_dir, SNAPSHOT_FILENAME }) catch return false;
    defer allocator.free(snapshot_path);

    std.fs.cwd().access(snapshot_path, .{}) catch return false;
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────

test "shouldHydrate no memory no snapshot" {
    try std.testing.expect(!shouldHydrate(std.testing.allocator, null, "/nonexistent"));
}

test "shouldHydrate with non-empty memory" {
    if (!build_options.enable_sqlite) return;

    // Create an in-memory SQLite for test
    var mem_impl = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    // Store something
    try mem.store("test", "data", .core, null);

    // Should not hydrate because memory is not empty
    try std.testing.expect(!shouldHydrate(std.testing.allocator, mem, "/nonexistent"));
}

test "exportSnapshot returns zero for empty memory" {
    if (!build_options.enable_sqlite) return;

    var mem_impl = try sqlite_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    const count = try exportSnapshot(std.testing.allocator, mem, "/tmp/yc_snapshot_test_nonexist");
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "SNAPSHOT_FILENAME is correct" {
    try std.testing.expectEqualStrings("MEMORY_SNAPSHOT.json", SNAPSHOT_FILENAME);
}

// ── R3 Tests ──────────────────────────────────────────────────────

test "R3: snapshot export then import roundtrip preserves all entries" {
    if (!build_options.enable_sqlite) return;

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_dir);

    // Source memory: populate with entries
    var src_impl = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer src_impl.deinit();
    const src_mem = src_impl.memory();

    try src_mem.store("pref_lang", "Zig is the best", .core, null);
    try src_mem.store("pref_editor", "NeoVim forever", .core, null);
    try src_mem.store("user_name", "Igor", .core, null);

    // Export
    const exported = try exportSnapshot(allocator, src_mem, workspace_dir);
    try std.testing.expectEqual(@as(usize, 3), exported);

    // Destination memory: empty, then hydrate
    var dst_impl = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer dst_impl.deinit();
    const dst_mem = dst_impl.memory();

    const hydrated = try hydrateFromSnapshot(allocator, dst_mem, workspace_dir);
    try std.testing.expectEqual(@as(usize, 3), hydrated);

    // Verify all entries are present
    const count = try dst_mem.count();
    try std.testing.expectEqual(@as(usize, 3), count);

    // Verify specific entries
    const e1 = try dst_mem.get(allocator, "pref_lang");
    try std.testing.expect(e1 != null);
    defer e1.?.deinit(allocator);
    try std.testing.expectEqualStrings("Zig is the best", e1.?.content);

    const e2 = try dst_mem.get(allocator, "pref_editor");
    try std.testing.expect(e2 != null);
    defer e2.?.deinit(allocator);
    try std.testing.expectEqualStrings("NeoVim forever", e2.?.content);

    const e3 = try dst_mem.get(allocator, "user_name");
    try std.testing.expect(e3 != null);
    defer e3.?.deinit(allocator);
    try std.testing.expectEqualStrings("Igor", e3.?.content);
}

// Phase-0.5b H4 — backup completeness: exportSnapshot must capture ALL user
// facts, not just `.core`. Before the fix it listed only `.core`, so a
// `preference` (a P3 typed durable) and a `.daily` fact were silently dropped
// from every backup. This asserts both are exported and round-trip back.
test "H4: snapshot exports non-core facts (preference + daily), not just core" {
    if (!build_options.enable_sqlite) return;

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_dir);

    var src_impl = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer src_impl.deinit();
    const src_mem = src_impl.memory();

    // One of each: legacy core, a P3 typed durable, and an ephemeral daily.
    try src_mem.store("core_name", "Igor", .core, null);
    try src_mem.store("pref_editor", "NeoVim forever", .{ .custom = "preference" }, null);
    try src_mem.store("daily_note", "stood up at 9am", .daily, null);

    // Export → all 3 categories must be captured (not just the 1 core).
    const exported = try exportSnapshot(allocator, src_mem, workspace_dir);
    try std.testing.expectEqual(@as(usize, 3), exported);

    // Round-trip into a fresh store and confirm every fact survived.
    var dst_impl = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer dst_impl.deinit();
    const dst_mem = dst_impl.memory();

    const hydrated = try hydrateFromSnapshot(allocator, dst_mem, workspace_dir);
    try std.testing.expectEqual(@as(usize, 3), hydrated);

    const pref = try dst_mem.get(allocator, "pref_editor");
    try std.testing.expect(pref != null);
    defer pref.?.deinit(allocator);
    try std.testing.expectEqualStrings("NeoVim forever", pref.?.content);
    // category preserved across the snapshot round-trip
    try std.testing.expect(pref.?.category.eql(.{ .custom = "preference" }));

    const daily = try dst_mem.get(allocator, "daily_note");
    try std.testing.expect(daily != null);
    defer daily.?.deinit(allocator);
    try std.testing.expectEqualStrings("stood up at 9am", daily.?.content);
    try std.testing.expect(daily.?.category.eql(.daily));
}

test "R3: shouldHydrate returns true when memory is empty and snapshot exists" {
    if (!build_options.enable_sqlite) return;

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const snap_file = try tmp.dir.createFile(SNAPSHOT_FILENAME, .{});
    snap_file.close();

    const workspace_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace_dir);

    var mem_impl = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    try std.testing.expect(shouldHydrate(allocator, mem, workspace_dir));
}

test "R3: hydrateFromSnapshot with no file returns 0" {
    if (!build_options.enable_sqlite) return;

    const allocator = std.testing.allocator;

    var mem_impl = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    const hydrated = try hydrateFromSnapshot(allocator, mem, "/nonexistent_dir_xyz");
    try std.testing.expectEqual(@as(usize, 0), hydrated);
}
