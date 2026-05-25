---
tags: [prose, prose/docs, prose/readiness]
authored: 2026-05-23
purpose: Direct-agent QA results — grounds Sprint 4 / commercial v1 scope in observed behaviour
pairs_with: STATUS.md, AGENTS.md §14.6, docs/ROADMAP.md (Sprint 4 row)
---

# Sprint 4 Readiness — Direct Agent QA, 2026-05-23

**Method.** Talked to the live gateway as a client over the same SSE
protocol the bench harness uses (`/api/v1/chat/stream`, `/tmp/qa_driver.py`).
8 tests on clean tenant `user_id=2005`, fresh single-turn sessions. Gateway
started production-clean (no bench env vars). Each test captured (a) the
agent's user-visible reply, (b) the gateway-side telemetry
(`compaction.auto`, `recall.metrics`, `extraction.persisted`,
`memory.write.batch_done`, `lifecycle.async.spawned`, tool dispatch logs),
(c) the postgres memory state for the tenant after the run.

This is the qualitative ground-truth doc that Sprint 4 scope hangs on —
*"would a paying customer hit this on day 1?"*

---

## Test matrix

| # | Test | Verdict | Elapsed | Notes |
|---|---|---|---|---|
| T1 | Cold hello | ✅ PASS | 6.7s | "I'm ZAKI BOT…" — natural, no leaks, honest persona |
| T2 | Shell tool (`echo hello`) | ❌ **BLOCKER** | 26.8s | Docker sandbox returns `invalid empty volume spec`; agent diagnosed correctly + reported honestly, but the tool is unusable |
| T3a/b | In-session memory store + recall | ✅ PASS | 12.2s + 9.7s | Stored "favorite color is teal", recalled cleanly |
| T4a/b | **Cross-session memory** (same user, different session) | ✅ PASS | 16.8s + 4.4s | Stored 2 facts in session A; cold session B retrieved BOTH. **The v1 differentiator works.** |
| T5a/b | **Temporal anchor** (the #1 fix) | ✅ PASS (text), ⚠ PARTIAL (structured) | 44.9s + 9.7s | Stored "Phoenix started May 5, 2026"; cold recall returns the date. BUT `memory_edges.temporal_anchor_unix` is NULL — the model didn't emit the structured `valid_at` JSON field; the date survives because it's in the `fact` text |
| T6 | **Subagent spawn / delegate** (v1 critical path) | ❌ **BLOCKER** | 40.9s | Agent reports honestly: *"I don't have a subagent-spawning capability"*. **Root cause:** `delegate` + `spawn` tools exist (`src/tools/delegate.zig`) but are **gated behind `NULLALIS_ENABLE_MULTIAGENT`** and off by default (test at `src/tools/root.zig:2858` confirms). Also reveals an XML leak (see Polish #1) |
| — | Streaming hygiene (passive) | ⚠ PARTIAL | — | First-line `<tool_call>` leak (today's fix) works on T1-T5. T6 surfaced a **mid-stream** leak (`tool_call>` appears after a text preamble, before the model switches to the tool call) — the fix only covers first-chunk |
| — | Tool honesty (passive) | ✅ PASS | — | When shell broke + when subagent unavailable, agent diagnosed accurately and named the issue. §14.6/§14.9 behaviour is real |

---

## Telemetry snapshot (gateway log)

- **`recall.metrics`** fired on every turn. Best sample: `candidates=64, global_candidates=128, semantic_entries=4, semantic_bytes=2112, durable_facts=4, fallback_entries=1, enrich_ms=20586` — P5 trace events confirmed live; P1/P2 in the recall pipeline.
- **Memory writes**: 8 `memory.write.batch_done origin=memory_store_tool` events. Direct-store path is the dominant write path on these short conversations (Pass C extraction didn't fire — no compaction needed at small context). Pass C is exercised in long conversations only.
- **`compaction.auto`** evaluated 33×, fired 0× — expected on short single-turn sessions. Cannot verify Pass-C-driven extraction from this QA; needs a longer-conversation test.
- **Tool calls by name (across all 8 tests):** `memory_store` 8, `shell` 4, `memory_recall` 2, `calculator` 2. **`delegate` / `spawn`: 0** (gated off).
- **`lifecycle.async.spawned`**: 5× — all `reason=summary_seed:auto` (background summary writes, not subagent spawns).

## Memory state after QA (user 2005, postgres)

```
memories:                34 rows
memory_edges:             4 rows (PREFERS, FAVORITE_LANGUAGE, USERNAME, STARTED_PROJECT)
edges_with_temporal_anchor: 0 ← #1 structured-field gap (text recall still works)
```

The 4 semantic edges look right:
- `PREFERS | user's favorite color is teal`
- `FAVORITE_LANGUAGE | User's favorite programming language is Zig.`
- `USERNAME | User's username is alaa.`
- `STARTED_PROJECT | User started a new project called 'Phoenix' on May 5, 2026.` ← **date in fact text, per #1 prompt fix**

---

## Sprint 4 BLOCKERS (must-fix before commercial v1)

These are the "would I bet money on this not embarrassing us in front of a paying customer" failures.

### B1. **`delegate` / `spawn` are off by default** (T6)

**Symptom:** Agent cannot delegate work to a sub-agent. It says so honestly:
> *"I don't have a subagent-spawning capability — there's no `spawn` or `delegate` tool in my runtime."*

**Root cause:** `src/tools/delegate.zig` ships a complete `delegate` tool (named, schemed, depth-tracked, tested). The default tool registry **filters it out unless `NULLALIS_ENABLE_MULTIAGENT=1`**. The gate is documented in the test at `src/tools/root.zig:2850-2867`.

**Same anti-pattern as P4** (silently off via env). And as P4 just demonstrated, an operator setting it in `.env` does NOT activate it because the binary doesn't auto-load `.env`.

**Fix:** flip the multiagent gate default — `delegate` + `spawn` ON by default, with the env var as the explicit opt-out (same shape as the P4 fix landed today). The V4 ledger-bridge work that just merged (`subagent.zig`, `task_lifecycle_test.zig`) is the *plumbing* that makes this safe at runtime; the gate flip is the *surface* that makes it visible to the agent. **One-line gate change + a test update.**

### B2. **Shell tool unusable** (T2)

**Symptom:** Every shell-tool invocation fails with `docker: invalid empty volume spec`.

**Root cause:** Sandbox config — `backend=docker, fail_open_on_dev=false`. Docker `-v ""` (empty mount spec) is rejected. Somewhere in the sandbox-arg builder a workspace mount path is empty. The agent's diagnosis was correct.

**Fix:** trace the empty volume in `src/tools/tool_sandbox_v1.zig` or `src/tools/shell.zig` (likely a workspace-path resolver returning "" for users without a configured `workspace_dir`). Either fall through to a default or fail loud at sandbox-init, not at every invocation. **Bench:** any `shell` call on a fresh user must succeed.

---

## Sprint 4 POLISH (should-fix before v1, not commercial blockers)

### P1. **Mid-stream `<tool_call>` XML leak** (T6 reply line "tool_call>")

The streaming-hygiene fix that landed today (`c6d9b8ea`) handles the **first-line** case (when the buffer starts with `<tool_call>` markup). T6 surfaced the **mid-stream** case: the model emits text, then mid-response switches to a tool call, the `<tool_call>` opener leaks because the streaming filter is already in `pass_through` mode.

**Fix:** widen the streaming guard to also detect `<tool_call>` in subsequent chunks while in `pass_through` mode (re-enter `hold_for_validation` when an opener appears). Or have the provider emit a marker event for "tool-call payload begins" so the streamer suppresses cleanly.

### P2. **Structured `temporal_anchor_unix` field never populated** (T5)

The extraction model isn't emitting the new `valid_at` JSON field from today's prompt change — `memory_edges.temporal_anchor_unix` is NULL for all 4 facts even though the conversation had an explicit date. The date IS in the `fact` text (so recall works at the user-visible layer), but time-ordered queries (e.g., "facts between X and Y") have nothing structured to sort on.

**Fix:** add a 1-2 shot example to the extraction prompt showing the `valid_at` field populated (the model needs the example to reliably emit it). Or post-parse the `fact` text for date phrases and back-fill the anchor. Not a v1 blocker; LoCoMo Cat-2 (temporal) numbers improve when this lands.

### P3. **`.env` is not auto-loaded by the binary**

Same root finding as the P4 saga. If the operator sets a feature flag (`NULLALIS_ENABLE_MULTIAGENT`, `NULLALIS_TIER_GATE_MIN_SCORE`, anything else env-gated) in `.env` and runs the binary, it has **no effect** — env-var reads via `std.posix.getenv` only see what the *parent shell* exported. Either:
- (a) auto-load `.env` at startup (one-time, log loaded keys), or
- (b) document loudly that `.env` is shell-time only (and stop using it as the calibration mechanism in our own code comments).

**Fix:** either is fine; (a) matches operator expectations from the Node/Python ecosystems.

---

## What works (ship-confident)

- **Cross-session memory** is the v1 differentiator and it works end-to-end. User stores a fact in session A, asks in cold session B (same user), gets the right answer. This is the thing customers pay for.
- **Temporal recall (text-layer)** — the agent answers "when" questions correctly because the date is captured in the `fact` text per the prompt rule. The structured anchor is the polish; the user-visible behaviour is correct.
- **`recall.metrics`** firing every turn — P5 trace events confirmed live. P1 entity-overlap + P2 PPR in the recall pipeline.
- **Agent honesty** — when a tool breaks (shell) or is missing (delegate), the agent reports it accurately rather than fabricating. §14.6/§14.9 are real, not aspirational.
- **First-line streaming hygiene** — today's fix prevents the `<tool_call>` leak on the dominant case (pure tool-call responses).
- **memory_store / memory_recall** tool path works cleanly. 8 stores, 2 recalls, 0 errors.

## What we couldn't verify (gaps in this QA)

- **Pass C extraction in a long conversation** — short single-turn sessions never triggered compaction; the long-conversation extraction path (which is where the `valid_at` field matters most) wasn't exercised.
- **Approval flow** — supervised/auto mode prompts weren't probed; needs a `read_only` vs `mutating` tool sequence in a multi-turn session.
- **Real subagent spawn + return** — blocked on B1.
- **Channel integrations** (Email, Teams, Slack, Discord, Telegram) — out of scope for this QA, covered by Sprint 2 verification.

---

## Recommended Sprint 4 scope (synthesized)

| Priority | Item | Source |
|---|---|---|
| 1 | **B1: flip `NULLALIS_ENABLE_MULTIAGENT` default → on** (expose `delegate` + `spawn`) | T6 |
| 2 | **B2: fix shell sandbox empty-volume bug** | T2 |
| 3 | **P3: `.env` auto-load OR loud doc that it's shell-only** | recurring pattern (P4, B1) |
| 4 | UI/UX activation per ROADMAP v1.16 (the original Sprint 4 scope) — autonomy toggle, AskUserQuestion renderer, mode toggle UI, brain-graph entity styling, memory inspector | ROADMAP |
| 5 | **P1: widen XML leak guard to mid-stream** | T6 |
| 6 | **P2: structured `valid_at` extraction (one-shot example)** | T5 |
| 7 | Multi-turn long-conversation smoke (verify Pass C + the `valid_at` polish under real load) | gap |
| 8 | Approval-flow smoke (supervised vs auto, multi-tool sequence) | gap |

**B1 + B2 are commercial v1 prerequisites.** Without B1, the agent can't delegate — the *"agent spawns subagents and gets work back safely"* criterion Nova set is unmet. Without B2, code/file work breaks immediately.

**P1/P2/P3** are quality items — fix before v1 if calendar allows; otherwise file as D52-D54 with explicit operator-facing impact notes.

**Items 4-8** are the original Sprint 4 scope + the gaps this QA can't close on its own.

---

## Driver + raw outputs

- Driver: `/tmp/qa_driver.py` (preserved for re-runs; uses the bench harness's SSE protocol)
- Run log: `/tmp/qa_run.log` (118 lines, all 8 tests + the inspections)
- Gateway log: `/tmp/qa_gateway.log` (the full telemetry)
- Tenant after run: `user_id=2005` carries the 4 semantic edges + autosaves; re-runnable after `DELETE FROM zaki_bot.memories WHERE user_id=2005`

Re-runnable any time. Recommend adding a `scripts/qa_smoke.sh` wrapper for the Sprint-4 CI gate.
