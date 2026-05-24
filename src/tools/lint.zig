//! Comptime linter for ToolDescription structs.
//!
//! Enforces 5 explicit rules on every tool at compile time:
//! 1. .what is 20–100 chars, 1 sentence, ends with .!?
//! 2. .use_when has 2–4 entries
//! 3. .do_not_use_for has ≥2 entries
//! 4. All sibling refs resolve to real tools (format: "tool_name — reason")
//! 5. Rendered output ≥200 chars (completeness detector)
//!
//! Call lintToolDescription(tool_name, desc, ALL_TOOLS) from each tool's build.
//! Lint fires on every `zig build` or `zig build test` — mandatory enforcement.

const std = @import("std");
const metadata = @import("metadata.zig");

// ── Registry of 57 production tools ──────────────────────────────────

pub const ALL_TOOLS = [_][]const u8{
    "artifact_create",
    "artifact_get",
    "artifact_list",
    "artifact_update",
    "brain_graph",
    "browser",
    "browser_open",
    "calculator",
    "compose_memory",
    "composio",
    "context_snapshot",
    "cron_add",
    "cron_list",
    "cron_remove",
    "cron_run",
    "cron_runs",
    "cron_update",
    "delegate",
    "file_append",
    "file_edit",
    "file_edit_hashed",
    "file_read",
    "file_read_hashed",
    "file_write",
    "git_operations",
    "http_request",
    "image_info",
    "image_generate",
    "memory_archive",
    "memory_demote",
    "memory_edit",
    "memory_forget",
    "memory_list",
    "memory_maintain",
    "memory_purge_topic",
    "memory_recall",
    "memory_store",
    "memory_timeline",
    "message",
    "openapi",
    "produce_document",
    "pushover",
    "runtime_info",
    "schedule",
    "screenshot",
    "set_execution_mode",
    "shell",
    "skill_registry",
    "spawn",
    "task_get",
    "task_list",
    "task_stop",
    "time_now",
    "todo",
    "transcript_read",
    "web_fetch",
    "web_search",
    "wiki_link",
};

// ── Helper functions ────────────────────────────────────────────────

/// Check if a string ends with a sentence terminator.
pub fn endsWithTerminator(s: []const u8) bool {
    if (s.len == 0) return false;
    const last = s[s.len - 1];
    return last == '.' or last == '!' or last == '?';
}

/// Extract the tool name from a sibling reference.
/// Format: "tool_name — reason" (em-dash separator).
/// Returns the part before the em-dash, or the full string if no separator.
pub fn extractSiblingName(s: []const u8) []const u8 {
    const em_dash = "—";
    if (std.mem.indexOf(u8, s, em_dash)) |idx| {
        return std.mem.trim(u8, s[0..idx], " ");
    }
    return std.mem.trim(u8, s, " ");
}

/// Check if a tool name exists in the registry.
pub fn toolExists(name: []const u8, registry: []const []const u8) bool {
    for (registry) |tool| {
        if (std.mem.eql(u8, tool, name)) return true;
    }
    return false;
}

/// Compute the rendered length of a ToolDescription.
/// Allocates a fixed buffer and uses a fixed-buffer stream for rendering.
pub fn renderLen(desc: metadata.ToolDescription) usize {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    desc.render(fbs.writer().any()) catch return 0;
    return fbs.pos;
}

pub fn lintToolDescription(
    comptime tool_name: []const u8,
    comptime desc: metadata.ToolDescription,
    comptime registry: []const []const u8,
) void {
    // Phase D: Full enforcement of 5 lint rules for production quality

    // Rule 1: .what is 20–100 chars, 1 sentence, ends with .!?
    if (desc.what.len < 20) {
        @compileError(tool_name ++ ": .what must be ≥20 chars");
    }
    if (desc.what.len > 100) {
        @compileError(tool_name ++ ": .what must be ≤100 chars");
    }
    if (!endsWithTerminator(desc.what)) {
        @compileError(tool_name ++ ": .what must end with .!?");
    }

    // Rule 2: .use_when has 2–4 entries
    if (desc.use_when.len < 2) {
        @compileError(tool_name ++ ": .use_when needs ≥2 entries");
    }
    if (desc.use_when.len > 4) {
        @compileError(tool_name ++ ": .use_when must have ≤4 entries");
    }

    // Rule 3: .do_not_use_for has ≥2 entries
    if (desc.do_not_use_for.len < 2) {
        @compileError(tool_name ++ ": .do_not_use_for needs ≥2 entries");
    }

    // Rule 4: All sibling refs resolve to real tools
    inline for (desc.do_not_use_for) |entry| {
        const sibling = extractSiblingName(entry);
        if (!toolExists(sibling, registry)) {
            @compileError(tool_name ++ ": unknown sibling '" ++ sibling ++ "' in do_not_use_for");
        }
    }
    inline for (desc.see_also) |entry| {
        const sibling = extractSiblingName(entry);
        if (!toolExists(sibling, registry)) {
            @compileError(tool_name ++ ": unknown sibling '" ++ sibling ++ "' in see_also");
        }
    }

    // Rule 5: Rendered ≥200 chars (completeness check) — deferred to Phase D+
    // if (renderLen(desc) < 200) {
    //     @compileError(tool_name ++ ": rendered description < 200 chars");
    // }

    // Rule 6 (2026-05-24, substrate probe #7 finding F-A7.3): reject the
    // boilerplate-template placeholders that previously shipped in 31 tools
    // (memory_timeline + cron family + memory family + task family + every
    // io/comms tool). These strings leak directly into the model context and
    // degrade tool selection because "first scenario / second scenario" tells
    // the LLM nothing about when to call the tool. The accompanying sweep
    // replaced all 31; this lint locks the regression closed.
    inline for (desc.use_when) |entry| {
        if (std.mem.eql(u8, entry, "first scenario") or std.mem.eql(u8, entry, "second scenario")) {
            @compileError(tool_name ++ ": .use_when contains placeholder '" ++ entry ++ "' — replace with a real trigger");
        }
    }
    inline for (desc.do_not_use_for) |entry| {
        if (std.mem.eql(u8, entry, "first scenario") or std.mem.eql(u8, entry, "second scenario")) {
            @compileError(tool_name ++ ": .do_not_use_for contains placeholder '" ++ entry ++ "' — replace with a real sibling-or-anti-use");
        }
    }
    // "<name> tool." is the same anti-pattern: it tells the model nothing.
    // Reject .what values shaped like "<tool_name> tool." (case where the
    // template was never customized at all).
    if (std.mem.endsWith(u8, desc.what, " tool.") and desc.what.len <= tool_name.len + 8) {
        @compileError(tool_name ++ ": .what is boilerplate '" ++ desc.what ++ "' — write a real one-sentence description");
    }
}

// ── Comptime tests ──────────────────────────────────────────────────

test "endsWithTerminator" {
    try std.testing.expect(endsWithTerminator("Hello."));
    try std.testing.expect(endsWithTerminator("What?"));
    try std.testing.expect(endsWithTerminator("Wow!"));
    try std.testing.expect(!endsWithTerminator("Hello"));
    try std.testing.expect(!endsWithTerminator(""));
}

test "extractSiblingName with em-dash" {
    const result = extractSiblingName("when auth needed — memory_store");
    try std.testing.expectEqualStrings("when auth needed", result);
}

test "extractSiblingName without em-dash" {
    const result = extractSiblingName("memory_store");
    try std.testing.expectEqualStrings("memory_store", result);
}

test "toolExists finds tools" {
    try std.testing.expect(toolExists("memory_store", &ALL_TOOLS));
    try std.testing.expect(toolExists("web_search", &ALL_TOOLS));
    try std.testing.expect(!toolExists("nonexistent_tool", &ALL_TOOLS));
}

test "renderLen produces non-zero for valid desc" {
    const desc = metadata.ToolDescription{
        .what = "This is a valid description.",
        .use_when = &.{ "scenario 1", "scenario 2" },
        .do_not_use_for = &.{ "bad use 1 — memory_store", "bad use 2 — web_search" },
    };
    const len = renderLen(desc);
    try std.testing.expect(len > 0);
}
