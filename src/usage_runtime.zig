//! Usage runtime — per-turn cost and token accounting with session aggregation.
//!
//! Tracks per-turn token counts (input, output, total), cost in USD,
//! and duration. Accumulates session-level totals and produces structured
//! UsageReport with per-model breakdown.
//!
//! MAX_TURNS_TRACKED ring buffer prevents unbounded memory (T-02-15).

const std = @import("std");

// ── TurnUsage ────────────────────────────────────────────────────────

pub const TurnUsage = struct {
    model: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    total_tokens: u64,
    cost_usd: f64,
    duration_ms: u64,
    turn_index: u32,
    timestamp_secs: i64,
};

// ── UsageReport ──────────────────────────────────────────────────────

pub const UsageReport = struct {
    session_input_tokens: u64,
    session_output_tokens: u64,
    session_total_tokens: u64,
    session_cost_usd: f64,
    turn_count: u32,
    model_breakdown: []const ModelUsage,
    /// Allocator used for model_breakdown; caller must free.
    _allocator: std.mem.Allocator,

    pub const ModelUsage = struct {
        model: []const u8,
        input_tokens: u64,
        output_tokens: u64,
        total_tokens: u64,
        cost_usd: f64,
        turn_count: u32,
    };

    pub fn deinit(self: *const UsageReport) void {
        self._allocator.free(self.model_breakdown);
    }

    pub fn formatText(self: *const UsageReport, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.print("Session: {d} tokens ({d} in / {d} out), ${d:.6}\n", .{
            self.session_total_tokens,
            self.session_input_tokens,
            self.session_output_tokens,
            self.session_cost_usd,
        });
        try w.print("Turns: {d}\n", .{self.turn_count});

        for (self.model_breakdown) |m| {
            try w.print("  {s}: {d} tokens ({d} turns), ${d:.6}\n", .{
                m.model, m.total_tokens, m.turn_count, m.cost_usd,
            });
        }

        return buf.toOwnedSlice(allocator);
    }

    pub fn formatJson(self: *const UsageReport, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.print("{{\"session_total_tokens\":{d},\"session_input_tokens\":{d},\"session_output_tokens\":{d},\"session_cost_usd\":{d:.6},\"turn_count\":{d},\"models\":[", .{
            self.session_total_tokens,
            self.session_input_tokens,
            self.session_output_tokens,
            self.session_cost_usd,
            self.turn_count,
        });

        for (self.model_breakdown, 0..) |m, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"model\":\"{s}\",\"total_tokens\":{d},\"turn_count\":{d},\"cost_usd\":{d:.6}}}", .{
                m.model, m.total_tokens, m.turn_count, m.cost_usd,
            });
        }

        try w.writeAll("]}");
        return buf.toOwnedSlice(allocator);
    }
};

// ── UsageRuntime ─────────────────────────────────────────────────────

pub const MAX_TURNS_TRACKED: usize = 1024;

pub const UsageRuntime = struct {
    turns: std.ArrayListUnmanaged(TurnUsage),
    session_input_tokens: u64,
    session_output_tokens: u64,
    session_total_tokens: u64,
    session_cost_usd: f64,
    next_turn_index: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) UsageRuntime {
        return .{
            .turns = .{},
            .session_input_tokens = 0,
            .session_output_tokens = 0,
            .session_total_tokens = 0,
            .session_cost_usd = 0.0,
            .next_turn_index = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UsageRuntime) void {
        self.turns.deinit(self.allocator);
    }

    pub fn recordTurn(
        self: *UsageRuntime,
        model: []const u8,
        input_tokens: u64,
        output_tokens: u64,
        cost_usd: f64,
        duration_ms: u64,
    ) void {
        // Accumulate session totals (independent of ring buffer)
        self.session_input_tokens += input_tokens;
        self.session_output_tokens += output_tokens;
        self.session_total_tokens += input_tokens + output_tokens;
        self.session_cost_usd += cost_usd;

        // Ring buffer: drop oldest if at capacity
        if (self.turns.items.len >= MAX_TURNS_TRACKED) {
            _ = self.turns.orderedRemove(0);
        }

        self.turns.append(self.allocator, .{
            .model = model,
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .total_tokens = input_tokens + output_tokens,
            .cost_usd = cost_usd,
            .duration_ms = duration_ms,
            .turn_index = self.next_turn_index,
            .timestamp_secs = std.time.timestamp(),
        }) catch return; // Best-effort; don't fail the turn

        self.next_turn_index += 1;
    }

    pub fn sessionTotals(self: *const UsageRuntime) struct { input: u64, output: u64, total: u64, cost: f64 } {
        return .{
            .input = self.session_input_tokens,
            .output = self.session_output_tokens,
            .total = self.session_total_tokens,
            .cost = self.session_cost_usd,
        };
    }

    pub fn turnCount(self: *const UsageRuntime) u32 {
        return self.next_turn_index;
    }

    pub fn lastTurn(self: *const UsageRuntime) ?TurnUsage {
        if (self.turns.items.len == 0) return null;
        return self.turns.items[self.turns.items.len - 1];
    }

    pub fn report(self: *const UsageRuntime, allocator: std.mem.Allocator) !UsageReport {
        // Aggregate per-model stats from turns array
        var model_map = std.StringArrayHashMapUnmanaged(UsageReport.ModelUsage){};
        defer model_map.deinit(allocator);

        for (self.turns.items) |turn| {
            const gop = try model_map.getOrPut(allocator, turn.model);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .model = turn.model,
                    .input_tokens = 0,
                    .output_tokens = 0,
                    .total_tokens = 0,
                    .cost_usd = 0.0,
                    .turn_count = 0,
                };
            }
            gop.value_ptr.input_tokens += turn.input_tokens;
            gop.value_ptr.output_tokens += turn.output_tokens;
            gop.value_ptr.total_tokens += turn.total_tokens;
            gop.value_ptr.cost_usd += turn.cost_usd;
            gop.value_ptr.turn_count += 1;
        }

        // Copy values into a stable slice
        const breakdown = try allocator.dupe(UsageReport.ModelUsage, model_map.values());

        return .{
            .session_input_tokens = self.session_input_tokens,
            .session_output_tokens = self.session_output_tokens,
            .session_total_tokens = self.session_total_tokens,
            .session_cost_usd = self.session_cost_usd,
            .turn_count = self.next_turn_index,
            .model_breakdown = breakdown,
            ._allocator = allocator,
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "TurnUsage records all fields" {
    const turn = TurnUsage{
        .model = "claude-3",
        .input_tokens = 100,
        .output_tokens = 50,
        .total_tokens = 150,
        .cost_usd = 0.001,
        .duration_ms = 250,
        .turn_index = 0,
        .timestamp_secs = 0,
    };
    try std.testing.expectEqual(@as(u64, 100), turn.input_tokens);
    try std.testing.expectEqual(@as(u64, 50), turn.output_tokens);
    try std.testing.expectEqual(@as(u64, 150), turn.total_tokens);
}

test "UsageRuntime.recordTurn adds entry" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    rt.recordTurn("model-a", 100, 50, 0.001, 200);
    try std.testing.expectEqual(@as(u32, 1), rt.turnCount());
}

test "UsageRuntime.sessionTotals aggregates across turns" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    rt.recordTurn("m", 100, 50, 0.001, 100);
    rt.recordTurn("m", 200, 80, 0.002, 150);

    const totals = rt.sessionTotals();
    try std.testing.expectEqual(@as(u64, 300), totals.input);
    try std.testing.expectEqual(@as(u64, 130), totals.output);
    try std.testing.expectEqual(@as(u64, 430), totals.total);
}

test "UsageRuntime.turnCount returns number of recorded turns" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    try std.testing.expectEqual(@as(u32, 0), rt.turnCount());
    rt.recordTurn("m", 10, 5, 0.0, 10);
    try std.testing.expectEqual(@as(u32, 1), rt.turnCount());
    rt.recordTurn("m", 10, 5, 0.0, 10);
    try std.testing.expectEqual(@as(u32, 2), rt.turnCount());
}

test "UsageRuntime.lastTurn returns most recent" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    try std.testing.expect(rt.lastTurn() == null);
    rt.recordTurn("first", 10, 5, 0.0, 10);
    rt.recordTurn("second", 20, 10, 0.0, 20);
    const last = rt.lastTurn().?;
    try std.testing.expectEqualStrings("second", last.model);
    try std.testing.expectEqual(@as(u64, 20), last.input_tokens);
}

test "UsageRuntime.report produces breakdown by model" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    rt.recordTurn("claude-3", 100, 50, 0.001, 100);
    rt.recordTurn("gpt-4", 200, 80, 0.002, 150);
    rt.recordTurn("claude-3", 50, 25, 0.0005, 80);

    const rpt = try rt.report(allocator);
    defer rpt.deinit();

    try std.testing.expectEqual(@as(u32, 3), rpt.turn_count);
    try std.testing.expectEqual(@as(u64, 350), rpt.session_input_tokens);
    try std.testing.expectEqual(@as(usize, 2), rpt.model_breakdown.len);
}

test "UsageRuntime ring buffer drops oldest" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    // Fill to capacity + 1
    var i: usize = 0;
    while (i <= MAX_TURNS_TRACKED) : (i += 1) {
        rt.recordTurn("m", 1, 1, 0.0, 1);
    }
    // Buffer should be at capacity, not over
    try std.testing.expectEqual(@as(usize, MAX_TURNS_TRACKED), rt.turns.items.len);
    // Session totals should still reflect ALL turns (not just buffered ones)
    try std.testing.expectEqual(@as(u64, MAX_TURNS_TRACKED + 1), rt.session_input_tokens);
}

test "UsageReport.formatText contains expected substrings" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    rt.recordTurn("claude-3", 100, 50, 0.001, 100);

    const rpt = try rt.report(allocator);
    defer rpt.deinit();

    const text = try rpt.formatText(allocator);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Session:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Turns: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "claude-3") != null);
}

test "UsageReport.formatJson contains expected fields" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    rt.recordTurn("claude-3", 100, 50, 0.001, 100);

    const rpt = try rt.report(allocator);
    defer rpt.deinit();

    const json = try rpt.formatJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"session_total_tokens\":150") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"turn_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"claude-3\"") != null);
}
