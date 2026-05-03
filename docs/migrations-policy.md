---
tags: [prose, prose/docs]
---

# Migrations Policy

**S10.3** — written guidance for the `src/migrations.zig` framework.

## When to add a new migration

Any change to `{schema}.*` table structure: add column, add index, add constraint, change type, drop column, etc. Every such change goes in a new numbered migration file under `src/migrations/`, and the entry is appended to `MIGRATIONS` in `src/migrations.zig`.

## File naming

`{NNNN}_{descriptive_name}.sql` — zero-padded 4-digit version. Names should describe the change (`0002_add_user_locale`, `0003_drop_legacy_chat_table`) not the date.

## Idempotency

- **Migration 0001** (initial schema) is idempotent because it runs against pre-existing prod databases where the schema already exists from the legacy `migrate()` loop. Uses `CREATE IF NOT EXISTS`, `IF NOT EXISTS`, and `DO $$ ... END$$` blocks for ALTER guards.
- **Migrations 0002+** MUST be true diffs. The framework guarantees they're never re-run after first success, so non-idempotent statements are correct and preferred (they're explicit about intent).

## CREATE INDEX CONCURRENTLY

**Default rule:** new indexes use `CREATE INDEX CONCURRENTLY`. Postgres allows reads/writes to the table during index build, avoiding the heavy lock that plain `CREATE INDEX` takes.

**Tradeoff:** `CREATE INDEX CONCURRENTLY` cannot run inside a transaction (Postgres restriction). The migration framework handles this via the `concurrent_only: bool = true` flag on the `Migration` entry:

```zig
.{
    .version = 5,
    .name = "0005_add_messages_chat_id_index",
    .sql = @embedFile("migrations/0005_add_messages_chat_id_index.sql"),
    .concurrent_only = true,
},
```

When `concurrent_only` is true:
- The runner skips the BEGIN/COMMIT wrapper around the migration body
- Statements execute one-at-a-time, split on `;`
- The `schema_migrations` row insert happens in a separate transaction after all statements succeed

**Implication:** if a `concurrent_only` migration fails partway, partial state may persist (some indexes created, others not). Recovery is to fix the failing statement, drop the partially-created indexes manually if needed, and re-run. The version row is NOT inserted on partial failure, so the runner will retry on next boot.

## Cross-schema FKs

Cross-schema references (e.g. `{schema}.users.user_id REFERENCES public.zaki_users(id)`) are sensitive — the public schema is owned by zaki-prod (Rails); the per-tenant schema is owned by nullalis. The FK exists for cascade-on-delete semantics (when a user is deleted in zaki-prod, all nullalis state is cascade-deleted via `ON DELETE CASCADE`).

**Contract:** any future migration touching this FK or adding new cross-schema FKs must update the contract test in `src/migrations/test_initial_schema_fk.zig` (S10.4). The test is static (greps the .sql file) so it's fast + runs in CI without a live database.

## Transactional safety

By default migrations run inside `BEGIN/COMMIT`. A failure inside the migration body triggers `ROLLBACK` and the version row is NOT inserted, so the runner will retry on next boot. This is the safe default — use `concurrent_only` only when you genuinely need CONCURRENTLY.

## Operator-only items deferred

The following Sprint 10 items require cloud / operator action and are documented in `docs/sprints/sprint-10.md` as operator-pending:

- **S10.5** NFS droplet — DigitalOcean volume snapshot schedule (daily minimum) in `terraform/nfs.tf` (zaki-infra repo)
- **S10.6** DO-managed Postgres — backup retention + PITR window + restore drill (quarterly, log date)
