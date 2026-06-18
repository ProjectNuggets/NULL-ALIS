---
tags: [prose, prose/docs, memory, design-contract]
authored: 2026-06-18
status: draft contract
---

# Canonical Memory Design Contract

This document is the working contract for how ZAKI's memory surfaces fit
together. It is intentionally broader than the June 2026 repair PR: the goal is
to make every memory-moving part legible, keep canonical memory clean, and make
time-based recall easy for the agent to reason about.

## Triggering Observation

On June 18, 2026, the local app agent was asked about the previous day's
session. It reported that no June 17 session summary was available through
`memory_timeline`, then had to fall back to `transcript_read`.

The transcript for
`agent:zaki-bot:user:1:thread:anon-1780904499550-2uvhlg` did exist and showed a
real June 17 session:

- user greeted ZAKI and asked to test capabilities and distance from a digital
  brain
- user asked for Telegram test messages
- user asked for investor research and a path to make money as soon as possible
- assistant created "ZAKI BOT - Investor & Monetization Sprint Pack"
- user said Joseph Zakher supports the project with UI/UX expertise
- user asked ZAKI to search Joseph and noted he is working on the app
- assistant stored Joseph Zakher information
- user asked to link ZAKI to email
- assistant reported the Composio/Gmail path was broken

Memory tools found at least one June 17 canonical memory,
`extracted_c845e6d992b4b577`, about Joseph Zakher. They did not find the
expected session timeline summary for that date.

The product lesson is specific: the system can have raw transcript and some
canonical facts while still failing the user-facing question "what happened
yesterday?" because the continuity/timeline plane is incomplete or not
discoverable.

## Memory Planes

ZAKI memory is not one bucket. Each plane has a different job.

| Plane | Purpose | Examples | Agent contract |
|---|---|---|---|
| Raw transcript | Exact history and audit | `transcript_read`, session store messages | Last resort for exact wording, not first-line recall |
| Lifecycle checkpoints | Boundary markers and recovery | `session_checkpoint_*`, `context_anchor_current` | Internal continuity scaffolding, not user facts |
| Timeline continuity | What happened in a session | `timeline_summary/*`, `summary_latest/*`, `timeline_index/current` | First-line answer for "yesterday", "recent work", "what did we do" |
| Compaction continuity | What was compressed or dropped | `compaction_summary/*`, `summary_fallback/*`, `compaction_dropped/*` | Discoverable continuity when context-window pressure changed the session |
| Canonical semantic memory | Durable user/project/world facts | `extracted_*`, `durable_fact/*`, graph entities/edges | Brain-visible facts with provenance and correction semantics |
| Working memory | In-session goals, decisions, open loops | `working_memory`, WM promotion | Short-lived until promoted or expired |
| Derived retrieval indexes | Search acceleration | pgvector rows, semantic cache | Rebuildable; never source of truth |
| User-created artifacts | Documents and outputs | artifact/doc rows, shared docs | Must be referenced by memory if later recall is expected |

## Canonicality Rules

1. Postgres is the canonical durable memory source for ZAKI production.
2. pgvector is a derived index. A vector miss is not proof a fact does not
   exist.
3. Markdown files are projection/manual context surfaces, not the canonical
   runtime store.
4. Session summaries are continuity artifacts, not canonical fact sources.
5. Canonical facts must come from explicit memory tools, structured extraction,
   working-memory promotion, or curated correction flows.
6. Summary prose must not write directly to `durable_fact/*`.
7. Transcripts prove what was said, but they do not by themselves make a fact
   canonical.
8. Artifacts created during a session should be linked from timeline memory when
   their existence matters later.
9. Every non-raw memory write should have provenance: source session, source
   message span or artifact, write origin, model/tool path, and confidence.
10. Every session boundary should produce either a continuity artifact or a
    durable failure/audit signal explaining why one was not produced.

## Timestamp Contract

Timestamp ambiguity is a product bug for a memory agent. All memory surfaces
that participate in recall should make time readable both to code and to the
model.

Required fields for this UTC-only slice:

- `created_at_unix`: Unix seconds when the memory row was written
- `created_at_utc`: when the memory row was written
- `date_utc`: UTC calendar date derived from `created_at_utc`
- `session_id`: exact session key
- `boundary_reason`: `summary_seed`, `compaction`, `idle_evict`, `ttl_evict`,
  `ttl_recycle`, `shutdown`, or explicit user action
- `source_key`: source transcript, timeline summary, artifact, or canonical fact
  row
- `quality`: `canonical`, `fallback`, `audit`, or `failed`

Future local-time fields, explicitly out of scope for the June 2026 UTC slice:

- `occurred_at_utc`: when the remembered event happened, if different from
  write time
- `local_date`: date in the user's active timezone, e.g. `2026-06-17`
- `timezone`: IANA zone used for `local_date`, e.g. `Europe/Berlin`
- `session_started_at_utc` and `session_ended_at_utc` for session summaries

Current tool output should display dates in this shape:

```text
date_utc=2026-06-17 created_at_utc=2026-06-17T08:42:10Z session=...
```

The agent should not have to infer "yesterday" from opaque timestamps. Read
tools should accept local date filters and show the resolved date range.

## June 17 Learnings

1. A session can be real and still be invisible to the timeline plane.
2. Canonical extraction can succeed for one fact while session-level continuity
   fails.
3. Artifact creation is not automatically semantic memory. The investor pack
   existed as an output, but the memory layer needs an explicit artifact
   reference if future recall should find it.
4. The agent's correct fallback order is timeline/recall first, transcript
   second. Falling back to transcript is acceptable only after explaining the
   continuity miss.
5. The user-facing answer should say what was found and where it came from:
   timeline summary, canonical memory, artifact, or transcript.

## Action Items

1. Add an end-to-end invariant test: conversation -> idle boundary -> timeline
   summary/index/latest -> queued extraction -> recall answer -> no transcript
   fallback.
2. Add memory-health diagnostics for latest session summary age, pending
   extraction jobs, failed extraction jobs, queue worker readiness, and vector
   lag.
3. Make `memory_timeline` use the same continuity families in global/date
   fallback as it uses for session-specific lookup.
4. Add timeline index coverage for `summary_fallback/*`,
   `compaction_summary/*`, and `compaction_dropped/*`, or document why they are
   intentionally second-line.
5. Return structured extraction outcomes instead of only nullable extraction:
   `ok_written`, `ok_empty`, `llm_failed`, `parse_failed`, `persist_failed`,
   `worker_unavailable`.
6. Ensure queued `session_end` extraction can report persistence failure before
   marking the job done.
7. Add a durable "continuity missing" audit row when a boundary cannot write a
   summary.
8. Add local-date/date-range rendering to memory timeline and recall outputs.
9. Record artifact references in timeline summaries when the assistant creates a
   document or other user-facing artifact.
10. Build a one-time historical cleanup plan for low-signal canonical graph
    entries, with audit and rollback.
11. Define a canonical write-authority ledger for every key family.
12. Add eval coverage for prompts such as "what did we do yesterday?" and
    require timeline/recall before transcript fallback.

## Open Design Questions

1. Should `context_anchor_current` remain a global pointer, or should it become
   `context_anchor/{session_id}` with a separate current pointer?
2. Should timeline index be a single current file, date-partitioned, or backed by
   a Postgres query surface?
3. Should artifact creation create an episodic memory automatically, or only
   when the artifact is user-facing and named?
4. Which timezone wins when the user travels: user profile timezone, channel
   timezone, or runtime locale?
5. Should failed continuity/extraction be visible to the agent by default, or
   only through `memory_doctor`?
