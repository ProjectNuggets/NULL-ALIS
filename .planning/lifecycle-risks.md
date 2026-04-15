# Agent Lifecycle — Known Risks (Post Phase 3.9)

## Fixed in Phase 3.9

### P0: Use-after-free on settings change during active turn — FIXED
- **Problem**: `removeTenantRuntime` destroyed the runtime immediately while concurrent request threads could hold a pointer to it.
- **Fix**: Settings PATCH now calls `markTenantRuntimeForDestroy()` which sets an atomic `pending_destroy` flag. The maintenance loop (1s interval) sweeps marked runtimes and only destroys them once `hasActiveTurns()` returns false. `getTenantRuntime()` skips pending_destroy runtimes and creates new ones with fresh config.
- **Files**: `gateway.zig` (markTenantRuntimeForDestroy, pruneTenantRuntimeCache, getTenantRuntime), `session.zig` (hasActiveTurns)

### P1: Memory enrichment failure kills the turn — FIXED
- **Problem**: `enrichMessageWithRuntimeDetailed` was called with `try`, propagating backend errors to the caller and failing the entire turn.
- **Fix**: Wrapped in `catch` block that logs a warning and falls back to the raw user message. Memory is an enhancement, not a prerequisite.
- **File**: `agent/root.zig` line ~1507

---

## Accepted for Launch (P2/P3)

### P2: No config staleness detection on TenantRuntime cache
- **Impact**: External config changes (e.g., Postgres row updated by another service) are not picked up until the runtime is pruned by idle TTL or explicitly invalidated.
- **Mitigation**: Settings PATCH correctly invalidates. Direct DB edits are an operator action, not a user flow. Acceptable for 500 users.
- **Future fix**: Add config hash check on `getTenantRuntime()` — compare stored hash against Postgres on a configurable interval (e.g., every 60s).

### P2: Blocking 500ms sleep in retry path
- **Impact**: Under high load, the sleep in the LLM retry path ties up request threads.
- **Mitigation**: The ReliableProvider wrapper handles most retries internally with its own backoff. The 500ms sleep is the non-reliable fallback path, used only when reliability is not configured. With 500 users, request concurrency is low.
- **Future fix**: Replace sleep with async retry or move to cooperative scheduling.

### P2: Generic error codes to user
- **Impact**: All LLM failures surface as `chat_failed` regardless of cause (rate limit, auth, timeout, context exhaustion).
- **Mitigation**: Error cause is logged server-side. User sees the error and retries.
- **Future fix**: Map error classes to specific user-facing codes (rate_limited, context_exhausted, provider_unavailable).

### P3: Compaction summaries lost on session restore
- **Impact**: Only user/assistant messages are persisted to session store. Compaction summary injections (role=assistant with [Compaction summary] prefix) are saved because they use assistant role. However, system-role messages (e.g., memory nudge, skills prompt) injected into history are NOT persisted.
- **Mitigation**: Memory nudge and skills prompts are transient by design — they're instructions for the next turn, not history. The system prompt is rebuilt fresh on restore.
- **Future fix**: None needed. Current behavior is correct.

### P3: Session TTL recycling vs eviction inconsistency
- **Impact**: A TTL-expired session is recycled in place on next turn (line 549) but evicted during sweep (line 774). The behavior differs: recycle preserves the session key entry, eviction removes it.
- **Mitigation**: Both paths checkpoint the session. The net effect is the same: next turn starts with fresh config and restored history.
- **Future fix**: Unify to single path if it causes confusion in monitoring.

### P3: Mid-session mode switch — memory summarizer window doesn't hot-reload
- **Impact**: `MemoryRuntime._summarizer_cfg` is set once at init. Changing mode (which changes summarizer window_size_tokens) doesn't propagate to the live memory runtime.
- **Mitigation**: Mode switch destroys the TenantRuntime (via pending_destroy), so the next request creates a new runtime with the new summarizer config. This is correct behavior — the risk is theoretical.
- **Future fix**: None needed given the destroy-and-recreate pattern.
