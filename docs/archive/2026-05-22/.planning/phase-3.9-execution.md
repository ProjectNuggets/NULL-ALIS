---
tags: [prose, prose/planning]
---

# Phase 3.9 Execution Plan — Step by Step

## Methodology
Each pass follows: **As-Is Analysis → Execute → Verify (test suite, no regressions)**

---

## Pass 1: Context Engineering Hardening

### 1.1 Quick Wins (Day 1)

**As-Is**: Analyze `compaction.zig` constants, `config_types.zig` queue drop, per-message truncation limits.

**Execute**:
| # | Change | File | Line | Before | After |
|---|--------|------|------|--------|-------|
| 1 | Queue drop fix | `config_types.zig` | 168 | `queue_drop = "newest"` | `queue_drop = "summarize"` |
| 2 | Summarizer source budget | `compaction.zig` | 32 | `MAX_SOURCE_CHARS = 12_000` | `MAX_SOURCE_CHARS = 80_000` |
| 3 | Summarizer output budget | `compaction.zig` | 25 | `MAX_SUMMARY_CHARS = 2_000` | `MAX_SUMMARY_CHARS = 16_000` |
| 4 | Per-message truncation | `compaction.zig` | 446 | `msg.content.len > 500` → 500 | `msg.content.len > 2000` → 2000 |

**Verify**: `zig build test` — all 5,300+ tests pass, no regressions.

### 1.2 Tool-Call Pair Hygiene (Day 1-2)

**As-Is**: Analyze `compactHistoryKeepingRecent` boundary logic — does `keep_recent` split tool_call/tool_result pairs?

**Execute**:
- In `compactHistoryKeepingRecent()`, after computing `keep_recent` boundary, walk backwards from boundary to find a clean split point (not between tool_call and tool_result)
- Add pair-integrity check: if message at boundary is `.tool` role, include it in keep_recent (extend boundary back)
- Add test: verify compaction never orphans a tool result from its preceding assistant tool_call

**Verify**: New tests + full suite pass.

### 1.3 Prompt Caching (Day 2-3)

**As-Is**: Analyze `providers/anthropic.zig` and `providers/openai.zig` message construction — how system prompts are structured, whether stable prefixes exist.

**Execute**:
- Create `NNGTs_cache.zig` — Anthropic `cache_control: {"type": "ephemeral"}` on system prompt message block
- Create `NNGTs_prefix_order.zig` — OpenAI deterministic tool definition ordering for automatic prefix caching (≥1024 tokens)
- Wire into existing provider message construction

**Verify**: Provider tests pass. Validate cache headers in request/response logs.

### 1.4 Three-Pass Compression (Day 3-5)

**As-Is**: Full analysis of the turn loop compaction call sites (7+ locations in root.zig), token budget policy, and interaction between autoCompact/forceCompress/trimHistory.

**Execute**:

**Pass A — Cheap Dedup at 60%** (new, zero LLM cost):
- New function: `cheapCompactionPass()` in `compaction.zig`
- Triggers at 60% of context window (new threshold in `TokenBudgetPolicy`)
- Operations:
  1. Deduplicate tool outputs: if same tool called with same args twice, keep only the latest result
  2. Placeholder substitution: replace tool results older than N turns with `[tool_result: {tool_name} — {first_line_preview}]`
  3. Clean orphaned tool_call/tool_result pairs
- No LLM call — pure string operations

**Pass B — Structured Extraction at 75%** (cheap model):
- New function: `structuredExtractionPass()` in `compaction.zig`
- Triggers at 75% (new threshold)
- Calls cheap model (Groq/Together) to extract: key decisions, files modified, current task state, unresolved items
- Output: structured bullet points replacing middle messages
- Requires: sidecar provider config for cheap model calls

**Pass C — Full LLM Summarization at 85%** (existing, upgraded):
- Existing `autoCompactHistory` refactored to trigger at 85% instead of 65%
- Change: use cheap model instead of main model for summarization
- Keep existing multi-part strategy (split >10 messages, summarize halves, merge)
- Keep workspace critical rules injection

**Wire cheap model provider**:
- Add `summarizer_provider` field to Agent struct (optional, falls back to main provider)
- Config: `agent.summarizer_model` and `agent.summarizer_provider` settings
- Default: use main provider if no sidecar configured

**Verify**: Full test suite + new tests for each pass. Integration test: simulate conversation hitting each threshold.

---

## Pass 2: Agent Modes Redesign

### 2.1 As-Is Analysis

Analyze:
- `config_types.zig`: `ProductPresetsConfig`, `AssistantModePresetConfig` structs — what fields exist
- `user_settings.zig`: `applySettingsToConfig()` — how presets map to runtime config
- `root.zig`: Agent struct — which fields are set from config (model_name, temperature, max_tokens, max_tool_iterations)
- How does the agent currently resolve its model? Is it per-session, per-turn, configurable?

### 2.2 Execute

**Expand `AssistantModePresetConfig`**:
- Add fields: `model_override: ?[]const u8`, `temperature: f64`, `max_tokens: u32`, `max_tool_iterations: u32`

**Update presets** (`config_types.zig`):
| Param | fast | balanced | deep |
|---|---|---|---|
| model_override | `null` (use cheapest configured) | `null` (use default) | `null` (use best configured) |
| temperature | 0.5 | 0.7 | 0.8 |
| max_tool_iterations | 8 | 25 | 50 |
| max_tokens | 2048 | 8192 | 16384 |
| queue_drop | "summarize" | "summarize" | "summarize" |
| max_history | 40 | 60 | 100 |

Note: `model_override = null` means the mode uses the provider's default model. The actual model mapping (fast→Haiku, deep→Opus) comes from configuration, not hardcoded — operators choose which model each tier gets. This keeps nullalis provider-agnostic.

**Update `applySettingsToConfig()`** (`user_settings.zig`):
- Apply new fields to `cfg.agent.*` and `cfg.default_temperature`

**Update Agent struct initialization** (`root.zig`):
- Respect mode-level overrides for temperature, max_tokens, max_tool_iterations

### 2.3 Verify
- Test each mode applies correct config values
- Test mode switch mid-session applies to next turn
- Full suite pass

---

## Pass 3: Self-Narration UX Upgrade

### 3.1 As-Is Analysis

Analyze:
- `narration.zig`: Current NarrationFrame struct, event mapping, emission path
- `observability.zig`: ObserverEvent variants, NarrationFrameType enum
- `root.zig`: Turn loop — where narration events are emitted, what data is available at each point
- `dispatcher.zig`: What tool metadata is available during dispatch (tool name, args, file paths)
- Frontend: How narration frames are rendered in ChatArea.tsx

### 3.2 Execute

**Layer 1: Tool-Specific Labels** (free):
- Extend `ObserverEvent.tool_call_start` to carry first-arg context (file path, command preview, query)
- Update `NarrationObserver.recordEvent` tool_call_start handler: format context-aware labels
  - read_file → "Reading {file_path}"
  - shell/bash → "Running: {command_first_40_chars}"
  - search → "Searching for '{query}'"
  - write_file → "Writing {file_path}"
  - Default → "Using {tool_name}"

**Layer 2: Thinking Narration Sidecar** (cheap LLM call):
- New file: `narration_thinking.zig`
- Function: `generateThinkingNarration(allocator, provider, recent_tool_pairs, model_name) ![]const u8`
- Takes last 3 tool_call+tool_result pairs (~500 tokens)
- Calls Groq/Together Llama 3.1 8B (same sidecar as Pass 1.4's cheap provider)
- Returns 1-2 sentence first-person narration
- Integration: in turn loop (`root.zig`), after every 3rd tool dispatch:
  ```
  if (iteration > 2 and iteration % 3 == 0) {
      narration = generateThinkingNarration(...);
      emit NarrationFrame { .frame_type = .thinking, .message = narration };
  }
  ```
- New `NarrationFrameType.thinking` variant in observability.zig

**Frontend** (zaki-prod):
- Add thinking frame type to narration renderer in ChatArea.tsx
- Render as italic thought bubble, distinct from tool status chips
- Subtle typing animation

### 3.3 Verify
- Test narration frames emitted with correct tool context
- Test thinking narration triggers at correct intervals
- Test graceful degradation if sidecar provider unavailable
- Frontend renders both frame types correctly

---

## Pass 4: Hermes-Inspired Improvements

### 4.1 As-Is Analysis

Analyze:
- `root.zig` turn loop: where to inject periodic nudges
- `memory_loader.zig`: how memory is currently stored/retrieved
- `prompt.zig`: skills section — how skills are loaded and injected
- Agent iteration counter and task complexity detection

### 4.2 Execute

**4.2a Periodic Memory Nudge**:
- Add `memory_nudge_interval: u32 = 10` to AgentConfig
- Add `turns_since_last_nudge: u32 = 0` counter to Agent struct
- In turn loop, after every N turns, inject invisible system message:
  > "Review the conversation so far. If any facts, preferences, or procedures should be remembered long-term, save them now. Only save what has lasting relevance."
- The agent uses its existing memory tool to persist — no new infrastructure needed

**4.2b Skills Auto-Extraction**:
- After turn loop exits with iteration > 5 (complex task), append to next system prompt refresh:
  > "You just completed a multi-step task. If this procedure could be reused, extract it as a SKILL.md file in the workspace."
- Add `last_task_tool_count: u32` to Agent struct, set after turn loop
- Skills infrastructure already exists (prompt.zig skills section with FTS search)

### 4.3 Verify
- Test nudge injection at correct intervals
- Test skills prompt appears after complex tasks
- Test no interference with normal flow
- Full suite pass

---

## Pass 5: Technical Polish

### 5.1 As-Is Analysis

Analyze `model_capabilities.zig` table — verify all entries match current model specs.

### 5.2 Execute

- Audit and update per-model context windows and max_tokens
- Add any missing models (newer Claude, GPT, Gemini variants)
- Verify provider fallback defaults are current

### 5.3 Verify
- Model capability tests pass
- Full suite pass

---

## Pass 6: Agent Lifecycle

### 6.1 As-Is Analysis

Analyze the full agent lifecycle:
- Session creation → first message → turn loop → idle → eviction → restore
- When does config apply? When does memory load? When does persona calibrate?
- What happens on: cold start, session restore, mode switch, session timeout, pod restart?
- How does the agent transition between: waiting → processing → tool executing → responding?
- What state survives across sessions? What's lost?
- Mid-session settings propagation (which settings hot-reload vs need session restart)

### 6.2 Execute

Based on as-is findings, address:
- **Settings hot-reload gaps**: Memory summarizer window and any other config that doesn't propagate mid-session
- **Session boundary clarity**: Ensure compaction/memory/skills state is properly checkpointed on session end
- **Graceful degradation**: What happens when the LLM provider is down? When memory is unavailable? When context is exhausted? Verify all failure paths have user-visible feedback
- **Cold start optimization**: First message latency — system prompt build, memory load, provider warmup
- **Lifecycle events**: Ensure observer emits events for session start, session end, mode change, compaction, memory nudge so the frontend can show appropriate UI state

### 6.3 Verify
- Trace test: simulate full lifecycle (create → 10 turns → compaction → mode switch → 10 more turns → session end → restore)
- Verify no state leaks between sessions
- Full suite pass

---

## Parallel Tracks (Separate Agents)

### Track A: UI/UX Audit
- Launch prompt: `zaki-prod/.planning/agent-prompts/ui-ux-audit.md`
- Output: `zaki-prod/.planning/ui-ux-audit.md`
- Fix P0s after Track A completes

### Track B: Positioning & Website
- Launch prompt: `zaki-prod/.planning/agent-prompts/positioning-website.md`
- Output: `zaki-prod/.planning/positioning.md`, `website-spec.md`, `pricing-strategy.md`
- Build landing page after Track B completes

---

## Execution Timeline

```
Day 1:    Pass 1.1 (quick wins) + Pass 1.2 (tool pair hygiene)
Day 2-3:  Pass 1.3 (prompt caching — NNGTs_cache.zig, NNGTs_prefix_order.zig)
Day 3-5:  Pass 1.4 (three-pass compression + cheap provider wiring)
Day 6-8:  Pass 2 (agent modes redesign)
Day 7-8:  Pass 3 Layer 1 (tool-specific narration labels)
Day 8-10: Pass 3 Layer 2 (thinking narration sidecar)
Day 9:    Pass 4.2a (periodic memory nudge)
Day 9-10: Pass 4.2b (skills auto-extraction)
Day 10:   Pass 5 (model capabilities audit)
Day 11+:  Fix UI/UX P0s, build landing page, final regression
```

## Success Gate

Every pass must:
- [ ] As-is analysis documented before changes
- [ ] All existing tests pass after changes (no regressions)
- [ ] New tests cover new functionality
- [ ] `zig build test` clean
