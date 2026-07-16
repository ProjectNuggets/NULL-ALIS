-- Minutes meeting-memory provenance and erasure tombstones.
--
-- Source links store only domain-separated SHA-256 source/scope digests,
-- policy evidence, and timestamps. Raw spoke identifiers, transcripts,
-- extracted candidate text, consent grants, and receipt payloads do not
-- belong here.
--
-- State methods derive meeting_scope_digest from the authenticated user and
-- meeting scope, then serialize writes and erasure for that digest with a
-- transaction-scoped advisory lock. Permanent, digest-only meeting/account
-- tombstones are deliberately separate from time-bounded compliance receipts:
-- receipt retention may delete audit evidence, but must never reopen ingest.

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
    user_id BIGINT NOT NULL
        CHECK (user_id > 0),
    write_origin TEXT NOT NULL DEFAULT 'meeting_ingest'
        CHECK (write_origin = 'meeting_ingest'),
    source_spoke TEXT NOT NULL DEFAULT 'minutes'
        CHECK (source_spoke = 'minutes'),
    meeting_scope_digest TEXT NOT NULL
        CHECK (meeting_scope_digest ~ '^sha256=[0-9a-f]{64}$')
        REFERENCES {schema}.meeting_memory_erasure_tombstones(meeting_scope_digest),

    -- These bind one authenticated request to one stable, immutable receipt.
    -- Neither may contain source data; both are hashes of canonical,
    -- domain-separated, content-free envelopes.
    request_digest TEXT NOT NULL
        CHECK (request_digest ~ '^sha256=[0-9a-f]{64}$'),
    receipt_digest TEXT NOT NULL
        CHECK (receipt_digest ~ '^sha256=[0-9a-f]{64}$'),

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
        user_id,
        source_spoke,
        meeting_scope_digest
    );

-- Prevent request or receipt replay across two meeting scopes.
CREATE UNIQUE INDEX IF NOT EXISTS idx_meeting_memory_erasure_receipts_request_digest
    ON {schema}.meeting_memory_erasure_receipts (
        user_id,
        source_spoke,
        request_digest
    );

CREATE UNIQUE INDEX IF NOT EXISTS idx_meeting_memory_erasure_receipts_receipt_digest
    ON {schema}.meeting_memory_erasure_receipts (receipt_digest);

-- The compliance worker applies its configured audit-receipt window to
-- erased_at and may DELETE expired rows. Durable tombstones are separate, so
-- cleanup cannot reopen the write gate or inherit transcript-retention policy.
CREATE INDEX IF NOT EXISTS idx_meeting_memory_erasure_receipts_retention
    ON {schema}.meeting_memory_erasure_receipts (erased_at);

-- Receipts are append-only while retained, including for the table owner. For
-- every matched UPDATE this idempotent rewrite rule attempts to reinsert the
-- immutable OLD row. The retained row necessarily collides with its unique
-- scope/request/receipt digests, so PostgreSQL aborts the statement loudly.
-- DELETE is deliberately unaffected so the retention worker can expire rows.
CREATE OR REPLACE RULE meeting_memory_erasure_receipts_no_update AS
    ON UPDATE TO {schema}.meeting_memory_erasure_receipts
    DO INSTEAD
    INSERT INTO {schema}.meeting_memory_erasure_receipts (
        user_id,
        write_origin,
        source_spoke,
        meeting_scope_digest,
        request_digest,
        receipt_digest,
        memory_source_links_deleted,
        memories_deleted,
        memory_events_deleted,
        memory_embeddings_deleted,
        memory_vectors_deleted,
        memory_entities_deleted,
        memory_edges_deleted,
        working_memory_deleted,
        erased_at,
        created_at
    ) VALUES (
        OLD.user_id,
        OLD.write_origin,
        OLD.source_spoke,
        OLD.meeting_scope_digest,
        OLD.request_digest,
        OLD.receipt_digest,
        OLD.memory_source_links_deleted,
        OLD.memories_deleted,
        OLD.memory_events_deleted,
        OLD.memory_embeddings_deleted,
        OLD.memory_vectors_deleted,
        OLD.memory_entities_deleted,
        OLD.memory_edges_deleted,
        OLD.working_memory_deleted,
        OLD.erased_at,
        OLD.created_at
    );
