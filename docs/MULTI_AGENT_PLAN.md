---
tags: [prose, prose/docs, prose/multi-agent]
authored: 2026-05-19
author: Claude (father, full ownership per Nova directive)
binds_to: AGENTS.md §14 + docs/ROADMAP.md
purpose: canonical dispatch document for parallel agent execution against the nullalis roadmap
---

# nullalis Multi-Agent Dispatch Plan

**Authority:** AGENTS.md §14 (Swiss-watch standard) + docs/ROADMAP.md (versioned blocks).
**Purpose:** Distribute roadmap work across N parallel agents (A, B, C, ...) without conflict, without quality loss, and without losing the Swiss-watch discipline.

This document is the operational protocol Nova (the owner) uses to spawn agents against the roadmap. Every section is normative — agents read this before claiming work.

---

## 1. Roster — Agent identities and primary scope

Each agent is a distinct execution lane. Identity is `Agent {LETTER}` (A, B, C, …); scope is a track from the multi-agent partitioning. Agents do not change their primary scope mid-block — they finish a block on their lane, then re-enter the pool for the next assignment.

| Agent | Track name | Primary scope (files/directories) | Conflict risk |
|---|---|---|---|
| **A** | Security Hardening | `src/security/`, `src/tools/metadata.zig`, `src/tools/tool_sandbox_v1.zig`, `src/session/`, `src/tools/composio.zig` (sanitizer wiring) | LOW |
| **B** | Channels Completion | `src/channels/email.zig`, `teams.zig`, `nostr.zig`; narrow edits to `src/daemon.zig`, `src/channel_loop.zig` per channel | LOW per channel, serialize daemon edits |
| **C** | Durability + Persistence | `src/migrations/00XX_*.sql` (new files), `src/runtime/approvals/` (new pkg), `src/runtime/events/` (new pkg), `src/subagent.zig`, `src/gdpr.zig` (E2E test) | LOW (mostly new files) |
| **D** | Benchmark Harness | `.spike/external/tau_bench/`, `.spike/results.tsv`, `.spike/run.sh` (latency gate additions) | NONE (sandboxed) |
| **E** | Audit-Sweep | Scattered MED/LOW findings — each task independent; touches `src/tools/`, `src/memory/`, `src/main.zig`, `src/onboard.zig` | LOW (small, diverse) |
| **F** | Orphan-Wiring | `src/agent/task_planner.zig`, `src/agent/narration.zig`, `src/tools/schema.zig`, narrow edits to `src/agent/prompt.zig` and `src/providers/*.zig` | MED (touches prompt + providers) |
| **G** | ContextEngine Migration | `src/agent/context_engine.zig`, **`src/agent/root.zig` (SOLO LOCK during v1.14.14)** | HIGH — locks root.zig |
| **H** | Gateway Extraction | **`src/gateway.zig` (SOLO LOCK during each extraction sprint)**, new files under `src/gateway/` (auth_tokens, tenant_cache, channels, quota) | HIGH — locks gateway.zig |
| **I** | Frontend (zaki-prod) | zaki-prod repo only (separate); UI autonomy toggle, AskUserQuestion renderer, mode toggle, brain entity styling, memory inspector | NONE within nullalis |
| **J** | Observability + SRE | `src/observability.zig`, `src/lane_metrics.zig`, `src/memory/lifecycle/hygiene.zig`, Grafana configs, OTEL collector setup, capacity model docs | LOW |

**Scaling rule:** v1.14.13 starts with **4 agents (A, D, E, F)** after PR #72 merges and ROADMAP.md is marked `→ IN FLIGHT`. E is included from the first wave because the doc-truth / false-confidence cluster is part of the launch gate. G and H are SOLO-LOCK agents — only one block in flight per lock at any time.

---

## 2. Block → Agent assignment matrix

Each V block in `docs/ROADMAP.md` has one or more agents assigned. Agents work in parallel on **separate sub-branches**, converging at the bench gate.

| V block | Theme | Agents | Notes |
|---|---|---|---|
| **v1.14.13** | Sandbox close + τ-bench baseline + wire orphans | A (V8 sandbox), D (τ-bench harness + B2 latency gate), E (B1 doc-truth + Cluster B/C handlers + F-A2 strip + identity.zig decision), F (tools/schema + task_planner + narration) | 4-way parallel; converges in `sprint/v1.14.13` |
| **v1.14.14** | ContextEngine migration | **G (SOLO LOCK on root.zig)** | Phase-by-phase; bench gate between phases |
| **v1.14.15** | Email channel | B (Email), H (auth_tokens extraction — Sprint A) | B + H can parallelize: B touches channels/, H touches gateway/ |
| **v1.14.16** | Teams channel | B (Teams), H (channels extraction — Sprint C) | Same pattern |
| **v1.14.17** | Nostr channel | B (Nostr) | Solo (small block) |
| **v1.14.18** | Audit MED sweep + V4/V6/V7 + B8 coverage | E (sweeps), C (V4 ledger), E (V6 state.zig), E (V7 markdown mirror), J (B8 kcov) | 2-3 agents (E with multiple sub-tasks queued, C, J) |
| **v1.15.0** | τ-bench Karpathy iteration | D (iteration analysis + fix tracking), F (most fixes are in agent/runner code) | Tight pairing D+F |
| **v1.16.0** | Frontend wave | I (zaki-prod), F (backend AskUserQuestion tool), J (instrumentation if needed) | I is the heavy track |
| **v1.17.0** | Native connectors | A (OAuth scaffolding), H (auth_tokens follow-up if not already done), B (connector wiring) | 3-way parallel |
| **v1.17.5** | Durability + auditability + B9 GDPR | C (V3 approvals + V5 event log + V4 finish + B9), H (Sprint E approval routing extraction) | C is the core track |
| **v1.18.0** | Per-cell pod canary + B5/B12 prereq | J (capacity model + load test), zaki-infra (Helm/PgBouncer — operator action, not an agent) | J is the agent; rest is operator |
| **v1.18.5** | DR + backup drill | J | Solo |
| **v1.19.0** | Observability + SRE + B6/B7 | J (dashboards + OTEL + long-tenant bench), H (Sprint D quota extraction) | J + H |
| **v1.19.5** | Security + identity hardening — H1 + V9 | A (capability metadata + identity strict mode) | Solo (A's specialty) |
| **v1.19.7** | Unit economics baseline | J (measurement), Nova (analysis + decision) | J + Nova |
| **v2.0.0** | Commercial launch | Nova (strategy), I (onboarding refresh), J (instrumentation), C (billing reconciliation tables) | Multi-track but Nova-led |
| **v2.1.0** | Runtime / frontend boundary — V10 | H (Sprint F BFF adapter extraction), I (channel adapter scaffolding) | H + I |
| **V-infinity** | 12 pillars | One agent per pillar; Karpathy keep/discard | Paced by user signal |

---

## 3. Branch + worktree + PR conventions

### 3.0 Worktree-per-agent (MANDATORY — added 2026-05-19 after Agent D shared-worktree incident)

**Each agent works in its OWN git worktree at its OWN filesystem path. Branches alone are not sufficient — two agents on different branches but in the same working directory will stomp each other's files.**

Before spawning Agent {X}, create their worktree:

```bash
# Run from any directory; Nova does this BEFORE pasting the agent's spawn prompt.
git -C /Users/nova/Desktop/nullalis worktree add /Users/nova/Desktop/nullalis-agent-{X} sprint/v{block}
```

The spawn prompt MUST point the agent at their worktree directory:

```
Your working directory: /Users/nova/Desktop/nullalis-agent-{X}
cd to it before running any git or build command.
Do NOT work in /Users/nova/Desktop/nullalis (Nova's monitor worktree) or any other agent's directory.
```

After merge, clean up:

```bash
# Once Agent {X}'s PR merges into sprint, remove their worktree:
git -C /Users/nova/Desktop/nullalis worktree remove /Users/nova/Desktop/nullalis-agent-{X}
# Then prune the merged branch:
git branch -d agent/{X}-v{block}
git push origin --delete agent/{X}-v{block}
```

**Why this matters (the 2026-05-19 lesson):** Agent A worked in its dedicated worktree
`/Users/nova/Desktop/nullalis-agent-A` and ran cleanly with zero coordination friction.
Agent D worked in the same directory as Claude (Nova's monitor lane) — even though they
were on different branches, every file edit in that shared filesystem state risked
clashing. Reviewing D's PR required Nova's monitor to go read-only mid-flight. Don't
repeat that pattern. One worktree per agent, every time.

### Branch naming

```
agent/{A-J}-v{block}                e.g.  agent/A-v1.14.13, agent/D-v1.14.13
sprint/v{block}                     e.g.  sprint/v1.14.13   (merge target for all agents on that block)
release/v{block}                    e.g.  release/v1.14.13  (PR head into main — only when bench gate passes)
```

### Worktree paths (canonical)

```
/Users/nova/Desktop/nullalis              Nova's monitor / general work / main branch
/Users/nova/Desktop/nullalis-agent-A      Agent A on agent/A-v{block}
/Users/nova/Desktop/nullalis-agent-B      Agent B on agent/B-v{block}
/Users/nova/Desktop/nullalis-agent-C      Agent C on agent/C-v{block}
... etc through J
```

### PR convention (one PR per V tag, per Nova directive)

1. Each agent commits to their sub-branch `agent/{X}-v{block}`.
2. When agent's sub-task hits bench gate, agent opens a PR from `agent/{X}-v{block}` → `sprint/v{block}`. This is the **agent-level review** PR. Nova or another agent reviews. Merge into sprint branch.
3. When ALL sub-tasks for the block are merged into `sprint/v{block}` AND the FULL bench gate passes (LoCoMo + τ-bench + latency + block-specific gates), open a PR from `sprint/v{block}` → `main`. This is the **block-level review** PR.
4. After review approval + merge, tag `v{block}` at the merge commit. Update ROADMAP.md status: `→ TAGGED v{block} (yyyy-mm-dd)`.

### Two-tier review

- **Agent-level PR** — narrow scope (one track's work). Reviewer = Nova or another agent (typically the agent who'd be most affected by the change). Verifies: AGENTS.md §14 compliance, scope discipline, test additions.
- **Block-level PR** — full sprint. Reviewer = Nova (final approval). Verifies: bench gate, no regressions, all in-flight items closed or documented.

---

## 4. Coordination protocol

### 4.1 ROADMAP.md is the global lock

Each block has a status marker in the block heading:
- `→ PLANNED` (default)
- `→ IN FLIGHT (agents: A, D, E, F; sprint branch: sprint/v1.14.13)` — actively being worked
- `→ BENCH GATE` — all agent sub-tasks merged, gate validation in progress
- `→ TAGGED v1.14.13 (2026-05-23)` — done
- `→ DEFERRED (reason: X; revisit: Y)` — paused with rationale

To start a block, the first-claiming agent updates the marker on a `chore(roadmap): claim v{block}` commit. Other agents reading ROADMAP.md see the marker and either join the block (if their track has work in it) or pick a different block their track owns.

### 4.2 Hot-file ownership

For files in the HIGH conflict tier (`src/agent/root.zig`, `src/gateway.zig`, `src/zaki_state.zig`, `AGENTS.md`, `docs/ROADMAP.md`):

- Owning agent declares in their first commit on the block: `[OWNS root.zig until {ISO-DATE}]`
- Other agents reading recent log see the ownership lock
- Owner releases by either tagging the block (lock dissolves) or explicit commit: `[RELEASE root.zig]`

For the SOLO-LOCK agents (G on root.zig during v1.14.14; H on gateway.zig during each extraction):
- The block heading in ROADMAP.md states the lock explicitly
- No other agent edits the locked file during that block — they queue their changes for a follow-up block

### 4.3 Communication channel = git log

There is no Slack, no synchronous chat, no shared chatroom. The git log IS the protocol.

Every commit references:
- Track + agent identifier in body: `[agent=A track=security block=v1.14.13]`
- Open questions (if any) in body: `[open: should X also Y? @nova]`
- Cross-agent dependencies: `[depends on: agent/D-v1.14.13:abc1234]`

Agents reading recent log on the sprint branch see the full coordination state.

### 4.4 Conflict resolution

If two agents both want a hot file:
1. The one holding the marker wins.
2. The other agent picks a different task from their track's backlog.
3. If no other task exists, the other agent pauses, posts an `[idle: waiting on root.zig]` empty commit on their own branch, waits.

Nova arbitrates if an agent doesn't release in a reasonable time.

### 4.5 Stuck protocol

If an agent gets stuck (Zig API uncertainty, architectural ambiguity, blocked dependency):
1. Commit current state on their branch with `[STUCK: <one-line description>]` in commit body
2. Update ROADMAP.md block marker: `→ IN FLIGHT (agent A STUCK on Z)`
3. Nova or another agent picks up the unblock

No silent stuck states. The git log makes it visible.

### 4.6 Branch divergence under an open PR (helper command)

When a sprint moves forward (another agent's PR merges) while your PR is still open,
your branch is now behind `sprint/v{block}` and the PR diff shows the just-merged
work as "deleted" (misleading view that would revert the prior agent's work if
naively merged).

**The fix is one command on the reviewer side:**

```bash
gh pr update-branch <PR_NUMBER>
```

This merges current `sprint/v{block}` INTO the agent's PR branch, creating a merge
commit on the agent's branch and updating the PR. The diff then shows only the
agent's actual additions. No working-tree action required. Safe for the agent (their
own commits are preserved).

This pattern came up on 2026-05-19 when Agent D's PR (#74) was opened before
Agent A's PR (#73) merged. `gh pr update-branch 74` resolved the apparent revert
without disrupting either agent.

### 4.7 GitHub self-approval limitation

`gh pr review <N> --approve` returns "Can not approve your own pull request" when
the GitHub user authenticated to `gh` is the same account that opened the PR.
This is a GitHub policy, not a tooling bug.

**Workaround:** the owner (Nova) merges directly via `gh pr merge <N> --merge`
without going through the approve step. Or set up a separate reviewer account.
Discovered 2026-05-19 reviewing Agent A's PR.

### 4.8 Audit-ledger SHA orphan — split your commits (MANDATORY)

When closing an audit-ledger row, **never put the ledger update in the same commit
as the code change you are referencing**. The ledger row needs the commit SHA, but
the SHA is only known *after* the commit exists. If you write the ledger row in
the same commit body, you have two bad choices:

1. **Amend after commit** to insert the SHA → the SHA you just wrote is now stale
   (amend produces a new commit). The ledger row now points at an orphan.
2. **Use a placeholder** like `<SHA-TBD>` → another agent merges, the placeholder
   ships, and the audit ledger is now a lie until someone backfills.

**The canonical fix (proven on Agent F's v1.14.13 work, ratified 2026-05-19):**

```
git commit -m "feat(tools): SCHEMA-WIRE — wire schema cleaner..."   # the code
# now the SHA exists. Capture it.
SHA=$(git rev-parse HEAD)
# Edit the ledger row in a SECOND, separate commit:
$EDITOR docs/audits/2026-05-19-file-by-file-audit-ledger.md   # paste $SHA
git commit docs/audits/2026-05-19-file-by-file-audit-ledger.md \
  -m "docs(audit): close SCHEMA-WIRE ledger"
```

Two commits, never one. The code commit references nothing; the ledger commit
references the code commit's now-immutable SHA. Both are atomic, both have a
single reason to exist. Bisect stays clean. Audit ledger remains accurate even
if the agent's branch is rebased before merge (the SHA points into the original
chain, which the merge-commit preserves).

**Why amend is wrong here:** amend rewrites history. If you amend the code commit
to fix the ledger SHA, every subsequent ledger entry that references the *amended*
SHA is also orphaned after the next force-push. Split commits avoid the problem
structurally.

**Agent E suffered this twice on v1.14.13 (commits 4d9d0529 + later orphan fix);
Agent F never did, because Agent F split from the start.** This pattern is now
mandatory for every ledger closure.

---

## 5. Per-block launch brief template

When Nova (or a meta-agent) spawns an agent for a block, the brief follows this template. Drop into your agent spawn prompt:

```
You are Agent {LETTER} on the nullalis project. Your scope is {TRACK_NAME}.

ROADMAP block in flight: v{BLOCK_NUMBER} — "{THEME}"
Block status target: → TAGGED

Read first (in this order):
  1. AGENTS.md §14 (Swiss-watch standards — these are MANDATORY)
  2. docs/ROADMAP.md → block v{BLOCK_NUMBER}
  3. docs/MULTI_AGENT_PLAN.md → your track's section
  4. docs/STATUS.md (current state)

Your working directory: /Users/nova/Desktop/nullalis-agent-{LETTER}
  cd to this directory BEFORE running any git or build command. Do NOT work
  in /Users/nova/Desktop/nullalis (Nova's monitor) or any other agent's
  worktree. Your filesystem is isolated from other agents.

Your branch: agent/{LETTER}-v{BLOCK_NUMBER}
  This branch already exists in your worktree (created by Nova via
  `git worktree add` before spawning you). Verify with `git branch --show-current`
  — it should return `agent/{LETTER}-v{BLOCK_NUMBER}`. If it doesn't, STOP
  and ask Nova; do not proceed.

Your sub-tasks in this block (from ROADMAP):
  - Step X.Y: {brief}
  - Step X.Z: {brief}

Files you OWN during this block (no other agent edits these):
  - {file or directory}
  - {file or directory}

Files you MAY NOT TOUCH (owned by other agents this block):
  - {file or directory} (Agent {OTHER})
  - {file or directory} (Agent {OTHER})

Hot files (coordinate via [OWNS] commit-message convention):
  - {file}

Closing standard (this is the bench gate criterion for YOUR sub-task):
  - {tests added}
  - {grep verification}
  - {behavior change demonstrated}

When YOUR sub-task is done:
  1. Push to agent/{LETTER}-v{BLOCK_NUMBER}
  2. Open PR → sprint/v{BLOCK_NUMBER}
  3. Tag Nova for review
  4. Update todo list with status

If stuck: commit [STUCK: <reason>], update ROADMAP marker, wait for unblock.

NEVER:
  - Edit a file owned by another agent without coordinating
  - Batch multiple findings into one commit (AGENTS.md §14.1)
  - Delete code reflexively (AGENTS.md §14.2 — archaeology first)
  - Ship a directive the bench shows the model ignores (AGENTS.md §14.7)
  - Push directly to main or sprint/{block} — sub-branch only

Reputation contract: every commit either improves nullalis or makes the
foundation harder to build on. There is no neutral commit.
```

---

## 6. v1.14.13 specific dispatch — ready to spawn

This is the first block to ship multi-agent. Concrete spawn assignments below.

**Launch prerequisites for every v1.14.13 agent:**
- PR #72 merged into `main`
- ROADMAP.md v1.14.13 heading marked `→ IN FLIGHT`
- Active audit ledger exists at `docs/audits/2026-05-19-file-by-file-audit-ledger.md`

### Agent A (Security) — v1.14.13 Step 0

**Sub-tasks:**
- Step 0: V8 sandbox fail-closed by default (~3-4 hours)

**Owns:** `src/tools/tool_sandbox_v1.zig`, `src/security/` (read-only verification), new test file `tests/security/sandbox_fail_closed_test.zig`

**May not touch:** anything else

**Closing standard:**
- `tool_sandbox_v1.zig:162-168` updated per ROADMAP spec
- New test proves `error.SandboxUnavailable` is raised when backend unavailable + new env var unset
- `grep "fail_open_on_dev" src/` shows only the new gated path
- `zig build test` passes

**Sub-branch:** `agent/A-v1.14.13`

### Agent D (Benchmark) — v1.14.13 Step 1 + Step 7

**Sub-tasks:**
- Step 1: τ-bench Airline harness (~1 day)
- Step 7: B2 latency bench gate scaffold (~2 hours)

**Owns:** `.spike/external/tau_bench/` (new), `.spike/results.tsv` (append-only), `.spike/run.sh` (latency-emit additions)

**May not touch:** `src/` (this track is sandboxed in `.spike/`)

**Closing standard:**
- `.spike/external/tau_bench/runner.sh` runs end-to-end on 50 Airline tasks
- First baseline row appended to `.spike/results.tsv` as `iter22-tau-airline-baseline` with pass_rate + mean_tool_calls + mean_latency_ms + p50_ttft_ms + p95_ttft_ms
- p95 TTFT bench gate added to subsequent block templates in ROADMAP.md
- Triage doc emitted at `.spike/external/tau_bench/runs/<ts>/triage.md`

**Sub-branch:** `agent/D-v1.14.13`

### Agent E (Audit-Sweep) — v1.14.13 Steps 4, 5, 6, 0.5

**Sub-tasks:**
- Step 0.5: B1 AGENTS.md skill/skillforge map verification (~5 min)
- Step 4: F-A2 brain_graph directive strip (~15 min)
- Step 5: False-confidence handler cluster — handleReady decision (rewire), EMPTY_TURN_PLACEHOLDER strip, BrowserTool honesty, BIRTHDAY contradiction (~1 day total)
- Step 6: identity.zig decision — keep+document OR delete (Nova approves direction first)

**Owns:** `src/agent/prompt.zig` (F-A2 lines only), `src/gateway.zig` (handleReady + EMPTY_TURN_PLACEHOLDER lines only — COORDINATE WITH H if H is active), `src/tools/browser.zig`, `src/agent/extraction_persist.zig:1106-1143` (BIRTHDAY docstring), `AGENTS.md` (skills map line only), `src/identity.zig` (decide), `docs/deferred-register.md`

**May not touch:** Agent A's, D's, F's owned files

**Closing standard:** each finding closed atomically with its own commit per AGENTS.md §14.1. References to v1.14.12 archaeology audit findings cited in commit messages.

**Sub-branch:** `agent/E-v1.14.13`

### Agent F (Orphan-Wiring) — v1.14.13 Steps 2, 3

**Sub-tasks:**
- Step 2: `tools/schema.zig` wired into providers (~1 day)
- Step 3: `task_planner.zig` + `narration.zig` paired wiring (~2 days)

**Owns:** `src/tools/schema.zig`, `src/agent/task_planner.zig`, `src/agent/narration.zig`, `src/providers/*.zig` (cleanSchemaForProvider insertion sites), narrow edits to `src/agent/prompt.zig` (task_plan directive — COORDINATE WITH E if E is editing prompt.zig same window), `src/agent/root.zig` (parseTaskPlan call site — COORDINATE: this is a HOT file, claim ownership via [OWNS] marker)

**May not touch:** Agent A's, D's, E's owned files except prompt.zig coordination

**Closing standard:**
- Each provider's tool-spec output passes its strategy's filter (new test per provider)
- Synthetic 3-step task → 3 narration frames emitted (new test)
- system prompt now includes task_plan directive (verify visible in stable prefix hash)

**Sub-branch:** `agent/F-v1.14.13`

---

## 7. Bench gate convergence

When all four agent sub-branches merge into `sprint/v1.14.13`:

1. **Build gate:** `zig build` + `zig build test --summary all` → exit 0, zero leaks
2. **Memory gate:** LoCoMo cold + polluted ≥ v1.14.12 numbers (no regression)
3. **Execution gate:** τ-bench Airline baseline committed (this block establishes the baseline; numerical target comes from v1.15.0)
4. **Latency gate:** p95 TTFT ≤ 4.0s on canonical bench
5. **Code-truth gate:** every audit Cluster A orphan either wired (verifiable by tests) OR documented in deferred-register
6. **Doc gate:** ROADMAP.md, STATUS.md, AGENTS.md all reflect post-block state

Only after ALL six gates pass: `sprint/v1.14.13` → `main` PR opens → review → merge → tag `v1.14.13`.

---

## 8. Failure modes + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Merge conflict on hot file | MED | File ownership + [OWNS] commit convention |
| Two tests with same name | LOW | Per-track test directory convention + zig's test-name uniqueness check |
| Bench regression invisible until merge | MED | Each agent's PR runs the bench gate before merging into sprint branch (not just at sprint merge) |
| Quality drift (one agent sloppy) | MED | AGENTS.md §14 enforcement; two-tier review (agent-PR + block-PR) |
| Coordination overhead | MED | Git log as protocol; ROADMAP.md as global lock; explicit briefs |
| Agent gets stuck silently | LOW | [STUCK] commit convention + ROADMAP marker update |
| Cross-repo coordination (zaki-prod) | MED | Frontend agent (I) has its own block markers; backend blocks reference frontend dependencies explicitly |
| Nova bottleneck on reviews | HIGH | Agent-level PRs are reviewable by peer agents; only block-level PR is Nova-only |

---

## 9. What this plan IS NOT

- **A guarantee of speed.** Parallelism helps but coordination has overhead. 4 agents ≠ 4× faster.
- **A bypass of AGENTS.md §14.** Every agent obeys the standards. Multi-agent operation is the standard scaled, not the standard relaxed.
- **A substitute for Nova's review judgment.** Block-level PRs always reach Nova. Agent-level PRs may be reviewed by peer agents, but Nova owns the merge call.

## 10. What this plan IS

- The dispatch mechanism so multiple agents can work in parallel without conflict.
- The proof that "no loose ends" is achievable at scale, not just with one agent.
- The way Nova distributes work without losing the Swiss-watch standard.
- The single source of truth for who-does-what when multiple agents are live.

---

## 11. Operational checklist for spawning an agent

Before spawning Agent X for block v{Y}, Nova confirms:

- [ ] ROADMAP.md block v{Y} is `→ PLANNED` or already `→ IN FLIGHT`
- [ ] Agent X's track is assigned to block v{Y} per §2 matrix
- [ ] No hot-file conflict with another active agent
- [ ] Sub-branch `agent/X-v{Y}` does not yet exist
- [ ] Brief from §5 is filled out concretely
- [ ] Closing standard for X's sub-tasks is unambiguous
- [ ] X's expected duration < block's total duration

After spawning:

- [ ] X confirms reading AGENTS.md + ROADMAP block + MULTI_AGENT_PLAN section
- [ ] X claims block in ROADMAP marker (if first agent on the block)
- [ ] X begins work; commits stream into agent/X-v{Y}

When X's sub-task done:

- [ ] X opens PR → sprint/v{Y}
- [ ] Reviewer (peer agent or Nova) reviews per §3 two-tier review
- [ ] Merge into sprint branch
- [ ] X re-enters pool for next assignment

When ALL agents' sub-tasks on block v{Y} are merged:

- [ ] Bench gate run (§7)
- [ ] If gate passes: block-level PR → main → review → merge → tag
- [ ] If gate fails: diagnose, agent(s) fix, re-run gate

---

## 12. Status as of authoring (2026-05-19)

- **Active agents:** none yet (awaiting greenlight from Nova)
- **Next block to spawn:** v1.14.13, after PR #72 merges and roadmap status is updated
- **Recommended initial spawn:** Agents A, D, E, F (4-way parallel)
- **PR #72 (v1.14.12) status:** open, must merge before v1.14.13 starts
- **Sprint branch state:** `sprint/v1.14.13` open, currently 0 agents committing

**The promise:** every block ships at the standard in AGENTS.md §14. Coordinated across N agents. No loose ends.
