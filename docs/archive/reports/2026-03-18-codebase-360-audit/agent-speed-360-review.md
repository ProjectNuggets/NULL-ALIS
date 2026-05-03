---
tags: [prose, prose/docs]
---

# nullalis Agent Speed 360 Review

Date: 2026-03-18

Scope:
- Fresh code-only rescan of agent turn speed from request entry to reply emission.
- Focused on time spent between "agent prompted" and "agent replied".
- Same-session lock wait is intentionally not the focus in this pass.

Validation:
- No builds or tests run for this pass.
- Evidence comes from source inspection in this checkout.

## Executive Verdict

- Confirmed fact: clean-turn wall time is still dominated by provider round-trip time, but the runtime adds several avoidable latency multipliers before the user sees output.
- Confirmed fact: the biggest UX speed gap is not raw model latency. It is that the gateway SSE path does not deliver real first-token streaming even though provider-side streaming exists.
- Confirmed fact: the next biggest code-side costs are repeated prompt rebuild I/O, repeated provider-message reconstruction, stacked retry layers, and inline post-reply memory/cache work.
- High-confidence inference: the current system is capable, but not yet SOTA in perceived responsiveness. It behaves more like "batch-complete then emit progress" than "optimize first useful token, then continuously stream".

## Fast Path Map

The request path is:

1. `SessionManager.processMessageWithContext(...)` starts timing and calls `session.agent.turn(...)`. (`src/session.zig:375-382`, `src/session.zig:480-482`)
2. `Agent.turn(...)` may rebuild the system prompt, auto-save, enrich memory, trim history, check caches, build provider messages, call the provider, parse tool calls, run tools, compose the reply, auto-save again, drain the outbox, and write caches. (`src/agent/root.zig:1072-1140`, `src/agent/root.zig:1142-1236`, `src/agent/root.zig:1252-1707`)
3. Session persistence happens after the agent returns. (`src/session.zig:491-508`)

High-confidence inference:
- In a no-tool, no-retry turn, the critical path is provider call plus prompt/message preparation plus finalization work.
- In a tool or retry turn, the system can pay for multiple provider passes before any final answer is emitted.

## Findings

### 1. Gateway "streaming" is post-hoc, not true token streaming

- Confirmed fact: `/api/v1/chat/stream` sends a status frame and progress events, but it waits for `tenant_runtime.processMessage(...)` or `sm.processMessageWithContext(...)` to finish and only then slices the completed reply into fixed chunks. (`src/gateway.zig:5368-5375`, `src/gateway.zig:5377-5424`, `src/gateway.zig:5426-5438`)
- Confirmed fact: the progress observer only emits phase updates like "Retrieving memory", "Preparing model request", and "Model response received". It does not emit model token deltas. (`src/gateway.zig:4977-5003`, `src/gateway.zig:5005-5031`)
- Confirmed fact: the agent only streams when `self.stream_callback != null and self.provider.supportsStreaming()`. (`src/agent/root.zig:1273-1279`)
- Confirmed fact: CLI wires `agent.stream_callback`, but the gateway path does not. (`src/agent/cli.zig:176-181`, `src/agent/cli.zig:260-264`, `src/session.zig:456-467`, `src/gateway.zig:5374-5412`)
- Confirmed fact: provider-side streaming exists. OpenAI exposes `stream_chat`, and the SSE helper emits deltas incrementally through `callback(...)`. (`src/providers/openai.zig:171-180`, `src/providers/openai.zig:182-205`, `src/providers/sse.zig:67-78`, `src/providers/sse.zig:270-333`)

Effect:
- Web users do not get true time-to-first-token improvements, only status updates followed by delayed fake token chunks.

Why this matters:
- This is the single biggest "feels slow" issue in the codebase, because the UI cannot surface model progress as soon as the provider has it.

### 2. The reliability wrapper silently disables streaming, and it is enabled by default

- Confirmed fact: `ReliableProvider`'s vtable implements `chat`, `chatWithSystem`, tool support, vision support, `deinit`, and `warmup`, but it does not implement `supports_streaming` or `stream_chat`. (`src/providers/reliable.zig:302-311`)
- Confirmed fact: the wrapper performs retry loops with backoff around blocking `prov.chat(...)` calls. (`src/providers/reliable.zig:356-387`)
- Confirmed fact: `RuntimeProviderBundle` enables the reliability wrapper whenever `provider_retries > 0`, model fallbacks exist, or extra providers/API keys are present. (`src/providers/runtime_bundle.zig:62-68`)
- Confirmed fact: the default config sets `provider_retries = 2`. (`src/config_types.zig:122-124`)

High-confidence inference:
- In the default runtime configuration, many turns are likely routed through `ReliableProvider`, which means `supportsStreaming()` becomes false even if the underlying provider can stream.

Effect:
- Real streaming is not just missing from the gateway path. The default provider bundle likely suppresses streaming at the provider abstraction layer first.

Why this matters:
- This turns a feature the providers already support into a default latency regression.

### 3. System prompt caching is invalidated every minute, forcing repeated file and config work

- Confirmed fact: every turn computes `workspacePromptFingerprint(...)`, and the agent also invalidates the system prompt when the minute bucket changes. (`src/agent/root.zig:1072-1080`)
- Confirmed fact: when invalidated, the turn path calls `Config.load(...)`, rebuilds the capabilities section, rebuilds the full system prompt, rebuilds tool instructions, and rewrites `history[0]`. (`src/agent/root.zig:1087-1140`)
- Confirmed fact: `Config.load(...)` allocates an arena, resolves config paths, opens the config file, reads it, parses JSON, and applies env overrides. (`src/config.zig:212-251`)
- Confirmed fact: `buildPromptSection(...)` recomputes enabled/disabled channels, memory engines, runtime tools, and optional tools every time. (`src/capabilities.zig:396-463`)
- Confirmed fact: the prompt builder stats nine tracked workspace files, injects up to eight identity files plus memory file content, enumerates skills, and reads `USER.md` again for timezone hints. (`src/agent/prompt.zig:38-87`, `src/agent/prompt.zig:167-190`, `src/agent/prompt.zig:214-297`, `src/agent/prompt.zig:300-398`, `src/agent/prompt.zig:401-436`)

High-confidence inference:
- Even when nothing relevant changed, minute rollover guarantees another expensive prompt rebuild on the next turn.

Effect:
- Users pay periodic disk and string-building overhead on otherwise ordinary turns.

Why this matters:
- This is exactly the kind of repeated CPU + filesystem work that makes local turns feel less crisp than frontier agents.

### 4. Provider request assembly is rebuilt from scratch on every iteration

- Confirmed fact: each tool-loop iteration allocates a new `ChatMessage` array, copies the entire history, rebuilds multimodal allowed dirs, canonicalizes dirs with `realpathAlloc`, and then calls multimodal preprocessing. (`src/agent/root.zig:1252-1271`, `src/agent/root.zig:1974-1996`, `src/agent/root.zig:1999-2015`)
- Confirmed fact: multimodal preprocessing always scans the latest user message for markers and, when markers exist, may parse refs, read files, and base64-encode image payloads. (`src/multimodal.zig:340-447`)

High-confidence inference:
- The repeated copy-and-normalize work is modest on tiny histories, but it compounds with larger histories, multi-pass tool turns, and retries.

Effect:
- A tool turn pays message-build overhead more than once, and the code has no stable "provider-ready transcript" cache between iterations.

### 5. Retry logic is layered, so rare failures can add seconds quickly

- Confirmed fact: `Agent.turn(...)` adds its own retry behavior around blocking provider calls, including a hardcoded `500ms` sleep and possible context-compression retries. (`src/agent/root.zig:1331-1408`)
- Confirmed fact: `ReliableProvider` separately retries provider calls with exponential backoff. (`src/providers/reliable.zig:330-350`, `src/providers/reliable.zig:364-384`)

High-confidence inference:
- When reliability wrapping is active, the system can stack provider-wrapper retries and agent-level retries in the same user turn.

Effect:
- A turn that was supposed to degrade quickly can turn into multi-second hidden waiting before the user gets a result or error.

### 6. Turn finalization still contains synchronous side work

- Confirmed fact: before returning the final text, the agent may prepare TTS payloads, trim history, auto-save the assistant reply, enqueue or run vector sync, drain the outbox, and write semantic/response caches. (`src/agent/root.zig:1557-1707`)
- Confirmed fact: if durable outbox is absent, vector sync can embed content inline and upsert it synchronously. (`src/memory/root.zig:551-584`)
- Confirmed fact: if durable outbox is present, `drainOutbox(...)` still runs at turn end and may fetch up to 50 items, look up content, embed, and upsert vectors inline before the turn fully exits. (`src/agent/root.zig:1654-1660`, `src/memory/root.zig:586-593`, `src/memory/vector/outbox.zig:88-199`)
- Confirmed fact: response cache writes hit SQLite in the same return path. (`src/agent/root.zig:1670-1702`, `src/memory/lifecycle/cache.zig:141-177`)

High-confidence inference:
- The reply often is not "done" when the answer text is logically ready. The turn still performs operational cleanup and memory maintenance on the hot path.

Effect:
- Tail latency is inflated by work that could be decoupled from user-visible completion.

### 7. Tool turns are structurally multi-pass, and the code adds extra follow-through passes

- Confirmed fact: when tool calls are present, the agent appends tool results back into history as a new user reflection prompt, then loops again. (`src/agent/root.zig:1761-1804`)
- Confirmed fact: even when there are no valid tool calls, the agent may force another completion if the model "promised" action or emitted malformed tool markup. (`src/agent/root.zig:1520-1549`)

High-confidence inference:
- Some slow turns are not provider slowness in isolation. They are architecture-driven extra completions.

Effect:
- The agent can spend an additional whole provider round-trip for behavioral guardrails before the user gets a final answer.

### 8. Memory enrichment can look cheap in logs even when memory is effectively off

- Confirmed fact: the agent always times `memory_enrich`, but `enrichMessageWithRuntime(...)` prefers `MemoryRuntime.search(...)` when a runtime exists. (`src/agent/root.zig:1159-1172`, `src/agent/memory_loader.zig:181-200`)
- Confirmed fact: `MemoryRuntime.search(...)` returns an empty allocation immediately when `_search_enabled` is false. (`src/memory/root.zig:461-464`)

High-confidence inference:
- Very low `memory_enrich` timings can mean "memory retrieval was skipped" rather than "retrieval is fast".

Effect:
- Speed telemetry can overstate memory efficiency if retrieval is disabled or hollow.

### 9. Observability is not yet sufficient for first-token speed work

- Confirmed fact: the observer schema records `llm_request`, `llm_response`, coarse `turn_stage`, and aggregate metrics like request latency and queue depth. It does not include first-token or token-delta timing events. (`src/observability.zig:4-25`)
- Confirmed fact: the tracing observer records `turn.stage` spans at `now, now`, which preserves the label but not a real nested duration model for critical sub-steps. (`src/observability.zig:527-533`)
- Confirmed fact: session and gateway summaries log aggregate `agent_ms`, `persist_ms`, `chat_ms`, and `total_ms`. (`src/session.zig:506-513`, `src/gateway.zig:5450-5458`)

Effect:
- The code can tell you total latency, but it is not instrumented like a first-token-optimized system.

Why this matters:
- Without TTFT and streamed-token telemetry, the team will keep debating speed with partial evidence.

## Most Time-Consuming Parts Between Prompted And Replied

Ignoring same-session lock wait, the likely cost ranking from code is:

1. Provider generation and network RTT.
2. Extra provider passes caused by tool loops, forced follow-through, and retries.
3. Prompt rebuild work when cache invalidates: config load, workspace file reads, skill enumeration, capabilities rebuild.
4. Provider-message reconstruction on each iteration, including multimodal path preparation.
5. Inline finalization: auto-save, vector sync or outbox drain, cache writes, and optional TTS preparation.

High-confidence inference:
- On a truly clean, no-tool, no-rebuild turn, the provider dominates.
- On real agent turns, the runtime architecture often adds enough surrounding work that the user experiences "slow agent" rather than just "slow model".

## Wrinkles And Gaps

- The system is optimized more for correctness and recoverability than for first useful token.
- Gateway progress UX is present, but it masks the absence of true streaming.
- The default reliability posture likely trades away streaming without making that trade explicit.
- Prompt caching is conceptually present, but minute-based invalidation keeps forcing cold rebuild behavior.
- The hot path still performs maintenance work that frontier agent runtimes usually push behind the reply boundary.
- Observability is detailed enough for stage logs, but not detailed enough for a serious latency program.

## How To Make This SOTA

### P0

- Wire true end-to-end streaming through the gateway path.
- Add `supports_streaming` and `stream_chat` to `ReliableProvider`, preserving retries/fallbacks without downgrading to blocking mode.
- Emit real token deltas to SSE clients instead of chunking the final string after completion.

Expected impact:
- Biggest improvement to perceived speed and first-token latency.

### P1

- Remove minute-bucket prompt invalidation and rely on actual dependency fingerprints.
- Cache the built capabilities section and skill listing unless config or workspace prompt files changed.
- Precompute or memoize canonical multimodal allowed dirs for the session instead of rebuilding them every iteration.

Expected impact:
- Better CPU and filesystem efficiency on repeated turns.

### P2

- Split "reply ready" from "maintenance complete".
- Move autosave vector sync, outbox drain, semantic-cache write, and nonessential post-processing onto a deferred background lane.
- Keep only the minimum history append needed before returning the user-visible reply.

Expected impact:
- Lower tail latency, especially for memory-enabled tenants.

### P3

- Collapse retry policy into one owner.
- Choose either provider-wrapper retries or agent-level retries as the primary mechanism, then expose explicit budgets.
- Prefer fast failover to a bounded fallback over stacked backoff loops.

Expected impact:
- Fewer surprise multi-second turns.

### P4

- Add true latency telemetry: TTFT, first tool start, tool wall time, final token time, post-reply maintenance time.
- Separate "memory disabled" from "memory fast" in logs and metrics.
- Publish percentile breakdowns by turn type: direct, tool, retry, compacted, memory-enriched, streamed.

Expected impact:
- Lets speed work become measurable instead of anecdotal.

## Bottom Line

- Confirmed fact: the current runtime has enough instrumentation and structure to find speed problems, but not enough first-token optimization to feel frontier-grade.
- Confirmed fact: the largest avoidable gap is the missing end-to-end streaming path, followed closely by the streaming regression introduced by the default reliability wrapper.
- High-confidence inference: if those two issues are fixed first, and prompt/finalization work is moved off the hot path next, the agent will feel dramatically faster even before any model change.
