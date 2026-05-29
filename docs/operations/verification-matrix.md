# V1 Production Verification Matrix

> **Purpose.** Operator runbook for the V1 production verification gate.
> The matrix pins the V1 backend surfaces enumerated in the
> "Surface coverage" table below — health/metrics, durable storage,
> sanitizer / parser / detector contracts, and a small set of live-PG
> integrations (D25 cascade, memory_purge_pii, trace-share durability,
> artifact CRUD). Surfaces NOT in the table are explicitly deferred
> with their compensating controls. Do not read this doc as "every V1
> user-facing flow is covered" — read the table.

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

This section lists every surface that the matrix actually pins. `Smoke` = the business-logic surface is exercised via the established in-process fixture pattern (handler / store / tool calls against fixtures, sanitizer functions, parser functions, source-of-truth doc and migration scans); it does NOT include a bound-port HTTP roundtrip — that remains deferred and is covered by the canonical CI lane + the runbook above.

| # | Surface | Status | Test file | Failure mode pin |
|---|---|---|---|---|
| 1 | S5 chartable metrics catalog (18 counters + 6 histograms declared at `src/gateway.zig:7290-7337`) | Smoke | `tests/verification/health_metrics_test.zig` | catalog drift between gateway HELP/TYPE block and Registry round-trip — fails with the exact missing series name |
| 2 | Registry cardinality cap exposure (H1 from S5 follow-up #113) | Smoke | `tests/verification/health_metrics_test.zig` | `nullalis_metrics_registry_dropped_series_total` not emitted on empty registry |
| 3 | Histogram bucket distribution at canonical BUCKETS_MS boundaries | Smoke | `tests/verification/health_metrics_test.zig` | bucket boundary refactor that breaks Grafana panel queries |
| 4 | Postgres URL resolver contract (canonical + legacy fallback; OOM / WTF-8 errors propagate) | Smoke | `tests/verification/harness.zig` | overbroad catch silently swallowing real env-read failures |
| 5 | Chat-stream SSE event-name surface (chunk/done/message/turn) + phantom-route absence | Smoke | `tests/verification/chat_stream_test.zig` | rename in source that drops a documented event name → UI binding silently breaks |
| 6 | Mode switching — canonical mode route + 4xx failure surface documented | Smoke | `tests/verification/mode_switch_test.zig` | OpenAPI section reshape that loses the `/mode:` path or the 400 response |
| 7 | Session cancel — canonical session-scoped route + idle response shape (`was_active`) + `/api/v1/chat/cancel` absent + Idempotency-Key contract | Smoke | `tests/verification/session_cancel_test.zig` | phantom top-level route appears, or Idempotency-Key parser regresses |
| 8 | Approvals — canonical approve route + stable `apr-{u64}` format + 409 stale-card response + `/api/v1/chat/approve` absent + Idempotency-Key contract | Smoke | `tests/verification/approvals_test.zig` | approval_id format drift; 409 disappears from the OpenAPI |
| 9 | Attachments — route documented + Idempotency-Key parser (happy / missing → null / empty) + 4xx failure surface | Smoke | `tests/verification/attachments_test.zig` | parser breaks → dedupe lane silently broken |
| 10 | Artifacts — route documented + `sanitizer.isPublicField` whitelist + `renderPublicShareJson` no-leak + JSON escape + every ArtifactKind serializes | Smoke | `tests/verification/artifacts_test.zig` | sanitizer accidentally widened to leak `user_id` / `session_id` / `metadata` |
| 11 | Trace sharing — public-share route documented + migration declares user_id CASCADE + share_code PK + JSON snapshot column + sanitizer keep-list (redundant pin) | Smoke | `tests/verification/trace_share_test.zig` | durable migration loses CASCADE FK; sanitizer widens |
| 12 | Extension browser — WS endpoint + diagnostics route + per-user token contract + every shipped `extension_*` tool documented + `url_sanitize.sanitize` SSRF defense + benign URL not over-rejected | Smoke | `tests/verification/extension_browser_test.zig` | SSRF gate regresses (lets through loopback / link-local); benign URL rejected (overbroad) |
| 13 | Memory tools — PII detector fires on phone + email + V1-scope-respecting (no address/name) + `Flags.any()` / `Flags.count()` contract + every shipped memory_* tool documented incl. `memory_purge_pii` | Smoke | `tests/verification/memory_tools_test.zig` | detector starts firing on address/name without scope review; doc gap |
| 14 | Postgres GDPR D25 cascade — 0001 migration has ≥17 user_id CASCADE FKs; artifacts + trace_shares each declare CASCADE; no user_id FK declares `SET NULL` or `NO ACTION` | Smoke | `tests/verification/gdpr_cascade_test.zig` | a new user-scoped table added without CASCADE on user_id |
| 15 | Static schema invariants (D33-equivalent) — every V1-critical table present + `migrations.MIGRATIONS` monotonically versioned starting at 1 + every migration carries non-empty SQL + critical indexes present + unique names | Smoke | `tests/verification/schema_static_test.zig` | dropped table, duplicate migration name, non-monotonic version |
| 16 | Observability — `MAX_SERIES = 4096` invariant + cold-path cardinality shedding + warm-path increments survive past cap + HELP/TYPE block on empty render | Smoke | `tests/verification/observability_test.zig` | cap shedding regresses; warm series accidentally bucketed as cold; HELP block dropped |
| 17 | Startup fail-loud — `gateway.isFatalStartupError` recognizes `ProductionPostgresRequired` + rejects unrelated transient errors | Smoke | `tests/verification/startup_fail_loud_test.zig` | a new `StartupSelfCheckError` variant added but daemon's fail-loud predicate not updated |
| 18 | Composio gated lane — `ComposioConfig` struct shape pinned at compile time + capability namespace wired + env-gated skip-graceful + production-name guard rejects unsafe test entity | Smoke (env-gated) | `tests/verification/composio_gated_test.zig` | struct field rename; env-set path mutates production data |

A surface migrates onto this table the same commit that lands its real assertions. There is intentionally no "Pending" row — every pending surface is closed before the matrix doc lists it.

## What is NOT covered by the matrix (deferred — see runbook above for shape)

| Not covered | Reason | Compensating control |
|---|---|---|
| Bound-port HTTP roundtrip harness | Codebase has no bound-port test harness; `GatewayState` has heavy init dependencies. Building one is a separate sprint. | Canonical-profile CI job boots the binary; runbook curl steps. |
| Live SSE-over-TCP roundtrip | Same. The SSE event-name surface is pinned via contract-doc scan. | Operator manual runbook. |
| Real Chrome extension binary | Mock hub is the contract pin (`tests/extension/mock_hub_e2e_test.zig`). | Operator manual runbook. |
| Address / name PII detection | V1 scope is phone + email only. | Documented as hidden V1 surface; matrix actively asserts the negative. |
| US-local 7–9 digit phones (no `+`, no area code) | Same V1 detector scope. | Documented hidden surface. |
| At-rest encryption of `pii_tagged` rows (D52 Pillar 5) | V1 ships PII *tagging* + *purge* (Pillars 2+4 from #108); encryption-at-rest is V2. | Documented hidden surface. |
| Subprocess-level startup fail-loud (exit-code check on the booted binary) | The Zig test pins the membership invariant (`isFatalStartupError` covers every variant via comptime iteration). Spawning the binary in a subprocess is operator-driven. | Documented in runbook §"Failure triage". |
| Some cascade tables have no direct runtime readback assertion | `messages`, `completion_events`, `memory_events`, `tasks`, `job_runs`, `telegram_updates`, `channel_identity_bindings`, and `tenant_user_leases` have no public seed/readback helper on `zaki_state.Manager`; `user_config`, `heartbeat`, `channel_state`, and `onboarding` are provisioned as default rows but are not separately read back after delete in the D25 live test. | Static line-scan pins the CASCADE declaration on every `user_id` FK. The live D25 test separately asserts post-delete absence for the publicly seedable/readable path: `sessions`, `memories`, `working_memory`, `user_secrets`, `secret_mutations`, `jobs`, `artifacts` (+ `artifact_versions` transitively), and `trace_shares`. |
| Subset execution of static contract scans on a non-PG build | `tests/verification/root.zig` carries a `comptime @compileError` when `-Dengines=...,postgres` is absent — by spec. The matrix IS the live-PG lane; static-only subset execution is a separate-lane concern. | Tests that ONLY need the static scans (chat_stream, mode_switch, schema_static, observability, etc.) can be run individually via `zig test tests/verification/<name>_test.zig` outside the build system if a future contributor needs static-only feedback. |

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
| Trace shares | **Durable** — Postgres `trace_shares` table (S3 / #110). The matrix pins the migration shape (FK CASCADE + JSON snapshot column + PK on `share_code`) statically AND verifies durability at runtime: `tests/verification/trace_share_test.zig` "S6.8 trace share live: share survives Manager-deinit-and-reopen" mints a share via Manager A, closes A, re-init's Manager B against the same schema, and asserts `getTraceByShareCode` returns the byte-exact row. A sibling test pins cascade-on-user-delete. |
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

## Cross-references

- Plan: `docs/superpowers/plans/2026-05-29-s6-verification-matrix.md`
- SLO catalog: `docs/operations/SLOs.md`
- Phantom-route contract: `docs/openapi-v1.yaml` (the existing `paths:` block documents that `/api/v1/chat/{cancel,resume,approve}` do not exist).
- V1 readiness report: `docs/operations/v1-readiness-report.md` (template until S1–S6 are all on main).
