---
tags: [prose, prose/docs]
---

# T8 Fix Decision Report (Core Proactivity Stabilization)

Date: 2026-03-15  
Branch: `v0.7-t8-proactive-single-truth`

## Implemented Changes

### 1) Duplicate heartbeat turn removed

1. Interval lane now only triggers wake (`heartbeat.interval_due`) and writes runtime state.
2. Wake lane performs the single heartbeat model turn and outbound enqueue.

### 2) Heartbeat/wake lane isolated from main session

1. Heartbeat synthetic job now uses `session_target = .isolated`.
2. Wake queue processing always runs forced wake lane behavior.

### 3) Deterministic heartbeat reply contract

1. Heartbeat prompt now requires exact output forms:
   - `HEARTBEAT_OK`
   - `HEARTBEAT_SEND: <single concise sentence>`
2. Phrase blacklist suppression was replaced with strict parser validation.
3. Invalid output now maps to runtime status:
   - `send_failed`
   - reason `invalid_heartbeat_reply_format`

### 4) Delivery outcome feedback loop added

1. Dispatcher now emits delivery outcomes (for sourced/proactive outbound messages).
2. Bus now carries delivery outcomes in a dedicated queue.
3. Daemon consumes outcomes and writes terminal heartbeat runtime states:
   - `sent`
   - `blocked_rate`
   - `blocked_dedupe`
   - `send_failed`
4. Runtime truth parser now reads `heartbeat_runtime` status/reason/run timestamp from diagnostics payload.

## Validation Results

1. `zig build test --summary all` passed (`4610 passed`, `21 skipped`, `0 failed`).
2. `zig build -Dengines=base,sqlite,postgres` passed.

## Added/Updated Test Coverage

1. `bus`: delivery outcome roundtrip, queue depth, close semantics.
2. `dispatch`: proactive delivery outcome emission for sent, blocked dedupe, send error, channel-not-found.
3. `daemon`: strict heartbeat reply parser coverage, delivery outcome mapping, outcome-thread-to-runtime-file write.
4. `runtime_truth`: heartbeat runtime diagnostics parsing coverage.

## GO/HOLD

Decision: **GO (local code/test gates)**.

Notes:

1. Staging lock-wait reduction evidence is still required for rollout decisioning.
2. This report covers code correctness and local regression gates only.
