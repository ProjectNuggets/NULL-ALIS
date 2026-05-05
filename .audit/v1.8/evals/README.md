# V1.8-6 — Adversarial eval suite (CI ship gate)

Drives the gateway with curated prompts, snapshots PG memory state pre/post each
corpus, and asserts deltas against `expected.json`. Output: per-corpus + overall
F1 score. Use as the V1.8 ship gate: every commit must improve F1 on its target
corpus and not regress others by >5%.

## Layout

```
.audit/v1.8/evals/
├── prompt_corpus/        # 5 corpora, ~5 prompts each (v1)
│   ├── identity_writes.txt
│   ├── preference_changes.txt
│   ├── multi_entity.txt
│   ├── relational_queries.txt
│   └── long_context_pass_c.txt
├── expected.json         # target assertions per corpus
├── run_eval.sh           # driver + scorer
├── README.md             # you are here
└── results/              # per-run output (JSON + summary.txt)
```

## Run

```bash
# All 4 fast corpora (skip Pass C):
.audit/v1.8/evals/run_eval.sh --quick

# Full 5 corpora (includes Pass C — needs gateway restart cycle, ~30+ min):
.audit/v1.8/evals/run_eval.sh

# Single corpus:
.audit/v1.8/evals/run_eval.sh --corpus preference_changes

# Tag results as a sprint baseline:
.audit/v1.8/evals/run_eval.sh --baseline
```

## Output

Each run writes:
- `results/<TAG>-<corpus>.json` — per-corpus deltas + assertion results + F1
- `results/<TAG>-summary.txt` — compact table + overall F1
- `results/<TAG>-<corpus>/T*.sse` `.reply` `.snap.json` — raw per-prompt artifacts

## Baseline @ sha `ad71bed` (2026-05-05)

| corpus | F1 | passed/total | What baseline tells us |
|---|---|---|---|
| identity_writes | 0.818 | 9/11 | LLM extraction works for single-fact prose; edge dedup against existing state inflates "no new edge"; embedding coverage 52% (G-C confirms) |
| preference_changes | 0.571 | 4/7 | **0 supersede, 0 judge_resolve** — G-B confirms, V1.8-1 closes |
| multi_entity | 0.500 | 3/6 | entity_delta=1 (target 8) — G-E + G-A confirm; V1.8-4 cheap deterministic closes |
| relational_queries | 1.000 | 1/1 | Limited assertion coverage in v1; v2 should add tool-call observability |
| **TOTAL** | **0.680** | **17/25** | Sprint goal: lift to ≥80% by V1.8 ship gate |
| long_context_pass_c | (deferred) | — | Audit ran in V1.8-7; archive write gap (V1.8-5) is the open item |

## Expected trajectory as V1.8 ships

Per build sequence in `docs/v1.8-sprint-lock.md`:

| After commit | Expected lift |
|---|---|
| **V1.8-1** (judge wire) | preference_changes 0.571 → ~0.85 (supersede + judge events fire) |
| **V1.8-2** (vector coverage) | identity_writes 0.818 → 1.000 (embedding pct → 100%) |
| **V1.8-3** (forget cascade) | new "forget" assertions can be added; doesn't move existing F1 |
| **V1.8-5** (prompts + archive) | long_context_pass_c 0 → 1 compaction_summary key per Pass C fire |
| **V1.8-4** (cheap deterministic) | multi_entity 0.500 → ~0.85 (entity coverage from prose) |
| **V1.8-9** (identity profile) | (cross-session recall — needs new corpus in v2) |
| **target** | overall ≥0.80 across all 5 corpora |

## Schema (v2 — V1.9-8)

Each corpus has its own `test_user_id`:

| Corpus | User ID | Notes |
|---|---|---|
| `identity_writes` | 7771 | isolated |
| `preference_changes` | 7772 | isolated |
| `multi_entity` | 7773 | shared with relational_queries (depends_on relationship) |
| `relational_queries` | 7773 | depends on multi_entity in same lineage |
| `long_context_pass_c` | 7775 | isolated |

**Why per-corpus users:** v1 ran every corpus against user 7777, so by run 2 the
entity coreference (V1.6 cmt8) had de-duplicated everything against existing
rows — making `entities_delta` and `event_edge_added_delta` underestimate
reality. F1 was contamination-noise-floored; v2 fixes this.

**Effect on baselines:** v1 baselines (e.g. `baseline-b97960c-...` at F1=0.846)
are NOT directly comparable to v2 baselines. v2 expected to score higher on
`multi_entity` and `identity_writes` (which both involve entity-creation
counts). Document v2 baselines from scratch.

**No explicit provisioning needed.** Gateway auto-provisions on first
`/chat/stream` call with `X-Zaki-User-Id`. Users 7771–7775 come into being on
first run.

## Caveats (v2)

1. **Pass C corpus skipped in `--quick`**: needs config change + gateway restart.
   Run full suite when validating V1.8-5.
2. **LLM non-determinism**: assertions use COUNT-deltas, not text matches. Multiple
   runs of the same corpus may differ by ±1 on edge counts. Tune target thresholds
   if you see consistent close-misses.
3. **Limited assertion vocabulary**: supports messages/memories/entities/edges
   counts, embedding coverage, entity-by-name, edge-by-predicate, event-type-deltas,
   compaction_summary keys. Add more assertion kinds in `run_eval.sh::run_corpus`
   as needed.
4. **No tool-call observability** yet — `relational_queries` corpus is mostly
   placeholder until we instrument tool-fire events. Future v3 work.
5. **Cross-corpus assertion thresholds**: with isolated users, per-corpus
   counts will be HIGHER than v1 (no dedup against prior runs). The thresholds
   in `expected.json` were calibrated for v1; v2 may show some asserts passing
   trivially or some new misses. Tune as v2 baseline emerges.

## Adding a new corpus

1. Create `prompt_corpus/<name>.txt` — one prompt per line
2. Add a `corpora.<name>` block to `expected.json` with target assertions
3. Add the corpus name to the `CORPORA` list in `run_eval.sh` main loop
4. Run baseline + commit

## CI integration (deferred to V1.9)

Per `docs/v1.8-sprint-lock.md` PL-5: local-first. CI integration via GitHub
Actions or pre-commit hook lands in V1.9 once we have GitHub Actions configured.

## Why this matters

Per design doc `docs/v1.8-memory-pyramid-design.md` § "Adversarial evals":
> extraction reliability is the universal failure mode. Mem0 has 97.8% junk after
> 32 days. Our 0-edges-DB-wide was the same family. A pure code fix without
> continuous evaluation will regress.

This eval suite is the regression detector. Every V1.8 commit's F1 delta is the
proof its target gap closed.

---

_V1.8-6 shipped 2026-05-05. Per locked binding [[feedback_next_generation]]._
