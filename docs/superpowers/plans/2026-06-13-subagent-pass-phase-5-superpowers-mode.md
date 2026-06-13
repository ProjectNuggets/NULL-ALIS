# Subagent Pass — Phase 5: Superpowers Mode (coordinator + gated fan-out) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a power-user "⚡ Superpowers" mode (the top of the chat reasoning toggle) that turns the parent agent into a **coordinator** — plan → dispatch parallel subagents (`spawn_many`, Phase 4) → review → synthesize → deliver — with transparent N× credit cost. It gates the Phase 4 fan-out ON (off for everyone else), shifts the agent persona via a **coordinator skill** that encodes the orchestration discipline, and (stretch) lets the agent author its own skills.

**Architecture:** The FE reasoning toggle gains a 4th value `superpowers`, which rides the existing `reasoning_effort` passthrough (FE → BFF → engine, zero transformation). The engine maps `reasoning_effort == "superpowers"` → `{ superpowers_mode = true, effective reasoning = high }`. When `superpowers_mode` is set on a turn: (a) the agent enters `ExecutionMode.coordinator` (a new variant) with a coordinator reflection prompt + a loaded `coordinator` SKILL that teaches plan/dispatch/review/synthesize/deliver; (b) the Phase-4 fan-out tools (`spawn_many`, `subagent_batch_result`) are exposed (they are OFF for all non-superpowers turns); (c) the BFF meters the turn at a top cost tier and the FE shows a "burns the most credits" tooltip.

**Tech Stack:** Engine (Zig): `gateway.zig` intake, `session.zig` threading, `agent/execution_mode.zig`, `agent/prompt.zig` + `agent/root.zig` reflection prompts, `tools/root.zig` tool gating, `skills/` (the coordinator SKILL). FE (Next/React): `zaki-prod-sa/src/app/components/InputArea.tsx`. BFF (Node): `zaki-prod-sa/backend/src/agent-metering.js`.

**Depends on:** Phase 4 (fan-out primitives) — `spawn_many` / barrier / `subagent_batch_result` must exist + be merged first. **Spec:** `/Users/nova/Desktop/zaki-infra/docs/saas-v1/SPEC-2026-06-13-subagent-pass.md` (this plan extends it; add a §3.5 "Superpowers mode" note to the spec as Task 0).

---

## Two deploy tracks (cross-stack)

- **Engine** (nullALIS, Tasks 1–5): branch off `origin/main` → PR → CI (green incl. linux+postgres) → merge → `sha-<commit>` image → bump `charts/nullalis/values-staging.yaml` `image.tag` → ArgoCD. (Same pipeline as Phases 1–4.)
- **FE + BFF** (zaki-prod-sa, Tasks 6–7): its own repo + deploy pipeline. The `reasoning_effort="superpowers"` value is **backward-compatible** — an engine without superpowers support just treats it as an unknown effort (maps to default). So the FE/BFF and engine can ship in either order, but **ship the engine first** so the toggle does something when it appears.

**Order:** Phase 4 merged → Engine (Tasks 1–5) → FE/BFF (Tasks 6–7) → verify end-to-end.

---

## Grounding facts (from recon — re-verify lines)

**Engine:**
- `ChatStreamTurnOptions { execution_mode, autonomy, reasoning_effort }` `gateway.zig:85`; parsed `gateway.zig:5906` (`parseChatStreamReasoningEffort` / `parseChatStreamTurnOptions`); threaded → `session.zig:267` `ProcessMessageOptions.turn_reasoning_effort` → applied `session.zig:1138` (`session.agent.reasoning_effort = effort`); `Agent.reasoning_effort` `agent/root.zig:607` (passed to `provider.chat`).
- `ExecutionMode { plan, execute, review, background }` `agent/execution_mode.zig:9`; `allowsTool(mode, meta)` `:35`; per-mode reflection prompts `agent/root.zig:2239–2275` (`getReflectionPrompt`).
- System prompt: `prompt.zig` `buildStableSystemPrompt:378` / `buildVolatileSystemPrompt:461`; `PromptContext`/`PromptSections:225–284`; persona `buildPersonaSection:169`.
- Tool gating: `tools/root.zig:1449–1458` — `spawn`/`delegate` gated by `opts.tool_profile == .main and multiagent_enabled`. `ToolProfile { main, subagent }` `:1771`. Tools chosen at agent/session init (not per-turn — see Task 3 note).
- Skills: `skills.zig` (`SkillManifest`, `listSkills`/`listSkillsMerged`); loaded into the prompt by `prompt.zig:1056` `appendSkillsSection` (`always:true` → inline; else lazy XML stub read via `read_file`). Location: `{workspace_dir}/skills/<name>/{skill.json, SKILL.md}` (per-tenant) + `~/.nullalis/skills/` (shared). `file_write` can author skills; `skill_registry` tool + `installSkillFromPath` exist.

**FE/BFF:**
- Toggle: `InputArea.tsx` — `ZakiTurnReasoningEffort = "low"|"medium"|"high"` (L98), `ZAKI_REASONING_ORDER` (L111), `ZAKI_REASONING_LABELS` (L125), state L353, button render L1737–1775. Sent as `reasoning_effort` (InputArea L813 → ChatArea L5810). BFF passthrough `backend/src/index.js:11174` (spread, unchanged).
- Metering: `backend/src/agent-metering.js` — `hasDeepMode()` L70–85 (matches `reasoning_effort` "high"/"deep" → `agent_deep_research`, baseUnits 3 at L123–140).

---

## Task 0 — Spec note + branch

- [ ] Add a short **§3.5 "Superpowers mode"** to `SPEC-2026-06-13-subagent-pass.md` (in zaki-infra): the toggle value, the coordinator persona, the gate, the credit tier, the coordinator skill. Commit in zaki-infra. (Keeps the spec the source of truth.)
- [ ] Engine work on a fresh branch off `origin/main` (after Phase 4 is merged): `git checkout -b saas-v1/superpowers-mode origin/main`.

---

## Task 1 — Engine: the `superpowers` signal intake

**Files:** Modify `src/gateway.zig` (ChatStreamTurnOptions + parse), `src/session.zig` (ProcessMessageOptions + apply), `src/agent/root.zig` (Agent flag). Test: inline.

- [ ] **Step 1: Failing test** — a unit on the mapping helper: `mapReasoningEffort("superpowers")` returns `.{ .superpowers = true, .effort = "high" }`; `mapReasoningEffort("high")` → `.{ .superpowers = false, .effort = "high" }`.

```zig
test "superpowers reasoning maps to coordinator + high effort" {
    const a = mapReasoningEffort("superpowers");
    try std.testing.expect(a.superpowers);
    try std.testing.expectEqualStrings("high", a.effort);
    const b = mapReasoningEffort("high");
    try std.testing.expect(!b.superpowers);
    try std.testing.expectEqualStrings("high", b.effort);
    const c = mapReasoningEffort("low");
    try std.testing.expect(!c.superpowers);
    try std.testing.expectEqualStrings("low", c.effort);
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement**
  - Add `fn mapReasoningEffort(raw: ?[]const u8) struct { superpowers: bool, effort: []const u8 }` (in gateway.zig near `parseChatStreamReasoningEffort`): if raw == "superpowers" → `.{ .superpowers = true, .effort = "high" }`; else → `.{ .superpowers = false, .effort = raw orelse "" }`. This keeps `reasoning_effort` provider-valid (provider never sees "superpowers") while activating the mode.
  - Add `superpowers_mode: bool = false` to `ChatStreamTurnOptions` (gateway.zig:85); in `parseChatStreamTurnOptions`, set both `reasoning_effort` and `superpowers_mode` via `mapReasoningEffort`.
  - Add `turn_superpowers_mode: bool = false` to `ProcessMessageOptions` (session.zig:267); thread the gateway value into it at the call site.
  - In `processMessageWithContext` (session.zig:1138 area), alongside `session.agent.reasoning_effort = effort`, set `session.agent.superpowers_mode = options.turn_superpowers_mode;` (restore on defer, mirroring reasoning_effort).
  - Add `superpowers_mode: bool = false` to the `Agent` struct (agent/root.zig:607 area).
- [ ] **Step 4: Run + build** → PASS / clean.
- [ ] **Step 5: Commit** `feat(superpowers): map reasoning_effort=superpowers → coordinator signal + high effort`.

---

## Task 2 — Engine: `.coordinator` ExecutionMode + reflection prompt + coordinator section

**Files:** Modify `src/agent/execution_mode.zig`, `src/agent/root.zig` (reflection prompt + select coordinator mode when superpowers), `src/agent/prompt.zig` (coordinator section). Test: inline.

- [ ] **Step 1: Failing test**
  - `ExecutionMode.coordinator` exists; `getReflectionPrompt(.coordinator)` returns the coordinator guidance (assert it contains "plan", "spawn_many", "synthesize").
  - `ExecutionMode.coordinator.allowsTool(meta)` returns true for read-only tools AND for the fan-out dispatch tools (a `coordinator_dispatch` metadata flag), false for direct mutating tools (so the coordinator delegates rather than does grunt work).

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement**
  - Add `.coordinator` to `ExecutionMode` (execution_mode.zig:9). In `allowsTool` (:35): `.coordinator => meta.flags.read_only or meta.flags.coordinator_dispatch` (add a `coordinator_dispatch` flag to ToolMetadata; set it on `spawn`, `spawn_many`, `delegate`, `subagent_batch_result`, `task_get`/`task_list`). This makes the coordinator a planner+dispatcher, not a doer.
  - Add `reflection_prompt_coordinator` (agent/root.zig:2275+) — the coordinator playbook (see the SKILL content in Task 4; the reflection prompt is the short in-turn version). Wire `getReflectionPrompt(.coordinator)`.
  - Select coordinator mode: where the turn's execution_mode is resolved (agent init / session threading), if `agent.superpowers_mode` is true and no explicit execution_mode override, set `execution_mode = .coordinator`. (Verify the resolution point; mirror how reasoning_effort is applied.)
  - Add `buildCoordinatorSection(w)` to prompt.zig + a `coordinator_mode: bool` on `PromptContext`; in `buildVolatileSystemPrompt`, emit the section when `ctx.coordinator_mode` (one concise paragraph pointing the model at the `coordinator` skill + the plan/dispatch/review/deliver loop). Set `ctx.coordinator_mode = agent.superpowers_mode` where PromptContext is built.
- [ ] **Step 4: Run + build** → PASS / clean. Run `-Dtest-filter="execution_mode"`/`"reflection"` + the broad agent tests for no regression.
- [ ] **Step 5: Commit** `feat(superpowers): .coordinator execution mode + reflection prompt + prompt section`.

---

## Task 3 — Engine: gate the fan-out tools to Superpowers turns

**Files:** Modify `src/tools/root.zig` (tool selection) + the agent/session tool wiring. Test: inline.

- [ ] **Step 1: Failing test** — `allTools(... .{ .superpowers = false ... })` does NOT include `spawn_many`/`subagent_batch_result`; with `.superpowers = true` it DOES. (And neither ever appears in the `.subagent` profile.)

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement**
  - Phase 4 registered `spawn_many`/`subagent_batch_result` behind an OFF-by-default flag. Here, replace that flag with the real gate: add a `superpowers: bool = false` field to the `allTools` opts; register `spawn_many` + `subagent_batch_result` only when `opts.tool_profile == .main and opts.superpowers` (mirror the `spawn`/`delegate` `multiagent_enabled` conditional at tools/root.zig:1449).
  - **Per-turn exposure:** tools are currently chosen at agent/session init, not per-turn. Two options — pick the one that fits the as-built wiring (verify):
    - (A) Rebuild/augment the tool set for the turn when `superpowers_mode` flips on (if the turn path can re-select tools). Preferred if cheap.
    - (B) If tools are fixed at init: register `spawn_many`/`subagent_batch_result` whenever multiagent is enabled, but have their `execute()` **refuse** with a clear message ("spawn_many is only available in ⚡ Superpowers mode") when `agent.superpowers_mode` is false. This is the robust fallback (the tool exists but self-gates), and combined with the `.coordinator` reflection prompt (which only mentions them in coordinator mode), regular turns won't call them. Implement (B) if (A) is invasive; document the choice.
- [ ] **Step 4: Run + build** → PASS / clean.
- [ ] **Step 5: Commit** `feat(superpowers): gate spawn_many/subagent_batch_result to Superpowers turns`.

---

## Task 4 — The `coordinator` SKILL (teach the orchestration discipline)

**Files:** Create the skill in the engine's shared skills location so every tenant gets it: `~/.nullalis/skills/coordinator/skill.json` + `SKILL.md`, OR (preferred for GitOps) embed it as an operator-provisioned skill the chart/image ships. Verify how shared skills are provisioned (image bake vs `~/.nullalis/skills`); pick the one that deploys via the existing pipeline. Test: a skills-loading test that the `coordinator` skill is discoverable.

- [ ] **Step 1: Failing test** — `listSkillsMerged` (or the prompt skills section) includes a skill named `coordinator` when the skill dir is present (mirror an existing skills test).

- [ ] **Step 2: Run → FAIL** (skill absent).

- [ ] **Step 3: Author the skill.** `skill.json`:

```json
{ "name": "coordinator", "version": "1.0.0",
  "description": "Superpowers coordinator: plan, dispatch parallel subagents, review, synthesize, deliver.",
  "author": "nullalis", "always": false }
```

`SKILL.md` (the orchestration discipline — this is the heart of the feature; encodes the proven pattern):

```markdown
# Coordinator (Superpowers mode)

You are the COORDINATOR. The user activated ⚡ Superpowers — they want your most
ambitious work, and they know it costs more. Your job is to orchestrate a fleet of
subagents, not to do the grunt work yourself.

## The loop: plan → dispatch → review → synthesize → deliver

1. **Understand & decompose.** Restate the goal in one line. Break it into the
   FEW genuinely independent workstreams that can run in parallel. If the work is
   actually sequential or tiny, say so and just do it — don't fan out for its own sake.

2. **Plan (out loud, briefly).** List the workstreams and what each subagent will do.
   This is your contract with the user; keep it tight.

3. **Dispatch with `spawn_many`.** One subagent per workstream, each with a FOCUSED,
   self-contained brief (it has no memory of this conversation — include everything it
   needs). Bound the fan-out (a handful, not dozens). Prefer one `spawn_many` call so
   they run together under one batch.

4. **Review each result.** When the batch returns, judge each result against its brief:
   correct? complete? Did any fail or time out? Don't trust blindly — if a result is
   thin or wrong, re-dispatch that one workstream with a sharper brief.

5. **Synthesize — don't dump.** Connect the findings into ONE coherent deliverable.
   Interpret and integrate; never paste raw subagent output back to the user. Surface
   failures/timeouts honestly ("3 of 4 done; the 4th timed out — here's what we have").

6. **Deliver.** Present the synthesized result. If you produced documents/artifacts,
   make them available.

## Principles
- You are the conductor. Plan, dispatch, review, synthesize — delegate the doing.
- Be transparent about cost: this mode burns the most credits; make the spend worth it.
- Bound the fan-out; a focused 3–5 beats an unfocused 20.
- Partial success is success: deliver survivors + name what failed.
```

- [ ] **Step 4** ensure it deploys (image-baked shared skill or provisioned to `~/.nullalis/skills`) + the test passes.
- [ ] **Step 5: Commit** `feat(superpowers): coordinator skill — the plan/dispatch/review/synthesize playbook`.

---

## Task 5 (stretch) — `skill_author` tool: let the agent create skills

**Files:** Create `src/tools/skill_author.zig`; register (main profile; available in coordinator mode). Test: inline.

- [ ] Build a `skill_author(name, description, instructions, always?)` tool that validates the name (safe slug), writes `{workspace_dir}/skills/<name>/skill.json` + `SKILL.md` via the same path-safe write `file_write` uses (or call `installSkillFromPath`), and returns confirmation. TDD: authoring a skill creates discoverable files; `listSkills` then finds it. This is the foundation for the "workflows on top" direction — the coordinator can mint reusable fan-out recipes. **Mark optional**: if it risks scope-creep, defer to a follow-up; Tasks 1–4 deliver Superpowers mode without it.
- [ ] **Commit** `feat(superpowers): skill_author tool — agent can create skills (stretch)`.

---

## Task 6 — FE: the ⚡ Superpowers toggle value + cost tooltip

**Files:** Modify `zaki-prod-sa/src/app/components/InputArea.tsx`. (FE repo, own pipeline.) Test: the FE's test setup (jest/RTL) if present; else a manual check.

- [ ] Extend `ZakiTurnReasoningEffort` (L98) to add `"superpowers"`; add it to `ZAKI_REASONING_ORDER` (L111, last) + `ZAKI_REASONING_LABELS` (L125, e.g. `superpowers: "⚡ Superpowers"`). The cycling button + send path then carry it automatically (it rides `reasoning_effort`).
- [ ] Add a **cost tooltip** on the reasoning chip (mirror the context-meter Tooltip at L1853–1919): show the per-mode note, with Superpowers = "⚡ multi-agent fan-out — burns the most credits, for your most ambitious work." (Transparency requirement.)
- [ ] Optional: a subtle `<Zap/>` glyph / accent when the chip is on `superpowers`.
- [ ] **Commit** (zaki-prod-sa) `feat(fe): ⚡ Superpowers reasoning mode + cost tooltip`.

---

## Task 7 — BFF: Superpowers metering tier

**Files:** Modify `zaki-prod-sa/backend/src/agent-metering.js`. Test: the BFF's test setup if present.

- [ ] Add a `hasSuperpowers(payload, message)` check (matches `reasoning_effort`/`mode` == "superpowers") and classify it as a NEW action `agent_superpowers` with a distinct, higher baseUnits than deep-research's 3 (e.g. **5** — confirm the desired ratio with the product owner; default 5). Insert ahead of the `hasDeepMode` branch in the classifier (L112–140) so superpowers wins. TDD: a payload with `reasoning_effort:"superpowers"` → `agent_superpowers` @ the higher unit cost; `"high"` still → `agent_deep_research` @ 3.
- [ ] **Commit** (zaki-prod-sa) `feat(bff): meter Superpowers turns at the top cost tier`.

---

## Build, Deploy & Verify

- [ ] **Engine:** `zig build test` green + `zig build` clean → holistic review (signal intake; coordinator gating doesn't leak fan-out to non-superpowers turns; the self-gate refusal message; skill loads; no Phase 1–4 regression) → PR → CI green (incl. linux+postgres) → merge → `sha-<commit>` → bump `values-staging.yaml` → ArgoCD roll → confirm config + `/ready`.
- [ ] **FE/BFF:** ship via the zaki-prod-sa pipeline (engine first).
- [ ] **Live verify (the real path):** in the UI, set the toggle to **⚡ Superpowers**, give an ambitious multi-part task. Confirm: (a) the agent PLANS + calls `spawn_many` (fan-out), (b) regular turns (toggle ≠ superpowers) do NOT have `spawn_many` (self-gate / not exposed), (c) the parent SYNTHESIZES the batch into one deliverable, (d) the turn meters at the Superpowers tier, (e) the cost tooltip shows. Test partial failure (one workstream fails) → survivors delivered.
- [ ] **Record** in `zaki-infra/staging/AGENT-SPOKE-RESULTS.md`; the subagent pass is then complete end-to-end (Phases 1–5): reliable returns → structured metadata → artifacts → fan-out primitives → Superpowers coordinator mode.

---

## Self-review

- **Coverage:** toggle→signal (Task 1, 6) ✓; coordinator persona = my orchestration discipline (Task 2 reflection prompt + Task 4 skill) ✓; gate fan-out to power-user (Task 3) ✓; credit transparency (Task 6 tooltip + Task 7 tier) ✓; agent-creates-skills (Task 5, stretch) ✓; layers on Phase 4 primitives ✓.
- **Backward-compat:** `reasoning_effort="superpowers"` is safely ignored by an un-upgraded engine (maps to default effort) — FE/BFF and engine decouple; ship engine first.
- **Cost safety:** fan-out is OFF for every non-superpowers turn (Task 3 gate + Phase 4's off-by-default), so no surprise N× spend.
- **Type consistency:** `superpowers_mode`/`turn_superpowers_mode` bool threaded gateway→session→agent (Task 1); `.coordinator` + `coordinator_dispatch` flag (Tasks 2–3); `coordinator` skill name (Task 4) referenced by the Task 2 prompt section.
- **Open product decision flagged:** the Superpowers metering ratio (default 5× — confirm).
