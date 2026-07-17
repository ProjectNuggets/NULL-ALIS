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
//!      number + descriptive name + SQL string + explicit compatibility
//!      phase (may use `{schema}` placeholder which the caller expands
//!      via `buildQuery`)
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

/// Compatibility phase used by the release rollback contract.
pub const CompatibilityPhase = enum {
    /// Initial adoption of the versioned migration framework.
    baseline,
    /// Additive schema that the previous binary must continue to tolerate.
    expand,
    /// Destructive cleanup allowed only after the previous binary is retired.
    contract,
};

pub const Migration = struct {
    version: u32,
    name: []const u8,
    sql: []const u8,
    phase: CompatibilityPhase,

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

    /// A reviewed data-only expand migration may opt into static DELETE
    /// statements. This does not relax any schema-destructive rule. At
    /// present only migration 0010 uses the exception.
    allow_expand_data_delete: bool = false,
};

/// Reject SQL shapes that cannot safely remain in place while the previous
/// binary is serving during an image rollback. This is deliberately
/// conservative; semantic compatibility still requires review and a live
/// old-binary-on-expanded-schema rehearsal.
pub fn validateExpandSql(sql: []const u8) !void {
    return validateExpandSqlWithPolicy(sql, false);
}

/// Validate an expand migration with its explicit, narrowly-scoped policy.
/// The runner and production registry use this entry point; standalone SQL
/// validation remains strict through `validateExpandSql`.
pub fn validateExpandMigration(migration: Migration) !void {
    return validateExpandSqlWithPolicy(migration.sql, migration.allow_expand_data_delete);
}

fn validateExpandSqlWithPolicy(sql: []const u8, allow_expand_data_delete: bool) !void {
    const allocator = std.heap.page_allocator;
    var normalized: std.ArrayListUnmanaged(u8) = .empty;
    defer normalized.deinit(allocator);
    try normalized.append(allocator, ' ');

    var index: usize = 0;
    while (index < sql.len) {
        if (index + 1 < sql.len and sql[index] == '-' and sql[index + 1] == '-') {
            index += 2;
            while (index < sql.len and sql[index] != '\n') : (index += 1) {}
            try appendNormalizedSpace(&normalized, allocator);
            continue;
        }

        // Keywords inside ordinary string literals and quoted identifiers are
        // data/names, not executable SQL tokens. Ignore them so a harmless
        // default such as 'drop table' does not force a migration to contract.
        if (sql[index] == '\'' or sql[index] == '"') {
            const quote = sql[index];
            index += 1;
            while (index < sql.len) {
                if (sql[index] != quote) {
                    index += 1;
                    continue;
                }
                if (index + 1 < sql.len and sql[index + 1] == quote) {
                    index += 2;
                    continue;
                }
                index += 1;
                break;
            }
            try appendNormalizedSpace(&normalized, allocator);
            continue;
        }
        if (index + 1 < sql.len and sql[index] == '/' and sql[index + 1] == '*') {
            index += 2;
            while (index + 1 < sql.len and !(sql[index] == '*' and sql[index + 1] == '/')) : (index += 1) {}
            if (index + 1 < sql.len) index += 2;
            try appendNormalizedSpace(&normalized, allocator);
            continue;
        }

        const byte = sql[index];
        index += 1;
        if (std.ascii.isWhitespace(byte)) {
            try appendNormalizedSpace(&normalized, allocator);
        } else {
            try normalized.append(allocator, std.ascii.toLower(byte));
        }
    }
    try appendNormalizedSpace(&normalized, allocator);

    const forbidden = [_][]const u8{
        " drop table ",
        " drop column ",
        " drop constraint ",
        " drop schema ",
        " drop view ",
        " drop materialized view ",
        " drop type ",
        " drop domain ",
        " drop sequence ",
        " drop function ",
        " drop procedure ",
        " drop trigger ",
        " drop index ",
        " drop policy ",
        " drop default ",
        " drop identity ",
        " drop expression ",
        " add constraint ",
        " add primary key ",
        " add unique ",
        " add check ",
        " add foreign key ",
        " add exclude ",
        " rename column ",
        " rename constraint ",
        " rename attribute ",
        " rename value ",
        " rename to ",
        " set not null ",
        " truncate table ",
        " create or replace view ",
        " create or replace function ",
        " create or replace procedure ",
        " create or replace trigger ",
    };
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, normalized.items, needle) != null) return error.DestructiveExpandMigration;
    }
    if (!allow_expand_data_delete and std.mem.indexOf(u8, normalized.items, " delete from ") != null) {
        return error.DestructiveExpandMigration;
    }
    // ALTER COLUMN ... TYPE may contain an arbitrary type expression between
    // the two tokens, so it cannot be represented by one fixed phrase.
    var statements = std.mem.tokenizeScalar(u8, normalized.items, ';');
    while (statements.next()) |statement| {
        const trimmed_statement = std.mem.trim(u8, statement, " ");
        if (containsTruncateToken(statement) and !isCreateTriggerExecuteFunction(trimmed_statement)) {
            return error.DestructiveExpandMigration;
        }
        // `EXECUTE FUNCTION` is part of a normal CREATE TRIGGER clause; every
        // other EXECUTE form remains dynamic SQL and is forbidden in expand.
        if (std.mem.indexOf(u8, statement, " execute ") != null and
            !isCreateTriggerExecuteFunction(trimmed_statement))
        {
            return error.DestructiveExpandMigration;
        }
        if (std.mem.indexOf(u8, statement, " add column ") != null and
            hasNotNullConstraint(statement))
        {
            return error.DestructiveExpandMigration;
        }
        if (std.mem.indexOf(u8, statement, " alter column ") != null and
            std.mem.indexOf(u8, statement, " type ") != null)
        {
            return error.DestructiveExpandMigration;
        }
    }
}

fn appendNormalizedSpace(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    if (buffer.items.len == 0 or buffer.items[buffer.items.len - 1] != ' ') {
        try buffer.append(allocator, ' ');
    }
}

fn isCreateTriggerExecuteFunction(statement: []const u8) bool {
    return std.mem.startsWith(u8, statement, "create trigger ") and
        std.mem.indexOf(u8, statement, " execute function ") != null;
}

fn hasNotNullConstraint(statement: []const u8) bool {
    const needle = " not null";
    var index: usize = 0;
    while (index + needle.len <= statement.len) : (index += 1) {
        if (!std.mem.startsWith(u8, statement[index..], needle)) continue;
        const after = index + needle.len;
        if (after == statement.len) return true;
        switch (statement[after]) {
            ' ', ',', ')' => return true,
            else => {},
        }
    }
    return false;
}

fn containsTruncateToken(sql: []const u8) bool {
    const needle = " truncate ";
    return std.mem.indexOf(u8, sql, needle) != null;
}

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
///       .phase = .expand,
///   },
pub const MIGRATIONS = [_]Migration{
    .{
        .version = 1,
        .name = "0001_initial_schema",
        .sql = @embedFile("migrations/0001_initial_schema.sql"),
        .phase = .baseline,
    },
    .{
        .version = 2,
        .name = "0002_artifacts",
        .sql = @embedFile("migrations/0002_artifacts.sql"),
        .phase = .expand,
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
        .phase = .expand,
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
        .phase = .expand,
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
        .phase = .expand,
    },
    .{
        // Wave C C4 (2026-06-12, agent-runtime resilience) — P1-5 transcript
        // fidelity. Adds NULLABLE `tool_calls` (JSONB) + `reasoning` (TEXT)
        // columns to {schema}.messages so a reloaded assistant turn carries
        // its native tool-call/reasoning structure instead of degrading to
        // flat text on a pod restart / session eviction. See
        // `src/migrations/0006_message_transcript_fidelity.sql` for the
        // rationale + the backward-compat (rolling update + rollback) and
        // idempotency contracts. Strictly additive + nullable: an older pod
        // ignores the columns; new code reads old (NULL) rows unchanged.
        .version = 6,
        .name = "0006_message_transcript_fidelity",
        .sql = @embedFile("migrations/0006_message_transcript_fidelity.sql"),
        .phase = .expand,
    },
    .{
        // Subagent Pass Phase 1 (2026-06-13) — durable outbox for subagent
        // completions. A row is written BEFORE the parent is woken; status
        // flips pending -> delivered once the parent has been notified, so a
        // crash between persist and deliver is recovered by re-delivering
        // 'pending' rows on startup. Mirrors the pending_approvals pattern.
        .version = 7,
        .name = "0007_subagent_results",
        .sql = @embedFile("migrations/0007_subagent_results.sql"),
        .phase = .expand,
    },
    .{
        // Loop-2 substrate (three-loops spec §3.1, docs/memory-contract.md)
        // — durable per-run tool-trace digests. Today's traces are
        // in-memory only (RunTraceStore) and die with the process; this
        // table gives the observer (Task 2: agent_end hook) a place to
        // flush a JSONB digest of the run's tool events so the
        // background-review miner can read them after a restart.
        .version = 8,
        .name = "0008_tool_traces",
        .sql = @embedFile("migrations/0008_tool_traces.sql"),
        .phase = .expand,
    },
    .{
        // WP-02 — schema-wide TTL pruning must not scan each bookkeeping
        // table on every bounded batch. These indexes are built outside a
        // transaction so existing production tables remain writable.
        .version = 9,
        .name = "0009_retention_ttl_indexes",
        .sql = @embedFile("migrations/0009_retention_ttl_indexes.sql"),
        .phase = .expand,
        .concurrent_only = true,
    },
    .{
        // WP-I / F21 — remove pre-guard assistant scaffold memories and exact
        // scaffold graph entities. The migration records hash-only audit
        // events before deleting rows and scopes every graph/vector delete by
        // user_id. See docs/memory-contract.md for the matching contract.
        .version = 10,
        .name = "0010_brain_scaffold_purge",
        .sql = @embedFile("migrations/0010_brain_scaffold_purge.sql"),
        // Data-only static DELETE/UPDATE purge (no schema DDL): the previous
        // binary tolerates the pruned rows, so this is expand-safe under the
        // rollback contract. W.4 classification per the Minutes launch handoff.
        .phase = .expand,
        .allow_expand_data_delete = true,
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

    // Step 2: preflight the complete registry before any migration body runs.
    // This prevents a safe earlier migration from being committed before a
    // later unsafe declaration stops boot halfway through the registry.
    for (migrations) |m| {
        switch (m.phase) {
            .baseline => if (m.version != 1) return error.InvalidBaselineMigration,
            .expand => try validateExpandMigration(m),
            .contract => {
                if (!try rc.isApplied(rc.ctx, m.version)) {
                    return error.ContractMigrationRequiresOperatorApproval;
                }
            },
        }
    }

    // Step 3: iterate migrations, apply unapplied ones in order.
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

// Fixture migrations for tests — small, fast, deterministic. Tests use
// `runWith(rc, &fixture)` to exercise the runner independently of the
// production array and must obey the same explicit-phase contract.
const fixture_migrations = [_]Migration{
    .{ .version = 1, .name = "0001_test_fixture", .sql = "CREATE TABLE {schema}.fixture_a (id INT)", .phase = .baseline },
    .{ .version = 2, .name = "0002_test_fixture", .sql = "CREATE TABLE {schema}.fixture_b (id INT)", .phase = .expand },
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

test "migrations.runWith rejects destructive SQL declared as expand before DDL" {
    var tr = TestRunner{ .allocator = std.testing.allocator };
    defer tr.deinit();

    const unsafe = [_]Migration{.{
        .version = 1,
        .name = "0001_unsafe_expand_fixture",
        .sql = "ALTER TABLE {schema}.fixture DROP COLUMN value",
        .phase = .expand,
    }};

    try std.testing.expectError(error.DestructiveExpandMigration, runWith(tr.context(), &unsafe));
    // Only the idempotent schema_migrations tracker may execute.
    try std.testing.expectEqual(@as(usize, 1), tr.queries.items.len);
    try std.testing.expect(!tr.in_tx);
    try std.testing.expectEqual(@as(usize, 0), tr.applied.count());
}

test "migrations.runWith refuses an unapplied contract migration before DDL" {
    var tr = TestRunner{ .allocator = std.testing.allocator };
    defer tr.deinit();

    const contract = [_]Migration{.{
        .version = 1,
        .name = "0001_contract_fixture",
        .sql = "ALTER TABLE {schema}.fixture DROP COLUMN value",
        .phase = .contract,
    }};

    try std.testing.expectError(error.ContractMigrationRequiresOperatorApproval, runWith(tr.context(), &contract));
    // Only the idempotent schema_migrations tracker may execute.
    try std.testing.expectEqual(@as(usize, 1), tr.queries.items.len);
    try std.testing.expect(!tr.in_tx);
    try std.testing.expectEqual(@as(usize, 0), tr.applied.count());
}

test "migrations.runWith preflights every phase before applying an earlier migration" {
    var tr = TestRunner{ .allocator = std.testing.allocator };
    defer tr.deinit();

    const mixed = [_]Migration{
        .{ .version = 1, .name = "0001_safe_expand", .sql = "CREATE TABLE {schema}.safe (id INT)", .phase = .expand },
        .{ .version = 2, .name = "0002_unsafe_expand", .sql = "DROP TABLE {schema}.safe", .phase = .expand },
    };

    try std.testing.expectError(error.DestructiveExpandMigration, runWith(tr.context(), &mixed));
    try std.testing.expectEqual(@as(usize, 1), tr.queries.items.len);
    try std.testing.expectEqual(@as(usize, 0), tr.applied.count());
}

test "migrations.runWith reserves baseline compatibility for version one" {
    var tr = TestRunner{ .allocator = std.testing.allocator };
    defer tr.deinit();

    const invalid = [_]Migration{.{
        .version = 2,
        .name = "0002_invalid_baseline",
        .sql = "DROP TABLE {schema}.fixture",
        .phase = .baseline,
    }};

    try std.testing.expectError(error.InvalidBaselineMigration, runWith(tr.context(), &invalid));
    try std.testing.expectEqual(@as(usize, 1), tr.queries.items.len);
}

test "migrations.runWith permits a contract migration already recorded by an operator" {
    var tr = TestRunner{ .allocator = std.testing.allocator };
    defer tr.deinit();

    const contract = [_]Migration{.{
        .version = 10,
        .name = "0010_contract_fixture",
        .sql = "ALTER TABLE {schema}.fixture DROP COLUMN value",
        .phase = .contract,
    }};
    try tr.applied.put(tr.allocator, 10, {});

    try runWith(tr.context(), &contract);
    try std.testing.expectEqual(@as(usize, 1), tr.queries.items.len);
    try std.testing.expect(!tr.in_tx);
}

test "validateExpandSql rejects additional rollback-breaking schema operations" {
    const forbidden = [_][]const u8{
        "DROP VIEW {schema}.legacy_view",
        "DROP TYPE {schema}.legacy_status",
        "ALTER TABLE {schema}.fixture RENAME CONSTRAINT old_name TO new_name",
        "ALTER TABLE {schema}.fixture ALTER COLUMN value DROP DEFAULT",
        "CREATE OR REPLACE VIEW {schema}.legacy_view AS SELECT id FROM {schema}.fixture",
        "DO $$ BEGIN EXECUTE 'DROP TABLE {schema}.fixture'; END $$",
        "ALTER TABLE {schema}.fixture ADD CONSTRAINT value_nonempty CHECK (value <> '')",
    };
    for (forbidden) |sql| {
        try std.testing.expectError(error.DestructiveExpandMigration, validateExpandSql(sql));
    }
}

test "validateExpandSql scopes ALTER COLUMN TYPE detection to one statement" {
    try validateExpandSql(
        \\ALTER TABLE {schema}.fixture ALTER COLUMN value SET DEFAULT 1;
        \\CREATE TYPE {schema}.status AS ENUM ('ready');
    );
}

test "validateExpandSql rejects bare TRUNCATE without rejecting a trigger event" {
    try std.testing.expectError(
        error.DestructiveExpandMigration,
        validateExpandSql("TRUNCATE {schema}.fixture"),
    );
    try std.testing.expectError(
        error.DestructiveExpandMigration,
        validateExpandSql("DO $$ BEGIN TRUNCATE {schema}.fixture; END $$"),
    );
    try validateExpandSql(
        "CREATE TRIGGER fixture_before_truncate BEFORE TRUNCATE ON {schema}.fixture FOR EACH STATEMENT EXECUTE FUNCTION {schema}.audit_fixture()",
    );
    try validateExpandSql(
        "CREATE TRIGGER fixture_before_insert_or_truncate BEFORE INSERT OR TRUNCATE ON {schema}.fixture FOR EACH STATEMENT EXECUTE FUNCTION {schema}.audit_fixture()",
    );
    try validateExpandSql(
        "CREATE FUNCTION {schema}.audit_fixture() RETURNS trigger LANGUAGE plpgsql AS $fixture$\nBEGIN\n  RETURN NEW;\nEND;\n$fixture$;\nCREATE TRIGGER fixture_before_truncate BEFORE TRUNCATE ON {schema}.fixture FOR EACH STATEMENT EXECUTE FUNCTION {schema}.audit_fixture()",
    );
}

test "validateExpandSql rejects inline ADD COLUMN NOT NULL without crossing statement boundaries" {
    try std.testing.expectError(
        error.DestructiveExpandMigration,
        validateExpandSql("ALTER TABLE {schema}.fixture ADD COLUMN required_value TEXT NOT NULL"),
    );
    try std.testing.expectError(
        error.DestructiveExpandMigration,
        validateExpandSql(
            "ALTER TABLE {schema}.fixture ADD COLUMN required_value TEXT NOT NULL, ADD COLUMN optional_value TEXT",
        ),
    );
    try validateExpandSql(
        "CREATE TABLE {schema}.new_fixture (id TEXT NOT NULL); ALTER TABLE {schema}.fixture ADD COLUMN optional_value TEXT;",
    );
}

test "validateExpandSql rejects index removal and trigger replacement" {
    const forbidden = [_][]const u8{
        "DROP INDEX CONCURRENTLY IF EXISTS {schema}.fixture_lookup_idx",
        "CREATE OR REPLACE TRIGGER fixture_before_insert BEFORE INSERT ON {schema}.fixture FOR EACH ROW EXECUTE FUNCTION {schema}.audit_fixture()",
    };
    for (forbidden) |sql| {
        try std.testing.expectError(error.DestructiveExpandMigration, validateExpandSql(sql));
    }
}

test "validateExpandSql rejects DELETE FROM including a CTE form" {
    const forbidden = [_][]const u8{
        "DELETE FROM {schema}.fixture",
        "WITH stale AS (SELECT id FROM {schema}.fixture) DELETE FROM {schema}.fixture USING stale WHERE fixture.id = stale.id",
    };
    for (forbidden) |sql| {
        try std.testing.expectError(error.DestructiveExpandMigration, validateExpandSql(sql));
    }
}

test "validateExpandSql rejects W.6 destructive shapes through comments and newlines" {
    const forbidden = [_][]const u8{
        "TRUNCATE /* temporary */ {schema}.fixture",
        "ALTER TABLE {schema}.fixture ADD /* inline */ COLUMN required_value TEXT NOT /* inline */ NULL",
        "DROP /* schema cleanup */ INDEX {schema}.fixture_lookup_idx",
        "DELETE\nFROM {schema}.fixture",
        "CREATE OR /* replacement */ REPLACE TRIGGER fixture_before_insert BEFORE INSERT ON {schema}.fixture FOR EACH ROW EXECUTE FUNCTION {schema}.audit_fixture()",
    };
    for (forbidden) |sql| {
        try std.testing.expectError(error.DestructiveExpandMigration, validateExpandSql(sql));
    }
}

test "validateExpandSql ignores destructive words inside literals and quoted identifiers" {
    try validateExpandSql(
        \\CREATE TABLE {schema}.fixture (
        \\  "drop column" TEXT,
        \\  note TEXT DEFAULT 'drop table and rename column'
        \\)
    );
}

test "validateExpandSql rejects every dynamic EXECUTE shape, even static-looking literals" {
    // The expand gate has NO dynamic-SQL admission: 0010 was rewritten to a
    // static conditional DELETE (PL/pgSQL binds a statement only when its
    // branch first executes) precisely so EXECUTE can stay forbidden.
    const rejected = [_][]const u8{
        "DO $$ BEGIN EXECUTE 'DELETE FROM {schema}.a'; END $$",
        "DO $$ BEGIN EXECUTE 'DROP TABLE {schema}.memories'; END $$",
        "DO $$ BEGIN EXECUTE format('DELETE FROM %I', tbl); END $$",
        "SELECT 1 EXECUTE now",
    };
    for (rejected) |sql| {
        try std.testing.expectError(error.DestructiveExpandMigration, validateExpandSql(sql));
    }
}

test "validateExpandMigration admits only 0010's audited data-only purge" {
    // Regression guard for the shipped registry: 0010 is a data-only purge
    // (temp tables + static DELETE/UPDATE/INSERT audit rows, no schema DDL,
    // no EXECUTE) classified .expand. Future validator hardening that starts
    // rejecting static DELETE must whitelist this shipped migration
    // deliberately, not break boot.
    const migration = blk: {
        for (MIGRATIONS) |candidate| {
            if (candidate.version == 10) break :blk candidate;
        }
        return error.Migration0010NotFound;
    };
    try std.testing.expectError(error.DestructiveExpandMigration, validateExpandSql(migration.sql));
    try validateExpandMigration(migration);
}

test "validateExpandMigration keeps destructive DDL forbidden for a data-delete exception" {
    const migration = Migration{
        .version = 11,
        .name = "0011_delete_exception_fixture",
        .sql = "DROP INDEX {schema}.fixture_lookup_idx",
        .phase = .expand,
        .allow_expand_data_delete = true,
    };
    try std.testing.expectError(error.DestructiveExpandMigration, validateExpandMigration(migration));
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

test "WP-02 retention indexes use concurrent schema-wide access paths" {
    const found = blk: {
        for (MIGRATIONS) |m| {
            if (m.version == 9) break :blk m;
        }
        return error.Migration0009NotFound;
    };
    try std.testing.expectEqualStrings("0009_retention_ttl_indexes", found.name);
    try std.testing.expect(found.concurrent_only);
    try std.testing.expect(std.mem.indexOf(u8, found.sql, "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tool_traces_retention") != null);
    try std.testing.expect(std.mem.indexOf(u8, found.sql, "ON {schema}.tool_traces (created_at)") != null);
    try std.testing.expect(std.mem.indexOf(u8, found.sql, "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_memory_events_retention") != null);
    try std.testing.expect(std.mem.indexOf(u8, found.sql, "ON {schema}.memory_events (created_at)") != null);
    try std.testing.expect(std.mem.indexOf(u8, found.sql, "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_subagent_results_retention") != null);
    try std.testing.expect(std.mem.indexOf(u8, found.sql, "COALESCE(delivered_at, created_at)") != null);
    try std.testing.expect(std.mem.indexOf(u8, found.sql, "WHERE status = 'delivered'") != null);
}

test "WP-I migration 0010 purges only explicit Brain scaffold artifacts with audit events" {
    const found = blk: {
        for (MIGRATIONS) |m| {
            if (m.version == 10) break :blk m;
        }
        return error.Migration0010NotFound;
    };
    try std.testing.expectEqualStrings("0010_brain_scaffold_purge", found.name);
    try std.testing.expect(!found.concurrent_only);

    const sql = found.sql;
    try std.testing.expect(std.mem.indexOf(u8, sql, "[[ZAKI_") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "<memory_for_turn") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "<memory_context") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "scaffold_purge") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "scaffold_entity_purge") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "DELETE FROM {schema}.memory_edges") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "DELETE FROM {schema}.memories") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "DELETE FROM {schema}.memory_entities") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "memory_embeddings") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "content_hash") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "UPDATE {schema}.memory_events") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "payload_hash") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "memory_id = NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "encode(digest(content, 'sha256'), 'hex')") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "DROP TABLE") == null);
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

test "Wave C C4 — migration 0006 adds NULLABLE tool_calls + reasoning, idempotently + backward-compatibly" {
    // Static contract test (no live DB): the transcript-fidelity migration
    // must add the two columns the reload path depends on, and must do so in
    // a way that is (a) idempotent on re-apply and (b) backward-compatible
    // with an older pod during a rolling update / after a rollback. A future
    // edit that drops the IF NOT EXISTS guard (breaks double-apply) or makes
    // a column NOT NULL (breaks old-pod inserts that omit it) is caught here
    // at compile-test time without a Postgres.
    const found = blk: {
        for (MIGRATIONS) |m| {
            if (m.version == 6) break :blk m;
        }
        return error.Migration0006NotFound;
    };
    try std.testing.expectEqualStrings("0006_message_transcript_fidelity", found.name);
    const sql = found.sql;

    // Both columns added, NULLABLE (no NOT NULL / no DEFAULT that would
    // rewrite the table or break an old-pod insert that omits them).
    try std.testing.expect(std.mem.indexOf(u8, sql, "ADD COLUMN IF NOT EXISTS tool_calls JSONB") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ADD COLUMN IF NOT EXISTS reasoning TEXT") != null);
    // Belt-and-suspenders: neither add declares NOT NULL.
    try std.testing.expect(std.mem.indexOf(u8, sql, "tool_calls JSONB NOT NULL") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "reasoning TEXT NOT NULL") == null);

    // Transactional (no CREATE INDEX CONCURRENTLY) so the runner wraps it
    // in BEGIN/COMMIT — a mid-migration failure rolls back cleanly.
    try std.testing.expect(!found.concurrent_only);
    try std.testing.expect(std.mem.indexOf(u8, sql, "CONCURRENTLY") == null);
}

test "Wave C C4 — every registered migration is idempotently re-appliable (no unguarded DDL)" {
    // P1-10 acceptance, enforced as a STATIC invariant across the WHOLE
    // migration set (not just the new one): applying the full set twice must
    // be a clean no-op. Any CREATE TABLE / CREATE [UNIQUE] INDEX / ADD COLUMN
    // that omits its IF NOT EXISTS guard, or any bare ADD CONSTRAINT outside a
    // DO-block existence guard, would fault on the second apply. This walks
    // every migration's SQL and fails if it finds such an unguarded statement,
    // so a future migration that forgets a guard is caught at compile-test
    // time — independent of whether a Postgres double-apply test happens to
    // exercise that exact table.
    for (MIGRATIONS) |m| {
        try assertGuardedDdl(m);
    }
}

fn assertGuardedDdl(m: Migration) !void {
    // Scan line-by-line for the leading DDL keyword of each guarded statement
    // kind, requiring the idempotency guard on the same logical statement.
    // We tolerate ADD CONSTRAINT / ADD PRIMARY KEY ONLY when the migration
    // wraps them in a DO-block existence guard (0001's FK + tasks re-key).
    var line_iter = std.mem.tokenizeAny(u8, m.sql, "\n");
    while (line_iter.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "--")) continue;
        const upper_has = struct {
            fn f(hay: []const u8, needle: []const u8) bool {
                return std.ascii.indexOfIgnoreCase(hay, needle) != null;
            }
        }.f;
        if (upper_has(line, "CREATE TABLE ")) {
            try std.testing.expect(upper_has(line, "IF NOT EXISTS"));
        }
        if (upper_has(line, "CREATE INDEX ") or upper_has(line, "CREATE UNIQUE INDEX ")) {
            try std.testing.expect(upper_has(line, "IF NOT EXISTS"));
        }
        if (upper_has(line, "ADD COLUMN ")) {
            try std.testing.expect(upper_has(line, "IF NOT EXISTS"));
        }
        // Bare top-level ADD CONSTRAINT / ADD PRIMARY KEY are allowed ONLY
        // inside a DO-block existence guard; require the migration to contain
        // a DO $$ block when it uses either form.
        if (upper_has(line, "ADD CONSTRAINT ") or upper_has(line, "ADD PRIMARY KEY")) {
            try std.testing.expect(std.mem.indexOf(u8, m.sql, "DO $$") != null);
        }
    }
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
