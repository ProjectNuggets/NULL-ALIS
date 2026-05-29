//! S6 verification matrix shared helpers.
//!
//! Pins:
//!   * postgres URL resolver via env_rebrand (canonical + legacy fallback).
//!     OOM and other genuine errors PROPAGATE — only env-var-absent collapses
//!     to SkipZigTest.
//!   * unique per-test schema name (microsecond timestamp + slug).
//!   * cached project-file loader for the matrix's doc-contract scans —
//!     reads each file at most once per test process, propagates real
//!     errors (missing file when CWD looks like repo root → real failure,
//!     not vacuously-green skip).
//!
//! Heavier per-surface fixtures (zaki_state.Manager init, gateway
//! fixtures) live in the per-surface test files because their config
//! shape varies.

const std = @import("std");
const nullalis = @import("nullalis");
const build_options = @import("build_options");
const env_rebrand = nullalis.env_rebrand;

pub const PG_URL_CANONICAL = "NULLALIS_POSTGRES_TEST_URL";
pub const PG_URL_LEGACY = "NULLCLAW_POSTGRES_TEST_URL";

/// Resolve the postgres test URL.
///
/// Returns `error.SkipZigTest` ONLY when:
///   * the build was compiled without `-Dengines=...,postgres`, or
///   * neither env var is set.
///
/// Every other error (OOM, WTF-8 decode, etc.) propagates as itself —
/// silently collapsing them would let a harness bug ship as a green
/// matrix.
pub fn requirePostgresUrl(allocator: std.mem.Allocator) ![]u8 {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const maybe_url = env_rebrand.getEnvOwnedWithRebrand(
        allocator,
        PG_URL_CANONICAL,
        PG_URL_LEGACY,
    ) catch |err| switch (err) {
        // Genuine env-var absence on this platform — distinct from a
        // configured-but-broken URL or an OOM.
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        // Everything else (OOM, WTF-8, etc.) PROPAGATES. Do not swallow.
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

// ── Project-file cache ────────────────────────────────────────────────
//
// The matrix's doc-contract tests load `docs/openapi-v1.yaml`,
// `docs/ui-handoff.md`, `docs/online-agent-contract.md`, and
// `docs/extension-ws-contract.md`. Without caching, each test pays a
// fresh openFile + readToEndAlloc + free; with 21+ load sites this is
// ~25 disk reads and ~25 testing-allocator alloc/free pairs that
// produce identical bytes. The cache reads each file at most once per
// test process, returns a borrowed slice owned by the cache (caller
// does NOT free), and propagates errors rather than swallowing them
// when CWD looks like the repo root.

const CacheEntry = struct {
    path: []const u8, // borrowed (caller-provided literal)
    bytes: []u8, // owned by cache_arena
};

const CacheState = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(CacheEntry) = .empty,
};

var cache_state: ?*CacheState = null;
var cache_mutex: std.Thread.Mutex = .{};

fn cwdLooksLikeRepoRoot() bool {
    // Sentinel files we expect at the project root. If even one is
    // present, treat CWD as the repo root and propagate FileNotFound
    // as a real failure. If none are present, we may be running from
    // a sub-checkout or an IDE working dir — fall back to SkipZigTest
    // for legitimate "the harness can't see the docs" cases.
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

    // Linear scan — 4 docs max, dwarfed by the I/O cost the cache avoids.
    for (state.entries.items) |e| {
        if (std.mem.eql(u8, e.path, rel_path)) return e.bytes;
    }

    var file = std.fs.cwd().openFile(rel_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Distinguish "test invoked from a non-repo-root CWD" (skip
            // cleanly — IDE/sub-checkout scenario) from "doc was actually
            // deleted / moved" (real failure — the matrix exists to catch
            // exactly this).
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

/// Load a project-root-relative file (e.g. `docs/openapi-v1.yaml`) with
/// process-lifetime caching. Returns a BORROWED slice — caller must NOT
/// free. The cache is thread-safe.
///
/// Returns `error.SkipZigTest` only when the file is missing AND CWD does
/// NOT look like the repo root (treat as a runner-env issue, not a
/// verification failure). When CWD has the repo sentinels, `FileNotFound`
/// PROPAGATES — a doc that was actually deleted is exactly what the matrix
/// is supposed to catch.
pub fn loadProjectFile(rel_path: []const u8) ![]const u8 {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    return try loadAndCacheLocked(rel_path);
}

/// Find the SQL body of a migration by its short name (e.g.
/// `"0001_initial_schema"`). Avoids `@embedFile` cross-package issues
/// by going through the already-embedded `migrations.MIGRATIONS` table.
pub fn migrationSql(name: []const u8) ?[]const u8 {
    for (nullalis.migrations.MIGRATIONS) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.sql;
    }
    return null;
}

// ── Self-tests ────────────────────────────────────────────────────────────

test "harness: schemaName builds a unique lowercase identifier" {
    var buf: [96]u8 = undefined;
    const name = try schemaName(&buf, "demo");
    try std.testing.expect(std.mem.startsWith(u8, name, "nullalis_s6_demo_"));
    try std.testing.expect(name.len > "nullalis_s6_demo_".len);
}

test "harness: cwdLooksLikeRepoRoot returns true from a normal `zig build` invocation" {
    // The default `addRunArtifact` CWD is the project root; the matrix's
    // contract depends on this. Pin it explicitly — if a future runner
    // change starts invoking the test binary from a sub-directory, this
    // test fails LOUD and the operator picks up the rebase work.
    try std.testing.expect(cwdLooksLikeRepoRoot());
}

test "harness: loadProjectFile returns the same borrowed slice across two calls (cache pin)" {
    // Cache hit → identical pointer + length. A regression that bypasses
    // the cache (e.g. allocates a fresh slice each call) makes the
    // pointers differ.
    const a = try loadProjectFile("docs/openapi-v1.yaml");
    const b = try loadProjectFile("docs/openapi-v1.yaml");
    try std.testing.expectEqual(a.ptr, b.ptr);
    try std.testing.expectEqual(a.len, b.len);
    try std.testing.expect(a.len > 0);
}
