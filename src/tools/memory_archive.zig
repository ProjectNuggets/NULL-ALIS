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
//! `memory_archive` calls `state_mgr.archiveInformationScoped` (Package 3
//! fix-wave Task 2, M3) which per closed row applies `setMemoryInvalidation`
//! (V1.6 cmt6):
//!   - Sets `valid_to = invalid_at = expired_at = now()`, `is_latest = false`
//!   - Cascades to memory_edges (V1.6 cmt7) — every edge whose source OR
//!     target is the archived key gets the same close-out
//!   - Emits `event_type='edge_closed'` per cascaded edge (V1.6 cmt9 graph
//!     history)
//!   - Hides the row from MEMORIES_VALIDITY_FILTER queries (agent +
//!     /brain don't see it) but the row stays as audit evidence
//!
//! M3 (information-scoped archive): archiving a key ALSO auto-closes every
//! other live row with the identical SHA-256 content_hash (byte-identical
//! copies — e.g. the learning fast path's `durable_fact/behavior/<fnv>`
//! snapshot of the same user message, autosaves). Cascade guards (fix-wave
//! I2/I3): twins under protected system families are skipped — the same
//! `isEditableMemoryEntry` predicate the direct-curation pre-check below
//! applies to the named key (`autosave_*` deliberately excepted: the
//! byte-identical autosave copy IS the recall leak, and close-out keeps it
//! as audit); twins with content under 16 bytes are only REPORTED, never
//! swept. Near-duplicates (same salient token, different hash) are REPORTED
//! in the tool result but never auto-closed — the agent offers them to the
//! user for follow-up curation.
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
const build_options = @import("build_options");
const env_rebrand = @import("../env_rebrand.zig");
const config_types = @import("../config_types.zig");
const zaki_postgres = @import("../memory/engines/zaki_postgres.zig");

const log = std.log.scoped(.memory_archive);

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
        "the graph, and archiving is information-scoped: other rows holding " ++
        "byte-identical content are closed automatically (protected system " ++
        "rows and very short content are skipped and reported instead), and " ++
        "near-duplicate rows (similar wording) are listed in the result so " ++
        "you can offer to archive them too. Use this instead of memory_forget " ++
        "when you want the agent to remember 'I used to know X but it changed' " ++
        "rather than scrub it completely. Use memory_forget for GDPR/sensitive " ++
        "removal.";
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
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };
        const uid = self.user_id orelse {
            const msg = try std.fmt.allocPrint(allocator, "Soft-delete unavailable (no tenant user_id). Use memory_forget for hard delete: {s}", .{key});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
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
                    return ToolResult{ .success = false, .error_msg = msg, .output = "" };
                },
                .editable => {},
            }
        }

        // Package 3 fix-wave Task 2 (M3) — INFORMATION-scoped archive: the
        // named key is closed via the same setMemoryInvalidation semantics
        // as before, PLUS every other live row with the identical
        // content_hash is auto-closed (the M3 leak: a byte-identical
        // `durable_fact/behavior/*` or autosave copy survived a single-key
        // archive and warm-start recall re-injected the information).
        // Near-duplicates (different hash, shared salient token) are only
        // REPORTED — the agent offers follow-up curation, never auto-closes.
        const now = std.time.timestamp();
        var scope = smgr.archiveInformationScoped(allocator, uid, key, now) catch |err| switch (err) {
            error.MemoryKeyNotFound => {
                // Manager-level miss (no Memory vtable was bound for the
                // lifecycle pre-check, or the row raced away). Same
                // idempotent success message as the lookup-missing path.
                const msg = try std.fmt.allocPrint(allocator, "No memory found with key: {s}", .{key});
                return ToolResult{ .success = true, .output = msg };
            },
            else => {
                log.warn("memory_archive archiveInformationScoped failed user_id={d} key='{s}' err={s}", .{ uid, key, @errorName(err) });
                const msg = try std.fmt.allocPrint(allocator, "Failed to archive memory '{s}': {s}", .{ key, @errorName(err) });
                return ToolResult{ .success = false, .error_msg = msg, .output = "" };
            },
        };
        defer scope.deinit(allocator);

        // V1.14.12 (Memory audit Finding 8 fix, 2026-05-19) — best-effort
        // vector store cleanup. Pre-fix, archived rows survived in the
        // vector index so semantic recall would still return them.
        // memory_forget.zig already does this; archive matches. M3 extends
        // the cleanup to every exact-hash copy the cascade closed.
        if (self.mem_rt) |rt| {
            rt.deleteFromVectorStore(key);
            for (scope.exact_closed) |closed_key| rt.deleteFromVectorStore(closed_key);
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.writer(allocator).print("Archived memory: {s} (soft-delete; row preserved as audit, edges cascaded, vector deactivated)", .{key});
        if (scope.exact_closed.len > 0) {
            try out.writer(allocator).print("\nAlso closed {d} exact-content {s}: ", .{
                scope.exact_closed.len,
                if (scope.exact_closed.len == 1) @as([]const u8, "copy") else "copies",
            });
            for (scope.exact_closed, 0..) |closed_key, i| {
                if (i > 0) try out.appendSlice(allocator, ", ");
                try out.appendSlice(allocator, closed_key);
            }
        }
        if (scope.near_dups.len > 0) {
            try out.appendSlice(allocator, "\nRelated rows with similar or identical wording found (NOT closed): ");
            for (scope.near_dups, 0..) |nd, i| {
                if (i > 0) try out.appendSlice(allocator, ", ");
                try out.appendSlice(allocator, nd.key);
            }
            try out.appendSlice(allocator, " — review them and archive separately if the user confirms.");
        }
        return ToolResult{ .success = true, .output = try out.toOwnedSlice(allocator) };
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
    defer if (result.error_msg) |em| std.testing.allocator.free(em);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "no postgres state manager") != null);
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

// Package 3 fix-wave Task 2 (M3 cure) — archive is INFORMATION-scoped, not
// key-scoped. Two live rows carry byte-identical content (the M3 leak shape:
// an auto-promoted durable_fact/behavior/<fnv> copy of a user message + an
// extracted_* row). Archiving ONE key must close BOTH (identical
// content_hash → zero-false-positive auto-close), report the closed copies,
// and LIST — without closing — a reworded near-duplicate. Mirrors the
// wiring pattern of memory_edit's supersede tool test.
test "M3 memory_archive closes exact-hash copies and reports near-dups" {
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
    try mgr.provisionUser(9, "/tmp/nullalis-zaki-bot-test-user-9/workspace");

    // Seed the M3 leak shape: identical content under two keys + a reworded
    // near-dup + an unrelated row.
    const info = "User prefers thmanyah podcasts on Fridays";
    try mgr.upsertMemory(9, "extracted_m3cafe01", info, .core, null);
    try mgr.upsertMemory(9, "durable_fact/behavior/00deadbeef00cafe", info, .core, null);
    const reworded = "User enjoys thmanyah episodes weekly";
    try mgr.upsertMemory(9, "extracted_m3nearby1", reworded, .core, null);
    try mgr.upsertMemory(9, "extracted_m3unrel99", "User lives in Hamburg", .core, null);

    var pg_mem = zaki_postgres.ZakiPostgresMemory.init(allocator, &mgr, 9);
    var mt = MemoryArchiveTool{ .memory = pg_mem.memory(), .state_mgr = &mgr, .user_id = 9 };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\": \"extracted_m3cafe01\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    defer if (result.error_msg) |em| allocator.free(em);
    try std.testing.expect(result.success);

    // The named key is closed (validity-filtered out).
    {
        const primary = try mgr.getMemory(allocator, 9, "extracted_m3cafe01");
        try std.testing.expect(primary == null);
    }
    // THE M3 FIX: the byte-identical behavior copy is closed too.
    {
        const copy = try mgr.getMemory(allocator, 9, "durable_fact/behavior/00deadbeef00cafe");
        try std.testing.expect(copy == null);
    }
    // Soft-delete, not scrub: both rows survive as audit evidence.
    {
        const audit = try mgr.getMemoryAnyValidity(allocator, 9, "durable_fact/behavior/00deadbeef00cafe");
        try std.testing.expect(audit != null);
        defer audit.?.deinit(allocator);
        try std.testing.expectEqualStrings(info, audit.?.content);
    }
    // The reworded near-dup is NOT closed (reported only).
    {
        const near = try mgr.getMemory(allocator, 9, "extracted_m3nearby1");
        try std.testing.expect(near != null);
        defer near.?.deinit(allocator);
    }
    // listMemories surfaces neither closed row, still surfaces the near-dup.
    {
        const rows = try mgr.listMemories(allocator, 9, null, null);
        defer {
            for (rows) |e| e.deinit(allocator);
            allocator.free(rows);
        }
        var saw_near = false;
        for (rows) |e| {
            try std.testing.expect(!std.mem.eql(u8, e.key, "extracted_m3cafe01"));
            try std.testing.expect(!std.mem.eql(u8, e.key, "durable_fact/behavior/00deadbeef00cafe"));
            if (std.mem.eql(u8, e.key, "extracted_m3nearby1")) saw_near = true;
        }
        try std.testing.expect(saw_near);
    }
    // The tool result reports what happened: the exact-closed copy by key,
    // the near-dup by key (curation offer), and NOT the unrelated row.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "durable_fact/behavior/00deadbeef00cafe") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "extracted_m3nearby1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "extracted_m3unrel99") == null);
}
