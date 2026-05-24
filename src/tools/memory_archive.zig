//! V1.6 commit 11 — memory_archive agent tool: soft-delete via bi-temporal
//! close-out.
//!
//! `memory_forget` (existing) is a HARD DELETE — `DELETE FROM memories`,
//! row gone forever, no audit trail. Right for GDPR, sensitive scrubs,
//! test cleanup. Wrong as the default user-facing action because:
//!   - The agent loses the audit trail (can't say "I used to remember X
//!     but you corrected me to Y")
//!   - V1.6 cmt7 typed edges aren't cleaned up alongside (orphan edges
//!     pointing at the deleted source/target)
//!
//! `memory_archive` calls `state_mgr.setMemoryInvalidation` (V1.6 cmt6)
//! which:
//!   - Sets `valid_to = invalid_at = expired_at = now()`, `is_latest = false`
//!   - Cascades to memory_edges (V1.6 cmt7) — every edge whose source OR
//!     target is the archived key gets the same close-out
//!   - Emits `event_type='edge_closed'` per cascaded edge (V1.6 cmt9 graph
//!     history)
//!   - Hides the row from MEMORIES_VALIDITY_FILTER queries (agent +
//!     /brain don't see it) but the row stays as audit evidence
//!
//! Resurrect-on-upsert (W-INT-01 fix): if the agent later writes the
//! same key again with non-core type, the close-out columns clear back
//! to NULL and the row becomes active again. Core rows are exempt
//! (immutable once promoted) — use memory_demote first if needed.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;
const zaki_state = @import("../zaki_state.zig");

pub const MemoryArchiveTool = struct {
    memory: ?Memory = null,
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,
    /// V1.14.12 (Memory audit Finding 8 fix, 2026-05-19) — vector store
    /// runtime, used to deactivate the archived key's vector embedding
    /// so it stops surfacing in semantic recall. Pre-fix, archive
    /// invalidated the SQL row + cascaded edges but left the vector
    /// entry live, causing archived facts to still match vector
    /// queries. memory_forget already does this cleanup
    /// (memory_forget.zig:62) — archive now matches.
    mem_rt: ?*mem_root.MemoryRuntime = null,

    pub const tool_name = "memory_archive";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Soft-close a memory: hide from retrieval but keep as audit evidence (bi-temporal close-out).",
        .use_when = &.{
            "A fact is now stale but the history matters (e.g. an old job title superseded by a new one)",
            "Closing out an edge so the agent recalls 'used to know X but it changed' rather than scrubbing it",
            "Marking a superseded preference without losing the audit trail",
        },
        .do_not_use_for = &.{
            "memory_forget — for hard-delete of sensitive or GDPR-requested data",
            "memory_edit — for modifying a fact in place rather than closing it out",
            "memory_demote — for downgrading importance/tier rather than closing the fact",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("memory_archive", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description =
        "Soft-delete a memory by key. The row is hidden from retrieval but " ++
        "preserved as audit evidence (bi-temporal close-out: valid_to/invalid_at/" ++
        "expired_at populated, is_latest=false). Cascades to typed edges in " ++
        "the graph. Use this instead of memory_forget when you want the agent " ++
        "to remember 'I used to know X but it changed' rather than scrub it " ++
        "completely. Use memory_forget for GDPR/sensitive removal.";
    pub const tool_params =
        \\{"type":"object","properties":{"key":{"type":"string","description":"The key of the memory to archive (soft-delete)"}},"required":["key"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryArchiveTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *MemoryArchiveTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const key = root.getString(args, "key") orelse
            return ToolResult.fail("Missing 'key' parameter");
        if (key.len == 0) return ToolResult.fail("'key' must not be empty");

        // Tenant context (state_mgr + user_id) is the only path to
        // bi-temporal close-out + edge cascade — the Memory backend
        // abstraction doesn't expose either. When unavailable, surface
        // a clear error rather than silent fallback.
        const smgr = self.state_mgr orelse {
            const msg = try std.fmt.allocPrint(allocator, "Soft-delete unavailable (no postgres state manager). Use memory_forget for hard delete: {s}", .{key});
            return ToolResult{ .success = false, .output = msg };
        };
        const uid = self.user_id orelse {
            const msg = try std.fmt.allocPrint(allocator, "Soft-delete unavailable (no tenant user_id). Use memory_forget for hard delete: {s}", .{key});
            return ToolResult{ .success = false, .output = msg };
        };

        // Sanity: the row must exist + be deletable. lookupMemoryLifecycleEntry
        // covers the protected-key case (continuity sentinels, etc.).
        if (self.memory) |m| {
            var lookup = try mem_root.lookupMemoryLifecycleEntry(allocator, m, key);
            defer lookup.deinit(allocator);
            switch (lookup.status) {
                .missing => {
                    const msg = try std.fmt.allocPrint(allocator, "No memory found with key: {s}", .{key});
                    return ToolResult{ .success = true, .output = msg };
                },
                .protected => {
                    const msg = try std.fmt.allocPrint(allocator, "Memory key is protected from archival: {s}", .{key});
                    return ToolResult{ .success = false, .output = msg };
                },
                .editable => {},
            }
        }

        const now = std.time.timestamp();
        smgr.setMemoryInvalidation(uid, key, now, now) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to archive memory '{s}': {s}", .{ key, @errorName(err) });
            return ToolResult{ .success = false, .output = msg };
        };

        // V1.14.12 (Memory audit Finding 8 fix, 2026-05-19) — best-effort
        // vector store cleanup. Pre-fix, archived rows survived in the
        // vector index so semantic recall would still return them.
        // memory_forget.zig:62 already does this; archive now matches.
        if (self.mem_rt) |rt| rt.deleteFromVectorStore(key);

        const msg = try std.fmt.allocPrint(allocator, "Archived memory: {s} (soft-delete; row preserved as audit, edges cascaded, vector deactivated)", .{key});
        return ToolResult{ .success = true, .output = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "memory_archive tool name" {
    var mt = MemoryArchiveTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_archive", t.name());
}

test "memory_archive schema requires key" {
    var mt = MemoryArchiveTool{};
    const t = mt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "key") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "required") != null);
}

test "memory_archive without state_mgr surfaces clear error" {
    var mt = MemoryArchiveTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"to_archive\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "no postgres state manager") != null);
}

test "memory_archive missing key" {
    var mt = MemoryArchiveTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "memory_archive empty key" {
    var mt = MemoryArchiveTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}
