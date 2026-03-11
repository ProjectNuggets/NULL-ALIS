# Runtime Baseline Ledger (v0.1.1)

Date: 2026-03-11  
Scope: runtime behavior inventory before new feature expansion.

## Purpose
Establish a defensible baseline of what is:
1. Active and affecting runtime behavior now.
2. Initialized but inert (state/config accepted, no runtime effect).
3. Metadata-only (diagnostic/lifecycle fields, not execution controls).

This ledger is the control document for "use what exists first" decisions.

## Baseline Verification Snapshot
- Baseline SHA (pre-activation patch): `0f413b4e1d7c8c7fcb50e464438d8b60758f7203`
- Baseline operator checks (user `1`, 2026-03-11):
  - `nullalis status --user-id 1`
  - `nullalis doctor --user-id 1`
  - `GET /internal/diagnostics` with `X-Zaki-User-Id: 1`
- Semantic cache wiring is active in agent turn path:
  - read/hit path: `src/agent/root.zig:755`
  - write path: `src/agent/root.zig:1179`
  - regression test: `src/agent/root.zig:3131`
- Memory runtime resolves as hybrid/vector when configured:
  - `backend=markdown retrieval=hybrid vector=pgvector rollout=on cache=true semantic_cache=true`
- Tenant gateway runtime still promotes primary memory to `zaki_dual` in tenant+postgres mode:
  - `src/gateway.zig:663`

## A. Active Runtime Paths (Do Not Regress)

### A1. Memory + retrieval + vector
- `MemoryRuntime.search(...)` uses rollout policy for keyword/hybrid/shadow:
  - `src/memory/root.zig:449`
- Vector reindex/sync paths are active:
  - `src/memory/root.zig:542`
  - `src/memory/root.zig:603`
- Semantic cache object is created in runtime init when enabled:
  - `src/memory/root.zig:1121`

### A2. Agent turn execution
- LLM/tool loop + stage emission + timeout propagation are active:
  - `src/agent/root.zig:642`
  - `src/agent/root.zig:840`
- Message timeout is used in provider requests:
  - `src/agent/root.zig:273`
  - `src/agent/root.zig:840`

### A3. Session and tenant wiring
- Session manager injects `mem_rt` and caches into per-session agent:
  - `src/session.zig:136`
  - `src/session.zig:137`
- Tenant runtime composes provider + memory + tools + session manager:
  - `src/gateway.zig:657`
  - `src/gateway.zig:723`

## B. Initialized-but-Inert (Confirmed)

Classification rule in v0.1.1:
1. `active`: runtime-enforced behavior.
2. `deferred-explicit`: accepted in config/commands but explicitly surfaced as not runtime-active.
3. `experimental-gated`: runtime-active only behind clear explicit gates.

### B1. `system_prompt_has_conversation_context` (write-only state)
- Declared and set/reset:
  - `src/agent/root.zig:297`
  - `src/agent/root.zig:712`
  - `src/agent/root.zig:1590`
- No behavioral read gate in turn logic.
- Recommendation: keep for now, or remove if no near-term consumer.

### B2. Queue mode controls are command-visible but runtime-inert
- Fields:
  - `queue_mode`, `queue_debounce_ms`, `queue_cap`, `queue_drop`
  - `src/agent/root.zig:252`
- Slash commands mutate and display them:
  - `src/agent/commands.zig:636`
  - `src/agent/commands.zig:954`
- No execution-path enforcement in `Agent.turn(...)`.
- Classification: `deferred-explicit`.
- Runtime note: startup/runtime surfaces must warn when these are set.

### B3. TTS controls are command-visible but runtime-inert
- Fields:
  - `tts_mode`, `tts_provider`, `tts_limit_chars`, `tts_summary`, `tts_audio`
  - `src/agent/root.zig:256`
- Slash commands mutate and display them:
  - `src/agent/commands.zig:640`
  - `src/agent/commands.zig:1028`
- No TTS synthesis/output path in core turn execution.
- Classification: `deferred-explicit`.

### B4. Activation/send/session TTL are command-visible but runtime-inert
- Fields:
  - `activation_mode`, `send_mode`, `session_ttl_secs`
  - `src/agent/root.zig:270`
  - `src/agent/root.zig:271`
  - `src/agent/root.zig:265`
- Command wiring exists:
  - `src/agent/commands.zig:1229`
  - `src/agent/commands.zig:1239`
  - `src/agent/commands.zig:1186`
- No enforcement in main turn/session execution path.
- Classification: `deferred-explicit` until wiring is complete.

## C. Metadata-Only (Not Bugs)

### C1. Runtime-owned path pointers
- `_db_path`, `_cache_db_path`, `_semantic_cache_db_path` are lifecycle/cleanup metadata:
  - `src/memory/root.zig:426`
  - `src/memory/root.zig:427`
  - `src/memory/root.zig:440`
- Used in deinit cleanup:
  - `src/memory/root.zig:688`
  - `src/memory/root.zig:693`
  - `src/memory/root.zig:695`

### C2. Summarizer config snapshot
- `_summarizer_cfg` is initialized and exposed for diagnostics:
  - `src/memory/root.zig:436`
  - `src/memory/root.zig:643`
  - `src/memory/lifecycle/diagnostics.zig:96`
- No active summarization pipeline hook in current turn path.
- Treat as staged capability metadata, not an active bug.

## D. Known Non-Blocking Reporting Choice
- Embedding adapter name remains `"openai"` for OpenAI-compatible providers (including Together API usage through compatible endpoint):
  - `src/memory/vector/embeddings.zig:270`
- Decision: accepted for now (labeling choice, not execution failure).

## E. Operator Baseline Checks (Run Before Any New Work)
1. `zig build test --summary all`
2. `zig build -Dengines=base,sqlite,postgres`
3. `./zig-out/bin/nullalis memory stats`
4. `./zig-out/bin/nullalis status --user-id <id>`
5. `sqlite3 ~/.nullalis/workspace/semantic_cache.db "select count(*), sum(hit_count) from semantic_cache;"`

## F. Patch Priority Using Existing Code First
1. Decide on inert controls (`queue`, `tts`, `activation/send`, `session ttl`): wire or mark runtime-noop in UX.
2. Keep semantic cache path as the first latency/cost optimization baseline.
3. Preserve tenant memory authority (`zaki_dual` with postgres canonical path) while improving observability labels.
4. Avoid adding new surfaces until inert control decisions are explicit.

## G. Baseline UX Hygiene Applied (2026-03-11)
- Memory context injection now suppresses markdown line-key artifacts (`MEMORY:<line>`) so prompts no longer leak scaffold IDs.
- Guard is in runtime and non-runtime context loaders:
  - `src/agent/memory_loader.zig`
  - helper: `src/memory/root.zig:isMarkdownLineKey`
