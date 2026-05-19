---
tags: [prose, prose/docs, prose/roadmap]
authored: 2026-05-19
author: Claude (father, full ownership per Nova directive)
supersedes:
  - docs/v1.9-v2.0-product-roadmap.md (archived)
  - docs/zaki-product-roadmap.md (archived)
binds_to: AGENTS.md §14 (Nullalis-grade standards)
---

# nullalis Roadmap — V1.14.13 → V2.0 → V-infinity

**Authored:** 2026-05-19 (post v1.14.12 — memory audit closed, PR #72 in review)
**Standard:** Swiss-watch build (`AGENTS.md` §14). No loose ends. No regressions. Bench-gated transitions.
**Operating loop:** plan → recon → fix → review per finding. Atomic commits. Bench gate per block.
**Versioning convention:** `v1.14.X` for patches within the current memory/extraction series. `v1.15+` for the next minor (τ-bench cycle). `v2.0` for commercial launch. `V-infinity` for the long arc.

---

## Where we are — code-truth state, 2026-05-19

| Layer | State | Evidence |
|---|---|---|
| Memory | Sound + audited | v1.14.12 closed 13 findings; TxnLease primitive; entity-node rendering |
| Extraction | Single funnel | V1.14.12 M1–M5 + Path A; 6 WriteOrigin variants; coverage filter live |
| Context | Byte-stable | iter18-20 (Phase A/B/C); 70/80/90 thresholds; anti-thrash |
| Approval | Closed | `approval_continues_turn=true`; regression test at root.zig:10711 |
| Subagent receive | Closed | TurnOutcome refactor + V1.14.4 booth-readiness |
| LoCoMo | 25/25 cold · 22-23/25 polluted | iter21 baseline |
| τ-bench | Not yet baselined | **Sprint v1.14.13 baseline** |

**Audit findings still open** (post-v1.14.12, captured by 3-agent file-by-file audit 2026-05-19): **67 total** — 9 HIGH, 31 MED, 27 LOW. Concentrated in: orphaned modules that were half-finished (`task_planner`, `narration`, `context_engine`, `tools/schema`), config zombies (Email/Teams/Nostr), false-confidence handlers (`handleReady`, `EMPTY_TURN_PLACEHOLDER`), aspirational prompt directives (F-A2).

**These are not "delete" candidates.** They are unfinished work (AGENTS.md §14.2 / §14.4). The roadmap below FINISHES them.

---

## Block legend

Each block has:
- **Version tag** (the git tag at block exit)
- **Theme** (one sentence)
- **Steps** (numbered, atomic — one per commit)
- **Bench gate** (the test that closes the block)
- **Estimated duration**
- **Dependencies** (prior blocks or external coordination)

A block does not "exit" until its bench gate passes. The next block does not start until the current one is tagged.

---

## v1.14.13 — "Establish τ-bench baseline + wire what's built"

**Theme:** Lock the execution-quality measurement before any code change. Then wire the orphans the original audit identified as half-finished.

**Why first:** Without τ-bench baseline we can't tell if subsequent work helps or harms execution quality. Same discipline LoCoMo gave us for memory.

**Steps:**

1. **τ-bench Airline harness** (`.spike/external/tau_bench/`)
   - Pull `tau-bench` package; identify 50 Airline tasks
   - Build adapter: `nullalis` gateway as the agent target, `tau-bench`'s user simulator + scorer unchanged
   - First baseline run → commit results as `iter22-tau-airline-baseline` in `.spike/results.tsv`
   - Triage failures into same 12-category breakdown as LoCoMo

2. **`tools/schema.zig` wired into providers**
   - Insert `cleanSchemaForProvider(strategy, schema)` at the tool-spec serialization boundary in `providers/*.zig`
   - Test: each provider's tool-spec output passes its strategy's filter
   - Unblocks Gemini support

3. **`task_planner.zig` + `narration.zig` paired wiring**
   - Add system-prompt directive: when user request requires multiple tool calls, emit `<task_plan>` XML
   - Wire `parseTaskPlan` into `root.zig` turn loop after first model response
   - Wire `NarrationObserver` to channel renderer (Telegram inline frames, frontend SSE event)
   - Test: synthetic 3-step task emits 3 narration frames

4. **F-A2 brain_graph directive stripped from system prompt**
   - 15-minute edit; ~180 tokens saved per turn (stable prefix)
   - Re-add only when F-A2.1 router classifier is built and bench-validated
   - Move F-A2.1 to deferred register

5. **False-confidence handler cluster** (audit Cluster B)
   - `gateway.zig::handleReady` — rewire `/ready` route through it OR delete handler + 7 tests (decision: rewire, tests already cover it)
   - `EMPTY_TURN_PLACEHOLDER` — remove the const + 8 archaeology references + the stale `observability.zig:87` doc
   - `BrowserTool` tool_description — strip the 4 unimplemented actions (`screenshot`/`click`/`type`/`scroll`); honest catalog
   - `predicateToSlotType` BIRTHDAY contradiction — fix docstring to match code

6. **`identity.zig` decision**
   - Keep as substrate for future persona-import feature (V-infinity pillar) → add `docs/deferred-register.md` entry + comment block in file linking to the deferred entry
   - OR delete with rationale (commit body names successor: SOUL.md + workspace markdown)
   - Nova decides; document either way

**Bench gate:**
- `zig build test` exit 0, 0 leaks
- LoCoMo cold + polluted ≥ v1.14.12 numbers (no regression)
- τ-bench Airline baseline committed to `.spike/results.tsv`
- Tag `v1.14.13`

**Duration:** 5–7 working days
**Dependencies:** PR #72 (`v1.14.12`) merged

---

## v1.14.14 — "ContextEngine migration"

**Theme:** Complete the lifecycle refactor started in iter18-20. Route `root.zig::turn()` through `ContextEngine.ingest/assemble/compact/afterTurn` so the 5,000-line turn loop becomes 4 testable phases.

**Why second:** This is the biggest payoff per LoC of any cleanup item. Today the iter20 70/80/90 threshold work + anti-thrash sits in a struct that's not called by production. Migration activates ~1K LoC of unused-but-correct code.

**Steps:**

1. **Phase: `ingest`** — extract memory-enrichment + history-prep block from `root.zig::turn()` (lines TBD) into `ContextEngine.ingest`. Bench gate: parity with prior turn output on canonical bench.

2. **Phase: `assemble`** — extract prompt-refresh + stable-prefix resolution into `ContextEngine.assemble`. Add the `prefix.stable_hash` diagnostic (already designed in iter18 plan, not landed). Bench gate: byte-stable hash equal across turns on multi-turn prompts (b16/b17).

3. **Phase: `compact`** — route the existing compaction trigger through `ContextEngine.compact` instead of inline. Activate the 70/80/90 thresholds from iter20. Bench gate: anti-thrash fires correctly on synthetic stress test.

4. **Phase: `afterTurn`** — checkpoint persistence + stats recording into `ContextEngine.afterTurn`. Bench gate: `.spike/runs/<ts>/stability.json` emitted with all four phase metrics.

5. **Cleanup** — `Agent.context_engine_state` field now consumed; `compaction_keep_recent` + `compaction_max_summary_chars` + `compaction_max_source_chars` move into `TokenBudgetPolicy` if not already there.

**Bench gate:**
- All previous gates + per-phase parity tests
- `root.zig::turn()` is materially shorter (target: 30% reduction)
- LoCoMo cold + polluted holds
- τ-bench Airline holds
- Tag `v1.14.14`

**Duration:** 7–10 working days (this is the biggest block in V1.14.x)
**Dependencies:** v1.14.13

---

## v1.14.15 — "Channels finish: Email"

**Theme:** First of three channel-completion blocks. Email is widest user reach.

**Steps:**

1. IMAP poller — mirror `src/channels/telegram.zig` inbound pattern; pull from `imap.config` per user
2. SMTP send path — wire `EmailChannel.send` through outbound message tool
3. Per-user secret resolution — `EmailConfig.credentials` follows the per-user secret-vault pattern
4. `daemon.zig` wiring — add Email to the channel loop list
5. `channel_loop.zig` thread bind
6. Identity binding — link `emailPrimary()` to actual `channels/email.zig`
7. Tests — auth, send, listen, malformed-message handling

**Bench gate:**
- Send + receive end-to-end on a test mailbox
- LoCoMo + τ-bench hold
- Tag `v1.14.15`

**Duration:** 3 working days
**Dependencies:** v1.14.14

---

## v1.14.16 — "Channels finish: Teams"

**Theme:** Enterprise wedge. Bot Framework webhook-based.

**Steps:**

1. Teams Bot Framework webhook handler in `gateway.zig`
2. Activity JSON parsing (`channels/teams.zig` already has scaffold)
3. Outbound message via Bot Framework `replyToActivity` endpoint
4. `daemon.zig` + `channel_loop.zig` wiring
5. Adaptive Cards rendering for AskUserQuestion (forward-compat with v1.16)
6. Tests

**Bench gate:**
- Send + receive on a Teams app registration
- LoCoMo + τ-bench hold
- Tag `v1.14.16`

**Duration:** 3 working days
**Dependencies:** v1.14.15

---

## v1.14.17 — "Channels finish: Nostr"

**Theme:** V-infinity differentiation. Censorship-resistant relay.

**Steps:**

1. Nostr websocket relay client
2. NIP-04 DM encryption
3. `channels/nostr.zig` listen + send
4. Per-user `nsec` secret in vault
5. `daemon.zig` + `channel_loop.zig` wiring
6. Tests

**Bench gate:**
- Send + receive on a Nostr relay (Damus, primal.net)
- LoCoMo + τ-bench hold
- Tag `v1.14.17`

**Duration:** 2 working days
**Dependencies:** v1.14.16

---

## v1.14.18 — "Audit MED-tier sweep"

**Theme:** Close the remaining 31 MED findings from the 2026-05-19 audit.

**Steps (grouped, each is one or more commits per AGENTS.md §14.1):**

1. **QMD session export wiring** (`memory/retrieval/qmd.zig::exportSessions` + `pruneExportedSessions`) — invoke at session-end OR delete config flag with rationale
2. **Composio error sanitizer wiring** — `sanitizeErrorMessage` + `extractApiErrorMessage` wired into ComposioTool.execute error path (security: token leak risk closed)
3. **CLI honesty pass** — `nullalis channel add/remove`, `models benchmark`, `gateway --role broker/user_cell`, onboard wizard channel branch — ship or remove subcommand registration
4. **Stale-comment + dead-branch sweep** — `compaction.zig` recovery thresholds, `extraction_persist.zig` deriveEntityKey docstring, `snapshot.zig` valid_to lossy round-trip, `legacy_semantic_cache_bridge`, F-A2 prompt directive followup
5. **Vector chunker decision** — `memory/vector/chunker.zig::chunkMarkdown` orphan: confirm V1.14.8 extraction switched away, delete with rationale OR document as legacy
6. **Legacy hybrid-merge decision** — `memory/vector/math.zig::hybridMerge` superseded by RRF+MMR; delete with rationale

**Bench gate:**
- All MED findings either closed (commit reference) OR moved to `docs/deferred-register.md` with rationale + ETA
- LoCoMo + τ-bench hold
- Tag `v1.14.18`

**Duration:** 5 working days
**Dependencies:** v1.14.17

---

## v1.15.0 — "τ-bench iteration sprint (Karpathy loop)"

**Theme:** Now that the foundation is clean, drive τ-bench Airline numbers up the same way iter1-21 drove LoCoMo. Hypothesize → iterate → bench → keep or discard.

**Why now:** Foundation work is done; we can attribute deltas correctly.

**Steps:**

Same iteration shape as `.spike/results.tsv` LoCoMo work. Each iter is one or more atomic commits:

1. Baseline analysis — read iter22 failures, categorize root causes
2. iter23: fix lowest-hanging category (e.g., tool selection)
3. iter24: dialogue grounding fixes
4. iter25: policy adherence
5. iter26: multi-turn coherence
6. iter27: re-baseline + summary
7. Continue until pass@1 plateaus

Target: ≥ 60% pass@1 on Airline (industry SOTA reference: tau-bench paper claims ~50-70% for the best models with their built-in agents; we should land at or above that with model-agnostic infrastructure).

**Bench gate:**
- τ-bench Airline pass@1 measurably improved vs v1.14.13 baseline (target ≥ +15 percentage points)
- LoCoMo holds (no memory regression)
- Tag `v1.15.0`

**Duration:** 10–15 working days (iteration is open-ended, gated by plateau detection)
**Dependencies:** v1.14.18

---

## v1.16.0 — "Frontend integration wave" (requires zaki-prod coordination)

**Theme:** The deferred backend features finally meet their renderers.

**Steps:**

1. **UI autonomy toggle** — zaki-prod frontend → `config.autonomy` setter, surfaces backend's `.full` / `.supervised` modes
2. **AskUserQuestion tool + renderer** — backend tool (~50 LoC) + Telegram inline keyboards + frontend multi-choice component (built on top of v1.14.16 Teams Adaptive Cards groundwork)
3. **Mode toggle UI** — fast/balanced/deep presets (currently config-only, per `project_modes_need_post_context_v2_pass`)
4. **Brain graph entity-node styling** — frontend renders the `kind="entity"` nodes from v1.14.12 Finding 2 distinctly from memory rows
5. **Memory inspector** — drilldown UI on `/brain/memory/{key}` (backend already exposes; frontend renders)

**Bench gate:**
- Each feature has a manual E2E walkthrough
- LoCoMo + τ-bench hold
- Tag `v1.16.0`

**Duration:** 10–14 working days (paced by zaki-prod cycle)
**Dependencies:** v1.15.0 + zaki-prod frontend availability

---

## v1.17.0 — "Native connectors phase 1"

**Theme:** Replace Composio for the top 3-5 integrations with per-user OAuth flows.

**Steps:**

1. OAuth flow scaffolding in `gateway.zig` (callback URL + state secret + token vault)
2. Connector 1: Calendar (Google + Apple via CalDAV)
3. Connector 2: Gmail
4. Connector 3: Slack
5. Connector 4: GitHub (probably; depends on Nova's user-data signal)
6. Connector 5: Linear (probably; depends on Nova's user-data signal)
7. Composio stays as fallback for long-tail integrations
8. Connection management UI in zaki-prod

**Bench gate:**
- Each connector live with per-user auth
- Composio call volume measurably down
- LoCoMo + τ-bench hold
- Tag `v1.17.0`

**Duration:** 10–14 working days
**Dependencies:** v1.16.0 (needs the connection management UI)

---

## v1.18.0 — "Per-cell pod canary deploy"

**Theme:** First production cell on the per-cell-pod architecture. zaki-infra work.

**Steps:**

1. Pre-deploy: validate canary tenant has clean per-cell schema + secrets
2. Helm chart application (existing reference in `claude-code/helm/`)
3. PgBouncer wiring (the entrypoint fix from `codex/nullalis-user-cell-pgbouncer-entrypoint` branch)
4. Workspace contract validation (`codex/nullalis-user-cell-workspace-contract`)
5. Routing: per-cell URL routing in zaki-prod
6. Observability: per-cell metrics → Grafana
7. 7-day soak before second cell

**Bench gate:**
- Canary cell runs production traffic for 7 days, zero P1 incidents
- LoCoMo + τ-bench hold against canary
- Tag `v1.18.0`

**Duration:** 5 working days deploy + 7 days soak
**Dependencies:** v1.17.0

---

## v1.19.0 — "Observability + SRE maturity"

**Theme:** The dashboards and budgets that turn nullalis into a real operated system.

**Steps:**

1. Grafana dashboards: per-tenant latency, per-tool cost, per-provider error rate
2. Per-tenant cost tracking (Kimi calls, Together calls, embedding calls, etc.)
3. Latency budgets per turn phase (the `memory_enrich` 900ms variance from `project_agent_turn_audit_followups`)
4. Background scheduler for memory hygiene (the lifecycle gap from `project_lifecycle_investigation_2026_04_20`)
5. Alerting: P95 latency, error rate, cost-per-tenant outliers

**Bench gate:**
- Dashboards live, alerts firing on synthetic incidents
- LoCoMo + τ-bench hold
- Tag `v1.19.0`

**Duration:** 5–7 working days
**Dependencies:** v1.18.0

---

## v2.0.0 — "Commercial launch — payment + onboarding + first 100 paying users"

**Theme:** The transition from "technical product" to "commercial product." Strategy is Nova's; this block holds the slots and dependencies.

**Steps (deferred to payment-design discussion per Nova):**

1. Payment provider integration (Stripe / Paddle / Lemonsqueezy — Nova's choice)
2. Pricing model implementation (per-cell / per-message / per-tool-call / token-metered — Nova's choice)
3. Trial → paid flow
4. Multi-tenant billing reconciliation
5. Onboarding flow refresh (post-AGENTS.md §14 standards)
6. First 100 paying users acquisition + retention measurement

**Bench gate:**
- ≥ 100 paying users
- ≥ 95% MRR retention month-over-month
- Tag `v2.0.0`

**Duration:** open — paced by payment-design decisions
**Dependencies:** v1.19.0 + payment design lock-in with Nova

---

## V-infinity arc — sprints 4-12 of the pillar program

After v2.0, the 12 V-infinity pillars get one sprint each. Pillar selection biased toward Nova's actual market signal, not feature-completion-for-its-own-sake.

Candidate pillar order (Nova-revisable):

1. **Vision / multimodal inbound** (MaixCam differentiator)
2. **Voice** (VibeVoice bookmark; V2 voice surface)
3. **Skills / self-evolving** (OpenSpace MCP adoption candidate)
4. Persona import/export (the `identity.zig` substrate, if kept)
5. Plugin/MCP marketplace (if `OpenSpace` proves out)
6. Autonomy escalation graph (full/supervised/locked transitions with user signal)
7. Cross-agent collaboration (sub-agent contracts beyond delegate.zig)
8. Long-horizon planning (week+ task tracking, not just per-turn)
9. Verifiable execution (signed tool outputs, audit trail)
10. Coding pillar (GitNexus bookmark, SWE-bench integration)
11. Multi-agent voice rooms (real-time conversation)
12. The "secret weapon" — TBD by Nova

**Critical sequencing rule:** never start a new pillar until the previous one has shipped to users AND received ≥ 1 cycle of real feedback. Karpathy keep/discard discipline.

---

## What this roadmap is NOT

- A guarantee of velocity. Each block has duration estimates; they're directional.
- Set in stone. Nova revises freely. Documented changes become a new authored ROADMAP commit.
- Independent of the standards. Every block obeys AGENTS.md §14 (Swiss-watch). If a block ships without obeying, it's reverted, not merged.

## What this roadmap IS

- The contract for the next 6-12 months.
- The mechanism by which "nothing gets left behind."
- The path from "technically sound foundation" to "commercial product people pay for."
- The way the standards in AGENTS.md become real outcomes instead of just rules.

---

## Operating procedure for this document

- One block in flight at a time. Mark its status in the block heading: `→ IN FLIGHT`, `→ BENCH GATE`, `→ TAGGED`, `→ DEFERRED`.
- When a block tags, the next block opens. Mark prior block `TAGGED v1.X.X (yyyy-mm-dd)`.
- Each block's bench gate is the closure event. Until gate passes, work continues; no skipping ahead.
- All changes to this file are commits with author + reason.
- Roadmap is bound to `AGENTS.md §14`. If standards change, roadmap re-anchors.

---

## Status as of authoring (2026-05-19)

- **v1.14.12** — TAGGED, PR #72 open for review
- **v1.14.13** — NEXT (this is the active sprint)
- Everything after — planned, awaiting v1.14.13 close

**The promise:** every block ships at the standard in AGENTS.md §14. Or it doesn't ship.
