---
tags: [prose, prose/docs]
---

# Security Hardening Plan (Next Sprint)

Date: 2026-03-16
Scope: nullalis gateway/front-door configuration hardening for open beta.

## Why this sprint exists

Current runtime accepts internal routes when `gateway.internal_service_tokens` is empty.
This is acceptable for local development but unsafe for public/tenant deployment.

Test literals like `test-internal-token` and sample local Postgres URLs exist in test code paths and docs.
They are not runtime defaults, but they create audit noise and should be removed from test fixtures.

## Locked goals

1. Fail closed in public mode for internal API auth.
2. Reject weak internal tokens at startup in production-like configurations.
3. Keep local dev ergonomics (no unnecessary breakage on localhost-only runs).
4. Remove hardcoded secret-like literals from tests and docs where feasible.

## Implementation slices

### S1: Startup security validator (gateway)

Add a gateway startup validation stage in `src/gateway.zig`:

1. Detect production-like mode:
   - `tenant.enabled == true`, or
   - `gateway.allow_public_bind == true`, or
   - `gateway.host` is non-loopback.
2. In production-like mode:
   - require `gateway.internal_service_tokens.len > 0`.
   - reject startup if empty.
3. Emit explicit startup failure reason and log key:
   - `security_config_invalid`
   - reason code (machine-readable).

### S2: Token quality policy

Add token policy helper (gateway/config layer):

1. Denylist obvious test/default values:
   - `test-internal-token`
   - `dev-internal-token`
   - `changeme` (and common trivial variants).
2. Enforce minimum quality in production-like mode:
   - minimum length threshold.
   - basic entropy/charset heuristic.
3. Reject startup when invalid.

### S3: Internal auth default tightening

Adjust behavior in `validateInternalServiceToken` path:

1. Keep permissive empty-token behavior only for explicit local dev mode.
2. For production-like mode, enforce strict token requirement.
3. Add tests for both local-dev and production-like branches.

### S4: Remove hardcoded secret-like literals from tests

In test paths (mainly `src/gateway.zig` tests):

1. Replace static `test-internal-token` literals with generated test fixture helper values.
2. Replace static Postgres credential literals in test assertions with neutral placeholders.
3. Keep tests deterministic and non-networked.

### S5: Deploy/runbook alignment

1. Update `deploy/k8s/zaki-bot/README.md` and secrets template notes:
   - internal token is mandatory in public/tenant mode.
   - required token generation guidance.
2. Add a preflight checklist item:
   - startup fails if token policy invalid (expected).

## Acceptance criteria

1. Gateway refuses to start in production-like mode when internal tokens are empty.
2. Gateway refuses weak/denylisted internal tokens in production-like mode.
3. Local localhost-only dev mode continues to run without forced token setup.
4. No hardcoded secret-like test literals remain in runtime-path tests.
5. Full gates pass:
   - `zig build test --summary all`
   - `zig build -Dengines=base,sqlite,postgres`

## Rollout order

1. Land validator + tests.
2. Land token policy + tests.
3. Update deploy manifests/secrets in staging.
4. Confirm staging startup fails on invalid token config.
5. Promote with updated runbook.
