# Agent Lifecycle Spec

Status: frozen continuity contract
Date: 2026-04-08
Scope: nullalis continuity artifacts and normal prompt-loading behavior

## Goal

Freeze the current continuity contract so lifecycle complexity does not expand without explicit evidence.

This document records the behavior that is now considered intentional:
- `summary_latest/<session>` is the canonical continuity object
- `timeline_summary/<session>/<timestamp>` is the append-only historical record
- `session_summary/...` is compatibility-only for audit/debug access and is not part of normal prompt loading
- normal lifecycle writes should not duplicate rich continuity artifacts beyond those roles

## Memory Layers

### Hot Memory

Definition:
- current in-RAM session cache
- recent transcript tail still carried directly in the agent history

Purpose:
- primary continuity source during active conversation
- lowest-latency context source

Contains:
- recent user turns
- recent assistant turns
- current session-local working state

Must not contain:
- long historical transcript once compaction has run
- duplicated warm or cold artifacts

### Warm Memory

Definition:
- small continuity layer used to resume or bridge a session

Purpose:
- preserve the meaning of older context after compaction
- allow session restart without replaying the whole transcript

Contains:
- `summary_latest/<session>`
- bounded related `timeline_summary/<session>/<timestamp>` fallback
- compact anchor/index metadata
- selected nearby semantic hits

Must not contain:
- raw checkpoints as normal prompt content
- duplicated full summary copies
- verbose bookkeeping blobs

### Cold Memory

Definition:
- durable facts and broader semantic recall

Purpose:
- support on-demand retrieval outside the immediate session working set

Contains:
- `durable_fact/...`
- curated long-lived memory
- global semantic recall results

Loaded:
- on demand
- or in a small bounded way when obviously relevant

## Artifact Contract

### `summary_latest/<session>`

Role:
- canonical current continuity object for a session

Should be:
- compact
- high signal
- safe to inject every turn

### `timeline_summary/<session>/<timestamp>`

Role:
- append-only historical continuity record

Should be:
- generated when compaction or session finalization produces a quality summary
- available for bounded fallback and audit

### `durable_fact/...`

Role:
- cross-session, long-lived facts

Should be:
- sparse
- high confidence
- injected only when relevant

### `context_anchor_current`

Role:
- routing and recency pointer only

Should contain only:
- session id
- source summary key
- timestamp
- channel/lane metadata

Should not be treated as normal prompt memory.

### `session_checkpoint_*`

Role:
- audit/debug/recovery artifact

Should contain:
- recent snippets
- reason
- counts

Should not be injected into normal prompts except as explicit fallback/debug behavior.

### `session_summary/...`

Role:
- audit-only compatibility artifact

Reason:
- retained only so historical data remains readable and protected
- not written by the normal lifecycle path
- not injected into normal prompts

## Stage Contract

## `turn_start`

Inputs:
- active session key
- current user message
- hot session cache if still resident
- warm continuity objects for the session
- relevant cold recall if needed

Outputs:
- assembled prompt context for this turn

Allowed writes:
- none required

Allowed prompt injections:
- hot session cache tail
- `summary_latest/<session>`
- bounded related `timeline_summary/...`
- relevant `durable_fact/...`

Forbidden behaviors:
- generating rich lifecycle summaries
- request-path session teardown
- request-path tenant runtime pruning that blocks the turn
- injecting raw checkpoints as standard context

## `turn_end`

Inputs:
- completed assistant reply
- updated hot session history

Outputs:
- persisted transcript
- updated hot cache
- "continuity dirty" marker if needed

Allowed writes:
- transcript/session-store persistence
- lightweight state needed to mark continuity freshness or staleness

Allowed prompt injections:
- none; this is a post-response stage

Forbidden behaviors:
- expensive provider-backed shutdown summary generation
- broad session teardown

## `compaction`

Trigger:
- hot session cache approaches context/token limit

Inputs:
- active session history
- token budget pressure

Outputs:
- reduced hot cache
- recent tail preserved
- quality warm continuity summary

Allowed writes:
- `timeline_summary/<session>/<timestamp>`
- `summary_latest/<session>`
- `durable_fact/...` if extraction quality is high
- compact `context_anchor_current`
- optional `session_checkpoint_*` for audit/debug

Allowed prompt injections on later turns:
- `summary_latest/<session>`
- bounded related summaries/facts

Forbidden behaviors:
- leaving old raw hot context fully resident after successful compaction
- writing low-signal summary placeholders over a better latest summary
- duplicating multiple rich summary artifacts for the same event unless justified

## `idle_prepare`

Trigger:
- session has been inactive for the idle preparation window

Purpose:
- ensure continuity is fresh before session teardown

Inputs:
- current hot session cache
- current warm continuity freshness

Outputs:
- fresh continuity state
- session ready for cheap teardown

Allowed writes:
- missing or stale `summary_latest/<session>`
- matching `timeline_summary/...`
- compact anchor update
- optional checkpoint if summary refresh fails

Forbidden behaviors:
- blocking a future user request with this work
- rebuilding the whole runtime inline on another user's turn

## `shutdown_finalize`

Trigger:
- session eviction
- runtime teardown
- process shutdown

Purpose:
- finalize only what is still missing

Inputs:
- hot session cache
- continuity freshness state

Outputs:
- safe handoff to warm continuity
- freed session/runtime memory

Allowed writes:
- compact anchor update
- optional checkpoint if no fresh summary exists
- final summary only if absolutely necessary and not on a user-critical path

Forbidden behaviors:
- default provider-backed summary generation on the next request path
- heavy teardown work that blocks the next session startup

## Trigger Rules

### When continuity refresh should happen

Continuity refresh should happen:
1. after compaction
2. after a turn if the session became materially different and no fresh summary exists
3. during idle preparation before teardown

Continuity refresh should not happen:
1. on every turn by default
2. as the first time continuity is produced during shutdown
3. on the next unrelated user request

## Frozen Contract

### Normal writes

The current normal lifecycle may write:
- `session_checkpoint_*` as the readable audit/debug checkpoint
- `timeline_summary/<session>/<timestamp>` as append-only history
- `summary_latest/<session>` as the canonical continuity object
- `durable_fact/...` when extracted from a parsed canonical summary
- `context_anchor_current` as compact recency/routing metadata

The current normal lifecycle must not write:
- `session_summary/...`

### Normal prompt loading

The normal prompt path may inject:
- hot session tail
- `summary_latest/<session>`
- bounded related `timeline_summary/...`
- relevant `durable_fact/...`

The normal prompt path must not inject:
- `session_summary/...`
- `session_checkpoint_*`
- rich `context_anchor_current`

### Canonical overwrite rule

`summary_latest/<session>` uses a simple frozen quality gate:
- canonical summaries may replace existing latest state
- fallback summaries may only replace missing or fallback latest state
- legacy latest entries without `quality_tier=` are treated as canonical

This is intentionally a small deterministic rule, not a ranking system.

## Code Truth References

- compaction-triggered continuity refresh:
  - `src/agent/root.zig`
  - `refreshDurableContinuityAfterCompaction`

- summary seed when no latest exists:
  - `src/agent/root.zig`
  - `ensureDurableContinuitySeed`

- lifecycle summary behavior:
  - `src/agent/commands.zig`
  - `shouldUseDeterministicSessionSummary`
  - `persistSessionSemanticSummary`
  - `persistSessionCheckpointDetailed`

- shutdown flush:
  - `src/session.zig`
  - `SessionManager.deinit`
  - `flushSessionsForShutdown`

- runtime pruning on request path:
  - `src/gateway.zig`
  - `pruneTenantRuntimeCache`
  - `getTenantRuntime`

## Intentionally Left Alone

This frozen contract does not change or refine:
- anchor redesign
- richer summary scoring or ranking
- new memory artifact types
- migration or deletion of historical `session_summary/...` data
- broader gateway or idle-preparation redesign

Any future expansion beyond this contract should be evidence-driven and explicit.
