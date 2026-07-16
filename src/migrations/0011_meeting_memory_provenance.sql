-- Minutes meeting-memory provenance and erasure tombstones.
--
-- This schema stores identifiers, domain-separated SHA-256 digests, policy
-- evidence, timestamps, and deletion counts only. Raw transcripts, extracted
-- candidate text, consent grants, and receipt payloads do not belong here.
--
-- State methods derive meeting_scope_digest from the authenticated user and
-- meeting scope, then serialize writes and erasure for that digest with a
-- transaction-scoped advisory lock. A meeting_memory_erasure_receipts row is
-- the durable tombstone: writers must check for it while holding that lock
-- before inserting a source link.

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
    source_item_id TEXT NOT NULL
        CHECK (
            source_item_id = btrim(source_item_id)
            AND octet_length(source_item_id) BETWEEN 1 AND 512
            AND source_item_id !~ '[[:cntrl:]]'
        ),
    meeting_id TEXT NOT NULL
        CHECK (
            meeting_id = btrim(meeting_id)
            AND octet_length(meeting_id) BETWEEN 1 AND 512
            AND meeting_id !~ '[[:cntrl:]]'
        ),
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
    consented_at TIMESTAMPTZ NOT NULL,
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
        source_item_id,
        meeting_id,
        meeting_scope_digest,
        source_digest,
        candidate_digest
    );

-- Meeting-scoped write/forget lookup, shared with the advisory-lock scope.
CREATE INDEX IF NOT EXISTS idx_memory_source_links_user_spoke_meeting
    ON {schema}.memory_source_links (user_id, source_spoke, meeting_id);

-- Erasure selects the complete meeting scope without retaining raw item IDs in
-- its tombstone.
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

CREATE TABLE IF NOT EXISTS {schema}.meeting_memory_erasure_receipts (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Intentionally no users FK: this minimal compliance/anti-resurrection
    -- identifier and its meeting tombstone must outlive tenant-row deletion.
    -- It is removed only under the separate receipt-retention policy.
    user_id BIGINT NOT NULL,
    write_origin TEXT NOT NULL DEFAULT 'meeting_ingest'
        CHECK (write_origin = 'meeting_ingest'),
    source_spoke TEXT NOT NULL DEFAULT 'minutes'
        CHECK (source_spoke = 'minutes'),
    meeting_scope_digest TEXT NOT NULL
        CHECK (meeting_scope_digest ~ '^sha256=[0-9a-f]{64}$'),

    -- These bind one authenticated request to one stable, immutable receipt.
    -- Neither may contain source data; both are hashes of canonical,
    -- domain-separated, content-free envelopes.
    request_digest TEXT NOT NULL
        CHECK (request_digest ~ '^sha256=[0-9a-f]{64}$'),
    receipt_digest TEXT NOT NULL
        CHECK (receipt_digest ~ '^sha256=[0-9a-f]{64}$'),

    -- Content-free carrier manifest. V1 must persist explicit zeroes for
    -- prohibited carriers instead of omitting them from the proof.
    memory_source_links_deleted INTEGER NOT NULL
        CHECK (memory_source_links_deleted >= 0),
    memories_deleted INTEGER NOT NULL
        CHECK (memories_deleted >= 0),
    memory_events_deleted INTEGER NOT NULL
        CHECK (memory_events_deleted >= 0),
    memory_embeddings_deleted INTEGER NOT NULL
        CHECK (memory_embeddings_deleted >= 0),
    memory_vectors_deleted INTEGER NOT NULL
        CHECK (memory_vectors_deleted >= 0),
    memory_entities_deleted INTEGER NOT NULL
        CHECK (memory_entities_deleted >= 0),
    memory_edges_deleted INTEGER NOT NULL
        CHECK (memory_edges_deleted >= 0),
    working_memory_deleted INTEGER NOT NULL
        CHECK (working_memory_deleted >= 0),

    erased_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Exactly one durable tombstone exists for a meeting scope. A retry with the
-- same request digest returns this immutable row; a different request cannot
-- replace it or recover the raw meeting identifier.
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
