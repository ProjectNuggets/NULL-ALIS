//! Extension device registry — pure logic for the ZAKI V2 user-facing
//! browser-extension device management contract (S7 follow-up).
//!
//! This is the *user device management* layer the activation map asks
//! for, kept deliberately distinct from the operator diagnostics surface
//! (`/api/v1/diagnostics/extension/*`, which reports live WS hub state).
//! The registry persists per-device lifecycle: pairing, inventory,
//! revoke, last-command, and last-error, plus a timeout-derived
//! connection state for the UI.
//!
//! This module is DB/HTTP free — the gateway does the zaki_state IO and
//! delegates route parsing, connection-state derivation, label
//! validation, and response JSON shape here so the contract logic stays
//! unit-testable without Postgres.
//!
//! SECURITY SCOPE (read before extending):
//!   The browser-extension WS auth path (`extension_ws/auth.zig`) is
//!   META-CRITICAL: it authenticates each socket with an operator-
//!   provisioned, constant-time-compared per-user token. This registry
//!   does NOT change that hot path. It is the management/observability
//!   layer: `revoke` records intent and flips device status, and the
//!   registry is the durable inventory the diagnostics endpoint lacks.
//!   Binding per-device token *issuance + enforcement* (so revoke denies
//!   a live socket) into the WS auth validator + mock-hub E2E is the
//!   remaining gated step — see the handoff doc.

const std = @import("std");

/// A device that has not reported in this many seconds is rendered as
/// `disconnected` (idle / closed laptop / lost socket). The WS contract
/// heartbeat is well under this; the value is intentionally generous so a
/// brief network blip doesn't flap the UI.
pub const DEVICE_TIMEOUT_S: i64 = 90;

/// Max label length — labels are user-supplied display strings ("Work
/// laptop"), single line.
pub const MAX_LABEL_LEN: usize = 128;

pub const Route = union(enum) {
    /// extension/devices — GET inventory, POST pair.
    collection,
    /// extension/devices/{id}/revoke — POST revoke.
    revoke: []const u8,
    /// extension/devices/{id} — DELETE (revoke alias).
    item: []const u8,
    /// Under extension/devices/ but malformed.
    unsupported,
};

/// Parse a user-scoped subpath into a device-registry route, or null if
/// it is not part of the device registry at all.
pub fn parseRoute(subpath: []const u8) ?Route {
    if (std.mem.eql(u8, subpath, "extension/devices")) return .collection;
    if (!std.mem.startsWith(u8, subpath, "extension/devices/")) return null;
    const rest = subpath["extension/devices/".len..];
    if (rest.len == 0) return .unsupported;

    var it = std.mem.splitScalar(u8, rest, '/');
    const id = it.next() orelse return .unsupported;
    if (id.len == 0) return .unsupported;
    const tail = it.next();
    if (it.next() != null) return .unsupported; // deeper than {id}/{verb}
    if (tail) |verb| {
        if (std.mem.eql(u8, verb, "revoke")) return .{ .revoke = id };
        return .unsupported;
    }
    return .{ .item = id };
}

/// A device id is an opaque server-minted hex string. Validate before
/// using it in a query path / JSON so a hostile id can't smuggle escapes.
pub fn isValidDeviceId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
        if (!ok) return false;
    }
    return true;
}

/// Labels are optional, single-line, bounded.
pub fn isValidLabel(label: []const u8) bool {
    if (label.len > MAX_LABEL_LEN) return false;
    for (label) |ch| {
        if (ch == '\n' or ch == '\r' or ch == 0x00) return false;
    }
    return true;
}

pub const ConnectionState = enum {
    /// Reported within DEVICE_TIMEOUT_S.
    connected,
    /// Paired + has connected before, but stale past the timeout.
    disconnected,
    /// Paired but never reported a heartbeat.
    never_connected,
    /// Operator/user revoked — no longer admitted.
    revoked,

    pub fn label(self: ConnectionState) []const u8 {
        return switch (self) {
            .connected => "connected",
            .disconnected => "disconnected",
            .never_connected => "never_connected",
            .revoked => "revoked",
        };
    }
};

pub fn deriveConnectionState(revoked: bool, last_seen_at_s: ?i64, now_s: i64, timeout_s: i64) ConnectionState {
    if (revoked) return .revoked;
    const last = last_seen_at_s orelse return .never_connected;
    if (now_s - last <= timeout_s) return .connected;
    return .disconnected;
}

// ── JSON serialization ────────────────────────────────────────────────

pub const DeviceView = struct {
    id: []const u8,
    label: []const u8,
    status: []const u8, // "active" | "revoked"
    connection_state: ConnectionState,
    paired_at_s: i64,
    last_seen_at_s: ?i64,
    last_command: ?[]const u8,
    last_command_at_s: ?i64,
    last_error: ?[]const u8,
    last_error_at_s: ?i64,
};

fn jsonEscape(w: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch);
            },
        }
    }
}

fn writeOptStr(w: anytype, v: ?[]const u8) !void {
    if (v) |s| {
        try w.writeByte('"');
        try jsonEscape(w, s);
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
}

fn writeOptInt(w: anytype, v: ?i64) !void {
    if (v) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
}

pub fn writeDeviceJson(w: anytype, d: DeviceView) !void {
    try w.writeAll("{\"id\":\"");
    try jsonEscape(w, d.id);
    try w.writeAll("\",\"label\":\"");
    try jsonEscape(w, d.label);
    try w.writeAll("\",\"status\":\"");
    try jsonEscape(w, d.status);
    try w.writeAll("\",\"connection_state\":\"");
    try jsonEscape(w, d.connection_state.label());
    try w.print("\",\"paired_at_s\":{d},\"last_seen_at_s\":", .{d.paired_at_s});
    try writeOptInt(w, d.last_seen_at_s);
    try w.writeAll(",\"last_command\":");
    try writeOptStr(w, d.last_command);
    try w.writeAll(",\"last_command_at_s\":");
    try writeOptInt(w, d.last_command_at_s);
    try w.writeAll(",\"last_error\":");
    try writeOptStr(w, d.last_error);
    try w.writeAll(",\"last_error_at_s\":");
    try writeOptInt(w, d.last_error_at_s);
    try w.writeByte('}');
}

// ── Tests ─────────────────────────────────────────────────────────────

test "parseRoute: collection / item / revoke" {
    try std.testing.expectEqual(Route.collection, parseRoute("extension/devices").?);
    const item = parseRoute("extension/devices/abc123").?;
    try std.testing.expectEqualStrings("abc123", item.item);
    const rev = parseRoute("extension/devices/abc123/revoke").?;
    try std.testing.expectEqualStrings("abc123", rev.revoke);
}

test "parseRoute: non-registry + malformed" {
    try std.testing.expect(parseRoute("extension/ws") == null);
    try std.testing.expect(parseRoute("channels") == null);
    try std.testing.expectEqual(Route.unsupported, parseRoute("extension/devices/abc/frob").?);
    try std.testing.expectEqual(Route.unsupported, parseRoute("extension/devices/a/b/c").?);
}

test "isValidDeviceId accepts hex, rejects escapes" {
    try std.testing.expect(isValidDeviceId("deadbeef0123"));
    try std.testing.expect(!isValidDeviceId(""));
    try std.testing.expect(!isValidDeviceId("../etc"));
    try std.testing.expect(!isValidDeviceId("abc\"xyz"));
    try std.testing.expect(!isValidDeviceId("zz"));
}

test "isValidLabel bounds + single line" {
    try std.testing.expect(isValidLabel(""));
    try std.testing.expect(isValidLabel("Work laptop"));
    try std.testing.expect(!isValidLabel("line\nbreak"));
}

test "deriveConnectionState" {
    try std.testing.expectEqual(ConnectionState.revoked, deriveConnectionState(true, 1000, 1000, 90));
    try std.testing.expectEqual(ConnectionState.never_connected, deriveConnectionState(false, null, 1000, 90));
    try std.testing.expectEqual(ConnectionState.connected, deriveConnectionState(false, 1000, 1050, 90));
    try std.testing.expectEqual(ConnectionState.connected, deriveConnectionState(false, 1000, 1090, 90));
    try std.testing.expectEqual(ConnectionState.disconnected, deriveConnectionState(false, 1000, 1200, 90));
}

test "writeDeviceJson stable shape, nulls + escaping" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeDeviceJson(w, .{
        .id = "abc123",
        .label = "Work \"laptop\"",
        .status = "active",
        .connection_state = .connected,
        .paired_at_s = 1730000000,
        .last_seen_at_s = 1730000500,
        .last_command = "extension_click",
        .last_command_at_s = 1730000400,
        .last_error = null,
        .last_error_at_s = null,
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try std.testing.expectEqualStrings("abc123", o.get("id").?.string);
    try std.testing.expectEqualStrings("Work \"laptop\"", o.get("label").?.string);
    try std.testing.expectEqualStrings("connected", o.get("connection_state").?.string);
    try std.testing.expectEqualStrings("extension_click", o.get("last_command").?.string);
    try std.testing.expect(o.get("last_error").? == .null);
    try std.testing.expectEqual(@as(i64, 1730000500), o.get("last_seen_at_s").?.integer);
}
