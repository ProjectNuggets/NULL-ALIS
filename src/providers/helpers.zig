const std = @import("std");
const json_util = @import("../json_util.zig");
const http_util = @import("../http_util.zig");
const config_types = @import("../config_types.zig");
const schema = @import("../tools/schema.zig");
const root = @import("root.zig");
const ToolSpec = root.ToolSpec;

/// Extract api_key from a config-like struct (supports both Config.defaultProviderKey() and plain .api_key field).
fn resolveApiKeyFromCfg(cfg: anytype) ?[]const u8 {
    const T = @TypeOf(cfg);
    const Struct = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
    if (@hasField(Struct, "api_key")) return cfg.api_key;
    if (@hasDecl(Struct, "defaultProviderKey")) return cfg.defaultProviderKey();
    return null;
}

fn timeout_ms_from_secs(timeout_secs: u64) u32 {
    if (timeout_secs == 0) return 300_000; // 5 min default
    const timeout_ms = timeout_secs * 1000;
    return @intCast(@min(timeout_ms, std.math.maxInt(u32)));
}

/// High-level complete function that routes to the right provider via HTTP.
/// Used by agent.zig for backward compatibility.
pub fn complete(allocator: std.mem.Allocator, cfg: anytype, prompt: []const u8) ![]const u8 {
    const api_key = resolveApiKeyFromCfg(cfg) orelse return error.NoApiKey;
    const url = providerUrl(cfg.default_provider);
    const model = cfg.default_model orelse return error.NoDefaultModel;
    const body_str = try buildRequestBody(allocator, model, prompt, cfg.temperature, cfg.max_tokens orelse config_types.DEFAULT_MODEL_MAX_TOKENS);
    defer allocator.free(body_str);

    var auth_buf: [512]u8 = undefined;
    const auth_val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch return error.NoApiKey;

    const response = try http_util.request_with_mode(allocator, .{}, .{
        .method = "POST",
        .url = url,
        .headers = &.{
            auth_val,
            "Content-Type: application/json",
        },
        .body = body_str,
        .timeout_ms = 30_000,
        .subsystem = .providers,
    });
    defer allocator.free(response.body);
    if (response.status_code < 200 or response.status_code >= 300) return error.ProviderError;

    const response_body = response.body;
    return try extractContent(allocator, response_body);
}

/// Like complete() but prepends a system prompt. OpenAI-compatible format.
pub fn completeWithSystem(allocator: std.mem.Allocator, cfg: anytype, system_prompt: []const u8, prompt: []const u8) ![]const u8 {
    const api_key = resolveApiKeyFromCfg(cfg) orelse return error.NoApiKey;
    const url = providerUrl(cfg.default_provider);
    const model = cfg.default_model orelse return error.NoDefaultModel;
    const max_tok: u32 = if (cfg.max_tokens) |mt| @intCast(@min(mt, std.math.maxInt(u32))) else config_types.DEFAULT_MODEL_MAX_TOKENS;
    const body_str = try buildRequestBodyWithSystem(allocator, model, system_prompt, prompt, cfg.temperature, max_tok);
    defer allocator.free(body_str);

    var auth_buf: [512]u8 = undefined;
    const auth_val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch return error.NoApiKey;

    const response = try http_util.request_with_mode(allocator, .{}, .{
        .method = "POST",
        .url = url,
        .headers = &.{
            auth_val,
            "Content-Type: application/json",
        },
        .body = body_str,
        .timeout_ms = 30_000,
        .subsystem = .providers,
    });
    defer allocator.free(response.body);
    if (response.status_code < 200 or response.status_code >= 300) return error.ProviderError;

    const response_body = response.body;
    return try extractContent(allocator, response_body);
}

/// Provider URL mapping for the legacy complete() function.
pub fn providerUrl(provider_name: []const u8) []const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "anthropic", "https://api.anthropic.com/v1/messages" },
        .{ "openai", "https://api.openai.com/v1/chat/completions" },
        .{ "ollama", "http://localhost:11434/api/chat" },
        .{ "gemini", "https://generativelanguage.googleapis.com/v1beta" },
        .{ "google", "https://generativelanguage.googleapis.com/v1beta" },
    });
    return map.get(provider_name) orelse "https://openrouter.ai/api/v1/chat/completions";
}

/// Build a JSON request body for the legacy complete() function.
pub fn buildRequestBody(allocator: std.mem.Allocator, model: []const u8, prompt: []const u8, temperature: f64, max_tokens: u32) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"model\":");
    try json_util.appendJsonString(&buf, allocator, model);
    try w.writeAll(",\"messages\":[{\"role\":\"user\",\"content\":");
    try json_util.appendJsonString(&buf, allocator, prompt);
    try std.fmt.format(w, "}}],\"temperature\":{d:.1},\"max_tokens\":{d}}}", .{ temperature, max_tokens });
    return try buf.toOwnedSlice(allocator);
}

/// Build a JSON request body with a system prompt (OpenAI-compatible format).
pub fn buildRequestBodyWithSystem(allocator: std.mem.Allocator, model: []const u8, system: []const u8, prompt: []const u8, temperature: f64, max_tokens: u32) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"model\":\"");
    try w.writeAll(model);
    try w.writeAll("\",\"messages\":[{\"role\":\"system\",\"content\":");
    try json_util.appendJsonString(&buf, allocator, system);
    try w.writeAll("},{\"role\":\"user\",\"content\":");
    try json_util.appendJsonString(&buf, allocator, prompt);
    try std.fmt.format(w, "}}],\"temperature\":{d:.1},\"max_tokens\":{d}}}", .{ temperature, max_tokens });
    return try buf.toOwnedSlice(allocator);
}

/// Check if a model name indicates an OpenAI reasoning model
/// (o1, o3, o4-mini, gpt-5*, codex-mini).
///
/// Q2 (2026-04-27): kept narrow for the OpenAI request-shape convention
/// (these models REJECT `temperature` when reasoning is on, accept only
/// `max_completion_tokens`). For broader "supports reasoning_effort"
/// classification, see `isReasoningCapableModel` below — Kimi/Moonshot
/// support reasoning_effort but accept temperature alongside it.
pub fn isReasoningModel(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "gpt-5") or
        std.mem.startsWith(u8, model, "o1") or
        std.mem.startsWith(u8, model, "o3") or
        std.mem.startsWith(u8, model, "o4-mini") or
        std.mem.startsWith(u8, model, "codex-mini");
}

/// **Q2 (2026-04-27)** — broader classifier: any model that accepts the
/// `reasoning_effort` request field, regardless of whether it follows
/// OpenAI's strict shape (drop-temperature) or the Kimi/Moonshot shape
/// (temperature accepted alongside).
///
/// Triggers Kimi K2.5/K2.6 + Moonshot variants on Together / OpenRouter
/// / direct Moonshot API. Per Moonshot + Together docs, these models
/// expose `reasoning_effort: low|medium|high` and default to `medium`
/// when unset.
///
/// Use this for `reasoning_effort` field emission gating; use the
/// narrower `isReasoningModel` for OpenAI request-shape gating
/// (temperature drop, max_completion_tokens swap).
pub fn isReasoningCapableModel(model: []const u8) bool {
    if (isReasoningModel(model)) return true;
    // Strip provider prefix for substring search across nested refs
    // (`together-ai/moonshotai/kimi-k2.5`, `openrouter/moonshotai/kimi-k2.6`,
    //  `together-ai/deepseek-ai/DeepSeek-V4-Pro`, etc.)
    const lower_haystack = model;
    return std.mem.indexOf(u8, lower_haystack, "kimi-k2") != null or
        std.mem.indexOf(u8, lower_haystack, "kimi-K2") != null or
        std.mem.indexOf(u8, lower_haystack, "Kimi-K2") != null or
        std.mem.indexOf(u8, lower_haystack, "moonshot") != null or
        std.mem.indexOf(u8, lower_haystack, "Moonshot") != null or
        // DeepSeek V4 (2026-04-29 swap): both V4-Pro and V4-Flash accept
        // reasoning_effort with normal temperature semantics — same shape
        // as Kimi. NOT in isReasoningModel because they don't drop
        // temperature like the OpenAI o-series does.
        std.mem.indexOf(u8, lower_haystack, "DeepSeek-V4") != null or
        std.mem.indexOf(u8, lower_haystack, "deepseek-v4") != null or
        std.mem.indexOf(u8, lower_haystack, "DeepSeek-v4") != null;
}

/// Append model-specific generation controls to a JSON request body buffer:
/// - non-reasoning: `temperature` + optional `max_tokens`
/// - reasoning + reasoning_effort=="none": `temperature` + `max_completion_tokens`
/// - reasoning (otherwise): `max_completion_tokens` only (no temperature)
/// Always emits `reasoning_effort` when set on a reasoning model.
///
/// `kimi_native_route` — true when the request targets Moonshot's
/// native Kimi API. That API differs from lenient OpenAI-compatible
/// hosts in two ways this function must honor:
///   - it controls reasoning via the top-level `thinking` field and
///     ignores `reasoning_effort` — so `reasoning_effort` is omitted;
///   - it HARD-REJECTS a custom `temperature` for Kimi K2.x
///     (`invalid temperature: only 1 is allowed for this model` —
///     probe-confirmed 2026-05-21) — so `temperature` is omitted and
///     the model applies its fixed default (1.0 in thinking mode).
/// All other (lenient) hosts are unaffected.
pub fn appendGenerationFields(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    model: []const u8,
    temperature: f64,
    max_tokens: ?u32,
    reasoning_effort: ?[]const u8,
    kimi_native_route: bool,
) !void {
    // Q2 (2026-04-27): three request shapes total —
    //   (a) Non-reasoning model: temperature + max_tokens
    //   (b) OpenAI reasoning (o1/o3/gpt-5/codex-mini): max_completion_tokens
    //       only when effort != "none"; temperature dropped unless explicit
    //       "none" override; `reasoning_effort` always appended when set
    //   (c) Kimi/Moonshot reasoning-capable: max_tokens + reasoning_effort,
    //       plus temperature on lenient hosts ONLY — Moonshot's native
    //       Kimi API rejects a custom temperature (see kimi_native_route)
    //
    // Default for reasoning-capable models when reasoning_effort is null:
    // emit "medium" — matches Moonshot/Together's documented server
    // default, and ensures our context_snapshot report (which echoes
    // config) stays honest with the actual wire request.

    if (!isReasoningModel(model) and !isReasoningCapableModel(model)) {
        // (a) Non-reasoning model: temperature + max_tokens
        try buf.appendSlice(allocator, ",\"temperature\":");
        var temp_buf: [16]u8 = undefined;
        const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.2}", .{temperature}) catch return error.FormatError;
        try buf.appendSlice(allocator, temp_str);

        if (max_tokens) |max_tok| {
            try buf.appendSlice(allocator, ",\"max_tokens\":");
            var max_buf: [16]u8 = undefined;
            const max_str = std.fmt.bufPrint(&max_buf, "{d}", .{max_tok}) catch return error.FormatError;
            try buf.appendSlice(allocator, max_str);
        }
        return;
    }

    if (isReasoningCapableModel(model) and !isReasoningModel(model)) {
        // (c) Kimi/Moonshot reasoning-capable: max_tokens + temperature +
        // reasoning_effort.
        //
        // Temperature: lenient OpenAI-compatible hosts (e.g. Together)
        // tolerate a custom temperature alongside reasoning, but Moonshot's
        // NATIVE Kimi API hard-rejects it — `invalid temperature: only 1
        // is allowed for this model` (probe-confirmed 2026-05-21). On the
        // Moonshot native route we OMIT temperature entirely; the model
        // applies its fixed default (1.0 in thinking mode).
        if (!kimi_native_route) {
            try buf.appendSlice(allocator, ",\"temperature\":");
            var temp_buf: [16]u8 = undefined;
            const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.2}", .{temperature}) catch return error.FormatError;
            try buf.appendSlice(allocator, temp_str);
        }

        if (max_tokens) |max_tok| {
            try buf.appendSlice(allocator, ",\"max_tokens\":");
            var max_buf: [16]u8 = undefined;
            const max_str = std.fmt.bufPrint(&max_buf, "{d}", .{max_tok}) catch return error.FormatError;
            try buf.appendSlice(allocator, max_str);
        }

        // reasoning_effort: explicit user value, or default "medium" —
        // keeps the context_snapshot report honest with the wire request.
        // Skipped on the Moonshot native route, which uses the top-level
        // `thinking` field and ignores `reasoning_effort`.
        if (!kimi_native_route) {
            const effort = reasoning_effort orelse "medium";
            try buf.appendSlice(allocator, ",\"reasoning_effort\":");
            try json_util.appendJsonString(buf, allocator, effort);
        }
        return;
    }

    // (b) OpenAI reasoning model: temperature only if reasoning_effort == "none"
    const effort_is_none = if (reasoning_effort) |re| std.mem.eql(u8, re, "none") else false;
    if (effort_is_none) {
        try buf.appendSlice(allocator, ",\"temperature\":");
        var temp_buf: [16]u8 = undefined;
        const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.2}", .{temperature}) catch return error.FormatError;
        try buf.appendSlice(allocator, temp_str);
    }

    // OpenAI reasoning model: always use max_completion_tokens instead of max_tokens
    if (max_tokens) |max_tok| {
        try buf.appendSlice(allocator, ",\"max_completion_tokens\":");
        var max_buf: [16]u8 = undefined;
        const max_str = std.fmt.bufPrint(&max_buf, "{d}", .{max_tok}) catch return error.FormatError;
        try buf.appendSlice(allocator, max_str);
    }

    // Emit reasoning_effort when set (JSON-escaped for safety).
    if (!kimi_native_route) {
        if (reasoning_effort) |re| {
            try buf.appendSlice(allocator, ",\"reasoning_effort\":");
            try json_util.appendJsonString(buf, allocator, re);
        }
    }
}

/// Serialize a single message's content field (plain string or multimodal content parts array).
/// OpenAI format: text → {"type":"text","text":"..."}, image_url → {"type":"image_url","image_url":{"url":"...","detail":"..."}},
/// image_base64 → {"type":"image_url","image_url":{"url":"data:mime;base64,..."}}.
/// Used by OpenAI, OpenRouter, and Compatible providers.
/// video_base64 → {"type":"video_url","video_url":{"url":"data:video/mime;base64,..."}}.
/// Serialize a single content part (text, image_url, image_base64, video_base64) to a JSON string.
pub fn serializeContentPart(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, part: root.ContentPart) !void {
    switch (part) {
        .text => |text| {
            try buf.appendSlice(allocator, "{\"type\":\"text\",\"text\":");
            try json_util.appendJsonString(buf, allocator, text);
            try buf.append(allocator, '}');
        },
        .image_url => |img| {
            try buf.appendSlice(allocator, "{\"type\":\"image_url\",\"image_url\":{\"url\":");
            try json_util.appendJsonString(buf, allocator, img.url);
            try buf.appendSlice(allocator, ",\"detail\":\"");
            try buf.appendSlice(allocator, img.detail.toSlice());
            try buf.appendSlice(allocator, "\"}}");
        },
        .image_base64 => |img| {
            // OpenAI accepts base64 images as data URIs in image_url
            // Build data URI with escaped media_type
            try buf.appendSlice(allocator, "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
            // media_type is from detectMimeType (e.g. "image/png") — safe,
            // but escape for defense-in-depth
            for (img.media_type) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    else => try buf.append(allocator, c),
                }
            }
            try buf.appendSlice(allocator, ";base64,");
            try buf.appendSlice(allocator, img.data);
            try buf.appendSlice(allocator, "\"}}");
        },
        .video_base64 => |vid| {
            // Moonshot/Kimi accepts video as a data URI inside a video_url
            // part: {"type":"video_url","video_url":{"url":"data:video/..;base64,.."}}.
            try buf.appendSlice(allocator, "{\"type\":\"video_url\",\"video_url\":{\"url\":\"data:");
            for (vid.media_type) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    else => try buf.append(allocator, c),
                }
            }
            try buf.appendSlice(allocator, ";base64,");
            try buf.appendSlice(allocator, vid.data);
            try buf.appendSlice(allocator, "\"}}");
        },
        .video_file_ref => |ref| {
            // Provider-storage reference (e.g. Moonshot `ms://<file_id>`).
            // Same shape as `video_base64` but the URL is the provider's
            // storage scheme rather than a base64 data URI. The URL is
            // JSON-escaped — it travels verbatim into the request.
            try buf.appendSlice(allocator, "{\"type\":\"video_url\",\"video_url\":{\"url\":");
            try json_util.appendJsonString(buf, allocator, ref.url);
            try buf.appendSlice(allocator, "}}");
        },
    }
}

pub fn serializeMessageContent(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, msg: root.ChatMessage) !void {
    if (msg.content_parts) |parts| {
        try buf.append(allocator, '[');
        for (parts, 0..) |part, j| {
            if (j > 0) try buf.append(allocator, ',');
            try serializeContentPart(buf, allocator, part);
        }
        try buf.append(allocator, ']');
    } else {
        try json_util.appendJsonString(buf, allocator, msg.content);
    }
}

/// Serialize tool definitions into an OpenAI-format JSON array, appending directly into `buf`.
/// Format: [{"type":"function","function":{"name":"...","description":"...","parameters":{...}}}]
pub fn convertToolsOpenAI(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, tools: []const ToolSpec) !void {
    if (tools.len == 0) {
        try buf.appendSlice(allocator, "[]");
        return;
    }
    try buf.append(allocator, '[');
    for (tools, 0..) |tool, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":");
        try json_util.appendJsonString(buf, allocator, tool.name);
        try buf.appendSlice(allocator, ",\"description\":");
        try json_util.appendJsonString(buf, allocator, tool.description);
        try buf.appendSlice(allocator, ",\"parameters\":");
        const cleaned_parameters = try schema.cleanForProvider(allocator, .openai, tool.parameters_json);
        defer allocator.free(cleaned_parameters);
        try buf.appendSlice(allocator, cleaned_parameters);
        try buf.appendSlice(allocator, "}}");
    }
    try buf.append(allocator, ']');
}

/// Serialize tool definitions into an Anthropic-format JSON array, appending directly into `buf`.
/// Format: [{"name":"...","description":"...","input_schema":{...}}]
pub fn convertToolsAnthropic(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, tools: []const ToolSpec) !void {
    if (tools.len == 0) {
        try buf.appendSlice(allocator, "[]");
        return;
    }
    try buf.append(allocator, '[');
    for (tools, 0..) |tool, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"name\":");
        try json_util.appendJsonString(buf, allocator, tool.name);
        try buf.appendSlice(allocator, ",\"description\":");
        try json_util.appendJsonString(buf, allocator, tool.description);
        try buf.appendSlice(allocator, ",\"input_schema\":");
        const cleaned_parameters = try schema.cleanForProvider(allocator, .anthropic, tool.parameters_json);
        defer allocator.free(cleaned_parameters);
        try buf.appendSlice(allocator, cleaned_parameters);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
}

/// HTTP POST with optional LLM timeout (seconds). 0 = no limit.
pub fn curlPostTimed(allocator: std.mem.Allocator, url: []const u8, body: []const u8, headers: []const []const u8, timeout_secs: u64) ![]u8 {
    const response = try http_util.request_with_mode(allocator, .{}, .{
        .method = "POST",
        .url = url,
        .headers = headers,
        .body = body,
        .timeout_ms = timeout_ms_from_secs(timeout_secs),
        .subsystem = .providers,
    });
    if (response.status_code < 200 or response.status_code >= 300) {
        allocator.free(response.body);
        return error.CurlFailed;
    }
    return response.body;
}

/// Extract text content from a provider JSON response.
pub fn extractContent(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;

    // OpenAI/OpenRouter format: choices[0].message.content
    if (root_obj.get("choices")) |choices| {
        if (choices.array.items.len > 0) {
            if (choices.array.items[0].object.get("message")) |msg| {
                if (msg.object.get("content")) |content| {
                    if (content == .string) return try allocator.dupe(u8, content.string);
                }
            }
        }
    }

    // Anthropic format: content[0].text
    if (root_obj.get("content")) |content| {
        if (content.array.items.len > 0) {
            if (content.array.items[0].object.get("text")) |text| {
                if (text == .string) return try allocator.dupe(u8, text.string);
            }
        }
    }

    return error.UnexpectedResponse;
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "Q2 — isReasoningCapableModel recognizes Kimi K2.5/K2.6 + Moonshot" {
    // OpenAI reasoning models still match (subset)
    try std.testing.expect(isReasoningCapableModel("gpt-5"));
    try std.testing.expect(isReasoningCapableModel("o1-preview"));
    try std.testing.expect(isReasoningCapableModel("o3-mini"));

    // Kimi variants across provider prefixes
    try std.testing.expect(isReasoningCapableModel("together/moonshotai/Kimi-K2.5"));
    try std.testing.expect(isReasoningCapableModel("openrouter/moonshotai/kimi-k2.5"));
    try std.testing.expect(isReasoningCapableModel("kimi-k2.6"));
    try std.testing.expect(isReasoningCapableModel("moonshotai/Kimi-K2.6"));
    try std.testing.expect(isReasoningCapableModel("Moonshot-K2.5"));

    // Non-reasoning models do NOT match
    try std.testing.expect(!isReasoningCapableModel("gpt-4o"));
    try std.testing.expect(!isReasoningCapableModel("claude-sonnet-4.6"));
    try std.testing.expect(!isReasoningCapableModel("mixtral-8x7b-32768"));
    try std.testing.expect(!isReasoningCapableModel("llama-3.1-70b"));
}

test "Mode-swap 2026-04-29 — isReasoningCapableModel recognizes DeepSeek V4 family" {
    // V4-Pro on Together (canonical balanced + deep model after swap)
    try std.testing.expect(isReasoningCapableModel("deepseek-ai/DeepSeek-V4-Pro"));
    try std.testing.expect(isReasoningCapableModel("together-ai/deepseek-ai/DeepSeek-V4-Pro"));
    try std.testing.expect(isReasoningCapableModel("openrouter/deepseek/deepseek-v4-pro"));
    // V4-Flash (future fast-mode candidate)
    try std.testing.expect(isReasoningCapableModel("deepseek-ai/DeepSeek-V4-Flash"));
    // Older DeepSeek versions (R1, V3.x) deliberately NOT matched here —
    // they have different reasoning shapes; if needed they get explicit
    // entries when added to a preset.
    try std.testing.expect(!isReasoningCapableModel("deepseek-ai/DeepSeek-V3.1"));
    try std.testing.expect(!isReasoningCapableModel("deepseek-ai/DeepSeek-V3.2"));
}

test "Q2 — appendGenerationFields emits reasoning_effort for Kimi with temperature" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    // Kimi K2.5 + explicit reasoning_effort
    try appendGenerationFields(&buf, alloc, "moonshotai/Kimi-K2.5", 0.7, 32_768, "high", false);
    const out = buf.items;

    // Kimi-shape: BOTH temperature AND max_tokens AND reasoning_effort present
    try std.testing.expect(std.mem.indexOf(u8, out, "\"temperature\":0.70") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"max_tokens\":32768") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"reasoning_effort\":\"high\"") != null);
    // Should NOT use OpenAI's max_completion_tokens
    try std.testing.expect(std.mem.indexOf(u8, out, "max_completion_tokens") == null);
}

test "Q2 — appendGenerationFields defaults Kimi reasoning_effort to medium when null" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    try appendGenerationFields(&buf, alloc, "moonshotai/Kimi-K2.5", 0.7, 32_768, null, false);
    const out = buf.items;

    // Default = "medium" (matches Together/Moonshot server default)
    try std.testing.expect(std.mem.indexOf(u8, out, "\"reasoning_effort\":\"medium\"") != null);
    // Temperature still emitted (Kimi accepts it alongside reasoning)
    try std.testing.expect(std.mem.indexOf(u8, out, "\"temperature\":0.70") != null);
}

test "appendGenerationFields suppresses reasoning_effort for Moonshot native route" {
    const alloc = std.testing.allocator;

    // Kimi K2.6 with suppression on: NO reasoning_effort, not even default.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try appendGenerationFields(&buf, alloc, "kimi-k2.6", 0.7, 32_768, "high", true);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "reasoning_effort") == null);

    // OpenAI o-series with suppression on: also drops reasoning_effort.
    var buf2: std.ArrayListUnmanaged(u8) = .empty;
    defer buf2.deinit(alloc);
    try appendGenerationFields(&buf2, alloc, "o1-preview", 0.7, 32_768, "high", true);
    try std.testing.expect(std.mem.indexOf(u8, buf2.items, "reasoning_effort") == null);
}

test "Q2 — OpenAI o1/o3 path unchanged (drops temperature unless effort=none)" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    try appendGenerationFields(&buf, alloc, "o1-preview", 0.7, 32_768, "high", false);
    const out = buf.items;

    // OpenAI-shape: max_completion_tokens (NOT max_tokens), no temperature, reasoning_effort
    try std.testing.expect(std.mem.indexOf(u8, out, "\"max_completion_tokens\":32768") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"temperature\"") == null);
}

test "serializeContentPart emits a video_url data URI for video_base64" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try serializeContentPart(&buf, allocator, .{ .video_base64 = .{ .data = "AAAA", .media_type = "video/mp4" } });
    try std.testing.expectEqualStrings(
        "{\"type\":\"video_url\",\"video_url\":{\"url\":\"data:video/mp4;base64,AAAA\"}}",
        buf.items,
    );
}

test "convertToolsOpenAI produces valid JSON" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    const tools = &[_]ToolSpec{
        .{
            .name = "shell",
            .description = "Run a \"shell\" command",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}",
        },
        .{
            .name = "file_read",
            .description = "Read a file",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
        },
    };
    try convertToolsOpenAI(&buf, alloc, tools);
    const json = buf.items;

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);

    const t0 = arr.items[0].object;
    try std.testing.expectEqualStrings("function", t0.get("type").?.string);
    const f0 = t0.get("function").?.object;
    try std.testing.expectEqualStrings("shell", f0.get("name").?.string);
    // Description with quotes should be properly escaped
    try std.testing.expect(std.mem.indexOf(u8, f0.get("description").?.string, "\"shell\"") != null);
    try std.testing.expect(f0.get("parameters").? == .object);

    const f1 = arr.items[1].object.get("function").?.object;
    try std.testing.expectEqualStrings("file_read", f1.get("name").?.string);
}

test "convertToolsOpenAI empty tools" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try convertToolsOpenAI(&buf, alloc, &.{});
    try std.testing.expectEqualStrings("[]", buf.items);
}

test "convertToolsOpenAI cleans parameter schema through provider strategy" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    const tools = &[_]ToolSpec{.{
        .name = "lookup",
        .description = "Resolve an item",
        .parameters_json =
        \\{"type":"object","properties":{"id":{"$ref":"#/$defs/Id"}},"$defs":{"Id":{"type":"string","const":"fixed"}}}
        ,
    }};

    try convertToolsOpenAI(&buf, alloc, tools);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"$ref\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"enum\"") != null);
}

test "convertToolsAnthropic produces valid JSON" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    const tools = &[_]ToolSpec{
        .{
            .name = "shell",
            .description = "Run a command",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}",
        },
    };
    try convertToolsAnthropic(&buf, alloc, tools);
    const json = buf.items;

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);

    const t0 = arr.items[0].object;
    try std.testing.expectEqualStrings("shell", t0.get("name").?.string);
    try std.testing.expectEqualStrings("Run a command", t0.get("description").?.string);
    try std.testing.expect(t0.get("input_schema").? == .object);
}

test "convertToolsAnthropic empty tools" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try convertToolsAnthropic(&buf, alloc, &.{});
    try std.testing.expectEqualStrings("[]", buf.items);
}

test "convertToolsAnthropic strips Anthropic-unsupported schema refs" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    const tools = &[_]ToolSpec{.{
        .name = "lookup",
        .description = "Resolve an item",
        .parameters_json =
        \\{"type":"object","properties":{"id":{"$ref":"#/$defs/Id"}},"$defs":{"Id":{"type":"string","minLength":1}}}
        ,
    }};

    try convertToolsAnthropic(&buf, alloc, tools);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"$ref\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"$defs\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"minLength\"") != null);
}

test "providerUrl returns correct URLs" {
    try std.testing.expectEqualStrings(
        "https://api.anthropic.com/v1/messages",
        providerUrl("anthropic"),
    );
    try std.testing.expectEqualStrings(
        "https://api.openai.com/v1/chat/completions",
        providerUrl("openai"),
    );
    try std.testing.expectEqualStrings(
        "https://openrouter.ai/api/v1/chat/completions",
        providerUrl("openrouter"),
    );
    try std.testing.expectEqualStrings(
        "http://localhost:11434/api/chat",
        providerUrl("ollama"),
    );
}

test "extractContent parses OpenAI format" {
    const allocator = std.testing.allocator;
    const body =
        \\{"choices":[{"message":{"content":"Hello there!"}}]}
    ;
    const result = try extractContent(allocator, body);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello there!", result);
}

test "extractContent parses Anthropic format" {
    const allocator = std.testing.allocator;
    const body =
        \\{"content":[{"type":"text","text":"Hello from Claude"}]}
    ;
    const result = try extractContent(allocator, body);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello from Claude", result);
}

test "buildRequestBody escapes double quotes in prompt" {
    const allocator = std.testing.allocator;
    const body = try buildRequestBody(allocator, "gpt-4o", "say \"hello\"", 0.7, 100);
    defer allocator.free(body);
    // Raw quote would break JSON; escaped form must be present
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"hello\\\"") != null);
    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    parsed.deinit();
}

test "buildRequestBody escapes newlines in prompt" {
    const allocator = std.testing.allocator;
    const body = try buildRequestBody(allocator, "gpt-4o", "line1\nline2", 0.7, 100);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    parsed.deinit();
}

test "buildRequestBody escapes backslash in prompt" {
    const allocator = std.testing.allocator;
    const body = try buildRequestBody(allocator, "gpt-4o", "path\\to\\file", 0.7, 100);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\\") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    parsed.deinit();
}

test "buildRequestBodyWithSystem escapes special chars in both fields" {
    const allocator = std.testing.allocator;
    const body = try buildRequestBodyWithSystem(allocator, "gpt-4o", "sys \"role\"", "user\nprompt", 0.7, 100);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"role\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    parsed.deinit();
}

test "serializeMessageContent plain text" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    const msg = root.ChatMessage.user("Hello world");
    try serializeMessageContent(&buf, alloc, msg);
    try std.testing.expectEqualStrings("\"Hello world\"", buf.items);
}

test "serializeMessageContent with content_parts text" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    const parts = &[_]root.ContentPart{
        .{ .text = "Describe this" },
    };
    const msg = root.ChatMessage{
        .role = .user,
        .content = "Describe this",
        .content_parts = parts,
    };
    try serializeMessageContent(&buf, alloc, msg);
    // Should produce an array with a text part
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, buf.items, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);
    try std.testing.expectEqualStrings("text", arr.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("Describe this", arr.items[0].object.get("text").?.string);
}

test "serializeMessageContent with image_base64 part" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    const parts = &[_]root.ContentPart{
        .{ .text = "What is this?" },
        .{ .image_base64 = .{ .data = "iVBOR", .media_type = "image/png" } },
    };
    const msg = root.ChatMessage{
        .role = .user,
        .content = "What is this?",
        .content_parts = parts,
    };
    try serializeMessageContent(&buf, alloc, msg);
    // Verify it produces valid JSON with data URI
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data:image/png;base64,iVBOR") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"type\":\"image_url\"") != null);
}

test "serializeMessageContent with image_url part" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    const parts = &[_]root.ContentPart{
        .{ .image_url = .{ .url = "https://example.com/cat.jpg" } },
    };
    const msg = root.ChatMessage{
        .role = .user,
        .content = "",
        .content_parts = parts,
    };
    try serializeMessageContent(&buf, alloc, msg);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, buf.items, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);
    const img_obj = arr.items[0].object.get("image_url").?.object;
    try std.testing.expectEqualStrings("https://example.com/cat.jpg", img_obj.get("url").?.string);
    try std.testing.expectEqualStrings("auto", img_obj.get("detail").?.string);
}
