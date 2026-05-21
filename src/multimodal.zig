//! Multimodal input processing — [IMAGE:] / [VIDEO:] marker parsing, MIME
//! detection, base64 encoding, and ephemeral content_parts preparation for
//! providers.
//!
//! Ported from ZeroClaw's `src/multimodal.rs`; video ingest added 2026-05-21.
//! Images and videos travel as `[IMAGE:path]` / `[VIDEO:path]` markers in
//! content strings through the entire pipeline. Conversion to `content_parts`
//! happens ephemerally at send time (arena-allocated), with no changes to
//! session/agent signatures or message history storage.

const std = @import("std");
const providers = @import("providers/root.zig");
const ChatMessage = providers.ChatMessage;
const ContentPart = providers.ContentPart;
const path_security = @import("tools/path_security.zig");

const log = std.log.scoped(.multimodal);

pub const ImageFlowMetrics = struct {
    image_markers_detected: u64,
    messages_with_image_markers: u64,
    image_parts_prepared: u64,
    image_parts_failed: u64,
    image_markers_ignored: u64,
};

var image_markers_detected_total = std.atomic.Value(u64).init(0);
var messages_with_image_markers_total = std.atomic.Value(u64).init(0);
var image_parts_prepared_total = std.atomic.Value(u64).init(0);
var image_parts_failed_total = std.atomic.Value(u64).init(0);
var image_markers_ignored_total = std.atomic.Value(u64).init(0);

pub fn imageFlowMetricsSnapshot() ImageFlowMetrics {
    return .{
        .image_markers_detected = image_markers_detected_total.load(.monotonic),
        .messages_with_image_markers = messages_with_image_markers_total.load(.monotonic),
        .image_parts_prepared = image_parts_prepared_total.load(.monotonic),
        .image_parts_failed = image_parts_failed_total.load(.monotonic),
        .image_markers_ignored = image_markers_ignored_total.load(.monotonic),
    };
}

fn markImageMarkersDetected(count: usize) void {
    if (count == 0) return;
    _ = image_markers_detected_total.fetchAdd(@intCast(count), .monotonic);
}

fn markMessageWithImageMarkers() void {
    _ = messages_with_image_markers_total.fetchAdd(1, .monotonic);
}

fn markImagePartPrepared() void {
    _ = image_parts_prepared_total.fetchAdd(1, .monotonic);
}

fn markImagePartFailed() void {
    _ = image_parts_failed_total.fetchAdd(1, .monotonic);
}

fn markImageMarkersIgnored(count: usize) void {
    if (count == 0) return;
    _ = image_markers_ignored_total.fetchAdd(@intCast(count), .monotonic);
}

// ════════════════════════════════════════════════════════════════════════════
// Configuration
// ════════════════════════════════════════════════════════════════════════════

pub const MultimodalConfig = struct {
    max_images: u32 = 4,
    max_image_size_bytes: u64 = 20_971_520, // 20 MB
    /// Max number of videos prepared per message. Mirrors `max_images`.
    /// Default 1: one max-size video already nears the provider body cap
    /// (see `max_video_size_bytes`), so a second would overflow it.
    max_videos: u32 = 1,
    /// Cap on a single video's raw (pre-base64) byte size. Moonshot/Kimi's
    /// request body limit is 100 MB and base64 inflates the payload ~33%,
    /// so raw video must stay under ~70 MB to fit once encoded. Over-cap
    /// videos are skipped (a text note replaces them); the provider's
    /// large-file upload API is not wired here.
    max_video_size_bytes: u64 = 73_400_320, // 70 MiB
    /// Allow passing remote image URLs (`https://...`) through to providers.
    /// Disabled by default for secure-by-default behavior.
    allow_remote_fetch: bool = false,
    /// Directories from which local image reads are allowed.
    /// If empty, all local file reads are rejected (only URLs pass through).
    allowed_dirs: []const []const u8 = &.{},
};

pub const default_config = MultimodalConfig{};

// ════════════════════════════════════════════════════════════════════════════
// Image Marker Parsing
// ════════════════════════════════════════════════════════════════════════════

pub const ParseResult = struct {
    cleaned_text: []const u8,
    refs: []const []const u8,
};

/// Scan content for `[IMAGE:...]` markers. Returns the cleaned text (markers
/// removed) and an array of image references (file paths or URLs).
/// Refs are sub-slices of the original content parameter, not independently allocated.
pub fn parseImageMarkers(allocator: std.mem.Allocator, content: []const u8) !ParseResult {
    return parseMarkers(allocator, content, isImageKind);
}

/// Scan content for `[VIDEO:...]` markers. Same contract as `parseImageMarkers`
/// but recognizes only the video marker kind; `[IMAGE:]` markers and any other
/// bracketed text are preserved verbatim in `cleaned_text`.
pub fn parseVideoMarkers(allocator: std.mem.Allocator, content: []const u8) !ParseResult {
    return parseMarkers(allocator, content, isVideoKind);
}

/// Shared marker scanner. `kindFn` decides which marker kinds are extracted
/// into `refs`; every other `[...]` span is kept verbatim in `cleaned_text`.
fn parseMarkers(
    allocator: std.mem.Allocator,
    content: []const u8,
    kindFn: *const fn (kind_str: []const u8) bool,
) !ParseResult {
    var refs: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer refs.deinit(allocator);

    var remaining: std.ArrayListUnmanaged(u8) = .empty;
    errdefer remaining.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < content.len) {
        const open_pos = std.mem.indexOfPos(u8, content, cursor, "[") orelse {
            try remaining.appendSlice(allocator, content[cursor..]);
            break;
        };

        try remaining.appendSlice(allocator, content[cursor..open_pos]);

        const close_pos = std.mem.indexOfPos(u8, content, open_pos, "]") orelse {
            try remaining.appendSlice(allocator, content[open_pos..]);
            break;
        };

        const marker = content[open_pos + 1 .. close_pos];

        if (std.mem.indexOf(u8, marker, ":")) |colon_pos| {
            const kind_str = marker[0..colon_pos];
            const target_raw = marker[colon_pos + 1 ..];
            const target = std.mem.trim(u8, target_raw, " ");

            if (target.len > 0 and kindFn(kind_str)) {
                try refs.append(allocator, target);
                cursor = close_pos + 1;
                continue;
            }
        }

        // Not a marker kind this scan extracts — keep original text
        try remaining.appendSlice(allocator, content[open_pos .. close_pos + 1]);
        cursor = close_pos + 1;
    }

    const trimmed = std.mem.trim(u8, remaining.items, " \t\n\r");
    const cleaned = try allocator.dupe(u8, trimmed);
    errdefer allocator.free(cleaned);
    remaining.deinit(allocator);

    return .{
        .cleaned_text = cleaned,
        .refs = try refs.toOwnedSlice(allocator),
    };
}

fn isImageKind(kind_str: []const u8) bool {
    return eqlLower(kind_str, "image") or eqlLower(kind_str, "photo") or eqlLower(kind_str, "img");
}

fn isVideoKind(kind_str: []const u8) bool {
    return eqlLower(kind_str, "video");
}

fn eqlLower(a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != bc) return false;
    }
    return true;
}

// ════════════════════════════════════════════════════════════════════════════
// MIME Type Detection
// ════════════════════════════════════════════════════════════════════════════

/// Detect MIME type from the first bytes of a file (magic byte sniffing).
pub fn detectMimeType(header: []const u8) ?[]const u8 {
    if (header.len < 4) return null;

    // PNG: 89 50 4E 47
    if (header[0] == 0x89 and header[1] == 'P' and header[2] == 'N' and header[3] == 'G')
        return "image/png";

    // JPEG: FF D8 FF
    if (header[0] == 0xFF and header[1] == 0xD8 and header[2] == 0xFF)
        return "image/jpeg";

    // GIF: GIF8
    if (header[0] == 'G' and header[1] == 'I' and header[2] == 'F' and header[3] == '8')
        return "image/gif";

    // BMP: BM
    if (header[0] == 'B' and header[1] == 'M')
        return "image/bmp";

    // WebP: RIFF....WEBP
    if (header.len >= 12 and
        header[0] == 'R' and header[1] == 'I' and header[2] == 'F' and header[3] == 'F' and
        header[8] == 'W' and header[9] == 'E' and header[10] == 'B' and header[11] == 'P')
        return "image/webp";

    return null;
}

/// ASF/WMV header object GUID — the fixed 16-byte prefix of every .wmv file.
const asf_guid = [16]u8{
    0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
    0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
};

/// Detect a video container MIME type from the first bytes of a file (magic
/// byte sniffing). Returns one of the Moonshot/Kimi-accepted `video/*` types,
/// or null when the bytes match no known container. Real video files carry
/// headers far larger than the 12-byte minimum checked here.
pub fn detectVideoMimeType(header: []const u8) ?[]const u8 {
    if (header.len < 12) return null;

    // ISO base media (mp4/mov/3gpp): bytes 4..8 are the `ftyp` box type;
    // bytes 8..12 are the major brand, which distinguishes the container.
    if (std.mem.eql(u8, header[4..8], "ftyp")) {
        const brand = header[8..12];
        if (std.mem.eql(u8, brand, "qt  ")) return "video/mov";
        if (std.mem.startsWith(u8, brand, "3g")) return "video/3gpp";
        return "video/mp4";
    }

    // WebM / Matroska: EBML header magic 1A 45 DF A3.
    if (header[0] == 0x1A and header[1] == 0x45 and header[2] == 0xDF and header[3] == 0xA3)
        return "video/webm";

    // AVI: RIFF....AVI<space>.
    if (header[0] == 'R' and header[1] == 'I' and header[2] == 'F' and header[3] == 'F' and
        header[8] == 'A' and header[9] == 'V' and header[10] == 'I' and header[11] == ' ')
        return "video/avi";

    // FLV: "FLV" signature.
    if (header[0] == 'F' and header[1] == 'L' and header[2] == 'V')
        return "video/x-flv";

    // ASF / WMV: fixed 16-byte header object GUID.
    if (header.len >= 16 and std.mem.eql(u8, header[0..16], &asf_guid))
        return "video/wmv";

    // MPEG-1/2 program/system stream (00 00 01 BA) or video sequence
    // header (00 00 01 B3). Covers both .mpeg and .mpg.
    if (header[0] == 0x00 and header[1] == 0x00 and header[2] == 0x01 and
        (header[3] == 0xBA or header[3] == 0xB3))
        return "video/mpeg";

    return null;
}

// ════════════════════════════════════════════════════════════════════════════
// Local Image / Video Reading
// ════════════════════════════════════════════════════════════════════════════

pub const ImageData = struct {
    data: []const u8,
    mime_type: []const u8,
};

pub const DataUriImage = struct {
    data: []const u8,
    mime_type: []const u8,
};

/// Raw bytes + detected container MIME type for a local video file.
/// Distinct from `ImageData` so callers can't accidentally cross modalities.
pub const VideoData = struct {
    data: []const u8,
    mime_type: []const u8,
};

/// Resolve `path` to an absolute path and verify it lives under an allowed
/// directory. Shared by `readLocalImage` and `readLocalVideo`. Caller owns
/// the returned slice.
///
/// Relative-path resolution: relative paths are resolved against
/// `config.allowed_dirs[*]` BEFORE falling back to process CWD. The agent's
/// prompt teaches it to reference uploaded attachments via relative paths
/// like `attachments/<filename>` (PR #69), which is correct relative to the
/// user's workspace — but the gateway's process CWD is typically the runtime
/// working dir (e.g. `/data/.nullalis/` on k8s pods), not the workspace.
/// Resolving against allowed_dirs ensures `attachments/<name>` lands at
/// `<workspace>/attachments/<name>` where the upload endpoint placed it.
fn resolveAllowedPath(allocator: std.mem.Allocator, path: []const u8, config: MultimodalConfig) ![]const u8 {
    // Resolve to absolute path (realpathAlloc resolves ".." and symlinks)
    const resolved = blk: {
        if (std.fs.path.isAbsolute(path)) {
            break :blk std.fs.realpathAlloc(allocator, path) catch return error.PathNotFound;
        }
        // Try each allowed_dir as a base before falling back to CWD.
        // First match wins; subsequent allowed_dirs are not tried.
        for (config.allowed_dirs) |dir| {
            const trimmed = std.mem.trimRight(u8, dir, "/\\");
            if (trimmed.len == 0) continue;
            const candidate = std.fs.path.join(allocator, &.{ trimmed, path }) catch continue;
            defer allocator.free(candidate);
            if (std.fs.realpathAlloc(allocator, candidate)) |r| {
                break :blk r;
            } else |_| continue;
        }
        // Backwards-compat: fall back to CWD-relative resolution. Existing
        // callers that pass a path already relative to the gateway's CWD
        // (rare, but possible for tests or operator scripts) keep working.
        break :blk std.fs.cwd().realpathAlloc(allocator, path) catch return error.PathNotFound;
    };
    errdefer allocator.free(resolved);

    // Verify the resolved path is within an allowed directory
    if (config.allowed_dirs.len == 0) return error.LocalReadNotAllowed;
    const allowed = blk: {
        for (config.allowed_dirs) |dir| {
            const trimmed = std.mem.trimRight(u8, dir, "/\\");
            if (trimmed.len == 0) continue;
            if (path_security.pathStartsWith(resolved, trimmed)) break :blk true;

            // Compare against canonicalized allowed dir too (/var -> /private/var on macOS).
            const canonical = std.fs.realpathAlloc(allocator, trimmed) catch continue;
            defer allocator.free(canonical);
            if (path_security.pathStartsWith(resolved, canonical)) break :blk true;
        }
        break :blk false;
    };
    if (!allowed) return error.PathNotAllowed;

    return resolved;
}

/// Read a local image file, validate its size, and detect MIME type.
/// Returns raw bytes and MIME type. Caller owns the returned `data` slice.
/// Path is validated against `allowed_dirs` to prevent arbitrary file reads.
pub fn readLocalImage(allocator: std.mem.Allocator, path: []const u8, config: MultimodalConfig) !ImageData {
    const resolved = try resolveAllowedPath(allocator, path, config);
    defer allocator.free(resolved);

    const file = std.fs.openFileAbsolute(resolved, .{}) catch return error.PathNotFound;
    return readFromFile(allocator, file, config.max_image_size_bytes);
}

/// Read a local video file, validate its size against `max_video_size_bytes`,
/// and detect its container MIME type. Returns raw bytes and MIME type; caller
/// owns the returned `data` slice. Path is validated against `allowed_dirs`
/// exactly like `readLocalImage`. Over-cap files return `error.VideoTooLarge`.
pub fn readLocalVideo(allocator: std.mem.Allocator, path: []const u8, config: MultimodalConfig) !VideoData {
    const resolved = try resolveAllowedPath(allocator, path, config);
    defer allocator.free(resolved);

    const file = std.fs.openFileAbsolute(resolved, .{}) catch return error.PathNotFound;
    return readVideoFromFile(allocator, file, config.max_video_size_bytes);
}

fn readVideoFromFile(allocator: std.mem.Allocator, file: std.fs.File, max_size: u64) !VideoData {
    defer file.close();

    const stat = try file.stat();
    if (stat.size > max_size)
        return error.VideoTooLarge;

    const data = try file.readToEndAlloc(allocator, max_size);
    errdefer allocator.free(data);

    const mime = detectVideoMimeType(data) orelse return error.UnknownVideoFormat;

    return .{ .data = data, .mime_type = mime };
}

fn readFromFile(allocator: std.mem.Allocator, file: std.fs.File, max_size: u64) !ImageData {
    defer file.close();

    const stat = try file.stat();
    if (stat.size > max_size)
        return error.ImageTooLarge;

    const data = try file.readToEndAlloc(allocator, max_size);
    errdefer allocator.free(data);

    const mime = detectMimeType(data) orelse return error.UnknownImageFormat;

    return .{ .data = data, .mime_type = mime };
}

// ════════════════════════════════════════════════════════════════════════════
// Base64 Encoding
// ════════════════════════════════════════════════════════════════════════════

/// Base64-encode raw bytes. Caller owns the returned slice.
pub fn encodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(buf, data);
    return buf;
}

fn isAllowedMimeType(mime: []const u8) bool {
    return std.ascii.eqlIgnoreCase(mime, "image/png") or
        std.ascii.eqlIgnoreCase(mime, "image/jpeg") or
        std.ascii.eqlIgnoreCase(mime, "image/webp") or
        std.ascii.eqlIgnoreCase(mime, "image/gif") or
        std.ascii.eqlIgnoreCase(mime, "image/bmp");
}

/// Parse and validate a data URI image marker.
/// Returns the base64 payload and MIME type as borrowed slices of `source`.
fn parseDataUriImage(source: []const u8, max_size_bytes: u64) !DataUriImage {
    if (!std.mem.startsWith(u8, source, "data:")) return error.InvalidDataUri;
    const comma = std.mem.indexOfScalar(u8, source, ',') orelse return error.InvalidDataUri;

    const meta = source["data:".len..comma];
    const payload = std.mem.trim(u8, source[comma + 1 ..], " \t\r\n");
    if (payload.len == 0) return error.InvalidDataUri;

    var meta_it = std.mem.splitScalar(u8, meta, ';');
    const mime = std.mem.trim(u8, meta_it.next() orelse "", " \t");
    if (mime.len == 0 or !isAllowedMimeType(mime)) return error.UnknownImageFormat;

    var has_base64 = false;
    while (meta_it.next()) |token| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), "base64")) {
            has_base64 = true;
            break;
        }
    }
    if (!has_base64) return error.InvalidDataUri;

    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(payload) catch return error.InvalidDataUri;
    if (decoded_size > max_size_bytes) return error.ImageTooLarge;

    return .{
        .data = payload,
        .mime_type = mime,
    };
}

/// Base64 payload + MIME type parsed from a `data:video/...;base64,...` URI.
pub const DataUriVideo = struct {
    data: []const u8,
    mime_type: []const u8,
};

/// Video container MIME types Moonshot/Kimi accepts in a `video_url` data URI.
fn isAllowedVideoMimeType(mime: []const u8) bool {
    return std.ascii.eqlIgnoreCase(mime, "video/mp4") or
        std.ascii.eqlIgnoreCase(mime, "video/mpeg") or
        std.ascii.eqlIgnoreCase(mime, "video/mpg") or
        std.ascii.eqlIgnoreCase(mime, "video/mov") or
        std.ascii.eqlIgnoreCase(mime, "video/avi") or
        std.ascii.eqlIgnoreCase(mime, "video/webm") or
        std.ascii.eqlIgnoreCase(mime, "video/wmv") or
        std.ascii.eqlIgnoreCase(mime, "video/3gpp") or
        std.ascii.eqlIgnoreCase(mime, "video/x-flv");
}

/// Parse and validate a `data:video/...;base64,...` URI.
/// Returns the base64 payload and MIME type as borrowed slices of `source`.
/// Over-cap payloads return `error.VideoTooLarge`.
fn parseDataUriVideo(source: []const u8, max_size_bytes: u64) !DataUriVideo {
    if (!std.mem.startsWith(u8, source, "data:")) return error.InvalidDataUri;
    const comma = std.mem.indexOfScalar(u8, source, ',') orelse return error.InvalidDataUri;

    const meta = source["data:".len..comma];
    const payload = std.mem.trim(u8, source[comma + 1 ..], " \t\r\n");
    if (payload.len == 0) return error.InvalidDataUri;

    var meta_it = std.mem.splitScalar(u8, meta, ';');
    const mime = std.mem.trim(u8, meta_it.next() orelse "", " \t");
    if (mime.len == 0 or !isAllowedVideoMimeType(mime)) return error.UnknownVideoFormat;

    var has_base64 = false;
    while (meta_it.next()) |token| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), "base64")) {
            has_base64 = true;
            break;
        }
    }
    if (!has_base64) return error.InvalidDataUri;

    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(payload) catch return error.InvalidDataUri;
    if (decoded_size > max_size_bytes) return error.VideoTooLarge;

    return .{
        .data = payload,
        .mime_type = mime,
    };
}

// ════════════════════════════════════════════════════════════════════════════
// Message Preparation for Providers
// ════════════════════════════════════════════════════════════════════════════

/// Process messages for multimodal content: scan the last user message for
/// [IMAGE:] and [VIDEO:] markers, read local files, base64-encode, and build
/// content_parts (image_base64 / image_url / video_base64).
///
/// All allocations happen on the arena (freed after the provider call).
/// Messages without markers pass through unchanged.
pub fn prepareMessagesForProvider(
    arena: std.mem.Allocator,
    messages: []ChatMessage,
    config: MultimodalConfig,
) ![]ChatMessage {
    const result = try arena.alloc(ChatMessage, messages.len);

    // Only process the last user message — earlier images are already consumed
    // and their temp files may be gone. This avoids re-encoding on every iteration.
    var last_user_idx: ?usize = null;
    for (0..messages.len) |j| {
        const idx = messages.len - 1 - j;
        if (messages[idx].role == .user) {
            last_user_idx = idx;
            break;
        }
    }

    for (messages, 0..) |msg, i| {
        if (msg.role != .user or msg.content.len == 0 or i != (last_user_idx orelse messages.len)) {
            result[i] = msg;
            continue;
        }

        // Quick check: scan for '[' followed by a case-insensitive image or
        // video keyword and ':'. Skips the full parse for the common no-marker
        // case.
        const has_marker = blk: {
            var pos: usize = 0;
            while (pos < msg.content.len) : (pos += 1) {
                if (msg.content[pos] == '[') {
                    const rest = msg.content[pos + 1 ..];
                    if (rest.len >= 6 and rest[5] == ':' and eqlLower(rest[0..5], "image")) break :blk true;
                    if (rest.len >= 6 and rest[5] == ':' and eqlLower(rest[0..5], "photo")) break :blk true;
                    if (rest.len >= 6 and rest[5] == ':' and eqlLower(rest[0..5], "video")) break :blk true;
                    if (rest.len >= 4 and rest[3] == ':' and eqlLower(rest[0..3], "img")) break :blk true;
                }
            }
            break :blk false;
        };
        if (!has_marker) {
            result[i] = msg;
            continue;
        }

        // Two-pass scan: parseImageMarkers strips [IMAGE:]/[PHOTO:]/[IMG:] and
        // leaves any [VIDEO:] span verbatim; parseVideoMarkers then strips
        // [VIDEO:] from that already-cleaned text. final_text has both removed.
        const parsed = try parseImageMarkers(arena, msg.content);
        const video_parsed = try parseVideoMarkers(arena, parsed.cleaned_text);
        const final_text = video_parsed.cleaned_text;

        if (parsed.refs.len == 0 and video_parsed.refs.len == 0) {
            result[i] = msg;
            continue;
        }
        if (parsed.refs.len > 0) {
            markMessageWithImageMarkers();
            markImageMarkersDetected(parsed.refs.len);
        }

        // Build content_parts: text part + image parts + video parts
        var parts: std.ArrayListUnmanaged(ContentPart) = .empty;

        if (final_text.len > 0) {
            try parts.append(arena, .{ .text = final_text });
        }

        const max_images = @min(parsed.refs.len, config.max_images);
        if (parsed.refs.len > max_images) {
            const dropped = parsed.refs.len - max_images;
            markImageMarkersIgnored(dropped);
            const note = try std.fmt.allocPrint(
                arena,
                "[Only {d} image(s) were processed (max_images={d}); {d} additional image(s) ignored]",
                .{ max_images, config.max_images, dropped },
            );
            try parts.append(arena, .{ .text = note });
        }

        for (parsed.refs[0..max_images]) |ref| {
            // Truncated ref for error messages (avoid leaking huge data URIs)
            const display_ref = if (ref.len > 80) ref[0..80] else ref;

            if (isDataUrl(ref)) {
                const data_uri = parseDataUriImage(ref, config.max_image_size_bytes) catch |err| {
                    log.warn("failed to parse data URI image: {}", .{err});
                    markImagePartFailed();
                    const note = try std.fmt.allocPrint(arena, "[Failed to load image: {s}...]", .{display_ref});
                    try parts.append(arena, .{ .text = note });
                    continue;
                };
                try parts.append(arena, .{ .image_base64 = .{
                    .data = data_uri.data,
                    .media_type = data_uri.mime_type,
                } });
                markImagePartPrepared();
            } else if (isHttpUrl(ref) or isHttpsUrl(ref)) {
                if (!config.allow_remote_fetch) {
                    markImagePartFailed();
                    const note = try std.fmt.allocPrint(arena, "[Remote image URLs are disabled: {s}]", .{display_ref});
                    try parts.append(arena, .{ .text = note });
                    continue;
                }
                if (!isHttpsUrl(ref)) {
                    markImagePartFailed();
                    const note = try std.fmt.allocPrint(arena, "[Remote image URL must use HTTPS: {s}]", .{display_ref});
                    try parts.append(arena, .{ .text = note });
                    continue;
                }
                try parts.append(arena, .{ .image_url = .{ .url = ref } });
                markImagePartPrepared();
            } else {
                // Local file — read + base64 encode
                const img = readLocalImage(arena, ref, config) catch |err| {
                    log.warn("failed to read image '{s}': {}", .{ ref, err });
                    markImagePartFailed();
                    const note = try std.fmt.allocPrint(arena, "[Failed to load image: {s}]", .{display_ref});
                    try parts.append(arena, .{ .text = note });
                    continue;
                };
                const b64 = encodeBase64(arena, img.data) catch {
                    markImagePartFailed();
                    const note = try std.fmt.allocPrint(arena, "[Failed to encode image: {s}]", .{display_ref});
                    try parts.append(arena, .{ .text = note });
                    continue;
                };
                try parts.append(arena, .{ .image_base64 = .{
                    .data = b64,
                    .media_type = img.mime_type,
                } });
                markImagePartPrepared();
            }
        }

        // Video parts — mirror the image loop. Over-cap and unreadable videos
        // are skipped with a text note rather than erroring the turn (there is
        // no video sidecar; capability-based routing happens later in the
        // agent, see agent/root.zig hasVideoContentParts).
        const max_videos = @min(video_parsed.refs.len, config.max_videos);
        if (video_parsed.refs.len > max_videos) {
            const dropped = video_parsed.refs.len - max_videos;
            const note = try std.fmt.allocPrint(
                arena,
                "[Only {d} video(s) were processed (max_videos={d}); {d} additional video(s) ignored]",
                .{ max_videos, config.max_videos, dropped },
            );
            try parts.append(arena, .{ .text = note });
        }

        const video_cap_mb = config.max_video_size_bytes / (1024 * 1024);
        for (video_parsed.refs[0..max_videos]) |ref| {
            // Truncated ref for notes (avoid leaking huge data URIs)
            const display_ref = if (ref.len > 80) ref[0..80] else ref;

            if (isDataUrl(ref)) {
                const data_uri = parseDataUriVideo(ref, config.max_video_size_bytes) catch |err| {
                    log.warn("failed to parse data URI video: {}", .{err});
                    const note = if (err == error.VideoTooLarge)
                        try std.fmt.allocPrint(arena, "[Video too large: {s}... — exceeds {d} MB cap, skipped]", .{ display_ref, video_cap_mb })
                    else
                        try std.fmt.allocPrint(arena, "[Failed to load video: {s}...]", .{display_ref});
                    try parts.append(arena, .{ .text = note });
                    continue;
                };
                try parts.append(arena, .{ .video_base64 = .{
                    .data = data_uri.data,
                    .media_type = data_uri.mime_type,
                } });
            } else if (isHttpUrl(ref) or isHttpsUrl(ref)) {
                // Moonshot/Kimi accepts video only as a base64 data URI, never
                // as a plain URL — so a remote video URL cannot be forwarded.
                const note = try std.fmt.allocPrint(
                    arena,
                    "[Remote video URLs are not supported (provider requires base64 video): {s}]",
                    .{display_ref},
                );
                try parts.append(arena, .{ .text = note });
            } else {
                // Local file — read, size-check, base64 encode.
                const vid = readLocalVideo(arena, ref, config) catch |err| {
                    log.warn("failed to read video '{s}': {}", .{ ref, err });
                    const note = if (err == error.VideoTooLarge)
                        try std.fmt.allocPrint(arena, "[Video too large: {s} — exceeds {d} MB cap, skipped]", .{ display_ref, video_cap_mb })
                    else
                        try std.fmt.allocPrint(arena, "[Failed to load video: {s}]", .{display_ref});
                    try parts.append(arena, .{ .text = note });
                    continue;
                };
                const b64 = encodeBase64(arena, vid.data) catch {
                    const note = try std.fmt.allocPrint(arena, "[Failed to encode video: {s}]", .{display_ref});
                    try parts.append(arena, .{ .text = note });
                    continue;
                };
                try parts.append(arena, .{ .video_base64 = .{
                    .data = b64,
                    .media_type = vid.mime_type,
                } });
            }
        }

        result[i] = .{
            .role = msg.role,
            .content = if (final_text.len > 0) final_text else msg.content,
            .name = msg.name,
            .tool_call_id = msg.tool_call_id,
            .content_parts = try parts.toOwnedSlice(arena),
        };
    }

    return result;
}

/// Count image markers across user messages.
pub fn countImageMarkers(messages: []const ChatMessage) usize {
    var total: usize = 0;
    for (messages) |msg| {
        if (msg.role != .user or msg.content.len == 0) continue;
        total += countImageMarkersInText(msg.content);
    }
    return total;
}

/// Count image markers in the most recent user message only.
pub fn countImageMarkersInLastUser(messages: []const ChatMessage) usize {
    var i = messages.len;
    while (i > 0) : (i -= 1) {
        const idx = i - 1;
        const msg = messages[idx];
        if (msg.role != .user or msg.content.len == 0) continue;
        return countImageMarkersInText(msg.content);
    }
    return 0;
}

fn countImageMarkersInText(content: []const u8) usize {
    var count: usize = 0;
    var cursor: usize = 0;
    while (cursor < content.len) {
        const open_pos = std.mem.indexOfPos(u8, content, cursor, "[") orelse break;
        const close_pos = std.mem.indexOfPos(u8, content, open_pos, "]") orelse break;
        const marker = content[open_pos + 1 .. close_pos];
        if (std.mem.indexOf(u8, marker, ":")) |colon_pos| {
            const kind_str = marker[0..colon_pos];
            const target = std.mem.trim(u8, marker[colon_pos + 1 ..], " ");
            if (target.len > 0 and isImageKind(kind_str)) {
                count += 1;
            }
        }
        cursor = close_pos + 1;
    }
    return count;
}

/// Returns true if the string looks like a URL.
pub fn isUrl(s: []const u8) bool {
    return isHttpUrl(s) or isHttpsUrl(s) or isDataUrl(s);
}

fn isHttpUrl(s: []const u8) bool {
    if (s.len < 7) return false;
    return std.ascii.eqlIgnoreCase(s[0..7], "http://");
}

fn isHttpsUrl(s: []const u8) bool {
    if (s.len < 8) return false;
    return std.ascii.eqlIgnoreCase(s[0..8], "https://");
}

fn isDataUrl(s: []const u8) bool {
    if (s.len < 5) return false;
    return std.ascii.eqlIgnoreCase(s[0..5], "data:");
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "parseImageMarkers single marker" {
    const parsed = try parseImageMarkers(std.testing.allocator, "Look at this [IMAGE:/tmp/photo.png] please");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 1), parsed.refs.len);
    try std.testing.expectEqualStrings("/tmp/photo.png", parsed.refs[0]);
    try std.testing.expectEqualStrings("Look at this  please", parsed.cleaned_text);
}

test "parseImageMarkers multiple markers" {
    const parsed = try parseImageMarkers(std.testing.allocator, "[IMAGE:/a.png] text [IMAGE:/b.jpg]");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 2), parsed.refs.len);
    try std.testing.expectEqualStrings("/a.png", parsed.refs[0]);
    try std.testing.expectEqualStrings("/b.jpg", parsed.refs[1]);
    try std.testing.expectEqualStrings("text", parsed.cleaned_text);
}

test "parseImageMarkers no markers" {
    const parsed = try parseImageMarkers(std.testing.allocator, "No images here!");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 0), parsed.refs.len);
    try std.testing.expectEqualStrings("No images here!", parsed.cleaned_text);
}

test "parseImageMarkers empty text" {
    const parsed = try parseImageMarkers(std.testing.allocator, "");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 0), parsed.refs.len);
    try std.testing.expectEqualStrings("", parsed.cleaned_text);
}

test "parseImageMarkers case insensitive" {
    const parsed = try parseImageMarkers(std.testing.allocator, "[image:/a.png] [Image:/b.png] [PHOTO:/c.png]");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 3), parsed.refs.len);
}

test "parseImageMarkers invalid marker kept" {
    const parsed = try parseImageMarkers(std.testing.allocator, "[UNKNOWN:/a.bin]");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 0), parsed.refs.len);
    try std.testing.expectEqualStrings("[UNKNOWN:/a.bin]", parsed.cleaned_text);
}

test "parseImageMarkers empty target ignored" {
    const parsed = try parseImageMarkers(std.testing.allocator, "[IMAGE:]");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 0), parsed.refs.len);
    try std.testing.expectEqualStrings("[IMAGE:]", parsed.cleaned_text);
}

test "parseImageMarkers unclosed bracket" {
    const parsed = try parseImageMarkers(std.testing.allocator, "text [IMAGE:/a.png");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 0), parsed.refs.len);
    try std.testing.expectEqualStrings("text [IMAGE:/a.png", parsed.cleaned_text);
}

test "parseImageMarkers URL target" {
    const parsed = try parseImageMarkers(std.testing.allocator, "[IMAGE:https://example.com/cat.jpg]");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 1), parsed.refs.len);
    try std.testing.expectEqualStrings("https://example.com/cat.jpg", parsed.refs[0]);
}

test "parseImageMarkers IMG alias" {
    const parsed = try parseImageMarkers(std.testing.allocator, "[IMG:/tmp/a.png]");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 1), parsed.refs.len);
}

test "detectMimeType PNG" {
    const header = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    try std.testing.expectEqualStrings("image/png", detectMimeType(&header).?);
}

test "detectMimeType JPEG" {
    const header = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 };
    try std.testing.expectEqualStrings("image/jpeg", detectMimeType(&header).?);
}

test "detectMimeType GIF" {
    const header = [_]u8{ 'G', 'I', 'F', '8', '9', 'a' };
    try std.testing.expectEqualStrings("image/gif", detectMimeType(&header).?);
}

test "detectMimeType BMP" {
    const header = [_]u8{ 'B', 'M', 0x00, 0x00 };
    try std.testing.expectEqualStrings("image/bmp", detectMimeType(&header).?);
}

test "detectMimeType WebP" {
    const header = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'E', 'B', 'P' };
    try std.testing.expectEqualStrings("image/webp", detectMimeType(&header).?);
}

test "detectMimeType unknown" {
    const header = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expect(detectMimeType(&header) == null);
}

test "detectMimeType too short" {
    const header = [_]u8{ 0x89, 'P' };
    try std.testing.expect(detectMimeType(&header) == null);
}

test "encodeBase64 simple" {
    const encoded = try encodeBase64(std.testing.allocator, "Hello");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("SGVsbG8=", encoded);
}

test "encodeBase64 empty" {
    const encoded = try encodeBase64(std.testing.allocator, "");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("", encoded);
}

test "encodeBase64 binary data" {
    const data = [_]u8{ 0x89, 0x50, 0x4E, 0x47 };
    const encoded = try encodeBase64(std.testing.allocator, &data);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("iVBORw==", encoded);
}

test "isUrl http" {
    try std.testing.expect(isUrl("http://example.com/a.png"));
}

test "isUrl https" {
    try std.testing.expect(isUrl("https://example.com/a.png"));
}

test "isUrl data" {
    try std.testing.expect(isUrl("data:image/png;base64,iVBOR"));
}

test "isUrl local path" {
    try std.testing.expect(!isUrl("/tmp/photo.png"));
}

test "isUrl relative path" {
    try std.testing.expect(!isUrl("photos/cat.jpg"));
}

test "MultimodalConfig defaults" {
    const cfg = MultimodalConfig{};
    try std.testing.expectEqual(@as(u32, 4), cfg.max_images);
    try std.testing.expectEqual(@as(u64, 20_971_520), cfg.max_image_size_bytes);
}

test "prepareMessagesForProvider no markers passes through" {
    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.system("Be helpful"),
        ChatMessage.user("Hello, no images"),
        ChatMessage.assistant("Hi there"),
    };

    const result = try prepareMessagesForProvider(arena, &msgs, .{});
    try std.testing.expectEqual(@as(usize, 3), result.len);
    // All should pass through unchanged
    try std.testing.expect(result[0].content_parts == null);
    try std.testing.expect(result[1].content_parts == null);
    try std.testing.expect(result[2].content_parts == null);
}

test "prepareMessagesForProvider with URL marker creates content_parts" {
    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user("Check this [IMAGE:https://example.com/cat.jpg] out"),
    };

    const result = try prepareMessagesForProvider(arena, &msgs, .{});
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0].content_parts != null);
    const parts = result[0].content_parts.?;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    // First part: text
    try std.testing.expect(parts[0] == .text);
    try std.testing.expectEqualStrings("Check this  out", parts[0].text);
    // Second part: explicit policy note (remote URLs disabled by default)
    try std.testing.expect(parts[1] == .text);
    try std.testing.expect(std.mem.indexOf(u8, parts[1].text, "Remote image URLs are disabled") != null);
}

test "prepareMessagesForProvider with URL marker allowed by config" {
    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user("Check this [IMAGE:https://example.com/cat.jpg] out"),
    };

    const result = try prepareMessagesForProvider(arena, &msgs, .{ .allow_remote_fetch = true });
    const parts = result[0].content_parts.?;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expect(parts[1] == .image_url);
    try std.testing.expectEqualStrings("https://example.com/cat.jpg", parts[1].image_url.url);
}

test "prepareMessagesForProvider adds note when markers exceed max_images" {
    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user("Compare [IMAGE:https://example.com/a.jpg] [IMAGE:https://example.com/b.jpg]"),
    };

    const result = try prepareMessagesForProvider(arena, &msgs, .{
        .allow_remote_fetch = true,
        .max_images = 1,
    });
    const parts = result[0].content_parts.?;

    var saw_limit_note = false;
    var saw_image = false;
    for (parts) |part| {
        switch (part) {
            .text => |text| {
                if (std.mem.indexOf(u8, text, "additional image(s) ignored") != null) {
                    saw_limit_note = true;
                }
            },
            .image_url => saw_image = true,
            else => {},
        }
    }
    try std.testing.expect(saw_image);
    try std.testing.expect(saw_limit_note);
}

test "prepareMessagesForProvider with data URI marker creates base64 image part" {
    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user("Analyze [IMAGE:data:image/png;base64,iVBORw0KGgo=]"),
    };

    const result = try prepareMessagesForProvider(arena, &msgs, .{});
    const parts = result[0].content_parts.?;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expect(parts[1] == .image_base64);
    try std.testing.expectEqualStrings("image/png", parts[1].image_base64.media_type);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", parts[1].image_base64.data);
}

test "prepareMessagesForProvider skips assistant messages" {
    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.assistant("Here is [IMAGE:/tmp/a.png]"),
    };

    const result = try prepareMessagesForProvider(arena, &msgs, .{});
    try std.testing.expect(result[0].content_parts == null);
}

test "readLocalImage rejects path traversal via allowed_dirs" {
    // On Unix: realpathAlloc resolves ".." -> path doesn't match empty allowed_dirs -> LocalReadNotAllowed
    // On Windows: /tmp doesn't exist -> realpathAlloc fails -> PathNotFound
    if (readLocalImage(std.testing.allocator, "/tmp/../etc/passwd", .{})) |_| {
        @panic("expected readLocalImage to fail for traversal path");
    } else |err| {
        try std.testing.expect(err == error.LocalReadNotAllowed or err == error.PathNotFound);
    }
}

test "readLocalImage rejects when no allowed_dirs" {
    // Create a real temp file so realpath succeeds, then verify allowed_dirs rejection
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "test.png", .data = "\x89PNG\x0d\x0a\x1a\x0a" });
    const dir_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "test.png" });
    defer std.testing.allocator.free(file_path);

    const err = readLocalImage(std.testing.allocator, file_path, .{});
    try std.testing.expectError(error.LocalReadNotAllowed, err);
}

test "readLocalImage resolves relative paths against allowed_dirs (workspace), not CWD" {
    // Regression for the 2026-04-29 image-upload bug: agent prompt teaches
    // relative `attachments/<filename>` references; readLocalImage was
    // resolving against process CWD (gateway working dir on k8s pods),
    // not against allowed_dirs (the user's workspace). This test pins the
    // allowed_dirs-first resolution.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("attachments");
    const png_bytes = "\x89PNG\x0d\x0a\x1a\x0a";
    try tmp_dir.dir.writeFile(.{
        .sub_path = "attachments/screenshot.png",
        .data = png_bytes,
    });
    const workspace_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_path);

    // Agent passes the relative path exactly as the prompt teaches it.
    const relative_ref = "attachments/screenshot.png";

    const allowed_dirs = [_][]const u8{workspace_path};
    const cfg = MultimodalConfig{
        .allowed_dirs = &allowed_dirs,
    };

    const result = try readLocalImage(std.testing.allocator, relative_ref, cfg);
    defer std.testing.allocator.free(result.data);

    try std.testing.expectEqualStrings("image/png", result.mime_type);
    try std.testing.expectEqualSlices(u8, png_bytes, result.data);
}

test "readLocalImage handles filenames with spaces, brackets, accents in allowed_dirs branch" {
    // Image-upload regression also surfaced via filenames the frontend
    // produces from "Save As" dialogs (e.g.
    // "ChatGPT Image Apr 25, 2026, 02:09:45 PM.png" with spaces +
    // commas + colons-replaced-with-underscores by the upload sanitizer).
    // PR #69 relaxed isSafeAttachmentFilename to allow these; this test
    // pins that the multimodal read path also tolerates them.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("attachments");
    const fname = "ChatGPT Image Apr 25_ 2026_ 02_09_45 PM.png";
    try tmp_dir.dir.writeFile(.{
        .sub_path = "attachments/ChatGPT Image Apr 25_ 2026_ 02_09_45 PM.png",
        .data = "\x89PNG\x0d\x0a\x1a\x0a",
    });
    const workspace_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_path);

    const allowed_dirs = [_][]const u8{workspace_path};
    const cfg = MultimodalConfig{ .allowed_dirs = &allowed_dirs };

    var rel_buf: [256]u8 = undefined;
    const relative = try std.fmt.bufPrint(&rel_buf, "attachments/{s}", .{fname});

    const result = try readLocalImage(std.testing.allocator, relative, cfg);
    defer std.testing.allocator.free(result.data);
    try std.testing.expectEqualStrings("image/png", result.mime_type);
}

test "prepareMessagesForProvider does not delete nullalis temp image files" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "nullalis_photo_123.png",
        .data = "\x89PNG\x0d\x0a\x1a\x0a",
    });

    const dir_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "nullalis_photo_123.png" });
    defer std.testing.allocator.free(file_path);

    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user(try std.fmt.allocPrint(std.testing.allocator, "[IMAGE:{s}]", .{file_path})),
    };
    defer std.testing.allocator.free(msgs[0].content);

    _ = try prepareMessagesForProvider(arena, &msgs, .{
        .allowed_dirs = &.{dir_path},
    });

    try std.fs.accessAbsolute(file_path, .{});
}

test "parseImageMarkers mixed case markers" {
    const parsed = try parseImageMarkers(std.testing.allocator, "[ImAgE:/a.png] [pHoTo:/b.jpg] [iMg:/c.gif]");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 3), parsed.refs.len);
    try std.testing.expectEqualStrings("/a.png", parsed.refs[0]);
    try std.testing.expectEqualStrings("/b.jpg", parsed.refs[1]);
    try std.testing.expectEqualStrings("/c.gif", parsed.refs[2]);
}

test "prepareMessagesForProvider only processes last user message" {
    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user("Look [IMAGE:https://example.com/old.jpg]"),
        ChatMessage.assistant("I see the old image"),
        ChatMessage.user("Now see [IMAGE:https://example.com/new.jpg]"),
    };

    const result = try prepareMessagesForProvider(arena, &msgs, .{});
    try std.testing.expectEqual(@as(usize, 3), result.len);
    // First user message should NOT be processed (not the last)
    try std.testing.expect(result[0].content_parts == null);
    // Assistant passes through
    try std.testing.expect(result[1].content_parts == null);
    // Last user message should be processed
    try std.testing.expect(result[2].content_parts != null);
}

test "quick-check handles mixed case IMAGE markers" {
    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user("[ImAgE:https://example.com/cat.jpg]"),
    };

    const result = try prepareMessagesForProvider(arena, &msgs, .{});
    try std.testing.expect(result[0].content_parts != null);
}

test "MultimodalConfig allowed_dirs defaults empty" {
    const cfg = MultimodalConfig{};
    try std.testing.expectEqual(@as(usize, 0), cfg.allowed_dirs.len);
}

test "countImageMarkers counts user image markers only" {
    const msgs = [_]ChatMessage{
        ChatMessage.user("One [IMAGE:/tmp/a.png]"),
        ChatMessage.assistant("[IMAGE:/tmp/ignored.png]"),
        ChatMessage.user("Two [PHOTO:/tmp/b.png] [IMG:/tmp/c.png]"),
    };
    try std.testing.expectEqual(@as(usize, 3), countImageMarkers(&msgs));
}

test "countImageMarkersInLastUser only counts latest user message" {
    const msgs = [_]ChatMessage{
        ChatMessage.user("Old [IMAGE:/tmp/old.png]"),
        ChatMessage.assistant("ack"),
        ChatMessage.user("No image here"),
    };
    try std.testing.expectEqual(@as(usize, 0), countImageMarkersInLastUser(&msgs));
}

test "imageFlowMetricsSnapshot tracks detected and prepared image parts" {
    const before = imageFlowMetricsSnapshot();

    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user("Check [IMAGE:https://example.com/a.jpg] and [IMAGE:https://example.com/b.jpg]"),
    };

    _ = try prepareMessagesForProvider(arena, &msgs, .{
        .allow_remote_fetch = true,
        .max_images = 1,
    });

    const after = imageFlowMetricsSnapshot();
    try std.testing.expectEqual(@as(u64, 2), after.image_markers_detected - before.image_markers_detected);
    try std.testing.expectEqual(@as(u64, 1), after.messages_with_image_markers - before.messages_with_image_markers);
    try std.testing.expectEqual(@as(u64, 1), after.image_parts_prepared - before.image_parts_prepared);
    try std.testing.expectEqual(@as(u64, 1), after.image_markers_ignored - before.image_markers_ignored);
}

// ── Video ingest tests (P3b) ─────────────────────────────────────────────────

test "MultimodalConfig video defaults" {
    const cfg = MultimodalConfig{};
    try std.testing.expectEqual(@as(u32, 1), cfg.max_videos);
    try std.testing.expectEqual(@as(u64, 73_400_320), cfg.max_video_size_bytes);
}

test "detectVideoMimeType mp4 (ftyp/isom)" {
    try std.testing.expectEqualStrings("video/mp4", detectVideoMimeType("\x00\x00\x00\x18ftypisom\x00\x00\x00\x00").?);
}

test "detectVideoMimeType mov (ftyp/qt)" {
    try std.testing.expectEqualStrings("video/mov", detectVideoMimeType("\x00\x00\x00\x18ftypqt  \x00\x00\x00\x00").?);
}

test "detectVideoMimeType 3gpp (ftyp/3gp4)" {
    try std.testing.expectEqualStrings("video/3gpp", detectVideoMimeType("\x00\x00\x00\x18ftyp3gp4\x00\x00\x00\x00").?);
}

test "detectVideoMimeType webm (EBML)" {
    try std.testing.expectEqualStrings("video/webm", detectVideoMimeType("\x1A\x45\xDF\xA3\x00\x00\x00\x00\x00\x00\x00\x00").?);
}

test "detectVideoMimeType avi (RIFF/AVI)" {
    try std.testing.expectEqualStrings("video/avi", detectVideoMimeType("RIFF\x00\x00\x00\x00AVI ").?);
}

test "detectVideoMimeType flv" {
    try std.testing.expectEqualStrings("video/x-flv", detectVideoMimeType("FLV\x01\x05\x00\x00\x00\x09\x00\x00\x00").?);
}

test "detectVideoMimeType mpeg (program stream)" {
    try std.testing.expectEqualStrings("video/mpeg", detectVideoMimeType("\x00\x00\x01\xBA\x00\x00\x00\x00\x00\x00\x00\x00").?);
}

test "detectVideoMimeType wmv (ASF GUID)" {
    try std.testing.expectEqualStrings("video/wmv", detectVideoMimeType(&asf_guid).?);
}

test "detectVideoMimeType unknown bytes" {
    try std.testing.expect(detectVideoMimeType("not-a-video!!!") == null);
}

test "detectVideoMimeType too short" {
    try std.testing.expect(detectVideoMimeType("ftyp") == null);
}

test "parseVideoMarkers single marker" {
    const parsed = try parseVideoMarkers(std.testing.allocator, "Watch [VIDEO:/tmp/clip.mp4] now");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 1), parsed.refs.len);
    try std.testing.expectEqualStrings("/tmp/clip.mp4", parsed.refs[0]);
    try std.testing.expectEqualStrings("Watch  now", parsed.cleaned_text);
}

test "parseVideoMarkers leaves image markers verbatim" {
    const parsed = try parseVideoMarkers(std.testing.allocator, "[IMAGE:/a.png] [VIDEO:/v.mp4]");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 1), parsed.refs.len);
    try std.testing.expectEqualStrings("/v.mp4", parsed.refs[0]);
    try std.testing.expectEqualStrings("[IMAGE:/a.png]", parsed.cleaned_text);
}

test "parseImageMarkers leaves video markers verbatim" {
    const parsed = try parseImageMarkers(std.testing.allocator, "[IMAGE:/a.png] [VIDEO:/v.mp4]");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 1), parsed.refs.len);
    try std.testing.expectEqualStrings("/a.png", parsed.refs[0]);
    try std.testing.expectEqualStrings("[VIDEO:/v.mp4]", parsed.cleaned_text);
}

test "parseVideoMarkers case insensitive" {
    const parsed = try parseVideoMarkers(std.testing.allocator, "[video:/a.mp4] [Video:/b.webm]");
    defer {
        std.testing.allocator.free(parsed.cleaned_text);
        std.testing.allocator.free(parsed.refs);
    }
    try std.testing.expectEqual(@as(usize, 2), parsed.refs.len);
}

test "parseDataUriVideo valid mp4" {
    const dv = try parseDataUriVideo("data:video/mp4;base64,AAAA", 1024);
    try std.testing.expectEqualStrings("video/mp4", dv.mime_type);
    try std.testing.expectEqualStrings("AAAA", dv.data);
}

test "parseDataUriVideo rejects non-video mime" {
    try std.testing.expectError(error.UnknownVideoFormat, parseDataUriVideo("data:image/png;base64,AAAA", 1024));
}

test "parseDataUriVideo rejects over-cap payload" {
    try std.testing.expectError(error.VideoTooLarge, parseDataUriVideo("data:video/mp4;base64,AAAAAAAA", 4));
}

test "readLocalVideo rejects when no allowed_dirs" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "clip.webm", .data = "\x1A\x45\xDF\xA3\x00\x00\x00\x00\x00\x00\x00\x00" });
    const dir_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "clip.webm" });
    defer std.testing.allocator.free(file_path);
    try std.testing.expectError(error.LocalReadNotAllowed, readLocalVideo(std.testing.allocator, file_path, .{}));
}

test "readLocalVideo reads a valid file within allowed_dirs" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "clip.webm", .data = "\x1A\x45\xDF\xA3\x00\x00\x00\x00\x00\x00\x00\x00" });
    const dir_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "clip.webm" });
    defer std.testing.allocator.free(file_path);
    const result = try readLocalVideo(std.testing.allocator, file_path, .{ .allowed_dirs = &.{dir_path} });
    defer std.testing.allocator.free(result.data);
    try std.testing.expectEqualStrings("video/webm", result.mime_type);
}

test "readLocalVideo rejects over-cap file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    // 20-byte mp4 — over a deliberately tiny 10-byte cap.
    try tmp_dir.dir.writeFile(.{ .sub_path = "big.mp4", .data = "\x00\x00\x00\x18ftypisom\x00\x00\x00\x00" });
    const dir_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "big.mp4" });
    defer std.testing.allocator.free(file_path);
    try std.testing.expectError(error.VideoTooLarge, readLocalVideo(std.testing.allocator, file_path, .{
        .allowed_dirs = &.{dir_path},
        .max_video_size_bytes = 10,
    }));
}

test "prepareMessagesForProvider with VIDEO data URI creates video_base64 part" {
    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user("Analyze [VIDEO:data:video/mp4;base64,AAAA]"),
    };
    const result = try prepareMessagesForProvider(arena, &msgs, .{});
    try std.testing.expect(result[0].content_parts != null);
    var saw_video = false;
    for (result[0].content_parts.?) |p| {
        if (p == .video_base64) {
            saw_video = true;
            try std.testing.expectEqualStrings("video/mp4", p.video_base64.media_type);
            try std.testing.expectEqualStrings("AAAA", p.video_base64.data);
        }
    }
    try std.testing.expect(saw_video);
}

test "prepareMessagesForProvider with VIDEO local file creates video_base64 part" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "clip.webm", .data = "\x1A\x45\xDF\xA3\x00\x00\x00\x00\x00\x00\x00\x00" });
    const dir_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "clip.webm" });
    defer std.testing.allocator.free(file_path);

    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user(try std.fmt.allocPrint(std.testing.allocator, "Watch [VIDEO:{s}]", .{file_path})),
    };
    defer std.testing.allocator.free(msgs[0].content);

    const result = try prepareMessagesForProvider(arena, &msgs, .{ .allowed_dirs = &.{dir_path} });
    try std.testing.expect(result[0].content_parts != null);
    var saw_video = false;
    for (result[0].content_parts.?) |p| {
        if (p == .video_base64) {
            saw_video = true;
            try std.testing.expectEqualStrings("video/webm", p.video_base64.media_type);
        }
    }
    try std.testing.expect(saw_video);
}

test "prepareMessagesForProvider over-cap video skipped with note" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    // 20-byte mp4 — over the tiny 10-byte cap configured below.
    try tmp_dir.dir.writeFile(.{ .sub_path = "big.mp4", .data = "\x00\x00\x00\x18ftypisom\x00\x00\x00\x00" });
    const dir_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "big.mp4" });
    defer std.testing.allocator.free(file_path);

    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user(try std.fmt.allocPrint(std.testing.allocator, "Examine [VIDEO:{s}]", .{file_path})),
    };
    defer std.testing.allocator.free(msgs[0].content);

    const result = try prepareMessagesForProvider(arena, &msgs, .{
        .allowed_dirs = &.{dir_path},
        .max_video_size_bytes = 10,
    });
    var saw_video = false;
    var saw_too_large_note = false;
    for (result[0].content_parts.?) |p| {
        switch (p) {
            .video_base64 => saw_video = true,
            .text => |t| {
                if (std.mem.indexOf(u8, t, "Video too large") != null) saw_too_large_note = true;
            },
            else => {},
        }
    }
    try std.testing.expect(!saw_video);
    try std.testing.expect(saw_too_large_note);
}

test "prepareMessagesForProvider image and video in same message" {
    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user("See [IMAGE:data:image/png;base64,iVBORw0KGgo=] then [VIDEO:data:video/mp4;base64,AAAA]"),
    };
    const result = try prepareMessagesForProvider(arena, &msgs, .{});
    var saw_image = false;
    var saw_video = false;
    for (result[0].content_parts.?) |p| {
        switch (p) {
            .image_base64 => saw_image = true,
            .video_base64 => saw_video = true,
            else => {},
        }
    }
    try std.testing.expect(saw_image);
    try std.testing.expect(saw_video);
}

test "prepareMessagesForProvider remote video URL emits unsupported note" {
    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user("[VIDEO:https://example.com/clip.mp4]"),
    };
    const result = try prepareMessagesForProvider(arena, &msgs, .{ .allow_remote_fetch = true });
    var saw_video = false;
    var saw_note = false;
    for (result[0].content_parts.?) |p| {
        switch (p) {
            .video_base64 => saw_video = true,
            .text => |t| {
                if (std.mem.indexOf(u8, t, "Remote video URLs are not supported") != null) saw_note = true;
            },
            else => {},
        }
    }
    try std.testing.expect(!saw_video);
    try std.testing.expect(saw_note);
}

test "prepareMessagesForProvider exceeds max_videos emits note" {
    const arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    var arena_mut = arena_impl;
    defer arena_mut.deinit();
    const arena = arena_mut.allocator();

    var msgs = [_]ChatMessage{
        ChatMessage.user("[VIDEO:data:video/mp4;base64,AAAA] [VIDEO:data:video/webm;base64,BBBB]"),
    };
    // Default config: max_videos = 1.
    const result = try prepareMessagesForProvider(arena, &msgs, .{});
    var video_count: usize = 0;
    var saw_limit_note = false;
    for (result[0].content_parts.?) |p| {
        switch (p) {
            .video_base64 => video_count += 1,
            .text => |t| {
                if (std.mem.indexOf(u8, t, "additional video(s) ignored") != null) saw_limit_note = true;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), video_count);
    try std.testing.expect(saw_limit_note);
}
