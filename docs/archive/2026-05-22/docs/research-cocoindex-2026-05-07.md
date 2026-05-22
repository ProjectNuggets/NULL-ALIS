# cocoindex investigation — V2 context candidate?

**Date:** 2026-05-07
**Context:** nullalis (Zig 0.15.2 + libpq + Postgres + pgvector) considering cocoindex for V2 context-build / memory-retrieval pipeline.
**Repo:** https://github.com/cocoindex-io/cocoindex — 8.8K stars, 647 forks, Apache-2.0, latest release `v1.0.3` (2026-05-05), pushed 2 days ago.

---

## 1. What is it?

CocoIndex is an **incremental ETL/indexing framework for AI agent context**. Tagline: "Your agents deserve fresh context." You declare a Python flow (`@coco.fn`) that turns sources (codebases, PDFs, Slack, meeting notes, Postgres, S3, Drive, Kafka) into target indexes (pgvector, LanceDB, Qdrant, Neo4j, FalkorDB, SurrealDB, Kafka, warehouses). The pitch is "React for data engineering" — `target = F(source)`, persistent dataflow, **only the Δ is recomputed** when source or transform code changes. It is *not* an agent runtime, *not* a memory store, *not* a retrieval engine. It is the pipe that keeps an index hot.

## 2. Language / runtime

- **Python API surface, Rust core engine.** `pip install -U cocoindex`. Python 3.10–3.13.
- Languages by bytes: Python 73%, Rust 24%, plus shell/astro/handlebars (docs site).
- Runs as a **Python process** that hosts the Rust engine in-proc. CLI exists (`cocoindex.cli`). It is library-shaped, not a daemon — though for "live" mode it wants to be a long-running process polling/subscribing to sources.

## 3. Architecture / data flow

`source connectors → @coco.fn transforms (chunk, embed, LLM-extract) → target connectors (vector / graph / relational)`. Both **batch** (`update_blocking()` for backfill) and **streaming/incremental** (Δ on source change or code change). It tracks per-row provenance and code-hash memoization so a transform-function rewrite invalidates only the dependent rows. Eight always-on subsystems advertised: live caching, pipeline catalog, version tracking, lineage, scheduler, metrics, retries, DLQ.

## 4. What problem does it solve?

It is an **incremental indexing pipeline**. Closest neighbors: dlt, Airbyte, LlamaIndex ingestion, Estuary Flow — but ETL-shaped rather than RAG-framework-shaped. It solves "I have a corpus that changes constantly and I need a vector / graph index that stays in sync without re-embedding everything." It does **not** solve retrieval, ranking, prompt assembly, or agent loop. That is left to your app.

## 5. Feature checklist

| Need | cocoindex |
|---|---|
| Postgres + pgvector | **Yes**, first-class target connector |
| Per-tenant scoping | Not built-in; you'd partition via flow params or table-per-tenant |
| Streaming / incremental | **Yes** — this is the headline feature |
| Bi-temporal (valid_to / invalid_at / supersede) | **No.** It tracks source→target lineage, not domain validity windows |
| Knowledge graph / typed edges | **Yes** — Neo4j, FalkorDB, Kuzu, SurrealDB targets; LLM-extraction examples include conversation→KG |
| LLM-driven extraction | **Yes** — examples use Gemini, BAML, DSPy for structured extraction |
| Custom embedders | **Yes** — any Python callable inside an `@coco.fn` |

## 6. Maturity signals

- 8,807 stars, 647 forks, 51 open issues, active CI, `v1.0.3` shipped 2 days ago — past the `0.x` threshold.
- Org-backed (`cocoindex-io`), commercial entity behind it (cocoindex.io homepage, "Enterprise" tier marketed).
- Discord, YouTube, blog all live. 20+ working examples in-repo, refreshed weekly.
- No marquee customer logos in the README — early-commercial, not Datadog-tier validation. But weekly cadence + Rust core + 1.0 release is real.

## 7. Runtime cost

- **Library-first.** No required external daemon. You import it, declare flows, run.
- For incremental mode it wants to be long-lived (so it can watch sources). Can also be cron-driven.
- **No new database required** — it writes into *your* targets (your existing Postgres works).
- Internal state (cache, lineage, version tracking) is persisted; default backing is Postgres. So you'd point it at the same Postgres you already run. Net new infra: zero. Net new process: one Python worker.

---

## Strategic verdict for nullalis

### Could we "port it as V2 context"?

Not directly. cocoindex is a **Python+Rust ingest pipeline**, nullalis is a **Zig agent runtime**. Adopting it means running a sidecar Python process that writes into the same Postgres nullalis already owns. The Zig retrieval layer (`memory_loader.zig`, `store_pgvector.zig`) stays — it just reads from richer tables.

### What we'd GAIN

1. **Free incremental ingest of external corpora** — codebases, PDFs, Slack, Drive, meeting notes. Today nullalis only ingests conversation turns. cocoindex turns "give the agent my whole repo / inbox / wiki" into a config file.
2. **Code-hash memoization** — change the chunker or extractor, only affected rows re-embed. We don't have this; today an extraction-prompt change would force a manual backfill.
3. **Lineage** — every vector traces to source byte. Useful for the audit-trail work in `.audit/v1.8/`.
4. **Connector breadth for free** (S3, Drive, Kafka, Neo4j) without writing each in Zig.

### What we'd LOSE / break

1. **Bi-temporal lifecycle is ours, not theirs.** `valid_to`, `invalid_at`, supersede chains, LPA communities, 0.95-cosine coreference — none of this maps to cocoindex's lineage model. cocoindex tracks `source-byte → target-row`. nullalis tracks `claim → world-state-over-time`. Different problem.
2. **Per-cell-pod tenancy** is not idiomatic. cocoindex flows are app-global; pod-per-cell would mean N flows or heavy parameterization.
3. **Python in the hot path.** nullalis is Zig precisely so the agent loop is allocator-tight. Adding a Python sidecar is fine for ingest, fatal for retrieval.
4. **The compaction/context_engine 4-phase pipeline is unique to agent turns**, not corpus indexing. cocoindex has nothing equivalent.

### Hybrid option (the actual fit)

Use cocoindex as the **ingest mouth** for non-conversation sources — repos, PDFs, Slack — writing into a `corpus_chunks(tenant_id, source, text, embedding, lineage)` table. Keep the entire Zig stack (`context_engine`, `memory_loader`, `compaction`, lifecycle, communities, extraction) untouched on conversation memory. `memory_loader` gains one new tier: `corpus_chunks` cosine top-k filtered by tenant. Agent retrieval stays Zig, stays hot.

This is the same shape as the existing native-connector roadmap — cocoindex would be the "long-tail document corpus" connector, not a memory replacement.

### One-line verdict

**Inspire + partial-adopt-as-ingest-sidecar.** Don't port it as V2 context — the bi-temporal memory model is the differentiator and cocoindex doesn't speak that language. Do consider it as the corpus-ingest plane once we want repo/PDF/Slack memory; the Δ-only engine is genuinely good and we'd be reinventing it badly in Zig.
