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
- [ ] **S2.12** `GET /api/v1/users/:id/secrets/:key` → metadata-only response (no plaintext). Cite: plan.md §3. _Carried → D8._
- [ ] **S2.13** `POST /api/v1/users/:id/secrets/:key/prepare` → issue confirmation token. Cite: plan.md §3. _Carried → D8._
- [ ] **S2.14** `PUT /api/v1/users/:id/secrets/:key` → requires valid confirmation token. Cite: plan.md §3. _Carried → D8._
- [ ] **S2.15** `DELETE /api/v1/users/:id/secrets/:key` → requires valid confirmation token. Cite: plan.md §3. _Carried → D8._
- [ ] **S2.16** Audit trail — new `zaki_bot.secret_mutations` table, row per attempt. Cite: plan.md §3 + plan-v02 §6. _Carried → D8._

**Sprint 2 DoD:** free-tier user hits chat stream → 402. Pro-tier user passes. Stripe cancel webhook → nullalis session revoked within 5s. CostTracker writing JSONL. Secret PUT without prepare token → 401.

---

## Sprint 3 — CI + Deploy Safety  (~3-5 days)

Goal: bad code can't reach prod; infra PR has a gate.

- [ ] **S3.1** Pin Zig `0.15.2` across `.github/workflows/ci.yml`, `flake.nix`, `Dockerfile`. Single source of version. Cite: P4_ci_cd top-gap #2.
- [ ] **S3.2** `.spike/run.sh` cold + polluted as required CI gate on PRs touching `src/`. Cite: P4_ci_cd.
- [ ] **S3.3** `release.yml` canonical-profile job must run `zig build test -Dengines=all` (currently build-only). Cite: P4_ci_cd top-gap #3.
- [ ] **S3.4** `deploy-zaki-runtime.yml` — add smoke test against staging, manual-approval gate, explicit rollback step. Cite: P4_ci_cd top-gap #3.
- [ ] **S3.5** zaki-infra — add `.github/workflows/validate.yml` enforcing `scripts/validate-nullalis-deploy.sh` (SHA-pinned tag validator) on every PR. Cite: P4_zaki_infra_ci top-gap #1.
- [ ] **S3.6** zaki-infra — add staging overlay in `argocd/` + `charts/` values-staging.yaml, or document explicit single-env decision with risk acceptance. Cite: P4_zaki_infra_ci top-gap #3.
- [ ] **S3.7** typ `:latest` on DOCR → pin to immutable SHA; backup custom patches to GHCR before flip. Cite: P4_zaki_infra_ci mutable-tag, memory-flagged.

**Sprint 3 DoD:** PR to main requires tests green. Tag push runs tests. Deploy-to-prod needs manual click. zaki-infra PR with floating tag is rejected by CI. typ image SHA-pinned in charts/typ/values.yaml.

---

## Sprint 4 — Silent-Catch Sweep  (~3-5 days)

Goal: system stops failing silently. Pattern: `catch {}` → `catch |err| log.warn(...)` + counter, never abort unless operator-critical.

### Durable writes
- [ ] **S4.1** `agent/root.zig:2371` (user autosave) — log + metric.
- [ ] **S4.2** `agent/root.zig:2427` (learning-fact) — log + metric.
- [ ] **S4.3** `agent/root.zig:3169` (assistant autosave) — log + metric.
- [ ] **S4.4** `session.zig:682-683` (saveMessage) — log + metric.
- [ ] **S4.5** `session.zig:715` (saveMessage other site) — log + metric.

### Daemon
- [ ] **S4.6** `daemon.zig:476` — `deleteCompletionEvent` log + new `lane_metrics.recordCompletionEventDeleteFailure` counter.
- [ ] **S4.7** `daemon.zig:962` — `writeStateFile` log + `health.markComponentError("heartbeat", ...)` on failure, skip ok-mark.

### Gateway operator-critical
- [ ] **S4.8** `gateway.zig:1180` — `applyProfileDefaults catch {}` — log + metric.
- [ ] **S4.9** `gateway.zig:1205` — same function, different call site.
- [ ] **S4.10** `gateway.zig:6231` — same pattern.
- [ ] **S4.11** `gateway.zig:6220, :6229` — `cfg.parseJson catch {}` on tenant config — log + metric.
- [ ] **S4.12** `gateway.zig:8684, :8685` — `subscriber.markDelivered` in `/chat/events` — log + metric.
- [ ] **S4.13** `gateway.zig:8713, :8714` — `sm.deleteCompletionEvent` — log + metric.

### Categorize the remaining 54 noise catches
- [ ] **S4.14** Annotate each `catch {}` in gateway.zig with either `// noisy-by-design: <reason>` or convert. Target: zero unlabeled silent catches.

**Sprint 4 DoD:** `grep -c "catch {}" src/gateway.zig src/daemon.zig src/agent/root.zig src/session.zig` shows ≤ noise-count. All 13 operator-critical sites fixed. Sentry captures a seeded test failure from each site.

---

## Sprint 5 — Architectural Correctness  (~5-7 days)

Goal: architectural claims match wire behavior.

- [ ] **S5.1** Anthropic two-block cache — change `serializeSystemCacheable` to emit `[{type:"text", text: stable+tools, cache_control: ephemeral}, {type:"text", text: volatile}]`. Cite: `anthropic.zig:480/547`, P2_context_v2, P2_providers. Verify with p50 TTFT proxy.
- [ ] **S5.2** Error classification carrier — `reliable.zig:296-301` replace `storeErrorName(@errorName)` with `{kind: ApiErrorKind, retry_after_ms: ?u64}` populated from body parsers. Delete 4 dead helpers (`isRateLimited`/`isContextExhausted`/`isNonRetryable`/`parseRetryAfterMs`). Cite: P2_providers.
- [ ] **S5.3** Streaming context-exhaustion recovery parity — `agent/root.zig:2652` mirror the `:2731-2760` force-compress-and-retry flow. Cite: P2_turn_loop.
- [ ] **S5.4** Sort tools prose block — `prompt.zig:584-594` sort `self.tools` by name before rendering. Cite: P2_context_v2.
- [ ] **S5.5** Sort skills directory iteration — `prompt.zig:639-719` `listSkillsMerged` must sort before rendering. Cite: P2_context_v2.
- [ ] **S5.6** Byte-equality test — unit test calling `buildStableSystemPrompt` twice with identical inputs, `expectEqualStrings`. Cite: P2_context_v2.
- [ ] **S5.7** `Config.load` memoize — `agent/root.zig:2245` honor workspace_prompt_fingerprint; only reload on change. Cite: P2_turn_loop.
- [ ] **S5.8** Stage-17 disambiguate — `agent/root.zig:3524+` and `:2561` separate loop-detected-exit from iteration-exhausted in observer event + return prefix. Cite: P2_turn_loop.

**Sprint 5 DoD:** Anthropic cache hit p50 TTFT drops ≥ 10% on turn 2+. `reliable.zig` has no `indexOf` heuristics. Byte-eq test green. stage-17 observer events match actual exit cause.

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

### Delete path (GDPR-grade)
- [ ] **S7.1** Compose `purgeUser(user_id)` in `zaki_state.zig` — single transaction, FK order aware. Must call: `deleteSecret:1140`, `clearJobs:1322`, `clearSessionMessages:1397`, `deleteCompletionEvent:1514`, `forgetMemory:1679`, `deleteChannelIdentityBinding:1917`, `releaseUserOwnershipLease:2016`, `deleteTelegramState:1056`. Cite: P2_session_storage.
- [ ] **S7.2** Missing helpers — implement `deleteAllTasks`, `deleteSession` row, user-scoped bulk DELETE for `messages`/`memories`/`completion_events`/`leases`. Cite: P2_session_storage.
- [ ] **S7.3** `evictUserSessions` cache purge on session manager. Cite: P2_session_storage.
- [ ] **S7.4** Filesystem + vector (`store_pgvector.memory_embeddings`) in purge scope. Cite: P2_session_storage + P4_schema.
- [ ] **S7.5** End-to-end test: seed user, verify `purgeUser`, assert zero rows across all tables.
- [ ] **S7.6** API surface: `DELETE /api/v1/users/:id/data` gated by confirmation token.

### Voice polish
- [ ] **S7.7** TTS failure-notice parity with STT — `voice.zig` emit `emitMultimodalFailureNotice` on error, no silent drop to text. Cite: P2_voice.
- [ ] **S7.8** Channel-locality enforcement — `MessageTool.send` must pin to inbound channel unless explicitly overridden. Cite: P2_voice, session.zig:597.
- [ ] **S7.9** `voice_mode.zig` capability honesty — either wire discord/whatsapp/slack audio send path, or remove their TTS-capable claim. Cite: P2_voice.

### Audit coverage
- [ ] **S7.10** Wire `bindAuditMemory` on CLI + gateway boot paths (currently only `channel_loop.zig:435`). Cite: P2_tools.

### Integration hardening (P4)
- [ ] **S7.11** MCP `readLine` timeout — default 30s, configurable. Cite: P4_integrations.
- [ ] **S7.12** MCP stderr pipe drain loop. Cite: P4_integrations.
- [ ] **S7.13** Telegram secret constant-time compare — `std.crypto.timingSafeEql`. Cite: P4_integrations.
- [ ] **S7.14** Composio 429/retry with exponential backoff. Cite: P4_integrations.
- [ ] **S7.15** Composio `list` cache (60s TTL) to cut latency + cost. Cite: P4_integrations.

**Sprint 7 DoD:** Delete-account flow E2E passes on seeded tenant. TTS failure surfaces a notice. MCP hung-server test times out cleanly. Telegram secret passes timing-safe test.

---

## Sprint 8 — Design Decisions  (~2-3 days, decisions + small code)

Goal: W5 ambiguities resolved. Each gets a YES/NO/DEFER with written rationale; resulting code work queued into later sprint if needed.

- [ ] **S8.1** W5.1 Lane-aware memory retrieval — decision + code (filter vs label vs keep-as-is). Cite: P2_memory_pipeline, P2_lanes.
- [ ] **S8.2** W5.2 `buildThreadSessionKey` legacy vs canonical — migrate, dual-parser, or deprecate. Cite: P2_lanes.
- [ ] **S8.3** W5.3 NULLCLAW_ → NULLALIS_ rebrand — bridge shim (`tryNullalisThenNullclaw` helper) or park. Currently 42 vs 5. Cite: P1_quality.
- [ ] **S8.4** W5.4 Dormant channel implementations — 15 impls; delete, formalize as flag set, or keep. Cite: P1_arch.
- [ ] **S8.5** W5.5 `.task` lane production path — wire when multiagent flips, delete until ready, or keep inert. Cite: P2_lanes.
- [ ] **S8.6** W5.6 `channels/dingtalk.zig` — add tests or mark dormant. Cite: P1_quality.

**Sprint 8 DoD:** each decision has a line in CLAUDE.md or similar explaining the call + date. Follow-up code queued.

---

## Sprint 9 — Supply Chain Full  (~3-5 days)

Goal: can prove what shipped.

- [ ] **S9.1** Branch-protection-as-code on `main` (GitHub ruleset or settings.yml).
- [ ] **S9.2** `CODEOWNERS` file — even if single-owner today, documents it.
- [ ] **S9.3** Dependabot or Renovate — at minimum for `build.zig.zon` deps + Dockerfile base image.
- [ ] **S9.4** SAST — CodeQL (free for public) or Semgrep.
- [ ] **S9.5** SBOM generation (syft) on every release, published with artifact.
- [ ] **S9.6** Secret scanning — gitleaks pre-commit + CI.
- [ ] **S9.7** Container scanning — trivy on built image in CI.
- [ ] **S9.8** cosign image signing + SLSA level-1+ provenance.

**Sprint 9 DoD:** release pipeline produces SBOM.spdx + cosign signature. trivy blocks high-severity CVE. gitleaks blocks secret commit.

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
