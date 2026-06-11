const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const root = @import("../root.zig");
const zaki_state = @import("../../zaki_state.zig");
const tools_mod = @import("../../tools/root.zig");
const sentry_runtime = @import("../../sentry_runtime.zig");

/// Returned by the write boundary when the per-turn authenticated tenant
/// (the threadlocal `ToolTenantContext.numeric_user_id`) does not match the
/// `user_id` this memory handle was bound to at TenantRuntime init. A
/// fail-closed guard: the cross-tenant write is REFUSED before it can reach
/// the database, rather than relying on a downstream FK to catch it. See
/// W1.1 (tenant write-boundary assertion).
pub const TenantWriteBoundaryViolation = error.TenantWriteBoundaryViolation;

pub const ZakiPostgresMemory = struct {
    allocator: std.mem.Allocator,
    manager: *zaki_state.Manager,
    user_id: i64,
    owns_self: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, manager: *zaki_state.Manager, user_id: i64) Self {
        return .{
            .allocator = allocator,
            .manager = manager,
            .user_id = user_id,
        };
    }

    pub fn deinit(_: *Self) void {}

    pub fn memory(self: *Self) root.Memory {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn implName(_: *anyopaque) []const u8 {
        return "zaki_postgres";
    }

    fn implStore(ptr: *anyopaque, key: []const u8, content: []const u8, category: root.MemoryCategory, session_id: ?[]const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.assertTenantWriteBoundary();
        try self.manager.upsertMemory(self.user_id, key, content, category, session_id);
        // V1.7 Item 1: when a session summary lands, record a structured
        // episode event so sessions are queryable by the brain timeline.
        // Key shape: timeline_summary/{session_id}/{ts}
        // MR-01 design note: multiple episode events per session are intentional
        // — each compaction checkpoint produces a new timeline_summary key
        // (different {ts}), so a long session with N compactions gets N episode
        // events, each representing a knowledge snapshot. This is not a
        // deduplication bug; it is the correct semantics for episodic recall.
        // Best-effort — a logging failure must not break the store path.
        if (std.mem.startsWith(u8, key, "timeline_summary/")) {
            const after_prefix = key["timeline_summary/".len..];
            if (std.mem.lastIndexOfScalar(u8, after_prefix, '/')) |slash| {
                const ep_session = after_prefix[0..slash];
                self.manager.insertEpisodeEvent(self.user_id, ep_session, content, "checkpoint") catch |err| {
                    std.log.warn("zaki_postgres: episode event write failed session={s}: {}", .{ ep_session, err });
                };
            }
        }
    }

    /// V1.5 day-3 — write path with attached JSONB metadata. Used by
    /// the `compose_memory` tool to land synthesized memories with
    /// `{"synthesized_by":"agent","references":["k1","k2"]}` provenance
    /// alongside the synthesis content. Routes to
    /// `state_mgr.upsertMemoryWithMetadata` which also writes a
    /// `compose` row to the `memory_events` audit table for free V1.6
    /// traversal-logging substrate.
    fn implStoreWithMetadata(
        ptr: *anyopaque,
        key: []const u8,
        content: []const u8,
        category: root.MemoryCategory,
        session_id: ?[]const u8,
        metadata_json: []const u8,
    ) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.assertTenantWriteBoundary();
        try self.manager.upsertMemoryWithMetadata(self.user_id, key, content, category, session_id, metadata_json);
    }

    /// W1.1 — fail-closed tenant write-boundary assertion.
    ///
    /// Root cause: a staging turn for user 16 once persisted memory under
    /// user_id 33 (a just-deleted, different user) — caught only by a postgres
    /// FK because 33 was gone. The autosave `user_id` is bound once at
    /// `TenantRuntime` init and is structurally per-user, so under normal load
    /// it is correct; the contamination was a cache/lifecycle artifact (a
    /// stale cached runtime handed to the wrong turn). This guard converts
    /// isolation from "true by construction" into a GUARANTEE: even if a
    /// future lifecycle bug hands a turn the wrong memory handle, the write is
    /// REFUSED before it reaches the database — fail-closed and LOUD.
    ///
    /// Mechanism: every real turn path (gateway `processMessageWithTurnOptions`,
    /// daemon `runCronAgentTurnWithBus`, channel-loop inbound dispatch) installs
    /// a per-turn `ToolTenantContext` whose `numeric_user_id` is the turn's
    /// authenticated user. We compare it to the `user_id` this handle was bound
    /// to. On mismatch: refuse + log + emit to the observer/Sentry. When the
    /// context is UNSET (`numeric_user_id == null` — e.g. an internal/MCP path
    /// that never installs the threadlocal) we SKIP the check and proceed: a
    /// missing context must never block a legitimate write.
    fn assertTenantWriteBoundary(self: *Self) !void {
        const ctx_user_id = tools_mod.getTenantContext().numeric_user_id orelse {
            // Context unset: no authenticated tenant to compare against. Never
            // refuse on this basis; just note the check was skipped.
            std.log.debug(
                "zaki_postgres: tenant write-boundary check skipped (context unset) bound_user_id={d}",
                .{self.user_id},
            );
            return;
        };
        if (ctx_user_id == self.user_id) return; // happy path — zero behavior change

        // Cross-tenant write: a lifecycle bug handed this turn the wrong memory
        // handle. Refuse before touching the DB, and make it observable.
        //
        // AGENTS.md §3.6: a `log.err` trips Zig 0.15's default test runner's
        // err-counter and fails the test even when the test is verifying this
        // exact refusal. The loud stderr line is a production audit signal, so
        // gate it on `!is_test`; the error return + observer event + Sentry
        // capture below all fire unconditionally, so the tests still assert the
        // full fail-closed-and-loud behavior.
        if (!builtin.is_test) {
            std.log.err(
                "zaki_postgres: tenant write-boundary VIOLATION — refusing memory write; bound_user_id={d} context_user_id={d}",
                .{ self.user_id, ctx_user_id },
            );
        }
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "refused cross-tenant memory write: bound_user_id={d} context_user_id={d}",
            .{ self.user_id, ctx_user_id },
        ) catch "refused cross-tenant memory write (ids omitted)";
        // Per-turn observer (reaches the user SSE + the Sentry observer in the
        // chain) when one is attached.
        if (tools_mod.getToolObserver()) |obs| {
            obs.recordEvent(&.{ .err = .{ .component = "memory_tenant_mismatch", .message = msg } });
        }
        // Always reach GlitchTip directly — background/in-process turns may have
        // no attached observer, but this violation must never be silent.
        sentry_runtime.globalOrFallback().captureError("memory_tenant_mismatch", msg);
        return error.TenantWriteBoundaryViolation;
    }

    fn implRecall(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) anyerror![]root.MemoryEntry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return try self.manager.recallMemories(allocator, self.user_id, query, limit, session_id);
    }

    fn implGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?root.MemoryEntry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return try self.manager.getMemory(allocator, self.user_id, key);
    }

    fn implList(ptr: *anyopaque, allocator: std.mem.Allocator, category: ?root.MemoryCategory, session_id: ?[]const u8) anyerror![]root.MemoryEntry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return try self.manager.listMemories(allocator, self.user_id, category, session_id);
    }

    fn implForget(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return try self.manager.forgetMemory(self.user_id, key);
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return try self.manager.countMemories(self.user_id);
    }

    fn implHealthCheck(_: *anyopaque) bool {
        return true;
    }

    fn implDeinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
        if (self.owns_self) self.allocator.destroy(self);
    }

    const vtable = root.Memory.VTable{
        .name = &implName,
        .store = &implStore,
        .recall = &implRecall,
        .get = &implGet,
        .list = &implList,
        .forget = &implForget,
        .count = &implCount,
        .healthCheck = &implHealthCheck,
        .deinit = &implDeinit,
        .store_with_metadata = &implStoreWithMetadata,
    };
};

// ── W1.1 tenant write-boundary assertion ─────────────────────────────
//
// These tests exercise the fail-closed guard at the postgres memory store
// boundary. In the default (non-postgres) build, `zaki_state.Manager` is the
// disabled stub whose `upsertMemory` returns `error.PostgresNotEnabled`, so:
//   - mismatch  → guard fires first → `error.TenantWriteBoundaryViolation`
//                 (never reaches upsertMemory; the stub error never surfaces)
//   - match     → guard passes → reaches stub upsert → `error.PostgresNotEnabled`
//   - unset ctx → guard skipped (logged) → reaches stub upsert → `error.PostgresNotEnabled`
// The distinguishing assertion is whether the boundary error is/ isn't raised.

/// Minimal capturing observer used to prove the refusal is LOUD — i.e. the
/// boundary violation reaches the per-turn observer chain (and therefore the
/// Sentry observer / GlitchTip in production).
const CapturingObserver = struct {
    const observability = @import("../../observability.zig");
    saw_mismatch: bool = false,

    fn recordEvent(ptr: *anyopaque, event: *const observability.ObserverEvent) void {
        const self: *CapturingObserver = @ptrCast(@alignCast(ptr));
        switch (event.*) {
            .err => |e| {
                if (std.mem.eql(u8, e.component, "memory_tenant_mismatch")) self.saw_mismatch = true;
            },
            else => {},
        }
    }
    fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn flush(_: *anyopaque) void {}
    fn name(_: *anyopaque) []const u8 {
        return "capturing";
    }
    const vtable = observability.Observer.VTable{
        .record_event = recordEvent,
        .record_metric = recordMetric,
        .flush = flush,
        .name = name,
    };
    fn observer(self: *CapturingObserver) observability.Observer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

test "W1.1: store REFUSES when tenant context user_id != bound user_id" {
    // Asserts the disabled-stub `Manager` semantics (PostgresNotEnabled vs the
    // boundary error). Under `-Dengines=...,postgres`, `Manager == ManagerImpl`
    // needs a live DB to construct, so skip there — the guard itself is
    // build-agnostic and compile-checked in both variants.
    if (build_options.enable_postgres) return error.SkipZigTest;
    var mgr = zaki_state.Manager{};
    defer mgr.deinit();
    var mem = ZakiPostgresMemory.init(std.testing.allocator, &mgr, 16);

    var capture = CapturingObserver{};
    var obs = capture.observer();
    tools_mod.setToolObserver(&obs);
    defer tools_mod.clearToolObserver();

    // A lifecycle bug hands this turn the wrong context: authenticated user is
    // 33 but the memory handle is bound to 16. The write must fail closed.
    tools_mod.setTenantContext(.{ .numeric_user_id = 33 });
    defer tools_mod.clearTenantContext();

    const result = mem.memory().store("k", "v", .{ .daily = {} }, null);
    try std.testing.expectError(error.TenantWriteBoundaryViolation, result);
    // ...and LOUD: the violation must reach the observer chain.
    try std.testing.expect(capture.saw_mismatch);
}

test "W1.1: storeWithMetadata REFUSES when tenant context user_id != bound user_id" {
    // Covers the SECOND write boundary: `implStoreWithMetadata` (compose_memory
    // path) also calls `assertTenantWriteBoundary`. W1.1 guarded both store
    // paths but only the plain `store` path had a refusal test; this closes
    // that gap so a cross-tenant write can never slip in through the
    // metadata-bearing path either. Same disabled-stub semantics as the plain
    // `store` test: the guard fires first, so the stub's PostgresNotEnabled is
    // never reached and the boundary error surfaces.
    if (build_options.enable_postgres) return error.SkipZigTest;
    var mgr = zaki_state.Manager{};
    defer mgr.deinit();
    var mem = ZakiPostgresMemory.init(std.testing.allocator, &mgr, 16);

    var capture = CapturingObserver{};
    var obs = capture.observer();
    tools_mod.setToolObserver(&obs);
    defer tools_mod.clearToolObserver();

    // A lifecycle bug hands this turn the wrong context: authenticated user is
    // 33 but the memory handle is bound to 16. The metadata write must fail
    // closed, exactly as the plain store path does.
    tools_mod.setTenantContext(.{ .numeric_user_id = 33 });
    defer tools_mod.clearTenantContext();

    const result = mem.memory().storeWithMetadata(
        "k",
        "v",
        .{ .daily = {} },
        null,
        "{\"synthesized_by\":\"agent\",\"references\":[\"a\",\"b\"]}",
    );
    try std.testing.expectError(error.TenantWriteBoundaryViolation, result);
    // ...and LOUD: the violation must reach the observer chain on this path too.
    try std.testing.expect(capture.saw_mismatch);
}

test "W1.1: storeWithMetadata PROCEEDS when tenant context user_id matches bound user_id" {
    // Same-tenant metadata write must pass the guard and reach the manager
    // (PostgresNotEnabled on the disabled stub — NOT the boundary error),
    // proving the metadata-path guard does not refuse a legitimate write.
    if (build_options.enable_postgres) return error.SkipZigTest;
    var mgr = zaki_state.Manager{};
    defer mgr.deinit();
    var mem = ZakiPostgresMemory.init(std.testing.allocator, &mgr, 16);

    tools_mod.setTenantContext(.{ .numeric_user_id = 16 });
    defer tools_mod.clearTenantContext();

    const result = mem.memory().storeWithMetadata(
        "k",
        "v",
        .{ .daily = {} },
        null,
        "{\"synthesized_by\":\"agent\"}",
    );
    try std.testing.expectError(error.PostgresNotEnabled, result);
}

test "W1.1: store PROCEEDS when tenant context user_id matches bound user_id" {
    if (build_options.enable_postgres) return error.SkipZigTest;
    var mgr = zaki_state.Manager{};
    defer mgr.deinit();
    var mem = ZakiPostgresMemory.init(std.testing.allocator, &mgr, 16);

    tools_mod.setTenantContext(.{ .numeric_user_id = 16 });
    defer tools_mod.clearTenantContext();

    // Guard must let this through to the manager. On the non-postgres stub the
    // manager reports PostgresNotEnabled — the key point is it is NOT the
    // boundary-violation error, proving the guard did not refuse a same-tenant
    // write.
    const result = mem.memory().store("k", "v", .{ .daily = {} }, null);
    try std.testing.expectError(error.PostgresNotEnabled, result);
}

test "W1.1: store PROCEEDS (skip-when-unset) when tenant context is unset" {
    if (build_options.enable_postgres) return error.SkipZigTest;
    var mgr = zaki_state.Manager{};
    defer mgr.deinit();
    var mem = ZakiPostgresMemory.init(std.testing.allocator, &mgr, 16);

    // No context set (e.g. MCP/internal path that never installs the
    // threadlocal). We must NEVER refuse merely because the context is unset;
    // the check is skipped and the write proceeds.
    tools_mod.clearTenantContext();
    const result = mem.memory().store("k", "v", .{ .daily = {} }, null);
    try std.testing.expectError(error.PostgresNotEnabled, result);
}
