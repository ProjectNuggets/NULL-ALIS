//! RunEventObserver — translates ObserverEvents into RunEvent SSE frames.
//!
//! Wraps an inner Observer, forwarding all events. For applicable events
//! (tool_call_start, tool_call, turn_stage, narration_frame, agent_end,
//! task_update), constructs a RunEvent, serializes it via toSseFrame,
//! and writes through a FrameSink.
//!
//! Security: Only translates the specified event types. llm_request/llm_response
//! are NOT forwarded to SSE to prevent leaking provider API details (T-02-03).

const std = @import("std");
const observability = @import("observability.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;
const run_event_types = @import("agent/run_event_types.zig");
const RunEvent = run_event_types.RunEvent;
const toSseFrame = run_event_types.toSseFrame;

// ── FrameSink ────────────────────────────────────────────────────────

pub const FrameSink = struct {
    ptr: *anyopaque,
    writeFn: *const fn (ptr: *anyopaque, frame: []const u8) void,

    pub fn write(self: FrameSink, frame: []const u8) void {
        self.writeFn(self.ptr, frame);
    }
};

// ── RunEventObserver ─────────────────────────────────────────────────

pub const RunEventObserver = struct {
    inner: Observer,
    sink: FrameSink,
    allocator: std.mem.Allocator,

    const vtable = Observer.VTable{
        .record_event = recordEvent,
        .record_metric = recordMetric,
        .flush = flush,
        .name = name,
    };

    pub fn observer(self: *RunEventObserver) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn recordEvent(ptr: *anyopaque, event: *const ObserverEvent) void {
        const self: *RunEventObserver = @ptrCast(@alignCast(ptr));
        // Always forward to inner observer first
        self.inner.recordEvent(event);

        // Translate applicable events to RunEvent SSE frames
        const run_event: ?RunEvent = switch (event.*) {
            .tool_call_start => |e| RunEvent{ .tool_start = .{ .tool = e.tool } },
            .tool_call => |e| RunEvent{ .tool_result = .{
                .tool = e.tool,
                .success = e.success,
                .duration_ms = e.duration_ms,
            } },
            .turn_stage => |e| RunEvent{ .progress = .{
                .phase = e.stage,
                .state = "update",
                .label = stageLabel(e.stage),
                .iteration = e.iteration,
                .duration_ms = e.duration_ms,
            } },
            .narration_frame => |e| RunEvent{ .progress = .{
                .phase = @tagName(e.frame_type),
                .state = "update",
                .label = e.message,
                .tool = e.tool_name,
            } },
            .agent_end => |e| RunEvent{ .done = .{
                .usage_tokens = e.tokens_used,
            } },
            .task_update => |e| RunEvent{ .task_update = .{
                .task_id = e.task_id,
                .status = e.status,
                .description = e.description,
            } },
            else => null,
        };

        if (run_event) |evt| {
            const frame = toSseFrame(self.allocator, evt) catch return;
            defer self.allocator.free(frame);
            self.sink.write(frame);
        }
    }

    // ── Convenience emitters ─────────────────────────────────────────

    pub fn emitReady(self: *RunEventObserver, session_key: []const u8) void {
        const frame = toSseFrame(self.allocator, RunEvent{ .ready = .{ .session_key = session_key } }) catch return;
        defer self.allocator.free(frame);
        self.sink.write(frame);
    }

    pub fn emitReplyStart(self: *RunEventObserver, stream_kind: []const u8, delivery_mode: []const u8, live: bool) void {
        const frame = toSseFrame(self.allocator, RunEvent{ .reply_start = .{
            .stream_kind = stream_kind,
            .delivery_mode = delivery_mode,
            .live = live,
        } }) catch return;
        defer self.allocator.free(frame);
        self.sink.write(frame);
    }

    pub fn emitDone(self: *RunEventObserver, session_id: ?[]const u8, message_id: ?i64) void {
        const frame = toSseFrame(self.allocator, RunEvent{ .done = .{
            .session_id = session_id,
            .message_id = message_id,
        } }) catch return;
        defer self.allocator.free(frame);
        self.sink.write(frame);
    }

    fn recordMetric(ptr: *anyopaque, metric: *const observability.ObserverMetric) void {
        const self: *RunEventObserver = @ptrCast(@alignCast(ptr));
        self.inner.recordMetric(metric);
    }

    fn flush(ptr: *anyopaque) void {
        const self: *RunEventObserver = @ptrCast(@alignCast(ptr));
        self.inner.flush();
    }

    fn name(_: *anyopaque) []const u8 {
        return "run_events";
    }
};

// ── Stage label mapping ──────────────────────────────────────────────

fn stageLabel(stage: []const u8) []const u8 {
    if (std.mem.eql(u8, stage, "turn_start")) return "Gathering context";
    if (std.mem.eql(u8, stage, "memory_enrich")) return "Retrieving memory";
    if (std.mem.eql(u8, stage, "turn_compaction") or
        std.mem.eql(u8, stage, "compact_trim")) return "Trimming context";
    if (std.mem.eql(u8, stage, "continuity_refresh")) return "Refreshing continuity";
    if (std.mem.eql(u8, stage, "build_provider_messages")) return "Preparing request";
    if (std.mem.eql(u8, stage, "dispatch_tools")) return "Running tools";
    if (std.mem.eql(u8, stage, "tool_reflection")) return "Reflecting on results";
    if (std.mem.eql(u8, stage, "compose_final_reply")) return "Preparing reply";
    if (std.mem.eql(u8, stage, "finalize_no_tools")) return "Finalizing reply";
    if (std.mem.eql(u8, stage, "llm_first_token")) return "Model responding";
    if (std.mem.eql(u8, stage, "llm_first_token_upper_bound")) return "Waiting for model";
    if (std.mem.eql(u8, stage, "post_reply_compaction")) return "Compacting context";
    return stage;
}

// ── Tests ────────────────────────────────────────────────────────────

const TestFrameSink = struct {
    frames: std.ArrayListUnmanaged([]u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) TestFrameSink {
        return .{ .frames = .{}, .allocator = allocator };
    }

    fn deinit(self: *TestFrameSink) void {
        for (self.frames.items) |f| self.allocator.free(f);
        self.frames.deinit(self.allocator);
    }

    fn sink(self: *TestFrameSink) FrameSink {
        return .{ .ptr = @ptrCast(self), .writeFn = captureWrite };
    }

    fn captureWrite(ptr: *anyopaque, frame: []const u8) void {
        const self: *TestFrameSink = @ptrCast(@alignCast(ptr));
        const copy = self.allocator.dupe(u8, frame) catch return;
        self.frames.append(self.allocator, copy) catch {
            self.allocator.free(copy);
        };
    }

    fn lastFrame(self: *const TestFrameSink) ?[]const u8 {
        if (self.frames.items.len == 0) return null;
        return self.frames.items[self.frames.items.len - 1];
    }
};

test "RunEventObserver.getName returns run_events" {
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };
    const obs = reo.observer();
    try std.testing.expectEqualStrings("run_events", obs.getName());
}

test "RunEventObserver forwards events to inner observer" {
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };
    const obs = reo.observer();
    const evt = ObserverEvent{ .turn_complete = {} };
    obs.recordEvent(&evt); // Should not panic
}

test "tool_call_start produces tool_start SSE frame" {
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };
    const obs = reo.observer();
    const evt = ObserverEvent{ .tool_call_start = .{ .tool = "bash" } };
    obs.recordEvent(&evt);
    const frame = test_sink.lastFrame().?;
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: tool_start\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool\":\"bash\"") != null);
}

test "tool_call produces tool_result SSE frame" {
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };
    const obs = reo.observer();
    const evt = ObserverEvent{ .tool_call = .{ .tool = "file_read", .success = true, .duration_ms = 42 } };
    obs.recordEvent(&evt);
    const frame = test_sink.lastFrame().?;
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: tool_result\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"success\":true") != null);
}

test "turn_stage produces progress SSE frame with label" {
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };
    const obs = reo.observer();
    const evt = ObserverEvent{ .turn_stage = .{ .stage = "dispatch_tools" } };
    obs.recordEvent(&evt);
    const frame = test_sink.lastFrame().?;
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: progress\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "Running tools") != null);
}

test "narration_frame produces progress SSE frame" {
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };
    const obs = reo.observer();
    const evt = ObserverEvent{ .narration_frame = .{
        .message = "Using tool",
        .frame_type = .tool_start,
        .tool_name = "bash",
    } };
    obs.recordEvent(&evt);
    const frame = test_sink.lastFrame().?;
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: progress\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "Using tool") != null);
}

test "agent_end produces done SSE frame" {
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };
    const obs = reo.observer();
    const evt = ObserverEvent{ .agent_end = .{ .duration_ms = 1000, .tokens_used = 500 } };
    obs.recordEvent(&evt);
    const frame = test_sink.lastFrame().?;
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: done\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"usage_tokens\":500") != null);
}

test "task_update produces task_update SSE frame" {
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };
    const obs = reo.observer();
    const evt = ObserverEvent{ .task_update = .{ .task_id = "t-001", .status = "running" } };
    obs.recordEvent(&evt);
    const frame = test_sink.lastFrame().?;
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: task_update\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"task_id\":\"t-001\"") != null);
}

test "emitReady writes ready SSE frame" {
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };
    reo.emitReady("session-key-123");
    const frame = test_sink.lastFrame().?;
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: ready\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"session_key\":\"session-key-123\"") != null);
}

test "stageLabel returns human-readable labels" {
    try std.testing.expectEqualStrings("Gathering context", stageLabel("turn_start"));
    try std.testing.expectEqualStrings("Running tools", stageLabel("dispatch_tools"));
    try std.testing.expectEqualStrings("Preparing reply", stageLabel("compose_final_reply"));
    try std.testing.expectEqualStrings("unknown_stage", stageLabel("unknown_stage"));
}
