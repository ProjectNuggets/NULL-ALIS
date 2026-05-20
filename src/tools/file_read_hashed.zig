const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const isPathSafe = @import("path_security.zig").isPathSafe;
const isResolvedPathAllowed = @import("path_security.zig").isResolvedPathAllowed;
const getBinaryFileType = @import("file_read.zig").getBinaryFileType;
const isBinaryContent = @import("file_read.zig").isBinaryContent;

/// Default maximum file size (10 MB).
const DEFAULT_MAX_FILE_SIZE: u64 = 10 * 1024 * 1024;

/// Generate a 3-character hex hash for a line, incorporating parent context.
/// FNV-1a 32-bit, lower 12 bits → 3 hex digits.
pub fn generateLineHash(parent: []const u8, current: []const u8) [3]u8 {
    var hasher = std.hash.Fnv1a_32.init();
    hasher.update(std.mem.trim(u8, parent, " \t\r\n"));
    hasher.update("|");
    hasher.update(std.mem.trim(u8, current, " \t\r\n"));
    const truncated = hasher.final() & 0xFFF;
    var buf: [3]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>3}", .{truncated}) catch unreachable;
    return buf;
}

/// Read file contents with Hashline tagging: `L<n>:<hash>|<content>`.
/// Hash anchors let `file_edit_hashed` locate and replace lines even after
/// the file has shifted, without relying on exact line numbers.
pub const FileReadHashedTool = struct {
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},
    max_file_size: u64 = DEFAULT_MAX_FILE_SIZE,

    pub const tool_name = "file_read_hashed";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "file_read_hashed tool.",
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
        @import("lint.zig").lintToolDescription("file_read_hashed", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description =
        "Read file contents with Hashline tagging for precise, verifiable editing. " ++
        "Each line is prefixed with L<n>:<hash>| — pass the tag to file_edit_hashed " ++
        "to replace that line even if the file has shifted since the read.";
    pub const tool_params =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Relative path to the file within the workspace"}},"required":["path"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *FileReadHashedTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *FileReadHashedTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const path = root.getString(args, "path") orelse
            return ToolResult.fail("Missing 'path' parameter");

        const full_path = if (std.fs.path.isAbsolute(path)) blk: {
            if (self.allowed_paths.len == 0)
                return ToolResult.fail("Absolute paths not allowed (no allowed_paths configured)");
            if (std.mem.indexOfScalar(u8, path, 0) != null)
                return ToolResult.fail("Path contains null bytes");
            break :blk try allocator.dupe(u8, path);
        } else blk: {
            if (!isPathSafe(path))
                return ToolResult.fail("Path not allowed: contains traversal or absolute path");
            break :blk try std.fs.path.join(allocator, &.{ self.workspace_dir, path });
        };
        defer allocator.free(full_path);

        const resolved = std.fs.cwd().realpathAlloc(allocator, full_path) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to resolve path: {} ({s})", .{ err, path });
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer allocator.free(resolved);

        const ws_resolved: ?[]const u8 = std.fs.cwd().realpathAlloc(allocator, self.workspace_dir) catch null;
        defer if (ws_resolved) |wr| allocator.free(wr);

        if (!isResolvedPathAllowed(allocator, resolved, ws_resolved orelse "", self.allowed_paths))
            return ToolResult.fail("Path is outside allowed areas");

        const file = std.fs.openFileAbsolute(resolved, .{}) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to open file: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer file.close();

        const stat = try file.stat();
        const max_usize: u64 = @intCast(std.math.maxInt(usize));
        const read_limit: usize = @intCast(@min(self.max_file_size, max_usize));
        if (stat.size > self.max_file_size) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "File too large: {d} bytes (limit: {d} bytes)",
                .{ stat.size, self.max_file_size },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        const contents = file.readToEndAlloc(allocator, read_limit) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to read file: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        errdefer allocator.free(contents);

        if (isBinaryContent(contents)) {
            const file_type = getBinaryFileType(contents, path);
            const msg = try std.fmt.allocPrint(
                allocator,
                "[Binary file detected: {s}, size: {d} bytes. Use [IMAGE:path] marker for images.]",
                .{ file_type, contents.len },
            );
            allocator.free(contents);
            return ToolResult{ .success = true, .output = msg };
        }
        defer allocator.free(contents);

        var output: std.ArrayListUnmanaged(u8) = .empty;
        errdefer output.deinit(allocator);

        var line_it = std.mem.splitScalar(u8, contents, '\n');
        var line_num: usize = 1;
        var last_line: []const u8 = "";
        while (line_it.next()) |line| {
            const hash = generateLineHash(last_line, line);
            try output.writer(allocator).print("L{d}:{s}|{s}\n", .{ line_num, hash, line });
            last_line = line;
            line_num += 1;
        }

        return ToolResult{ .success = true, .output = try output.toOwnedSlice(allocator) };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "generateLineHash is context-sensitive" {
    const h1 = generateLineHash("parent1", "child");
    const h2 = generateLineHash("parent2", "child");
    const h3 = generateLineHash("parent1", "child");
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
    try std.testing.expectEqualStrings(&h1, &h3);
}

test "generateLineHash produces 3-character hex output" {
    const h = generateLineHash("", "line");
    try std.testing.expectEqual(@as(usize, 3), h.len);
    for (h) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "file_read_hashed tags lines with L<n>:<hash>|<content>" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = "const x = 1;\nconst y = 2;" });

    const ws = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws);

    var ft = FileReadHashedTool{ .workspace_dir = ws };
    const parsed = try root.parseTestArgs("{\"path\": \"test.zig\"}");
    defer parsed.deinit();

    const result = try ft.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.startsWith(u8, result.output, "L1:"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "|const x = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "L2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "|const y = 2;") != null);
}

test "file_read_hashed detects binary PNG" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "img.png", .data = "\x89PNG\r\n\x1a\nrest" });

    const ws = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws);

    var ft = FileReadHashedTool{ .workspace_dir = ws };
    const parsed = try root.parseTestArgs("{\"path\": \"img.png\"}");
    defer parsed.deinit();

    const result = try ft.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Binary file detected") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PNG image") != null);
}

test "file_read_hashed rejects traversal path" {
    var ft = FileReadHashedTool{ .workspace_dir = "/tmp/ws" };
    const parsed = try root.parseTestArgs("{\"path\": \"../../etc/passwd\"}");
    defer parsed.deinit();
    const result = try ft.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not allowed") != null);
}

test "file_read_hashed rejects absolute path without allowed_paths" {
    var ft = FileReadHashedTool{ .workspace_dir = "/tmp" };
    const parsed = try root.parseTestArgs("{\"path\": \"/etc/passwd\"}");
    defer parsed.deinit();
    const result = try ft.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Absolute paths not allowed") != null);
}

test "file_read_hashed missing path param" {
    var ft = FileReadHashedTool{ .workspace_dir = "/tmp" };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try ft.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "file_read_hashed hash is stable across reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "stable.txt", .data = "alpha\nbeta\ngamma" });

    const ws = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws);

    var ft = FileReadHashedTool{ .workspace_dir = ws };
    const parsed = try root.parseTestArgs("{\"path\": \"stable.txt\"}");
    defer parsed.deinit();

    const r1 = try ft.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(r1.output);
    const r2 = try ft.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(r2.output);

    try std.testing.expectEqualStrings(r1.output, r2.output);
}
