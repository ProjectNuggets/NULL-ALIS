//! The miner — pure, deterministic analysis of tool-trace digests
//! (Package 2a Task 3). Governed by docs/learning-contract.md invariants
//! 2, 4, 5. Implementation follows in small TDD steps below.

const std = @import("std");

/// One row read back from the tool_traces table (Manager's
/// listRecentToolTraces / listRecentToolTracesAllUsers). `events_json`
/// is the raw JSONB array text exactly as
/// run_trace_store.serializeEventsJsonArray wrote it. Caller
/// (zaki_state.zig) owns allocation; analyze() only borrows these
/// slices for the duration of the call.
pub const ToolTraceDigestRow = struct {
    run_id: []const u8,
    events_json: []const u8,
    created_at_unix: i64,

    pub fn deinit(self: ToolTraceDigestRow, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.events_json);
    }
};

/// The conservative threshold (learning-contract-design.md's mining
/// section): a failure pattern or a recurring tool-sequence shingle
/// must be seen at least this many times before it is surfaced as a
/// pattern/cluster at all. Below this, occurrences are noise and are
/// dropped entirely (not rendered) — this is what keeps the miner's
/// output cheap and deterministic rather than a firehose of one-off
/// blips.
pub const MIN_PATTERN_COUNT: usize = 3;

/// A failure mode: a (tool, label) pair that failed at least
/// MIN_PATTERN_COUNT times across the mined window. `label` is the
/// error-ish string carried on the trace event (the label/status
/// fields serializeTraceEventJson emits); an event with no label is
/// grouped under the empty-string label for that tool. Evidence
/// run_ids are format-validated (isValidRunId) before being attached.
pub const FailurePattern = struct {
    tool: []const u8,
    label: []const u8,
    count: usize,
    evidence_run_ids: [][]const u8,

    pub fn deinit(self: FailurePattern, allocator: std.mem.Allocator) void {
        allocator.free(self.tool);
        allocator.free(self.label);
        for (self.evidence_run_ids) |id| allocator.free(id);
        allocator.free(self.evidence_run_ids);
    }
};

/// A repeated tool-sequence shingle (order-preserving n-gram of tool
/// names within a single run), counted across runs. `sequence` is the
/// ordered list of tool names in the shingle (length 2 or 3).
pub const RecurrenceCluster = struct {
    sequence: [][]const u8,
    count: usize,
    evidence_run_ids: [][]const u8,

    pub fn deinit(self: RecurrenceCluster, allocator: std.mem.Allocator) void {
        for (self.sequence) |s| allocator.free(s);
        allocator.free(self.sequence);
        for (self.evidence_run_ids) |id| allocator.free(id);
        allocator.free(self.evidence_run_ids);
    }
};

/// Tool-fluency stats: usage count, success rate, median duration
/// across the mined window. Unlike FailurePattern/RecurrenceCluster,
/// ToolStat has no MIN_PATTERN_COUNT gate — a tool used once still gets
/// a row (fluency reporting, not anomaly detection).
pub const ToolStat = struct {
    tool: []const u8,
    uses: usize,
    success_rate: f64,
    p50_duration_ms: u64,

    pub fn deinit(self: ToolStat, allocator: std.mem.Allocator) void {
        allocator.free(self.tool);
    }
};

pub const MiningReport = struct {
    failure_patterns: []FailurePattern,
    recurrences: []RecurrenceCluster,
    tool_stats: []ToolStat,

    pub fn deinit(self: MiningReport, allocator: std.mem.Allocator) void {
        for (self.failure_patterns) |p| p.deinit(allocator);
        allocator.free(self.failure_patterns);
        for (self.recurrences) |r| r.deinit(allocator);
        allocator.free(self.recurrences);
        for (self.tool_stats) |t| t.deinit(allocator);
        allocator.free(self.tool_stats);
    }
};

/// A fleet-scope failure mode: tool + failure-count ONLY. Unlike
/// FailurePattern (the per-tenant type), this deliberately has NO
/// `label` and NO `evidence_run_ids` field — labels can embed tenant
/// content and run_ids identify a user's runs (learning contract
/// inv. 5). Grouping is by TOOL alone (all of a tool's failures across
/// the window collapse to one count), never by (tool, label). Produced
/// by Manager.fleetMiningStats' SQL-side aggregation.
pub const FleetFailurePattern = struct {
    tool: []const u8,
    count: usize,

    pub fn deinit(self: FleetFailurePattern, allocator: std.mem.Allocator) void {
        allocator.free(self.tool);
    }
};

/// The bounded fleet-scope aggregate — the SHAPE-ONLY projection the
/// operator endpoint (GET /internal/fleet/mining-stats) emits.
///
/// This type is the structural half of the fix for the HIGH-severity
/// unbounded-materialization defect: the fleet path computes these
/// aggregates SQL-side (Manager.fleetMiningStats) and never loads the
/// full cross-tenant trace corpus into app memory. FleetStats
/// deliberately has NO `recurrences` and NO evidence/run_id fields —
/// the discarded run_id/recurrence work MiningReport carried is not
/// merely dropped at render time, it is never built or even
/// representable here. `tool_stats` reuses ToolStat (its four fields are
/// exactly what renderFleetJson reads). Caller owns the result; call
/// deinit.
pub const FleetStats = struct {
    failure_patterns: []FleetFailurePattern,
    tool_stats: []ToolStat,

    pub fn deinit(self: FleetStats, allocator: std.mem.Allocator) void {
        for (self.failure_patterns) |p| p.deinit(allocator);
        allocator.free(self.failure_patterns);
        for (self.tool_stats) |t| t.deinit(allocator);
        allocator.free(self.tool_stats);
    }
};

test "FleetStats is bounded BY CONSTRUCTION: no recurrence / run_id / label fields (inv. 5 + no-full-corpus)" {
    // The bounded fleet path returns FleetStats, NOT MiningReport. This
    // is the compile-time proof that the fleet endpoint cannot even
    // REPRESENT run_id evidence or recurrence shingles, let alone
    // materialize them: those fields do not exist on the fleet types. A
    // future edit that reintroduces run_id/recurrence/label plumbing onto
    // the fleet surface fails this test at comptime.
    try std.testing.expect(@hasField(FleetStats, "tool_stats"));
    try std.testing.expect(@hasField(FleetStats, "failure_patterns"));
    try std.testing.expect(!@hasField(FleetStats, "recurrences"));
    try std.testing.expect(!@hasField(FleetStats, "evidence_run_ids"));

    // Fleet failure patterns are tool + count ONLY — no label (tenant
    // content) and no evidence run_ids (per-user identifiers).
    try std.testing.expect(@hasField(FleetFailurePattern, "tool"));
    try std.testing.expect(@hasField(FleetFailurePattern, "count"));
    try std.testing.expect(!@hasField(FleetFailurePattern, "label"));
    try std.testing.expect(!@hasField(FleetFailurePattern, "evidence_run_ids"));
}

/// Parsed view of one `tool_call`-kind event relevant to failure-pattern
/// mining. Borrows slices from the parsed std.json.Value tree — valid
/// only while that tree (and its owning ParseFromSliceResult) is alive.
const ParsedFailureEvent = struct {
    tool: []const u8,
    label: []const u8,
};

/// Scans one row's events_json for tool_call events with success=false,
/// calling `cb` for each one found. Malformed/unparseable JSON is
/// treated as "no events" (mining degrades gracefully — never errors
/// the whole batch over one bad row).
fn forEachFailedToolCall(
    allocator: std.mem.Allocator,
    events_json: []const u8,
    context: anytype,
    comptime cb: fn (@TypeOf(context), ParsedFailureEvent) anyerror!void,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, events_json, .{}) catch return;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return,
    };
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const kind = obj.get("kind") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "tool_call")) continue;
        const success_val = obj.get("success") orelse continue;
        if (success_val != .bool or success_val.bool) continue; // only success=false
        const tool_val = obj.get("tool") orelse continue;
        if (tool_val != .string) continue;
        const label: []const u8 = if (obj.get("label")) |l| switch (l) {
            .string => |s| s,
            else => "",
        } else "";
        try cb(context, .{ .tool = tool_val.string, .label = label });
    }
}

const FailureKey = struct {
    tool: []const u8,
    label: []const u8,
};
const FailureAccum = struct {
    run_ids: std.ArrayListUnmanaged([]const u8) = .empty,
};

const FailureCollectCtx = struct {
    allocator: std.mem.Allocator,
    map: *std.ArrayHashMapUnmanaged(FailureKey, FailureAccum, FailureKeyContext, true),
    run_id: []const u8,

    /// IMPORTANT: `ev.tool`/`ev.label` are BORROWED slices into the
    /// caller's per-row std.json.Value parse tree, which is deinit'd
    /// (freeing that memory) as soon as forEachFailedToolCall returns —
    /// i.e. before the NEXT row is even parsed. Because `map` persists
    /// across rows, a stored FailureKey holding a borrowed slice from
    /// row N would dangle by the time row N+1's getOrPut does an `eql`
    /// comparison against it — a real use-after-free that segfaults
    /// under zig test's poisoning allocator (caught via `zig test
    /// src/agent/trace_mining.zig` directly; not surfaced by `zig build
    /// test`). Only insert an OWNED copy when the key is new; the
    /// looked-up-but-already-owned copy on a repeat match is simply
    /// discarded (not leaked — never allocated).
    fn onEvent(self: FailureCollectCtx, ev: ParsedFailureEvent) anyerror!void {
        const probe_key = FailureKey{ .tool = ev.tool, .label = ev.label };
        if (self.map.getPtr(probe_key)) |existing| {
            try existing.run_ids.append(self.allocator, self.run_id);
            return;
        }
        const owned_key = FailureKey{
            .tool = try self.allocator.dupe(u8, ev.tool),
            .label = try self.allocator.dupe(u8, ev.label),
        };
        const gop = try self.map.getOrPut(self.allocator, owned_key);
        std.debug.assert(!gop.found_existing); // just checked above under the same key shape
        gop.value_ptr.* = .{};
        try gop.value_ptr.run_ids.append(self.allocator, self.run_id);
    }
};

const FailureKeyContext = struct {
    pub fn hash(_: FailureKeyContext, k: FailureKey) u32 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.tool);
        h.update("\x00");
        h.update(k.label);
        return @truncate(h.final());
    }
    pub fn eql(_: FailureKeyContext, a: FailureKey, b: FailureKey, _: usize) bool {
        return std.mem.eql(u8, a.tool, b.tool) and std.mem.eql(u8, a.label, b.label);
    }
};

/// Extracts the ORDERED sequence of tool names from every `tool_call`
/// event in one row (regardless of success/failure — recurrence mining
/// is about repeated PROCEDURES, not just failures). Returns an owned
/// slice of owned tool-name copies (safe to keep after this row's JSON
/// parse tree is torn down); caller frees each name then the slice.
/// Malformed/unparseable JSON degrades to an empty sequence.
fn extractToolSequence(allocator: std.mem.Allocator, events_json: []const u8) ![][]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, events_json, .{}) catch
        return allocator.alloc([]const u8, 0);
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return allocator.alloc([]const u8, 0),
    };

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const kind = obj.get("kind") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "tool_call")) continue;
        const tool_val = obj.get("tool") orelse continue;
        if (tool_val != .string) continue;
        try out.append(allocator, try allocator.dupe(u8, tool_val.string));
    }
    return out.toOwnedSlice(allocator);
}

/// Shingle lengths mined for recurrence clusters — order-2 and order-3
/// n-grams of consecutive tool names within a single run (per the
/// binding design). Named so both the generator loop and any future
/// reader of this file see the exact contract in one place.
const SHINGLE_LENGTHS = [_]usize{ 2, 3 };

const ShingleAccum = struct {
    sequence: [][]const u8, // owned copy of the shingle's tool names
    run_ids: std.ArrayListUnmanaged([]const u8) = .empty,
};

/// Builds the "\x00"-joined lookup key for a shingle (tool names can
/// legally contain any character our own tool-name registry allows, so
/// a NUL-byte separator avoids ambiguity between e.g. ["ab","c"] and
/// ["a","bc"] that a bare concatenation could conflate).
fn shingleMapKey(allocator: std.mem.Allocator, seq: []const []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (seq, 0..) |tool, i| {
        if (i > 0) try buf.append(allocator, 0);
        try buf.appendSlice(allocator, tool);
    }
    return buf.toOwnedSlice(allocator);
}

/// Pure, deterministic analysis of tool-trace digest rows (learning
/// contract inv. 2: observational only, no LLM, no I/O). Currently
/// derives FailurePattern entries; recurrence clusters and tool stats
/// are added in later steps of this module's TDD build-out.
pub fn analyze(allocator: std.mem.Allocator, rows: []const ToolTraceDigestRow) !MiningReport {
    var map: std.ArrayHashMapUnmanaged(FailureKey, FailureAccum, FailureKeyContext, true) = .empty;
    defer {
        var it = map.iterator();
        while (it.next()) |e| {
            // Keys are OWNED copies (see FailureCollectCtx.onEvent's doc
            // comment) — free them here, not just the accumulated values.
            allocator.free(e.key_ptr.tool);
            allocator.free(e.key_ptr.label);
            e.value_ptr.run_ids.deinit(allocator);
        }
        map.deinit(allocator);
    }

    for (rows) |row| {
        const ctx = FailureCollectCtx{ .allocator = allocator, .map = &map, .run_id = row.run_id };
        try forEachFailedToolCall(allocator, row.events_json, ctx, FailureCollectCtx.onEvent);
    }

    var patterns: std.ArrayListUnmanaged(FailurePattern) = .empty;
    errdefer {
        for (patterns.items) |p| p.deinit(allocator);
        patterns.deinit(allocator);
    }

    var it = map.iterator();
    while (it.next()) |entry| {
        const count = entry.value_ptr.run_ids.items.len;
        if (count < MIN_PATTERN_COUNT) continue;

        const evidence = try allocator.alloc([]const u8, count);
        var filled: usize = 0;
        errdefer {
            for (evidence[0..filled]) |e| allocator.free(e);
            allocator.free(evidence);
        }
        for (entry.value_ptr.run_ids.items, 0..) |rid, i| {
            evidence[i] = try allocator.dupe(u8, rid);
            filled = i + 1;
        }
        // Evidence run_ids must be in a deterministic order regardless
        // of which row happened to be scanned first (inv. 4 —
        // rebuildability requires byte-identical re-mine output).
        std.mem.sort([]const u8, evidence, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        try patterns.append(allocator, .{
            .tool = try allocator.dupe(u8, entry.key_ptr.tool),
            .label = try allocator.dupe(u8, entry.key_ptr.label),
            .count = count,
            .evidence_run_ids = evidence,
        });
    }

    const owned = try patterns.toOwnedSlice(allocator);
    std.mem.sort(FailurePattern, owned, {}, struct {
        fn lessThan(_: void, a: FailurePattern, b: FailurePattern) bool {
            if (a.count != b.count) return a.count > b.count; // count desc
            if (!std.mem.eql(u8, a.tool, b.tool)) return std.mem.lessThan(u8, a.tool, b.tool);
            return std.mem.lessThan(u8, a.label, b.label);
        }
    }.lessThan);
    errdefer {
        for (owned) |p| p.deinit(allocator);
        allocator.free(owned);
    }

    const recurrences = try mineRecurrenceClusters(allocator, rows);
    errdefer {
        for (recurrences) |r| r.deinit(allocator);
        allocator.free(recurrences);
    }

    const tool_stats = try mineToolStats(allocator, rows);

    return .{ .failure_patterns = owned, .recurrences = recurrences, .tool_stats = tool_stats };
}

const ToolStatAccum = struct {
    uses: usize = 0,
    successes: usize = 0,
    durations: std.ArrayListUnmanaged(u64) = .empty,
};

/// Scans every row for `tool_call` events (any success value) and
/// computes per-tool usage count, success rate, and median
/// (p50) duration. A tool with zero recorded durations reports
/// p50_duration_ms=0 (no basis to report a median). No MIN_PATTERN_COUNT
/// gate here — fluency stats are a full census, not anomaly detection.
fn mineToolStats(allocator: std.mem.Allocator, rows: []const ToolTraceDigestRow) ![]ToolStat {
    var map: std.StringArrayHashMapUnmanaged(ToolStatAccum) = .empty;
    defer {
        var it = map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            e.value_ptr.durations.deinit(allocator);
        }
        map.deinit(allocator);
    }

    for (rows) |row| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, row.events_json, .{}) catch continue;
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => continue,
        };
        for (arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const kind = obj.get("kind") orelse continue;
            if (kind != .string or !std.mem.eql(u8, kind.string, "tool_call")) continue;
            const tool_val = obj.get("tool") orelse continue;
            if (tool_val != .string) continue;

            const gop = try map.getOrPut(allocator, tool_val.string);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, tool_val.string);
                gop.value_ptr.* = .{};
            }
            gop.value_ptr.uses += 1;
            if (obj.get("success")) |sv| {
                if (sv == .bool and sv.bool) gop.value_ptr.successes += 1;
            }
            if (obj.get("duration_ms")) |dv| {
                // Negative duration = malformed row (P3): SKIP the
                // duration, keep the call counted. The prior naked
                // @intCast(i64 -> u64) trapped the whole mining run on
                // one bad row; clamping to 0 would instead skew p50
                // with a fake sample.
                if (dv == .integer and dv.integer >= 0) {
                    try gop.value_ptr.durations.append(allocator, @intCast(dv.integer));
                }
            }
        }
    }

    var stats: std.ArrayListUnmanaged(ToolStat) = .empty;
    errdefer {
        for (stats.items) |s| s.deinit(allocator);
        stats.deinit(allocator);
    }

    var it = map.iterator();
    while (it.next()) |entry| {
        const uses = entry.value_ptr.uses;
        const success_rate: f64 = if (uses == 0) 0.0 else @as(f64, @floatFromInt(entry.value_ptr.successes)) / @as(f64, @floatFromInt(uses));

        // Median duration: sort a scratch copy, take the middle element
        // (lower-middle on even counts — matches the brief's "p50").
        const durations = entry.value_ptr.durations.items;
        var p50: u64 = 0;
        if (durations.len > 0) {
            const scratch = try allocator.dupe(u64, durations);
            defer allocator.free(scratch);
            std.mem.sort(u64, scratch, {}, std.sort.asc(u64));
            p50 = scratch[scratch.len / 2];
        }

        try stats.append(allocator, .{
            .tool = try allocator.dupe(u8, entry.key_ptr.*),
            .uses = uses,
            .success_rate = success_rate,
            .p50_duration_ms = p50,
        });
    }

    const owned_stats = try stats.toOwnedSlice(allocator);
    std.mem.sort(ToolStat, owned_stats, {}, struct {
        fn lessThan(_: void, a: ToolStat, b: ToolStat) bool {
            if (a.uses != b.uses) return a.uses > b.uses; // uses desc
            return std.mem.lessThan(u8, a.tool, b.tool);
        }
    }.lessThan);

    return owned_stats;
}

/// Mines order-2/3 tool-sequence shingles across all rows (see
/// SHINGLE_LENGTHS), keeping only those seen at least MIN_PATTERN_COUNT
/// times. Each row is scanned once per shingle length (cheap — rows are
/// short digests, not full transcripts).
fn mineRecurrenceClusters(allocator: std.mem.Allocator, rows: []const ToolTraceDigestRow) ![]RecurrenceCluster {
    var map: std.StringArrayHashMapUnmanaged(ShingleAccum) = .empty;
    defer {
        var it = map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            for (e.value_ptr.sequence) |s| allocator.free(s);
            allocator.free(e.value_ptr.sequence);
            e.value_ptr.run_ids.deinit(allocator);
        }
        map.deinit(allocator);
    }

    for (rows) |row| {
        const seq = try extractToolSequence(allocator, row.events_json);
        defer {
            for (seq) |s| allocator.free(s);
            allocator.free(seq);
        }

        for (SHINGLE_LENGTHS) |shingle_len| {
            if (seq.len < shingle_len) continue;
            var start: usize = 0;
            while (start + shingle_len <= seq.len) : (start += 1) {
                const shingle = seq[start .. start + shingle_len];
                const lookup_key = try shingleMapKey(allocator, shingle);
                defer allocator.free(lookup_key);

                if (map.getPtr(lookup_key)) |existing| {
                    try existing.run_ids.append(allocator, row.run_id);
                    continue;
                }

                const owned_seq = try allocator.alloc([]const u8, shingle.len);
                var filled: usize = 0;
                errdefer {
                    for (owned_seq[0..filled]) |s| allocator.free(s);
                    allocator.free(owned_seq);
                }
                for (shingle, 0..) |tool, i| {
                    owned_seq[i] = try allocator.dupe(u8, tool);
                    filled = i + 1;
                }

                const owned_key = try allocator.dupe(u8, lookup_key);
                errdefer allocator.free(owned_key);
                const gop = try map.getOrPut(allocator, owned_key);
                std.debug.assert(!gop.found_existing);
                gop.value_ptr.* = .{ .sequence = owned_seq };
                try gop.value_ptr.run_ids.append(allocator, row.run_id);
            }
        }
    }

    var clusters: std.ArrayListUnmanaged(RecurrenceCluster) = .empty;
    errdefer {
        for (clusters.items) |c| c.deinit(allocator);
        clusters.deinit(allocator);
    }

    var it = map.iterator();
    while (it.next()) |entry| {
        const count = entry.value_ptr.run_ids.items.len;
        if (count < MIN_PATTERN_COUNT) continue;

        const evidence = try allocator.alloc([]const u8, count);
        var filled: usize = 0;
        errdefer {
            for (evidence[0..filled]) |e| allocator.free(e);
            allocator.free(evidence);
        }
        for (entry.value_ptr.run_ids.items, 0..) |rid, i| {
            evidence[i] = try allocator.dupe(u8, rid);
            filled = i + 1;
        }
        std.mem.sort([]const u8, evidence, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        const seq_copy = try allocator.alloc([]const u8, entry.value_ptr.sequence.len);
        var seq_filled: usize = 0;
        errdefer {
            for (seq_copy[0..seq_filled]) |s| allocator.free(s);
            allocator.free(seq_copy);
        }
        for (entry.value_ptr.sequence, 0..) |tool, i| {
            seq_copy[i] = try allocator.dupe(u8, tool);
            seq_filled = i + 1;
        }

        try clusters.append(allocator, .{
            .sequence = seq_copy,
            .count = count,
            .evidence_run_ids = evidence,
        });
    }

    const owned_clusters = try clusters.toOwnedSlice(allocator);
    // Deterministic order: count desc, then sequence lexicographically
    // (joined by "\x00", matching the map key so this cannot disagree
    // with the grouping semantics above).
    std.mem.sort(RecurrenceCluster, owned_clusters, {}, struct {
        fn lessThan(_: void, a: RecurrenceCluster, b: RecurrenceCluster) bool {
            if (a.count != b.count) return a.count > b.count;
            if (a.sequence.len != b.sequence.len) return a.sequence.len < b.sequence.len;
            for (a.sequence, b.sequence) |sa, sb| {
                if (!std.mem.eql(u8, sa, sb)) return std.mem.lessThan(u8, sa, sb);
            }
            return false;
        }
    }.lessThan);

    return owned_clusters;
}

/// Computes the ISO-8601 week label ("YYYY-Www", e.g. "2026-W28") for a
/// unix timestamp (seconds since epoch). Used both as the human-facing
/// week_label passed to renderInsightsMarkdown and to build the
/// `workspace/insights/{ISO-week}.md` / `.json` file names.
///
/// ISO-8601 weeks start Monday and are numbered by the year that
/// contains their THURSDAY — so the first days of January can belong
/// to the previous year's last week (52 or 53), and the last days of
/// December can belong to the next year's week 1. This function
/// implements the standard ordinal-day algorithm rather than a partial
/// approximation, specifically to get those boundary cases right (see
/// the boundary tests below, cross-checked against Python's
/// datetime.isocalendar()).
pub fn isoWeekLabel(unix_ts: i64) [8]u8 {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, unix_ts)) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const calendar_year: i32 = @intCast(year_day.year);
    const ordinal_day: i32 = @as(i32, year_day.day) + 1; // calculateYearDay's day is 0-indexed

    // Weekday, Monday=1..Sunday=7 (ISO convention). Epoch day 0
    // (1970-01-01) was a Thursday; Monday-indexed-from-0 that's
    // weekday_mon0=3, so iso_weekday = weekday_mon0 + 1.
    const days_since_epoch: i64 = @intCast(epoch_day.day);
    const weekday_mon0: i64 = @mod(days_since_epoch + 3, 7);
    const iso_weekday: i32 = @as(i32, @intCast(weekday_mon0)) + 1;

    // Standard ISO week-number formula.
    var week: i32 = @divFloor(ordinal_day - iso_weekday + 10, 7);
    var iso_year: i32 = calendar_year;

    if (week < 1) {
        // Belongs to the previous year's last week.
        iso_year -= 1;
        week = isoWeeksInYear(iso_year);
    } else {
        const weeks_this_year = isoWeeksInYear(iso_year);
        if (week > weeks_this_year) {
            iso_year += 1;
            week = 1;
        }
    }

    // Cast to unsigned before formatting: Zig's signed-integer formatter
    // reserves a byte for a possible '-' sign even when the value is
    // positive, which overflows an exactly-sized [8]u8 buffer
    // ("2026-W28" is exactly 8 bytes with no room for a phantom sign
    // byte). iso_year/week are always non-negative in any valid
    // ISO-week computation, so the cast is lossless.
    var buf: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-W{d:0>2}", .{ @as(u32, @intCast(iso_year)), @as(u32, @intCast(week)) }) catch unreachable;
    return buf;
}

/// Number of ISO-8601 weeks in a given year (52 or 53). A year has 53
/// ISO weeks iff Jan 1 of that year falls on a Thursday, OR (for leap
/// years) Jan 1 falls on a Wednesday. Implemented via the weekday of
/// Dec 31 of that year — standard equivalent formulation used by most
/// reference ISO-week implementations.
fn isoWeeksInYear(year: i32) i32 {
    const p = @mod(year + @divFloor(year, 4) - @divFloor(year, 100) + @divFloor(year, 400), 7);
    if (p == 4) return 53;
    // Leap year with Jan 1 on a Wednesday also yields 53 weeks —
    // equivalent check: p == 3 for the PREVIOUS year's contribution.
    const prev_p = @mod((year - 1) + @divFloor(year - 1, 4) - @divFloor(year - 1, 100) + @divFloor(year - 1, 400), 7);
    if (prev_p == 3) return 53;
    return 52;
}

/// Validates the run-id SHAPE the binding design requires:
/// `r-<digits>-<digits>` (e.g. "r-1720000000-42"). Anything else —
/// including a run_id containing a newline or a comma, which could
/// otherwise inject a fake header line into learning.zig's
/// content-header format (the residual T2's report flagged) — is
/// rejected. This is the FIRST real call site validating
/// evidence_run_ids before they reach storeLearnedFact or a renderer.
pub fn isValidRunId(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "r-")) return false;
    const rest = s[2..];
    const dash_idx = std.mem.indexOfScalar(u8, rest, '-') orelse return false;
    const first_digits = rest[0..dash_idx];
    const second_digits = rest[dash_idx + 1 ..];
    if (first_digits.len == 0 or second_digits.len == 0) return false;
    for (first_digits) |c| if (!std.ascii.isDigit(c)) return false;
    for (second_digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "isValidRunId accepts the r-<digits>-<digits> shape" {
    try std.testing.expect(isValidRunId("r-1720000000-42"));
}

test "isValidRunId rejects a run_id containing a newline (T2's flagged residual)" {
    try std.testing.expect(!isValidRunId("r-123-1\nstate=active"));
}

test "isValidRunId rejects a run_id containing a comma" {
    try std.testing.expect(!isValidRunId("r-123-1,r-456-2"));
}

test "isValidRunId rejects a bare non-shaped string" {
    try std.testing.expect(!isValidRunId("run_abc"));
}

test "isValidRunId rejects empty string" {
    try std.testing.expect(!isValidRunId(""));
}

test "isValidRunId rejects missing second segment" {
    try std.testing.expect(!isValidRunId("r-123-"));
}

test "isValidRunId rejects non-digit segments" {
    try std.testing.expect(!isValidRunId("r-abc-def"));
}

// ── analyze(): failure-pattern threshold ────────────────────────────
//
// A (tool, label) pair that fails fewer than MIN_PATTERN_COUNT times is
// noise and must not appear in the report at all — not even as a
// count-2 entry. At MIN_PATTERN_COUNT it becomes a real FailurePattern.

fn failedToolCallRow(run_id: []const u8, tool: []const u8, label: []const u8) ToolTraceDigestRow {
    const events_json = std.fmt.allocPrint(
        std.testing.allocator,
        "[{{\"kind\":\"tool_call\",\"tool\":\"{s}\",\"label\":\"{s}\",\"success\":false,\"duration_ms\":10}}]",
        .{ tool, label },
    ) catch unreachable;
    return .{
        .run_id = std.testing.allocator.dupe(u8, run_id) catch unreachable,
        .events_json = events_json,
        .created_at_unix = 0,
    };
}

test "analyze: 2 occurrences of the same failure produce NO pattern (below threshold)" {
    const allocator = std.testing.allocator;
    var rows = [_]ToolTraceDigestRow{
        failedToolCallRow("r-1-1", "web_search", "timeout"),
        failedToolCallRow("r-2-1", "web_search", "timeout"),
    };
    defer for (rows) |r| r.deinit(allocator);

    var report = try analyze(allocator, &rows);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), report.failure_patterns.len);
}

test "analyze: 3 occurrences of the same failure DO produce a pattern (at threshold)" {
    const allocator = std.testing.allocator;
    var rows = [_]ToolTraceDigestRow{
        failedToolCallRow("r-1-1", "web_search", "timeout"),
        failedToolCallRow("r-2-1", "web_search", "timeout"),
        failedToolCallRow("r-3-1", "web_search", "timeout"),
    };
    defer for (rows) |r| r.deinit(allocator);

    var report = try analyze(allocator, &rows);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), report.failure_patterns.len);
    try std.testing.expectEqualStrings("web_search", report.failure_patterns[0].tool);
    try std.testing.expectEqualStrings("timeout", report.failure_patterns[0].label);
    try std.testing.expectEqual(@as(usize, 3), report.failure_patterns[0].count);
    try std.testing.expectEqual(@as(usize, 3), report.failure_patterns[0].evidence_run_ids.len);
}

test "analyze: two distinct failure patterns sort by count desc, then tool asc, then label asc" {
    const allocator = std.testing.allocator;
    var rows = [_]ToolTraceDigestRow{
        // "bash" x3 (higher count — must sort first)
        failedToolCallRow("r-1-1", "bash", "exit_1"),
        failedToolCallRow("r-2-1", "bash", "exit_1"),
        failedToolCallRow("r-3-1", "bash", "exit_1"),
        // "web_search" x4 (even higher count — must sort ahead of bash)
        failedToolCallRow("r-4-1", "web_search", "timeout"),
        failedToolCallRow("r-5-1", "web_search", "timeout"),
        failedToolCallRow("r-6-1", "web_search", "timeout"),
        failedToolCallRow("r-7-1", "web_search", "timeout"),
    };
    defer for (rows) |r| r.deinit(allocator);

    var report = try analyze(allocator, &rows);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), report.failure_patterns.len);
    // web_search (count 4) sorts before bash (count 3).
    try std.testing.expectEqualStrings("web_search", report.failure_patterns[0].tool);
    try std.testing.expectEqual(@as(usize, 4), report.failure_patterns[0].count);
    try std.testing.expectEqualStrings("bash", report.failure_patterns[1].tool);
    try std.testing.expectEqual(@as(usize, 3), report.failure_patterns[1].count);
}

test "analyze: output is deterministic regardless of input row order (inv. 4 rebuildability)" {
    const allocator = std.testing.allocator;

    var rows_a = [_]ToolTraceDigestRow{
        failedToolCallRow("r-1-1", "bash", "exit_1"),
        failedToolCallRow("r-2-1", "web_search", "timeout"),
        failedToolCallRow("r-3-1", "bash", "exit_1"),
        failedToolCallRow("r-4-1", "web_search", "timeout"),
        failedToolCallRow("r-5-1", "bash", "exit_1"),
        failedToolCallRow("r-6-1", "web_search", "timeout"),
    };
    defer for (rows_a) |r| r.deinit(allocator);
    var report_a = try analyze(allocator, &rows_a);
    defer report_a.deinit(allocator);

    // Same rows, deliberately reordered ("shuffled") — content is otherwise
    // byte-identical to rows_a.
    var rows_b = [_]ToolTraceDigestRow{
        failedToolCallRow("r-6-1", "web_search", "timeout"),
        failedToolCallRow("r-3-1", "bash", "exit_1"),
        failedToolCallRow("r-1-1", "bash", "exit_1"),
        failedToolCallRow("r-4-1", "web_search", "timeout"),
        failedToolCallRow("r-2-1", "web_search", "timeout"),
        failedToolCallRow("r-5-1", "bash", "exit_1"),
    };
    defer for (rows_b) |r| r.deinit(allocator);
    var report_b = try analyze(allocator, &rows_b);
    defer report_b.deinit(allocator);

    try std.testing.expectEqual(report_a.failure_patterns.len, report_b.failure_patterns.len);
    for (report_a.failure_patterns, report_b.failure_patterns) |pa, pb| {
        try std.testing.expectEqualStrings(pa.tool, pb.tool);
        try std.testing.expectEqualStrings(pa.label, pb.label);
        try std.testing.expectEqual(pa.count, pb.count);
        // Evidence run_ids: byte-identical order regardless of input row
        // order — required for byte-identical rendered output (inv. 4).
        try std.testing.expectEqual(pa.evidence_run_ids.len, pb.evidence_run_ids.len);
        for (pa.evidence_run_ids, pb.evidence_run_ids) |ea, eb| {
            try std.testing.expectEqualStrings(ea, eb);
        }
    }
}

// ── analyze(): recurrence clusters (tool-sequence shingles) ─────────
//
// A shingle is an order-2 (or order-3) n-gram of consecutive tool names
// within a SINGLE run. The same threshold (MIN_PATTERN_COUNT) applies:
// a shingle seen fewer than 3 times ACROSS runs is noise.

/// Builds a row whose events are a sequence of successful tool_call
/// events for the given tool names, in order. Used to construct
/// multi-step "procedure" fixtures for recurrence-cluster mining.
fn sequenceRow(run_id: []const u8, tools: []const []const u8) ToolTraceDigestRow {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    buf.append(std.testing.allocator, '[') catch unreachable;
    for (tools, 0..) |tool, i| {
        if (i > 0) buf.append(std.testing.allocator, ',') catch unreachable;
        const piece = std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"kind\":\"tool_call\",\"tool\":\"{s}\",\"success\":true,\"duration_ms\":5}}",
            .{tool},
        ) catch unreachable;
        defer std.testing.allocator.free(piece);
        buf.appendSlice(std.testing.allocator, piece) catch unreachable;
    }
    buf.append(std.testing.allocator, ']') catch unreachable;
    return .{
        .run_id = std.testing.allocator.dupe(u8, run_id) catch unreachable,
        .events_json = buf.toOwnedSlice(std.testing.allocator) catch unreachable,
        .created_at_unix = 0,
    };
}

test "analyze: a 2-gram shingle seen only twice across runs produces NO recurrence cluster" {
    const allocator = std.testing.allocator;
    var rows = [_]ToolTraceDigestRow{
        sequenceRow("r-1-1", &.{ "memory_recall", "web_search" }),
        sequenceRow("r-2-1", &.{ "memory_recall", "web_search" }),
    };
    defer for (rows) |r| r.deinit(allocator);

    var report = try analyze(allocator, &rows);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), report.recurrences.len);
}

test "analyze: a 2-gram shingle seen 3x across runs DOES produce a recurrence cluster" {
    const allocator = std.testing.allocator;
    var rows = [_]ToolTraceDigestRow{
        sequenceRow("r-1-1", &.{ "memory_recall", "web_search" }),
        sequenceRow("r-2-1", &.{ "memory_recall", "web_search" }),
        sequenceRow("r-3-1", &.{ "memory_recall", "web_search" }),
    };
    defer for (rows) |r| r.deinit(allocator);

    var report = try analyze(allocator, &rows);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), report.recurrences.len);
    try std.testing.expectEqual(@as(usize, 2), report.recurrences[0].sequence.len);
    try std.testing.expectEqualStrings("memory_recall", report.recurrences[0].sequence[0]);
    try std.testing.expectEqualStrings("web_search", report.recurrences[0].sequence[1]);
    try std.testing.expectEqual(@as(usize, 3), report.recurrences[0].count);
    try std.testing.expectEqual(@as(usize, 3), report.recurrences[0].evidence_run_ids.len);
}

test "analyze: a 3-tool run yields BOTH its 2-gram and 3-gram shingles when each hits threshold" {
    const allocator = std.testing.allocator;
    var rows = [_]ToolTraceDigestRow{
        sequenceRow("r-1-1", &.{ "memory_recall", "web_search", "memory_store" }),
        sequenceRow("r-2-1", &.{ "memory_recall", "web_search", "memory_store" }),
        sequenceRow("r-3-1", &.{ "memory_recall", "web_search", "memory_store" }),
    };
    defer for (rows) |r| r.deinit(allocator);

    var report = try analyze(allocator, &rows);
    defer report.deinit(allocator);

    // Expect 2 clusters: the 3-gram [memory_recall, web_search, memory_store]
    // AND the 2-gram [memory_recall, web_search] AND [web_search, memory_store]
    // — three total possible shingles, all at count 3.
    try std.testing.expectEqual(@as(usize, 3), report.recurrences.len);

    var found_3gram = false;
    var found_2gram_a = false;
    var found_2gram_b = false;
    for (report.recurrences) |rc| {
        if (rc.sequence.len == 3) {
            try std.testing.expectEqualStrings("memory_recall", rc.sequence[0]);
            try std.testing.expectEqualStrings("web_search", rc.sequence[1]);
            try std.testing.expectEqualStrings("memory_store", rc.sequence[2]);
            found_3gram = true;
        } else if (rc.sequence.len == 2) {
            if (std.mem.eql(u8, rc.sequence[0], "memory_recall")) {
                try std.testing.expectEqualStrings("web_search", rc.sequence[1]);
                found_2gram_a = true;
            } else if (std.mem.eql(u8, rc.sequence[0], "web_search")) {
                try std.testing.expectEqualStrings("memory_store", rc.sequence[1]);
                found_2gram_b = true;
            }
        }
    }
    try std.testing.expect(found_3gram);
    try std.testing.expect(found_2gram_a);
    try std.testing.expect(found_2gram_b);
}

test "analyze: recurrence clusters within a single run do not double-count non-adjacent repeats oddly (basic sanity)" {
    // A run using the SAME tool 3 times in a row: [bash, bash, bash].
    // The 2-gram [bash, bash] appears twice WITHIN this one run. Across
    // 2 such runs that's 4 occurrences of the [bash, bash] shingle —
    // above threshold from just 2 runs.
    const allocator = std.testing.allocator;
    var rows = [_]ToolTraceDigestRow{
        sequenceRow("r-1-1", &.{ "bash", "bash", "bash" }),
        sequenceRow("r-2-1", &.{ "bash", "bash", "bash" }),
    };
    defer for (rows) |r| r.deinit(allocator);

    var report = try analyze(allocator, &rows);
    defer report.deinit(allocator);

    var found = false;
    for (report.recurrences) |rc| {
        if (rc.sequence.len == 2) {
            try std.testing.expectEqualStrings("bash", rc.sequence[0]);
            try std.testing.expectEqualStrings("bash", rc.sequence[1]);
            try std.testing.expectEqual(@as(usize, 4), rc.count);
            found = true;
        }
    }
    try std.testing.expect(found);
}

// ── analyze(): tool fluency stats ────────────────────────────────────

/// Builds a row with one tool_call event carrying explicit
/// success/duration fields, for ToolStat fixture construction.
fn statRow(run_id: []const u8, tool: []const u8, success: bool, duration_ms: u64) ToolTraceDigestRow {
    const events_json = std.fmt.allocPrint(
        std.testing.allocator,
        "[{{\"kind\":\"tool_call\",\"tool\":\"{s}\",\"success\":{s},\"duration_ms\":{d}}}]",
        .{ tool, if (success) "true" else "false", duration_ms },
    ) catch unreachable;
    return .{
        .run_id = std.testing.allocator.dupe(u8, run_id) catch unreachable,
        .events_json = events_json,
        .created_at_unix = 0,
    };
}

test "analyze: a single tool use produces one ToolStat with uses=1, success_rate=1.0" {
    const allocator = std.testing.allocator;
    var rows = [_]ToolTraceDigestRow{
        statRow("r-1-1", "bash", true, 100),
    };
    defer for (rows) |r| r.deinit(allocator);

    var report = try analyze(allocator, &rows);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), report.tool_stats.len);
    try std.testing.expectEqualStrings("bash", report.tool_stats[0].tool);
    try std.testing.expectEqual(@as(usize, 1), report.tool_stats[0].uses);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), report.tool_stats[0].success_rate, 0.0001);
    try std.testing.expectEqual(@as(u64, 100), report.tool_stats[0].p50_duration_ms);
}

test "analyze: ToolStat success_rate reflects mixed success/failure" {
    const allocator = std.testing.allocator;
    var rows = [_]ToolTraceDigestRow{
        statRow("r-1-1", "bash", true, 10),
        statRow("r-2-1", "bash", true, 20),
        statRow("r-3-1", "bash", false, 30),
        statRow("r-4-1", "bash", false, 40),
    };
    defer for (rows) |r| r.deinit(allocator);

    var report = try analyze(allocator, &rows);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), report.tool_stats.len);
    try std.testing.expectEqual(@as(usize, 4), report.tool_stats[0].uses);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), report.tool_stats[0].success_rate, 0.0001);
}

test "analyze: ToolStat p50_duration_ms is the median across uses" {
    const allocator = std.testing.allocator;
    // Durations: 10, 20, 30, 40, 50 — median (p50) of 5 values is 30.
    var rows = [_]ToolTraceDigestRow{
        statRow("r-1-1", "bash", true, 50),
        statRow("r-2-1", "bash", true, 10),
        statRow("r-3-1", "bash", true, 30),
        statRow("r-4-1", "bash", true, 40),
        statRow("r-5-1", "bash", true, 20),
    };
    defer for (rows) |r| r.deinit(allocator);

    var report = try analyze(allocator, &rows);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 30), report.tool_stats[0].p50_duration_ms);
}

test "analyze: a NEGATIVE duration_ms (malformed row) is skipped, not trapped (P3 regression)" {
    const allocator = std.testing.allocator;
    // One malformed row with duration_ms=-50 among valid ones. Before
    // the fix, the naked @intCast(i64 -> u64) panicked the whole run.
    const malformed = ToolTraceDigestRow{
        .run_id = try allocator.dupe(u8, "r-2-1"),
        .events_json = try allocator.dupe(u8, "[{\"kind\":\"tool_call\",\"tool\":\"bash\",\"success\":true,\"duration_ms\":-50}]"),
        .created_at_unix = 0,
    };
    var rows = [_]ToolTraceDigestRow{
        statRow("r-1-1", "bash", true, 10),
        malformed,
        statRow("r-3-1", "bash", true, 30),
    };
    defer for (rows) |r| r.deinit(allocator);

    var report = try analyze(allocator, &rows);
    defer report.deinit(allocator);

    // The malformed call is still COUNTED (uses=3, all successes)...
    try std.testing.expectEqual(@as(u64, 3), report.tool_stats[0].uses);
    try std.testing.expectEqual(@as(f64, 1.0), report.tool_stats[0].success_rate);
    // ...but its duration is ignored: p50 over {10, 30} (index len/2
    // = 30), not over a set polluted by a clamped fake sample (which
    // would make it {0, 10, 30} -> 10).
    try std.testing.expectEqual(@as(u64, 30), report.tool_stats[0].p50_duration_ms);
}

test "analyze: ToolStat covers multiple distinct tools, sorted by uses desc then tool asc" {
    const allocator = std.testing.allocator;
    var rows = [_]ToolTraceDigestRow{
        statRow("r-1-1", "bash", true, 10),
        statRow("r-2-1", "web_search", true, 10),
        statRow("r-3-1", "web_search", true, 10),
        statRow("r-4-1", "web_search", true, 10),
    };
    defer for (rows) |r| r.deinit(allocator);

    var report = try analyze(allocator, &rows);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), report.tool_stats.len);
    try std.testing.expectEqualStrings("web_search", report.tool_stats[0].tool);
    try std.testing.expectEqual(@as(usize, 3), report.tool_stats[0].uses);
    try std.testing.expectEqualStrings("bash", report.tool_stats[1].tool);
    try std.testing.expectEqual(@as(usize, 1), report.tool_stats[1].uses);
}

/// JSON-string-escape a slice, appending directly into `buf`. Mirrors
/// memory_maintain.zig's jsonEscape / learning.zig's
/// writeJsonEscapedRunId idiom (this codebase's established local
/// json-escape pattern — no shared pub helper exists to reuse across
/// these small leaf modules, matching the precedent already set by the
/// sibling escapers).
fn appendJsonEscaped(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.writer(allocator).print("\\u{x:0>4}", .{c});
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
}

/// Renders a MiningReport as a machine-readable JSON object with three
/// arrays (failure_patterns, recurrences, tool_stats), mirroring the
/// report's own field names. PURE (learning contract inv. 2): no I/O,
/// deterministic given the (already-deterministic, per analyze()'s
/// sort order) input report. Caller frees the returned slice.
pub fn renderInsightsJson(allocator: std.mem.Allocator, report: MiningReport) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"failure_patterns\":[");
    for (report.failure_patterns, 0..) |p, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"tool\":\"");
        try appendJsonEscaped(allocator, &buf, p.tool);
        try buf.appendSlice(allocator, "\",\"label\":\"");
        try appendJsonEscaped(allocator, &buf, p.label);
        try buf.writer(allocator).print("\",\"count\":{d},\"evidence_run_ids\":[", .{p.count});
        for (p.evidence_run_ids, 0..) |rid, j| {
            if (j > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '"');
            try appendJsonEscaped(allocator, &buf, rid);
            try buf.append(allocator, '"');
        }
        try buf.appendSlice(allocator, "]}");
    }
    try buf.appendSlice(allocator, "],\"recurrences\":[");
    for (report.recurrences, 0..) |rc, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"sequence\":[");
        for (rc.sequence, 0..) |tool, j| {
            if (j > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '"');
            try appendJsonEscaped(allocator, &buf, tool);
            try buf.append(allocator, '"');
        }
        try buf.writer(allocator).print("],\"count\":{d},\"evidence_run_ids\":[", .{rc.count});
        for (rc.evidence_run_ids, 0..) |rid, j| {
            if (j > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '"');
            try appendJsonEscaped(allocator, &buf, rid);
            try buf.append(allocator, '"');
        }
        try buf.appendSlice(allocator, "]}");
    }
    try buf.appendSlice(allocator, "],\"tool_stats\":[");
    for (report.tool_stats, 0..) |t, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"tool\":\"");
        try appendJsonEscaped(allocator, &buf, t.tool);
        try buf.writer(allocator).print(
            "\",\"uses\":{d},\"success_rate\":{d:.4},\"p50_duration_ms\":{d}}}",
            .{ t.uses, t.success_rate, t.p50_duration_ms },
        );
    }
    try buf.appendSlice(allocator, "]}");

    return buf.toOwnedSlice(allocator);
}

/// Renders a MiningReport as human-readable markdown with three
/// sections: "Failure patterns", "Recurring procedures", "Tool
/// fluency". Every failure pattern / recurrence cluster cites its
/// evidence run_ids inline (learning contract inv. 6 — disclosure
/// without theatre: nothing is asserted without citation). PURE
/// (inv. 2): no I/O. Caller frees the returned slice.
pub fn renderInsightsMarkdown(allocator: std.mem.Allocator, report: MiningReport, week_label: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("# Insights — {s}\n\n", .{week_label});

    try w.writeAll("## Failure patterns\n\n");
    if (report.failure_patterns.len == 0) {
        try w.writeAll("None observed this window.\n\n");
    } else {
        for (report.failure_patterns) |p| {
            if (p.label.len == 0) {
                try w.print("- `{s}` failed {d}x — evidence: ", .{ p.tool, p.count });
            } else {
                try w.print("- `{s}` failed with \"{s}\" {d}x — evidence: ", .{ p.tool, p.label, p.count });
            }
            for (p.evidence_run_ids, 0..) |rid, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s}", .{rid});
            }
            try w.writeAll("\n");
        }
        try w.writeAll("\n");
    }

    try w.writeAll("## Recurring procedures\n\n");
    if (report.recurrences.len == 0) {
        try w.writeAll("None observed this window.\n\n");
    } else {
        for (report.recurrences) |rc| {
            try w.writeAll("- ");
            for (rc.sequence, 0..) |tool, i| {
                if (i > 0) try w.writeAll(" -> ");
                try w.print("`{s}`", .{tool});
            }
            try w.print(" — seen {d}x — evidence: ", .{rc.count});
            for (rc.evidence_run_ids, 0..) |rid, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s}", .{rid});
            }
            try w.writeAll("\n");
        }
        try w.writeAll("\n");
    }

    try w.writeAll("## Tool fluency\n\n");
    if (report.tool_stats.len == 0) {
        try w.writeAll("None observed this window.\n\n");
    } else {
        for (report.tool_stats) |t| {
            try w.print(
                "- `{s}`: {d} uses, {d:.0}% success, p50 {d}ms\n",
                .{ t.tool, t.uses, t.success_rate * 100.0, t.p50_duration_ms },
            );
        }
        try w.writeAll("\n");
    }

    return buf.toOwnedSlice(allocator);
}

// ── Renderer tests ───────────────────────────────────────────────────

/// Builds a small fixture report by hand (bypassing analyze()) so
/// renderer tests are isolated from the mining logic above.
fn fixtureReport(allocator: std.mem.Allocator) !MiningReport {
    const fp_tool = try allocator.dupe(u8, "web_search");
    const fp_label = try allocator.dupe(u8, "timeout");
    var fp_evidence = try allocator.alloc([]const u8, 2);
    fp_evidence[0] = try allocator.dupe(u8, "r-1-1");
    fp_evidence[1] = try allocator.dupe(u8, "r-2-1");
    var failure_patterns = try allocator.alloc(FailurePattern, 1);
    failure_patterns[0] = .{ .tool = fp_tool, .label = fp_label, .count = 3, .evidence_run_ids = fp_evidence };

    var rc_seq = try allocator.alloc([]const u8, 2);
    rc_seq[0] = try allocator.dupe(u8, "memory_recall");
    rc_seq[1] = try allocator.dupe(u8, "web_search");
    var rc_evidence = try allocator.alloc([]const u8, 1);
    rc_evidence[0] = try allocator.dupe(u8, "r-3-1");
    var recurrences = try allocator.alloc(RecurrenceCluster, 1);
    recurrences[0] = .{ .sequence = rc_seq, .count = 3, .evidence_run_ids = rc_evidence };

    var tool_stats = try allocator.alloc(ToolStat, 1);
    tool_stats[0] = .{ .tool = try allocator.dupe(u8, "bash"), .uses = 10, .success_rate = 0.9, .p50_duration_ms = 150 };

    return .{ .failure_patterns = failure_patterns, .recurrences = recurrences, .tool_stats = tool_stats };
}

test "renderInsightsMarkdown: includes all three section headers" {
    const allocator = std.testing.allocator;
    var report = try fixtureReport(allocator);
    defer report.deinit(allocator);

    const md = try renderInsightsMarkdown(allocator, report, "2026-W27");
    defer allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "Failure pattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Recurring procedure") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Tool fluency") != null);
}

test "renderInsightsMarkdown: cites evidence run_ids for a failure pattern" {
    const allocator = std.testing.allocator;
    var report = try fixtureReport(allocator);
    defer report.deinit(allocator);

    const md = try renderInsightsMarkdown(allocator, report, "2026-W27");
    defer allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "web_search") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "timeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "r-1-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "r-2-1") != null);
}

test "renderInsightsMarkdown: cites evidence run_ids for a recurrence cluster" {
    const allocator = std.testing.allocator;
    var report = try fixtureReport(allocator);
    defer report.deinit(allocator);

    const md = try renderInsightsMarkdown(allocator, report, "2026-W27");
    defer allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "memory_recall") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "r-3-1") != null);
}

test "renderInsightsMarkdown: includes the week label" {
    const allocator = std.testing.allocator;
    var report = try fixtureReport(allocator);
    defer report.deinit(allocator);

    const md = try renderInsightsMarkdown(allocator, report, "2026-W27");
    defer allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "2026-W27") != null);
}

test "renderInsightsMarkdown: empty report still renders section headers with no items" {
    const allocator = std.testing.allocator;
    const empty: MiningReport = .{
        .failure_patterns = try allocator.alloc(FailurePattern, 0),
        .recurrences = try allocator.alloc(RecurrenceCluster, 0),
        .tool_stats = try allocator.alloc(ToolStat, 0),
    };
    defer empty.deinit(allocator);

    const md = try renderInsightsMarkdown(allocator, empty, "2026-W27");
    defer allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "Failure pattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "None") != null or std.mem.indexOf(u8, md, "none") != null);
}

test "renderInsightsJson: produces valid JSON containing evidence run_ids" {
    const allocator = std.testing.allocator;
    var report = try fixtureReport(allocator);
    defer report.deinit(allocator);

    const json_str = try renderInsightsJson(allocator, report);
    defer allocator.free(json_str);

    // Must be parseable JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(std.mem.indexOf(u8, json_str, "web_search") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "r-1-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "memory_recall") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "bash") != null);
}

test "renderInsightsJson: same report renders byte-identical JSON twice (inv. 4 rebuildability)" {
    const allocator = std.testing.allocator;
    var report = try fixtureReport(allocator);
    defer report.deinit(allocator);

    const json_1 = try renderInsightsJson(allocator, report);
    defer allocator.free(json_1);
    const json_2 = try renderInsightsJson(allocator, report);
    defer allocator.free(json_2);

    try std.testing.expectEqualStrings(json_1, json_2);
}

test "renderInsightsMarkdown: same report renders byte-identical markdown twice (inv. 4 rebuildability)" {
    const allocator = std.testing.allocator;
    var report = try fixtureReport(allocator);
    defer report.deinit(allocator);

    const md_1 = try renderInsightsMarkdown(allocator, report, "2026-W27");
    defer allocator.free(md_1);
    const md_2 = try renderInsightsMarkdown(allocator, report, "2026-W27");
    defer allocator.free(md_2);

    try std.testing.expectEqualStrings(md_1, md_2);
}

// ── isoWeekLabel(): ISO-8601 week label for insight filenames ───────
//
// Reference values cross-checked against Python's datetime.isocalendar()
// (the standard-library reference ISO-week implementation), not
// hand-derived — see task-3-report.md for the exact commands run.

test "isoWeekLabel: 2026-07-07 (noon UTC) is ISO week 2026-W28" {
    // python3: datetime.date(2026,7,7).isocalendar() == (2026, 28, 2)
    const label = isoWeekLabel(1783425600);
    try std.testing.expectEqualStrings("2026-W28", &label);
}

test "isoWeekLabel: 2026-01-01 (noon UTC) is ISO week 2026-W01" {
    // python3: datetime.date(2026,1,1).isocalendar() == (2026, 1, 4)
    const label = isoWeekLabel(1767268800);
    try std.testing.expectEqualStrings("2026-W01", &label);
}

test "isoWeekLabel: year-boundary edge case — 2025-12-31 belongs to ISO week 2026-W01" {
    // python3: datetime.date(2025,12,31).isocalendar() == (2026, 1, 3)
    // Dec 31 2025 is a Wednesday; ISO 8601 assigns it to the FOLLOWING
    // year's week 1 because that week's Thursday falls in 2026.
    const label = isoWeekLabel(1767182400);
    try std.testing.expectEqualStrings("2026-W01", &label);
}

test "isoWeekLabel: 2026-12-31 (noon UTC) is ISO week 2026-W53 (53-week year)" {
    // python3: datetime.date(2026,12,31).isocalendar() == (2026, 53, 4)
    const label = isoWeekLabel(1798718400);
    try std.testing.expectEqualStrings("2026-W53", &label);
}
