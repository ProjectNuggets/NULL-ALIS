# T8 Fix Baseline (Core Proactivity Stabilization)

Date: 2026-03-15  
Branch: `v0.7-t8-proactive-single-truth`  
Start SHA: `0e54c1a`

## Scope

Targeted fixes for:

1. Duplicate heartbeat turns.
2. Heartbeat/wake running on main session lane.
3. Brittle heartbeat phrase suppression.
4. Missing terminal delivery feedback in heartbeat runtime status.

## Baseline Signals

Observed pre-fix behavior (from runtime logs):

1. Long session lock waits on main lane (examples seen above 50s and above 150s).
2. Contradictory proactive chatter from heartbeat narratives.
3. Heartbeat status frequently stopping at enqueue-level interpretation.

## Pre-Change Gates

1. `zig build test --summary all` passed.
2. `zig build -Dengines=base,sqlite,postgres` passed.

## Risk Acceptance

1. Risk acceptances: none.
