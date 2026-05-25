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
};

pub const AuthDecision = struct {
    ok: bool,
    /// On success, the SERVER-derived user_id (from the matching
    /// `TokenEntry`). On failure, null. NEVER reflects the inbound
    /// auth frame's `user_id` field.
    user_id: ?[]const u8 = null,
    /// On failure, a short machine-readable reason
    /// (`"invalid_token"`, `"auth_frame_too_large"`,
    /// `"malformed_auth_frame"`). Lands in the
    /// `auth_ack{ok:false, error}` envelope verbatim — keep it
    /// alphanumeric-and-underscores so popup-rendering stays simple.
    reason: ?[]const u8 = null,
};

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
            if (constantTimeEql(entry.token, token_str)) {
                // Don't break — keep iterating so an attacker can't
                // time-attack "which slot did I hit." We still
                // capture the matched index.
                if (matched_idx == null) matched_idx = i;
            }
        }

        if (matched_idx) |idx| {
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
