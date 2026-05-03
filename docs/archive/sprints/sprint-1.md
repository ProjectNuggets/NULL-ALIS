---
tags: [prose, prose/docs]
---

# Sprint 1 — Visibility + Stop Bleeds — CLOSED

**Branch:** `repair/sprint-1-visibility`
**Sprint range:** `87cb435` (main baseline) → `7b54dae` (sprint close)
**Opened:** 2026-04-22
**Closed:** 2026-04-23
**PR:** [NULL-ALIS#9](https://github.com/ProjectNuggets/NULL-ALIS/pull/9)
**Cross-repo commits:** `zaki-infra` main @ `c329e9a`

Goal: prod emits real signal; no active user-visible data-loss or first-click bugs.

---

## Ship summary (14 commits)

| # | Commit | Item | One-line |
|---|--------|------|----------|
| 1 | `cc063fc` | docs | Closure checklist v1 — 16 sprints, ~128 items |
| 2 | `2b6c157` | **S1.1** | Sentry DSN wired — `NULLALIS_*` primary, `NULLCLAW_*` fallback chokepoint |
| 3 | `fdfa37b` | **S1.2** | `Runtime` implements `Observer` — inner-loop `.err` and elevated `.system_notice` reach Sentry |
| 4 | `73eeb57` | **S1.3** | `install_signal_handlers` default flipped to `true` |
| 5 | `1ed9be3` | **S1.8** | Voice TTS inbound gate matches `[voice]` / `[audio]` (Telegram's `[Voice]:` emission) |
| 6 | `6799140` | **S1.13** | pgvector dim-mismatch refuses destructive rebuild; opt-in via env |
| 7 | `e761d53` | carry | `HttpRequestConfig.enabled` default true |
| 8 | `b904142` | **S1.6** | cron `loadJobsStrict` + `loaded_from_disk` guard — stops boot-time self-heal from wiping `cron.json` |
| 9 | `8cad56a` | **S1.7** | `clearAutoSaved` postgres impl — `/new` actually deletes `autosave_*` rows |
| 10 | `2197c79` | **S1.4** | `std_options.logFn` → JSON lines via `NULLALIS_LOG_FORMAT=json` |
| 11 | `10fba9b` | **S1.5** | `OtelObserver.fromEnv` + attach in both gateway composition sites |
| 12 | `87b083f` | **S1.9** | Remove inert `DecisionSource.session_cache` scaffolding, embed full feature-design comment |
| 13 | `963fc92` | **S1.10** | Gateway emits honest `EMPTY_TURN_PLACEHOLDER` instead of fabricating `"received"` |
| 14 | `7b54dae` | close | Sprint 1 CLOSED annotation in checklist |

Cross-repo:
- `zaki-infra` @ `c329e9a` — `charts/nullalis/README.md` documents `NULLALIS_*` secrets + observability keys + rebrand migration notes.
- `zaki-prod` — S1.11 verified stale (BFF `bot-bff.js:930` already correct). No change committed.

---

## DoD verification log

Per-item verdict at sprint close (`7b54dae`). Green = DoD holds without further action. Yellow = passed in code, awaiting live-staging confirmation before go-live.

| Item | DoD | Verdict | Evidence |
|------|-----|---------|----------|
| **S1.1** | `NULLALIS_SENTRY_DSN` read by runtime; `NULLCLAW_*` still accepted | 🟢 | `sentry_runtime.zig` bootstrap uses `getEnvVarOwnedWithFallback`; k8s template documents both keys |
| **S1.2** | `.err` event reaches Sentry in both gateway composition sites | 🟢 | `Runtime.observer()` returns vtable-backed observer; `gateway.zig:1336+` and `:14157+` attach it via `globalOrFallback` |
| **S1.3** | Signal handlers on by default, operator can opt out | 🟢 | `sentry_runtime.zig:94` default `true`; env escape hatch preserved |
| **S1.4** | Logs emit valid JSON when `NULLALIS_LOG_FORMAT=json` | 🟡 | `log_fmt.zig` unit test covers format parser + JSON escape; needs live confirmation post-deploy |
| **S1.5** | OtelObserver attaches only when `NULLALIS_OTEL_ENDPOINT` set | 🟢 | `OtelObserver.fromEnv` returns null on empty env; NoopObserver fills the slot; two composition sites wired |
| **S1.6** | Corrupt `cron.json` at boot → empty scheduler + `log.err` + file NOT overwritten | 🟢 | `daemon.zig:1456` uses `loadJobsStrict`; `cron.zig:1902-1909` self-heal gated on `loaded_from_disk` flag |
| **S1.7** | `/new` deletes postgres `autosave_user_*` + `autosave_assistant_*` rows | 🟢 | `Manager.clearAutoSavedMemory` DELETE query scoped by user_id + optional session_id; `UserSessionStore.clearAutoSaved` vtable bridge routes to it |
| **S1.8** | Telegram voice note with `voice_replies=on` triggers TTS | 🟡 | `agent/root.zig:854-866` substring now matches `[voice]` and `[audio]` (Telegram emits `[Voice]:`); needs live Telegram test |
| **S1.9** | `DecisionSource.session_cache` removed OR wired end-to-end | 🟢 | Removed + full feature-design comment embedded for revival |
| **S1.10** | Tool-only turn surfaces honest placeholder (not `"received"`) | 🟢 | `gateway.zig:9200` and `:10578` use `EMPTY_TURN_PLACEHOLDER`; architectural `TurnOutcome` refactor queued as deferred item D1 |
| **S1.11** | BFF `/v1/me/bot/settings PATCH` reaches a 200-returning nullalis route | 🟢 | Verified already correct at `zaki-prod/backend/src/bot-bff.js:930`; P4_ops_truth drift #1 was stale |
| **S1.12** | k8s Secret templated for new observability keys | 🟢 | `deploy/k8s/zaki-bot/01-secrets-template.yaml` + `zaki-infra/charts/nullalis/README.md` both updated; operator must set real values at go-live |
| **S1.13** | pgvector dim change does not silently drop embeddings | 🟢 | `store_pgvector.zig:394+` returns `error.PgVectorDimensionMismatch` unless env override explicitly set |

Build gate: `zig build test -Dengines=all` green at every commit in the sprint chain.

---

## Files touched + internals P-file cites

| File(s) | P-file | Sha bumped? |
|---------|--------|-------------|
| `src/sentry_runtime.zig`, `src/main.zig`, `src/log_fmt.zig`, `src/observability.zig`, `src/gateway.zig` (observer slots) | `P4_telemetry.md` | ✅ to `7b54dae` |
| `src/memory/vector/store_pgvector.zig` | `P4_schema.md` | ✅ to `7b54dae` |
| `src/cron.zig`, `src/daemon.zig` | `P2_scheduler.md` | ✅ to `7b54dae` |
| `src/zaki_state.zig` (`clearAutoSavedMemory`) | `P2_session_storage.md` | ✅ to `7b54dae` |
| `src/agent/root.zig` (`ttsModeEnabledForTurn`) | `P2_voice.md` | ✅ to `7b54dae` |
| `src/security/approval_modes.zig` | `P2_tools.md` | ✅ to `7b54dae` |
| `src/gateway.zig` (`EMPTY_TURN_PLACEHOLDER`) | `P2_subagent_delegate.md` | ✅ to `7b54dae` |
| `src/gateway.zig` (observer_slots bump + otel) | `P2_gateway.md` | ⚠️ partial — drift note added, full re-verify deferred to Sprint 4 |
| `deploy/k8s/zaki-bot/01-secrets-template.yaml`, `zaki-infra/charts/nullalis/README.md` | `P4_ops_truth.md` | ✅ to `7b54dae` (S1.11 note + S1.12 template updates noted) |
| `src/config_types.zig` (`HttpRequestConfig.enabled`) | — | n/a (carry commit, not a P-file claim) |

---

## `.spike/run.sh` decision

**Skipped for Sprint 1.** Per the new gating rule, `.spike/run.sh` runs for sprints that alter agent behavior (turn loop, memory retrieval, compaction, streaming, provider path, context v2, entitlement enforcement). Sprint 1's scope was observability + data-integrity guards + operator-visible bugs — none change per-benchmark answer quality or latency beyond the Anthropic cache path which was NOT touched this sprint.

**Required full-spike run:** held for the closure-complete go-live promotion per the "don't promote image until closure done" rule.

---

## Deferred items (explicitly tracked, nothing silent)

| ID | Item | Target sprint | Rationale |
|----|------|---------------|-----------|
| D1 | Full `TurnOutcome` struct-return + structured tool-only-turn SSE frame | TBD (architectural sprint, post-revenue-loop) | Touches `session.zig:530` signature + gateway + BFF + frontend consumers. Interim `EMPTY_TURN_PLACEHOLDER` unblocks the user-visible symptom for the closure window |
| D2 | Run-scoped approvals feature (`/approve allow-run`) | Sprint 4+ / Wave M | Needs new verb + session-scoped cache with explicit lifetime + 5-step design doc already embedded in `security/approval_modes.zig` |
| D3 | Re-verify `P2_gateway.md` cite accuracy after Sprint 4 silent-catch sweep | Sprint 4 close | Sprint 1 added fields (`otel_obs`, `noop_obs`) + const `EMPTY_TURN_PLACEHOLDER` that aren't yet reflected in the P-file; full re-pass cheaper after S4 also touches gateway |
| D4 | Live-staging verification of S1.4 JSON-log format + S1.8 Telegram voice reply | Post-deploy smoke | In-repo unit test + grep sanity caught the regressions we'd expect; real env still needs confirmation |

---

## Post-merge / go-live checklist (when full closure done)

1. Push `zaki-infra` @ `c329e9a`
2. Set live k8s Secret: `NULLALIS_SENTRY_DSN`, `NULLALIS_STATE_MASTER_KEY` (REQUIRED — plaintext user_secrets without it)
3. Optional but strongly recommended: `NULLALIS_OTEL_ENDPOINT`, `NULLALIS_LOG_FORMAT=json`, `NULLALIS_SENTRY_ENVIRONMENT=production`
4. Promote image tag in `zaki-infra/charts/nullalis/values.yaml`

---

## What Sprint 2 inherits

Nothing blocking. Sprint 1 is self-contained. Sprint 2 branch (`repair/sprint-2-revenue-loop`) opens off a clean main once PR #9 merges (image promotion held per go-live rule).
