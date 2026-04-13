//! Structured run-event type system for online client consumption.
//!
//! Defines the 8 event kinds from REQ-004 (ready, reply_start, progress,
//! tool_start, tool_result, approval_required, task_update, done) as a
//! tagged union with per-event payloads and an SSE frame serializer.

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
};

pub const ReasoningSummaryPayload = struct {
    summary: []const u8,
    phase: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    iteration: ?u32 = null,
};

pub const ToolStartPayload = struct {
    tool: []const u8,
    tool_use_id: ?[]const u8 = null,
    input_preview: ?[]const u8 = null,
    command: ?[]const u8 = null,
    files: ?[]const []const u8 = null,
    activity_label: ?[]const u8 = null,
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
};

pub const ApprovalRequiredPayload = struct {
    tool: []const u8,
    reason: []const u8,
    risk_level: []const u8,
};

pub const TaskUpdatePayload = struct {
    task_id: []const u8,
    status: []const u8,
    description: ?[]const u8 = null,
    progress_pct: ?u8 = null,
};

pub const DonePayload = struct {
    session_id: ?[]const u8 = null,
    message_id: ?i64 = null,
    usage_tokens: ?u64 = null,
    cost_usd: ?f64 = null,
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
            try w.writeAll("}");
        },
        .approval_required => |p| {
            try w.writeAll("{\"type\":\"approval_required\",\"tool\":\"");
            try jsonEscapeInto(w, p.tool);
            try w.writeAll("\",\"reason\":\"");
            try jsonEscapeInto(w, p.reason);
            try w.writeAll("\",\"risk_level\":\"");
            try jsonEscapeInto(w, p.risk_level);
            try w.writeAll("\"}");
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

test "RunEventType has exactly 9 variants" {
    const fields = @typeInfo(RunEventType).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 9), fields.len);
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
