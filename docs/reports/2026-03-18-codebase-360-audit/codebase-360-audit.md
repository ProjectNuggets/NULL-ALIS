# nullALIS 360 Codebase Audit

Date: 2026-03-18

Validation run:
- `zig build test --summary all` passed: `4686 passed`, `25 skipped`, `0 failed`, `MaxRSS 44M`.
- `zig build -Doptimize=ReleaseSmall` passed.
- `zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite,postgres` passed.

Legend:
- Confirmed fact: directly verified in code/manifests/tests in this checkout.
- High-confidence inference: consequence strongly implied by verified code.
- Unknown: needs runtime or staging validation.

## Executive Summary

- Confirmed fact: the codebase is broadly healthy at build/test level, and both the default release build and the Postgres-enabled release build complete successfully. (`build.zig:263-453`)
- Confirmed fact: the shipped capability surface is larger than the actually active surface; activation is controlled by compile-time flags, config, listener mode, and some runtime-only conditions. (`build.zig:66-69`, `build.zig:196-202`, `src/channel_catalog.zig:33-54`, `src/capabilities.zig:62-71`)
- Confirmed fact: deployment observability is currently miswired: the Prometheus alert rules use `nullclaw_*` metric names, while the gateway exports `nullalis_*` metric names. Alerts as written will not match the emitted series. (`deploy/k8s/zaki-bot/12-prometheusrule.yaml:13-54`, `src/gateway.zig:3884-4002`)
- Confirmed fact: the capabilities/reporting layer underestimates and misnames runtime tools; it omits several tools that `allTools()` actually loads and uses `git` instead of the real tool name `git_operations`. (`src/capabilities.zig:11-36`, `src/capabilities.zig:62-71`, `src/tools/root.zig:299-471`, `src/tools/git.zig:18-21`)
- Confirmed fact: several source features are present but not actually reachable from the agent runtime, notably the `cron_*` tool modules and `pushover`, which are implemented but never appended in `allTools()`. (`src/tools/root.zig:77-85`, `src/tools/root.zig:299-471`, `src/tools/cron_add.zig:30-47`, `src/tools/cron_list.zig:31-48`, `src/tools/cron_remove.zig:31-48`, `src/tools/pushover.zig:9-31`)
- Confirmed fact: multiple CLI surfaces are placeholders or partial implementations: `channel add/remove`, `hardware flash/monitor`, and `models benchmark` do not perform the implied operation. (`src/main.zig:838-857`, `src/main.zig:1049-1056`, `src/main.zig:1713-1715`)
- Confirmed fact: the default local binary excludes Postgres support, while the Docker image and the k8s deployment profile include it. Local-default and deployed-default are different runtime profiles. (`build.zig:196-202`, `build.zig:279-300`, `Dockerfile:6-13`, `deploy/k8s/zaki-bot/README.md:46-53`)
- High-confidence inference: operator and developer expectations can drift because docs and deployment materials still mix `nullALIS`, `nullalis`, and `nullclaw` naming, including env vars, resource names, and alert definitions. (`deploy/k8s/zaki-bot/README.md:8-10`, `Dockerfile:17-18`, `Dockerfile:51-60`, `src/config.zig:427-468`)
- Confirmed fact: per-user filesystem isolation is correctly modeled end-to-end in gateway user context resolution, even in tenant mode. (`src/gateway.zig:1466-1495`)
- Confirmed fact: deployment shutdown semantics are still bounded by a 90-second pod grace period while ingress allows 3600-second SSE connections, so long streams can still be cut during rollout or disruption. (`deploy/k8s/zaki-bot/05-deployment.yaml:31`, `deploy/k8s/zaki-bot/05-deployment.yaml:158-167`, `deploy/k8s/zaki-bot/07-ingress.yaml:12-19`)

## Current Reality Map

### Build and Packaging Truth

- Confirmed fact: default channel compilation is `all`, so the standard binary compiles every listed channel unless explicitly reduced with `-Dchannels=...`. (`build.zig:66-69`, `build.zig:267-277`)
- Confirmed fact: default memory-engine compilation is `base,sqlite`; Postgres is not included unless `-Dengines=...postgres` is passed. (`build.zig:196-202`, `build.zig:279-300`)
- Confirmed fact: the Docker image build explicitly enables Postgres by building with `-Dengines=base,sqlite,postgres`. (`Dockerfile:6-13`)
- Confirmed fact: the deployment pack documents a Postgres-first tenant profile with PgBouncer enabled by default. (`deploy/k8s/zaki-bot/README.md:46-53`, `deploy/k8s/zaki-bot/05-deployment.yaml:57-65`, `deploy/k8s/zaki-bot/05-deployment.yaml:98-107`)
- High-confidence inference: local `zig build` and production container images exercise different storage and tenant code paths unless engineers opt into the Postgres build locally. (`build.zig:196-202`, `Dockerfile:12`, `deploy/k8s/zaki-bot/README.md:46-53`)

### Activation Model: Compiled vs Configured vs Active

- Confirmed fact: channels are tracked by listener mode: `polling`, `gateway_loop`, `webhook_only`, `send_only`, or `none`. (`src/channel_catalog.zig:33-54`)
- Confirmed fact: `telegram`, `matrix`, and `signal` are polling channels; `discord`, `slack`, `imessage`, `mattermost`, `irc`, `qq`, and `onebot` are gateway-loop channels; `whatsapp`, `lark`, and `line` are webhook-only; `dingtalk`, `email`, and `maixcam` are send-only. (`src/channel_catalog.zig:36-54`)
- Confirmed fact: a channel only becomes active if it is both build-enabled and configured. (`src/channel_catalog.zig:65-120`)
- Confirmed fact: the daemon only creates channel runtime state and inbound dispatch workers if at least one runtime-dependent channel is configured. (`src/daemon.zig:2217-2277`, `src/channel_catalog.zig:168-183`)
- Confirmed fact: `ChannelManager.startAll()` starts polling threads, gateway loops, webhook registrations, and send-only starts differently by listener type. (`src/channel_manager.zig:271-342`)
- Confirmed fact: Telegram is special-cased so configured `receive_mode=webhook` flips it from polling to webhook-only at runtime. (`src/channel_manager.zig:201-206`)

### State and Per-User Isolation

- Confirmed fact: the gateway resolves a per-user root and derives per-user `workspace`, `memory.db`, `cron.json`, `config.json`, `heartbeat.json`, `channel_state.json`, `telegram.json`, and `secrets/` paths from it. (`src/gateway.zig:1466-1495`)
- Confirmed fact: the memory registry knows about `none`, `markdown`, `memory`, `api`, `sqlite`, `lucid`, `redis`, `lancedb`, and `postgres`, but only build-enabled backends are actually present in the executable. (`src/memory/engines/registry.zig:124-188`, `src/memory/engines/registry.zig:192-197`)
- Confirmed fact: the tenant state manager becomes a stub that returns `PostgresNotEnabled` when the binary is built without Postgres support. (`src/zaki_state.zig:69-207`)
- High-confidence inference: in non-Postgres builds, tenant-mode behavior can still look “configured” from config files while key canonical tenant state operations are silently unavailable behind the stub manager. (`src/zaki_state.zig:69-207`, `build.zig:196-202`)
- Confirmed fact: the deployment includes Litestream to replicate per-user `memory.db` files, not Postgres state. (`deploy/k8s/zaki-bot/11-litestream-configmap.yaml:10-20`)
- High-confidence inference: Litestream protects SQLite/file-fallback durability and per-user memory mirrors, but not the canonical Postgres tenant state path documented for the k8s profile. (`deploy/k8s/zaki-bot/README.md:49-53`, `deploy/k8s/zaki-bot/11-litestream-configmap.yaml:10-20`)

## Findings

| Severity | Finding | Effect | Evidence | Confidence |
| --- | --- | --- | --- | --- |
| P0 | Prometheus alerts are wired to `nullclaw_*` metric names while the gateway exports `nullalis_*`. | Alert rules for lock conflicts, drain rejects, Telegram rejects, and chat-stream errors will not fire on the emitted metrics. | `deploy/k8s/zaki-bot/12-prometheusrule.yaml:13-54`; `src/gateway.zig:3884-4002` | Confirmed fact |
| P1 | Capability reporting is stale and incomplete. `core_tool_names` and `optional_tool_names` do not match the actual tool set built by `allTools()`. | `/capabilities`-style summaries and any tooling that trusts the estimated manifest can underreport or misname runtime tools. | `src/capabilities.zig:11-36`; `src/capabilities.zig:62-71`; `src/tools/root.zig:299-471`; `src/tools/git.zig:18-21`; `src/tools/file_append.zig:23-27`; `src/tools/runtime_info.zig:43-50`; `src/tools/skill_registry.zig:11-18`; `src/tools/spi.zig:11-19` | Confirmed fact |
| P1 | Some tool modules are implemented but never activated in the runtime tool list. | The agent cannot invoke these tools even though they exist in source and tests, which creates dead surface area and false expectations. | `src/tools/root.zig:77-85`; `src/tools/root.zig:299-471`; `src/tools/cron_add.zig:30-47`; `src/tools/cron_list.zig:31-48`; `src/tools/cron_remove.zig:31-48`; `src/tools/pushover.zig:9-31` | Confirmed fact |
| P1 | Local-default build profile and deployment-default build profile differ on Postgres support. | Engineers can validate a binary locally that cannot exercise the same tenant state path as the containerized deployment. | `build.zig:196-202`; `build.zig:279-300`; `Dockerfile:6-13`; `deploy/k8s/zaki-bot/README.md:46-53` | Confirmed fact |
| P1 | Deployment docs still ship an ARM build command that omits Postgres even though the deployment profile expects Postgres tenant mode. | A team following the ARM instructions literally can produce an image that boots without the intended canonical state backend. | `deploy/k8s/zaki-bot/README.md:46-53`; `deploy/k8s/zaki-bot/README.md:261-274`; `build.zig:196-202` | Confirmed fact |
| P1 | Several CLI commands are present but not actually implemented as the UX implies. | Users can believe they have management commands that are only instructions or placeholders. | `src/main.zig:838-857`; `src/main.zig:1049-1056`; `src/main.zig:1713-1715` | Confirmed fact |
| P1 | The deployment pack claims legacy `nullclaw` metric prefixes while the gateway code emits `nullalis` prefixes. | Naming drift is no longer cosmetic; it already causes observability breakage. | `deploy/k8s/zaki-bot/README.md:8-10`; `deploy/k8s/zaki-bot/12-prometheusrule.yaml:13-54`; `src/gateway.zig:3884-4002` | Confirmed fact |
| P2 | HPA scales only on CPU and memory, even though the gateway exports queue-pressure and in-flight-request signals. | Scaling may lag user-facing saturation events such as overload rejects or queue buildup. | `deploy/k8s/zaki-bot/09-hpa.yaml:16-28`; `src/gateway.zig:3869-3871`; `src/gateway.zig:3943-3951` | High-confidence inference |
| P2 | Long SSE sessions can outlive pod termination grace. | Some active chat streams can be cut during rollout or node disruption despite drain handling. | `deploy/k8s/zaki-bot/05-deployment.yaml:31`; `deploy/k8s/zaki-bot/05-deployment.yaml:158-167`; `deploy/k8s/zaki-bot/07-ingress.yaml:12-19` | Confirmed fact |
| P2 | Lark support is partial: webhook path exists, WebSocket long-connection mode is explicitly unimplemented. | Lark is available for webhook-driven use, but the more persistent connection mode does not exist yet. | `src/channel_catalog.zig:46-54`; `src/channels/lark.zig:5-12`; `src/channels/lark.zig:361` | Confirmed fact |

## Inert / Partial / Available-but-Not-Active Inventory

### Compiled but Not Automatically Active

- Confirmed fact: build-enabled channels still remain inactive until configured; `isConfigured()` requires both build support and non-zero config count. (`src/channel_catalog.zig:106-120`)
- Confirmed fact: optional tools are config-gated; `http_request`, `browser`, `screenshot`, `composio`, `browser_open`, and hardware tools are disabled unless their config preconditions are met. (`src/capabilities.zig:62-71`, `src/tools/root.zig:404-462`)
- Confirmed fact: send-only channels (`dingtalk`, `email`, `maixcam`) can be present and started, but they do not receive inbound traffic. (`src/channel_catalog.zig:46-54`, `src/channel_manager.zig:327-333`)

### Implemented but Not Reachable from Agent Runtime

- Confirmed fact: `CronAddTool`, `CronListTool`, `CronRemoveTool`, and `PushoverTool` are real tool implementations with schemas and execute methods. (`src/tools/cron_add.zig:30-60`, `src/tools/cron_list.zig:31-59`, `src/tools/cron_remove.zig:31-60`, `src/tools/pushover.zig:9-31`)
- Confirmed fact: `allTools()` never allocates those tool structs, so they are not part of the runtime tool slice used by gateway, channel runtime, CLI agent, or tests that rely on `allTools()`. (`src/tools/root.zig:268-471`; `src/gateway.zig:858-872`; `src/channel_loop.zig:269-281`; `src/agent/root.zig:4227`; `src/main.zig:2270-2283`)

### User-Facing Partial Features

- Confirmed fact: `nullalis channel add` and `nullalis channel remove` only print config-edit instructions. (`src/main.zig:838-857`)
- Confirmed fact: `nullalis hardware flash` and `nullalis hardware monitor` are placeholders. (`src/main.zig:1049-1056`)
- Confirmed fact: `nullalis models benchmark` is a stub message, not a benchmark runner. (`src/main.zig:1713-1715`)
- Confirmed fact: `nullalis service` is platform-limited and depends on systemd user services; on unsupported platforms it exits with explicit errors. (`src/main.zig:228-280`)

## What Is Working Reliably

- Confirmed fact: the daemon runtime scaffolds workspace state, starts gateway, delivery outcome, optional heartbeat/scheduler threads, supervised channels, and inbound/outbound dispatchers. (`src/daemon.zig:2104-2317`)
- Confirmed fact: gateway routing exposes health, readiness, metrics, internal diagnostics, webhook endpoints, and the app `/api/v1/chat/stream` path. (`src/gateway.zig:7904-8150`)
- Confirmed fact: per-user tenant filesystem paths are derived consistently from `tenant_data_root/user_id`. (`src/gateway.zig:1471-1495`)
- Confirmed fact: the container image builds a Postgres-capable runtime that matches the intended k8s tenant profile better than the default local build does. (`Dockerfile:6-13`, `deploy/k8s/zaki-bot/README.md:46-53`)
- Confirmed fact: the repo’s capabilities module at least models the difference between build-enabled, configured, and runtime-loaded channels/tools, even though some tool estimates are stale. (`src/capabilities.zig:38-142`, `src/capabilities.zig:197-320`)

## Unknowns Requiring Runtime Validation

- Unknown: whether the deployment actually relies materially on Litestream-restored `memory.db` files in the current Postgres-first tenant profile, or whether the sidecar is mostly protecting fallback/diagnostic state. Code proves the sidecar exists, not how often it matters operationally. (`deploy/k8s/zaki-bot/11-litestream-configmap.yaml:10-20`, `src/gateway.zig:1466-1495`)
- Unknown: whether CPU/memory-only HPA behavior is sufficient under realistic chat-stream saturation, since no staging traffic replay results are encoded in repo state. (`deploy/k8s/zaki-bot/09-hpa.yaml:16-28`)
- Unknown: whether the SSE drain/shutdown policy produces acceptable interruption rates during rollouts in practice. The manifests show the timing mismatch, but not the observed impact. (`deploy/k8s/zaki-bot/05-deployment.yaml:31`, `deploy/k8s/zaki-bot/05-deployment.yaml:158-167`, `deploy/k8s/zaki-bot/07-ingress.yaml:12-19`)

## Immediate TODOs

### P0

- Fix the Prometheus rules to use the actual `nullalis_*` metric names exported by `/metrics`. Target: `deploy/k8s/zaki-bot/12-prometheusrule.yaml`. Verify by comparing each rule expression against `curl /metrics` output. (`deploy/k8s/zaki-bot/12-prometheusrule.yaml:13-54`, `src/gateway.zig:3884-4002`)

### P1

- Bring capability reporting in sync with the real runtime tool set. Target: `src/capabilities.zig`. Minimum fixes: rename `git` to `git_operations`, add `file_append`, `runtime_info`, `skill_registry`, `web_fetch`, `web_search`, `message`, and `spi`, or derive estimates from the actual tool builder instead of hardcoded lists. Verify by diffing `estimated_enabled_from_config` against `runtime_loaded`. (`src/capabilities.zig:11-36`, `src/tools/root.zig:299-471`)
- Decide whether the unwired tool modules should be exposed or removed. Target: `src/tools/root.zig` plus the individual tool modules. Verify by asserting expected tool names in `allTools()` tests. (`src/tools/root.zig:77-85`, `src/tools/root.zig:299-471`, `src/tools/root.zig:1049-1176`)
- Align local and documented release builds with the deployment profile. Targets: `README.md`, `deploy/k8s/zaki-bot/README.md`, optionally `build.zig` defaults if product direction is Postgres-first. Verify by following the docs from scratch and confirming the resulting binary supports the intended tenant state path. (`README.md:133-149`, `deploy/k8s/zaki-bot/README.md:46-53`, `deploy/k8s/zaki-bot/README.md:261-274`, `build.zig:196-202`)
- Replace placeholder CLI commands with either real implementations or explicit “not supported” positioning in help text. Targets: `src/main.zig`. Verify via CLI golden-path tests or direct command execution. (`src/main.zig:800-857`, `src/main.zig:1049-1056`, `src/main.zig:1713-1715`)

### P2

- Revisit rollout safety for long SSE connections. Targets: `deploy/k8s/zaki-bot/05-deployment.yaml`, `deploy/k8s/zaki-bot/07-ingress.yaml`. Verify with a canary rollout while holding open long-lived `/api/v1/chat/stream` requests. (`deploy/k8s/zaki-bot/05-deployment.yaml:31`, `deploy/k8s/zaki-bot/05-deployment.yaml:158-167`, `deploy/k8s/zaki-bot/07-ingress.yaml:12-19`)
- Consider adding queue/backpressure-aware autoscaling signals. Targets: `deploy/k8s/zaki-bot/09-hpa.yaml` and the metrics consumer stack. Verify under synthetic saturation using overload and in-flight metrics. (`deploy/k8s/zaki-bot/09-hpa.yaml:16-28`, `src/gateway.zig:3943-3951`)

## Bottom Line

- Confirmed fact: this repo is not “broken”; it builds, tests, and contains a substantial active runtime surface.
- Confirmed fact: the biggest 360 gaps are not core execution bugs but truthfulness gaps between source, diagnostics, CLI UX, and deployment materials.
- High-confidence inference: the fastest risk reduction comes from fixing observability wiring, capability reporting drift, and the documented build/deploy contract before adding new surface area.
