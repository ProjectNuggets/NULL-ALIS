//! D1.14 — generalized tool-result cache.
//!
//! Extracts the proven `ListCache` pattern from `src/tools/composio.zig`
//! (the use-after-free was fixed in PR #32 with a long-lived
//! `storage_allocator`) into a reusable module that ANY tool with a
//! deterministic + expensive call shape can opt into via
//! `ToolMetadata.flags.cacheable + cache_ttl_secs`.
//!
//! **Lifetime model — same as the composio fix:**
//!   * `storage_allocator` is module-owned and long-lived. Defaults to
//!     `std.heap.page_allocator` so the cache is safe before any
//!     explicit install — no daemon-side wiring required.
//!   * Per-turn allocators are NEVER stored. `put` copies inputs into
//!     `storage_allocator`; `get` copies the cached value into the
//!     caller's allocator so the returned slice rides the turn
//!     lifetime.
//!
//! **Key shape:** `tool_name + "\x00" + args_json_hash_hex`. Args are
//! hashed via Wyhash for collision resistance + bounded key length
//! (the raw args JSON could be arbitrarily large; the hash is 16 hex
//! chars).
//!
//! **Eviction:** simple "earliest expiry wins" — the entry with the
//! oldest `expires_at_ms` is evicted when all 128 slots are full.
//! Bounded slot count keeps memory usage predictable; 128 is enough
//! for ~16 unique queries per tool across 8 active tools, far more
//! than typical session activity.

const std = @import("std");

pub const SLOTS: usize = 128;

const Entry = struct {
    key: ?[]u8 = null,
    value: ?[]u8 = null,
    success: bool = false,
    expires_at_ms: i64 = 0,
};

/// Result handed to the caller by `get`. The output slice is
/// allocated in the caller's allocator and transfers ownership —
/// caller must free.
pub const Hit = struct {
    output: []const u8,
    success: bool,
};

pub const ToolResultCache = struct {
    mutex: std.Thread.Mutex = .{},
    entries: [SLOTS]Entry = [_]Entry{.{}} ** SLOTS,
    /// Long-lived backing allocator for every stored key/value. Must
    /// outlive every per-turn allocator that calls `put` or `get`.
    /// Defaulted to page_allocator so production paths never need an
    /// init step. Tests swap via `setStorageAllocatorForTest`.
    storage_allocator: std.mem.Allocator = std.heap.page_allocator,

    /// Build the composite cache key for `(tool_name, args_json)`.
    /// Caller owns the returned slice. Fixed-length (tool_name + null
    /// separator + 16 hex chars of Wyhash-64).
    pub fn buildKey(allocator: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) ![]u8 {
        const hash = std.hash.Wyhash.hash(0, args_json);
        return std.fmt.allocPrint(allocator, "{s}\x00{x:0>16}", .{ tool_name, hash });
    }

    /// Return a fresh copy of the cached output for `(tool_name,
    /// args_json)`, or null on miss/expiry. Caller owns the returned
    /// slice and must free with `caller_allocator`.
    pub fn get(self: *ToolResultCache, caller_allocator: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) ?Hit {
        const key = buildKey(caller_allocator, tool_name, args_json) catch return null;
        defer caller_allocator.free(key);

        self.mutex.lock();
        defer self.mutex.unlock();
        const now = std.time.milliTimestamp();
        for (&self.entries) |*entry| {
            const ek = entry.key orelse continue;
            if (!std.mem.eql(u8, ek, key)) continue;
            if (now > entry.expires_at_ms) return null;
            const v = entry.value orelse return null;
            const out = caller_allocator.dupe(u8, v) catch return null;
            return Hit{ .output = out, .success = entry.success };
        }
        return null;
    }

    /// Store `output` for `(tool_name, args_json)` with `ttl_secs`
    /// time-to-live. Both inputs are copied into `self.storage_allocator`;
    /// the caller may free its own copies as soon as this returns.
    /// On collision the existing entry is updated; otherwise the
    /// first empty slot is filled, or the entry with the earliest
    /// expiry is evicted.
    pub fn put(self: *ToolResultCache, tool_name: []const u8, args_json: []const u8, output: []const u8, success: bool, ttl_secs: u32) !void {
        const a = self.storage_allocator;
        const key = try buildKey(a, tool_name, args_json);
        // On any failure beyond this point, free the key.
        errdefer a.free(key);

        self.mutex.lock();
        defer self.mutex.unlock();
        const now = std.time.milliTimestamp();
        const new_expiry = now + (@as(i64, @intCast(ttl_secs)) * 1000);

        // First pass: update existing entry or fill an empty slot.
        for (&self.entries) |*entry| {
            if (entry.key) |ek| {
                if (std.mem.eql(u8, ek, key)) {
                    if (entry.value) |v| a.free(v);
                    entry.value = try a.dupe(u8, output);
                    entry.success = success;
                    entry.expires_at_ms = new_expiry;
                    a.free(key); // existing entry's key wins; ours is redundant
                    return;
                }
            } else {
                entry.key = key;
                entry.value = a.dupe(u8, output) catch |err| {
                    a.free(key);
                    entry.key = null;
                    return err;
                };
                entry.success = success;
                entry.expires_at_ms = new_expiry;
                return;
            }
        }

        // All slots full — evict the entry with the earliest expiry.
        var victim_idx: usize = 0;
        var victim_expiry: i64 = self.entries[0].expires_at_ms;
        for (self.entries, 0..) |entry, i| {
            if (entry.expires_at_ms < victim_expiry) {
                victim_expiry = entry.expires_at_ms;
                victim_idx = i;
            }
        }
        const victim = &self.entries[victim_idx];
        if (victim.key) |k| a.free(k);
        if (victim.value) |v| a.free(v);
        victim.key = key;
        victim.value = a.dupe(u8, output) catch |err| {
            a.free(key);
            victim.key = null;
            return err;
        };
        victim.success = success;
        victim.expires_at_ms = new_expiry;
    }

    /// Reset helper — clears all entries and frees their backing
    /// allocations through `self.storage_allocator`. Test-only.
    pub fn resetForTest(self: *ToolResultCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const a = self.storage_allocator;
        for (&self.entries) |*entry| {
            if (entry.key) |k| a.free(k);
            if (entry.value) |v| a.free(v);
            entry.key = null;
            entry.value = null;
            entry.expires_at_ms = 0;
            entry.success = false;
        }
    }

    /// Test-only: install a different storage allocator (typically
    /// `std.testing.allocator`) so the leak detector can verify the
    /// cache frees everything on `resetForTest`. Caller must reset
    /// the cache before swapping allocators — entries allocated
    /// through the previous allocator cannot be freed through the new
    /// one.
    pub fn setStorageAllocatorForTest(self: *ToolResultCache, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.storage_allocator = allocator;
    }
};

/// Process-global cache instance. Tools and dispatchers share this
/// single cache to maximize hit rate across sessions / channels.
pub var global: ToolResultCache = .{};

test "ToolResultCache put + get roundtrip" {
    global.resetForTest();
    global.setStorageAllocatorForTest(std.testing.allocator);
    defer {
        global.resetForTest();
        global.setStorageAllocatorForTest(std.heap.page_allocator);
    }

    try global.put("web_search", "{\"q\":\"zig\"}", "result-1", true, 60);
    const hit = global.get(std.testing.allocator, "web_search", "{\"q\":\"zig\"}") orelse return error.CacheMissUnexpected;
    defer std.testing.allocator.free(hit.output);
    try std.testing.expectEqualStrings("result-1", hit.output);
    try std.testing.expect(hit.success);
}

test "ToolResultCache miss on different args" {
    global.resetForTest();
    global.setStorageAllocatorForTest(std.testing.allocator);
    defer {
        global.resetForTest();
        global.setStorageAllocatorForTest(std.heap.page_allocator);
    }

    try global.put("web_search", "{\"q\":\"zig\"}", "result-1", true, 60);
    try std.testing.expect(global.get(std.testing.allocator, "web_search", "{\"q\":\"rust\"}") == null);
}

test "ToolResultCache miss on different tool name" {
    global.resetForTest();
    global.setStorageAllocatorForTest(std.testing.allocator);
    defer {
        global.resetForTest();
        global.setStorageAllocatorForTest(std.heap.page_allocator);
    }

    try global.put("web_search", "{\"q\":\"zig\"}", "result-1", true, 60);
    try std.testing.expect(global.get(std.testing.allocator, "memory_recall", "{\"q\":\"zig\"}") == null);
}

test "ToolResultCache survives caller allocator death (D1.14 lifetime contract)" {
    // Same regression-class as PR #32's composio fix. A short-lived
    // arena puts into the cache; arena dies; later get must still work.
    global.resetForTest();
    global.setStorageAllocatorForTest(std.testing.allocator);
    defer {
        global.resetForTest();
        global.setStorageAllocatorForTest(std.heap.page_allocator);
    }

    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const tool_name = try arena_alloc.dupe(u8, "web_search");
        const args = try arena_alloc.dupe(u8, "{\"q\":\"zig\"}");
        const output = try arena_alloc.dupe(u8, "from-arena-output");
        try global.put(tool_name, args, output, true, 60);
        // arena.deinit() frees tool_name/args/output. Cache must
        // have its own copies.
    }

    const hit = global.get(std.testing.allocator, "web_search", "{\"q\":\"zig\"}") orelse return error.CacheMissUnexpected;
    defer std.testing.allocator.free(hit.output);
    try std.testing.expectEqualStrings("from-arena-output", hit.output);
}

test "ToolResultCache update existing key replaces value" {
    global.resetForTest();
    global.setStorageAllocatorForTest(std.testing.allocator);
    defer {
        global.resetForTest();
        global.setStorageAllocatorForTest(std.heap.page_allocator);
    }

    try global.put("web_search", "{\"q\":\"zig\"}", "v1", true, 60);
    try global.put("web_search", "{\"q\":\"zig\"}", "v2", true, 60);
    const hit = global.get(std.testing.allocator, "web_search", "{\"q\":\"zig\"}") orelse return error.CacheMissUnexpected;
    defer std.testing.allocator.free(hit.output);
    try std.testing.expectEqualStrings("v2", hit.output);
}

test "ToolResultCache expired entry returns null" {
    global.resetForTest();
    global.setStorageAllocatorForTest(std.testing.allocator);
    defer {
        global.resetForTest();
        global.setStorageAllocatorForTest(std.heap.page_allocator);
    }

    // ttl_secs=0 means "expires this millisecond" — sleep 5ms to
    // ensure now > expires_at_ms when we check.
    try global.put("web_search", "{\"q\":\"zig\"}", "result-1", true, 0);
    std.Thread.sleep(5 * std.time.ns_per_ms);
    try std.testing.expect(global.get(std.testing.allocator, "web_search", "{\"q\":\"zig\"}") == null);
}
