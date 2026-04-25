//! GDPR purge orchestrator (Sprint 7B — S7.1).
//!
//! Single entrypoint that reduces a user to zero traces across every
//! persistence surface nullalis operates: the tenant Postgres schema,
//! the vector store (pgvector / qdrant / sqlite-shared), the per-user
//! filesystem tree, and the in-process session cache.
//!
//! Design choices (deliberate, worth preserving):
//!
//!  • **Order matters.** Sessions are evicted FIRST so no in-flight turn
//!    attempts to write to the user's rows while we're deleting them.
//!    Postgres cascade runs SECOND because it's the authoritative identity
//!    surface — if the users row is gone, downstream systems can treat
//!    the user as not-present. Vector store runs THIRD because pgvector
//!    has no FK to users and a partial cascade there wouldn't be visible
//!    to pg observers. Filesystem is LAST because it's the slowest and
//!    also the easiest to retry (idempotent `rm -rf`).
//!
//!  • **No true 2PC.** The tenant Postgres pool and the pgvector pool are
//!    separate connections. A failure between the pg cascade and the
//!    vector bulk-delete could leave orphaned embeddings. The orchestrator
//!    reports every per-step outcome in `PurgeReport`; every step is
//!    idempotent, so the caller can safely retry on failure.
//!
//!  • **Best-effort continuation.** One surface failing does not abort
//!    the purge. We try every step, collect errors, and return. A partial
//!    purge is strictly better than no purge — and the caller sees which
//!    surfaces still have data via the report.
//!
//!  • **Dependencies are explicit.** `PurgeDeps` takes nullable pointers
//!    for every subsystem so the orchestrator can run in test harnesses
//!    that stub out Postgres, and so the gateway can omit the vector
//!    store when memory.vector_store is unconfigured. A null dependency
//!    is NOT an error — it's "this surface isn't in scope for this
//!    deployment, skip it."
//!
//! Called by the `DELETE /api/v1/users/:user_id/data` HTTP endpoint
//! (S7.6) gated behind a two-phase confirmation token.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.gdpr);

const zaki_state_mod = @import("zaki_state.zig");
const memory_mod = @import("memory/root.zig");
const session_mod = @import("session.zig");

// ── Report ─────────────────────────────────────────────────────────

/// Per-surface accounting for a purgeUser call. Every field is
/// populated regardless of errors — a value of 0/false means "surface
/// had nothing to remove" OR "step failed" depending on `errors`.
pub const PurgeReport = struct {
    sessions_evicted: usize = 0,
    sessions_skipped_active: usize = 0,
    pg_user_row_deleted: bool = false,
    vector_rows_removed: usize = 0,
    filesystem_removed: bool = false,
    /// Per-step error names (e.g. "pg_delete_user_failed:PgQueryFailed").
    /// Empty slice = full success. Caller owns and frees.
    errors: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *PurgeReport, allocator: Allocator) void {
        for (self.errors.items) |e| allocator.free(e);
        self.errors.deinit(allocator);
    }

    /// True when every attempted surface succeeded. A deployment that
    /// omits a surface (e.g. no vector_store) does NOT count as failure.
    pub fn fullySucceeded(self: *const PurgeReport) bool {
        return self.errors.items.len == 0;
    }
};

// ── Dependencies ──────────────────────────────────────────────────

/// Every collaborating surface the orchestrator touches. Null fields
/// signal "this surface is not configured in this deployment" and are
/// skipped silently (not errors). Non-null pointers are borrowed — the
/// orchestrator does not take ownership and does not call deinit.
pub const PurgeDeps = struct {
    allocator: Allocator,
    /// Tenant Postgres manager. When null, the pg cascade step is skipped
    /// and `pg_user_row_deleted` stays false. Only valid to be null in
    /// tests or in non-postgres deployments.
    zaki_state: ?*zaki_state_mod.Manager = null,
    /// Vector store. When null, embeddings are skipped.
    vector_store: ?memory_mod.VectorStore = null,
    /// In-process session manager. When null, session-cache purge is
    /// skipped (typical for non-gateway tools).
    session_manager: ?*session_mod.SessionManager = null,
    /// Per-tenant filesystem root (e.g. "/data/users"). The orchestrator
    /// removes `{users_root}/{user_id}` recursively. When null or empty,
    /// filesystem purge is skipped.
    users_root: ?[]const u8 = null,
};

// ── Entrypoint ────────────────────────────────────────────────────

/// Purge every trace of `user_id` across the configured surfaces.
///
/// Returns a populated `PurgeReport`. The caller must call `deinit` on
/// the report to release the owned error slice.
///
/// This function does not return an error. Internal errors are logged
/// and recorded in `report.errors` — the HTTP handler maps a non-empty
/// errors slice to a 207 Multi-Status or 500 depending on policy.
pub fn purgeUser(deps: PurgeDeps, user_id: i64) !PurgeReport {
    var report = PurgeReport{};
    errdefer report.deinit(deps.allocator);

    const user_id_str = try std.fmt.allocPrint(deps.allocator, "{d}", .{user_id});
    defer deps.allocator.free(user_id_str);

    log.info("gdpr.purge.start user_id={d}", .{user_id});

    // Step 1: evict in-process sessions for this user. Do this FIRST so
    // no turn writes into rows we're about to delete.
    if (deps.session_manager) |sm| {
        const result = sm.evictUserSessions(user_id_str);
        report.sessions_evicted = result.evicted;
        report.sessions_skipped_active = result.active_skipped;
        if (result.active_skipped > 0) {
            const msg = std.fmt.allocPrint(
                deps.allocator,
                "session_evict_partial:active_skipped={d}",
                .{result.active_skipped},
            ) catch null;
            if (msg) |m| {
                report.errors.append(deps.allocator, m) catch deps.allocator.free(m);
            }
        }
    }

    // Step 2: Postgres cascade. Single `DELETE FROM users` removes 17
    // per-user tables via ON DELETE CASCADE (see zaki_state.deleteUser
    // doc comment for the table list).
    if (deps.zaki_state) |state| {
        if (state.deleteUser(user_id)) {
            report.pg_user_row_deleted = true;
        } else |err| {
            log.warn("gdpr.pg_delete_user_failed user_id={d} err={s}", .{ user_id, @errorName(err) });
            const msg = std.fmt.allocPrint(
                deps.allocator,
                "pg_delete_user_failed:{s}",
                .{@errorName(err)},
            ) catch null;
            if (msg) |m| {
                report.errors.append(deps.allocator, m) catch deps.allocator.free(m);
            }
        }
    }

    // Step 3: vector store bulk purge. pgvector's `memory_vectors` has no
    // FK to `users`; this is the only path that removes those rows.
    if (deps.vector_store) |vs| {
        if (vs.deleteAllForUser(user_id)) |removed| {
            report.vector_rows_removed = removed;
        } else |err| {
            log.warn("gdpr.vector_delete_all_failed user_id={d} err={s}", .{ user_id, @errorName(err) });
            const msg = std.fmt.allocPrint(
                deps.allocator,
                "vector_delete_all_failed:{s}",
                .{@errorName(err)},
            ) catch null;
            if (msg) |m| {
                report.errors.append(deps.allocator, m) catch deps.allocator.free(m);
            }
        }
    }

    // Step 4: filesystem. Recursively remove `{users_root}/{user_id}`.
    //
    // D32 (2026-04-25) — `users_root` MUST be absolute. `std.fs.cwd().
    // deleteTree` resolves relative paths against the worker CWD, so a
    // misconfigured `tenant_data_root = "data/users"` (relative) would
    // silently delete the wrong tree (or nothing — `deleteTree` swallows
    // top-level FileNotFound). The handler in `gateway.zig` passes
    // `state.tenant_data_root`, defaulted to `DEFAULT_TENANT_DATA_ROOT
    // = "/data/users"`. Catch the misconfiguration here rather than
    // letting the silent-mis-delete play out.
    if (deps.users_root) |root| {
        if (root.len > 0) {
            if (!std.fs.path.isAbsolute(root)) {
                log.warn("gdpr.fs_path_not_absolute user_id={d} users_root={s}", .{ user_id, root });
                const msg = std.fmt.allocPrint(
                    deps.allocator,
                    "fs_path_not_absolute:{s}",
                    .{root},
                ) catch null;
                if (msg) |m| {
                    report.errors.append(deps.allocator, m) catch deps.allocator.free(m);
                }
                // Skip step 4 entirely; `filesystem_removed` stays false.
                // Caller sees the error string and can fix the config
                // before retrying. Better than half-deleting somewhere
                // weird relative to the worker CWD.
            } else {
                const user_dir = std.fmt.allocPrint(
                    deps.allocator,
                    "{s}/{d}",
                    .{ root, user_id },
                ) catch |err| blk: {
                    log.warn("gdpr.fs_path_alloc_failed user_id={d} err={s}", .{ user_id, @errorName(err) });
                    break :blk null;
                };
                if (user_dir) |dir| {
                    defer deps.allocator.free(dir);
                    removeUserDirectoryTree(dir) catch |err| {
                        log.warn("gdpr.fs_delete_failed user_id={d} dir={s} err={s}", .{ user_id, dir, @errorName(err) });
                        const msg = std.fmt.allocPrint(
                            deps.allocator,
                            "fs_delete_failed:{s}",
                            .{@errorName(err)},
                        ) catch null;
                        if (msg) |m| {
                            report.errors.append(deps.allocator, m) catch deps.allocator.free(m);
                        }
                        return report;
                    };
                    report.filesystem_removed = true;
                }
            }
        }
    }

    log.info(
        "gdpr.purge.complete user_id={d} sessions_evicted={d} sessions_skipped={d} pg_deleted={} vector_rows={d} fs_removed={} errors={d}",
        .{
            user_id,
            report.sessions_evicted,
            report.sessions_skipped_active,
            report.pg_user_row_deleted,
            report.vector_rows_removed,
            report.filesystem_removed,
            report.errors.items.len,
        },
    );
    return report;
}

// ── Filesystem helper ─────────────────────────────────────────────

/// Recursively delete `user_dir`. `deleteTree` in stdlib already
/// treats a missing root as success (doesn't surface FileNotFound for
/// the top-level path), so we just forward its error set. A user with
/// no filesystem writes (fresh signup, etc.) purges cleanly.
fn removeUserDirectoryTree(user_dir: []const u8) !void {
    try std.fs.cwd().deleteTree(user_dir);
}

// ── Tests ─────────────────────────────────────────────────────────

test "PurgeReport starts empty and reports success" {
    var report = PurgeReport{};
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.fullySucceeded());
    try std.testing.expectEqual(@as(usize, 0), report.sessions_evicted);
    try std.testing.expectEqual(@as(usize, 0), report.vector_rows_removed);
    try std.testing.expect(!report.pg_user_row_deleted);
    try std.testing.expect(!report.filesystem_removed);
}

test "PurgeReport with recorded error is not a success" {
    var report = PurgeReport{};
    defer report.deinit(std.testing.allocator);
    const msg = try std.testing.allocator.dupe(u8, "pg_delete_user_failed:PgQueryFailed");
    try report.errors.append(std.testing.allocator, msg);
    try std.testing.expect(!report.fullySucceeded());
}

test "purgeUser with all-null deps returns empty success report" {
    var report = try purgeUser(.{ .allocator = std.testing.allocator }, 42);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.fullySucceeded());
    try std.testing.expectEqual(@as(usize, 0), report.sessions_evicted);
    try std.testing.expectEqual(@as(usize, 0), report.vector_rows_removed);
    try std.testing.expect(!report.pg_user_row_deleted);
    try std.testing.expect(!report.filesystem_removed);
}

test "purgeUser removes user filesystem tree and tolerates missing dir" {
    const allocator = std.testing.allocator;

    // Build a throwaway tenant root under the test tmp dir.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    // Seed `{root}/77/nested/file.txt` so we can observe the delete.
    try tmp.dir.makePath("77/nested");
    var f = try tmp.dir.createFile("77/nested/file.txt", .{});
    f.close();

    var report = try purgeUser(.{
        .allocator = allocator,
        .users_root = root_path,
    }, 77);
    defer report.deinit(allocator);
    try std.testing.expect(report.filesystem_removed);
    try std.testing.expect(report.fullySucceeded());

    // `77/` must no longer exist.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("77", .{}));

    // Second call is a no-op (tree already gone) but still reports success.
    var report2 = try purgeUser(.{
        .allocator = allocator,
        .users_root = root_path,
    }, 77);
    defer report2.deinit(allocator);
    try std.testing.expect(report2.filesystem_removed);
    try std.testing.expect(report2.fullySucceeded());
}

test "purgeUser with empty users_root skips filesystem step" {
    var report = try purgeUser(.{
        .allocator = std.testing.allocator,
        .users_root = "",
    }, 99);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.filesystem_removed);
    try std.testing.expect(report.fullySucceeded());
}

test "D32 purgeUser rejects relative users_root and records explicit error" {
    // Defense against a misconfigured `tenant_data_root = "data/users"`
    // (relative) silently deleting the wrong tree relative to the
    // worker's CWD. The orchestrator must NOT touch the filesystem
    // at all when the root isn't absolute, and the error must be
    // visible in PurgeReport so the operator sees it.
    var report = try purgeUser(.{
        .allocator = std.testing.allocator,
        .users_root = "relative/path/users",
    }, 42);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(!report.filesystem_removed);
    try std.testing.expect(!report.fullySucceeded());
    try std.testing.expectEqual(@as(usize, 1), report.errors.items.len);
    try std.testing.expect(std.mem.startsWith(u8, report.errors.items[0], "fs_path_not_absolute:"));
    try std.testing.expect(std.mem.indexOf(u8, report.errors.items[0], "relative/path/users") != null);
}

test "D32 purgeUser accepts absolute users_root (sanity, regression guard for the new branch)" {
    // Mirror of the existing absolute-path test but explicitly tagged
    // as the D32 partner — ensures the absolute-path branch still
    // succeeds after the relative-path rejection was added.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);

    // realpathAlloc returns an absolute path on every supported OS.
    try std.testing.expect(std.fs.path.isAbsolute(root_path));

    var report = try purgeUser(.{
        .allocator = std.testing.allocator,
        .users_root = root_path,
    }, 1234);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.filesystem_removed);
    try std.testing.expect(report.fullySucceeded());
}

test "purgeUser reports vector_rows_removed from vector store" {
    const allocator = std.testing.allocator;
    const sqlite_mod = @import("memory/engines/sqlite.zig");
    const vector_store_mod = @import("memory/vector/store.zig");

    var mem = try sqlite_mod.SqliteMemory.init(allocator, ":memory:");
    defer mem.deinit();
    var vs_impl = vector_store_mod.SqliteSharedVectorStore.init(allocator, mem.db);
    defer vs_impl.deinit();
    const vs = vs_impl.store();

    // Seed: 3 rows for user 42, 1 row for user 99.
    try vs.upsertScoped(42, "k1", &[_]f32{ 1.0, 0.0 });
    try vs.upsertScoped(42, "k2", &[_]f32{ 0.0, 1.0 });
    try vs.upsertScoped(42, "k3", &[_]f32{ 1.0, 1.0 });
    try vs.upsertScoped(99, "k1", &[_]f32{ 0.5, 0.5 });

    var report = try purgeUser(.{
        .allocator = allocator,
        .vector_store = vs,
    }, 42);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), report.vector_rows_removed);
    try std.testing.expect(report.fullySucceeded());

    // User 99 still has their row.
    try std.testing.expectEqual(@as(usize, 1), try vs.count());
}
