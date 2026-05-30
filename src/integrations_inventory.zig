//! Integrations inventory — pure logic for the ZAKI V2 read-only
//! integrations status surface (S7 follow-up, slice 5).
//!
//! Reports the *operator-configured* status of Composio, OpenAPI
//! connectors, and MCP client servers so the ZAKI UI can show
//! "Configured (operator-managed)" vs "Not configured" WITHOUT implying
//! user self-service. These integrations are operator-owned today; the
//! activation map keeps them read-only until user-managed auth contracts
//! exist. This module is DB/HTTP/Config free — the gateway reads the
//! Config and builds the plain views below, which serialize here so the
//! shape stays unit-testable.
//!
//! Security: only non-secret status is exposed — Composio's api_key,
//! OpenAPI auth_ref values, MCP headers/urls/commands are NEVER
//! serialized. Composio reports `key_present`; OpenAPI reports
//! `auth_required`; MCP reports name + transport only.

const std = @import("std");

pub const ComposioView = struct {
    configured: bool,
    entity_id: []const u8,
    key_present: bool,
};

pub const OpenApiItem = struct {
    id: []const u8,
    mode: []const u8, // "read_only" | "read_write"
    auth_required: bool,
};

pub const McpItem = struct {
    name: []const u8,
    transport: []const u8, // "stdio" | "http"
};

pub const Inventory = struct {
    composio: ComposioView,
    openapi: []const OpenApiItem,
    mcp_client: []const McpItem,
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

/// Write one operator-managed integration envelope header. Every entry is
/// read-only and operator-managed in V1.
fn writeEnvelopeHead(w: anytype, kind: []const u8, label: []const u8, configured: bool) !void {
    try w.writeAll("{\"kind\":\"");
    try jsonEscape(w, kind);
    try w.writeAll("\",\"label\":\"");
    try jsonEscape(w, label);
    try w.print("\",\"configured\":{s},\"user_manageable\":false,\"managed_by\":\"operator\"", .{if (configured) "true" else "false"});
}

pub fn writeInventoryJson(w: anytype, inv: Inventory) !void {
    try w.writeAll("{\"integrations\":[");

    // Composio
    try writeEnvelopeHead(w, "composio", "Composio", inv.composio.configured);
    try w.writeAll(",\"detail\":{\"entity_id\":\"");
    try jsonEscape(w, inv.composio.entity_id);
    try w.print("\",\"key_present\":{s}}}}}", .{if (inv.composio.key_present) "true" else "false"});

    // OpenAPI connectors
    try w.writeByte(',');
    try writeEnvelopeHead(w, "openapi", "OpenAPI Connectors", inv.openapi.len > 0);
    try w.print(",\"count\":{d},\"items\":[", .{inv.openapi.len});
    for (inv.openapi, 0..) |it, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":\"");
        try jsonEscape(w, it.id);
        try w.writeAll("\",\"mode\":\"");
        try jsonEscape(w, it.mode);
        try w.print("\",\"auth_required\":{s}}}", .{if (it.auth_required) "true" else "false"});
    }
    try w.writeAll("]}");

    // MCP client servers
    try w.writeByte(',');
    try writeEnvelopeHead(w, "mcp_client", "MCP Servers", inv.mcp_client.len > 0);
    try w.print(",\"count\":{d},\"items\":[", .{inv.mcp_client.len});
    for (inv.mcp_client, 0..) |it, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":\"");
        try jsonEscape(w, it.name);
        try w.writeAll("\",\"transport\":\"");
        try jsonEscape(w, it.transport);
        try w.writeAll("\"}");
    }
    try w.writeAll("]}");

    try w.writeAll("]}");
}

// ── Tests ─────────────────────────────────────────────────────────────

test "writeInventoryJson — populated, read-only, secret-free" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    const openapi = [_]OpenApiItem{
        .{ .id = "weather", .mode = "read_only", .auth_required = true },
        .{ .id = "internal", .mode = "read_write", .auth_required = false },
    };
    const mcp = [_]McpItem{.{ .name = "context7", .transport = "stdio" }};
    try writeInventoryJson(w, .{
        .composio = .{ .configured = true, .entity_id = "default", .key_present = true },
        .openapi = &openapi,
        .mcp_client = &mcp,
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("integrations").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.items.len);

    const composio = arr.items[0].object;
    try std.testing.expectEqualStrings("composio", composio.get("kind").?.string);
    try std.testing.expectEqual(false, composio.get("user_manageable").?.bool);
    try std.testing.expectEqual(true, composio.get("detail").?.object.get("key_present").?.bool);
    // Composio api_key value is NEVER present.
    try std.testing.expect(composio.get("detail").?.object.get("api_key") == null);

    const oa = arr.items[1].object;
    try std.testing.expectEqualStrings("openapi", oa.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 2), oa.get("count").?.integer);
    try std.testing.expectEqualStrings("read_only", oa.get("items").?.array.items[0].object.get("mode").?.string);
    // No auth_ref value, no spec_url leaked.
    try std.testing.expect(oa.get("items").?.array.items[0].object.get("auth_ref") == null);

    const mcpv = arr.items[2].object;
    try std.testing.expectEqualStrings("mcp_client", mcpv.get("kind").?.string);
    try std.testing.expectEqualStrings("context7", mcpv.get("items").?.array.items[0].object.get("name").?.string);
    // No url / headers leaked.
    try std.testing.expect(mcpv.get("items").?.array.items[0].object.get("url") == null);
}

test "writeInventoryJson — unconfigured" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeInventoryJson(w, .{
        .composio = .{ .configured = false, .entity_id = "default", .key_present = false },
        .openapi = &.{},
        .mcp_client = &.{},
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("integrations").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.items.len);
    for (arr.items) |it| {
        try std.testing.expectEqual(false, it.object.get("configured").?.bool);
        try std.testing.expectEqual(false, it.object.get("user_manageable").?.bool);
        try std.testing.expectEqualStrings("operator", it.object.get("managed_by").?.string);
    }
}
