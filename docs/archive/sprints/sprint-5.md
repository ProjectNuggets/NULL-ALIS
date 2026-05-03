---
tags: [prose, prose/docs]
---

# Sprint 5 — Architectural Correctness — CLOSED 6/8 (S5.1 → D17, S5.2 → D18)

**Branch:** `repair/sprint-5-architectural-correctness` (off `main` tip `3acf82a`)
**Opened:** 2026-04-24
**Closed:** 2026-04-24 at `4a23d6c` — 6 in-repo items shipped; S5.1 + S5.2 deferred as D17 + D18.
**Target:** architectural claims match wire behavior; byte-stability invariant has a test guard; operator diagnostics distinguish exit causes; turn-loop file I/O memoized.

## Scope

### Byte-stability closure (3)

- [x] **S5.6** Byte-equality unit test for `buildStableSystemPrompt`. _Shipped `477d520` — three-call identity assertion ensures future HashMap / directory-walk / module-state regressions fire immediately._
- [x] **S5.4** Sort tools prose block alphabetically. _Shipped `3a8da9e` — index-array insertion sort on a 256-slot stack buffer, function signature opened to `anytype` for duck-typed test coverage. New unit test with reversed-input MockTools asserts the emitted order is alpha → mike → zebra + byte-equal on repeat call._
- [x] **S5.5** Sort `listSkills` + `listSkillsMerged` by name. _Shipped `831a50c` — `std.mem.sort` + new private `skillLessThanByName` comparator; sort applied at end of both functions (listSkillsMerged sorts the post-merge slice). New unit test creates three skill dirs in reverse alphabetical order and asserts sorted return._

### Operator diagnostics (1)

- [x] **S5.8** Stage-17 disambiguate loop-detected vs iterations-exhausted exit. _Shipped `0e997de` — new `ObserverEvent.loop_detected{iteration, iterations_cap}` variant; branched emission at fallback entry + distinct log lines + `turn.profile kind=tool_loop_detected` vs `tool_exhausted` + user-visible return prefix "[Tool loop detected at N/N]" vs "[Tool iteration limit: N/N]". Three consumers in observability.zig (logRecordEvent, fileRecordEvent JSON emit, OTel addSpan) got exhaustive-switch arms._

### Performance (1)

- [x] **S5.7** Memoize `Config.load` for turn-loop capabilities rendering. _Shipped `3550539` — new `cached_config: ?Config` + `cached_config_loaded: bool` fields on Agent; `cachedConfigForCaps()` accessor loads on first call + caches; `Agent.deinit` frees. Turn-loop replaces per-turn load + parse + deinit triad with one pointer read. 50-message burst: 50 file reads → 1._

### Architectural (1)

- [x] **S5.3** Streaming context-exhaustion recovery parity with blocking path. _Shipped `4a23d6c` — mirror the `provider.chat` force-compress + retry flow in the `provider.streamChat` branch. On `ContextLengthExceeded` + history > `CONTEXT_RECOVERY_MIN_HISTORY`: `forceCompressHistory` + `recordForceCompression` + rebuild messages from compacted history + re-stream once. Retry failure propagates._

### Deferred (2 → D17, D18)

- [ ] **S5.1** Anthropic two-block cache split on the wire. _Carried → **D17**._
- [ ] **S5.2** Error classification carrier in `providers/reliable.zig` (delete 4 dead string-matchers). _Carried → **D18**._

## Deferred items (tracked)

| ID | From | What's carried | Target | Rationale |
|----|------|----------------|--------|-----------|
| D17 | S5.1 | Extend `serializeSystemCacheable` to emit `[{type:text, text: stable, cache_control: ephemeral}, {type:text, text: volatile}]`. Plumb stable-prefix-length through ChatRequest (or add a side channel) so the emitter can split without parsing. | Dedicated PR, after the primary-provider decision firms up | Today's emission wraps the full `stable + volatile` concat in one cache_control block — volatile bytes change every turn so Anthropic cache invalidates on every call. The fix is real but: **Together is current primary**, not Anthropic. Landing this refactor now means plumbing a new field through ChatRequest + touching three anthropic.zig call sites + the NNGTs_cache.zig serializer + reconciling with how Agent stores system prompt in history[0]. Multi-file surface area, low current value (Anthropic isn't primary). Deferred PR lets it ship with proper review + a provider-switch trigger to prove the cache hit. |
| D18 | S5.2 | Replace `storeErrorName(@errorName)` with a structured `{kind: ApiErrorKind, retry_after_ms: ?u64}` carrier populated inside body parsers (anthropic.zig:125, compatible.zig:347 already classify). Delete `isNonRetryable` / `isContextExhausted` / `isRateLimited` / `parseRetryAfterMs`. | Dedicated PR | Cross-cutting error-path refactor: Zig errors can't carry payloads, so the carrier needs threadlocal or Provider-held state or a callback/out-param signature change. Each option has consequences the string-matchers don't. Today's string-matchers WORK (battery passes); the refactor is correctness + hygiene, not a live bug. Worth doing, not worth rushing. |

## DoD

- `zig build` green at each commit in the chain.
- `zig build test` exit 0 on tip. Three new unit tests land:
  - `buildToolsSection emits tools sorted by name regardless of input order [S5.4]`
  - `listSkills returns skills sorted by name regardless of on-disk order [S5.5]`
  - `buildStableSystemPrompt is byte-stable across back-to-back calls with identical inputs [S5.6]`
- Byte-stability invariant now has an inline regression guard — any future unsorted iteration or stateful builder mutation fires the S5.6 test.
- Loop-detected exits reach observers + dashboards + user reply distinctly from iterations-exhausted exits.
- Config.load reduced from per-turn to per-Agent-lifetime — 50-msg burst goes from 50 disk I/Os to 1.
- Streaming sessions heal on context-exhaustion the same way blocking sessions do.

## Commit log

Branch `repair/sprint-5-architectural-correctness` off `main` tip `3acf82a`.

| # | Commit | Item | Scope |
|---|--------|------|-------|
| 1 | `477d520` | **S5.6** | test(prompt): assert buildStableSystemPrompt is byte-stable across calls |
| 2 | `3a8da9e` | **S5.4** | fix(prompt): sort tools alphabetically for byte-stable prefix |
| 3 | `831a50c` | **S5.5** | fix(skills): sort listSkills + listSkillsMerged by name |
| 4 | `0e997de` | **S5.8** | fix(agent): distinguish loop-detected from iterations-exhausted exit |
| 5 | `3550539` | **S5.7** | perf(agent): memoize Config.load for turn-loop capabilities rendering |
| 6 | `4a23d6c` | **S5.3** | fix(agent): force-compress + retry on context-exhausted stream |
| 7 | _(this commit)_ | close | Sprint 5 plan doc + CLOSURE tick + D17 / D18 tracking |

## Sprint 5 close-out checklist

1. [x] Every in-repo `[ ]` ticked to `[x]` for shipped items (S5.3, S5.4, S5.5, S5.6, S5.7, S5.8). S5.1 + S5.2 explicitly deferred as D17 + D18.
2. [x] `zig build` green at each commit.
3. [x] `zig build test` green on tip; three new unit tests pass.
4. [x] Sprint 5 close-out commit populates Ship summary + DoD log + deferred rationale (this commit).
5. [ ] Push branch, create PR.
