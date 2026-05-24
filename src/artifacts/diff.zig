//! Wave 2C — canvas/artifacts backend: simple line diff.
//!
//! Naive O(n*m) longest-common-subsequence diff with line granularity.
//! "Good enough for v1" per spec — the FE may upgrade to Myers/patience
//! later. Tracks insertions (+) and deletions (-); shared lines pass
//! through with a single space prefix.
//!
//! Output format mirrors `git diff --no-context`:
//!   `+added line`
//!   `-deleted line`
//!   ` unchanged line`
//!
//! Deterministic, allocation-bounded, no external deps. Cap inputs at
//! 4096 lines per side to keep the LCS table under ~16M cells (~64 MB
//! at 4 bytes per cell). Inputs over the cap fall back to "full
//! replace" output so the endpoint never blocks the request thread on
//! a degenerate megabyte-of-lines diff.

const std = @import("std");

/// Hard cap on per-side line count. The LCS table is `m * n * @sizeOf(u32)`
/// — capping each side at 4096 keeps the table at ~64 MB worst-case,
/// which we still won't allocate in practice because real artifact diffs
/// are tens-to-hundreds of lines. The cap exists to refuse the worst case
/// rather than to be hit in normal operation.
pub const MAX_DIFF_LINES: usize = 4096;

/// Compute a unified-style textual diff between `before` and `after`.
/// Returns a heap-allocated owned slice the caller must free.
///
/// Behaviour:
///   * `before == after` → empty string (callers can short-circuit on len==0).
///   * Either side over MAX_DIFF_LINES → "full replace" diff: every
///     before-line as `-`, every after-line as `+`. The endpoint stays
///     functional but the diff isn't minimal — surface this in metadata
///     when needed.
pub fn unifiedLineDiff(
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
) ![]u8 {
    const before_lines = try splitLines(allocator, before);
    defer allocator.free(before_lines);
    const after_lines = try splitLines(allocator, after);
    defer allocator.free(after_lines);

    if (std.mem.eql(u8, before, after)) {
        return try allocator.alloc(u8, 0);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (before_lines.len > MAX_DIFF_LINES or after_lines.len > MAX_DIFF_LINES) {
        // Degenerate-case fallback: pure replace. Keeps the endpoint
        // functional without DOS-ing the request thread.
        try emitReplace(allocator, &out, before_lines, after_lines);
        return out.toOwnedSlice(allocator);
    }

    // LCS table. dp[i][j] = LCS length of before_lines[0..i] / after_lines[0..j].
    const m = before_lines.len;
    const n = after_lines.len;
    const dp = try allocator.alloc(u32, (m + 1) * (n + 1));
    defer allocator.free(dp);
    @memset(dp, 0);
    var i: usize = 1;
    while (i <= m) : (i += 1) {
        var j: usize = 1;
        while (j <= n) : (j += 1) {
            if (std.mem.eql(u8, before_lines[i - 1], after_lines[j - 1])) {
                dp[i * (n + 1) + j] = dp[(i - 1) * (n + 1) + (j - 1)] + 1;
            } else {
                const up = dp[(i - 1) * (n + 1) + j];
                const left = dp[i * (n + 1) + (j - 1)];
                dp[i * (n + 1) + j] = if (up >= left) up else left;
            }
        }
    }

    // Backtrack to build the diff (in reverse). Walk the table from
    // (m, n) toward (0, 0), emitting ops as we go.
    var ops: std.ArrayListUnmanaged(DiffOp) = .empty;
    defer ops.deinit(allocator);
    var ri: usize = m;
    var rj: usize = n;
    while (ri > 0 or rj > 0) {
        if (ri > 0 and rj > 0 and std.mem.eql(u8, before_lines[ri - 1], after_lines[rj - 1])) {
            try ops.append(allocator, .{ .kind = .same, .text = before_lines[ri - 1] });
            ri -= 1;
            rj -= 1;
        } else if (rj > 0 and (ri == 0 or dp[ri * (n + 1) + (rj - 1)] >= dp[(ri - 1) * (n + 1) + rj])) {
            try ops.append(allocator, .{ .kind = .add, .text = after_lines[rj - 1] });
            rj -= 1;
        } else {
            try ops.append(allocator, .{ .kind = .del, .text = before_lines[ri - 1] });
            ri -= 1;
        }
    }

    // Ops are in reverse — walk back-to-front to emit forward order.
    var k: usize = ops.items.len;
    while (k > 0) {
        k -= 1;
        const op = ops.items[k];
        const prefix: u8 = switch (op.kind) {
            .same => ' ',
            .add => '+',
            .del => '-',
        };
        try out.append(allocator, prefix);
        try out.appendSlice(allocator, op.text);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

const DiffOpKind = enum { same, add, del };
const DiffOp = struct { kind: DiffOpKind, text: []const u8 };

fn splitLines(allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(allocator);
    if (input.len == 0) return list.toOwnedSlice(allocator);
    var start: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\n') {
            try list.append(allocator, input[start..i]);
            start = i + 1;
        }
    }
    if (start <= input.len - 0) {
        // Tail without trailing newline still counts as a line.
        if (start < input.len) {
            try list.append(allocator, input[start..]);
        }
    }
    return list.toOwnedSlice(allocator);
}

fn emitReplace(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    before_lines: []const []const u8,
    after_lines: []const []const u8,
) !void {
    for (before_lines) |line| {
        try out.append(allocator, '-');
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    for (after_lines) |line| {
        try out.append(allocator, '+');
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "diff identical inputs returns empty" {
    const a = std.testing.allocator;
    const out = try unifiedLineDiff(a, "alpha\nbeta\n", "alpha\nbeta\n");
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "diff add a single line at end" {
    const a = std.testing.allocator;
    const out = try unifiedLineDiff(a, "alpha\nbeta", "alpha\nbeta\ngamma");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "+gamma") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " beta") != null);
}

test "diff delete a single line" {
    const a = std.testing.allocator;
    const out = try unifiedLineDiff(a, "alpha\nbeta\ngamma", "alpha\ngamma");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "-beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " gamma") != null);
}

test "diff replace one line surfaces add+del" {
    const a = std.testing.allocator;
    const out = try unifiedLineDiff(a, "alpha\nbeta\ngamma", "alpha\nBETA\ngamma");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "-beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+BETA") != null);
}

test "diff empty before vs nonempty after" {
    const a = std.testing.allocator;
    const out = try unifiedLineDiff(a, "", "hello\nworld");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "+hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+world") != null);
}

test "diff fallback when input exceeds line cap" {
    const a = std.testing.allocator;
    // Build a string with MAX_DIFF_LINES+1 lines.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    var idx: usize = 0;
    while (idx <= MAX_DIFF_LINES) : (idx += 1) {
        try buf.appendSlice(a, "x\n");
    }
    const huge = buf.items;
    const out = try unifiedLineDiff(a, huge, "tiny");
    defer a.free(out);
    // Should still be non-empty (replace fallback), starts with '-x' for
    // the first before line.
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "+tiny") != null);
}
