# Phase 3: Canonical Session and Context Runtime - Discussion Log (Assumptions Mode)

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions captured in CONTEXT.md — this log preserves the analysis.

**Date:** 2026-04-11
**Phase:** 03-canonical-session-and-context-runtime
**Mode:** assumptions
**Areas analyzed:** Session Identity, Session Controls, Context Engine, Transcript Provenance

## Assumptions Presented

### Session Identity and Lane Routing
| Assumption | Confidence | Evidence |
|------------|-----------|----------|
| Extend existing zaki_session.zig + gateway lane resolution | Confident | zaki_session.zig key formatters, gateway tenantLaneFromSessionKey, deriveMemoryProvenance |
| :main removal requires new thread CRUD API (no listSessions exists) | Confident | SessionManager has no list method, no /api/v1/sessions endpoint |

### Session Controls
| Assumption | Confidence | Evidence |
|------------|-----------|----------|
| Extract core logic into shared session_controls.zig module | Likely | /compact, /export-session, /new, /reset in commands.zig are chat-only |
| Resume = history reload from Postgres + thread list API | Likely | getOrCreateInternal already loads from SessionStore |

### Context Engine Lifecycle
| Assumption | Confidence | Evidence |
|------------|-----------|----------|
| Thin facade over existing scattered modules | Likely | context_builder.zig, compaction.zig, memory_loader.zig, persistSessionCheckpoint |

### Transcript Provenance
| Assumption | Confidence | Evidence |
|------------|-----------|----------|
| Extend SessionStore.saveMessage with provenance metadata columns | Likely | MemoryProvenance struct exists, refreshSessionOrigin tracks origin per session |

## Corrections Made

### Session Controls
- **Original assumption:** Extract logic into shared module (3 options presented)
- **User correction:** Requested Claude Code + OpenClaw research first
- **Research finding:** Both isolate core logic in standalone modules, exposed via multiple surfaces. Claude Code is slash-command-first, OpenClaw is API-first.
- **User decision:** API-first like OpenClaw — gateway endpoints are primary surface, slash commands delegate

### Resume Scope
- **Original assumption:** Resume = history reload + thread list
- **User decision:** Confirmed — no checkpoint branching or execution state serialization in this phase

### Context Engine
- **Original assumption:** Thin facade vs refactor context_builder
- **User decision:** Thin facade — new context_engine.zig orchestrating existing modules

### Transcript Provenance
- **Original assumption:** Schema extension vs content prefix
- **User decision:** Schema extension — new Postgres columns for provenance metadata

## External Research

- Claude Code session controls: core logic in utils/services (sessionRestore.ts, compact.ts, sessionStorage.ts), exposed via CLI flags + slash commands
- OpenClaw session controls: core logic in gateway services (session-reset-service.ts, session-compaction-checkpoints.ts), exposed via typed API endpoints with lifecycle hooks
- Both share pattern: isolated core logic called by multiple surfaces
