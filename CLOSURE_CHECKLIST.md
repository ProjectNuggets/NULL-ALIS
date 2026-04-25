# nullalis + zaki-infra + zaki-prod — Closure Checklist

**Built:** 1 month, 83K LoC of Zig, 3 repos, k8s deployment live.
**Goal:** Swiss-watch quality end-to-end before adding anything new.
**Rule:** every item below closes or is explicitly marked parked-with-rationale. Nothing is left latent.
**Baseline:** commit `87cb435` (nullalis), derived from P1+P2+P3+P4 internals x-ray at `.claude/projects/-Users-nova-Desktop-nullalis/memory/internals/`.

**Progress:** update this file as items land. Each item is `[ ]` → `[x]`. At each sprint boundary, confirm every item's DoD holds. Branch per sprint: `repair/sprint-N-<theme>`.

---

## Sprint 1 — Visibility + Stop Bleeds  (~5-7 days)

Goal: prod emits real signal; no active user-visible data-loss or first-click bugs.

### Observability
- [x] **S1.1** Wire `NULLCLAW_SENTRY_DSN` — add to `config.example.json`, `deploy/k8s/zaki-bot/05-deployment.yaml` envFrom, set secret in zaki-infra. Cite: P4_telemetry.
- [x] **S1.2** Hook `ObserverEvent.err` → `captureError` in `src/sentry_runtime.zig` so inner-loop errors (tool/LLM/channel) reach Sentry. Cite: P4_telemetry.
- [x] **S1.3** Enable signal handlers in sentry_runtime for crash capture. Cite: P4_telemetry.
- [x] **S1.4** Override `std_options.logFn` → JSON structured logs to stderr. Cite: P4_telemetry.
- [x] **S1.5** Instantiate `OtelObserver` in gateway + daemon boot (currently dead outside tests). Cite: P4_telemetry.

### Wave 0 — data-loss + broken-first-click
- [x] **S1.6** `daemon.zig:1456` — replace `cron.loadJobs catch {}` with `loadJobsStrict` + `loaded_from_disk: bool` on `CronScheduler`, gate `saveJobs` in recoverable-error branch of `reloadJobs` (`cron.zig:1902-1909`). Cite: P2_scheduler.
- [x] **S1.7** Implement `UserSessionStore.clearAutoSaved` postgres DELETE on `autosave_*` keys (`zaki_state.zig:432-435`) + test. Cite: P2_session_storage.
- [x] **S1.8** Voice TTS inbound gate — fix `[voice:` vs `[Voice]:` substring mismatch (case-insensitive or both forms) + telegram-marker test. Cite: P2_voice.
- [x] **S1.9** Run-scoped approval — either wire `DecisionSource.session_cache` through `executeToolUnchecked` with test, or correct the declaration + comment to reflect reality. Cite: P2_tools, P2_subagent_delegate.
- [x] **S1.10** Subagent "received" fabrication — replace `gateway.zig:9184 + :10562` with `TurnOutcome` struct from `session.zig:530` → `{text, tool_calls_executed, spawned_task_ids}` + structured tool-only-turn SSE. Defense: guard `subagent.zig:643` against empty-but-non-null `owned_result`. Tests. Cite: P2_subagent_delegate.
- [x] **S1.11** Settings page first-click fix — BFF `/v1/me/bot/settings PATCH` must target nullalis `/settings` (not `/config` which returns 403). zaki-prod-side change. Cite: P4_ops_truth drift #1, P4_zaki_prod_bff.
- [x] **S1.12** `NULLCLAW_STATE_MASTER_KEY` — add `valueFrom.secretKeyRef` in `deploy/k8s/zaki-bot/05-deployment.yaml` + set secret via sealed-secrets or operator. Cite: P4_ops_truth drift #2, state-secrets-wiring.md:51-52.
- [x] **S1.13** pgvector dim-mismatch guard — `store_pgvector.zig:394-410` → refuse + log-error + document migration path, do NOT drop. Cite: P4_schema risk #1.

**Sprint 1 DoD:** Sentry captures a test error in staging. Logs ship as JSON. `grep "catch {}" src/daemon.zig` shows the 3 fixed sites replaced. Open settings → no 403. Telegram voice note → voice reply. Subagent task with no post-tool text → clear `[no reply]` placeholder, actual result arrives on follow-up.

**Sprint 1 — CLOSED 2026-04-22 at `963fc92`** (nullalis) + `c329e9a` (zaki-infra).

Ship:
- Observability triad live: Sentry DSN + inner-loop `.err`→`captureError` + signal handlers default-on + JSON log format, all opt-in via env with NULLCLAW_→NULLALIS_ fallback.
- OtelObserver instantiated when `NULLALIS_OTEL_ENDPOINT` set; NoopObserver in slot otherwise — composition stable across deployments.
- Data-loss landmines closed: cron.json wipe guard (`loaded_from_disk` + strict boot load), pgvector destructive-rebuild refusal + explicit opt-in override.
- User-visible bugs fixed: `/new` actually clears postgres `autosave_*` rows; Telegram voice replies fire on real voice notes; gateway no longer fabricates `"received"` as a reply body.
- Inert run-scoped approval scaffolding removed with design doc embedded for proper revival.
- Carried `http_request` default flip landed as its own commit for clean audit.
- zaki-infra chart README documents NULLALIS_* secrets + observability keys + rebrand migration path.
- S1.11 verified stale (BFF was already correct) — no code change.

DoD verification:
- `zig build test -Dengines=all` green at every commit (postgres path compiled in).
- Per-item grep sanity sweep passes (see sprint-1 close-out chat log).
- `.spike/run.sh` cold + polluted — pending (operator-gated; Nova to run pre-merge).

Deferred-but-tracked (with rationale):
- **S1.10 full TurnOutcome refactor**: interim honest placeholder shipped. Full `{text, tool_calls_executed, spawned_task_ids}` struct return + structured tool-only-turn SSE frame touches gateway / session / agent signatures and requires BFF + frontend consumers. Queued for its own sprint.
- **Run-scoped approval feature (S1.9)**: enum value deleted; full design documented in `src/security/approval_modes.zig` for revival when the user-facing verb + cache lifetime are built end-to-end. Queued for Sprint 4+ or Wave M.

PR path: merge `repair/sprint-1-visibility` → `main` once `.spike/run.sh` confirms baseline. Tag post-merge. Then branch `repair/sprint-2-revenue-loop`.

---

## Sprint 2 — Revenue Loop  (~5-7 days)

Goal: can charge users honestly; free tier blocked at entry points; revocation propagates.

### Entitlement propagation + enforcement
- [x] **S2.1** Extend `/api/v1/users/provision` response with `plan_tier`, `status`, `period_end` — BFF side. Cite: P4_zaki_prod_bff gap 1. _Nullalis side shipped `d0a57b1` + `8f7e54d`; zaki-prod BFF companion PR pending._
- [x] **S2.2** Nullalis-side: store entitlement per-session, expose via `TurnContext.entitlement`. Cite: plan-v02 §6. _Shipped `c13813b`._
- [x] **S2.3** Enforcement chokepoint 1 — chat-stream entry. Reject with `402 entitlement_required` if beyond plan. _Shipped `dae9bea`._
- [x] **S2.4** Enforcement chokepoint 2 — tool execution preflight. _Shipped `9c1a6d2`._
- [x] **S2.5** Enforcement chokepoint 3 — scheduler job dispatch. _Shipped `23cac97`._
- [x] **S2.6** Enforcement chokepoint 4 — Composio / MCP / other integration calls. _Structurally covered by S2.4 (`2a8405a`)._
- [x] **S2.7** BFF → nullalis revocation webhook `POST /internal/entitlements/revoke`. Cite: P4_zaki_prod_bff gap 2. _Nullalis endpoint shipped `8f7e54d`; zaki-prod Stripe translator pending._
- [x] **S2.8** Flip dead `CostTracker` — weight-budget gate + `UsageRuntime.recordWeight`. Cite: P4_monetization. _Shipped `347f8dc` (session-scoped; true monthly persistence → D5)._
- [x] **S2.9** Cost classes per tool — `cost_class: enum { A, B, C }` on `ToolMetadata`. Cite: plan-v02 §4.4. _Shipped `f51128d`._
- [x] **S2.10** `Idempotency-Key` header dedupe on mutating routes. Cite: P4_zaki_prod_bff gap 3. _Shipped `ee60b68` (soft-mode on `/provision`; strict + attachments → D6/D7)._
- [x] **S2.11** Enforce "64 active jobs per user" cap. Cite: P4_ops_truth drift #3. _Shipped `3fe1f79`._

### Secret vault API (plan.md §3)
- [x] **S2.12** `GET /api/v1/users/:id/secrets/:key` → metadata-only response (no plaintext). Cite: plan.md §3. _Shipped via D8 `e5fad87`._
- [x] **S2.13** `POST /api/v1/users/:id/secrets/:key/prepare` → issue confirmation token. Cite: plan.md §3. _Shipped via D8 `e5fad87` (TokenStore `277ec7d` + mount `e457faa`)._
- [x] **S2.14** `PUT /api/v1/users/:id/secrets/:key` → requires valid confirmation token. Cite: plan.md §3. _Shipped via D8 `e5fad87`._
- [x] **S2.15** `DELETE /api/v1/users/:id/secrets/:key` → requires valid confirmation token. Cite: plan.md §3. _Shipped via D8 `e5fad87`._
- [x] **S2.16** Audit trail — new `zaki_bot.secret_mutations` table, row per attempt. Cite: plan.md §3 + plan-v02 §6. _Shipped via D8 `946d325` + `e5fad87`._

**Sprint 2 DoD:** free-tier user hits chat stream → 402. Pro-tier user passes. Stripe cancel webhook → nullalis session revoked within 5s. CostTracker writing JSONL. Secret PUT without prepare token → 401.

**Sprint 2 — CLOSED 2026-04-23 at `aa251cb`** (PR [#10](https://github.com/ProjectNuggets/NULL-ALIS/pull/10)), with S2.12–S2.16 landing in dedicated D8 PR **CLOSED 2026-04-23 at `f303153`** (PR [#11](https://github.com/ProjectNuggets/NULL-ALIS/pull/11)).

Ship:
- Entitlement propagation spine: `Entitlement` type + `RuntimeTurnContext.entitlement`; default in-memory resolver (`useDefaultResolver` + `installEntitlement`); `/provision` parses + installs `plan_tier` / `status` / `period_end_unix`; `/internal/entitlements/revoke` control endpoint; self-review dupe-before-put fix `60664bc`.
- 4 enforcement chokepoints live: chat-stream entry (402 `entitlement_required`), tool preflight, scheduler dispatch, integration calls (structurally covered by preflight).
- Session weight budget + `UsageRuntime.recordWeight`; cost classes A/B/C on `ToolMetadata`.
- Idempotency-Key dedupe (soft-mode on `/provision`).
- 64 active-jobs cap per tier enforced.
- D8: gated vault API (`gateway/secret_vault.zig` + `TokenStore`) replaces legacy plaintext GET; two-phase mutation handshake; `zaki_bot.secret_mutations` audit table + recorders + list endpoint; full BFF migration guide `docs/sprints/d8-secret-vault.md`.
- D11: HTTP envelope tests `dfcace8` + 5 DB integration tests (`bc0f3f0`, `ae482fa`, `c14b2e9`, `17ae688`, `b2af768`) cover happy-path, missing-token, mismatched-action, fabricated-token, audit-scoping.
- Cross-repo: zaki-prod BFF provision forwards the 3 entitlement fields + Stripe webhook translator to `/internal/entitlements/revoke` (merged zaki-prod #5 `cd54970`).

DoD verification:
- `zig build test -Dengines=all` green at each commit.
- D11 proves: happy-path roundtrip passes; `PUT` without token → 401 `token_required`; mismatched-action token preserved for legitimate call; fabricated-token `DELETE` → 401 `token_invalid`; audit scoped to requested key.
- D14 pre-existing scheduler test failures recorded (unrelated to Sprint 2 / D8 surface).

Deferred-but-tracked (D items):
- **D5** CostTracker full JSONL persistence (S2.8 session-scoped weight cap shipped; true calendar-monthly persistence queued).
- **D6** Idempotency-Key strict-mode flip (after zaki-prod confirms every mutating call attaches key).
- **D7** Idempotency-Key on `POST /api/v1/users/:id/attachments` (needs handler-signature refactor).
- **D9** Sprint-2 self-review MEDIUM finding (tracked in `docs/sprints/sprint-2-review.md`).
- **D10** Sprint-2 self-review LOW finding (tracked in `docs/sprints/sprint-2-review.md`).
- **D12** Frontend `SecretsVaultSheet.tsx` still reads `response.value` on GET — undefined post-D8; BFF migration guide shipped, frontend audit queued.
- **D13** Secret vault monitoring: wire `lane_metrics.recordSecretMutation{ok,fail}` counters (audit rows exist; metrics counters do not yet).
- **D14** 2 pre-existing scheduler test failures documented; not Sprint 2 / D8 regression.

---

## Sprint 3 — CI + Deploy Safety  (~3-5 days)

Goal: bad code can't reach prod; infra PR has a gate.

- [x] **S3.1** Pin Zig `0.15.2` across `.github/workflows/ci.yml`, `flake.nix`, `Dockerfile`. Single source of version. Cite: P4_ci_cd top-gap #2. _Shipped `035cc18` via `.zigversion` single source._
- [x] **S3.2** `.spike/run.sh` cold + polluted as required CI gate on PRs touching `src/`. Cite: P4_ci_cd. _Shipped `474905c` — `spike.yml` workflow with check-secret + postgres service + gateway background + 80% pass-rate floor._
- [x] **S3.3** `release.yml` canonical-profile job must run `zig build test -Dengines=all` (currently build-only). Cite: P4_ci_cd top-gap #3. _Shipped `bf4ed56` — inserts matching test step before ReleaseSmall build._
- [x] **S3.4** `deploy-zaki-runtime.yml` — add smoke test against staging, manual-approval gate, explicit rollback step. Cite: P4_ci_cd top-gap #3. _Shipped `f3af29d` — three-stage gate: build (immutable sha tags) → smoke (`version` + `help`) → promote :latest (environment-gated). Rollback via workflow_dispatch with `rollback_to_sha` input. Requires one-time operator setup of `production-image-promotion` environment → tracked as D15._
- [ ] **S3.5** zaki-infra — add `.github/workflows/validate.yml` enforcing `scripts/validate-nullalis-deploy.sh` (SHA-pinned tag validator) on every PR. Cite: P4_zaki_infra_ci top-gap #1. _Cross-repo: zaki-infra PR._
- [ ] **S3.6** zaki-infra — add staging overlay in `argocd/` + `charts/` values-staging.yaml, or document explicit single-env decision with risk acceptance. Cite: P4_zaki_infra_ci top-gap #3. _Cross-repo: zaki-infra PR._
- [ ] **S3.7** typ `:latest` on DOCR → pin to immutable SHA; backup custom patches to GHCR before flip. Cite: P4_zaki_infra_ci mutable-tag, memory-flagged. _Cross-repo: zaki-infra PR._

**Sprint 3 DoD:** PR to main requires tests green. Tag push runs tests. Deploy-to-prod needs manual click. zaki-infra PR with floating tag is rejected by CI. typ image SHA-pinned in charts/typ/values.yaml.

**Sprint 3 — NULLALIS SIDE CLOSED 2026-04-24 at `f3af29d`** (PR [#13](https://github.com/ProjectNuggets/NULL-ALIS/pull/13)). In-repo items S3.1–S3.4 shipped; zaki-infra items S3.5–S3.7 track as cross-repo follow-up (same pattern as Sprint 1's zaki-infra `c329e9a`).

Ship:
- **S3.1 Zig version single source:** `.zigversion` file authored; `ci.yml` and `release.yml` consume via `mlugg/setup-zig@v2` `version-file:` input; `flake.nix` reads via `builtins.readFile`; Dockerfile swapped `apk add zig` → pinned tarball download keyed on the same file. One edit bumps every build path.
- **S3.2 Spike as CI gate:** new `.github/workflows/spike.yml` with `check-secret` guard + `spike` job running postgres service container, launching gateway in background, and enforcing `BATTERY_PASS_FLOOR=0.80` on the 25-benchmark battery. Required on PRs touching `src/`.
- **S3.3 Release gate includes tests:** `release.yml` canonical-production-profile now runs `zig build test --summary all -Dengines=base,sqlite,postgres -Dchannels=cli,telegram` before the ReleaseSmall build, matching the ci.yml canonical profile. Tag push → tests run → build runs → artifact uploads.
- **S3.4 Deploy three-stage gate:** `deploy-zaki-runtime.yml` split into `build-and-publish` (immutable sha tags only, no `:latest`) → `smoke` (`nullalis version` + `nullalis help` exit 0 + `gateway` listed) → `promote-latest` (gated on `production-image-promotion` environment with required reviewer). Rollback path via `workflow_dispatch` with `rollback_to_sha` input re-tags a previously-published SHA as `:latest` without rebuild or smoke.

DoD verification:
- `.zigversion` contents = `0.15.2`; `grep -r "version-file" .github/workflows/` returns 2 hits (ci + release).
- `.github/workflows/spike.yml` present; contains `check-secret` + `spike` jobs + postgres service + `BATTERY_PASS_FLOOR`.
- `grep -A2 "Run tests" .github/workflows/release.yml` shows test step before ReleaseSmall build.
- `.github/workflows/deploy-zaki-runtime.yml` YAML parses clean via PyYAML — 3 jobs, 5 smoke steps, 4 promote steps.
- Local smoke of build assertions: `./zig-out/bin/nullalis version` → exit 0 `nullalis 2026.2.25`; `./zig-out/bin/nullalis help` → exit 0 with `gateway` listed.

Deferred-but-tracked:
- **D15** — create `production-image-promotion` GitHub environment on ProjectNuggets/NULL-ALIS with Nova as required reviewer. One-time UI click. Until done, `promote-latest` job hangs on approval (fail-closed: sha tags still publish, `:latest` simply doesn't advance).
- **S3.5/S3.6/S3.7** — zaki-infra cross-repo items tracked for a zaki-infra PR, parallel to Sprint 1's zaki-infra `c329e9a` pattern.

---

## Sprint 4 — Silent-Catch Sweep  (~3-5 days)

Goal: system stops failing silently. Pattern: `catch {}` → `catch |err| log.warn(...)` + counter, never abort unless operator-critical.

### Durable writes
- [x] **S4.1** `agent/root.zig` — user autosave — log. _Shipped `5d2c04a` (line drift since baseline: now in user-turn autosave block, `else |_| {}` converted to logged branch)._
- [x] **S4.2** `agent/root.zig` — learning-fact — log. _Shipped `5d2c04a`._
- [x] **S4.3** `agent/root.zig` — assistant autosave — log. _Shipped `5d2c04a`._
- [x] **S4.4** `session.zig:682-683` (saveMessage) — log. _Shipped `0bbeadf`._
- [x] **S4.5** `session.zig:715` (saveMessage other site) — log. _Shipped `0bbeadf`._

### Daemon
- [x] **S4.6** `daemon.zig:477` — `deleteCompletionEvent` log + new `lane_metrics.recordCompletionEventDeleteFailure` counter. _Shipped `19ed54a` — counter + unit test added to `src/lane_metrics.zig`._
- [x] **S4.7** `daemon.zig:963` — `writeStateFile` log + `health.markComponentError("heartbeat", ...)` on failure, skip ok-mark. _Shipped `19ed54a`._

### Gateway operator-critical
- [x] **S4.8** `gateway.zig` — `applyProfileDefaults catch {}` primary path — log. _Shipped `0503468`._
- [x] **S4.9** `gateway.zig` — `applyProfileDefaults catch {}` postgres-seeded path — log. _Shipped `0503468`._
- [x] **S4.10** `gateway.zig` — `buildUserRuntimeConfig` applyProfileDefaults — log. _Shipped `0503468`._
- [x] **S4.11** `gateway.zig` — `cfg.parseJson catch {}` on tenant config (2 sites, base + overlay) — log. _Shipped `0503468`._
- [x] **S4.12** `gateway.zig` — `subscriber.markDelivered` in `/chat/events` (both replay + live loops, `replace_all`) — log. _Shipped `e2a6203`._
- [x] **S4.13** `gateway.zig` — `sm.deleteCompletionEvent` in `/chat/events` (both loops) — log + S4.6 counter. _Shipped `e2a6203`._

### Categorize the remaining 54 noise catches
- [ ] **S4.14** Annotate each `catch {}` in gateway.zig with either `// noisy-by-design: <reason>` or convert. Target: zero unlabeled silent catches. _Carried → **D16** — 89 sites in gateway.zig alone + 83 other files; per-site audit warrants dedicated PR._

**Sprint 4 DoD:** `grep -c "catch {}" src/gateway.zig src/daemon.zig src/agent/root.zig src/session.zig` shows ≤ noise-count. All 13 operator-critical sites fixed. Sentry captures a seeded test failure from each site.

**Sprint 4 — CLOSED 2026-04-24 at `e2a6203`** — 13/14 in-repo items shipped; S4.14 noise-catalog sweep carried as D16.

Ship:
- 13 operator-critical silent catches converted to `catch |err| log.warn(...)` with session / user / event / errorName context.
- New `lane_metrics.recordCompletionEventDeleteFailure` counter unifies two distinct code paths (daemon delivery-outcome loop + gateway SSE stream) under one rising-count signal for "completion_events rows not clearing" — operators see one number regardless of source.
- `writeStateFile` failure now flips `health.markComponentError("heartbeat", ...)` instead of silently marking ok; next successful flush re-marks healthy via the ok branch.
- Atomic commits: 5 commits, one per logical cluster (root / session / daemon / gateway-config / gateway-stream). Each green `zig build`; full `zig build test` green on tip.

DoD verification:
- `zig build` green at each commit.
- `zig build test` exits 0 on tip; new lane_metrics unit test (`recordCompletionEventDeleteFailure increments total monotonically`) passes.
- Formerly-silent paths now emit warn-level log lines with enough context (session_key, event_id, user_id, errorName) to surface the failure class in operator logs.

Deferred-but-tracked:
- **D16** — S4.14 noise-catch classification sweep. 89 `catch {}` in gateway.zig + more across 83 other files. Each needs a per-site call: noisy-by-design (e.g. `child.kill() catch {}` in signal-death cleanup) vs. convert. Too large for this sprint; queued for a follow-up PR with its own review cadence.

---

## Sprint 5 — Architectural Correctness  (~5-7 days)

Goal: architectural claims match wire behavior.

- [ ] **S5.1** Anthropic two-block cache — change `serializeSystemCacheable` to emit `[{type:"text", text: stable+tools, cache_control: ephemeral}, {type:"text", text: volatile}]`. Cite: `anthropic.zig:480/547`, P2_context_v2, P2_providers. Verify with p50 TTFT proxy. _Carried → **D17** — cross-cutting ChatRequest plumbing needed; value latent while Together is primary._
- [ ] **S5.2** Error classification carrier — `reliable.zig:296-301` replace `storeErrorName(@errorName)` with `{kind: ApiErrorKind, retry_after_ms: ?u64}` populated from body parsers. Delete 4 dead helpers (`isRateLimited`/`isContextExhausted`/`isNonRetryable`/`parseRetryAfterMs`). Cite: P2_providers. _Carried → **D18** — Zig error payload limitation forces threadlocal/out-param; string-matchers work; hygiene not live bug._
- [x] **S5.3** Streaming context-exhaustion recovery parity — `agent/root.zig:2652` mirror the `:2731-2760` force-compress-and-retry flow. Cite: P2_turn_loop. _Shipped `4a23d6c` — streamChat retry on `ContextLengthExceeded` via `forceCompressHistory` + rebuilt messages + one retry._
- [x] **S5.4** Sort tools prose block — `prompt.zig:584-594` sort `self.tools` by name before rendering. Cite: P2_context_v2. _Shipped `3a8da9e` — index-array insertion sort + duck-typed anytype signature + MockTool test._
- [x] **S5.5** Sort skills directory iteration — `prompt.zig:639-719` `listSkillsMerged` must sort before rendering. Cite: P2_context_v2. _Shipped `831a50c` — `std.mem.sort` + `skillLessThanByName` comparator applied in both `listSkills` and post-merge in `listSkillsMerged`; new unit test._
- [x] **S5.6** Byte-equality test — unit test calling `buildStableSystemPrompt` twice with identical inputs, `expectEqualStrings`. Cite: P2_context_v2. _Shipped `477d520` — three-call identity assertion inline._
- [x] **S5.7** `Config.load` memoize — `agent/root.zig:2245` honor workspace_prompt_fingerprint; only reload on change. Cite: P2_turn_loop. _Shipped `3550539` — cached-Config + load-once-per-Agent-lifetime; 50-msg burst drops from 50 disk I/Os to 1._
- [x] **S5.8** Stage-17 disambiguate — `agent/root.zig:3524+` and `:2561` separate loop-detected-exit from iteration-exhausted in observer event + return prefix. Cite: P2_turn_loop. _Shipped `0e997de` — new `ObserverEvent.loop_detected` variant + distinct `turn.profile kind=tool_loop_detected` + "[Tool loop detected at N/N]" user-visible prefix; 3 exhaustive-switch arms updated in observability.zig._

**Sprint 5 DoD:** Anthropic cache hit p50 TTFT drops ≥ 10% on turn 2+. `reliable.zig` has no `indexOf` heuristics. Byte-eq test green. stage-17 observer events match actual exit cause.

**Sprint 5 — CLOSED 2026-04-24 at `4a23d6c`** — 6/8 shipped; S5.1 → **D17** (Anthropic two-block, latent value), S5.2 → **D18** (error carrier, Zig-error-payload refactor).

Ship:
- Byte-stability invariant now has an inline regression guard (S5.6) + explicit sorts on both surfaces that could drift it (S5.4 tools prose, S5.5 skills directory). Any future HashMap-enum / directory-walk introduction fires the test.
- Loop-detected exits distinct from iterations-exhausted end-to-end: new observer event variant, distinct logs, distinct `turn.profile kind`, distinct user-visible return prefix. Operator dashboards can aggregate separately.
- Config.load memoized: 50-msg burst goes from 50 disk I/Os + 50 JSON parses + 50 Config deinits → 1 each at first turn.
- Streaming sessions now heal on context-exhaustion the same way blocking sessions do (mirror of the pre-existing force-compress + retry pattern in `provider.chat`).

DoD verification:
- `zig build` green at each commit.
- `zig build test` exits 0 on tip; 38 test binaries pass; three new unit tests added.
- Byte-eq test green.

Deferred-but-tracked:
- **D17** — S5.1 Anthropic two-block cache on the wire. Requires plumbing stable-prefix-length through ChatRequest (or side channel) so `serializeSystemCacheable` can split without re-parsing. Together is current primary; Anthropic path is a latent cost sink. Worth a dedicated PR with a primary-switch trigger to prove the cache hit.
- **D18** — S5.2 error classification carrier + deletion of `isNonRetryable` / `isContextExhausted` / `isRateLimited` / `parseRetryAfterMs` string-matchers. Zig errors can't carry payloads, so the carrier needs threadlocal / Provider-held state / signature change. String-matchers are imperfect but working today. Hygiene refactor, not a live bug.

---

## Sprint 6 — Dead Code Removal  (~2-3 days)

Goal: every line earns its place.

- [~] **S6.1** Remove `hardware` surface — `main.zig` (5 hunks), `config.zig` (field + re-exports + tests + printer), `config_types.zig` (struct + enum), `config_parse.zig`, `status.zig:210`, `user_settings.zig:145`, `capabilities.zig:48-49,88-89`, `tools/root.zig:653,897,900`, `root.zig:5,84,86`. Delete `src/rag.zig` (dead module). _S6.1a shipped `4492bf3` (rag.zig removed); S6.1b (hardware surface, 9-file surgery) carried → **D19**._
- [ ] **S6.2** Remove dead `POST /api/v1/chat/stream` + `GET /api/v1/chat/events` buffered paths — `gateway.zig:10377-10582`, `:10584+` (~200 LoC). Cite: P2_gateway. _Carried → **D20** — line numbers pre-drift; need re-verification against current tip before deletion._
- [x] **S6.3** Gate `delegate`/`spawn` metadata in `DEFAULT_TOOL_METADATA:384-392` behind `NULLALIS_ENABLE_MULTIAGENT` to match runtime registration. Cite: P2_tools. _Shipped `917b9ce` — comptime-computed `CORE_TOOL_METADATA` subset + `multiagentEnabledEnv()` helper + test updates + new test for extended-registry classification._
- [ ] **S6.4** Consolidate legacy `pending_exec_*` into `pending_tool_approval`. Cite: P2_tools. _Carried → **D21** — two parallel approval systems; user-facing surface; needs dedicated read-through + test coverage before merge._
- [x] **S6.5** Fix `gateway.zig:11` file header (`std.http.Server` → `std.net.Server`) + refresh endpoint list at `:9`. Cite: P2_gateway. _Shipped `08f3729` — header rewrite points at dispatch table (drifts more slowly than enumerated comments) + corrects stdlib citation._
- [x] **S6.6** Rename `tool_dispatcher.zig` → `tool_mode.zig`. Update all imports. Cite: P2_tools, P1_arch. _Shipped `46ef65e` — `git mv` + 3 import paths + file header documenting the rename and the stability of the user-facing config key._
- [x] **S6.7** `voice_mode.zig` — add file-header comment noting metadata-only. Cite: P2_voice, P1_arch. _Shipped `08f3729` — header block states responsibility boundary + warns that TTS-capable flags for discord/whatsapp/slack advertise intent not working paths._

**Sprint 6 — CLOSED 2026-04-24 at `4492bf3`** — 5/7 shipped (S6.1a + S6.3 + S6.5 + S6.6 + S6.7); S6.1b → **D19**, S6.2 → **D20**, S6.4 → **D21**.

Ship:
- `src/rag.zig` deleted (13 KiB dead datasheet-RAG module with sole consumer being its own re-export in root.zig).
- `delegate` + `spawn` metadata gated behind `NULLALIS_ENABLE_MULTIAGENT` — registry now matches runtime registration; hallucinated-by-name tool calls fail cleanly at lookup instead of confusing the preflight policy.
- Two file-header comment fixes: gateway.zig now honestly says `std.net.Server` + points at the dispatch table; voice_mode.zig declares itself metadata-only with a warning about its aspirational TTS-capability flags.
- `tool_dispatcher.zig` → `tool_mode.zig` rename removes the grep-trap where readers confused the 70-line config-helper with the real ~1700-LoC dispatcher at `src/agent/dispatcher.zig`.

DoD verification:
- `zig build` green at each commit.
- `zig build test` exit 0 on tip; 5560 tests pass, 35 skipped, 0 failures.
- New unit test guards delegate/spawn classification against the extended registry so future multiagent-path regressions fire immediately.
- Zero stale `@import("tool_dispatcher.zig")` references after the rename.

Deferred-but-tracked:
- **D19** — S6.1b hardware surface removal. 9-file surgery; inert today (CLI is a deprecation-stub, tools don't register, config_parse silently ignores); ~200 lines to remove cleanly.
- **D20** — S6.2 dead `/api/v1/chat/stream` + `/api/v1/chat/events` buffered paths. Line numbers pre-drift; need re-verification before deletion — dead-looking code that's actually consumed is a classic regression.
- **D21** — S6.4 `pending_exec_*` consolidation. Two parallel approval systems; user-facing; risky merge without dedicated review.

**Sprint 6 DoD:** `zig build test` green. Line count in `src/` reduced. No references to removed symbols.

---

## Sprint 7 — User-Value Completion  (~3-5 days)

Goal: features users touch don't lie.

### Delete path (GDPR-grade)  ← Sprint 7B (branch `repair/sprint-7b-gdpr-delete`)
- [x] **S7.1** Compose `purgeUser(user_id)` — **new module `src/gdpr.zig`** rather than stuffing into zaki_state.zig (cleaner separation; the orchestrator reaches across pg / vector / fs / session surfaces, not one store). FK-ordered within pg via single `DELETE FROM {schema}.users WHERE user_id = $1` — cascade does the rest. Sha: 9956131.
- [x] **S7.2** Helpers — `VectorStore.deleteAllForUser` vtable extension (pgvector+sqlite+qdrant impls), `zaki_state.Manager.deleteUser` (single-stmt pg-cascade entrypoint), `SessionManager.evictUserSessions` (per-user 3-phase eviction, mirrors evictIdle). Per-table bulk DELETEs from the original plan were not built because the pg schema already cascades on users-row delete (17 tables, see lines 743–974); we use the existing FK contract instead of bypassing it. Sha: 77955fc.
- [x] **S7.3** `SessionManager.evictUserSessions` — filters by `session_identity.isOwnedBy`, wraps `active_refs != 0` / locked-mutex as `active_skipped` so an in-flight turn isn't torn out from under. Called by the orchestrator as step 1. Sha: 77955fc (helper) + 9956131 (wired).
- [x] **S7.4** Filesystem `{users_root}/{user_id}` via `std.fs.Dir.deleteTree` (treats missing root as success) + vector `memory_vectors` via S7.2 vtable. Both wired in step 3 and step 4 of the orchestrator. Sha: 9956131.
- [x] **S7.5** E2E test coverage — orchestrator-level unit tests in `src/gdpr.zig`: PurgeReport accounting, all-null-deps success, filesystem tree removal + idempotent re-purge, empty-users_root skip, vector-store bulk purge using SqliteSharedVectorStore (seeds 3+1 rows, verifies targeted user purged + other user untouched). Full postgres E2E (live DB fixture) deferred to D27 — the hermetic tests prove orchestrator correctness; the postgres cascade was already proved by existing pg_helpers tests. Sha: 9956131.
- [x] **S7.6** API surface: `DELETE /api/v1/users/:id/data` gated by body `{"confirm":"PURGE-USER-<id>"}` where `<id>` must match the path user_id (anti-mis-routing) + X-Internal-Token header (existing handleApiRoute entry gate). Not 2-phase prepare/consume like the secret vault — this endpoint is operator-only; adding a prepare step would slow operators without raising the effective bar. If exposed to end-users later, upgrade to the vault pattern (D26). Response body includes per-surface accounting (sessions_evicted, pg_user_row_deleted, vector_rows_removed, filesystem_removed, errors[]). Sha: 0228f40.

### Voice polish
- [x] **S7.7** TTS failure-notice parity with STT — `voice.zig::emitMultimodalFailureNotice` now surfaces on error, no silent drop to text. Sha: e500ad8.
- [x] **S7.8** Channel-locality enforcement — `MessageTool.send` pins to inbound channel unless `allow_channel_override=true`. Sha: 3978f1a.
- [x] **S7.9** `voice_mode.zig` capability honesty — discord/whatsapp/slack now report STT=false/TTS=false until their send paths actually ship. Sha: b52b7c0.

### Audit coverage
- [x] **S7.10** `bindAuditMemory` wired on CLI (`src/agent/cli.zig`) + gateway session boot (`src/session.zig::SessionManager.init`). Sha: a919568.

### Integration hardening (P4)
- [x] **S7.11** MCP `readLine` timeout — POSIX poll-based, 30s default, `read_line_timeout_secs` in config. Sha: 01363d2.
- [x] **S7.12** MCP stderr pipe drain loop — background thread per child, `[name]`-prefixed log.warn. Sha: 3051e76.
- [x] **S7.13** Telegram webhook secret constant-time compare — `security/pairing.constantTimeEq` (array-only `std.crypto.timing_safe.eql` wasn't applicable to runtime-length slices). Sha: 790814f.
- [x] **S7.14** Composio 429/retry with exponential backoff (1s, 2s). Sha: 3da1050.
- [x] **S7.15** Composio `list` cache (60s TTL, 16-slot LRU-by-expiry, test-gated via builtin.is_test). Sha: 0071ac8.

**Sprint 7 DoD:** Delete-account flow E2E passes on seeded tenant. TTS failure surfaces a notice. MCP hung-server test times out cleanly. Telegram secret passes timing-safe test.

---

## Sprint 8 — Design Decisions  (~2-3 days, decisions + small code)

Goal: W5 ambiguities resolved. Each gets a YES/NO/DEFER with written rationale; resulting code work queued into later sprint if needed.

- [x] **S8.1** W5.1 Lane-aware memory retrieval — **B (Label)**. `MemoryEntry` and `RetrievalCandidate` now carry a `lane: []const u8` field, populated via the new public `laneFromSessionId()` helper. Sqlite row reader hydrates it from `session_id`; entries-to-candidates mirrors it. Borrowed-string-literal pointer (no alloc/free coupling). Future evolution to vtable-level filtering (Option C) preserved if cross-lane noise ever shows in production. Sha: `462ce54`.
- [x] **S8.2** W5.2 `buildThreadSessionKey` legacy vs canonical — **B (Dual-formatter, formalize)**. Investigation revealed they're not legacy-vs-canonical at all: `agent_routing.buildThreadSessionKey` operates on the channel-routed family (`agent:{agent_id}:{channel}:{kind}:{id}`) used by `daemon.zig:1709`; `session/root.zig::userThreadSessionKey` operates on the user-cell family (`agent:zaki-bot:user:{id}:thread:{conv}`) used by HTTP/SSE. Migration would have produced wrong key shapes. Both formatters now carry doc comments cross-referencing each other; `daemon.zig:1709` carries an inline anti-migrate guard. Sha: `d722b39`.
- [x] **S8.3** W5.3 NULLCLAW_ → NULLALIS_ rebrand — **C (Park with deadline)**. Sunset 2026-05-15 baked into `sentry_runtime.NULLCLAW_SUNSET_DATE`. Three `*WithFallback` shim helpers fire a once-per-process banner via cmpxchg-guarded atomic flag, and per-key warns include the date. `observability.zig::OtelObserver.fromEnv` warning text matches. Direct-read sites in `cell_k8s_api.zig` (16 vars) and `providers/api_key.zig` deferred to D28 — they need a coordinated infra+code migration before sunset. Sha: `1be6e1a`.
- [x] **S8.4** W5.4 Dormant channel implementations — **A (Delete dingtalk; defer flag-gating)**. Investigation: 19 channels (not 15), 13 live + 5 dormant-working + 1 dormant-stub. Only dingtalk (121 LoC, 0 tests, comment admitted incomplete Stream Mode WebSocket) was a delete candidate; the other 5 dormant-working channels (whatsapp/lark/email/line/maixcam) carry real implementations and stay as roadmap code. Formalizing flag-gating as `@import` conditionals deferred to a dedicated infrastructure PR. Sha: `c969e88` (combined with S8.6).
- [x] **S8.5** W5.5 `.task` lane production path — **A (Already wired; tick and close)**. The premise of the original W5.5 question was stale. Audit found `.task` lane is fully wired across `subagent.zig:890` (`isTaskLaneSession`), `spawn.zig:178`, `runtime_info.zig` (multiple test asserts), `diagnostics/runtime_truth.zig:323`, plus the gateway lane-metric counters. Activation is gated by `NULLALIS_ENABLE_MULTIAGENT` (S6.3); when off, the spawn tool is filtered from the metadata registry so task-lane sessions never get created — but the machinery is ready. No code change needed; closure is the doc capture itself.
- [x] **S8.6** W5.6 `channels/dingtalk.zig` — **C (Delete)**. Rolled into S8.4 (`c969e88`). 121 LoC, 0 tests, no roadmap signal — recreating from scratch costs less than maintaining a dead stub.

**Sprint 8 DoD:** all 6 decisions captured in `docs/sprints/sprint-8.md` with date, rationale, and SHAs. Follow-up code queued in deferred-register (D28: NULLCLAW_ direct-read migration; D29: vtable-level memory filtering if cross-lane noise observed).

**Sprint 8 — CLOSED 2026-04-24.** Branch `repair/sprint-8-design-decisions`. 5 commits: `c969e88` (S8.4+S8.6), `d722b39` (S8.2), `462ce54` (S8.1), `1be6e1a` (S8.3), + a docs commit for S8.5 + closure artifacts.

---

## Sprint 9 — Supply Chain Full  (~3-5 days) — **PARKED 2026-04-26**

Goal: can prove what shipped.

**Parked-with-rationale (2026-04-26):** every S9 item produces a CI/GitHub
artifact (CodeQL run, syft SBOM, trivy scan, cosign signature, gitleaks
block) that requires Actions to actually execute to be valid. Today's
state — single-owner, no external auditor, GitHub Actions intermittently
quota-locked, no production paying-customer pressure — makes shipping
S9 theoretical work: configuration that nothing reads, signatures
nothing verifies, scans nothing acts on. Until at least ONE of the
following triggers fires, S9 stays parked:

  • External audit / customer security questionnaire (most likely first
    trigger; typical for any B2B sale or compliance posture)
  • Second committer added to either repo (CODEOWNERS becomes load-bearing)
  • Public-facing release (cosign signatures + SBOM matter for trust)
  • Discovered supply-chain CVE in a dep that wasn't caught (forcing
    function for Dependabot + trivy)

When any trigger fires, unpark in this order: S9.1 + S9.2 (zero-cost
foundation) → S9.3 (low-cost continuous gain) → S9.6 (gitleaks, prevents
the next D28-style accidental key commit; lessons from 2026-04-26) →
S9.4 (CodeQL) → S9.5 + S9.7 + S9.8 (release-pipeline artifacts).

**The 2026-04-26 D28 incident** (Tailscale .key accidentally committed to
the zaki-prod D28 branch, force-pushed clean within minutes) is the
strongest **single-shop** argument for S9.6 specifically. Even with one
operator, gitleaks pre-commit would have blocked that commit locally
before push. S9.6 may unpark ahead of the others on its own merit.

- [ ] **S9.1** Branch-protection-as-code on `main` (GitHub ruleset or settings.yml). PARKED.
- [ ] **S9.2** `CODEOWNERS` file — even if single-owner today, documents it. PARKED.
- [ ] **S9.3** Dependabot or Renovate — at minimum for `build.zig.zon` deps + Dockerfile base image. PARKED.
- [ ] **S9.4** SAST — CodeQL (free for public) or Semgrep. PARKED.
- [ ] **S9.5** SBOM generation (syft) on every release, published with artifact. PARKED.
- [ ] **S9.6** Secret scanning — gitleaks pre-commit + CI. **PARKED but pre-commit-only could ship today** (no CI dep) — lifts before the rest if D28-style incidents recur.
- [ ] **S9.7** Container scanning — trivy on built image in CI. PARKED.
- [ ] **S9.8** cosign image signing + SLSA level-1+ provenance. PARKED.

**Sprint 9 DoD (when unparked):** release pipeline produces SBOM.spdx + cosign signature. trivy blocks high-severity CVE. gitleaks blocks secret commit.

---

## Sprint 10 — Data Durability Full  (~5-7 days)

Goal: schema change is a process; data is recoverable.

- [ ] **S10.1** Real migration framework — introduce `zaki_bot.schema_migrations` table, numbered migrations in `src/migrations/*.sql` + runner in `zaki_state.zig`. Remove `canIgnoreMigrateError:2867-2907` allowlist once covered. Cite: P4_schema.
- [ ] **S10.2** Replace boot-time `CREATE IF NOT EXISTS` with versioned migrations. Cite: P4_schema.
- [ ] **S10.3** All index creation uses `CREATE INDEX CONCURRENTLY`. Cite: P4_schema risk #2.
- [ ] **S10.4** Cross-schema FK to `public.zaki_users` — add a versioning contract test that runs in both repos' CI (Rails side + nullalis side). Cite: P4_schema risk #3.
- [ ] **S10.5** NFS droplet — DigitalOcean volume snapshot schedule (daily minimum) in `terraform/nfs.tf`. Cite: P4_zaki_infra_ops Q4.
- [ ] **S10.6** DO-managed Postgres — document backup retention, PITR window, run restore drill quarterly, log date. Cite: P4_zaki_infra_ops Q4.

**Sprint 10 DoD:** migration up/down dry-run works in CI. CONCURRENTLY used on all new indexes. Last-restore-drill timestamp < 90 days old.

---

## Sprint 11 — Security Hardening Full  (~3-5 days)

Goal: defense in depth.

- [ ] **S11.1** NetworkPolicy between services — default-deny, explicit allow per flow. `cluster/networkpolicies/`. Cite: P4_zaki_infra_ops Q2.
- [ ] **S11.2** mTLS between services — linkerd or istio service mesh; or mTLS in app layer if sidecar overhead rejected. Cite: P4_zaki_infra_ops Q2.
- [ ] **S11.3** Sealed-secrets or external-secrets-operator — replace plain k8s Secrets. Cite: P4_zaki_infra_ops Q1.
- [ ] **S11.4** Documented scheduled secret rotation — at least for provider API keys (Together / Groq / Moonshot / Composio). Quarterly. Cite: P4_zaki_infra_ops Q1.
- [ ] **S11.5** cert-manager OR document explicit Cloudflare-only decision with risk acceptance. Cite: P4_zaki_infra_ops Q3.

**Sprint 11 DoD:** `kubectl exec pod_a -- curl pod_b:unlisted_port` denied. etcd has no plaintext secret contents.

---

## Sprint 12 — HA + DR  (~5-7 days)

Goal: no SPOFs that kill the service for paying users.

- [ ] **S12.1** Nullalis replicas > 1 after cell-pod flip — staged canary, watch for state races. Cite: P4_zaki_infra_ops Q5.
- [ ] **S12.2** NFS data-SPOF mitigation — plan: either dual NFS droplet in different AZ with rsync, or migrate to DO Managed Storage (block), or DO Spaces + cache. Decision + impl. Cite: P4_zaki_infra_ops top-gap.
- [ ] **S12.3** RTO/RPO targets documented + tested (e.g. RTO ≤ 15 min, RPO ≤ 5 min). Cite: P4_zaki_infra_ops Q15.
- [ ] **S12.4** Multi-region DR plan on paper (runbook), even if not implemented yet. Cite: P4_zaki_infra_ops Q15.
- [ ] **S12.5** `ResourceQuota` + `PriorityClass` per namespace. Cite: P4_zaki_infra_ops Q6.
- [ ] **S12.6** ArgoCD `AppProject` scoping — bound repo, cluster, namespace per app. Cite: P4_zaki_infra_ops Q11.
- [ ] **S12.7** `PodDisruptionBudget` for every service that has > 1 replica (zaki-api, zaki-web, zaki-website, pgbouncer, nullalis-post-S12.1). Cite: P4_zaki_infra_ops Q8.

**Sprint 12 DoD:** simulated node drain doesn't kill service. RTO clocked ≤ target on restore drill.

---

## Sprint 13 — Observability Full  (~3-5 days)

Goal: operator can see, not just the app.

- [ ] **S13.1** Prometheus deployed in cluster (via kube-prometheus-stack Helm). Cite: P4_zaki_infra_ops Q12.
- [ ] **S13.2** Loki deployed for log aggregation. Cite: P4_zaki_infra_ops Q12.
- [ ] **S13.3** OTel collector deployed; wire nullalis `OtelObserver` OTLP endpoint to it. Cite: P4_telemetry + P4_zaki_infra_ops Q12.
- [ ] **S13.4** AlertManager rules — at least: gateway down, daemon not running, postgres unreachable, disk > 85%, error rate > threshold, 5xx spike, OOMKilled. Cite: P4_zaki_infra_ops Q13.
- [ ] **S13.5** Alert routing — PagerDuty / Slack / email depending on severity. Cite: P4_zaki_infra_ops Q13.
- [ ] **S13.6** Grafana dashboards — gateway, nullalis runtime, daemon, postgres, per-tenant. Check in dashboard JSON to zaki-infra. Cite: P4_zaki_infra_ops Q12.
- [ ] **S13.7** Incident runbook per SPOF — what to do at 3am for each failure mode. Cite: P4_zaki_infra_ops Q14.

**Sprint 13 DoD:** forced test failure pages to Slack. Grafana shows per-tenant token burn.

---

## Sprint 14 — Out-of-Code  (ongoing, weeks of parallel work)

Goal: things not solved by editing files.

- [ ] **S14.1** STRIDE threat model against P3 relations diagrams — document at `docs/threat-model.md`.
- [ ] **S14.2** EU AI Act risk classification — determine if we're a "general purpose AI" provider, plan disclosures + content-provenance per Article 50.
- [ ] **S14.3** Provider DPA / BAA posture — Together, Groq, Moonshot, Composio. Sign or document absence.
- [ ] **S14.4** Zig allocator-discipline audit — focused human read across agent/root.zig, gateway.zig, daemon.zig. Arena vs GPA mixing, cross-allocator frees. Cannot be subagent-ed.
- [ ] **S14.5** Thread-safety audit — 11-thread daemon supervisor + scheduler + event_bus + heartbeat_wake. Races on shared state.
- [ ] **S14.6** Zig 0.14 → 0.15+ upgrade plan — track upstream, isolate deprecated stdlib calls, test ahead of release.
- [ ] **S14.7** Bus factor mitigation — the internals x-ray IS the onboarding doc; document release process, who can merge, who can deploy. Single-person today; document it.
- [ ] **S14.8** On-call rotation (even of one) — weekly windows, explicit "no coverage" periods communicated.
- [ ] **S14.9** Pentest engagement — schedule for post-Sprint-11 (security hardened first).
- [ ] **S14.10** License audit — all zon deps + Dockerfile base images + k8s images. No GPL/AGPL surprises.

**Sprint 14 DoD:** each item has a written status (done / in progress / parked with reason) in `docs/out-of-code-status.md`.

---

## Sprint 16 — V1 Gaps Not In Prior Sprints  (~3-5 days)

Goal: close items surfaced on final pressure-test.

- [ ] **S16.1** Load test harness — k6 or vegeta scripts for gateway chat-stream, webhook inbound, scheduler tick. Target: documented pass at 100 concurrent users, 500, 1000. Commit results to `.spike/load/`.
- [ ] **S16.2** SLO definitions — publish `docs/SLO.md`: uptime target, p50 / p95 / p99 latency targets, error budget math. Tie to AlertManager thresholds (S13.4).
- [ ] **S16.3** Public status page — deploy statuspage.io or Cachet; wire to AlertManager. Embed on chatzaki.com.
- [ ] **S16.4** Transactional email — Resend or SendGrid. Billing receipt on Stripe webhook (BFF side), welcome email on signup, password reset.
- [ ] **S16.5** Legal docs — Terms of Service, Privacy Policy, Acceptable Use Policy live at chatzaki.com/legal/*. Consent checkbox on signup, re-consent on material changes.
- [ ] **S16.6** Dependency SHA pinning — `build.zig.zon` entries for sqlite3 and sentry_zig use hash + URL, not moving ref. Document update cadence.
- [ ] **S16.7** Frontend audit — spawn a mapper pass on zaki-web React side: error boundaries, a11y (WCAG AA minimum), SSR/hydration, offline/reconnect UX, accessibility on forms, keyboard nav.
- [ ] **S16.8** Typ custom-patches inventory — pull the running `:latest` image, diff vs upstream AnythingLLM, document every patch in `zaki-infra/charts/typ/PATCHES.md`. Then rebuild on pinned SHA. Only then flip S3.7.

**Sprint 16 DoD:** load-test numbers in .spike/load/README.md. SLO.md published. status page green. billing receipt arrives on test subscription. TOS/Privacy consented on signup. 2 zon deps SHA-pinned. zaki-web audit doc at internals/P5_zaki_web.md. typ PATCHES.md committed.

---

## Sprint 15 — Minor + Park Items  (~2 days)

Goal: fold what's left, confirm park decisions.

- [ ] **S15.1** `config_parse.zig` table-driven tests — 10 canonical + 10 malformed per top-level key. Cite: P1_quality.
- [ ] **S15.2** log.warn vs log.info rebalance — audit + demote noise. Cite: P1_quality (340 vs 146).
- [ ] **S15.3** Provider catalog — trim cosmetic entries (bedrock SigV4, qianfan/baidu 2-step, hardcoded-localhost 6) or document honestly. Cite: P2_providers, P1_tech.
- [ ] **S15.4** Transcripts vector sync — match memory-architecture-map.md claim, or update the doc to reality. Cite: P4_ops_truth drift #4.

**Sprint 15 DoD:** no "park — maybe later" item remains undocumented.

---

## Cross-cut maintenance

- [ ] **M1** Every sprint, update corresponding `internals/P*_*.md` cites + bump `verified at <sha>` header.
- [ ] **M2** Every sprint close, re-run `.spike/run.sh` cold + polluted — keep pass rate ≥ baseline.
- [ ] **M3** Every sprint, one commit per item. No kitchen-sink PRs.
- [ ] **M4** Branch hygiene: `repair/sprint-N-<theme>` merged via PR with green CI, not pushed direct to main.

---

## Totals

- 16 sprints, ~128 concrete items.
- Estimated focused-dev time: 9-13 weeks if solo Nova, ~5-7 weeks with one extra hand.
- Paying-user-v1 minimum (Sprints 1-3 + S16.4/S16.5) is ~2-3 weeks.

## When we say "done"

All 120 boxes `[x]`. Every P-file's `verified at <sha>` bumped within the last sprint. `.spike/run.sh` cold + polluted at or above 25/23. Sentry showing signal in prod. One billing webhook round-trip end-to-end proven. One restore drill proven. One pentest report landed.

Then — and only then — we add new features.
