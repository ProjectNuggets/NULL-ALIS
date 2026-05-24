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

/// Hard ceiling on share lifetime, in hours. Matches the trace share cap
/// (`SHARE_MAX_HOURS = 720` in gateway.zig) so the commercial v1 contract
/// is identical on both surfaces: callers cannot mint a share that
/// outlives 30 days. Wave 2 review HIGH#2 — prior to this constant the
/// artifact share-create endpoint accepted `24 * 365 = 8760h` (365 days),
/// contradicting the trace share's published 720h ceiling and the
/// commit-message claim that the two limits match.
pub const SHARE_MAX_EXPIRY_HOURS: i64 = 720;

/// URL-safe alphabet for share codes. Crockford-ish: lowercase + digits
/// only, no look-alikes (no `i`, `l`, `o`, `0`, `1`). 31 symbols. This
/// MATCHES the trace-share alphabet at `gateway.zig` (TRACE_SHARE_ALPHABET)
/// so both surfaces produce visually-consistent codes — Wave 2 review
/// MEDIUM#5 (the artifact share previously used a 57-char mixed-case
/// alphabet which violated the commit-message claim that the two surfaces
/// match + made FE/SMS/voice handling inconsistent).
///
/// 16 chars from this 31-symbol alphabet ≈ 78 bits of entropy —
/// well above the ~32 bits an enumeration attack realistically scans
/// before TLS rate-limits the attacker. The trace surface uses the same
/// length for symmetry.
const SHARE_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";
pub const SHARE_CODE_LEN: usize = 16;

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
