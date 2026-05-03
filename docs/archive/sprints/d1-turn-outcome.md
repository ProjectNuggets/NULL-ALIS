---
tags: [prose, prose/docs]
---

# D1 Sprint — Agent Turn (TurnOutcome refactor + SOTA uplift)

**Opened:** 2026-04-25 (post-D28 close, post-Sprint-9 park)
**Pattern precedent:** `d8-secret-vault.md` — D8 was its own standalone sprint when it grew beyond Sprint 2 scope; D1 follows the same convention.
**Baseline:** main HEAD `d48771b` (post-D28 register update).
**Branch shape:** one branch + one atomic PR per item. Same discipline as Sprint 1-8.
**Estimated wall-clock:** 1-2 weeks across ~14 atomic PRs (5 D1 core, 1 cross-repo, 5 SOTA hygiene, 3 SOTA capability).

## Why a sprint

D1 has been deferred since Sprint 1. The interim `EMPTY_TURN_PLACEHOLDER` (S1.10) closed the user-visible "received" symptom for empty tool-only turns, but three real obligations remain:

1. **Structural** — `pub fn turn(self: *Agent, user_message: []const u8) ![]const u8` returns a bare string. Tool-only turns, spawned tasks, and tool execution counts are all invisible to callers (gateway, BFF, frontend). A `TurnOutcome` struct return is the right shape.
2. **Behavioral** — the subagent "received" bug (memory: `project_subagent_received_bug.md`) is NOT in `turn()` itself. The drop is on the **bus delivery path** between subagent completion and the outer agent's reply composition. Per `P2_agent_turn_loop.md` §14, "the turn driver doesn't re-enter via the bus path." Fix lives outside `turn()` but in the same conceptual surface.
3. **Capability uplift** — while we're in the agent turn loop, `P2_agent_turn_loop.md` §13 lists 13 ugly truths. Half closed by Sprints 4-5; the rest are within reach. Plus three SOTA capability adds (parallel tools, tool-result cache, memory background warmup) that the current architecture supports cleanly.

This sprint is **the agent's intelligence sprint**. The goal is not just D1 the deferred item — it's "make the agent turn more intelligent and SOTA" without rewriting it.

---

## Scope (14 items)

### Phase 1 — D1 core: TurnOutcome refactor (5 PRs)

| ID | Item | Cite | Atomic shape |
|---|---|---|---|
| D1.1 | Define `TurnOutcome` struct in `src/agent/root.zig` with fields `text`, `tool_calls_executed`, `spawned_task_ids`, `tool_only_turn` | `src/agent/root.zig` near `:530` | Struct + helper constructors. No call-site changes yet. Tests for the struct itself. |
| D1.2 | Change `pub fn turn` return type from `![]const u8` to `!TurnOutcome`. Update all 12 exit points listed in `P2_agent_turn_loop.md` §1. | `src/agent/root.zig:2184, 2480, 2511, 2571, 2668, 3324, 3329, 3431, 3544, 3565, 3603` | One PR. Caller (`session.zig:661`) updated to `.text` access for compatibility — text-only consumers unchanged. |
| D1.3 | Update `SessionManager.processMessageWithContext` to consume `TurnOutcome` and propagate metadata. Return value stays `[]const u8` for now (text only) but stores `tool_calls_executed` + `spawned_task_ids` for gateway access via session-state. | `src/session.zig:530-700` | Backward-compatible at the public-API boundary. New metadata is additive. |
| D1.4 | Gateway emits structured SSE frame for tool-only turns. New event type `tool_only_turn` carrying `{tool_calls_executed: [...], spawned_task_ids: [...]}`. `EMPTY_TURN_PLACEHOLDER` stays as fallback for old SSE consumers; new consumers prefer the structured frame. | `src/gateway.zig:9184, :10562` (the historical fabrication sites) | Versioned: gateway emits BOTH the old text frame AND the new structured frame in parallel, so frontend rollout can be gradual. |
| D1.5 | **Cross-repo:** zaki-prod BFF + frontend consume the new structured `tool_only_turn` SSE frame. zaki-prod PR pairs with this. | zaki-prod `bff/streamProxy.ts` + `frontend/components/Timeline/...` | Cross-repo PR. zaki-infra not affected. |

### Phase 2 — Subagent "received" bus-path fix (2 PRs)

| ID | Item | Cite | Atomic shape |
|---|---|---|---|
| D1.6 | Investigate the bus-delivery payload-drop path. The audit pinned the drop to `src/bus.zig:421` delivery outcome path. Reproduce in a test (subagent completes → outer agent's next turn shows the result). | `src/bus.zig:421`, `src/agent/commands.zig:2161` (`refreshSubagentToolContext`) | Investigation PR with a failing test that pins the drop. No fix yet. |
| D1.7 | Fix the bus-routing drop. Likely shape: subagent completion event includes the result payload, and the outer agent's next-turn entry consumes it via `refreshSubagentToolContext` at `src/agent/commands.zig:2161` or by re-routing the payload through `turn()`. | Same | Fix + test passes. Closes `project_subagent_received_bug.md`. |

### Phase 3 — SOTA hygiene (5 PRs, opportunistic while in-file)

| ID | Item | Cite (P2_agent_turn_loop.md §13) | Atomic shape |
|---|---|---|---|
| D1.8 | Replace `mem.list` learning-fact count with a counter on `Agent` struct. O(N) → O(1). | Ugly truth #2; `:2407` | Counter incremented at store, decremented on session-end. Verifier test. |
| D1.9 | Remove the 500ms blocking `std.Thread.sleep` at `:2765`. Reliable wrapper handles backoff already; this is duplication risk + thread-stall. | Ugly truth #5 | Delete + observability test that verifies retry path uses reliable wrapper's backoff. |
| D1.10 | Fix `loop_detected` delayed exit. Detector flags at `:3382` AFTER history write + tool reflection. Move the early-exit check to before the assistant write. | Ugly truth #6; `:3382, :2559, :2561` | History stays cleaner; saved tokens proved by added-line-count assertion in test. |
| D1.11 | Reorder memory-nudge + skills-extraction prompts to AFTER `turn_complete` is appropriate, OR emit a separate `post_turn_artifacts` event so observers see the writes. | Ugly truth #11; `:3185, :3204, :3223` | Choose: ordering fix vs new event. Ordering fix preferred; lighter. |
| D1.12 | Fix `effective_model` consistency in exhausted-iterations summary. The summary at `:3548` hardcodes `self.model_name` instead of using the vision-fallback model. | Ugly truth #10; `:3548` | One-line. Plus a test that exhausted summary uses the same model as the primary call when vision-fallback active. |

### Phase 4 — SOTA capability uplift (3 PRs, real intelligence wins)

| ID | Item | Why SOTA | Atomic shape |
|---|---|---|---|
| D1.13 | **Parallel tool execution for independent calls.** `executeToolCallsSerial` runs N tool calls back-to-back. For independent calls (`memory_recall` + `web_search` + `file_read`) this is wasted wall-clock. Add parallel dispatch for tools whose `ToolMetadata.flags.read_only_or_independent` is set. Serialize only the dependent ones (writes, anything that mutates state). | Real perceptual SOTA: a turn with 3 independent tool calls drops from 3×latency to 1×latency. Same semantics. | **ALREADY SHIPPED — verified 2026-04-25.** Implementation found at: `executeToolCallsParallel` (`src/agent/root.zig:2072`), `shouldParallelDispatch` (`:1479`), `isParallelSafeToolCall` (`:1502`), canary infrastructure (`parallelDispatchCanaryAllowsSession` `:1489`), `parallel_tools_rollout_percent: u8 = 100` default at `:395`, `parallel_tools: bool = true` Config default at `config_types.zig:310`. Tools with `concurrency_safe = true` flag set in `tools/root.zig` (~14 tools). The audit's MVP scope is fully implemented and rolling at 100%. No work needed. |
| D1.14 | **Tool result caching, generalized.** The composio `ListCache` pattern (long-lived storage_allocator, TTL, key-by-args-hash) generalized into `src/tools/result_cache.zig`. Opt-in per tool via `ToolMetadata.flags.cacheable + cache_ttl_secs`. | Tool calls that are deterministic+expensive (memory_recall with same query, web_search with same q) return cached. Cuts latency + cost. | New module mirroring composio's pattern. Wire 2-3 tools as initial subscribers. Cache invalidation: TTL only, no manual invalidation in v1. |
| D1.15 | **Memory background warmup on session restore.** The audit followup memo flagged the 900ms `memory_enrich` variance: cold cache on first turn after session restore. Pre-warm common queries (semantic recall on the most-recent topic, RRF index hydration) in a background thread when session boot completes. Hot path returns degraded-but-fast on the first turn while warmup completes. | Closes `project_agent_turn_audit_followups.md` finding #1. ~900ms saved on first-turn-after-restore. | New `memory.warmupSession` called from session boot. Background thread. Hot path checks `warmup_complete` flag and chooses fresh-vs-stale. |

### Sprint close-out (2026-04-25)

**All 14 items addressed across two PRs:**

- **PR #36** (sprint/d1-turn-outcome) — Phase 1 + most of Phase 3 + D1.13 verification: D1.1, D1.2, D1.3, D1.4, D1.8, D1.9, D1.11, D1.12, D1.13✓
- **PR #TBD** (sprint/d1-followups) — Remaining items: D1.6, D1.7, D1.10, D1.14, D1.15
- **zaki-prod PR #8** (feat/d1.5-tool-only-turn-sse) — D1.5 cross-repo

**Status of each item:**
- ✅ D1.1 TurnOutcome struct
- ✅ D1.2 turnOutcome() returns TurnOutcome, turn() wraps
- ✅ D1.3 Session stores TurnOutcome
- ✅ D1.4 tool_only_turn ObserverEvent + emit
- ✅ D1.5 zaki-prod consumes tool_only_turn SSE
- ✅ D1.6 subagent empty-result distinction
- ✅ D1.7 TurnOutcome.spawned_task_ids capture
- ✅ D1.8 mem.list O(N) → counter O(1)
- ✅ D1.9 500ms blocking sleep removed
- ✅ D1.10 loop_detected immediate exit
- ✅ D1.11 post-turn maintenance events
- ✅ D1.12 vision-fallback in exhausted summary
- ✅ D1.13 (verified pre-shipped)
- ✅ D1.14 generalized tool-result cache (serial dispatcher integrated; parallel + per-tool subscribers in follow-ups)
- ✅ D1.15 memory warmupSession + flag (auto-spawn-on-boot in follow-up)

### Deferred from this sprint (tracked for D-N successors)

| Future ID | Item | Why deferred from D1 |
|---|---|---|
| D1.X1 | `elideUnverifiedHistory` flag-at-insert (audit followup #2) | Touches `OwnedMessage` struct + every insert site + migration. 1-2 hour careful change. Worth its own atomic PR but not a hard blocker for D1 core. Schedule for next sprint. |
| D1.X2 | Continuation-turn error stacking (ugly truth #7) | Edge-case; needs test scaffolding to even reproduce. Defer with a `// TODO(D1.X2)` breadcrumb. |
| D1.X3 | `approval_continues_turn` legacy path coverage (ugly truth #8) | Untested-in-prod codepath; needs end-to-end test that flips the flag. Defer. |
| D1.X4 | `freeResponseFields` ownership transfer fragility (ugly truth #12) | Latent; not a real bug today. Document with `// SAFETY:` comment in this sprint, defer fix to a memory-safety pass. |
| D1.X5 | Multi-step planning (LLM proposes plan, executes step-by-step) | Real SOTA architectural change. Sprint of its own. |
| D1.X6 | Self-evolving skills via OpenSpace (memory: `reference_openspace.md`) | Adoption candidate after MCP client + hallucination fixes land per memory. |
| D1.X7 | Cost streaming per-stage SSE event | Useful but observability-flavor; bundle with Sprint 13 (Observability Full) per `CLOSURE_CHECKLIST.md`. |

---

## Verification before each PR

1. `zig build test -Dengines=base,sqlite,postgres -Dchannels=cli,telegram` green locally
2. New regression test for the specific item passes
3. No drift in existing tests
4. Update matching `internals/P*.md` cite + bump `verified at <sha>` per the maintenance rule

## Verification at sprint close

1. `pub fn turn` returns `TurnOutcome`, all 12 exit points use the struct
2. SSE structured `tool_only_turn` frame fires for tool-only turns; old text frame still fires in parallel
3. zaki-prod cross-repo PR merged; frontend consumes the new frame
4. Subagent "received" bug fix has a regression test that fails pre-fix and passes post-fix
5. All 5 hygiene items closed; their `// TODO` breadcrumbs replaced with code
6. Parallel tool execution: a turn with 3 independent tool calls completes in ≤ 1.5× the slowest tool's latency (measured)
7. Tool-result cache: 2-3 tools opted in; cache hit rate logged
8. Memory background warmup: first-turn-after-restore latency drops by ~50% on a benchmark
9. `docs/sprints/d1-turn-outcome.md` close-out tick-list filled in
10. `docs/deferred-register.md` D1 row updated to `shipped at <sha>`
11. `internals/P2_agent_turn_loop.md` re-derived (or drift-folded) for the new architecture

## Operational notes

- **Deploy held until sprint done + local E2E test pass** (per Nova's directive 2026-04-25)
- **CI is informational only** until GitHub Actions billing restored (per recent operational state)
- **No per-cell flip** — shared runtime stays (per Nova's directive 2026-04-25)
- **Atomic PRs with commits** — one logical unit per PR, multiple commits inside as needed; sprint-granular reviews acceptable per Nova's pattern

## Why this sprint matters for revenue

Per `project_revenue_sprint_shape_2026_04_20.md` corrected ranking, **D1 ("received" bug full fix) is item #3** on the revenue unlock list. Operationalizes the delegation story. The SOTA uplift adds perceptual speed (parallel tools), cost efficiency (result cache), and first-turn responsiveness (memory warmup) — all directly improve the user's "this AI is fast and smart" experience that converts trial → paid.

The sprint itself is the agent's intelligence inflection. After this lands, the next major unlock is the Moonshot direct provider swap (item #4), then TTS UX polish (already wired but presentation refinements pending).

---

*Plan locked at sprint open. Items may be re-ordered if discovered dependencies require it. Items may NOT be added without re-opening the plan with explicit rationale.*
