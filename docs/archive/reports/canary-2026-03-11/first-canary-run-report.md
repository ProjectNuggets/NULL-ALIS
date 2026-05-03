---
tags: [prose, prose/docs]
---

# First Canary Run Report (v0.2 Baseline Activation)

Date: 2026-03-11  
Branch SHA: `1f0ed2d`  
Environment: local gateway (`127.0.0.1:3000`), tenant+Postgres enabled, chat provider `openrouter`, embedding provider `together`

## Canary config
- `agent.parallel_tools = true`
- `agent.tool_dispatcher = "parallel"`
- `agent.parallel_tools_rollout_percent = 5`

Startup evidence (gateway log):
- `agent.parallel_tools canary active rollout_percent=5 dispatcher=parallel`

## Workload and method
- Tool: `scripts/load-burst.py`
- Endpoint: `POST /api/v1/chat/stream`
- Mode: multi-user burst (distinct users)
- Prompt:
  - `Use runtime_info summary and schedule list, then answer in one short sentence.`
- Runs:
  1. `20 users / 20 requests / 20 workers`
  2. `50 users / 50 requests / 50 workers`
  3. `100 users / 100 requests / 100 workers`

Raw artifacts:
- [`rollout5-multi-20.json`](/Users/nova/Desktop/nullalis/docs/reports/canary-2026-03-11/rollout5-multi-20.json)
- [`rollout5-multi-50.json`](/Users/nova/Desktop/nullalis/docs/reports/canary-2026-03-11/rollout5-multi-50.json)
- [`rollout5-multi-100.json`](/Users/nova/Desktop/nullalis/docs/reports/canary-2026-03-11/rollout5-multi-100.json)

## Results

| Profile | Success | Errors | p50 | p95 | p99 | Mean | Wall |
|---|---:|---:|---:|---:|---:|---:|---:|
| 20 users | 19/20 | 1 | 16.5s | 135.7s | 136.4s | 29.2s | 136.4s |
| 50 users | 50/50 | 0 | 16.9s | 262.8s | 263.7s | 76.9s | 263.7s |
| 100 users | 100/100 | 0 | 15.8s | 527.1s | 637.8s | 151.7s | 643.7s |

## Interpretation
1. Stability is high under burst (50/50 and 100/100 complete).
2. Median remains relatively stable (~16s), but tail latency grows sharply with concurrency.
3. Queueing/long-tail saturation remains the dominant issue for user experience at higher burst levels.

## Canary-specific notes
1. This was a low-rollout canary (`5%`), so parallel tool dispatch impact is intentionally limited.
2. Observed turns in sampled logs still showed many `dispatch_tools ... mode=serial` paths, which is expected at low rollout and mixed tool-call patterns.
3. This run validates safety/stability of canary activation, not maximum speedup.

## Recommendation (next step)
1. Keep rollout at `5%` for now.
2. Run one additional repeated sample (same workload) to confirm reproducibility.
3. If error rate remains near zero, move to `20%` and rerun 20/50/100.
4. Gate progression on:
   - error rate
   - p95/p99 regression threshold
   - no crash/termination events

## Known caveat during setup
An earlier attempt failed with `connection refused` because the gateway process was not alive. Those failed outputs were discarded and replaced with the valid run artifacts above.
