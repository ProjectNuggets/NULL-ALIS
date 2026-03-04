const std = @import("std");

pub const TransportMode = enum {
    curl_only,
    native_preferred,
    native_only,
};

pub const TransportSubsystem = enum {
    providers,
    channels,
    tools,
    system,
};

pub const PoolConfig = struct {
    max_connections: u16 = 8,
    max_idle_time_ms: u32 = 30_000,
    max_requests_per_conn: u16 = 100,
};

pub const ResolverConfig = struct {
    threads: u8 = 2,
    cache_ttl_secs: u32 = 30,
};

pub const RequestOptions = struct {
    method: []const u8,
    url: []const u8,
    headers: []const []const u8 = &.{},
    body: ?[]const u8 = null,
    proxy: ?[]const u8 = null,
    timeout_ms: u32 = 30_000,
    max_response_bytes: usize = 4 * 1024 * 1024,
    subsystem: TransportSubsystem = .system,
    resolve_host: ?[]const u8 = null,
    resolve_port: u16 = 0,
    connect_host: ?[]const u8 = null,
};

pub const Response = struct {
    status_code: u16,
    body: []u8,
    reused_connection: bool = false,
};

pub const TransportConfig = struct {
    mode: TransportMode = .native_preferred,
    resolver: ResolverConfig = .{},
    providers: PoolConfig = .{ .max_connections = 24 },
    channels: PoolConfig = .{ .max_connections = 16 },
    tools: PoolConfig = .{},
    system: PoolConfig = .{ .max_connections = 2 },
};

test "transport defaults are sane" {
    const cfg = TransportConfig{};
    try std.testing.expectEqual(TransportMode.native_preferred, cfg.mode);
    try std.testing.expectEqual(@as(u16, 24), cfg.providers.max_connections);
    try std.testing.expectEqual(@as(u8, 2), cfg.resolver.threads);
}
