const std = @import("std");
const config_types = @import("config_types.zig");
const Config = @import("config.zig").Config;

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
    proactive_updates: bool = true,
    voice_replies: bool = false,
    session_timeout_minutes: u32 = 30,
};

pub const Error = error{
    InvalidPayload,
    InvalidAssistantMode,
    InvalidGroupActivation,
    InvalidProactiveUpdates,
    InvalidVoiceReplies,
    InvalidSessionTimeoutMinutes,
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
// Runtime behavior for each mode is driven by product_presets in
// config_types.zig, NOT this table.
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
    "diagnostics",
    "autonomy",
    "runtime",
    "network",
    "reliability",
    "scheduler",
    "agent",
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
    "product_presets",
};

const tenant_preference_product_settings_keys = [_][]const u8{
    "assistant_mode",
    "group_activation",
    "proactive_updates",
    "voice_replies",
    "session_timeout_minutes",
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
    const agent_val = parsed.value.object.get("agent") orelse return defaults();
    if (agent_val != .object) return defaults();
    return deriveNearestFromAgentObject(agent_val.object);
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

    var ignored_override_count: usize = 0;
    inline for (operator_owned_top_level_config_keys) |key| {
        if (topLevelKeyOwnership(key) == .operator) {
            if (root_obj.swapRemove(key)) ignored_override_count += 1;
        }
    }

    const product_obj = ensureObjectKey(root_obj, a, "product_settings");
    try putString(product_obj, a, "assistant_mode", settings.assistant_mode.toSlice());
    try putString(product_obj, a, "group_activation", settings.group_activation.toSlice());
    try putBool(product_obj, a, "proactive_updates", settings.proactive_updates);
    try putBool(product_obj, a, "voice_replies", settings.voice_replies);
    try putInt(product_obj, a, "session_timeout_minutes", settings.session_timeout_minutes);

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
    const preset = presetForMode(settings.assistant_mode, cfg.product_presets);

    cfg.agent.compact_context = preset.agent.compact_context;
    cfg.agent.max_history_messages = preset.agent.max_history_messages;
    cfg.agent.queue_mode = preset.agent.queue_mode;
    cfg.agent.queue_cap = preset.agent.queue_cap;
    cfg.agent.queue_drop = preset.agent.queue_drop;
    cfg.agent.queue_debounce_ms = preset.agent.queue_debounce_ms;

    // Mode-specific quality/cost differentiation
    if (preset.agent.temperature) |temp| {
        cfg.default_temperature = temp;
    }
    if (preset.agent.max_tool_iterations > 0) {
        cfg.agent.max_tool_iterations = preset.agent.max_tool_iterations;
    }
    // Per-mode model/provider selection — the core of mode differentiation.
    // Fast=Gemma/Together, Balanced=K2.5/Together, Deep=GLM/OpenRouter.
    // Empty string = keep the current config default (operator override).
    //
    // IMPORTANT: When the provider changes, the RuntimeProviderBundle MUST be
    // rebuilt. The provider bundle is an HTTP client pointed at a specific API
    // endpoint — changing cfg.default_provider without rebuilding the bundle
    // sends the wrong model to the wrong provider (silent failure).
    // Currently safe: applySettingsToConfig runs before bundle init at boot.
    // If hot-reload is added later, bundle rebuild must follow config update.
    if (preset.agent.model.len > 0) {
        cfg.default_model = preset.agent.model;
    }
    if (preset.agent.provider.len > 0) {
        cfg.default_provider = preset.agent.provider;
    }
    // Note: max_response_tokens intentionally NOT applied from presets.
    // Hard API caps truncate mid-response during agentic tasks (file writes, code gen).
    // References (Claude Code, Cursor, Devin) use no per-mode response caps.
    // Verbosity is controlled via persona voice_style (concise/verbose) instead.

    cfg.memory.summarizer.enabled = preset.summarizer.enabled;
    cfg.memory.summarizer.window_size_tokens = preset.summarizer.window_size_tokens;
    cfg.memory.summarizer.summary_max_tokens = preset.summarizer.summary_max_tokens;
    cfg.memory.summarizer.auto_extract_semantic = preset.summarizer.auto_extract_semantic;

    cfg.agent.activation_mode = settings.group_activation.toSlice();
    cfg.agent.send_mode = if (settings.proactive_updates) "inherit" else "off";
    cfg.agent.tts_mode = if (settings.voice_replies) "inbound" else "off";
    cfg.agent.tts_audio = settings.voice_replies;
    cfg.agent.session_ttl_secs = settings.session_timeout_minutes * 60;
    cfg.session.cross_channel_shared_main = false;
    cfg.syncFlatFields();
}

pub fn renderSettingsJson(allocator: std.mem.Allocator, settings: ProductSettings) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"assistant_mode\":\"{s}\",\"group_activation\":\"{s}\",\"proactive_updates\":{s},\"voice_replies\":{s},\"session_timeout_minutes\":{d}}}",
        .{
            settings.assistant_mode.toSlice(),
            settings.group_activation.toSlice(),
            if (settings.proactive_updates) "true" else "false",
            if (settings.voice_replies) "true" else "false",
            settings.session_timeout_minutes,
        },
    );
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

    return .{
        .assistant_mode = assistant_mode,
        .group_activation = group_activation,
        .proactive_updates = proactive_raw.bool,
        .voice_replies = voice_raw.bool,
        .session_timeout_minutes = clampSessionTimeoutMinutesI64(timeout_raw.integer),
    };
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
    if (getObjectU32(agent, "session_ttl_secs")) |secs| {
        result.session_timeout_minutes = clampSessionTimeoutMinutes(@max(1, secs / 60));
    }
    return result;
}

fn presetForMode(
    mode: AssistantMode,
    presets: config_types.ProductPresetsConfig,
) config_types.AssistantModePresetConfig {
    return switch (mode) {
        .fast => presets.fast,
        .balanced => presets.balanced,
        .deep => presets.deep,
    };
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
    try std.testing.expect(settings.proactive_updates);
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

test "applySettingsToConfig enables fast summarizer without changing fast preset sizing" {
    var cfg = Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .default_model = "test/mock-model",
        .allocator = std.testing.allocator,
    };

    try std.testing.expect(cfg.product_presets.fast.summarizer.enabled);

    applySettingsToConfig(&cfg, .{
        .assistant_mode = .fast,
        .group_activation = .mention,
        .proactive_updates = true,
        .voice_replies = false,
        .session_timeout_minutes = 30,
    });

    try std.testing.expectEqualStrings("serial", cfg.agent.queue_mode);
    try std.testing.expectEqual(@as(u32, 8), cfg.agent.queue_cap);
    try std.testing.expectEqualStrings("summarize", cfg.agent.queue_drop);
    try std.testing.expectEqual(@as(u32, 0), cfg.agent.max_history_messages);
    try std.testing.expect(cfg.memory.summarizer.enabled);
    try std.testing.expectEqual(@as(u32, 3000), cfg.memory.summarizer.window_size_tokens);
    try std.testing.expectEqual(@as(u32, 300), cfg.memory.summarizer.summary_max_tokens);

    // Mode-specific quality fields
    try std.testing.expectEqual(@as(f64, 0.5), cfg.default_temperature);
    // Fast mode cap: 20 (raised from 8 after field testing — 8 truncated
    // real multi-step tasks; adaptive loop detector keeps runaways bounded).
    try std.testing.expectEqual(@as(u32, 20), cfg.agent.max_tool_iterations);
    // max_response_tokens not applied — no hard cap on response length
    try std.testing.expectEqual(@as(?u32, null), cfg.max_tokens);
    // Per-mode model/provider selection
    try std.testing.expectEqualStrings("moonshotai/Kimi-K2.5", cfg.default_model.?);
    try std.testing.expectEqualStrings("together", cfg.default_provider);
}

test "applySettingsToConfig deep mode applies high-quality settings" {
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

    try std.testing.expectEqual(@as(f64, 0.8), cfg.default_temperature);
    // Deep mode cap: 100 (lowered from 500). 500 was effectively unbounded;
    // 100 is a real safety valve with adaptive exits handling stuck loops.
    try std.testing.expectEqual(@as(u32, 100), cfg.agent.max_tool_iterations);
    // max_response_tokens not applied — no hard cap
    try std.testing.expectEqual(@as(?u32, null), cfg.max_tokens);
    try std.testing.expectEqual(@as(u32, 0), cfg.agent.max_history_messages);
    try std.testing.expectEqualStrings("serial", cfg.agent.queue_mode);
    try std.testing.expectEqual(@as(u32, 8000), cfg.memory.summarizer.window_size_tokens);
    // Per-mode model/provider selection
    try std.testing.expectEqualStrings("zai-org/GLM-5.1", cfg.default_model.?);
    try std.testing.expectEqualStrings("together", cfg.default_provider);
}

test "resolveSettingsFromConfigJson clamps huge canonical timeout" {
    const cfg =
        \\{"product_settings":{"assistant_mode":"balanced","group_activation":"mention","proactive_updates":true,"voice_replies":false,"session_timeout_minutes":9223372036854775807}}
    ;
    const settings = try resolveSettingsFromConfigJson(std.testing.allocator, cfg);
    try std.testing.expectEqual(@as(u32, 180), settings.session_timeout_minutes);
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

test "normalizeTenantConfigJson strips operator-owned overrides and preserves tenant metadata" {
    const existing =
        \\{"foo":"bar","agent":{"queue_mode":"latest","queue_cap":8},"memory":{"summarizer":{"enabled":false}},"default_provider":"openai","models":{"providers":{"openai":{"api_key":"test-key"}}},"product_presets":{"fast":{"agent":{"queue_mode":"latest"}}}}
    ;
    const normalized = try normalizeTenantConfigJson(std.testing.allocator, existing);
    defer std.testing.allocator.free(normalized.json);

    try std.testing.expectEqual(@as(usize, 5), normalized.ignored_override_count);
    try std.testing.expect(normalized.settings.assistant_mode == .fast);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, normalized.json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("bar", parsed.value.object.get("foo").?.string);
    try std.testing.expect(parsed.value.object.get("agent") == null);
    try std.testing.expect(parsed.value.object.get("memory") == null);
    try std.testing.expect(parsed.value.object.get("default_provider") == null);
    try std.testing.expect(parsed.value.object.get("models") == null);
    try std.testing.expect(parsed.value.object.get("product_presets") == null);
    const product = parsed.value.object.get("product_settings").?.object;
    try std.testing.expectEqualStrings("fast", product.get("assistant_mode").?.string);
}

test "ownership registry classifies operator and tenant preference keys" {
    try std.testing.expect(topLevelKeyOwnership("memory") == .operator);
    try std.testing.expect(topLevelKeyOwnership("models") == .operator);
    try std.testing.expect(topLevelKeyOwnership("product_presets") == .operator);
    try std.testing.expect(topLevelKeyOwnership("product_settings") == .tenant_preference);
    try std.testing.expect(topLevelKeyOwnership("foo") == .unknown);
    try std.testing.expect(productSettingsFieldOwnership("assistant_mode") == .tenant_preference);
    try std.testing.expect(productSettingsFieldOwnership("voice_replies") == .tenant_preference);
    try std.testing.expect(productSettingsFieldOwnership("queue_mode") == .unknown);
}
