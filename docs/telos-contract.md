# TELOS Contract

Normative. Code and this doc must agree; `src/agent/telos_contract_test.zig` is
the executable form of the invariants below — if you change either, change both.
PRs touching the curated user-model injection are reviewed against this file.

TELOS is the agent's **curated, always-on model of who the user is and where
they are going** — mission, lifetime goals, challenges, strategies, projects,
metrics, and identity anchors. It is a *governed view over existing durable
facts*, NOT a new store: the authoritative rows live under the reserved
`durable_fact/telos/*` key namespace and ride the same memory substrate
(embedding, `valid_to` aliveness, contradiction resolution, GDPR erase) as every
other durable fact. See `docs/memory-contract.md` — TELOS adds no bucket; it
constrains a slice of the existing **knowledge** bucket.

## Scope

In scope: which durable facts are the curated north star, how they are injected,
how they supersede raw copies, how they stay fresh, who may write them.

Non-goals (deliberately NOT built): no new table or store; no scoring/rings/UI;
no extraction-time "is-this-telos" classifier; no per-turn writes; the human
`TELOS.md` file is a late, optional read-projection, never the source of truth.

## Relationship to the memory contract

| Property | TELOS rows |
|---|---|
| Bucket | `knowledge` (outward-facing, about the user) |
| Storage fate | persisted + injected, `memory_type = core` (durable, immortality-guarded); embedding follows the durable_fact default |
| Referent | the END user (never the operator) — resolution correctness is load-bearing (see Invariants) |
| Write provenance | internal/approved only — NEVER a raw agent- or human-authored file edit (memory-contract Invariant 6) |

## Ownership matrix

The matrix is what makes overlap impossible: each referent has exactly one owner,
one substrate, one injection path.

| Referent class | Owner | Substrate | Injected via | On conflict with a raw copy |
|---|---|---|---|---|
| Mission, lifetime goal, challenge, strategy, project, metric, identity anchor | **`durable_fact/telos/*`** | existing memory rows | pinned `<telos>` block (unconditional) | filing supersedes the raw row (`valid_to`) → raw row leaves EVERY surface |
| Session goal ("finish today") | WM `active_goal` slot | transient (≤15 slots) | `<working_memory>` | decays; never filed |
| People, events, preferences, world facts | `durable_fact/*` | memory rows | `memory_slot` retrieval | contradiction judge (unchanged) |

## Invariants

Executable form: `src/agent/telos_contract_test.zig`.

1. **T1 — single-source injection.** A telos referent is injected from the
   `<telos>` block only. This is achieved by supersession (T2), NOT by editing
   the identity-fact predicate set or the `/brain` self-anchor picker — a filed
   telos row's raw source is superseded and drops from `listIdentityFacts`,
   retrieval, and the anchor picker automatically via `MEMORIES_VALIDITY_FILTER`.
2. **T2 — filing supersedes.** Writing a telos row calls `resolveContradiction`
   on the source raw key(s) so `valid_to` is set. Exactly one live copy exists at
   all times; there is never a window where a goal is in both blocks or neither.
3. **T3 — precedence.** telos > raw durable_fact > working memory, enforced at
   file-time by T2 (not at query time). Curated intent outranks stray extraction.
4. **T4 — proposal-gated writes.** Telos rows enter only via the curation loop:
   reflection proposes (a `wish/*` proposal — memory-contract's "request, not
   behaviour" bucket), the user approves through `execution_mode`, then an
   internal writer files. No silent self-authored identity.
5. **T5 — axis honesty.** Durability is `memory_type = core`; aliveness is
   `valid_to`; curability is provenance (the `telos/` namespace). Never proxy one
   axis through another (memory-contract Invariant 5).
6. **T6 — freshness.** Always-on curated content that goes stale is worse than
   retrieval-gated memory (the agent pursues abandoned goals confidently). Each
   telos row carries an age (`created_at`, free); the curation loop demotes rows
   past a reconfirmation horizon from pinned → retrieval-gated, and the renderer
   annotates age so the model itself can discount stale intent.

## Enforcement map

(Symbol references — locate with `grep -n "<symbol>" <file>`. Line numbers rot;
symbols survive refactors.)

- Namespace recognition: `src/agent/memory_loader.zig` `isDurableFactKey`
  (prefix-only `startsWith "durable_fact/"` — the `telos/` segment is free).
- Injection block + query: `src/agent/memory_loader.zig` `buildTelosBlock` +
  `listTelosFacts` (sibling of `buildActiveIdentityBlock` / `listIdentityFacts`,
  keyed on `key LIKE 'durable_fact/telos/%'` + `MEMORIES_VALIDITY_FILTER`).
- Supersession (T2): `src/zaki_state.zig` `resolveContradiction`.
- Aliveness filter (T1/T2): `src/zaki_state.zig` `MEMORIES_VALIDITY_FILTER`.
- Proposal + approval (T4): `wish/*` bucket (`docs/learning-contract.md`) +
  `src/agent/execution_mode.zig`.
- Durability (T5): `memory_type = core` ∈ `EVERGREEN_MEMORY_TYPES`
  (`src/memory/root.zig`).
- Registry cross-check: `src/agent/telos_contract_test.zig`.

## Deferred register

- Confirm `resolveContradiction` sets `valid_to` on the memory ROW (not only the
  edge) such that `listIdentityFacts` drops it — verify in Slice 1 before relying
  on T2.
- Curation heuristic ("which raw durable fact is telos-worthy") — kept
  human-approval-gated (T4) so a weak heuristic proposes noise but cannot corrupt
  the model. Tune post-measurement.
- Stable-tier promotion of the `<telos>` block (currently volatile, re-sent per
  turn, bounded like the identity block). Upgrade only if token cost measures as
  material.
- `TELOS.md` read-projection + guarded `telos_set` tool + subagent opt-out
  (Slice 3 ergonomics).
