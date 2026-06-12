//! S10.1 — Real migration framework.
//!
//! Replaces the boot-time `for (statements) |s| exec(s)` pattern in
//! `zaki_state.zig::migrate` (which relied on `IF NOT EXISTS` +
//! `canIgnoreMigrateError` allowlist tolerance to be re-run-safe)
//! with a versioned schema-migrations runner:
//!
//!   * `{schema}.schema_migrations` table tracks applied versions
//!   * Each migration runs exactly once per database
//!   * Each migration runs inside a transaction (BEGIN/COMMIT) so a
//!     mid-migration failure rolls back cleanly without leaving
//!     half-applied DDL
//!   * Failures surface as errors instead of being swallowed by the
//!     allowlist (the `canIgnoreMigrateError` allowlist stays in
//!     place ONLY for migration 0001 — the legacy idempotent batch
//!     that may run against pre-existing prod databases — and gets
//!     dropped once 0001 is confirmed applied everywhere)
//!
//! Adding a new migration:
//!   1. Append to `MIGRATIONS` array below with the next version
//!      number + descriptive name + SQL string (may use `{schema}`
//!      placeholder which the caller expands via `buildQuery`)
//!   2. Each migration must be a single `BEGIN`-able transaction
//!      (no `CREATE INDEX CONCURRENTLY` — that statement can't run
//!      inside a transaction; if you need it, use a separate
//!      `concurrent_only` flag on the entry — see §S10.3)
//!   3. Migrations 0002+ MUST be true diffs (not idempotent
//!      replays); the framework guarantees they're never re-run
//!      after first success
//!   4. Test coverage: each new migration gets a regression test
//!      asserting the resulting schema state

const std = @import("std");

pub const Migration = struct {
    version: u32,
    name: []const u8,
    sql: []const u8,

    /// **S10.3** — when true, this migration's statements must run
    /// outside of a BEGIN/COMMIT transaction (e.g. `CREATE INDEX
    /// CONCURRENTLY` in Postgres can't run inside a transaction).
    /// The runner will:
    ///   - Skip the BEGIN/COMMIT wrapper for this migration
    ///   - Execute statements one-at-a-time, splitting on `;`
    ///   - Insert the version row in a separate transaction after
    ///     all statements succeed
    /// Use sparingly — most migrations should be transactional.
    concurrent_only: bool = false,
};

/// SQL for the `schema_migrations` tracker table itself. Idempotent —
/// safe to run on every boot (it's a `CREATE TABLE IF NOT EXISTS`).
pub const SCHEMA_MIGRATIONS_DDL =
    \\CREATE TABLE IF NOT EXISTS {schema}.schema_migrations (
    \\    version INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    \\)
;

/// Registered migrations in version order. The runner iterates this
/// array and applies each unapplied entry exactly once.
///
/// **S10.1 ships the framework with an EMPTY MIGRATIONS array.** S10.2
/// adds the `0001_initial_schema` entry that embeds the full
/// schema-as-of-S10.1 from `migrations/0001_initial_schema.sql` and
/// flips `zaki_state.zig::migrate` over to call `run(...)` instead of
/// the legacy hardcoded statement loop. Splitting the framework + the
/// content into two commits keeps the diffs reviewable and lets the
/// framework's tests run against a clean MIGRATIONS array.
///
/// Adding a new migration:
///   .{
///       .version = N+1,
///       .name = "{NNNN}_descriptive_name",
///       .sql = @embedFile("migrations/{NNNN}_descriptive_name.sql"),
///   },
pub const MIGRATIONS = [_]Migration{
    .{
        .version = 1,
        .name = "0001_initial_schema",
        .sql = @embedFile("migrations/0001_initial_schema.sql"),
    },
    .{
        .version = 2,
        .name = "0002_artifacts",
        .sql = @embedFile("migrations/0002_artifacts.sql"),
    },
    .{
        // Sprint 3 (2026-05-28, prod-readiness) — durable trace shares.
        // See `src/migrations/0003_trace_shares.sql` for the rationale +
        // schema. Closes `ui-handoff.md` §7 P1 for the shares half;
        // trace EVENTS stay in the in-process RunTraceStore (V1.x
        // decision documented in the migration file).
        .version = 3,
        .name = "0003_trace_shares",
        .sql = @embedFile("migrations/0003_trace_shares.sql"),
    },
    .{
        // Wave 2 (2026-06-11, nullALIS metering completeness) — durable
        // per-turn usage ledger. See `src/migrations/0004_turn_usage.sql`
        // for the rationale + schema. Written on EVERY turn completion
        // (http + daemon) so cron/heartbeat/channel turns — which record
        // NOTHING today (usage_rt = null) — become reconcilable by the BFF.
        .version = 4,
        .name = "0004_turn_usage",
        .sql = @embedFile("migrations/0004_turn_usage.sql"),
    },
    .{
        // Wave A (2026-06-12, agent-runtime resilience) — P0-4 durable,
        // resumable, idempotent tool approvals. See
        // `src/migrations/0005_pending_approvals.sql` for the rationale +
        // schema. Persists the in-RAM approval SNAPSHOT so a pod restart /
        // session eviction no longer 404s the user's Approve click — the
        // session rehydrates the open row on (re)build and resolves it.
        // NO expires_at / NO TTL. FK-safe via the P0-6 ensureUserRow
        // chokepoint.
        .version = 5,
        .name = "0005_pending_approvals",
        .sql = @embedFile("migrations/0005_pending_approvals.sql"),
    },
};

/// Trait the runner's caller must satisfy: a method that takes a
/// `{schema}`-templated SQL string + a callback to be invoked for
/// each statement. The caller (Manager.Self) provides this so the
/// runner doesn't need to know about libpq specifics — it just
/// orchestrates the version tracking.
///
/// The caller is responsible for:
///   - Substituting `{schema}` in templates via its own `buildQuery`
///   - Acquiring/releasing a Postgres connection
///   - Wrapping in BEGIN/COMMIT (when `concurrent_only == false`)
///   - Surfacing errors
pub const RunnerContext = struct {
    /// Execute a single DDL statement (already `{schema}`-substituted).
    /// Returns error on failure.
    exec: *const fn (ctx: *anyopaque, query: []const u8) anyerror!void,
    /// Begin a transaction. No-op if backend doesn't support transactions.
    begin: *const fn (ctx: *anyopaque) anyerror!void,
    /// Commit the current transaction.
    commit: *const fn (ctx: *anyopaque) anyerror!void,
    /// Rollback the current transaction.
    rollback: *const fn (ctx: *anyopaque) anyerror!void,
    /// Query whether a migration version has already been applied.
    /// Returns true if a row with `version` exists in `schema_migrations`.
    isApplied: *const fn (ctx: *anyopaque, version: u32) anyerror!bool,
    /// Insert a row into `schema_migrations` for a freshly-applied
    /// migration. Caller may run this inside the same transaction
    /// as the DDL (transactional path) OR in a separate transaction
    /// (concurrent_only path).
    recordApplied: *const fn (ctx: *anyopaque, version: u32, name: []const u8) anyerror!void,
    /// Build a `{schema}`-substituted query string from a template.
    /// Caller-owned allocation; runner frees via `freeQuery`.
    buildQuery: *const fn (ctx: *anyopaque, template: []const u8) anyerror![]const u8,
    /// Free a query string returned by `buildQuery`.
    freeQuery: *const fn (ctx: *anyopaque, query: []const u8) void,

    ctx: *anyopaque,
};

/// **S10.1** — main runner. Ensures the schema_migrations table
/// exists, then iterates `MIGRATIONS` and applies each unapplied
/// entry. Call this from `zaki_state.zig::migrate` instead of the
/// legacy hardcoded statement loop.
pub fn run(rc: RunnerContext) !void {
    return runWith(rc, &MIGRATIONS);
}

/// **S10.1** — testable runner. Same behavior as `run`, but takes the
/// migrations slice as a parameter so tests can inject their own
/// fixture migrations independent of the production `MIGRATIONS`
/// array (which is empty in the S10.1 commit; S10.2 fills it).
pub fn runWith(rc: RunnerContext, migrations: []const Migration) !void {
    // Step 1: ensure tracker table exists. Idempotent.
    {
        const q = try rc.buildQuery(rc.ctx, SCHEMA_MIGRATIONS_DDL);
        defer rc.freeQuery(rc.ctx, q);
        try rc.exec(rc.ctx, q);
    }

    // Step 2: iterate migrations, apply unapplied ones in order.
    for (migrations) |m| {
        if (try rc.isApplied(rc.ctx, m.version)) {
            std.log.scoped(.migrations).debug("migration {d} '{s}' already applied", .{ m.version, m.name });
            continue;
        }

        std.log.scoped(.migrations).info("applying migration {d} '{s}' ({s})", .{
            m.version,
            m.name,
            if (m.concurrent_only) "concurrent_only" else "transactional",
        });

        if (m.concurrent_only) {
            try applyConcurrent(rc, m);
        } else {
            try applyTransactional(rc, m);
        }

        std.log.scoped(.migrations).info("migration {d} '{s}' applied successfully", .{ m.version, m.name });
    }
}

fn applyTransactional(rc: RunnerContext, m: Migration) !void {
    try rc.begin(rc.ctx);
    errdefer rc.rollback(rc.ctx) catch |rb_err| {
        std.log.scoped(.migrations).err("rollback after migration {d} failure also failed: {}", .{ m.version, rb_err });
    };

    // Migration body. May contain {schema} placeholders.
    const q = try rc.buildQuery(rc.ctx, m.sql);
    defer rc.freeQuery(rc.ctx, q);
    try rc.exec(rc.ctx, q);

    // Record applied within the same transaction so failures roll
    // both the DDL and the version row back together.
    try rc.recordApplied(rc.ctx, m.version, m.name);

    try rc.commit(rc.ctx);
}

fn applyConcurrent(rc: RunnerContext, m: Migration) !void {
    // Concurrent path: no BEGIN/COMMIT around the DDL (e.g. CREATE
    // INDEX CONCURRENTLY can't run inside a transaction). Statements
    // execute one-at-a-time, split on `;`. The version row gets
    // inserted in a separate transaction after all statements succeed.
    const q = try rc.buildQuery(rc.ctx, m.sql);
    defer rc.freeQuery(rc.ctx, q);

    var iter = std.mem.tokenizeScalar(u8, q, ';');
    while (iter.next()) |raw_stmt| {
        const stmt = std.mem.trim(u8, raw_stmt, " \t\r\n");
        if (stmt.len == 0) continue;
        try rc.exec(rc.ctx, stmt);
    }

    // Record applied in its own transaction so a crash between DDL
    // success and version-record insertion doesn't lose the marker.
    try rc.begin(rc.ctx);
    errdefer rc.rollback(rc.ctx) catch {};
    try rc.recordApplied(rc.ctx, m.version, m.name);
    try rc.commit(rc.ctx);
}

// ── Tests ─────────────────────────────────────────────────────────

const TestRunner = struct {
    queries: std.ArrayListUnmanaged([]const u8) = .empty,
    in_tx: bool = false,
    applied: std.AutoHashMapUnmanaged(u32, void) = .empty,
    fail_on_exec_n: ?usize = null,
    exec_count: usize = 0,
    allocator: std.mem.Allocator,

    fn deinit(self: *TestRunner) void {
        for (self.queries.items) |q| self.allocator.free(q);
        self.queries.deinit(self.allocator);
        self.applied.deinit(self.allocator);
    }

    fn execImpl(ctx: *anyopaque, query: []const u8) anyerror!void {
        const self: *TestRunner = @ptrCast(@alignCast(ctx));
        self.exec_count += 1;
        if (self.fail_on_exec_n) |n| {
            if (self.exec_count == n) return error.SimulatedExecFailure;
        }
        const owned = try self.allocator.dupe(u8, query);
        try self.queries.append(self.allocator, owned);
    }

    fn beginImpl(ctx: *anyopaque) anyerror!void {
        const self: *TestRunner = @ptrCast(@alignCast(ctx));
        self.in_tx = true;
    }

    fn commitImpl(ctx: *anyopaque) anyerror!void {
        const self: *TestRunner = @ptrCast(@alignCast(ctx));
        self.in_tx = false;
    }

    fn rollbackImpl(ctx: *anyopaque) anyerror!void {
        const self: *TestRunner = @ptrCast(@alignCast(ctx));
        self.in_tx = false;
    }

    fn isAppliedImpl(ctx: *anyopaque, version: u32) anyerror!bool {
        const self: *TestRunner = @ptrCast(@alignCast(ctx));
        return self.applied.contains(version);
    }

    fn recordAppliedImpl(ctx: *anyopaque, version: u32, _: []const u8) anyerror!void {
        const self: *TestRunner = @ptrCast(@alignCast(ctx));
        try self.applied.put(self.allocator, version, {});
    }

    fn buildQueryImpl(ctx: *anyopaque, template: []const u8) anyerror![]const u8 {
        const self: *TestRunner = @ptrCast(@alignCast(ctx));
        // Test harness: simple {schema} → "test" substitution.
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        var i: usize = 0;
        while (i < template.len) {
            if (i + 8 <= template.len and std.mem.eql(u8, template[i .. i + 8], "{schema}")) {
                try out.appendSlice(self.allocator, "test");
                i += 8;
            } else {
                try out.append(self.allocator, template[i]);
                i += 1;
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn freeQueryImpl(ctx: *anyopaque, query: []const u8) void {
        const self: *TestRunner = @ptrCast(@alignCast(ctx));
        self.allocator.free(query);
    }

    fn context(self: *TestRunner) RunnerContext {
        return .{
            .exec = execImpl,
            .begin = beginImpl,
            .commit = commitImpl,
            .rollback = rollbackImpl,
            .isApplied = isAppliedImpl,
            .recordApplied = recordAppliedImpl,
            .buildQuery = buildQueryImpl,
            .freeQuery = freeQueryImpl,
            .ctx = @ptrCast(self),
        };
    }
};

// Fixture migrations for tests — small, fast, deterministic. The
// production `MIGRATIONS` array is empty in S10.1; S10.2 populates
// it with the real schema. Tests use `runWith(rc, &fixture)` to
// exercise the runner independently of the production array.
const fixture_migrations = [_]Migration{
    .{ .version = 1, .name = "0001_test_fixture", .sql = "CREATE TABLE {schema}.fixture_a (id INT)" },
    .{ .version = 2, .name = "0002_test_fixture", .sql = "CREATE TABLE {schema}.fixture_b (id INT)" },
};

test "migrations.runWith on empty DB applies all fixture migrations once" {
    var tr = TestRunner{ .allocator = std.testing.allocator };
    defer tr.deinit();

    try runWith(tr.context(), &fixture_migrations);

    // schema_migrations DDL + each fixture migration's SQL.
    try std.testing.expect(tr.queries.items.len >= fixture_migrations.len + 1);

    // Every fixture migration should be marked applied.
    for (fixture_migrations) |m| {
        try std.testing.expect(tr.applied.contains(m.version));
    }
}

test "migrations.runWith on already-migrated DB is a no-op for applied versions" {
    var tr = TestRunner{ .allocator = std.testing.allocator };
    defer tr.deinit();

    // Pre-mark all fixture migrations as applied.
    for (fixture_migrations) |m| {
        try tr.applied.put(tr.allocator, m.version, {});
    }

    try runWith(tr.context(), &fixture_migrations);

    // Only the schema_migrations DDL should have executed (the
    // tracker table is always ensured); migration bodies are skipped.
    try std.testing.expectEqual(@as(usize, 1), tr.queries.items.len);
}

test "migrations.runWith failure inside a transactional migration triggers rollback" {
    var tr = TestRunner{ .allocator = std.testing.allocator };
    defer tr.deinit();

    // Fail on the second exec call (the first being schema_migrations
    // DDL, the second being fixture migration 0001 body).
    tr.fail_on_exec_n = 2;

    const result = runWith(tr.context(), &fixture_migrations);
    try std.testing.expectError(error.SimulatedExecFailure, result);

    // The failed migration should NOT be recorded as applied — the
    // rollback rolled the version-row insert back along with the DDL.
    try std.testing.expect(!tr.applied.contains(1));
    // Transaction should be cleanly closed (no leak).
    try std.testing.expect(!tr.in_tx);
}

test "migrations.run with production MIGRATIONS executes tracker + each registered migration" {
    var tr = TestRunner{ .allocator = std.testing.allocator };
    defer tr.deinit();

    try run(tr.context());

    // S10.2 populated MIGRATIONS with 0001_initial_schema. The
    // tracker DDL fires once, then each registered migration's
    // body fires. Production MIGRATIONS may grow over time; assert
    // the lower bound (tracker + at least one migration) rather
    // than a fixed count so adding 0002+ doesn't break this test.
    try std.testing.expect(tr.queries.items.len >= 1 + MIGRATIONS.len);
    try std.testing.expectEqual(@as(usize, MIGRATIONS.len), tr.applied.count());
    for (MIGRATIONS) |m| {
        try std.testing.expect(tr.applied.contains(m.version));
    }
}

test "MIGRATIONS array is in strict ascending version order with no gaps" {
    // Catches future contributor mistakes (skipping a number or
    // re-using one). The framework relies on monotonically increasing
    // versions to enforce "applied exactly once" semantics.
    var prev: u32 = 0;
    for (MIGRATIONS) |m| {
        try std.testing.expect(m.version == prev + 1);
        prev = m.version;
    }
}

test "Wave 2 — migration 0004_turn_usage is registered with the durable metering schema" {
    // Static contract test (no live DB): assert the durable per-turn usage
    // ledger migration exists in the MIGRATIONS array with the load-bearing
    // structural invariants the BFF reconciliation sweep + idempotency depend
    // on. A future edit that drops any of these silently breaks metering
    // completeness (daemon turns stop being reconcilable, or get double-
    // debited) — this catches it at compile-test time without a Postgres.
    const found = blk: {
        for (MIGRATIONS) |m| {
            if (m.version == 4) break :blk m;
        }
        return error.Migration0004NotFound;
    };
    try std.testing.expectEqualStrings("0004_turn_usage", found.name);
    const sql = found.sql;

    // Idempotent create (applies cleanly on fresh AND existing staging DB).
    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE IF NOT EXISTS {schema}.turn_usage") != null);

    // FK to {schema}.users with ON DELETE CASCADE (GDPR purge cascade parity).
    try std.testing.expect(std.mem.indexOf(u8, sql, "REFERENCES {schema}.users(user_id) ON DELETE CASCADE") != null);

    // The two discriminators the BFF reconciles on.
    try std.testing.expect(std.mem.indexOf(u8, sql, "entry_kind") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "turn_origin") != null);

    // Reconciliation columns.
    try std.testing.expect(std.mem.indexOf(u8, sql, "cost_available") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "reconciled_at") != null);

    // Idempotency: UNIQUE (user_id, turn_key) — the ON CONFLICT target.
    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE UNIQUE INDEX IF NOT EXISTS idx_turn_usage_idem") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "(user_id, turn_key)") != null);

    // Sweep index: partial on (entry_kind, reconciled_at) WHERE NULL.
    try std.testing.expect(std.mem.indexOf(u8, sql, "idx_turn_usage_sweep") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "WHERE reconciled_at IS NULL") != null);

    // Transactional (no CREATE INDEX CONCURRENTLY) so the runner wraps it
    // in BEGIN/COMMIT — a mid-migration failure rolls back cleanly.
    try std.testing.expect(!found.concurrent_only);
    try std.testing.expect(std.mem.indexOf(u8, sql, "CONCURRENTLY") == null);
}

test "S10.4 — initial schema declares cross-schema FK to public.zaki_users with CASCADE" {
    // Static contract test: the FK that ties {schema}.users to
    // public.zaki_users with ON DELETE CASCADE is the load-bearing
    // structural invariant for GDPR purgeUser cascade behavior
    // (see S7.5 + project_repair_queue_2026_04_21.md). Any future
    // migration that drops or alters this FK without preserving
    // CASCADE semantics breaks user deletion silently — this test
    // catches such drift at compile-time without needing a live pg.
    //
    // The test inspects the embedded 0001 migration SQL directly.
    // Future migrations that touch the FK must either preserve the
    // exact phrase below in the cumulative schema state, or update
    // this test to point at the new authoritative location.
    const found_0001 = blk: {
        for (MIGRATIONS) |m| {
            if (m.version == 1) break :blk m;
        }
        return error.Migration0001NotFound;
    };

    const sql = found_0001.sql;
    // Required: the constraint name + table reference + cascade.
    try std.testing.expect(std.mem.indexOf(u8, sql, "users_user_id_fkey") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "REFERENCES public.zaki_users(id)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ON DELETE CASCADE") != null);

    // Defense: ensure the FK declaration is wrapped in an idempotent
    // guard (DO block with NOT EXISTS check), so re-running 0001 on
    // a database where the FK already exists doesn't fail. Pre-S10.2
    // the legacy loop relied on canIgnoreMigrateError tolerance for
    // the "constraint already exists" error; the migration-framework
    // path requires real idempotency.
    try std.testing.expect(std.mem.indexOf(u8, sql, "DO $$") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "WHERE conname = 'users_user_id_fkey'") != null);
}
