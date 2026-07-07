-- Loop-2 substrate (three-loops spec §3.1): durable per-run tool-trace
-- digests. One row per completed run; events carried as a JSONB array
-- (kind, tool, success, duration_ms, error-ish fields — the observer's
-- sanitized view). Written best-effort on agent_end; readable by the
-- background-review miner. Retention: pruned by ops policy (not here).
CREATE TABLE IF NOT EXISTS {schema}.tool_traces (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    run_id TEXT NOT NULL,
    events JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Idempotency: one digest per run.
CREATE UNIQUE INDEX IF NOT EXISTS tool_traces_run_uniq
    ON {schema}.tool_traces (user_id, run_id);

-- Miner access path: recent traces per user.
CREATE INDEX IF NOT EXISTS tool_traces_user_recent
    ON {schema}.tool_traces (user_id, created_at DESC);
