//! Insights consultation block — read the latest mined insights file and
//! format its top bullet lines for volatile prompt injection. Part of
//! Package 2a Task 4 (behaviour §4 "in-turn consultation"): mirrors
//! `bench_self.zig::readKnownWeakness` exactly — same fail-soft shape
//! (missing file/dir -> empty string, never an error), same "read a small
//! text artifact, format a fenced block" role, sitting alongside it in the
//! volatile recall stack.
//!
//! The miner (Task 3, tools/memory_maintain.zig's mine_traces action)
//! writes `{workspace_dir}/insights/{ISO-week}.md` — see
//! trace_mining.renderInsightsMarkdown for the exact format (three
//! sections: "Failure patterns", "Recurring procedures", "Tool fluency",
//! each with `- ` bullet lines citing evidence run_ids). Dates/weeks sort
//! lexicographically the same as chronologically (YYYY-Www), so
//! "lexicographic max filename" == "latest week" — the same trick
//! memory_loader.zig's latestDreamLogKey uses for dream_log/ keys.

const std = @import("std");
const log = std.log.scoped(.agent);

/// Reads `{insights_dir}/*.md`, picks the lexicographically-latest
/// filename (== latest ISO week), and formats its top 3 `- ` bullet
/// lines as a `<recent_insights>...</recent_insights>` block for volatile
/// prompt injection. Fail-soft: a missing/empty/unreadable directory, or
/// a latest file with zero bullet lines, returns an empty string — NEVER
/// an error — so a caller that unconditionally frees the result and
/// treats `len == 0` as "omit the block" never needs a special case.
pub fn readInsightsBlock(allocator: std.mem.Allocator, insights_dir: []const u8) ![]u8 {
    var dir = std.fs.cwd().openDir(insights_dir, .{ .iterate = true }) catch {
        log.debug("insights_block.readInsightsBlock: {s} not found or inaccessible", .{insights_dir});
        return try allocator.dupe(u8, "");
    };
    defer dir.close();

    var latest_name: ?[]u8 = null;
    defer if (latest_name) |n| allocator.free(n);

    var it = dir.iterate();
    while (try it.next()) |dirent| {
        if (dirent.kind != .file) continue;
        if (!std.mem.endsWith(u8, dirent.name, ".md")) continue;
        if (latest_name == null or std.mem.order(u8, dirent.name, latest_name.?) == .gt) {
            if (latest_name) |n| allocator.free(n);
            latest_name = try allocator.dupe(u8, dirent.name);
        }
    }

    const name = latest_name orelse return try allocator.dupe(u8, "");

    const max_size = 1024 * 1024; // 1 MB max — same ceiling as bench_self.readKnownWeakness
    const content = dir.readFileAlloc(allocator, name, max_size) catch |err| {
        log.debug("insights_block.readInsightsBlock: failed to read {s}/{s}: {s}", .{ insights_dir, name, @errorName(err) });
        return try allocator.dupe(u8, "");
    };
    defer allocator.free(content);

    var bullets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer bullets.deinit(allocator);
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "- ")) continue;
        try bullets.append(allocator, trimmed);
        if (bullets.items.len == 3) break;
    }

    if (bullets.items.len == 0) return try allocator.dupe(u8, "");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("<recent_insights source=\"mine_traces\">\n");
    for (bullets.items) |b| {
        try w.print("{s}\n", .{b});
    }
    try w.writeAll("</recent_insights>\n");

    return buf.toOwnedSlice(allocator);
}

// ─────────────────────────────────────────────────────────────────
// Tests (written first — RED before GREEN)
// ─────────────────────────────────────────────────────────────────

test "readInsightsBlock with no insights dir returns empty" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const absent_path = try std.fs.path.join(allocator, &.{ dir_path, "insights" });
    defer allocator.free(absent_path);

    const result = try readInsightsBlock(allocator, absent_path);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "readInsightsBlock with an empty insights dir returns empty" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("insights");

    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const insights_path = try std.fs.path.join(allocator, &.{ dir_path, "insights" });
    defer allocator.free(insights_path);

    const result = try readInsightsBlock(allocator, insights_path);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "readInsightsBlock formats the top 3 bullet lines from the latest week's file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("insights");
    var insights_dir = try tmp_dir.dir.openDir("insights", .{});
    defer insights_dir.close();

    const md =
        "# Insights — 2026-W28\n\n" ++
        "## Failure patterns\n\n" ++
        "- `web_search` failed with \"timeout\" 4x — evidence: r-1-1, r-2-1\n" ++
        "- `bash` failed with \"exit_1\" 3x — evidence: r-3-1, r-4-1\n\n" ++
        "## Recurring procedures\n\n" ++
        "- `memory_recall` -> `web_search` — seen 3x — evidence: r-5-1\n\n" ++
        "## Tool fluency\n\n" ++
        "- `bash`: 10 uses, 90% success, p50 150ms\n\n";
    try insights_dir.writeFile(.{ .sub_path = "2026-W28.md", .data = md });

    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const insights_path = try std.fs.path.join(allocator, &.{ dir_path, "insights" });
    defer allocator.free(insights_path);

    const result = try readInsightsBlock(allocator, insights_path);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<recent_insights") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</recent_insights>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "web_search") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "memory_recall") != null);
    // Only 3 bullets — the 4th (tool fluency) line is excluded.
    try std.testing.expect(std.mem.indexOf(u8, result, "90% success") == null);

    var bullet_count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "- ")) bullet_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), bullet_count);
}

test "readInsightsBlock picks the LEXICOGRAPHICALLY LATEST week file, not the first one found" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("insights");
    var insights_dir = try tmp_dir.dir.openDir("insights", .{});
    defer insights_dir.close();

    try insights_dir.writeFile(.{ .sub_path = "2026-W20.md", .data = "## Failure patterns\n\n- OLD week's stale suggestion\n\n" });
    try insights_dir.writeFile(.{ .sub_path = "2026-W28.md", .data = "## Failure patterns\n\n- NEWEST week's fresh suggestion\n\n" });
    try insights_dir.writeFile(.{ .sub_path = "2026-W25.md", .data = "## Failure patterns\n\n- middle week's suggestion\n\n" });

    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const insights_path = try std.fs.path.join(allocator, &.{ dir_path, "insights" });
    defer allocator.free(insights_path);

    const result = try readInsightsBlock(allocator, insights_path);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "NEWEST week's fresh suggestion") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "OLD week's stale suggestion") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "middle week's suggestion") == null);
}

test "readInsightsBlock ignores non-.md files in the insights dir" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("insights");
    var insights_dir = try tmp_dir.dir.openDir("insights", .{});
    defer insights_dir.close();

    try insights_dir.writeFile(.{ .sub_path = "2026-W28.md", .data = "## Failure patterns\n\n- the real markdown suggestion\n\n" });
    try insights_dir.writeFile(.{ .sub_path = "2026-W99.json", .data = "{\"failure_patterns\":[]}" });

    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const insights_path = try std.fs.path.join(allocator, &.{ dir_path, "insights" });
    defer allocator.free(insights_path);

    const result = try readInsightsBlock(allocator, insights_path);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "the real markdown suggestion") != null);
}

test "readInsightsBlock: a file with zero bullet lines (e.g. 'None observed') returns empty" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("insights");
    var insights_dir = try tmp_dir.dir.openDir("insights", .{});
    defer insights_dir.close();

    const md =
        "# Insights — 2026-W28\n\n" ++
        "## Failure patterns\n\nNone observed this window.\n\n" ++
        "## Recurring procedures\n\nNone observed this window.\n\n" ++
        "## Tool fluency\n\nNone observed this window.\n\n";
    try insights_dir.writeFile(.{ .sub_path = "2026-W28.md", .data = md });

    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const insights_path = try std.fs.path.join(allocator, &.{ dir_path, "insights" });
    defer allocator.free(insights_path);

    const result = try readInsightsBlock(allocator, insights_path);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}
