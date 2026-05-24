//! Wave 2C — canvas/artifacts backend: thin convenience facade.
//!
//! The bulk of the storage logic lives on `zaki_state.Manager` (see the
//! ManagerImpl method block tagged "Wave 2C: artifacts CRUD"). This
//! module exists to centralize:
//!   * the share-code generator (URL-safe random alphabet)
//!   * the default share window (7 days = 168 h)
//!
//! Keeping it small + dependency-free means the tools + gateway both
//! get one obvious import point without re-implementing the share-code
//! shape in two places.

const std = @import("std");

/// Default expiry for a freshly minted share, in hours. Mirror of the
/// spec default (168h = 7 days). Endpoints accept an override via the
/// `expires_in_hours` body field.
pub const DEFAULT_SHARE_EXPIRY_HOURS: i64 = 168;

/// URL-safe alphabet for share codes. No look-alikes (no I/l/1, no
/// O/0) to keep typed/spoken sharing forgiving. 22 chars from this
/// 58-symbol alphabet ≈ 128 bits of entropy — comfortably resistant
/// to enumeration.
const SHARE_ALPHABET = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
pub const SHARE_CODE_LEN: usize = 22;

/// Generate a fresh URL-safe share code. Caller owns the returned slice.
/// Cryptographic randomness; collisions across the global namespace are
/// astronomically unlikely at v1 scale (the UNIQUE constraint on the
/// column would still catch the impossible case).
pub fn generateShareCode(allocator: std.mem.Allocator) ![]u8 {
    var raw: [SHARE_CODE_LEN]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const out = try allocator.alloc(u8, SHARE_CODE_LEN);
    for (raw, 0..) |b, i| {
        out[i] = SHARE_ALPHABET[@as(usize, b) % SHARE_ALPHABET.len];
    }
    return out;
}

/// Validate the shape of a candidate share code. Used by the public
/// share endpoint to reject obviously-malformed input before hitting
/// the DB (cheap defense against URL fuzzing).
pub fn isValidShareCode(code: []const u8) bool {
    if (code.len < 8 or code.len > 64) return false;
    for (code) |b| {
        const ok = (b >= 'a' and b <= 'z') or
            (b >= 'A' and b <= 'Z') or
            (b >= '0' and b <= '9');
        if (!ok) return false;
    }
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────

test "generateShareCode produces alphabet-only bytes of correct length" {
    const a = std.testing.allocator;
    const code = try generateShareCode(a);
    defer a.free(code);
    try std.testing.expectEqual(SHARE_CODE_LEN, code.len);
    for (code) |b| {
        try std.testing.expect(std.mem.indexOfScalar(u8, SHARE_ALPHABET, b) != null);
    }
}

test "two generated share codes differ (probabilistic — collision odds ~2^-128)" {
    const a = std.testing.allocator;
    const c1 = try generateShareCode(a);
    defer a.free(c1);
    const c2 = try generateShareCode(a);
    defer a.free(c2);
    try std.testing.expect(!std.mem.eql(u8, c1, c2));
}

test "isValidShareCode rejects empty and too-long inputs" {
    try std.testing.expect(!isValidShareCode(""));
    try std.testing.expect(!isValidShareCode("a"));
    try std.testing.expect(!isValidShareCode("a" ** 65));
}

test "isValidShareCode rejects non-alphanumeric chars" {
    try std.testing.expect(!isValidShareCode("abc/def123"));
    try std.testing.expect(!isValidShareCode("abc..def"));
    try std.testing.expect(!isValidShareCode("abc def!"));
}

test "isValidShareCode accepts generated codes" {
    const a = std.testing.allocator;
    const code = try generateShareCode(a);
    defer a.free(code);
    try std.testing.expect(isValidShareCode(code));
}
