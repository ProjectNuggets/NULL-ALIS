-- Durable outbox for subagent completions (Subagent Pass Phase 1).
-- Mirrors the pending_approvals durability pattern: schema-per-tenant, user_id FK,
-- status ledger, idempotent on (user_id, task_id). A row is written BEFORE the parent
-- is woken; status flips pending -> delivered once the parent has been notified, so a
-- crash between persist and deliver is recovered by re-delivering 'pending' rows.
CREATE TABLE IF NOT EXISTS {schema}.subagent_results (
    result_id    TEXT PRIMARY KEY,           -- formatted "subagent:<task_id>"
    user_id      BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    session_key  TEXT NOT NULL,              -- parent session to wake/deliver to
    task_id      BIGINT NOT NULL,            -- numeric subagent task id
    status       TEXT NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'delivered')),
    result_json  TEXT NOT NULL,              -- serialized SubagentResult (Phase 2); {status,text} in Phase 1
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    delivered_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_subagent_results_idem
    ON {schema}.subagent_results (user_id, task_id);

CREATE INDEX IF NOT EXISTS idx_subagent_results_recover
    ON {schema}.subagent_results (session_key)
    WHERE status = 'pending';
