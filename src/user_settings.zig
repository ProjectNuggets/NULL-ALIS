const std = @import("std");

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

    fn toSlice(self: AssistantMode) []const u8 {
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

    fn toSlice(self: GroupActivation) []const u8 {
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

const ModeMapping = struct {
    mode: AssistantMode,
    queue_mode: []const u8,
    queue_cap: u32,
    queue_drop: []const u8,
    max_history_messages: u32,
};

const mode_mappings = [_]ModeMapping{
    .{
        .mode = .fast,
        .queue_mode = "latest",
        .queue_cap = 8,
        .queue_drop = "newest",
        .max_history_messages = 40,
    },
    .{
        .mode = .balanced,
        .queue_mode = "serial",
        .queue_cap = 12,
        .queue_drop = "summarize",
        .max_history_messages = 50,
    },
    .{
        .mode = .deep,
        .queue_mode = "serial",
        .queue_cap = 20,
        .queue_drop = "summarize",
        .max_history_messages = 80,
    },
};

pub fn defaults() ProductSettings {
    return .{};
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
    putString(product_obj, a, "assistant_mode", settings.assistant_mode.toSlice()) catch {};
    putString(product_obj, a, "group_activation", settings.group_activation.toSlice()) catch {};
    putBool(product_obj, a, "proactive_updates", settings.proactive_updates) catch {};
    putBool(product_obj, a, "voice_replies", settings.voice_replies) catch {};
    putInt(product_obj, a, "session_timeout_minutes", settings.session_timeout_minutes) catch {};

    const agent_obj = ensureObjectKey(root_obj, a, "agent");
    const mapping = mappingFor(settings.assistant_mode);
    putString(agent_obj, a, "queue_mode", mapping.queue_mode) catch {};
    putInt(agent_obj, a, "queue_cap", mapping.queue_cap) catch {};
    putString(agent_obj, a, "queue_drop", mapping.queue_drop) catch {};
    putInt(agent_obj, a, "queue_debounce_ms", 0) catch {};
    putBool(agent_obj, a, "compact_context", true) catch {};
    putInt(agent_obj, a, "max_history_messages", mapping.max_history_messages) catch {};
    putString(agent_obj, a, "activation_mode", settings.group_activation.toSlice()) catch {};
    putString(agent_obj, a, "send_mode", if (settings.proactive_updates) "inherit" else "off") catch {};
    putString(agent_obj, a, "tts_mode", if (settings.voice_replies) "inbound" else "off") catch {};
    putBool(agent_obj, a, "tts_audio", settings.voice_replies) catch {};
    putInt(agent_obj, a, "session_ttl_secs", settings.session_timeout_minutes * 60) catch {};

    var rendered = try std.json.Stringify.valueAlloc(allocator, root, .{});
    if (rendered.len == 0 or rendered[rendered.len - 1] != '\n') {
        const with_nl = try std.fmt.allocPrint(allocator, "{s}\n", .{rendered});
        allocator.free(rendered);
        rendered = with_nl;
    }
    return rendered;
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

fn mappingFor(mode: AssistantMode) ModeMapping {
    return switch (mode) {
        .fast => mode_mappings[0],
        .balanced => mode_mappings[1],
        .deep => mode_mappings[2],
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

test "mergeSettingsIntoConfigJson preserves unknown keys and writes mapped agent knobs" {
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
    try std.testing.expectEqualStrings("serial", agent.get("queue_mode").?.string);
    try std.testing.expectEqual(@as(i64, 20), agent.get("queue_cap").?.integer);
    try std.testing.expectEqualStrings("summarize", agent.get("queue_drop").?.string);
    try std.testing.expectEqual(@as(i64, 80), agent.get("max_history_messages").?.integer);
    try std.testing.expectEqualStrings("always", agent.get("activation_mode").?.string);
    try std.testing.expectEqualStrings("off", agent.get("send_mode").?.string);
    try std.testing.expectEqualStrings("inbound", agent.get("tts_mode").?.string);
    try std.testing.expectEqual(true, agent.get("tts_audio").?.bool);
    try std.testing.expectEqual(@as(i64, 2700), agent.get("session_ttl_secs").?.integer);
    try std.testing.expectEqual(@as(i64, 9), agent.get("max_tool_iterations").?.integer);
}
