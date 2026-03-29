# Memory Architecture Map

Last updated: 2026-03-28
Branch context: `feat/summary-first-continuity-v1`

This document describes how memory works in the live codebase today, what the
agent actually sees per turn, what to tune first, and what to build next.

The goal is practical clarity:
- how continuity works now
- where summaries fit
- how session and global memory interact
- which files control behavior
- how to evolve memory without breaking the runtime

## 1. As Is

The current memory system has 4 real layers:

1. Active session history
- The current lane/session transcript lives in `self.history`.
- Each user turn is enriched with memory context, then appended into history.
- This is still the main source of immediate conversational coherence.

Files:
- `src/agent/root.zig`
- `src/agent/compaction.zig`

Key behavior:
- Memory is injected before the user message is added to history.
- History is then trim-compacted, not LLM-summarized on the hot turn path.

2. Semantic continuity objects
- These are written at session boundaries.
- They are now the primary continuity layer for later turns.

Objects:
- `session_summary/{session_id}/{timestamp}`
- `timeline_summary/{session_id}/{timestamp}`
- `summary_latest/{session_id}`
- `context_anchor_current`
- `timeline_index/current`

Provenance behavior:
- semantic summary bodies stay compact and semantic
- provenance is stored in metadata surfaces instead:
  - `summary_latest/{session_id}`
  - `context_anchor_current`
  - `timeline_index/current`

Files:
- `src/agent/commands.zig`
- `src/memory/lifecycle/summarizer.zig`
- `src/session.zig`

3. Durable semantic facts
- `Key fact:` lines extracted from summaries become global `.core` memories.
- These are the closest thing to stable lifetime semantic memory today.

Objects:
- `durable_fact/{timestamp}/{idx}`

Files:
- `src/memory/lifecycle/summarizer.zig`
- `src/agent/commands.zig`

4. Evidence / archive layer
- Raw transcripts and checkpoints still exist.
- They are kept for exact-history or recovery use, not as the primary continuity carrier.

Objects:
- `session_checkpoint_{timestamp}`
- session transcript in history/session store
- autosave entries

Files:
- `src/agent/commands.zig`
- `src/session.zig`
- `src/memory/root.zig`

## 2. What The Agent Sees

### Regular turn enrichment order

Per turn, the runtime now tries to give the agent this order of context:

1. `summary_latest/{current_session_id}`
2. `context_anchor_current`
3. relevant `durable_fact/*`
4. up to 2 relevant `timeline_summary/*` from other sessions
5. generic recall / retrieval results
6. recent raw transcript already in current history

Files:
- `src/agent/memory_loader.zig`
- `src/agent/root.zig`

Important limits:
- default recall limit: `5`
- cross-session timeline fallback cap: `2`
- injected memory context budget: `4000` bytes

This means the agent does not see "all memory".
It sees a small, prioritized continuity bundle.

### What gets filtered out

By default, the runtime suppresses internal memory noise:
- `autosave_user_*`
- `autosave_assistant_*`
- `last_hygiene_at`
- bootstrap prompt keys
- markdown parser artifact keys like `MEMORY:8`

Files:
- `src/memory/root.zig`
- `src/agent/memory_loader.zig`
- `src/tools/memory_list.zig`
- `src/tools/memory_recall.zig`

### What the tools see

The agent can still explicitly inspect memory with tools:

- `memory_store`
  - defaults to session scope unless `scope="global"`
- `memory_recall`
  - defaults to session scope unless `scope="global"`
- `memory_list`
  - defaults to session scope unless `scope="global"`

Files:
- `src/tools/memory_store.zig`
- `src/tools/memory_recall.zig`
- `src/tools/memory_list.zig`

This matters because per-turn memory and tool-visible memory are related but not identical.
Turn enrichment is now smarter than the generic tool default.

Tool-visible provenance:
- memory tools now derive and display:
  - `channel`
  - `lane`
  - `session`
- provenance is derived from `session_id` when present, otherwise from summary keys

Files:
- `src/memory/root.zig`
- `src/tools/memory_recall.zig`
- `src/tools/memory_list.zig`

## 3. Session Boundaries And Summary Triggers

### What counts as a real session boundary today

Explicit:
- `/new`
- `/reset`
- `/restart`

Implicit:
- `ttl_recycle`
- `ttl_evict`
- `idle_evict`

Files:
- `src/agent/commands.zig`
- `src/session.zig`

### Where timeout comes from

Product settings map `session_timeout_minutes` into `agent.session_ttl_secs`.
Default today is `30` minutes.

Important nuance:
- summaries are not written by an exact wall-clock timer at minute N
- they are written when session maintenance observes that the idle/TTL boundary has been crossed

Files:
- `src/user_settings.zig`

### Important current limitation

The system writes semantic summaries at real session boundaries, but not during a long uninterrupted session.

That means:
- short-to-medium usage works well
- marathon sessions may still rely heavily on transcript until a boundary is hit

This is a known evolution point, not a bug.

## 4. Summary Shape

The structured summary format is now:

```text
focus: ...
decisions:
- ...
open_loops:
- ...
next:
- ...
Key fact: ...
```

Rules:
- `focus:` is mandatory
- `decisions`, `open_loops`, and `next` must exist
- `Key fact:` is the durable fact promotion marker
- checkpoint metadata should not be in the summary body

Files:
- `src/memory/lifecycle/summarizer.zig`

Fallback behavior:
- if provider summary generation fails
- or parsing fails
- a structured fallback summary is built from checkpoint content

Files:
- `src/agent/commands.zig`

## 5. Retrieval System As Of Now

### Raw memory backend recall

The underlying memory backend still fundamentally does keyword recall unless a higher-level retrieval engine is in play.

Tenant Postgres recall currently ranks by:
- `key ILIKE`
- `content ILIKE`
- then `updated_at DESC`

Files:
- `src/zaki_state.zig`

### MemoryRuntime retrieval

When `MemoryRuntime` is available, `rt.search(...)` uses the retrieval engine and rollout policy.
That can mean:
- keyword-only
- hybrid
- shadow hybrid

Files:
- `src/memory/root.zig`
- `src/memory/retrieval/engine.zig`

Important nuance:
- even with the retrieval engine, the summary-first direct lookups are performed first in `memory_loader`
- so the semantic continuity layer does not depend only on retrieval ranking

## 6. What To Tune First

These are the safest, highest-value tuning levers.

### A. Increase summary quality before increasing summary volume

Do this first:
- improve `focus`
- improve `open_loops`
- improve `next`
- improve which `Key fact:` lines get extracted

Files:
- `src/memory/lifecycle/summarizer.zig`
- `src/agent/commands.zig`

Why:
- better semantic density is more valuable than more summaries

### B. Tune memory_loader ordering and budget, not just backend recall

Best next tuning points:
- `DEFAULT_RECALL_LIMIT`
- `TIMELINE_FALLBACK_LIMIT`
- `MAX_CONTEXT_BYTES`
- skip/allow rules in `shouldSkipGenericEntry`

Files:
- `src/agent/memory_loader.zig`

Why:
- this directly controls what the model sees per turn

### C. Tune product modes with memory in mind

Current product settings change:
- queue behavior
- max history messages
- summarizer enabled/window/max tokens
- session timeout

Files:
- `src/user_settings.zig`

Why:
- the user-facing "Fast / Balanced / Deep" modes already influence continuity behavior

### D. Keep transcripts as evidence, not primary continuity

Do not revert to transcript-heavy continuity by default.
Use summaries and durable facts first.

Files:
- `src/agent/root.zig`
- `src/agent/memory_loader.zig`
- `src/agent/commands.zig`

## 7. What To Build Next

These are the next strong memory evolutions after the current summary-first baseline.

### 1. Milestone summaries for long uninterrupted sessions

Problem:
- long sessions may not hit a boundary for hours or days

Next move:
- create milestone summaries after N meaningful turns or after summary-window overflow
- do not end the session
- do not summarize every turn

Likely files:
- `src/agent/root.zig`
- `src/agent/commands.zig`
- `src/memory/lifecycle/summarizer.zig`

### 2. Topic / project memory indices

Problem:
- `timeline_index/current` is a hot TOC, not a semantic organizer

Next move:
- optional lightweight indices such as:
  - `project_index/current`
  - `people_index/current`
  - `open_loops/current`

Likely files:
- `src/agent/commands.zig`
- `src/tools/memory_recall.zig`

### 3. Explicit timeline recall tool behavior

Problem:
- the agent can inspect memory, but there is no dedicated "episode timeline" surface

Next move:
- add a dedicated memory or timeline tool mode that:
  - lists recent summaries
  - filters by session/channel/date
  - returns timeline summaries before raw transcript

Likely files:
- `src/tools/memory_recall.zig`
- `src/tools/memory_list.zig`

### 4. Better durable fact governance

Problem:
- all `Key fact:` promotion is currently parser-marker based

Next move:
- improve what counts as a durable fact
- distinguish:
  - stable identity/preferences
  - long-running projects
  - temporary session-only facts

Likely files:
- `src/memory/lifecycle/summarizer.zig`
- `src/agent/commands.zig`

### 5. Cross-channel continuity policy

Current state:
- same-user other-session continuity comes from bounded `timeline_summary/*`

Next move:
- make channel-aware continuity more deliberate:
  - app + Telegram + future channels
  - still no raw transcript bleed by default

Likely files:
- `src/agent/memory_loader.zig`
- `src/session.zig`
- `src/user_settings.zig`

## 8. File-By-File Map

### `src/agent/root.zig`
- injects memory into user turns
- appends enriched message into history
- trim-compacts active history
- is the hot path for what the model actually receives

### `src/agent/memory_loader.zig`
- decides memory injection order
- decides direct summary/anchor lookup
- decides cross-session summary fallback
- enforces byte budget and filtering

### `src/agent/commands.zig`
- writes checkpoints
- writes session summaries
- writes timeline summaries
- writes summary pointers and index
- promotes durable facts

### `src/memory/lifecycle/summarizer.zig`
- defines summary prompt shape
- parses structured summary output
- extracts `Key fact:` lines

### `src/session.zig`
- defines TTL recycle / eviction boundaries
- is where implicit session-end behavior lives

### `src/user_settings.zig`
- maps product settings into:
  - queue mode
  - queue cap
  - history size
  - summarizer config
  - session timeout

### `src/memory/root.zig`
- defines memory interfaces
- holds runtime retrieval configuration
- defines internal-memory filtering helpers

### `src/memory/retrieval/engine.zig`
- retrieval engine layer
- keyword / hybrid retrieval plumbing

### `src/zaki_state.zig`
- tenant Postgres persistence and recall logic
- important when understanding raw backend ranking

### `src/tools/memory_store.zig`
- explicit memory persistence tool

### `src/tools/memory_recall.zig`
- explicit memory search tool

### `src/tools/memory_list.zig`
- explicit memory browsing tool

## 9. Practical Debugging Checklist

If memory feels weak or inconsistent, inspect in this order:

1. Did a real session boundary occur?
- if not, no session-end summary will exist yet

2. Does `summary_latest/{session_id}` exist?
- if not, the lane has no latest semantic handoff yet

3. Does `timeline_summary/{session_id}/{timestamp}` exist?
- if not, cross-session continuity for that episode is missing

4. Does `context_anchor_current` point at the expected lane?

5. Are `durable_fact/*` entries being extracted from summaries?

6. Is `memory_loader` injecting summaries before generic recall?

7. Is the relevant memory hidden by scope?
- tools default to session scope

8. Is context budget clipping relevant summaries out?

## 10. Recommended Working Principle

Keep this mental model:

- transcript is for immediate coherence
- summaries are for episodic continuity
- durable facts are for long-term identity
- checkpoints are for recovery
- indices are for discovery

That is the current best shape in the codebase.
Do not collapse them back into one undifferentiated memory bucket.

## 11. Research To Roadmap Memo

This section translates current memory research and the implementation patterns
from the repos discussed in this project into a `nullalis`-specific roadmap.

The short version:
- bigger context windows are helpful but not sufficient
- transcript replay alone is not a durable memory strategy
- layered memory beats one giant prompt
- topic-aware episodic memory is stronger than timestamp-only recall
- pre-compaction or milestone memory flush is a high-value next step

### What The Research Validates

#### A. Long context alone is unreliable

`Lost in the Middle` showed that models often under-use information placed in
the middle of long prompts.

What this means for `nullalis`:
- do not treat larger prompt windows as the main memory strategy
- keep active turn context compact
- retrieve high-value memory objects instead of replaying whole history

Source:
- https://arxiv.org/abs/2307.03172

#### B. Layered memory is the right architectural shape

`MemGPT`, `LongMem`, and later agent-memory work converge on a split between:
- working memory
- external memory
- durable memory
- retrieval-on-demand

What this means for `nullalis`:
- the current split between transcript, summaries, durable facts, and archive is directionally correct
- the next step is to formalize a true mutable state layer

Sources:
- https://arxiv.org/abs/2310.08560
- https://arxiv.org/abs/2306.07174

#### C. Episodic memory units should be meaningful, not only chronological

`SeCom`, `Membox`, and newer long-horizon dialogue memory papers all point to
the same issue: turn-level fragments and naive session dumps are weaker than
coherent topical/episodic units.

What this means for `nullalis`:
- `timeline_summary/*` is a good start
- but session-end summaries alone are not enough for very long sessions
- the next evolution should be milestone or topic summaries, not more transcript

Sources:
- https://www.microsoft.com/en-us/research/project/secom/
- https://arxiv.org/abs/2601.03785

#### D. Structured persistent memory beats transcript carry-forward

`Memori`, `AdaMem`, and `HiMem` all reinforce the same product lesson:
- keep compact structured memory objects
- separate current state from episodic history
- keep raw dialogue as evidence, not the default continuity carrier

What this means for `nullalis`:
- summary-first continuity is the right base layer
- future `state/*`, `intention/*`, `pattern/*`, and `learning/*` objects are the right next layer

Sources:
- https://arxiv.org/abs/2603.19935
- https://arxiv.org/abs/2603.16496
- https://arxiv.org/abs/2601.06377

### What The Shared Repos Validate

#### OpenClaw

Strong lessons from OpenClaw:
- stable prompt files are useful:
  - `SOUL.md`
  - `USER.md`
  - `MEMORY.md`
- long sessions need a pre-compaction memory flush
- compaction should preserve active task continuity, not only reduce tokens

What to borrow:
- a milestone or pre-compaction semantic flush
- not a transcript-heavy reset model

#### PageIndex

Strong lesson from PageIndex:
- summaries need an index/discovery layer
- retrieval should not depend only on time ordering

What to borrow:
- lightweight flat or topical indices
- not a full tree or indexing subsystem in the next step

## 12. Nullalis Memory Roadmap

The roadmap below is intentionally phased.
It is ordered by leverage and safety, not novelty.

### Phase 0: Current Baseline

Status:
- active transcript in `self.history`
- summary-first continuity at real session boundaries
- durable fact extraction from structured summaries
- provenance-aware summary pointers
- lifecycle-safe mutable memory for editable `.core` state

Files:
- `src/agent/root.zig`
- `src/agent/memory_loader.zig`
- `src/agent/commands.zig`
- `src/memory/lifecycle/summarizer.zig`
- `src/memory/root.zig`
- `src/memory/engines/markdown.zig`
- `src/memory/engines/zaki_dual.zig`
- `src/tools/memory_edit.zig`

### Phase 1: State Layer Formalization

Goal:
- separate current mutable truth from episodic timeline memory

Add:
- `state/*`
- `intention/*`
- `open_loop/*`
- `pattern/*`
- `autonomy/*`

Keep:
- `session_summary/*` and `timeline_summary/*` append-only
- transcripts/checkpoints as evidence

Why this phase comes first:
- the research consistently shows that “current state” must not be mixed with “history”
- it creates the base for proactive behavior later

Likely files:
- `src/memory/root.zig`
- `src/agent/memory_loader.zig`
- `src/agent/commands.zig`
- `src/tools/memory_store.zig`
- `src/tools/memory_edit.zig`

Execution hints:
- start with key-prefix policy only
- do not add a new vtable
- keep the existing `Memory` interface
- extend lifecycle classification rules for the new mutable key families

### Phase 2: Milestone / Pre-Compaction Memory Flush

Goal:
- preserve continuity during long uninterrupted sessions

Behavior:
- if a session becomes too large or too old without a real boundary
- write a milestone summary
- do not end the session
- do not summarize every turn

Why this phase matters:
- this is the biggest current gap in lifetime continuity
- OpenClaw validates the practical need
- the research says episodic memory needs intermediate units, not only final session summaries

Likely files:
- `src/agent/root.zig`
- `src/agent/commands.zig`
- `src/memory/lifecycle/summarizer.zig`
- `src/session.zig`

Execution hints:
- trigger on either:
  - meaningful turn count
  - transcript bytes
  - summarizer window overflow
- write new memory objects, do not rewrite existing session summaries
- keep the first version session-scoped and simple

### Phase 3: Topic / Project Indices

Goal:
- improve discoverability without loading more raw history

Add optional indices:
- `project_index/current`
- `people_index/current`
- `open_loops/current`
- later maybe `pattern_index/current`

Why:
- PageIndex-style discovery is useful
- current `timeline_index/current` is only a hot TOC

Likely files:
- `src/agent/commands.zig`
- `src/tools/memory_recall.zig`
- `src/tools/memory_list.zig`
- `src/agent/memory_loader.zig`

Execution hints:
- keep indices flat and rolling
- do not build a tree or graph layer yet
- store descriptors, not full memory copies

### Phase 4: Proactive State And Pattern Use

Goal:
- make the agent proactively helpful based on explicit memory structures

Use:
- `intention/*`
- `pattern/*`
- `open_loop/*`
- `autonomy/*`

Why:
- proactive behavior should be driven by evidence-backed state
- not inferred from raw transcript residue

Likely files:
- `src/agent/memory_loader.zig`
- `src/agent/prompt.zig`
- `src/daemon.zig`
- `src/user_settings.zig`

Execution hints:
- require policy checks before proactive actions
- distinguish:
  - suggest
  - ask first
  - never act automatically
- keep pattern promotion conservative and evidence-based

### Phase 5: Learning And Reflection Layer

Goal:
- make self-improvement visible and controlled

Add:
- `learning/*`
- maybe later a short curated `LEARNING.md`

Why:
- learnings should improve future behavior
- but should not silently rewrite identity or user truth

Likely files:
- `src/agent/commands.zig`
- `src/memory/root.zig`
- `src/agent/prompt.zig`

Execution hints:
- keep it small
- prefer weekly or session-end reflection over per-turn self-commentary
- do not inject long reflection logs every turn

## 13. Mode Design Guidance

The product modes should differ by:
- responsiveness
- working-memory depth
- summary richness
- queue patience

They should not differ by whether core memory exists.

### Status Quo

Current defaults:

`fast`
- history: `40`
- queue: `latest`
- cap: `8`
- drop: `newest`
- summary window: `3000`
- summary max: `300`

`balanced`
- history: `50`
- queue: `serial`
- cap: `12`
- drop: `summarize`
- summary window: `4000`
- summary max: `500`

`deep`
- history: `80`
- queue: `serial`
- cap: `20`
- drop: `summarize`
- summary window: `6000`
- summary max: `700`

### Recommended Future Tuning

`fast`
- optimize for latency and cost
- keep continuity compact

Recommended target:
- history: `35`
- queue: `latest`
- cap: `8`
- drop: `newest`
- summary window: `2500`
- summary max: `240`

`balanced`
- optimize for default product experience

Recommended target:
- history: `50`
- queue: `serial`
- cap: `10`
- drop: `summarize`
- summary window: `4500`
- summary max: `450`

`deep`
- optimize for high-continuity work and life sessions

Recommended target:
- history: `70`
- queue: `serial`
- cap: `16`
- drop: `summarize`
- summary window: `6500`
- summary max: `750`

Files:
- `src/config_types.zig`
- `src/user_settings.zig`

Execution hints:
- update both `ProductPresetsConfig` and `mode_mappings`
- test the applied-config path, not only helper mappings
- avoid hidden mode-only behavior outside queue/history/summarizer/session knobs

## 14. Practical Execution Notes

### What To Build Now

If the goal is strongest progress with low regression risk, build in this order:

1. state layer
2. milestone/pre-compaction summaries
3. topic/project indices
4. proactive use of patterns/intentions/autonomy
5. learning/reflection layer

### What Not To Build Yet

Delay these until the earlier layers are solid:
- full knowledge graph memory
- heavy hierarchical indexing
- transcript-first long-context strategies
- unconstrained auto-learning of user traits

### How To Judge Success

A good memory change should make the agent:
- more stable across sessions
- more accurate about what is current
- less noisy
- better at cross-channel continuity
- better at preserving long-running work

A bad memory change usually:
- increases transcript volume in prompt
- blurs state and history
- makes forgetting/editing dangerous
- makes proactive behavior feel creepy or arbitrary

### Current Code Hotspots

When designing or implementing any memory evolution, start here:

`src/agent/memory_loader.zig`
- what the model actually sees per turn

`src/agent/commands.zig`
- where summaries, anchors, indices, and promoted facts are written

`src/memory/lifecycle/summarizer.zig`
- summary shape, parsing, and fact extraction

`src/memory/root.zig`
- memory lifecycle policy and internal filtering

`src/user_settings.zig`
- user-facing product mode behavior

`src/config_types.zig`
- real preset defaults that runtime application uses
