# Sprint 15 — Minor + Park Items — CLOSED 2/4 in-repo, 2/4 parked-with-reason (2026-04-26)

**Branch:** `sprint/s15-minor-park` (off `main` tip `8396291`)
**Opened:** 2026-04-26
**Closed:** 2026-04-26 — meets DoD ("no park-maybe-later item remains undocumented") via 2 shipped + 2 explicitly parked.

## In-repo items shipped

| ID | SHA | Item | Notes |
|---|---|---|---|
| **S15.3** | `7870c07` | Provider catalog honesty | 11 cosmetic / local-only entries documented inline in `src/providers/factory.zig`: Qianfan/Baidu (needs OAuth 2-step, Bearer auth fails), Bedrock (needs AWS SigV4, Bearer auth fails), 8 localhost entries (local-dev-only, won't reach from cell-pod). Operators now know which entries need extra work before production use. |
| **S15.4** | `7870c07` | Transcripts vector sync truth | `docs/memory-architecture-map.md` corrected: cold transcripts are NOT vector-synced today (saveMessage writes the row but doesn't call syncVectorAfterStore). Doc updated to match code-truth + tracks the gap as future work with the proposed `transcript/<session_id>/<message_id>` vector_key path. |

## Parked-with-reason items (deferred from in-repo close)

| ID | Item | Why parked |
|---|---|---|
| **S15.1** | `config_parse.zig` table-driven tests — 10 canonical + 10 malformed per top-level key | Substantial test-writing effort (~50+ test cases for ~15 top-level keys = 150+ assertions). Real value but no live bug pressure. The 1948-LoC `config_parse.zig` has 0 in-file tests today; comprehensive coverage is best done in a focused dedicated PR with one engineer's full attention rather than crammed into a sprint. **Park trigger:** any future config-parse bug in prod, OR a contributor specifically picks up the test-writing as a side project. |
| **S15.2** | log.warn vs log.info rebalance — audit + demote noise (340 vs 146) | Audit-flavor cleanup: read every log.warn site, decide whether it's actually warn-grade or just info-grade noise. ~340 sites is a 2-3 hour focused read. Real value (operator alert fatigue) but no live signal that the noise is causing missed-alert problems. **Park trigger:** any operator pain about log noise, OR an observability sprint (S13) that takes the rebalance as part of its scope. |

## Sprint 15 DoD

> "no `park — maybe later` item remains undocumented"

✅ S15.1 parked with explicit park-trigger conditions
✅ S15.2 parked with explicit park-trigger conditions
✅ S15.3 shipped at `7870c07`
✅ S15.4 shipped at `7870c07`

## Tests

`zig build test` green throughout (5500+, no behavior changes — pure docs/comments).
