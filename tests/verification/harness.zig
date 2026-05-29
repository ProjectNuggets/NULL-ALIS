//! S6 verification matrix shared helpers.
//!
//! Pins:
//!   * postgres URL resolver via env_rebrand (canonical + legacy fallback).
//!     OOM and other genuine errors PROPAGATE — only env-var-absent
//!     collapses to SkipZigTest.
//!   * `newManager` — opens a live Postgres connection on a unique schema
//!     and propagates connection failures as REAL errors (not skips).
//!   * unique per-test schema name (microsecond timestamp + slug).
//!   * cached project-file loader for the matrix's doc-contract scans.
//!   * `openApiPathBlock` — extract a single path's response block from
//!     the OpenAPI YAML so response-code assertions stay scoped to the
//!     declaring route (not a global substring match).

const std = @import("std");
const nullalis = @import("nullalis");
const build_options = @import("build_options");
const env_rebrand = nullalis.env_rebrand;
const zaki_state = nullalis.zaki_state;

pub const PG_URL_CANONICAL = "NULLALIS_POSTGRES_TEST_URL";
pub const PG_URL_LEGACY = "NULLCLAW_POSTGRES_TEST_URL";

/// Resolve the postgres test URL.
///
/// Returns `error.SkipZigTest` ONLY when neither env var is set. The
/// build-options gate (`enable_postgres == false`) is handled at
/// `root.zig` compile time, so by the time this code runs we know the
/// engine is on.
///
/// Every other env_rebrand error (OOM, WTF-8) PROPAGATES — silently
/// collapsing them would let a harness bug ship as a green matrix.
pub fn requirePostgresUrl(allocator: std.mem.Allocator) ![]u8 {
    const maybe_url = env_rebrand.getEnvOwnedWithRebrand(
        allocator,
        PG_URL_CANONICAL,
        PG_URL_LEGACY,
    ) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    return maybe_url orelse error.SkipZigTest;
}

/// Build a unique schema name keyed on microsecond timestamp + a short slug.
/// `buf` must be ≥ 96 bytes. The name is lowercase ASCII safe for raw SQL.
pub fn schemaName(buf: []u8, slug: []const u8) ![]const u8 {
    const stamp = std.time.microTimestamp();
    return try std.fmt.bufPrint(buf, "nullalis_s6_{s}_{d}", .{ slug, stamp });
}

/// Open a live Postgres connection on a unique schema. Connection
/// failures PROPAGATE as the underlying error (not collapsed to
/// SkipZigTest) — a bogus `NULLALIS_POSTGRES_TEST_URL` must fail the
/// matrix, not silently pass. URL absence is handled at the caller via
/// `requirePostgresUrl`.
///
/// On success the schema is freshly created and migrated by
/// `Manager.init`. Caller owns the `*Manager` (deinit it).
pub fn newManager(
    allocator: std.mem.Allocator,
    test_url: []const u8,
    schema: []const u8,
) !zaki_state.Manager {
    return zaki_state.Manager.init(allocator, .{
        .backend = "postgres",
        .postgres = .{
            .connection_string = test_url,
            .schema = schema,
        },
    });
}

/// Shared schema-cleanup + manager-deinit helper for live-PG tests.
/// Drop failures are logged via `std.debug.print` (surfaced in CI logs)
/// rather than silently swallowed — a drop failure may indicate a real
/// test-side bug (held lock, dangling transaction) but should not turn
/// an otherwise-passing test red. `mgr.deinit` is unconditional so the
/// connection pool tears down even if drop fails.
///
/// Use as `defer harness.dropAndDeinit(&mgr, "test-slug");`.
pub fn dropAndDeinit(mgr: *zaki_state.Manager, label: []const u8) void {
    mgr.dropSchemaForTests() catch |err| {
        std.debug.print(
            "S6 cleanup ({s}): dropSchemaForTests failed: {s} — schema may leak\n",
            .{ label, @errorName(err) },
        );
    };
    mgr.deinit();
}

// ── Project-file cache ────────────────────────────────────────────────

const CacheEntry = struct {
    path: []const u8,
    bytes: []u8,
};

const CacheState = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(CacheEntry) = .empty,
};

var cache_state: ?*CacheState = null;
var cache_mutex: std.Thread.Mutex = .{};

fn cwdLooksLikeRepoRoot() bool {
    const sentinels = [_][]const u8{ "build.zig", "tests/verification/root.zig" };
    for (sentinels) |s| {
        std.fs.cwd().access(s, .{}) catch continue;
        return true;
    }
    return false;
}

fn loadAndCacheLocked(rel_path: []const u8) ![]const u8 {
    const state = cache_state orelse blk: {
        const heap_state = std.heap.page_allocator.create(CacheState) catch return error.OutOfMemory;
        heap_state.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
        cache_state = heap_state;
        break :blk heap_state;
    };

    for (state.entries.items) |e| {
        if (std.mem.eql(u8, e.path, rel_path)) return e.bytes;
    }

    var file = std.fs.cwd().openFile(rel_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (cwdLooksLikeRepoRoot()) return err;
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer file.close();

    const cache_alloc = state.arena.allocator();
    const stat = try file.stat();
    const bytes = try cache_alloc.alloc(u8, stat.size);
    const n = try file.readAll(bytes);
    const slice = bytes[0..n];

    try state.entries.append(cache_alloc, .{ .path = rel_path, .bytes = slice });
    return slice;
}

/// Load a project-root-relative file with process-lifetime caching.
/// Returns a BORROWED slice — caller must NOT free.
pub fn loadProjectFile(rel_path: []const u8) ![]const u8 {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    return try loadAndCacheLocked(rel_path);
}

/// Find the SQL body of a migration by its short name.
pub fn migrationSql(name: []const u8) ?[]const u8 {
    for (nullalis.migrations.MIGRATIONS) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.sql;
    }
    return null;
}

// ── OpenAPI path-block scoping ────────────────────────────────────────
//
// Replaces global substring matches like
//   indexOf(yaml, "'409'")
// (which would pass if ANY route in the whole document had a 409) with
// a path-scoped check that locates the path declaration line and
// returns only the bytes that belong to THAT path's block.
//
// OpenAPI paths use 2-space indentation:
//   paths:
//     /api/v1/users/{uid}/sessions/{key}/approve:
//       post:
//         responses:
//           '409':
//             ...
//     /api/v1/users/{uid}/sessions/{key}/cancel:
//       ...
//
// A path block is delimited by the next line at the same 2-space
// indentation level that starts with `/`.

/// Extract the bytes for a single path's block in `yaml`. Returns null
/// when no path containing `path_substr` is found.
///
/// `path_substr` is matched as a substring of the path declaration line
/// (so callers can pass `"/cancel:"` or `"/sessions/{key}/cancel:"` —
/// both anchor on the canonical session-scoped route).
///
/// The block extends from the declaration line up to (but not including)
/// the NEXT sibling path declaration OR the next top-level section
/// (`components:`, `tags:`, `info:`, etc. — any line at column 0). The
/// second terminator is critical for the last path under `paths:` —
/// without it the block would extend into `components:` and the
/// substring scan would silently match unrelated responses declared
/// under e.g. `components.responses`.
///
/// `\r` is stripped from each line before matching so CRLF-terminated
/// files (Windows checkouts) work without modification.
pub fn openApiPathBlock(yaml: []const u8, path_substr: []const u8) ?[]const u8 {
    var line_iter = std.mem.splitScalar(u8, yaml, '\n');
    var cursor: usize = 0;
    while (line_iter.next()) |raw_line| : (cursor += raw_line.len + 1) {
        const line = trimTrailingCr(raw_line);
        if (line.len < 4) continue;
        if (line[0] != ' ' or line[1] != ' ') continue;
        if (line.len > 2 and line[2] == ' ') continue; // deeper than 2 spaces
        if (line[2] != '/') continue;
        if (line[line.len - 1] != ':') continue;
        if (std.mem.indexOf(u8, line, path_substr) == null) continue;

        // Found the declaring line. Block ends at the NEXT sibling path
        // entry (`  /...:`) OR the next top-level YAML section
        // (any non-blank line at column 0 with no leading spaces).
        const block_start = cursor + raw_line.len + 1;
        if (block_start >= yaml.len) return yaml[cursor..];
        const rest = yaml[block_start..];
        var inner_iter = std.mem.splitScalar(u8, rest, '\n');
        var inner_cursor: usize = 0;
        while (inner_iter.next()) |raw_inner| : (inner_cursor += raw_inner.len + 1) {
            const inner = trimTrailingCr(raw_inner);
            // Sibling path entry: 2-space-indented `/`-prefixed.
            if (inner.len >= 3 and inner[0] == ' ' and inner[1] == ' ' and inner[2] == '/') {
                return yaml[cursor .. block_start + inner_cursor];
            }
            // Top-level YAML section: column-0 non-blank, non-comment.
            // (`components:`, `tags:`, `info:`, etc.)
            if (inner.len >= 1 and inner[0] != ' ' and inner[0] != '#') {
                return yaml[cursor .. block_start + inner_cursor];
            }
        }
        return yaml[cursor..];
    }
    return null;
}

fn trimTrailingCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

// ── Self-tests ────────────────────────────────────────────────────────────

test "harness: schemaName builds a unique lowercase identifier" {
    var buf: [96]u8 = undefined;
    const name = try schemaName(&buf, "demo");
    try std.testing.expect(std.mem.startsWith(u8, name, "nullalis_s6_demo_"));
    try std.testing.expect(name.len > "nullalis_s6_demo_".len);
}

test "harness: cwdLooksLikeRepoRoot returns true from a normal `zig build` invocation" {
    try std.testing.expect(cwdLooksLikeRepoRoot());
}

test "harness: loadProjectFile returns the same borrowed slice across two calls (cache pin)" {
    const a = try loadProjectFile("docs/openapi-v1.yaml");
    const b = try loadProjectFile("docs/openapi-v1.yaml");
    try std.testing.expectEqual(a.ptr, b.ptr);
    try std.testing.expectEqual(a.len, b.len);
    try std.testing.expect(a.len > 0);
}

test "harness: openApiPathBlock isolates a path block and excludes sibling routes" {
    const synth =
        \\paths:
        \\  /api/v1/foo:
        \\    post:
        \\      responses:
        \\        '200':
        \\          description: ok
        \\  /api/v1/bar:
        \\    post:
        \\      responses:
        \\        '409':
        \\          description: conflict
    ;
    const foo_block = openApiPathBlock(synth, "/foo:") orelse return error.FooBlockNotFound;
    try std.testing.expect(std.mem.indexOf(u8, foo_block, "'200'") != null);
    try std.testing.expect(std.mem.indexOf(u8, foo_block, "'409'") == null); // bar's, not foo's

    const bar_block = openApiPathBlock(synth, "/bar:") orelse return error.BarBlockNotFound;
    try std.testing.expect(std.mem.indexOf(u8, bar_block, "'409'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bar_block, "'200'") == null);

    try std.testing.expect(openApiPathBlock(synth, "/nonexistent:") == null);
}

test "harness: openApiPathBlock terminates at the next top-level YAML section" {
    // Regression pin: a path that is the LAST entry under `paths:` must
    // NOT have its block extended into `components:` / `tags:` etc.
    // Without this, a response code declared in `components.responses`
    // would be falsely matched against the last path's block.
    const synth =
        \\paths:
        \\  /api/v1/only-route:
        \\    post:
        \\      summary: the only path
        \\components:
        \\  responses:
        \\    '409':
        \\      description: shared conflict template
    ;
    const block = openApiPathBlock(synth, "/only-route:") orelse return error.BlockNotFound;
    try std.testing.expect(std.mem.indexOf(u8, block, "the only path") != null);
    // The CRITICAL assertion: the `components:` section's 409 declaration
    // must NOT bleed into this block.
    try std.testing.expect(std.mem.indexOf(u8, block, "'409'") == null);
    try std.testing.expect(std.mem.indexOf(u8, block, "components") == null);
}

test "harness: openApiPathBlock tolerates CRLF line endings" {
    // Windows-checkout safety: `\r\n` line termination must not break the
    // path/section detection.
    const synth = "paths:\r\n  /api/v1/foo:\r\n    post:\r\n      x: y\r\n  /api/v1/bar:\r\n    post:\r\n      x: z\r\n";
    const foo_block = openApiPathBlock(synth, "/foo:") orelse return error.FooBlockNotFound;
    try std.testing.expect(std.mem.indexOf(u8, foo_block, "/foo:") != null);
    try std.testing.expect(std.mem.indexOf(u8, foo_block, "/bar:") == null);
}
