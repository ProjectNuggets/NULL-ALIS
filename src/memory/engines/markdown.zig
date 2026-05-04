//! Markdown-based memory — plain files as source of truth.
//!
//! Layout:
//!   workspace/MEMORY.md          — curated long-term memory (core)
//!   workspace/memory/YYYY-MM-DD.md — daily logs (append-only)
//!
//! This backend is append-only: forget() is a no-op to preserve audit trail.

const std = @import("std");
const root = @import("../root.zig");
const Memory = root.Memory;
const MemoryCategory = root.MemoryCategory;
const MemoryEntry = root.MemoryEntry;
const LAST_HYGIENE_KEY = "last_hygiene_at";
const TOMBSTONES_FILENAME = "TOMBSTONES.md";

/// Max size for a single memory markdown file on read. Grew from 1 MB to 16 MB
/// after production logs showed `error.FileTooBig` on MEMORY.md for active
/// sessions with many curated entries + context anchors. Postgres is
/// authoritative; the markdown mirror only degrades if this cap is too low.
/// 16 MB is a practical ceiling — a single markdown at that size is a
/// pathological state that a future sweeper should compact.
const MARKDOWN_FILE_READ_CAP: usize = 16 * 1024 * 1024;

pub const MarkdownMemory = struct {
    workspace_dir: []const u8,
    allocator: std.mem.Allocator,
    owns_self: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, workspace_dir: []const u8) !Self {
        return Self{
            .workspace_dir = try allocator.dupe(u8, workspace_dir),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.workspace_dir);
    }

    fn corePath(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{self.workspace_dir});
    }

    fn memoryDir(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/memory", .{self.workspace_dir});
    }

    fn dailyPath(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        const ts = std.time.timestamp();
        const epoch: u64 = @intCast(ts);
        const es = std.time.epoch.EpochSeconds{ .secs = epoch };
        const day = es.getEpochDay().calculateYearDay();
        const md = day.calculateMonthDay();

        return std.fmt.allocPrint(allocator, "{s}/memory/{d:0>4}-{d:0>2}-{d:0>2}.md", .{
            self.workspace_dir,
            day.year,
            @intFromEnum(md.month),
            md.day_index + 1,
        });
    }

    fn tombstonePath(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/memory/{s}", .{ self.workspace_dir, TOMBSTONES_FILENAME });
    }

    fn ensureDir(path: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    fn appendToFile(path: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
        try ensureDir(path);

        // Open (or create) without truncation and seek to end to append.
        // This avoids the read-concat-rewrite pattern which loses data if
        // the process crashes between truncation and write completion.
        const file = try std.fs.cwd().createFile(path, .{ .truncate = false, .read = true });
        defer file.close();

        const stat = try file.stat();
        const size = stat.size;

        try file.seekTo(size);

        // If the file already has content and doesn't end with a newline,
        // prepend one to keep entries on separate lines.
        if (size > 0) {
            try file.seekTo(size - 1);
            var last_byte: [1]u8 = undefined;
            const n = try file.read(&last_byte);
            if (n == 1 and last_byte[0] != '\n') {
                try file.seekTo(size);
                try file.writeAll("\n");
            } else {
                try file.seekTo(size);
            }
        }

        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{content});
        defer allocator.free(line);
        try file.writeAll(line);
    }

    fn writeFileAtomic(path: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
        try ensureDir(path);

        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        defer allocator.free(tmp_path);

        const tmp_file = try std.fs.createFileAbsolute(tmp_path, .{});
        errdefer tmp_file.close();
        try tmp_file.writeAll(content);
        tmp_file.close();

        std.fs.renameAbsolute(tmp_path, path) catch {
            std.fs.deleteFileAbsolute(tmp_path) catch {};
            const file = try std.fs.createFileAbsolute(path, .{});
            defer file.close();
            try file.writeAll(content);
        };
    }

    fn lineHasStructuredKey(line: []const u8, key: []const u8) bool {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return false;

        const clean = if (std.mem.startsWith(u8, trimmed, "- "))
            trimmed[2..]
        else
            trimmed;

        if (!std.mem.startsWith(u8, clean, "**")) return false;
        if (std.mem.indexOf(u8, clean[2..], "**:")) |end_off| {
            const key_slice = std.mem.trim(u8, clean[2 .. 2 + end_off], " \t");
            return std.mem.eql(u8, key_slice, key);
        }
        return false;
    }

    fn formatStructuredEntry(
        allocator: std.mem.Allocator,
        key: []const u8,
        content: []const u8,
    ) ![]u8 {
        if (std.mem.indexOfScalar(u8, content, '\n') == null) {
            return std.fmt.allocPrint(allocator, "- **{s}**: {s}", .{ key, content });
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        const w = out.writer(allocator);
        try std.fmt.format(w, "- **{s}**:\n", .{key});

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            try std.fmt.format(w, "  {s}\n", .{line});
        }

        if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
            _ = out.pop();
        }
        return out.toOwnedSlice(allocator);
    }

    fn replaceCoreEntryAtomic(path: []const u8, key: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
        try ensureDir(path);

        const existing = std.fs.cwd().readFileAlloc(allocator, path, MARKDOWN_FILE_READ_CAP) catch |err| switch (err) {
            error.FileNotFound => try allocator.dupe(u8, ""),
            else => return err,
        };
        defer allocator.free(existing);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        var iter = std.mem.splitScalar(u8, existing, '\n');
        var skipping_continuation = false;
        while (iter.next()) |line| {
            if (skipping_continuation) {
                if (std.mem.startsWith(u8, line, "  ") or (line.len > 0 and line[0] == '\t')) continue;
                skipping_continuation = false;
            }
            if (lineHasStructuredKey(line, key)) {
                skipping_continuation = true;
                continue;
            }
            try buf.appendSlice(allocator, line);
            try buf.append(allocator, '\n');
        }

        while (buf.items.len > 0 and std.ascii.isWhitespace(buf.items[buf.items.len - 1])) {
            _ = buf.pop();
        }
        if (buf.items.len > 0) {
            try buf.append(allocator, '\n');
        }
        const formatted = try formatStructuredEntry(allocator, key, content);
        defer allocator.free(formatted);
        try buf.appendSlice(allocator, formatted);
        try buf.append(allocator, '\n');

        try writeFileAtomic(path, buf.items, allocator);
    }

    fn removeStructuredEntryAtomic(path: []const u8, key: []const u8, allocator: std.mem.Allocator) !void {
        try ensureDir(path);

        const existing = std.fs.cwd().readFileAlloc(allocator, path, MARKDOWN_FILE_READ_CAP) catch |err| switch (err) {
            error.FileNotFound => try allocator.dupe(u8, ""),
            else => return err,
        };
        defer allocator.free(existing);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        var iter = std.mem.splitScalar(u8, existing, '\n');
        var skipping_continuation = false;
        while (iter.next()) |line| {
            if (skipping_continuation) {
                if (std.mem.startsWith(u8, line, "  ") or (line.len > 0 and line[0] == '\t')) continue;
                skipping_continuation = false;
            }
            if (lineHasStructuredKey(line, key)) {
                skipping_continuation = true;
                continue;
            }
            try buf.appendSlice(allocator, line);
            try buf.append(allocator, '\n');
        }

        while (buf.items.len > 0 and std.ascii.isWhitespace(buf.items[buf.items.len - 1])) {
            _ = buf.pop();
        }
        if (buf.items.len == 0) {
            std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            return;
        }

        try writeFileAtomic(path, buf.items, allocator);
    }

    fn removeTombstoneAtomic(self: *const Self, key: []const u8, allocator: std.mem.Allocator) !void {
        const path = try self.tombstonePath(allocator);
        defer allocator.free(path);
        const tombstone_key = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root.TombstoneKeyPrefix, key });
        defer allocator.free(tombstone_key);
        try removeStructuredEntryAtomic(path, tombstone_key, allocator);
    }

    pub fn appendTombstone(self: *const Self, key: []const u8, allocator: std.mem.Allocator) !void {
        const path = try self.tombstonePath(allocator);
        defer allocator.free(path);
        const now = try std.fmt.allocPrint(allocator, "{d}", .{std.time.timestamp()});
        defer allocator.free(now);
        const tombstone_key = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root.TombstoneKeyPrefix, key });
        defer allocator.free(tombstone_key);
        const entry_text = try std.fmt.allocPrint(allocator, "- **{s}**: {s}", .{ tombstone_key, now });
        defer allocator.free(entry_text);
        try appendToFile(path, entry_text, allocator);
    }

    pub fn readTombstonedKeys(self: *const Self, allocator: std.mem.Allocator) ![][]u8 {
        var result: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (result.items) |key| allocator.free(key);
            result.deinit(allocator);
        }

        const path = try self.tombstonePath(allocator);
        defer allocator.free(path);

        const content = std.fs.cwd().readFileAlloc(allocator, path, MARKDOWN_FILE_READ_CAP) catch |err| switch (err) {
            error.FileNotFound => return result.toOwnedSlice(allocator),
            else => return err,
        };
        defer allocator.free(content);

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            const clean = if (std.mem.startsWith(u8, trimmed, "- ")) trimmed[2..] else trimmed;
            if (!std.mem.startsWith(u8, clean, "**")) continue;
            if (std.mem.indexOf(u8, clean[2..], "**:")) |end_off| {
                const key_slice = std.mem.trim(u8, clean[2 .. 2 + end_off], " \t");
                if (root.tombstoneTargetKey(key_slice)) |target_key| {
                    try result.append(allocator, try allocator.dupe(u8, target_key));
                }
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn dupeEntryBytes(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
        if (source.len == 0) return allocator.alloc(u8, 0);
        const out = try allocator.alloc(u8, source.len);
        const src: [*]align(1) const u8 = @ptrCast(source.ptr);
        std.mem.copyForwards(u8, out, src[0..source.len]);
        return out;
    }

    fn cloneCategory(allocator: std.mem.Allocator, category: MemoryCategory) !MemoryCategory {
        return switch (category) {
            .custom => |name| MemoryCategory{ .custom = try dupeEntryBytes(allocator, name) },
            else => category,
        };
    }

    fn cloneEntry(allocator: std.mem.Allocator, entry: MemoryEntry) !MemoryEntry {
        const id = try dupeEntryBytes(allocator, entry.id);
        errdefer allocator.free(id);
        const key = try dupeEntryBytes(allocator, entry.key);
        errdefer allocator.free(key);
        const content = try dupeEntryBytes(allocator, entry.content);
        errdefer allocator.free(content);
        const timestamp = try dupeEntryBytes(allocator, entry.timestamp);
        errdefer allocator.free(timestamp);
        const category = try cloneCategory(allocator, entry.category);
        errdefer switch (category) {
            .custom => |name| allocator.free(name),
            else => {},
        };
        const session_id = if (entry.session_id) |sid|
            try dupeEntryBytes(allocator, sid)
        else
            null;
        errdefer if (session_id) |sid| allocator.free(sid);
        // S8.1 — populate lane from session_id when present (post-S8.1
        // review fix M-LANE; mirrors sqlite + postgres engines).
        const lane: []const u8 = if (session_id) |s| root.laneFromSessionId(s) else "unknown";
        return MemoryEntry{
            .id = id,
            .key = key,
            .content = content,
            .category = category,
            .timestamp = timestamp,
            .session_id = session_id,
            .score = entry.score,
            .lane = lane,
        };
    }

    fn parseEntries(text: []const u8, filename: []const u8, category: MemoryCategory, allocator: std.mem.Allocator) ![]MemoryEntry {
        var entries: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*e| e.deinit(allocator);
            entries.deinit(allocator);
        }

        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer lines.deinit(allocator);

        var split = std.mem.splitScalar(u8, text, '\n');
        while (split.next()) |line| {
            try lines.append(allocator, line);
        }

        var line_idx: usize = 0;
        var i: usize = 0;
        while (i < lines.items.len) : (i += 1) {
            const line = lines.items[i];
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') {
                continue;
            }

            const clean = if (std.mem.startsWith(u8, trimmed, "- "))
                trimmed[2..]
            else
                trimmed;

            var parsed_key: ?[]const u8 = null;
            var parsed_content: []const u8 = clean;
            if (std.mem.startsWith(u8, clean, "**")) {
                if (std.mem.indexOf(u8, clean[2..], "**:")) |end_off| {
                    const key_slice = std.mem.trim(u8, clean[2 .. 2 + end_off], " \t");
                    const content_start = 2 + end_off + 3;
                    if (key_slice.len > 0 and content_start <= clean.len) {
                        parsed_key = key_slice;
                        parsed_content = std.mem.trim(u8, clean[content_start..], " \t");
                    }
                }
            }

            var content_dup: []u8 = undefined;
            if (parsed_key != null) {
                var structured: std.ArrayListUnmanaged(u8) = .empty;
                errdefer structured.deinit(allocator);
                if (parsed_content.len > 0) {
                    try structured.appendSlice(allocator, parsed_content);
                }

                while (i + 1 < lines.items.len) {
                    const next_line = lines.items[i + 1];
                    if (next_line.len == 0) break;
                    if (std.mem.startsWith(u8, next_line, "  ")) {
                        if (structured.items.len > 0) try structured.append(allocator, '\n');
                        try structured.appendSlice(allocator, next_line[2..]);
                        i += 1;
                        continue;
                    }
                    if (next_line[0] == '\t') {
                        if (structured.items.len > 0) try structured.append(allocator, '\n');
                        try structured.appendSlice(allocator, next_line[1..]);
                        i += 1;
                        continue;
                    }
                    break;
                }
                content_dup = try structured.toOwnedSlice(allocator);
            } else {
                content_dup = try dupeEntryBytes(allocator, parsed_content);
            }
            errdefer allocator.free(content_dup);

            const id = if (parsed_key) |key_slice|
                try dupeEntryBytes(allocator, key_slice)
            else
                try std.fmt.allocPrint(allocator, "{s}:{d}", .{ filename, line_idx });
            errdefer allocator.free(id);
            const key = if (parsed_key) |key_slice|
                try dupeEntryBytes(allocator, key_slice)
            else
                try dupeEntryBytes(allocator, id);
            errdefer allocator.free(key);
            const timestamp = try dupeEntryBytes(allocator, filename);
            errdefer allocator.free(timestamp);

            const cat = switch (category) {
                .custom => |name| MemoryCategory{ .custom = try dupeEntryBytes(allocator, name) },
                else => category,
            };

            try entries.append(allocator, MemoryEntry{
                .id = id,
                .key = key,
                .content = content_dup,
                .category = cat,
                .timestamp = timestamp,
            });

            line_idx += 1;
        }

        return entries.toOwnedSlice(allocator);
    }

    fn readAllEntries(self: *Self, allocator: std.mem.Allocator) ![]MemoryEntry {
        var all: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (all.items) |*e| e.deinit(allocator);
            all.deinit(allocator);
        }

        // Parse using a page-backed arena to avoid cross-thread allocator contention
        // in high-concurrency markdown scans. Final entries are cloned into caller allocator.
        var parse_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer parse_arena.deinit();
        const parse_allocator = parse_arena.allocator();

        const cp = try self.corePath(parse_allocator);
        defer parse_allocator.free(cp);
        if (std.fs.cwd().readFileAlloc(parse_allocator, cp, MARKDOWN_FILE_READ_CAP)) |content| {
            const entries = try parseEntries(content, "MEMORY", .core, parse_allocator);
            for (entries) |entry| {
                const cloned = try cloneEntry(allocator, entry);
                try all.append(allocator, cloned);
            }
        } else |_| {}

        const md = try self.memoryDir(parse_allocator);
        defer parse_allocator.free(md);
        if (std.fs.cwd().openDir(md, .{ .iterate = true })) |*dir_handle| {
            var dir = dir_handle.*;
            defer dir.close();
            var filenames: std.ArrayListUnmanaged([]u8) = .empty;
            defer {
                for (filenames.items) |name| allocator.free(name);
                filenames.deinit(allocator);
            }
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
                if (std.mem.eql(u8, entry.name, TOMBSTONES_FILENAME)) continue;
                try filenames.append(allocator, try allocator.dupe(u8, entry.name));
            }

            std.mem.sort([]u8, filenames.items, {}, struct {
                fn lessThan(_: void, a: []u8, b: []u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);

            for (filenames.items) |entry_name| {
                const fpath = try std.fmt.allocPrint(parse_allocator, "{s}/{s}", .{ md, entry_name });
                defer parse_allocator.free(fpath);
                if (std.fs.cwd().readFileAlloc(parse_allocator, fpath, MARKDOWN_FILE_READ_CAP)) |content| {
                    const fname = entry_name[0 .. entry_name.len - 3];
                    const entries = try parseEntries(content, fname, .daily, parse_allocator);
                    for (entries) |parsed| {
                        const cloned = try cloneEntry(allocator, parsed);
                        try all.append(allocator, cloned);
                    }
                } else |_| {}
            }

            const tombstone_path = try std.fmt.allocPrint(parse_allocator, "{s}/{s}", .{ md, TOMBSTONES_FILENAME });
            defer parse_allocator.free(tombstone_path);
            if (std.fs.cwd().readFileAlloc(parse_allocator, tombstone_path, MARKDOWN_FILE_READ_CAP)) |content| {
                const entries = try parseEntries(content, "TOMBSTONES", .daily, parse_allocator);
                for (entries) |parsed| {
                    const cloned = try cloneEntry(allocator, parsed);
                    try all.append(allocator, cloned);
                }
            } else |_| {}
        } else |_| {}

        var collapsed: std.ArrayListUnmanaged(MemoryEntry) = .empty;
        errdefer {
            for (collapsed.items) |*e| e.deinit(allocator);
            collapsed.deinit(allocator);
        }
        var mutable_positions: std.StringHashMapUnmanaged(usize) = .empty;
        defer mutable_positions.deinit(allocator);
        // V1.8-0 fix: tombstoned stores OWNED keys (duped from entry.key slices).
        // Without this, target_key — a slice into entry.key — outlives entry.deinit
        // at the end of each iteration, leaving dangling key pointers in the hashmap.
        // Subsequent puts then corrupt bucket invariants and a later grow rehash
        // crashes with putAssumeCapacityNoClobberContext assertion failure.
        // See .audit/v1.8/runs/kimi-pass-c-20260504-215527/FINDINGS.md
        var tombstoned: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = tombstoned.keyIterator();
            while (it.next()) |k_ptr| allocator.free(k_ptr.*);
            tombstoned.deinit(allocator);
        }

        for (all.items) |*entry_ptr| {
            var entry = entry_ptr.*;
            if (root.isTombstoneKey(entry.key)) {
                if (root.tombstoneTargetKey(entry.key)) |target_key_slice| {
                    // Dupe before tombstoned.put — target_key_slice points into
                    // entry.key memory which is freed by entry.deinit below.
                    const target_key = try allocator.dupe(u8, target_key_slice);
                    const gop = try tombstoned.getOrPut(allocator, target_key);
                    if (gop.found_existing) {
                        // Same key tombstoned more than once — free the dupe,
                        // existing entry already owns its key memory.
                        allocator.free(target_key);
                    }
                    // Use target_key_slice for mutable_positions lookup since the
                    // slice is still alive within this iteration step. (Either
                    // pointer would byte-match; using the slice avoids relying on
                    // the gop branch above.)
                    if (mutable_positions.get(target_key_slice)) |idx| {
                        // Order matters: remove from mutable_positions BEFORE
                        // deinit'ing collapsed.items[idx] (whose key is the
                        // pointer mutable_positions stored).
                        _ = mutable_positions.remove(target_key_slice);
                        collapsed.items[idx].deinit(allocator);
                        _ = collapsed.swapRemove(idx);
                        if (idx < collapsed.items.len) {
                            const moved_key = collapsed.items[idx].key;
                            if (root.isMutableMemoryEntry(moved_key, collapsed.items[idx].category)) {
                                try mutable_positions.put(allocator, moved_key, idx);
                            }
                        }
                    }
                }
                entry.deinit(allocator);
                continue;
            }

            if (root.isMutableMemoryEntry(entry.key, entry.category)) {
                if (tombstoned.contains(entry.key)) {
                    entry.deinit(allocator);
                    continue;
                }
                if (mutable_positions.get(entry.key)) |idx| {
                    const old_key = collapsed.items[idx].key;
                    _ = mutable_positions.remove(old_key);
                    collapsed.items[idx].deinit(allocator);
                    collapsed.items[idx] = entry;
                    try mutable_positions.put(allocator, collapsed.items[idx].key, idx);
                } else {
                    try mutable_positions.put(allocator, entry.key, collapsed.items.len);
                    try collapsed.append(allocator, entry);
                }
                continue;
            }

            try collapsed.append(allocator, entry);
        }

        all.deinit(allocator);
        return collapsed.toOwnedSlice(allocator);
    }

    // ── Memory vtable impl ────────────────────────────────────────

    fn implName(_: *anyopaque) []const u8 {
        return "markdown";
    }

    fn implStore(ptr: *anyopaque, key: []const u8, content: []const u8, category: MemoryCategory, _: ?[]const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const scratch_allocator = scratch.allocator();

        if (root.isTombstoneKey(key)) {
            try self_.appendTombstone(root.tombstoneTargetKey(key) orelse key, scratch_allocator);
            return;
        }

        if (root.isMutableMemoryEntry(key, category) or (category == .core and std.mem.eql(u8, key, LAST_HYGIENE_KEY))) {
            const path = try self_.corePath(scratch_allocator);
            try replaceCoreEntryAtomic(path, key, content, scratch_allocator);
            if (root.isEditableMemoryEntry(key, category)) {
                try self_.removeTombstoneAtomic(key, scratch_allocator);
            }
            return;
        }

        const path = switch (category) {
            .core => try self_.corePath(scratch_allocator),
            else => try self_.dailyPath(scratch_allocator),
        };
        const entry_text = try formatStructuredEntry(scratch_allocator, key, content);
        defer scratch_allocator.free(entry_text);
        try appendToFile(path, entry_text, scratch_allocator);
    }

    fn implRecall(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, _: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const all = try self_.readAllEntries(allocator);
        defer allocator.free(all);

        const query_lower = try std.ascii.allocLowerString(allocator, query);
        defer allocator.free(query_lower);

        var keywords: std.ArrayList([]const u8) = .empty;
        defer keywords.deinit(allocator);
        var kw_iter = std.mem.tokenizeAny(u8, query_lower, " \t\n\r");
        while (kw_iter.next()) |word| try keywords.append(allocator, word);

        if (keywords.items.len == 0) {
            for (all) |*e| @constCast(e).deinit(allocator);
            return allocator.alloc(MemoryEntry, 0);
        }

        var scored: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (scored.items) |*e| e.deinit(allocator);
            scored.deinit(allocator);
        }

        for (all) |*entry_ptr| {
            var entry = entry_ptr.*;
            const content_lower = try std.ascii.allocLowerString(allocator, entry.content);
            defer allocator.free(content_lower);

            var matched: usize = 0;
            for (keywords.items) |kw| {
                if (std.mem.indexOf(u8, content_lower, kw) != null) matched += 1;
            }

            if (matched > 0) {
                const score: f64 = @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(keywords.items.len));
                entry.score = score;
                try scored.append(allocator, entry);
            } else {
                @constCast(entry_ptr).deinit(allocator);
            }
        }

        std.mem.sort(MemoryEntry, scored.items, {}, struct {
            fn lessThan(_: void, a: MemoryEntry, b: MemoryEntry) bool {
                return (b.score orelse 0) < (a.score orelse 0);
            }
        }.lessThan);

        if (scored.items.len > limit) {
            for (scored.items[limit..]) |*e| e.deinit(allocator);
            scored.shrinkRetainingCapacity(limit);
        }

        return scored.toOwnedSlice(allocator);
    }

    fn implGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const all = try self_.readAllEntries(allocator);
        defer allocator.free(all);

        var exact: ?MemoryEntry = null;
        var fallback: ?MemoryEntry = null;
        for (all) |*entry_ptr| {
            const entry = entry_ptr.*;
            if (std.mem.eql(u8, entry.key, key)) {
                if (exact) |*prev| {
                    prev.deinit(allocator);
                } else if (fallback) |*prev| {
                    prev.deinit(allocator);
                    fallback = null;
                }
                exact = entry;
                continue;
            }
            if (exact == null and fallback == null and std.mem.indexOf(u8, entry.content, key) != null) {
                fallback = entry;
                continue;
            }
            @constCast(entry_ptr).deinit(allocator);
        }

        return exact orelse fallback;
    }

    fn implList(ptr: *anyopaque, allocator: std.mem.Allocator, category: ?MemoryCategory, _: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const all = try self_.readAllEntries(allocator);
        defer allocator.free(all);

        if (category == null) {
            const result = try allocator.alloc(MemoryEntry, all.len);
            @memcpy(result, all);
            return result;
        }

        var filtered: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (filtered.items) |*e| e.deinit(allocator);
            filtered.deinit(allocator);
        }

        for (all) |*entry_ptr| {
            var entry = entry_ptr.*;
            if (entry.category.eql(category.?)) {
                try filtered.append(allocator, entry);
            } else {
                @constCast(entry_ptr).deinit(allocator);
            }
        }

        return filtered.toOwnedSlice(allocator);
    }

    fn implForget(_: *anyopaque, _: []const u8) anyerror!bool {
        return false;
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const scratch_allocator = scratch.allocator();
        const all = try self_.readAllEntries(scratch_allocator);
        return all.len;
    }

    fn implHealthCheck(_: *anyopaque) bool {
        return true;
    }

    fn implDeinit(ptr: *anyopaque) void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        self_.deinit();
        if (self_.owns_self) {
            self_.allocator.destroy(self_);
        }
    }

    const vtable = Memory.VTable{
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

    pub fn memory(self: *Self) Memory {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "markdown forget always returns false" {
    var mem = try MarkdownMemory.init(std.testing.allocator, "/tmp/nullalis-test-md-forget");
    defer mem.deinit();
    const m = mem.memory();

    // Multiple forget calls all return false
    try std.testing.expect(!(try m.forget("key1")));
    try std.testing.expect(!(try m.forget("key2")));
    try std.testing.expect(!(try m.forget("")));
}

test "markdown parseEntries skips empty lines" {
    const text = "line one\n\n\nline two\n";
    const entries = try MarkdownMemory.parseEntries(text, "test", .core, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("line one", entries[0].content);
    try std.testing.expectEqualStrings("line two", entries[1].content);
}

test "markdown parseEntries skips headings" {
    const text = "# Heading\nContent under heading\n## Sub\nMore content";
    const entries = try MarkdownMemory.parseEntries(text, "test", .core, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("Content under heading", entries[0].content);
    try std.testing.expectEqualStrings("More content", entries[1].content);
}

test "markdown parseEntries strips bullet prefix" {
    const text = "- Item one\n- Item two\nPlain line";
    const entries = try MarkdownMemory.parseEntries(text, "test", .core, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("Item one", entries[0].content);
    try std.testing.expectEqualStrings("Item two", entries[1].content);
    try std.testing.expectEqualStrings("Plain line", entries[2].content);
}

test "markdown parseEntries generates sequential ids" {
    const text = "a\nb\nc";
    const entries = try MarkdownMemory.parseEntries(text, "myfile", .core, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("myfile:0", entries[0].id);
    try std.testing.expectEqualStrings("myfile:1", entries[1].id);
    try std.testing.expectEqualStrings("myfile:2", entries[2].id);
}

test "markdown parseEntries preserves structured key entries" {
    const text = "- **favorite_snack**: pistachios\n- **timezone**: UTC";
    const entries = try MarkdownMemory.parseEntries(text, "MEMORY", .core, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("favorite_snack", entries[0].key);
    try std.testing.expectEqualStrings("pistachios", entries[0].content);
    try std.testing.expectEqualStrings("timezone", entries[1].key);
    try std.testing.expectEqualStrings("UTC", entries[1].content);
}

test "markdown parseEntries empty text returns empty" {
    const entries = try MarkdownMemory.parseEntries("", "test", .core, std.testing.allocator);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "markdown parseEntries only headings returns empty" {
    const text = "# Heading\n## Another\n### Third";
    const entries = try MarkdownMemory.parseEntries(text, "test", .core, std.testing.allocator);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "markdown parseEntries preserves category" {
    const text = "content";
    const entries = try MarkdownMemory.parseEntries(text, "test", .daily, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expect(entries[0].category.eql(.daily));
}

test "markdown accepts session_id param" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const m = mem.memory();

    // session_id is accepted but ignored by markdown backend
    try m.store("sess_key", "session data", .core, "session-123");

    const recalled = try m.recall(std.testing.allocator, "session", 10, "session-123");
    defer {
        for (recalled) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(recalled);
    }

    const listed = try m.list(std.testing.allocator, null, "session-123");
    defer {
        for (listed) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(listed);
    }
}

test "markdown concurrent count does not panic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const memory = mem.memory();

    for (0..32) |idx| {
        const key = try std.fmt.allocPrint(std.testing.allocator, "count_key_{d}", .{idx});
        defer std.testing.allocator.free(key);
        const content = try std.fmt.allocPrint(std.testing.allocator, "count_value_{d}", .{idx});
        defer std.testing.allocator.free(content);
        try memory.store(key, content, .core, null);
    }

    const worker_count = 8;
    var failed = std.atomic.Value(bool).init(false);
    var handles: [worker_count]std.Thread = undefined;

    for (0..worker_count) |idx| {
        handles[idx] = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, struct {
            fn run(mem_i: Memory, failed_flag: *std.atomic.Value(bool)) void {
                for (0..64) |_| {
                    _ = mem_i.count() catch {
                        failed_flag.store(true, .release);
                        return;
                    };
                }
            }
        }.run, .{ memory, &failed });
    }

    for (handles) |handle| handle.join();
    try std.testing.expect(!failed.load(.acquire));
}

test "markdown concurrent recall list get does not panic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const memory = mem.memory();

    for (0..32) |idx| {
        const key = try std.fmt.allocPrint(std.testing.allocator, "lookup_key_{d}", .{idx});
        defer std.testing.allocator.free(key);
        const content = try std.fmt.allocPrint(std.testing.allocator, "lookup_value_{d}", .{idx});
        defer std.testing.allocator.free(content);
        try memory.store(key, content, .core, null);
    }

    const worker_count = 8;
    var failed = std.atomic.Value(bool).init(false);
    var handles: [worker_count]std.Thread = undefined;

    for (0..worker_count) |idx| {
        handles[idx] = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, struct {
            fn run(mem_i: Memory, failed_flag: *std.atomic.Value(bool)) void {
                const alloc = std.heap.smp_allocator;
                for (0..32) |_| {
                    const recalled = mem_i.recall(alloc, "lookup_value", 10, null) catch {
                        failed_flag.store(true, .release);
                        return;
                    };
                    root.freeEntries(alloc, recalled);

                    const listed = mem_i.list(alloc, null, null) catch {
                        failed_flag.store(true, .release);
                        return;
                    };
                    root.freeEntries(alloc, listed);

                    const got = mem_i.get(alloc, "lookup_key_1") catch {
                        failed_flag.store(true, .release);
                        return;
                    };
                    if (got) |entry| entry.deinit(alloc);
                }
            }
        }.run, .{ memory, &failed });
    }

    for (handles) |handle| handle.join();
    try std.testing.expect(!failed.load(.acquire));
}

test "markdown replaces hygiene metadata instead of appending duplicates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const memory = mem.memory();

    try memory.store("favorite_color", "teal", .core, null);
    try memory.store(LAST_HYGIENE_KEY, "100", .core, null);
    try memory.store(LAST_HYGIENE_KEY, "200", .core, null);

    const memory_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/MEMORY.md", .{base});
    defer std.testing.allocator.free(memory_path);
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, memory_path, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "- **favorite_color**: teal") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "- **last_hygiene_at**: 100") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "- **last_hygiene_at**: 200") != null);
}

test "markdown get prefers newest exact key match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    const memory_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/MEMORY.md", .{base});
    defer std.testing.allocator.free(memory_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = memory_path,
        .data = "# MEMORY.md - Long-Term Memory\n\n" ++
            "- **duplicate_key**: first\n" ++
            "- **duplicate_key**: second\n",
    });

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();

    const got = (try mem.memory().get(std.testing.allocator, "duplicate_key")).?;
    defer got.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("second", got.content);
}

test "markdown mutable core keys replace in place" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const memory = mem.memory();

    try memory.store("user_name", "Nova", .core, null);
    try memory.store("user_name", "Nova Alis", .core, null);

    const memory_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/MEMORY.md", .{base});
    defer std.testing.allocator.free(memory_path);
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, memory_path, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "- **user_name**: Nova\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "- **user_name**: Nova Alis") != null);
}

test "markdown stores multiline structured entries in readable block form" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const memory = mem.memory();

    const key = "summary_latest/agent:zaki-bot:user:1:main";
    const content =
        "type=summary_latest\n" ++
        "session=agent:zaki-bot:user:1:main\n" ++
        "focus: shipping readiness\n" ++
        "next:\n" ++
        "- ship";
    try memory.store(key, content, .core, null);

    const memory_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/MEMORY.md", .{base});
    defer std.testing.allocator.free(memory_path);
    const file_content = try std.fs.cwd().readFileAlloc(std.testing.allocator, memory_path, 4096);
    defer std.testing.allocator.free(file_content);

    try std.testing.expect(std.mem.indexOf(u8, file_content, "- **summary_latest/agent:zaki-bot:user:1:main**:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "  type=summary_latest\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "  focus: shipping readiness\n") != null);

    const got = (try memory.get(std.testing.allocator, key)).?;
    defer got.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(content, got.content);
}

test "markdown parses indented multiline structured entries" {
    const text =
        "# MEMORY.md - Long-Term Memory\n\n" ++
        "- **summary_latest/agent:zaki-bot:user:1:main**:\n" ++
        "  type=summary_latest\n" ++
        "  session=agent:zaki-bot:user:1:main\n" ++
        "  focus: shipping readiness\n" ++
        "  next:\n" ++
        "  - ship\n";

    const entries = try MarkdownMemory.parseEntries(text, "MEMORY", .core, std.testing.allocator);
    defer {
        for (entries) |*entry| entry.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("summary_latest/agent:zaki-bot:user:1:main", entries[0].key);
    try std.testing.expectEqualStrings(
        "type=summary_latest\nsession=agent:zaki-bot:user:1:main\nfocus: shipping readiness\nnext:\n- ship",
        entries[0].content,
    );
}

test "markdown tombstones suppress mutable keys from reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const memory = mem.memory();

    try memory.store("user_name", "Nova", .core, null);
    try mem.appendTombstone("user_name", std.testing.allocator);

    try std.testing.expect((try memory.get(std.testing.allocator, "user_name")) == null);
    const listed = try memory.list(std.testing.allocator, null, null);
    defer root.freeEntries(std.testing.allocator, listed);
    for (listed) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.key, "user_name"));
    }
}

test "markdown store removes tombstone for mutable key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const memory = mem.memory();

    try mem.appendTombstone("user_name", std.testing.allocator);
    try memory.store("user_name", "Nova", .core, null);

    const entry = (try memory.get(std.testing.allocator, "user_name")) orelse return error.TestUnexpectedResult;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Nova", entry.content);

    const tombstoned = try mem.readTombstonedKeys(std.testing.allocator);
    defer {
        for (tombstoned) |key| std.testing.allocator.free(key);
        std.testing.allocator.free(tombstoned);
    }
    try std.testing.expectEqual(@as(usize, 0), tombstoned.len);
}
