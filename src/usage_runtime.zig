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

// ── Per-turn delta accumulator (WO-03 concurrency-safe) ──────────────

/// The cost/token/weight a single HTTP turn contributed to the shared
/// per-user UsageRuntime. An HTTP turn drives the agent loop, which calls
/// `recordTurn` (and `recordWeight`) one-or-more times — once per provider
/// response in a multi-step tool turn. The done frame must report exactly
/// THIS turn's accumulation, never a concurrent turn's.
///
/// `cost_priced` is true iff at least one `recordTurn` in the window
/// carried a non-zero (priced) cost. It is the per-turn analogue of
/// handleUserUsage's `cost_available` gate: an unpriced-model turn (pricing
/// table returned 0) reports `cost_priced=false` so the done frame emits NO
/// real `cost_usd: 0` for a billable turn (which the BFF would settle at $0).
pub const TurnDelta = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,
    cost_usd: f64 = 0.0,
    weight: u64 = 0,
    cost_priced: bool = false,
};

/// Thread-local per-turn delta accumulator. The gateway worker pool handles
/// one HTTP turn end-to-end on a single worker thread (gateway.zig accept →
/// queue → gatewayWorkerMain runs handleChatStream synchronously, including
/// the full agent loop). So a turn is bounded to one thread for its whole
/// lifetime: `recordTurn`/`recordWeight` calls during the agent loop run on
/// the same thread that called `beginTurnDelta`, and concurrent turns for
/// the SAME user land on DIFFERENT worker threads with independent
/// accumulators — no interleaving, unlike a before/after diff of the shared
/// cumulative under two separate locks.
///
/// `tracking` gates accumulation so paths that never call `beginTurnDelta`
/// (CLI /cost, tests) pay nothing and leave the slot clean for the next turn
/// that DOES track. Reset on every `beginTurnDelta`.
const TurnDeltaTls = struct {
    tracking: bool = false,
    delta: TurnDelta = .{},
};
threadlocal var turn_delta_tls: TurnDeltaTls = .{};

// ── UsageRuntime ─────────────────────────────────────────────────────

pub const MAX_TURNS_TRACKED: usize = 1024;

pub const UsageRuntime = struct {
    turns: std.ArrayListUnmanaged(TurnUsage),
    session_input_tokens: u64,
    session_output_tokens: u64,
    session_total_tokens: u64,
    session_cost_usd: f64,
    /// Accumulated tool-weight for the lifetime of this session. Each
    /// tool dispatch contributes `tool_metadata.CostClass.weight()` — 1
    /// for class-A (cheap), 5 for class-B (moderate), 25 for class-C
    /// (expensive). Used by the S2.8 weight-budget gate in
    /// `preflightToolPolicy` to cap abusive sessions within a single
    /// connection. Session-scoped; the calendar-month $ counterpart
    /// lives in the JSONL ledger below (D5).
    session_weight_total: u64,
    next_turn_index: u32,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    /// **D5 (2026-04-26)** — per-tenant JSONL cost ledger. When
    /// non-null, every `recordTurn` call append-writes a one-line JSON
    /// record to this path. `monthlyTotalUsd(now)` aggregates the
    /// ledger by calendar month for billing-grade cost accounting.
    /// Today's tenant runtime instantiates one UsageRuntime per
    /// workspace (gateway.zig:1405) so the ledger naturally scopes
    /// per-tenant when path = `{workspace_dir}/state/cost.jsonl`.
    /// Survives gateway restart; survives process crash (atomic-append
    /// at the OS-level, single line at a time so partial writes are
    /// detectable on read).
    cost_jsonl_path: ?[]const u8 = null,
    cost_jsonl_path_owned: bool = false,

    pub fn init(allocator: std.mem.Allocator) UsageRuntime {
        return .{
            .turns = .{},
            .session_input_tokens = 0,
            .session_output_tokens = 0,
            .session_total_tokens = 0,
            .session_cost_usd = 0.0,
            .session_weight_total = 0,
            .next_turn_index = 0,
            .allocator = allocator,
            .mutex = .{},
        };
    }

    /// **D5** — initialize with per-tenant cost-ledger persistence.
    /// `workspace_dir` is per-tenant (`{users_root}/{user_id}/workspace`
    /// in the standard tenant-runtime topology, sibling-of-tenant in
    /// the workspace-only topology). The ledger lives at
    /// `{workspace_dir}/state/cost.jsonl`. Parent directory is created
    /// on first append.
    pub fn initWithCostPersistence(
        allocator: std.mem.Allocator,
        workspace_dir: []const u8,
    ) !UsageRuntime {
        var rt = UsageRuntime.init(allocator);
        const path = try std.fs.path.join(allocator, &.{ workspace_dir, "state", "cost.jsonl" });
        rt.cost_jsonl_path = path;
        rt.cost_jsonl_path_owned = true;
        return rt;
    }

    pub fn deinit(self: *UsageRuntime) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.turns.items) |turn| {
            self.allocator.free(@constCast(turn.model));
        }
        self.turns.deinit(self.allocator);
        if (self.cost_jsonl_path_owned) {
            if (self.cost_jsonl_path) |p| self.allocator.free(@constCast(p));
        }
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

        // WO-03: accumulate THIS turn's own contribution into the
        // thread-local delta when the calling thread opened a tracking
        // window (`beginTurnDelta`). Done under the SAME lock as the
        // session totals so the value the done frame later reads is exactly
        // what THIS turn added — never a concurrent turn's. `cost_priced`
        // latches true on any non-zero priced contribution (Fix 3).
        if (turn_delta_tls.tracking) {
            turn_delta_tls.delta.input_tokens += input_tokens;
            turn_delta_tls.delta.output_tokens += output_tokens;
            turn_delta_tls.delta.total_tokens += input_tokens + output_tokens;
            turn_delta_tls.delta.cost_usd += cost_usd;
            if (cost_usd > 0.0) turn_delta_tls.delta.cost_priced = true;
        }

        // Ring buffer: drop oldest if at capacity, freeing its owned model.
        if (self.turns.items.len >= MAX_TURNS_TRACKED) {
            const evicted = self.turns.orderedRemove(0);
            self.allocator.free(@constCast(evicted.model));
        }

        // Duplicate the model string so callers may free/reuse their buffer.
        const owned_model = self.allocator.dupe(u8, model) catch return; // best-effort

        const ts = std.time.timestamp();
        self.turns.append(self.allocator, .{
            .model = owned_model,
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .total_tokens = input_tokens + output_tokens,
            .cost_usd = cost_usd,
            .duration_ms = duration_ms,
            .turn_index = self.next_turn_index,
            .timestamp_secs = ts,
        }) catch {
            // append failed — free the orphaned model to avoid leak.
            self.allocator.free(owned_model);
            return;
        };

        self.next_turn_index += 1;

        // D5 — persist to JSONL ledger when configured. Best-effort:
        // a write failure logs but does not block the session-totals
        // update (in-memory truth is preserved). Cross-restart accuracy
        // depends on this not failing under normal disk conditions.
        if (self.cost_jsonl_path != null) {
            self.persistTurnToJsonlLocked(model, input_tokens, output_tokens, cost_usd, ts) catch |err| {
                const log = std.log.scoped(.usage);
                log.warn("usage.cost_persist_failed err={s} model={s}", .{ @errorName(err), model });
            };
        }
    }

    /// **D5** — append one-line JSON record to the ledger. Caller must
    /// hold `self.mutex`. Creates parent dir on first call.
    fn persistTurnToJsonlLocked(
        self: *UsageRuntime,
        model: []const u8,
        input_tokens: u64,
        output_tokens: u64,
        cost_usd: f64,
        timestamp_secs: i64,
    ) !void {
        const path = self.cost_jsonl_path orelse return;
        if (std.fs.path.dirnamePosix(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }
        const file = try std.fs.cwd().createFile(path, .{ .truncate = false });
        defer file.close();
        file.seekFromEnd(0) catch {};

        var line_buf: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{{\"model\":\"{s}\",\"input_tokens\":{d},\"output_tokens\":{d},\"cost_usd\":{d:.8},\"timestamp\":{d}}}\n", .{
            model, input_tokens, output_tokens, cost_usd, timestamp_secs,
        });
        try file.writeAll(line);
    }

    /// **D5** — return total cost in USD recorded in the JSONL ledger
    /// for the calendar month (UTC) containing `now_secs`. Returns 0
    /// if no ledger configured or file unreadable. Calendar-month
    /// (year + month) comparison via std.time.epoch — stable across
    /// month boundaries (correct on Feb 28→Mar 1, leap years, etc.)
    /// unlike the day/30 approximation in cost.zig.
    pub fn monthlyTotalUsd(self: *UsageRuntime, now_secs: i64) f64 {
        // Snapshot the path under lock to avoid race vs. deinit.
        self.mutex.lock();
        const path_opt = self.cost_jsonl_path;
        self.mutex.unlock();
        const path = path_opt orelse return 0.0;

        const file = std.fs.cwd().openFile(path, .{}) catch return 0.0;
        defer file.close();

        const target_ym = yearMonthOrdinal(now_secs);
        var total: f64 = 0.0;

        var read_buf: [4096]u8 = undefined;
        var carry: usize = 0;
        while (true) {
            const n = file.read(read_buf[carry..]) catch break;
            if (n == 0 and carry == 0) break;
            const filled = carry + n;

            var start: usize = 0;
            while (std.mem.indexOfScalar(u8, read_buf[start..filled], '\n')) |nl| {
                const line = read_buf[start .. start + nl];
                start += nl + 1;
                if (parseLedgerLine(line)) |parsed| {
                    if (yearMonthOrdinal(parsed.timestamp) == target_ym) {
                        total += parsed.cost_usd;
                    }
                }
            }

            if (start < filled) {
                std.mem.copyForwards(u8, read_buf[0..(filled - start)], read_buf[start..filled]);
                carry = filled - start;
            } else {
                carry = 0;
            }

            if (n == 0) break;
        }

        return total;
    }

    /// Calendar (year, month) ordinal from epoch seconds, expressed as
    /// `year * 12 + (month - 1)`. Stable comparison key for "same
    /// month?" without dragging in date math at every call site.
    fn yearMonthOrdinal(secs: i64) i32 {
        if (secs < 0) return 0; // ledger has no pre-1970 entries
        const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
        const year_day = epoch_secs.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const year: i32 = @intCast(year_day.year);
        const month: i32 = @intCast(month_day.month.numeric());
        return year * 12 + (month - 1);
    }

    const LedgerLine = struct {
        timestamp: i64,
        cost_usd: f64,
    };

    /// Parse the two fields we need (`timestamp`, `cost_usd`) from a
    /// ledger JSON line via lightweight string scan. Avoids a full
    /// JSON parse per line (millions of lines per year for active
    /// tenants). Returns null on malformed input — that line is
    /// silently skipped (rolling totals continue).
    fn parseLedgerLine(line: []const u8) ?LedgerLine {
        const ts_marker = "\"timestamp\":";
        const cost_marker = "\"cost_usd\":";
        const ts_idx = std.mem.indexOf(u8, line, ts_marker) orelse return null;
        const cost_idx = std.mem.indexOf(u8, line, cost_marker) orelse return null;

        const ts_after = line[ts_idx + ts_marker.len ..];
        var ts_end: usize = 0;
        for (ts_after) |ch| {
            if (ch >= '0' and ch <= '9') ts_end += 1 else if (ch == '-' and ts_end == 0) ts_end += 1 else break;
        }
        if (ts_end == 0) return null;
        const ts = std.fmt.parseInt(i64, ts_after[0..ts_end], 10) catch return null;

        const cost_after = line[cost_idx + cost_marker.len ..];
        var cost_end: usize = 0;
        for (cost_after) |ch| {
            if ((ch >= '0' and ch <= '9') or ch == '.' or ch == '-' or ch == 'e' or ch == 'E' or ch == '+') cost_end += 1 else break;
        }
        if (cost_end == 0) return null;
        const cost = std.fmt.parseFloat(f64, cost_after[0..cost_end]) catch return null;

        return .{ .timestamp = ts, .cost_usd = cost };
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

    /// Accumulate tool-weight for this session (S2.8). Called by
    /// `executeToolUnchecked` after a successful preflight so the
    /// weight-budget gate in `preflightToolPolicy` sees this tool's
    /// contribution on subsequent dispatches. Saturating so the counter
    /// cannot wrap.
    pub fn recordWeight(self: *UsageRuntime, weight: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.session_weight_total +|= weight;
        // WO-03: mirror the per-turn delta accumulation for tool-weight so
        // the done frame's `turn_weight` reflects only THIS turn, immune to
        // a concurrent same-user turn racing the shared session counter.
        if (turn_delta_tls.tracking) {
            turn_delta_tls.delta.weight +|= weight;
        }
    }

    /// WO-03: open a per-turn delta tracking window on the CALLING thread.
    /// Resets the thread-local accumulator and arms accumulation in
    /// subsequent `recordTurn`/`recordWeight` calls on this same thread.
    /// The gateway calls this immediately before driving the turn, in place
    /// of taking before-snapshots of the shared cumulative totals.
    ///
    /// Idempotent within a thread: a fresh `beginTurnDelta` always starts
    /// from zero, so a path that began-but-never-took (e.g. an error before
    /// `takeTurnDelta`) cannot leak into the next turn on that worker.
    pub fn beginTurnDelta(self: *UsageRuntime) void {
        _ = self;
        turn_delta_tls = .{ .tracking = true, .delta = .{} };
    }

    /// WO-03: close the per-turn delta window on the CALLING thread and
    /// return what THIS turn accumulated. Disarms tracking so any stray
    /// later `recordTurn` (there should be none) does not corrupt the next
    /// turn. Returns a zeroed delta if `beginTurnDelta` was never called on
    /// this thread.
    pub fn takeTurnDelta(self: *UsageRuntime) TurnDelta {
        _ = self;
        const out = turn_delta_tls.delta;
        turn_delta_tls = .{ .tracking = false, .delta = .{} };
        return out;
    }

    /// Current session-accumulated tool-weight. Zero at session start,
    /// monotonically non-decreasing for the session lifetime.
    pub fn sessionWeight(self: *UsageRuntime) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.session_weight_total;
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

test "UsageRuntime.recordWeight accumulates session tool weight (S2.8)" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    try std.testing.expectEqual(@as(u64, 0), rt.sessionWeight());
    rt.recordWeight(1); // class-A
    rt.recordWeight(5); // class-B
    rt.recordWeight(25); // class-C
    try std.testing.expectEqual(@as(u64, 31), rt.sessionWeight());
}

test "UsageRuntime.recordWeight saturates at u64 max instead of wrapping" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    rt.recordWeight(std.math.maxInt(u64) - 5);
    rt.recordWeight(10); // would overflow; expect saturation
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), rt.sessionWeight());
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

// ── D5 — calendar-month JSONL persistence tests ────────────────────

test "D5 — initWithCostPersistence builds workspace-relative path" {
    const allocator = std.testing.allocator;
    var rt = try UsageRuntime.initWithCostPersistence(allocator, "/tmp/d5-test-workspace");
    defer rt.deinit();
    try std.testing.expect(rt.cost_jsonl_path != null);
    try std.testing.expect(rt.cost_jsonl_path_owned);
    try std.testing.expect(std.mem.endsWith(u8, rt.cost_jsonl_path.?, "/state/cost.jsonl"));
    try std.testing.expect(std.mem.indexOf(u8, rt.cost_jsonl_path.?, "/tmp/d5-test-workspace") != null);
}

test "D5 — recordTurn appends to JSONL when path configured" {
    const allocator = std.testing.allocator;
    // Use a unique tmp dir per test invocation to avoid cross-test pollution.
    var dir_buf: [128]u8 = undefined;
    const tmp_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/nullalis-d5-{d}", .{std.time.microTimestamp()});
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    var rt = try UsageRuntime.initWithCostPersistence(allocator, tmp_dir);
    defer rt.deinit();

    rt.recordTurn("test-model", 100, 50, 0.001234, 250);
    rt.recordTurn("test-model", 200, 100, 0.002468, 500);

    // Read the ledger file directly and assert it has 2 lines with expected fields.
    const path = rt.cost_jsonl_path.?;
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = try file.read(&buf);
    const content = buf[0..n];

    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, line, "\"model\":\"test-model\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"cost_usd\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"timestamp\":") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), line_count);
}

test "D5 — monthlyTotalUsd sums same-calendar-month entries" {
    const allocator = std.testing.allocator;
    var dir_buf: [128]u8 = undefined;
    const tmp_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/nullalis-d5-monthly-{d}", .{std.time.microTimestamp()});
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    var rt = try UsageRuntime.initWithCostPersistence(allocator, tmp_dir);
    defer rt.deinit();

    rt.recordTurn("m", 1, 1, 0.10, 1);
    rt.recordTurn("m", 1, 1, 0.20, 1);
    rt.recordTurn("m", 1, 1, 0.05, 1);

    const now = std.time.timestamp();
    const monthly = rt.monthlyTotalUsd(now);

    // 0.10 + 0.20 + 0.05 = 0.35; allow tiny float tolerance from %.8f roundtrip.
    try std.testing.expect(@abs(monthly - 0.35) < 0.0001);
}

test "D5 — monthlyTotalUsd excludes entries from other calendar months" {
    const allocator = std.testing.allocator;
    var dir_buf: [128]u8 = undefined;
    const tmp_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/nullalis-d5-bound-{d}", .{std.time.microTimestamp()});
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    var rt = try UsageRuntime.initWithCostPersistence(allocator, tmp_dir);
    defer rt.deinit();

    // Hand-craft three lines with explicit timestamps spanning 3 calendar
    // months so we can verify the year-month boundary is honored. Bypassing
    // recordTurn to set arbitrary timestamps; mirrors the exact wire format.
    const path = rt.cost_jsonl_path.?;
    if (std.fs.path.dirnamePosix(path)) |d| try std.fs.cwd().makePath(d);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    // 2024-01-15 00:00:00 UTC = 1705276800
    // 2024-02-15 00:00:00 UTC = 1707955200
    // 2024-03-15 00:00:00 UTC = 1710460800
    try file.writeAll("{\"model\":\"m\",\"input_tokens\":1,\"output_tokens\":1,\"cost_usd\":1.00000000,\"timestamp\":1705276800}\n");
    try file.writeAll("{\"model\":\"m\",\"input_tokens\":1,\"output_tokens\":1,\"cost_usd\":2.00000000,\"timestamp\":1707955200}\n");
    try file.writeAll("{\"model\":\"m\",\"input_tokens\":1,\"output_tokens\":1,\"cost_usd\":4.00000000,\"timestamp\":1710460800}\n");

    // Probe Feb (1707955200) — should return only the 2.00 entry.
    const feb_total = rt.monthlyTotalUsd(1707955200);
    try std.testing.expect(@abs(feb_total - 2.00) < 0.001);

    // Probe Jan — should return only 1.00.
    const jan_total = rt.monthlyTotalUsd(1705276800);
    try std.testing.expect(@abs(jan_total - 1.00) < 0.001);

    // Probe Mar — should return only 4.00.
    const mar_total = rt.monthlyTotalUsd(1710460800);
    try std.testing.expect(@abs(mar_total - 4.00) < 0.001);

    // Probe a month with no entries (April 2024 = 1712016000) — 0.
    const apr_total = rt.monthlyTotalUsd(1712016000);
    try std.testing.expect(apr_total == 0.0);
}

test "D5 — monthlyTotalUsd returns 0 when no path configured" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();
    rt.recordTurn("m", 100, 50, 5.0, 100);
    try std.testing.expect(rt.monthlyTotalUsd(std.time.timestamp()) == 0.0);
}

// ── WO-03 — per-turn delta accumulator tests ────────────────────────

test "WO-03 — takeTurnDelta returns only this turn's recordTurn contributions" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    // A prior priced turn inflates the SHARED session cumulative.
    rt.recordTurn("priced", 1000, 500, 5.0, 100);

    // Now open a turn window and record two provider responses (multi-step
    // tool turn). The delta must be EXACTLY this turn's accumulation, not
    // the session-cumulative which already carries the prior turn's $5.
    rt.beginTurnDelta();
    rt.recordTurn("m", 100, 50, 0.001, 100);
    rt.recordTurn("m", 200, 80, 0.002, 100);
    const d = rt.takeTurnDelta();

    try std.testing.expectEqual(@as(u64, 300), d.input_tokens);
    try std.testing.expectEqual(@as(u64, 130), d.output_tokens);
    try std.testing.expectEqual(@as(u64, 430), d.total_tokens);
    try std.testing.expect(@abs(d.cost_usd - 0.003) < 1e-9);
    try std.testing.expect(d.cost_priced);

    // Shared session totals still reflect ALL turns (unchanged behavior):
    // prior 1500 + this turn 430 = 1930.
    const totals = rt.sessionTotals();
    try std.testing.expectEqual(@as(u64, 1930), totals.total);
    try std.testing.expect(@abs(totals.cost - 5.003) < 1e-9);
}

test "WO-03 — takeTurnDelta without beginTurnDelta returns zeroed delta" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();
    rt.recordTurn("m", 100, 50, 1.0, 100); // not tracked
    const d = rt.takeTurnDelta();
    try std.testing.expectEqual(@as(u64, 0), d.total_tokens);
    try std.testing.expectEqual(@as(f64, 0.0), d.cost_usd);
    try std.testing.expect(!d.cost_priced);
}

test "WO-03 — beginTurnDelta resets any leftover accumulation" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    // Turn that began but never took (e.g. errored before takeTurnDelta).
    rt.beginTurnDelta();
    rt.recordTurn("m", 999, 999, 9.0, 100);

    // Next turn on the same (thread) worker must start from zero.
    rt.beginTurnDelta();
    rt.recordTurn("m", 1, 2, 0.5, 100);
    const d = rt.takeTurnDelta();
    try std.testing.expectEqual(@as(u64, 1), d.input_tokens);
    try std.testing.expectEqual(@as(u64, 2), d.output_tokens);
    try std.testing.expect(@abs(d.cost_usd - 0.5) < 1e-9);
}

test "WO-03 (Fix 3) — unpriced turn after a priced one reports cost_priced=false" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    // Priced turn first → session cumulative cost > 0.
    rt.recordTurn("priced", 100, 50, 2.5, 100);

    // Unpriced-model turn (pricing table returned 0) AFTER it.
    rt.beginTurnDelta();
    rt.recordTurn("unpriced", 100, 50, 0.0, 100);
    const d = rt.takeTurnDelta();

    // Even though session cumulative is > 0, THIS turn was not priced.
    try std.testing.expectEqual(@as(f64, 0.0), d.cost_usd);
    try std.testing.expect(!d.cost_priced);
    // Tokens still flow (they're not gated on pricing).
    try std.testing.expectEqual(@as(u64, 150), d.total_tokens);
}

test "WO-03 — takeTurnDelta captures tool-weight for the turn" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    rt.recordWeight(7); // before the window — must not count
    rt.beginTurnDelta();
    rt.recordWeight(1);
    rt.recordWeight(5);
    const d = rt.takeTurnDelta();
    try std.testing.expectEqual(@as(u64, 6), d.weight);
    // Session-cumulative weight still includes the pre-window contribution.
    try std.testing.expectEqual(@as(u64, 13), rt.sessionWeight());
}

test "WO-03 — concurrent same-runtime turns get independent thread-local deltas" {
    const allocator = std.testing.allocator;
    var rt = UsageRuntime.init(allocator);
    defer rt.deinit();

    const Worker = struct {
        fn run(r: *UsageRuntime, cost: f64, tokens: u64, out: *TurnDelta, barrier: *std.atomic.Value(u32)) void {
            r.beginTurnDelta();
            r.recordTurn("m", tokens, tokens, cost, 1);
            // Spin so both threads interleave recordTurn calls against the
            // shared session cumulative before either takes its delta.
            _ = barrier.fetchAdd(1, .seq_cst);
            while (barrier.load(.seq_cst) < 2) {}
            r.recordTurn("m", tokens, tokens, cost, 1);
            out.* = r.takeTurnDelta();
        }
    };

    var barrier = std.atomic.Value(u32).init(0);
    var a_out: TurnDelta = .{};
    var b_out: TurnDelta = .{};
    const ta = try std.Thread.spawn(.{}, Worker.run, .{ &rt, 1.0, 100, &a_out, &barrier });
    const tb = try std.Thread.spawn(.{}, Worker.run, .{ &rt, 2.0, 200, &b_out, &barrier });
    ta.join();
    tb.join();

    // Each thread's delta reflects only its own two recordTurn calls, never
    // the other's — despite both racing the shared session cumulative.
    try std.testing.expect(@abs(a_out.cost_usd - 2.0) < 1e-9);
    try std.testing.expectEqual(@as(u64, 400), a_out.total_tokens);
    try std.testing.expect(@abs(b_out.cost_usd - 4.0) < 1e-9);
    try std.testing.expectEqual(@as(u64, 800), b_out.total_tokens);

    // Shared session cumulative is the sum of all four recordTurn calls.
    const totals = rt.sessionTotals();
    try std.testing.expectEqual(@as(u64, 1200), totals.total);
    try std.testing.expect(@abs(totals.cost - 6.0) < 1e-9);
}

test "D5 — yearMonthOrdinal handles year boundaries correctly" {
    // 2024-12-31 23:59:59 UTC = 1735689599 → ordinal = 2024*12 + 11 = 24299
    // 2025-01-01 00:00:00 UTC = 1735689600 → ordinal = 2025*12 + 0  = 24300
    try std.testing.expectEqual(@as(i32, 24299), UsageRuntime.yearMonthOrdinal(1735689599));
    try std.testing.expectEqual(@as(i32, 24300), UsageRuntime.yearMonthOrdinal(1735689600));
    // Different days, same month → same ordinal
    try std.testing.expectEqual(
        UsageRuntime.yearMonthOrdinal(1707955200), // 2024-02-15
        UsageRuntime.yearMonthOrdinal(1709251199), // 2024-02-29 23:59:59 (leap year)
    );
}
