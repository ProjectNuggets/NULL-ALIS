# Learning Contract

Normative. Code and this doc must agree; `src/agent/learning_contract_test.zig`
is the executable form of the truth below — if you change a predicate, an
enum, or this doc, change both. This contract governs what may become
BEHAVIOUR (companion to `docs/memory-contract.md`, which governs what may
become KNOWLEDGE).

One sentence: the agent may learn from its own experience only along a
**provenance-typed, externally-gated trust ladder** — observation never
becomes behaviour by the miner's own judgment, and the human can always see,
adopt, or dismiss what the agent thinks it learned.

## Buckets

Every learning artifact lands in exactly one bucket:

| Bucket | Definition | Storage | May influence behaviour? |
|---|---|---|---|
| **experience** | raw operational record: `tool_traces` rows (what was tried, outcome, duration) | Postgres, retention-bounded (operational tier) | never directly |
| **insight** | derived pattern: failure-modes, recurrence clusters, tool-fluency stats — RE-DERIVABLE from experience | workspace files (`insights/`), versioned per mining run | consultable context only (reports, briefs, dream) |
| **shadow directive** | a drafted behaviour rule mined from experience (`origin=mined_aggregate` or an `observed_*` origin), NOT yet active | behavior-fact store, `state=shadow` | NO — visible in reports and `/learn list`, never injected |
| **active directive** | a behaviour rule the gate promoted: user-stated correction (`origin=user_correction`, active at birth — today's learning.zig path, unchanged) or an ADOPTED mined draft | behavior-fact store, `state=active` | yes — priority injection (existing mechanism) |
| **proposal** | capability gap or skill candidate the agent wants (wish-ledger entry; future skill draft) | `wish/` memory namespace / `.pending/` | never — it's a request to the roadmap, not a behaviour |

## Axes

The bucket is decided by these axes — never by content matching:

1. **Provenance** (immutable, stamped at birth): `user_correction` |
   `observed_success` | `observed_failure` | `mined_aggregate` | `operator`.
   Trust follows provenance, never content.
2. **Scope**: `user` | `workspace` | `fleet`. Fleet artifacts carry ONLY
   counts and shapes (see invariant 5).
3. **Evidence**: the trace/run ids and occurrence count that birthed it. No
   artifact without citations.
4. **State** (the trust ladder): `shadow -> active -> retired`. Transitions
   are EXTERNAL events only (invariant 1).

## Invariants

1. **No self-promotion.** `shadow -> active` happens only by an external
   gate: the user adopts it (`/learn adopt`), or a future trust-governor
   policy the OPERATOR configured. The miner's confidence score may rank
   suggestions; it may never promote them. ("Never let the agent grade its
   own homework into trust.") Executable as the birth-state law: only
   `origin=user_correction` and `origin=operator` are active at birth;
   `observed_success`, `observed_failure`, and `mined_aggregate` always
   start `shadow` — see `birthState` in `src/agent/learning.zig` and
   `learning_contract_test.zig`'s birth-state table.
2. **Learning is observational.** Mining reads traces and writes
   insights/shadow drafts. It never mutates prompts, config, skills, tools,
   or active directives.
3. **Provenance is mandatory and immutable**; `origin=user_correction` and
   `origin=mined_aggregate` are never conflated — `/learn list` shows them
   separately.
4. **Insights are rebuildable.** Delete all insight files -> re-mine from
   traces -> equivalent content (the memsearch invariant applied to
   learning). Anything not re-derivable does not belong in the insight
   bucket.
5. **Privacy boundary.** Per-user trace CONTENT never leaves the tenant.
   Fleet-scope aggregation carries tool names, outcome counts, duration
   shapes — never arguments, keys, or text. Operator sees the fleet shape,
   not the user's life.
6. **Disclosure without theatre.** The agent may say "I've noticed X fails
   when Y — seen 4 times; adjusting" (citing real evidence) and must not
   claim improvement it cannot cite. Ties to AGENTS.md §14.7: no directive
   in the prompt may be a lie, so nothing may instruct the agent to imply
   learning that didn't happen.
7. **Bounded influence.** Active directives are capped (existing
   `MAX_FACTS_PER_SESSION`), aged by the Curator pattern (unused -> stale ->
   retired), and every one is user-curatable (`/learn forget` — exists).
8. **Learning artifacts are bookkeeping to the MEMORY pipeline** (never
   extracted/embedded as world knowledge) — the memory contract's
   provenance wall extends over the learning stores. See
   `docs/memory-contract.md`'s bookkeeping bucket.

## Behaviour design — how the agent acts around its own learning

- **In-turn**: on tool failure, it may consult recent insights (a volatile
  block, like `known_weakness` today) and adapt; it cites the insight when
  it changes course ("switching approach — direct API calls to X timed out
  3 times this week").
- **On user correction**: unchanged fast path — `origin=user_correction`
  directives are active at birth (the human said so; that IS the gate).
- **Overnight (sleep/dream)**: mining runs; the reflection may reference
  NEW insights ("I keep fumbling calendar timezones") — honest
  self-knowledge, `bench_self` style.
- **Morning brief**: at most one learning line, and only when a shadow
  draft awaits adoption: "I have a suggestion from last week's patterns —
  say 'learn list' to review." Never nags, never self-congratulates.
- **Capability walls**: when the agent cannot do what the user needed, it
  MAY file a wish (`wish/` entry: what was needed, evidence run_id) and
  tell the user it did. Wishes are proposals (bucket 5) — the roadmap
  answers them, nothing auto-builds.
- **Identity**: the agent never describes shadow drafts as things it
  "does" — they are "suggestions I haven't adopted yet." Its
  self-description tracks the ladder truthfully.

## What this contract makes impossible (by construction)

- Self-modifying behaviour without an external gate (inv. 1-2).
- Learned rules of unknown origin (inv. 3 + axis 1).
- A learning store that silently grows forever (inv. 7).
- The operator reading users' lives through "analytics" (inv. 5).
- The agent gaslighting users about its own improvement (inv. 6).
- Mined content leaking into semantic memory as facts (inv. 8).

## Enforcement map

- Vocabulary (provenance + state enums, birth-state law): `src/agent/learning.zig`
  — `LearnedOrigin`, `LearnedState`, `birthState`.
- Registry cross-check: `src/agent/learning_contract_test.zig`.

## Deferred register

- Trust governor (policy-based promotion budgets with receipts;
  hash-chained transition log reserving `prev_hash` from day one).
- Skill Forge v2 (skill drafts as bucket-5 proposals gated by an approvals
  substrate).
- Fleet curation (operator review of fleet-scope insights authoring hub
  skills/global directives).
- Provenance-typed fact metadata + gated injection + `/learn list`
  origin/state columns (Package 2a Task 2).
