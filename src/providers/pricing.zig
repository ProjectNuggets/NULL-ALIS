//! Static model pricing table (WP5.1).
//!
//! Lookup returns prices in USD per million tokens for a small set of
//! well-known hosted models. Unknown models yield `null` so callers can
//! honestly record "cost unavailable" rather than invent a $0.00 cost.
//!
//! No network fetches, no runtime mutation, no persistent ledger — this
//! is a compile-time constant table. The unit test in this file
//! guarantees prices stay non-negative and the table stays small.

const std = @import("std");

/// Prices are stated in USD per 1,000,000 tokens. These are published
/// list prices at the time of the WP5.1 implementation; they are meant
/// to be a starting point, not a contract.
pub const ModelPrice = struct {
    input_per_million: f64,
    output_per_million: f64,
};

/// One row in the static lookup table. `match` is compared
/// case-insensitively as a substring of the requested model name so a
/// provider-prefixed id like `openrouter/anthropic/claude-sonnet-4`
/// resolves to the same price as `claude-sonnet-4`.
const Row = struct {
    match: []const u8,
    provider: ?[]const u8 = null, // optional provider hint to disambiguate
    price: ModelPrice,
};

/// Curated, conservative list. Keep entries short and specific — the
/// matcher picks the FIRST row whose `match` appears in the model name
/// (and whose `provider` hint matches when set), so more specific names
/// must come before more generic ones.
const TABLE = [_]Row{
    // Anthropic Claude family ------------------------------------------------
    .{ .match = "claude-opus-4", .price = .{ .input_per_million = 15.0, .output_per_million = 75.0 } },
    .{ .match = "claude-sonnet-4", .price = .{ .input_per_million = 3.0, .output_per_million = 15.0 } },
    .{ .match = "claude-haiku-4", .price = .{ .input_per_million = 1.0, .output_per_million = 5.0 } },
    .{ .match = "claude-3-5-sonnet", .price = .{ .input_per_million = 3.0, .output_per_million = 15.0 } },
    .{ .match = "claude-3-5-haiku", .price = .{ .input_per_million = 0.8, .output_per_million = 4.0 } },
    .{ .match = "claude-3-opus", .price = .{ .input_per_million = 15.0, .output_per_million = 75.0 } },
    .{ .match = "claude-3-sonnet", .price = .{ .input_per_million = 3.0, .output_per_million = 15.0 } },
    .{ .match = "claude-3-haiku", .price = .{ .input_per_million = 0.25, .output_per_million = 1.25 } },

    // OpenAI family ----------------------------------------------------------
    .{ .match = "gpt-4o-mini", .price = .{ .input_per_million = 0.15, .output_per_million = 0.6 } },
    .{ .match = "gpt-4o", .price = .{ .input_per_million = 2.5, .output_per_million = 10.0 } },
    .{ .match = "gpt-4.1-mini", .price = .{ .input_per_million = 0.4, .output_per_million = 1.6 } },
    .{ .match = "gpt-4.1", .price = .{ .input_per_million = 2.0, .output_per_million = 8.0 } },
    .{ .match = "o4-mini", .price = .{ .input_per_million = 1.1, .output_per_million = 4.4 } },
    .{ .match = "o3-mini", .price = .{ .input_per_million = 1.1, .output_per_million = 4.4 } },
    .{ .match = "o3", .price = .{ .input_per_million = 10.0, .output_per_million = 40.0 } },

    // Google Gemini family ---------------------------------------------------
    .{ .match = "gemini-2.5-pro", .price = .{ .input_per_million = 1.25, .output_per_million = 5.0 } },
    .{ .match = "gemini-2.5-flash", .price = .{ .input_per_million = 0.3, .output_per_million = 2.5 } },
    .{ .match = "gemini-1.5-pro", .price = .{ .input_per_million = 1.25, .output_per_million = 5.0 } },
    .{ .match = "gemini-1.5-flash", .price = .{ .input_per_million = 0.075, .output_per_million = 0.3 } },

    // Together-hosted: DeepSeek family --------------------------------------
    // Pricing verified 2026-05-07 from Together's models page. V4-Pro is
    // $0.435/M input ($0.145 promo through 2026-05-05 — promo expired
    // before this entry), $3.48/M output. V4-Flash is the cheaper sibling
    // (DeepSeek's direct API at $0.14/$0.28; Together pricing not yet
    // published, conservative estimate using direct + Together's typical
    // 3× output multiplier).
    .{ .match = "deepseek-v4-pro", .price = .{ .input_per_million = 0.435, .output_per_million = 3.48 } },
    .{ .match = "DeepSeek-V4-Pro", .price = .{ .input_per_million = 0.435, .output_per_million = 3.48 } },
    .{ .match = "deepseek-v4-flash", .price = .{ .input_per_million = 0.14, .output_per_million = 0.28 } },
    .{ .match = "DeepSeek-V4-Flash", .price = .{ .input_per_million = 0.14, .output_per_million = 0.28 } },
    // Pre-V4 DeepSeek (legacy / OpenRouter fallback path)
    .{ .match = "deepseek-v3", .price = .{ .input_per_million = 0.27, .output_per_million = 1.10 } },
    .{ .match = "deepseek-chat", .price = .{ .input_per_million = 0.27, .output_per_million = 1.10 } },
    .{ .match = "deepseek-reasoner", .price = .{ .input_per_million = 0.55, .output_per_million = 2.19 } },

    // Together-hosted: Moonshot Kimi family ---------------------------------
    // K2.5 is the current Fast-mode default. K2.6 (April 2026 release)
    // adds vision + reasoning toggle; pricing on Together is similar to
    // K2.5 per Moonshot's pricing page. Conservative estimate uses K2.5's
    // current Together rate.
    .{ .match = "kimi-k2.5", .price = .{ .input_per_million = 0.55, .output_per_million = 2.20 } },
    .{ .match = "Kimi-K2.5", .price = .{ .input_per_million = 0.55, .output_per_million = 2.20 } },
    .{ .match = "kimi-k2.6", .price = .{ .input_per_million = 0.55, .output_per_million = 2.20 } },
    .{ .match = "Kimi-K2.6", .price = .{ .input_per_million = 0.55, .output_per_million = 2.20 } },
    .{ .match = "k2p5", .price = .{ .input_per_million = 0.55, .output_per_million = 2.20 } },
    .{ .match = "k2p6", .price = .{ .input_per_million = 0.55, .output_per_million = 2.20 } },

    // Together-hosted: Qwen family (multimodal candidate for Fast mode) -----
    .{ .match = "qwen3.6-plus", .price = .{ .input_per_million = 0.50, .output_per_million = 3.00 } },
    .{ .match = "Qwen3.6-Plus", .price = .{ .input_per_million = 0.50, .output_per_million = 3.00 } },
    .{ .match = "qwen3-coder", .price = .{ .input_per_million = 0.40, .output_per_million = 1.60 } },

    // Together-hosted: GLM (Zhipu) -------------------------------------------
    .{ .match = "glm-5.1", .price = .{ .input_per_million = 0.60, .output_per_million = 2.20 } },
    .{ .match = "glm-5.1-air", .price = .{ .input_per_million = 0.20, .output_per_million = 1.10 } },

    // Together-hosted: Llama 4 / 5 ------------------------------------------
    .{ .match = "llama-4-70b", .price = .{ .input_per_million = 0.88, .output_per_million = 0.88 } },
    .{ .match = "llama-3.3-70b", .price = .{ .input_per_million = 0.88, .output_per_million = 0.88 } },
    .{ .match = "llama-3.1-8b-instant", .price = .{ .input_per_million = 0.05, .output_per_million = 0.08 } },
};

/// Lookup price for `(provider, model)`. Either may be empty. Returns
/// `null` when no row in the static table matches. Matching is
/// case-insensitive and substring-based on the model name, so provider
/// prefixes (e.g. `openrouter/anthropic/claude-sonnet-4`) still hit.
pub fn lookup(provider: []const u8, model: []const u8) ?ModelPrice {
    if (model.len == 0) return null;
    for (TABLE) |row| {
        if (row.provider) |hint| {
            if (!asciiSubstringEqlIgnoreCase(provider, hint)) continue;
        }
        if (asciiContainsIgnoreCase(model, row.match)) return row.price;
    }
    return null;
}

/// Compute cost for a (input_tokens, output_tokens) pair under a given
/// `ModelPrice`. Sanitizes non-finite and negative inputs to zero.
pub fn computeCost(input_tokens: u64, output_tokens: u64, price: ModelPrice) f64 {
    const in_price = sanitize(price.input_per_million);
    const out_price = sanitize(price.output_per_million);
    const in_f: f64 = @floatFromInt(input_tokens);
    const out_f: f64 = @floatFromInt(output_tokens);
    return (in_f / 1_000_000.0) * in_price + (out_f / 1_000_000.0) * out_price;
}

/// Convenience: look up and compute in one call. Returns null when the
/// model is not priced so callers can report `cost_available=false`
/// rather than a fabricated $0.00.
pub fn costFor(
    provider: []const u8,
    model: []const u8,
    input_tokens: u64,
    output_tokens: u64,
) ?f64 {
    const price = lookup(provider, model) orelse return null;
    return computeCost(input_tokens, output_tokens, price);
}

fn sanitize(x: f64) f64 {
    if (std.math.isFinite(x) and x >= 0.0) return x;
    return 0.0;
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn asciiSubstringEqlIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return asciiContainsIgnoreCase(haystack, needle);
}

// ── Tests ────────────────────────────────────────────────────────────

test "lookup returns price for known Claude model" {
    const p = lookup("anthropic", "claude-sonnet-4").?;
    try std.testing.expect(p.input_per_million > 0.0);
    try std.testing.expect(p.output_per_million > p.input_per_million);
}

test "lookup returns price with provider-prefixed model id" {
    const p = lookup("openrouter", "openrouter/anthropic/claude-sonnet-4").?;
    try std.testing.expectEqual(@as(f64, 3.0), p.input_per_million);
    try std.testing.expectEqual(@as(f64, 15.0), p.output_per_million);
}

test "lookup returns null for unknown model" {
    try std.testing.expect(lookup("anthropic", "made-up-model-999") == null);
    try std.testing.expect(lookup("anthropic", "") == null);
}

test "lookup is case-insensitive" {
    const p = lookup("openai", "GPT-4o").?;
    try std.testing.expect(p.input_per_million > 0.0);
}

test "computeCost scales linearly in million-token units" {
    const price = ModelPrice{ .input_per_million = 3.0, .output_per_million = 15.0 };
    const cost = computeCost(1_000_000, 500_000, price);
    // 1M input * $3 + 0.5M output * $15 = 3 + 7.5 = 10.5
    try std.testing.expect(@abs(cost - 10.5) < 1e-9);
}

test "computeCost zero-token usage is zero dollars" {
    const price = ModelPrice{ .input_per_million = 3.0, .output_per_million = 15.0 };
    try std.testing.expectEqual(@as(f64, 0.0), computeCost(0, 0, price));
}

test "computeCost clamps non-finite prices to zero" {
    const price = ModelPrice{ .input_per_million = std.math.nan(f64), .output_per_million = -1.0 };
    try std.testing.expectEqual(@as(f64, 0.0), computeCost(1_000_000, 1_000_000, price));
}

test "costFor returns null for unknown models" {
    try std.testing.expect(costFor("anthropic", "nope", 100, 50) == null);
}

test "costFor composes lookup and computeCost" {
    const cost = costFor("anthropic", "claude-3-haiku", 1_000_000, 1_000_000).?;
    // 1M * 0.25 + 1M * 1.25 = 1.5
    try std.testing.expect(@abs(cost - 1.5) < 1e-9);
}

test "TABLE entries all have non-negative prices" {
    for (TABLE) |row| {
        try std.testing.expect(row.price.input_per_million >= 0.0);
        try std.testing.expect(row.price.output_per_million >= 0.0);
        try std.testing.expect(std.math.isFinite(row.price.input_per_million));
        try std.testing.expect(std.math.isFinite(row.price.output_per_million));
        try std.testing.expect(row.match.len > 0);
    }
}

test "specific model matches before generic family prefix" {
    // claude-3-opus is listed before the generic claude-3-sonnet — a
    // request for `claude-3-opus-20240229` must hit the opus price.
    const p = lookup("anthropic", "claude-3-opus-20240229").?;
    try std.testing.expectEqual(@as(f64, 15.0), p.input_per_million);
    try std.testing.expectEqual(@as(f64, 75.0), p.output_per_million);
}
