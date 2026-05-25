//! Provider-side file upload (Files API) for large multimodal inputs.
//!
//! The OpenAI-compat chat-completions surface caps request bodies around
//! ~100 MB, and base64 inflates the payload ~33%. Real-world videos quickly
//! cross that line. Providers that natively understand video (Moonshot/Kimi,
//! Gemini, OpenAI) expose a separate Files API: upload the raw bytes once,
//! reference the returned `file_id` from the chat request.
//!
//! This module wires the **Moonshot/Kimi** path for v1 — the default provider
//! for nullALIS. Other providers return `error.NotImplemented` (Gemini's File
//! API uses its own `gs://` scheme + `fileData` block in the gemini.zig
//! request builder; OpenAI's Files API uses a `file_id` reference with a
//! distinct `file` content-part type — both can be wired later without
//! disturbing this surface).
//!
//! API contract (verified 2026-05-25 against platform.kimi.ai docs — the
//! `platform.moonshot.ai` host 301-redirects to it):
//!
//! - `POST https://api.moonshot.ai/v1/files` (multipart/form-data)
//!   - `file`: binary file bytes
//!   - `purpose`: `"video"` (or `"image"`, `"file-extract"`, `"batch"`)
//!   - `Authorization: Bearer $MOONSHOT_API_KEY`
//! - Response: `{"id":"<file_id>","object":"file","bytes":...,"created_at":...,
//!   "filename":"...","purpose":"video","status":"ready","status_details":null}`
//! - Caps: 100 MB per file, 1,000 files per user, 10 GB total per user.
//! - Reference shape in chat completions:
//!   `{"type":"video_url","video_url":{"url":"ms://<file_id>"}}`.
//!
//! TODO: verify against live Moonshot API once a key is provisioned for the
//! upload-purpose path. The shape above is the documented contract; the live
//! call has not been smoke-probed from this codebase yet.

const std = @import("std");
const json_util = @import("../json_util.zig");
const platform = @import("../platform.zig");

const log = std.log.scoped(.provider_file_upload);

pub const Error = error{
    NotImplemented,
    BoundaryGenerationFailed,
    FileReadFailed,
    TempFileFailed,
    UploadFailed,
    InvalidResponse,
    ApiError,
    OutOfMemory,
};

/// Providers that have a wired file-upload path. Extend this enum as more
/// providers' Files APIs are wired; routing decisions live in
/// `multimodal.zig` (which calls into here via a callback closure).
pub const ProviderKind = enum {
    moonshot,
    // gemini,  // TODO: wire Gemini File API (gs:// + fileData)
    // openai,  // TODO: wire OpenAI Files API (file_id reference)
};

/// Map a provider name string to a ProviderKind. Returns null when the
/// provider has no wired uploader (caller should fall back to inline path
/// or text-note). Mirrors the alias table in `providers/factory.zig`.
pub fn classifyForUpload(provider_name: []const u8) ?ProviderKind {
    // All names that resolve to `api.moonshot.ai` in `factory.zig`.
    if (std.mem.eql(u8, provider_name, "moonshot") or
        std.mem.eql(u8, provider_name, "kimi") or
        std.mem.eql(u8, provider_name, "moonshot-cn") or
        std.mem.eql(u8, provider_name, "kimi-cn") or
        std.mem.eql(u8, provider_name, "moonshot-intl") or
        std.mem.eql(u8, provider_name, "moonshot-global") or
        std.mem.eql(u8, provider_name, "kimi-intl") or
        std.mem.eql(u8, provider_name, "kimi-global"))
    {
        return .moonshot;
    }
    return null;
}

/// Allowed `purpose` values for Moonshot's Files API. We only use `video` from
/// this module today; the others are listed for forward compatibility.
pub const MoonshotPurpose = enum {
    video,
    image,
    file_extract,
    batch,

    pub fn toSlice(self: MoonshotPurpose) []const u8 {
        return switch (self) {
            .video => "video",
            .image => "image",
            .file_extract => "file-extract",
            .batch => "batch",
        };
    }
};

/// Format a Moonshot `file_id` as the `ms://` reference URL the chat
/// completions endpoint expects in `video_url.url`. Caller owns the slice.
pub fn formatMoonshotRef(allocator: std.mem.Allocator, file_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "ms://{s}", .{file_id});
}

/// Upload a local video file to Moonshot's Files API and return the
/// resulting `file_id` (caller owns the slice).
///
/// `base_url` is the provider's base (e.g. `https://api.moonshot.ai/v1`);
/// the endpoint is `<base_url>/files`. `file_path` must be a readable
/// absolute path — caller is responsible for sandbox + size validation
/// (see `multimodal.readLocalVideo`).
///
/// The body is streamed to a tempfile and POSTed via curl
/// (`--data-binary @<tempfile>`) so we never hold the full payload in RAM —
/// same pattern as `voice.zig`'s Whisper transcription path.
pub fn uploadMoonshotFile(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    file_path: []const u8,
    filename_hint: []const u8,
    purpose: MoonshotPurpose,
    proxy: ?[]const u8,
) Error![]u8 {
    const boundary = generateBoundary() catch return error.BoundaryGenerationFailed;

    // Tempfile for the multipart body (so we never hold both raw file +
    // body in RAM simultaneously for a 100 MB video).
    const tmp_dir = platform.getTempDir(allocator) catch return error.TempFileFailed;
    defer allocator.free(tmp_dir);
    var tmp_path_buf: [256]u8 = undefined;
    var tmp_fbs = std.io.fixedBufferStream(&tmp_path_buf);
    tmp_fbs.writer().print("{s}/nullalis_upload_{d}.bin", .{ tmp_dir, getPid() }) catch
        return error.TempFileFailed;
    const tmp_path_len = tmp_fbs.pos;
    tmp_path_buf[tmp_path_len] = 0;
    const tmp_path: [:0]const u8 = tmp_path_buf[0..tmp_path_len :0];

    writeMultipartToTempFile(tmp_path, file_path, filename_hint, &boundary, purpose) catch
        return error.FileReadFailed;
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Build endpoint URL: <base_url>/files
    const endpoint = std.fmt.allocPrint(allocator, "{s}/files", .{base_url}) catch
        return error.OutOfMemory;
    defer allocator.free(endpoint);

    // Build headers.
    var content_type_buf: [128]u8 = undefined;
    var ct_fbs = std.io.fixedBufferStream(&content_type_buf);
    ct_fbs.writer().print("Content-Type: multipart/form-data; boundary={s}", .{&boundary}) catch
        return error.BoundaryGenerationFailed;
    const content_type_hdr = ct_fbs.getWritten();

    const auth_hdr = std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key}) catch
        return error.OutOfMemory;
    defer allocator.free(auth_hdr);

    const resp = curlPostFromFile(
        allocator,
        endpoint,
        tmp_path,
        &.{ auth_hdr, content_type_hdr },
        proxy,
    ) catch |err| {
        log.warn("file upload failed: {s} (endpoint={s}, file={s})", .{ @errorName(err), endpoint, file_path });
        return error.UploadFailed;
    };
    defer allocator.free(resp);

    return parseFileIdFromResponse(allocator, resp) catch |err| {
        log.warn("could not parse file_id from upload response: {s} (body_len={d})", .{ @errorName(err), resp.len });
        return error.InvalidResponse;
    };
}

/// Parse the `id` field from the Moonshot upload response. Exposed for tests.
/// Returns `error.ApiError` if the response body contains an `"error"` key
/// (HTTP-200 with an embedded error object — Moonshot's pattern), else
/// `error.InvalidResponse` if the body isn't a JSON object with a string `id`.
pub fn parseFileIdFromResponse(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidResponse;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    if (parsed.value.object.get("error") != null) return error.ApiError;

    const id_val = parsed.value.object.get("id") orelse return error.InvalidResponse;
    if (id_val != .string) return error.InvalidResponse;
    if (id_val.string.len == 0) return error.InvalidResponse;

    return try allocator.dupe(u8, id_val.string);
}

/// Generate a random 32-character hex boundary string.
/// Public so the multipart unit tests can use a fixed-pattern boundary check.
fn generateBoundary() ![32]u8 {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var boundary: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (random_bytes, 0..) |b, i| {
        boundary[i * 2] = hex[b >> 4];
        boundary[i * 2 + 1] = hex[b & 0x0f];
    }
    return boundary;
}

fn getPid() u64 {
    if (@hasDecl(std.posix, "system") and @hasDecl(std.posix.system, "getpid")) {
        return @intCast(std.posix.system.getpid());
    }
    return 0;
}

/// Build the multipart/form-data body in-memory. Exposed (and used) by tests
/// so they don't have to spin up a temp file. The runtime path uses
/// `writeMultipartToTempFile` to stream straight to disk for memory reasons.
pub fn buildMultipartBody(
    allocator: std.mem.Allocator,
    boundary: []const u8,
    file_bytes: []const u8,
    filename: []const u8,
    purpose: MoonshotPurpose,
) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);

    // file part
    try body.appendSlice(allocator, "--");
    try body.appendSlice(allocator, boundary);
    try body.appendSlice(allocator, "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"");
    // sanitize filename — strip any \r \n " \\ that could escape the header.
    for (filename) |c| {
        switch (c) {
            '\r', '\n', '"', '\\' => try body.append(allocator, '_'),
            else => try body.append(allocator, c),
        }
    }
    try body.appendSlice(allocator, "\"\r\nContent-Type: application/octet-stream\r\n\r\n");
    try body.appendSlice(allocator, file_bytes);
    try body.appendSlice(allocator, "\r\n");

    // purpose part
    try body.appendSlice(allocator, "--");
    try body.appendSlice(allocator, boundary);
    try body.appendSlice(allocator, "\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\n");
    try body.appendSlice(allocator, purpose.toSlice());
    try body.appendSlice(allocator, "\r\n");

    // closing boundary
    try body.appendSlice(allocator, "--");
    try body.appendSlice(allocator, boundary);
    try body.appendSlice(allocator, "--\r\n");

    return body.toOwnedSlice(allocator);
}

/// Stream the multipart body straight to a tempfile so we never hold both
/// the raw file bytes + the assembled body in memory. Same pattern as
/// `voice.zig writeMultipartToTempFile`.
fn writeMultipartToTempFile(
    tmp_path: [:0]const u8,
    file_path: []const u8,
    filename: []const u8,
    boundary: []const u8,
    purpose: MoonshotPurpose,
) !void {
    const tmp_file = try std.fs.createFileAbsolute(tmp_path, .{});
    defer tmp_file.close();

    // file part header
    try tmp_file.writeAll("--");
    try tmp_file.writeAll(boundary);
    try tmp_file.writeAll("\r\nContent-Disposition: form-data; name=\"file\"; filename=\"");
    for (filename) |c| {
        const ch: [1]u8 = .{switch (c) {
            '\r', '\n', '"', '\\' => '_',
            else => c,
        }};
        try tmp_file.writeAll(&ch);
    }
    try tmp_file.writeAll("\"\r\nContent-Type: application/octet-stream\r\n\r\n");

    // Stream the raw file in
    {
        const in_file = try std.fs.openFileAbsolute(file_path, .{});
        defer in_file.close();
        var buf: [32768]u8 = undefined;
        while (true) {
            const n = try in_file.read(&buf);
            if (n == 0) break;
            try tmp_file.writeAll(buf[0..n]);
        }
    }
    try tmp_file.writeAll("\r\n");

    // purpose part
    try tmp_file.writeAll("--");
    try tmp_file.writeAll(boundary);
    try tmp_file.writeAll("\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\n");
    try tmp_file.writeAll(purpose.toSlice());
    try tmp_file.writeAll("\r\n");

    // closing
    try tmp_file.writeAll("--");
    try tmp_file.writeAll(boundary);
    try tmp_file.writeAll("--\r\n");
}

/// curl POST with the body read from a file on disk.
/// Mirrors `voice.curlPostFromFile` but adds an optional `--proxy` arg so
/// gateway proxy config flows through.
fn curlPostFromFile(
    allocator: std.mem.Allocator,
    url: []const u8,
    file_path: [:0]const u8,
    headers: []const []const u8,
    proxy: ?[]const u8,
) ![]u8 {
    var data_arg_buf: [300]u8 = undefined;
    var data_fbs = std.io.fixedBufferStream(&data_arg_buf);
    try data_fbs.writer().print("@{s}", .{file_path});
    const data_arg = data_fbs.getWritten();

    var argv_buf: [40][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-s";
    argc += 1;
    argv_buf[argc] = "-X";
    argc += 1;
    argv_buf[argc] = "POST";
    argc += 1;

    if (proxy) |p| {
        argv_buf[argc] = "--proxy";
        argc += 1;
        argv_buf[argc] = p;
        argc += 1;
    }

    for (headers) |hdr| {
        if (argc + 2 > argv_buf.len) break;
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = hdr;
        argc += 1;
    }

    argv_buf[argc] = "--data-binary";
    argc += 1;
    argv_buf[argc] = data_arg;
    argc += 1;
    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    // Upload responses are small JSON objects — 1 MB cap is plenty.
    const stdout = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch return error.CurlReadError;
    errdefer allocator.free(stdout);

    const term = child.wait() catch return error.CurlWaitError;
    switch (term) {
        .Exited => |code| if (code != 0) {
            allocator.free(stdout);
            return error.CurlFailed;
        },
        else => {
            allocator.free(stdout);
            return error.CurlFailed;
        },
    }

    return stdout;
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "classifyForUpload recognizes all Moonshot/Kimi aliases" {
    try std.testing.expectEqual(ProviderKind.moonshot, classifyForUpload("moonshot").?);
    try std.testing.expectEqual(ProviderKind.moonshot, classifyForUpload("kimi").?);
    try std.testing.expectEqual(ProviderKind.moonshot, classifyForUpload("moonshot-cn").?);
    try std.testing.expectEqual(ProviderKind.moonshot, classifyForUpload("kimi-cn").?);
    try std.testing.expectEqual(ProviderKind.moonshot, classifyForUpload("moonshot-intl").?);
    try std.testing.expectEqual(ProviderKind.moonshot, classifyForUpload("moonshot-global").?);
    try std.testing.expectEqual(ProviderKind.moonshot, classifyForUpload("kimi-intl").?);
    try std.testing.expectEqual(ProviderKind.moonshot, classifyForUpload("kimi-global").?);
}

test "classifyForUpload returns null for non-Moonshot providers" {
    try std.testing.expect(classifyForUpload("openai") == null);
    try std.testing.expect(classifyForUpload("anthropic") == null);
    try std.testing.expect(classifyForUpload("gemini") == null);
    try std.testing.expect(classifyForUpload("groq") == null);
    try std.testing.expect(classifyForUpload("") == null);
}

test "formatMoonshotRef builds ms:// URL" {
    const allocator = std.testing.allocator;
    const url = try formatMoonshotRef(allocator, "file-abc123");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("ms://file-abc123", url);
}

test "buildMultipartBody includes file, purpose, and closing boundary" {
    const allocator = std.testing.allocator;
    const boundary = "fixedboundary0123456789abcdef00";
    const body = try buildMultipartBody(
        allocator,
        boundary,
        "rawbytes",
        "clip.mp4",
        .video,
    );
    defer allocator.free(body);

    // file part
    try std.testing.expect(std.mem.indexOf(u8, body, "--fixedboundary0123456789abcdef00\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Disposition: form-data; name=\"file\"; filename=\"clip.mp4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: application/octet-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "rawbytes") != null);
    // purpose part
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Disposition: form-data; name=\"purpose\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\r\n\r\nvideo\r\n") != null);
    // closing boundary
    try std.testing.expect(std.mem.endsWith(u8, body, "--fixedboundary0123456789abcdef00--\r\n"));
}

test "buildMultipartBody sanitizes header-breaking chars in filename" {
    const allocator = std.testing.allocator;
    const boundary = "boundary00000000000000000000000000";
    // Filename contains chars that would let an attacker inject extra headers.
    const body = try buildMultipartBody(
        allocator,
        boundary,
        "x",
        "ev\r\nil\"name\\.mp4",
        .video,
    );
    defer allocator.free(body);
    // The sanitizer replaces \r \n " \\ with '_'; ensure none of those
    // chars survive inside the filename slot.
    const fname_start = std.mem.indexOf(u8, body, "filename=\"").? + "filename=\"".len;
    const fname_end = std.mem.indexOfPos(u8, body, fname_start, "\"").?;
    const fname = body[fname_start..fname_end];
    try std.testing.expectEqualStrings("ev__il_name_.mp4", fname);
}

test "parseFileIdFromResponse extracts id from happy-path JSON" {
    const allocator = std.testing.allocator;
    const body =
        \\{"id":"file-abc123","object":"file","bytes":12345,"created_at":1700000000,"filename":"clip.mp4","purpose":"video","status":"ready","status_details":null}
    ;
    const id = try parseFileIdFromResponse(allocator, body);
    defer allocator.free(id);
    try std.testing.expectEqualStrings("file-abc123", id);
}

test "parseFileIdFromResponse rejects empty id" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidResponse, parseFileIdFromResponse(allocator, "{\"id\":\"\"}"));
}

test "parseFileIdFromResponse surfaces API error object" {
    const allocator = std.testing.allocator;
    const body = "{\"error\":{\"message\":\"file too large\",\"type\":\"invalid_request_error\"}}";
    try std.testing.expectError(error.ApiError, parseFileIdFromResponse(allocator, body));
}

test "parseFileIdFromResponse rejects malformed JSON" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidResponse, parseFileIdFromResponse(allocator, "not json"));
    try std.testing.expectError(error.InvalidResponse, parseFileIdFromResponse(allocator, "[1,2,3]"));
    try std.testing.expectError(error.InvalidResponse, parseFileIdFromResponse(allocator, "{}"));
    try std.testing.expectError(error.InvalidResponse, parseFileIdFromResponse(allocator, "{\"id\":123}"));
}

// Suppress unused-import warning in release builds when json_util is only
// touched by helpers that aren't built into the dev profile.
comptime {
    _ = json_util;
}
