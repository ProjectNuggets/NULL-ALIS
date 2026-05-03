---
tags: [prose, prose/docs]
---

# Founder Control Dashboard (v0.2)

Date: 2026-03-12  
Branch: `v0.2-scale-exec-swisswatch`  
Baseline commit: `73f52f3`

## 1) NOW (Current State)

### Deployment
1. Status: **ready for controlled small-scale deployment**.
2. Gate posture:
- Profile A (north-star claim gate): **FAIL**.
- Profile B (rollout guardrail): **PASS**.
3. Canary evidence (Q5):
- 20 users: p50 `14.4s`, p95 `27.6s`, p99 `33.8s`, errors `0%`.
- 50 users mixed: p50 `29.9s`, p95 `50.5s`, p99 `60.2s`, errors `0%`.
- 100 users: p50 `82.8s`, p95 `134.3s`, p99 `144.4s`, errors `0%`.

### Product / UX
1. Core runtime truth hardening is in place.
2. Session lanes + ownership/lock path are implemented.
3. UX is stable for current scale, but tail latency under high concurrency is still the main pain point.

### Monetization
1. Plan and packaging direction are documented.
2. Infra capacity/cost sensitivity model exists.
3. Entitlements/metering/billing activation is still not fully production-implemented.

## 2) RISK (What Can Hurt Us Now)

1. Latency risk at high concurrency (experience degrades before correctness fails).
2. Scale-claim risk: cannot claim strict performance tier yet.
3. Operational evidence gap: still need staged multi-cell proof for sticky routing + noisy-neighbor isolation in target environment.
4. Commercial risk: pricing story is ahead of meter enforcement if launched too early.

## 3) NEXT 7 DAYS (Execution Sequence)

1. Deploy controlled rollout in staging/prod envelope (4-6 pods target).
2. Run staged multi-cell canaries: 10% -> 25% -> 50% -> 75% -> 100%.
3. Publish one report per stage (JSON + short decision note).
4. Validate and document:
- sticky routing consistency,
- `tenant_lock_backend=postgres_lease`,
- noisy-neighbor isolation delta.
5. Start monetization execution slice:
- entitlements check at runtime entry points,
- usage meter ingestion,
- operator/user usage visibility.

## 4) GO / NO-GO

### GO (Allowed)
1. Controlled deployment for small scale:
- up to ~300 total users,
- ~30 active concurrently,
- with Profile B guardrails and canary monitoring.

### NO-GO (Not Allowed Yet)
1. Public scale-performance claim at strict tier (Profile A not met).
2. Aggressive traffic promotion without staged canary evidence.
3. Broad paid launch without metering + entitlement enforcement.

## 5) Decision Board (Founder)

Decide now:
1. Approve controlled rollout with 4-6 pods and staged canary progression.
2. Keep public messaging at: "reliable at current rollout profile; latency optimization in progress."
3. Prioritize monetization backend execution (entitlements + metering) immediately after rollout stabilization.

## 6) Single Source Links

1. Core operational truth: `docs/v0.2-single-source-of-truth.md`
2. Canary decision baseline: `docs/reports/canary-2026-03-12-q5/canary-suite-report.md`
3. Capacity/cost refresh: `docs/reports/canary-2026-03-12-q5/capacity-cost-refresh.md`
4. Operational runbook: `docs/v0.2-operational-model-agent-runbook.md`
5. v0.2 product plan: `docs/plan-v02.md`
