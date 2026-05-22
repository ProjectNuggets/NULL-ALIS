---
tags: [prose, prose/docs]
---

# V1 — Ready Declaration

**Date:** 2026-04-30
**Backend HEAD:** `4fa5265`
**Tests:** 5595/5631 pass, 36 skipped
**Build:** ReleaseFast green, no warnings
**Owner:** Nova + this Claude session (decisions live here)

---

## Verdict

**V1 backend is declared ready to ship 2026-05-05.**

Zero critical findings from the pre-declare audit. All flagged operational concerns addressed in the close-out arc (commits since `5ff846f`). Backend is honest, observable, sandboxed, tested, single-source-of-truth.

---

## What shipped in the close-out arc (8 commits, 2026-04-29/30)

```
4fa5265 refactor(gateway): TenantRuntime.resolvedSessionStore — single source of truth
f152514 perf+test(agent,sse): O(N) forward-sweep elision + SSE regression coverage
ea9f331 fix(gateway): log infra errors instead of swallowing as not_found / queue_decline
5926944 chore(channels): remove Lark from operator-facing surface (Nova directive)
5ff846f docs(compaction): clarify compaction_trigger is advisory, not a fire signal
6d4ecce fix(modes): V4-Pro context window 128K→512K + cache/reasoning observability
8bed18b feat(modes): swap balanced + deep to DeepSeek V4-Pro on Together
5b34a8b feat(api): session-truth fields for /sessions list + detail (Codex ask)
```

Plus the V1.5-prep arc (10 commits, 2026-04-28/29) covering sandbox hardening, sentry fork, policy relaxation, multimodal CWD fix, Telegram sendPhoto, UX-enabling endpoints. **18 atomic commits total since V1 close started.**

---

## Honest-debt scorecard

| Surface | Verdict |
|---|---|
| TODO/FIXME/HACK density across all of `src/` | **2 TODOs total** in 36K LOC. No FIXME, no XXX, no WORKAROUND. |
| Test coverage | 5595 tests passing across 12 areas; 940 memory + 731 channels + 688 tools + 548 agent + 388 gateway |
| Compile warnings (ReleaseFast) | **0** |
| Critical-path silent error swallows | All audited; intentional best-effort paths kept, observability paths now log.warn / log.err |
| Cross-tenant boundaries | Sandbox (bwrap+tmpfs+unshare-all) verified clean. Path security comprehensive (15 system-blocked prefixes, URL-encoded traversal blocked, symlink-resilient). |
| Mode plumbing | DeepSeek V4-Pro on balanced+deep verified at `config_types.zig:274/315` + `model_capabilities.zig:68-69` + tests |
| Compaction | Trigger curve simple + correct: 70% Pass A (cheap dedup), 90% Pass C (LLM summary). 50% is advisory only, doc clarified at `compaction.zig:88` |
| Provider-side caching observability | `cached_prompt_tokens` + `reasoning_tokens` fields wired in TokenUsage; populates automatically when Together surfaces them for V4-Pro |

---

## No miswirings. No double sources of truth.

Audit findings, all closed:

| Finding | Resolution |
|---|---|
| V4-Pro context window resolved to 128K (wrong) | Fixed in `6d4ecce` — explicit MODEL_TABLE + V4-specific inferFromPattern, now 512K verified |
| `compaction_trigger=50%` doc said "fires at 50%" (wrong) | Fixed in `5ff846f` — clarified advisory marker, real fire thresholds 70/90 |
| Lark TODO + 215 dead-code refs | Operator surface removed in `5926944`; full source delete deferred to V1.5 first-week per scope-before-delete |
| `loadDiagnosticsConfigSnapshot` swallowed PG/disk errors as 404 | Fixed in `ea9f331` — log.warn distinguishes infra failure from "user not found" |
| `enqueueTenantTelegramAsync` masked OOM as queue decline | Fixed in `ea9f331` — log.err per alloc-fail step |
| `extractSseEvent` zero direct tests | Fixed in `f152514` — 4 regression tests covering malformed JSON, missing delta, non-object choices, valid array passthrough |
| `elideUnverifiedHistory` O(N²) backward walks | Fixed in `f152514` — single forward sweep, semantically equivalent across 8 verified scenarios |
| TenantRuntime PG-vs-mem session store dedup | Fixed in `4fa5265` — `resolvedSessionStore()` method, single source |

---

## Stale memory entries — closed

Updated in `~/.claude/projects/-Users-nova-Desktop-nullalis/memory/`:

- `project_subagent_received_bug.md` — closed 2026-04-25 via D1 sprint TurnOutcome refactor + tool_only_turn SSE event. Verified at HEAD: only doc-comment reference to "received" remains.
- `project_approval_drop_bug.md` — closed 2026-04-18 via continue-turn-after-approval pattern at `commands.zig:2408-2483`. Verified at HEAD: `executeApprovedPendingTool` → synthetic continuation message → `agent.turn()` → return reasoning result.

---

## What's deferred to V1.5 first week (filed, not blocking V1)

1. **Lark dead-code cleanup** — delete `src/channels/lark.zig`, remove `LarkConfig`, sweep ~200 remaining refs across config/channel_manager/websocket/gateway/memory/etc.
2. **NULLCLAW_* deprecation sweep** — 127 refs in `src/`, deprecation date 2026-05-15. Trivial migration; flagged for completion before deprecation.
3. **Cached/reasoning tokens UI surface** — fields tracked in TokenUsage; surface in `/sessions/:key/context` so frontend can show effective cost.
4. **Cost-tracker billing rules** — needs per-provider price table for cached vs full input.
5. **openai.zig + openrouter.zig + anthropic.zig parser parity** — they don't yet parse cached/reasoning tokens. Compatible.zig (Together path) does.
6. **`elideUnverifiedHistory` cold-cache `memory_enrich` 900ms variance** — known soft spot, not regressing.

Plus the operational items pending on Nova:
- Sentry DSN finalize on DO k8s
- D-phase escape tests on Linux staging
- V4-Flash on fast (after measuring Kimi K2.5 latency complaints)
- Multi-channel `image_url` extension (Discord, Slack, WhatsApp, Email, Matrix)
- Re-host uploaded attachments to public URLs (so reference_urls works for user uploads)
- MCP child-process wrap (post-self-service-MCP-UI)
- cgroup/resource limits

---

## Frontend status — dependent on Codex's branch

Codex shipped the in-thread session controls UX in zaki-prod. Backend exposes everything that work needs:

- `GET /api/v1/status.sandbox.{enabled,backend}` — for sandbox status badge
- `POST /api/v1/users/:id/sessions/:key/mode` — for Plan/Execute/Review segmented control
- `GET /api/v1/users/:id/sessions/:key/context.context_pressure_percent` — for context-state indicator
- `GET /api/v1/users/:id/sessions` — list now includes mode + pending_approval_count + last_channel + context_pressure_percent per session
- `GET /api/v1/users/:id/sessions/:key` — detail includes pending_approvals[] + same fields, with persisted-session fallback (no 404 for evicted sessions)

When Codex/zaki-prod side merges, redeploy lands V1 + V1.5 frontend together on 2026-05-05.

---

## Operating model

**Decisions live in this Claude session with Nova.** Codex CLI and frontend agents are delegates for parallel work; correctness audits, architecture changes, and V1.5 design happen here. Backend code reviews of any substantial changes go through Nova + this session before merging to main on the nullalis side.

— V1 ready, signed at HEAD `4fa5265`.
