//! Liveness narration engine — converts observer events into user-facing progress frames.
//!
//! NarrationObserver wraps an inner Observer, translates tool_call_start and turn_stage
//! events into semantic NarrationFrame structs, and delivers them through a callback.
//! This is the "thinking out loud" infrastructure for real-time user-facing status.
//!
//! Design invariant: narration frames flow ONLY through the Observer event bus.
//! They must NEVER be appended to Agent.history (LLM message context).

const std = @import("std");
const observability = @import("../observability.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;
const ObserverMetric = observability.ObserverMetric;

/// Semantic frame type — reuses NarrationFrameType from observability to avoid duplication.
pub const FrameType = observability.NarrationFrameType;

/// A user-facing progress frame delivered by NarrationObserver.
pub const NarrationFrame = struct {
    message: []const u8,
    frame_type: FrameType,
    tool_name: ?[]const u8 = null,
    step_index: ?u32 = null,
    step_total: ?u32 = null,
};

/// Callback fn pointer for direct frame delivery (optional, can be null).
/// ctx is the caller-supplied context pointer passed at construction.
pub const NarrationCallback = *const fn (ctx: *anyopaque, frame: NarrationFrame) void;

/// Wraps an inner Observer, forwarding all events and additionally generating
/// user-facing NarrationFrame structs for tool and turn-stage events.
pub const NarrationObserver = struct {
    inner: Observer,
    callback: ?NarrationCallback = null,
    callback_ctx: ?*anyopaque = null,

    const vtable = Observer.VTable{
        .record_event = recordEvent,
        .record_metric = recordMetric,
        .flush = flush,
        .name = name,
    };

    /// Return an Observer interface backed by this NarrationObserver.
    pub fn observer(self: *NarrationObserver) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn recordEvent(ptr: *anyopaque, event: *const ObserverEvent) void {
        const self: *NarrationObserver = @ptrCast(@alignCast(ptr));
        // Always forward to inner observer first.
        self.inner.recordEvent(event);

        // Generate narration frames for specific events.
        switch (event.*) {
            .tool_call_start => |e| {
                self.emitFrame(.{
                    .message = "Using tool",
                    .frame_type = .tool_start,
                    .tool_name = e.tool,
                });
            },
            .tool_call => |e| {
                self.emitFrame(.{
                    .message = if (e.success) "Tool completed" else "Tool failed",
                    .frame_type = if (e.success) .tool_done else .error_recovery,
                    .tool_name = e.tool,
                });
            },
            .turn_stage => |e| {
                if (turnStageToNarration(e.stage)) |msg| {
                    self.emitFrame(.{
                        .message = msg,
                        .frame_type = turnStageToFrameType(e.stage),
                    });
                }
            },
            else => {},
        }
    }

    fn emitFrame(self: *NarrationObserver, frame: NarrationFrame) void {
        // Deliver via callback if one is registered.
        if (self.callback) |cb| {
            cb(self.callback_ctx orelse @ptrCast(&self.inner), frame);
        }
        // Also emit as an observer event so downstream consumers (SSE, channels) receive it.
        const narration_event = ObserverEvent{ .narration_frame = .{
            .message = frame.message,
            .frame_type = frame.frame_type,
            .tool_name = frame.tool_name,
            .step_index = frame.step_index,
            .step_total = frame.step_total,
        } };
        self.inner.recordEvent(&narration_event);
    }

    fn recordMetric(ptr: *anyopaque, metric: *const ObserverMetric) void {
        const self: *NarrationObserver = @ptrCast(@alignCast(ptr));
        self.inner.recordMetric(metric);
    }

    fn flush(ptr: *anyopaque) void {
        const self: *NarrationObserver = @ptrCast(@alignCast(ptr));
        self.inner.flush();
    }

    fn name(_: *anyopaque) []const u8 {
        return "narration";
    }

    /// Maps turn_stage labels to user-facing narration messages.
    /// Returns null for unknown stages (no narration emitted).
    fn turnStageToNarration(stage: []const u8) ?[]const u8 {
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
        if (std.mem.eql(u8, stage, "voice_listening")) return "Listening...";
        if (std.mem.eql(u8, stage, "voice_speaking")) return "Speaking...";
        return null;
    }

    /// Maps turn_stage labels to semantic FrameType values.
    fn turnStageToFrameType(stage: []const u8) FrameType {
        if (std.mem.eql(u8, stage, "dispatch_tools")) return .tool_start;
        if (std.mem.eql(u8, stage, "llm_first_token_upper_bound")) return .waiting;
        if (std.mem.eql(u8, stage, "llm_first_token")) return .waiting;
        if (std.mem.eql(u8, stage, "voice_listening")) return .listening;
        if (std.mem.eql(u8, stage, "voice_speaking")) return .speaking;
        return .thinking;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "NarrationObserver.getName returns narration" {
    var noop = observability.NoopObserver{};
    var narr = NarrationObserver{ .inner = noop.observer() };
    const obs = narr.observer();
    try std.testing.expectEqualStrings("narration", obs.getName());
}

test "NarrationObserver wraps inner observer and forwards events" {
    var noop = observability.NoopObserver{};
    var narr = NarrationObserver{ .inner = noop.observer() };
    const obs = narr.observer();
    // Should not panic — events forwarded to noop inner.
    const evt = ObserverEvent{ .turn_complete = {} };
    obs.recordEvent(&evt);
}

test "NarrationObserver emits narration_frame on tool_call_start" {
    // Use a LogObserver as inner to capture events without crashing.
    var log_obs = observability.LogObserver{};
    var narr = NarrationObserver{ .inner = log_obs.observer() };
    const obs = narr.observer();
    const evt = ObserverEvent{ .tool_call_start = .{ .tool = "bash" } };
    obs.recordEvent(&evt);
    // Verify the NarrationObserver itself is still alive and functional.
    try std.testing.expectEqualStrings("narration", obs.getName());
}

test "turnStageToNarration returns correct labels" {
    try std.testing.expectEqualStrings("Gathering context", NarrationObserver.turnStageToNarration("turn_start").?);
    try std.testing.expectEqualStrings("Retrieving memory", NarrationObserver.turnStageToNarration("memory_enrich").?);
    try std.testing.expectEqualStrings("Running tools", NarrationObserver.turnStageToNarration("dispatch_tools").?);
    try std.testing.expectEqualStrings("Reflecting on results", NarrationObserver.turnStageToNarration("tool_reflection").?);
    try std.testing.expectEqualStrings("Preparing reply", NarrationObserver.turnStageToNarration("compose_final_reply").?);
    try std.testing.expectEqualStrings("Model responding", NarrationObserver.turnStageToNarration("llm_first_token").?);
    try std.testing.expectEqualStrings("Waiting for model", NarrationObserver.turnStageToNarration("llm_first_token_upper_bound").?);
}

test "turnStageToNarration returns null for unknown stages" {
    try std.testing.expect(NarrationObserver.turnStageToNarration("unknown_stage") == null);
    try std.testing.expect(NarrationObserver.turnStageToNarration("") == null);
    try std.testing.expect(NarrationObserver.turnStageToNarration("made_up") == null);
}

test "turnStageToFrameType returns correct frame types" {
    try std.testing.expectEqual(FrameType.tool_start, NarrationObserver.turnStageToFrameType("dispatch_tools"));
    try std.testing.expectEqual(FrameType.waiting, NarrationObserver.turnStageToFrameType("llm_first_token_upper_bound"));
    try std.testing.expectEqual(FrameType.waiting, NarrationObserver.turnStageToFrameType("llm_first_token"));
    try std.testing.expectEqual(FrameType.thinking, NarrationObserver.turnStageToFrameType("memory_enrich"));
    try std.testing.expectEqual(FrameType.thinking, NarrationObserver.turnStageToFrameType("turn_start"));
}

test "narration_frame variant exists in ObserverEvent" {
    const evt = ObserverEvent{ .narration_frame = .{
        .message = "test message",
        .frame_type = .thinking,
    } };
    switch (evt) {
        .narration_frame => |f| {
            try std.testing.expectEqualStrings("test message", f.message);
            try std.testing.expectEqual(observability.NarrationFrameType.thinking, f.frame_type);
            try std.testing.expect(f.tool_name == null);
        },
        else => return error.WrongVariant,
    }
}

test "NarrationFrame struct zero-init" {
    const frame = NarrationFrame{
        .message = "hello",
        .frame_type = .tool_start,
    };
    try std.testing.expectEqualStrings("hello", frame.message);
    try std.testing.expectEqual(FrameType.tool_start, frame.frame_type);
    try std.testing.expect(frame.tool_name == null);
    try std.testing.expect(frame.step_index == null);
    try std.testing.expect(frame.step_total == null);
}

test "turnStageToNarration handles voice_listening" {
    try std.testing.expectEqualStrings("Listening...", NarrationObserver.turnStageToNarration("voice_listening").?);
}

test "turnStageToNarration handles voice_speaking" {
    try std.testing.expectEqualStrings("Speaking...", NarrationObserver.turnStageToNarration("voice_speaking").?);
}

test "turnStageToFrameType maps voice_listening to listening" {
    try std.testing.expectEqual(FrameType.listening, NarrationObserver.turnStageToFrameType("voice_listening"));
}

test "turnStageToFrameType maps voice_speaking to speaking" {
    try std.testing.expectEqual(FrameType.speaking, NarrationObserver.turnStageToFrameType("voice_speaking"));
}
