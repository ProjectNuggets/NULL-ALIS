const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;
const zaki_state = @import("../zaki_state.zig");
const build_options = @import("build_options");
const env_rebrand = @import("../env_rebrand.zig");
const config_types = @import("../config_types.zig");
const zaki_postgres = @import("../memory/engines/zaki_postgres.zig");

const log = std.log.scoped(.memory_edit);

/// Memory edit tool — explicitly updates an existing mutable memory by key.
pub const MemoryEditTool = struct {
    memory: ?Memory = null,
    mem_rt: ?*mem_root.MemoryRuntime = null,
    /// Package 3 Task 1 (M2) — tenant context for the bi-temporal supersede
    /// path. When bound (postgres tenant lane), an edit snapshots the prior
    /// version into a born-closed `history/<key>/<now>-<nanos>` row via
    /// `Manager.editMemorySupersede` instead of mutating in place. Wired the
    /// same way as memory_archive (bindStateMgrTenant in tools/root.zig). When
    /// null (no postgres lane, e.g. file-tenant/CLI/SQLite), the tool falls
    /// back to the legacy in-place `m.store` update.
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "memory_edit";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Edit a mutable memory by key; the prior version is auto-archived and category/scope preserved.",
        .use_when = &.{
            "Correcting a typo or imprecise wording in an existing fact",
            "Refreshing a memory whose surface text needs to evolve but whose identity stays the same",
            "Re-anchoring a fact's content after the underlying truth shifted but the entity is unchanged",
        },
        .do_not_use_for = &.{
            "memory_store — for creating a brand-new fact rather than editing an existing one",
            "memory_demote — for unlocking a core memory that the immortality guard is blocking",
            "memory_archive — for closing out a fact instead of editing it",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("memory_edit", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description = "Edit an existing mutable memory by key. Preserves the original category and scope.";
    pub const tool_params =
        \\{"type":"object","properties":{"key":{"type":"string","description":"Existing memory key to edit"},"content":{"type":"string","description":"Replacement memory content"}},"required":["key","content"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryEditTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *MemoryEditTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const key = root.getString(args, "key") orelse
            return ToolResult.fail("Missing 'key' parameter");
        if (key.len == 0) return ToolResult.fail("'key' must not be empty");

        const content = root.getString(args, "content") orelse
            return ToolResult.fail("Missing 'content' parameter");
        if (content.len == 0) return ToolResult.fail("'content' must not be empty");

        const m = self.memory orelse {
            const msg = try std.fmt.allocPrint(allocator, "Memory backend not configured. Cannot edit: {s}", .{key});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };

        var lookup = try mem_root.lookupMemoryLifecycleEntry(allocator, m, key);
        defer lookup.deinit(allocator);
        switch (lookup.status) {
            .missing => {
                const msg = try std.fmt.allocPrint(allocator, "No memory found with key: {s}", .{key});
                return ToolResult{ .success = false, .error_msg = msg, .output = "" };
            },
            .protected => {
                const msg = try std.fmt.allocPrint(allocator, "Memory key is not editable: {s}", .{key});
                return ToolResult{ .success = false, .error_msg = msg, .output = "" };
            },
            .editable => {},
        }
        const existing = lookup.entry.?;

        if (std.mem.eql(u8, existing.content, content)) {
            const msg = try std.fmt.allocPrint(allocator, "Memory unchanged: {s}", .{key});
            return ToolResult{ .success = true, .output = msg };
        }

        // Package 3 Task 1 (M2) — bi-temporal supersede on the postgres tenant
        // lane: snapshot the prior version into a born-closed history row and
        // update the live key in place (stable identity + injection). Falls
        // back to the legacy in-place store when no tenant Manager is bound
        // (file-tenant/CLI/SQLite) — the Memory vtable has no supersede path.
        // The Manager is reached via the tool's state_mgr handle, mirroring
        // memory_archive.zig's access pattern exactly.
        if (self.state_mgr) |smgr| {
            if (self.user_id) |uid| {
                const editor_now = std.time.timestamp();
                const archived_key = smgr.editMemorySupersede(allocator, uid, existing.key, content, editor_now) catch |err| {
                    log.warn("memory_edit supersede failed user_id={d} key='{s}' err={s}", .{ uid, key, @errorName(err) });
                    const msg = try std.fmt.allocPrint(allocator, "Failed to edit memory '{s}': {s}", .{ key, @errorName(err) });
                    return ToolResult{ .success = false, .error_msg = msg, .output = "" };
                };
                defer if (archived_key) |hk| allocator.free(hk);

                // Refresh the live key's vector so semantic recall matches the
                // NEW content. The born-closed history row is intentionally
                // NOT embedded (its old wording must not pollute recall).
                if (self.mem_rt) |rt| {
                    _ = rt.syncVectorAfterStore(allocator, existing.key, content);
                }

                // Fix-wave (review I2): claim archival ONLY when the snapshot
                // row was actually inserted — editMemorySupersede returns the
                // history key it wrote, or null when the INSERT hit
                // ON CONFLICT DO NOTHING. That path is practically impossible
                // now that history keys carry a nanosecond component, but if
                // it ever fires the tool must not name a row that does not
                // hold this edit's prior version.
                const msg = if (archived_key) |hk|
                    try std.fmt.allocPrint(
                        allocator,
                        "Edited memory: {s} (prior version archived to {s})",
                        .{ key, hk },
                    )
                else
                    try std.fmt.allocPrint(
                        allocator,
                        "Edited memory: {s} (prior-version snapshot NOT archived: an identical history row already existed; the old content survives only in the edit_supersede audit event)",
                        .{key},
                    );
                return ToolResult{ .success = true, .output = msg };
            }
        }

        // Fallback: legacy in-place update (no bi-temporal history).
        m.store(existing.key, content, existing.category, existing.session_id) catch |err| {
            log.warn("memory_edit store failed key='{s}' err={s}", .{ key, @errorName(err) });
            const msg = try std.fmt.allocPrint(allocator, "Failed to edit memory '{s}': {s}", .{ key, @errorName(err) });
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };

        if (self.mem_rt) |rt| {
            _ = rt.syncVectorAfterStore(allocator, existing.key, content);
        }

        const msg = try std.fmt.allocPrint(allocator, "Edited memory: {s}", .{key});
        return ToolResult{ .success = true, .output = msg };
    }
};

test "memory_edit tool name" {
    var mt = MemoryEditTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_edit", t.name());
}

test "memory_edit updates existing mutable key" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("user_name", "Nova", .core, null);

    var mt = MemoryEditTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"user_name\",\"content\":\"Nova Alis\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    const entry = (try mem.get(allocator, "user_name")) orelse return error.TestUnexpectedResult;
    defer entry.deinit(allocator);
    try std.testing.expectEqualStrings("Nova Alis", entry.content);
    try std.testing.expect(entry.category.eql(.core));
    try std.testing.expect(entry.session_id == null);
}

test "memory_edit rejects missing key" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();

    var mt = MemoryEditTool{ .memory = sqlite_mem.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"missing\",\"content\":\"x\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    defer if (result.error_msg) |em| allocator.free(em);
    try std.testing.expect(!result.success);
}

test "memory_edit rejects system-managed key" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("summary_latest/agent:zaki-bot:user:1:main", "focus: shipping", .core, null);

    var mt = MemoryEditTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"summary_latest/agent:zaki-bot:user:1:main\",\"content\":\"focus: changed\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    defer if (result.error_msg) |em| allocator.free(em);
    try std.testing.expect(!result.success);
}

// Package 3 Task 1 (M2) — memory_edit tool supersedes with a bi-temporal
// history row when a tenant Manager is bound (mirrors memory_archive's
// state_mgr + user_id access). Edit oolong → sencha; a validity-filtered
// read (getMemory) NEVER returns oolong-as-current, and the born-closed
// history row holds the OLD "oolong". Uses the same Postgres backend the
// Memory vtable talks to so the tool exercises the real supersede path.
test "memory_edit supersede tool: edit oolong to sencha, history row holds oolong" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const test_url = (env_rebrand.getEnvOwnedWithRebrand(allocator, "NULLALIS_POSTGRES_TEST_URL", "NULLCLAW_POSTGRES_TEST_URL") catch return error.SkipZigTest) orelse return error.SkipZigTest;
    defer allocator.free(test_url);

    var schema_buf: [96]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buf, "zaki_bot_test_{d}", .{std.time.microTimestamp()});
    const cfg = config_types.StateConfig{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    };

    var mgr = try zaki_state.Manager.init(allocator, cfg);
    defer mgr.deinit();
    try mgr.migrate();
    try mgr.provisionUser(7, "/tmp/nullalis-zaki-bot-test-user-7/workspace");

    // Seed a live, editable fact holding "oolong".
    try mgr.upsertMemory(7, "fav_tea", "oolong", .core, null);

    // Wire the tool as production does: the Memory vtable (for the lifecycle
    // lookup) is the ZakiPostgresMemory over the SAME Manager, plus the tenant
    // state_mgr + user_id (for the supersede path).
    var pg_mem = zaki_postgres.ZakiPostgresMemory.init(allocator, &mgr, 7);
    var mt = MemoryEditTool{ .memory = pg_mem.memory(), .state_mgr = &mgr, .user_id = 7 };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"fav_tea\",\"content\":\"sencha\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    defer if (result.error_msg) |em| allocator.free(em);
    try std.testing.expect(result.success);

    // The tool names the born-closed history key in its output so the audit
    // trail is discoverable. Parse it back out. The key's timestamp segment
    // is `<editor_now>-<nanos>` (fix-wave I2: the nanosecond component keeps
    // same-second edits collision-free), so consume digits AND the dash.
    const marker = "history/fav_tea/";
    const idx = std.mem.indexOf(u8, result.output, marker) orelse {
        std.debug.print("FAIL: tool output did not name the history key: {s}\n", .{result.output});
        return error.TestUnexpectedResult;
    };
    var end = idx + marker.len;
    while (end < result.output.len and (std.ascii.isDigit(result.output[end]) or result.output[end] == '-')) : (end += 1) {}
    const history_key = result.output[idx..end];

    // Recall/get NEVER returns oolong-as-current: the live key reads "sencha".
    {
        const live = try mgr.getMemory(allocator, 7, "fav_tea");
        try std.testing.expect(live != null);
        defer live.?.deinit(allocator);
        try std.testing.expectEqualStrings("sencha", live.?.content);
    }

    // The history row is validity-filtered OUT of normal reads.
    {
        const hidden = try mgr.getMemory(allocator, 7, history_key);
        try std.testing.expect(hidden == null);
    }

    // But getMemoryAnyValidity surfaces the born-closed history row holding
    // the OLD "oolong".
    {
        const audit = try mgr.getMemoryAnyValidity(allocator, 7, history_key);
        try std.testing.expect(audit != null);
        defer audit.?.deinit(allocator);
        try std.testing.expectEqualStrings("oolong", audit.?.content);
    }
}
