//! Usage runtime — per-turn cost and token accounting with session aggregation.
//!
//! Tracks per-turn token counts (input, output, total), cost in USD,
//! and duration. Accumulates session-level totals and produces structured
//! UsageReport with per-model breakdown.
//!
//! MAX_TURNS_TRACKED ring buffer prevents unbounded memory (T-02-15).
//!
//! Concurrency (WP2.3): UsageRuntime is shared across the agent recording
//! turns and HTTP readers producing summaries. All public methods lock an
//! internal mutex and return either owned/copied snapshots or primitive
//! values so callers never hold pointers into runtime-owned state.

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
    model_breakdown: []ModelUsage,
    /// Allocator that owns model_breakdown AND each ModelUsage.model slice.
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
        for (self.model_breakdown) |m| {
            self._allocator.free(@constCast(m.model));
        }
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
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) UsageRuntime {
        return .{
            .turns = .{},
            .session_input_tokens = 0,
            .session_output_tokens = 0,
            .session_total_tokens = 0,
            .session_cost_usd = 0.0,
            .next_turn_index = 0,
            .allocator = allocator,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *UsageRuntime) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.turns.items) |turn| {
            self.allocator.free(@constCast(turn.model));
        }
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
        self.mutex.lock();
        defer self.mutex.unlock();

        // Accumulate session totals (independent of ring buffer)
        self.session_input_tokens += input_tokens;
        self.session_output_tokens += output_tokens;
        self.session_total_tokens += input_tokens + output_tokens;
        self.session_cost_usd += cost_usd;

        // Ring buffer: drop oldest if at capacity, freeing its owned model.
        if (self.turns.items.len >= MAX_TURNS_TRACKED) {
            const evicted = self.turns.orderedRemove(0);
            self.allocator.free(@constCast(evicted.model));
        }

        // Duplicate the model string so callers may free/reuse their buffer.
        const owned_model = self.allocator.dupe(u8, model) catch return; // best-effort

        self.turns.append(self.allocator, .{
            .model = owned_model,
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .total_tokens = input_tokens + output_tokens,
            .cost_usd = cost_usd,
            .duration_ms = duration_ms,
            .turn_index = self.next_turn_index,
            .timestamp_secs = std.time.timestamp(),
        }) catch {
            // append failed — free the orphaned model to avoid leak.
            self.allocator.free(owned_model);
            return;
        };

        self.next_turn_index += 1;
    }

    pub fn sessionTotals(self: *UsageRuntime) struct { input: u64, output: u64, total: u64, cost: f64 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .input = self.session_input_tokens,
            .output = self.session_output_tokens,
            .total = self.session_total_tokens,
            .cost = self.session_cost_usd,
        };
    }

    pub fn turnCount(self: *UsageRuntime) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.next_turn_index;
    }

    /// Returns a snapshot of the most recent turn. The `model` field is a
    /// COPY owned by `allocator`; caller must free it (or pass to deinit via
    /// `allocator.free(result.model)`).
    pub fn lastTurnCopy(self: *UsageRuntime, allocator: std.mem.Allocator) !?TurnUsage {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.turns.items.len == 0) return null;
        const src = self.turns.items[self.turns.items.len - 1];
        var copy = src;
        copy.model = try allocator.dupe(u8, src.model);
        return copy;
    }

    /// Returns true if any turn is recorded — cheap probe that does not
    /// require copying the turn's model string.
    pub fn hasTurns(self: *UsageRuntime) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.turns.items.len > 0;
    }

    pub fn report(self: *UsageRuntime, allocator: std.mem.Allocator) !UsageReport {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Aggregate per-model stats from turns array. The map keys point
        // into runtime-owned turn buffers while we hold the mutex; the
        // report produced below owns independent copies.
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

        const values = model_map.values();
        const breakdown = try allocator.alloc(UsageReport.ModelUsage, values.len);
        errdefer allocator.free(breakdown);

        // Copy each ModelUsage with an OWNED model string so the returned
        // report remains valid after subsequent recordTurn / ring-buffer
        // eviction in UsageRuntime.
        var copied: usize = 0;
        errdefer for (breakdown[0..copied]) |m| allocator.free(@constCast(m.model));

        for (values, 0..) |src, i| {
            const owned_name = try allocator.dupe(u8, src.model);
            breakdown[i] = .{
                .model = owned_name,
                .input_tokens = src.input_tokens,
                .output_tokens = src.output_tokens,
                .total_tokens = src.total_tokens,
                .cost_usd = src.cost_usd,
                .turn_count = src.turn_count,
            };
            copied = i + 1;
        }

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

test "UsageRuntime.lastTurnCopy returns owned most-recent snapshot" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    try std.testing.expect((try rt.lastTurnCopy(allocator)) == null);
    rt.recordTurn("first", 10, 5, 0.0, 10);
    rt.recordTurn("second", 20, 10, 0.0, 20);
    const last = (try rt.lastTurnCopy(allocator)).?;
    defer allocator.free(@constCast(last.model));
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

// ── WP2.3 ownership and concurrency tests ────────────────────────────

test "UsageRuntime owns model strings after caller buffer mutation" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    // Pass a caller-owned buffer then mutate it. The runtime must retain
    // its own copy of the model name, independent of the caller slice.
    var caller_buf: [32]u8 = undefined;
    const m1 = "claude-3";
    @memcpy(caller_buf[0..m1.len], m1);
    rt.recordTurn(caller_buf[0..m1.len], 10, 5, 0.0, 10);

    // Scribble over the caller buffer.
    @memset(caller_buf[0..], 'X');

    const rpt = try rt.report(allocator);
    defer rpt.deinit();
    try std.testing.expectEqual(@as(usize, 1), rpt.model_breakdown.len);
    try std.testing.expectEqualStrings("claude-3", rpt.model_breakdown[0].model);
}

test "UsageRuntime report survives subsequent ring-buffer churn" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    rt.recordTurn("keeper-model", 10, 5, 0.0, 10);

    const rpt = try rt.report(allocator);
    defer rpt.deinit();

    // Evict the original turn many times so any aliased pointer into
    // runtime state would become dangling.
    var i: usize = 0;
    while (i < MAX_TURNS_TRACKED + 4) : (i += 1) {
        rt.recordTurn("noise", 1, 1, 0.0, 1);
    }

    // Report slice must still be valid and independently owned.
    try std.testing.expectEqual(@as(usize, 1), rpt.model_breakdown.len);
    try std.testing.expectEqualStrings("keeper-model", rpt.model_breakdown[0].model);
}

test "UsageRuntime ring buffer eviction frees owned model strings" {
    // std.testing.allocator (DebugAllocator) will fail the test on leak.
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    // Fill past capacity several times over with unique-ish names.
    var i: usize = 0;
    while (i < MAX_TURNS_TRACKED * 2) : (i += 1) {
        var buf: [24]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "model-{d}", .{i}) catch unreachable;
        rt.recordTurn(name, 1, 1, 0.0, 1);
    }
    try std.testing.expectEqual(@as(usize, MAX_TURNS_TRACKED), rt.turns.items.len);
}
