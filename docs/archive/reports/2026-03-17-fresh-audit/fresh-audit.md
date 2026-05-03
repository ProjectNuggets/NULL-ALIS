---
tags: [prose, prose/docs]
---

# Fresh Audit

Date: 2026-03-17

Method: repo-only audit from current checkout. I inspected runtime code, manifests, and tests, then ran `zig build test --summary all` and `zig build -Doptimize=ReleaseSmall`. No code was edited in this pass.

## A) Executive Summary

- Confirmed fact: app chat-stream requests now require an explicit tenant-owned `session_key` by default, and the gateway rejects missing keys with `400 missing_session_key`; the current staging smoke script still omits that field, so the shipped smoke contract does not match runtime behavior. (`src/config_types.zig:778-794`, `src/gateway.zig:5131-5150`, `src/gateway.zig:5242-5266`, `deploy/k8s/zaki-bot/smoke.sh:50-53`)
- Confirmed fact: tenant Telegram traffic is still biased onto `main` in practice because `cross_channel_shared_main` defaults to `true`, the tenant webhook honors that flag, and the staging deployment hardcodes it to `true`. (`src/config_types.zig:1023-1029`, `src/gateway.zig:3414-3417`, `src/gateway.zig:6745-6748`, `src/gateway.zig:6806-6808`, `deploy/k8s/zaki-bot/05-deployment.yaml:109-111`)
- High-confidence inference: lane isolation exists in the key format and validator, but defaults still collapse a meaningful share of Telegram DM traffic onto `main`; thread/task/cron isolation is not the operational default today. (`src/zaki_session.zig:3-17`, `src/gateway.zig:5093-5150`, `src/gateway.zig:6745-6808`)
- Confirmed fact: pre-provider compaction is on the hot path before cache/provider execution and can add 1-3 extra provider calls, so it is a credible latency source; whether it is the dominant source cannot be proven from code alone because no exported latency metric breaks down that stage. (`src/agent/root.zig:1156-1238`, `src/agent/compaction.zig:75-128`, `src/agent/compaction.zig:267-321`, `src/gateway.zig:3778-3900`)
- Confirmed fact: Telegram tenant handling is architecturally synchronous today: webhook request, ownership lock, state/secret lookup, canonicalization, `processMessage`, and outbound reply all happen before the HTTP handler returns. (`src/gateway.zig:6545-6915`)
- Confirmed fact: runtime config source-of-truth is unified to Postgres when `zaki_state` is healthy, but config/settings writes are not mirrored back to file fallback, so failover to file state can reintroduce stale per-user config. (`src/gateway.zig:742-780`, `src/gateway.zig:5843-5925`, `src/gateway.zig:8269-8278`)
- Confirmed fact: per-user filesystem scoping is correct at the path layer: user data is rooted under `<tenant_data_root>/<user_id>/...`, and tenant runtimes inject tenant context with that user id into tool execution. (`src/gateway.zig:1464-1521`, `src/gateway.zig:979-1004`)
- Confirmed fact: Postgres tenant memory is not pure Postgres; the gateway forces markdown, wraps it in `zaki_dual`, and re-syncs markdown into Postgres on read/list/get, which trades durability compatibility for repeated sync overhead. (`src/gateway.zig:781-843`, `src/memory/engines/zaki_dual.zig:35-79`, `src/memory/engines/markdown.zig:1-8`, `src/memory/engines/markdown.zig:210-255`)
- Confirmed fact: drain/readiness semantics are mostly safe for admission control, but active streams are not guaranteed safe across pod termination because ingress permits 3600s streams while pod grace is 90s. (`src/gateway.zig:7786-7806`, `src/gateway.zig:7869-7890`, `src/gateway.zig:8046-8082`, `src/gateway.zig:8438-8445`, `deploy/k8s/zaki-bot/05-deployment.yaml:31`, `deploy/k8s/zaki-bot/07-ingress.yaml:12-19`)
- Confirmed fact: the repo is currently buildable and test-clean on this checkout: `4661 passed`, `25 skipped`, `0 failed`, `MaxRSS 42M`, and `ReleaseSmall` compiled successfully. (local validation run on 2026-03-17)

## B) Current Reality Map

### Canonical data/config sources

- Confirmed fact: when tenant Postgres state is available, per-user config is loaded from `zaki_state.getConfigJson`; if DB config is empty, the gateway seeds Postgres from file once and marks the effective source accordingly. (`src/gateway.zig:742-780`)
- Confirmed fact: config/settings API writes go to Postgres only when `state.zaki_state` exists; the file fallback copy is not updated on those writes. (`src/gateway.zig:5857-5871`, `src/gateway.zig:5899-5925`)
- Confirmed fact: Telegram bot-token secret handling is different: DB writes are mirrored to the file secret explicitly for fallback compatibility. (`src/gateway.zig:6231-6248`)
- Confirmed fact: if Postgres state init fails at startup, gateway degrades to file state and records that degradation in self-check fields. (`src/gateway.zig:2449-2477`, `src/gateway.zig:8269-8278`)
- Confirmed fact: in tenant Postgres mode, memory is not directly the generic Postgres engine; gateway forces markdown, builds `ZakiPostgresMemory`, wraps it in `ZakiDualMemory`, and syncs markdown into Postgres before use. (`src/gateway.zig:781-843`, `src/memory/engines/zaki_dual.zig:35-79`)
- Confirmed fact: file-mode tenant state is per-user under `<tenant_data_root>/<user_id>/workspace`, `memory.db`, `config.json`, `cron.json`, `heartbeat.json`, `channel_state.json`, `telegram.json`, and `secrets/`. (`src/gateway.zig:1464-1500`, `src/gateway.zig:1509-1521`)

### Request/response path: app stream

- Confirmed fact: `/api/v1/chat/stream` validates internal auth, provisions/resolves tenant user context, enforces an explicit tenant-owned `session_key` by default, records lane metrics, and then calls `tenant_runtime.processMessage(..., channel = "zaki_app", progress_observer)` for the SSE connection path. (`src/gateway.zig:5238-5306`)
- Confirmed fact: `TenantRuntime.processMessage` sets tenant context with `user_id`, `state_mgr`, and expected backend, then delegates to `SessionManager.processMessageWithContext`. (`src/gateway.zig:979-1004`)
- Confirmed fact: `SessionManager` serializes per-session work behind `session.mutex`, records lock wait as an observer event only, runs `agent.turn`, then persists user/assistant messages via the session store. (`src/session.zig:375-515`)
- Confirmed fact: the SSE connection path sends a status frame first, but still emits token frames only after `processMessage` returns the full reply buffer. (`src/gateway.zig:5269-5351`)
- Confirmed fact: the non-connection HTTP path also returns `text/event-stream`, but it is fully buffered: it calls `processMessage(..., null)` and only then renders one SSE payload. (`src/gateway.zig:5567-5652`)

### Request/response path: Telegram webhook

- Confirmed fact: tenant Telegram webhook requires `user_id`, validates it, acquires the tenant ownership lock, loads Telegram channel state, resolves per-user bot token, and validates Telegram’s secret-token header before processing the message. (`src/gateway.zig:6521-6664`)
- Confirmed fact: the webhook uses Postgres-backed duplicate suppression when tenant Postgres state exists, otherwise an in-memory idempotency key. (`src/gateway.zig:6666-6690`)
- Confirmed fact: tenant webhook canonicalization uses channel identity keys plus fallback session choice, then calls `tenant_runtime.processMessage` synchronously and sends the Telegram reply before completing the HTTP request. (`src/gateway.zig:6751-6915`)
- Confirmed fact: the code explicitly documents why tenant Telegram stayed synchronous: async queueing could acknowledge the webhook while losing the reply later. (`src/gateway.zig:6739-6741`)
- Confirmed fact: an async Telegram worker still exists in code, but it hardcodes `userMainSessionKey` and is not used by the tenant webhook path. (`src/gateway.zig:2170-2321`, `src/gateway.zig:2222-2229`, `src/gateway.zig:6739-6915`)

### Lane mapping behavior in practice

- Confirmed fact: canonical tenant lanes exist as `main`, `thread:<id>`, `task:<id>`, and `cron:<id>`. (`src/zaki_session.zig:3-17`)
- Confirmed fact: chat-stream session key validation accepts only those tenant lanes and rejects cross-user or malformed overrides. (`src/gateway.zig:5083-5150`, `src/gateway.zig:11561-11630`)
- Confirmed fact: strict explicit-key enforcement is enabled by default in gateway config. (`src/config_types.zig:778-794`)
- Confirmed fact: Telegram uses shared-main routing unless `session.cross_channel_shared_main` is disabled; absent config, helper logic returns `true`. (`src/config_types.zig:1023-1029`, `src/gateway.zig:3414-3417`, `src/gateway.zig:10306-10321`)
- Confirmed fact: when shared-main is disabled, tenant Telegram can feed a thread lane into canonicalization if a thread identity key exists; otherwise it still lands on `main`. (`src/gateway.zig:6745-6808`, `src/inbound_canonicalizer.zig:450-461`)
- High-confidence inference: app/BFF traffic can achieve lane isolation when the caller sends explicit canonical keys, but Telegram DMs are operationally collapsed onto `main` under the current deployment default. (`src/gateway.zig:5131-5150`, `src/gateway.zig:6745-6808`, `deploy/k8s/zaki-bot/05-deployment.yaml:109-111`)

### Explicit answers to the focus questions

1. Lanes isolated or collapsed?
   - Confirmed fact: app/BFF lanes are isolated when clients provide explicit canonical keys; missing keys are rejected by default, not silently collapsed. (`src/gateway.zig:5131-5150`, `src/gateway.zig:5242-5266`)
   - Confirmed fact: Telegram is not isolated by default because shared-main defaults to `true` and staging hardcodes it. (`src/config_types.zig:1023-1029`, `src/gateway.zig:3414-3417`, `src/gateway.zig:6745-6748`, `deploy/k8s/zaki-bot/05-deployment.yaml:109-111`)

2. Is pre-provider compaction the dominant latency culprit?
   - Confirmed fact: compaction is pre-provider and pre-cache, and can trigger extra provider `chat` calls. (`src/agent/root.zig:1177-1238`, `src/agent/compaction.zig:75-128`, `src/agent/compaction.zig:267-321`)
   - Unknown requiring runtime validation: dominance versus provider latency, session lock wait, or memory enrichment cannot be proven from current exported metrics because those stage durations are logged/observed but not emitted to `/metrics`. (`src/agent/root.zig:1163-1194`, `src/session.zig:469-477`, `src/gateway.zig:3778-3900`, `src/observability.zig:21-24`, `src/gateway.zig:4939-4939`)

3. Is Telegram slower by architecture, config, or bug?
   - Confirmed fact: architecture is the primary code-level reason today: tenant Telegram is synchronous, non-streaming, lock-gated, and reply-on-webhook. (`src/gateway.zig:6545-6915`)
   - High-confidence inference: config amplifies it when `cross_channel_shared_main=true`, because more Telegram DMs contend on the same `main` session mutex. (`src/config_types.zig:1023-1029`, `src/gateway.zig:6745-6808`, `src/session.zig:389-406`)
   - Unknown requiring runtime validation: there is not enough exported timing to prove whether Telegram slowness is dominated by lock contention, compaction, provider latency, or Telegram outbound API latency. (`src/session.zig:469-477`, `src/agent/root.zig:1163-1194`, `src/gateway.zig:3778-3900`)

4. Is config source-of-truth unified at runtime?
   - Confirmed fact: yes, when Postgres state is healthy, runtime loads config from Postgres first and records that source in diagnostics. (`src/gateway.zig:742-780`, `src/gateway.zig:4254-4359`)
   - Confirmed fact: drift still occurs across failover boundaries because config/settings writes are not mirrored to file fallback. (`src/gateway.zig:5857-5925`, `src/gateway.zig:8269-8278`)

5. Is per-user filesystem/state isolation correct end-to-end?
   - Confirmed fact: path-level isolation is correct for user-rooted files and workspace. (`src/gateway.zig:1464-1521`)
   - Confirmed fact: tenant tool/session execution carries tenant context with the current `user_id` and session key. (`src/gateway.zig:987-1000`)
   - High-confidence inference: end-to-end isolation is good at the user boundary, but not at the intra-user lane boundary under shared-main Telegram defaults. (`src/gateway.zig:6745-6808`)

6. Are deployment manifests and shutdown semantics safe for active chat streams?
   - Confirmed fact: admission control is mostly safe because drain makes `/ready` fail and rejects non-ops requests. (`src/gateway.zig:7786-7806`, `src/gateway.zig:7869-7890`, `src/gateway.zig:8046-8082`)
   - Confirmed fact: active long streams are not fully safe because ingress allows 3600-second streams while pod grace is 90 seconds, and the process only exits after in-flight work drains or Kubernetes kills it. (`src/gateway.zig:8438-8445`, `deploy/k8s/zaki-bot/05-deployment.yaml:31`, `deploy/k8s/zaki-bot/07-ingress.yaml:12-19`)

## C) Gap Analysis

| Gap | Impact | Evidence | Confidence | Fix candidate | Risk of change |
|---|---|---|---|---|---|
| Smoke test does not send required `session_key` | Staging smoke can fail against default gateway behavior and hide real regressions behind a broken test contract | `src/config_types.zig:778-794`, `src/gateway.zig:5131-5150`, `src/gateway.zig:5242-5266`, `deploy/k8s/zaki-bot/smoke.sh:50-53` | Confirmed fact | Update smoke payload to send a canonical tenant key such as `agent:zaki-bot:user:${USER_ID}:main`; add a negative smoke/assertion for missing key | Low |
| Telegram DM traffic defaults to shared `main` lane | Lane isolation goals are not met for Telegram by default; lock contention and context bleed risk increase within a user | `src/config_types.zig:1023-1029`, `src/gateway.zig:3414-3417`, `src/gateway.zig:6745-6808`, `deploy/k8s/zaki-bot/05-deployment.yaml:109-111` | Confirmed fact | Decide whether Telegram should be `main` or thread-routed by policy; if isolation is intended, set `cross_channel_shared_main=false` and add route tests covering tenant Telegram thread keys | Medium |
| Config/settings DB writes are not mirrored to file fallback | Postgres outage or startup degradation can resurrect stale per-user config/settings from disk | `src/gateway.zig:742-780`, `src/gateway.zig:5843-5925`, `src/gateway.zig:6237-6244`, `src/gateway.zig:8269-8278` | Confirmed fact | Mirror `config` and `settings` writes to the per-user file the same way Telegram secret writes already do, or explicitly remove file fallback for those resources | Medium |
| Pre-provider compaction can issue extra provider calls before cache lookup | User-facing latency can spike on long histories; compaction cost is paid before a cache hit can short-circuit | `src/agent/root.zig:1177-1238`, `src/agent/compaction.zig:75-128`, `src/agent/compaction.zig:267-321` | Confirmed fact for placement; dominant-latency claim remains unknown | Emit per-stage metrics, then consider moving cache lookup earlier for safe cases or constraining compaction thresholds for interactive lanes | Medium |
| Tenant Telegram path is synchronous and non-streaming | Telegram latency includes lock wait, canonicalization, full agent turn, and outbound send inside webhook SLA | `src/gateway.zig:6545-6915`, `src/gateway.zig:6739-6741` | Confirmed fact | Keep sync semantics if reply guarantee matters, but add route-specific latency metrics and queue/typing diagnostics before changing architecture | Medium |
| Async Telegram worker hardcodes `main` | If async path is re-enabled later, it will silently bypass lane policy and collapse traffic onto `main` | `src/gateway.zig:2170-2321`, `src/gateway.zig:2222-2229` | High-confidence latent regression | Refactor worker job payload to carry canonical session key instead of reconstructing `main` | Low |
| `zaki_dual` syncs markdown into Postgres on every recall/get/list | Read amplification and repeated sync work can slow turns and memory operations as markdown history grows | `src/gateway.zig:818-843`, `src/memory/engines/zaki_dual.zig:35-79`, `src/memory/engines/markdown.zig:210-255` | Confirmed fact | Add sync watermark/checkpointing or one-way migration semantics instead of full read-time sync; cover duplicate/upsert behavior in tests | Medium |
| Observability omits exported stage latency and queue/session gauges | Hard to prove whether stalls come from compaction, lock wait, provider time, or persistence from `/metrics` alone | `src/observability.zig:21-24`, `src/observability.zig:43-45`, `src/gateway.zig:3778-3900`, `src/agent/root.zig:1163-1194`, `src/session.zig:469-477`, `src/gateway.zig:4939-4939`, `src/session.zig:657-657` | Confirmed fact | Wire `Observer.recordMetric` into gateway/session/agent paths for request latency, active sessions, queue depth, compaction time, and lock-wait time | Medium |
| Long SSE allowance exceeds termination grace | Rolling updates or node eviction can cut active chat streams mid-turn after 90s grace expires | `src/gateway.zig:8046-8082`, `src/gateway.zig:8438-8445`, `deploy/k8s/zaki-bot/05-deployment.yaml:31`, `deploy/k8s/zaki-bot/07-ingress.yaml:12-19` | Confirmed fact | Align ingress timeout, app drain semantics, and `terminationGracePeriodSeconds`; add staged drain test with an intentionally long stream | Medium |
| ConfigMap advertises `SESSION_CROSS_CHANNEL_SHARED_MAIN`, deployment ignores it | Operators can believe they changed session policy when runtime still hardcodes `true` | `deploy/k8s/zaki-bot/02-configmap.yaml:39-40`, `deploy/k8s/zaki-bot/05-deployment.yaml:109-111` | Confirmed fact | Template `session.cross_channel_shared_main` from env or remove the dead config key | Low |
| Postgres session taxonomy collapses non-main kinds to `system` | Reporting/backoffice views can lose thread/task/cron semantics even when keys are lane-specific | `src/zaki_state.zig:1793-1813` | Confirmed fact | Persist actual lane kind derived from session key suffix instead of binary `main/system` | Low |

## D) Ranked TODOs

### P0 (must fix before beta)

- [ ] Fix chat-stream contract drift
  - Target files: `deploy/k8s/zaki-bot/smoke.sh`, `src/gateway.zig`, `src/gateway.zig` tests near `resolveChatStreamSessionKey`
  - Change: send explicit canonical tenant `session_key` in smoke; keep strict default behavior intact unless product intentionally changes the API
  - Verification:
    - Run `deploy/k8s/zaki-bot/smoke.sh` against staging with a valid `session_key`
    - Add/keep a negative test proving missing `session_key` returns `400`
    - Re-run `zig build test --summary all`

- [ ] Decide and enforce tenant Telegram lane policy
  - Target files: `deploy/k8s/zaki-bot/05-deployment.yaml`, `deploy/k8s/zaki-bot/02-configmap.yaml`, `src/gateway.zig`, `src/gateway.zig` tests near `tenantTelegramUsesSharedMain`
  - Change: either explicitly keep shared-main and document it as the product contract, or flip to isolated routing with `cross_channel_shared_main=false`
  - Verification:
    - Staging webhook test with DM + threaded Telegram inputs
    - Inspect `/internal/diagnostics` and `/metrics` lane counters before/after
    - Re-run `zig build test --summary all`

- [ ] Eliminate config drift between DB and file fallback
  - Target files: `src/gateway.zig` config/settings handlers, adjacent fallback tests
  - Change: mirror DB-backed config/settings writes to user file fallback or remove file fallback reads for those resources
  - Verification:
    - PATCH `/api/v1/users/{id}/config`
    - Force Postgres init failure in staging or local config
    - Confirm next runtime boots with identical effective config hash via `/internal/diagnostics`
    - Re-run `zig build test --summary all`

- [ ] Make active-stream shutdown semantics explicit and safe
  - Target files: `deploy/k8s/zaki-bot/05-deployment.yaml`, `deploy/k8s/zaki-bot/07-ingress.yaml`, `src/gateway.zig`
  - Change: align stream timeout expectations with pod grace, or add explicit stream cutoff/retry semantics during drain
  - Verification:
    - Open a deliberately slow `/api/v1/chat/stream`
    - Trigger `/internal/drain` then terminate the pod
    - Confirm whether stream completes, is retried cleanly, or is cut

### P1 (should fix)

- [ ] Add exported latency and contention metrics
  - Target files: `src/session.zig`, `src/agent/root.zig`, `src/gateway.zig`, `src/observability.zig`
  - Change: export `session_lock_wait_ms`, `memory_enrich_ms`, `compact_pre_provider_ms`, `chat_ms`, active sessions, and queue depth
  - Verification:
    - Hit app and Telegram paths locally/staging
    - Confirm `/metrics` exposes the new series
    - Correlate route-level slow turns with stage-level metrics

- [ ] Reduce `zaki_dual` read-time sync amplification
  - Target files: `src/memory/engines/zaki_dual.zig`, `src/memory/engines/markdown.zig`, gateway tenant-runtime tests
  - Change: add sync checkpointing/watermark or one-time migration semantics instead of syncing all markdown entries on each read/list/get
  - Verification:
    - Seed markdown memory with many entries
    - Measure recall/list latency before/after
    - Re-run `zig build test --summary all`

- [ ] Harden latent async Telegram regression path
  - Target files: `src/gateway.zig`
  - Change: if async worker remains in tree, pass canonical session key in the job payload instead of recomputing `main`
  - Verification:
    - Unit test worker with a thread/task lane
    - Confirm session key is preserved

- [ ] Preserve lane kind in Postgres session metadata
  - Target files: `src/zaki_state.zig`
  - Change: store `main|thread|task|cron` rather than binary `main/system`
  - Verification:
    - Create sessions for each canonical lane
    - Inspect stored `kind`
    - Re-run relevant DB-backed tests

### P2 (nice to have)

- [ ] Remove dead deployment config or wire it through
  - Target files: `deploy/k8s/zaki-bot/02-configmap.yaml`, `deploy/k8s/zaki-bot/05-deployment.yaml`
  - Change: template `SESSION_CROSS_CHANNEL_SHARED_MAIN` into generated runtime JSON or delete the unused env
  - Verification:
    - Change env value in staging
    - Confirm generated `config.json` and runtime behavior match

- [ ] Expand route-specific Telegram/app diagnostics
  - Target files: `src/gateway.zig`
  - Change: add route-tagged counters for synchronous Telegram processing time, reply send failures, dedupe hits, and ownership-lock wait/conflict details
  - Verification:
    - Exercise webhook duplicates, lock conflicts, and normal chats
    - Confirm `/metrics` and `/internal/diagnostics` reflect each case

- [ ] Revisit PDB/HPA assumptions for rollout safety
  - Target files: `deploy/k8s/zaki-bot/08-pdb.yaml`, `deploy/k8s/zaki-bot/09-hpa.yaml`
  - Change: align disruption budget and scaling signals with stream-heavy workload rather than CPU/memory only
  - Verification:
    - Canary rollout under live SSE load
    - Confirm no elevated lock conflicts, dropped streams, or readiness churn

## E) Validation Plan

### Local checks

- Run `zig build test --summary all`
  - Expected gate: `0 failed`, `0 leaked`; current checkout passed with `4661 passed`, `25 skipped`, `MaxRSS 42M`
- Run `zig build -Doptimize=ReleaseSmall`
  - Expected gate: build succeeds; current checkout passed
- Add/confirm targeted tests for:
  - chat-stream missing/valid `session_key`
  - tenant Telegram shared-main vs isolated routing
  - config DB/file fallback parity
  - `zaki_dual` sync behavior under repeated recall/list/get

### Staging / k8s checks

- App/BFF path
  - POST `/api/v1/chat/stream` with explicit `session_key=agent:zaki-bot:user:<id>:main`
  - Repeat with `thread:<id>` and verify lane counters in `/metrics`
- Telegram path
  - Send two distinct DM/webhook messages for the same user
  - Verify whether they land on `main` or a thread lane based on the chosen policy
  - Confirm duplicate webhook returns duplicate status without duplicate reply
- Config drift
  - PATCH config/settings
  - Restart with Postgres intentionally unavailable
  - Compare `effective_config_hash` from `/internal/diagnostics`
- Shutdown safety
  - Start a long chat stream
  - Invoke `/internal/drain`, then roll the deployment
  - Record whether the stream completes inside grace or is cut

### Canary gates and rollback criteria

- Gate 1: no increase in `nullalis_gateway_chat_stream_session_key_rejections_total{reason="missing"}` after smoke and client updates land (`src/gateway.zig:3827-3832`)
- Gate 2: if Telegram isolation is enabled, lane counters must show non-zero thread traffic and no spike in `tenant_lock_conflicts_*` (`src/gateway.zig:3821-3832`, `src/gateway.zig:3858-3870`)
- Gate 3: `/internal/diagnostics` must show expected `effective_config_source` and stable `effective_config_hash` across restart/failover drills (`src/gateway.zig:4254-4359`)
- Gate 4: canary must show no rise in drain rejections, overload rejections, or readiness flaps during rollout (`src/gateway.zig:3871-3899`, `src/gateway.zig:7869-7890`)
- Roll back immediately if:
  - app chats begin failing on missing/invalid session key after client rollout
  - Telegram reply latency or conflict rate rises materially after lane-policy changes
  - canary rollout drops active streams during normal drain
  - effective config source/hash diverges across pods for the same user

