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
//! Live-verified against api.moonshot.ai on 2026-05-25 (Gate #1 of the
//! v1.14.24 verification pass) — see `docs/archive/2026-05-25/MOONSHOT_LIVE_PROBE.md`.
//! Confirmed:
//!   - POST /v1/files with `purpose=image` returns 200 + `{"id":"...","status":"ready"}`
//!   - Canonical purpose enum (per Moonshot's 400-response disclosure):
//!     `file-extract`, `batch`, `batch_output`, `lambda`, `image`, `video`
//!   - Response `id` field name matches `parseFileIdFromResponse`
//!   - `ms://<file_id>` URL form accepted in chat completion content parts
//!     against `kimi-k2.6` (default model; billed for the request)
//!   - `image_url` and `data:image/...;base64,...` inline path also works
//!
//! Not yet smoke-probed end-to-end:
//!   - A real video file upload + chat completion round-trip with
//!     `purpose=video`. The image path validates the SAME multipart
//!     contract + response shape + URL form, so video is high-confidence
//!     by symmetry, but `experimental_video_upload: false` stays default
//!     until a >1MB MP4 has been uploaded + referenced in a chat turn.

const std = @import("std");
const json_util = @import("../json_util.zig");
const platform = @import("../platform.zig");
const observability = @import("../observability.zig");

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
    // HIGH 2.A: emit `moonshot_video_upload_total{result}` on every
    // exit path. The defer reads `metric_result` set by the failure
    // sites (or `"ok"` on success). Bytes are emitted separately after
    // we resolve the source file's size (skipped on early-validation
    // failures where we never reached the file).
    var metric_result: []const u8 = "network_error";
    defer observability.recordMetricGlobal(.{
        .moonshot_video_upload_total = .{ .result = metric_result },
    });

    const boundary = generateBoundary() catch {
        metric_result = "boundary_failed";
        return error.BoundaryGenerationFailed;
    };

    // Tempfile for the multipart body (so we never hold both raw file +
    // body in RAM simultaneously for a 100 MB video).
    //
    // HIGH-2 (v1.14.23 review): the prior path `{tmp_dir}/nullalis_upload_{pid}.bin`
    // collided on concurrent in-process uploads (two threads/coroutines
    // truncating each other's body mid-stream) and was a predictable
    // symlink-race target in shared /tmp. We now mix in 96 bits of
    // cryptographic randomness AND create the file with O_EXCL so a
    // pre-existing path (collision OR attacker symlink) errors instead of
    // overwriting.
    const tmp_dir = platform.getTempDir(allocator) catch {
        metric_result = "tempfile_failed";
        return error.TempFileFailed;
    };
    defer allocator.free(tmp_dir);

    var tmp_path_buf: [512]u8 = undefined;
    const tmp_path = buildUploadTempPath(&tmp_path_buf, tmp_dir, getPid()) catch {
        metric_result = "tempfile_failed";
        return error.TempFileFailed;
    };

    // WARN-1 (v1.14.23 review): register the cleanup defer BEFORE the
    // write call so a partial-write fault (disk full mid-stream, source
    // file disappears, perm error after createFile succeeded) still
    // unlinks the tempfile. Previously the defer was registered after
    // the `catch return`, leaking the partial body on every failure.
    //
    // We create the file exclusively up front so the defer's unlink
    // targets a tempfile we own (mitigates symlink-overwrite races).
    {
        const tmp_file = std.fs.createFileAbsolute(tmp_path, .{ .exclusive = true }) catch {
            metric_result = "tempfile_failed";
            return error.TempFileFailed;
        };
        tmp_file.close();
    }
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    writeMultipartToTempFile(tmp_path, file_path, filename_hint, &boundary, purpose) catch {
        metric_result = "file_read_failed";
        return error.FileReadFailed;
    };

    // HIGH 2.A: emit the bytes histogram now that the multipart body
    // is on disk. This is the wire-bytes count (multipart envelope +
    // payload) — slightly larger than the raw source file but operators
    // care about the actual upload size for bandwidth attribution.
    if (std.fs.cwd().statFile(tmp_path)) |st| {
        observability.recordMetricGlobal(.{ .moonshot_video_upload_bytes = @intCast(st.size) });
    } else |_| {}

    // Build endpoint URL: <base_url>/files
    const endpoint = std.fmt.allocPrint(allocator, "{s}/files", .{base_url}) catch {
        metric_result = "oom";
        return error.OutOfMemory;
    };
    defer allocator.free(endpoint);

    // Build headers.
    var content_type_buf: [128]u8 = undefined;
    var ct_fbs = std.io.fixedBufferStream(&content_type_buf);
    ct_fbs.writer().print("Content-Type: multipart/form-data; boundary={s}", .{&boundary}) catch {
        metric_result = "boundary_failed";
        return error.BoundaryGenerationFailed;
    };
    const content_type_hdr = ct_fbs.getWritten();

    const auth_hdr = std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key}) catch {
        metric_result = "oom";
        return error.OutOfMemory;
    };
    defer allocator.free(auth_hdr);

    const resp = curlPostFromFile(
        allocator,
        endpoint,
        tmp_path,
        &.{ auth_hdr, content_type_hdr },
        proxy,
    ) catch |err| {
        log.warn("file upload failed: {s} (endpoint={s}, file={s})", .{ @errorName(err), endpoint, file_path });
        metric_result = "upload_failed";
        return error.UploadFailed;
    };
    defer allocator.free(resp);

    const file_id = parseFileIdFromResponse(allocator, resp) catch |err| {
        log.warn("could not parse file_id from upload response: {s} (body_len={d})", .{ @errorName(err), resp.len });
        metric_result = "invalid_response";
        return error.InvalidResponse;
    };
    metric_result = "ok";
    return file_id;
}

/// Parse the `id` field from the Moonshot upload response. Exposed for tests.
/// Returns `error.ApiError` if the response body contains a non-null `"error"`
/// value (HTTP-200 with an embedded error object — Moonshot's pattern), else
/// `error.InvalidResponse` if the body isn't a JSON object with a string `id`.
///
/// HIGH-1 (v1.14.23 review): we MUST check the error VALUE not just key
/// presence. Some providers return `{"id":"file-1","error":null}` on success
/// for symmetry — treating that as an error would silently degrade every
/// upload to the text-note fallback.
pub fn parseFileIdFromResponse(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidResponse;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    if (parsed.value.object.get("error")) |err_val| {
        if (err_val != .null) return error.ApiError;
    }

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

/// Build a per-call unique tempfile path in `tmp_dir`. The path embeds the
/// caller's PID for forensic correlation AND 96 bits of cryptographic
/// randomness so two concurrent in-process uploads (or any symlink-race
/// attempt against the predictable PID-only path) cannot collide.
///
/// `buf` must be large enough to hold `tmp_dir + "/nullalis_upload_<pid>_<24hex>.bin"
/// + NUL`. Returns `error.TempPathTooLong` if the buffer can't fit the
/// formatted path with its trailing NUL.
///
/// Exposed (pub) so tests can assert the uniqueness contract without
/// needing filesystem mocks.
pub fn buildUploadTempPath(
    buf: []u8,
    tmp_dir: []const u8,
    pid: u64,
) ![:0]const u8 {
    var rand_bytes: [12]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var rand_hex: [24]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (rand_bytes, 0..) |b, i| {
        rand_hex[i * 2] = hex_chars[b >> 4];
        rand_hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }

    var fbs = std.io.fixedBufferStream(buf);
    fbs.writer().print("{s}/nullalis_upload_{d}_{s}.bin", .{ tmp_dir, pid, &rand_hex }) catch
        return error.TempPathTooLong;
    const len = fbs.pos;
    if (len + 1 > buf.len) return error.TempPathTooLong;
    buf[len] = 0;
    return buf[0..len :0];
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
///
/// PRE-CONDITION: `tmp_path` already exists (created exclusively by the
/// caller, see `uploadMoonshotFile`). We open the existing inode rather
/// than re-create it so we don't race against the caller's defer-unlink
/// or against a concurrent symlink-overwrite attempt between the create
/// and the open.
fn writeMultipartToTempFile(
    tmp_path: [:0]const u8,
    file_path: []const u8,
    filename: []const u8,
    boundary: []const u8,
    purpose: MoonshotPurpose,
) !void {
    const tmp_file = try std.fs.openFileAbsolute(tmp_path, .{ .mode = .write_only });
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
    //
    // WARN-2 (v1.14.23 review): if the read fails (StreamTooLong, OOM,
    // IO error) we MUST still reap the spawned child or its process
    // descriptor stays a zombie until the gateway exits. Pre-fix the
    // bare `catch return` leaked the PID; under a flapping upload loop
    // this exhausts the process table.
    const stdout = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        _ = child.wait() catch {};
        log.warn("curl read failed; reaped child: {s}", .{@errorName(err)});
        return error.CurlReadError;
    };
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

// HIGH-1 (v1.14.23 review): success responses with `"error":null` for shape
// symmetry must NOT be misclassified as an API error. Pre-fix the parser
// checked key presence; the fix checks the error VALUE for null.
test "parseFileIdFromResponse accepts success body with explicit error:null" {
    const allocator = std.testing.allocator;
    const body = "{\"id\":\"file-1\",\"error\":null}";
    const id = try parseFileIdFromResponse(allocator, body);
    defer allocator.free(id);
    try std.testing.expectEqualStrings("file-1", id);
}

test "parseFileIdFromResponse accepts richer success body with explicit error:null" {
    const allocator = std.testing.allocator;
    const body =
        \\{"id":"file-xyz","object":"file","bytes":42,"created_at":1700000000,"filename":"clip.mp4","purpose":"video","status":"ready","status_details":null,"error":null}
    ;
    const id = try parseFileIdFromResponse(allocator, body);
    defer allocator.free(id);
    try std.testing.expectEqualStrings("file-xyz", id);
}

test "parseFileIdFromResponse rejects malformed JSON" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidResponse, parseFileIdFromResponse(allocator, "not json"));
    try std.testing.expectError(error.InvalidResponse, parseFileIdFromResponse(allocator, "[1,2,3]"));
    try std.testing.expectError(error.InvalidResponse, parseFileIdFromResponse(allocator, "{}"));
    try std.testing.expectError(error.InvalidResponse, parseFileIdFromResponse(allocator, "{\"id\":123}"));
}

// HIGH-2 (v1.14.23 review): tempfile path must embed 96 bits of
// cryptographic randomness so two concurrent uploads in the same
// process cannot collide on the predictable PID-only path.
test "buildUploadTempPath embeds tmp_dir, pid, and 24-hex-char random suffix" {
    var buf: [512]u8 = undefined;
    const p = try buildUploadTempPath(&buf, "/tmp", 12345);
    try std.testing.expect(std.mem.startsWith(u8, p, "/tmp/nullalis_upload_12345_"));
    try std.testing.expect(std.mem.endsWith(u8, p, ".bin"));
    // path = "/tmp/nullalis_upload_12345_" + 24 hex + ".bin"
    const prefix = "/tmp/nullalis_upload_12345_";
    try std.testing.expectEqual(@as(usize, prefix.len + 24 + ".bin".len), p.len);
    // Sentinel is in place.
    try std.testing.expectEqual(@as(u8, 0), buf[p.len]);
    // Suffix between prefix and ".bin" is 24 lowercase hex chars.
    const hex_slice = p[prefix.len .. p.len - ".bin".len];
    try std.testing.expectEqual(@as(usize, 24), hex_slice.len);
    for (hex_slice) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(ok);
    }
}

test "buildUploadTempPath returns distinct random suffixes across calls" {
    var buf_a: [512]u8 = undefined;
    var buf_b: [512]u8 = undefined;
    const a = try buildUploadTempPath(&buf_a, "/tmp", 99);
    const b = try buildUploadTempPath(&buf_b, "/tmp", 99);
    // Same PID + same tmp_dir but distinct random suffix → distinct paths.
    // 96 bits of entropy means a collision probability is negligible
    // (~1 in 2^96), so a test failure here is a real regression.
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "buildUploadTempPath errors on undersized buffer" {
    var buf: [16]u8 = undefined;
    try std.testing.expectError(
        error.TempPathTooLong,
        buildUploadTempPath(&buf, "/tmp", 12345),
    );
}

// Suppress unused-import warning in release builds when json_util is only
// touched by helpers that aren't built into the dev profile.
comptime {
    _ = json_util;
}
