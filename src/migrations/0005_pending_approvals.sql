-- Migration 0005 — durable, resumable, idempotent tool approvals (P0-4,
-- 2026-06-12, Wave A agent-runtime resilience).
--
-- Closes the "approval lost on restart/eviction" hole. Before this, a
-- pending tool approval lived ONLY in RAM (`Agent.pending_tool_approval`,
-- `src/agent/root.zig`). On a pod restart / session eviction the snapshot
-- was lost, so the user's Approve click 404'd and the turn could never
-- resume. The conversation HISTORY is already durable in
-- `{schema}.messages`, so the ONLY missing piece is the approval SNAPSHOT
-- — exactly what this table persists.
--
-- Resume model (unchanged): on Approve we execute the approved tool and
-- start a FRESH continuation turn (NOT a multi-call turn replay), so only
-- the snapshot must survive a restart.
--
-- FK-safety: the parent `{schema}.users(user_id)` row is guaranteed to
-- exist before any approval write because the persist path funnels through
-- the P0-6 `ensureUserRow` chokepoint (which itself self-heals the row and
-- gates a bogus id on the `public.zaki_users` identity probe). So this FK
-- can never fault for a legitimately-resolvable user.
--
-- No expiry column / no time-to-live — by design. An approval persists until
-- the user resolves it (approve|deny). There is no countdown and no sweep.
--
-- Idempotency: `status` is the durable ledger. A repeat approve/deny for an
-- already-resolved `approval_id` reads the row, sees a terminal status, and
-- replays the original outcome (HTTP 200) instead of 409-ing — the
-- gateway/commands layer keys idempotent replay off this column +
-- `resolved_at`.

CREATE TABLE IF NOT EXISTS {schema}.pending_approvals (
    -- Stable wire id the FE pins a card to. Format `apr-<u64>` (minted by
    -- the agent's per-session counter). PRIMARY KEY so a re-issue of the
    -- same id is impossible and idempotent replay is a single-row lookup.
    approval_id    TEXT PRIMARY KEY,
    -- The session this approval belongs to (e.g.
    -- `agent:zaki-bot:user:42:thread:main`). Rehydration loads the open
    -- row for the session on session (re)build.
    session_key    TEXT NOT NULL,
    -- FK to the parent users row. ON DELETE CASCADE so a GDPR purge of the
    -- user removes their approvals too. The write path calls ensureUserRow
    -- first, so this can never fault for a resolvable user.
    user_id        BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    tool_name      TEXT NOT NULL,
    -- Provider tool_call_id (nullable — some calls have none).
    tool_call_id   TEXT,
    -- The exact arguments the user is approving. Replayed verbatim into the
    -- rebuilt ParsedToolCall so the executed call is byte-identical to what
    -- was approved.
    arguments_json TEXT NOT NULL,
    reason         TEXT NOT NULL,
    -- RiskLevel slice ("low" | "medium" | "high" | ...). Stored as text so
    -- the rehydrated card renders the same badge.
    risk_level     TEXT NOT NULL,
    -- Lifecycle status. 'pending' is the only OPEN state; 'approved' and
    -- 'denied' are terminal and drive idempotent replay.
    status         TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending', 'approved', 'denied')),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- NULL while pending; set to NOW() on resolve.
    resolved_at    TIMESTAMPTZ,
    -- Who resolved it (e.g. "user", "gateway"). NULL while pending.
    resolved_by    TEXT
);

-- Rehydration lookup: find THE open approval for a session cheaply. Partial
-- index — resolved rows drop out, so the (very common) "is there an open
-- approval for this session?" probe on session (re)build scans only the
-- pending backlog. v1 invariant is at most one pending per session.
CREATE INDEX IF NOT EXISTS idx_pending_approvals_open
    ON {schema}.pending_approvals (session_key)
    WHERE status = 'pending';

-- Per-user history / GDPR scoping.
CREATE INDEX IF NOT EXISTS idx_pending_approvals_user
    ON {schema}.pending_approvals (user_id, created_at);
