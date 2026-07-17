-- WP-I / F21 — remove assistant-owned scaffold artifacts that predate the
-- write-boundary guard. This migration is deliberately conservative:
--   * memory rows match only explicit runtime fence syntax
--     ([[ZAKI_*]], <memory_for_turn>, <memory_context>);
--   * entity rows match the exact, whitespace-normalized denylist shared by
--     context_builder.isScaffoldEntityName at the time of this migration.
-- It never classifies or deletes ordinary prose about memory architecture.
--
-- The runner wraps this file and its schema_migrations record in one
-- transaction. Audit payloads contain hashes, never poisoned content.

CREATE TEMP TABLE IF NOT EXISTS wp_i_poisoned_memories ON COMMIT DROP AS
SELECT
    id,
    user_id,
    key,
    encode(digest(content, 'sha256'), 'hex') AS audit_content_hash
FROM {schema}.memories
WHERE content ~* '\[\[[[:space:]]*/?[[:space:]]*ZAKI_'
   OR content ~* '<[[:space:]]*/?[[:space:]]*memory_for_turn([[:space:]/>]|$)'
   OR content ~* '<[[:space:]]*/?[[:space:]]*memory_context([[:space:]/>]|$)';

CREATE TEMP TABLE IF NOT EXISTS wp_i_scaffold_entities ON COMMIT DROP AS
SELECT id, user_id, name
FROM {schema}.memory_entities
WHERE btrim(regexp_replace(lower(name), '[[:space:]]+', ' ', 'g')) IN (
    'memory link types',
    'brain architecture',
    'response protocol',
    'channel attachments',
    'task decomposition',
    'runtime capabilities',
    'persona calibration',
    'project context',
    'available skills',
    'tool use protocol',
    'available tools',
    'working memory',
    'distillation extraction',
    'layer 0',
    'layer 1',
    'layer 2',
    'auto-promoted',
    'auto-promotion',
    'semantic memory',
    'episodic memory',
    'procedural memory',
    'memory link',
    'link type'
);

-- Existing upsert/edit events contain the full memory content in payload.
-- Preserve their audit identity and event type, but replace all payload fields
-- with hashes before the poisoned memory disappears. Clearing memory_id avoids
-- retaining a possibly caller-shaped identifier in the hash-only audit trail.
UPDATE {schema}.memory_events AS event
SET memory_id = NULL,
    payload = jsonb_build_object(
        'migration', '0010_brain_scaffold_purge',
        'reason', 'historical_scaffold_event_redacted',
        'original_event_type', event.event_type,
        'memory_id_hash', encode(digest(event.memory_id, 'sha256'), 'hex'),
        'payload_hash', encode(digest(event.payload::text, 'sha256'), 'hex')
    )
WHERE EXISTS (
    SELECT 1
    FROM wp_i_poisoned_memories AS poisoned
    WHERE poisoned.user_id = event.user_id
      AND poisoned.id = event.memory_id
);

INSERT INTO {schema}.memory_events (id, user_id, memory_id, event_type, payload)
SELECT
    'mig0010-memory-' || md5(user_id::text || ':' || id),
    user_id,
    NULL,
    'scaffold_purge',
    jsonb_build_object(
        'migration', '0010_brain_scaffold_purge',
        'reason', 'explicit_assistant_scaffold',
        'memory_id_hash', encode(digest(id, 'sha256'), 'hex'),
        'key_hash', encode(digest(key, 'sha256'), 'hex'),
        'content_hash', audit_content_hash
    )
FROM wp_i_poisoned_memories
ON CONFLICT (id) DO NOTHING;

INSERT INTO {schema}.memory_events (id, user_id, memory_id, event_type, payload)
SELECT
    'mig0010-entity-' || md5(user_id::text || ':' || id),
    user_id,
    NULL,
    'scaffold_entity_purge',
    jsonb_build_object(
        'migration', '0010_brain_scaffold_purge',
        'reason', 'exact_scaffold_entity',
        'entity_id_hash', encode(digest(id, 'sha256'), 'hex'),
        'entity_name_hash', encode(digest(name, 'sha256'), 'hex')
    )
FROM wp_i_scaffold_entities
ON CONFLICT (id) DO NOTHING;

-- Remove graph edges first. Every join includes user_id so identical keys or
-- IDs in another tenant cannot be touched by a tenant-local match.
DELETE FROM {schema}.memory_edges AS edge
WHERE EXISTS (
    SELECT 1
    FROM wp_i_poisoned_memories AS poisoned
    WHERE poisoned.user_id = edge.user_id
      AND (
          edge.source_key IN (poisoned.key, poisoned.id)
          OR edge.target_key IN (poisoned.key, poisoned.id)
      )
)
OR EXISTS (
    SELECT 1
    FROM wp_i_scaffold_entities AS scaffold
    WHERE scaffold.user_id = edge.user_id
      AND (edge.source_key = scaffold.id OR edge.target_key = scaffold.id)
);

-- The pgvector table is created lazily and may not exist in every deployment.
-- Delete from the production-default table when present without making the
-- migration depend on pgvector being enabled. The DELETE is written as a
-- static statement in the conditional branch — PL/pgSQL parses and resolves
-- a statement only the first time its branch executes, so deployments
-- without the table never reference it. Static SQL (no EXECUTE) is required
-- by the WP-12 expand-phase gate (validateExpandSql).
DO $wp_i$
BEGIN
    IF to_regclass('{schema}.memory_embeddings') IS NOT NULL THEN
        DELETE FROM {schema}.memory_embeddings AS embedding
        USING pg_temp.wp_i_poisoned_memories AS poisoned
        WHERE embedding.user_id = poisoned.user_id
          AND embedding.key = poisoned.key;
    END IF;
END
$wp_i$;

DELETE FROM {schema}.memories AS memory
USING wp_i_poisoned_memories AS poisoned
WHERE memory.user_id = poisoned.user_id
  AND memory.id = poisoned.id;

DELETE FROM {schema}.memory_entities AS entity
USING wp_i_scaffold_entities AS scaffold
WHERE entity.user_id = scaffold.user_id
  AND entity.id = scaffold.id;
