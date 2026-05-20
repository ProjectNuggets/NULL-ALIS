//! V1.6 commit 11 — memory_demote agent tool: flip a `core` memory back
//! to a non-core type (daily / conversation / episodic).
//!
//! Why this exists:
//!   - V1.7 Tier-3 promotion auto-flips a memory to `core` when the same
//!     key is written from ≥2 distinct sessions (cross-session corroboration).
//!   - V1.6 cmt6/cmt7 W-INT-01 fix CASE-guards core rows so subsequent
//!     `upsertMemory` writes can't demote them back. This protects the
//!     promotion against being silently undone, but creates a problem:
//!     once core, a row is immortal against ANY subsequent ON CONFLICT
//!     write, including legitimate user-driven corrections.
//!   - The escape hatch: an explicit demotion. The user (via the agent)
//!     says "stop treating this as a core fact, downgrade it to daily."
//!     The CASE-guard releases its hold; subsequent upserts can edit
//!     the row freely again.
//!
//! Safety:
//!   - target_category MUST be one of "daily" / "conversation" /
//!     "episodic". Defending against "core" prevents a no-op that would
//!     mask agent confusion.
//!   - Only acts on rows that are currently `core`. Returns success-with-
//!     null-effect when key doesn't exist or is already non-core.
//!   - Emits a memory_events row with event_type='demote' carrying the
//!     from/to types so the demotion is auditable.
//!
//! Pairs with memory_archive (cmt11 sibling): demote first if you need to
//! soft-delete a core fact. Or use memory_forget for hard delete (which
//! ignores the CASE-guard since it's a DELETE, not an UPDATE).

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const zaki_state = @import("../zaki_state.zig");

pub const MemoryDemoteTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "memory_demote";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "memory_demote tool.",
        .use_when = &.{
            "first scenario",
            "second scenario",
        },
        .do_not_use_for = &.{
            "web_search — for web queries",
            "memory_store — for persistence",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("memory_demote", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description =
        "Demote a `core` memory back to a non-core type (daily / conversation / episodic). " ++
        "Required when a Tier-3-promoted memory needs to be edited or retired — " ++
        "otherwise the V1.7 immortality guard prevents subsequent upserts from " ++
        "modifying the row. Use this BEFORE memory_archive when you want to " ++
        "soft-delete a core fact.";
    pub const tool_params =
        \\{"type":"object","properties":{"key":{"type":"string","description":"The key of the core memory to demote"},"target_category":{"type":"string","enum":["daily","conversation","episodic"],"description":"Type to demote to (default: daily)"}},"required":["key"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryDemoteTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *MemoryDemoteTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const key = root.getString(args, "key") orelse
            return ToolResult.fail("Missing 'key' parameter");
        if (key.len == 0) return ToolResult.fail("'key' must not be empty");

        const target = root.getString(args, "target_category") orelse "daily";
        // Defensive: target=core would be a no-op masking caller's confusion.
        if (std.mem.eql(u8, target, "core")) {
            return ToolResult.fail("target_category=core is invalid (you're trying to demote, not promote)");
        }

        const smgr = self.state_mgr orelse {
            const msg = try std.fmt.allocPrint(allocator, "Demote unavailable (no postgres state manager): {s}", .{key});
            return ToolResult{ .success = false, .output = msg };
        };
        const uid = self.user_id orelse {
            const msg = try std.fmt.allocPrint(allocator, "Demote unavailable (no tenant user_id): {s}", .{key});
            return ToolResult{ .success = false, .output = msg };
        };

        const demoted = smgr.demoteMemoryFromCore(uid, key, target) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to demote memory '{s}': {s}", .{ key, @errorName(err) });
            return ToolResult{ .success = false, .output = msg };
        };

        if (demoted) {
            const msg = try std.fmt.allocPrint(allocator, "Demoted memory: {s} (core → {s})", .{ key, target });
            return ToolResult{ .success = true, .output = msg };
        } else {
            const msg = try std.fmt.allocPrint(allocator, "No core memory found with key (already non-core or missing): {s}", .{key});
            return ToolResult{ .success = true, .output = msg };
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "memory_demote tool name" {
    var mt = MemoryDemoteTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_demote", t.name());
}

test "memory_demote schema requires key" {
    var mt = MemoryDemoteTool{};
    const t = mt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "key") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "target_category") != null);
}

test "memory_demote rejects target=core" {
    var mt = MemoryDemoteTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"x\",\"target_category\":\"core\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "memory_demote without state_mgr surfaces clear error" {
    var mt = MemoryDemoteTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"some_core_key\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "no postgres state manager") != null);
}

test "memory_demote missing key" {
    var mt = MemoryDemoteTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}
