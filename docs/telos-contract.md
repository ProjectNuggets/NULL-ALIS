# TELOS Contract

Normative. Code and this doc must agree; `src/agent/telos_contract_test.zig` is
the executable form of the invariants below — if you change either, change both.
PRs touching the curated user-model injection are reviewed against this file.

TELOS is the agent's **curated, always-on model of who the user is and where
they are going** — mission, lifetime goals, challenges, strategies, projects,
metrics, values, and identity anchors. It is a *governed view over existing durable
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

## Schema (research-grounded, not Miessler-canonical)

TELOS owns the user model's **static / foundation layer** — the slow-changing core
the agent should always know. Dynamic/behavioral/contextual layers stay with the
memory pipeline (working memory, extraction, retrieval). This static-foundation +
dynamic-behavior split is the personalized-LLM-agent consensus (see Research basis).

Rows are keyed `durable_fact/telos/<type>/<id>`, `type ∈ {mission, goal, challenge,
strategy, project, value, identity}`. Each **goal** row additionally carries:

- `specificity` + `metric` — a filed goal is specific and measurable; a vague,
  metric-less goal is an inbox candidate, NOT a north star (Goal-Setting Theory).
- `motivation: intrinsic | extrinsic` (+ optional `why`) — lets the agent prioritize
  intrinsic goals and frame help autonomy-supportively (Self-Determination Theory).
- `frame: ideal | ought` — aspiration vs obligation. They motivate differently
  (ideal-gap → disappointment; ought-gap → guilt) so the agent treats them
  differently (Self-Discrepancy Theory).

The **actual-self** is NOT stored here — it is what the memory pipeline observes.
The agent reasons over the *discrepancy* between observed actual and filed
ideal/ought; that gap is the motivational signal, not the goal text alone.

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
4. **T4 — human authorship (propose-only).** The user AUTHORS their model; the
   agent only scaffolds. Rows enter via the curation loop as `wish/*` proposals
   (memory-contract's "request, not behaviour" bucket); the user approves through
   `execution_mode`; then an internal writer files. The loop NEVER auto-files.
   This is not merely governance: AI-authored goals measurably *undermine* the
   motivation they aim to drive by violating autonomy ("Optimized but Unowned";
   SDT). Auto-authored identity is a correctness bug, not a convenience.
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

## Research basis

TELOS-the-brand (Miessler) is a practitioner ontology, not a validated construct.
This contract keeps its useful structure but grounds the schema in theory that is:

- **Goal-Setting Theory** (Locke & Latham) — goals perform when specific + measurable
  + committed → `metric` / `specificity` (Schema).
- **Self-Determination Theory** (Deci & Ryan) — intrinsic goals predict wellbeing,
  extrinsic predict ill-being; autonomy is a core need → `motivation` tag + T4.
- **Self-Discrepancy Theory** (Higgins) — actual / ideal / ought selves; the
  *discrepancy* motivates → `frame` + actual-self-lives-in-the-memory-pipeline.
- **Personalized-LLM-agent surveys (2026)** — layered profile, static-foundation +
  dynamic-behavior, staleness as an open problem → the ownership split + T6.
- **"Optimized but Unowned" (2026)** — AI-authored goals undermine motivation →
  T4 human authorship is a requirement, not a nicety.

## Deferred register

- ~~Confirm `resolveContradiction` sets `valid_to` on the memory ROW~~ —
  **VERIFIED CLOSED (Package 3 review, 2026-07-09)**: `resolveContradiction`
  calls `setMemoryInvalidation` on the loser key, which sets
  `valid_to`/`invalid_at`/`expired_at` + `is_latest=FALSE` on the memories ROW
  in one txn (plus the edge cascade). This is the same close-out primitive
  `memory_archive` and the M3 cascade ride — exhaustively exercised by the
  Package 3 test suite and live drive. T2 may rely on it.
- **T2b (NEW, must land in Slice 1) — protect telos rows from the M3
  archive/forget cascade.** Package 3 made `memory_archive`/`memory_forget`
  information-scoped: live rows with an identical `content_hash` are
  cascade-closed. `durable_fact/` is an editable family, so a re-stored raw
  duplicate later archived by the user could silently take the byte-identical
  telos twin with it — curated intent killed by curation of a stray copy. Fix:
  add `durable_fact/telos/` to the cascade's protected-key set (the same
  predicate hook the M3 fix introduced for system keys; one line + one test).
  Only explicit curation of the telos key itself may close a telos row.
- **T4 key naming — use a `wish/telos/<type>/<id>` sub-namespace, not bare
  `wish/*`.** Bare wishes are capability requests: the fleet wish-harvest and
  the planned wish→Decision-Hub matchmaking mine that namespace. Mixing
  identity proposals in muddies both. A dedicated sub-namespace keeps T4's
  propose→approve flow intact and lets the miner/matchmaker filter it out.
- Curation heuristic ("which raw durable fact is telos-worthy") — kept
  human-approval-gated (T4) so a weak heuristic proposes noise but cannot corrupt
  the model. Tune post-measurement.
- Stable-tier promotion of the `<telos>` block (currently volatile, re-sent per
  turn, bounded like the identity block). Upgrade only if token cost measures as
  material.
- `TELOS.md` read-projection + guarded `telos_set` tool + subagent opt-out
  (Slice 3 ergonomics).
