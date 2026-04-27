const std = @import("std");
const providers = @import("../providers/root.zig");

// ═══════════════════════════════════════════════════════════════════════════
// Dispatcher — tool call parsing and result formatting
// ═══════════════════════════════════════════════════════════════════════════

/// A parsed tool call extracted from an LLM response.
pub const ParsedToolCall = struct {
    name: []const u8,
    /// Raw JSON arguments string.
    arguments_json: []const u8,
    /// Optional tool_call_id for native tool-calling APIs.
    tool_call_id: ?[]const u8 = null,
};

/// Result of parsing tool calls from an LLM response: text content and extracted calls.
pub const ParseResult = struct {
    text: []const u8,
    calls: []ParsedToolCall,
};

/// Result of executing a single tool.
pub const ToolExecutionResult = struct {
    name: []const u8,
    output: []const u8,
    success: bool,
    tool_call_id: ?[]const u8 = null,
};

/// Parse tool calls from an LLM response.
///
/// Two parsing paths (matching ZeroClaw's Rust implementation):
/// 1. First, try parsing as OpenAI native JSON format `{"tool_calls": [...]}`
/// 2. Fall back to XML `<tool_call>` tag parsing
///
/// Returns text portions (joined by newline) and extracted tool calls.
pub fn parseToolCalls(
    allocator: std.mem.Allocator,
    response: []const u8,
) !ParseResult {
    // First: try OpenAI native JSON format {"tool_calls": [...]}
    if (isNativeJsonFormat(response)) {
        const native = parseNativeToolCalls(allocator, response) catch null;
        if (native) |result| {
            if (result.calls.len > 0) return result;
            // No calls found in native format — free and fall through to XML
            allocator.free(result.text);
            allocator.free(result.calls);
        }
    }
    // Second: try XML <tool_call> tag parsing (ZeroClaw / OpenClaw format)
    const tool_call_result = try parseXmlToolCalls(allocator, response);
    if (tool_call_result.calls.len > 0) return tool_call_result;

    // Third: Anthropic-legacy `<invoke name="X"><parameter name="Y">Z</parameter></invoke>`.
    // Some Kimi / Qwen / other models fall back to this format when native
    // function calling isn't engaged or when the model's training data skews
    // toward Anthropic's older XML tool-use docs. Parsing it recovers real
    // tool invocations instead of leaving them as inert text in the reply.
    if (std.mem.indexOf(u8, response, "<invoke ") != null or std.mem.indexOf(u8, response, "<invoke\t") != null) {
        const invoke_result = try parseInvokeXmlToolCalls(allocator, response);
        if (invoke_result.calls.len > 0) {
            // Free the empty tool_call result before returning the invoke result.
            allocator.free(tool_call_result.text);
            allocator.free(tool_call_result.calls);
            return invoke_result;
        }
        // <invoke> present but parse produced no calls — free it and fall through.
        allocator.free(invoke_result.text);
        allocator.free(invoke_result.calls);
    }

    return tool_call_result;
}

/// Parse `<invoke name="X"><parameter name="Y">Z</parameter>...</invoke>` segments
/// (Anthropic-legacy XML tool-use format). Also accepts a raw JSON object body
/// inside `<invoke name="X">{...}</invoke>` as some models emit that shape.
///
/// Returns a ParseResult where `text` is the response with all `<invoke>...</invoke>`
/// segments removed and `calls` is the parsed tool calls.
pub fn parseInvokeXmlToolCalls(
    allocator: std.mem.Allocator,
    response: []const u8,
) !ParseResult {
    const open_prefix = "<invoke ";
    const close_tag = "</invoke>";

    var text_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer text_parts.deinit(allocator);

    var calls: std.ArrayListUnmanaged(ParsedToolCall) = .empty;
    errdefer {
        for (calls.items) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        calls.deinit(allocator);
    }

    var cursor: usize = 0;

    while (std.mem.indexOfPos(u8, response, cursor, open_prefix)) |start| {
        const before = std.mem.trim(u8, response[cursor..start], " \t\r\n");
        if (before.len > 0) try text_parts.append(allocator, before);

        // Find the closing `>` of the <invoke ...> opening tag.
        const tag_end_opt = std.mem.indexOfPos(u8, response, start + open_prefix.len, ">");
        if (tag_end_opt == null) break;
        const tag_end = tag_end_opt.?;

        // Extract the `name="..."` attribute value.
        const open_slice = response[start..tag_end];
        const name_opt = extractXmlAttribute(open_slice, "name");

        const inner_start = tag_end + 1;
        const close_idx_opt = std.mem.indexOfPos(u8, response, inner_start, close_tag);
        if (close_idx_opt == null) break;
        const close_idx = close_idx_opt.?;
        const inner = std.mem.trim(u8, response[inner_start..close_idx], " \t\r\n");

        if (name_opt) |name| {
            const arguments_json = try buildInvokeArgumentsJson(allocator, inner);
            try calls.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .arguments_json = arguments_json,
                .tool_call_id = null,
            });
        }

        cursor = close_idx + close_tag.len;
    }

    const trailing = std.mem.trim(u8, response[cursor..], " \t\r\n");
    if (trailing.len > 0) try text_parts.append(allocator, trailing);

    const text = if (text_parts.items.len == 0)
        try allocator.dupe(u8, "")
    else
        try std.mem.join(allocator, "\n", text_parts.items);

    return .{
        .text = text,
        .calls = try calls.toOwnedSlice(allocator),
    };
}

/// Extract the value of an XML attribute (attr="value") from an opening tag slice.
/// Returns null if not found or malformed. Only handles double-quoted values.
fn extractXmlAttribute(tag_slice: []const u8, attr: []const u8) ?[]const u8 {
    var search_key_buf: [64]u8 = undefined;
    if (attr.len + 2 > search_key_buf.len) return null;
    const search_key = std.fmt.bufPrint(&search_key_buf, "{s}=\"", .{attr}) catch return null;
    const key_idx = std.mem.indexOf(u8, tag_slice, search_key) orelse return null;
    const value_start = key_idx + search_key.len;
    const value_end_rel = std.mem.indexOfScalar(u8, tag_slice[value_start..], '"') orelse return null;
    return tag_slice[value_start .. value_start + value_end_rel];
}

/// Build a JSON object string from the inner content of an `<invoke>` tag.
/// - If inner is already a JSON object `{...}`, return it directly.
/// - Otherwise parse `<parameter name="K">V</parameter>` segments into a JSON object.
/// - If neither applies, return `{}`.
fn buildInvokeArgumentsJson(allocator: std.mem.Allocator, inner: []const u8) ![]const u8 {
    // Case 1: raw JSON object.
    if (extractJsonObject(inner)) |json_slice| {
        const trimmed = std.mem.trim(u8, json_slice, " \t\r\n");
        if (trimmed.ptr == inner.ptr and trimmed.len == inner.len) {
            return try allocator.dupe(u8, trimmed);
        }
    }

    // Case 2: <parameter name="K">V</parameter> segments.
    const param_open_prefix = "<parameter ";
    const param_close_tag = "</parameter>";

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');

    var cursor: usize = 0;
    var first = true;

    while (std.mem.indexOfPos(u8, inner, cursor, param_open_prefix)) |p_start| {
        const tag_end_opt = std.mem.indexOfPos(u8, inner, p_start + param_open_prefix.len, ">");
        if (tag_end_opt == null) break;
        const tag_end = tag_end_opt.?;
        const open_slice = inner[p_start..tag_end];
        const param_name = extractXmlAttribute(open_slice, "name") orelse {
            cursor = tag_end + 1;
            continue;
        };

        const value_start = tag_end + 1;
        const close_idx_opt = std.mem.indexOfPos(u8, inner, value_start, param_close_tag);
        if (close_idx_opt == null) break;
        const close_idx = close_idx_opt.?;
        const value = std.mem.trim(u8, inner[value_start..close_idx], " \t\r\n");

        if (!first) try out.append(allocator, ',');
        first = false;
        try out.append(allocator, '"');
        try appendJsonEscaped(&out, allocator, param_name);
        try out.appendSlice(allocator, "\":");
        // If the value is already JSON-shaped (starts with { [ " digit t f n -), inline it.
        // Otherwise quote it as a string.
        if (valueLooksLikeJson(value)) {
            try out.appendSlice(allocator, value);
        } else {
            try out.append(allocator, '"');
            try appendJsonEscaped(&out, allocator, value);
            try out.append(allocator, '"');
        }

        cursor = close_idx + param_close_tag.len;
    }

    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

fn valueLooksLikeJson(value: []const u8) bool {
    if (value.len == 0) return false;
    const c = value[0];
    if (c == '{' or c == '[' or c == '"') return true;
    if (c == '-' or (c >= '0' and c <= '9')) return true;
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "null")) return true;
    return false;
}

fn appendJsonEscaped(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
}

/// Parse tool calls from an LLM response using XML-style `<tool_call>` tags.
///
/// Expected format:
/// ```
/// Some text
/// <tool_call>
/// {"name": "shell", "arguments": {"command": "ls"}}
/// </tool_call>
/// More text
/// ```
///
/// Returns text portions (joined by newline) and extracted tool calls.
///
/// SECURITY: This function only extracts JSON from within explicit `<tool_call>` tags.
/// It does NOT parse raw JSON from the response body, which prevents prompt injection
/// where malicious content could include JSON mimicking a tool call.
pub fn parseXmlToolCalls(
    allocator: std.mem.Allocator,
    response: []const u8,
) !ParseResult {
    const open_tag = "<tool_call>";
    const close_tag = "</tool_call>";

    var text_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer text_parts.deinit(allocator);

    var calls: std.ArrayListUnmanaged(ParsedToolCall) = .empty;
    errdefer {
        for (calls.items) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        calls.deinit(allocator);
    }

    var cursor: usize = 0;

    while (std.mem.indexOfPos(u8, response, cursor, open_tag)) |start| {
        // Text before the tag
        const before = std.mem.trim(u8, response[cursor..start], " \t\r\n");
        if (before.len > 0) {
            try text_parts.append(allocator, before);
        }

        const inner_start = start + open_tag.len;
        const close_idx = std.mem.indexOfPos(u8, response, inner_start, close_tag);
        const next_open_idx = std.mem.indexOfPos(u8, response, inner_start, open_tag);

        var inner_end: usize = response.len;
        var next_cursor: usize = response.len;
        var last_unclosed_segment = false;

        if (close_idx) |close_pos| {
            if (next_open_idx) |next_pos| {
                if (next_pos < close_pos) {
                    // Malformed output: a new <tool_call> starts before the first close.
                    // Treat this segment as one call and continue at the next opening tag.
                    inner_end = next_pos;
                    next_cursor = next_pos;
                } else {
                    inner_end = close_pos;
                    next_cursor = close_pos + close_tag.len;
                }
            } else {
                inner_end = close_pos;
                next_cursor = close_pos + close_tag.len;
            }
        } else if (next_open_idx) |next_pos| {
            // Unclosed call followed by another opening tag — still try to parse
            // this segment to avoid leaking raw tool JSON to users.
            inner_end = next_pos;
            next_cursor = next_pos;
        } else {
            // Last unclosed tag at end-of-response.
            inner_end = response.len;
            next_cursor = response.len;
            last_unclosed_segment = true;
        }

        const inner = std.mem.trim(u8, response[inner_start..inner_end], " \t\r\n");

        var should_parse_inner = inner.len > 0;
        if (should_parse_inner and last_unclosed_segment) {
            // Keep historical safety for trailing prose after an unclosed tag:
            // parse only if the remaining segment is a standalone JSON object.
            should_parse_inner = false;
            if (extractJsonObject(inner)) |json_slice| {
                const json_trimmed = std.mem.trim(u8, json_slice, " \t\r\n");
                if (json_trimmed.ptr == inner.ptr and json_trimmed.len == inner.len) {
                    should_parse_inner = true;
                }
            }
        }

        if (should_parse_inner) {
            // Try to extract JSON object from inner content (may have markdown fences or preamble text)
            // Then fall back to <function=name><parameter=key>value</parameter></function> format
            var call_parsed = false;
            if (extractJsonObject(inner)) |json_slice| {
                if (parseToolCallJson(allocator, json_slice)) |call| {
                    try calls.append(allocator, call);
                    call_parsed = true;
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                }
            }
            if (!call_parsed) {
                if (parseFunctionTagCall(allocator, inner)) |call| {
                    try calls.append(allocator, call);
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                }
            }
        }

        if (next_cursor <= cursor) break;
        cursor = next_cursor;
    }

    // Remaining text after last tool call
    const trailing = std.mem.trim(u8, response[cursor..], " \t\r\n");
    if (trailing.len > 0) {
        try text_parts.append(allocator, trailing);
    }

    // Join text parts
    const text = if (text_parts.items.len == 0)
        ""
    else
        try std.mem.join(allocator, "\n", text_parts.items);

    return .{
        .text = text,
        .calls = try calls.toOwnedSlice(allocator),
    };
}

/// Maximum characters per individual tool result output before truncation.
///
/// **R11 raise (2026-04-27):** bumped from 8000 → 24000 after researcher
/// pass found 8KB code files (e.g. `lane_metrics.zig` at 8.8KB) being
/// truncated by ~10% — too aggressive for code review workflows. 24KB
/// covers ~600 lines of typical Zig source while still leaving plenty
/// of context budget on Kimi K2.5's 256K window (a single tool result
/// at the cap is still <0.01% of window; many tool results per turn
/// stay safely bounded by the per-turn iteration cap).
///
/// Original constraint (8K) was matched to OpenClaw's default — chosen
/// for shorter-context models where any single tool result could fill
/// the window. We're not in that regime; per-call caps should match
/// today's window sizes.
const MAX_TOOL_RESULT_CHARS: usize = 24000;

/// Truncate tool output to fit within the context budget.
/// Keeps the first and last portions so the LLM sees both the beginning
/// (usually headers/structure) and end (usually the final state/error).
fn truncateToolOutput(allocator: std.mem.Allocator, output: []const u8, max_chars: usize) ![]const u8 {
    if (output.len <= max_chars) return try allocator.dupe(u8, output);

    const marker_overhead = 60; // "[... NNNNN characters truncated ...]" + newlines
    const min_useful = marker_overhead + 40; // at least 40 chars of content
    if (max_chars < min_useful) {
        // Too small for head+tail split; just take the head
        return try std.fmt.allocPrint(allocator, "{s}\n\n[... {d} characters truncated ...]", .{
            output[0..@min(output.len, max_chars)],
            output.len -| max_chars,
        });
    }

    const budget = max_chars - marker_overhead;
    const keep_head = budget * 2 / 3;
    const keep_tail = budget - keep_head;
    const omitted = output.len - keep_head - keep_tail;

    return try std.fmt.allocPrint(allocator, "{s}\n\n[... {d} characters truncated ...]\n\n{s}", .{
        output[0..keep_head],
        omitted,
        output[output.len - keep_tail ..],
    });
}

/// Format tool execution results as XML for the next LLM turn.
/// Normalizes output: truncates oversized results, structures errors clearly.
pub fn formatToolResults(allocator: std.mem.Allocator, results: []const ToolExecutionResult) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "[Tool results]\n");
    for (results) |result| {
        const status_str = if (result.success) "ok" else "error";

        // Truncate oversized outputs to prevent context window exhaustion
        const normalized_output = try truncateToolOutput(allocator, result.output, MAX_TOOL_RESULT_CHARS);
        defer allocator.free(normalized_output);

        try std.fmt.format(buf.writer(allocator), "<tool_result name=\"{s}\" status=\"{s}\">\n{s}\n</tool_result>\n", .{
            result.name,
            status_str,
            normalized_output,
        });
    }

    return try buf.toOwnedSlice(allocator);
}

/// Build tool use instructions for the system prompt.
pub fn buildToolInstructions(allocator: std.mem.Allocator, tools: anytype) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("\n## Tool Use Protocol\n\n");
    try w.writeAll("To use a tool, wrap a JSON object in <tool_call></tool_call> tags:\n\n");
    try w.writeAll("```\n<tool_call>\n{\"name\": \"tool_name\", \"arguments\": {\"param\": \"value\"}}\n</tool_call>\n```\n\n");
    try w.writeAll("CRITICAL: Output actual <tool_call> tags -- never describe steps or give examples.\n\n");
    try w.writeAll("You may use multiple tool calls in a single response. ");
    try w.writeAll("After tool execution, results appear in <tool_result> tags. ");
    try w.writeAll("Continue reasoning with the results until you can give a final answer.\n\n");
    try w.writeAll("Prefer memory tools (memory_recall, memory_list, memory_timeline, memory_store, memory_edit, memory_forget) for assistant memory tasks instead of shell/sqlite commands.\n");
    try w.writeAll("Use `memory_timeline` first to discover or browse session/timeline summaries, `memory_recall` for semantic lookup, and `memory_list` for raw record inspection. Treat transcript/autosave records as exact-history deep dives, not default memory context.\n");
    try w.writeAll("Important: `memory_recall` and `memory_list` default to `scope=session`; use `scope=global` for durable or cross-session facts. Prompt-loaded workspace docs such as `MEMORY.md` are fallback/context surfaces, not proof that a fact is in canonical semantic memory.\n\n");
    try w.writeAll("### Available Tools\n\n");

    for (tools) |t| {
        try std.fmt.format(w, "**{s}**: {s}\nParameters: `{s}`\n\n", .{
            t.name(),
            t.description(),
            t.parametersJson(),
        });
    }

    return try buf.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// Structured Tool Call Conversion
// ═══════════════════════════════════════════════════════════════════════════

const ToolCall = providers.ToolCall;

/// Convert structured tool calls from a ChatResponse (provider-native format)
/// into ParsedToolCall slices for the agent loop.
///
/// This bridges the provider's `ToolCall` type (id, name, arguments) to the
/// dispatcher's `ParsedToolCall` type used for tool execution.
pub fn parseStructuredToolCalls(
    allocator: std.mem.Allocator,
    tool_calls: []const ToolCall,
) ![]ParsedToolCall {
    var calls: std.ArrayListUnmanaged(ParsedToolCall) = .empty;
    errdefer {
        for (calls.items) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        calls.deinit(allocator);
    }

    for (tool_calls) |tc| {
        if (tc.name.len == 0) continue;

        try calls.append(allocator, .{
            .name = try allocator.dupe(u8, tc.name),
            .arguments_json = try allocator.dupe(u8, tc.arguments),
            .tool_call_id = if (tc.id.len > 0) try allocator.dupe(u8, tc.id) else null,
        });
    }

    return try calls.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// Native Tool Dispatcher — OpenAI-format tool_calls support
// ═══════════════════════════════════════════════════════════════════════════

/// Dispatcher format kind.
pub const DispatcherKind = enum {
    xml,
    native,
};

/// Quick check whether a response string looks like OpenAI native JSON format.
/// Returns true if the text starts with `{` (after trimming whitespace) and contains `"tool_calls"`.
/// This is a lightweight heuristic — full JSON parsing happens in parseNativeToolCalls.
pub fn isNativeJsonFormat(text: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, text, " \n\r\t");
    if (trimmed.len == 0 or trimmed[0] != '{') return false;
    return std.mem.indexOf(u8, trimmed, "\"tool_calls\"") != null;
}

/// Detect whether a response string is in OpenAI native tool-call format.
/// Looks for the `"tool_calls"` key inside a top-level JSON object.
pub fn isNativeFormat(allocator: std.mem.Allocator, response: []const u8) bool {
    // Quick heuristic: must contain "tool_calls" substring
    if (std.mem.indexOf(u8, response, "\"tool_calls\"") == null) return false;

    // Validate it's inside a parseable JSON object
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return false;
    defer parsed.deinit();

    return switch (parsed.value) {
        .object => |obj| obj.get("tool_calls") != null,
        else => false,
    };
}

/// A single tool call in the OpenAI native format (within the `tool_calls` array).
const NativeToolCall = struct {
    id: []const u8,
    type: []const u8,
    function: struct {
        name: []const u8,
        arguments: []const u8,
    },
};

/// Parse tool calls from an OpenAI-format JSON response.
///
/// Expected input format (the full response JSON, or just the message object):
/// ```json
/// {
///   "content": "Some text",
///   "tool_calls": [
///     {
///       "id": "call_abc123",
///       "type": "function",
///       "function": {
///         "name": "shell",
///         "arguments": "{\"command\": \"ls -la\"}"
///       }
///     }
///   ]
/// }
/// ```
///
/// Returns text content and extracted tool calls (same shape as XML parser).
pub fn parseNativeToolCalls(
    allocator: std.mem.Allocator,
    response: []const u8,
) !ParseResult {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidNativeFormat,
    };

    // Extract text content
    const text = if (obj.get("content")) |content_val| switch (content_val) {
        .string => |s| try allocator.dupe(u8, s),
        .null => try allocator.dupe(u8, ""),
        else => try allocator.dupe(u8, ""),
    } else try allocator.dupe(u8, "");

    // Extract tool_calls array
    const tool_calls_val = obj.get("tool_calls") orelse return .{
        .text = text,
        .calls = try allocator.alloc(ParsedToolCall, 0),
    };

    const tool_calls_arr = switch (tool_calls_val) {
        .array => |a| a,
        else => return .{
            .text = text,
            .calls = try allocator.alloc(ParsedToolCall, 0),
        },
    };

    var calls: std.ArrayListUnmanaged(ParsedToolCall) = .empty;
    errdefer {
        for (calls.items) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        calls.deinit(allocator);
    }

    for (tool_calls_arr.items) |tc_val| {
        const tc_obj = switch (tc_val) {
            .object => |o| o,
            else => continue,
        };

        // Extract the function object
        const func_val = tc_obj.get("function") orelse continue;
        const func_obj = switch (func_val) {
            .object => |o| o,
            else => continue,
        };

        // Extract function name
        const name_val = func_obj.get("name") orelse continue;
        const name_str = switch (name_val) {
            .string => |s| s,
            else => continue,
        };
        if (name_str.len == 0) continue;

        // Extract arguments (string)
        const args_str = if (func_obj.get("arguments")) |args_val| switch (args_val) {
            .string => |s| s,
            else => "{}",
        } else "{}";

        // Extract tool call id
        const tc_id = if (tc_obj.get("id")) |id_val| switch (id_val) {
            .string => |s| s,
            else => null,
        } else null;

        try calls.append(allocator, .{
            .name = try allocator.dupe(u8, name_str),
            .arguments_json = try allocator.dupe(u8, args_str),
            .tool_call_id = if (tc_id) |id| try allocator.dupe(u8, id) else null,
        });
    }

    return .{
        .text = text,
        .calls = try calls.toOwnedSlice(allocator),
    };
}

/// Format tool execution results as OpenAI-format JSON for the next API call.
///
/// Produces an array of tool result messages:
/// ```json
/// [
///   {"role": "tool", "tool_call_id": "call_abc123", "content": "output here"}
/// ]
/// ```
pub fn formatNativeToolResults(allocator: std.mem.Allocator, results: []const ToolExecutionResult) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("[");
    for (results, 0..) |result, i| {
        if (i > 0) try w.writeAll(",");
        const tc_id = result.tool_call_id orelse "unknown";

        // Serialize content as a JSON string value
        try std.fmt.format(w, "{{\"role\":\"tool\",\"tool_call_id\":{f},\"content\":{f}}}", .{
            std.json.fmt(tc_id, .{}),
            std.json.fmt(result.output, .{}),
        });
    }
    try w.writeAll("]");

    return try buf.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// Assistant History Builder
// ═══════════════════════════════════════════════════════════════════════════

/// Build an assistant history entry that includes serialized tool calls as XML.
///
/// When the provider returns structured tool_calls, we serialize them as
/// `<tool_call>` XML tags so the conversation history stays in a canonical
/// format regardless of whether tools came from native API or XML parsing.
///
/// Mirrors ZeroClaw's `build_assistant_history_with_tool_calls`.
pub fn buildAssistantHistoryWithToolCalls(
    allocator: std.mem.Allocator,
    response_text: []const u8,
    parsed_calls: []const ParsedToolCall,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    if (response_text.len > 0) {
        try w.writeAll(response_text);
        try w.writeByte('\n');
    }

    for (parsed_calls) |call| {
        try w.writeAll("<tool_call>\n");
        const name_json = try std.json.Stringify.valueAlloc(allocator, call.name, .{});
        defer allocator.free(name_json);
        try w.writeAll("{\"name\": ");
        try w.writeAll(name_json);
        try w.writeAll(", \"arguments\": ");
        try w.writeAll(call.arguments_json);
        try w.writeByte('}');
        try w.writeAll("\n</tool_call>\n");
    }

    return buf.toOwnedSlice(allocator);
}

// ── Internal helpers ────────────────────────────────────────────────────

/// Find the first JSON object `{...}` in a string, handling nesting.
fn extractJsonObject(input: []const u8) ?[]const u8 {
    // Strip markdown fences if present
    var trimmed = input;
    if (std.mem.indexOf(u8, trimmed, "```")) |fence_start| {
        // Skip to end of first line (after ```json or ```)
        const after_fence = trimmed[fence_start + 3 ..];
        if (std.mem.indexOfScalar(u8, after_fence, '\n')) |nl| {
            trimmed = after_fence[nl + 1 ..];
        }
        // Strip closing fence
        if (std.mem.lastIndexOf(u8, trimmed, "```")) |close| {
            trimmed = trimmed[0..close];
        }
    }

    // Find first '{' or '[' — support both objects and arrays
    const obj_pos = std.mem.indexOfScalar(u8, trimmed, '{');
    const arr_pos = std.mem.indexOfScalar(u8, trimmed, '[');

    const start_info: struct { pos: usize, open: u8, close: u8 } = blk: {
        if (obj_pos) |op| {
            if (arr_pos) |ap| {
                // Both found — pick whichever comes first
                if (ap < op) break :blk .{ .pos = ap, .open = '[', .close = ']' };
                break :blk .{ .pos = op, .open = '{', .close = '}' };
            }
            break :blk .{ .pos = op, .open = '{', .close = '}' };
        }
        if (arr_pos) |ap| break :blk .{ .pos = ap, .open = '[', .close = ']' };
        return null;
    };

    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i: usize = start_info.pos;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\' and in_string) {
            escaped = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        if (!in_string) {
            if (c == start_info.open) depth += 1;
            if (c == start_info.close) {
                if (depth > 0) depth -= 1;
                if (depth == 0) return trimmed[start_info.pos .. i + 1];
            }
        }
    }

    return null;
}

/// Attempt to repair common JSON issues from LLM output.
/// Handles: trailing commas, unbalanced braces/brackets, unbalanced quotes.
pub fn repairJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Step 1: Copy input, fixing trailing commas and control chars in strings
    var in_string = false;
    var escaped = false;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (escaped) {
            try buf.append(allocator, c);
            escaped = false;
            continue;
        }
        if (in_string) {
            if (c == '\\') {
                escaped = true;
                try buf.append(allocator, c);
            } else if (c == '"') {
                in_string = false;
                try buf.append(allocator, c);
            } else if (c == '\n') {
                try buf.appendSlice(allocator, "\\n");
            } else if (c == '\r') {
                try buf.appendSlice(allocator, "\\r");
            } else if (c == '\t') {
                try buf.appendSlice(allocator, "\\t");
            } else {
                try buf.append(allocator, c);
            }
        } else {
            if (c == '"') {
                in_string = true;
                try buf.append(allocator, c);
            } else if (c == ',') {
                // Check if next non-whitespace is } or ] (trailing comma)
                var j = i + 1;
                while (j < input.len and (input[j] == ' ' or input[j] == '\n' or input[j] == '\r' or input[j] == '\t')) j += 1;
                if (j < input.len and (input[j] == '}' or input[j] == ']')) {
                    // Skip trailing comma
                } else {
                    try buf.append(allocator, c);
                }
            } else {
                try buf.append(allocator, c);
            }
        }
    }

    // Step 2: Balance quotes (if odd number of unescaped quotes, add closing quote)
    var quote_count: usize = 0;
    var esc2 = false;
    for (buf.items) |c| {
        if (esc2) {
            esc2 = false;
            continue;
        }
        if (c == '\\') {
            esc2 = true;
            continue;
        }
        if (c == '"') quote_count += 1;
    }
    if (quote_count % 2 != 0) {
        try buf.append(allocator, '"');
    }

    // Step 3: Balance braces and brackets
    var brace_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var in_str = false;
    var esc3 = false;
    for (buf.items) |c| {
        if (esc3) {
            esc3 = false;
            continue;
        }
        if (c == '\\' and in_str) {
            esc3 = true;
            continue;
        }
        if (c == '"') in_str = !in_str;
        if (!in_str) {
            if (c == '{') brace_depth += 1;
            if (c == '}') brace_depth -= 1;
            if (c == '[') bracket_depth += 1;
            if (c == ']') bracket_depth -= 1;
        }
    }
    while (bracket_depth > 0) : (bracket_depth -= 1) {
        try buf.append(allocator, ']');
    }
    while (brace_depth > 0) : (brace_depth -= 1) {
        try buf.append(allocator, '}');
    }

    return try buf.toOwnedSlice(allocator);
}

/// Parse a JSON tool call object: {"name": "...", "arguments": {...}}
/// Tries to parse as-is first, then applies JSON repair as fallback.
fn parseToolCallJson(allocator: std.mem.Allocator, json_str: []const u8) !ParsedToolCall {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        // JSON parse failed — try repair
        const repaired = repairJson(allocator, json_str) catch return error.InvalidToolCallFormat;
        defer allocator.free(repaired);
        const reparsed = std.json.parseFromSlice(std.json.Value, allocator, repaired, .{}) catch
            return error.InvalidToolCallFormat;
        return parseToolCallJsonInner(allocator, reparsed);
    };
    return parseToolCallJsonInner(allocator, parsed);
}

fn parseToolCallJsonInner(allocator: std.mem.Allocator, parsed: std.json.Parsed(std.json.Value)) !ParsedToolCall {
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidToolCallFormat,
    };

    // Extract name
    const name_val = obj.get("name") orelse return error.MissingToolName;
    const name_str = switch (name_val) {
        .string => |s| s,
        else => return error.InvalidToolName,
    };
    const trimmed_name = std.mem.trim(u8, name_str, " \t\r\n");
    if (trimmed_name.len == 0) return error.EmptyToolName;

    // Extract arguments — re-serialize to JSON string
    const args_json = if (obj.get("arguments")) |args_val| blk: {
        switch (args_val) {
            .string => |s| {
                // Arguments is a string (possibly a JSON string) — use as-is
                break :blk try allocator.dupe(u8, s);
            },
            else => {
                // Arguments is an object/value — serialize it
                break :blk try std.json.Stringify.valueAlloc(allocator, args_val, .{});
            },
        }
    } else try allocator.dupe(u8, "{}");
    errdefer allocator.free(args_json);

    return .{
        .name = try allocator.dupe(u8, trimmed_name),
        .arguments_json = args_json,
    };
}

/// Parse `<function=NAME><parameter=KEY>VALUE</parameter>...</function>` format.
///
/// Some open-source LLMs (Llama, Qwen, etc.) emit this XML-based format
/// instead of JSON inside `<tool_call>` tags. Extracts function name and
/// parameter key-value pairs, returning a `ParsedToolCall` with serialized
/// JSON arguments.
fn parseFunctionTagCall(allocator: std.mem.Allocator, inner: []const u8) !ParsedToolCall {
    // Expect: <function=NAME> ... </function>
    const func_prefix = "<function=";
    const func_start = std.mem.indexOf(u8, inner, func_prefix) orelse return error.NoFunctionTag;
    const after_prefix = inner[func_start + func_prefix.len ..];
    const name_end = std.mem.indexOfScalar(u8, after_prefix, '>') orelse return error.NoFunctionTag;
    const func_name = std.mem.trim(u8, after_prefix[0..name_end], " \t\r\n");
    if (func_name.len == 0) return error.EmptyFunctionName;

    // Validate function name: only alphanumeric, underscore, dash, dot allowed
    for (func_name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
            else => return error.InvalidFunctionName,
        }
    }

    // Collect <parameter=KEY>VALUE</parameter> pairs — bounded by </function>
    const full_body = after_prefix[name_end + 1 ..];
    const body = if (std.mem.indexOf(u8, full_body, "</function>")) |fc|
        full_body[0..fc]
    else
        full_body;

    var args_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer args_buf.deinit(allocator);
    const w = args_buf.writer(allocator);
    try w.writeByte('{');

    var remaining = body;
    var first = true;
    const param_prefix = "<parameter=";
    const param_close = "</parameter>";

    while (std.mem.indexOf(u8, remaining, param_prefix)) |ps| {
        const after_param = remaining[ps + param_prefix.len ..];
        const key_end = std.mem.indexOfScalar(u8, after_param, '>') orelse break;
        const key = std.mem.trim(u8, after_param[0..key_end], " \t\r\n");
        if (key.len == 0) break;

        const value_start = after_param[key_end + 1 ..];
        const value_end_pos = std.mem.indexOf(u8, value_start, param_close) orelse break;
        const value = std.mem.trim(u8, value_start[0..value_end_pos], " \t\r\n");

        if (!first) try w.writeByte(',');
        first = false;

        // Write "key": "value" with JSON string escaping via Stringify.valueAlloc
        const key_json = try std.json.Stringify.valueAlloc(allocator, key, .{});
        defer allocator.free(key_json);
        const val_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(val_json);
        try w.writeAll(key_json);
        try w.writeByte(':');
        try w.writeAll(val_json);

        remaining = value_start[value_end_pos + param_close.len ..];
    }

    try w.writeByte('}');

    const args_json = try args_buf.toOwnedSlice(allocator);
    errdefer allocator.free(args_json);
    return .{
        .name = try allocator.dupe(u8, func_name),
        .arguments_json = args_json,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "parseToolCalls extracts single call" {
    const allocator = std.testing.allocator;
    const response =
        \\Let me check that.
        \\<tool_call>
        \\{"name": "shell", "arguments": {"command": "ls -la"}}
        \\</tool_call>
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqualStrings("Let me check that.", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, result.calls[0].arguments_json, "ls -la") != null);
}

test "parseToolCalls extracts multiple calls" {
    const allocator = std.testing.allocator;
    const response =
        \\<tool_call>
        \\{"name": "file_read", "arguments": {"path": "a.txt"}}
        \\</tool_call>
        \\<tool_call>
        \\{"name": "file_read", "arguments": {"path": "b.txt"}}
        \\</tool_call>
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 2), result.calls.len);
    try std.testing.expectEqualStrings("file_read", result.calls[0].name);
    try std.testing.expectEqualStrings("file_read", result.calls[1].name);
}

test "parseToolCalls returns text only when no calls" {
    const allocator = std.testing.allocator;
    const response = "Just a normal response with no tools.";

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        allocator.free(result.calls);
    }

    try std.testing.expectEqualStrings("Just a normal response with no tools.", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseToolCalls handles text before and after" {
    const allocator = std.testing.allocator;
    const response =
        \\Before text.
        \\<tool_call>
        \\{"name": "shell", "arguments": {"command": "echo hi"}}
        \\</tool_call>
        \\After text.
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expect(std.mem.indexOf(u8, result.text, "Before text.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "After text.") != null);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
}

test "parseToolCalls rejects raw JSON without tags" {
    const allocator = std.testing.allocator;
    const response =
        \\Sure, creating the file now.
        \\{"name": "file_write", "arguments": {"path": "hello.py", "content": "print('hello')"}}
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseToolCalls handles markdown fenced JSON" {
    const allocator = std.testing.allocator;
    const response =
        \\<tool_call>
        \\```json
        \\{"name": "file_write", "arguments": {"path": "test.py", "content": "ok"}}
        \\```
        \\</tool_call>
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("file_write", result.calls[0].name);
}

test "parseToolCalls handles preamble text inside tag" {
    const allocator = std.testing.allocator;
    const response =
        \\<tool_call>
        \\I will now call the tool:
        \\{"name": "shell", "arguments": {"command": "pwd"}}
        \\</tool_call>
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
}

test "formatToolResults produces XML" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "hello world", .success = true },
    };
    const formatted = try formatToolResults(allocator, &results);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "<tool_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "ok") != null);
}

test "formatToolResults marks errors" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "permission denied", .success = false },
    };
    const formatted = try formatToolResults(allocator, &results);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "error") != null);
}

test "extractJsonObject finds nested object" {
    const input = "some text {\"key\": {\"nested\": true}} more text";
    const result = extractJsonObject(input).?;
    try std.testing.expectEqualStrings("{\"key\": {\"nested\": true}}", result);
}

test "extractJsonObject returns null for no object" {
    try std.testing.expect(extractJsonObject("no json here") == null);
}

// ── Additional dispatcher tests ─────────────────────────────────

test "parseToolCalls empty string" {
    const allocator = std.testing.allocator;
    const result = try parseToolCalls(allocator, "");
    defer {
        allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
    try std.testing.expectEqual(@as(usize, 0), result.text.len);
}

test "parseToolCalls unclosed tag" {
    const allocator = std.testing.allocator;
    const response = "Some text <tool_call>{\"name\":\"shell\",\"arguments\":{}} and more";
    const result = try parseToolCalls(allocator, response);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        allocator.free(result.calls);
    }
    // Unclosed tag should stop parsing, text before tag should be captured
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseToolCalls recovers malformed consecutive tool_call openings" {
    const allocator = std.testing.allocator;
    const response =
        \\<tool_call>
        \\{"name":"file_edit","arguments":{"path":"a.log","old_text":"x","new_text":"y"}}
        \\<tool_call>
        \\{"name":"file_edit","arguments":{"path":"b.log","old_text":"x","new_text":"y"}}
        \\<tool_call>
        \\{"name":"file_edit","arguments":{"path":"c.log","old_text":"x","new_text":"y"}}
    ;
    const result = try parseToolCalls(allocator, response);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 3), result.calls.len);
    try std.testing.expectEqualStrings("file_edit", result.calls[0].name);
    try std.testing.expectEqualStrings("file_edit", result.calls[1].name);
    try std.testing.expectEqualStrings("file_edit", result.calls[2].name);
}

test "parseToolCalls malformed JSON inside tag" {
    const allocator = std.testing.allocator;
    const response = "<tool_call>this is not json</tool_call>";
    const result = try parseToolCalls(allocator, response);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        allocator.free(result.calls);
    }
    // Malformed JSON is skipped
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseToolCalls empty arguments defaults to empty object" {
    const allocator = std.testing.allocator;
    const response = "<tool_call>{\"name\": \"shell\"}</tool_call>";
    const result = try parseToolCalls(allocator, response);
    defer {
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
    try std.testing.expectEqualStrings("{}", result.calls[0].arguments_json);
}

test "parseToolCalls whitespace-only inside tag" {
    const allocator = std.testing.allocator;
    const response = "<tool_call>   \n   </tool_call>";
    const result = try parseToolCalls(allocator, response);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "formatToolResults empty results" {
    const allocator = std.testing.allocator;
    const formatted = try formatToolResults(allocator, &.{});
    defer allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Tool results") != null);
}

test "formatToolResults multiple results" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "file1.txt", .success = true },
        .{ .name = "file_read", .output = "content here", .success = true },
        .{ .name = "search", .output = "not found", .success = false },
    };
    const formatted = try formatToolResults(allocator, &results);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "file_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "search") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "file1.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "not found") != null);
}

test "truncateToolOutput preserves short output" {
    const allocator = std.testing.allocator;
    const short = "hello world";
    const result = try truncateToolOutput(allocator, short, 100);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(short, result);
}

test "truncateToolOutput truncates oversized output with marker" {
    const allocator = std.testing.allocator;
    // Create a 200-char output, truncate to 100
    const big = "A" ** 200;
    const result = try truncateToolOutput(allocator, big, 100);
    defer allocator.free(result);
    try std.testing.expect(result.len < big.len);
    try std.testing.expect(std.mem.indexOf(u8, result, "characters truncated") != null);
    // Should start with A's (head) and end with A's (tail)
    try std.testing.expect(result[0] == 'A');
    try std.testing.expect(result[result.len - 1] == 'A');
}

test "formatToolResults truncates oversized tool output" {
    const allocator = std.testing.allocator;
    const big_output = "X" ** (MAX_TOOL_RESULT_CHARS + 1000);
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = big_output, .success = true },
    };
    const formatted = try formatToolResults(allocator, &results);
    defer allocator.free(formatted);
    // The formatted output should contain the truncation marker
    try std.testing.expect(std.mem.indexOf(u8, formatted, "characters truncated") != null);
    // And should be smaller than the raw output
    try std.testing.expect(formatted.len < big_output.len);
}

// Bug 3 regression: unmatched close brace/bracket must not underflow depth (usize).
// Before fix, `depth -= 1` when depth==0 caused a panic (usize underflow).
test "extractJsonObject unmatched close brace does not panic" {
    // Input starts with '}' — no matching open, depth would underflow before fix.
    const result = extractJsonObject("} not an object {\"key\":\"ok\"}");
    // The second valid object should still be found (or null — both are acceptable).
    // The important thing is no panic.
    if (result) |r| {
        try std.testing.expect(r.len > 0);
    }
}

test "extractJsonObject unmatched close bracket does not panic" {
    // Input starts with ']' — no matching open.
    const result = extractJsonObject("] some text [1,2,3]");
    if (result) |r| {
        try std.testing.expect(r.len > 0);
    }
}

test "extractJsonObject with leading text" {
    const input = "Here is the result: {\"key\": \"value\"}";
    const result = extractJsonObject(input).?;
    try std.testing.expectEqualStrings("{\"key\": \"value\"}", result);
}

test "extractJsonObject deeply nested" {
    const input = "{\"a\":{\"b\":{\"c\":true}}}";
    const result = extractJsonObject(input).?;
    try std.testing.expectEqualStrings(input, result);
}

test "extractJsonObject with string containing braces" {
    const input = "{\"key\": \"value with { and } inside\"}";
    const result = extractJsonObject(input).?;
    try std.testing.expectEqualStrings(input, result);
}

test "extractJsonObject empty string" {
    try std.testing.expect(extractJsonObject("") == null);
}

test "extractJsonObject unmatched brace" {
    try std.testing.expect(extractJsonObject("{unclosed") == null);
}

test "buildToolInstructions empty tools" {
    const allocator = std.testing.allocator;
    const MockTool = struct {
        fn name(_: @This()) []const u8 {
            return "mock";
        }
        fn description(_: @This()) []const u8 {
            return "A mock tool";
        }
        fn parametersJson(_: @This()) []const u8 {
            return "{}";
        }
    };
    const empty: []const MockTool = &.{};
    const instructions = try buildToolInstructions(allocator, empty);
    defer allocator.free(instructions);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "Tool Use Protocol") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "tool_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "memory_edit") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "memory_timeline") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "semantic lookup") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions, "exact-history deep dives") != null);
}

test "parseToolCalls three consecutive calls" {
    const allocator = std.testing.allocator;
    const response =
        \\<tool_call>
        \\{"name": "a", "arguments": {}}
        \\</tool_call>
        \\<tool_call>
        \\{"name": "b", "arguments": {}}
        \\</tool_call>
        \\<tool_call>
        \\{"name": "c", "arguments": {}}
        \\</tool_call>
    ;
    const result = try parseToolCalls(allocator, response);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 3), result.calls.len);
    try std.testing.expectEqualStrings("a", result.calls[0].name);
    try std.testing.expectEqualStrings("b", result.calls[1].name);
    try std.testing.expectEqualStrings("c", result.calls[2].name);
}

test "formatToolResults with tool_call_id" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "ok", .success = true, .tool_call_id = "tc-123" },
    };
    const formatted = try formatToolResults(allocator, &results);
    defer allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "ok") != null);
}

test "ParsedToolCall default tool_call_id is null" {
    const call = ParsedToolCall{
        .name = "test",
        .arguments_json = "{}",
    };
    try std.testing.expect(call.tool_call_id == null);
}

test "ToolExecutionResult default tool_call_id is null" {
    const result = ToolExecutionResult{
        .name = "test",
        .output = "output",
        .success = true,
    };
    try std.testing.expect(result.tool_call_id == null);
}

// ── Function-tag format tests (<function=name><parameter=key>value</parameter></function>) ──

test "parseFunctionTagCall single parameter" {
    const allocator = std.testing.allocator;
    const inner = "<function=shell><parameter=command>ps aux | grep nullalis</parameter></function>";
    const call = try parseFunctionTagCall(allocator, inner);
    defer {
        allocator.free(call.name);
        allocator.free(call.arguments_json);
    }
    try std.testing.expectEqualStrings("shell", call.name);
    try std.testing.expect(std.mem.indexOf(u8, call.arguments_json, "ps aux | grep nullalis") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.arguments_json, "command") != null);
}

test "parseFunctionTagCall multiple parameters" {
    const allocator = std.testing.allocator;
    const inner = "<function=file_write><parameter=path>/tmp/test.txt</parameter><parameter=content>hello world</parameter></function>";
    const call = try parseFunctionTagCall(allocator, inner);
    defer {
        allocator.free(call.name);
        allocator.free(call.arguments_json);
    }
    try std.testing.expectEqualStrings("file_write", call.name);
    try std.testing.expect(std.mem.indexOf(u8, call.arguments_json, "path") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.arguments_json, "/tmp/test.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.arguments_json, "content") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.arguments_json, "hello world") != null);
}

test "parseFunctionTagCall with whitespace and newlines" {
    const allocator = std.testing.allocator;
    const inner =
        \\<function=shell>
        \\<parameter=command>
        \\ls -la
        \\</parameter>
        \\</function>
    ;
    const call = try parseFunctionTagCall(allocator, inner);
    defer {
        allocator.free(call.name);
        allocator.free(call.arguments_json);
    }
    try std.testing.expectEqualStrings("shell", call.name);
    try std.testing.expect(std.mem.indexOf(u8, call.arguments_json, "ls -la") != null);
}

test "parseFunctionTagCall no function tag returns error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NoFunctionTag, parseFunctionTagCall(allocator, "just plain text"));
}

test "parseToolCalls handles function-tag format inside tool_call" {
    const allocator = std.testing.allocator;
    const response =
        \\<tool_call>
        \\<function=shell>
        \\<parameter=command>ps aux | grep nullalis | grep -v grep</parameter>
        \\</function>
        \\</tool_call>
    ;
    const result = try parseToolCalls(allocator, response);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, result.calls[0].arguments_json, "ps aux") != null);
}

test "parseToolCalls function-tag with surrounding text" {
    const allocator = std.testing.allocator;
    const response =
        \\Let me check that.
        \\<tool_call>
        \\<function=shell>
        \\<parameter=command>echo hi</parameter>
        \\</function>
        \\</tool_call>
        \\Done.
    ;
    const result = try parseToolCalls(allocator, response);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Let me check that.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Done.") != null);
}

test "parseFunctionTagCall value with quotes is JSON-escaped" {
    const allocator = std.testing.allocator;
    const inner = "<function=shell><parameter=command>echo \"hello world\"</parameter></function>";
    const call = try parseFunctionTagCall(allocator, inner);
    defer {
        allocator.free(call.name);
        allocator.free(call.arguments_json);
    }
    try std.testing.expectEqualStrings("shell", call.name);
    // Verify the JSON is valid by parsing it
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, call.arguments_json, .{});
    defer parsed.deinit();
    const cmd = parsed.value.object.get("command").?.string;
    try std.testing.expectEqualStrings("echo \"hello world\"", cmd);
}

// ── Native tool dispatcher tests ────────────────────────────────

test "isNativeFormat detects OpenAI tool_calls" {
    const native_response =
        \\{"content":"ok","tool_calls":[{"id":"call_1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"ls\"}"}}]}
    ;
    try std.testing.expect(isNativeFormat(std.testing.allocator, native_response));
}

test "isNativeFormat rejects XML format" {
    const xml_response = "Let me check.\n<tool_call>\n{\"name\":\"shell\",\"arguments\":{}}\n</tool_call>";
    try std.testing.expect(!isNativeFormat(std.testing.allocator, xml_response));
}

test "isNativeFormat rejects plain text" {
    try std.testing.expect(!isNativeFormat(std.testing.allocator, "Just a normal response."));
}

test "isNativeFormat rejects tool_calls in non-JSON context" {
    // Contains the substring but is not valid JSON
    try std.testing.expect(!isNativeFormat(std.testing.allocator, "The API returns \"tool_calls\" in the response."));
}

test "parseNativeToolCalls single call" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"I will list files.","tool_calls":[{"id":"call_abc","type":"function","function":{"name":"shell","arguments":"{\"command\":\"ls -la\"}"}}]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqualStrings("I will list files.", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
    try std.testing.expectEqualStrings("call_abc", result.calls[0].tool_call_id.?);
    try std.testing.expect(std.mem.indexOf(u8, result.calls[0].arguments_json, "ls -la") != null);
}

test "parseNativeToolCalls multiple calls" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"Reading files.","tool_calls":[{"id":"tc1","type":"function","function":{"name":"file_read","arguments":"{\"path\":\"a.txt\"}"}},{"id":"tc2","type":"function","function":{"name":"file_read","arguments":"{\"path\":\"b.txt\"}"}}]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 2), result.calls.len);
    try std.testing.expectEqualStrings("file_read", result.calls[0].name);
    try std.testing.expectEqualStrings("tc1", result.calls[0].tool_call_id.?);
    try std.testing.expectEqualStrings("file_read", result.calls[1].name);
    try std.testing.expectEqualStrings("tc2", result.calls[1].tool_call_id.?);
}

test "parseNativeToolCalls null content" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":null,"tool_calls":[{"id":"tc1","type":"function","function":{"name":"shell","arguments":"{}"}}]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqualStrings("", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
}

test "parseNativeToolCalls no tool_calls key" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"Just text, no tools."}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        allocator.free(result.calls);
    }

    try std.testing.expectEqualStrings("Just text, no tools.", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseNativeToolCalls empty tool_calls array" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"Done.","tool_calls":[]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        allocator.free(result.calls);
    }

    try std.testing.expectEqualStrings("Done.", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseNativeToolCalls skips entries without function field" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"","tool_calls":[{"id":"tc1","type":"function"},{"id":"tc2","type":"function","function":{"name":"shell","arguments":"{}"}}]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
}

test "parseNativeToolCalls skips entries with empty function name" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"","tool_calls":[{"id":"tc1","type":"function","function":{"name":"","arguments":"{}"}}]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "parseNativeToolCalls preserves tool_call_id" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"","tool_calls":[{"id":"call_xyz789","type":"function","function":{"name":"search","arguments":"{\"query\":\"test\"}"}}]}
    ;

    const result = try parseNativeToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("call_xyz789", result.calls[0].tool_call_id.?);
}

test "formatNativeToolResults single result" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "hello world", .success = true, .tool_call_id = "call_1" },
    };
    const formatted = try formatNativeToolResults(allocator, &results);
    defer allocator.free(formatted);

    // Should be valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, formatted, .{});
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.ExpectedArray,
    };

    try std.testing.expectEqual(@as(usize, 1), arr.items.len);
    const item = arr.items[0].object;
    try std.testing.expectEqualStrings("tool", item.get("role").?.string);
    try std.testing.expectEqualStrings("call_1", item.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings("hello world", item.get("content").?.string);
}

test "formatNativeToolResults multiple results" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "ok", .success = true, .tool_call_id = "tc1" },
        .{ .name = "file_read", .output = "content", .success = true, .tool_call_id = "tc2" },
    };
    const formatted = try formatNativeToolResults(allocator, &results);
    defer allocator.free(formatted);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, formatted, .{});
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.ExpectedArray,
    };

    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    try std.testing.expectEqualStrings("tc1", arr.items[0].object.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings("tc2", arr.items[1].object.get("tool_call_id").?.string);
}

test "formatNativeToolResults missing tool_call_id defaults to unknown" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "ok", .success = true },
    };
    const formatted = try formatNativeToolResults(allocator, &results);
    defer allocator.free(formatted);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, formatted, .{});
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.ExpectedArray,
    };

    try std.testing.expectEqualStrings("unknown", arr.items[0].object.get("tool_call_id").?.string);
}

test "formatNativeToolResults empty results" {
    const allocator = std.testing.allocator;
    const formatted = try formatNativeToolResults(allocator, &.{});
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("[]", formatted);
}

test "formatNativeToolResults escapes special characters in output" {
    const allocator = std.testing.allocator;
    const results = [_]ToolExecutionResult{
        .{ .name = "shell", .output = "line1\nline2\t\"quoted\"", .success = true, .tool_call_id = "tc1" },
    };
    const formatted = try formatNativeToolResults(allocator, &results);
    defer allocator.free(formatted);

    // Verify it's valid JSON (will fail if escaping is broken)
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, formatted, .{});
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqualStrings("line1\nline2\t\"quoted\"", arr.items[0].object.get("content").?.string);
}

test "DispatcherKind enum values" {
    try std.testing.expect(@intFromEnum(DispatcherKind.xml) != @intFromEnum(DispatcherKind.native));
}

// ── parseToolCalls with OpenAI JSON format ──────────────────────

test "parseToolCalls routes OpenAI JSON to native parser" {
    const allocator = std.testing.allocator;
    const response =
        \\{"content":"Listing files.","tool_calls":[{"id":"call_1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"ls\"}"}}]}
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqualStrings("Listing files.", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
    try std.testing.expectEqualStrings("call_1", result.calls[0].tool_call_id.?);
}

test "parseToolCalls falls back to XML when JSON has no tool_calls" {
    const allocator = std.testing.allocator;
    const response =
        \\<tool_call>
        \\{"name": "shell", "arguments": {"command": "pwd"}}
        \\</tool_call>
    ;

    const result = try parseToolCalls(allocator, response);
    defer {
        allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
}

// ── isNativeJsonFormat ──────────────────────────────────────────

test "isNativeJsonFormat true for valid native JSON" {
    try std.testing.expect(isNativeJsonFormat(
        \\{"content":"ok","tool_calls":[]}
    ));
}

test "isNativeJsonFormat true with leading whitespace" {
    try std.testing.expect(isNativeJsonFormat(
        \\  {"tool_calls":[{"id":"1","type":"function","function":{"name":"x","arguments":"{}"}}]}
    ));
}

test "isNativeJsonFormat false for XML response" {
    try std.testing.expect(!isNativeJsonFormat("<tool_call>{\"name\":\"shell\"}</tool_call>"));
}

test "isNativeJsonFormat false for plain text" {
    try std.testing.expect(!isNativeJsonFormat("Just a normal response."));
}

test "isNativeJsonFormat false for empty string" {
    try std.testing.expect(!isNativeJsonFormat(""));
}

test "isNativeJsonFormat false for array" {
    try std.testing.expect(!isNativeJsonFormat("[1,2,3]"));
}

// ── parseStructuredToolCalls ────────────────────────────────────

test "parseStructuredToolCalls converts ToolCall slice" {
    const allocator = std.testing.allocator;
    const tool_calls = [_]providers.ToolCall{
        .{ .id = "call_1", .name = "shell", .arguments = "{\"command\":\"ls\"}" },
        .{ .id = "call_2", .name = "file_read", .arguments = "{\"path\":\"a.txt\"}" },
    };

    const result = try parseStructuredToolCalls(allocator, &tool_calls);
    defer {
        for (result) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("shell", result[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", result[0].arguments_json);
    try std.testing.expectEqualStrings("call_1", result[0].tool_call_id.?);
    try std.testing.expectEqualStrings("file_read", result[1].name);
    try std.testing.expectEqualStrings("call_2", result[1].tool_call_id.?);
}

test "parseStructuredToolCalls skips empty name" {
    const allocator = std.testing.allocator;
    const tool_calls = [_]providers.ToolCall{
        .{ .id = "call_1", .name = "", .arguments = "{}" },
        .{ .id = "call_2", .name = "shell", .arguments = "{}" },
    };

    const result = try parseStructuredToolCalls(allocator, &tool_calls);
    defer {
        for (result) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("shell", result[0].name);
}

test "parseStructuredToolCalls empty input" {
    const allocator = std.testing.allocator;
    const empty: []const providers.ToolCall = &.{};

    const result = try parseStructuredToolCalls(allocator, empty);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "parseStructuredToolCalls empty id becomes null" {
    const allocator = std.testing.allocator;
    const tool_calls = [_]providers.ToolCall{
        .{ .id = "", .name = "shell", .arguments = "{}" },
    };

    const result = try parseStructuredToolCalls(allocator, &tool_calls);
    defer {
        for (result) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0].tool_call_id == null);
}

// ── extractJsonObject with arrays ───────────────────────────────

test "extractJsonObject finds array" {
    const input = "some text [1, 2, 3] more text";
    const result = extractJsonObject(input).?;
    try std.testing.expectEqualStrings("[1, 2, 3]", result);
}

test "extractJsonObject finds nested array" {
    const input = "[[1, 2], [3, 4]]";
    const result = extractJsonObject(input).?;
    try std.testing.expectEqualStrings("[[1, 2], [3, 4]]", result);
}

test "extractJsonObject prefers earlier bracket over brace" {
    const input = "[{\"key\": \"value\"}]";
    const result = extractJsonObject(input).?;
    try std.testing.expectEqualStrings("[{\"key\": \"value\"}]", result);
}

test "extractJsonObject prefers earlier brace over bracket" {
    const input = "{\"arr\": [1, 2]}";
    const result = extractJsonObject(input).?;
    try std.testing.expectEqualStrings("{\"arr\": [1, 2]}", result);
}

// ── JSON Repair Tests ───────────────────────────────────────────

test "repairJson removes trailing commas" {
    const allocator = std.testing.allocator;
    const result = try repairJson(allocator, "{\"key\": \"value\",}");
    defer allocator.free(result);
    // Should be valid JSON after repair
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("value", parsed.value.object.get("key").?.string);
}

test "repairJson removes trailing comma in array" {
    const allocator = std.testing.allocator;
    const result = try repairJson(allocator, "[1, 2, 3,]");
    defer allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);
}

test "repairJson balances unclosed braces" {
    const allocator = std.testing.allocator;
    const result = try repairJson(allocator, "{\"name\": \"shell\", \"arguments\": {\"command\": \"ls\"");
    defer allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("shell", parsed.value.object.get("name").?.string);
}

test "repairJson balances unclosed brackets" {
    const allocator = std.testing.allocator;
    const result = try repairJson(allocator, "[1, 2, 3");
    defer allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);
}

test "repairJson balances unclosed quote" {
    const allocator = std.testing.allocator;
    const result = try repairJson(allocator, "{\"name\": \"shell}");
    defer allocator.free(result);
    // After repair, should have balanced quotes and closing brace
    try std.testing.expect(std.mem.indexOf(u8, result, "shell") != null);
}

test "repairJson escapes newlines in strings" {
    const allocator = std.testing.allocator;
    const result = try repairJson(allocator, "{\"content\": \"line1\nline2\"}");
    defer allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("line1\nline2", parsed.value.object.get("content").?.string);
}

test "repairJson passes through valid JSON unchanged" {
    const allocator = std.testing.allocator;
    const valid = "{\"name\": \"shell\", \"arguments\": {\"command\": \"ls\"}}";
    const result = try repairJson(allocator, valid);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(valid, result);
}

test "repairJson handles combined issues" {
    const allocator = std.testing.allocator;
    // Trailing comma + unclosed brace
    const result = try repairJson(allocator, "{\"name\": \"test\", \"args\": {\"a\": 1,}");
    defer allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("test", parsed.value.object.get("name").?.string);
}

test "parseToolCallJson with trailing comma repair" {
    const allocator = std.testing.allocator;
    const result = try parseToolCallJson(allocator, "{\"name\": \"shell\", \"arguments\": {\"command\": \"ls\"},}");
    defer {
        allocator.free(result.name);
        allocator.free(result.arguments_json);
    }
    try std.testing.expectEqualStrings("shell", result.name);
}

test "parseToolCallJson with unclosed brace repair" {
    const allocator = std.testing.allocator;
    const result = try parseToolCallJson(allocator, "{\"name\": \"shell\", \"arguments\": {\"command\": \"ls\"}");
    defer {
        allocator.free(result.name);
        allocator.free(result.arguments_json);
    }
    try std.testing.expectEqualStrings("shell", result.name);
}

// ── Hardening tests (issue #16 audit) ───────────────────────────

test "parseFunctionTagCall parameters bounded by </function>" {
    const allocator = std.testing.allocator;
    // Two function blocks concatenated — second block's params must NOT leak into first
    const inner = "<function=shell><parameter=command>echo hi</parameter></function><function=file_read><parameter=path>/etc/passwd</parameter></function>";
    const call = try parseFunctionTagCall(allocator, inner);
    defer {
        allocator.free(call.name);
        allocator.free(call.arguments_json);
    }
    try std.testing.expectEqualStrings("shell", call.name);
    // Only "command" parameter should be present, not "path"
    try std.testing.expect(std.mem.indexOf(u8, call.arguments_json, "echo hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.arguments_json, "/etc/passwd") == null);
}

test "parseFunctionTagCall rejects invalid function name with special chars" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidFunctionName,
        parseFunctionTagCall(allocator, "<function=shell\"><parameter=x>y</parameter></function>"),
    );
    try std.testing.expectError(
        error.InvalidFunctionName,
        parseFunctionTagCall(allocator, "<function=she<ll><parameter=x>y</parameter></function>"),
    );
    try std.testing.expectError(
        error.InvalidFunctionName,
        parseFunctionTagCall(allocator, "<function=she ll><parameter=x>y</parameter></function>"),
    );
}

test "parseFunctionTagCall accepts valid names with dots dashes underscores" {
    const allocator = std.testing.allocator;
    const call = try parseFunctionTagCall(allocator, "<function=my-tool_v2.0><parameter=key>val</parameter></function>");
    defer {
        allocator.free(call.name);
        allocator.free(call.arguments_json);
    }
    try std.testing.expectEqualStrings("my-tool_v2.0", call.name);
}

test "parseXmlToolCalls function-tag fallback when JSON has braces in value" {
    const allocator = std.testing.allocator;
    // The parameter value contains {hello} which extractJsonObject will pick up,
    // but parseToolCallJson will fail — function-tag should still be tried as fallback
    const response =
        \\<tool_call>
        \\<function=shell><parameter=command>echo {hello}</parameter></function>
        \\</tool_call>
    ;
    const result = try parseXmlToolCalls(allocator, response);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, result.calls[0].arguments_json, "echo {hello}") != null);
}

// ── buildAssistantHistoryWithToolCalls tests ─────────────────────

test "buildAssistantHistoryWithToolCalls with text and calls" {
    const allocator = std.testing.allocator;
    const calls = [_]ParsedToolCall{
        .{ .name = "shell", .arguments_json = "{\"command\":\"ls\"}" },
        .{ .name = "file_read", .arguments_json = "{\"path\":\"a.txt\"}" },
    };
    const result = try buildAssistantHistoryWithToolCalls(
        allocator,
        "Let me check that.",
        &calls,
    );
    defer allocator.free(result);

    // Should contain the response text
    try std.testing.expect(std.mem.indexOf(u8, result, "Let me check that.") != null);
    // Should contain tool_call XML tags
    try std.testing.expect(std.mem.indexOf(u8, result, "<tool_call>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</tool_call>") != null);
    // Should contain tool names
    try std.testing.expect(std.mem.indexOf(u8, result, "\"shell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"file_read\"") != null);
    // Should contain two tool_call tags
    var count: usize = 0;
    var search = result;
    while (std.mem.indexOf(u8, search, "<tool_call>")) |idx| {
        count += 1;
        search = search[idx + 11 ..];
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "buildAssistantHistoryWithToolCalls empty text" {
    const allocator = std.testing.allocator;
    const calls = [_]ParsedToolCall{
        .{ .name = "shell", .arguments_json = "{}" },
    };
    const result = try buildAssistantHistoryWithToolCalls(
        allocator,
        "",
        &calls,
    );
    defer allocator.free(result);

    // Should NOT start with a newline (no empty text prefix)
    try std.testing.expect(result[0] == '<');
    try std.testing.expect(std.mem.indexOf(u8, result, "<tool_call>") != null);
}

test "buildAssistantHistoryWithToolCalls no calls" {
    const allocator = std.testing.allocator;
    const result = try buildAssistantHistoryWithToolCalls(
        allocator,
        "Just text, no tools.",
        &.{},
    );
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Just text, no tools.\n", result);
}

test "buildAssistantHistoryWithToolCalls empty text and no calls" {
    const allocator = std.testing.allocator;
    const result = try buildAssistantHistoryWithToolCalls(
        allocator,
        "",
        &.{},
    );
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "buildAssistantHistoryWithToolCalls preserves arguments JSON" {
    const allocator = std.testing.allocator;
    const calls = [_]ParsedToolCall{
        .{ .name = "file_write", .arguments_json = "{\"path\":\"test.py\",\"content\":\"print('hello')\"}" },
    };
    const result = try buildAssistantHistoryWithToolCalls(
        allocator,
        "",
        &calls,
    );
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"file_write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "print('hello')") != null);
}

test "buildAssistantHistoryWithToolCalls escapes special chars in name" {
    const allocator = std.testing.allocator;
    const calls = [_]ParsedToolCall{
        .{ .name = "shell\"injection", .arguments_json = "{}" },
    };
    const result = try buildAssistantHistoryWithToolCalls(
        allocator,
        "",
        &calls,
    );
    defer allocator.free(result);

    // The name should be properly JSON-escaped, so the output must be valid JSON inside <tool_call>
    // Find the JSON between <tool_call> tags
    const tc_start = std.mem.indexOf(u8, result, "<tool_call>\n").?;
    const json_start = tc_start + "<tool_call>\n".len;
    const tc_end = std.mem.indexOf(u8, result[json_start..], "\n</tool_call>").?;
    const json_str = result[json_start .. json_start + tc_end];

    // Must be valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    const name = parsed.value.object.get("name").?.string;
    try std.testing.expectEqualStrings("shell\"injection", name);
}

// ── <invoke> parser regression locks ─────────────────────────────────
//
// These reproduce the exact payloads observed on 2026-04-19 when Kimi K2.5
// on Together AI emitted Anthropic-legacy XML instead of native tool_calls.
// If the parser regresses, these tests break.

test "parseToolCalls recovers <invoke> with <parameter> shape" {
    const response =
        \\<invoke name="runtime_info">
        \\<parameter name="section">summary</parameter>
        \\</invoke>
    ;
    const result = try parseToolCalls(std.testing.allocator, response);
    defer std.testing.allocator.free(result.text);
    defer {
        for (result.calls) |call| {
            std.testing.allocator.free(call.name);
            std.testing.allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| std.testing.allocator.free(id);
        }
        std.testing.allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("runtime_info", result.calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, result.calls[0].arguments_json, "\"section\":\"summary\"") != null);
}

test "parseToolCalls recovers <invoke> with inline JSON body shape" {
    const response =
        \\<invoke name="schedule">
        \\{"action": "list"}
        \\</invoke>
    ;
    const result = try parseToolCalls(std.testing.allocator, response);
    defer std.testing.allocator.free(result.text);
    defer {
        for (result.calls) |call| {
            std.testing.allocator.free(call.name);
            std.testing.allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| std.testing.allocator.free(id);
        }
        std.testing.allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("schedule", result.calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, result.calls[0].arguments_json, "\"action\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.calls[0].arguments_json, "\"list\"") != null);
}

test "parseToolCalls handles multiple <invoke> calls in one response" {
    const response =
        \\<invoke name="memory_recall">
        \\<parameter name="query">preferences</parameter>
        \\<parameter name="limit">5</parameter>
        \\</invoke>
        \\<invoke name="schedule">
        \\{"action": "list"}
        \\</invoke>
    ;
    const result = try parseToolCalls(std.testing.allocator, response);
    defer std.testing.allocator.free(result.text);
    defer {
        for (result.calls) |call| {
            std.testing.allocator.free(call.name);
            std.testing.allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| std.testing.allocator.free(id);
        }
        std.testing.allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 2), result.calls.len);
    try std.testing.expectEqualStrings("memory_recall", result.calls[0].name);
    try std.testing.expectEqualStrings("schedule", result.calls[1].name);
    // limit=5 should be inlined as a number, not quoted as a string.
    try std.testing.expect(std.mem.indexOf(u8, result.calls[0].arguments_json, "\"limit\":5") != null);
}

test "parseToolCalls preserves surrounding text with <invoke>" {
    const response =
        \\Looking this up.
        \\<invoke name="runtime_info">
        \\<parameter name="section">session</parameter>
        \\</invoke>
        \\Then I'll summarize.
    ;
    const result = try parseToolCalls(std.testing.allocator, response);
    defer std.testing.allocator.free(result.text);
    defer {
        for (result.calls) |call| {
            std.testing.allocator.free(call.name);
            std.testing.allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| std.testing.allocator.free(id);
        }
        std.testing.allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Looking this up") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "summarize") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "<invoke") == null);
}

test "parseToolCalls escapes special chars in <parameter> values" {
    const response =
        \\<invoke name="shell">
        \\<parameter name="command">echo "hi"</parameter>
        \\</invoke>
    ;
    const result = try parseToolCalls(std.testing.allocator, response);
    defer std.testing.allocator.free(result.text);
    defer {
        for (result.calls) |call| {
            std.testing.allocator.free(call.name);
            std.testing.allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| std.testing.allocator.free(id);
        }
        std.testing.allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    // The inner quotes must be JSON-escaped.
    try std.testing.expect(std.mem.indexOf(u8, result.calls[0].arguments_json, "echo \\\"hi\\\"") != null);
    // Must still parse as valid JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.calls[0].arguments_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("echo \"hi\"", parsed.value.object.get("command").?.string);
}

test "DIAGNOSTIC Nova exact payload context_snapshot trailing prose" {
    const payload =
        \\<invoke name="context_snapshot">
        \\{}
        \\</invoke> Live Runtime Test — Executing Now
    ;
    const result = try parseToolCalls(std.testing.allocator, payload);
    defer std.testing.allocator.free(result.text);
    defer {
        for (result.calls) |c| {
            std.testing.allocator.free(c.name);
            std.testing.allocator.free(c.arguments_json);
            if (c.tool_call_id) |id| std.testing.allocator.free(id);
        }
        std.testing.allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("context_snapshot", result.calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "<invoke") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Live Runtime Test") != null);
}

test "DIAGNOSTIC Nova exact payload multi-invoke no newline between" {
    const payload =
        \\<invoke name="runtime_info">
        \\{"section": "summary", "verbose": true}</invoke>
        \\<invoke name="memory_recall">
        \\{"query": "test memory system", "limit": 3}</invoke>
    ;
    const result = try parseToolCalls(std.testing.allocator, payload);
    defer std.testing.allocator.free(result.text);
    defer {
        for (result.calls) |c| {
            std.testing.allocator.free(c.name);
            std.testing.allocator.free(c.arguments_json);
            if (c.tool_call_id) |id| std.testing.allocator.free(id);
        }
        std.testing.allocator.free(result.calls);
    }
    try std.testing.expectEqual(@as(usize, 2), result.calls.len);
    try std.testing.expectEqualStrings("runtime_info", result.calls[0].name);
    try std.testing.expectEqualStrings("memory_recall", result.calls[1].name);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "<invoke") == null);
}

test "parseToolCalls prefers <tool_call> over <invoke> when both present" {
    const response =
        \\<tool_call>
        \\{"name": "shell", "arguments": {"command": "ls"}}
        \\</tool_call>
        \\<invoke name="runtime_info">
        \\<parameter name="section">summary</parameter>
        \\</invoke>
    ;
    const result = try parseToolCalls(std.testing.allocator, response);
    defer std.testing.allocator.free(result.text);
    defer {
        for (result.calls) |call| {
            std.testing.allocator.free(call.name);
            std.testing.allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| std.testing.allocator.free(id);
        }
        std.testing.allocator.free(result.calls);
    }
    // First-win: <tool_call> takes precedence to preserve existing behavior.
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
}
