---
tags: [prose, prose/planning, prose/agent-E]
authored: 2026-05-20
author: Agent E (Claude Opus 4.7)
binds_to: AGENTS.md §14 + docs/MULTI_AGENT_PLAN.md + docs/ROADMAP.md v1.14.18
status: PHASE 0 — TRAJECTORY FOR REVIEW (no production code until Nova approves)
baseline_sha: bd86f217 (origin/main at worktree creation)
---

# Agent E — v1.14.18-A Phase 0 Plan

> **For agentic workers:** This is a **Phase 0 trajectory document**, not yet an
> executable task list. Per the dispatch: "Nova reviews trajectory before any
> production code." Sections 4–9 become the executable plan only after the
> §3 blockers are resolved. Steps use `- [ ]` checkboxes for later tracking.

**Goal:** Land v1.14.18-A — three audit findings (MODE-UNIFICATION, TOOL-DESC-AUDIT,
GOAL-LOOP + procedural-memory activation) — as 6 atomic commits (3 code + 3 ledger),
gated by one bench run, at AGENTS.md §14 Swiss-watch standard.

**Architecture:** Finding 1 collapses the `AssistantModePresetConfig` machinery and
promotes `reasoning_effort` to the single user-facing depth knob. Finding 2 is a
description-only audit of 51 agent tools plus a cross-session TODO convention.
Finding 3 wires a ReAct-style goal/reflection loop into `turnOutcome`, fixes the
procedural-memory capture gate to be session-wide, and feeds goal-status into
`outcome_quality` — activating the Layer 6 `skill_executions` table that is
currently never written.

**Tech Stack:** Zig 0.15.2; postgres-backed `zaki_state.Manager`; existing observer
vtable, hooks, and prompt-builder infrastructure.

---

## 0. How to read this

This plan deliberately leads with **§3 — Blockers & Open Questions**. Recon
surfaced several issues that must be resolved before code work: one hard hot-file
lock, one self-contradiction inside the dispatch, and one tool-surface conflict.
Findings 4–9 are written assuming §3 is resolved in the recommended direction;
where a finding depends on a §3 answer, it is marked **[gated on Qn]**.

Line numbers are cited at baseline `bd86f217`. They will shift if PR #78
(v1.14.14 ContextEngine migration) merges first — see Q1.

---

## 1. Dispatch scope

**Three findings, this sub-block only. The rest of v1.14.18 (ROADMAP steps 1–10:
QMD / Composio / CLI / sweeps / V4 / V6 / V7 / B8) stays parked.**

| # | Finding | Code commit | Ledger commit |
|---|---------|-------------|---------------|
| 1 | MODE-UNIFICATION | `refactor(config):` | `docs(audit):` close MODE-UNIFICATION + R-effort-override |
| 2 | TOOL-DESC-AUDIT + TODO convention | `docs(tools):` | `docs(audit):` close TOOL-DESC-AUDIT |
| 3 | GOAL-LOOP + PROCEDURAL-ACTIVATION | `feat(agent):` | `docs(audit):` close F-A2.1 (obsolete) + capture-gate |

Plus **commit 0** = this plan file. Total: 7 commits. Split-commit pattern
(§4.8) mandatory — Agent E violated it twice on v1.14.13; not again.

---

## 2. Reconnaissance summary (§14.1 "Recon" — done before any code)

Mandatory reading completed at `bd86f217`:

| # | Item | Key takeaway |
|---|------|--------------|
| 1 | AGENTS.md §14 | §14.1 one-commit-per-finding; §14.2 archaeology; §14.5 completion contract; **§14.6 honest config**; **§14.7 honest prompts (bench-validate or strip)**; §14.9 reputation contract |
| 2 | MULTI_AGENT_PLAN §3.0, §4.8 | worktree-per-agent (done); **§4.8 split-commit, never amend, never one commit** |
| 3 | deferred-register.md | `R-effort-override` (Strategic, open) + `F-A2.1` (v1.14.13, open) confirmed present |
| 4 | ROADMAP v1.14.18 | block = steps 1–10; **no sub-block A exists** — see Q5 |
| 5 | learning.zig (full) | user-correction → behavioral facts. **Distinct from procedural memory** — GOAL-LOOP does not duplicate it |
| 6 | procedural_memory.zig (full) | `captureSession` / `loadForRender` / `renderBlock`; `CAPTURE_TOOL_THRESHOLD=5`; heuristic `oq` |
| 7 | commands.zig:1535–1591 | capture gate; runs at **session-end** inside `persistSessionSemanticSummary`; uses `last_turn_tool_count`; `empty_names` TODO |
| 8 | prompt.zig:764 + Response Protocol | Layer 6 line @764; `buildResponseProtocolSection` @773 (extends past 821) |
| 9 | root.zig:3024–3037 + turn_start | ambient `renderBlock` injection; `turn_start` ObserverEvent @2786; turn-end @4199 |
| 10 | zaki_state.zig DDL/insert/list | `skill_executions` table; no `goal_status` column (status maps to `outcome_quality` float); non-postgres **stub is a no-op** |
| 11 | ReAct / Reflexion / Voyager | design grounded below; nullalis stores TRACE-as-skill (Reflexion-shaped) |

Additional recon: 51 tools inventoried (Explore sweep); MODE-UNIFICATION config
surface mapped across 5 files; git log + audit ledger checked for hot-file locks.

---

## 3. 🔴 BLOCKERS & OPEN QUESTIONS FOR NOVA

**Q1 — root.zig is under Agent G's SOLO-LOCK (HARD BLOCKER for Finding 3).**
`docs/audits/2026-05-19-file-by-file-audit-ledger.md` row `CONTEXT-ENGINE` is
**OPEN** (v1.14.14, owner G). PR #78 (agent/G-v1.14.14, ContextEngine migration)
is open and carries a STUCK marker. MULTI_AGENT_PLAN §4.2: "the block heading
states the lock explicitly; no other agent edits the locked file during that
block." Finding 3 edits `src/agent/root.zig` in ≥4 places (new Agent field
~622, defer-accumulate ~2737, `<prior_attempts>` injection ~2786+, share the
`loadForRender` near 3024). Additionally, PR #78 restructures `turnOutcome`
into a 4-phase ContextEngine — **every line number Finding 3 depends on goes
stale and may merge-conflict** once #78 lands.
→ **Need a decision:** (a) G's lock released / #78 frozen → I claim
`[OWNS root.zig until <date>]` per §4.2; or (b) Finding 3's root.zig edits
rebase onto post-#78 root.zig (sequence Finding 3 last, after #78 merges); or
(c) explicit lock-override from Nova. **I will not edit a §4.2-locked hot file
without this.** Findings 1 & 2 do not touch root.zig and can proceed regardless.

**Q2 — the dispatch contradicts itself on the session-counter reset boundary.**
The `session_total_tool_count` field comment says *"Reset at session_start"*;
the instruction below it says *"Reset in turn-start observer (root.zig:turn_start)."*
These are not the same. The capture gate runs at **session-end**
(commands.zig ~1576). If the counter is reset every `turn_start`, then at
session-end it holds only the last turn's count — **identical to the
`last_turn_tool_count` bug this finding exists to fix.** Phase 0 design
(see §6.3) resets at **session-end (post-capture) + `clearSessionState`**, never
at turn_start. → Confirm this correction is accepted.

**Q3 — a `todo` tool already exists; Finding 2's TODO text would lie about it.**
Finding 2 asks to append to `memory_store`/`memory_recall` descriptions:
*"…No separate todo tool is needed."* But `src/tools/todo.zig:75` **is** a
registered tool (409-char description), and `prompt.zig:821` actively instructs
the agent to call `todo create` for 3+ task requests. Shipping "no separate todo
tool is needed" is a §14.6 honest-surface violation. → Phase 0 **adopts** the
useful part (cross-session durable TODO memory) and **strikes** the false
sentence; reworded text in §5.3. Confirm.

**Q4 — there is no audit-ledger row for any of the three findings.**
`grep MODE-UNIFICATION|TOOL-DESC-AUDIT|GOAL-LOOP docs/` → nothing. The only
ledger is `docs/audits/2026-05-19-file-by-file-audit-ledger.md`. The dispatch's
"close X ledger row" commits assume rows exist. → Phase 0 plan: each ledger
commit **adds the row and closes it** (`CLOSED <sha>`) in that file. §4.8 is
still satisfied (code SHA exists before the ledger commit). Confirm this is the
right ledger (vs. a new `2026-05-20-v11418A` file).

**Q5 — ROADMAP v1.14.18 has no "sub-block A".** The published block is steps
1–10 (QMD/Composio/CLI/…/B8). MODE-UNIFICATION / TOOL-DESC-AUDIT / GOAL-LOOP are
not in it. §4.1 makes ROADMAP the global lock; §14.5(6) requires ROADMAP to
reflect the operating surface. → Recommend: add a **"Sub-block A"** addendum +
`→ IN FLIGHT (agent E; sub-block A)` marker to the v1.14.18 heading as an early
task. Confirm (and confirm whether this is bundled into commit 1b or its own
`chore(roadmap): claim` commit).

**Q6 — `GoalState` mixes turn-scoped and session-scoped lifetimes.** The dispatch's
struct carries `goal_text` / `progress_notes` / `status` (turn-scoped — the goal
is the current user message) **and** `tool_call_sequence` / `iteration_count`
("capture tools…at session end" — session-scoped). A per-turn `GoalState` cannot
supply a session-wide tool list at session-end. → Phase 0 recommends: keep
`GoalState` strictly turn-scoped; hold session-wide accumulators
(`session_total_tool_count`, `session_tool_names`) as **Agent fields**; the Agent
also holds `active_goal_state: ?GoalState` so the capture gate reads
`gs.status`. Detail in §6.1/§6.3. Confirm the split.

**Q7 — Findings 1 & 2 were abbreviated ("[unchanged from prior draft]").**
Phase 0 reconstructed Finding 1 from the code + the inline bullets (it is
plannable — see §4). Two scope notes need a Nova ruling: (a) deleting
`AssistantModePresetConfig` also drops per-mode `temperature` (0.5/0.7/0.8),
`queue_cap` (8/12/20), and summarizer windows (3000/5000/8000) — a real behavior
change to confirm under §14.3; (b) Finding 1 lightly touches `src/gateway.zig`
(settings schema), a §4.2 **hot file** — confirm no Agent H gateway activity this
window. If the prior draft carried extra constraints, please paste them.

**Q8 — `sprint/v1.14.18` branch does not exist.** Per §3 PR convention,
agent branches PR into `sprint/v{block}`. Who creates `sprint/v1.14.18` —
Nova, or this agent on first push?

**Q9 — §14.7 exposure on the GOAL-LOOP prompt section.** The new "Goal Pursuit
Protocol" is a large directive block. F-A2 was *stripped* under §14.7 for being
bench-ignored. The dispatch's bench gate proves *capture* fires (row count) but
not that the model *acts on* the reflection / `<prior_attempts>` directives.
→ Phase 0 adds a behavior signal to the bench (§8). Confirm.

**Resolved (no question) —** the dispatch's "default 25→500" =
`AgentConfig.max_tool_iterations` (`config_types.zig:398`, currently `= 25`).
`config.zig:1533` confirms the preset/base relationship. No ambiguity remains.

---

## 4. Finding 1 — MODE-UNIFICATION  [Findings 1–2 can start independent of Q1]

**Intent:** the three modes already share one model (`moonshotai/Kimi-K2.6`) and
one provider (`together`); they meaningfully differ only by `reasoning_effort`.
Collapse the preset machinery and make `reasoning_effort` the single knob, with
**user override winning over the mode-derived value** (this is exactly the
`R-effort-override` deferred item: today `applySettingsToConfig` unconditionally
overwrites `cfg.reasoning_effort`).

### 4.1 Surface map (verified @ bd86f217)

| File | Lines | Action |
|------|-------|--------|
| `src/config_types.zig` | 204–228 `AssistantModePresetAgentConfig` | delete |
| `src/config_types.zig` | 230–235 `AssistantModePresetSummarizerConfig` | delete |
| `src/config_types.zig` | 237–240 `AssistantModePresetConfig` | delete |
| `src/config_types.zig` | 242–379 `ProductPresetsConfig` (fast/balanced/deep) | delete |
| `src/config_types.zig` | 398 `AgentConfig.max_tool_iterations: u32 = 25` | **→ `= 500`** |
| `src/config.zig` | 24–26 re-exports of the three preset types | delete |
| `src/config.zig` | 106 `reasoning_effort: ?[]const u8 = null` | **keep — promoted knob** |
| `src/config.zig` | 121 `product_presets: ProductPresetsConfig = .{}` | delete field |
| `src/config.zig` | 1533 stale comment `(8/25/500)` | correct |
| `src/config_parse.zig` | 23–~50 `parseAssistantModePresetConfig` | delete |
| `src/config_parse.zig` | 778/781/784 calls (`product_presets.*`) | delete |
| `src/config_parse.zig` | 401–408 `reasoning_effort` parse | keep + extend |
| `src/user_settings.zig` | 456–458 `if (preset.agent.reasoning_effort)…cfg.reasoning_effort = effort` | **the R-effort-override bug — invert precedence** |
| `src/user_settings.zig` | 401–467 `applySettingsToConfig` body | rework (no preset lookup) |
| `src/user_settings.zig` | `presetForMode` (~615–630, returns deleted type) | delete/rewrite |
| `src/gateway.zig` | 4229 settings-schema `assistant_mode` enum | keep (legacy FE alias) — **hot file, see Q7** |

`AssistantMode` enum + `ProductSettings.assistant_mode` (user_settings.zig:9–28,
49) **stay** — `assistant_mode` becomes a legacy front-end alias that maps to
`reasoning_effort` at parse/apply time (fast→low, balanced→medium, deep→high).

### 4.2 Behavior contract

- New precedence: user-set `cfg.reasoning_effort` (explicit, non-null from
  config.json) **wins**; otherwise it is derived from `assistant_mode`. This
  closes `R-effort-override`.
- `max_tool_iterations`: base default 25→500 (no per-mode presets to supply
  100/200/1000 anymore). Adaptive exits (`loop_detected`, repeated-call detector)
  remain the real guardrail — confirmed in `turnOutcome`.
- **Behavior delta to confirm (Q7a):** temperature, queue caps, and summarizer
  windows fall back to base `Config`/`MemoryConfig` defaults. §14.3 bench gate
  must show no LoCoMo/τ-bench regression.

### 4.3 Tasks (outline — TDD-expanded after review)

- [ ] Add `Sub-block A` marker to ROADMAP v1.14.18 [gated on Q5]
- [ ] Delete preset types + `product_presets` field + parser + calls
- [ ] `AgentConfig.max_tool_iterations` 25→500; correct the `config.zig:1533` comment
- [ ] Rewrite `applySettingsToConfig`: `assistant_mode`→`reasoning_effort` map; **user value wins**
- [ ] `config_parse.zig`: legacy `assistant_mode`/`product_presets` auto-map to `reasoning_effort`
- [ ] Tests: user-override-wins; legacy auto-map; default `max_tool_iterations`=500; reject unknown effort
- [ ] gateway settings schema verified (FE compat preserved) [coordinate per Q7b]
- [ ] Commit 1a `refactor(config):` → capture SHA → Commit 1b `docs(audit):`

---

## 5. Finding 2 — TOOL-DESC-AUDIT + TODO convention

**Mechanism:** descriptions are **scattered** — each `src/tools/<name>.zig`
declares its own `pub const tool_description`. No central registry. The audit
edits the individual files. **Constraint: descriptions only, zero behavior change.**

### 5.1 Tool inventory (51 found; dispatch expected 53 — see §5.4)

`✓` = current description already carries an explicit usage hint;
`~` = partial hint; `✗` = needs a `Use when:` clause added.

| Tool | File:line | Len | Hint |
|------|-----------|----:|:---:|
| brain_graph | brain_graph.zig:62 | 662 | ✓ |
| browser | browser.zig:21 | 38 | ✗ |
| browser_open | browser_open.zig:16 | 90 | ~ |
| calculator | calculator.zig:14 | 317 | ~ |
| compose_memory | compose_memory.zig:77 | 501 | ✓ |
| composio | composio.zig:48 | 242 | ✓ |
| context_snapshot | context_snapshot.zig:18 | 265 | ✓ |
| cron_add | cron_add.zig:38 | 170 | ~ |
| cron_list | cron_list.zig:37 | 102 | ~ |
| cron_remove | cron_remove.zig:38 | 67 | ✗ |
| cron_run | cron_run.zig:39 | 76 | ✗ |
| cron_runs | cron_runs.zig:37 | 96 | ~ |
| cron_update | cron_update.zig:38 | 101 | ~ |
| delegate | delegate.zig:31 | 68 | ✗ |
| file_append | file_append.zig:24 | 74 | ✗ |
| file_edit | file_edit.zig:19 | 31 | ✗ |
| file_edit_hashed | file_edit_hashed.zig:82 | 183 | ~ |
| file_read | file_read.zig:142 | 44 | ✗ |
| file_read_hashed | file_read_hashed.zig:36 | 214 | ~ |
| file_write | file_write.zig:16 | 41 | ✗ |
| git_operations | git.zig:22 | 92 | ✗ |
| http_request | http_request.zig:16 | 95 | ✓ |
| image_generate | image_generate.zig:83 | 581 | ✓ |
| image_info | image.zig:13 | 52 | ✗ |
| memory_archive | memory_archive.zig:50 | 398 | ✓ |
| memory_demote | memory_demote.zig:42 | 314 | ✓ |
| memory_edit | memory_edit.zig:15 | 82 | ~ |
| memory_forget | memory_forget.zig:16 | 71 | ~ |
| memory_list | memory_list.zig:21 | 111 | ~ |
| memory_maintain | memory_maintain.zig:97 | 120 | ~ |
| memory_purge_topic | memory_purge_topic.zig:42 | 334 | ✓ |
| memory_recall | memory_recall.zig:47 | 133 | ✗ **+ TODO convention** |
| memory_store | memory_store.zig:40 | 465 | ✓ **+ TODO convention** |
| memory_timeline | memory_timeline.zig:21 | 356 | ✓ |
| message | message.zig:24 | 160 | ~ |
| pushover | pushover.zig:17 | 98 | ✗ |
| runtime_info | runtime_info.zig:59 | 156 | ✓ |
| schedule | schedule.zig:728 | 264 | ✓ |
| screenshot | screenshot.zig:15 | 141 | ~ |
| set_execution_mode | set_execution_mode.zig:15 | 141 | ~ |
| shell | shell.zig:43 | 79 | ~ |
| spawn | spawn.zig:18 | 92 | ✓ |
| task_get | task_get.zig:16 | 114 | ~ |
| task_list | task_list.zig:17 | 133 | ~ |
| task_stop | task_stop.zig:15 | 131 | ~ |
| time_now | time_now.zig:27 | 282 | ✓ |
| todo | todo.zig:75 | 409 | ✓ |
| transcript_read | transcript_read.zig:30 | 443 | ✓ |
| web_fetch | web_fetch.zig:22 | 100 | ✓ |
| web_search | web_search.zig:65 | 120 | ✓ |
| wiki_link | wiki_link.zig:68 | 599 | ~ |

Audit target: every `✗`/`~` row gets an explicit `Use when:` clause; `✓` rows
verified for goal-aware phrasing. Behavior, params, and dispatch logic untouched.

### 5.2 The `Use when:` pattern

Append/normalise a single sentence so the model routes on *goal shape*, e.g.
`file_read` → "… **Use when:** the user names a file to read or summarise." Keep
the dispatch's existing routing table in `prompt.zig` Response Protocol as the
source of truth; the per-tool clause mirrors it so the model sees the cue at the
tool catalog level too.

### 5.3 TODO convention — reworded to remove the §14.6 violation (Q3)

Append to **memory_store** and **memory_recall** descriptions:

> "Multi-turn task tracking — to remember a pending task **across sessions**, use
> `memory_store(predicate=TODO, attribute=todo, object=<task>)`; to check pending
> work at session start, `memory_recall(filter={attribute:todo, status:open})`.
> This is the durable cross-session task layer. (For *within-session* multi-step
> task tracking, the `todo` tool remains the right surface.)"

**Struck from the dispatch text:** *"The agent's TODO list IS the memory layer …
No separate todo tool is needed."* — false: `src/tools/todo.zig` exists and
`prompt.zig:821` recommends it. The reworded version states the real division of
labor: `todo` = in-session; `memory_store(TODO)` = cross-session.

### 5.4 The 51-vs-53 gap

Dispatch expected 53. 51 statically-defined `tool_description` constants found.
Likely the two missing are conditionally-compiled or MCP/dynamic tools without a
static description constant. Non-blocking; to reconcile at code-time (a
`grep -rl tool_description src/tools` count check) and noted in commit 2b.

### 5.5 Tasks

- [ ] Per-tool `Use when:` pass across the `✗`/`~` rows (51 files; behavior frozen)
- [ ] memory_store / memory_recall: append reworded TODO convention (§5.3)
- [ ] Reconcile 51-vs-53; document in commit body
- [ ] Verify `zig build` (no behavior/param edits → no test churn expected; run full suite anyway)
- [ ] Commit 2a `docs(tools):` → capture SHA → Commit 2b `docs(audit):`

---

## 6. Finding 3 — GOAL-LOOP + PROCEDURAL-ACTIVATION  [gated on Q1, Q2, Q6]

The substantive change. One code commit + one ledger commit. Sub-parts 3a–3f.

### 6.1 New module `src/agent/goal_loop.zig` (~150 LoC)

```
pub const GoalStatus = enum { in_progress, met, stuck, max_iterations };

// TURN-scoped (Q6 recommendation). Lifetime = one turnOutcome call.
pub const GoalState = struct {
    goal_text: []const u8,                          // = user_message
    progress_notes: ArrayListUnmanaged([]const u8),
    no_progress_count: u32,
    iteration_count: u32,
    status: GoalStatus,
};

pub fn extractGoal(allocator, user_message) ![]const u8;        // verbatim copy
pub fn buildReflectionPrompt(allocator, goal, iteration, last_tool, last_result_summary) ![]const u8;
pub fn parseReflection(reflection_text) GoalStatus;
pub fn buildSkillTraceContext(allocator, traces: []const SkillExecution, goal_text) ![]const u8;
```

`tool_call_sequence` is **removed from `GoalState`** and lives on the Agent as
`session_tool_names` (§6.3) — the dispatch placed it in a turn-scoped struct but
it is consumed at session-end (Q6). Import DAG: `procedural_memory.zig` →
`goal_loop.zig` → `memory/root.zig` (for `SkillExecution`). `goal_loop.zig` does
**not** import `procedural_memory.zig` → **no import cycle.**

### 6.2 Reflection: parsing strategy, latency, context (dispatch's required design specifics)

**Parsing strategy — structured tags, model-emitted, no sidecar.** The model
emits, as part of its *normal iteration generation* (ReAct: reasoning interleaved
with action — **no extra round-trip**):

```
<reflection iteration="N" tool="last_tool_name" goal_status="in_progress">
What I learned: …
Goal progress: closer | same | further
Next action: <tool_name … | finalize>
</reflection>
```

`parseReflection` does tolerant attribute extraction: find `goal_status="`, read
to the next `"`, map to `GoalStatus`; **if absent → default `.in_progress`**
(failure-soft — never falsely declare met/stuck, never crash).

- *Rejected — sidecar LLM:* a second call per iteration doubles latency/cost and
  adds a failure mode — a §14.3 latency-gate risk. No.
- *Rejected — regex on free text:* brittle.
- *Chosen — structured tags:* matches the codebase's existing fenced-block
  convention (`<recent_skill_traces>`, `<working_memory>`, `<task_plan>`);
  operator-greppable; deterministic; zero extra calls.

**Latency budget per iteration:** zero extra round-trips → **zero TTFT impact**
(p95 ≤ 4.0s gate unaffected). Cost is tokens only: ~150–250 prompt tokens
(`buildReflectionPrompt` elicitation appended to the iteration context) +
~60–120 completion tokens (the emitted block).

**Context-length impact:** bounded. Inject only the **most-recent** reflection
between iterations ("showing your last reflection") → O(1), not O(iterations).
`<prior_attempts>` at turn-start = 3 traces, compact. Net ≈ 200–1000 tokens.

### 6.3 Session-wide tool count — design (corrects the dispatch, Q2)

`turnOutcome` calls per **turn**; capture fires at **session-end**
(`commands.zig` ~1576, inside `persistSessionSemanticSummary`). The Agent is
long-lived and **does not own `memory_session_id`** (commands.zig:2621 — the
SessionManager swaps it). Therefore:

**New Agent fields** (root.zig, immediately after `last_turn_tool_count` @622 —
`last_turn_tool_count` is *kept*, it still feeds `skills_nudge` at root.zig:12089):
```
/// v1.14.18-A — session-wide tool count for the procedural-memory capture gate.
/// Accumulates across ALL turns of a session; read + reset at session-end.
/// Replaces the last_turn-only signal that left skill_executions empty.
session_total_tool_count: u32 = 0,
/// v1.14.18-A — session-wide tool-name manifest for the capture trace.
session_tool_names: std.ArrayListUnmanaged([]const u8) = .empty,
```

**Increment — deviation from the dispatch, with rationale.** The dispatch says
"increment after each successful tool dispatch in the dispatch loop." Phase 0
recommends instead a single **`defer` at `turnOutcome` scope** (~root.zig:2737,
right after `turn_tool_calls_total` is declared @2736):
```
defer self.session_total_tool_count +%= turn_tool_calls_total;
```
Rationale: a `defer` fires on **every** exit path (normal, error, early return) —
guaranteed once per turn; one site; no churn inside `executeToolCallsSerial`
*and* `executeToolCallsParallel`. This is the §14.1 "minimal surgical edit."
`session_tool_names` is appended where per-call names are already known (the
serial/parallel dispatch sites) — the one place the inner loop is touched.

**Reset — NOT at turn_start (Q2).** Reset where it is correct:
1. **Primary** — immediately after the capture gate in `commands.zig` (after
   line 1591), unconditionally: count accumulates → session-end fires capture →
   reset → next session on the same Agent starts clean.
2. `clearSessionState` (commands.zig:1798) — covers `/new` and `/restart`.
3. Struct default `= 0` — covers Agent construction (first session).

**"What if an observer event is missed?"** — N/A by construction. The counter is
**not** tied to observer events. `turn_start` `ObserverEvent`s route through
swappable wrappers (`NarrationObserver`, root.zig:2702) and are telemetry, not
control flow. The counter uses direct field manipulation at deterministic code
points. No observer dependency → no missed-event failure mode. (This is *why*
the dispatch's "turn-start observer" instruction is rejected.)

### 6.4 `procedural_memory` extension contract (3b — dispatch's required specifics)

`captureSession` gains an 8th parameter; **signature change is backward-compatible**:
```
pub fn captureSession(allocator, state_mgr, user_id, session_id,
    task_summary, tool_call_names, total_tool_calls,
    goal_status: ?goal_loop.GoalStatus) ?i64
```
`oq` becomes:
```
const oq: f64 = if (goal_status) |gs| switch (gs) {
    .met => 0.9, .stuck => 0.3, .max_iterations => 0.4, .in_progress => 0.5,
} else std.math.clamp(@as(f64,@floatFromInt(total_tool_calls))/20.0, 0.5, 0.85);
```
**Backward compat:** any caller passing `null` keeps the existing heuristic — no
forced migration. **No DDL change** — `goal_status` is consumed to produce the
`outcome_quality` *float*; the `skill_executions` schema (no `goal_status`
column) is untouched. `procedural_memory.zig` adds `@import("goal_loop.zig")`
for the `GoalStatus` type only.

**`buildSkillTraceContext` vs `renderBlock` composition:** both consume
`RenderSet.traces` from one `loadForRender` call. `renderBlock` →
ambient `<recent_skill_traces>` (root.zig:3024–3037, unchanged). `buildSkillTraceContext`
→ goal-anchored `<prior_attempts goal_shape=… count=N>` injected as a system
message at turn-start. **Optimization:** hoist a single `loadForRender` per turn
and feed both formatters — avoids a duplicate postgres query. (Dispatch had them
separate; noted as a refinement.)

### 6.5 Wiring (3c/3d/3e) — all in `src/agent/` [gated on Q1]

- **3c** capture gate (commands.zig:1576–1591): read `session_total_tool_count`;
  `tool_call_names = self.session_tool_names.items`; pass
  `if (self.active_goal_state) |gs| gs.status else null`.
- **3d** `<prior_attempts>` at turn-start: after `extractGoal`, `loadForRender` →
  `buildSkillTraceContext` → inject as a system message before the first model
  call. `active_goal_state` set on the Agent here.
- **3e** prompt.zig: new `buildGoalPursuitProtocolSection`, called **after**
  `buildResponseProtocolSection` (note: the dispatch's "~line 800" is stale —
  the Response Protocol body extends past line 821; exact insertion point
  confirmed at code-time). Update the Layer 6 line @764 to describe session-wide
  capture + `<prior_attempts>`.
  - **§14.7 risk (Q9):** must be bench-proven engaged — see §8. Avoid duplicating
    the existing "Tool routing" / "Memory is retrieval, not truth" content.

### 6.6 Tests (3f)

- `goal_loop.zig` inline: `extractGoal` verbatim; `GoalState.no_progress_count`
  tracking; `parseReflection` met/stuck/in_progress; `buildReflectionPrompt`
  includes goal+iteration+last_tool+result-summary; `buildSkillTraceContext` format.
- `procedural_memory.zig` (extend): `captureSession` goal_status `.met`→0.9,
  `.stuck`→0.3, `null`→heuristic (backward-compat).
- `commands.zig`: `session_total_tool_count` increments; resets at session-end;
  capture fires at ≥5 even when `last_turn_tool_count`==0.
- **Integration:** `tests/agent/goal_loop_integration_test.zig` — **`tests/agent/`
  does not exist.** New directory **and** a `build.zig` test-target registration
  are required (mirror the existing satellite test binaries from B13). Covers:
  3-iteration turn → 1 reflection/iteration; stuck verdict → `force_final_response`;
  met verdict → loop exit; 6-tool session → `captureSession` with goal-status.

### 6.7 Tasks

- [ ] **[Q1]** Confirm root.zig lock status; claim `[OWNS root.zig]` or rebase plan
- [ ] Create `src/agent/goal_loop.zig` + inline tests (TDD)
- [ ] `procedural_memory.captureSession` 8th param + `oq` switch + tests
- [ ] Agent fields + defer-accumulate + 3-point reset
- [ ] Capture-gate rewrite (commands.zig) + tests
- [ ] `<prior_attempts>` injection + shared `loadForRender`
- [ ] prompt.zig Goal Pursuit Protocol section + Layer 6 line update
- [ ] `tests/agent/` dir + build.zig wiring + integration test
- [ ] Commit 3a `feat(agent):` → capture SHA → Commit 3b `docs(audit):` + obsolete F-A2.1

---

## 7. Commit plan (§4.8 — split, never amend, never one commit)

```
commit 0  docs(planning): Agent E v1.14.18-A Phase 0 plan
commit 1a refactor(config): MODE-UNIFICATION …
          SHA1=$(git rev-parse HEAD)
commit 1b docs(audit): add+close MODE-UNIFICATION row + close R-effort-override at $SHA1
commit 2a docs(tools): TOOL-DESC-AUDIT — Use-when pass + cross-session TODO convention
          SHA2=$(git rev-parse HEAD)
commit 2b docs(audit): add+close TOOL-DESC-AUDIT row at $SHA2
commit 3a feat(agent): GOAL-LOOP + procedural memory activation …
          SHA3=$(git rev-parse HEAD)
commit 3b docs(audit): add+close GOAL-LOOP row + obsolete F-A2.1 (superseded) at $SHA3
```

Every body carries `[agent=E track=audit-sweep block=v1.14.18-A]` (§4.3). Ledger
commits touch only `docs/audits/…` (+ `deferred-register.md` for 1b/3b). 1b flips
`R-effort-override` → `shipped at $SHA1`; 3b flips `F-A2.1` →
`obsolete — superseded by GOAL-LOOP at $SHA3`. Deferred-register rows are never
deleted (the doc's own rule).

---

## 8. Bench gate (single, after all 3 findings)

- `zig build test --summary all` → 0 failures, 0 leaks.
- LoCoMo ≥ 0.78 **and** Cat 3 ≥ 0.50; V-infinity ≥ 0.72; τ-bench smoke ≥ 0.30.
- **p95 TTFT ≤ 4.0s** (§14.3 — load-bearing here: MODE-UNIFICATION changes
  defaults, GOAL-LOOP adds per-iteration tokens).
- **Capture proof:** `docker exec zaki-postgres psql -U zaki -d zaki -c "SELECT
  COUNT(*), AVG(outcome_quality) FROM zaki_bot.skill_executions WHERE created_at >
  NOW() - INTERVAL '30 minutes';"` → **≥ 10 rows AND AVG > 0.5**.
  - **Caveat:** meaningful only if the bench runs on the **postgres** backend.
    The non-postgres `zaki_state` stub (zaki_state.zig:672–680) makes
    insert/list no-ops → 0 rows always. Confirm `.spike` harness uses postgres.
    0 rows → STUCK (per dispatch: capture gate or session-end detection still broken).
- **§14.7 behavior signal (Phase 0 addition, Q9):** grep bench transcripts for
  emitted `<reflection>` blocks (> 0 ⇒ the Goal Pursuit Protocol is engaged) and
  measure the "5+ similar `memory_recall` calls then give up" anti-pattern rate
  vs. baseline. If reflections are absent ⇒ §14.7 says **strip** the prompt
  section, do not ship it "in hope."

---

## 9. Test plan summary

| Area | New/extended tests |
|------|--------------------|
| config | user-override-wins; legacy `assistant_mode` auto-map; `max_tool_iterations` default 500; reject unknown effort |
| tools | `zig build` green (descriptions only — no behavior tests change) |
| goal_loop.zig | extractGoal; no_progress_count; parseReflection ×3; buildReflectionPrompt; buildSkillTraceContext |
| procedural_memory.zig | captureSession goal_status met/stuck/null-heuristic |
| commands.zig | session counter increment / reset / capture-at-≥5 |
| tests/agent/ (new) | goal_loop integration: reflection/iteration, stuck, met, 6-tool capture |

---

## 10. Self-review (writing-plans skill)

- **Spec coverage:** all 3 findings + sub-parts 3a–3f mapped to §4/§5/§6 tasks;
  all 5 dispatch-mandated Phase-0 deliverables present (line ranges §4.1;
  51-tool table §5.1; GOAL-LOOP design specifics §6.2; session-counter design
  §6.3; procedural_memory contract §6.4).
- **Placeholders:** none — every file/line/signature is concrete or explicitly
  marked "confirm at code-time" with the reason.
- **Type consistency:** `GoalStatus`, `GoalState`, `captureSession` 8-arg
  signature, and `SkillExecution` field set are consistent across §6.1/§6.4/§6.6.
- **Gaps found & surfaced:** dispatch self-contradiction (Q2), pre-existing
  `todo` tool (Q3), missing ledger rows (Q4), missing ROADMAP sub-block (Q5),
  `GoalState` lifetime (Q6), missing `tests/agent/` dir (§6.6), root.zig lock
  (Q1) — all raised, not silently absorbed.

---

## 11. Sequencing & next action

1. **Now:** commit this plan (commit 0), push `agent/E-v1.14.18-A`, request
   Nova's trajectory review.
2. **Blocked on review:** §3 Q1–Q9. Findings 1 & 2 (no root.zig) may be
   greenlit independently of Q1; Finding 3 cannot start until Q1 is resolved.
3. **On greenlight:** expand §4/§5/§6 task outlines into TDD steps and execute
   per §7; one bench gate per §8; PR `agent/E-v1.14.18-A` → `sprint/v1.14.18`
   (Q8: branch creation).

**No production code is written until Nova approves this trajectory.**
