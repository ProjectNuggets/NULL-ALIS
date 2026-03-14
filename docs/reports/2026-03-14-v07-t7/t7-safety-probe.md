# V0.7-T7 Safety Probe Report

Date: 2026-03-14  
Branch: `v0.7-t7-safety-minimum`  

## Precheck
Command:
```bash
python3 scripts/load-burst.py --help
```
Result: pass (`scripts/load-burst.py` present and executable).

## Controlled Probe Run
Command:
```bash
python3 scripts/load-burst.py \
  --url http://127.0.0.1:3000/api/v1/chat/stream \
  --token dev-internal-token \
  --mode multi-user \
  --users 10 \
  --requests 10 \
  --workers 5 \
  --timeout-secs 180 \
  --lane-strategy main_only \
  --capture-diagnostics \
  --run-label t7-safety-minimum \
  --json > docs/reports/2026-03-14-v07-t7/t7-safety-probe.json
```

## Result Summary
From `t7-safety-probe.json`:
1. `success=10`, `errors=0`
2. `latency_ms`: `p50=14481`, `p95=26195`, `p99=26195`
3. `failure_samples`: `0`
4. `diagnostics.tenant_lock_conflicts_by_route` remained zero before/after.

## Classification Outcome
1. Probe completed.
2. No panic/crash observed.
3. No non-success errors to classify in this run.

## Artifact
Primary machine-readable evidence:
- `docs/reports/2026-03-14-v07-t7/t7-safety-probe.json`

