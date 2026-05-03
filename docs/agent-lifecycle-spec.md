---
tags: [prose, prose/docs]
---

# Agent Lifecycle Specification

> Task and session lifecycle contract for the nullalis agent runtime.
> Applies to: all deployment targets (hosted, desktop, extension, embedded).
> Baseline: 2026-04-09 (Phase 00-02). Revised 2026-04-09.
> Supersedes: frozen continuity contract (2026-04-08) — memory lifecycle
> content moved to Section 10.

## 1. Task States

Defined in `src/subagent.zig` `TaskStatus` enum:

| State | Ordinal | Description | Terminal |
|---|---|---|---|
| `queued` | 0 | Task created, waiting for worker thread to mark it running | No |
| `running` | 1 | Worker thread called `markTaskRunning`, agent loop executing | No |
| `completed` | 2 | Agent loop finished successfully | Yes |
| `failed` | 3 | Agent loop errored or process restarted | Yes |

### Planned States (SOTA)

| State | Description | Sprint |
|---|---|---|
| `timed_out` | Task exceeded configured timeout | 2B |
| `cancelled` | Operator cancelled via `/kill` or API | 2B |
| `lost` | Process crashed, recovered from ledger | 2B |

## 2. Task Record Fields

Defined in `src/subagent.zig` `TaskState` struct:

| Field | Type | Description |
|---|---|---|
| `status` | `TaskStatus` | Current lifecycle state |
| `label` | `[]const u8` | Human-readable task label (e.g., "summarize this") |
| `task_summary` | `[]const u8` | Short summary of the task |
| `task_prompt` | `[]const u8` | Full prompt sent to the subagent |
| `session_key` | `?[]const u8` | Requester's session key (for result routing) |
| `runtime_session_key` | `?[]const u8` | Derived runtime session for the subagent (canonical: `agent:zaki-bot:user:42:task:7`, fallback: `subagent:<id>`) |
| `origin_channel` | `?[]const u8` | Channel that originated the task |
| `origin_chat_id` | `?[]const u8` | Chat ID in the originating channel |
| `result` | `?[]const u8` | Task result text (set on completion) |
| `error_msg` | `?[]const u8` | Error message (set on failure) |
| `started_at` | `i64` | Millisecond timestamp when task was created |
| `completed_at` | `?i64` | Millisecond timestamp when task completed/failed |
| `thread` | `?std.Thread` | OS thread handle (null after join) |

### Planned Fields (SOTA)

| Field | Type | Sprint |
|---|---|---|
| `timeout_at` | `?i64` | Timeout deadline (2B) |
| `progress_pct` | `?u8` | Progress percentage 0-100 (2B) |
| `parent_task_id` | `?u64` | For nested subagent chains (5A) |
| `cost_tokens` | `?u64` | Token cost tracking (4B) |

## 3. Delivery Modes

How task results reach the requester:

| Mode | Description | Current |
|---|---|---|
| **Direct (to channel)** | Result routed as `InboundMessage` via event bus to the originating channel and chat | Yes |
| **Session-queued** | Result stored in task state, polled via `/subagents` or `/agents` command | Yes |
| **SSE event** | `subagent_completion` SSE event pushed to connected stream clients | Yes |
| **Replay** | Completed task results replayed on session reconnect | Planned (2B) |

### Direct Delivery Flow

```
SubagentManager.completeTask()
  -> state.status = .completed
  -> state.result = agent_output
  -> event_bus.publish(InboundMessage{
      channel: origin_channel,
      chat_id: origin_chat_id,
      session_key: session_key,
      content: "completed: {label}\n{result}"
    })
```

Source: `src/subagent.zig` `completeTask` method.

### Fallback (No Event Bus)

When the event bus is not wired (e.g., subagent isolation), the result is stored locally in `TaskState.result` and can be retrieved via `getTaskResult(task_id)`.

## 4. Lifecycle Transitions

```
                    +-------------+
                    |   queued    |
                    +------+------+
                           | thread spawned
                    +------v------+
                    |   running   |
                    +------+------+
                     +-----+-----+
              success|           |error
            +--------v---+  +----v------+
            | completed  |  |  failed   |
            +------------+  +-----------+
```

### Triggers

| Transition | Trigger | Code Location |
|---|---|---|
| `queued -> running` | Worker thread calls `markTaskRunning()` | `subagentThreadFn` (line 618) |
| `running -> completed` | Agent loop returns result | `subagentThreadFn` -> `completeTask` |
| `running -> failed` | Agent loop returns error | `subagentThreadFn` -> `completeTask` (error path) |
| `queued -> failed` | Thread spawn fails (OOM, too many threads) | `SubagentManager.spawn()` error path |
| *(recovery)* `running -> failed` | Process restarts, in-flight task found in ledger | `recoverFromLedger` |

### Planned Transitions (SOTA)

| Transition | Trigger | Sprint |
|---|---|---|
| `running -> timed_out` | Wall-clock exceeds `timeout_at` | 2B |
| `running -> cancelled` | Operator sends `/kill <task_id>` | 2B |
| `running -> lost` | Process crash detected on recovery | 2B |

## 5. Concurrency Control

- **Max concurrent**: `SubagentConfig.max_concurrent` (default: **4**)
- **Max iterations per subagent**: `SubagentConfig.max_iterations` (default: **15**)
- **Enforcement**: `spawn()` returns `error.TooManyConcurrentSubagents` when limit reached
- **Thread stack**: 512 KB per subagent thread
- **Running count**: `getRunningCount()` tracks live threads via mutex-protected task map

## 6. Relationship: Tasks and Subagents

A **task** is the unit of work. A **subagent** is the execution context:

- Each task spawns exactly one subagent (1:1).
- The subagent runs a full `ChannelRuntime` agent loop in an isolated session.
- Subagents have a **restricted tool profile**: `spawn`, `delegate`, and `message` tools are excluded to prevent recursive spawning.
- Subagents do **not** have the event bus wired, so they cannot emit proactive messages directly.
- Results are routed back to the caller via the parent's event bus.

Session key derivation (`deriveTaskRuntimeSessionKey`):
- Canonical requester (e.g., `agent:zaki-bot:user:42:main`) -> runtime key: `agent:zaki-bot:user:42:task:<id>`
- Non-canonical requester (no parseable user ID) -> runtime key: `subagent:<id>`

## 7. Relationship: Tasks and Cron Jobs

- Cron jobs use session keys with the `cron:<id>` lane pattern (e.g., `agent:zaki-bot:user:42:cron:morning`).
- Cron-triggered tasks follow the same lifecycle as user-triggered tasks.
- Cron execution is **daemon/runtime-driven** via `CronScheduler.setAgentRunner` — it does **not** go through the gateway `/api/v1/chat/stream` path. The gateway only exposes CRUD endpoints for cron job management.
- Cron results are delivered to channels via the outbound bus.

Source: `src/cron.zig` `CronScheduler`, `src/gateway.zig` cron CRUD at `/api/v1/users/{user_id}/cron`.

## 8. Task Persistence

- **Ledger file**: `subagent_tasks.jsonl` (constant: `TASK_LEDGER_FILE_NAME`)
- **Recovery**: On startup, `recoverFromLedger` scans for in-flight tasks and marks them as failed with reason `"process_restarted_before_completion"`.
- **Format**: One JSON line per task state change (append-only).

## 9. Source References

- Task types: `src/subagent.zig` lines 24-53
- SubagentManager: `src/subagent.zig` line 69+
- Thread spawn: `src/subagent.zig` `spawn()` method
- Completion routing: `src/subagent.zig` `completeTask()` method
- Recovery: `src/subagent.zig` `recoverFromLedger()`
- Commands: `src/agent/commands.zig` `/subagents`, `/agents`, `/kill`, `/tell`
- Characterization tests: `src/subagent.zig` baseline tests

## 10. Memory Lifecycle (Frozen Contract)

> Preserved from the frozen continuity contract (2026-04-08).
> This section documents the memory/continuity lifecycle, which is
> separate from the task lifecycle above.

### Memory Layers

**Hot Memory**: Current in-RAM session cache and recent transcript tail. Primary continuity source during active conversation.

**Warm Memory**: Small continuity layer for session resume/bridging. Contains `summary_latest/<session>`, bounded `timeline_summary` fallback, compact anchor metadata.

**Cold Memory**: Durable facts and broader semantic recall. Contains `durable_fact/...`, loaded on demand.

### Canonical Artifacts

| Artifact | Role |
|---|---|
| `summary_latest/<session>` | Canonical current continuity object |
| `timeline_summary/<session>/<ts>` | Append-only historical continuity record |
| `durable_fact/...` | Cross-session long-lived facts |
| `context_anchor_current` | Routing/recency pointer only |
| `session_checkpoint_*` | Audit/debug/recovery artifact |
| `session_summary/...` | Compatibility-only, not in normal prompt path |

### Stage Contract

- **turn_start**: Assemble prompt from hot cache + warm continuity + relevant cold recall. No writes.
- **turn_end**: Persist transcript, update hot cache, mark continuity freshness. No prompt injection.
- **compaction**: Reduce hot cache, produce quality warm summary. Write `timeline_summary`, `summary_latest`, optionally `durable_fact`.
- **idle_prepare**: Ensure continuity is fresh before session teardown.
- **shutdown_finalize**: Finalize only what is missing, free memory.

### Continuity Refresh Rules

Should happen: after compaction, after materially different turns with stale summary, during idle preparation.

Should NOT happen: on every turn, during shutdown as first-time generation, on unrelated user requests.

### Code References

- Compaction continuity: `src/agent/root.zig` `refreshDurableContinuityAfterCompaction`
- Summary seed: `src/agent/root.zig` `ensureDurableContinuitySeed`
- Lifecycle summary: `src/agent/commands.zig` `persistSessionSemanticSummary`, `persistSessionCheckpointDetailed`
- Shutdown flush: `src/session.zig` `SessionManager.deinit`, `flushSessionsForShutdown`
- Runtime pruning: `src/gateway.zig` `pruneTenantRuntimeCache`, `getTenantRuntime`
