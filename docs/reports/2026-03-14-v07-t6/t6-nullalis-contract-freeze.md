# T6 nullalis Contract Freeze

Date: 2026-03-14  
Branch: `v0.7-t6-contract-freeze`

## Contract Pin (for BFF)
1. OpenAPI file: `docs/openapi-v1.yaml`
2. OpenAPI SHA-256: `02179fea9b5984e6761bdff7821e8b9c29e4a6d810ce2dc3719cefeb0fb55097`
3. Gateway source: `src/gateway.zig`
4. Gateway SHA-256: `6031773e6321dcb1f9fe12e63de2a301c4b0a79714b36c02447799e4e5bbc6f3`
5. Pin timestamp (UTC): `2026-03-14T14:51:31Z`

## Frozen Internal Endpoints Consumed by BFF
1. `POST /api/v1/users/provision`
2. `GET /api/v1/users/{user_id}/onboarding`
3. `PUT /api/v1/users/{user_id}/onboarding`
4. `GET /api/v1/users/{user_id}/settings`
5. `PATCH /api/v1/users/{user_id}/settings`
6. `PUT /api/v1/users/{user_id}/settings`
7. `POST /api/v1/chat/stream` (SSE)
8. `POST /api/v1/users/{user_id}/channels/telegram/connect`
9. `POST /api/v1/users/{user_id}/channels/telegram/disconnect`

## Lock Conflict Contract (Frozen)
For lock-protected write routes:
1. HTTP status: `409 Conflict`
2. Header: `Retry-After: <seconds>`
3. JSON body schema: `OwnershipLockConflictResponse`
4. `error` value: `ownership_lock_conflict`
5. Includes `retry_after_ms`, optional ownership metadata

Example:
```json
{
  "error": "ownership_lock_conflict",
  "message": "user is active on another node, retry shortly",
  "retry_after_ms": 250,
  "owner_instance_id": "node-a",
  "lease_until_s": 1760000000
}
```

SSE stream conflict (pre-stream):
1. Status `409`
2. `event:error` payload includes `code=ownership_lock_conflict` and retry metadata.

## Lock Timing Knobs (Frozen)
1. `tenant.ownership_lock_lease_secs`
2. `tenant.ownership_lock_wait_ms`
3. `tenant.ownership_lock_retry_min_ms`
4. `tenant.ownership_lock_retry_max_ms`

## Frontend-Agnostic Guarantee from nullalis Side
1. Contract is transport/state oriented, not page-layout oriented.
2. No UI-only fields are present in internal API schemas.
3. BFF can map these contracts to multiple client types without gateway schema changes.
