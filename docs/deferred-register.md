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
| D1 | Full `TurnOutcome{text, tool_calls_executed, spawned_task_ids}` struct return + structured tool-only-turn SSE frame | Interim `EMPTY_TURN_PLACEHOLDER` (S1.10) unblocks the user-visible symptom; full refactor touches `session.zig:530` + gateway + BFF + frontend consumers | Own sprint, post-Sprint-6 | **open** |
| D2 | Run-scoped approvals feature (`/approve allow-run`) | Needs user-facing verb + session-scoped cache with explicit lifetime. 5-step design doc embedded in `src/security/approval_modes.zig` for when the UX side is designed. Sprint 1 removed the inert scaffolding | Sprint 4+ / Wave M | **open** |
| D3 | Re-verify `P2_gateway` cite accuracy after Sprint 4 silent-catch sweep | Sprint 1 added `otel_obs`, `noop_obs`, `EMPTY_TURN_PLACEHOLDER` not reflected in the P-file; cheaper to do after Sprint 4 also touches gateway | Sprint 4 close-out | **open** — Sprint 4 shipped; cite refresh pending |
| D4 | Live-staging verification of S1.4 JSON log format + S1.8 Telegram voice reply | Unit test + grep sanity caught expected regressions; real env still needs confirmation | Post-deploy smoke | **open** |

---

## From Sprint 2 (Revenue Loop) + D8 (Secret Vault)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D5 | `CostTracker` (420 LoC, USD-cost JSONL) full wire-up: per-user workspace resolution, lifecycle alongside cell-pod tenancy, JSONL persistence path | S2.8 shipped session-scoped weight cap (still bounds single-session abuse); true calendar-monthly persistence requires threading CostTracker through per-tenant runtime | Sprint 2 follow-up PR | **open** |
| D6 | `Idempotency-Key` strict-enforcement mode (missing header → 400, not current soft mode) | Flipping strict before zaki-prod BFF confirms every mutating call attaches a key would break provisioning | After zaki-prod confirms | **open** |
| D7 | Extend Idempotency-Key dedupe to `POST /api/v1/users/:id/attachments` | Needs `state` threaded through `handleAttachmentUpload` signature; kept atomic scope for the S2.10 commit | Sprint 2 follow-up PR | **open** |
| D8 | Full secret vault API (5 routes + `zaki_bot.secret_mutations` table + two-phase mutation crypto) | Substantial new surface out of scope for Sprint 2 body | Dedicated atomic PR | **shipped at `f303153`** (PR #11) |
| D9 | Sprint-2 self-review MEDIUM finding | Tracked in `docs/sprints/sprint-2-review.md` | Sprint 2 review follow-up | **open** — see sprint-2-review.md for specifics |
| D10 | Sprint-2 self-review LOW finding | Tracked in `docs/sprints/sprint-2-review.md` | Sprint 2 review follow-up | **open** |
| D11 | Full integration test coverage for D8 secret vault API | D8 shipped with unit tests; integration tests covered happy path + 4 error branches | Separate test PR | **shipped at `b2af768`** (5 DB integration tests via PR #11) |
| D12 | zaki-prod frontend `SecretsVaultSheet.tsx` reads `response.value` on GET `/secrets/:key` — returns undefined post-D8 | BFF migration guide shipped (`docs/sprints/d8-secret-vault.md`); frontend consumer swap needs its own PR | zaki-prod frontend PR | **open** |
| D13 | Wire `lane_metrics.recordSecretMutation{ok,fail}` counters alongside D8 audit rows | Audit table rows exist (`zaki_bot.secret_mutations`) but metrics counters do not | nullalis monitoring PR | **open** |
| D14 | 2 pre-existing scheduler test failures recorded | Unrelated to Sprint 2 / D8 surface; pre-existing on baseline | Separate bug PR | **open** |

---

## From Sprint 3 (CI + Deploy Safety)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D15 | Create `production-image-promotion` GitHub environment on ProjectNuggets/NULL-ALIS with Nova as required reviewer | One-time UI click; not representable in workflow YAML. Fail-closed: until done, `promote-latest` hangs waiting for approval — sha tags still publish, `:latest` doesn't advance | GitHub Settings → Environments, before first main-push after #13 merges | **open** — operator action |

---

## From Sprint 4 (Silent-Catch Sweep)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D16 | S4.14 noise-catch classification sweep — 89 sites in `gateway.zig` alone + more across 83 files | Per-site "operator-critical vs noisy-by-design" audit; too large for sprint body | Dedicated follow-up PR | **open** |

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
| D19 | S6.1b hardware surface removal — `main.zig`, `config.zig`, `config_types.zig`, `config_parse.zig`, `status.zig`, `user_settings.zig`, `capabilities.zig`, `tools/root.zig`, `root.zig` (9-file surgery, ~200 LoC). `rag.zig` portion shipped as S6.1a | Surface is inert today (CLI is a deprecation-stub, tools don't register, config_parse silently ignores unknown keys); removal needs careful per-file passes | Dedicated PR | **open** |
| D20 | S6.2 dead `POST /api/v1/chat/stream` + `GET /api/v1/chat/events` buffered paths (~200 LoC at `gateway.zig:10377-10582` + `:10584+` on baseline) | Line numbers pre-drift; Sprint 2 + D8 added gateway surface in between. Re-verify paths are truly dead on current tip before deletion | Dedicated PR | **open** |
| D21 | S6.4 consolidate legacy `pending_exec_*` approval system into `pending_tool_approval` | Two parallel approval systems coexist; user-facing surface; merging needs dedicated read-through with test cases for both flows | Dedicated PR | **open** |

---

## From Sprint 7 (User-Value Completion — 7A polish / 7B GDPR / 7C channel-locality)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D25 | Full postgres E2E for `gdpr.purgeUser` — live DB fixture that seeds a user across all 17 cascade tables + `memory_vectors`, runs `purgeUser`, asserts zero rows in every table plus audit-log for the delete | Sprint 7B shipped hermetic orchestrator tests (sqlite vector store, filesystem tree, session cache, PurgeReport accounting) + structural proof that the pg cascade works (existing `pg_helpers` tests). A live-DB E2E requires the `NULLCLAW_POSTGRES_TEST_URL` fixture pattern seen in `store_pgvector.zig`, ~200 LoC of seed + assert code. Value is belt-and-suspenders, not net-new safety | Dedicated follow-up PR keyed to `NULLCLAW_POSTGRES_TEST_URL` in CI | **open** |
| D26 | 2-phase prepare/consume confirmation token on `DELETE /api/v1/users/:id/data` — reuse `secret_vault.ConfirmationTokenStore` keyed on `(user_id, "__gdpr_purge__", .delete)` | S7.6 ships single-phase (X-Internal-Token + body magic string binding to path user_id). Operator-only today — the internal token IS the credential. Upgrade to 2-phase if this endpoint is ever exposed via the frontend where a user-driven UX flow needs the prepare-then-confirm interstitial | Frontend exposure PR, not before | **open** |
| D27 | Wire `lane_metrics.recordGdprPurge{ok,partial,fail}` counters alongside `gdpr.purgeUser` | Observability parity with secret_mutations audit counters (D13). Separate metrics PR keeps Sprint 7B scope clean | nullalis monitoring PR | **open** |

---

## From Sprint 4/5/6 post-hoc self-review

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| MED-1 | `cachedConfigForCaps()` pointer-dangling invariant (S5.7) | Safe today (no reassignment site) but latent for future hot-reload | Sprint 5 review fix | **shipped at `f29e6a6`** (PR #16) — docstring invariant added |
| MED-2 | Streaming context-exhaust retry emits `llm_response success=false` but not paired `success=true` on retry success (S5.3) | Dashboards aggregating llm.response outcomes would undercount retry successes | Sprint 5 review fix | **shipped at `f29e6a6`** (PR #16) — success event emitted |
| MED-3 | Two readers of `NULLALIS_ENABLE_MULTIAGENT` could disagree if `setenv()` fires mid-process (S6.3) | Not realistic today, but latent drift trap | Sprint 6 review fix | **shipped at `95f80fb`** (PR #17) — atomic cache, first reader wins |

---

## Strategic / architectural (not from any specific sprint)

| ID | Shape | Why deferred | Target | Status |
|----|-------|--------------|--------|--------|
| D22 | Billing architecture — `Entitlement` feature flags (`zaki_enabled`, `spaces_enabled`) on top of the existing `plan_tier` ladder to support zaki-only / spaces-only / bundle SKUs | Nova's current direction: pricing math ($23 / $12 / $30) is sound; architectural plumbing is a post-closure concern. Feature-flag shape over SKU-as-tier is the lean; see conversation context | After closure through Sprint 16, as a standalone "billing-v2" PR | **open** — architectural decision locked; implementation pending |
| D23 | `nullalis-v2` partial-rewrite bootstrap — new repo with simplified 14-directory runtime layout + ADRs 0001-0005 | Originally floated as "parallel with Sprint 4" but decision was "finish all 16 sprints first"; revisit once Sprint 14/16 close. Until then, v1 continues to absorb the fixes and v2 does not exist | Post-Sprint-16 | **open** — reassess after closure |

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

Last audit: **2026-04-24** at Sprint 7B close — 21 items open, 4 shipped, 0 obsolete.
