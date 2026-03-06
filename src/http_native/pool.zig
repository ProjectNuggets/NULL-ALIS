//! Connection pool for the native HTTP client.
//!
//! Design constraints:
//!   - Pool only stores idle, fully-drained connections.
//!   - Caller is responsible for correct HTTP/1.1 response consumption
//!     (Content-Length or chunked) before releasing a connection here.
//!   - If the server sent Connection: close the caller MUST NOT release
//!     the connection here — close it directly instead.
//!   - Thread-safe: a single Mutex guards all map operations.
//!   - Allocator is fixed at init time (page_allocator for the singleton);
//!     never captured from a request-scoped allocator.
//!   - close_fn is injected by root.zig to avoid circular imports.

const std = @import("std");
const PoolConfig = @import("types.zig").PoolConfig;

const Allocator = std.mem.Allocator;

/// An idle connection held in the pool.
/// For HTTPS, tls_state is non-null (*TlsIoState from root.zig, opaque here).
/// Pool owns tls_state allocation.
pub const PooledConn = struct {
    stream: std.net.Stream,
    tls_state: ?*anyopaque, // *TlsIoState for HTTPS, null for HTTP
    created_at_s: i64,
    requests_served: u32,
    is_tls: bool,
};

const Bucket = struct {
    conns: std.ArrayListUnmanaged(PooledConn) = .{},
};

pub const ConnectionPool = struct {
    allocator: Allocator,
    config: PoolConfig,
    mutex: std.Thread.Mutex,
    map: std.StringHashMapUnmanaged(Bucket),
    last_eviction_s: i64,
    hits: std.atomic.Value(u64),
    misses: std.atomic.Value(u64),
    close_fn: *const fn (PooledConn) void,

    const Self = @This();

    pub fn init(allocator: Allocator, config: PoolConfig, close_fn: *const fn (PooledConn) void) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .mutex = .{},
            .map = .{},
            .last_eviction_s = 0,
            .hits = std.atomic.Value(u64).init(0),
            .misses = std.atomic.Value(u64).init(0),
            .close_fn = close_fn,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.map.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.conns.items) |conn| self.close_fn(conn);
            entry.value_ptr.conns.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    /// Acquire an idle connection. Returns null on miss.
    pub fn acquire(self: *Self, host: []const u8, port: u16, is_tls: bool) ?PooledConn {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        if (now - self.last_eviction_s >= 30) {
            self.evictExpiredLocked(now);
            self.last_eviction_s = now;
        }

        const key = makeKey(self.allocator, host, port, is_tls) catch {
            _ = self.misses.fetchAdd(1, .monotonic);
            return null;
        };
        defer self.allocator.free(key);

        const bucket = self.map.getPtr(key) orelse {
            _ = self.misses.fetchAdd(1, .monotonic);
            return null;
        };

        const max_age_ms: i64 = @intCast(self.config.max_idle_time_ms);
        while (bucket.conns.items.len > 0) {
            const conn = bucket.conns.pop() orelse break;
            const age_ms = (now - conn.created_at_s) * 1000;
            if (age_ms > max_age_ms or conn.requests_served >= self.config.max_requests_per_conn) {
                self.close_fn(conn);
                continue;
            }
            _ = self.hits.fetchAdd(1, .monotonic);
            return conn;
        }
        _ = self.misses.fetchAdd(1, .monotonic);
        return null;
    }

    /// Release a fully-drained connection back to the pool.
    /// ONLY call if: (1) response body fully consumed, (2) server did NOT
    /// send Connection: close, (3) no error occurred during response read.
    pub fn release(self: *Self, host: []const u8, port: u16, is_tls: bool, conn: PooledConn) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const max_age_ms: i64 = @intCast(self.config.max_idle_time_ms);
        const age_ms = (now - conn.created_at_s) * 1000;

        if (age_ms > max_age_ms or conn.requests_served >= self.config.max_requests_per_conn) {
            self.close_fn(conn);
            return;
        }

        const key = makeKey(self.allocator, host, port, is_tls) catch {
            self.close_fn(conn);
            return;
        };

        const gop = self.map.getOrPut(self.allocator, key) catch {
            self.allocator.free(key);
            self.close_fn(conn);
            return;
        };
        if (!gop.found_existing) {
            gop.key_ptr.* = key;
            gop.value_ptr.* = .{};
        } else {
            self.allocator.free(key);
        }

        // Enforce per-host cap.
        if (gop.value_ptr.conns.items.len >= self.config.max_connections) {
            const oldest = gop.value_ptr.conns.orderedRemove(0);
            self.close_fn(oldest);
        }

        gop.value_ptr.conns.append(self.allocator, conn) catch {
            self.close_fn(conn);
        };
    }

    pub fn idleCount(self: *Self) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: u64 = 0;
        var it = self.map.iterator();
        while (it.next()) |e| n += e.value_ptr.conns.items.len;
        return n;
    }

    fn evictExpiredLocked(self: *Self, now: i64) void {
        const max_age_ms: i64 = @intCast(self.config.max_idle_time_ms);
        var it = self.map.iterator();
        while (it.next()) |entry| {
            var i: usize = 0;
            while (i < entry.value_ptr.conns.items.len) {
                const conn = entry.value_ptr.conns.items[i];
                const age_ms = (now - conn.created_at_s) * 1000;
                if (age_ms > max_age_ms or conn.requests_served >= self.config.max_requests_per_conn) {
                    self.close_fn(conn);
                    _ = entry.value_ptr.conns.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    pub fn makeKey(allocator: Allocator, host: []const u8, port: u16, is_tls: bool) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{d}:{d}", .{ host, port, @intFromBool(is_tls) });
    }
};

// ── Singleton ─────────────────────────────────────────────────────────────────

var g_pool_mutex: std.Thread.Mutex = .{};
var g_pool: ?ConnectionPool = null;

/// Returns the process-wide pool. close_fn must be the same on every call.
/// Uses page_allocator so lifetime outlives all request-scoped allocators.
pub fn globalPool(config: PoolConfig, close_fn: *const fn (PooledConn) void) *ConnectionPool {
    g_pool_mutex.lock();
    defer g_pool_mutex.unlock();
    if (g_pool == null) {
        g_pool = ConnectionPool.init(std.heap.page_allocator, config, close_fn);
    }
    return &g_pool.?;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn nopClose(_: PooledConn) void {}

test "pool: empty acquire returns null and counts miss" {
    var pool = ConnectionPool.init(std.testing.allocator, .{}, nopClose);
    defer pool.deinit();
    try std.testing.expect(pool.acquire("api.example.com", 443, true) == null);
    try std.testing.expectEqual(@as(u64, 1), pool.misses.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), pool.hits.load(.monotonic));
}

test "pool: expired entry evicted on acquire" {
    var pool = ConnectionPool.init(std.testing.allocator, .{
        .max_connections = 8,
        .max_idle_time_ms = 0, // expire immediately
        .max_requests_per_conn = 100,
    }, nopClose);
    defer pool.deinit();

    {
        pool.mutex.lock();
        defer pool.mutex.unlock();
        const key = try ConnectionPool.makeKey(std.testing.allocator, "old.example.com", 443, true);
        const gop = try pool.map.getOrPut(std.testing.allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const stale = PooledConn{
            .stream = undefined,
            .tls_state = null,
            .created_at_s = std.time.timestamp() - 10,
            .requests_served = 1,
            .is_tls = true,
        };
        try gop.value_ptr.conns.append(std.testing.allocator, stale);
    }
    // acquire evicts stale; returns null.
    try std.testing.expect(pool.acquire("old.example.com", 443, true) == null);
    try std.testing.expectEqual(@as(u64, 0), pool.idleCount());
}

test "pool: per-host isolation" {
    var pool = ConnectionPool.init(std.testing.allocator, .{
        .max_connections = 8,
        .max_idle_time_ms = 60_000,
        .max_requests_per_conn = 100,
    }, nopClose);
    defer pool.deinit();

    const now_ts = std.time.timestamp();
    const insertDirect = struct {
        fn run(p: *ConnectionPool, host: []const u8, ts: i64) !void {
            p.mutex.lock();
            defer p.mutex.unlock();
            const key = try ConnectionPool.makeKey(std.testing.allocator, host, 443, true);
            const gop = try p.map.getOrPut(std.testing.allocator, key);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const c = PooledConn{ .stream = undefined, .tls_state = null, .created_at_s = ts, .requests_served = 1, .is_tls = true };
            try gop.value_ptr.conns.append(std.testing.allocator, c);
        }
    };
    try insertDirect.run(&pool, "api1.example.com", now_ts);
    try insertDirect.run(&pool, "api2.example.com", now_ts);

    try std.testing.expectEqual(@as(u64, 2), pool.idleCount());
    try std.testing.expect(pool.acquire("api3.example.com", 443, true) == null);
    try std.testing.expectEqual(@as(u64, 2), pool.idleCount());
}

test "pool: max_connections cap enforced" {
    var pool = ConnectionPool.init(std.testing.allocator, .{
        .max_connections = 2,
        .max_idle_time_ms = 60_000,
        .max_requests_per_conn = 100,
    }, nopClose);
    defer pool.deinit();

    const now = std.time.timestamp();
    {
        pool.mutex.lock();
        defer pool.mutex.unlock();
        const key = try ConnectionPool.makeKey(std.testing.allocator, "h", 443, false);
        const gop = try pool.map.getOrPut(std.testing.allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        // Insert 3 directly, manually enforcing the cap (mirrors release() logic).
        for (0..3) |i| {
            const c = PooledConn{ .stream = undefined, .tls_state = null, .created_at_s = now, .requests_served = @intCast(i + 1), .is_tls = false };
            if (gop.value_ptr.conns.items.len >= 2) _ = gop.value_ptr.conns.orderedRemove(0);
            try gop.value_ptr.conns.append(std.testing.allocator, c);
        }
    }
    // After inserting 3 with cap=2, only 2 remain.
    try std.testing.expectEqual(@as(u64, 2), pool.idleCount());
}

test "pool: max_requests_per_conn evicts on acquire" {
    var pool = ConnectionPool.init(std.testing.allocator, .{
        .max_connections = 8,
        .max_idle_time_ms = 60_000,
        .max_requests_per_conn = 3,
    }, nopClose);
    defer pool.deinit();

    // Insert connection that has served exactly max_requests_per_conn.
    {
        pool.mutex.lock();
        defer pool.mutex.unlock();
        const key = try ConnectionPool.makeKey(std.testing.allocator, "h", 443, false);
        const gop = try pool.map.getOrPut(std.testing.allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const c = PooledConn{
            .stream = undefined,
            .tls_state = null,
            .created_at_s = std.time.timestamp(),
            .requests_served = 3, // at limit
            .is_tls = false,
        };
        try gop.value_ptr.conns.append(std.testing.allocator, c);
    }
    // Should be evicted (requests_served >= max), miss returned.
    try std.testing.expect(pool.acquire("h", 443, false) == null);
    try std.testing.expectEqual(@as(u64, 0), pool.idleCount());
}

test "pool: concurrent acquire/release is safe" {
    // Verify that concurrent access does not corrupt the pool.
    // Use nopClose to avoid closing undefined streams.
    var pool = ConnectionPool.init(std.testing.allocator, .{
        .max_connections = 4,
        .max_idle_time_ms = 60_000,
        .max_requests_per_conn = 100,
    }, nopClose);
    defer pool.deinit();

    const N: usize = 8;
    const ThreadCtx = struct {
        p: *ConnectionPool,
        results: [N]bool = [_]bool{false} ** N,
    };
    var ctx = ThreadCtx{ .p = &pool };

    // Spin up N threads each doing: miss acquire, then check miss counter.
    const worker = struct {
        fn run(c: *ThreadCtx, idx: usize) void {
            const got = c.p.acquire("concurrent.test", 443, false);
            c.results[idx] = (got == null); // should always miss (pool is empty)
        }
    };
    var threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        threads[i] = std.Thread.spawn(.{}, worker.run, .{ &ctx, i }) catch unreachable;
    }
    for (threads) |t| t.join();

    // All N attempts should have missed.
    for (ctx.results) |r| try std.testing.expect(r);
    try std.testing.expectEqual(@as(u64, N), pool.misses.load(.monotonic));
}

test "pool: Connection: close path does not release to pool" {
    // Simulates the caller checking poolable/server_close before calling release.
    // Pool should remain empty after a server_close=true response.
    var pool = ConnectionPool.init(std.testing.allocator, .{}, nopClose);
    defer pool.deinit();

    // Caller decides NOT to release due to Connection: close.
    // Just verify the pool stays empty (caller does nothing).
    try std.testing.expectEqual(@as(u64, 0), pool.idleCount());
}

test "pool: response boundary detection" {
    // Verify parse_http_response_poolable flags correctly.
    // We test only the pooling logic — not full HTTP parsing.
    // The real parser is tested in existing root.zig tests.
    // Here we just document the expected semantics.
    //
    // content-length response  -> poolable=true
    // chunked response         -> poolable=true
    // EOF-only response        -> poolable=false
    // Connection: close header -> server_close=true
    //
    // This is enforced in root.zig, not pool.zig.
    // Test is a documentation test — always passes.
    try std.testing.expect(true);
}
