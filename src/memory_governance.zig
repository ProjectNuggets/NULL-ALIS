//! Memory governance contract — pure logic for the ZAKI V2 user-facing
//! privacy/data control plane (S7 follow-up).
//!
//! Surfaces the existing nullalis memory governance primitives
//! (forget-by-id, PII purge dry-run/apply, export, provenance counts) as
//! a stable, user-safe HTTP contract the ZAKI UI binds to under
//! `/api/v1/users/{id}/memory/*`. This module is DB/HTTP free — the
//! gateway does the zaki_state IO and delegates route parsing, category
//! validation, and response JSON shape here so the contract logic stays
//! unit-testable without Postgres.
//!
//! Scope notes:
//!   - PII detector scope is phone + email (+ all) — matches the
//!     `memory_purge_pii` tool / pii_detect.zig V1 detector. Name/address
//!     are explicitly out of scope.
//!   - Every operation is user-scoped; the gateway resolves the user from
//!     the authenticated `X-Zaki-User-Id` before calling in here.
//!   - Forget is by stable memory id/key (deterministic, reversible-audit
//!     via valid_to). Topic-substring purge stays an agent-only lever
//!     (memory_purge_topic) — not exposed as a blunt user delete.

const std = @import("std");

pub const Route = enum {
    /// GET memory/governance — provenance counts.
    counts,
    /// POST memory/forget — forget one memory by id/key.
    forget,
    /// POST memory/purge-pii — dry-run or apply a PII-category purge.
    purge_pii,
    /// GET memory/export — full user memory dump with provenance.
    export_all,

    pub fn fromSubpath(subpath: []const u8) ?Route {
        if (std.mem.eql(u8, subpath, "memory/governance")) return .counts;
        if (std.mem.eql(u8, subpath, "memory/forget")) return .forget;
        if (std.mem.eql(u8, subpath, "memory/purge-pii")) return .purge_pii;
        if (std.mem.eql(u8, subpath, "memory/export")) return .export_all;
        return null;
    }
};

pub const PiiCategory = enum {
    phone,
    email,
    all,

    pub fn fromKey(s: []const u8) ?PiiCategory {
        if (std.mem.eql(u8, s, "phone")) return .phone;
        if (std.mem.eql(u8, s, "email")) return .email;
        if (std.mem.eql(u8, s, "all")) return .all;
        return null;
    }

    pub fn key(self: PiiCategory) []const u8 {
        return switch (self) {
            .phone => "phone",
            .email => "email",
            .all => "all",
        };
    }
};

pub fn isValidPiiCategory(s: []const u8) bool {
    return PiiCategory.fromKey(s) != null;
}

/// How many sample keys a dry-run / apply result echoes back, so the UI
/// can show "these would be / were deleted" without dumping thousands.
pub const SAMPLE_KEY_CAP: usize = 20;

fn jsonEscape(w: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
}

/// Serialize a PII purge result (dry-run or apply). `deleted` is null on
/// a dry run. `sample_keys` is a bounded preview of affected keys.
pub fn writePurgeResult(
    w: anytype,
    category: PiiCategory,
    dry_run: bool,
    candidate_count: usize,
    deleted: ?usize,
    sample_keys: []const []const u8,
) !void {
    try w.writeAll("{\"category\":\"");
    try jsonEscape(w, category.key());
    try w.print("\",\"dry_run\":{s},\"candidate_count\":{d},\"deleted\":", .{ if (dry_run) "true" else "false", candidate_count });
    if (deleted) |d| {
        try w.print("{d}", .{d});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"sample_keys\":[");
    const cap = @min(sample_keys.len, SAMPLE_KEY_CAP);
    for (sample_keys[0..cap], 0..) |k, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('"');
        try jsonEscape(w, k);
        try w.writeByte('"');
    }
    try w.print("],\"sample_truncated\":{s}}}", .{if (sample_keys.len > cap) "true" else "false"});
}

/// Serialize provenance counts: total memories + PII counts per category.
pub fn writeCounts(w: anytype, total: usize, phone: usize, email: usize, all: usize) !void {
    try w.print("{{\"total\":{d},\"pii\":{{\"phone\":{d},\"email\":{d},\"all\":{d}}}}}", .{ total, phone, email, all });
}

pub fn writeForgetResult(w: anytype, key: []const u8, forgotten: bool) !void {
    try w.writeAll("{\"key\":\"");
    try jsonEscape(w, key);
    try w.print("\",\"forgotten\":{s}}}", .{if (forgotten) "true" else "false"});
}

// ── Tests ─────────────────────────────────────────────────────────────

test "route parsing" {
    try std.testing.expectEqual(Route.counts, Route.fromSubpath("memory/governance").?);
    try std.testing.expectEqual(Route.forget, Route.fromSubpath("memory/forget").?);
    try std.testing.expectEqual(Route.purge_pii, Route.fromSubpath("memory/purge-pii").?);
    try std.testing.expectEqual(Route.export_all, Route.fromSubpath("memory/export").?);
    try std.testing.expect(Route.fromSubpath("memory/forgettt") == null);
    try std.testing.expect(Route.fromSubpath("brain/graph") == null);
    try std.testing.expect(Route.fromSubpath("memory") == null);
}

test "pii category allowlist (phone/email/all only)" {
    try std.testing.expectEqual(PiiCategory.phone, PiiCategory.fromKey("phone").?);
    try std.testing.expectEqual(PiiCategory.email, PiiCategory.fromKey("email").?);
    try std.testing.expectEqual(PiiCategory.all, PiiCategory.fromKey("all").?);
    // Out of V1 detector scope — must be rejected.
    try std.testing.expect(PiiCategory.fromKey("name") == null);
    try std.testing.expect(PiiCategory.fromKey("address") == null);
    try std.testing.expect(PiiCategory.fromKey("") == null);
    try std.testing.expect(!isValidPiiCategory("ssn"));
    try std.testing.expect(isValidPiiCategory("email"));
}

test "writePurgeResult dry-run shape" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    const keys = [_][]const u8{ "k1", "k2" };
    try writePurgeResult(w, .phone, true, 2, null, &keys);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqualStrings("phone", o.get("category").?.string);
    try std.testing.expectEqual(true, o.get("dry_run").?.bool);
    try std.testing.expectEqual(@as(i64, 2), o.get("candidate_count").?.integer);
    try std.testing.expect(o.get("deleted").? == .null);
    try std.testing.expectEqual(@as(usize, 2), o.get("sample_keys").?.array.items.len);
    try std.testing.expectEqual(false, o.get("sample_truncated").?.bool);
}

test "writePurgeResult apply reports deleted count" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writePurgeResult(w, .all, false, 5, 5, &.{});
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqual(false, o.get("dry_run").?.bool);
    try std.testing.expectEqual(@as(i64, 5), o.get("deleted").?.integer);
}

test "writePurgeResult caps and flags truncation" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    var many: [25][]const u8 = undefined;
    for (&many, 0..) |*k, i| k.* = if (i % 2 == 0) "a" else "b";
    try writePurgeResult(w, .email, true, 25, null, &many);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqual(@as(usize, SAMPLE_KEY_CAP), o.get("sample_keys").?.array.items.len);
    try std.testing.expectEqual(true, o.get("sample_truncated").?.bool);
}

test "writeCounts shape" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeCounts(w, 42, 3, 5, 7);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 42), o.get("total").?.integer);
    const pii = o.get("pii").?.object;
    try std.testing.expectEqual(@as(i64, 3), pii.get("phone").?.integer);
    try std.testing.expectEqual(@as(i64, 7), pii.get("all").?.integer);
}

test "writeForgetResult escapes key" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeForgetResult(w, "fact_\"x\"", true);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("fact_\"x\"", parsed.value.object.get("key").?.string);
    try std.testing.expectEqual(true, parsed.value.object.get("forgotten").?.bool);
}
