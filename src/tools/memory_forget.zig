const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;
const observability = @import("../observability.zig");
const zaki_state = @import("../zaki_state.zig");
const build_options = @import("build_options");
const env_rebrand = @import("../env_rebrand.zig");
const config_types = @import("../config_types.zig");
const zaki_postgres = @import("../memory/engines/zaki_postgres.zig");

const log = std.log.scoped(.memory_forget);

/// Memory forget tool — lets the agent delete a memory entry.
/// When a MemoryRuntime is available, also cleans up the vector store.
///
/// Package 3 fix-wave Task 2 (M3): with a tenant Manager bound, forget is
/// INFORMATION-scoped — the named key AND every other live KNOWLEDGE row
/// holding byte-identical content (same SHA-256 content_hash) are
/// hard-deleted (GDPR erasure must reach the behavior copies of the
/// content, not just the named row). Cascade guards (fix-wave I2/I3):
/// twins under protected system families are skipped (same predicate as
/// direct curation); `autosave_*` twins are DOWNGRADED to bi-temporal
/// close-out instead of hard-delete (audit rows are never destroyed —
/// live recall stops seeing them either way); twins with content under
/// 16 bytes are only REPORTED (byte identity on short generic values
/// does not prove same-information). Near-duplicates (similar wording,
/// different hash) are reported in the result but never auto-deleted.
pub const MemoryForgetTool = struct {
    memory: ?Memory = null,
    mem_rt: ?*mem_root.MemoryRuntime = null,
    /// Package 3 fix-wave Task 2 (M3) — tenant context for the
    /// information-scoped hard-delete (`Manager.forgetInformationScoped`).
    /// Wired via bindStateMgrTenant (tools/root.zig), mirroring
    /// memory_archive. When null (file-tenant/CLI/SQLite lanes), the tool
    /// falls back to the legacy single-key `m.forget` path.
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "memory_forget";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Hard-delete a memory by key (GDPR-grade scrub; no audit trail kept).",
        .use_when = &.{
            "User explicitly asks to delete or forget specific personal information",
            "GDPR / data-subject erasure request that requires the row to disappear",
            "Cleaning sensitive content that must not survive as audit evidence",
        },
        .do_not_use_for = &.{
            "memory_archive — for soft-close that keeps the row as audit evidence",
            "memory_purge_topic — for bulk-removal of agent-generated artifacts on a topic",
            "memory_edit — for correcting a fact rather than scrubbing it",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("memory_forget", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description =
        "Remove a memory by key. Use to delete outdated facts or sensitive " ++
        "data. Deletion is information-scoped: other rows holding " ++
        "byte-identical content are removed along with the named key " ++
        "(autosave audit copies are closed rather than destroyed; protected " ++
        "system rows and very short content are skipped and reported), and " ++
        "near-duplicate rows (similar wording) are listed in the result " ++
        "so you can offer to forget them too.";
    pub const tool_params =
        \\{"type":"object","properties":{"key":{"type":"string","description":"The key of the memory to forget"}},"required":["key"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryForgetTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// S5 (2026-05-29, prod-readiness) — public entry point wraps the
    /// underlying executor with latency + result emit. See the parallel
    /// pattern in `memory_store.zig` for rationale.
    pub fn execute(self: *MemoryForgetTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const start_ms = std.time.milliTimestamp();
        const result = self.executeInner(allocator, args) catch |err| {
            const elapsed_ms: u64 = @intCast(@max(@as(i64, 0), std.time.milliTimestamp() - start_ms));
            observability.recordMetricGlobal(.{ .memory_op_total = .{ .op = "forget", .result = "err" } });
            observability.recordMetricGlobal(.{ .memory_op_latency_ms = .{ .op = "forget", .value = elapsed_ms } });
            return err;
        };
        const elapsed_ms: u64 = @intCast(@max(@as(i64, 0), std.time.milliTimestamp() - start_ms));
        const label: []const u8 = if (result.success) "ok" else "err";
        observability.recordMetricGlobal(.{ .memory_op_total = .{ .op = "forget", .result = label } });
        observability.recordMetricGlobal(.{ .memory_op_latency_ms = .{ .op = "forget", .value = elapsed_ms } });
        return result;
    }

    fn executeInner(self: *MemoryForgetTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const key = root.getString(args, "key") orelse
            return ToolResult.fail("Missing 'key' parameter");
        if (key.len == 0) return ToolResult.fail("'key' must not be empty");

        const m = self.memory orelse {
            const msg = try std.fmt.allocPrint(allocator, "Memory backend not configured. Cannot forget: {s}", .{key});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };

        var lookup = try mem_root.lookupMemoryLifecycleEntry(allocator, m, key);
        defer lookup.deinit(allocator);
        switch (lookup.status) {
            .missing => {
                // Idempotent (matches the existing behavior). Caller-
                // facing message stays in `output` because the call
                // succeeded (nothing to do).
                const msg = try std.fmt.allocPrint(allocator, "No memory found with key: {s}", .{key});
                return ToolResult{ .success = true, .output = msg };
            },
            .protected => {
                const msg = try std.fmt.allocPrint(allocator, "Memory key is not deletable: {s}", .{key});
                return ToolResult{ .success = false, .error_msg = msg, .output = "" };
            },
            .editable => {},
        }

        // Package 3 fix-wave Task 2 (M3) — information-scoped hard delete on
        // the postgres tenant lane: the named key plus every live row with
        // the identical content_hash is deleted (mirrors memory_archive's
        // exact-hash cascade with forget's hard-delete semantics). Near-dups
        // are reported, never auto-deleted. Falls through to the legacy
        // single-key path when no tenant Manager is bound.
        if (self.state_mgr) |smgr| {
            if (self.user_id) |uid| {
                const now = std.time.timestamp();
                var scope = smgr.forgetInformationScoped(allocator, uid, key, now) catch |err| switch (err) {
                    error.MemoryKeyNotFound => {
                        // Same idempotent message as the lookup-missing path.
                        const msg = try std.fmt.allocPrint(allocator, "No memory found with key: {s}", .{key});
                        return ToolResult{ .success = true, .output = msg };
                    },
                    else => {
                        log.warn("memory_forget forgetInformationScoped failed user_id={d} key='{s}' err={s}", .{ uid, key, @errorName(err) });
                        const msg = try std.fmt.allocPrint(allocator, "Failed to forget memory '{s}': {s}", .{ key, @errorName(err) });
                        return ToolResult{ .success = false, .error_msg = msg, .output = "" };
                    },
                };
                defer scope.deinit(allocator);

                // Best-effort vector store cleanup for the primary + every
                // exact-hash copy the cascade deleted.
                if (self.mem_rt) |rt| {
                    rt.deleteFromVectorStore(key);
                    for (scope.exact_closed) |deleted_key| rt.deleteFromVectorStore(deleted_key);
                }

                if (!scope.primary_closed and scope.exact_closed.len == 0) {
                    // Row raced away between read and delete, nothing else
                    // matched — keep the idempotent contract.
                    const msg = try std.fmt.allocPrint(allocator, "No memory found with key: {s}", .{key});
                    return ToolResult{ .success = true, .output = msg };
                }

                var out: std.ArrayListUnmanaged(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.writer(allocator).print("Forgot memory: {s}", .{key});
                if (scope.exact_closed.len > 0) {
                    // "removed", not "deleted": autosave twins in this list
                    // were closed (audit preserved), knowledge twins were
                    // hard-deleted — see forgetInformationScoped (fix-wave I3).
                    try out.writer(allocator).print("\nAlso removed {d} exact-content {s}: ", .{
                        scope.exact_closed.len,
                        if (scope.exact_closed.len == 1) @as([]const u8, "copy") else "copies",
                    });
                    for (scope.exact_closed, 0..) |deleted_key, i| {
                        if (i > 0) try out.appendSlice(allocator, ", ");
                        try out.appendSlice(allocator, deleted_key);
                    }
                }
                if (scope.near_dups.len > 0) {
                    try out.appendSlice(allocator, "\nRelated rows with similar or identical wording found (NOT deleted): ");
                    for (scope.near_dups, 0..) |nd, i| {
                        if (i > 0) try out.appendSlice(allocator, ", ");
                        try out.appendSlice(allocator, nd.key);
                    }
                    try out.appendSlice(allocator, " — review them and forget separately if the user confirms.");
                }
                return ToolResult{ .success = true, .output = try out.toOwnedSlice(allocator) };
            }
        }

        const forgotten = m.forget(key) catch |err| {
            log.warn("memory_forget delete failed key='{s}' err={s}", .{ key, @errorName(err) });
            const msg = try std.fmt.allocPrint(allocator, "Failed to forget memory '{s}': {s}", .{ key, @errorName(err) });
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };

        if (forgotten) {
            // Best-effort vector store cleanup
            if (self.mem_rt) |rt| {
                rt.deleteFromVectorStore(key);
            }
            const msg = try std.fmt.allocPrint(allocator, "Forgot memory: {s}", .{key});
            return ToolResult{ .success = true, .output = msg };
        } else {
            const msg = try std.fmt.allocPrint(allocator, "No memory found with key: {s}", .{key});
            return ToolResult{ .success = true, .output = msg };
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "memory_forget tool name" {
    var mt = MemoryForgetTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_forget", t.name());
}

test "memory_forget schema has key" {
    var mt = MemoryForgetTool{};
    const t = mt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "key") != null);
}

test "memory_forget executes without backend" {
    var mt = MemoryForgetTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"temp\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |em| std.testing.allocator.free(em);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not configured") != null);
}

test "memory_forget missing key" {
    var mt = MemoryForgetTool{};
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "memory_forget with real backend key not found" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryForgetTool{ .memory = backend.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"nonexistent\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "No memory found") != null);
}

test "memory_forget with real backend returns appropriate message" {
    const NoneMemory = mem_root.NoneMemory;
    var backend = NoneMemory.init();
    defer backend.deinit();

    var mt = MemoryForgetTool{ .memory = backend.memory() };
    const t = mt.tool();
    // NoneMemory.forget always returns false (nothing to forget)
    const parsed = try root.parseTestArgs("{\"key\": \"test_key\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "No memory found with key: test_key") != null);
}

test "memory_forget rejects system-managed key" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("summary_latest/agent:zaki-bot:user:1:main", "focus: shipping", .core, null);

    var mt = MemoryForgetTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"summary_latest/agent:zaki-bot:user:1:main\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    defer if (result.error_msg) |em| allocator.free(em);
    try std.testing.expect(!result.success);
}

test "memory_forget deletes editable key" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("user_name", "Nova", .core, null);

    var mt = MemoryForgetTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"user_name\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect((try mem.get(allocator, "user_name")) == null);
}

// Package 3 fix-wave Task 2 (M3 cure, forget flavor) — memory_forget mirrors
// the information-scoped archive with HARD-delete semantics: exact-hash
// copies are deleted alongside the named key (GDPR erasure must reach the
// autosave/behavior copies of the content, not just the named row); near-
// dups are reported, never auto-deleted.
test "M3 memory_forget hard-deletes exact-hash copies and reports near-dups" {
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
    try mgr.provisionUser(11, "/tmp/nullalis-zaki-bot-test-user-11/workspace");

    // Same M3 leak shape as the archive test: byte-identical content under
    // two keys, a reworded near-dup, an unrelated row.
    const info = "User salary is 90000 riyal at thmanyah";
    try mgr.upsertMemory(11, "extracted_m3fgt001", info, .core, null);
    try mgr.upsertMemory(11, "durable_fact/behavior/00feedface00beef", info, .core, null);
    const reworded = "User works at thmanyah for a 90k package";
    try mgr.upsertMemory(11, "extracted_m3fgtnear", reworded, .core, null);
    try mgr.upsertMemory(11, "extracted_m3fgtunrl", "User lives in Hamburg", .core, null);

    var pg_mem = zaki_postgres.ZakiPostgresMemory.init(allocator, &mgr, 11);
    var mt = MemoryForgetTool{ .memory = pg_mem.memory(), .state_mgr = &mgr, .user_id = 11 };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"extracted_m3fgt001\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    defer if (result.error_msg) |em| allocator.free(em);
    try std.testing.expect(result.success);

    // HARD delete: the named row is GONE (not merely validity-closed).
    {
        const primary = try mgr.getMemoryAnyValidity(allocator, 11, "extracted_m3fgt001");
        try std.testing.expect(primary == null);
    }
    // THE M3 FIX (forget flavor): the byte-identical copy is gone too.
    {
        const copy = try mgr.getMemoryAnyValidity(allocator, 11, "durable_fact/behavior/00feedface00beef");
        try std.testing.expect(copy == null);
    }
    // The reworded near-dup survives untouched (reported only).
    {
        const near = try mgr.getMemory(allocator, 11, "extracted_m3fgtnear");
        try std.testing.expect(near != null);
        defer near.?.deinit(allocator);
    }
    // The tool result names the deleted copy and the near-dup, not the
    // unrelated row.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "durable_fact/behavior/00feedface00beef") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "extracted_m3fgtnear") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "extracted_m3fgtunrl") == null);
}
