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
    /// Native image understanding. When true, image content parts may be sent
    /// directly to this model instead of routing through a vision sidecar
    /// (reliability.vision_fallback). When false, callers fall back.
    vision: bool = false,
    /// Native video understanding. When true, video content parts may be sent
    /// directly to this model.
    video: bool = false,
    /// Native audio understanding. When true, audio may be sent directly
    /// instead of routing through a speech-to-text sidecar.
    audio: bool = false,
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
    // Anthropic — Claude 4.x is vision-capable (images), no native video/audio.
    //
    // V1.14.22 honesty correction (was v1.14.21): the prior synthetic `-1m`
    // suffix entries (`claude-opus-4.6-1m`, `claude-sonnet-4.6-1m`,
    // `gemini-2.5-pro-1m`) were based on Anthropic's retired
    // `context-1m-2025-08-07` beta-header gate. As of April 30 2026 the
    // beta gate is gone — Claude Opus 4.7 and Sonnet 4.6 ship 1M context
    // at standard API pricing on the BASE model ids with no header and
    // no suffix. The `-1m` suffix entries were unreachable (Anthropic
    // 404s on unknown model ids) and have been DELETED. Base entries
    // promoted to 1_000_000 to reflect reality.
    .{ .key = "claude-opus-4-7", .caps = .{ .context_window = 1_000_000, .max_output = 8_192, .vision = true } },
    .{ .key = "claude-opus-4.7", .caps = .{ .context_window = 1_000_000, .max_output = 8_192, .vision = true } },
    .{ .key = "claude-opus-4-6", .caps = .{ .context_window = 1_000_000, .max_output = 8_192, .vision = true } },
    .{ .key = "claude-opus-4.6", .caps = .{ .context_window = 1_000_000, .max_output = 8_192, .vision = true } },
    .{ .key = "claude-sonnet-4-6", .caps = .{ .context_window = 1_000_000, .max_output = 8_192, .vision = true } },
    .{ .key = "claude-sonnet-4.6", .caps = .{ .context_window = 1_000_000, .max_output = 8_192, .vision = true } },
    .{ .key = "claude-haiku-4-5", .caps = .{ .context_window = 200_000, .max_output = 8_192, .vision = true } },
    // OpenAI — GPT-4o/4.1/4.5/5.x accept image input. This table marks vision
    // only; audio-capable variants (e.g. gpt-4o-audio) are not wired here.
    // o3-mini is text-only (left at defaults).
    .{ .key = "gpt-5.2", .caps = .{ .context_window = 128_000, .max_output = 8_192, .vision = true } },
    .{ .key = "gpt-5.2-codex", .caps = .{ .context_window = 128_000, .max_output = 8_192, .vision = true } },
    .{ .key = "gpt-4.5-preview", .caps = .{ .context_window = 128_000, .max_output = 8_192, .vision = true } },
    .{ .key = "gpt-4.1", .caps = .{ .context_window = 128_000, .max_output = 8_192, .vision = true } },
    .{ .key = "gpt-4.1-mini", .caps = .{ .context_window = 128_000, .max_output = 8_192, .vision = true } },
    .{ .key = "gpt-4o", .caps = .{ .context_window = 128_000, .max_output = 8_192, .vision = true } },
    .{ .key = "gpt-4o-mini", .caps = .{ .context_window = 128_000, .max_output = 8_192, .vision = true } },
    .{ .key = "o3-mini", .caps = .{ .context_window = 128_000, .max_output = 8_192 } },
    // Google — Gemini 2.x natively understands images AND video.
    // Gemini 2.5 Pro ships with 1M context natively (Google's published
    // spec). Flash variants stay at 200K. The synthetic `-1m` suffix is
    // gone — use the base id.
    .{ .key = "gemini-2.5-pro", .caps = .{ .context_window = 1_000_000, .max_output = 8_192, .vision = true, .video = true } },
    .{ .key = "gemini-2.5-flash", .caps = .{ .context_window = 200_000, .max_output = 8_192, .vision = true, .video = true } },
    .{ .key = "gemini-2.0-flash", .caps = .{ .context_window = 200_000, .max_output = 8_192, .vision = true, .video = true } },
    // Moonshot / Kimi — K2.5 is text-only; K2.6 is multimodal (vision + video).
    .{ .key = "kimi-k2.5", .caps = .{ .context_window = 262_144, .max_output = 32_768 } },
    .{ .key = "k2p5", .caps = .{ .context_window = 262_144, .max_output = 32_768 } },
    // V1.11 hardening (2026-05-07) — K2.6 full switch. Multimodal (vision +
    // video), 256K context, SWE-Bench Verified 80.2. Same context window as
    // K2.5; Moonshot kept it at 256K rather than expanding. This is the
    // nullalis default model.
    //
    // Per Nova's directive (2026-05-25): only K2.5 + K2.6 are kept in the
    // model-specific table. Every other Moonshot/Kimi SKU on the account
    // (`moonshot-v1-*` family, `kimi-coding`, etc.) is LEGACY — we do not
    // route to them. Adding them to this table would be premature breadth
    // per §14.2 ("every line of code creates compounding value"). If a
    // future need surfaces, add the entry then — not now.
    .{ .key = "kimi-k2.6", .caps = .{ .context_window = 262_144, .max_output = 32_768, .vision = true, .video = true } },
    .{ .key = "k2p6", .caps = .{ .context_window = 262_144, .max_output = 32_768, .vision = true, .video = true } },
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
    // IN-02 (v1.14.22 follow-up): provider-level fallback for UNKNOWN
    // model ids stays at a conservative 200K floor. The reviewer's
    // defensive concern: if Anthropic ships a future Haiku-tier SKU
    // with 200K context and operators route to it without adding the
    // MODEL_TABLE entry, the fallback would assume 1M and the agent
    // would try to fit > 200K → provider 400s. Known 1M models
    // (claude-opus-4.7, claude-sonnet-4.6, gemini-2.5-pro) ALL have
    // explicit MODEL_TABLE entries above; the fallback is only hit
    // for genuinely unknown ids where being conservative is correct.
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
    // Note: pattern matches intentionally leave vision/video/audio at the
    // conservative default (false). The exact MODEL_TABLE is the source of
    // truth for modality; a model recognized only by a broad name prefix
    // routes through the sidecar rather than guessing it is multimodal.

    // Kimi K2 large-context family — K2.5 + K2.6 are explicit in
    // MODEL_TABLE (with .vision/.video flags on K2.6); this pattern
    // catches future dated variants like `kimi-k2.6-20260901`. The
    // older `kimi-coding-*` endpoint is intentionally NOT pattern-
    // matched anymore (legacy per Nova directive 2026-05-25).
    if (startsWithIgnoreCase(model_id, "kimi-k2"))
        return .{ .context_window = 262_144, .max_output = 32_768 };

    // IN-02 (v1.14.22 follow-up): keep the pattern-match fallback at
    // a CONSERVATIVE 200K floor for UNKNOWN Claude / Gemini ids. The
    // 1M-tier models (claude-opus-4.6/4.7, claude-sonnet-4.6,
    // gemini-2.5-pro) all have explicit MODEL_TABLE entries that win
    // first; this fallback only fires for genuinely unrecognized
    // ids. The defensive rationale: if Anthropic ships a future
    // Haiku-tier SKU at 200K and operators route there before adding
    // a MODEL_TABLE entry, optimistically assuming 1M would let the
    // agent try to fit > 200K context and get 400'd by the provider.
    // 200K is the safer pessimistic floor.
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

// ── Modality capability helpers ─────────────────────────────────────────────
//
// Used by the agent's asset-routing logic: when the active model natively
// understands a modality, the asset is sent straight to it; otherwise the
// caller falls back to a sidecar (vision_fallback for images, a speech-to-text
// sidecar for audio). Unknown models return false — conservative: an unknown
// model routes through the sidecar rather than risking a dropped asset.

/// Whether `model_ref` natively understands image input.
pub fn modelSupportsVision(model_ref: []const u8) bool {
    return if (lookupCapabilities(model_ref)) |c| c.vision else false;
}

/// Whether `model_ref` natively understands video input.
pub fn modelSupportsVideo(model_ref: []const u8) bool {
    return if (lookupCapabilities(model_ref)) |c| c.video else false;
}

/// Whether `model_ref` natively understands audio input.
pub fn modelSupportsAudio(model_ref: []const u8) bool {
    return if (lookupCapabilities(model_ref)) |c| c.audio else false;
}

/// How a turn's audio input reaches the model.
pub const AudioInputRoute = enum {
    /// The model understands audio natively — audio is sent straight to it.
    native,
    /// The model is text-only for audio — route through the speech-to-text
    /// (Whisper) sidecar, which transcribes audio to text before the turn.
    transcription_sidecar,
};

/// Decide how audio input should reach `model_ref`. Every model in the table
/// is currently text-only for audio (`audio = false`), so this always returns
/// `.transcription_sidecar` — the existing Whisper-sidecar behaviour. The
/// `.native` arm is reachable only once an audio-capable model is added to
/// the table; such a model must also have a native audio-input path wired
/// (none exists today — audio always arrives already transcribed to text).
pub fn audioInputRoute(model_ref: []const u8) AudioInputRoute {
    return if (modelSupportsAudio(model_ref)) .native else .transcription_sidecar;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "modelSupportsVision: Kimi K2.6 is multimodal, K2.5 is not" {
    try std.testing.expect(modelSupportsVision("kimi-k2.6"));
    try std.testing.expect(modelSupportsVision("moonshot/kimi-k2.6"));
    try std.testing.expect(modelSupportsVision("k2p6"));
    try std.testing.expect(!modelSupportsVision("kimi-k2.5"));
    try std.testing.expect(!modelSupportsVision("k2p5"));
}

test "modelSupportsVideo: Kimi K2.6 and Gemini have native video; others do not" {
    try std.testing.expect(modelSupportsVideo("kimi-k2.6"));
    try std.testing.expect(modelSupportsVideo("gemini-2.5-pro"));
    // Vision-only models are not video-capable.
    try std.testing.expect(!modelSupportsVideo("claude-sonnet-4.6"));
    try std.testing.expect(!modelSupportsVideo("gpt-4o"));
    try std.testing.expect(!modelSupportsVideo("kimi-k2.5"));
}

test "modelSupports* : unknown model is conservatively non-multimodal" {
    try std.testing.expect(!modelSupportsVision("some-unknown-model-xyz"));
    try std.testing.expect(!modelSupportsVideo("some-unknown-model-xyz"));
    try std.testing.expect(!modelSupportsAudio("some-unknown-model-xyz"));
    // No model is marked audio-capable yet.
    try std.testing.expect(!modelSupportsAudio("kimi-k2.6"));
}

test "audioInputRoute: every current model routes to the transcription sidecar" {
    // No model in the table has native audio, so audio input always routes
    // through the Whisper sidecar. This test pins that no-op behaviour —
    // adding an audio-capable model must fail it deliberately.
    try std.testing.expectEqual(AudioInputRoute.transcription_sidecar, audioInputRoute("kimi-k2.6"));
    try std.testing.expectEqual(AudioInputRoute.transcription_sidecar, audioInputRoute("claude-sonnet-4.6"));
    try std.testing.expectEqual(AudioInputRoute.transcription_sidecar, audioInputRoute("gemini-2.5-pro"));
    try std.testing.expectEqual(AudioInputRoute.transcription_sidecar, audioInputRoute("gpt-4o"));
    try std.testing.expectEqual(AudioInputRoute.transcription_sidecar, audioInputRoute("some-unknown-model"));
    try std.testing.expectEqual(AudioInputRoute.transcription_sidecar, audioInputRoute(""));
}

test "vision flag does not disturb context/output capability lookups" {
    const k26 = lookupCapabilities("kimi-k2.6").?;
    try std.testing.expectEqual(@as(u64, 262_144), k26.context_window);
    try std.testing.expectEqual(@as(u32, 32_768), k26.max_output);
    try std.testing.expect(k26.vision and k26.video and !k26.audio);
}

test "resolveMaxTokens honors explicit override" {
    try std.testing.expectEqual(@as(u32, 512), resolveMaxTokens(512, "openai/gpt-4.1-mini"));
}

test "resolveContextTokens honors explicit override" {
    try std.testing.expectEqual(@as(u64, 42_000), resolveContextTokens(42_000, "openai/gpt-4.1-mini"));
}

test "lookupCapabilities known models" {
    // v1.14.22: Claude 4.x now reports 1M context (Anthropic's beta-gated
    // 1M-context tier is GA at standard pricing as of April 30 2026).
    const claude = lookupCapabilities("claude-sonnet-4.6").?;
    try std.testing.expectEqual(@as(u64, 1_000_000), claude.context_window);
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
    try std.testing.expectEqual(@as(u64, 1_000_000), caps.context_window);
    try std.testing.expectEqual(@as(u32, 8_192), caps.max_output);

    const kimi = lookupCapabilities("openrouter/moonshotai/kimi-k2.5").?;
    try std.testing.expectEqual(@as(u64, 262_144), kimi.context_window);
}

test "lookupCapabilities strips date and latest suffixes" {
    const claude_dated = lookupCapabilities("anthropic/claude-sonnet-4.6-20260219").?;
    try std.testing.expectEqual(@as(u64, 1_000_000), claude_dated.context_window);

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

test "Nova-directive (2026-05-25): legacy kimi-coding provider entry removed cleanly" {
    // The `kimi-coding` provider-table entry + the corresponding
    // `startsWithIgnoreCase(model_id, "kimi-coding")` pattern in
    // inferFromPattern were both removed per the K2.5+K2.6-only
    // directive. The provider name `kimi-coding` is now genuinely
    // unrecognized: lookupCapabilities returns null instead of the
    // old bespoke 32K-output entry. Callers fall back to the global
    // DEFAULT_CONTEXT_WINDOW / DEFAULT_MAX_OUTPUT via resolveContextTokens.
    try std.testing.expectEqual(@as(?ModelCapabilities, null), lookupCapabilities("kimi-coding/some-model"));
    // The known K2 ids still resolve correctly (no collateral damage).
    const k26 = lookupCapabilities("kimi-k2.6").?;
    try std.testing.expectEqual(@as(u64, 262_144), k26.context_window);
    try std.testing.expectEqual(@as(u32, 32_768), k26.max_output);
}

test "v1.14.22 — 1M context: Claude Opus 4.7 (base id, no suffix) resolves to 1M" {
    // Anthropic released Opus 4.7 in April 2026 with 1M context native at
    // standard API pricing. No beta header, no -1m suffix needed; the
    // BASE model id is the 1M id.
    const opus_dash = lookupCapabilities("claude-opus-4-7").?;
    try std.testing.expectEqual(@as(u64, 1_000_000), opus_dash.context_window);
    try std.testing.expectEqual(@as(u32, 8_192), opus_dash.max_output);
    try std.testing.expect(opus_dash.vision);

    const opus_dot = lookupCapabilities("claude-opus-4.7").?;
    try std.testing.expectEqual(@as(u64, 1_000_000), opus_dot.context_window);
    try std.testing.expect(opus_dot.vision);

    // Provider-prefixed routing also resolves.
    const via_anthropic = lookupCapabilities("anthropic/claude-opus-4.7").?;
    try std.testing.expectEqual(@as(u64, 1_000_000), via_anthropic.context_window);
}

test "v1.14.22 — 1M context: Gemini 2.5 Pro base id is 1M (native, no suffix)" {
    // Google's published spec: gemini-2.5-pro has 1M context window native.
    const gemini = lookupCapabilities("gemini-2.5-pro").?;
    try std.testing.expectEqual(@as(u64, 1_000_000), gemini.context_window);
    try std.testing.expect(gemini.vision);
    try std.testing.expect(gemini.video);

    // Flash is still 200K — only Pro got the 1M tier.
    const flash = lookupCapabilities("gemini-2.5-flash").?;
    try std.testing.expectEqual(@as(u64, 200_000), flash.context_window);
}

test "v1.14.22 — 1M context: Claude Sonnet 4.6 base id is 1M (beta gate retired)" {
    // Sonnet 4.6's 1M tier was previously gated by the
    // `context-1m-2025-08-07` beta header; that header was retired on
    // April 30 2026 and 1M is now native at standard pricing on the
    // base id.
    const sonnet = lookupCapabilities("claude-sonnet-4.6").?;
    try std.testing.expectEqual(@as(u64, 1_000_000), sonnet.context_window);
    try std.testing.expect(sonnet.vision);

    const sonnet_dash = lookupCapabilities("claude-sonnet-4-6").?;
    try std.testing.expectEqual(@as(u64, 1_000_000), sonnet_dash.context_window);
}

test "v1.14.22 — Kimi K2.6 honestly stays at 262_144 (256K), did NOT extend to 1M" {
    // Moonshot's published spec for K2.6 is 256K (262_144 tokens). There
    // is no Kimi 1M variant. This test pins the §14.5 honesty boundary:
    // we will not silently advertise a context window the provider does
    // not actually support, even if a UI option made the request.
    const k26 = lookupCapabilities("kimi-k2.6").?;
    try std.testing.expectEqual(@as(u64, 262_144), k26.context_window);

    const k26_alias = lookupCapabilities("k2p6").?;
    try std.testing.expectEqual(@as(u64, 262_144), k26_alias.context_window);

    const k25 = lookupCapabilities("kimi-k2.5").?;
    try std.testing.expectEqual(@as(u64, 262_144), k25.context_window);
}

test "v1.14.22 — synthetic -1m suffix entries are GONE from the table" {
    // Comptime audit: walk MODEL_TABLE and assert no entry ends in `-1m`.
    // These entries were based on the retired Anthropic beta header and
    // would route to model ids the provider 404s on. Deleted in v1.14.22.
    inline for (MODEL_TABLE) |entry| {
        try std.testing.expect(!std.mem.endsWith(u8, entry.key, "-1m"));
    }
}
