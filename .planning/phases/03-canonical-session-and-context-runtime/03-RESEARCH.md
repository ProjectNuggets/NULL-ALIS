# Phase 3: Canonical Session and Context Runtime — Research

**Researched:** 2026-04-11
**Domain:** Zig session management, gateway API extension, Postgres schema migration, context lifecycle, provenance tagging
**Confidence:** HIGH (all findings verified against live source)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Extend existing `zaki_session.zig` key formatters and `gateway.zig` lane resolution. Do NOT build a new session identity module.
- **D-02:** Remove the `:main` hardcode. Users create threads freely with `agent:zaki-bot:user:{id}:thread:{uuid}` keys. A user's first thread can default to a system-generated UUID, but there is no special "main" session.
- **D-03:** Add thread CRUD API endpoints to the gateway: list threads, create thread, rename thread, delete thread. `SessionManager` needs a `listSessions` method that filters by user ID prefix.
- **D-04:** Add `SessionMetadata` struct: title, created_at, last_active, message_count, lane. Persisted via SessionStore alongside messages.
- **D-05:** API-first like OpenClaw. Core logic in new `session_controls.zig` module. Primary surface is `/api/v1/sessions/*` endpoints. Existing slash commands (`/compact`, `/export-session`, `/new`, `/reset`) refactored to delegate to the same shared module.
- **D-06:** Resume = reconnecting to an existing session key that loads history from Postgres (already works via `getOrCreateInternal` + `SessionStore.loadMessages`). The gap is thread discoverability — solved by the thread list API (D-03).
- **D-07:** No checkpoint branching or mid-turn execution state serialization in this phase.
- **D-08:** `GET /api/v1/sessions` — list user's threads (filtered by session key prefix). Returns SessionMetadata array.
- **D-09:** `POST /api/v1/sessions` — create new thread. Generates UUID, returns session_key and metadata.
- **D-10:** `PATCH /api/v1/sessions/{session_key}` — rename thread (update title).
- **D-11:** `DELETE /api/v1/sessions/{session_key}` — delete thread and its messages.
- **D-12:** `POST /api/v1/sessions/{session_key}/compact` — trigger manual compaction.
- **D-13:** `POST /api/v1/sessions/{session_key}/export` — export thread as markdown.
- **D-14:** `POST /api/v1/sessions/{session_key}/reset` — clear thread history, keep metadata.
- **D-15:** Create a thin `context_engine.zig` facade that orchestrates 4 lifecycle phases by calling existing modules: `ingest()`, `assemble()`, `compact()`, `afterTurn()`.
- **D-16:** Context transparency report via existing `context_report.zig` — expose as `/api/v1/sessions/{session_key}/context` endpoint.
- **D-17:** Extend `SessionStore.saveMessage` vtable to accept provenance metadata (channel, lane, account_id). New columns in Postgres schema.
- **D-18:** Leverage existing `MemoryProvenance` struct and `refreshSessionOrigin` tracking. On message save, attach the session's current origin metadata.
- **D-19:** Context transparency report uses provenance tags to show message origins.
- **D-20:** Phase ships with a ZAKI-Prod frontend prompt that activates: multi-thread sidebar, session controls, context transparency panel, provenance badges.

### Claude's Discretion
- Thread list pagination strategy (offset vs cursor)
- SessionMetadata storage format (extend existing session store vs separate table)
- Context report verbosity levels (summary vs detailed)
- Export format details (markdown structure, what metadata to include)

### Deferred Ideas (OUT OF SCOPE)
- Checkpoint branching (OpenClaw-style branch/restore from compaction checkpoints) — potential GAP-010 scope
- Mid-turn execution state serialization for true pause/resume — future phase
- Cross-surface session handoff (GAP-010) — Phase 7
- Session sharing/collaboration between users — Track B (Agent Network Effect) scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| REQ-007 | Canonical session identity and lane routing module | D-01 through D-04: zaki_session.zig already provides key formatters; gateway.zig has lane routing; gaps are listSessions and :main removal |
| REQ-008 | Session controls: resume, compact, reset, export | D-05 through D-14: existing slash commands + session_controls.zig module + 7 API endpoints |
| REQ-009 | Context engine with explicit lifecycle: ingest, assemble, compact, after_turn | D-15, D-16: thin facade over existing context_builder.zig, memory_loader.zig, compaction.zig, agent/root.zig |
| REQ-017 | Transcript hygiene and provenance tagging | D-17 through D-19: extend SessionStore.saveMessage vtable + Postgres schema migration |
</phase_requirements>

---

## Summary

Phase 3 is primarily a **wiring and surface-exposure** phase — the core session and context mechanics are already implemented. The session identity system (`zaki_session.zig`), lane routing (`tenantLaneFromSessionKey` in `gateway.zig`), history persistence (`SessionStore` vtable backed by `zaki_state.zig`), compaction (`compaction.zig`), and context reporting (`context_report.zig`) all exist and function. What is missing is: (1) thread discoverability (no `listSessions`, no CRUD API), (2) the `:main` hardcode still present in `zaki_session.zig` and `ensureSession`, (3) no `session_controls.zig` module that slash commands can delegate to, (4) the `SessionStore.saveMessage` vtable signature does not accept provenance metadata, and (5) there is no `context_engine.zig` facade exposing the 4-phase lifecycle.

The Postgres schema is largely ready: `{schema}.sessions` has `id`, `session_key`, `kind`, `title`, `created_at`, `updated_at`. The `messages` table has `channel`, `account_id`, `chat_id`, and `source` columns but `saveMessage` in the vtable and `saveSessionMessage` in `zaki_state.zig` currently pass `'app'` as the hardcoded source and do not accept provenance at the call site. The vtable signature change cascades through 3 callsites: the vtable definition in `memory/root.zig`, the bridge in `zaki_state.zig`, and every `saveMessage` call in `agent/root.zig`.

The 7 gateway API endpoints (D-08 through D-14) follow an established pattern: auth via `X-Internal-Token` + `X-Zaki-User-Id`, user resolution via `resolveGatewayPathUserId` or `resolveGatewayRequestUserId`, Postgres operations through `zaki_state.Manager`, and JSON responses. The context endpoint (D-16) requires accessing the live `Session` object from `SessionManager`, which means it needs to be wired into `handleApiRoute` with access to the tenant runtime's `session_mgr`.

**Primary recommendation:** Implement in task order: (1) provenance schema + vtable change, (2) session_controls.zig module, (3) listSessions + SessionMetadata, (4) gateway endpoints, (5) context_engine.zig facade, (6) context transparency endpoint, (7) UI activation.

---

## Standard Stack

### Core (all verified against live source)
| Component | Location | Purpose | Status |
|-----------|----------|---------|--------|
| Session identity | `src/zaki_session.zig` | Key formatters for all 4 lanes | EXISTS — remove `:main` hardcode |
| Lane routing | `src/gateway.zig:8158` | `tenantLaneFromSessionKey` — already handles thread/task/cron/main | EXISTS — drop `.main` arm after :main removal |
| SessionManager | `src/session.zig` | In-process session hashmap with mutex, TTL, queue management | EXISTS — add `listSessions` method |
| SessionStore vtable | `src/memory/root.zig:188` | Persistence abstraction — saveMessage, loadMessages, clearMessages | EXISTS — extend saveMessage signature |
| Postgres implementation | `src/zaki_state.zig` | `saveSessionMessage`, `ensureSession`, schema | EXISTS — add lane/channel/account_id params |
| Compaction | `src/agent/compaction.zig` | autoCompactHistory, manualCompactHistory | EXISTS — delegate from session_controls.zig |
| Context builder | `src/agent/context_builder.zig` | Snapshot, buildSnapshot, buildPromptRefreshPlan | EXISTS — delegate from context_engine.zig |
| Context report | `src/agent/context_report.zig` | formatSummary, formatDetail, formatJson, fromAgent | EXISTS — expose via API endpoint |
| Memory provenance | `src/memory/root.zig:292` | MemoryProvenance struct, deriveMemoryProvenance | EXISTS — use in saveMessage extension |
| Origin tracking | `src/session.zig:272` | refreshSessionOrigin, syncSessionOriginToAgent | EXISTS — data source for provenance on save |
| Commands | `src/agent/commands.zig:3305` | handleSlashCommand dispatch, clearSessionState, handleExportSessionCommand | EXISTS — refactor to delegate to session_controls.zig |

### New Files to Create
| File | Purpose |
|------|---------|
| `src/agent/session_controls.zig` | Shared implementation: compact, export, reset, delete — called by both slash commands and API endpoints |
| `src/agent/context_engine.zig` | Thin facade: ingest/assemble/compact/afterTurn phases |

---

## Architecture Patterns

### Established Gateway API Pattern (from Phase 02.1)
[VERIFIED: src/gateway.zig — confirmed against channel health and security review endpoints]

All `/api/v1/*` endpoints follow this flow:
1. Method validation (405 if wrong)
2. Auth: internal token or `X-Zaki-User-Id` header
3. User resolution via `resolveGatewayPathUserId` / `resolveGatewayRequestUserId`
4. Broker role: proxy to cell, skip local logic
5. `resolveUserContext` → `ensureUserProvisioned` → `scaffoldUserWorkspace`
6. Write operations: acquire tenant ownership lock via `maybeAcquireTenantOwnershipLock`
7. Delegate to `state.zaki_state.?` for Postgres operations
8. Return `{ .body = json }` or `{ .status = "...", .body = "{\"error\":\"...\"}" }`

For session endpoints that need access to the live `SessionManager`, the pattern must extend: the tenant runtime (accessible via `getTenantRuntime`) carries `session_mgr`. The `/api/v1/sessions/{key}/compact` endpoint needs to call `session.agent.manualCompactHistory()`, which requires acquiring the session mutex — same pattern as `processMessage`.

### URL Routing Pattern for Session Subpaths
The existing pattern `parseUserPath` extracts `/api/v1/users/{user_id}/{subpath}`. The new session endpoints are at `/api/v1/sessions` (no user in the path). Session ownership is verified by checking `sessionKeyOwnedByUser(session_key, user_id)` — this function already exists at `gateway.zig:8148`.

For the session control endpoints (compact/export/reset), the session key appears in the URL path: `/api/v1/sessions/{encoded_session_key}/compact`. Since session keys contain colons (e.g., `agent:zaki-bot:user:42:thread:uuid`), the planner must handle URL-encoding. Using a base64url or percent-encoded session key in the path is the standard approach; percent-encoding `%3A` for colons is the simplest.

### SessionMetadata Storage
[VERIFIED: src/zaki_state.zig:686 — sessions table schema]

The existing `sessions` table already has: `id TEXT PRIMARY KEY`, `session_key TEXT UNIQUE`, `kind TEXT`, `title TEXT`, `created_at TIMESTAMPTZ`, `updated_at TIMESTAMPTZ`. Missing for D-04: `last_active` and `message_count`. Two options for Claude's discretion:
- **Option A (recommended):** Add `last_active TIMESTAMPTZ` column to `sessions` table via schema migration. `message_count` is a computed query `(SELECT COUNT(*) FROM messages WHERE session_id = s.id)` in the list query — no column needed.
- **Option B:** Separate `session_metadata` table. More flexible but unnecessary given the small number of new fields.

Recommendation: Option A. The sessions table already has the right shape; `ALTER TABLE ADD COLUMN IF NOT EXISTS` is safe and idiomatic for this schema migration pattern.

### SessionStore VTable Extension (D-17)
[VERIFIED: src/memory/root.zig:192 — VTable definition]

Current vtable:
```zig
saveMessage: *const fn (ptr: *anyopaque, session_id: []const u8, role: []const u8, content: []const u8) anyerror!void,
```

New vtable (add optional provenance fields):
```zig
saveMessage: *const fn (
    ptr: *anyopaque,
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    channel: ?[]const u8,
    lane: ?[]const u8,
    account_id: ?[]const u8,
) anyerror!void,
```

This cascades to:
1. `memory/root.zig` — vtable definition and `SessionStore.saveMessage` wrapper
2. `zaki_state.zig` — `saveMessage` bridge function, `saveSessionMessage` implementation
3. `agent/root.zig` — all `session_store.saveMessage(...)` call sites (need to pass `self.origin_channel`, `self.origin_lane`, `self.origin_account_id`)
4. Any other vtable implementations (SQLite session store, test mocks)

[VERIFIED: grep for `saveMessage` call sites in src/agent/root.zig required during implementation]

### context_engine.zig Facade
[VERIFIED: src/agent/root.zig:1368 — turn() implementation; existing phases confirmed]

The `Agent.turn()` method already performs all 4 lifecycle phases implicitly. The `context_engine.zig` facade adds explicit named boundaries without changing the execution path:

```zig
// src/agent/context_engine.zig
pub fn ingest(agent: *Agent, user_message: []const u8) !void
// → delegates to memory_loader.zig enrichment (already called inside turn())

pub fn assemble(agent: *Agent) ![]ChatMessage
// → delegates to context_builder.buildSnapshot + prompt.buildSystemPrompt

pub fn compact(agent: *Agent) !bool
// → delegates to agent.manualCompactHistory() / autoCompactHistory

pub fn afterTurn(agent: *Agent, reason: []const u8) void
// → delegates to commands.persistSessionCheckpoint
```

The facade is a compile-time wrapper that names the phases for observability and future hookability. It does NOT replace the existing turn() flow in this phase — it layers alongside it.

### Recommended Project Structure (new files only)
```
src/agent/
├── session_controls.zig    # compact/export/reset/delete shared logic (NEW)
├── context_engine.zig      # 4-phase lifecycle facade (NEW)
```

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Session key validation | Custom regex parser | `sessionKeyOwnedByUser` + `tenantLaneFromSessionKey` (gateway.zig:8148,8158) | Already handles all 4 lanes, user ownership scoping |
| Provenance derivation | Custom channel/lane extraction | `deriveMemoryProvenance` (memory/root.zig:814) | Handles app/telegram/slack/task/cron lane detection from session key |
| UUID generation | Custom UUID v4 | `std.crypto.random.bytes` + hex encoding (pattern from `randomHexId` in zaki_state.zig) | Already used for message IDs |
| Compaction logic | Any new summarizer | `manualCompactHistory` / `autoCompactHistory` in compaction.zig | LLM summarization, keep-recent policy, workspace context already wired |
| Context snapshot | Custom introspection | `context_builder.buildSnapshot` → `context_report.fromAgent` | Already tracks all 30+ fields including memory selection, cache state, trim events |
| Export serialization | Custom markdown builder | `handleExportSessionCommand` in commands.zig:1928 | Already handles path resolution, file writing, markdown formatting |
| Auth/user resolution | New auth layer | `resolveGatewayRequestUserId` + `resolveGatewayPathUserId` pattern | Both functions handle broker proxy, user cell pinning, header validation |
| Postgres schema migration | Manual SQL execution | `ManagerImpl.migrations` slice pattern in zaki_state.zig (additive ALTER TABLE) | Schema runs on startup; add to migrations array |

---

## Runtime State Inventory

Step 2.5: SKIPPED — this is a greenfield feature addition (new endpoints, new module), not a rename/refactor phase. No stored data with old identifiers to migrate. The `:main` hardcode removal is a code edit only; existing `main` session rows in Postgres can remain — `ensureSession` uses `ON CONFLICT DO NOTHING`, so old rows are harmless and backward-compatible.

---

## Common Pitfalls

### Pitfall 1: VTable Signature Change Breaks Test Mocks
**What goes wrong:** The `SessionStore.VTable.saveMessage` signature change (adding 3 new optional params) will break every test mock that implements the vtable inline. Session tests in `session.zig` and gateway tests use mock implementations.
**Why it happens:** Zig vtable implementations require exact function signature matching.
**How to avoid:** Search for all `saveMessage:` vtable field assignments across the codebase before implementing. Update all mocks simultaneously. Pattern: `fn saveMessage(ptr: *anyopaque, ...)` — grep for `fn saveMessage` to find all implementations.
**Warning signs:** Compile error "function signature mismatch" at any vtable assignment site.

### Pitfall 2: Session Key URL-Encoding in Path Segments
**What goes wrong:** Session keys like `agent:zaki-bot:user:42:thread:550e8400-e29b-41d4-a716-446655440000` contain colons and hyphens, which are safe in URL paths per RFC 3986 but may confuse naive path parsers.
**Why it happens:** Gateway path parsing uses `std.mem.indexOf` / `std.mem.startsWith` — colon in path segment is legal but the parser must not split on it.
**How to avoid:** Route the sessions CRUD endpoints before `parseUserPath` in `handleApiRoute` (it currently checks `/api/v1/users/` prefix). Add session path detection (`std.mem.startsWith(u8, base_path, "/api/v1/sessions")`) before the user path block.
**Warning signs:** 404 responses on valid session endpoints, or session key truncation.

### Pitfall 3: Compact/Export/Reset Require Active Session Mutex
**What goes wrong:** `compact`, `export`, and `reset` session control API endpoints need to access `session.agent` — which requires holding `session.mutex`. Calling without the lock causes data races.
**Why it happens:** `Agent.turn()` holds `session.mutex` for its entire duration. The controls endpoints should use the same `acquireSessionForTurn` + `releaseSessionRef` flow as `processMessage`.
**How to avoid:** Use `session_mgr.getOrCreate(session_key)` (non-blocking read), then `session.mutex.lock()` + `defer session.mutex.unlock()` before touching `session.agent`. Do NOT use `processMessage` for control operations — they are not turns.
**Warning signs:** Deadlock under concurrent load, or race condition in compaction state.

### Pitfall 4: `ensureSession` Kind Classification After :main Removal
**What goes wrong:** `ensureSession` currently classifies sessions as `kind = 'main'` if the key ends with `:main`, and `kind = 'system'` otherwise. After removing `:main`, all thread sessions will get `kind = 'system'` unless the classifier is updated.
**Why it happens:** The kind derivation is hardcoded string matching: `if (std.mem.endsWith(u8, session_id, ":main")) "main" else "system"`.
**How to avoid:** Update `ensureSession` to parse the lane type: `:thread:` → `"thread"`, `:task:` → `"task"`, `:cron:` → `"cron"`, fallback → `"system"`. Also update the `provisionUser` call at line ~925 that hardcodes `kind = 'main'`.
**Warning signs:** All sessions showing as `kind = 'system'` in the sessions list API.

### Pitfall 5: `listSessions` In-Memory vs Postgres Split
**What goes wrong:** The `SessionManager` in-process map only contains currently-loaded sessions. A user's historical sessions (evicted from memory, only in Postgres) won't appear in a `listSessions` that only iterates the hashmap.
**Why it happens:** Sessions are evicted from `SessionManager.sessions` when idle. They remain in `{schema}.sessions` in Postgres but are invisible to the in-memory map.
**How to avoid:** `listSessions` must query Postgres (`{schema}.sessions WHERE user_id = $1 AND session_key LIKE 'agent:zaki-bot:user:{id}:thread:%'`) — not the in-memory map. The in-memory `last_active` can be used to enrich Postgres rows for live sessions only.
**Warning signs:** Session list returns only the current active session, missing historical ones.

### Pitfall 6: gateway.zig Size and Merge Risk
**What goes wrong:** `gateway.zig` is ~16K lines. Adding 7+ new endpoint handlers inline risks merge conflicts with any parallel phase work.
**Why it happens:** All API routing is in one file (known risk from STATE.md).
**How to avoid:** Add all session API handlers in a single contiguous block, clearly delimited with comments matching the Phase 02.1 pattern (`// ── Session endpoints ──`). Test each endpoint independently before proceeding to the next.
**Warning signs:** Merge conflicts during git rebase, duplicate endpoint blocks.

---

## Code Examples

Verified patterns from live source:

### Existing Gateway Endpoint Pattern (channel health)
[VERIFIED: src/gateway.zig:9202]
```zig
// ── Channel Health endpoint ───────────────────────────────
if (std.mem.eql(u8, base_path, "/api/v1/channels/health")) {
    if (!std.mem.eql(u8, method, "GET")) {
        return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
    }
    // ... logic ...
    const json = formatJson(req_allocator, ...) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"format_failed\"}" };
    };
    return .{ .body = json };
}
```

### SessionStore VTable (current, to be extended)
[VERIFIED: src/memory/root.zig:192]
```zig
pub const VTable = struct {
    saveMessage: *const fn (ptr: *anyopaque, session_id: []const u8, role: []const u8, content: []const u8) anyerror!void,
    loadMessages: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror![]MessageEntry,
    clearMessages: *const fn (ptr: *anyopaque, session_id: []const u8) anyerror!void,
    // ...
};
```

### ensureSession (current, kind classification to be fixed)
[VERIFIED: src/zaki_state.zig:2285]
```zig
fn ensureSession(self: *Self, user_id: i64, session_id: []const u8) !void {
    // ...
    const kind = if (std.mem.endsWith(u8, session_id, ":main")) "main" else "system";
    const title = if (std.mem.eql(u8, kind, "main")) "Main" else "Session";
    // INSERT ... ON CONFLICT (session_key) DO NOTHING
}
```

### Manual Compact Slash Command (to be refactored to delegate to session_controls.zig)
[VERIFIED: src/agent/commands.zig:3391]
```zig
if (isSlashName(cmd, "compact")) {
    if (try self.manualCompactHistory()) {
        self.last_turn_compacted = true;
        self.last_turn_context.durable_continuity_refreshed = persistSessionCheckpointDetailed(self, "compaction:manual");
        if (self.last_turn_context.durable_continuity_refreshed) {
            return try self.allocator.dupe(u8, "Context compacted and continuity refreshed.");
        }
        return try self.allocator.dupe(u8, "Context compacted.");
    }
    return try self.allocator.dupe(u8, "Nothing to compact.");
}
```

### MemoryProvenance Struct (existing, use as-is)
[VERIFIED: src/memory/root.zig:292]
```zig
pub const MemoryProvenance = struct {
    session_id: ?[]const u8 = null,
    channel: []const u8 = "unknown",
    lane: []const u8 = "unknown",
};

pub fn deriveMemoryProvenance(session_id_opt: ?[]const u8, key: []const u8) MemoryProvenance
// → "agent:zaki-bot:user:42:thread:x" → channel="app", lane="thread"
// → "telegram:chatId"                 → channel="telegram", lane=...
```

### Postgres Sessions Table (existing schema)
[VERIFIED: src/zaki_state.zig:686]
```sql
CREATE TABLE IF NOT EXISTS {schema}.sessions (
    id TEXT PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    session_key TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL,
    title TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
```
Migration to add: `last_active TIMESTAMPTZ` column.

### Messages Table (existing — provenance columns already present)
[VERIFIED: src/zaki_state.zig:696]
```sql
CREATE TABLE IF NOT EXISTS {schema}.messages (
    id TEXT PRIMARY KEY DEFAULT encode(gen_random_bytes(16), 'hex'),
    session_id TEXT NOT NULL REFERENCES {schema}.sessions(id) ON DELETE CASCADE,
    user_id BIGINT,
    role TEXT NOT NULL,
    channel TEXT,        -- <-- already exists
    account_id TEXT,     -- <-- already exists
    chat_id TEXT,        -- <-- already exists
    source TEXT NOT NULL DEFAULT 'app',
    content TEXT NOT NULL,
    -- ...
)
```
The Postgres schema already has all needed provenance columns. The gap is that `saveMessage` always passes `'app'` as source and does not pass channel/account_id to the INSERT. No new schema migration needed for messages — only `saveMessage` call sites need updating and the sessions `last_active` column needs adding.

### refreshSessionOrigin (existing — data source for provenance on save)
[VERIFIED: src/session.zig:272]
```zig
fn refreshSessionOrigin(self: *SessionManager, session: *Session, message_turn_context: ?tools_mod.MessageTurnContext) !void {
    // Populates: session.origin_lane, session.origin_channel, session.origin_chat_id, session.origin_account_id
    // These are then synced to agent via syncSessionOriginToAgent
    // agent.origin_channel / origin_lane / origin_account_id are the values to pass on saveMessage
}
```

---

## State of the Art

| Old Pattern | Current Pattern | Notes |
|------------|----------------|-------|
| `:main` singleton session per user | `thread:{uuid}` multi-session per user (D-02) | zaki_session.zig has `userMainSessionKey` — keep as deprecated fallback, add new path |
| saveMessage with 3 params | saveMessage with 6 params (+ channel, lane, account_id) | Vtable break — update all impls |
| Context lifecycle implicit in turn() | context_engine.zig explicit facade | Additive only — turn() internals unchanged |
| Slash-command-only session controls | API-first + slash delegates | session_controls.zig is the canonical impl |

**Deprecated/outdated after this phase:**
- `userMainSessionKey` in `zaki_session.zig` — keep for backward compatibility but don't generate new main keys from gateway
- `kind = 'main'` sessions in Postgres — harmless but no longer generated; existing rows remain valid

---

## Environment Availability

Step 2.6: Core dependencies verified.

| Dependency | Required By | Available | Notes |
|------------|------------|-----------|-------|
| Postgres (libpq) | All session API endpoints, schema migration | Conditional (`enable_postgres` build flag) | `zaki_state.zig` already guards with `build_options.enable_postgres`. Session CRUD endpoints must check `state.zaki_state != null` |
| `std.crypto.random` | UUID generation in POST /api/v1/sessions | Always available (Zig stdlib) | Use for `thread:{uuid}` generation |
| Session mutex | Compact/export/reset control endpoints | Always available (in-process) | Must acquire `session.mutex` for all session agent operations |

**Missing dependencies with no fallback:**
- None that would block execution.

**Postgres-disabled fallback note:** When `enable_postgres = false`, session CRUD endpoints should return `{"error":"session_store_unavailable"}` with 503. The existing `state.zaki_state` null check pattern covers this.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Zig built-in test runner |
| Config file | `build.zig` (test step) |
| Quick run command | `zig build test --summary all 2>&1 | tail -20` |
| Full suite command | `zig build test --summary all` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| REQ-007 | listSessions returns only user-owned thread sessions | unit | `zig build test --summary all 2>&1 | grep session` | No — Wave 0 |
| REQ-007 | :main hardcode removed, new thread key generation works | unit | tests in zaki_session.zig | Partial (existing key tests pass; new UUID generation test needed) |
| REQ-007 | tenantLaneFromSessionKey handles thread without :main | unit | existing test in gateway.zig | No — Wave 0 |
| REQ-008 | session_controls compact delegates same logic as /compact slash | unit | test in session_controls.zig | No — Wave 0 |
| REQ-008 | session_controls reset clears history, keeps metadata | unit | test in session_controls.zig | No — Wave 0 |
| REQ-009 | context_engine.zig ingest/assemble/compact/afterTurn phases call correct delegates | unit | test in context_engine.zig | No — Wave 0 |
| REQ-017 | saveMessage passes provenance to Postgres insert | unit | test in zaki_state.zig | No — Wave 0 |
| REQ-017 | deriveMemoryProvenance returns correct channel/lane for all 4 session lines | unit | existing tests in memory/root.zig | YES (tests at line 2907) |

### Sampling Rate
- **Per task commit:** `zig build test --summary all 2>&1 | tail -20`
- **Per wave merge:** `zig build test --summary all`
- **Phase gate:** Full suite green (currently 5298/5329 passing) before `/gsd-verify-work`

### Wave 0 Gaps
- [ ] Tests for `listSessions` method in `src/session.zig`
- [ ] Tests for `session_controls.zig` (compact/reset/export functions)
- [ ] Tests for `context_engine.zig` (4 phase lifecycle)
- [ ] Tests for updated `saveMessage` vtable signature (provenance params)
- [ ] Tests for `/api/v1/sessions` endpoint handlers in gateway (following existing gateway test pattern)

*(Existing test infrastructure covers all other claims — no framework install needed)*

---

## Security Domain

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | Yes | Existing `X-Internal-Token` + `X-Zaki-User-Id` headers — reuse exact same pattern |
| V3 Session Management | Yes | Session ownership verified via `sessionKeyOwnedByUser` before any CRUD; user cannot access another user's sessions |
| V4 Access Control | Yes | `resolveGatewayRequestUserId` enforces user cell isolation; broker proxies to correct cell |
| V5 Input Validation | Yes | Session key validation via `tenantLaneFromSessionKey` (rejects invalid keys); title field capped/sanitized before DB write |
| V6 Cryptography | No | No new crypto; UUID generation uses `std.crypto.random` (existing pattern) |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Session key forgery (user accesses another user's session) | Elevation of Privilege | `sessionKeyOwnedByUser(session_key, user_id)` check before any operation — already exists in gateway.zig:8148 |
| Excessive session creation (DoS) | Denial of Service | Rate limit consideration: no current per-user session count limit; `POST /api/v1/sessions` should check existing thread count (planner's discretion for limit) |
| Title injection (XSS via session title) | Tampering | Title is a plain text field rendered in frontend; sanitize on read in frontend; backend stores raw text only |
| Export path traversal | Information Disclosure | `handleExportSessionCommand` already handles absolute vs relative path — delegate to this; verify output path stays within workspace_dir |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | saveMessage is called exactly at `agent/root.zig` (not other files besides mock tests) | Code Examples, VTable Extension | Medium: if there are other callers, the vtable change will miss them — needs grep verification during implementation |
| A2 | The sessions table `kind` column currently accepts values beyond 'main' and 'system' — no DB constraint | Pitfall 4 | Low: schema uses `TEXT NOT NULL` with no CHECK constraint, so any string is valid |
| A3 | Session list endpoint can safely read from Postgres without holding the in-process session mutex | Pitfall 5 | Low: reading from Postgres is independent of in-process session state; eventual consistency between Postgres row and in-memory last_active is acceptable |

**If these fail:** A1 requires a full grep before implementing vtable change. A2 confirmed by schema inspection. A3 is design intent.

---

## Open Questions

1. **Thread list pagination (Claude's discretion)**
   - What we know: No existing pagination pattern in the session API. Postgres sessions table is unbounded per user.
   - What's unclear: Expected thread count per user (likely small — 10s not 1000s for app sessions). Cursor vs offset.
   - Recommendation: Offset pagination with `limit` and `offset` query params (simpler, consistent with task list). Default `limit=50`. Cursor pagination adds complexity without clear benefit at this scale.

2. **Context report verbosity levels (Claude's discretion)**
   - What we know: `context_report.zig` already has `formatSummary`, `formatDetail`, and `formatJson`. The `/context` endpoint can accept a `?format=summary|detail|json` query param.
   - Recommendation: Default to `summary`, support `?format=json` for machine consumption by frontend. The `detail` format is too verbose for API consumers.

3. **Export format (Claude's discretion)**
   - What we know: `handleExportSessionCommand` in commands.zig:1928 writes to a file path. For the API endpoint, the response body should BE the markdown (not a file path).
   - Recommendation: API endpoint returns markdown in response body with `Content-Type: text/markdown`. The slash command retains its file-write behavior for CLI users.

4. **Does `tenantLaneFromSessionKey` need updating after :main removal?**
   - What we know: The function currently returns `.main` for keys ending in `:main`. After D-02, no new `:main` keys will be created. But existing sessions may still have them.
   - Recommendation: Keep `.main` arm in `tenantLaneFromSessionKey` for backward compatibility. The session list endpoint should exclude `:main` sessions or label them as legacy.

---

## Sources

### Primary (HIGH confidence — verified against live source)
- `src/zaki_session.zig` — all key formatters, parseUserIdFromSessionKey
- `src/session.zig` — SessionManager (lines 84–710), Session struct, getOrCreateInternal, refreshSessionOrigin
- `src/memory/root.zig` — SessionStore vtable (lines 186–229), MemoryProvenance (line 292), deriveMemoryProvenance (line 814)
- `src/agent/context_builder.zig` — Snapshot struct (lines 13–45), LastTurnContext, MemorySelection
- `src/agent/context_report.zig` — fromAgent, formatSummary, formatDetail, formatJson
- `src/agent/compaction.zig` — CompactionConfig, manualCompactHistory function signatures
- `src/agent/commands.zig` — handleSlashCommand (line 3305), clearSessionState (line 1262), handleExportSessionCommand (line 1928), handleContextCommand (line 1914), compact dispatch (line 3391)
- `src/agent/root.zig` — turn() (line 1368), persistSessionCheckpoint (line 2706)
- `src/gateway.zig` — tenantLaneFromSessionKey (line 8158), sessionKeyOwnedByUser (line 8148), resolveChatStreamSessionKey (line 8196), parseUserPath (line 8823), channel health endpoint pattern (line 9202)
- `src/zaki_state.zig` — sessions table schema (line 686), messages table schema (line 696), ensureSession (line 2285), saveSessionMessage (line 1283), migrations pattern
- `.planning/phases/03-canonical-session-and-context-runtime/03-CONTEXT.md` — all locked decisions

### Secondary (MEDIUM confidence)
- `.planning/STATE.md` — architecture locks, test count baseline (5298/5329)
- `.planning/REQUIREMENTS.md` — REQ-007, REQ-008, REQ-009, REQ-017 descriptions
- `.planning/config.json` — nyquist_validation not set (absent = enabled), test command

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all modules verified by direct file read
- Architecture: HIGH — gateway patterns confirmed against 3 existing endpoint implementations
- Pitfalls: HIGH — each pitfall rooted in a specific code finding (hardcoded string, vtable signature, missing Postgres query)
- Schema gaps: HIGH — confirmed by reading full `sessions` and `messages` DDL

**Research date:** 2026-04-11
**Valid until:** 2026-05-11 (stable Zig codebase; fast-moving only at gateway.zig merge points)
