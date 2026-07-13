-- WP-02: access paths for bounded, schema-wide retention pruning.
-- This migration is concurrent-only so existing tables remain writable.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tool_traces_retention
    ON {schema}.tool_traces (created_at);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_subagent_results_retention
    ON {schema}.subagent_results (COALESCE(delivered_at, created_at))
    WHERE status = 'delivered';

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_memory_events_retention
    ON {schema}.memory_events (created_at);
