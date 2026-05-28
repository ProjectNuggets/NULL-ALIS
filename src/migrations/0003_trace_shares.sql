-- Migration 0003 — durable trace shares (prod-readiness Sprint 3, 2026-05-28)
--
-- Closes the `ui-handoff.md` §7 P1 item: trace SHARE records survive
-- gateway restart. Trace EVENTS themselves stay in the in-process
-- bounded RunTraceStore (src/run_trace_store.zig) — this migration
-- captures a SNAPSHOT of the sanitized events at share-create time
-- in `events_json`, so a public share link resolves to the exact
-- bytes the server returned when the user clicked "Share".
--
-- Why a snapshot, not a live join: trace events are ephemeral (FIFO
-- ring buffer, 64 runs × 256 events). A persistent share index that
-- referenced live events would silently break the moment a run got
-- evicted. The snapshot semantic matches "here's what happened in
-- run X" — moment-in-time, not live feed.
--
-- The shape mirrors `artifacts.share_code`/`share_expires_at_unix`
-- (migration 0002) but lives in its own table because:
--   * the snapshot blob can be large (256 events × a few hundred bytes)
--   * trace shares have no "current_version"/"artifact_versions"
--     companion — they're standalone snapshots
--   * D64's share-spam cap (100 live shares per user, gateway.zig)
--     is now enforced via a state_mgr countLiveTraceSharesForUser
--     query against this table

CREATE TABLE IF NOT EXISTS {schema}.trace_shares (
    -- 16-char opaque code from the SHARE_CODE_ALPHABET set
    -- (gateway.zig). Unique across all users; lookup is the
    -- primary access pattern.
    share_code      TEXT PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    -- run_id is opaque to the DB — matches the in-process run_id used
    -- by RunTraceStore. NOT a foreign key (run_ids are ephemeral).
    run_id          TEXT NOT NULL,
    -- Sanitized snapshot. JSON document matching the response shape of
    -- `GET /api/v1/share/:share_code` — `{user_id, session_id, run_id,
    -- first_event_ms, last_event_ms, truncated, events:[...]}`.
    -- Sanitization rules baked in at share-create time; future rule
    -- changes do NOT retroactively apply to existing shares (deliberate
    -- — old shares stay readable).
    --
    -- **Column type chosen for byte preservation.** `JSON` (not
    -- `JSONB`) is used here on purpose: PostgreSQL `JSON` validates
    -- structure on insert but stores the original text verbatim,
    -- whereas `JSONB` normalizes (sorts keys, strips insignificant
    -- whitespace). The public-share contract promises the snapshot
    -- bytes returned by the public GET match the bytes the gateway
    -- emitted at share-create time — a byte-exact assertion that
    -- `JSONB` would silently break (key reordering would surface as
    -- a test failure on the CI Canonical Profile run). `JSON` also
    -- keeps the validation safety net: malformed payloads are
    -- rejected at INSERT time rather than corrupting the share index.
    events_json     JSON NOT NULL,
    created_at_unix BIGINT NOT NULL,
    expires_at_unix BIGINT NOT NULL,
    -- Revoke is soft-delete to preserve audit. `getTraceByShareCode`
    -- filters `NOT revoked AND expires_at_unix > now`. The unique-
    -- per-(user,run) partial index below allows a fresh share after a
    -- revoke without violating uniqueness.
    revoked         BOOLEAN NOT NULL DEFAULT FALSE
);

-- Listing live shares for a user (D64 cap enforcement + admin).
-- Partial index — revoked rows are audit-only, never iterated.
CREATE INDEX IF NOT EXISTS idx_trace_shares_user_live
    ON {schema}.trace_shares (user_id)
    WHERE NOT revoked;

-- Expired-sweep helper (future operator CLI).
CREATE INDEX IF NOT EXISTS idx_trace_shares_expires
    ON {schema}.trace_shares (expires_at_unix)
    WHERE NOT revoked;

-- One live share per (user, run). Revoke flips `revoked = true`, which
-- drops the row out of the partial index — a fresh share for the same
-- run is then allowed. This matches the artifacts.share_code semantics
-- where a single artifact can only have one active share at a time.
CREATE UNIQUE INDEX IF NOT EXISTS idx_trace_shares_live_per_run
    ON {schema}.trace_shares (user_id, run_id)
    WHERE NOT revoked;
