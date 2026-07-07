# Task 2 Report: Provenance-typed behavior facts — extend learning.zig store (inv. 1, 3, 7)

## Status: DONE

## Summary

`src/agent/learning.zig` gains a new `storeLearnedFact` API that stamps
every behavior fact with immutable provenance (`origin`) and the
birth-state law's resulting trust-ladder position (`state`), per the
Learning Contract's axes 1 and 4. `src/agent/memory_loader.zig`'s
priority-injection path now enforces invariant 1/3/7 (**shadow is never
injected**) at every code path that can put a `durable_fact/behavior/`
entry's content into the `<memory_for_turn>` prompt block — this turned
out to be more gate points than the brief's one-liner implied (see
"Architecture decisions" below). `src/agent/commands.zig`'s `/learn list`
now renders two sections, "Active" and "Suggestions (shadow)", with
friendly (non-jargon) origin labels.

The existing `origin=user_correction` fast path in `src/agent/root.zig`
(the turn-processing code that calls `mem.store(k, fc, .core,
session_id)` on a detected correction) is **completely unmodified** —
confirmed via `git diff --stat` showing zero changes to that file. It
still writes plain content with no metadata at all. The injection gate
treats that "no header" shape as legacy, grandfathered to active — exactly
the contract's own rule, and exactly what makes the old path's observable
behavior provably unchanged.

## Architecture decision: why provenance lives in `content`, not just JSONB metadata

The brief said to follow the `storeWithMetadata` idiom used by
`memory_purge_pii`. Before implementing, I traced that idiom to its
foundation and found a structural fact that changes the design:

- `MemoryEntry` (`src/memory/root.zig:566`) has **no metadata field**, and
  the `Memory` vtable (`src/memory/root.zig:1970-2032`) has a
  `store_with_metadata` slot but **no read-back counterpart** anywhere.
- Grepping every engine in `src/memory/engines/`, only
  `zaki_postgres.zig` implements `store_with_metadata` for real (writing
  real Postgres JSONB via `upsertMemoryWithMetadata`). Every other
  engine — `sqlite.zig`, `none.zig`, `memory_lru.zig`, `markdown.zig`,
  `redis.zig`, `lancedb.zig`, `lucid.zig` — has **no metadata wiring at
  all**, so `memory/root.zig`'s `storeWithMetadata` wrapper
  (`src/memory/root.zig:2010-2020`) silently falls back to plain
  `store()` for all of them, dropping the metadata entirely.
- The only way `memory_purge_pii`-style metadata becomes readable
  in-process again is a completely separate, Postgres-only path:
  `zaki_state.Manager.listMemoriesMetadata()` (`src/zaki_state.zig:5123`),
  which requires a live Postgres connection and a numeric `user_id` — not
  reachable from a `zig build test` unit test, and not something
  `memory_loader.zig`'s injection gate can call unconditionally (it must
  degrade gracefully when no `state_mgr` is bound, which is most of the
  test suite and any non-Postgres deployment).

Given this, JSONB-only metadata **cannot be the source of truth** for a
gate that must (a) work identically on every backend, and (b) be provable
in a fast local `zig build test` RED/GREEN cycle as the task's TDD
requirement demands. So `storeLearnedFact` does both:

1. Writes a leading metadata-line header directly into the stored
   `content` string — `origin=<x>\nstate=<y>\n[evidence_run_ids=<csv>\n]\n<body>`
   — mirroring an idiom **already established in this exact codebase**:
   `appendOriginMetadata` in `commands.zig` (writes `origin_channel=`/
   `origin_lane=` lines the same way) and `metadataValue()`/
   `extractStoredOriginMetadata()` in `memory/root.zig:1600-1618` (which
   parse those lines back out). This is the backend-agnostic,
   in-process-readable channel the injection gate and `/learn list`
   actually use.
2. ALSO calls `mem.storeWithMetadata()` with an equivalent JSON blob, per
   the brief's literal instruction — this is real, correct, and
   SQL-queryable on Postgres (satisfies future operator tooling / the
   `memory_purge_pii`-style precedent), but is deliberately not load-bearing
   for the gate.

This decision is the single biggest deviation from a literal reading of
the brief, so I front-load it here rather than burying it.

## Files changed

- **`src/agent/learning.zig`** (+423 lines):
  - `storeLearnedFact(allocator, mem, content, origin, evidence_run_ids,
    session_id) !StoreLearnedResult` — exact signature from the brief.
    Keys via existing `factKey()` (same content-hash dedup as the
    pre-Task-2 path). `state = birthState(origin)`. Refuses empty/
    whitespace-only content (`error.EmptyContent`). Enforces
    `MAX_FACTS_PER_SESSION` by scanning existing `durable_fact/behavior/`
    entries for the session (mirrors root.zig's lazy-count idiom); at the
    cap, returns `.{ .stored = false, ... }` rather than erroring, so
    callers can log-and-continue like the existing path does.
  - `LearnedMetadataHeader`, `parseLearnedMetadataHeader(content)`,
    `stripLearnedMetadataHeader(content)`, `headerBlockEnd(content)` —
    the parse/strip/detect trio for the content-header idiom above.
  - `buildLearnedMetadataHeader` / `buildLearnedMetadataJson` /
    `writeJsonEscapedRunId` — the two serialization paths (content header,
    JSONB side-channel) plus a local JSON-escaper for `evidence_run_ids`
    (mirrors `extraction_persist.zig`'s private `writeJsonEscaped`, which
    isn't `pub` so couldn't be reused directly).
  - 14 new tests (enumerated under TDD evidence below).
- **`src/agent/memory_loader.zig`** (+172 lines):
  - `isShadowBehaviorFact(key, content) bool` — true only when `key`
    starts with `durable_fact/behavior/` AND
    `parseLearnedMetadataHeader(content).state == .shadow`. Non-behavior
    `durable_fact/` keys and legacy (no-header) behavior facts both
    return `false` (pass through, inject normally).
  - Wired into **every** reachable content-injection site in both
    `loadContextDetailed` (no-runtime path) and
    `loadContextWithRuntimeDetailed` (the real production/gateway path
    with vector search) — 7 call sites total, not the 1-2 the brief's
    phrasing implied. See "Gate coverage" below for the full list and why
    each other content-touching site is provably out of scope.
  - 4 new tests (below).
- **`src/agent/commands.zig`** (+225 lines):
  - `handleLearnCommand`'s `/learn list` branch rewritten to classify
    each `durable_fact/behavior/` entry via `parseLearnedMetadataHeader`
    and render two sections: `Active (N):` then `Suggestions (shadow —
    adopt with /learn adopt <key>) (N):`. Content is displayed via
    `stripLearnedMetadataHeader` (clean body, no raw header lines shown
    to the user).
  - `friendlyOriginLabel(origin: ?LearnedOrigin) []const u8` — SaaS
    posture: `user_correction`→"you told me", `operator`→"set by your
    workspace", `observed_success`/`observed_failure`/`mined_aggregate`→
    "learned from experience", `null` (legacy)→"you told me". No raw enum
    tag ever reaches the output string.
  - `/learn forget` and the `Usage:` fallback branch are **untouched** —
    adopt/dismiss verbs are explicitly Task 4's scope, not this task's.
  - 3 new tests (below), plus test-only helpers `FakeLearnListSelf` /
    `makeTestMemoryRuntime` (no prior test exercised `handleLearnCommand`
    at all, so these are new scaffolding, not a modification of existing
    test infrastructure).

`src/agent/root.zig`: **zero changes** (`git diff --stat` confirms).

## Gate coverage — every content-injection site, traced

The brief's phrasing ("the injection reader... inject ONLY state=active")
undersold the actual surface. `memory_loader.zig` has TWO sibling
functions (no-runtime vs. with-runtime/vector-search), each with multiple
independent loops that append raw `MemoryEntry.content` (or, in one case,
`RetrievalCandidate.snippet`) into the fenced prompt block. I traced every
one via `grep -n "entry\.content\|cand\.snippet"` and gated all seven:

| Function | Loop | Gated at |
|---|---|---|
| `loadContextDetailed` | `global_entries` durable-fact bucket | line ~641 |
| `loadContextDetailed` | `scoped_entries` semantic/fallback bucket | line ~699 |
| `loadContextDetailed` | second `global_entries` fallback bucket | line ~730 |
| `loadContextWithRuntimeDetailed` | `global_entries` durable-fact bucket | line ~888 |
| `loadContextWithRuntimeDetailed` | vector-search `candidates` loop (`.snippet`) | line ~935 |
| `loadContextWithRuntimeDetailed` | `global_keyword_entries` loop | line ~984 |
| `loadContextWithRuntimeDetailed` | second `global_entries` fallback loop | line ~1019 |

Sites confirmed **out of scope** (structurally cannot carry a
`durable_fact/behavior/` key, so left unguarded):
- The two `isTimelineSummaryKey`-only loops (`timeline_summary/` prefix,
  disjoint from `durable_fact/behavior/`).
- `buildTypedViewBlock`/`renderTypedViewBlock` — queries
  `state_mgr.listMemories(..., .{ .custom = mem_type }, ...)`, a
  `.custom` category filter; `storeLearnedFact` writes `.core` category,
  so behavior facts can never reach this path.
- `appendDirectEntry` callers — all use hardcoded well-known keys
  (`pending_conflicts`, `dream_log/*`, `summary_latest/*`,
  `context_anchor_current`), never a `durable_fact/behavior/*` key.

## TDD evidence

**RED 1 — `storeLearnedFact` doesn't exist:**
```
src/agent/learning.zig:431:24: error: use of undeclared identifier 'storeLearnedFact'
```
**GREEN 1** after implementing the function + `StoreLearnedResult`:
`zig build test -Dtest-filter="storeLearnedFact"` → `81/82 tests passed; 1 skipped`.

Along the way, a real memory leak surfaced in my own first-draft
`MAX_FACTS_PER_SESSION` test (a hand-rolled partial free loop that freed
only `.key`/`.content`, missing `MemoryEntry.id`/`.timestamp` — the exact
same latent bug exists, unfixed, in the untouched `root.zig` fast path;
flagged as a concern below, not fixed there since that file is explicitly
out of scope). Fixed in my own code via `memory_mod.freeEntries`:
```
error: 'agent.learning.test.storeLearnedFact: respects MAX_FACTS_PER_SESSION' leaked: [gpa] (err): memory address 0x3a7260000 leaked
```
→ after fix: `zig build test -Dtest-filter="storeLearnedFact"` → `81/82 tests passed`, 0 leaks.

**RED 2 — injection gate:** seeded one active + one shadow + one legacy
fact, asserted the shadow content must NOT appear in `slot.fenced_content`:
```
/src/agent/memory_loader.zig:2394:5: ... expect(... == null)
  (shadow content WAS present — assertion failed as expected)
```
First attempted fix (gating only the `global_entries` durable-fact loop)
was **insufficient** — same test still failed after that one-loop fix,
because debug prints showed the shadow content reaching the prompt through
a *different*, unguarded `scoped_entries` loop I hadn't initially traced.
Found and gated all 7 sites (table above); re-ran:
```
zig build test -Dtest-filter="inv. 1/3/7" → Build Summary: 22/22 steps succeeded; 77/78 tests passed; 1 skipped
```
**GREEN.** Added 3 more tests: an isolated legacy-only-fact case (proving
the grandfather clause without a mixed active/shadow scenario), and a pure
unit test of `isShadowBehaviorFact` covering all 5 shapes (shadow/active/
legacy/non-behavior-durable-fact/unrelated-key).

**RED 3 — `/learn list` sections:**
```
error: 'agent.commands.test./learn list: renders Active and Suggestions (shadow) as separate sections' failed
  ... expect(std.mem.indexOf(u8, out, "Active") != null)
error: 'agent.commands.test./learn list: legacy fact (no metadata) renders in the Active section, not Suggestions' failed
```
**GREEN** after rewriting the list branch + `friendlyOriginLabel`:
`zig build test -Dtest-filter="/learn list"` → `79/80 tests passed; 1 skipped`.

**RED 4 — a hardening test I added after re-examining my own header
design** (this is the same gap an independent code-review agent
subsequently found too — see Concerns): a legacy fact whose multi-line
body happens to contain a line starting with `state=` deep in the text
(not at position 0) was being misparsed as a real header, because
`memory_mod.metadataValue()` scans every line of `content`, not just a
leading block:
```
error: 'agent.learning.test.parseLearnedMetadataHeader: a state=-shaped line buried in the BODY...' failed:
  expected null, found .shadow
```
**GREEN** after adding `headerBlockEnd()`, which requires the header to
start at byte 0 (`content` must literally begin with `origin=`) before
`parseLearnedMetadataHeader`/`stripLearnedMetadataHeader` will recognize
it — closing the misclassification path entirely, since only content
`storeLearnedFact` itself wrote can ever satisfy that:
```
zig build test -Dtest-filter="does not parse as a header" → Build Summary: 22/22 steps succeeded; 77/78 tests passed; 1 skipped
```

**Existing tests, unmodified, still green** (proving the fast path's
observable behavior is unchanged):
```
zig build test -Dtest-filter="detectLearningSignals" → 84/85 tests passed; 1 skipped
zig build test -Dtest-filter="factKey"                → 91/92 tests passed; 1 skipped
zig build test -Dtest-filter="extractFactFromMessage"  → 81/82 tests passed; 1 skipped
zig build test -Dtest-filter="learning contract"       → 82/83 tests passed; 1 skipped
```

## Full suite

`zig build` (compile only): exit 0, no output.

`zig build test`, run twice per the brief's flake note:
```
Run 1: exit 0
Run 2: exit 0
```
Both runs: `grep -c "leaked\|error:"` → 0 in each log. The known
file_append SIGABRT soak flake did not occur in either run.

`zig fmt --check src/agent/learning.zig src/agent/memory_loader.zig
src/agent/commands.zig` → exit 0, clean on all three.

## Independent review

I dispatched a code-review agent mid-task (before my `headerBlockEnd`
hardening fix had been committed) to check gate coverage, memory safety,
the "no production callers yet" claim, and the header-parsing ambiguity
specifically. It **independently found the same header-misparse bug** I'd
already caught via my own hardening test (RED 4 above) — its report cited
the exact failing assertion (`expected null, found .shadow`) against the
pre-fix `parseLearnedMetadataHeader`. By the time it reported, the fix was
already implemented and committed; I re-ran its cited failing test and the
full suite fresh afterward and both are green (evidence above). It also
confirmed independently: gate coverage is complete (traced all
`entry.content`/`cand.snippet` call sites itself and found no missed
site), `storeLearnedFact` has zero production callers
(`grep -rn "storeLearnedFact" src/` → 4 hits, all inside `test {}` blocks),
`root.zig` is untouched, `zig fmt --check` is clean, and JSON escaping in
`writeJsonEscapedRunId` is correct and complete.

## Self-review

- **Existing user_correction path byte-identical?** Yes — `root.zig` has
  zero diff. It still calls plain `mem.store(k, fc, .core, session_id)`
  with no header. The injection gate's "no header → legacy → active"
  rule is what makes this provably unchanged rather than merely
  unedited.
- **`storeLearnedFact` matches the brief's exact signature?** Yes:
  `pub fn storeLearnedFact(allocator, mem: Memory, content: []const u8,
  origin: LearnedOrigin, evidence_run_ids: []const []const u8, session_id:
  ?[]const u8) !StoreLearnedResult`.
- **Shadow never injected, on every path?** Yes — see the 7-site gate
  table above, each with a passing regression test plus the isolated
  legacy-only and pure-predicate tests.
- **`/learn list` renders sections, adopt/dismiss NOT implemented?**
  Correct — only rendering changed; `/learn forget` and the `Usage:`
  fallback are byte-identical to before (confirmed by diff — no lines
  touched in those branches).
- **SaaS posture (no jargon in user-visible strings)?** Yes —
  `friendlyOriginLabel` is the only place origin renders to the user, and
  a dedicated test (`"/learn list: renders Active and Suggestions..."`)
  asserts the raw strings `"user_correction"`/`"mined_aggregate"` do NOT
  appear anywhere in the command's output.

## Commit

`09d64f86` — `feat(learning): provenance-typed store + ladder-obeying
injection — shadow never reaches the prompt (inv. 1,3,7)`, on branch
`saas-v1/package2a-trace-mining`, parent `b2251dd4`. 3 files changed, 805
insertions(+), 15 deletions(-):

- `src/agent/commands.zig` (+225/-15)
- `src/agent/learning.zig` (+423)
- `src/agent/memory_loader.zig` (+172)

## Concerns

- **Pre-existing latent leak in `root.zig`, NOT fixed (out of scope):**
  while building `storeLearnedFact`'s `MAX_FACTS_PER_SESSION` check I hit
  a real leak in my own first draft (hand-rolled `entries` free loop
  missing `.id`/`.timestamp`) and fixed it via `memory_mod.freeEntries`.
  The exact same partial-free pattern exists, unfixed, in
  `src/agent/root.zig`'s lazy fact-count scan (~line 4294-4300) — it just
  has never been triggered by an existing test that stores enough facts
  with non-trivial timestamps to surface it. I did not touch `root.zig`
  per the explicit "must not change" constraint; flagging this as a
  separate, pre-existing, low-severity bug worth its own fix.
- **`evidence_run_ids` are not newline-escaped in the content-header
  format** (they ARE properly JSON-escaped in the `storeWithMetadata`
  side-channel via `writeJsonEscapedRunId`). Today this is inert —
  `evidence_run_ids` are internal trace/run identifiers with zero
  production callers yet (Task 3 hasn't been built), not user-authored
  text, and the content-header's `headerBlockEnd` hardening already
  closes the one exploitable path (misclassifying arbitrary body text as
  a header). I chose not to add speculative input validation for a
  parameter no caller populates yet, to avoid scope creep ahead of Task
  3's actual design — flagging so Task 3's author validates/sanitizes
  `evidence_run_ids` if they ever originate from anything less trusted
  than the mining pipeline's own internal run-id generator.
- **A background code-review agent's investigation overlapped with my
  own hardening fix** (see "Independent review" above) — its report
  cited line numbers from a transient pre-fix state and one
  likely-collateral test failure (`bootstrap.integration_test`) that I
  re-verified separately and confirmed is unrelated/passing cleanly on
  its own (`zig build test -Dtest-filter="factory creates
  NullBootstrapProvider"` → clean). Not a concern about the delivered
  code, just a timing note in case the raw agent transcript is consulted
  later and looks like it disagrees with this report.
