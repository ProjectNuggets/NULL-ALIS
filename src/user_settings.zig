const std = @import("std");
const config_types = @import("config_types.zig");
const Config = @import("config.zig").Config;
// V1.14.4 review MD-04 — pulled from config_types' re-export rather
// than direct security/policy import, honoring the documented
// "single source of truth" indirection at config_types.zig:12.
const AutonomyLevel = config_types.AutonomyLevel;
const AUTONOMY_FULL_ACKNOWLEDGED_KEY = "autonomy_full_acknowledged";

pub const AssistantMode = enum {
    fast,
    balanced,
    deep,

    fn fromString(raw: []const u8) ?AssistantMode {
        if (std.ascii.eqlIgnoreCase(raw, "fast")) return .fast;
        if (std.ascii.eqlIgnoreCase(raw, "balanced")) return .balanced;
        if (std.ascii.eqlIgnoreCase(raw, "deep")) return .deep;
        return null;
    }

    pub fn toSlice(self: AssistantMode) []const u8 {
        return switch (self) {
            .fast => "fast",
            .balanced => "balanced",
            .deep => "deep",
        };
    }
};

pub const GroupActivation = enum {
    mention,
    always,

    fn fromString(raw: []const u8) ?GroupActivation {
        if (std.ascii.eqlIgnoreCase(raw, "mention")) return .mention;
        if (std.ascii.eqlIgnoreCase(raw, "always")) return .always;
        return null;
    }

    pub fn toSlice(self: GroupActivation) []const u8 {
        return switch (self) {
            .mention => "mention",
            .always => "always",
        };
    }
};

pub const ProductSettings = struct {
    assistant_mode: AssistantMode = .balanced,
    group_activation: GroupActivation = .mention,
    proactive_updates: bool = false,
    voice_replies: bool = false,
    session_timeout_minutes: u32 = 30,
    /// V1.14.4 (booth-readiness, autonomy toggle wire-up).
    ///
    /// User-controllable autonomy: `.read_only` (no writes), `.supervised`
    /// (dangerous and paid side effects approval-gated), `.full` (auto-approve within
    /// SecurityPolicy bounds). Default matches `AutonomyConfig.level`'s
    /// default (`.supervised`) — single source of truth
    /// for "what does a fresh user get."
    ///
    /// Gap pre-V1.14.4: FE shipped this toggle as
    /// `autonomy: "read_only" | "supervised" | "full"` (zaki-prod
    /// ZakiSettingsSheet.tsx:79, default "supervised"); backend
    /// ProductSettings struct didn't have the field, so saving from FE
    /// silently no-op'd at the backend. parseProductSettings rejected
    /// the field as InvalidPayload, but the FE error was swallowed by
    /// retry logic. Now wired.
    autonomy: AutonomyLevel = .supervised,
    /// Runtime-only migration signal. Stored `.full` values created before
    /// informed-choice provenance existed are downgraded to `.supervised` and
    /// set this flag so the tenant runtime can persist the normalized row.
    /// This field is never rendered to the settings API.
    legacy_full_autonomy_migrated: bool = false,
    /// 2026-05-24 (v1.14.21 final-sprint) — user toggle for the nightly
    /// 3 AM dream-reflection cron job declared in `AUTOMATIONS.json`.
    /// Default true: every new tenant gets a nightly reflection out of
    /// the box. When false, the daemon's wake-turn reconciler honors the
    /// flag and uninstalls (or skips installing) the canonical dream_3am
    /// job. Pairs with `_user_facing.user_toggle_setting = "dream_enabled"`
    /// on the matching AUTOMATIONS.json entry.
    dream_enabled: bool = true,
    /// 2026-05-24 (v1.14.21 final-sprint) — user toggle for LLM-based
    /// query expansion at memory-retrieval time. Adds one cheap LLM call
    /// per query to widen the search ("zed" → "zed editor preferences
    /// development tools"). Default false because it has a real per-query
    /// cost; UI should label it "Expand my queries with AI (costs more,
    /// improves recall on short / vague questions)." Maps to
    /// `memory.retrieval_stages.query_expansion_enabled` at runtime.
    query_expansion_enabled: bool = false,
    /// Per-tenant privacy opt-in for wish-to-Decision-Hub matchmaking.
    /// Defaults false so wish-derived queries never leave the tenant unless
    /// this exact tenant enables the feature.
    wish_matchmaking_enabled: bool = false,
    /// 2026-05-25 (v1.14.22 hotfix sprint) — per-user model selection.
    ///
    /// When non-null, this overrides `cfg.default_model` for this tenant's
    /// turns (set in `applySettingsToConfig` AFTER profile defaults / env
    /// overrides land, so the user choice is the last writer). When null,
    /// the operator-configured `default_model` is used (existing behavior).
    ///
    /// The FE renders a model picker; the selection round-trips through
    /// product_settings → mergeSettingsIntoConfigJson → tenant config →
    /// applySettingsToConfig → cfg.default_model → provider router. Switching
    /// the picker is end-to-end real, not a half-wired claim.
    ///
    /// Validation: parseProductSettings rejects unknown ids with
    /// `error.InvalidSelectedModel`. The allowlist is `SELECTED_MODEL_ALLOWLIST`
    /// below; operators add new ids there. We intentionally do NOT echo
    /// arbitrary tenant input into cfg.default_model — a tenant could
    /// otherwise smuggle in a model id with embedded provider routing
    /// (e.g. "openrouter/proxy.evil/model-x") that bypasses the operator's
    /// provider allowlist.
    ///
    /// Storage: `SelectedModelBuf` is a fixed-size inline buffer (64 bytes,
    /// well above the longest allowlisted id) so the field is self-owned and
    /// does not alias arena memory from JSON parsing. Use `selectedModelSlice()`
    /// to read the string, and `setSelectedModel()` to set it from a slice.
    /// `selected_model_set = false` means null.
    selected_model_set: bool = false,
    selected_model_buf: SelectedModelBuf = .{},

    pub fn selectedModelSlice(self: *const ProductSettings) ?[]const u8 {
        if (!self.selected_model_set) return null;
        return self.selected_model_buf.bytes[0..self.selected_model_buf.len];
    }

    pub fn setSelectedModel(self: *ProductSettings, value: ?[]const u8) error{SelectedModelTooLong}!void {
        if (value) |s| {
            if (s.len > self.selected_model_buf.bytes.len) return error.SelectedModelTooLong;
            self.selected_model_buf.len = @intCast(s.len);
            @memcpy(self.selected_model_buf.bytes[0..s.len], s);
            self.selected_model_set = true;
        } else {
            self.selected_model_set = false;
            self.selected_model_buf.len = 0;
        }
    }
};

/// Fixed-size storage for ProductSettings.selected_model. 64 bytes is well
/// above any allowlisted id (longest is ~20 chars), and the inline shape
/// keeps the field independent of JSON arena lifetime.
pub const SelectedModelBuf = struct {
    bytes: [64]u8 = [_]u8{0} ** 64,
    len: u8 = 0,

    pub fn slice(self: *const SelectedModelBuf) []const u8 {
        return self.bytes[0..self.len];
    }
};

// ── Per-user model selection allowlist ──────────────────────────────────────
//
// v1.14.22 (2026-05-25). Tenants choose from this list via the FE settings
// picker. New ids must be added explicitly — see selected_model docstring.
//
// Pricing note: Kimi K2.6 is the default cheap option (262K context, ~$0.40
// per million in / ~$2 out at Moonshot's published rate as of May 2026).
// Anthropic Opus 4.7 is the premium 1M-context option. Pricing varies — we
// don't enforce a price ceiling here; that's the operator's metering job.
//
// Case-insensitive match (FE may send any casing).
const SELECTED_MODEL_ALLOWLIST = [_][]const u8{
    // Moonshot / Kimi — cheap defaults, 256K context
    "kimi-k2.6",
    "kimi-k2.5",
    "k2p6",
    "k2p5",
    // Anthropic — Claude 4.x with 1M-context tier on Opus 4.7 / Sonnet 4.6
    "claude-opus-4.7",
    "claude-opus-4-7",
    "claude-opus-4.6",
    "claude-opus-4-6",
    "claude-sonnet-4.6",
    "claude-sonnet-4-6",
    "claude-haiku-4-5",
    // OpenAI
    "gpt-5.2",
    "gpt-4.1",
    // Google — Gemini 2.5 Pro has 1M context native
    "gemini-2.5-pro",
    "gemini-2.5-flash",
    // DeepSeek
    "deepseek-v4-pro",
    "deepseek-v4-flash",
};

fn isAllowedSelectedModel(candidate: []const u8) bool {
    for (SELECTED_MODEL_ALLOWLIST) |allowed| {
        if (std.ascii.eqlIgnoreCase(allowed, candidate)) return true;
    }
    return false;
}

pub const Error = error{
    InvalidPayload,
    InvalidAssistantMode,
    InvalidGroupActivation,
    InvalidProactiveUpdates,
    InvalidVoiceReplies,
    InvalidSessionTimeoutMinutes,
    InvalidAutonomy,
    /// v1.14.22 — `selected_model` was present but is not on the per-user
    /// model picker allowlist (`SELECTED_MODEL_ALLOWLIST`). The tenant
    /// either typo'd the model id or attempted to set a model the operator
    /// does not whitelist for direct selection.
    InvalidSelectedModel,
};

pub const OwnershipPlane = enum {
    operator,
    tenant_preference,
    tenant_integration,
    derived,
    unknown,
};

// iter35: ModeMapping is a lookup table for legacy-config inference only
// (deriveNearestFromAgentObject → deriveNearestFromConfigJson → snap pre-
// product_settings configs to an assistant_mode). Only queue_mode / queue_cap
// / queue_drop / max_history_messages are read for scoring. Removed
// summarizer_* (never read) and the dead `mappingFor` function.
// Numeric values here are just snap SIGNAL — they reflect the pre-
// context-v2 era's config shape so old configs still migrate cleanly.
// Legacy values used only for pre-context-v2 config migration.
const ModeMapping = struct {
    mode: AssistantMode,
    queue_mode: []const u8,
    queue_cap: u32,
    queue_drop: []const u8,
    max_history_messages: u32,
};

const mode_mappings = [_]ModeMapping{
    // Q1 (2026-04-27): max_history_messages set to 0 across all modes —
    // post-iter26 the field is uncapped at runtime; the legacy 40/50/80
    // values were a snap signal for pre-context-v2 era configs and
    // visually misleading on audit. Scoring still works (absDiffU32(v, 0)
    // ranks any non-zero user value lower equally). Compaction is the
    // sole context governor.
    .{
        .mode = .fast,
        .queue_mode = "latest",
        .queue_cap = 8,
        .queue_drop = "newest",
        .max_history_messages = 0,
    },
    .{
        .mode = .balanced,
        .queue_mode = "serial",
        .queue_cap = 12,
        .queue_drop = "summarize",
        .max_history_messages = 0,
    },
    .{
        .mode = .deep,
        .queue_mode = "serial",
        .queue_cap = 20,
        .queue_drop = "summarize",
        .max_history_messages = 0,
    },
};

const operator_owned_top_level_config_keys = [_][]const u8{
    "profile",
    "providers",
    "audio_media",
    "default_provider",
    "default_model",
    "default_temperature",
    "max_tokens",
    "reasoning_effort",
    "model_routes",
    "agents",
    "bindings",
    "mcp_servers",
    // Sprint 3 — operator-owned, NOT tenant-settable. An api_specs entry
    // declares an outbound integration plus a credential reference; a
    // tenant must not be able to point the agent at an arbitrary API or
    // swap a spec's auth_ref. Same posture as mcp_servers.
    "api_specs",
    "diagnostics",
    "autonomy",
    "runtime",
    "network",
    "reliability",
    "scheduler",
    "agent",
    // Finding #3 (2026-05-22): the sidecar model is the cheap auxiliary
    // LLM for structured extraction, compaction summarization, and the
    // narration fallback — operator infrastructure, exactly like `agent`
    // and `reliability`. It must NOT be tenant-settable: a stale tenant
    // `sidecar` block (e.g. bench-seeded groq/llama-3.1-8b-instant) would
    // shadow the operator's extraction-model choice and silently route
    // every boundary extraction through the wrong provider/tier.
    "sidecar",
    "heartbeat",
    "cron",
    "channels",
    "memory",
    "tunnel",
    "gateway",
    "tenant",
    "state",
    "composio",
    "secrets",
    "browser",
    "http_request",
    "identity",
    "cost",
    "peripherals",
    // "hardware" removed D19 (2026-04-25) — surface fully stripped.
    "security",
    "tools",
    "session",
    "models",
};

const tenant_preference_product_settings_keys = [_][]const u8{
    "assistant_mode",
    "group_activation",
    "proactive_updates",
    "voice_replies",
    "session_timeout_minutes",
    "autonomy",
    AUTONOMY_FULL_ACKNOWLEDGED_KEY,
    "dream_enabled",
    "query_expansion_enabled",
    "wish_matchmaking_enabled",
    "selected_model",
};

pub const NormalizedTenantConfig = struct {
    json: []u8,
    ignored_override_count: usize,
    settings: ProductSettings,
};

pub fn defaults() ProductSettings {
    return .{};
}

pub fn topLevelKeyOwnership(key: []const u8) OwnershipPlane {
    if (std.mem.eql(u8, key, "product_settings")) return .tenant_preference;
    inline for (operator_owned_top_level_config_keys) |owned_key| {
        if (std.mem.eql(u8, key, owned_key)) return .operator;
    }
    return .unknown;
}

pub fn productSettingsFieldOwnership(key: []const u8) OwnershipPlane {
    inline for (tenant_preference_product_settings_keys) |owned_key| {
        if (std.mem.eql(u8, key, owned_key)) return .tenant_preference;
    }
    return .unknown;
}

pub fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidAssistantMode => "invalid_assistant_mode",
        error.InvalidGroupActivation => "invalid_group_activation",
        error.InvalidProactiveUpdates => "invalid_proactive_updates",
        error.InvalidVoiceReplies => "invalid_voice_replies",
        error.InvalidSessionTimeoutMinutes => "invalid_session_timeout_minutes",
        error.InvalidAutonomy => "invalid_autonomy",
        error.InvalidSelectedModel => "invalid_selected_model",
        else => "invalid_payload",
    };
}

pub fn extractFromConfigJson(allocator: std.mem.Allocator, config_json: []const u8) !?ProductSettings {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, config_json, .{}) catch return null;
    if (parsed.value != .object) return null;
    const product = parsed.value.object.get("product_settings") orelse return null;
    return parseProductSettings(product) catch null;
}

pub fn deriveNearestFromConfigJson(allocator: std.mem.Allocator, config_json: []const u8) !ProductSettings {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, config_json, .{}) catch return defaults();
    if (parsed.value != .object) return defaults();
    // V1.14.4 review MD-01 — operator-set autonomy.level is honored when
    // the tenant has no `product_settings` block. Pre-fix path returned
    // defaults() ⇒ the struct default regardless of operator config, silently
    // elevating autonomy on first FE save. Now we extract autonomy.level
    // (if present at the top level) BEFORE delegating to the agent-shape
    // snapper, then merge it into the snapped result.
    var operator_autonomy: ?AutonomyLevel = null;
    if (parsed.value.object.get("autonomy")) |aut_val| {
        if (aut_val == .object) {
            if (aut_val.object.get("level")) |lvl| {
                if (lvl == .string) {
                    operator_autonomy = AutonomyLevel.fromString(lvl.string);
                }
            }
        }
    }
    const agent_val = parsed.value.object.get("agent") orelse {
        var fallback = defaults();
        if (operator_autonomy) |ao| fallback.autonomy = ao;
        return fallback;
    };
    if (agent_val != .object) {
        var fallback = defaults();
        if (operator_autonomy) |ao| fallback.autonomy = ao;
        return fallback;
    }
    var snapped = deriveNearestFromAgentObject(agent_val.object);
    if (operator_autonomy) |ao| snapped.autonomy = ao;
    return snapped;
}

pub fn resolveSettingsFromConfigJson(allocator: std.mem.Allocator, config_json: []const u8) !ProductSettings {
    if (try extractFromConfigJson(allocator, config_json)) |settings| return settings;
    return deriveNearestFromConfigJson(allocator, config_json);
}

pub fn applyPatchToSettingsJson(
    allocator: std.mem.Allocator,
    base: ProductSettings,
    patch_json: []const u8,
) Error!ProductSettings {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, patch_json, .{}) catch return error.InvalidPayload;
    if (parsed.value != .object) return error.InvalidPayload;

    var next = base;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "assistant_mode")) {
            if (value != .string) return error.InvalidAssistantMode;
            next.assistant_mode = AssistantMode.fromString(value.string) orelse return error.InvalidAssistantMode;
            continue;
        }
        if (std.mem.eql(u8, key, "group_activation")) {
            if (value != .string) return error.InvalidGroupActivation;
            next.group_activation = GroupActivation.fromString(value.string) orelse return error.InvalidGroupActivation;
            continue;
        }
        if (std.mem.eql(u8, key, "proactive_updates")) {
            if (value != .bool) return error.InvalidProactiveUpdates;
            next.proactive_updates = value.bool;
            continue;
        }
        if (std.mem.eql(u8, key, "voice_replies")) {
            if (value != .bool) return error.InvalidVoiceReplies;
            next.voice_replies = value.bool;
            continue;
        }
        if (std.mem.eql(u8, key, "session_timeout_minutes")) {
            if (value != .integer or value.integer < 0) return error.InvalidSessionTimeoutMinutes;
            next.session_timeout_minutes = clampSessionTimeoutMinutesI64(value.integer);
            continue;
        }
        if (std.mem.eql(u8, key, "autonomy")) {
            if (value != .string) return error.InvalidAutonomy;
            next.autonomy = AutonomyLevel.fromString(value.string) orelse return error.InvalidAutonomy;
            next.legacy_full_autonomy_migrated = false;
            continue;
        }
        if (std.mem.eql(u8, key, "dream_enabled")) {
            if (value != .bool) return error.InvalidPayload;
            next.dream_enabled = value.bool;
            continue;
        }
        if (std.mem.eql(u8, key, "query_expansion_enabled")) {
            if (value != .bool) return error.InvalidPayload;
            next.query_expansion_enabled = value.bool;
            continue;
        }
        if (std.mem.eql(u8, key, "wish_matchmaking_enabled")) {
            if (value != .bool) return error.InvalidPayload;
            next.wish_matchmaking_enabled = value.bool;
            continue;
        }
        if (std.mem.eql(u8, key, "selected_model")) {
            // v1.14.22 — same validation rules as parseProductSettings.
            // String must be on SELECTED_MODEL_ALLOWLIST; null clears
            // the current selection; any other shape is rejected.
            switch (value) {
                .null => {
                    next.setSelectedModel(null) catch return error.InvalidSelectedModel;
                },
                .string => |s| {
                    if (s.len == 0) {
                        next.setSelectedModel(null) catch return error.InvalidSelectedModel;
                    } else {
                        if (!isAllowedSelectedModel(s)) return error.InvalidSelectedModel;
                        next.setSelectedModel(s) catch return error.InvalidSelectedModel;
                    }
                },
                else => return error.InvalidSelectedModel,
            }
            continue;
        }
        return error.InvalidPayload;
    }
    return next;
}

pub fn mergeSettingsIntoConfigJson(
    allocator: std.mem.Allocator,
    existing_config_json: []const u8,
    settings: ProductSettings,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root = parseRootOrEmptyObject(a, existing_config_json);
    const root_obj = ensureObject(&root, a);

    const product_obj = ensureObjectKey(root_obj, a, "product_settings");
    try putString(product_obj, a, "assistant_mode", settings.assistant_mode.toSlice());
    try putString(product_obj, a, "group_activation", settings.group_activation.toSlice());
    try putBool(product_obj, a, "proactive_updates", settings.proactive_updates);
    try putBool(product_obj, a, "voice_replies", settings.voice_replies);
    try putInt(product_obj, a, "session_timeout_minutes", settings.session_timeout_minutes);
    try putString(product_obj, a, "autonomy", settings.autonomy.toString());
    if (settings.autonomy == .full) {
        try putBool(product_obj, a, AUTONOMY_FULL_ACKNOWLEDGED_KEY, true);
    } else {
        _ = product_obj.swapRemove(AUTONOMY_FULL_ACKNOWLEDGED_KEY);
    }
    try putBool(product_obj, a, "dream_enabled", settings.dream_enabled);
    try putBool(product_obj, a, "query_expansion_enabled", settings.query_expansion_enabled);
    try putBool(product_obj, a, "wish_matchmaking_enabled", settings.wish_matchmaking_enabled);
    // v1.14.22 — when the tenant has picked a model, persist it; when they
    // haven't, ensure any stale key is REMOVED so the round-trip doesn't
    // resurrect a deleted choice on the next read.
    if (settings.selectedModelSlice()) |sm| {
        try putString(product_obj, a, "selected_model", sm);
    } else {
        _ = product_obj.swapRemove("selected_model");
    }

    var rendered = try std.json.Stringify.valueAlloc(allocator, root, .{});
    if (rendered.len == 0 or rendered[rendered.len - 1] != '\n') {
        const with_nl = try std.fmt.allocPrint(allocator, "{s}\n", .{rendered});
        allocator.free(rendered);
        rendered = with_nl;
    }
    return rendered;
}

pub fn normalizeTenantConfigJson(
    allocator: std.mem.Allocator,
    existing_config_json: []const u8,
) !NormalizedTenantConfig {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root = parseRootOrEmptyObject(a, existing_config_json);
    const root_obj = ensureObject(&root, a);
    const settings = resolveSettingsFromConfigJson(allocator, existing_config_json) catch defaults();

    // Allowlist inversion (Finding #3 follow-up, 2026-05-22): a tenant
    // config may carry exactly ONE top-level key — `product_settings`.
    // Everything else at the top level is operator infrastructure and is
    // stripped. The prior design iterated `operator_owned_top_level_config_keys`
    // and removed listed keys — deny-by-omission: a key NOT on the list
    // (e.g. `sidecar` — finding #3) leaked straight through to the tenant.
    // A strict allowlist makes "strip" the safe default: a newly added
    // operator key is locked down automatically, and typo'd / unknown keys
    // are removed too. `operator_owned_top_level_config_keys` /
    // `topLevelKeyOwnership` remain for OwnershipPlane diagnostics — they
    // are no longer the enforcement mechanism.
    const tenant_allowed_top_level_keys = [_][]const u8{"product_settings"};
    var ignored_override_count: usize = 0;
    {
        // Collect keys first — cannot swapRemove while iterating the map.
        var keys_to_strip: std.ArrayListUnmanaged([]const u8) = .empty;
        defer keys_to_strip.deinit(a);
        var it = root_obj.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            var allowed = false;
            inline for (tenant_allowed_top_level_keys) |ak| {
                if (std.mem.eql(u8, key, ak)) allowed = true;
            }
            if (!allowed) try keys_to_strip.append(a, key);
        }
        for (keys_to_strip.items) |key| {
            if (root_obj.swapRemove(key)) ignored_override_count += 1;
        }
    }

    const product_obj = ensureObjectKey(root_obj, a, "product_settings");
    try putString(product_obj, a, "assistant_mode", settings.assistant_mode.toSlice());
    try putString(product_obj, a, "group_activation", settings.group_activation.toSlice());
    try putBool(product_obj, a, "proactive_updates", settings.proactive_updates);
    try putBool(product_obj, a, "voice_replies", settings.voice_replies);
    try putInt(product_obj, a, "session_timeout_minutes", settings.session_timeout_minutes);
    try putString(product_obj, a, "autonomy", settings.autonomy.toString());
    if (settings.autonomy == .full) {
        try putBool(product_obj, a, AUTONOMY_FULL_ACKNOWLEDGED_KEY, true);
    } else {
        _ = product_obj.swapRemove(AUTONOMY_FULL_ACKNOWLEDGED_KEY);
    }
    try putBool(product_obj, a, "dream_enabled", settings.dream_enabled);
    try putBool(product_obj, a, "query_expansion_enabled", settings.query_expansion_enabled);
    try putBool(product_obj, a, "wish_matchmaking_enabled", settings.wish_matchmaking_enabled);
    if (settings.selectedModelSlice()) |sm| {
        try putString(product_obj, a, "selected_model", sm);
    } else {
        _ = product_obj.swapRemove("selected_model");
    }

    var rendered = try std.json.Stringify.valueAlloc(allocator, root, .{});
    if (rendered.len == 0 or rendered[rendered.len - 1] != '\n') {
        const with_nl = try std.fmt.allocPrint(allocator, "{s}\n", .{rendered});
        allocator.free(rendered);
        rendered = with_nl;
    }
    return .{
        .json = rendered,
        .ignored_override_count = ignored_override_count,
        .settings = settings,
    };
}

pub fn applySettingsToConfig(cfg: *Config, settings: ProductSettings) void {
    // MODE-UNIFICATION (v1.14.18-A F1): reasoning_effort is the single knob.
    // User-set value (from config.json) wins; otherwise derive from assistant_mode.
    //
    // Mapping: fast → low, balanced → medium, deep → high.
    // This closes the R-effort-override deferred item: user explicitly-set
    // reasoning_effort now takes precedence over mode-derived value.
    if (cfg.reasoning_effort == null) {
        // User did not explicitly set reasoning_effort in config.json.
        // Derive from assistant_mode (legacy UI selector).
        const effort_value = switch (settings.assistant_mode) {
            .fast => "low",
            .balanced => "medium",
            .deep => "high",
        };
        cfg.reasoning_effort = effort_value;
    }
    // If cfg.reasoning_effort is already set (not null), user explicitly configured
    // it and we honor that choice — do not override with mode-derived value.

    cfg.agent.activation_mode = settings.group_activation.toSlice();
    cfg.agent.send_mode = if (settings.proactive_updates) "inherit" else "off";
    cfg.agent.tts_mode = if (settings.voice_replies) "inbound" else "off";
    cfg.agent.tts_audio = settings.voice_replies;
    // V1.14.11 — session_timeout_minutes wires to the IDLE eviction
    // timer, not the hard TTL. User mental model of "session timeout"
    // (Slack/Discord/Notion convention) means "evict after N minutes
    // of no activity," not "hard-kill at N minutes from creation."
    // Hard TTL (`session_ttl_secs`) stays operator-controlled via raw
    // config.json for the rare deployments that actually want it.
    // Downstream reader: daemon.zig:2325 evictIdle(idle_timeout_secs).
    cfg.agent.session_idle_timeout_secs = @as(u64, settings.session_timeout_minutes) * 60;
    cfg.session.cross_channel_shared_main = false;

    // V1.14.4 (booth-readiness, autonomy toggle) — propagate user-chosen
    // autonomy into the operative SecurityPolicy via cfg.autonomy.level.
    // Downstream readers:
    //   - capabilities.zig:108 (allowed_paths plumbing — operator surface)
    //   - security/policy.zig (gate decisions — autonomy.level drives
    //     read_only block, supervised approval-gate, full auto-approve)
    //   - security/approval_modes.zig::ApprovalPolicy.forTool
    //     (per-tool decision: returns auto_approve / confirm_once / deny
    //     based on tool risk level × autonomy level)
    //
    // The other AutonomyConfig fields (workspace_only, max_actions_per_hour,
    // allowed_commands, allowed_paths, etc.) stay operator-controlled
    // via config.json — those are deployment policy, not user
    // preference. The user choice is solely the level.
    cfg.autonomy.level = settings.autonomy;

    // 2026-05-24 (v1.14.21) — query_expansion_enabled propagates from per-
    // user product_settings into the live memory retrieval pipeline. UI
    // labels this "Expand my queries with AI (costs more, improves recall
    // on short / vague questions)." Default false; user opts in.
    cfg.memory.retrieval_stages.query_expansion_enabled = settings.query_expansion_enabled;

    // Wish content can contain sensitive tenant context. Keep the runtime
    // egress gate false unless this tenant explicitly opted in through its
    // allowlisted product settings.
    cfg.agent.wish_matchmaking_enabled = settings.wish_matchmaking_enabled;

    // dream_enabled propagation: handled by the daemon wake-turn reconciler
    // reading `user_settings.dream_enabled` and matching against
    // AUTOMATIONS.json's dream_3am.enabled field — not a config flip here.
    // See AUTOMATIONS.json `_user_facing.user_toggle_setting` mapping
    // and src/daemon.zig wake-turn reconciliation.

    // v1.14.22 — per-user model selection. When the tenant has picked a
    // model in their settings, override the operator's default_model for
    // this turn. Allocation lifecycle: cfg.default_model is allocator-
    // owned, so free the previous value (if any) and dup the new one
    // into cfg.allocator. The selected_model value was already validated
    // against SELECTED_MODEL_ALLOWLIST at parse time — no need to
    // re-validate here.
    //
    // Failure mode: if dup OOMs we leave cfg.default_model untouched so
    // the operator default keeps working. applySettingsToConfig has a
    // void signature, so OOM is logged and the caller proceeds.
    if (settings.selectedModelSlice()) |sm| {
        if (cfg.allocator.dupe(u8, sm)) |duped| {
            if (cfg.default_model) |old| cfg.allocator.free(old);
            cfg.default_model = duped;
        } else |err| {
            std.log.warn("applySettingsToConfig: failed to dupe selected_model '{s}' ({s}); keeping operator default", .{ sm, @errorName(err) });
        }
    }

    cfg.syncFlatFields();
}

pub fn renderSettingsJson(allocator: std.mem.Allocator, settings: ProductSettings) ![]u8 {
    // v1.14.22 — selected_model is OMITTED when null so the on-disk shape
    // for tenants who haven't picked a model stays clean (and downstream
    // diff tools don't surface `"selected_model": null` as a meaningful
    // edit). When set, it serializes as a quoted string. The validator
    // already rejects invalid ids in parseProductSettings, so the value
    // here is known-safe at render time.
    const head = try std.fmt.allocPrint(
        allocator,
        "{{\"assistant_mode\":\"{s}\",\"group_activation\":\"{s}\",\"proactive_updates\":{s},\"voice_replies\":{s},\"session_timeout_minutes\":{d},\"autonomy\":\"{s}\",\"dream_enabled\":{s},\"query_expansion_enabled\":{s},\"wish_matchmaking_enabled\":{s}",
        .{
            settings.assistant_mode.toSlice(),
            settings.group_activation.toSlice(),
            if (settings.proactive_updates) "true" else "false",
            if (settings.voice_replies) "true" else "false",
            settings.session_timeout_minutes,
            settings.autonomy.toString(),
            if (settings.dream_enabled) "true" else "false",
            if (settings.query_expansion_enabled) "true" else "false",
            if (settings.wish_matchmaking_enabled) "true" else "false",
        },
    );
    defer allocator.free(head);
    if (settings.selectedModelSlice()) |sm| {
        return std.fmt.allocPrint(allocator, "{s},\"selected_model\":\"{s}\"}}", .{ head, sm });
    }
    return std.fmt.allocPrint(allocator, "{s}}}", .{head});
}

fn parseRootOrEmptyObject(allocator: std.mem.Allocator, json: []const u8) std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        return .{ .object = std.json.ObjectMap.init(allocator) };
    };
    if (parsed.value == .object) return parsed.value;
    return .{ .object = std.json.ObjectMap.init(allocator) };
}

fn parseProductSettings(value: std.json.Value) Error!ProductSettings {
    if (value != .object) return error.InvalidPayload;
    const obj = value.object;

    const assistant_mode_raw = obj.get("assistant_mode") orelse return error.InvalidAssistantMode;
    if (assistant_mode_raw != .string) return error.InvalidAssistantMode;
    const assistant_mode = AssistantMode.fromString(assistant_mode_raw.string) orelse return error.InvalidAssistantMode;

    const group_activation_raw = obj.get("group_activation") orelse return error.InvalidGroupActivation;
    if (group_activation_raw != .string) return error.InvalidGroupActivation;
    const group_activation = GroupActivation.fromString(group_activation_raw.string) orelse return error.InvalidGroupActivation;

    const proactive_raw = obj.get("proactive_updates") orelse return error.InvalidProactiveUpdates;
    if (proactive_raw != .bool) return error.InvalidProactiveUpdates;

    const voice_raw = obj.get("voice_replies") orelse return error.InvalidVoiceReplies;
    if (voice_raw != .bool) return error.InvalidVoiceReplies;

    const timeout_raw = obj.get("session_timeout_minutes") orelse return error.InvalidSessionTimeoutMinutes;
    if (timeout_raw != .integer or timeout_raw.integer < 0) return error.InvalidSessionTimeoutMinutes;

    // V1.14.4 — autonomy is OPTIONAL on read so that pre-V1.14.4 stored
    // configs (no `autonomy` key in product_settings) deserialize cleanly
    // to the default. New writes always include the key (mergeSettingsIntoConfigJson
    // + normalizeTenantConfigJson + renderSettingsJson all emit it).
    var legacy_full_autonomy_migrated = false;
    const autonomy_resolved: AutonomyLevel = blk: {
        const raw = obj.get("autonomy") orelse break :blk .supervised;
        if (raw != .string) return error.InvalidAutonomy;
        const parsed = AutonomyLevel.fromString(raw.string) orelse return error.InvalidAutonomy;
        if (parsed != .full) break :blk parsed;

        const acknowledged = obj.get(AUTONOMY_FULL_ACKNOWLEDGED_KEY) orelse {
            legacy_full_autonomy_migrated = true;
            break :blk .supervised;
        };
        if (acknowledged != .bool) return error.InvalidAutonomy;
        if (acknowledged.bool) break :blk .full;
        legacy_full_autonomy_migrated = true;
        break :blk .supervised;
    };

    // 2026-05-24 (v1.14.21) — dream_enabled + query_expansion_enabled are
    // OPTIONAL on read for the same reason as autonomy above: pre-v1.14.21
    // stored configs predate these keys; absent → struct default.
    const dream_enabled: bool = blk: {
        const raw = obj.get("dream_enabled") orelse break :blk true;
        if (raw != .bool) return error.InvalidPayload;
        break :blk raw.bool;
    };
    const query_expansion_enabled: bool = blk: {
        const raw = obj.get("query_expansion_enabled") orelse break :blk false;
        if (raw != .bool) return error.InvalidPayload;
        break :blk raw.bool;
    };
    const wish_matchmaking_enabled: bool = blk: {
        const raw = obj.get("wish_matchmaking_enabled") orelse break :blk false;
        if (raw != .bool) return error.InvalidPayload;
        break :blk raw.bool;
    };

    // v1.14.22 — selected_model is optional. Three valid shapes:
    //  1. key absent           → null (operator default wins)
    //  2. key present, JSON null → null
    //  3. key present, string  → must be on SELECTED_MODEL_ALLOWLIST
    // Any other shape is `InvalidSelectedModel`. Storage is inline
    // (SelectedModelBuf) so the value survives the JSON arena's deinit
    // — unlike the raw `.string` slice which aliases arena memory.
    var result = ProductSettings{
        .assistant_mode = assistant_mode,
        .group_activation = group_activation,
        .proactive_updates = proactive_raw.bool,
        .voice_replies = voice_raw.bool,
        .session_timeout_minutes = clampSessionTimeoutMinutesI64(timeout_raw.integer),
        .autonomy = autonomy_resolved,
        .legacy_full_autonomy_migrated = legacy_full_autonomy_migrated,
        .dream_enabled = dream_enabled,
        .query_expansion_enabled = query_expansion_enabled,
        .wish_matchmaking_enabled = wish_matchmaking_enabled,
    };

    if (obj.get("selected_model")) |raw| switch (raw) {
        .null => {}, // keep default (unset)
        .string => |s| {
            if (s.len > 0) {
                if (!isAllowedSelectedModel(s)) return error.InvalidSelectedModel;
                // Reject impossibly long ids — every allowlisted id is well
                // under SelectedModelBuf.bytes.len. SelectedModelTooLong
                // from setSelectedModel surfaces as InvalidSelectedModel.
                result.setSelectedModel(s) catch return error.InvalidSelectedModel;
            }
        },
        else => return error.InvalidSelectedModel,
    };

    return result;
}

fn deriveNearestFromAgentObject(agent: std.json.ObjectMap) ProductSettings {
    const mode_val = getObjectString(agent, "queue_mode");
    const cap_val = getObjectU32(agent, "queue_cap");
    const drop_val = getObjectString(agent, "queue_drop");
    const hist_val = getObjectU32(agent, "max_history_messages");

    const has_signal = mode_val != null or cap_val != null or drop_val != null or hist_val != null;
    if (!has_signal) return defaults();

    var best_mode: AssistantMode = .balanced;
    var best_score: u64 = std.math.maxInt(u64);
    for (mode_mappings) |entry| {
        var score: u64 = 0;
        if (mode_val) |v| {
            if (!std.ascii.eqlIgnoreCase(v, entry.queue_mode)) score += 100;
        }
        if (drop_val) |v| {
            if (!std.ascii.eqlIgnoreCase(v, entry.queue_drop)) score += 50;
        }
        if (cap_val) |v| {
            score += absDiffU32(v, entry.queue_cap);
        }
        if (hist_val) |v| {
            score += absDiffU32(v, entry.max_history_messages) / 2;
        }
        if (score < best_score) {
            best_score = score;
            best_mode = entry.mode;
        }
    }

    var result = defaults();
    result.assistant_mode = best_mode;
    if (getObjectString(agent, "activation_mode")) |raw| {
        result.group_activation = GroupActivation.fromString(raw) orelse .mention;
    }
    if (getObjectString(agent, "send_mode")) |raw| {
        result.proactive_updates = !std.ascii.eqlIgnoreCase(raw, "off");
    }
    if (getObjectBool(agent, "tts_audio")) |enabled| {
        result.voice_replies = enabled;
    } else if (getObjectString(agent, "tts_mode")) |raw| {
        result.voice_replies = !std.ascii.eqlIgnoreCase(raw, "off");
    }
    // V1.14.11 — read-back symmetric to applySettingsToConfig:
    // session_idle_timeout_secs is the operative field. Fall back to
    // legacy session_ttl_secs for configs written before the rewire
    // (preserves UI display continuity across upgrade).
    if (getObjectU32(agent, "session_idle_timeout_secs")) |secs| {
        result.session_timeout_minutes = clampSessionTimeoutMinutes(@max(1, secs / 60));
    } else if (getObjectU32(agent, "session_ttl_secs")) |secs| {
        result.session_timeout_minutes = clampSessionTimeoutMinutes(@max(1, secs / 60));
    }
    return result;
}

fn clampSessionTimeoutMinutes(minutes: u32) u32 {
    return std.math.clamp(minutes, 5, 180);
}

fn clampSessionTimeoutMinutesI64(minutes: i64) u32 {
    return @intCast(std.math.clamp(minutes, @as(i64, 5), @as(i64, 180)));
}

fn absDiffU32(a: u32, b: u32) u64 {
    return if (a >= b) @as(u64, a - b) else @as(u64, b - a);
}

fn ensureObject(value: *std.json.Value, allocator: std.mem.Allocator) *std.json.ObjectMap {
    switch (value.*) {
        .object => |*obj| return obj,
        else => {
            value.* = .{ .object = std.json.ObjectMap.init(allocator) };
            return &value.object;
        },
    }
}

fn ensureObjectKey(parent: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8) *std.json.ObjectMap {
    if (parent.getPtr(key)) |slot| {
        return ensureObject(slot, allocator);
    }
    const key_copy = allocator.dupe(u8, key) catch unreachable;
    parent.put(key_copy, .{ .object = std.json.ObjectMap.init(allocator) }) catch unreachable;
    return &parent.getPtr(key).?.object;
}

fn putString(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const str_copy = try allocator.dupe(u8, value);
    if (obj.getPtr(key)) |slot| {
        slot.* = .{ .string = str_copy };
        return;
    }
    const key_copy = try allocator.dupe(u8, key);
    try obj.put(key_copy, .{ .string = str_copy });
}

fn putBool(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: bool) !void {
    if (obj.getPtr(key)) |slot| {
        slot.* = .{ .bool = value };
        return;
    }
    const key_copy = try allocator.dupe(u8, key);
    try obj.put(key_copy, .{ .bool = value });
}

fn putInt(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: u32) !void {
    if (obj.getPtr(key)) |slot| {
        slot.* = .{ .integer = value };
        return;
    }
    const key_copy = try allocator.dupe(u8, key);
    try obj.put(key_copy, .{ .integer = value });
}

fn getObjectString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getObjectU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = obj.get(key) orelse return null;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return null;
    return @intCast(value.integer);
}

fn getObjectBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

test "defaults uses balanced profile" {
    const settings = defaults();
    try std.testing.expect(settings.assistant_mode == .balanced);
    try std.testing.expect(settings.group_activation == .mention);
    try std.testing.expect(!settings.proactive_updates);
    try std.testing.expect(!settings.voice_replies);
    try std.testing.expectEqual(@as(u32, 30), settings.session_timeout_minutes);
}

test "applyPatchToSettingsJson validates and clamps timeout" {
    const base = defaults();
    const updated = try applyPatchToSettingsJson(std.testing.allocator, base, "{\"assistant_mode\":\"deep\",\"session_timeout_minutes\":999}");
    try std.testing.expect(updated.assistant_mode == .deep);
    try std.testing.expectEqual(@as(u32, 180), updated.session_timeout_minutes);
}

test "applyPatchToSettingsJson rejects invalid assistant mode" {
    const base = defaults();
    try std.testing.expectError(
        error.InvalidAssistantMode,
        applyPatchToSettingsJson(std.testing.allocator, base, "{\"assistant_mode\":\"turbo\"}"),
    );
}

test "applyPatchToSettingsJson clamps huge timeout without overflow" {
    const base = defaults();
    const updated = try applyPatchToSettingsJson(std.testing.allocator, base, "{\"session_timeout_minutes\":9223372036854775807}");
    try std.testing.expectEqual(@as(u32, 180), updated.session_timeout_minutes);
}

test "resolveSettingsFromConfigJson prefers canonical product settings" {
    const cfg =
        \\{"product_settings":{"assistant_mode":"fast","group_activation":"always","proactive_updates":false,"voice_replies":true,"session_timeout_minutes":42}}
    ;
    const settings = try resolveSettingsFromConfigJson(std.testing.allocator, cfg);
    try std.testing.expect(settings.assistant_mode == .fast);
    try std.testing.expect(settings.group_activation == .always);
    try std.testing.expect(!settings.proactive_updates);
    try std.testing.expect(settings.voice_replies);
    try std.testing.expectEqual(@as(u32, 42), settings.session_timeout_minutes);
}

test "applySettingsToConfig fast input maps to low reasoning_effort" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "test/mock-model",
        .allocator = std.testing.allocator,
    };

    applySettingsToConfig(&cfg, .{
        .assistant_mode = .fast,
        .group_activation = .mention,
        .proactive_updates = true,
        .voice_replies = false,
        .session_timeout_minutes = 30,
    });

    // MODE-UNIFICATION: fast mode maps to low reasoning_effort
    try std.testing.expectEqualStrings("low", cfg.reasoning_effort.?);
    // Apply settings wires user preferences to config
    try std.testing.expectEqualStrings("mention", cfg.agent.activation_mode);
    try std.testing.expectEqualStrings("inherit", cfg.agent.send_mode);
    try std.testing.expectEqualStrings("off", cfg.agent.tts_mode);
    try std.testing.expectEqual(@as(u64, 1800), cfg.agent.session_idle_timeout_secs);
}

test "applySettingsToConfig deep input maps to high reasoning_effort" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "test/mock-model",
        .allocator = std.testing.allocator,
    };

    applySettingsToConfig(&cfg, .{
        .assistant_mode = .deep,
        .group_activation = .always,
        .proactive_updates = false,
        .voice_replies = true,
        .session_timeout_minutes = 60,
    });

    // MODE-UNIFICATION: deep mode maps to high reasoning_effort
    try std.testing.expectEqualStrings("high", cfg.reasoning_effort.?);
    // Apply settings wires user preferences to config
    try std.testing.expectEqualStrings("always", cfg.agent.activation_mode);
    try std.testing.expectEqualStrings("off", cfg.agent.send_mode);
    try std.testing.expectEqualStrings("inbound", cfg.agent.tts_mode);
    try std.testing.expectEqual(@as(u64, 3600), cfg.agent.session_idle_timeout_secs);
}

test "resolveSettingsFromConfigJson clamps huge canonical timeout" {
    const cfg =
        \\{"product_settings":{"assistant_mode":"balanced","group_activation":"mention","proactive_updates":true,"voice_replies":false,"session_timeout_minutes":9223372036854775807}}
    ;
    const settings = try resolveSettingsFromConfigJson(std.testing.allocator, cfg);
    try std.testing.expectEqual(@as(u32, 180), settings.session_timeout_minutes);
}

test "applySettingsToConfig wires session_timeout_minutes to session_idle_timeout_secs" {
    // V1.14.11 — confirms the UI slider drives the IDLE eviction
    // (Slack/Discord semantic) rather than the hard TTL kill. The
    // daemon's evictIdle loop (daemon.zig:2325) reads
    // session_idle_timeout_secs; the hard TTL stays operator-only.
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "test/mock-model",
        .allocator = std.testing.allocator,
    };

    applySettingsToConfig(&cfg, .{
        .assistant_mode = .balanced,
        .group_activation = .mention,
        .proactive_updates = true,
        .voice_replies = false,
        .session_timeout_minutes = 5,
    });

    try std.testing.expectEqual(@as(u64, 300), cfg.agent.session_idle_timeout_secs);
    // Hard TTL must NOT be touched by the UI slider (operator-only).
    try std.testing.expectEqual(@as(?u64, null), cfg.agent.session_ttl_secs);
}

test "wish matchmaking opt-in survives tenant normalization and reaches agent config" {
    const raw =
        \\{"product_settings":{"assistant_mode":"balanced","group_activation":"mention","proactive_updates":true,"voice_replies":false,"session_timeout_minutes":30,"wish_matchmaking_enabled":true}}
    ;
    const normalized = try normalizeTenantConfigJson(std.testing.allocator, raw);
    defer std.testing.allocator.free(normalized.json);
    try std.testing.expect(normalized.settings.wish_matchmaking_enabled);
    try std.testing.expect(std.mem.indexOf(u8, normalized.json, "\"wish_matchmaking_enabled\":true") != null);

    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "test/mock-model",
        .allocator = std.testing.allocator,
    };
    applySettingsToConfig(&cfg, normalized.settings);
    try std.testing.expect(cfg.agent.wish_matchmaking_enabled);
}

test "deriveNearestFromAgentObject reads session_idle_timeout_secs first, falls back to legacy session_ttl_secs" {
    // V1.14.11 — read-back must mirror write. Configs written post-
    // rewire surface session_idle_timeout_secs; configs from before
    // the rewire still have session_ttl_secs and must render in the
    // UI without a visual reset to default.
    const cfg_new =
        \\{"agent":{"queue_mode":"serial","queue_cap":8,"queue_drop":"summarize","max_history_messages":0,"session_idle_timeout_secs":420}}
    ;
    const new_settings = try resolveSettingsFromConfigJson(std.testing.allocator, cfg_new);
    try std.testing.expectEqual(@as(u32, 7), new_settings.session_timeout_minutes);

    const cfg_legacy =
        \\{"agent":{"queue_mode":"serial","queue_cap":8,"queue_drop":"summarize","max_history_messages":0,"session_ttl_secs":600}}
    ;
    const legacy_settings = try resolveSettingsFromConfigJson(std.testing.allocator, cfg_legacy);
    try std.testing.expectEqual(@as(u32, 10), legacy_settings.session_timeout_minutes);
}

test "resolveSettingsFromConfigJson keeps canonical profile when agent fields drift" {
    const cfg =
        \\{"product_settings":{"assistant_mode":"balanced","group_activation":"mention","proactive_updates":true,"voice_replies":false,"session_timeout_minutes":30},"agent":{"queue_mode":"latest","queue_cap":8,"queue_drop":"newest","max_history_messages":40}}
    ;
    const settings = try resolveSettingsFromConfigJson(std.testing.allocator, cfg);
    try std.testing.expect(settings.assistant_mode == .balanced);
}

test "deriveNearestFromConfigJson snaps from agent config" {
    const cfg =
        \\{"agent":{"queue_mode":"latest","queue_cap":9,"queue_drop":"newest","max_history_messages":39}}
    ;
    const settings = try deriveNearestFromConfigJson(std.testing.allocator, cfg);
    try std.testing.expect(settings.assistant_mode == .fast);
}

test "mergeSettingsIntoConfigJson preserves unknown keys and writes canonical product settings" {
    const existing =
        \\{"foo":"bar","agent":{"max_tool_iterations":9}}
    ;
    const merged = try mergeSettingsIntoConfigJson(std.testing.allocator, existing, .{
        .assistant_mode = .deep,
        .group_activation = .always,
        .proactive_updates = false,
        .voice_replies = true,
        .session_timeout_minutes = 45,
    });
    defer std.testing.allocator.free(merged);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, merged, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("bar", parsed.value.object.get("foo").?.string);
    const product = parsed.value.object.get("product_settings").?.object;
    try std.testing.expectEqualStrings("deep", product.get("assistant_mode").?.string);
    const agent = parsed.value.object.get("agent").?.object;
    try std.testing.expectEqual(@as(i64, 9), agent.get("max_tool_iterations").?.integer);
    try std.testing.expect(parsed.value.object.get("session") == null);
    try std.testing.expect(parsed.value.object.get("memory") == null);
}

test "normalizeTenantConfigJson strips every non-product_settings key (strict allowlist)" {
    // Enforcement test #3 (catches finding #3): under the strict tenant
    // allowlist, a tenant config keeps ONLY `product_settings`. Operator
    // blocks (agent/memory/default_provider/models/product_presets) AND
    // unknown/typo'd keys (`foo`) are all stripped — deny-by-default.
    const existing =
        \\{"foo":"bar","agent":{"queue_mode":"latest","queue_cap":8},"memory":{"summarizer":{"enabled":false}},"default_provider":"openai","models":{"providers":{"openai":{"api_key":"test-key"}}},"product_presets":{"fast":{"agent":{"queue_mode":"latest"}}}}
    ;
    const normalized = try normalizeTenantConfigJson(std.testing.allocator, existing);
    defer std.testing.allocator.free(normalized.json);

    // 6 non-allowlisted top-level keys stripped: foo, agent, memory,
    // default_provider, models, product_presets. Pre-inversion `foo`
    // leaked (count was 5) — that leak is exactly finding #3's class.
    try std.testing.expectEqual(@as(usize, 6), normalized.ignored_override_count);
    try std.testing.expect(normalized.settings.assistant_mode == .fast);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, normalized.json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("foo") == null);
    try std.testing.expect(parsed.value.object.get("agent") == null);
    try std.testing.expect(parsed.value.object.get("memory") == null);
    try std.testing.expect(parsed.value.object.get("default_provider") == null);
    try std.testing.expect(parsed.value.object.get("models") == null);
    try std.testing.expect(parsed.value.object.get("product_presets") == null);
    const product = parsed.value.object.get("product_settings").?.object;
    try std.testing.expectEqualStrings("fast", product.get("assistant_mode").?.string);
}

test "normalizeTenantConfigJson strips a tenant sidecar block (finding #3 regression guard)" {
    // A tenant sidecar block must never reach the runtime — it would
    // shadow the operator's extraction-model choice. Pre-inversion this
    // leaked because `sidecar` was absent from the operator deny-list.
    const existing =
        \\{"sidecar":{"provider":"groq","model":"llama-3.1-8b-instant"},"product_settings":{"assistant_mode":"balanced"}}
    ;
    const normalized = try normalizeTenantConfigJson(std.testing.allocator, existing);
    defer std.testing.allocator.free(normalized.json);
    try std.testing.expectEqual(@as(usize, 1), normalized.ignored_override_count);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, normalized.json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("sidecar") == null);
    try std.testing.expect(parsed.value.object.get("product_settings") != null);
}

test "ownership registry classifies operator and tenant preference keys" {
    try std.testing.expect(topLevelKeyOwnership("memory") == .operator);
    try std.testing.expect(topLevelKeyOwnership("models") == .operator);
    try std.testing.expect(topLevelKeyOwnership("sidecar") == .operator);
    try std.testing.expect(topLevelKeyOwnership("product_settings") == .tenant_preference);
    try std.testing.expect(topLevelKeyOwnership("foo") == .unknown);
    try std.testing.expect(productSettingsFieldOwnership("assistant_mode") == .tenant_preference);
    try std.testing.expect(productSettingsFieldOwnership("voice_replies") == .tenant_preference);
    try std.testing.expect(productSettingsFieldOwnership("autonomy") == .tenant_preference);
    try std.testing.expect(productSettingsFieldOwnership("queue_mode") == .unknown);
}

test "WP-SEC1: autonomy default is supervised and full remains an explicit choice" {
    const settings = defaults();
    try std.testing.expect(settings.autonomy == .supervised);

    const patched = try applyPatchToSettingsJson(std.testing.allocator, settings, "{\"autonomy\":\"full\"}");
    try std.testing.expect(patched.autonomy == .full);

    const patched2 = try applyPatchToSettingsJson(std.testing.allocator, patched, "{\"autonomy\":\"read_only\"}");
    try std.testing.expect(patched2.autonomy == .read_only);
}

test "V1.14.4: applyPatchToSettingsJson rejects invalid autonomy" {
    const base = defaults();
    try std.testing.expectError(
        error.InvalidAutonomy,
        applyPatchToSettingsJson(std.testing.allocator, base, "{\"autonomy\":\"yolo\"}"),
    );
    try std.testing.expectError(
        error.InvalidAutonomy,
        applyPatchToSettingsJson(std.testing.allocator, base, "{\"autonomy\":42}"),
    );
}

test "V1.14.4: applySettingsToConfig propagates autonomy into cfg.autonomy.level" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "test/mock-model",
        .allocator = std.testing.allocator,
    };

    applySettingsToConfig(&cfg, .{
        .assistant_mode = .balanced,
        .group_activation = .mention,
        .proactive_updates = true,
        .voice_replies = false,
        .session_timeout_minutes = 30,
        .autonomy = .supervised,
    });
    try std.testing.expect(cfg.autonomy.level == .supervised);

    applySettingsToConfig(&cfg, .{
        .assistant_mode = .balanced,
        .group_activation = .mention,
        .proactive_updates = true,
        .voice_replies = false,
        .session_timeout_minutes = 30,
        .autonomy = .read_only,
    });
    try std.testing.expect(cfg.autonomy.level == .read_only);

    applySettingsToConfig(&cfg, .{
        .assistant_mode = .balanced,
        .group_activation = .mention,
        .proactive_updates = true,
        .voice_replies = false,
        .session_timeout_minutes = 30,
        .autonomy = .full,
    });
    try std.testing.expect(cfg.autonomy.level == .full);
}

test "WP-SEC1: stored configs without autonomy key resolve to supervised" {
    // A tenant config saved before V1.14.4 has no explicit autonomy choice.
    // Resolve it to the safe default; an explicitly stored `full` remains full.
    const cfg =
        \\{"product_settings":{"assistant_mode":"balanced","group_activation":"mention","proactive_updates":true,"voice_replies":false,"session_timeout_minutes":30}}
    ;
    const settings = try resolveSettingsFromConfigJson(std.testing.allocator, cfg);
    try std.testing.expect(settings.autonomy == .supervised);
}

test "WP-SEC1: legacy stored full migrates to supervised until explicit re-opt-in" {
    const legacy =
        \\{"product_settings":{"assistant_mode":"balanced","group_activation":"mention","proactive_updates":false,"voice_replies":false,"session_timeout_minutes":30,"autonomy":"full"}}
    ;
    const normalized = try normalizeTenantConfigJson(std.testing.allocator, legacy);
    defer std.testing.allocator.free(normalized.json);
    try std.testing.expect(normalized.settings.autonomy == .supervised);
    try std.testing.expect(normalized.settings.legacy_full_autonomy_migrated);

    const reopted = try applyPatchToSettingsJson(std.testing.allocator, normalized.settings, "{\"autonomy\":\"full\"}");
    try std.testing.expect(!reopted.legacy_full_autonomy_migrated);
    const persisted = try mergeSettingsIntoConfigJson(std.testing.allocator, normalized.json, reopted);
    defer std.testing.allocator.free(persisted);
    const resolved = try resolveSettingsFromConfigJson(std.testing.allocator, persisted);
    try std.testing.expect(resolved.autonomy == .full);
}

test "V1.14.4 review MD-01: operator-set cfg.autonomy.level honored when product_settings absent" {
    // The legacy fallback path (deriveNearestFromAgentObject) MUST read
    // the operator's autonomy.level from cfg.autonomy.level when no
    // product_settings block exists. Pre-fix this returned .full
    // unconditionally, silently elevating autonomy beyond what the
    // operator configured.
    const cfg_supervised =
        \\{"agent":{"queue_mode":"serial","queue_cap":12},"autonomy":{"level":"supervised"}}
    ;
    const settings_s = try resolveSettingsFromConfigJson(std.testing.allocator, cfg_supervised);
    try std.testing.expect(settings_s.autonomy == .supervised);

    const cfg_readonly =
        \\{"agent":{"queue_mode":"serial","queue_cap":12},"autonomy":{"level":"read_only"}}
    ;
    const settings_r = try resolveSettingsFromConfigJson(std.testing.allocator, cfg_readonly);
    try std.testing.expect(settings_r.autonomy == .read_only);

    // Legacy underscoreless form should still resolve via fromString
    // (defense-in-depth — older configs may have used the old toString
    // output before V1.14.4 review CR-01).
    const cfg_legacy =
        \\{"agent":{"queue_mode":"serial","queue_cap":12},"autonomy":{"level":"readonly"}}
    ;
    const settings_l = try resolveSettingsFromConfigJson(std.testing.allocator, cfg_legacy);
    try std.testing.expect(settings_l.autonomy == .read_only);

    // No agent block at all: still extract autonomy from top-level.
    const cfg_no_agent =
        \\{"autonomy":{"level":"supervised"}}
    ;
    const settings_na = try resolveSettingsFromConfigJson(std.testing.allocator, cfg_no_agent);
    try std.testing.expect(settings_na.autonomy == .supervised);
}

test "V1.14.4: renderSettingsJson includes autonomy" {
    const out = try renderSettingsJson(std.testing.allocator, .{
        .assistant_mode = .deep,
        .group_activation = .always,
        .proactive_updates = false,
        .voice_replies = true,
        .session_timeout_minutes = 45,
        .autonomy = .supervised,
    });
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"autonomy\":\"supervised\"") != null);
}

test "V1.14.4: mergeSettingsIntoConfigJson writes canonical autonomy" {
    const merged = try mergeSettingsIntoConfigJson(std.testing.allocator, "{}", .{
        .assistant_mode = .balanced,
        .group_activation = .mention,
        .proactive_updates = true,
        .voice_replies = false,
        .session_timeout_minutes = 30,
        .autonomy = .read_only,
    });
    defer std.testing.allocator.free(merged);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, merged, .{});
    defer parsed.deinit();
    const product = parsed.value.object.get("product_settings").?.object;
    // V1.14.4 review CR-01 fix — toString emits "read_only" (underscore
    // form) to match the FE TypeScript contract.
    try std.testing.expectEqualStrings("read_only", product.get("autonomy").?.string);
}

// ── v1.14.22: per-user model selection tests ────────────────────────────────

test "v1.14.22: selected_model defaults to null" {
    // Pre-v1.14.22 stored configs do not have the selected_model key.
    // They must deserialize cleanly with selectedModelSlice() == null so
    // the operator's default_model wins (the backward-compat contract
    // every ProductSettings field on this struct honors).
    const cfg =
        \\{"product_settings":{"assistant_mode":"balanced","group_activation":"mention","proactive_updates":true,"voice_replies":false,"session_timeout_minutes":30}}
    ;
    const settings = try resolveSettingsFromConfigJson(std.testing.allocator, cfg);
    try std.testing.expect(settings.selectedModelSlice() == null);

    // Fresh defaults() also yields null.
    try std.testing.expect(defaults().selectedModelSlice() == null);
}

test "v1.14.22: selected_model accepts allowlisted ids (case-insensitive)" {
    // Round-trip through parseProductSettings via resolveSettingsFromConfigJson.
    const cases = [_][]const u8{
        "kimi-k2.6",
        "claude-opus-4.7",
        "claude-opus-4-7",
        "claude-sonnet-4.6",
        "gemini-2.5-pro",
        // Case-insensitive — FE may upper-case to be safe.
        "Claude-Opus-4.7",
        "KIMI-K2.6",
    };
    inline for (cases) |id| {
        const cfg_json = "{\"product_settings\":{\"assistant_mode\":\"balanced\",\"group_activation\":\"mention\",\"proactive_updates\":true,\"voice_replies\":false,\"session_timeout_minutes\":30,\"selected_model\":\"" ++ id ++ "\"}}";
        const settings = try resolveSettingsFromConfigJson(std.testing.allocator, cfg_json);
        try std.testing.expect(settings.selectedModelSlice() != null);
        try std.testing.expectEqualStrings(id, settings.selectedModelSlice().?);
    }
}

test "v1.14.22: selected_model rejects ids not on the allowlist" {
    // Unknown model id — should fail parse with InvalidSelectedModel via
    // the FE patch path (applyPatchToSettingsJson). The on-disk-config
    // load path (extractFromConfigJson) intentionally swallows parse
    // errors to keep startup robust, so the patch path is the gate
    // that surfaces validation to the user.
    const bad_id_cases = [_][]const u8{
        "not-a-real-model",
        "gpt-3.5-turbo", // not on our allowlist
        "claude-opus-3", // older Claude not on list
        "openai/gpt-4.1", // provider-prefixed forms must be rejected — the
        // tenant can't smuggle in routing through this field
        "kimi-k2.6-1m", // synthetic suffix not on list
    };
    inline for (bad_id_cases) |id| {
        const patch = "{\"selected_model\":\"" ++ id ++ "\"}";
        const result = applyPatchToSettingsJson(std.testing.allocator, defaults(), patch);
        try std.testing.expectError(error.InvalidSelectedModel, result);
    }

    // Non-string shape is also rejected.
    const bad_shape = "{\"selected_model\":42}";
    try std.testing.expectError(error.InvalidSelectedModel, applyPatchToSettingsJson(std.testing.allocator, defaults(), bad_shape));

    // And via the full-parse path too — parseProductSettings rejects.
    // (We can't observe this through resolveSettingsFromConfigJson because
    // extractFromConfigJson swallows; assert against parseProductSettings
    // directly via a JSON arena.)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const obj_json = "{\"assistant_mode\":\"balanced\",\"group_activation\":\"mention\",\"proactive_updates\":true,\"voice_replies\":false,\"session_timeout_minutes\":30,\"selected_model\":\"not-real\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), obj_json, .{});
    try std.testing.expectError(error.InvalidSelectedModel, parseProductSettings(parsed.value));
}

test "v1.14.22: selected_model overrides cfg.default_model in applySettingsToConfig" {
    // The whole point of the feature: when the tenant picks a model in
    // the FE, the agent's outbound routing must reflect that choice.
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = try std.testing.allocator.dupe(u8, "operator-default-model"),
        .allocator = std.testing.allocator,
    };
    defer if (cfg.default_model) |m| std.testing.allocator.free(m);

    // Apply with selected_model set — cfg.default_model is rewritten.
    var s1 = ProductSettings{
        .assistant_mode = .balanced,
        .group_activation = .mention,
        .proactive_updates = true,
        .voice_replies = false,
        .session_timeout_minutes = 30,
        .autonomy = .full,
    };
    try s1.setSelectedModel("claude-opus-4.7");
    applySettingsToConfig(&cfg, s1);
    try std.testing.expect(cfg.default_model != null);
    try std.testing.expectEqualStrings("claude-opus-4.7", cfg.default_model.?);

    // Apply with selected_model = null — cfg.default_model stays as-is
    // (this preserves the operator's choice for tenants who haven't
    // explicitly picked).
    applySettingsToConfig(&cfg, .{
        .assistant_mode = .balanced,
        .group_activation = .mention,
        .proactive_updates = true,
        .voice_replies = false,
        .session_timeout_minutes = 30,
        .autonomy = .full,
    });
    try std.testing.expectEqualStrings("claude-opus-4.7", cfg.default_model.?);
}

test "v1.14.22: selected_model round-trips through render + parse" {
    // renderSettingsJson → mergeSettingsIntoConfigJson → resolveSettingsFromConfigJson
    // must preserve the picked model. Null round-trips to absent key.
    var original = ProductSettings{
        .assistant_mode = .balanced,
        .group_activation = .mention,
        .proactive_updates = true,
        .voice_replies = false,
        .session_timeout_minutes = 30,
        .autonomy = .full,
    };
    try original.setSelectedModel("kimi-k2.6");

    const merged = try mergeSettingsIntoConfigJson(std.testing.allocator, "{}", original);
    defer std.testing.allocator.free(merged);

    const read_back = try resolveSettingsFromConfigJson(std.testing.allocator, merged);
    try std.testing.expect(read_back.selectedModelSlice() != null);
    try std.testing.expectEqualStrings("kimi-k2.6", read_back.selectedModelSlice().?);

    // Null round-trip: render with null → JSON has no selected_model key →
    // parse → null again.
    const null_original = ProductSettings{};
    const null_merged = try mergeSettingsIntoConfigJson(std.testing.allocator, "{}", null_original);
    defer std.testing.allocator.free(null_merged);
    try std.testing.expect(std.mem.indexOf(u8, null_merged, "selected_model") == null);

    const null_read = try resolveSettingsFromConfigJson(std.testing.allocator, null_merged);
    try std.testing.expect(null_read.selectedModelSlice() == null);
}
