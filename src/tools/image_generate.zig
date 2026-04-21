//! Image generation tool — agent reasons about a user request, calls the
//! Together.ai image API, saves the result to the agent's workspace, and
//! emits the URL + workspace path in its reply so the frontend can render
//! inline and the user can download or ask for edits.
//!
//! Invocation flow (what the agent does):
//!   1. User says: "make me a logo for X" / "draw Y" / "based on this URL,
//!      generate a similar image" / "edit the image I just sent".
//!   2. Agent reasons about intent and (for reference-based requests) may
//!      first call web_fetch / web_search to gather style cues, then builds
//!      a detailed prompt.
//!   3. Agent calls this tool with `prompt` (required) and optionally
//!      `reference_urls` (for image-to-image via FLUX.1-Kontext-pro).
//!   4. Tool calls Together, downloads the returned image bytes, writes to
//!      `<workspace>/images/img_<timestamp>_<rand>.<ext>`, emits markdown
//!      image (for frontend inline render) + workspace path (for agent's
//!      own follow-up edits) + Together URL (for preview-card scrapers +
//!      download-link fallback).
//!
//! Endpoint: https://api.together.xyz/v1/images/generations
//! Default model: black-forest-labs/FLUX.1-schnell
//!   - Serverless-tier compatible (FLUX.1-dev and FLUX.1-pro require Together's
//!     dedicated paid endpoints; verified 2026-04-21 via live 400 response).
//!   - $0.003/image — fits a $23/mo product comfortably even at hundreds of
//!     gens per user.
//!   - ~2-4s per image (4 steps). Fast enough that the generation feels
//!     immediate in the UI.
//!   - Operators with dedicated endpoints can override via `model_override`
//!     in config to use FLUX.1-dev or FLUX.1-pro for higher quality.
//! Image-to-image model: black-forest-labs/FLUX.1-Kontext-pro
//!   - Engaged when `reference_urls` is non-empty.
//!   - Single-image input.

const std = @import("std");
const root = @import("root.zig");
const platform = @import("../platform.zig");
const http_util = @import("../root.zig").http_util;
const net_security = @import("../root.zig").net_security;
const json_util = @import("../json_util.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const TOGETHER_IMAGE_URL = "https://api.together.xyz/v1/images/generations";
const TOGETHER_HOST = "api.together.xyz";
// CORRECTED 2026-04-21: FLUX.1-dev requires Together's DEDICATED endpoint
// (paid, not serverless). Serverless-tier accounts get 400 "Unable to access
// non-serverless model". Schnell IS available serverless. Verified via live
// API call against a serverless Together account. If the operator has a
// dedicated endpoint, they can override via model_override in config.
const DEFAULT_TEXT_MODEL = "black-forest-labs/FLUX.1-schnell";
const DEFAULT_IMG2IMG_MODEL = "black-forest-labs/FLUX.1-Kontext-pro";
const DEFAULT_WIDTH: u32 = 1024;
const DEFAULT_HEIGHT: u32 = 1024;
const DEFAULT_STEPS: u32 = 4; // schnell optimized for 1-4 steps
// Discovered via live 400: FLUX.1-schnell serverless caps steps at 12.
// FLUX.1-dev allows up to ~28, -pro up to ~50. Clamping per-model below so
// agent's ambitious retry doesn't 400. If operator configures a dedicated
// endpoint variant with higher limits, they can bump MAX_STEPS via model
// override (future: make step-cap fully model-aware via a small lookup).
const MAX_STEPS_SCHNELL: u32 = 12;
const MAX_STEPS_DEFAULT: u32 = 50;
const MIN_STEPS: u32 = 1;
const MIN_DIM: u32 = 256;
const MAX_DIM: u32 = 1440;
const DIM_STRIDE: u32 = 64; // FLUX expects multiples of 64
const ENV_TOGETHER_API_KEY = "TOGETHER_API_KEY";
const REQUEST_TIMEOUT_MS: u32 = 180_000; // dev is slower than schnell
const DOWNLOAD_TIMEOUT_MS: u32 = 60_000;
const MAX_IMAGE_BYTES: usize = 16 * 1024 * 1024; // 16 MB cap
const MAX_ERROR_BODY_CHARS: usize = 500;
const STATIC_ALT: []const u8 = "generated image"; // NEVER interpolate user prompt here — markdown injection risk.

pub const ImageGenerateTool = struct {
    /// Config-resolved Together API key. Empty means fall back to TOGETHER_API_KEY env.
    api_key_override: []const u8 = "",
    /// Operator-configurable model override. Empty uses DEFAULT_TEXT_MODEL.
    model_override: []const u8 = "",
    /// Workspace root for saved images. Bound at tool registration time.
    workspace_dir: []const u8 = "",

    pub const tool_name = "image_generate";
    pub const tool_description =
        "Generate an image from a text prompt, optionally using reference images for " ++
        "image-to-image generation. Use this when the user asks for a picture, image, " ++
        "logo, diagram, visualization, illustration, sketch, mockup, art, poster, or " ++
        "variation of an existing image. For reference-based requests (e.g. 'look at " ++
        "this website/image and make something similar'), first gather style cues " ++
        "using web_fetch or web_search, then build a detailed prompt. The generated " ++
        "image is saved to the agent's workspace and returned as markdown — include " ++
        "the output in your reply so the UI renders it inline.";
    pub const tool_params =
        \\{"type":"object","properties":{"prompt":{"type":"string","description":"Detailed text description of the image to generate. Include style, subject, mood, colors, composition, lighting."},"reference_urls":{"type":"array","items":{"type":"string"},"description":"Optional image URL(s) to use as visual reference. When provided, the tool switches to image-to-image mode (FLUX.1-Kontext-pro). Currently only the first URL is used."},"width":{"type":"integer","description":"Image width in pixels (rounded to nearest multiple of 64, range 256-1440). Default 1024."},"height":{"type":"integer","description":"Image height in pixels (same constraints as width). Default 1024."},"steps":{"type":"integer","description":"Diffusion steps. Default 4 (fast). FLUX.1-schnell max is 12; other variants max 50. The tool clamps automatically based on model."},"n":{"type":"integer","description":"Number of variations 1-4. Default 1."}},"required":["prompt"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ImageGenerateTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ImageGenerateTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const prompt = root.getString(args, "prompt") orelse
            return ToolResult.fail("Missing 'prompt' parameter");
        const trimmed_prompt = std.mem.trim(u8, prompt, " \t\r\n");
        if (trimmed_prompt.len == 0) return ToolResult.fail("'prompt' must not be empty");
        if (trimmed_prompt.len > 4000) return ToolResult.fail("'prompt' too long (max 4000 chars)");

        // Optional reference URL (image-to-image via Kontext-pro).
        const reference_url = extractFirstReferenceUrl(args);

        const width_raw = optionalU32(args, "width") orelse DEFAULT_WIDTH;
        const height_raw = optionalU32(args, "height") orelse DEFAULT_HEIGHT;
        const width = roundToStride(clampU32(width_raw, MIN_DIM, MAX_DIM));
        const height = roundToStride(clampU32(height_raw, MIN_DIM, MAX_DIM));
        const n = clampU32(optionalU32(args, "n") orelse 1, 1, 4);

        // Model selection: reference-image mode switches to Kontext-pro.
        const model_default = if (reference_url != null) DEFAULT_IMG2IMG_MODEL else DEFAULT_TEXT_MODEL;
        const model_raw = if (self.model_override.len > 0) self.model_override else model_default;
        const model = std.mem.trim(u8, model_raw, " \t\r\n");

        // Model-aware step cap (FLUX.1-schnell serverless rejects steps > 12).
        const max_steps = maxStepsForModel(model);
        const steps = clampU32(optionalU32(args, "steps") orelse DEFAULT_STEPS, MIN_STEPS, max_steps);

        const api_key = resolveApiKey(allocator, self.api_key_override) orelse {
            return ToolResult.fail(
                "Together API key not configured. Set models.providers.together.api_key " ++
                    "in config, or the TOGETHER_API_KEY environment variable.",
            );
        };
        defer freeResolvedKey(allocator, api_key);

        const body = try buildRequestBody(allocator, model, trimmed_prompt, reference_url, width, height, steps, n);
        defer allocator.free(body);

        const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key.value});
        defer allocator.free(auth_header);
        const headers = [_][]const u8{
            auth_header,
            "Content-Type: application/json",
            "Accept: application/json",
        };

        const connect_host = net_security.resolveConnectHost(allocator, TOGETHER_HOST, 443) catch |err| switch (err) {
            error.LocalAddressBlocked => return ToolResult.fail("Blocked local/private host"),
            else => return ToolResult.fail("Unable to verify Together host safety"),
        };
        defer allocator.free(connect_host);

        const response = http_util.request_with_mode(
            allocator,
            .{ .mode = .curl_only },
            .{
                .method = "POST",
                .url = TOGETHER_IMAGE_URL,
                .headers = &headers,
                .body = body,
                .timeout_ms = REQUEST_TIMEOUT_MS,
                .subsystem = .tools,
                .resolve_host = TOGETHER_HOST,
                .resolve_port = 443,
                .connect_host = connect_host,
            },
        ) catch |err| {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Image generation request failed: {s}",
                .{@errorName(err)},
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer allocator.free(response.body);

        if (response.status_code < 200 or response.status_code >= 300) {
            const truncated = truncate(response.body, MAX_ERROR_BODY_CHARS);
            const msg = try std.fmt.allocPrint(
                allocator,
                "Together image API returned HTTP {d}. Body (first {d} chars): {s}",
                .{ response.status_code, truncated.len, truncated },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        return formatAndSave(allocator, response.body, trimmed_prompt, model, self.workspace_dir);
    }
};

// ── Helpers ──────────────────────────────────────────────────────

const ResolvedKey = struct {
    value: []const u8,
    owned: bool = false,
};

fn resolveApiKey(allocator: std.mem.Allocator, configured: []const u8) ?ResolvedKey {
    const trimmed = std.mem.trim(u8, configured, " \t\r\n");
    if (trimmed.len > 0) return .{ .value = trimmed, .owned = false };
    const raw = platform.getEnvOrNull(allocator, ENV_TOGETHER_API_KEY) orelse return null;
    const env_trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (env_trimmed.len == 0) {
        allocator.free(raw);
        return null;
    }
    if (env_trimmed.ptr == raw.ptr and env_trimmed.len == raw.len) {
        return .{ .value = @constCast(raw), .owned = true };
    }
    const owned = allocator.dupe(u8, env_trimmed) catch {
        allocator.free(raw);
        return null;
    };
    allocator.free(raw);
    return .{ .value = owned, .owned = true };
}

fn freeResolvedKey(allocator: std.mem.Allocator, key: ResolvedKey) void {
    if (key.owned) allocator.free(key.value);
}

fn optionalU32(args: JsonObjectMap, key: []const u8) ?u32 {
    const v = root.getInt(args, key) orelse return null;
    if (v < 0) return null;
    return @intCast(v);
}

fn clampU32(v: u32, lo: u32, hi: u32) u32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

/// Per-model step-cap. Together's serverless FLUX.1-schnell rejects steps > 12.
/// Larger FLUX variants (dev/pro/Kontext) accept higher. Kept as a small
/// lookup so the agent's ambitious parameter choice doesn't silently 400.
fn maxStepsForModel(model: []const u8) u32 {
    // Match on substring so both bare names and org-prefixed forms work
    // (e.g. "FLUX.1-schnell" and "black-forest-labs/FLUX.1-schnell").
    if (std.ascii.indexOfIgnoreCase(model, "flux.1-schnell") != null) return MAX_STEPS_SCHNELL;
    if (std.ascii.indexOfIgnoreCase(model, "flux-1-schnell") != null) return MAX_STEPS_SCHNELL;
    return MAX_STEPS_DEFAULT;
}

/// Round to nearest multiple of DIM_STRIDE, keeping within [MIN_DIM, MAX_DIM].
fn roundToStride(v: u32) u32 {
    const half = DIM_STRIDE / 2;
    var rounded = ((v + half) / DIM_STRIDE) * DIM_STRIDE;
    if (rounded < MIN_DIM) rounded = MIN_DIM;
    if (rounded > MAX_DIM) rounded = (MAX_DIM / DIM_STRIDE) * DIM_STRIDE;
    return rounded;
}

fn truncate(s: []const u8, max: usize) []const u8 {
    return if (s.len <= max) s else s[0..max];
}

fn extractFirstReferenceUrl(args: JsonObjectMap) ?[]const u8 {
    const v = root.getValue(args, "reference_urls") orelse return null;
    if (v != .array) return null;
    if (v.array.items.len == 0) return null;
    const first = v.array.items[0];
    if (first != .string) return null;
    const trimmed = std.mem.trim(u8, first.string, " \t\r\n");
    if (trimmed.len == 0) return null;
    // Basic scheme sanity — reject file:// and other non-http schemes so we
    // don't ask Together to fetch arbitrary local URIs.
    if (!std.mem.startsWith(u8, trimmed, "https://") and !std.mem.startsWith(u8, trimmed, "http://")) return null;
    return trimmed;
}

fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    prompt: []const u8,
    reference_url: ?[]const u8,
    width: u32,
    height: u32,
    steps: u32,
    n: u32,
) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);

    try body.append(allocator, '{');
    try json_util.appendJsonKey(&body, allocator, "model");
    try json_util.appendJsonString(&body, allocator, model);
    try body.append(allocator, ',');
    try json_util.appendJsonKey(&body, allocator, "prompt");
    try json_util.appendJsonString(&body, allocator, prompt);
    try body.append(allocator, ',');
    try json_util.appendJsonInt(&body, allocator, "width", @intCast(width));
    try body.append(allocator, ',');
    try json_util.appendJsonInt(&body, allocator, "height", @intCast(height));
    try body.append(allocator, ',');
    try json_util.appendJsonInt(&body, allocator, "steps", @intCast(steps));
    try body.append(allocator, ',');
    try json_util.appendJsonInt(&body, allocator, "n", @intCast(n));
    if (reference_url) |url| {
        try body.append(allocator, ',');
        try json_util.appendJsonKey(&body, allocator, "image_url");
        try json_util.appendJsonString(&body, allocator, url);
    }
    try body.append(allocator, '}');

    return body.toOwnedSlice(allocator);
}

/// Download the generated image to the agent workspace and format an
/// agent-consumable response. Emits markdown with a STATIC alt so the
/// user prompt is never interpolated into markdown link syntax.
fn formatAndSave(
    allocator: std.mem.Allocator,
    api_body: []const u8,
    prompt: []const u8,
    model: []const u8,
    workspace_dir: []const u8,
) !ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, api_body, .{}) catch {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Together image API returned non-JSON. Body (first {d} chars): {s}",
            .{ @min(api_body.len, MAX_ERROR_BODY_CHARS), truncate(api_body, MAX_ERROR_BODY_CHARS) },
        );
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    };
    defer parsed.deinit();

    if (parsed.value != .object) return ToolResult.fail("Together image API response was not a JSON object");

    const data_val = parsed.value.object.get("data") orelse
        return ToolResult.fail("Together image API response missing 'data' array");
    if (data_val != .array) return ToolResult.fail("'data' field is not an array");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("Generated {d} image(s)\nModel: {s}\nPrompt: {s}\n\n", .{
        data_val.array.items.len,
        model,
        truncate(prompt, 400),
    });

    var count_urls: usize = 0;
    for (data_val.array.items, 0..) |entry, idx| {
        if (entry != .object) continue;
        const url_val = entry.object.get("url") orelse continue;
        if (url_val != .string) continue;
        count_urls += 1;

        // Best-effort save to workspace. If save fails we still emit the URL.
        const save_result = saveImageToWorkspace(allocator, url_val.string, workspace_dir, idx) catch null;
        defer if (save_result) |sr| allocator.free(sr);

        // Markdown with STATIC alt — never interpolate user prompt here.
        try w.print("![{s}]({s})\n", .{ STATIC_ALT, url_val.string });
        if (save_result) |local_path| {
            try w.print("Saved: {s}\n", .{local_path});
        }
        // Raw URL on its own line for preview-card scrapers + download link.
        try w.print("Download: {s}\n\n", .{url_val.string});
    }

    if (count_urls == 0) return ToolResult.fail("Together image API returned no image URLs");

    return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
}

/// Download image bytes and write to `<workspace_dir>/images/img_<ts>_<rand><ext>`.
/// Returns the absolute file path (caller-owned), or null on any failure.
/// Never throws — the upstream URL is the primary delivery; the local save
/// is a convenience for agent-driven edit flows and user download.
fn saveImageToWorkspace(
    allocator: std.mem.Allocator,
    url: []const u8,
    workspace_dir: []const u8,
    seq_hint: usize,
) !?[]u8 {
    if (workspace_dir.len == 0) return null;

    // Ensure images/ subdir exists (idempotent).
    const images_dir = try std.fs.path.join(allocator, &.{ workspace_dir, "images" });
    defer allocator.free(images_dir);
    std.fs.cwd().makePath(images_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return null,
    };

    // Derive filename: img_<nanots>_<seq>.<ext>. Extension from URL path,
    // defaulting to .png if unclear.
    const ext = detectImageExtensionFromUrl(url);
    const ts = std.time.nanoTimestamp();
    const filename = try std.fmt.allocPrint(allocator, "img_{d}_{d}{s}", .{ ts, seq_hint, ext });
    defer allocator.free(filename);

    const full_path = try std.fs.path.join(allocator, &.{ images_dir, filename });
    // Review-fix: every `return null` below would have leaked full_path because
    // `errdefer` only fires on propagated `!`-errors. Use a success flag + defer.
    var ok = false;
    defer if (!ok) allocator.free(full_path);

    // Fetch image bytes. SSRF + DNS-rebinding protection applied.
    const image_host = net_security.extractHost(url) orelse return null;
    const connect_host = net_security.resolveConnectHost(allocator, image_host, 443) catch return null;
    defer allocator.free(connect_host);

    const data = http_util.request_with_mode(
        allocator,
        .{ .mode = .curl_only },
        .{
            .method = "GET",
            .url = url,
            .timeout_ms = DOWNLOAD_TIMEOUT_MS,
            .subsystem = .tools,
            .resolve_host = image_host,
            .resolve_port = 443,
            .connect_host = connect_host,
            .max_response_bytes = MAX_IMAGE_BYTES,
        },
    ) catch return null;
    defer allocator.free(data.body);

    if (data.status_code < 200 or data.status_code >= 300) return null;
    if (data.body.len == 0) return null;

    const file = std.fs.createFileAbsolute(full_path, .{}) catch return null;
    // Review-fix: if writeAll fails mid-stream we'd leave a partial file
    // on disk forever. Track write success and unlink on failure. Register
    // the unlink BEFORE file.close so LIFO gives us close-then-unlink
    // (portable; Windows dislikes unlink-while-open).
    var write_ok = false;
    defer if (!write_ok) std.fs.deleteFileAbsolute(full_path) catch {};
    defer file.close();
    file.writeAll(data.body) catch return null;
    write_ok = true;

    ok = true;
    return full_path;
}

fn detectImageExtensionFromUrl(url: []const u8) []const u8 {
    // Strip query + fragment for extension detection.
    const q = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const path_part = url[0..q];
    const dot = std.mem.lastIndexOfScalar(u8, path_part, '.') orelse return ".png";
    const ext = path_part[dot..];
    if (ext.len > 6 or ext.len < 4) return ".png";
    if (std.ascii.eqlIgnoreCase(ext, ".png") or
        std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg") or
        std.ascii.eqlIgnoreCase(ext, ".webp") or
        std.ascii.eqlIgnoreCase(ext, ".gif")) return ext;
    return ".png";
}

// ── Tests ────────────────────────────────────────────────────────

test "image_generate tool name + schema" {
    var ig = ImageGenerateTool{};
    const t = ig.tool();
    try std.testing.expectEqualStrings("image_generate", t.name());
    try std.testing.expect(std.mem.indexOf(u8, ImageGenerateTool.tool_description, "reference") != null);
    try std.testing.expect(std.mem.indexOf(u8, ImageGenerateTool.tool_params, "reference_urls") != null);
    try std.testing.expect(std.mem.indexOf(u8, ImageGenerateTool.tool_params, "prompt") != null);
}

test "image_generate fails without prompt" {
    var ig = ImageGenerateTool{};
    const t = ig.tool();
    var args = std.json.ObjectMap.init(std.testing.allocator);
    defer args.deinit();
    const result = try t.execute(std.testing.allocator, args);
    try std.testing.expect(!result.success);
    const msg = if (result.error_msg) |m| m else result.output;
    try std.testing.expect(std.mem.indexOf(u8, msg, "prompt") != null);
}

test "image_generate rejects empty prompt" {
    var ig = ImageGenerateTool{};
    const t = ig.tool();
    var args = std.json.ObjectMap.init(std.testing.allocator);
    defer args.deinit();
    try args.put("prompt", std.json.Value{ .string = "   " });
    const result = try t.execute(std.testing.allocator, args);
    try std.testing.expect(!result.success);
    const msg = if (result.error_msg) |m| m else result.output;
    try std.testing.expect(std.mem.indexOf(u8, msg, "empty") != null);
}

test "clampU32 bounds" {
    try std.testing.expectEqual(@as(u32, 256), clampU32(100, 256, 1440));
    try std.testing.expectEqual(@as(u32, 1440), clampU32(2048, 256, 1440));
    try std.testing.expectEqual(@as(u32, 512), clampU32(512, 256, 1440));
}

test "maxStepsForModel caps schnell at 12, others at 50" {
    try std.testing.expectEqual(@as(u32, 12), maxStepsForModel("black-forest-labs/FLUX.1-schnell"));
    try std.testing.expectEqual(@as(u32, 12), maxStepsForModel("FLUX.1-schnell"));
    try std.testing.expectEqual(@as(u32, 12), maxStepsForModel("flux-1-schnell"));
    try std.testing.expectEqual(@as(u32, 50), maxStepsForModel("black-forest-labs/FLUX.1-dev"));
    try std.testing.expectEqual(@as(u32, 50), maxStepsForModel("black-forest-labs/FLUX.1-Kontext-pro"));
    try std.testing.expectEqual(@as(u32, 50), maxStepsForModel("unknown/model"));
}

test "roundToStride snaps to multiples of 64" {
    try std.testing.expectEqual(@as(u32, 512), roundToStride(500));
    try std.testing.expectEqual(@as(u32, 1024), roundToStride(1024));
    try std.testing.expectEqual(@as(u32, 1024), roundToStride(1000));
    try std.testing.expectEqual(@as(u32, 1024), roundToStride(1050));
    try std.testing.expectEqual(@as(u32, 768), roundToStride(777));
    try std.testing.expectEqual(@as(u32, 256), roundToStride(200));
    try std.testing.expectEqual(@as(u32, 1408), roundToStride(1440));
}

test "truncate caps at max" {
    try std.testing.expectEqualStrings("hello", truncate("hello", 10));
    try std.testing.expectEqualStrings("hell", truncate("hello", 4));
}

test "extractFirstReferenceUrl handles common cases" {
    const alloc = std.testing.allocator;
    // no reference_urls
    {
        var args = std.json.ObjectMap.init(alloc);
        defer args.deinit();
        try std.testing.expect(extractFirstReferenceUrl(args) == null);
    }
    // valid https URL
    {
        var args = std.json.ObjectMap.init(alloc);
        defer args.deinit();
        var arr = std.json.Array.init(alloc);
        defer arr.deinit();
        try arr.append(std.json.Value{ .string = "https://example.com/image.png" });
        try args.put("reference_urls", std.json.Value{ .array = arr });
        const url = extractFirstReferenceUrl(args) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("https://example.com/image.png", url);
    }
    // rejects file:// scheme
    {
        var args = std.json.ObjectMap.init(alloc);
        defer args.deinit();
        var arr = std.json.Array.init(alloc);
        defer arr.deinit();
        try arr.append(std.json.Value{ .string = "file:///etc/passwd" });
        try args.put("reference_urls", std.json.Value{ .array = arr });
        try std.testing.expect(extractFirstReferenceUrl(args) == null);
    }
}

test "buildRequestBody includes image_url when reference provided" {
    const body = try buildRequestBody(
        std.testing.allocator,
        "black-forest-labs/FLUX.1-Kontext-pro",
        "make a variation",
        "https://example.com/ref.png",
        1024,
        1024,
        28,
        1,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"image_url\":\"https://example.com/ref.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"black-forest-labs/FLUX.1-Kontext-pro\"") != null);
}

test "buildRequestBody omits image_url when no reference" {
    const body = try buildRequestBody(
        std.testing.allocator,
        "black-forest-labs/FLUX.1-schnell",
        "a sunset",
        null,
        1024,
        1024,
        4,
        1,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "image_url") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"black-forest-labs/FLUX.1-schnell\"") != null);
}

test "detectImageExtensionFromUrl handles common formats and query strings" {
    try std.testing.expectEqualStrings(".png", detectImageExtensionFromUrl("https://x.com/a.png"));
    try std.testing.expectEqualStrings(".jpg", detectImageExtensionFromUrl("https://x.com/a.jpg?token=abc"));
    try std.testing.expectEqualStrings(".webp", detectImageExtensionFromUrl("https://x.com/a.webp"));
    try std.testing.expectEqualStrings(".png", detectImageExtensionFromUrl("https://x.com/a"));
    try std.testing.expectEqualStrings(".png", detectImageExtensionFromUrl("https://x.com/a.exe")); // unknown → .png
}

test "markdown alt is static (no prompt injection surface)" {
    // Sanity guard: STATIC_ALT must not contain any format-style placeholders
    // and must not be empty.
    try std.testing.expect(STATIC_ALT.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, STATIC_ALT, "{") == null);
    try std.testing.expect(std.mem.indexOf(u8, STATIC_ALT, "}") == null);
}
