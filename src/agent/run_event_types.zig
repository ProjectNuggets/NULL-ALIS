//! Structured run-event type system for online client consumption.
//!
//! Defines the 11 *structured* event kinds (ready, reply_start, progress,
//! reasoning_summary, tool_start, tool_result, approval_required,
//! task_update, system_notice, artifact_event, done) as a tagged union
//! with per-event payloads and an SSE frame serializer.
//!
//! ── Transport-only event kinds (NOT modeled here) ────────────────────
//!
//! The gateway also emits 5 additional `event:` kinds on the SSE wire
//! that are intentionally NOT part of this tagged union. They are kept
//! out of `RunEvent` either because they have no structured payload
//! (just an opaque slice) or because they're synthetic frames produced
//! by the SSE transport layer itself, not the agent runtime. FE and
//! out-of-process consumers must handle these directly off the wire.
//!
//! - `token`               — streaming reply text chunk. No `type` field,
//!                           no JSON envelope; the payload is the raw
//!                           token slice. Emitted from gateway.zig at
//!                           the final-reply pump.
//! - `error`               — terminal error frame, always followed by
//!                           `done`. Payload is a JSON error envelope
//!                           with `error.message` + `error.code`.
//! - `audio_reply`         — voice/TTS reply bytes (base64). Emitted
//!                           when `cfg.agent.tts_mode != off`.
//! - `subagent_completion` — async spawn/delegate result delivery (on
//!                           reconnect or async arrival). Carries a
//!                           snapshot of the child task's terminal state.
//! - `tool_only_summary`   — synthetic frame when a turn ran tools but
//!                           produced no user-visible reply. Lets the FE
//!                           render a "no reply, but X tools fired" pill.
//!
//! Gateway emit sites for all 5 are listed in `gateway_run_events.zig`
//! (the bridge module) and `gateway.zig` (the raw emit fallback path).
//! When adding a new structured event with rich JSON payload, promote
//! it to `RunEvent` here. When adding a thin transport-only frame,
//! add it to the list above so the schema stays honest (§14.5).

const std = @import("std");

// ── Event Type Enum ──────────────────────────────────────────────────

pub const RunEventType = enum {
    ready,
    reply_start,
    progress,
    reasoning_summary,
    tool_start,
    tool_result,
    approval_required,
    task_update,
    system_notice,
    /// Wave 2C — canvas/artifacts side-panel notification. Fired by
    /// artifact_create / artifact_update tools so the FE can refresh
    /// the artifacts panel in real time without polling.
    artifact_event,
    done,

    pub fn toSlice(self: RunEventType) []const u8 {
        return switch (self) {
            .ready => "ready",
            .reply_start => "reply_start",
            .progress => "progress",
            .reasoning_summary => "reasoning_summary",
            .tool_start => "tool_start",
            .tool_result => "tool_result",
            .approval_required => "approval_required",
            .task_update => "task_update",
            .system_notice => "system_notice",
            .artifact_event => "artifact_event",
            .done => "done",
        };
    }
};

// ── Payload Structs ──────────────────────────────────────────────────

pub const ReadyPayload = struct {
    session_key: []const u8,
};

pub const ReplyStartPayload = struct {
    stream_kind: []const u8,
    delivery_mode: []const u8,
    live: bool,
};

pub const ProgressPayload = struct {
    phase: []const u8,
    state: []const u8,
    label: []const u8,
    tool: ?[]const u8 = null,
    iteration: ?u32 = null,
    duration_ms: ?u64 = null,
    tool_use_id: ?[]const u8 = null,
    task_id: ?[]const u8 = null,
    group_id: ?[]const u8 = null,
    heartbeat: bool = false,
    command: ?[]const u8 = null,
    files: ?[]const []const u8 = null,
    run_id: ?[]const u8 = null,
};

pub const ReasoningSummaryPayload = struct {
    summary: []const u8,
    phase: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    iteration: ?u32 = null,
    run_id: ?[]const u8 = null,
};

pub const ToolStartPayload = struct {
    tool: []const u8,
    tool_use_id: ?[]const u8 = null,
    input_preview: ?[]const u8 = null,
    command: ?[]const u8 = null,
    files: ?[]const []const u8 = null,
    activity_label: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
};

pub const ToolResultPayload = struct {
    tool: []const u8,
    success: bool,
    duration_ms: u64,
    tool_use_id: ?[]const u8 = null,
    output_preview: ?[]const u8 = null,
    output_truncated: bool = false,
    result_summary: ?[]const u8 = null,
    command: ?[]const u8 = null,
    files: ?[]const []const u8 = null,
    exit_code: ?i32 = null,
    run_id: ?[]const u8 = null,
};

pub const ApprovalRequiredPayload = struct {
    tool: []const u8,
    reason: []const u8,
    risk_level: []const u8,
    approval_id: ?[]const u8 = null,
    id: ?u64 = null,
    tool_call_id: ?[]const u8 = null,
    created_at: ?i64 = null,
    expires_at: ?i64 = null,
    run_id: ?[]const u8 = null,
};

pub const TaskUpdatePayload = struct {
    task_id: []const u8,
    status: []const u8,
    description: ?[]const u8 = null,
    progress_pct: ?u8 = null,
    run_id: ?[]const u8 = null,
};

pub const DonePayload = struct {
    session_id: ?[]const u8 = null,
    message_id: ?i64 = null,
    usage_tokens: ?u64 = null,
    cost_usd: ?f64 = null,
    duration_ms: ?u64 = null,
    run_id: ?[]const u8 = null,
    /// 2026-05-24 (v1.14.20) — spend-meter feed for the zaki-prod
    /// central usage meter (5-hour + weekly windows aggregated across
    /// products). `turn_weight` is the sum of tool cost-classes
    /// dispatched this turn; `session_weight` is the cumulative
    /// across the session so far. Both null when UsageRuntime isn't
    /// wired (standalone CLI / test paths). The FE can render these
    /// as a per-turn "cost" pill + lifetime session total.
    turn_weight: ?u64 = null,
    session_weight: ?u64 = null,
    /// 2026-05-25 (Wave 5 surface-audit fix) — true when the turn ran
    /// tools but produced no user-visible reply (the agent finished
    /// in a tool-only state). The FE renders this as a "no reply, but
    /// X tools fired" indicator instead of an empty bubble. Mirrors
    /// the literal field the gateway already writes inline at the
    /// done frame; promoting it to the schema closes the §14.5
    /// schema-vs-wire honesty gap surfaced in the surface audit.
    tool_only_turn: ?bool = null,
};

/// Wave 2C — artifact side-panel event. Fired when artifact_create
/// or artifact_update lands a new revision. The FE side panel listens
/// for these and pulls the new content via the REST `GET .../artifacts/:id`
/// endpoint — keeping the SSE payload small.
///
/// `op` is "created" | "updated" | "deleted" (string for forward-compat;
/// new ops can land without an enum rev). `version` is the resulting
/// `current_version` after the op.
pub const ArtifactEventPayload = struct {
    op: []const u8,
    artifact_id: []const u8,
    title: []const u8,
    kind: []const u8,
    version: u64,
    url: []const u8,
    change_summary: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
};

/// Binding principle: no silent fallback. When nullalis degrades or has a
/// notable internal state change the user deserves to know about, emit a
/// system_notice. The frontend should render these as chrome (badge / toast)
/// separate from the reply content.
pub const SystemNoticePayload = struct {
    /// Category — compaction | provider_fallback | connector_stale | multimodal_failure | generic.
    /// Add new kinds as distinct surfaces appear. Keep stable so frontend
    /// can style/route per kind.
    kind: []const u8,
    /// info | warning | error.
    severity: []const u8,
    /// Short user-facing message. Keep under 200 chars.
    message: []const u8,
    /// Optional additional detail (tool name, provider name, etc.).
    detail: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
};

// ── RunEvent Tagged Union ────────────────────────────────────────────

pub const RunEvent = union(enum) {
    ready: ReadyPayload,
    reply_start: ReplyStartPayload,
    progress: ProgressPayload,
    reasoning_summary: ReasoningSummaryPayload,
    tool_start: ToolStartPayload,
    tool_result: ToolResultPayload,
    approval_required: ApprovalRequiredPayload,
    task_update: TaskUpdatePayload,
    system_notice: SystemNoticePayload,
    artifact_event: ArtifactEventPayload,
    done: DonePayload,
};

pub fn eventType(event: RunEvent) RunEventType {
    return switch (event) {
        .ready => .ready,
        .reply_start => .reply_start,
        .progress => .progress,
        .reasoning_summary => .reasoning_summary,
        .tool_start => .tool_start,
        .tool_result => .tool_result,
        .approval_required => .approval_required,
        .task_update => .task_update,
        .system_notice => .system_notice,
        .artifact_event => .artifact_event,
        .done => .done,
    };
}

// ── SSE Frame Serializer ─────────────────────────────────────────────

/// Maximum length for output_preview in tool_result events (T-02-01).
const MAX_PREVIEW_LEN: usize = 256;

/// Serialize a RunEvent into an SSE frame: "event: {type}\ndata: {json}\n\n"
pub fn toSseFrame(allocator: std.mem.Allocator, event: RunEvent) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    const evt_type = eventType(event);
    try w.writeAll("event: ");
    try w.writeAll(evt_type.toSlice());
    try w.writeAll("\ndata: ");

    switch (event) {
        .ready => |p| {
            try w.writeAll("{\"type\":\"ready\",\"session_key\":\"");
            try jsonEscapeInto(w, p.session_key);
            try w.writeAll("\"}");
        },
        .reply_start => |p| {
            try w.writeAll("{\"type\":\"reply_start\",\"stream_kind\":\"");
            try jsonEscapeInto(w, p.stream_kind);
            try w.writeAll("\",\"delivery_mode\":\"");
            try jsonEscapeInto(w, p.delivery_mode);
            try w.print("\",\"live\":{s}}}", .{if (p.live) "true" else "false"});
        },
        .progress => |p| {
            try w.writeAll("{\"type\":\"progress\",\"phase\":\"");
            try jsonEscapeInto(w, p.phase);
            try w.writeAll("\",\"state\":\"");
            try jsonEscapeInto(w, p.state);
            try w.writeAll("\",\"label\":\"");
            try jsonEscapeInto(w, p.label);
            try w.writeAll("\"");
            if (p.tool) |tool_name| {
                try w.writeAll(",\"tool\":\"");
                try jsonEscapeInto(w, tool_name);
                try w.writeAll("\"");
            }
            if (p.iteration) |iter| {
                try w.print(",\"iteration\":{d}", .{iter});
            }
            if (p.duration_ms) |dur| {
                try w.print(",\"duration_ms\":{d}", .{dur});
            }
            try writeOptionalStringField(w, "tool_use_id", p.tool_use_id);
            try writeOptionalStringField(w, "task_id", p.task_id);
            try writeOptionalStringField(w, "group_id", p.group_id);
            if (p.heartbeat) {
                try w.writeAll(",\"heartbeat\":true");
            }
            try writeOptionalStringField(w, "command", p.command);
            try writeOptionalStringArrayField(w, "files", p.files);
            try writeOptionalStringField(w, "run_id", p.run_id);
            try w.writeAll("}");
        },
        .reasoning_summary => |p| {
            try w.writeAll("{\"type\":\"reasoning_summary\",\"summary\":\"");
            try jsonEscapeInto(w, p.summary);
            try w.writeAll("\"");
            try writeOptionalStringField(w, "phase", p.phase);
            try writeOptionalStringField(w, "tool", p.tool);
            if (p.iteration) |iter| {
                try w.print(",\"iteration\":{d}", .{iter});
            }
            try writeOptionalStringField(w, "run_id", p.run_id);
            try w.writeAll("}");
        },
        .tool_start => |p| {
            try w.writeAll("{\"type\":\"tool_start\",\"tool\":\"");
            try jsonEscapeInto(w, p.tool);
            try w.writeAll("\"");
            try writeOptionalStringField(w, "tool_use_id", p.tool_use_id);
            try writeOptionalStringField(w, "input_preview", p.input_preview);
            try writeOptionalStringField(w, "command", p.command);
            try writeOptionalStringArrayField(w, "files", p.files);
            try writeOptionalStringField(w, "activity_label", p.activity_label);
            try writeOptionalStringField(w, "run_id", p.run_id);
            try w.writeAll("}");
        },
        .tool_result => |p| {
            try w.writeAll("{\"type\":\"tool_result\",\"tool\":\"");
            try jsonEscapeInto(w, p.tool);
            try w.print("\",\"success\":{s},\"duration_ms\":{d}", .{
                if (p.success) "true" else "false",
                p.duration_ms,
            });
            try writeOptionalStringField(w, "tool_use_id", p.tool_use_id);
            if (p.output_preview) |preview| {
                const truncated = if (preview.len > MAX_PREVIEW_LEN) preview[0..MAX_PREVIEW_LEN] else preview;
                try w.writeAll(",\"output_preview\":\"");
                try jsonEscapeInto(w, truncated);
                try w.writeAll("\"");
                if (p.output_truncated or preview.len > MAX_PREVIEW_LEN) {
                    try w.writeAll(",\"output_truncated\":true");
                }
            }
            try writeOptionalStringField(w, "result_summary", p.result_summary);
            try writeOptionalStringField(w, "command", p.command);
            try writeOptionalStringArrayField(w, "files", p.files);
            if (p.exit_code) |code| {
                try w.print(",\"exit_code\":{d}", .{code});
            }
            try writeOptionalStringField(w, "run_id", p.run_id);
            try w.writeAll("}");
        },
        .approval_required => |p| {
            try w.writeAll("{\"type\":\"approval_required\",\"tool\":\"");
            try jsonEscapeInto(w, p.tool);
            try w.writeAll("\",\"reason\":\"");
            try jsonEscapeInto(w, p.reason);
            try w.writeAll("\",\"risk_level\":\"");
            try jsonEscapeInto(w, p.risk_level);
            try w.writeAll("\"");
            try writeOptionalStringField(w, "approval_id", p.approval_id);
            if (p.id) |id| {
                try w.print(",\"id\":{d}", .{id});
            }
            try writeOptionalStringField(w, "tool_call_id", p.tool_call_id);
            if (p.created_at) |created_at| {
                try w.print(",\"created_at\":{d}", .{created_at});
            }
            if (p.expires_at) |expires_at| {
                try w.print(",\"expires_at\":{d}", .{expires_at});
            }
            try writeOptionalStringField(w, "run_id", p.run_id);
            try w.writeAll("}");
        },
        .task_update => |p| {
            try w.writeAll("{\"type\":\"task_update\",\"task_id\":\"");
            try jsonEscapeInto(w, p.task_id);
            try w.writeAll("\",\"status\":\"");
            try jsonEscapeInto(w, p.status);
            try w.writeAll("\"");
            if (p.description) |desc| {
                try w.writeAll(",\"description\":\"");
                try jsonEscapeInto(w, desc);
                try w.writeAll("\"");
            }
            if (p.progress_pct) |pct| {
                try w.print(",\"progress_pct\":{d}", .{pct});
            }
            try writeOptionalStringField(w, "run_id", p.run_id);
            try w.writeAll("}");
        },
        .system_notice => |p| {
            try w.writeAll("{\"type\":\"system_notice\",\"kind\":\"");
            try jsonEscapeInto(w, p.kind);
            try w.writeAll("\",\"severity\":\"");
            try jsonEscapeInto(w, p.severity);
            try w.writeAll("\",\"message\":\"");
            try jsonEscapeInto(w, p.message);
            try w.writeAll("\"");
            try writeOptionalStringField(w, "detail", p.detail);
            try writeOptionalStringField(w, "run_id", p.run_id);
            try w.writeAll("}");
        },
        .artifact_event => |p| {
            try w.writeAll("{\"type\":\"artifact_event\",\"op\":\"");
            try jsonEscapeInto(w, p.op);
            try w.writeAll("\",\"artifact_id\":\"");
            try jsonEscapeInto(w, p.artifact_id);
            try w.writeAll("\",\"title\":\"");
            try jsonEscapeInto(w, p.title);
            try w.writeAll("\",\"kind\":\"");
            try jsonEscapeInto(w, p.kind);
            try w.print("\",\"version\":{d}", .{p.version});
            try w.writeAll(",\"url\":\"");
            try jsonEscapeInto(w, p.url);
            try w.writeAll("\"");
            try writeOptionalStringField(w, "change_summary", p.change_summary);
            try writeOptionalStringField(w, "run_id", p.run_id);
            try w.writeAll("}");
        },
        .done => |p| {
            try w.writeAll("{\"type\":\"done\"");
            if (p.session_id) |sid| {
                try w.writeAll(",\"session_id\":\"");
                try jsonEscapeInto(w, sid);
                try w.writeAll("\"");
            }
            if (p.message_id) |mid| {
                try w.print(",\"message_id\":\"{d}\"", .{mid});
            }
            if (p.usage_tokens) |tokens| {
                try w.print(",\"usage_tokens\":{d}", .{tokens});
            }
            if (p.cost_usd) |cost| {
                try w.print(",\"cost_usd\":{d:.6}", .{cost});
            }
            if (p.duration_ms) |d| {
                try w.print(",\"duration_ms\":{d}", .{d});
            }
            if (p.turn_weight) |tw| {
                try w.print(",\"turn_weight\":{d}", .{tw});
            }
            if (p.session_weight) |sw| {
                try w.print(",\"session_weight\":{d}", .{sw});
            }
            if (p.tool_only_turn) |tot| {
                try w.print(",\"tool_only_turn\":{s}", .{if (tot) "true" else "false"});
            }
            try writeOptionalStringField(w, "run_id", p.run_id);
            try w.writeAll("}");
        },
    }

    try w.writeAll("\n\n");
    return buf.toOwnedSlice(allocator);
}

// ── JSON Escape Helper ───────────────────────────────────────────────

fn jsonEscapeInto(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
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

fn writeOptionalStringField(writer: anytype, field_name: []const u8, value: ?[]const u8) !void {
    if (value) |text| {
        try writer.writeAll(",\"");
        try writer.writeAll(field_name);
        try writer.writeAll("\":\"");
        try jsonEscapeInto(writer, text);
        try writer.writeAll("\"");
    }
}

fn writeOptionalStringArrayField(writer: anytype, field_name: []const u8, value: ?[]const []const u8) !void {
    if (value) |items| {
        try writer.writeAll(",\"");
        try writer.writeAll(field_name);
        try writer.writeAll("\":[");
        for (items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("\"");
            try jsonEscapeInto(writer, item);
            try writer.writeAll("\"");
        }
        try writer.writeAll("]");
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "RunEventType has exactly 11 structured variants" {
    // Wave 2C adds artifact_event (+1 over the prior 10).
    //
    // The wire SSE surface is LARGER than this enum — the gateway also
    // emits 5 transport-only kinds (`token`, `error`, `audio_reply`,
    // `subagent_completion`, `tool_only_summary`) that intentionally
    // sit outside this tagged union. See the module-level doc block.
    // Total wire-visible kinds = 11 structured + 5 transport-only = 16.
    const fields = @typeInfo(RunEventType).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 11), fields.len);
}

test "RunEventType.toSlice returns correct strings" {
    try std.testing.expectEqualStrings("ready", RunEventType.ready.toSlice());
    try std.testing.expectEqualStrings("reply_start", RunEventType.reply_start.toSlice());
    try std.testing.expectEqualStrings("progress", RunEventType.progress.toSlice());
    try std.testing.expectEqualStrings("reasoning_summary", RunEventType.reasoning_summary.toSlice());
    try std.testing.expectEqualStrings("tool_start", RunEventType.tool_start.toSlice());
    try std.testing.expectEqualStrings("tool_result", RunEventType.tool_result.toSlice());
    try std.testing.expectEqualStrings("approval_required", RunEventType.approval_required.toSlice());
    try std.testing.expectEqualStrings("task_update", RunEventType.task_update.toSlice());
    try std.testing.expectEqualStrings("system_notice", RunEventType.system_notice.toSlice());
    try std.testing.expectEqualStrings("artifact_event", RunEventType.artifact_event.toSlice());
    try std.testing.expectEqualStrings("done", RunEventType.done.toSlice());
}

test "RunEvent.ready payload contains session_key" {
    const event = RunEvent{ .ready = .{ .session_key = "abc-123" } };
    try std.testing.expectEqualStrings("abc-123", event.ready.session_key);
}

test "RunEvent.progress payload has phase, state, label" {
    const event = RunEvent{ .progress = .{
        .phase = "turn_start",
        .state = "update",
        .label = "Gathering context",
    } };
    try std.testing.expectEqualStrings("turn_start", event.progress.phase);
    try std.testing.expectEqualStrings("update", event.progress.state);
    try std.testing.expectEqualStrings("Gathering context", event.progress.label);
}

test "toSseFrame for reasoning_summary preserves safe narration" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .reasoning_summary = .{
        .summary = "Checking context and memory",
        .phase = "thinking",
        .tool = null,
        .iteration = 2,
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: reasoning_summary\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"type\":\"reasoning_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"summary\":\"Checking context and memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"phase\":\"thinking\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"iteration\":2") != null);
}

test "RunEvent.tool_start payload contains tool name" {
    const event = RunEvent{ .tool_start = .{ .tool = "bash" } };
    try std.testing.expectEqualStrings("bash", event.tool_start.tool);
}

test "toSseFrame for tool_start includes safe action metadata" {
    const allocator = std.testing.allocator;
    const files = [_][]const u8{"src/main.zig"};
    const frame = try toSseFrame(allocator, RunEvent{ .tool_start = .{
        .tool = "bash",
        .tool_use_id = "call_1",
        .input_preview = "{\"command\":\"zig build test\"}",
        .command = "zig build test",
        .files = files[0..],
        .activity_label = "Running command",
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: tool_start\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool_use_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"command\":\"zig build test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"files\":[\"src/main.zig\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"activity_label\":\"Running command\"") != null);
}

test "RunEvent.tool_result payload has tool, success, duration_ms" {
    const event = RunEvent{ .tool_result = .{
        .tool = "file_read",
        .success = true,
        .duration_ms = 42,
    } };
    try std.testing.expectEqualStrings("file_read", event.tool_result.tool);
    try std.testing.expect(event.tool_result.success);
    try std.testing.expectEqual(@as(u64, 42), event.tool_result.duration_ms);
}

test "toSseFrame for tool_result includes matching action evidence" {
    const allocator = std.testing.allocator;
    const files = [_][]const u8{"src/main.zig"};
    const frame = try toSseFrame(allocator, RunEvent{ .tool_result = .{
        .tool = "bash",
        .success = true,
        .duration_ms = 42,
        .tool_use_id = "call_1",
        .output_preview = "$ zig build test\nok",
        .result_summary = "completed",
        .command = "zig build test",
        .files = files[0..],
        .exit_code = 0,
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: tool_result\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool_use_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"output_preview\":\"$ zig build test\\nok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"result_summary\":\"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"exit_code\":0") != null);
}

test "RunEvent.task_update payload has task_id, status, description" {
    const event = RunEvent{ .task_update = .{
        .task_id = "t-001",
        .status = "running",
        .description = "Compiling module",
    } };
    try std.testing.expectEqualStrings("t-001", event.task_update.task_id);
    try std.testing.expectEqualStrings("running", event.task_update.status);
    try std.testing.expectEqualStrings("Compiling module", event.task_update.description.?);
}

test "RunEvent.done payload has optional session_id and message_id" {
    const event = RunEvent{ .done = .{
        .session_id = "sess-1",
        .message_id = 12345,
    } };
    try std.testing.expectEqualStrings("sess-1", event.done.session_id.?);
    try std.testing.expectEqual(@as(i64, 12345), event.done.message_id.?);
}

test "toSseFrame produces correct SSE format for ready event" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .ready = .{ .session_key = "test-key" } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: ready\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"session_key\":\"test-key\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, frame, "\n\n"));
}

test "toSseFrame for progress matches gateway format" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .progress = .{
        .phase = "dispatch_tools",
        .state = "update",
        .label = "Running tools",
        .tool = "bash",
        .iteration = 3,
        .duration_ms = 150,
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: progress\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"phase\":\"dispatch_tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"iteration\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"duration_ms\":150") != null);
}

test "toSseFrame for progress includes heartbeat and group metadata" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .progress = .{
        .phase = "thinking",
        .state = "update",
        .label = "Still working on the reply",
        .tool_use_id = "call_1",
        .task_id = "task_1",
        .group_id = "group_1",
        .heartbeat = true,
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool_use_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"task_id\":\"task_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"group_id\":\"group_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"heartbeat\":true") != null);
}

test "toSseFrame for done event" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .done = .{
        .session_id = "s1",
        .message_id = 99,
        .usage_tokens = 1500,
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: done\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"session_id\":\"s1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"usage_tokens\":1500") != null);
}

test "toSseFrame for done emits tool_only_turn when set" {
    // Wave 5 surface-audit fix — DonePayload now declares
    // tool_only_turn explicitly. Lock the wire shape so the
    // schema and gateway stay in sync.
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .done = .{
        .session_id = "s1",
        .tool_only_turn = true,
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool_only_turn\":true") != null);
}

test "toSseFrame for done omits tool_only_turn when null" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .done = .{
        .session_id = "s1",
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "tool_only_turn") == null);
}

test "toSseFrame for done emits tool_only_turn false explicitly" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .done = .{
        .session_id = "s1",
        .tool_only_turn = false,
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool_only_turn\":false") != null);
}

test "toSseFrame truncates output_preview to 256 chars" {
    const allocator = std.testing.allocator;
    const long_preview = "A" ** 512;
    const frame = try toSseFrame(allocator, RunEvent{ .tool_result = .{
        .tool = "bash",
        .success = true,
        .duration_ms = 10,
        .output_preview = long_preview,
    } });
    defer allocator.free(frame);
    // The output_preview in the frame should be truncated
    // Count the A's in the output — should be MAX_PREVIEW_LEN (256)
    var a_count: usize = 0;
    const data_start = std.mem.indexOf(u8, frame, "\"output_preview\":\"") orelse 0;
    if (data_start > 0) {
        const preview_start = data_start + "\"output_preview\":\"".len;
        var i = preview_start;
        while (i < frame.len and frame[i] == 'A') : (i += 1) {
            a_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, MAX_PREVIEW_LEN), a_count);
}

test "eventType returns correct RunEventType" {
    try std.testing.expectEqual(RunEventType.ready, eventType(RunEvent{ .ready = .{ .session_key = "x" } }));
    try std.testing.expectEqual(RunEventType.done, eventType(RunEvent{ .done = .{} }));
    try std.testing.expectEqual(RunEventType.tool_start, eventType(RunEvent{ .tool_start = .{ .tool = "y" } }));
    try std.testing.expectEqual(RunEventType.task_update, eventType(RunEvent{ .task_update = .{ .task_id = "t", .status = "queued" } }));
}

test "toSseFrame escapes special characters in JSON" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .ready = .{ .session_key = "key\"with\\special\nchars" } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\\\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\\n") != null);
}

test "toSseFrame for reply_start" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .reply_start = .{
        .stream_kind = "final_reply",
        .delivery_mode = "streaming",
        .live = true,
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: reply_start\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"stream_kind\":\"final_reply\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"live\":true") != null);
}

test "toSseFrame for approval_required" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .approval_required = .{
        .tool = "bash",
        .reason = "destructive command",
        .risk_level = "high",
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: approval_required\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"risk_level\":\"high\"") != null);
}

test "toSseFrame includes run_id when set on tool_start" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .tool_start = .{
        .tool = "bash",
        .tool_use_id = "call_1",
        .run_id = "r-100-1",
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool_use_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"run_id\":\"r-100-1\"") != null);
}

test "toSseFrame omits run_id when null on tool_start" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .tool_start = .{
        .tool = "bash",
        .tool_use_id = "call_2",
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"run_id\"") == null);
}

test "toSseFrame includes run_id when set on tool_result" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .tool_result = .{
        .tool = "bash",
        .success = true,
        .duration_ms = 5,
        .tool_use_id = "call_1",
        .run_id = "r-100-1",
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool_use_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"run_id\":\"r-100-1\"") != null);
}

test "toSseFrame omits run_id when null on tool_result" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .tool_result = .{
        .tool = "bash",
        .success = true,
        .duration_ms = 5,
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"run_id\"") == null);
}

test "toSseFrame includes run_id when set on approval_required" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .approval_required = .{
        .tool = "bash",
        .reason = "supervised_mutating_requires_approval",
        .risk_level = "critical",
        .run_id = "r-200-3",
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"risk_level\":\"critical\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"run_id\":\"r-200-3\"") != null);
}

test "toSseFrame includes canonical approval fields on approval_required" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .approval_required = .{
        .tool = "produce_document",
        .reason = "supervised_mutating_requires_approval",
        .risk_level = "medium",
        .approval_id = "apr-7",
        .id = 7,
        .tool_call_id = "call_doc",
        .created_at = 1770000000,
        .expires_at = 1770000060,
        .run_id = "r-200-4",
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"approval_id\":\"apr-7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool_call_id\":\"call_doc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"created_at\":1770000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"expires_at\":1770000060") != null);
}

test "toSseFrame omits run_id when null on approval_required" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .approval_required = .{
        .tool = "bash",
        .reason = "x",
        .risk_level = "low",
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"run_id\"") == null);
}

test "toSseFrame includes run_id when set on progress" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .progress = .{
        .phase = "thinking",
        .state = "start",
        .label = "Thinking",
        .run_id = "r-300-9",
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"run_id\":\"r-300-9\"") != null);
}

test "toSseFrame omits run_id when null on progress" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .progress = .{
        .phase = "thinking",
        .state = "start",
        .label = "Thinking",
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"run_id\"") == null);
}

test "toSseFrame for task_update with progress_pct" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .task_update = .{
        .task_id = "t-42",
        .status = "running",
        .description = "Building",
        .progress_pct = 75,
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"progress_pct\":75") != null);
}

// Wave 2C — canvas/artifacts SSE event serializer round-trip. Pins
// the wire shape that the FE side-panel listens for.
test "toSseFrame for artifact_event serializes all fields" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .artifact_event = .{
        .op = "created",
        .artifact_id = "abc-uuid",
        .title = "Quarterly plan",
        .kind = "markdown",
        .version = 1,
        .url = "/api/v1/users/42/artifacts/abc-uuid",
        .change_summary = "first draft",
        .run_id = "r-9",
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: artifact_event\n"));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"op\":\"created\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"artifact_id\":\"abc-uuid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"title\":\"Quarterly plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"kind\":\"markdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"url\":\"/api/v1/users/42/artifacts/abc-uuid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"change_summary\":\"first draft\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"run_id\":\"r-9\"") != null);
}

test "toSseFrame for artifact_event omits optional fields when null" {
    const allocator = std.testing.allocator;
    const frame = try toSseFrame(allocator, RunEvent{ .artifact_event = .{
        .op = "updated",
        .artifact_id = "id-1",
        .title = "t",
        .kind = "code",
        .version = 5,
        .url = "/api/v1/users/1/artifacts/id-1",
    } });
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"change_summary\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"run_id\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"version\":5") != null);
}
