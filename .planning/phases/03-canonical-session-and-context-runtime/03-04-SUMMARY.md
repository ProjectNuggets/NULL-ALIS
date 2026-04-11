---
phase: 03-canonical-session-and-context-runtime
plan: "04"
subsystem: agent/transcript
tags: [transcript, hygiene, provenance, export]
dependency_graph:
  requires: [03-02, 03-03]
  provides: [transcript-hygiene, provenance-tagging, clean-export]
  affects: [src/agent/commands.zig, src/agent/root.zig]
tech_stack:
  added: []
  patterns: [hygiene-pipeline, provenance-annotation, html-comment-metadata]
key_files:
  created:
    - src/agent/transcript.zig
  modified:
    - src/agent/root.zig
    - src/agent/commands.zig
decisions:
  - "Used ArrayListUnmanaged(u8) with buf.writer(allocator) to match codebase convention (not ArrayList)"
  - "Passed null for provenance in export command since existing history entries have no provenance yet"
  - "formatExportEntry uses catch {} for error swallowing in export loop to match existing commands.zig error handling style"
metrics:
  duration: "~18 minutes"
  completed: "2026-04-11T17:40:58Z"
  tasks_completed: 2
  files_changed: 3
---

# Phase 03 Plan 04: Transcript Hygiene and Provenance Summary

One-liner: Transcript hygiene pipeline stripping [Memory context] and [Queue notice] internal markers from exports, with optional ProvenanceTag metadata for source attribution.

## What Was Built

Created `src/agent/transcript.zig` implementing REQ-017 transcript hygiene and provenance tagging. The module provides:

- **ProvenanceTag struct** — lightweight metadata (source_channel, timestamp_ms, turn_index, tool_name, is_synthetic) that attaches to history entries without changing the entry format. Optional by design — existing history entries without provenance still work.
- **stripInternalMarkers** — removes `[Memory context]\n...\n\n` prefixes injected by memory enrichment, and `[Queue notice:...]` line prefixes from queue overflow handling. Returns a slice into the original string (no allocation).
- **isInternalMessage** — detects 5 queue drop artifact patterns that should be omitted entirely from exports.
- **sanitizeForExport** — full pipeline: detect internal-only messages (return ""), then strip markers from enriched messages.
- **formatExportEntry** — writes clean markdown `## role\n\ncontent\n\n` with optional provenance as an HTML comment (invisible in rendered markdown). Skips internal-only messages entirely.

`src/agent/root.zig` re-exports the module as `pub const transcript` and includes it in the `test {}` block so transcript tests run as part of the main test suite.

`src/agent/commands.zig` now uses `transcript.formatExportEntry` in `handleExportSessionCommand` instead of raw `w.print`, giving clean exports without internal markers.

## Tasks

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Create transcript.zig with ProvenanceTag and hygiene functions | 2b4fd83 | src/agent/transcript.zig (created) |
| 2 | Wire transcript module into agent and update export command | cabc11a | src/agent/root.zig, src/agent/commands.zig |

## Verification

```
zig build test --summary all
Build Summary: 8/8 steps succeeded; 5351/5382 tests passed; 31 skipped
```

- `grep -c 'test "' src/agent/transcript.zig` → 16 (>= 10 required)
- `grep 'pub const transcript' src/agent/root.zig` → found
- `grep 'formatExportEntry' src/agent/commands.zig` → found
- Test count increased from 5335 → 5351 (16 new transcript tests)

## Decisions Made

1. **ArrayListUnmanaged pattern** — used `std.ArrayListUnmanaged(u8)` with `buf.writer(allocator)` in tests to match the codebase convention (prompt.zig, dispatcher.zig). The plan's code snippet showed `std.ArrayList(u8)` which is the managed variant not used elsewhere in the agent module.
2. **null provenance for existing entries** — existing history entries have no provenance tags, so `null` is passed in the export command. The `formatExportEntry` function gracefully handles null provenance (no comment written). Future work can add provenance when entries are created.
3. **catch {} in export loop** — matches the existing commands.zig style where errors in the export loop are swallowed to avoid partial export failure on a single bad entry.

## Deviations from Plan

None — plan executed exactly as written.

## Threat Mitigations Applied

| Threat ID | Status |
|-----------|--------|
| T-03-11 | Mitigated — sanitizeForExport strips [Memory context] enrichment data (may contain memories from other sessions) before export |
| T-03-12 | Mitigated — provenance tags include only operational metadata (channel, timestamp, turn_index), not PII beyond session key |
| T-03-13 | Accepted — path handling unchanged, delegated to existing handleExportSessionCommand path resolution |

## Known Stubs

None — all functions are fully implemented and wired.

## Threat Flags

None — no new network endpoints, auth paths, or trust boundary changes introduced.

## Self-Check: PASSED

- [x] `src/agent/transcript.zig` exists and contains ProvenanceTag, stripInternalMarkers, isInternalMessage, sanitizeForExport, formatExportEntry
- [x] `src/agent/root.zig` contains `pub const transcript = @import("transcript.zig")`
- [x] `src/agent/commands.zig` references `transcript.formatExportEntry`
- [x] Commits 2b4fd83 and cabc11a exist in git log
- [x] `zig build test --summary all` passes with 0 failures
