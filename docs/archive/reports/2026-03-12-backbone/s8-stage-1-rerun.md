# S8 Stage 1 Re-run Report — Soft-Gate Validation

Date: 2026-03-12  
Owner: Codex (runtime/platform)  
Scope: P1 recovery slice (RCA sync + lease observability + split canary tracks)

## Inputs

- Baseline head before rerun: `806d196`
- RCA sync commit: `5677070`
- Observability patch commit: `429a56e`
- Artifacts:
- `s8-stage-1-rerun-chatstream-100.json`
- `s8-stage-1-rerun-telegram-strict-ingress.json`
- `p1-chatstream-20.json`
- `p1-chatstream-50.json`
- `p1-chatstream-100.json`
- `p1-telegram-strict-ingress.json`

## Split Canary Results

Chat-stream stability track:
- 20 users (`main_only`): `20/20`, `0%` errors, `p50=10023ms`, `p95=14952ms`, `p99=17170ms`
- 50 users (`mixed_real`): `50/50`, `0%` errors, `p50=36993ms`, `p95=61911ms`, `p99=62950ms`
- 100 users (`main_only`): `100/100`, `0%` errors, `p50=35323ms`, `p95=68579ms`, `p99=73162ms`

Strict Telegram ingress track (explicit webhook path):
- mapped request: `403` (`invalid telegram secret token`)
- unmapped request: `403` (`invalid telegram secret token`)
- strict reject signal (`strict_identity_reject`): not observed
- binding upsert request: `500` (`upsert binding failed`)

## Observability Checks

- No runtime panic observed during chat-stream replay.
- `tenant_lock_conflicts_by_route` remained zero in captured chat-stream diagnostics snapshots.
- `tenant_lease_probe` surfaced in diagnostics for scoped users with additive fields:
- `user_id`
- `data_source`
- `owner_id`
- `lease_until_s`
- `updated_at_s`

## Soft-Gate Evaluation

Temporary soft gate policy:
- one grace run allowed at `<=10%` error and no panic
- strict-ingress mapped/unmapped behavior must still be explainable and correct

Evaluation:
- chat-stream error rate: `0%` (PASS)
- no panic: PASS
- strict-ingress correctness: FAIL (blocked before canonical strict decision by secret-token rejection)

Decision: **ROLLBACK (config-only)**  
Reason: grace run failed strict-ingress correctness condition.

## Rollback Action

- Reverted local stage strict config to pre-stage baseline:
- `tenant.identity_mapping_enforcement`: back to compat/default
- `tenant.identity_mapping_strict_channels`: cleared

## Next Step (P2)

1. Fix Telegram strict-ingress preconditions in canary environment:
- valid webhook secret token injection for test user
- successful mapped binding upsert in strict-ingress harness path
2. Re-run strict-ingress canary to verify:
- mapped accepted
- unmapped strict-rejected with `strict_identity_reject`
3. Keep chat-stream and strict-ingress tracks separate for promotion decisions.
