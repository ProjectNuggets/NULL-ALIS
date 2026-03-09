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
    telegram_configured: ?bool = null,
    telegram_connected: ?bool = null,
    context_incomplete: bool = false,

    pub fn deinit(self: *RuntimeSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.state_backend_configured);
        allocator.free(self.state_backend_effective);
        allocator.free(self.scheduler_backend);
        allocator.free(self.degraded_reason);
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
    snapshot.scheduler_max_tasks_configured = cfg.scheduler.max_tasks;
    snapshot.scheduler_max_concurrent_configured = cfg.scheduler.max_concurrent;
    snapshot.scheduler_max_tasks_effective = cfg.scheduler.max_tasks;
    snapshot.telegram_configured = channel_catalog.configuredCount(cfg, .telegram) > 0;
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
        .telegram_configured = channel_catalog.configuredCount(cfg, .telegram) > 0,
        .telegram_connected = null,
        .context_incomplete = context_incomplete,
    };
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
}
