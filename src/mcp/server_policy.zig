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
///   - memory read + non-destructive write: the "composable brain" play —
///     an external agent can query and append, but cannot forget/archive/
///     demote/purge (destructive ops stay agent-only).
///   - web_search / web_fetch: outbound but read-only and rate-bounded;
///     net_security egress filtering still applies at the tool layer.
///
/// Everything NOT in this list is excluded by default. Notable exclusions
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
    // Memory — read + non-destructive append. Destructive memory ops
    // (forget/archive/demote/purge/maintain/edit) are deliberately absent.
    "memory_recall",
    "memory_list",
    "memory_timeline",
    "memory_store",
    // Web — outbound but read-only; net_security egress filter still gates.
    "web_search",
    "web_fetch",
};

/// Environment variable that opts an operator into exposing the *entire*
/// tool registry, bypassing the curated subset. Off unless set to "1".
pub const expose_all_env = "NULLALIS_MCP_EXPOSE_ALL";

/// Returns true when `tool_name` is in the curated safe subset.
pub fn isSafeToExpose(tool_name: []const u8) bool {
    for (safe_tool_names) |n| {
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

/// The exposure decision for one tool, given the resolved `expose_all` flag.
pub fn shouldExpose(tool_name: []const u8, expose_all: bool) bool {
    if (expose_all) return true;
    return isSafeToExpose(tool_name);
}

/// Count of tools in the curated subset — used in tests and the startup log.
pub fn safeSubsetCount() usize {
    return safe_tool_names.len;
}

// ── Tests ───────────────────────────────────────────────────────

const testing = std.testing;

test "server_policy: safe subset includes read-only and memory tools" {
    try testing.expect(isSafeToExpose("calculator"));
    try testing.expect(isSafeToExpose("file_read"));
    try testing.expect(isSafeToExpose("memory_recall"));
    try testing.expect(isSafeToExpose("memory_store"));
    try testing.expect(isSafeToExpose("web_search"));
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
    try testing.expect(shouldExpose("calculator", false));
    try testing.expect(!shouldExpose("shell", false));
    // Escape hatch: everything passes.
    try testing.expect(shouldExpose("shell", true));
    try testing.expect(shouldExpose("calculator", true));
}

test "server_policy: unknown tool name is not exposed by default" {
    try testing.expect(!isSafeToExpose("some_future_tool"));
    try testing.expect(!shouldExpose("some_future_tool", false));
}

test "server_policy: safe subset is non-empty" {
    try testing.expect(safeSubsetCount() > 0);
}
