//! Liveness narration engine — converts observer events into user-facing progress frames.
//!
//! NarrationObserver wraps an inner Observer, translates tool_call_start and turn_stage
//! events into semantic NarrationFrame structs, and delivers them through a callback.
//! This is the "thinking out loud" infrastructure for real-time user-facing status.
//!
//! Design invariant: narration frames flow ONLY through the Observer event bus.
//! They must NEVER be appended to Agent.history (LLM message context).
//!
//! v1.14.18-B G3 (NARRATION-AS-CONTEXT) addition: a per-Agent
//! `NarrationRingBuffer` records the recent narration frames so the agent
//! can read its own prior thinking back into the next iteration's prompt.
//! The buffer is owned by the Agent (so it persists across the per-turn
//! `NarrationObserver` lifetime) and is referenced by pointer from the
//! per-turn wrapper. `recallRecent` returns the last N entries oldest →
//! newest for rendering into the `<recent_thoughts>` volatile block via
//! `context_engine.assemble`.

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

/// v1.14.18-B G3 — recorded ring-buffer frame. Owns its message + tool_name
/// strings (heap-dup'd from NarrationFrame at push time) so the buffer is
/// not aliasing the per-turn observer's stack frames or the channel
/// formatters' transient buffers. Caller frees via `RingBuffer.deinit`.
pub const RecordedFrame = struct {
    message: []u8,
    frame_type: FrameType,
    tool_name: ?[]u8 = null,
    iteration: u32 = 0,
    unix_ms: i64 = 0,

    pub fn deinit(self: *RecordedFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.tool_name) |t| allocator.free(t);
    }
};

/// Fixed-capacity ring buffer of recent narration frames. 16 slots fits
/// 4-5 multi-tool iterations comfortably without bloating the agent struct.
/// Eviction is FIFO (oldest dropped first).
///
/// Owned by `Agent`; the per-turn `NarrationObserver` holds a pointer back
/// so `emitFrame` pushes through. `recallRecent` reads the last N in
/// oldest→newest order for prompt injection.
pub const RING_BUFFER_CAPACITY: usize = 16;

/// Number of recent narration frames surfaced in the <recent_thoughts>
/// recall block. v1.14.18-B G3 tuning knob — referenced by
/// `context_engine.assemble` when it calls `recallRecent`.
pub const RECALL_DEPTH: usize = 3;

/// v1.14.18-B G3 — thread-safe ring buffer of recent narration frames.
///
/// **Thread-safety:** `push`, `last`, and `deinit` are mutex-guarded. Safe
/// to call from any thread. The host `NarrationObserver` is reached from
/// worker threads via `tools_mod.setToolObserver(...)` in
/// `src/agent/root.zig` (parallel tool dispatch path), so any future
/// worker-emitted event variant that lands in `emitFrame` immediately
/// becomes a concurrent push. The mutex makes that safe by construction
/// instead of by calling-convention discipline.
///
/// **Ownership contract for `last()` / `recallRecent`:** the returned slice
/// AND each inner `.message` / `.tool_name` are FULLY OWNED by
/// `out_allocator`. The caller MUST free each frame's `.message`, each
/// non-null `.tool_name`, and the outer slice itself (or pass an arena
/// allocator that bulk-frees on reset). The prior "borrow contract" was a
/// HIGH concurrent use-after-free: the mutex only fenced WHEN the metadata
/// was copied; the borrowed string pointers still aliased ring-buffer
/// memory and a subsequent worker-thread `push()` could recycle the slot
/// and free the underlying buffer, dangling the borrow. `last()` now
/// deep-copies the strings while holding the lock so the returned frames
/// are independent of the ring buffer's slot lifetimes.
pub const NarrationRingBuffer = struct {
    frames: [RING_BUFFER_CAPACITY]RecordedFrame = undefined,
    /// Number of valid frames currently stored (0..RING_BUFFER_CAPACITY).
    len: usize = 0,
    /// Next write index modulo capacity.
    head: usize = 0,
    /// Allocator used to dup message strings on push.
    allocator: std.mem.Allocator,
    /// v1.14.18-B G3 — guards `frames`/`len`/`head` against concurrent
    /// push/last calls from worker threads (parallel tool dispatch path).
    /// Uncontended in the common case; the cost is one atomic per frame.
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) NarrationRingBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *NarrationRingBuffer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var idx: usize = 0;
        while (idx < self.len) : (idx += 1) {
            self.frames[idx].deinit(self.allocator);
        }
        self.len = 0;
        self.head = 0;
    }

    /// Push a frame. Dupes message + tool_name; on dupe failure the frame
    /// is dropped and a warn is logged (narration is observability —
    /// never crashes the agent). The warn is critical for spotting an
    /// uninitialized buffer (e.g. test fixture that forgot to call
    /// `NarrationRingBuffer.init` and left the `failing_allocator`
    /// sentinel from the struct default — see `Agent.narration_ring_buffer`
    /// in `src/agent/root.zig`). Without the warn, missed init silently
    /// drops every frame and tests pass with empty recall blocks.
    /// Thread-safe via internal mutex.
    pub fn push(self: *NarrationRingBuffer, frame: NarrationFrame, iteration: u32) void {
        const msg = self.allocator.dupe(u8, frame.message) catch {
            std.log.warn(
                "narration: dropped frame (allocator OOM or uninitialized: did you forget to call NarrationRingBuffer.init?)",
                .{},
            );
            return;
        };
        const tool_owned: ?[]u8 = if (frame.tool_name) |t|
            (self.allocator.dupe(u8, t) catch {
                self.allocator.free(msg);
                std.log.warn(
                    "narration: dropped frame (allocator OOM or uninitialized: did you forget to call NarrationRingBuffer.init?)",
                    .{},
                );
                return;
            })
        else
            null;

        const recorded = RecordedFrame{
            .message = msg,
            .frame_type = frame.frame_type,
            .tool_name = tool_owned,
            .iteration = iteration,
            .unix_ms = std.time.milliTimestamp(),
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len < RING_BUFFER_CAPACITY) {
            self.frames[self.len] = recorded;
            self.len += 1;
            self.head = self.len % RING_BUFFER_CAPACITY;
        } else {
            // Full: free the slot we're about to overwrite, then write.
            self.frames[self.head].deinit(self.allocator);
            self.frames[self.head] = recorded;
            self.head = (self.head + 1) % RING_BUFFER_CAPACITY;
        }
    }

    /// Return the last N frames in oldest → newest order. The returned slice
    /// AND each inner `.message` / `.tool_name` string are fully owned by
    /// `out_allocator` — strings are deep-copied while the mutex is held.
    /// The caller MUST free each frame's `.message`, each non-null
    /// `.tool_name`, and the outer slice (or pass an arena that gets
    /// bulk-freed on reset).
    ///
    /// **Why deep-copy:** previously the returned slice borrowed
    /// ring-buffer-owned strings. After `last()` released the mutex a
    /// concurrent worker-thread `push()` could recycle a slot, free its
    /// old `.message` / `.tool_name`, and dangle the borrow — a HIGH
    /// concurrent use-after-free that `renderRecentThoughtsBlock` would
    /// trip when it read the strings. Deep-copying under the lock closes
    /// the window: the returned frames carry their own buffers and stay
    /// valid regardless of what the ring buffer does next.
    ///
    /// Thread-safe via internal mutex.
    pub fn last(
        self: *NarrationRingBuffer,
        out_allocator: std.mem.Allocator,
        n: usize,
    ) ![]RecordedFrame {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len == 0 or n == 0) return out_allocator.alloc(RecordedFrame, 0);
        const take = @min(n, self.len);

        // Reconstruct chronological order. When len < capacity, frames
        // live at indices 0..len-1 in arrival order (no wrap yet). When
        // saturated, the oldest sits at `head` and wraps around.
        const out = try out_allocator.alloc(RecordedFrame, take);
        errdefer out_allocator.free(out);

        // Partial-failure cleanup: if a `dupe` partway through the loop
        // fails, the prior iterations already heap-allocated strings that
        // would otherwise leak. Track how many slots are fully populated
        // and free their owned strings on error before bubbling up.
        var duped: usize = 0;
        errdefer {
            var k: usize = 0;
            while (k < duped) : (k += 1) {
                out_allocator.free(out[k].message);
                if (out[k].tool_name) |t| out_allocator.free(t);
            }
        }

        var i: usize = 0;
        while (i < take) : (i += 1) {
            const idx: usize = if (self.len < RING_BUFFER_CAPACITY) blk: {
                // No wrap: newest is at self.len-1, oldest of `take`
                // window is at self.len-take.
                const start = self.len - take;
                break :blk start + i;
            } else blk: {
                // Saturated: chronological start is at `head`; iterate
                // forward wrapping. The last `take` frames are at
                // positions (head + (capacity-take)) .. (head + capacity-1)
                // modulo capacity.
                const skip = RING_BUFFER_CAPACITY - take;
                break :blk (self.head + skip + i) % RING_BUFFER_CAPACITY;
            };

            const src = &self.frames[idx];
            const msg_copy = try out_allocator.dupe(u8, src.message);
            const tool_copy: ?[]u8 = if (src.tool_name) |t|
                out_allocator.dupe(u8, t) catch |e| {
                    out_allocator.free(msg_copy);
                    return e;
                }
            else
                null;

            out[i] = .{
                .message = msg_copy,
                .tool_name = tool_copy,
                .frame_type = src.frame_type,
                .iteration = src.iteration,
                .unix_ms = src.unix_ms,
            };
            duped += 1;
        }
        return out;
    }
};

/// v1.14.18-B G3 entry point — return the last N recorded narration frames.
/// Oldest → newest order. Empty slice when the buffer is empty or null.
///
/// Wired into `context_engine.assemble` so the agent sees its own recent
/// thinking as feedback in the next iteration's `<recent_thoughts>` block.
///
/// Takes a mutable pointer because the underlying `last()` locks the
/// buffer's mutex (thread-safety per `NarrationRingBuffer` doc). The
/// caller-visible semantics are read-only — the buffer's contents are
/// not mutated — but the mutex acquisition requires the non-const handle.
///
/// **Ownership:** delegates to `NarrationRingBuffer.last`, which returns
/// frames whose `.message` / `.tool_name` strings AND outer slice are
/// fully owned by `out_allocator`. The caller MUST free each frame's
/// `.message`, each non-null `.tool_name`, and the outer slice (or pass
/// an arena that bulk-frees on reset). See the `last()` doc-comment for
/// the rationale (concurrent UAF closure).
pub fn recallRecent(
    buffer_opt: ?*NarrationRingBuffer,
    out_allocator: std.mem.Allocator,
    n: usize,
) ![]RecordedFrame {
    const buffer = buffer_opt orelse return out_allocator.alloc(RecordedFrame, 0);
    return buffer.last(out_allocator, n);
}

/// Format a frame_type as a short tag for the `<recent_thoughts>` block.
/// Kept terse so the prompt surface stays compact.
fn frameTypeTag(ft: FrameType) []const u8 {
    return switch (ft) {
        .thinking => "thinking",
        .tool_start => "action",
        .tool_done => "result",
        .error_recovery => "error",
        .waiting => "waiting",
        .plan_step => "plan",
        .listening => "listen",
        .speaking => "speak",
    };
}

/// Render a slice of RecordedFrame as a `<recent_thoughts>` block string.
/// Returns empty string when frames are empty. Caller frees.
///
/// Format (per dispatch spec):
///   <recent_thoughts iteration="N" count="3">
///   [iter 1, thinking]: Retrieving memory for entity
///   [iter 2, action]: memory_recall (Joanna)
///   [iter 2, thinking]: 4 hits, none match the constraint
///   </recent_thoughts>
pub fn renderRecentThoughtsBlock(
    allocator: std.mem.Allocator,
    frames: []const RecordedFrame,
    current_iteration: u32,
) ![]u8 {
    if (frames.len == 0) return allocator.alloc(u8, 0);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print(
        "<recent_thoughts iteration=\"{d}\" count=\"{d}\">\n",
        .{ current_iteration, frames.len },
    );
    for (frames) |f| {
        if (f.tool_name) |tn| {
            try w.print(
                "[iter {d}, {s}]: {s} ({s})\n",
                .{ f.iteration, frameTypeTag(f.frame_type), f.message, tn },
            );
        } else {
            try w.print(
                "[iter {d}, {s}]: {s}\n",
                .{ f.iteration, frameTypeTag(f.frame_type), f.message },
            );
        }
    }
    try w.writeAll("</recent_thoughts>\n");
    return buf.toOwnedSlice(allocator);
}

/// Callback fn pointer for direct frame delivery (optional, can be null).
/// ctx is the caller-supplied context pointer passed at construction.
pub const NarrationCallback = *const fn (ctx: *anyopaque, frame: NarrationFrame) void;

/// Wraps an inner Observer, forwarding all events and additionally generating
/// user-facing NarrationFrame structs for tool and turn-stage events.
pub const NarrationObserver = struct {
    inner: Observer,
    callback: ?NarrationCallback = null,
    callback_ctx: ?*anyopaque = null,
    /// v1.14.18-B G3 — optional pointer to the Agent's ring buffer so
    /// emitted frames flow into per-iteration recall. Null in test
    /// constructions and in subagent observers where recall isn't needed.
    ring_buffer: ?*NarrationRingBuffer = null,
    /// v1.14.18-B G3 — current tool-iteration the agent is on. Stamped
    /// onto pushed frames so `<recent_thoughts>` lines carry their origin
    /// iteration. The owning Agent bumps this between iterations.
    ///
    /// **Session-monotonic:** mirrors `Agent.iteration_counter`, which is
    /// bumped per ReAct iteration and is NOT reset per turn. Turn-2
    /// iterations therefore display continued numbers (e.g. iter=17, 18,
    /// ... after turn 1 ended at iter=16). See the field doc on
    /// `Agent.iteration_counter` in `src/agent/root.zig` for the
    /// definitive wording.
    current_iteration: u32 = 0,

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
        // Use activity_label, command, and files from tool events for specific
        // narration instead of generic "Using tool" / "Tool completed".
        switch (event.*) {
            .tool_call_start => |e| {
                // Priority: activity_label > "Running: {command}" > "Using {tool}"
                const message = e.activity_label orelse
                    if (e.command != null) "Running command" else "Using tool";
                self.emitFrame(.{
                    .message = message,
                    .frame_type = .tool_start,
                    .tool_name = e.tool,
                });
            },
            .tool_call => |e| {
                // Use result_summary if available, otherwise generic success/fail
                const message = e.result_summary orelse
                    if (e.success) "Tool completed" else "Tool failed";
                self.emitFrame(.{
                    .message = message,
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
        // v1.14.18-B G3 — push into the Agent's ring buffer so recallRecent
        // can surface this thought in the next iteration's volatile prompt
        // block. Happens FIRST (before callback / inner observer) so the
        // record reflects the model's own progress trail regardless of
        // whether downstream observers crash. Failure-soft via push().
        if (self.ring_buffer) |rb| rb.push(frame, self.current_iteration);

        // Deliver via callback if one is registered and has a valid context.
        if (self.callback) |cb| {
            if (self.callback_ctx) |ctx| {
                cb(ctx, frame);
            }
            // Skip callback if no context — avoid passing pointer to unrelated data.
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

// ── v1.14.18-B G3 ring buffer + recallRecent tests ─────────────────────────

/// Free the deep-copied strings inside frames returned by `last()` /
/// `recallRecent()` under `std.testing.allocator`. Test-only helper; the
/// production caller (`context_engine.assemble`) uses an equivalent
/// inline `defer` block.
fn freeRecalledFramesForTest(frames: []RecordedFrame) void {
    for (frames) |f| {
        std.testing.allocator.free(f.message);
        if (f.tool_name) |t| std.testing.allocator.free(t);
    }
    std.testing.allocator.free(frames);
}

test "NarrationRingBuffer push + last returns frames in order" {
    var rb = NarrationRingBuffer.init(std.testing.allocator);
    defer rb.deinit();

    rb.push(.{ .message = "first", .frame_type = .thinking }, 1);
    rb.push(.{ .message = "second", .frame_type = .tool_start, .tool_name = "bash" }, 1);
    rb.push(.{ .message = "third", .frame_type = .tool_done, .tool_name = "bash" }, 2);

    const frames = try rb.last(std.testing.allocator, 3);
    defer freeRecalledFramesForTest(frames);
    try std.testing.expectEqual(@as(usize, 3), frames.len);
    try std.testing.expectEqualStrings("first", frames[0].message);
    try std.testing.expectEqualStrings("second", frames[1].message);
    try std.testing.expectEqualStrings("third", frames[2].message);
    try std.testing.expectEqualStrings("bash", frames[1].tool_name.?);
    try std.testing.expectEqual(@as(u32, 2), frames[2].iteration);
}

test "NarrationRingBuffer.last(n) returns at most n newest" {
    var rb = NarrationRingBuffer.init(std.testing.allocator);
    defer rb.deinit();
    rb.push(.{ .message = "a", .frame_type = .thinking }, 0);
    rb.push(.{ .message = "b", .frame_type = .thinking }, 0);
    rb.push(.{ .message = "c", .frame_type = .thinking }, 0);
    rb.push(.{ .message = "d", .frame_type = .thinking }, 0);

    const last2 = try rb.last(std.testing.allocator, 2);
    defer freeRecalledFramesForTest(last2);
    try std.testing.expectEqual(@as(usize, 2), last2.len);
    try std.testing.expectEqualStrings("c", last2[0].message);
    try std.testing.expectEqualStrings("d", last2[1].message);
}

test "NarrationRingBuffer never grows past RING_BUFFER_CAPACITY" {
    var rb = NarrationRingBuffer.init(std.testing.allocator);
    defer rb.deinit();
    // Push 2x capacity; oldest must be evicted FIFO.
    var i: usize = 0;
    while (i < RING_BUFFER_CAPACITY * 2) : (i += 1) {
        var buf: [16]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "m{d}", .{i});
        // dup so we can free locally; push dups again internally.
        const owned = try std.testing.allocator.dupe(u8, msg);
        defer std.testing.allocator.free(owned);
        rb.push(.{ .message = owned, .frame_type = .thinking }, @intCast(i));
    }
    try std.testing.expectEqual(RING_BUFFER_CAPACITY, rb.len);

    // last(capacity) must return the most recent capacity entries.
    const all = try rb.last(std.testing.allocator, RING_BUFFER_CAPACITY);
    defer freeRecalledFramesForTest(all);
    try std.testing.expectEqual(RING_BUFFER_CAPACITY, all.len);
    // Oldest of the kept window is m{capacity} (we pushed 0..2*capacity-1).
    var first_buf: [16]u8 = undefined;
    const first_expected = try std.fmt.bufPrint(&first_buf, "m{d}", .{RING_BUFFER_CAPACITY});
    try std.testing.expectEqualStrings(first_expected, all[0].message);
    // Newest = m{2*capacity - 1}.
    var last_buf: [16]u8 = undefined;
    const last_expected = try std.fmt.bufPrint(&last_buf, "m{d}", .{RING_BUFFER_CAPACITY * 2 - 1});
    try std.testing.expectEqualStrings(last_expected, all[RING_BUFFER_CAPACITY - 1].message);
}

test "recallRecent null buffer returns empty slice" {
    const frames = try recallRecent(null, std.testing.allocator, 3);
    defer freeRecalledFramesForTest(frames);
    try std.testing.expectEqual(@as(usize, 0), frames.len);
}

test "recallRecent empty buffer returns empty slice" {
    var rb = NarrationRingBuffer.init(std.testing.allocator);
    defer rb.deinit();
    const frames = try recallRecent(&rb, std.testing.allocator, 3);
    defer freeRecalledFramesForTest(frames);
    try std.testing.expectEqual(@as(usize, 0), frames.len);
}

test "recallRecent returns last N oldest-to-newest" {
    var rb = NarrationRingBuffer.init(std.testing.allocator);
    defer rb.deinit();
    rb.push(.{ .message = "alpha", .frame_type = .thinking }, 1);
    rb.push(.{ .message = "beta", .frame_type = .tool_start, .tool_name = "memory_recall" }, 2);
    rb.push(.{ .message = "gamma", .frame_type = .thinking }, 2);
    rb.push(.{ .message = "delta", .frame_type = .tool_done, .tool_name = "memory_recall" }, 3);

    const last3 = try recallRecent(&rb, std.testing.allocator, 3);
    defer freeRecalledFramesForTest(last3);
    try std.testing.expectEqual(@as(usize, 3), last3.len);
    try std.testing.expectEqualStrings("beta", last3[0].message);
    try std.testing.expectEqualStrings("gamma", last3[1].message);
    try std.testing.expectEqualStrings("delta", last3[2].message);
}

test "renderRecentThoughtsBlock empty frames returns empty string" {
    const out = try renderRecentThoughtsBlock(std.testing.allocator, &.{}, 5);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "renderRecentThoughtsBlock formats frames with iteration tags" {
    const frames = [_]RecordedFrame{
        .{ .message = @constCast("Retrieving memory"), .frame_type = .thinking, .iteration = 1 },
        .{
            .message = @constCast("memory_recall"),
            .frame_type = .tool_start,
            .tool_name = @constCast("memory_recall"),
            .iteration = 2,
        },
        .{ .message = @constCast("4 hits"), .frame_type = .thinking, .iteration = 2 },
    };
    const out = try renderRecentThoughtsBlock(std.testing.allocator, &frames, 3);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<recent_thoughts iteration=\"3\" count=\"3\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[iter 1, thinking]: Retrieving memory\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[iter 2, action]: memory_recall (memory_recall)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[iter 2, thinking]: 4 hits") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "</recent_thoughts>\n"));
}

test "NarrationObserver pushes into ring buffer when wired" {
    var noop = observability.NoopObserver{};
    var rb = NarrationRingBuffer.init(std.testing.allocator);
    defer rb.deinit();
    var narr = NarrationObserver{
        .inner = noop.observer(),
        .ring_buffer = &rb,
        .current_iteration = 2,
    };
    const obs = narr.observer();
    const evt = ObserverEvent{ .tool_call_start = .{ .tool = "bash", .activity_label = "Running tests" } };
    obs.recordEvent(&evt);
    try std.testing.expectEqual(@as(usize, 1), rb.len);
    const frames = try rb.last(std.testing.allocator, 1);
    defer freeRecalledFramesForTest(frames);
    try std.testing.expectEqualStrings("Running tests", frames[0].message);
    try std.testing.expectEqualStrings("bash", frames[0].tool_name.?);
    try std.testing.expectEqual(@as(u32, 2), frames[0].iteration);
}

test "NarrationRingBuffer.last() returns owned strings under concurrent push" {
    // Concurrent UAF regression test (v1.14.18-B G3 deep-copy fix).
    //
    // Before the fix, `last()` returned RecordedFrame slices whose
    // `.message` / `.tool_name` aliased ring-buffer memory. After the
    // mutex dropped, a worker-thread `push()` could recycle a slot,
    // free the old string, and dangle the borrow. With
    // `std.testing.allocator`'s GPA leak/UAF detection, hammering
    // last() + push() concurrently while reading the strings would
    // surface as a use-after-free or a leak (depending on timing).
    //
    // Under the fix, returned frames are deep-copied and fully owned
    // by `out_allocator`. 500 iterations of last() + push() with a
    // string-touching read on every returned frame must show zero
    // leaks and zero UAF.

    const allocator = std.testing.allocator;
    var rb = NarrationRingBuffer.init(allocator);
    defer rb.deinit();

    // Pre-seed with a few frames so `last()` always has something to
    // copy on the first iterations, before the hammer thread has had
    // a chance to push anything.
    var seed_i: usize = 0;
    while (seed_i < 4) : (seed_i += 1) {
        rb.push(.{
            .message = "seed",
            .tool_name = "tool",
            .frame_type = .tool_start,
        }, 0);
    }

    const ThreadCtx = struct {
        rb_ptr: *NarrationRingBuffer,
        stop: *std.atomic.Value(bool),
        fn run(ctx: @This()) void {
            var n: usize = 0;
            while (!ctx.stop.load(.acquire)) : (n +%= 1) {
                ctx.rb_ptr.push(.{
                    .message = "hammer",
                    .tool_name = "thread",
                    .frame_type = .tool_start,
                }, @intCast(n & 0xffff));
            }
        }
    };

    var stop = std.atomic.Value(bool).init(false);
    const hammer = try std.Thread.spawn(.{}, ThreadCtx.run, .{
        ThreadCtx{ .rb_ptr = &rb, .stop = &stop },
    });

    // Main thread: hammer last() + touch the strings. With UAF this
    // would either crash the test runner or surface as a heap probe
    // failure under the GPA's safety mode.
    var iter: usize = 0;
    while (iter < 500) : (iter += 1) {
        const frames = try rb.last(allocator, 3);
        defer freeRecalledFramesForTest(frames);
        for (frames) |f| {
            std.mem.doNotOptimizeAway(f.message.len);
            if (f.tool_name) |t| std.mem.doNotOptimizeAway(t.len);
        }
    }

    stop.store(true, .release);
    hammer.join();
}
