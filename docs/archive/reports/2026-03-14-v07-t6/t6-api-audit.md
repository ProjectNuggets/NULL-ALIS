# T6 Frontend-Agnostic API Audit

Date: 2026-03-14  
Scope: `/v1/me/bot/*` product-facing BFF contract

## Audit Checklist
1. Field names contain no page/layout semantics.
2. Each endpoint represents a product capability/state.
3. Error codes come from stable cross-client catalog.
4. SSE contract is transport-safe and replay-safe.
5. Second frontend can consume endpoint without schema changes.

## Product-Level vs UI-Specific Classification

### Product-Level Fields (Allowed)
1. `completed`, `completed_at_s`
2. `assistant_mode`, `group_activation`, `proactive_updates`, `voice_replies`, `session_timeout_minutes`
3. `status`, `channel`
4. `state`, `requests_day`, `tokens_day`, `tokens_month`
5. `error`, `message`, `retryable`, `request_id`
6. SSE `code`, `message`, `retryable`

### UI-Specific Fields (Forbidden)
1. `panel_tab`
2. `screen_state`
3. `view_mode`
4. `mobile_compact`
5. `layout_variant`
6. page-level copy/labels

## Endpoint Reuse Audit
1. `POST /v1/me/bot/provision` -> reusable by web/mobile/desktop unchanged: `yes`
2. `GET /v1/me/bot/onboarding` -> reusable unchanged: `yes`
3. `PUT /v1/me/bot/onboarding` -> reusable unchanged: `yes`
4. `GET /v1/me/bot/settings` -> reusable unchanged: `yes`
5. `PATCH /v1/me/bot/settings` -> reusable unchanged: `yes`
6. `POST /v1/me/bot/chat/stream` -> reusable unchanged: `yes`
7. `POST /v1/me/bot/telegram/connect` -> reusable unchanged: `yes`
8. `POST /v1/me/bot/telegram/disconnect` -> reusable unchanged: `yes`
9. `GET /v1/me/bot/usage` -> reusable unchanged: `yes`

## SSE Replay Rule Verification
1. Retry allowed only before upstream SSE body begins.
2. Once first SSE bytes are forwarded, no request replay/retry.
3. Mid-stream faults are emitted as normalized `event:error`.

## Findings
1. No endpoint in the T6 contract requires UI-specific fields.
2. Contract can be consumed by at least two frontend shapes without redesign.
3. Remaining risk is implementation drift in BFF code; enforce with schema tests.

## Required Guardrail Tests in BFF
1. DTO rejects unknown UI-only fields.
2. Error catalog mapping is fixed and snapshot-tested.
3. SSE pre-stream retry and post-stream no-retry behavior tested.
