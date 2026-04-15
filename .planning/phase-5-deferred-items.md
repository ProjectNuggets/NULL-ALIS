# Phase 5 SOTA — Remaining Items

## Completed in Phase 3.9 (moved out of deferred)

The following were originally deferred but shipped in the Sidecar Pass:
- ✅ Sidecar provider wiring (Groq free tier)
- ✅ Thinking narration sidecar (every 3 tool iterations)
- ✅ Structured extraction at 75% compaction threshold
- ✅ Compaction routed through sidecar (cost savings)

## Remaining Phase 5 Items

### Native Extended Thinking (replaces sidecar narration long-term)

**Discovery**: Claude Code uses native extended thinking — a `thinking` content block
in each model response. The model's own reasoning IS the narration. No separate call.
This is higher quality than our sidecar approach (8B model guessing what the main model thought).

**Implementation**:
- Models that support it: Claude (extended thinking API), GLM 5.1 (`<think>` blocks), Hermes 4
- Parse `thinking` content blocks from provider responses
- Emit as NarrationFrame with .thinking type (same frontend path)
- Sidecar narration becomes the fallback for models without native thinking
- Budget control via Anthropic's `budget_tokens` parameter

**Effort**: 2-3 days
**Impact**: Higher quality narration + zero extra latency/cost

### Multi-Session Frontend

**Implementation**: Frontend thread management, session switching, parallel conversations.
Currently the agent uses a single main session per user.

**Effort**: 3-5 days (frontend + session routing)

### CLI Agent + Downloadable App

- Model picker (per-mode override for power users)
- `--model` flag and config file override
- Web app: modes only, no model visibility

### Specific Error Codes

- Map LLM error classes to user-facing codes (rate_limited, context_exhausted, provider_unavailable)
- Currently all failures show generic "chat_failed"

### Config Staleness Detection

- Check config hash on getTenantRuntime at configurable interval
- Detect external config changes without requiring explicit invalidation

---

## Previous Shared Dependency (RESOLVED)

The sidecar provider was the shared dependency. It's now wired:
- Config: `SidecarConfig` in config_types.zig
- Provider: RuntimeProviderBundle builds sidecar ProviderHolder
- Wiring: Config → Bundle → SessionManager → Agent
- Default: Groq free tier (`llama-3.1-8b-instant`)
- All three items need a lightweight provider instance that:
- Is separate from the main agent provider (doesn't use the mode's model)
- Calls a fast, cheap model (Groq free tier → Together $0.18/M fallback)
- Is configured once per TenantRuntime, available to the Agent struct
- Has its own API key resolution (GROQ_API_KEY / TOGETHER_API_KEY)

### Implementation

1. Add `sidecar_provider: ?Provider` field to Agent struct
2. Add `sidecar_model: []const u8` to AgentConfig (default: "llama-3.1-8b-instant")
3. Add `sidecar_provider_name: []const u8` to AgentConfig (default: "groq")
4. RuntimeProviderBundle builds a second CompatProvider for the sidecar
5. Agent.fromConfig receives it alongside the main provider

---

## Item 1: Thinking Narration Sidecar (Pass 3 Layer 2)

**Goal**: Every 3 tool iterations during multi-step tasks, generate 1-2 sentences explaining
what the agent just figured out and what it plans next.

**Implementation**:
- New file: `agent/narration_thinking.zig`
- Function: `generateThinkingNarration(allocator, sidecar_provider, sidecar_model, recent_tool_pairs) ![]const u8`
- System prompt: "You are a narration assistant. Given recent actions and results, write 1-2 sentences explaining what the agent figured out and what it plans next. First person, specific."
- Input: last 3 tool_call + tool_result pairs (~500 tokens)
- Output: ~30-50 tokens
- Integration: in turn loop (root.zig), after every 3rd tool dispatch:
  ```
  if (iteration > 2 and iteration % 3 == 0 and self.sidecar_provider != null) {
      narration = generateThinkingNarration(...);
      emit NarrationFrame { .frame_type = .thinking, .message = narration };
  }
  ```
- New `NarrationFrameType.thinking` variant in observability.zig
- Frontend: render as italic thought bubble, distinct from tool status chips
- Graceful degradation: if sidecar fails, skip narration (don't block the turn)

**Cost**: ~$0/month on Groq free tier (14,400 req/day). $1.50/month on Together fallback.
**Effort**: 2-3 days (including sidecar provider wiring)

---

## Item 2: Structured Extraction at 75% (Pass 1B)

**Goal**: Between the cheap dedup pass (60%) and LLM summarization (85%), extract key state
into a structured format via the sidecar model.

**Implementation**:
- New function in `compaction.zig`: `structuredExtractionPass()`
- Triggers when token estimate > 75% of context window (after cheap pass)
- Calls sidecar model with prompt:
  "Extract from this conversation: (1) key decisions made, (2) files modified,
   (3) current task state, (4) unresolved items. Bullet points only."
- Input: middle messages (between system and keep_recent boundary), ~2k tokens
- Output: structured bullets, ~500 tokens
- Replaces middle messages with the extraction
- Falls back to no-op if sidecar unavailable

**Cost**: Same sidecar, ~100 tokens per extraction. Negligible.
**Effort**: 1 day (after sidecar is wired)

---

## Item 3: Model Picker UI (Web App NOT included)

**Note from product owner**: Model picker is NOT for the web app. This is for the
downloadable app and CLI agent only. The web app routes models transparently via modes.

**Implementation (downloadable/CLI only)**:
- Settings page shows current model per mode
- Advanced section: override model within a mode (power user)
- CLI: `--model` flag or config file override
- Web app: modes only, no model visibility

**Effort**: 1-2 days (UI component + CLI flag)

---

## Execution Order

```
Day 1-2: Sidecar provider wiring (shared dependency)
Day 2-3: Item 1 — Thinking narration sidecar
Day 3:   Item 2 — Structured extraction at 75%
Day 4:   Item 3 — CLI model override (if CLI ships in Phase 5)
```

Total: ~4 days of focused work, all building on the sidecar provider.
