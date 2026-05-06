//! V1.10-D — supersede filter shared by memory-presenting tools.
//!
//! ## Why this module exists
//!
//! V1.10-A integrated the supersede filter into `agent/memory_loader.zig`
//! so warm-context retrieval skips rows whose
//! `metadata.superseded_by_correction` is set. ZAKI's stress-test
//! report (2026-05-06) revealed the gap: when the agent calls a
//! retrieval TOOL (e.g. `memory_recall`, `memory_timeline`,
//! `memory_list`) instead of reading warm context, the tools' SQL
//! paths bypass the loader-side filter and return superseded rows as
//! truth-equivalent.
//!
//! ZAKI named the bug himself: *"the marks didn't persist across
//! retrieval. So they still surface alongside the truth."*
//!
//! V1.10-D closes that loop by giving each memory-presenting tool a
//! one-call entry to:
//!   1. Fetch the supersede skip-set once at the tool boundary
//!   2. Filter returned entries against that set before formatting
//!
//! ## Why a shared helper rather than inlining
//!
//! Three tools (memory_recall, memory_timeline, memory_list) need
//! identical fetch + filter logic. Inlined, that's ~15 LOC × 3 with
//! drift risk. Shared, it's one canonical implementation; future
//! memory-presenting tools opt in with three lines.
//!
//! The helper functions DO NOT throw on SQL/state errors — they
//! degrade to "no skip-set" silently (with a debug log). The
//! supersede filter is a quality-of-life improvement, never a
//! correctness gate. A failed fetch returns the unfiltered set
//! rather than an empty result.
//!
//! ## Tenant binding
//!
//! Each consuming tool exposes `state_mgr: ?*Manager` and
//! `user_id: ?i64` fields, wired by `tools/root.zig::bindStateMgrTenant`.
//! When EITHER is null, fetchSupersededKeys returns an empty slice
//! and the filter becomes a no-op — graceful degrade for
//! non-postgres builds and pre-tenant deploys.

const std = @import("std");
const zaki_state = @import("../zaki_state.zig");
const mem_root = @import("../memory/root.zig");

const log = std.log.scoped(.supersede_filter);

/// Fetch the set of memory keys currently marked
/// `metadata.superseded_by_correction` for the tenant. Caller frees
/// each []u8 + the outer slice with `freeKeys`.
///
/// Returns an empty slice (allocated, len=0) when:
///   - `state_mgr` is null (non-postgres build / standalone deploy)
///   - `user_id` is null (no tenant context wired)
///   - the SQL fetch errors (graceful degrade — surveyor failure
///     never breaks retrieval; just means filtering doesn't apply
///     this turn)
///
/// Cost: 1 SQL per tool invocation that needs filtering. Bounded by
/// count of currently-superseded rows for this tenant. With ~10-100
/// corrections accumulated over a typical user's lifetime, the
/// result set stays small. The `(user_id, key)` index covers the
/// scan; a future GIN index on `metadata` would accelerate this
/// further at scale.
pub fn fetchSupersededKeys(
    allocator: std.mem.Allocator,
    state_mgr: ?*zaki_state.Manager,
    user_id: ?i64,
) [][]u8 {
    const sm = state_mgr orelse return allocator.alloc([]u8, 0) catch &[_][]u8{};
    const uid = user_id orelse return allocator.alloc([]u8, 0) catch &[_][]u8{};

    return sm.findSupersededMemoryKeys(allocator, uid) catch |err| blk: {
        log.debug("fetchSupersededKeys.failed error={s} — falling back to empty skip-set", .{@errorName(err)});
        break :blk allocator.alloc([]u8, 0) catch &[_][]u8{};
    };
}

/// Free a slice returned by `fetchSupersededKeys`.
pub fn freeKeys(allocator: std.mem.Allocator, keys: [][]u8) void {
    for (keys) |k| allocator.free(k);
    if (keys.len > 0) allocator.free(keys);
}

/// True when `key` appears in the superseded skip-set. O(N) linear
/// scan — fine for the typical 10-100 entry skip-set; if the set
/// grows significantly the caller should switch to a hash set.
pub fn isKeySuperseded(key: []const u8, superseded_keys: []const []u8) bool {
    for (superseded_keys) |sk| {
        if (std.mem.eql(u8, key, sk)) return true;
    }
    return false;
}

/// Convenience: filter a MemoryEntry slice against the skip-set.
/// Returns a NEW slice with non-superseded entries copied in
/// allocation order; original entries' ownership is unchanged
/// (caller still calls `freeEntries(original)` afterward, which
/// will free both kept and dropped). The returned slice is a flat
/// copy — same MemoryEntry contents, different array allocation.
///
/// This is safe because MemoryEntry is a struct of borrowed slices
/// owned by the source slice's allocator; copying the struct copies
/// the borrow, not the data. The deinit happens once via the
/// original slice's `freeEntries`, not via the filtered copy.
pub fn filterEntries(
    allocator: std.mem.Allocator,
    entries: []const mem_root.MemoryEntry,
    superseded_keys: []const []u8,
) ![]mem_root.MemoryEntry {
    if (superseded_keys.len == 0) {
        // Fast path: nothing to skip. Copy as-is.
        const out = try allocator.alloc(mem_root.MemoryEntry, entries.len);
        @memcpy(out, entries);
        return out;
    }
    var kept: usize = 0;
    for (entries) |e| {
        if (!isKeySuperseded(e.key, superseded_keys)) kept += 1;
    }
    const out = try allocator.alloc(mem_root.MemoryEntry, kept);
    var i: usize = 0;
    for (entries) |e| {
        if (isKeySuperseded(e.key, superseded_keys)) continue;
        out[i] = e;
        i += 1;
    }
    return out;
}

// ════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════

test "isKeySuperseded matches exact key" {
    const keys_data = [_][]u8{
        @constCast("durable_fact/A"),
        @constCast("durable_fact/B"),
    };
    const keys: []const []u8 = &keys_data;
    try std.testing.expect(isKeySuperseded("durable_fact/A", keys));
    try std.testing.expect(isKeySuperseded("durable_fact/B", keys));
    try std.testing.expect(!isKeySuperseded("durable_fact/C", keys));
    try std.testing.expect(!isKeySuperseded("", keys));
}

test "isKeySuperseded returns false on empty skip-set" {
    const empty: []const []u8 = &[_][]u8{};
    try std.testing.expect(!isKeySuperseded("any_key", empty));
}

test "filterEntries fast-path with empty skip-set returns full copy" {
    const allocator = std.testing.allocator;
    const entries = [_]mem_root.MemoryEntry{
        .{
            .id = "1",
            .key = "k1",
            .content = "c1",
            .category = .core,
            .timestamp = "0",
        },
    };
    const empty: []const []u8 = &[_][]u8{};
    const out = try filterEntries(allocator, &entries, empty);
    defer allocator.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("k1", out[0].key);
}

test "filterEntries drops superseded" {
    const allocator = std.testing.allocator;
    const entries = [_]mem_root.MemoryEntry{
        .{
            .id = "1",
            .key = "kept",
            .content = "c1",
            .category = .core,
            .timestamp = "0",
        },
        .{
            .id = "2",
            .key = "dropped",
            .content = "c2",
            .category = .core,
            .timestamp = "0",
        },
    };
    const skip_data = [_][]u8{@constCast("dropped")};
    const skip: []const []u8 = &skip_data;
    const out = try filterEntries(allocator, &entries, skip);
    defer allocator.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("kept", out[0].key);
}
