//! File Append Tool — append content to the end of a file within workspace.
//!
//! Creates the file if it doesn't exist. Uses workspace path scoping
//! and the same path safety checks as file_edit.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const isPathSafe = @import("path_security.zig").isPathSafe;
const isResolvedPathAllowed = @import("path_security.zig").isResolvedPathAllowed;

/// Default maximum file size to read before appending (10MB).
const DEFAULT_MAX_FILE_SIZE: usize = 10 * 1024 * 1024;
const UNAVAILABLE_WORKSPACE_SENTINEL = "\x00";

/// Append content to the end of a file with workspace path scoping.
pub const FileAppendTool = struct {
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},
    max_file_size: usize = DEFAULT_MAX_FILE_SIZE,

    pub const tool_name = "file_append";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Append content to the end of an existing file.",
        .use_when = &.{
            "Adding new content to the end of existing files",
            "Logging output to running transaction or session files",
            "Accumulating multi-step results in a single file",
        },
        .do_not_use_for = &.{
            "web_search — for external data queries",
            "memory_store — for persistent storage",
            "http_request — for specific API endpoints",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("file_append", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description = "Append content to the end of a file (creates the file if it doesn't exist)";
    pub const tool_params =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Relative path to the file within the workspace"},"content":{"type":"string","description":"Content to append to the file"}},"required":["path","content"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *FileAppendTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *FileAppendTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const path = root.getString(args, "path") orelse
            return ToolResult.fail("Missing 'path' parameter");

        const content = root.getString(args, "content") orelse
            return ToolResult.fail("Missing 'content' parameter");

        // Build full path — absolute or relative
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

        // Resolve workspace path (may fail if workspace doesn't exist yet)
        const ws_resolved: ?[]const u8 = std.fs.cwd().realpathAlloc(allocator, self.workspace_dir) catch null;
        defer if (ws_resolved) |wr| allocator.free(wr);
        const ws_str = ws_resolved orelse UNAVAILABLE_WORKSPACE_SENTINEL;

        const resolved_target: ?[]const u8 = std.fs.cwd().realpathAlloc(allocator, full_path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                const msg = try std.fmt.allocPrint(allocator, "Failed to resolve path: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
        };
        defer if (resolved_target) |rt| allocator.free(rt);

        const parent_to_check = std.fs.path.dirname(full_path) orelse full_path;
        const resolved_ancestor = resolveNearestExistingAncestor(allocator, parent_to_check) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to resolve path: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer allocator.free(resolved_ancestor);

        if (!isResolvedPathAllowed(allocator, resolved_ancestor, ws_str, self.allowed_paths)) {
            return ToolResult.fail("Path is outside allowed areas");
        }

        // Try to read existing content
        const existing = blk: {
            const resolved = resolved_target orelse
                break :blk @as(?[]const u8, null);

            if (!isResolvedPathAllowed(allocator, resolved, ws_str, self.allowed_paths)) {
                return ToolResult.fail("Path is outside allowed areas");
            }

            const file = std.fs.openFileAbsolute(resolved, .{}) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to open file: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            const data = file.readToEndAlloc(allocator, self.max_file_size) catch |err| {
                file.close();
                const msg = try std.fmt.allocPrint(allocator, "Failed to read file: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            file.close();
            break :blk @as(?[]const u8, data);
        };
        defer if (existing) |e| allocator.free(e);

        // Build new content
        const new_contents = if (existing) |e|
            try std.mem.concat(allocator, u8, &.{ e, content })
        else
            try allocator.dupe(u8, content);
        defer allocator.free(new_contents);

        const existing_is_symlink = if (resolved_target != null) blk: {
            if (comptime builtin.os.tag == .windows) break :blk false;
            break :blk isSymlinkPath(full_path) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to resolve path: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
        } else false;

        const write_path = if (existing_is_symlink)
            try allocator.dupe(u8, resolved_target.?)
        else
            try allocator.dupe(u8, full_path);
        defer allocator.free(write_path);

        const existing_mode: ?std.fs.File.Mode = blk: {
            const st = std.fs.cwd().statFile(write_path) catch |err| switch (err) {
                error.FileNotFound => break :blk null,
                else => {
                    const msg = try std.fmt.allocPrint(allocator, "Failed to stat file: {}", .{err});
                    return ToolResult{ .success = false, .output = "", .error_msg = msg };
                },
            };
            break :blk st.mode;
        };

        const parent = std.fs.path.dirname(write_path) orelse write_path;
        const basename = std.fs.path.basename(write_path);
        var parent_dir = if (std.fs.path.isAbsolute(parent))
            std.fs.openDirAbsolute(parent, .{}) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to open directory: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            }
        else
            std.fs.cwd().openDir(parent, .{}) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to open directory: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
        defer parent_dir.close();

        var tmp_name_buf: [128]u8 = undefined;
        var tmp_name_len: usize = 0;
        var tmp_file: ?std.fs.File = null;
        var attempt: usize = 0;
        while (attempt < 32) : (attempt += 1) {
            const tmp_name = std.fmt.bufPrint(
                &tmp_name_buf,
                ".nullalis-append-{d}-{d}.tmp",
                .{ std.time.nanoTimestamp(), attempt },
            ) catch unreachable;
            tmp_file = parent_dir.createFile(tmp_name, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => {
                    const msg = try std.fmt.allocPrint(allocator, "Failed to create file: {}", .{err});
                    return ToolResult{ .success = false, .output = "", .error_msg = msg };
                },
            };
            tmp_name_len = tmp_name.len;
            break;
        }
        if (tmp_file == null) {
            return ToolResult.fail("Failed to create temporary file");
        }

        var file_w = tmp_file.?;
        defer file_w.close();

        if (comptime std.fs.has_executable_bit) {
            if (existing_mode) |mode| {
                if (mode != 0) {
                    file_w.chmod(mode) catch |err| {
                        const msg = try std.fmt.allocPrint(allocator, "Failed to preserve file mode: {}", .{err});
                        return ToolResult{ .success = false, .output = "", .error_msg = msg };
                    };
                }
            }
        }

        var committed = false;
        defer if (!committed and tmp_name_len > 0) {
            parent_dir.deleteFile(tmp_name_buf[0..tmp_name_len]) catch {};
        };

        file_w.writeAll(new_contents) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to write file: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        parent_dir.rename(tmp_name_buf[0..tmp_name_len], basename) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to replace file: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        committed = true;

        // Verify newly created files are within allowed areas
        if (existing == null) {
            const new_resolved = std.fs.cwd().realpathAlloc(allocator, full_path) catch {
                std.fs.cwd().deleteFile(full_path) catch {};
                return ToolResult.fail("Failed to verify created file location");
            };
            defer allocator.free(new_resolved);
            if (!isResolvedPathAllowed(allocator, new_resolved, ws_str, self.allowed_paths)) {
                std.fs.cwd().deleteFile(full_path) catch {};
                return ToolResult.fail("Created file is outside allowed areas");
            }
        }

        const msg = try std.fmt.allocPrint(allocator, "Appended {d} bytes to {s}", .{ content.len, path });
        return ToolResult{ .success = true, .output = msg };
    }
};

fn resolveNearestExistingAncestor(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return err;
            if (std.mem.eql(u8, parent, path)) return err;
            return resolveNearestExistingAncestor(allocator, parent);
        },
        else => return err,
    };
}

fn isSymlinkPath(path: []const u8) !bool {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const entry_name = std.fs.path.basename(path);
    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.fs.openDirAbsolute(dir_path, .{})
    else
        try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = dir.readLink(entry_name, &link_buf) catch |err| switch (err) {
        error.NotLink => return false,
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "FileAppendTool name and description" {
    var fat = FileAppendTool{ .workspace_dir = "/tmp" };
    const t = fat.tool();
    try testing.expectEqualStrings("file_append", t.name());
    try testing.expect(t.description().len > 0);
    try testing.expect(t.parametersJson()[0] == '{');
}

test "FileAppendTool missing path" {
    var fat = FileAppendTool{ .workspace_dir = "/tmp" };
    const parsed = try root.parseTestArgs("{\"content\":\"hello\"}");
    defer parsed.deinit();
    const result = try fat.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Missing 'path' parameter", result.error_msg.?);
}

test "FileAppendTool missing content" {
    var fat = FileAppendTool{ .workspace_dir = "/tmp" };
    const parsed = try root.parseTestArgs("{\"path\":\"test.txt\"}");
    defer parsed.deinit();
    const result = try fat.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Missing 'content' parameter", result.error_msg.?);
}

test "FileAppendTool blocks path traversal" {
    var fat = FileAppendTool{ .workspace_dir = "/tmp/workspace" };
    const parsed = try root.parseTestArgs("{\"path\":\"../../etc/evil\",\"content\":\"x\"}");
    defer parsed.deinit();
    const result = try fat.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not allowed") != null);
}

test "FileAppendTool appends to existing file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "log.txt", .data = "line1" });

    const ws_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(ws_path);

    var fat = FileAppendTool{ .workspace_dir = ws_path };
    const parsed = try root.parseTestArgs("{\"path\":\"log.txt\",\"content\":\"line2\"}");
    defer parsed.deinit();
    const result = try fat.execute(testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) testing.allocator.free(result.output);
    defer if (result.error_msg) |e| testing.allocator.free(e);

    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "Appended") != null);

    const actual = try tmp_dir.dir.readFileAlloc(testing.allocator, "log.txt", 4096);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("line1line2", actual);
}

test "FileAppendTool creates new file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const ws_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(ws_path);

    var fat = FileAppendTool{ .workspace_dir = ws_path };
    const parsed = try root.parseTestArgs("{\"path\":\"new.txt\",\"content\":\"hello\"}");
    defer parsed.deinit();
    const result = try fat.execute(testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) testing.allocator.free(result.output);
    defer if (result.error_msg) |e| testing.allocator.free(e);

    try testing.expect(result.success);

    const actual = try tmp_dir.dir.readFileAlloc(testing.allocator, "new.txt", 4096);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("hello", actual);
}

test "FileAppendTool blocks parent symlink escape before creating file" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var ws_tmp = testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    var outside_tmp = testing.tmpDir(.{});
    defer outside_tmp.cleanup();

    const ws_path = try ws_tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(ws_path);
    const outside_path = try outside_tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(outside_path);

    try ws_tmp.dir.symLink(outside_path, "escape_dir", .{});

    var fat = FileAppendTool{ .workspace_dir = ws_path };
    const parsed = try root.parseTestArgs("{\"path\":\"escape_dir/pwned.txt\",\"content\":\"pwned\"}");
    defer parsed.deinit();
    const result = try fat.execute(testing.allocator, parsed.value.object);

    try testing.expect(!result.success);
    try testing.expect(std.mem.indexOf(u8, result.error_msg.?, "outside allowed areas") != null);
    try testing.expectError(error.FileNotFound, outside_tmp.dir.openFile("pwned.txt", .{}));
}

test "FileAppendTool does not mutate outside inode through hard link" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var ws_tmp = testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    var outside_tmp = testing.tmpDir(.{});
    defer outside_tmp.cleanup();

    const ws_path = try ws_tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(ws_path);
    const outside_path = try outside_tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(outside_path);

    try outside_tmp.dir.writeFile(.{ .sub_path = "outside.txt", .data = "SAFE" });
    const outside_file = try std.fs.path.join(testing.allocator, &.{ outside_path, "outside.txt" });
    defer testing.allocator.free(outside_file);
    const hardlink_path = try std.fs.path.join(testing.allocator, &.{ ws_path, "hl.txt" });
    defer testing.allocator.free(hardlink_path);

    try std.posix.link(outside_file, hardlink_path);

    var fat = FileAppendTool{ .workspace_dir = ws_path };
    const parsed = try root.parseTestArgs("{\"path\":\"hl.txt\",\"content\":\"!\"}");
    defer parsed.deinit();
    const result = try fat.execute(testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) testing.allocator.free(result.output);
    defer if (result.error_msg) |e| testing.allocator.free(e);
    try testing.expect(result.success);

    const workspace_actual = try ws_tmp.dir.readFileAlloc(testing.allocator, "hl.txt", 1024);
    defer testing.allocator.free(workspace_actual);
    try testing.expectEqualStrings("SAFE!", workspace_actual);

    const outside_actual = try outside_tmp.dir.readFileAlloc(testing.allocator, "outside.txt", 1024);
    defer testing.allocator.free(outside_actual);
    try testing.expectEqualStrings("SAFE", outside_actual);
}

test "FileAppendTool appends to empty file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "empty.txt", .data = "" });

    const ws_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(ws_path);

    var fat = FileAppendTool{ .workspace_dir = ws_path };
    const parsed = try root.parseTestArgs("{\"path\":\"empty.txt\",\"content\":\"data\"}");
    defer parsed.deinit();
    const result = try fat.execute(testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) testing.allocator.free(result.output);
    defer if (result.error_msg) |e| testing.allocator.free(e);

    try testing.expect(result.success);

    const actual = try tmp_dir.dir.readFileAlloc(testing.allocator, "empty.txt", 4096);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("data", actual);
}

test "FileAppendTool multiple appends" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "multi.txt", .data = "A" });

    const ws_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(ws_path);

    var fat = FileAppendTool{ .workspace_dir = ws_path };

    const p1 = try root.parseTestArgs("{\"path\":\"multi.txt\",\"content\":\"B\"}");
    defer p1.deinit();
    const r1 = try fat.execute(testing.allocator, p1.value.object);
    defer if (r1.output.len > 0) testing.allocator.free(r1.output);
    defer if (r1.error_msg) |e| testing.allocator.free(e);
    try testing.expect(r1.success);

    const p2 = try root.parseTestArgs("{\"path\":\"multi.txt\",\"content\":\"C\"}");
    defer p2.deinit();
    const r2 = try fat.execute(testing.allocator, p2.value.object);
    defer if (r2.output.len > 0) testing.allocator.free(r2.output);
    defer if (r2.error_msg) |e| testing.allocator.free(e);
    try testing.expect(r2.success);

    const actual = try tmp_dir.dir.readFileAlloc(testing.allocator, "multi.txt", 4096);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("ABC", actual);
}

test "FileAppendTool schema has required params" {
    var fat = FileAppendTool{ .workspace_dir = "/tmp" };
    const t = fat.tool();
    const schema = t.parametersJson();
    try testing.expect(std.mem.indexOf(u8, schema, "path") != null);
    try testing.expect(std.mem.indexOf(u8, schema, "content") != null);
}
