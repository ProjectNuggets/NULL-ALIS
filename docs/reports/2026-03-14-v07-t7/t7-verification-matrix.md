# V0.7-T7 Verification Matrix

Scope: safety-minimum verification for queue and rate-limit behavior with objective evidence mapping.

## Gap Policy Applied
1. Observability gap only: add additive counter/log (no policy mutation).
2. Coverage gap (zero direct test): add fast local test if feasible; else document residual risk with HOLD trigger.
3. Both missing: add additive observability + targeted test, else residual risk.

## Requirement Matrix

| Requirement | Tests | Counters/Signals | Status |
|---|---|---|---|
| Queue mode `off` bypasses cap/drop side effects | `src/session.zig` test `queue_mode_off_bypasses_queue_cap_and_drop` | `session.lock_wait` warning log, `message.process` info log | Covered |
| Queue mode `latest` supersedes deterministically | `src/session.zig` test `queue_mode latest supersedes older waiting turn` | Drop message `QUEUE_LATEST_SUPERSEDED_MESSAGE` | Covered |
| Queue mode `summarize` injects exactly once and resets | `src/session.zig` test `queue_drop_summarize_injects_single_synthetic_summary_on_next_turn` | History marker `[Queue notice: ...]`, `queue_summarize_pending_count == 0` assertion | Covered |
| Queue mode `oldest` deterministic drop semantics | `src/session.zig` test `queue_drop_oldest_still_holds` | Drop message `QUEUE_OLDEST_DROPPED_MESSAGE` | Covered |
| Gateway rate limiter deterministic blocking semantics | `src/gateway.zig` tests: `gateway rate limiter blocks after limit`, `gateway rate limiter pair and webhook independent`, `gateway rate limiter zero limits always allow` | 429 response body contract in handlers (`{\"error\":\"rate limited\"}`) | Covered (unit + handler contract) |
| Route lock-conflict counters increment by route | `src/gateway.zig` test `recordTenantLockConflict increments route counters and total` | `tenant_lock_conflicts_by_route` in diagnostics + prometheus metrics | Covered |
| Safety probe produces classifiable errors | `scripts/load-burst.py` structured `reason/error_class/error_detail` schema | JSON artifact fields + diagnostics snapshot before/after | Covered |

## Observability/Gaps Assessment
1. No missing test coverage for the six T7 safety-minimum requirements.
2. Residual observability note (non-blocking):
- There is no dedicated `rate_limited_total` counter family broken down by endpoint class.
- Current safety-minimum relies on deterministic 429 contract + existing limiter tests.

## Residual Risk Register
1. `R-T7-001` (Low): Endpoint-specific runtime 429 counters are not yet emitted in diagnostics.
- Impact: if probe returns 429, explanation depends on response class + limiter path tests, not dedicated runtime counter increments.
- HOLD trigger: repeated unexplained 429 bursts in staging/prod-like runs.
- Follow-up branch: `v0.7-t7-fix-rate-limit-observability` (additive counters only).

