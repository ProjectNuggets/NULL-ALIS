# T6 Handoff — BFF Integration Readiness

## What is now available in nullalis

1. Lock-protected conflict responses now return deterministic JSON:
   - `error=ownership_lock_conflict`
   - `message`
   - `retry_after_ms`
   - optional `owner_instance_id`
   - optional `lease_until_s`
2. HTTP lock conflicts include `Retry-After` header.
3. SSE lock conflicts include `retry_after_ms` metadata in the `event:error` payload.
4. Tenant lock behavior is configurable:
   - `tenant.ownership_lock_lease_secs`
   - `tenant.ownership_lock_wait_ms`
   - `tenant.ownership_lock_retry_min_ms`
   - `tenant.ownership_lock_retry_max_ms`
5. Diagnostics/metrics include:
   - `tenant_lock_conflict_retries_total`
   - `tenant_lock_conflicts_by_route`
   - lock backend and lock timing settings.

## BFF T6 implementation checklist

1. Retry only `409` responses where `error=ownership_lock_conflict`.
2. Use `retry_after_ms` from gateway body when present.
3. Fallback backoff when absent:
   - `100ms`, `250ms`, `500ms` with jitter ±20%.
4. Stop retrying at:
   - max attempts `3`, or
   - max wall-time `1500ms`.
5. Preserve idempotency key and user binding (`X-Zaki-User-Id`) across retries.
6. Map exhausted retries to:
   - status `503`
   - `{ "error": "temporary_contention", "message": "Agent is busy on another node. Retry shortly." }`
7. Emit BFF metrics/logs:
   - conflict detected
   - retries attempted
   - retry success
   - retry exhausted.

## Validation expected in T6

1. With two gateway nodes and same user contention:
   - user should not see raw lock conflict in normal UX path.
2. BFF should recover on lock release within retry budget.
3. No cross-user header leakage or auth/token regression.
