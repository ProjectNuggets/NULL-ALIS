---
phase: 01-agent-execution-contract
reviewed: 2026-04-10T22:15:00Z
depth: deep
files_reviewed: 9
files_reviewed_list:
  - src/tools/metadata.zig
  - src/agent/execution_mode.zig
  - src/security/approval_modes.zig
  - src/agent/abort.zig
  - src/agent/root.zig
  - src/agent/commands.zig
  - src/security/policy.zig
  - src/tools/root.zig
  - src/security/root.zig
findings:
  critical: 1
  warning: 3
  info: 2
  total: 6
status: issues_found
tags: [prose, prose/planning]
---

# Phase 1: Code Review Report

**Reviewed:** 2026-04-10T22:15:00Z
**Depth:** deep (cross-file tracing across all 9 files)
**Files Reviewed:** 9
**Status:** issues_found

## Summary

Phase 1 introduces four new type modules (metadata, execution_mode, approval_modes, abort) and wires them into the agent runtime (root.zig), slash commands (commands.zig), and security policy (policy.zig). The foundational type files are well-structured: conservative-default fail-closed policy, proper atomic memory ordering for cross-thread cancellation, and comprehensive inline tests. However, cross-file analysis reveals one critical bug (CancellationToken never reset between turns), two security-relevant warnings in the approval policy, and an uninformative block message that will confuse the LLM.

## Critical Issues

### CR-01: CancellationToken never reset between turns -- agent permanently stuck after first cancel

**File:** `src/agent/root.zig:1235` (turn entry), `src/agent/root.zig:1532` (cancel check), `src/agent/abort.zig:26` (reset method)

**Issue:** The `CancellationToken` has a `reset()` method (abort.zig:26) but it is never called in production code. Once an HTTP handler or CLI signals `cancel()`, the atomic boolean stays `true` forever. Every subsequent call to `turn()` immediately hits the `isCancelled()` check at line 1532 and returns `"[Cancelled]"` without processing the user message. The agent becomes permanently unresponsive until the process is restarted.

The `reset()` method is only exercised in the abort.zig unit test (line 71). A grep across the entire `src/` tree confirms zero production call sites.

**Fix:** Reset the cancellation token at the start of each turn:

```zig
// src/agent/root.zig, inside pub fn turn(), after line 1236
pub fn turn(self: *Agent, user_message: []const u8) ![]const u8 {
    const turn_start_ms = std.time.milliTimestamp();
    self.cancellation_token.reset(); // Clear stale cancellation from previous turn
    commands.refreshSubagentToolContext(self);
```

This is safe because `reset()` uses `.release` ordering and `isCancelled()` uses `.acquire`, so a concurrent `cancel()` call racing with `reset()` at turn start will be correctly observed on the next `isCancelled()` poll within the iteration loop.

## Warnings

### WR-01: Execution mode block message is uninformative -- LLM will retry blocked tools

**File:** `src/agent/root.zig:986`

**Issue:** When `preflightToolPolicy` blocks a tool due to execution mode, the output is the bare string `"blocked"`. Compare this to the other block messages in the same function: `"Action blocked: agent is in read-only mode"` (line 964) and `"Action budget exhausted"` (line 973). The LLM receives no context about *why* the tool was blocked or what mode it is in. Per the reflection prompt, the LLM is instructed to "not repeat the same blocked call" but the generic "blocked" gives it no signal that mode is the cause. This will likely lead to the LLM retrying the same tool or attempting similar mutating tools, wasting iterations.

**Fix:**

```zig
// src/agent/root.zig:984-989
return .{ .blocked = .{
    .name = call.name,
    .output = try std.fmt.allocPrint(
        self.allocator,
        "Tool blocked: '{s}' is not allowed in {s} mode",
        .{ call.name, self.execution_mode.toSlice() },
    ),
    .success = false,
    .tool_call_id = call.tool_call_id,
} };
```

Note: this requires checking whether `output` is arena-allocated or allocator-owned in the result lifecycle. If `ToolExecutionResult.output` is expected to be a string literal or arena-allocated, use the arena instead. The current code uses string literals for the other block messages, so an `allocPrint` changes the ownership semantics. A simpler alternative is a comptime string per mode, but the dynamic version is more informative.

**Simpler alternative (no allocation):**

```zig
.output = switch (self.execution_mode) {
    .plan => "Tool blocked: not allowed in plan mode (read-only tools only)",
    .review => "Tool blocked: not allowed in review mode (read-only tools only)",
    .background => "Tool blocked: not allowed in background mode (background-safe tools only)",
    .execute => unreachable, // execute never reaches this branch
},
```

### WR-02: resolveApproval always uses conservative metadata -- renders approval policy ineffective for known tools

**File:** `src/security/policy.zig:282-284`

**Issue:** `SecurityPolicy.resolveApproval` unconditionally calls `ToolMetadata.conservative(tool_name)`, which sets `mutating=true` and `risk_level=.high` for every tool. This means for `supervised` autonomy, every single tool resolves to `confirm_once` -- even tools that have comptime metadata declaring `read_only=true`. The `lookupMetadata` function and the comptime `metadataFor` extractor exist but are completely bypassed by `resolveApproval`.

The summary acknowledges this: "Empty registry (`&.{}`) passed to lookupMetadata -- all tools get conservative default until comptime registry is wired." However, `resolveApproval` does not even call `lookupMetadata`; it goes straight to `conservative()`. This makes the entire approval policy distinction (auto_approve vs confirm_once vs deny) meaningless in practice for supervised mode -- everything is confirm_once.

**Fix:** When the comptime registry is wired, `resolveApproval` should look up actual metadata:

```zig
pub fn resolveApproval(self: *const SecurityPolicy, tool_name: []const u8) approval_modes_mod.ApprovalPolicy {
    const meta = tool_metadata_mod.lookupMetadata(tool_name, &.{}) orelse
        tool_metadata_mod.ToolMetadata.conservative(tool_name);
    return approval_modes_mod.ApprovalPolicy.forTool(meta, self.autonomy);
}
```

This at least matches the pattern used in `preflightToolPolicy` (root.zig:981-982) which already does `lookupMetadata` with fallback to `conservative`. Both paths should be consistent.

### WR-03: Supervised approval priority -- read_only check shadows operator_only for dual-flagged tools

**File:** `src/security/approval_modes.zig:37-42`

**Issue:** In `ApprovalPolicy.forTool` for `.supervised` autonomy, the `read_only` flag is checked before `operator_only`:

```zig
if (meta.flags.read_only) return .auto_approve;   // line 38
if (meta.flags.operator_only) return .deny;         // line 39
```

If a tool declares both `read_only=true` and `operator_only=true` (e.g., a diagnostic tool that reads sensitive operator-level data), the `read_only` check fires first and returns `.auto_approve`, bypassing the `operator_only` deny. The `operator_only` flag is intended to restrict tools to operators only, but a dual-flagged tool would be auto-approved for any supervised agent.

Currently no tools declare both flags simultaneously, so this is not exploitable today. However, the flag ordering creates a latent privilege escalation path if a future tool is tagged with both.

**Fix:** Check `operator_only` before `read_only`:

```zig
.supervised => {
    if (meta.flags.operator_only) return .deny;
    if (meta.flags.read_only) return .auto_approve;
    if (meta.flags.mutating) return .confirm_once;
    return .auto_approve;
},
```

## Info

### IN-01: ToolFlags allows contradictory flag combinations without validation

**File:** `src/tools/metadata.zig:17-23`

**Issue:** `ToolFlags` is a packed struct where `read_only` and `mutating` are independent booleans. A tool could declare `{ .read_only = true, .mutating = true }` which is semantically contradictory. There is no compile-time or runtime validation preventing this. If both are set, `allowsTool` in `.plan` mode would return `true` (because it only checks `read_only`), allowing a mutating tool to execute in plan mode.

**Fix:** Add a validation function and call it from `metadataFor`:

```zig
pub fn validate(self: ToolFlags) !void {
    if (self.read_only and self.mutating) return error.ContradictoryFlags;
}
```

### IN-02: Empty registry slice `&.{}` passed to lookupMetadata is a placeholder that should be tracked

**File:** `src/agent/root.zig:981`

**Issue:** `lookupMetadata(call.name, &.{})` passes an empty registry, so every tool falls through to the conservative default. This is documented in the summaries as intentional ("comptime registry wiring deferred to future plan") but there is no TODO comment at the call site and no tracking issue referenced. When the registry is eventually wired, this call site must be updated -- but without a marker it may be overlooked.

**Fix:** Add a comment for traceability:

```zig
// TODO(phase-2+): wire comptime tool registry here instead of empty slice
const meta = tool_metadata.lookupMetadata(call.name, &.{}) orelse
    tool_metadata.ToolMetadata.conservative(call.name);
```

---

_Reviewed: 2026-04-10T22:15:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: deep_
