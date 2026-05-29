# V1 Production Verification Matrix

> **Purpose.** A fresh checkout must be able to verify every V1 user-facing
> backend flow with two commands. This document is the operator-facing
> runbook for that verification + the source-of-truth for which surfaces
> are pinned, which are smoke-only, and which are explicitly deferred.

## TL;DR — two commands

```bash
# 1. Default baseline. No live fixture required. Runs on every PR.
zig build test -Dengines=base,sqlite,postgres --summary all

# 2. V1 production verification matrix. Requires a live Postgres URL for
#    the live-PG lane; absent fixture → tests skip cleanly (not failure).
NULLALIS_POSTGRES_TEST_URL=postgresql://zaki:zaki@localhost:5432/zaki \
  zig build test-postgres -Dengines=base,sqlite,postgres --summary all
```

Expected on a clean main + this branch:
- Command 1 → `Build Summary: <N>/<N> steps succeeded; <K> tests passed; <S> skipped` (the `test` step is **intentionally unchanged** by S6 — the matrix is additive).
- Command 2 → `Build Summary: <M>/<M> steps succeeded; <V> tests passed` (where V grows as the per-surface tasks fill in the placeholders).

## Required env vars

| Variable | Required for | Notes |
|---|---|---|
| `NULLALIS_POSTGRES_TEST_URL` | live-PG verification lane | Canonical name (since 2026-05-29). Tests skip-graceful when unset. |
| `NULLCLAW_POSTGRES_TEST_URL` | (legacy fallback only) | Resolved via `env_rebrand.getEnvOwnedWithRebrand` — banner + per-key warning fire when used. Slated for sunset; keep working through V1. |
| `COMPOSIO_API_KEY` | optional Composio gated lane | Without it, `composio_gated_test.zig` returns `error.SkipZigTest`. |
| `NULLALIS_COMPOSIO_TEST_ENTITY` | optional Composio gated lane | Must be a non-production entity name; the test rejects any containing `prod` / `main`. |

## Per-PR vs per-release

| Cadence | Command | What gates merging |
|---|---|---|
| Per-PR (CI) | `zig build test` on ubuntu-latest + macos-latest matrix | Default suite must be green. |
| Per-PR (CI, canonical lane) | `zig build test --summary all -Dengines=base,sqlite,postgres -Dchannels=cli,telegram` against pgvector service | Live-PG postgres-gated suite must be green. |
| Per-PR (CI, S6 matrix) | `zig build test-postgres --summary all -Dengines=base,sqlite,postgres -Dchannels=cli,telegram` against pgvector service | V1 verification matrix must be green. |
| Per-release | All of the above + manual runbook below | Plus the v1-readiness-report sign-off (see `docs/operations/v1-readiness-report.md`). |

## Local runbook

```bash
# 1. Start a fresh Postgres with the canonical pgvector image (matches CI).
docker run --rm -d --name nullalis-s6 -p 5432:5432 \
  -e POSTGRES_USER=zaki -e POSTGRES_PASSWORD=zaki -e POSTGRES_DB=zaki \
  pgvector/pgvector:pg16
sleep 5  # wait for readiness

# 2. Run the matrix.
NULLALIS_POSTGRES_TEST_URL=postgresql://zaki:zaki@localhost:5432/zaki \
  zig build test-postgres -Dengines=base,sqlite,postgres --summary all

# 3. Tear down.
docker rm -f nullalis-s6
```

Expected: `Build Summary: <M>/<M> steps succeeded; <V> tests passed`. No `failed` line. PG-gated tests that lack live-fixture support print SKIPPED — that is the established suite-wide convention, not a verification gap.

## CI runbook

The matrix runs as a dedicated step in the `canonical-production-profile` job in `.github/workflows/ci.yml`. It re-uses the `pgvector/pgvector:pg16` service container declared on that job, so the verification lane and the default canonical lane share one Postgres for the whole job.

A failed `V1 production verification matrix` step is a hard merge block. A failed `Run tests (canonical production engines)` step is also a hard block — both must be green.

## Surface coverage

This section lists ONLY surfaces that the matrix actually pins. `Smoke` = the business-logic surface is exercised via the established in-process fixture pattern (handler / store / tool calls against fixtures); it does NOT include a bound-port HTTP roundtrip. The table is the operator's authoritative coverage answer — surfaces planned but not yet pinned live in the **Coverage roadmap** subsection below so the table never makes a promise the code does not keep.

| Surface | Status | Test file | Failure mode pin |
|---|---|---|---|
| S5 chartable metrics catalog (the 18 counters + 6 histograms declared at `src/gateway.zig:7290-7337`) | Smoke | `tests/verification/health_metrics_test.zig` | catalog drift between gateway HELP/TYPE block and Registry round-trip — fails with the exact missing series name printed by the test runner |
| Registry cardinality cap exposure (H1 from S5 follow-up #113) | Smoke | `tests/verification/health_metrics_test.zig` | `nullalis_metrics_registry_dropped_series_total` not emitted on empty registry |
| Histogram bucket distribution at the canonical BUCKETS_MS boundaries | Smoke | `tests/verification/health_metrics_test.zig` | bucket boundary refactor that breaks Grafana panel queries |
| Postgres URL resolver contract (canonical + legacy fallback) | Smoke | `tests/verification/harness.zig` | overbroad catch silently swallowing a real env-read failure |

### Coverage roadmap

The following surfaces are scheduled by the plan at [`docs/superpowers/plans/2026-05-29-s6-verification-matrix.md`](../superpowers/plans/2026-05-29-s6-verification-matrix.md) but are NOT yet pinned in CI. They are tracked here only so the runbook reader can locate which plan task will close each gap; do not treat them as covered.

- Chat-stream SSE event-name surface + phantom-route absence — plan Task 2
- Mode switching valid/invalid + persistence — plan Task 2
- Session cancel idle/active/idempotent — plan Task 2
- Approvals — stable `apr-{u64}` id, 409 stale-card, approve/deny/expiry, idempotency, cross-session, irreversible gating — plan Task 3
- Attachments — upload + Idempotency-Key dedupe + invalid + cross-user — plan Task 3
- Artifacts — CRUD, share/revoke, export, unsafe-filename, cross-user — plan Task 4
- Trace sharing — create/get/revoke + sanitizer whitelist + restart-equivalent durability + cross-user list — plan Task 4
- Extension browser — every shipped `extension_*` command via mock hub (partial coverage today in `tests/extension/mock_hub_e2e_test.zig`) — plan Task 5
- Memory tools — store/recall/forget/doctor + `memory_purge_pii` dry+wet + user isolation — plan Task 5
- Postgres GDPR D25 cascade across the 19 FK tables — plan Task 6
- Static schema invariants (D33-equivalent) — plan Task 6
- Full observability counter + histogram movement after representative flows — plan Task 7
- Startup fail-loud — production-mode + missing PG → non-zero exit — plan Task 7
- Composio gated lane — plan Task 8

A surface migrates from this roadmap to the table above when its `tests/verification/*_test.zig` file lands real content + the matrix-doc row is added in the same commit.

## Failure triage

If `test-postgres` fails on CI, look here first:

| Failing assertion | First file to read | Common root cause |
|---|---|---|
| `MissingMetricSeries` in `health_metrics_test.zig` | `src/observability_metrics.zig` `metricsPayload()` + emit sites | Counter renamed or never emitted (catalog drift); fix the catalog or restore the emit. |
| `CounterMovementBroken` | `src/observability_metrics.zig:139` (`incCounter`) | First-sample atomicity broken (the F6 fix in #113). |
| `D25 leak: <table> still has N rows after user delete` | `src/migrations/` for that table's FK | A new table added without `ON DELETE CASCADE` on `user_id`. |
| Schema-static check fails | latest migration file | Renamed/removed table or constraint. |
| Extension test fails with "no extension connected" path | `src/extension_ws/hub.zig` lifecycle | Hub init or token handoff regression. |

## Restart / pod-loss expectations

| Surface | Durability |
|---|---|
| Sessions, messages, memories, artifacts, artifact_versions, jobs, tasks | **Durable** — Postgres-backed; survives restart. |
| Trace shares | **Durable** — Postgres `trace_shares` table (S3 / #110). Verified by Manager-deinit-and-reopen in `trace_share_test.zig` (pending). |
| Approval pending-card state | **Ephemeral** — in-memory on the agent runtime. Lost on restart; resolution via the canonical `POST /api/v1/users/{uid}/sessions/{key}/approve` route requires the original session to still be running. |
| Extension WS connections | **Ephemeral** — must re-pair after restart. |
| Active turn cancel state | **Ephemeral** — bounded by the in-flight HTTP request. |
| `/metrics` registry | **Ephemeral** — counters reset on restart (this is correct Prometheus semantics; scrape interval handles it). |

## V1 hidden surfaces (do NOT claim)

The following are deliberately hidden from V1 docs and UI claims. The matrix asserts their absence where possible:

- `/api/v1/chat/cancel`, `/api/v1/chat/resume`, `/api/v1/chat/approve` as top-level chat routes. Use the session-scoped canonical routes only (`/api/v1/users/{uid}/sessions/{key}/{cancel,approve}`; no `resume` route exists). Verified absent by inspection of `docs/openapi-v1.yaml`.
- Live subagent interruption. Only queued subtasks can be cancelled.
- Bi-temporal `valid_to` contradiction classifier.
- Per-cell isolated pods. Current state is shared-runtime.
- D52 Pillar 5 at-rest encryption of `pii_tagged` rows.
- Address / name PII detection. V1 detection is **phone + email only** (see `src/memory/pii_detect.zig:9-22`).
- 7-9 digit US-local phone numbers without area code or `+` prefix.
- End-user Composio / integration claims unless the gated smoke lane is configured *and* passing on the operator's environment.
- Public `/metrics` — treat as operator-only / firewalled.

## What is NOT covered by S6 (and why)

| Not covered | Why deferred |
|---|---|
| Bound-port HTTP roundtrip harness | The codebase has no bound-port test harness today and `GatewayState` has heavy init dependencies (postgres pool, observer registry, extension hub, agent runtime). Building one is a separate sprint. Coverage is provided by (a) the canonical-production-profile CI job which boots the binary, and (b) the operator runbook above. |
| Live SSE-over-TCP roundtrip | Same. The SSE event-name surface is pinned in `chat_stream_test.zig` against the emitter helpers directly. |
| Real Chrome extension binary | The extension mock hub (`tests/extension/mock_hub_e2e_test.zig`) is the canonical pin for the WS contract. A real-extension lane is operator-driven. |
| Address / name PII detection | V1 scope is phone + email only — too noisy without NER. Documented as hidden above. |
| US-local 7-9 digit phones (no `+`, no area code) | Same V1 detector scope. |
| At-rest encryption of `pii_tagged` rows (D52 Pillar 5) | V1 ships PII *tagging* and *purge* (Pillars 2+4 from #108). Encryption-at-rest is V2. |

## Cross-references

- Plan: `docs/superpowers/plans/2026-05-29-s6-verification-matrix.md`
- SLO catalog: `docs/operations/SLOs.md`
- Phantom-route contract: `docs/openapi-v1.yaml` (the existing `paths:` block documents that `/api/v1/chat/{cancel,resume,approve}` do not exist).
- V1 readiness report: `docs/operations/v1-readiness-report.md` (template until S1–S6 are all on main).
