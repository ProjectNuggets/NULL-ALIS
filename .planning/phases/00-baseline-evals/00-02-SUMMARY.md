---
phase: "00-baseline-evals"
plan: "00-02"
status: "complete"
commit: "60471d9"
runtime_changes: false
---

# Plan 00-02 Summary: Online Agent Contract Documentation

## Result: PASS

All 3 tasks completed. Documentation-only changes — no runtime code modified. All 5045 tests still pass.

## Tasks Completed

### Task 1: Document target run-event vocabulary
- Created `docs/online-agent-contract.md`
- Lists all 9 current SSE events with payload schemas, when emitted, and terminal flags
- Defines 7 planned target events (tool_start, tool_result, approval_required, approval_response, task_update, context_snapshot, cost_update) with sprint assignments
- Documents event ordering invariants (done is always terminal, reply_start before tokens, error always followed by done)
- Defines replay contract (buffered vs live, seq ordering, terminal detection)
- Defines backward compatibility rules (additive only, unknown events ignored, type field dispatch)
- Documents all 8 current error codes with HTTP status mapping

### Task 2: Document target task vocabulary
- Rewrote `docs/agent-lifecycle-spec.md` with task lifecycle focus
- Documents 4 current TaskStatus states (queued, running, completed, failed) with ordinals
- Documents 13 TaskState fields with types
- Defines 3 planned states (timed_out, cancelled, lost) and 4 planned fields
- Documents 4 delivery modes (direct, session-queued, SSE event, replay)
- Documents lifecycle transition diagram and 5 current triggers
- Documents concurrency control (max_concurrent=4, max_iterations=15)
- Documents task-subagent relationship (1:1, restricted tools, no event bus)
- Documents task persistence via JSONL ledger and recovery semantics
- Preserved existing memory lifecycle contract in Section 10

### Task 3: Document target session-control API semantics
- Annotated `docs/openapi-v1.yaml` with 14 TODO markers
- Marked all existing endpoints as stable
- Added planned endpoints: tasks list/get/stop, approvals, session compact/context/resume/export, usage
- Each TODO tagged with sprint assignment (2A, 2B, 3A, 4A, 4B)
- Cross-referenced docs/online-agent-contract.md and docs/agent-lifecycle-spec.md

## Acceptance Criteria Verification

1. online-agent-contract.md exists and defines all target run events ✓
2. agent-lifecycle-spec.md exists and defines task lifecycle ✓
3. openapi-v1.yaml annotated with 14 planned extensions ✓
4. No runtime code changes ✓
5. Documents consistent with current gateway.zig behavior ✓
