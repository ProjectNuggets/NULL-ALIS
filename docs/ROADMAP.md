---
tags: [prose, prose/docs, prose/roadmap]
authored: 2026-05-19
reconciled: 2026-05-22
author: Claude (father, full ownership per Nova directive)
status: CANONICAL — the single roadmap/plan/map doc. No other plan doc exists.
supersedes:
  - docs/v1.9-v2.0-product-roadmap.md (archived)
  - docs/zaki-product-roadmap.md (archived)
  - .planning/ROADMAP.md (GSD v1.0-sota roadmap — archived 2026-05-22)
  - the "Sprints 0-4" task-list re-cut (folded into "Near-term road" below)
  - 8 FOLD docs reconciled here 2026-05-22 (see docs/archive/2026-05-22/)
pairs_with: STATUS.md (the state doc — "where we are now"; this is "where we go")
binds_to: AGENTS.md §14 (Nullalis-grade standards)
---

# nullalis Roadmap — the canonical map

**THE single source of truth for the plan.** STATUS.md is the state doc (current code truth); this is the plan doc (the road ahead). There is no other roadmap, sprint-plan, or map doc — every prior one is archived or folded here (reconcile 2026-05-22).

**Standard:** Swiss-watch build (`AGENTS.md` §14). No loose ends. No regressions. Bench-gated transitions.
**Operating loop:** plan → recon → fix → review per finding. Atomic commits. Bench gate per block.
**Versioning:** `v1.14.X` patches within the memory/extraction series · `v1.15+` next minor · `v2.0` commercial launch · `V-infinity` the long arc.

**Standing rules** (carried from the retired `.planning/ROADMAP.md`, still binding):
1. **UI/UX activation is mandatory per shipped feature** — a backend capability with no surface is not "done."
2. **Multi-session by default** — the agent is a persistent brain, not a per-conversation tool; design for memory across sessions.
3. **Code truth beats docs** — when a doc disagrees with the code, the code wins; fix the doc (§14.9).

---

## Where we are — code-truth state, 2026-05-22

Tags: `v1.14.12` · `v1.14.13` · `v1.14.14` · `v1.14.18` (v1.14.18-A/B block) · `v1.14.19` (memory-pipeline repair + config-control-plane hardening) · `v1.14.20` (Sprint 2 — Channels V1 + MCP V1, the A2A core) — all tagged 2026-05-22. `main` is at `v1.14.20`.

| Layer | State | Evidence |
|---|---|---|
| Memory pipeline | **Repaired + verified end-to-end (2026-05-22)** | 4 stacked regressions fixed (findings #1–#4); Pass A/C extract, hydration + summaries persist |
| Extraction | Single funnel, live | `extractAtBoundary`; boundary extractor now on a matched sidecar pair |
| Compaction | Live (was silently OFF ~2 days) | `compact_context` default restored true; Pass A/C fire |
| Config control plane | **Hardened** | Strict tenant allowlist; comptime exhaustiveness guard — Class-D bugs can't merge |
| Context (ContextEngine) | Migrated (v1.14.14) | `ContextEngine.compact` is the live path |
| Approval / Subagent receive | Closed | `approval_continues_turn=true`; TurnOutcome refactor |
| Architecture | **Shared multi-tenant runtime** (decision 2026-05-22) | one pod, many users; per-cell pods deferred to v1.18 |
| Channels / MCP | **Sprint 2 shipped (v1.14.20)** | Discord+Slack finished, Email+Teams activated; MCP client hardened + MCP server built (A2A core). Memory-over-MCP + Nostr deferred |
| LoCoMo / τ-bench | **No clean K2.6 number** | the ~94% LoCoMo conv-0 was long-context recall on a then-dead pipeline; re-bench deferred (must be a multi-session / over-window test) |

**What 2026-05-19 → 2026-05-22 actually did:** v1.14.13 + v1.14.14 tagged; the channel blocks (v1.14.15/.16/.17 Email/Teams/Nostr) were **deferred**, re-cut as "Sprint 2"; v1.14.18-A/B (learning loop) merged. Then an **unplanned fire**: the memory pipeline was found silently dead (4 config/wiring regressions) and repaired, the config control plane was audited + hardened — closed as **v1.14.19** (`docs/CONFIG_CONTROL_PLANE_AUDIT.md`). Then **Sprint 2 shipped** as 4 parallel agents — Discord/Slack finished, Email/Teams activated, MCP client hardened, MCP server built — merged, independently audited, fix-forward'd, closed as **v1.14.20**.

**Audit ledger:** `docs/audits/2026-05-19-file-by-file-audit-ledger.md` remains the active control ledger (67 findings: 9 HIGH / 31 MED / 27 LOW — half-finished orphans, config zombies, false-confidence handlers). No block tags until its rows close. **These are unfinished work, not delete candidates (§14.2/§14.4) — the blocks below finish them.**

---

## Near-term road — the Sprints (P1)

The active near-term sequence. "Sprints 0–4" was a tactical re-cut; reconciled here, it maps onto the version blocks:

| Sprint | Scope | Maps to | State |
|---|---|---|---|
| Sprint 0 | Multimodal — native image + video | (PR #97) | ✅ done |
| Sprint 1 | Learning-loop activation + §14.10 audit | v1.14.18-A/B (PR #87/#98) | ✅ done |
| — | **Memory-pipeline repair + config hardening** | unplanned block (this session) | ✅ done 2026-05-22 |
| **Sprint 2** | **Channels V1 + MCP V1** | v1.14.15 Email · .16 Teams + MCP → **v1.14.20** | **✅ done 2026-05-22** |
| **Sprint 3** | **Universal API Connector** (OpenAPI → agent tools) | new — slots before v1.17 connectors; see block below | **🔨 IN PROGRESS 2026-05-22** |
| **Sprint 4** | **UI/UX activation + feature-freeze** | overlaps v1.16 frontend wave | **P1** |

After the Sprints, the version blocks below carry the road to v2.0. **Deferred follow-ups** (tracked in `docs/CONFIG_CONTROL_PLANE_AUDIT.md`, not lost): `network` config parser+wiring · `agent.extraction` parse-or-delete · sentinel-collision profile pattern · streaming-path error mapping. **LoCoMo Cat-3 lift** (the R6/R3/R4/R2 lever set — temporal/inference 56–77% → 80%+) is folded into the v1.15.0 bench-iteration block.

**Folded from retired plan docs (2026-05-22 reconcile)** — captured here so nothing is lost when the source docs archive: the **F-A2.1 / F-T1 / F-PA1** fixes are **verified shipped 2026-05-22** — F-A2.1 via prompt-level `brain_graph` routing for entity questions (`prompt.zig`), F-T1 via `elideUnverifiedHistory` (`root.zig:5204`), F-PA1 via `archiveDroppedMessages` (Pass A archives to `compaction_dropped/` before deletion). The **cognitive-layers track** (Working / Procedural / Dream-consolidation memory — partly landed, the v1.14.21 sleep cycle is its home) and the **SOTA append-only context end-state** (ContextEngine migration at v1.14.14 covered the bulk) remain the open carry-forward items.

**Dangling references:** this doc cites `docs/capacity-model.md`, `docs/dr-runbook.md`, `docs/unit-economics-2026-XX-XX.md` — those are *outputs* of blocks v1.18/v1.18.5/v1.19.7, authored when those blocks run, not pre-existing files.

---

## Sprint 3 — "Universal API Connector (OpenAPI → agent tools)" → IN PROGRESS

**Theme:** Point nullalis at any API's OpenAPI 3.x spec → the agent gains structured, auth-handled access to that API. Zero per-API code, zero third-party platform, no MCP server required. The no-dependency long-tail companion to v1.17's hand-built OAuth connectors (deferred) and to Composio.

**Why this shape (research-backed, 2026-05-22):** the industry standardized on "OpenAPI spec → agent tools" (Google ADK, Gentoro, Speakeasy, Stainless). The documented anti-pattern is 1:1 endpoint→tool mapping — it blows the context window, confuses tool selection, and forces the LLM to act as a dumb REST client. nullalis sidesteps it with a `list/describe/invoke` **meta-tool**: the agent discovers operations and invokes on demand; its own intelligence does selection at call-time. Smaller build, robust at any spec size.

**Scope line:** static-credential auth only (API key / bearer / basic) — OAuth2 flows are v1.17's job. Operator-registered specs only — no runtime arbitrary-URL ingestion in V1 (exfiltration surface). OpenAPI 3.x JSON; Swagger 2.0 deferred. The API half of "universal access" — the CLI / arbitrary-environment half is deferred to the per-cell pod (v1.18) / the installable app.

**Steps:**

1. `src/openapi/` — OpenAPI 3.x parser: fetch (URL/file), parse, resolve `$ref`, extract `OperationSpec[]` (id, method, path, params, requestBody, per-op security) + `securitySchemes` + `servers`. Pure, unit-tested.
2. Config — `api_specs` block (`config_types` + `config_parse` + the operator-owned allowlist + the comptime exhaustiveness table): `{ id, spec_url|spec_path, base_url?, auth_ref, mode: read_only|read_write }`. Operator-owned, NOT tenant-settable.
3. Spec registry/loader — load + parse each configured spec at startup; fail-soft per spec (a bad spec logs + skips, never kills startup).
4. The `openapi` tool — modes `list` / `describe` / `invoke`. `invoke` builds the request from the operation + args, applies auth, enforces the per-spec mode, calls via `http_native` + `net_security` egress filtering, response size-capped.
5. Auth — resolve `securityScheme` → credential from the encrypted vault by `auth_ref`, injected at the tool layer, never in the model's context. OAuth2 → explicit "use v1.17 connectors" error.
6. Approval — classify each operation at invoke-time (GET/HEAD → `read_only` metadata · POST/PUT/PATCH/DELETE → `mutating`) and feed the existing `ApprovalPolicy.forTool` engine: reads auto-run; writes → `confirm_once` in supervised. Hard gate above the mode: a spec not opted into `read_write` cannot write regardless of approval level. Thin-spec guardrail: on a write the agent surfaces the request it built for approval before firing.
7. Tests + operator doc (`docs/openapi-access.md`) + a manual E2E walkthrough against a real public spec (httpbin / GitHub API).

**Bench gate:**
- E2E: register a real public OpenAPI spec, agent `list` → `describe` → `invoke` a GET; a write op triggers `confirm_once` in supervised mode
- Canonical CI gate green
- LoCoMo + τ-bench hold
- Tag at block exit (Nova's call — likely the v1.14.2x line)

**Duration:** 3–4 working days
**Dependencies:** Sprint 2 — the encrypted vault, the MCP/tool machinery, and the `ApprovalPolicy` engine are all already in place.

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

## v1.14.13 — "Sandbox fail-closed + τ-bench baseline + wire what's built" → TAGGED v1.14.13

**Theme:** Close the sandbox fail-open security hole FIRST (3-4 hours). Then lock the execution-quality measurement. Then wire the orphans the audit identified as half-finished.

**Why first:** V8 (sandbox fail-open) is a security blocker — a misconfigured prod deploy with `fail_open_on_dev=true` runs tools UNSANDBOXED. This is non-negotiable to fix before any other code lands. Then τ-bench baseline so subsequent work has signal.

**Steps:**

0. **V8 — Sandbox fail-closed by default** (3-4 hours, MUST come first)
   - Remove `fail_open_on_dev` silent passthrough at `tool_sandbox_v1.zig:162-168`
   - Replacement: require both env var `NULLALIS_ALLOW_UNSANDBOXED_DEV=1` AND `exec_cfg.fail_open_on_dev=true` AND `log.err` (not warn) to fall through
   - Startup banner if running with `NULLALIS_ALLOW_UNSANDBOXED_DEV=1`
   - New test: `tests/security/sandbox_fail_closed_test.zig` proving missing backend → `error.SandboxUnavailable`, never raw argv
   - Audit deployment configs: confirm no production tenant relies on the old behavior
   - Commit: `fix(security): V1.14.9 — sandbox fail closed by default`

0.5. **B1 — AGENTS.md contradiction fix** (5 minutes)
   - Historical issue: `AGENTS.md §4` referenced `src/skillforge.zig`, which does not exist at HEAD
   - Correct the map to name `src/skills.zig` as the active successor and keep archived `skillforge` mentions out of active protocol
   - Block-internal commit: cleanup, no functional change

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
   - Keep the existing system-prompt directive honest: `prompt.zig` already emits `<task_plan>` instructions, but runtime parsing is not wired
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

7. **B2 — Latency bench gate scaffold** (~2 hours)
   - `SLO.md` defines p50 TTFT ≤ 1.5s, p95 ≤ 4s; `.spike/run.sh` currently only emits `mean_latency_ms`
   - Extend `.spike/run.sh` to emit p50/p95 TTFT from SSE event timestamps
   - Add bench gate criterion to every subsequent block: "p95 TTFT ≤ 4.0s" (the SLO commitment)
   - New `.spike/results.tsv` columns: `p50_ttft_ms`, `p95_ttft_ms`
   - Without this we can't catch latency regressions until customers complain

8. **B13 — Test RSS budget remediation** (~0.5-1 day triage, fix size TBD)
   - AGENTS.md budget is <50 MB MaxRSS during `zig build test`; current HEAD reports 61M
   - Triage whether the regression is test fixture growth, sqlite build shape, or runtime allocation drift
   - Fix if cheap; otherwise document the measured baseline + root cause in this ledger and make the next budget explicit

**Bench gate:**
- `zig build test` exit 0, 0 leaks
- LoCoMo cold + polluted ≥ v1.14.12 numbers (no regression)
- τ-bench Airline baseline committed to `.spike/results.tsv`
- p95 TTFT ≤ 4.0s on canonical bench (new gate from B2)
- All 7 audit Cluster A orphans either wired OR documented per AGENTS.md §14.4
- Test MaxRSS budget either back under 50 MB OR documented with root cause + accepted replacement budget
- Tag `v1.14.13`

**Duration:** 5–7 working days
**Dependencies:** PR #72 (`v1.14.12`) merged

---

## v1.14.14 — "ContextEngine migration" → TAGGED v1.14.14

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

## v1.14.15 — "Channels finish: Email" → DELIVERED via Sprint 2 → v1.14.20

**DELIVERED 2026-05-22 (PR #100):** Email activated as a `send_only` channel through `channel_manager`'s generic listener path. SMTP outbound was live; inbound IMAP was deferred at that point.

**COMPLETED 2026-05-22 (Slice 2):** Email is now a genuine bidirectional `polling` channel. Inbound IMAP-over-TLS client built in `src/channels/email.zig` (`pollMessages`: implicit-TLS connect to port 993, LOGIN → SELECT → UID SEARCH UNSEEN → UID FETCH, RFC 2047 + HTML-strip parsing, `allow_from` allowlist filter, `BoundedSeenSet` de-dup, `\Seen` marking). Outbound SMTP TLS fixed: implicit TLS on 465, STARTTLS on 587/other, plaintext only when `smtp_tls=false`. `channel_loop.runEmailLoop` drives the poll thread; `channel_catalog` listener_mode flipped `send_only` → `polling`. Discord + Slack were also finished in an earlier sprint (PR #99) — echo-loop fix, system-message filtering, markdown conversion.

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

## v1.14.16 — "Channels finish: Teams" → DELIVERED via Sprint 2 → v1.14.20

**DELIVERED 2026-05-22 (PR #100):** Teams fully wired — inbound Bot Framework Activities arrive at `POST /api/messages` (`handleTeamsWebhookRoute` in `gateway.zig`, constant-time `webhook_secret` gate), outbound + typing via the Bot Framework REST API; registered through `channel_manager`'s `webhook_only` path. Plus MCP V1 (PR #101 server, #102 client) shipped under the same sprint.

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

## v1.14.17 — "Channels finish: Nostr" → DEFERRED (no user demand)

**DEFERRED 2026-05-22:** Sprint 2 explicitly scoped Nostr out — no current user uses Nostr, and the enterprise/consumer channels (Email/Teams/Discord/Slack) carry the launch. The block stays here for when censorship-resistant relay becomes a differentiator; it is NOT a v1.14.20 deliverable.

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

## v1.14.18 — "Audit MED-tier sweep + state/memory polish" → PLANNED

**Theme:** Close the remaining 31 MED findings from the 2026-05-19 audit. ALSO closes V6 (state.zig deprecation), V7 (markdown mirror opt-in), and V4 (subagent ledger bridge default-on) from the architectural-debt audit.

**Steps (grouped, each is one or more commits per AGENTS.md §14.1):**

1. **QMD session export wiring** (`memory/retrieval/qmd.zig::exportSessions` + `pruneExportedSessions`) — invoke at session-end OR delete config flag with rationale
2. **Composio error sanitizer wiring** — `sanitizeErrorMessage` + `extractApiErrorMessage` wired into ComposioTool.execute error path (security: token leak risk closed)
3. **CLI honesty pass** — `nullalis channel add/remove`, `models benchmark`, `gateway --role broker/user_cell`, onboard wizard channel branch — ship or remove subcommand registration
4. **Stale-comment + dead-branch sweep** — `compaction.zig` recovery thresholds, `extraction_persist.zig` deriveEntityKey docstring, `snapshot.zig` valid_to lossy round-trip, `legacy_semantic_cache_bridge`, F-A2 prompt directive followup
5. **Vector chunker decision** — `memory/vector/chunker.zig::chunkMarkdown` orphan: confirm V1.14.8 extraction switched away, delete with rationale OR document as legacy
6. **Legacy hybrid-merge decision** — `memory/vector/math.zig::hybridMerge` superseded by RRF+MMR; delete with rationale
7. **V4 — Subagent ledger bridge default-on**
   - Audit every `SubagentManager` construction; find `task_delivery = null` usages
   - Make bridge default-on; constructors without `task_delivery` get a default singleton
   - Startup warning if `task_delivery` is nil at runtime
   - Plan: remove `?` from field type in v1.15+ (deferred to follow-up)
   - Test: `tests/runtime/task_lifecycle_test.zig` — subagent spawn → ledger has entry → completion → ledger reflects
8. **V6 — state.zig deprecation path**
   - Audit every read/write to `state.zig`; list callers
   - Add deprecation warnings at every call site
   - Startup check: if `~/.nullalis/state.json` exists AND Postgres configured → loud migration prompt
   - Build `scripts/migrate-state-to-postgres.zig` utility (idempotent)
   - Gate `state.zig` behind `--allow-legacy-state` CLI flag, default refuse
9. **V7 — Markdown mirror opt-in**
   - Refactor `zaki_dual.zig` → eliminate markdown mirror by default
   - Add `--enable-markdown-mirror` opt-in flag for operators who rely on it
   - Rename `zaki_dual.zig` → `zaki_postgres.zig` (the "dual" name is the architecture smell)
   - Health check: if mirror enabled, log mirror-write latency / failure rate
   - Test: write a memory → only Postgres row exists → no markdown file unless flag set

10. **B8 — Test coverage audit (one-off)**
    - Integrate `kcov` or equivalent against `zig build test` binary
    - Generate per-file coverage report → publish to `.spike/coverage/<ts>/`
    - Surface untested production paths (the `handleReady` pattern — 7 tests, 0 prod callers)
    - One-off audit; not a recurring gate (too slow). Re-run quarterly.

**Bench gate:**
- All 67 file-by-file audit findings + V4 + V6 + V7 either closed (commit reference) OR moved to `docs/deferred-register.md` with rationale + ETA
- LoCoMo + τ-bench hold
- p95 TTFT ≤ 4.0s
- Coverage report published
- Tag `v1.14.18`

**Duration:** 8-9 working days (added V4/V6/V7 + B8 coverage audit)
**Dependencies:** v1.14.17

---

## v1.14.18-B — "Learning loop closure + self-knowledge" → TAGGED v1.14.18 (covers A+B)

**Theme:** Close the latent-value gaps surfaced by the 2026-05-20 post-v1.14.14 activation
audit (`docs/audits/2026-05-20-v1.14.14-activation-audit.md`). v1.14.18-A (Agent E) gives
nullalis goal-loop reflection + procedural memory capture; v1.14.18-B persists that
reflection across sessions, surfaces nullalis's own bench self-knowledge, and adds the
first cross-layer memory promotion rule.

**Why this exists:** AGENTS.md §14.10 audit-discipline pattern produced this block.
Without it, ~40% of v1.14.13 + v1.14.14 + v1.14.18-A combined value would have stayed
latent (events firing, no read-back loop; reflection generated, no storage; bench data
exists, agent doesn't see it).

**Steps (each atomic per §14.1):**

1. **G5 REFLECTION-STORE** — Agent E's reflection trail (turn-ephemeral in v1.14.18-A)
   writes to `skill_executions.assumptions_made_json` at session-end. Loop closes; sessions
   compound learning. File: new `src/agent/reflection.zig` (extract from `goal_loop.zig`).
   Owner: Agent E (already in goal-loop context).

2. **G3 NARRATION-AS-CONTEXT** — Iteration-start prompt injection: last 3 narration events
   become `<recent_thoughts>` volatile-prompt block. Agent sees its own thinking trail
   as feedback. File: extend `src/agent/narration.zig` with `recallRecent(N)` + wire at
   ContextEngine.assemble entry. Owner: Agent G (already in narration + ContextEngine).

3. **G7 BENCH-SELF-KNOWLEDGE** — Read `.spike/results.tsv` last 3 rows + LoCoMo
   per-category latest. Surface as `<known_weakness>` volatile-prompt block. Agent reads
   its own bench data and self-adjusts. File: new `src/agent/bench_self.zig`.
   Owner: Agent E or fresh.

4. **G16 WM-CROSS-SESSION** — At session-end, promote high-importance `active_goal` +
   `decision` slots to durable_facts with `attribute=transient_goal`. Recall at
   session-start via existing memory_loader path. File: new `src/agent/promotion.zig`
   (first concrete cross-layer promotion rule; foundation for G6 broader graph in v1.14.21).
   Owner: Agent G (already in working_memory pipeline).

5. **G19 DAEMON-PROMPT-HONESTY** — Either implement the "nightly summaries" prompt promise
   in `daemon.zig:3903` OR strip the prompt line per §14.6 honest-config. Recommend strip
   in this block; the actual nightly summaries land in v1.14.21 sleep cycle. Owner: either.

**Repo structure additions (locked per CTO/repo-designer review):**
- `src/agent/reflection.zig` — standalone module for the reflection trail
- `src/agent/bench_self.zig` — agent's self-knowledge from .spike/results.tsv
- `src/agent/promotion.zig` — explicit memory layer promotion rules

**Bench gate (after v1.14.18-A and v1.14.18-B both land):**
- LoCoMo overall ≥ 0.78 (no regression vs v1.14.14 baseline 0.80)
- LoCoMo Cat 3 ≥ 0.45 (v1.14.18-A goal-loop sets baseline; G3 narration-as-context + G5
  reflection-storage compound on top)
- V-inf polluted ≥ 0.72
- Production postgres: `skill_executions` populating AND `durable_facts.attribute=transient_goal`
  rows appearing across sessions (proves G16 works end-to-end)
- Postgres: `<known_weakness>` block populated from real bench data (proves G7 wiring)

**Duration:** 6-7 working days, 1-2 agents in parallel (E does G5 + G7; G does G3 + G16 + G19).
**Dependencies:** v1.14.18-A (Agent E's goal-loop + procedural memory capture must be in place).

---

## v1.14.21 — "Sleep cycle / offline self-improvement (Voyager-class)" → PLANNED

*(Renumbered from v1.14.19 on the 2026-05-22 reconcile — .19 and .20 were consumed by the memory-pipeline-repair and Sprint 2 blocks.)*

**Theme:** Turn the existing 12h hygiene cadence into a Voyager-style offline self-improvement
loop. Compound learning across sessions during agent downtime. Replaces the "A/B prompt
testing" approach with the self-improvement-from-real-data approach (no synthetic dual-runs;
the agent learns from its actual usage).

**Why this is SOTA:**
- Voyager (Wang et al., NeurIPS 2023) — skill library accumulates over time; agent gets
  better with use
- Reflexion (Shinn et al., NeurIPS 2023) — negative-example storage prevents repeating
  failed patterns
- mem0 memory consolidation — semantic dedup keeps long-tail memory tractable
- The sleep cycle is the substrate for all three

**Existing plumbing this leverages:**
- `src/memory/lifecycle/hygiene.zig` — 12h cadence already running; extend with consolidation
- `src/agent/community_pipeline.zig::recomputeCommunitiesForUser` — exists, no scheduler
- `src/agent/procedural_memory.zig` — captures traces; v1.14.18-A makes it actually populate

**Steps:**

1. **SC1 SKILL-CONSOLIDATION** — Every cycle, scan `skill_executions` rows added since last
   consolidation. Identify patterns with `outcome_quality ≥ 0.8`. Distill as `durable_facts`
   with predicate=`LEARNED_PATTERN` (e.g., "for entity-question goals, the memory_recall →
   brain_graph chain succeeded 8/10 times"). File: new
   `src/memory/lifecycle/skill_consolidation.zig`.

2. **SC2 NEGATIVE-EXAMPLES** — Same pass captures failures (`outcome_quality ≤ 0.3`) as
   `durable_facts` with predicate=`AVOID_PATTERN` (e.g., "for booking goals when reservation
   already cancelled, transfer_to_human path failed 5/5 times — try alternative tool
   sequence first"). Reflexion pattern.

3. **SC3 MEMORY-DEDUP** — E5 semantic similarity over `durable_facts`; merge near-duplicates
   above threshold 0.92. Preserve highest-confidence original. Long-tail memory tractability.

4. **SC4 COMMUNITY-RECOMPUTE-SCHEDULER** — Wire `community_pipeline.recomputeCommunitiesForUser`
   to daemon nightly tick (per-user, capped LLM-naming budget). Closes G17 from the
   activation audit.

5. **SC5 SLEEP-CYCLE-OBSERVABILITY** — JSONL log of every cycle: `ran_at`, `items_consolidated`,
   `items_deduped`, `llm_calls`, `errors`. Same pattern as stability.jsonl. File:
   `src/agent/sleep_cycle.zig` (orchestrator). This also serves as G9 continuous-canary
   substitute — daily cycle = daily signal of whether agent improvement is compounding.

**Repo structure additions:**
- `src/agent/sleep_cycle.zig` — orchestrator (NEW)
- `src/memory/lifecycle/skill_consolidation.zig` — consolidation logic (NEW)
- extend `src/memory/lifecycle/hygiene.zig` — add sleep-cycle trigger point
- extend `src/daemon.zig` — schedule sleep cycle at hygiene cadence

**Bench gate (after 2 sleep cycles run on real data):**
- `durable_facts.predicate = LEARNED_PATTERN` ≥ 10 rows after 2 weeks of normal use
- `durable_facts.predicate = AVOID_PATTERN` ≥ 3 rows
- LoCoMo + V-inf + τ-bench: no regression; Cat 3 ideally lifts (learned patterns inform
  agent on similar future questions)
- p95 sleep-cycle wall-clock ≤ 30s per user
- Sleep-cycle JSONL emitting; operator can grep for consolidation events

**Duration:** 7-10 working days.
**Dependencies:** v1.14.18-A (skill_executions populating) + v1.14.18-B (reflection trail
in skill_executions). Without these, consolidation has no material to work with.

---

## v1.15.0 — "τ-bench iteration sprint (Karpathy loop)" → PLANNED

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

## v1.16.0 — "Frontend integration wave" (requires zaki-prod coordination) → PLANNED

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

## v1.17.0 — "Native connectors phase 1" → PLANNED

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

## v1.17.5 — "Durability + auditability — enterprise blocker close" (NEW from 2026-05-19 architecture audit) → PLANNED

**Theme:** Move ephemeral runtime state to durable backing stores. Closes V3 (approvals), V5 (event log), V4 trailing work. Enterprise / regulated industries / GDPR access requests UNBLOCKED. Must precede the per-cell canary deploy.

**Why here:** A real customer onboarding with compliance requirements (auditable history, approval ledger, replayable runs) needs these durable. Canarying onto a production cell BEFORE these land means accepting "we can't answer audit questions about your past runs" — that's commercially unsafe.

**Steps:**

1. **V3 — Approval persistence**
   - New migration `src/migrations/00XX_approvals.sql`: `approvals` table with `id UUID`, `run_id`, `tenant_id`, `user_id`, `tool_name`, `args_json JSONB`, `status` enum, `requested_at`, `resolved_at`, `resolver_actor`, `ttl_at`, `audit_metadata JSONB` + indexes on `(tenant_id, status)` and `(run_id)`
   - New package `src/runtime/approvals/` with `store.zig` (Postgres CRUD), `service.zig` (request/resolve/expire/list), `types.zig`
   - Wire `agent/root.zig:1791 setPendingToolApproval` to call `approvals.service.request()`; in-memory `pending_tool_approval` becomes a cache layer with explicit invalidation
   - REST endpoint: `POST /api/v1/users/{user_id}/approvals/{id}/{resolve|deny}`
   - TTL expiry as background job
   - Test: agent restart mid-approval → approval still queryable from DB

2. **V5 — Durable event log**
   - Migration `src/migrations/00XY_run_events.sql`: `run_events` table with `id BIGSERIAL`, `run_id`, `tenant_id`, `user_id`, `event_type`, `event_version`, `occurred_at`, `causal_parent_id BIGINT`, `payload JSONB` + indexes; partition by month
   - SQLite WAL mirror for hot writes (same schema, faster local persist)
   - New package `src/runtime/events/` with `event_log.zig` (append-only writer), `replay.zig` (`replayRun(run_id) → iterator<Event>`), `subscription.zig`
   - Wire `observability.zig` event bus to write to durable log
   - Keep `run_trace_store.zig` as query cache for last-N runs
   - Test: replay an old run from durable log → byte-identical event sequence

3. **V4 follow-through — remove the optional from subagent ledger bridge**
   - After 2 weeks of stable `task_delivery != null` everywhere, remove the `?` from the field type — make it required
   - Compile-time guarantee that subagent task state is always ledger-mirrored

4. **B9 — GDPR purge E2E test**
   - `src/gdpr.zig` + `lane_metrics.zig` purge counters exist; no proven E2E test
   - New test: populate tenant with memories + edges + vectors + approvals + run_events, invoke `gdpr.purgeUser`, assert zero rows survive across ALL tables (memories, memory_edges, memory_entities, vectors, conversations, run_events, approvals)
   - Couples naturally with new approval + event tables landing in this block

**Bench gate:**
- Approval state survives agent restart (proven by test)
- Event replay byte-identical to original (proven by test)
- `grep -r "pending_tool_approval = " src/` shows only the cache layer (not the source of truth)
- `subagent.zig:134` field type is `*tasks_mod.TaskDelivery`, not `?*...`
- GDPR purge E2E test passes (all tables zero rows post-purge)
- LoCoMo + τ-bench hold
- p95 TTFT ≤ 4.0s
- Tag `v1.17.5`

**Duration:** 13–16 working days (added B9 GDPR E2E test)
**Dependencies:** v1.17.0

---

## v1.18.0 — "Per-cell pod canary deploy" → PLANNED

**Theme:** First production cell on the per-cell-pod architecture. zaki-infra work.

**Prereq (before any deploy):**

- **B5 — Platform-wide load test** — beyond the existing Telegram webhook stress at `deploy/k8s/zaki-bot/telegram_webhook_stress_local.sh`. New test: simulate N concurrent tenants with mixed channel traffic + tool use, measure: connection-pool exhaustion threshold, gateway QPS ceiling, memory peak RSS. Document the numbers as the per-cell capacity envelope.
- **B12 — Capacity model documented** — `docs/capacity-model.md` with: max tenants per cell, max concurrent SSE streams per cell, peak QPS supported, Postgres connection pool sizing per cell, horizontal scaling triggers. This is the spec the canary deploy validates against.

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
- Capacity model spec verified (canary cell matches predicted envelope ± 15%)
- p95 TTFT ≤ 4.0s
- Tag `v1.18.0`

**Duration:** 7 working days deploy + 7 days soak (added 2 days for B5 load test)
**Dependencies:** v1.17.5

---

## v1.18.5 — "Disaster recovery + backup drill" (NEW from blind-spot B4) → PLANNED

**Theme:** Tested restore drill against the canary cell. Customer trust gate before broader rollout.

**Why here:** Customer asks "what's your RTO?" We need a number proven by a real restore drill, not a guess. Must precede the second cell going live.

**Steps:**

1. Document backup strategy: cadence, retention, location (DO-managed → confirm settings + cross-region copy?)
2. Define RTO (recovery time objective) + RPO (recovery point objective) numbers
3. Build automated backup health check (last backup age, restore-test status)
4. Perform a real restore drill: snapshot the canary cell DB → spin up parallel restore env → verify data integrity → measure restore wall-clock time
5. Document the drill outcome in `docs/dr-runbook.md`
6. Optionally: cross-region failover plan (if commercial signals require)

**Bench gate:**
- Restore drill executed end-to-end, RTO measured + documented
- `docs/dr-runbook.md` exists with concrete procedures
- LoCoMo + τ-bench hold (no regression)
- Tag `v1.18.5`

**Duration:** 3 working days
**Dependencies:** v1.18.0

---

## v1.19.0 — "Observability + SRE maturity" → PLANNED

**Theme:** The dashboards and budgets that turn nullalis into a real operated system.

**Steps:**

1. Grafana dashboards: per-tenant latency, per-tool cost, per-provider error rate
2. Per-tenant cost tracking (Kimi calls, Together calls, embedding calls, etc.)
3. Latency budgets per turn phase (the `memory_enrich` 900ms variance from `project_agent_turn_audit_followups`)
4. Background scheduler for memory hygiene (the lifecycle gap from `project_lifecycle_investigation_2026_04_20`)
5. Alerting: P95 latency, error rate, cost-per-tenant outliers
6. **B6 — Long-tenant recall benchmark** — synthetic 5-year tenant with 50K memory rows; measure recall p50/p95 under realistic load. Triggers `conversation_retention_days` policy decision.
7. **B7 — OTEL collector setup** — `OtelObserver.fromEnv` already wires, but no collector receives spans in production. Document the collector deployment (Tempo / Jaeger / Honeycomb) + wire env vars in zaki-infra.

**Bench gate:**
- Dashboards live, alerts firing on synthetic incidents
- Long-tenant benchmark documented (p95 recall ≤ acceptable threshold; threshold defined in this block)
- OTEL spans visible in collector backend
- LoCoMo + τ-bench hold
- p95 TTFT ≤ 4.0s
- Tag `v1.19.0`

**Duration:** 6–8 working days (added B6 + B7)
**Dependencies:** v1.18.5

---

## v1.19.5 — "Security + identity hardening — pre-commercial gate" (NEW from 2026-05-19 architecture audit) → PLANNED

**Theme:** Close the two-headed authorization model (H1) and eliminate identity fallback keys from canonical paths (V9). This is the security gate before commercial launch — no enterprise customer signs without a coherent auth model and clean per-user attribution.

**Why here:** Commercial launch implies multi-tenant production traffic with audit obligations. Today's H1 finding (capability metadata exists but `security/policy.zig:71 default_allowed_commands` is still the primary allowlist) means we have two parallel authorization models. V9 (identity fallback keys `agent:zaki-bot:main` / `:cron` still propagate through some paths) means audit log entries can carry `user_id=unknown`. Both must close before v2.0.

**Steps:**

1. **H1 — Capability metadata becomes the source of truth**
   - Extend `ToolMetadata` with `auth_requirements: []const AuthRequirement` (credential_id + scopes) and `side_effects: []const SideEffect` (.network, .filesystem_write, etc.)
   - Wire `tools/root.zig` dispatcher to enforce metadata at execution time:
     - `risk_level == .critical` → require explicit approval
     - `mutating && agent.mode == .read_only` → refuse
     - `auth_requirements` missing for credential-bearing tool → refuse early with clear error
   - Migrate `security/policy.zig:71 default_allowed_commands` to derive from metadata
   - Delete the flat allowlist
   - Test: tool without metadata fails comptime check
   - Exit verification: `grep "default_allowed_commands" src/` → zero matches

2. **V9 — Identity strict mode for canonical paths**
   - Add `parseUserIdFromSessionKeyStrict()` rejecting fallback keys and unrecognized shapes (current `parseUserIdFromSessionKey` already returns null for non-canonical; strict variant throws an error rather than returning null)
   - Replace lenient calls in canonical paths (agent loop, memory writes, approval requests) with strict variant
   - Keep lenient parser only at telemetry/diagnostics paths
   - Metric: count of fallback-key usages per hour; should trend to zero
   - Deprecate `fallbackMainSessionKey()` + `fallbackCronSessionKey()` behind feature flag
   - Test: `tests/security/identity_attribution_test.zig` — every canonical write path requires real `user_id`; fallback keys raise

**Bench gate:**
- One unified authorization model (`grep "default_allowed_commands"` empty)
- Zero fallback-key usage in canonical paths (metric counter at zero for 7 days)
- LoCoMo + τ-bench hold
- p95 TTFT ≤ 4.0s
- Tag `v1.19.5`

**Duration:** 8–10 working days
**Dependencies:** v1.19.0

---

## v1.19.7 — "Unit economics baseline" (NEW from blind-spot B3) → PLANNED

**Theme:** Measure the cost-per-turn / cost-per-tenant / cost-per-tool-call baseline that informs v2.0 pricing. Without this block, the payment design is design-in-the-dark.

**Why here:** Pricing models (per-message vs per-token vs per-cell vs flat-subscription) need real cost data. v1.19.0 added per-tenant cost tracking infrastructure; this block USES that infrastructure to produce the numbers Nova needs for payment strategy.

**Steps:**

1. Run a 7-day cost measurement on the canary cell with real production traffic
2. Aggregate by tenant / by channel / by tool family / by provider
3. Compute: median cost-per-turn, p90 cost-per-turn, monthly cost-per-tenant distribution
4. Compute storage growth rate (memories + vectors + run_events + conversations) per active tenant per month
5. Document: `docs/unit-economics-2026-XX-XX.md` with the actual numbers
6. Cross-reference against pricing models Nova is considering — flag where the model is upside-down (e.g., "$5/month flat at observed median cost would lose money on the p90 tenant")

**Bench gate:**
- `docs/unit-economics-*.md` published with real measured numbers
- Nova has the data to lock the v2.0 pricing model
- LoCoMo + τ-bench hold
- p95 TTFT ≤ 4.0s
- Tag `v1.19.7`

**Duration:** 7 days measurement + 1 day analysis = 8 working days
**Dependencies:** v1.19.5 + at least 5 active tenants on canary

---

## v2.0.0 — "Commercial launch — payment + onboarding + first 100 paying users" → PLANNED

**Theme:** The transition from "technical product" to "commercial product." Strategy is Nova's; this block holds the slots and dependencies.

**Steps (deferred to payment-design discussion per Nova):**

1. Payment provider integration (Stripe / Paddle / Lemonsqueezy — Nova's choice)
2. Pricing model implementation (per-cell / per-message / per-tool-call / token-metered — Nova's choice)
3. Trial → paid flow
4. Multi-tenant billing reconciliation
5. Onboarding flow refresh (post-AGENTS.md §14 standards)
6. First 100 paying users acquisition + retention measurement

**Cross-coord with zaki-prod (B11):**
- Frontend XSS / agent-content safety boundary — explicit contract test that a malicious memory containing `<script>` cannot escape zaki-prod's markdown renderer
- Coordinated with v1.16.0 frontend wave; revisited at v2.0 onboarding refresh

**Bench gate:**
- ≥ 100 paying users
- ≥ 95% MRR retention month-over-month
- p95 TTFT ≤ 4.0s holds under paying-user load
- Tag `v2.0.0`

**Duration:** open — paced by payment-design decisions
**Dependencies:** v1.19.7 (unit economics) + payment design lock-in with Nova

---

## v2.1.0 — "Runtime / frontend boundary cleanup" (NEW from 2026-05-19 architecture audit — V10) → PLANNED

**Theme:** Stop hardcoding `zaki_app` channel-specific behavior inside the runtime layer. Make the runtime emit ONE pure event-envelope shape; channel adapters do the shaping.

**Why post-v2.0:** This is architectural debt that compounds with every new channel — but it doesn't block commercial launch, and the refactor risk is high. Better to do it AFTER v2.0 stabilizes with real traffic informing the boundary design.

**Steps:**

1. Create `src/runtime/event_envelope.zig` — pure event shape, no client-specific tagging
2. Move channel-specific delivery/pacing into `src/channels/zaki_app/event_adapter.zig` (follow the existing channel adapter pattern)
3. Refactor `gateway_run_events.zig` to emit pure envelopes; channel adapters do shaping
4. The `"live"` vs `"buffered_replay"` decision becomes a channel adapter concern, not runtime concern (today: `gateway_run_events.zig:81,91`)
5. SSE frame shaping with frontend-specific tags ("reasoning_summary" thinking-card source tagging at `gateway_run_events.zig:207-256`) moves to the zaki_app adapter
6. Test: a new channel can be added without touching `gateway.zig` or `gateway_run_events.zig`

**Bench gate:**
- New channel surface added via adapter only, no runtime edits required (proven by a test that adds a dummy channel and asserts no gateway/runtime LoC changed)
- LoCoMo + τ-bench hold
- Tag `v2.1.0`

**Duration:** 12–15 working days
**Dependencies:** v2.0.0

---

## Background extraction stream — "gateway.zig monolith split" (V1 from 2026-05-19 architecture audit, ONGOING)

**Theme:** `src/gateway.zig` is **26,990 LoC** at HEAD. Target: < 8K LoC. Extract one responsibility per sprint, distributed as background work across blocks v1.14.18 → v2.1.0. Each extraction is its own PR, keeps public API stable, slims `gateway.zig` by ~3-5K LoC.

**Why background, not a single block:** This is a 3-month refactor done as one-extraction-per-sprint while other roadmap blocks proceed. Trying to do it all at once is the same mistake as the original assembly — instead we extract one responsibility at a time, each a clean PR with its own tests.

**Extraction sprints (one per parent block, scheduled when extractor fits the parent block's theme):**

1. **Sprint A — Auth-token management** → `src/gateway/auth_tokens.zig` (~3K LoC: telegram, whatsapp, line, lark token resolution). Targets parent block: v1.14.15 (Email channel finish — touches token surface anyway).
2. **Sprint B — Tenant runtime cache** → `src/gateway/tenant_cache.zig` (~2K LoC: lifecycle, idle TTL, policy attach). Targets parent block: v1.17.5 (Durability/auditability — touches tenant state).
3. **Sprint C — Webhook + channel queues** → `src/gateway/channels.zig` (~3K LoC). Targets parent block: v1.14.16 (Teams channel — touches webhook handler).
4. **Sprint D — Rate limit + idempotency** → `src/gateway/quota.zig` (~1K LoC). Targets parent block: v1.19.0 (Observability — quota metrics are observability-adjacent).
5. **Sprint E — Approval routing** → into `src/runtime/approvals/` package built in v1.17.5. Targets parent block: v1.17.5 itself.
6. **Sprint F — Product-shaping (V10)** → into BFF adapter (`src/channels/zaki_app/event_adapter.zig`). Targets parent block: v2.1.0 itself.

**Per-extraction invariants (per AGENTS.md §14.1):**
- Public API stable (extraction is internal restructure, no breaking changes)
- Each extraction lands as its own PR, with its own tests
- Net `gateway.zig` LoC reduction: ~3-5K per extraction
- LoCoMo + τ-bench hold per extraction (no regression)

**Exit:** `wc -l src/gateway.zig` shows < 8K. Each cluster lives in its own file with explicit interface. Total work: ~3 months distributed across the roadmap blocks above.

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
13. **Local-first / on-premise deployment story (B10)** — make-target + config preset for fully local operation (Zig binary + optional sqlite + optional libpq, no cloud LLM dependency). Differentiator for privacy-first users. Position as V-infinity pillar candidate; not blocking commercial.

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

## Status as of 2026-05-22 reconcile

- **v1.14.12 / .13 / .14** — TAGGED.
- **v1.14.15 / .16** (Email/Teams channels) — DELIVERED via **Sprint 2**, folded into the `v1.14.20` tag. **.17** (Nostr) — still DEFERRED (no user demand).
- **v1.14.18-A / -B** (learning loop) — MERGED via PR #87 / #98; **TAGGED `v1.14.18`** (2026-05-22, at block-completion commit `79094848`).
- **v1.14.19** — Memory-pipeline repair + config-control-plane hardening; **TAGGED `v1.14.19`** (2026-05-22, `docs/CONFIG_CONTROL_PLANE_AUDIT.md`).
- **v1.14.20** — **Sprint 2: Channels V1 + MCP V1 (the A2A core).** 4 PRs (#99–#102) merged, independently audited, 5 fix-forward commits; **TAGGED `v1.14.20`** (2026-05-22 at `99db4ea8`). MCP follow-ups: enable the MCP client (config key rename), wire a memory backend into `mcp serve`.
- **NEXT:** Sprint 3 (universal-environment access) → Sprint 4 (UI/UX + freeze), then the v1.15+ blocks to v2.0. The "Sleep cycle" block is renumbered v1.14.19 → **v1.14.21**.
- **v1.14.18 MED-tier sweep** — partially addressed by the §14.10 activation audit; the full 31-MED sweep is still open against the audit ledger.

**The promise:** every block ships at the standard in AGENTS.md §14. Or it doesn't ship.
