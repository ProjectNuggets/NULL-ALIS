//! Bench self-knowledge — read recent bench results and format for volatile prompt injection.
//! Part of G7 (BENCH-SELF-KNOWLEDGE) — agent reads .spike/results.tsv to understand
//! its own weaknesses and adjusts strategy accordingly.

const std = @import("std");
const log = std.log.scoped(.agent);

/// Read recent bench results from .spike/results.tsv (last 3 rows + LoCoMo category analysis).
/// Returns formatted <known_weakness> block for injection into volatile prompt.
/// Fail-soft: returns empty string if file absent or parse fails.
///
/// Expected format of .spike/results.tsv (TSV):
///   timestamp   run_name  metric          category        value
///   1234567890  run_001   airline_bench   overall         0.450
///   1234567890  run_001   locomo_bench    cat_1           0.800
///   1234567890  run_001   locomo_bench    cat_3           0.333
pub fn readKnownWeakness(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // Try to open .spike/results.tsv
    const results_path = ".spike/results.tsv";
    const file = std.fs.cwd().openFile(results_path, .{}) catch {
        // Fail-soft: file not found or inaccessible
        log.debug("bench_self.readKnownWeakness: {s} not found or inaccessible", .{results_path});
        return try allocator.dupe(u8, "");
    };
    defer file.close();

    // Read file content
    const file_size = try file.getEndPos();
    const max_size = 1024 * 1024; // 1 MB max
    if (file_size > max_size) {
        log.warn("bench_self.readKnownWeakness: {s} too large ({d} > {d})", .{ results_path, file_size, max_size });
        return try allocator.dupe(u8, "");
    }

    const content = try file.readToEndAlloc(allocator, file_size);
    defer allocator.free(content);

    // Parse last 3 data rows
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    var all_lines: std.ArrayListUnmanaged([]const u8) = .{};
    defer all_lines.deinit(allocator);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "#")) {
            try all_lines.append(allocator, trimmed);
        }
    }

    if (all_lines.items.len < 1) {
        return try allocator.dupe(u8, "");
    }

    // Extract last 3 rows and find weakest metric
    const start_idx = if (all_lines.items.len > 3) all_lines.items.len - 3 else 0;
    var recent_rows: std.ArrayListUnmanaged([]const u8) = .{};
    defer recent_rows.deinit(allocator);

    var weakest_category: ?[]const u8 = null;
    var weakest_value: f64 = 1.0;
    var overall_locomo: ?f64 = null;

    for (all_lines.items[start_idx..]) |row| {
        try recent_rows.append(allocator, row);

        var fields = std.mem.tokenizeScalar(u8, row, '\t');
        var field_idx: u32 = 0;
        var metric: ?[]const u8 = null;
        var category: ?[]const u8 = null;
        var value_str: ?[]const u8 = null;

        while (fields.next()) |field| {
            switch (field_idx) {
                2 => metric = field,
                3 => category = field,
                4 => value_str = field,
                else => {},
            }
            field_idx += 1;
        }

        if (metric) |m| {
            if (std.mem.indexOf(u8, m, "locomo") != null) {
                if (category) |c| {
                    if (value_str) |vs| {
                        const val = std.fmt.parseFloat(f64, vs) catch 0.0;
                        if (std.mem.startsWith(u8, c, "cat_")) {
                            if (val < weakest_value) {
                                weakest_value = val;
                                weakest_category = c;
                            }
                        } else if (std.mem.eql(u8, c, "overall")) {
                            overall_locomo = val;
                        }
                    }
                }
            }
        }
    }

    // Format <known_weakness> block
    try buf.writer(allocator).print(
        "<known_weakness source=\"bench\" updated=\"2026-05-20\">\n",
        .{},
    );

    if (recent_rows.items.len > 0) {
        try buf.writer(allocator).print(
            "Recent benchmark results from {d} runs:\n",
            .{recent_rows.items.len},
        );
        for (recent_rows.items) |row| {
            try buf.writer(allocator).print("  {s}\n", .{row});
        }
    }

    if (overall_locomo) |val| {
        try buf.writer(allocator).print(
            "LoCoMo overall: {d:.3} pass_rate\n",
            .{val},
        );
    }

    if (weakest_category) |cat| {
        try buf.writer(allocator).print(
            "Weakest LoCoMo category: {s} at {d:.3} pass_rate\n",
            .{ cat, weakest_value },
        );
        try buf.writer(allocator).print(
            "Strategy: when facing {s}-type questions, commit confidently per F-A1; this is your measured weak axis.\n",
            .{cat},
        );
    }

    try buf.writer(allocator).print(
        "</known_weakness>\n",
        .{},
    );

    return try buf.toOwnedSlice(allocator);
}

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

test "readKnownWeakness with no results.tsv returns empty" {
    const allocator = std.testing.allocator;

    // This will fail-soft since .spike/results.tsv won't exist in test dir
    const result = try readKnownWeakness(allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "readKnownWeakness formats known_weakness block" {
    const allocator = std.testing.allocator;

    // Create a temporary test file
    var tmp_dir = try std.fs.cwd().makeOpenPath(".spike", .{});
    defer tmp_dir.close();

    const test_content = "timestamp\trun_name\tmetric\tcategory\tvalue\n" ++
        "1234567890\trun_001\tlocomo_bench\tcat_1\t0.800\n" ++
        "1234567890\trun_001\tlocomo_bench\tcat_3\t0.333\n" ++
        "1234567890\trun_001\tlocomo_bench\toverall\t0.600\n";

    var file = try tmp_dir.createFile("results.tsv", .{});
    try file.writeAll(test_content);
    file.close();

    defer tmp_dir.deleteFile("results.tsv") catch {};

    const result = try readKnownWeakness(allocator);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<known_weakness") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</known_weakness>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "cat_3") != null);
}
