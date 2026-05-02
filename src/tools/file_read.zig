const std = @import("std");
const root = @import("root.zig");
const process_util = @import("process_util.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const isPathSafe = @import("path_security.zig").isPathSafe;
const isResolvedPathAllowed = @import("path_security.zig").isResolvedPathAllowed;

/// Default maximum file size to read (10MB).
const DEFAULT_MAX_FILE_SIZE: u64 = 10 * 1024 * 1024;

const BinarySignature = struct { magic: []const u8, type_name: []const u8 };

const BINARY_SIGNATURES: []const BinarySignature = &.{
    .{ .magic = "\x89PNG", .type_name = "PNG image" },
    .{ .magic = "\xFF\xD8\xFF", .type_name = "JPEG image" },
    .{ .magic = "GIF87a", .type_name = "GIF image" },
    .{ .magic = "GIF89a", .type_name = "GIF image" },
    .{ .magic = "%PDF", .type_name = "PDF document" },
    .{ .magic = "PK\x03\x04", .type_name = "ZIP archive" },
    .{ .magic = "Rar!", .type_name = "RAR archive" },
    .{ .magic = "7z\xBC\xAF\x27\x1C", .type_name = "7z archive" },
    // V1.7-cherrypick side-effect fix (SE-WIP-01): "MZ" was the 2-byte
    // DOS-header signature for Windows .exe / .dll files, but it false-
    // positives on any text file beginning with "MZ" (e.g. a markdown
    // document starting "MZ Industries quarterly report"). Real PE binaries
    // are still detected via the null-byte fallback in isBinaryContent
    // (lines ~62-64) — DOS-header padding contains zero bytes within the
    // first 8KB scan window. Removing the MZ row is safe: every other
    // signature in this table is ≥3 bytes or contains non-ASCII.
    .{ .magic = "\x7FELF", .type_name = "Linux executable" },
};

const EXTENSION_TYPES: []const struct { []const u8, []const u8 } = &.{
    .{ ".png", "PNG image" },     .{ ".jpg", "JPEG image" },
    .{ ".jpeg", "JPEG image" },   .{ ".gif", "GIF image" },
    .{ ".webp", "WebP image" },   .{ ".avif", "AVIF image" },
    .{ ".heic", "HEIC image" },   .{ ".heif", "HEIF image" },
    .{ ".pdf", "PDF document" },  .{ ".zip", "ZIP archive" },
    .{ ".mp4", "MP4 video" },     .{ ".mov", "QuickTime video" },
    .{ ".mp3", "MP3 audio" },     .{ ".m4a", "M4A audio" },
    .{ ".wav", "WAV audio" },     .{ ".exe", "Windows executable" },
    .{ ".dll", "Windows DLL" },   .{ ".so", "Linux shared library" },
    .{ ".dylib", "macOS shared library" },
};

fn isWebP(data: []const u8) bool {
    return data.len >= 12 and
        std.mem.eql(u8, data[0..4], "RIFF") and
        std.mem.eql(u8, data[8..12], "WEBP");
}

fn hasIsoBmffHeader(data: []const u8) bool {
    return data.len >= 8 and std.mem.eql(u8, data[4..8], "ftyp");
}

/// Returns true if `data` looks like binary content (magic bytes or null bytes).
pub fn isBinaryContent(data: []const u8) bool {
    if (data.len == 0) return false;
    for (BINARY_SIGNATURES) |sig| {
        if (std.mem.startsWith(u8, data, sig.magic)) return true;
    }
    if (isWebP(data)) return true;
    if (hasIsoBmffHeader(data)) return true;
    const check_len = @min(data.len, 8192);
    for (data[0..check_len]) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

/// Returns a human-readable type label for `data` (e.g. "PNG image").
pub fn getBinaryFileType(data: []const u8, path: []const u8) []const u8 {
    for (BINARY_SIGNATURES) |sig| {
        if (std.mem.startsWith(u8, data, sig.magic)) return sig.type_name;
    }
    // V1.7-cherrypick fix (WR-WIP-03): lowercase the extension before
    // comparison so `Photo.JPG` and `image.PDF` get the right human label.
    // The magic-byte detection above already catches the common formats; this
    // is just for files whose extension is known but whose magic isn't (e.g.
    // shared libraries, executables).
    const ext_raw = std.fs.path.extension(path);
    var ext_buf: [16]u8 = undefined;
    const ext = if (ext_raw.len <= ext_buf.len) blk: {
        for (ext_raw, 0..) |c, i| ext_buf[i] = std.ascii.toLower(c);
        break :blk ext_buf[0..ext_raw.len];
    } else ext_raw;
    for (EXTENSION_TYPES) |entry| {
        if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    }
    if (isWebP(data)) return "WebP image";
    if (hasIsoBmffHeader(data)) return "ISO media container";
    return "binary file";
}

/// Maximum output bytes from extractor subprocesses (8 MB of extracted text is
/// plenty — a 100-page dense document is typically under 500 KB of text).
const DOC_EXTRACTION_MAX_OUTPUT: u64 = 8 * 1024 * 1024;

fn endsWithCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const tail = haystack[haystack.len - needle.len ..];
    for (tail, 0..) |c, i| {
        const a = std.ascii.toLower(c);
        const b = std.ascii.toLower(needle[i]);
        if (a != b) return false;
    }
    return true;
}

/// Check if a resolved file path has an extension from a list (case-insensitive).
fn hasDocExtension(path: []const u8, exts: []const []const u8) bool {
    for (exts) |ext| {
        if (endsWithCaseInsensitive(path, ext)) return true;
    }
    return false;
}

/// Extensions handled by pandoc. Pandoc converts these to plain text via
/// `pandoc <path> -t plain`. Requires pandoc binary in the container image.
const PANDOC_EXTENSIONS = [_][]const u8{
    ".docx", ".doc",   ".odt", ".rtf",
    ".epub", ".pptx",  ".ppt",
    ".html", ".htm",
};

/// Extensions handled by xlsx2csv / libreoffice for spreadsheets. Pandoc's
/// xlsx support is limited; we shell to libreoffice --headless which handles
/// xlsx, xls, ods, csv round-trip.
const SPREADSHEET_EXTENSIONS = [_][]const u8{
    ".xlsx", ".xls", ".ods",
};

/// Read file contents with workspace path scoping.
pub const FileReadTool = struct {
    workspace_dir: []const u8,
    allowed_paths: []const []const u8 = &.{},
    max_file_size: u64 = DEFAULT_MAX_FILE_SIZE,

    pub const tool_name = "file_read";
    pub const tool_description = "Read the contents of a file in the workspace";
    pub const tool_params =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Relative path to the file within the workspace"}},"required":["path"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *FileReadTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *FileReadTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const path = root.getString(args, "path") orelse
            return ToolResult.fail("Missing 'path' parameter");

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

        // Resolve to catch symlink escapes
        const resolved = std.fs.cwd().realpathAlloc(allocator, full_path) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to resolve file path: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer allocator.free(resolved);

        // Validate against workspace + allowed_paths + system blocklist
        const ws_resolved: ?[]const u8 = std.fs.cwd().realpathAlloc(allocator, self.workspace_dir) catch null;
        defer if (ws_resolved) |wr| allocator.free(wr);

        if (!isResolvedPathAllowed(allocator, resolved, ws_resolved orelse "", self.allowed_paths)) {
            return ToolResult.fail("Path is outside allowed areas");
        }

        // ── Document extraction branches ─────────────────────────────────
        // Binary document formats go through specialized extractors that
        // produce plain text for the agent. Text files fall through to the
        // raw-read path below.
        //
        // Required container packages (install in Dockerfile):
        //   poppler-utils  → pdftotext
        //   pandoc         → docx/doc/odt/rtf/epub/pptx/ppt/html
        //   libreoffice    → xlsx/xls/ods (converted to CSV)

        // PDF: pdftotext -layout -enc UTF-8
        if (endsWithCaseInsensitive(resolved, ".pdf")) {
            return runDocExtractor(allocator, &.{
                "pdftotext", "-layout", "-enc", "UTF-8", resolved, "-",
            }, "pdftotext", "poppler-utils");
        }

        // Office docs, RTF, ePub, HTML → pandoc plain text
        if (hasDocExtension(resolved, &PANDOC_EXTENSIONS)) {
            return runDocExtractor(allocator, &.{
                "pandoc", resolved, "-t", "plain", "--wrap=preserve",
            }, "pandoc", "pandoc");
        }

        // Spreadsheets → libreoffice headless CSV conversion. We convert to
        // CSV in /tmp then read it back. This handles xlsx/xls/ods uniformly.
        if (hasDocExtension(resolved, &SPREADSHEET_EXTENSIONS)) {
            return extractSpreadsheet(allocator, resolved);
        }

        // Check file size
        const file = std.fs.openFileAbsolute(resolved, .{}) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to open file: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size > self.max_file_size) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "File too large: {} bytes (limit: {} bytes)",
                .{ stat.size, self.max_file_size },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        // Read contents
        const contents = file.readToEndAlloc(allocator, self.max_file_size) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to read file: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        return ToolResult{ .success = true, .output = contents };
    }
};

/// Run a document extractor subprocess and build a ToolResult from its output.
/// Stderr is freed; stdout becomes the tool output (or error_msg on failure).
/// `tool_name` is used in error messages. `pkg_hint` is the apt/brew package
/// name to suggest if the binary is missing.
fn runDocExtractor(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    tool_name: []const u8,
    pkg_hint: []const u8,
) !ToolResult {
    const result = process_util.run(allocator, argv, .{ .max_output_bytes = DOC_EXTRACTION_MAX_OUTPUT }) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Document extraction failed ({s}): {s}. Is {s} installed in the container?",
            .{ tool_name, @errorName(err), pkg_hint },
        );
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };
    defer allocator.free(result.stderr);

    if (!result.success) {
        defer allocator.free(result.stdout);
        const msg = try std.fmt.allocPrint(
            allocator,
            "{s} exit={?d} stderr={s}",
            .{ tool_name, result.exit_code, result.stderr },
        );
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }

    if (result.stdout.len == 0) {
        allocator.free(result.stdout);
        const empty_note = try allocator.dupe(
            u8,
            "[Document contains no extractable text — may be a scanned image or empty file]",
        );
        return ToolResult{ .success = true, .output = empty_note };
    }

    return ToolResult{ .success = true, .output = result.stdout };
}

/// Extract a spreadsheet (xlsx/xls/ods) to CSV via libreoffice headless mode.
/// libreoffice writes {basename}.csv next to the output directory we pass in.
/// We use /tmp with a unique suffix to avoid collisions, then read the CSV back.
fn extractSpreadsheet(allocator: std.mem.Allocator, resolved_path: []const u8) !ToolResult {
    // Build a unique output dir in /tmp
    const ts = std.time.milliTimestamp();
    var rand_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    const rand_suffix: u32 = std.mem.readInt(u32, &rand_bytes, .little);
    const out_dir = try std.fmt.allocPrint(allocator, "/tmp/nullalis_xlsx_{d}_{x}", .{ ts, rand_suffix });
    defer allocator.free(out_dir);
    std.fs.makeDirAbsolute(out_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return ToolResult.fail("Failed to create spreadsheet extraction dir"),
    };
    defer std.fs.deleteTreeAbsolute(out_dir) catch {};

    const result = process_util.run(allocator, &.{
        "libreoffice", "--headless", "--convert-to", "csv", "--outdir", out_dir, resolved_path,
    }, .{ .max_output_bytes = DOC_EXTRACTION_MAX_OUTPUT }) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Spreadsheet extraction failed: {s}. Is libreoffice installed in the container?",
            .{@errorName(err)},
        );
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!result.success) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "libreoffice exit={?d} stderr={s}",
            .{ result.exit_code, result.stderr },
        );
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }

    // Find the CSV output: {out_dir}/{basename-without-ext}.csv
    const base = std.fs.path.basename(resolved_path);
    const dot_idx = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    const csv_path = try std.fmt.allocPrint(allocator, "{s}/{s}.csv", .{ out_dir, base[0..dot_idx] });
    defer allocator.free(csv_path);

    const csv_file = std.fs.openFileAbsolute(csv_path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "libreoffice completed but CSV not found at {s}: {s}",
            .{ csv_path, @errorName(err) },
        );
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };
    defer csv_file.close();
    const csv_bytes = csv_file.readToEndAlloc(allocator, DOC_EXTRACTION_MAX_OUTPUT) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to read extracted CSV: {s}", .{@errorName(err)});
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };

    if (csv_bytes.len == 0) {
        allocator.free(csv_bytes);
        const empty_note = try allocator.dupe(u8, "[Spreadsheet is empty]");
        return ToolResult{ .success = true, .output = empty_note };
    }

    return ToolResult{ .success = true, .output = csv_bytes };
}

// ── Tests ───────────────────────────────────────────────────────────

test "file_read tool name" {
    var ft = FileReadTool{ .workspace_dir = "/tmp" };
    const t = ft.tool();
    try std.testing.expectEqualStrings("file_read", t.name());
}

test "file_read tool schema has path" {
    var ft = FileReadTool{ .workspace_dir = "/tmp" };
    const t = ft.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "path") != null);
}

test "file_read reads existing file" {
    // Create temp dir and file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "test.txt", .data = "hello world" });

    // Get the real path of the tmp dir
    const ws_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws_path);

    var ft = FileReadTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"test.txt\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("hello world", result.output);
}

test "file_read nonexistent file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const ws_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws_path);

    var ft = FileReadTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"nope.txt\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "file_read blocks path traversal" {
    var ft = FileReadTool{ .workspace_dir = "/tmp/workspace" };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"../../../etc/passwd\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // error_msg is a static string from ToolResult.fail(), don't free it
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not allowed") != null);
}

test "file_read blocks absolute path" {
    var ft = FileReadTool{ .workspace_dir = "/tmp/workspace" };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"/etc/passwd\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // error_msg is a static string from ToolResult.fail(), don't free it
    try std.testing.expect(!result.success);
}

test "file_read missing path param" {
    var ft = FileReadTool{ .workspace_dir = "/tmp" };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // error_msg is a static string from ToolResult.fail(), don't free it
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
}

test "file_read nested path" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("sub/dir");
    try tmp_dir.dir.writeFile(.{ .sub_path = "sub/dir/deep.txt", .data = "deep content" });

    const ws_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws_path);

    var ft = FileReadTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"sub/dir/deep.txt\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("deep content", result.output);
}

test "file_read empty file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "empty.txt", .data = "" });

    const ws_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws_path);

    var ft = FileReadTool{ .workspace_dir = ws_path };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"empty.txt\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("", result.output);
}

test "isPathSafe blocks null bytes" {
    try std.testing.expect(!isPathSafe("file\x00.txt"));
}

test "isPathSafe allows relative" {
    try std.testing.expect(isPathSafe("file.txt"));
    try std.testing.expect(isPathSafe("src/main.zig"));
}

test "file_read absolute path without allowed_paths is rejected" {
    var ft = FileReadTool{ .workspace_dir = "/tmp" };
    const t = ft.tool();
    const parsed = try root.parseTestArgs("{\"path\": \"/tmp/foo.txt\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Absolute paths not allowed") != null);
}

test "file_read absolute path with allowed_paths works" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "hello.txt", .data = "allowed content" });

    const ws_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws_path);
    const abs_file = try std.fs.path.join(std.testing.allocator, &.{ ws_path, "hello.txt" });
    defer std.testing.allocator.free(abs_file);

    // JSON-escape backslashes in the path (needed on Windows where paths use \)
    var escaped_buf: [1024]u8 = undefined;
    var esc_len: usize = 0;
    for (abs_file) |c| {
        if (c == '\\') {
            escaped_buf[esc_len] = '\\';
            esc_len += 1;
        }
        escaped_buf[esc_len] = c;
        esc_len += 1;
    }

    var args_buf: [2048]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"path\": \"{s}\"}}", .{escaped_buf[0..esc_len]});
    const parsed = try root.parseTestArgs(args);
    defer parsed.deinit();

    var ft = FileReadTool{ .workspace_dir = "/nonexistent", .allowed_paths = &.{ws_path} };
    const result = try ft.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |e| std.testing.allocator.free(e);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("allowed content", result.output);
}
