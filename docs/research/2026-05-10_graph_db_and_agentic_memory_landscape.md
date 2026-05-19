# Graph DBs and Agentic Memory Systems vs. nullalis — Landscape & Upgrade Plan

*Research date: 2026-05-10. Author: research agent for Mohammad (nullalis V1.14.8).*
*Baseline: nullalis 90.17% on LoCoMo Cat 1-4 (541/600); V1.14.8 unified boundary extractor just shipped (Pass A / Pass C / session-end), graph density unvalidated end-to-end.*

---

## TL;DR — Top 5 Recommendations (~250 words)

1. **Stay on Postgres + pgvector + your own `memory_edges` table. Do NOT adopt Apache AGE, Neo4j, Kuzu, or FalkorDB.** Kuzu was archived October 2025 ([BigGo News](https://biggo.com/news/202510130126_KuzuDB-embedded-graph-database-archived)); AGE is slower than Neo4j for [r*..N] traversals in production ([Trendyol migration report, Apr 2026](https://medium.com/trendyol-tech/migrating-graph-operations-to-apache-age-from-writes-to-reads-3b8334628e1c)); the agent-memory field is converging on "graph-shaped queries over Postgres" rather than dedicated graph engines. Hindsight's [Case Against External Vector DBs](https://hindsight.vectorize.io/blog/2026/05/12/case-against-external-vector-dbs-agent-memory) and [SoftwareSeni's Postgres-as-substrate piece](https://www.softwareseni.com/how-postgres-became-the-ai-agent-substrate-for-memory-branching-and-modern-hosting/) both make this explicit.
2. **Adopt Graphiti-style bi-temporal fact invalidation** — store `valid_at`, `invalid_at`, `created_at`, `expired_at` per edge and run an LLM "invalidation prompt" against semantically-similar existing edges at write time. You already have `valid_at`; add `invalid_at` + invalidation pass. This is the single biggest reason Zep/Graphiti win LongMemEval temporal reasoning ([arxiv 2501.13956](https://arxiv.org/abs/2501.13956)).
3. **Add a third "graph density audit" boundary** — fire after every Pass C and log `entities`, `edges`, `density_per_1k_tokens`. Two `entities=0 edges=0` observations is one fault away from a silent regression. Mem0's eval pipeline shows the density floor matters more than fancy schemas.
4. **Add LongMemEval (especially LongMemEval_S) alongside LoCoMo.** Frontier numbers now live there (Supermemory 99%, ENGRAM 71.4% with 1% tokens, HyperMem 92.73%, LiCoMemory new SOTA on temporal). Cat 1-4 of LoCoMo is saturated above 90%; the differentiation is happening on LongMemEval and on BEAM (10M-token sessions, ICLR 2026).
5. **Keep your distillation-boundary extraction; add Cognee-style "memify" reweighting and consider HippoRAG's Personalized PageRank for multi-hop retrieval.** Your Pass A/C/session-end approach is *correct* and matches LiCoMemory's design philosophy of treating the KG as a "semantic indexing layer, not a static repository." But you have no edge reinforcement or PageRank-style traversal — that's where the next 3-5 points on Cat 2 multi-hop live.

---

## Section 1 — Graph DB landscape

### 1.1 The October 2025 shock

The single most important fact for any 2026 graph-DB decision: **KuzuDB was archived on or around October 10, 2025** ([BigGo News](https://biggo.com/news/202510130126_KuzuDB-embedded-graph-database-archived)). The team went to Apple. Two forks exist:
- **Ladybug** — successor maintained by the original Kuzu community ([prrao87/graph-benchmark](https://github.com/prrao87/graph-benchmark)).
- **RyuGraph** ([predictable-labs/ryugraph](https://github.com/predictable-labs/ryugraph)) — embedded property graph DB with vector + full-text search, Cypher-compatible.
- **Bighorn** ([Kineviz/bighorn](https://github.com/Kineviz/bighorn)) — another Kuzu fork.

This invalidates a lot of 2024-mid-2025 advice that recommended Kuzu as "the embedded Neo4j." If you adopt anything in this family, pick Ladybug or RyuGraph and accept that you are betting on a small fork community.

RedisGraph was deprecated by Redis in early 2024; the spiritual successor is **FalkorDB**, run by the original RedisGraph team.

### 1.2 Property-graph engines

| Engine | License | Query Lang | Vector? | Best at | Agentic-memory fit |
|---|---|---|---|---|---|
| **Neo4j** | GPLv3 community / commercial enterprise | Cypher | yes (5.11+) | deep traversals, mature tooling, biggest community | de facto standard for Graphiti, GraphRAG, LightRAG, Cognee; heavy infra |
| **Memgraph** | BSL (source-available) | Cypher | yes | in-memory speed, GraphRAG-native (Memgraph + Cognee integration) | strong fit — purpose-built for "structured connected context" ([memgraph.com](https://memgraph.com/blog/from-rag-to-graphs-cognee-ai-memory)) |
| **FalkorDB** | SSPL | Cypher (OpenCypher) | yes | highest QPS in benchmarks (6,693 QPS, 11 of 12 wins per [aimultiple](https://aimultiple.com/graph-databases)); distributed by default | fastest single-node graph engine measured; backs Graphiti officially ([docs.falkordb.com](https://docs.falkordb.com/agentic-memory/graphiti.html)) |
| **ArangoDB** | Apache 2.0 community / commercial | AQL | yes | multi-model (doc + graph + KV); only OSI-licensed mainstream graph DB left besides Apache AGE / HugeGraph | underrated for memory; lacks tight LLM ecosystem |
| **KuzuDB** | **ARCHIVED** | Cypher | yes | columnar, vectorized scan, 18× faster ingest than Neo4j ([prrao87](https://github.com/prrao87/kuzudb-study)) | dead — use Ladybug/RyuGraph |
| **NebulaGraph** | Apache 2.0 | nGQL | yes | horizontal scale, trillion-edge claims | overkill for single-tenant memory |
| **JanusGraph** | Apache 2.0 | Gremlin | weak | distributed (Cassandra/HBase backend) | obsolete for agent memory |
| **TigerGraph** | Proprietary | GSQL | yes | enterprise analytics | wrong shape |
| **ArcadeDB** | Apache 2.0 | Cypher + Gremlin + SQL | yes | multi-model + OSI license + KuzuDB-migration story | quietly the best "actually open" alternative in 2026 ([ArcadeDB](https://arcadedb.com/blog/neo4j-alternatives-in-2026-a-fair-look-at-the-open-source-options/)) |

### 1.3 Triple stores / RDF

Largely irrelevant for agentic memory. Blazegraph is dead (acquired into Amazon Neptune, no open development). Virtuoso is mature but its sweet spot is large static ontologies, not write-heavy session memory. Stardog is commercial enterprise. GraphDB (Ontotext) similar. **No serious agent-memory system in 2026 uses RDF** — they all use property graphs because edges-with-properties map cleanly to "fact with valid_at + confidence."

### 1.4 Hybrid / Postgres-native graph

| Option | Status | Verdict for nullalis |
|---|---|---|
| **Apache AGE** | Apache 2.0, Postgres extension, openCypher | Slower than Neo4j on deep traversals (Trendyol migration writeup, Apr 2026). Driver/tooling thinner. Recommended for "simple graph needs alongside SQL" but **not for graph-first workloads** ([dev.to/pawnsapprentice](https://dev.to/pawnsapprentice/apache-age-vs-neo4j-battle-of-the-graph-databases-2m4)). Likely a downgrade from your current `memory_edges` table approach because AGE imposes a Cypher abstraction without delivering the depth-traversal speed that justifies it. |
| **pgRouting** | road-network routing, not general graphs | n/a |
| **lance-graph** (Lance + graph extensions) | new, experimental | watch but don't adopt |
| **pgvector + handwritten edges table** | what you have | **this is the recommendation the field is converging on** |

### 1.5 Zig-native?

There is no production-grade Zig graph database. Closest:
- **TigerBeetle** is in Zig but it is a financial transaction DB, not a graph DB; its LSM is single-purpose.
- A handwritten Postgres-backed `memory_edges(src, relation_type, dst, valid_at, invalid_at, confidence, fact)` table — which is what nullalis has — is exactly the right level of native-Zig for a graph layer in 2026. You can hand-tune the relevant queries; you do not need a graph engine for typical traversals of depth ≤ 3 over user-scoped subgraphs of < 100K edges.

### 1.6 Decision matrix for nullalis specifically

| Criterion | Stay on pg+pgvector+memory_edges | Add AGE | Add Kuzu/Ladybug | Add Neo4j |
|---|---|---|---|---|
| Operational simplicity | **best** — one engine | medium (Postgres extension) | medium (embedded but new fork) | worst (new daemon) |
| Per-user tenant isolation | **best** (Postgres RLS, single-query) | medium | weak in embedded mode | enterprise feature |
| Traversal depth ≤ 3 | excellent if you index | comparable | excellent | excellent |
| Traversal depth > 5 | weak | weak (per Trendyol) | excellent | best |
| Vector colocation | **native** (pgvector) | possible | native | added in 5.11+ |
| Engineering cost to migrate | zero | weeks | months | months |
| Future-proof | very high (Postgres isn't going anywhere) | medium (AGE governance is thin) | low (Kuzu is archived) | high but commercial pressure |

**Verdict:** Stay on Postgres. The agent-memory field is not constrained by graph engine performance at the scale agent memories operate at (millions, not billions, of edges per tenant). It is constrained by *extraction quality, temporal correctness, and retrieval strategy* — none of which a dedicated graph engine helps with. See `docs.softwareseni.com/Postgres-as-AI-agent-substrate` and Hindsight's `Case Against External Vector DBs` (both 2026) for the same conclusion from production teams.

---

## Section 2 — Agentic memory frameworks

### 2.1 Graphiti / Zep — the canonical bi-temporal KG

[Graphiti](https://github.com/getzep/graphiti) is the open-source temporal graph engine inside Zep. The architecture, per the Zep paper ([arxiv 2501.13956](https://arxiv.org/abs/2501.13956)) and [Neo4j developer blog](https://neo4j.com/blog/developer/graphiti-knowledge-graph-memory/):

- **Three subgraphs**: Episode subgraph (raw events), Semantic Entity subgraph (extracted entities + edges), Community subgraph (Leiden-clustered).
- **Bi-temporal model**: every edge carries `(t_valid, t_invalid)` for "when this fact was true in the world" and `(t_created, t_expired)` for "when we learned it / when we superseded it." Both axes independent. Old facts are *invalidated*, never deleted.
- **Invalidation prompt**: on every new edge, an LLM call compares against the top-K semantically similar existing edges, identifies contradictions, and marks the loser `expired_at = now()`. Example: `Maria works_as junior_manager` is expired when `Maria works_as senior_manager` arrives ([Zep blog](https://blog.getzep.com/beyond-static-knowledge-graphs/)).
- **Custom entity + edge types** via Pydantic models (`extract_nodes.py`, `extract_edges.py` in the repo). Relations are SCREAMING_SNAKE.
- **Storage**: Neo4j or FalkorDB.
- **Bench**: 94.8% on Deep Memory Retrieval; cited 92% on LongMemEval bitemporal subset.

**Differences vs nullalis**: you have valid_at but not the second time axis; you do not run an invalidation prompt; you do not have community subgraphs. The SCREAMING_SNAKE convention, custom types, and the "ban conversational predicates" idea are *all also in Graphiti's prompt design philosophy* — Graphiti's `extract_edges.py` actively discourages low-information predicates although the explicit ban list is yours.

### 2.2 mem0 — flat-facts-first, optional graph

[mem0](https://github.com/mem0ai/mem0) (arxiv [2504.19413](https://arxiv.org/abs/2504.19413)) is the most popular agent-memory framework in 2026 by stars. Architecture:

- **Per-turn extraction** (not boundary-based): every user turn → "Distill Memories" single-pass LLM call → "Context Lookup" against top-K similar facts → dedupe (hash + semantic) → embed → store.
- **Three retrieval scorers fused**: BM25 + vector similarity + entity matching. This is the "Multi-Signal Retrieval" change in the 2026 mem0 update ([mem0 blog](https://mem0.ai/blog/state-of-ai-agent-memory-2026)).
- **Graph mode** (`Mem0^g`): optional layer that adds a property graph. Reported ~2pp lift on LoCoMo vs flat mode.
- **LoCoMo numbers**: Mem0 base ~68%, Mem0^g ~70%. Token efficiency: 6,956 retrieval tokens vs 26,000 full-context.

**Differences vs nullalis**: mem0 extracts per turn; you extract at boundaries. Per-turn means more LLM calls and more drift; boundary means denser extractions but bigger latency spikes. Both are defensible. mem0 has nothing like your `slot_intent` working-memory promotion. mem0's BM25+vector+entity fusion is *strictly stronger* than pure vector retrieval — worth porting.

### 2.3 MemGPT / Letta — virtual memory paging

[Letta docs](https://docs.letta.com/concepts/memgpt/) implement the original MemGPT paper ([arxiv 2310.08560](https://arxiv.org/abs/2310.08560)). Three tiers:

- **Core memory** — small in-context block, agent-edited via tool calls (RAM).
- **Recall memory** — searchable conversation history (disk cache).
- **Archival memory** — long-term, tool-queried (cold storage).

The agent itself executes function calls to move things between tiers. Letta is the productionization of this; agents *run inside Letta* as a service.

**Differences vs nullalis**: your `working_memory` slot system (open_loop / active_goal / decision / identity / temporal) is closer to MemGPT's "core memory" than to mem0's flat-facts approach. The crucial distinction: MemGPT lets the LLM edit core memory directly via tools every turn; nullalis promotes slots from extraction `slot_intent`. Your approach is less prone to drift but slower to adapt within a session. Neither is universally better.

### 2.4 Microsoft GraphRAG — community detection at scale

[GraphRAG docs](https://microsoft.github.io/graphrag/) and the official Microsoft Research blog. Pipeline:

1. Chunk text → "TextUnits."
2. LLM extracts entities + relationships + claims.
3. LLM-driven entity resolution merges duplicates.
4. **Leiden clustering** builds a community hierarchy.
5. LLM generates a summary per community (bottom-up).
6. At query time, the agent picks relevant communities + adds their summaries to context.

**Cost is the killer.** Per [LightRAG comparison](https://www.ragdollai.io/blog/lightrag-vector-rags-speed-meets-graph-reasoning-at-1-100th-the-cost): GraphRAG uses ~610,000 tokens per retrieval vs ~100 for LightRAG. GraphRAG also requires rebuilding the graph from scratch for new documents, making it impractical for write-heavy session memory.

**Relevance to nullalis**: don't adopt GraphRAG wholesale, but the *Leiden community summary* trick is portable. If you ever want a "what does this user care about overall" cold view, computing communities offline (dream cycle?) and summarizing them is the cheapest way to add global understanding.

### 2.5 LightRAG — the practical middle ground

[LightRAG](https://learnopencv.com/lightrag/) is the spiritual successor to GraphRAG. Same graph extraction, but:
- No community detection.
- Dual-level retrieval: entity-level + relationship-level.
- Incremental updates — union new docs into existing graph (~50% faster updates).
- Cost ~1/6000 of GraphRAG per retrieval call.

This is what the field has converged on. **Your architecture (entities + edges, vector-indexed, no community layer) is essentially LightRAG-shaped already.** That's a win.

### 2.6 Cognee — graph + vector poly-store

[Cognee](https://github.com/topoteretes/cognee) is the most production-ready open-source semantic memory layer. Notable features:

- **Cognify pipeline** (6 stages): classify → permissions → chunk → LLM entity/relation extraction → summarize → embed-and-commit.
- **Memify** — periodically prunes stale nodes, strengthens frequent connections, reweights edges based on usage, adds derived facts. This is *the* feature nullalis is missing.
- **Polystore**: pluggable graph backend (Neo4j, Memgraph, FalkorDB, Kuzu, NetworkX) + vector store (LanceDB, Chroma, Weaviate, pgvector).
- **14 retrieval modes**: classic RAG, graph-walk, chain-of-thought traversal, hybrid.

[Cognee + Memgraph integration](https://memgraph.com/blog/cognee-memgraph-integration-demo) shows the "graph engine purely for traversal indexing" pattern — exactly what you want.

### 2.7 HippoRAG — hippocampal indexing + Personalized PageRank

[HippoRAG paper (NeurIPS 2024, arxiv 2405.14831)](https://arxiv.org/abs/2405.14831). One-line pitch: build a KG, then at query time run Personalized PageRank with the query entities as seeds, and use the top-ranked entities to fetch passages.

- Up to **20% improvement on multi-hop QA** over SOTA.
- Single-step retrieval matches iterative retrieval (IRCoT) at **10-30× lower cost** and **6-13× faster**.
- HippoRAG 2 extends with denser graph + context-aware retrieval.

For nullalis, the PPR-over-the-edge-table trick is implementable as a recursive CTE on Postgres in tens of milliseconds for typical user subgraphs. **This is the single most evidence-backed retrieval improvement available.**

### 2.8 OpenAI ChatGPT memory — pragmatic, not graph-based

Per [llmrefs reverse-engineering analysis](https://llmrefs.com/blog/reverse-engineering-chatgpt-memory) and OpenAI's [help docs](https://help.openai.com/en/articles/8983136-what-is-memory):

- **Two layers**: saved memories (auto-written facts) + chat history summary.
- **No vector DB, no graph.** Just structured natural-language facts injected into the system prompt.
- 2026: Memory Sources feature shows which memory influenced each response. Projects partition memory.

OpenAI deliberately chose "boring text in the system prompt" over any sophisticated retrieval. They have GPT-5.5 to burn context on. Mortals with frontier-pricing constraints cannot. **Don't copy OpenAI here.**

### 2.9 Anthropic memory MCP server — knowledge graph at the protocol layer

The [official memory MCP server](https://www.pulsemcp.com/servers/modelcontextprotocol-knowledge-graph-memory) uses a knowledge graph (entities + relations + observations) that an agent reads/writes via MCP tools. Simple JSON file backend. Designed as a *demonstration* of the protocol, not a production system. The interesting move here is **memory as an MCP tool surface** — agents call `add_entity`, `add_observation`, `search_nodes` etc. Worth considering as an *interface* nullalis could expose to other agents.

### 2.10 AriGraph (2024-2025)

[AriGraph paper (arxiv 2407.04363)](https://arxiv.org/abs/2407.04363). Constructs a memory graph mixing semantic + episodic vertices. Designed for text-game agents (TextWorld). Beats RL baselines and unstructured memory significantly. The architectural insight that **episodic vertices live in the same graph as semantic vertices** (rather than separate stores) is increasingly common — see PersonalAI below.

### 2.11 PersonalAI (2025-2026)

[PersonalAI: arxiv 2506.17001](https://arxiv.org/abs/2506.17001) and PersonalAI 2.0: [arxiv 2605.13481](https://arxiv.org/abs/2605.13481). Builds on AriGraph with **hybrid graph design supporting both standard edges and two types of hyper-edges**. Retrieval: A*, WaterCircles traversal, beam search, hybrid. Evaluated on TriviaQA, HotpotQA, DiaASQ (extended with temporal annotations and contradictions). Shows different memory/retrieval configurations win on different tasks — there is no universal best, but graph traversal beats flat retrieval consistently for multi-hop and temporal.

### 2.12 A-Mem — Zettelkasten for agents

[A-Mem (NeurIPS 2025, arxiv 2502.12110)](https://arxiv.org/abs/2502.12110). Each memory is a *note* with attributes (context, keywords, tags). New memories trigger updates to existing notes' contextual representations — a true Zettelkasten dynamic. Beats SOTA baselines on 6 foundation models. This is what your `wiki memory` reference in your memory index alludes to, and it's a stronger pattern than flat-facts.

### 2.13 HyperMem — current LoCoMo SOTA (April 2026)

[HyperMem (arxiv 2604.08256)](https://arxiv.org/abs/2604.08256). Hypergraph memory — hyperedges group related facts across multiple episodes. Three levels: topics, episodes, facts. **92.73% LLM-as-judge on LoCoMo.** Note your 90.17% on Cat 1-4 is competitive with this; HyperMem reports overall whereas you report 1-4.

### 2.14 LiCoMemory — temporal SOTA (Nov 2025 / Jan 2026)

[LiCoMemory (arxiv 2511.01448)](https://arxiv.org/abs/2511.01448). "CogniGraph" — hierarchical graph as semantic indexing layer, not static repository. Temporal + hierarchy-aware search with integrated reranking. **Beats Mem0, Zep, A-Mem, LoCoMo-RAG** on both LoCoMo and LongMemEval. 73.8% accuracy / 76.6% recall on LongMemEval with GPT-4o-mini, and 10-40% latency reduction.

### 2.15 ENGRAM — token-frugal SOTA (Nov 2025 / Feb 2026)

[ENGRAM (arxiv 2511.12960)](https://arxiv.org/abs/2511.12960). Three canonical types (episodic, semantic, procedural), single router + retriever. **71.4% LLM-as-judge on LongMemEval using ~1.0-1.2K tokens per query vs 101K full-context** — a 99% token reduction while *beating* full-context by 15 points. This shape (typed memories, router, dense retrieval) is the simplest design that works at SOTA-adjacent quality.

### 2.16 Supermemory — production SOTA (2026)

[Supermemory research](https://supermemory.ai/research/). 99% on LongMemEval_S using experimental "ASMR" (Agentic Search and Memory Retrieval) — 3 parallel reader agents extracting across 6 vectors (Personal, Preferences, Events, Temporal, Updates, Assistant Info). Production: 85.4% LongMemEval, sub-300ms recall, 100B+ tokens/month.

### 2.17 Claude Code's memory

Per [Penligent's reverse engineering](https://www.penligent.ai/hackinglabs/inside-claude-code-the-architecture-behind-tools-memory-hooks-and-mcp/) and inspection of `/Users/nova/Desktop/claude-code/`: Claude Code uses **CLAUDE.md hierarchy** (project/user/global) + MCP tool surface for richer memory. No knowledge graph internally. Simple, file-based, hierarchical. Their "memory" is really a layered system-prompt augmentation. Closer to OpenAI's pragmatism than to Graphiti's structure.

### 2.18 Comparative summary table

| Framework | Storage | Extraction | Schema | Retrieval | Temporal | LoCoMo |
|---|---|---|---|---|---|---|
| Graphiti/Zep | Neo4j/FalkorDB | per-episode | entities + edges + episodic + community | hybrid + Leiden communities | bi-temporal w/ invalidation prompt | 94.8% DMR |
| mem0 | vector store + optional graph | per-turn | flat facts + optional graph | BM25 + vector + entity fusion | weak | ~70% |
| Letta/MemGPT | postgres/sqlite | tool-driven, agent-controlled | unstructured blocks | direct + tool search | weak | n/a |
| GraphRAG | Neo4j typically | one-shot batch | entities + relations + communities | Leiden community summaries | none | n/a |
| LightRAG | various | per-doc | entities + relations | dual-level (entity + relationship) | none | n/a |
| Cognee | poly-store (KG + vector) | cognify pipeline | entities + relations + summaries | 14 modes incl. graph walk | basic | n/a |
| HippoRAG | KG + vector | per-doc | entities + relations | Personalized PageRank | none | n/a |
| AriGraph | in-memory graph | per-step | semantic + episodic vertices | associative graph walk | basic | n/a (text games) |
| PersonalAI 2.0 | hybrid graph (edges + hyperedges) | per-doc | edges + 2 hyperedge types | A*/WaterCircles/beam | hybrid | n/a |
| A-Mem | vector + linking | per-event | notes (Zettelkasten) | similarity + link traversal | weak | n/a |
| HyperMem | hypergraph | per-session | topics/episodes/facts + hyperedges | hyperedge-aware | basic | **92.73%** |
| LiCoMemory | "CogniGraph" hierarchical | per-session | entities + relations + hierarchy | temporal + hierarchy + rerank | **strong** | new SOTA |
| ENGRAM | vector + typed | per-turn | episodic/semantic/procedural | typed dense + set fusion | basic | competitive |
| Supermemory | hybrid | ASMR parallel readers | 6-vector schema | hybrid + reranker | strong | 85.4% prod / 99% exp |
| **nullalis (V1.14.8)** | **Postgres + pgvector + memory_edges** | **boundary (Pass A/C/session-end)** | **entities + edges + slot_intent (SCREAMING_SNAKE)** | **vector (no graph traversal yet)** | **valid_at only, no invalidation** | **90.17% Cat 1-4** |

---

## Section 3 — Recent papers worth reading

1. **HyperMem: Hypergraph Memory for Long-Term Conversations** ([arxiv 2604.08256](https://arxiv.org/abs/2604.08256), Apr 2026). Hyperedges over (topic, episode, fact) triple. **92.73% on LoCoMo**. Read if you want to know what the LoCoMo ceiling looks like.

2. **LiCoMemory: Lightweight and Cognitive Agentic Memory for Efficient Long-Term Reasoning** ([arxiv 2511.01448](https://arxiv.org/abs/2511.01448), Nov 2025). CogniGraph as a semantic indexing layer (not storage). New SOTA on temporal LongMemEval. **Most aligned with your architecture philosophy.** Mandatory read.

3. **ENGRAM: Effective, Lightweight Memory Orchestration for Conversational Agents** ([arxiv 2511.12960](https://arxiv.org/abs/2511.12960), Nov 2025). Three typed memories + single router. 99% token reduction with +15 points over full-context. Argues "simple typed retrieval beats complex graph machinery." Read for the counter-argument to everything else here.

4. **PersonalAI 2.0** ([arxiv 2605.13481](https://arxiv.org/abs/2605.13481), May 2026). Hybrid edges + hyperedges; planning-mechanism-enhanced retrieval. Confirms hypergraphs win on multi-hop + temporal jointly.

5. **Mem0: Building Production-Ready AI Agents with Scalable Long-Term Memory** ([arxiv 2504.19413](https://arxiv.org/abs/2504.19413), Apr 2025). The reference architecture paper for the production-mem0 era. BM25+vector+entity fusion details.

6. **Zep: A Temporal Knowledge Graph Architecture for Agent Memory** ([arxiv 2501.13956](https://arxiv.org/abs/2501.13956), Jan 2025). The canonical bi-temporal paper. Read for the invalidation prompt.

7. **A-Mem: Agentic Memory for LLM Agents** (NeurIPS 2025, [arxiv 2502.12110](https://arxiv.org/abs/2502.12110)). Zettelkasten for agents — dynamic re-linking of memories.

8. **AriGraph: Learning Knowledge Graph World Models with Episodic Memory for LLM Agents** ([arxiv 2407.04363](https://arxiv.org/abs/2407.04363), Jul 2024 - May 2025 v3). KG world models for game agents; episodic + semantic in one graph.

9. **HippoRAG: Neurobiologically Inspired Long-Term Memory for Large Language Models** (NeurIPS 2024, [arxiv 2405.14831](https://arxiv.org/abs/2405.14831)). PPR over KG. 20% gain on multi-hop. **Cheapest retrieval upgrade you can make.**

10. **PersonalAI: A Systematic Comparison of Knowledge Graph Storage and Retrieval Approaches for Personalized LLM agents** ([arxiv 2506.17001](https://arxiv.org/abs/2506.17001), Jun 2025). Best ablation study of retrieval modes (A*, beam, WaterCircles).

11. **Graph-based Agent Memory: Taxonomy, Techniques, and Applications** ([arxiv 2602.05665](https://arxiv.org/html/2602.05665v1), Feb 2026). The current canonical survey. **Read first if you only read one survey.**

12. **Memory for Autonomous LLM Agents: Mechanisms, Evaluation, and Emerging Frontiers** ([arxiv 2603.07670](https://arxiv.org/abs/2603.07670), Mar 2026). Companion survey covering eval methodology.

13. **LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory** (ICLR 2025, [arxiv 2410.10813](https://arxiv.org/abs/2410.10813)). The benchmark you need to add. 5 ability dimensions: extraction, multi-session, temporal, updates, abstention.

14. **LongMemEval-V2** ([arxiv 2605.12493](https://arxiv.org/abs/2605.12493), May 2026). Extension toward "experienced colleague" web-agent setting. Forward-looking but worth tracking.

15. **Empowering LLM Agents with Trainable Graph Memory** ([arxiv 2511.07800](https://arxiv.org/pdf/2511.07800), Nov 2025). Edge/node weights learned via RL signal — points at where the field is heading after static-KG approaches plateau.

16. **HGMem: Improving Multi-step RAG with Hypergraph-based Memory for Long-Context Complex Relational Modeling** ([arxiv 2512.23959](https://arxiv.org/html/2512.23959v2), late 2025). Hypergraphs for multi-step RAG.

17. **BEAM: Beyond a Million Tokens** (ICLR 2026). 100 conversations × 10M tokens. Benchmark for when LongMemEval gets saturated.

---

## Section 4 — Where nullalis stands vs the field

### 4.1 Where you are ahead

**Boundary-based extraction at distillation moments (Pass A / Pass C / session-end).** Almost everyone else does per-turn (mem0, A-Mem, ENGRAM) or batch-after-the-fact (GraphRAG, Cognee cognify). Your approach matches LiCoMemory's "KG as semantic indexing layer, not static repository" philosophy and is fundamentally cheaper at scale than per-turn while preserving more structural coherence than batch. **This is a genuinely strong architectural bet.** The closest analog in the wild is Supermemory's ASMR (parallel readers at session boundaries) — yours is the single-reader version.

**Banned conversational predicates list (SAID, MENTIONED, ASKED, GREETED, ACKNOWLEDGED).** I could not find an explicit, public, named "banned predicate list" in any other open-source memory framework. Graphiti's prompt design implicitly discourages low-info predicates but does not enumerate them. This is **a small but real prompt-engineering edge** — and it's why your graph stays semantically dense rather than polluted with chatter triples.

**Per-conversation tenant isolation (F-G4.1).** Standard in *production SaaS* (Supermemory, Zep cloud do this), but among open-source frameworks most are single-tenant. Postgres RLS makes this near-free for you.

**Single binary in Zig.** Operational simplicity nobody else has. Letta is a JVM-style runtime; mem0 is a Python lib with N backends; Cognee is Python + N services. Yours boots, has one process, ships.

**slot_intent → working_memory promotion.** This is *unusual*. The closest published pattern is MemGPT's tool-driven core-memory editing — but MemGPT puts the LLM in the driver's seat every turn, which is expensive and drifty. Your "extraction emits a slot_intent that gets promoted to working memory" is a cheaper, more deterministic version of the same idea, and structurally similar to ENGRAM's "typed memory router" — except ENGRAM types are (episodic, semantic, procedural) while yours are (open_loop, active_goal, decision, identity, temporal). Yours map closer to the **GTD / coaching ontology** and that's a genuine differentiator.

**90.17% on LoCoMo Cat 1-4.** Competitive with HyperMem's 92.73% overall and within striking distance of Supermemory production (85.4% LongMemEval — different bench, but same range). For a single-binary, single-developer system, this is excellent.

### 4.2 Where you are at parity

- **Entity + edge schema with SCREAMING_SNAKE relations.** Same as Graphiti, mem0^g, Cognee.
- **Vector embeddings via pgvector + e5-large-instruct.** Standard. e5-large-instruct is a defensible 2026 choice; alternative would be `BAAI/bge-m3` or OpenAI `text-embedding-3-large`.
- **Mem0-style regex fallback when JSON parse fails.** This is in mem0 source and increasingly common.
- **Filesystem workspace + markdown mirror.** Letta and Cognee both do filesystem; the markdown mirror is closer to Claude Code's pattern.
- **valid_at on edges.** You have one of the two bi-temporal axes.

### 4.3 Where you are behind

**Bi-temporal invalidation.** You have `valid_at` but no `invalid_at` and no invalidation prompt. Graphiti and PersonalAI 2.0 both do this and both report large temporal-reasoning lift. **This is the biggest correctness gap.** Without it, contradictions accumulate silently — your KG slowly becomes a graveyard of stale facts.

**Multi-hop graph traversal at retrieval time.** You retrieve by vector only (as far as I can tell from your description). HippoRAG's PPR, AriGraph's associative walk, PersonalAI's beam search, LiCoMemory's hierarchy-aware search all use the graph at query time. You have a graph layer but you're not using it at retrieval. **This is the biggest retrieval gap.**

**Hybrid scoring (BM25 + vector + entity).** Mem0 does this; you're vector-only. ~3-5pp on average from this alone in mem0's ablations.

**Edge reweighting / "memify."** Cognee's memify pass strengthens frequent connections and prunes stale ones. Your dream cycle (L7) is the natural home for this but I don't see it described doing edge reweighting yet.

**Community detection / global summaries.** GraphRAG and Graphiti have them; you don't. Probably not worth the cost, but worth knowing you don't.

**Hypergraphs.** HyperMem and PersonalAI 2.0 both use hyperedges; you don't. This is the cutting edge — not a glaring miss but the field is moving here.

**LongMemEval evaluation surface.** You only bench on LoCoMo. The frontier is on LongMemEval (and BEAM). You're flying blind on the 2026 SOTA conversation because you can't compare numbers.

**Graph density validation in production.** Your own note: `boundary.complete entities=0 edges=0` on two observed fires. **This is the most urgent operational gap** — without telemetry on density, you cannot detect silent regressions.

### 4.4 Direct head-to-head matrix

| Capability | nullalis V1.14.8 | Graphiti | mem0 | LiCoMemory | HyperMem | ENGRAM | Supermemory |
|---|---|---|---|---|---|---|---|
| Bi-temporal w/ invalidation | partial (valid_at only) | **yes** | no | partial | basic | no | yes (prod) |
| Graph traversal at retrieval | **no** | yes (subgraph) | optional | yes (hierarchy) | yes (hyperedge) | no | yes |
| Hybrid scoring (BM25+vec+entity) | vector only | hybrid | **yes** | yes + rerank | yes | dense only | yes + rerank |
| Per-tenant isolation | **yes (Postgres RLS)** | yes (cloud) | partial | partial | n/a | n/a | yes |
| Working-memory slots / typed memory | **yes (GTD-ish)** | no | no | partial | no | yes (3-type) | yes (6-type) |
| Hypergraph | no | no | no | hierarchy ~= proxy | **yes** | no | no |
| Edge reweighting | no (planned in dream) | weak | hash dedup | no | no | no | yes |
| Distillation-boundary extraction | **yes** | per-episode | per-turn | per-session | per-session | per-turn | per-session (parallel) |
| Production single-binary | **yes (Zig)** | no (Python) | no | no | no | no | no |
| Public LoCoMo number | **90.17% C1-4** | n/a here | ~70% | new SOTA | 92.73% | competitive | n/a |
| Public LongMemEval number | **none** | ~92% | ~70% | 73.8% | n/a | 71.4% | 85.4% prod / 99% exp |

---

## Section 5 — Concrete upgrade recommendations for nullalis

Ranked by leverage. Each item has rough effort estimate (S/M/L) and confidence (Low/Med/High).

### 5.1 R1 (S, High) — Ship graph density telemetry today

Before any other change. Every `boundary.complete` log line must include `entities`, `edges`, `density_per_1k_input_tokens`, `slot_intent_count`, `invalidation_count`. Wire an alert if a `Pass C` or `session-end` boundary returns `edges=0` on a session with >5K tokens. Cost: one afternoon. **Without this, you cannot evaluate any other change here.**

### 5.2 R2 (M, High) — Add bi-temporal `invalid_at` + invalidation pass

Schema change: add `invalid_at TIMESTAMPTZ`, `expired_at TIMESTAMPTZ`, `superseded_by_edge_id BIGINT` columns to `memory_edges`. On every Pass C extraction, after the extraction LLM call, run a second small call:

```
You are a fact-invalidation judge. Given:
NEW EDGES: {newly extracted}
EXISTING SIMILAR EDGES: {top-K from vector similarity, scoped to user}
Identify which existing edges are contradicted or superseded by the new ones.
Return JSON: [{"edge_id": ..., "superseded_by_new_fact": "..."}].
```

Mark the loser with `expired_at = now()` and `superseded_by_edge_id`. Never delete.

Retrieval defaults to `WHERE expired_at IS NULL`. Time-travel queries become `WHERE valid_at <= $1 AND (invalid_at IS NULL OR invalid_at > $1) AND (expired_at IS NULL OR expired_at > $now)`.

Evidence: Graphiti reports this is the single biggest contributor to their LongMemEval temporal-reasoning lead ([Zep blog](https://blog.getzep.com/beyond-static-knowledge-graphs/), [arxiv 2501.13956](https://arxiv.org/abs/2501.13956)). PersonalAI 2.0 replicates the win.

**Cost note:** adds one LLM call per Pass C. Use a small/cheap model (Haiku 3.5 / Gemini Flash) — invalidation is a JSON comparison, not a creative task.

### 5.3 R3 (M, High) — Add graph traversal to retrieval (HippoRAG-style PPR)

You have a `memory_edges` table. At retrieval time, instead of pure vector search:

1. Take user query → embed → seed the top-K entity nodes by vector similarity.
2. Run Personalized PageRank from those seeds over the user's subgraph, depth 3, damping 0.85.
3. Re-rank fetched facts by `α·vector_sim + β·ppr_score + γ·recency_decay`.

PPR over a user subgraph of < 100K edges is tens of milliseconds in a recursive CTE in Postgres. HippoRAG reports +20% on multi-hop QA over SOTA. Your Cat 2 (multi-hop) was the area you specifically called out improving — this is the lever.

Alternative simpler version: 2-hop neighborhood expansion. Take top-K vector-similar nodes, fetch all 1-2-hop neighbors via the edge table, score the resulting fact set. Strictly weaker than PPR but trivial to implement first.

Evidence: HippoRAG paper, PersonalAI ablations, AriGraph results all confirm graph-aware retrieval > vector-only on multi-hop.

### 5.4 R4 (S, High) — Add BM25 + entity-overlap to scoring

Postgres has full-text (`tsvector`). Compute three scores per candidate fact:
- `vector_sim` (you have this).
- `bm25_score` via `ts_rank(to_tsvector('english', fact), plainto_tsquery($q))`.
- `entity_overlap` = |entities_in_query ∩ entities_on_edge| / |entities_in_query|.

Fuse with `reciprocal_rank_fusion` or weighted sum. Mem0's 2026 update reports this is one of their two architectural lifts. ~3-5pp generally.

### 5.5 R5 (M, Med) — Add LongMemEval to your bench surface

You ship LoCoMo. Add LongMemEvalₛ (115K tokens, 500 questions) immediately and LongMemEvalₘ (1.5M tokens) when you can afford the eval cost. This is where the 2026 SOTA conversation is happening. Without a LongMemEval number you cannot say "we're better than Zep/Graphiti/Supermemory" with any rigor.

LongMemEval breaks down into 5 abilities (extraction, multi-session, temporal, knowledge updates, abstention). The category-level numbers tell you where your real weaknesses are — e.g., "abstention" measures whether your agent correctly says "I don't know" rather than fabricating. Graphiti and Supermemory both struggle with abstention; your boundary architecture might actually be advantaged here.

Source: [LongMemEval ICLR 2025 paper](https://arxiv.org/abs/2410.10813), [GitHub xiaowu0162/LongMemEval](https://github.com/xiaowu0162/LongMemEval).

### 5.6 R6 (M, Med) — Edge reweighting in dream cycle (L7)

Cognee's memify is the model. In your dream cycle:
- Count edge "hit count" (incremented every time the edge appears in a retrieval set used by the agent).
- Apply exponential decay (half-life of N days).
- Edges with `confidence × recency × hit_count` below threshold get marked `archived = true` (not deleted — never delete).
- Frequently-co-retrieved entities can be considered for **synthetic summary edges** (e.g., "Mohammad ROUTINELY_DISCUSSES nullalis"). This is GraphRAG's community-summary idea reduced to per-pair.

This is the path to a *self-improving* memory rather than an accumulating one. Without it, KGs decay into noise; with it, they get sharper over time. A-Mem's dynamic re-linking is the same family of ideas.

### 5.7 R7 (S, Med) — Custom entity + edge type ontology via Zig structs

Graphiti's killer extension feature is **Pydantic-typed custom entities/edges**. The LLM is instructed to classify entities into provided types and edges into provided relation types per-type-pair. For nullalis specifically: define types like `Person`, `Project`, `Decision`, `Routine`, `Preference`, `Goal` and an edge_type_map like `(Person, Project) → [OWNS, CONTRIBUTES_TO, ABANDONED]`. Even a small ontology constrains the LLM toward higher graph density and lower duplicate-relation noise.

This is essentially formalizing what your banned-predicate list already does negatively — give the LLM a positive whitelist per type-pair.

### 5.8 R8 (S, High) — Make your extraction prompt deterministic on count

Mem0's extraction prompts include phrases like "extract at least N distinct facts" and "if the conversation contains M speakers, ensure facts are attributed correctly." A common cause of `edges=0` in extraction is the LLM deciding the input is "small talk." Add an explicit lower-bound + a "if no factual content, return an empty list with reason field." That gives you observability into *why* you got zero, not just *that* you did.

### 5.9 R9 (M, Low) — Consider hypergraphs (later)

HyperMem and PersonalAI 2.0 show hypergraphs win on the hardest LoCoMo categories. But your edge table is fine until you've spent the easier R2/R3/R4 wins. When you do this, the cheap implementation is a `hyperedges(id, fact, valid_at, …)` table + `hyperedge_members(hyperedge_id, entity_id, role)` join table. SCREAMING_SNAKE relation_type generalizes naturally to "hyperedge_type" on the hyperedge itself.

### 5.10 R10 (S, Med) — Things to STOP doing

- **Stop using two LLM calls per boundary if extraction quality is consistent.** Your extraction (graphiti-shaped JSON) and hydration (Claude-Code-shaped XML) are different *outputs* but they can share an extraction step. Try a single structured-output call with both `entities/edges` and `summary/focus/decisions/...` as parts of one schema. Saves ~40% of boundary cost. Re-test that quality holds.
- **Stop ignoring zero-edge fires.** R8 covers the *why*; treat any zero-edge Pass C as a P2 incident, not a normal log.
- **Don't introduce Apache AGE, Neo4j, Kuzu, or any second engine.** The justification doesn't exist in 2026. The field is converging the other direction — see [The Case Against External Vector DBs for Agent Memory](https://hindsight.vectorize.io/blog/2026/05/12/case-against-external-vector-dbs-agent-memory) and [How Postgres Became the AI Agent Substrate](https://www.softwareseni.com/how-postgres-became-the-ai-agent-substrate-for-memory-branching-and-modern-hosting/).
- **Don't chase GraphRAG community detection.** Cost-prohibitive (6000× more tokens than LightRAG) and updates require rebuilds. The LightRAG / your-current-shape is the right shape.

### 5.11 Suggested execution order

If I were ranking by next-30-days impact-per-effort for V1.14.9 / V1.15:

1. **R1** (density telemetry) — this week, blocking everything else.
2. **R8** (deterministic-count extraction prompt + empty-result reason) — same change as R1, basically.
3. **R4** (BM25 + entity overlap fusion) — one PR, immediate measurable lift.
4. **R5** (LongMemEval added to bench) — needed before measuring R2/R3 wins credibly.
5. **R2** (bi-temporal invalidation) — biggest correctness gain, but only measurable on LongMemEval temporal subset, so do after R5.
6. **R3** (PPR-based retrieval) — biggest multi-hop gain, hard to validate without R5.
7. **R7** (custom entity ontology) — incremental quality lever once R1 + R8 confirm density.
8. **R6** (edge reweighting in dream cycle) — V1.15+ work.
9. **R9** (hypergraphs) — V1.16+, after R2/R3/R4 wins are banked.

### 5.12 What this gets you, plausibly

If R2 + R3 + R4 + R7 all land:
- LoCoMo Cat 1-4 stays ≥ 90% (these don't hurt that).
- LoCoMo Cat 5 (temporal) likely lifts 5-10pp from bi-temporal invalidation alone.
- LongMemEval baseline reasonable target: **75-80% overall** with `gpt-4o-mini`-tier judge, putting you above mem0, near LiCoMemory, behind Supermemory production but in the same conversation. With a stronger judge model the absolute number moves but the relative position holds.
- Token economics: your boundary approach + R4 fusion should land in the 1-3K tokens-per-retrieval band — competitive with ENGRAM's 1.0-1.2K and far below GraphRAG's 610K.

That gets nullalis into the 2026 SOTA conversation on agent memory with no second database engine, no Python service, no exotic infrastructure — just Zig, Postgres, pgvector, and the same `memory_edges` table you have today plus three new columns and a few new prompts.

---

## Appendix — Sources referenced

**Graph databases:**
- [Apache AGE](https://age.apache.org/) and [AGE vs Neo4j](https://dev.to/pawnsapprentice/apache-age-vs-neo4j-battle-of-the-graph-databases-2m4)
- [Trendyol: Migrating Graph Operations to Apache AGE](https://medium.com/trendyol-tech/migrating-graph-operations-to-apache-age-from-writes-to-reads-3b8334628e1c) (April 2026)
- [Kuzu DB archived](https://biggo.com/news/202510130126_KuzuDB-embedded-graph-database-archived) (October 2025)
- [Neo4j alternatives in 2026 (ArcadeDB)](https://arcadedb.com/blog/neo4j-alternatives-in-2026-a-fair-look-at-the-open-source-options/)
- [FalkorDB vs Memgraph vs Neo4j benchmark](https://aimultiple.com/graph-databases)
- [RyuGraph (Kuzu fork)](https://github.com/predictable-labs/ryugraph)
- [Postgres as AI agent substrate](https://www.softwareseni.com/how-postgres-became-the-ai-agent-substrate-for-memory-branching-and-modern-hosting/)
- [Case Against External Vector DBs for Agent Memory](https://hindsight.vectorize.io/blog/2026/05/12/case-against-external-vector-dbs-agent-memory)

**Frameworks:**
- [Graphiti GitHub](https://github.com/getzep/graphiti) and [Graphiti welcome docs](https://help.getzep.com/graphiti/getting-started/welcome)
- [Graphiti custom entity/edge types docs](https://help.getzep.com/graphiti/core-concepts/custom-entity-and-edge-types)
- [Graphiti extract_nodes.py source](https://github.com/getzep/graphiti/blob/5a67e660dce965582ba4b80d3c74f25e7d86f6b3/graphiti_core/prompts/extract_nodes.py)
- [Zep "Beyond Static Knowledge Graphs"](https://blog.getzep.com/beyond-static-knowledge-graphs/)
- [Neo4j: Graphiti — Knowledge Graph Memory](https://neo4j.com/blog/developer/graphiti-knowledge-graph-memory/)
- [mem0 GitHub](https://github.com/mem0ai/mem0) and [State of AI Agent Memory 2026](https://mem0.ai/blog/state-of-ai-agent-memory-2026)
- [Letta docs / MemGPT](https://docs.letta.com/concepts/memgpt/)
- [MemGPT vs Letta vs mem0 (vectorize.io)](https://vectorize.io/articles/mem0-vs-letta)
- [Microsoft GraphRAG docs](https://microsoft.github.io/graphrag/)
- [LightRAG explanation](https://learnopencv.com/lightrag/) and [LightRAG vs GraphRAG cost analysis](https://www.ragdollai.io/blog/lightrag-vector-rags-speed-meets-graph-reasoning-at-1-100th-the-cost)
- [Cognee GitHub](https://github.com/topoteretes/cognee) and [Cognee + Memgraph integration](https://memgraph.com/blog/cognee-memgraph-integration-demo)
- [Cognee memory architecture](https://www.cognee.ai/blog/fundamentals/how-cognee-builds-ai-memory)
- [Supermemory research](https://supermemory.ai/research/)
- [Anthropic memory MCP server](https://www.pulsemcp.com/servers/modelcontextprotocol-knowledge-graph-memory)
- [ChatGPT memory reverse-engineered](https://llmrefs.com/blog/reverse-engineering-chatgpt-memory) and [OpenAI memory FAQ](https://help.openai.com/en/articles/8590148-memory-faq)
- [Inside Claude Code architecture](https://www.penligent.ai/hackinglabs/inside-claude-code-the-architecture-behind-tools-memory-hooks-and-mcp/)

**Papers (arxiv):**
- Zep / Graphiti: [2501.13956](https://arxiv.org/abs/2501.13956)
- mem0: [2504.19413](https://arxiv.org/abs/2504.19413)
- MemGPT: [2310.08560](https://arxiv.org/abs/2310.08560)
- AriGraph: [2407.04363](https://arxiv.org/abs/2407.04363)
- A-Mem: [2502.12110](https://arxiv.org/abs/2502.12110)
- HippoRAG: [2405.14831](https://arxiv.org/abs/2405.14831)
- LongMemEval: [2410.10813](https://arxiv.org/abs/2410.10813) and v2 [2605.12493](https://arxiv.org/abs/2605.12493)
- LiCoMemory: [2511.01448](https://arxiv.org/abs/2511.01448)
- ENGRAM: [2511.12960](https://arxiv.org/abs/2511.12960)
- HyperMem: [2604.08256](https://arxiv.org/abs/2604.08256)
- PersonalAI: [2506.17001](https://arxiv.org/abs/2506.17001) and PersonalAI 2.0: [2605.13481](https://arxiv.org/abs/2605.13481)
- Graph-based Agent Memory survey: [2602.05665](https://arxiv.org/html/2602.05665v1)
- LoCoMo: [2402.17753](https://arxiv.org/abs/2402.17753)
- Memory for Autonomous LLM Agents (survey): [2603.07670](https://arxiv.org/abs/2603.07670)
- Trainable Graph Memory: [2511.07800](https://arxiv.org/pdf/2511.07800)
- HGMem: [2512.23959](https://arxiv.org/html/2512.23959v2)

**Benchmarks:**
- [LoCoMo project page](https://snap-research.github.io/locomo/)
- [LongMemEval project page](https://xiaowu0162.github.io/long-mem-eval/)
- [LongMemEval GitHub](https://github.com/xiaowu0162/LongMemEval)
- [Awesome-GraphMemory (DEEP-PolyU)](https://github.com/DEEP-PolyU/Awesome-GraphMemory)
