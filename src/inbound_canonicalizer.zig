const std = @import("std");
const Config = @import("config.zig").Config;
const zaki_session = @import("zaki_session.zig");
const zaki_state = @import("zaki_state.zig");

pub const CanonicalSessionLane = enum {
    main,
    thread,
    task,
    cron,
};

pub const InboundIdentityEnvelope = struct {
    channel: []const u8,
    account_id: []const u8,
    principal_key: []const u8,
    scope_key: []const u8,
    thread_key: ?[]const u8 = null,
    message_id: ?[]const u8 = null,
    fallback_session_key: []const u8,
    lane: CanonicalSessionLane = .main,
};

pub const DecisionKind = enum {
    canonical,
    degraded_compat,
    strict_reject,
};

pub const CanonicalizationDecision = struct {
    kind: DecisionKind,
    session_key: ?[]u8 = null,
    user_id: ?[]u8 = null,
    strict_channel: bool = false,
    reason_code: []const u8 = "ok",
    mapping_source: []const u8 = "none",
    cache_status: []const u8 = "none",
    db_lookup_ms: u64 = 0,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.session_key) |value| allocator.free(value);
        if (self.user_id) |value| allocator.free(value);
    }
};

pub const MetricsSnapshot = struct {
    mapped: u64,
    unmapped: u64,
    strict_rejected: u64,
    degraded_compat: u64,
    cache_hit: u64,
    cache_miss: u64,
    cache_stale: u64,
    db_lookup_count: u64,
    db_lookup_ms_total: u64,
};

const CachePositiveEntry = struct {
    user_id: i64,
    expires_at_s: i64,
};

const CacheState = struct {
    mutex: std.Thread.Mutex = .{},
    positive: std.StringHashMapUnmanaged(CachePositiveEntry) = .empty,
    negative: std.StringHashMapUnmanaged(i64) = .empty,

    fn purgeLocked(self: *CacheState, allocator: std.mem.Allocator) void {
        var positive_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (positive_remove.items) |key| allocator.free(key);
            positive_remove.deinit(allocator);
        }
        const now_s = std.time.timestamp();
        var pos_it = self.positive.iterator();
        while (pos_it.next()) |entry| {
            if (entry.value_ptr.expires_at_s <= now_s) {
                const key_copy = allocator.dupe(u8, entry.key_ptr.*) catch continue;
                positive_remove.append(allocator, key_copy) catch allocator.free(key_copy);
            }
        }
        for (positive_remove.items) |key| {
            if (self.positive.fetchRemove(key)) |removed| {
                allocator.free(@constCast(removed.key));
                _ = METRICS.cache_stale.fetchAdd(1, .monotonic);
            }
        }

        var negative_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (negative_remove.items) |key| allocator.free(key);
            negative_remove.deinit(allocator);
        }
        var neg_it = self.negative.iterator();
        while (neg_it.next()) |entry| {
            if (entry.value_ptr.* <= now_s) {
                const key_copy = allocator.dupe(u8, entry.key_ptr.*) catch continue;
                negative_remove.append(allocator, key_copy) catch allocator.free(key_copy);
            }
        }
        for (negative_remove.items) |key| {
            if (self.negative.fetchRemove(key)) |removed| {
                allocator.free(@constCast(removed.key));
                _ = METRICS.cache_stale.fetchAdd(1, .monotonic);
            }
        }
    }
};

const LookupResult = struct {
    user_id: ?i64 = null,
    cache_status: []const u8 = "none",
    mapping_source: []const u8 = "none",
    db_lookup_ms: u64 = 0,
};

var CACHE: CacheState = .{};

const METRICS = struct {
    var mapped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    var unmapped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    var strict_rejected: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    var degraded_compat: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    var cache_hit: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    var cache_miss: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    var cache_stale: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    var db_lookup_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    var db_lookup_ms_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
};

fn cacheAllocator() std.mem.Allocator {
    return std.heap.c_allocator;
}

pub fn metricsSnapshot() MetricsSnapshot {
    return .{
        .mapped = METRICS.mapped.load(.monotonic),
        .unmapped = METRICS.unmapped.load(.monotonic),
        .strict_rejected = METRICS.strict_rejected.load(.monotonic),
        .degraded_compat = METRICS.degraded_compat.load(.monotonic),
        .cache_hit = METRICS.cache_hit.load(.monotonic),
        .cache_miss = METRICS.cache_miss.load(.monotonic),
        .cache_stale = METRICS.cache_stale.load(.monotonic),
        .db_lookup_count = METRICS.db_lookup_count.load(.monotonic),
        .db_lookup_ms_total = METRICS.db_lookup_ms_total.load(.monotonic),
    };
}

pub fn invalidateAllCache() void {
    const allocator = cacheAllocator();
    CACHE.mutex.lock();
    defer CACHE.mutex.unlock();

    var pos_it = CACHE.positive.iterator();
    while (pos_it.next()) |entry| {
        allocator.free(@constCast(entry.key_ptr.*));
    }
    CACHE.positive.clearRetainingCapacity();

    var neg_it = CACHE.negative.iterator();
    while (neg_it.next()) |entry| {
        allocator.free(@constCast(entry.key_ptr.*));
    }
    CACHE.negative.clearRetainingCapacity();
}

pub fn invalidateCacheForIdentity(input: InboundIdentityEnvelope) void {
    const allocator = cacheAllocator();
    const key = std.fmt.allocPrint(allocator, "{s}|{s}|{s}|{s}|{s}", .{
        input.channel,
        input.account_id,
        input.principal_key,
        input.scope_key,
        input.thread_key orelse "",
    }) catch return;
    defer allocator.free(key);

    CACHE.mutex.lock();
    defer CACHE.mutex.unlock();
    if (CACHE.positive.fetchRemove(key)) |removed| allocator.free(@constCast(removed.key));
    if (CACHE.negative.fetchRemove(key)) |removed| allocator.free(@constCast(removed.key));
}

pub fn canonicalizeInboundTurn(
    allocator: std.mem.Allocator,
    state_mgr: ?*zaki_state.Manager,
    cfg: *const Config,
    input: InboundIdentityEnvelope,
) !CanonicalizationDecision {
    const tenant_postgres = cfg.tenant.enabled and std.mem.eql(u8, cfg.state.backend, "postgres");
    const strict_channel = isStrictChannel(cfg, input.channel);

    if (!tenant_postgres) {
        _ = METRICS.degraded_compat.fetchAdd(1, .monotonic);
        return .{
            .kind = .degraded_compat,
            .session_key = try allocator.dupe(u8, input.fallback_session_key),
            .strict_channel = strict_channel,
            .reason_code = "tenant_mapping_not_required",
            .mapping_source = "compat",
            .cache_status = "none",
        };
    }

    if (state_mgr == null) {
        if (strict_channel) {
            _ = METRICS.strict_rejected.fetchAdd(1, .monotonic);
            return .{
                .kind = .strict_reject,
                .strict_channel = true,
                .reason_code = "state_manager_missing",
            };
        }
        _ = METRICS.degraded_compat.fetchAdd(1, .monotonic);
        return .{
            .kind = .degraded_compat,
            .session_key = try allocator.dupe(u8, input.fallback_session_key),
            .strict_channel = false,
            .reason_code = "state_manager_missing",
            .mapping_source = "compat",
            .cache_status = "none",
        };
    }

    if (input.principal_key.len == 0 or input.scope_key.len == 0) {
        if (strict_channel) {
            _ = METRICS.strict_rejected.fetchAdd(1, .monotonic);
            return .{
                .kind = .strict_reject,
                .strict_channel = true,
                .reason_code = "missing_identity_keys",
            };
        }
        _ = METRICS.degraded_compat.fetchAdd(1, .monotonic);
        return .{
            .kind = .degraded_compat,
            .session_key = try allocator.dupe(u8, input.fallback_session_key),
            .strict_channel = false,
            .reason_code = "missing_identity_keys",
            .mapping_source = "compat",
            .cache_status = "none",
        };
    }

    const lookup = try resolveUserId(state_mgr.?, cfg, input);
    if (lookup.user_id) |resolved_user_id| {
        var user_id_buf: [32]u8 = undefined;
        const user_id_text = try std.fmt.bufPrint(&user_id_buf, "{d}", .{resolved_user_id});
        const canonical_session = try buildCanonicalSessionKey(allocator, user_id_text, input);
        _ = METRICS.mapped.fetchAdd(1, .monotonic);
        return .{
            .kind = .canonical,
            .session_key = canonical_session,
            .user_id = try allocator.dupe(u8, user_id_text),
            .strict_channel = strict_channel,
            .reason_code = "ok",
            .mapping_source = lookup.mapping_source,
            .cache_status = lookup.cache_status,
            .db_lookup_ms = lookup.db_lookup_ms,
        };
    }

    _ = METRICS.unmapped.fetchAdd(1, .monotonic);
    if (strict_channel) {
        _ = METRICS.strict_rejected.fetchAdd(1, .monotonic);
        return .{
            .kind = .strict_reject,
            .strict_channel = true,
            .reason_code = "identity_mapping_not_found",
            .mapping_source = lookup.mapping_source,
            .cache_status = lookup.cache_status,
            .db_lookup_ms = lookup.db_lookup_ms,
        };
    }

    _ = METRICS.degraded_compat.fetchAdd(1, .monotonic);
    return .{
        .kind = .degraded_compat,
        .session_key = try allocator.dupe(u8, input.fallback_session_key),
        .strict_channel = false,
        .reason_code = "identity_mapping_not_found",
        .mapping_source = lookup.mapping_source,
        .cache_status = lookup.cache_status,
        .db_lookup_ms = lookup.db_lookup_ms,
    };
}

fn resolveUserId(
    state_mgr: *zaki_state.Manager,
    cfg: *const Config,
    input: InboundIdentityEnvelope,
) !LookupResult {
    const allocator = cacheAllocator();
    const key = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}|{s}|{s}", .{
        input.channel,
        input.account_id,
        input.principal_key,
        input.scope_key,
        input.thread_key orelse "",
    });
    defer allocator.free(key);

    const now_s = std.time.timestamp();
    CACHE.mutex.lock();
    CACHE.purgeLocked(allocator);

    if (CACHE.positive.get(key)) |entry| {
        if (entry.expires_at_s > now_s) {
            CACHE.mutex.unlock();
            _ = METRICS.cache_hit.fetchAdd(1, .monotonic);
            return .{
                .user_id = entry.user_id,
                .cache_status = "hit_positive",
                .mapping_source = "cache_positive",
            };
        }
    }
    if (CACHE.negative.get(key)) |expires_at_s| {
        if (expires_at_s > now_s) {
            CACHE.mutex.unlock();
            _ = METRICS.cache_hit.fetchAdd(1, .monotonic);
            return .{
                .user_id = null,
                .cache_status = "hit_negative",
                .mapping_source = "cache_negative",
            };
        }
    }
    CACHE.mutex.unlock();
    _ = METRICS.cache_miss.fetchAdd(1, .monotonic);

    const lookup_start = std.time.milliTimestamp();
    const resolved_user = try state_mgr.resolveUserByChannelIdentity(
        input.channel,
        input.account_id,
        input.principal_key,
        input.scope_key,
        input.thread_key,
    );
    const lookup_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - lookup_start));
    _ = METRICS.db_lookup_count.fetchAdd(1, .monotonic);
    _ = METRICS.db_lookup_ms_total.fetchAdd(lookup_ms, .monotonic);

    const pos_ttl: i64 = @intCast(if (cfg.tenant.identity_mapping_positive_ttl_secs > 0) cfg.tenant.identity_mapping_positive_ttl_secs else 300);
    const neg_ttl: i64 = @intCast(if (cfg.tenant.identity_mapping_negative_ttl_secs > 0) cfg.tenant.identity_mapping_negative_ttl_secs else 30);
    const cache_key = try allocator.dupe(u8, key);
    errdefer allocator.free(cache_key);

    CACHE.mutex.lock();
    defer CACHE.mutex.unlock();
    if (resolved_user) |user_id| {
        if (CACHE.positive.fetchRemove(cache_key)) |removed| allocator.free(@constCast(removed.key));
        if (CACHE.negative.fetchRemove(cache_key)) |removed| allocator.free(@constCast(removed.key));
        try CACHE.positive.put(allocator, cache_key, .{
            .user_id = user_id,
            .expires_at_s = now_s + pos_ttl,
        });
        return .{
            .user_id = user_id,
            .cache_status = "miss",
            .mapping_source = "db",
            .db_lookup_ms = lookup_ms,
        };
    }

    if (CACHE.negative.fetchRemove(cache_key)) |removed| allocator.free(@constCast(removed.key));
    if (CACHE.positive.fetchRemove(cache_key)) |removed| allocator.free(@constCast(removed.key));
    try CACHE.negative.put(allocator, cache_key, now_s + neg_ttl);
    return .{
        .user_id = null,
        .cache_status = "miss",
        .mapping_source = "db",
        .db_lookup_ms = lookup_ms,
    };
}

fn isStrictChannel(cfg: *const Config, channel: []const u8) bool {
    if (!std.mem.eql(u8, cfg.tenant.identity_mapping_enforcement, "staged_strict")) return false;
    for (cfg.tenant.identity_mapping_strict_channels) |entry| {
        if (std.mem.eql(u8, entry, channel)) return true;
    }
    return false;
}

fn buildCanonicalSessionKey(
    allocator: std.mem.Allocator,
    user_id: []const u8,
    input: InboundIdentityEnvelope,
) ![]u8 {
    var key_buf: [256]u8 = undefined;
    return switch (input.lane) {
        .main => allocator.dupe(u8, zaki_session.userMainSessionKey(&key_buf, user_id)),
        .thread => allocator.dupe(u8, zaki_session.userThreadSessionKey(&key_buf, user_id, input.thread_key orelse "default")),
        .task => allocator.dupe(u8, zaki_session.userTaskSessionKey(&key_buf, user_id, input.thread_key orelse "default")),
        .cron => allocator.dupe(u8, zaki_session.userCronSessionKey(&key_buf, user_id, input.thread_key orelse "default")),
    };
}

test "canonicalizer degrades when tenant mapping not required" {
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = false;
    var decision = try canonicalizeInboundTurn(std.testing.allocator, null, &cfg, .{
        .channel = "telegram",
        .account_id = "default",
        .principal_key = "telegram:principal:1",
        .scope_key = "telegram:scope:1",
        .fallback_session_key = "telegram:1",
    });
    defer decision.deinit(std.testing.allocator);
    try std.testing.expectEqual(DecisionKind.degraded_compat, decision.kind);
    try std.testing.expectEqualStrings("tenant_mapping_not_required", decision.reason_code);
}

test "canonicalizer rejects strict channel when manager missing" {
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = true;
    cfg.state.backend = "postgres";
    cfg.tenant.identity_mapping_enforcement = "staged_strict";
    cfg.tenant.identity_mapping_strict_channels = &[_][]const u8{"telegram"};

    var decision = try canonicalizeInboundTurn(std.testing.allocator, null, &cfg, .{
        .channel = "telegram",
        .account_id = "default",
        .principal_key = "telegram:principal:1",
        .scope_key = "telegram:scope:1",
        .fallback_session_key = "telegram:1",
    });
    defer decision.deinit(std.testing.allocator);
    try std.testing.expectEqual(DecisionKind.strict_reject, decision.kind);
    try std.testing.expectEqualStrings("state_manager_missing", decision.reason_code);
}

test "canonicalizer rejects strict channel when identity keys missing" {
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.tenant.enabled = true;
    cfg.state.backend = "postgres";
    cfg.tenant.identity_mapping_enforcement = "staged_strict";
    cfg.tenant.identity_mapping_strict_channels = &[_][]const u8{"telegram"};
    var mgr = zaki_state.Manager.init(std.testing.allocator, .{}) catch |err| switch (err) {
        error.PostgresNotEnabled => return error.SkipZigTest,
        else => return err,
    };
    defer mgr.deinit();

    var decision = try canonicalizeInboundTurn(std.testing.allocator, &mgr, &cfg, .{
        .channel = "telegram",
        .account_id = "default",
        .principal_key = "",
        .scope_key = "",
        .fallback_session_key = "telegram:1",
    });
    defer decision.deinit(std.testing.allocator);
    try std.testing.expectEqual(DecisionKind.strict_reject, decision.kind);
    try std.testing.expectEqualStrings("missing_identity_keys", decision.reason_code);
}

test "invalidateCacheForIdentity is safe on empty cache" {
    invalidateAllCache();
    invalidateCacheForIdentity(.{
        .channel = "telegram",
        .account_id = "default",
        .principal_key = "telegram:principal:1",
        .scope_key = "telegram:scope:1",
        .fallback_session_key = "telegram:1",
    });
}
