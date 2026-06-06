//! Token validation for the extension WebSocket endpoint.
//!
//! META CRITICAL #2 (2026-05-25) — per-user tokens.
//!
//! Prior model: a shared `internal_service_tokens` list authenticated
//! every extension, and the frame's `user_id` field was trusted. Any
//! holder of any token could authenticate as any user_id by setting
//! the frame field — cross-tenant impersonation. A user who
//! exfiltrated THEIR OWN token from their own `chrome.storage.local`
//! could connect as Alice and receive every `extension_*` command the
//! agent dispatched on Alice's behalf.
//!
//! New model: operators provision a UNIQUE token per user. Each token
//! maps to exactly one user_id. The auth frame's `user_id` field is
//! IGNORED — the gateway returns the mapped `user_id` from the entry
//! that matched the inbound token.
//!
//! For single-tenant deployments (one user, one extension) the
//! operator still configures one entry with that user's id; the API
//! is the same. There is no path that falls back to the legacy
//! shared-token model; if `entries` is empty, every auth attempt
//! rejects with `invalid_token` and the operator sees an explicit
//! warning at gateway boot.
//!
//! Side-channel: the validator iterates ALL entries and performs a
//! constant-time compare on each. This avoids leaking via timing
//! which token (or even WHETHER any token) matched. An attacker
//! probing the token-space sees one indistinguishable rejection per
//! attempt regardless of how close they got.

const std = @import("std");

/// One operator-provisioned token + the user_id it authenticates as.
/// Mirrors `config_types.ExtensionTokenEntry` — kept here as a
/// distinct type so the auth module is testable without dragging the
/// gateway config tree into the test binary.
pub const TokenEntry = struct {
    token: []const u8,
    user_id: []const u8,
    /// Plan-8 (2026-06-06) — token rotation window. When non-null, this
    /// PREVIOUS token is ALSO accepted for `user_id` alongside the
    /// current `token`. Operators rotate without a hard cutover: set
    /// `token` to the new secret + `token_previous` to the old one,
    /// push the new token to the extension, then clear
    /// `token_previous` (set null / drop the config field) once every
    /// client has migrated. After it's cleared, only `token` is
    /// accepted. Empty string is treated as "not set" so a config that
    /// emits `""` doesn't accidentally admit a blank token.
    token_previous: ?[]const u8 = null,
};

pub const AuthDecision = struct {
    ok: bool,
    /// On success, the SERVER-derived user_id (from the matching
    /// `TokenEntry`). On failure, null. NEVER reflects the inbound
    /// auth frame's `user_id` field.
    user_id: ?[]const u8 = null,
    /// On failure, a short machine-readable reason
    /// (`"invalid_token"`, `"auth_frame_too_large"`,
    /// `"malformed_auth_frame"`, `"bad_nonce"`). Lands in the
    /// `auth_ack{ok:false, error}` envelope verbatim — keep it
    /// alphanumeric-and-underscores so popup-rendering stays simple.
    reason: ?[]const u8 = null,
};

/// Plan-8 (2026-06-06) — per-connection anti-replay nonce.
///
/// Plan 7 productionized the extension lane but explicitly DECLINED
/// HMAC request-signing as theater. The real gap it identified: a
/// captured `auth` frame could be REPLAYED verbatim on a fresh
/// connection because nothing in the handshake was connection-unique.
/// (The token is a long-lived static secret; the WS `Sec-WebSocket-Key`
/// is client-chosen and not bound to app-layer auth.)
///
/// Fix: the SERVER mints a fresh CSPRNG nonce per connection, sends it
/// to the client as a `challenge` frame BEFORE waiting for auth, and
/// the client must echo it back in its `auth` frame. The server
/// constant-time compares the echoed nonce against the one it issued
/// for THIS connection. Because the nonce is generated freshly per
/// connection and the validator runs exactly once per connection, the
/// nonce is single-use and connection-bound by construction — a
/// replayed `auth` frame carries a STALE nonce that will never match
/// the new connection's freshly-minted challenge.
///
/// Nonce shape: NONCE_RAW_BYTES of CSPRNG output, lower-hex encoded
/// (so NONCE_HEX_LEN = 2 * NONCE_RAW_BYTES chars). Hex keeps it
/// JSON-safe and trivially constant-time comparable.
pub const NONCE_RAW_BYTES: usize = 32;
pub const NONCE_HEX_LEN: usize = NONCE_RAW_BYTES * 2;

/// Generate a fresh per-connection nonce into `out` (lower-hex). Uses
/// `std.crypto.random` — a CSPRNG seeded by the OS entropy source. The
/// caller owns `out`; it must be exactly `NONCE_HEX_LEN` bytes.
pub fn generateNonceHex(out: *[NONCE_HEX_LEN]u8) void {
    var raw: [NONCE_RAW_BYTES]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    @memcpy(out, &hex);
}

/// Constant-time comparison for the echoed nonce. Wraps
/// `std.crypto.timing_safe.eql` over fixed-size arrays so the compare
/// is length-independent (the nonce is always NONCE_HEX_LEN; a wrong
/// length fails the up-front check, which is not secret because the
/// expected length is a public protocol constant). Exposed so the
/// validator and tests share one implementation.
fn constantTimeNonceEql(expected: []const u8, got: []const u8) bool {
    if (expected.len != NONCE_HEX_LEN or got.len != NONCE_HEX_LEN) return false;
    const Vec = [NONCE_HEX_LEN]u8;
    var e: Vec = undefined;
    var g: Vec = undefined;
    @memcpy(&e, expected);
    @memcpy(&g, got);
    return std.crypto.timing_safe.eql(Vec, e, g);
}

/// META HIGH #2 (2026-05-25) — explicit size cap on auth-frame JSON,
/// surfaced as a distinct rejection reason so operators can
/// distinguish "someone hammering us with junk" from "someone has a
/// malformed extension build."
///
/// 4 KB is plenty for the contract's three-field auth frame (token +
/// extension_version + optional user_id). A real JWT can push past
/// this; v2 will lift it when JWTs become the token shape. For now,
/// over-4KB → distinct reason instead of being conflated with
/// "malformed JSON" inside the parser's OutOfMemory return.
pub const MAX_AUTH_FRAME_BYTES: usize = 4 * 1024;

/// ME-02 (v1.14.23, 2026-05-25) — pad target for the constant-time
/// token compare. Every `constantTimeEql` invocation runs exactly this
/// many byte-compares regardless of input lengths, eliminating the
/// length-bucket timing channel that the pre-fix early-exit-on-length
/// branch opened.
///
/// Inbound tokens longer than this are rejected up-front (after a
/// fixed-cost pad-and-compare so the length check itself is not the
/// signal). 256 bytes covers operator-chosen strings AND most
/// short-lived JWT shapes; v2 may raise it when long bearer tokens
/// land.
///
/// Tradeoff: ~256 extra byte-compares per auth attempt is sub-µs on
/// modern hardware; the timing channel it closes is worth that cost
/// many times over.
pub const MAX_TOKEN_LEN: usize = 256;

/// Stateless validator: given an auth frame JSON payload, decides
/// whether to admit the connection AND which user_id to register
/// under.
pub const AuthValidator = struct {
    /// Configured (token, user_id) entries. Empty list ⇒ reject
    /// everything (closed-by-default — operator must configure at
    /// least one entry to admit any extension).
    entries: []const TokenEntry,

    /// Plan-8 — the per-connection nonce the server issued in its
    /// `challenge` frame. When non-null, the inbound `auth` frame MUST
    /// echo this value verbatim (constant-time compared) IN ADDITION to
    /// carrying a valid token. When null, no nonce is required (kept so
    /// the validator's pure-token tests stay valid; production always
    /// sets it).
    expected_nonce: ?[]const u8 = null,

    pub fn validate(self: AuthValidator, auth_frame_json: []const u8) AuthDecision {
        // META HIGH #2: distinguish "frame is huge garbage" from "frame
        // is small but malformed." Operators chasing a DoS see the
        // size-blocked reason; operators chasing a stale extension
        // build see the parser reason.
        if (auth_frame_json.len > MAX_AUTH_FRAME_BYTES) {
            return .{ .ok = false, .reason = "auth_frame_too_large" };
        }

        // Parse with a stack-bounded arena so the validator can be
        // called from any thread without involving a long-lived
        // allocator. 8 KB FBA — strictly larger than the
        // MAX_AUTH_FRAME_BYTES cap above, with headroom for the
        // parser's own internal book-keeping.
        var buf: [8 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            fba.allocator(),
            auth_frame_json,
            .{},
        ) catch return .{ .ok = false, .reason = "malformed_auth_frame" };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return .{ .ok = false, .reason = "malformed_auth_frame" },
        };

        const type_val = obj.get("type") orelse return .{ .ok = false, .reason = "malformed_auth_frame" };
        const type_str = switch (type_val) {
            .string => |s| s,
            else => return .{ .ok = false, .reason = "malformed_auth_frame" },
        };
        if (!std.mem.eql(u8, type_str, "auth")) {
            return .{ .ok = false, .reason = "malformed_auth_frame" };
        }

        const token_val = obj.get("token") orelse return .{ .ok = false, .reason = "invalid_token" };
        const token_str = switch (token_val) {
            .string => |s| s,
            else => return .{ .ok = false, .reason = "invalid_token" },
        };

        // Iterate ALL entries with a constant-time compare per entry.
        // Do NOT short-circuit on first match: short-circuiting would
        // let an attacker measure which token slot matched (the loop
        // body's branch latency leaks). Iterate all, accumulate the
        // matching index, ignore the inbound user_id.
        var matched_idx: ?usize = null;
        for (self.entries, 0..) |entry, i| {
            // ME-02 (v1.14.23): constantTimeEql now pads to
            // MAX_TOKEN_LEN regardless of input lengths, so the
            // length-bucket timing channel is closed. Length-mismatch
            // becomes a final-mask bit OR'd into the result instead
            // of a branchy early-exit.
            //
            // Plan-8 — token rotation window: a connection is admitted
            // for this entry if it presents EITHER the current token OR
            // the (optional, non-empty) previous token. Both compares
            // run every iteration (no short-circuit `or`) so the
            // accept-current-vs-accept-previous decision doesn't open a
            // timing channel. Once `token_previous` is cleared in
            // config, only the current token matches.
            const cur_match = constantTimeEql(entry.token, token_str);
            const prev_match = if (entry.token_previous) |prev| blk: {
                if (prev.len == 0) break :blk false; // "" ⇒ not set
                break :blk constantTimeEql(prev, token_str);
            } else false;
            if (cur_match or prev_match) {
                // Don't break — keep iterating so an attacker can't
                // time-attack "which slot did I hit." We still
                // capture the matched index.
                if (matched_idx == null) matched_idx = i;
            }
        }

        if (matched_idx) |idx| {
            // Plan-8 — additive nonce check. The token matched; now the
            // echoed nonce must ALSO match the one the server issued for
            // this connection. A replayed `auth` frame (captured from a
            // prior connection) carries a stale nonce and is rejected
            // here even though its token is valid.
            if (self.expected_nonce) |expected| {
                const nonce_val = obj.get("nonce") orelse
                    return .{ .ok = false, .reason = "bad_nonce" };
                const nonce_str = switch (nonce_val) {
                    .string => |s| s,
                    else => return .{ .ok = false, .reason = "bad_nonce" },
                };
                if (!constantTimeNonceEql(expected, nonce_str)) {
                    return .{ .ok = false, .reason = "bad_nonce" };
                }
            }
            // SERVER-derived user_id. The inbound frame's user_id
            // field is ignored entirely — that's the whole point of
            // CRIT #2's fix.
            return .{ .ok = true, .user_id = self.entries[idx].user_id };
        }

        // Don't reveal whether the token was unknown vs malformed-
        // shape; the user sees one indistinguishable rejection.
        return .{ .ok = false, .reason = "invalid_token" };
    }
};

/// Constant-time token comparison.
///
/// ME-02 (v1.14.23, 2026-05-25): closes the length-bucket timing
/// channel that the pre-fix early-exit-on-length opened. The pre-fix
/// implementation let an attacker measuring total `validate` latency
/// guess the operator-chosen token length: a 16-byte guess against a
/// 64-byte configured token returned almost instantly (length check
/// failed), while a 64-byte guess ran the byte loop.
///
/// Post-fix: every call performs EXACTLY `MAX_TOKEN_LEN` byte
/// XOR/ORs. Inputs are copied into fixed-size zero-padded buffers,
/// so loop iteration count, branch shape, and memory-access pattern
/// are identical regardless of the actual input lengths. The
/// `a.len == b.len` bit is folded into the result via a final mask
/// AFTER the loop — never short-circuits.
///
/// Inputs longer than MAX_TOKEN_LEN cannot fit in the pad buffer; we
/// return false unconditionally (their length is already attacker-
/// chosen, so leaking "too long" doesn't tell the attacker anything
/// about the configured token).
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len > MAX_TOKEN_LEN or b.len > MAX_TOKEN_LEN) return false;

    var pad_a: [MAX_TOKEN_LEN]u8 = @splat(0);
    var pad_b: [MAX_TOKEN_LEN]u8 = @splat(0);
    @memcpy(pad_a[0..a.len], a);
    @memcpy(pad_b[0..b.len], b);

    // Always run MAX_TOKEN_LEN iterations — no early exit, no
    // length-dependent branching inside the loop body.
    var diff: u8 = 0;
    var i: usize = 0;
    while (i < MAX_TOKEN_LEN) : (i += 1) {
        diff |= pad_a[i] ^ pad_b[i];
    }

    // Fold the length-equal bit in AFTER the loop. If lengths differ,
    // `len_mask = 1` and `result |= 1` forces a non-zero `result` even
    // when the padded buffers happen to byte-equal (which they can
    // when one input is a prefix of the other, e.g. "abc" vs "abc\0").
    const len_mask: u8 = if (a.len == b.len) 0 else 1;
    return (diff | len_mask) == 0;
}

// ── Tests ────────────────────────────────────────────────────────────

test "AuthValidator accepts valid token; returns MAPPED user_id (ignores frame's)" {
    const entries = [_]TokenEntry{
        .{ .token = "tok-alice", .user_id = "alice" },
        .{ .token = "tok-bob", .user_id = "bob" },
    };
    const v = AuthValidator{ .entries = &entries };
    const auth =
        \\{"type":"auth","token":"tok-alice","user_id":"i-claim-to-be-bob","extension_version":"0.1.0"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(d.ok);
    // The MAPPED user_id is alice — the frame's "i-claim-to-be-bob"
    // is ignored.
    try std.testing.expectEqualStrings("alice", d.user_id.?);
    try std.testing.expect(d.reason == null);
}

test "META CRIT #2: frame's user_id is IGNORED even when missing" {
    const entries = [_]TokenEntry{
        .{ .token = "tok-alice", .user_id = "alice" },
    };
    const v = AuthValidator{ .entries = &entries };
    // No user_id field at all — under the new model, that's fine
    // because the gateway derives it from the token entry.
    const auth =
        \\{"type":"auth","token":"tok-alice","extension_version":"0.1.0"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(d.ok);
    try std.testing.expectEqualStrings("alice", d.user_id.?);
}

test "META CRIT #2: cross-tenant impersonation is impossible" {
    // The exfiltrated-token attack: a holder of tok-alice tries to
    // pose as bob by setting the frame's user_id="bob". Pre-fix this
    // returned ok=true with user_id="bob". Post-fix: ok=true with
    // user_id="alice" (the MAPPED value).
    const entries = [_]TokenEntry{
        .{ .token = "tok-alice", .user_id = "alice" },
        .{ .token = "tok-bob", .user_id = "bob" },
    };
    const v = AuthValidator{ .entries = &entries };
    const auth =
        \\{"type":"auth","token":"tok-alice","user_id":"bob"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(d.ok);
    try std.testing.expectEqualStrings("alice", d.user_id.?);
    try std.testing.expect(!std.mem.eql(u8, d.user_id.?, "bob"));
}

test "AuthValidator rejects wrong token" {
    const entries = [_]TokenEntry{
        .{ .token = "tok-alice", .user_id = "alice" },
    };
    const v = AuthValidator{ .entries = &entries };
    const auth =
        \\{"type":"auth","token":"bogus","user_id":"alice","extension_version":"0.1.0"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("invalid_token", d.reason.?);
    try std.testing.expect(d.user_id == null);
}

test "AuthValidator rejects wrong frame type" {
    const entries = [_]TokenEntry{
        .{ .token = "tok-alice", .user_id = "alice" },
    };
    const v = AuthValidator{ .entries = &entries };
    const auth =
        \\{"type":"ping","token":"tok-alice","user_id":"alice"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("malformed_auth_frame", d.reason.?);
}

test "AuthValidator rejects malformed JSON" {
    const entries = [_]TokenEntry{
        .{ .token = "tok-alice", .user_id = "alice" },
    };
    const v = AuthValidator{ .entries = &entries };
    const d = v.validate("not json at all");
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("malformed_auth_frame", d.reason.?);
}

test "META CRIT #2: empty entries list → every token is invalid" {
    const v = AuthValidator{ .entries = &.{} };
    const auth =
        \\{"type":"auth","token":"anything","user_id":"alice"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("invalid_token", d.reason.?);
    try std.testing.expect(d.user_id == null);
}

test "AuthValidator matches the right user_id among several entries" {
    const entries = [_]TokenEntry{
        .{ .token = "alpha", .user_id = "u1" },
        .{ .token = "beta", .user_id = "u2" },
        .{ .token = "gamma", .user_id = "u3" },
    };
    const v = AuthValidator{ .entries = &entries };
    const auth =
        \\{"type":"auth","token":"beta","user_id":"i-claim-to-be-anyone"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(d.ok);
    try std.testing.expectEqualStrings("u2", d.user_id.?);
}

test "META HIGH #2: oversized auth frame returns auth_frame_too_large" {
    const entries = [_]TokenEntry{
        .{ .token = "tok", .user_id = "alice" },
    };
    const v = AuthValidator{ .entries = &entries };

    // Build a frame larger than MAX_AUTH_FRAME_BYTES.
    var buf: [MAX_AUTH_FRAME_BYTES + 100]u8 = undefined;
    @memset(&buf, 'x');
    const d = v.validate(&buf);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("auth_frame_too_large", d.reason.?);
}

test "META HIGH #2: a 1MB junk blob returns auth_frame_too_large, NOT malformed" {
    // Operator-visible distinction: huge payload should NOT be
    // logged as "malformed extension build" — it's likely DoS.
    const entries = [_]TokenEntry{
        .{ .token = "tok", .user_id = "alice" },
    };
    const v = AuthValidator{ .entries = &entries };

    // 1 MB of garbage. We allocate on the heap for this one because
    // a 1 MB stack array is iffy in a test runner.
    const big = std.testing.allocator.alloc(u8, 1024 * 1024) catch unreachable;
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    const d = v.validate(big);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("auth_frame_too_large", d.reason.?);
}

test "constantTimeEql length mismatch returns false" {
    try std.testing.expect(!constantTimeEql("abc", "abcd"));
    try std.testing.expect(!constantTimeEql("abcd", "abc"));
}

test "constantTimeEql equal slices return true" {
    try std.testing.expect(constantTimeEql("hello", "hello"));
    try std.testing.expect(constantTimeEql("", ""));
}

test "constantTimeEql different bytes return false" {
    try std.testing.expect(!constantTimeEql("hello", "hellp"));
    try std.testing.expect(!constantTimeEql("hello", "Hello"));
}

// ── ME-02 (v1.14.23) — pad-to-fixed-length tests ─────────────────────

test "ME-02: constant-time loop iterates fixed count regardless of length" {
    // White-box invariant: the loop body runs MAX_TOKEN_LEN times for
    // every call within the allowed length range. We can't directly
    // assert "iteration count" without instrumenting the function, so
    // we assert the OBSERVABLE consequence: every length pair
    // (including wildly asymmetric ones) returns a result with the
    // same shape — no panic, no UB, no different code path.
    //
    // The cases below cover the full length matrix: short=short,
    // short=long, long=short, short=MAX, long=MAX, MAX=MAX, and the
    // boundary at MAX_TOKEN_LEN exactly. A regression to early-exit
    // would NOT change these return values (they're all rejections
    // because the bytes differ or lengths differ), but it WOULD
    // measurably change relative timing. This test exists primarily
    // to lock the contract in tree so a future "optimize the hot
    // path" PR can't strip the pad-loop without a visible diff to
    // this file.
    const a_short = "x";
    const b_short = "y";
    try std.testing.expect(!constantTimeEql(a_short, b_short));

    const a_long = "x" ** 200;
    const b_long = "y" ** 200;
    try std.testing.expect(!constantTimeEql(a_long, b_long));

    // Asymmetric: short vs long.
    try std.testing.expect(!constantTimeEql(a_short, b_long));
    try std.testing.expect(!constantTimeEql(a_long, b_short));

    // Both at exactly MAX_TOKEN_LEN with one differing byte.
    var a_max: [MAX_TOKEN_LEN]u8 = @splat('a');
    var b_max: [MAX_TOKEN_LEN]u8 = @splat('a');
    b_max[MAX_TOKEN_LEN - 1] = 'b';
    try std.testing.expect(!constantTimeEql(&a_max, &b_max));

    // Both at exactly MAX_TOKEN_LEN, identical → match.
    var c_max: [MAX_TOKEN_LEN]u8 = @splat('a');
    try std.testing.expect(constantTimeEql(&a_max, &c_max));

    // Over the cap: returns false (length isn't secret, but we still
    // want a defined behavior rather than overrunning the pad buffer).
    var over_a: [MAX_TOKEN_LEN + 1]u8 = @splat('z');
    var over_b: [MAX_TOKEN_LEN + 1]u8 = @splat('z');
    try std.testing.expect(!constantTimeEql(&over_a, &over_b));
}

test "ME-02: auth still rejects wrong-length tokens" {
    // Behavioral regression guard: after the pad-buffer rewrite, the
    // length-equal mask must still cause length mismatches to reject.
    // A bug that flipped the mask polarity (or forgot to OR it in)
    // would let "tok" match a configured "tok\0\0\0..." (because the
    // padded buffers would byte-equal). This test pins the contract.
    const entries = [_]TokenEntry{
        .{ .token = "tok-alice-32-bytes-long-exactly!", .user_id = "alice" },
    };
    const v = AuthValidator{ .entries = &entries };

    // Same prefix, shorter length → reject.
    const auth_short =
        \\{"type":"auth","token":"tok-alice","user_id":"alice"}
    ;
    const d_short = v.validate(auth_short);
    try std.testing.expect(!d_short.ok);
    try std.testing.expectEqualStrings("invalid_token", d_short.reason.?);

    // Same prefix, longer length → reject.
    const auth_long =
        \\{"type":"auth","token":"tok-alice-32-bytes-long-exactly!-PLUS-MORE","user_id":"alice"}
    ;
    const d_long = v.validate(auth_long);
    try std.testing.expect(!d_long.ok);
    try std.testing.expectEqualStrings("invalid_token", d_long.reason.?);

    // Exact match → accept (sanity that the pad-buffer logic didn't
    // break the happy path).
    const auth_exact =
        \\{"type":"auth","token":"tok-alice-32-bytes-long-exactly!","user_id":"alice"}
    ;
    const d_exact = v.validate(auth_exact);
    try std.testing.expect(d_exact.ok);
    try std.testing.expectEqualStrings("alice", d_exact.user_id.?);
}

// ── Plan-8 (2026-06-06) — anti-replay nonce tests ────────────────────
//
// Test names contain "extension" so `zig build test -Dtest-filter=extension`
// selects them alongside the existing extension_ws suite.

test "extension nonce: generateNonceHex is hex, full length, and random" {
    var a: [NONCE_HEX_LEN]u8 = undefined;
    var b: [NONCE_HEX_LEN]u8 = undefined;
    generateNonceHex(&a);
    generateNonceHex(&b);
    // Lower-hex alphabet only.
    for (a) |c| try std.testing.expect(std.ascii.isHex(c) and (c < 'A' or c > 'F'));
    // Two draws from a CSPRNG must (astronomically) differ.
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "extension nonce: constantTimeNonceEql matches only on exact equal" {
    var n: [NONCE_HEX_LEN]u8 = @splat('a');
    var same: [NONCE_HEX_LEN]u8 = @splat('a');
    var diff: [NONCE_HEX_LEN]u8 = @splat('a');
    diff[NONCE_HEX_LEN - 1] = 'b';
    try std.testing.expect(constantTimeNonceEql(&n, &same));
    try std.testing.expect(!constantTimeNonceEql(&n, &diff));
    // Wrong length never matches.
    try std.testing.expect(!constantTimeNonceEql(&n, "abc"));
    try std.testing.expect(!constantTimeNonceEql("abc", &n));
}

test "extension nonce: valid token + correct echoed nonce is ACCEPTED" {
    const nonce = "a" ** NONCE_HEX_LEN;
    const entries = [_]TokenEntry{.{ .token = "tok-alice", .user_id = "alice" }};
    const v = AuthValidator{ .entries = &entries, .expected_nonce = nonce };
    const auth =
        \\{"type":"auth","token":"tok-alice","nonce":"
    ++ nonce ++
        \\"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(d.ok);
    try std.testing.expectEqualStrings("alice", d.user_id.?);
}

test "extension nonce: valid token but MISSING nonce is REJECTED (bad_nonce)" {
    const nonce = "a" ** NONCE_HEX_LEN;
    const entries = [_]TokenEntry{.{ .token = "tok-alice", .user_id = "alice" }};
    const v = AuthValidator{ .entries = &entries, .expected_nonce = nonce };
    const auth =
        \\{"type":"auth","token":"tok-alice"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("bad_nonce", d.reason.?);
    try std.testing.expect(d.user_id == null);
}

test "extension nonce: valid token but WRONG nonce is REJECTED (replay defense)" {
    // The replay scenario: an attacker captured a prior connection's
    // auth frame (valid token + that connection's nonce) and replays it
    // on a NEW connection whose freshly-minted nonce differs. The
    // expected_nonce here models the new connection's nonce; the frame
    // carries the stale one.
    const this_conn_nonce = "b" ** NONCE_HEX_LEN;
    const stale_nonce = "a" ** NONCE_HEX_LEN;
    const entries = [_]TokenEntry{.{ .token = "tok-alice", .user_id = "alice" }};
    const v = AuthValidator{ .entries = &entries, .expected_nonce = this_conn_nonce };
    const auth =
        \\{"type":"auth","token":"tok-alice","nonce":"
    ++ stale_nonce ++
        \\"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("bad_nonce", d.reason.?);
}

test "extension nonce: single-use is connection-bound (reused nonce on new conn rejected)" {
    // "Single-use" is enforced structurally: each connection mints its
    // own nonce and the validator runs once per connection. A second
    // connection has a DIFFERENT expected_nonce, so echoing the first
    // connection's (now-consumed) nonce fails the second connection's
    // check. This test models that: conn2's validator carries nonce2,
    // the frame echoes nonce1 → reject.
    const nonce1 = "1" ** NONCE_HEX_LEN;
    const nonce2 = "2" ** NONCE_HEX_LEN;
    const entries = [_]TokenEntry{.{ .token = "tok-alice", .user_id = "alice" }};

    // Conn 1: echoing nonce1 is accepted.
    const v1 = AuthValidator{ .entries = &entries, .expected_nonce = nonce1 };
    const auth1 =
        \\{"type":"auth","token":"tok-alice","nonce":"
    ++ nonce1 ++
        \\"}
    ;
    try std.testing.expect(v1.validate(auth1).ok);

    // Conn 2: same frame (reusing nonce1) is rejected because conn2's
    // expected nonce is nonce2.
    const v2 = AuthValidator{ .entries = &entries, .expected_nonce = nonce2 };
    const d2 = v2.validate(auth1);
    try std.testing.expect(!d2.ok);
    try std.testing.expectEqualStrings("bad_nonce", d2.reason.?);
}

test "extension nonce: wrong token with correct nonce still REJECTED (invalid_token, additive)" {
    // The nonce is ADDITIVE — it does not replace the token check. A
    // bogus token short-circuits to invalid_token before the nonce is
    // even consulted (no matched entry).
    const nonce = "a" ** NONCE_HEX_LEN;
    const entries = [_]TokenEntry{.{ .token = "tok-alice", .user_id = "alice" }};
    const v = AuthValidator{ .entries = &entries, .expected_nonce = nonce };
    const auth =
        \\{"type":"auth","token":"bogus","nonce":"
    ++ nonce ++
        \\"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("invalid_token", d.reason.?);
}

// ── Plan-8 — token rotation window tests ─────────────────────────────

test "extension rotation: NEW (current) token is accepted while window open" {
    const nonce = "a" ** NONCE_HEX_LEN;
    const entries = [_]TokenEntry{.{
        .token = "tok-new",
        .user_id = "alice",
        .token_previous = "tok-old",
    }};
    const v = AuthValidator{ .entries = &entries, .expected_nonce = nonce };
    const auth =
        \\{"type":"auth","token":"tok-new","nonce":"
    ++ nonce ++
        \\"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(d.ok);
    try std.testing.expectEqualStrings("alice", d.user_id.?);
}

test "extension rotation: PREVIOUS token is accepted while window open" {
    const nonce = "a" ** NONCE_HEX_LEN;
    const entries = [_]TokenEntry{.{
        .token = "tok-new",
        .user_id = "alice",
        .token_previous = "tok-old",
    }};
    const v = AuthValidator{ .entries = &entries, .expected_nonce = nonce };
    const auth =
        \\{"type":"auth","token":"tok-old","nonce":"
    ++ nonce ++
        \\"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(d.ok);
    try std.testing.expectEqualStrings("alice", d.user_id.?);
}

test "extension rotation: PREVIOUS token is REJECTED after window cleared" {
    const nonce = "a" ** NONCE_HEX_LEN;
    // token_previous cleared (null) — only the current token works now.
    const entries = [_]TokenEntry{.{
        .token = "tok-new",
        .user_id = "alice",
        .token_previous = null,
    }};
    const v = AuthValidator{ .entries = &entries, .expected_nonce = nonce };
    const auth =
        \\{"type":"auth","token":"tok-old","nonce":"
    ++ nonce ++
        \\"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("invalid_token", d.reason.?);
}

test "extension rotation: empty-string previous token is treated as not-set" {
    const nonce = "a" ** NONCE_HEX_LEN;
    const entries = [_]TokenEntry{.{
        .token = "tok-new",
        .user_id = "alice",
        .token_previous = "", // "" must NOT admit a blank token
    }};
    const v = AuthValidator{ .entries = &entries, .expected_nonce = nonce };
    // A blank-token attempt must be rejected.
    const auth_blank =
        \\{"type":"auth","token":"","nonce":"
    ++ nonce ++
        \\"}
    ;
    try std.testing.expect(!v.validate(auth_blank).ok);
    // The current token still works.
    const auth_new =
        \\{"type":"auth","token":"tok-new","nonce":"
    ++ nonce ++
        \\"}
    ;
    try std.testing.expect(v.validate(auth_new).ok);
}

test "extension rotation: bogus token rejected even with both current and previous set" {
    const nonce = "a" ** NONCE_HEX_LEN;
    const entries = [_]TokenEntry{.{
        .token = "tok-new",
        .user_id = "alice",
        .token_previous = "tok-old",
    }};
    const v = AuthValidator{ .entries = &entries, .expected_nonce = nonce };
    const auth =
        \\{"type":"auth","token":"definitely-not-a-token","nonce":"
    ++ nonce ++
        \\"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("invalid_token", d.reason.?);
}
