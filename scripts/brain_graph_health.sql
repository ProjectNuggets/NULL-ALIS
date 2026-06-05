-- brain_graph_health.sql — reusable graph-health metrics for the memory graph.
--
-- Phase-0 instrumentation for the brain-graph activation work. Run read-only
-- against any deployment to baseline (and later re-measure) graph health.
--
-- Usage:
--   psql "$URL" -v schema=zaki_bot -f scripts/brain_graph_health.sql
-- Defaults to schema `zaki_bot` if -v schema is not supplied.
--
-- Distinguishes the two graph layers that matter:
--   * MEMORY orphans  — memory rows with no incident memory_edges (the
--                       "99.6% orphan" headline). Reduced by memory->entity
--                       extraction/structural edges, NOT by the entity
--                       pipeline's hub/co-occurrence edges alone.
--   * ENTITY graph    — entities + speaker-hub (user:<id> MENTIONED) +
--                       co-occurrence (MENTIONS) edges. Densified by the
--                       entity pipeline (C4 activation).

\set ON_ERROR_STOP on
\if :{?schema}
\else
  \set schema zaki_bot
\endif
SET search_path TO :"schema";
SET default_transaction_read_only = on;

\echo '== Aggregate corpus =='
SELECT
  (SELECT count(*) FROM memories)                              AS memories_total,
  (SELECT count(*) FROM memories WHERE memory_type = 'core')   AS memories_core,
  (SELECT count(DISTINCT user_id) FROM memories)               AS users,
  (SELECT count(*) FROM memory_entities)                       AS entities,
  (SELECT count(*) FROM memory_edges WHERE is_latest)          AS edges_latest;

\echo '== Memory-orphan rate (the headline) — all vs core layer =='
SELECT
  round(100.0 * (SELECT count(*) FROM memories m
                 WHERE NOT EXISTS (SELECT 1 FROM memory_edges e
                   WHERE e.is_latest AND (e.source_key = m.key OR e.target_key = m.key)))
        / NULLIF((SELECT count(*) FROM memories), 0), 1)        AS orphan_pct_all,
  round(100.0 * (SELECT count(*) FROM memories m
                 WHERE m.memory_type = 'core'
                   AND NOT EXISTS (SELECT 1 FROM memory_edges e
                     WHERE e.is_latest AND (e.source_key = m.key OR e.target_key = m.key)))
        / NULLIF((SELECT count(*) FROM memories WHERE memory_type = 'core'), 0), 1)
                                                                AS orphan_pct_core;

\echo '== Embedding coverage (no embedding => no semantic edge, no coref) =='
SELECT
  (SELECT count(*) FROM memory_embeddings_e5_1024)             AS embeddings,
  round(100.0 * (SELECT count(*) FROM memories m
                 WHERE EXISTS (SELECT 1 FROM memory_embeddings_e5_1024 em WHERE em.key = m.key))
        / NULLIF((SELECT count(*) FROM memories), 0), 1)        AS embed_coverage_pct;

\echo '== Entity-graph density (what C4 activation moves) =='
SELECT
  count(*) FILTER (WHERE predicate = 'MENTIONED')              AS speaker_hub_edges,
  count(*) FILTER (WHERE predicate = 'MENTIONS')               AS cooccurrence_edges,
  count(*) FILTER (WHERE source_key LIKE 'user:%' OR target_key LIKE 'user:%') AS hub_incident_edges,
  count(DISTINCT CASE WHEN source_key LIKE 'user:%' THEN source_key END)       AS distinct_user_hubs,
  round(count(*)::numeric / NULLIF((SELECT count(*) FROM memories), 0), 4)      AS edges_per_memory
FROM memory_edges WHERE is_latest;

\echo '== Coref health (resolved entity ids vs hash fallback) =='
SELECT
  count(*) FILTER (WHERE target_key NOT LIKE 'entity_%')       AS resolved_targets,
  count(*) FILTER (WHERE target_key LIKE 'entity_%')           AS hash_fallback_targets
FROM memory_edges WHERE is_latest AND predicate <> 'MENTIONED';
