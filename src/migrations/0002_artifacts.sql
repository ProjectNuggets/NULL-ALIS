-- 0002_artifacts — canvas/artifacts backend (Wave 2C).
--
-- Adds the artifacts + artifact_versions tables that back the "agent
-- produces a named, versioned, editable document" UX shape: every
-- substantial deliverable (report, plan, code, diagram, slides outline)
-- lands as an ARTIFACT instead of being dumped inline in chat. Both the
-- agent and the user can edit; full version history; one-click public
-- share via opaque share_code.
--
-- Migration contract (per migrations.zig §S10.1):
--   * versioned + idempotent during the dual-path window (D62, 2026-05-25):
--     the legacy `zaki_state.zig::migrate` inline loop ALSO creates the
--     artifacts tables via CREATE IF NOT EXISTS so existing v1 deployments
--     get the schema even when the migrations framework is being wired up.
--     migrations.run() runs immediately after that inline loop, so the
--     0002 body MUST tolerate the tables already existing. Once the
--     inline block is deleted (follow-up after D62), this migration can
--     drop the IF NOT EXISTS guards and become a true pure-diff entry.
--   * applies in a single transaction (no CONCURRENTLY)
--   * references {schema}.users(user_id) with ON DELETE CASCADE so
--     GDPR purgeUser drops a user's artifacts automatically
--
-- Conservative design choices documented inline:
--   * `kind` is a TEXT CHECK whitelist instead of an enum type because
--     enum-type ALTER requires a separate migration to add a new value;
--     the CHECK constraint can be replaced atomically.
--   * `metadata_jsonb` is a free-form JSONB bucket but the sanitizer in
--     src/artifacts/sanitizer.zig STRIPS it from any public-share
--     payload — operators can stash internal hints there without leak
--     risk. Default `{}` keeps the row size minimal.
--   * `share_code` is opaque + UNIQUE; the partial index restricts the
--     index to actively-shared rows so an unshared corpus stays
--     storage-efficient.
--   * artifact_versions.content_hash is sha256-hex — used by the
--     application layer for "is this update a no-op duplicate?" checks.
--     The DB does not enforce dedup; the application chooses whether
--     to insert a no-change version (default: skip).

CREATE TABLE IF NOT EXISTS {schema}.artifacts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    session_id      TEXT,
    title           TEXT NOT NULL,
    kind            TEXT NOT NULL CHECK (kind IN (
        'markdown',
        'code',
        'html',
        'svg',
        'json',
        'mermaid',
        'plaintext'
    )),
    created_at_unix BIGINT NOT NULL,
    updated_at_unix BIGINT NOT NULL,
    current_version BIGINT NOT NULL DEFAULT 1,
    is_shared       BOOLEAN NOT NULL DEFAULT FALSE,
    share_code      TEXT UNIQUE,
    share_expires_at_unix BIGINT,
    metadata_jsonb  JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_artifacts_user_updated
    ON {schema}.artifacts (user_id, updated_at_unix DESC);

-- Partial index — only actively-shared rows. Saves space when most
-- artifacts are private (the expected steady-state shape).
CREATE INDEX IF NOT EXISTS idx_artifacts_share_code
    ON {schema}.artifacts (share_code)
    WHERE share_code IS NOT NULL;

CREATE TABLE IF NOT EXISTS {schema}.artifact_versions (
    id                  BIGSERIAL PRIMARY KEY,
    artifact_id         UUID NOT NULL REFERENCES {schema}.artifacts(id) ON DELETE CASCADE,
    version             BIGINT NOT NULL,
    parent_version      BIGINT,
    content             TEXT NOT NULL,
    content_hash        TEXT NOT NULL,
    created_at_unix     BIGINT NOT NULL,
    author              TEXT NOT NULL CHECK (author IN ('agent', 'user')),
    change_summary      TEXT,
    UNIQUE (artifact_id, version)
);

CREATE INDEX IF NOT EXISTS idx_artifact_versions_artifact_version
    ON {schema}.artifact_versions (artifact_id, version DESC);
