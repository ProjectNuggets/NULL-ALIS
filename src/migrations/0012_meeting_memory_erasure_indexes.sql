-- WP-15: complete-history access paths for exact Minutes erasure.
--
-- Existing edge indexes are partial on is_latest and cannot prove deletion of
-- historical source/target carriers. memory_events previously had no tenant
-- lookup index at all. Build these outside a transaction so populated Brain
-- tables remain writable while the launch foundation is still default-off.
--
-- PostgreSQL can leave an INVALID same-name index behind when a concurrent
-- build is interrupted. Version 12 is recorded only after every statement
-- succeeds, so an unapplied retry must remove that residue before rebuilding;
-- IF NOT EXISTS would otherwise accept the unusable index and mark the
-- migration complete.

DROP INDEX CONCURRENTLY IF EXISTS {schema}.idx_memory_events_user_memory_all;
CREATE INDEX CONCURRENTLY idx_memory_events_user_memory_all
    ON {schema}.memory_events (user_id, memory_id);

DROP INDEX CONCURRENTLY IF EXISTS {schema}.idx_memory_edges_source_all;
CREATE INDEX CONCURRENTLY idx_memory_edges_source_all
    ON {schema}.memory_edges (user_id, source_key);

DROP INDEX CONCURRENTLY IF EXISTS {schema}.idx_memory_edges_target_all;
CREATE INDEX CONCURRENTLY idx_memory_edges_target_all
    ON {schema}.memory_edges (user_id, target_key);

DROP INDEX CONCURRENTLY IF EXISTS {schema}.idx_memory_edges_episodes_all;
CREATE INDEX CONCURRENTLY idx_memory_edges_episodes_all
    ON {schema}.memory_edges USING GIN (episodes);
