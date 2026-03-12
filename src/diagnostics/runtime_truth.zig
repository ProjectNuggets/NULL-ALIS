const std = @import("std");
const build_options = @import("build_options");
const channel_catalog = @import("../channel_catalog.zig");
const config_mod = @import("../config.zig");
const http_util = @import("../http_util.zig");

pub const Source = enum {
    gateway_internal,
    local_fallback,

    pub fn toSlice(self: Source) []const u8 {
        return switch (self) {
            .gateway_internal => "gateway_internal",
            .local_fallback => "local_fallback",
        };
    }
};

pub const RuntimeSnapshot = struct {
    source: Source,
    state_backend_configured: []u8,
    state_backend_effective: []u8,
    scheduler_backend: []u8,
    degraded: bool,
    degraded_reason: []u8,
    heartbeat_enabled: bool,
    heartbeat_interval_minutes: u32,
    tenant_enabled: bool,
    scheduler_max_tasks_configured: u32,
    scheduler_max_concurrent_configured: u32,
    scheduler_max_tasks_effective: ?u32 = null,
    chat_provider_effective: []u8,
    chat_fallback_chain: []u8,
    embedding_provider_effective: []u8,
    provider_data_source: []u8,
    telegram_configured: ?bool = null,
    telegram_connected: ?bool = null,
    telegram_account_id: ?[]u8 = null,
    telegram_chat_id: ?i64 = null,
    telegram_data_source: ?[]u8 = null,
    context_incomplete: bool = false,
    identity_mapped: ?u64 = null,
    identity_unmapped: ?u64 = null,
    identity_strict_rejected: ?u64 = null,
    identity_degraded_compat: ?u64 = null,
    identity_cache_hit: ?u64 = null,
    identity_cache_miss: ?u64 = null,
    identity_cache_stale: ?u64 = null,
    identity_db_lookup_count: ?u64 = null,
    identity_db_lookup_ms_total: ?u64 = null,

    pub fn deinit(self: *RuntimeSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.state_backend_configured);
        allocator.free(self.state_backend_effective);
        allocator.free(self.scheduler_backend);
        allocator.free(self.degraded_reason);
        allocator.free(self.chat_provider_effective);
        allocator.free(self.chat_fallback_chain);
        allocator.free(self.embedding_provider_effective);
        allocator.free(self.provider_data_source);
        if (self.telegram_account_id) |value| allocator.free(value);
        if (self.telegram_data_source) |value| allocator.free(value);
    }
};

pub fn collectRuntimeSnapshot(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    user_id: ?[]const u8,
) !RuntimeSnapshot {
    return collectGatewayInternalSnapshot(allocator, cfg, user_id) catch
        collectLocalFallbackSnapshot(allocator, cfg);
}

fn collectGatewayInternalSnapshot(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    user_id: ?[]const u8,
) !RuntimeSnapshot {
    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/internal/diagnostics", .{
        cfg.gateway.host,
        cfg.gateway.port,
    });
    defer allocator.free(url);

    var headers: [2][]const u8 = undefined;
    var header_count: usize = 0;
    var token_header_alloc: ?[]u8 = null;
    defer if (token_header_alloc) |h| allocator.free(h);
    var user_header_alloc: ?[]u8 = null;
    defer if (user_header_alloc) |h| allocator.free(h);

    if (cfg.gateway.internal_service_tokens.len > 0) {
        token_header_alloc = try std.fmt.allocPrint(allocator, "X-Internal-Token: {s}", .{
            cfg.gateway.internal_service_tokens[0],
        });
        headers[header_count] = token_header_alloc.?;
        header_count += 1;
    }
    if (user_id) |uid| {
        user_header_alloc = try std.fmt.allocPrint(allocator, "X-Zaki-User-Id: {s}", .{uid});
        headers[header_count] = user_header_alloc.?;
        header_count += 1;
    }

    const response = try http_util.request_with_mode(allocator, .{}, .{
        .subsystem = .system,
        .method = "GET",
        .url = url,
        .headers = headers[0..header_count],
        .timeout_ms = 2_000,
        .max_response_bytes = 512 * 1024,
    });
    defer allocator.free(response.body);
    if (response.status_code != 200) return error.DiagnosticsUnavailable;

    var snapshot = try parseGatewayDiagnosticsPayload(allocator, response.body);
    errdefer snapshot.deinit(allocator);
    var provider_from_config = false;
    snapshot.scheduler_max_tasks_configured = cfg.scheduler.max_tasks;
    snapshot.scheduler_max_concurrent_configured = cfg.scheduler.max_concurrent;
    snapshot.scheduler_max_tasks_effective = cfg.scheduler.max_tasks;
    if (std.mem.eql(u8, snapshot.chat_provider_effective, "unknown")) {
        allocator.free(snapshot.chat_provider_effective);
        snapshot.chat_provider_effective = try allocator.dupe(u8, normalizeProviderAlias(cfg.default_provider));
        provider_from_config = true;
    }
    if (std.mem.eql(u8, snapshot.chat_fallback_chain, "none") and cfg.reliability.fallback_providers.len > 0) {
        allocator.free(snapshot.chat_fallback_chain);
        snapshot.chat_fallback_chain = try allocNormalizedFallbackChain(allocator, cfg.reliability.fallback_providers);
        provider_from_config = true;
    }
    if (std.mem.eql(u8, snapshot.embedding_provider_effective, "none") and cfg.memory.search.provider.len > 0) {
        allocator.free(snapshot.embedding_provider_effective);
        snapshot.embedding_provider_effective = try allocator.dupe(u8, normalizeProviderAlias(cfg.memory.search.provider));
        provider_from_config = true;
    }
    if (provider_from_config) {
        allocator.free(snapshot.provider_data_source);
        snapshot.provider_data_source = try allocator.dupe(u8, "config");
    }
    if (snapshot.telegram_configured == null and snapshot.telegram_data_source == null) {
        snapshot.telegram_configured = channel_catalog.configuredCount(cfg, .telegram) > 0;
    }
    return snapshot;
}

fn parseGatewayDiagnosticsPayload(allocator: std.mem.Allocator, body: []const u8) !RuntimeSnapshot {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDiagnosticsPayload;
    const startup_value = parsed.value.object.get("startup_self_check") orelse return error.InvalidDiagnosticsPayload;
    if (startup_value != .object) return error.InvalidDiagnosticsPayload;
    const startup = startup_value.object;

    const configured = readObjectString(startup, "state_backend_configured") orelse "unknown";
    const effective = readObjectString(startup, "state_backend_effective") orelse "unknown";
    const scheduler_backend = readObjectString(startup, "scheduler_backend") orelse "unknown";
    const degraded = readObjectBool(startup, "degraded") orelse false;
    const degraded_reason = readObjectString(startup, "degraded_reason") orelse "";
    const heartbeat_enabled = readObjectBool(startup, "heartbeat_enabled") orelse false;
    const heartbeat_interval_minutes = readObjectU32(startup, "heartbeat_interval_minutes") orelse 0;
    const tenant_enabled = readObjectBool(startup, "tenant_enabled") orelse false;
    const chat_provider_effective = normalizeProviderAlias(readObjectString(startup, "chat_provider_effective") orelse "unknown");
    const chat_fallback_chain = normalizeFallbackChain(readObjectString(startup, "chat_fallback_chain") orelse "none");
    const embedding_provider_effective = normalizeProviderAlias(readObjectString(startup, "embedding_provider_effective") orelse "none");
    const provider_data_source = readObjectString(startup, "provider_data_source") orelse "gateway_internal";

    var telegram_configured: ?bool = null;
    var telegram_connected: ?bool = null;
    var telegram_account_id: ?[]u8 = null;
    errdefer if (telegram_account_id) |value| allocator.free(value);
    var telegram_chat_id: ?i64 = null;
    var telegram_data_source: ?[]u8 = null;
    errdefer if (telegram_data_source) |value| allocator.free(value);
    var identity_mapped: ?u64 = null;
    var identity_unmapped: ?u64 = null;
    var identity_strict_rejected: ?u64 = null;
    var identity_degraded_compat: ?u64 = null;
    var identity_cache_hit: ?u64 = null;
    var identity_cache_miss: ?u64 = null;
    var identity_cache_stale: ?u64 = null;
    var identity_db_lookup_count: ?u64 = null;
    var identity_db_lookup_ms_total: ?u64 = null;

    if (parsed.value.object.get("integrations")) |integrations_value| {
        if (integrations_value == .object) {
            if (integrations_value.object.get("telegram")) |telegram_value| {
                if (telegram_value == .object) {
                    telegram_configured = readObjectBool(telegram_value.object, "configured");
                    telegram_connected = readObjectBool(telegram_value.object, "connected");
                    if (readObjectString(telegram_value.object, "account_id")) |value| {
                        if (!std.mem.eql(u8, value, "null")) {
                            telegram_account_id = try allocator.dupe(u8, value);
                        }
                    }
                    telegram_chat_id = readObjectI64(telegram_value.object, "chat_id");
                    if (readObjectString(telegram_value.object, "data_source")) |value| {
                        telegram_data_source = try allocator.dupe(u8, value);
                    }
                    if (telegram_data_source) |source| {
                        if (std.mem.eql(u8, source, "global") and telegram_connected == null and telegram_configured != true) {
                            telegram_configured = null;
                        }
                    }
                }
            }
        }
    }

    if (parsed.value.object.get("identity_mapping")) |identity_value| {
        if (identity_value == .object) {
            identity_mapped = readObjectU64(identity_value.object, "mapped");
            identity_unmapped = readObjectU64(identity_value.object, "unmapped");
            identity_strict_rejected = readObjectU64(identity_value.object, "strict_rejected");
            identity_degraded_compat = readObjectU64(identity_value.object, "degraded_compat");
            identity_cache_hit = readObjectU64(identity_value.object, "cache_hit");
            identity_cache_miss = readObjectU64(identity_value.object, "cache_miss");
            identity_cache_stale = readObjectU64(identity_value.object, "cache_stale");
            identity_db_lookup_count = readObjectU64(identity_value.object, "db_lookup_count");
            identity_db_lookup_ms_total = readObjectU64(identity_value.object, "db_lookup_ms_total");
        }
    }

    return .{
        .source = .gateway_internal,
        .state_backend_configured = try allocator.dupe(u8, configured),
        .state_backend_effective = try allocator.dupe(u8, effective),
        .scheduler_backend = try allocator.dupe(u8, scheduler_backend),
        .degraded = degraded,
        .degraded_reason = try allocator.dupe(u8, degraded_reason),
        .heartbeat_enabled = heartbeat_enabled,
        .heartbeat_interval_minutes = heartbeat_interval_minutes,
        .tenant_enabled = tenant_enabled,
        .scheduler_max_tasks_configured = 0,
        .scheduler_max_concurrent_configured = 0,
        .chat_provider_effective = try allocator.dupe(u8, chat_provider_effective),
        .chat_fallback_chain = try allocator.dupe(u8, chat_fallback_chain),
        .embedding_provider_effective = try allocator.dupe(u8, embedding_provider_effective),
        .provider_data_source = try allocator.dupe(u8, provider_data_source),
        .telegram_configured = telegram_configured,
        .telegram_connected = telegram_connected,
        .telegram_account_id = telegram_account_id,
        .telegram_chat_id = telegram_chat_id,
        .telegram_data_source = telegram_data_source,
        .identity_mapped = identity_mapped,
        .identity_unmapped = identity_unmapped,
        .identity_strict_rejected = identity_strict_rejected,
        .identity_degraded_compat = identity_degraded_compat,
        .identity_cache_hit = identity_cache_hit,
        .identity_cache_miss = identity_cache_miss,
        .identity_cache_stale = identity_cache_stale,
        .identity_db_lookup_count = identity_db_lookup_count,
        .identity_db_lookup_ms_total = identity_db_lookup_ms_total,
    };
}

fn collectLocalFallbackSnapshot(allocator: std.mem.Allocator, cfg: *const config_mod.Config) !RuntimeSnapshot {
    const configured = cfg.state.backend;
    const effective = blk: {
        if (!std.mem.eql(u8, configured, "postgres")) break :blk "file";
        if (!build_options.enable_postgres) break :blk "file";
        break :blk "unknown";
    };
    const scheduler_backend = blk: {
        if (!cfg.tenant.enabled) break :blk "file";
        if (std.mem.eql(u8, configured, "postgres") and build_options.enable_postgres) break :blk "unknown";
        break :blk "file";
    };
    const degraded_reason = if (std.mem.eql(u8, configured, "postgres") and !build_options.enable_postgres)
        "PostgresNotEnabled"
    else
        "";
    const context_incomplete = std.mem.eql(u8, effective, "unknown") or std.mem.eql(u8, scheduler_backend, "unknown");

    return .{
        .source = .local_fallback,
        .state_backend_configured = try allocator.dupe(u8, configured),
        .state_backend_effective = try allocator.dupe(u8, effective),
        .scheduler_backend = try allocator.dupe(u8, scheduler_backend),
        .degraded = degraded_reason.len > 0,
        .degraded_reason = try allocator.dupe(u8, degraded_reason),
        .heartbeat_enabled = cfg.heartbeat.enabled,
        .heartbeat_interval_minutes = cfg.heartbeat.interval_minutes,
        .tenant_enabled = cfg.tenant.enabled,
        .scheduler_max_tasks_configured = cfg.scheduler.max_tasks,
        .scheduler_max_concurrent_configured = cfg.scheduler.max_concurrent,
        .scheduler_max_tasks_effective = if (std.mem.eql(u8, scheduler_backend, "unknown")) null else cfg.scheduler.max_tasks,
        .chat_provider_effective = try allocator.dupe(u8, normalizeProviderAlias(cfg.default_provider)),
        .chat_fallback_chain = try allocNormalizedFallbackChain(allocator, cfg.reliability.fallback_providers),
        .embedding_provider_effective = try allocator.dupe(u8, normalizeProviderAlias(cfg.memory.search.provider)),
        .provider_data_source = try allocator.dupe(u8, "config"),
        .telegram_configured = channel_catalog.configuredCount(cfg, .telegram) > 0,
        .telegram_connected = null,
        .telegram_account_id = null,
        .telegram_chat_id = null,
        .telegram_data_source = try allocator.dupe(u8, "local_fallback"),
        .context_incomplete = context_incomplete,
    };
}

fn normalizeProviderAlias(provider_name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, provider_name, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "together-ai")) return "together";
    if (std.mem.eql(u8, trimmed, "google-gemini")) return "gemini";
    return trimmed;
}

fn normalizeFallbackChain(chain: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, chain, " \t\r\n");
    if (trimmed.len == 0) return "none";
    if (std.mem.eql(u8, trimmed, "together-ai")) return "together";
    return trimmed;
}

fn allocNormalizedFallbackChain(allocator: std.mem.Allocator, providers: []const []const u8) ![]u8 {
    if (providers.len == 0) return allocator.dupe(u8, "none");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var wrote_any = false;
    for (providers) |provider_name| {
        const normalized = normalizeProviderAlias(provider_name);
        if (normalized.len == 0) continue;
        if (wrote_any) try out.append(allocator, ',');
        try out.appendSlice(allocator, normalized);
        wrote_any = true;
    }
    if (!wrote_any) return allocator.dupe(u8, "none");
    return out.toOwnedSlice(allocator);
}

fn readObjectString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn readObjectBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    if (v != .bool) return null;
    return v.bool;
}

fn readObjectU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => std.math.cast(u32, v.integer),
        .string => std.fmt.parseInt(u32, v.string, 10) catch null,
        else => null,
    };
}

fn readObjectU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => std.math.cast(u64, v.integer),
        .string => std.fmt.parseInt(u64, v.string, 10) catch null,
        else => null,
    };
}

fn readObjectI64(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => v.integer,
        .string => std.fmt.parseInt(i64, v.string, 10) catch null,
        else => null,
    };
}

test "parseGatewayDiagnosticsPayload reads startup self check" {
    const payload =
        \\{
        \\  "startup_self_check": {
        \\    "state_backend_configured": "postgres",
        \\    "state_backend_effective": "postgres",
        \\    "scheduler_backend": "postgres",
        \\    "degraded": false,
        \\    "degraded_reason": "",
        \\    "heartbeat_enabled": true,
        \\    "heartbeat_interval_minutes": 30,
        \\    "tenant_enabled": true
        \\  },
        \\  "integrations": {
        \\    "telegram": {
        \\      "configured": true,
        \\      "connected": true,
        \\      "account_id": "main",
        \\      "chat_id": 1110331014,
        \\      "data_source": "postgres"
        \\    }
        \\  },
        \\  "identity_mapping": {
        \\    "mapped": 11,
        \\    "unmapped": 2,
        \\    "strict_rejected": 1,
        \\    "degraded_compat": 3,
        \\    "cache_hit": 8,
        \\    "cache_miss": 5,
        \\    "cache_stale": 1,
        \\    "db_lookup_count": 5,
        \\    "db_lookup_ms_total": 41
        \\  }
        \\}
    ;
    var snapshot = try parseGatewayDiagnosticsPayload(std.testing.allocator, payload);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(Source.gateway_internal, snapshot.source);
    try std.testing.expectEqualStrings("postgres", snapshot.state_backend_effective);
    try std.testing.expectEqualStrings("postgres", snapshot.scheduler_backend);
    try std.testing.expect(snapshot.heartbeat_enabled);
    try std.testing.expectEqual(@as(u32, 30), snapshot.heartbeat_interval_minutes);
    try std.testing.expectEqual(@as(?bool, true), snapshot.telegram_configured);
    try std.testing.expectEqual(@as(?bool, true), snapshot.telegram_connected);
    try std.testing.expectEqualStrings("main", snapshot.telegram_account_id.?);
    try std.testing.expectEqual(@as(?i64, 1110331014), snapshot.telegram_chat_id);
    try std.testing.expectEqualStrings("postgres", snapshot.telegram_data_source.?);
    try std.testing.expectEqualStrings("unknown", snapshot.chat_provider_effective);
    try std.testing.expectEqualStrings("none", snapshot.chat_fallback_chain);
    try std.testing.expectEqualStrings("none", snapshot.embedding_provider_effective);
    try std.testing.expectEqualStrings("gateway_internal", snapshot.provider_data_source);
    try std.testing.expectEqual(@as(?u64, 11), snapshot.identity_mapped);
    try std.testing.expectEqual(@as(?u64, 2), snapshot.identity_unmapped);
    try std.testing.expectEqual(@as(?u64, 1), snapshot.identity_strict_rejected);
    try std.testing.expectEqual(@as(?u64, 3), snapshot.identity_degraded_compat);
    try std.testing.expectEqual(@as(?u64, 8), snapshot.identity_cache_hit);
    try std.testing.expectEqual(@as(?u64, 5), snapshot.identity_cache_miss);
    try std.testing.expectEqual(@as(?u64, 1), snapshot.identity_cache_stale);
    try std.testing.expectEqual(@as(?u64, 5), snapshot.identity_db_lookup_count);
    try std.testing.expectEqual(@as(?u64, 41), snapshot.identity_db_lookup_ms_total);
}

test "collectLocalFallbackSnapshot marks unknown effective backend when runtime probe is unavailable" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/nullalis/workspace",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = true;
    cfg.state.backend = "postgres";
    cfg.scheduler.max_tasks = 64;
    cfg.scheduler.max_concurrent = 4;

    var snapshot = try collectLocalFallbackSnapshot(std.testing.allocator, &cfg);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(Source.local_fallback, snapshot.source);
    try std.testing.expectEqualStrings("postgres", snapshot.state_backend_configured);
    if (build_options.enable_postgres) {
        try std.testing.expectEqualStrings("unknown", snapshot.state_backend_effective);
        try std.testing.expect(snapshot.context_incomplete);
    } else {
        try std.testing.expectEqualStrings("file", snapshot.state_backend_effective);
        try std.testing.expect(!snapshot.context_incomplete);
    }
    try std.testing.expectEqualStrings("openrouter", snapshot.chat_provider_effective);
    try std.testing.expectEqualStrings("none", snapshot.chat_fallback_chain);
    try std.testing.expectEqualStrings("none", snapshot.embedding_provider_effective);
    try std.testing.expectEqualStrings("config", snapshot.provider_data_source);
}
