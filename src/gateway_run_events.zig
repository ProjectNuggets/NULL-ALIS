//! RunEventObserver — translates ObserverEvents into RunEvent SSE frames.
//!
//! Wraps an inner Observer, forwarding all events. For applicable events
//! (llm_request, llm_response, tool_call_start, tool_call, turn_stage,
//! narration_frame, agent_end, task_update, turn_complete,
//! tool_iterations_exhausted), constructs a RunEvent, serializes it via
//! toSseFrame, and writes through a FrameSink.
//!
//! Security: llm_request/llm_response are translated to safe progress events
//! (phase/state labels only) — no provider API details are exposed (T-02-03).
//! reasoning_summary events emit human-readable narration with dedup.

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

// ── PacedFrameSink ──────────────────────────────────────────────────

/// Decorator that wraps any FrameSink with a configurable inter-chunk
/// delay, enabling human-pacing for progressive SSE token streaming.
/// Uses timestamp-based gating: only sleeps if the elapsed time since
/// the last write is less than the configured delay, so fast tokens
/// don't accumulate artificial latency (T-02.1-02: bounded delay).
pub const PacedFrameSink = struct {
    inner: FrameSink,
    delay_ns: u64,
    last_write_ns: i128,

    pub fn init(inner: FrameSink, delay_ms: u32) PacedFrameSink {
        return .{
            .inner = inner,
            .delay_ns = @as(u64, delay_ms) * std.time.ns_per_ms,
            .last_write_ns = 0,
        };
    }

    fn pacedWrite(ptr: *anyopaque, frame: []const u8) void {
        const self: *PacedFrameSink = @ptrCast(@alignCast(ptr));
        if (self.delay_ns > 0) {
            const now = std.time.nanoTimestamp();
            if (self.last_write_ns > 0) {
                const elapsed = now - self.last_write_ns;
                // Guard: clock adjustments can produce negative elapsed — skip pacing.
                const delay_i128: i128 = @intCast(self.delay_ns);
                if (elapsed >= 0 and elapsed < delay_i128) {
                    const remaining: u64 = @intCast(delay_i128 - elapsed);
                    std.Thread.sleep(remaining);
                }
            }
            self.last_write_ns = std.time.nanoTimestamp();
        }
        self.inner.write(frame);
    }

    pub fn sink(self: *PacedFrameSink) FrameSink {
        return .{ .ptr = @ptrCast(self), .writeFn = pacedWrite };
    }
};

// ── Delivery Mode Resolution ────────────────────────────────────────

/// Resolve delivery mode for a given channel name.
/// Live channels (zaki_app, cli) receive token-by-token streaming.
/// All other channels use buffered_replay (post-hoc chunking).
pub fn resolveDeliveryMode(channel: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(channel, "zaki_app")) return "live";
    if (std.ascii.eqlIgnoreCase(channel, "cli")) return "live";
    return "buffered_replay";
}

/// Resolve inter-chunk pacing delay (ms) for a given channel.
/// Web SSE (zaki_app) gets 10ms for human-readable progressive feel
/// without excessive latency on long responses (500 tokens * 10ms = 5s).
/// CLI gets 0ms (immediate dump). Non-live channels return 0 (unused).
pub fn resolvePacingDelay(channel: []const u8) u32 {
    if (std.ascii.eqlIgnoreCase(channel, "zaki_app")) return 10;
    if (std.ascii.eqlIgnoreCase(channel, "cli")) return 0;
    return 0; // non-live channels don't need pacing
}

// ── RunEventObserver ─────────────────────────────────────────────────

pub const RunEventObserver = struct {
    inner: Observer,
    sink: FrameSink,
    allocator: std.mem.Allocator,
    last_reasoning_emit_ms: i64 = 0,
    last_reasoning_hash: u64 = 0,

    const REASONING_DEDUPE_WINDOW_MS: i64 = 450;

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

        // Translate applicable events to RunEvent SSE frames.
        switch (event.*) {
            .llm_request => |e| {
                self.emit(.{ .progress = .{
                    .phase = "thinking",
                    .state = "start",
                    .label = "Thinking",
                    .run_id = e.run_id,
                } });
                // iter20: removed "Thinking through the request" template
                // from reasoning_summary — it's stage chrome, routed via the
                // progress event above.
            },
            .llm_response => |e| {
                self.emit(.{ .progress = .{
                    .phase = if (e.success) "compose" else "finalize",
                    .state = if (e.success) "update" else "error",
                    .label = if (e.success) "Model response received" else "Model request failed",
                    .duration_ms = e.duration_ms,
                    .run_id = e.run_id,
                } });
            },
            .tool_call_start => |e| {
                self.emit(.{ .tool_start = .{
                    .tool = e.tool,
                    .tool_use_id = e.tool_use_id,
                    .input_preview = e.input_preview,
                    .command = e.command,
                    .files = e.files,
                    .activity_label = e.activity_label,
                    .run_id = e.run_id,
                } });
                // iter20: only emit reasoning_summary if there's a REAL
                // activity_label (agent-generated per-tool description).
                // Skip the generic "Using <tool>" template — the tool_start
                // event above already carries the tool name for the UI
                // status row.
                if (e.activity_label) |label| {
                    self.emitReasoningSummary(label, "tool", e.tool, null, e.run_id);
                }
            },
            .tool_call => |e| {
                self.emit(.{ .tool_result = .{
                    .tool = e.tool,
                    .success = e.success,
                    .duration_ms = e.duration_ms,
                    .tool_use_id = e.tool_use_id,
                    .output_preview = e.output_preview,
                    .output_truncated = e.output_truncated,
                    .result_summary = e.result_summary,
                    .command = e.command,
                    .files = e.files,
                    .exit_code = e.exit_code,
                    .run_id = e.run_id,
                } });
            },
            .turn_stage => |e| {
                self.emit(.{ .progress = .{
                    .phase = e.stage,
                    .state = "update",
                    .label = stageLabel(e.stage),
                    .iteration = e.iteration,
                    .duration_ms = e.duration_ms,
                    .tool_use_id = e.tool_use_id,
                    .task_id = e.task_id,
                    .group_id = e.group_id,
                    .heartbeat = e.heartbeat,
                    .command = e.command,
                    .files = e.files,
                    .run_id = e.run_id,
                } });
                // iter20 (gauntlet): removed the synthetic reasoning_summary
                // emission that aliased stage labels ("Checking context and
                // memory", "Preparing the model request", etc). Those are
                // stage CHROME, not thinking — the `progress` event above
                // already carries them via stageLabel for the UI status row.
                // reasoning_summary now fires ONLY on narration_frame (real
                // sidecar or model-native reasoning), matching opencode's
                // pattern where the thinking surface contains real content
                // only — never templated status.
            },
            .narration_frame => |e| {
                // Single-emit per frame_type. The zaki-prod thinking card
                // (NullalisRuntimeWidgets.tsx: isRealReasoningEntry) ONLY
                // surfaces entries with source="reasoning_summary" and
                // length ≥ 40. Earlier dual-emit to both `progress` and
                // `reasoning_summary` caused the frontend's transcript
                // dedup (entrySemanticKey) to hit the progress entry
                // first, drop the reasoning_summary entry as duplicate,
                // and the card fell back to generic labels. So: route
                // model-voice frames (thinking / plan_step) ONLY to
                // reasoning_summary, and tool-chrome frames ONLY to
                // progress.
                switch (e.frame_type) {
                    .thinking, .plan_step => {
                        self.emitReasoningSummary(
                            e.message,
                            @tagName(e.frame_type),
                            e.tool_name,
                            null,
                            null,
                        );
                    },
                    else => {
                        self.emit(.{ .progress = .{
                            .phase = @tagName(e.frame_type),
                            .state = "update",
                            .label = e.message,
                            .tool = e.tool_name,
                        } });
                    },
                }
            },
            .agent_end => |e| self.emit(.{ .done = .{
                .usage_tokens = e.tokens_used,
                .duration_ms = e.duration_ms,
                .run_id = e.run_id,
            } }),
            .task_update => |e| self.emit(.{ .task_update = .{
                .task_id = e.task_id,
                .status = e.status,
                .description = e.description,
                .run_id = e.run_id,
            } }),
            .approval_required => |e| self.emit(.{ .approval_required = .{
                .tool = e.tool,
                .reason = e.reason,
                .risk_level = e.risk_level,
                .run_id = e.run_id,
            } }),
            .turn_complete => self.emit(.{ .progress = .{
                .phase = "finalize",
                .state = "done",
                .label = "Response ready",
            } }),
            .tool_iterations_exhausted => self.emit(.{ .progress = .{
                .phase = "finalize",
                .state = "error",
                .label = "Tool iteration limit reached",
            } }),
            else => {},
        }
    }

    fn emit(self: *RunEventObserver, evt: RunEvent) void {
        const frame = toSseFrame(self.allocator, evt) catch return;
        defer self.allocator.free(frame);
        self.sink.write(frame);
    }

    fn shouldSuppressReasoningSummary(
        self: *RunEventObserver,
        summary: []const u8,
        phase: ?[]const u8,
        tool: ?[]const u8,
        iteration: ?u32,
    ) bool {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(summary);
        if (phase) |phase_name| hasher.update(phase_name);
        if (tool) |tool_name| hasher.update(tool_name);
        if (iteration) |value| {
            var iter_buf: [16]u8 = undefined;
            const iter_text = std.fmt.bufPrint(&iter_buf, "{d}", .{value}) catch "";
            hasher.update(iter_text);
        }
        const hash = hasher.final();
        const now_ms = std.time.milliTimestamp();
        if (self.last_reasoning_hash == hash and now_ms - self.last_reasoning_emit_ms < REASONING_DEDUPE_WINDOW_MS) {
            return true;
        }
        self.last_reasoning_hash = hash;
        self.last_reasoning_emit_ms = now_ms;
        return false;
    }

    fn emitReasoningSummary(
        self: *RunEventObserver,
        summary: []const u8,
        phase: ?[]const u8,
        tool: ?[]const u8,
        iteration: ?u32,
        run_id: ?[]const u8,
    ) void {
        if (self.shouldSuppressReasoningSummary(summary, phase, tool, iteration)) return;
        self.emit(.{ .reasoning_summary = .{
            .summary = summary,
            .phase = phase,
            .tool = tool,
            .iteration = iteration,
            .run_id = run_id,
        } });
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
    if (std.mem.eql(u8, stage, "turn_auto_compaction")) return "Auto-compacting context";
    if (std.mem.eql(u8, stage, "continuity_refresh")) return "Refreshing continuity";
    if (std.mem.eql(u8, stage, "build_provider_messages")) return "Preparing request";
    if (std.mem.eql(u8, stage, "response_cache_hit")) return "Using cached response";
    if (std.mem.eql(u8, stage, "parse_provider_response")) return "Processing response";
    if (std.mem.eql(u8, stage, "dispatch_tools")) return "Running tools";
    if (std.mem.eql(u8, stage, "tool_reflection")) return "Reflecting on results";
    if (std.mem.eql(u8, stage, "compose_final_reply")) return "Preparing reply";
    if (std.mem.eql(u8, stage, "finalize_no_tools")) return "Finalizing reply";
    if (std.mem.eql(u8, stage, "llm_first_token")) return "Model responding";
    if (std.mem.eql(u8, stage, "llm_first_token_upper_bound")) return "Waiting for model";
    if (std.mem.eql(u8, stage, "post_reply_compaction")) return "Compacting context";
    if (std.mem.eql(u8, stage, "tts_prepare")) return "Preparing audio";
    if (std.mem.eql(u8, stage, "history_maintenance_after_tools")) return "Updating history";
    return stage;
}

// Note: `reasoningSummaryForStage` and `reasoningPhaseForStage` helpers were
// removed in iter20 — stage labels are no longer aliased as reasoning
// content. Progress events carry the UI status via stageLabel(); reasoning
// content flows only through narration_frame events (real sidecar /
// model-native reasoning).

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

    fn firstFrameWithPrefix(self: *const TestFrameSink, prefix: []const u8) ?[]const u8 {
        for (self.frames.items) |frame| {
            if (std.mem.startsWith(u8, frame, prefix)) return frame;
        }
        return null;
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
    const frame = test_sink.firstFrameWithPrefix("event: tool_start\n").?;
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
    const frame = test_sink.firstFrameWithPrefix("event: progress\n").?;
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: progress\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "Running tools") != null);
}

test "narration_frame thinking produces ONLY reasoning_summary, not progress" {
    // Single-emit for .thinking frames: zaki-prod's thinking card reads
    // reasoning_summary only. Emitting both caused the frontend's
    // transcript dedup to drop the reasoning_summary entry as a
    // duplicate of the progress entry, making the thinking card fall
    // back to generic labels. See commit e07f237 → reverted.
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };
    const obs = reo.observer();
    const evt = ObserverEvent{ .narration_frame = .{
        .message = "The user is asking about X. Let me check Y before answering.",
        .frame_type = .thinking,
    } };
    obs.recordEvent(&evt);

    const reasoning_frame = test_sink.firstFrameWithPrefix("event: reasoning_summary\n") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, reasoning_frame, "\"phase\":\"thinking\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reasoning_frame, "The user is asking about X") != null);

    // Must NOT also produce a progress frame for .thinking (would collide
    // in frontend dedup and silence the reasoning_summary channel).
    try std.testing.expect(test_sink.firstFrameWithPrefix("event: progress\n") == null);
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

test "tool_call_start with run_id forwards run_id into tool_start frame" {
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };
    const obs = reo.observer();
    const evt = ObserverEvent{ .tool_call_start = .{
        .tool = "bash",
        .tool_use_id = "call_1",
        .run_id = "r-42-1",
    } };
    obs.recordEvent(&evt);
    const frame = test_sink.firstFrameWithPrefix("event: tool_start\n").?;
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool_use_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"run_id\":\"r-42-1\"") != null);
}

test "tool_call with run_id forwards run_id into tool_result frame" {
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };
    const obs = reo.observer();
    const evt = ObserverEvent{ .tool_call = .{
        .tool = "bash",
        .success = true,
        .duration_ms = 7,
        .tool_use_id = "call_1",
        .run_id = "r-42-1",
    } };
    obs.recordEvent(&evt);
    const frame = test_sink.lastFrame().?;
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: tool_result\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool_use_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"run_id\":\"r-42-1\"") != null);
}

test "approval_required with run_id forwards run_id into approval_required frame" {
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };
    const obs = reo.observer();
    const evt = ObserverEvent{ .approval_required = .{
        .tool = "bash",
        .reason = "supervised_mutating_requires_approval",
        .risk_level = "critical",
        .run_id = "r-77-2",
    } };
    obs.recordEvent(&evt);
    const frame = test_sink.lastFrame().?;
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: approval_required\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"run_id\":\"r-77-2\"") != null);
}

test "shouldSuppressReasoningSummary deduplicates identical events within window" {
    var noop = observability.NoopObserver{};
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var reo = RunEventObserver{ .inner = noop.observer(), .sink = test_sink.sink(), .allocator = allocator };

    // First emission should pass
    try std.testing.expect(!reo.shouldSuppressReasoningSummary("Thinking", "thinking", null, null));
    // Identical emission within window should be suppressed
    try std.testing.expect(reo.shouldSuppressReasoningSummary("Thinking", "thinking", null, null));
    // Different content should pass
    try std.testing.expect(!reo.shouldSuppressReasoningSummary("Using bash", "tool", "bash", null));
    // Same tool content should be suppressed
    try std.testing.expect(reo.shouldSuppressReasoningSummary("Using bash", "tool", "bash", null));
    // Same text but different iteration should pass
    try std.testing.expect(!reo.shouldSuppressReasoningSummary("Using bash", "tool", "bash", 2));
}

// ── PacedFrameSink Tests ────────────────────────────────────────────

test "PacedFrameSink.init creates instance with inner sink, delay_ms=30" {
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    const paced = PacedFrameSink.init(test_sink.sink(), 30);
    try std.testing.expectEqual(@as(u64, 30 * std.time.ns_per_ms), paced.delay_ns);
}

test "PacedFrameSink.sink returns valid FrameSink that delegates write to inner" {
    const allocator = std.testing.allocator;
    var test_sink = TestFrameSink.init(allocator);
    defer test_sink.deinit();
    var paced = PacedFrameSink.init(test_sink.sink(), 0);
    const sink = paced.sink();
    sink.write("hello from paced");
    try std.testing.expectEqual(@as(usize, 1), test_sink.frames.items.len);
    try std.testing.expectEqualStrings("hello from paced", test_sink.lastFrame().?);
}

// ── resolveDeliveryMode Tests ───────────────────────────────────────

test "resolveDeliveryMode zaki_app returns live" {
    try std.testing.expectEqualStrings("live", resolveDeliveryMode("zaki_app"));
}

test "resolveDeliveryMode cli returns live" {
    try std.testing.expectEqualStrings("live", resolveDeliveryMode("cli"));
}

test "resolveDeliveryMode telegram returns buffered_replay" {
    try std.testing.expectEqualStrings("buffered_replay", resolveDeliveryMode("telegram"));
}

test "resolveDeliveryMode discord returns buffered_replay" {
    try std.testing.expectEqualStrings("buffered_replay", resolveDeliveryMode("discord"));
}

test "resolveDeliveryMode unknown_channel returns buffered_replay" {
    try std.testing.expectEqualStrings("buffered_replay", resolveDeliveryMode("unknown_channel"));
}

// ── resolvePacingDelay Tests ────────────────────────────────────────

test "resolvePacingDelay zaki_app returns 10" {
    try std.testing.expectEqual(@as(u32, 10), resolvePacingDelay("zaki_app"));
}

test "resolvePacingDelay cli returns 0" {
    try std.testing.expectEqual(@as(u32, 0), resolvePacingDelay("cli"));
}
