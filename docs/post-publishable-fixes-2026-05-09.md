# Post-publishable architecture fixes (2026-05-09)

After diagnosing the LoCoMo bench run, three real product issues surfaced
that need code-level fixes (not prompt scaffolds). All are filed for
post-publishable execution.

The fixes compound:
- **F-A2.1** ships brain_graph as a real default for entity questions → SOTA-class memory recall
- **F-T1** strips memory_recall bloat from history → reduces cost + context contamination
- **F-PA1** makes Pass A information-preserving → middle ground between cheap-but-lossy and expensive-LLM

Together: real product wins. Each ALSO improves bench scores, but that's
secondary to shipping value.

---

## F-A2.1 — brain_graph as automatic dispatcher route

### Problem
F-A2 (commit 47be6fc) added a prompt instruction telling the agent to call
`brain_graph local_graph` for entity-centric questions. Inspection during
the canonical bench run showed **0 brain_graph tool calls across 145
memory_recall calls** — the agent ignored the prompt entirely. Prompt
ordering bias (older narrow rule wins) + LLM convenience bias
("memory_recall already gave me something, why escalate?") killed it.

The `brain_graph` tool is fully wired in `src/tools/brain_graph.zig` —
`tool_name = "brain_graph"`, 4 actions, registered in the tool catalog.
We have the engine; we just didn't route to it.

### Goal
When the user asks an entity-shaped question, the agent automatically
fires `brain_graph local_graph(center_key=<entity>)` BEFORE composing the
reply — not as a prompted suggestion but as a dispatcher decision.

### Approach
1. **Question classifier** in `src/agent/root.zig` (or new file
   `src/agent/question_router.zig`). Heuristic + lightweight:
   - Capitalized named entity in the message?
   - Question patterns: `tell me about X`, `what does X do`, `what events
     involve X`, `what's X been up to`, possessive `<X>'s ...`
   - Confidence threshold to avoid over-triggering on common nouns
2. **Pre-flight tool injection** at agent turn start:
   - When classifier matches: resolve entity → canonical key (fast index
     lookup, no full memory_recall needed)
   - Inject a `brain_graph local_graph` tool call as the agent's first
     iteration — agent reasons over the subgraph result + the user
     question together
3. **Cold-start fallback** (the F-A2 lesson): if entity has no key, log
   it and fall back to memory_recall — don't synthesize an empty graph

### Hooks that exist
- `src/agent/entity_pipeline.zig` already does mention extraction with
  coreference (V1.14 wiki path). Reuse the extractor for the classifier.
- `src/zaki_state.zig::recallMemories` already has fast key lookup.
- `src/tools/brain_graph.zig::executeLocalGraph` is the destination.

### Files to touch
- `src/agent/root.zig` — pre-flight router hook
- `src/agent/question_router.zig` — NEW, ~150 LOC for the classifier +
  injector logic
- `src/agent/prompt.zig` — REMOVE the F-A2 prompt scaffold (it's lying
  to the agent now)

### Tests
- Unit: classifier matches "tell me about X" / "what does X do" patterns;
  rejects "what time is it" / "summarize this file"
- Integration: against a fixture state-manager with known entity keys,
  verify a turn auto-fires brain_graph

### Estimate
**~1.5 days** (classifier + router + tests + integration)

### Bench impact
Expected: Cat 1 (single-hop) +2-5pp, Cat 2 (multi-hop) +5-10pp on
entity-centric questions. Cat 3 unchanged (counterfactual is F-A1's
domain).

### Audit outcome (broader scope per Nova)
**Same exercise for ALL tools.** Today the agent uses tools by reading
the protocol and deciding. We should make MORE tools auto-fire when
their pattern matches:

| Question pattern | Auto-tool |
|---|---|
| "When did X happen?" / "what did I do yesterday?" | `memory_timeline` |
| "What changed in my brain on DATE?" | `brain_graph diff` |
| "What CONNECTS X to Y?" | `brain_graph local_graph` (already F-A2.1) |
| "What topics am I focused on?" | `brain_graph communities` |
| "What did I save but never link?" | `brain_graph orphans` |
| "Tell me about X" (entity) | `brain_graph local_graph` (F-A2.1 already) |
| "Read FILE X" / "summarize X.md" | `file_read` (already routed via prompt) |

Most are prompt-routed today. F-A2.1 establishes the pattern; the audit
is "for each entry above, verify the route fires reliably and adds value."

**Audit estimate: +0.5-1 day.**

---

## F-T1 — strip memory_recall results from history after use

### Problem
Every `memory_recall` call retains its raw result (5-10 results × 500-
2000 chars) in conversation history. Heavy memory-using sessions
accumulate fast:

```
LoCoMo bench observation (sample 0, qa_31):
  226 messages in history
  Pass A firing 60+ times (placeholder substitution)
  Token pressure 70% → 85% over ~30 QAs
  Per-QA history growth: ~5-7 messages
```

A real production user asking 15-30 memory-aware questions in a session
hits the same curve. Force-compress eventually fires, drops messages,
agent loses context, user-facing quality drops.

The agent's brain HAS the recalled facts; carrying the raw recall output
forward duplicates information AND inflates cost (every subsequent
provider call sends the bloated history).

### Goal
After a memory_recall result is consumed by the agent's current turn,
compress it to a structured placeholder that preserves WHAT was
retrieved without the raw bytes.

### Approach
**Two-pronged: write-time cap + post-turn compress.**

#### 1. Write-time result-length cap (cheap)
In `src/zaki_state.zig::recallMemories`, cap each individual result's
content at ~500 chars. Truncate with ellipsis. Stops the firehose at
the source.

#### 2. Post-turn structured-compress (real fix)
After the agent's final reply in a turn, walk back through this turn's
tool_result messages. For each `memory_recall` result, replace with:

```
[memory_recall("<query>"): <N> results, top key=<top_key>; consumed by reply above]
```

Information preserved:
- WHICH query was made (so the agent can re-call if needed)
- HOW MANY results came back (signal of recall quality)
- TOP RESULT'S KEY (so the agent can re-fetch one specific one)
- That this was consumed (no need to re-process)

Token cost: ~80 bytes per call vs ~5-10KB raw. **40-100× compression.**

This is information-preserving compression, not destruction. Different
from Pass A's placeholder which destroys the data structure too.

### Files to touch
- `src/zaki_state.zig::recallMemories` — per-result length cap (~5
  lines)
- `src/agent/root.zig` — add `postTurnHistoryCompress` hook after the
  final reply lands
- `src/agent/compaction.zig` — add `structuredRecallCompress` helper
  (Pass A becomes Pass A' with structured replacement)

### Tests
- Unit: structuredRecallCompress preserves query + key + result-count
- Unit: write-time cap truncates at 500 chars without splitting UTF-8
- Integration: 30-QA in-session sequence stays under 50% pressure

### Estimate
**~1 day** (per-result cap is trivial; post-turn compress is the
substance)

### Bench impact
Expected: enables sample 0 to complete cleanly with no force-compress
pressure. Late-QA scores no longer degrade. Probably +2-4pp on bench
overall just from "the agent doesn't run out of context."

### Production impact
Heavy-memory users (15+ recall-driven turns in a row) no longer hit
force-compress. Token costs per heavy session drop 30-60%. Tier-1
support category eliminated.

---

## F-PA1 — Pass A becomes information-preserving

### Problem
Pass A's placeholder is `"[tool_result truncated — see earlier context]"`
— literally tells the agent "the data was here but I deleted it." If a
subsequent turn needs to re-reference what was recalled, the agent sees
nothing. Compounds with F-T1 (which addresses memory_recall specifically;
F-PA1 addresses all tool_results).

### Goal
Pass A's placeholder carries enough information for the agent to either
(a) reason without re-fetching, or (b) make an informed decision to
re-call the tool.

### Approach
Per-tool placeholder template:

| Tool | Placeholder |
|---|---|
| `memory_recall` | `[memory_recall("<q>"): <N> results, top key=<key>; consumed]` |
| `brain_graph` | `[brain_graph <action>(<center>): <N> nodes <M> edges; consumed]` |
| `web_search` | `[web_search("<q>"): <N> results, top URL=<url>; consumed]` |
| `file_read` | `[file_read("<path>"): <bytes> bytes, lines <a>-<b>; consumed]` |
| `shell` | `[shell("<cmd>"): exit=<code>, <N> output bytes; consumed]` |
| Other | `[<tool>: <length> bytes; consumed]` (current behavior) |

The agent can read these and decide whether to re-call. They're tiny
(50-150 bytes vs 1-10KB raw).

### Files to touch
- `src/agent/compaction.zig::cheapCompactionPass` — replace single
  placeholder with per-tool structured placeholder

### Tests
- Unit: each tool's placeholder format is parseable by the agent (round-
  trip check)
- Unit: token estimate verifies 40-100× compression vs raw

### Estimate
**~half day** (replace one function body, add per-tool dispatch)

### Bench impact
Same direction as F-T1, smaller magnitude (Pass A is a fallback when
F-T1's per-turn compress hasn't fired yet). Expected +1-2pp on bench.

### Production impact
Long-running sessions retain useful context structure even after Pass A
fires. No silent data loss.

---

## Combined plan

### Sequence
```
Phase A — Quick wins (1.5-2 days):
  F-T1 (write-time cap)        — 1h
  F-PA1 (structured placeholders) — 4h
  → Test: rerun LoCoMo battery, expect Cat 1/2 stable, no degradation

Phase B — F-A2.1 (1.5-2 days):
  Question classifier
  Pre-flight tool injector
  brain_graph routing wired
  → Test: expect Cat 2 +5-10pp from real graph routing

Phase C — Audit + cleanup (0.5-1 day):
  Walk every tool, verify auto-route works
  Cut dead prompt scaffolding (F-A2's prompt becomes obsolete)
  → Test: full battery once more
```

**Total: 3.5-5 focused days. Real product improvements, no test gaming.**

### Order rationale
- F-T1 + F-PA1 first because they FIX A REAL PRODUCTION BUG (heavy users
  get force-compress)
- F-A2.1 second because it requires the classifier work + dispatcher
  changes which are bigger surface
- Audit last because it benefits from the patterns established in A2.1

### Bench compounding
After all three:
- F-T1 + F-PA1: enables clean 60-QA runs, no late-QA degradation → +2-4pp
- F-A2.1: real graph routing on entity Qs → +5-10pp Cat 2 + Cat 1
- Audit: smaller wins from cleaning prompt-vs-route mismatches → +1-3pp

**Realistic projection: 90.17% baseline → 95-98% after all three.**

That would put us within range of ByteRover (92.2% on Gemini-3) and
likely #1 in the Kimi-class cohort. Headline achievable: "nullalis
ranks at the top of LoCoMo memory benchmark for the Kimi-K2.6 model
class."

---

## What we're NOT doing in this plan

- **F-S2 short-answer prompt**: still skipped — user can instruct, not our
  concern.
- **Per-judge tuning**: GPT-4o-mini judge stays as the publishable
  apples-to-apples scorer. Don't tune the judge.
- **Bench-shape gaming**: every fix here is a real product improvement;
  the bench is the witness, not the target.

## When to ship

After the publishable run completes (whenever providers stabilize), we
report the **honest baseline** with the F-A1 win + F-A2 disclosure
(prompt-only, didn't fire). Then this doc becomes the V1.14.6 sprint
plan. Each phase ships independently with its own bench delta to
verify.
