//! Bounded in-process store for recent agent run events (WP4.1).
//!
//! Sits behind the existing Observer plumbing: events with a populated
//! `run_id` are grouped by that id and recorded as small, sanitized
//! summaries. No provider API details, no raw tool arguments, no full
//! tool output payloads — only the same public run-event fields that
//! `RunEventObserver` already exposes to online clients, capped to a
//! safe preview length.
//!
//! Memory is bounded by two caps:
//!   * `max_runs`           — maximum distinct runs retained at once
//!   * `max_events_per_run` — maximum events retained per run
//!
//! When `max_runs` is exceeded the run with the oldest first-event
//! timestamp is evicted (deterministic, not LRU-by-read). Within a
//! single run, when the per-run cap is hit, the oldest event is
//! dropped (simple FIFO). All string fields are owned by the store
//! and freed on eviction / deinit.

const std = @import("std");
const observability = @import("observability.zig");
const ObserverEvent = observability.ObserverEvent;
const Observer = observability.Observer;

/// Maximum length of any retained preview/label field. Keeps per-event
/// memory predictable even when a provider emits a very long message.
pub const MAX_FIELD_LEN: usize = 256;

/// Default caps — mirror the memory budget called out in the WP4.1
/// plan. Exposed so tests can construct stores with tighter bounds.
pub const DEFAULT_MAX_RUNS: usize = 64;
pub const DEFAULT_MAX_EVENTS_PER_RUN: usize = 256;

pub const TraceEventKind = enum {
    llm_request,
    llm_response,
    tool_call_start,
    tool_call,
    turn_stage,
    task_update,
    approval_required,
    agent_end,
    memory_retrieval,

    pub fn toSlice(self: TraceEventKind) []const u8 {
        return switch (self) {
            .llm_request => "llm_request",
            .llm_response => "llm_response",
            .tool_call_start => "tool_call_start",
            .tool_call => "tool_call",
            .turn_stage => "turn_stage",
            .task_update => "task_update",
            .approval_required => "approval_required",
            .agent_end => "agent_end",
            .memory_retrieval => "memory_retrieval",
        };
    }
};

/// One sanitized event belonging to a run. All `[]u8` fields are owned
/// by the parent `RunTraceStore` allocator and must be freed via
/// `deinit` when the event itself is destroyed.
pub const TraceEvent = struct {
    kind: TraceEventKind,
    ts_ms: i64,

    // Optional structured fields — each one is either null or a fully
    // owned duped slice. Only the subset meaningful for the event kind
    // is populated.
    tool: ?[]u8 = null,
    tool_use_id: ?[]u8 = null,
    phase: ?[]u8 = null,
    label: ?[]u8 = null,
    risk_level: ?[]u8 = null,
    status: ?[]u8 = null,
    task_id: ?[]u8 = null,

    success: ?bool = null,
    duration_ms: ?u64 = null,
    iteration: ?u32 = null,
    exit_code: ?i32 = null,
    usage_tokens: ?u64 = null,

    fn deinit(self: *TraceEvent, allocator: std.mem.Allocator) void {
        if (self.tool) |v| allocator.free(v);
        if (self.tool_use_id) |v| allocator.free(v);
        if (self.phase) |v| allocator.free(v);
        if (self.label) |v| allocator.free(v);
        if (self.risk_level) |v| allocator.free(v);
        if (self.status) |v| allocator.free(v);
        if (self.task_id) |v| allocator.free(v);
        self.* = undefined;
    }
};

/// A single run's trace — an ordered window of recent events plus the
/// bookend timestamps used for eviction ordering.
const RunBucket = struct {
    run_id: []u8, // owned
    events: std.ArrayListUnmanaged(TraceEvent) = .empty,
    first_event_ms: i64,
    last_event_ms: i64,

    fn deinit(self: *RunBucket, allocator: std.mem.Allocator) void {
        for (self.events.items) |*evt| evt.deinit(allocator);
        self.events.deinit(allocator);
        allocator.free(self.run_id);
        self.* = undefined;
    }
};

/// Snapshot payload returned to readers. `events` is a freshly-owned
/// copy — callers may read it freely after the store continues to
/// mutate, and must free it via `deinit`.
pub const TraceSnapshot = struct {
    run_id: []u8, // owned copy
    events: []TraceEvent, // each entry owned, in chronological order
    first_event_ms: i64,
    last_event_ms: i64,
    truncated: bool,
    _allocator: std.mem.Allocator,

    pub fn deinit(self: *TraceSnapshot) void {
        for (self.events) |*evt| evt.deinit(self._allocator);
        self._allocator.free(self.events);
        self._allocator.free(self.run_id);
        self.* = undefined;
    }
};

/// Lightweight index entry for list endpoints. All strings are owned
/// copies; release via `deinit`.
pub const RunIndexEntry = struct {
    run_id: []u8,
    event_count: usize,
    first_event_ms: i64,
    last_event_ms: i64,
    truncated: bool,
};

pub const RunIndex = struct {
    entries: []RunIndexEntry,
    _allocator: std.mem.Allocator,

    pub fn deinit(self: *RunIndex) void {
        for (self.entries) |*e| self._allocator.free(e.run_id);
        self._allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const RunTraceStore = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    runs: std.StringArrayHashMapUnmanaged(*RunBucket),
    max_runs: usize,
    max_events_per_run: usize,
    truncated_runs: std.StringArrayHashMapUnmanaged(void),

    /// Task 2 (Loop-2 prerequisite) — optional durable-flush sink.
    ///
    /// All three default to null, which reproduces the exact prior
    /// (in-memory-only) behavior. When all three are set, an
    /// `.agent_end` event for a run triggers exactly one best-effort
    /// call carrying that run's full sanitized event timeline as a
    /// JSON array. Errors from the sink are logged and swallowed —
    /// they must never propagate into the agent/observer path.
    flush_fn: ?*const fn (ctx: ?*anyopaque, user_id: i64, run_id: []const u8, events_json: []const u8) anyerror!void = null,
    flush_ctx: ?*anyopaque = null,
    flush_user_id: ?i64 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        max_runs: usize,
        max_events_per_run: usize,
    ) RunTraceStore {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .runs = .empty,
            .max_runs = if (max_runs == 0) 1 else max_runs,
            .max_events_per_run = if (max_events_per_run == 0) 1 else max_events_per_run,
            .truncated_runs = .empty,
        };
    }

    pub fn deinit(self: *RunTraceStore) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.runs.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.runs.deinit(self.allocator);
        // truncated_runs shares keys with runs (pointers into RunBucket.run_id),
        // which we just freed. Just drop the map.
        self.truncated_runs.deinit(self.allocator);
    }

    // ── Observer wiring ──────────────────────────────────────────────

    const vtable = Observer.VTable{
        .record_event = obsRecordEvent,
        .record_metric = obsRecordMetric,
        .flush = obsFlush,
        .name = obsName,
    };

    pub fn observer(self: *RunTraceStore) Observer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn obsRecordEvent(ptr: *anyopaque, event: *const ObserverEvent) void {
        const self: *RunTraceStore = @ptrCast(@alignCast(ptr));
        self.recordEvent(event);
    }

    fn obsRecordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn obsFlush(_: *anyopaque) void {}
    fn obsName(_: *anyopaque) []const u8 {
        return "run_trace_store";
    }

    // ── Public introspection ────────────────────────────────────────

    /// Snapshot a single run by id. Returns null if the run is not
    /// present. Caller owns the returned snapshot.
    pub fn snapshotRun(
        self: *RunTraceStore,
        allocator: std.mem.Allocator,
        run_id: []const u8,
    ) !?TraceSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const bucket_ptr = self.runs.get(run_id) orelse return null;
        return try self.copyBucket(allocator, bucket_ptr);
    }

    /// Snapshot the set of currently-stored run ids with their sizes
    /// and timestamps. Result is sorted by first_event_ms ascending so
    /// the caller sees a stable chronological listing.
    pub fn listRuns(self: *RunTraceStore, allocator: std.mem.Allocator) !RunIndex {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = self.runs.count();
        var out = try allocator.alloc(RunIndexEntry, count);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |*e| allocator.free(e.run_id);
            allocator.free(out);
        }

        var it = self.runs.iterator();
        while (it.next()) |entry| {
            const bucket = entry.value_ptr.*;
            const id_copy = try allocator.dupe(u8, bucket.run_id);
            out[filled] = .{
                .run_id = id_copy,
                .event_count = bucket.events.items.len,
                .first_event_ms = bucket.first_event_ms,
                .last_event_ms = bucket.last_event_ms,
                .truncated = self.truncated_runs.contains(bucket.run_id),
            };
            filled += 1;
        }

        std.mem.sort(RunIndexEntry, out, {}, struct {
            fn lessThan(_: void, a: RunIndexEntry, b: RunIndexEntry) bool {
                return a.first_event_ms < b.first_event_ms;
            }
        }.lessThan);

        return .{ .entries = out, ._allocator = allocator };
    }

    /// Best-effort diagnostic: current number of retained runs.
    pub fn runCount(self: *RunTraceStore) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.runs.count();
    }

    // ── Internals ───────────────────────────────────────────────────

    fn recordEvent(self: *RunTraceStore, event: *const ObserverEvent) void {
        // Extract run_id first — events without one are ignored; we do
        // not synthesize ids here (WP4.1 constraint).
        const derived = deriveTraceEvent(event) orelse return;
        const is_agent_end = derived.kind == .agent_end;
        const run_id = derived.run_id;

        self.mutex.lock();
        self.appendLocked(derived) catch |err| {
            // Best-effort: failing to append must never propagate back
            // into the agent path. Drop silently; the caller cannot
            // observe this via the Observer vtable.
            std.log.scoped(.run_trace_store).debug("append failed: {}", .{err});
        };

        // Task 2 (Loop-2 prerequisite): on agent_end, snapshot this
        // run's buffered events under the mutex we already hold, then
        // release the lock BEFORE serializing/flushing — JSON encoding
        // and the sink call must never happen while holding the lock.
        var flush_snapshot: ?TraceSnapshot = null;
        if (is_agent_end and self.flush_fn != null) {
            const bucket = self.runs.get(run_id);
            if (bucket) |b| {
                flush_snapshot = self.copyBucket(self.allocator, b) catch |err| blk: {
                    std.log.scoped(.run_trace_store).warn("flush snapshot failed run_id='{s}' err={}", .{ run_id, err });
                    break :blk null;
                };
            }
        }
        self.mutex.unlock();

        if (flush_snapshot) |*snap| {
            defer snap.deinit();
            self.tryFlush(snap);
        }
    }

    /// Best-effort durable flush — invoked with the store's mutex
    /// already released. Serializes the given snapshot to the same
    /// sanitized JSON schema `trace_query` exposes and hands it to the
    /// injected sink. Any failure (serialization OOM or sink error) is
    /// logged and swallowed; it must never propagate into the agent
    /// path or the Observer vtable.
    fn tryFlush(self: *RunTraceStore, snap: *const TraceSnapshot) void {
        const flush_fn = self.flush_fn orelse return;
        const user_id = self.flush_user_id orelse return;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        serializeEventsJsonArray(self.allocator, &buf, snap.events) catch |err| {
            std.log.scoped(.run_trace_store).warn(
                "flush serialize failed run_id='{s}' err={}",
                .{ snap.run_id, err },
            );
            return;
        };

        flush_fn(self.flush_ctx, user_id, snap.run_id, buf.items) catch |err| {
            std.log.scoped(.run_trace_store).warn(
                "flush sink failed run_id='{s}' err={}",
                .{ snap.run_id, err },
            );
        };
    }

    fn appendLocked(self: *RunTraceStore, d: DerivedEvent) !void {
        const gop = try self.runs.getOrPut(self.allocator, d.run_id);
        if (!gop.found_existing) {
            errdefer _ = self.runs.orderedRemove(d.run_id);
            const bucket = try self.allocator.create(RunBucket);
            errdefer self.allocator.destroy(bucket);
            const run_id_copy = try self.allocator.dupe(u8, d.run_id);
            errdefer self.allocator.free(run_id_copy);
            bucket.* = .{
                .run_id = run_id_copy,
                .first_event_ms = d.ts_ms,
                .last_event_ms = d.ts_ms,
            };
            gop.key_ptr.* = run_id_copy;
            gop.value_ptr.* = bucket;

            if (self.runs.count() > self.max_runs) {
                self.evictOldestRun();
            }
        }

        const bucket = self.runs.get(d.run_id).?;
        const trace_event = try self.buildTraceEvent(d);
        errdefer {
            var evt_mut = trace_event;
            evt_mut.deinit(self.allocator);
        }

        if (bucket.events.items.len >= self.max_events_per_run) {
            var dropped = bucket.events.orderedRemove(0);
            dropped.deinit(self.allocator);
            _ = try self.truncated_runs.getOrPut(self.allocator, bucket.run_id);
        }

        try bucket.events.append(self.allocator, trace_event);
        bucket.last_event_ms = d.ts_ms;
    }

    fn evictOldestRun(self: *RunTraceStore) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_ts: i64 = std.math.maxInt(i64);
        var it = self.runs.iterator();
        while (it.next()) |entry| {
            const ts = entry.value_ptr.*.first_event_ms;
            if (ts < oldest_ts) {
                oldest_ts = ts;
                oldest_key = entry.key_ptr.*;
            }
        }
        const key = oldest_key orelse return;
        if (self.runs.fetchOrderedRemove(key)) |kv| {
            _ = self.truncated_runs.orderedRemove(kv.value.run_id);
            kv.value.deinit(self.allocator);
            self.allocator.destroy(kv.value);
        }
    }

    fn buildTraceEvent(self: *RunTraceStore, d: DerivedEvent) !TraceEvent {
        var evt = TraceEvent{ .kind = d.kind, .ts_ms = d.ts_ms };
        errdefer evt.deinit(self.allocator);

        if (d.tool) |v| evt.tool = try dupeClamped(self.allocator, v);
        if (d.tool_use_id) |v| evt.tool_use_id = try dupeClamped(self.allocator, v);
        if (d.phase) |v| evt.phase = try dupeClamped(self.allocator, v);
        if (d.label) |v| evt.label = try dupeClamped(self.allocator, v);
        if (d.risk_level) |v| evt.risk_level = try dupeClamped(self.allocator, v);
        if (d.status) |v| evt.status = try dupeClamped(self.allocator, v);
        if (d.task_id) |v| evt.task_id = try dupeClamped(self.allocator, v);

        evt.success = d.success;
        evt.duration_ms = d.duration_ms;
        evt.iteration = d.iteration;
        evt.exit_code = d.exit_code;
        evt.usage_tokens = d.usage_tokens;
        return evt;
    }

    fn copyBucket(
        self: *RunTraceStore,
        allocator: std.mem.Allocator,
        bucket: *RunBucket,
    ) !TraceSnapshot {
        const count = bucket.events.items.len;
        const events_copy = try allocator.alloc(TraceEvent, count);
        var filled: usize = 0;
        errdefer {
            for (events_copy[0..filled]) |*e| e.deinit(allocator);
            allocator.free(events_copy);
        }

        for (bucket.events.items, 0..) |src, i| {
            events_copy[i] = .{
                .kind = src.kind,
                .ts_ms = src.ts_ms,
                .success = src.success,
                .duration_ms = src.duration_ms,
                .iteration = src.iteration,
                .exit_code = src.exit_code,
                .usage_tokens = src.usage_tokens,
            };
            if (src.tool) |v| events_copy[i].tool = try allocator.dupe(u8, v);
            if (src.tool_use_id) |v| events_copy[i].tool_use_id = try allocator.dupe(u8, v);
            if (src.phase) |v| events_copy[i].phase = try allocator.dupe(u8, v);
            if (src.label) |v| events_copy[i].label = try allocator.dupe(u8, v);
            if (src.risk_level) |v| events_copy[i].risk_level = try allocator.dupe(u8, v);
            if (src.status) |v| events_copy[i].status = try allocator.dupe(u8, v);
            if (src.task_id) |v| events_copy[i].task_id = try allocator.dupe(u8, v);
            filled = i + 1;
        }

        const id_copy = try allocator.dupe(u8, bucket.run_id);
        errdefer allocator.free(id_copy);
        return .{
            .run_id = id_copy,
            .events = events_copy,
            .first_event_ms = bucket.first_event_ms,
            .last_event_ms = bucket.last_event_ms,
            .truncated = self.truncated_runs.contains(bucket.run_id),
            ._allocator = allocator,
        };
    }
};

fn dupeClamped(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const take = @min(input.len, MAX_FIELD_LEN);
    return allocator.dupe(u8, input[0..take]);
}

// ── Shared sanitized-event JSON serialization ────────────────────────
//
// Single source of truth for the sanitized event JSON shape. Both the
// `trace_query` agent tool and the Task 2 durable-flush sink must emit
// the SAME fields (kind, tool, phase, label, status, success,
// duration_ms, iteration, exit_code, usage_tokens, ts_ms) so a
// persisted run's digest matches exactly what the agent/FE trace
// browser already see. Do not fork this schema.

/// Serialize one trace event as a JSON object. Exposed so callers
/// outside this file (currently `tools/trace_query.zig`) can reuse the
/// exact same field set rather than maintaining a parallel writer.
pub fn serializeTraceEventJson(w: anytype, evt: *const TraceEvent) !void {
    try w.writeAll("{\"kind\":\"");
    try jsonEscapeInto(w, evt.kind.toSlice());
    try w.print("\",\"ts_ms\":{d}", .{evt.ts_ms});
    if (evt.phase) |v| {
        try w.writeAll(",\"phase\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.tool) |v| {
        try w.writeAll(",\"tool\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.tool_use_id) |v| {
        try w.writeAll(",\"tool_use_id\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.label) |v| {
        try w.writeAll(",\"label\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.risk_level) |v| {
        try w.writeAll(",\"risk_level\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.status) |v| {
        try w.writeAll(",\"status\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.task_id) |v| {
        try w.writeAll(",\"task_id\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.success) |v| try w.print(",\"success\":{s}", .{if (v) "true" else "false"});
    if (evt.duration_ms) |v| try w.print(",\"duration_ms\":{d}", .{v});
    if (evt.iteration) |v| try w.print(",\"iteration\":{d}", .{v});
    if (evt.exit_code) |v| try w.print(",\"exit_code\":{d}", .{v});
    if (evt.usage_tokens) |v| try w.print(",\"usage_tokens\":{d}", .{v});
    try w.writeAll("}");
}

/// Serialize a full slice of events as a JSON array using the same
/// per-event writer as `serializeTraceEventJson`. Used by the Task 2
/// durable-flush path to build the `events_json` payload handed to
/// `Manager.insertToolTraceEvents`.
pub fn serializeEventsJsonArray(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    events: []const TraceEvent,
) !void {
    const w = buf.writer(allocator);
    try w.writeAll("[");
    for (events, 0..) |*evt, i| {
        if (i > 0) try w.writeAll(",");
        try serializeTraceEventJson(w, evt);
    }
    try w.writeAll("]");
}

pub fn jsonEscapeInto(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// ── Internal translation layer ──────────────────────────────────────

/// Sanitized, borrowing view of an event about to be stored. All
/// string fields reference the source event — the store copies them
/// before releasing the caller's lifetime.
const DerivedEvent = struct {
    kind: TraceEventKind,
    run_id: []const u8,
    ts_ms: i64,

    tool: ?[]const u8 = null,
    tool_use_id: ?[]const u8 = null,
    phase: ?[]const u8 = null,
    label: ?[]const u8 = null,
    risk_level: ?[]const u8 = null,
    status: ?[]const u8 = null,
    task_id: ?[]const u8 = null,

    success: ?bool = null,
    duration_ms: ?u64 = null,
    iteration: ?u32 = null,
    exit_code: ?i32 = null,
    usage_tokens: ?u64 = null,
};

fn deriveTraceEvent(event: *const ObserverEvent) ?DerivedEvent {
    const ts_ms = std.time.milliTimestamp();
    return switch (event.*) {
        .llm_request => |e| blk: {
            const rid = e.run_id orelse break :blk null;
            break :blk .{
                .kind = .llm_request,
                .run_id = rid,
                .ts_ms = ts_ms,
            };
        },
        .llm_response => |e| blk: {
            const rid = e.run_id orelse break :blk null;
            break :blk .{
                .kind = .llm_response,
                .run_id = rid,
                .ts_ms = ts_ms,
                .duration_ms = e.duration_ms,
                .success = e.success,
            };
        },
        .tool_call_start => |e| blk: {
            const rid = e.run_id orelse break :blk null;
            break :blk .{
                .kind = .tool_call_start,
                .run_id = rid,
                .ts_ms = ts_ms,
                .tool = e.tool,
                .tool_use_id = e.tool_use_id,
                .label = e.activity_label,
            };
        },
        .tool_call => |e| blk: {
            const rid = e.run_id orelse break :blk null;
            break :blk .{
                .kind = .tool_call,
                .run_id = rid,
                .ts_ms = ts_ms,
                .tool = e.tool,
                .tool_use_id = e.tool_use_id,
                .label = e.result_summary,
                .success = e.success,
                .duration_ms = e.duration_ms,
                .exit_code = e.exit_code,
            };
        },
        .turn_stage => |e| blk: {
            const rid = e.run_id orelse break :blk null;
            break :blk .{
                .kind = .turn_stage,
                .run_id = rid,
                .ts_ms = ts_ms,
                .phase = e.stage,
                .iteration = e.iteration,
                .duration_ms = e.duration_ms,
                .tool_use_id = e.tool_use_id,
                .task_id = e.task_id,
            };
        },
        .task_update => |e| blk: {
            const rid = e.run_id orelse break :blk null;
            break :blk .{
                .kind = .task_update,
                .run_id = rid,
                .ts_ms = ts_ms,
                .task_id = e.task_id,
                .status = e.status,
                .label = e.description,
            };
        },
        .approval_required => |e| blk: {
            const rid = e.run_id orelse break :blk null;
            break :blk .{
                .kind = .approval_required,
                .run_id = rid,
                .ts_ms = ts_ms,
                .tool = e.tool,
                .label = e.reason,
                .risk_level = e.risk_level,
            };
        },
        .agent_end => |e| blk: {
            const rid = e.run_id orelse break :blk null;
            break :blk .{
                .kind = .agent_end,
                .run_id = rid,
                .ts_ms = ts_ms,
                .duration_ms = e.duration_ms,
                .usage_tokens = e.tokens_used,
            };
        },
        .memory_retrieval => |e| blk: {
            const rid = e.run_id orelse break :blk null;
            break :blk .{
                .kind = .memory_retrieval,
                .run_id = rid,
                .ts_ms = ts_ms,
                .status = e.status,
                .label = "memory_retrieval",
                .success = e.success,
                .usage_tokens = e.usage_tokens,
                .iteration = e.iteration,
                .duration_ms = e.duration_ms,
            };
        },
        else => null,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "RunTraceStore.recordEvent ignores events without run_id" {
    const allocator = std.testing.allocator;
    var store = RunTraceStore.init(allocator, 4, 8);
    defer store.deinit();

    const evt = ObserverEvent{ .tool_call_start = .{ .tool = "bash" } };
    const obs = store.observer();
    obs.recordEvent(&evt);

    try std.testing.expectEqual(@as(usize, 0), store.runCount());
}

test "RunTraceStore groups events by run_id" {
    const allocator = std.testing.allocator;
    var store = RunTraceStore.init(allocator, 4, 8);
    defer store.deinit();

    const obs = store.observer();
    const e1 = ObserverEvent{ .tool_call_start = .{ .tool = "bash", .run_id = "r-1" } };
    const e2 = ObserverEvent{ .tool_call = .{ .tool = "bash", .success = true, .duration_ms = 5, .run_id = "r-1" } };
    const e3 = ObserverEvent{ .tool_call_start = .{ .tool = "file_read", .run_id = "r-2" } };
    obs.recordEvent(&e1);
    obs.recordEvent(&e2);
    obs.recordEvent(&e3);

    try std.testing.expectEqual(@as(usize, 2), store.runCount());

    var snap = (try store.snapshotRun(allocator, "r-1")).?;
    defer snap.deinit();
    try std.testing.expectEqualStrings("r-1", snap.run_id);
    try std.testing.expectEqual(@as(usize, 2), snap.events.len);
    try std.testing.expectEqual(TraceEventKind.tool_call_start, snap.events[0].kind);
    try std.testing.expectEqual(TraceEventKind.tool_call, snap.events[1].kind);
    try std.testing.expectEqualStrings("bash", snap.events[0].tool.?);
    try std.testing.expect(snap.events[1].success.? == true);
    try std.testing.expectEqual(@as(u64, 5), snap.events[1].duration_ms.?);
    try std.testing.expect(!snap.truncated);
}

test "RunTraceStore snapshotRun returns null for missing run" {
    const allocator = std.testing.allocator;
    var store = RunTraceStore.init(allocator, 4, 8);
    defer store.deinit();

    const snap = try store.snapshotRun(allocator, "does-not-exist");
    try std.testing.expect(snap == null);
}

test "RunTraceStore per-run cap evicts oldest events and marks truncated" {
    const allocator = std.testing.allocator;
    var store = RunTraceStore.init(allocator, 4, 3);
    defer store.deinit();

    const obs = store.observer();
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const evt = ObserverEvent{ .turn_stage = .{
            .stage = "dispatch_tools",
            .iteration = i,
            .run_id = "r-cap",
        } };
        obs.recordEvent(&evt);
    }

    var snap = (try store.snapshotRun(allocator, "r-cap")).?;
    defer snap.deinit();
    try std.testing.expectEqual(@as(usize, 3), snap.events.len);
    // Oldest iterations (0,1) were dropped; we kept 2,3,4.
    try std.testing.expectEqual(@as(u32, 2), snap.events[0].iteration.?);
    try std.testing.expectEqual(@as(u32, 4), snap.events[2].iteration.?);
    try std.testing.expect(snap.truncated);
}

test "RunTraceStore global cap evicts oldest run deterministically" {
    const allocator = std.testing.allocator;
    var store = RunTraceStore.init(allocator, 2, 4);
    defer store.deinit();

    const obs = store.observer();
    // Ensure distinct first-event timestamps across runs — milliTimestamp
    // granularity is coarse, so stamp through turn_stage emissions in
    // sequence and sleep a hair between new runs.
    const r1 = ObserverEvent{ .turn_stage = .{ .stage = "turn_start", .run_id = "r-old" } };
    obs.recordEvent(&r1);
    std.Thread.sleep(2 * std.time.ns_per_ms);
    const r2 = ObserverEvent{ .turn_stage = .{ .stage = "turn_start", .run_id = "r-mid" } };
    obs.recordEvent(&r2);
    std.Thread.sleep(2 * std.time.ns_per_ms);
    const r3 = ObserverEvent{ .turn_stage = .{ .stage = "turn_start", .run_id = "r-new" } };
    obs.recordEvent(&r3);

    try std.testing.expectEqual(@as(usize, 2), store.runCount());
    const removed = try store.snapshotRun(allocator, "r-old");
    try std.testing.expect(removed == null);
    var kept_mid = (try store.snapshotRun(allocator, "r-mid")).?;
    defer kept_mid.deinit();
    var kept_new = (try store.snapshotRun(allocator, "r-new")).?;
    defer kept_new.deinit();
}

test "RunTraceStore listRuns returns chronological index" {
    const allocator = std.testing.allocator;
    var store = RunTraceStore.init(allocator, 8, 8);
    defer store.deinit();

    const obs = store.observer();
    const a = ObserverEvent{ .turn_stage = .{ .stage = "turn_start", .run_id = "a" } };
    obs.recordEvent(&a);
    std.Thread.sleep(2 * std.time.ns_per_ms);
    const b = ObserverEvent{ .turn_stage = .{ .stage = "turn_start", .run_id = "b" } };
    obs.recordEvent(&b);

    var index = try store.listRuns(allocator);
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 2), index.entries.len);
    try std.testing.expectEqualStrings("a", index.entries[0].run_id);
    try std.testing.expectEqualStrings("b", index.entries[1].run_id);
    try std.testing.expect(index.entries[0].first_event_ms <= index.entries[1].first_event_ms);
}

test "RunTraceStore clamps long label fields to MAX_FIELD_LEN" {
    const allocator = std.testing.allocator;
    var store = RunTraceStore.init(allocator, 2, 4);
    defer store.deinit();

    const long_label = "x" ** (MAX_FIELD_LEN + 50);
    const evt = ObserverEvent{ .approval_required = .{
        .tool = "bash",
        .reason = long_label,
        .risk_level = "high",
        .run_id = "r-long",
    } };
    store.observer().recordEvent(&evt);

    var snap = (try store.snapshotRun(allocator, "r-long")).?;
    defer snap.deinit();
    try std.testing.expectEqual(@as(usize, 1), snap.events.len);
    try std.testing.expectEqual(@as(usize, MAX_FIELD_LEN), snap.events[0].label.?.len);
}

test "RunTraceStore deinit frees all retained runs without leaks" {
    const allocator = std.testing.allocator;
    var store = RunTraceStore.init(allocator, 8, 8);

    const obs = store.observer();
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "run-{d}", .{i}) catch unreachable;
        const evt = ObserverEvent{ .tool_call_start = .{
            .tool = "bash",
            .run_id = id,
        } };
        obs.recordEvent(&evt);
        const evt2 = ObserverEvent{ .tool_call = .{
            .tool = "bash",
            .success = true,
            .duration_ms = 1,
            .run_id = id,
        } };
        obs.recordEvent(&evt2);
    }
    store.deinit();
}

test "memory_retrieval kind serializes to correct slice" {
    const kind = TraceEventKind.memory_retrieval;
    try std.testing.expectEqualStrings("memory_retrieval", kind.toSlice());
}

test "RunTraceStore snapshot outlives subsequent mutations" {
    const allocator = std.testing.allocator;
    var store = RunTraceStore.init(allocator, 2, 4);
    defer store.deinit();

    const obs = store.observer();
    const first = ObserverEvent{ .tool_call_start = .{
        .tool = "keep-me",
        .run_id = "r-keep",
    } };
    obs.recordEvent(&first);

    var snap = (try store.snapshotRun(allocator, "r-keep")).?;
    defer snap.deinit();

    // Drive many subsequent events to force eviction churn.
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "n-{d}", .{i}) catch unreachable;
        const evt = ObserverEvent{ .tool_call_start = .{
            .tool = "noise",
            .run_id = id,
        } };
        obs.recordEvent(&evt);
    }

    try std.testing.expectEqual(@as(usize, 1), snap.events.len);
    try std.testing.expectEqualStrings("keep-me", snap.events[0].tool.?);
}

// ── Durable flush on agent_end (Task 2, Loop-2 prerequisite) ────────

const FlushCall = struct {
    user_id: i64,
    run_id: []u8,
    events_json: []u8,
};

/// Recording fake sink — captures every invocation so tests can assert
/// on call count, user_id, run_id, and serialized payload contents.
const FakeFlushSink = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayListUnmanaged(FlushCall) = .empty,
    fail: bool = false,

    fn deinit(self: *FakeFlushSink) void {
        for (self.calls.items) |c| {
            self.allocator.free(c.run_id);
            self.allocator.free(c.events_json);
        }
        self.calls.deinit(self.allocator);
    }

    fn flush(ctx: ?*anyopaque, user_id: i64, run_id: []const u8, events_json: []const u8) anyerror!void {
        const self: *FakeFlushSink = @ptrCast(@alignCast(ctx.?));
        if (self.fail) return error.Boom;
        try self.calls.append(self.allocator, .{
            .user_id = user_id,
            .run_id = try self.allocator.dupe(u8, run_id),
            .events_json = try self.allocator.dupe(u8, events_json),
        });
    }
};

test "durable flush: agent_end triggers exactly one flush call with both tool events" {
    const allocator = std.testing.allocator;
    var store = RunTraceStore.init(allocator, 4, 8);
    defer store.deinit();

    var sink = FakeFlushSink{ .allocator = allocator };
    defer sink.deinit();
    store.flush_fn = FakeFlushSink.flush;
    store.flush_ctx = &sink;
    store.flush_user_id = 99;

    const obs = store.observer();
    const e1 = ObserverEvent{ .tool_call_start = .{ .tool = "bash", .run_id = "r1" } };
    const e2 = ObserverEvent{ .tool_call = .{ .tool = "file_read", .success = true, .duration_ms = 5, .run_id = "r1" } };
    const e3 = ObserverEvent{ .agent_end = .{ .duration_ms = 100, .tokens_used = 50, .run_id = "r1" } };
    obs.recordEvent(&e1);
    obs.recordEvent(&e2);
    obs.recordEvent(&e3);

    // In-memory behavior is untouched: all 3 events still retained.
    var snap = (try store.snapshotRun(allocator, "r1")).?;
    defer snap.deinit();
    try std.testing.expectEqual(@as(usize, 3), snap.events.len);

    // Flush happened exactly once, on the agent_end event.
    try std.testing.expectEqual(@as(usize, 1), sink.calls.items.len);
    const call = sink.calls.items[0];
    try std.testing.expectEqual(@as(i64, 99), call.user_id);
    try std.testing.expectEqualStrings("r1", call.run_id);
    try std.testing.expect(std.mem.indexOf(u8, call.events_json, "\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.events_json, "\"file_read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.events_json, "\"success\":true") != null);
}

test "durable flush: null sink is a no-op, prior behavior unchanged" {
    const allocator = std.testing.allocator;
    var store = RunTraceStore.init(allocator, 4, 8);
    defer store.deinit();
    // flush_fn / flush_ctx / flush_user_id all left at their default null.

    const obs = store.observer();
    const e1 = ObserverEvent{ .tool_call_start = .{ .tool = "bash", .run_id = "r-null" } };
    const e2 = ObserverEvent{ .agent_end = .{ .duration_ms = 10, .tokens_used = 1, .run_id = "r-null" } };
    obs.recordEvent(&e1);
    obs.recordEvent(&e2);

    var snap = (try store.snapshotRun(allocator, "r-null")).?;
    defer snap.deinit();
    try std.testing.expectEqual(@as(usize, 2), snap.events.len);
}

test "durable flush: sink error does not propagate and later records still work" {
    const allocator = std.testing.allocator;
    var store = RunTraceStore.init(allocator, 4, 8);
    defer store.deinit();

    var sink = FakeFlushSink{ .allocator = allocator, .fail = true };
    defer sink.deinit();
    store.flush_fn = FakeFlushSink.flush;
    store.flush_ctx = &sink;
    store.flush_user_id = 7;

    const obs = store.observer();
    const e1 = ObserverEvent{ .tool_call_start = .{ .tool = "bash", .run_id = "r-err" } };
    const e2 = ObserverEvent{ .agent_end = .{ .duration_ms = 10, .tokens_used = 1, .run_id = "r-err" } };
    obs.recordEvent(&e1);
    obs.recordEvent(&e2); // sink returns error.Boom — must not crash/propagate.

    // No successful calls were recorded (sink always failed).
    try std.testing.expectEqual(@as(usize, 0), sink.calls.items.len);

    // Store keeps working after a failed flush.
    const e3 = ObserverEvent{ .tool_call_start = .{ .tool = "bash", .run_id = "r-after" } };
    obs.recordEvent(&e3);
    var snap = (try store.snapshotRun(allocator, "r-after")).?;
    defer snap.deinit();
    try std.testing.expectEqual(@as(usize, 1), snap.events.len);
}
