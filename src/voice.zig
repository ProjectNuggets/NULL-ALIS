//! Voice transcription via Groq Whisper API (OpenAI-compatible).
//!
//! Reads an audio file, builds a multipart/form-data POST request,
//! and sends it to the Groq transcription endpoint. Returns the
//! transcribed text as an owned slice.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const json_util = @import("json_util.zig");
const http_util = @import("http_util.zig");
const telegram_token = @import("telegram_token.zig");
const observability = @import("observability.zig");

const log = std.log.scoped(.voice);

/// Emit a system_notice via the optional observer when a multimodal path
/// fails. Binding rule: no silent fallback. Callers that have an observer
/// handle pass it; callers that don't pass null and the notice is dropped
/// at this level (the existing std.log warnings still fire).
fn emitMultimodalFailureNotice(
    obs: ?*observability.Observer,
    detail: []const u8,
) void {
    const observer = obs orelse return;
    const event = observability.ObserverEvent{ .system_notice = .{
        .kind = "multimodal_failure",
        .severity = "warning",
        .message = "Voice/transcription step failed. Text channel unaffected; the message may have arrived without audio transcript.",
        .detail = detail,
    } };
    observer.recordEvent(&event);
}

pub const TelegramSttMetrics = struct {
    transcriber_configured: u64,
    transcription_attempted: u64,
    transcription_succeeded: u64,
    transcription_failed: u64,
    transcription_skipped_no_transcriber: u64,
    failure_get_file: u64,
    failure_download: u64,
    failure_transcriber: u64,
    failure_empty_transcript: u64,
};

var telegram_stt_transcriber_configured_total = std.atomic.Value(u64).init(0);
var telegram_stt_transcription_attempted_total = std.atomic.Value(u64).init(0);
var telegram_stt_transcription_succeeded_total = std.atomic.Value(u64).init(0);
var telegram_stt_transcription_failed_total = std.atomic.Value(u64).init(0);
var telegram_stt_transcription_skipped_no_transcriber_total = std.atomic.Value(u64).init(0);
var telegram_stt_failure_get_file_total = std.atomic.Value(u64).init(0);
var telegram_stt_failure_download_total = std.atomic.Value(u64).init(0);
var telegram_stt_failure_transcriber_total = std.atomic.Value(u64).init(0);
var telegram_stt_failure_empty_transcript_total = std.atomic.Value(u64).init(0);

pub fn markTelegramTranscriberConfigured() void {
    _ = telegram_stt_transcriber_configured_total.fetchAdd(1, .monotonic);
}

pub fn telegramSttMetricsSnapshot() TelegramSttMetrics {
    return .{
        .transcriber_configured = telegram_stt_transcriber_configured_total.load(.monotonic),
        .transcription_attempted = telegram_stt_transcription_attempted_total.load(.monotonic),
        .transcription_succeeded = telegram_stt_transcription_succeeded_total.load(.monotonic),
        .transcription_failed = telegram_stt_transcription_failed_total.load(.monotonic),
        .transcription_skipped_no_transcriber = telegram_stt_transcription_skipped_no_transcriber_total.load(.monotonic),
        .failure_get_file = telegram_stt_failure_get_file_total.load(.monotonic),
        .failure_download = telegram_stt_failure_download_total.load(.monotonic),
        .failure_transcriber = telegram_stt_failure_transcriber_total.load(.monotonic),
        .failure_empty_transcript = telegram_stt_failure_empty_transcript_total.load(.monotonic),
    };
}

fn markTelegramSttAttempted() void {
    _ = telegram_stt_transcription_attempted_total.fetchAdd(1, .monotonic);
}

fn markTelegramSttSucceeded() void {
    _ = telegram_stt_transcription_succeeded_total.fetchAdd(1, .monotonic);
}

fn markTelegramSttFailed() void {
    _ = telegram_stt_transcription_failed_total.fetchAdd(1, .monotonic);
}

fn markTelegramSttSkippedNoTranscriber() void {
    _ = telegram_stt_transcription_skipped_no_transcriber_total.fetchAdd(1, .monotonic);
}

fn markTelegramSttFailedGetFile() void {
    _ = telegram_stt_failure_get_file_total.fetchAdd(1, .monotonic);
}

fn markTelegramSttFailedDownload() void {
    _ = telegram_stt_failure_download_total.fetchAdd(1, .monotonic);
}

fn markTelegramSttFailedTranscriber() void {
    _ = telegram_stt_failure_transcriber_total.fetchAdd(1, .monotonic);
}

fn markTelegramSttFailedEmptyTranscript() void {
    _ = telegram_stt_failure_empty_transcript_total.fetchAdd(1, .monotonic);
}

fn parseTelegramFilePathFromResponse(allocator: std.mem.Allocator, resp: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch
        return error.InvalidResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    if (parsed.value.object.get("ok")) |ok_val| {
        if (ok_val == .bool and !ok_val.bool) {
            if (parsed.value.object.get("description")) |description| {
                if (description == .string) {
                    log.warn("telegram getFile rejected: {s}", .{description.string});
                    const lowered = description.string;
                    if (std.mem.indexOf(u8, lowered, "file is too big") != null) {
                        return error.TelegramFileTooBig;
                    }
                }
            }
            return error.TelegramApiRejected;
        }
    }

    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const fp_val = result.object.get("file_path") orelse return error.InvalidResponse;
    if (fp_val != .string) return error.InvalidResponse;
    return try allocator.dupe(u8, fp_val.string);
}

fn isUnreservedQueryByte(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or
        (ch >= 'a' and ch <= 'z') or
        (ch >= '0' and ch <= '9') or
        ch == '-' or ch == '_' or ch == '.' or ch == '~';
}

fn appendPercentEncodedQueryValue(
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
) !void {
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        if (isUnreservedQueryByte(ch)) {
            try list.append(allocator, ch);
        } else {
            try list.append(allocator, '%');
            try list.append(allocator, hex[(ch >> 4) & 0x0F]);
            try list.append(allocator, hex[ch & 0x0F]);
        }
    }
}

fn isTelegramBotTokenShape(value: []const u8) bool {
    return telegram_token.is_bot_token_shape(value);
}

fn normalizeTelegramBotToken(value: []const u8) []const u8 {
    return telegram_token.normalize_bot_token(value);
}

fn isTelegramBotTokenChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_' or
        ch == '-';
}

fn logTelegramTokenShapeFailure(token: []const u8) void {
    const colon_idx_opt = std.mem.indexOfScalar(u8, token, ':');
    const colon_pos: isize = if (colon_idx_opt) |idx| @intCast(idx) else -1;

    var first_bad_idx: isize = -1;
    var first_bad_byte: u8 = 0;
    var found_bad = false;

    if (colon_idx_opt) |colon_idx| {
        for (token[0..colon_idx], 0..) |ch, i| {
            if (ch < '0' or ch > '9') {
                first_bad_idx = @intCast(i);
                first_bad_byte = ch;
                found_bad = true;
                break;
            }
        }
        if (!found_bad and colon_idx + 1 < token.len) {
            for (token[colon_idx + 1 ..], 0..) |ch, rel_i| {
                if (!isTelegramBotTokenChar(ch)) {
                    first_bad_idx = @intCast(colon_idx + 1 + rel_i);
                    first_bad_byte = ch;
                    found_bad = true;
                    break;
                }
            }
        }
    } else {
        for (token, 0..) |ch, i| {
            if (!(isTelegramBotTokenChar(ch) or (ch >= '0' and ch <= '9'))) {
                first_bad_idx = @intCast(i);
                first_bad_byte = ch;
                found_bad = true;
                break;
            }
        }
    }

    if (found_bad) {
        log.warn("telegram token shape invalid len={d} colon_pos={d} bad_idx={d} bad_byte=0x{x}", .{
            token.len,
            colon_pos,
            first_bad_idx,
            first_bad_byte,
        });
    } else {
        log.warn("telegram token shape invalid len={d} colon_pos={d} bad_idx={d}", .{
            token.len,
            colon_pos,
            first_bad_idx,
        });
    }
}

fn buildTelegramGetFileQueryUrl(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    file_id: []const u8,
) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, "https://api.telegram.org/bot");
    try list.appendSlice(allocator, bot_token);
    try list.appendSlice(allocator, "/getFile?file_id=");
    try appendPercentEncodedQueryValue(&list, allocator, file_id);
    return try list.toOwnedSlice(allocator);
}

fn getPid() i32 {
    if (builtin.os.tag == .linux) return @intCast(std.os.linux.getpid());
    if (builtin.os.tag == .macos) return std.c.getpid();
    return 0;
}

fn copyTelegramBotTokenForStt(allocator: std.mem.Allocator, bot_token: []const u8) ![]u8 {
    return allocator.dupe(u8, bot_token);
}

pub const TranscribeOptions = struct {
    model: []const u8 = "whisper-large-v3",
    language: ?[]const u8 = null,
};

pub const SynthesizeOptions = struct {
    endpoint: ?[]const u8 = null,
    model: ?[]const u8 = null,
    voice: []const u8 = "alloy",
    format: []const u8 = "mp3",
    timeout_ms: u32 = 60_000,
};

pub const TranscribeError = error{
    FileReadFailed,
    BoundaryGenerationFailed,
    ApiRequestFailed,
    InvalidResponse,
} || std.mem.Allocator.Error;

pub const SynthesizeError = error{
    UnsupportedProvider,
    ApiRequestFailed,
    InvalidResponse,
    WriteFailed,
} || std.mem.Allocator.Error;

// ════════════════════════════════════════════════════════════════════════════
// Transcriber vtable interface
// ════════════════════════════════════════════════════════════════════════════

pub const Transcriber = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        transcribe: *const fn (*anyopaque, std.mem.Allocator, []const u8) TranscribeError!?[]const u8,
    };

    pub fn transcribe(self: Transcriber, alloc: std.mem.Allocator, path: []const u8) TranscribeError!?[]const u8 {
        return self.vtable.transcribe(self.ptr, alloc, path);
    }
};

pub const WhisperTranscriber = struct {
    endpoint: []const u8,
    api_key: []const u8,
    model: []const u8,
    language: ?[]const u8,

    fn vtableTranscribe(ptr: *anyopaque, alloc: std.mem.Allocator, path: []const u8) TranscribeError!?[]const u8 {
        const self: *WhisperTranscriber = @ptrCast(@alignCast(ptr));
        const result = try transcribeFile(alloc, self.api_key, self.endpoint, path, .{
            .model = self.model,
            .language = self.language,
        });
        return result;
    }

    pub const vtable = Transcriber.VTable{
        .transcribe = &vtableTranscribe,
    };

    pub fn transcriber(self: *WhisperTranscriber) Transcriber {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

/// Resolve transcription endpoint for a given provider name.
pub fn resolveTranscriptionEndpoint(provider: []const u8, explicit_endpoint: ?[]const u8) []const u8 {
    if (explicit_endpoint) |ep| return ep;
    if (std.mem.eql(u8, provider, "openai")) return "https://api.openai.com/v1/audio/transcriptions";
    if (std.mem.eql(u8, provider, "groq")) return "https://api.groq.com/openai/v1/audio/transcriptions";
    // For unknown providers, try OpenAI-compatible endpoint
    return "https://api.groq.com/openai/v1/audio/transcriptions";
}

/// Resolve text-to-speech endpoint for OpenAI-compatible providers.
pub fn resolveSynthesisEndpoint(provider: []const u8, explicit_endpoint: ?[]const u8) ?[]const u8 {
    if (explicit_endpoint) |ep| return ep;
    if (std.mem.eql(u8, provider, "openai")) return "https://api.openai.com/v1/audio/speech";
    if (std.mem.eql(u8, provider, "openrouter")) return "https://openrouter.ai/api/v1/audio/speech";
    if (std.mem.eql(u8, provider, "together") or std.mem.eql(u8, provider, "together-ai")) {
        return "https://api.together.xyz/v1/audio/speech";
    }
    return null;
}

/// Synthesize text into a temporary audio file. Caller owns returned path.
pub fn synthesizeTextToTempAudio(
    allocator: std.mem.Allocator,
    provider: []const u8,
    api_key: []const u8,
    text: []const u8,
    opts: SynthesizeOptions,
) SynthesizeError![]u8 {
    const endpoint = resolveSynthesisEndpoint(provider, opts.endpoint) orelse return error.UnsupportedProvider;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InvalidResponse;

    const model = opts.model orelse defaultSynthesisModel(provider);
    if (model.len == 0) return error.UnsupportedProvider;

    const format = sanitizeSynthesisFormat(opts.format);

    const body = buildSynthesisRequestBody(allocator, model, opts.voice, format, text) catch return error.ApiRequestFailed;
    defer allocator.free(body);

    var auth_buf: [256]u8 = undefined;
    const auth_hdr = std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{api_key}) catch
        return error.ApiRequestFailed;
    const headers = [_][]const u8{
        auth_hdr,
        "Content-Type: application/json",
    };

    const response = http_util.request_with_mode(
        allocator,
        .{ .mode = .curl_only },
        .{
            .subsystem = .providers,
            .method = "POST",
            .url = endpoint,
            .headers = &headers,
            .body = body,
            .timeout_ms = opts.timeout_ms,
            .max_response_bytes = 8 * 1024 * 1024,
        },
    ) catch return error.ApiRequestFailed;
    defer allocator.free(response.body);

    if (response.status_code < 200 or response.status_code >= 300) {
        return error.ApiRequestFailed;
    }
    if (response.body.len == 0) return error.InvalidResponse;
    if (looksLikeJsonError(response.body)) return error.ApiRequestFailed;

    const tmp_dir = platform.getTempDir(allocator) catch return error.WriteFailed;
    defer allocator.free(tmp_dir);
    const ts = std.time.milliTimestamp();
    var path_buf: [512]u8 = undefined;
    const audio_path = std.fmt.bufPrint(
        &path_buf,
        "{s}/nullalis_tts_{d}_{d}.{s}",
        .{ tmp_dir, getPid(), ts, format },
    ) catch return error.WriteFailed;

    var path_z_buf: [512]u8 = undefined;
    if (audio_path.len + 1 > path_z_buf.len) return error.WriteFailed;
    @memcpy(path_z_buf[0..audio_path.len], audio_path);
    path_z_buf[audio_path.len] = 0;
    const audio_path_z: [:0]const u8 = path_z_buf[0..audio_path.len :0];

    const out_file = std.fs.createFileAbsolute(audio_path_z, .{}) catch return error.WriteFailed;
    defer out_file.close();
    out_file.writeAll(response.body) catch return error.WriteFailed;

    return try allocator.dupe(u8, audio_path);
}

/// Transcribe an audio file using the Groq Whisper API.
///
/// Reads the file at `file_path`, builds a multipart/form-data request,
/// POSTs to the Groq transcription endpoint, and returns the transcribed text.
/// Caller owns the returned slice.
pub fn transcribeFile(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    endpoint: []const u8,
    file_path: []const u8,
    opts: TranscribeOptions,
) TranscribeError![]const u8 {
    // Generate random boundary (16 hex chars)
    const boundary = generateBoundary() catch return error.BoundaryGenerationFailed;

    // Build temp file path (platform-aware temp dir)
    const tmp_dir = platform.getTempDir(allocator) catch return error.FileReadFailed;
    defer allocator.free(tmp_dir);
    var tmp_path_buf: [256]u8 = undefined;
    var tmp_fbs = std.io.fixedBufferStream(&tmp_path_buf);
    tmp_fbs.writer().print("{s}/nullalis_voice_{d}.bin", .{ tmp_dir, getPid() }) catch
        return error.FileReadFailed;
    const tmp_path_len = tmp_fbs.pos;
    tmp_path_buf[tmp_path_len] = 0;
    const tmp_path: [:0]const u8 = tmp_path_buf[0..tmp_path_len :0];

    // Write multipart body directly to temp file (avoids holding file_data + body in memory)
    writeMultipartToTempFile(tmp_path, file_path, &boundary, opts) catch
        return error.FileReadFailed;
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Build headers
    var content_type_buf: [128]u8 = undefined;
    var ct_fbs = std.io.fixedBufferStream(&content_type_buf);
    ct_fbs.writer().print("Content-Type: multipart/form-data; boundary={s}", .{&boundary}) catch
        return error.BoundaryGenerationFailed;
    const content_type_hdr = ct_fbs.getWritten();

    var auth_buf: [256]u8 = undefined;
    var auth_fbs = std.io.fixedBufferStream(&auth_buf);
    auth_fbs.writer().print("Authorization: Bearer {s}", .{api_key}) catch
        return error.ApiRequestFailed;
    const auth_hdr = auth_fbs.getWritten();

    // POST via curl using --data-binary @tempfile
    const resp = curlPostFromFile(
        allocator,
        endpoint,
        tmp_path,
        &.{ auth_hdr, content_type_hdr },
    ) catch return error.ApiRequestFailed;
    defer allocator.free(resp);

    // Parse {"text":"..."} from response
    return parseTranscriptionText(allocator, resp) catch return error.InvalidResponse;
}

/// Generate a random 32-character hex boundary string.
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

fn defaultSynthesisModel(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "openai") or
        std.mem.eql(u8, provider, "openrouter") or
        std.mem.eql(u8, provider, "together") or
        std.mem.eql(u8, provider, "together-ai"))
    {
        return "gpt-4o-mini-tts";
    }
    return "";
}

fn sanitizeSynthesisFormat(format: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(format, "wav")) return "wav";
    if (std.ascii.eqlIgnoreCase(format, "ogg")) return "ogg";
    if (std.ascii.eqlIgnoreCase(format, "m4a")) return "m4a";
    return "mp3";
}

fn normalizeTranscriptionLanguage(language: ?[]const u8) ?[]const u8 {
    const raw = language orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "auto")) return null;
    return trimmed;
}

fn buildSynthesisRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    voice_name: []const u8,
    format: []const u8,
    text: []const u8,
) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, "{");
    try json_util.appendJsonKeyValue(&body, allocator, "model", model);
    try body.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&body, allocator, "voice", voice_name);
    try body.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&body, allocator, "response_format", format);
    try body.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&body, allocator, "input", text);
    try body.appendSlice(allocator, "}");
    return try body.toOwnedSlice(allocator);
}

fn looksLikeJsonError(body: []const u8) bool {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return false;
    return std.mem.indexOf(u8, trimmed, "\"error\"") != null;
}

/// Build the multipart/form-data body.
fn buildMultipartBody(
    allocator: std.mem.Allocator,
    boundary: []const u8,
    file_data: []const u8,
    opts: TranscribeOptions,
) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);

    // Part: file
    try body.appendSlice(allocator, "--");
    try body.appendSlice(allocator, boundary);
    try body.appendSlice(allocator, "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.ogg\"\r\nContent-Type: audio/ogg\r\n\r\n");
    try body.appendSlice(allocator, file_data);
    try body.appendSlice(allocator, "\r\n");

    // Part: model
    try body.appendSlice(allocator, "--");
    try body.appendSlice(allocator, boundary);
    try body.appendSlice(allocator, "\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n");
    try body.appendSlice(allocator, opts.model);
    try body.appendSlice(allocator, "\r\n");

    // Part: language (optional)
    if (normalizeTranscriptionLanguage(opts.language)) |lang| {
        try body.appendSlice(allocator, "--");
        try body.appendSlice(allocator, boundary);
        try body.appendSlice(allocator, "\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n");
        try body.appendSlice(allocator, lang);
        try body.appendSlice(allocator, "\r\n");
    }

    // Closing boundary
    try body.appendSlice(allocator, "--");
    try body.appendSlice(allocator, boundary);
    try body.appendSlice(allocator, "--\r\n");

    return body.toOwnedSlice(allocator);
}

/// Write multipart/form-data directly to a temp file, streaming the audio file
/// through without building the full body in memory.
/// This avoids holding both file_data and multipart body in RAM simultaneously.
fn writeMultipartToTempFile(
    tmp_path: [:0]const u8,
    audio_path: []const u8,
    boundary: []const u8,
    opts: TranscribeOptions,
) !void {
    const tmp_file = try std.fs.createFileAbsolute(tmp_path, .{});
    defer tmp_file.close();

    // Write file part header
    try tmp_file.writeAll("--");
    try tmp_file.writeAll(boundary);
    try tmp_file.writeAll("\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.ogg\"\r\nContent-Type: audio/ogg\r\n\r\n");

    // Stream audio file directly (no intermediate buffer)
    {
        const audio_file = try std.fs.openFileAbsolute(audio_path, .{});
        defer audio_file.close();
        var buf: [32768]u8 = undefined;
        while (true) {
            const n = try audio_file.read(&buf);
            if (n == 0) break;
            try tmp_file.writeAll(buf[0..n]);
        }
    }
    try tmp_file.writeAll("\r\n");

    // Write model part
    try tmp_file.writeAll("--");
    try tmp_file.writeAll(boundary);
    try tmp_file.writeAll("\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n");
    try tmp_file.writeAll(opts.model);
    try tmp_file.writeAll("\r\n");

    // Write language part (optional)
    if (normalizeTranscriptionLanguage(opts.language)) |lang| {
        try tmp_file.writeAll("--");
        try tmp_file.writeAll(boundary);
        try tmp_file.writeAll("\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n");
        try tmp_file.writeAll(lang);
        try tmp_file.writeAll("\r\n");
    }

    // Closing boundary
    try tmp_file.writeAll("--");
    try tmp_file.writeAll(boundary);
    try tmp_file.writeAll("--\r\n");
}

/// Parse the "text" field from a JSON response like {"text":"transcribed text here"}.
fn parseTranscriptionText(allocator: std.mem.Allocator, json_resp: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_resp, .{}) catch
        return error.InvalidResponse;
    defer parsed.deinit();

    const text_val = parsed.value.object.get("text") orelse return error.InvalidResponse;
    if (text_val != .string) return error.InvalidResponse;
    return try allocator.dupe(u8, text_val.string);
}

/// HTTP POST via curl subprocess, reading body from a file on disk.
/// Used for multipart/form-data where body has already been written to a temp file.
fn curlPostFromFile(
    allocator: std.mem.Allocator,
    url: []const u8,
    file_path: [:0]const u8,
    headers: []const []const u8,
) ![]u8 {
    // Build data-binary arg: @/path/to/file
    var data_arg_buf: [300]u8 = undefined;
    var data_fbs = std.io.fixedBufferStream(&data_arg_buf);
    try data_fbs.writer().print("@{s}", .{file_path});
    const data_arg = data_fbs.getWritten();

    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-s";
    argc += 1;
    argv_buf[argc] = "-X";
    argc += 1;
    argv_buf[argc] = "POST";
    argc += 1;

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

    const stdout = child.stdout.?.readToEndAlloc(allocator, 4 * 1024 * 1024) catch return error.CurlReadError;

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
// Telegram Voice Integration
// ════════════════════════════════════════════════════════════════════════════

/// Download a Telegram voice/audio file and transcribe it.
/// Returns the transcribed text, or null if transcription is unavailable
/// (no Transcriber configured or file download fails).
pub fn transcribeTelegramVoice(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    file_id: []const u8,
    t: ?Transcriber,
    proxy: ?[]const u8,
    obs: ?*observability.Observer,
) ?[]const u8 {
    const transcr = t orelse {
        markTelegramSttSkippedNoTranscriber();
        log.info("telegram.stt.skip reason=no_transcriber", .{});
        return null;
    };
    markTelegramSttAttempted();

    // Own token bytes for the full STT flow to avoid caller-lifetime issues.
    const bot_token_owned = copyTelegramBotTokenForStt(allocator, bot_token) catch return null;
    defer allocator.free(bot_token_owned);

    // 1. Call getFile to get file_path
    const tg_file_path = getFilePathWithRetry(allocator, bot_token_owned, file_id, proxy) catch |err| {
        markTelegramSttFailed();
        markTelegramSttFailedGetFile();
        log.err("getFile failed: {}", .{err});
        log.warn("telegram.stt.fail reason=get_file_failed err={}", .{err});
        emitMultimodalFailureNotice(obs, "telegram STT: getFile failed");
        return null;
    };
    defer allocator.free(tg_file_path);

    // 2. Download file via Telegram API
    const local_path = downloadTelegramFile(allocator, bot_token_owned, tg_file_path, proxy) catch |err| {
        markTelegramSttFailed();
        markTelegramSttFailedDownload();
        log.err("download failed: {}", .{err});
        log.warn("telegram.stt.fail reason=download_failed err={}", .{err});
        emitMultimodalFailureNotice(obs, "telegram STT: download failed");
        return null;
    };
    defer {
        // Clean up temp file
        std.fs.deleteFileAbsolute(local_path) catch {};
        allocator.free(local_path);
    }

    // 3. Transcribe via vtable
    const text = transcr.transcribe(allocator, local_path) catch |err| {
        markTelegramSttFailed();
        markTelegramSttFailedTranscriber();
        log.err("transcription failed: {}", .{err});
        log.warn("telegram.stt.fail reason=transcriber_failed err={}", .{err});
        emitMultimodalFailureNotice(obs, "telegram STT: transcriber failed");
        return null;
    };
    if (text != null) {
        markTelegramSttSucceeded();
        log.info("telegram.stt.success", .{});
    } else {
        markTelegramSttFailed();
        markTelegramSttFailedEmptyTranscript();
        log.warn("telegram.stt.fail reason=empty_transcript", .{});
        emitMultimodalFailureNotice(obs, "telegram STT: empty transcript");
    }

    return text;
}

/// Call Telegram getFile API and extract the file_path from the response.
fn getFilePathOnce(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    file_id: []const u8,
    proxy: ?[]const u8,
) ![]u8 {
    const normalized_bot_token = normalizeTelegramBotToken(bot_token);
    if (!isTelegramBotTokenShape(normalized_bot_token)) {
        logTelegramTokenShapeFailure(normalized_bot_token);
        log.warn("telegram getFile refused: invalid bot token shape len={d}", .{normalized_bot_token.len});
        return error.CurlFailed;
    }
    const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/getFile", .{normalized_bot_token});
    defer allocator.free(url);

    // Build request body
    var body_list: std.ArrayListUnmanaged(u8) = .empty;
    defer body_list.deinit(allocator);
    try body_list.appendSlice(allocator, "{\"file_id\":");
    try json_util.appendJsonString(&body_list, allocator, file_id);
    try body_list.appendSlice(allocator, "}");

    const post_resp = http_util.curlRequest(
        allocator,
        "POST",
        url,
        &.{"Content-Type: application/json"},
        body_list.items,
        proxy,
        "15",
    ) catch |post_err| {
        log.warn("telegram getFile post request failed: {}; trying query fallback", .{post_err});
        return getFilePathViaQuery(allocator, normalized_bot_token, file_id, proxy);
    };
    defer allocator.free(post_resp.body);

    if (post_resp.status_code < 200 or post_resp.status_code >= 300) {
        const preview_len: usize = @min(post_resp.body.len, 220);
        log.warn("telegram getFile post status={d} body_len={d} body_preview={s}; trying query fallback", .{
            post_resp.status_code,
            post_resp.body.len,
            post_resp.body[0..preview_len],
        });
        return getFilePathViaQuery(allocator, normalized_bot_token, file_id, proxy);
    }

    return parseTelegramFilePathFromResponse(allocator, post_resp.body) catch |post_parse_err| {
        log.warn("telegram getFile post parse failed: {}; trying query fallback", .{post_parse_err});
        return getFilePathViaQuery(allocator, normalized_bot_token, file_id, proxy);
    };
}

fn shouldRetryGetFileError(err: anyerror) bool {
    return switch (err) {
        error.TelegramApiRejected,
        error.TelegramFileTooBig,
        => false,
        else => true,
    };
}

fn classifyTelegramGetFileFailure(allocator: std.mem.Allocator, body: []const u8) anyerror {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        const preview_len: usize = @min(body.len, 220);
        log.warn("telegram getFile rejected (non-json body preview): {s}", .{body[0..preview_len]});
        return error.TelegramApiRejected;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.TelegramApiRejected;

    if (parsed.value.object.get("description")) |description| {
        if (description == .string) {
            log.warn("telegram getFile rejected: {s}", .{description.string});
            if (std.mem.indexOf(u8, description.string, "file is too big") != null) {
                return error.TelegramFileTooBig;
            }
        }
    }
    return error.TelegramApiRejected;
}

fn getFilePathViaQuery(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    file_id: []const u8,
    proxy: ?[]const u8,
) ![]u8 {
    const normalized_bot_token = normalizeTelegramBotToken(bot_token);
    if (!isTelegramBotTokenShape(normalized_bot_token)) {
        logTelegramTokenShapeFailure(normalized_bot_token);
        return error.CurlFailed;
    }
    const get_url = try buildTelegramGetFileQueryUrl(allocator, normalized_bot_token, file_id);
    defer allocator.free(get_url);

    const resp = try http_util.curlRequest(allocator, "GET", get_url, &.{}, null, proxy, "15");
    defer allocator.free(resp.body);

    if (resp.status_code < 200 or resp.status_code >= 300) {
        const preview_len: usize = @min(resp.body.len, 220);
        log.warn("telegram getFile query status={d} body_len={d} body_preview={s}", .{
            resp.status_code,
            resp.body.len,
            resp.body[0..preview_len],
        });
        return classifyTelegramGetFileFailure(allocator, resp.body);
    }
    return parseTelegramFilePathFromResponse(allocator, resp.body);
}

fn getFilePathWithRetry(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    file_id: []const u8,
    proxy: ?[]const u8,
) ![]u8 {
    const max_attempts: u8 = 3;
    var attempt: u8 = 1;
    while (attempt <= max_attempts) : (attempt += 1) {
        const file_path = getFilePathOnce(allocator, bot_token, file_id, proxy) catch |err| {
            if (attempt >= max_attempts or !shouldRetryGetFileError(err)) {
                return err;
            }
            log.warn("telegram getFile transient failure attempt={d}/{d}: {}; retrying", .{ attempt, max_attempts, err });
            std.Thread.sleep(@as(u64, attempt) * 200 * std.time.ns_per_ms);
            continue;
        };
        return file_path;
    }
    return error.TelegramApiRejected;
}

/// Download a file from Telegram and save to temp dir. Returns the local path (owned).
fn downloadTelegramFile(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    tg_file_path: []const u8,
    proxy: ?[]const u8,
) ![]u8 {
    const normalized_bot_token = normalizeTelegramBotToken(bot_token);
    if (!isTelegramBotTokenShape(normalized_bot_token)) {
        logTelegramTokenShapeFailure(normalized_bot_token);
        return error.CurlFailed;
    }
    var url_buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&url_buf);
    try fbs.writer().print("https://api.telegram.org/file/bot{s}/{s}", .{ normalized_bot_token, tg_file_path });
    const url = fbs.getWritten();

    const data = try http_util.curlGetWithProxy(allocator, url, &.{}, "30", proxy);
    defer allocator.free(data);

    // Save to temp file (platform-aware temp dir)
    const tmp_dir = platform.getTempDir(allocator) catch return error.OutOfMemory;
    defer allocator.free(tmp_dir);
    const pid = getPid();
    var path_buf: [256]u8 = undefined;
    var path_fbs = std.io.fixedBufferStream(&path_buf);
    try path_fbs.writer().print("{s}/nullalis_tg_voice_{d}.ogg", .{ tmp_dir, pid });
    const local_path = path_fbs.getWritten();

    var z_buf: [256]u8 = undefined;
    @memcpy(z_buf[0..local_path.len], local_path);
    z_buf[local_path.len] = 0;
    const local_path_z: [:0]const u8 = z_buf[0..local_path.len :0];

    {
        const f = try std.fs.createFileAbsolute(local_path_z, .{});
        defer f.close();
        try f.writeAll(data);
    }

    return try allocator.dupe(u8, local_path);
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "voice TranscribeOptions defaults" {
    const opts = TranscribeOptions{};
    try std.testing.expectEqualStrings("whisper-large-v3", opts.model);
    try std.testing.expect(opts.language == null);
}

test "voice TranscribeOptions custom" {
    const opts = TranscribeOptions{
        .model = "whisper-large-v3-turbo",
        .language = "ru",
    };
    try std.testing.expectEqualStrings("whisper-large-v3-turbo", opts.model);
    try std.testing.expectEqualStrings("ru", opts.language.?);
}

test "voice generateBoundary produces 32 hex chars" {
    const boundary = try generateBoundary();
    try std.testing.expectEqual(@as(usize, 32), boundary.len);
    for (&boundary) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "voice generateBoundary produces different values" {
    const b1 = try generateBoundary();
    const b2 = try generateBoundary();
    // Extremely unlikely to be equal
    try std.testing.expect(!std.mem.eql(u8, &b1, &b2));
}

test "voice buildMultipartBody structure" {
    const allocator = std.testing.allocator;
    const boundary = "abcdef0123456789abcdef0123456789";
    const file_data = "fake audio data";

    const body = try buildMultipartBody(allocator, boundary, file_data, .{});
    defer allocator.free(body);

    // Check that boundary markers appear
    try std.testing.expect(std.mem.indexOf(u8, body, "--abcdef0123456789abcdef0123456789") != null);
    // Check file part
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "filename=\"audio.ogg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: audio/ogg") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "fake audio data") != null);
    // Check model part
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "whisper-large-v3") != null);
    // Check closing boundary
    try std.testing.expect(std.mem.indexOf(u8, body, "--abcdef0123456789abcdef0123456789--") != null);
}

test "voice buildMultipartBody with language" {
    const allocator = std.testing.allocator;
    const boundary = "abcdef0123456789abcdef0123456789";

    const body = try buildMultipartBody(allocator, boundary, "data", .{ .language = "en" });
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"language\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "en") != null);
}

test "voice buildMultipartBody without language" {
    const allocator = std.testing.allocator;
    const boundary = "abcdef0123456789abcdef0123456789";

    const body = try buildMultipartBody(allocator, boundary, "data", .{});
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"language\"") == null);
}

test "voice buildMultipartBody language auto omits language field" {
    const allocator = std.testing.allocator;
    const boundary = "abcdef0123456789abcdef0123456789";

    const body = try buildMultipartBody(allocator, boundary, "data", .{ .language = "auto" });
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"language\"") == null);
}

test "voice parseTranscriptionText valid" {
    const allocator = std.testing.allocator;
    const json = "{\"text\":\"Hello, world!\"}";
    const text = try parseTranscriptionText(allocator, json);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello, world!", text);
}

test "voice parseTranscriptionText unicode" {
    const allocator = std.testing.allocator;
    const json = "{\"text\":\"Héllo wörld\"}";
    const text = try parseTranscriptionText(allocator, json);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Héllo wörld", text);
}

test "voice parseTranscriptionText missing field" {
    const allocator = std.testing.allocator;
    const result = parseTranscriptionText(allocator, "{\"status\":\"ok\"}");
    try std.testing.expectError(error.InvalidResponse, result);
}

test "voice parseTranscriptionText invalid json" {
    const allocator = std.testing.allocator;
    const result = parseTranscriptionText(allocator, "not json");
    try std.testing.expectError(error.InvalidResponse, result);
}

test "voice parseTranscriptionText non-string text" {
    const allocator = std.testing.allocator;
    const result = parseTranscriptionText(allocator, "{\"text\":42}");
    try std.testing.expectError(error.InvalidResponse, result);
}

test "voice parseTranscriptionText empty text" {
    const allocator = std.testing.allocator;
    const text = try parseTranscriptionText(allocator, "{\"text\":\"\"}");
    defer allocator.free(text);
    try std.testing.expectEqualStrings("", text);
}

test "voice shouldRetryGetFileError classifies retryable and permanent failures" {
    try std.testing.expect(shouldRetryGetFileError(error.CurlFailed));
    try std.testing.expect(!shouldRetryGetFileError(error.TelegramApiRejected));
    try std.testing.expect(shouldRetryGetFileError(error.InvalidResponse));
}

test "voice buildTelegramGetFileQueryUrl percent-encodes file id" {
    const allocator = std.testing.allocator;
    const url = try buildTelegramGetFileQueryUrl(allocator, "123:ABC", "A/B+C=");
    defer allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "file_id=A%2FB%2BC%3D") != null);
}

test "voice normalizeTelegramBotToken unwraps quoted token" {
    const token = normalizeTelegramBotToken(" \"8622705808:AAFVrWAamFu8Q3Av4V_OdInaJr_7Qn-26CA\" ");
    try std.testing.expectEqualStrings("8622705808:AAFVrWAamFu8Q3Av4V_OdInaJr_7Qn-26CA", token);
    try std.testing.expect(isTelegramBotTokenShape(token));
}

test "voice normalizeTelegramBotToken extracts candidate from wrapped content" {
    const wrapped = "{\"key\":\"telegram_bot_token\",\"value\":\"8622705808:AAFVrWAamFu8Q3Av4V_OdInaJr_7Qn-26CA\"}";
    const token = normalizeTelegramBotToken(wrapped);
    try std.testing.expectEqualStrings("8622705808:AAFVrWAamFu8Q3Av4V_OdInaJr_7Qn-26CA", token);
    try std.testing.expect(isTelegramBotTokenShape(token));
}

test "voice copyTelegramBotTokenForStt returns owned copy" {
    var src = [_]u8{ '1', '2', '3', ':', 'A', 'B', 'C' };
    const copied = try copyTelegramBotTokenForStt(std.testing.allocator, src[0..]);
    defer std.testing.allocator.free(copied);

    src[0] = '9';
    try std.testing.expectEqualStrings("123:ABC", copied);
}

test "voice transcribeFile returns error for nonexistent file" {
    const allocator = std.testing.allocator;
    const result = transcribeFile(allocator, "fake_key", "https://api.groq.com/openai/v1/audio/transcriptions", "/nonexistent/path/audio.ogg", .{});
    try std.testing.expectError(error.FileReadFailed, result);
}

test "voice transcribeTelegramVoice returns null without transcriber" {
    // No transcriber configured, so should return null
    const result = transcribeTelegramVoice(std.testing.allocator, "fake:token", "fake_file_id", null, null, null);
    try std.testing.expect(result == null);
}

test "voice WhisperTranscriber stores fields" {
    var wt = WhisperTranscriber{
        .endpoint = "https://api.groq.com/openai/v1/audio/transcriptions",
        .api_key = "gsk_test",
        .model = "whisper-large-v3",
        .language = "ru",
    };
    try std.testing.expectEqualStrings("gsk_test", wt.api_key);
    try std.testing.expectEqualStrings("ru", wt.language.?);
    // Vtable dispatches
    const t = wt.transcriber();
    try std.testing.expect(t.vtable == &WhisperTranscriber.vtable);
}

test "voice resolveTranscriptionEndpoint groq" {
    try std.testing.expectEqualStrings(
        "https://api.groq.com/openai/v1/audio/transcriptions",
        resolveTranscriptionEndpoint("groq", null),
    );
}

test "voice resolveTranscriptionEndpoint openai" {
    try std.testing.expectEqualStrings(
        "https://api.openai.com/v1/audio/transcriptions",
        resolveTranscriptionEndpoint("openai", null),
    );
}

test "voice resolveTranscriptionEndpoint explicit" {
    try std.testing.expectEqualStrings(
        "http://localhost:9090/v1/transcribe",
        resolveTranscriptionEndpoint("groq", "http://localhost:9090/v1/transcribe"),
    );
}

test "voice resolveTranscriptionEndpoint unknown falls back to groq" {
    // Unknown providers fall back to the Groq-compatible endpoint
    try std.testing.expectEqualStrings(
        "https://api.groq.com/openai/v1/audio/transcriptions",
        resolveTranscriptionEndpoint("some-unknown-provider", null),
    );
}

test "voice resolveSynthesisEndpoint openai" {
    try std.testing.expectEqualStrings(
        "https://api.openai.com/v1/audio/speech",
        resolveSynthesisEndpoint("openai", null).?,
    );
}

test "voice resolveSynthesisEndpoint unknown returns null" {
    try std.testing.expect(resolveSynthesisEndpoint("unknown-provider", null) == null);
}

test "voice sanitizeSynthesisFormat defaults to mp3" {
    try std.testing.expectEqualStrings("mp3", sanitizeSynthesisFormat("random"));
}

test "voice buildSynthesisRequestBody contains required fields" {
    const allocator = std.testing.allocator;
    const body = try buildSynthesisRequestBody(
        allocator,
        "gpt-4o-mini-tts",
        "alloy",
        "mp3",
        "Hello from test",
    );
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4o-mini-tts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"voice\":\"alloy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"response_format\":\"mp3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":\"Hello from test\"") != null);
}

test "voice looksLikeJsonError detects api error payloads" {
    try std.testing.expect(looksLikeJsonError("{\"error\":{\"message\":\"bad key\"}}"));
    try std.testing.expect(!looksLikeJsonError("audio-bytes"));
}
