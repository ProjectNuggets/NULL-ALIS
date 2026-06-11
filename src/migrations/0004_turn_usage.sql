-- Migration 0004 — durable per-turn usage ledger (nullALIS metering completeness, Wave 2)
--
-- Closes the metering hole where cron / heartbeat / channel agent turns
-- (which run the SAME agent loop as HTTP turns, but with `usage_rt = null`)
-- recorded NOTHING: no done-frame, no wallet signal. Real model cost was
-- consumed and lost to accounting. HTTP turns ARE settled live via the SSE
-- done-frame, so this table is the reconciliation surface for the OTHER turn
-- origins — the BFF sweeps unreconciled `entry_kind = 'daemon'` rows into the
-- wallet, and `entry_kind = 'http'` rows exist for audit/cross-check only
-- (already settled live → the sweep MUST NOT double-debit them).
--
-- Written on EVERY turn completion (http + daemon) from the agent loop,
-- INDEPENDENT of `usage_rt` — so the rows exist regardless of whether the
-- in-memory usage runtime is wired for that session.
--
-- Idempotency: `UNIQUE (user_id, turn_key)` + `ON CONFLICT DO NOTHING` so a
-- turn that retries (or a duplicated write) never inserts twice. `turn_key`
-- is the per-turn run_id minted by the agent (`agent/root.zig` — `r-<ms>-<n>`),
-- deterministic + unique within a session.

CREATE TABLE IF NOT EXISTS {schema}.turn_usage (
    user_id          BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    session_key      TEXT NOT NULL,
    -- Deterministic per-turn id (the agent's run_id). UNIQUE per user for
    -- idempotency — see idx_turn_usage_idem below.
    turn_key         TEXT NOT NULL,
    -- 'http'   — gateway path; already settled live via the SSE done frame.
    -- 'daemon' — cron / heartbeat / channel path; reconcilable by the BFF.
    entry_kind       TEXT NOT NULL,
    -- The TurnOrigin enum value: user|heartbeat|scheduler|wake|proactive|mcp.
    turn_origin      TEXT NOT NULL,
    model            TEXT,
    input_tokens     BIGINT NOT NULL DEFAULT 0,
    output_tokens    BIGINT NOT NULL DEFAULT 0,
    cost_usd         DOUBLE PRECISION NOT NULL DEFAULT 0,
    -- Mirrors the done-frame `cost_priced` gate: false when the pricing table
    -- returned no price for the model, so the BFF settles tokens (not a bogus
    -- $0) for an unpriced-but-billable turn.
    cost_available   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- NULL until the BFF reconciliation sweep claims the row.
    reconciled_at    TIMESTAMPTZ
);

-- Idempotency key. A retried turn (same run_id) is a no-op insert.
CREATE UNIQUE INDEX IF NOT EXISTS idx_turn_usage_idem
    ON {schema}.turn_usage (user_id, turn_key);

-- The BFF reconciliation sweep: find unreconciled daemon rows cheaply.
-- Partial index — reconciled rows drop out, so the sweep scans only the
-- backlog. `entry_kind` is leading so the sweep can target 'daemon' directly.
CREATE INDEX IF NOT EXISTS idx_turn_usage_sweep
    ON {schema}.turn_usage (entry_kind, reconciled_at)
    WHERE reconciled_at IS NULL;

-- Per-user history (admin / audit / /cost cross-check).
CREATE INDEX IF NOT EXISTS idx_turn_usage_user_created
    ON {schema}.turn_usage (user_id, created_at);
