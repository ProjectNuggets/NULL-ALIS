---
tags: [prose, prose/docs]
---

# Release Validation Investigation Findings

Date: 2026-03-17  
Scope: issue-by-issue validation against the current checkout before release.  
Method: inspect live code paths, nearby tests, and runtime wiring before accepting or rejecting a claim.

## Executive Summary

- Investigated `16` release-review claims against the current checkout.
- Final verdict mix:
  - `1` true maintainability finding
  - `10` partially true findings that narrowed down to smaller real gaps
  - `5` claims rejected as not matching current code
- Two low-risk fixes were implemented from the validated list:
  - markdown hygiene metadata correctness in [`src/memory/engines/markdown.zig`](/Users/nova/Desktop/nullalis/src/memory/engines/markdown.zig) and [`src/memory/lifecycle/hygiene.zig`](/Users/nova/Desktop/nullalis/src/memory/lifecycle/hygiene.zig)
  - canonical models cache path + atomic writes in [`src/onboard.zig`](/Users/nova/Desktop/nullalis/src/onboard.zig)
- Validation after implementation:
  - `zig build test --summary all` passed
  - `zig build -Doptimize=ReleaseSmall` passed
  - No automated regressions were detected in the current repo validation envelope

## Implemented Now

### A) Markdown hygiene metadata fix

- Status: `Implemented and validated`
- Files:
  - [`src/memory/engines/markdown.zig`](/Users/nova/Desktop/nullalis/src/memory/engines/markdown.zig)
  - [`src/memory/lifecycle/hygiene.zig`](/Users/nova/Desktop/nullalis/src/memory/lifecycle/hygiene.zig)
- Outcome:
  - repeated `last_hygiene_at` writes now replace prior markdown entries instead of appending duplicates
  - markdown `get()` now prefers the newest exact-key match
  - hygiene due-check now observes the latest stored timestamp
- Risk / side effects:
  - low risk
  - intended behavioral change only for exact-key resolution and internal hygiene metadata handling

### B) Models cache unification + atomic writes

- Status: `Implemented and validated`
- File:
  - [`src/onboard.zig`](/Users/nova/Desktop/nullalis/src/onboard.zig)
- Outcome:
  - canonical cache path is now `~/.nullalis/state/models_cache.json`
  - refresh and read paths now target the same cache file
  - cache writes are now atomic
  - updating one provider cache preserves unrelated provider cache entries
- Risk / side effects:
  - low risk
  - no public API/config change
  - cache remains best-effort and disposable

## Open Later

- [`src/gateway.zig`](/Users/nova/Desktop/nullalis/src/gateway.zig): monolith extraction remains the largest maintainability issue, but it is not a release-week patch.
- Tenant state convergence: introduce a thin facade around canonical tenant state so gateway/daemon stop encoding storage authority in multiple places.
- Config hot reload: tenant runtimes already track effective config hash, but runtime invalidation/rebuild on change is not implemented.
- Cron raw-payload semantic dedupe: higher-level schedule flows dedupe exact recurring jobs, but raw JSON replace/load paths still allow semantic duplicates by different IDs.
- Docker portability hardening: optional Docker `HEALTHCHECK`, image-default host review, and non-K8s graceful termination improvements remain worthwhile but non-blocking.
- Config/tooling docs: a machine-readable config schema and a secret-source matrix would improve operator clarity, but startup semantic validation already exists.

## Verdict Legend

- `Not true`: the claim does not match the current code.
- `Partially true`: the core claim is overstated, but there is a narrower real risk or limitation.
- `True`: the claim matches the current code and needs action.

## Findings

### 1) Claimed critical SQL injection risk in Postgres identifier handling

- Verdict: `Not true`
- Claim summary: identifier validation uses alphanumeric filtering and then performs string substitution, so schema/table handling is said to be injectable.
- Current state:
  - Dynamic identifiers are allowlisted by [`validateIdentifier`](/Users/nova/Desktop/nullalis/src/memory/engines/postgres.zig#L28).
  - Validated identifiers are quoted by [`quoteIdentifier`](/Users/nova/Desktop/nullalis/src/memory/engines/postgres.zig#L40).
  - Placeholder substitution in [`buildQuery`](/Users/nova/Desktop/nullalis/src/memory/engines/postgres.zig#L46) is limited to pre-validated, pre-quoted identifiers.
  - Value data uses `PQexecParams`, not string interpolation, across the generic Postgres memory backend.
  - ZAKI state helpers also validate and quote dynamic identifiers before formatting SQL in [`zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig#L1902).
- Why the claim is not accepted:
  - The risky characters needed to break identifier context are rejected before interpolation.
  - Postgres identifiers cannot be parameter-bound, so validated+quoted interpolation is the correct pattern here.
  - I did not find a bypass path that injects unvalidated user-controlled schema/table/column names into SQL.
- Safest next action:
  - No release fix required.
  - Optional cleanup later: rename comments from “SQL injection protection” to “identifier allowlist for dynamic SQL identifiers” to make the design clearer for reviewers.

### 2) Claimed absence of connection pooling causing one Postgres connection per memory operation

- Verdict: `Not true`
- Claim summary: `PQconnectdb` in generic Postgres memory init is said to imply a fresh connection for every memory operation.
- Current state:
  - Generic Postgres memory opens a connection once during [`PostgresMemory.init`](/Users/nova/Desktop/nullalis/src/memory/engines/postgres.zig#L105) and stores it on the backend instance as `conn`.
  - Memory operations reuse that persistent connection through [`execParams`](/Users/nova/Desktop/nullalis/src/memory/engines/postgres.zig#L285).
  - Generic backend instances are created once per memory runtime in [`registry.zig`](/Users/nova/Desktop/nullalis/src/memory/engines/registry.zig#L349), not once per operation.
  - The tenant release path mostly uses `zaki_state.Manager`, which has a bounded reusable pool in [`zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig#L257), [`zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig#L425), and pool tests in [`zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig#L2710).
  - Tenant runtimes are cached per user in [`gateway.zig`](/Users/nova/Desktop/nullalis/src/gateway.zig#L1061), so the gateway is not rebuilding Postgres state on every request.
- Why the claim is not accepted:
  - The code does not open a new Postgres connection per store/get/list/recall call.
  - The release-critical tenant gateway path already uses pooled Postgres state.
- Real nuance that remains:
  - The generic `PostgresMemory` backend is single-connection-per-instance, not a shared pool across all instances.
  - That is a capacity/scaling characteristic worth documenting, but it is not the reported bug.
- Safest next action:
  - No release fix required for this claim.
  - Optional follow-up later: document the difference between generic single-connection `PostgresMemory` and pooled tenant `zaki_state.Manager`.

### 3) Claimed multiple state systems with no coherence across JSON files and Postgres

- Verdict: `Partially true`
- Claim summary: the repo is said to split state across `state.zig`, `zaki_state.zig`, `daemon.zig`, and `cron.zig` with no coherence or transaction boundaries.
- Current state:
  - Multiple persistence mechanisms do exist in the codebase: Postgres-backed tenant state, file-backed cron/state stores in non-tenant or file mode, and daemon status files.
  - The release-critical tenant Postgres path centralizes most product state in [`zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig#L770), including config, secrets, heartbeat, onboarding, channel state, jobs, identities, memory, and ownership leases.
  - In tenant Postgres mode, the scheduler uses Postgres job claim/finalize flow in [`daemon.zig`](/Users/nova/Desktop/nullalis/src/daemon.zig#L1435), not `cron.json`.
  - `cron.zig` file persistence remains the store for non-tenant or file-mode runtimes in [`cron.zig`](/Users/nova/Desktop/nullalis/src/cron.zig#L1848) and [`daemon.zig`](/Users/nova/Desktop/nullalis/src/daemon.zig#L1564).
  - `daemon_state.json` is an operational status/diagnostics artifact written by [`daemon.zig`](/Users/nova/Desktop/nullalis/src/daemon.zig#L109) and read by [`doctor.zig`](/Users/nova/Desktop/nullalis/src/doctor.zig#L418); it is not canonical user/product state.
  - `state.zig` exists as a file-backed last-channel helper in [`state.zig`](/Users/nova/Desktop/nullalis/src/state.zig#L25), but I did not find active runtime wiring to it in the current checkout outside its own tests/export surface.
- Why the full claim is not accepted:
  - The listed stores are not all active authoritative writers for the same domain at the same time in the current tenant Postgres release path.
  - Core tenant product state is mostly consolidated into Postgres rather than split live across JSON and DB.
  - `daemon_state.json` is diagnostic metadata, so cross-transaction atomicity with jobs/config/messages is not required.
  - `state.zig` appears effectively unused right now, so treating it as an active coherence boundary overstates the live risk.
- Real nuance that remains:
  - There is no single cross-store transaction layer spanning all ancillary file artifacts and Postgres-backed state.
  - Some mode-dependent file/DB variants still exist by design, and mirror/fallback behavior must stay well documented to avoid operator confusion.
  - The repo would benefit from a clear source-of-truth matrix by runtime mode so reviewers can quickly see which store is authoritative for each domain.
- Safest next action:
  - No release-blocking fix required based on this claim alone.
  - Good follow-up: document authoritative state by mode (`tenant+postgres`, `tenant+file`, non-tenant) and either remove or explicitly mark `state.zig` as legacy/unused if that remains intentional.

### 4) Claimed `state.zig` ignores `state.backend = "postgres"` so the configured Postgres state backend is not implemented

- Verdict: `Not true`
- Claim summary: because [`state.zig`](/Users/nova/Desktop/nullalis/src/state.zig) is file-backed, the report claims the configured Postgres state backend is wired in config but not implemented in code.
- Current state:
  - [`state.zig`](/Users/nova/Desktop/nullalis/src/state.zig) is a standalone file-backed helper for last-channel metadata; it is not the module that implements the configured tenant state backend.
  - The configured Postgres state backend is implemented in [`zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig) and is initialized from `cfg.state` in the gateway at [`gateway.zig`](/Users/nova/Desktop/nullalis/src/gateway.zig#L8410).
  - The daemon also initializes [`zaki_state.Manager`](/Users/nova/Desktop/nullalis/src/daemon.zig#L1047) when `tenant.enabled` and `state.backend == "postgres"`.
  - CLI/runtime paths use [`zaki_state.Manager.init`](/Users/nova/Desktop/nullalis/src/main.zig#L350) for Postgres-backed cron/state operations when the mode requires it.
  - I did not find active runtime wiring that makes `state.zig` the authoritative implementation of `cfg.state.backend`.
- Why the claim is not accepted:
  - The Postgres state backend is implemented and used; it just lives in `zaki_state.zig`, not `state.zig`.
  - Treating `state.zig` as the expected implementation target for `cfg.state.backend` conflates a legacy/general file helper with the tenant state system.
- Real nuance that remains:
  - The existence of `state.zig` can still confuse reviewers because its name overlaps conceptually with `cfg.state`.
  - If the product direction is “always zaki_state,” then the better long-term move is to retire or fence off `state.zig`, not to add another Postgres implementation path there.
- Safest next action:
  - No release fix required for this claim.
  - Good follow-up: continue converging authority onto `zaki_state` and keep `state.zig` clearly labeled as non-canonical/legacy support.

### 5) Claimed `gateway.zig` is a 520 KB monolith with weak separation between HTTP handling and business logic

- Verdict: `True`
- Claim summary: [`gateway.zig`](/Users/nova/Desktop/nullalis/src/gateway.zig) is said to be a monolith that mixes transport, auth, tenant behavior, channel handling, and business logic in one file.
- Current state:
  - File size is `520,588` bytes and `11,886` lines in the current checkout.
  - The file contains HTTP accept-loop handling, auth/token policy, readiness/drain behavior, tenant runtime lifecycle, chat streaming, webhook routing, and per-channel webhook handlers.
  - There are some internal seams already:
    - [`TenantRuntime`](/Users/nova/Desktop/nullalis/src/gateway.zig#L616)
    - [`handleApiChatStreamSseConnection`](/Users/nova/Desktop/nullalis/src/gateway.zig#L5225)
    - [`handleApiRoute`](/Users/nova/Desktop/nullalis/src/gateway.zig#L5537)
    - [`WebhookHandlerContext`](/Users/nova/Desktop/nullalis/src/gateway.zig#L6507)
    - channel-specific handlers such as [`handleTelegramWebhookRoute`](/Users/nova/Desktop/nullalis/src/gateway.zig#L6544)
    - top-level [`run`](/Users/nova/Desktop/nullalis/src/gateway.zig#L8311)
  - Even with those seams, transport concerns and business/state orchestration are still concentrated in one file.
- Why the claim is accepted:
  - The file is objectively monolithic by size and responsibility count.
  - HTTP parsing/routing and higher-level tenant/channel behavior are not cleanly separated into distinct modules.
  - This is a maintainability and change-safety issue, especially on a high-risk boundary.
- Real nuance that remains:
  - This is not proof of a functional bug by itself.
  - The file already has extraction candidates, which lowers refactor risk compared with a completely flat implementation.
- Safest next action:
  - No release-week behavior refactor unless a concrete bug forces it.
  - Best follow-up: extract by boundary, starting with pure routing/handler surfaces and keeping behavior identical.

### 6) Claimed session queue is in-memory only so daemon restarts lose queued work

- Verdict: `Partially true`
- Claim summary: [`session.zig`](/Users/nova/Desktop/nullalis/src/session.zig) is said to have non-persistent queues, so a daemon restart loses queued work.
- Current state:
  - The queue-related fields in [`Session`](/Users/nova/Desktop/nullalis/src/session.zig#L46) are in-memory only: `queue_mutex`, `queue_waiting`, `queue_sequence`, and related drop/summarize counters.
  - Queue behavior is implemented inside [`processMessageWithContext`](/Users/nova/Desktop/nullalis/src/session.zig#L375) as a waiter/serialization policy around `session.mutex`.
  - Waiting requests are not persisted anywhere before they acquire the session lock.
  - Persisted state exists for conversation history/messages via `session_store`, but not for queued waiters.
- Why the claim is only partially accepted:
  - It is true that queued waiters would be lost on process restart.
  - But this is not a durable background job queue; it is a synchronous in-process contention mechanism for live requests.
  - Losing these waiters on restart is functionally similar to losing in-flight HTTP requests/connections, not evidence that a promised durable queue is missing.
- Real nuance that remains:
  - There is no resumable/replayable queue for blocked same-session requests.
  - If the product ever needs “accept now, complete later” durability for user turns, this mechanism is insufficient by design.
  - Current mitigations rely on caller retry behavior rather than persistence.
- Safest next action:
  - No release fix required if synchronous request/retry semantics are acceptable.
  - If stronger durability is desired later, it should be implemented as an explicit persisted work queue at the gateway/job layer, not by persisting `session.zig` waiter bookkeeping.

### 7) Claimed cron jobs are file-based because `cron.zig` persists `cron.json`

- Verdict: `Partially true`
- Claim summary: because [`cron.zig`](/Users/nova/Desktop/nullalis/src/cron.zig) reads/writes `cron.json`, the report claims cron jobs are file-based.
- Current state:
  - [`cron.zig`](/Users/nova/Desktop/nullalis/src/cron.zig#L1802) does implement file-backed persistence via `cron.json` for generic/file-mode scheduler operation.
  - Non-tenant or file-mode scheduler paths in [`daemon.zig`](/Users/nova/Desktop/nullalis/src/daemon.zig#L1578) use `cron.loadJobs`, `cron.reloadJobs`, and file persistence.
  - But tenant Postgres mode uses Postgres-backed job storage and claiming:
    - gateway cron API uses [`getJobsJson`](/Users/nova/Desktop/nullalis/src/gateway.zig#L6044) and [`replaceJobsJson`](/Users/nova/Desktop/nullalis/src/gateway.zig#L6058) on `zaki_state`
    - scheduler execution uses [`runTenantSchedulerTickPostgres`](/Users/nova/Desktop/nullalis/src/daemon.zig#L1436)
    - CLI auto-selects Postgres cron backend in tenant Postgres mode via [`resolveCronBackendMode`](/Users/nova/Desktop/nullalis/src/main.zig#L310)
    - job persistence is implemented in [`zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig#L995)
- Why the claim is only partially accepted:
  - It is true that `cron.zig` supports file-backed cron storage.
  - It is false that cron jobs are universally file-based in the current release path.
  - In tenant Postgres mode, canonical cron storage is already in Postgres.
- Real nuance that remains:
  - The codebase still supports two cron persistence styles depending on runtime mode.
  - That duality is a maintainability concern and aligns with the broader “converge on zaki_state” direction.
- Safest next action:
  - No release fix required for this claim.
  - Good follow-up: if product direction is “always zaki_state,” narrow file-backed cron persistence to explicit non-tenant/file-mode usage and keep Postgres as the sole tenant authority.

### 8) Claimed memory has 10+ backends, no default, complex failover logic, and a probably failing pgvector path

- Verdict: `Partially true`
- Claim summary: the memory subsystem is said to expose many backends, lack a default, rely on complex failover logic, and have a pgvector path that is “probably failing.”
- Current state:
  - The memory subsystem is broad and does support many backends/components:
    - primary backends in [`registry.zig`](/Users/nova/Desktop/nullalis/src/memory/engines/registry.zig#L188): `none`, `markdown`, `memory`, `api`, `sqlite`, `lucid`, `redis`, `lancedb`, `postgres`
    - vector-plane stores and helpers in [`memory/root.zig`](/Users/nova/Desktop/nullalis/src/memory/root.zig#L51), including Qdrant and pgvector
  - There is a default memory backend:
    - [`MemoryConfig.DEFAULT_MEMORY_BACKEND`](/Users/nova/Desktop/nullalis/src/config_types.zig#L528) is `"markdown"`
    - [`MemoryConfig.backend`](/Users/nova/Desktop/nullalis/src/config_types.zig#L532) defaults to that value
    - profiles can override the default intentionally in [`applyProfileDefaults`](/Users/nova/Desktop/nullalis/src/config_types.zig#L548)
  - The runtime does not randomly pick a backend; it resolves the configured `config.memory.backend` through the registry in [`initRuntimeWithOptions`](/Users/nova/Desktop/nullalis/src/memory/root.zig#L765).
  - There is complexity in the semantic/vector plane:
    - optional embedding fallback provider routing
    - optional rollout mode
    - optional circuit breaker
    - optional outbox/durable sync
  - But that logic is not “primary memory backend failover”; it is mostly vector/embedding-plane resilience layered on top of the primary backend.
  - The pgvector path exists and has health-check/pool/error handling in [`store_pgvector.zig`](/Users/nova/Desktop/nullalis/src/memory/vector/store_pgvector.zig#L628) and pool tests, but code alone does not prove it is currently failing.
- Why the claim is only partially accepted:
  - It is true that the memory subsystem is feature-rich and operationally complex.
  - It is false that there is “no default”; the default is `markdown`.
  - It is misleading to say the runtime “picks one” arbitrarily; it uses explicit config/profile resolution.
  - It is not justified from code alone to conclude the pgvector path is “probably failing.”
- Real nuance that remains:
  - The number of options raises maintenance and observability burden.
  - The vector plane is especially nuanced because it mixes provider fallback, rollout, circuit breaking, and sync mode.
  - Better diagnostics would make it easier to tell whether pgvector is healthy in a live environment without inference.
- Safest next action:
  - No release fix required for this claim as written.
  - Good follow-up: tighten diagnostics/reporting for vector-plane health and consider reducing exposed option surface in the product-facing tenant path even if the general framework keeps broader backend support.

### 9) Claimed `deploy/k8s/zaki-bot` is for a different app and nullalis daemon has no Kubernetes manifests

- Verdict: `Partially true`
- Claim summary: the report says the manifests under `deploy/k8s/zaki-bot` are for a different app (`zaki-bot`) rather than nullalis core, and that the nullalis daemon has no K8s manifests.
- Current state:
  - [`deploy/k8s/zaki-bot/README.md`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/README.md#L1) explicitly describes this folder as the deployment pack for running `nullALIS` as the dedicated `ZAKI BOT` backend.
  - The main deployment runs the repo’s binary/image:
    - image: [`ghcr.io/nullclaw/nullclaw:REPLACE_TAG`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/05-deployment.yaml#L35)
    - command: [`exec nullalis gateway --host "${GATEWAY_HOST}" --port "${GATEWAY_PORT}"`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/05-deployment.yaml#L132)
  - So this is not a different application codebase; it is this repo deployed in a specific ZAKI BOT gateway profile.
  - It is true that the manifests are product/profile-specific rather than a generic “deploy any nullalis mode” pack.
  - I did not find a separate Kubernetes deployment pack specifically for `nullalis daemon` mode in the repo.
- Why the claim is only partially accepted:
  - It is false that `deploy/k8s/zaki-bot` is for a different app in the sense of a separate codebase; it deploys `nullalis`.
  - It is fair to say the manifests target a specific operational profile (`ZAKI BOT gateway`) rather than the full generic nullalis runtime surface.
  - It is likely true in practice that there is no first-class K8s manifest pack for daemon mode today.
- Real nuance that remains:
  - The folder name and resource naming (`nullclaw`, `zaki-bot`) can confuse reviewers into thinking this is external to core runtime behavior.
  - If daemon mode is a supported deployment target, the repo may benefit from a dedicated deployment pack or clearer documentation that the current manifests are gateway-profile specific.
- Safest next action:
  - No release code fix required for this claim.
  - Good follow-up: document that `deploy/k8s/zaki-bot` is the nullalis gateway deployment pack for the ZAKI BOT product profile, and decide whether daemon mode needs its own deployment story.

### 10) Claimed Dockerfile has signal/health/binding/shutdown/worker issues

- Verdict: `Partially true`
- Claim summary: the Dockerfile is said to have no init system, no health check, a hard-coded `::` bind, no graceful SIGTERM handling, and only a single gateway thread with no workers.
- Current state:
  - The Dockerfile does use exec-form entrypoint/cmd in [`Dockerfile`](/Users/nova/Desktop/nullalis/Dockerfile#L55), so `nullalis` runs as PID 1 directly.
  - The Dockerfile does not define a Docker `HEALTHCHECK`.
  - The image default command does bind the gateway to `::` in [`Dockerfile`](/Users/nova/Desktop/nullalis/Dockerfile#L56).
  - The Kubernetes deployment pack overrides host to `0.0.0.0` via [`02-configmap.yaml`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/02-configmap.yaml#L10), so the Dockerfile default does not govern that deployment.
  - The Kubernetes deployment also provides readiness/liveness/startup probes in [`05-deployment.yaml`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/05-deployment.yaml#L136).
  - Gateway runtime does use a worker pool controlled by `cfg.gateway.max_workers` in [`gateway.zig`](/Users/nova/Desktop/nullalis/src/gateway.zig#L8539), so “one gateway thread, no workers” is incorrect.
  - I did not find a general SIGTERM handler in the gateway/daemon entry path; graceful shutdown in the K8s pack is driven by explicit preStop calls to `/internal/drain` and `/internal/shutdown` in [`05-deployment.yaml`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/05-deployment.yaml#L165).
- Why the claim is only partially accepted:
  - `No init system — signals won't propagate properly`: not accepted as stated. Exec-form entrypoint means signals are delivered to the main process directly.
  - `No health check — K8s can't determine if it's alive`: false for the provided K8s deployment, though true for plain Docker metadata because there is no Docker `HEALTHCHECK`.
  - `Hard-coded :: binding`: true for the image default, but the shipped K8s deployment overrides it.
  - `No graceful shutdown — SIGTERM handling missing`: partially true in the binary/runtime path, but mitigated in the K8s deployment by explicit preStop drain/shutdown hooks.
  - `Single process — one gateway thread, no workers`: false. It is a single process with multiple worker threads.
- Real nuance that remains:
  - Plain `docker run` without orchestrator hooks is less graceful than the K8s deployment profile.
  - A container-level `HEALTHCHECK` and optional explicit SIGTERM handling would improve portability outside the curated K8s pack.
- Safest next action:
  - No release-blocking fix required for the K8s deployment profile.
  - Good follow-up: add a Docker `HEALTHCHECK`, consider changing the image default host to `0.0.0.0`, and decide whether to add explicit SIGTERM-driven drain/shutdown behavior for non-K8s/container-only use.

### 11) Claimed `defaultStatePath` should inspect `config.state.backend` and route to PostgreSQL when configured

- Verdict: `Not true`
- Claim summary: because [`defaultStatePath`](/Users/nova/Desktop/nullalis/src/state.zig#L175) always returns a `state.json` path, the report claims it should instead route to Postgres when `config.state.backend = "postgres"`.
- Current state:
  - [`defaultStatePath`](/Users/nova/Desktop/nullalis/src/state.zig#L175) is a file-path helper for the standalone file-backed `StateManager`.
  - It is not part of the configured tenant state backend routing path.
  - The configured Postgres state backend is handled by [`zaki_state.zig`](/Users/nova/Desktop/nullalis/src/zaki_state.zig), which is initialized from `cfg.state` in the gateway and daemon:
    - [`gateway.zig`](/Users/nova/Desktop/nullalis/src/gateway.zig#L8410)
    - [`daemon.zig`](/Users/nova/Desktop/nullalis/src/daemon.zig#L1047)
  - I did not find any active runtime path where `defaultStatePath` is consulted to choose between file state and Postgres state.
- Why the claim is not accepted:
  - This function is not the backend selector; it only builds a file path for the file-backed helper.
  - Teaching `defaultStatePath` to “route to PostgreSQL” would mix two unrelated concerns and duplicate the actual state-backend routing already implemented elsewhere.
- Real nuance that remains:
  - The naming collision between generic `state.zig` and configured `cfg.state` remains confusing for reviewers.
  - If the desired product direction is “always zaki_state,” the right fix is to narrow or retire `state.zig`, not to make its path helper backend-aware.
- Safest next action:
  - No release fix required for this claim.
  - Keep converging backend selection onto `zaki_state` and avoid adding parallel routing logic to `state.zig`.

### 12) Claimed `MEMORY.md` hygiene bug causes duplicate `last_hygiene_at` growth

- Verdict: `Partially true`
- Claim summary: the referenced files are wrong for this repo (`src/memory/hygiene.py`, `src/agent/session.py` do not exist), but the underlying claim is that hygiene metadata is appended repeatedly into `MEMORY.md`, causing duplicate timestamp lines and file growth.
- Current state:
  - The real hygiene implementation is in [`src/memory/lifecycle/hygiene.zig`](/Users/nova/Desktop/nullalis/src/memory/lifecycle/hygiene.zig#L41).
  - Hygiene completion writes `last_hygiene_at` via `m.store(LAST_HYGIENE_KEY, ts, .core, null)` in [`hygiene.zig`](/Users/nova/Desktop/nullalis/src/memory/lifecycle/hygiene.zig#L67).
  - The markdown backend stores core entries by append-only writes to `MEMORY.md` in [`markdown.zig`](/Users/nova/Desktop/nullalis/src/memory/engines/markdown.zig#L263) and [`markdown.zig`](/Users/nova/Desktop/nullalis/src/memory/engines/markdown.zig#L65).
  - The markdown backend `get()` returns the first matching entry encountered while reading the file in [`markdown.zig`](/Users/nova/Desktop/nullalis/src/memory/engines/markdown.zig#L336).
  - Because append-only writes place newer `last_hygiene_at` lines later in the file, `shouldRunNow()` in [`hygiene.zig`](/Users/nova/Desktop/nullalis/src/memory/lifecycle/hygiene.zig#L79) can keep reading the oldest timestamp after multiple hygiene passes.
- Why the claim is only partially accepted:
  - The specific file references and implementation language are wrong.
  - But the core bug is real for append-only markdown-backed memory:
    - after more than one hygiene write, duplicate `last_hygiene_at` lines can accumulate
    - `shouldRunNow()` can observe the stale earliest timestamp instead of the latest one
    - this can cause hygiene to run more often than intended and grow `MEMORY.md`
- Real nuance that remains:
  - This bug is specific to markdown-backed/core-file behavior, including paths that use markdown as a workspace mirror (for example `zaki_dual`).
  - Internal-entry filtering prevents `last_hygiene_at` from syncing into canonical memory in [`zaki_dual.zig`](/Users/nova/Desktop/nullalis/src/memory/engines/zaki_dual.zig#L35), but it does not prevent `MEMORY.md` duplication.
  - I did not find an existing dedupe cleanup, replace-in-place update, or file-size guard for this metadata path.
- Safest next action:
  - This is a real bug worth fixing.
  - Best minimal fix:
    - make hygiene metadata updates replace existing `last_hygiene_at` lines in markdown-backed `MEMORY.md` instead of appending
    - make markdown `get()` prefer the newest matching key rather than the first
    - add a regression test covering repeated hygiene runs on markdown memory
  - Nice follow-up:
    - add lightweight dedupe cleanup for internal hygiene keys on load/init
    - consider a size guard for pathological `MEMORY.md` growth, but that is secondary to fixing stale-key lookup

### 13) Claimed cron-job accumulation bug with duplicate runtime merge jobs, no cleanup, and no job cap/TTL

- Verdict: `Partially true`
- Claim summary: the referenced Python files do not exist in this repo (`src/scheduler/cron.py`, `src/jobs/manager.py`), but the underlying concern is that cron persistence may accumulate duplicate jobs over time, especially around runtime merge behavior.
- Current state:
  - The core scheduler implementation is in [`src/cron.zig`](/Users/nova/Desktop/nullalis/src/cron.zig#L426) and daemon merge/reload logic is in [`src/daemon.zig`](/Users/nova/Desktop/nullalis/src/daemon.zig#L1335).
  - There is already a hard cap on in-memory job count via `max_tasks` in [`CronScheduler.addJob`](/Users/nova/Desktop/nullalis/src/cron.zig#L550) and [`CronScheduler.addOnce`](/Users/nova/Desktop/nullalis/src/cron.zig#L572); the config default is `64` in [`config_types.zig`](/Users/nova/Desktop/nullalis/src/config_types.zig#L134).
  - The schedule tool already deduplicates exact recurring jobs by `(expression, command)` before creating them in [`schedule.zig`](/Users/nova/Desktop/nullalis/src/tools/schedule.zig#L406) and special-cases canonical morning-brief jobs in [`schedule.zig`](/Users/nova/Desktop/nullalis/src/tools/schedule.zig#L380).
  - The file-mode scheduler merge path does not blindly append runtime copies on every tick; it snapshots current runtime jobs and upserts changed jobs by `job.id` in [`mergeSchedulerTickChangesAndSave`](/Users/nova/Desktop/nullalis/src/daemon.zig#L1335) and [`upsertSchedulerRuntimeJob`](/Users/nova/Desktop/nullalis/src/daemon.zig#L1312).
  - There is an explicit regression test proving externally added jobs are preserved during merge, not duplicated by repeated runtime saves, in [`daemon.zig`](/Users/nova/Desktop/nullalis/src/daemon.zig#L3158).
  - Postgres-backed tenant cron storage replaces the user's job set wholesale through [`replaceJobsJson`](/Users/nova/Desktop/nullalis/src/zaki_state.zig#L995), so it does not accumulate extra runtime rows across scheduler ticks by itself.
  - I did not find any generic TTL/age-based pruning for old cron jobs, nor a startup cleanup pass that removes semantically duplicate jobs from raw `cron.json` / raw jobs JSON payloads.
- Why the claim is only partially accepted:
  - The specific implementation references are wrong.
  - There is no evidence of a scheduler self-replication bug where every startup or tick creates another `merge_runtime` job.
  - The requested `max job limit` is already present in current code, though the default is `64` rather than `100`.
  - The real narrower gap is that semantic deduplication is uneven:
    - higher-level schedule flows dedupe exact recurring `(expression, command)` duplicates
    - lower-level raw JSON/file/Postgres replacement paths do not enforce semantic uniqueness
    - no TTL exists for stale dormant jobs
- Real nuance that remains:
  - Users or integrations that write raw cron payloads can still persist duplicate jobs if they give them different IDs.
  - `cron.json` size is indirectly bounded by `max_tasks`, but not by an explicit file-size guard, and command/payload length can still vary widely.
  - Startup time is not protected by a dedicated duplicate-cleanup pass, though the scheduler currently just parses the persisted JSON and does not synthesize extra jobs during load.
- Safest next action:
  - No P0 release fix is required for the claim as stated.
  - Good later hardening if desired:
    - add optional semantic dedupe when loading or saving raw cron payloads, using `(expression, command, one_shot)` or an equivalent canonical key
    - keep the existing `max_tasks` cap as the primary bound, rather than adding a second overlapping limit unless product policy needs `100` specifically
    - consider TTL pruning only for one-shot/completed or clearly ephemeral runtime-generated jobs; do not add blanket expiry to recurring user jobs without product sign-off

### 14) Claimed config hardening gaps: response cache off, rollout percent not deterministic, no schema validation, secrets in file, no hot reload

- Verdict: `Partially true`
- Claim summary: the referenced files are wrong for this repo (`config_loader.py` does not exist), but the underlying concerns are about runtime defaults, startup validation, secret handling, and config reload behavior.
- Current state:
  - Config is type-driven Zig, centered in [`src/config.zig`](/Users/nova/Desktop/nullalis/src/config.zig), [`src/config_types.zig`](/Users/nova/Desktop/nullalis/src/config_types.zig), and [`src/config_parse.zig`](/Users/nova/Desktop/nullalis/src/config_parse.zig).
  - Startup validation already exists:
    - [`Config.validate`](/Users/nova/Desktop/nullalis/src/config.zig#L751) enforces semantic checks such as default-model presence/format, temperature range, gateway port, and retry bounds
    - gateway/daemon startup calls validation in [`main.zig`](/Users/nova/Desktop/nullalis/src/main.zig#L210) and channel startup does the same in [`main.zig`](/Users/nova/Desktop/nullalis/src/main.zig#L2020)
  - `parallel_tools_rollout_percent` is already deterministic by default:
    - default value is `100` in [`config_types.zig`](/Users/nova/Desktop/nullalis/src/config_types.zig#L131)
    - parser clamps to `0..100` in [`config_parse.zig`](/Users/nova/Desktop/nullalis/src/config_parse.zig#L741)
  - Response cache exists but is default-off:
    - config default is `enabled: false` in [`config_types.zig`](/Users/nova/Desktop/nullalis/src/config_types.zig#L706)
    - runtime wiring is implemented in [`memory/root.zig`](/Users/nova/Desktop/nullalis/src/memory/root.zig#L842) and [`memory/root.zig`](/Users/nova/Desktop/nullalis/src/memory/root.zig#L1137)
  - Secret handling is already split across multiple supported sources:
    - provider/tool API keys can resolve from env vars in [`providers/api_key.zig`](/Users/nova/Desktop/nullalis/src/providers/api_key.zig#L4) and tools like [`web_search.zig`](/Users/nova/Desktop/nullalis/src/tools/web_search.zig#L65)
    - tenant/channel secrets can live in encrypted state via [`zaki_state.getSecret`](/Users/nova/Desktop/nullalis/src/zaki_state.zig#L926) and [`zaki_state.putSecret`](/Users/nova/Desktop/nullalis/src/zaki_state.zig#L950)
    - delivery fallback still supports file-based per-user secrets like [`secrets/telegram_bot_token`](/Users/nova/Desktop/nullalis/src/delivery/adapters/telegram_adapter.zig#L113)
  - I did not find a general config hot-reload loop:
    - config is loaded at startup and tenant runtimes cache an `effective_config_hash`, but [`getTenantRuntime`](/Users/nova/Desktop/nullalis/src/gateway.zig#L1084) does not invalidate/rebuild runtimes when backing config changes
- Why the claim is only partially accepted:
  - `Set parallel_tools_rollout_percent to 100`: already true by default, so this is not a current gap.
  - `Add validation schema for config.json`: startup validation already exists, though it is Zig semantic validation rather than an external JSON Schema artifact.
  - `Move secrets to env vars`: overstated. Env-var support already exists for many provider/tool credentials, while tenant secrets are intentionally persisted in encrypted state for product operation.
  - `Enable response_cache`: this is a tuning decision, not an unambiguous correctness fix; cache is implemented but intentionally default-off.
  - `Add config hot-reload`: this is the clearest real missing feature in the list.
- Real nuance that remains:
  - The current config validator is semantic/in-process, not a separately published machine-readable schema for external tooling.
  - Secret sourcing is inconsistent by domain: some credentials resolve from env, some from encrypted DB/file-backed secret stores, and some can still be placed directly in config.
  - Enabling response cache globally could help latency/cost, but it changes runtime behavior and should be validated against memory footprint, correctness expectations, and actual hit rates.
  - Hot reload is not present as a generic capability; cached tenant runtimes can continue using prior effective config until restart or cache eviction.
- Safest next action:
  - No P1 release patch is required for the claim as written.
  - Best low-risk hardening later:
    - document the supported secret-source matrix (`config`, env vars, encrypted tenant state, file fallback)
    - if external tooling needs it, generate or document a machine-readable config schema from the typed config surface
    - treat response-cache enablement as an explicit rollout experiment, not a blind default flip
    - if hot reload becomes important, add targeted runtime invalidation keyed off config hash changes rather than ad hoc partial reloads

### 15) Claimed state-management optimization is required for `models_cache.json` (compression, async writes, backups, migrations)

- Verdict: `Partially true`
- Claim summary: the report treats `state/models_cache.json` like a critical state file and proposes compression, versioning, async writes, and frequent backups.
- Current state:
  - The real implementation is in [`src/onboard.zig`](/Users/nova/Desktop/nullalis/src/onboard.zig#L310), not a dedicated state subsystem.
  - `fetchModels` uses a small file-based cache under `~/.nullalis/state/models_cache.json` with a 12-hour TTL in [`onboard.zig`](/Users/nova/Desktop/nullalis/src/onboard.zig#L310) and [`onboard.zig`](/Users/nova/Desktop/nullalis/src/onboard.zig#L425).
  - Cache read failures are already non-fatal: [`loadModelsWithCache`](/Users/nova/Desktop/nullalis/src/onboard.zig#L417) falls back to hardcoded provider model lists on any cache error.
  - The cache file is small and bounded in practice:
    - per-provider results are limited to `MAX_MODELS = 20` in [`onboard.zig`](/Users/nova/Desktop/nullalis/src/onboard.zig#L287)
    - cache reads are capped at `256 KiB` in [`readCachedModels`](/Users/nova/Desktop/nullalis/src/onboard.zig#L444)
  - There is no compression, async write, backup rotation, or explicit schema version on this cache file.
  - The write path is simplistic:
    - [`saveCachedModels`](/Users/nova/Desktop/nullalis/src/onboard.zig#L483) overwrites the file directly rather than using temp-file + rename
    - despite the comment saying it “merge[s] into existing cache,” the implementation writes only `fetched_at` plus the current provider payload
  - There is also a path inconsistency:
    - interactive/onboarding fetch cache uses `~/.nullalis/state/models_cache.json`
    - [`runModelsRefresh`](/Users/nova/Desktop/nullalis/src/onboard.zig#L1425) writes `~/.nullalis/models_cache.json`
- Why the claim is only partially accepted:
  - It is false to treat this file as canonical runtime state that needs backup/S3-grade durability.
  - Compression, async writes, and frequent backups are not justified for a tiny, disposable model-list cache.
  - Recovery from corruption is already effectively immediate because the caller falls back to hardcoded lists rather than blocking startup.
  - The narrower real issue is cache robustness/consistency, not heavy state-management features.
- Real nuance that remains:
  - The direct-write cache save path is more fragile than the repo’s other temp-file + rename state writes.
  - The split cache locations (`~/.nullalis/state/models_cache.json` vs `~/.nullalis/models_cache.json`) can cause refresh/read divergence.
  - A lightweight version field could still be useful if the cache format grows later, but it is not urgent for the current shape.
- Safest next action:
  - No P1 release fix is required for the claim as written.
  - Best small safe follow-up later:
    - unify the cache path to a single location
    - make cache writes atomic with temp-file + rename
    - optionally add a tiny `version` field if you expect the cache schema to evolve

### 16) Claimed Kubernetes deployment hardening is missing (resources, probes, graceful shutdown, PDB, HPA)

- Verdict: `Not true`
- Claim summary: the report says the Kubernetes deployment needs resource limits, liveness/readiness/startup probes, graceful shutdown, PDB, and HPA as if they are absent.
- Current state:
  - The shipped deployment pack already includes all of the requested Kubernetes primitives under [`deploy/k8s/zaki-bot`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot).
  - Resource requests/limits are present in [`05-deployment.yaml`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/05-deployment.yaml#L168):
    - main container requests: `750m` CPU / `1Gi` memory
    - main container limits: `2` CPU / `2Gi` memory
  - Probes are already configured in [`05-deployment.yaml`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/05-deployment.yaml#L136):
    - readiness probe: `GET /ready`
    - liveness probe: `GET /health`
    - startup probe: `GET /health`
  - Graceful shutdown handling is already wired at the pod level:
    - `terminationGracePeriodSeconds: 90` in [`05-deployment.yaml`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/05-deployment.yaml#L31)
    - `preStop` hook calling `/internal/drain` then `/internal/shutdown` in [`05-deployment.yaml`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/05-deployment.yaml#L159)
  - Pod disruption budget already exists with `minAvailable: 1` in [`08-pdb.yaml`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/08-pdb.yaml#L1).
  - Horizontal pod autoscaling already exists in [`09-hpa.yaml`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/09-hpa.yaml#L1):
    - `minReplicas: 3`
    - `maxReplicas: 12`
    - CPU target `70%`
    - memory target `80%`
  - The pack is already one-command applyable through Kustomize in [`kustomization.yaml`](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/kustomization.yaml#L1) (`kubectl apply -k deploy/k8s/zaki-bot`).
- Why the claim is not accepted:
  - Every requested hardening category is already present in the current manifest set.
  - The request mostly describes tuning changes, not missing features.
- Real nuance that remains:
  - The exact requested values differ from current tuning:
    - readiness period is `5s`, not `10s`
    - liveness period is `10s`, not `30s`
    - startup probe allows `24 * 5s = 120s`, not `5 minutes`
    - HPA scales `3..12`, not `1..3`
  - Graceful termination is currently driven by Kubernetes lifecycle hooks rather than a dedicated PID 1 SIGTERM handler inside the image/runtime path.
  - I did not validate real-world downtime or autoscaling reaction time from live cluster telemetry here; this conclusion is based on manifest/code inspection.
- Safest next action:
  - No P0 release fix is required for this claim.
  - If desired later, review probe/HPA tuning based on staging telemetry rather than replacing already-present hardening primitives.

## Next Entries

Append each new investigated issue with:

1. Claim summary
2. Verdict
3. Current state in code
4. Evidence links
5. Safest next action
