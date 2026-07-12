# nullALIS Ultimate Agent — Code-Truth Assessment

**Date:** 2026-07-12
**Assessed commit:** `c05bcac2` (`origin/main`)
**Scope:** nullALIS engine, its executable contracts, and the live gateway → session → agent path
**Status:** Evidence-backed assessment; no runtime implementation is authorized by this document

## Executive verdict

nullALIS is already an unusually capable **agent harness**. It has a coherent Zig runtime, a real
tool loop, multi-agent execution, structured turn state, tenant boundaries, durable memory,
retrieval, learning and TELOS contracts, observers, channels, scheduling, and a production gateway.
This is not a prototype that needs a rewrite.

It is not yet a trustworthy autonomous agent in the strongest sense. Its central semantic gap is:

> The model can still declare a goal complete, and the runtime can still advance a plan, without a
> host-owned predicate proving that the requested world state is true.

The second gap compounds the first:

> Durable learning does not yet have one provenance-and-authority boundary that prevents assistant,
> tool, web, dream, or reflection content from being laundered into user-authored truth or active
> behavior.

My calibrated assessment at this commit is:

| Lens | Score | Meaning |
|---|---:|---|
| Agent harness and architecture | **78 / 100** | Strong, extensible foundation; worth evolving in place |
| Dependable autonomous behavior | **47 / 100** | Can do impressive work, but success, authority, cancellation, and recovery are not closed contracts |
| “Ultimate agent” product | **43 / 100** | The hardest remaining work is semantic integrity, governed growth, longitudinal evaluation, and premium interaction—not more tools |

These are engineering judgments, not benchmark results. No current SOTA performance claim should be
made until the proposed evaluation program establishes reproducible baselines.

## What changed from the earlier assessment

The code is closer to the target than a surface-level read suggests:

- `Agent.turnOutcome` is real and is already the live orchestration boundary
  (`src/agent/root.zig:1017`, `:3973`).
- Memory, learning, and TELOS have normative docs paired with executable contract tests.
- Context assembly, multi-agent coordination, run traces, entitlement, approval, cancellation,
  scheduling, and secret-vault primitives already exist.
- ReleaseSmall is genuinely small for the shipped surface.

But the newer code also makes the missing kernel easier to see. A structured `TurnOutcome` exists,
yet it carries activity metadata rather than proof of task success. Learning state exists, yet its
promotion authority and provenance are fragmented across several paths. The correct plan is
therefore **convergence around two contracts**, not another broad feature sprint:

1. an evidence-grounded outcome contract; and
2. a bounded learning-and-authority contract.

## The live path, reconstructed

The production chat path is:

```text
POST /api/v1/chat/stream
  → TenantRuntime.processMessageWithTurnOptions
  → SessionManager.processMessageWithContext
  → Agent.turnOutcome
  → provider/tool loop
  → SessionManager returns assistant text
  → gateway derives and emits the terminal SSE frame
```

The important seams are `src/gateway.zig:11150`, `:11523`, `src/session.zig:1118`, `:1307`, and
`src/agent/root.zig:3973`.

This is good news: the new outcome evaluator belongs at an existing, narrow boundary. It does not
require replacing the provider, tool, channel, memory, or runtime vtables.

## What is already excellent

### 1. The architecture can carry the vision

- Vtable-driven providers, tools, channels, memory, observers, and runtimes give nullALIS stable
  extension boundaries.
- The core loop already has serial and parallel dispatch, approval, policy and entitlement
  preflight, observer events, task plans, subagents, and durable run identifiers.
- The engine remains compact: the all-engine ReleaseSmall build produced a 6,653,816-byte binary in
  this assessment.
- The codebase has unusually broad automated coverage and leak-aware Zig tests.

### 2. The memory substrate is not the problem

The engine already contains layered retrieval, extraction, working memory, semantic summaries,
procedural memory, graph expansion, TELOS loading, dream/mining jobs, and explicit memory/learning/
TELOS contracts. The missing work is **trust, activation, and outcome linkage**, not another memory
backend.

### 3. There is a usable evidence substrate

Tool executions have IDs, structured success/error results, run events, traces, observers, and a
gateway flush seam. These can become evidence receipts without a new tool vtable or a second event
system.

### 4. The project already values contract truth

`docs/memory-contract.md`, `docs/learning-contract.md`, and `docs/telos-contract.md` are paired with
compiled tests. The ultimate-agent work should extend this exact governance model with an outcome
contract and stronger learning transition tests.

## The decisive gaps

### P0 — Success is still self-reported or inferred from activity

`TurnOutcome` currently contains text, a tool-only flag, executed-call metadata, spawned task IDs,
iteration count, and loop detection (`src/agent/root.zig:1039`). It has no goal contract, success
predicate, evidence receipt, terminal cause, or deterministic verdict.

The current goal loop explicitly asks for the model's judgment and writes the parsed result directly
into goal state (`src/agent/goal_loop.zig:39`, `src/agent/root.zig:5137`). Procedural quality then maps
that judgment to a score (`src/agent/procedural_memory.zig:155`). A model saying “met” is therefore
able to influence both termination and learning without host verification.

There is also a producer/parser mismatch in the reflection format: the prompt describes a body value
while the parser searches the opening tag's attribute area (`src/agent/goal_loop.zig:39`, `:80`).

### P0 — Plans track calls by position, not proof by identity

The active task plan assigns parsed tool calls to successive steps by position
(`src/agent/root.zig:5768`). Any successful tool result can complete the corresponding step; the
runtime does not first prove that the tool is the step's expected tool or that its output establishes
the step's desired state. A final prose response can complete a no-tool step
(`src/agent/root.zig:5379`).

`TaskPlan.isComplete` treats both `.done` and `.failed` as terminal, and `refreshStatus` can mark a
mixed plan completed unless every step failed (`src/agent/task_planner.zig:205`, `:212`). A plan with
two failed steps and one successful step can therefore be represented as completed.

### P0 — The structured outcome is not actually consumed end-to-end

Production `TurnOutcome` return sites do not populate `tool_calls_executed`
(`src/agent/root.zig:5643`, `:5658`, `:6222`). `Session.lastTurnOutcome` exists but has no production
consumer (`src/session.zig:174`), and the session path returns only text (`src/session.zig:1317`). The
gateway still infers a tool-only turn from an empty reply (`src/gateway.zig:11631`).

The shape exists; its intended truth has not reached the user-facing boundary.

### P0 — Durable learning can misattribute source authority

Reflection and tool output can be reintroduced into history with a user role
(`src/agent/root.zig:5875`). The extraction schema does not carry a separately observed speaker, and
the runner hardcodes extracted attribution to `user` (`src/agent/extraction/runner.zig:893`). The
prompt favors liberal extraction when uncertain (`src/agent/extraction/prompts.zig:32`). Extracted
material can then enter durable and working memory (`src/agent/extraction_persist.zig:1671`, `:1835`).

That is a classic authority-laundering path: untrusted generated material can acquire the semantics
of a direct user statement.

### P0 — Entitlement and approval context is not closed over execution

The gateway resolves entitlement, but the turn context reaching tool preflight can fall back to a
permissive default. `ProcessMessageOptions` does not carry the resolved entitlement through the
session boundary, while tool preflight reads the global turn context (`src/agent/root.zig:3144`). The
default entitlement is active/pro when no resolver value is present (`src/entitlement.zig:116`).

Approved pending tools intentionally bypass entitlement revalidation (`src/agent/root.zig:3147`). A
scoped approval must never silently become a durable bypass of current policy, entitlement, or
capability state.

The configured default is also materially broader than the target authority contract:
`AutonomyConfig.level` defaults to `.full` (`src/config_types.zig:79`), and full autonomy resolves
every tool metadata class—including `operator_only`—to `auto_approve`
(`src/security/approval_modes.zig:26`). The security policy still blocks some unsafe commands, but the
approval surface is not a default product boundary. Launch must make this posture an explicit owner
decision and close it before production cut: enforce human gates for external, destructive,
user-sovereign, and operator-governed actions, or disable those action classes until enforcement
lands. A generic autonomy label cannot waive that invariant.

### P0 — Secret mutation has multiple governance paths

The generic secret API consumes its confirmation token before validating the new value
(`src/gateway.zig:21029`, `:21045`), and success-audit writes are best-effort. Channel, provider, and
Telegram setup paths call `putSecret` directly (`src/gateway.zig:19458`, `:20017`, `:21255`) instead
of sharing the same two-phase contract. `TokenStore.prepare` has no outstanding-token cap
(`src/gateway/secret_vault.zig:108`).

A tracked benchmark artifact also contains credential-shaped material at `.spike/benchmark.json`.
The value must not be repeated; it should be treated as compromised, rotated, and removed from
history through the platform's credential-response process.

### P1 — Cancellation is advisory at iteration boundaries

The token resets at turn start and is polled at the top of the agent loop
(`src/agent/root.zig:3983`, `:4519`). It does not interrupt an in-flight provider request, a running
tool, a serial call sequence, or a subagent. Cancellation returns text rather than a terminal outcome
verdict. A premium autonomous system needs cancellation to be a propagated control signal with a
receipt stating what did and did not run.

### P1 — Recovery is weaker than the action surface

Reversible actions do not share a journal/undo protocol, child tasks can outlive the parent without a
unified terminal contract, and `file_edit` writes in place. The agent can act more broadly than it can
prove, unwind, or explain.

### P1 — Learning organs are present but gated and fragmented

Semantic summarization defaults off (`src/config_types.zig:1382`), and that early return suppresses
several downstream session-end learning operations. The learning trust states and manual
adopt/dismiss path are real, but transitions are not yet an immutable evidence ledger with TTL,
canary, outcome-based retirement, and deterministic rollback. The current executable learning
contract covers only a thin part of that behavior.

TELOS Slice 1 is substantially implemented, but it defaults off, human-authored T4 remains Slice 2,
freshness demotion is deferred, and backfill is not operator-reachable
(`src/agent/telos_contract_test.zig:89`, `src/agent/memory_loader.zig:1197`, `:1512`).

### P1 — Behavioral evaluation is not yet a release authority

The compile/test matrix is strong. Behavioral benches are not yet one blocking, reproducible
scorecard spanning task success, memory, recovery, safety, personalization, cost, and premium UX.
Provider-secret absence can skip behavioral lanes, and polluted-memory results are not universally
blocking. “SOTA” is therefore not currently a falsifiable release claim.

## Dimension scorecard

| Dimension | Current | Target | Gap |
|---|---:|---:|---:|
| Architecture and extensibility | 9.0 | 9.5 | 0.5 |
| Tool/action execution substrate | 8.0 | 9.5 | 1.5 |
| Memory and retrieval substrate | 8.0 | 9.5 | 1.5 |
| Outcome truth and calibration | 3.0 | 9.8 | 6.8 |
| Learning provenance and governance | 4.0 | 9.5 | 5.5 |
| Authority and approval integrity | 5.0 | 9.8 | 4.8 |
| Cancellation, recovery, and rollback | 4.0 | 9.5 | 5.5 |
| Longitudinal evaluation | 5.0 | 9.5 | 4.5 |
| Premium user experience | 5.0* | 9.5 | 4.5 |

`*` Premium UX is provisional because this recon centered on the engine; the hub/frontend requires a
separate code-truth pass before implementation.

The shortest honest summary is: **roughly half of the difficult work remains**. It is not half the
code volume. It is the semantic closure that turns abundant capability into trustworthy agency.

## What should not be rebuilt

- Do not replace the vtable architecture.
- Do not create a parallel goal engine, event bus, memory store, or approval service.
- Do not add more autonomous tools before existing actions have success, authority, cancellation,
  and recovery contracts.
- Do not let the model write executable predicates or directly promote its own learning.
- Do not conflate “used often” with “helpful”; learned procedures need held-out outcome evidence.
- Do not call a prose answer “completed” when the host lacks a verifier. Use `unverified` or
  `awaiting_user` honestly.

## Would I want to work through nullALIS?

Yes. Strongly.

I would choose this foundation over starting again because the expensive structural decisions are
mostly right: explicit ownership, small binaries, typed boundaries, contract tests, durable state,
observability, modular tool/provider/channel surfaces, and a serious test culture. Its failures are
legible and concentrated at a few cross-cutting seams. That is the kind of system worth raising into
an exceptional agent.

The work should be demanding and conservative: preserve the engine, replace self-belief with proof,
separate memory from authority, let only bounded low-risk procedures grow autonomously, and make
every production capability earn promotion independently.

## Validation evidence

Run from the isolated worktree at `c05bcac2`:

```text
zig build test --summary all \
  -Dengines=base,sqlite,postgres \
  -Dchannels=cli,telegram

22/22 build steps succeeded
7548/7703 tests passed
155 skipped
0 failed
```

`NULLALIS_POSTGRES_TEST_URL` was unset, so the real Postgres implementation was semantically compiled
but live-Postgres integration tests were skipped. These local counts must not replace the repository's
profile-qualified status lock.

```text
zig build -Doptimize=ReleaseSmall \
  -Dengines=base,sqlite,postgres \
  -Dchannels=cli,telegram

7/7 build steps succeeded
zig-out/bin/nullalis = 6,653,816 bytes
```

The build summary reported a test-step maximum RSS above the stated 80 MB product ceiling. This run
does not establish a runtime RSS regression—the measurement includes build/test-runner behavior—but
it also does not validate the ceiling. The release gate needs the repository's canonical per-process
RSS procedure before publishing a refreshed status lock.

## Companion documents

- Binding target: `docs/superpowers/specs/2026-07-12-ultimate-agent-design.md`
- Execution and rollout: `docs/superpowers/plans/2026-07-12-ultimate-agent-convergence.md`
