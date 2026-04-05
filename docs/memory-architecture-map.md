# Memory Architecture Map

Last updated: 2026-04-05
Branch context: `feat/context-introspection-v1`

This document describes the memory and continuity system as it exists in the
live code today after the M2 stabilization pass, the locked hot/warm/cold
model, and the remaining sharpening items.

The goal is practical clarity:
- what the model actually receives per turn
- how continuity is persisted today
- where transcripts fit
- what is already strong
- what is intentionally deferred for the next branch

## 1. Core Mental Model

Each provider call is a fresh request. The model does not retain prior turns
for us between requests. `nullalis` rebuilds a turn packet every time.

The target runtime model is:
- `fixed`
  - system prompt
  - runtime / workspace rules
  - tool contract
- `hot`
  - last `N` raw messages from the active session
- `warm`
  - `summary_latest/{session_id}`
  - `context_anchor_current`
  - `durable_fact/*`
  - semantic retrieval / memory enrich
  - recent summaries
- `cold`
  - tools
  - index / discovery surfaces
  - transcripts
- `reserve`
  - reply headroom
  - tool / reasoning headroom
  - safety margin

Locked object roles:
- `hot` = raw history only
- `warm` = `summary_latest`, `context_anchor_current`, `durable_fact/*`, semantic recall, recent summaries, memory enrich
- `cold` = tools, index/discovery, transcripts

The important distinction is:
- `hot` keeps the model grounded in the exact active conversation
- `warm` keeps continuity and semantic recall relevant
- `cold` is what the agent reaches for when it needs a deeper dive

## 2. As Is Today

The current system already has the right memory building blocks. The main
stabilization work is now done; what remains is selective sharpening.

### 2.1 Active turn packet

The model currently receives a turn packet built from:

1. system / stable prefix
2. recent raw history in `self.history`
3. memory-enriched provider-facing user turn for the active request only
4. optional compaction summary already present in history

Files:
- `src/agent/root.zig`
- `src/agent/memory_loader.zig`
- `src/agent/compaction.zig`

### 2.2 Continuity objects

The main continuity objects already exist:
- `session_summary/{session_id}/{timestamp}`
- `timeline_summary/{session_id}/{timestamp}`
- `summary_latest/{session_id}`
- `context_anchor_current`
- `timeline_index/current`
- `durable_fact/{timestamp}/{idx}`

Files:
- `src/agent/commands.zig`
- `src/memory/lifecycle/summarizer.zig`

Structured summary shape:

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

This is already a strong continuity schema. We should keep it.

### 2.3 Transcript and archive layer

The system also stores exact-history artifacts:
- `autosave_user_*`
- `autosave_assistant_*`
- `session_checkpoint_*`

Current behavior:
- user autosaves persist the full user message
- assistant autosaves persist the full final visible reply
- retention now defaults to forever with `conversation_retention_days = 0`

Files:
- `src/agent/root.zig`
- `src/agent/commands.zig`
- `src/config_types.zig`
- `src/memory/lifecycle/hygiene.zig`

This gives us strong auditability. Transcripts are now best understood as cold
deep-dive memory: preserved, vector-synced, and hidden from default warm recall.

## 3. Hot / Warm / Cold As Is

### Hot

Locked role:
- raw history only

As-is implementation:
- system / stable prompt still exists outside the hot/warm/cold split as fixed context
- last `N` raw messages in active history are the real hot lane today

Important nuance:
- `summary_latest/{session_id}` and `context_anchor_current` are currently injected ahead of generic recall, but they are now classified as warm continuity objects, not hot history

Files:
- `src/agent/root.zig`
- `src/agent/memory_loader.zig`

### Warm

Locked role:
- `summary_latest/{session_id}`
- `context_anchor_current`
- `durable_fact/*`
- semantic recall / memory enrich
- recent summaries

Warm memory currently comes from the memory loader in this order:

1. `summary_latest/{current_session_id}`
2. `context_anchor_current`
3. relevant `durable_fact/*`
4. up to `2` relevant `timeline_summary/*` from other sessions
5. generic scoped retrieval results
6. global fallback retrieval results

Important limits:
- warm recall limit is `10`
- timeline fallback limit is `2`
- memory context byte budget is `4000`

Mode target for recent summaries:
- `fast`: up to `2`
- `balanced`: up to `4`
- `deep`: up to `6`

These recent summaries belong to warm continuity, not hot raw history.

Files:
- `src/agent/memory_loader.zig`
- `src/memory/root.zig`
- `src/memory/retrieval/engine.zig`

### Cold

Locked role:
- tools
- index / discovery
- transcripts

Cold memory is the deep-dive layer.

Cold assets today:
- autosaved transcripts
- session checkpoints
- older summaries
- `timeline_index/current`
- durable records discoverable through tools

Current tool surfaces:
- `memory_recall`
- `memory_timeline`
- `memory_list`

Important nuance:
- cold transcripts are stored and kept forever
- they are vector-synced
- by default they are still filtered as internal records in normal recall/list flows
- `memory_list(include_internal=true)` can inspect them today

So the architecture direction is:
- transcripts belong in cold memory
- transcripts should be agent-recallable for deep dives
- cold should include enough index/discovery information that the agent knows what to call
- current default tool filtering still needs cleanup for that contract to be fully true

Files:
- `src/tools/memory_recall.zig`
- `src/tools/memory_list.zig`
- `src/memory/root.zig`

## 4. Continuity Lifecycle

### What already triggers continuity writes

Explicit boundaries:
- `/new`
- `/reset`
- `/restart`

Implicit boundaries:
- `ttl_recycle`
- `ttl_evict`
- `idle_evict`

Files:
- `src/agent/commands.zig`
- `src/session.zig`

### What compaction now does

There are three distinct behaviors:

1. `trim`
- cheap history-count guardrail
- removes oldest raw messages
- does not create semantic continuity

2. `auto-compaction`
- summary-producing compaction for token pressure
- can create a `[Compaction summary]` in live history

3. `force compression`
- emergency recovery after context exhaustion

The intended architecture is:
- trim keeps the hot session bounded
- compaction creates same-session continuity
- durable continuity is refreshed from summary-producing compaction and
  lifecycle boundaries

That direction is now implemented in the core runtime paths.

## 5. What Is Strong Already

The current system is already strong in these ways:

- summary schema is good
- runtime memory truth is cleaner and primary-backed during runtime
- `hot` is truly raw-only
- continuity refresh timing is correct
- continuity summaries reflect actual post-compaction history
- diagnostics are materially more truthful

## 6. Confirmed Runtime Truth

The current truth split is:

1. fixed prompt truth
   - still file-based by design in `src/agent/prompt.zig`
2. runtime memory truth
   - primary store is canonical during runtime
   - markdown is startup import plus write mirror
3. continuity truth
   - `summary_latest/*`, `timeline_summary/*`, `session_summary/*`, `context_anchor_current`, `durable_fact/*`
4. audit truth
   - `autosave_*`, `session_checkpoint_*`
5. discovery truth
   - `timeline_index/current`

This mixed contract is acceptable for the stabilization pass:
- file-first fixed prompt
- primary-first runtime memory and continuity

## 7. Remaining Follow-Up Items

These are the main sharpening items left after stabilization:

1. mode-based recent-summary injection by depth
2. transcript-specific deep-dive tool surface if testing shows need
3. fixed prompt truth unification so bootstrap-backed prompt content becomes more canonical over time

## 8. Practical Bottom Line

The memory system should now be understood as:

1. `fixed`
   - file-based prompt identity and workspace context
2. `hot`
   - raw active-session history only
3. `warm`
   - continuity objects and semantic recall
4. `cold`
   - discovery tools, indexes, and transcript deep dives
5. `reserve`
   - reply and tool headroom

The next branch should improve fixed prompt truth, not reopen the stabilized
hot/warm/cold runtime pipeline unless testing reveals a concrete regression.
- provenance metadata is good
- memory tools already exist
- session summaries, timeline summaries, latest pointers, anchors, and facts all
  already exist
- transcripts are now retained indefinitely by default
- the hot/warm/cold mental model fits the codebase well

The main work remaining is not "invent memory". It is:
- make the continuity pipeline ordered
- make artifact roles explicit
- make recall surfaces truthful
- make introspection match runtime reality

## 6. Findings And Open Wiring

### P0

1. Compaction-triggered continuity refresh happens too early
- current auto-compaction refresh happens before the final assistant reply is
  appended
- effect:
  - `summary_latest`
  - `context_anchor_current`
  can be stale by one reply on compaction turns
- needed:
  - continuity refresh must run post-reply from the real final turn state

2. Durable summary generation can miss the real compaction state
- long-session summary generation can summarize checkpoint text plus the recent
  tail instead of the real post-compaction history
- effect:
  - durable continuity may miss the actual `[Compaction summary]`
  - older context preserved by compaction can be lost again in semantic form
- needed:
  - durable continuity must summarize actual current history after compaction
    and after the final reply exists

### P1

1. Continuity keys are collision-prone
- append-only continuity keys still use second-granularity timestamps
- effect:
  - same-second writes can overwrite
  - auditability and ordering are weaker than they should be
- needed:
  - one collision-safe numeric continuity cycle id per persistence pass

2. Audit artifacts and continuity artifacts are not cleanly separated
- checkpoints, transcript autosaves, and some system index artifacts are still
  treated too much like searchable memory objects
- effect:
  - retrieval can get noisier
  - the system feels more fragmented than it is
- needed:
  - continuity artifacts, audit artifacts, and index artifacts need clearer
    roles and filtering rules

3. Warm top-k is not truthful yet
- the loader asks for more than the hybrid runtime actually returns
- effect:
  - docs and diagnostics can overstate recall depth
- needed:
  - explicit per-call retrieval limits must win over lower engine defaults

4. Cold transcript recall is conceptually right but not fully wired
- transcripts are now worth keeping as cold deep-dive memory
- effect:
  - architecture says "cold deep dive"
  - current default tool filtering still treats them mostly as internal records
- needed:
  - make transcript recall a deliberate cold-memory behavior without polluting
    hot/warm injection

5. Introspection is ahead of reality in a few places
- some reports still blur:
  - intended recall depth vs actual recall depth
  - stored vs recallable
  - live runtime bytes vs trimmed bytes
- needed:
  - introspection should report actual runtime behavior only

## 7. Working Principle Going Forward

Keep this mental model:

- transcript is for grounding and deep audit
- summaries are for episodic continuity
- durable facts are for long-term semantic identity
- checkpoints are for recovery and audit
- hot / warm / cold should be explicit, truthful, and minimally overlapping

That means:
- keep last `N` raw messages
- keep `summary_latest` and `context_anchor_current` hot
- keep semantic recall warm
- keep transcripts cold but recallable for deliberate deep dives
- do not collapse all memory back into one undifferentiated bucket

## 8. What To Build Next

The next work should not add a new memory architecture. It should close the
remaining continuity pipeline gaps.

Priority order:

1. make continuity writes post-reply and ordered
2. summarize from actual post-compaction history
3. separate continuity artifacts from audit/index artifacts
4. make warm retrieval limits truthful
5. make cold transcript recall explicit and intentional
6. keep `/context detail` and `/memory doctor` aligned with real behavior

That is the shortest path to a smoother, less error-prone, SOTA memory system
using the architecture we already have.

## 9. M2 Execution Sequence

This is the concrete completion sequence for `feat/context-introspection-v1`.

### Step 1. Lock The Turn Packet

Use one canonical runtime model:
- `fixed`
- `hot`
- `warm`
- `cold`
- `reserve`

Definition:
- `hot` = last `N` raw messages
- `warm` = `summary_latest`, `context_anchor_current`, `durable_fact/*`,
  semantic enrich, and up to `2-3` recent summaries when not redundant
- `cold` = on-demand recall plus discovery surfaces
- `reserve` = reply/tool/safety headroom

This should become the source of truth for diagnostics, docs, and runtime.

### Step 2. Make Continuity Post-Reply

Summary-producing compaction should trigger durable continuity refresh only
after the final assistant reply exists.

Required outcome:
- continuity is not stale by one turn
- compaction is treated as normal context management
- cheap trim stays cheap and non-semantic

### Step 3. Summarize The Real State

Durable continuity must summarize the actual post-compaction history, not only
checkpoint text plus a recent tail.

Required outcome:
- `[Compaction summary]` remains part of semantic continuity when it is the
  continuity carrier
- long sessions survive semantically, not only through transcript replay

### Step 4. Separate Artifact Classes

Keep three explicit classes:

1. continuity artifacts
- `summary_latest/*`
- `session_summary/*`
- `timeline_summary/*`
- `context_anchor_current`
- `durable_fact/*`

2. audit artifacts
- `autosave_user_*`
- `autosave_assistant_*`
- `session_checkpoint_*`

3. index artifacts
- `timeline_index/current`
- any later session / continuity TOCs

Required outcome:
- continuity artifacts are searchable/injectable
- audit artifacts are cold deep-dive records
- index artifacts are discovery, not normal semantic memory payload

### Step 5. Make Warm Truthful

Warm recall must match what the runtime actually returns.

Required outcome:
- explicit top-k works on the hybrid path
- warm injection order is stable
- docs and diagnostics stop overstating recall depth

### Step 6. Make Cold Discoverable

Cold memory should be on-demand, but the agent should know what exists.

Cold discoverability includes:
- `memory_recall`
- `memory_timeline`
- `memory_list`
- session/timeline index information
- transcript availability

Required outcome:
- the agent knows what deep-dive surfaces exist
- cold is not blindly injected into every turn

### Step 7. Add Milestone Summaries

Summaries should not happen only under pressure.

Use two triggers:
- pressure-driven compaction summary
- continuity-driven milestone summary

Examples:
- important decision made
- tool-heavy phase completed
- topic shift
- continuity interval crossed

Required outcome:
- long uninterrupted sessions accumulate continuity without waiting for context
  stress

### Step 8. Finish Introspection

`/context detail` and `/memory doctor` should show:
- hot contents
- warm contents
- cold discovery surfaces
- actual recall limit
- last continuity write reason
- last compaction reason
- last milestone summary reason

Required outcome:
- diagnostics match runtime truth

### Step 9. Close With Two Audits

After the pipeline is stable, split final review into:

1. retrieval audit
- what is recalled
- in what order
- with what scope and redundancy rules

2. ingestion audit
- what is written
- when continuity objects update
- when timeline/index objects update
- when transcripts/checkpoints are written

Required outcome:
- ingestion and retrieval can be explained end-to-end with no hidden wiring

## 10. What Must Be True Before Calling It Done

The model does not need every memory injected every turn.
It needs:
- enough hot context to stay grounded
- enough warm context to stay continuous and relevant
- enough cold discoverability to know what to call when it needs depth

M2 is done when:
- the turn packet is stable and explicit
- warm recall is truthful
- compaction is normal context management
- milestone summaries exist
- cold deep-dive surfaces are discoverable
- continuity writes are correct and timely
- diagnostics match runtime reality

If those are true, the agent will have the context needed to:
- resolve normal tasks directly from hot + warm context
- recall relevant memory without overstuffing the prompt
- deep-dive into transcript/history only when the task actually requires it

## 11. Validation Checklist

Use this checklist when executing and finalizing M2.

### Runtime packet validation

- `/context detail` shows:
  - `hot` as raw recent history only
  - `warm` objects explicitly:
    - `summary_latest`
    - `context_anchor_current`
    - `durable_fact/*`
    - semantic recall
    - recent summaries
  - `cold` discovery surfaces explicitly:
    - tools
    - timeline/session index
    - transcript deep-dive availability

### Continuity validation

- a normal turn without compaction keeps hot history bounded
- a summary-producing compaction turn refreshes durable continuity after the final reply
- lifecycle boundary still writes continuity correctly
- `summary_latest` points to the expected recent `timeline_summary/*`
- `context_anchor_current` references the expected latest summary/checkpoint keys

### Warm recall validation

- hybrid retrieval honors the requested warm top-k
- `durable_fact/*` appears in warm memory when relevant
- recent summaries appear according to mode and are not duplicated blindly
- timeline fallback remains bounded

### Cold validation

- the agent can discover cold surfaces from docs/prompt/tooling
- `memory_timeline` can find recent summaries through `timeline_index/current`
- transcript records are available for deliberate deep dives
- transcripts are not injected by default into hot/warm

### Milestone validation

- milestone summary path exists separately from pressure compaction
- a long uninterrupted session can accumulate continuity without waiting for overflow

### Final branch gate

- `zig build test --summary all`
- `zig build -Doptimize=ReleaseSmall`
- one real-session spot-check for each:
  - short task
  - long task
  - recall-heavy task
  - deep-dive transcript task
