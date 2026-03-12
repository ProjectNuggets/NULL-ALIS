# Session-Lane Baseline Freeze (v0.1.1)

Date: 2026-03-12  
Branch: `v0.2-baseline-ledger-utilization`

## Runtime posture locked for this suite

1. `agent.parallel_tools=true`
2. `agent.tool_dispatcher="parallel"`
3. `agent.parallel_tools_rollout_percent=50`
4. `memory.response_cache.enabled=false`
5. `state.backend=postgres` effective at runtime

## Effective policy snapshot

1. Direct Telegram/app continuity defaults to shared main (`cross_channel_shared_main=true`).
2. Explicit split lanes are allowed and measured via client/session-key strategy:
- `thread:<conversation_id>`
- `task:<task_id>`
3. Scheduler lane is canonicalized as `cron:<job_id>`.

## Baseline gates run

1. `zig build test --summary all` -> pass
2. `zig build -Dengines=base,sqlite,postgres` -> pass

## Control artifacts retained

1. `docs/reports/canary-2026-03-11/rollout5-multi-20.json`
2. `docs/reports/canary-2026-03-11/rollout5-multi-50.json`
3. `docs/reports/canary-2026-03-11/rollout5-multi-100.json`
4. `docs/reports/canary-2026-03-11/rollout50-nocache-multi-20.json`
5. `docs/reports/canary-2026-03-11/rollout50-nocache-multi-50.json`
6. `docs/reports/canary-2026-03-11/rollout50-nocache-multi-100.json`
