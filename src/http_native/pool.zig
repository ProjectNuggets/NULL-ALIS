//! Connection Pool for native HTTP client
//!
//! Reuses TCP+TLS connections with keep-alive support.
//! Thread-safe with Mutex protection.

const std = @import("std");
const types = @import("types.zig");
const root = @import("root.zig");

const Allocator = std.mem.Allocator;
const PoolConfig = types.PoolConfig;
const TlsIoState = root.TlsIoState;

/// Pooled connection entry
pub const PooledConnection = struct {
    stream: std.net.Stream,
    tls_state: ?*TlsIoState,
    created_at: i64,
    requests_served: u16,
};

/// Per-host connection pool
const HostPool = struct {
    conns: std.ArrayListUnmanaged(PooledConnection),
    last_used: i64,
};

pub const ConnectionPool = struct {
    allocator: Allocator,
    config: PoolConfig,
    mutex: std.Thread.Mutex,
    pools: std.StringHashMapUnmanaged(HostPool),
    last_eviction: i64,

    const Self = @This();

    pub fn init(allocator: Allocator, config: PoolConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .mutex = .{},
            .pools = .{},
            .last_eviction = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.pools.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.conns.items) |*conn| {
                if (conn.tls_state) |tls| {
                    tls.deinit(self.allocator);
                }
                conn.stream.close();
            }
            entry.value_ptr.conns.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.pools.deinit(self.allocator);
    }

    fn makeKey(alloc: Allocator, host: []const u8, port: u16, is_tls: bool) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}:{d}:{d}", .{ host, port, @intFromBool(is_tls) });
    }

    pub fn acquire(self: *Self, host: []const u8, port: u16, is_tls: bool) ?PooledConnection {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        // Periodic eviction
        if (now - self.last_eviction > 60) {
            self.evictExpiredInternal(now);
            self.last_eviction = now;
        }

        const key = makeKey(self.allocator, host, port, is_tls) catch return null;
        defer self.allocator.free(key);

        const hp = self.pools.getPtr(key) orelse return null;

        // Scan for valid connection
        while (hp.conns.items.len > 0) {
            const conn = &hp.conns.items[0];
            const age_ms = (now - conn.created_at) * 1000;

            if (age_ms > self.config.max_idle_time_ms or
                conn.requests_served >= self.config.max_requests_per_conn)
            {
                // Expired - remove first element
                if (conn.tls_state) |tls| tls.deinit(self.allocator);
                conn.stream.close();
                _ = hp.conns.orderedRemove(0);
                continue;
            }

            // Valid connection - remove and return
            const result = conn.*;
            _ = hp.conns.orderedRemove(0);
            hp.last_used = now;
            return result;
        }

        return null;
    }

    pub fn release(self: *Self, host: []const u8, port: u16, is_tls: bool, conn: PooledConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        // Check validity
        const age_ms = (now - conn.created_at) * 1000;
        if (age_ms > self.config.max_idle_time_ms or
            conn.requests_served >= self.config.max_requests_per_conn)
        {
            if (conn.tls_state) |tls| tls.deinit(self.allocator);
            conn.stream.close();
            return;
        }

        const key = makeKey(self.allocator, host, port, is_tls) catch {
            if (conn.tls_state) |tls| tls.deinit(self.allocator);
            conn.stream.close();
            return;
        };

        const gop = self.pools.getOrPut(self.allocator, key) catch {
            self.allocator.free(key);
            if (conn.tls_state) |tls| tls.deinit(self.allocator);
            conn.stream.close();
            return;
        };

        if (!gop.found_existing) {
            gop.key_ptr.* = key;
            gop.value_ptr.* = .{ .conns = .{}, .last_used = now };
        } else {
            self.allocator.free(key);
        }

        // Enforce max connections per host
        if (gop.value_ptr.conns.items.len >= self.config.max_connections) {
            if (gop.value_ptr.conns.items.len > 0) {
                const oldest = gop.value_ptr.conns.orderedRemove(0);
                if (oldest.tls_state) |tls| tls.deinit(self.allocator);
                oldest.stream.close();
            }
        }

        gop.value_ptr.conns.append(self.allocator, conn) catch {
            if (conn.tls_state) |tls| tls.deinit(self.allocator);
            conn.stream.close();
        };
        gop.value_ptr.last_used = now;
    }

    fn evictExpiredInternal(self: *Self, now: i64) void {
        var it = self.pools.iterator();
        var to_remove: std.ArrayListUnmanaged([]const u8) = .{};
        defer {
            for (to_remove.items) |k| self.allocator.free(k);
            to_remove.deinit(self.allocator);
        }

        while (it.next()) |entry| {
            var i: usize = 0;
            while (i < entry.value_ptr.conns.items.len) {
                const conn = &entry.value_ptr.conns.items[i];
                const age_ms = (now - conn.created_at) * 1000;

                if (age_ms > self.config.max_idle_time_ms or
                    conn.requests_served >= self.config.max_requests_per_conn)
                {
                    if (conn.tls_state) |tls| tls.deinit(self.allocator);
                    conn.stream.close();
                    _ = entry.value_ptr.conns.orderedRemove(i);
                    continue;
                }
                i += 1;
            }

            if (entry.value_ptr.conns.items.len == 0) {
                const k = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                to_remove.append(self.allocator, k) catch self.allocator.free(k);
            }
        }

        for (to_remove.items) |key| {
            if (self.pools.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                var conns = kv.value.conns;
                conns.deinit(self.allocator);
            }
        }
    }

    pub fn stats(self: *Self, idle: *u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var total: u64 = 0;
        var it = self.pools.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.conns.items.len;
        }
        idle.* = total;
    }
};

// Global singleton
var global_pool: ?ConnectionPool = null;
var global_mutex: std.Thread.Mutex = .{};

pub fn globalPool(allocator: Allocator, config: PoolConfig) *ConnectionPool {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_pool == null) {
        global_pool = ConnectionPool.init(allocator, config);
    }
    return &global_pool.?;
}

test "connection pool basic" {
    const allocator = std.testing.allocator;
    var pool = ConnectionPool.init(allocator, .{
        .max_connections = 2,
        .max_idle_time_ms = 30_000,
        .max_requests_per_conn = 100,
    });
    defer pool.deinit();

    const conn = pool.acquire("example.com", 443, true);
    try std.testing.expect(conn == null);
}

test "connection pool stats" {
    const allocator = std.testing.allocator;
    var pool = ConnectionPool.init(allocator, .{
        .max_connections = 2,
        .max_idle_time_ms = 30_000,
        .max_requests_per_conn = 100,
    });
    defer pool.deinit();

    // Empty pool should have 0 idle
    var idle: u64 = 0;
    pool.stats(&idle);
    try std.testing.expectEqual(@as(u64, 0), idle);
}
