# Phase 3: Canonical Session and Context Runtime - Context

**Gathered:** 2026-04-11 (assumptions mode)
**Status:** Ready for planning

<domain>
## Phase Boundary

Multi-session identity (thread:{uuid} replaces :main), session controls (resume, compact, reset, export), context engine with explicit lifecycle (ingest/assemble/compact/after_turn), context transparency report, and transcript hygiene with provenance tagging.

Requirements: REQ-007, REQ-008, REQ-009, REQ-017

Rules:
- UI/UX activation is mandatory — phase must ship with ZAKI-Prod frontend prompt
- Multi-session by default — all 4 session lines support multiple conversations
- API-first design — gateway endpoints are the primary surface, slash commands delegate
</domain>

<decisions>
## Implementation Decisions

### Session Identity and Lane Routing (REQ-007)
- **D-01:** Extend existing `zaki_session.zig` key formatters and `gateway.zig` lane resolution. Do NOT build a new session identity module. The `userThreadSessionKey`, `tenantLaneFromSessionKey`, and `deriveMemoryProvenance` are already wired end-to-end.
- **D-02:** Remove the `:main` hardcode. Users create threads freely with `agent:zaki-bot:user:{id}:thread:{uuid}` keys. A user's first thread can default to a system-generated UUID, but there is no special "main" session.
- **D-03:** Add thread CRUD API endpoints to the gateway: list threads, create thread, rename thread, delete thread. `SessionManager` needs a `listSessions` method that filters by user ID prefix.
- **D-04:** Add `SessionMetadata` struct: title, created_at, last_active, message_count, lane. Persisted via SessionStore alongside messages.

### Session Controls (REQ-008)
- **D-05:** API-first like OpenClaw. Core logic in new `session_controls.zig` module. Primary surface is `/api/v1/sessions/*` endpoints. Existing slash commands (`/compact`, `/export-session`, `/new`, `/reset`) refactored to delegate to the same shared module.
- **D-06:** Resume = reconnecting to an existing session key that loads history from Postgres (already works via `getOrCreateInternal` + `SessionStore.loadMessages`). The gap is thread discoverability — solved by the thread list API (D-03).
- **D-07:** No checkpoint branching or mid-turn execution state serialization in this phase. Those are future enhancements (potential Phase 7 scope for GAP-010 cross-surface handoff).

### Gateway Session API Endpoints
- **D-08:** `GET /api/v1/sessions` — list user's threads (filtered by session key prefix). Returns SessionMetadata array.
- **D-09:** `POST /api/v1/sessions` — create new thread. Generates UUID, returns session_key and metadata.
- **D-10:** `PATCH /api/v1/sessions/{session_key}` — rename thread (update title).
- **D-11:** `DELETE /api/v1/sessions/{session_key}` — delete thread and its messages.
- **D-12:** `POST /api/v1/sessions/{session_key}/compact` — trigger manual compaction.
- **D-13:** `POST /api/v1/sessions/{session_key}/export` — export thread as markdown.
- **D-14:** `POST /api/v1/sessions/{session_key}/reset` — clear thread history, keep metadata.

### Context Engine Lifecycle (REQ-009)
- **D-15:** Create a thin `context_engine.zig` facade that orchestrates 4 lifecycle phases by calling existing modules. Adds explicit phase boundaries and lifecycle state machine without rewriting internals.
  - `ingest()` — delegates to memory_loader.zig + memory enrichment
  - `assemble()` — delegates to context_builder.zig + prompt.zig system prompt construction
  - `compact()` — delegates to compaction.zig (auto/manual)
  - `afterTurn()` — delegates to persistSessionCheckpoint + lifecycle summarizer
- **D-16:** Context transparency report via existing `context_report.zig` — expose as `/api/v1/sessions/{session_key}/context` endpoint. Shows what the agent knows and why.

### Transcript Hygiene and Provenance (REQ-017)
- **D-17:** Extend `SessionStore.saveMessage` vtable to accept provenance metadata (channel, lane, account_id). New columns in Postgres schema. Clean, queryable, supports cross-surface handoff (GAP-010) later.
- **D-18:** Leverage existing `MemoryProvenance` struct and `refreshSessionOrigin` tracking. On message save, attach the session's current origin metadata to each message row.
- **D-19:** Context transparency report (D-16) uses provenance tags to show message origins (e.g., "from Telegram", "from web app", "from cron job").

### UI Activation
- **D-20:** Phase ships with a ZAKI-Prod frontend prompt that activates: multi-thread sidebar (create/list/switch/rename/delete), session controls (compact/export/reset buttons), context transparency panel, provenance badges on messages.

### Claude's Discretion
- Thread list pagination strategy (offset vs cursor)
- SessionMetadata storage format (extend existing session store vs separate table)
- Context report verbosity levels (summary vs detailed)
- Export format details (markdown structure, what metadata to include)
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Session Management
- `src/session.zig` — SessionManager, Session struct, getOrCreateInternal, processMessage, queue policies
- `src/zaki_session.zig` — session key formatters (userMainSessionKey, userThreadSessionKey, userTaskSessionKey, userCronSessionKey, parseUserIdFromSessionKey)
- `src/gateway.zig` — tenantLaneFromSessionKey (line ~8158), resolveChatStreamSessionKey (line ~8196), handleApiChatStreamSseConnection
- `src/config_types.zig` — SessionConfig, queue policies

### Context and Compaction
- `src/agent/context_builder.zig` — Snapshot, buildSnapshot, LastTurnContext
- `src/agent/compaction.zig` — autoCompactHistory, manualCompactHistory
- `src/agent/context_report.zig` — context transparency report formatting
- `src/agent/prompt.zig` — composable prompt scaffold (Phase 1.5)
- `src/agent/root.zig` — Agent.turn(), persistSessionCheckpoint (line ~2581), history management

### Memory and Provenance
- `src/memory/root.zig` — SessionStore vtable (loadMessages, saveMessage, clearMessages), MemoryProvenance, deriveMemoryProvenance
- `src/memory/lifecycle/hygiene.zig` — conversation row pruning
- `src/zaki_state.zig` — Postgres state manager, schema

### Existing Slash Commands
- `src/agent/commands.zig` — /compact (line ~3391), /export-session (line ~3406), /new, /reset

### Prior Phase Context
- `.planning/phases/02.1-streaming-voice-and-channel-polish/02.1-CONTEXT.md` — SSE streaming decisions, API endpoint patterns
</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **SessionManager** — In-process session hashmap with mutex-guarded access, idle eviction, queue management
- **SessionStore vtable** — Persistence abstraction with loadMessages/saveMessage/clearMessages
- **zaki_session key formatters** — Canonical session key generation with lane encoding
- **tenantLaneFromSessionKey** — Gateway lane routing/validation already handles 4 lane types
- **context_builder.zig** — Snapshot computation with LastTurnContext tracking (trim, compaction, memory)
- **compaction.zig** — Both auto (token-pressure) and manual compaction with LLM summarization
- **context_report.zig** — Detailed transparency report of what the agent knows
- **MemoryProvenance** — session_id, channel, lane fields for provenance tracking
- **refreshSessionOrigin** — Per-session origin metadata tracking (channel, lane, chat_id, account_id)

### Established Patterns
- Gateway API: `/api/v1/...` with JSON responses, X-Internal-Token + X-Zaki-User-Id auth
- Observer vtable chain for event delivery to SSE clients
- Slash commands in commands.zig with consistent dispatch pattern
- Phase 02.1 endpoint pattern: validate auth → resolve user → process → return JSON

### Integration Points
- gateway.zig — add `/api/v1/sessions/*` endpoint handlers following Phase 02.1 health/security pattern
- SessionManager — add listSessions() method, possibly with prefix filtering
- SessionStore vtable — extend saveMessage signature for provenance metadata
- zaki_state.zig — Postgres schema addition for session_metadata and message provenance columns
- agent/root.zig — wire context_engine.zig facade into the turn() lifecycle
</code_context>

<specifics>
## Specific Ideas

- Multi-session like Claude Code — users create conversations freely, no forced "one main session"
- API-first like OpenClaw — gateway endpoints are primary surface, session dashboard with controls
- Context transparency — users can see what the agent knows and why (context_report.zig already exists)
- Provenance badges — each message shows where it came from (web, Telegram, cron, etc.)
- Thread sidebar in ZAKI-Prod frontend — create, list, switch, rename, delete threads

</specifics>

<deferred>
## Deferred Ideas

- Checkpoint branching (OpenClaw-style branch/restore from compaction checkpoints) — potential GAP-010 scope
- Mid-turn execution state serialization for true pause/resume — future phase
- Cross-surface session handoff (GAP-010) — Phase 7, but provenance tags from D-17 lay the groundwork
- Session sharing/collaboration between users — Track B (Agent Network Effect) scope

</deferred>

---

*Phase: 03-canonical-session-and-context-runtime*
*Context gathered: 2026-04-11 via assumptions mode*
