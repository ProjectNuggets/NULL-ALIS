# V1 Production Readiness Report

> **STATUS: FINAL BACKEND BASELINE.** Signed off on 2026-05-29 after
> Sprint S6 merged at `19bf7ba6`. CI run
> <https://github.com/ProjectNuggets/NULL-ALIS/actions/runs/26663275706>
> passed the canonical production profile and the V1 verification
> matrix against live Postgres. This report is the backend readiness
> baseline for the commercial V1 surface; deployment and ZAKI app UI
> release gates are listed separately below.

## 1. Sprint Sign-Off Summary

| Sprint | Deliverable | PR | Merge SHA | Status |
|---|---|---|---|---|
| S1 | D52 Pillars 2+4: PII tagging + `memory_purge_pii` tool | #108 | `a0531b29` | merged |
| S2 | Approval consolidation: stable `apr-{u64}` id + 409 stale-card guard | #109 | `dececa3c` | merged |
| S3 | Durable trace share records via Postgres snapshot | #110 | `9ed4fbca` | merged |
| S4 | Extension browser readiness: diagnostics + lifecycle + isolation + E2E | #111 | `baaaeb9e` | merged |
| S5 | Observability + SLOs: metrics catalog and production fail-loud gate | #112 | `78939eab` | merged |
| S5 follow-up | Observability review remediation + hardening | #113 | `560500cc` | merged |
| S6 | V1 production verification matrix | #115 | `19bf7ba6` | merged |

## 2. Verification Evidence

CI source of truth: <https://github.com/ProjectNuggets/NULL-ALIS/actions/runs/26663275706>

`Canonical Profile (linux-x86_64, postgres)`:

- `Run tests (canonical production engines)`:
  `Build Summary: 22/22 steps succeeded; 6956/6971 tests passed; 15 skipped`
- `V1 production verification matrix`:
  `Build Summary: 6/6 steps succeeded; 93/94 tests passed; 1 skipped`
- `Build ReleaseSmall (canonical production engines)`: passed

Local merge-gate verification run by Codex on 2026-05-29:

- `zig build -Dengines=base,sqlite,postgres` -> exit 0
- `zig build test -Dengines=base,sqlite,postgres --summary all` ->
  `22/22 steps succeeded; 6892/6971 tests passed; 79 skipped`
- `zig build test-postgres -Dengines=base,sqlite,postgres --summary all`
  without a PG URL -> `6/6 steps succeeded; 86/94 tests passed; 8 skipped`
- Live pgvector fixture:
  `NULLALIS_POSTGRES_TEST_URL=postgresql://zaki:zaki@localhost:5432/zaki zig build test-postgres -Dengines=base,sqlite,postgres --summary all`
  -> `6/6 steps succeeded; 93/94 tests passed; 1 skipped`

Negative proofs:

- Bogus `NULLALIS_POSTGRES_TEST_URL=postgresql://zaki:zaki@127.0.0.1:1/zaki`
  correctly fails the live-PG lane with 7 live test failures.
- `zig build test-postgres -Dengines=base,sqlite --summary all`
  correctly compile-fails at `tests/verification/root.zig:14`.

## 3. Production-Ready Backend Surface

The backend V1 contract is now ready for the exposed Agent surface where
the UI binds to the documented routes and event contracts:

- Chat stream, session-scoped mode changes, active-turn cancel, and
  approvals.
- Attachment idempotency and safe retry behavior.
- Artifact create/update/share/revoke/export/download surfaces.
- Durable trace share URLs with sanitized snapshot persistence.
- Extension browser control plane, diagnostics, SSRF blocking, and
  failure reporting.
- User-scoped memory store/recall/forget plus PII tagging and
  `memory_purge_pii`.
- Postgres durability gates for sessions, memories, artifacts, jobs,
  tasks, trace shares, and schema cascade invariants.
- Prometheus `/metrics` catalog, SLO mapping, cardinality cap, and
  production fail-loud behavior when configured Postgres is unavailable.
- V1 verification command and CI gate: `zig build test-postgres`.

## 4. Hidden Or Deferred From V1 Claims

These surfaces must not be marketed or exposed as production-ready V1
behavior:

- Top-level `/api/v1/chat/cancel`, `/api/v1/chat/resume`, and
  `/api/v1/chat/approve`; only session-scoped cancel/approve exist, and
  there is no resume route.
- Live subagent interruption; only queued subtasks can be cancelled.
- Bi-temporal `valid_to` contradiction classifier.
- Per-cell isolated pods; current state is a shared runtime.
- D52 Pillar 5 at-rest encryption of `pii_tagged` rows; V1 ships
  tagging and purge, encryption is V1.1 with secret-vault integration.
- Address/name PII detection and 7-9 digit US-local phone numbers
  without area code or `+`; V1 detector scope is phone + email.
- End-user Composio/integration claims unless the gated lane is
  configured and passing in the operator environment.
- Public `/metrics`; treat it as operator-only and firewall it.
- Bound-port HTTP/SSE E2E harness and real Chrome extension binary E2E;
  S6 pins these with in-process/mocked coverage plus operator runbook.

## 5. Remaining Release Gates

No backend S1-S6 launch blocker remains for the documented V1 surface.
Before GA, the following gates still need owner sign-off:

- **Deployment smoke:** boot the production binary in the DigitalOcean
  environment with Postgres intentionally unavailable and confirm the
  process exits non-zero with `startup.production_postgres_required`.
- **Promotion environment:** close D15 by creating the GitHub
  `production-image-promotion` environment with Nova as required
  reviewer before relying on `:latest` promotion.
- **ZAKI app UI E2E:** verify the V2 app binds to the session-scoped
  Agent contract: mode/reasoning/autonomy controls, cancel, approvals,
  attachments, artifacts, trace share, extension browser, memory/PII
  settings, and meter/usage surfaces.
- **Visibility discipline:** keep every hidden surface above absent from
  app copy, website claims, onboarding, and public docs.

Residual non-blocking backlog remains in `docs/deferred-register.md`.
Items that are explicitly post-launch or hidden from V1 include
run-scoped approval allow-cache (D2), strict idempotency enforcement
(D6), secret-vault integration for OpenAPI connector credentials (D47),
PII at-rest encryption (D52 Pillar 5), and broader live bound-port E2E
coverage.

## 6. Exact Verification Sequence

Fresh checkout baseline:

```bash
git checkout main
git pull --ff-only origin main
zig build -Dengines=base,sqlite,postgres
zig build test -Dengines=base,sqlite,postgres --summary all
zig build test-postgres -Dengines=base,sqlite,postgres --summary all
```

Live Postgres matrix:

```bash
docker run --rm -d --name nullalis-s6 -p 5432:5432 \
  -e POSTGRES_USER=zaki \
  -e POSTGRES_PASSWORD=zaki \
  -e POSTGRES_DB=zaki \
  pgvector/pgvector:pg16

sleep 6

NULLALIS_POSTGRES_TEST_URL=postgresql://zaki:zaki@localhost:5432/zaki \
  zig build test-postgres -Dengines=base,sqlite,postgres --summary all

docker rm -f nullalis-s6
```

Failure-mode proofs:

```bash
NULLALIS_POSTGRES_TEST_URL=postgresql://zaki:zaki@127.0.0.1:1/zaki \
  zig build test-postgres -Dengines=base,sqlite,postgres --summary all

zig build test-postgres -Dengines=base,sqlite --summary all
```

Both commands above must fail for the right reason: the first because a
configured PG URL is unreachable, the second because the verification
matrix requires the Postgres engine at compile time.

## 7. Rollback Plan

If a V1 backend production regression surfaces:

1. Identify the failing surface using
   `docs/operations/verification-matrix.md` and its failure-triage table.
2. Pin the offending merge with `git log --first-parent main` after
   `19bf7ba6`.
3. Hot revert the relevant squash merge with `git revert <sha>`.
4. Re-run the default baseline and live Postgres matrix.
5. Open a follow-up PR for root cause. Do not forward-fix directly to
   main without the verification matrix.

## 8. Sign-Off

| Role | Status | Date | SHA |
|---|---|---|---|
| Backend merge gate | reviewed and merged by Codex | 2026-05-29 | `19bf7ba6` |
| Security review | S6 matrix + test-only identity bypass reviewed by Codex | 2026-05-29 | `19bf7ba6` |
| Ops/SRE | CI canonical profile green; deployment smoke still required | 2026-05-29 | `19bf7ba6` |
| Product / GA owner | pending Nova app-level UAT and release approval | pending | `19bf7ba6` |
