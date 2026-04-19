# Second Confirmatory Canary Report (50% Rollout)

Date: 2026-03-11  
Environment: local gateway (`127.0.0.1:3000`), canary set to 50%, response cache disabled for this run set.

## Run artifacts

- `rollout50-nocache-multi-20.json`
- `rollout50-nocache-multi-50.json`
- `rollout50-nocache-multi-100.json`

## Results (multi-user burst)

| Users | Success | Errors | p50 (ms) | p95 (ms) | p99 (ms) | Wall (ms) |
|---|---:|---:|---:|---:|---:|---:|
| 20 | 19/20 | 1 (`http_error`) | 12,668 | 20,731 | 134,315 | 134,320 |
| 50 | 49/50 | 1 (`http_error`) | 34,045 | 56,889 | 165,705 | 165,716 |
| 100 | 100/100 | 0 | 64,824 | 115,331 | 190,035 | 191,358 |

## Readout

1. Stability is acceptable at this canary level: success rate is high and no crash occurred.
2. Tail latency remains the gating risk: p95/p99 are still too high for a conversational UX under burst.
3. Throughput degrades with concurrency in a queue-shaped curve (no collapse, but clear backlog effects).
4. The single `http_error` occurrences at 20/50 indicate transport fragility still exists in burst conditions.

## Comparability note

The earlier 5% canary artifacts were captured under a different cache posture.  
Do not treat 5% vs 50% deltas as strict A/B without rerunning both at identical cache/config settings.

## Recommendation

1. Keep canary capped (do not raise beyond 50% yet).
2. Run a matched-config A/B set (5% and 50% with the same cache + prompt load).
3. Prioritize latency-tail reduction before wider rollout:
   - turn-level budget controls
   - reduction of long tool/reflection loops
   - stronger session-lane isolation under burst
