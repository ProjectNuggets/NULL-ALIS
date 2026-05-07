//! Single source of truth for per-model context window and max-output tokens.
//!
//! Previously split across max_tokens.zig (generation limit) and context_tokens.zig
//! (context window). Having two files with parallel lookup logic meant new models
//! required edits in two places, and the byte-gate in shouldEmbedMemoryEntry could
//! drift from the chunker. This file consolidates both.
//!
//! Callers:
//!   max_tokens.zig     — re-exports resolveMaxTokens / lookupModelMaxTokens
//!   context_tokens.zig — re-exports resolveContextTokens / lookupContextTokens

const std = @import("std");
const config_types = @import("../config_types.zig");

pub const DEFAULT_MAX_OUTPUT: u32 = config_types.DEFAULT_MODEL_MAX_TOKENS;
pub const DEFAULT_CONTEXT_WINDOW: u64 = config_types.DEFAULT_AGENT_TOKEN_LIMIT;

pub const ModelCapabilities = struct {
    /// Full context window (input + output). Used for compaction threshold math.
    context_window: u64,
    /// Maximum generation output tokens. Used for reply-reserve budgeting.
    max_output: u32,
};

// ── Per-model table ─────────────────────────────────────────────────────────
//
// Add new models here. One entry covers both dimensions.
// Use the canonical model ID (no provider prefix, no date suffix).

const ModelEntry = struct {
    key: []const u8,
    caps: ModelCapabilities,
};

const MODEL_TABLE = [_]ModelEntry{
    // Anthropic
    .{ .key = "claude-opus-4-6", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    .{ .key = "claude-opus-4.6", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    .{ .key = "claude-sonnet-4-6", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    .{ .key = "claude-sonnet-4.6", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    .{ .key = "claude-haiku-4-5", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    // OpenAI
    .{ .key = "gpt-5.2", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "gpt-5.2-codex", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "gpt-4.5-preview", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "gpt-4.1", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "gpt-4.1-mini", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "gpt-4o", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "gpt-4o-mini", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "o3-mini", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    // Google
    .{ .key = "gemini-2.5-pro", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    .{ .key = "gemini-2.5-flash", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    .{ .key = "gemini-2.0-flash", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    // Moonshot / Kimi
    .{ .key = "kimi-k2.5", .caps = .{ .context_window = 262_144, .max_output = 32_768 } },
    .{ .key = "k2p5", .caps = .{ .context_window = 262_144, .max_output = 32_768 } },
    // V1.11 hardening (2026-05-07) — K2.6 full switch. Multimodal (vision +
    // video), 256K context, SWE-Bench Verified 80.2. Same context window as
    // K2.5; Moonshot kept it at 256K rather than expanding.
    .{ .key = "kimi-k2.6", .caps = .{ .context_window = 262_144, .max_output = 32_768 } },
    .{ .key = "k2p6", .caps = .{ .context_window = 262_144, .max_output = 32_768 } },
    // DeepSeek
    .{ .key = "deepseek-v3.2", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "deepseek-chat", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "deepseek-reasoner", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    // V4 family (released 2026-04-24). Context window verified from Together's
    // /v1/models endpoint 2026-04-30: V4-Pro=512000 on Together (DeepSeek's
    // native API advertises 1M but the Together-hosted instance is capped
    // at 512K — using the 1M figure would cause 400s at scale). max_output
    // 32_768 is conservative-safe; V4 reasoning_effort=high may emit longer
    // chains-of-thought but stays under cap on Together's deployment.
    .{ .key = "deepseek-v4-pro", .caps = .{ .context_window = 512_000, .max_output = 32_768 } },
    .{ .key = "deepseek-v4-flash", .caps = .{ .context_window = 512_000, .max_output = 32_768 } },
    // Zhipu / GLM
    .{ .key = "glm-5.1", .caps = .{ .context_window = 202_000, .max_output = 65_536 } },
    .{ .key = "glm-5.1-air", .caps = .{ .context_window = 202_000, .max_output = 32_768 } },
    // Google Gemma
    .{ .key = "gemma-4-26b-a4b-it", .caps = .{ .context_window = 256_000, .max_output = 8_192 } },
    .{ .key = "gemma-4-31b-it", .caps = .{ .context_window = 256_000, .max_output = 8_192 } },
    .{ .key = "gemma-4-e2b-it", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "gemma-4-e4b-it", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    // Meta LLaMA / Mixtral
    .{ .key = "llama-4-70b-instruct", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "llama-3.3-70b-versatile", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "llama-3.1-8b-instant", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "mixtral-8x7b-32768", .caps = .{ .context_window = 32_768, .max_output = 8_192 } },
};

// ── Per-provider fallback table ─────────────────────────────────────────────
//
// Used when model-level lookup fails. Provider name = the value in config.provider.

const ProviderEntry = struct {
    key: []const u8,
    caps: ModelCapabilities,
};

const PROVIDER_TABLE = [_]ProviderEntry{
    .{ .key = "anthropic", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    .{ .key = "openai", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "google", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    .{ .key = "gemini", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    .{ .key = "openrouter", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    .{ .key = "minimax", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    .{ .key = "xiaomi", .caps = .{ .context_window = 262_144, .max_output = 8_192 } },
    .{ .key = "openai-codex", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    .{ .key = "moonshot", .caps = .{ .context_window = 256_000, .max_output = 8_192 } },
    .{ .key = "moonshotai", .caps = .{ .context_window = 256_000, .max_output = 8_192 } },
    .{ .key = "kimi", .caps = .{ .context_window = 262_144, .max_output = 8_192 } },
    .{ .key = "kimi-coding", .caps = .{ .context_window = 262_144, .max_output = 32_768 } },
    .{ .key = "together-ai", .caps = .{ .context_window = 200_000, .max_output = 8_192 } },
    .{ .key = "ollama", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "qwen", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "qwen-portal", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "vllm", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "github-copilot", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    .{ .key = "qianfan", .caps = .{ .context_window = 98_304, .max_output = 32_768 } },
    .{ .key = "nvidia", .caps = .{ .context_window = 131_072, .max_output = 4_096 } },
    .{ .key = "byteplus", .caps = .{ .context_window = 128_000, .max_output = 4_096 } },
    .{ .key = "doubao", .caps = .{ .context_window = 128_000, .max_output = 4_096 } },
    .{ .key = "cloudflare-ai-gateway", .caps = .{ .context_window = 128_000, .max_output = 64_000 } },
};

// ── Lookup helpers ──────────────────────────────────────────────────────────

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn stripDateSuffix(model_id: []const u8) []const u8 {
    const last_dash = std.mem.lastIndexOfScalar(u8, model_id, '-') orelse return model_id;
    const suffix = model_id[last_dash + 1 ..];
    if (suffix.len == 8 and isAllDigits(suffix)) return model_id[0..last_dash];
    return model_id;
}

fn stripKnownSuffix(model_id: []const u8) []const u8 {
    if (endsWithIgnoreCase(model_id, "-latest")) return model_id[0 .. model_id.len - "-latest".len];
    return model_id;
}

fn lookupModelTable(key: []const u8) ?ModelCapabilities {
    for (&MODEL_TABLE) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key, key)) return entry.caps;
    }
    return null;
}

fn lookupProviderTable(key: []const u8) ?ModelCapabilities {
    for (&PROVIDER_TABLE) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key, key)) return entry.caps;
    }
    return null;
}

fn inferFromPattern(model_id: []const u8) ?ModelCapabilities {
    // Kimi large-context variants
    if (std.mem.indexOf(u8, model_id, "k2p5") != null or
        startsWithIgnoreCase(model_id, "kimi-k2"))
        return .{ .context_window = 262_144, .max_output = 32_768 };

    // Kimi coding endpoint
    if (startsWithIgnoreCase(model_id, "kimi-coding"))
        return .{ .context_window = 262_144, .max_output = 32_768 };

    if (startsWithIgnoreCase(model_id, "claude-"))
        return .{ .context_window = 200_000, .max_output = 8_192 };

    if (startsWithIgnoreCase(model_id, "gemini-"))
        return .{ .context_window = 200_000, .max_output = 8_192 };

    if (startsWithIgnoreCase(model_id, "gpt-") or
        startsWithIgnoreCase(model_id, "o1") or
        startsWithIgnoreCase(model_id, "o3"))
        return .{ .context_window = 128_000, .max_output = 8_192 };

    // V4 family detected ANYWHERE in the model id (catches the org-prefixed
    // form `deepseek-ai/DeepSeek-V4-Pro` that the generic `deepseek-`
    // startsWith match below would otherwise misroute to 128K). Critical:
    // this must precede the generic deepseek- match.
    if (std.ascii.indexOfIgnoreCase(model_id, "deepseek-v4") != null)
        return .{ .context_window = 512_000, .max_output = 32_768 };

    if (startsWithIgnoreCase(model_id, "deepseek-"))
        return .{ .context_window = 128_000, .max_output = 8_192 };

    if (startsWithIgnoreCase(model_id, "llama") or startsWithIgnoreCase(model_id, "mixtral-"))
        return .{ .context_window = 128_000, .max_output = 8_192 };

    if (startsWithIgnoreCase(model_id, "nvidia/"))
        return .{ .context_window = 131_072, .max_output = 4_096 };

    // Mixtral 32k variant encoded in model name
    if (std.mem.indexOf(u8, model_id, "32768") != null)
        return .{ .context_window = 32_768, .max_output = 8_192 };

    return null;
}

fn lookupModelCandidates(model_id_raw: []const u8) ?ModelCapabilities {
    const no_latest = stripKnownSuffix(model_id_raw);
    const no_date = stripDateSuffix(no_latest);

    if (lookupModelTable(model_id_raw)) |c| return c;
    if (!std.mem.eql(u8, no_latest, model_id_raw)) {
        if (lookupModelTable(no_latest)) |c| return c;
    }
    if (!std.mem.eql(u8, no_date, no_latest)) {
        if (lookupModelTable(no_date)) |c| return c;
    }

    return inferFromPattern(no_date) orelse inferFromPattern(no_latest) orelse inferFromPattern(model_id_raw);
}

fn splitProviderModel(model_ref: []const u8) struct { provider: ?[]const u8, model: []const u8 } {
    const slash = std.mem.indexOfScalar(u8, model_ref, '/') orelse
        return .{ .provider = null, .model = model_ref };
    return .{ .provider = model_ref[0..slash], .model = model_ref[slash + 1 ..] };
}

/// Look up capabilities for a model reference (bare model ID, provider/model,
/// or provider/org/model nested refs). Returns null for unknown models.
pub fn lookupCapabilities(model_ref_raw: []const u8) ?ModelCapabilities {
    const model_ref = std.mem.trim(u8, model_ref_raw, " \t\r\n");
    if (model_ref.len == 0) return null;

    if (lookupModelCandidates(model_ref)) |c| return c;

    const split = splitProviderModel(model_ref);
    if (lookupModelCandidates(split.model)) |c| return c;

    // Support nested refs like openrouter/anthropic/claude-sonnet-4.6
    if (std.mem.indexOfScalar(u8, split.model, '/')) |nested_sep| {
        const nested_provider = split.model[0..nested_sep];
        const nested_model = split.model[nested_sep + 1 ..];
        if (lookupModelCandidates(nested_model)) |c| return c;
        if (lookupProviderTable(nested_provider)) |c| return c;
    }
    if (std.mem.lastIndexOfScalar(u8, split.model, '/')) |last_sep| {
        const leaf_model = split.model[last_sep + 1 ..];
        if (lookupModelCandidates(leaf_model)) |c| return c;
    }

    if (split.provider) |provider| {
        if (lookupProviderTable(provider)) |c| return c;
    }

    return null;
}

/// Resolve max output tokens: explicit override → table → DEFAULT_MAX_OUTPUT.
pub fn resolveMaxTokens(override: ?u32, model_ref: []const u8) u32 {
    if (override) |v| return v;
    if (lookupCapabilities(model_ref)) |c| return c.max_output;
    return DEFAULT_MAX_OUTPUT;
}

/// Resolve context window size: explicit override → table → DEFAULT_CONTEXT_WINDOW.
pub fn resolveContextTokens(override: ?u64, model_ref: []const u8) u64 {
    if (override) |v| return v;
    if (lookupCapabilities(model_ref)) |c| return c.context_window;
    return DEFAULT_CONTEXT_WINDOW;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "resolveMaxTokens honors explicit override" {
    try std.testing.expectEqual(@as(u32, 512), resolveMaxTokens(512, "openai/gpt-4.1-mini"));
}

test "resolveContextTokens honors explicit override" {
    try std.testing.expectEqual(@as(u64, 42_000), resolveContextTokens(42_000, "openai/gpt-4.1-mini"));
}

test "lookupCapabilities known models" {
    const claude = lookupCapabilities("claude-sonnet-4.6").?;
    try std.testing.expectEqual(@as(u64, 200_000), claude.context_window);
    try std.testing.expectEqual(@as(u32, 8_192), claude.max_output);

    const kimi = lookupCapabilities("kimi-k2.5").?;
    try std.testing.expectEqual(@as(u64, 262_144), kimi.context_window);
    try std.testing.expectEqual(@as(u32, 32_768), kimi.max_output);

    const gpt41 = lookupCapabilities("openai/gpt-4.1-mini").?;
    try std.testing.expectEqual(@as(u64, 128_000), gpt41.context_window);
    try std.testing.expectEqual(@as(u32, 8_192), gpt41.max_output);
}

test "lookupCapabilities nested openrouter refs" {
    const caps = lookupCapabilities("openrouter/anthropic/claude-sonnet-4.6").?;
    try std.testing.expectEqual(@as(u64, 200_000), caps.context_window);
    try std.testing.expectEqual(@as(u32, 8_192), caps.max_output);

    const kimi = lookupCapabilities("openrouter/moonshotai/kimi-k2.5").?;
    try std.testing.expectEqual(@as(u64, 262_144), kimi.context_window);
}

test "lookupCapabilities strips date and latest suffixes" {
    const claude_dated = lookupCapabilities("anthropic/claude-sonnet-4.6-20260219").?;
    try std.testing.expectEqual(@as(u64, 200_000), claude_dated.context_window);

    const gpt_latest = lookupCapabilities("openai/gpt-4.1-latest").?;
    try std.testing.expectEqual(@as(u32, 8_192), gpt_latest.max_output);
}

test "lookupCapabilities provider-level fallback" {
    const qianfan = lookupCapabilities("qianfan/custom-model").?;
    try std.testing.expectEqual(@as(u64, 98_304), qianfan.context_window);
    try std.testing.expectEqual(@as(u32, 32_768), qianfan.max_output);

    const nvidia = lookupCapabilities("nvidia/custom-model").?;
    try std.testing.expectEqual(@as(u32, 4_096), nvidia.max_output);
}

test "lookupCapabilities unknown model falls back to null" {
    try std.testing.expectEqual(@as(?ModelCapabilities, null), lookupCapabilities("unknown-provider/unknown-model"));
}

test "resolveMaxTokens falls back to global default" {
    try std.testing.expectEqual(DEFAULT_MAX_OUTPUT, resolveMaxTokens(null, "unknown-provider/unknown-model"));
}

test "resolveContextTokens falls back to global default" {
    try std.testing.expectEqual(DEFAULT_CONTEXT_WINDOW, resolveContextTokens(null, "unknown-provider/unknown-model"));
}

test "Mode-swap 2026-04-29 — DeepSeek V4 family resolves to 512K context, not 128K fallback" {
    // The org-prefixed form Together uses must NOT fall through to the
    // generic `deepseek-` match (which returns 128K and would silently
    // under-utilize the model's 512K window).
    const v4_pro = lookupCapabilities("deepseek-ai/DeepSeek-V4-Pro").?;
    try std.testing.expectEqual(@as(u64, 512_000), v4_pro.context_window);
    try std.testing.expectEqual(@as(u32, 32_768), v4_pro.max_output);

    // Provider-prefixed nesting (together-ai/deepseek-ai/...) also resolves.
    const v4_pro_nested = lookupCapabilities("together-ai/deepseek-ai/DeepSeek-V4-Pro").?;
    try std.testing.expectEqual(@as(u64, 512_000), v4_pro_nested.context_window);

    // V4-Flash same shape.
    const v4_flash = lookupCapabilities("deepseek-ai/DeepSeek-V4-Flash").?;
    try std.testing.expectEqual(@as(u64, 512_000), v4_flash.context_window);

    // Older DeepSeek versions deliberately stay at 128K (unchanged).
    const v3 = lookupCapabilities("deepseek-ai/DeepSeek-V3.1").?;
    try std.testing.expectEqual(@as(u64, 128_000), v3.context_window);
}

test "kimi-coding provider has large output ceiling" {
    const caps = lookupCapabilities("kimi-coding/some-model").?;
    try std.testing.expectEqual(@as(u32, 32_768), caps.max_output);
    try std.testing.expectEqual(@as(u64, 262_144), caps.context_window);
}
