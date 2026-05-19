---
tags: [prose, prose/docs]
---

# Deferred-items register

**Single source of truth for every item that was explicitly deferred
(not silently dropped) during the Swiss-watch closure sprints.** If a
sprint's close-out carries an item into a named follow-up with
rationale, it lands here. If a review pass classifies a finding as
MEDIUM/LOW and we don't fix it inline, it lands here.

Each row lists:
- **ID** — `Dn` identifier as cited in the originating sprint/review doc.
- **From** — which sprint/review surfaced it.
- **Shape** — one-line description.
- **Why deferred** — the honest reason it wasn't done in-sprint.
- **Target** — where the follow-up is expected to live.
- **Status** — `open` / `shipped` / `obsolete`.

When an item ships, mark `shipped at <sha>` in the Status column and
leave the row — the historical audit trail is part of the value. When
an item is superseded or no longer applicable, mark `obsolete` with a
one-line reason.

---

## From Sprint 1 (Visibility + Stop Bleeds)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D1 | Full `TurnOutcome{text, tool_calls_executed, spawned_task_ids}` struct return + structured tool-only-turn SSE frame | Interim `EMPTY_TURN_PLACEHOLDER` (S1.10) unblocks the user-visible symptom; full refactor touches `session.zig:530` + gateway + BFF + frontend consumers | Own sprint, post-Sprint-6 | **shipped at PR #36 + PR #TBD (sprint/d1-followups) + zaki-prod PR #8** (2026-04-25) — D1 sprint closed: TurnOutcome struct + 12 exit-point migration + Session storage + tool_only_turn ObserverEvent + spawned_task_ids capture + zaki-prod consumer. Plus opportunistic SOTA: parallel tools verified pre-shipped (D1.13), generalized tool-result cache (D1.14), memory warmupSession (D1.15), 4 hygiene fixes (D1.8/9/11/12), loop_detected immediate exit (D1.10), subagent return defense (D1.6). See `docs/sprints/d1-turn-outcome.md` for full status. |
| D2 | Run-scoped approvals feature (`/approve allow-run`) | Needs user-facing verb + session-scoped cache with explicit lifetime. 5-step design doc embedded in `src/security/approval_modes.zig` for when the UX side is designed. Sprint 1 removed the inert scaffolding | Sprint 4+ / Wave M | **open** |
| D3 | Re-verify `P2_gateway` cite accuracy after Sprint 4 silent-catch sweep | Sprint 1 added `otel_obs`, `noop_obs`, `EMPTY_TURN_PLACEHOLDER` not reflected in the P-file; cheaper to do after Sprint 4 also touches gateway | Sprint 4 close-out | **shipped at `c61d732`** (2026-04-25 catchup pass) — P2_gateway re-cited as part of the discipline-lapse repair across all 23 P-files. Drift section folded forward includes Sprint 1 (otel_obs, EMPTY_TURN_PLACEHOLDER), Sprint 4 (S4.8-13 silent-catch fixes), Sprint 7 (S7.6 GDPR endpoint, S7.13 telegram constant-time), Sprint 8 (dingtalk removal), D20 (dead chat-stream removal). |
| D4 | Live-staging verification of S1.4 JSON log format + S1.8 Telegram voice reply | Unit test + grep sanity caught expected regressions; real env still needs confirmation | Post-deploy smoke | **open** |

---

## From Sprint 2 (Revenue Loop) + D8 (Secret Vault)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D5 | `CostTracker` (420 LoC, USD-cost JSONL) full wire-up: per-user workspace resolution, lifecycle alongside cell-pod tenancy, JSONL persistence path | S2.8 shipped session-scoped weight cap (still bounds single-session abuse); true calendar-monthly persistence requires threading CostTracker through per-tenant runtime | Sprint 2 follow-up PR | **shipped at PR #51** (2026-04-26) — V1-must per `docs/v1-triage.md`. Implementation took the minimal-viable path: extended `UsageRuntime` (already per-tenant via gateway.zig:1405) with a JSONL ledger field instead of standing up the parallel CostTracker module. Ledger lives at `{workspace_dir}/state/cost.jsonl`, append-on-recordTurn, calendar-month rollup via `monthlyTotalUsd(now_secs)` with std.time.epoch year/month ordinal (correct across leap years + month boundaries, unlike the day/30 approximation in cost.zig). 6 new tests cover: path construction, append correctness, monthly aggregation, cross-month exclusion, no-path fallback, year-boundary correctness. CostTracker module remains for future budget-check integration; this PR closes the persistence gap V1 needs. |
| D6 | `Idempotency-Key` strict-enforcement mode (missing header → 400, not current soft mode) | Flipping strict before zaki-prod BFF confirms every mutating call attaches a key would break provisioning | After zaki-prod confirms | **open** |
| D7 | Extend Idempotency-Key dedupe to `POST /api/v1/users/:id/attachments` | Needs `state` threaded through `handleAttachmentUpload` signature; kept atomic scope for the S2.10 commit | Sprint 2 follow-up PR | **open** |
| D8 | Full secret vault API (5 routes + `zaki_bot.secret_mutations` table + two-phase mutation crypto) | Substantial new surface out of scope for Sprint 2 body | Dedicated atomic PR | **shipped at `f303153`** (PR #11) |
| D9 | Sprint-2 self-review MEDIUM finding | Tracked in `docs/sprints/sprint-2-review.md` | Sprint 2 review follow-up | **shipped at PR #53** (2026-04-26) — V1-nice per docs/v1-triage.md. Extracted `.entitlements_revoke` switch arm body into `pub fn handleEntitlementsRevokeRequest(raw, tokens, auth_required, method) EntitlementsRevokeResponse` near the existing `validateInternalServiceToken` helpers. Switch arm now just composes the response. 4 new unit tests cover: 405 method-not-allowed, 401 unauthorized (missing token), 400 missing user_id, 200 OK happy path with installEntitlement roundtrip. Happy-path test pairs `useDefaultResolver` with `resetDefaultStore` cleanup to prevent global-state pollution across the test suite. |
| D10 | Sprint-2 self-review LOW finding | Tracked in `docs/sprints/sprint-2-review.md` | Sprint 2 review follow-up | **open** |
| D11 | Full integration test coverage for D8 secret vault API | D8 shipped with unit tests; integration tests covered happy path + 4 error branches | Separate test PR | **shipped at `b2af768`** (5 DB integration tests via PR #11) |
| D12 | zaki-prod frontend `SecretsVaultSheet.tsx` reads `response.value` on GET `/secrets/:key` — returns undefined post-D8 | BFF migration guide shipped (`docs/sprints/d8-secret-vault.md`); frontend consumer swap needs its own PR | zaki-prod frontend PR | **open** |
| D13 | Wire `lane_metrics.recordSecretMutation{ok,fail}` counters alongside D8 audit rows | Audit table rows exist (`zaki_bot.secret_mutations`) but metrics counters do not | nullalis monitoring PR | **shipped at PR #52** (2026-04-26) — V1-nice per `docs/v1-triage.md`. Added `recordSecretMutationOk` / `recordSecretMutationFail` + `classifyAndRecordSecretMutation(outcome)` to `lane_metrics.zig`. Wired centrally in `zaki_state.Manager.recordSecretMutation` so every gateway call site (handlePrepare/handleSet/handleDelete) updates the counter without per-site touches. Outcome classifier: strings starting `rejected_` / `prepare_failed` / `consume_failed` / containing `_failed` / `_invalid` → fail; everything else → ok. 2 new tests (independence/monotonicity + classifier). |
| D14 | 2 pre-existing scheduler test failures recorded | Unrelated to Sprint 2 / D8 surface; pre-existing on baseline | Separate bug PR | **shipped at PR #49** (2026-04-26) — both root-caused + fixed: (1) `postgres claimed recurring job reschedules` failed because `job_type=.agent` + `tick(now, null)` had no agent runner → `last_status="error"` instead of `"ok"`; fixed by wiring a stub agent runner that returns `"ok"`. (2) `postgres replaceJobsJson scopes stored job ids per user while preserving raw ids` failed because Postgres jsonb→text serialization always inserts spaces after colons (`"id": "morning-brief"` not `"id":"morning-brief"`); fixed by parsing JSON and asserting structurally instead of substring-matching the raw text. New finding surfaced during this work tracked as **D14b**. |
| D14b | `bootstrap.integration_test.factory creates NullBootstrapProvider for memory backend` non-zero exit when postgres engine enabled | Surfaced during D14 investigation — appears to be cleanup leakage from `postgres_pool_releases_on_exec_error` test (intentionally probes a missing relation) bleeding into the next test process. Tests themselves pass (5560/5570 with 10 skipped, 0 asserts failed) but the bootstrap test process exits non-zero. Default suite (`zig build test` without postgres engine) is unaffected — exit 0. | Separate investigation PR, not blocking V1 | **open** |

---

## From Sprint 3 (CI + Deploy Safety)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D15 | Create `production-image-promotion` GitHub environment on ProjectNuggets/NULL-ALIS with Nova as required reviewer | One-time UI click; not representable in workflow YAML. Fail-closed: until done, `promote-latest` hangs waiting for approval — sha tags still publish, `:latest` doesn't advance | GitHub Settings → Environments, before first main-push after #13 merges | **open** — operator action |

---

## From Sprint 4 (Silent-Catch Sweep)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D16 | S4.14 noise-catch classification sweep — was 89 sites in `gateway.zig` alone + more across 83 files; current 307 sites across 57 files | First-pass shipped at `51422d0` (PR #28): policy doc at `docs/silent-catches-policy.md` establishes the 3-bucket classification (noisy-by-design / operator-critical / bubble-up); 5 operator-critical workspace-scaffolding sites converted; 16 process-cleanup sites tagged as noisy-by-design with one batch comment. **302 sites remain.** Reframed from "do it all" → "operator-pain-triggered sweep using the policy doc as guide" | Operator-pain-triggered, surface-by-surface | **partially-shipped at `51422d0`** (PR #28) — first-pass landed, continued audit on-trigger |

---

## From Sprint 5 (Architectural Correctness)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D17 | S5.1 Anthropic two-block cache on the wire — extend `serializeSystemCacheable` to emit `[{stable+tools, cache_control:ephemeral}, {volatile}]` | Requires plumbing stable-prefix-length through `ChatRequest` or adding a side channel. Value latent while Together is primary | Dedicated PR with a provider-switch trigger to prove the cache hit | **open** |
| D18 | S5.2 error classification carrier — replace `storeErrorName(@errorName)` with `{kind: ApiErrorKind, retry_after_ms: ?u64}`; delete 4 dead string-matchers in `providers/reliable.zig` | Zig errors can't carry payloads; carrier needs threadlocal / Provider-held state / signature change. Current string-matchers work; hygiene refactor, not live bug | Dedicated PR | **open** |

---

## From Sprint 6 (Dead Code Removal)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D19 | S6.1b hardware surface removal — 9-file surgery, ~200 LoC. `rag.zig` portion shipped as S6.1a | Shipped at `f05a114` (PR #27): full surface stripped. -61 LoC net (-120 deletions, +59 breadcrumbs). Test impact: -1 test ("json parse hardware section"). Every deletion site carries a `// ... removed D19` breadcrumb so future grep finds the rationale | Dedicated PR | **shipped at `f05a114`** (PR #27) |
| D20 | S6.2 dead `POST /api/v1/chat/stream` + `GET /api/v1/chat/events` buffered paths (~200 LoC at `gateway.zig:10377-10582` + `:10584+` on baseline) | Shipped at `a7235aa` (PR #26): re-verified the buffered handlers are unreachable from production traffic (SSE handlers intercept first), then deleted ~838 LoC of dead code + 4 tests that only exercised the dead branches. Net -832 LoC. Equivalent SSE-handler tests cover all behaviors that mattered | Dedicated PR | **shipped at `a7235aa`** (PR #26) |
| D21 | S6.4 consolidate legacy `pending_exec_*` approval system into `pending_tool_approval` | Two parallel approval systems coexist; user-facing surface; merging needs dedicated read-through with test cases for both flows. **Re-scoped 2026-04-26**: 63 reference sites across 3 files, 8-12 hr including test rewrite. Triaged-out of the freeze-week debt drain; needs its own focused sprint | Dedicated mini-sprint, not bundled with other debt | **open — needs own sprint** |

---

## From Sprint 7 (User-Value Completion — 7A polish / 7B GDPR / 7C channel-locality)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D25 | Full postgres E2E for `gdpr.purgeUser` — live DB fixture that seeds a user across all 17 cascade tables + `memory_vectors`, runs `purgeUser`, asserts zero rows in every table plus audit-log for the delete | Sprint 7B shipped hermetic orchestrator tests (sqlite vector store, filesystem tree, session cache, PurgeReport accounting) + structural proof that the pg cascade works (existing `pg_helpers` tests). A live-DB E2E requires the `NULLCLAW_POSTGRES_TEST_URL` fixture pattern seen in `store_pgvector.zig`, ~200 LoC of seed + assert code. Value is belt-and-suspenders, not net-new safety | Dedicated follow-up PR keyed to `NULLCLAW_POSTGRES_TEST_URL` in CI | **open** |
| D26 | 2-phase prepare/consume confirmation token on `DELETE /api/v1/users/:id/data` — reuse `secret_vault.ConfirmationTokenStore` keyed on `(user_id, "__gdpr_purge__", .delete)` | S7.6 ships single-phase (X-Internal-Token + body magic string binding to path user_id). Operator-only today — the internal token IS the credential. Upgrade to 2-phase if this endpoint is ever exposed via the frontend where a user-driven UX flow needs the prepare-then-confirm interstitial | Frontend exposure PR, not before | **open** |
| D27 | Wire `lane_metrics.recordGdprPurge{ok,partial,fail}` counters alongside `gdpr.purgeUser` | Observability parity with secret_mutations audit counters (D13). Separate metrics PR keeps Sprint 7B scope clean | nullalis monitoring PR | **shipped at PR #52** (2026-04-26) — V1-nice per `docs/v1-triage.md`. Added `recordGdprPurge{Ok,Partial,Fail}` to `lane_metrics.zig`. Wired at end of `gdpr.purgeUser` with three-way classification matching PurgeReport semantics: `ok = fullySucceeded`, `partial = some surface succeeded but errors recorded`, `fail = no surface succeeded`. 1 new test (independence/monotonicity). |

---

## From Sprint 8 (Design Decisions)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D28 | Migrate the ~16 NULLCLAW_CELL_* direct-reads in `src/cell_k8s_api.zig` + the `NULLCLAW_API_KEY` generic fallback in `src/providers/api_key.zig` + the `NULLCLAW_POSTGRES_TEST_URL` test gates in `src/zaki_state.zig` to dual-name (NULLALIS_ primary, NULLCLAW_ fallback) before the 2026-05-15 sunset | S8.3 shipped sunset deadline + once-per-process banner + per-key warn for the SHIM-helper paths in `sentry_runtime.zig` and `observability.zig`. Direct-read sites bypass the shim helpers and need coordinated env-file + k8s-manifest + sealed-secrets migration. Hard deadline forcing function — must close before sunset | Dedicated NULLCLAW-migration PR with k8s manifest companion in zaki-infra | **shipped at `4a5f23b`** (nullalis PR #30, +241/-70 LoC across 12 files) — landed 2026-04-25 ahead of sunset. Cross-repo cousins: zaki-infra PR #14 (k8s manifests emit both names) and zaki-prod PR #7 (clean — replaces messy PR #6 which bundled unrelated Wave3 work, now closed). All three repos shipped same day. |
| D29 | Vtable-level lane filtering (`VectorStore.searchScopedByLane(user_id, lane, ...)` + Memory.recall lane parameter) if cross-lane noise becomes observable | S8.1 shipped Label (Option B) — entries and candidates carry `lane` field for ranking heuristics. Filter (Option C) was deferred because today's 3-tier retrieval strategy already handles scope via session_id; promoting lane to a vtable parameter would churn ~6-8 files and force every backend impl to reimplement filtering. Activate only if production retrieval shows real cross-lane confusion | Dedicated retrieval refactor PR | **open — conditional, not scheduled** |
| D30 | Rename `agent_routing.buildThreadSessionKey` → `buildChannelRoutedThreadSessionKey` to remove the name collision with `session/root.userThreadSessionKey` | Shipped at `997ee11` (PR #25): rename + deprecated alias for external callers (sunsets alongside NULLCLAW_ on 2026-05-15) + 1 new regression test asserting the alias still works | Dedicated rename PR | **shipped at `997ee11`** (PR #25) |

---

## From PR #21 / PR #22 code review (post-Sprint-7B / post-Sprint-8 fixes)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D31 | Qdrant `deleteAllForUser` count-before-delete: pre-count via filter then delete, so `PurgeReport.vector_rows_removed` reflects actual removal count instead of returning 0 unconditionally | Today Qdrant's `/points/delete` doesn't return a count; we honestly return 0 (regulator-asking-for-proof scenario in M3 of the review). Fix is two HTTP calls instead of one — non-trivial cost on the happy path. Worth doing for audit-trail completeness, not blocking | Qdrant follow-up PR | **open — audit completeness** |
| D32 | `gdpr.purgeUser` — assert `users_root` is absolute path; reject relative roots with explicit error in `PurgeReport` | Shipped at `283b8e1` (PR #23): `std.fs.path.isAbsolute` guard before fs touch; non-absolute roots skip step 4 and record `fs_path_not_absolute:<root>` in errors. 2 new tests | Sprint 7B follow-up PR | **shipped at `283b8e1`** (PR #23) |
| D33 | Cascade integration test: assert `DELETE FROM {schema}.users WHERE user_id = $1` removes rows from each of the 17 FK-cascading tables on a seeded user. Without it, a future migration that adds a per-user table without `ON DELETE CASCADE` silently leaks that table from GDPR purge | S7.5 shipped hermetic orchestrator tests + relies on the schema audit at `zaki_state.zig:743-974` for the cascade claim. A live-pg fixture asserting every table is FK'd to users with cascade would lock the contract structurally rather than relying on the audit memory. Pairs naturally with D25. **S10.4 (`c49bf14`, PR #39) ships a static-analysis complement** that asserts the `users_user_id_fkey` cross-schema FK declaration is present in `migrations/0001_initial_schema.sql` with CASCADE semantics + idempotent DO-block wrapping. The live-pg runtime test below is still needed to catch future migrations that add per-user tables WITHOUT FK + CASCADE | Combined live-pg E2E PR (D25 + D33) | **open — runtime cascade still needed; static contract shipped via S10.4** |
| D34 | Banner-once test: assert `env_rebrand.fireBannerOnce` emits exactly one log line under repeated calls + a multi-thread-style stress test. Plus integration test that exercises a `NULLCLAW_*` env-fallback path end-to-end | Partially shipped at `50c9ec4` (PR #24): multi-thread stress (8×100 calls, exactly-1 winner via test-only counter) + state-cycle round-trip + 1000-call no-op fast-path tests landed. End-to-end env-fallback integration test still deferred (Zig 0.15 has no `std.posix.setenv`; needs cross-platform setenv shim — separate test-infra PR) | Future test infra PR | **partially-shipped at `50c9ec4`** (PR #24) — once-fire contract locked; env-integration still deferred |

---

## From Sprint 4/5/6 post-hoc self-review

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| MED-1 | `cachedConfigForCaps()` pointer-dangling invariant (S5.7) | Safe today (no reassignment site) but latent for future hot-reload | Sprint 5 review fix | **shipped at `f29e6a6`** (PR #16) — docstring invariant added |
| MED-2 | Streaming context-exhaust retry emits `llm_response success=false` but not paired `success=true` on retry success (S5.3) | Dashboards aggregating llm.response outcomes would undercount retry successes | Sprint 5 review fix | **shipped at `f29e6a6`** (PR #16) — success event emitted |
| MED-3 | Two readers of `NULLALIS_ENABLE_MULTIAGENT` could disagree if `setenv()` fires mid-process (S6.3) | Not realistic today, but latent drift trap | Sprint 6 review fix | **shipped at `95f80fb`** (PR #17) — atomic cache, first reader wins |

---

## From LLM researcher pass rounds 1+2 (2026-04-27)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| R7-tool | Agent emits `**Step N: <action>**` headings without firing the tool or surfacing result content (yesterday's exact rough edge, recurrence) | Round-1 finding; round-2 verified fixed via PR #54 — Plan-Execute Integrity rule + reflection_prompt restructure (STEP 1 = surface tool result, STEP 2 = decide next action) | Closed in-pass | **shipped at `14d1af6`** (PR #54) |
| R7-stat | Agent fabricated "3,700+ memories stored" in intro reply with no tool call (real total: 9,270) | Round-1 finding; round-2 verified fixed via PR #54 prompt strengthening — agent now fires `memory_list` and quotes `100/9278` verbatim when asked about own state | Closed in-pass | **shipped at `14d1af6`** (PR #54) |
| R10 | Workspace-path discovery friction — agent ran 6+ shell calls (`find` / `ls` / `pwd`) to locate a file at workspace root | Round-2 finding; PR for cleanup batch | This batch | **shipped** — strengthened `buildWorkspaceSection` with explicit "your working directory is X, all file ops resolve relative; try direct read first, only `find` if not-found" + names R10 anti-pattern by date |
| R11 | `MAX_TOOL_RESULT_CHARS=8000` truncates 8.8KB code files by ~10% — too aggressive for code review on Kimi's 256K window | Round-2 finding; PR for cleanup batch | This batch | **shipped** — bumped 8000 → 24000 (~600 lines of typical Zig source per result), still <0.01% of Kimi window |
| R12 | Leaked tool_call XML markers at start of some streaming replies (`l>\nall>\nl>\nool_call>\n`) — likely Kimi K2.5 emits pipe-delimited markers (`<|tool_calls_section_begin|>`, `<|tool_call_begin|>`, etc.) that the `<invoke>`/`<tool_call>` filter doesn't recognize | Cosmetic; agent behavior unaffected. Filter extension to handle Kimi's pipe-format requires careful prefix-matching logic (15-byte hold-back may not be enough for 28-char `<|tool_calls_section_begin|>`). Needs dedicated PR | Filter-extension PR after V1 | **open** — cosmetic, not blocking V1 |
| R13 | Duplicate iteration emission — same content rendered twice in single reply (observed once in round-2 R2.5 cross-turn coherence test) | Need reproduction. Could be agent loop running an extra iteration, OR streaming dedup gap, OR LLM emitting same content twice. Single observation = insufficient evidence | Reproduce + investigate | **open** — needs more reproductions to root-cause |
| R9 | Workspace path uses `.nullclaw/data/users/...` prefix — D28 NULLCLAW→NULLALIS work didn't extend to operator config-file `tenant.data_root` | Operator action (Nova): edit `~/.nullalis/config.json` `data_root` from `.nullclaw/data/users` → `.nullalis/data/users` + `mv ~/.nullclaw/data/users ~/.nullalis/data/users`. No code change needed | Operator config + filesystem rename | **open — operator action** |

---

## Strategic / architectural (not from any specific sprint)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| **R-effort-override** | User override for `reasoning_effort` decoupled from assistant_mode | Currently the mode preset (Q3) unconditionally overwrites `cfg.reasoning_effort` when applied. So a user who wants "fast mode + high reasoning" or "deep mode + low reasoning" cannot. Tied. Per Nova SwissWatch directive 2026-04-28: "we allow user override in later versions; document it now, remind me later." Implementation: invert precedence in `user_settings.applySettingsToConfig` so user-set `cfg.reasoning_effort` wins over preset when explicitly non-null. ~30min code + tests | V1.X polish OR V1.5 (Nova's call) | **open** — user-facing flexibility request |
| D22 | Billing architecture — `Entitlement` feature flags (`zaki_enabled`, `spaces_enabled`) on top of the existing `plan_tier` ladder to support zaki-only / spaces-only / bundle SKUs | Nova's current direction: pricing math ($23 / $12 / $30) is sound; architectural plumbing is a post-closure concern. Feature-flag shape over SKU-as-tier is the lean; see conversation context | After closure through Sprint 16, as a standalone "billing-v2" PR | **open** — architectural decision locked; implementation pending |
| D23 | `nullalis-v2` partial-rewrite bootstrap — new repo with simplified 14-directory runtime layout + ADRs 0001-0005 | Originally floated as "parallel with Sprint 4" but decision was "finish all 16 sprints first"; revisit once Sprint 14/16 close. Until then, v1 continues to absorb the fixes and v2 does not exist | Post-Sprint-16 | **open** — reassess after closure |
| D35 | Sprint 9 (Supply Chain Full) — 8-item supply-chain proof layer: branch protection + CODEOWNERS + Dependabot + CodeQL + SBOM + gitleaks + trivy + cosign | Parked 2026-04-26: every item produces a CI artifact requiring GitHub Actions to execute; today's state (single-owner, no external auditor, Actions intermittently locked, no production paying-customer pressure) makes the work theoretical. Triggers to unpark: external audit, customer security questionnaire, second committer added, public release, or supply-chain CVE. S9.6 (gitleaks pre-commit) may unpark ahead of the rest after the 2026-04-26 D28 incident — pre-commit-only doesn't need CI | When external pressure or second committer arrives | **parked — trigger-conditional** |

---

## From v1.14.13 (Audit Sweep — Agent E)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| F-A2.1 | Auto-router classifier that selects `brain_graph local_graph` for entity-centric questions vs `memory_recall` for text-shaped recall — and re-emits the F-A2 directive only when the router is in place | The F-A2 system-prompt directive was bench-verified ignored (0 brain_graph calls vs 145 memory_recall calls on canonical bench). Per AGENTS.md §14.7 we strip directives the model doesn't act on rather than retain them "in hope." The structural intent (use the graph for entity questions) is real; the prompt-layer mechanism failed. Re-add F-A2 only when (a) F-A2.1 classifier exists, (b) bench shows brain_graph call counts climb from zero, and (c) the directive's presence is tied to the router's signal, not standalone wishfulness. | When entity-routing becomes a measured bottleneck on τ-bench or LoCoMo cohort | **open** — directive stripped at v1.14.13 Step 4; re-attach gated on router |
| B13 — MaxRSS budget remediation | `zig build test --summary all` MaxRSS exceeds the AGENTS.md §2.2 budget (<50 MB). Measured 2026-05-19 on agent/E-v1.14.13 worktree: main test binary `run test 6045 passed 67 skipped` → **MaxRSS 62M** (small drift from the 61M baseline named in ROADMAP). Two satellite test binaries (38 passed @ 5M, 4 passed @ 2M) are within budget; the monolithic root binary is the entire overage. Compile-time peak is 3G for the same step but is not the runtime concern. | Root cause hypothesis (unverified): the monolithic main test binary runs 6045 tests sequentially in a single process under `std.testing.allocator` (a GeneralPurposeAllocator wrapper). The GPA freelist doesn't shrink between tests, so peak RSS equals the high-water-mark across the entire suite. Likely hot sources: large JSON parse trees in extraction/entity tests, conversation transcript fixtures, in-memory SQLite test DBs in memory-engine tests. Cheap surgical fixes are blocked on data we don't have yet — we cannot identify the top-N allocators without per-test instrumentation. Splitting the monolith into per-subsystem test binaries is the canonical remediation but is significant refactor surface and needs bench validation that it doesn't slow CI. Remediation path: (1) add a debug-build-only test wrapper that emits peak `GeneralPurposeAllocator` stats per top-level test module, (2) identify the 3-5 worst offenders, (3) reduce fixture size or arena-scope them so memory is reclaimed between tests, (4) if still over budget, split the root.zig test binary along subsystem boundaries (memory / providers / channels / tools / agent / gateway). Until step 1 lands we are guessing. | Triage block before next bench gate; remediation as its own block after data | **deferred at v1.14.13 Step 8** — baseline 62M documented; cheap fix blocked on instrumentation; data-driven remediation deferred per Agent E's measured-baseline-or-defer protocol |
| IDENTITY-ORPHAN | `src/identity.zig` — AIEOS v1.1 portable AI-identity struct tree (586 LoC) with JSON parser + system-prompt formatter. Zero production callers at HEAD; re-exported once at `src/root.zig:75`. Originally mirrored ZeroClaw's `identity.rs` and was intended as the substrate for "import / export a persona definition." The active runtime persona surface today lives in MEMORY.md + SOUL.md + workspace markdown, not in this struct tree. | Outcome A per ROADMAP v1.14.13 Step 6 (keep + document). Per AGENTS.md §14.2 archaeology shows the original intent (portable persona spec) maps directly onto a V-infinity pillar candidate (#4 — persona import/export). Deleting the module would lose ~580 LoC of correct-but-unused parsing scaffolding that the future feature would otherwise need to rebuild. Gating: re-evaluate at V-infinity pillar selection. If the persona pillar is chosen, wire this module's `parseAieosJson` + `aieosToSystemPrompt` into the import/export tool surface. If a different persona design is chosen (e.g. extending SOUL.md as the canonical persona file), delete-with-named-successor per §14.4 at that point. | V-infinity arc — persona pillar (candidate #4) OR explicit successor selection | **open** — substrate parked; touch protocol documented in `src/identity.zig` top-of-file comment |

---

## Retroactive reviews (process-gap)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D24 | Retroactive self-review for Sprint 1 + Sprint 3 (review protocol was only adopted mid-session, starting with Sprint 2) | Sprints 1 and 3 already merged through main; any findings go into this register or direct follow-up PRs. Not blocking any current work | Opportunistic — do during any future Sprint 1/3 surface touch | **open** — low priority; doc completeness only |

---

## How to use this file

- **Adding an item:** when a sprint close-out or review pass defers something with rationale, copy the row into the matching section above (create new section if the sprint doesn't exist yet).
- **Closing an item:** change `open` → `shipped at <sha>` with PR reference. Do NOT delete the row.
- **Superseding an item:** change `open` → `obsolete` with a one-line reason. Do NOT delete the row.
- **Reviewing "what's still open":** `grep 'open' docs/deferred-register.md | wc -l` gives the live count.

Last audit: **2026-04-26** at D28-Day-1 close + S9 park — 19 items open (D35 added for Sprint-9 park), 9 shipped, 1 obsolete. D28 cross-repo PRs are open and ready (nullalis #30 + zaki-infra #14 + zaki-prod #6); sunset deadline 2026-05-15 honored ahead of schedule. Sprint-9-as-debt-item D35 added with explicit unpark triggers (external audit / second committer / public release / supply-chain CVE).
