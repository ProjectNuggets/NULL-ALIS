//! Secret vault API — two-phase mutation + in-memory confirmation tokens.
//!
//! Per plan.md §3 and plan-v02 §6, user secrets (OAuth tokens, API keys)
//! must never be readable post-save (metadata-only GET) and mutating
//! writes must require a short-lived single-use confirmation token
//! obtained via a prior `POST /prepare` call. This module owns the
//! token lifecycle + validation; the actual encrypted storage lives in
//! `zaki_state.{putSecret,deleteSecret,getSecret,listSecretKeys}`.
//!
//! Token lifecycle:
//!   1. Client calls `POST /api/v1/users/:id/secrets/:key/prepare` with
//!      body `{"action":"put"|"delete"}`. Server generates 32 random
//!      bytes, hex-encodes to 64 chars, stores `(user_id, key, action,
//!      issued_at)` keyed by the token, returns the token ONCE.
//!   2. Client calls `PUT /secrets/:key` or `DELETE /secrets/:key` with
//!      body including `{"confirmation_token":"..."}`. Server validates
//!      the token matches (user_id, key, action) and was issued within
//!      TTL. Once consumed, the token is removed — single-use.
//!   3. Expired tokens are lazily swept on each `consumeToken` call.
//!
//! Thread safety: all mutations go through `TokenStore.mutex`. The
//! store's owned strings are duplicated on insert and freed on
//! consume/expiry.
//!
//! Not yet wired into the gateway route dispatcher — that lands in
//! D8.3 along with S2.12 metadata handler.

const std = @import("std");

pub const DEFAULT_TTL_SECS: i64 = 300; // 5 minutes per plan.md §3
pub const TOKEN_HEX_LEN: usize = 64; // 32 raw bytes hex-encoded

pub const SecretAction = enum {
    put,
    delete,

    pub fn fromSlice(s: []const u8) ?SecretAction {
        if (std.mem.eql(u8, s, "put")) return .put;
        if (std.mem.eql(u8, s, "delete")) return .delete;
        return null;
    }

    pub fn toSlice(self: SecretAction) []const u8 {
        return switch (self) {
            .put => "put",
            .delete => "delete",
        };
    }
};

pub const TokenEntry = struct {
    user_id: []const u8,
    key: []const u8,
    action: SecretAction,
    issued_at_unix: i64,
};

pub const ConsumeResult = union(enum) {
    /// Token matched on (user_id, key, action) and was within TTL. The
    /// token has been removed from the store — subsequent calls with
    /// the same token return `.not_found`.
    ok,
    /// No token with this value exists. Either never issued, already
    /// consumed, or swept due to expiry.
    not_found,
    /// Token exists but was issued for a different user_id / key / or
    /// mismatched action (e.g. prepared `put`, caller tried `delete`).
    /// The token is NOT consumed — the legitimate holder may still
    /// spend it on the right call.
    mismatch,
    /// Token exists but issued_at + TTL < now. Removed on this call
    /// to keep the store bounded.
    expired,
};

pub const TokenStore = struct {
    mutex: std.Thread.Mutex = .{},
    tokens: std.StringHashMapUnmanaged(TokenEntry) = .{},
    allocator: std.mem.Allocator,
    ttl_secs: i64,

    pub fn init(allocator: std.mem.Allocator, ttl_secs: i64) TokenStore {
        return .{
            .allocator = allocator,
            .ttl_secs = @max(@as(i64, 1), ttl_secs),
        };
    }

    pub fn deinit(self: *TokenStore) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.tokens.iterator();
        while (it.next()) |e| {
            self.allocator.free(@constCast(e.key_ptr.*));
            self.allocator.free(@constCast(e.value_ptr.user_id));
            self.allocator.free(@constCast(e.value_ptr.key));
        }
        self.tokens.deinit(self.allocator);
    }

    /// Generate a fresh 32-byte random token, hex-encode to 64 chars,
    /// and store `(user_id, key, action, now)` under that token.
    /// Writes the 64-char hex token into `out_buf` (must be ≥ 64 bytes)
    /// and returns a slice pointing into `out_buf`.
    ///
    /// Memory ownership: the store duplicates `user_id` and `key`;
    /// caller may free their buffers after return.
    pub fn prepare(
        self: *TokenStore,
        user_id: []const u8,
        key: []const u8,
        action: SecretAction,
        out_buf: []u8,
    ) ![]const u8 {
        if (out_buf.len < TOKEN_HEX_LEN) return error.BufferTooSmall;

        var raw: [32]u8 = undefined;
        std.crypto.random.bytes(&raw);
        const hex_digits = "0123456789abcdef";
        for (raw, 0..) |b, i| {
            out_buf[i * 2] = hex_digits[b >> 4];
            out_buf[i * 2 + 1] = hex_digits[b & 0x0f];
        }
        const hex_slice = out_buf[0..TOKEN_HEX_LEN];

        self.mutex.lock();
        defer self.mutex.unlock();

        const owned_token = try self.allocator.dupe(u8, hex_slice);
        errdefer self.allocator.free(owned_token);
        const owned_user = try self.allocator.dupe(u8, user_id);
        errdefer self.allocator.free(owned_user);
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        try self.tokens.put(self.allocator, owned_token, .{
            .user_id = owned_user,
            .key = owned_key,
            .action = action,
            .issued_at_unix = std.time.timestamp(),
        });

        return hex_slice;
    }

    /// Attempt to consume a token. On `.ok` the entry is removed.
    /// On `.mismatch` the entry is preserved (legitimate caller may
    /// retry with correct user_id/key/action). On `.expired` the
    /// entry is removed. On `.not_found` there was no entry.
    pub fn consume(
        self: *TokenStore,
        token: []const u8,
        user_id: []const u8,
        key: []const u8,
        action: SecretAction,
    ) ConsumeResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.tokens.get(token) orelse return .not_found;

        const now = std.time.timestamp();
        if (entry.issued_at_unix + self.ttl_secs < now) {
            self.removeTokenLocked(token);
            return .expired;
        }

        if (!std.mem.eql(u8, entry.user_id, user_id) or
            !std.mem.eql(u8, entry.key, key) or
            entry.action != action)
        {
            return .mismatch;
        }

        self.removeTokenLocked(token);
        return .ok;
    }

    fn removeTokenLocked(self: *TokenStore, token: []const u8) void {
        if (self.tokens.fetchRemove(token)) |kv| {
            self.allocator.free(@constCast(kv.key));
            self.allocator.free(@constCast(kv.value.user_id));
            self.allocator.free(@constCast(kv.value.key));
        }
    }

    /// Count non-expired tokens. Exposed for test + diagnostics; not
    /// consulted by the API path.
    pub fn size(self: *TokenStore) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tokens.count();
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "SecretAction roundtrip via slice" {
    try std.testing.expectEqual(SecretAction.put, SecretAction.fromSlice("put").?);
    try std.testing.expectEqual(SecretAction.delete, SecretAction.fromSlice("delete").?);
    try std.testing.expect(SecretAction.fromSlice("PUT") == null); // case sensitive on purpose
    try std.testing.expect(SecretAction.fromSlice("unknown") == null);
    try std.testing.expectEqualStrings("put", SecretAction.put.toSlice());
    try std.testing.expectEqualStrings("delete", SecretAction.delete.toSlice());
}

test "TokenStore happy path — prepare then consume once" {
    var store = TokenStore.init(std.testing.allocator, 60);
    defer store.deinit();

    var buf: [TOKEN_HEX_LEN]u8 = undefined;
    const token = try store.prepare("42", "OPENAI_KEY", .put, &buf);
    try std.testing.expectEqual(TOKEN_HEX_LEN, token.len);
    try std.testing.expectEqual(@as(usize, 1), store.size());

    try std.testing.expectEqual(ConsumeResult.ok, store.consume(token, "42", "OPENAI_KEY", .put));
    try std.testing.expectEqual(@as(usize, 0), store.size());

    // Single-use: second consume returns not_found.
    try std.testing.expectEqual(ConsumeResult.not_found, store.consume(token, "42", "OPENAI_KEY", .put));
}

test "TokenStore consume rejects user mismatch + preserves entry for retry" {
    var store = TokenStore.init(std.testing.allocator, 60);
    defer store.deinit();

    var buf: [TOKEN_HEX_LEN]u8 = undefined;
    const token = try store.prepare("42", "OPENAI_KEY", .put, &buf);

    try std.testing.expectEqual(ConsumeResult.mismatch, store.consume(token, "99", "OPENAI_KEY", .put));
    try std.testing.expectEqual(@as(usize, 1), store.size()); // preserved for legitimate caller

    try std.testing.expectEqual(ConsumeResult.ok, store.consume(token, "42", "OPENAI_KEY", .put));
}

test "TokenStore consume rejects key mismatch" {
    var store = TokenStore.init(std.testing.allocator, 60);
    defer store.deinit();

    var buf: [TOKEN_HEX_LEN]u8 = undefined;
    const token = try store.prepare("42", "OPENAI_KEY", .put, &buf);

    try std.testing.expectEqual(ConsumeResult.mismatch, store.consume(token, "42", "GITHUB_TOKEN", .put));
    try std.testing.expectEqual(@as(usize, 1), store.size());
}

test "TokenStore consume rejects action mismatch (put token, delete call)" {
    var store = TokenStore.init(std.testing.allocator, 60);
    defer store.deinit();

    var buf: [TOKEN_HEX_LEN]u8 = undefined;
    const token = try store.prepare("42", "OPENAI_KEY", .put, &buf);

    try std.testing.expectEqual(ConsumeResult.mismatch, store.consume(token, "42", "OPENAI_KEY", .delete));
    try std.testing.expectEqual(@as(usize, 1), store.size());
}

test "TokenStore expires tokens past TTL" {
    var store = TokenStore.init(std.testing.allocator, 1);
    defer store.deinit();

    var buf: [TOKEN_HEX_LEN]u8 = undefined;
    const token = try store.prepare("42", "OPENAI_KEY", .put, &buf);
    // Force the entry's issued_at into the past.
    store.mutex.lock();
    if (store.tokens.getPtr(token)) |entry| {
        entry.issued_at_unix = std.time.timestamp() - 10;
    }
    store.mutex.unlock();

    try std.testing.expectEqual(ConsumeResult.expired, store.consume(token, "42", "OPENAI_KEY", .put));
    try std.testing.expectEqual(@as(usize, 0), store.size());
}

test "TokenStore unknown token returns not_found" {
    var store = TokenStore.init(std.testing.allocator, 60);
    defer store.deinit();

    try std.testing.expectEqual(
        ConsumeResult.not_found,
        store.consume("feedfacecafebabedeadbeef00000000000000000000000000000000000000ff", "42", "K", .put),
    );
}

test "TokenStore prepare fails cleanly when buffer is too small" {
    var store = TokenStore.init(std.testing.allocator, 60);
    defer store.deinit();

    var small: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, store.prepare("42", "K", .put, &small));
    try std.testing.expectEqual(@as(usize, 0), store.size());
}

test "TokenStore TTL secs clamps to 1 minimum" {
    var store = TokenStore.init(std.testing.allocator, 0);
    defer store.deinit();
    try std.testing.expectEqual(@as(i64, 1), store.ttl_secs);
}
