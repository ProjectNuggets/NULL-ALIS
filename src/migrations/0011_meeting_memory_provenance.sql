-- Minutes meeting-memory provenance and erasure tombstones.
--
-- Source links store only domain-separated HMAC-SHA-256 source/scope
-- pseudonyms (rendered with the legacy-compatible sha256= prefix),
-- policy evidence, and timestamps. Raw spoke identifiers, transcripts,
-- extracted candidate text, consent grants, and receipt payloads do not
-- belong here.
--
-- State methods derive meeting_scope_digest from the authenticated user and
-- meeting scope, then serialize writes and erasure for that digest with a
-- transaction-scoped advisory lock. Permanent, digest-only meeting/account
-- tombstones are deliberately separate from time-bounded compliance receipts:
-- receipt retention may delete audit evidence, but must never reopen ingest.

-- One immutable identifier binds all existing pseudonyms to the configured
-- deployment key. Runtime initialization must insert the active key ID and
-- fail closed when the singleton already contains a different value; changing
-- this key is a data migration, never an ordinary secret rotation.
CREATE TABLE IF NOT EXISTS {schema}.meeting_memory_crypto_state (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    pseudonym_key_id TEXT NOT NULL
        CHECK (pseudonym_key_id ~ '^sha256=[0-9a-f]{64}$'),
    initialized_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        CHECK (isfinite(initialized_at))
);

CREATE TABLE IF NOT EXISTS {schema}.memory_source_links (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL
        REFERENCES {schema}.users(user_id) ON DELETE CASCADE,
    memory_key TEXT NOT NULL
        CHECK (memory_key ~ '^meeting_ingest/[0-9a-f]{64}$'),
    write_origin TEXT NOT NULL DEFAULT 'meeting_ingest'
        CHECK (write_origin = 'meeting_ingest'),
    source_spoke TEXT NOT NULL DEFAULT 'minutes'
        CHECK (source_spoke = 'minutes'),
    meeting_scope_digest TEXT NOT NULL
        CHECK (meeting_scope_digest ~ '^sha256=[0-9a-f]{64}$'),
    source_digest TEXT NOT NULL
        CHECK (source_digest ~ '^sha256=[0-9a-f]{64}$'),
    candidate_digest TEXT NOT NULL
        CHECK (candidate_digest ~ '^sha256=[0-9a-f]{64}$'),
    consent_grant_digest TEXT NOT NULL
        CHECK (consent_grant_digest ~ '^sha256=[0-9a-f]{64}$'),
    consent_policy_version TEXT NOT NULL
        CHECK (
            consent_policy_version = btrim(consent_policy_version)
            AND octet_length(consent_policy_version) BETWEEN 1 AND 128
            AND consent_policy_version ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
        ),
    consented_at TIMESTAMPTZ NOT NULL
        CHECK (consented_at > TIMESTAMPTZ '1970-01-01 00:00:00+00'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (updated_at >= created_at),
    FOREIGN KEY (user_id, memory_key)
        REFERENCES {schema}.memories(user_id, key) ON DELETE CASCADE
);

-- Exact source-scope provenance is the idempotency boundary. memory_key is
-- deliberately absent from this index tuple: the same source candidate cannot
-- race into two Brain rows and then masquerade as two valid links.
CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_source_links_exact_provenance
    ON {schema}.memory_source_links (
        user_id,
        write_origin,
        source_spoke,
        meeting_scope_digest,
        source_digest,
        candidate_digest
    );

-- Meeting-scoped write/erasure lookup, shared with the advisory-lock scope,
-- without retaining raw item identifiers.
CREATE INDEX IF NOT EXISTS idx_memory_source_links_user_spoke_scope_digest
    ON {schema}.memory_source_links (
        user_id,
        source_spoke,
        meeting_scope_digest
    );

-- A Brain row belongs to exactly one source scope. This composite unique index
-- also supports the composite memory FK cascade and prevents erasing one
-- meeting from deleting a row that another tenant or meeting also claims.
CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_source_links_memory
    ON {schema}.memory_source_links (user_id, memory_key);

-- Permanent anti-resurrection marker for one user-bound Minutes meeting.
-- Both identifiers are domain-separated SHA-256 digests. No numeric user ID,
-- raw meeting ID, deletion payload, or retention deadline survives here.
CREATE TABLE IF NOT EXISTS {schema}.meeting_memory_erasure_tombstones (
    user_scope_digest TEXT NOT NULL
        CHECK (user_scope_digest ~ '^sha256=[0-9a-f]{64}$'),
    write_origin TEXT NOT NULL DEFAULT 'meeting_ingest'
        CHECK (write_origin = 'meeting_ingest'),
    source_spoke TEXT NOT NULL DEFAULT 'minutes'
        CHECK (source_spoke = 'minutes'),
    meeting_scope_digest TEXT NOT NULL
        CHECK (meeting_scope_digest ~ '^sha256=[0-9a-f]{64}$'),
    erased_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        CHECK (
            isfinite(erased_at)
            AND erased_at > TIMESTAMPTZ '1970-01-01 00:00:00+00'
        ),
    PRIMARY KEY (user_scope_digest, source_spoke, meeting_scope_digest),
    UNIQUE (meeting_scope_digest)
);

-- Permanent anti-resurrection marker for an erased account. The application
-- derives user_scope_digest from the authenticated user under its own
-- domain; meeting writers must check this marker while holding the user lock.
-- Keeping this separate avoids enumerating every meeting during account purge.
CREATE TABLE IF NOT EXISTS {schema}.meeting_memory_account_erasure_tombstones (
    user_scope_digest TEXT PRIMARY KEY
        CHECK (user_scope_digest ~ '^sha256=[0-9a-f]{64}$'),
    write_origin TEXT NOT NULL DEFAULT 'meeting_ingest'
        CHECK (write_origin = 'meeting_ingest'),
    source_spoke TEXT NOT NULL DEFAULT 'minutes'
        CHECK (source_spoke = 'minutes'),
    erased_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        CHECK (
            isfinite(erased_at)
            AND erased_at > TIMESTAMPTZ '1970-01-01 00:00:00+00'
        )
);

CREATE TABLE IF NOT EXISTS {schema}.meeting_memory_erasure_receipts (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Intentionally no users FK: this time-bounded compliance row may outlive
    -- tenant deletion until the configured compliance-retention window ends.
    -- It is not the anti-resurrection authority; the tombstone above is.
    user_scope_digest TEXT NOT NULL
        CHECK (user_scope_digest ~ '^sha256=[0-9a-f]{64}$'),
    write_origin TEXT NOT NULL DEFAULT 'meeting_ingest'
        CHECK (write_origin = 'meeting_ingest'),
    source_spoke TEXT NOT NULL DEFAULT 'minutes'
        CHECK (source_spoke = 'minutes'),
    meeting_scope_digest TEXT NOT NULL
        CHECK (meeting_scope_digest ~ '^sha256=[0-9a-f]{64}$')
        REFERENCES {schema}.meeting_memory_erasure_tombstones(meeting_scope_digest),

    -- These bind one authenticated request to one stable, immutable receipt.
    -- The request is a keyed pseudonym; the key ID and Ed25519 signature attest
    -- the canonical, domain-separated, content-free receipt envelope.
    request_digest TEXT NOT NULL
        CHECK (request_digest ~ '^sha256=[0-9a-f]{64}$'),
    receipt_key_id TEXT NOT NULL
        CHECK (receipt_key_id ~ '^sha256=[0-9a-f]{64}$'),
    receipt_signature TEXT NOT NULL
        CHECK (receipt_signature ~ '^ed25519=[0-9a-f]{128}$'),

    -- Content-free carrier manifest. V1 must persist explicit zeroes for
    -- prohibited carriers instead of omitting them from the proof.
    memory_source_links_deleted BIGINT NOT NULL
        CHECK (memory_source_links_deleted >= 0),
    memories_deleted BIGINT NOT NULL
        CHECK (memories_deleted >= 0),
    memory_events_deleted BIGINT NOT NULL
        CHECK (memory_events_deleted >= 0),
    memory_embeddings_deleted BIGINT NOT NULL
        CHECK (memory_embeddings_deleted >= 0),
    memory_vectors_deleted BIGINT NOT NULL
        CHECK (memory_vectors_deleted >= 0),
    memory_entities_deleted BIGINT NOT NULL
        CHECK (memory_entities_deleted >= 0),
    memory_edges_deleted BIGINT NOT NULL
        CHECK (memory_edges_deleted >= 0),
    working_memory_deleted BIGINT NOT NULL
        CHECK (working_memory_deleted >= 0),

    erased_at TIMESTAMPTZ NOT NULL
        CHECK (
            isfinite(erased_at)
            AND erased_at > TIMESTAMPTZ '1970-01-01 00:00:00+00'
        ),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (isfinite(created_at) AND created_at >= erased_at)
);

-- At most one retained audit receipt exists for a meeting scope. While that
-- receipt remains, an exact retry returns it and a different request cannot
-- replace it. Deleting an expired receipt never deletes the durable tombstone.
CREATE UNIQUE INDEX IF NOT EXISTS idx_meeting_memory_erasure_receipts_scope
    ON {schema}.meeting_memory_erasure_receipts (
        user_scope_digest,
        source_spoke,
        meeting_scope_digest
    );

-- Prevent one authenticated request from replaying across meeting scopes.
CREATE UNIQUE INDEX IF NOT EXISTS idx_meeting_memory_erasure_receipts_request_digest
    ON {schema}.meeting_memory_erasure_receipts (
        user_scope_digest,
        source_spoke,
        request_digest
    );

-- The compliance worker applies its configured audit-receipt window to
-- erased_at and may DELETE expired rows. Durable tombstones are separate, so
-- cleanup cannot reopen the write gate or inherit transcript-retention policy.
CREATE INDEX IF NOT EXISTS idx_meeting_memory_erasure_receipts_retention
    ON {schema}.meeting_memory_erasure_receipts (erased_at);

-- Fail-loud application guards. Tombstones and the pseudonym-key binding are
-- permanent; receipts are immutable while retained, but DELETE remains open
-- for the compliance-retention worker. PostgreSQL owners/superusers can bypass
-- or disable triggers, so real enforcement still requires infra to split the
-- migration-owner, runtime, and retention roles and grant least privilege.
CREATE OR REPLACE FUNCTION {schema}.reject_meeting_memory_immutable_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $meeting_memory_guard$
BEGIN
    RAISE EXCEPTION 'immutable Minutes state mutation rejected on %.% via %',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP
        USING ERRCODE = '55000';
END;
$meeting_memory_guard$;

DROP TRIGGER IF EXISTS meeting_memory_crypto_state_no_update_delete
    ON {schema}.meeting_memory_crypto_state;
CREATE TRIGGER meeting_memory_crypto_state_no_update_delete
    BEFORE UPDATE OR DELETE ON {schema}.meeting_memory_crypto_state
    FOR EACH STATEMENT
    EXECUTE FUNCTION {schema}.reject_meeting_memory_immutable_mutation();
DROP TRIGGER IF EXISTS meeting_memory_crypto_state_no_truncate
    ON {schema}.meeting_memory_crypto_state;
CREATE TRIGGER meeting_memory_crypto_state_no_truncate
    BEFORE TRUNCATE ON {schema}.meeting_memory_crypto_state
    FOR EACH STATEMENT
    EXECUTE FUNCTION {schema}.reject_meeting_memory_immutable_mutation();

DROP TRIGGER IF EXISTS meeting_memory_erasure_tombstones_no_update_delete
    ON {schema}.meeting_memory_erasure_tombstones;
CREATE TRIGGER meeting_memory_erasure_tombstones_no_update_delete
    BEFORE UPDATE OR DELETE ON {schema}.meeting_memory_erasure_tombstones
    FOR EACH STATEMENT
    EXECUTE FUNCTION {schema}.reject_meeting_memory_immutable_mutation();
DROP TRIGGER IF EXISTS meeting_memory_erasure_tombstones_no_truncate
    ON {schema}.meeting_memory_erasure_tombstones;
CREATE TRIGGER meeting_memory_erasure_tombstones_no_truncate
    BEFORE TRUNCATE ON {schema}.meeting_memory_erasure_tombstones
    FOR EACH STATEMENT
    EXECUTE FUNCTION {schema}.reject_meeting_memory_immutable_mutation();

DROP TRIGGER IF EXISTS meeting_memory_account_tombstones_no_update_delete
    ON {schema}.meeting_memory_account_erasure_tombstones;
CREATE TRIGGER meeting_memory_account_tombstones_no_update_delete
    BEFORE UPDATE OR DELETE ON {schema}.meeting_memory_account_erasure_tombstones
    FOR EACH STATEMENT
    EXECUTE FUNCTION {schema}.reject_meeting_memory_immutable_mutation();
DROP TRIGGER IF EXISTS meeting_memory_account_tombstones_no_truncate
    ON {schema}.meeting_memory_account_erasure_tombstones;
CREATE TRIGGER meeting_memory_account_tombstones_no_truncate
    BEFORE TRUNCATE ON {schema}.meeting_memory_account_erasure_tombstones
    FOR EACH STATEMENT
    EXECUTE FUNCTION {schema}.reject_meeting_memory_immutable_mutation();

DROP TRIGGER IF EXISTS meeting_memory_erasure_receipts_no_update
    ON {schema}.meeting_memory_erasure_receipts;
CREATE TRIGGER meeting_memory_erasure_receipts_no_update
    BEFORE UPDATE ON {schema}.meeting_memory_erasure_receipts
    FOR EACH STATEMENT
    EXECUTE FUNCTION {schema}.reject_meeting_memory_immutable_mutation();
DROP TRIGGER IF EXISTS meeting_memory_erasure_receipts_no_truncate
    ON {schema}.meeting_memory_erasure_receipts;
CREATE TRIGGER meeting_memory_erasure_receipts_no_truncate
    BEFORE TRUNCATE ON {schema}.meeting_memory_erasure_receipts
    FOR EACH STATEMENT
    EXECUTE FUNCTION {schema}.reject_meeting_memory_immutable_mutation();
