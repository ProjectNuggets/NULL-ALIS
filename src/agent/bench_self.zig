//! Bench self-knowledge — read recent bench results and format for volatile prompt injection.
//! Part of G7 (BENCH-SELF-KNOWLEDGE) — agent reads .spike/results.tsv to understand
//! its own weaknesses and adjusts strategy accordingly.

const std = @import("std");
const log = std.log.scoped(.agent);

/// Read recent bench results from `results_path` (production: .spike/results.tsv); last 3 rows + LoCoMo category analysis.
/// Returns formatted <known_weakness> block for injection into volatile prompt.
/// Fail-soft: returns empty string if file absent or parse fails.
///
/// Supported formats of .spike/results.tsv (TSV):
///   timestamp   run_name  metric          category        value
///   1234567890  run_001   airline_bench   overall         0.450
///   1234567890  run_001   locomo_bench    cat_1           0.800
///   1234567890  run_001   locomo_bench    cat_3           0.333
///
/// Legacy iteration-loop format:
///   commit      pass_rate mean_tools mean_latency_ms [p50_ttft_ms p95_ttft_ms] status description
///   iter19      0.920     1.40       9612            keep   ...
pub fn readKnownWeakness(allocator: std.mem.Allocator, results_path: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // Open the bench results file (production call site passes ".spike/results.tsv").
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
        if (!@import("builtin").is_test) log.warn("bench_self.readKnownWeakness: {s} too large ({d} > {d})", .{ results_path, file_size, max_size });
        return try allocator.dupe(u8, "");
    }

    const content = try file.readToEndAlloc(allocator, file_size);
    defer allocator.free(content);

    // Parse non-empty rows; the first row may be a schema header.
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

    const schema = detectSchema(all_lines.items[0]);
    const data_lines = if (schema.has_header and all_lines.items.len > 1) all_lines.items[1..] else all_lines.items;
    if (data_lines.len == 0) {
        return try allocator.dupe(u8, "");
    }

    // Extract last 3 data rows and find weakest metric.
    const start_idx = if (data_lines.len > 3) data_lines.len - 3 else 0;
    var recent_rows: std.ArrayListUnmanaged([]const u8) = .{};
    defer recent_rows.deinit(allocator);

    var weakest_category: ?[]const u8 = null;
    var weakest_value: f64 = 1.0;
    var overall_locomo: ?f64 = null;
    var latest_run: ?[]const u8 = null;
    var latest_pass_rate: ?f64 = null;
    var weakest_run: ?[]const u8 = null;
    var weakest_run_status: ?[]const u8 = null;
    var weakest_run_description: ?[]const u8 = null;
    var weakest_run_pass_rate: f64 = 1.0;

    for (data_lines[start_idx..]) |row| {
        try recent_rows.append(allocator, row);

        const fields = try splitTsvFields(allocator, row);
        defer allocator.free(fields);

        switch (schema.kind) {
            .metric_category_value => {
                if (fields.len < 5) continue;
                const metric = fields[2];
                const category = fields[3];
                const value_str = fields[4];
                if (std.mem.indexOf(u8, metric, "locomo") != null) {
                    if (parseScore(value_str)) |val| {
                        if (std.mem.startsWith(u8, category, "cat_")) {
                            if (val < weakest_value) {
                                weakest_value = val;
                                weakest_category = category;
                            }
                        } else if (std.mem.eql(u8, category, "overall")) {
                            overall_locomo = val;
                        }
                    }
                }
            },
            .pass_rate_iteration => {
                if (fields.len < 2) continue;
                const pass_rate = parseScore(fields[1]) orelse continue;
                latest_run = fields[0];
                latest_pass_rate = pass_rate;
                if (pass_rate < weakest_run_pass_rate) {
                    weakest_run_pass_rate = pass_rate;
                    weakest_run = fields[0];
                    weakest_run_status = legacyStatusField(fields);
                    weakest_run_description = legacyDescriptionField(fields);
                }
            },
            .unknown => {},
        }
    }

    if (schema.kind == .unknown) {
        for (data_lines[start_idx..]) |row| {
            const fields = try splitTsvFields(allocator, row);
            defer allocator.free(fields);
            if (fields.len >= 2) {
                if (parseScore(fields[1])) |pass_rate| {
                    latest_run = fields[0];
                    latest_pass_rate = pass_rate;
                    if (pass_rate < weakest_run_pass_rate) {
                        weakest_run_pass_rate = pass_rate;
                        weakest_run = fields[0];
                        weakest_run_status = legacyStatusField(fields);
                        weakest_run_description = legacyDescriptionField(fields);
                    }
                    continue;
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

    if (latest_pass_rate) |pass_rate| {
        try buf.writer(allocator).print(
            "Latest benchmark pass_rate: {d:.3}",
            .{pass_rate},
        );
        if (latest_run) |run| {
            try buf.writer(allocator).print(" ({s})", .{run});
        }
        try buf.writer(allocator).writeAll("\n");
    }

    if (weakest_run) |run| {
        try buf.writer(allocator).print(
            "Weakest recent benchmark run: {s} at {d:.3} pass_rate",
            .{ run, weakest_run_pass_rate },
        );
        if (weakest_run_status) |status| {
            try buf.writer(allocator).print(" status={s}", .{status});
        }
        if (weakest_run_description) |description| {
            try buf.writer(allocator).print(" description={s}", .{description});
        }
        try buf.writer(allocator).writeAll("\n");
        if (weakest_run_pass_rate < 0.9) {
            try buf.writer(allocator).writeAll(
                "Strategy: recent bench data shows measurable failures; prefer explicit tool verification, concrete answers, and avoid unsupported claims.\n",
            );
        }
    }

    try buf.writer(allocator).print(
        "</known_weakness>\n",
        .{},
    );

    return try buf.toOwnedSlice(allocator);
}

const ResultSchemaKind = enum {
    metric_category_value,
    pass_rate_iteration,
    unknown,
};

const ResultSchema = struct {
    kind: ResultSchemaKind,
    has_header: bool,
};

fn detectSchema(line: []const u8) ResultSchema {
    const fields = splitTsvFields(std.heap.page_allocator, line) catch return .{ .kind = .unknown, .has_header = false };
    defer std.heap.page_allocator.free(fields);

    if (fields.len >= 5 and
        std.mem.eql(u8, fields[2], "metric") and
        std.mem.eql(u8, fields[3], "category") and
        std.mem.eql(u8, fields[4], "value"))
    {
        return .{ .kind = .metric_category_value, .has_header = true };
    }

    if (fields.len >= 2 and std.mem.eql(u8, fields[1], "pass_rate")) {
        return .{ .kind = .pass_rate_iteration, .has_header = true };
    }

    if (fields.len >= 5 and std.mem.indexOf(u8, fields[2], "bench") != null and parseScore(fields[4]) != null) {
        return .{ .kind = .metric_category_value, .has_header = false };
    }

    if (fields.len >= 2 and parseScore(fields[1]) != null) {
        return .{ .kind = .pass_rate_iteration, .has_header = false };
    }

    return .{ .kind = .unknown, .has_header = false };
}

fn splitTsvFields(allocator: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var fields: std.ArrayListUnmanaged([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, line, '\t');
    while (parts.next()) |field| {
        try fields.append(allocator, std.mem.trim(u8, field, " \r"));
    }
    return try fields.toOwnedSlice(allocator);
}

fn parseScore(raw: []const u8) ?f64 {
    if (std.mem.eql(u8, raw, "na") or std.mem.eql(u8, raw, "NA") or raw.len == 0) {
        return null;
    }
    return std.fmt.parseFloat(f64, raw) catch null;
}

fn legacyStatusField(fields: []const []const u8) ?[]const u8 {
    if (fields.len >= 7) return fields[6];
    if (fields.len >= 5) return fields[4];
    return null;
}

fn legacyDescriptionField(fields: []const []const u8) ?[]const u8 {
    if (fields.len >= 8) return fields[7];
    if (fields.len >= 6) return fields[5];
    return null;
}

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

test "readKnownWeakness with no results.tsv returns empty" {
    const allocator = std.testing.allocator;

    // Hermetic: point at an absent file inside a fresh temp dir, so the
    // result is independent of the repo's real .spike/results.tsv.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const absent_path = try std.fs.path.join(allocator, &.{ dir_path, "results.tsv" });
    defer allocator.free(absent_path);

    const result = try readKnownWeakness(allocator, absent_path);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "readKnownWeakness formats known_weakness block" {
    const allocator = std.testing.allocator;

    // Hermetic temp fixture — never touches the repo's real .spike/results.tsv.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_content = "timestamp\trun_name\tmetric\tcategory\tvalue\n" ++
        "1234567890\trun_001\tlocomo_bench\tcat_1\t0.800\n" ++
        "1234567890\trun_001\tlocomo_bench\tcat_3\t0.333\n" ++
        "1234567890\trun_001\tlocomo_bench\toverall\t0.600\n";
    try tmp_dir.dir.writeFile(.{ .sub_path = "results.tsv", .data = test_content });

    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const results_path = try std.fs.path.join(allocator, &.{ dir_path, "results.tsv" });
    defer allocator.free(results_path);

    const result = try readKnownWeakness(allocator, results_path);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<known_weakness") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</known_weakness>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "cat_3") != null);
}

test "readKnownWeakness supports legacy pass_rate results schema" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_content = "commit\tpass_rate\tmean_tools\tmean_latency_ms\tp50_ttft_ms\tp95_ttft_ms\tstatus\tdescription\n" ++
        "iter17-polluted\t0.840\t2.56\t17335\t0\t0\tbaseline\tpolluted weakness\n" ++
        "iter18-phaseA\t0.920\t1.44\t8544\t0\t0\tkeep\tcontext v2\n" ++
        "iter19-phaseB\t0.920\t1.40\t9612\t0\t0\tkeep\tanti-thrash\n";
    try tmp_dir.dir.writeFile(.{ .sub_path = "results.tsv", .data = test_content });

    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const results_path = try std.fs.path.join(allocator, &.{ dir_path, "results.tsv" });
    defer allocator.free(results_path);

    const result = try readKnownWeakness(allocator, results_path);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Latest benchmark pass_rate: 0.920") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "iter19-phaseB") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Weakest recent benchmark run: iter17-polluted at 0.840") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "polluted weakness") != null);
}
