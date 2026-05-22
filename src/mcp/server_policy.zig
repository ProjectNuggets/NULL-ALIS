//! MCP server — tool-exposure safety policy.
//!
//! An MCP server is an attack surface: whatever appears in `tools/list`
//! becomes callable by an *external, untrusted* client over `tools/call`.
//! nullalis's full registry includes arbitrary shell execution, filesystem
//! writes, outbound HTTP, browser control, message delivery, and
//! destructive memory operations. Exposing those unauthenticated would be
//! remote code execution by design.
//!
//! This module is the single source of truth for the exposure decision.
//! Default posture: **deny-by-default**, allow only a curated read-mostly
//! subset. An operator can opt into the full registry with
//! `NULLALIS_MCP_EXPOSE_ALL=1` for trusted-stdio deployments (e.g. a local
//! pairing between two nullalis instances the operator controls) — that is
//! a deliberate, documented escape hatch, not the default.

const std = @import("std");

/// The curated safe subset. Selection rationale:
///   - read-only / introspection: bounded, no side effects, safe to expose.
///   - web_search / web_fetch: outbound but read-only and rate-bounded;
///     net_security egress filtering still applies at the tool layer.
///   - memory read + non-destructive append (`memory_tool_names`): the
///     "composable brain over MCP" payload — exposed ONLY when `mcp serve`
///     has bound a memory backend (`shouldExpose`'s `memory_available`);
///     destructive memory ops stay excluded regardless.
///
/// Everything NOT in these lists is excluded by default. Notable exclusions
/// and why:
///   shell, git_operations               — arbitrary code execution
///   file_write/edit/append/*_hashed      — filesystem mutation
///   browser, browser_open, screenshot    — local environment control
///   composio, image_generate             — third-party side effects / cost
///   message, pushover                    — outbound delivery (spoofing)
///   delegate, spawn                      — recursive agent invocation
///   schedule, cron_*                     — persistent scheduled side effects
///   set_execution_mode, context_snapshot — agent-internal self-control
///   memory_edit/forget/archive/demote/
///     purge_topic/maintain, compose_memory,
///     wiki_link, brain_graph, todo,
///     transcript_read                    — destructive or agent-private
const safe_tool_names = [_][]const u8{
    // Introspection / compute — pure, bounded.
    "calculator",
    "time_now",
    "runtime_info",
    "image_info",
    // Filesystem — read only. file_read is path-sandboxed by the tool
    // itself (workspace_dir + allowed_paths); no write counterpart exposed.
    "file_read",
    // Web — outbound but read-only; net_security egress filter still gates.
    "web_search",
    "web_fetch",
};

/// Memory tools — read + non-destructive append. Exposed only when the
/// server has bound a memory backend (`memory_available`); listing them
/// unbound would advertise non-functional tools. Destructive memory ops
/// (edit/forget/archive/demote/purge) are deliberately NOT here.
const memory_tool_names = [_][]const u8{
    "memory_recall",
    "memory_list",
    "memory_timeline",
    "memory_store",
};

/// Environment variable that opts an operator into exposing the *entire*
/// tool registry, bypassing the curated subset. Off unless set to "1".
pub const expose_all_env = "NULLALIS_MCP_EXPOSE_ALL";

/// Returns true when `tool_name` is in the always-safe compute/file/web subset.
pub fn isSafeToExpose(tool_name: []const u8) bool {
    for (safe_tool_names) |n| {
        if (std.mem.eql(u8, n, tool_name)) return true;
    }
    return false;
}

/// Returns true when `tool_name` is a memory tool — exposed conditionally
/// on a bound memory backend (see `shouldExpose`).
pub fn isMemoryTool(tool_name: []const u8) bool {
    for (memory_tool_names) |n| {
        if (std.mem.eql(u8, n, tool_name)) return true;
    }
    return false;
}

/// Resolve whether the "expose everything" escape hatch is active. Reads
/// the environment once; the caller should cache the result for the
/// process lifetime.
pub fn exposeAllEnabled(allocator: std.mem.Allocator) bool {
    const raw = std.process.getEnvVarOwned(allocator, expose_all_env) catch return false;
    defer allocator.free(raw);
    return std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "1");
}

/// The exposure decision for one tool.
///   - `expose_all` (the escape hatch) bypasses every restriction.
///   - memory tools require `memory_available` — a backend bound into
///     `mcp serve`; listing them unbound would advertise broken tools.
///   - otherwise: the always-safe compute/file/web subset.
pub fn shouldExpose(tool_name: []const u8, expose_all: bool, memory_available: bool) bool {
    if (expose_all) return true;
    if (isMemoryTool(tool_name)) return memory_available;
    return isSafeToExpose(tool_name);
}

/// Count of curated tools exposed by default — used in the startup log.
/// Includes the memory tools only when a backend is bound.
pub fn safeSubsetCount(memory_available: bool) usize {
    return safe_tool_names.len + if (memory_available) memory_tool_names.len else 0;
}

// ── Tests ───────────────────────────────────────────────────────

const testing = std.testing;

test "server_policy: safe subset includes read-only compute, file, and web tools" {
    try testing.expect(isSafeToExpose("calculator"));
    try testing.expect(isSafeToExpose("file_read"));
    try testing.expect(isSafeToExpose("web_search"));
    try testing.expect(isSafeToExpose("web_fetch"));
}

test "server_policy: memory tools are exposed only when a backend is bound" {
    // Classified as memory tools.
    try testing.expect(isMemoryTool("memory_recall"));
    try testing.expect(isMemoryTool("memory_list"));
    try testing.expect(isMemoryTool("memory_timeline"));
    try testing.expect(isMemoryTool("memory_store"));
    try testing.expect(!isMemoryTool("calculator"));
    // Not in the always-safe subset...
    try testing.expect(!isSafeToExpose("memory_store"));
    // ...shouldExpose gates them on memory_available: unbound → hidden,
    // bound → exposed (the "composable brain over MCP" payload).
    try testing.expect(!shouldExpose("memory_store", false, false));
    try testing.expect(shouldExpose("memory_store", false, true));
    try testing.expect(!shouldExpose("memory_recall", false, false));
    try testing.expect(shouldExpose("memory_recall", false, true));
}

test "server_policy: dangerous tools are excluded from the safe subset" {
    try testing.expect(!isSafeToExpose("shell"));
    try testing.expect(!isSafeToExpose("git_operations"));
    try testing.expect(!isSafeToExpose("file_write"));
    try testing.expect(!isSafeToExpose("file_edit"));
    try testing.expect(!isSafeToExpose("browser"));
    try testing.expect(!isSafeToExpose("composio"));
    try testing.expect(!isSafeToExpose("message"));
    try testing.expect(!isSafeToExpose("delegate"));
    try testing.expect(!isSafeToExpose("spawn"));
    try testing.expect(!isSafeToExpose("memory_forget"));
    try testing.expect(!isSafeToExpose("memory_archive"));
    try testing.expect(!isSafeToExpose("set_execution_mode"));
}

test "server_policy: shouldExpose honors the expose_all escape hatch" {
    // Default posture: only the safe subset.
    try testing.expect(shouldExpose("calculator", false, false));
    try testing.expect(!shouldExpose("shell", false, false));
    // Escape hatch: everything passes, even with no memory backend bound.
    try testing.expect(shouldExpose("shell", true, false));
    try testing.expect(shouldExpose("calculator", true, false));
    try testing.expect(shouldExpose("memory_store", true, false));
}

test "server_policy: unknown tool name is not exposed by default" {
    try testing.expect(!isSafeToExpose("some_future_tool"));
    try testing.expect(!shouldExpose("some_future_tool", false, true));
}

test "server_policy: safe subset is non-empty and grows with a memory backend" {
    try testing.expect(safeSubsetCount(false) > 0);
    try testing.expect(safeSubsetCount(true) > safeSubsetCount(false));
}
