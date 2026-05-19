---
tags: [prose, prose/docs]
---

# Post-Compaction Handoff (2026-04-30)

**Purpose:** survive a compact. Self-contained context for the post-compact me.

## State at compaction

- **Main HEAD (will be):** todo-prompt-directive commit (about to land)
- **V1 status:** declared READY at HEAD `2ddc2d6` via `docs/v1-ready.md`
- **V1.5 status:** day-1 shipped (todo tool + prompt directive). Days 2-5 pending.
- **Ship target:** 2026-05-05 (V1 + V1.5 simultaneous)
- **Tests:** 5601/5637 pass, 36 skipped, ReleaseFast clean
- **Internals/:** P-files at `4f27487` (last bumped 2026-04-30 in earlier session — needs bump to current HEAD post-compact)

## Operating model

**Decisions live in this Claude session with Nova.** Codex CLI + frontend agents are delegates. Anything substantial that lands on `main` for nullalis goes through Nova + this Claude session before merge. Future me-after-compact: respect this rhythm; don't autonomously merge frontend work without Nova greenlight.

## Today's commit ledger (2026-04-30)

```
[todo-prompt-directive — about to land] feat(prompt): todo tool trigger discipline
f0d27f8 feat(tools): todo tool — V1.5 day-1
4bee264 docs(research): consolidated graph-memory ecosystem reference
d005a44 docs(design): frontend vision brief for Claude design agent
03fa184 docs(v1.5): research addendum — bi-temporal + cosmos.gl + classifier namespace
bad77a8 docs(v1.5): lock design choices after Nova greenlight
2ddc2d6 docs(v1): ready declaration + V1.5 design kickoff + activation list refresh
4fa5265 refactor(gateway): TenantRuntime.resolvedSessionStore — single source of truth
f152514 perf+test(agent,sse): O(N) forward-sweep elision + SSE regression coverage
ea9f331 fix(gateway): log infra errors instead of swallowing as not_found / queue_decline
5926944 chore(channels): remove Lark from operator-facing surface (Nova directive)
5ff846f docs(compaction): clarify compaction_trigger is advisory, not a fire signal
6d4ecce fix(modes): V4-Pro context window 128K→512K + cache/reasoning observability
8bed18b feat(modes): V4-Pro on balanced + deep, Kimi K2.5 on fast
5b34a8b feat(api): session-truth fields for /sessions
2ab4236 feat(api): UX-enabling endpoints + sandbox state snapshot + prompt polish
83b224a fix(prompt): reference_urls dot-connection
a93e941 fix(prompt,message): de-Telegram-ify
0fc4aef feat(message,prompt): Telegram sendPhoto + image guidance
6af358f fix(multimodal): workspace-relative read
bd388d2 docs(handoff): zaki-prod sandbox+policy
a19d460 feat(policy): sandbox-aware allowlist
7b57e85 fix(sandbox): /tmp tmpfs
e67e15e chore(deps): sentry fork swap
897e9d5 feat(sandbox): A-C-E finish
fe651ba docs(legal): chatzaki.com handoff
4f27487 docs(audits): sandbox + frontend gap docs
dab1dff fix(sandbox): firejail/bwrap binary check
399a0d8 fix(sandbox): landlock fail-closed
4fe5fe4 fix(sandbox): bwrap --chdir
c3a7c29 docs(sweep): archive 9 stale docs
```

## V1.5 sequencing (where we are)

| Day | Backend (this session) | Frontend (Codex / Claude design + Opus impl) |
|---|---|---|
| 04-30 | ✅ Day 1 SHIPPED — todo tool + prompt directive | Codex finishing in-thread controls UX |
| 05-01 | **Day 2 NEXT:** bi-temporal `valid_to` schema + `/brain/graph` + `/brain/timeline` endpoints | Claude design produces wireframes per `docs/frontend-vision-brief.md` |
| 05-02 | **Day 3:** `compose_memory` tool + `/brain/compose` endpoint | Frontend agent (Opus + Codex tag-team) starts implementation |
| 05-03 | **Day 4:** traversal-event logging + brain-page prompt directive | Frontend pieces land + reviewed at diff level |
| 05-04 | **Day 5:** polish + tests + final QA pass | Final integration |
| **05-05** | **V1 + V1.5 SHIP** | **Deploy** |

## V1.5 design — locked answers (Nova greenlight)

1. **Todo persistence scope:** per-session
2. **Graph edge weights:** static (cosine > 0.7 default) for V1.5; log traversal events from day 1 to bootstrap V1.6 learned weights with 30+ days of real data
3. **Graph node cap:** 500 default, user-toggleable
4. **Compose-memory authorship:** visible (`synthesized_by: "agent"` + `references: [source_keys]`)

## V1.5 research-driven adoptions (Nova greenlight)

1. **Graphiti bi-temporal model** (Apache-2.0) — add nullable `valid_to: ?i64` to memory entries in V1.5 schema. Day 2 work.
2. **Supermemory `packages/memory-graph`** (MIT) — vendor for `/brain` graph view in zaki-prod. Saves Codex 2-3 days. Replaces earlier cosmos.gl recommendation.
3. **Mem0 ADD/UPDATE/DELETE/NONE classifier namespace** — reserve `event_kind` + `decision_type` columns on V1.5 traversal-event log table. V1.5 emits only "traversal"; V1.6 classifier emits "memory_decision" rows in same table. Avoids migration.

## Reference docs to read first after compact

1. `docs/v1-ready.md` — V1 ready declaration + close-out scorecard
2. `docs/v1.5-design-kickoff.md` — full V1.5 design + locked choices + research addendum
3. `docs/graph-memory-research.md` — every graph-memory repo evaluated (don't re-research)
4. `docs/frontend-vision-brief.md` — what backend wants from frontend (for Claude design)
5. This doc

## Pending on Nova (operational)

1. **Hand `docs/frontend-vision-brief.md` to Claude design** for wireframes
2. **Spawn Opus + Codex tag-team for frontend implementation** when designs land — Nova confirmed Codex alone wasn't delivering quality, will pair with Opus
3. **Sentry DSN finalize** on DO k8s — once V1.5 deploys
4. **D-phase escape tests** at Linux staging — once V1.5 deploys
5. **Greenlight supermemory adoption** ✅ GIVEN
6. Watch promo expiry on V4-Pro May 5 — bump cost-monitoring eyes

## V1.5 day-2 (next session resumption point)

The natural next step after compact:

1. **Bi-temporal `valid_to` schema:**
   - Add `valid_to: ?i64 = null` to `MemoryEntry` struct in `src/memory/root.zig`
   - Update `Memory.store` / `Memory.list` paths to thread it through
   - Update SQL schema if postgres backend (`src/zaki_state.zig` schema files)
   - Update retrieval to filter `valid_to IS NULL OR valid_to > now()`
   - Tests
   - ~2-3 hours

2. **`/brain/graph` endpoint:**
   - New handler in `src/gateway.zig` — `handleBrainGraph`
   - Reads memories for user, builds nodes + edges JSON
   - Edge types: session (same session_id), semantic (cosine > 0.7 from existing pgvector), reference (parse `memory:<key>` patterns in content)
   - Query params: `since`, `max_nodes`, `node_kinds`
   - Tests
   - ~3-4 hours

3. **`/brain/timeline` endpoint:**
   - Simpler — straight DB query on memories ordered by created_at
   - Query params: `from`, `to`, `session_filter`
   - Tests
   - ~1 hour

Total day-2: ~6-8 hours focused work.

## Critical context for post-compact me

1. **Frontend is in much better shape than the activation list reflects.** Codex shipped SlashCommandPalette, MemoryViewer, ReasoningBlock, TurnTimeline, CronManagementSheet, SecretsVaultSheet, DiagnosticsSheet, SessionManagementSheet, full approval card, autonomy radio, sandbox badge, cost view. Real V1 P0 frontend gaps are 4 small items (privacy footer, cost chip, inline mode strip, slash mount verify) totaling ~2 days frontend work.

2. **Codex+Opus tag-team for frontend is Nova's decision** post this compaction. Don't unilaterally re-engage Codex; respect Nova's bandwidth.

3. **DeepSeek V4-Pro on balanced + deep is shipped and verified.** Kimi K2.5 stays on fast (byte-stable prefix). Pressure logs read correctly after V4-Pro context fix (512K, was 128K).

4. **Sandbox auto-mode is shipped and clean.** bwrap --chdir + landlock fail-closed + firejail/bwrap binary checks + tmpfs /tmp + ACE finish. Cross-tenant verified clean.

5. **Stale memory entries closed** for subagent_received_bug + approval_drop_bug. Both are CLOSED with verification anchors at HEAD `4fa5265` + `commands.zig:2408-2483`.

6. **Lark removed from operator surface** but ~200 dead-code refs remain in src/. Cleanup is V1.5-first-week post-ship work.

7. **NULLCLAW_* deprecation date is 2026-05-15.** 127 refs in src/. Sweep before that date or paying users see deprecation banners.

## Discipline reminders (from prior handoff that worked)

1. Per-commit P-file updates — rhythm broke once already, don't break again
2. Atomic PRs per item, sprint-granular per Nova's pattern
3. `zig build test` green before every commit
4. Don't change behavior the user is actively testing without flagging
5. Backend stays truthful — frontend handles UX simplification (PR #66 lesson)
6. Father, not godfather — slow and honest > fast and theatrical

---

*Written 2026-04-30 pre-compact. Update inline as items close.*
