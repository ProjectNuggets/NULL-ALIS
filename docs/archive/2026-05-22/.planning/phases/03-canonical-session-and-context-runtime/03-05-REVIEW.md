---
phase: 03-05-session-crud-handlers
reviewed: 2026-04-13T00:00:00Z
depth: deep
files_reviewed: 3
files_reviewed_list:
  - src/gateway.zig
  - src/session.zig
  - src/agent/root.zig
findings:
  critical: 1
  warning: 2
  info: 2
  total: 5
status: issues_found
tags: [prose, prose/planning]
---

# Phase 3.5: Session CRUD Handlers Code Review Report

**Reviewed:** 2026-04-13
**Depth:** deep (cross-file analysis)
**Files Reviewed:** 3 (gateway.zig lines 8927-9290+10377-10384+18025-18091, session.zig, agent/root.zig)
**Status:** issues_found

## Summary

The Session CRUD handlers (Phase 3.5) are generally well-structured. Lock escalation patterns (mgr.mutex -> session.mutex -> release mgr.mutex) are correctly applied in `handleSessionGet`, `handleSessionCompact`, `handleSessionContext`, and `acquireSessionHistory`. Ownership checks via `isOwnedBy` are applied consistently in `handleSessionAction` before any session access. JSON output is well-formed with proper escaping via `jsonEscapeInto`. The `handleSessionApprove` active_refs pinning is balanced on all code paths (error and success). The delete handler's 409 Conflict guard is correct. Route dispatch at lines 10377-10384 correctly wires all 8 endpoints.

However, cross-file analysis reveals one critical use-after-free pattern in `acquireSessionHistory` and a related race in `handleSessionList`, both caused by returning borrowed pointers after releasing locks.

**Verification summary:**
- Lock escalation pattern: Correct in all 5 handlers that use it (Get, Compact, Context, acquireSessionHistory helper, Delete)
- Ownership check: Applied once in `handleSessionAction` (line 9995), before any handler dispatch -- correct
- HTTP status codes: 400 (missing key, missing body), 403 (ownership), 404 (not found), 405 (wrong method), 409 (delete conflict), 500 (internal errors) -- all appropriate
- JSON output: All responses produce valid JSON; `jsonEscapeInto` handles control chars, quotes, backslashes
- Route dispatch: 8 endpoints (list, get, delete, compact, context, export, history, approve) all wired correctly
- active_refs balance in approve handler: +1 manual pin, +1 from processMessage/acquireSessionForTurn, -1 from processMessage/releaseSessionRef, -1 manual unpin -- balanced on both success and error paths
- Delete 409 logic: Correctly checks `active_refs > 0` OR `!session.mutex.tryLock()` before proceeding

## Critical Issues

### CR-01: Use-after-free in acquireSessionHistory -- borrowed content pointers outlive session mutex

**File:** `src/gateway.zig:9172-9190`
**Issue:** `acquireSessionHistory` acquires the session mutex (line 9182), calls `session.agent.getHistory(allocator)` which returns `HistoryPair` structs where `.content` **borrows** from `session.agent.history` (see `agent/root.zig:2770`: `.content = msg.content` -- a raw slice alias, not a copy), then releases the session mutex via `defer` (line 9184) before returning.

After `acquireSessionHistory` returns, the callers (`handleSessionExport` at line 9197 and `handleSessionHistory` at line 9220) iterate over the history entries and read `.content` to build JSON via `writeHistoryMessagesJson` (line 9166: `jsonEscapeInto(w, entry.content)`). But by this point the session mutex is no longer held. If a concurrent thread processes a turn on the same session (compaction can replace history entries, or a new turn can trigger `enforceHistoryBounds` which removes oldest entries and frees their content), the borrowed `.content` slices become dangling pointers.

The `.role` field is safe (static string literals from the switch statement), but `.content` points into heap memory owned by the agent's `ArrayListUnmanaged(OwnedMessage)`.

**Affected endpoints:** GET `sessions/{key}/history`, GET/POST `sessions/{key}/export`

**Fix:** Deep-copy the content strings while the session mutex is still held. The `getHistory` function should dupe content, or a wrapper should be added:

```zig
fn acquireSessionHistory(
    allocator: std.mem.Allocator,
    mgr: *session_mod.SessionManager,
    session_key: []const u8,
) struct { history: []const @import("agent/root.zig").Agent.HistoryPair, err: ?RouteResponse } {
    mgr.mutex.lock();
    const session = mgr.sessions.get(session_key) orelse {
        mgr.mutex.unlock();
        return .{ .history = &.{}, .err = .{ .status = "404 Not Found", .body = "{\"error\":\"session_not_found\"}" } };
    };
    session.mutex.lock();
    mgr.mutex.unlock();
    defer session.mutex.unlock();

    const raw_history = session.agent.getHistory(allocator) catch {
        return .{ .history = &.{}, .err = .{ .status = "500 Internal Server Error", .body = "{\"error\":\"history_read_failed\"}" } };
    };
    // Deep-copy content so it survives past mutex release.
    for (raw_history) |*entry| {
        entry.content = allocator.dupe(u8, entry.content) catch {
            // On failure, free already-duped entries to avoid leak
            for (raw_history[0..@intFromPtr(entry) - @intFromPtr(&raw_history[0])]) |*prev| {
                allocator.free(prev.content);
            }
            allocator.free(raw_history);
            return .{ .history = &.{}, .err = .{ .status = "500 Internal Server Error", .body = "{\"error\":\"history_read_failed\"}" } };
        };
    }
    return .{ .history = raw_history, .err = null };
}
```

Callers must then also free each `entry.content` after use:
```zig
defer {
    for (history) |entry| allocator.free(entry.content);
    allocator.free(history);
}
```

Alternative: perform the entire JSON serialization inside the lock scope by inlining the JSON build into `acquireSessionHistory`.

## Warnings

### WR-01: Race condition in handleSessionList -- borrowed session_key pointers from listUserSessions

**File:** `src/gateway.zig:8944-8961` cross-ref `src/session.zig:838-841`
**Issue:** `listUserSessions` (session.zig:827) returns `SessionInfo` structs where `.session_key` borrows from the HashMap key. The HashMap key is the same memory as `session.session_key` (the owned duplicate created at session.zig:204). The mgr mutex is released when `listUserSessions` returns (via `defer self.mutex.unlock()` at session.zig:833).

The handler then iterates the returned slice to build JSON (gateway.zig:8953-8961), reading `info.session_key` without holding any lock. If a concurrent `handleSessionDelete` call runs between `listUserSessions` returning and the JSON serialization completing, the delete handler's `fetchRemove` + `session.deinit` sequence frees the `session_key` memory (session.zig:75: `allocator.free(self.session_key)`), leaving `info.session_key` as a dangling pointer.

The race window is narrow (JSON serialization is fast, and a delete for the same user must arrive concurrently), so the practical risk is low but non-zero under load.

**Fix:** `listUserSessions` should `allocator.dupe()` each `session_key` into the returned `SessionInfo`. The caller already frees the `SessionInfo` slice; it would also need to free each duped key:

```zig
// In listUserSessions:
try result.append(allocator, .{
    .session_key = try allocator.dupe(u8, entry.key_ptr.*),
    .created_at = entry.value_ptr.*.created_at,
    // ...
});

// In handleSessionList cleanup:
defer {
    for (sessions) |info| allocator.free(info.session_key);
    allocator.free(sessions);
}
```

### WR-02: Tests pass undefined as mgr pointer -- UB-adjacent and brittle

**File:** `src/gateway.zig:18072-18078, 18089`
**Issue:** Two tests pass `undefined` as the `mgr: *session_mod.SessionManager` parameter to `handleSessionApprove`. The tests rely on input validation (body extraction / JSON field parsing) returning an error before `mgr` is ever dereferenced. The code comments acknowledge this fragility.

Concerns:
1. In Zig, `undefined` for a pointer type is explicitly undefined behavior if the pointer is ever observed (even compared). While the current code path never dereferences it, the compiler is permitted to assume pointer parameters are non-null/valid and optimize accordingly.
2. If anyone reorders `handleSessionApprove` to check `mgr.sessions.get()` before `extractBody`, this becomes a segfault in CI with no compile-time warning.
3. In `ReleaseSafe` builds, Zig may trap on undefined pointer values.

**Fix:** Extract input validation into a separate pure function that does not receive the mgr parameter, and test that function directly:

```zig
fn validateApproveInput(raw_request: []const u8) ?struct { approved: bool } {
    const body = extractBody(raw_request) orelse return null;
    const approved = jsonBoolField(body, "approved") orelse return null;
    return .{ .approved = approved };
}

test "validateApproveInput rejects missing body" {
    try std.testing.expect(validateApproveInput("POST /approve HTTP/1.1\r\nHost: localhost\r\n\r\n") == null);
}
```

## Info

### IN-01: No test coverage for 6 of 8 session CRUD handlers

**File:** `src/gateway.zig:18025-18091`
**Issue:** The test block covers `isSessionAction`, `handleSessionList` (2 tests), `handleSessionAction` (2 tests), and `handleSessionApprove` (2 tests). But there are no tests for:
- `handleSessionGet` -- lock escalation + JSON output
- `handleSessionDelete` -- 409 Conflict path (active_refs > 0 or mutex held), successful delete
- `handleSessionCompact` -- compaction failure fallback to checkpoint
- `handleSessionContext` -- JSON output format
- `handleSessionExport` -- JSON output with history
- `handleSessionHistory` -- JSON output with history

These handlers contain non-trivial concurrent locking logic that is best validated with tests constructing a real `SessionManager`.

**Fix:** Add integration tests with a test `SessionManager` and mock agent. Priority: `handleSessionDelete` (most complex locking), `handleSessionExport`/`handleSessionHistory` (affected by CR-01).

### IN-02: Repetitive error handling pattern across all JSON response builders

**File:** `src/gateway.zig:8952-8965, 9063-9074, 9145-9156, 9202-9211, 9225-9232, 9280-9288`
**Issue:** Every handler building a JSON response repeats the same pattern: create `ArrayListUnmanaged`, get writer, then `w.writeAll(...) catch return .{ .status = "500 ...", .body = "..." }` for every individual write call -- approximately 40+ identical catch-return statements across the 7 handlers. If the error response format changes, every site must be updated.

Not a bug, but a maintainability concern.

**Fix:** Consider a builder helper or `errdefer`-based pattern. Low priority.

---

_Reviewed: 2026-04-13_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: deep_
