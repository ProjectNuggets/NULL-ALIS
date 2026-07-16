-- WP-15: complete-history access paths for exact Minutes erasure.
--
-- Existing edge indexes are partial on is_latest and cannot prove deletion of
-- historical source/target carriers. memory_events previously had no tenant
-- lookup index at all. Build these outside a transaction so populated Brain
-- tables remain writable while the launch foundation is still default-off.

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_memory_events_user_memory_all
    ON {schema}.memory_events (user_id, memory_id);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_memory_edges_source_all
    ON {schema}.memory_edges (user_id, source_key);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_memory_edges_target_all
    ON {schema}.memory_edges (user_id, target_key);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_memory_edges_episodes_all
    ON {schema}.memory_edges USING GIN (episodes);
