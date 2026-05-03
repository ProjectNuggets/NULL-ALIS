---
tags: [prose, prose/docs]
---

# Agent Behavior, Context Loading, and Turn Latency Audit

Date: 2026-03-18
Scope: source audit plus existing staging evidence already checked into this repo. No runtime mutation.

## Executive Summary

1. The dominant confirmed cost between "agent prompted" and "agent replied" is provider round-trip time.
2. Current context loading is cheaper than expected partly because it is often effectively off: when a `MemoryRuntime` exists but `search.enabled=false`, `memory_enrich` returns no candidates instead of falling back to raw recall.
3. Prompt construction is heavier than the timing reports make visible: the agent can rebuild a very large system prompt by re-reading workspace files and reloading config from disk, but that work is not separately instrumented.
4. The terminal is likely telling the truth with `summarizer=false`. That value is read directly from `MemoryRuntime._summarizer_cfg.enabled`, which is copied from `config.memory.summarizer.enabled`. It is not a UI-only flag.
5. The current repo's deployment manifest and current seed code do not line up with the observed seeded runtime state. Under today's checked-in code, a freshly seeded tenant should not land on `search.enabled=false` and `summarizer=false` at the same time.
6. There is a meaningful distinction between queue "summarize" and memory "summarizer". Queue summarize is overflow coalescing in `SessionManager`; memory summarizer is the lifecycle checkpoint summarizer. They are different subsystems.
7. The repo has the bones of a strong agent runtime, but it is not SOTA yet because it lacks first-token observability, budgeted context packing, and robust memory recall behavior when semantic retrieval is disabled.

## 1. Verified Turn Path

Current turn handling is:

1. `SessionManager.processMessageWithContext(...)` resolves a session, may block on the session mutex, optionally injects a queue summary prefix, then calls `agent.turn(...)`. `src/session.zig:375-515`
2. `Agent.turn(...)` may rebuild the system prompt, auto-save the user message, enrich the message with memory context, check caches, then enter the provider/tool loop. `src/agent/root.zig:1062-1245`
3. For each provider iteration, the agent rebuilds provider messages from full history, calls the LLM, parses tool calls, optionally executes tools, reflects tool output back into history, then loops or finalizes. `src/agent/root.zig:1246-1690`
4. After the final assistant reply, the session layer persists user and assistant messages and logs total timing. `src/session.zig:491-513`

High-confidence implication:
- The user-visible latency budget is not just "LLM time". It is:
  `session_lock_wait + prompt/context work + provider pass(es) + tool loop(s) + finalize + persistence`

## 2. What Is Actually Slow

### Confirmed from checked-in staging evidence

From the existing sweep report:

- Clean short turns were dominated by `llm.response`:
  - median `2294 ms`
  - p95 `6169 ms`
  - median total `3075 ms`
  - about 75% of clean-turn time was provider time
  - source: `docs/reports/2026-03-17-agent-wiring-sweep/sweep-report.md:39-66`

- Same-session overlap is the strongest measured internal blocker:
  - one overlapped turn spent `7160 ms` waiting on the session lock before doing about `2336 ms` of real provider work
  - source: `docs/reports/2026-03-17-agent-wiring-sweep/sweep-report.md:88-97`

- Trivial meta/runtime prompts can become multi-pass turns:
  - a `runtime_info` tool call itself took `2 ms`
  - the second provider pass took `13259 ms`
  - total turn `17290 ms`
  - source: `docs/reports/2026-03-17-agent-wiring-sweep/sweep-report.md:68-86`

### Confirmed from code

- Session serialization is real and explicit. Only one turn runs per session at a time. `src/session.zig:389-405`
- The total request log is emitted only after agent work and persistence finish. `src/session.zig:480-513`
- The agent rebuilds provider messages on every iteration from full history and re-runs multimodal preprocessing each time. `src/agent/root.zig:1256-1271`, `src/agent/root.zig:1974-1996`
- Tool turns always pay at least one more provider pass after tool execution because tool results are appended as a new user reflection message. `src/agent/root.zig:1454-1515`, `src/agent/root.zig:1710-1788`

## 3. What Is Not Slow, and Why That Is Misleading

The old sweep correctly observed that `memory_enrich` was usually `0 ms`, but the current source explains why that can happen without meaning memory is healthy.

When `Agent.turn(...)` has a `MemoryRuntime`, it always uses `enrichMessageWithRuntime(...)`. `src/agent/root.zig:1159-1167`, `src/agent/memory_loader.zig:176-195`

That runtime path calls `rt.search(...)`. `src/agent/memory_loader.zig:121-154`

But `MemoryRuntime.search(...)` returns an empty candidate list immediately when `_search_enabled` is false. `src/memory/root.zig:461-489`

Result:
- if `search.enabled=false`, memory context injection is effectively disabled
- the loader does not fall back to plain `mem.recall(...)` once a `MemoryRuntime` exists
- therefore `memory_enrich=0 ms` can mean "memory recall skipped", not "memory retrieval is efficient"

This is one of the most important behavior wrinkles in the codebase.

## 4. Context Loading Behavior

### System prompt path

The system prompt is heavy:

- it fingerprints 9 workspace prompt files every turn to decide whether to rebuild the prompt cache: `AGENTS.md`, `SOUL.md`, `TOOLS.md`, `IDENTITY.md`, `USER.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`, `MEMORY.md`, `memory.md`. `src/agent/prompt.zig:36-87`
- it injects up to `20_000` chars from each workspace file into the prompt. `src/agent/prompt.zig:15-16`, `src/agent/prompt.zig:401-436`
- it renders every tool name, description, and full parameter JSON into the prompt. `src/agent/prompt.zig:193-203`
- it can also embed always-on skill instructions. `src/agent/prompt.zig:214-298`

### Prompt rebuild wrinkle

The prompt cache is invalidated not only on file changes but also every minute:

- `system_prompt_time_bucket_min` forces a rebuild when the UTC minute changes. `src/agent/root.zig:1072-1080`

It also reloads config from disk during prompt rebuild:

- `Config.load(self.allocator)` is called inside the turn path to build the capabilities section. `src/agent/root.zig:1087-1096`

Wrinkle:
- the capabilities section is rebuilt from disk config, not from the already-resolved tenant runtime config, so the prompt can drift from the actual effective per-user runtime state.

### User message enrichment path

Memory context is prepended directly to the user message:

- `[Memory context] ...` is formatted and then concatenated in front of the raw user text. `src/agent/memory_loader.zig:47-118`, `src/agent/memory_loader.zig:156-174`, `src/agent/memory_loader.zig:176-195`

Wrinkles:
- retrieved memory is merged into the user utterance rather than carried in a separate structured prompt slot
- when retrieval is disabled, that enrichment path quietly becomes empty
- there is no budgeted ranking across system prompt + memory + history + tool reflection; each piece grows mostly independently

## 5. Why The Terminal Shows `summarizer=false`

### What that flag actually means

The terminal/doctor output is reading the runtime memory summarizer flag, not queue overflow behavior.

- the doctor report reads `rt._summarizer_cfg.enabled` directly. `src/memory/lifecycle/diagnostics.zig:92-133`
- it prints that value as `summarizer: {}`. `src/memory/lifecycle/diagnostics.zig:197-203`
- `MemoryRuntime` copies `_summarizer_cfg.enabled` from `config.memory.summarizer.enabled` at init time. `src/memory/root.zig:447-448`, `src/memory/root.zig:1158-1164`
- the startup `memory plan resolved` log also prints `config.summarizer.enabled` directly. `src/memory/root.zig:1176-1186`

So if the terminal says `summarizer=false`, the effective memory runtime was initialized with summarization disabled.

### Why that can still coexist with "summarize" elsewhere

Queue summarize is a different subsystem:

- queue overflow with `queue_drop=summarize` increments `queue_summarize_pending_count` and later injects a synthetic notice into the next admitted message. `src/session.zig:234-276`, `src/session.zig:308-314`, `src/session.zig:422-434`

Memory summarizer is lifecycle-only:

- it is only consulted in `maybePersistLifecycleSummary(...)`
- it runs on checkpoint/persist flows, not on the main fast turn path
- it returns immediately if `summarizer_cfg.enabled` is false
- source: `src/agent/commands.zig:595-676`

### Why the checked-in evidence points to a real config mismatch

The earlier sweep inferred balanced-mode seeding, but the checked-in tenant logs show many seeded users still initializing with `summarizer=false`:

- `memory plan resolved ... summarizer=false`
- followed immediately by `tenant.runtime.config user=<id> source=postgres_seeded_from_file hash=59750d4df997b660`
- source: `docs/reports/2026-03-17-agent-wiring-sweep/evidence/logs/nullclaw-6dc897558c-8f4fw.log:589-610`

Code evidence says:

- balanced mode should map to `summarizer_enabled=true` in user-settings seeding. `src/user_settings.zig:81-100`
- seeding writes `memory.summarizer.enabled` into config JSON. `src/user_settings.zig:193-234`
- tenant seeding uses `resolveSettingsFromConfigJson(...)` and then `mergeSettingsIntoConfigJson(...)`. `src/gateway.zig:698-705`

High-confidence inference:
- the terminal is probably correct
- the mismatch is between expected seed behavior and the actual effective config derived from the base file
- that needs a focused config-truth investigation; it does not look like a display bug

### What the current deployment manifest would actually seed

The checked-in Kubernetes deployment does not write any explicit memory or product-settings block into the runtime `config.json`:

- it writes `agents.defaults.model`, `models.providers`, `gateway`, `tenant`, `state`, `composio`, `session`, and `channels`
- it does not write `memory`
- it does not write `product_settings`
- it does not write `agent`
- source: `deploy/k8s/zaki-bot/05-deployment.yaml:66-130`

Given that file, current source says:

- top-level memory defaults start as `profile="markdown_only"` and `backend="markdown"`. `src/config_types.zig:529-546`
- default memory search is `enabled=true`. `src/config_types.zig:587-598`
- tenant seed generation reads the base config file, resolves settings from `product_settings` or `agent`, and if neither exists falls back to `user_settings.defaults()`. `src/gateway.zig:698-705`, `src/user_settings.zig:103-105`, `src/user_settings.zig:141-143`
- `user_settings.defaults()` is `assistant_mode=balanced`. `src/user_settings.zig:42-48`, `src/user_settings.zig:103-105`
- balanced-mode seed output writes `memory.summarizer.enabled=true`. `src/user_settings.zig:81-89`, `src/user_settings.zig:229-234`, `src/user_settings.zig:498-535`

Under current checked-in code, a freshly seeded tenant from the checked-in deployment manifest should therefore look roughly like:

- `search.enabled=true` inherited from `Config.memory.search`
- `summarizer.enabled=true` written by balanced-mode seed JSON
- semantic tenant defaults applied afterward (`profile=postgres_hybrid`, hybrid query enabled, pgvector store, rollout `on`) without forcing either flag back off. `src/gateway.zig:645-684`, `src/config_types.zig:550-575`

### Why `search.enabled=false` is especially suspicious

Current code does not implicitly disable search in the tenant semantic path:

- `applyTenantSemanticMemoryDefaults(...)` sets profile/provider/fallback/store/rollout but never writes `search.enabled=false`. `src/gateway.zig:645-684`
- `MemoryConfig.applyProfileDefaults()` also never disables search. `src/config_types.zig:550-575`
- `search.enabled` only changes when parsed explicitly from JSON. `src/config_parse.zig:896-905`

So for a runtime that reports both:

- `effective_config_source=postgres_seeded_from_file`
- `retrieval=disabled`

the most likely explanations are not "terminal bug" or "profile side effect". They are:

1. The seed row in Postgres was created by an older image or older seed logic than the one currently checked in.
2. The live base config file used at seed time differed from the checked-in deployment manifest and explicitly disabled memory search.
3. The `postgres_seeded_from_file` source label is truthful only in a narrow sense, while the actual seed payload came from a partial or repaired config path that hid important fields.

### Strongest config-truth conclusion

The current repo now contains enough evidence to say something stronger than the earlier audit:

- the terminal readout is almost certainly truthful
- the observed `search=false` plus `summarizer=false` combination is real runtime state
- that combination does not match what the current deployment manifest plus current seeding code should produce for a brand-new seeded tenant

So the config-truth mismatch is not just "docs vs code". It is:

- checked-in deploy template and checked-in seed logic imply one runtime state
- checked-in staging diagnostics and logs show a different seeded runtime state

That means the repo's documented source of truth for tenant memory defaults is incomplete.

## 6. Important Wrinkles And Gaps

### A. Observability is missing the metrics you actually want for agent UX

Current observer events expose:
- whole-request `llm_request`
- whole-response `llm_response`
- coarse `turn_stage`
- no first-token / first-byte latency
- no prompt-build stage
- no cache lookup stage
- no SSE flush/delivery stage

Source: `src/observability.zig:3-25`

This means the repo can measure "full completion finished" much better than "how long until the user sees useful output".

### B. Prompt build cost is under-measured

The system prompt can be huge and is rebuilt from workspace files plus tool schemas plus skills, but there is no dedicated timing event around prompt construction. `src/agent/root.zig:1072-1140`, `src/agent/prompt.zig:89-165`

### C. Context compaction is trim-first, not intelligence-first

The hot path uses trim-only compaction:
- `self.trimHistory()` before provider
- `self.trimHistory()` after reply
- comments explicitly say "trim-only" and "keep interactive turns fast"

Source: `src/agent/root.zig:1180-1192`, `src/agent/root.zig:1616-1626`

Good for determinism, but not SOTA memory retention.

### D. Context exhaustion recovery is lossy

On context exhaustion the agent can `forceCompressHistory()` and keep only the system prompt plus the last few messages, dropping the middle without semantic preservation. `src/agent/root.zig:1348-1408`, `src/agent/compaction.zig:156-177`

### E. Current source and older timing artifacts have naming drift

Checked-in staging logs use `compact_pre_provider`; current source emits `turn_compaction` for the trim-before-provider stage. `docs/reports/2026-03-17-agent-wiring-sweep/sweep-report.md:39-47`, `src/agent/root.zig:1185-1191`

That is survivable, but it is a warning that some latency parsers and some mental models are already drifting from the source.

## 7. What Would Make This Feel SOTA

### P0: Fix truth and instrumentation

1. Add first-token and last-token timings, plus explicit stages for:
   - prompt rebuild
   - cache lookup
   - provider request start
   - first streamed token
   - persistence
2. Expose the effective per-tenant config that actually reached `MemoryRuntime`, including:
   - `memory.search.enabled`
   - `memory.search.provider`
   - `memory.summarizer.enabled`
   - `agent.queue_mode`
   - `agent.queue_drop`
3. Resolve the seed/config contradiction behind hash `59750d4df997b660`.
4. Log whether a tenant config row was seeded by current code, migrated from older rows, or repaired from fallback paths.

### P1: Improve context quality without making latency worse

1. If `MemoryRuntime` exists but `search.enabled=false`, fall back to plain `mem.recall(...)` instead of returning empty memory context.
2. Stop prepending memory to the raw user message; pack memory as a separate structured context block with its own budget.
3. Keep prompt cache stable across minute changes. Time should be a small dynamic section, not a reason to rebuild the whole system prompt.
4. Reuse tenant runtime config for the capabilities section instead of reloading disk config inside the turn.

### P1: Reduce avoidable latency

1. Add a cheap classifier/router for obvious tool-free/meta-free turns.
2. Special-case local status/runtime questions before the model decides to call `runtime_info`.
3. Default more flows to `thread:` or `task:` lanes instead of crowding `main`.
4. Precompute and cache serialized tool schemas and workspace prompt fragments per tenant/session.

### P2: Make memory actually agent-grade

1. Turn lifecycle summarization into a real tiered memory pipeline rather than checkpoint-only behavior.
2. Make the deployment template explicit about memory defaults instead of relying on struct defaults plus seed-time inference.
3. Add budget-aware context packing:
   - system prompt budget
   - working memory budget
   - recent-history budget
   - tool-reflection budget
4. Add durable semantic summaries that survive context exhaustion instead of relying on trim/drop recovery.

## 8. Bottom Line

This agent is not slow because Zig is slow or because the code is bloated. It is slow for two concrete reasons:

1. provider RTT is the main clean-turn cost
2. context and tool behavior are not yet budgeted and instrumented at SOTA granularity

And the `summarizer=false` readout is probably not lying. It is reporting the actual runtime memory summarizer flag, which currently appears to be off in the seeded tenant runtimes captured in this repo's own evidence. The bigger problem is that the current checked-in deploy template and the current checked-in seed path should not be producing that state for fresh tenants, so the real gap is configuration truth and rollout provenance.
