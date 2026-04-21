//! Image generation tool — calls Together.ai's `/v1/images/generations` endpoint
//! to produce an image from a text prompt. Returns a URL the user (via the
//! frontend) can display inline.
//!
//! Invocation: Kimi (and any capable LLM) calls this when the user asks for
//! an image, logo, picture, visualization, diagram, or other visual artifact.
//! The tool description is deliberately broad so the model recognizes the
//! intent without a slash-command.
//!
//! Endpoint: https://api.together.xyz/v1/images/generations
//! Default model: black-forest-labs/FLUX.1-schnell (fastest/cheapest, 4 steps)
//!
//! Frontend pairing: the returned URL is embedded as markdown image syntax
//! so markdown-aware renderers display it inline. If the frontend strips
//! images from markdown, pair this with an <img> detector (see zaki-prod F3).

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
const DEFAULT_MODEL = "black-forest-labs/FLUX.1-schnell";
const DEFAULT_WIDTH: u32 = 1024;
const DEFAULT_HEIGHT: u32 = 1024;
const DEFAULT_STEPS: u32 = 4; // schnell is optimized for 1-4 steps
const MAX_STEPS: u32 = 50;
const MIN_STEPS: u32 = 1;
const MIN_DIM: u32 = 256;
const MAX_DIM: u32 = 1440;
const ENV_TOGETHER_API_KEY = "TOGETHER_API_KEY";
const REQUEST_TIMEOUT_MS: u32 = 120_000; // image gen can be slow

pub const ImageGenerateTool = struct {
    /// Config-resolved Together API key. Empty means fall back to TOGETHER_API_KEY env.
    api_key_override: []const u8 = "",
    /// Operator-configurable model override. Empty uses DEFAULT_MODEL.
    model_override: []const u8 = "",

    pub const tool_name = "image_generate";
    pub const tool_description =
        "Generate an image from a text prompt. Use this when the user asks for a " ++
        "picture, image, logo, diagram, visualization, illustration, sketch, mockup, " ++
        "art, poster, or any visual artifact. Returns a URL to the generated image; " ++
        "include it in your reply so the UI can render it inline.";
    pub const tool_params =
        \\{"type":"object","properties":{"prompt":{"type":"string","description":"Detailed text description of the image to generate. Include style, subject, mood, colors, composition."},"width":{"type":"integer","description":"Image width in pixels (256-1440). Default 1024."},"height":{"type":"integer","description":"Image height in pixels (256-1440). Default 1024."},"steps":{"type":"integer","description":"Diffusion steps 1-50. Default 4 for FLUX.1-schnell (fast). Higher = slower but may improve quality."},"n":{"type":"integer","description":"Number of variations 1-4. Default 1."}},"required":["prompt"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ImageGenerateTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ImageGenerateTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const prompt = root.getString(args, "prompt") orelse
            return ToolResult.fail("Missing 'prompt' parameter");
        const trimmed_prompt = std.mem.trim(u8, prompt, " \t\r\n");
        if (trimmed_prompt.len == 0) {
            return ToolResult.fail("'prompt' must not be empty");
        }
        if (trimmed_prompt.len > 4000) {
            return ToolResult.fail("'prompt' too long (max 4000 chars)");
        }

        const width = clampU32(optionalU32(args, "width") orelse DEFAULT_WIDTH, MIN_DIM, MAX_DIM);
        const height = clampU32(optionalU32(args, "height") orelse DEFAULT_HEIGHT, MIN_DIM, MAX_DIM);
        const steps = clampU32(optionalU32(args, "steps") orelse DEFAULT_STEPS, MIN_STEPS, MAX_STEPS);
        const n = clampU32(optionalU32(args, "n") orelse 1, 1, 4);

        const model_raw = if (self.model_override.len > 0) self.model_override else DEFAULT_MODEL;
        const model = std.mem.trim(u8, model_raw, " \t\r\n");

        // Resolve API key from config override, then env var.
        const api_key = resolveApiKey(allocator, self.api_key_override) orelse {
            return ToolResult.fail(
                "Together API key not configured. Set models.providers.together.api_key " ++
                    "in config, or the TOGETHER_API_KEY environment variable.",
            );
        };
        defer freeResolvedKey(allocator, api_key);

        // Build request body.
        const body = try buildRequestBody(allocator, model, trimmed_prompt, width, height, steps, n);
        defer allocator.free(body);

        // Auth + content headers.
        const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key.value});
        defer allocator.free(auth_header);
        const headers = [_][]const u8{
            auth_header,
            "Content-Type: application/json",
            "Accept: application/json",
        };

        // SSRF protection / DNS rebinding hardening (matches http_request pattern).
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
            const msg = try std.fmt.allocPrint(
                allocator,
                "Together image API returned HTTP {d}. Body: {s}",
                .{ response.status_code, response.body },
            );
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        return formatResponse(allocator, response.body, trimmed_prompt, model);
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

fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    prompt: []const u8,
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
    try body.append(allocator, '}');

    return body.toOwnedSlice(allocator);
}

fn formatResponse(allocator: std.mem.Allocator, body: []const u8, prompt: []const u8, model: []const u8) !ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Image generated, but response was not valid JSON. Raw body:\n{s}",
            .{body},
        );
        return ToolResult{ .success = true, .output = msg };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return ToolResult.fail("Together image API response was not a JSON object");
    }

    const data_val = parsed.value.object.get("data") orelse
        return ToolResult.fail("Together image API response missing 'data' array");
    if (data_val != .array) return ToolResult.fail("'data' field is not an array");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("Generated {d} image(s) for prompt: {s}\nModel: {s}\n\n", .{
        data_val.array.items.len,
        prompt,
        model,
    });

    var count_urls: usize = 0;
    for (data_val.array.items) |entry| {
        if (entry != .object) continue;
        const url_val = entry.object.get("url") orelse continue;
        if (url_val != .string) continue;
        count_urls += 1;
        // Emit markdown image syntax so markdown-aware renderers display inline.
        // Also emit the raw URL on a separate line so plain-text UIs can still
        // surface it and so iPhone/Android preview-card scrapers find it.
        try w.print("![{s}]({s})\n{s}\n\n", .{ prompt, url_val.string, url_val.string });
    }

    if (count_urls == 0) {
        return ToolResult.fail("Together image API returned no image URLs");
    }

    return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
}

// ── Tests ────────────────────────────────────────────────────────

test "image_generate tool name + schema" {
    var ig = ImageGenerateTool{};
    const t = ig.tool();
    try std.testing.expectEqualStrings("image_generate", t.name());
    try std.testing.expect(std.mem.indexOf(u8, ImageGenerateTool.tool_description, "image") != null);
    try std.testing.expect(std.mem.indexOf(u8, ImageGenerateTool.tool_params, "prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, ImageGenerateTool.tool_params, "width") != null);
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

test "buildRequestBody shape" {
    const body = try buildRequestBody(std.testing.allocator, "model-x", "a cat", 512, 512, 4, 1);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"model-x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt\":\"a cat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"width\":512") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"steps\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"n\":1") != null);
}
