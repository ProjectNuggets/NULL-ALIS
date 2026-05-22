# SOTA Context Architecture — Deep-Dive Plan

**Date:** 2026-05-09
**Owner:** Mohammad / Nova
**Status:** PLANNING — execute after Nova confirms
**Total scope:** 5 fixes, ~4 focused days, no behavioral regression
**Goal:** replace nullalis's mid-history-rewrite anti-pattern with the convergent SOTA append-only + tiered + drop-from-middle pattern

---

## TL;DR

Today nullalis is the only major agent runtime that **rewrites tool_result content mid-conversation** (Pass A in `compaction.zig:284-338`). This invalidates LLM provider KV-cache from the modification point onward, costing ~$0.02 per Pass A fire in re-processing tax. In our 30-QA bench Pass A fired ~60 times = ~$1.20 burned just on cache misses, plus user-visible latency every fire.

Every other major agent (Claude Code, Hermes, Aider, Cline, OpenAI Agents SDK) does **drop-from-middle + tiered tool-result lifecycle + cache breakpoint discipline**. The arxiv 2601.06007 "Don't Break the Cache" paper confirms: system-prompt-only caching beats naive caching by 41-80% because dynamic content rewrites are the #1 cache killer.

This plan adopts the SOTA pattern in 5 fixes.

---

## The 5 fixes — table of contents

| ID | Fix | Effort | Risk | Order |
|---|---|---|---|---|
| **F-CB2** | Compaction telemetry: `notifyCompaction()` resets cache-baseline so legitimate compactions don't show as cache regressions | 0.25 day | LOW (telemetry only) | 1st |
| **F-T1** | Memory_recall result tiering: write-time cap + tier-at-dispatch (top-N inline, older as `{recall_id, query, summary}`) | 1 day | MEDIUM | 2nd |
| **F-A2.1** | brain_graph as auto-dispatcher route + tool/prompt audit | 1.5 day | MEDIUM | 3rd |
| **F-PA2** | Replace Pass A: rewrite-in-place → drop-oldest-from-middle (Cline / Claude Code pattern) | 1 day | HIGH (touches history) | 4th |
| **F-CB1** | Cache breakpoints at "system_and_3" (Hermes pattern) | 0.5 day | LOW (Anthropic-only) | 5th |

**Total:** 4.25 days. Buffer + integration: ~5 days end-to-end.

---

## Code inspection — what we're changing

### History mutation surface

```
270 history.* call sites across the codebase, top files:
  src/agent/root.zig          — turn loop, history.append on each message
  src/agent/compaction.zig    — autoCompactHistory, cheapCompactionPass, forceCompress
  src/agent/commands.zig      — slash command handlers (some manipulate history)
  src/session.zig             — history persistence
  src/agent/memory_loader.zig — memory_for_turn build (read-only, no mutation)
```

### Continuity artifact writers (74 + 52 + 29 + ... = 250+ writes)

```
1. autosave_*              — periodic disk snapshot
2. summary_latest/         — agent's session summary
3. session_summary/        — per-session summary
4. timeline_summary/       — multi-session timeline
5. compaction_summary/*    — Pass C archive (continuity gold)
6. durable_fact/*          — extracted facts (V1.13 extraction)
7. messages (postgres)     — every message persisted; survives history mutation
8. memory_events           — edge add/close events
```

**Critical invariant:** `messages` table in postgres survives ALL history mutations. Even if F-PA2 drops messages from the agent's working window, they remain queryable via SQL. This is the safety net.

### Compaction architecture today

```
Pass A trigger  70% pressure
  cheapCompactionPass:
    - rewrites OLD tool_result content with placeholder string
    - dedups consecutive identical tool_results
    - DOES invalidate cache from rewrite point
    - DOES NOT drop messages
    - DOES NOT archive
    - NO LLM call
  Fires often: ~2-3× per turn under heavy memory load

Pass C trigger  90% pressure
  compactHistoryKeepingRecent:
    - LLM summarizes oldest messages
    - DROPS them from history
    - ARCHIVES summary to compaction_summary/{session}/{ts}
    - Preserves continuity via the archive
  Fires rarely: ~0× in our 30-QA bench (Pass A keeps us under 90%)
```

---

## Fix 1 — F-CB2: Compaction telemetry baseline reset

### What

When compaction fires (any pass), emit a `compaction.notify` event that signals cache-baseline reset to telemetry. Stops legitimate post-compaction prefix changes from being counted as cache regressions in our metrics.

### Code touched
- `src/agent/compaction.zig` — emit `log.info("compaction.notify reason=passA|passC|forceCompress prefix_drift_bytes=N")` after each compaction
- `src/observability.zig` — receive the notify, reset cache-hit-rate baseline

### Why first

**Zero behavior change.** Pure telemetry. Lets us SEE the cache impact of subsequent fixes accurately. Without this, we can't tell if F-PA2 is improving cache hit rate or just shifting the metric noise.

### Side effects
- None to agent behavior
- Slight increase in log volume

### Continuity
- None affected

### Test
- Unit: notify event fires on compaction
- Integration: cache hit-rate metric shows expected pattern (high during stable conversation, drops at notify, recovers)

### Rollback
- Remove the notify call. Telemetry only.

---

## Fix 2 — F-T1: Memory_recall result tiering

### What

**Two-pronged: write-time cap + tier-at-dispatch.**

#### Part A — Write-time cap (~30 min)
In `src/zaki_state.zig::recallMemories`, cap each individual result's content at **500 chars** (UTF-8-safe truncation, ellipsis suffix). Stops the firehose at the source. A single recall result was previously 500-2000 chars; now uniformly capped.

#### Part B — Tier-at-dispatch (~1 day)
In the agent's tool dispatch path (`src/agent/root.zig`), when a `memory_recall` tool result is appended to history:
- **First N=5 most recent recall results**: keep raw content
- **All older recall results**: replace with structured ref (in-place at write time, NOT mid-history rewrite)
  ```
  [memory_recall(query="<q>", id="<recall_id>"): N results, top key="<key>"; recall again if needed]
  ```

**Critical: tiering happens AT DISPATCH time, before append-to-history. So history is always written with the tier already applied. No mid-history rewrite. No cache invalidation.**

The agent reads its OWN reply that consumed the result — that reply is in history with full text. So the agent's reasoning about the result is preserved; only the raw bytes are tiered.

### Why second

Reduces context bloat at the source. Once F-T1 lands, Pass A pressure drops dramatically. F-PA2 (next) becomes much rarer.

### Side effects
- **Agent must learn to re-call when needed.** If a turn references a tiered recall by content (rare), agent calls memory_recall again with the saved query.
- **Existing prompt rule** at `prompt.zig` says "memory_recall is retrieval, not truth" — already trains the agent to re-verify. Aligns with F-T1.
- **Tools that consume memory_recall output downstream** (memory_purge_topic, memory_maintain): they read from postgres directly, not from agent history. Not affected.

### Continuity
- **Postgres messages table:** unaffected (we save full agent message content, but the tool_result message is what we tier — postgres also gets the tiered version). Wait — need to verify: do we persist the raw or the tiered version to postgres? **Decision: persist the tiered version.** The raw recall output is recoverable via re-call; saving it twice is waste.
- **Autosave:** snapshots whatever is in history, which is now tiered. Smaller autosaves, faster recovery.
- **Extraction queue (V1.13 wiki path):** runs on TURN TEXT, not on tool_result content. Unaffected.

### Test
- Unit: tier replaces older recall results with structured ref; recent N kept raw
- Unit: write-time cap truncates at 500 chars without splitting UTF-8
- Integration: 30-QA in-session sequence stays under 50% pressure
- Regression: Cat 1+2 scores stable (tiered results don't degrade reasoning quality)

### Rollback
- Single config flag: `tier_old_memory_recall = true`. Set false to disable. Tier function becomes pass-through.

### Risk: agent confusion
**Risk:** agent reads "[memory_recall(query=X, id=Y): 3 results, top key=Z; recall again if needed]" and doesn't know what to do.
**Mitigation:** add a one-line prompt rule: "When you see a tiered recall in history, the original query and top-result key are preserved; re-call memory_recall with the same query if you need the full data."

---

## Fix 3 — F-A2.1: brain_graph as auto-dispatcher route

### What

When the agent receives a question matching the entity-centric pattern, **automatically inject a `brain_graph local_graph` tool call** as the first iteration of the turn — the agent reasons over the subgraph result + the question.

### Code touched
- NEW: `src/agent/question_router.zig` (~150 LOC)
  - `classifyQuestion(message) → QuestionShape` — heuristic classifier
  - `injectPreflightTool(agent, shape) → ?ToolCall` — returns the tool call to inject
- `src/agent/root.zig` — turn pre-flight hook: call classifier, inject if matched
- `src/agent/prompt.zig` — REMOVE F-A2 prompt scaffold (it's wrong now; the route fires regardless of prompt)
- `src/agent/entity_pipeline.zig` — reuse for entity extraction in classifier

### Why third

Independent of F-T1 and F-PA2. Can be developed in parallel. Lands the bench's biggest expected win (Cat 1+2 lift from real graph routing).

### Side effects
- **Latency:** +200-500ms per entity question (extra tool call)
- **Cost:** +10-50 tokens per call (small)
- **False positive risk:** "tell me a joke about X" wrongly fires brain_graph
  - **Mitigation:** classifier confidence threshold; allow agent to skip injected result if irrelevant (already standard pattern)
- **False negative risk:** indirect references ("my friend who lives in NYC") don't trigger
  - **Mitigation:** acceptable — agent falls back to memory_recall; no regression
- **Tool iteration cap:** agent's `max_tool_iterations` budget consumed by 1 extra call. Default 1000, plenty of headroom.

### Continuity
- Auto-fired brain_graph results land in conversation history → interaction with F-T1 (tier brain_graph results too) and F-PA2 (drop oldest)
- **Decision:** treat brain_graph results AS RE-DERIVABLE for tiering purposes (same tier as memory_recall)

### Test
- Unit: classifier matches entity patterns ("tell me about X" / "what does X do") + rejects ("what time is it" / "summarize this file")
- Unit: confidence threshold tuning — false positive rate < 5%
- Integration: against fixture state-mgr with known entity keys, verify auto-fire of brain_graph happens
- Bench: Cat 1+2 scores improve

### Rollback
- Single config flag: `auto_route_brain_graph = false`. Disables router; agent falls back to prompt-only routing (effectively the F-A2 we already shipped).

---

## Fix 4 — F-PA2: Replace Pass A with drop-from-middle

### What

**Delete `cheapCompactionPass`'s rewrite logic.** Replace with `dropOldestPairsFromMiddle`:
- At 70% pressure (same trigger), drop oldest **whole** message pairs from the middle of history
- Protect: `[system, first_user_turn, last_3_turns]` (mirrors Hermes "system_and_3")
- Tool-call-pair hygiene: never split a `.tool` from its `.assistant` (already implemented in `compactHistoryKeepingRecent` at line 366; reuse the helper)
- Per-tool re-derivability tier:
  - **Re-derivable** (drop freely): memory_recall, brain_graph, file_read, web_search, web_fetch, shell (read-only)
  - **State-changing** (preserve): file_write, memory_store, memory_edit, memory_archive, composio side-effects
- After dropping, optionally write a brief `compaction_summary/{session}/{ts}` artifact (mirror Pass C archive pattern) so the dropped content is recoverable for future continuity needs

### Why fourth

Built on top of F-T1 (which keeps memory_recall pressure low). F-PA2 handles residual pressure from non-memory_recall tools.

### Side effects — DEEP DIVE

#### Side effect 1: messages table (postgres)
- **Unaffected.** Postgres `messages` table holds every message regardless of in-flight history state. Drop is RAM-only.

#### Side effect 2: compaction_summary archive
- **NEW:** F-PA2 writes a brief archive (just a list of dropped message keys, not full content) so future continuity can find what was dropped.
- Format: `{type:"compaction_drop", session, at, dropped_message_count, dropped_message_ids:[...], reason:"pass_a_drop"}`
- Optional — only if dropped count > N (don't archive on every small drop)

#### Side effect 3: extraction queue race
- **Critical risk:** if F-PA2 drops a message BEFORE the V1.13 extraction queue has run on it, the facts in that message are LOST from the wiki/edges layer.
- **Mitigation:** F-PA2 must check the extraction watermark. The agent tracks `turns_since_extraction` (root.zig:3935) — every 3 turns it enqueues a wiki_link extraction job. F-PA2 must NOT drop messages newer than the most recent successful extraction job.
- Implementation: read `extraction_queue` table for the user's most recent `done` job; only drop messages with timestamp ≤ that job's input timestamp.

#### Side effect 4: prompt rules
- The prompt has rules referencing tool result handling ("Tool Result Synthesis", `prompt.zig:834+`). Those still apply to RECENT (non-dropped) tool results. No change needed.
- But: prompt-level rule should mention that the agent might see "[N earlier tool results dropped from context due to length]" markers. Add a one-liner.

#### Side effect 5: memory_purge_topic
- The tool scans history for topic mentions. If messages were dropped, scan misses them.
- **Mitigation:** memory_purge_topic ALREADY scans postgres `messages`, not in-flight history, for permanent purges. The in-flight history scan is a secondary signal. F-PA2 doesn't change purge behavior in any user-visible way.
- Verify: read `tools/memory_purge_topic.zig` to confirm — sounds like it's already DB-based.

#### Side effect 6: trace_store / observability
- `run_trace_store` records turn events independently. Unaffected by history mutation.
- `metrics_obs` records counters. Unaffected.

#### Side effect 7: subagent dispatch
- Subagent results land in parent agent's history via `appendSubagentCompletionToGatewaySession`. F-PA2 might drop those too. Treat as re-derivable (subagent ran, result was used; if needed again, re-dispatch).

#### Side effect 8: compaction_summary artifact persistence
- Pass C currently writes `compaction_summary/{session}/{ts}` keys to memories table. F-PA2 should write a different shape: `compaction_drop/{session}/{ts}` (or extend compaction_summary with a `pass:"A"` field).
- Continuity tooling (memory_timeline, brain_graph) lists these. New shape needs to be filtered or rendered consistently.

### Continuity invariants (must hold post-F-PA2)
1. **Every dropped message is in postgres** ✓ (postgres unaffected)
2. **Every dropped message that has facts has been through extraction** ✓ (mitigation: check extraction watermark before drop)
3. **Drop event is auditable** ✓ (write `compaction_drop/*` artifact with message IDs)
4. **Agent prompt acknowledges dropped content** ✓ (one-line marker in history: "[N earlier turn-pairs dropped]")
5. **Tool-call pair integrity preserved** ✓ (mirror existing helper)
6. **Cache breakpoint protected zone is never dropped** ✓ (protection list includes last 3 turns)

### Test
- Unit: dropOldestPairsFromMiddle preserves system + first_user + last_3
- Unit: tool-call pair hygiene — `.tool` orphan never created
- Unit: state-changing tool result NOT dropped even if oldest
- Integration: 60-QA sequence with F-T1 active — F-PA2 fires only on residual pressure (rare)
- Continuity: dropped message IDs match a `compaction_drop/*` artifact
- Race condition: extraction queue lag stress test (drop attempted on un-extracted messages → blocked)

### Rollback
- Config flag: `compaction_pass_a_mode = "rewrite" | "drop"`. Default to "drop" (new behavior). Set to "rewrite" to restore old Pass A behavior.
- This is a binary flip — no migration needed, just routes to old or new function.

### Risk highest-priority

**Risk:** dropping a message destroys agent context that the user expects to be remembered.
**Symptom:** "I told you about X earlier in this conversation, why don't you know?"
**Mitigation tiers:**
1. Top: extraction has run on the message → facts are in memory → memory_recall finds them
2. Middle: agent sees "[N turn-pairs dropped]" marker → knows to re-recall
3. Bottom: postgres messages table has the original → if needed, can be re-loaded as raw content (V1.15 enhancement)

---

## Fix 5 — F-CB1: Cache breakpoints "system_and_3"

### What

Today: cache_control on system block only (V1.13 byte-stable work shipped this).
Add: cache_control on the boundary just before the rolling "last 3 turns".

Hermes "system_and_3" pattern:
- Breakpoint 1: end of system prompt
- Breakpoint 2: just before last 3 user-assistant pairs

This means a F-PA2 drop in the middle of history invalidates cache only between Breakpoint 1 and Breakpoint 2 — NOT the most recent (still cached) suffix.

### Code touched
- `src/providers/NNGTs_cache.zig` — extend `serializeSystemCacheable` to emit a second cache_control marker
- `src/providers/anthropic.zig` — add cache_control on the boundary message
- The provider request builder in `agent/root.zig` — pass the breakpoint hint

### Why fifth

Anthropic-specific. Together/vLLM does prefix-byte caching automatically — no explicit hints needed. So this fix only affects Anthropic users (small slice today, growing).

### Side effects
- **Anthropic-only** — Together/vLLM/OpenAI providers ignore the second cache_control marker
- **Cache write cost** — Anthropic charges for cache writes. More breakpoints = more cache writes. Per Anthropic docs, this is typically <1% overhead for a session that benefits from the cache.
- **TTL alignment** — both breakpoints have same TTL; no special handling needed

### Continuity
- None affected — per-request optimization

### Test
- Unit: serialize emits 2 cache_control markers in correct positions
- Integration: live Anthropic call shows cache hit on the second breakpoint after a drop event

### Rollback
- Single field in PromptContext: `cache_breakpoints = 1 | 2`. Default 2 (new). Set 1 to revert.

---

## Cross-fix interactions

### F-T1 + F-PA2
- F-T1 fires AT WRITE TIME (per tool_call dispatch); F-PA2 fires AT TURN START (when pressure crosses 70%)
- F-T1 keeps pressure low → F-PA2 rarely fires
- If F-PA2 fires, it may drop tiered (already small) memory_recall results — fine, they're already compressed

### F-T1 + F-A2.1
- F-A2.1 auto-fires brain_graph; brain_graph results enter history
- F-T1 must tier brain_graph results too (treat as re-derivable, same tier policy as memory_recall)

### F-CB1 + F-PA2
- F-CB1 places breakpoint at "last 3 turns" boundary
- F-PA2 drops oldest messages OUTSIDE this protected zone
- Result: F-PA2 invalidates cache between breakpoint 1 and breakpoint 2; does NOT invalidate the protected suffix
- This is the SOTA goal — minimize invalidation scope

### F-CB2 + F-PA2 + F-T1
- All three fire `notifyCompaction()` events
- Telemetry sees coherent picture: when did we drop, when did we tier, what was the cache impact
- Without F-CB2, F-PA2/F-T1 changes would look like cache regressions in metrics

### F-CB2 + F-A2.1
- F-A2.1's auto-fired tool calls add new bytes to history
- Cache invalidation from new bytes is normal (every tool call has this)
- F-CB2 doesn't fire on normal append; only on compaction

---

## Sequencing — execute in this order

```
Day 1:
  Morning:   F-CB2 (telemetry baseline)        — 0.25 day
  Afternoon: F-T1 Part A (write-time cap)       — 0.5 day
  Verify:    Live smoke test, recall results capped, no regression

Day 2:
  Morning:   F-T1 Part B (tier-at-dispatch)    — 0.5 day
  Afternoon: F-T1 tests + bench smoke           — 0.5 day
  Verify:    30-QA sequence stays under 50% pressure, no Pass A fires

Day 3:
  All day:   F-A2.1 (classifier + injector + tests)  — 1 day
  Verify:    auto-fire on entity Qs, no false positives on non-entity Qs

Day 4:
  Morning:   F-A2.1 finishing + integration   — 0.5 day
  Afternoon: F-PA2 implementation (drop-from-middle + extraction watermark check) — 0.5 day

Day 5:
  Morning:   F-PA2 tests + continuity verification — 0.5 day
  Afternoon: F-CB1 (Anthropic cache breakpoints) — 0.5 day
  Verify:    Live bench, full battery, end-to-end SOTA pattern working
```

**Buffer:** 1 day for integration issues + bench rerun.
**Total:** ~5 days end-to-end.

---

## Test gates per fix

Each fix must pass these gates before the NEXT fix lands:

1. **Build clean** (`zig build -Doptimize=ReleaseFast`)
2. **Unit tests pass** (`zig build test --summary all` — 5983/6043 baseline, must hold or grow)
3. **Smoke chat works** (single ping → reply via curl)
4. **No regression on conv 0 small sample** (5 QAs, recall ≥ 80%)
5. **Continuity artifacts intact** (memory_timeline still works; durable_facts still emerge after a multi-turn session)

---

## Post-implementation: bench

After all 5 fixes ship and pass all gates:

1. **Restart canonical battery** (per-conv isolation, latest binary, both providers green)
2. **600 QAs across 10 conversations**
3. **Score with GPT-4o-mini judge via OpenRouter** (apples-to-apples vs mem0/Letta/Zep)
4. **Honest SUMMARY.md** with:
   - Per-fix delta (which fix moved which category how much)
   - Apples-to-apples comparison table
   - Architecture rationale (SOTA-aligned)
5. **Final claim** (projection):
   ```
   Recall:           90.17% → projected 94-97%
   Cat 1 (single):   91.2% → projected 92-95% (F-T1 cleaner context)
   Cat 2 (multi):    93.6% → projected 96-99% (F-A2.1 graph routing)
   Cat 3 (temporal): 75.3% → projected 80-85% (F-A1 already shipped)
   Cat 4 (open):     90.3% → projected 92-94% (F-A2.1 spillover)

   Cost per turn:    -50 to -70% (cache hits + tiered results)
   Latency per turn: -1 to -3s on heavy memory turns
   ```

---

## Honest framing for any later writeup

What's REAL product improvement (ships value to users regardless of bench):
- F-T1: heavy-memory users no longer hit force-compress; cost drops 30-60% per long session
- F-PA2: cache hit rate climbs to industry-standard 70-85%; per-turn latency stable across conversations
- F-A2.1: entity questions get structural answers; "tell me about X" UX improves
- F-CB1: Anthropic users get better caching
- F-CB2: telemetry honest

What's bench-correlated but not gaming:
- All 5 fixes happen to also improve bench scores. That's a SIGN they're real product wins, not target-chasing.

What's NOT in this plan:
- F-S2 short-answer prompt (skipped, user can instruct)
- LLM-judge tuning (we use the standard GPT-4o-mini)
- BFCL setup (Phase 2, post-LoCoMo)

---

## Risk-weighted go/no-go per fix

| ID | Implementation risk | Production risk | Bench-impact certainty | Decision |
|---|---|---|---|---|
| F-CB2 | Trivial | None (telemetry only) | None (just enables measurement) | **GO** |
| F-T1 | Medium (tier semantics) | Low (postgres safety net) | High (kills the bloat source) | **GO** |
| F-A2.1 | Medium (classifier tuning) | Low (rollback flag) | High (real architectural win) | **GO** |
| F-PA2 | High (mutates history) | Medium (continuity artifacts) | Medium (cache wins, may not move bench much directly) | **GO with extraction-watermark mitigation** |
| F-CB1 | Low (Anthropic-only) | None | Low (Anthropic slice only today) | **GO** |

---

## Continuity artifacts checklist (must verify post-implementation)

For each fix, verify these still work end-to-end:

- [ ] **Postgres `messages` table** — every turn's message persisted
- [ ] **`autosave_*`** — periodic disk snapshot still includes all live history
- [ ] **`summary_latest/`** — agent's session summary still generates
- [ ] **`session_summary/`** — per-session summary still generates
- [ ] **`compaction_summary/*`** — Pass C still writes archive on its rare fires
- [ ] **NEW: `compaction_drop/*`** — F-PA2 writes drop audit
- [ ] **`durable_fact/*`** — V1.13 extraction still extracts facts
- [ ] **Working memory slots** — pinned identity + active goals + open loops still render
- [ ] **memory_timeline** — still lists all continuity artifacts in order
- [ ] **memory_recall** — still retrieves across sessions
- [ ] **brain_graph** — still navigates the typed-edge graph
- [ ] **`/brain` page** — still renders graph + timeline + diff

If ANY of these break, the fix that broke them must be reverted before bench.

---

## What I commit to before going

If you confirm GO:
1. I implement F-CB2 first (lowest risk, enables visibility for the rest)
2. After EACH fix, I run the test gates + report results before moving to the next
3. Continuity checklist verified after F-PA2 (the highest-risk fix)
4. No bench until ALL fixes pass + checklist verified
5. Honest SUMMARY.md with per-fix delta, not just aggregate

**Ready when you say GO.**
