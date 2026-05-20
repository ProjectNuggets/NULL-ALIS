//! V1.7-ship S2a — `brain_graph` tool: agent-side wrapper over the
//! V1.7a-Obsidian-parity graph endpoints.
//!
//! Gives nullalis the same superpower the FE will get from /brain/*
//! endpoints: navigate the user's knowledge as STRUCTURE, not just text.
//!
//! ## Why a tool, not always-injected
//!
//! `recallMemoriesAsGraph` (V1.7a-2) already injects 1-hop graph
//! neighbors warm into the memory enrichment block on every turn.
//! That's tier-1: cheap, always-on, useful for every memory-touching
//! query. This tool is tier-3: explicit on-demand drilldown when the
//! user's question is shape-of-the-data (relational / cluster /
//! temporal) rather than content-of-a-fact.
//!
//! ## Sub-actions (specified via the `action` arg)
//!
//!   "local_graph"  → N-hop subgraph from a center fact (was
//!                    /brain/local-graph V1.7a-7)
//!   "communities"  → topical clusters with names + sizes (was
//!                    /brain/communities V1.7a-9d)
//!   "orphans"      → facts with no edges (was /brain/orphans V1.7a-8a)
//!   "diff"         → births/deaths of facts in a date window (was
//!                    /brain/diff V1.7a-6)
//!
//! ## Reuse audit (per V1.7-ship architectural constraint)
//!
//! ZERO new SQL, ZERO new algorithms. Pure wrapper over:
//!   - graph_expand.expandFromSeeds (V1.6 cmt10)
//!   - state_mgr.listCommunities (V1.7a-9a)
//!   - state_mgr.listOrphanMemories (V1.7a-8a)
//!   - state_mgr.listMemoryBirthsInWindow (V1.7a-6)
//!   - state_mgr.listMemoryDeathsInWindow (V1.7a-6)
//!
//! ## Token economy
//!
//! Each action returns a structured JSON-in-text payload, capped:
//!   - 20 nodes / 20 edges per local_graph response
//!   - top 10 communities per communities response
//!   - top 20 orphans per orphans response
//!   - 30 births + 30 deaths per diff response
//! Per-content truncation to 100 chars. Total payload ≤ ~3KB.

const std = @import("std");
const log = std.log.scoped(.brain_graph_tool);

const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const mem_root = @import("../memory/root.zig");
const zaki_state = @import("../zaki_state.zig");
const graph_expand = @import("../agent/graph_expand.zig");

pub const BrainGraphTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "brain_graph";
    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Visualize and navigate the knowledge graph of facts.",
        .use_when = &.{
            "scenario 1",
            "scenario 2",
        },
        .do_not_use_for = &.{
            "web_search — for external data",
            "memory_store — for persistence",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("brain_graph", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Navigate the user's knowledge graph as STRUCTURE (relations / clusters / time), " ++
        "not just content. Use this when the user's question is about the SHAPE of what " ++
        "they know, not the substance of one fact. Prefer `memory_recall` for content-of-a-fact " ++
        "questions ('what did Alex say about HRS?'). Prefer `brain_graph` for: " ++
        "RELATIONAL ('what connects to my Helix preference?' → action='local_graph'), " ++
        "TOPICAL ('what topics am I focused on this month?' → action='communities'), " ++
        "ISOLATION ('what notes did I save but never link to anything?' → action='orphans'), " ++
        "TEMPORAL ('what changed in my brain yesterday?' → action='diff', date='YYYY-MM-DD'). " ++
        "Returns structured JSON.";

    pub const tool_params =
        \\{"type":"object","properties":{
        \\"action":{"type":"string","enum":["local_graph","communities","orphans","diff"],"description":"Which graph navigation to perform"},
        \\"center_key":{"type":"string","description":"For action=local_graph: the fact key to center the subgraph on (use a key returned by memory_recall)"},
        \\"depth":{"type":"integer","description":"For action=local_graph: BFS depth 1-3 (default: 1)"},
        \\"limit":{"type":"integer","description":"For action=communities|orphans: max results (default: 10 communities, 20 orphans)"},
        \\"date":{"type":"string","description":"For action=diff: YYYY-MM-DD UTC date for the diff window (default: today)"},
        \\"window_days":{"type":"integer","description":"For action=diff: window length in days (default: 1, max: 30)"}
        \\},"required":["action"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *BrainGraphTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *BrainGraphTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const sm = self.state_mgr orelse return ToolResult.fail("brain_graph unavailable: state manager not bound (postgres not configured)");
        const uid = self.user_id orelse return ToolResult.fail("brain_graph unavailable: user_id not bound");

        const action = root.getString(args, "action") orelse
            return ToolResult.fail("Missing 'action' parameter. Expected one of: local_graph, communities, orphans, diff.");

        if (std.mem.eql(u8, action, "local_graph")) {
            return executeLocalGraph(allocator, sm, uid, args);
        } else if (std.mem.eql(u8, action, "communities")) {
            return executeCommunities(allocator, sm, uid, args);
        } else if (std.mem.eql(u8, action, "orphans")) {
            return executeOrphans(allocator, sm, uid, args);
        } else if (std.mem.eql(u8, action, "diff")) {
            return executeDiff(allocator, sm, uid, args);
        }
        return ToolResult.fail("Invalid 'action'. Expected one of: local_graph, communities, orphans, diff.");
    }

    // ── local_graph ────────────────────────────────────────────────
    fn executeLocalGraph(
        allocator: std.mem.Allocator,
        sm: *zaki_state.Manager,
        uid: i64,
        args: JsonObjectMap,
    ) !ToolResult {
        const center_key = root.getString(args, "center_key") orelse
            return ToolResult.fail("action=local_graph requires 'center_key'. Use a key returned by memory_recall.");
        const depth_raw = root.getInt(args, "depth") orelse 1;
        const depth: u8 = if (depth_raw > 0 and depth_raw <= 3) @intCast(depth_raw) else 1;

        // Verify center exists + is brain-visible. Same gate as
        // /brain/local-graph endpoint (V1.7a-7).
        if (!mem_root.isBrainVisibleKey(center_key)) {
            return ToolResult.fail("center_key is hidden (system bookkeeping). Pick a user-visible memory key.");
        }
        const center_row = sm.getMemory(allocator, uid, center_key) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to verify center: {s}", .{@errorName(err)});
            return .{ .success = false, .output = "", .error_msg = msg };
        };
        if (center_row) |row| {
            row.deinit(allocator);
        } else {
            return ToolResult.fail("center_key not found (or archived). Try memory_recall first to find a live key.");
        }

        const seeds = [_][]const u8{center_key};
        var nb = graph_expand.expandFromSeeds(allocator, sm, uid, &seeds, .{
            .max_hops = depth,
            .max_nodes_per_hop = 20,
        }) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Graph expansion failed: {s}", .{@errorName(err)});
            return .{ .success = false, .output = "", .error_msg = msg };
        };
        defer nb.deinit(allocator);

        // Build JSON output capped at 20 nodes / 20 edges.
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        const w = out.writer(allocator);
        try w.print("{{\"action\":\"local_graph\",\"center_key\":\"", .{});
        try jsonEscape(w, center_key);
        try w.print("\",\"depth\":{d},\"nodes\":[", .{depth});
        var node_count: usize = 0;
        for (nb.nodes) |n| {
            if (node_count >= 20) break;
            if (!mem_root.isBrainVisibleKey(n.key)) continue;
            if (node_count > 0) try w.writeAll(",");
            try w.writeAll("{\"key\":\"");
            try jsonEscape(w, n.key);
            try w.print("\",\"hop\":{d},\"score\":{d:.3}}}", .{ n.hop_distance, n.score });
            node_count += 1;
        }
        try w.writeAll("],\"edges\":[");
        var edge_count: usize = 0;
        for (nb.edges) |e| {
            if (edge_count >= 20) break;
            if (!mem_root.isBrainVisibleKey(e.source_key) or !mem_root.isBrainVisibleKey(e.target_key)) continue;
            if (edge_count > 0) try w.writeAll(",");
            try w.writeAll("{\"source\":\"");
            try jsonEscape(w, e.source_key);
            try w.writeAll("\",\"target\":\"");
            try jsonEscape(w, e.target_key);
            try w.writeAll("\",\"predicate\":\"");
            try jsonEscape(w, e.predicate);
            try w.print("\",\"weight\":{d:.2}}}", .{e.weight});
            edge_count += 1;
        }
        try w.print("],\"stats\":{{\"nodes\":{d},\"edges\":{d}}}}}", .{ node_count, edge_count });
        return .{ .success = true, .output = try out.toOwnedSlice(allocator) };
    }

    // ── communities ────────────────────────────────────────────────
    fn executeCommunities(
        allocator: std.mem.Allocator,
        sm: *zaki_state.Manager,
        uid: i64,
        args: JsonObjectMap,
    ) !ToolResult {
        const limit_raw = root.getInt(args, "limit") orelse 10;
        const limit: usize = if (limit_raw > 0 and limit_raw <= 50) @intCast(limit_raw) else 10;

        const summaries = sm.listCommunities(allocator, uid) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Communities query failed: {s}", .{@errorName(err)});
            return .{ .success = false, .output = "", .error_msg = msg };
        };
        defer mem_root.freeCommunitySummaries(allocator, summaries);

        if (summaries.len == 0) {
            return .{
                .success = true,
                .output = try allocator.dupe(u8,
                    \\{"action":"communities","communities":[],"hint":"No communities yet. Suggest user POST /brain/communities/recompute (or wait for next nightly job) to populate cluster data."}
                ),
            };
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        const w = out.writer(allocator);
        try w.writeAll("{\"action\":\"communities\",\"communities\":[");
        var n: usize = 0;
        for (summaries) |s| {
            if (n >= limit) break;
            if (n > 0) try w.writeAll(",");
            try w.print("{{\"id\":{d},\"size\":{d},\"name\":", .{ s.community_id, s.member_count });
            if (s.name) |name| {
                try w.writeAll("\"");
                try jsonEscape(w, name);
                try w.writeAll("\"");
            } else {
                try w.writeAll("null");
            }
            try w.writeAll("}");
            n += 1;
        }
        try w.print("],\"stats\":{{\"returned\":{d},\"total\":{d}}}}}", .{ n, summaries.len });
        return .{ .success = true, .output = try out.toOwnedSlice(allocator) };
    }

    // ── orphans ────────────────────────────────────────────────────
    fn executeOrphans(
        allocator: std.mem.Allocator,
        sm: *zaki_state.Manager,
        uid: i64,
        args: JsonObjectMap,
    ) !ToolResult {
        const limit_raw = root.getInt(args, "limit") orelse 20;
        const limit: u32 = if (limit_raw > 0 and limit_raw <= 100) @intCast(limit_raw) else 20;

        const orphans = sm.listOrphanMemories(allocator, uid, limit) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Orphans query failed: {s}", .{@errorName(err)});
            return .{ .success = false, .output = "", .error_msg = msg };
        };
        defer mem_root.freeEntries(allocator, orphans);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        const w = out.writer(allocator);
        try w.writeAll("{\"action\":\"orphans\",\"orphans\":[");
        for (orphans, 0..) |e, i| {
            if (i > 0) try w.writeAll(",");
            const summary_len = @min(e.content.len, 100);
            try w.writeAll("{\"key\":\"");
            try jsonEscape(w, e.key);
            try w.writeAll("\",\"summary\":\"");
            try jsonEscape(w, e.content[0..summary_len]);
            try w.writeAll("\"}");
        }
        try w.print("],\"stats\":{{\"returned\":{d}}}}}", .{orphans.len});
        return .{ .success = true, .output = try out.toOwnedSlice(allocator) };
    }

    // ── diff ───────────────────────────────────────────────────────
    fn executeDiff(
        allocator: std.mem.Allocator,
        sm: *zaki_state.Manager,
        uid: i64,
        args: JsonObjectMap,
    ) !ToolResult {
        const date_param = root.getString(args, "date");
        const window_days_raw = root.getInt(args, "window_days") orelse 1;
        const window_days: i64 = if (window_days_raw > 0 and window_days_raw <= 30) @intCast(window_days_raw) else 1;

        // Compute window: date= specifies midnight UTC of that date, window_days extends forward.
        // No date= → today UTC.
        const now: i64 = std.time.timestamp();
        var window_from: i64 = undefined;
        if (date_param) |dp| {
            window_from = parseIsoDateUtc(dp) orelse {
                return ToolResult.fail("Invalid 'date' format. Expected YYYY-MM-DD.");
            };
        } else {
            window_from = @divFloor(now, 86400) * 86400;
        }
        const window_to = window_from + (window_days * 86400);

        const births = sm.listMemoryBirthsInWindow(allocator, uid, window_from, window_to, 30) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Births query failed: {s}", .{@errorName(err)});
            return .{ .success = false, .output = "", .error_msg = msg };
        };
        defer mem_root.freeEntries(allocator, births);

        const deaths = sm.listMemoryDeathsInWindow(allocator, uid, window_from, window_to, 30) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Deaths query failed: {s}", .{@errorName(err)});
            return .{ .success = false, .output = "", .error_msg = msg };
        };
        defer mem_root.freeEntries(allocator, deaths);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        const w = out.writer(allocator);
        try w.print("{{\"action\":\"diff\",\"window\":{{\"from\":{d},\"to\":{d}}},\"births\":[", .{ window_from, window_to });
        for (births, 0..) |e, i| {
            if (i > 0) try w.writeAll(",");
            const summary_len = @min(e.content.len, 100);
            try w.writeAll("{\"key\":\"");
            try jsonEscape(w, e.key);
            try w.writeAll("\",\"summary\":\"");
            try jsonEscape(w, e.content[0..summary_len]);
            try w.writeAll("\"}");
        }
        try w.writeAll("],\"deaths\":[");
        for (deaths, 0..) |e, i| {
            if (i > 0) try w.writeAll(",");
            const summary_len = @min(e.content.len, 100);
            try w.writeAll("{\"key\":\"");
            try jsonEscape(w, e.key);
            try w.writeAll("\",\"summary\":\"");
            try jsonEscape(w, e.content[0..summary_len]);
            try w.writeAll("\"}");
        }
        try w.print("],\"stats\":{{\"births\":{d},\"deaths\":{d}}}}}", .{ births.len, deaths.len });
        return .{ .success = true, .output = try out.toOwnedSlice(allocator) };
    }
};

/// Parse YYYY-MM-DD into unix-second of midnight UTC. Same algorithm
/// as gateway.parseIsoDateUtc (Howard Hinnant days_from_civil); copied
/// here to avoid pulling gateway as a dep into tools/.
fn parseIsoDateUtc(s: []const u8) ?i64 {
    if (s.len != 10) return null;
    if (s[4] != '-' or s[7] != '-') return null;
    const y = std.fmt.parseInt(u32, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    if (y < 1970 or y > 9999) return null;
    if (m < 1 or m > 12) return null;
    if (d < 1 or d > 31) return null;
    const is_leap = (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
    const days_in_month: u8 = switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (is_leap) 29 else 28,
        else => unreachable,
    };
    if (d > days_in_month) return null;
    const yy: i64 = if (m <= 2) @as(i64, y) - 1 else @as(i64, y);
    const era: i64 = @divFloor(if (yy >= 0) yy else yy - 399, 400);
    const yoe: u64 = @intCast(yy - era * 400);
    const mp: u64 = if (m > 2) @as(u64, m) - 3 else @as(u64, m) + 9;
    const doy: u64 = (153 * mp + 2) / 5 + @as(u64, d) - 1;
    const doe: u64 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    const days: i64 = era * 146097 + @as(i64, @intCast(doe)) - 719468;
    return days * 86400;
}

fn jsonEscape(writer: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "parseIsoDateUtc — accepts valid dates, rejects invalid" {
    try std.testing.expectEqual(@as(?i64, 0), parseIsoDateUtc("1970-01-01"));
    try std.testing.expectEqual(@as(?i64, 1704067200), parseIsoDateUtc("2024-01-01"));
    try std.testing.expect(parseIsoDateUtc("2024-02-29") != null); // leap
    try std.testing.expectEqual(@as(?i64, null), parseIsoDateUtc("2023-02-29"));
    try std.testing.expectEqual(@as(?i64, null), parseIsoDateUtc("invalid"));
    try std.testing.expectEqual(@as(?i64, null), parseIsoDateUtc("2024-13-01"));
}

test "BrainGraphTool — unbound state returns clear failure" {
    const allocator = std.testing.allocator;
    var t = BrainGraphTool{};
    var args = std.json.ObjectMap.init(allocator);
    defer args.deinit();
    try args.put("action", .{ .string = "communities" });
    const result = try t.execute(allocator, args);
    // ToolResult.fail() puts the message in error_msg, not output;
    // both are static slices (no allocator.free needed).
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "state manager not bound") != null);
}

test "BrainGraphTool — missing action returns clear failure" {
    const allocator = std.testing.allocator;
    // Build a tool with state_mgr stubbed (just a non-null pointer suffices
    // for the missing-action error path; we won't actually call PG).
    var stub_mgr: zaki_state.Manager = undefined;
    var t = BrainGraphTool{ .state_mgr = &stub_mgr, .user_id = 1 };
    var args = std.json.ObjectMap.init(allocator);
    defer args.deinit();
    const result = try t.execute(allocator, args);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Missing 'action'") != null);
}

test "BrainGraphTool — invalid action returns clear failure" {
    const allocator = std.testing.allocator;
    var stub_mgr: zaki_state.Manager = undefined;
    var t = BrainGraphTool{ .state_mgr = &stub_mgr, .user_id = 1 };
    var args = std.json.ObjectMap.init(allocator);
    defer args.deinit();
    try args.put("action", .{ .string = "frobnicate" });
    const result = try t.execute(allocator, args);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid 'action'") != null);
}

test "BrainGraphTool — bound state, unbound user_id returns clear failure (WR-3)" {
    // V1.7-ship review WR-3: explicit coverage for the user_id=null branch.
    // Previously only state_mgr=null was tested; the orelse on user_id was
    // unverified. This catches a regression that would silently 0-out the
    // tenant scope on a partially-bound tool.
    const allocator = std.testing.allocator;
    var stub_mgr: zaki_state.Manager = undefined;
    var t = BrainGraphTool{ .state_mgr = &stub_mgr }; // user_id intentionally null
    var args = std.json.ObjectMap.init(allocator);
    defer args.deinit();
    try args.put("action", .{ .string = "communities" });
    const result = try t.execute(allocator, args);
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "user_id not bound") != null);
}
