-- S10.2 — Initial schema (extracted from src/zaki_state.zig::migrate
-- as of commit 960a2ab — pre-S10.2 snapshot of the legacy hardcoded
-- statement loop).
--
-- This migration is **idempotent** — uses CREATE IF NOT EXISTS +
-- IF NOT EXISTS guards on ALTERs — so it's safe to run against
-- pre-existing prod databases where the schema already exists from
-- the legacy migrate() loop. Once confirmed applied across all
-- environments, future migrations (0002+) MUST be true diffs and
-- MUST NOT be idempotent replays.
--
-- The {schema} placeholder is substituted at runtime by
-- Manager.Self.buildQuery — same pattern as the legacy code.

CREATE SCHEMA IF NOT EXISTS {schema};

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS {schema}.users (
    user_id BIGINT PRIMARY KEY,
    workspace_path TEXT NOT NULL,
    agent_name TEXT,
    onboarding_completed BOOLEAN NOT NULL DEFAULT FALSE,
    onboarding_completed_at TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ALTER guarded with DO block for idempotency (S10.2 invariant:
-- migration 0001 must be safely re-runnable).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'users_user_id_fkey'
          AND conrelid = '{schema}.users'::regclass
    ) THEN
        ALTER TABLE {schema}.users ADD CONSTRAINT users_user_id_fkey
            FOREIGN KEY (user_id) REFERENCES public.zaki_users(id) ON DELETE CASCADE;
    END IF;
EXCEPTION WHEN undefined_table THEN
    -- public.zaki_users not yet created in this database (test
    -- fixture / fresh local dev). Skip the FK; runtime queries
    -- still work without it.
    NULL;
WHEN insufficient_privilege THEN
    -- Test environments where current role can't ALTER public schema.
    NULL;
END$$;

CREATE TABLE IF NOT EXISTS {schema}.user_config (
    user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    config JSONB NOT NULL DEFAULT '{}'::jsonb,
    version INT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS {schema}.user_secrets (
    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    ciphertext BYTEA NOT NULL,
    nonce BYTEA NOT NULL,
    aad TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, key)
);

-- D8 (S2.16) — audit trail for every secret mutation.
CREATE TABLE IF NOT EXISTS {schema}.secret_mutations (
    id TEXT PRIMARY KEY DEFAULT encode(gen_random_bytes(16), 'hex'),
    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    action TEXT NOT NULL,
    actor TEXT,
    outcome TEXT NOT NULL,
    detail TEXT,
    at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_secret_mutations_user_at
    ON {schema}.secret_mutations(user_id, at DESC);

CREATE TABLE IF NOT EXISTS {schema}.sessions (
    id TEXT PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    session_key TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL,
    title TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS {schema}.messages (
    id TEXT PRIMARY KEY DEFAULT encode(gen_random_bytes(16), 'hex'),
    session_id TEXT NOT NULL REFERENCES {schema}.sessions(id) ON DELETE CASCADE,
    user_id BIGINT REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    channel TEXT,
    account_id TEXT,
    chat_id TEXT,
    source TEXT NOT NULL DEFAULT 'app',
    content TEXT NOT NULL,
    tool_name TEXT,
    tool_call JSONB,
    tool_result JSONB,
    request_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_messages_user_created
    ON {schema}.messages(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_session_created
    ON {schema}.messages(session_id, created_at ASC);

CREATE TABLE IF NOT EXISTS {schema}.completion_events (
    id TEXT PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    session_id TEXT NOT NULL REFERENCES {schema}.sessions(id) ON DELETE CASCADE,
    channel TEXT,
    account_id TEXT,
    chat_id TEXT,
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_completion_events_user_session_created
    ON {schema}.completion_events(user_id, session_id, created_at ASC, id ASC);

CREATE TABLE IF NOT EXISTS {schema}.memories (
    id TEXT PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    session_id TEXT REFERENCES {schema}.sessions(id) ON DELETE SET NULL,
    key TEXT NOT NULL UNIQUE,
    content TEXT NOT NULL,
    content_hash TEXT,
    memory_type TEXT NOT NULL DEFAULT 'core',
    embedding VECTOR,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    importance_score DOUBLE PRECISION DEFAULT 0.5,
    confidence_score DOUBLE PRECISION DEFAULT 0.8,
    access_count INT DEFAULT 0,
    last_accessed_at TIMESTAMPTZ,
    user_verified BOOLEAN DEFAULT FALSE,
    source_channel TEXT,
    source_message_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_memories_user ON {schema}.memories(user_id);
CREATE INDEX IF NOT EXISTS idx_memories_hash ON {schema}.memories(user_id, content_hash);
ALTER TABLE {schema}.memories DROP CONSTRAINT IF EXISTS memories_key_key;
CREATE UNIQUE INDEX IF NOT EXISTS idx_memories_user_key ON {schema}.memories(user_id, key);

CREATE TABLE IF NOT EXISTS {schema}.memory_events (
    id TEXT PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    memory_id TEXT,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS {schema}.channel_state (
    user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    telegram JSONB NOT NULL DEFAULT '{}'::jsonb,
    app JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS {schema}.telegram_updates (
    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    update_id BIGINT NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, update_id)
);

CREATE TABLE IF NOT EXISTS {schema}.channel_identity_bindings (
    id TEXT PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    channel TEXT NOT NULL,
    account_id TEXT NOT NULL,
    principal_key TEXT NOT NULL,
    scope_key TEXT NOT NULL,
    thread_key TEXT,
    thread_key_norm TEXT NOT NULL DEFAULT '',
    peer_kind TEXT,
    peer_id TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_channel_identity_unique
    ON {schema}.channel_identity_bindings(channel, account_id, principal_key, scope_key, thread_key_norm);
CREATE INDEX IF NOT EXISTS idx_channel_identity_user_channel
    ON {schema}.channel_identity_bindings(user_id, channel);
CREATE INDEX IF NOT EXISTS idx_channel_identity_lookup
    ON {schema}.channel_identity_bindings(channel, account_id, principal_key, scope_key, thread_key_norm);

CREATE TABLE IF NOT EXISTS {schema}.heartbeat (
    user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    config JSONB NOT NULL DEFAULT '{}'::jsonb,
    last_evaluated_at TIMESTAMPTZ,
    last_triggered_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS {schema}.onboarding (
    user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    state JSONB NOT NULL DEFAULT '{"completed":false}'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS {schema}.tenant_user_leases (
    user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    owner_id TEXT NOT NULL,
    lease_token TEXT NOT NULL,
    lease_until TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tenant_user_leases_owner_until
    ON {schema}.tenant_user_leases(owner_id, lease_until DESC);

CREATE TABLE IF NOT EXISTS {schema}.jobs (
    id TEXT PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    session_id TEXT REFERENCES {schema}.sessions(id) ON DELETE SET NULL,
    kind TEXT NOT NULL,
    schedule_type TEXT NOT NULL,
    cron_expr TEXT,
    run_at TIMESTAMPTZ,
    timezone TEXT NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    raw_job JSONB NOT NULL DEFAULT '{}'::jsonb,
    delivery JSONB NOT NULL DEFAULT '{}'::jsonb,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    quiet_hours_policy JSONB NOT NULL DEFAULT '{}'::jsonb,
    retry_budget INT NOT NULL DEFAULT 3,
    retry_count INT NOT NULL DEFAULT 0,
    next_run_at TIMESTAMPTZ,
    last_run_at TIMESTAMPTZ,
    last_status TEXT,
    last_error TEXT,
    lease_owner TEXT,
    lease_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_jobs_due ON {schema}.jobs(enabled, next_run_at);
CREATE INDEX IF NOT EXISTS idx_jobs_user_due ON {schema}.jobs(user_id, next_run_at);

CREATE TABLE IF NOT EXISTS {schema}.job_runs (
    id TEXT PRIMARY KEY,
    job_id TEXT NOT NULL REFERENCES {schema}.jobs(id) ON DELETE CASCADE,
    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at TIMESTAMPTZ,
    status TEXT NOT NULL,
    output TEXT,
    error TEXT,
    trace JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS {schema}.tasks (
    id TEXT NOT NULL,
    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    session_id TEXT REFERENCES {schema}.sessions(id) ON DELETE SET NULL,
    request_session_id TEXT REFERENCES {schema}.sessions(id) ON DELETE SET NULL,
    label TEXT NOT NULL,
    prompt TEXT NOT NULL,
    status TEXT NOT NULL,
    result TEXT,
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    PRIMARY KEY (user_id, id)
);

-- Idempotent guards for legacy schema upgrades. The IF NOT EXISTS
-- column add covers the case where {schema}.tasks pre-exists without
-- request_session_id (older code path). The pkey drop+add is also
-- guarded — DROP IF EXISTS is naturally idempotent.
ALTER TABLE {schema}.tasks
    ADD COLUMN IF NOT EXISTS request_session_id TEXT
    REFERENCES {schema}.sessions(id) ON DELETE SET NULL;

DO $$
BEGIN
    -- Only re-key if the existing pkey is the legacy single-column
    -- (id) shape. The new pkey is (user_id, id). After first apply
    -- this DO block is a no-op.
    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'tasks_pkey'
          AND conrelid = '{schema}.tasks'::regclass
          AND array_length(conkey, 1) = 1
    ) THEN
        ALTER TABLE {schema}.tasks DROP CONSTRAINT tasks_pkey;
        ALTER TABLE {schema}.tasks ADD PRIMARY KEY (user_id, id);
    END IF;
END$$;
