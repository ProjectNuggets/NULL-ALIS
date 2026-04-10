//! Task decomposition — parses <task_plan> XML from LLM responses and tracks step execution.
//!
//! The LLM emits a structured plan block when instructed by the system prompt.
//! This module extracts the plan, tracks per-step status, and emits observer
//! events for narration.
//!
//! SECURITY (T-1.5-05): parseTaskPlan uses bounded scanning with the same
//! pattern as dispatcher.zig. Malformed input returns null, never panics.
//! Step count is implicitly bounded by response length.

const std = @import("std");
const observability = @import("../observability.zig");
const ObserverEvent = observability.ObserverEvent;
const Observer = observability.Observer;
const NarrationFrameType = observability.NarrationFrameType;

// ─── Step status ──────────────────────────────────────────────────────────────

pub const StepStatus = enum {
    pending,
    running,
    done,
    failed,

    pub fn toSlice(self: StepStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .done => "done",
            .failed => "failed",
        };
    }
};

// ─── Types ────────────────────────────────────────────────────────────────────

pub const TaskStep = struct {
    index: u32,
    description: []const u8,
    status: StepStatus = .pending,
    tool_used: ?[]const u8 = null,
    result_summary: ?[]const u8 = null,
};

pub const TaskPlan = struct {
    summary: []const u8,
    steps: []TaskStep,
    current_step: u32 = 0,

    pub fn stepCount(self: *const TaskPlan) u32 {
        return @intCast(self.steps.len);
    }

    pub fn currentStep(self: *TaskPlan) ?*TaskStep {
        if (self.current_step < self.steps.len) return &self.steps[self.current_step];
        return null;
    }

    pub fn markStepRunning(self: *TaskPlan) void {
        if (self.currentStep()) |step| step.status = .running;
    }

    pub fn markStepDone(self: *TaskPlan, result_summary: ?[]const u8) void {
        if (self.currentStep()) |step| {
            step.status = .done;
            step.result_summary = result_summary;
        }
    }

    pub fn markStepFailed(self: *TaskPlan) void {
        if (self.currentStep()) |step| step.status = .failed;
    }

    pub fn advanceStep(self: *TaskPlan) void {
        if (self.current_step < self.steps.len) self.current_step += 1;
    }

    pub fn isComplete(self: *const TaskPlan) bool {
        for (self.steps) |step| {
            if (step.status != .done and step.status != .failed) return false;
        }
        return true;
    }

    pub fn deinit(self: *TaskPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        for (self.steps) |step| {
            allocator.free(step.description);
        }
        allocator.free(self.steps);
    }
};

/// Result of splitting response text from its embedded <task_plan> block.
pub const ExtractResult = struct {
    /// Text outside the <task_plan> block (before + after), trimmed.
    text: []const u8,
    /// Raw content inside <task_plan>...</task_plan>, or null if no block found.
    plan_xml: ?[]const u8,
};

// ─── XML tag scanner helpers ───────────────────────────────────────────────────

/// Scan for content between open_tag and close_tag starting at `cursor`.
/// Returns {inner_start, inner_end, next_cursor} or null if open_tag not found.
/// Does NOT allocate — returns slices into `haystack`.
fn scanTagPair(
    haystack: []const u8,
    cursor: usize,
    open_tag: []const u8,
    close_tag: []const u8,
) ?struct { inner_start: usize, inner_end: usize, next_cursor: usize } {
    const open_pos = std.mem.indexOfPos(u8, haystack, cursor, open_tag) orelse return null;
    const inner_start = open_pos + open_tag.len;
    const close_pos = std.mem.indexOfPos(u8, haystack, inner_start, close_tag) orelse {
        // Unclosed tag — treat rest of string as content (bounded by response length).
        return .{
            .inner_start = inner_start,
            .inner_end = haystack.len,
            .next_cursor = haystack.len,
        };
    };
    return .{
        .inner_start = inner_start,
        .inner_end = close_pos,
        .next_cursor = close_pos + close_tag.len,
    };
}

// ─── Public API ───────────────────────────────────────────────────────────────

/// Split an LLM response into its text portion and embedded <task_plan> XML.
///
/// The function scans for the first <task_plan>...</task_plan> block.
/// Text before and after the block is trimmed and returned as `text`.
/// The raw content between the tags is returned as `plan_xml`.
///
/// If no <task_plan> tag is found, the full response is returned as `text`
/// with `plan_xml = null`. Never allocates; returned slices are into `response`.
pub fn extractTextAndPlan(response: []const u8) ExtractResult {
    const open_tag = "<task_plan>";
    const close_tag = "</task_plan>";

    const open_pos = std.mem.indexOf(u8, response, open_tag) orelse {
        return .{ .text = response, .plan_xml = null };
    };

    const inner_start = open_pos + open_tag.len;
    const close_pos = std.mem.indexOf(u8, response[inner_start..], close_tag);

    const text_before = std.mem.trim(u8, response[0..open_pos], " \t\r\n");

    if (close_pos) |rel_close| {
        const abs_close = inner_start + rel_close;
        const plan_xml = response[inner_start..abs_close];
        const after_close = abs_close + close_tag.len;
        const text_after = std.mem.trim(u8, response[after_close..], " \t\r\n");

        // Combine before + after as the text portion (separated by newline when both non-empty).
        // Since we return slices into `response` we can only return one slice. We choose the
        // longer of the two unless before is empty, in which case we return after (and vice-versa).
        // Both-non-empty case: caller can reconstruct from offsets; we return `text_before` as
        // the canonical text slice for now (common: plan appears at start of response).
        const text: []const u8 = if (text_before.len > 0)
            text_before
        else
            text_after;

        return .{ .text = text, .plan_xml = plan_xml };
    } else {
        // Unclosed tag — no plan_xml
        return .{ .text = std.mem.trim(u8, response[0..open_pos], " \t\r\n"), .plan_xml = null };
    }
}

/// Parse the XML content of a <task_plan> block into a TaskPlan.
///
/// Expected format (content between <task_plan> tags):
/// ```xml
/// <summary>Brief description</summary>
/// <step>First step description</step>
/// <step>Second step description</step>
/// ```
///
/// Returns null on malformed input (missing summary, no steps, or empty content).
/// Never panics. Allocates owned copies of all strings.
pub fn parseTaskPlan(allocator: std.mem.Allocator, plan_xml: []const u8) !?TaskPlan {
    const trimmed = std.mem.trim(u8, plan_xml, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Extract <summary>...</summary>
    const summary_result = scanTagPair(trimmed, 0, "<summary>", "</summary>") orelse return null;
    const summary_raw = std.mem.trim(u8, trimmed[summary_result.inner_start..summary_result.inner_end], " \t\r\n");
    if (summary_raw.len == 0) return null;

    // Collect all <step>...</step> pairs
    var steps: std.ArrayListUnmanaged(TaskStep) = .empty;
    errdefer {
        for (steps.items) |step| allocator.free(step.description);
        steps.deinit(allocator);
    }

    var cursor: usize = 0;
    while (scanTagPair(trimmed, cursor, "<step>", "</step>")) |result| {
        const desc_raw = std.mem.trim(u8, trimmed[result.inner_start..result.inner_end], " \t\r\n");
        if (desc_raw.len > 0) {
            const desc = try allocator.dupe(u8, desc_raw);
            try steps.append(allocator, TaskStep{
                .index = @intCast(steps.items.len),
                .description = desc,
            });
        }
        cursor = result.next_cursor;
        if (cursor >= trimmed.len) break;
    }

    if (steps.items.len == 0) {
        return null;
    }

    const summary = try allocator.dupe(u8, summary_raw);
    errdefer allocator.free(summary);

    return TaskPlan{
        .summary = summary,
        .steps = try steps.toOwnedSlice(allocator),
        .current_step = 0,
    };
}

/// Emit a narration_frame event for the current step in `plan`.
///
/// Emits a plan_step frame with:
/// - message: current step description (or empty if plan exhausted)
/// - frame_type: .plan_step
/// - step_index: plan.current_step
/// - step_total: plan.stepCount()
pub fn emitStepEvent(observer: Observer, plan: *const TaskPlan) void {
    const message: []const u8 = if (plan.current_step < plan.steps.len)
        plan.steps[plan.current_step].description
    else
        "";

    const event = ObserverEvent{ .narration_frame = .{
        .message = message,
        .frame_type = NarrationFrameType.plan_step,
        .tool_name = null,
        .step_index = plan.current_step,
        .step_total = plan.stepCount(),
    } };
    observer.recordEvent(&event);
}

// ─── Inline tests ─────────────────────────────────────────────────────────────

test "parseTaskPlan with valid XML returns correct step count and descriptions" {
    const xml =
        \\<summary>Do the thing</summary>
        \\<step>Alpha</step>
        \\<step>Beta</step>
        \\<step>Gamma</step>
    ;
    const plan = (try parseTaskPlan(std.testing.allocator, xml)) orelse return error.TestUnexpectedNull;
    var p = plan;
    defer p.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3), p.stepCount());
    try std.testing.expectEqualStrings("Do the thing", p.summary);
    try std.testing.expectEqualStrings("Alpha", p.steps[0].description);
    try std.testing.expectEqualStrings("Beta", p.steps[1].description);
    try std.testing.expectEqualStrings("Gamma", p.steps[2].description);
}

test "parseTaskPlan with no task_plan tag returns null" {
    const plan = try parseTaskPlan(std.testing.allocator, "");
    try std.testing.expect(plan == null);
}

test "parseTaskPlan with missing summary returns null" {
    const xml = "<step>Only step</step>";
    const plan = try parseTaskPlan(std.testing.allocator, xml);
    try std.testing.expect(plan == null);
}

test "parseTaskPlan with no steps returns null" {
    const xml = "<summary>Has summary but no steps</summary>";
    const plan = try parseTaskPlan(std.testing.allocator, xml);
    try std.testing.expect(plan == null);
}

test "parseTaskPlan with malformed XML returns null not panic" {
    const cases = [_][]const u8{
        "not xml at all",
        "<summary>unclosed",
        "<step>no summary step</step>",
        "<<>>",
        "<summary></summary><step></step>", // empty summary and step
    };
    for (cases) |xml| {
        const plan = try parseTaskPlan(std.testing.allocator, xml);
        try std.testing.expect(plan == null);
    }
}

test "TaskStep status transitions: pending -> running -> done" {
    const xml =
        \\<summary>test</summary>
        \\<step>step 0</step>
    ;
    const plan = (try parseTaskPlan(std.testing.allocator, xml)) orelse return error.TestUnexpectedNull;
    var p = plan;
    defer p.deinit(std.testing.allocator);

    try std.testing.expectEqual(StepStatus.pending, p.steps[0].status);

    p.markStepRunning();
    try std.testing.expectEqual(StepStatus.running, p.steps[0].status);

    p.markStepDone(null);
    try std.testing.expectEqual(StepStatus.done, p.steps[0].status);
}

test "TaskStep status transitions: running -> failed" {
    const xml =
        \\<summary>test</summary>
        \\<step>step 0</step>
    ;
    const plan = (try parseTaskPlan(std.testing.allocator, xml)) orelse return error.TestUnexpectedNull;
    var p = plan;
    defer p.deinit(std.testing.allocator);

    p.markStepRunning();
    try std.testing.expectEqual(StepStatus.running, p.steps[0].status);

    p.markStepFailed();
    try std.testing.expectEqual(StepStatus.failed, p.steps[0].status);
}

test "advanceStep increments current_step correctly for 3-step plan" {
    const xml =
        \\<summary>Three-step plan</summary>
        \\<step>Step 1</step>
        \\<step>Step 2</step>
        \\<step>Step 3</step>
    ;
    const plan = (try parseTaskPlan(std.testing.allocator, xml)) orelse return error.TestUnexpectedNull;
    var p = plan;
    defer p.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), p.current_step);
    p.advanceStep();
    try std.testing.expectEqual(@as(u32, 1), p.current_step);
    p.advanceStep();
    try std.testing.expectEqual(@as(u32, 2), p.current_step);
    p.advanceStep();
    try std.testing.expectEqual(@as(u32, 3), p.current_step); // past last
}

test "isComplete returns true when all steps done" {
    const xml =
        \\<summary>Two-step plan</summary>
        \\<step>Step 1</step>
        \\<step>Step 2</step>
    ;
    const plan = (try parseTaskPlan(std.testing.allocator, xml)) orelse return error.TestUnexpectedNull;
    var p = plan;
    defer p.deinit(std.testing.allocator);

    try std.testing.expect(!p.isComplete());

    p.markStepDone(null);
    p.advanceStep();
    try std.testing.expect(!p.isComplete());

    p.markStepDone(null);
    p.advanceStep();
    try std.testing.expect(p.isComplete());
}

test "isComplete returns true when steps mix done and failed" {
    const xml =
        \\<summary>Two-step plan</summary>
        \\<step>Step 1</step>
        \\<step>Step 2</step>
    ;
    const plan = (try parseTaskPlan(std.testing.allocator, xml)) orelse return error.TestUnexpectedNull;
    var p = plan;
    defer p.deinit(std.testing.allocator);

    p.markStepDone(null);
    p.advanceStep();
    p.markStepFailed();
    p.advanceStep();
    try std.testing.expect(p.isComplete());
}

test "extractTextAndPlan splits text from task_plan block" {
    const response = "Here is my plan:\n<task_plan>\n<summary>Test</summary>\n<step>A</step>\n</task_plan>\nAnd now I will execute.";
    const result = extractTextAndPlan(response);

    try std.testing.expect(result.plan_xml != null);
    try std.testing.expect(std.mem.indexOf(u8, result.plan_xml.?, "<summary>Test</summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.plan_xml.?, "<step>A</step>") != null);
    // Text portion should not contain the task_plan tags
    try std.testing.expect(std.mem.indexOf(u8, result.text, "<task_plan>") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "</task_plan>") == null);
}

test "extractTextAndPlan with no task_plan returns full text and null plan_xml" {
    const response = "Just a plain response with no plan.";
    const result = extractTextAndPlan(response);

    try std.testing.expect(result.plan_xml == null);
    try std.testing.expectEqualStrings(response, result.text);
}

test "StepStatus toSlice covers all variants" {
    try std.testing.expectEqualStrings("pending", StepStatus.pending.toSlice());
    try std.testing.expectEqualStrings("running", StepStatus.running.toSlice());
    try std.testing.expectEqualStrings("done", StepStatus.done.toSlice());
    try std.testing.expectEqualStrings("failed", StepStatus.failed.toSlice());
}
