---
tags: [prose, prose/docs]
---

# nullALIS 360 Audit, Redone From Code Evidence

Date: 2026-03-18

Validation run:
- `zig build test --summary all` passed: `4686 passed`, `25 skipped`, `0 failed`, `MaxRSS 44M`.
- `zig build -Doptimize=ReleaseSmall` passed.
- `zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite,postgres` passed.
- `zig build test --summary all -Dengines=base,sqlite,postgres` failed to compile with 11 source errors in Postgres-gated test code.

Legend:
- Confirmed fact: directly verified in source, manifests, or command results in this checkout.
- High-confidence inference: strong consequence of the verified code.
- Unknown: requires runtime/staging validation; not claimed as fact here.

## Verdict

- Confirmed fact: this is not a “swiss watch” yet. The default profile builds and tests cleanly, but the Postgres-enabled test profile does not compile, several config surfaces are decorative rather than wired, and some docs/contracts overstate what the code actually does. (`build.zig:437-452`, `src/channel_identity_backfill.zig:211-277`, `src/inbound_canonicalizer.zig:516-790`, `src/gateway.zig:11403-11410`)
- Confirmed fact: the runtime core is still substantial and real: gateway routing, chat stream handling, tenant per-user path resolution, channel supervision, and release builds all work in this checkout. (`src/daemon.zig:2097-2317`, `src/gateway.zig:5236-5435`, `src/gateway.zig:5537-5775`, `src/gateway.zig:7904-8150`, `src/gateway.zig:1466-1495`)

## What Is Working

- Confirmed fact: default builds compile all channels but only the default memory engines (`base,sqlite`) unless Postgres is requested explicitly. (`build.zig:66-69`, `build.zig:196-202`, `build.zig:267-300`)
- Confirmed fact: the Docker image intentionally builds the Postgres-capable profile with `-Dengines=base,sqlite,postgres`. (`Dockerfile:6-13`)
- Confirmed fact: tenant request handling resolves a per-user root and derived paths for `workspace`, `memory.db`, `cron.json`, `config.json`, `heartbeat.json`, `channel_state.json`, `telegram.json`, and `secrets/`. (`src/gateway.zig:1466-1495`)
- Confirmed fact: `/api/v1/chat/stream` enforces internal auth through `validateInternalServiceToken(...)`, requires `X-Zaki-User-Id` in tenant mode, and enforces explicit session-key validation by default. (`src/gateway.zig:5238-5242`, `src/gateway.zig:5256-5264`, `src/gateway.zig:5314-5338`, `src/config_types.zig:782-783`)
- Confirmed fact: the daemon runtime scaffolds workspace state, starts gateway, delivery outcome, optional heartbeat/scheduler threads, channel supervisor threads, and inbound/outbound dispatchers. (`src/daemon.zig:2104-2317`)
- Confirmed fact: channel activation is explicit by listener mode and configuration count, not accidental. (`src/channel_catalog.zig:33-54`, `src/channel_catalog.zig:106-120`, `src/channel_manager.zig:271-342`)

## Findings

### 1. The Postgres-enabled test profile is broken

- Confirmed fact: `zig build test --summary all -Dengines=base,sqlite,postgres` fails at compile time, even though the default test profile passes.
- Confirmed fact: several tests switch on `error.PostgresNotEnabled` after calling `zaki_state.Manager.init(...)`; that error only exists in the stub manager build, so the switch becomes invalid in the Postgres-enabled build. (`src/channel_identity_backfill.zig:211-277`, `src/inbound_canonicalizer.zig:516-790`, `src/zaki_state.zig:69-207`)
- Confirmed fact: a gateway test uses `gs.zaki_state = @ptrFromInt(1)`, which becomes an invalid aligned pointer assignment once `zaki_state` is the real `ManagerImpl` pointer type in the Postgres-enabled build. (`src/gateway.zig:11403-11410`)
- High-confidence inference: the repo’s default CI-style path is not exercising the most important tenant-state profile thoroughly enough, because `build.zig` only runs the compiled test graph for the currently selected engine set. (`build.zig:437-452`, `build.zig:196-202`)
- Effect: the most important deployment profile can compile as a release binary but still have broken test code and reduced confidence for changes in Postgres-gated paths.

### 2. Several config surfaces are decorative, not operational

- Confirmed fact: `runtime.kind` is parsed from config and displayed in status output. (`src/config_parse.zig:599-610`, `src/status.zig:51-52`)
- High-confidence inference: I did not find any non-test runtime code path that selects behavior from `runtime.kind`; the runtime adapter types exist in `src/runtime.zig`, but the main binary does not branch on them in this checkout. (`src/runtime.zig:3-40`, `src/runtime.zig:43-409`, `src/config_parse.zig:599-610`, `src/status.zig:51-52`)
- Confirmed fact: `tunnel.provider` is parsed from config and set during onboarding, but the only concrete tunnel factory is `createTunnel(...)` inside `src/tunnel.zig`. (`src/config_parse.zig:1740-1745`, `src/onboard.zig:1422`, `src/onboard.zig:1514`, `src/tunnel.zig:873-1004`)
- High-confidence inference: I did not find non-test runtime wiring that actually starts or manages tunnels from `cfg.tunnel.provider`; the feature is present in source but not integrated into the gateway/daemon/main execution path in this checkout. (`src/onboard.zig:1422`, `src/onboard.zig:1514`, `src/tunnel.zig:873-1004`)
- Effect: runtime and tunnel config knobs look productized in config/status/onboarding, but they are not acting like live control surfaces.

### 3. Hardware and peripherals are only partly wired

- Confirmed fact: `hardware.enabled` and `peripherals.enabled` are parsed from config and displayed in status. (`src/config_parse.zig:1623-1665`, `src/status.zig:199-208`)
- Confirmed fact: hardware tools (`hardware_board_info`, `hardware_memory`, `i2c`, `spi`) are only added when `allTools()` receives `opts.hardware_boards`. (`src/tools/root.zig:478-494`)
- Confirmed fact: the main runtime call sites I inspected do not pass `hardware_boards` into `allTools()`: gateway tenant runtime, channel runtime, CLI agent, and main agent CLI path all omit it. (`src/gateway.zig:858-872`, `src/channel_loop.zig:268-284`, `src/agent/cli.zig:121-134`, `src/main.zig:2270-2284`, `src/main.zig:2593-2604`)
- Confirmed fact: the `hardware` CLI only implements `scan`; `flash` and `monitor` are still explicit placeholders. (`src/main.zig:1012-1064`)
- High-confidence inference: the repo has real hardware/peripheral code, but the main assistant runtime does not currently activate the hardware tools from config alone.
- Effect: hardware/peripheral support exists in source and tests, but much of it is inert for normal agent execution.

### 4. `NULLALIS_CONFIG_PATH` is decorative; the runtime does not read it

- Confirmed fact: deployment startup exports `NULLALIS_CONFIG_PATH=/nullclaw-data/.nullalis/config.json`. (`deploy/k8s/zaki-bot/05-deployment.yaml:50-53`)
- Confirmed fact: helper scripts also use `NULLALIS_CONFIG_PATH` as an override. (`scripts/preflight.sh:1-5`, `scripts/preflight-integrations.sh:1-5`)
- Confirmed fact: `Config.load()` constructs the config path as `<HOME>/.nullalis/config.json` and then applies only `NULLCLAW_*` env overrides; I did not find any source reference to `NULLALIS_CONFIG_PATH`. (`src/config.zig:219-243`, `src/config.zig:427-472`)
- High-confidence inference: exporting `NULLALIS_CONFIG_PATH` does not change runtime config loading in this checkout; the deployment works because it also sets `HOME=/nullclaw-data`. (`deploy/k8s/zaki-bot/05-deployment.yaml:50-53`, `src/config.zig:219-243`)
- Effect: config-path override behavior is implied by scripts/manifests but not actually implemented in the binary.

### 5. API documentation is not fully aligned with the gateway

- Confirmed fact: the OpenAPI header says `/api/v1/*` and `/internal/*` require `X-Internal-Token`. (`docs/openapi-v1.yaml:8-13`)
- Confirmed fact: gateway internal auth is conditional on `production_like_gateway`; if no internal tokens are configured and the gateway is not production-like, `validateInternalServiceTokenWithPolicy(...)` returns true without a token. (`src/gateway.zig:1361-1365`, `src/gateway.zig:1419-1439`, `src/gateway.zig:8383-8391`)
- High-confidence inference: the OpenAPI note overstates auth requirements for local/loopback development mode.
- Confirmed fact: the gateway exposes webhook routes for `/telegram`, `/webhook/telegram`, `/whatsapp`, `/slack/events`, `/line`, and `/lark`. (`src/gateway.zig:6528-6535`)
- Confirmed fact: the OpenAPI file documents `/webhook/telegram`, but I did not find corresponding OpenAPI path entries for `/telegram`, `/whatsapp`, `/slack/events`, `/line`, or `/lark`. (`docs/openapi-v1.yaml:140-180`, `src/gateway.zig:6528-6535`)
- Effect: external integrators can follow an incomplete contract unless they read gateway code or deployment docs directly.

### 6. Default local and deployed product profiles still differ

- Confirmed fact: the default build excludes Postgres support, while the container build and k8s deployment expect the Postgres-enabled profile. (`build.zig:196-202`, `Dockerfile:6-13`, `deploy/k8s/zaki-bot/README.md:46-53`)
- Confirmed fact: the deployment README’s ARM build command still omits `-Dengines=base,sqlite,postgres`. (`deploy/k8s/zaki-bot/README.md:261-274`)
- High-confidence inference: local “it builds” and deployment “it matches tenant-state reality” are still different bars unless engineers consciously build the Postgres profile.
- Effect: easy to validate the wrong artifact locally.

### 7. Shutdown semantics still do not match long-lived stream semantics

- Confirmed fact: ingress allows 3600-second read/send timeouts for SSE. (`deploy/k8s/zaki-bot/07-ingress.yaml:12-19`)
- Confirmed fact: the deployment gives pods 90 seconds of termination grace and `preStop` sleeps 5 seconds between drain and shutdown. (`deploy/k8s/zaki-bot/05-deployment.yaml:31`, `deploy/k8s/zaki-bot/05-deployment.yaml:158-167`)
- High-confidence inference: long-running chat streams can still be cut during rollouts or node disruption.
- Effect: graceful drain is present, but not fully aligned with the stream contract.

### 8. Some CLI surface is still instructional rather than functional

- Confirmed fact: `nullalis channel add` and `nullalis channel remove` are explicit “Not implemented” flows that print config-edit instructions. (`src/main.zig:838-861`)
- Confirmed fact: `nullalis hardware flash` and `nullalis hardware monitor` are explicit “Not implemented” flows. (`src/main.zig:1053-1064`)
- Confirmed fact: `nullalis service` is platform-limited and exits with clear unsupported/systemd-specific errors on unsupported environments. (`src/main.zig:228-280`)
- Effect: the CLI exposes more surface area than it fully implements.

## Available But Not Active

### Runtime Adapters

- Confirmed fact: `NativeRuntime`, `DockerRuntime`, `WasmRuntime`, and `CloudflareRuntime` are real adapter types with tests. (`src/runtime.zig:43-409`)
- High-confidence inference: in this checkout they are capability models and test-covered abstractions, not actively selected by the shipped runtime path.

### Tunnel Providers

- Confirmed fact: `NoneTunnel`, `CloudflareTunnel`, `NgrokTunnel`, `TailscaleTunnel`, and `CustomTunnel` exist with a tunnel factory. (`src/tunnel.zig:121-260`, `src/tunnel.zig:292-499`, `src/tunnel.zig:540-844`, `src/tunnel.zig:873-1004`)
- High-confidence inference: tunnel configuration is currently more of an onboarding/config artifact than an active gateway feature.

### Hardware/Peripherals

- Confirmed fact: serial, Arduino, RPi GPIO, and Nucleo peripheral implementations exist. (`src/peripherals.zig:106-260`, `src/peripherals.zig:264-464`, `src/peripherals.zig:497-844`)
- High-confidence inference: much of that subsystem is presently “library code plus tests plus scan,” not end-to-end runtime capability.

## What This Audit No Longer Claims

- Confirmed fact: the earlier suspicion that cron/pushover tools were implemented but not loaded is no longer true in this checkout; `allTools()` now appends the `cron_*` tools and `pushover`. (`src/tools/root.zig:380-410`)
- Confirmed fact: the earlier metric-prefix alert mismatch is also no longer true in manifests; the Prometheus rules now reference `nullalis_gateway_*` series. (`deploy/k8s/zaki-bot/12-prometheusrule.yaml:13-38`, `src/gateway.zig:3884-4002`)

## Bottom Line

- Confirmed fact: the codebase is not sloppy, but it is not yet “swiss watch exact.”
- Confirmed fact: the sharpest current wrinkles are profile-specific correctness gaps and decorative config/features: Postgres-enabled tests fail, some config knobs do not drive runtime behavior, and some docs promise a cleaner contract than the gateway actually enforces. (`src/channel_identity_backfill.zig:211-277`, `src/inbound_canonicalizer.zig:516-790`, `src/gateway.zig:11403-11410`, `src/config_parse.zig:599-610`, `src/config_parse.zig:1623-1665`, `src/config_parse.zig:1740-1745`, `docs/openapi-v1.yaml:8-13`, `src/gateway.zig:1361-1439`)
- High-confidence inference: the next step is not broad refactoring; it is tightening the decorative surfaces until config, docs, tests, and the deployment profile all describe the same machine.

## Next Steps: Memory and Caching Roadmap

### Objective

- Keep current snappy behavior while improving continuity and correctness using explicit short-term, mid-term, and long-term memory layers plus disciplined caching.

### Phase 1 (Short-Term Memory, Hot Path)

- Keep interactive turn compaction trim-only (`turn_compaction mode=trim`) and avoid provider-backed summarization in the turn hot path.
- Maintain a strict working set per lane/session: recent turns + active task context only.
- Add per-turn retrieval dedupe (L1 cache) to avoid repeated identical memory lookups within a single turn.

### Phase 2 (Mid-Term Memory, Boundary Path)

- Keep lifecycle summarizer at boundaries only (`/new`, TTL recycle/evict, idle evict, shutdown/drain checkpoint).
- Enforce bounded summarizer budget (cooldown + timeout + fallback) so failure never blocks user-turn completion.
- Store session episodes as `session_summary/*` and keep them retrievable ahead of noisy transcript/autosave entries.

### Phase 3 (Long-Term Durable Memory)

- Promote only durable facts by policy: preferences, decisions, commitments, project state, relationship facts, shared vocabulary.
- Do not auto-promote filler/tool noise/transient guesses.
- Keep canonical durable state in backend; workspace files remain projection/inspection surfaces.

### Caching Layers

- L1: in-turn dedupe cache for repeated retrieval calls in the same turn.
- L2: semantic/response cache with TTL + similarity/confidence threshold.
- L3: short-lived retrieval-result cache keyed by `(user_id, session_lane, query_hash)` to cut repetitive enrich latency across nearby turns.

### Validation Gates

- Stage attribution must show no provider-backed compaction in interactive hot path.
- Boundary summarizer events (`memory_lifecycle_summarizer`) must appear on checkpoint flows, not ordinary turn flows.
- Recall quality tests must show durable fact recall without transcript stuffing.
- Cache hit ratio and latency deltas must improve p50/p95 without increasing wrong-context recalls.
