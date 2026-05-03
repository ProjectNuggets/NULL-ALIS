---
tags: [prose, prose/docs]
---

# S6 — User-Scoped Binding CRUD API

## Objective
Expose additive API endpoints for managing channel identity bindings per user/channel with ownership-scoped operations.

## Files Changed
- `src/gateway.zig`
- `docs/openapi-v1.yaml`
- `src/zaki_state.zig`

## Implementation
- Added user-scoped channel binding routes:
  - `GET /api/v1/users/{user_id}/channels/{channel}/bindings`
  - `POST /api/v1/users/{user_id}/channels/{channel}/bindings`
  - `DELETE /api/v1/users/{user_id}/channels/{channel}/bindings/{binding_id}`
- Added route parser for binding collection/item subpaths.
- Wired CRUD operations to `zaki_state` identity binding APIs.
- Added cache invalidation hooks on upsert/delete via `inbound_canonicalizer`.
- Updated OpenAPI with endpoint and parameter definitions.
- Fixed nullable result duplication helper in `zaki_state` (`try` propagation).

## Tests Added/Updated
- `parseUserChannelBindingsSubpath parses bindings collection route`
- `parseUserChannelBindingsSubpath parses binding item route`

## Gates
- `zig build test --summary all` ✅
- `zig build -Dengines=base,sqlite,postgres` ✅

## Risks / Open Points
- API currently relies on existing internal-token route protection; no new auth model was introduced in this slice.
- Payload field semantics are validated for presence/non-empty; stricter schema-level constraints can be expanded later.
