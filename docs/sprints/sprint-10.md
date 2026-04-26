# Sprint 10 — Data Durability Full — CLOSED 4/6 in-repo (2026-04-26)

**Branch:** `sprint/s10-data-durability` (off `main` tip `bd6248b`)
**Opened:** 2026-04-26
**In-repo CLOSED:** 2026-04-26 — 4 items shipped (S10.1, S10.2, S10.3, S10.4); 2 items (S10.5, S10.6) are operator-pending, documented below.

## Goal

Schema change is a process; data is recoverable. Replace the boot-time `for (statements) |s| exec(s)` pattern that relied on `IF NOT EXISTS` + `canIgnoreMigrateError` allowlist tolerance with a real versioned migrations framework.

## In-repo items shipped

| ID | SHA | Item | Notes |
|---|---|---|---|
| **S10.1** | `960a2ab` | Real migration framework | New `src/migrations.zig` with `Migration` struct, `MIGRATIONS` array, `RunnerContext` vtable (backend-agnostic), `run` / `runWith` entry points, `applyTransactional` / `applyConcurrent` paths, and 4 unit tests using a TestRunner mock. |
| **S10.2** | `50ff5ed` | Initial schema content + tracker bootstrap | Extracted ~280 LoC of DDL into `src/migrations/0001_initial_schema.sql`, idempotency-guarded with `DO $$` blocks for non-idempotent ALTERs. `src/zaki_state.zig::migrate` now appends `CREATE schema_migrations` + `INSERT version 1 ON CONFLICT DO NOTHING` after the legacy loop — bootstraps the framework's tracker without changing the active migration path. |
| **S10.3** | `c49bf14` | CONCURRENTLY policy doc | `docs/migrations-policy.md` — when to add a migration, file naming, idempotency rule (0001 idempotent for legacy compat; 0002+ true diffs), CREATE INDEX CONCURRENTLY default + framework's `concurrent_only` flag, cross-schema FK contract, transactional safety semantics. |
| **S10.4** | `c49bf14` | Cross-schema FK contract test | Static test in `src/migrations.zig` inspects embedded 0001 SQL: asserts `users_user_id_fkey` present, `REFERENCES public.zaki_users(id)` cross-schema target, `ON DELETE CASCADE` semantics (load-bearing for GDPR purgeUser cascade per S7.5), and idempotent `DO $$` wrapping. Runs in CI without live pg. |

## Operator-pending items (deferred from in-repo close)

These require cloud / DigitalOcean operations and are tracked separately for execution by Nova:

| ID | Shape | Where | When |
|---|---|---|---|
| **S10.5** | NFS droplet — DigitalOcean volume snapshot schedule (daily minimum) | zaki-infra repo, `terraform/nfs.tf` | Whenever the next zaki-infra PR window opens |
| **S10.6** | DO-managed Postgres — document backup retention + PITR window + run restore drill quarterly + log date | zaki-infra docs + operator runbook | Quarterly cadence; first drill before public launch |

## Deferred-register implications

- D33 (live-pg cascade integration test) remains open — complements S10.4's static test with runtime FK assertion against seeded data. Pairs with D25 (full GDPR purgeUser live-pg E2E).
- The legacy `canIgnoreMigrateError` allowlist at `src/zaki_state.zig:3181` stays in place during the framework's transition period. Future S10.X commit (post prod-verify of 0001 idempotency) will:
  1. Replace the legacy `for (statements)` loop body in `migrate()` with a call to `migrations.run(...)` via a vtable that wraps Manager.Self
  2. Remove the `canIgnoreMigrateError` allowlist
  3. Migration 0002+ ships as true diffs through the framework

## Tests + verification

- All 4 in-repo items have unit/contract test coverage
- `zig build test` green throughout (5500+, +5 new tests across S10.1 + S10.4)
- Production behavior unchanged — same DDL fires on every boot, just with `schema_migrations` row added on first

## Why this matters

The old pattern silently swallowed migration errors via the canIgnoreMigrateError allowlist. A bad migration would either:
- Re-run forever (idempotent statements) — wasted work on every boot
- Silently fail (non-idempotent statements not in the allowlist) — schema drifts, manifests later as runtime errors

The framework guarantees:
- Each migration runs exactly once per database
- Failures roll back cleanly (transaction wrap)
- Future migrations can rely on "if I'm in MIGRATIONS, my predecessor ran" — enables true diffs without idempotency overhead
- Version tracking means operators can answer "what migrations has this DB seen?" via a single SELECT

## Sprint 10 DoD

- [x] Migration framework module exists with tests
- [x] Initial schema content extracted to .sql file
- [x] Schema_migrations tracker table bootstrapped on every boot
- [x] CONCURRENTLY policy documented
- [x] Cross-schema FK contract test in CI
- [ ] DO NFS snapshots (S10.5 — operator-pending)
- [ ] DO Postgres backup retention + PITR + restore drill (S10.6 — operator-pending)
