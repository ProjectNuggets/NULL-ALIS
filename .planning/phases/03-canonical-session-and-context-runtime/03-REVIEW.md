---
phase: 03-canonical-session-and-context-runtime
reviewed: 2026-04-11T00:00:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - src/agent/commands.zig
  - src/agent/root.zig
  - src/session.zig
  - src/root.zig
findings:
  critical: 0
  warning: 4
  info: 3
  total: 7
status: issues_found
---

# Phase 03: Code Review Report

**Reviewed:** 2026-04-11T00:00:00Z
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Note on Scope

The config listed 8 files, but 4 of them do not exist at the specified paths in the working tree:

- `src/agent/context_engine.zig` — not found
- `src/agent/transcript.zig` — not found
- `src/session/identity.zig` — not found
- `src/session/root.zig` — not found

The four remaining files (`src/agent/commands.zig`, `src/agent/root.zig`, `src/session.zig`, `src/root.zig`) were reviewed. `src/root.zig` is a pure module re-export file with no logic; findings are against the three substantive files.

## Summary

The session and agent core is well-structured: `SessionManager` correctly uses a two-level mutex strategy (short-hold manager lock for map operations, long-hold session lock for turn execution), the queue overflow logic is sound, and the compaction/continuity checkpoint pipeline is correctly guarded with `errdefer` chains. Test coverage for `session.zig` is thorough.

Four warnings were found: a use-after-defer in `handleApproveCommand` that produces a stale ID in the response, an `@constCast` in `executeRuntimeInfoSection` that discards const-correctness and risks a double-free, an `evictIdle` deadlock window between the `tryLock` call and the deferred `session.mutex.unlock()`, and a `clearSessionState` that passes `?[]const u8` directly to a function expecting `[]const u8`. Three info items cover escaped newlines in a user-facing format string, a redundant `@import` inside a function body, and a TODO comment in the production turn loop.

## Warnings

### WR-01: Use-After-Defer — `pending_exec_id` read after `clearPendingExecCommand` is deferred

**File:** `src/agent/commands.zig:2159-2170`
**Issue:** `command_to_run` aliases `self.pending_exec_command` (a raw pointer to the owned slice). On line 2159, `defer clearPendingExecCommand(self)` is registered. On line 2165, `runShellCommand` executes successfully, then on line 2167-2170 the response string is formatted using `self.pending_exec_id`. However the `defer` fires at the *end of the block* (line 2172), which is after the `allocPrint`. The ID itself is a `u64` value field so there is no memory hazard, but `command_to_run` is a dangling pointer if `clearPendingExecCommand` had freed it before the format string was assembled — this is safe only because defers run in reverse order after the final statement. The real hazard is that the formatted message always prints the *pre-clear* `pending_exec_id`, which is correct, but this is fragile: if any future path causes an early return between lines 2165 and 2172 while the defer is still pending, the id in the message will refer to a cleared slot. The cleaner fix is to capture the id in a local before registering the defer.

**Fix:**
```zig
const command_to_run = pending_command;
const exec_id_snapshot = self.pending_exec_id;  // capture before defer
defer clearPendingExecCommand(self);

if (decision == .allow_always) {
    self.exec_ask = .off;
}

const output = try runShellCommand(self, command_to_run, true);
defer self.allocator.free(output);
return try std.fmt.allocPrint(
    self.allocator,
    "Approved exec (id={d}).\n{s}",
    .{ exec_id_snapshot, output },
);
```

---

### WR-02: `@constCast` in `executeRuntimeInfoSection` discards ownership semantics

**File:** `src/agent/commands.zig:1578`
**Issue:** `result.output` is a `[]const u8` returned by the tool. Casting it with `@constCast` to satisfy the `![]u8` return type sidesteps the type system without actually transferring ownership. The caller (`formatRuntimeStatus`) stores the result in `summary_json` and `integrations_json` and later calls `self.allocator.free()` on them. If the tool returns a string literal or a slice backed by memory it owns (not the session allocator), the `free()` call is undefined behaviour — it passes a pointer that was never allocated with `self.allocator`. This is a latent safety issue that depends on the tool's internal implementation.

**Fix:** Either have the tool return owned memory, or explicitly dupe in `executeRuntimeInfoSection`:
```zig
// Instead of:
return @constCast(result.output);

// Use:
return try self.allocator.dupe(u8, result.output);
```
This ensures the caller always receives allocator-owned memory it is safe to free.

---

### WR-03: `evictIdle` holds manager mutex while calling `persistSessionCheckpoint` — potential long hold

**File:** `src/session.zig:714-753`
**Issue:** `evictIdle` acquires `self.mutex` (manager-level) with `defer self.mutex.unlock()` on line 716, then for each candidate session calls `session.agent.persistSessionCheckpoint(...)` on lines 735 and 737. `persistSessionCheckpoint` can invoke a summarisation LLM call (via `persistSessionSemanticSummary` → `self.provider.chat(...)` which has a configurable `timeout_secs`). Holding the manager mutex for the entire duration of an LLM call means **all** concurrent `processMessage` calls and `getOrCreate` calls are blocked for potentially tens of seconds. This can be observed in high-concurrency deployments where eviction and a new inbound message race.

The secondary hazard: line 730 registers `defer session.mutex.unlock()` inside the iterator loop, but in Zig `defer` in a loop does not fire per-iteration — it fires at the end of the enclosing scope (the `while` body), which happens to be correct here because each iteration introduces its own block. This is fine, but worth an explicit code comment.

**Fix:** Separate the checkpoint phase from the map-mutation phase so the manager mutex is not held during I/O:
```zig
// Phase 1: collect sessions to evict while holding manager mutex (fast)
self.mutex.lock();
var candidates = collect candidates with tryLock ...;
self.mutex.unlock();

// Phase 2: checkpoint each candidate (no manager mutex held)
for (candidates) |session| {
    session.agent.persistSessionCheckpoint(...);
}

// Phase 3: re-acquire manager mutex and remove from map
self.mutex.lock();
defer self.mutex.unlock();
remove confirmed candidates ...;
```

---

### WR-04: `clearSessionState` passes `?[]const u8` to `clearAutoSaved` which likely expects `[]const u8`

**File:** `src/agent/commands.zig:1267-1269`
**Issue:** `self.memory_session_id` is typed `?[]const u8`. The call `store.clearAutoSaved(self.memory_session_id)` passes the optional directly. If `clearAutoSaved` is defined as accepting `[]const u8`, this coerces the optional to a non-optional (Zig will not implicitly unwrap optionals — it may require `?[]const u8` on the callee side). If the callee does accept `?[]const u8` this is benign, but if not it is a type mismatch that will silently no-op when `memory_session_id` is null, leaving auto-saved memories stale after a `/new` or `/reset`. Compare with line 1437 in `root.zig` where the same field is correctly guarded: `mem.store(k, fc, .core, self.memory_session_id)` — memory operations accept optional session_ids. The session store's `clearAutoSaved` should be reviewed for consistency.

**Fix:** Guard the call explicitly:
```zig
if (self.session_store) |store| {
    if (self.memory_session_id) |sid| {
        store.clearAutoSaved(sid) catch {};
    }
}
```

---

## Info

### IN-01: Escaped newlines in `formatConfigMutationResponse` produce literal `\n` in output

**File:** `src/agent/commands.zig:2894-2901`
**Issue:** The format string uses `\\n` (escaped backslash-n) rather than `\n` (newline). In Zig string literals, `\\n` produces the two-character sequence `\` + `n`, not a line break. The `/config apply` command will emit a response with literal `\n` characters in it instead of line breaks, making the output unreadable in most chat interfaces.

**Fix:** Replace `\\n` with `\n` throughout the format string:
```zig
"Config {s} ({s}):\n" ++
"  action: {s}\n" ++
"  path: {s}\n" ++
...
```

---

### IN-02: `@import("execution_mode.zig")` duplicated inside function body

**File:** `src/agent/commands.zig:1633`
**Issue:** `handleModeCommand` imports `execution_mode.zig` at line 1633 with a local `const execution_mode_mod = @import("execution_mode.zig")`. The same module is already imported at the top of `agent/root.zig` and `ExecutionMode` is available via the outer scope. While Zig deduplicates imports, placing an `@import` inside a function body is unusual and makes the dependency less visible. The import can simply be moved to module scope or use the already-imported `ExecutionMode` type.

**Fix:** Remove the inline import and reference the type directly:
```zig
fn handleModeCommand(self: anytype, arg: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, arg, " \t");
    if (trimmed.len == 0) {
        return try std.fmt.allocPrint(self.allocator, "Current execution mode: {s}", .{self.execution_mode.toSlice()});
    }
    if (@TypeOf(self.execution_mode).fromString(trimmed)) |mode| {
        // ...
    }
```

---

### IN-03: TODO in production turn loop

**File:** `src/agent/root.zig:981`
**Issue:** The tool metadata preflight at line 981 contains `// TODO(phase-4+): wire comptime tool registry here instead of empty slice`. This comment is inside the hot path of every agentic tool-call iteration. Until the registry is wired, `lookupMetadata` always returns `null`, so all tools fall back to `conservative` metadata — meaning tools that should be allowed in `plan` or `review` mode are blocked unless they match the hardcoded allowlist in `isParallelSafeToolCall`. This may cause unexpected tool-block behaviour in non-execute modes.

**Fix:** Track in the backlog; add a test that verifies that known read-only tools (`file_read`, `web_search`, etc.) are permitted in `plan` mode. No immediate code change required, but the TODO should be tracked as a known limitation.

---

_Reviewed: 2026-04-11T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
